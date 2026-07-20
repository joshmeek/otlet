log "Checking pair candidate drift audit"
candidate_removed_contract="$(psql_exec -qAt -v index_name="$join_index_name" -v task_name="$join_task" <<'SQL'
BEGIN;
DELETE FROM public.otlet_demo_vendor_pair
WHERE pair_id = 'vendor-1001:vendor-314';
SELECT otlet.refresh_semantic_join_index(:'index_name')::text;
SELECT stale::text || '|' || COALESCE(stale_reason, '')
FROM otlet.semantic_dependency_audit
WHERE task_name = :'task_name'
  AND subject_id = 'vendor-1001:vendor-314';
SELECT count(*)::text
FROM otlet.semantic_join_index_current_rows(:'index_name', false)
WHERE subject_id = 'vendor-1001:vendor-314';
INSERT INTO public.otlet_demo_vendor_pair (pair_id, left_id, right_id)
VALUES ('vendor-1001:vendor-314', 'vendor-1001', 'vendor-314');
SELECT otlet.refresh_semantic_join_index(:'index_name')::text;
SELECT stale::text || '|' || COALESCE(stale_reason, '')
FROM otlet.semantic_dependency_audit
WHERE task_name = :'task_name'
  AND subject_id = 'vendor-1001:vendor-314';
ROLLBACK;
SQL
)"
candidate_removed_refresh="$(sed -n '1p' <<<"$candidate_removed_contract")"
candidate_removed_audit="$(sed -n '2p' <<<"$candidate_removed_contract")"
candidate_removed_current="$(sed -n '3p' <<<"$candidate_removed_contract")"
candidate_restored_refresh="$(sed -n '4p' <<<"$candidate_removed_contract")"
candidate_restored_audit="$(sed -n '5p' <<<"$candidate_removed_contract")"
echo "candidate_removed_contract=$candidate_removed_refresh|$candidate_removed_audit|$candidate_removed_current|$candidate_restored_refresh|$candidate_restored_audit"
[ "$candidate_removed_refresh|$candidate_removed_audit|$candidate_removed_current|$candidate_restored_refresh|$candidate_restored_audit" = "0|true|candidate_removed|0|0|false|" ] || {
  echo "Expected removed pair audit and zero-work restoration, got $candidate_removed_contract" >&2
  exit 1
}

candidate_changed_contract="$(psql_exec -qAt -v index_name="$join_index_name" -v task_name="$join_task" <<'SQL'
BEGIN;
UPDATE public.otlet_demo_vendor_pair
SET right_id = 'vendor-77'
WHERE pair_id = 'vendor-1001:vendor-314';
SELECT otlet.refresh_semantic_join_index(:'index_name')::text;
SELECT stale::text || '|' || COALESCE(stale_reason, '')
FROM otlet.semantic_dependency_audit
WHERE task_name = :'task_name'
  AND subject_id = 'vendor-1001:vendor-314';
SELECT count(*)::text
FROM otlet.semantic_join_index_current_rows(:'index_name', true)
WHERE subject_id = 'vendor-1001:vendor-314';
ROLLBACK;
SQL
)"
candidate_changed_refresh="$(sed -n '1p' <<<"$candidate_changed_contract")"
candidate_changed_audit="$(sed -n '2p' <<<"$candidate_changed_contract")"
candidate_changed_current="$(sed -n '3p' <<<"$candidate_changed_contract")"
echo "candidate_changed_contract=$candidate_changed_refresh|$candidate_changed_audit|$candidate_changed_current"
[ "$candidate_changed_refresh|$candidate_changed_audit|$candidate_changed_current" = "1|true|candidate_changed|0" ] || {
  echo "Expected changed pair audit and one queued refresh, got $candidate_changed_contract" >&2
  exit 1
}

log "Checking entity-resolution dependency update"
join_receipts_before_update="$(psql_exec -qAt -v task_name="$join_task" <<'SQL'
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = :'task_name';
SQL
)"
psql_exec >/dev/null <<'SQL'
SELECT otlet.watch_semantic_stale('public.otlet_demo_vendor_entity'::regclass, 'id');
UPDATE public.otlet_demo_vendor_entity
SET notes = notes || '; updated AP contact confirms remittance migration',
    updated_at = clock_timestamp()
WHERE id = 'vendor-1001';
SQL
join_stale_contract="$(psql_exec -qAt \
  -v index_name="$join_index_name" \
  -v task_name="$join_task" <<'SQL'
SELECT stale_subjects::text || '|' || fresh_subjects::text
FROM otlet.semantic_join_index_plan(:'index_name');
SELECT count(*)::text
FROM otlet.semantic_join_index_current_rows(:'index_name', true);
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = :'task_name';
SQL
)"
join_stale_subjects="$(head -n 1 <<<"$join_stale_contract")"
join_fresh_after_lookup="$(sed -n '2p' <<<"$join_stale_contract")"
join_receipts_after_update="$(tail -n 1 <<<"$join_stale_contract")"
echo "semantic_join_stale_contract=$join_stale_subjects|fresh_after_lookup=$join_fresh_after_lookup|receipts=$join_receipts_before_update|$join_receipts_after_update"
if [ "$join_stale_subjects|$join_fresh_after_lookup" != "4|0|0" ] || [ "$join_receipts_before_update" != "$join_receipts_after_update" ]; then
  echo "Expected semantic join dependency update to fail closed with unchanged receipts, got $join_stale_subjects|$join_fresh_after_lookup|$join_receipts_before_update|$join_receipts_after_update" >&2
  exit 1
fi

log "Checking contract-change freshness invalidation"
psql_exec -v task_name="$join_task" >/dev/null <<'SQL'
WITH current_task AS (
  SELECT *
  FROM otlet.tasks
  WHERE name = :'task_name'
)
SELECT (otlet.create_task(
    name,
    input_query,
    instruction || ' Contract drift demo.',
    output_schema,
    model_name,
    runtime_options,
    input_shaping,
    decision_contract
  )).name
FROM current_task;
SQL
contract_change_contract="$(psql_exec -qAt \
  -v task_name="$join_task" \
  -v index_name="$join_index_name" <<'SQL'
SELECT count(*) FILTER (WHERE sm.stale_reason = 'contract_changed')::text || '|' ||
       count(*) FILTER (WHERE sm.stale)::text
FROM otlet.semantic_materializations sm
WHERE sm.task_name = :'task_name';
SELECT count(*)::text
FROM otlet.semantic_join_index_current_rows(:'index_name', true);
SQL
)"
contract_change_counts="$(head -n 1 <<<"$contract_change_contract")"
contract_change_fresh="$(tail -n 1 <<<"$contract_change_contract")"
echo "contract_change_contract=$contract_change_counts|fresh_after_contract_change=$contract_change_fresh"
[ "$contract_change_counts|$contract_change_fresh" = "4|4|0" ] || {
  echo "Expected contract-change freshness invalidation 4|4|0, got $contract_change_counts|$contract_change_fresh" >&2
  exit 1
}

trace_contract="$(psql_exec -qAt \
  -v entity_task="$entity_task" \
  -v join_task="$join_task" <<'SQL'
SELECT count(*) FILTER (WHERE receipt_id > 0)::text || '|' ||
       count(*) FILTER (WHERE prompt_tokens > 0)::text || '|' ||
       count(*) FILTER (WHERE generated_tokens >= 0)::text || '|' ||
       count(*) FILTER (WHERE schema_validation_status = 'passed')::text
FROM otlet.inference_receipt_trace_status
WHERE task_name IN (:'entity_task', :'join_task')
  AND status = 'complete';
SQL
)"
echo "receipt_trace_contract=$trace_contract"
[ "$trace_contract" = "8|8|8|8" ] || {
  echo "Expected receipt trace contract 8|8|8|8, got $trace_contract" >&2
  exit 1
}

timing_contract="$(psql_exec -qAt \
  -v entity_task="$entity_task" \
  -v join_task="$join_task" <<'SQL'
SELECT count(*) FILTER (WHERE finish_sql_ms IS NOT NULL)::text || '|' ||
       count(*) FILTER (WHERE materialize_ms IS NOT NULL AND accepted)::text
FROM otlet.inference_receipt_trace_status
WHERE task_name IN (:'entity_task', :'join_task')
  AND status = 'complete';
SQL
)"
echo "receipt_timing_contract=$timing_contract"
[ "$timing_contract" = "8|8" ] || {
  echo "Expected receipt timing contract 8|8, got $timing_contract" >&2
  exit 1
}

stage_timing_contract="$(psql_exec -qAt \
  -v entity_task="$entity_task" \
  -v join_task="$join_task" <<'SQL'
SELECT (count(*) > 0)::text || '|' ||
       bool_and(accounted_worker_ms > 0)::text || '|' ||
       bool_and(observed_end_to_end_ms >= queue_wait_ms)::text || '|' ||
       bool_and(timing_overrun_ms <= 100)::text
FROM otlet.runtime_stage_timing_status
WHERE task_name IN (:'entity_task', :'join_task')
  AND status = 'complete';
SQL
)"
echo "runtime_stage_timing_contract=$stage_timing_contract"
[ "$stage_timing_contract" = "true|true|true|true" ] || {
  echo "Expected reconciled runtime stage timing, got $stage_timing_contract" >&2
  exit 1
}

visibility_status="$(psql_exec -qAt \
  -v entity_task="$entity_task" \
  -v join_task="$join_task" <<'SQL'
SELECT (count(*) > 0)::text || '|' ||
       (COALESCE(sum(detailed_trace_captured_tokens), 0) > 0)::text || '|' ||
       (COALESCE(sum(detailed_trace_captured_tokens * detailed_trace_top_k), 0) > 0)::text || '|' ||
       (COALESCE(max(detailed_trace_max_tokens), 0) > 0)::text || '|' ||
       (COALESCE(max(detailed_trace_top_k), 0) = 3)::text
FROM otlet.inference_receipt_trace_status
WHERE task_name IN (:'entity_task', :'join_task')
  AND status = 'complete';
SQL
)"
echo "inference_visibility_status=$visibility_status"
require_contains "$visibility_status" "true|true|true|true|true" "Expected bounded token/top-k trace visibility counters"

cleanup_dry_run="$(psql_exec -qAt <<'SQL'
SELECT worker_events::text || '|' ||
       token_trace_rows::text || '|' ||
       token_alternative_rows::text || '|' ||
       eval_labels::text || '|' ||
       delete_stale_materializations::text || '|' ||
       sensitive_raw_outputs::text || '|' ||
       sensitive_chosen_texts::text || '|' ||
       sensitive_token_texts::text || '|' ||
       sensitive_alternative_token_texts::text || '|' ||
       failed_canceled_jobs::text || '|' ||
       dry_run::text
FROM otlet.cleanup_policy_state(true);
SQL
)"
echo "cleanup_policy_dry_run=$cleanup_dry_run"
require_regex "$cleanup_dry_run" '^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|true$' "Expected cleanup dry run counts ending in true"
