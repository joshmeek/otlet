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

CREATE FUNCTION otlet.materialize_semantic_records(
  task_name text,
  record_type text,
  source_table text,
  current_input_query text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  refreshed bigint;
  current_contract_hash text;
  current_input_shaping jsonb;
BEGIN
  IF NULLIF(materialize_semantic_records.current_input_query, '') IS NULL THEN
    RAISE EXCEPTION 'otlet materialize_semantic_records requires current_input_query';
  END IF;

  SELECT
    otlet.task_contract_hash(
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    ),
    t.input_shaping
  INTO current_contract_hash, current_input_shaping
  FROM otlet.tasks t
  WHERE t.name = materialize_semantic_records.task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', materialize_semantic_records.task_name;
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
         AND ci.input IS NOT DISTINCT FROM j.input
        WHERE j.task_name = %2$L
          AND j.status = 'complete'
        ORDER BY j.subject_id, j.finished_at DESC NULLS LAST, j.id DESC
      )
      INSERT INTO otlet.semantic_materializations (
        record_id,
        record_type,
        source_table,
        subject_id,
        source_dependencies,
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
        otlet.semantic_input_dependencies(j.input),
        j.task_name,
        ar.model_name,
        r.body,
        false,
        md5(j.input::text),
        otlet.semantic_content_hash(j.input, %5$L::jsonb),
        %6$L,
        NULL,
        'content_hash_match',
        now()
      FROM otlet.records r
      JOIN otlet.actions a ON a.id = r.action_id
      JOIN latest_jobs j ON j.id = a.job_id
      JOIN otlet.outputs o ON o.id = a.output_id
      JOIN otlet.inference_receipts ar ON ar.id = o.receipt_id
      WHERE r.record_type = %4$L
      ON CONFLICT (record_id) DO UPDATE
        SET record_type = EXCLUDED.record_type,
            source_table = EXCLUDED.source_table,
            subject_id = EXCLUDED.subject_id,
            source_dependencies = EXCLUDED.source_dependencies,
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
    materialize_semantic_records.current_input_query,
    materialize_semantic_records.task_name,
    materialize_semantic_records.source_table,
    materialize_semantic_records.record_type,
    current_input_shaping,
    current_contract_hash
  );

  GET DIAGNOSTICS refreshed = ROW_COUNT;
  RETURN refreshed;
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

  RETURN otlet.materialize_semantic_records(
    index_row.task_name,
    index_row.record_type,
    index_row.source_table,
    input_query
  );
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
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes
  WHERE name = materialize_semantic_index_subject.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', materialize_semantic_index_subject.index_name;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.tasks t
    WHERE t.name = index_row.task_name
  ) THEN
    RAISE EXCEPTION 'otlet semantic index % task % does not exist', materialize_semantic_index_subject.index_name, index_row.task_name;
  END IF;

  input_query := format(
    $sql$
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
        WHERE (src.%1$I)::text = %4$L
    $sql$,
    index_row.subject_column,
    index_row.source_table,
    index_row.source_table,
    materialize_semantic_index_subject.subject_id,
    index_row.input_columns
  );

  RETURN otlet.materialize_semantic_records(
    index_row.task_name,
    index_row.record_type,
    index_row.source_table,
    input_query
  );
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
  freshness_basis text,
  updated_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes
  WHERE name = semantic_index_current_rows.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', semantic_index_current_rows.index_name;
  END IF;

  PERFORM otlet.mark_semantic_schema_drift(index_row.name);

  SELECT
    otlet.task_contract_hash(
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    ),
    t.input_shaping
  INTO current_contract_hash, current_input_shaping
  FROM otlet.tasks t
  WHERE t.name = index_row.task_name;

  RETURN QUERY EXECUTE format(
    $sql$
      WITH raw_inputs AS (
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
      current_inputs AS (
        SELECT
          subject_id,
          input,
          md5(input::text) AS source_hash,
          otlet.semantic_content_hash(input, %9$L::jsonb) AS content_hash
        FROM raw_inputs
      ),
      latest AS (
        SELECT DISTINCT ON (sm.subject_id)
          sm.subject_id,
          sm.body,
          sm.stale,
          sm.source_hash,
          sm.content_hash,
          sm.contract_hash,
          sm.stale_reason,
          sm.freshness_basis,
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
            sm.content_hash IS NOT DISTINCT FROM ci.content_hash
            AND sm.contract_hash IS NOT DISTINCT FROM %7$L
          ) DESC,
          sm.updated_at DESC,
          sm.id DESC
      )
      SELECT
        latest.subject_id,
        latest.body,
        status.is_stale AS stale,
        latest.source_hash,
        CASE
          WHEN status.freshness_basis = 'content_hash_match' THEN COALESCE(latest.freshness_basis, status.freshness_basis)
          ELSE status.freshness_basis
        END AS freshness_basis,
        latest.updated_at
      FROM current_inputs ci
      JOIN latest ON latest.subject_id = ci.subject_id
      CROSS JOIN LATERAL otlet.semantic_freshness_status(
        latest.content_hash,
        latest.contract_hash,
        latest.stale,
        latest.stale_reason,
        latest.source_hash,
        ci.content_hash,
        %7$L,
        ci.source_hash
      ) status
      WHERE (
        NOT %8$s
        OR status.is_fresh
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
    CASE WHEN COALESCE(semantic_index_current_rows.fresh_only, true) THEN 'true' ELSE 'false' END,
    current_input_shaping
  );
END;
$$;

CREATE FUNCTION otlet.revalidate_semantic_subjects(
  index_name text,
  subject_ids text[] DEFAULT NULL
) RETURNS TABLE (
  subject_id text,
  revalidated boolean,
  stale_reason text,
  freshness_basis text
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes
  WHERE name = revalidate_semantic_subjects.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', revalidate_semantic_subjects.index_name;
  END IF;

  SELECT
    otlet.task_contract_hash(
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    ),
    t.input_shaping
  INTO current_contract_hash, current_input_shaping
  FROM otlet.tasks t
  WHERE t.name = index_row.task_name;

  RETURN QUERY EXECUTE format(
    $sql$
      WITH raw_inputs AS (
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
            'row', otlet.semantic_project_row(to_jsonb(src), %7$L::text[])
          ) AS input
        FROM %3$s AS src
        WHERE (%8$L::text[] IS NULL OR (src.%1$I)::text = ANY(%8$L::text[]))
      ),
      current_inputs AS (
        SELECT
          subject_id,
          input,
          md5(input::text) AS source_hash,
          otlet.semantic_content_hash(input, %6$L::jsonb) AS content_hash
        FROM raw_inputs
      ),
      latest AS (
        SELECT DISTINCT ON (sm.subject_id)
          sm.id,
          sm.subject_id,
          sm.stale,
          sm.source_hash,
          sm.content_hash,
          sm.contract_hash,
          sm.stale_reason,
          sm.freshness_basis,
          sm.updated_at
        FROM current_inputs ci
        JOIN otlet.semantic_materializations sm
          ON sm.subject_id = ci.subject_id
        WHERE sm.task_name = %4$L
          AND sm.record_type = %5$L
        ORDER BY
          sm.subject_id,
          (
            sm.content_hash IS NOT DISTINCT FROM ci.content_hash
            AND sm.contract_hash IS NOT DISTINCT FROM %9$L
          ) DESC,
          sm.updated_at DESC,
          sm.id DESC
      ),
      classified AS (
        SELECT
          ci.subject_id,
          l.id,
          l.stale,
          status.is_fresh,
          status.stale_reason,
          status.freshness_basis
        FROM current_inputs ci
        JOIN latest l USING (subject_id)
        CROSS JOIN LATERAL otlet.semantic_freshness_status(
          l.content_hash,
          l.contract_hash,
          l.stale,
          l.stale_reason,
          l.source_hash,
          ci.content_hash,
          %9$L,
          ci.source_hash
        ) status
      ),
      updated AS (
        UPDATE otlet.semantic_materializations sm
        SET stale = false,
            stale_reason = NULL,
            freshness_basis = 'revalidated_after_benign_update',
            updated_at = now()
        FROM classified c
        WHERE sm.id = c.id
          AND c.stale
          AND c.is_fresh
        RETURNING sm.id, sm.subject_id
      )
      SELECT
        c.subject_id,
        (u.id IS NOT NULL) AS revalidated,
        CASE
          WHEN u.id IS NOT NULL THEN NULL::text
          ELSE c.stale_reason
        END AS stale_reason,
        CASE
          WHEN u.id IS NOT NULL THEN 'revalidated_after_benign_update'
          ELSE c.freshness_basis
        END AS freshness_basis
      FROM classified c
      LEFT JOIN updated u ON u.id = c.id
      ORDER BY c.subject_id
    $sql$,
    index_row.subject_column,
    index_row.source_table,
    index_row.source_table,
    index_row.task_name,
    index_row.record_type,
    current_input_shaping,
    index_row.input_columns,
    revalidate_semantic_subjects.subject_ids,
    current_contract_hash
  );
END;
$$;
