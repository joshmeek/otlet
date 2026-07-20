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

CREATE FUNCTION otlet.update_row_idempotency_key(
  action_body jsonb,
  source_content_hash text
) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT md5(
    concat_ws(
      E'\x1f',
      $1 ->> 'target',
      otlet.semantic_canonical_jsonb($1 -> 'identity')::text,
      $2,
      otlet.semantic_canonical_jsonb($1 -> 'changes')::text
    )
  );
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
  job_input jsonb DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_action_type text := COALESCE(action ->> 'type', '');
  body jsonb;
  schema_row otlet.action_type_schemas%ROWTYPE;
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

  SELECT *
  INTO schema_row
  FROM otlet.action_type_schemas s
  WHERE s.action_type = v_action_type;

  IF NOT FOUND THEN
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

