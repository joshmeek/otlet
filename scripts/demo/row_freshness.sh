log "Checking visible row update freshness"
row_receipts_before_visible_update="$(psql_exec -qAt -v task_name="$row_triage_task" <<'SQL'
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = :'task_name';
SQL
)"
row_visible_stale_contract="$(psql_exec -qAt \
  -v watch_name="$row_triage_watch" \
  -v task_name="$row_triage_task" <<'SQL'
BEGIN;
UPDATE public.otlet_demo_triage_signal
SET blockers = 0,
    approvals = 1,
    evidence = 'Updated review cleared the blocker and recorded manager approval'
WHERE id = 'triage-1';
SELECT count(*)::text
FROM otlet.semantic_index_current_rows(:'watch_name', true);
SELECT (count(*) FILTER (WHERE stale AND stale_reason = 'source_update') >= 1)::text
FROM otlet.semantic_materializations
WHERE task_name = :'task_name'
  AND subject_id = 'triage-1';
SELECT otlet.semantic_matches(:'watch_name', 'triage-1', '{"decision":"flag"}'::jsonb)::text;
SELECT count(*)::text
FROM otlet.semantic_index_current_rows(:'watch_name', true)
WHERE subject_id = 'triage-1';
SAVEPOINT pending_reason_probe;
UPDATE otlet.semantic_materializations
SET stale_reason = NULL
WHERE task_name = :'task_name'
  AND subject_id = 'triage-1';
SELECT COALESCE(stale_reasons->>'content_revalidation_pending', '0')
FROM otlet.semantic_index_plan(:'watch_name', true);
ROLLBACK TO SAVEPOINT pending_reason_probe;
COMMIT;
SQL
)"
row_visible_fresh_before="$(head -n 1 <<<"$row_visible_stale_contract")"
row_visible_source_update="$(sed -n '2p' <<<"$row_visible_stale_contract")"
row_visible_predicate_match="$(sed -n '3p' <<<"$row_visible_stale_contract")"
row_visible_current_rows="$(sed -n '4p' <<<"$row_visible_stale_contract")"
row_pending_reason="$(sed -n '5p' <<<"$row_visible_stale_contract")"
echo "row_visible_update_stale_contract=$row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_current_rows"
[ "$row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_current_rows" = "0|true|false|0" ] || {
  echo "Expected visible row update to fail closed across lookup surfaces, got $row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_current_rows" >&2
  exit 1
}
echo "row_content_revalidation_pending_contract=$row_pending_reason"
[ "$row_pending_reason" = "1" ] || {
  echo "Expected stale current row with no stored reason to expose content_revalidation_pending, got $row_pending_reason" >&2
  exit 1
}
wait_task_complete "$row_triage_task" 2 900 1
row_visible_refresh_contract="$(psql_exec -qAt \
  -v task_name="$row_triage_task" \
  -v watch_name="$row_triage_watch" <<'SQL'
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = :'task_name';
SELECT count(*)::text
FROM otlet.semantic_index_current_rows(:'watch_name', true);
SQL
)"
row_receipts_after_visible_update="$(head -n 1 <<<"$row_visible_refresh_contract")"
row_visible_fresh_after="$(tail -n 1 <<<"$row_visible_refresh_contract")"
row_visible_receipt_delta=$((row_receipts_after_visible_update - row_receipts_before_visible_update))
echo "row_visible_update_refresh_contract=$row_visible_receipt_delta|$row_visible_fresh_after"
[ "$row_visible_receipt_delta|$row_visible_fresh_after" = "1|1" ] || {
  echo "Expected visible row update to produce exactly one receipt and one fresh row, got $row_visible_receipt_delta|$row_visible_fresh_after" >&2
  exit 1
}

log "Checking content-keyed inference cache on row revert"
psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_demo_triage_signal
SET blockers = 2,
    approvals = 0,
    evidence = 'Wire instructions changed after invoice approval and the requester used urgent payment language'
WHERE id = 'triage-1';
SQL
psql_exec -v task_name="$row_triage_task" >/dev/null <<'SQL'
INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT
  :'task_name',
  (src.id)::text,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_triage_signal',
      'subject_id', (src.id)::text,
      'ctid', src.ctid::text,
      'xmin', src.xmin::text
    ),
    'table', 'public.otlet_demo_triage_signal',
    'row', otlet.semantic_project_row(to_jsonb(src), NULL::text[])
  )
FROM public.otlet_demo_triage_signal AS src
WHERE src.id = 'triage-1';
SELECT otlet.wake_worker();
SQL
wait_task_complete "$row_triage_task" 3 900 1
row_cache_revert_contract="$(psql_exec -qAt \
  -v task_name="$row_triage_task" \
  -v watch_name="$row_triage_watch" <<'SQL'
SELECT inference_cache_hit::text || '|' ||
       COALESCE(inference_cache_reason, '') || '|' ||
       COALESCE(inference_cache_key_basis, '') || '|' ||
       COALESCE(inference_cache_eviction_reason, '') || '|' ||
       COALESCE(decode_constraint, '')
FROM otlet.inference_receipt_trace_status
WHERE task_name = :'task_name'
  AND subject_id = 'triage-1'
  AND status = 'complete'
ORDER BY receipt_id DESC
LIMIT 1;
SELECT count(*)::text
FROM otlet.semantic_index_current_rows(:'watch_name', true);
SQL
)"
row_cache_revert_trace="$(head -n 1 <<<"$row_cache_revert_contract")"
row_cache_revert_fresh="$(tail -n 1 <<<"$row_cache_revert_contract")"
echo "row_cache_revert_contract=$row_cache_revert_trace|fresh=$row_cache_revert_fresh"
[ "$row_cache_revert_trace|$row_cache_revert_fresh" = "true|hit|content_hash_contract_hash_runtime_output_contract_hash_model_fingerprint|none|greedy_with_balanced_json_object_stop_post_generation_schema_check|1" ] || {
  echo "Expected reverted row content to hit inference cache and remain fresh, got $row_cache_revert_trace|$row_cache_revert_fresh" >&2
  exit 1
}

log "Checking contract-change inference cache miss"
psql_exec \
  -v task_name="$row_triage_task" \
  -v started_at="$script_started" >/dev/null <<'SQL'
WITH current_task AS (
  SELECT *
  FROM otlet.tasks
  WHERE name = :'task_name'
)
SELECT (otlet.create_task(
    name,
    input_query,
    instruction || ' Cache contract drift demo ' || :'started_at' || '.',
    output_schema,
    model_name,
    runtime_options,
    input_shaping,
    decision_contract
  )).name
FROM current_task;

INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT
  :'task_name',
  (src.id)::text,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_triage_signal',
      'subject_id', (src.id)::text,
      'ctid', src.ctid::text,
      'xmin', src.xmin::text
    ),
    'table', 'public.otlet_demo_triage_signal',
    'row', otlet.semantic_project_row(to_jsonb(src), NULL::text[])
  )
FROM public.otlet_demo_triage_signal AS src
WHERE src.id = 'triage-1';
SELECT otlet.wake_worker();
SQL
wait_task_complete "$row_triage_task" 4 900 1
row_contract_cache_contract="$(psql_exec -qAt -v task_name="$row_triage_task" <<'SQL'
SELECT inference_cache_hit::text || '|' ||
       COALESCE(inference_cache_reason, '') || '|' ||
       COALESCE(inference_cache_key_basis, '')
FROM otlet.inference_receipt_trace_status
WHERE task_name = :'task_name'
  AND subject_id = 'triage-1'
  AND status = 'complete'
ORDER BY receipt_id DESC
LIMIT 1;
SQL
)"
echo "row_contract_cache_contract=$row_contract_cache_contract"
[ "$row_contract_cache_contract" = "false|contract_changed|content_hash_contract_hash_runtime_output_contract_hash_model_fingerprint" ] || {
  echo "Expected contract edit to miss inference cache with contract_changed reason, got $row_contract_cache_contract" >&2
  exit 1
}

row_manual_reason_contract="$(psql_exec -qAt -v task_name="$row_triage_task" <<'SQL'
SELECT (otlet.mark_semantic_stale(NULL, 'triage-1', 'manual') >= 1)::text;
SELECT (count(*) FILTER (WHERE stale AND stale_reason = 'manual') >= 1)::text
FROM otlet.semantic_materializations
WHERE task_name = :'task_name'
  AND subject_id = 'triage-1';
SQL
)"
row_manual_marked="$(head -n 1 <<<"$row_manual_reason_contract")"
row_manual_reason="$(tail -n 1 <<<"$row_manual_reason_contract")"
echo "row_manual_reason_contract=$row_manual_marked|$row_manual_reason"
[ "$row_manual_marked|$row_manual_reason" = "true|true" ] || {
  echo "Expected manual mark to expose manual stale reason, got $row_manual_marked|$row_manual_reason" >&2
  exit 1
}

log "Checking row delete freshness"
psql_exec >/dev/null <<'SQL'
DELETE FROM public.otlet_demo_triage_signal
WHERE id = 'triage-1';
SQL
row_delete_contract="$(psql_exec -qAt \
  -v watch_name="$row_triage_watch" \
  -v task_name="$row_triage_task" <<'SQL'
SELECT count(*)::text
FROM otlet.semantic_index_current_rows(:'watch_name', true);
SELECT (count(*) FILTER (WHERE stale AND stale_reason = 'source_delete') >= 1)::text
FROM otlet.semantic_dependency_audit
WHERE task_name = :'task_name'
  AND subject_id = 'triage-1';
SQL
)"
row_delete_fresh="$(head -n 1 <<<"$row_delete_contract")"
row_delete_reason="$(tail -n 1 <<<"$row_delete_contract")"
echo "row_delete_contract=$row_delete_fresh|$row_delete_reason"
[ "$row_delete_fresh|$row_delete_reason" = "0|true" ] || {
  echo "Expected row delete to fail closed with source_delete reason, got $row_delete_fresh|$row_delete_reason" >&2
  exit 1
}

psql_exec -v task_name="$row_triage_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
CREATE TEMP TABLE row_triage_invalid_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token)
  VALUES (
    :'task_name',
    'triage-invalid-json',
    '{"row":{"id":"triage-invalid-json","blockers":1,"approvals":0,"evidence":"invalid model answer smoke"}}'::jsonb,
    'running',
    1,
    now(),
    now() + interval '5 minutes',
    gen_random_uuid()::text
  )
  RETURNING id, claim_token
)
SELECT id, claim_token FROM inserted;

SELECT otlet.fail_job(
  id,
  'invalid model JSON: expected object',
  'not json',
  NULL,
  NULL,
  md5('{"type":"object","required":["decision","confidence","reason"]}'),
  otlet.portable_text_hash('not json'),
  now(),
  'failed',
  '{"schema_validation_status":"failed"}'::jsonb,
  :'model_name',
  'direct',
  'failed',
  'invalid_model_json',
  NULL,
  claim_token
)
FROM row_triage_invalid_claim;
SQL
row_triage_invalid_contract="$(psql_exec -qAt -v task_name="$row_triage_task" <<'SQL'
SELECT j.status || '|' ||
       (j.error LIKE 'invalid model JSON:%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.schema_validation_status || '|' ||
       (r.raw_output_hash = otlet.portable_text_hash('not json'))::text || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       (SELECT count(*) FROM otlet.actions WHERE job_id = j.id)::text || '|' ||
       (
         SELECT count(*)::text
         FROM otlet.semantic_materializations sm
         JOIN otlet.records rec ON rec.id = sm.record_id
         JOIN otlet.actions act ON act.id = rec.action_id
         WHERE act.job_id = j.id
       )
FROM otlet.jobs j
JOIN otlet.inference_receipts r ON r.job_id = j.id
WHERE j.task_name = :'task_name'
  AND j.subject_id = 'triage-invalid-json'
ORDER BY j.id DESC, r.id DESC
LIMIT 1;
SQL
)"
echo "row_triage_invalid_answer_contract=$row_triage_invalid_contract"
[ "$row_triage_invalid_contract" = "failed|true|failed|failed|failed|true|0|0|0" ] || {
  echo "Expected invalid non-ER model answer to leave only a failed receipt, got $row_triage_invalid_contract" >&2
  exit 1
}


source "$demo_dir/customscan.sh"
