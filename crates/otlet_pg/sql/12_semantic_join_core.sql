CREATE FUNCTION otlet.create_watch_pair_index(
  index_name text,
  candidate_query text,
  instruction text,
  output_schema jsonb,
  model_name text,
  record_type text DEFAULT NULL,
  runtime_options jsonb DEFAULT '{}'::jsonb,
  max_candidate_rows integer DEFAULT 1000,
  input_shaping jsonb DEFAULT '{}'::jsonb,
  decision_contract jsonb DEFAULT '{}'::jsonb
) RETURNS otlet.semantic_join_indexes
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.semantic_join_indexes%ROWTYPE;
  semantic_record_type text := COALESCE(record_type, index_name);
  semantic_task_name text := index_name || '_task';
  bounded_rows integer := GREATEST(1, LEAST(COALESCE(max_candidate_rows, 1000), 100000));
  current_contract_hash text := otlet.task_contract_hash(instruction, output_schema, model_name, runtime_options, input_shaping, decision_contract);
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
        SELECT
          shaped.subject_id,
          shaped.input,
          otlet.semantic_content_hash(shaped.input, %6$L::jsonb) AS content_hash
        FROM (
          SELECT subject_id::text AS subject_id, input::jsonb AS input
          FROM (%1$s) otlet_join_candidate
          ORDER BY subject_id
          LIMIT %2$s
        ) shaped
      ) otlet_join_input
      WHERE NOT EXISTS (
        SELECT 1
        FROM otlet.semantic_materializations sm
        WHERE sm.task_name = %3$L
          AND sm.record_type = %4$L
          AND sm.subject_id = otlet_join_input.subject_id
          AND sm.content_hash = otlet_join_input.content_hash
          AND sm.contract_hash = %5$L
      )
    $query$,
    candidate_query,
    bounded_rows,
    semantic_task_name,
    semantic_record_type,
    current_contract_hash,
    input_shaping
  );

  PERFORM otlet.create_task(
    semantic_task_name,
    wrapped_query,
    instruction,
    output_schema,
    model_name,
    runtime_options,
    input_shaping,
    decision_contract
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

CREATE FUNCTION otlet.drop_watch_pair_index(
  index_name text
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
BEGIN
  SELECT sji.name, sji.task_name, sji.record_type
  INTO index_row.name, index_row.task_name, index_row.record_type
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = drop_watch_pair_index.index_name;

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
  SELECT sji.name, sji.task_name
  INTO index_row.name, index_row.task_name
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
  input_query text;
  refreshed bigint;
BEGIN
  SELECT sji.name, sji.task_name, sji.record_type, sji.candidate_query, sji.max_candidate_rows
  INTO index_row.name, index_row.task_name, index_row.record_type, index_row.candidate_query, index_row.max_candidate_rows
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = materialize_semantic_join_index.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', materialize_semantic_join_index.index_name;
  END IF;

  input_query := format(
    $sql$
        SELECT subject_id, input
        FROM (
          SELECT subject_id::text AS subject_id, input::jsonb AS input
          FROM (%1$s) otlet_join_candidate
          ORDER BY subject_id
          LIMIT %2$s
        ) otlet_join_input
    $sql$,
    index_row.candidate_query,
    index_row.max_candidate_rows
  );

  refreshed := otlet.materialize_semantic_records(
    index_row.task_name,
    index_row.record_type,
    'otlet.semantic_join:' || index_row.name,
    input_query
  );

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
  input_query text;
  refreshed bigint;
BEGIN
  SELECT sji.name, sji.task_name, sji.record_type, sji.candidate_query, sji.max_candidate_rows
  INTO index_row.name, index_row.task_name, index_row.record_type, index_row.candidate_query, index_row.max_candidate_rows
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = materialize_semantic_join_index_subject.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', materialize_semantic_join_index_subject.index_name;
  END IF;

  input_query := format(
    $sql$
        SELECT subject_id, input
        FROM (
          SELECT subject_id::text AS subject_id, input::jsonb AS input
          FROM (%1$s) otlet_join_candidate
          ORDER BY subject_id
          LIMIT %2$s
        ) otlet_join_input
        WHERE subject_id = %3$L
    $sql$,
    index_row.candidate_query,
    index_row.max_candidate_rows,
    materialize_semantic_join_index_subject.subject_id
  );

  refreshed := otlet.materialize_semantic_records(
    index_row.task_name,
    index_row.record_type,
    'otlet.semantic_join:' || index_row.name,
    input_query
  );

  IF refreshed > 0 THEN
    UPDATE otlet.semantic_join_indexes
    SET last_materialized_at = now(),
        updated_at = now()
    WHERE name = index_row.name;
  END IF;

  RETURN refreshed;
END;
$$;

CREATE FUNCTION otlet.materialize_completed_semantic_job(
  job_id bigint
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  output_row otlet.outputs%ROWTYPE;
  index_row record;
  saved_action_id bigint;
  refreshed bigint := 0;
  total_refreshed bigint := 0;
  materialize_started timestamptz := clock_timestamp();
BEGIN
  SELECT *
  INTO job_row
  FROM otlet.jobs j
  WHERE j.id = materialize_completed_semantic_job.job_id
    AND j.status = 'complete';

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  -- outputs_one_per_job_idx guarantees at most one row per job.
  SELECT *
  INTO output_row
  FROM otlet.outputs o
  WHERE o.job_id = job_row.id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  IF jsonb_typeof(output_row.output) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet semantic job % output must be a JSON object to materialize', job_row.id;
  END IF;

  FOR index_row IN
    SELECT 'row'::text AS index_kind, si.name, si.record_type, si.source_table
    FROM otlet.semantic_indexes si
    WHERE si.task_name = job_row.task_name
    UNION ALL
    SELECT 'join'::text AS index_kind, sji.name, sji.record_type, NULL::text AS source_table
    FROM otlet.semantic_join_indexes sji
    WHERE sji.task_name = job_row.task_name
  LOOP
    SELECT a.id
    INTO saved_action_id
    FROM otlet.actions a
    WHERE a.job_id = job_row.id
      AND a.output_id = output_row.id
      AND a.action_type = 'create_record'
      AND a.payload ->> 'record_type' = index_row.record_type
    ORDER BY a.id
    LIMIT 1;

    IF NOT FOUND THEN
      INSERT INTO otlet.actions (
        job_id,
        output_id,
        receipt_id,
        action_type,
        payload,
        status,
        subject_id,
        source_table,
        source_hash
      )
      VALUES (
        job_row.id,
        output_row.id,
        output_row.receipt_id,
        'create_record',
        jsonb_build_object(
          'type', 'create_record',
          'record_type', index_row.record_type,
          'subject_id', job_row.subject_id,
          'body', output_row.output
        ),
        'complete',
        job_row.subject_id,
        index_row.source_table,
        md5(job_row.input::text)
      )
      RETURNING id INTO saved_action_id;
    END IF;

    INSERT INTO otlet.records (action_id, record_type, subject_id, body)
    SELECT saved_action_id, index_row.record_type, job_row.subject_id, output_row.output
    WHERE NOT EXISTS (
      SELECT 1
      FROM otlet.records r
      WHERE r.action_id = saved_action_id
    );

    IF index_row.index_kind = 'row' THEN
      SELECT otlet.materialize_semantic_index_subject(index_row.name, job_row.subject_id)
      INTO refreshed;
    ELSE
      SELECT otlet.materialize_semantic_join_index_subject(index_row.name, job_row.subject_id)
      INTO refreshed;
    END IF;

    total_refreshed := total_refreshed + COALESCE(refreshed, 0);
  END LOOP;

  IF output_row.receipt_id IS NOT NULL THEN
    UPDATE otlet.inference_receipts r
    SET trace_summary = r.trace_summary || jsonb_build_object(
      'materialize_ms',
      GREATEST(
        0,
        CEIL(EXTRACT(epoch FROM (clock_timestamp() - materialize_started)) * 1000)
      )::bigint
    )
    WHERE r.id = output_row.receipt_id;
  END IF;

  RETURN total_refreshed;
END;
$$;
