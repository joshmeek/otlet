BEGIN;

SET LOCAL statement_timeout = '10s';

UPDATE otlet.production_policy
SET sensitive_evidence_mode = 'redacted'
WHERE name = 'default';

CREATE TEMP TABLE trust_property_params AS
SELECT
  :'model_name'::text AS model_name,
  pg_backend_pid() AS backend_pid,
  'otlet-property-' || md5(txid_current()::text || ':' || pg_backend_pid()::text) AS canary;

CREATE TEMP TABLE trust_property_results (
  category text PRIMARY KEY,
  cases integer NOT NULL,
  passed boolean NOT NULL
);

CREATE TEMP TABLE trust_property_errors (message text NOT NULL);

SELECT otlet.create_task(
  'trust_boundary_property_task',
  NULL,
  'Return status ok and only declared actions',
  '{
    "type":"object",
    "required":["status"],
    "additionalProperties":false,
    "properties":{
      "status":{"const":"ok"},
      "secret":{"type":"string"}
    }
  }'::jsonb,
  :'model_name',
  '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"source_fields":["case_id"]}'::jsonb,
  '{
    "action_types":["create_record","review_flag","update_row"],
    "redact_output_fields":["secret"],
    "redact_action_fields":["secret"]
  }'::jsonb
) \g /dev/null

CREATE TEMP TABLE trust_property_validation_job AS
WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    subject_id,
    input,
    status,
    attempts,
    started_at,
    leased_until,
    claim_token
  ) VALUES (
    'trust_boundary_property_task',
    'malformed-json',
    '{}'::jsonb,
    'running',
    1,
    clock_timestamp(),
    clock_timestamp() + interval '10 minutes',
    'trust-validation-token'
  )
  RETURNING id
)
SELECT id FROM inserted;

CREATE TEMP TABLE trust_property_malformed_json (
  case_id integer PRIMARY KEY,
  payload text NOT NULL
);

INSERT INTO trust_property_malformed_json
SELECT case_id, payload
FROM trust_property_params params
CROSS JOIN LATERAL (
  VALUES
    (1, '{'),
    (2, '['),
    (3, '{"output":'),
    (4, '{"output":{"status":"ok"},"actions":[}'),
    (5, '{"secret":"' || params.canary),
    (6, '{"output":{"status":"ok"},"actions":[],,}'),
    (7, '{"output":{"status":"ok"} "actions":[]}'),
    (8, '{"output":{"status":"\uZZZZ"},"actions":[]}')
) corpus(case_id, payload);

DO $body$
DECLARE
  test_case record;
  passed_cases integer := 0;
BEGIN
  FOR test_case IN
    SELECT * FROM trust_property_malformed_json ORDER BY case_id
  LOOP
    BEGIN
      PERFORM otlet.validate_portable_result(
        (SELECT id FROM trust_property_validation_job),
        '{"status":"ok"}'::jsonb,
        test_case.payload,
        '[]'::jsonb,
        (SELECT model_name FROM trust_property_params)
      );
      RAISE EXCEPTION 'trust property malformed JSON case % was accepted', test_case.case_id;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE 'trust property malformed JSON case % was accepted' THEN
        RAISE;
      END IF;
      IF SQLERRM <> 'otlet portable result raw output is malformed JSON' THEN
        RAISE EXCEPTION 'trust property malformed JSON case % returned %',
          test_case.case_id,
          SQLERRM;
      END IF;
      INSERT INTO trust_property_errors VALUES (SQLERRM);
      passed_cases := passed_cases + 1;
    END;
  END LOOP;

  INSERT INTO trust_property_results
  SELECT
    'malformed_json',
    passed_cases,
    passed_cases = 8
      AND job.status = 'running'
      AND NOT EXISTS (
        SELECT 1 FROM otlet.inference_receipts receipt WHERE receipt.job_id = job.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM otlet.outputs output WHERE output.job_id = job.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM otlet.actions action WHERE action.job_id = job.id
      )
  FROM otlet.jobs job
  WHERE job.id = (SELECT id FROM trust_property_validation_job);
END
$body$;

DO $body$
DECLARE
  limits otlet.definition_complexity_limits%ROWTYPE;
  schema jsonb;
  case_id integer;
  level integer;
  rejected_cases integer := 0;
BEGIN
  SELECT * INTO limits FROM otlet.definition_complexity_limits;
  FOR case_id IN 1..4 LOOP
    schema := '{"type":"string"}'::jsonb;
    FOR level IN 1..(limits.max_json_depth + case_id) LOOP
      schema := jsonb_build_object(
        'type', 'object',
        'properties', jsonb_build_object('nested', schema)
      );
    END LOOP;

    BEGIN
      PERFORM otlet.create_task(
        'trust_depth_' || case_id,
        NULL,
        'Return one object',
        schema,
        (SELECT model_name FROM trust_property_params)
      );
      RAISE EXCEPTION 'trust property schema depth case % was accepted', case_id;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE 'trust property schema depth case % was accepted' THEN
        RAISE;
      END IF;
      IF SQLERRM NOT LIKE 'otlet definition complexity rejected: JSON nesting exceeds depth %' THEN
        RAISE EXCEPTION 'trust property schema depth case % returned %', case_id, SQLERRM;
      END IF;
      INSERT INTO trust_property_errors VALUES (SQLERRM);
      rejected_cases := rejected_cases + 1;
    END;
  END LOOP;

  INSERT INTO trust_property_results VALUES (
    'schema_depth',
    rejected_cases,
    rejected_cases = 4
      AND NOT EXISTS (SELECT 1 FROM otlet.tasks WHERE name LIKE 'trust_depth_%')
  );
END
$body$;

CREATE TEMP TABLE trust_property_identifiers (
  case_id integer PRIMARY KEY,
  value text NOT NULL
);

INSERT INTO trust_property_identifiers VALUES
  (1, 'Upper'),
  (2, '_leading'),
  (3, '-leading'),
  (4, 'contains space'),
  (5, 'contains.dot'),
  (6, 'contains;semicolon'),
  (7, U&'bidi\202Ename'),
  (8, 'emoji🙂');

DO $body$
DECLARE
  test_case record;
  rejected_cases integer := 0;
BEGIN
  FOR test_case IN SELECT * FROM trust_property_identifiers ORDER BY case_id LOOP
    BEGIN
      PERFORM otlet.create_task(
        test_case.value,
        NULL,
        'Return one object',
        '{"type":"object"}'::jsonb,
        (SELECT model_name FROM trust_property_params)
      );
      RAISE EXCEPTION 'trust property identifier case % was accepted', test_case.case_id;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE 'trust property identifier case % was accepted' THEN
        RAISE;
      END IF;
      INSERT INTO trust_property_errors VALUES (SQLERRM);
      rejected_cases := rejected_cases + 1;
    END;
  END LOOP;

  INSERT INTO trust_property_results VALUES (
    'identifiers',
    rejected_cases,
    rejected_cases = 8
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.tasks task
        JOIN trust_property_identifiers corpus ON corpus.value = task.name
      )
  );
END
$body$;

CREATE TEMP TABLE trust_property_unicode (
  case_id integer PRIMARY KEY,
  value text NOT NULL,
  utf8_hex text NOT NULL
);

INSERT INTO trust_property_unicode (case_id, value, utf8_hex)
SELECT case_id, value, encode(convert_to(value, 'UTF8'), 'hex')
FROM (VALUES
  (1, U&'caf\00E9'),
  (2, U&'cafe\0301'),
  (3, '東京'),
  (4, 'שלום'),
  (5, 'مرحبا'),
  (6, '🙂'),
  (7, '👩‍💻'),
  (8, 'naïve')
) corpus(case_id, value);

INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT
  'trust_boundary_property_task',
  value,
  jsonb_build_object('case_id', case_id)
FROM trust_property_unicode;

INSERT INTO trust_property_results
SELECT
  'unicode',
  count(*)::integer,
  count(*) = 8
    AND count(DISTINCT job.subject_id) = 8
    AND bool_and(convert_from(convert_to(job.subject_id, 'UTF8'), 'UTF8') = corpus.value)
    AND bool_and(encode(convert_to(job.subject_id, 'UTF8'), 'hex') = corpus.utf8_hex)
FROM trust_property_unicode corpus
JOIN otlet.jobs job
  ON job.task_name = 'trust_boundary_property_task'
 AND job.input ->> 'case_id' = corpus.case_id::text;

CREATE TEMP TABLE trust_property_claim_results (
  case_id integer PRIMARY KEY,
  passed boolean NOT NULL
);

DO $body$
DECLARE
  case_id integer;
  property_job_id bigint;
  token text;
  rejected boolean;
  expected_status text;
  passed boolean;
BEGIN
  FOR case_id IN 1..8 LOOP
    token := 'trust-claim-' || case_id;
    INSERT INTO otlet.jobs (
      task_name,
      subject_id,
      input,
      status,
      attempts,
      started_at,
      leased_until,
      claim_token,
      cancel_requested_at
    ) VALUES (
      'trust_boundary_property_task',
      'claim-sequence-' || case_id,
      '{}'::jsonb,
      CASE WHEN case_id = 8 THEN 'cancel_requested' ELSE 'running' END,
      1,
      clock_timestamp(),
      CASE
        WHEN case_id = 2 THEN clock_timestamp() - interval '1 second'
        ELSE clock_timestamp() + interval '10 minutes'
      END,
      token,
      CASE WHEN case_id = 8 THEN clock_timestamp() ELSE NULL END
    ) RETURNING id INTO property_job_id;

    rejected := false;
    IF case_id = 1 THEN
      BEGIN
        PERFORM * FROM otlet.complete_job(
          job_id => property_job_id,
          output => '{"status":"ok"}'::jsonb,
          raw_output => '{"output":{"status":"ok"},"actions":[]}',
          actions => '[]'::jsonb,
          model_name => (SELECT model_name FROM trust_property_params),
          expected_claim_token => 'wrong-' || token
        );
      EXCEPTION WHEN OTHERS THEN
        rejected := SQLERRM = 'otlet job claim is stale';
        INSERT INTO trust_property_errors VALUES (SQLERRM);
      END;
      expected_status := 'running';
    ELSIF case_id = 2 THEN
      BEGIN
        PERFORM * FROM otlet.complete_job(
          job_id => property_job_id,
          output => '{"status":"ok"}'::jsonb,
          raw_output => '{"output":{"status":"ok"},"actions":[]}',
          actions => '[]'::jsonb,
          model_name => (SELECT model_name FROM trust_property_params),
          expected_claim_token => token
        );
      EXCEPTION WHEN OTHERS THEN
        rejected := SQLERRM = 'otlet job claim is stale';
        INSERT INTO trust_property_errors VALUES (SQLERRM);
      END;
      expected_status := 'running';
    ELSIF case_id BETWEEN 3 AND 5 THEN
      PERFORM * FROM otlet.complete_job(
        job_id => property_job_id,
        output => '{"status":"ok"}'::jsonb,
        raw_output => '{"output":{"status":"ok"},"actions":[]}',
        actions => '[]'::jsonb,
        model_name => (SELECT model_name FROM trust_property_params),
        expected_claim_token => token
      );
      IF case_id = 4 THEN
        PERFORM * FROM otlet.complete_job(
          job_id => property_job_id,
          output => '{"status":"ok"}'::jsonb,
          raw_output => '{"output":{"status":"ok"},"actions":[]}',
          actions => '[]'::jsonb,
          model_name => (SELECT model_name FROM trust_property_params),
          expected_claim_token => token
        );
      ELSIF case_id = 5 THEN
        BEGIN
          PERFORM * FROM otlet.complete_job(
            job_id => property_job_id,
            output => '{"status":"changed"}'::jsonb,
            raw_output => '{"output":{"status":"changed"},"actions":[]}',
            actions => '[]'::jsonb,
            model_name => (SELECT model_name FROM trust_property_params),
            expected_claim_token => token
          );
        EXCEPTION WHEN OTHERS THEN
          rejected := SQLERRM = 'otlet conflicting terminal retry';
          INSERT INTO trust_property_errors VALUES (SQLERRM);
        END;
      END IF;
      expected_status := 'complete';
    ELSIF case_id BETWEEN 6 AND 7 THEN
      PERFORM * FROM otlet.fail_job(
        job_id => property_job_id,
        error => 'generated failure',
        model_name => (SELECT model_name FROM trust_property_params),
        expected_claim_token => token
      );
      IF case_id = 6 THEN
        PERFORM * FROM otlet.fail_job(
          job_id => property_job_id,
          error => 'generated failure',
          model_name => (SELECT model_name FROM trust_property_params),
          expected_claim_token => token
        );
      ELSE
        BEGIN
          PERFORM * FROM otlet.fail_job(
            job_id => property_job_id,
            error => 'conflicting failure',
            model_name => (SELECT model_name FROM trust_property_params),
            expected_claim_token => token
          );
        EXCEPTION WHEN OTHERS THEN
          rejected := SQLERRM = 'otlet conflicting terminal retry';
          INSERT INTO trust_property_errors VALUES (SQLERRM);
        END;
      END IF;
      expected_status := 'failed';
    ELSE
      PERFORM * FROM otlet.complete_job(
        job_id => property_job_id,
        output => '{"status":"ok"}'::jsonb,
        raw_output => '{"output":{"status":"ok"},"actions":[]}',
        actions => '[]'::jsonb,
        model_name => (SELECT model_name FROM trust_property_params),
        expected_claim_token => token
      );
      PERFORM * FROM otlet.complete_job(
        job_id => property_job_id,
        output => '{"status":"ok"}'::jsonb,
        raw_output => '{"output":{"status":"ok"},"actions":[]}',
        actions => '[]'::jsonb,
        model_name => (SELECT model_name FROM trust_property_params),
        expected_claim_token => token
      );
      expected_status := 'canceled';
    END IF;

    SELECT
      job.status = expected_status
        AND CASE case_id
          WHEN 1 THEN rejected
          WHEN 2 THEN rejected
          WHEN 5 THEN rejected
          WHEN 7 THEN rejected
          ELSE true
        END
        AND CASE
          WHEN case_id IN (1, 2) THEN
            job.claim_token = token
              AND job.terminal_claim_token IS NULL
              AND count(receipt.id) = 0
              AND count(output.id) = 0
          WHEN case_id IN (3, 4, 5) THEN
            job.claim_token IS NULL
              AND job.terminal_claim_token = token
              AND count(DISTINCT receipt.id) = 1
              AND count(DISTINCT output.id) = 1
          ELSE
            job.claim_token IS NULL
              AND job.terminal_claim_token = token
              AND count(DISTINCT receipt.id) = 1
              AND count(DISTINCT output.id) = 0
        END
        AND count(DISTINCT action.id) = 0
    INTO passed
    FROM otlet.jobs job
    LEFT JOIN otlet.inference_receipts receipt ON receipt.job_id = job.id
    LEFT JOIN otlet.outputs output ON output.job_id = job.id
    LEFT JOIN otlet.actions action ON action.job_id = job.id
    WHERE job.id = property_job_id
    GROUP BY job.id;

    INSERT INTO trust_property_claim_results VALUES (case_id, passed);
  END LOOP;

  INSERT INTO trust_property_results
  SELECT 'claim_sequences', count(*)::integer, count(*) = 8 AND bool_and(result.passed)
  FROM trust_property_claim_results result;
END
$body$;

CREATE TEMP TABLE trust_property_action_payloads (
  case_id integer PRIMARY KEY,
  payload jsonb NOT NULL
);

INSERT INTO trust_property_action_payloads VALUES
  (1, '"scalar"'::jsonb),
  (2, '{}'::jsonb),
  (3, '{"type":"","body":{}}'::jsonb),
  (4, '{"type":"review_flag"}'::jsonb),
  (5, '{"type":"review_flag","body":[]}'::jsonb),
  (6, '{"type":"review_flag","body":{},"extra":1}'::jsonb),
  (7, '{"type":"unsupported","body":{}}'::jsonb),
  (8, '{
    "type":"update_row",
    "body":{
      "target":"pg_catalog.pg_authid",
      "identity":"postgres",
      "changes":{"rolsuper":true}
    }
  }'::jsonb);

DO $body$
DECLARE
  test_case record;
  property_job_id bigint;
  passed_cases integer := 0;
BEGIN
  FOR test_case IN SELECT * FROM trust_property_action_payloads ORDER BY case_id LOOP
    INSERT INTO otlet.jobs (
      task_name,
      subject_id,
      input,
      status,
      attempts,
      started_at,
      leased_until,
      claim_token
    ) VALUES (
      'trust_boundary_property_task',
      'action-payload-' || test_case.case_id,
      '{}'::jsonb,
      'running',
      1,
      clock_timestamp(),
      clock_timestamp() + interval '10 minutes',
      'trust-action-' || test_case.case_id
    ) RETURNING id INTO property_job_id;

    PERFORM * FROM otlet.complete_job(
      job_id => property_job_id,
      output => '{"status":"ok"}'::jsonb,
      raw_output => jsonb_build_object(
        'output', jsonb_build_object('status', 'ok'),
        'actions', jsonb_build_array(test_case.payload)
      )::text,
      actions => jsonb_build_array(test_case.payload),
      model_name => (SELECT model_name FROM trust_property_params),
      expected_claim_token => 'trust-action-' || test_case.case_id
    );

    IF EXISTS (
      SELECT 1
      FROM otlet.jobs job
      JOIN otlet.inference_receipts receipt ON receipt.job_id = job.id
      JOIN otlet.outputs output ON output.job_id = job.id
      JOIN otlet.actions action ON action.job_id = job.id
      WHERE job.id = property_job_id
        AND job.status = 'complete'
        AND action.status = 'rejected'
        AND action.approval_status = 'not_required'
        AND NOT EXISTS (
          SELECT 1 FROM otlet.action_execution_receipts execution
          WHERE execution.action_id = action.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM otlet.records record WHERE record.action_id = action.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM otlet.semantic_materializations materialization
          WHERE materialization.record_id IN (
            SELECT record.id FROM otlet.records record WHERE record.action_id = action.id
          )
        )
      GROUP BY job.id, action.id
      HAVING count(DISTINCT receipt.id) = 1
         AND count(DISTINCT output.id) = 1
         AND count(DISTINCT action.id) = 1
    ) THEN
      passed_cases := passed_cases + 1;
    END IF;
  END LOOP;

  INSERT INTO trust_property_results VALUES (
    'action_payloads',
    passed_cases,
    passed_cases = 8
  );
END
$body$;

CREATE SCHEMA trust_property_sql;
CREATE TABLE trust_property_sql.source (
  id text PRIMARY KEY,
  value text NOT NULL
);
CREATE TABLE trust_property_sql.writer_log (value text NOT NULL);
INSERT INTO trust_property_sql.source VALUES ('source', 'safe');

CREATE FUNCTION trust_property_sql.write_probe(value text) RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $body$
BEGIN
  INSERT INTO trust_property_sql.writer_log VALUES (write_probe.value);
  RETURN write_probe.value;
END
$body$;

CREATE TEMP TABLE trust_property_temp_source (id text PRIMARY KEY);
INSERT INTO trust_property_temp_source VALUES ('temp');

CREATE TEMP TABLE trust_property_sql_dependencies (
  case_id integer PRIMARY KEY,
  query text NOT NULL,
  declared_sources jsonb
);

INSERT INTO trust_property_sql_dependencies VALUES
  (1,
   'SELECT current_setting(''search_path'') AS subject_id, ''{}''::jsonb AS input',
   '[]'::jsonb),
  (2,
   'SELECT set_config(''application_name'', ''safe'', true) AS subject_id, ''{}''::jsonb AS input',
   '[]'::jsonb),
  (3,
   'SELECT CURRENT_SCHEMA::text AS subject_id, ''{}''::jsonb AS input',
   '[]'::jsonb),
  (4,
   'SELECT ''pg_database''::regclass::text AS subject_id, ''{}''::jsonb AS input',
   '[]'::jsonb),
  (5,
   'SELECT id AS subject_id, ''{}''::jsonb AS input FROM pg_temp.trust_property_temp_source',
   '[{"table":"pg_temp.trust_property_temp_source"}]'::jsonb),
  (6,
   'SELECT ''one''::text AS subject_id, ''{}''::jsonb AS input; SELECT 2',
   '[]'::jsonb),
  (7,
   'SELECT id AS subject_id, jsonb_build_object(''value'', value) AS input FROM trust_property_sql.source',
   '[]'::jsonb),
  (8,
   'SELECT id AS subject_id, jsonb_build_object(''value'', trust_property_sql.write_probe(value)) AS input FROM trust_property_sql.source',
   '[{"table":"trust_property_sql.source"}]'::jsonb);

DO $body$
DECLARE
  test_case record;
  rejected_cases integer := 0;
BEGIN
  FOR test_case IN SELECT * FROM trust_property_sql_dependencies ORDER BY case_id LOOP
    BEGIN
      PERFORM otlet.build_source_query_contract(
        test_case.query,
        test_case.declared_sources
      );
      RAISE EXCEPTION 'trust property SQL dependency case % was accepted', test_case.case_id;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE 'trust property SQL dependency case % was accepted' THEN
        RAISE;
      END IF;
      INSERT INTO trust_property_errors VALUES (SQLERRM);
      rejected_cases := rejected_cases + 1;
    END;
  END LOOP;

  INSERT INTO trust_property_results VALUES (
    'sql_dependencies',
    rejected_cases,
    rejected_cases = 8
      AND NOT EXISTS (SELECT 1 FROM trust_property_sql.writer_log)
  );
END
$body$;

CREATE FUNCTION pg_temp.trust_property_fault() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
  IF current_setting('otlet.trust_property_fault', true) = TG_ARGV[0] THEN
    RAISE EXCEPTION 'trust property injected % failure', TG_ARGV[0];
  END IF;
  RETURN NEW;
END
$body$;

CREATE TRIGGER trust_property_receipt_fault
AFTER INSERT ON otlet.inference_receipts
FOR EACH ROW EXECUTE FUNCTION pg_temp.trust_property_fault('receipt');

CREATE TRIGGER trust_property_output_fault
AFTER INSERT ON otlet.outputs
FOR EACH ROW EXECUTE FUNCTION pg_temp.trust_property_fault('output');

CREATE TRIGGER trust_property_action_fault
AFTER INSERT ON otlet.actions
FOR EACH ROW EXECUTE FUNCTION pg_temp.trust_property_fault('action');

CREATE TRIGGER trust_property_record_fault
AFTER INSERT ON otlet.records
FOR EACH ROW EXECUTE FUNCTION pg_temp.trust_property_fault('record');

CREATE TEMP TABLE trust_property_fault_results (
  stage text PRIMARY KEY,
  passed boolean NOT NULL
);

DO $body$
DECLARE
  stage text;
  property_job_id bigint;
  token text;
  output jsonb;
  actions jsonb;
  canary text := (SELECT canary FROM trust_property_params);
  rejected boolean;
  passed boolean;
BEGIN
  FOREACH stage IN ARRAY ARRAY['receipt', 'output', 'action', 'record'] LOOP
    token := 'trust-fault-' || stage;
    output := jsonb_build_object('status', 'ok', 'secret', canary);
    actions := CASE
      WHEN stage IN ('action', 'record') THEN jsonb_build_array(jsonb_build_object(
        'type', 'create_record',
        'record_type', 'trust_property',
        'subject_id', stage,
        'body', jsonb_build_object('secret', canary)
      ))
      ELSE '[]'::jsonb
    END;

    INSERT INTO otlet.jobs (
      task_name,
      subject_id,
      input,
      status,
      attempts,
      started_at,
      leased_until,
      claim_token
    ) VALUES (
      'trust_boundary_property_task',
      'fault-' || stage,
      '{}'::jsonb,
      'running',
      1,
      clock_timestamp(),
      clock_timestamp() + interval '10 minutes',
      token
    ) RETURNING id INTO property_job_id;

    PERFORM set_config('otlet.trust_property_fault', stage, true);
    rejected := false;
    BEGIN
      PERFORM * FROM otlet.complete_job(
        job_id => property_job_id,
        output => output,
        raw_output => jsonb_build_object('output', output, 'actions', actions)::text,
        actions => actions,
        model_name => (SELECT model_name FROM trust_property_params),
        expected_claim_token => token
      );
    EXCEPTION WHEN OTHERS THEN
      rejected := SQLERRM = 'trust property injected ' || stage || ' failure';
      INSERT INTO trust_property_errors VALUES (SQLERRM);
    END;
    PERFORM set_config('otlet.trust_property_fault', '', true);

    SELECT
      rejected
        AND job.status = 'running'
        AND job.claim_token = token
        AND job.terminal_claim_token IS NULL
        AND count(DISTINCT receipt.id) = 0
        AND count(DISTINCT output_row.id) = 0
        AND count(DISTINCT action.id) = 0
        AND count(DISTINCT record.id) = 0
    INTO passed
    FROM otlet.jobs job
    LEFT JOIN otlet.inference_receipts receipt ON receipt.job_id = job.id
    LEFT JOIN otlet.outputs output_row ON output_row.job_id = job.id
    LEFT JOIN otlet.actions action ON action.job_id = job.id
    LEFT JOIN otlet.records record ON record.action_id = action.id
    WHERE job.id = property_job_id
    GROUP BY job.id;

    INSERT INTO trust_property_fault_results VALUES (stage, passed);
  END LOOP;

  INSERT INTO trust_property_results
  SELECT 'crash_points', count(*)::integer, count(*) = 4 AND bool_and(result.passed)
  FROM trust_property_fault_results result;
END
$body$;

CREATE TEMP TABLE trust_property_leaks (relation_name text PRIMARY KEY);

DO $body$
DECLARE
  target_relation record;
  leaked boolean;
  canary text := (SELECT canary FROM trust_property_params);
BEGIN
  FOR target_relation IN
    SELECT table_row.oid::regclass AS name
    FROM pg_class table_row
    JOIN pg_namespace namespace ON namespace.oid = table_row.relnamespace
    WHERE namespace.nspname = 'otlet'
      AND table_row.relkind IN ('r', 'p')
    ORDER BY table_row.oid
  LOOP
    EXECUTE format(
      'SELECT EXISTS (SELECT 1 FROM %s row_value WHERE strpos(to_jsonb(row_value)::text, $1) > 0)',
      target_relation.name
    ) USING canary INTO leaked;
    IF leaked THEN
      INSERT INTO trust_property_leaks VALUES (target_relation.name::text);
    END IF;
  END LOOP;
END
$body$;

CREATE TEMP TABLE trust_property_summary AS
SELECT
  (
    SELECT count(*)
    FROM otlet.actions action
    JOIN otlet.jobs job ON job.id = action.job_id
    WHERE job.task_name = 'trust_boundary_property_task'
      AND job.subject_id LIKE 'action-payload-%'
      AND action.status <> 'rejected'
  )
  + (
    SELECT count(*)
    FROM otlet.action_execution_receipts execution
    JOIN otlet.actions action ON action.id = execution.action_id
    JOIN otlet.jobs job ON job.id = action.job_id
    WHERE job.task_name = 'trust_boundary_property_task'
  )
  + (
    SELECT count(*)
    FROM otlet.records record
    JOIN otlet.actions action ON action.id = record.action_id
    JOIN otlet.jobs job ON job.id = action.job_id
    WHERE job.task_name = 'trust_boundary_property_task'
  )
  + (SELECT count(*) FROM trust_property_sql.writer_log)
    AS unauthorized_state,
  (SELECT count(*) FROM trust_property_leaks)
    + (
      SELECT count(*)
      FROM trust_property_errors error
      CROSS JOIN trust_property_params params
      WHERE strpos(error.message, params.canary) > 0
    ) AS raw_secret_leaks,
  (SELECT count(*) FROM trust_property_fault_results WHERE NOT passed)
    AS partial_trusted_writes,
  pg_backend_pid() = (SELECT backend_pid FROM trust_property_params)
    AS backend_pid_preserved;

DELETE FROM otlet.worker_events event
USING otlet.jobs job
WHERE event.job_id = job.id
  AND job.task_name = 'trust_boundary_property_task';

DELETE FROM otlet.semantic_materializations materialization
USING otlet.records record, otlet.actions action, otlet.jobs job
WHERE materialization.record_id = record.id
  AND record.action_id = action.id
  AND action.job_id = job.id
  AND job.task_name = 'trust_boundary_property_task';

DELETE FROM otlet.action_execution_receipts execution
USING otlet.actions action, otlet.jobs job
WHERE execution.action_id = action.id
  AND action.job_id = job.id
  AND job.task_name = 'trust_boundary_property_task';

DELETE FROM otlet.records record
USING otlet.actions action, otlet.jobs job
WHERE record.action_id = action.id
  AND action.job_id = job.id
  AND job.task_name = 'trust_boundary_property_task';

DELETE FROM otlet.actions action
USING otlet.jobs job
WHERE action.job_id = job.id
  AND job.task_name = 'trust_boundary_property_task';

DELETE FROM otlet.outputs output
USING otlet.jobs job
WHERE output.job_id = job.id
  AND job.task_name = 'trust_boundary_property_task';

DELETE FROM otlet.inference_receipts receipt
USING otlet.jobs job
WHERE receipt.job_id = job.id
  AND job.task_name = 'trust_boundary_property_task';

DELETE FROM otlet.jobs
WHERE task_name = 'trust_boundary_property_task';

DO $body$
BEGIN
  IF EXISTS (SELECT 1 FROM trust_property_results WHERE NOT passed) THEN
    RAISE EXCEPTION 'trust property category failed: %', (
      SELECT string_agg(category, ',' ORDER BY category)
      FROM trust_property_results
      WHERE NOT passed
    );
  END IF;
  IF EXISTS (
    SELECT 1
    FROM trust_property_summary
    WHERE unauthorized_state <> 0
       OR raw_secret_leaks <> 0
       OR partial_trusted_writes <> 0
       OR NOT backend_pid_preserved
  ) THEN
    RAISE EXCEPTION 'trust property safety summary failed';
  END IF;
  IF EXISTS (SELECT 1 FROM otlet.verify_invariants()) THEN
    RAISE EXCEPTION 'trust property invariant failed';
  END IF;
END
$body$;

SELECT concat_ws('|',
  'malformed_json=' || (SELECT cases FROM trust_property_results WHERE category = 'malformed_json'),
  'schema_depth=' || (SELECT cases FROM trust_property_results WHERE category = 'schema_depth'),
  'identifiers=' || (SELECT cases FROM trust_property_results WHERE category = 'identifiers'),
  'unicode=' || (SELECT cases FROM trust_property_results WHERE category = 'unicode'),
  'claim_sequences=' || (SELECT cases FROM trust_property_results WHERE category = 'claim_sequences'),
  'sql_dependencies=' || (SELECT cases FROM trust_property_results WHERE category = 'sql_dependencies'),
  'action_payloads=' || (SELECT cases FROM trust_property_results WHERE category = 'action_payloads'),
  'crash_points=' || (SELECT cases FROM trust_property_results WHERE category = 'crash_points'),
  'unauthorized_state=' || summary.unauthorized_state,
  'raw_secret_leaks=' || summary.raw_secret_leaks,
  'partial_trusted_writes=' || summary.partial_trusted_writes,
  'backend_pid_preserved=' || summary.backend_pid_preserved,
  'invariants=0'
)
FROM trust_property_summary summary;

ROLLBACK;
