-- Read-only operator export surfaces. These views withhold prompts, raw model
-- output, token steps, and full trace_summary payloads. See
-- otlet.redaction_policy_status for the active withheld-field contract.

CREATE VIEW otlet.redaction_policy_status AS
SELECT
  'default_withhold_sensitive'::text AS policy_name,
  1::integer AS policy_version,
  false AS prompts_visible,
  false AS raw_output_visible,
  false AS token_steps_visible,
  false AS source_row_visible,
  ARRAY[
    'prompt',
    'raw_output',
    'token_steps',
    'top_k_alternatives',
    'source_row',
    'trace_summary'
  ]::text[] AS withheld_fields,
  ARRAY[
    'otlet.audit_receipt_export',
    'otlet.audit_review_export',
    'otlet.audit_eval_label_export',
    'otlet.semantic_dependency_audit',
    'otlet.worker_batch_timing_status'
  ]::text[] AS export_views,
  'Audit export views omit prompts, raw_output, token detail, and full trace_summary. Use inference_receipt_trace_status only when those fields are required.'::text AS notes;

CREATE VIEW otlet.audit_receipt_export AS
SELECT
  s.receipt_id,
  s.job_id,
  s.task_name,
  s.subject_id,
  s.attempt_index,
  s.selection_role,
  s.selection_status,
  s.selection_reason,
  s.accepted,
  s.status,
  s.model_name,
  s.runtime_name,
  s.prompt_hash,
  s.prompt_tokens,
  s.generated_tokens,
  s.generate_ms,
  s.tokens_per_second,
  s.tokenize_ms,
  s.prompt_decode_ms,
  s.first_token_ms,
  s.ttft_ms,
  s.finish_sql_ms,
  s.materialize_ms,
  s.schema_validation_status,
  s.trace_version,
  s.decision_preset_name,
  s.decision_preset_contract_hash,
  s.executor_origin,
  s.executor_node,
  s.executor_boundary,
  s.planner_selected_path,
  s.freshness_basis,
  s.worker_handoff,
  s.stale_policy,
  s.stop_reason,
  s.schema_force,
  s.decode_constraint,
  s.trace_output_schema_hash,
  s.receipt_output_schema_hash,
  s.trace_raw_output_hash,
  s.receipt_raw_output_hash,
  s.model_cache_hit,
  s.inference_cache_hit,
  s.inference_cache_key_basis,
  s.inference_cache_reason,
  s.inference_cache_eviction_reason,
  s.row_identity,
  s.shaped_input_bytes,
  s.input_truncated,
  s.input_shaping_applied,
  s.receipt_finished_at
FROM otlet.inference_receipt_trace_status s;

CREATE VIEW otlet.audit_review_export AS
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
  q.source_table,
  q.source_hash,
  q.content_hash,
  q.current_content_hash,
  q.source_stale,
  q.created_at
FROM otlet.review_queue q;

CREATE VIEW otlet.audit_eval_label_export AS
SELECT
  l.label_id,
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
  l.observed_action_type,
  l.action_status,
  l.approval_status,
  l.observed_answer,
  l.observed_confidence,
  l.model_name,
  l.selection_role,
  l.selection_status,
  l.created_at
FROM otlet.eval_label_status l;

CREATE VIEW otlet.semantic_dependency_audit AS
SELECT DISTINCT ON (sm.task_name, sm.record_type, sm.subject_id)
  sm.id AS materialization_id,
  sm.task_name,
  sm.record_type,
  sm.subject_id,
  sm.source_table,
  sm.source_hash,
  sm.content_hash,
  sm.contract_hash,
  sm.stale,
  sm.stale_reason,
  sm.freshness_basis,
  sm.source_dependencies,
  sm.model_name,
  sm.updated_at,
  sm.created_at
FROM otlet.semantic_materializations sm
ORDER BY sm.task_name, sm.record_type, sm.subject_id, sm.updated_at DESC, sm.id DESC;

CREATE VIEW otlet.worker_batch_timing_status AS
SELECT
  e.id AS event_id,
  e.created_at,
  COALESCE(e.detail ->> 'task_name', '') AS task_name,
  COALESCE(e.detail ->> 'model_name', '') AS model_name,
  COALESCE((e.detail ->> 'job_count')::bigint, 0) AS job_count,
  COALESCE((e.detail ->> 'completed_jobs')::bigint, 0) AS completed_jobs,
  COALESCE((e.detail ->> 'failed_jobs')::bigint, 0) AS failed_jobs,
  CASE
    WHEN jsonb_typeof(e.detail -> 'batch_ms') = 'number'
      THEN (e.detail ->> 'batch_ms')::bigint
    ELSE NULL
  END AS batch_ms,
  COALESCE((e.detail ->> 'model_swaps')::bigint, 0) AS model_swaps
FROM otlet.worker_events e
WHERE e.event_type = 'worker_batch_finished';
