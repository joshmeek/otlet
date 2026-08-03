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
        otlet.semantic_source_hash(j.input),
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

  -- outputs_one_per_job_idx guarantees at most one row per job
  SELECT *
  INTO output_row
  FROM otlet.outputs o
  WHERE o.job_id = job_row.id;

  IF NOT FOUND THEN
    RETURN 0;
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
    IF jsonb_typeof(output_row.output) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'otlet semantic job % output must be a JSON object to materialize', job_row.id;
    END IF;

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
        authority_origin,
        authority_mode,
        evaluation_status,
        authority_policy_hash,
        subject_namespace,
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
        'system',
        'recommendation_only',
        'unevaluated',
        otlet.default_action_authority_hash(job_row.task_name, 'create_record'),
        COALESCE(index_row.source_table, 'task:' || job_row.task_name),
        jsonb_build_object(
          'type', 'create_record',
          'record_type', index_row.record_type,
          'subject_id', job_row.subject_id,
          'body', output_row.output
        ),
        'complete',
        job_row.subject_id,
        index_row.source_table,
        otlet.semantic_source_hash(job_row.input)
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
