CREATE VIEW otlet.inference_trace_chain AS
SELECT
  s.receipt_id,
  s.job_id,
  s.task_name,
  s.subject_id,
  s.status,
  s.row_identity,
  s.stop_reason,
  s.summary_sql,
  s.timeline_sql,
  s.alternatives_sql,
  jsonb_build_object(
    'receipt', jsonb_build_object(
      'receipt_id', s.receipt_id,
      'job_id', s.job_id,
      'task_name', s.task_name,
      'subject_id', s.subject_id,
      'status', s.status,
      'error', s.error,
      'model_name', s.model_name,
      'runtime_name', s.runtime_name,
      'model_fingerprint_hash', r.trace_summary ->> 'model_fingerprint_hash',
      'prompt_hash', r.prompt_hash,
      'input_hash', r.input_hash,
      'runtime_options_hash', r.trace_summary ->> 'runtime_options_hash',
      'output_schema_hash', r.output_schema_hash,
      'raw_output_hash', r.raw_output_hash,
      'row_identity', s.row_identity,
      'mvcc', s.mvcc,
      'stale_policy', s.stale_policy,
      'worker_handoff', s.worker_handoff,
      'stop_reason', s.stop_reason
    ),
    'trace', jsonb_build_object(
      'status', s.detailed_trace_status,
      'contract', s.detailed_trace_contract,
      'token_steps', s.token_steps,
      'top_k_alternatives', s.top_k_alternatives,
      'chosen_text_readable', s.chosen_text_readable,
      'summary_bytes', s.trace_summary_bytes,
      'runtime_options_status', s.runtime_options_status
    ),
    'timeline', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'step', t.step,
          'token_id', t.token_id,
          'token_text_readable', t.token_text_readable,
          'generated_text_readable_so_far', t.generated_text_readable_so_far,
          'chosen_probability', t.chosen_probability,
          'chosen_logprob', t.chosen_logprob,
          'chosen_rank', t.chosen_rank
        )
        ORDER BY t.step
      )
      FROM otlet.inference_trace_timeline t
      WHERE t.receipt_id = s.receipt_id
    ), '[]'::jsonb),
    'alternatives', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'step', a.step,
          'rank', a.alternative_rank,
          'token_id', a.token_id,
          'token_text_readable', a.token_text_readable,
          'probability', a.probability,
          'logprob', a.logprob
        )
        ORDER BY a.step, a.alternative_rank
      )
      FROM otlet.inference_trace_alternatives a
      WHERE a.receipt_id = s.receipt_id
    ), '[]'::jsonb),
    'links', jsonb_build_object(
      'outputs', s.output_ids,
      'actions', s.action_ids,
      'materializations', s.materialization_ids
    ),
    'inspection_sql', jsonb_build_object(
      'summary', s.summary_sql,
      'timeline', s.timeline_sql,
      'alternatives', s.alternatives_sql,
      'chain', s.chain_sql
    )
  ) AS trace_chain
FROM otlet.inference_trace_summary s
JOIN otlet.inference_receipts r ON r.id = s.receipt_id;

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
    s.inference_cache_reason,
    pg_column_size(r.trace_summary)::bigint AS trace_summary_bytes,
    COALESCE(jsonb_array_length(r.trace_summary #> '{detailed_trace,chosen_token_ids}'), 0)::bigint AS chosen_token_ids,
    COALESCE((
      SELECT count(*)
      FROM otlet.inference_receipt_token_trace t
      WHERE t.job_id = s.job_id
    ), 0)::bigint AS token_steps,
    COALESCE((
      SELECT count(*)
      FROM otlet.inference_receipt_token_trace t
      WHERE t.job_id = s.job_id
        AND t.chosen_logprob IS NOT NULL
        AND t.chosen_probability IS NOT NULL
    ), 0)::bigint AS token_logprob_steps,
    COALESCE((
      SELECT count(*)
      FROM otlet.inference_receipt_token_alternative_trace a
      WHERE a.job_id = s.job_id
    ), 0)::bigint AS top_k_alternatives,
    COALESCE((
      SELECT count(*)
      FROM otlet.inference_receipt_token_alternative_trace a
      WHERE a.job_id = s.job_id
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
