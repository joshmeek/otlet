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
  r.candidate_output,
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
  latest.candidate_output,
  COALESCE(o.output, latest.candidate_output) AS diagnostic_output,
  COALESCE(accepted.raw_output, latest.raw_output) AS raw_output,
  COALESCE(accepted.id, latest.id) AS receipt_id,
  accepted.id AS accepted_receipt_id,
  COALESCE(accepted.model_name, latest.model_name) AS model_name,
  accepted.model_name AS accepted_model_name,
  COALESCE(accepted.runtime_name, latest.runtime_name) AS runtime_name,
  COALESCE(accepted.prompt_hash, latest.prompt_hash) AS prompt_hash,
  COALESCE(accepted.input_hash, latest.input_hash) AS input_hash,
  COALESCE(accepted.output_schema_hash, latest.output_schema_hash) AS output_schema_hash,
  COALESCE(accepted.raw_output_hash, latest.raw_output_hash) AS raw_output_hash,
  COALESCE(accepted.prompt_tokens, latest.prompt_tokens) AS prompt_tokens,
  COALESCE(accepted.generated_tokens, latest.generated_tokens) AS generated_tokens,
  COALESCE(accepted.generate_ms, latest.generate_ms) AS generate_ms,
  COALESCE(accepted.tokens_per_second, latest.tokens_per_second) AS tokens_per_second,
  COALESCE(accepted.schema_validation_status, latest.schema_validation_status) AS schema_validation_status,
  COALESCE(accepted.trace_summary, latest.trace_summary) AS trace_summary,
  COALESCE(accepted.selection_role, latest.selection_role) AS model_selection_role,
  COALESCE(accepted.selection_status, latest.selection_status) AS model_selection_status,
  COALESCE(accepted.selection_reason, latest.selection_reason) AS model_selection_reason,
  COALESCE(attempts.model_attempt_count, 0)::bigint AS model_attempt_count,
  COALESCE(attempts.escalated, false) AS escalated,
  j.created_at AS job_created_at,
  o.created_at AS output_created_at,
  accepted.finished_at AS receipt_finished_at
FROM otlet.jobs j
LEFT JOIN receipt_attempts attempts ON attempts.job_id = j.id
LEFT JOIN otlet.outputs o ON o.job_id = j.id
LEFT JOIN otlet.inference_receipts accepted ON accepted.id = o.receipt_id
LEFT JOIN LATERAL (
  SELECT r.*
  FROM otlet.inference_receipts r
  WHERE r.job_id = j.id
  ORDER BY r.attempt_index DESC, r.id DESC
  LIMIT 1
) latest ON true;

CREATE VIEW otlet.action_status AS
SELECT
  a.id AS action_id,
  a.job_id,
  j.task_name,
  j.subject_id AS job_subject_id,
  a.subject_id,
  a.action_type,
  a.authority_origin,
  a.authority_mode,
  a.evaluation_status,
  a.authority_policy_hash,
  a.subject_namespace,
  a.status,
  a.approval_status,
  a.dry_run_status,
  a.apply_status,
  a.target_name,
  a.idempotency_key,
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
  a.applied_at,
  execution.id AS execution_receipt_id,
  execution.mode AS execution_mode,
  execution.status AS execution_status,
  execution.affected_rows AS execution_affected_rows,
  execution.before_hash AS execution_before_hash,
  execution.result_hash AS execution_result_hash,
  execution.error AS execution_error,
  execution.replay_of_receipt_id
FROM otlet.actions a
JOIN otlet.jobs j ON j.id = a.job_id
LEFT JOIN otlet.outputs o ON o.id = a.output_id
LEFT JOIN otlet.inference_receipts r ON r.id = a.receipt_id
LEFT JOIN LATERAL (
  SELECT er.*
  FROM otlet.action_execution_receipts er
  WHERE er.action_id = a.id
  ORDER BY er.created_at DESC, er.id DESC
  LIMIT 1
) execution ON true;

CREATE VIEW otlet.action_workflow_policy_status AS
SELECT
  p.task_name,
  p.action_type,
  p.target_name,
  p.subject_namespace,
  p.authority_mode,
  p.evaluation_status,
  p.policy_hash,
  p.task_contract_hash,
  p.target_contract_hash,
  p.enabled,
  p.task_contract_hash IS NOT DISTINCT FROM otlet.current_task_contract_hash(p.task_name)
    AS task_contract_current,
  p.target_contract_hash IS NOT DISTINCT FROM otlet.action_target_contract_hash(p.target_name)
    AS target_contract_current,
  otlet.action_target_validation_error(p.target_name) AS target_error,
  p.enabled
    AND p.authority_mode = 'bounded_mutation'
    AND p.evaluation_status = 'evaluated'
    AND p.task_contract_hash IS NOT DISTINCT FROM otlet.current_task_contract_hash(p.task_name)
    AND p.target_contract_hash IS NOT DISTINCT FROM otlet.action_target_contract_hash(p.target_name)
    AND otlet.action_target_validation_error(p.target_name) IS NULL
    AS mutation_authorized,
  p.created_at,
  p.updated_at
FROM otlet.action_workflow_policies p;

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
      WHEN a.action_type = 'update_row' AND a.dry_run_status = 'not_run' THEN 'pending_dry_run'
      WHEN a.approval_status = 'required' AND a.status = 'proposed' THEN 'pending_approval'
      WHEN a.action_type = 'update_row' AND a.status = 'approved' THEN 'ready_to_apply'
      ELSE 'review_flag'
    END AS queue_kind,
    CASE
      WHEN a.action_type = 'update_row' AND a.dry_run_status = 'not_run' THEN 'dry_run'
      WHEN a.action_type = 'update_row' AND a.dry_run_status = 'failed' THEN 'review_failure'
      WHEN a.action_type = 'update_row' AND a.status = 'proposed' THEN 'approve'
      WHEN a.action_type = 'update_row' AND a.status = 'approved' THEN 'apply'
      WHEN a.approval_status = 'required' AND a.status = 'proposed' THEN 'approve'
      ELSE 'review'
    END AS next_operator_step,
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
    a.dry_run_status,
    a.apply_status,
    a.idempotency_key,
    execution.id AS execution_receipt_id,
    execution.mode AS execution_mode,
    execution.status AS execution_status,
    execution.affected_rows AS execution_affected_rows,
    execution.before_hash AS execution_before_hash,
    execution.result_hash AS execution_result_hash,
    execution.error AS execution_error,
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
    SELECT er.*
    FROM otlet.action_execution_receipts er
    WHERE er.action_id = a.id
    ORDER BY er.created_at DESC, er.id DESC
    LIMIT 1
  ) execution ON true
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
      OR (
        a.action_type = 'update_row'
        AND a.status = 'approved'
        AND a.apply_status NOT IN ('applied', 'replayed')
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
    'review'::text AS next_operator_step,
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
    NULL::text AS dry_run_status,
    NULL::text AS apply_status,
    NULL::text AS idempotency_key,
    NULL::bigint AS execution_receipt_id,
    NULL::text AS execution_mode,
    NULL::text AS execution_status,
    NULL::bigint AS execution_affected_rows,
    NULL::text AS execution_before_hash,
    NULL::text AS execution_result_hash,
    NULL::text AS execution_error,
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
    'review'::text AS next_operator_step,
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
    NULL::text AS dry_run_status,
    NULL::text AS apply_status,
    NULL::text AS idempotency_key,
    NULL::bigint AS execution_receipt_id,
    NULL::text AS execution_mode,
    NULL::text AS execution_status,
    NULL::bigint AS execution_affected_rows,
    NULL::text AS execution_before_hash,
    NULL::text AS execution_result_hash,
    NULL::text AS execution_error,
    NULL::text AS review_reason,
    r.candidate_output AS output,
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
    AND r.candidate_output IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.eval_labels l
      WHERE l.receipt_id = r.id
        AND l.label_source = 'manual_correction'
    )
)
SELECT
  queue_kind,
  next_operator_step,
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
  dry_run_status,
  apply_status,
  idempotency_key,
  execution_receipt_id,
  execution_mode,
  execution_status,
  execution_affected_rows,
  execution_before_hash,
  execution_result_hash,
  execution_error,
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
  next_operator_step,
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
  dry_run_status,
  apply_status,
  idempotency_key,
  execution_receipt_id,
  execution_mode,
  execution_status,
  execution_affected_rows,
  execution_before_hash,
  execution_result_hash,
  execution_error,
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
  next_operator_step,
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
  dry_run_status,
  apply_status,
  idempotency_key,
  execution_receipt_id,
  execution_mode,
  execution_status,
  execution_affected_rows,
  execution_before_hash,
  execution_result_hash,
  execution_error,
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
