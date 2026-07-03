CREATE FUNCTION otlet.semantic_native_table_name(
  index_name text
) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT CASE
    WHEN ($1 || '_native') ~ '^[a-z][a-z0-9_]*$' AND length($1 || '_native') <= 63 THEN $1 || '_native'
    ELSE 'semantic_' || substr(regexp_replace($1, '[^a-z0-9_]', '_', 'g'), 1, 44) || '_' || substr(md5($1), 1, 8)
  END;
$$;

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
      ) otlet_semantic_input
      WHERE NOT EXISTS (
        SELECT 1
        FROM otlet.semantic_materializations sm
        WHERE sm.task_name = %4$L
          AND sm.source_table = %2$L
          AND sm.subject_id = otlet_semantic_input.subject_id
          AND sm.content_hash = otlet.semantic_content_hash(otlet_semantic_input.input)
          AND sm.contract_hash = %6$L
      )
    $query$,
    subject_column,
    source_table,
    table_name,
    semantic_task_name,
    actual_input_columns,
    current_contract_hash
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
  PERFORM otlet.create_semantic_foreign_table(
    otlet.semantic_native_table_name(index_name),
    index_name
  );

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
  native_table text;
  stale_trigger_name text;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes si
  WHERE si.name = drop_watch_row_index.index_name;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  FOR native_table IN
    SELECT format('%I.%I', ns.nspname, c.relname)
    FROM pg_foreign_table ft
    JOIN pg_class c ON c.oid = ft.ftrelid
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
    WHERE ft.ftoptions @> ARRAY['index_name=' || index_row.name]
  LOOP
    EXECUTE format('DROP FOREIGN TABLE IF EXISTS %s', native_table);
  END LOOP;

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

CREATE FUNCTION otlet.materialize_semantic_index(
  index_name text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  input_query text;
  refreshed bigint;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes
  WHERE name = materialize_semantic_index.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', materialize_semantic_index.index_name;
  END IF;

  SELECT t.input_query
  INTO input_query
  FROM otlet.tasks t
  WHERE t.name = index_row.task_name;

  IF input_query IS NULL THEN
    RAISE EXCEPTION 'otlet semantic index % task % does not exist', materialize_semantic_index.index_name, index_row.task_name;
  END IF;

  EXECUTE format(
    $sql$
      WITH current_inputs AS (
        SELECT subject_id::text AS subject_id, input::jsonb AS input
        FROM (%1$s) otlet_current_input
      ),
      latest_jobs AS (
        SELECT DISTINCT ON (j.subject_id)
          j.id,
          j.subject_id,
          j.task_name,
          j.input
        FROM otlet.jobs j
        JOIN current_inputs ci
          ON ci.subject_id = j.subject_id
         AND md5(ci.input::text) = md5(j.input::text)
        WHERE j.task_name = %2$L
          AND j.status = 'complete'
        ORDER BY j.subject_id, j.finished_at DESC NULLS LAST, j.id DESC
      )
      INSERT INTO otlet.semantic_materializations (
        record_id,
        record_type,
        source_table,
        subject_id,
        task_name,
        model_name,
        body,
        stale,
        source_hash,
        content_hash,
        contract_hash,
        stale_reason,
        freshness_basis,
        updated_at
      )
      SELECT
        r.id,
        r.record_type,
        %3$L,
        j.subject_id,
        j.task_name,
        ar.model_name,
        r.body,
        false,
        md5(j.input::text),
        otlet.semantic_content_hash(j.input),
        otlet.task_contract_hash(t.instruction, t.output_schema, t.model_name, t.runtime_options, t.input_shaping, t.decision_contract),
        NULL,
        'content_hash_match',
        now()
      FROM otlet.records r
      JOIN otlet.actions a ON a.id = r.action_id
      JOIN latest_jobs j ON j.id = a.job_id
      JOIN otlet.tasks t ON t.name = j.task_name
      JOIN otlet.outputs o ON o.id = a.output_id
      JOIN otlet.inference_receipts ar ON ar.id = o.receipt_id
      WHERE r.record_type = %4$L
      ON CONFLICT (record_id) DO UPDATE
        SET record_type = EXCLUDED.record_type,
            source_table = EXCLUDED.source_table,
            subject_id = EXCLUDED.subject_id,
            task_name = EXCLUDED.task_name,
            model_name = EXCLUDED.model_name,
            body = EXCLUDED.body,
            stale = false,
            source_hash = EXCLUDED.source_hash,
            content_hash = EXCLUDED.content_hash,
            contract_hash = EXCLUDED.contract_hash,
            stale_reason = NULL,
            freshness_basis = EXCLUDED.freshness_basis,
            updated_at = now()
    $sql$,
    input_query,
    index_row.task_name,
    index_row.source_table,
    index_row.record_type
  );

  GET DIAGNOSTICS refreshed = ROW_COUNT;
  RETURN refreshed;
END;
$$;

CREATE FUNCTION otlet.materialize_semantic_index_subject(
  index_name text,
  subject_id text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  input_query text;
  refreshed bigint;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes
  WHERE name = materialize_semantic_index_subject.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', materialize_semantic_index_subject.index_name;
  END IF;

  SELECT t.input_query
  INTO input_query
  FROM otlet.tasks t
  WHERE t.name = index_row.task_name;

  IF input_query IS NULL THEN
    RAISE EXCEPTION 'otlet semantic index % task % does not exist', materialize_semantic_index_subject.index_name, index_row.task_name;
  END IF;

  EXECUTE format(
    $sql$
      WITH current_inputs AS (
        SELECT subject_id::text AS subject_id, input::jsonb AS input
        FROM (%1$s) otlet_current_input
        WHERE subject_id::text = %3$L
      ),
      latest_jobs AS (
        SELECT DISTINCT ON (j.subject_id)
          j.id,
          j.subject_id,
          j.task_name,
          j.input
        FROM otlet.jobs j
        JOIN current_inputs ci
          ON ci.subject_id = j.subject_id
         AND md5(ci.input::text) = md5(j.input::text)
        WHERE j.task_name = %2$L
          AND j.subject_id = %3$L
          AND j.status = 'complete'
        ORDER BY j.subject_id, j.finished_at DESC NULLS LAST, j.id DESC
      )
      INSERT INTO otlet.semantic_materializations (
        record_id,
        record_type,
        source_table,
        subject_id,
        task_name,
        model_name,
        body,
        stale,
        source_hash,
        content_hash,
        contract_hash,
        stale_reason,
        freshness_basis,
        updated_at
      )
      SELECT
        r.id,
        r.record_type,
        %4$L,
        j.subject_id,
        j.task_name,
        ar.model_name,
        r.body,
        false,
        md5(j.input::text),
        otlet.semantic_content_hash(j.input),
        otlet.task_contract_hash(t.instruction, t.output_schema, t.model_name, t.runtime_options, t.input_shaping, t.decision_contract),
        NULL,
        'content_hash_match',
        now()
      FROM otlet.records r
      JOIN otlet.actions a ON a.id = r.action_id
      JOIN latest_jobs j ON j.id = a.job_id
      JOIN otlet.tasks t ON t.name = j.task_name
      JOIN otlet.outputs o ON o.id = a.output_id
      JOIN otlet.inference_receipts ar ON ar.id = o.receipt_id
      WHERE r.record_type = %5$L
      ON CONFLICT (record_id) DO UPDATE
        SET record_type = EXCLUDED.record_type,
            source_table = EXCLUDED.source_table,
            subject_id = EXCLUDED.subject_id,
            task_name = EXCLUDED.task_name,
            model_name = EXCLUDED.model_name,
            body = EXCLUDED.body,
            stale = false,
            source_hash = EXCLUDED.source_hash,
            content_hash = EXCLUDED.content_hash,
            contract_hash = EXCLUDED.contract_hash,
            stale_reason = NULL,
            freshness_basis = EXCLUDED.freshness_basis,
            updated_at = now()
    $sql$,
    input_query,
    index_row.task_name,
    materialize_semantic_index_subject.subject_id,
    index_row.source_table,
    index_row.record_type
  );

  GET DIAGNOSTICS refreshed = ROW_COUNT;
  RETURN refreshed;
END;
$$;

CREATE FUNCTION otlet.semantic_index_current_rows(
  index_name text,
  fresh_only boolean DEFAULT true
) RETURNS TABLE (
  subject_id text,
  body jsonb,
  stale boolean,
  source_hash text,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  current_contract_hash text;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes
  WHERE name = semantic_index_current_rows.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', semantic_index_current_rows.index_name;
  END IF;

  SELECT otlet.task_contract_hash(
    t.instruction,
    t.output_schema,
    t.model_name,
    t.runtime_options,
    t.input_shaping,
    t.decision_contract
  )
  INTO current_contract_hash
  FROM otlet.tasks t
  WHERE t.name = index_row.task_name;

  RETURN QUERY EXECUTE format(
    $sql$
      WITH current_inputs AS (
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
            'row', otlet.semantic_project_row(to_jsonb(src), %6$L::text[])
          ) AS input
        FROM %3$s AS src
      ),
      latest AS (
        SELECT DISTINCT ON (sm.subject_id)
          sm.subject_id,
          sm.body,
          sm.stale,
          sm.source_hash,
          sm.content_hash,
          sm.contract_hash,
          sm.updated_at,
          sm.id
        FROM current_inputs ci
        JOIN otlet.semantic_materializations sm
          ON sm.subject_id = ci.subject_id
        WHERE sm.task_name = %4$L
          AND sm.record_type = %5$L
        ORDER BY
          sm.subject_id,
          (
            sm.content_hash IS NOT DISTINCT FROM otlet.semantic_content_hash(ci.input)
            AND sm.contract_hash IS NOT DISTINCT FROM %7$L
          ) DESC,
          sm.updated_at DESC,
          sm.id DESC
      )
      SELECT
        latest.subject_id,
        latest.body,
        latest.content_hash IS DISTINCT FROM otlet.semantic_content_hash(ci.input)
          OR latest.contract_hash IS DISTINCT FROM %7$L AS stale,
        latest.source_hash,
        latest.updated_at
      FROM current_inputs ci
      JOIN latest ON latest.subject_id = ci.subject_id
      WHERE (
        NOT %8$s
        OR (
          latest.content_hash IS NOT DISTINCT FROM otlet.semantic_content_hash(ci.input)
          AND latest.contract_hash IS NOT DISTINCT FROM %7$L
        )
      )
      ORDER BY latest.subject_id, latest.updated_at DESC
    $sql$,
    index_row.subject_column,
    index_row.source_table,
    index_row.source_table,
    index_row.task_name,
    index_row.record_type,
    index_row.input_columns,
    current_contract_hash,
    CASE WHEN COALESCE(semantic_index_current_rows.fresh_only, true) THEN 'true' ELSE 'false' END
  );
END;
$$;
