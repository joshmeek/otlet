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
  a.content_hash,
  a.error,
  a.review_reason,
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

CREATE VIEW otlet.eval_label_status AS
SELECT
  l.id AS label_id,
  l.action_id,
  l.output_id,
  l.receipt_id,
  l.source_table,
  l.subject_id,
  l.source_hash,
  l.expected_answer,
  l.expected_confidence,
  l.expected_action_type,
  l.label_source,
  l.reason,
  a.action_type AS observed_action_type,
  a.status AS action_status,
  a.approval_status,
  o.output ->> COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match') AS observed_answer,
  o.output ->> COALESCE(NULLIF(t.decision_contract ->> 'confidence_field', ''), 'confidence') AS observed_confidence,
  r.model_name,
  r.selection_role,
  r.selection_status,
  l.created_at
FROM otlet.eval_labels l
LEFT JOIN otlet.actions a ON a.id = l.action_id
LEFT JOIN otlet.jobs j ON j.id = a.job_id
LEFT JOIN otlet.tasks t ON t.name = j.task_name
LEFT JOIN otlet.outputs o ON o.id = l.output_id
LEFT JOIN otlet.inference_receipts r ON r.id = l.receipt_id;

CREATE VIEW otlet.review_queue AS
WITH action_items AS (
  SELECT
    CASE
      WHEN a.approval_status = 'required' AND a.status = 'proposed' THEN 'pending_approval'
      ELSE 'review_flag'
    END AS queue_kind,
    j.task_name,
    w.name AS watch_name,
    j.subject_id AS job_subject_id,
    a.subject_id,
    a.id AS action_id,
    a.output_id,
    a.receipt_id,
    a.action_type,
    a.status AS action_status,
    a.approval_status,
    a.review_reason,
    o.output,
    a.source_table,
    a.source_hash,
    a.content_hash,
    COALESCE(materialization.content_hash, a.content_hash) AS current_content_hash,
    (
      COALESCE(materialization.stale, false)
      OR (
        a.content_hash IS NOT NULL
        AND materialization.content_hash IS NOT NULL
        AND materialization.content_hash IS DISTINCT FROM a.content_hash
      )
    ) AS source_stale,
    a.created_at
  FROM otlet.actions a
  JOIN otlet.jobs j ON j.id = a.job_id
  LEFT JOIN otlet.watches w ON w.task_name = j.task_name
  LEFT JOIN otlet.outputs o ON o.id = a.output_id
  LEFT JOIN LATERAL (
    SELECT sm.content_hash, sm.stale
    FROM otlet.semantic_materializations sm
    WHERE sm.task_name = j.task_name
      AND sm.subject_id = j.subject_id
    ORDER BY sm.updated_at DESC, sm.id DESC
    LIMIT 1
  ) materialization ON true
  WHERE (
      (
        a.approval_status = 'required'
        AND a.status = 'proposed'
      )
      OR (
        a.action_type = 'review_flag'
        AND a.status <> 'rejected'
      )
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.eval_labels l
      WHERE l.action_id = a.id
        AND l.label_source = 'manual_correction'
    )
),
abstention_items AS (
  SELECT
    'abstention_output'::text AS queue_kind,
    j.task_name,
    w.name AS watch_name,
    j.subject_id AS job_subject_id,
    j.subject_id AS subject_id,
    NULL::bigint AS action_id,
    o.id AS output_id,
    o.receipt_id,
    NULL::text AS action_type,
    NULL::text AS action_status,
    NULL::text AS approval_status,
    NULL::text AS review_reason,
    o.output,
    r.trace_summary #>> '{mvcc,table}' AS source_table,
    COALESCE(r.trace_summary #>> '{mvcc,source_hash}', md5((r.trace_summary -> 'mvcc')::text)) AS source_hash,
    otlet.semantic_content_hash(j.input, t.input_shaping) AS content_hash,
    COALESCE(materialization.content_hash, otlet.semantic_content_hash(j.input, t.input_shaping)) AS current_content_hash,
    (
      COALESCE(materialization.stale, false)
      OR (
        materialization.content_hash IS NOT NULL
        AND materialization.content_hash IS DISTINCT FROM otlet.semantic_content_hash(j.input, t.input_shaping)
      )
    ) AS source_stale,
    o.created_at
  FROM otlet.outputs o
  JOIN otlet.jobs j ON j.id = o.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
  JOIN otlet.inference_receipts r ON r.id = o.receipt_id
  LEFT JOIN otlet.watches w ON w.task_name = j.task_name
  LEFT JOIN LATERAL (
    SELECT sm.content_hash, sm.stale
    FROM otlet.semantic_materializations sm
    WHERE sm.task_name = j.task_name
      AND sm.subject_id = j.subject_id
    ORDER BY sm.updated_at DESC, sm.id DESC
    LIMIT 1
  ) materialization ON true
  CROSS JOIN LATERAL (
    SELECT
      COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match') AS answer_field,
      COALESCE(
        (
          SELECT array_agg(value)
          FROM jsonb_array_elements_text(COALESCE(t.decision_contract -> 'abstain_values', '["unclear"]'::jsonb)) AS abstain(value)
        ),
        ARRAY[]::text[]
      ) AS abstain_values
  ) contract
  WHERE o.output ->> contract.answer_field = ANY(contract.abstain_values)
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.eval_labels l
      WHERE l.output_id = o.id
        AND l.label_source = 'manual_correction'
    )
),
direct_rejected_items AS (
  SELECT
    'direct_rejected_output'::text AS queue_kind,
    j.task_name,
    w.name AS watch_name,
    j.subject_id AS job_subject_id,
    j.subject_id AS subject_id,
    NULL::bigint AS action_id,
    NULL::bigint AS output_id,
    r.id AS receipt_id,
    NULL::text AS action_type,
    NULL::text AS action_status,
    NULL::text AS approval_status,
    NULL::text AS review_reason,
    r.raw_output::jsonb -> 'output' AS output,
    r.trace_summary #>> '{mvcc,table}' AS source_table,
    COALESCE(r.trace_summary #>> '{mvcc,source_hash}', md5((r.trace_summary -> 'mvcc')::text)) AS source_hash,
    otlet.semantic_content_hash(j.input, t.input_shaping) AS content_hash,
    COALESCE(materialization.content_hash, otlet.semantic_content_hash(j.input, t.input_shaping)) AS current_content_hash,
    (
      COALESCE(materialization.stale, false)
      OR (
        materialization.content_hash IS NOT NULL
        AND materialization.content_hash IS DISTINCT FROM otlet.semantic_content_hash(j.input, t.input_shaping)
      )
    ) AS source_stale,
    r.finished_at AS created_at
  FROM otlet.inference_receipts r
  JOIN otlet.jobs j ON j.id = r.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
  LEFT JOIN otlet.watches w ON w.task_name = j.task_name
  LEFT JOIN LATERAL (
    SELECT sm.content_hash, sm.stale
    FROM otlet.semantic_materializations sm
    WHERE sm.task_name = j.task_name
      AND sm.subject_id = j.subject_id
    ORDER BY sm.updated_at DESC, sm.id DESC
    LIMIT 1
  ) materialization ON true
  WHERE r.selection_role = 'direct'
    AND r.selection_status = 'rejected'
    AND r.selection_reason = 'direct_rejected_by_decision_contract'
    AND r.schema_validation_status = 'passed'
    AND NULLIF(r.raw_output, '') IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.eval_labels l
      WHERE l.receipt_id = r.id
        AND l.label_source = 'manual_correction'
    )
)
SELECT
  queue_kind,
  task_name,
  watch_name,
  job_subject_id,
  subject_id,
  action_id,
  output_id,
  receipt_id,
  action_type,
  action_status,
  approval_status,
  review_reason,
  output,
  source_table,
  source_hash,
  content_hash,
  current_content_hash,
  source_stale,
  created_at
FROM action_items
UNION ALL
SELECT
  queue_kind,
  task_name,
  watch_name,
  job_subject_id,
  subject_id,
  action_id,
  output_id,
  receipt_id,
  action_type,
  action_status,
  approval_status,
  review_reason,
  output,
  source_table,
  source_hash,
  content_hash,
  current_content_hash,
  source_stale,
  created_at
FROM abstention_items
UNION ALL
SELECT
  queue_kind,
  task_name,
  watch_name,
  job_subject_id,
  subject_id,
  action_id,
  output_id,
  receipt_id,
  action_type,
  action_status,
  approval_status,
  review_reason,
  output,
  source_table,
  source_hash,
  content_hash,
  current_content_hash,
  source_stale,
  created_at
FROM direct_rejected_items
ORDER BY created_at, task_name, job_subject_id, queue_kind;

CREATE FUNCTION otlet.review_queue_live()
RETURNS SETOF otlet.review_queue
LANGUAGE sql
STABLE
AS $$
  SELECT
    q.queue_kind,
    q.task_name,
    q.watch_name,
    q.job_subject_id,
    q.subject_id,
    q.action_id,
    q.output_id,
    q.receipt_id,
    q.action_type,
    q.action_status,
    q.approval_status,
    q.review_reason,
    q.output,
    q.source_table,
    q.source_hash,
    q.content_hash,
    live.current_content_hash,
    (q.content_hash IS NOT NULL AND live.current_content_hash IS DISTINCT FROM q.content_hash) AS source_stale,
    q.created_at
  FROM otlet.review_queue q
  CROSS JOIN LATERAL (
    SELECT otlet.current_task_subject_content_hash(q.task_name, q.job_subject_id) AS current_content_hash
  ) live;
$$;

CREATE VIEW otlet.output_reliability_status AS
SELECT
  count(*)::bigint AS receipt_count,
  count(*) FILTER (WHERE status = 'complete' AND schema_validation_status = 'passed')::bigint AS schema_passed_receipts,
  count(*) FILTER (WHERE schema_validation_status = 'failed')::bigint AS schema_failed_receipts,
  count(*) FILTER (WHERE error LIKE 'invalid model JSON:%')::bigint AS json_parse_failed_receipts,
  count(*) FILTER (WHERE selection_role = 'cheap' AND selection_status = 'rejected')::bigint AS cheap_rejected_receipts,
  count(*) FILTER (WHERE selection_role = 'strong' AND selection_status = 'accepted')::bigint AS strong_accepted_receipts,
  count(*) FILTER (WHERE trace_summary ->> 'decode_constraint' IS NOT NULL)::bigint AS decode_constraint_receipts,
  count(DISTINCT job_id) FILTER (WHERE selection_role = 'strong')::bigint AS escalated_jobs,
  (
    SELECT count(*)::bigint
    FROM otlet.outputs o
    JOIN otlet.jobs j ON j.id = o.job_id
    JOIN otlet.tasks t ON t.name = j.task_name
    CROSS JOIN LATERAL (
      SELECT COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match') AS answer_field,
             COALESCE(t.decision_contract -> 'abstain_values', '["unclear"]'::jsonb) AS abstain_values
    ) contract
    WHERE EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(contract.abstain_values) value(abstain_value)
      WHERE o.output ->> contract.answer_field = value.abstain_value
    )
  ) AS abstained_outputs,
  (
    SELECT count(*)::bigint
    FROM otlet.actions a
    WHERE a.status = 'rejected'
  ) AS rejected_actions,
  (
    SELECT count(*)::bigint
    FROM otlet.actions a
    WHERE a.error = 'unsupported action type'
  ) AS unknown_action_rejections,
  (
    SELECT count(*)::bigint
    FROM otlet.outputs o
  ) AS trusted_outputs,
  (
    SELECT count(*)::bigint
    FROM otlet.eval_labels l
  ) AS eval_labels
FROM otlet.inference_receipts;

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
  r.prompt_hash,
  r.prompt_tokens,
  r.generated_tokens,
  r.generate_ms,
  r.tokens_per_second,
  r.schema_validation_status,
  r.trace_summary ->> 'trace_version' AS trace_version,
  NULLIF(r.trace_summary ->> 'decision_preset_name', '') AS decision_preset_name,
  NULLIF(r.trace_summary ->> 'decision_preset_contract_hash', '') AS decision_preset_contract_hash,
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
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'shaped_input_bytes') = 'number'
      THEN (r.trace_summary ->> 'shaped_input_bytes')::bigint
    ELSE NULL
  END AS shaped_input_bytes,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'original_shaped_input_bytes') = 'number'
      THEN (r.trace_summary ->> 'original_shaped_input_bytes')::bigint
    ELSE NULL
  END AS original_shaped_input_bytes,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'max_shaped_input_bytes') = 'number'
      THEN (r.trace_summary ->> 'max_shaped_input_bytes')::bigint
    ELSE NULL
  END AS max_shaped_input_bytes,
  COALESCE(r.trace_summary ->> 'input_truncated', 'false')::boolean AS input_truncated,
  COALESCE(r.trace_summary ->> 'input_shaping_applied', 'false')::boolean AS input_shaping_applied,
  materialization.freshness_basis,
  r.trace_summary ->> 'worker_handoff' AS worker_handoff,
  r.trace_summary ->> 'stale_policy' AS stale_policy,
  r.trace_summary ->> 'stop_reason' AS stop_reason,
  r.trace_summary ->> 'schema_force' AS schema_force,
  r.trace_summary ->> 'schema_prompt' AS schema_prompt,
  r.trace_summary ->> 'prompt_prefix_hash' AS prompt_prefix_hash,
  COALESCE(r.trace_summary ->> 'prompt_prefix_reuse_enabled', 'false')::boolean AS prompt_prefix_reuse_enabled,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'prompt_prefix_tokens') = 'number'
      THEN (r.trace_summary ->> 'prompt_prefix_tokens')::bigint
    ELSE NULL
  END AS prompt_prefix_tokens,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'prompt_suffix_tokens') = 'number'
      THEN (r.trace_summary ->> 'prompt_suffix_tokens')::bigint
    ELSE NULL
  END AS prompt_suffix_tokens,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'prompt_prefix_reused_tokens') = 'number'
      THEN (r.trace_summary ->> 'prompt_prefix_reused_tokens')::bigint
    ELSE NULL
  END AS prompt_prefix_reused_tokens,
  r.trace_summary ->> 'prompt_prefix_reuse_status' AS prompt_prefix_reuse_status,
  r.trace_summary ->> 'prompt_prefix_reuse_reason' AS prompt_prefix_reuse_reason,
  COALESCE(r.trace_summary ->> 'json_logit_mask_enabled', 'false')::boolean AS json_logit_mask_enabled,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'json_logit_mask_sampled_tokens') = 'number'
      THEN (r.trace_summary ->> 'json_logit_mask_sampled_tokens')::bigint
    ELSE NULL
  END AS json_logit_mask_sampled_tokens,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'json_logit_mask_candidates_checked') = 'number'
      THEN (r.trace_summary ->> 'json_logit_mask_candidates_checked')::bigint
    ELSE NULL
  END AS json_logit_mask_candidates_checked,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'json_logit_mask_candidates_rejected') = 'number'
      THEN (r.trace_summary ->> 'json_logit_mask_candidates_rejected')::bigint
    ELSE NULL
  END AS json_logit_mask_candidates_rejected,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'json_logit_mask_fallbacks') = 'number'
      THEN (r.trace_summary ->> 'json_logit_mask_fallbacks')::bigint
    ELSE NULL
  END AS json_logit_mask_fallbacks,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'json_logit_mask_uncertain_pieces') = 'number'
      THEN (r.trace_summary ->> 'json_logit_mask_uncertain_pieces')::bigint
    ELSE NULL
  END AS json_logit_mask_uncertain_pieces,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'json_logit_mask_overhead_ms') = 'number'
      THEN (r.trace_summary ->> 'json_logit_mask_overhead_ms')::bigint
    ELSE NULL
  END AS json_logit_mask_overhead_ms,
  COALESCE(r.trace_summary ->> 'json_logit_mask_enum_enabled', 'false')::boolean AS json_logit_mask_enum_enabled,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'json_logit_mask_enum_fields') = 'number'
      THEN (r.trace_summary ->> 'json_logit_mask_enum_fields')::bigint
    ELSE NULL
  END AS json_logit_mask_enum_fields,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'json_logit_mask_enum_values') = 'number'
      THEN (r.trace_summary ->> 'json_logit_mask_enum_values')::bigint
    ELSE NULL
  END AS json_logit_mask_enum_values,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'json_logit_mask_enum_candidates_rejected') = 'number'
      THEN (r.trace_summary ->> 'json_logit_mask_enum_candidates_rejected')::bigint
    ELSE NULL
  END AS json_logit_mask_enum_candidates_rejected,
  r.trace_summary ->> 'decode_constraint' AS decode_constraint,
  r.trace_summary ->> 'decode_constraint_reason' AS decode_constraint_reason,
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
  r.trace_summary ->> 'inference_cache_key_basis' AS inference_cache_key_basis,
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
    WHEN jsonb_typeof(r.trace_summary -> 'inference_cache_max_entries') = 'number'
      THEN (r.trace_summary ->> 'inference_cache_max_entries')::bigint
    ELSE NULL
  END AS inference_cache_max_entries,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'inference_cache_max_bytes') = 'number'
      THEN (r.trace_summary ->> 'inference_cache_max_bytes')::bigint
    ELSE NULL
  END AS inference_cache_max_bytes,
  CASE
    WHEN jsonb_typeof(r.trace_summary -> 'inference_cache_evictions') = 'number'
      THEN (r.trace_summary ->> 'inference_cache_evictions')::bigint
    ELSE NULL
  END AS inference_cache_evictions,
  r.trace_summary ->> 'inference_cache_eviction_reason' AS inference_cache_eviction_reason,
  r.trace_summary ->> 'inference_cache_invalidation_reason' AS inference_cache_reason,
  r.finished_at AS receipt_finished_at
FROM otlet.inference_receipts r
LEFT JOIN otlet.outputs o ON o.receipt_id = r.id
LEFT JOIN LATERAL (
  SELECT sm.freshness_basis
  FROM otlet.semantic_materializations sm
  JOIN otlet.records rec ON rec.id = sm.record_id
  JOIN otlet.actions a ON a.id = rec.action_id
  WHERE a.receipt_id = r.id
  ORDER BY sm.updated_at DESC, sm.id DESC
  LIMIT 1
) materialization ON true;

CREATE VIEW otlet.task_inference_cache_status AS
WITH receipt_cache AS (
  SELECT
    task_name,
    receipt_id,
    selection_status,
    inference_cache_hit,
    inference_cache_key_basis,
    inference_cache_reason,
    receipt_finished_at,
    (
      inference_cache_reason IS NOT NULL
      AND inference_cache_reason NOT IN ('disabled', 'disabled_for_generation_trace')
    ) AS cache_enabled
  FROM otlet.inference_receipt_trace_status
),
task_cache AS (
  SELECT
    task_name,
    count(*)::bigint AS receipt_count,
    count(*) FILTER (WHERE selection_status = 'accepted')::bigint AS accepted_receipts,
    count(*) FILTER (WHERE selection_status = 'rejected')::bigint AS rejected_receipts,
    count(*) FILTER (WHERE selection_status = 'failed')::bigint AS failed_receipts,
    count(*) FILTER (WHERE cache_enabled)::bigint AS cache_enabled_receipts,
    count(*) FILTER (WHERE inference_cache_hit)::bigint AS inference_cache_hits,
    count(*) FILTER (WHERE cache_enabled AND NOT inference_cache_hit)::bigint AS inference_cache_misses,
    count(*) FILTER (WHERE selection_status = 'accepted' AND inference_cache_hit)::bigint AS accepted_cache_hits,
    count(*) FILTER (WHERE selection_status = 'rejected' AND inference_cache_hit)::bigint AS rejected_cache_hits,
    count(*) FILTER (WHERE selection_status = 'failed' AND inference_cache_hit)::bigint AS failed_cache_hits,
    array_remove(array_agg(DISTINCT inference_cache_key_basis), NULL) AS key_basis_values,
    (array_agg(inference_cache_reason ORDER BY receipt_finished_at DESC, receipt_id DESC))[1] AS last_cache_reason
  FROM receipt_cache
  GROUP BY task_name
)
SELECT
  c.task_name,
  c.receipt_count,
  c.accepted_receipts,
  c.rejected_receipts,
  c.failed_receipts,
  c.cache_enabled_receipts,
  c.inference_cache_hits,
  c.inference_cache_misses,
  CASE
    WHEN c.cache_enabled_receipts > 0
      THEN c.inference_cache_hits::numeric / c.cache_enabled_receipts
    ELSE NULL
  END AS inference_cache_hit_rate,
  c.accepted_cache_hits,
  c.rejected_cache_hits,
  c.failed_cache_hits,
  to_jsonb(c.key_basis_values) AS inference_cache_key_bases,
  c.last_cache_reason,
  COALESCE(reasons.cache_reasons, '{}'::jsonb) AS cache_reasons
FROM task_cache c
LEFT JOIN LATERAL (
  SELECT jsonb_object_agg(reason, receipt_count ORDER BY reason) AS cache_reasons
  FROM (
    SELECT
      COALESCE(r.inference_cache_reason, 'unknown') AS reason,
      count(*)::bigint AS receipt_count
    FROM receipt_cache r
    WHERE r.task_name = c.task_name
    GROUP BY COALESCE(r.inference_cache_reason, 'unknown')
  ) reason_counts
) reasons ON true;
