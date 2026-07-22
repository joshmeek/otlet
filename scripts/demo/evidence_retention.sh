log "Proving evidence retention and deletion controls"

retention_contract="$(psql_value -v model_name="$strong_model_name" <<'SQL'
BEGIN;

UPDATE otlet.production_policy
SET terminal_evidence_retention = interval '100 years',
    worker_event_retention = interval '1000 years',
    trace_detail_retention = interval '1000 years',
    eval_label_retention = interval '1000 years',
    delete_stale_materialization_retention = interval '1000 years',
    sensitive_evidence_mode = 'diagnostic',
    sensitive_evidence_retention = interval '1000 years',
    failed_job_retention = interval '100 years'
WHERE name = 'default';

SELECT (otlet.create_task(
  'retention_canary_task',
  NULL,
  'Retention canary task',
  '{"type":"object"}'::jsonb,
  :'model_name',
  '{}'::jsonb,
  '{"source_fields":["secret"]}'::jsonb
)).name AS name \gset task_

CREATE TEMP TABLE retention_canary_job AS
WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    subject_id,
    input,
    status,
    attempts,
    error,
    created_at,
    started_at,
    finished_at
  )
  VALUES (
    'retention_canary_task',
    'RETENTION-CANARY-SUBJECT',
    '{"secret":"RETENTION-CANARY-INPUT"}'::jsonb,
    'complete',
    1,
    'RETENTION-CANARY-JOB-ERROR',
    now() - interval '200 years',
    now() - interval '200 years',
    now() - interval '200 years'
  )
  RETURNING id
)
SELECT id FROM inserted;

CREATE TEMP TABLE retention_other_terminal_jobs AS
WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    subject_id,
    input,
    status,
    error,
    created_at,
    finished_at
  )
  VALUES
    (
      'retention_canary_task',
      'RETENTION-CANARY-FAILED',
      '{"secret":"RETENTION-CANARY-FAILED-INPUT"}'::jsonb,
      'failed',
      'RETENTION-CANARY-FAILED-ERROR',
      now() - interval '200 years',
      now() - interval '200 years'
    ),
    (
      'retention_canary_task',
      'RETENTION-CANARY-CANCELED',
      '{"secret":"RETENTION-CANARY-CANCELED-INPUT"}'::jsonb,
      'canceled',
      'RETENTION-CANARY-CANCELED-ERROR',
      now() - interval '200 years',
      now() - interval '200 years'
    )
  RETURNING id, status
)
SELECT * FROM inserted;

CREATE TEMP TABLE retention_canary_receipt AS
WITH inserted AS (
  INSERT INTO otlet.inference_receipts (
    job_id,
    attempt_index,
    selection_role,
    selection_status,
    task_name,
    subject_id,
    model_name,
    model_artifact_path,
    model_artifact_hash,
    model_artifact_identity,
    runtime_name,
    runtime_endpoint,
    runtime_options,
    prompt_hash,
    input_hash,
    output_schema_hash,
    raw_output_hash,
    raw_output,
    candidate_output,
    schema_validation_status,
    trace_summary,
    started_at,
    finished_at,
    status,
    error
  )
  SELECT
    job.id,
    1,
    'direct',
    'accepted',
    'retention_canary_task',
    'RETENTION-CANARY-SUBJECT',
    model.name,
    model.artifact_path,
    model.artifact_hash,
    model.artifact_identity,
    'linked_inproc',
    'local',
    '{}'::jsonb,
    md5('RETENTION-CANARY-PROMPT'),
    md5('RETENTION-CANARY-INPUT'),
    md5('{}'),
    md5('RETENTION-CANARY-RAW'),
    'RETENTION-CANARY-RAW',
    '{"secret":"RETENTION-CANARY-CANDIDATE"}'::jsonb,
    'passed',
    '{"secret":"RETENTION-CANARY-TRACE"}'::jsonb,
    now() - interval '200 years',
    now() - interval '200 years',
    'complete',
    'RETENTION-CANARY-RECEIPT-ERROR'
  FROM retention_canary_job job
  JOIN otlet.models model ON model.name = :'model_name'
  RETURNING id, job_id
)
SELECT * FROM inserted;

CREATE TEMP TABLE retention_canary_output AS
WITH inserted AS (
  INSERT INTO otlet.outputs (job_id, receipt_id, output, created_at)
  SELECT
    receipt.job_id,
    receipt.id,
    '{"secret":"RETENTION-CANARY-OUTPUT"}'::jsonb,
    now() - interval '200 years'
  FROM retention_canary_receipt receipt
  RETURNING id, job_id, receipt_id
)
SELECT * FROM inserted;

CREATE TEMP TABLE retention_canary_action AS
WITH inserted AS (
  INSERT INTO otlet.actions (
    job_id,
    output_id,
    receipt_id,
    action_type,
    authority_origin,
    authority_mode,
    evaluation_status,
    authority_policy_hash,
    subject_namespace,
    payload,
    status,
    subject_id,
    error,
    review_reason,
    created_at
  )
  SELECT
    output.job_id,
    output.id,
    output.receipt_id,
    'review_flag',
    'system',
    'recommendation_only',
    'unevaluated',
    otlet.default_action_authority_hash('retention_canary_task', 'review_flag'),
    'task:retention_canary_task',
    '{"type":"review_flag","body":{"secret":"RETENTION-CANARY-ACTION"}}'::jsonb,
    'complete',
    'RETENTION-CANARY-SUBJECT',
    'RETENTION-CANARY-ACTION-ERROR',
    'RETENTION-CANARY-REVIEW',
    now() - interval '200 years'
  FROM retention_canary_output output
  RETURNING id, output_id, receipt_id
)
SELECT * FROM inserted;

CREATE TEMP TABLE retention_canary_record AS
WITH inserted AS (
  INSERT INTO otlet.records (action_id, record_type, subject_id, body, created_at)
  SELECT
    action.id,
    'retention_canary',
    'RETENTION-CANARY-SUBJECT',
    '{"secret":"RETENTION-CANARY-RECORD"}'::jsonb,
    now() - interval '200 years'
  FROM retention_canary_action action
  RETURNING id, action_id
)
SELECT * FROM inserted;

INSERT INTO otlet.eval_labels (
  action_id,
  output_id,
  receipt_id,
  source_table,
  subject_id,
  source_hash,
  expected_answer,
  expected_confidence,
  expected_action_type,
  label_source,
  reason,
  created_at
)
SELECT
  action.id,
  action.output_id,
  action.receipt_id,
  'public.retention_canary',
  'RETENTION-CANARY-SUBJECT',
  md5('RETENTION-CANARY-SOURCE'),
  'RETENTION-CANARY-CORRECTION',
  'high',
  'review_flag',
  'manual_correction',
  'RETENTION-CANARY-LABEL',
  now() - interval '200 years'
FROM retention_canary_action action;

INSERT INTO otlet.semantic_materializations (
  record_id,
  record_type,
  source_table,
  subject_id,
  source_dependencies,
  task_name,
  model_name,
  body,
  source_hash,
  content_hash,
  contract_hash,
  created_at,
  updated_at
)
SELECT
  record.id,
  'retention_canary',
  'public.retention_canary',
  'RETENTION-CANARY-SUBJECT',
  '[{"secret":"RETENTION-CANARY-DEPENDENCY"}]'::jsonb,
  'retention_canary_task',
  :'model_name',
  '{"secret":"RETENTION-CANARY-MATERIALIZATION"}'::jsonb,
  md5('RETENTION-CANARY-SOURCE'),
  md5('RETENTION-CANARY-CONTENT'),
  md5('RETENTION-CANARY-CONTRACT'),
  now() - interval '200 years',
  now() - interval '200 years'
FROM retention_canary_record record;

INSERT INTO otlet.worker_events (event_type, job_id, message, detail, created_at)
SELECT
  'retention_canary',
  job.id,
  'RETENTION-CANARY-EVENT-MESSAGE',
  '{"secret":"RETENTION-CANARY-EVENT"}'::jsonb,
  now() - interval '200 years'
FROM retention_canary_job job;

SELECT id
FROM otlet.place_retention_hold(
  (SELECT id FROM retention_canary_job),
  'retention canary hold'
) \gset hold_

SELECT terminal_jobs
FROM otlet.cleanup_policy_state(true) \gset held_

SELECT id
FROM otlet.release_retention_hold(:hold_id, 'retention canary release') \gset released_

SELECT
  terminal_jobs,
  terminal_job_inputs,
  terminal_outputs,
  terminal_actions,
  terminal_corrections,
  terminal_receipt_payloads,
  terminal_events,
  terminal_records,
  terminal_materializations,
  failed_canceled_jobs
FROM otlet.cleanup_policy_state(true) \gset dry_

SELECT pg_current_wal_insert_lsn()::text AS lsn \gset wal_before_

SELECT
  terminal_jobs,
  terminal_job_inputs,
  terminal_outputs,
  terminal_actions,
  terminal_corrections,
  terminal_receipt_payloads,
  terminal_events,
  terminal_records,
  terminal_materializations,
  failed_canceled_jobs,
  cleanup_run_id
FROM otlet.cleanup_policy_state(false) \gset applied_

SELECT pg_current_wal_insert_lsn()::text AS lsn \gset wal_after_

SELECT
  (:'held_terminal_jobs' = '2')::text || '|' ||
  (
    :'dry_terminal_jobs' = '3'
    AND :'dry_terminal_job_inputs' = '3'
    AND :'dry_terminal_outputs' = '1'
    AND :'dry_terminal_actions' = '1'
    AND :'dry_terminal_corrections' = '1'
    AND :'dry_terminal_receipt_payloads' = '1'
    AND :'dry_terminal_events' = '1'
    AND :'dry_terminal_records' = '1'
    AND :'dry_terminal_materializations' = '1'
    AND :'dry_failed_canceled_jobs' = '2'
  )::text || '|' ||
  (
    :'applied_terminal_jobs' = '3'
    AND :'applied_failed_canceled_jobs' = '2'
    AND :'applied_cleanup_run_id' <> ''
  )::text || '|' ||
  (NOT EXISTS (
    SELECT 1
    FROM (
      SELECT to_jsonb(j) AS value FROM otlet.jobs j WHERE j.task_name = 'retention_canary_task'
      UNION ALL
      SELECT to_jsonb(r) FROM otlet.inference_receipts r WHERE r.job_id = (SELECT id FROM retention_canary_job)
      UNION ALL
      SELECT to_jsonb(o) FROM otlet.outputs o WHERE o.job_id = (SELECT id FROM retention_canary_job)
      UNION ALL
      SELECT to_jsonb(a) FROM otlet.actions a WHERE a.job_id = (SELECT id FROM retention_canary_job)
      UNION ALL
      SELECT to_jsonb(record) FROM otlet.records record JOIN retention_canary_action a ON a.id = record.action_id
      UNION ALL
      SELECT to_jsonb(l) FROM otlet.eval_labels l JOIN retention_canary_action a ON a.id = l.action_id
      UNION ALL
      SELECT to_jsonb(sm) FROM otlet.semantic_materializations sm JOIN retention_canary_record r ON r.id = sm.record_id
      UNION ALL
      SELECT to_jsonb(e) FROM otlet.worker_events e WHERE e.job_id = (SELECT id FROM retention_canary_job)
    ) active
    WHERE active.value::text LIKE '%RETENTION-CANARY%'
  ))::text || '|' ||
  EXISTS (
    SELECT 1
    FROM otlet.evidence_cleanup_receipts receipt
    WHERE receipt.job_id = (SELECT id FROM retention_canary_job)
      AND receipt.cleanup_run_id = :'applied_cleanup_run_id'::bigint
      AND receipt.subject_id_hash = md5('RETENTION-CANARY-SUBJECT')
      AND receipt.identity_hashes::text NOT LIKE '%RETENTION-CANARY%'
      AND (SELECT count(*) FROM jsonb_object_keys(receipt.identity_hashes)) = 9
      AND (SELECT count(*) FROM otlet.evidence_cleanup_receipts WHERE cleanup_run_id = receipt.cleanup_run_id) = 3
  )::text || '|' ||
  EXISTS (
    SELECT 1
    FROM otlet.retention_hold_status
    WHERE hold_id = :hold_id
      AND NOT active
      AND release_reason_hash = md5('retention canary release')
      AND held_by = session_user
      AND released_by = session_user
  )::text || '|' ||
  EXISTS (
    SELECT 1
    FROM otlet.cleanup_receipt_status
    WHERE cleanup_run_id = :'applied_cleanup_run_id'::bigint
      AND status = 'applied'
      AND job_receipts = 3
      AND family_counts ->> 'terminal_jobs' = '3'
  )::text || '|' ||
  EXISTS (
    SELECT 1
    FROM otlet.retention_copy_status
    WHERE active_table_payloads_covered
      AND active_table_storage_reclaim_requires_vacuum
      AND cleanup_generates_wal
      AND NOT prior_wal_copies_deleted
      AND NOT physical_backup_copies_deleted
      AND NOT restore_point_copies_deleted
      AND NOT point_in_time_recovery_copies_deleted
      AND :'wal_before_lsn' <> :'wal_after_lsn'
  )::text || '|' ||
  ((SELECT terminal_jobs FROM otlet.cleanup_policy_state(true)) = 0)::text;

ROLLBACK;
SQL
)"

echo "retention_contract=$retention_contract"
[ "$retention_contract" = "true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected holds, dry run, applied cleanup, hash receipts, active-state deletion, copy limits, and idempotence, got $retention_contract" >&2
  exit 1
}
