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
WITH receipt_attempts AS (
  SELECT
    job_id,
    count(*)::bigint AS model_attempt_count,
    bool_or(selection_role = 'strong') AS escalated
  FROM otlet.inference_receipts
  GROUP BY job_id
)
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
  COALESCE(o.raw_output, accepted.raw_output, j.raw_output) AS raw_output,
  accepted.id AS receipt_id,
  accepted.id AS accepted_receipt_id,
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
  o.created_at AS output_created_at,
  accepted.finished_at AS receipt_finished_at
FROM otlet.jobs j
LEFT JOIN receipt_attempts attempts ON attempts.job_id = j.id
LEFT JOIN otlet.outputs o ON o.job_id = j.id
LEFT JOIN otlet.inference_receipts accepted ON accepted.id = o.receipt_id;

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
      AND (w.record_type IS NULL OR sm.record_type = w.record_type)
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
    hashed.content_hash,
    COALESCE(materialization.content_hash, hashed.content_hash) AS current_content_hash,
    (
      COALESCE(materialization.stale, false)
      OR (
        materialization.content_hash IS NOT NULL
        AND materialization.content_hash IS DISTINCT FROM hashed.content_hash
      )
    ) AS source_stale,
    o.created_at
  FROM otlet.outputs o
  JOIN otlet.jobs j ON j.id = o.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
  JOIN otlet.inference_receipts r ON r.id = o.receipt_id
  LEFT JOIN otlet.watches w ON w.task_name = j.task_name
  CROSS JOIN LATERAL (
    SELECT otlet.semantic_content_hash(j.input, t.input_shaping) AS content_hash
  ) hashed
  LEFT JOIN LATERAL (
    SELECT sm.content_hash, sm.stale
    FROM otlet.semantic_materializations sm
    WHERE sm.task_name = j.task_name
      AND sm.subject_id = j.subject_id
      AND (w.record_type IS NULL OR sm.record_type = w.record_type)
    ORDER BY sm.updated_at DESC, sm.id DESC
    LIMIT 1
  ) materialization ON true
  WHERE COALESCE(t.decision_contract -> 'abstain_values', '["unclear"]'::jsonb)
      ? (o.output ->> COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match'))
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
    hashed.content_hash,
    COALESCE(materialization.content_hash, hashed.content_hash) AS current_content_hash,
    (
      COALESCE(materialization.stale, false)
      OR (
        materialization.content_hash IS NOT NULL
        AND materialization.content_hash IS DISTINCT FROM hashed.content_hash
      )
    ) AS source_stale,
    r.finished_at AS created_at
  FROM otlet.inference_receipts r
  JOIN otlet.jobs j ON j.id = r.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
  LEFT JOIN otlet.watches w ON w.task_name = j.task_name
  CROSS JOIN LATERAL (
    SELECT otlet.semantic_content_hash(j.input, t.input_shaping) AS content_hash
  ) hashed
  LEFT JOIN LATERAL (
    SELECT sm.content_hash, sm.stale
    FROM otlet.semantic_materializations sm
    WHERE sm.task_name = j.task_name
      AND sm.subject_id = j.subject_id
      AND (w.record_type IS NULL OR sm.record_type = w.record_type)
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
    WHEN jsonb_typeof(trace.summary -> 'worker_process_rss_bytes') = 'number'
      THEN (trace.summary ->> 'worker_process_rss_bytes')::bigint
    ELSE NULL
  END AS worker_process_rss_bytes,
  CASE
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

CREATE VIEW otlet.task_inference_cache_status AS
WITH receipt_cache AS MATERIALIZED (
  SELECT
    task_name,
    id AS receipt_id,
    selection_status,
    COALESCE(trace.summary ->> 'inference_cache_hit', 'false')::boolean AS inference_cache_hit,
    COALESCE(
      trace.summary #>> '{cache,key_basis}',
      trace.summary ->> 'inference_cache_key_basis'
    ) AS inference_cache_key_basis,
    COALESCE(
      trace.summary #>> '{cache,invalidation_reason}',
      trace.summary ->> 'inference_cache_invalidation_reason'
    ) AS inference_cache_reason,
    finished_at AS receipt_finished_at,
    (
      COALESCE(
        trace.summary #>> '{cache,invalidation_reason}',
        trace.summary ->> 'inference_cache_invalidation_reason'
      ) IS NOT NULL
      AND COALESCE(
        trace.summary #>> '{cache,invalidation_reason}',
        trace.summary ->> 'inference_cache_invalidation_reason'
      ) NOT IN ('disabled', 'disabled_for_generation_trace')
    ) AS cache_enabled
  FROM otlet.inference_receipts r
  CROSS JOIN LATERAL (
    -- Expand the toasted object once and keep the projection from being pulled up
    SELECT r.trace_summary || '{}'::jsonb AS summary
    OFFSET 0
  ) trace
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
    array_remove(array_agg(DISTINCT inference_cache_key_basis), NULL) AS key_basis_values
  FROM receipt_cache
  GROUP BY task_name
),
latest_cache AS (
  SELECT DISTINCT ON (task_name)
    task_name,
    inference_cache_reason AS last_cache_reason
  FROM receipt_cache
  ORDER BY task_name, receipt_finished_at DESC, receipt_id DESC
),
reason_counts AS (
  SELECT
    task_name,
    COALESCE(inference_cache_reason, 'unknown') AS reason,
    count(*)::bigint AS receipt_count
  FROM receipt_cache
  GROUP BY task_name, COALESCE(inference_cache_reason, 'unknown')
),
task_reasons AS (
  SELECT
    task_name,
    jsonb_object_agg(reason, receipt_count ORDER BY reason) AS cache_reasons
  FROM reason_counts
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
  latest.last_cache_reason,
  COALESCE(reasons.cache_reasons, '{}'::jsonb) AS cache_reasons
FROM task_cache c
LEFT JOIN latest_cache latest USING (task_name)
LEFT JOIN task_reasons reasons USING (task_name);
