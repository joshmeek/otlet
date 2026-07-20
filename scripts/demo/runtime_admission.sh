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
