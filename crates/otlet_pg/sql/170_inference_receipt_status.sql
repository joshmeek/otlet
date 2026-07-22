CREATE VIEW otlet.output_reliability_status AS
WITH receipt_counts AS (
  SELECT
    count(*)::bigint AS receipt_count,
    count(*) FILTER (WHERE status = 'complete' AND schema_validation_status = 'passed')::bigint AS schema_passed_receipts,
    count(*) FILTER (WHERE schema_validation_status = 'failed')::bigint AS schema_failed_receipts,
    count(*) FILTER (WHERE error LIKE 'invalid model JSON:%')::bigint AS json_parse_failed_receipts,
    count(*) FILTER (WHERE selection_role = 'cheap' AND selection_status = 'rejected')::bigint AS cheap_rejected_receipts,
    count(*) FILTER (WHERE selection_role = 'strong' AND selection_status = 'accepted')::bigint AS strong_accepted_receipts,
    count(*) FILTER (WHERE trace_summary ->> 'decode_constraint' IS NOT NULL)::bigint AS decode_constraint_receipts,
    count(DISTINCT job_id) FILTER (WHERE selection_role = 'strong')::bigint AS escalated_jobs
  FROM otlet.inference_receipts
),
output_counts AS (
  SELECT
    count(*) FILTER (
      WHERE COALESCE(t.decision_contract -> 'abstain_values', '["unclear"]'::jsonb)
        ? (o.output ->> COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match'))
    )::bigint AS abstained_outputs,
    count(*)::bigint AS trusted_outputs
  FROM otlet.outputs o
  JOIN otlet.jobs j ON j.id = o.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
),
action_counts AS (
  SELECT
    count(*) FILTER (WHERE a.status = 'rejected')::bigint AS rejected_actions,
    count(*) FILTER (WHERE a.error = 'unsupported action type')::bigint AS unknown_action_rejections
  FROM otlet.actions a
),
label_counts AS (
  SELECT count(*)::bigint AS eval_labels
  FROM otlet.eval_labels
)
SELECT
  receipt_counts.*,
  output_counts.abstained_outputs,
  action_counts.rejected_actions,
  action_counts.unknown_action_rejections,
  output_counts.trusted_outputs,
  label_counts.eval_labels
FROM receipt_counts
CROSS JOIN output_counts
CROSS JOIN action_counts
CROSS JOIN label_counts;

CREATE VIEW otlet.inference_receipt_trace_status AS
WITH latest_materialization AS (
  SELECT DISTINCT ON (a.receipt_id)
    a.receipt_id,
    sm.freshness_basis
  FROM otlet.actions a
  JOIN otlet.records rec ON rec.action_id = a.id
  JOIN otlet.semantic_materializations sm ON sm.record_id = rec.id
  WHERE a.receipt_id IS NOT NULL
  ORDER BY a.receipt_id, sm.updated_at DESC, sm.id DESC
)
SELECT
  r.id AS receipt_id,
  r.job_id,
  r.task_name,
  r.subject_id,
  r.attempt_index,
  r.selection_role,
  r.selection_status,
  r.selection_reason,
  (o.id IS NOT NULL) AS accepted,
  r.status,
  r.model_name,
  r.model_artifact_path,
  r.model_artifact_hash,
  r.model_artifact_identity,
  r.runtime_name,
  r.prompt_hash,
  r.prompt_tokens,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'prompt_cached_tokens_before') = 'number'
      THEN (trace.summary ->> 'prompt_cached_tokens_before')::bigint
    ELSE NULL
  END AS prompt_cached_tokens_before,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'prompt_reused_tokens') = 'number'
      THEN (trace.summary ->> 'prompt_reused_tokens')::bigint
    ELSE NULL
  END AS prompt_reused_tokens,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'prompt_decoded_tokens') = 'number'
      THEN (trace.summary ->> 'prompt_decoded_tokens')::bigint
    ELSE NULL
  END AS prompt_decoded_tokens,
  trace.summary ->> 'prompt_reuse_strategy' AS prompt_reuse_strategy,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'prompt_prefix_state_bytes') = 'number'
      THEN (trace.summary ->> 'prompt_prefix_state_bytes')::bigint
    ELSE NULL
  END AS prompt_prefix_state_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'prompt_prefix_cache_entries') = 'number'
      THEN (trace.summary ->> 'prompt_prefix_cache_entries')::bigint
    ELSE NULL
  END AS prompt_prefix_cache_entries,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'prompt_prefix_cache_bytes') = 'number'
      THEN (trace.summary ->> 'prompt_prefix_cache_bytes')::bigint
    ELSE NULL
  END AS prompt_prefix_cache_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'effective_llama_threads') = 'number'
      THEN (trace.summary ->> 'effective_llama_threads')::bigint
    ELSE NULL
  END AS effective_llama_threads,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'effective_llama_batch_threads') = 'number'
      THEN (trace.summary ->> 'effective_llama_batch_threads')::bigint
    ELSE NULL
  END AS effective_llama_batch_threads,
  r.generated_tokens,
  r.generate_ms,
  r.tokens_per_second,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'runtime_prepare_ms') = 'number'
      THEN (trace.summary ->> 'runtime_prepare_ms')::bigint
    ELSE NULL
  END AS runtime_prepare_ms,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'model_load_ms') = 'number'
      THEN (trace.summary ->> 'model_load_ms')::bigint
    ELSE NULL
  END AS model_load_ms,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'model_context_ms') = 'number'
      THEN (trace.summary ->> 'model_context_ms')::bigint
    ELSE NULL
  END AS model_context_ms,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'tokenize_ms') = 'number'
      THEN (trace.summary ->> 'tokenize_ms')::bigint
    ELSE NULL
  END AS tokenize_ms,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'prompt_decode_ms') = 'number'
      THEN (trace.summary ->> 'prompt_decode_ms')::bigint
    ELSE NULL
  END AS prompt_decode_ms,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'postprocess_ms') = 'number'
      THEN (trace.summary ->> 'postprocess_ms')::bigint
    ELSE NULL
  END AS postprocess_ms,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'finish_sql_ms') = 'number'
      THEN (trace.summary ->> 'finish_sql_ms')::bigint
    ELSE NULL
  END AS finish_sql_ms,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'materialize_ms') = 'number'
      THEN (trace.summary ->> 'materialize_ms')::bigint
    ELSE NULL
  END AS materialize_ms,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'first_token_ms') = 'number'
      THEN (trace.summary ->> 'first_token_ms')::bigint
    ELSE NULL
  END AS first_token_ms,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'ttft_ms') = 'number'
      THEN (trace.summary ->> 'ttft_ms')::bigint
    ELSE NULL
  END AS ttft_ms,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'steady_tokens_per_second') = 'number'
      THEN (trace.summary ->> 'steady_tokens_per_second')::numeric
    ELSE NULL
  END AS steady_tokens_per_second,
  r.schema_validation_status,
  trace.summary ->> 'trace_version' AS trace_version,
  trace.summary AS trace_summary,
  trace.summary ->> 'runtime_fingerprint_version' AS runtime_fingerprint_version,
  trace.summary ->> 'runtime_fingerprint_hash' AS runtime_fingerprint_hash,
  trace.summary ->> 'runtime_output_contract_hash' AS runtime_output_contract_hash,
  trace.summary -> 'runtime_fingerprint' AS runtime_fingerprint,
  COALESCE(
    NULLIF(trace.summary #>> '{decision,preset_name}', ''),
    NULLIF(trace.summary ->> 'decision_preset_name', '')
  ) AS decision_preset_name,
  COALESCE(
    NULLIF(trace.summary #>> '{decision,preset_contract_hash}', ''),
    NULLIF(trace.summary ->> 'decision_preset_contract_hash', '')
  ) AS decision_preset_contract_hash,
  trace.summary -> 'runtime_options_status' AS runtime_options_status,
  trace.summary ->> 'executor_origin' AS executor_origin,
  trace.summary ->> 'executor_node' AS executor_node,
  trace.summary ->> 'executor_boundary' AS executor_boundary,
  trace.summary ->> 'planner_selected_path' AS planner_selected_path,
  trace.summary ->> 'source_tuple_provider' AS source_tuple_provider,
  trace.summary ->> 'refresh_policy' AS refresh_policy,
  trace.summary ->> 'semantic_index_kind' AS semantic_index_kind,
  trace.summary ->> 'semantic_index_name' AS semantic_index_name,
  trace.summary -> 'probability_summary' ->> 'status' AS probability_status,
  trace.summary -> 'probability_summary' ->> 'method' AS probability_method,
  trace.summary -> 'detailed_trace' ->> 'status' AS detailed_trace_status,
  trace.summary -> 'detailed_trace' ->> 'trace_contract' AS detailed_trace_contract,
  trace.summary -> 'detailed_trace' ->> 'storage_policy' AS detailed_trace_storage_policy,
  trace.summary -> 'detailed_trace' ->> 'text_storage' AS detailed_trace_text_storage,
  trace.summary -> 'detailed_trace' ->> 'logprob_policy' AS detailed_trace_logprob_policy,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{detailed_trace,max_tokens}') = 'number'
      THEN (trace.summary #>> '{detailed_trace,max_tokens}')::bigint
    ELSE NULL
  END AS detailed_trace_max_tokens,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{detailed_trace,top_k}') = 'number'
      THEN (trace.summary #>> '{detailed_trace,top_k}')::bigint
    ELSE NULL
  END AS detailed_trace_top_k,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{detailed_trace,captured_tokens}') = 'number'
      THEN (trace.summary #>> '{detailed_trace,captured_tokens}')::bigint
    ELSE NULL
  END AS detailed_trace_captured_tokens,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{detailed_trace,skipped_tokens}') = 'number'
      THEN (trace.summary #>> '{detailed_trace,skipped_tokens}')::bigint
    ELSE NULL
  END AS detailed_trace_skipped_tokens,
  trace.summary ->> 'row_identity' AS row_identity,
  trace.summary -> 'mvcc' AS mvcc,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{input_shaping,shaped_input_bytes}') = 'number'
      THEN (trace.summary #>> '{input_shaping,shaped_input_bytes}')::bigint
    WHEN jsonb_typeof(trace.summary -> 'shaped_input_bytes') = 'number'
      THEN (trace.summary ->> 'shaped_input_bytes')::bigint
    ELSE NULL
  END AS shaped_input_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{input_shaping,original_shaped_input_bytes}') = 'number'
      THEN (trace.summary #>> '{input_shaping,original_shaped_input_bytes}')::bigint
    WHEN jsonb_typeof(trace.summary -> 'original_shaped_input_bytes') = 'number'
      THEN (trace.summary ->> 'original_shaped_input_bytes')::bigint
    ELSE NULL
  END AS original_shaped_input_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{input_shaping,max_shaped_input_bytes}') = 'number'
      THEN (trace.summary #>> '{input_shaping,max_shaped_input_bytes}')::bigint
    WHEN jsonb_typeof(trace.summary -> 'max_shaped_input_bytes') = 'number'
      THEN (trace.summary ->> 'max_shaped_input_bytes')::bigint
    ELSE NULL
  END AS max_shaped_input_bytes,
  COALESCE(
    trace.summary #>> '{input_shaping,input_truncated}',
    trace.summary ->> 'input_truncated',
    'false'
  )::boolean AS input_truncated,
  COALESCE(
    trace.summary #>> '{input_shaping,applied}',
    trace.summary ->> 'input_shaping_applied',
    'false'
  )::boolean AS input_shaping_applied,
  materialization.freshness_basis,
  COALESCE(trace.summary #>> '{policies,worker_handoff}', trace.summary ->> 'worker_handoff') AS worker_handoff,
  COALESCE(trace.summary #>> '{policies,stale_policy}', trace.summary ->> 'stale_policy') AS stale_policy,
  trace.summary ->> 'stop_reason' AS stop_reason,
  trace.summary ->> 'schema_force' AS schema_force,
  trace.summary ->> 'decode_constraint' AS decode_constraint,
  trace.summary ->> 'decode_constraint_reason' AS decode_constraint_reason,
  trace.summary ->> 'output_schema_hash' AS trace_output_schema_hash,
  r.output_schema_hash AS receipt_output_schema_hash,
  trace.summary ->> 'raw_output_hash' AS trace_raw_output_hash,
  r.raw_output_hash AS receipt_raw_output_hash,
  CASE
    WHEN jsonb_typeof(trace.summary -> 'model_memory_bytes') = 'number'
      THEN (trace.summary ->> 'model_memory_bytes')::bigint
    ELSE NULL
  END AS model_memory_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,after,process_rss_bytes}') = 'number'
      THEN (trace.summary #>> '{memory,after,process_rss_bytes}')::bigint
    WHEN jsonb_typeof(trace.summary -> 'worker_process_rss_bytes') = 'number'
      THEN (trace.summary ->> 'worker_process_rss_bytes')::bigint
    ELSE NULL
  END AS worker_process_rss_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,after,process_virtual_bytes}') = 'number'
      THEN (trace.summary #>> '{memory,after,process_virtual_bytes}')::bigint
    WHEN jsonb_typeof(trace.summary -> 'worker_process_virtual_bytes') = 'number'
      THEN (trace.summary ->> 'worker_process_virtual_bytes')::bigint
    ELSE NULL
  END AS worker_process_virtual_bytes,
  COALESCE(trace.summary #>> '{memory,worker_memory_sample_policy}', trace.summary ->> 'worker_memory_sample_policy') AS worker_memory_sample_policy,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,worker_memory_budget_bytes}') = 'number'
      THEN (trace.summary #>> '{memory,worker_memory_budget_bytes}')::bigint
    WHEN jsonb_typeof(trace.summary -> 'worker_memory_budget_bytes') = 'number'
      THEN (trace.summary ->> 'worker_memory_budget_bytes')::bigint
    ELSE NULL
  END AS worker_memory_budget_bytes,
  COALESCE(trace.summary #>> '{memory,worker_memory_budget_policy}', trace.summary ->> 'worker_memory_budget_policy') AS worker_memory_budget_policy,
  trace.summary -> 'memory' AS memory_evidence,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,after,process_swap_bytes}') = 'number'
      THEN (trace.summary #>> '{memory,after,process_swap_bytes}')::bigint
    ELSE NULL
  END AS worker_process_swap_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,after,system_memory_available_bytes}') = 'number'
      THEN (trace.summary #>> '{memory,after,system_memory_available_bytes}')::bigint
    ELSE NULL
  END AS system_memory_available_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,after,system_swap_free_bytes}') = 'number'
      THEN (trace.summary #>> '{memory,after,system_swap_free_bytes}')::bigint
    ELSE NULL
  END AS system_swap_free_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,delta,process_major_faults}') = 'number'
      THEN (trace.summary #>> '{memory,delta,process_major_faults}')::bigint
    ELSE NULL
  END AS worker_major_faults,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,delta,process_read_bytes}') = 'number'
      THEN (trace.summary #>> '{memory,delta,process_read_bytes}')::bigint
    ELSE NULL
  END AS worker_read_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,delta,memory_pressure_some_total_us}') = 'number'
      THEN (trace.summary #>> '{memory,delta,memory_pressure_some_total_us}')::bigint
    ELSE NULL
  END AS memory_pressure_some_us,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,delta,memory_pressure_full_total_us}') = 'number'
      THEN (trace.summary #>> '{memory,delta,memory_pressure_full_total_us}')::bigint
    ELSE NULL
  END AS memory_pressure_full_us,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,after,cgroup_memory_current_bytes}') = 'number'
      THEN (trace.summary #>> '{memory,after,cgroup_memory_current_bytes}')::bigint
    ELSE NULL
  END AS cgroup_memory_current_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,after,cgroup_memory_max_bytes}') = 'number'
      THEN (trace.summary #>> '{memory,after,cgroup_memory_max_bytes}')::bigint
    ELSE NULL
  END AS cgroup_memory_max_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,delta,cgroup_memory_high_events}') = 'number'
      THEN (trace.summary #>> '{memory,delta,cgroup_memory_high_events}')::bigint
    ELSE NULL
  END AS cgroup_memory_high_events,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,delta,cgroup_memory_oom_events}') = 'number'
      THEN (trace.summary #>> '{memory,delta,cgroup_memory_oom_events}')::bigint
    ELSE NULL
  END AS cgroup_memory_oom_events,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,delta,cgroup_memory_oom_kill_events}') = 'number'
      THEN (trace.summary #>> '{memory,delta,cgroup_memory_oom_kill_events}')::bigint
    ELSE NULL
  END AS cgroup_memory_oom_kill_events,
  trace.summary #>> '{memory,admission,decision}' AS model_load_admission_decision,
  trace.summary #>> '{memory,admission,reason}' AS model_load_admission_reason,
  trace.summary #>> '{memory,admission,policy}' AS model_load_admission_policy,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{memory,admission,allowed_additional_bytes}') = 'number'
      THEN (trace.summary #>> '{memory,admission,allowed_additional_bytes}')::bigint
    ELSE NULL
  END AS model_load_allowed_additional_bytes,
  COALESCE(trace.summary ->> 'model_cache_hit', 'false')::boolean AS model_cache_hit,
  COALESCE(trace.summary ->> 'inference_cache_hit', 'false')::boolean AS inference_cache_hit,
  COALESCE(trace.summary #>> '{cache,key_basis}', trace.summary ->> 'inference_cache_key_basis') AS inference_cache_key_basis,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{cache,entries}') = 'number'
      THEN (trace.summary #>> '{cache,entries}')::bigint
    WHEN jsonb_typeof(trace.summary -> 'inference_cache_entries') = 'number'
      THEN (trace.summary ->> 'inference_cache_entries')::bigint
    ELSE NULL
  END AS inference_cache_entries,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{cache,bytes}') = 'number'
      THEN (trace.summary #>> '{cache,bytes}')::bigint
    WHEN jsonb_typeof(trace.summary -> 'inference_cache_bytes') = 'number'
      THEN (trace.summary ->> 'inference_cache_bytes')::bigint
    ELSE NULL
  END AS inference_cache_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{cache,max_entries}') = 'number'
      THEN (trace.summary #>> '{cache,max_entries}')::bigint
    WHEN jsonb_typeof(trace.summary -> 'inference_cache_max_entries') = 'number'
      THEN (trace.summary ->> 'inference_cache_max_entries')::bigint
    ELSE NULL
  END AS inference_cache_max_entries,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{cache,max_bytes}') = 'number'
      THEN (trace.summary #>> '{cache,max_bytes}')::bigint
    WHEN jsonb_typeof(trace.summary -> 'inference_cache_max_bytes') = 'number'
      THEN (trace.summary ->> 'inference_cache_max_bytes')::bigint
    ELSE NULL
  END AS inference_cache_max_bytes,
  CASE
    WHEN jsonb_typeof(trace.summary #> '{cache,evictions}') = 'number'
      THEN (trace.summary #>> '{cache,evictions}')::bigint
    WHEN jsonb_typeof(trace.summary -> 'inference_cache_evictions') = 'number'
      THEN (trace.summary ->> 'inference_cache_evictions')::bigint
    ELSE NULL
  END AS inference_cache_evictions,
  COALESCE(trace.summary #>> '{cache,eviction_reason}', trace.summary ->> 'inference_cache_eviction_reason') AS inference_cache_eviction_reason,
  COALESCE(trace.summary #>> '{cache,invalidation_reason}', trace.summary ->> 'inference_cache_invalidation_reason') AS inference_cache_reason,
  r.finished_at AS receipt_finished_at
FROM otlet.inference_receipts r
CROSS JOIN LATERAL (
  -- Expand the toasted object once and keep the projection from being pulled up
  SELECT r.trace_summary || '{}'::jsonb AS summary
  OFFSET 0
) trace
LEFT JOIN otlet.outputs o ON o.receipt_id = r.id
LEFT JOIN latest_materialization materialization ON materialization.receipt_id = r.id;
