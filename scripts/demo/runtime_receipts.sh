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
[ "$requester_timeout_contract" = "canceled|true|canceled|canceled|0|0|true|true|true|1|ready|ready" ] || {
  echo "Expected requester timeout to leave no late output and one healthy worker, got $requester_timeout_contract" >&2
  exit 1
}

malformed_schema_task="malformed_schema_worker_demo"
cleanup_task "$malformed_schema_task"
psql_exec -v task_name="$malformed_schema_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'malformed-schema-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only.',
  '{"type":"not_a_valid_json_schema_type"}'::jsonb,
  :'model_name',
  '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_failed "$malformed_schema_task" 1 120 1
malformed_schema_contract="$(psql_exec -qAt \
  -v task_name="$malformed_schema_task" \
  -v model_name="$strong_model_name" <<'SQL'
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = :'task_name'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, selection_reason, schema_validation_status, trace_summary
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
)
SELECT j.status || '|' ||
       (j.error LIKE 'invalid output schema:%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.selection_reason || '|' ||
       r.schema_validation_status || '|' ||
       COALESCE(r.trace_summary ->> 'stop_reason', '') || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM job_row j
CROSS JOIN receipt_row r
JOIN otlet.runtime_status rs
  ON rs.model_name = :'model_name';
SQL
)"
echo "malformed_schema_worker_contract=$malformed_schema_contract"
[ "$malformed_schema_contract" = "failed|true|failed|failed|direct_attempt_failed|failed|invalid_output_schema|0|ready|ready" ] || {
  echo "Expected malformed schema to produce a clean failed receipt and healthy worker, got $malformed_schema_contract" >&2
  exit 1
}

rss_budget_task="rss_budget_worker_demo"
cleanup_task "$rss_budget_task"
psql_exec -v task_name="$rss_budget_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'rss-budget-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":16,"reasoning":"off","inference_cache":false,"max_worker_rss_bytes":1}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_failed "$rss_budget_task" 1 240 1
rss_budget_contract="$(psql_exec -qAt \
  -v task_name="$rss_budget_task" \
  -v model_name="$strong_model_name" <<'SQL'
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = :'task_name'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, selection_reason, schema_validation_status, trace_summary
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
)
SELECT j.status || '|' ||
       (j.error LIKE 'linked worker RSS budget%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.selection_reason || '|' ||
       r.schema_validation_status || '|' ||
       COALESCE(r.trace_summary ->> 'stop_reason', '') || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM job_row j
CROSS JOIN receipt_row r
JOIN otlet.runtime_status rs
  ON rs.model_name = :'model_name';
SQL
)"
echo "rss_budget_worker_contract=$rss_budget_contract"
[ "$rss_budget_contract" = "failed|true|failed|failed|direct_attempt_failed|failed|worker_rss_budget_exceeded|0|ready|ready" ] || {
  echo "Expected RSS budget hit to produce a clean failed receipt and healthy worker, got $rss_budget_contract" >&2
  exit 1
}

preload_admission_task="preload_admission_demo"
cleanup_task "$preload_admission_task"
preload_instruction='Return one JSON object only with top-level output and actions. output has one key ok set to true. actions is an empty array. No markdown.'
preload_schema='{"type":"object","required":["ok"],"additionalProperties":false,"properties":{"ok":{"type":"boolean"}}}'
psql_exec -qAt \
  -v model_name="$cheap_model_name" \
  -v instruction="$preload_instruction" \
  -v output_schema="$preload_schema" >/dev/null <<'SQL'
SELECT output FROM otlet.ask(
  :'model_name',
  :'instruction',
  '{}'::jsonb,
  :'output_schema'::jsonb,
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb,
  30000
);
SQL
preload_worker_pid_before="$(psql_exec -qAt -c "SELECT pid FROM pg_stat_activity WHERE backend_type = 'otlet worker' LIMIT 1;")"
preload_swaps_before="$(psql_exec -qAt -c "SELECT count(*) FROM otlet.worker_events WHERE event_type = 'model_swap';")"
psql_exec \
  -v task_name="$preload_admission_task" \
  -v model_name="$strong_model_name" \
  -v instruction="$preload_instruction" \
  -v output_schema="$preload_schema" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'preload-admission-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  :'instruction',
  :'output_schema'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false,"max_worker_rss_bytes":7200000000}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_failed "$preload_admission_task" 1 240 1
preload_admission_contract="$(psql_exec -qAt \
  -v task_name="$preload_admission_task" <<'SQL'
WITH evidence AS (
  SELECT s.*, j.status AS job_status
  FROM otlet.inference_receipt_trace_status s
  JOIN otlet.jobs j ON j.id = s.job_id
  WHERE s.task_name = :'task_name'
  ORDER BY s.receipt_id DESC
  LIMIT 1
)
SELECT job_status || '|' ||
       COALESCE(stop_reason, '') || '|' ||
       COALESCE(model_load_admission_decision, '') || '|' ||
       (model_load_admission_reason = 'llama_projected_model_kv_batch_exceeds_headroom')::text || '|' ||
       (model_load_allowed_additional_bytes < jsonb_extract_path_text(memory_evidence, 'admission', 'projected_total_bytes')::bigint)::text || '|' ||
       (worker_process_rss_bytes > 0)::text || '|' ||
       (system_memory_available_bytes > 0)::text || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = evidence.job_id)::text
FROM evidence;
SQL
)"
preload_rejection_event="$(psql_exec -qAt \
  -v task_name="$preload_admission_task" <<'SQL'
SELECT (count(*) = 1)::text
FROM otlet.worker_events e
JOIN otlet.jobs j ON j.id = e.job_id
WHERE j.task_name = :'task_name'
  AND e.event_type = 'model_admission_rejected';
SQL
)"
preload_resident_reuse="$(psql_exec -qAt \
  -v model_name="$cheap_model_name" \
  -v instruction="$preload_instruction" \
  -v output_schema="$preload_schema" <<'SQL'
SELECT output ->> 'ok' FROM otlet.ask(
  :'model_name',
  :'instruction',
  '{}'::jsonb,
  :'output_schema'::jsonb,
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb,
  30000
);
SQL
)"
preload_worker_pid_after="$(psql_exec -qAt -c "SELECT pid FROM pg_stat_activity WHERE backend_type = 'otlet worker' LIMIT 1;")"
preload_swaps_after="$(psql_exec -qAt -c "SELECT count(*) FROM otlet.worker_events WHERE event_type = 'model_swap';")"
preload_pid_preserved="$([ "$preload_worker_pid_before" = "$preload_worker_pid_after" ] && echo true || echo false)"
preload_swap_preserved="$([ "$preload_swaps_before" = "$preload_swaps_after" ] && echo true || echo false)"
preload_admission_contract="$preload_admission_contract|$preload_rejection_event|$preload_resident_reuse|$preload_pid_preserved|$preload_swap_preserved"
echo "preload_admission_contract=$preload_admission_contract"
[ "$preload_admission_contract" = "failed|model_load_admission_rejected|rejected|true|true|true|true|0|true|true|true|true" ] || {
  echo "Expected pre-load rejection to preserve the resident model and worker, got $preload_admission_contract" >&2
  exit 1
}

oversized_prompt_task="oversized_prompt_worker_demo"
cleanup_task "$oversized_prompt_task"
psql_exec -v task_name="$oversized_prompt_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'oversized-prompt-1'::text AS subject_id,
           jsonb_build_object('payload', repeat('oversized prompt ', 50000)) AS input
  $source$::text,
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":4096,"reasoning":"off","inference_cache":false}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_failed "$oversized_prompt_task" 1 300 1
oversized_prompt_contract="$(psql_exec -qAt \
  -v task_name="$oversized_prompt_task" \
  -v model_name="$strong_model_name" <<'SQL'
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = :'task_name'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, selection_reason, schema_validation_status, trace_summary
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
)
SELECT j.status || '|' ||
       (j.error LIKE 'linked llama.cpp prompt has%exceeds context window%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.selection_reason || '|' ||
       r.schema_validation_status || '|' ||
       COALESCE(r.trace_summary ->> 'stop_reason', '') || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM job_row j
CROSS JOIN receipt_row r
JOIN otlet.runtime_status rs
  ON rs.model_name = :'model_name';
SQL
)"
echo "oversized_prompt_worker_contract=$oversized_prompt_contract"
require_regex "$oversized_prompt_contract" '^failed\|true\|failed\|failed\|direct_attempt_failed\|failed\|prompt(_and_generation)?_exceed(s_context_window|_context_window)\|0\|ready\|ready$' "Expected oversized prompt to produce a clean failed receipt and healthy worker"

cancel_decode_task="cancel_decode_worker_demo"
cleanup_task "$cancel_decode_task"
psql_exec -v task_name="$cancel_decode_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'cancel-decode-1'::text AS subject_id,
           jsonb_build_object('payload', repeat('cancel decode ', 1000)) AS input
  $source$::text,
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":512,"reasoning":"off","inference_cache":false}'::jsonb
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
SELECT count(*) FROM otlet.cancel_job(:'job_id'::bigint, 'demo cancel mid-decode');
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
    echo "Expected cancel smoke to reach running state before terminal status, got $cancel_decode_terminal" >&2
    exit 1
  fi
  sleep 0.2
done
[ -n "$cancel_decode_job_id" ] || {
  echo "Timed out waiting for cancel smoke job to run" >&2
  exit 1
}
wait_task_failed "$cancel_decode_task" 1 240 1
cancel_decode_contract="$(psql_exec -qAt \
  -v task_name="$cancel_decode_task" \
  -v model_name="$strong_model_name" <<'SQL'
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = :'task_name'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, selection_reason, schema_validation_status
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
)
SELECT j.status || '|' ||
       (j.error = 'demo cancel mid-decode')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.selection_reason || '|' ||
       COALESCE(r.schema_validation_status, '') || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM job_row j
CROSS JOIN receipt_row r
JOIN otlet.runtime_status rs
  ON rs.model_name = :'model_name';
SQL
)"
echo "cancel_decode_worker_contract=$cancel_decode_contract"
[ "$cancel_decode_contract" = "canceled|true|canceled|failed|canceled||0|ready|ready" ] || {
  echo "Expected mid-decode cancel to produce a clean canceled receipt and healthy worker, got $cancel_decode_contract" >&2
  exit 1
}

invalid_json_task="invalid_json_safety_demo"
cleanup_task "$invalid_json_task"
psql_exec -v task_name="$invalid_json_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'invalid-json-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only.',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
);
CREATE TEMP TABLE invalid_json_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  VALUES (:'task_name', 'invalid-json-1', '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes')
  RETURNING id
)
SELECT id FROM inserted;
SELECT otlet.fail_job(
  id,
  'invalid model JSON: expected object',
  'not json',
  NULL,
  NULL,
  NULL,
  md5('not json'),
  now(),
  'failed',
  '{"schema_validation_status":"failed"}'::jsonb,
  :'model_name',
  'direct',
  'failed',
  'invalid_model_json'
)
FROM invalid_json_claim;
SQL
invalid_json_contract="$(psql_exec -qAt -v task_name="$invalid_json_task" <<'SQL'
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = :'task_name'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, schema_validation_status
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
),
materialized AS (
  SELECT count(*)::bigint AS materialization_count
  FROM otlet.semantic_materializations sm
  JOIN otlet.records rec ON rec.id = sm.record_id
  JOIN otlet.actions act ON act.id = rec.action_id
  WHERE act.job_id = (SELECT id FROM job_row)
)
SELECT j.status || '|' ||
       (j.error LIKE 'invalid model JSON:%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.schema_validation_status || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       (SELECT count(*) FROM otlet.actions WHERE job_id = j.id)::text || '|' ||
       (SELECT materialization_count FROM materialized)::text
FROM job_row j
CROSS JOIN receipt_row r;
SQL
)"
echo "invalid_json_safety_contract=$invalid_json_contract"
[ "$invalid_json_contract" = "failed|true|failed|failed|failed|0|0|0" ] || {
  echo "Expected invalid JSON to leave only a failed receipt, got $invalid_json_contract" >&2
  exit 1
}

cleanup_task "$output_envelope_task"
psql_exec -v task_name="$output_envelope_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'unused'::text AS subject_id, '{}'::jsonb AS input WHERE false
  $source$::text,
  'Return JSON only.',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
);

CREATE TEMP TABLE output_envelope_cases (
  subject_id text PRIMARY KEY,
  expected_error text NOT NULL,
  raw_output text NOT NULL
);

INSERT INTO output_envelope_cases (subject_id, expected_error, raw_output)
VALUES
  (
    'markdown-fence',
    'invalid model JSON: markdown fences are not allowed',
    $raw$```json
{"output":{"status":"ok"},"actions":[]}
```$raw$
  ),
  (
    'extra-top-level',
    'model JSON has unsupported top-level key',
    '{"output":{"status":"ok"},"actions":[],"extra":true}'
  ),
  (
    'non-object-action',
    'model JSON actions must contain objects',
    '{"output":{"status":"ok"},"actions":["bad"]}'
  );

WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  SELECT :'task_name', subject_id, '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes'
  FROM output_envelope_cases
  RETURNING id, subject_id
)
SELECT otlet.fail_job(
  inserted.id,
  cases.expected_error,
  cases.raw_output,
  NULL,
  NULL,
  NULL,
  md5(cases.raw_output),
  now(),
  'failed',
  '{}'::jsonb,
  :'model_name',
  'direct',
  'failed',
  'output_envelope_contract'
)
FROM inserted
JOIN output_envelope_cases cases USING (subject_id);
SQL
output_envelope_contract="$(psql_exec -qAt -v task_name="$output_envelope_task" <<'SQL'
WITH cases(subject_id, expected_error, raw_output) AS (
  VALUES
    (
      'markdown-fence',
      'invalid model JSON: markdown fences are not allowed',
      $raw$```json
{"output":{"status":"ok"},"actions":[]}
```$raw$
    ),
    (
      'extra-top-level',
      'model JSON has unsupported top-level key',
      '{"output":{"status":"ok"},"actions":[],"extra":true}'
    ),
    (
      'non-object-action',
      'model JSON actions must contain objects',
      '{"output":{"status":"ok"},"actions":["bad"]}'
    )
), rows AS (
  SELECT c.subject_id,
         c.expected_error,
         c.raw_output AS expected_raw_output,
         j.id AS job_id,
         j.status AS job_status,
         j.error AS job_error,
         r.status AS receipt_status,
         r.selection_status,
         r.schema_validation_status,
         r.error AS receipt_error,
         r.raw_output,
         r.raw_output_hash
  FROM cases c
  JOIN otlet.jobs j
    ON j.task_name = :'task_name'
   AND j.subject_id = c.subject_id
  JOIN otlet.inference_receipts r ON r.job_id = j.id
)
SELECT count(*) FILTER (WHERE subject_id = 'markdown-fence' AND job_error = expected_error AND receipt_error = expected_error)::text || '|' ||
       count(*) FILTER (WHERE subject_id = 'extra-top-level' AND job_error = expected_error AND receipt_error = expected_error)::text || '|' ||
       count(*) FILTER (WHERE subject_id = 'non-object-action' AND job_error = expected_error AND receipt_error = expected_error)::text || '|' ||
       bool_and(job_status = 'failed' AND receipt_status = 'failed' AND selection_status = 'failed' AND schema_validation_status = 'failed')::text || '|' ||
       bool_and(raw_output IS NULL AND raw_output_hash = md5(expected_raw_output))::text || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id IN (SELECT job_id FROM rows))::text || '|' ||
       (SELECT count(*) FROM otlet.actions WHERE job_id IN (SELECT job_id FROM rows))::text
FROM rows;
SQL
)"
echo "output_envelope_contract=$output_envelope_contract"
[ "$output_envelope_contract" = "1|1|1|true|true|0|0" ] || {
  echo "Expected strict output envelope failures with raw output hashes, got $output_envelope_contract" >&2
  exit 1
}

hallucinated_action_task="hallucinated_action_safety_demo"
cleanup_task "$hallucinated_action_task"
psql_exec -v task_name="$hallucinated_action_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'hallucinated-action-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only.',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
);
CREATE TEMP TABLE hallucinated_action_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  VALUES (:'task_name', 'hallucinated-action-1', '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes')
  RETURNING id
)
SELECT id FROM inserted;
SELECT otlet.complete_job(
  id,
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[{"type":"invented_action","body":{"subject_id":"hallucinated-action-1","text":"no record"}}]}',
  '[{"type":"invented_action","body":{"subject_id":"hallucinated-action-1","text":"no record"}}]'::jsonb,
  NULL,
  NULL,
  NULL,
  md5('{"output":{"status":"ok"},"actions":[{"type":"invented_action","body":{"subject_id":"hallucinated-action-1","text":"no record"}}]}'),
  now(),
  '{"schema_validation_status":"passed"}'::jsonb,
  :'model_name'
)
FROM hallucinated_action_claim;
SQL
hallucinated_action_contract="$(psql_exec -qAt -v task_name="$hallucinated_action_task" <<'SQL'
WITH job_row AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name = :'task_name'
  ORDER BY id DESC
  LIMIT 1
)
SELECT (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE((SELECT status || '|' || COALESCE(error, '') FROM otlet.actions WHERE job_id = j.id ORDER BY id DESC LIMIT 1), '') || '|' ||
       (SELECT count(*) FROM otlet.records r JOIN otlet.actions a ON a.id = r.action_id WHERE a.job_id = j.id)::text || '|' ||
       COALESCE((
         SELECT (r.raw_output IS NULL AND
                 r.raw_output_hash = md5('{"output":{"status":"ok"},"actions":[{"type":"invented_action","body":{"subject_id":"hallucinated-action-1","text":"no record"}}]}'))::text
         FROM otlet.inference_receipts r
         WHERE r.job_id = j.id
         ORDER BY r.id DESC
         LIMIT 1
       ), 'false')
FROM job_row j;
SQL
)"
echo "hallucinated_action_safety_contract=$hallucinated_action_contract"
[ "$hallucinated_action_contract" = "1|rejected|unsupported action type|0|true" ] || {
  echo "Expected hallucinated action type to be rejected without a record, got $hallucinated_action_contract" >&2
  exit 1
}
