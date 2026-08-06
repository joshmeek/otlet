log "Proving versioned observability and quality status"

original_native_runtime_options="$(psql_value <<'SQL'
SELECT default_runtime_options::text
FROM otlet.production_policy
WHERE name = 'default';
SQL
)"
startup_event_floor="$(psql_value -c \
  "SELECT COALESCE(max(id), 0) FROM otlet.worker_events")"
startup_failure_event_id=""

cleanup_observability_startup_probe() {
  psql_exec -q -v runtime_options="$original_native_runtime_options" <<'SQL' \
    >/dev/null 2>&1 || true
UPDATE otlet.production_policy
SET default_runtime_options = :'runtime_options'::jsonb
WHERE name = 'default';
SQL
  if [ -n "$startup_failure_event_id" ]; then
    psql_exec -q -v event_id="$startup_failure_event_id" <<'SQL' \
      >/dev/null 2>&1 || true
DELETE FROM otlet.worker_events WHERE id = :'event_id';
SQL
  fi
}

wait_observability_postgres() {
  for _ in $(seq 1 30); do
    if docker exec "$container" pg_isready -U postgres -d "$database" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Postgres did not become ready for the observability startup proof" >&2
  return 1
}

trap cleanup_observability_startup_probe EXIT
psql_exec -q <<'SQL' >/dev/null
UPDATE otlet.production_policy
SET default_runtime_options = jsonb_set(
      default_runtime_options,
      '{max_worker_rss_bytes}',
      '"invalid"'::jsonb
    )
WHERE name = 'default';
SQL
docker restart "$container" >/dev/null
wait_observability_postgres
for _ in $(seq 1 30); do
  startup_failure_event_id="$(psql_value -v event_floor="$startup_event_floor" <<'SQL'
SELECT COALESCE(max(id)::text, '')
FROM otlet.worker_events
WHERE id > :'event_floor'
  AND event_type = 'worker_startup_failed';
SQL
)"
  [ -n "$startup_failure_event_id" ] && break
  sleep 1
done
[ -n "$startup_failure_event_id" ] || {
  echo "Native worker did not record the controlled startup failure" >&2
  exit 1
}
psql_exec -q -v runtime_options="$original_native_runtime_options" <<'SQL' \
  >/dev/null
UPDATE otlet.production_policy
SET default_runtime_options = :'runtime_options'::jsonb
WHERE name = 'default';
SQL
docker restart "$container" >/dev/null
wait_observability_postgres
for _ in $(seq 1 30); do
  native_restart_ready="$(psql_value -v event_id="$startup_failure_event_id" <<'SQL'
SELECT EXISTS (
  SELECT 1
  FROM otlet.worker_events
  WHERE id > :'event_id'
    AND event_type = 'worker_started'
);
SQL
)"
  [ "$native_restart_ready" = "t" ] && break
  sleep 1
done
[ "${native_restart_ready:-f}" = "t" ] || {
  echo "Native worker did not recover after the controlled startup failure" >&2
  exit 1
}

versioned_observability_contract="$(psql_exec -qAt \
  -v model_name="$cheap_model_name" \
  -v startup_failure_event_id="$startup_failure_event_id" <<'SQL' | tail -n 1
BEGIN;
SET LOCAL otlet.administrative_reason = 'versioned observability proof';

SELECT otlet.create_task(
  'versioned_observability_probe',
  NULL,
  'Return an empty object',
  '{"type":"object"}'::jsonb,
  :'model_name',
  '{"max_tokens":1,"reasoning":"off","inference_cache":false}'::jsonb
) \g /dev/null
SELECT otlet.promote_configured_workload_revision(
  'versioned_observability_probe'
) AS observability_revision \gset
SELECT otlet.create_task(
  'versioned_observability_probe_sibling',
  NULL,
  'Return an empty object',
  '{"type":"object"}'::jsonb,
  :'model_name',
  '{"max_tokens":1,"reasoning":"off","inference_cache":false}'::jsonb
) \g /dev/null
SELECT otlet.promote_configured_workload_revision(
  'versioned_observability_probe_sibling'
) \g /dev/null

CREATE TEMP TABLE observability_clock AS
SELECT clock_timestamp() AS observed_at;

WITH sample(queue_ms, run_ms, age_ms) AS (
  VALUES
    (10, 100, 1000),
    (20, 200, 2000),
    (30, 300, 3000),
    (40, 400, 4000),
    (50, 500, 5000),
    (60, 600, 1800000),
    (70, 700, 7200000)
)
INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  created_at,
  started_at,
  finished_at
)
SELECT
  'versioned_observability_probe',
  'timing-' || sample.queue_ms::text,
  '{}'::jsonb,
  'complete',
  1,
  clock.observed_at
    - sample.age_ms * interval '1 millisecond'
    - sample.run_ms * interval '1 millisecond'
    - sample.queue_ms * interval '1 millisecond',
  clock.observed_at
    - sample.age_ms * interval '1 millisecond'
    - sample.run_ms * interval '1 millisecond',
  clock.observed_at - sample.age_ms * interval '1 millisecond'
FROM sample
CROSS JOIN observability_clock clock;

INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  created_at,
  started_at,
  finished_at
)
SELECT
  'versioned_observability_probe',
  'future-timing',
  '{}'::jsonb,
  'complete',
  1,
  observed_at + interval '1 minute',
  observed_at + interval '1 minute 10 milliseconds',
  observed_at + interval '1 minute 110 milliseconds'
FROM observability_clock;

INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  error,
  finished_at
)
SELECT
  'versioned_observability_probe',
  'failed',
  '{}'::jsonb,
  'failed',
  'attempt_timeout',
  observed_at - interval '1 minute'
FROM observability_clock;

INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  error,
  finished_at
)
SELECT
  'versioned_observability_probe',
  'future-failed',
  '{}'::jsonb,
  'failed',
  'attempt_timeout',
  observed_at + interval '1 minute'
FROM observability_clock;

INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  leased_until,
  claim_token
)
VALUES (
  'versioned_observability_probe',
  'incident',
  '{}'::jsonb,
  'running',
  1,
  clock_timestamp() + interval '5 minutes',
  'versioned-observability-claim'
)
RETURNING id AS incident_job_id \gset

INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  leased_until,
  claim_token
)
VALUES (
  'versioned_observability_probe',
  'schema-rejection',
  '{}'::jsonb,
  'running',
  1,
  clock_timestamp() + interval '5 minutes',
  'versioned-observability-schema-claim'
)
RETURNING id AS schema_job_id \gset

SELECT id
FROM otlet.record_model_attempt(
  job_id => :'schema_job_id',
  model_name => :'model_name',
  started_at => clock_timestamp() - interval '500 milliseconds',
  trace_summary => '{"schema_validation_status":"failed"}'::jsonb,
  schema_validation_status => 'failed',
  selection_status => 'failed',
  selection_reason => 'schema_validation_failed',
  error => 'schema_validation_failed',
  receipt_status => 'failed',
  expected_claim_token => 'versioned-observability-schema-claim'
) \g /dev/null

SELECT set_config('otlet.evaluation_append', 'on', true) \g /dev/null
INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input,
  execution_mode,
  status,
  attempts,
  started_at,
  leased_until,
  claim_token
)
VALUES (
  'versioned_observability_probe',
  :'observability_revision',
  'evaluation-failure',
  '{}'::jsonb,
  'evaluation',
  'running',
  1,
  clock_timestamp() - interval '500 milliseconds',
  clock_timestamp() + interval '5 minutes',
  'versioned-observability-evaluation-claim'
)
RETURNING id AS evaluation_job_id \gset
SELECT *
FROM otlet.fail_job(
  job_id => :'evaluation_job_id',
  error => 'attempt_timeout',
  schema_validation_status => 'failed',
  trace_summary => '{"schema_validation_status":"failed"}'::jsonb,
  model_name => :'model_name',
  selection_reason => 'attempt_timeout',
  expected_claim_token => 'versioned-observability-evaluation-claim'
) \g /dev/null
SELECT set_config('otlet.evaluation_append', '', true) \g /dev/null

SELECT id AS incident_output_id
FROM otlet.complete_job(
  job_id => :'incident_job_id',
  output => '{}'::jsonb,
  raw_output => '{"output":{},"actions":[]}',
  actions => '[]'::jsonb,
  raw_output_hash => otlet.portable_text_hash('{"output":{},"actions":[]}'),
  started_at => clock_timestamp() - interval '500 milliseconds',
  trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
  model_name => :'model_name',
  expected_claim_token => 'versioned-observability-claim'
) \gset
SELECT receipt_id AS incident_receipt_id
FROM otlet.outputs
WHERE id = :'incident_output_id' \gset

INSERT INTO otlet.actions (
  job_id,
  output_id,
  receipt_id,
  action_type,
  authority_origin,
  authority_mode,
  evaluation_status,
  authority_policy_hash,
  subject_namespace,
  payload,
  status,
  subject_id,
  created_at
)
SELECT
  :'incident_job_id',
  :'incident_output_id',
  :'incident_receipt_id',
  'review_flag',
  'system',
  'recommendation_only',
  'unevaluated',
  otlet.default_action_authority_hash(
    'versioned_observability_probe',
    'review_flag'
  ),
  'versioned_observability_probe',
  '{"type":"review_flag","body":{"reason":"proof","severity":"low"}}'::jsonb,
  'proposed',
  'incident',
  clock.observed_at - interval '15 minutes'
FROM observability_clock clock
RETURNING id AS incident_action_id \gset

WITH inserted AS (
  INSERT INTO otlet.records (action_id, record_type, subject_id, body)
  VALUES (
    :'incident_action_id',
    'versioned_observability_probe',
    'incident',
    '{}'::jsonb
  )
  RETURNING id
)
INSERT INTO otlet.semantic_materializations (
  record_id,
  record_type,
  subject_id,
  task_name,
  model_name,
  body,
  stale,
  source_hash,
  contract_hash,
  stale_reason,
  created_at,
  updated_at
)
SELECT
  inserted.id,
  'versioned_observability_probe',
  'incident',
  'versioned_observability_probe',
  :'model_name',
  '{}'::jsonb,
  true,
  otlet.semantic_source_hash('{}'::jsonb),
  :'observability_revision',
  'manual',
  clock.observed_at - interval '20 minutes',
  clock.observed_at - interval '10 minutes'
FROM inserted
CROSS JOIN observability_clock clock;

INSERT INTO otlet.task_backfills (
  task_name,
  workload_revision_hash,
  subject_limit,
  subject_count,
  subject_manifest_hash,
  page_size,
  max_jobs_per_minute,
  max_outstanding_jobs,
  created_at,
  updated_at
)
SELECT
  'versioned_observability_probe',
  :'observability_revision',
  1,
  1,
  otlet.identity_hash('observability_backfill', '{}'::jsonb),
  1,
  1,
  1,
  clock.observed_at - interval '20 minutes',
  clock.observed_at - interval '20 minutes'
FROM observability_clock clock
RETURNING id AS observability_backfill_id \gset

INSERT INTO otlet.task_backfill_subjects (
  backfill_id,
  ordinal,
  subject_id,
  selected_source_hash
)
VALUES (
  :'observability_backfill_id',
  1,
  'backfill',
  otlet.identity_hash('observability_source', '{}'::jsonb)
);
UPDATE otlet.task_backfills
SET subject_manifest_hash = otlet.task_backfill_manifest_hash(
      :'observability_backfill_id'
    )
WHERE id = :'observability_backfill_id';

INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('versioned_observability_probe', 'queued', '{}'::jsonb);

INSERT INTO otlet.maintenance_runs (
  kind,
  control_state,
  row_budget,
  wal_budget_bytes,
  time_budget_ms,
  last_stop_reason,
  created_at,
  updated_at,
  completed_at
)
SELECT
  'cleanup',
  'complete',
  1,
  1,
  1,
  'complete',
  observed_at - interval '6 minutes',
  observed_at - interval '5 minutes',
  observed_at - interval '5 minutes'
FROM observability_clock;

INSERT INTO otlet.worker_events (
  event_type,
  message,
  detail,
  created_at
)
SELECT
  'versioned_observability_cleanup_secret',
  'cleanup-secret-canary',
  '{"secret":"cleanup-secret-canary"}'::jsonb,
  observed_at - interval '200 years'
FROM observability_clock
RETURNING id AS cleanup_event_id \gset

SELECT id AS batch_event_id
FROM otlet.record_worker_event(
  'worker_batch_finished',
  NULL,
  'linked_inproc',
  'batch-secret-canary',
  jsonb_build_object(
    'task_name', 'versioned_observability_probe',
    'task_names', jsonb_build_array(
      'versioned_observability_probe',
      'versioned_observability_probe_sibling',
      'batch-secret-task-canary'
    ),
    'model_name', :'model_name',
    'job_count', 2
  )
) \gset

SELECT set_config(
  'otlet.worker_identity_hash',
  otlet.identity_hash('spoofed_worker', '{}'::jsonb),
  true
) \g /dev/null
SELECT id AS incident_event_id
FROM otlet.record_worker_event(
  'versioned_observability_future_secret',
  :'incident_job_id',
  'linked_inproc',
  'incident-secret-canary',
  jsonb_build_object(
    'secret', 'incident-secret-canary',
    'model_name', :'model_name',
    'job_count', 1
  )
) \gset
INSERT INTO otlet.worker_events (
  event_type,
  runtime_name,
  message,
  detail,
  claim_attempt_index,
  claim_identity_hash,
  worker_identity_hash
)
VALUES (
  'versioned_observability_spoof_secret',
  'runtime-secret-canary',
  'spoof-secret-canary',
  '{"secret":"spoof-secret-canary"}'::jsonb,
  999,
  otlet.identity_hash('spoofed_claim', '{}'::jsonb),
  otlet.identity_hash('spoofed_worker_column', '{}'::jsonb)
)
RETURNING id AS spoof_event_id \gset
SELECT set_config('otlet.worker_identity_hash', '', true) \g /dev/null

INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  leased_until,
  claim_token
)
VALUES (
  'versioned_observability_probe',
  'model-swap-fence',
  '{}'::jsonb,
  'running',
  1,
  clock_timestamp() + interval '5 minutes',
  'versioned-observability-model-swap-one'
)
RETURNING id AS model_swap_job_id \gset
WITH owned AS MATERIALIZED (
  SELECT 1
  FROM otlet.jobs
  WHERE id = :'model_swap_job_id'
    AND claim_token = 'versioned-observability-model-swap-one'
    AND status IN ('running', 'cancel_requested')
    AND leased_until >= now()
  FOR UPDATE
)
SELECT otlet.record_worker_event(
  'model_swap',
  :'model_swap_job_id',
  'linked_inproc',
  'model swap fence proof',
  jsonb_build_object('task_name', 'versioned_observability_probe')
)
FROM owned \g /dev/null
UPDATE otlet.jobs
SET attempts = 2,
    claim_token = 'versioned-observability-model-swap-two'
WHERE id = :'model_swap_job_id';
WITH owned AS MATERIALIZED (
  SELECT 1
  FROM otlet.jobs
  WHERE id = :'model_swap_job_id'
    AND claim_token = 'versioned-observability-model-swap-one'
    AND status IN ('running', 'cancel_requested')
    AND leased_until >= now()
  FOR UPDATE
)
SELECT otlet.record_worker_event(
  'model_swap',
  :'model_swap_job_id',
  'linked_inproc',
  'stale model swap must not persist',
  jsonb_build_object('task_name', 'versioned_observability_probe')
)
FROM owned \g /dev/null
UPDATE otlet.jobs
SET status = 'canceled',
    terminal_claim_token = claim_token,
    terminal_request_hash = otlet.job_terminal_request_hash(
      'observability-model-swap-fence',
      jsonb_build_array(id)
    ),
    claim_token = NULL,
    leased_until = NULL,
    finished_at = clock_timestamp()
WHERE id = :'model_swap_job_id';

CREATE ROLE otlet_observability_portable_role
NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
SELECT otlet.register_portable_worker(
  'observability-portable-worker',
  'otlet_observability_portable_role'::regrole,
  1,
  :'model_name',
  'reference-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'build', 'observability',
    'transport', 'postgres',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null
UPDATE otlet.portable_workers
SET last_heartbeat_at = clock_timestamp(),
    last_seen_at = clock_timestamp(),
    reported_state = 'idle',
    model_status = 'ready',
    incarnation_nonce_hash = otlet.portable_text_hash(
      'observability-portable-incarnation'
    )
WHERE worker_id = 'observability-portable-worker';

SAVEPOINT observability_retry_correlation;
INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  leased_until,
  claim_token
)
VALUES (
  'versioned_observability_probe',
  'correlation-retry',
  '{}'::jsonb,
  'running',
  1,
  clock_timestamp() + interval '5 minutes',
  'observability-correlation-one'
)
RETURNING id AS job_id, workload_revision_hash
\gset correlation_
INSERT INTO otlet.portable_claims (
  job_id,
  workload_revision_hash,
  worker_id,
  protocol_version,
  runtime_identity_hash,
  incarnation_nonce_hash,
  attempt_index,
  selection_role,
  claim_token_hash,
  runtime_options_status
)
SELECT
  :'correlation_job_id',
  :'correlation_workload_revision_hash',
  worker_id,
  protocol_version,
  runtime_identity_hash,
  incarnation_nonce_hash,
  1,
  'direct',
  otlet.portable_text_hash('observability-correlation-one'),
  '{"compatible":true}'::jsonb
FROM otlet.portable_workers
WHERE worker_id = 'observability-portable-worker'
RETURNING id AS correlation_claim_one \gset
SELECT id AS correlation_event_id
FROM otlet.record_worker_event(
  'job_started',
  :'correlation_job_id',
  'portable:reference-worker',
  'correlation retry proof',
  '{}'::jsonb
) \gset
UPDATE otlet.portable_claims
SET status = 'complete', finished_at = clock_timestamp()
WHERE id = :'correlation_claim_one';
UPDATE otlet.jobs
SET attempts = 2,
    claim_token = 'observability-correlation-two'
WHERE id = :'correlation_job_id';
INSERT INTO otlet.portable_claims (
  job_id,
  workload_revision_hash,
  worker_id,
  protocol_version,
  runtime_identity_hash,
  incarnation_nonce_hash,
  attempt_index,
  selection_role,
  claim_token_hash,
  runtime_options_status
)
SELECT
  :'correlation_job_id',
  :'correlation_workload_revision_hash',
  worker_id,
  protocol_version,
  runtime_identity_hash,
  incarnation_nonce_hash,
  2,
  'strong',
  otlet.portable_text_hash('observability-correlation-two'),
  '{"compatible":true}'::jsonb
FROM otlet.portable_workers
WHERE worker_id = 'observability-portable-worker';
CREATE TEMP TABLE observability_retry_check AS
SELECT EXISTS (
  SELECT 1
  FROM otlet.operational_event_log
  WHERE event_id = :'correlation_event_id'
    AND claim_attempt_index = 1
    AND portable_claim_id = :'correlation_claim_one'
    AND selection_role = 'direct'
    AND worker_identity_hash = otlet.identity_text_hash(
      'portable_worker',
      'observability-portable-worker'
    )
) AS ok;
DO $proof$
BEGIN
  IF NOT (SELECT ok FROM observability_retry_check) THEN
    RAISE EXCEPTION 'otlet event correlation drifted to a later claim';
  END IF;
END;
$proof$;
ROLLBACK TO SAVEPOINT observability_retry_correlation;
RELEASE SAVEPOINT observability_retry_correlation;

UPDATE otlet.production_policy
SET max_active_jobs_per_task = 1,
    max_queued_input_bytes_per_task = octet_length('{}'::jsonb::text)
WHERE name = 'default';

CREATE TEMP TABLE observability_live_checks AS
SELECT
  EXISTS (
    SELECT 1
    FROM otlet.route_readiness_status
    WHERE task_name = 'versioned_observability_probe'
      AND selection_role = 'direct'
      AND route_ready
  ) AS route_ready,
  EXISTS (
    SELECT 1
    FROM otlet.operational_observability_status
    WHERE metric_name = 'portable_worker_heartbeat_age_ms'
      AND worker_identity_hash = otlet.identity_text_hash(
        'portable_worker',
        'observability-portable-worker'
      )
      AND status = 'healthy'
  ) AS heartbeat_fresh;

UPDATE otlet.portable_workers
SET last_heartbeat_at = clock_timestamp() - interval '3 minutes'
WHERE worker_id = 'observability-portable-worker';
SELECT otlet.touch_runtime_slot(
  :'model_name',
  'error',
  0,
  'observability proof'
) \g /dev/null

CREATE TEMP TABLE observability_degraded_checks AS
SELECT
  EXISTS (
    SELECT 1
    FROM otlet.operational_observability_status
    WHERE metric_name = 'portable_worker_heartbeat_age_ms'
      AND worker_identity_hash = otlet.identity_text_hash(
        'portable_worker',
        'observability-portable-worker'
      )
      AND status = 'stale'
  ) AS heartbeat_stale,
  EXISTS (
    SELECT 1
    FROM otlet.operational_observability_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = :'observability_revision'
      AND metric_name = 'route_readiness'
      AND status = 'not_ready'
  ) AS route_not_ready;
SELECT otlet.touch_runtime_slot(:'model_name', 'ready', 0, NULL) \g /dev/null

CREATE ROLE otlet_observability_auditor
NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE otlet_observability_partial
NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
SELECT otlet.grant_auditor_access(
  'otlet_observability_auditor'::regrole
) \g /dev/null
SET LOCAL ROLE otlet_observability_auditor;
SELECT count(*) FROM otlet.operational_observability_status \g /dev/null
SELECT count(*) FROM otlet.labeled_quality_status \g /dev/null
RESET ROLE;

CREATE TEMP TABLE observability_final_status AS
SELECT * FROM otlet.operational_observability_status;

CREATE TEMP TABLE observability_startup_failure AS
SELECT :'startup_failure_event_id'::bigint AS event_id;

DO $proof$
DECLARE
  revision_hash text;
  incident_job bigint;
  incident_receipt bigint;
  incident_action bigint;
  incident_event bigint;
  cleanup_event bigint;
  batch_event bigint;
  spoof_event bigint;
  startup_failure_event bigint;
  model_swap_job bigint;
  expected_model text;
  event_row otlet.operational_event_log%ROWTYPE;
BEGIN
  SELECT event_id INTO STRICT startup_failure_event
  FROM observability_startup_failure;
  SELECT active_workload_revision_hash
  INTO STRICT revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = 'versioned_observability_probe';
  SELECT id INTO STRICT incident_job
  FROM otlet.jobs
  WHERE task_name = 'versioned_observability_probe'
    AND subject_id = 'incident';
  SELECT id INTO STRICT incident_receipt
  FROM otlet.inference_receipts
  WHERE job_id = incident_job;
  SELECT id INTO STRICT incident_action
  FROM otlet.actions
  WHERE job_id = incident_job;
  SELECT id INTO STRICT incident_event
  FROM otlet.worker_events
  WHERE event_type = 'versioned_observability_future_secret';
  SELECT id INTO STRICT cleanup_event
  FROM otlet.worker_events
  WHERE event_type = 'versioned_observability_cleanup_secret';
  SELECT id INTO STRICT batch_event
  FROM otlet.worker_events
  WHERE event_type = 'worker_batch_finished'
    AND message = 'batch-secret-canary';
  SELECT id INTO STRICT spoof_event
  FROM otlet.worker_events
    WHERE event_type = 'versioned_observability_spoof_secret';
  SELECT id INTO STRICT model_swap_job
  FROM otlet.jobs
  WHERE task_name = 'versioned_observability_probe'
    AND subject_id = 'model-swap-fence';
  SELECT model_name INTO STRICT expected_model
  FROM otlet.tasks
  WHERE name = 'versioned_observability_probe';

  IF NOT EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = revision_hash
      AND window_name = '15m'
      AND metric_name = 'queue_wait_ms'
      AND sample_count = 5
      AND p50 = 30
      AND p95 = 50
      AND p99 = 50
      AND maximum = 50
  ) OR NOT EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = revision_hash
      AND window_name = '1h'
      AND metric_name = 'run_time_ms'
      AND sample_count = 6
      AND p50 = 300
      AND p95 = 600
      AND p99 = 600
      AND maximum = 600
  ) OR NOT EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = revision_hash
      AND window_name = '24h'
      AND metric_name = 'queue_wait_ms'
      AND sample_count = 7
      AND p50 = 40
      AND p95 = 70
      AND p99 = 70
      AND maximum = 70
  ) THEN
    RAISE EXCEPTION 'otlet observability timing windows are invalid';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.operational_event_log
    WHERE event_id = batch_event
      AND task_name = 'versioned_observability_probe'
      AND task_names = jsonb_build_array(
        'versioned_observability_probe',
        'versioned_observability_probe_sibling'
      )
      AND model_name = expected_model
      AND evidence_redacted
      AND to_jsonb(operational_event_log)::text NOT LIKE '%batch-secret%'
  ) THEN
    RAISE EXCEPTION 'otlet batch event correlation is invalid';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = revision_hash
      AND metric_name = 'failure_occurrence'
      AND category = 'job:otlet.failure.v1.attempt_timeout'
      AND sample_count = 1
  ) OR NOT EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = revision_hash
      AND metric_name = 'schema_rejection_rate'
      AND sample_count = 1
      AND denominator = 2
      AND value_numeric = 0.5
  ) THEN
    RAISE EXCEPTION 'otlet observability failure or schema status is invalid';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = revision_hash
      AND metric_name = 'stale_age_ms'
      AND sample_count = 1
      AND value_numeric >= 600000
      AND status = 'stale'
  ) OR NOT EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = revision_hash
      AND metric_name = 'catch_up_age_ms'
      AND sample_count = 1
      AND value_numeric >= 1200000
      AND status = 'waiting'
  ) OR NOT EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = revision_hash
      AND metric_name = 'review_backlog_age_ms'
      AND sample_count = 1
      AND value_numeric >= 900000
      AND status = 'waiting'
  ) OR (
    SELECT COALESCE(sum(sample_count), 0)
    FROM observability_final_status
    WHERE metric_name = 'review_backlog_age_ms'
  ) <> (
    SELECT count(*) FROM otlet.review_queue
  ) THEN
    RAISE EXCEPTION 'otlet observability backlog ages are invalid';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE metric_name = 'cleanup_lag_ms'
      AND status = 'pending'
      AND value_numeric >= 300000
  ) OR NOT EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = revision_hash
      AND metric_name = 'resource_pressure'
      AND category = 'task_queued_input_bytes'
      AND value_numeric = maximum
      AND unit = 'bytes'
      AND status = 'pressured'
  ) OR NOT EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = revision_hash
      AND metric_name = 'resource_pressure'
      AND category = 'task_active_claims'
      AND value_numeric = maximum
      AND unit = 'jobs'
      AND status = 'pressured'
  ) OR (
    SELECT count(*)
    FROM observability_final_status
    WHERE task_name = 'versioned_observability_probe'
      AND workload_revision_hash = revision_hash
      AND metric_name = 'resource_pressure'
      AND status = 'pressured'
  ) <> 2 OR EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE metric_name = 'resource_pressure'
      AND status = 'pressured'
      AND (
        value_numeric IS NULL
        OR maximum IS NULL
        OR value_numeric < maximum
      )
  ) THEN
    RAISE EXCEPTION 'otlet cleanup lag or resource pressure is invalid';
  END IF;

  IF NOT (
    SELECT route_ready AND heartbeat_fresh
    FROM observability_live_checks
  ) OR NOT (
    SELECT heartbeat_stale AND route_not_ready
    FROM observability_degraded_checks
  ) THEN
    RAISE EXCEPTION 'otlet route readiness or heartbeat status is invalid: live=%, degraded=%',
      (SELECT to_jsonb(observability_live_checks) FROM observability_live_checks),
      (SELECT to_jsonb(observability_degraded_checks)
       FROM observability_degraded_checks);
  END IF;

  SELECT * INTO STRICT event_row
  FROM otlet.operational_event_log
  WHERE event_id = incident_event;
  IF event_row.event_schema <> 'otlet.observability.event.v1'
     OR event_row.event_version <> 1
     OR event_row.event_type <> 'other'
     OR event_row.event_class <> 'other'
     OR event_row.job_id <> incident_job
     OR event_row.workload_revision_hash <> revision_hash
     OR event_row.claim_attempt_index <> 1
     OR event_row.claim_identity_hash <> otlet.identity_hash(
       'claim_correlation',
       jsonb_build_object('job_id', incident_job, 'attempt_index', 1)
     )
     OR event_row.receipt_ids <> ARRAY[incident_receipt]
     OR event_row.worker_identity_hash IS NOT NULL
     OR event_row.action_ids <> ARRAY[incident_action]
     OR event_row.selection_role <> 'direct'
     OR to_jsonb(event_row)::text LIKE '%incident-secret-canary%' THEN
    RAISE EXCEPTION 'otlet redacted incident correlation is invalid';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.operational_event_log
    WHERE event_id = spoof_event
      AND event_type = 'other'
      AND runtime_name = 'other'
      AND claim_attempt_index IS NULL
      AND claim_identity_hash IS NULL
      AND worker_identity_hash IS NULL
      AND evidence_redacted
      AND to_jsonb(operational_event_log)::text NOT LIKE '%secret-canary%'
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.operational_event_log
    WHERE event_type = 'worker_started'
      AND runtime_name = 'linked_inproc'
      AND worker_identity_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.operational_event_log
    WHERE event_id = startup_failure_event
      AND event_type = 'worker_startup_failed'
      AND runtime_name = 'linked_inproc'
      AND worker_identity_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
      AND evidence_redacted
      AND to_jsonb(operational_event_log)::text NOT LIKE '%max_worker_rss_bytes%'
  ) THEN
    RAISE EXCEPTION 'otlet worker identity attribution is invalid';
  END IF;

  IF (
    SELECT count(*)
    FROM otlet.operational_event_log
    WHERE job_id = model_swap_job
      AND event_type = 'model_swap'
      AND claim_attempt_index = 1
  ) <> 1 OR EXISTS (
    SELECT 1
    FROM otlet.operational_event_log
    WHERE job_id = model_swap_job
      AND event_type = 'model_swap'
      AND claim_attempt_index <> 1
  ) THEN
    RAISE EXCEPTION 'otlet model swap claim fencing is invalid';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.operational_event_log
    WHERE event_id = cleanup_event
      AND event_type = 'other'
      AND event_class = 'other'
      AND evidence_redacted
      AND to_jsonb(operational_event_log)::text NOT LIKE '%cleanup-secret-canary%'
  ) OR EXISTS (
    SELECT 1
    FROM otlet.operational_event_log
    WHERE to_jsonb(operational_event_log)::text LIKE '%cleanup-secret-canary%'
       OR to_jsonb(operational_event_log)::text LIKE '%incident-secret-canary%'
       OR to_jsonb(operational_event_log)::text LIKE '%spoof-secret-canary%'
       OR to_jsonb(operational_event_log)::text LIKE '%runtime-secret-canary%'
       OR event_type = 'versioned_observability_future_secret'
       OR reason = 'cleanup-secret-canary'
  ) THEN
    RAISE EXCEPTION 'otlet unknown worker event redaction is invalid';
  END IF;

  IF NOT pg_catalog.has_table_privilege(
       'otlet_observability_auditor',
       'otlet.operational_event_log',
       'SELECT'
     )
     OR NOT pg_catalog.has_table_privilege(
       'otlet_observability_auditor',
       'otlet.operational_observability_status',
       'SELECT'
     )
     OR NOT pg_catalog.has_table_privilege(
       'otlet_observability_auditor',
       'otlet.labeled_quality_status',
       'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'otlet_observability_auditor',
       'otlet.worker_events',
       'SELECT'
     )
     OR NOT pg_catalog.has_function_privilege(
       'otlet_observability_auditor',
       'otlet.operational_observability_status_rows()',
       'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'otlet_observability_auditor',
       'otlet.labeled_quality_status_rows()',
       'EXECUTE'
     )
     OR EXISTS (
       SELECT 1
       FROM unnest(ARRAY[
         'otlet.operational_event_log',
         'otlet.operational_observability_status',
         'otlet.operational_observability_status_internal',
         'otlet.labeled_quality_status',
         'otlet.labeled_quality_status_internal'
       ]) relation(name)
       CROSS JOIN unnest(ARRAY[
         'otlet_observability_partial',
         'public'
       ]) principal(name)
       WHERE pg_catalog.has_table_privilege(
         principal.name,
         relation.name,
         'SELECT'
       )
     )
     OR EXISTS (
       SELECT 1
       FROM unnest(ARRAY[
         'otlet.operational_observability_status_rows()',
         'otlet.labeled_quality_status_rows()'
       ]) api(signature)
       CROSS JOIN unnest(ARRAY[
         'otlet_observability_partial',
         'public'
       ]) principal(name)
       WHERE pg_catalog.has_function_privilege(
         principal.name,
         api.signature,
         'EXECUTE'
       )
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.redaction_policy_status
      WHERE policy_version = 7
         AND withheld_fields @> ARRAY[
           'worker_event_message',
           'worker_event_detail'
         ]::text[]
         AND export_views @> ARRAY[
           'otlet.operational_observability_status',
           'otlet.labeled_quality_status'
         ]::text[]
     ) THEN
    RAISE EXCEPTION 'otlet observability access policy is invalid';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM observability_final_status
    WHERE metric_name LIKE '%quality%'
  ) OR EXISTS (SELECT 1 FROM otlet.verify_invariants()) THEN
    RAISE EXCEPTION 'otlet observability separation or invariants are invalid: quality=%, invariants=%',
      EXISTS (
        SELECT 1
        FROM observability_final_status
        WHERE metric_name LIKE '%quality%'
      ),
      COALESCE(
        (SELECT jsonb_agg(to_jsonb(invariant))
         FROM otlet.verify_invariants() invariant),
        '[]'::jsonb
      );
  END IF;
END;
$proof$;

SELECT 'windows|failures|backlogs|routes|heartbeats|cleanup|pressure|events|acl|invariants';
ROLLBACK;
SQL
)"

echo "versioned_observability_contract=$versioned_observability_contract"
[ "$versioned_observability_contract" = "windows|failures|backlogs|routes|heartbeats|cleanup|pressure|events|acl|invariants" ] || {
  echo "Versioned observability contract mismatch: $versioned_observability_contract" >&2
  exit 1
}

cleanup_observability_startup_probe
trap - EXIT
