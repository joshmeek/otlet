log "Checking interactive and asynchronous service quantum"

service_quantum_task="service_quantum_demo"
cleanup_task "$service_quantum_task"

service_quantum_policy_contract="$(psql_value <<'SQL'
BEGIN;
CREATE FUNCTION pg_temp.reject_invalid_service_targets() RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
  interactive_rejected boolean := false;
  asynchronous_rejected boolean := false;
  cancellation_rejected boolean := false;
BEGIN
  BEGIN
    UPDATE otlet.production_policy
    SET interactive_queue_age_p99_target_ms = 0
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    interactive_rejected := true;
  END;
  BEGIN
    UPDATE otlet.production_policy
    SET asynchronous_queue_age_p99_target_ms = 0
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    asynchronous_rejected := true;
  END;
  BEGIN
    UPDATE otlet.production_policy
    SET cancellation_observation_p99_target_ms = 0
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    cancellation_rejected := true;
  END;
  RETURN interactive_rejected AND asynchronous_rejected AND cancellation_rejected;
END
$function$;

SELECT policy.interactive_queue_age_p99_target_ms::text || '|' ||
       policy.asynchronous_queue_age_p99_target_ms::text || '|' ||
       policy.cancellation_observation_p99_target_ms::text || '|' ||
       policy.worker_claim_batch_size::text || '|' ||
       (state.value ->> 'service_policy') || '|' ||
       (state.value ->> 'queue_policy') || '|' ||
       (state.value ->> 'infer_now_request_quantum') || '|' ||
       (state.value ->> 'queued_claim_batch_quantum') || '|' ||
       (state.value ->> 'priority_classes') || '|' ||
       (state.value ->> 'service_measurement_status') || '|' ||
       (
         policy.asynchronous_queue_age_p99_target_ms
           <= EXTRACT(epoch FROM policy.max_queue_age) * 1000
       )::text || '|' ||
       pg_temp.reject_invalid_service_targets()::text
FROM otlet.production_policy_status policy
CROSS JOIN LATERAL (SELECT otlet.worker_infer_now_state()) state(value);
ROLLBACK;
SQL
)"

psql_exec -qAt -v task_name="$service_quantum_task" -v model_name="$strong_model_name" \
  >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'queued-' || value::text AS subject_id,
           jsonb_build_object('class', 'queued') AS input
    FROM generate_series(1, 16) value
  $source$::text,
  'Return one JSON object with exactly two top-level keys: "output" then "actions". output must be {}. actions must be []. Do not close the outer object until actions has been written. No markdown.',
  '{"type":"object"}'::jsonb,
  :'model_name',
  '{"max_tokens":128,"reasoning":"off","inference_cache":true}'::jsonb,
  input_shaping => '{"source_fields":["class"]}'::jsonb
);
SELECT otlet.promote_configured_workload_revision(:'task_name');
UPDATE otlet.production_policy
SET max_attempts = 1,
    worker_claim_batch_size = 8,
    worker_claim_task_cursor = ''
WHERE name = 'default';
SQL

service_quantum_event_floor="$(psql_value <<'SQL'
SELECT COALESCE(max(id), 0) FROM otlet.worker_events;
SQL
)"
service_quantum_before="$(psql_value <<'SQL'
SELECT (state ->> 'submitted') || '|' ||
       (state ->> 'timeouts') || '|' ||
       (state ->> 'busy_rejections')
FROM (SELECT otlet.worker_infer_now_state() AS state) current;
SQL
)"
IFS='|' read -r service_quantum_submitted_before service_quantum_timeouts_before \
  service_quantum_busy_before <<<"$service_quantum_before"

psql_exec -qAt -v task_name="$service_quantum_task" >/dev/null <<'SQL' &
BEGIN;
SELECT 1
FROM otlet.production_policy
WHERE name = 'default'
FOR UPDATE;
SELECT otlet.run_task(:'task_name');
SELECT pg_sleep(5);
COMMIT;
SQL
service_quantum_lock_pid="$!"
sleep 0.2

service_quantum_outputs=()
service_quantum_pids=()
service_quantum_saturated=true
for request in 1 2 3 4; do
  output="$(mktemp "${TMPDIR:-/tmp}/otlet-service-quantum.XXXXXX")"
  service_quantum_outputs+=("$output")
  psql_exec -qAt -v task_name="$service_quantum_task" -v subject="interactive-$request" \
    >"$output" <<'SQL' &
SELECT otlet.worker_infer_now(
  :'task_name',
  :'subject',
  '{"class":"interactive"}'::jsonb,
  30000
);
SQL
  service_quantum_pids+=("$!")
  service_quantum_request_queued=false
  for _ in {1..80}; do
    if [ "$(psql_value <<'SQL'
SELECT otlet.worker_infer_now_state() ->> 'queue_depth';
SQL
)" = "$request" ]; then
      service_quantum_request_queued=true
      break
    fi
    sleep 0.05
  done
  if [ "$service_quantum_request_queued" = false ]; then
    service_quantum_saturated=false
    break
  fi
done

service_quantum_background_ok=true
for pid in "${service_quantum_pids[@]}"; do
  if ! wait "$pid"; then
    service_quantum_background_ok=false
  fi
done
if ! wait "$service_quantum_lock_pid"; then
  service_quantum_background_ok=false
fi

service_quantum_ids_ok=true
for output in "${service_quantum_outputs[@]}"; do
  if ! [[ "$(tr -d '[:space:]' <"$output")" =~ ^[1-9][0-9]*$ ]]; then
    service_quantum_ids_ok=false
  fi
done

service_quantum_terminal=false
for _ in {1..300}; do
  if [ "$(psql_value -v task_name="$service_quantum_task" <<'SQL'
SELECT count(*) FILTER (WHERE status IN ('complete', 'failed', 'canceled'))
FROM otlet.jobs
WHERE task_name = :'task_name';
SQL
)" = "20" ]; then
    service_quantum_terminal=true
    break
  fi
  sleep 0.1
done

service_quantum_contract="$(psql_value \
  -v task_name="$service_quantum_task" \
  -v event_floor="$service_quantum_event_floor" \
  -v submitted_before="$service_quantum_submitted_before" \
  -v timeouts_before="$service_quantum_timeouts_before" \
  -v busy_before="$service_quantum_busy_before" <<'SQL'
WITH starts AS (
  SELECT
    row_number() OVER (ORDER BY event.id) AS ordinal,
    job.id AS job_id,
    job.job_origin,
    job.subject_id
  FROM otlet.worker_events event
  JOIN otlet.jobs job ON job.id = event.job_id
  WHERE event.id > :'event_floor'::bigint
    AND event.event_type = 'job_started'
    AND job.task_name = :'task_name'
), sequence AS (
  SELECT string_agg(job_origin, ',' ORDER BY ordinal) AS origins,
         string_agg(subject_id, ',' ORDER BY ordinal)
           FILTER (WHERE job_origin = 'direct_ask') AS direct_subjects,
         count(*) AS starts,
         count(DISTINCT job_id) AS distinct_jobs
  FROM starts
), current_state AS (
  SELECT otlet.worker_infer_now_state() AS value
)
SELECT sequence.origins || '|' ||
       sequence.direct_subjects || '|' ||
       sequence.starts::text || '|' ||
       sequence.distinct_jobs::text || '|' ||
       (
         (current_state.value ->> 'submitted')::bigint
           - :'submitted_before'::bigint
       )::text || '|' ||
       (
         (current_state.value ->> 'timeouts')::bigint
           - :'timeouts_before'::bigint
       )::text || '|' ||
       (
         (current_state.value ->> 'busy_rejections')::bigint
           - :'busy_before'::bigint
       )::text
FROM sequence
CROSS JOIN current_state;
SQL
)"

for output in "${service_quantum_outputs[@]}"; do
  rm -f "$output"
done
cleanup_task "$service_quantum_task"
psql_exec -qAt >/dev/null <<'SQL'
UPDATE otlet.production_policy
SET max_attempts = 3,
    worker_claim_batch_size = 8,
    worker_claim_task_cursor = ''
WHERE name = 'default';
SQL

echo "service_quantum_policy_contract=$service_quantum_policy_contract"
echo "service_quantum_contract=$service_quantum_contract"

[ "$service_quantum_policy_contract" = \
  "30000|30000|1000|8|work_conserving_round_robin|oldest_request_id_first|1|1|false|native_cancellation_measured_queue_targets_declared|true|true" ] || {
  echo "Expected declared service targets and fixed native quanta, got $service_quantum_policy_contract" >&2
  exit 1
}
[ "$service_quantum_saturated" = true ] || {
  echo "Expected all four infer-now slots to be active before service resumed" >&2
  exit 1
}
[ "$service_quantum_background_ok" = true ] && [ "$service_quantum_ids_ok" = true ] || {
  echo "Expected four successful infer-now callers" >&2
  exit 1
}
[ "$service_quantum_terminal" = true ] || {
  echo "Expected all 20 service-quantum jobs to reach terminal state" >&2
  exit 1
}
case "$service_quantum_contract" in
  "direct_ask,task_run,task_run,task_run,task_run,task_run,task_run,task_run,task_run,direct_ask,task_run,task_run,task_run,task_run,task_run,task_run,task_run,task_run,direct_ask,direct_ask|interactive-1,interactive-2,interactive-3,interactive-4|20|20|4|0|0" | \
  "task_run,task_run,task_run,task_run,task_run,task_run,task_run,task_run,direct_ask,task_run,task_run,task_run,task_run,task_run,task_run,task_run,task_run,direct_ask,direct_ask,direct_ask|interactive-1,interactive-2,interactive-3,interactive-4|20|20|4|0|0") ;;
  *)
    echo "Expected work-conserving one-request/one-batch alternation, got $service_quantum_contract" >&2
    exit 1
    ;;
esac
