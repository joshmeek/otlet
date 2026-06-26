CREATE VIEW otlet.model_selection_attempts AS
SELECT
  r.job_id,
  r.task_name,
  r.subject_id,
  r.attempt_index,
  r.selection_role,
  r.selection_status,
  r.selection_reason,
  (o.id IS NOT NULL) AS accepted,
  r.model_name,
  r.runtime_name,
  r.schema_validation_status,
  r.status,
  r.error,
  o.output,
  r.raw_output,
  r.raw_output_hash,
  r.prompt_tokens,
  r.generated_tokens,
  r.generate_ms,
  r.tokens_per_second,
  r.id AS receipt_id,
  o.id AS output_id,
  r.finished_at
FROM otlet.inference_receipts r
LEFT JOIN otlet.outputs o ON o.receipt_id = r.id;

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
  accepted.output_id,
  accepted.output,
  COALESCE(accepted.output_raw_output, accepted.raw_output, j.raw_output) AS raw_output,
  accepted.receipt_id,
  accepted.receipt_id AS accepted_receipt_id,
  accepted.model_name,
  accepted.model_name AS accepted_model_name,
  accepted.runtime_name,
  accepted.prompt_hash,
  accepted.input_hash,
  accepted.output_schema_hash,
  accepted.raw_output_hash,
  accepted.prompt_tokens,
  accepted.generated_tokens,
  accepted.generate_ms,
  accepted.tokens_per_second,
  accepted.schema_validation_status,
  accepted.trace_summary,
  accepted.selection_role AS model_selection_role,
  accepted.selection_status AS model_selection_status,
  accepted.selection_reason AS model_selection_reason,
  COALESCE(attempts.model_attempt_count, 0)::bigint AS model_attempt_count,
  COALESCE(attempts.escalated, false) AS escalated,
  j.created_at AS job_created_at,
  accepted.output_created_at,
  accepted.finished_at AS receipt_finished_at
FROM otlet.jobs j
LEFT JOIN LATERAL (
  SELECT
    ar.id AS receipt_id,
    ar.model_name,
    ar.runtime_name,
    ar.prompt_hash,
    ar.input_hash,
    ar.output_schema_hash,
    ar.raw_output_hash,
    ar.raw_output,
    ar.prompt_tokens,
    ar.generated_tokens,
    ar.generate_ms,
    ar.tokens_per_second,
    ar.schema_validation_status,
    ar.trace_summary,
    ar.selection_role,
    ar.selection_status,
    ar.selection_reason,
    ar.finished_at,
    o.id AS output_id,
    o.output,
    o.raw_output AS output_raw_output,
    o.created_at AS output_created_at
  FROM otlet.outputs o
  JOIN otlet.inference_receipts ar ON ar.id = o.receipt_id
  WHERE o.job_id = j.id
  ORDER BY ar.attempt_index DESC, ar.id DESC
  LIMIT 1
) accepted ON true
LEFT JOIN LATERAL (
  SELECT
    count(*)::bigint AS model_attempt_count,
    bool_or(ar.selection_role = 'strong') AS escalated
  FROM otlet.inference_receipts ar
  WHERE ar.job_id = j.id
) attempts ON true;

CREATE VIEW otlet.action_status AS
SELECT
  a.id AS action_id,
  a.job_id,
  j.task_name,
  j.subject_id AS job_subject_id,
  a.subject_id,
  a.action_type,
  a.status,
  a.approval_status,
  a.dry_run_status,
  a.apply_status,
  a.source_table,
  a.source_hash,
  a.error,
  a.payload,
  a.output_id,
  a.receipt_id,
  (o.id IS NOT NULL AND r.selection_status = 'accepted') AS trusted_output,
  a.created_at,
  a.approved_at,
  a.applied_at
FROM otlet.actions a
JOIN otlet.jobs j ON j.id = a.job_id
LEFT JOIN otlet.outputs o ON o.id = a.output_id
LEFT JOIN otlet.inference_receipts r ON r.id = a.receipt_id;

CREATE VIEW otlet.inference_receipt_trace_status AS
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
FROM otlet.inference_receipts r
LEFT JOIN otlet.outputs o ON o.receipt_id = r.id;
