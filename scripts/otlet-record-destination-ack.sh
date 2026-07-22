#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 ACKNOWLEDGEMENT_JSON SIGNATURE_B64 ED25519_PUBLIC_KEY [DATABASE_ROLE]" >&2
  exit 2
fi

acknowledgement_file="$1"
signature_file="$2"
public_key="$3"
database_role="${4:-${OTLET_PG_USER:-postgres}}"
container="${OTLET_PG_CONTAINER:-otlet-postgres}"
database="${OTLET_DATABASE:-postgres}"

for file in "$acknowledgement_file" "$signature_file" "$public_key"; do
  [ -r "$file" ] || {
    echo "Destination acknowledgement file is not readable: $file" >&2
    exit 1
  }
done
for command in docker jq openssl sha256sum cmp; do
  command -v "$command" >/dev/null || {
    echo "Missing destination acknowledgement command: $command" >&2
    exit 1
  }
done

host_tmp="$(mktemp -d "${TMPDIR:-/tmp}/otlet-destination-ack.XXXXXX")"
cleanup() {
  rm -rf "$host_tmp"
}
trap cleanup EXIT

jq -S -c . "$acknowledgement_file" | cmp -s - "$acknowledgement_file" || {
  echo "Destination acknowledgement is not canonical JSON" >&2
  exit 1
}
jq -e '
  .format == "otlet.destination-acknowledgement.v1" and
  (.destination | test("^[a-z0-9][a-z0-9_.-]{0,127}$")) and
  (.recommendation_id | test("^sha256:[0-9a-f]{64}$")) and
  (.idempotency_key | test("^sha256:[0-9a-f]{64}$")) and
  (.acknowledgement_id | test("^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$")) and
  (.state == "received" or .state == "applied" or .state == "rejected") and
  (.replay_decision == "fresh" or .replay_decision == "duplicate_replay" or .replay_decision == "not_applicable") and
  (if .state == "applied" then
     (.destination_execution_receipt_id | type == "string") and
     (.replay_decision == "fresh" or .replay_decision == "duplicate_replay")
   else
     .destination_execution_receipt_id == null and
     .replay_decision == "not_applicable"
   end) and
  (if .replay_decision == "duplicate_replay" then
     (.replay_of_acknowledgement_id | type == "string")
   else
     .replay_of_acknowledgement_id == null
   end) and
  ((keys | sort) == [
    "acknowledgement_id",
    "destination",
    "destination_execution_receipt_id",
    "format",
    "idempotency_key",
    "recommendation_id",
    "replay_decision",
    "replay_of_acknowledgement_id",
    "state"
  ])
' "$acknowledgement_file" >/dev/null || {
  echo "Destination acknowledgement contract is invalid" >&2
  exit 1
}

openssl base64 -d -A -in "$signature_file" -out "$host_tmp/signature.bin"
openssl pkeyutl \
  -verify \
  -pubin \
  -inkey "$public_key" \
  -rawin \
  -in "$acknowledgement_file" \
  -sigfile "$host_tmp/signature.bin" >/dev/null || {
    echo "Destination acknowledgement signature is invalid" >&2
    exit 1
  }
openssl pkey -pubin -in "$public_key" -outform DER -out "$host_tmp/public.der"

destination="$(jq -r '.destination' "$acknowledgement_file")"
recommendation_id="$(jq -r '.recommendation_id' "$acknowledgement_file")"
idempotency_key="$(jq -r '.idempotency_key' "$acknowledgement_file")"
acknowledgement_id="$(jq -r '.acknowledgement_id' "$acknowledgement_file")"
acknowledgement_state="$(jq -r '.state' "$acknowledgement_file")"
destination_execution_receipt_id="$(jq -r '.destination_execution_receipt_id // ""' "$acknowledgement_file")"
replay_decision="$(jq -r '.replay_decision' "$acknowledgement_file")"
replay_of_acknowledgement_id="$(jq -r '.replay_of_acknowledgement_id // ""' "$acknowledgement_file")"
receiver_key_sha256="$(sha256sum "$host_tmp/public.der" | awk '{print $1}')"
signed_payload_sha256="$(sha256sum "$acknowledgement_file" | awk '{print $1}')"
signature_sha256="$(sha256sum "$host_tmp/signature.bin" | awk '{print $1}')"

result="$(docker exec -i "$container" \
  psql -U "$database_role" -d "$database" -v ON_ERROR_STOP=1 -qAt \
  -v destination="$destination" \
  -v recommendation_id="$recommendation_id" \
  -v idempotency_key="$idempotency_key" \
  -v acknowledgement_id="$acknowledgement_id" \
  -v acknowledgement_state="$acknowledgement_state" \
  -v destination_execution_receipt_id="$destination_execution_receipt_id" \
  -v replay_decision="$replay_decision" \
  -v replay_of_acknowledgement_id="$replay_of_acknowledgement_id" \
  -v receiver_key_sha256="$receiver_key_sha256" \
  -v signed_payload_sha256="$signed_payload_sha256" \
  -v signature_sha256="$signature_sha256" <<'SQL'
SELECT destination_export_id || '|' || reconciliation_state || '|' || duplicate_acknowledgement::text
FROM otlet.record_destination_acknowledgement(
  :'destination',
  :'recommendation_id',
  :'idempotency_key',
  :'acknowledgement_id',
  :'acknowledgement_state',
  NULLIF(:'destination_execution_receipt_id', ''),
  :'replay_decision',
  NULLIF(:'replay_of_acknowledgement_id', ''),
  :'receiver_key_sha256',
  :'signed_payload_sha256',
  :'signature_sha256'
);
SQL
)"

echo "destination_acknowledgement_recorded=$acknowledgement_id|$result|$receiver_key_sha256"
