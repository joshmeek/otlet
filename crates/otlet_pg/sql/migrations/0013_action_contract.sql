CREATE FUNCTION otlet.action_target_validation_error(target_name text) RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  target otlet.action_targets%ROWTYPE;
  relation_row record;
  column_name name;
BEGIN
  SELECT * INTO target
  FROM otlet.action_targets t
  WHERE t.name = action_target_validation_error.target_name;

  IF NOT FOUND THEN
    RETURN 'unknown action target';
  ELSIF NOT target.enabled THEN
    RETURN 'action target is disabled';
  END IF;

  SELECT
    c.relkind,
    c.relpersistence,
    c.relispartition,
    c.relrowsecurity,
    c.relforcerowsecurity,
    n.nspname
  INTO relation_row
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE c.oid = target.target_table;

  IF NOT FOUND THEN
    RETURN 'action target table does not exist';
  ELSIF relation_row.relkind <> 'r' THEN
    RETURN 'action target must be an ordinary table';
  ELSIF relation_row.relispartition THEN
    RETURN 'action target cannot be a partition';
  ELSIF relation_row.relpersistence = 't' THEN
    RETURN 'action target cannot be temporary';
  ELSIF relation_row.nspname IN ('pg_catalog', 'information_schema', 'otlet')
     OR relation_row.nspname LIKE 'pg_toast%' THEN
    RETURN 'action target schema is not allowed';
  ELSIF relation_row.relrowsecurity OR relation_row.relforcerowsecurity THEN
    RETURN 'action target cannot use row level security';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_index i
    JOIN pg_catalog.pg_attribute a
      ON a.attrelid = i.indrelid
     AND a.attnum = i.indkey[0]
    WHERE i.indrelid = target.target_table
      AND i.indisprimary
      AND i.indnkeyatts = 1
      AND a.attname = target.identity_column
      AND NOT a.attisdropped
  ) THEN
    RETURN 'action target identity must be its single-column primary key';
  END IF;

  IF cardinality(target.allowed_columns) IS NULL
     OR cardinality(target.allowed_columns) NOT BETWEEN 1 AND 16
     OR target.identity_column = ANY(target.allowed_columns)
     OR EXISTS (SELECT 1 FROM unnest(target.allowed_columns) c WHERE c IS NULL)
     OR cardinality(target.allowed_columns) <> (
       SELECT count(DISTINCT c)::integer FROM unnest(target.allowed_columns) c
     ) THEN
    RETURN 'action target allowed columns are invalid';
  END IF;

  FOREACH column_name IN ARRAY target.allowed_columns LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_attribute a
      WHERE a.attrelid = target.target_table
        AND a.attname = column_name
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND a.attgenerated = ''
        AND a.attidentity = ''
    ) THEN
      RETURN 'action target column is not writable';
    ELSIF NOT pg_catalog.has_column_privilege(
      current_user,
      target.target_table,
      column_name,
      'SELECT'
    ) OR NOT pg_catalog.has_column_privilege(
      current_user,
      target.target_table,
      column_name,
      'UPDATE'
    ) THEN
      RETURN 'action target column privilege is missing';
    END IF;
  END LOOP;

  IF NOT pg_catalog.has_column_privilege(
    current_user,
    target.target_table,
    target.identity_column,
    'SELECT'
  ) THEN
    RETURN 'action target identity privilege is missing';
  END IF;

  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.register_action_target(
  target_name text,
  target_table regclass,
  identity_column name,
  allowed_columns name[]
) RETURNS otlet.action_targets
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.action_targets%ROWTYPE;
  validation_error text;
  normalized_columns name[];
BEGIN
  IF target_name IS NULL OR target_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet action target name is invalid';
  END IF;

  SELECT array_agg(c ORDER BY c) INTO normalized_columns
  FROM unnest(allowed_columns) c;

  INSERT INTO otlet.action_targets (
    name,
    target_table,
    identity_column,
    allowed_columns,
    enabled
  )
  VALUES (
    target_name,
    target_table,
    identity_column,
    normalized_columns,
    true
  )
  ON CONFLICT (name) DO UPDATE
    SET target_table = EXCLUDED.target_table,
        identity_column = EXCLUDED.identity_column,
        allowed_columns = EXCLUDED.allowed_columns,
        enabled = true,
        updated_at = now()
  RETURNING * INTO saved;

  validation_error := otlet.action_target_validation_error(saved.name);
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet %', validation_error;
  END IF;

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.disable_action_target(target_name text) RETURNS otlet.action_targets
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.action_targets%ROWTYPE;
BEGIN
  UPDATE otlet.action_targets t
  SET enabled = false,
      updated_at = now()
  WHERE t.name = disable_action_target.target_name
  RETURNING * INTO saved;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet action target % does not exist', target_name;
  END IF;

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.current_task_contract_hash(task_name text) RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT otlet.task_contract_hash(
    t.instruction,
    t.output_schema,
    t.model_name,
    t.runtime_options,
    t.input_shaping,
    t.decision_contract
  )
  FROM otlet.tasks t
  WHERE t.name = $1;
$$;

CREATE FUNCTION otlet.action_target_contract_hash(target_name text) RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT otlet.identity_hash('action_target_contract', jsonb_build_object(
    'name', t.name,
    'target_table', t.target_table::oid,
    'identity_column', t.identity_column,
    'allowed_columns', to_jsonb(ARRAY(
      SELECT column_name::text
      FROM unnest(t.allowed_columns) column_name
      ORDER BY column_name
    )),
    'enabled', t.enabled
  ))
  FROM otlet.action_targets t
  WHERE t.name = $1;
$$;

CREATE FUNCTION otlet.default_action_authority_hash(
  task_name text,
  action_type text
) RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT otlet.identity_hash('default_action_authority', jsonb_build_object(
    'task_name', $1,
    'action_type', $2,
    'task_contract_hash', otlet.current_task_contract_hash($1),
    'authority_mode', 'recommendation_only',
    'evaluation_status', 'unevaluated'
  ));
$$;

CREATE FUNCTION otlet.register_action_workflow_policy(
  task_name text,
  action_type text,
  target_name text,
  authority_mode text DEFAULT 'recommendation_only',
  evaluation_status text DEFAULT 'unevaluated'
) RETURNS otlet.action_workflow_policies
LANGUAGE plpgsql
AS $$
DECLARE
  task_row otlet.tasks%ROWTYPE;
  watch_row otlet.watches%ROWTYPE;
  target_row otlet.action_targets%ROWTYPE;
  saved otlet.action_workflow_policies%ROWTYPE;
  task_hash text;
  target_hash text;
  policy_hash text;
  target_error text;
BEGIN
  SELECT * INTO task_row
  FROM otlet.tasks t
  WHERE t.name = register_action_workflow_policy.task_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', register_action_workflow_policy.task_name;
  END IF;
  IF register_action_workflow_policy.action_type <> 'update_row' THEN
    RAISE EXCEPTION 'otlet bounded workflow authority only supports update_row';
  END IF;
  IF NOT COALESCE(task_row.decision_contract -> 'action_types', '[]'::jsonb)
    ? register_action_workflow_policy.action_type THEN
    RAISE EXCEPTION 'otlet action type % is not allowed by task %',
      register_action_workflow_policy.action_type,
      register_action_workflow_policy.task_name;
  END IF;
  IF register_action_workflow_policy.authority_mode NOT IN ('recommendation_only', 'bounded_mutation') THEN
    RAISE EXCEPTION 'otlet action authority mode must be recommendation_only or bounded_mutation';
  END IF;
  IF register_action_workflow_policy.evaluation_status NOT IN ('unevaluated', 'evaluated', 'adversarial') THEN
    RAISE EXCEPTION 'otlet action evaluation status must be unevaluated, evaluated, or adversarial';
  END IF;

  SELECT * INTO watch_row
  FROM otlet.watches w
  WHERE w.task_name = register_action_workflow_policy.task_name
    AND w.kind = 'row';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet bounded workflow authority requires a row watch';
  END IF;

  SELECT * INTO target_row
  FROM otlet.action_targets t
  WHERE t.name = register_action_workflow_policy.target_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet action target % does not exist', register_action_workflow_policy.target_name;
  END IF;
  target_error := otlet.action_target_validation_error(register_action_workflow_policy.target_name);
  IF target_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet %', target_error;
  END IF;
  IF target_row.target_table::oid IS DISTINCT FROM to_regclass(watch_row.source_table)::oid THEN
    RAISE EXCEPTION 'otlet action target must match the workflow source table';
  END IF;

  task_hash := otlet.current_task_contract_hash(register_action_workflow_policy.task_name);
  target_hash := otlet.action_target_contract_hash(register_action_workflow_policy.target_name);
  policy_hash := otlet.identity_hash('action_workflow_policy', jsonb_build_object(
    'task_name', register_action_workflow_policy.task_name,
    'action_type', register_action_workflow_policy.action_type,
    'target_name', register_action_workflow_policy.target_name,
    'subject_namespace', watch_row.source_table,
    'authority_mode', register_action_workflow_policy.authority_mode,
    'evaluation_status', register_action_workflow_policy.evaluation_status,
    'task_contract_hash', task_hash,
    'target_contract_hash', target_hash
  ));

  INSERT INTO otlet.action_workflow_policies (
    task_name,
    action_type,
    target_name,
    subject_namespace,
    authority_mode,
    evaluation_status,
    task_contract_hash,
    target_contract_hash,
    policy_hash,
    enabled
  )
  VALUES (
    register_action_workflow_policy.task_name,
    register_action_workflow_policy.action_type,
    register_action_workflow_policy.target_name,
    watch_row.source_table,
    register_action_workflow_policy.authority_mode,
    register_action_workflow_policy.evaluation_status,
    task_hash,
    target_hash,
    policy_hash,
    true
  )
  ON CONFLICT ON CONSTRAINT action_workflow_policies_pkey DO UPDATE
  SET target_name = EXCLUDED.target_name,
      subject_namespace = EXCLUDED.subject_namespace,
      authority_mode = EXCLUDED.authority_mode,
      evaluation_status = EXCLUDED.evaluation_status,
      task_contract_hash = EXCLUDED.task_contract_hash,
      target_contract_hash = EXCLUDED.target_contract_hash,
      policy_hash = EXCLUDED.policy_hash,
      enabled = true,
      updated_at = now()
  RETURNING * INTO saved;

  PERFORM otlet.promote_configured_workload_revision(saved.task_name);
  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.disable_action_workflow_policy(
  task_name text,
  action_type text
) RETURNS otlet.action_workflow_policies
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.action_workflow_policies%ROWTYPE;
BEGIN
  UPDATE otlet.action_workflow_policies p
  SET enabled = false,
      updated_at = now()
  WHERE p.task_name = disable_action_workflow_policy.task_name
    AND p.action_type = disable_action_workflow_policy.action_type
  RETURNING * INTO saved;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet action workflow policy does not exist';
  END IF;
  PERFORM otlet.promote_configured_workload_revision(saved.task_name);
  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.action_workflow_policy_error(
  task_name text,
  action_type text,
  authority_policy_hash text,
  target_name text,
  subject_namespace text,
  require_mutation boolean DEFAULT false
) RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  revision_definition jsonb;
  policy jsonb;
  target_error text;
BEGIN
  SELECT active.definition
  INTO revision_definition
  FROM otlet.active_workload_revision(action_workflow_policy_error.task_name) active;
  IF NOT FOUND THEN
    RETURN 'action workload revision is not active';
  END IF;
  IF NOT COALESCE(revision_definition #> '{task,decision_contract,action_types}', '[]'::jsonb)
    ? action_workflow_policy_error.action_type THEN
    RETURN 'action type is not allowed by workflow';
  END IF;

  policy := revision_definition #> ARRAY[
    'action_policies', action_workflow_policy_error.action_type, 'authority'
  ];
  IF jsonb_typeof(policy) IS DISTINCT FROM 'object'
     OR policy ->> 'origin' IS DISTINCT FROM 'workflow' THEN
    RETURN 'action has no registered workflow authority';
  ELSIF COALESCE((policy ->> 'enabled')::boolean, false) IS NOT TRUE THEN
    RETURN 'action workflow authority is disabled';
  ELSIF policy ->> 'target_contract_hash' IS DISTINCT FROM otlet.action_target_contract_hash(policy ->> 'target_name') THEN
    RETURN 'action workflow target contract changed';
  ELSIF policy ->> 'policy_hash' IS DISTINCT FROM action_workflow_policy_error.authority_policy_hash THEN
    RETURN 'action workflow authority changed';
  ELSIF policy ->> 'target_name' IS DISTINCT FROM action_workflow_policy_error.target_name THEN
    RETURN 'action target does not match workflow authority';
  ELSIF policy ->> 'subject_namespace' IS DISTINCT FROM action_workflow_policy_error.subject_namespace THEN
    RETURN 'action subject namespace does not match workflow authority';
  END IF;

  target_error := otlet.action_target_validation_error(policy ->> 'target_name');
  IF target_error IS NOT NULL THEN
    RETURN target_error;
  END IF;
  IF action_workflow_policy_error.require_mutation
     AND policy ->> 'mode' IS DISTINCT FROM 'bounded_mutation' THEN
    RETURN 'action workflow is recommendation only';
  ELSIF action_workflow_policy_error.require_mutation
     AND policy ->> 'evaluation_status' IS DISTINCT FROM 'evaluated' THEN
    RETURN 'action workflow is not evaluated for mutation';
  END IF;

  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.update_row_idempotency_key(
  action_body jsonb,
  source_content_hash text
) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT otlet.identity_hash('update_row_idempotency', jsonb_build_object(
    'target', $1 ->> 'target',
    'identity', $1 -> 'identity',
    'source_content_hash', $2,
    'changes', $1 -> 'changes'
  ));
$$;

CREATE FUNCTION otlet.action_execution_error(sqlstate text) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT CASE
    WHEN $1 IN ('22P02', '22003', '22007', '22008', '23502')
      THEN 'target value failed type validation'
    WHEN $1 IN ('42P01', '42703', '42804')
      THEN 'action target changed'
    WHEN $1 = '42501'
      THEN 'action target privilege denied'
    ELSE 'bounded update execution failed'
  END;
$$;

CREATE FUNCTION otlet.action_validation_error(
  action jsonb,
  output jsonb DEFAULT NULL,
  job_subject_id text DEFAULT NULL,
  job_input jsonb DEFAULT NULL,
  declared_action_schema jsonb DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_action_type text := COALESCE(action ->> 'type', '');
  body jsonb;
  expected_left_id text;
  expected_right_id text;
  output_confidence text := NULLIF(output ->> 'confidence', '');
  output_rank int;
  action_rank int;
  unsupported_key text;
  target_row otlet.action_targets%ROWTYPE;
  target_error text;
  changed_key text;
  changed_count integer;
  action_identity text;
  source_table_name text;
BEGIN
  IF jsonb_typeof(action) IS DISTINCT FROM 'object' THEN
    RETURN 'action must be an object';
  END IF;

  IF v_action_type = '' THEN
    RETURN 'action missing type';
  END IF;

  IF action_validation_error.declared_action_schema IS NULL THEN
    PERFORM 1
    FROM otlet.action_type_schemas s
    WHERE s.action_type = v_action_type;
    IF NOT FOUND THEN
      RETURN 'unsupported action type';
    END IF;
  ELSIF jsonb_typeof(action_validation_error.declared_action_schema) IS DISTINCT FROM 'object' THEN
    RETURN 'unsupported action type';
  END IF;

  body := CASE
    WHEN v_action_type = 'create_record' THEN action - 'type'
    ELSE action -> 'body'
  END;

  IF v_action_type <> 'create_record' THEN
    SELECT key
    INTO unsupported_key
    FROM jsonb_object_keys(action) AS key
    WHERE key NOT IN ('type', 'body')
    ORDER BY key
    LIMIT 1;

    IF unsupported_key IS NOT NULL THEN
      RETURN 'action has unsupported key';
    END IF;
  END IF;

  IF jsonb_typeof(body) IS DISTINCT FROM 'object' THEN
    RETURN 'action body must be an object';
  END IF;

  expected_left_id := NULLIF(job_input #>> '{action_ids,left_id}', '');
  expected_right_id := NULLIF(job_input #>> '{action_ids,right_id}', '');

  output_rank := CASE output_confidence WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 ELSE NULL END;

  IF v_action_type = 'create_record' THEN
    IF NULLIF(body ->> 'record_type', '') IS NULL THEN
      RETURN 'create_record missing record_type';
    ELSIF NULLIF(body ->> 'subject_id', '') IS NULL THEN
      RETURN 'create_record missing subject_id';
    ELSIF jsonb_typeof(body -> 'body') IS DISTINCT FROM 'object' THEN
      RETURN 'create_record missing body';
    END IF;
    SELECT key
    INTO unsupported_key
    FROM jsonb_object_keys(body) AS key
    WHERE key NOT IN ('record_type', 'subject_id', 'body')
    ORDER BY key
    LIMIT 1;
    IF unsupported_key IS NOT NULL THEN
      RETURN 'create_record unsupported payload field: ' || unsupported_key;
    END IF;
  ELSIF v_action_type = 'merge_candidate' THEN
    IF NULLIF(body ->> 'left_id', '') IS NULL THEN
      RETURN 'merge_candidate missing left_id';
    ELSIF NULLIF(body ->> 'right_id', '') IS NULL THEN
      RETURN 'merge_candidate missing right_id';
    ELSIF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'merge_candidate missing reason';
    ELSIF NULLIF(output ->> 'match', '') IS NOT NULL AND output ->> 'match' <> 'same_entity' THEN
      RETURN 'merge_candidate requires same_entity output';
    ELSIF expected_left_id IS NULL OR expected_right_id IS NULL THEN
      RETURN 'merge_candidate requires input.action_ids left_id and right_id';
    ELSIF body ->> 'left_id' <> expected_left_id OR body ->> 'right_id' <> expected_right_id THEN
      RETURN 'merge_candidate subject ids must match job subject_id';
    ELSIF body ? 'confidence' AND body ->> 'confidence' NOT IN ('low', 'medium', 'high') THEN
      RETURN 'merge_candidate confidence must be low, medium, or high';
    END IF;
    action_rank := CASE body ->> 'confidence' WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 ELSE NULL END;
    IF output_rank IS NOT NULL AND action_rank IS NOT NULL AND action_rank > output_rank THEN
      RETURN 'merge_candidate confidence cannot exceed output confidence';
    END IF;
    IF body ? 'evidence'
       AND NOT (
         (jsonb_typeof(body -> 'evidence') = 'array' AND jsonb_array_length(body -> 'evidence') > 0)
         OR (jsonb_typeof(body -> 'evidence') = 'string' AND btrim(body ->> 'evidence') <> '')
       ) THEN
      RETURN 'merge_candidate missing decisive evidence';
    END IF;
  ELSIF v_action_type = 'new_entity' THEN
    IF NULLIF(body ->> 'entity_id', '') IS NULL THEN
      RETURN 'new_entity missing entity_id';
    ELSIF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'new_entity missing reason';
    ELSIF NULLIF(output ->> 'match', '') IS NOT NULL AND output ->> 'match' <> 'different_entity' THEN
      RETURN 'new_entity requires different_entity output';
    ELSIF expected_right_id IS NULL THEN
      RETURN 'new_entity requires input.action_ids right_id';
    ELSIF body ->> 'entity_id' <> expected_right_id THEN
      RETURN 'new_entity entity_id must match job right subject_id';
    END IF;
    IF body ? 'evidence'
       AND NOT (
         (jsonb_typeof(body -> 'evidence') = 'array' AND jsonb_array_length(body -> 'evidence') > 0)
         OR (jsonb_typeof(body -> 'evidence') = 'string' AND btrim(body ->> 'evidence') <> '')
       ) THEN
      RETURN 'new_entity missing separation evidence';
    END IF;
  ELSIF v_action_type = 'review_flag' THEN
    IF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'review_flag missing reason';
    ELSIF body ? 'severity' AND body ->> 'severity' NOT IN ('low', 'medium', 'high') THEN
      RETURN 'review_flag severity must be low, medium, or high';
    ELSIF NULLIF(output ->> 'match', '') IS NOT NULL AND output ->> 'match' <> 'unclear' THEN
      RETURN 'review_flag requires unclear output';
    ELSIF expected_left_id IS NOT NULL
       AND NULLIF(body ->> 'left_id', '') IS NOT NULL
       AND (body ->> 'left_id' <> expected_left_id OR body ->> 'right_id' <> expected_right_id) THEN
      RETURN 'review_flag subject ids must match job subject_id';
    END IF;
  ELSIF v_action_type = 'note' THEN
    IF NULLIF(body ->> 'subject_id', '') IS NULL THEN
      RETURN 'note missing subject_id';
    ELSIF NULLIF(body ->> 'text', '') IS NULL THEN
      RETURN 'note missing text';
    END IF;
  ELSIF v_action_type = 'update_row' THEN
    IF pg_column_size(action) > 16384 THEN
      RETURN 'update_row exceeds 16384 byte limit';
    END IF;
    SELECT key INTO unsupported_key
    FROM jsonb_object_keys(body) key
    WHERE key NOT IN ('target', 'identity', 'changes')
    ORDER BY key
    LIMIT 1;
    IF unsupported_key IS NOT NULL THEN
      RETURN 'update_row has unsupported body key';
    ELSIF NULLIF(body ->> 'target', '') IS NULL THEN
      RETURN 'update_row missing target';
    ELSIF jsonb_typeof(body -> 'identity') NOT IN ('string', 'number') THEN
      RETURN 'update_row identity must be a string or number';
    ELSIF jsonb_typeof(body -> 'changes') IS DISTINCT FROM 'object' THEN
      RETURN 'update_row changes must be a non-empty object';
    END IF;
    SELECT count(*)::integer INTO changed_count
    FROM jsonb_object_keys(body -> 'changes');
    IF changed_count = 0 THEN
      RETURN 'update_row changes must be a non-empty object';
    ELSIF changed_count > 16 THEN
      RETURN 'update_row changes exceed 16 columns';
    END IF;

    SELECT * INTO target_row
    FROM otlet.action_targets t
    WHERE t.name = body ->> 'target';
    target_error := otlet.action_target_validation_error(body ->> 'target');
    IF target_error IS NOT NULL THEN
      RETURN target_error;
    END IF;

    action_identity := body #>> '{identity}';
    source_table_name := job_input #>> '{_otlet_mvcc,table}';
    IF source_table_name IS NULL THEN
      source_table_name := job_input #>> '{otlet_mvcc,table}';
    END IF;
    IF action_identity IS DISTINCT FROM job_subject_id THEN
      RETURN 'update_row identity must match job subject_id';
    ELSIF target_row.target_table::oid IS DISTINCT FROM to_regclass(source_table_name)::oid THEN
      RETURN 'update_row target must match source table';
    END IF;

    SELECT key INTO changed_key
    FROM jsonb_object_keys(body -> 'changes') key
    WHERE NOT key::name = ANY(target_row.allowed_columns)
    ORDER BY key
    LIMIT 1;
    IF changed_key IS NOT NULL THEN
      RETURN 'update_row column is not allowed';
    END IF;

    SELECT changed.key INTO changed_key
    FROM jsonb_each(body -> 'changes') changed
    JOIN pg_catalog.pg_attribute a
      ON a.attrelid = target_row.target_table
     AND a.attname = changed.key
     AND a.attnum > 0
     AND NOT a.attisdropped
    WHERE changed.value = 'null'::jsonb
      AND a.attnotnull
    ORDER BY changed.key
    LIMIT 1;
    IF changed_key IS NOT NULL THEN
      RETURN 'update_row cannot set a required column to null';
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.workload_model_definition(model_name text) RETURNS jsonb
LANGUAGE sql
STABLE
STRICT
AS $$
  SELECT jsonb_build_object(
    'name', m.name,
    'artifact_path', m.artifact_path,
    'artifact_hash', m.artifact_hash,
    'artifact_identity', m.artifact_identity,
    'max_active_jobs', m.max_active_jobs
  )
  FROM otlet.models m
  WHERE m.name = $1;
$$;

CREATE FUNCTION otlet.current_workload_revision_definition(task_name text) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  definition jsonb;
BEGIN
  SELECT jsonb_build_object(
    'format', 'otlet.workload.v1',
    'task', jsonb_build_object(
      'name', t.name,
      'input_query', t.input_query,
      'instruction', t.instruction,
      'output_schema', t.output_schema,
      'runtime_options', t.runtime_options,
      'input_shaping', t.input_shaping,
      'decision_contract', t.decision_contract
    ),
    'source', COALESCE((
      SELECT jsonb_strip_nulls(jsonb_build_object(
        'watch_name', w.name,
        'kind', w.kind,
        'semantic_index_name', w.semantic_index_name,
        'semantic_join_index_name', w.semantic_join_index_name,
        'source_table', w.source_table,
        'subject_column', w.subject_column,
        'input_columns', to_jsonb(w.input_columns),
        'candidate_query', w.candidate_query,
        'pair_sources', w.pair_sources,
        'max_candidate_rows', w.max_candidate_rows,
        'record_type', w.record_type
      ))
      FROM otlet.watches w
      WHERE w.task_name = t.name
    ), (
      SELECT jsonb_build_object(
        'kind', 'row',
        'semantic_index_name', si.name,
        'source_table', si.source_table,
        'subject_column', si.subject_column,
        'input_columns', to_jsonb(si.input_columns),
        'record_type', si.record_type
      )
      FROM otlet.semantic_indexes si
      WHERE si.task_name = t.name
    ), (
      SELECT jsonb_build_object(
        'kind', 'pair',
        'semantic_join_index_name', sji.name,
        'candidate_query', sji.candidate_query,
        'max_candidate_rows', sji.max_candidate_rows,
        'record_type', sji.record_type
      )
      FROM otlet.semantic_join_indexes sji
      WHERE sji.task_name = t.name
    ), 'null'::jsonb),
    'prompt_builder', jsonb_build_object(
      'version', 'otlet_raw_json_worker_v1'
    ),
    'validator', jsonb_build_object(
      'version', 'otlet_portable_validation_v1',
      'schema_force', 'postgres_portable_json_schema_validation'
    ),
    'decode', jsonb_build_object(
      'mode', 'deterministic',
      'sampler', 'greedy',
      'constraint', 'greedy_with_balanced_json_object_stop_post_generation_schema_check'
    ),
    'runtime', jsonb_build_object(
      'effective_options', p.default_runtime_options || t.runtime_options,
      'effective_max_attempt_ms', otlet.effective_task_max_attempt_ms(
        p.default_runtime_options || t.runtime_options,
        p.max_attempt_ms
      ),
      'lease_ms', round(EXTRACT(epoch FROM otlet.effective_job_lease_interval(
        p.default_runtime_options || t.runtime_options,
        p.max_attempt_ms,
        p.job_lease_interval
      )) * 1000)::bigint,
      'output_options', jsonb_build_object(
        'reasoning', COALESCE((p.default_runtime_options || t.runtime_options) ->> 'reasoning', 'off'),
        'max_tokens', COALESCE(
          (p.default_runtime_options || t.runtime_options) -> 'max_tokens',
          '512'::jsonb
        )
      )
    ),
    'models', jsonb_build_object(
      'direct', otlet.workload_model_definition(t.model_name),
      'cheap', otlet.workload_model_definition(selection.cheap_model_name),
      'strong', otlet.workload_model_definition(selection.strong_model_name)
    ),
    'selection', CASE WHEN selection.task_name IS NULL THEN 'null'::jsonb ELSE jsonb_build_object(
      'cheap_model_name', selection.cheap_model_name,
      'strong_model_name', selection.strong_model_name,
      'accept_field_checks', selection.accept_field_checks
    ) END,
    'action_policies', COALESCE((
      SELECT jsonb_object_agg(
        action_type.action_type,
        jsonb_build_object(
          'schema', jsonb_build_object(
            'requires_approval', action_schema.requires_approval,
            'creates_record', action_schema.creates_record,
            'applyable', action_schema.applyable
          ),
          'authority', CASE WHEN workflow.task_name IS NULL THEN jsonb_build_object(
            'origin', 'system',
            'enabled', true,
            'mode', 'recommendation_only',
            'evaluation_status', 'unevaluated',
            'policy_hash', otlet.default_action_authority_hash(t.name, action_type.action_type),
            'subject_namespace', COALESCE((
              SELECT si.source_table
              FROM otlet.semantic_indexes si
              WHERE si.task_name = t.name
            ), 'task:' || t.name)
          ) ELSE jsonb_build_object(
            'origin', 'workflow',
            'enabled', workflow.enabled,
            'mode', workflow.authority_mode,
            'evaluation_status', workflow.evaluation_status,
            'policy_hash', workflow.policy_hash,
            'target_name', workflow.target_name,
            'target_contract_hash', workflow.target_contract_hash,
            'subject_namespace', workflow.subject_namespace
          ) END
        )
        ORDER BY action_type.action_type
      )
      FROM (
        SELECT DISTINCT relevant.action_type
        FROM (
          SELECT declared.value AS action_type
          FROM jsonb_array_elements_text(
            COALESCE(t.decision_contract -> 'action_types', '[]'::jsonb)
          ) declared(value)
          UNION ALL
          SELECT 'create_record'
          WHERE EXISTS (
            SELECT 1 FROM otlet.semantic_indexes si WHERE si.task_name = t.name
          ) OR EXISTS (
            SELECT 1 FROM otlet.semantic_join_indexes sji WHERE sji.task_name = t.name
          )
        ) relevant
      ) action_type
      JOIN otlet.action_type_schemas action_schema
        ON action_schema.action_type = action_type.action_type
      LEFT JOIN otlet.action_workflow_policies workflow
        ON workflow.task_name = t.name
       AND workflow.action_type = action_type.action_type
    ), '{}'::jsonb)
  )
  INTO definition
  FROM otlet.tasks t
  CROSS JOIN otlet.production_policy p
  LEFT JOIN otlet.model_selection_policies selection ON selection.task_name = t.name
  WHERE t.name = current_workload_revision_definition.task_name
    AND p.name = 'default';

  RETURN definition;
END;
$$;

CREATE FUNCTION otlet.validate_workload_revision() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.definition ->> 'format' IS DISTINCT FROM 'otlet.workload.v1'
     OR NEW.definition #>> '{task,name}' IS DISTINCT FROM NEW.task_name THEN
    RAISE EXCEPTION 'otlet workload revision definition is invalid';
  END IF;
  IF NEW.workload_revision_hash IS DISTINCT FROM otlet.identity_hash(
    'workload_revision',
    NEW.definition
  ) THEN
    RAISE EXCEPTION 'otlet workload revision hash does not match its definition';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM (
      SELECT declared.value AS action_type
      FROM jsonb_array_elements_text(
        COALESCE(NEW.definition #> '{task,decision_contract,action_types}', '[]'::jsonb)
      ) declared(value)
      UNION
      SELECT 'create_record'
      WHERE NEW.definition #>> '{source,kind}' IN ('row', 'pair')
    ) required_action
    WHERE jsonb_typeof(NEW.definition #> ARRAY[
      'action_policies', required_action.action_type, 'schema'
    ]) IS DISTINCT FROM 'object'
       OR jsonb_typeof(NEW.definition #> ARRAY[
         'action_policies', required_action.action_type, 'authority'
       ]) IS DISTINCT FROM 'object'
  ) THEN
    RAISE EXCEPTION 'otlet workload revision action contract is incomplete';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_revisions_validate
BEFORE INSERT ON otlet.workload_revisions
FOR EACH ROW EXECUTE FUNCTION otlet.validate_workload_revision();

CREATE FUNCTION otlet.reject_workload_revision_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'otlet workload revisions are immutable';
END;
$$;

CREATE TRIGGER workload_revisions_immutable
BEFORE UPDATE OR DELETE ON otlet.workload_revisions
FOR EACH ROW EXECUTE FUNCTION otlet.reject_workload_revision_change();

CREATE TRIGGER workload_revisions_truncate_immutable
BEFORE TRUNCATE ON otlet.workload_revisions
FOR EACH STATEMENT EXECUTE FUNCTION otlet.reject_workload_revision_change();

CREATE FUNCTION otlet.capture_workload_revision(task_name text) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  revision_definition jsonb;
  revision_hash text;
  stored_definition jsonb;
BEGIN
  revision_definition := otlet.current_workload_revision_definition(
    capture_workload_revision.task_name
  );
  IF revision_definition IS NULL THEN
    RAISE EXCEPTION 'otlet task % does not exist', capture_workload_revision.task_name;
  END IF;

  revision_hash := otlet.identity_hash('workload_revision', revision_definition);
  INSERT INTO otlet.workload_revisions (
    workload_revision_hash,
    task_name,
    definition
  )
  VALUES (
    revision_hash,
    capture_workload_revision.task_name,
    revision_definition
  )
  ON CONFLICT (workload_revision_hash) DO NOTHING;

  SELECT r.definition
  INTO stored_definition
  FROM otlet.workload_revisions r
  WHERE r.workload_revision_hash = revision_hash
    AND r.task_name = capture_workload_revision.task_name;
  IF NOT FOUND OR stored_definition IS DISTINCT FROM revision_definition THEN
    RAISE EXCEPTION 'otlet workload revision hash collision';
  END IF;

  RETURN revision_hash;
END;
$$;

CREATE FUNCTION otlet.active_workload_revision(task_name text)
RETURNS TABLE (
  workload_revision_hash text,
  definition jsonb
)
LANGUAGE sql
STABLE
AS $$
  SELECT head.active_workload_revision_hash, revision.definition
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = active_workload_revision.task_name;
$$;

CREATE FUNCTION otlet.ensure_active_workload_revision(task_name text) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  active_hash text;
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || ensure_active_workload_revision.task_name, 0)
  );

  SELECT head.active_workload_revision_hash
  INTO active_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = ensure_active_workload_revision.task_name;
  IF FOUND THEN
    RETURN active_hash;
  END IF;

  active_hash := otlet.capture_workload_revision(ensure_active_workload_revision.task_name);
  INSERT INTO otlet.workload_revision_heads (
    task_name,
    active_workload_revision_hash
  )
  VALUES (
    ensure_active_workload_revision.task_name,
    active_hash
  );
  RETURN active_hash;
END;
$$;

CREATE FUNCTION otlet.promote_workload_revision(
  task_name text,
  target_workload_revision_hash text,
  expected_active_workload_revision_hash text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  active_hash text;
BEGIN
  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || promote_workload_revision.task_name, 0)
  );

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.workload_revisions revision
    WHERE revision.task_name = promote_workload_revision.task_name
      AND revision.workload_revision_hash = promote_workload_revision.target_workload_revision_hash
  ) THEN
    RAISE EXCEPTION 'otlet workload revision does not belong to task %', promote_workload_revision.task_name;
  END IF;

  SELECT head.active_workload_revision_hash
  INTO active_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = promote_workload_revision.task_name
  FOR UPDATE;

  IF NOT FOUND THEN
    IF promote_workload_revision.expected_active_workload_revision_hash IS NOT NULL THEN
      RAISE EXCEPTION 'otlet workload revision promotion conflict: task % has no active revision', promote_workload_revision.task_name;
    END IF;
    INSERT INTO otlet.workload_revision_heads (
      task_name,
      active_workload_revision_hash
    )
    VALUES (
      promote_workload_revision.task_name,
      promote_workload_revision.target_workload_revision_hash
    );
  ELSE
    IF promote_workload_revision.expected_active_workload_revision_hash IS NULL
       OR active_hash IS DISTINCT FROM promote_workload_revision.expected_active_workload_revision_hash THEN
      RAISE EXCEPTION 'otlet workload revision promotion conflict for task %', promote_workload_revision.task_name;
    END IF;
    IF active_hash = promote_workload_revision.target_workload_revision_hash THEN
      RETURN active_hash;
    END IF;

    UPDATE otlet.workload_revision_heads head
    SET previous_workload_revision_hash = active_hash,
        active_workload_revision_hash = promote_workload_revision.target_workload_revision_hash,
        promoted_at = now()
    WHERE head.task_name = promote_workload_revision.task_name;
  END IF;

  UPDATE otlet.semantic_materializations materialization
  SET stale = true,
      stale_reason = 'contract_changed',
      updated_at = now()
  WHERE materialization.task_name = promote_workload_revision.task_name
    AND materialization.contract_hash IS DISTINCT FROM promote_workload_revision.target_workload_revision_hash;

  RETURN promote_workload_revision.target_workload_revision_hash;
END;
$$;

CREATE FUNCTION otlet.promote_configured_workload_revision(task_name text) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  active_hash text;
  target_hash text;
BEGIN
  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || promote_configured_workload_revision.task_name, 0)
  );
  target_hash := otlet.capture_workload_revision(promote_configured_workload_revision.task_name);
  SELECT head.active_workload_revision_hash
  INTO active_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = promote_configured_workload_revision.task_name;

  IF active_hash IS NOT DISTINCT FROM target_hash THEN
    RETURN target_hash;
  END IF;
  RETURN otlet.promote_workload_revision(
    promote_configured_workload_revision.task_name,
    target_hash,
    active_hash
  );
END;
$$;

CREATE FUNCTION otlet.rollback_workload_revision(
  task_name text,
  expected_active_workload_revision_hash text,
  target_workload_revision_hash text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  rollback_hash text;
BEGIN
  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || rollback_workload_revision.task_name, 0)
  );
  SELECT COALESCE(
    rollback_workload_revision.target_workload_revision_hash,
    head.previous_workload_revision_hash
  )
  INTO rollback_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = rollback_workload_revision.task_name
    AND head.active_workload_revision_hash = rollback_workload_revision.expected_active_workload_revision_hash;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision rollback conflict for task %', rollback_workload_revision.task_name;
  END IF;
  IF rollback_hash IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no workload revision to roll back to', rollback_workload_revision.task_name;
  END IF;

  RETURN otlet.promote_workload_revision(
    rollback_workload_revision.task_name,
    rollback_hash,
    rollback_workload_revision.expected_active_workload_revision_hash
  );
END;
$$;

CREATE FUNCTION otlet.workload_revision_diff(
  task_name text,
  from_workload_revision_hash text,
  to_workload_revision_hash text
) RETURNS TABLE (
  path text,
  old_value jsonb,
  new_value jsonb
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  old_definition jsonb;
  new_definition jsonb;
BEGIN
  SELECT revision.definition
  INTO old_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = workload_revision_diff.task_name
    AND revision.workload_revision_hash = workload_revision_diff.from_workload_revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision does not belong to task %', workload_revision_diff.task_name;
  END IF;

  SELECT revision.definition
  INTO new_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = workload_revision_diff.task_name
    AND revision.workload_revision_hash = workload_revision_diff.to_workload_revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision does not belong to task %', workload_revision_diff.task_name;
  END IF;

  RETURN QUERY
  WITH RECURSIVE nodes(node_path, old_node, new_node) AS (
    SELECT ''::text, old_definition, new_definition
    UNION ALL
    SELECT
      nodes.node_path || '/' || replace(replace(child.key, '~', '~0'), '/', '~1'),
      nodes.old_node -> child.key,
      nodes.new_node -> child.key
    FROM nodes
    CROSS JOIN LATERAL (
      SELECT key
      FROM jsonb_object_keys(
        CASE WHEN jsonb_typeof(nodes.old_node) = 'object' THEN nodes.old_node ELSE '{}'::jsonb END
      ) key
      UNION
      SELECT key
      FROM jsonb_object_keys(
        CASE WHEN jsonb_typeof(nodes.new_node) = 'object' THEN nodes.new_node ELSE '{}'::jsonb END
      ) key
    ) child
    WHERE jsonb_typeof(nodes.old_node) = 'object'
      AND jsonb_typeof(nodes.new_node) = 'object'
  )
  SELECT nodes.node_path, nodes.old_node, nodes.new_node
  FROM nodes
  WHERE nodes.node_path <> ''
    AND nodes.old_node IS DISTINCT FROM nodes.new_node
    AND (
      jsonb_typeof(nodes.old_node) IS DISTINCT FROM 'object'
      OR jsonb_typeof(nodes.new_node) IS DISTINCT FROM 'object'
    )
  ORDER BY nodes.node_path;
END;
$$;

CREATE FUNCTION otlet.repair_workload_revision(
  task_name text,
  expected_active_workload_revision_hash text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  revision_definition jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || repair_workload_revision.task_name, 0)
  );
  SELECT revision.definition
  INTO revision_definition
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = repair_workload_revision.task_name
    AND head.active_workload_revision_hash = repair_workload_revision.expected_active_workload_revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision repair conflict for task %', repair_workload_revision.task_name;
  END IF;

  IF revision_definition #>> '{source,kind}' NOT IN ('row', 'pair')
     OR NULLIF(revision_definition #>> '{task,input_query}', '') IS NULL THEN
    RETURN 0;
  END IF;

  RETURN otlet.materialize_semantic_records(
    repair_workload_revision.task_name,
    revision_definition #>> '{source,record_type}',
    revision_definition #>> '{source,source_table}',
    revision_definition #>> '{task,input_query}'
  );
END;
$$;

CREATE FUNCTION otlet.bind_job_workload_revision() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  active_hash text;
BEGIN
  active_hash := otlet.ensure_active_workload_revision(NEW.task_name);
  IF NEW.workload_revision_hash IS NULL THEN
    NEW.workload_revision_hash := active_hash;
  ELSIF NEW.workload_revision_hash IS DISTINCT FROM active_hash THEN
    RAISE EXCEPTION 'otlet job workload revision is not active for task %', NEW.task_name;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER jobs_bind_workload_revision
BEFORE INSERT ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION otlet.bind_job_workload_revision();

CREATE FUNCTION otlet.reject_job_workload_revision_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.task_name IS DISTINCT FROM OLD.task_name
     OR NEW.workload_revision_hash IS DISTINCT FROM OLD.workload_revision_hash THEN
    RAISE EXCEPTION 'otlet job workload revision is immutable';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER jobs_workload_revision_immutable
BEFORE UPDATE OF task_name, workload_revision_hash ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION otlet.reject_job_workload_revision_change();
