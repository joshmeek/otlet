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
recovery_log="$(mktemp)"
recovery_container="otlet-portable-recovery-worker"
canary="RECOVERY_RAW_EVIDENCE_CANARY"

cleanup() {
  if docker container inspect "$recovery_container" >/dev/null 2>&1; then
    docker rm -f "$recovery_container" >/dev/null 2>&1 || true
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]; then
    docker start "$container" >/dev/null 2>&1 || true
  fi
  rm -f "$worker_log" "$recovery_log"
  docker exec "$container" dropdb -U postgres --if-exists "$portable_database" >/dev/null 2>&1 || true
  docker exec -i "$container" psql -U postgres -d postgres -X -qAt -v ON_ERROR_STOP=1 \
    -v worker_role="$worker_role" <<'SQL' >/dev/null 2>&1 || true
SELECT format('DROP ROLE IF EXISTS %I', :'worker_role') \gexec
SQL
}

trap cleanup EXIT

archive_recovery_worker() {
  if docker container inspect "$recovery_container" >/dev/null 2>&1; then
    docker logs "$recovery_container" >>"$recovery_log" 2>&1 || true
    docker rm -f "$recovery_container" >/dev/null
  fi
}

start_recovery_worker() {
  archive_recovery_worker
  docker run -d \
    --name "$recovery_container" \
    --user 10001:10001 \
    --entrypoint /target/release/otlet_worker \
    -e "OTLET_DATABASE_URL=$external_database_url" \
    -e "OTLET_PORTABLE_WORKER_ID=$worker_id" \
    -e OTLET_PORTABLE_PROTOCOL_VERSION=1 \
    -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$runtime_identity_hash" \
    -e "OTLET_MODEL_NAME=$model_name" \
    -e "OTLET_MODEL_PATH=$model_artifact" \
    -e "OTLET_MODEL_SHA256=$model_sha256" \
    -e OTLET_PORTABLE_REQUIRE_TLS=0 \
    -e OTLET_PORTABLE_EGRESS_MODE=deny_model_providers \
    -e OTLET_PORTABLE_POLL_MS=100 \
    -e OTLET_PORTABLE_RENEW_MS=250 \
    -e "OTLET_LLAMA_THREADS=${OTLET_LLAMA_THREADS:-4}" \
    -v "$postgres_volume:/var/lib/postgresql:ro" \
    -v "$target_volume:/target:ro" \
    "$worker_image" >/dev/null
}

queue_recovery_job() {
  local subject_id="$1"
  local padding="$2"

  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v subject_id="$subject_id" \
    -v padding="$padding" \
    -v canary="$canary" <<'SQL' >/dev/null
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (
  'portable_worker_demo',
  :'subject_id',
  jsonb_build_object(
    'signal',
    :'canary' || ':' || :'subject_id' || repeat(' bounded recovery input', :'padding'::integer)
  )
);
SQL
}

wait_for_job_status() {
  local subject_id="$1"
  local expected="$2"
  local actual=""

  for _ in {1..400}; do
    actual="$(
      docker exec -i "$container" psql -U postgres -d "$portable_database" -X -qAt \
        -v subject_id="$subject_id" <<'SQL'
SELECT status
FROM otlet.jobs
WHERE subject_id = :'subject_id'
ORDER BY id DESC
LIMIT 1;
SQL
    )"
    [ "$actual" = "$expected" ] && return
    sleep 0.1
  done
  echo "Expected recovery job $subject_id to reach $expected, got $actual" >&2
  docker logs --tail 120 "$recovery_container" >&2 || true
  exit 1
}

wait_for_worker_state() {
  local expected="$1"
  local actual=""

  for _ in {1..400}; do
    actual="$(
      docker exec -i "$container" psql -U postgres -d "$portable_database" -X -qAt \
        -v worker_id="$worker_id" <<'SQL'
SELECT reported_state
FROM otlet.portable_workers
WHERE worker_id = :'worker_id';
SQL
    )"
    [ "$actual" = "$expected" ] && return
    sleep 0.1
  done
  echo "Expected portable worker state $expected, got $actual" >&2
  docker logs --tail 120 "$recovery_container" >&2 || true
  exit 1
}

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
  -e OTLET_PORTABLE_REQUIRE_TLS=0 \
  -e OTLET_PORTABLE_EGRESS_MODE=deny_model_providers \
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

worker_image="$(docker inspect -f '{{.Config.Image}}' "$container")"
postgres_volume="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql"}}{{.Name}}{{end}}{{end}}' "$container")"
target_volume="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/target"}}{{.Name}}{{end}}{{end}}' "$container")"
external_database_url="postgresql://${worker_role}:${worker_password}@host.docker.internal:${OTLET_PG_PORT:-55432}/${portable_database}"

docker exec -i "$container" psql -U postgres -d "$portable_database" -X -qAt \
  -v ON_ERROR_STOP=1 -v worker_id="$worker_id" <<'SQL' >/dev/null
SELECT otlet.set_portable_worker_control(:'worker_id', 'paused');
SQL
queue_recovery_job recovery-pause 0
start_recovery_worker
wait_for_worker_state paused
wait_for_job_status recovery-pause queued
docker exec -i "$container" psql -U postgres -d "$portable_database" -X -qAt \
  -v ON_ERROR_STOP=1 -v worker_id="$worker_id" <<'SQL' >/dev/null
SELECT otlet.set_portable_worker_control(:'worker_id', 'running');
SQL
wait_for_job_status recovery-pause complete

queue_recovery_job recovery-cancel 300
wait_for_job_status recovery-cancel running
docker exec -i "$container" psql -U postgres -d "$portable_database" -X -qAt \
  -v ON_ERROR_STOP=1 -v subject_id=recovery-cancel <<'SQL' >/dev/null
SELECT otlet.request_job_cancellation(id, 'portable recovery probe')
FROM otlet.jobs
WHERE subject_id = :'subject_id'
ORDER BY id DESC
LIMIT 1;
SQL
wait_for_job_status recovery-cancel canceled

queue_recovery_job recovery-claim-loss 300
wait_for_job_status recovery-claim-loss running
docker exec -i "$container" psql -U postgres -d "$portable_database" -X -qAt \
  -v ON_ERROR_STOP=1 -v subject_id=recovery-claim-loss <<'SQL' >/dev/null
UPDATE otlet.jobs
SET claim_token = gen_random_uuid()::text,
    leased_until = now() - interval '1 second'
WHERE id = (
  SELECT id
  FROM otlet.jobs
  WHERE subject_id = :'subject_id'
  ORDER BY id DESC
  LIMIT 1
);
SQL
wait_for_job_status recovery-claim-loss complete

queue_recovery_job recovery-worker-loss 300
wait_for_job_status recovery-worker-loss running
docker kill "$recovery_container" >/dev/null
archive_recovery_worker
docker exec -i "$container" psql -U postgres -d "$portable_database" -X -qAt \
  -v ON_ERROR_STOP=1 -v subject_id=recovery-worker-loss <<'SQL' >/dev/null
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second'
WHERE id = (
  SELECT id
  FROM otlet.jobs
  WHERE subject_id = :'subject_id'
  ORDER BY id DESC
  LIMIT 1
);
SQL
start_recovery_worker
wait_for_job_status recovery-worker-loss complete

docker stop "$container" >/dev/null
for _ in {1..100}; do
  if docker logs "$recovery_container" 2>&1 | grep -q '"event":"database_unavailable"'; then
    break
  fi
  sleep 0.1
done
docker start "$container" >/dev/null
for _ in {1..100}; do
  docker exec "$container" pg_isready -U postgres -d "$portable_database" >/dev/null 2>&1 && break
  sleep 0.1
done
if ! docker exec "$container" pg_isready -U postgres -d "$portable_database" >/dev/null 2>&1; then
  echo "Portable recovery database did not restart" >&2
  exit 1
fi
queue_recovery_job recovery-database-restart 0
wait_for_job_status recovery-database-restart complete

docker exec -i "$container" psql -U postgres -d "$portable_database" -X -qAt \
  -v ON_ERROR_STOP=1 -v worker_id="$worker_id" <<'SQL' >/dev/null
SELECT otlet.set_portable_worker_control(:'worker_id', 'draining');
SQL
for _ in {1..400}; do
  [ "$(docker inspect -f '{{.State.Running}}' "$recovery_container")" = "false" ] && break
  sleep 0.1
done
wait_for_worker_state drained
archive_recovery_worker

if grep -Fq "$canary" "$recovery_log"; then
  echo "Portable worker logs exposed raw source evidence" >&2
  exit 1
fi
if awk 'NF && substr($0, 1, 1) != "{" { exit 1 }' "$recovery_log"; then
  :
else
  echo "Portable worker emitted an unstructured log line" >&2
  tail -n 120 "$recovery_log" >&2
  exit 1
fi
while IFS= read -r line; do
  [ -z "$line" ] || printf '%s\n' "$line" | jq -e . >/dev/null
done <"$recovery_log"
for event in job_cancel_observed job_claim_lost job_abandoned database_unavailable database_recovered worker_drained; do
  if ! grep -q "\"event\":\"$event\"" "$recovery_log"; then
    echo "Portable recovery log is missing $event" >&2
    tail -n 120 "$recovery_log" >&2
    exit 1
  fi
done

recovery_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v worker_id="$worker_id" <<'SQL'
WITH job_state AS (
  SELECT
    subject_id,
    status,
    attempts,
    (SELECT count(*) FROM otlet.outputs o WHERE o.job_id = j.id) AS outputs,
    (SELECT count(*) FROM otlet.inference_receipts r WHERE r.job_id = j.id) AS receipts
  FROM otlet.jobs j
  WHERE subject_id LIKE 'recovery-%'
)
SELECT concat_ws('|',
  (SELECT status FROM job_state WHERE subject_id = 'recovery-pause'),
  (SELECT status FROM job_state WHERE subject_id = 'recovery-cancel'),
  (SELECT status || ':' || attempts || ':' || outputs || ':' || receipts
   FROM job_state WHERE subject_id = 'recovery-claim-loss'),
  (SELECT status || ':' || attempts || ':' || outputs || ':' || receipts
   FROM job_state WHERE subject_id = 'recovery-worker-loss'),
  (SELECT status FROM job_state WHERE subject_id = 'recovery-database-restart'),
  (SELECT desired_state || ':' || reported_state || ':' || worker_health || ':' || expired_claims
   FROM otlet.portable_worker_status WHERE worker_id = :'worker_id')
);
SQL
)"
expected_recovery_contract="complete|canceled|complete:2:1:1|complete:2:1:1|complete|draining:drained:drained:0"
if [ "$recovery_contract" != "$expected_recovery_contract" ]; then
  echo "Expected portable recovery contract $expected_recovery_contract, got $recovery_contract" >&2
  exit 1
fi

echo "portable_external_worker_contract=$contract|source_access=denied|protocol=1"
echo "portable_recovery_contract=$recovery_contract|logs=structured_redacted|duplicate=covered_by_protocol"
