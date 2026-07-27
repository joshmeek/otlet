log "Building entity-resolution pair watch"
psql_exec \
  -v join_index_name="$join_index_name" \
  -v cheap_model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" \
  -v record_type="$record_type" \
  -v entity_instruction="$entity_instruction" >/dev/null <<'SQL'
SELECT name, task_name, record_type, max_candidate_rows
FROM otlet.create_watch(
  watch_name => :'join_index_name',
  kind => 'pair',
  instruction => :'entity_instruction',
  output_schema => '{
    "type": "object",
    "required": ["match", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "match": {"enum": ["same_entity", "different_entity", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 240}
    }
  }'::jsonb,
  model_name => :'cheap_model_name',
  candidate_query => $$
    SELECT subject_id, input
    FROM public.otlet_demo_vendor_pair_input
    ORDER BY subject_id
  $$,
  record_type => :'record_type',
  runtime_options => '{"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":16,"generation_trace_top_k":3}'::jsonb,
  selection_policy => jsonb_build_object(
    'cheap_model_name', :'cheap_model_name',
    'strong_model_name', :'strong_model_name'
  ),
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  action_types => ARRAY['merge_candidate', 'new_entity', 'review_flag'],
  input_shaping => '{"source_fields":["_otlet_mvcc","action_ids","candidate_evidence","evidence_counts"],"evidence_fields":["candidate_evidence"],"action_id_fields":{"left_id":"left_id","right_id":"right_id"}}'::jsonb,
  decision_contract => '{"preset":"entity_resolution_evidence_v1"}'::jsonb,
  max_candidate_rows => 10
);
SQL

queued="$(psql_candidate_exec -qAt -v index_name="$join_index_name" <<'SQL'
SELECT otlet.refresh_semantic_join_index(:'index_name');
SQL
)"
echo "semantic_join_refresh_queued=$queued"
[ "$queued" = "4" ] || {
  echo "Expected 4 semantic join jobs, got $queued" >&2
  exit 1
}
wait_task_complete "$join_task" 4 1800 1
throughput_contracts="$(psql_exec -qAt \
  -v task_name="$join_task" \
  -v record_type="$record_type" \
  -v model_name="$cheap_model_name" <<'SQL'
SELECT count(*) FILTER (WHERE a.action_type = 'create_record' AND a.status = 'complete')::text || '|' ||
       count(*) FILTER (WHERE r.record_type = :'record_type')::text
FROM otlet.jobs j
LEFT JOIN otlet.actions a ON a.job_id = j.id
LEFT JOIN otlet.records r ON r.action_id = a.id
WHERE j.task_name = :'task_name';

SELECT count(*)
FROM otlet.semantic_materializations
WHERE task_name = :'task_name'
  AND record_type = :'record_type'
  AND stale = false;

SELECT q.queue_state || '|' ||
       w.queued_jobs::text || '|' ||
       w.running_jobs::text || '|' ||
       w.last_batch_jobs::text || '|' ||
       w.last_batch_completed_jobs::text || '|' ||
       w.last_batch_failed_jobs::text
FROM otlet.worker_throughput_status w
JOIN otlet.model_queue_status q ON q.model_name = w.model_name
WHERE w.model_name = :'model_name';
SQL
)"
auto_records="$(sed -n '1p' <<<"$throughput_contracts")"
materialized="$(sed -n '2p' <<<"$throughput_contracts")"
throughput_status_contract="$(sed -n '3p' <<<"$throughput_contracts")"
echo "semantic_join_auto_records=$auto_records"
[ "$auto_records" = "4|4" ] || {
  echo "Expected 4 auto actions and records, got $auto_records" >&2
  exit 1
}

echo "semantic_join_auto_materialized=$materialized"
[ "$materialized" = "4" ] || {
  echo "Expected 4 automatic semantic join materializations, got $materialized" >&2
  exit 1
}

echo "throughput_status_contract=$throughput_status_contract"
[ "$throughput_status_contract" = "queue_accepting|0|0|4|4|0" ] || {
  echo "Expected throughput status contract queue_accepting|0|0|4|4|0, got $throughput_status_contract" >&2
  exit 1
}

join_status_contract="$(psql_exec -qAt -v index_name="$join_index_name" <<'SQL'
SELECT selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queue_subjects::text || '|' ||
       fail_closed_subjects::text || '|' ||
       count_basis
FROM otlet.semantic_join_index_plan(:'index_name');
SELECT selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queue_subjects::text || '|' ||
       fail_closed_subjects::text || '|' ||
       count_basis
FROM otlet.semantic_join_index_plan(:'index_name', true);
SQL
)"
join_status_estimated="$(head -n 1 <<<"$join_status_contract")"
join_status_exact="$(tail -n 1 <<<"$join_status_contract")"
echo "semantic_join_status_contract=$join_status_contract"
[ "$join_status_estimated|$join_status_exact" = "semantic_join_lookup|4|4|0|0|0|0|estimated|semantic_join_lookup|4|4|0|0|0|0|exact" ] || {
  echo "Expected fresh semantic join status, got $join_status_contract" >&2
  exit 1
}

pair_watch_status_contract="$(psql_exec -qAt -v watch_name="$join_index_name" <<'SQL'
SELECT watch_name || '|' || kind || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queued_jobs::text || '|' ||
       complete_jobs::text || '|' ||
       (proposed_actions >= 4)::text
FROM otlet.watch_status
WHERE watch_name = :'watch_name';
SQL
)"
echo "pair_watch_status_contract=$pair_watch_status_contract"
[ "$pair_watch_status_contract" = "$join_index_name|pair|4|4|0|0|0|4|true" ] || {
  echo "Expected pair watch status to show four fresh completed subjects, got $pair_watch_status_contract" >&2
  exit 1
}

join_lookup_contract="$(psql_exec -qAt -v index_name="$join_index_name" <<'SQL'
SELECT count(*)::text || '|' ||
       count(*) FILTER (WHERE body @> '{"match":"same_entity"}'::jsonb)::text || '|' ||
       count(*) FILTER (WHERE body @> '{"match":"different_entity"}'::jsonb)::text
FROM otlet.semantic_join_index_current_rows(:'index_name', true);
SQL
)"
echo "semantic_join_lookup_contract=$join_lookup_contract"
require_regex "$join_lookup_contract" '^4\|[1-9][0-9]*\|[1-9][0-9]*$' "Expected semantic join lookup to include 4 rows, at least one same_entity, and at least one different_entity"

join_match_contract="$(psql_exec -qAt -v index_name="$join_index_name" <<'SQL'
SELECT otlet.semantic_join_matches(:'index_name', 'vendor-1001:vendor-42', '{"match":"same_entity"}'::jsonb)::text || '|' ||
       otlet.semantic_join_matches(:'index_name', 'vendor-1001:vendor-77', '{"match":"different_entity"}'::jsonb)::text;
SQL
)"
echo "semantic_join_match_contract=$join_match_contract"
[ "$join_match_contract" = "true|true" ] || {
  echo "Expected semantic join matches, got $join_match_contract" >&2
  exit 1
}
