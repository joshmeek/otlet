log "Checking workload admission"

admission_policy_contract="$(psql_value <<'SQL'
SELECT max_admission_rows::text || '|' ||
       max_input_bytes_per_job::text || '|' ||
       max_queued_input_bytes_per_model::text || '|' ||
       max_queued_input_bytes_total::text || '|' ||
       max_candidate_query_cost::text || '|' ||
       candidate_query_statement_timeout_ms::text
FROM otlet.production_policy_status;
SQL
)"
echo "admission_policy_contract=$admission_policy_contract"
[ "$admission_policy_contract" = "1000|1048576|67108864|268435456|1000000|2000" ] || {
  echo "Expected default workload admission policy, got $admission_policy_contract" >&2
  exit 1
}

candidate_preflight_contract="$(psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE admission_preflight_created AS
SELECT otlet.create_watch(
    watch_name => 'admission_preflight_demo',
    kind => 'pair',
    instruction => 'Return an empty object',
    output_schema => '{"type":"object"}'::jsonb,
    model_name => :'model_name',
    candidate_query => 'SELECT ''candidate-1''::text AS subject_id, ''{}''::jsonb AS input',
    max_candidate_rows => 1
  );
SELECT (candidate_plan_cost >= 0)::text || '|' ||
       (jsonb_typeof(candidate_plan) = 'array')::text || '|' ||
       (candidate_preflight_at IS NOT NULL)::text || '|' ||
       candidate_query_statement_timeout_ms::text
FROM otlet.semantic_join_indexes
CROSS JOIN otlet.production_policy
WHERE otlet.semantic_join_indexes.name = 'admission_preflight_demo'
  AND otlet.production_policy.name = 'default';
ROLLBACK;
SQL
)"
echo "candidate_preflight_contract=$candidate_preflight_contract"
[ "$candidate_preflight_contract" = "true|true|true|2000" ] || {
  echo "Expected stored candidate EXPLAIN preflight evidence, got $candidate_preflight_contract" >&2
  exit 1
}

set +e
invalid_candidate_output="$(psql_exec -qAt 2>&1 <<'SQL'
SELECT *
FROM otlet.preflight_candidate_query(
  'SELECT subject_id, input FROM public.otlet_admission_missing_source'
);
SQL
)"
invalid_candidate_exit=$?
set -e
if [ "$invalid_candidate_exit" -eq 0 ] || [[ "$invalid_candidate_output" != *"candidate query EXPLAIN failed"* ]]; then
  echo "Invalid candidate query did not fail during EXPLAIN preflight" >&2
  printf '%s\n' "$invalid_candidate_output" >&2
  exit 1
fi
echo "candidate_invalid_preflight_contract=failed|no_mutation"

set +e
expensive_candidate_output="$(psql_exec -qAt 2>&1 <<'SQL'
BEGIN;
UPDATE otlet.production_policy
SET max_candidate_query_cost = 1
WHERE name = 'default';
SELECT *
FROM otlet.preflight_candidate_query(
  'SELECT i::text AS subject_id, ''{}''::jsonb AS input FROM generate_series(1, 1000000) AS g(i)'
);
SQL
)"
expensive_candidate_exit=$?
set -e
if [ "$expensive_candidate_exit" -eq 0 ] || [[ "$expensive_candidate_output" != *"plan cost"* ]]; then
  echo "Expensive candidate query did not fail before execution" >&2
  printf '%s\n' "$expensive_candidate_output" >&2
  exit 1
fi
echo "candidate_cost_preflight_contract=failed|no_execution"

psql_exec -qAt -v model_name="$cheap_model_name" >/dev/null <<'SQL'
SELECT otlet.drop_watch('admission_timeout_demo');
SELECT otlet.create_watch(
  watch_name => 'admission_timeout_demo',
  kind => 'pair',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => :'model_name',
  candidate_query => $$
    SELECT 'slow-candidate'::text AS subject_id, '{}'::jsonb AS input
    FROM (SELECT pg_sleep(1)) AS delayed
  $$,
  max_candidate_rows => 1
);
SQL

set +e
missing_timeout_output="$(psql_exec -qAt 2>&1 <<'SQL'
SELECT otlet.refresh_semantic_join_index('admission_timeout_demo');
SQL
)"
missing_timeout_exit=$?
set -e
if [ "$missing_timeout_exit" -eq 0 ] || [[ "$missing_timeout_output" != *"requires statement_timeout"* ]]; then
  echo "Pair refresh without a statement timeout did not fail closed" >&2
  printf '%s\n' "$missing_timeout_output" >&2
  exit 1
fi

set +e
timed_candidate_output="$(docker exec -e PGOPTIONS='-c statement_timeout=100ms' -i "$container" \
  psql -U postgres -d "$database" -qAt -v ON_ERROR_STOP=1 2>&1 <<'SQL'
SELECT otlet.refresh_semantic_join_index('admission_timeout_demo');
SQL
)"
timed_candidate_exit=$?
set -e
if [ "$timed_candidate_exit" -eq 0 ] || [[ "$timed_candidate_output" != *"canceling statement due to statement timeout"* ]]; then
  echo "Slow candidate query did not honor the caller statement timeout" >&2
  printf '%s\n' "$timed_candidate_output" >&2
  exit 1
fi
timeout_job_count="$(psql_value -c "SELECT count(*) FROM otlet.jobs WHERE task_name = 'admission_timeout_demo_task';")"
[ "$timeout_job_count" = "0" ] || {
  echo "Timed-out candidate query left $timeout_job_count jobs" >&2
  exit 1
}
echo "candidate_timeout_contract=missing_rejected|timed_out|0"

set +e
invalid_import_output="$(psql_exec -qAt 2>&1 <<'SQL'
SELECT otlet.import_watch(
  otlet.export_watch('admission_timeout_demo') || jsonb_build_object(
    'name', 'admission_import_invalid',
    'candidate_query', 'SELECT subject_id, input FROM public.otlet_admission_missing_source'
  )
);
SQL
)"
invalid_import_exit=$?
set -e
invalid_import_count="$(psql_value -c "SELECT count(*) FROM otlet.watches WHERE name = 'admission_import_invalid';")"
if [ "$invalid_import_exit" -eq 0 ] || [[ "$invalid_import_output" != *"candidate query EXPLAIN failed"* ]] || [ "$invalid_import_count" != "0" ]; then
  echo "Invalid imported candidate query did not roll back cleanly" >&2
  printf '%s\n' "$invalid_import_output" >&2
  exit 1
fi
psql_exec -qAt -c "SELECT otlet.drop_watch('admission_timeout_demo');" >/dev/null
echo "candidate_import_preflight_contract=failed|0"

row_cap_contract="$(psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE admission_row_created AS
SELECT otlet.create_task(
    'admission_row_cap_demo',
    'SELECT i::text AS subject_id, jsonb_build_object(''value'', i) AS input FROM generate_series(1, 3) AS g(i)',
    'Admission row cap',
    '{"type":"object"}'::jsonb,
    :'model_name'
  );
UPDATE otlet.production_policy
SET max_admission_rows = 2,
    max_queued_jobs_per_model = 100
WHERE name = 'default';
CREATE TEMP TABLE admission_row_result AS
SELECT otlet.run_task('admission_row_cap_demo') AS queued;
SELECT (SELECT queued FROM admission_row_result)::text || '|' ||
       (SELECT count(*) FROM otlet.jobs WHERE task_name = 'admission_row_cap_demo')::text || '|' ||
       COALESCE((
         SELECT detail ->> 'reason'
         FROM otlet.worker_events
         WHERE detail ->> 'task_name' = 'admission_row_cap_demo'
         ORDER BY id DESC
         LIMIT 1
       ), '');
ROLLBACK;
SQL
)"
echo "row_cap_contract=$row_cap_contract"
[ "$row_cap_contract" = "0|0|row_cap" ] || {
  echo "Expected all-or-nothing row cap rejection, got $row_cap_contract" >&2
  exit 1
}

input_cap_contract="$(psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE admission_input_created AS
SELECT otlet.create_task(
    'admission_input_cap_demo',
    'SELECT ''large''::text AS subject_id, jsonb_build_object(''payload'', repeat(''x'', 100)) AS input',
    'Admission input cap',
    '{"type":"object"}'::jsonb,
    :'model_name'
  );
UPDATE otlet.production_policy
SET max_input_bytes_per_job = 64
WHERE name = 'default';
CREATE TEMP TABLE admission_input_result AS
SELECT otlet.run_task('admission_input_cap_demo') AS queued;
SELECT (SELECT queued FROM admission_input_result)::text || '|' ||
       (SELECT count(*) FROM otlet.jobs WHERE task_name = 'admission_input_cap_demo')::text || '|' ||
       COALESCE((
         SELECT detail ->> 'reason'
         FROM otlet.worker_events
         WHERE detail ->> 'task_name' = 'admission_input_cap_demo'
         ORDER BY id DESC
         LIMIT 1
       ), '');
ROLLBACK;
SQL
)"
echo "input_cap_contract=$input_cap_contract"
[ "$input_cap_contract" = "0|0|input_byte_cap" ] || {
  echo "Expected per-job input cap rejection, got $input_cap_contract" >&2
  exit 1
}

model_byte_cap_contract="$(psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE admission_model_bytes_created AS
SELECT otlet.create_task(
    'admission_model_bytes_demo',
    'SELECT i::text AS subject_id, jsonb_build_object(''payload'', repeat(''x'', 50)) AS input FROM generate_series(1, 2) AS g(i)',
    'Admission model byte cap',
    '{"type":"object"}'::jsonb,
    :'model_name'
  );
UPDATE otlet.production_policy
SET max_input_bytes_per_job = 1000,
    max_queued_input_bytes_per_model = 100,
    max_queued_input_bytes_total = 1000
WHERE name = 'default';
CREATE TEMP TABLE admission_model_bytes_result AS
SELECT otlet.run_task('admission_model_bytes_demo') AS queued;
SELECT (SELECT queued FROM admission_model_bytes_result)::text || '|' ||
       (SELECT count(*) FROM otlet.jobs WHERE task_name = 'admission_model_bytes_demo')::text || '|' ||
       COALESCE((
         SELECT detail ->> 'reason'
         FROM otlet.worker_events
         WHERE detail ->> 'task_name' = 'admission_model_bytes_demo'
         ORDER BY id DESC
         LIMIT 1
       ), '');
ROLLBACK;
SQL
)"
echo "model_byte_cap_contract=$model_byte_cap_contract"
[ "$model_byte_cap_contract" = "0|0|model_queued_input_byte_cap" ] || {
  echo "Expected per-model queued-input byte rejection, got $model_byte_cap_contract" >&2
  exit 1
}

total_byte_cap_contract="$(psql_value -v cheap_model_name="$cheap_model_name" -v strong_model_name="$strong_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE admission_total_existing_created AS
SELECT otlet.create_task(
    'admission_total_existing_demo',
    NULL,
    'Existing total bytes',
    '{"type":"object"}'::jsonb,
    :'strong_model_name'
  );
CREATE TEMP TABLE admission_total_candidate_created AS
SELECT otlet.create_task(
    'admission_total_candidate_demo',
    'SELECT ''candidate''::text AS subject_id, jsonb_build_object(''payload'', repeat(''y'', 90)) AS input',
    'Candidate total bytes',
    '{"type":"object"}'::jsonb,
    :'cheap_model_name'
  );
UPDATE otlet.production_policy
SET max_input_bytes_per_job = 200,
    max_queued_input_bytes_per_model = 200,
    max_queued_input_bytes_total = 200
WHERE name = 'default';
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (
  'admission_total_existing_demo',
  'existing',
  jsonb_build_object('payload', repeat('x', 120))
);
CREATE TEMP TABLE admission_total_result AS
SELECT otlet.run_task('admission_total_candidate_demo') AS queued;
SELECT (SELECT queued FROM admission_total_result)::text || '|' ||
       (SELECT count(*) FROM otlet.jobs WHERE task_name = 'admission_total_candidate_demo')::text || '|' ||
       COALESCE((
         SELECT detail ->> 'reason'
         FROM otlet.worker_events
         WHERE detail ->> 'task_name' = 'admission_total_candidate_demo'
         ORDER BY id DESC
         LIMIT 1
       ), '');
ROLLBACK;
SQL
)"
echo "total_byte_cap_contract=$total_byte_cap_contract"
[ "$total_byte_cap_contract" = "0|0|total_queued_input_byte_cap" ] || {
  echo "Expected total queued-input byte rejection, got $total_byte_cap_contract" >&2
  exit 1
}

queue_depth_contract="$(psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE admission_depth_created AS
SELECT otlet.create_task(
    'admission_depth_demo',
    'SELECT i::text AS subject_id, ''{}''::jsonb AS input FROM generate_series(1, 3) AS g(i)',
    'Admission queue depth',
    '{"type":"object"}'::jsonb,
    :'model_name'
  );
UPDATE otlet.production_policy
SET max_admission_rows = 10,
    max_queued_jobs_per_model = 2
WHERE name = 'default';
CREATE TEMP TABLE admission_depth_result AS
SELECT otlet.run_task('admission_depth_demo') AS queued;
SELECT (SELECT queued FROM admission_depth_result)::text || '|' ||
       (SELECT count(*) FROM otlet.jobs WHERE task_name = 'admission_depth_demo')::text || '|' ||
       COALESCE((
         SELECT detail ->> 'reason'
         FROM otlet.worker_events
         WHERE detail ->> 'task_name' = 'admission_depth_demo'
         ORDER BY id DESC
         LIMIT 1
       ), '');
ROLLBACK;
SQL
)"
echo "queue_depth_contract=$queue_depth_contract"
[ "$queue_depth_contract" = "0|0|queue_depth_cap" ] || {
  echo "Expected all-or-nothing queue-depth rejection, got $queue_depth_contract" >&2
  exit 1
}

enqueue_only_contract="$(psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE admission_enqueue_created AS
SELECT otlet.create_task(
    'admission_enqueue_only_demo',
    'SELECT ''one''::text AS subject_id, ''{}''::jsonb AS input',
    'Admission enqueue only',
    '{"type":"object"}'::jsonb,
    :'model_name'
  );
CREATE TEMP TABLE admission_enqueue_result AS
SELECT otlet.run_task('admission_enqueue_only_demo') AS queued;
SELECT (SELECT queued FROM admission_enqueue_result)::text || '|' ||
       (SELECT status FROM otlet.jobs WHERE task_name = 'admission_enqueue_only_demo') || '|' ||
       (SELECT 42)::text;
ROLLBACK;
SQL
)"
echo "enqueue_only_contract=$enqueue_only_contract"
[ "$enqueue_only_contract" = "1|queued|42" ] || {
  echo "Expected enqueue-only admission without a worker wait, got $enqueue_only_contract" >&2
  exit 1
}

set +e
invalid_shaping_output="$(psql_exec -qAt -v model_name="$cheap_model_name" 2>&1 <<'SQL'
SELECT otlet.create_task(
  'admission_invalid_shaping_demo',
  'SELECT ''one''::text AS subject_id, ''{}''::jsonb AS input',
  'Invalid shaping',
  '{"type":"object"}'::jsonb,
  :'model_name',
  input_shaping => '{"max_shaped_input_bytes":0}'::jsonb
);
SQL
)"
invalid_shaping_exit=$?
set -e
if [ "$invalid_shaping_exit" -eq 0 ] || [[ "$invalid_shaping_output" != *"max_shaped_input_bytes must be an integer"* ]]; then
  echo "Invalid shaped-input limit did not fail closed" >&2
  printf '%s\n' "$invalid_shaping_output" >&2
  exit 1
fi
echo "shaped_input_limit_contract=failed|no_task"
