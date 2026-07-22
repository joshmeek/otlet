log "Checking evidence boundaries"

source_allowlist_contract_sql() {
  psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE source_allowlist_results(name text PRIMARY KEY, passed boolean NOT NULL);

CREATE TEMP TABLE evidence_source_single_task AS SELECT otlet.create_task(
  'evidence_source_single_demo',
  NULL,
  'Source allowlist proof',
  '{"type":"object"}'::jsonb,
  :'model_name',
  input_shaping => '{"source_fields":["approved"]}'::jsonb
);
DO $$
BEGIN
  PERFORM otlet.admit_task_input(
    'evidence_source_single_demo',
    'single',
    '{"approved":"ok","unapproved":"SENSITIVE-FIXTURE-SOURCE"}'::jsonb
  );
  INSERT INTO source_allowlist_results VALUES ('single', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO source_allowlist_results VALUES (
    'single',
    SQLERRM LIKE '%outside the task source-field allowlist%'
  );
END;
$$;

CREATE TEMP TABLE evidence_source_bulk_task AS SELECT otlet.create_task(
  'evidence_source_bulk_demo',
  'SELECT ''bulk''::text AS subject_id,
          ''{"approved":"ok","unapproved":"SENSITIVE-FIXTURE-BULK"}''::jsonb AS input',
  'Source allowlist proof',
  '{"type":"object"}'::jsonb,
  :'model_name',
  input_shaping => '{"source_fields":["approved"]}'::jsonb
);
DO $$
BEGIN
  PERFORM otlet.run_task('evidence_source_bulk_demo');
  INSERT INTO source_allowlist_results VALUES ('bulk', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO source_allowlist_results VALUES (
    'bulk',
    SQLERRM LIKE '%outside the task source-field allowlist%'
  );
END;
$$;

CREATE TEMP TABLE evidence_source_claim_task AS SELECT otlet.create_task(
  'evidence_source_claim_demo',
  NULL,
  'Source claim proof',
  '{"type":"object"}'::jsonb,
  :'model_name',
  input_shaping => '{"source_fields":["approved"]}'::jsonb
);
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('evidence_source_claim_demo', 'claim', '{"approved":"ok"}'::jsonb);
UPDATE otlet.tasks
SET input_shaping = '{"source_fields":[]}'::jsonb
WHERE name = 'evidence_source_claim_demo';
CREATE TEMP TABLE evidence_claimed AS SELECT * FROM otlet.claim_jobs();

CREATE TABLE public.otlet_evidence_row_source (
  id text PRIMARY KEY,
  approved text NOT NULL,
  unapproved text NOT NULL
);
INSERT INTO public.otlet_evidence_row_source
VALUES ('row-1', 'visible', 'SENSITIVE-FIXTURE-ROW');
CREATE TEMP TABLE evidence_row_watch AS SELECT otlet.create_watch(
  watch_name => 'evidence_row_allowlist_demo',
  kind => 'row',
  table_name => 'public.otlet_evidence_row_source'::regclass,
  subject_column => 'id',
  input_columns => ARRAY['id', 'approved'],
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => :'model_name'
);
CREATE TEMP TABLE evidence_row_run AS SELECT otlet.run_task('evidence_row_allowlist_demo_task');

SELECT
  (SELECT bool_and(passed) FROM source_allowlist_results)::text || '|' ||
  (SELECT count(*) = 0 FROM otlet.jobs WHERE task_name IN ('evidence_source_single_demo', 'evidence_source_bulk_demo'))::text || '|' ||
  (SELECT count(*) = 0 FROM evidence_claimed)::text || '|' ||
  (SELECT status = 'failed' AND error = 'source field allowlist violation' FROM otlet.jobs WHERE task_name = 'evidence_source_claim_demo')::text || '|' ||
  (SELECT input_columns = ARRAY['approved', 'id']::text[] FROM otlet.semantic_indexes WHERE name = 'evidence_row_allowlist_demo')::text || '|' ||
  (SELECT (input #> '{row}') ? 'approved'
          AND NOT ((input #> '{row}') ? 'unapproved')
   FROM otlet.jobs WHERE task_name = 'evidence_row_allowlist_demo_task')::text;
ROLLBACK;
SQL
}
source_allowlist_contract="$(source_allowlist_contract_sql)"
unset -f source_allowlist_contract_sql
echo "source_allowlist_contract=$source_allowlist_contract"
[ "$source_allowlist_contract" = "true|true|true|true|true|true" ] || {
  echo "Expected source allowlists on single, bulk, claim, and row-watch paths, got $source_allowlist_contract" >&2
  exit 1
}

evidence_bound_contract_sql() {
  psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE evidence_bound_results(name text PRIMARY KEY, passed boolean NOT NULL);
CREATE TEMP TABLE evidence_bound_task AS SELECT otlet.create_task(
  'evidence_bound_demo',
  NULL,
  'Evidence bound proof',
  '{"type":"object"}'::jsonb,
  :'model_name'
);
INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at)
VALUES ('evidence_bound_demo', 'bound', '{}'::jsonb, 'running', 1, now())
RETURNING id \gset bound_

UPDATE otlet.production_policy SET max_raw_output_bytes = 16 WHERE name = 'default';
DO $$
BEGIN
  PERFORM otlet.record_model_attempt(
    otlet.jobs.id,
    otlet.tasks.model_name,
    raw_output => repeat('x', 17),
    selection_status => 'failed'
  )
  FROM otlet.jobs
  JOIN otlet.tasks ON otlet.tasks.name = otlet.jobs.task_name
  WHERE otlet.jobs.task_name = 'evidence_bound_demo';
  INSERT INTO evidence_bound_results VALUES ('raw_output', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('raw_output', SQLERRM LIKE '%raw output exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_raw_output_bytes = 1048576 WHERE name = 'default';

UPDATE otlet.production_policy SET max_structured_output_bytes = 32 WHERE name = 'default';
DO $$
BEGIN
  PERFORM * FROM otlet.complete_job(
    (SELECT id FROM otlet.jobs WHERE task_name = 'evidence_bound_demo'),
    jsonb_build_object('payload', repeat('x', 64)),
    '{}',
    trace_summary => '{"schema_validation_status":"passed"}'::jsonb
  );
  INSERT INTO evidence_bound_results VALUES ('structured_output', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('structured_output', SQLERRM LIKE '%structured output exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_structured_output_bytes = 1048576 WHERE name = 'default';

UPDATE otlet.production_policy SET max_action_bytes = 64 WHERE name = 'default';
DO $$
BEGIN
  PERFORM * FROM otlet.complete_job(
    (SELECT id FROM otlet.jobs WHERE task_name = 'evidence_bound_demo'),
    '{"match":"unclear"}'::jsonb,
    '{}',
    jsonb_build_array(jsonb_build_object(
      'type', 'review_flag',
      'body', jsonb_build_object('reason', repeat('x', 80))
    )),
    trace_summary => '{"schema_validation_status":"passed"}'::jsonb
  );
  INSERT INTO evidence_bound_results VALUES ('action_bytes', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('action_bytes', SQLERRM LIKE '%action exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_action_bytes = 65536 WHERE name = 'default';

UPDATE otlet.production_policy SET max_actions_per_job = 0 WHERE name = 'default';
DO $$
BEGIN
  PERFORM * FROM otlet.complete_job(
    (SELECT id FROM otlet.jobs WHERE task_name = 'evidence_bound_demo'),
    '{"match":"unclear"}'::jsonb,
    '{}',
    '[{"type":"review_flag","body":{"reason":"review"}}]'::jsonb,
    trace_summary => '{"schema_validation_status":"passed"}'::jsonb
  );
  INSERT INTO evidence_bound_results VALUES ('action_count', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('action_count', SQLERRM LIKE '%actions exceed%');
END;
$$;
UPDATE otlet.production_policy SET max_actions_per_job = 64 WHERE name = 'default';

UPDATE otlet.production_policy SET max_trace_bytes = 64 WHERE name = 'default';
DO $$
BEGIN
  PERFORM otlet.record_model_attempt(
    otlet.jobs.id,
    otlet.tasks.model_name,
    trace_summary => jsonb_build_object('trace', repeat('x', 80)),
    selection_status => 'failed'
  )
  FROM otlet.jobs
  JOIN otlet.tasks ON otlet.tasks.name = otlet.jobs.task_name
  WHERE otlet.jobs.task_name = 'evidence_bound_demo';
  INSERT INTO evidence_bound_results VALUES ('trace', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('trace', SQLERRM LIKE '%trace exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_trace_bytes = 1048576 WHERE name = 'default';

UPDATE otlet.production_policy SET max_error_bytes = 16 WHERE name = 'default';
DO $$
BEGIN
  PERFORM * FROM otlet.fail_job(
    (SELECT id FROM otlet.jobs WHERE task_name = 'evidence_bound_demo'),
    repeat('x', 17)
  );
  INSERT INTO evidence_bound_results VALUES ('error', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('error', SQLERRM LIKE '%error exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_error_bytes = 4096 WHERE name = 'default';

UPDATE otlet.production_policy SET max_event_message_bytes = 16 WHERE name = 'default';
DO $$
BEGIN
  PERFORM otlet.record_worker_event('evidence_bound_message', message => repeat('x', 17));
  INSERT INTO evidence_bound_results VALUES ('event_message', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('event_message', SQLERRM LIKE '%event message exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_event_message_bytes = 4096 WHERE name = 'default';

UPDATE otlet.production_policy SET max_event_detail_bytes = 32 WHERE name = 'default';
DO $$
BEGIN
  PERFORM otlet.record_worker_event(
    'evidence_bound_detail',
    detail => jsonb_build_object('safe_metric', repeat('x', 40))
  );
  INSERT INTO evidence_bound_results VALUES ('event_detail', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('event_detail', SQLERRM LIKE '%event detail exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_event_detail_bytes = 262144 WHERE name = 'default';

UPDATE otlet.production_policy SET max_receipt_bytes = 512 WHERE name = 'default';
DO $$
BEGIN
  PERFORM otlet.record_model_attempt(
    otlet.jobs.id,
    otlet.tasks.model_name,
    selection_status => 'failed'
  )
  FROM otlet.jobs
  JOIN otlet.tasks ON otlet.tasks.name = otlet.jobs.task_name
  WHERE otlet.jobs.task_name = 'evidence_bound_demo';
  INSERT INTO evidence_bound_results VALUES ('receipt', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('receipt', SQLERRM LIKE '%receipt exceeds%');
END;
$$;

SELECT bool_and(passed)::text || '|' ||
       count(*)::text || '|' ||
       (SELECT status = 'running' FROM otlet.jobs WHERE id = :bound_id)::text || '|' ||
       (SELECT count(*) = 0 FROM otlet.inference_receipts WHERE job_id = :bound_id)::text || '|' ||
       (SELECT count(*) = 0 FROM otlet.outputs WHERE job_id = :bound_id)::text || '|' ||
       (SELECT count(*) = 0 FROM otlet.actions WHERE job_id = :bound_id)::text
FROM evidence_bound_results;
ROLLBACK;
SQL
}
evidence_bound_contract="$(evidence_bound_contract_sql)"
unset -f evidence_bound_contract_sql
echo "evidence_bound_contract=$evidence_bound_contract"
[ "$evidence_bound_contract" = "true|9|true|true|true|true" ] || {
  echo "Expected every stored evidence family to fail closed at its bound, got $evidence_bound_contract" >&2
  exit 1
}

evidence_redaction_contract_sql() {
  psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE evidence_redaction_task AS SELECT otlet.create_task(
  'evidence_redaction_demo',
  NULL,
  'Evidence redaction proof',
  '{"type":"object"}'::jsonb,
  :'model_name',
  decision_contract => '{
    "redact_output_fields":["sensitive_note"],
    "redact_action_fields":["reason","sensitive_note"],
    "identity_fields":["case_id"],
    "action_types":["review_flag"]
  }'::jsonb
);
INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at)
VALUES ('evidence_redaction_demo', 'redaction', '{}'::jsonb, 'running', 1, now())
RETURNING id \gset redaction_
CREATE TEMP TABLE evidence_redaction_completed AS SELECT count(*)
FROM otlet.complete_job(
  :redaction_id,
  '{"match":"unclear","case_id":"case-1","sensitive_note":"SENSITIVE-FIXTURE-OUTPUT"}'::jsonb,
  'SENSITIVE-FIXTURE-RAW',
  '[{
    "type":"review_flag",
    "body":{
      "left_id":"left-1",
      "right_id":"right-1",
      "reason":"SENSITIVE-FIXTURE-REASON",
      "sensitive_note":"SENSITIVE-FIXTURE-ACTION"
    }
  }]'::jsonb,
  trace_summary => '{
    "schema_validation_status":"passed",
    "input":{"sensitive_note":"SENSITIVE-FIXTURE-TRACE"}
  }'::jsonb,
  model_name => :'model_name'
);
DO $$
BEGIN
  PERFORM otlet.record_worker_event(
    'evidence_redaction_probe',
    detail => '{
      "model_name":"probe",
      "input":{"sensitive_note":"SENSITIVE-FIXTURE-EVENT"}
    }'::jsonb
  );
END;
$$;

SELECT
  (SELECT output ->> 'case_id' = 'case-1'
          AND output ->> 'sensitive_note' = '[REDACTED]'
   FROM otlet.outputs WHERE job_id = :redaction_id)::text || '|' ||
  (SELECT payload #>> '{body,left_id}' = 'left-1'
          AND payload #>> '{body,right_id}' = 'right-1'
          AND payload #>> '{body,reason}' = '[REDACTED]'
          AND payload #>> '{body,sensitive_note}' = '[REDACTED]'
   FROM otlet.actions WHERE job_id = :redaction_id)::text || '|' ||
  (SELECT raw_output IS NULL
          AND trace_summary -> 'input' IS NULL
          AND trace_summary #>> '{evidence_redaction,structured_output}' = 'true'
          AND trace_summary #>> '{evidence_redaction,actions}' = 'true'
   FROM otlet.inference_receipts WHERE job_id = :redaction_id)::text || '|' ||
  (SELECT detail #>> '{input}' = '[REDACTED]'
   FROM otlet.worker_events WHERE event_type = 'evidence_redaction_probe')::text || '|' ||
  (SELECT structured_output_redacted AND actions_redacted
   FROM otlet.audit_receipt_export WHERE job_id = :redaction_id)::text || '|' ||
  (SELECT bool_and(to_jsonb(surface)::text NOT LIKE '%SENSITIVE-FIXTURE%')
   FROM (
     SELECT to_jsonb(log_row) AS surface FROM otlet.operational_event_log log_row
     UNION ALL SELECT to_jsonb(metric_row) FROM otlet.worker_batch_timing_status metric_row
     UNION ALL SELECT to_jsonb(permission_row) FROM otlet.access_policy_status permission_row
     UNION ALL SELECT to_jsonb(redaction_row) FROM otlet.redaction_policy_status redaction_row
     UNION ALL SELECT to_jsonb(cleanup_row) FROM otlet.cleanup_receipt_status cleanup_row
     UNION ALL SELECT to_jsonb(hold_row) FROM otlet.retention_hold_status hold_row
     UNION ALL SELECT to_jsonb(copy_row) FROM otlet.retention_copy_status copy_row
     UNION ALL SELECT to_jsonb(receipt_row) FROM otlet.audit_receipt_export receipt_row
     UNION ALL SELECT to_jsonb(review_row) FROM otlet.audit_review_export review_row
   ) surfaces)::text;
ROLLBACK;
SQL
}
evidence_redaction_contract="$(evidence_redaction_contract_sql)"
unset -f evidence_redaction_contract_sql
echo "evidence_redaction_contract=$evidence_redaction_contract"
[ "$evidence_redaction_contract" = "true|true|true|true|true|true" ] || {
  echo "Expected structured redaction and source-free operational surfaces, got $evidence_redaction_contract" >&2
  exit 1
}
