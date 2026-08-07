ALTER TABLE otlet.administrative_change_events
DROP CONSTRAINT administrative_change_events_object_type_check,
ADD CONSTRAINT administrative_change_events_object_type_check CHECK (
  object_type IN (
    'model',
    'task',
    'watch',
    'selection',
    'action_policy',
    'access_policy',
    'retention',
    'workload_pack'
  )
);

CREATE TABLE otlet.workload_pack_definitions (
  pack_hash text PRIMARY KEY CHECK (
    pack_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  spec_hash text NOT NULL CHECK (
    spec_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  pack_name text NOT NULL CHECK (pack_name ~ '^[a-z0-9][a-z0-9_-]*$'),
  pack_version integer NOT NULL CHECK (pack_version > 0),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  baseline_spec_hash text NOT NULL CHECK (
    baseline_spec_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  baseline_workload_revision_hash text NOT NULL,
  candidate_workload_revision_hash text NOT NULL,
  prepared_event_id bigint NOT NULL UNIQUE
    REFERENCES otlet.administrative_change_events(event_id),
  prepared_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (pack_name, pack_version),
  FOREIGN KEY (task_name, baseline_workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  FOREIGN KEY (task_name, candidate_workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash)
);

CREATE TABLE otlet.workload_pack_events (
  event_id bigserial PRIMARY KEY,
  event_hash text NOT NULL UNIQUE CHECK (
    event_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  event_kind text NOT NULL CHECK (event_kind IN ('apply', 'rollback')),
  application_pack_hash text NOT NULL
    REFERENCES otlet.workload_pack_definitions(pack_hash),
  pack_name text NOT NULL,
  pack_version integer NOT NULL CHECK (pack_version > 0),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  prior_pack_hash text CHECK (
    prior_pack_hash IS NULL
    OR prior_pack_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  result_pack_hash text NOT NULL CHECK (
    result_pack_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  prior_spec_hash text CHECK (
    prior_spec_hash IS NULL
    OR prior_spec_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  result_spec_hash text NOT NULL CHECK (
    result_spec_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  prior_definition jsonb CHECK (
    prior_definition IS NULL OR jsonb_typeof(prior_definition) = 'object'
  ),
  result_definition jsonb NOT NULL CHECK (
    jsonb_typeof(result_definition) = 'object'
  ),
  prior_workload_revision_hash text,
  result_workload_revision_hash text NOT NULL,
  predecessor_event_hash text REFERENCES otlet.workload_pack_events(event_hash),
  rollback_of_event_hash text REFERENCES otlet.workload_pack_events(event_hash),
  governance_event_hash text UNIQUE
    REFERENCES otlet.workload_acceptance_events(event_hash),
  administrative_event_id bigint NOT NULL UNIQUE
    REFERENCES otlet.administrative_change_events(event_id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (
    (prior_definition IS NULL) = (prior_pack_hash IS NULL)
    AND (prior_definition IS NULL) = (prior_spec_hash IS NULL)
    AND (prior_definition IS NULL) = (prior_workload_revision_hash IS NULL)
  ),
  CHECK (
    (event_kind = 'apply' AND rollback_of_event_hash IS NULL)
    OR (event_kind = 'rollback' AND rollback_of_event_hash IS NOT NULL)
  ),
  FOREIGN KEY (task_name, prior_workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  FOREIGN KEY (task_name, result_workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash)
);

CREATE UNIQUE INDEX workload_pack_events_one_apply_idx
ON otlet.workload_pack_events (application_pack_hash)
WHERE event_kind = 'apply';

CREATE UNIQUE INDEX workload_pack_events_one_successor_idx
ON otlet.workload_pack_events (predecessor_event_hash)
WHERE predecessor_event_hash IS NOT NULL;

CREATE UNIQUE INDEX workload_pack_events_one_rollback_idx
ON otlet.workload_pack_events (rollback_of_event_hash)
WHERE rollback_of_event_hash IS NOT NULL;

CREATE INDEX workload_pack_events_latest_idx
ON otlet.workload_pack_events (pack_name, event_id DESC);

CREATE FUNCTION otlet.guard_workload_pack_storage() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT'
     AND current_setting('otlet.workload_pack_append', true) = 'on' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'otlet workload pack history is append only';
END;
$$;

CREATE TRIGGER workload_pack_definitions_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.workload_pack_definitions
FOR EACH ROW EXECUTE FUNCTION otlet.guard_workload_pack_storage();

CREATE TRIGGER workload_pack_definitions_truncate_guard
BEFORE TRUNCATE ON otlet.workload_pack_definitions
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_workload_pack_storage();

CREATE TRIGGER workload_pack_events_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.workload_pack_events
FOR EACH ROW EXECUTE FUNCTION otlet.guard_workload_pack_storage();

CREATE TRIGGER workload_pack_events_truncate_guard
BEFORE TRUNCATE ON otlet.workload_pack_events
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_workload_pack_storage();

DO $migration$
DECLARE
  signature regprocedure;
  definition text;
  rewritten text;
BEGIN
  FOREACH signature IN ARRAY ARRAY[
    'otlet.create_watch(text,text,text,jsonb,text,regclass,text,text,text,jsonb,jsonb,jsonb,text[],text,jsonb,jsonb,integer,text[],jsonb)'::regprocedure,
    'otlet.register_action_workflow_policy(text,text,text,text,text)'::regprocedure,
    'otlet.disable_action_workflow_policy(text,text)'::regprocedure
  ]
  LOOP
    definition := pg_catalog.pg_get_functiondef(signature);
    IF position('otlet.workload_pack_stage' IN definition) > 0 THEN
      CONTINUE;
    END IF;
    rewritten := pg_catalog.replace(
      definition,
      E'  PERFORM otlet.promote_configured_workload_revision(saved.task_name);\n  RETURN saved;',
      E'  IF current_setting(''otlet.workload_pack_stage'', true) IS DISTINCT FROM ''on'' THEN\n    PERFORM otlet.promote_configured_workload_revision(saved.task_name);\n  END IF;\n  RETURN saved;'
    );
    IF rewritten = definition THEN
      RAISE EXCEPTION 'otlet workload pack staging rewrite is incomplete for %', signature;
    END IF;
    EXECUTE rewritten;
  END LOOP;

  definition := pg_catalog.pg_get_functiondef(
    'otlet.append_administrative_change(text,text,text,text,text)'::regprocedure
  );
  IF position('''workload_pack''' IN definition) = 0 THEN
    rewritten := pg_catalog.replace(
      definition,
      E'    ''retention''\n  ) THEN',
      E'    ''retention'',\n    ''workload_pack''\n  ) THEN'
    );
    IF rewritten = definition THEN
      RAISE EXCEPTION 'otlet workload pack administrative ledger rewrite is incomplete';
    END IF;
    EXECUTE rewritten;
  END IF;
END;
$migration$;

CREATE FUNCTION otlet.workload_pack_hash(definition jsonb) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT otlet.identity_hash('workload_pack', $1);
$$;

CREATE FUNCTION otlet.workload_pack_spec_hash(definition jsonb) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT otlet.identity_hash('workload_pack_spec', $1 - 'version');
$$;

CREATE FUNCTION otlet.workload_pack_artifact_identity(identity jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'sha256', $1 -> 'sha256',
    'bytes', $1 -> 'bytes',
    'source', $1 -> 'source',
    'revision', $1 -> 'revision',
    'quantization', $1 -> 'quantization',
    'license', $1 -> 'license'
  );
$$;

CREATE FUNCTION otlet.export_workload_pack(
  watch_name text,
  pack_version integer DEFAULT 1
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  watch_definition jsonb;
  pack_task_name text;
  direct_model_name text;
  selection jsonb;
  models jsonb;
  action_policies jsonb;
BEGIN
  IF export_workload_pack.pack_version <= 0 THEN
    RAISE EXCEPTION 'otlet workload pack version must be positive';
  END IF;

  SELECT watch.task_name, task.model_name
  INTO pack_task_name, direct_model_name
  FROM otlet.watches watch
  JOIN otlet.tasks task ON task.name = watch.task_name
  WHERE watch.name = export_workload_pack.watch_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet watch % does not exist', export_workload_pack.watch_name;
  END IF;

  SELECT CASE
    WHEN policy.task_name IS NULL THEN '{}'::jsonb
    ELSE jsonb_build_object(
      'cheap_model_name', policy.cheap_model_name,
      'strong_model_name', policy.strong_model_name,
      'accept_field_checks', policy.accept_field_checks
    )
  END
  INTO selection
  FROM (SELECT pack_task_name AS task_name) task
  LEFT JOIN otlet.model_selection_policies policy
    ON policy.task_name = task.task_name;

  watch_definition := jsonb_set(
    otlet.export_watch(export_workload_pack.watch_name),
    '{model_name}',
    to_jsonb(direct_model_name)
  );
  watch_definition := jsonb_set(
    watch_definition,
    '{model_artifact_identity}',
    (SELECT otlet.workload_pack_artifact_identity(model.artifact_identity)
     FROM otlet.models model
     WHERE model.name = direct_model_name)
  );
  watch_definition := jsonb_set(
    watch_definition,
    '{selection_policy}',
    selection
  );

  WITH roles(role_name, model_name, role_order) AS (
    SELECT 'direct', direct_model_name, 1
    UNION ALL
    SELECT 'cheap', selection ->> 'cheap_model_name', 2
    WHERE selection <> '{}'::jsonb
    UNION ALL
    SELECT 'strong', selection ->> 'strong_model_name', 3
    WHERE selection <> '{}'::jsonb
  )
  SELECT jsonb_object_agg(
    roles.role_name,
    jsonb_build_object(
      'name', model.name,
      'artifact_identity',
        otlet.workload_pack_artifact_identity(model.artifact_identity)
    ) ORDER BY roles.role_order
  )
  INTO models
  FROM roles
  JOIN otlet.models model ON model.name = roles.model_name;

  SELECT COALESCE(jsonb_object_agg(
    policy.action_type,
    jsonb_build_object(
      'target_name', target.name,
      'target_table', format('%I.%I', namespace.nspname, relation.relname),
      'identity_column', target.identity_column::text,
      'allowed_columns', to_jsonb(ARRAY(
        SELECT column_name::text
        FROM unnest(target.allowed_columns) column_name
        ORDER BY column_name
      )),
      'authority_mode', policy.authority_mode,
      'evaluation_status', policy.evaluation_status,
      'enabled', policy.enabled
    ) ORDER BY policy.action_type
  ), '{}'::jsonb)
  INTO action_policies
  FROM otlet.action_workflow_policies policy
  JOIN otlet.action_targets target ON target.name = policy.target_name
  JOIN pg_catalog.pg_class relation ON relation.oid = target.target_table
  JOIN pg_catalog.pg_namespace namespace
    ON namespace.oid = relation.relnamespace
  WHERE policy.task_name = pack_task_name;

  RETURN jsonb_build_object(
    'format', 'otlet.workload_pack.v1',
    'name', export_workload_pack.watch_name,
    'version', export_workload_pack.pack_version,
    'watch', watch_definition,
    'models', models,
    'action_policies', action_policies
  );
END;
$$;

CREATE FUNCTION otlet.workload_pack_shape_error(definition jsonb) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  allowed_keys constant text[] := ARRAY[
    'format', 'name', 'version', 'watch', 'models', 'action_policies'
  ];
  watch_keys constant text[] := ARRAY[
    'action_types', 'candidate_query', 'decision_contract', 'format',
    'input_columns', 'input_shaping', 'instruction', 'kind',
    'max_candidate_rows', 'model_artifact_identity', 'model_name', 'name',
    'output_schema', 'pair_sources', 'record_type', 'runtime_options',
    'selection_policy', 'stale_policy', 'subject_column', 'table_name',
    'trigger_policy'
  ];
  model_keys constant text[] := ARRAY['artifact_identity', 'name'];
  artifact_keys constant text[] := ARRAY[
    'bytes', 'license', 'quantization', 'revision', 'sha256', 'source'
  ];
  policy_keys constant text[] := ARRAY[
    'allowed_columns', 'authority_mode', 'enabled', 'evaluation_status',
    'identity_column', 'target_name', 'target_table'
  ];
  object_key text;
  role_name text;
  role_definition jsonb;
  policy_name text;
  policy_definition jsonb;
  selection jsonb;
  watch_definition jsonb;
  object_field text;
  array_field text;
  expected_roles text[];
  actual_roles text[];
  actual_columns text[];
BEGIN
  BEGIN
    PERFORM otlet.workload_definition_complexity_guard(
      workload_pack_shape_error.definition
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
  END;
  IF jsonb_typeof(workload_pack_shape_error.definition) IS DISTINCT FROM 'object' THEN
    RETURN 'workload pack must be a JSON object';
  END IF;
  SELECT key INTO object_key
  FROM jsonb_object_keys(workload_pack_shape_error.definition) key
  WHERE NOT key = ANY(allowed_keys)
  ORDER BY key COLLATE "C"
  LIMIT 1;
  IF object_key IS NOT NULL THEN
    RETURN format('workload pack has unsupported key %s', object_key);
  END IF;
  SELECT key INTO object_key
  FROM unnest(allowed_keys) key
  WHERE NOT workload_pack_shape_error.definition ? key
  ORDER BY key COLLATE "C"
  LIMIT 1;
  IF object_key IS NOT NULL THEN
    RETURN format('workload pack is missing key %s', object_key);
  END IF;
  IF workload_pack_shape_error.definition ->> 'format'
     IS DISTINCT FROM 'otlet.workload_pack.v1' THEN
    RETURN 'workload pack format must be otlet.workload_pack.v1';
  END IF;
  IF jsonb_typeof(workload_pack_shape_error.definition -> 'name')
       IS DISTINCT FROM 'string'
     OR workload_pack_shape_error.definition ->> 'name'
       !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RETURN 'workload pack name must be a simple identifier';
  END IF;
  IF jsonb_typeof(workload_pack_shape_error.definition -> 'version')
       IS DISTINCT FROM 'number'
     OR workload_pack_shape_error.definition ->> 'version' !~ '^[1-9][0-9]*$'
     OR (workload_pack_shape_error.definition ->> 'version')::numeric > 2147483647 THEN
    RETURN 'workload pack version must be a positive integer';
  END IF;
  IF jsonb_typeof(workload_pack_shape_error.definition -> 'watch')
       IS DISTINCT FROM 'object'
     OR workload_pack_shape_error.definition #>> '{watch,format}'
       IS DISTINCT FROM 'otlet.watch.v1'
     OR workload_pack_shape_error.definition #>> '{watch,name}'
       IS DISTINCT FROM workload_pack_shape_error.definition ->> 'name' THEN
    RETURN 'workload pack watch must be a matching otlet.watch.v1 definition';
  END IF;
  watch_definition := workload_pack_shape_error.definition -> 'watch';
  SELECT key INTO object_key
  FROM jsonb_object_keys(watch_definition) key
  WHERE NOT key = ANY(watch_keys)
  ORDER BY key COLLATE "C"
  LIMIT 1;
  IF object_key IS NOT NULL THEN
    RETURN format('workload pack watch has unsupported key %s', object_key);
  END IF;
  SELECT key INTO object_key
  FROM unnest(watch_keys) key
  WHERE NOT watch_definition ? key
  ORDER BY key COLLATE "C"
  LIMIT 1;
  IF object_key IS NOT NULL THEN
    RETURN format('workload pack watch is missing key %s', object_key);
  END IF;
  FOREACH object_field IN ARRAY ARRAY[
    'name', 'kind', 'instruction', 'model_name', 'record_type', 'stale_policy'
  ] LOOP
    IF jsonb_typeof(watch_definition -> object_field) IS DISTINCT FROM 'string'
       OR NULLIF(watch_definition ->> object_field, '') IS NULL THEN
      RETURN format('workload pack watch %s must be a non-empty string', object_field);
    END IF;
  END LOOP;
  IF jsonb_typeof(watch_definition -> 'output_schema') IS DISTINCT FROM 'object' THEN
    RETURN 'workload pack watch output_schema must be an object';
  END IF;
  FOREACH object_field IN ARRAY ARRAY[
    'runtime_options', 'selection_policy', 'trigger_policy', 'input_shaping',
    'decision_contract', 'model_artifact_identity'
  ] LOOP
    IF jsonb_typeof(watch_definition -> object_field) IS DISTINCT FROM 'object' THEN
      RETURN format('workload pack watch %s must be an object', object_field);
    END IF;
  END LOOP;
  FOREACH array_field IN ARRAY ARRAY['action_types', 'pair_sources'] LOOP
    IF jsonb_typeof(watch_definition -> array_field) IS DISTINCT FROM 'array' THEN
      RETURN format('workload pack watch %s must be an array', array_field);
    END IF;
  END LOOP;
  IF jsonb_typeof(watch_definition -> 'input_columns') NOT IN ('array', 'null') THEN
    RETURN 'workload pack watch input_columns must be an array or null';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(watch_definition -> 'action_types') item(value)
    WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'string'
  ) THEN
    RETURN 'workload pack watch action_types entries must be strings';
  END IF;
  IF jsonb_typeof(watch_definition -> 'input_columns') = 'array'
     AND EXISTS (
       SELECT 1
       FROM jsonb_array_elements(watch_definition -> 'input_columns') item(value)
       WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'string'
     ) THEN
    RETURN 'workload pack watch input_columns entries must be strings';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(watch_definition -> 'pair_sources') item(value)
    WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'object'
  ) THEN
    RETURN 'workload pack watch pair_sources entries must be objects';
  END IF;
  IF jsonb_typeof(watch_definition -> 'max_candidate_rows')
       IS DISTINCT FROM 'number'
     OR watch_definition ->> 'max_candidate_rows' !~ '^[1-9][0-9]*$'
     OR (watch_definition ->> 'max_candidate_rows')::numeric > 100000 THEN
    RETURN 'workload pack watch max_candidate_rows must be an integer between 1 and 100000';
  END IF;
  IF watch_definition ->> 'kind' = 'row' THEN
    IF jsonb_typeof(watch_definition -> 'table_name') IS DISTINCT FROM 'string'
       OR NULLIF(watch_definition ->> 'table_name', '') IS NULL
       OR jsonb_typeof(watch_definition -> 'subject_column')
            IS DISTINCT FROM 'string'
       OR NULLIF(watch_definition ->> 'subject_column', '') IS NULL THEN
      RETURN 'workload pack row watch requires table_name and subject_column';
    END IF;
    IF watch_definition -> 'candidate_query' IS DISTINCT FROM 'null'::jsonb
       OR watch_definition -> 'pair_sources' IS DISTINCT FROM '[]'::jsonb THEN
      RETURN 'workload pack row watch cannot declare pair fields';
    END IF;
  ELSIF watch_definition ->> 'kind' = 'pair' THEN
    IF jsonb_typeof(watch_definition -> 'candidate_query')
         IS DISTINCT FROM 'string'
       OR NULLIF(watch_definition ->> 'candidate_query', '') IS NULL THEN
      RETURN 'workload pack pair watch requires candidate_query';
    END IF;
    IF watch_definition -> 'table_name' IS DISTINCT FROM 'null'::jsonb
       OR watch_definition -> 'subject_column' IS DISTINCT FROM 'null'::jsonb
       OR watch_definition -> 'input_columns' IS DISTINCT FROM 'null'::jsonb THEN
      RETURN 'workload pack pair watch cannot declare row fields';
    END IF;
  ELSE
    RETURN 'workload pack watch kind must be row or pair';
  END IF;
  IF jsonb_typeof(workload_pack_shape_error.definition -> 'models')
       IS DISTINCT FROM 'object' THEN
    RETURN 'workload pack models must be an object';
  END IF;
  IF jsonb_typeof(workload_pack_shape_error.definition -> 'action_policies')
       IS DISTINCT FROM 'object' THEN
    RETURN 'workload pack action_policies must be an object';
  END IF;

  selection := workload_pack_shape_error.definition #> '{watch,selection_policy}';
  IF selection = '{}'::jsonb THEN
    expected_roles := ARRAY['direct'];
  ELSIF jsonb_typeof(selection) = 'object'
        AND ARRAY(
          SELECT key FROM jsonb_object_keys(selection) key ORDER BY key COLLATE "C"
        ) = ARRAY['accept_field_checks', 'cheap_model_name', 'strong_model_name'] THEN
    expected_roles := ARRAY['cheap', 'direct', 'strong'];
  ELSE
    RETURN 'workload pack selection_policy must use canonical model names and accept checks';
  END IF;
  SELECT COALESCE(array_agg(key ORDER BY key COLLATE "C"), ARRAY[]::text[])
  INTO actual_roles
  FROM jsonb_object_keys(workload_pack_shape_error.definition -> 'models') key;
  IF actual_roles IS DISTINCT FROM expected_roles THEN
    RETURN 'workload pack model roles do not match selection_policy';
  END IF;

  FOR role_name, role_definition IN
    SELECT key, value
    FROM jsonb_each(workload_pack_shape_error.definition -> 'models')
    ORDER BY key COLLATE "C"
  LOOP
    IF jsonb_typeof(role_definition) IS DISTINCT FROM 'object'
       OR ARRAY(
         SELECT key FROM jsonb_object_keys(role_definition) key
         ORDER BY key COLLATE "C"
       ) IS DISTINCT FROM model_keys
       OR jsonb_typeof(role_definition -> 'name') IS DISTINCT FROM 'string'
       OR NULLIF(role_definition ->> 'name', '') IS NULL
       OR jsonb_typeof(role_definition -> 'artifact_identity') IS DISTINCT FROM 'object'
       OR ARRAY(
         SELECT key
         FROM jsonb_object_keys(role_definition -> 'artifact_identity') key
         ORDER BY key COLLATE "C"
       ) IS DISTINCT FROM artifact_keys THEN
      RETURN format('workload pack model role %s is invalid', role_name);
    END IF;
  END LOOP;
  IF workload_pack_shape_error.definition #>> '{models,direct,name}'
       IS DISTINCT FROM workload_pack_shape_error.definition #>> '{watch,model_name}'
     OR workload_pack_shape_error.definition #> '{models,direct,artifact_identity}'
       IS DISTINCT FROM workload_pack_shape_error.definition #> '{watch,model_artifact_identity}' THEN
    RETURN 'workload pack direct model does not match the watch';
  END IF;
  IF selection <> '{}'::jsonb
     AND (
       workload_pack_shape_error.definition #>> '{models,cheap,name}'
         IS DISTINCT FROM selection ->> 'cheap_model_name'
       OR workload_pack_shape_error.definition #>> '{models,strong,name}'
         IS DISTINCT FROM selection ->> 'strong_model_name'
     ) THEN
    RETURN 'workload pack routed models do not match selection_policy';
  END IF;

  FOR policy_name, policy_definition IN
    SELECT key, value
    FROM jsonb_each(workload_pack_shape_error.definition -> 'action_policies')
    ORDER BY key COLLATE "C"
  LOOP
    IF jsonb_typeof(policy_definition) IS DISTINCT FROM 'object'
       OR ARRAY(
         SELECT key FROM jsonb_object_keys(policy_definition) key
         ORDER BY key COLLATE "C"
       ) IS DISTINCT FROM policy_keys
       OR policy_name <> 'update_row'
       OR jsonb_typeof(policy_definition -> 'target_name') IS DISTINCT FROM 'string'
       OR policy_definition ->> 'target_name' !~ '^[a-z0-9][a-z0-9_-]*$'
       OR jsonb_typeof(policy_definition -> 'target_table') IS DISTINCT FROM 'string'
       OR NULLIF(policy_definition ->> 'target_table', '') IS NULL
       OR jsonb_typeof(policy_definition -> 'identity_column') IS DISTINCT FROM 'string'
       OR NULLIF(policy_definition ->> 'identity_column', '') IS NULL
       OR jsonb_typeof(policy_definition -> 'allowed_columns') IS DISTINCT FROM 'array'
       OR jsonb_array_length(policy_definition -> 'allowed_columns') NOT BETWEEN 1 AND 16
       OR EXISTS (
         SELECT 1
         FROM jsonb_array_elements(policy_definition -> 'allowed_columns') item(value)
         WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'string'
            OR NULLIF(item.value #>> '{}', '') IS NULL
       )
       OR policy_definition ->> 'authority_mode'
         NOT IN ('recommendation_only', 'bounded_mutation')
       OR jsonb_typeof(policy_definition -> 'enabled') IS DISTINCT FROM 'boolean'
       OR policy_definition ->> 'evaluation_status'
         NOT IN ('unevaluated', 'evaluated', 'adversarial') THEN
      RETURN format('workload pack action policy %s is invalid', policy_name);
    END IF;
    SELECT array_agg(value ORDER BY value COLLATE "C")
    INTO actual_columns
    FROM jsonb_array_elements_text(policy_definition -> 'allowed_columns') value;
    IF actual_columns IS DISTINCT FROM ARRAY(
         SELECT DISTINCT value COLLATE "C"
         FROM jsonb_array_elements_text(policy_definition -> 'allowed_columns') value
         ORDER BY value COLLATE "C"
       ) THEN
      RETURN format('workload pack action policy %s allowed_columns must be sorted and unique', policy_name);
    END IF;
    IF NOT COALESCE(
      workload_pack_shape_error.definition #> '{watch,action_types}',
      '[]'::jsonb
    ) ? policy_name THEN
      RETURN format('workload pack action policy %s is not declared by the watch', policy_name);
    END IF;
  END LOOP;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END;
$$;

CREATE FUNCTION otlet.workload_pack_capability_report(definition jsonb)
RETURNS TABLE (
  path text,
  component text,
  compatible boolean,
  ready boolean,
  code text,
  detail text
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  shape_error text;
  role_name text;
  required_model jsonb;
  registered_model otlet.models%ROWTYPE;
  requested_options text[];
  native_options text[];
  portable_options text[];
  native_compatible boolean;
  portable_compatible boolean;
  runtime_compatible boolean;
  runtime_ready boolean;
  schema_error text;
  source_index integer;
  required_source jsonb;
  source_relation regclass;
  source_error text;
  policy_name text;
  required_policy jsonb;
  target otlet.action_targets%ROWTYPE;
  required_target_relation regclass;
  watch_target_relation regclass;
  target_error text;
  required_columns name[];
BEGIN
  shape_error := otlet.workload_pack_shape_error(
    workload_pack_capability_report.definition
  );
  IF shape_error IS NOT NULL THEN
    RETURN QUERY SELECT
      '$'::text,
      'definition'::text,
      false,
      false,
      'invalid_definition'::text,
      shape_error;
    RETURN;
  END IF;

  SELECT COALESCE(array_agg(key ORDER BY key COLLATE "C"), ARRAY[]::text[])
  INTO requested_options
  FROM jsonb_object_keys(
    COALESCE((
      SELECT policy.default_runtime_options
      FROM otlet.production_policy policy
      WHERE policy.name = 'default'
    ), '{}'::jsonb)
    || COALESCE(
      workload_pack_capability_report.definition #> '{watch,runtime_options}',
      '{}'::jsonb
    )
  ) key;
  SELECT COALESCE(array_agg(value ORDER BY value COLLATE "C"), ARRAY[]::text[])
  INTO native_options
  FROM jsonb_array_elements_text(COALESCE(
    otlet.linked_runtime_capabilities() -> 'supported_runtime_options',
    '[]'::jsonb
  )) value;
  SELECT COALESCE(array_agg(value ORDER BY value COLLATE "C"), ARRAY[]::text[])
  INTO portable_options
  FROM jsonb_array_elements_text(
    otlet.portable_reference_runtime_contract() -> 'supported_runtime_options'
  ) value;

  SELECT report.error
  INTO schema_error
  FROM otlet.json_schema_support_report(
    workload_pack_capability_report.definition #> '{watch,output_schema}'
  ) report
  ORDER BY report.schema_path, report.keyword
  LIMIT 1;
  RETURN QUERY SELECT
    '/watch/output_schema'::text,
    'schema'::text,
    schema_error IS NULL,
    schema_error IS NULL,
    CASE WHEN schema_error IS NULL THEN 'compatible' ELSE 'unsupported_schema' END,
    COALESCE(schema_error, 'database validation supports this schema');

  IF workload_pack_capability_report.definition #>> '{watch,kind}' = 'row' THEN
    source_error := NULL;
    BEGIN
      PERFORM otlet.semantic_source_column_contract(
        workload_pack_capability_report.definition #>> '{watch,table_name}',
        workload_pack_capability_report.definition #>> '{watch,subject_column}',
        CASE WHEN jsonb_typeof(
          workload_pack_capability_report.definition #> '{watch,input_columns}'
        ) = 'array' THEN ARRAY(
          SELECT value
          FROM jsonb_array_elements_text(
            workload_pack_capability_report.definition
              #> '{watch,input_columns}'
          ) value
        ) ELSE NULL END
      );
    EXCEPTION WHEN OTHERS THEN
      source_error := SQLERRM;
    END;
    RETURN QUERY SELECT
      '/watch/table_name'::text,
      'source'::text,
      source_error IS NULL,
      source_error IS NULL,
      CASE WHEN source_error IS NULL THEN 'compatible' ELSE 'source_missing' END,
      COALESCE(source_error, 'source relation and projected columns exist');
  ELSE
    FOR source_index, required_source IN
      SELECT source.ordinality::integer - 1, source.value
      FROM jsonb_array_elements(
        workload_pack_capability_report.definition #> '{watch,pair_sources}'
      ) WITH ORDINALITY source(value, ordinality)
    LOOP
      source_error := NULL;
      BEGIN
        source_relation := to_regclass(required_source ->> 'table');
        IF source_relation IS NULL THEN
          RAISE EXCEPTION 'pair source relation is missing';
        END IF;
        PERFORM 1
        FROM pg_catalog.pg_attribute attribute
        WHERE attribute.attrelid = source_relation
          AND attribute.attname = required_source ->> 'subject_column'
          AND attribute.attnum > 0
          AND NOT attribute.attisdropped;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'pair source subject column is missing';
        END IF;
      EXCEPTION WHEN OTHERS THEN
        source_error := SQLERRM;
      END;
      RETURN QUERY SELECT
        format('/watch/pair_sources/%s', source_index),
        'source'::text,
        source_error IS NULL,
        source_error IS NULL,
        CASE WHEN source_error IS NULL THEN 'compatible' ELSE 'source_missing' END,
        COALESCE(source_error, 'pair source relation and subject column exist');
    END LOOP;
  END IF;

  FOR role_name, required_model IN
    SELECT key, value
    FROM jsonb_each(workload_pack_capability_report.definition -> 'models')
    ORDER BY key COLLATE "C"
  LOOP
    SELECT model.*
    INTO registered_model
    FROM otlet.models model
    WHERE model.name = required_model ->> 'name';
    RETURN QUERY SELECT
      format('/models/%s', role_name),
      'model',
      registered_model.name IS NOT NULL
        AND otlet.workload_pack_artifact_identity(
          registered_model.artifact_identity
        ) IS NOT DISTINCT FROM
          required_model -> 'artifact_identity'
        AND registered_model.lifecycle_state = 'active',
      registered_model.name IS NOT NULL
        AND otlet.workload_pack_artifact_identity(
          registered_model.artifact_identity
        ) IS NOT DISTINCT FROM
          required_model -> 'artifact_identity'
        AND registered_model.lifecycle_state = 'active'
        AND otlet.model_artifact_ready(registered_model.name),
      CASE
        WHEN registered_model.name IS NULL THEN 'model_missing'
        WHEN otlet.workload_pack_artifact_identity(
               registered_model.artifact_identity
             ) IS DISTINCT FROM
             required_model -> 'artifact_identity' THEN 'artifact_mismatch'
        WHEN registered_model.lifecycle_state <> 'active' THEN 'model_inactive'
        ELSE 'compatible'
      END,
      CASE
        WHEN registered_model.name IS NULL THEN 'registered model is missing'
        WHEN otlet.workload_pack_artifact_identity(
               registered_model.artifact_identity
             ) IS DISTINCT FROM
             required_model -> 'artifact_identity' THEN 'registered artifact identity differs'
        WHEN registered_model.lifecycle_state <> 'active' THEN
          format('model lifecycle is %s', registered_model.lifecycle_state)
        ELSE 'registered model and artifact identity match'
      END;

    native_compatible := COALESCE(requested_options <@ native_options, false);
    portable_compatible := COALESCE(
      requested_options <@ portable_options,
      false
    );
    runtime_compatible := native_compatible OR portable_compatible;
    runtime_ready := registered_model.name IS NOT NULL
      AND registered_model.lifecycle_state = 'active'
      AND otlet.model_artifact_ready(registered_model.name)
      AND (
        (native_compatible AND otlet.linked_runtime_capabilities() IS NOT NULL)
        OR EXISTS (
          SELECT 1
          FROM otlet.portable_worker_status worker
          WHERE portable_compatible
            AND worker.model_name = registered_model.name
            AND worker.model_artifact_hash = registered_model.artifact_hash
            AND worker.worker_health = 'healthy'
            AND worker.desired_state = 'running'
            AND worker.reported_state IN ('idle', 'running')
            AND worker.model_status = 'ready'
        )
      );
    RETURN QUERY SELECT
      format('/models/%s/runtime', role_name),
      'runtime',
      runtime_compatible,
      runtime_ready,
      CASE
        WHEN runtime_compatible THEN 'compatible'
        ELSE 'unsupported_runtime_option'
      END,
      CASE
        WHEN runtime_compatible AND runtime_ready THEN 'compatible runtime is ready'
        WHEN runtime_compatible THEN 'compatible runtime exists but no live route is ready'
        ELSE 'no native or portable contract supports every requested runtime option'
      END;
  END LOOP;

  FOR policy_name, required_policy IN
    SELECT key, value
    FROM jsonb_each(workload_pack_capability_report.definition -> 'action_policies')
    ORDER BY key COLLATE "C"
  LOOP
    RETURN QUERY SELECT
      format('/action_policies/%s', policy_name),
      'action_type',
      EXISTS (
        SELECT 1 FROM otlet.action_type_schemas action_type
        WHERE action_type.action_type = policy_name
      ),
      EXISTS (
        SELECT 1 FROM otlet.action_type_schemas action_type
        WHERE action_type.action_type = policy_name
      ),
      CASE WHEN EXISTS (
        SELECT 1 FROM otlet.action_type_schemas action_type
        WHERE action_type.action_type = policy_name
      ) THEN 'compatible' ELSE 'action_type_missing' END,
      CASE WHEN EXISTS (
        SELECT 1 FROM otlet.action_type_schemas action_type
        WHERE action_type.action_type = policy_name
      ) THEN 'action type is registered' ELSE 'action type is not registered' END;

    SELECT action_target.*
    INTO target
    FROM otlet.action_targets action_target
    WHERE action_target.name = required_policy ->> 'target_name';
    target_error := NULL;
    required_target_relation := NULL;
    watch_target_relation := NULL;
    BEGIN
      required_target_relation := to_regclass(
        required_policy ->> 'target_table'
      );
      watch_target_relation := to_regclass(
        workload_pack_capability_report.definition #>> '{watch,table_name}'
      );
      IF required_target_relation IS NULL OR watch_target_relation IS NULL THEN
        RAISE EXCEPTION 'action target relation is missing';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      target_error := SQLERRM;
    END;
    IF target.name IS NOT NULL AND target_error IS NULL THEN
      target_error := otlet.action_target_validation_error(target.name);
    ELSIF target.name IS NULL THEN
      target_error := 'unknown action target';
    END IF;
    SELECT array_agg(value::name ORDER BY value COLLATE "C")
    INTO required_columns
    FROM jsonb_array_elements_text(required_policy -> 'allowed_columns') value;
    RETURN QUERY SELECT
      format('/action_policies/%s/target_name', policy_name),
      'action_target',
      target.name IS NOT NULL
        AND target.target_table IS NOT DISTINCT FROM
          required_target_relation
        AND target.target_table IS NOT DISTINCT FROM watch_target_relation
        AND target.identity_column::text IS NOT DISTINCT FROM
          required_policy ->> 'identity_column'
        AND target.allowed_columns IS NOT DISTINCT FROM required_columns
        AND target_error IS NULL,
      target.name IS NOT NULL
        AND target.target_table IS NOT DISTINCT FROM
          required_target_relation
        AND target.target_table IS NOT DISTINCT FROM watch_target_relation
        AND target.identity_column::text IS NOT DISTINCT FROM
          required_policy ->> 'identity_column'
        AND target.allowed_columns IS NOT DISTINCT FROM required_columns
        AND target_error IS NULL,
      CASE
        WHEN target.name IS NULL THEN 'action_target_missing'
        WHEN target.target_table IS DISTINCT FROM
             required_target_relation
          OR target.target_table IS DISTINCT FROM watch_target_relation
          OR target.identity_column::text IS DISTINCT FROM
             required_policy ->> 'identity_column'
          OR target.allowed_columns IS DISTINCT FROM required_columns
          THEN 'action_target_mismatch'
        WHEN target_error IS NOT NULL THEN 'action_target_invalid'
        ELSE 'compatible'
      END,
      COALESCE(target_error, 'registered action target matches the portable declaration');
  END LOOP;
END;
$$;

CREATE FUNCTION otlet.stage_workload_pack_configuration(definition jsonb)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  shape_error text;
  capability record;
  policy_name text;
  policy_definition jsonb;
  direct_artifact_identity jsonb;
  saved_watch otlet.watches%ROWTYPE;
  candidate_workload_revision_hash text;
  previous_stage text := current_setting('otlet.workload_pack_stage', true);
BEGIN
  shape_error := otlet.workload_pack_shape_error(
    stage_workload_pack_configuration.definition
  );
  IF shape_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet workload pack is invalid: %', shape_error;
  END IF;
  SELECT report.*
  INTO capability
  FROM otlet.workload_pack_capability_report(
    stage_workload_pack_configuration.definition
  ) report
  WHERE NOT report.compatible
  ORDER BY report.path COLLATE "C", report.component COLLATE "C"
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'otlet workload pack capability % failed: %',
      capability.code,
      capability.detail;
  END IF;

  SELECT model.artifact_identity
  INTO STRICT direct_artifact_identity
  FROM otlet.models model
  WHERE model.name = stage_workload_pack_configuration.definition
    #>> '{models,direct,name}';

  PERFORM set_config('otlet.workload_pack_stage', 'on', true);
  BEGIN
    SELECT *
    INTO saved_watch
    FROM otlet.import_watch(
      jsonb_set(
        stage_workload_pack_configuration.definition -> 'watch',
        '{model_artifact_identity}',
        direct_artifact_identity
      ),
      true
    );

    DELETE FROM otlet.action_workflow_policies policy
    WHERE policy.task_name = saved_watch.task_name
      AND NOT (
        stage_workload_pack_configuration.definition -> 'action_policies'
      ) ? policy.action_type;

    FOR policy_name, policy_definition IN
      SELECT key, value
      FROM jsonb_each(
        stage_workload_pack_configuration.definition -> 'action_policies'
      )
      ORDER BY key COLLATE "C"
    LOOP
      PERFORM otlet.register_action_workflow_policy(
        saved_watch.task_name,
        policy_name,
        policy_definition ->> 'target_name',
        policy_definition ->> 'authority_mode',
        policy_definition ->> 'evaluation_status'
      );
      IF NOT (policy_definition ->> 'enabled')::boolean THEN
        PERFORM otlet.disable_action_workflow_policy(
          saved_watch.task_name,
          policy_name
        );
      END IF;
    END LOOP;

    candidate_workload_revision_hash := otlet.capture_workload_revision(
      saved_watch.task_name
    );
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config(
      'otlet.workload_pack_stage',
      COALESCE(previous_stage, ''),
      true
    );
    RAISE;
  END;
  PERFORM set_config(
    'otlet.workload_pack_stage',
    COALESCE(previous_stage, ''),
    true
  );
  RETURN candidate_workload_revision_hash;
END;
$$;

CREATE FUNCTION otlet.preview_workload_pack(definition jsonb)
RETURNS TABLE (
  canonical_definition jsonb,
  pack_hash text,
  spec_hash text,
  task_name text,
  candidate_workload_revision_hash text,
  workload_definition jsonb,
  candidate_plan jsonb,
  candidate_plan_cost numeric,
  candidate_preflight_at timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
  previous_suppress text := current_setting('otlet.administrative_suppress', true);
BEGIN
  BEGIN
    PERFORM set_config('otlet.administrative_suppress', 'on', true);
    preview_workload_pack.candidate_workload_revision_hash :=
      otlet.stage_workload_pack_configuration(
        preview_workload_pack.definition
      );
    preview_workload_pack.task_name :=
      preview_workload_pack.definition ->> 'name' || '_task';
    SELECT
      revision.definition,
      revision.candidate_plan,
      revision.candidate_plan_cost,
      revision.candidate_preflight_at
    INTO
      preview_workload_pack.workload_definition,
      preview_workload_pack.candidate_plan,
      preview_workload_pack.candidate_plan_cost,
      preview_workload_pack.candidate_preflight_at
    FROM otlet.workload_revisions revision
    WHERE revision.task_name = preview_workload_pack.task_name
      AND revision.workload_revision_hash =
        preview_workload_pack.candidate_workload_revision_hash;
    preview_workload_pack.canonical_definition := otlet.export_workload_pack(
      preview_workload_pack.definition ->> 'name',
      (preview_workload_pack.definition ->> 'version')::integer
    );
    preview_workload_pack.pack_hash := otlet.workload_pack_hash(
      preview_workload_pack.canonical_definition
    );
    preview_workload_pack.spec_hash := otlet.workload_pack_spec_hash(
      preview_workload_pack.canonical_definition
    );
    RAISE EXCEPTION 'otlet workload pack preview rollback'
      USING ERRCODE = 'P7474';
  EXCEPTION WHEN SQLSTATE 'P7474' THEN
    NULL;
  END;
  PERFORM set_config(
    'otlet.administrative_suppress',
    COALESCE(previous_suppress, ''),
    true
  );
  IF preview_workload_pack.canonical_definition IS NULL
     OR preview_workload_pack.workload_definition IS NULL THEN
    RAISE EXCEPTION 'otlet workload pack preview produced no candidate revision';
  END IF;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.lint_workload_pack(definition jsonb)
RETURNS TABLE (
  path text,
  code text,
  message text
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  shape_error text;
  preview record;
BEGIN
  shape_error := otlet.workload_pack_shape_error(lint_workload_pack.definition);
  IF shape_error IS NOT NULL THEN
    RETURN QUERY SELECT '$'::text, 'invalid_definition'::text, shape_error;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT report.path, report.code, report.detail
  FROM otlet.workload_pack_capability_report(
    lint_workload_pack.definition
  ) report
  WHERE NOT report.compatible
  ORDER BY report.path COLLATE "C", report.component COLLATE "C";
  IF FOUND THEN
    RETURN;
  END IF;

  BEGIN
    SELECT preview_row.*
    INTO STRICT preview
    FROM otlet.preview_workload_pack(
      lint_workload_pack.definition
    ) preview_row;
    IF preview.canonical_definition IS DISTINCT FROM
         lint_workload_pack.definition THEN
      RETURN QUERY SELECT
        '$'::text,
        'noncanonical_definition'::text,
        'workload pack must match its canonical export'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT
      '$'::text,
      'apply_validation_failed'::text,
      SQLERRM::text;
  END;
END;
$$;

CREATE FUNCTION otlet.diff_workload_packs(
  left_definition jsonb,
  right_definition jsonb
) RETURNS TABLE (
  category text,
  path text,
  old_value jsonb,
  new_value jsonb
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  left_error text;
  right_error text;
BEGIN
  left_error := otlet.workload_pack_shape_error(
    diff_workload_packs.left_definition
  );
  right_error := otlet.workload_pack_shape_error(
    diff_workload_packs.right_definition
  );
  IF left_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet left workload pack is invalid: %', left_error;
  ELSIF right_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet right workload pack is invalid: %', right_error;
  END IF;

  RETURN QUERY
  WITH components(category, path, old_value, new_value) AS (
    VALUES
      (
        'identity'::text,
        '/identity'::text,
        jsonb_build_object(
          'format', left_definition -> 'format',
          'name', left_definition -> 'name',
          'watch_name', left_definition #> '{watch,name}',
          'kind', left_definition #> '{watch,kind}'
        ),
        jsonb_build_object(
          'format', right_definition -> 'format',
          'name', right_definition -> 'name',
          'watch_name', right_definition #> '{watch,name}',
          'kind', right_definition #> '{watch,kind}'
        )
      ),
      (
        'source',
        '/watch/source',
        jsonb_build_object(
          'table_name', left_definition #> '{watch,table_name}',
          'subject_column', left_definition #> '{watch,subject_column}',
          'candidate_query', left_definition #> '{watch,candidate_query}',
          'input_columns', left_definition #> '{watch,input_columns}',
          'pair_sources', left_definition #> '{watch,pair_sources}',
          'max_candidate_rows', left_definition #> '{watch,max_candidate_rows}'
        ),
        jsonb_build_object(
          'table_name', right_definition #> '{watch,table_name}',
          'subject_column', right_definition #> '{watch,subject_column}',
          'candidate_query', right_definition #> '{watch,candidate_query}',
          'input_columns', right_definition #> '{watch,input_columns}',
          'pair_sources', right_definition #> '{watch,pair_sources}',
          'max_candidate_rows', right_definition #> '{watch,max_candidate_rows}'
        )
      ),
      (
        'prompt_schema',
        '/watch/prompt_schema',
        jsonb_build_object(
          'instruction', left_definition #> '{watch,instruction}',
          'output_schema', left_definition #> '{watch,output_schema}',
          'record_type', left_definition #> '{watch,record_type}',
          'input_shaping', left_definition #> '{watch,input_shaping}',
          'decision_contract', left_definition #> '{watch,decision_contract}',
          'action_types', left_definition #> '{watch,action_types}'
        ),
        jsonb_build_object(
          'instruction', right_definition #> '{watch,instruction}',
          'output_schema', right_definition #> '{watch,output_schema}',
          'record_type', right_definition #> '{watch,record_type}',
          'input_shaping', right_definition #> '{watch,input_shaping}',
          'decision_contract', right_definition #> '{watch,decision_contract}',
          'action_types', right_definition #> '{watch,action_types}'
        )
      ),
      (
        'model_runtime',
        '/models',
        jsonb_build_object(
          'models', left_definition -> 'models',
          'runtime_options', left_definition #> '{watch,runtime_options}'
        ),
        jsonb_build_object(
          'models', right_definition -> 'models',
          'runtime_options', right_definition #> '{watch,runtime_options}'
        )
      ),
      (
        'selection',
        '/watch/selection_policy',
        left_definition #> '{watch,selection_policy}',
        right_definition #> '{watch,selection_policy}'
      ),
      (
        'freshness',
        '/watch/freshness',
        jsonb_build_object(
          'trigger_policy', left_definition #> '{watch,trigger_policy}',
          'stale_policy', left_definition #> '{watch,stale_policy}'
        ),
        jsonb_build_object(
          'trigger_policy', right_definition #> '{watch,trigger_policy}',
          'stale_policy', right_definition #> '{watch,stale_policy}'
        )
      ),
      (
        'action_authority',
        '/action_policies',
        left_definition -> 'action_policies',
        right_definition -> 'action_policies'
      )
  )
  SELECT components.category, components.path,
         components.old_value, components.new_value
  FROM components
  WHERE components.old_value IS DISTINCT FROM components.new_value
  ORDER BY components.category COLLATE "C";
END;
$$;

CREATE FUNCTION otlet.prepare_workload_pack(
  definition jsonb,
  expected_current_spec_hash text,
  expected_current_workload_revision_hash text,
  reason text,
  ticket text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  preview record;
  shape_error text;
  current_definition jsonb;
  current_pack_hash text;
  current_spec_hash text;
  current_workload_revision_hash text;
  existing otlet.workload_pack_definitions%ROWTYPE;
  existing_reason text;
  existing_ticket text;
  prepared_event_id bigint;
  previous_append text := current_setting('otlet.workload_pack_append', true);
BEGIN
  PERFORM otlet.set_administrative_change_context(
    prepare_workload_pack.reason,
    prepare_workload_pack.ticket
  );
  shape_error := otlet.workload_pack_shape_error(
    prepare_workload_pack.definition
  );
  IF shape_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet workload pack is invalid: %', shape_error;
  END IF;
  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_revision:' ||
      (prepare_workload_pack.definition ->> 'name') || '_task',
    0
  ));

  SELECT stored.*
  INTO existing
  FROM otlet.workload_pack_definitions stored
  WHERE stored.pack_name = prepare_workload_pack.definition ->> 'name'
    AND stored.pack_version =
      (prepare_workload_pack.definition ->> 'version')::integer;
  IF FOUND THEN
    SELECT administrative.reason, administrative.ticket
    INTO existing_reason, existing_ticket
    FROM otlet.administrative_change_events administrative
    WHERE administrative.event_id = existing.prepared_event_id;
    IF existing.pack_hash IS DISTINCT FROM
         otlet.workload_pack_hash(prepare_workload_pack.definition)
       OR existing.baseline_spec_hash IS DISTINCT FROM
         prepare_workload_pack.expected_current_spec_hash
       OR existing.baseline_workload_revision_hash IS DISTINCT FROM
         prepare_workload_pack.expected_current_workload_revision_hash
       OR existing_reason IS DISTINCT FROM
         NULLIF(btrim(prepare_workload_pack.reason), '')
       OR existing_ticket IS DISTINCT FROM
         NULLIF(btrim(prepare_workload_pack.ticket), '') THEN
      RAISE EXCEPTION 'otlet workload pack name and version already identify another preparation';
    END IF;
    RETURN existing.pack_hash;
  END IF;

  SELECT head.active_workload_revision_hash
  INTO current_workload_revision_hash
  FROM otlet.watches watch
  JOIN otlet.tasks task ON task.name = watch.task_name
  JOIN otlet.workload_revision_heads head ON head.task_name = task.name
  WHERE watch.name = prepare_workload_pack.definition ->> 'name'
    AND task.lifecycle_state = 'active'
  FOR UPDATE OF task, head;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload pack preparation requires an existing active watch';
  END IF;
  current_definition := otlet.export_workload_pack(
    prepare_workload_pack.definition ->> 'name',
    (prepare_workload_pack.definition ->> 'version')::integer
  );
  current_spec_hash := otlet.workload_pack_spec_hash(current_definition);
  IF prepare_workload_pack.expected_current_spec_hash
       IS DISTINCT FROM current_spec_hash
     OR prepare_workload_pack.expected_current_workload_revision_hash
       IS DISTINCT FROM current_workload_revision_hash THEN
    RAISE EXCEPTION 'otlet workload pack preparation conflict';
  END IF;

  SELECT preview_row.*
  INTO STRICT preview
  FROM otlet.preview_workload_pack(prepare_workload_pack.definition) preview_row;
  IF preview.canonical_definition IS DISTINCT FROM
       prepare_workload_pack.definition THEN
    RAISE EXCEPTION 'otlet workload pack must match its canonical export';
  END IF;
  current_pack_hash := otlet.workload_pack_hash(current_definition);
  IF preview.pack_hash = current_pack_hash THEN
    RAISE EXCEPTION 'otlet workload pack does not change the current definition';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.workload_pack_definitions stored
    WHERE stored.pack_name = preview.canonical_definition ->> 'name'
      AND stored.pack_version >=
        (preview.canonical_definition ->> 'version')::integer
  ) THEN
    RAISE EXCEPTION 'otlet workload pack version must increase';
  END IF;

  INSERT INTO otlet.workload_revisions (
    workload_revision_hash,
    task_name,
    definition,
    candidate_plan,
    candidate_plan_cost,
    candidate_preflight_at
  ) VALUES (
    preview.candidate_workload_revision_hash,
    preview.task_name,
    preview.workload_definition,
    preview.candidate_plan,
    preview.candidate_plan_cost,
    preview.candidate_preflight_at
  )
  ON CONFLICT (workload_revision_hash) DO NOTHING;

  prepared_event_id := otlet.append_administrative_change(
    'workload_pack',
    preview.canonical_definition ->> 'name',
    'prepare',
    current_spec_hash,
    preview.pack_hash
  );
  PERFORM set_config('otlet.workload_pack_append', 'on', true);
  INSERT INTO otlet.workload_pack_definitions (
    pack_hash,
    spec_hash,
    pack_name,
    pack_version,
    task_name,
    definition,
    baseline_spec_hash,
    baseline_workload_revision_hash,
    candidate_workload_revision_hash,
    prepared_event_id
  ) VALUES (
    preview.pack_hash,
    preview.spec_hash,
    preview.canonical_definition ->> 'name',
    (preview.canonical_definition ->> 'version')::integer,
    preview.task_name,
    preview.canonical_definition,
    current_spec_hash,
    current_workload_revision_hash,
    preview.candidate_workload_revision_hash,
    prepared_event_id
  );
  PERFORM set_config(
    'otlet.workload_pack_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN preview.pack_hash;
END;
$$;

CREATE FUNCTION otlet.apply_workload_pack(
  pack_hash text,
  expected_current_spec_hash text,
  expected_current_workload_revision_hash text,
  reason text,
  ticket text DEFAULT NULL,
  promotion_decision_event_hash text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  prepared otlet.workload_pack_definitions%ROWTYPE;
  existing_event otlet.workload_pack_events%ROWTYPE;
  existing_reason text;
  existing_ticket text;
  predecessor otlet.workload_pack_events%ROWTYPE;
  current_definition jsonb;
  current_pack_hash text;
  current_spec_hash text;
  current_workload_revision_hash text;
  result_workload_revision_hash text;
  result_definition jsonb;
  governed boolean;
  governance_event_hash text;
  administrative_event_id bigint;
  created_at timestamptz := clock_timestamp();
  event_hash text;
  previous_append text := current_setting('otlet.workload_pack_append', true);
BEGIN
  PERFORM otlet.set_administrative_change_context(
    apply_workload_pack.reason,
    apply_workload_pack.ticket
  );
  SELECT stored.*
  INTO prepared
  FROM otlet.workload_pack_definitions stored
  WHERE stored.pack_hash = apply_workload_pack.pack_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload pack % is not prepared', apply_workload_pack.pack_hash;
  END IF;

  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_revision:' || prepared.task_name,
    0
  ));
  SELECT event.*
  INTO existing_event
  FROM otlet.workload_pack_events event
  WHERE event.event_kind = 'apply'
    AND event.application_pack_hash = prepared.pack_hash;
  IF FOUND THEN
    SELECT administrative.reason, administrative.ticket
    INTO existing_reason, existing_ticket
    FROM otlet.administrative_change_events administrative
    WHERE administrative.event_id = existing_event.administrative_event_id;
    IF existing_event.prior_spec_hash IS DISTINCT FROM
         apply_workload_pack.expected_current_spec_hash
       OR existing_event.prior_workload_revision_hash IS DISTINCT FROM
         apply_workload_pack.expected_current_workload_revision_hash
       OR existing_reason IS DISTINCT FROM NULLIF(btrim(apply_workload_pack.reason), '')
       OR existing_ticket IS DISTINCT FROM NULLIF(btrim(apply_workload_pack.ticket), '')
       OR NULLIF(btrim(apply_workload_pack.promotion_decision_event_hash), '')
          IS DISTINCT FROM (
            SELECT governance.definition
              #>> '{payload,promotion_decision_event_hash}'
            FROM otlet.workload_acceptance_events governance
            WHERE governance.event_hash = existing_event.governance_event_hash
          ) THEN
      RAISE EXCEPTION 'otlet workload pack apply retry conflicts';
    END IF;
    RETURN existing_event.event_hash;
  END IF;
  SELECT head.active_workload_revision_hash
  INTO current_workload_revision_hash
  FROM otlet.tasks task
  JOIN otlet.workload_revision_heads head ON head.task_name = task.name
  WHERE task.name = prepared.task_name
    AND task.lifecycle_state = 'active'
  FOR UPDATE OF task, head;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload pack apply requires an active task';
  END IF;
  SELECT latest.*
  INTO predecessor
  FROM otlet.workload_pack_events latest
  WHERE latest.pack_name = prepared.pack_name
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_pack_events successor
      WHERE successor.predecessor_event_hash = latest.event_hash
    )
  ORDER BY latest.event_id DESC
  LIMIT 1
  FOR UPDATE;
  current_definition := otlet.export_workload_pack(
    prepared.pack_name,
    CASE WHEN predecessor.event_hash IS NULL THEN prepared.pack_version
      ELSE (predecessor.result_definition ->> 'version')::integer
    END
  );
  current_pack_hash := otlet.workload_pack_hash(current_definition);
  current_spec_hash := otlet.workload_pack_spec_hash(current_definition);
  IF apply_workload_pack.expected_current_spec_hash
       IS DISTINCT FROM current_spec_hash
     OR apply_workload_pack.expected_current_workload_revision_hash
       IS DISTINCT FROM current_workload_revision_hash
     OR prepared.baseline_spec_hash IS DISTINCT FROM current_spec_hash
     OR prepared.baseline_workload_revision_hash IS DISTINCT FROM
       current_workload_revision_hash THEN
    RAISE EXCEPTION 'otlet workload pack apply conflict';
  END IF;
  IF predecessor.event_hash IS NOT NULL
     AND (
       predecessor.result_definition IS DISTINCT FROM current_definition
       OR predecessor.result_pack_hash IS DISTINCT FROM current_pack_hash
       OR predecessor.result_spec_hash IS DISTINCT FROM current_spec_hash
       OR predecessor.result_workload_revision_hash IS DISTINCT FROM
         current_workload_revision_hash
     ) THEN
    RAISE EXCEPTION 'otlet workload pack event head differs from configured state';
  END IF;
  IF current_pack_hash = prepared.pack_hash THEN
    RAISE EXCEPTION 'otlet workload pack is already current';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM otlet.workload_acceptance_contracts contract
    WHERE contract.task_name = prepared.task_name
      AND contract.baseline_workload_revision_hash =
        current_workload_revision_hash
      AND contract.candidate_workload_revision_hash =
        prepared.candidate_workload_revision_hash
      AND contract.definition #>> '{population,rule,kind}' =
        'promotion_shadow'
  )
  INTO governed;
  IF governed IS DISTINCT FROM (
       NULLIF(btrim(apply_workload_pack.promotion_decision_event_hash), '')
         IS NOT NULL
     ) THEN
    RAISE EXCEPTION '%', CASE WHEN governed
      THEN 'otlet governed workload pack requires a promotion decision event'
      ELSE 'otlet workload pack has no matching governed promotion'
    END;
  END IF;
  IF governed AND NOT EXISTS (
    SELECT 1
    FROM otlet.workload_acceptance_events decision
    JOIN otlet.workload_acceptance_contracts contract
      ON contract.contract_hash = decision.contract_hash
    JOIN otlet.workload_acceptance_contracts shadow
      ON shadow.contract_hash = contract.supersedes_contract_hash
    WHERE decision.event_hash =
            btrim(apply_workload_pack.promotion_decision_event_hash)
      AND decision.event_kind = 'promotion_decision'
      AND decision.definition #>> '{payload,outcome}' = 'promote'
      AND contract.task_name = prepared.task_name
      AND contract.baseline_workload_revision_hash =
            current_workload_revision_hash
      AND contract.candidate_workload_revision_hash =
            prepared.candidate_workload_revision_hash
      AND shadow.task_name = prepared.task_name
      AND shadow.baseline_workload_revision_hash =
            current_workload_revision_hash
      AND shadow.candidate_workload_revision_hash =
            prepared.candidate_workload_revision_hash
      AND shadow.definition #>> '{population,rule,kind}' =
            'promotion_shadow'
  ) THEN
    RAISE EXCEPTION 'otlet promotion decision does not match the prepared workload pack';
  END IF;

  IF otlet.stage_workload_pack_configuration(prepared.definition)
       IS DISTINCT FROM prepared.candidate_workload_revision_hash THEN
    RAISE EXCEPTION 'otlet workload pack staged revision changed after preparation';
  END IF;
  IF governed THEN
    governance_event_hash := otlet.activate_workload_promotion(
      btrim(apply_workload_pack.promotion_decision_event_hash),
      current_workload_revision_hash
    );
    IF NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_events activation
      WHERE activation.event_hash = governance_event_hash
        AND activation.event_kind = 'promotion_activation'
        AND activation.definition #>> '{payload,promotion_decision_event_hash}' =
              btrim(apply_workload_pack.promotion_decision_event_hash)
        AND activation.definition #>> '{payload,task_name}' = prepared.task_name
        AND activation.definition #>> '{payload,prior_workload_revision_hash}' =
              current_workload_revision_hash
        AND activation.definition #>> '{payload,resulting_workload_revision_hash}' =
              prepared.candidate_workload_revision_hash
    ) THEN
      RAISE EXCEPTION 'otlet promotion activation differs from the prepared workload pack';
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM otlet.workload_revision_heads head
      WHERE head.task_name = prepared.task_name
        AND head.active_workload_revision_hash =
              prepared.candidate_workload_revision_hash
        AND head.previous_workload_revision_hash =
              current_workload_revision_hash
    ) THEN
      RAISE EXCEPTION 'otlet promotion activation did not move the prepared workload head';
    END IF;
    result_workload_revision_hash := prepared.candidate_workload_revision_hash;
  ELSE
    result_workload_revision_hash := otlet.promote_workload_revision(
      prepared.task_name,
      prepared.candidate_workload_revision_hash,
      current_workload_revision_hash
    );
  END IF;
  result_definition := otlet.export_workload_pack(
    prepared.pack_name,
    prepared.pack_version
  );
  IF result_definition IS DISTINCT FROM prepared.definition
     OR otlet.workload_pack_hash(result_definition) IS DISTINCT FROM
       prepared.pack_hash THEN
    RAISE EXCEPTION 'otlet workload pack apply did not produce the prepared definition';
  END IF;

  administrative_event_id := otlet.append_administrative_change(
    'workload_pack',
    prepared.pack_name,
    'apply',
    current_pack_hash,
    prepared.pack_hash
  );
  event_hash := otlet.identity_hash('workload_pack_event', jsonb_build_object(
    'event_kind', 'apply',
    'application_pack_hash', prepared.pack_hash,
    'pack_name', prepared.pack_name,
    'pack_version', prepared.pack_version,
    'task_name', prepared.task_name,
    'prior_pack_hash', current_pack_hash,
    'result_pack_hash', prepared.pack_hash,
    'prior_spec_hash', current_spec_hash,
    'result_spec_hash', prepared.spec_hash,
    'prior_workload_revision_hash', current_workload_revision_hash,
    'result_workload_revision_hash', result_workload_revision_hash,
    'predecessor_event_hash', predecessor.event_hash,
    'governance_event_hash', governance_event_hash,
    'administrative_event_id', administrative_event_id,
    'created_at', created_at
  ));
  PERFORM set_config('otlet.workload_pack_append', 'on', true);
  INSERT INTO otlet.workload_pack_events (
    event_hash,
    event_kind,
    application_pack_hash,
    pack_name,
    pack_version,
    task_name,
    prior_pack_hash,
    result_pack_hash,
    prior_spec_hash,
    result_spec_hash,
    prior_definition,
    result_definition,
    prior_workload_revision_hash,
    result_workload_revision_hash,
    predecessor_event_hash,
    governance_event_hash,
    administrative_event_id,
    created_at
  ) VALUES (
    event_hash,
    'apply',
    prepared.pack_hash,
    prepared.pack_name,
    prepared.pack_version,
    prepared.task_name,
    current_pack_hash,
    prepared.pack_hash,
    current_spec_hash,
    prepared.spec_hash,
    current_definition,
    result_definition,
    current_workload_revision_hash,
    result_workload_revision_hash,
    predecessor.event_hash,
    governance_event_hash,
    administrative_event_id,
    created_at
  );
  PERFORM set_config(
    'otlet.workload_pack_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN event_hash;
END;
$$;

CREATE FUNCTION otlet.rollback_workload_pack(
  application_event_hash text,
  expected_current_spec_hash text,
  expected_current_workload_revision_hash text,
  reason text,
  ticket text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  application otlet.workload_pack_events%ROWTYPE;
  existing otlet.workload_pack_events%ROWTYPE;
  existing_reason text;
  existing_ticket text;
  current_definition jsonb;
  current_spec_hash text;
  current_workload_revision_hash text;
  staged_workload_revision_hash text;
  result_workload_revision_hash text;
  result_definition jsonb;
  governance_event_hash text;
  administrative_event_id bigint;
  created_at timestamptz := clock_timestamp();
  rollback_event_hash text;
  previous_append text := current_setting('otlet.workload_pack_append', true);
BEGIN
  PERFORM otlet.set_administrative_change_context(
    rollback_workload_pack.reason,
    rollback_workload_pack.ticket
  );
  SELECT event.*
  INTO application
  FROM otlet.workload_pack_events event
  WHERE event.event_hash = rollback_workload_pack.application_event_hash
    AND event.event_kind = 'apply';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload pack application % does not exist',
      rollback_workload_pack.application_event_hash;
  END IF;
  IF application.prior_definition IS NULL
     OR application.prior_spec_hash IS NOT DISTINCT FROM
       application.result_spec_hash THEN
    RAISE EXCEPTION 'otlet workload pack application has no distinct one-step rollback';
  END IF;

  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_revision:' || application.task_name,
    0
  ));
  SELECT event.*
  INTO existing
  FROM otlet.workload_pack_events event
  WHERE event.rollback_of_event_hash = application.event_hash;
  IF FOUND THEN
    SELECT administrative.reason, administrative.ticket
    INTO existing_reason, existing_ticket
    FROM otlet.administrative_change_events administrative
    WHERE administrative.event_id = existing.administrative_event_id;
    IF rollback_workload_pack.expected_current_spec_hash
         IS DISTINCT FROM application.result_spec_hash
       OR rollback_workload_pack.expected_current_workload_revision_hash
         IS DISTINCT FROM application.result_workload_revision_hash
       OR existing_reason IS DISTINCT FROM NULLIF(btrim(rollback_workload_pack.reason), '')
       OR existing_ticket IS DISTINCT FROM NULLIF(btrim(rollback_workload_pack.ticket), '') THEN
      RAISE EXCEPTION 'otlet workload pack rollback retry conflicts';
    END IF;
    RETURN existing.event_hash;
  END IF;
  PERFORM 1
  FROM otlet.workload_pack_events latest
  WHERE latest.event_hash = application.event_hash
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_pack_events successor
      WHERE successor.predecessor_event_hash = latest.event_hash
    )
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload pack rollback is not the latest application';
  END IF;
  SELECT head.active_workload_revision_hash
  INTO current_workload_revision_hash
  FROM otlet.tasks task
  JOIN otlet.workload_revision_heads head ON head.task_name = task.name
  WHERE task.name = application.task_name
    AND task.lifecycle_state = 'active'
  FOR UPDATE OF task, head;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload pack rollback requires an active task';
  END IF;
  current_definition := otlet.export_workload_pack(
    application.pack_name,
    application.pack_version
  );
  current_spec_hash := otlet.workload_pack_spec_hash(current_definition);
  IF rollback_workload_pack.expected_current_spec_hash
       IS DISTINCT FROM current_spec_hash
     OR rollback_workload_pack.expected_current_workload_revision_hash
       IS DISTINCT FROM current_workload_revision_hash
     OR application.result_spec_hash IS DISTINCT FROM current_spec_hash
     OR application.result_workload_revision_hash IS DISTINCT FROM
       current_workload_revision_hash THEN
    RAISE EXCEPTION 'otlet workload pack rollback conflict';
  END IF;

  staged_workload_revision_hash := otlet.stage_workload_pack_configuration(
    application.prior_definition
  );
  IF staged_workload_revision_hash IS DISTINCT FROM
       application.prior_workload_revision_hash THEN
    RAISE EXCEPTION 'otlet workload pack rollback target changed';
  END IF;
  IF current_workload_revision_hash = application.prior_workload_revision_hash THEN
    result_workload_revision_hash := current_workload_revision_hash;
  ELSIF application.governance_event_hash IS NOT NULL THEN
    governance_event_hash := otlet.rollback_workload_promotion(
      application.governance_event_hash,
      current_workload_revision_hash,
      rollback_workload_pack.reason,
      rollback_workload_pack.ticket
    );
    IF NOT EXISTS (
      SELECT 1
      FROM otlet.workload_revision_heads head
      WHERE head.task_name = application.task_name
        AND head.active_workload_revision_hash =
              application.prior_workload_revision_hash
        AND head.previous_workload_revision_hash IS NULL
    ) THEN
      RAISE EXCEPTION 'otlet promotion rollback did not restore the prior workload head';
    END IF;
    result_workload_revision_hash := application.prior_workload_revision_hash;
  ELSE
    result_workload_revision_hash := otlet.rollback_workload_revision(
      application.task_name,
      current_workload_revision_hash,
      application.prior_workload_revision_hash
    );
  END IF;
  result_definition := otlet.export_workload_pack(
    application.pack_name,
    (application.prior_definition ->> 'version')::integer
  );
  IF result_definition IS DISTINCT FROM application.prior_definition
     OR otlet.workload_pack_hash(result_definition) IS DISTINCT FROM
       application.prior_pack_hash THEN
    RAISE EXCEPTION 'otlet workload pack rollback did not restore the prior definition';
  END IF;

  administrative_event_id := otlet.append_administrative_change(
    'workload_pack',
    application.pack_name,
    'rollback',
    application.result_pack_hash,
    application.prior_pack_hash
  );
  rollback_event_hash := otlet.identity_hash(
    'workload_pack_event',
    jsonb_build_object(
      'event_kind', 'rollback',
      'application_pack_hash', application.application_pack_hash,
      'pack_name', application.pack_name,
      'pack_version', (application.prior_definition ->> 'version')::integer,
      'task_name', application.task_name,
      'prior_pack_hash', application.result_pack_hash,
      'result_pack_hash', application.prior_pack_hash,
      'prior_spec_hash', application.result_spec_hash,
      'result_spec_hash', application.prior_spec_hash,
      'prior_workload_revision_hash', current_workload_revision_hash,
      'result_workload_revision_hash', result_workload_revision_hash,
      'predecessor_event_hash', application.event_hash,
      'rollback_of_event_hash', application.event_hash,
      'governance_event_hash', governance_event_hash,
      'administrative_event_id', administrative_event_id,
      'created_at', created_at
    )
  );
  PERFORM set_config('otlet.workload_pack_append', 'on', true);
  INSERT INTO otlet.workload_pack_events (
    event_hash,
    event_kind,
    application_pack_hash,
    pack_name,
    pack_version,
    task_name,
    prior_pack_hash,
    result_pack_hash,
    prior_spec_hash,
    result_spec_hash,
    prior_definition,
    result_definition,
    prior_workload_revision_hash,
    result_workload_revision_hash,
    predecessor_event_hash,
    rollback_of_event_hash,
    governance_event_hash,
    administrative_event_id,
    created_at
  ) VALUES (
    rollback_event_hash,
    'rollback',
    application.application_pack_hash,
    application.pack_name,
    (application.prior_definition ->> 'version')::integer,
    application.task_name,
    application.result_pack_hash,
    application.prior_pack_hash,
    application.result_spec_hash,
    application.prior_spec_hash,
    application.result_definition,
    application.prior_definition,
    current_workload_revision_hash,
    result_workload_revision_hash,
    application.event_hash,
    application.event_hash,
    governance_event_hash,
    administrative_event_id,
    created_at
  );
  PERFORM set_config(
    'otlet.workload_pack_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN rollback_event_hash;
END;
$$;

CREATE VIEW otlet.workload_pack_status AS
WITH latest AS (
  SELECT event.*
  FROM otlet.workload_pack_events event
  WHERE NOT EXISTS (
    SELECT 1
    FROM otlet.workload_pack_events successor
    WHERE successor.predecessor_event_hash = event.event_hash
  )
), configured AS (
  SELECT
    latest.pack_name,
    head.active_workload_revision_hash AS current_active_workload_revision_hash,
    revision_status.configured_revision_hash AS
      configured_workload_revision_hash,
    revision_status.configured_revision_error AS
      configured_workload_revision_error,
    CASE WHEN dependency.error IS NULL THEN 'ready' ELSE 'suspended' END AS
      source_dependency_status,
    dependency.error AS source_dependency_error,
    CASE WHEN watch.name IS NULL THEN NULL::jsonb ELSE otlet.export_workload_pack(
      latest.pack_name,
      (latest.result_definition ->> 'version')::integer
    ) END AS definition,
    task.lifecycle_state
  FROM latest
  LEFT JOIN otlet.watches watch ON watch.name = latest.pack_name
  LEFT JOIN otlet.tasks task ON task.name = latest.task_name
  LEFT JOIN otlet.workload_revision_heads head
    ON head.task_name = latest.task_name
  LEFT JOIN otlet.workload_revisions active
    ON active.task_name = head.task_name
   AND active.workload_revision_hash = head.active_workload_revision_hash
  LEFT JOIN LATERAL otlet.current_workload_revision_status(task.name)
    revision_status ON task.name IS NOT NULL
  LEFT JOIN LATERAL (
    SELECT otlet.source_query_contract_error(
      active.definition #> '{source,query_contract}'
    ) AS error
  ) dependency ON true
), current_state AS (
  SELECT
    configured.*,
    CASE WHEN configured.definition IS NULL THEN NULL
      ELSE otlet.workload_pack_hash(configured.definition)
    END AS configured_pack_hash,
    CASE WHEN configured.definition IS NULL THEN NULL
      ELSE otlet.workload_pack_spec_hash(configured.definition)
    END AS configured_spec_hash
  FROM configured
)
SELECT
  prepared.pack_name,
  prepared.pack_version,
  prepared.pack_hash,
  prepared.spec_hash,
  prepared.task_name,
  prepared.baseline_spec_hash,
  prepared.baseline_workload_revision_hash,
  prepared.candidate_workload_revision_hash,
  prepared.prepared_event_id,
  prepared.prepared_at,
  application.event_hash AS application_event_hash,
  application.governance_event_hash AS promotion_activation_event_hash,
  rollback.event_hash AS rollback_event_hash,
  rollback.governance_event_hash AS promotion_rollback_event_hash,
  CASE
    WHEN application.event_hash IS NULL THEN 'prepared'
    WHEN rollback.event_hash IS NOT NULL THEN 'rolled_back'
    WHEN latest.result_pack_hash = prepared.pack_hash THEN 'applied'
    ELSE 'superseded'
  END AS state,
  latest.event_hash AS latest_event_hash,
  latest.event_kind AS latest_event_kind,
  latest.result_pack_hash AS active_pack_hash,
  latest.result_spec_hash AS active_spec_hash,
  latest.result_workload_revision_hash AS active_workload_revision_hash,
  current_state.current_active_workload_revision_hash,
  current_state.configured_pack_hash,
  current_state.configured_spec_hash,
  current_state.configured_workload_revision_hash,
  current_state.configured_workload_revision_error,
  current_state.source_dependency_status,
  current_state.source_dependency_error,
  current_state.lifecycle_state,
  COALESCE(
    current_state.configured_spec_hash IS DISTINCT FROM latest.result_spec_hash
      OR current_state.current_active_workload_revision_hash IS DISTINCT FROM
        latest.result_workload_revision_hash
      OR current_state.configured_workload_revision_hash IS DISTINCT FROM
        latest.result_workload_revision_hash
      OR current_state.configured_workload_revision_error IS NOT NULL
      OR current_state.source_dependency_status IS DISTINCT FROM 'ready',
    latest.event_hash IS NOT NULL
  ) AS configured_drift,
  application.event_hash IS NOT NULL
    AND rollback.event_hash IS NULL
    AND latest.event_hash = application.event_hash
    AND application.prior_definition IS NOT NULL
    AND application.prior_spec_hash IS DISTINCT FROM application.result_spec_hash
    AND current_state.lifecycle_state = 'active'
    AND current_state.configured_spec_hash = application.result_spec_hash
    AND current_state.current_active_workload_revision_hash =
      application.result_workload_revision_hash
    AND current_state.configured_workload_revision_hash =
      application.result_workload_revision_hash
    AND current_state.configured_workload_revision_error IS NULL
    AND current_state.source_dependency_status = 'ready' AS rollback_ready,
  CASE
    WHEN application.event_hash IS NULL THEN 'not_applied'
    WHEN rollback.event_hash IS NOT NULL THEN 'already_rolled_back'
    WHEN latest.event_hash IS DISTINCT FROM application.event_hash THEN 'not_latest'
    WHEN application.prior_definition IS NULL
      OR application.prior_spec_hash IS NOT DISTINCT FROM
        application.result_spec_hash THEN 'no_distinct_prior_state'
    WHEN current_state.lifecycle_state IS DISTINCT FROM 'active' THEN 'task_inactive'
    WHEN current_state.configured_spec_hash IS DISTINCT FROM
      application.result_spec_hash
      OR current_state.current_active_workload_revision_hash IS DISTINCT FROM
        application.result_workload_revision_hash
      OR current_state.configured_workload_revision_hash IS DISTINCT FROM
        application.result_workload_revision_hash
      OR current_state.configured_workload_revision_error IS NOT NULL
      OR current_state.source_dependency_status IS DISTINCT FROM 'ready'
      THEN 'configured_drift'
    ELSE NULL
  END AS rollback_blocker,
  administrative.actor_name AS applied_by,
  administrative.active_role_name AS applied_as,
  administrative.reason AS apply_reason,
  administrative.ticket AS apply_ticket,
  application.created_at AS applied_at
FROM otlet.workload_pack_definitions prepared
LEFT JOIN otlet.workload_pack_events application
  ON application.application_pack_hash = prepared.pack_hash
 AND application.event_kind = 'apply'
LEFT JOIN otlet.workload_pack_events rollback
  ON rollback.rollback_of_event_hash = application.event_hash
LEFT JOIN latest ON latest.pack_name = prepared.pack_name
LEFT JOIN current_state ON current_state.pack_name = prepared.pack_name
LEFT JOIN otlet.administrative_change_events administrative
  ON administrative.event_id = application.administrative_event_id;

CREATE FUNCTION otlet.verify_workload_pack_invariants()
RETURNS TABLE (
  invariant_name text,
  object_type text,
  object_id text,
  detail jsonb
)
LANGUAGE sql
VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT
    'workload_pack_definition_identity'::text,
    'workload_pack_definition'::text,
    definition.pack_hash,
    jsonb_build_object(
      'stored_pack_hash', definition.pack_hash,
      'computed_pack_hash', otlet.workload_pack_hash(definition.definition),
      'stored_spec_hash', definition.spec_hash,
      'computed_spec_hash', otlet.workload_pack_spec_hash(definition.definition),
      'pack_name', definition.pack_name,
      'definition_name', definition.definition ->> 'name',
      'pack_version', definition.pack_version,
      'definition_version', definition.definition ->> 'version',
      'shape_error', otlet.workload_pack_shape_error(definition.definition)
    )
  FROM otlet.workload_pack_definitions definition
  WHERE definition.pack_hash IS DISTINCT FROM
          otlet.workload_pack_hash(definition.definition)
     OR definition.spec_hash IS DISTINCT FROM
          otlet.workload_pack_spec_hash(definition.definition)
     OR definition.pack_name IS DISTINCT FROM definition.definition ->> 'name'
     OR definition.pack_version::text IS DISTINCT FROM
          definition.definition ->> 'version'
     OR definition.task_name IS DISTINCT FROM
          definition.pack_name || '_task'
     OR otlet.workload_pack_shape_error(definition.definition) IS NOT NULL

  UNION ALL

  SELECT
    'workload_pack_preparation_revision_owner'::text,
    'workload_pack_definition'::text,
    definition.pack_hash,
    jsonb_build_object(
      'task_name', definition.task_name,
      'baseline_workload_revision_hash',
        definition.baseline_workload_revision_hash,
      'candidate_workload_revision_hash',
        definition.candidate_workload_revision_hash
    )
  FROM otlet.workload_pack_definitions definition
  WHERE NOT EXISTS (
      SELECT 1 FROM otlet.workload_revisions revision
      WHERE revision.task_name = definition.task_name
        AND revision.workload_revision_hash =
          definition.baseline_workload_revision_hash
    ) OR NOT EXISTS (
      SELECT 1 FROM otlet.workload_revisions revision
      WHERE revision.task_name = definition.task_name
        AND revision.workload_revision_hash =
          definition.candidate_workload_revision_hash
    )

  UNION ALL

  SELECT
    'workload_pack_preparation_administrative_link'::text,
    'workload_pack_definition'::text,
    definition.pack_hash,
    jsonb_build_object(
      'administrative_event_id', definition.prepared_event_id,
      'object_type', administrative.object_type,
      'object_name', administrative.object_name,
      'operation', administrative.operation,
      'old_revision_hash', administrative.old_revision_hash,
      'new_revision_hash', administrative.new_revision_hash
    )
  FROM otlet.workload_pack_definitions definition
  LEFT JOIN otlet.administrative_change_events administrative
    ON administrative.event_id = definition.prepared_event_id
  WHERE administrative.object_type IS DISTINCT FROM 'workload_pack'
     OR administrative.object_name IS DISTINCT FROM definition.pack_name
     OR administrative.operation IS DISTINCT FROM 'prepare'
     OR administrative.old_revision_hash IS DISTINCT FROM
          definition.baseline_spec_hash
     OR administrative.new_revision_hash IS DISTINCT FROM definition.pack_hash

  UNION ALL

  SELECT
    'workload_pack_event_identity'::text,
    'workload_pack_event'::text,
    event.event_hash,
    jsonb_build_object(
      'stored_event_hash', event.event_hash,
      'computed_event_hash', CASE event.event_kind
        WHEN 'apply' THEN otlet.identity_hash(
          'workload_pack_event',
          jsonb_build_object(
            'event_kind', 'apply',
            'application_pack_hash', event.application_pack_hash,
            'pack_name', event.pack_name,
            'pack_version', event.pack_version,
            'task_name', event.task_name,
            'prior_pack_hash', event.prior_pack_hash,
            'result_pack_hash', event.result_pack_hash,
            'prior_spec_hash', event.prior_spec_hash,
            'result_spec_hash', event.result_spec_hash,
            'prior_workload_revision_hash', event.prior_workload_revision_hash,
            'result_workload_revision_hash', event.result_workload_revision_hash,
            'predecessor_event_hash', event.predecessor_event_hash,
            'governance_event_hash', event.governance_event_hash,
            'administrative_event_id', event.administrative_event_id,
            'created_at', event.created_at
          )
        )
        ELSE otlet.identity_hash(
          'workload_pack_event',
          jsonb_build_object(
            'event_kind', 'rollback',
            'application_pack_hash', event.application_pack_hash,
            'pack_name', event.pack_name,
            'pack_version', event.pack_version,
            'task_name', event.task_name,
            'prior_pack_hash', event.prior_pack_hash,
            'result_pack_hash', event.result_pack_hash,
            'prior_spec_hash', event.prior_spec_hash,
            'result_spec_hash', event.result_spec_hash,
            'prior_workload_revision_hash', event.prior_workload_revision_hash,
            'result_workload_revision_hash', event.result_workload_revision_hash,
            'predecessor_event_hash', event.predecessor_event_hash,
            'rollback_of_event_hash', event.rollback_of_event_hash,
            'governance_event_hash', event.governance_event_hash,
            'administrative_event_id', event.administrative_event_id,
            'created_at', event.created_at
          )
        )
      END,
      'prior_pack_hash', event.prior_pack_hash,
      'computed_prior_pack_hash', CASE WHEN event.prior_definition IS NULL
        THEN NULL ELSE otlet.workload_pack_hash(event.prior_definition) END,
      'result_pack_hash', event.result_pack_hash,
      'computed_result_pack_hash',
        otlet.workload_pack_hash(event.result_definition)
    )
  FROM otlet.workload_pack_events event
  WHERE event.event_hash IS DISTINCT FROM CASE event.event_kind
      WHEN 'apply' THEN otlet.identity_hash(
        'workload_pack_event',
        jsonb_build_object(
          'event_kind', 'apply',
          'application_pack_hash', event.application_pack_hash,
          'pack_name', event.pack_name,
          'pack_version', event.pack_version,
          'task_name', event.task_name,
          'prior_pack_hash', event.prior_pack_hash,
          'result_pack_hash', event.result_pack_hash,
          'prior_spec_hash', event.prior_spec_hash,
          'result_spec_hash', event.result_spec_hash,
          'prior_workload_revision_hash', event.prior_workload_revision_hash,
          'result_workload_revision_hash', event.result_workload_revision_hash,
          'predecessor_event_hash', event.predecessor_event_hash,
          'governance_event_hash', event.governance_event_hash,
          'administrative_event_id', event.administrative_event_id,
          'created_at', event.created_at
        )
      )
      ELSE otlet.identity_hash(
        'workload_pack_event',
        jsonb_build_object(
          'event_kind', 'rollback',
          'application_pack_hash', event.application_pack_hash,
          'pack_name', event.pack_name,
          'pack_version', event.pack_version,
          'task_name', event.task_name,
          'prior_pack_hash', event.prior_pack_hash,
          'result_pack_hash', event.result_pack_hash,
          'prior_spec_hash', event.prior_spec_hash,
          'result_spec_hash', event.result_spec_hash,
          'prior_workload_revision_hash', event.prior_workload_revision_hash,
          'result_workload_revision_hash', event.result_workload_revision_hash,
          'predecessor_event_hash', event.predecessor_event_hash,
          'rollback_of_event_hash', event.rollback_of_event_hash,
          'governance_event_hash', event.governance_event_hash,
          'administrative_event_id', event.administrative_event_id,
          'created_at', event.created_at
        )
      )
    END
     OR event.prior_pack_hash IS DISTINCT FROM CASE
          WHEN event.prior_definition IS NULL THEN NULL
          ELSE otlet.workload_pack_hash(event.prior_definition)
        END
     OR event.result_pack_hash IS DISTINCT FROM
          otlet.workload_pack_hash(event.result_definition)
     OR event.prior_spec_hash IS DISTINCT FROM CASE
          WHEN event.prior_definition IS NULL THEN NULL
          ELSE otlet.workload_pack_spec_hash(event.prior_definition)
        END
     OR event.result_spec_hash IS DISTINCT FROM
          otlet.workload_pack_spec_hash(event.result_definition)
     OR event.pack_name IS DISTINCT FROM event.result_definition ->> 'name'
     OR event.pack_version::text IS DISTINCT FROM
          event.result_definition ->> 'version'
     OR event.task_name IS DISTINCT FROM event.pack_name || '_task'

  UNION ALL

  SELECT
    'workload_pack_application_matches_preparation'::text,
    'workload_pack_event'::text,
    event.event_hash,
    jsonb_build_object(
      'application_pack_hash', event.application_pack_hash,
      'result_pack_hash', event.result_pack_hash,
      'result_spec_hash', event.result_spec_hash,
      'result_workload_revision_hash', event.result_workload_revision_hash
    )
  FROM otlet.workload_pack_events event
  JOIN otlet.workload_pack_definitions definition
    ON definition.pack_hash = event.application_pack_hash
  WHERE event.event_kind = 'apply'
    AND (
      event.pack_name IS DISTINCT FROM definition.pack_name
      OR event.pack_version IS DISTINCT FROM definition.pack_version
      OR event.task_name IS DISTINCT FROM definition.task_name
      OR event.result_pack_hash IS DISTINCT FROM definition.pack_hash
      OR event.result_spec_hash IS DISTINCT FROM definition.spec_hash
      OR event.result_definition IS DISTINCT FROM definition.definition
      OR event.result_workload_revision_hash IS DISTINCT FROM
           definition.candidate_workload_revision_hash
    )

  UNION ALL

  SELECT
    'workload_pack_event_chain_link'::text,
    'workload_pack_event'::text,
    event.event_hash,
    jsonb_build_object(
      'predecessor_event_hash', predecessor.event_hash,
      'pack_name', event.pack_name,
      'predecessor_pack_name', predecessor.pack_name,
      'task_name', event.task_name,
      'predecessor_task_name', predecessor.task_name
    )
  FROM otlet.workload_pack_events event
  JOIN otlet.workload_pack_events predecessor
    ON predecessor.event_hash = event.predecessor_event_hash
  WHERE event.pack_name IS DISTINCT FROM predecessor.pack_name
     OR event.task_name IS DISTINCT FROM predecessor.task_name
     OR event.prior_pack_hash IS DISTINCT FROM predecessor.result_pack_hash
     OR event.prior_spec_hash IS DISTINCT FROM predecessor.result_spec_hash
     OR event.prior_definition IS DISTINCT FROM predecessor.result_definition
     OR event.prior_workload_revision_hash IS DISTINCT FROM
          predecessor.result_workload_revision_hash

  UNION ALL

  SELECT
    'workload_pack_event_administrative_link'::text,
    'workload_pack_event'::text,
    event.event_hash,
    jsonb_build_object(
      'administrative_event_id', event.administrative_event_id,
      'object_type', administrative.object_type,
      'object_name', administrative.object_name,
      'operation', administrative.operation,
      'old_revision_hash', administrative.old_revision_hash,
      'new_revision_hash', administrative.new_revision_hash
    )
  FROM otlet.workload_pack_events event
  LEFT JOIN otlet.administrative_change_events administrative
    ON administrative.event_id = event.administrative_event_id
  WHERE administrative.object_type IS DISTINCT FROM 'workload_pack'
     OR administrative.object_name IS DISTINCT FROM event.pack_name
     OR administrative.operation IS DISTINCT FROM event.event_kind
     OR administrative.old_revision_hash IS DISTINCT FROM event.prior_pack_hash
     OR administrative.new_revision_hash IS DISTINCT FROM event.result_pack_hash

  UNION ALL

  SELECT
    'workload_pack_rollback_mirrors_application'::text,
    'workload_pack_event'::text,
    rollback.event_hash,
    jsonb_build_object(
      'application_event_hash', application.event_hash,
      'rollback_event_hash', rollback.event_hash
    )
  FROM otlet.workload_pack_events rollback
  JOIN otlet.workload_pack_events application
    ON application.event_hash = rollback.rollback_of_event_hash
  WHERE rollback.event_kind <> 'rollback'
     OR application.event_kind <> 'apply'
     OR rollback.application_pack_hash IS DISTINCT FROM
          application.application_pack_hash
     OR rollback.predecessor_event_hash IS DISTINCT FROM application.event_hash
     OR rollback.prior_pack_hash IS DISTINCT FROM application.result_pack_hash
     OR rollback.result_pack_hash IS DISTINCT FROM application.prior_pack_hash
     OR rollback.prior_spec_hash IS DISTINCT FROM application.result_spec_hash
     OR rollback.result_spec_hash IS DISTINCT FROM application.prior_spec_hash
     OR rollback.prior_definition IS DISTINCT FROM application.result_definition
     OR rollback.result_definition IS DISTINCT FROM application.prior_definition
     OR rollback.prior_workload_revision_hash IS DISTINCT FROM
          application.result_workload_revision_hash
     OR rollback.result_workload_revision_hash IS DISTINCT FROM
          application.prior_workload_revision_hash
     OR (application.governance_event_hash IS NULL) IS DISTINCT FROM
          (rollback.governance_event_hash IS NULL)

  UNION ALL

  SELECT
    'workload_pack_governance_event_link'::text,
    'workload_pack_event'::text,
    event.event_hash,
    jsonb_build_object(
      'event_kind', event.event_kind,
      'governance_event_hash', event.governance_event_hash,
      'governance_event_kind', governance.event_kind
    )
  FROM otlet.workload_pack_events event
  LEFT JOIN otlet.workload_pack_events application
    ON application.event_hash = event.rollback_of_event_hash
  LEFT JOIN otlet.workload_acceptance_events governance
    ON governance.event_hash = event.governance_event_hash
  WHERE event.governance_event_hash IS NOT NULL
    AND (
      governance.event_hash IS NULL
      OR governance.task_name IS DISTINCT FROM event.task_name
      OR CASE event.event_kind
        WHEN 'apply' THEN
          governance.event_kind IS DISTINCT FROM 'promotion_activation'
          OR governance.definition #>> '{payload,prior_workload_revision_hash}'
            IS DISTINCT FROM event.prior_workload_revision_hash
          OR governance.definition
            #>> '{payload,resulting_workload_revision_hash}'
            IS DISTINCT FROM event.result_workload_revision_hash
        ELSE
          governance.event_kind IS DISTINCT FROM 'promotion_rollback'
          OR governance.definition
            #>> '{payload,promotion_activation_event_hash}'
            IS DISTINCT FROM application.governance_event_hash
          OR governance.definition #>> '{payload,prior_workload_revision_hash}'
            IS DISTINCT FROM event.prior_workload_revision_hash
          OR governance.definition
            #>> '{payload,resulting_workload_revision_hash}'
            IS DISTINCT FROM event.result_workload_revision_hash
      END
    )

  UNION ALL

  SELECT
    'workload_pack_event_chain_single_root_and_head'::text,
    'workload_pack'::text,
    event.pack_name,
    jsonb_build_object(
      'roots', count(*) FILTER (WHERE event.predecessor_event_hash IS NULL),
      'heads', count(*) FILTER (WHERE NOT EXISTS (
        SELECT 1 FROM otlet.workload_pack_events successor
        WHERE successor.predecessor_event_hash = event.event_hash
      ))
    )
  FROM otlet.workload_pack_events event
  GROUP BY event.pack_name
  HAVING count(*) FILTER (WHERE event.predecessor_event_hash IS NULL) <> 1
      OR count(*) FILTER (WHERE NOT EXISTS (
        SELECT 1 FROM otlet.workload_pack_events successor
        WHERE successor.predecessor_event_hash = event.event_hash
      )) <> 1;
$$;

ALTER FUNCTION otlet.verify_invariants(integer)
RENAME TO verify_invariants_before_workload_pack;

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.verify_invariants_before_workload_pack(integer)'::regprocedure
  );
  IF position('verify_invariants.sample_limit' IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet workload pack invariant wrapper rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(
    definition,
    'verify_invariants.sample_limit',
    'verify_invariants_before_workload_pack.sample_limit'
  );
  EXECUTE definition;
END;
$migration$;

CREATE FUNCTION otlet.verify_invariants(sample_limit integer DEFAULT NULL)
RETURNS TABLE (
  invariant_name text,
  object_type text,
  object_id text,
  detail jsonb
)
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT invariant.*
  FROM otlet.verify_invariants_before_workload_pack(
    verify_invariants.sample_limit
  ) invariant;

  RETURN QUERY
  SELECT invariant.*
  FROM otlet.verify_workload_pack_invariants() invariant;
END;
$$;

REVOKE ALL ON TABLE otlet.workload_pack_definitions FROM PUBLIC;
REVOKE ALL ON TABLE otlet.workload_pack_events FROM PUBLIC;
REVOKE ALL ON TABLE otlet.workload_pack_status FROM PUBLIC;
REVOKE ALL ON SEQUENCE otlet.workload_pack_events_event_id_seq FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_workload_pack_storage() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.workload_pack_hash(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.workload_pack_spec_hash(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.workload_pack_artifact_identity(jsonb)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.export_workload_pack(text,integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.workload_pack_shape_error(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.workload_pack_capability_report(jsonb)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.stage_workload_pack_configuration(jsonb)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.preview_workload_pack(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.lint_workload_pack(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.diff_workload_packs(jsonb,jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.prepare_workload_pack(jsonb,text,text,text,text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.apply_workload_pack(
  text,text,text,text,text,text
)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.rollback_workload_pack(text,text,text,text,text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_workload_pack_invariants() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_invariants_before_workload_pack(integer)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_invariants(integer) FROM PUBLIC;
