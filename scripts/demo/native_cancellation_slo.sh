log "Checking native cancellation SLO"

native_cancel_sql_contract="$(psql_exec -qAt \
  -v model_name="$strong_model_name" <<'SQL'
BEGIN;
SET LOCAL otlet.administrative_reason = 'native cancellation SLO proof';
\o /dev/null
SELECT otlet.create_task(
  'native_cancel_slo_sql',
  NULL,
  'Return an empty object',
  '{"type":"object"}'::jsonb,
  :'model_name',
  '{"max_tokens":1,"reasoning":"off","inference_cache":false}'::jsonb
);
SELECT otlet.promote_configured_workload_revision('native_cancel_slo_sql');
CREATE ROLE native_cancel_portable_gap_role
NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
SELECT otlet.grant_portable_worker_access(
  'native_cancel_portable_gap_role'::regrole
);
SELECT otlet.register_portable_worker(
  'native-cancel-portable-gap',
  'native_cancel_portable_gap_role'::regrole,
  1,
  :'model_name',
  'native-cancel-proof',
  '1',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
);
WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    subject_id,
    input,
    status,
    attempts,
    started_at,
    leased_until,
    claim_token,
    cancel_requested_at,
    error
  ) VALUES (
    'native_cancel_slo_sql',
    'portable-gap',
    '{}'::jsonb,
    'cancel_requested',
    1,
    clock_timestamp(),
    clock_timestamp() + interval '5 minutes',
    'native-cancel-portable-gap-token',
    clock_timestamp() - interval '2 seconds',
    'canceled'
  )
  RETURNING *
)
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
  job.id,
  job.workload_revision_hash,
  worker.worker_id,
  worker.protocol_version,
  worker.runtime_identity_hash,
  otlet.portable_text_hash('native-cancel-portable-gap-incarnation'),
  job.attempts,
  'direct',
  otlet.portable_text_hash('native-cancel-portable-gap-token'),
  '{"compatible":true}'::jsonb
FROM inserted job
JOIN otlet.portable_workers worker
  ON worker.worker_id = 'native-cancel-portable-gap';
CREATE TEMP TABLE native_cancel_claims AS
WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    subject_id,
    input,
    status,
    attempts,
    started_at,
    leased_until,
    claim_token
  )
  VALUES
    (
      'native_cancel_slo_sql',
      'helper',
      '{}'::jsonb,
      'running',
      1,
      clock_timestamp(),
      clock_timestamp() + interval '5 minutes',
      'native-cancel-helper'
    ),
    (
      'native_cancel_slo_sql',
      'output-acceptance',
      '{}'::jsonb,
      'running',
      1,
      clock_timestamp(),
      clock_timestamp() + interval '5 minutes',
      'native-cancel-output'
    ),
    (
      'native_cancel_slo_sql',
      'failure-race',
      '{}'::jsonb,
      'running',
      1,
      clock_timestamp(),
      clock_timestamp() + interval '5 minutes',
      'native-cancel-failure'
    )
  RETURNING id, subject_id, claim_token
)
SELECT * FROM inserted;
CREATE TEMP TABLE native_cancel_running AS
SELECT otlet.observe_native_job_cancellation(
  id,
  claim_token,
  'model_load'
) AS canceled
FROM native_cancel_claims
WHERE subject_id = 'helper';
UPDATE otlet.jobs
SET status = 'cancel_requested',
    cancel_requested_at = clock_timestamp(),
    error = 'canceled'
WHERE id IN (SELECT id FROM native_cancel_claims);
SELECT otlet.observe_native_job_cancellation(
  id,
  claim_token,
  'prompt_decode'
)
FROM native_cancel_claims
WHERE subject_id = 'helper';
SELECT otlet.observe_native_job_cancellation(
  id,
  claim_token,
  'generation'
)
FROM native_cancel_claims
WHERE subject_id = 'helper';
SELECT otlet.stop_native_job_cancellation(id, claim_token)
FROM native_cancel_claims
WHERE subject_id = 'helper';
CREATE TEMP TABLE native_cancel_helper_stop AS
SELECT job.native_cancel_stopped_at
FROM native_cancel_claims claim
JOIN otlet.jobs job ON job.id = claim.id
WHERE claim.subject_id = 'helper';
SELECT otlet.stop_native_job_cancellation(id, claim_token)
FROM native_cancel_claims
WHERE subject_id = 'helper';
CREATE TEMP TABLE native_cancel_completion_result AS
SELECT completion.*
FROM native_cancel_claims claim
CROSS JOIN LATERAL otlet.complete_and_materialize_job(
  claim.id,
  '{}'::jsonb,
  '{"output":{},"actions":[]}',
  '[]'::jsonb,
  NULL,
  NULL,
  NULL,
  otlet.portable_text_hash('{"output":{},"actions":[]}'),
  '{"schema_validation_status":"passed"}'::jsonb,
  :'model_name',
  'direct',
  'accepted_by_direct_task',
  claim.claim_token
) completion
WHERE claim.subject_id = 'output-acceptance';
CREATE TEMP TABLE native_cancel_failure_result AS
SELECT terminal.status
FROM native_cancel_claims claim
CROSS JOIN LATERAL otlet.fail_job(
  claim.id,
  'native failure raced cancellation',
  model_name => :'model_name',
  expected_claim_token => claim.claim_token
) terminal
WHERE claim.subject_id = 'failure-race';
CREATE FUNCTION pg_temp.native_cancel_rejections(
  helper_id bigint,
  helper_token text,
  terminal_id bigint,
  terminal_token text
) RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
  invalid_phase boolean := false;
  null_phase boolean := false;
  stale_claim boolean := false;
  terminal_claim boolean := false;
BEGIN
  BEGIN
    PERFORM otlet.observe_native_job_cancellation(
      helper_id, helper_token, 'invalid'
    );
  EXCEPTION WHEN OTHERS THEN
    invalid_phase := true;
  END;
  BEGIN
    PERFORM otlet.observe_native_job_cancellation(
      helper_id, helper_token, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    null_phase := true;
  END;
  BEGIN
    PERFORM otlet.observe_native_job_cancellation(
      helper_id, 'stale', 'prompt_decode'
    );
  EXCEPTION WHEN OTHERS THEN
    stale_claim := true;
  END;
  BEGIN
    PERFORM otlet.observe_native_job_cancellation(
      terminal_id, terminal_token, 'output_acceptance'
    );
  EXCEPTION WHEN OTHERS THEN
    terminal_claim := true;
  END;
  RETURN invalid_phase AND null_phase AND stale_claim AND terminal_claim;
END
$function$;
\o
WITH helper AS (
  SELECT job.*
  FROM native_cancel_claims claim
  JOIN otlet.jobs job ON job.id = claim.id
  WHERE claim.subject_id = 'helper'
), output_acceptance AS (
  SELECT job.*, claim.claim_token AS original_claim_token
  FROM native_cancel_claims claim
  JOIN otlet.jobs job ON job.id = claim.id
  WHERE claim.subject_id = 'output-acceptance'
), failure_race AS (
  SELECT job.*
  FROM native_cancel_claims claim
  JOIN otlet.jobs job ON job.id = claim.id
  WHERE claim.subject_id = 'failure-race'
)
SELECT concat_ws(
  '|',
  (SELECT canceled FROM native_cancel_running),
  helper.native_cancel_observed_phase,
  helper.native_cancel_stopped_at >= helper.native_cancel_observed_at,
  helper.native_cancel_stopped_at = (
    SELECT native_cancel_stopped_at FROM native_cancel_helper_stop
  ),
  (
    SELECT count(*)
    FROM otlet.worker_events event
    WHERE event.job_id = helper.id
      AND event.event_type = 'job_cancel_observed'
  ),
  (
    SELECT bool_and(event.created_at = helper.native_cancel_observed_at)
    FROM otlet.worker_events event
    WHERE event.job_id = helper.id
      AND event.event_type = 'job_cancel_observed'
  ),
  output_acceptance.status,
  output_acceptance.native_cancel_observed_phase,
  output_acceptance.native_cancel_stopped_at >=
    output_acceptance.native_cancel_observed_at,
  output_acceptance.finished_at >= output_acceptance.native_cancel_stopped_at,
  (
    SELECT output_id IS NULL AND completion_error = 'canceled'
    FROM native_cancel_completion_result
  ),
  (
    SELECT count(*)
    FROM otlet.outputs output
    WHERE output.job_id = output_acceptance.id
  ),
  failure_race.status,
  failure_race.status = (SELECT status FROM native_cancel_failure_result),
  failure_race.native_cancel_observed_phase,
  failure_race.native_cancel_stopped_at >=
    failure_race.native_cancel_observed_at,
  (
    SELECT status.active_unobserved_cancellations = 0
      AND status.overdue_unobserved_cancellations = 0
      AND job.native_cancel_observed_at IS NULL
    FROM otlet.native_cancellation_slo_status status
    CROSS JOIN otlet.jobs job
    WHERE status.phase = 'all'
      AND job.task_name = 'native_cancel_slo_sql'
      AND job.subject_id = 'portable-gap'
  ),
  pg_temp.native_cancel_rejections(
    helper.id,
    helper.claim_token,
    output_acceptance.id,
    output_acceptance.original_claim_token
  ),
  NOT has_table_privilege(
    'public',
    'otlet.native_cancellation_slo_status',
    'SELECT'
  ) AND NOT has_function_privilege(
    'public',
    'otlet.observe_native_job_cancellation(bigint,text,text)',
    'EXECUTE'
  ) AND NOT has_function_privilege(
    'public',
    'otlet.stop_native_job_cancellation(bigint,text)',
    'EXECUTE'
  )
)
FROM helper
CROSS JOIN output_acceptance
CROSS JOIN failure_race;
ROLLBACK;
SQL
)"

[ "$native_cancel_sql_contract" = \
  "f|prompt_decode|t|t|1|t|canceled|output_acceptance|t|t|t|0|canceled|t|output_acceptance|t|t|t|t" ] || {
  echo "Expected fenced first-write cancellation evidence, got $native_cancel_sql_contract" >&2
  exit 1
}

native_cancel_percentile_contract="$(psql_exec -qAt \
  -v model_name="$strong_model_name" <<'SQL'
BEGIN;
SET LOCAL otlet.administrative_reason = 'native cancellation percentile proof';
\o /dev/null
SELECT otlet.create_task(
  'native_cancel_slo_percentiles',
  NULL,
  'Return an empty object',
  '{"type":"object"}'::jsonb,
  :'model_name',
  '{"max_tokens":1,"reasoning":"off","inference_cache":false}'::jsonb
);
SELECT otlet.promote_configured_workload_revision(
  'native_cancel_slo_percentiles'
);
UPDATE otlet.jobs
SET native_cancel_observed_at = NULL,
    native_cancel_observed_phase = NULL,
    native_cancel_stopped_at = NULL
WHERE native_cancel_observed_at IS NOT NULL;
WITH phase(phase) AS (
  VALUES
    ('claimed_batch_wait'),
    ('model_load'),
    ('prompt_decode'),
    ('generation'),
    ('inference_cache_hit'),
    ('strong_fallback'),
    ('output_acceptance')
), fixture AS (
  SELECT
    phase.phase,
    sample,
    clock_timestamp() - interval '1 hour' AS requested_at
  FROM phase
  CROSS JOIN generate_series(1, 20) sample
)
INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  error,
  cancel_requested_at,
  native_cancel_observed_at,
  native_cancel_observed_phase,
  native_cancel_stopped_at,
  finished_at
)
SELECT
  'native_cancel_slo_percentiles',
  phase || '-' || sample::text,
  '{}'::jsonb,
  'canceled',
  'canceled',
  requested_at,
  requested_at + make_interval(secs => sample / 1000.0),
  phase,
  requested_at + make_interval(secs => (sample + 10) / 1000.0),
  requested_at + make_interval(secs => (sample + 10) / 1000.0)
FROM fixture;
\o
SELECT concat_ws(
  '|',
  observation_samples,
  stop_samples,
  request_to_observation_p95_ms,
  request_to_observation_p99_ms,
  cancel_to_stop_p95_ms,
  cancel_to_stop_p99_ms,
  observation_target_met,
  measurement_status,
  active_unobserved_cancellations,
  active_observed_not_stopped,
  overdue_unobserved_cancellations,
  finer_preemption_required,
  (
    SELECT count(*) = 8
      AND count(*) FILTER (
        WHERE phase <> 'all'
          AND observation_samples = 20
          AND stop_samples = 20
          AND request_to_observation_p95_ms = 19
          AND request_to_observation_p99_ms = 20
          AND cancel_to_stop_p95_ms = 29
          AND cancel_to_stop_p99_ms = 30
      ) = 7
    FROM otlet.native_cancellation_slo_status
  )
)
FROM otlet.native_cancellation_slo_status
WHERE phase = 'all';
\o /dev/null
WITH missed AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name = 'native_cancel_slo_percentiles'
  ORDER BY id
  LIMIT 2
)
UPDATE otlet.jobs job
SET native_cancel_observed_at =
      job.cancel_requested_at + interval '2 seconds',
    native_cancel_stopped_at =
      job.cancel_requested_at + interval '2010 milliseconds',
    finished_at =
      job.cancel_requested_at + interval '2010 milliseconds'
FROM missed
WHERE job.id = missed.id;
\o
SELECT concat_ws(
  '|',
  measurement_status,
  observation_target_met,
  finer_preemption_required,
  request_to_observation_p99_ms
)
FROM otlet.native_cancellation_slo_status
WHERE phase = 'all';
ROLLBACK;
SQL
)"

[ "$native_cancel_percentile_contract" = \
  $'140|140|19|20|29|30|t|met|0|0|0|f|t\nmissed|f|t|2000' ] || {
  echo "Expected exact phase percentiles and measured preemption gate, got $native_cancel_percentile_contract" >&2
  exit 1
}

cancel_wait_task="cancel_claimed_wait_demo"
cleanup_task "$cancel_wait_task"
psql_exec -qAt -v task_name="$cancel_wait_task" -v model_name="$strong_model_name" \
  >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT subject_id, jsonb_build_object('payload', payload) AS input
    FROM (VALUES
      ('01-hold', repeat('hold native batch ', 600)),
      ('02-wait', 'wait')
    ) source(subject_id, payload)
    ORDER BY subject_id COLLATE "C"
  $source$::text,
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":256,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"source_fields":["payload"]}'::jsonb
);
UPDATE otlet.production_policy
SET worker_claim_batch_size = 8
WHERE name = 'default';
SELECT otlet.run_task(:'task_name');
SQL
cancel_wait_ids=""
for _ in $(seq 1 300); do
  cancel_wait_ids="$(psql_exec -qAt -v task_name="$cancel_wait_task" <<'SQL'
WITH first_job AS (
  SELECT id, status
  FROM otlet.jobs
  WHERE task_name = :'task_name' AND subject_id = '01-hold'
), second_job AS (
  SELECT id, status
  FROM otlet.jobs
  WHERE task_name = :'task_name' AND subject_id = '02-wait'
)
SELECT first_job.id::text || '|' || second_job.id::text
FROM first_job
CROSS JOIN second_job
WHERE first_job.status = 'running'
  AND second_job.status = 'running'
  AND (
    SELECT count(*)
    FROM otlet.worker_events event
    WHERE event.job_id = first_job.id AND event.event_type = 'job_started'
  ) = 1
  AND (
    SELECT count(*)
    FROM otlet.worker_events event
    WHERE event.job_id = second_job.id AND event.event_type = 'job_started'
  ) = 0;
SQL
)"
  [ -n "$cancel_wait_ids" ] && break
  sleep 0.1
done
[ -n "$cancel_wait_ids" ] || {
  echo "Timed out waiting for a held native batch claim" >&2
  exit 1
}
IFS='|' read -r cancel_hold_job_id cancel_wait_job_id <<<"$cancel_wait_ids"
psql_exec -qAt -v wait_id="$cancel_wait_job_id" -v hold_id="$cancel_hold_job_id" \
  >/dev/null <<'SQL'
SELECT count(*)
FROM otlet.request_job_cancellation(
  :'wait_id'::bigint,
  'demo cancel during claimed batch wait'
);
SELECT count(*)
FROM otlet.request_job_cancellation(
  :'hold_id'::bigint,
  'demo release claimed batch holder'
);
SQL
wait_task_failed "$cancel_wait_task" 2 240 1
cancel_wait_contract="$(psql_exec -qAt -v job_id="$cancel_wait_job_id" <<'SQL'
WITH job_row AS (
  SELECT * FROM otlet.jobs WHERE id = :'job_id'::bigint
)
SELECT concat_ws(
  '|',
  job.status,
  job.native_cancel_observed_phase,
  job.native_cancel_observed_at >= job.cancel_requested_at,
  job.native_cancel_stopped_at >= job.native_cancel_observed_at,
  job.finished_at >= job.native_cancel_stopped_at,
  (
    SELECT count(*)
    FROM otlet.worker_events event
    WHERE event.job_id = job.id AND event.event_type = 'job_started'
  ),
  (
    SELECT count(*)
    FROM otlet.worker_events event
    WHERE event.job_id = job.id AND event.event_type = 'job_cancel_observed'
  ),
  (
    SELECT count(*)
    FROM otlet.inference_receipts receipt
    WHERE receipt.job_id = job.id AND receipt.status = 'canceled'
  ),
  (SELECT count(*) FROM otlet.outputs output WHERE output.job_id = job.id)
)
FROM job_row job;
SQL
)"
[ "$cancel_wait_contract" = "canceled|claimed_batch_wait|t|t|t|0|1|1|0" ] || {
  echo "Expected pre-start claimed-batch cancellation, got $cancel_wait_contract" >&2
  exit 1
}

cancel_decode_task="cancel_decode_worker_demo"
cleanup_task "$cancel_decode_task"
psql_exec -v task_name="$cancel_decode_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'cancel-decode-1'::text AS subject_id,
           jsonb_build_object('payload', repeat('cancel decode ', 600)) AS input
  $source$::text,
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":256,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"source_fields":["payload"]}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
cancel_decode_job_id=""
for _ in $(seq 1 300); do
  cancel_decode_job_id="$(psql_exec -qAt -v task_name="$cancel_decode_task" <<'SQL'
SELECT id FROM otlet.jobs
WHERE task_name = :'task_name' AND status = 'running'
ORDER BY id DESC LIMIT 1;
SQL
)"
  if [ -n "$cancel_decode_job_id" ]; then
    psql_exec -qAt -v job_id="$cancel_decode_job_id" >/dev/null <<'SQL'
SELECT count(*)
FROM otlet.request_job_cancellation(
  :'job_id'::bigint,
  'demo cancel during native runtime'
);
SQL
    break
  fi
  cancel_decode_terminal="$(psql_exec -qAt -v task_name="$cancel_decode_task" <<'SQL'
SELECT COALESCE(max(status), '') FROM otlet.jobs
WHERE task_name = :'task_name'
  AND status IN ('complete','failed','canceled');
SQL
)"
  if [ -n "$cancel_decode_terminal" ]; then
    echo "Expected native cancel smoke to run before terminal status, got $cancel_decode_terminal" >&2
    exit 1
  fi
  sleep 0.2
done
[ -n "$cancel_decode_job_id" ] || {
  echo "Timed out waiting for native cancel smoke job to run" >&2
  exit 1
}
wait_task_failed "$cancel_decode_task" 1 240 1
cancel_decode_contract="$(psql_exec -qAt \
  -v task_name="$cancel_decode_task" \
  -v model_name="$strong_model_name" <<'SQL'
WITH job_row AS (
  SELECT *
  FROM otlet.jobs
  WHERE task_name = :'task_name'
  ORDER BY id DESC
  LIMIT 1
), receipt_row AS (
  SELECT status, selection_status, selection_reason, schema_validation_status
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
), phase_status AS (
  SELECT *
  FROM otlet.native_cancellation_slo_status
  WHERE phase = (SELECT native_cancel_observed_phase FROM job_row)
)
SELECT concat_ws(
  '|',
  job.status,
  job.error = 'demo cancel during native runtime',
  receipt.status,
  receipt.selection_status,
  receipt.selection_reason,
  COALESCE(receipt.schema_validation_status, ''),
  (SELECT count(*) FROM otlet.outputs output WHERE output.job_id = job.id),
  runtime.runtime_status IN ('ready', 'cold'),
  runtime.slot_state IN ('ready', 'cold'),
  job.native_cancel_observed_phase,
  job.native_cancel_observed_at >= job.cancel_requested_at,
  job.native_cancel_stopped_at >= job.native_cancel_observed_at,
  job.finished_at >= job.native_cancel_stopped_at,
  (
    SELECT count(*)
    FROM otlet.worker_events event
    WHERE event.job_id = job.id
      AND event.event_type = 'job_cancel_observed'
  ),
  phase_status.observation_samples >= 1,
  phase_status.stop_samples >= 1,
  phase_status.request_to_observation_p95_ms IS NOT NULL,
  phase_status.request_to_observation_p99_ms IS NOT NULL,
  phase_status.cancel_to_stop_p95_ms IS NOT NULL,
  phase_status.cancel_to_stop_p99_ms IS NOT NULL,
  phase_status.measurement_status = CASE
    WHEN phase_status.observation_samples <
      phase_status.minimum_observation_samples THEN 'collecting'
    WHEN phase_status.request_to_observation_p99_ms <=
      phase_status.cancellation_observation_p99_target_ms THEN 'met'
    ELSE 'missed'
  END,
  phase_status.finer_preemption_required =
    (
      phase_status.observation_samples >=
        phase_status.minimum_observation_samples
      AND
      phase_status.request_to_observation_p99_ms >
      phase_status.cancellation_observation_p99_target_ms
    )
)
FROM job_row job
CROSS JOIN receipt_row receipt
JOIN otlet.runtime_status runtime
  ON runtime.model_name = :'model_name'
CROSS JOIN phase_status;
SQL
)"
echo "native_cancellation_sql_contract=$native_cancel_sql_contract"
echo "native_cancellation_percentile_contract=$native_cancel_percentile_contract"
echo "native_cancellation_claimed_wait_contract=$cancel_wait_contract"
echo "native_cancellation_worker_contract=$cancel_decode_contract"
require_regex \
  "$cancel_decode_contract" \
  '^canceled\|t\|canceled\|failed\|canceled\|not_run\|0\|t\|t\|(claimed_batch_wait|model_load|prompt_decode|generation|inference_cache_hit|strong_fallback|output_acceptance)\|t\|t\|t\|1\|t\|t\|t\|t\|t\|t\|t\|t$' \
  "Expected measurable native cancellation with a healthy worker"
