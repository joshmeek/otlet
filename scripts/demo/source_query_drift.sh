log "Proving source-query dependency drift and repair"

psql_exec -qAt <<'SQL'
BEGIN;

CREATE SCHEMA source_query_drift;
CREATE SCHEMA source_query_shadow;
CREATE SCHEMA source_query_empty;

CREATE TABLE source_query_drift.source (
  id text PRIMARY KEY,
  payload text NOT NULL,
  visible boolean NOT NULL DEFAULT true
);
INSERT INTO source_query_drift.source (id, payload)
VALUES
  ('after', 'AFTER'),
  ('complete', 'COMPLETE'),
  ('queued', 'QUEUED'),
  ('running', 'RUNNING');
ALTER TABLE source_query_drift.source ENABLE ROW LEVEL SECURITY;
ALTER TABLE source_query_drift.source FORCE ROW LEVEL SECURITY;
CREATE POLICY visible_rows ON source_query_drift.source
USING (visible);

CREATE FUNCTION source_query_drift.decorate(value text) RETURNS text
LANGUAGE sql
IMMUTABLE
BEGIN ATOMIC
  SELECT lower(value);
END;

CREATE ROLE source_query_drift_reader;
CREATE ROLE source_query_drift_unrelated;
GRANT USAGE ON SCHEMA source_query_drift TO source_query_drift_reader;
GRANT SELECT ON source_query_drift.source TO source_query_drift_reader;
REVOKE EXECUTE ON FUNCTION source_query_drift.decorate(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION source_query_drift.decorate(text) TO source_query_drift_reader;

CREATE TABLE source_query_shadow.source (
  id text PRIMARY KEY,
  payload text NOT NULL,
  visible boolean NOT NULL DEFAULT true
);
INSERT INTO source_query_shadow.source (id, payload)
VALUES ('complete', 'SHADOW');
CREATE FUNCTION source_query_shadow.decorate(value text) RETURNS text
LANGUAGE sql
IMMUTABLE
RETURNS NULL ON NULL INPUT
BEGIN ATOMIC
  SELECT NULL::text;
END;

CREATE TABLE source_query_drift.writer_log (value text NOT NULL);
CREATE FUNCTION source_query_drift.write_probe(value text) RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $body$
BEGIN
  INSERT INTO source_query_drift.writer_log VALUES (write_probe.value);
  RETURN write_probe.value;
END
$body$;

CREATE FUNCTION otlet.source_query_drift_write_probe(value text) RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $body$
BEGIN
  INSERT INTO source_query_drift.writer_log VALUES (source_query_drift_write_probe.value);
  RETURN source_query_drift_write_probe.value;
END
$body$;

CREATE TABLE source_query_drift.pair_left (id text PRIMARY KEY);
CREATE TABLE source_query_drift.pair_right (id text PRIMARY KEY);
INSERT INTO source_query_drift.pair_left VALUES ('left');
INSERT INTO source_query_drift.pair_right VALUES ('right');

CREATE TABLE source_query_drift.inherited_source (
  id text PRIMARY KEY,
  payload text NOT NULL
);

CREATE TABLE source_query_drift.partitioned_source (
  id text NOT NULL,
  payload text NOT NULL
) PARTITION BY LIST (id);
CREATE TABLE source_query_drift.partitioned_source_x
PARTITION OF source_query_drift.partitioned_source FOR VALUES IN ('x');

CREATE TYPE source_query_drift.source_state AS ENUM ('open', 'ready');
CREATE TYPE source_query_drift.source_payload AS (value text);
CREATE TABLE source_query_drift.typed_source (
  id text PRIMARY KEY,
  state source_query_drift.source_state NOT NULL
);

SELECT otlet.register_model(
  'source_query_drift_model',
  '/tmp/source-query-drift.gguf',
  repeat('6', 64),
  jsonb_build_object(
    'sha256', repeat('6', 64),
    'bytes', 1,
    'source', 'fixture',
    'revision', 'source-query-drift',
    'quantization', 'none',
    'license', 'test'
  ),
  2
) \g /dev/null

CREATE FUNCTION pg_temp.expect_error(statement text, message_fragment text) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
  BEGIN
    EXECUTE expect_error.statement;
  EXCEPTION WHEN OTHERS THEN
    IF position(expect_error.message_fragment IN SQLERRM) = 0 THEN
      RAISE EXCEPTION 'expected error containing %, got %',
        expect_error.message_fragment,
        SQLERRM;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'expected error containing %, but statement succeeded',
    expect_error.message_fragment;
END
$body$;

DO $body$
DECLARE
  pair_query text := $query$
    SELECT
      pair_left.id || ':' || pair_right.id AS subject_id,
      jsonb_build_object('left_id', pair_left.id, 'right_id', pair_right.id) AS input
    FROM source_query_drift.pair_left
    CROSS JOIN source_query_drift.pair_right
  $query$;
  contract jsonb;
BEGIN
  contract := otlet.build_source_query_contract(
    pair_query,
    '[{"table":"source_query_drift.pair_left"},{"table":"source_query_drift.pair_right"}]'::jsonb
  );
  IF jsonb_array_length(contract -> 'declared_sources') <> 2
     OR jsonb_array_length(contract -> 'relations') <> 2 THEN
    RAISE EXCEPTION 'exact pair source coverage was not captured';
  END IF;

  BEGIN
    PERFORM otlet.create_watch(
      watch_name => 'source_query_pair_reject',
      kind => 'pair',
      instruction => 'Return one decision.',
      output_schema => '{"type":"object"}'::jsonb,
      model_name => 'source_query_drift_model',
      candidate_query => pair_query,
      record_type => 'source_query_pair_reject',
      pair_sources => '[{"table":"source_query_drift.pair_left","subject_column":"id"}]'::jsonb
    );
    RAISE EXCEPTION 'undeclared pair source was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF position('declared source relations do not cover actual query reads' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;

  IF EXISTS (SELECT 1 FROM otlet.watches WHERE name = 'source_query_pair_reject')
     OR EXISTS (SELECT 1 FROM otlet.tasks WHERE name = 'source_query_pair_reject_task')
     OR EXISTS (SELECT 1 FROM otlet.semantic_join_indexes WHERE name = 'source_query_pair_reject') THEN
    RAISE EXCEPTION 'rejected pair watch left partial state';
  END IF;

  PERFORM otlet.create_watch(
    watch_name => 'source_query_pair_repair',
    kind => 'pair',
    instruction => 'Return one decision.',
    output_schema => '{"type":"object"}'::jsonb,
    model_name => 'source_query_drift_model',
    candidate_query => pair_query,
    record_type => 'source_query_pair_repair',
    pair_sources => '[{"table":"source_query_drift.pair_left","subject_column":"id"},{"table":"source_query_drift.pair_right","subject_column":"id"}]'::jsonb
  );
END
$body$;

SELECT pg_temp.expect_error(
  $statement$
    SELECT otlet.build_source_query_contract(
      'SELECT id AS subject_id, jsonb_build_object(''state'', state) AS input FROM source_query_drift.typed_source',
      '[{"table":"source_query_drift.typed_source"}]'::jsonb
    )
  $statement$,
  'uses unsupported source column type'
);

SELECT pg_temp.expect_error(
  $statement$
    SELECT otlet.build_source_query_contract(
      'SELECT id AS subject_id, to_jsonb(ROW(payload)::source_query_drift.source_payload) AS input FROM source_query_drift.source',
      '[{"table":"source_query_drift.source"}]'::jsonb
    )
  $statement$,
  'uses unsupported PostgreSQL type'
);

DO $body$
BEGIN
  PERFORM otlet.create_task(
    'source_query_constant',
    'SELECT ''constant''::text AS subject_id, ''{}''::jsonb AS input',
    'Return one decision.',
    '{"type":"object"}'::jsonb,
    'source_query_drift_model'
  );
  PERFORM otlet.ensure_active_workload_revision('source_query_constant');
  PERFORM otlet.ensure_active_workload_revision('source_query_constant');
  INSERT INTO otlet.jobs (task_name, subject_id, input)
  SELECT 'source_query_constant', 'constant-' || id, '{}'::jsonb
  FROM generate_series(1, 32) id;
  IF (SELECT count(*) FROM otlet.jobs WHERE task_name = 'source_query_constant') <> 32 THEN
    RAISE EXCEPTION 'dependency-free bulk admission did not bind every job';
  END IF;
  DELETE FROM otlet.jobs WHERE task_name = 'source_query_constant';

  EXECUTE 'CREATE DOMAIN pg_temp.text AS pg_catalog.text';
  BEGIN
    PERFORM otlet.source_query_contract_guard(
      (SELECT source_query_contract FROM otlet.tasks WHERE name = 'source_query_constant'),
      true
    );
    RAISE EXCEPTION 'temporary type shadowing was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF position('source query binding drifted' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;
  EXECUTE 'DROP DOMAIN pg_temp.text';
END
$body$;

DO $body$
DECLARE
  contract jsonb;
BEGIN
  contract := otlet.build_source_query_contract(
    'SELECT id AS subject_id, jsonb_build_object(''payload'', payload) AS input FROM source_query_drift.inherited_source',
    '[{"table":"source_query_drift.inherited_source"}]'::jsonb
  );
  EXECUTE 'CREATE TABLE source_query_drift.inherited_child () INHERITS (source_query_drift.inherited_source)';
  BEGIN
    PERFORM otlet.source_query_contract_guard(contract, true);
    RAISE EXCEPTION 'inherited child drift was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF position('source relation source_query_drift.inherited_source drifted' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;
  DROP TABLE source_query_drift.inherited_child;
END
$body$;

DO $body$
DECLARE
  original_search_path text := current_setting('search_path');
  contract jsonb;
BEGIN
  PERFORM set_config('search_path', 'source_query_shadow, pg_catalog, public', true);
  contract := otlet.build_source_query_contract(
    'SELECT ''one''::text AS subject_id, ''{}''::jsonb AS input',
    '[]'::jsonb
  );
  CREATE DOMAIN source_query_shadow.text AS pg_catalog.text CHECK (VALUE <> 'one');
  BEGIN
    PERFORM otlet.source_query_contract_guard(contract, true);
    RAISE EXCEPTION 'built-in type shadowing was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF position('source query binding drifted' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;
  PERFORM set_config('search_path', original_search_path, true);
END
$body$;

DO $body$
BEGIN
  BEGIN
    PERFORM otlet.build_source_query_contract(
      'SELECT ''one''::text AS subject_id, jsonb_build_object(''error'', otlet.action_target_validation_error(''missing'')) AS input',
      '[]'::jsonb
    );
    RAISE EXCEPTION 'unparsed stable Otlet source function was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF position('is not read-only parsed SQL' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;
END
$body$;

DO $body$
BEGIN
  BEGIN
    PERFORM otlet.create_task(
      'source_query_writer_reject',
      $query$
        SELECT id AS subject_id,
               jsonb_build_object('value', source_query_drift.write_probe(payload)) AS input
        FROM source_query_drift.source
      $query$,
      'Return one decision.',
      '{"type":"object"}'::jsonb,
      'source_query_drift_model',
      source_relations => '[{"table":"source_query_drift.source"}]'::jsonb
    );
    RAISE EXCEPTION 'mutating source function was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF position('is not read-only parsed SQL' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;

  IF EXISTS (SELECT 1 FROM otlet.tasks WHERE name = 'source_query_writer_reject')
     OR EXISTS (SELECT 1 FROM source_query_drift.writer_log) THEN
    RAISE EXCEPTION 'mutating source rejection was not atomic';
  END IF;

  BEGIN
    PERFORM otlet.create_task(
      'source_query_otlet_writer_reject',
      $query$
        SELECT id AS subject_id,
               jsonb_build_object('value', otlet.source_query_drift_write_probe(payload)) AS input
        FROM source_query_drift.source
      $query$,
      'Return one decision.',
      '{"type":"object"}'::jsonb,
      'source_query_drift_model',
      source_relations => '[{"table":"source_query_drift.source"}]'::jsonb
    );
    RAISE EXCEPTION 'mutating Otlet source function was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF position('is not read-only parsed SQL' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;

  IF EXISTS (SELECT 1 FROM otlet.tasks WHERE name = 'source_query_otlet_writer_reject')
     OR EXISTS (SELECT 1 FROM source_query_drift.writer_log) THEN
    RAISE EXCEPTION 'mutating Otlet source rejection was not atomic';
  END IF;
END
$body$;

DO $body$
BEGIN
  BEGIN
    PERFORM otlet.build_source_query_contract(
      'SELECT id AS subject_id, jsonb_build_object(''payload'', payload) AS input FROM source_query_drift.partitioned_source',
      '[{"table":"source_query_drift.partitioned_source"}]'::jsonb
    );
    RAISE EXCEPTION 'partitioned source query was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF position('cannot depend on inherited or partitioned table' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;
END
$body$;

DO $body$
BEGIN
  BEGIN
    PERFORM otlet.build_source_query_contract(
      'SELECT source.id AS subject_id, jsonb_build_object(''payload'', source.payload) AS input FROM source_query_drift.source CROSS JOIN otlet.production_policy',
      '[{"table":"source_query_drift.source"}]'::jsonb
    );
    RAISE EXCEPTION 'undeclared internal source read was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF position('cannot read internal relation otlet.production_policy' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;
END
$body$;

CREATE TEMP TABLE source_query_reader_contract AS
WITH bound AS (
  SELECT otlet.build_source_query_contract(
    $query$
      SELECT id AS subject_id,
             jsonb_build_object('payload', source_query_drift.decorate(payload)) AS input
      FROM source_query_drift.source
    $query$,
    '[{"table":"source_query_drift.source"}]'::jsonb
  ) AS contract
), reader_bound AS (
  SELECT jsonb_set(
    jsonb_set(
      jsonb_set(
        bound.contract,
        '{identity}',
        otlet.source_role_descriptor('source_query_drift_reader'::regrole::oid)
      ),
      '{relations,0}',
      otlet.source_relation_descriptor(
        'source_query_drift.source'::regclass::oid,
        'source_query_drift_reader'::regrole::oid,
        bound.contract #> '{relations,0,referenced_attnums}'
      )
    ),
    '{functions,0}',
    otlet.source_function_descriptor(
      'source_query_drift.decorate(text)'::regprocedure::oid,
      'source_query_drift_reader'::regrole::oid
    )
  ) AS contract
  FROM bound
)
SELECT contract FROM reader_bound;

DO $body$
DECLARE
  contract_error text;
BEGIN
  SELECT otlet.source_query_contract_error(contract, false)
  INTO contract_error
  FROM source_query_reader_contract;
  IF contract_error IS NOT NULL THEN
    RAISE EXCEPTION 'reader source contract was not initially valid: %', contract_error;
  END IF;
END
$body$;

SET LOCAL search_path = source_query_empty, source_query_drift, public;

SELECT otlet.create_watch(
  watch_name => 'source_query_drift_watch',
  kind => 'row',
  instruction => 'Return one decision and one review flag.',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'source_query_drift_model',
  table_name => 'source_query_drift.source'::regclass,
  subject_column => 'id',
  record_type => 'source_query_drift_record',
  action_types => ARRAY['review_flag'],
  trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  input_columns => ARRAY['id', 'payload', 'visible']
) \g /dev/null

UPDATE otlet.tasks
SET input_query = $query$
  SELECT
    src.id::text AS subject_id,
    jsonb_build_object(
      '_otlet_mvcc', jsonb_build_object(
        'table', 'source_query_drift.source',
        'subject_id', src.id::text,
        'ctid', src.ctid::text,
        'xmin', src.xmin::text
      ),
      'table', 'source_query_drift.source',
      'row', otlet.semantic_project_row(
        to_jsonb(src),
        ARRAY['id', 'payload', 'visible']::text[]
      )
    ) AS input
  FROM source AS src
  WHERE decorate(src.payload) IS NOT NULL
    AND current_setting('search_path') = 'source_query_empty, source_query_drift, public'
$query$
WHERE name = 'source_query_drift_watch_task';

CREATE TEMP TABLE source_query_drift_proof (
  revision_a text NOT NULL,
  revision_b text,
  revision_c text,
  complete_job_id bigint,
  running_job_id bigint,
  queued_job_id bigint,
  action_id bigint,
  receipt_id bigint,
  materialization_id bigint
) ON COMMIT DROP;

INSERT INTO source_query_drift_proof (revision_a)
VALUES (otlet.promote_configured_workload_revision('source_query_drift_watch_task'));

DO $body$
DECLARE
  task_contract jsonb;
  revision_definition jsonb;
BEGIN
  SELECT source_query_contract
  INTO task_contract
  FROM otlet.tasks
  WHERE name = 'source_query_drift_watch_task';
  SELECT revision.definition
  INTO revision_definition
  FROM source_query_drift_proof proof
  JOIN otlet.workload_revisions revision
    ON revision.workload_revision_hash = proof.revision_a;

  IF task_contract #>> '{query,raw}' IS DISTINCT FROM (
       SELECT input_query FROM otlet.tasks WHERE name = 'source_query_drift_watch_task'
     )
     OR task_contract #>> '{query,raw_hash}' IS DISTINCT FROM otlet.identity_text_hash(
       'source_query',
       task_contract #>> '{query,raw}'
     ) THEN
    RAISE EXCEPTION 'source query bytes were not bound exactly';
  END IF;
  IF task_contract #>> '{search_path,raw}' IS DISTINCT FROM
       'source_query_empty, source_query_drift, public'
     OR position('source_query_drift.source' IN task_contract #>> '{query,resolved}') = 0
     OR position('source_query_drift.decorate' IN task_contract #>> '{query,resolved}') = 0 THEN
    RAISE EXCEPTION 'source query was not bound to its schema and search_path';
  END IF;
  IF jsonb_array_length(task_contract -> 'declared_sources') <> 1
     OR task_contract #>> '{declared_sources,0,name}' IS DISTINCT FROM 'source_query_drift.source'
     OR jsonb_array_length(task_contract -> 'relations') <> 1
     OR task_contract #>> '{relations,0,name}' IS DISTINCT FROM 'source_query_drift.source'
     OR jsonb_array_length(task_contract -> 'functions') <> 2
     OR NOT EXISTS (
       SELECT 1
       FROM jsonb_array_elements(task_contract -> 'functions') function_contract(value)
       WHERE function_contract.value ->> 'name' = 'source_query_drift.decorate(value text)'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM jsonb_array_elements(task_contract -> 'functions') function_contract(value)
       WHERE function_contract.value ->> 'name' =
         'otlet.semantic_project_row(row_data jsonb, input_columns text[])'
     ) THEN
    RAISE EXCEPTION 'row relation or function coverage is not exact';
  END IF;
  IF revision_definition #>> '{task,input_query}' IS DISTINCT FROM task_contract #>> '{query,resolved}'
     OR revision_definition #> '{source,query_contract}' IS DISTINCT FROM task_contract
     OR otlet.source_query_contract_error(task_contract, true) IS NOT NULL THEN
    RAISE EXCEPTION 'active revision did not preserve the bound source contract';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.source_query_dependency_status
    WHERE task_name = 'source_query_drift_watch_task'
      AND dependency_status = 'ready'
      AND relation_dependencies = 1
      AND function_dependencies = 2
      AND dependency_error IS NULL
  ) THEN
    RAISE EXCEPTION 'healthy source dependency status is incomplete';
  END IF;
END
$body$;

SET LOCAL search_path = source_query_shadow, public;

DO $body$
DECLARE
  claimed_job otlet.jobs%ROWTYPE;
BEGIN
  IF otlet.run_task_subject('source_query_drift_watch_task', 'complete') <> 1 THEN
    RAISE EXCEPTION 'schema-bound source query did not queue the real source row';
  END IF;
  SELECT * INTO claimed_job
  FROM otlet.claim_jobs('source_query_drift_model', 1);
  IF claimed_job.id IS NULL OR claimed_job.subject_id <> 'complete' THEN
    RAISE EXCEPTION 'source-query proof complete job was not claimed';
  END IF;

  PERFORM 1
  FROM otlet.complete_job(
    job_id => claimed_job.id,
    output => '{"decision":"keep"}'::jsonb,
    raw_output => '{"output":{"decision":"keep"},"actions":[{"type":"review_flag","body":{"reason":"source contract proof"}}]}',
    actions => '[{"type":"review_flag","body":{"reason":"source contract proof"}}]'::jsonb,
    started_at => now(),
    trace_summary => '{"schema_validation_status":"passed","mvcc":{"table":"source_query_drift.source"}}'::jsonb,
    model_name => 'source_query_drift_model',
    expected_claim_token => claimed_job.claim_token
  );
  IF otlet.materialize_completed_semantic_job(claimed_job.id) <> 1 THEN
    RAISE EXCEPTION 'source-query proof output was not materialized';
  END IF;

  UPDATE source_query_drift_proof
  SET complete_job_id = claimed_job.id,
      receipt_id = (SELECT receipt_id FROM otlet.outputs WHERE job_id = claimed_job.id),
      action_id = (SELECT id FROM otlet.actions WHERE job_id = claimed_job.id AND action_type = 'review_flag'),
      materialization_id = (
        SELECT id
        FROM otlet.semantic_materializations
        WHERE task_name = claimed_job.task_name
          AND subject_id = claimed_job.subject_id
      );

  IF otlet.run_task_subject('source_query_drift_watch_task', 'running') <> 1 THEN
    RAISE EXCEPTION 'source-query proof running job was not admitted';
  END IF;
  SELECT * INTO claimed_job
  FROM otlet.claim_jobs('source_query_drift_model', 1);
  IF claimed_job.id IS NULL OR claimed_job.subject_id <> 'running' THEN
    RAISE EXCEPTION 'source-query proof running job was not claimed';
  END IF;
  UPDATE source_query_drift_proof SET running_job_id = claimed_job.id;

  IF otlet.run_task_subject('source_query_drift_watch_task', 'queued') <> 1 THEN
    RAISE EXCEPTION 'source-query proof queued job was not admitted';
  END IF;
  UPDATE source_query_drift_proof
  SET queued_job_id = (
    SELECT id
    FROM otlet.jobs
    WHERE task_name = 'source_query_drift_watch_task'
      AND subject_id = 'queued'
      AND status = 'queued'
  );

  IF EXISTS (
    SELECT 1 FROM source_query_drift_proof
    WHERE receipt_id IS NULL OR action_id IS NULL OR materialization_id IS NULL
       OR running_job_id IS NULL OR queued_job_id IS NULL
  ) THEN
    RAISE EXCEPTION 'source-query proof lifecycle fixtures are incomplete';
  END IF;
END
$body$;

SET LOCAL plan_cache_mode = force_generic_plan;
PREPARE source_query_drift_cached_customscan AS
SELECT id
FROM source_query_drift.source
WHERE otlet.semantic_matches(
  'source_query_drift_watch',
  id,
  '{"decision":"keep"}'::jsonb
);

DO $body$
DECLARE
  plan_line text;
  plan_text text := '';
  matched_id text;
BEGIN
  FOR plan_line IN EXECUTE 'EXPLAIN (COSTS OFF) EXECUTE source_query_drift_cached_customscan'
  LOOP
    plan_text := plan_text || plan_line;
  END LOOP;
  IF position('Otlet Semantic Source CustomScan' IN plan_text) = 0 THEN
    RAISE EXCEPTION 'source-query cached plan did not select CustomScan';
  END IF;
  EXECUTE 'EXECUTE source_query_drift_cached_customscan' INTO matched_id;
  IF matched_id IS DISTINCT FROM 'complete' THEN
    RAISE EXCEPTION 'healthy cached CustomScan returned %', matched_id;
  END IF;
END
$body$;

CREATE FUNCTION pg_temp.assert_drift(expected_fragment text) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
  contract_error text;
BEGIN
  SELECT otlet.source_query_contract_error(
    revision.definition #> '{source,query_contract}',
    true
  )
  INTO contract_error
  FROM source_query_drift_proof proof
  JOIN otlet.workload_revisions revision
    ON revision.workload_revision_hash = proof.revision_a;

  IF contract_error IS NULL
     OR position(assert_drift.expected_fragment IN contract_error) = 0 THEN
    RAISE EXCEPTION 'expected source drift containing %, got %',
      assert_drift.expected_fragment,
      contract_error;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.source_query_dependency_status
    WHERE task_name = 'source_query_drift_watch_task'
      AND dependency_status = 'suspended'
      AND position(assert_drift.expected_fragment IN dependency_error) > 0
  ) THEN
    RAISE EXCEPTION 'source dependency status did not suspend for %',
      assert_drift.expected_fragment;
  END IF;
END
$body$;

CREATE FUNCTION pg_temp.assert_reader_drift(expected_fragment text) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
  contract_error text;
BEGIN
  SELECT otlet.source_query_contract_error(contract, false)
  INTO contract_error
  FROM source_query_reader_contract;
  IF contract_error IS NULL
     OR position(assert_reader_drift.expected_fragment IN contract_error) = 0 THEN
    RAISE EXCEPTION 'expected reader drift containing %, got %',
      assert_reader_drift.expected_fragment,
      contract_error;
  END IF;
END
$body$;

CREATE FUNCTION pg_temp.assert_source_contracts_ready() RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
  reader_error text;
  active_error text;
BEGIN
  SELECT otlet.source_query_contract_error(contract, false)
  INTO reader_error
  FROM source_query_reader_contract;
  SELECT otlet.source_query_contract_error(
    revision.definition #> '{source,query_contract}',
    true
  )
  INTO active_error
  FROM source_query_drift_proof proof
  JOIN otlet.workload_revisions revision
    ON revision.workload_revision_hash = proof.revision_a;
  IF reader_error IS NOT NULL OR active_error IS NOT NULL THEN
    RAISE EXCEPTION 'irrelevant dependency drift suspended a contract: reader=%, active=%',
      reader_error,
      active_error;
  END IF;
END
$body$;

SAVEPOINT binding_drift;
CREATE TABLE source_query_empty.source (
  id text PRIMARY KEY,
  payload text NOT NULL,
  visible boolean NOT NULL DEFAULT true
);
SELECT pg_temp.assert_drift('source query binding drifted');
SELECT pg_temp.expect_error(
  'SELECT otlet.run_task_subject(''source_query_drift_watch_task'', ''after'')',
  'otlet workload is suspended'
);
ROLLBACK TO SAVEPOINT binding_drift;

SAVEPOINT relation_identity_drift;
ALTER TABLE source_query_drift.source RENAME TO source_original;
CREATE TABLE source_query_drift.source (
  id text PRIMARY KEY,
  payload text NOT NULL,
  visible boolean NOT NULL DEFAULT true
);
SELECT pg_temp.assert_drift('source query binding drifted');
SELECT pg_temp.expect_error(
  'SELECT otlet.run_task_subject(''source_query_drift_watch_task'', ''after'')',
  'otlet workload is suspended'
);
ROLLBACK TO SAVEPOINT relation_identity_drift;

SAVEPOINT relation_schema_drift;
ALTER TABLE source_query_drift.source ALTER COLUMN payload TYPE varchar(64);
SELECT pg_temp.assert_drift('source relation source_query_drift.source drifted');
ROLLBACK TO SAVEPOINT relation_schema_drift;

SAVEPOINT relevant_relation_privilege_drift;
REVOKE SELECT ON source_query_drift.source FROM source_query_drift_reader;
SELECT pg_temp.assert_reader_drift('source relation source_query_drift.source drifted');
ROLLBACK TO SAVEPOINT relevant_relation_privilege_drift;

SAVEPOINT relevant_function_privilege_drift;
REVOKE EXECUTE ON FUNCTION source_query_drift.decorate(text)
FROM source_query_drift_reader;
SELECT pg_temp.assert_reader_drift('source function source_query_drift.decorate(value text) drifted');
ROLLBACK TO SAVEPOINT relevant_function_privilege_drift;

SAVEPOINT relation_rls_drift;
ALTER POLICY visible_rows ON source_query_drift.source USING (NOT visible);
SELECT pg_temp.assert_reader_drift('source relation source_query_drift.source drifted');
ROLLBACK TO SAVEPOINT relation_rls_drift;

SAVEPOINT irrelevant_authorization_drift;
GRANT SELECT ON source_query_drift.source TO source_query_drift_unrelated;
GRANT EXECUTE ON FUNCTION source_query_drift.decorate(text)
TO source_query_drift_unrelated;
CREATE POLICY irrelevant_update ON source_query_drift.source
FOR UPDATE TO source_query_drift_unrelated
USING (false);
SELECT pg_temp.assert_source_contracts_ready();
ROLLBACK TO SAVEPOINT irrelevant_authorization_drift;

CREATE OR REPLACE FUNCTION source_query_drift.decorate(value text) RETURNS text
LANGUAGE sql
IMMUTABLE
BEGIN ATOMIC
  SELECT upper(value);
END;

SELECT pg_temp.assert_drift('source function source_query_drift.decorate(value text) drifted');

SELECT pg_temp.expect_error(
  'SELECT otlet.run_task_subject(''source_query_drift_watch_task'', ''after'')',
  'otlet workload is suspended'
);
SELECT pg_temp.expect_error(
  'SELECT otlet.refresh_semantic_index(''source_query_drift_watch'')',
  'otlet workload is suspended'
);
SELECT pg_temp.expect_error(
  'SELECT * FROM otlet.semantic_index_current_rows(''source_query_drift_watch'')',
  'otlet workload is suspended'
);
SELECT pg_temp.expect_error(
  'SELECT * FROM otlet.semantic_index_plan(''source_query_drift_watch'')',
  'otlet workload is suspended'
);
SELECT pg_temp.expect_error(
  'EXECUTE source_query_drift_cached_customscan',
  'otlet workload is suspended'
);
SELECT pg_temp.expect_error(
  'INSERT INTO otlet.jobs (task_name, subject_id, input, status, claim_token) VALUES (''source_query_drift_watch_task'', ''direct-running'', ''{}''::jsonb, ''running'', ''direct-running-token'')',
  'otlet workload is suspended'
);

DO $body$
DECLARE
  proof source_query_drift_proof%ROWTYPE;
  running_claim_token text;
BEGIN
  SELECT * INTO proof FROM source_query_drift_proof;
  IF EXISTS (
    SELECT 1 FROM otlet.claim_jobs('source_query_drift_model', 1)
  ) THEN
    RAISE EXCEPTION 'drifted queued job was claimable';
  END IF;

  SELECT claim_token
  INTO running_claim_token
  FROM otlet.jobs
  WHERE id = proof.running_job_id;
  BEGIN
    PERFORM 1
    FROM otlet.complete_job(
      job_id => proof.running_job_id,
      output => '{"decision":"late"}'::jsonb,
      raw_output => '{"output":{"decision":"late"},"actions":[]}',
      actions => '[]'::jsonb,
      started_at => now(),
      trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
      model_name => 'source_query_drift_model',
      expected_claim_token => running_claim_token
    );
    RAISE EXCEPTION 'drifted running job completed';
  EXCEPTION WHEN OTHERS THEN
    IF position('otlet workload is suspended' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM otlet.materialize_completed_semantic_job(proof.complete_job_id);
    RAISE EXCEPTION 'drifted output materialized';
  EXCEPTION WHEN OTHERS THEN
    IF position('otlet workload is suspended' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM 1 FROM otlet.dry_run_action(proof.action_id);
    RAISE EXCEPTION 'drifted action retained authority';
  EXCEPTION WHEN OTHERS THEN
    IF position('otlet workload is suspended' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.action_status status
    WHERE status.action_id = proof.action_id
      AND status.authority_status = 'suspended'
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.review_queue queue
    WHERE queue.action_id = proof.action_id
      AND queue.queue_kind = 'suspended_authority'
  ) THEN
    RAISE EXCEPTION 'drifted action status was not suspended';
  END IF;
  IF (SELECT count(*) FROM otlet.outputs WHERE job_id = proof.complete_job_id) <> 1
     OR (SELECT count(*) FROM otlet.inference_receipts WHERE job_id = proof.complete_job_id) <> 1
     OR (SELECT status FROM otlet.jobs WHERE id = proof.running_job_id) <> 'running'
     OR (SELECT status FROM otlet.jobs WHERE id = proof.queued_job_id) <> 'queued' THEN
    RAISE EXCEPTION 'drift rejection mutated historical or pending evidence';
  END IF;
END
$body$;

UPDATE otlet.tasks
SET instruction = 'Pending configured instruction that repair must not promote.'
WHERE name = 'source_query_drift_watch_task';

UPDATE source_query_drift_proof
SET revision_b = otlet.repair_source_query_contract(
  'source_query_drift_watch_task',
  revision_a
);

DO $body$
DECLARE
  proof source_query_drift_proof%ROWTYPE;
  old_definition jsonb;
  new_definition jsonb;
  old_contract jsonb;
  new_contract jsonb;
  repaired_job otlet.jobs%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM source_query_drift_proof;
  SELECT revision.definition
  INTO old_definition
  FROM otlet.workload_revisions revision
  WHERE revision.workload_revision_hash = proof.revision_a;
  SELECT revision.definition
  INTO new_definition
  FROM otlet.workload_revisions revision
  WHERE revision.workload_revision_hash = proof.revision_b;
  old_contract := old_definition #> '{source,query_contract}';
  new_contract := new_definition #> '{source,query_contract}';

  IF proof.revision_b IS NULL OR proof.revision_b = proof.revision_a THEN
    RAISE EXCEPTION 'source contract repair did not create a new revision';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = 'source_query_drift_watch_task'
      AND head.active_workload_revision_hash = proof.revision_b
      AND head.previous_workload_revision_hash = proof.revision_a
  ) THEN
    RAISE EXCEPTION 'repaired source revision was not promoted explicitly';
  END IF;
  IF old_contract #> '{query}' IS DISTINCT FROM new_contract #> '{query}'
     OR old_contract -> 'declared_sources' IS DISTINCT FROM new_contract -> 'declared_sources'
     OR old_contract -> 'relations' IS DISTINCT FROM new_contract -> 'relations'
     OR old_contract -> 'functions' IS NOT DISTINCT FROM new_contract -> 'functions'
     OR otlet.source_query_contract_error(old_contract, true) IS NULL
     OR otlet.source_query_contract_error(new_contract, true) IS NOT NULL THEN
    RAISE EXCEPTION 'repair did not preserve query identity and recapture only drifted dependencies';
  END IF;
  IF new_definition #>> '{task,instruction}' IS DISTINCT FROM
       old_definition #>> '{task,instruction}'
     OR (SELECT instruction FROM otlet.tasks WHERE name = 'source_query_drift_watch_task')
       IS DISTINCT FROM 'Pending configured instruction that repair must not promote.'
     OR NOT COALESCE((
       SELECT status.configured_drift
       FROM otlet.workload_revision_status status
       WHERE status.task_name = 'source_query_drift_watch_task'
     ), false) THEN
    RAISE EXCEPTION 'source repair promoted or erased unrelated configured task changes';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.source_query_dependency_status
    WHERE task_name = 'source_query_drift_watch_task'
      AND workload_revision_hash = proof.revision_b
      AND dependency_status = 'ready'
      AND dependency_error IS NULL
  ) THEN
    RAISE EXCEPTION 'repaired source dependency status is not ready';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations materialization
    WHERE materialization.id = proof.materialization_id
      AND materialization.stale
      AND materialization.stale_reason = 'contract_changed'
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.action_status status
    WHERE status.action_id = proof.action_id
      AND status.authority_status = 'suspended'
  ) THEN
    RAISE EXCEPTION 'repair revived old semantic or action authority';
  END IF;

  IF otlet.run_task_subject('source_query_drift_watch_task', 'after', proof.revision_b) <> 1 THEN
    RAISE EXCEPTION 'repaired source workload did not resume admission';
  END IF;
  SELECT * INTO repaired_job
  FROM otlet.claim_jobs('source_query_drift_model', 1);
  IF repaired_job.id IS NULL
     OR repaired_job.subject_id <> 'after'
     OR repaired_job.workload_revision_hash <> proof.revision_b THEN
    RAISE EXCEPTION 'repaired source workload did not resume claims on the new revision';
  END IF;
END
$body$;

DROP TABLE source_query_drift.source;
CREATE TABLE source_query_drift.source (
  id text PRIMARY KEY,
  payload text NOT NULL,
  visible boolean NOT NULL DEFAULT true
);
INSERT INTO source_query_drift.source (id, payload)
VALUES
  ('after', 'AFTER'),
  ('complete', 'COMPLETE'),
  ('queued', 'QUEUED'),
  ('running', 'RUNNING');
ALTER TABLE source_query_drift.source ENABLE ROW LEVEL SECURITY;
ALTER TABLE source_query_drift.source FORCE ROW LEVEL SECURITY;
CREATE POLICY visible_rows ON source_query_drift.source
USING (visible);

UPDATE source_query_drift_proof
SET revision_c = otlet.repair_source_query_contract(
  'source_query_drift_watch_task',
  revision_b
);

DO $body$
DECLARE
  proof source_query_drift_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM source_query_drift_proof;
  IF proof.revision_c IS NULL OR proof.revision_c = proof.revision_b
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.workload_revision_heads head
       WHERE head.task_name = 'source_query_drift_watch_task'
         AND head.active_workload_revision_hash = proof.revision_c
         AND head.previous_workload_revision_hash = proof.revision_b
     ) THEN
    RAISE EXCEPTION 'relation recreation repair did not promote a derived revision';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'source_query_drift.source'::regclass
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgfoid = 'otlet.mark_semantic_stale_trigger()'::regprocedure
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'source_query_drift.source'::regclass
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgfoid = 'otlet.watch_change_trigger()'::regprocedure
  ) THEN
    RAISE EXCEPTION 'row source repair did not restore invalidation triggers';
  END IF;

  UPDATE source_query_drift.source
  SET payload = 'AFTER-RECREATED'
  WHERE id = 'after';
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.jobs job
    WHERE job.task_name = 'source_query_drift_watch_task'
      AND job.workload_revision_hash = proof.revision_c
      AND job.subject_id = 'after'
      AND job.status = 'queued'
  ) THEN
    RAISE EXCEPTION 'restored row watch trigger did not enqueue the changed source row';
  END IF;
END
$body$;

DROP TABLE source_query_drift.pair_left;
CREATE TABLE source_query_drift.pair_left (id text PRIMARY KEY);
INSERT INTO source_query_drift.pair_left VALUES ('left');

DO $body$
DECLARE
  old_revision text;
  repaired_revision text;
BEGIN
  SELECT head.active_workload_revision_hash
  INTO old_revision
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = 'source_query_pair_repair_task';
  repaired_revision := otlet.repair_source_query_contract(
    'source_query_pair_repair_task',
    old_revision
  );
  IF repaired_revision IS NULL OR repaired_revision = old_revision THEN
    RAISE EXCEPTION 'pair relation recreation repair did not create a revision';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'source_query_drift.pair_left'::regclass
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgfoid = 'otlet.mark_semantic_stale_trigger()'::regprocedure
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'source_query_drift.pair_right'::regclass
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgfoid = 'otlet.mark_semantic_stale_trigger()'::regprocedure
  ) THEN
    RAISE EXCEPTION 'pair source repair did not restore invalidation triggers';
  END IF;
END
$body$;

SELECT 'pair=exact|writer=rejected|binding=qualified|relation=suspended|schema=suspended|privilege=suspended|rls=suspended|function=suspended|customscan=cached_fail_closed|lifecycle=fail_closed|repair=promoted|repair_config=isolated|triggers=restored';

ROLLBACK;
SQL
