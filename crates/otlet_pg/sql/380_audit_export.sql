-- Read-only operator export surfaces. These views withhold prompts, raw model
-- output, token steps, and full trace_summary payloads. See
-- otlet.redaction_policy_status for the active withheld-field contract.

CREATE VIEW otlet.redaction_policy_status AS
WITH policy AS (
  SELECT sensitive_evidence_mode, sensitive_evidence_retention
  FROM otlet.production_policy
  WHERE name = 'default'
),
observed AS (
  SELECT
    count(*) FILTER (WHERE r.raw_output IS NOT NULL)::bigint AS raw_output_rows,
    count(*) FILTER (
      WHERE r.trace_summary #>> '{detailed_trace,chosen_text}' IS NOT NULL
    )::bigint AS chosen_text_rows,
    COALESCE(sum(jsonb_array_length(jsonb_path_query_array(
      r.trace_summary,
      '$.detailed_trace.steps[*].token_text'
    ))), 0)::bigint AS token_text_values,
    COALESCE(sum(jsonb_array_length(jsonb_path_query_array(
      r.trace_summary,
      '$.detailed_trace.steps[*].top_alternatives[*].token_text'
    ))), 0)::bigint AS alternative_token_text_values,
    count(*) FILTER (
      WHERE (
        p.sensitive_evidence_mode = 'redacted'
        OR r.finished_at < now() - p.sensitive_evidence_retention
      )
      AND (
        r.raw_output IS NOT NULL
        OR r.trace_summary #>> '{detailed_trace,chosen_text}' IS NOT NULL
        OR jsonb_path_exists(r.trace_summary, '$.detailed_trace.steps[*].token_text')
        OR jsonb_path_exists(r.trace_summary, '$.detailed_trace.steps[*].top_alternatives[*].token_text')
      )
    )::bigint AS overdue_sensitive_rows,
    count(*) FILTER (
      WHERE r.trace_summary #> '{evidence_redaction,structured_output}' = 'true'::jsonb
    )::bigint AS structured_output_redacted_receipts,
    count(*) FILTER (
      WHERE r.trace_summary #> '{evidence_redaction,actions}' = 'true'::jsonb
    )::bigint AS action_redacted_receipts
  FROM otlet.inference_receipts r
  CROSS JOIN policy p
),
configured AS (
  SELECT
    count(*) FILTER (
      WHERE jsonb_array_length(COALESCE(t.decision_contract -> 'redact_output_fields', '[]'::jsonb)) > 0
    )::bigint AS structured_output_redaction_tasks,
    count(*) FILTER (
      WHERE jsonb_array_length(COALESCE(t.decision_contract -> 'redact_action_fields', '[]'::jsonb)) > 0
    )::bigint AS action_redaction_tasks
  FROM otlet.tasks t
)
SELECT
  'stored_sensitive_evidence'::text AS policy_name,
  2::integer AS policy_version,
  'hash_only'::text AS assembled_prompt_storage,
  p.sensitive_evidence_mode,
  p.sensitive_evidence_retention,
  (p.sensitive_evidence_mode = 'diagnostic') AS raw_output_allowed_at_write,
  (p.sensitive_evidence_mode = 'diagnostic') AS token_text_allowed_at_write,
  o.raw_output_rows,
  o.chosen_text_rows,
  o.token_text_values,
  o.alternative_token_text_values,
  o.overdue_sensitive_rows,
  c.structured_output_redaction_tasks,
  c.action_redaction_tasks,
  o.structured_output_redacted_receipts,
  o.action_redacted_receipts,
  (o.overdue_sensitive_rows = 0) AS storage_compliant,
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
    'otlet.audit_review_event_export',
    'otlet.audit_action_execution_export',
    'otlet.audit_eval_label_export',
    'otlet.audit_workload_evaluation_export',
    'otlet.action_workflow_policy_status',
    'otlet.cleanup_receipt_status',
    'otlet.retention_hold_status',
    'otlet.retention_copy_status',
    'otlet.semantic_dependency_audit',
    'otlet.operational_event_log',
    'otlet.worker_batch_timing_status',
    'otlet.access_policy_status'
  ]::text[] AS export_views,
  'Assembled prompts are hash-only. Audit exports omit job input, raw output, candidate output, token detail, and full trace summaries. Task configuration and active job input remain owner-only.'::text AS notes
FROM policy p
CROSS JOIN observed o
CROSS JOIN configured c;

CREATE VIEW otlet.operational_event_log AS
SELECT
  e.id AS event_id,
  e.created_at,
  e.event_type,
  e.job_id,
  e.runtime_name,
  e.detail ->> 'task_name' AS task_name,
  e.detail -> 'task_names' AS task_names,
  e.detail ->> 'model_name' AS model_name,
  e.detail ->> 'reason' AS reason,
  e.detail ->> 'status' AS status,
  CASE WHEN jsonb_typeof(e.detail -> 'job_count') = 'number' THEN (e.detail ->> 'job_count')::bigint END AS job_count,
  CASE WHEN jsonb_typeof(e.detail -> 'completed_jobs') = 'number' THEN (e.detail ->> 'completed_jobs')::bigint END AS completed_jobs,
  CASE WHEN jsonb_typeof(e.detail -> 'failed_jobs') = 'number' THEN (e.detail ->> 'failed_jobs')::bigint END AS failed_jobs,
  CASE WHEN jsonb_typeof(e.detail -> 'batch_ms') = 'number' THEN (e.detail ->> 'batch_ms')::bigint END AS batch_ms,
  CASE WHEN jsonb_typeof(e.detail -> 'input_bytes') = 'number' THEN (e.detail ->> 'input_bytes')::bigint END AS input_bytes,
  CASE WHEN jsonb_typeof(e.detail -> 'limit_bytes') = 'number' THEN (e.detail ->> 'limit_bytes')::bigint END AS limit_bytes,
  (e.detail::text LIKE '%[REDACTED]%') AS evidence_redacted
FROM otlet.worker_events e;

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
  s.model_artifact_hash AS model_artifact_sha256,
  s.model_artifact_identity,
  s.runtime_name,
  s.prompt_hash,
  s.prompt_tokens,
  s.generated_tokens,
  s.generate_ms,
  s.tokens_per_second,
  s.runtime_prepare_ms,
  s.model_load_ms,
  s.model_context_ms,
  s.tokenize_ms,
  s.prompt_decode_ms,
  s.postprocess_ms,
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
  (r.trace_summary #> '{evidence_redaction,structured_output}' = 'true'::jsonb) AS structured_output_redacted,
  CASE
    WHEN jsonb_typeof(r.trace_summary #> '{evidence_redaction,structured_output_field_count}') = 'number'
    THEN (r.trace_summary #>> '{evidence_redaction,structured_output_field_count}')::integer
    ELSE 0
  END AS structured_output_redacted_field_count,
  (r.trace_summary #> '{evidence_redaction,actions}' = 'true'::jsonb) AS actions_redacted,
  CASE
    WHEN jsonb_typeof(r.trace_summary #> '{evidence_redaction,action_field_count}') = 'number'
    THEN (r.trace_summary #>> '{evidence_redaction,action_field_count}')::integer
    ELSE 0
  END AS action_redacted_field_count,
  s.receipt_finished_at
FROM otlet.inference_receipt_trace_status s
JOIN otlet.inference_receipts r ON r.id = s.receipt_id;

CREATE VIEW otlet.audit_review_export AS
SELECT
  q.queue_kind,
  q.next_operator_step,
  q.task_name,
  q.watch_name,
  q.job_subject_id,
  q.subject_id,
  q.action_id,
  q.output_id,
  q.receipt_id,
  q.action_type,
  a.authority_origin,
  a.authority_mode,
  a.evaluation_status,
  a.authority_policy_hash,
  a.subject_namespace,
  a.target_name,
  q.action_status,
  q.approval_status,
  q.dry_run_status,
  q.apply_status,
  md5(q.idempotency_key) AS idempotency_key_hash,
  q.execution_receipt_id,
  q.execution_mode,
  q.execution_status,
  q.execution_affected_rows,
  q.execution_before_hash,
  q.execution_result_hash,
  q.execution_error,
  q.review_reason,
  q.source_table,
  q.source_hash,
  q.content_hash,
  q.current_content_hash,
  q.source_stale,
  q.created_at
FROM otlet.review_queue q
LEFT JOIN otlet.actions a ON a.id = q.action_id;

CREATE VIEW otlet.audit_review_event_export AS
SELECT
  id AS review_event_id,
  outcome,
  reviewer_identity,
  reviewer_role,
  reason,
  job_id,
  task_name,
  subject_id,
  action_id,
  output_id,
  receipt_id,
  source_table,
  source_hash,
  content_hash,
  current_content_hash,
  source_freshness,
  model_name,
  model_artifact_hash,
  prompt_hash,
  output_schema_hash,
  output_hash,
  runtime_fingerprint_hash,
  reviewed_at
FROM otlet.review_events;

CREATE VIEW otlet.audit_action_execution_export AS
SELECT
  er.id AS execution_receipt_id,
  er.action_id,
  a.job_id,
  a.receipt_id AS inference_receipt_id,
  j.task_name,
  a.subject_id,
  a.action_type,
  a.authority_origin,
  a.authority_mode,
  a.evaluation_status,
  a.authority_policy_hash,
  a.subject_namespace,
  a.status AS action_status,
  a.approval_status,
  a.dry_run_status,
  a.apply_status,
  md5(er.idempotency_key) AS idempotency_key_hash,
  er.mode,
  er.status,
  er.target_name,
  er.target_table,
  er.identity_hash,
  er.changed_columns,
  er.affected_rows,
  er.before_hash,
  er.result_hash,
  er.error,
  er.replay_of_receipt_id,
  er.created_at
FROM otlet.action_execution_receipts er
JOIN otlet.actions a ON a.id = er.action_id
JOIN otlet.jobs j ON j.id = a.job_id;

CREATE VIEW otlet.audit_eval_label_export AS
SELECT
  l.label_id,
  l.action_id,
  l.output_id,
  l.receipt_id,
  l.workload_name,
  l.case_key,
  l.case_weight,
  l.task_name,
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

CREATE VIEW otlet.audit_workload_evaluation_export AS
SELECT *
FROM otlet.workload_evaluation_status;

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
  COALESCE(
    e.detail -> 'task_names',
    jsonb_build_array(COALESCE(e.detail ->> 'task_name', ''))
  ) AS task_names,
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
