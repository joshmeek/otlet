CREATE VIEW otlet.runs AS
SELECT
  j.id AS job_id,
  j.task_name,
  j.subject_id,
  j.status,
  j.attempts,
  j.error,
  j.input,
  j.started_at,
  j.finished_at,
  j.cancel_requested_at,
  o.id AS output_id,
  o.output,
  COALESCE(o.raw_output, j.raw_output) AS raw_output,
  r.id AS receipt_id,
  r.model_name,
  r.runtime_name,
  r.prompt_hash,
  r.input_hash,
  r.output_schema_hash,
  r.raw_output_hash,
  r.prompt_tokens,
  r.generated_tokens,
  r.generate_ms,
  r.tokens_per_second,
  r.schema_validation_status,
  r.trace_summary,
  j.created_at AS job_created_at,
  o.created_at AS output_created_at,
  r.finished_at AS receipt_finished_at
FROM otlet.jobs j
LEFT JOIN otlet.outputs o ON o.job_id = j.id
LEFT JOIN otlet.inference_receipts r ON r.job_id = j.id;

CREATE VIEW otlet.inference_receipt_trace_status AS
SELECT
  r.id AS receipt_id,
  r.job_id,
  r.task_name,
  r.subject_id,
  r.status,
  r.model_name,
  r.runtime_name,
  r.prompt_tokens,
  r.generated_tokens,
  r.generate_ms,
  r.tokens_per_second,
  r.schema_validation_status,
  r.trace_summary ->> 'trace_version' AS trace_version,
  r.trace_summary -> 'runtime_options_status' AS runtime_options_status,
  r.trace_summary ->> 'executor_origin' AS executor_origin,
  r.trace_summary ->> 'executor_node' AS executor_node,
  r.trace_summary ->> 'executor_boundary' AS executor_boundary,
  r.trace_summary ->> 'planner_selected_path' AS planner_selected_path,
  r.trace_summary ->> 'source_tuple_provider' AS source_tuple_provider,
  r.trace_summary ->> 'refresh_policy' AS refresh_policy,
  r.trace_summary ->> 'semantic_index_kind' AS semantic_index_kind,
  r.trace_summary ->> 'semantic_index_name' AS semantic_index_name,
  r.trace_summary ->> 'semantic_predicate_kind' AS semantic_predicate_kind,
  r.trace_summary ->> 'semantic_action_type' AS semantic_action_type,
  r.trace_summary -> 'probability_summary' ->> 'status' AS probability_status,
  r.trace_summary -> 'probability_summary' ->> 'method' AS probability_method,
  r.trace_summary -> 'detailed_trace' ->> 'status' AS detailed_trace_status,
  r.trace_summary -> 'detailed_trace' ->> 'trace_contract' AS detailed_trace_contract,
  r.trace_summary -> 'detailed_trace' ->> 'storage_policy' AS detailed_trace_storage_policy,
  r.trace_summary -> 'detailed_trace' ->> 'logprob_policy' AS detailed_trace_logprob_policy,
  CASE
    WHEN jsonb_typeof(r.trace_summary #> '{detailed_trace,max_tokens}') = 'number'
      THEN (r.trace_summary #>> '{detailed_trace,max_tokens}')::bigint
    ELSE NULL
  END AS detailed_trace_max_tokens,
  CASE
    WHEN jsonb_typeof(r.trace_summary #> '{detailed_trace,top_k}') = 'number'
      THEN (r.trace_summary #>> '{detailed_trace,top_k}')::bigint
    ELSE NULL
  END AS detailed_trace_top_k,
  CASE
    WHEN jsonb_typeof(r.trace_summary #> '{detailed_trace,captured_tokens}') = 'number'
      THEN (r.trace_summary #>> '{detailed_trace,captured_tokens}')::bigint
    ELSE NULL
  END AS detailed_trace_captured_tokens,
  CASE
    WHEN jsonb_typeof(r.trace_summary #> '{detailed_trace,skipped_tokens}') = 'number'
      THEN (r.trace_summary #>> '{detailed_trace,skipped_tokens}')::bigint
    ELSE NULL
  END AS detailed_trace_skipped_tokens,
  r.trace_summary ->> 'row_identity' AS row_identity,
  r.trace_summary -> 'mvcc' AS mvcc,
  r.trace_summary ->> 'worker_handoff' AS worker_handoff,
  r.trace_summary ->> 'stale_policy' AS stale_policy,
  r.trace_summary ->> 'stop_reason' AS stop_reason,
  r.trace_summary ->> 'schema_force' AS schema_force,
  r.trace_summary ->> 'output_schema_hash' AS trace_output_schema_hash,
  r.output_schema_hash AS receipt_output_schema_hash,
  r.trace_summary ->> 'raw_output_hash' AS trace_raw_output_hash,
  r.raw_output_hash AS receipt_raw_output_hash,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'model_memory_bytes') = 'number'
      THEN (r.trace_summary ->> 'model_memory_bytes')::bigint
    ELSE NULL
  END AS model_memory_bytes,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'worker_process_rss_bytes') = 'number'
      THEN (r.trace_summary ->> 'worker_process_rss_bytes')::bigint
    ELSE NULL
  END AS worker_process_rss_bytes,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'worker_process_virtual_bytes') = 'number'
      THEN (r.trace_summary ->> 'worker_process_virtual_bytes')::bigint
    ELSE NULL
  END AS worker_process_virtual_bytes,
  r.trace_summary ->> 'worker_memory_sample_policy' AS worker_memory_sample_policy,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'worker_memory_budget_bytes') = 'number'
      THEN (r.trace_summary ->> 'worker_memory_budget_bytes')::bigint
    ELSE NULL
  END AS worker_memory_budget_bytes,
  r.trace_summary ->> 'worker_memory_budget_policy' AS worker_memory_budget_policy,
  COALESCE(r.trace_summary ->> 'model_cache_hit', 'false')::boolean AS model_cache_hit,
  COALESCE(r.trace_summary ->> 'inference_cache_hit', 'false')::boolean AS inference_cache_hit,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'inference_cache_entries') = 'number'
      THEN (r.trace_summary ->> 'inference_cache_entries')::bigint
    ELSE NULL
  END AS inference_cache_entries,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'inference_cache_bytes') = 'number'
      THEN (r.trace_summary ->> 'inference_cache_bytes')::bigint
    ELSE NULL
  END AS inference_cache_bytes,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'inference_cache_evictions') = 'number'
      THEN (r.trace_summary ->> 'inference_cache_evictions')::bigint
    ELSE NULL
  END AS inference_cache_evictions,
  r.trace_summary ->> 'inference_cache_invalidation_reason' AS inference_cache_reason,
  r.finished_at AS receipt_finished_at
FROM otlet.inference_receipts r;
