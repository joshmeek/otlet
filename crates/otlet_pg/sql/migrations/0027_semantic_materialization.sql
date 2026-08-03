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
  revision_definition jsonb;
BEGIN
  IF NULLIF(materialize_semantic_records.current_input_query, '') IS NULL THEN
    RAISE EXCEPTION 'otlet materialize_semantic_records requires current_input_query';
  END IF;

  SELECT
    head.active_workload_revision_hash,
    revision.definition #> '{task,input_shaping}',
    revision.definition
  INTO current_contract_hash, current_input_shaping, revision_definition
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = materialize_semantic_records.task_name
  FOR UPDATE OF head;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', materialize_semantic_records.task_name;
  END IF;
  PERFORM otlet.source_query_contract_guard(
    revision_definition #> '{source,query_contract}',
    true
  );
  EXECUTE format(
    $sql$
      WITH current_inputs AS (
        SELECT subject_id, input
        FROM otlet.validated_task_input_rows(%1$L)
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
          AND j.workload_revision_hash = %7$L
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
    current_contract_hash,
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
  revision_definition jsonb;
BEGIN
  SELECT
    revision.definition #>> '{source,semantic_index_name}',
    revision.definition #>> '{task,name}'
  INTO index_row.name, index_row.task_name
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_index_name}' = materialize_semantic_index.index_name
    AND revision.definition #>> '{source,kind}' = 'row'
  FOR UPDATE OF head;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', materialize_semantic_index.index_name;
  END IF;

  SELECT active.definition
  INTO revision_definition
  FROM otlet.active_workload_revision(index_row.task_name) active;
  input_query := revision_definition #>> '{task,input_query}';

  IF input_query IS NULL THEN
    RAISE EXCEPTION 'otlet semantic index % task % does not exist', materialize_semantic_index.index_name, index_row.task_name;
  END IF;

  RETURN otlet.materialize_semantic_records(
    index_row.task_name,
    revision_definition #>> '{source,record_type}',
    revision_definition #>> '{source,source_table}',
    input_query
  );
END;
$$;

CREATE FUNCTION otlet.materialize_semantic_index_subject(
  index_name text,
  subject_id text,
  expected_workload_revision_hash text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  input_query text;
  revision_definition jsonb;
  active_revision_hash text;
BEGIN
  SELECT
    revision.definition #>> '{source,semantic_index_name}',
    revision.definition #>> '{task,name}',
    head.active_workload_revision_hash
  INTO index_row.name, index_row.task_name, active_revision_hash
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_index_name}' = materialize_semantic_index_subject.index_name
    AND revision.definition #>> '{source,kind}' = 'row'
  FOR UPDATE OF head;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', materialize_semantic_index_subject.index_name;
  END IF;

  IF materialize_semantic_index_subject.expected_workload_revision_hash IS NOT NULL
     AND materialize_semantic_index_subject.expected_workload_revision_hash IS DISTINCT FROM active_revision_hash THEN
    RAISE EXCEPTION 'otlet workload revision changed during semantic materialization for index %', index_row.name;
  END IF;

  SELECT active.definition
  INTO revision_definition
  FROM otlet.active_workload_revision(index_row.task_name) active;

  SELECT format(
    'SELECT subject_id, input FROM (%s) otlet_active_input WHERE subject_id::text = %L',
    revision_definition #>> '{task,input_query}',
    materialize_semantic_index_subject.subject_id
  )
  INTO input_query;

  IF input_query IS NULL THEN
    RAISE EXCEPTION 'otlet semantic index % has no active workload revision', index_row.name;
  END IF;

  RETURN otlet.materialize_semantic_records(
    index_row.task_name,
    revision_definition #>> '{source,record_type}',
    revision_definition #>> '{source,source_table}',
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
  revision_definition jsonb;
  action_authority jsonb;
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

  SELECT revision.definition
  INTO revision_definition
  FROM otlet.workload_revisions revision
  WHERE revision.workload_revision_hash = job_row.workload_revision_hash
    AND revision.task_name = job_row.task_name;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  PERFORM 1
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = job_row.task_name
  FOR UPDATE;

  IF job_row.workload_revision_hash IS DISTINCT FROM (
    SELECT head.active_workload_revision_hash
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = job_row.task_name
  ) THEN
    RETURN 0;
  END IF;

  PERFORM otlet.require_workload_source_contract(
    job_row.task_name,
    job_row.workload_revision_hash
  );

  -- outputs_one_per_job_idx guarantees at most one row per job
  SELECT *
  INTO output_row
  FROM otlet.outputs o
  WHERE o.job_id = job_row.id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  action_authority := revision_definition #> '{action_policies,create_record,authority}';

  FOR index_row IN
    SELECT
      CASE revision_definition #>> '{source,kind}'
        WHEN 'row' THEN 'row'
        WHEN 'pair' THEN 'join'
      END AS index_kind,
      COALESCE(
        revision_definition #>> '{source,semantic_index_name}',
        revision_definition #>> '{source,semantic_join_index_name}'
      ) AS name,
      revision_definition #>> '{source,record_type}' AS record_type,
      revision_definition #>> '{source,source_table}' AS source_table
    WHERE revision_definition #>> '{source,kind}' IN ('row', 'pair')
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
      SELECT
        job_row.id,
        output_row.id,
        output_row.receipt_id,
        'create_record',
        action_authority ->> 'origin',
        action_authority ->> 'mode',
        action_authority ->> 'evaluation_status',
        action_authority ->> 'policy_hash',
        action_authority ->> 'subject_namespace',
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
      WHERE action_authority ->> 'origin' = 'system'
        AND job_row.workload_revision_hash = (
          SELECT head.active_workload_revision_hash
          FROM otlet.workload_revision_heads head
          WHERE head.task_name = job_row.task_name
        )
      RETURNING id INTO saved_action_id;

      IF NOT FOUND THEN
        RETURN 0;
      END IF;
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
