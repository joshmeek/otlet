#!/usr/bin/env bash
set -euo pipefail

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
database="otlet_portable_upgrade_demo_$$"

cleanup() {
  docker exec "$container" dropdb -U postgres --if-exists "$database" >/dev/null 2>&1 || true
}
trap cleanup EXIT

install_portable() {
  docker exec -w /work "$container" \
    psql -U postgres -d "$database" -X -q -v ON_ERROR_STOP=1 \
    -f crates/otlet_worker/sql/install.sql
}

claim_probe_jobs() {
  docker exec "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -c "SELECT count(*) FROM otlet.claim_jobs('model_concurrency_probe', $1)"
}

model_capacity_contract() {
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  status.active_claimed_jobs,
  status.max_active_jobs,
  status.available_active_job_slots,
  status.running_jobs,
  status.cancel_requested_jobs,
  status.expired_running_jobs,
  status.queued_jobs,
  (SELECT count(*) FROM otlet.verify_invariants() violation
   WHERE violation.invariant_name = 'active_claimed_jobs_within_model_cap')
)
FROM otlet.model_queue_status status
WHERE status.model_name = 'model_concurrency_probe';
SQL
}

cleanup
docker exec "$container" createdb -U postgres "$database"
install_portable

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE TABLE public.portable_upgrade_sentinel (
  id integer PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO public.portable_upgrade_sentinel VALUES (1, 'preserved');
SQL

install_portable

contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  max(version),
  count(*),
  array_agg(version ORDER BY version) = ARRAY(SELECT generate_series(1, 46)),
  bool_and(file ~ ('(^|/)' || lpad(version::text, 4, '0') || '_')),
  (SELECT value FROM public.portable_upgrade_sentinel),
  (SELECT count(*) FROM otlet.verify_invariants())
)
FROM otlet.portable_schema_migrations;
SQL
)"
[ "$contract" = "46|46|t|t|preserved|0" ] || {
  echo "Portable repeat-install contract mismatch: $contract" >&2
  exit 1
}

identity_vector_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  otlet.identity_hash(
    'test_vector',
    '{"b":2.00,"a":[1.0,"é"]}'::jsonb
  ) = 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_hash(
    'test_vector',
    '{"a":[1.00,"é"],"b":2}'::jsonb
  ) = 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_hash(
    'other_vector',
    '{"b":2.00,"a":[1.0,"é"]}'::jsonb
  ) <> 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_text_hash(
    'text_vector',
    E'Otlet\n🙂'
  ) = 'otlet:v1:sha256:96077dacfe042898c24b4f06ed6d91b8d21e13a52d36738fe1009032d0d13f72'
);
SQL
)"
[ "$identity_vector_contract" = "t|t|t|t" ] || {
  echo "Portable identity vector contract mismatch: $identity_vector_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
SELECT otlet.register_model(
  'model_concurrency_probe',
  '/tmp/model_concurrency_probe.gguf',
  repeat('1', 64),
  jsonb_build_object(
    'sha256', repeat('1', 64),
    'bytes', 1,
    'source', 'portable-upgrade-demo',
    'revision', 'model-concurrency-v1',
    'quantization', 'test',
    'license', 'test'
  ),
  3
);
SELECT otlet.create_task(
  task_name => 'model_concurrency_probe',
  input_query => NULL,
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'model_concurrency_probe',
  input_shaping => '{"source_fields":["value"]}'::jsonb
);
WITH revision AS (
  SELECT otlet.ensure_active_workload_revision('model_concurrency_probe') AS revision_hash
)
INSERT INTO otlet.jobs (task_name, workload_revision_hash, subject_id, input)
SELECT
  'model_concurrency_probe',
  revision_hash,
  'subject-' || subject_number,
  jsonb_build_object('value', subject_number)
FROM revision
CROSS JOIN generate_series(1, 6) AS subject_number;
SQL

batch_claims="$(claim_probe_jobs 8)"
batch_capacity_contract="$(model_capacity_contract)"
[ "$batch_claims|$batch_capacity_contract" = "3|3|3|0|3|0|0|3|0" ] || {
  echo "Portable batch model capacity contract mismatch: $batch_claims|$batch_capacity_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
UPDATE otlet.jobs
SET status = 'queued',
    attempts = 0,
    leased_until = NULL,
    claim_token = NULL,
    started_at = NULL
WHERE task_name = 'model_concurrency_probe';
SQL

docker exec "$container" psql -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -c "BEGIN; SELECT pg_advisory_xact_lock(hashtext('otlet_queue_admission')); SELECT pg_sleep(2); COMMIT" \
  >/dev/null &
capacity_lock_pid=$!
sleep 1
claim_pids=()
for _ in 1 2; do
  claim_probe_jobs 8 >/dev/null &
  claim_pids+=("$!")
done
wait "$capacity_lock_pid"
for claim_pid in "${claim_pids[@]}"; do
  wait "$claim_pid"
done

concurrent_capacity_contract="$(model_capacity_contract)"
[ "$concurrent_capacity_contract" = "3|3|0|3|0|0|3|0" ] || {
  echo "Portable concurrent model capacity contract mismatch: $concurrent_capacity_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
UPDATE otlet.jobs
SET status = 'cancel_requested',
    cancel_requested_at = now(),
    error = 'cancellation requested'
WHERE id = (
  SELECT id
  FROM otlet.jobs
  WHERE task_name = 'model_concurrency_probe'
    AND status = 'running'
  ORDER BY id
  LIMIT 1
);
SQL

cancel_blocked_claims="$(claim_probe_jobs 8)"
[ "$cancel_blocked_claims" = "0" ] || {
  echo "Live cancellation released model capacity: $cancel_blocked_claims" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second',
    attempts = (SELECT max_attempts FROM otlet.production_policy WHERE name = 'default')
WHERE task_name = 'model_concurrency_probe'
  AND status = 'cancel_requested';
SQL

replacement_claims="$(claim_probe_jobs 8)"
lease_capacity_contract="$(model_capacity_contract)"
[ "$replacement_claims|$lease_capacity_contract" = "1|3|3|0|3|1|1|2|0" ] || {
  echo "Portable lease model capacity contract mismatch: $replacement_claims|$lease_capacity_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
DELETE FROM otlet.jobs WHERE task_name = 'model_concurrency_probe';
SELECT otlet.register_model(
  model.name,
  model.artifact_path,
  model.artifact_hash,
  model.artifact_identity,
  1
)
FROM otlet.models model
WHERE model.name = 'model_concurrency_probe';
WITH revision AS (
  SELECT otlet.ensure_active_workload_revision('model_concurrency_probe') AS revision_hash
), inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    status,
    attempts,
    leased_until,
    claim_token,
    started_at
  )
  SELECT
    'model_concurrency_probe',
    revision_hash,
    'renewed',
    '{"value":1}'::jsonb,
    'running',
    (SELECT max_attempts FROM otlet.production_policy WHERE name = 'default'),
    clock_timestamp() + interval '2 seconds',
    'renewal-owner',
    clock_timestamp()
  FROM revision
  RETURNING workload_revision_hash
)
INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input
)
SELECT
  'model_concurrency_probe',
  workload_revision_hash,
  'replacement',
  '{"value":2}'::jsonb
FROM inserted;
SQL

docker exec "$container" psql -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -c "BEGIN; SELECT id FROM otlet.jobs WHERE task_name = 'model_concurrency_probe' AND subject_id = 'renewed' FOR UPDATE; SELECT pg_sleep(5); COMMIT" \
  >/dev/null &
renewal_row_lock_pid=$!
sleep 0.5
docker exec "$container" psql -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -c "SELECT count(*) FROM otlet.renew_job_lease((SELECT id FROM otlet.jobs WHERE task_name = 'model_concurrency_probe' AND subject_id = 'renewed'), 'renewal-owner')" \
  >/dev/null &
renewal_pid=$!
sleep 3
renewal_race_claims="$(claim_probe_jobs 8)"
wait "$renewal_row_lock_pid"
wait "$renewal_pid"

renewal_race_contract="$renewal_race_claims|$(model_capacity_contract)"
[ "$renewal_race_contract" = "1|1|1|0|2|0|1|0|0" ] || {
  echo "Portable renewal race contract mismatch: $renewal_race_contract" >&2
  exit 1
}

echo "portable_upgrade_contract=$contract"
echo "portable_identity_vector_contract=$identity_vector_contract"
echo "portable_model_capacity_contract=$batch_claims|$batch_capacity_contract|$concurrent_capacity_contract|$cancel_blocked_claims|$replacement_claims|$lease_capacity_contract"
echo "portable_renewal_race_contract=$renewal_race_contract"
