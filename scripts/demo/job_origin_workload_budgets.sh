log "Proving job origin and workload budgets"

job_origin_workload_budget_contract="$(psql_exec -qAt <<'SQL' | tail -n 1
BEGIN;
SET LOCAL statement_timeout = '10s';
SELECT 1
FROM otlet.production_policy
WHERE name = 'default'
FOR UPDATE \g /dev/null

CREATE FUNCTION pg_temp.assert_true(condition boolean, message text)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT COALESCE(assert_true.condition, false) THEN
    RAISE EXCEPTION '%', assert_true.message;
  END IF;
END;
$function$;

CREATE FUNCTION pg_temp.expect_error(statement text, message_fragment text)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    EXECUTE expect_error.statement;
    RAISE EXCEPTION 'expected statement to fail: %', expect_error.statement;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected statement to fail: ' || expect_error.statement
       OR position(expect_error.message_fragment IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;
END;
$function$;

SELECT pg_temp.assert_true(
  (
    SELECT (
      max_active_jobs_per_task,
      max_queued_input_bytes_per_task,
      max_queue_age
    ) = (8, 67108864::bigint, interval '1 day')
    FROM otlet.production_policy_status
  ),
  'default task workload budgets changed'
);

INSERT INTO otlet.models (
  name,
  artifact_path,
  artifact_hash,
  artifact_identity,
  max_active_jobs
)
VALUES (
  'job_origin_budget_model',
  '/tmp/job-origin-budget.gguf',
  repeat('7', 64),
  jsonb_build_object(
    'sha256', repeat('7', 64),
    'bytes', 24,
    'source', 'contract',
    'revision', 'v1',
    'quantization', 'test',
    'license', 'test'
  ),
  10
);

INSERT INTO otlet.tasks (
  name,
  input_query,
  instruction,
  output_schema,
  model_name,
  input_shaping
)
VALUES
  (
    'job_origin_budget_a',
    'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
    'Return status ok',
    '{"type":"object","required":["status"],"properties":{"status":{"const":"ok"}},"additionalProperties":false}'::jsonb,
    'job_origin_budget_model',
    '{"source_fields":["value"]}'::jsonb
  ),
  (
    'job_origin_budget_b',
    'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
    'Return status ok',
    '{"type":"object","required":["status"],"properties":{"status":{"const":"ok"}},"additionalProperties":false}'::jsonb,
    'job_origin_budget_model',
    '{"source_fields":["value"]}'::jsonb
  ),
  (
    'job_origin_budget_bulk',
    'SELECT ''bulk-'' || i::text AS subject_id, ''{}''::jsonb AS input FROM generate_series(1, 2) g(i)',
    'Return status ok',
    '{"type":"object","required":["status"],"properties":{"status":{"const":"ok"}},"additionalProperties":false}'::jsonb,
    'job_origin_budget_model',
    '{}'::jsonb
  );

SET LOCAL statement_timeout = '2000ms';

UPDATE otlet.production_policy
SET max_active_jobs_per_task = 1,
    max_queued_input_bytes_per_task = 1000,
    max_queue_age = interval '1 second',
    max_queued_jobs_per_model = 100,
    max_queued_input_bytes_per_model = 100000,
    max_queued_input_bytes_total = 200000,
    worker_claim_batch_size = 10,
    worker_claim_task_cursor = ''
WHERE name = 'default';

SELECT pg_temp.expect_error(
  $$UPDATE otlet.production_policy
    SET max_active_jobs_per_task = 0
    WHERE name = 'default'$$,
  'production_policy_task_active_jobs_bound'
);
SELECT pg_temp.expect_error(
  $$UPDATE otlet.production_policy
    SET max_queue_age = interval '31 days'
    WHERE name = 'default'$$,
  'production_policy_task_queue_age_bound'
);

SELECT otlet.admit_task_input_with_origin(
  'job_origin_budget_a', 'direct', '{"value":"direct"}', NULL, 'direct_ask'
) \g /dev/null
SELECT otlet.admit_task_input_with_origin(
  'job_origin_budget_a', 'run', '{"value":"run"}', NULL, 'task_run'
) \g /dev/null
SELECT otlet.admit_task_input_with_origin(
  'job_origin_budget_a', 'row', '{"value":"row"}', NULL, 'row_watch'
) \g /dev/null
SELECT otlet.admit_task_input_with_origin(
  'job_origin_budget_a', 'pair', '{"value":"pair"}', NULL, 'pair_watch'
) \g /dev/null
SELECT otlet.admit_task_input_with_origin(
  'job_origin_budget_a', 'catch', '{"value":"catch"}', NULL, 'catch_up'
) \g /dev/null
SELECT otlet.admit_task_input_with_origin(
  'job_origin_budget_a', 'backfill', '{"value":"backfill"}', NULL, 'backfill'
) \g /dev/null
SELECT otlet.admit_task_input_with_origin(
  'job_origin_budget_a', 'scan', '{"value":"scan"}', NULL, 'customscan'
) \g /dev/null

SELECT pg_temp.assert_true(
  (
    SELECT count(DISTINCT job_origin) = 7
      AND array_agg(DISTINCT job_origin ORDER BY job_origin) = ARRAY[
        'backfill',
        'catch_up',
        'customscan',
        'direct_ask',
        'pair_watch',
        'row_watch',
        'task_run'
      ]
    FROM otlet.jobs
    WHERE task_name = 'job_origin_budget_a'
  ),
  'job origin vocabulary is incomplete'
);
SELECT pg_temp.expect_error(
  $$SELECT otlet.admit_task_input_with_origin(
    'job_origin_budget_a', 'invalid', '{}', NULL, 'invalid'
  )$$,
  'unsupported'
);
SELECT pg_temp.expect_error(
  $$UPDATE otlet.jobs
    SET job_origin = 'task_run'
    WHERE task_name = 'job_origin_budget_a'
      AND subject_id = 'direct'$$,
  'origin is immutable'
);

UPDATE otlet.production_policy
SET max_queued_input_bytes_per_task = 1
WHERE name = 'default';
SELECT pg_temp.assert_true(
  otlet.run_task('job_origin_budget_bulk') = 0,
  'bulk task byte rejection did not return zero'
);
SELECT pg_temp.assert_true(
  EXISTS (
    SELECT 1
    FROM otlet.task_candidate_observations
    WHERE task_name = 'job_origin_budget_bulk'
      AND NOT admitted
      AND rejection_reason = 'task_queued_input_byte_cap'
  ),
  'bulk task byte rejection observation is missing'
);
UPDATE otlet.production_policy
SET max_queued_input_bytes_per_task = 1000
WHERE name = 'default';
SELECT set_config('otlet.job_origin', 'backfill', true) \g /dev/null
SELECT pg_temp.assert_true(
  otlet.run_task('job_origin_budget_bulk') = 2,
  'bulk task admission did not queue both rows'
);
SELECT pg_temp.assert_true(
  (
    SELECT count(*) = 2 AND bool_and(job_origin = 'task_run')
    FROM otlet.jobs
    WHERE task_name = 'job_origin_budget_bulk'
  ),
  'session setting changed the bulk task origin'
);
SELECT set_config('otlet.job_origin', '', true) \g /dev/null
DELETE FROM otlet.jobs WHERE task_name = 'job_origin_budget_bulk';

UPDATE otlet.production_policy
SET max_queued_input_bytes_per_task = (
  SELECT sum(octet_length(input::text))
  FROM otlet.jobs
  WHERE task_name = 'job_origin_budget_a'
    AND status = 'queued'
)
WHERE name = 'default';

SELECT pg_temp.assert_true(
  NOT otlet.admit_task_input_with_origin(
    'job_origin_budget_a', 'over-byte-cap', '{"value":"x"}', NULL, 'task_run'
  ),
  'same-task byte cap admitted another job'
);
SELECT pg_temp.assert_true(
  set_config('otlet.job_origin', 'backfill', true) = 'backfill',
  'origin spoof probe could not set its session value'
);
SELECT pg_temp.assert_true(
  otlet.admit_task_input(
    'job_origin_budget_b', 'isolated-byte-cap', '{"value":"x"}', NULL
  ),
  'task byte cap leaked across tasks'
);
SELECT set_config('otlet.job_origin', '', true) \g /dev/null
SELECT pg_temp.assert_true(
  EXISTS (
    SELECT 1
    FROM otlet.jobs
    WHERE task_name = 'job_origin_budget_b'
      AND subject_id = 'isolated-byte-cap'
      AND job_origin = 'task_run'
  ),
  'default task admission origin changed'
);
SELECT pg_temp.assert_true(
  EXISTS (
    SELECT 1
    FROM otlet.worker_events
    WHERE event_type = 'queue_admission_suppressed'
      AND detail ->> 'task_name' = 'job_origin_budget_a'
      AND detail ->> 'reason' = 'task_queued_input_byte_cap'
  ),
  'task byte suppression reason is missing'
);
SELECT pg_temp.expect_error(
  $$INSERT INTO otlet.jobs (task_name, subject_id, input)
    VALUES ('job_origin_budget_a', 'raw-over-byte-cap', '{}')$$,
  'task queued input byte cap exceeded'
);

DELETE FROM otlet.jobs
WHERE task_name = 'job_origin_budget_a'
  AND subject_id <> 'direct';
UPDATE otlet.jobs
SET created_at = statement_timestamp() - interval '2 seconds'
WHERE task_name = 'job_origin_budget_a'
  AND subject_id = 'direct';

SELECT pg_temp.assert_true(
  NOT otlet.admit_task_input_with_origin(
    'job_origin_budget_a', 'over-age-cap', '{}', NULL, 'task_run'
  ),
  'aged task queue admitted another job'
);
SELECT pg_temp.assert_true(
  otlet.admit_task_input_with_origin(
    'job_origin_budget_b', 'isolated-age-cap', '{}', NULL, 'task_run'
  ),
  'task queue age leaked across tasks'
);
SELECT pg_temp.assert_true(
  EXISTS (
    SELECT 1
    FROM otlet.task_queue_status
    WHERE task_name = 'job_origin_budget_a'
      AND job_origin = 'direct_ask'
      AND origin_queue_age_exceeded
      AND task_queue_age_exceeded
      AND max_queue_age = interval '1 second'
  )
  AND EXISTS (
    SELECT 1
    FROM otlet.jobs
    WHERE task_name = 'job_origin_budget_a'
      AND subject_id = 'direct'
      AND status = 'queued'
  ),
  'queue age status or non-expiring backlog contract changed'
);

CREATE TEMP TABLE job_origin_age_claims ON COMMIT DROP AS
SELECT * FROM otlet.claim_jobs(NULL, 10);
SELECT pg_temp.assert_true(
  EXISTS (
    SELECT 1
    FROM job_origin_age_claims
    WHERE task_name = 'job_origin_budget_a'
      AND subject_id = 'direct'
  ),
  'aged task backlog was not claimable'
);
SELECT pg_temp.assert_true(
  otlet.admit_task_input(
    'job_origin_budget_a', 'age-recovered', '{}', NULL
  ),
  'task admission did not recover after the aged backlog left the queue'
);

DELETE FROM otlet.jobs
WHERE task_name IN ('job_origin_budget_a', 'job_origin_budget_b');
UPDATE otlet.production_policy
SET max_queued_input_bytes_per_task = 1000
WHERE name = 'default';

INSERT INTO otlet.jobs (task_name, subject_id, input, job_origin)
VALUES
  ('job_origin_budget_a', 'a-1', '{}', 'direct_ask'),
  ('job_origin_budget_a', 'a-2', '{}', 'customscan'),
  ('job_origin_budget_b', 'b-1', '{}', 'pair_watch'),
  ('job_origin_budget_b', 'b-2', '{}', 'backfill');

CREATE TEMP TABLE job_origin_first_claims ON COMMIT DROP AS
SELECT * FROM otlet.claim_jobs(NULL, 10);
SELECT pg_temp.assert_true(
  (SELECT count(*) = 2 FROM job_origin_first_claims)
  AND (SELECT count(DISTINCT task_name) = 2 FROM job_origin_first_claims)
  AND NOT EXISTS (
    SELECT 1
    FROM job_origin_first_claims
    GROUP BY task_name
    HAVING count(*) > 1
  ),
  'task claim concurrency exceeded one live job per task'
);
SELECT pg_temp.assert_true(
  EXISTS (
    SELECT 1
    FROM otlet.task_queue_status
    WHERE task_name = 'job_origin_budget_a'
      AND job_origin = 'customscan'
      AND queued_jobs = 1
  )
  AND EXISTS (
    SELECT 1
    FROM otlet.task_resource_status
    WHERE task_name = 'job_origin_budget_a'
      AND job_origin = 'direct_ask'
      AND task_active_claimed_jobs = 1
      AND task_concurrency_exhausted
  ),
  'queue or resource origin status is incomplete'
);

UPDATE otlet.jobs
SET leased_until = statement_timestamp() - interval '1 second'
WHERE id = (
  SELECT id
  FROM job_origin_first_claims
  WHERE task_name = 'job_origin_budget_a'
);
SELECT pg_temp.assert_true(
  (
    SELECT available_active_job_slots = 1
    FROM otlet.task_claim_capacity
    WHERE task_name = 'job_origin_budget_a'
  )
  AND (
    SELECT available_active_job_slots = 0
    FROM otlet.task_claim_capacity
    WHERE task_name = 'job_origin_budget_b'
  ),
  'expired task lease did not release only its task slot'
);
CREATE TEMP TABLE job_origin_second_claims ON COMMIT DROP AS
SELECT * FROM otlet.claim_jobs(NULL, 10);
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1 FROM job_origin_second_claims)
  AND (
    SELECT bool_and(task_name = 'job_origin_budget_a')
    FROM job_origin_second_claims
  ),
  'task claim capacity did not fence the second claim'
);

SELECT concat_ws('|',
  (SELECT count(DISTINCT job_origin)
   FROM otlet.jobs
   WHERE task_name IN ('job_origin_budget_a', 'job_origin_budget_b')),
  (SELECT count(*)
   FROM job_origin_first_claims),
  (SELECT count(*)
   FROM job_origin_second_claims),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.task_queue_status', 'SELECT'
  ),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.task_resource_status', 'SELECT'
  ),
  NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.admit_task_input_with_origin(text,text,jsonb,text,text)',
    'EXECUTE'
  ),
  NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.run_task_subject_with_origin(text,text,text,text)',
    'EXECUTE'
  )
);
ROLLBACK;
SQL
)"

echo "job_origin_workload_budget_contract=$job_origin_workload_budget_contract"
[ "$job_origin_workload_budget_contract" = "4|2|1|t|t|t|t" ] || {
  echo "Expected bounded job origin contract, got $job_origin_workload_budget_contract" >&2
  exit 1
}
