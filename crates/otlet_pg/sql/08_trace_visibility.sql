CREATE VIEW otlet.inference_visibility_status AS
WITH per_receipt AS (
  SELECT
    s.job_id,
    s.status,
    r.error,
    s.detailed_trace_status,
    s.detailed_trace_contract,
    s.detailed_trace_captured_tokens,
    s.detailed_trace_top_k,
    s.row_identity,
    s.mvcc,
    s.worker_handoff,
    s.stale_policy,
    s.stop_reason,
    s.executor_origin,
    s.executor_node,
    s.inference_cache_hit,
    s.inference_cache_key_basis,
    s.inference_cache_eviction_reason,
    s.inference_cache_reason,
    pg_column_size(r.trace_summary)::bigint AS trace_summary_bytes,
    COALESCE(jsonb_array_length(r.trace_summary #> '{detailed_trace,chosen_token_ids}'), 0)::bigint AS chosen_token_ids,
    COALESCE((
      SELECT count(*)
      FROM otlet.inference_receipt_token_trace t
      WHERE t.receipt_id = s.receipt_id
    ), 0)::bigint AS token_steps,
    COALESCE((
      SELECT count(*)
      FROM otlet.inference_receipt_token_trace t
      WHERE t.receipt_id = s.receipt_id
        AND t.chosen_logprob IS NOT NULL
        AND t.chosen_probability IS NOT NULL
    ), 0)::bigint AS token_logprob_steps,
    COALESCE((
      SELECT count(*)
      FROM otlet.inference_receipt_token_alternative_trace a
      WHERE a.receipt_id = s.receipt_id
    ), 0)::bigint AS top_k_alternatives,
    COALESCE((
      SELECT count(*)
      FROM otlet.inference_receipt_token_alternative_trace a
      WHERE a.receipt_id = s.receipt_id
        AND a.logprob IS NOT NULL
        AND a.probability IS NOT NULL
    ), 0)::bigint AS top_k_logprob_alternatives,
    EXISTS (
      SELECT 1
      FROM otlet.outputs o
      WHERE o.job_id = s.job_id
    ) AS has_output,
    EXISTS (
      SELECT 1
      FROM otlet.actions a
      WHERE a.job_id = s.job_id
    ) AS has_action,
    EXISTS (
      SELECT 1
      FROM otlet.semantic_materializations sm
      WHERE sm.task_name = s.task_name
        AND sm.subject_id = s.subject_id
        AND sm.source_hash IS NOT NULL
    ) AS has_materialization_source_hash
  FROM otlet.inference_receipt_trace_status s
  JOIN otlet.inference_receipts r ON r.id = s.receipt_id
)
SELECT
  count(*)::bigint AS receipt_count,
  count(*) FILTER (
    WHERE detailed_trace_status = 'available'
      AND detailed_trace_contract = 'receipt_trace_v2_bounded_token_steps'
  )::bigint AS detailed_trace_receipts,
  COALESCE(sum(token_steps), 0)::bigint AS token_steps,
  COALESCE(sum(token_logprob_steps), 0)::bigint AS token_logprob_steps,
  COALESCE(sum(top_k_alternatives), 0)::bigint AS top_k_alternatives,
  COALESCE(sum(top_k_logprob_alternatives), 0)::bigint AS top_k_logprob_alternatives,
  count(*) FILTER (
    WHERE chosen_token_ids > 0
      AND chosen_token_ids = detailed_trace_captured_tokens
  )::bigint AS chosen_token_id_receipts,
  count(*) FILTER (WHERE has_output)::bigint AS output_linked_receipts,
  count(*) FILTER (WHERE has_action)::bigint AS action_linked_receipts,
  count(*) FILTER (
    WHERE executor_origin IS NOT NULL
      AND executor_node IS NOT NULL
  )::bigint AS provenance_linked_receipts,
  count(*) FILTER (WHERE row_identity IS NOT NULL)::bigint AS row_identity_receipts,
  count(*) FILTER (
    WHERE COALESCE(mvcc ->> 'source_hash', '') <> ''
       OR has_materialization_source_hash
  )::bigint AS source_hash_receipts,
  count(*) FILTER (WHERE stale_policy IS NOT NULL)::bigint AS stale_policy_receipts,
  count(*) FILTER (WHERE worker_handoff IS NOT NULL)::bigint AS worker_handoff_receipts,
  count(*) FILTER (WHERE stop_reason IS NOT NULL)::bigint AS stop_reason_receipts,
  count(*) FILTER (
    WHERE status IN ('failed', 'canceled')
      AND error IS NOT NULL
  )::bigint AS error_receipts,
  count(*) FILTER (WHERE inference_cache_reason IS NOT NULL)::bigint AS cache_state_receipts,
  count(*) FILTER (WHERE inference_cache_key_basis IS NOT NULL)::bigint AS cache_key_basis_receipts,
  count(*) FILTER (WHERE inference_cache_eviction_reason IS NOT NULL)::bigint AS cache_eviction_reason_receipts,
  count(*) FILTER (
    WHERE detailed_trace_status = 'available'
      AND inference_cache_hit = false
      AND inference_cache_reason = 'disabled_for_generation_trace'
  )::bigint AS cache_disabled_trace_receipts,
  count(*) FILTER (WHERE inference_cache_hit = true)::bigint AS cache_hit_receipts,
  count(*) FILTER (
    WHERE executor_origin = 'customscan_infer_now'
      AND executor_node = 'Otlet Semantic Source CustomScan'
      AND detailed_trace_status = 'available'
  )::bigint AS customscan_trace_receipts,
  COALESCE(max(trace_summary_bytes), 0)::bigint AS max_trace_summary_bytes,
  COALESCE(max(detailed_trace_captured_tokens), 0)::bigint AS max_detailed_trace_tokens,
  COALESCE(max(detailed_trace_top_k), 0)::bigint AS max_detailed_trace_top_k
FROM per_receipt;
