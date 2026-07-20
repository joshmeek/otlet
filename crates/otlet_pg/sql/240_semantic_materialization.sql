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

