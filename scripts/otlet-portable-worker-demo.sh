#!/usr/bin/env bash
set -euo pipefail

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
portable_database="otlet_portable_worker_demo"
worker_role="otlet_portable_worker_demo"
worker_id="portable-worker-demo"
model_name="${OTLET_STRONG_MODEL_NAME:-qwen35_4b}"
model_file="${OTLET_STRONG_MODEL_FILE:-Qwen3.5-4B-Q4_K_M.gguf}"
model_artifact="${OTLET_STRONG_MODEL_ARTIFACT:-}"
model_source="${OTLET_STRONG_MODEL_SOURCE:-local-demo}"
model_revision="${OTLET_STRONG_MODEL_REVISION:-main}"
model_quantization="${OTLET_STRONG_MODEL_QUANTIZATION:-Q4_K_M}"
model_license="${OTLET_STRONG_MODEL_LICENSE:-apache-2.0}"
worker_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
worker_log="$(mktemp)"

cleanup() {
  rm -f "$worker_log"
  docker exec "$container" dropdb -U postgres --if-exists "$portable_database" >/dev/null 2>&1 || true
  docker exec -i "$container" psql -U postgres -d postgres -X -qAt -v ON_ERROR_STOP=1 \
    -v worker_role="$worker_role" <<'SQL' >/dev/null 2>&1 || true
SELECT format('DROP ROLE IF EXISTS %I', :'worker_role') \gexec
SQL
}

trap cleanup EXIT

if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
  echo "Container $container is not running. Run ./scripts/otlet-setup.sh first" >&2
  exit 1
fi

cleanup

if [ -z "$model_artifact" ]; then
  model_artifact="$(docker exec "$container" find /var/lib/postgresql -name "$model_file" -type f -print -quit)"
fi
if [ -z "$model_artifact" ] || ! docker exec "$container" test -f "$model_artifact"; then
  echo "Missing model artifact. Set OTLET_STRONG_MODEL_ARTIFACT or run ./scripts/otlet-setup.sh first" >&2
  exit 1
fi

model_sha256="$(docker exec "$container" sha256sum "$model_artifact" | awk '{print $1}')"
model_bytes="$(docker exec "$container" stat -Lc %s "$model_artifact")"

docker exec -e CARGO_TARGET_DIR=/target -w /work "$container" \
  cargo build --locked --quiet --release -p otlet_worker
runtime_identity="$(docker exec "$container" /target/release/otlet_worker --print-runtime-identity)"

docker exec "$container" createdb -U postgres "$portable_database"
docker exec -w /work "$container" psql -U postgres -d "$portable_database" \
  -X -q -v ON_ERROR_STOP=1 -f portable/install.sql

docker exec -i "$container" psql -U postgres -d "$portable_database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -v worker_role="$worker_role" \
  -v worker_password="$worker_password" \
  -v worker_id="$worker_id" \
  -v model_name="$model_name" \
  -v model_artifact="$model_artifact" \
  -v model_sha256="$model_sha256" \
  -v model_bytes="$model_bytes" \
  -v model_source="$model_source" \
  -v model_revision="$model_revision" \
  -v model_quantization="$model_quantization" \
  -v model_license="$model_license" \
  -v runtime_identity="$runtime_identity" <<'SQL' >/dev/null
SELECT format(
  'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  :'worker_role',
  :'worker_password'
) \gexec
SELECT otlet.register_model(
  :'model_name',
  :'model_artifact',
  :'model_sha256',
  jsonb_build_object(
    'sha256', :'model_sha256',
    'bytes', :'model_bytes'::bigint,
    'source', :'model_source',
    'revision', :'model_revision',
    'quantization', :'model_quantization',
    'license', :'model_license'
  ),
  1
);
SELECT otlet.grant_portable_worker_access(:'worker_role'::regrole);
SELECT otlet.register_portable_worker(
  :'worker_id',
  :'worker_role'::regrole,
  1,
  :'model_name',
  'otlet-portable-worker',
  '0.1.0',
  :'runtime_identity'::jsonb
);
CREATE TABLE public.otlet_portable_worker_source (
  subject_id text PRIMARY KEY,
  input jsonb NOT NULL
);
INSERT INTO public.otlet_portable_worker_source
VALUES ('real-gguf-1', '{"signal":"retain"}');
SELECT otlet.create_task(
  'portable_worker_demo',
  'SELECT subject_id, input FROM public.otlet_portable_worker_source',
  'Return decision keep',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"const":"keep"}}}'::jsonb,
  :'model_name',
  '{"reasoning":"off","max_tokens":48,"inference_cache":false}'::jsonb,
  '{"source_fields":["signal"]}'::jsonb
);
SELECT otlet.run_task('portable_worker_demo');
SQL

runtime_identity_hash="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" -X -qAt \
    -v ON_ERROR_STOP=1 -v worker_id="$worker_id" <<'SQL'
SELECT runtime_identity_hash
FROM otlet.portable_workers
WHERE worker_id = :'worker_id';
SQL
)"

worker_database_url="postgresql://${worker_role}:${worker_password}@127.0.0.1:5432/${portable_database}"
if ! docker exec \
  -e "OTLET_DATABASE_URL=$worker_database_url" \
  -e "OTLET_PORTABLE_WORKER_ID=$worker_id" \
  -e OTLET_PORTABLE_PROTOCOL_VERSION=1 \
  -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$runtime_identity_hash" \
  -e "OTLET_MODEL_NAME=$model_name" \
  -e "OTLET_MODEL_PATH=$model_artifact" \
  -e "OTLET_MODEL_SHA256=$model_sha256" \
  -e OTLET_PORTABLE_ONCE=1 \
  -e "OTLET_LLAMA_THREADS=${OTLET_LLAMA_THREADS:-4}" \
  "$container" /target/release/otlet_worker --once >"$worker_log" 2>&1; then
  tail -n 120 "$worker_log" >&2
  exit 1
fi

if ! grep -q '"event":"job_completed"' "$worker_log"; then
  tail -n 120 "$worker_log" >&2
  echo "Portable worker did not report a completed job" >&2
  exit 1
fi

contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v model_sha256="$model_sha256" <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*) FROM pg_extension WHERE extname = 'otlet'),
  (SELECT count(*)
   FROM pg_proc p
   JOIN pg_namespace n ON n.oid = p.pronamespace
   JOIN pg_language l ON l.oid = p.prolang
   WHERE n.nspname = 'otlet' AND l.lanname = 'c'),
  j.status,
  o.output ->> 'decision',
  r.status,
  r.selection_status,
  r.schema_validation_status,
  r.runtime_name,
  r.runtime_endpoint,
  (r.model_artifact_hash = :'model_sha256')::text,
  (r.task_identity_hash IS NOT NULL
    AND r.source_identity_hash IS NOT NULL
    AND r.model_identity_hash IS NOT NULL
    AND r.runtime_options_hash IS NOT NULL
    AND r.prompt_hash IS NOT NULL
    AND r.input_hash IS NOT NULL
    AND r.output_schema_hash IS NOT NULL
    AND r.output_hash IS NOT NULL
    AND r.actions_hash IS NOT NULL
    AND r.raw_output_hash IS NOT NULL)::text,
  c.status,
  (l.receipt_id = r.id)::text,
  (SELECT count(*) FROM otlet.outputs output_row WHERE output_row.job_id = j.id),
  (SELECT count(*) FROM otlet.inference_receipts receipt_row WHERE receipt_row.job_id = j.id),
  (SELECT count(*) FROM otlet.actions action_row WHERE action_row.job_id = j.id)
)
FROM otlet.jobs j
JOIN otlet.outputs o ON o.job_id = j.id
JOIN otlet.inference_receipts r ON r.id = o.receipt_id
JOIN otlet.portable_receipt_links l ON l.receipt_id = r.id
JOIN otlet.portable_claims c ON c.id = l.claim_id
WHERE j.task_name = 'portable_worker_demo';
SQL
)"
expected="0|0|complete|keep|complete|accepted|passed|portable:otlet-portable-worker|postgres_rpc|true|true|complete|true|1|1|0"
if [ "$contract" != "$expected" ]; then
  echo "Expected portable external worker contract $expected, got $contract" >&2
  exit 1
fi

source_read="$(
  docker exec -e "PGPASSWORD=$worker_password" "$container" \
    psql -h 127.0.0.1 -U "$worker_role" -d "$portable_database" -X -qAt \
      -c 'SELECT count(*) FROM public.otlet_portable_worker_source' 2>&1 || true
)"
if [[ "$source_read" != *"permission denied"* ]]; then
  echo "Expected the portable worker role to be denied source-table access, got $source_read" >&2
  exit 1
fi

protocol_status="$(
  docker exec -e "PGPASSWORD=$worker_password" "$container" \
    psql -h 127.0.0.1 -U "$worker_role" -d "$portable_database" -X -qAt \
      -c "SELECT count(*) || '|' || bool_and(protocol_version = 1 AND status = 'active')::text FROM otlet.portable_protocol_status"
)"
if [ "$protocol_status" != "1|true" ]; then
  echo "Expected one active protocol visible to the worker, got $protocol_status" >&2
  exit 1
fi

echo "portable_external_worker_contract=$contract|source_access=denied|protocol=1"
