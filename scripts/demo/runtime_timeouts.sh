attempt_timeout_task="attempt_timeout_demo"
cleanup_task "$attempt_timeout_task"
psql_exec -v task_name="$attempt_timeout_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'timeout-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":256,"reasoning":"off","inference_cache":false,"max_attempt_ms":1}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
attempt_timeout_failed="0"
attempt_timeout_complete="0"
for _ in $(seq 1 180); do
  attempt_timeout_state="$(psql_exec -qAt -v task_name="$attempt_timeout_task" <<'SQL'
SELECT count(*) FILTER (WHERE status IN ('queued','running','cancel_requested'))::text || '|' ||
       count(*) FILTER (WHERE status = 'failed')::text || '|' ||
       count(*) FILTER (WHERE status = 'complete')::text
FROM otlet.jobs
WHERE task_name = :'task_name';
SQL
)"
  attempt_timeout_failed="$(cut -d'|' -f2 <<<"$attempt_timeout_state")"
  attempt_timeout_complete="$(cut -d'|' -f3 <<<"$attempt_timeout_state")"
  if [ "$attempt_timeout_failed" = "1" ]; then
    break
  fi
  if [ "$attempt_timeout_complete" != "0" ]; then
    echo "Expected timeout smoke to fail, got state $attempt_timeout_state" >&2
    exit 1
  fi
  sleep 1
done
[ "$attempt_timeout_failed" = "1" ] || {
  echo "Timed out waiting for attempt-timeout smoke, complete=$attempt_timeout_complete failed=$attempt_timeout_failed" >&2
  exit 1
}
attempt_timeout_contract="$(psql_exec -qAt \
  -v task_name="$attempt_timeout_task" \
  -v model_name="$strong_model_name" <<'SQL'
SELECT j.status || '|' ||
       COALESCE(j.error, '') || '|' ||
       COALESCE(s.selection_reason, '') || '|' ||
       COALESCE(s.schema_validation_status, '') || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM otlet.inference_receipt_trace_status s
JOIN otlet.jobs j ON j.id = s.job_id
JOIN otlet.runtime_status rs
  ON rs.model_name = :'model_name'
WHERE s.task_name = :'task_name'
ORDER BY s.receipt_id DESC
LIMIT 1;
SQL
)"
echo "attempt_timeout_contract=$attempt_timeout_contract"
[ "$attempt_timeout_contract" = "failed|attempt_timeout|attempt_timeout|failed|ready|ready" ] || {
  echo "Expected attempt timeout to fail cleanly with healthy worker, got $attempt_timeout_contract" >&2
  exit 1
}
attempt_timeout_clamp_contract="$(psql_exec -qAt <<'SQL'
SELECT otlet.effective_task_max_attempt_ms('{"max_attempt_ms":1}'::jsonb, max_attempt_ms)::text || '|' ||
       otlet.effective_task_max_attempt_ms('{}'::jsonb, max_attempt_ms)::text || '|' ||
       otlet.effective_task_max_attempt_ms('{"max_attempt_ms":999999999}'::jsonb, max_attempt_ms)::text
FROM otlet.production_policy_status;
SQL
)"
echo "attempt_timeout_clamp_contract=$attempt_timeout_clamp_contract"
[ "$attempt_timeout_clamp_contract" = "1|300000|300000" ] || {
  echo "Expected per-task timeout clamp to leave default/global budget unaffected, got $attempt_timeout_clamp_contract" >&2
  exit 1
}

requester_timeout_before="$(psql_exec -qAt <<'SQL'
SELECT (s ->> 'timeouts') || '|' || (s ->> 'abort_requests')
FROM (SELECT otlet.worker_infer_now_state() AS s) state;
SQL
)"
IFS='|' read -r requester_timeouts_before requester_aborts_before <<<"$requester_timeout_before"
requester_timeout_error=""
if requester_timeout_error="$(psql_exec -qAt -v model_name="$strong_model_name" <<'SQL' 2>&1
SELECT * FROM otlet.ask(
  :'model_name',
  'Return one JSON object only with top-level output and actions. output has status equal ok. actions is empty. No markdown.',
  jsonb_build_object('payload', repeat('request timeout ', 300)),
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  '{"max_tokens":512,"reasoning":"off","inference_cache":false}'::jsonb,
  500
);
SQL
)"; then
  echo "Expected requester timeout smoke to fail closed" >&2
  exit 1
fi
require_contains "$requester_timeout_error" "otlet ask worker is busy" "Expected requester timeout smoke to report no synchronous result"
requester_timeout_job_id="$(psql_exec -qAt -c "SELECT otlet.worker_infer_now_state() ->> 'last_cancel_job_id';")"
[ -n "$requester_timeout_job_id" ] && [ "$requester_timeout_job_id" != "0" ] || {
  echo "Expected requester timeout smoke to identify the canceled job" >&2
  exit 1
}
for _ in $(seq 1 300); do
  requester_timeout_status="$(psql_exec -qAt -v job_id="$requester_timeout_job_id" <<'SQL'
SELECT status FROM otlet.jobs WHERE id = :'job_id'::bigint;
SQL
)"
  case "$requester_timeout_status" in
    canceled|failed|complete) break ;;
  esac
  sleep 0.2
done
requester_timeout_contract="$(psql_exec -qAt \
  -v job_id="$requester_timeout_job_id" \
  -v model_name="$strong_model_name" \
  -v timeouts_before="$requester_timeouts_before" \
  -v aborts_before="$requester_aborts_before" <<'SQL'
WITH infer AS (
  SELECT otlet.worker_infer_now_state() AS state
), job_row AS (
  SELECT * FROM otlet.jobs WHERE id = :'job_id'::bigint
), receipt_row AS (
  SELECT * FROM otlet.inference_receipts
  WHERE job_id = :'job_id'::bigint
  ORDER BY id DESC
  LIMIT 1
)
SELECT j.status || '|' ||
       (j.error = 'infer-now timeout requested job cancellation')::text || '|' ||
       r.status || '|' || r.selection_reason || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       (SELECT count(*) FROM otlet.actions WHERE job_id = j.id)::text || '|' ||
       ((infer.state ->> 'timeouts')::bigint > :'timeouts_before'::bigint)::text || '|' ||
       ((infer.state ->> 'abort_requests')::bigint > :'aborts_before'::bigint)::text || '|' ||
       ((infer.state ->> 'last_cancel_job_id')::bigint = j.id)::text || '|' ||
       rs.resident_worker_count::text || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM job_row j
JOIN receipt_row r ON r.job_id = j.id
CROSS JOIN infer
JOIN otlet.runtime_status rs ON rs.model_name = :'model_name';
SQL
)"
echo "requester_timeout_contract=$requester_timeout_contract"
