#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 RECEIPT_ID OUTPUT_DIR ED25519_PRIVATE_KEY" >&2
  exit 2
fi

receipt_id="$1"
output_dir="$2"
private_key="$3"
container="${OTLET_PG_CONTAINER:-otlet-postgres}"
database="${OTLET_DATABASE:-postgres}"

[[ "$receipt_id" =~ ^[1-9][0-9]*$ ]] || {
  echo "Receipt ID must be a positive integer" >&2
  exit 2
}
[ -r "$private_key" ] || {
  echo "Signing key is not readable: $private_key" >&2
  exit 1
}
[ ! -e "$output_dir" ] || {
  echo "Decision export output already exists: $output_dir" >&2
  exit 1
}

for command in docker jq openssl sha256sum stat; do
  command -v "$command" >/dev/null || {
    echo "Missing decision export command: $command" >&2
    exit 1
  }
done
docker container inspect "$container" >/dev/null 2>&1 || {
  echo "Container $container is unavailable" >&2
  exit 1
}

host_tmp="$(mktemp -d "${TMPDIR:-/tmp}/otlet-decision-export.XXXXXX")"
cleanup() {
  rm -rf "$host_tmp"
}
trap cleanup EXIT

public_key="$host_tmp/signing-public-key.pem"
public_der="$host_tmp/signing-public-key.der"
openssl pkey -in "$private_key" -pubout -out "$public_key"
openssl pkey -pubin -in "$public_key" -text -noout | grep -q 'ED25519' || {
  echo "Decision exports require an Ed25519 signing key" >&2
  exit 1
}
openssl pkey -pubin -in "$public_key" -outform DER -out "$public_der"
signing_key_sha256="$(sha256sum "$public_der" | awk '{print $1}')"

psql_exec() {
  docker exec -i "$container" psql -U postgres -d "$database" -v ON_ERROR_STOP=1 "$@"
}

psql_value() {
  psql_exec -qAt "$@"
}

export_rows="$(psql_value -v receipt_id="$receipt_id" <<'SQL'
SELECT count(*)
FROM otlet.decision_trace_export
WHERE receipt_id = :'receipt_id'::bigint;
SQL
)"
[ "$export_rows" = "1" ] || {
  echo "Receipt $receipt_id is not one accepted, schema-valid decision" >&2
  exit 1
}

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

psql_exec -q -v receipt_id="$receipt_id" >"$output_dir/decision.csv" <<'SQL'
COPY (
  SELECT
    receipt_id,
    job_id,
    output_id,
    task_name,
    subject_id,
    recommendation_id,
    decision_trace_sha256,
    decision_trace::text AS decision_trace,
    recommendation::text AS recommendation
  FROM otlet.decision_trace_export
  WHERE receipt_id = :'receipt_id'::bigint
  ORDER BY receipt_id
) TO STDOUT WITH (FORMAT csv, HEADER true, FORCE_QUOTE *);
SQL

printf '%s\n' \
  'BEGIN;' \
  'SET standard_conforming_strings = on;' \
  'CREATE TABLE IF NOT EXISTS otlet_decision_trace_export (' \
  '  receipt_id bigint PRIMARY KEY,' \
  '  job_id bigint NOT NULL,' \
  '  output_id bigint NOT NULL,' \
  '  task_name text NOT NULL,' \
  '  subject_id text NOT NULL,' \
  '  recommendation_id text NOT NULL,' \
  '  decision_trace_sha256 text NOT NULL,' \
  '  decision_trace jsonb NOT NULL,' \
  '  recommendation jsonb NOT NULL' \
  ');' >"$output_dir/decision.sql"
psql_value -v receipt_id="$receipt_id" >>"$output_dir/decision.sql" <<'SQL'
SELECT format(
  'INSERT INTO otlet_decision_trace_export VALUES (%s, %s, %s, %L, %L, %L, %L, %L::jsonb, %L::jsonb);',
  receipt_id,
  job_id,
  output_id,
  task_name,
  subject_id,
  recommendation_id,
  decision_trace_sha256,
  decision_trace::text,
  recommendation::text
)
FROM otlet.decision_trace_export
WHERE receipt_id = :'receipt_id'::bigint
ORDER BY receipt_id;
SQL
printf '%s\n' 'COMMIT;' >>"$output_dir/decision.sql"

recommendation="$(psql_value -v receipt_id="$receipt_id" <<'SQL'
SELECT recommendation::text
FROM otlet.decision_trace_export
WHERE receipt_id = :'receipt_id'::bigint;
SQL
)"
destinations="$(psql_value -v receipt_id="$receipt_id" <<'SQL'
SELECT COALESCE(jsonb_agg(jsonb_build_object(
  'destination', destination.destination,
  'idempotency_key', destination.idempotency_key,
  'recommendation_id', destination.recommendation_id,
  'state', destination.state
) ORDER BY destination.destination), '[]'::jsonb)
FROM otlet.destination_reconciliation_status destination
JOIN otlet.decision_trace_export trace ON trace.receipt_id = destination.receipt_id
WHERE destination.receipt_id = :'receipt_id'::bigint
  AND destination.recommendation_id = trace.recommendation_id
  AND destination.decision_trace_sha256 = trace.decision_trace_sha256;
SQL
)"
: >"$host_tmp/manifest.rows"
for path in decision.csv decision.sql; do
  file="$output_dir/$path"
  bytes="$(stat -f %z "$file" 2>/dev/null || stat -c %s "$file")"
  sha256="$(sha256sum "$file" | awk '{print $1}')"
  jq -cn \
    --arg path "$path" \
    --arg sha256 "$sha256" \
    --argjson bytes "$bytes" \
    '{path: $path, bytes: $bytes, sha256: $sha256}' >>"$host_tmp/manifest.rows"
done
jq -S -c -s \
  --argjson receipt_id "$receipt_id" \
  '{format: "otlet.audit-manifest.v1", receipt_id: $receipt_id, files: sort_by(.path)}' \
  "$host_tmp/manifest.rows" >"$output_dir/audit-manifest.json"
manifest_sha256="$(sha256sum "$output_dir/audit-manifest.json" | awk '{print $1}')"

jq -S -c -n \
  --arg format "otlet.signed-recommendation.v1" \
  --arg manifest_sha256 "$manifest_sha256" \
  --arg signing_key_sha256 "$signing_key_sha256" \
  --argjson receipt_id "$receipt_id" \
  --argjson recommendation "$recommendation" \
  --argjson destinations "$destinations" \
  '{
    format: $format,
    receipt_id: $receipt_id,
    manifest_sha256: $manifest_sha256,
    signing_key_sha256: $signing_key_sha256,
    recommendation: $recommendation,
    destinations: $destinations
  }' >"$output_dir/recommendation-envelope.json"

openssl pkeyutl \
  -sign \
  -rawin \
  -inkey "$private_key" \
  -in "$output_dir/recommendation-envelope.json" |
  openssl base64 -A >"$output_dir/recommendation-envelope.sig"
printf '\n' >>"$output_dir/recommendation-envelope.sig"
cp "$public_key" "$output_dir/signing-public-key.pem"

echo "decision_export_created=$receipt_id|$manifest_sha256|$signing_key_sha256|$output_dir"
