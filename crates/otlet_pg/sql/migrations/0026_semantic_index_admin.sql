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
  actual_input_shaping jsonb := COALESCE(input_shaping, '{}'::jsonb);
  actual_input_columns text[];
  subject_attnum smallint;
  subject_not_null boolean;
  query text;
BEGIN
  IF semantic_task_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'semantic index name % creates invalid task name %', index_name, semantic_task_name;
  END IF;

  SELECT attribute.attnum, attribute.attnotnull
  INTO subject_attnum, subject_not_null
  FROM pg_attribute attribute
  WHERE attribute.attrelid = table_name
    AND attribute.attname = subject_column
    AND attribute.attnum > 0
    AND NOT attribute.attisdropped;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet subject column % does not exist on %', subject_column, table_name;
  END IF;
  IF NOT subject_not_null OR NOT EXISTS (
    SELECT 1
    FROM pg_index key_index
    WHERE key_index.indrelid = table_name
      AND key_index.indisunique
      AND key_index.indisvalid
      AND key_index.indisready
      AND key_index.indimmediate
      AND key_index.indnkeyatts = 1
      AND key_index.indkey[0] = subject_attnum
      AND key_index.indexprs IS NULL
      AND key_index.indpred IS NULL
  ) THEN
    RAISE EXCEPTION 'otlet subject column % must be NOT NULL with an immediate unique key',
      subject_column;
  END IF;

  SELECT format('%I.%I', n.nspname, c.relname)
  INTO source_table
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.oid = table_name;

  IF input_columns IS NULL THEN
    SELECT array_agg(a.attname::text ORDER BY a.attname)
    INTO actual_input_columns
    FROM pg_attribute a
    WHERE a.attrelid = table_name
      AND a.attnum > 0
      AND NOT a.attisdropped;
  ELSE
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

  actual_input_shaping := jsonb_set(
    actual_input_shaping,
    '{source_fields}',
    '["_otlet_mvcc","row","table"]'::jsonb,
    true
  );
  query := format(
    $query$
      SELECT subject_id, input
      FROM (
        SELECT
          shaped.subject_id,
          shaped.input,
          otlet.semantic_content_hash(shaped.input, %6$L::jsonb) AS content_hash
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
          AND sm.contract_hash = (
            SELECT head.active_workload_revision_hash
            FROM otlet.workload_revision_heads head
            WHERE head.task_name = %4$L
          )
          AND NOT sm.stale
      )
    $query$,
    subject_column,
    source_table,
    table_name,
    semantic_task_name,
    actual_input_columns,
    actual_input_shaping
  );

  PERFORM otlet.create_task(
    semantic_task_name,
    query,
    instruction,
    output_schema,
    model_name,
    runtime_options,
    actual_input_shaping,
    decision_contract,
    jsonb_build_array(jsonb_build_object('table', source_table))
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

  UPDATE otlet.semantic_materializations sm
  SET stale = true,
      stale_reason = 'contract_changed',
      updated_at = now()
  WHERE sm.task_name = index_row.task_name
    AND sm.record_type = index_row.record_type;

  DELETE FROM otlet.semantic_indexes si
  WHERE si.name = index_row.name;

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.semantic_indexes si
    WHERE si.source_table = index_row.source_table
      AND si.subject_column = index_row.subject_column
  ) THEN
    stale_trigger_name := 'otlet_stale_v1_' || substr(right(otlet.identity_text_hash(
      'semantic_stale_trigger',
      index_row.source_table::regclass::text || ':' || index_row.subject_column
    ), 64), 1, 16);
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
  task_name text;
  queued bigint;
BEGIN
  SELECT revision.definition #>> '{task,name}'
  INTO task_name
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_index_name}' = refresh_semantic_index.index_name
    AND revision.definition #>> '{source,kind}' = 'row';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', refresh_semantic_index.index_name;
  END IF;

  SELECT otlet.run_task(task_name) INTO queued;

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
  revision_definition jsonb;
  current_task_name text;
  current_record_type text;
  current_contract_hash text;
  drift_error text;
  updated_count bigint := 0;
BEGIN
  SELECT
    revision.definition,
    revision.definition #>> '{task,name}',
    revision.definition #>> '{source,record_type}',
    revision.workload_revision_hash
  INTO revision_definition, current_task_name, current_record_type, current_contract_hash
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_index_name}' = mark_semantic_schema_drift.index_name
    AND revision.definition #>> '{source,kind}' = 'row';

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  drift_error := COALESCE(
    otlet.source_query_contract_error(revision_definition #> '{source,query_contract}'),
    otlet.semantic_schema_drift_error(revision_definition)
  );
  IF drift_error IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE otlet.semantic_materializations materialization
  SET stale = true,
      stale_reason = 'schema_drift',
      updated_at = now()
  WHERE materialization.task_name = current_task_name
    AND materialization.record_type = current_record_type
    AND materialization.contract_hash = current_contract_hash
    AND materialization.stale_reason IS DISTINCT FROM 'contract_changed'
    AND materialization.stale_reason IS DISTINCT FROM 'schema_drift';

  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count;
END;
$$;
