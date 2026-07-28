CREATE FUNCTION otlet.watch_change_trigger() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  watch_task_name text;
  watch_on_change text;
  row_input jsonb;
  subject_id text;
BEGIN
  SELECT w.task_name, COALESCE(w.trigger_policy ->> 'on_change', 'mark_stale')
  INTO watch_task_name, watch_on_change
  FROM otlet.watches w
  WHERE w.name = TG_ARGV[1]
    AND w.kind = 'row';

  IF NOT FOUND THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    row_input := to_jsonb(OLD);
  ELSE
    row_input := to_jsonb(NEW);
  END IF;

  subject_id := row_input ->> TG_ARGV[0];
  PERFORM otlet.mark_semantic_stale(
    format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME),
    subject_id,
    CASE WHEN TG_OP = 'DELETE' THEN 'source_delete' ELSE 'source_update' END
  );

  IF TG_OP <> 'DELETE'
     AND watch_on_change = 'mark_stale_and_enqueue'
     AND subject_id IS NOT NULL THEN
    PERFORM otlet.run_task_subject(watch_task_name, subject_id);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION otlet.watch_semantic_change(
  table_name regclass,
  subject_column text DEFAULT 'id',
  watch_name text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  trigger_name text := 'otlet_watch_' || substr(md5(table_name::text || ':' || subject_column || ':' || COALESCE(watch_name, '')), 1, 16);
BEGIN
  IF watch_name IS NULL OR watch_name = '' THEN
    RAISE EXCEPTION 'otlet watch name is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = table_name
      AND attname = subject_column
      AND attnum > 0
      AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'otlet subject column % does not exist on %', subject_column, table_name;
  END IF;

  EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trigger_name, table_name);
  EXECUTE format(
    'CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION otlet.watch_change_trigger(%L, %L)',
    trigger_name,
    table_name,
    subject_column,
    watch_name
  );

  RETURN trigger_name;
END;
$$;

CREATE FUNCTION otlet.drop_watch(
  watch_name text
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  watch_row otlet.watches%ROWTYPE;
  trigger_name text;
  pair_source jsonb;
  pair_source_table text;
  pair_source_subject_column text;
BEGIN
  SELECT *
  INTO watch_row
  FROM otlet.watches w
  WHERE w.name = drop_watch.watch_name;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF watch_row.kind = 'row'
     AND watch_row.source_table IS NOT NULL
     AND to_regclass(watch_row.source_table) IS NOT NULL THEN
    trigger_name := 'otlet_watch_' || substr(md5(to_regclass(watch_row.source_table)::text || ':' || watch_row.subject_column || ':' || watch_row.name), 1, 16);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trigger_name, watch_row.source_table);
  END IF;

  DELETE FROM otlet.watches w
  WHERE w.name = watch_row.name;

  IF watch_row.kind = 'row' AND watch_row.semantic_index_name IS NOT NULL THEN
    PERFORM otlet.drop_watch_row_index(watch_row.semantic_index_name);
  ELSIF watch_row.kind = 'pair' AND watch_row.semantic_join_index_name IS NOT NULL THEN
    PERFORM otlet.drop_watch_pair_index(watch_row.semantic_join_index_name);
  END IF;

  IF watch_row.kind = 'pair' THEN
    FOR pair_source IN
      SELECT value
      FROM jsonb_array_elements(COALESCE(watch_row.pair_sources, '[]'::jsonb)) source(value)
    LOOP
      pair_source_table := pair_source ->> 'table';
      pair_source_subject_column := COALESCE(NULLIF(pair_source ->> 'subject_column', ''), 'id');

      IF pair_source_table IS NOT NULL
         AND to_regclass(pair_source_table) IS NOT NULL
         AND NOT EXISTS (
           SELECT 1
           FROM otlet.semantic_indexes si
           WHERE si.source_table = pair_source_table
             AND si.subject_column = pair_source_subject_column
         )
         AND NOT EXISTS (
           SELECT 1
           FROM otlet.watches w
           CROSS JOIN LATERAL jsonb_array_elements(COALESCE(w.pair_sources, '[]'::jsonb)) source(value)
           WHERE source.value ->> 'table' = pair_source_table
             AND COALESCE(NULLIF(source.value ->> 'subject_column', ''), 'id') = pair_source_subject_column
         ) THEN
        trigger_name := 'otlet_stale_' || substr(
          md5(pair_source_table::regclass::text || ':' || pair_source_subject_column),
          1,
          16
        );
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trigger_name, pair_source_table);
      END IF;
    END LOOP;
  END IF;

  RETURN true;
END;
$$;

CREATE FUNCTION otlet.create_watch(
  watch_name text,
  kind text,
  instruction text,
  output_schema jsonb,
  model_name text,
  table_name regclass DEFAULT NULL,
  subject_column text DEFAULT 'id',
  candidate_query text DEFAULT NULL,
  record_type text DEFAULT NULL,
  runtime_options jsonb DEFAULT '{}'::jsonb,
  selection_policy jsonb DEFAULT '{}'::jsonb,
  trigger_policy jsonb DEFAULT '{"on_change":"mark_stale"}'::jsonb,
  action_types text[] DEFAULT '{}'::text[],
  stale_policy text DEFAULT 'refresh_then_fail_closed',
  input_shaping jsonb DEFAULT '{}'::jsonb,
  decision_contract jsonb DEFAULT '{}'::jsonb,
  max_candidate_rows integer DEFAULT 1000,
  input_columns text[] DEFAULT NULL,
  pair_sources jsonb DEFAULT '[]'::jsonb
) RETURNS otlet.watches
LANGUAGE plpgsql
AS $$
DECLARE
  existing_watch otlet.watches%ROWTYPE;
  actual_kind text := lower(COALESCE(create_watch.kind, ''));
  actual_record_type text := COALESCE(create_watch.record_type, create_watch.watch_name);
  actual_runtime_options jsonb := COALESCE(create_watch.runtime_options, '{}'::jsonb);
  actual_selection_policy jsonb := COALESCE(create_watch.selection_policy, '{}'::jsonb);
  actual_trigger_policy jsonb := COALESCE(create_watch.trigger_policy, '{"on_change":"mark_stale"}'::jsonb);
  actual_action_types text[] := COALESCE(create_watch.action_types, '{}'::text[]);
  actual_stale_policy text := COALESCE(create_watch.stale_policy, 'refresh_then_fail_closed');
  actual_input_shaping jsonb := COALESCE(create_watch.input_shaping, '{}'::jsonb);
  actual_decision_contract jsonb := COALESCE(create_watch.decision_contract, '{}'::jsonb);
  actual_max_candidate_rows integer := GREATEST(1, LEAST(COALESCE(create_watch.max_candidate_rows, 1000), 100000));
  actual_pair_sources jsonb := COALESCE(create_watch.pair_sources, '[]'::jsonb);
  source_table_name text;
  source_table_regclass regclass;
  pair_source jsonb;
  pair_source_table text;
  pair_source_subject_column text;
  task_name text;
  row_index otlet.semantic_indexes%ROWTYPE;
  join_index otlet.semantic_join_indexes%ROWTYPE;
  saved otlet.watches%ROWTYPE;
  same_identity boolean := false;
  watch_trigger_name text;
  cheap_model_name text;
  strong_model_name text;
BEGIN
  IF create_watch.watch_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet watch name % must be a simple identifier', create_watch.watch_name;
  END IF;
  IF actual_kind NOT IN ('row', 'pair') THEN
    RAISE EXCEPTION 'otlet watch kind % must be row or pair', create_watch.kind;
  END IF;
  IF jsonb_typeof(create_watch.output_schema) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch output_schema must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_runtime_options) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch runtime_options must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_selection_policy) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch selection_policy must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_trigger_policy) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch trigger_policy must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_input_shaping) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch input_shaping must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_decision_contract) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch decision_contract must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_pair_sources) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'otlet watch pair_sources must be a JSON array';
  END IF;
  IF COALESCE(actual_trigger_policy ->> 'on_change', 'mark_stale') NOT IN ('mark_stale', 'mark_stale_and_enqueue') THEN
    RAISE EXCEPTION 'otlet watch trigger_policy.on_change must be mark_stale or mark_stale_and_enqueue';
  END IF;
  IF actual_stale_policy NOT IN ('lookup_only_fail_closed', 'refresh_then_fail_closed') THEN
    RAISE EXCEPTION 'otlet watch stale_policy % is not supported', actual_stale_policy;
  END IF;
  SELECT COALESCE(array_agg(action_type ORDER BY action_type), ARRAY[]::text[])
  INTO actual_action_types
  FROM (
    SELECT DISTINCT action_type
    FROM unnest(actual_action_types) action_type
  ) normalized;
  actual_decision_contract := jsonb_set(
    actual_decision_contract,
    '{action_types}',
    to_jsonb(actual_action_types),
    true
  );

  IF actual_kind = 'row' THEN
    IF create_watch.table_name IS NULL THEN
      RAISE EXCEPTION 'otlet row watch % requires table_name', create_watch.watch_name;
    END IF;
    IF actual_pair_sources <> '[]'::jsonb THEN
      RAISE EXCEPTION 'otlet row watch % cannot declare pair_sources', create_watch.watch_name;
    END IF;

    SELECT format('%I.%I', n.nspname, c.relname)
    INTO source_table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = create_watch.table_name;

    actual_input_shaping := jsonb_set(
      actual_input_shaping,
      '{source_fields}',
      '["_otlet_mvcc","row","table"]'::jsonb,
      true
    );
  ELSE
    actual_pair_sources := '[]'::jsonb;

    FOR pair_source IN
      SELECT value
      FROM jsonb_array_elements(COALESCE(create_watch.pair_sources, '[]'::jsonb)) source(value)
    LOOP
      IF jsonb_typeof(pair_source) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'otlet pair_sources entries must be JSON objects';
      END IF;

      source_table_regclass := to_regclass(COALESCE(pair_source ->> 'table', pair_source ->> 'source_table'));
      pair_source_subject_column := COALESCE(NULLIF(pair_source ->> 'subject_column', ''), 'id');

      IF source_table_regclass IS NULL THEN
        RAISE EXCEPTION 'otlet pair source table % does not exist', COALESCE(pair_source ->> 'table', pair_source ->> 'source_table');
      END IF;
      IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = source_table_regclass
          AND attname = pair_source_subject_column
          AND attnum > 0
          AND NOT attisdropped
      ) THEN
        RAISE EXCEPTION 'otlet pair source subject column % does not exist on %', pair_source_subject_column, source_table_regclass;
      END IF;

      SELECT format('%I.%I', n.nspname, c.relname)
      INTO pair_source_table
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.oid = source_table_regclass;

      actual_pair_sources := actual_pair_sources || jsonb_build_array(
        jsonb_build_object(
          'table', pair_source_table,
          'subject_column', pair_source_subject_column
        )
      );
    END LOOP;
  END IF;

  SELECT *
  INTO existing_watch
  FROM otlet.watches w
  WHERE w.name = create_watch.watch_name;

  IF FOUND THEN
    same_identity := (
      (actual_kind = 'row'
       AND existing_watch.kind = 'row'
       AND existing_watch.source_table = source_table_name
       AND existing_watch.subject_column = create_watch.subject_column
       AND existing_watch.record_type = actual_record_type)
      OR
      (actual_kind = 'pair'
       AND existing_watch.kind = 'pair'
       AND existing_watch.candidate_query = create_watch.candidate_query
       AND existing_watch.record_type = actual_record_type)
    );

    IF NOT same_identity THEN
      PERFORM otlet.drop_watch(create_watch.watch_name);
    END IF;
  END IF;

  IF actual_kind = 'row' THEN
    SELECT *
    INTO row_index
    FROM otlet.create_watch_row_index(
      index_name => create_watch.watch_name,
      table_name => create_watch.table_name,
      subject_column => create_watch.subject_column,
      instruction => create_watch.instruction,
      output_schema => create_watch.output_schema,
      model_name => create_watch.model_name,
      runtime_options => actual_runtime_options,
      record_type => actual_record_type,
      input_shaping => actual_input_shaping,
      decision_contract => actual_decision_contract,
      input_columns => create_watch.input_columns
    );
    task_name := row_index.task_name;
  ELSE
    IF NULLIF(create_watch.candidate_query, '') IS NULL THEN
      RAISE EXCEPTION 'otlet pair watch % requires candidate_query', create_watch.watch_name;
    END IF;

    SELECT *
    INTO join_index
    FROM otlet.create_watch_pair_index(
      index_name => create_watch.watch_name,
      candidate_query => create_watch.candidate_query,
      instruction => create_watch.instruction,
      output_schema => create_watch.output_schema,
      model_name => create_watch.model_name,
      record_type => actual_record_type,
      runtime_options => actual_runtime_options,
      max_candidate_rows => actual_max_candidate_rows,
      input_shaping => actual_input_shaping,
      decision_contract => actual_decision_contract
    );
    task_name := join_index.task_name;
  END IF;

  INSERT INTO otlet.watches (
    name,
    kind,
    task_name,
    semantic_index_name,
    semantic_join_index_name,
    source_table,
    subject_column,
    input_columns,
    pair_sources,
    candidate_query,
    output_schema,
    action_types,
    stale_policy,
    selection_policy,
    trigger_policy,
    input_shaping,
    decision_contract,
    model_name,
    record_type,
    runtime_options,
    max_candidate_rows,
    updated_at
  )
  VALUES (
    create_watch.watch_name,
    actual_kind,
    task_name,
    CASE WHEN actual_kind = 'row' THEN row_index.name END,
    CASE WHEN actual_kind = 'pair' THEN join_index.name END,
    CASE WHEN actual_kind = 'row' THEN source_table_name END,
    CASE WHEN actual_kind = 'row' THEN create_watch.subject_column END,
    CASE WHEN actual_kind = 'row' THEN row_index.input_columns END,
    CASE WHEN actual_kind = 'pair' THEN actual_pair_sources ELSE '[]'::jsonb END,
    CASE WHEN actual_kind = 'pair' THEN create_watch.candidate_query END,
    create_watch.output_schema,
    actual_action_types,
    actual_stale_policy,
    actual_selection_policy,
    actual_trigger_policy,
    actual_input_shaping,
    actual_decision_contract,
    create_watch.model_name,
    actual_record_type,
    actual_runtime_options,
    actual_max_candidate_rows,
    now()
  )
  ON CONFLICT (name) DO UPDATE
    SET task_name = EXCLUDED.task_name,
        semantic_index_name = EXCLUDED.semantic_index_name,
        semantic_join_index_name = EXCLUDED.semantic_join_index_name,
        source_table = EXCLUDED.source_table,
        subject_column = EXCLUDED.subject_column,
        input_columns = EXCLUDED.input_columns,
        pair_sources = EXCLUDED.pair_sources,
        candidate_query = EXCLUDED.candidate_query,
        output_schema = EXCLUDED.output_schema,
        action_types = EXCLUDED.action_types,
        stale_policy = EXCLUDED.stale_policy,
        selection_policy = EXCLUDED.selection_policy,
        trigger_policy = EXCLUDED.trigger_policy,
        input_shaping = EXCLUDED.input_shaping,
        decision_contract = EXCLUDED.decision_contract,
        model_name = EXCLUDED.model_name,
        record_type = EXCLUDED.record_type,
        runtime_options = EXCLUDED.runtime_options,
        max_candidate_rows = EXCLUDED.max_candidate_rows,
        updated_at = now()
  RETURNING * INTO saved;

  cheap_model_name := COALESCE(
    actual_selection_policy ->> 'cheap_model_name',
    actual_selection_policy ->> 'cheap_model'
  );
  strong_model_name := COALESCE(
    actual_selection_policy ->> 'strong_model_name',
    actual_selection_policy ->> 'strong_model'
  );

  IF cheap_model_name IS NOT NULL OR strong_model_name IS NOT NULL THEN
    IF cheap_model_name IS NULL OR strong_model_name IS NULL THEN
      RAISE EXCEPTION 'otlet watch selection_policy requires both cheap_model_name and strong_model_name';
    END IF;

    PERFORM otlet.set_model_selection_policy(
      saved.task_name,
      cheap_model_name,
      strong_model_name,
      actual_selection_policy -> 'accept_field_checks'
    );
  ELSE
    DELETE FROM otlet.model_selection_policies p
    WHERE p.task_name = saved.task_name;
  END IF;

  IF saved.kind = 'row' THEN
    IF COALESCE(saved.trigger_policy ->> 'on_change', 'mark_stale') = 'mark_stale_and_enqueue' THEN
      PERFORM otlet.watch_semantic_change(create_watch.table_name, saved.subject_column, saved.name);
    ELSIF saved.source_table IS NOT NULL AND to_regclass(saved.source_table) IS NOT NULL THEN
      watch_trigger_name := 'otlet_watch_' || substr(md5(to_regclass(saved.source_table)::text || ':' || saved.subject_column || ':' || saved.name), 1, 16);
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', watch_trigger_name, saved.source_table);
    END IF;
  ELSIF saved.kind = 'pair' THEN
    FOR pair_source IN
      SELECT value
      FROM jsonb_array_elements(COALESCE(saved.pair_sources, '[]'::jsonb)) source(value)
    LOOP
      PERFORM otlet.watch_semantic_stale(
        (pair_source ->> 'table')::regclass,
        COALESCE(NULLIF(pair_source ->> 'subject_column', ''), 'id')
      );
    END LOOP;
  END IF;

  RETURN saved;
END;
$$;
