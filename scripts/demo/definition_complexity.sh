log "Checking definition complexity bounds"

definition_complexity_contract="$(psql_exec -qAt \
  -v model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" <<'SQL' | tail -n 1
BEGIN;

CREATE TEMP TABLE definition_complexity_fixture AS
SELECT :'model_name'::text AS model_name, :'strong_model_name'::text AS strong_model_name;

CREATE TEMP TABLE definition_complexity_results (
  test_order integer PRIMARY KEY,
  test_name text NOT NULL UNIQUE
);

CREATE FUNCTION pg_temp.expect_complexity_error(
  test_order integer,
  test_name text,
  statement text,
  expected text
) RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  actual text;
BEGIN
  BEGIN
    EXECUTE expect_complexity_error.statement;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS actual = MESSAGE_TEXT;
    IF position(expect_complexity_error.expected IN actual) = 0 THEN
      RAISE EXCEPTION 'expected % for %, got %',
        expect_complexity_error.expected,
        expect_complexity_error.test_name,
        actual;
    END IF;
    INSERT INTO definition_complexity_results VALUES (
      expect_complexity_error.test_order,
      expect_complexity_error.test_name
    );
    RETURN;
  END;
  RAISE EXCEPTION 'expected % to fail with %',
    expect_complexity_error.test_name,
    expect_complexity_error.expected;
END
$function$;

CREATE TABLE public.otlet_definition_complexity_source (
  id text PRIMARY KEY,
  payload text NOT NULL
);

SELECT otlet.create_task(
  'definition_complexity_baseline',
  NULL,
  'Return an empty object',
  '{"type":"object"}'::jsonb,
  (SELECT model_name FROM definition_complexity_fixture)
) \g /dev/null
SELECT otlet.ensure_active_workload_revision('definition_complexity_baseline') \g /dev/null

SELECT otlet.create_watch(
  watch_name => 'definition_complexity_watch',
  kind => 'row',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => (SELECT model_name FROM definition_complexity_fixture),
  table_name => 'public.otlet_definition_complexity_source'::regclass,
  subject_column => 'id',
  action_types => ARRAY['update_row'],
  input_columns => ARRAY['payload']::text[]
) \g /dev/null

SELECT otlet.register_action_target(
  'definition_complexity_target',
  'public.otlet_definition_complexity_source'::regclass,
  'id',
  ARRAY['payload']::name[]
) \g /dev/null

SELECT otlet.register_action_workflow_policy(
  'definition_complexity_watch_task',
  'update_row',
  'definition_complexity_target',
  'bounded_mutation',
  'evaluated'
) \g /dev/null

DO $body$
BEGIN
  EXECUTE
    'ALTER TABLE public.otlet_definition_complexity_source ' ||
    'ALTER COLUMN payload SET DEFAULT $q$' || repeat(chr(39), 400000) || '$q$';
END
$body$;

CREATE TEMP TABLE definition_complexity_snapshot AS
SELECT
  pg_backend_pid() AS backend_pid,
  (SELECT to_jsonb(task) FROM otlet.tasks task
   WHERE task.name = 'definition_complexity_baseline') AS task_definition,
  (SELECT active_workload_revision_hash FROM otlet.workload_revision_heads
   WHERE task_name = 'definition_complexity_baseline') AS active_revision,
  otlet.export_watch('definition_complexity_watch') AS watch_definition,
  (SELECT jsonb_agg(trigger.tgname ORDER BY trigger.tgname)
   FROM pg_trigger trigger
   WHERE trigger.tgrelid = 'public.otlet_definition_complexity_source'::regclass
     AND NOT trigger.tgisinternal) AS watch_triggers,
  (SELECT default_runtime_options FROM otlet.production_policy WHERE name = 'default') AS default_runtime_options,
  (SELECT count(*) FROM otlet.tasks) AS task_count,
  (SELECT count(*) FROM otlet.workload_revisions) AS revision_count,
  (SELECT count(*) FROM otlet.watches) AS watch_count,
  (SELECT count(*) FROM otlet.action_targets) AS action_target_count,
  (SELECT count(*) FROM otlet.action_workflow_policies) AS workflow_policy_count,
  (SELECT count(*) FROM otlet.semantic_indexes) AS row_index_count,
  (SELECT count(*) FROM otlet.semantic_join_indexes) AS pair_index_count,
  (SELECT count(*) FROM otlet.jobs) AS job_count,
  (SELECT count(*) FROM otlet.semantic_materializations) AS materialization_count;

SELECT pg_temp.expect_complexity_error(
  1,
  'instruction',
  $statement$
    SELECT otlet.create_task(
      'definition_complexity_instruction', NULL,
      repeat('i', ((SELECT max_instruction_bytes FROM otlet.definition_complexity_limits) + 1)::integer),
      '{"type":"object"}'::jsonb,
      (SELECT model_name FROM definition_complexity_fixture)
    )
  $statement$,
  'instruction exceeds'
);

SELECT pg_temp.expect_complexity_error(
  2,
  'query',
  $statement$
    SELECT otlet.create_task(
      'definition_complexity_query',
      'SELECT ''subject''::text AS subject_id, ''{}''::jsonb AS input' ||
        repeat(' ', ((SELECT max_query_bytes FROM otlet.definition_complexity_limits) + 1)::integer),
      'Return an empty object',
      '{"type":"object"}'::jsonb,
      (SELECT model_name FROM definition_complexity_fixture)
    )
  $statement$,
  'query exceeds'
);

SELECT pg_temp.expect_complexity_error(
  3,
  'schema',
  $statement$
    SELECT otlet.create_task(
      'definition_complexity_schema', NULL, 'Return an empty object',
      jsonb_build_object(
        'type', 'object',
        'description', repeat('s', (SELECT max_output_schema_bytes::integer FROM otlet.definition_complexity_limits))
      ),
      (SELECT model_name FROM definition_complexity_fixture)
    )
  $statement$,
  'output schema exceeds'
);

SELECT pg_temp.expect_complexity_error(
  4,
  'runtime',
  $statement$
    SELECT otlet.create_task(
      'definition_complexity_runtime', NULL, 'Return an empty object',
      '{"type":"object"}'::jsonb,
      (SELECT model_name FROM definition_complexity_fixture),
      jsonb_build_object(
        'padding', repeat('r', (SELECT max_runtime_json_bytes::integer FROM otlet.definition_complexity_limits))
      )
    )
  $statement$,
  'runtime JSON exceeds'
);

SELECT pg_temp.expect_complexity_error(
  5,
  'decision',
  $statement$
    SELECT otlet.create_task(
      task_name => 'definition_complexity_decision',
      input_query => NULL,
      instruction => 'Return an empty object',
      output_schema => '{"type":"object"}'::jsonb,
      model_name => (SELECT model_name FROM definition_complexity_fixture),
      decision_contract => jsonb_build_object(
        'padding', repeat('d', (SELECT max_decision_contract_bytes::integer FROM otlet.definition_complexity_limits))
      )
    )
  $statement$,
  'decision contract exceeds'
);

SELECT pg_temp.expect_complexity_error(
  6,
  'depth',
  $statement$
    WITH RECURSIVE nested(depth, schema) AS (
      SELECT 0, '{"type":"object"}'::jsonb
      UNION ALL
      SELECT depth + 1, jsonb_build_object('type', 'array', 'items', schema)
      FROM nested
      WHERE depth < (SELECT max_json_depth FROM otlet.definition_complexity_limits)
    )
    SELECT otlet.create_task(
      'definition_complexity_depth', NULL, 'Return an empty object',
      (SELECT schema FROM nested ORDER BY depth DESC LIMIT 1),
      (SELECT model_name FROM definition_complexity_fixture)
    )
  $statement$,
  'JSON nesting exceeds'
);

SELECT pg_temp.expect_complexity_error(
  7,
  'nodes',
  $statement$
    SELECT otlet.create_task(
      'definition_complexity_nodes', NULL, 'Return an empty object',
      '{"type":"object"}'::jsonb,
      (SELECT model_name FROM definition_complexity_fixture),
      jsonb_build_object('nodes', (
        SELECT jsonb_agg('null'::jsonb)
        FROM generate_series(
          1,
          ((SELECT max_json_nodes FROM otlet.definition_complexity_limits) + 1)::integer
        )
      ))
    )
  $statement$,
  'JSON node count exceeds'
);

SELECT pg_temp.expect_complexity_error(
  8,
  'identifiers',
  $statement$
    WITH properties AS (
      SELECT jsonb_object_agg('identifier_' || identifier, '{}'::jsonb) AS value
      FROM generate_series(
        1,
        ((SELECT max_identifiers FROM otlet.definition_complexity_limits) + 1)::integer
      ) identifier
    )
    SELECT otlet.create_task(
      'definition_complexity_identifiers', NULL, 'Return an empty object',
      jsonb_build_object('type', 'object', 'properties', properties.value),
      (SELECT model_name FROM definition_complexity_fixture)
    )
    FROM properties
  $statement$,
  'identifier count exceeds'
);

SELECT pg_temp.expect_complexity_error(
  9,
  'query_identifiers',
  $statement$
    WITH generated_query AS (
      SELECT
        'SELECT ''subject''::text AS subject_id, ''{}''::jsonb AS input' ||
        string_agg(', 1 AS identifier_' || identifier, '') AS value
      FROM generate_series(
        1,
        ((SELECT max_query_identifiers FROM otlet.definition_complexity_limits) + 1)::integer
      ) identifier
    )
    SELECT otlet.create_task(
      'definition_complexity_query_identifiers', generated_query.value,
      'Return an empty object', '{"type":"object"}'::jsonb,
      (SELECT model_name FROM definition_complexity_fixture)
    )
    FROM generated_query
  $statement$,
  'query identifier count exceeds'
);

SELECT pg_temp.expect_complexity_error(
  10,
  'prompt',
  $statement$
    SELECT otlet.create_task(
      'definition_complexity_prompt', NULL, repeat('i', 50000),
      jsonb_build_object('type', 'object', 'description', repeat('s', 220000)),
      (SELECT model_name FROM definition_complexity_fixture)
    )
  $statement$,
  'prompt template exceeds'
);

SELECT pg_temp.expect_complexity_error(
  11,
  'raw_insert',
  $statement$
    INSERT INTO otlet.tasks (
      name, instruction, output_schema, model_name, runtime_options, input_shaping, decision_contract
    ) VALUES (
      'definition_complexity_raw_insert',
      repeat('i', ((SELECT max_instruction_bytes FROM otlet.definition_complexity_limits) + 1)::integer),
      '{"type":"object"}'::jsonb,
      (SELECT model_name FROM definition_complexity_fixture),
      '{}'::jsonb,
      '{}'::jsonb,
      '{}'::jsonb
    )
  $statement$,
  'instruction exceeds'
);

SELECT pg_temp.expect_complexity_error(
  12,
  'raw_update',
  $statement$
    UPDATE otlet.tasks
    SET instruction = repeat(
      'i',
      ((SELECT max_instruction_bytes FROM otlet.definition_complexity_limits) + 1)::integer
    )
    WHERE name = 'definition_complexity_baseline'
  $statement$,
  'instruction exceeds'
);

SELECT pg_temp.expect_complexity_error(
  13,
  'create_watch',
  $statement$
    SELECT otlet.create_watch(
      watch_name => 'definition_complexity_rejected_watch',
      kind => 'row',
      instruction => repeat(
        'i',
        ((SELECT max_instruction_bytes FROM otlet.definition_complexity_limits) + 1)::integer
      ),
      output_schema => '{"type":"object"}'::jsonb,
      model_name => (SELECT model_name FROM definition_complexity_fixture),
      table_name => 'public.otlet_definition_complexity_source'::regclass,
      subject_column => 'id'
    )
  $statement$,
  'instruction exceeds'
);

SELECT pg_temp.expect_complexity_error(
  14,
  'import_watch',
  $statement$
    SELECT otlet.import_watch(
      jsonb_set(
        otlet.export_watch('definition_complexity_watch'),
        '{instruction}',
        to_jsonb(repeat(
          'i',
          ((SELECT max_instruction_bytes FROM otlet.definition_complexity_limits) + 1)::integer
        ))
      ),
      true
    )
  $statement$,
  'instruction exceeds'
);

SELECT pg_temp.expect_complexity_error(
  15,
  'ask',
  $statement$
    SELECT * FROM otlet.ask(
      (SELECT model_name FROM definition_complexity_fixture),
      repeat('i', ((SELECT max_instruction_bytes FROM otlet.definition_complexity_limits) + 1)::integer),
      '{}'::jsonb,
      '{"type":"object"}'::jsonb,
      '{}'::jsonb,
      1
    )
  $statement$,
  'instruction exceeds'
);

SELECT pg_temp.expect_complexity_error(
  16,
  'enqueue_ask',
  $statement$
    SELECT otlet.enqueue_ask(
      (SELECT model_name FROM definition_complexity_fixture),
      repeat('i', ((SELECT max_instruction_bytes FROM otlet.definition_complexity_limits) + 1)::integer),
      '{}'::jsonb,
      '{"type":"object"}'::jsonb,
      '{}'::jsonb
    )
  $statement$,
  'instruction exceeds'
);

SELECT pg_temp.expect_complexity_error(
  17,
  'selection',
  $statement$
    SELECT otlet.set_model_selection_policy(
      'definition_complexity_baseline',
      (SELECT model_name FROM definition_complexity_fixture),
      (SELECT strong_model_name FROM definition_complexity_fixture),
      jsonb_build_object('nodes', (
        SELECT jsonb_agg('null'::jsonb)
        FROM generate_series(
          1,
          ((SELECT max_json_nodes FROM otlet.definition_complexity_limits) + 1)::integer
        )
      ))
    )
  $statement$,
  'JSON node count exceeds'
);

SELECT pg_temp.expect_complexity_error(
  18,
  'decision_preset',
  $statement$
    INSERT INTO otlet.decision_rule_presets (name, decision_contract)
    VALUES (
      'definition_complexity_rejected_preset',
      jsonb_build_object(
        'padding',
        repeat('d', (SELECT max_decision_contract_bytes::integer FROM otlet.definition_complexity_limits))
      )
    )
  $statement$,
  'decision contract exceeds'
);

SELECT pg_temp.expect_complexity_error(
  19,
  'default_runtime',
  $statement$
    UPDATE otlet.production_policy
    SET default_runtime_options = jsonb_build_object(
      'padding',
      repeat('r', (SELECT max_runtime_json_bytes::integer FROM otlet.definition_complexity_limits))
    )
    WHERE name = 'default'
  $statement$,
  'runtime JSON exceeds'
);

SELECT pg_temp.expect_complexity_error(
  20,
  'revision',
  $statement$
    WITH active AS (
      SELECT revision.definition
      FROM otlet.workload_revision_heads head
      JOIN otlet.workload_revisions revision
        ON revision.task_name = head.task_name
       AND revision.workload_revision_hash = head.active_workload_revision_hash
      WHERE head.task_name = 'definition_complexity_baseline'
    ), rejected AS (
      SELECT definition || jsonb_build_object('nodes', (
        SELECT jsonb_agg('null'::jsonb)
        FROM generate_series(
          1,
          ((SELECT max_json_nodes FROM otlet.definition_complexity_limits) + 1)::integer
        )
      )) AS definition
      FROM active
    )
    INSERT INTO otlet.workload_revisions (workload_revision_hash, task_name, definition)
    SELECT
      otlet.identity_hash('workload_revision', definition),
      'definition_complexity_baseline',
      definition
    FROM rejected
  $statement$,
  'JSON node count exceeds'
);

SELECT pg_temp.expect_complexity_error(
  21,
  'input_shaping',
  $statement$
    SELECT otlet.create_task(
      task_name => 'definition_complexity_input_shaping',
      input_query => NULL,
      instruction => 'Return an empty object',
      output_schema => '{"type":"object"}'::jsonb,
      model_name => (SELECT model_name FROM definition_complexity_fixture),
      input_shaping => jsonb_build_object(
        'padding',
        repeat('s', (SELECT max_input_shaping_bytes::integer FROM otlet.definition_complexity_limits))
      )
    )
  $statement$,
  'input shaping exceeds'
);

SELECT pg_temp.expect_complexity_error(
  22,
  'definition',
  $statement$
    SELECT otlet.create_watch(
      watch_name => 'definition_complexity_full_definition',
      kind => 'row',
      instruction => 'Return an empty object',
      output_schema => '{"type":"object"}'::jsonb,
      model_name => (SELECT model_name FROM definition_complexity_fixture),
      table_name => 'public.otlet_definition_complexity_source'::regclass,
      subject_column => 'id',
      selection_policy => jsonb_build_object(
        'padding',
        repeat('f', (SELECT max_definition_bytes::integer FROM otlet.definition_complexity_limits))
      )
    )
  $statement$,
  'definition exceeds'
);

SELECT pg_temp.expect_complexity_error(
  23,
  'raw_watch',
  $statement$
    UPDATE otlet.watches
    SET selection_policy = jsonb_build_object('nodes', (
      SELECT jsonb_agg('null'::jsonb)
      FROM generate_series(
        1,
        ((SELECT max_json_nodes FROM otlet.definition_complexity_limits) + 1)::integer
      )
    ))
    WHERE name = 'definition_complexity_watch'
  $statement$,
  'JSON node count exceeds'
);

SELECT pg_temp.expect_complexity_error(
  24,
  'raw_selection',
  $statement$
    INSERT INTO otlet.model_selection_policies (
      task_name, cheap_model_name, strong_model_name, accept_field_checks
    ) VALUES (
      'definition_complexity_baseline',
      (SELECT model_name FROM definition_complexity_fixture),
      (SELECT strong_model_name FROM definition_complexity_fixture),
      jsonb_build_object('nodes', (
        SELECT jsonb_agg('null'::jsonb)
        FROM generate_series(
          1,
          ((SELECT max_json_nodes FROM otlet.definition_complexity_limits) + 1)::integer
        )
      ))
    )
  $statement$,
  'JSON node count exceeds'
);

SELECT pg_temp.expect_complexity_error(
  25,
  'byte_precedence',
  $statement$
    SELECT otlet.create_task(
      'definition_complexity_byte_precedence',
      NULL,
      'Return an empty object',
      '{"type":"object"}'::jsonb,
      (SELECT model_name FROM definition_complexity_fixture),
      jsonb_build_object('nodes', (
        SELECT jsonb_agg(repeat('x', 16))
        FROM generate_series(
          1,
          ((SELECT max_json_nodes FROM otlet.definition_complexity_limits) + 1)::integer
        )
      ))
    )
  $statement$,
  'runtime JSON exceeds'
);

SELECT pg_temp.expect_complexity_error(
  26,
  'resolved_query',
  $statement$
    WITH generated AS (
      SELECT
        'SELECT ''subject''::text AS subject_id, jsonb_build_object(''value'', $q$' ||
        repeat(chr(39), 140000) ||
        '$q$) AS input' AS query
    )
    SELECT otlet.create_task(
      'definition_complexity_resolved_query',
      generated.query,
      'Return an empty object',
      '{"type":"object"}'::jsonb,
      (SELECT model_name FROM definition_complexity_fixture)
    )
    FROM generated
    CROSS JOIN otlet.definition_complexity_limits limits
    WHERE octet_length(generated.query) <= limits.max_query_bytes
  $statement$,
  'query exceeds'
);

DO $body$
DECLARE
  calls text;
BEGIN
  SELECT string_agg('abs(1)', ',')
  INTO calls
  FROM generate_series(
    1,
    ((SELECT max_identifiers FROM otlet.definition_complexity_limits) + 1)::integer
  );
  EXECUTE
    'CREATE FUNCTION public.otlet_definition_complexity_dependency() RETURNS integer ' ||
    'LANGUAGE sql IMMUTABLE BEGIN ATOMIC SELECT (ARRAY[' || calls || '])[1]; END';
END
$body$;

SELECT pg_temp.expect_complexity_error(
  27,
  'dependency_work',
  $statement$
    SELECT otlet.create_task(
      'definition_complexity_dependency_work',
      'SELECT ''dependency''::text AS subject_id, ' ||
        'jsonb_build_object(''value'', public.otlet_definition_complexity_dependency()) AS input',
      'Return an empty object',
      '{"type":"object"}'::jsonb,
      (SELECT model_name FROM definition_complexity_fixture)
    )
  $statement$,
  'source dependency'
);

SELECT pg_temp.expect_complexity_error(
  28,
  'action_workflow',
  $statement$
    SELECT otlet.register_action_workflow_policy(
      'definition_complexity_watch_task',
      'update_row',
      'definition_complexity_target',
      'bounded_mutation',
      'evaluated'
    )
  $statement$,
  'action target catalog text exceeds'
);

SELECT pg_temp.expect_complexity_error(
  29,
  'action_status_drift',
  $statement$
    SELECT *
    FROM otlet.action_workflow_policy_status
    WHERE task_name = 'definition_complexity_watch_task'
  $statement$,
  'action target catalog text exceeds'
);

ALTER TABLE public.otlet_definition_complexity_source
ALTER COLUMN payload DROP DEFAULT;

SELECT pg_temp.expect_complexity_error(
  30,
  'raw_action_policy',
  $statement$
    INSERT INTO otlet.action_workflow_policies (
      task_name,
      action_type,
      target_name,
      subject_namespace,
      authority_mode,
      evaluation_status,
      task_contract_hash,
      target_contract,
      target_contract_hash,
      policy_hash
    ) VALUES (
      'definition_complexity_watch_task',
      'update_row',
      'definition_complexity_target',
      'public.otlet_definition_complexity_source',
      'bounded_mutation',
      'evaluated',
      otlet.identity_hash('definition_complexity_fixture', '"task"'::jsonb),
      jsonb_build_object('nodes', (
        SELECT jsonb_agg('null'::jsonb)
        FROM generate_series(
          1,
          ((SELECT max_json_nodes FROM otlet.definition_complexity_limits) + 1)::integer
        )
      )),
      otlet.identity_hash('definition_complexity_fixture', '"target"'::jsonb),
      otlet.identity_hash('definition_complexity_fixture', '"policy"'::jsonb)
    )
  $statement$,
  'JSON node count exceeds'
);

SELECT pg_temp.expect_complexity_error(
  31,
  'raw_action_policy_update',
  $statement$
    UPDATE otlet.action_workflow_policies
    SET subject_namespace = repeat(
      's',
      (SELECT max_definition_bytes::integer FROM otlet.definition_complexity_limits)
    )
    WHERE task_name = 'definition_complexity_watch_task'
      AND action_type = 'update_row'
  $statement$,
  'definition exceeds'
);

DO $body$
DECLARE
  default_items text;
BEGIN
  SELECT string_agg('1', ',')
  INTO default_items
  FROM generate_series(1, 30000);
  EXECUTE
    'CREATE FUNCTION public.otlet_definition_complexity_default(' ||
    'unused integer[] DEFAULT ARRAY[' || default_items || ']) RETURNS integer ' ||
    'LANGUAGE sql IMMUTABLE BEGIN ATOMIC SELECT 1; END';
END
$body$;

SELECT pg_temp.expect_complexity_error(
  32,
  'function_defaults',
  $statement$
    SELECT otlet.create_task(
      'definition_complexity_function_defaults',
      'SELECT ''default''::text AS subject_id, ' ||
        'jsonb_build_object(''value'', public.otlet_definition_complexity_default()) AS input',
      'Return an empty object',
      '{"type":"object"}'::jsonb,
      (SELECT model_name FROM definition_complexity_fixture)
    )
  $statement$,
  'source dependency text exceeds'
);

DO $body$
DECLARE
  snapshot definition_complexity_snapshot%ROWTYPE;
BEGIN
  SELECT * INTO snapshot FROM definition_complexity_snapshot;
  IF pg_backend_pid() <> snapshot.backend_pid
     OR (SELECT to_jsonb(task) FROM otlet.tasks task
         WHERE task.name = 'definition_complexity_baseline') IS DISTINCT FROM snapshot.task_definition
     OR (SELECT active_workload_revision_hash FROM otlet.workload_revision_heads
         WHERE task_name = 'definition_complexity_baseline') IS DISTINCT FROM snapshot.active_revision
     OR otlet.export_watch('definition_complexity_watch') IS DISTINCT FROM snapshot.watch_definition
     OR (SELECT jsonb_agg(trigger.tgname ORDER BY trigger.tgname)
         FROM pg_trigger trigger
         WHERE trigger.tgrelid = 'public.otlet_definition_complexity_source'::regclass
           AND NOT trigger.tgisinternal) IS DISTINCT FROM snapshot.watch_triggers
     OR (SELECT default_runtime_options FROM otlet.production_policy
         WHERE name = 'default') IS DISTINCT FROM snapshot.default_runtime_options
     OR (SELECT count(*) FROM otlet.tasks) <> snapshot.task_count
     OR (SELECT count(*) FROM otlet.workload_revisions) <> snapshot.revision_count
     OR (SELECT count(*) FROM otlet.watches) <> snapshot.watch_count
     OR (SELECT count(*) FROM otlet.action_targets) <> snapshot.action_target_count
     OR (SELECT count(*) FROM otlet.action_workflow_policies) <> snapshot.workflow_policy_count
     OR (SELECT count(*) FROM otlet.semantic_indexes) <> snapshot.row_index_count
     OR (SELECT count(*) FROM otlet.semantic_join_indexes) <> snapshot.pair_index_count
     OR (SELECT count(*) FROM otlet.jobs) <> snapshot.job_count
     OR (SELECT count(*) FROM otlet.semantic_materializations) <> snapshot.materialization_count
     OR EXISTS (SELECT 1 FROM otlet.model_selection_policies
                WHERE task_name = 'definition_complexity_baseline') THEN
    RAISE EXCEPTION 'rejected definition changed durable state';
  END IF;
END
$body$;

SELECT otlet.create_task(
  'definition_complexity_boundary',
  NULL,
  repeat('i', 50000),
  jsonb_build_object('type', 'object', 'description', repeat('s', 190000)),
  (SELECT model_name FROM definition_complexity_fixture)
) \g /dev/null
SELECT otlet.ensure_active_workload_revision('definition_complexity_boundary') \g /dev/null

SELECT concat_ws('|',
  (SELECT concat_ws(',',
    max_instruction_bytes,
    max_query_bytes,
    max_output_schema_bytes,
    max_runtime_json_bytes,
    max_input_shaping_bytes,
    max_decision_contract_bytes,
    max_definition_bytes,
    max_json_depth,
    max_json_nodes,
    max_identifiers,
    max_query_identifiers,
    max_prompt_template_bytes
  ) FROM otlet.definition_complexity_limits),
  (SELECT string_agg(test_name, ',' ORDER BY test_order)
   FROM definition_complexity_results),
  (SELECT (pg_backend_pid() = backend_pid)::text FROM definition_complexity_snapshot),
  (SELECT (count(*) = 0)::text FROM otlet.verify_invariants()),
  (SELECT (
     report.error IS NULL
     AND report.prompt_template_bytes <= limits.max_prompt_template_bytes
     AND report.instruction_bytes = 50000
   )::text
   FROM otlet.definition_complexity_status report
   CROSS JOIN otlet.definition_complexity_limits limits
   WHERE report.task_name = 'definition_complexity_boundary')
);

ROLLBACK;
SQL
)"

echo "definition_complexity_contract=$definition_complexity_contract"
expected_definition_complexity_contract="65536,262144,262144,65536,65536,262144,1048576,32,8192,4096,4096,262144|instruction,query,schema,runtime,decision,depth,nodes,identifiers,query_identifiers,prompt,raw_insert,raw_update,create_watch,import_watch,ask,enqueue_ask,selection,decision_preset,default_runtime,revision,input_shaping,definition,raw_watch,raw_selection,byte_precedence,resolved_query,dependency_work,action_workflow,action_status_drift,raw_action_policy,raw_action_policy_update,function_defaults|true|true|true"
[ "$definition_complexity_contract" = "$expected_definition_complexity_contract" ] || {
  echo "Expected bounded atomic definition authoring, got $definition_complexity_contract" >&2
  exit 1
}
