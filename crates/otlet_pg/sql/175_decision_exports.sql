CREATE VIEW otlet.decision_trace_export AS
WITH action_exports AS (
  SELECT
    a.receipt_id,
    jsonb_agg(
      jsonb_build_object(
        'action_id', a.id,
        'action_identity_sha256', encode(sha256(convert_to(
          otlet.semantic_canonical_jsonb(jsonb_build_object(
            'action_id', a.id,
            'job_id', a.job_id,
            'output_id', a.output_id,
            'receipt_id', a.receipt_id,
            'action_type', a.action_type,
            'authority_origin', a.authority_origin,
            'authority_mode', a.authority_mode,
            'evaluation_status', a.evaluation_status,
            'authority_policy_hash', a.authority_policy_hash,
            'subject_namespace', a.subject_namespace,
            'target_name', a.target_name,
            'payload_sha256', encode(sha256(convert_to(
              otlet.semantic_canonical_jsonb(a.payload)::text,
              'UTF8'
            )), 'hex'),
            'status', a.status,
            'approval_status', a.approval_status,
            'dry_run_status', a.dry_run_status,
            'apply_status', a.apply_status,
            'source_table', a.source_table,
            'subject_id', a.subject_id,
            'source_hash', a.source_hash,
            'content_hash', a.content_hash
          ))::text,
          'UTF8'
        )), 'hex'),
        'action_type', a.action_type,
        'authority_origin', a.authority_origin,
        'authority_mode', a.authority_mode,
        'evaluation_status', a.evaluation_status,
        'authority_policy_hash', a.authority_policy_hash,
        'subject_namespace', a.subject_namespace,
        'target_name', a.target_name,
        'payload_sha256', encode(sha256(convert_to(
          otlet.semantic_canonical_jsonb(a.payload)::text,
          'UTF8'
        )), 'hex'),
        'status', a.status,
        'approval_status', a.approval_status,
        'dry_run_status', a.dry_run_status,
        'apply_status', a.apply_status,
        'source_table', a.source_table,
        'subject_id', a.subject_id,
        'source_hash', a.source_hash,
        'content_hash', a.content_hash,
        'idempotency_key_sha256', CASE
          WHEN a.idempotency_key IS NULL THEN NULL
          ELSE encode(sha256(convert_to(a.idempotency_key, 'UTF8')), 'hex')
        END,
        'executions', COALESCE((
          SELECT jsonb_agg(
            jsonb_build_object(
              'execution_receipt_id', execution.id,
              'mode', execution.mode,
              'status', execution.status,
              'target_name', execution.target_name,
              'target_table', execution.target_table,
              'identity_hash', execution.identity_hash,
              'changed_columns', to_jsonb(execution.changed_columns),
              'affected_rows', execution.affected_rows,
              'before_hash', execution.before_hash,
              'result_hash', execution.result_hash,
              'replay_of_receipt_id', execution.replay_of_receipt_id,
              'created_at', to_char(
                execution.created_at AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
              )
            )
            ORDER BY execution.id
          )
          FROM otlet.action_execution_receipts execution
          WHERE execution.action_id = a.id
        ), '[]'::jsonb)
      )
      ORDER BY a.id
    ) AS actions
  FROM otlet.actions a
  WHERE a.receipt_id IS NOT NULL
  GROUP BY a.receipt_id
),
review_exports AS (
  SELECT
    review.receipt_id,
    jsonb_agg(
      jsonb_build_object(
        'review_event_id', review.id,
        'review_identity_sha256', encode(sha256(convert_to(
          otlet.semantic_canonical_jsonb(jsonb_build_object(
            'review_event_id', review.id,
            'outcome', review.outcome,
            'reviewer_identity', review.reviewer_identity,
            'reviewer_role', review.reviewer_role,
            'reason_sha256', encode(sha256(convert_to(review.reason, 'UTF8')), 'hex'),
            'job_id', review.job_id,
            'action_id', review.action_id,
            'output_id', review.output_id,
            'receipt_id', review.receipt_id,
            'source_hash', review.source_hash,
            'content_hash', review.content_hash,
            'current_content_hash', review.current_content_hash,
            'source_freshness', review.source_freshness,
            'reviewed_at', to_char(
              review.reviewed_at AT TIME ZONE 'UTC',
              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
            )
          ))::text,
          'UTF8'
        )), 'hex'),
        'outcome', review.outcome,
        'reviewer_identity', review.reviewer_identity,
        'reviewer_role', review.reviewer_role,
        'reason_sha256', encode(sha256(convert_to(review.reason, 'UTF8')), 'hex'),
        'action_id', review.action_id,
        'output_id', review.output_id,
        'source_table', review.source_table,
        'source_hash', review.source_hash,
        'content_hash', review.content_hash,
        'current_content_hash', review.current_content_hash,
        'source_freshness', review.source_freshness,
        'model_artifact_hash', review.model_artifact_hash,
        'prompt_hash', review.prompt_hash,
        'output_schema_hash', review.output_schema_hash,
        'output_hash', review.output_hash,
        'runtime_fingerprint_hash', review.runtime_fingerprint_hash,
        'reviewed_at', to_char(
          review.reviewed_at AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        )
      )
      ORDER BY review.id
    ) AS reviews
  FROM otlet.review_events review
  GROUP BY review.receipt_id
),
decision_traces AS (
  SELECT
    status.receipt_id,
    status.job_id,
    output.id AS output_id,
    status.task_name,
    status.subject_id,
    status.output_hash,
    status.actions_hash,
    otlet.semantic_canonical_jsonb(jsonb_build_object(
      'format', 'otlet.decision-trace.v1',
      'source', jsonb_build_object(
        'identity_hash', status.source_identity_hash,
        'subject_id', status.subject_id,
        'row_identity', status.row_identity
      ),
      'task', jsonb_build_object(
        'name', status.task_name,
        'identity_hash', status.task_identity_hash
      ),
      'model', jsonb_build_object(
        'name', status.model_name,
        'identity_hash', status.model_identity_hash,
        'artifact_sha256', status.model_artifact_hash,
        'artifact_identity', status.model_artifact_identity
      ),
      'prompt', jsonb_build_object(
        'sha256', status.prompt_hash,
        'input_hash', status.input_hash
      ),
      'schema', jsonb_build_object(
        'output_schema_hash', status.output_schema_hash,
        'validation_status', status.schema_validation_status
      ),
      'runtime', jsonb_build_object(
        'name', status.runtime_name,
        'options_hash', status.runtime_options_hash,
        'fingerprint_hash', status.runtime_fingerprint_hash,
        'output_contract_hash', status.runtime_output_contract_hash,
        'executor_origin', status.executor_origin,
        'executor_boundary', status.executor_boundary
      ),
      'output', jsonb_build_object(
        'output_id', output.id,
        'output_hash', status.output_hash,
        'actions_hash', status.actions_hash,
        'accepted', status.accepted
      ),
      'review', COALESCE(review.reviews, '[]'::jsonb),
      'action', COALESCE(action.actions, '[]'::jsonb),
      'freshness', jsonb_build_object(
        'basis', status.freshness_basis,
        'row_identity', status.row_identity,
        'reviews', COALESCE(review.reviews, '[]'::jsonb)
      ),
      'receipt', jsonb_build_object(
        'receipt_id', status.receipt_id,
        'job_id', status.job_id,
        'attempt_index', status.attempt_index,
        'selection_role', status.selection_role,
        'selection_status', status.selection_status,
        'selection_reason', status.selection_reason,
        'status', status.status,
        'trace_version', status.trace_version,
        'finished_at', to_char(
          status.receipt_finished_at AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        )
      )
    )) AS decision_trace
  FROM otlet.inference_receipt_trace_status status
  JOIN otlet.outputs output ON output.receipt_id = status.receipt_id
  LEFT JOIN action_exports action ON action.receipt_id = status.receipt_id
  LEFT JOIN review_exports review ON review.receipt_id = status.receipt_id
  WHERE status.accepted
    AND status.status = 'complete'
    AND status.schema_validation_status = 'passed'
),
hashed_traces AS (
  SELECT
    trace.*,
    encode(sha256(convert_to(trace.decision_trace::text, 'UTF8')), 'hex') AS decision_trace_sha256
  FROM decision_traces trace
),
recommendations AS (
  SELECT
    trace.*,
    'sha256:' || trace.decision_trace_sha256 AS recommendation_id,
    otlet.semantic_canonical_jsonb(jsonb_build_object(
      'format', 'otlet.recommendation.v1',
      'recommendation_id', 'sha256:' || trace.decision_trace_sha256,
      'receipt_id', trace.receipt_id,
      'job_id', trace.job_id,
      'output_id', trace.output_id,
      'task_name', trace.task_name,
      'subject_id', trace.subject_id,
      'decision_trace_sha256', trace.decision_trace_sha256,
      'output_hash', trace.output_hash,
      'actions_hash', trace.actions_hash
    )) AS recommendation
  FROM hashed_traces trace
)
SELECT
  recommendation.receipt_id,
  recommendation.job_id,
  recommendation.output_id,
  recommendation.task_name,
  recommendation.subject_id,
  recommendation.recommendation_id,
  recommendation.decision_trace_sha256,
  recommendation.decision_trace,
  recommendation.recommendation
FROM recommendations recommendation;
