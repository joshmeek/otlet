CREATE FUNCTION otlet.create_semantic_join_index(
  index_name text,
  candidate_query text,
  instruction text,
  output_schema jsonb,
  model_name text,
  record_type text DEFAULT NULL,
  runtime_options jsonb DEFAULT '{}'::jsonb,
  max_candidate_rows integer DEFAULT 1000
) RETURNS otlet.semantic_join_indexes
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.semantic_join_indexes%ROWTYPE;
  semantic_record_type text := COALESCE(record_type, index_name);
  semantic_task_name text := index_name || '_task';
  bounded_rows integer := GREATEST(1, LEAST(COALESCE(max_candidate_rows, 1000), 100000));
  wrapped_query text;
BEGIN
  IF index_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet semantic join index name % must be a simple identifier', index_name;
  END IF;

  IF semantic_task_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet semantic join index name % creates invalid task name %', index_name, semantic_task_name;
  END IF;

  EXECUTE format(
    'SELECT subject_id::text, input::jsonb FROM (%s) otlet_join_candidate LIMIT 0',
    candidate_query
  );

  wrapped_query := format(
    $query$
      SELECT subject_id, input
      FROM (
        SELECT subject_id::text AS subject_id, input::jsonb AS input
        FROM (%1$s) otlet_join_candidate
        ORDER BY subject_id
        LIMIT %2$s
      ) otlet_join_input
      WHERE NOT EXISTS (
        SELECT 1
        FROM otlet.semantic_materializations sm
        WHERE sm.task_name = %3$L
          AND sm.record_type = %4$L
          AND sm.subject_id = otlet_join_input.subject_id
          AND sm.stale = false
          AND sm.source_hash = md5(otlet_join_input.input::text)
      )
    $query$,
    candidate_query,
    bounded_rows,
    semantic_task_name,
    semantic_record_type
  );

  PERFORM otlet.create_task(
    semantic_task_name,
    wrapped_query,
    instruction,
    output_schema,
    model_name,
    runtime_options
  );

  INSERT INTO otlet.semantic_join_indexes (
    name,
    task_name,
    candidate_query,
    record_type,
    model_name,
    max_candidate_rows,
    updated_at
  )
  VALUES (
    index_name,
    semantic_task_name,
    candidate_query,
    semantic_record_type,
    model_name,
    bounded_rows,
    now()
  )
  ON CONFLICT (name) DO UPDATE
    SET task_name = EXCLUDED.task_name,
        candidate_query = EXCLUDED.candidate_query,
        record_type = EXCLUDED.record_type,
        model_name = EXCLUDED.model_name,
        max_candidate_rows = EXCLUDED.max_candidate_rows,
        updated_at = now()
  RETURNING * INTO saved;

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.drop_semantic_join_index(
  index_name text
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = drop_semantic_join_index.index_name;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  DELETE FROM otlet.semantic_materializations sm
  WHERE sm.task_name = index_row.task_name
    AND sm.record_type = index_row.record_type;

  DELETE FROM otlet.semantic_join_indexes sji
  WHERE sji.name = index_row.name;

  DELETE FROM otlet.tasks t
  WHERE t.name = index_row.task_name
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.jobs j
      WHERE j.task_name = t.name
    );

  RETURN true;
END;
$$;

CREATE FUNCTION otlet.refresh_semantic_join_index(
  index_name text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  queued bigint;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = refresh_semantic_join_index.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', refresh_semantic_join_index.index_name;
  END IF;

  SELECT otlet.run_task(index_row.task_name) INTO queued;

  UPDATE otlet.semantic_join_indexes
  SET last_refresh_at = now(),
      updated_at = now()
  WHERE name = index_row.name;

  RETURN queued;
END;
$$;

CREATE FUNCTION otlet.materialize_semantic_join_index(
  index_name text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  refreshed bigint;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = materialize_semantic_join_index.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', materialize_semantic_join_index.index_name;
  END IF;

  EXECUTE format(
    $sql$
      WITH current_inputs AS (
        SELECT subject_id, input
        FROM (
          SELECT subject_id::text AS subject_id, input::jsonb AS input
          FROM (%1$s) otlet_join_candidate
          ORDER BY subject_id
          LIMIT %2$s
        ) otlet_join_input
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
        WHERE j.task_name = %3$L
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
        updated_at
      )
      SELECT
        r.id,
        r.record_type,
        %4$L,
        j.subject_id,
        j.task_name,
        t.model_name,
        r.body,
        false,
        md5(j.input::text),
        now()
      FROM otlet.records r
      JOIN otlet.actions a ON a.id = r.action_id
      JOIN latest_jobs j ON j.id = a.job_id
      JOIN otlet.tasks t ON t.name = j.task_name
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
            updated_at = now()
    $sql$,
    index_row.candidate_query,
    index_row.max_candidate_rows,
    index_row.task_name,
    'otlet.semantic_join:' || index_row.name,
    index_row.record_type
  );

  GET DIAGNOSTICS refreshed = ROW_COUNT;

  UPDATE otlet.semantic_join_indexes
  SET last_materialized_at = now(),
      updated_at = now()
  WHERE name = index_row.name;

  RETURN refreshed;
END;
$$;

CREATE FUNCTION otlet.materialize_semantic_join_index_subject(
  index_name text,
  subject_id text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  refreshed bigint;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = materialize_semantic_join_index_subject.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', materialize_semantic_join_index_subject.index_name;
  END IF;

  EXECUTE format(
    $sql$
      WITH current_inputs AS (
        SELECT subject_id, input
        FROM (
          SELECT subject_id::text AS subject_id, input::jsonb AS input
          FROM (%1$s) otlet_join_candidate
          ORDER BY subject_id
          LIMIT %2$s
        ) otlet_join_input
        WHERE subject_id = %3$L
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
        WHERE j.task_name = %4$L
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
        updated_at
      )
      SELECT
        r.id,
        r.record_type,
        %5$L,
        j.subject_id,
        j.task_name,
        t.model_name,
        r.body,
        false,
        md5(j.input::text),
        now()
      FROM otlet.records r
      JOIN otlet.actions a ON a.id = r.action_id
      JOIN latest_jobs j ON j.id = a.job_id
      JOIN otlet.tasks t ON t.name = j.task_name
      WHERE r.record_type = %6$L
      ON CONFLICT (record_id) DO UPDATE
        SET record_type = EXCLUDED.record_type,
            source_table = EXCLUDED.source_table,
            subject_id = EXCLUDED.subject_id,
            task_name = EXCLUDED.task_name,
            model_name = EXCLUDED.model_name,
            body = EXCLUDED.body,
            stale = false,
            source_hash = EXCLUDED.source_hash,
            updated_at = now()
    $sql$,
    index_row.candidate_query,
    index_row.max_candidate_rows,
    materialize_semantic_join_index_subject.subject_id,
    index_row.task_name,
    'otlet.semantic_join:' || index_row.name,
    index_row.record_type
  );

  GET DIAGNOSTICS refreshed = ROW_COUNT;

  IF refreshed > 0 THEN
    UPDATE otlet.semantic_join_indexes
    SET last_materialized_at = now(),
        updated_at = now()
    WHERE name = index_row.name;
  END IF;

  RETURN refreshed;
END;
$$;

CREATE FUNCTION otlet.semantic_join_index_lookup(
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
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = semantic_join_index_lookup.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', semantic_join_index_lookup.index_name;
  END IF;

  EXECUTE format(
    $sql$
      WITH current_inputs AS (
        SELECT subject_id, input
        FROM (
          SELECT subject_id::text AS subject_id, input::jsonb AS input
          FROM (%1$s) otlet_join_candidate
          ORDER BY subject_id
          LIMIT %2$s
        ) otlet_join_input
      )
      UPDATE otlet.semantic_materializations sm
      SET stale = true,
          updated_at = now()
      FROM current_inputs ci
      WHERE sm.task_name = %3$L
        AND sm.record_type = %4$L
        AND sm.stale = false
        AND ci.subject_id = sm.subject_id
        AND md5(ci.input::text) IS DISTINCT FROM sm.source_hash
    $sql$,
    index_row.candidate_query,
    index_row.max_candidate_rows,
    index_row.task_name,
    index_row.record_type
  );

  UPDATE otlet.semantic_join_indexes
  SET last_lookup_at = now()
  WHERE name = index_row.name;

  RETURN QUERY
  SELECT *
  FROM otlet.semantic_join_index_current_rows(
    semantic_join_index_lookup.index_name,
    semantic_join_index_lookup.fresh_only
  );
END;
$$;
