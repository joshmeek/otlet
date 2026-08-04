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
cheap_worker_role="otlet_portable_worker_demo_cheap"
cheap_worker_id="portable-worker-demo-cheap"
cheap_model_name="${OTLET_CHEAP_MODEL_NAME:-qwen3_1_7b}"
cheap_model_file="${OTLET_CHEAP_MODEL_FILE:-Qwen3-1.7B-Q8_0.gguf}"
cheap_model_artifact="${OTLET_CHEAP_MODEL_ARTIFACT:-}"
cheap_model_source="${OTLET_CHEAP_MODEL_SOURCE:-local-demo}"
cheap_model_revision="${OTLET_CHEAP_MODEL_REVISION:-main}"
cheap_model_quantization="${OTLET_CHEAP_MODEL_QUANTIZATION:-Q8_0}"
cheap_model_license="${OTLET_CHEAP_MODEL_LICENSE:-apache-2.0}"
worker_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
cheap_worker_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
worker_log="$(mktemp)"
recovery_log="$(mktemp)"
recovery_container="otlet-portable-recovery-worker"
canary="RECOVERY_RAW_EVIDENCE_CANARY"
swap_artifact_dir="/var/lib/postgresql/otlet-portable-artifact-swap-$$"
swap_artifact="$swap_artifact_dir/model.gguf"

cleanup() {
  if docker container inspect "$recovery_container" >/dev/null 2>&1; then
    docker rm -f "$recovery_container" >/dev/null 2>&1 || true
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]; then
    docker start "$container" >/dev/null 2>&1 || true
  fi
  rm -f "$worker_log" "$recovery_log"
  docker exec "$container" rm -rf "$swap_artifact_dir" >/dev/null 2>&1 || true
  docker exec "$container" dropdb -U postgres --if-exists "$portable_database" >/dev/null 2>&1 || true
  docker exec -i "$container" psql -U postgres -d postgres -X -qAt -v ON_ERROR_STOP=1 \
    -v worker_role="$worker_role" \
    -v cheap_worker_role="$cheap_worker_role" <<'SQL' >/dev/null 2>&1 || true
SELECT format('DROP ROLE IF EXISTS %I', :'worker_role') \gexec
SELECT format('DROP ROLE IF EXISTS %I', :'cheap_worker_role') \gexec
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
    -e "PGPASSWORD=$worker_password" \
    -e "OTLET_PORTABLE_WORKER_ID=$worker_id" \
    -e OTLET_PORTABLE_PROTOCOL_VERSION=1 \
    -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$runtime_identity_hash" \
    -e "OTLET_MODEL_NAME=$model_name" \
    -e "OTLET_MODEL_PATH=$model_artifact" \
    -e "OTLET_MODEL_SHA256=$model_sha256" \
    -e OTLET_PORTABLE_REQUIRE_TLS=0 \
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

run_worker_once_for() {
  local active_worker_id="$1"
  local active_database_url="$2"
  local active_database_password="$3"
  local active_model_name="$4"
  local active_model_artifact="$5"
  local active_model_sha256="$6"
  local expected_event="$7"
  local renew_ms="${8:-1000}"

  : >"$worker_log"
  if ! docker exec \
    -e "OTLET_DATABASE_URL=$active_database_url" \
    -e "PGPASSWORD=$active_database_password" \
    -e "OTLET_PORTABLE_WORKER_ID=$active_worker_id" \
    -e OTLET_PORTABLE_PROTOCOL_VERSION=1 \
    -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$runtime_identity_hash" \
    -e "OTLET_MODEL_NAME=$active_model_name" \
    -e "OTLET_MODEL_PATH=$active_model_artifact" \
    -e "OTLET_MODEL_SHA256=$active_model_sha256" \
    -e OTLET_PORTABLE_REQUIRE_TLS=0 \
    -e OTLET_PORTABLE_ONCE=1 \
    -e "OTLET_PORTABLE_RENEW_MS=$renew_ms" \
    -e "OTLET_LLAMA_THREADS=${OTLET_LLAMA_THREADS:-4}" \
    "$container" /target/release/otlet_worker --once >"$worker_log" 2>&1; then
    tail -n 120 "$worker_log" >&2
    exit 1
  fi

  if ! grep -q "\"event\":\"$expected_event\"" "$worker_log"; then
    tail -n 120 "$worker_log" >&2
    echo "Portable worker did not report $expected_event" >&2
    exit 1
  fi
}

run_worker_once() {
  run_worker_once_for \
    "$worker_id" \
    "$worker_database_url" \
    "$worker_password" \
    "$model_name" \
    "$model_artifact" \
    "$model_sha256" \
    job_completed
}

if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
  echo "Container $container is not running. Run ./scripts/otlet-setup.sh first" >&2
  exit 1
fi

cleanup

if [ -z "$model_artifact" ]; then
  model_artifact="$(docker exec "$container" find /var/lib/postgresql -name "$model_file" -type f -print -quit)"
fi
if [ -z "$cheap_model_artifact" ]; then
  cheap_model_artifact="$(docker exec "$container" find /var/lib/postgresql -name "$cheap_model_file" -type f -print -quit)"
fi
if [ -z "$model_artifact" ] || ! docker exec "$container" test -f "$model_artifact"; then
  echo "Missing model artifact. Set OTLET_STRONG_MODEL_ARTIFACT or run ./scripts/otlet-setup.sh first" >&2
  exit 1
fi
if [ -z "$cheap_model_artifact" ] || ! docker exec "$container" test -f "$cheap_model_artifact"; then
  echo "Missing cheap model artifact. Set OTLET_CHEAP_MODEL_ARTIFACT or run ./scripts/otlet-setup.sh first" >&2
  exit 1
fi

model_sha256="$(docker exec "$container" sha256sum "$model_artifact" | awk '{print $1}')"
model_bytes="$(docker exec "$container" stat -Lc %s "$model_artifact")"
cheap_model_sha256="$(docker exec "$container" sha256sum "$cheap_model_artifact" | awk '{print $1}')"
cheap_model_bytes="$(docker exec "$container" stat -Lc %s "$cheap_model_artifact")"

docker exec -e CARGO_TARGET_DIR=/target -w /work "$container" \
  cargo build --locked --quiet --release -p otlet_worker
runtime_identity="$(docker exec "$container" /target/release/otlet_worker --print-runtime-identity)"

docker exec "$container" createdb -U postgres "$portable_database"
docker exec -w /work "$container" psql -U postgres -d "$portable_database" \
  -X -q -v ON_ERROR_STOP=1 -f crates/otlet_worker/sql/install.sql

docker exec -i "$container" psql -U postgres -d "$portable_database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -v worker_role="$worker_role" \
  -v worker_password="$worker_password" \
  -v worker_id="$worker_id" \
  -v cheap_worker_role="$cheap_worker_role" \
  -v cheap_worker_password="$cheap_worker_password" \
  -v cheap_worker_id="$cheap_worker_id" \
  -v model_name="$model_name" \
  -v model_artifact="$model_artifact" \
  -v model_sha256="$model_sha256" \
  -v model_bytes="$model_bytes" \
  -v model_source="$model_source" \
  -v model_revision="$model_revision" \
  -v model_quantization="$model_quantization" \
  -v model_license="$model_license" \
  -v cheap_model_name="$cheap_model_name" \
  -v cheap_model_artifact="$cheap_model_artifact" \
  -v cheap_model_sha256="$cheap_model_sha256" \
  -v cheap_model_bytes="$cheap_model_bytes" \
  -v cheap_model_source="$cheap_model_source" \
  -v cheap_model_revision="$cheap_model_revision" \
  -v cheap_model_quantization="$cheap_model_quantization" \
  -v cheap_model_license="$cheap_model_license" \
  -v runtime_identity="$runtime_identity" <<'SQL' >/dev/null
SELECT format(
  'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  :'worker_role',
  :'worker_password'
) \gexec
SELECT format(
  'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  :'cheap_worker_role',
  :'cheap_worker_password'
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
SELECT otlet.register_model(
  :'cheap_model_name',
  :'cheap_model_artifact',
  :'cheap_model_sha256',
  jsonb_build_object(
    'sha256', :'cheap_model_sha256',
    'bytes', :'cheap_model_bytes'::bigint,
    'source', :'cheap_model_source',
    'revision', :'cheap_model_revision',
    'quantization', :'cheap_model_quantization',
    'license', :'cheap_model_license'
  ),
  1
);
SELECT otlet.grant_portable_worker_access(:'worker_role'::regrole);
SELECT otlet.grant_portable_worker_access(:'cheap_worker_role'::regrole);
SELECT otlet.register_portable_worker(
  :'worker_id',
  :'worker_role'::regrole,
  1,
  :'model_name',
  'otlet-portable-worker',
  '0.1.0',
  :'runtime_identity'::jsonb
);
SELECT otlet.register_portable_worker(
  :'cheap_worker_id',
  :'cheap_worker_role'::regrole,
  1,
  :'cheap_model_name',
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
SELECT otlet.create_task(
  'aaa_portable_runtime_incompatible',
  NULL,
  'Return decision keep',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"const":"keep"}}}'::jsonb,
  :'model_name',
  '{"reasoning":"off","max_tokens":48,"inference_cache":false,"max_worker_rss_bytes":1,"n_gpu_layers":1}'::jsonb
);
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('aaa_portable_runtime_incompatible', 'runtime-incompatible', '{}'::jsonb);
CREATE TABLE public.otlet_portable_routing_source (
  subject_id text PRIMARY KEY,
  input jsonb NOT NULL
);
INSERT INTO public.otlet_portable_routing_source
VALUES ('routing-live', '{"signal":"retain"}');
SELECT otlet.create_task(
  'portable_routing_demo',
  'SELECT subject_id, input FROM public.otlet_portable_routing_source',
  'Return decision keep',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"const":"keep"}}}'::jsonb,
  :'cheap_model_name',
  '{"reasoning":"off","max_tokens":48,"inference_cache":false}'::jsonb,
  '{"source_fields":["signal"]}'::jsonb
);
SELECT otlet.set_model_selection_policy(
  'portable_routing_demo',
  :'cheap_model_name',
  :'model_name',
  '{"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);
SELECT otlet.run_task('portable_routing_demo');
SELECT otlet.create_task(
  'portable_routing_accept_demo',
  'SELECT subject_id, input FROM public.otlet_portable_routing_source',
  'Return decision keep',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"const":"keep"}}}'::jsonb,
  :'cheap_model_name',
  '{"reasoning":"off","max_tokens":48,"inference_cache":false}'::jsonb,
  '{"source_fields":["signal"]}'::jsonb
);
SELECT otlet.set_model_selection_policy(
  'portable_routing_accept_demo',
  :'cheap_model_name',
  :'model_name',
  '{"answer_field":"decision","abstain_values":["reject"]}'::jsonb
);
SELECT otlet.create_task(
  'portable_claim_fence_demo',
  'SELECT subject_id, input FROM public.otlet_portable_routing_source',
  'Return decision keep',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"const":"keep"}}}'::jsonb,
  :'cheap_model_name',
  '{"reasoning":"off","max_tokens":48,"inference_cache":false}'::jsonb,
  '{"source_fields":["signal"]}'::jsonb
);
SELECT otlet.set_model_selection_policy(
  'portable_claim_fence_demo',
  :'cheap_model_name',
  :'model_name',
  '{"answer_field":"decision","abstain_values":["reject"]}'::jsonb
);
CREATE TABLE public.otlet_portable_watch_source (
  subject_id text PRIMARY KEY,
  signal text NOT NULL
);
SELECT otlet.create_watch(
  watch_name => 'portable_row_watch',
  kind => 'row',
  instruction => 'Return decision keep',
  output_schema => '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"const":"keep"}}}'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_portable_watch_source'::regclass,
  subject_column => 'subject_id',
  record_type => 'portable_row_decision',
  runtime_options => '{"reasoning":"off","max_tokens":48,"inference_cache":false}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  input_columns => ARRAY['signal']::text[]
);
CREATE TABLE public.otlet_portable_pair_source (
  subject_id text PRIMARY KEY,
  signal text NOT NULL
);
INSERT INTO public.otlet_portable_pair_source VALUES
  ('pair-left', 'retain'),
  ('pair-right', 'retain');
SELECT otlet.create_watch(
  watch_name => 'portable_pair_watch',
  kind => 'pair',
  instruction => 'Return decision keep',
  output_schema => '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"const":"keep"}}}'::jsonb,
  model_name => :'model_name',
  candidate_query => $query$
    SELECT
      left_row.subject_id || ':' || right_row.subject_id AS subject_id,
      jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', 'public.otlet_portable_pair_source',
          'subject_id', left_row.subject_id,
          'right_id', right_row.subject_id
        ),
        'left', to_jsonb(left_row),
        'right', to_jsonb(right_row)
      ) AS input
    FROM public.otlet_portable_pair_source left_row
    JOIN public.otlet_portable_pair_source right_row
      ON left_row.subject_id < right_row.subject_id
  $query$,
  record_type => 'portable_pair_decision',
  runtime_options => '{"reasoning":"off","max_tokens":48,"inference_cache":false}'::jsonb,
  input_shaping => '{"source_fields":["_otlet_mvcc","left","right"]}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  max_candidate_rows => 4,
  pair_sources => '[{"table":"public.otlet_portable_pair_source","subject_column":"subject_id"}]'::jsonb
);
SQL

invalid_input="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v model_name="$model_name" <<'SQL' 2>&1 || true
SELECT otlet.enqueue_ask(
  :'model_name',
  'Return decision keep',
  '[]'::jsonb,
  '{"type":"object"}'::jsonb
);
SQL
)"
if [[ "$invalid_input" != *"otlet ask input must be a JSON object"* ]]; then
  echo "Expected enqueue_ask to reject a non-object input, got $invalid_input" >&2
  exit 1
fi

admission_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v model_name="$model_name" <<'SQL'
BEGIN;
UPDATE otlet.production_policy
SET max_input_bytes_per_job = 1
WHERE name = 'default';
SELECT (otlet.enqueue_ask(
  :'model_name',
  'Return decision keep',
  '{"signal":"retain"}'::jsonb,
  '{"type":"object"}'::jsonb
) = 0)::text;
ROLLBACK;
SQL
)"
if [ "$admission_contract" != "true" ]; then
  echo "Expected enqueue_ask admission rejection to return zero, got $admission_contract" >&2
  exit 1
fi

async_job_id="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v model_name="$model_name" <<'SQL'
BEGIN;
SELECT otlet.enqueue_ask(
  :'model_name',
  'Return decision keep',
  '{"signal":"retain"}'::jsonb,
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"const":"keep"}}}'::jsonb,
  '{"reasoning":"off","max_tokens":48,"inference_cache":false,"llama_threads":2,"llama_batch_threads":3}'::jsonb
) AS async_job_id \gset
COMMIT;
SELECT :'async_job_id';
SQL
)"
if [[ ! "$async_job_id" =~ ^[1-9][0-9]*$ ]]; then
  echo "Expected enqueue_ask to return a positive job ID, got $async_job_id" >&2
  exit 1
fi

async_queued_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v async_job_id="$async_job_id" <<'SQL'
SELECT concat_ws('|',
  status,
  (output IS NULL)::text,
  (receipt_id IS NULL)::text,
  (task_name LIKE 'ask_%')::text
)
FROM otlet.runs
WHERE job_id = :'async_job_id'::bigint;
SQL
)"
if [ "$async_queued_contract" != "queued|true|true|true" ]; then
  echo "Expected queued asynchronous ask state, got $async_queued_contract" >&2
  exit 1
fi

runtime_identity_hash="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" -X -qAt \
    -v ON_ERROR_STOP=1 -v worker_id="$worker_id" <<'SQL'
SELECT runtime_identity_hash
FROM otlet.portable_workers
WHERE worker_id = :'worker_id';
SQL
)"

worker_database_url="postgresql://${worker_role}@127.0.0.1:5432/${portable_database}"
cheap_worker_database_url="postgresql://${cheap_worker_role}@127.0.0.1:5432/${portable_database}"

docker exec "$container" mkdir -p "$swap_artifact_dir"
docker exec "$container" ln "$model_artifact" "$swap_artifact"
docker exec -i "$container" psql -U postgres -d "$portable_database" \
  -X -qAt -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE FUNCTION public.portable_artifact_swap_delay() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_sleep(5);
  RETURN NEW;
END;
$$;
CREATE TRIGGER portable_artifact_swap_delay
BEFORE UPDATE ON otlet.portable_workers
FOR EACH ROW
WHEN (OLD.incarnation_nonce_hash IS DISTINCT FROM NEW.incarnation_nonce_hash)
EXECUTE FUNCTION public.portable_artifact_swap_delay();
SQL

: >"$worker_log"
docker exec \
  -e "OTLET_DATABASE_URL=$worker_database_url" \
  -e "PGPASSWORD=$worker_password" \
  -e "OTLET_PORTABLE_WORKER_ID=$worker_id" \
  -e OTLET_PORTABLE_PROTOCOL_VERSION=1 \
  -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$runtime_identity_hash" \
  -e "OTLET_MODEL_NAME=$model_name" \
  -e "OTLET_MODEL_PATH=$swap_artifact" \
  -e "OTLET_MODEL_SHA256=$model_sha256" \
  -e OTLET_PORTABLE_REQUIRE_TLS=0 \
  -e OTLET_PORTABLE_ONCE=1 \
  "$container" /target/release/otlet_worker --once >"$worker_log" 2>&1 &
swap_worker_pid=$!

swap_waiting="false"
for _ in {1..100}; do
  swap_waiting="$(
    docker exec "$container" psql -U postgres -d "$portable_database" -X -qAt \
      -c "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '$portable_database' AND wait_event = 'PgSleep' AND query LIKE '%portable_start_worker%')"
  )"
  [ "$swap_waiting" = "t" ] && break
  sleep 0.05
done
if [ "$swap_waiting" != "t" ]; then
  wait "$swap_worker_pid" || true
  tail -n 120 "$worker_log" >&2
  echo "Portable artifact swap did not reach the load window" >&2
  exit 1
fi
docker exec "$container" sh -c 'rm -f "$1" && ln -s "$2" "$1"' sh "$swap_artifact" "$model_artifact"
set +e
wait "$swap_worker_pid"
swap_worker_status=$?
set -e
if [ "$swap_worker_status" = "0" ] || ! grep -q '"reason":"model_artifact_path_replaced"' "$worker_log"; then
  tail -n 120 "$worker_log" >&2
  echo "Expected portable load-window replacement to fail closed" >&2
  exit 1
fi

portable_artifact_swap_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v worker_id="$worker_id" -v async_job_id="$async_job_id" <<'SQL'
SELECT concat_ws('|',
  worker.reported_state,
  worker.model_status,
  worker.last_error_code,
  job.status,
  (SELECT count(*) FROM otlet.portable_claims claim WHERE claim.job_id = job.id),
  (SELECT count(*) FROM otlet.inference_receipts receipt WHERE receipt.job_id = job.id),
  (SELECT count(*) FROM otlet.outputs output_row WHERE output_row.job_id = job.id)
)
FROM otlet.portable_workers worker
CROSS JOIN otlet.jobs job
WHERE worker.worker_id = :'worker_id'
  AND job.id = :'async_job_id'::bigint;
SQL
)"
if [ "$portable_artifact_swap_contract" != "error|error|model_artifact_path_replaced|queued|0|0|0" ]; then
  echo "Expected SQL-visible portable artifact replacement failure, got $portable_artifact_swap_contract" >&2
  exit 1
fi
echo "portable_artifact_swap_contract=$portable_artifact_swap_contract"
docker exec -i "$container" psql -U postgres -d "$portable_database" \
  -X -qAt -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
DROP TRIGGER portable_artifact_swap_delay ON otlet.portable_workers;
DROP FUNCTION public.portable_artifact_swap_delay();
SQL
docker exec "$container" rm -rf "$swap_artifact_dir"

run_worker_once

contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v model_sha256="$model_sha256" \
    -v async_job_id="$async_job_id" <<'SQL'
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
WHERE j.id = :'async_job_id'::bigint;
SQL
)"
expected="0|0|complete|keep|complete|accepted|passed|portable:otlet-portable-worker|postgres_rpc|true|true|complete|true|1|1|0"
if [ "$contract" != "$expected" ]; then
  echo "Expected portable external worker contract $expected, got $contract" >&2
  exit 1
fi

portable_runtime_contract_query() {
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v model_sha256="$model_sha256" \
    -v model_bytes="$model_bytes" \
    -v async_job_id="$async_job_id" <<'SQL'
WITH receipt_contract AS (
  SELECT
    receipt.trace_summary,
    receipt.trace_summary -> 'runtime_options_status' AS option_status,
    claim.runtime_options_status AS claim_option_status
  FROM otlet.inference_receipts receipt
  JOIN otlet.portable_receipt_links link ON link.receipt_id = receipt.id
  JOIN otlet.portable_claims claim ON claim.id = link.claim_id
  WHERE receipt.job_id = :'async_job_id'::bigint
), incompatible_state AS (
  SELECT
    job.status,
    job.attempts,
    (SELECT count(*) FROM otlet.portable_claims claim WHERE claim.job_id = job.id) AS claims,
    (SELECT count(*) FROM otlet.inference_receipts receipt WHERE receipt.job_id = job.id) AS receipts
  FROM otlet.jobs job
  WHERE job.task_name = 'aaa_portable_runtime_incompatible'
    AND job.subject_id = 'runtime-incompatible'
)
SELECT concat_ws('|',
  contract.option_status ->> 'version',
  (
    contract.option_status ->> 'compatible' = 'true'
    AND contract.option_status = contract.claim_option_status
  )::text,
  (
    contract.option_status -> 'requested' =
      '{"reasoning":"off","max_tokens":48,"inference_cache":false,"llama_threads":2,"llama_batch_threads":3}'::jsonb
    AND contract.option_status -> 'honored' =
      '{"reasoning":"off","max_tokens":48,"inference_cache":false,"llama_threads":2,"llama_batch_threads":3}'::jsonb
  )::text,
  (
    contract.option_status -> 'defaulted' ?&
      ARRAY['max_attempt_ms','max_worker_rss_bytes','generation_trace']
    AND (SELECT count(*) FROM jsonb_object_keys(contract.option_status -> 'defaulted')) = 3
    AND (contract.option_status #>> '{defaulted,max_attempt_ms}')::bigint > 0
    AND (contract.option_status #>> '{defaulted,max_worker_rss_bytes}')::bigint > 0
    AND contract.option_status #> '{defaulted,generation_trace}' = 'false'::jsonb
    AND contract.option_status -> 'rejected' = '{}'::jsonb
    AND contract.option_status -> 'effective' =
      (contract.option_status -> 'honored') || (contract.option_status -> 'defaulted')
  )::text,
  (
    contract.option_status #>> '{envelope,model_artifact_hash}' = :'model_sha256'
    AND (contract.option_status #>> '{envelope,model_artifact_bytes}')::bigint = :'model_bytes'::bigint
    AND (contract.option_status #>> '{envelope,context_window_tokens}')::integer = 4096
    AND (contract.option_status #>> '{envelope,batch_tokens}')::integer = 512
    AND (contract.option_status #>> '{envelope,ubatch_tokens}')::integer = 128
    AND contract.option_status #>> '{envelope,load_policy}' = 'eager_single_resident_model'
    AND contract.option_status #>> '{envelope,device_policy}' = 'cpu_only_n_gpu_layers_0'
    AND contract.option_status #>> '{envelope,rss_policy}' = 'linux_proc_status_vmrss_fail_closed'
  )::text,
  (
    (contract.option_status #>> '{envelope,max_worker_rss_bytes}')::bigint > 0
    AND (contract.option_status #>> '{envelope,current_rss_bytes}')::bigint > 0
    AND (contract.option_status #>> '{envelope,current_rss_bytes}')::bigint <=
      (contract.option_status #>> '{envelope,max_worker_rss_bytes}')::bigint
    AND contract.trace_summary #>> '{memory,claim,process_rss_bytes}' =
      contract.option_status #>> '{envelope,current_rss_bytes}'
    AND (contract.trace_summary #>> '{memory,after,process_rss_bytes}')::bigint > 0
    AND (contract.trace_summary #>> '{memory,after,process_rss_bytes}')::bigint <=
      (contract.option_status #>> '{envelope,max_worker_rss_bytes}')::bigint
    AND contract.trace_summary #>> '{memory,worker_memory_budget_bytes}' =
      contract.option_status #>> '{envelope,max_worker_rss_bytes}'
    AND contract.trace_summary #>> '{memory,admission,decision}' = 'allowed'
    AND contract.trace_summary #>> '{memory,post_inference_enforcement,decision}' = 'allowed'
  )::text,
  (
    contract.trace_summary #>> '{runtime_fingerprint,artifact,sha256}' = :'model_sha256'
    AND (contract.trace_summary #>> '{runtime_fingerprint,artifact,bytes}')::bigint = :'model_bytes'::bigint
    AND contract.trace_summary #>> '{runtime_fingerprint,artifact,verification}' = 'sha256_verified_file_descriptor_load'
    AND (contract.trace_summary #>> '{runtime_fingerprint,context,tokens}')::integer = 4096
    AND (contract.trace_summary #>> '{runtime_fingerprint,context,batch_tokens}')::integer = 512
    AND (contract.trace_summary #>> '{runtime_fingerprint,context,ubatch_tokens}')::integer = 128
    AND contract.trace_summary #>> '{runtime_fingerprint,runtime,load_policy}' = 'eager_single_resident_model'
    AND contract.trace_summary #>> '{runtime_fingerprint,runtime,device_policy}' = 'cpu_only_n_gpu_layers_0'
    AND contract.trace_summary #>> '{runtime_fingerprint,runtime,rss_policy}' = 'linux_proc_status_vmrss_fail_closed'
    AND contract.trace_summary ->> 'model_cache_hit' = 'true'
    AND contract.trace_summary ->> 'inference_cache_hit' = 'false'
  )::text,
  (
    (contract.option_status #>> '{effective,llama_threads}')::integer = 2
    AND (contract.option_status #>> '{effective,llama_batch_threads}')::integer = 3
    AND (contract.trace_summary ->> 'effective_llama_threads')::integer = 2
    AND (contract.trace_summary ->> 'effective_llama_batch_threads')::integer = 3
    AND (contract.trace_summary #>> '{runtime_fingerprint,context,decode_threads}')::integer = 2
    AND (contract.trace_summary #>> '{runtime_fingerprint,context,batch_threads}')::integer = 3
  )::text,
  incompatible.status,
  incompatible.attempts,
  incompatible.claims,
  incompatible.receipts
)
FROM receipt_contract contract
CROSS JOIN incompatible_state incompatible;
SQL
}
portable_runtime_contract="$(portable_runtime_contract_query)"
expected_portable_runtime_contract="otlet_portable_runtime_options_status_v1|true|true|true|true|true|true|true|queued|0|0|0"
if [ "$portable_runtime_contract" != "$expected_portable_runtime_contract" ]; then
  echo "Expected portable runtime contract $expected_portable_runtime_contract, got $portable_runtime_contract" >&2
  exit 1
fi
echo "portable_runtime_contract=$portable_runtime_contract"
docker exec -i "$container" psql -U postgres -d "$portable_database" \
  -X -qAt -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
DELETE FROM otlet.jobs
WHERE task_name = 'aaa_portable_runtime_incompatible'
  AND subject_id = 'runtime-incompatible';
SQL

async_result_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v async_job_id="$async_job_id" <<'SQL'
SELECT concat_ws('|',
  status,
  output ->> 'decision',
  (receipt_id IS NOT NULL)::text,
  (raw_output_hash IS NOT NULL)::text
)
FROM otlet.runs
WHERE job_id = :'async_job_id'::bigint;
SQL
)"
if [ "$async_result_contract" != "complete|keep|true|true" ]; then
  echo "Expected completed asynchronous ask result, got $async_result_contract" >&2
  exit 1
fi

non_watch_scalar_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v async_job_id="$async_job_id" <<'SQL'
BEGIN;
UPDATE otlet.outputs
SET output = '"scalar"'::jsonb
WHERE job_id = :'async_job_id'::bigint;
SELECT (otlet.materialize_completed_semantic_job(:'async_job_id'::bigint) = 0)::text;
ROLLBACK;
SQL
)"
if [ "$non_watch_scalar_contract" != "true" ]; then
  echo "Expected scalar non-watch output to skip semantic materialization, got $non_watch_scalar_contract" >&2
  exit 1
fi

deadline_job_id="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v model_name="$model_name" <<'SQL'
SELECT otlet.create_task(
  'portable_attempt_deadline_demo',
  NULL,
  'Read the full signal and return decision keep',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"const":"keep"}}}'::jsonb,
  :'model_name',
  '{"reasoning":"off","max_tokens":512,"max_attempt_ms":1000,"inference_cache":false}'::jsonb,
  '{"source_fields":["signal"]}'::jsonb
) \g /dev/null
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (
  'portable_attempt_deadline_demo',
  'deadline',
  jsonb_build_object('signal', repeat('bounded portable deadline input ', 400))
)
RETURNING id;
SQL
)"
if [[ ! "$deadline_job_id" =~ ^[1-9][0-9]*$ ]]; then
  echo "Expected portable deadline job ID, got $deadline_job_id" >&2
  exit 1
fi

run_worker_once_for \
  "$worker_id" \
  "$worker_database_url" \
  "$worker_password" \
  "$model_name" \
  "$model_artifact" \
  "$model_sha256" \
  job_failed \
  250

if ! grep -q '"reason":"attempt_timeout"' "$worker_log"; then
  tail -n 120 "$worker_log" >&2
  echo "Portable deadline worker did not report attempt_timeout" >&2
  exit 1
fi

portable_deadline_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v job_id="$deadline_job_id" <<'SQL'
SELECT concat_ws('|',
  job.status,
  job.error,
  receipt.selection_reason,
  receipt.trace_summary ->> 'stop_reason',
  receipt.schema_validation_status,
  claim.status,
  (claim.last_renewed_at IS NOT NULL)::text,
  (claim.last_renewed_at < status.attempt_deadline_at)::text,
  (SELECT count(*) FROM otlet.inference_receipts r WHERE r.job_id = job.id),
  (SELECT count(*) FROM otlet.outputs output WHERE output.job_id = job.id)
)
FROM otlet.jobs job
JOIN otlet.portable_claims claim ON claim.job_id = job.id
JOIN otlet.portable_claim_status status ON status.claim_id = claim.id
JOIN otlet.inference_receipts receipt ON receipt.job_id = job.id
WHERE job.id = :'job_id'::bigint;
SQL
)"
expected_portable_deadline_contract="failed|attempt_timeout|attempt_timeout|attempt_timeout|failed|failed|true|true|1|0"
if [ "$portable_deadline_contract" != "$expected_portable_deadline_contract" ]; then
  echo "Expected portable deadline contract $expected_portable_deadline_contract, got $portable_deadline_contract" >&2
  exit 1
fi
echo "portable_deadline_contract=$portable_deadline_contract"

run_worker_once_for \
  "$cheap_worker_id" \
  "$cheap_worker_database_url" \
  "$cheap_worker_password" \
  "$cheap_model_name" \
  "$cheap_model_artifact" \
  "$cheap_model_sha256" \
  job_escalated

routing_handoff_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v cheap_model_name="$cheap_model_name" \
    -v model_name="$model_name" <<'SQL'
SELECT concat_ws('|',
  j.status,
  CASE WHEN j.routed_model_name = :'model_name' THEN 'strong' END,
  j.routed_model_name,
  j.attempts,
  count(r.id),
  count(r.id) FILTER (
    WHERE r.selection_role = 'cheap'
      AND r.selection_status = 'rejected'
      AND r.model_name = :'cheap_model_name'
  ),
  count(c.id) FILTER (WHERE c.status = 'replaced'),
  (SELECT queued_jobs
   FROM otlet.portable_worker_status
   WHERE worker_id = 'portable-worker-demo')
)
FROM otlet.jobs j
LEFT JOIN otlet.inference_receipts r ON r.job_id = j.id
LEFT JOIN otlet.portable_receipt_links link ON link.receipt_id = r.id
LEFT JOIN otlet.portable_claims c ON c.id = link.claim_id
WHERE j.task_name = 'portable_routing_demo'
  AND j.subject_id = 'routing-live'
GROUP BY j.id;
SQL
)"
if [ "$routing_handoff_contract" != "queued|strong|$model_name|0|1|1|1|1" ]; then
  echo "Expected portable cheap-to-strong handoff, got $routing_handoff_contract" >&2
  exit 1
fi

run_worker_once

routing_complete_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v cheap_model_name="$cheap_model_name" \
    -v model_name="$model_name" <<'SQL'
SELECT concat_ws('|',
  j.status,
  o.output ->> 'decision',
  j.attempts,
  count(r.id),
  count(r.id) FILTER (
    WHERE r.selection_role = 'cheap'
      AND r.selection_status = 'rejected'
      AND r.model_name = :'cheap_model_name'
  ),
  count(r.id) FILTER (
    WHERE r.selection_role = 'strong'
      AND r.selection_status = 'accepted'
      AND r.model_name = :'model_name'
      AND r.selection_reason = 'escalated_after_cheap_rejection'
  ),
  count(c.id) FILTER (WHERE c.status = 'replaced'),
  count(c.id) FILTER (WHERE c.status = 'complete')
)
FROM otlet.jobs j
JOIN otlet.outputs o ON o.job_id = j.id
JOIN otlet.inference_receipts r ON r.job_id = j.id
JOIN otlet.portable_receipt_links link ON link.receipt_id = r.id
JOIN otlet.portable_claims c ON c.id = link.claim_id
WHERE j.task_name = 'portable_routing_demo'
  AND j.subject_id = 'routing-live'
GROUP BY j.id, o.id;
SQL
)"
if [ "$routing_complete_contract" != "complete|keep|1|2|1|1|1|1" ]; then
  echo "Expected completed portable model routing, got $routing_complete_contract" >&2
  exit 1
fi

docker exec -i "$container" psql -U postgres -d "$portable_database" \
  -X -qAt -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
SELECT otlet.run_task('portable_routing_accept_demo');
SQL

run_worker_once_for \
  "$cheap_worker_id" \
  "$cheap_worker_database_url" \
  "$cheap_worker_password" \
  "$cheap_model_name" \
  "$cheap_model_artifact" \
  "$cheap_model_sha256" \
  job_completed

routing_accept_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v cheap_model_name="$cheap_model_name" <<'SQL'
SELECT concat_ws('|',
  j.status,
  o.output ->> 'decision',
  j.attempts,
  j.routed_model_name IS NULL,
  count(r.id),
  count(r.id) FILTER (
    WHERE r.selection_role = 'cheap'
      AND r.selection_status = 'accepted'
      AND r.model_name = :'cheap_model_name'
  ),
  count(c.id) FILTER (WHERE c.status = 'complete')
)
FROM otlet.jobs j
JOIN otlet.outputs o ON o.job_id = j.id
JOIN otlet.inference_receipts r ON r.job_id = j.id
JOIN otlet.portable_receipt_links link ON link.receipt_id = r.id
JOIN otlet.portable_claims c ON c.id = link.claim_id
WHERE j.task_name = 'portable_routing_accept_demo'
  AND j.subject_id = 'routing-live'
GROUP BY j.id, o.id;
SQL
)"
if [ "$routing_accept_contract" != "complete|keep|1|t|1|1|1" ]; then
  echo "Expected a portable cheap result to complete without escalation, got $routing_accept_contract" >&2
  exit 1
fi

docker exec -i "$container" psql -U postgres -d "$portable_database" \
  -X -qAt -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
SELECT otlet.run_task('portable_claim_fence_demo');
SQL

claim_metadata_contract="$(
  docker exec -i \
    -e "PGPASSWORD=$cheap_worker_password" \
    -e "PGOPTIONS=-c otlet.probe_worker_id=$cheap_worker_id -c otlet.probe_runtime_hash=$runtime_identity_hash -c otlet.probe_cheap_model=$cheap_model_name" \
    "$container" \
    psql -h 127.0.0.1 -U "$cheap_worker_role" -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT pg_catalog.set_config(
  'otlet.probe_incarnation',
  started.incarnation_nonce,
  true
)
FROM otlet.portable_start_worker(
  current_setting('otlet.probe_worker_id'),
  1,
  current_setting('otlet.probe_runtime_hash')
) started
\g /dev/null
DO $$
DECLARE
  claim_row record;
  cleanup_status text;
BEGIN
  SELECT *
  INTO claim_row
  FROM otlet.portable_claim_jobs(
    current_setting('otlet.probe_worker_id'),
    1,
    current_setting('otlet.probe_runtime_hash'),
    current_setting('otlet.probe_incarnation'),
    1048576,
    6,
    1
  );
  IF claim_row.selection_role IS DISTINCT FROM 'cheap'
     OR claim_row.model ->> 'name' IS DISTINCT FROM current_setting('otlet.probe_cheap_model') THEN
    RAISE EXCEPTION 'portable claim returned incorrect model metadata';
  END IF;

  SELECT job_status
  INTO cleanup_status
  FROM otlet.portable_fail_job(
    current_setting('otlet.probe_worker_id'),
    1,
    current_setting('otlet.probe_runtime_hash'),
    current_setting('otlet.probe_incarnation'),
    claim_row.job_id,
    claim_row.claim_token,
    'claim metadata probe cleanup',
    raw_output => '{"output":{"decision":"keep"},"actions":[]}'
  );
  IF cleanup_status IS DISTINCT FROM 'queued' THEN
    RAISE EXCEPTION 'portable claim metadata cleanup did not requeue';
  END IF;
END;
$$;
SELECT 'cheap|' || current_setting('otlet.probe_cheap_model') || '|queued';
COMMIT;
SQL
)"
claim_metadata_contract+="|$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v cheap_model_name="$cheap_model_name" <<'SQL'
SELECT id AS metadata_job_id
FROM otlet.jobs
WHERE task_name = 'portable_claim_fence_demo'
  AND subject_id = 'routing-live'
ORDER BY id DESC
LIMIT 1
\gset
SELECT status AS cancellation_status
FROM otlet.request_job_cancellation(:'metadata_job_id'::bigint, 'claim metadata probe cleanup')
\gset
SELECT concat_ws('|',
  :'cancellation_status',
  claim.selection_role,
  claim.claim_status,
  receipt.model_name,
  receipt.selection_role,
  receipt.status,
  (
    SELECT count(*)
    FROM otlet.inference_receipts attempted
    WHERE attempted.job_id = claim.job_id
      AND attempted.model_name = :'cheap_model_name'
      AND attempted.selection_role = 'cheap'
      AND attempted.status = 'failed'
  )
)
FROM otlet.portable_claim_status claim
CROSS JOIN LATERAL (
  SELECT r.model_name, r.selection_role, r.status
  FROM otlet.inference_receipts r
  WHERE r.job_id = claim.job_id
  ORDER BY r.id DESC
  LIMIT 1
) receipt
WHERE claim.job_id = :'metadata_job_id'::bigint;
SQL
)"
if [ "$claim_metadata_contract" != "cheap|$cheap_model_name|queued|canceled|cheap|replaced|$model_name|strong|canceled|1" ]; then
  echo "Expected portable RPCs to preserve server-owned model metadata, got $claim_metadata_contract" >&2
  exit 1
fi

docker exec -i "$container" psql -U postgres -d "$portable_database" \
  -X -qAt -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
SELECT otlet.run_task('portable_claim_fence_demo');
SQL

routing_failure_contract="$(
  docker exec -i \
    -e "PGPASSWORD=$cheap_worker_password" \
    -e "PGOPTIONS=-c otlet.probe_worker_id=$cheap_worker_id -c otlet.probe_runtime_hash=$runtime_identity_hash -c otlet.probe_cheap_model=$cheap_model_name" \
    "$container" \
    psql -h 127.0.0.1 -U "$cheap_worker_role" -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT pg_catalog.set_config(
  'otlet.probe_incarnation',
  started.incarnation_nonce,
  true
)
FROM otlet.portable_start_worker(
  current_setting('otlet.probe_worker_id'),
  1,
  current_setting('otlet.probe_runtime_hash')
) started
\g /dev/null
DO $$
DECLARE
  claim_row record;
  failure_status text;
BEGIN
  SELECT *
  INTO claim_row
  FROM otlet.portable_claim_jobs(
    current_setting('otlet.probe_worker_id'),
    1,
    current_setting('otlet.probe_runtime_hash'),
    current_setting('otlet.probe_incarnation'),
    1048576,
    6,
    1
  );
  SELECT job_status
  INTO failure_status
  FROM otlet.portable_fail_job(
    current_setting('otlet.probe_worker_id'),
    1,
    current_setting('otlet.probe_runtime_hash'),
    current_setting('otlet.probe_incarnation'),
    claim_row.job_id,
    claim_row.claim_token,
    'cheap runtime failure'
  );
  IF claim_row.selection_role IS DISTINCT FROM 'cheap'
     OR failure_status IS DISTINCT FROM 'failed' THEN
    RAISE EXCEPTION 'cheap runtime failure did not remain terminal';
  END IF;
END;
$$;
SELECT 'runtime=failed';
COMMIT;
SQL
)"
if [ "$routing_failure_contract" != "runtime=failed" ]; then
  echo "Expected a cheap runtime failure without output to remain terminal, got $routing_failure_contract" >&2
  exit 1
fi

routed_recovery_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v model_name="$model_name" <<'SQL'
INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  routed_model_name,
  status,
  attempts,
  leased_until,
  claim_token,
  started_at
)
SELECT
  'portable_claim_fence_demo',
  'routing-expired',
  '{"signal":"retain"}'::jsonb,
  :'model_name',
  'running',
  max_attempts,
  now() - interval '1 second',
  gen_random_uuid()::text,
  now() - interval '1 minute'
FROM otlet.production_policy
WHERE name = 'default'
RETURNING id AS routed_recovery_job_id
\gset
SELECT otlet.sweep_expired_jobs() > 0 AS swept
\gset
SELECT concat_ws('|',
  :'swept',
  job.status,
  receipt.model_name,
  receipt.selection_role,
  receipt.status,
  receipt.selection_reason
)
FROM otlet.jobs job
JOIN LATERAL (
  SELECT r.model_name, r.selection_role, r.status, r.selection_reason
  FROM otlet.inference_receipts r
  WHERE r.job_id = job.id
  ORDER BY r.id DESC
  LIMIT 1
) receipt ON true
WHERE job.id = :'routed_recovery_job_id'::bigint;
SQL
)"
if [ "$routed_recovery_contract" != "t|failed|$model_name|strong|failed|job_lease_expired_after_max_attempts" ]; then
  echo "Expected expired routed work to fail against the strong model, got $routed_recovery_contract" >&2
  exit 1
fi

watch_insert_job_id="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
INSERT INTO public.otlet_portable_watch_source
VALUES ('watch-live', 'retain');
SELECT j.id AS watch_insert_job_id
FROM otlet.jobs j
JOIN otlet.watches w ON w.task_name = j.task_name
WHERE w.name = 'portable_row_watch'
  AND j.subject_id = 'watch-live'
  AND j.status = 'queued'
ORDER BY j.id DESC
LIMIT 1
\gset
COMMIT;
SELECT :'watch_insert_job_id';
SQL
)"
if [[ ! "$watch_insert_job_id" =~ ^[1-9][0-9]*$ ]]; then
  echo "Expected the row-watch insert to queue a job, got $watch_insert_job_id" >&2
  exit 1
fi

watch_queued_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v watch_job_id="$watch_insert_job_id" <<'SQL'
SELECT concat_ws('|',
  (SELECT status FROM otlet.jobs WHERE id = :'watch_job_id'::bigint),
  (SELECT count(*) FROM otlet.semantic_index_current_rows('portable_row_watch')),
  plan.runtime_name,
  plan.infer_now_subjects
)
FROM otlet.semantic_index_plan('portable_row_watch', true) plan;
SQL
)"
if [ "$watch_queued_contract" != "queued|0|portable_external_worker|0" ]; then
  echo "Expected a committed portable row-watch job with queue-only status, got $watch_queued_contract" >&2
  exit 1
fi

run_worker_once

watch_insert_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v watch_job_id="$watch_insert_job_id" <<'SQL'
SELECT concat_ws('|',
  (SELECT status FROM otlet.jobs WHERE id = :'watch_job_id'::bigint),
  (SELECT body ->> 'decision'
   FROM otlet.semantic_index_current_rows('portable_row_watch')
   WHERE subject_id = 'watch-live'),
  (SELECT stale::text
   FROM otlet.semantic_index_current_rows('portable_row_watch')
   WHERE subject_id = 'watch-live'),
  (SELECT count(*)
   FROM otlet.semantic_materializations
   WHERE subject_id = 'watch-live'),
  (SELECT (trace_summary ? 'materialize_ms')::text
   FROM otlet.inference_receipts
   WHERE job_id = :'watch_job_id'::bigint
   ORDER BY id DESC
   LIMIT 1),
  plan.total_subjects,
  plan.fresh_subjects,
  plan.stale_subjects,
  plan.missing_subjects,
  plan.runtime_name,
  plan.infer_now_subjects
)
FROM otlet.semantic_index_plan('portable_row_watch', true) plan;
SQL
)"
expected_watch_insert="complete|keep|false|1|true|1|1|0|0|portable_external_worker|0"
if [ "$watch_insert_contract" != "$expected_watch_insert" ]; then
  echo "Expected portable row-watch insert contract $expected_watch_insert, got $watch_insert_contract" >&2
  exit 1
fi

watch_update_job_id="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
UPDATE public.otlet_portable_watch_source
SET signal = 'retain updated'
WHERE subject_id = 'watch-live';
SELECT j.id AS watch_update_job_id
FROM otlet.jobs j
JOIN otlet.watches w ON w.task_name = j.task_name
WHERE w.name = 'portable_row_watch'
  AND j.subject_id = 'watch-live'
  AND j.status = 'queued'
ORDER BY j.id DESC
LIMIT 1
\gset
COMMIT;
SELECT :'watch_update_job_id';
SQL
)"
if [[ ! "$watch_update_job_id" =~ ^[1-9][0-9]*$ ]]; then
  echo "Expected the row-watch update to queue a job, got $watch_update_job_id" >&2
  exit 1
fi

run_worker_once

watch_update_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 -v watch_job_id="$watch_update_job_id" <<'SQL'
SELECT concat_ws('|',
  (SELECT status FROM otlet.jobs WHERE id = :'watch_job_id'::bigint),
  (SELECT body ->> 'decision'
   FROM otlet.semantic_index_current_rows('portable_row_watch')
   WHERE subject_id = 'watch-live'),
  (SELECT stale::text
   FROM otlet.semantic_index_current_rows('portable_row_watch')
   WHERE subject_id = 'watch-live'),
  count(*),
  count(*) FILTER (WHERE stale),
  count(*) FILTER (WHERE NOT stale)
)
FROM otlet.semantic_materializations
WHERE subject_id = 'watch-live';
SQL
)"
expected_watch_update="complete|keep|false|2|1|1"
if [ "$watch_update_contract" != "$expected_watch_update" ]; then
  echo "Expected portable row-watch update contract $expected_watch_update, got $watch_update_contract" >&2
  exit 1
fi

docker exec -i "$container" psql -U postgres -d "$portable_database" \
  -X -qAt -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
DELETE FROM public.otlet_portable_watch_source
WHERE subject_id = 'watch-live';
SQL

watch_delete_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*)
   FROM otlet.semantic_index_current_rows('portable_row_watch')
   WHERE subject_id = 'watch-live'),
  count(*),
  count(*) FILTER (WHERE stale),
  count(*) FILTER (WHERE stale_reason = 'source_delete'),
  (SELECT count(*)
   FROM otlet.jobs j
   JOIN otlet.watches w ON w.task_name = j.task_name
   WHERE w.name = 'portable_row_watch'
     AND j.subject_id = 'watch-live')
)
FROM otlet.semantic_materializations
WHERE subject_id = 'watch-live';
SQL
)"
expected_watch_delete="0|2|2|2|2"
if [ "$watch_delete_contract" != "$expected_watch_delete" ]; then
  echo "Expected portable row-watch delete contract $expected_watch_delete, got $watch_delete_contract" >&2
  exit 1
fi

pair_refresh_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SET LOCAL statement_timeout = '2000ms';
SELECT otlet.refresh_semantic_join_index('portable_pair_watch');
COMMIT;
SELECT concat_ws('|',
  (SELECT count(*)
   FROM otlet.jobs j
   JOIN otlet.watches w ON w.task_name = j.task_name
   WHERE w.name = 'portable_pair_watch'
     AND j.status = 'queued'),
  (SELECT count(*)
   FROM otlet.semantic_join_index_current_rows('portable_pair_watch')),
  (SELECT runtime_name
   FROM otlet.semantic_join_index_plan('portable_pair_watch', true)),
  (SELECT kind FROM otlet.watch_status WHERE watch_name = 'portable_pair_watch'),
  (otlet.export_watch('portable_pair_watch') ->> 'kind')
);
SQL
)"
if [ "$pair_refresh_contract" != $'1\n1|0|portable_external_worker|pair|pair' ]; then
  echo "Expected a queued portable pair watch, got $pair_refresh_contract" >&2
  exit 1
fi

run_worker_once

pair_insert_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  (SELECT status
   FROM otlet.jobs j
   JOIN otlet.watches w ON w.task_name = j.task_name
   WHERE w.name = 'portable_pair_watch'
   ORDER BY j.id DESC
   LIMIT 1),
  (SELECT body ->> 'decision'
   FROM otlet.semantic_join_index_current_rows('portable_pair_watch')),
  (SELECT stale::text
   FROM otlet.semantic_join_index_current_rows('portable_pair_watch')),
  (SELECT count(*)
   FROM otlet.semantic_materializations
   WHERE task_name = 'portable_pair_watch_task'),
  (SELECT (count(*) > 0)::integer FROM otlet.audit_receipt_export)
);
SQL
)"
if [ "$pair_insert_contract" != "complete|keep|false|1|1" ]; then
  echo "Expected portable pair materialization and audit visibility, got $pair_insert_contract" >&2
  exit 1
fi

pair_update_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SET LOCAL statement_timeout = '2000ms';
UPDATE public.otlet_portable_pair_source
SET signal = 'retain updated'
WHERE subject_id = 'pair-left';
SELECT concat_ws('|',
  (SELECT stale::text
   FROM otlet.semantic_join_index_current_rows('portable_pair_watch', false)),
  (SELECT stale_reason
   FROM otlet.semantic_materializations
   WHERE task_name = 'portable_pair_watch_task'
   ORDER BY id DESC
   LIMIT 1),
  otlet.refresh_semantic_join_index('portable_pair_watch')
);
COMMIT;
SQL
)"
if [ "$pair_update_contract" != "true|source_update|1" ]; then
  echo "Expected a stale portable pair replacement, got $pair_update_contract" >&2
  exit 1
fi

run_worker_once

pair_replacement_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  (SELECT body ->> 'decision'
   FROM otlet.semantic_join_index_current_rows('portable_pair_watch')),
  (SELECT stale::text
   FROM otlet.semantic_join_index_current_rows('portable_pair_watch')),
  count(*),
  count(*) FILTER (WHERE stale),
  count(*) FILTER (WHERE NOT stale)
)
FROM otlet.semantic_materializations
WHERE task_name = 'portable_pair_watch_task';
SQL
)"
if [ "$pair_replacement_contract" != "keep|false|2|1|1" ]; then
  echo "Expected a fresh portable pair replacement, got $pair_replacement_contract" >&2
  exit 1
fi

pair_delete_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SET LOCAL statement_timeout = '2000ms';
DELETE FROM public.otlet_portable_pair_source
WHERE subject_id = 'pair-right';
SELECT otlet.refresh_semantic_join_index('portable_pair_watch');
SELECT concat_ws('|',
  (SELECT count(*)
   FROM otlet.semantic_join_index_current_rows('portable_pair_watch')),
  count(*) FILTER (WHERE stale),
  count(*) FILTER (WHERE stale_reason = 'source_delete')
)
FROM otlet.semantic_materializations
WHERE task_name = 'portable_pair_watch_task';
COMMIT;
SQL
)"
if [ "$pair_delete_contract" != $'0\n0|2|2' ]; then
  echo "Expected portable pair deletion reconciliation, got $pair_delete_contract" >&2
  exit 1
fi

watch_cancel_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO public.otlet_portable_watch_source
VALUES ('watch-cancel', 'retain');
WITH target AS (
  SELECT j.id
  FROM otlet.jobs j
  JOIN otlet.watches w ON w.task_name = j.task_name
  WHERE w.name = 'portable_row_watch'
    AND j.subject_id = 'watch-cancel'
  ORDER BY j.id DESC
  LIMIT 1
),
canceled AS (
  SELECT c.*
  FROM target
  CROSS JOIN LATERAL otlet.request_job_cancellation(target.id, 'portable row-watch probe') c
)
SELECT concat_ws('|',
  (SELECT status FROM canceled),
  (SELECT count(*)
   FROM otlet.semantic_materializations
   WHERE subject_id = 'watch-cancel'),
  (SELECT count(*)
   FROM otlet.semantic_index_current_rows('portable_row_watch')
   WHERE subject_id = 'watch-cancel')
);
SQL
)"
if [ "$watch_cancel_contract" != "canceled|0|0" ]; then
  echo "Expected canceled row-watch work to remain unmaterialized, got $watch_cancel_contract" >&2
  exit 1
fi

source_read="$(
  docker exec -e "PGPASSWORD=$worker_password" "$container" \
    psql -h 127.0.0.1 -U "$worker_role" -d "$portable_database" -X -qAt \
      -c 'SELECT count(*) FROM public.otlet_portable_watch_source' 2>&1 || true
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
external_database_url="postgresql://${worker_role}@host.docker.internal:${OTLET_PG_PORT:-55432}/${portable_database}"

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
docker exec -i "$container" psql -U postgres -d "$portable_database" \
  -X -qAt -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
INSERT INTO public.otlet_portable_watch_source
VALUES ('watch-restart', 'retain');
SQL
wait_for_job_status watch-restart complete

watch_restart_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  (SELECT status
   FROM otlet.jobs
   WHERE subject_id = 'watch-restart'
   ORDER BY id DESC
   LIMIT 1),
  (SELECT body ->> 'decision'
   FROM otlet.semantic_index_current_rows('portable_row_watch')
   WHERE subject_id = 'watch-restart'),
  (SELECT stale::text
   FROM otlet.semantic_index_current_rows('portable_row_watch')
   WHERE subject_id = 'watch-restart'),
  (SELECT count(*)
   FROM otlet.semantic_materializations
   WHERE subject_id = 'watch-restart')
);
SQL
)"
if [ "$watch_restart_contract" != "complete|keep|false|1" ]; then
  echo "Expected row-watch materialization after database restart, got $watch_restart_contract" >&2
  exit 1
fi

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

for secret in \
  "$worker_password" \
  "$cheap_worker_password" \
  "$worker_database_url" \
  "$cheap_worker_database_url" \
  "$external_database_url"; do
  if grep -Fq -- "$secret" "$worker_log" "$recovery_log"; then
    echo "Portable worker logs exposed a database credential" >&2
    exit 1
  fi
done
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
  (SELECT status
   FROM otlet.jobs
   WHERE subject_id = 'watch-restart'
   ORDER BY id DESC
   LIMIT 1),
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

portable_parity_contract="$(
  docker exec -i "$container" psql -U postgres -d "$portable_database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*) FROM otlet.verify_invariants()),
  (SELECT count(*)
   FROM unnest(ARRAY[
     'otlet.semantic_matches(text,text,jsonb)',
     'otlet.semantic_join_matches(text,text,jsonb)',
     'otlet.export_watch(text)',
     'otlet.cleanup_policy_state(boolean)'
   ]) signature
   WHERE to_regprocedure(signature) IS NOT NULL),
  (SELECT count(*)
   FROM unnest(ARRAY[
     'otlet.runtime_status',
     'otlet.production_status',
     'otlet.watch_status',
     'otlet.audit_receipt_export'
   ]) relation_name
   WHERE to_regclass(relation_name) IS NOT NULL)
);
SQL
)"
if [ "$portable_parity_contract" != "0|4|4" ]; then
  echo "Expected complete portable SQL parity surfaces and zero invariant violations, got $portable_parity_contract" >&2
  exit 1
fi

echo "portable_async_inference_contract=$async_queued_contract|$async_result_contract|admission=closed|input=validated|scalar_non_watch=accepted"
echo "portable_model_routing_contract=$routing_handoff_contract|$routing_complete_contract|$routing_accept_contract"
echo "portable_claim_metadata_contract=$claim_metadata_contract"
echo "portable_selection_failure_contract=$routing_failure_contract"
echo "portable_routed_recovery_contract=$routed_recovery_contract"
echo "portable_row_watch_contract=$watch_queued_contract|$watch_insert_contract|$watch_update_contract|$watch_delete_contract|$watch_cancel_contract|$watch_restart_contract"
echo "portable_pair_watch_contract=$pair_refresh_contract|$pair_insert_contract|$pair_update_contract|$pair_replacement_contract|$(tr '\n' ':' <<<"$pair_delete_contract")"
echo "portable_external_worker_contract=$contract|source_access=denied|protocol=1"
echo "portable_recovery_contract=$recovery_contract|logs=structured_redacted|duplicate=covered_by_protocol"
echo "portable_parity_contract=$portable_parity_contract"
