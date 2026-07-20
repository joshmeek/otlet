CREATE FUNCTION otlet.create_watch_row_index(
  index_name text,
  table_name regclass,
  subject_column text,
  instruction text,
  output_schema jsonb,
  model_name text,
  runtime_options jsonb DEFAULT '{}'::jsonb,
  record_type text DEFAULT NULL,
  input_shaping jsonb DEFAULT '{}'::jsonb,
  decision_contract jsonb DEFAULT '{}'::jsonb,
  input_columns text[] DEFAULT NULL
) RETURNS otlet.semantic_indexes
LANGUAGE plpgsql
AS $$
DECLARE
  source_table text;
  saved otlet.semantic_indexes%ROWTYPE;
  semantic_record_type text := COALESCE(record_type, index_name);
  semantic_task_name text := index_name || '_task';
  current_contract_hash text := otlet.task_contract_hash(instruction, output_schema, model_name, runtime_options, input_shaping, decision_contract);
  actual_input_columns text[];
  query text;
BEGIN
  IF semantic_task_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'semantic index name % creates invalid task name %', index_name, semantic_task_name;
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

  SELECT format('%I.%I', n.nspname, c.relname)
  INTO source_table
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.oid = table_name;

  IF input_columns IS NOT NULL THEN
    SELECT array_agg(DISTINCT column_name ORDER BY column_name)
    INTO actual_input_columns
    FROM unnest(input_columns) AS requested(column_name)
    WHERE NULLIF(column_name, '') IS NOT NULL;

    IF actual_input_columns IS NULL THEN
      RAISE EXCEPTION 'otlet input_columns cannot be empty when provided';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM unnest(actual_input_columns) AS requested(column_name)
      WHERE NOT EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = table_name
          AND attname = requested.column_name
          AND attnum > 0
          AND NOT attisdropped
      )
    ) THEN
      RAISE EXCEPTION 'otlet input_columns must all exist on %', table_name;
    END IF;
  END IF;

  query := format(
    $query$
      SELECT subject_id, input
      FROM (
        SELECT
          shaped.subject_id,
          shaped.input,
          otlet.semantic_content_hash(shaped.input, %7$L::jsonb) AS content_hash
        FROM (
          SELECT
            (src.%1$I)::text AS subject_id,
            jsonb_build_object(
              '_otlet_mvcc', jsonb_build_object(
                'table', %2$L,
                'subject_id', (src.%1$I)::text,
                'ctid', src.ctid::text,
                'xmin', src.xmin::text
              ),
              'table', %2$L,
              'row', otlet.semantic_project_row(to_jsonb(src), %5$L::text[])
            ) AS input
          FROM %3$s AS src
        ) shaped
      ) otlet_semantic_input
      WHERE NOT EXISTS (
        SELECT 1
        FROM otlet.semantic_materializations sm
        WHERE sm.task_name = %4$L
          AND sm.source_table = %2$L
          AND sm.subject_id = otlet_semantic_input.subject_id
          AND sm.content_hash = otlet_semantic_input.content_hash
          AND sm.contract_hash = %6$L
      )
    $query$,
    subject_column,
    source_table,
    table_name,
    semantic_task_name,
    actual_input_columns,
    current_contract_hash,
    input_shaping
  );

  PERFORM otlet.create_task(
    semantic_task_name,
    query,
    instruction,
    output_schema,
    model_name,
    runtime_options,
    input_shaping,
    decision_contract
  );

  INSERT INTO otlet.semantic_indexes (
    name,
    task_name,
    source_table,
    subject_column,
    input_columns,
    record_type,
    model_name,
    updated_at
  )
  VALUES (
    index_name,
    semantic_task_name,
    source_table,
    subject_column,
    actual_input_columns,
    semantic_record_type,
    model_name,
    now()
  )
  ON CONFLICT (name) DO UPDATE
    SET task_name = EXCLUDED.task_name,
        source_table = EXCLUDED.source_table,
        subject_column = EXCLUDED.subject_column,
        input_columns = EXCLUDED.input_columns,
        record_type = EXCLUDED.record_type,
        model_name = EXCLUDED.model_name,
        updated_at = now()
  RETURNING * INTO saved;

  PERFORM otlet.watch_semantic_stale(table_name, subject_column);

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.drop_watch_row_index(
  index_name text
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  stale_trigger_name text;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes si
  WHERE si.name = drop_watch_row_index.index_name;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  DELETE FROM otlet.semantic_materializations sm
  WHERE sm.task_name = index_row.task_name
    AND sm.record_type = index_row.record_type;

  DELETE FROM otlet.semantic_indexes si
  WHERE si.name = index_row.name;

  DELETE FROM otlet.tasks t
  WHERE t.name = index_row.task_name
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.jobs j
      WHERE j.task_name = t.name
    );

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.semantic_indexes si
    WHERE si.source_table = index_row.source_table
      AND si.subject_column = index_row.subject_column
  ) THEN
    stale_trigger_name := 'otlet_stale_' || substr(
      md5(index_row.source_table::regclass::text || ':' || index_row.subject_column),
      1,
      16
    );
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', stale_trigger_name, index_row.source_table);
  END IF;

  RETURN true;
END;
$$;

CREATE FUNCTION otlet.refresh_semantic_index(
  index_name text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  queued bigint;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes
  WHERE name = refresh_semantic_index.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', refresh_semantic_index.index_name;
  END IF;

  SELECT otlet.run_task(index_row.task_name) INTO queued;

  UPDATE otlet.semantic_indexes
  SET last_refresh_at = now(),
      updated_at = now()
  WHERE name = index_row.name;

  RETURN queued;
END;
$$;

CREATE FUNCTION otlet.mark_semantic_schema_drift(
  index_name text
) RETURNS bigint
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  updated_count bigint := 0;
BEGIN
  SELECT si.subject_column, si.source_table, si.input_columns, si.task_name, si.record_type
  INTO index_row.subject_column, index_row.source_table, index_row.input_columns, index_row.task_name, index_row.record_type
  FROM otlet.semantic_indexes si
  WHERE si.name = mark_semantic_schema_drift.index_name;

  IF NOT FOUND OR index_row.input_columns IS NULL THEN
    RETURN 0;
  END IF;

  EXECUTE format(
    $sql$
      WITH missing_columns AS (
        SELECT 1
        FROM unnest(%3$L::text[]) AS expected(column_name)
        WHERE NOT EXISTS (
          SELECT 1
          FROM pg_attribute a
          WHERE a.attrelid = %2$L::regclass
            AND a.attname = expected.column_name
            AND a.attnum > 0
            AND NOT a.attisdropped
        )
        LIMIT 1
      ),
      drift_subjects AS (
        SELECT (src.%1$I)::text AS subject_id
        FROM %2$s AS src
        WHERE EXISTS (SELECT 1 FROM missing_columns)
      )
      UPDATE otlet.semantic_materializations sm
      SET stale = true,
          stale_reason = 'schema_drift',
          updated_at = now()
      FROM drift_subjects ds
      WHERE sm.task_name = %4$L
        AND sm.record_type = %5$L
        AND sm.subject_id = ds.subject_id
        AND sm.stale_reason IS DISTINCT FROM 'schema_drift'
    $sql$,
    index_row.subject_column,
    index_row.source_table,
    index_row.input_columns,
    index_row.task_name,
    index_row.record_type
  );

  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count;
END;
$$;

