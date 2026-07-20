CREATE VIEW otlet.inference_visibility_status AS
WITH trace_steps AS MATERIALIZED (
  SELECT
    r.id AS receipt_id,
    step.value
  FROM otlet.inference_receipts r
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(r.trace_summary #> '{detailed_trace,steps}') = 'array'
        THEN r.trace_summary #> '{detailed_trace,steps}'
      ELSE '[]'::jsonb
    END
  ) step(value)
),
token_counts AS (
  SELECT
    receipt_id,
    count(*)::bigint AS token_steps,
    count(*) FILTER (WHERE value ? 'token_text')::bigint AS token_text_steps,
    count(*) FILTER (
      WHERE jsonb_typeof(value -> 'chosen_logprob') = 'number'
        AND jsonb_typeof(value -> 'chosen_probability') = 'number'
    )::bigint AS token_logprob_steps
  FROM trace_steps
  GROUP BY receipt_id
),
alternative_counts AS (
  SELECT
    steps.receipt_id,
    count(*)::bigint AS top_k_alternatives,
    count(*) FILTER (WHERE alt.value ? 'token_text')::bigint AS top_k_text_alternatives,
    count(*) FILTER (
      WHERE jsonb_typeof(alt.value -> 'logprob') = 'number'
        AND jsonb_typeof(alt.value -> 'probability') = 'number'
    )::bigint AS top_k_logprob_alternatives
  FROM trace_steps steps
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(steps.value -> 'top_alternatives') = 'array'
        THEN steps.value -> 'top_alternatives'
      ELSE '[]'::jsonb
    END
  ) alt(value)
  GROUP BY steps.receipt_id
),
output_jobs AS (
  SELECT job_id
  FROM otlet.outputs
  GROUP BY job_id
),
action_jobs AS (
  SELECT job_id
  FROM otlet.actions
  GROUP BY job_id
),
materialized_subjects AS (
  SELECT task_name, subject_id
  FROM otlet.semantic_materializations
  WHERE source_hash IS NOT NULL
  GROUP BY task_name, subject_id
),
per_receipt AS (
  SELECT
    r.job_id,
    r.status,
    r.error,
    trace.summary -> 'detailed_trace' ->> 'status' AS detailed_trace_status,
    trace.summary -> 'detailed_trace' ->> 'trace_contract' AS detailed_trace_contract,
    trace.summary -> 'detailed_trace' ->> 'text_storage' AS detailed_trace_text_storage,
    (trace.summary #>> '{detailed_trace,chosen_text}' IS NOT NULL) AS has_chosen_text,
    CASE
      WHEN jsonb_typeof(trace.summary #> '{detailed_trace,captured_tokens}') = 'number'
        THEN (trace.summary #>> '{detailed_trace,captured_tokens}')::bigint
      ELSE NULL
    END AS detailed_trace_captured_tokens,
    CASE
      WHEN jsonb_typeof(trace.summary #> '{detailed_trace,top_k}') = 'number'
        THEN (trace.summary #>> '{detailed_trace,top_k}')::bigint
      ELSE NULL
    END AS detailed_trace_top_k,
    trace.summary ->> 'row_identity' AS row_identity,
    trace.summary -> 'mvcc' AS mvcc,
    COALESCE(trace.summary #>> '{policies,worker_handoff}', trace.summary ->> 'worker_handoff') AS worker_handoff,
    COALESCE(trace.summary #>> '{policies,stale_policy}', trace.summary ->> 'stale_policy') AS stale_policy,
    trace.summary ->> 'stop_reason' AS stop_reason,
    trace.summary ->> 'executor_origin' AS executor_origin,
    trace.summary ->> 'executor_node' AS executor_node,
    COALESCE(trace.summary ->> 'inference_cache_hit', 'false')::boolean AS inference_cache_hit,
    COALESCE(trace.summary #>> '{cache,key_basis}', trace.summary ->> 'inference_cache_key_basis') AS inference_cache_key_basis,
    COALESCE(trace.summary #>> '{cache,eviction_reason}', trace.summary ->> 'inference_cache_eviction_reason') AS inference_cache_eviction_reason,
    COALESCE(trace.summary #>> '{cache,invalidation_reason}', trace.summary ->> 'inference_cache_invalidation_reason') AS inference_cache_reason,
    pg_column_size(r.trace_summary)::bigint AS trace_summary_bytes,
    CASE
      WHEN jsonb_typeof(trace.summary #> '{detailed_trace,chosen_token_ids}') = 'array'
        THEN jsonb_array_length(trace.summary #> '{detailed_trace,chosen_token_ids}')::bigint
      ELSE 0::bigint
    END AS chosen_token_ids,
    COALESCE(tok.token_steps, 0)::bigint AS token_steps,
    COALESCE(tok.token_text_steps, 0)::bigint AS token_text_steps,
    COALESCE(tok.token_logprob_steps, 0)::bigint AS token_logprob_steps,
    COALESCE(alt.top_k_alternatives, 0)::bigint AS top_k_alternatives,
    COALESCE(alt.top_k_text_alternatives, 0)::bigint AS top_k_text_alternatives,
    COALESCE(alt.top_k_logprob_alternatives, 0)::bigint AS top_k_logprob_alternatives,
    (output_jobs.job_id IS NOT NULL) AS has_output,
    (action_jobs.job_id IS NOT NULL) AS has_action,
    (materialized_subjects.task_name IS NOT NULL) AS has_materialization_source_hash
  FROM otlet.inference_receipts r
  CROSS JOIN LATERAL (
    -- Expand the toasted object once and keep the projection from being pulled up
    SELECT r.trace_summary || '{}'::jsonb AS summary
    OFFSET 0
  ) trace
  LEFT JOIN token_counts tok ON tok.receipt_id = r.id
  LEFT JOIN alternative_counts alt ON alt.receipt_id = r.id
  LEFT JOIN output_jobs ON output_jobs.job_id = r.job_id
  LEFT JOIN action_jobs ON action_jobs.job_id = r.job_id
  LEFT JOIN materialized_subjects
    ON materialized_subjects.task_name = r.task_name
   AND materialized_subjects.subject_id = r.subject_id
)
SELECT
  count(*)::bigint AS receipt_count,
  count(*) FILTER (
    WHERE detailed_trace_status = 'available'
      AND detailed_trace_contract = 'receipt_trace_v2_bounded_token_steps'
  )::bigint AS detailed_trace_receipts,
  COALESCE(sum(token_steps), 0)::bigint AS token_steps,
  COALESCE(sum(token_text_steps), 0)::bigint AS token_text_steps,
  COALESCE(sum(token_logprob_steps), 0)::bigint AS token_logprob_steps,
  COALESCE(sum(top_k_alternatives), 0)::bigint AS top_k_alternatives,
  COALESCE(sum(top_k_text_alternatives), 0)::bigint AS top_k_text_alternatives,
  COALESCE(sum(top_k_logprob_alternatives), 0)::bigint AS top_k_logprob_alternatives,
  count(*) FILTER (
    WHERE chosen_token_ids > 0
      AND chosen_token_ids = detailed_trace_captured_tokens
  )::bigint AS chosen_token_id_receipts,
  count(*) FILTER (WHERE has_chosen_text)::bigint AS chosen_text_receipts,
  count(*) FILTER (WHERE detailed_trace_text_storage = 'redacted')::bigint AS redacted_text_receipts,
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
