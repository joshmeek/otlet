log "Checking complete evidence lifecycle"

complete_evidence_lifecycle_contract="$(psql_exec -qAt \
  -v model_name="$cheap_model_name" <<'SQL' | tail -n 1
BEGIN;
SET LOCAL statement_timeout = '5000ms';

CREATE FUNCTION pg_temp.assert_true(value boolean, message text) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF value IS DISTINCT FROM true THEN
    RAISE EXCEPTION '%', message;
  END IF;
END;
$$;

CREATE FUNCTION pg_temp.expect_error(statement text, message_fragment text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  BEGIN
    EXECUTE expect_error.statement;
  EXCEPTION WHEN OTHERS THEN
    IF NOT EXISTS (
      SELECT 1
      FROM unnest(string_to_array(expect_error.message_fragment, '|')) fragment
      WHERE position(fragment IN SQLERRM) > 0
    ) THEN
      RAISE EXCEPTION 'expected error containing %, got %',
        expect_error.message_fragment,
        SQLERRM;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'expected error containing %, but statement succeeded',
    expect_error.message_fragment;
END;
$$;

UPDATE otlet.production_policy
SET successful_job_retention = NULL,
    failed_job_retention = interval '1000 years',
    evidence_max_chain_rows = 1000,
    worker_event_retention = interval '100 years',
    trace_detail_retention = interval '100 years',
    eval_label_retention = interval '100 years',
    delete_stale_materialization_retention = interval '100 years',
    sensitive_evidence_mode = 'diagnostic',
    sensitive_evidence_retention = interval '100 years'
WHERE name = 'default';

CREATE TABLE public.complete_evidence_lifecycle_source (
  id text PRIMARY KEY,
  state text NOT NULL
);
INSERT INTO public.complete_evidence_lifecycle_source
VALUES ('lifecycle-subject', 'pending');
SELECT otlet.register_action_target(
  'complete_evidence_lifecycle_target',
  'public.complete_evidence_lifecycle_source'::regclass,
  'id',
  ARRAY['state']::name[]
) \g /dev/null
SELECT otlet.create_watch(
  watch_name => 'complete_evidence_lifecycle_watch',
  kind => 'row',
  instruction => 'Return one keep decision and one note',
  output_schema => '{
    "type":"object",
    "required":["decision","confidence"],
    "additionalProperties":false,
    "properties":{
      "decision":{"enum":["keep"]},
      "confidence":{"enum":["high"]}
    }
  }'::jsonb,
  model_name => :'model_name',
  table_name => 'public.complete_evidence_lifecycle_source'::regclass,
  subject_column => 'id',
  record_type => 'complete_evidence_lifecycle_record',
  action_types => ARRAY['note', 'update_row'],
  input_shaping => '{"strip_keys":["table"]}'::jsonb,
  input_columns => ARRAY['id', 'state'],
  decision_contract => '{
    "answer_field":"decision",
    "abstain_values":[],
    "confidence_field":"confidence",
    "accepted_confidence":["high"],
    "action_types":["note","update_row"]
  }'::jsonb
) \g /dev/null
SELECT otlet.register_action_workflow_policy(
  'complete_evidence_lifecycle_watch_task',
  'update_row',
  'complete_evidence_lifecycle_target',
  'bounded_mutation',
  'evaluated'
) \g /dev/null

CREATE TEMP TABLE lifecycle_acceptance AS
SELECT jsonb_object_agg(
  category,
  jsonb_build_object(
    'metric', category,
    'statistic', CASE
      WHEN category IN (
        'review_age', 'review_minutes', 'freshness', 'latency', 'recovery'
      ) THEN 'p95'
      ELSE 'rate'
    END,
    'operator', CASE
      WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 'gte'
      ELSE 'lte'
    END,
    'value', CASE
      WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 0.9
      ELSE 0.1
    END,
    'unit', 'ratio',
    'minimum_support', 1,
    'required', true
  )
) AS thresholds
FROM unnest(ARRAY[
  'candidate_recall',
  'false_trust',
  'abstention',
  'review_age',
  'review_minutes',
  'freshness',
  'latency',
  'database_impact',
  'unit_cost',
  'recovery',
  'downstream_outcome'
]) category;
SELECT otlet.ensure_active_workload_revision(
  'complete_evidence_lifecycle_watch_task'
) AS lifecycle_workload_revision_hash \gset
SELECT otlet.register_workload_acceptance_contract(
  'complete_evidence_lifecycle_watch_task',
  :'lifecycle_workload_revision_hash',
  :'lifecycle_workload_revision_hash',
  '{
    "mode":"sample",
    "rule":{
      "kind":"stable_hash",
      "basis":"receipt_id",
      "review_sampling":{
        "format":"otlet.review_sampling.v1",
        "task_rate":1
      }
    }
  }'::jsonb,
  clock_timestamp() + interval '100 milliseconds',
  clock_timestamp() + interval '1 hour',
  '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
  thresholds
) AS lifecycle_acceptance_contract_hash
FROM lifecycle_acceptance \gset
SELECT pg_sleep(0.15) \g /dev/null

INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input,
  status,
  attempts,
  created_at,
  started_at,
  leased_until,
  claim_token,
  job_origin
) SELECT
  'complete_evidence_lifecycle_watch_task',
  :'lifecycle_workload_revision_hash',
  source.id,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.complete_evidence_lifecycle_source',
      'subject_id', source.id,
      'ctid', source.ctid::text,
      'xmin', source.xmin::text
    ),
    'table', 'public.complete_evidence_lifecycle_source',
    'row', to_jsonb(source)
  ),
  'running',
  1,
  clock_timestamp() - interval '201 years',
  clock_timestamp(),
  clock_timestamp() + interval '5 minutes',
  'OTLET-CLAIM-CANARY-0087',
  'row_watch'
FROM public.complete_evidence_lifecycle_source source
WHERE source.id = 'lifecycle-subject'
RETURNING
  id AS lifecycle_job_id,
  claim_token AS lifecycle_claim_token
\gset
CREATE TEMP TABLE lifecycle_original_job_input AS
SELECT input
FROM otlet.jobs
WHERE id = :lifecycle_job_id;

SELECT completed.id AS lifecycle_output_id
FROM otlet.complete_job(
  job_id => :lifecycle_job_id,
  output => '{"decision":"keep","confidence":"high"}'::jsonb,
  raw_output => '{
    "output":{"decision":"keep","confidence":"high"},
    "actions":[
      {
        "type":"note",
        "body":{
          "subject_id":"lifecycle-subject",
          "text":"Lifecycle proof",
          "record_type":"complete_evidence_lifecycle_record"
        }
      },
      {
        "type":"update_row",
        "body":{
          "target":"complete_evidence_lifecycle_target",
          "identity":"lifecycle-subject",
          "changes":{"state":"archived"}
        }
      }
    ]
  }',
  actions => '[
    {
      "type":"note",
      "body":{
        "subject_id":"lifecycle-subject",
        "text":"Lifecycle proof",
        "record_type":"complete_evidence_lifecycle_record"
      }
    },
    {
      "type":"update_row",
      "body":{
        "target":"complete_evidence_lifecycle_target",
        "identity":"lifecycle-subject",
        "changes":{"state":"archived"}
      }
    }
  ]'::jsonb,
  started_at => clock_timestamp(),
  trace_summary => jsonb_build_object(
    'schema_validation_status', 'passed',
    'worker_incarnation_nonce_hash', repeat('d', 64),
    'detailed_trace', jsonb_build_object(
      'status', 'available',
      'chosen_text', 'OTLET-MANAGED-TRACE-CANARY-0087',
      'chosen_token_ids', jsonb_build_array(1),
      'steps', jsonb_build_array(jsonb_build_object(
        'step', 1,
        'token_id', 1,
        'token_text', 'OTLET-MANAGED-TOKEN-CANARY-0087',
        'top_alternatives', jsonb_build_array(jsonb_build_object(
          'rank', 1,
          'token_id', 2,
          'token_text', 'OTLET-MANAGED-ALT-CANARY-0087'
        ))
      ))
    )
  ),
  model_name => :'model_name',
  expected_claim_token => :'lifecycle_claim_token',
  runtime_name => 'portable:complete-evidence-lifecycle',
  runtime_endpoint => 'postgres_rpc'
) completed
\gset
UPDATE otlet.jobs
SET finished_at = clock_timestamp() - interval '200 years'
WHERE id = :lifecycle_job_id;
SELECT receipt_id AS lifecycle_receipt_id
FROM otlet.outputs
WHERE id = :lifecycle_output_id \gset
SELECT id AS lifecycle_action_id
FROM otlet.actions
WHERE job_id = :lifecycle_job_id
  AND action_type = 'note' \gset
SELECT id AS lifecycle_update_action_id,
       idempotency_key AS lifecycle_action_idempotency_key
FROM otlet.actions
WHERE job_id = :lifecycle_job_id
  AND action_type = 'update_row' \gset
SELECT id AS lifecycle_record_id
FROM otlet.records
WHERE action_id = :lifecycle_action_id \gset

INSERT INTO otlet.action_execution_receipts (
  action_id,
  idempotency_key,
  mode,
  status,
  target_name,
  target_table,
  identity_hash,
  changed_columns,
  affected_rows,
  result_hash
) VALUES (
  :lifecycle_action_id,
  otlet.identity_hash('evidence_action_idempotency', '{"proof":1}'::jsonb),
  'dry_run',
  'passed',
  'complete_evidence_lifecycle_target',
  'public.complete_evidence_lifecycle_source',
  otlet.identity_hash('evidence_action_identity', '{"proof":1}'::jsonb),
  ARRAY[]::name[],
  0,
  otlet.identity_hash('evidence_action_result', '{"proof":1}'::jsonb)
);
SELECT otlet.dry_run_action(:lifecycle_update_action_id) \g /dev/null
SELECT otlet.approve_action(
  :lifecycle_update_action_id,
  'Complete evidence lifecycle proof'
) \g /dev/null
SELECT otlet.apply_action(:lifecycle_update_action_id) \g /dev/null
SELECT id AS lifecycle_applied_receipt_id
FROM otlet.action_execution_receipts
WHERE action_id = :lifecycle_update_action_id
  AND mode = 'apply'
  AND status = 'applied' \gset
SELECT pg_temp.assert_true(
  (SELECT state = 'archived'
   FROM public.complete_evidence_lifecycle_source
   WHERE id = 'lifecycle-subject')
    AND (SELECT status = 'applied' AND apply_status = 'applied'
         FROM otlet.actions
         WHERE id = :lifecycle_update_action_id),
  'bounded evidence action was not applied'
);
SELECT otlet.record_review_event(
  'approve',
  :lifecycle_action_id,
  NULL,
  'Complete evidence lifecycle proof'
) \g /dev/null
SELECT id AS lifecycle_label_id FROM otlet.label_action(
  :lifecycle_action_id,
  'keep',
  'high',
  'note',
  'Complete evidence lifecycle proof',
  'manual_correction'
) \gset

INSERT INTO otlet.semantic_materializations (
  record_id,
  record_type,
  source_table,
  subject_id,
  source_dependencies,
  task_name,
  model_name,
  body,
  stale,
  source_hash,
  content_hash,
  contract_hash,
  stale_reason,
  created_at,
  updated_at
)
SELECT
  record.id,
  record.record_type,
  'public.complete_evidence_lifecycle_source',
  record.subject_id,
  '[]'::jsonb,
  'complete_evidence_lifecycle_watch_task',
  :'model_name',
  record.body,
  true,
  action.source_hash,
  action.content_hash,
  :'lifecycle_workload_revision_hash',
  'source_delete',
  clock_timestamp() - interval '200 years',
  clock_timestamp() - interval '200 years'
FROM otlet.records record
JOIN otlet.actions action ON action.id = record.action_id
WHERE record.id = :lifecycle_record_id
RETURNING id AS lifecycle_materialization_id \gset
INSERT INTO otlet.watch_time_freshness (
  watch_name,
  task_name,
  workload_revision_hash,
  subject_id,
  materialization_id,
  source_identity,
  anchor_identity,
  refreshed_at,
  refresh_due_at,
  expires_at
) VALUES (
  'complete_evidence_lifecycle_watch',
  'complete_evidence_lifecycle_watch_task',
  :'lifecycle_workload_revision_hash',
  'lifecycle-subject',
  :lifecycle_materialization_id,
  otlet.identity_hash('evidence_source_identity', '{"proof":1}'::jsonb),
  'complete-evidence-lifecycle-anchor',
  clock_timestamp(),
  clock_timestamp() + interval '1 hour',
  clock_timestamp() + interval '2 hours'
);
CREATE ROLE complete_evidence_lifecycle_worker NOLOGIN;
WITH runtime AS (
  SELECT jsonb_build_object(
    'runtime_contract', otlet.portable_reference_runtime_contract(),
    'proof', 'complete-evidence-lifecycle'
  ) AS identity
), model AS (
  SELECT * FROM otlet.models WHERE name = :'model_name'
)
INSERT INTO otlet.portable_workers (
  worker_id,
  database_role_oid,
  protocol_version,
  model_name,
  model_artifact_hash,
  model_artifact_bytes,
  runtime_name,
  runtime_version,
  runtime_identity,
  runtime_identity_hash,
  incarnation_nonce_hash,
  reported_state,
  model_status
)
SELECT
  'complete_evidence_lifecycle_worker',
  'complete_evidence_lifecycle_worker'::regrole::oid,
  1,
  model.name,
  model.artifact_hash,
  (model.artifact_identity ->> 'bytes')::bigint,
  'complete-evidence-lifecycle',
  'v1',
  runtime.identity,
  otlet.portable_json_hash(runtime.identity),
  repeat('d', 64),
  'idle',
  'ready'
FROM runtime
CROSS JOIN model;
INSERT INTO otlet.portable_claims (
  job_id,
  workload_revision_hash,
  worker_id,
  protocol_version,
  runtime_identity_hash,
  incarnation_nonce_hash,
  attempt_index,
  selection_role,
  claim_token_hash,
  status,
  runtime_options_status,
  claimed_at,
  finished_at
)
SELECT
  :lifecycle_job_id,
  :'lifecycle_workload_revision_hash',
  worker.worker_id,
  worker.protocol_version,
  worker.runtime_identity_hash,
  worker.incarnation_nonce_hash,
  1,
  'direct',
  otlet.portable_text_hash(:'lifecycle_claim_token'),
  'complete',
  '{"compatible":true}'::jsonb,
  clock_timestamp() - interval '1 second',
  clock_timestamp()
FROM otlet.portable_workers worker
WHERE worker.worker_id = 'complete_evidence_lifecycle_worker'
RETURNING id AS lifecycle_portable_claim_id \gset
INSERT INTO otlet.portable_receipt_links (receipt_id, claim_id)
VALUES (:lifecycle_receipt_id, :lifecycle_portable_claim_id);

SELECT pg_temp.assert_true(
  (SELECT status = 'complete' FROM otlet.actions
   WHERE id = :lifecycle_action_id)
    AND EXISTS (
      SELECT 1 FROM otlet.review_samples
      WHERE job_id = :lifecycle_job_id
    ),
  'full evidence fixture did not create terminal action and review sample'
);

CREATE TEMP TABLE lifecycle_step AS
SELECT * FROM otlet.maintenance_evidence_lifecycle_step();
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1
    FROM otlet.evidence_lifecycle_records
    WHERE job_id = :lifecycle_job_id
  )
    AND NOT EXISTS (SELECT 1 FROM lifecycle_step WHERE item_found),
  'disabled successful-job retention adopted legacy evidence'
);

SELECT otlet.request_evidence_lifecycle(
  :lifecycle_job_id,
  false,
  'Explicit lifecycle proof',
  'OTLET-EVIDENCE-1'
) \g /dev/null
SELECT pg_temp.assert_true(
  lifecycle_state = 'requested'
    AND generation = 0
    AND NOT retain_history,
  'explicit lifecycle request was not recorded'
)
FROM otlet.evidence_lifecycle_records
WHERE job_id = :lifecycle_job_id;
SELECT pg_temp.expect_error(
  format(
    'DELETE FROM otlet.evidence_lifecycle_records WHERE job_id = %s',
    :lifecycle_job_id
  ),
  'function managed'
);
SELECT pg_temp.expect_error(
  format(
    'UPDATE otlet.evidence_lifecycle_records SET held = true WHERE job_id = %s',
    :lifecycle_job_id
  ),
  'function managed'
);
SELECT pg_temp.expect_error(
  format(
    'INSERT INTO otlet.evidence_lifecycle_records SELECT * FROM otlet.evidence_lifecycle_records WHERE job_id = %s',
    :lifecycle_job_id
  ),
  'function managed'
);
SELECT pg_temp.expect_error(
  'TRUNCATE otlet.evidence_lifecycle_records',
  'function managed|cannot truncate'
);

CREATE TABLE public.complete_evidence_cleanup_control_source (
  id text PRIMARY KEY
);
INSERT INTO public.complete_evidence_cleanup_control_source
VALUES ('cleanup-control');
SELECT otlet.create_watch(
  watch_name => 'complete_evidence_cleanup_control_watch',
  kind => 'row',
  instruction => 'Return one keep decision and one note',
  output_schema => '{
    "type":"object",
    "required":["decision","confidence"],
    "additionalProperties":false,
    "properties":{
      "decision":{"enum":["keep"]},
      "confidence":{"enum":["high"]}
    }
  }'::jsonb,
  model_name => :'model_name',
  table_name => 'public.complete_evidence_cleanup_control_source'::regclass,
  subject_column => 'id',
  record_type => 'complete_evidence_cleanup_control_record',
  action_types => ARRAY['note'],
  input_columns => ARRAY['id'],
  decision_contract => '{
    "answer_field":"decision",
    "abstain_values":[],
    "confidence_field":"confidence",
    "accepted_confidence":["high"],
    "action_types":["note"]
  }'::jsonb
) \g /dev/null
SELECT otlet.ensure_active_workload_revision(
  'complete_evidence_cleanup_control_watch_task'
) AS lifecycle_cleanup_revision_hash \gset
INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input,
  status,
  attempts,
  started_at,
  leased_until,
  claim_token,
  job_origin
)
SELECT
  'complete_evidence_cleanup_control_watch_task',
  :'lifecycle_cleanup_revision_hash',
  source.id,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.complete_evidence_cleanup_control_source',
      'subject_id', source.id,
      'ctid', source.ctid::text,
      'xmin', source.xmin::text
    ),
    'table', 'public.complete_evidence_cleanup_control_source',
    'row', to_jsonb(source)
  ),
  'running',
  1,
  clock_timestamp(),
  clock_timestamp() + interval '5 minutes',
  'complete-evidence-cleanup-control-claim',
  'row_watch'
FROM public.complete_evidence_cleanup_control_source source
WHERE source.id = 'cleanup-control'
RETURNING id AS lifecycle_cleanup_job_id,
  claim_token AS lifecycle_cleanup_claim_token
\gset
SELECT completed.id AS lifecycle_cleanup_output_id
FROM otlet.complete_job(
  job_id => :lifecycle_cleanup_job_id,
  output => '{"decision":"keep","confidence":"high"}'::jsonb,
  raw_output => '{
    "output":{"decision":"keep","confidence":"high"},
    "actions":[{
      "type":"note",
      "body":{
        "subject_id":"cleanup-control",
        "text":"Cleanup control",
        "record_type":"complete_evidence_cleanup_control_record"
      }
    }]
  }',
  actions => '[{
    "type":"note",
    "body":{
      "subject_id":"cleanup-control",
      "text":"Cleanup control",
      "record_type":"complete_evidence_cleanup_control_record"
    }
  }]'::jsonb,
  started_at => clock_timestamp(),
  trace_summary => '{
    "schema_validation_status":"passed",
    "detailed_trace":{
      "status":"available",
      "chosen_text":"OTLET-UNMANAGED-TRACE-CANARY-0087",
      "chosen_token_ids":[1],
      "steps":[{
        "step":1,
        "token_id":1,
        "token_text":"OTLET-UNMANAGED-TOKEN-CANARY-0087",
        "top_alternatives":[{
          "rank":1,
          "token_id":2,
          "token_text":"OTLET-UNMANAGED-ALT-CANARY-0087"
        }]
      }]
    }
  }'::jsonb,
  model_name => :'model_name',
  expected_claim_token => :'lifecycle_cleanup_claim_token'
) completed
\gset
SELECT receipt_id AS lifecycle_cleanup_receipt_id
FROM otlet.outputs
WHERE id = :lifecycle_cleanup_output_id \gset
SELECT id AS lifecycle_cleanup_action_id
FROM otlet.actions
WHERE job_id = :lifecycle_cleanup_job_id
  AND action_type = 'note' \gset
SELECT id AS lifecycle_cleanup_record_id
FROM otlet.records
WHERE action_id = :lifecycle_cleanup_action_id \gset
SELECT id AS lifecycle_cleanup_label_id FROM otlet.label_action(
  :lifecycle_cleanup_action_id,
  'keep',
  'high',
  'note',
  'Cleanup control',
  'manual_correction'
) \gset
INSERT INTO otlet.semantic_materializations (
  record_id,
  record_type,
  source_table,
  subject_id,
  source_dependencies,
  task_name,
  model_name,
  body,
  stale,
  source_hash,
  content_hash,
  contract_hash,
  stale_reason,
  created_at,
  updated_at
)
SELECT
  record.id,
  record.record_type,
  'public.complete_evidence_cleanup_control_source',
  record.subject_id,
  '[]'::jsonb,
  'complete_evidence_cleanup_control_watch_task',
  :'model_name',
  record.body,
  true,
  action.source_hash,
  action.content_hash,
  :'lifecycle_cleanup_revision_hash',
  'source_delete',
  clock_timestamp() - interval '200 years',
  clock_timestamp() - interval '200 years'
FROM otlet.records record
JOIN otlet.actions action ON action.id = record.action_id
WHERE record.id = :lifecycle_cleanup_record_id
RETURNING id AS lifecycle_cleanup_materialization_id \gset

UPDATE otlet.worker_events
SET created_at = clock_timestamp() - interval '200 years'
WHERE job_id IN (:lifecycle_job_id, :lifecycle_cleanup_job_id);
UPDATE otlet.inference_receipts
SET finished_at = clock_timestamp() - interval '200 years'
WHERE id IN (:lifecycle_receipt_id, :lifecycle_cleanup_receipt_id);
ALTER TABLE otlet.eval_labels DISABLE TRIGGER eval_labels_c_adjudication;
UPDATE otlet.eval_labels
SET created_at = clock_timestamp() - interval '200 years'
WHERE id IN (:lifecycle_label_id, :lifecycle_cleanup_label_id);
ALTER TABLE otlet.eval_labels ENABLE TRIGGER eval_labels_c_adjudication;

SELECT pg_temp.assert_true(
  worker_events = 1
    AND token_trace_rows = 1
    AND token_alternative_rows = 1
    AND eval_labels = 1
    AND delete_stale_materializations = 1
    AND sensitive_raw_outputs = 1
    AND sensitive_chosen_texts = 1
    AND sensitive_token_texts = 1
    AND sensitive_alternative_token_texts = 1
    AND failed_canceled_jobs = 0
    AND dry_run,
  'cleanup preview counted active lifecycle evidence'
)
FROM otlet.cleanup_policy_state(true);

CREATE TEMP TABLE lifecycle_legacy_cleanup_steps (
  ordinal integer NOT NULL,
  item_found boolean NOT NULL,
  item_kind text,
  affected_rows bigint NOT NULL,
  touched_relations text[] NOT NULL
);
INSERT INTO lifecycle_legacy_cleanup_steps
SELECT 1, step.* FROM otlet.maintenance_cleanup_step_before_evidence() step;
INSERT INTO lifecycle_legacy_cleanup_steps
SELECT 2, step.* FROM otlet.maintenance_cleanup_step_before_evidence() step;
INSERT INTO lifecycle_legacy_cleanup_steps
SELECT 3, step.* FROM otlet.maintenance_cleanup_step_before_evidence() step;
INSERT INTO lifecycle_legacy_cleanup_steps
SELECT 4, step.* FROM otlet.maintenance_cleanup_step_before_evidence() step;
INSERT INTO lifecycle_legacy_cleanup_steps
SELECT 5, step.* FROM otlet.maintenance_cleanup_step_before_evidence() step;
CREATE TEMP TABLE lifecycle_legacy_cleanup_idle AS
SELECT * FROM otlet.maintenance_cleanup_step_before_evidence();
SELECT pg_temp.assert_true(
  (SELECT string_agg(item_kind, '|' ORDER BY ordinal) =
      'worker_event|trace_detail|eval_label_series|delete_stale_materialization|sensitive_evidence'
     AND bool_and(item_found AND affected_rows = 1)
   FROM lifecycle_legacy_cleanup_steps)
    AND NOT EXISTS (
      SELECT 1 FROM lifecycle_legacy_cleanup_idle WHERE item_found
    )
    AND EXISTS (
      SELECT 1 FROM otlet.worker_events
      WHERE job_id = :lifecycle_job_id
    )
    AND EXISTS (
      SELECT 1 FROM otlet.inference_receipts
      WHERE id = :lifecycle_receipt_id
        AND raw_output IS NOT NULL
        AND trace_summary #>> '{detailed_trace,chosen_text}' =
          'OTLET-MANAGED-TRACE-CANARY-0087'
        AND jsonb_array_length(
          trace_summary #> '{detailed_trace,steps}'
        ) = 1
    )
    AND EXISTS (
      SELECT 1 FROM otlet.eval_labels WHERE id = :lifecycle_label_id
    )
    AND EXISTS (
      SELECT 1 FROM otlet.semantic_materializations
      WHERE id = :lifecycle_materialization_id
    )
    AND NOT EXISTS (
      SELECT 1 FROM otlet.worker_events
      WHERE job_id = :lifecycle_cleanup_job_id
    )
    AND EXISTS (
      SELECT 1 FROM otlet.inference_receipts
      WHERE id = :lifecycle_cleanup_receipt_id
        AND raw_output IS NULL
        AND trace_summary #>> '{detailed_trace,chosen_text}' IS NULL
        AND trace_summary #> '{detailed_trace,steps}' = '[]'::jsonb
    )
    AND NOT EXISTS (
      SELECT 1 FROM otlet.eval_labels WHERE id = :lifecycle_cleanup_label_id
    )
    AND NOT EXISTS (
      SELECT 1 FROM otlet.semantic_materializations
      WHERE id = :lifecycle_cleanup_materialization_id
    ),
  'legacy cleanup did not fence active evidence and clean controls'
);

SELECT pg_temp.assert_true(
  count(*) = 1
    AND bool_and(NOT evidence ? 'claim_token')
    AND bool_and(NOT evidence ? 'terminal_claim_token')
    AND bool_and(
      position('OTLET-CLAIM-CANARY-0087' IN evidence::text) = 0
    ),
  'archive job evidence retained a raw claim token'
)
FROM otlet.evidence_archive_rows(:lifecycle_job_id)
WHERE evidence_kind = 'job';

SET LOCAL TimeZone = 'America/Los_Angeles';
CREATE TEMP TABLE lifecycle_timezone_manifest AS
SELECT manifest_hash
FROM otlet.evidence_archive_manifest(:lifecycle_job_id);
SET LOCAL TimeZone = 'Asia/Tokyo';
SELECT pg_temp.assert_true(
  manifest_hash = (
    SELECT timezone_manifest.manifest_hash
    FROM lifecycle_timezone_manifest timezone_manifest
  ),
  'evidence archive manifest changed with TimeZone'
)
FROM otlet.evidence_archive_manifest(:lifecycle_job_id);
SET LOCAL TimeZone = 'UTC';

TRUNCATE lifecycle_step;
INSERT INTO lifecycle_step
SELECT * FROM otlet.maintenance_evidence_lifecycle_step();
SELECT pg_temp.assert_true(
  (SELECT item_found
      AND item_kind = 'evidence_archive'
      AND affected_rows = 1
      AND touched_relations = ARRAY[
        'otlet.evidence_lifecycle_records'
      ]::text[]
   FROM lifecycle_step)
    AND lifecycle_state = 'archived'
    AND generation = 1
    AND archive_row_count = 18
    AND archive_row_counts = '{
      "action":2,
      "action_execution_receipt":3,
      "eval_label":1,
      "job":1,
      "output":1,
      "portable_claim":1,
      "portable_receipt_link":1,
      "receipt":1,
      "record":1,
      "review_event":2,
      "review_sample":1,
      "semantic_materialization":1,
      "watch_time_freshness":1,
      "worker_event":1
    }'::jsonb
    AND export_state = 'pending',
  'bounded one-row archive did not capture the full evidence chain'
)
FROM otlet.evidence_lifecycle_records
WHERE job_id = :lifecycle_job_id;
SELECT pg_temp.expect_error(
  format('DELETE FROM otlet.jobs WHERE id = %s', :lifecycle_job_id),
  'is lifecycle managed'
);

SELECT generation AS lifecycle_generation
FROM otlet.evidence_lifecycle_records
WHERE job_id = :lifecycle_job_id \gset
SELECT otlet.set_evidence_history_retention(
  :lifecycle_job_id,
  :lifecycle_generation,
  true,
  'Retain lifecycle proof history',
  'OTLET-EVIDENCE-2'
) \g /dev/null
SELECT pg_temp.assert_true(
  retain_history
    AND blocker_codes @> ARRAY['history_retained']::text[],
  'retain_history did not expose its named deletion conflict'
)
FROM otlet.evidence_lifecycle_status
WHERE job_id = :lifecycle_job_id;
SELECT generation AS lifecycle_generation
FROM otlet.evidence_lifecycle_records
WHERE job_id = :lifecycle_job_id \gset
SELECT otlet.set_evidence_history_retention(
  :lifecycle_job_id,
  :lifecycle_generation,
  false,
  'Release lifecycle proof history',
  'OTLET-EVIDENCE-3'
) \g /dev/null

SELECT generation AS lifecycle_generation,
       archive_manifest_hash AS lifecycle_manifest_hash
FROM otlet.evidence_lifecycle_records
WHERE job_id = :lifecycle_job_id \gset
SELECT otlet.record_evidence_export(
  :lifecycle_job_id,
  :lifecycle_generation,
  :'lifecycle_manifest_hash',
  NULL,
  false,
  'Fail lifecycle proof export',
  'OTLET-EVIDENCE-4'
) \g /dev/null
SELECT pg_temp.assert_true(
  export_state = 'failed'
    AND blocker_codes @> ARRAY['export_failed']::text[],
  'failed export did not block deletion'
)
FROM otlet.evidence_lifecycle_status
WHERE job_id = :lifecycle_job_id;

INSERT INTO otlet.worker_events (event_type, job_id, message, detail)
VALUES (
  'complete_evidence_lifecycle_canary',
  :lifecycle_job_id,
  'OTLET-RAW-EVIDENCE-CANARY-0087',
  '{"private":"OTLET-RAW-EVIDENCE-CANARY-0087"}'::jsonb
);
SELECT generation AS lifecycle_generation
FROM otlet.evidence_lifecycle_records
WHERE job_id = :lifecycle_job_id \gset
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.record_evidence_export(%s, %s, %L, %L, true, %L, %L)',
    :lifecycle_job_id,
    :lifecycle_generation,
    :'lifecycle_manifest_hash',
    otlet.identity_hash(
      'evidence_export_reference',
      jsonb_build_object('manifest_hash', :'lifecycle_manifest_hash')
    ),
    'Reject stale lifecycle proof export',
    'OTLET-EVIDENCE-5'
  ),
  'live manifest changed'
);
SELECT pg_temp.assert_true(
  NOT manifest_current
    AND blocker_codes @> ARRAY['export_stale']::text[]
    AND position(
      'OTLET-RAW-EVIDENCE-CANARY-0087' IN to_jsonb(status)::text
    ) = 0,
  'stale archive was not visible as a hash-only conflict'
)
FROM otlet.evidence_lifecycle_status status
WHERE job_id = :lifecycle_job_id;

TRUNCATE lifecycle_step;
INSERT INTO lifecycle_step
SELECT * FROM otlet.maintenance_evidence_lifecycle_step();
SELECT pg_temp.assert_true(
  (SELECT item_found AND item_kind = 'evidence_archive'
   FROM lifecycle_step)
    AND lifecycle_state = 'archived'
    AND archive_row_count = 19
    AND archive_row_counts = '{
      "action":2,
      "action_execution_receipt":3,
      "eval_label":1,
      "job":1,
      "output":1,
      "portable_claim":1,
      "portable_receipt_link":1,
      "receipt":1,
      "record":1,
      "review_event":2,
      "review_sample":1,
      "semantic_materialization":1,
      "watch_time_freshness":1,
      "worker_event":2
    }'::jsonb
    AND export_state = 'pending'
    AND manifest_current,
  'maintenance did not refresh the stale archive manifest'
)
FROM otlet.evidence_lifecycle_status
WHERE job_id = :lifecycle_job_id;

SELECT generation AS lifecycle_generation,
       archive_manifest_hash AS lifecycle_manifest_hash,
       otlet.identity_hash(
         'evidence_export_reference',
         jsonb_build_object(
           'manifest_hash', archive_manifest_hash,
           'receipt', 'OTLET-EVIDENCE-ARCHIVE-1'
         )
       ) AS lifecycle_export_reference_hash
FROM otlet.evidence_lifecycle_records
WHERE job_id = :lifecycle_job_id \gset
SELECT otlet.record_evidence_export(
  :lifecycle_job_id,
  :lifecycle_generation,
  :'lifecycle_manifest_hash',
  :'lifecycle_export_reference_hash',
  true,
  'Complete lifecycle proof export',
  'OTLET-EVIDENCE-6'
) \g /dev/null
UPDATE otlet.production_policy
SET successful_job_retention = interval '100 years'
WHERE name = 'default';
SELECT pg_temp.assert_true(
  export_state = 'complete'
    AND exported_at IS NOT NULL
    AND delete_eligible,
  'completed export was not initially eligible for deletion'
)
FROM otlet.evidence_lifecycle_status
WHERE job_id = :lifecycle_job_id;

SELECT generation AS lifecycle_generation
FROM otlet.evidence_lifecycle_records
WHERE job_id = :lifecycle_job_id \gset
SELECT otlet.set_evidence_hold(
  :lifecycle_job_id,
  :lifecycle_generation,
  true,
  'Hold deletion-ready lifecycle proof',
  'OTLET-EVIDENCE-7'
) \g /dev/null
SELECT pg_temp.assert_true(
  held
    AND blocker_codes = ARRAY['held']::text[]
    AND NOT delete_eligible,
  'evidence hold did not take precedence over deletion eligibility'
)
FROM otlet.evidence_lifecycle_status
WHERE job_id = :lifecycle_job_id;
TRUNCATE lifecycle_step;
INSERT INTO lifecycle_step
SELECT * FROM otlet.maintenance_evidence_lifecycle_step();
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT 1 FROM lifecycle_step WHERE item_found)
    AND EXISTS (
      SELECT 1 FROM otlet.jobs WHERE id = :lifecycle_job_id
    ),
  'maintenance deleted evidence while its hold was active'
);
SELECT generation AS lifecycle_generation
FROM otlet.evidence_lifecycle_records
WHERE job_id = :lifecycle_job_id \gset
SELECT otlet.set_evidence_hold(
  :lifecycle_job_id,
  :lifecycle_generation,
  false,
  'Release deletion-ready lifecycle proof hold',
  'OTLET-EVIDENCE-8'
) \g /dev/null
SELECT pg_temp.assert_true(
  delete_eligible AND cardinality(blocker_codes) = 0,
  'released evidence hold did not restore deletion eligibility'
)
FROM otlet.evidence_lifecycle_status
WHERE job_id = :lifecycle_job_id;

TRUNCATE lifecycle_step;
INSERT INTO lifecycle_step
SELECT * FROM otlet.maintenance_evidence_lifecycle_step();
SELECT pg_temp.assert_true(
  (SELECT item_found
      AND item_kind = 'evidence_delete'
      AND affected_rows = 19
   FROM lifecycle_step)
    AND lifecycle_state = 'deleted'
    AND export_state = 'complete'
    AND export_reference_hash = :'lifecycle_export_reference_hash'
    AND archive_row_counts = deleted_row_counts
    AND tombstone_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
    AND NOT live_job_present
    AND NOT EXISTS (
      SELECT 1 FROM otlet.jobs WHERE id = :lifecycle_job_id
    )
    AND NOT EXISTS (
      SELECT 1 FROM otlet.worker_events WHERE job_id = :lifecycle_job_id
    ),
  'evidence chain deletion was not atomic with its tombstone'
)
FROM otlet.evidence_lifecycle_status
WHERE job_id = :lifecycle_job_id;
SELECT pg_temp.assert_true(
  position(
    'OTLET-RAW-EVIDENCE-CANARY-0087' IN to_jsonb(status)::text
  ) = 0
    AND position(
      'OTLET-RAW-EVIDENCE-CANARY-0087' IN to_jsonb(record)::text
    ) = 0,
  'raw evidence canary leaked into status or tombstone state'
)
FROM otlet.evidence_lifecycle_status status
JOIN otlet.evidence_lifecycle_records record USING (job_id)
WHERE job_id = :lifecycle_job_id;

SELECT tombstone_hash AS lifecycle_action_tombstone_hash,
       replay_metadata_hash AS lifecycle_replay_metadata_hash
FROM otlet.action_idempotency_tombstones
WHERE idempotency_key = :'lifecycle_action_idempotency_key' \gset
SELECT pg_temp.assert_true(
  tombstone.tombstone_hash = :'lifecycle_action_tombstone_hash'
    AND tombstone.replay_metadata_hash = :'lifecycle_replay_metadata_hash'
    AND tombstone.source_job_id = :lifecycle_job_id
    AND tombstone.source_job_identity_hash ~
      '^otlet:v1:sha256:[0-9a-f]{64}$'
    AND tombstone.before_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
    AND tombstone.result_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
    AND position(
      'complete_evidence_lifecycle_target' IN to_jsonb(tombstone)::text
    ) = 0
    AND position(
      'public.complete_evidence_lifecycle_source' IN to_jsonb(tombstone)::text
    ) = 0,
  'applied action deletion did not create a hash-only replay tombstone'
)
FROM otlet.action_idempotency_tombstones tombstone
WHERE tombstone.idempotency_key = :'lifecycle_action_idempotency_key';
SELECT pg_temp.expect_error(
  format(
    'DELETE FROM otlet.action_idempotency_tombstones WHERE idempotency_key = %L',
    :'lifecycle_action_idempotency_key'
  ),
  'function managed'
);

CREATE FUNCTION pg_temp.create_evidence_replay_action(
  requested_task_name text,
  requested_input jsonb,
  requested_claim_token text,
  requested_model_name text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  revision_hash text;
  created_job_id bigint;
  created_action_id bigint;
BEGIN
  SELECT head.active_workload_revision_hash INTO STRICT revision_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = requested_task_name;
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    status,
    attempts,
    started_at,
    leased_until,
    claim_token,
    job_origin
  )
  VALUES (
    requested_task_name,
    revision_hash,
    'lifecycle-subject',
    requested_input,
    'running',
    1,
    clock_timestamp(),
    clock_timestamp() + interval '5 minutes',
    requested_claim_token,
    'row_watch'
  )
  RETURNING id INTO STRICT created_job_id;
  PERFORM otlet.complete_job(
    job_id => created_job_id,
    output => '{"decision":"keep","confidence":"high"}'::jsonb,
    raw_output => '{
      "output":{"decision":"keep","confidence":"high"},
      "actions":[{
        "type":"update_row",
        "body":{
          "target":"complete_evidence_lifecycle_target",
          "identity":"lifecycle-subject",
          "changes":{"state":"archived"}
        }
      }]
    }',
    actions => '[{
      "type":"update_row",
      "body":{
        "target":"complete_evidence_lifecycle_target",
        "identity":"lifecycle-subject",
        "changes":{"state":"archived"}
      }
    }]'::jsonb,
    started_at => clock_timestamp(),
    trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
    model_name => requested_model_name,
    expected_claim_token => requested_claim_token
  );
  SELECT action.id INTO STRICT created_action_id
  FROM otlet.actions action
  WHERE action.job_id = created_job_id
    AND action.action_type = 'update_row';
  RETURN created_action_id;
END;
$$;

UPDATE public.complete_evidence_lifecycle_source
SET state = 'pending'
WHERE id = 'lifecycle-subject';
SELECT pg_temp.create_evidence_replay_action(
  'complete_evidence_lifecycle_watch_task',
  original.input,
  'complete-evidence-normal-replay',
  :'model_name'
) AS lifecycle_replay_action_id
FROM lifecycle_original_job_input original \gset
UPDATE public.complete_evidence_lifecycle_source
SET state = 'archived'
WHERE id = 'lifecycle-subject';
SELECT pg_temp.assert_true(
  idempotency_key = :'lifecycle_action_idempotency_key',
  'duplicate action did not preserve its idempotency key'
)
FROM otlet.actions
WHERE id = :lifecycle_replay_action_id;
UPDATE otlet.actions
SET status = 'approved',
    approval_status = 'approved',
    dry_run_status = 'passed',
    error = NULL
WHERE id = :lifecycle_replay_action_id;
SELECT state AS lifecycle_target_state_before_replay,
       ctid::text AS lifecycle_target_ctid_before_replay
FROM public.complete_evidence_lifecycle_source
WHERE id = 'lifecycle-subject' \gset
SELECT otlet.apply_action(:lifecycle_replay_action_id) \g /dev/null
SELECT id AS lifecycle_replay_receipt_id
FROM otlet.action_execution_receipts
WHERE action_id = :lifecycle_replay_action_id
  AND mode = 'apply'
  AND status = 'replayed' \gset
SELECT pg_temp.assert_true(
  action.status = 'applied'
    AND action.apply_status = 'replayed'
    AND receipt.affected_rows = 0
    AND receipt.replay_of_receipt_id IS NULL
    AND receipt.replay_of_tombstone_hash = :'lifecycle_action_tombstone_hash'
    AND target.state = :'lifecycle_target_state_before_replay'
    AND target.ctid::text = :'lifecycle_target_ctid_before_replay',
  'tombstone replay mutated its target or lost replay provenance'
)
FROM otlet.actions action
JOIN otlet.action_execution_receipts receipt
  ON receipt.id = :lifecycle_replay_receipt_id
CROSS JOIN public.complete_evidence_lifecycle_source target
WHERE action.id = :lifecycle_replay_action_id
  AND target.id = 'lifecycle-subject';
UPDATE otlet.action_execution_receipts
SET result_hash = otlet.identity_hash(
  'evidence_replay_invariant_tamper',
  '{}'::jsonb
)
WHERE id = :lifecycle_replay_receipt_id;
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1
   FROM otlet.verify_invariants() invariant
   WHERE invariant.invariant_name = 'action_tombstone_replay_matches'
     AND invariant.object_id = :lifecycle_replay_receipt_id::text),
  'replay receipt drift did not surface through its invariant'
);
UPDATE otlet.action_execution_receipts receipt
SET result_hash = tombstone.result_hash
FROM otlet.action_idempotency_tombstones tombstone
WHERE receipt.id = :lifecycle_replay_receipt_id
  AND tombstone.tombstone_hash = receipt.replay_of_tombstone_hash;
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1
    FROM otlet.verify_invariants() invariant
    WHERE invariant.invariant_name = 'action_tombstone_replay_matches'
      AND invariant.object_id = :lifecycle_replay_receipt_id::text
  ),
  'restoring replay receipt provenance did not clear its invariant'
);

CREATE FUNCTION pg_temp.expect_invalid_replay_reference(
  requested_action_id bigint,
  requested_status text,
  requested_receipt_id bigint,
  requested_tombstone_hash text
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  violated_constraint text;
BEGIN
  INSERT INTO otlet.action_execution_receipts (
    action_id,
    idempotency_key,
    mode,
    status,
    target_name,
    target_table,
    identity_hash,
    changed_columns,
    affected_rows,
    error,
    replay_of_receipt_id,
    replay_of_tombstone_hash
  ) VALUES (
    requested_action_id,
    otlet.identity_hash(
      'invalid_replay_reference',
      jsonb_build_object(
        'status', requested_status,
        'receipt_id', requested_receipt_id,
        'tombstone_hash', requested_tombstone_hash
      )
    ),
    'apply',
    requested_status,
    'complete_evidence_lifecycle_target',
    'public.complete_evidence_lifecycle_source',
    otlet.identity_hash('invalid_replay_identity', 'null'::jsonb),
    ARRAY['state']::name[],
    0,
    CASE WHEN requested_status = 'failed' THEN 'Expected failure' END,
    requested_receipt_id,
    requested_tombstone_hash
  );
  RAISE EXCEPTION 'invalid replay reference was accepted';
EXCEPTION WHEN check_violation THEN
  GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
  IF violated_constraint <> 'action_execution_receipts_replay_reference_check' THEN
    RAISE EXCEPTION 'unexpected replay constraint %', violated_constraint;
  END IF;
END;
$$;
SELECT pg_temp.expect_invalid_replay_reference(
  :lifecycle_replay_action_id,
  'applied',
  :lifecycle_replay_receipt_id,
  NULL
);
SELECT pg_temp.expect_invalid_replay_reference(
  :lifecycle_replay_action_id,
  'failed',
  NULL,
  :'lifecycle_action_tombstone_hash'
);
SELECT pg_temp.expect_invalid_replay_reference(
  :lifecycle_replay_action_id,
  'failed',
  :lifecycle_replay_receipt_id,
  :'lifecycle_action_tombstone_hash'
);

CREATE TABLE public.complete_evidence_lifecycle_rebound_target (
  id text PRIMARY KEY,
  state text NOT NULL
);
INSERT INTO public.complete_evidence_lifecycle_rebound_target
VALUES ('lifecycle-subject', 'pending');
SELECT otlet.create_watch(
  watch_name => 'complete_evidence_lifecycle_rebound_watch',
  kind => 'row',
  instruction => 'Return one keep decision and one update',
  output_schema => '{
    "type":"object",
    "required":["decision","confidence"],
    "additionalProperties":false,
    "properties":{
      "decision":{"enum":["keep"]},
      "confidence":{"enum":["high"]}
    }
  }'::jsonb,
  model_name => :'model_name',
  table_name => 'public.complete_evidence_lifecycle_rebound_target'::regclass,
  subject_column => 'id',
  record_type => 'complete_evidence_lifecycle_rebound_record',
  action_types => ARRAY['note', 'update_row'],
  input_shaping => '{"strip_keys":["table"]}'::jsonb,
  input_columns => ARRAY['id', 'state'],
  decision_contract => '{
    "answer_field":"decision",
    "abstain_values":[],
    "confidence_field":"confidence",
    "accepted_confidence":["high"],
    "action_types":["note","update_row"]
  }'::jsonb
) \g /dev/null
SELECT otlet.register_action_target(
  'complete_evidence_lifecycle_target',
  'public.complete_evidence_lifecycle_rebound_target'::regclass,
  'id',
  ARRAY['state']::name[]
) \g /dev/null
SELECT otlet.register_action_workflow_policy(
  'complete_evidence_lifecycle_rebound_watch_task',
  'update_row',
  'complete_evidence_lifecycle_target',
  'bounded_mutation',
  'evaluated'
) \g /dev/null
CREATE TEMP TABLE lifecycle_rebound_job_input AS
SELECT jsonb_build_object(
  '_otlet_mvcc', jsonb_build_object(
    'table', 'public.complete_evidence_lifecycle_rebound_target',
    'subject_id', source.id,
    'ctid', source.ctid::text,
    'xmin', source.xmin::text
  ),
  'table', 'public.complete_evidence_lifecycle_rebound_target',
  'row', to_jsonb(source)
) AS input
FROM public.complete_evidence_lifecycle_rebound_target source
WHERE source.id = 'lifecycle-subject';
SELECT pg_temp.create_evidence_replay_action(
  'complete_evidence_lifecycle_rebound_watch_task',
  rebound.input,
  'complete-evidence-rebound-replay',
  :'model_name'
) AS lifecycle_rebound_action_id
FROM lifecycle_rebound_job_input rebound \gset
SELECT pg_temp.assert_true(
  idempotency_key = :'lifecycle_action_idempotency_key',
  'rebound action did not preserve its idempotency key'
)
FROM otlet.actions
WHERE id = :lifecycle_rebound_action_id;
UPDATE otlet.actions
SET status = 'approved',
    approval_status = 'approved',
    dry_run_status = 'passed',
    error = NULL
WHERE id = :lifecycle_rebound_action_id;
SELECT ctid::text AS lifecycle_original_ctid_before_rebind_failure,
       state AS lifecycle_original_state_before_rebind_failure
FROM public.complete_evidence_lifecycle_source
WHERE id = 'lifecycle-subject' \gset
SELECT ctid::text AS lifecycle_rebound_ctid_before_failure,
       state AS lifecycle_rebound_state_before_failure
FROM public.complete_evidence_lifecycle_rebound_target
WHERE id = 'lifecycle-subject' \gset
SELECT otlet.apply_action(:lifecycle_rebound_action_id) \g /dev/null
SELECT pg_temp.assert_true(
  action.status = 'approved'
    AND action.apply_status = 'failed'
    AND action.error =
      'action replay metadata changed after evidence deletion'
    AND original.ctid::text =
      :'lifecycle_original_ctid_before_rebind_failure'
    AND original.state =
      :'lifecycle_original_state_before_rebind_failure'
    AND rebound.ctid::text = :'lifecycle_rebound_ctid_before_failure'
    AND rebound.state = :'lifecycle_rebound_state_before_failure'
    AND EXISTS (
      SELECT 1
      FROM otlet.action_execution_receipts receipt
      WHERE receipt.action_id = action.id
        AND receipt.mode = 'apply'
        AND receipt.status = 'failed'
        AND receipt.error =
          'action replay metadata changed after evidence deletion'
        AND receipt.replay_of_receipt_id IS NULL
        AND receipt.replay_of_tombstone_hash IS NULL
    ),
  'target-table rebind did not fail closed without mutation'
)
FROM otlet.actions action
CROSS JOIN public.complete_evidence_lifecycle_source original
CROSS JOIN public.complete_evidence_lifecycle_rebound_target rebound
WHERE action.id = :lifecycle_rebound_action_id
  AND original.id = 'lifecycle-subject'
  AND rebound.id = 'lifecycle-subject';
CREATE TEMP TABLE lifecycle_replay_jobs AS
SELECT DISTINCT action.job_id
FROM otlet.actions action
WHERE action.id IN (
  :lifecycle_replay_action_id,
  :lifecycle_rebound_action_id
);
SELECT set_config('otlet.evidence_lifecycle_cleanup', 'on', true) \g /dev/null
DELETE FROM otlet.review_samples sample
USING lifecycle_replay_jobs replay
WHERE sample.job_id = replay.job_id;
DELETE FROM otlet.worker_events event
USING lifecycle_replay_jobs replay
WHERE event.job_id = replay.job_id;
DELETE FROM otlet.actions action
USING lifecycle_replay_jobs replay
WHERE action.job_id = replay.job_id;
DELETE FROM otlet.outputs output
USING lifecycle_replay_jobs replay
WHERE output.job_id = replay.job_id;
DELETE FROM otlet.inference_receipts receipt
USING lifecycle_replay_jobs replay
WHERE receipt.job_id = replay.job_id;
DELETE FROM otlet.jobs job
USING lifecycle_replay_jobs replay
WHERE job.id = replay.job_id;
SELECT set_config('otlet.evidence_lifecycle_cleanup', '', true) \g /dev/null
SELECT otlet.disable_action_workflow_policy(
  'complete_evidence_lifecycle_rebound_watch_task',
  'update_row'
) \g /dev/null
SELECT otlet.register_action_target(
  'complete_evidence_lifecycle_target',
  'public.complete_evidence_lifecycle_source'::regclass,
  'id',
  ARRAY['state']::name[]
) \g /dev/null
SELECT otlet.register_action_workflow_policy(
  'complete_evidence_lifecycle_watch_task',
  'update_row',
  'complete_evidence_lifecycle_target',
  'bounded_mutation',
  'evaluated'
) \g /dev/null
SELECT otlet.ensure_active_workload_revision(
  'complete_evidence_lifecycle_watch_task'
) AS lifecycle_workload_revision_hash \gset

UPDATE otlet.production_policy
SET evidence_max_chain_rows = 1
WHERE name = 'default';
INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input,
  status,
  attempts,
  created_at,
  started_at,
  finished_at
) VALUES (
  'complete_evidence_lifecycle_watch_task',
  :'lifecycle_workload_revision_hash',
  'lifecycle-cap',
  '{}'::jsonb,
  'complete',
  1,
  clock_timestamp() - interval '201 years',
  clock_timestamp() - interval '200 years',
  clock_timestamp() - interval '200 years'
) RETURNING id AS lifecycle_cap_job_id \gset
INSERT INTO otlet.worker_events (event_type, job_id, detail)
VALUES ('complete_evidence_lifecycle_cap', :lifecycle_cap_job_id, '{}'::jsonb);
TRUNCATE lifecycle_step;
INSERT INTO lifecycle_step
SELECT * FROM otlet.maintenance_evidence_lifecycle_step();
SELECT pg_temp.assert_true(
  otlet.evidence_archive_row_count_bounded(:lifecycle_cap_job_id, 1) = 2,
  'bounded evidence count did not stop at max rows plus one'
);
SELECT pg_temp.expect_error(
  format(
    'SELECT * FROM otlet.evidence_archive_manifest(%s)',
    :lifecycle_cap_job_id
  ),
  'exceeds the chain limit'
);
SELECT pg_temp.assert_true(
  (SELECT item_found
      AND item_kind = 'evidence_request'
      AND affected_rows = 2
      AND touched_relations = ARRAY[
        'otlet.administrative_change_events',
        'otlet.evidence_lifecycle_records'
      ]::text[]
   FROM lifecycle_step)
    AND record.lifecycle_state = 'requested'
    AND record.archive_manifest_hash IS NULL
    AND record.archive_row_count IS NULL
    AND record.archive_row_counts IS NULL
    AND status.current_row_count = 2
    AND status.current_manifest_hash IS NULL
    AND status.blocker_codes @> ARRAY['chain_too_large']::text[],
  'oversized evidence chain was archived or lacked its named blocker'
)
FROM otlet.evidence_lifecycle_records record
JOIN otlet.evidence_lifecycle_status status USING (job_id)
WHERE record.job_id = :lifecycle_cap_job_id;

UPDATE otlet.production_policy
SET failed_job_retention = interval '100 years'
WHERE name = 'default';
INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input,
  status,
  attempts,
  created_at,
  started_at,
  finished_at
) VALUES (
  'complete_evidence_lifecycle_watch_task',
  :'lifecycle_workload_revision_hash',
  'lifecycle-null-finished',
  '{}'::jsonb,
  'failed',
  1,
  clock_timestamp() - interval '200 years',
  clock_timestamp() - interval '200 years',
  NULL
) RETURNING id AS lifecycle_null_finished_job_id \gset
TRUNCATE lifecycle_step;
INSERT INTO lifecycle_step
SELECT * FROM otlet.maintenance_evidence_lifecycle_step();
SELECT pg_temp.assert_true(
  (SELECT item_found
      AND item_kind = 'evidence_archive'
      AND affected_rows = 2
      AND touched_relations = ARRAY[
        'otlet.administrative_change_events',
        'otlet.evidence_lifecycle_records'
      ]::text[]
   FROM lifecycle_step)
    AND record.lifecycle_state = 'archived'
    AND record.archive_row_count = 1
    AND record.terminal_at = job.created_at
    AND record.export_state = 'pending',
  'automatic null-finished adoption was not archived in one bounded item'
)
FROM otlet.evidence_lifecycle_records record
JOIN otlet.jobs job ON job.id = record.job_id
WHERE record.job_id = :lifecycle_null_finished_job_id;

UPDATE otlet.production_policy
SET successful_job_retention = NULL,
    failed_job_retention = interval '1000 years',
    evidence_max_chain_rows = 1000
WHERE name = 'default';
WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    status,
    attempts,
    created_at,
    started_at,
    finished_at
  ) VALUES
    (
      'complete_evidence_lifecycle_watch_task',
      :'lifecycle_workload_revision_hash',
      'lifecycle-snapshot',
      '{}'::jsonb,
      'complete',
      1,
      clock_timestamp() - interval '201 years',
      clock_timestamp() - interval '200 years',
      clock_timestamp() - interval '200 years'
    ),
    (
      'complete_evidence_lifecycle_watch_task',
      :'lifecycle_workload_revision_hash',
      'lifecycle-retry',
      '{}'::jsonb,
      'complete',
      1,
      clock_timestamp() - interval '201 years',
      clock_timestamp() - interval '200 years',
      clock_timestamp() - interval '200 years'
    ),
    (
      'complete_evidence_lifecycle_watch_task',
      :'lifecycle_workload_revision_hash',
      'lifecycle-backfill',
      '{}'::jsonb,
      'complete',
      1,
      clock_timestamp() - interval '201 years',
      clock_timestamp() - interval '200 years',
      clock_timestamp() - interval '200 years'
    )
  RETURNING id, subject_id
)
SELECT
  max(id) FILTER (WHERE subject_id = 'lifecycle-snapshot')
    AS lifecycle_snapshot_job_id,
  max(id) FILTER (WHERE subject_id = 'lifecycle-retry')
    AS lifecycle_retry_job_id,
  max(id) FILTER (WHERE subject_id = 'lifecycle-backfill')
    AS lifecycle_backfill_job_id
FROM inserted
\gset
SELECT otlet.request_evidence_lifecycle(
  :lifecycle_snapshot_job_id,
  false,
  'Snapshot conflict proof',
  'OTLET-EVIDENCE-10'
) \g /dev/null
SELECT otlet.request_evidence_lifecycle(
  :lifecycle_retry_job_id,
  false,
  'Retry conflict proof',
  'OTLET-EVIDENCE-11'
) \g /dev/null
SELECT otlet.request_evidence_lifecycle(
  :lifecycle_backfill_job_id,
  false,
  'Backfill conflict proof',
  'OTLET-EVIDENCE-12'
) \g /dev/null

SELECT generation AS lifecycle_snapshot_generation
FROM otlet.evidence_lifecycle_records
WHERE job_id = :lifecycle_snapshot_job_id \gset
SELECT otlet.set_evidence_hold(
  :lifecycle_snapshot_job_id,
  :lifecycle_snapshot_generation,
  true,
  'Hold snapshot conflict proof',
  'OTLET-EVIDENCE-13'
) \g /dev/null
UPDATE otlet.jobs
SET subject_id = 'lifecycle-snapshot-drifted'
WHERE id = :lifecycle_snapshot_job_id;
SELECT pg_temp.assert_true(
  status.blocker_codes[1] = 'held'
    AND status.blocker_codes @> ARRAY['held', 'snapshot_changed']::text[]
    AND (
      SELECT count(*) = 1
      FROM otlet.verify_invariants() invariant
      WHERE invariant.invariant_name =
          'evidence_lifecycle_live_snapshot_matches'
        AND invariant.object_id = :lifecycle_snapshot_job_id::text
    ),
  'subject drift did not produce its blocker and invariant'
)
FROM otlet.evidence_lifecycle_status status
WHERE status.job_id = :lifecycle_snapshot_job_id;
UPDATE otlet.jobs
SET subject_id = 'lifecycle-snapshot'
WHERE id = :lifecycle_snapshot_job_id;
SELECT generation AS lifecycle_snapshot_generation
FROM otlet.evidence_lifecycle_records
WHERE job_id = :lifecycle_snapshot_job_id \gset
SELECT otlet.set_evidence_hold(
  :lifecycle_snapshot_job_id,
  :lifecycle_snapshot_generation,
  false,
  'Release snapshot conflict proof',
  'OTLET-EVIDENCE-14'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT status.blocker_codes @> ARRAY['snapshot_changed']::text[]
    AND NOT status.blocker_codes @> ARRAY['held']::text[]
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.verify_invariants() invariant
      WHERE invariant.invariant_name =
          'evidence_lifecycle_live_snapshot_matches'
        AND invariant.object_id = :lifecycle_snapshot_job_id::text
    ),
  'restoring the evidence snapshot did not clear its conflict'
)
FROM otlet.evidence_lifecycle_status status
WHERE status.job_id = :lifecycle_snapshot_job_id;

INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input,
  status,
  retry_of_job_id,
  retry_mode
) VALUES (
  'complete_evidence_lifecycle_watch_task',
  :'lifecycle_workload_revision_hash',
  'lifecycle-retry',
  '{}'::jsonb,
  'queued',
  :lifecycle_retry_job_id,
  'original_snapshot'
) RETURNING id AS lifecycle_retry_successor_id \gset
SELECT pg_temp.assert_true(
  status.blocker_codes @> ARRAY['retry_successor']::text[]
    AND successor.retry_of_job_id = :lifecycle_retry_job_id
    AND successor.retry_mode = 'original_snapshot',
  'retry successor did not block deletion with intact provenance'
)
FROM otlet.evidence_lifecycle_status status
JOIN otlet.jobs successor ON successor.id = :lifecycle_retry_successor_id
WHERE status.job_id = :lifecycle_retry_job_id;

INSERT INTO otlet.task_backfills (
  task_name,
  workload_revision_hash,
  subject_limit,
  subject_count,
  subject_manifest_hash,
  page_size,
  max_jobs_per_minute,
  max_outstanding_jobs
) VALUES (
  'complete_evidence_lifecycle_watch_task',
  :'lifecycle_workload_revision_hash',
  1,
  1,
  otlet.identity_hash('complete_evidence_backfill', '{}'::jsonb),
  1,
  1,
  1
) RETURNING id AS lifecycle_backfill_id \gset
INSERT INTO otlet.task_backfill_subjects (
  backfill_id,
  ordinal,
  subject_id,
  selected_source_hash,
  disposition,
  submitted_source_hash,
  covered_job_id,
  processed_at
) VALUES (
  :lifecycle_backfill_id,
  1,
  'lifecycle-backfill',
  otlet.semantic_source_hash('{}'::jsonb),
  'covered',
  otlet.semantic_source_hash('{}'::jsonb),
  :lifecycle_backfill_job_id,
  clock_timestamp()
);
UPDATE otlet.task_backfills
SET subject_manifest_hash = otlet.task_backfill_manifest_hash(
      :lifecycle_backfill_id
    )
WHERE id = :lifecycle_backfill_id;
SELECT pg_temp.assert_true(
  status.blocker_codes @> ARRAY['backfill_coverage']::text[]
    AND subject.covered_job_id = :lifecycle_backfill_job_id,
  'backfill coverage did not block deletion with intact provenance'
)
FROM otlet.evidence_lifecycle_status status
JOIN otlet.task_backfill_subjects subject
  ON subject.backfill_id = :lifecycle_backfill_id
 AND subject.ordinal = 1
WHERE status.job_id = :lifecycle_backfill_job_id;

SELECT pg_temp.assert_true(
  count(*) = 26
    AND array_agg(relation.relname::text ORDER BY relation.relname) = ARRAY[
      'action_execution_receipts',
      'action_idempotency_tombstones',
      'actions',
      'eval_labels',
      'evaluation_cases',
      'evaluation_executions',
      'evaluation_results',
      'evidence_lifecycle_records',
      'inference_receipts',
      'jobs',
      'outputs',
      'pair_constraint_facts',
      'portable_claims',
      'portable_receipt_links',
      'production_model_cancellation_probes',
      'production_model_database_samples',
      'production_policy',
      'records',
      'review_events',
      'review_samples',
      'reviewer_review_errors',
      'semantic_correction_overrides',
      'semantic_materializations',
      'task_backfill_subjects',
      'watch_time_freshness',
      'worker_events'
    ]::text[]
    AND bool_and(trigger.tgtype = 62)
    AND bool_and(NOT trigger.tgisinternal)
    AND bool_and(function_namespace.nspname = 'otlet')
    AND bool_and(function.proname = 'guard_evidence_mutation_barrier'),
  'evidence mutation barrier trigger catalog is incomplete'
)
FROM pg_catalog.pg_trigger trigger
JOIN pg_catalog.pg_class relation ON relation.oid = trigger.tgrelid
JOIN pg_catalog.pg_namespace relation_namespace
  ON relation_namespace.oid = relation.relnamespace
JOIN pg_catalog.pg_proc function ON function.oid = trigger.tgfoid
JOIN pg_catalog.pg_namespace function_namespace
  ON function_namespace.oid = function.pronamespace
WHERE relation_namespace.nspname = 'otlet'
  AND trigger.tgname = 'evidence_mutation_barrier';

SELECT pg_temp.assert_true(
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.evidence_lifecycle_records',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.evidence_lifecycle_status', 'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.action_idempotency_tombstones',
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname IN (
          'guard_evidence_lifecycle_record',
          'evidence_job_label_ids',
          'guard_evidence_lifecycle_job_delete',
          'evidence_lifecycle_manages_job',
          'evidence_lifecycle_manages_label_series',
          'evidence_lifecycle_manages_materialization',
          'evidence_archive_row_count_bounded',
          'acquire_evidence_mutation_barrier',
          'guard_evidence_mutation_barrier',
          'guard_evidence_review_event_insert',
          'evidence_archive_rows',
          'evidence_archive_manifest',
          'evidence_delete_blockers',
          'evidence_lifecycle_revision',
          'request_evidence_lifecycle',
          'set_evidence_history_retention',
          'set_evidence_hold',
          'record_evidence_export',
          'maintenance_evidence_lifecycle_step',
          'maintenance_cleanup_step',
          'maintenance_cleanup_pending',
          'verify_invariants'
        )
        AND pg_catalog.has_function_privilege(
          'public', function.oid, 'EXECUTE'
        )
    ),
  'complete evidence lifecycle privileges are open to PUBLIC'
);
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants()),
  'complete evidence lifecycle left an invariant violation'
);

SELECT 'disabled_default|explicit_request|full_chain_archive|timezone_stable|direct_delete_guards|cleanup_fenced|claim_tokens_omitted|hold|failed_export|stale_refresh|completed_export|export_reference|atomic_delete_tombstone|action_tombstone_replay|replay_reference_constraint|replay_invariant|rebind_fail_closed|retain_history|named_conflict|bounded_auto_request|null_finished_adoption|snapshot_conflict|held_first|retry_backfill_conflicts|mutation_barrier_catalog|public_closed|raw_canary_absent|invariants_clean';
ROLLBACK;
SQL
)"
echo "complete_evidence_lifecycle_contract=$complete_evidence_lifecycle_contract"
[ "$complete_evidence_lifecycle_contract" = \
  "disabled_default|explicit_request|full_chain_archive|timezone_stable|direct_delete_guards|cleanup_fenced|claim_tokens_omitted|hold|failed_export|stale_refresh|completed_export|export_reference|atomic_delete_tombstone|action_tombstone_replay|replay_reference_constraint|replay_invariant|rebind_fail_closed|retain_history|named_conflict|bounded_auto_request|null_finished_adoption|snapshot_conflict|held_first|retry_backfill_conflicts|mutation_barrier_catalog|public_closed|raw_canary_absent|invariants_clean" ] || {
  echo "Complete evidence lifecycle contract mismatch: $complete_evidence_lifecycle_contract" >&2
  exit 1
}

docker exec \
  -e PGAPPNAME=otlet-evidence-delete-barrier \
  -e PGOPTIONS="$demo_pgoptions" \
  -i "$container" \
  psql -U postgres -d "$database" -v ON_ERROR_STOP=1 >/dev/null <<'SQL' &
BEGIN;
SELECT otlet.acquire_evidence_mutation_barrier();
SELECT pg_sleep(2);
SELECT * FROM otlet.maintenance_evidence_lifecycle_step();
ROLLBACK;
SQL
evidence_barrier_holder_pid=$!
evidence_barrier_ready=false
for _ in $(seq 1 40); do
  if [ "$(psql_value <<'SQL'
SELECT EXISTS (
  SELECT 1
  FROM pg_catalog.pg_stat_activity
  WHERE application_name = 'otlet-evidence-delete-barrier'
    AND wait_event = 'PgSleep'
);
SQL
)" = "t" ]; then
    evidence_barrier_ready=true
    break
  fi
  sleep 0.05
done
if [ "$evidence_barrier_ready" != "true" ]; then
  if ! wait "$evidence_barrier_holder_pid"; then
    :
  fi
  echo "Evidence mutation barrier holder did not become ready" >&2
  exit 1
fi

evidence_mutation_barrier_contract="$(psql_value <<'SQL'
CREATE TEMP TABLE evidence_barrier_result (
  sqlstate text NOT NULL,
  no_row boolean NOT NULL
);
DO $$
DECLARE
  captured_sqlstate text := '00000';
BEGIN
  BEGIN
    INSERT INTO otlet.worker_events (event_type, detail)
    VALUES ('complete_evidence_barrier_race', '{}'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS captured_sqlstate = RETURNED_SQLSTATE;
  END;
  IF captured_sqlstate <> '55P03' THEN
    RAISE EXCEPTION 'expected evidence writer SQLSTATE 55P03, got %',
      captured_sqlstate;
  END IF;
  INSERT INTO evidence_barrier_result
  SELECT captured_sqlstate, NOT EXISTS (
    SELECT 1
    FROM otlet.worker_events
    WHERE event_type = 'complete_evidence_barrier_race'
  );
END;
$$;
SELECT sqlstate || '|' || no_row::text
FROM evidence_barrier_result;
SQL
)"
wait "$evidence_barrier_holder_pid"
echo "evidence_mutation_barrier_contract=$evidence_mutation_barrier_contract"
[ "$evidence_mutation_barrier_contract" = "55P03|true" ] || {
  echo "Evidence mutation barrier contract mismatch: $evidence_mutation_barrier_contract" >&2
  exit 1
}

psql_exec >/dev/null <<'SQL'
DELETE FROM otlet.worker_events
WHERE event_type = 'complete_evidence_generic_cleanup';
INSERT INTO otlet.worker_events (event_type, detail, created_at)
VALUES (
  'complete_evidence_generic_cleanup',
  '{}'::jsonb,
  '1900-01-01 00:00:00+00'::timestamptz
);
SQL

docker exec \
  -e PGAPPNAME=otlet-evidence-shared-barrier \
  -e PGOPTIONS="$demo_pgoptions" \
  -i "$container" \
  psql -U postgres -d "$database" -v ON_ERROR_STOP=1 >/dev/null <<'SQL' &
BEGIN;
INSERT INTO otlet.worker_events (event_type, detail)
VALUES ('complete_evidence_shared_barrier', '{}'::jsonb);
SELECT pg_sleep(2);
ROLLBACK;
SQL
evidence_shared_holder_pid=$!
evidence_shared_ready=false
for _ in $(seq 1 40); do
  if [ "$(psql_value <<'SQL'
SELECT EXISTS (
  SELECT 1
  FROM pg_catalog.pg_stat_activity
  WHERE application_name = 'otlet-evidence-shared-barrier'
    AND wait_event = 'PgSleep'
);
SQL
)" = "t" ]; then
    evidence_shared_ready=true
    break
  fi
  sleep 0.05
done
if [ "$evidence_shared_ready" != "true" ]; then
  if ! wait "$evidence_shared_holder_pid"; then
    :
  fi
  echo "Evidence shared barrier holder did not become ready" >&2
  exit 1
fi

evidence_shared_barrier_contract="$(psql_value <<'SQL'
SET statement_timeout = '500ms';
CREATE TEMP TABLE evidence_shared_maintenance AS
SELECT * FROM otlet.maintenance_evidence_lifecycle_step();
CREATE TEMP TABLE evidence_shared_cleanup AS
SELECT * FROM otlet.maintenance_cleanup_step();
CREATE TEMP TABLE evidence_shared_mutation (
  request_sqlstate text NOT NULL,
  export_sqlstate text NOT NULL
);
DO $$
DECLARE
  request_sqlstate text := '00000';
  export_sqlstate text := '00000';
BEGIN
  BEGIN
    PERFORM otlet.request_evidence_lifecycle(
      0,
      false,
      'Shared barrier proof',
      'OTLET-EVIDENCE-BARRIER'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS request_sqlstate = RETURNED_SQLSTATE;
  END;
  BEGIN
    PERFORM otlet.record_evidence_export(
      0,
      0,
      otlet.identity_hash('shared_barrier_manifest', '{}'::jsonb),
      otlet.identity_hash('shared_barrier_export', '{}'::jsonb),
      true,
      'Shared barrier proof',
      'OTLET-EVIDENCE-BARRIER'
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS export_sqlstate = RETURNED_SQLSTATE;
  END;
  INSERT INTO evidence_shared_mutation
  VALUES (request_sqlstate, export_sqlstate);
END;
$$;
SELECT (
         SELECT NOT item_found
           AND item_kind IS NULL
           AND affected_rows = 0
           AND touched_relations = ARRAY[]::text[]
         FROM evidence_shared_maintenance
       )::text || '|' || (
         SELECT item_found
           AND item_kind = 'worker_event'
           AND affected_rows = 1
           AND touched_relations = ARRAY['otlet.worker_events']::text[]
           AND NOT EXISTS (
             SELECT 1
             FROM otlet.worker_events
             WHERE event_type = 'complete_evidence_generic_cleanup'
           )
         FROM evidence_shared_cleanup
       )::text || '|' || (
         SELECT request_sqlstate || '|' || export_sqlstate
         FROM evidence_shared_mutation
       );
SQL
)"
wait "$evidence_shared_holder_pid"
echo "evidence_shared_barrier_contract=$evidence_shared_barrier_contract"
[ "$evidence_shared_barrier_contract" = "true|true|55P03|55P03" ] || {
  echo "Evidence shared barrier contract mismatch: $evidence_shared_barrier_contract" >&2
  exit 1
}

crash_scan
