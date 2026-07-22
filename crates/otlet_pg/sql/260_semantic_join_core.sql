CREATE FUNCTION otlet.semantic_join_refresh_inputs(
  index_name text
) RETURNS TABLE (
  subject_id text,
  input jsonb
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = semantic_join_refresh_inputs.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', semantic_join_refresh_inputs.index_name;
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
      WITH current_inputs AS MATERIALIZED (
        SELECT
          candidate.subject_id,
          candidate.input,
          otlet.semantic_content_hash(candidate.input, %6$L::jsonb) AS content_hash
        FROM (
          SELECT subject_id::text AS subject_id, input::jsonb AS input
          FROM (%1$s) otlet_join_candidate
          ORDER BY subject_id
          LIMIT %2$s
        ) candidate
      ),
      candidate_materializations AS (
        SELECT
          sm.id,
          sm.content_hash AS material_content_hash,
          sm.contract_hash AS material_contract_hash,
          sm.stale_reason,
          ci.subject_id AS current_subject_id,
          ci.content_hash AS current_content_hash,
          (
            sm.stale_reason IS NULL
            OR sm.stale_reason IN (
              'source_update',
              'content_revalidation_pending',
              'candidate_removed',
              'candidate_changed'
            )
          ) AS replace_reason
        FROM current_inputs ci
        FULL JOIN otlet.semantic_materializations sm
          ON sm.task_name = %3$L
         AND sm.record_type = %4$L
         AND sm.subject_id = ci.subject_id
        WHERE ci.subject_id IS NOT NULL
           OR (sm.task_name = %3$L AND sm.record_type = %4$L)
      ),
      candidate_states AS (
        SELECT
          id,
          CASE
            WHEN current_subject_id IS NULL AND replace_reason THEN 'candidate_removed'
            WHEN current_content_hash IS DISTINCT FROM material_content_hash AND replace_reason THEN 'candidate_changed'
            WHEN current_content_hash IS NOT DISTINCT FROM material_content_hash
              AND stale_reason IN ('candidate_removed', 'candidate_changed') THEN 'candidate_restored'
            ELSE NULL
          END AS transition
        FROM candidate_materializations
        WHERE id IS NOT NULL
      ),
      reconciled AS (
        UPDATE otlet.semantic_materializations sm
        SET stale = state.transition <> 'candidate_restored',
            stale_reason = CASE
              WHEN state.transition = 'candidate_restored' THEN NULL
              ELSE state.transition
            END,
            freshness_basis = CASE
              WHEN state.transition = 'candidate_restored' THEN 'content_hash_match'
              ELSE sm.freshness_basis
            END,
            updated_at = now()
        FROM candidate_states state
        WHERE sm.id = state.id
          AND state.transition IS NOT NULL
          AND (
            sm.stale IS DISTINCT FROM (state.transition <> 'candidate_restored')
            OR sm.stale_reason IS DISTINCT FROM CASE
              WHEN state.transition = 'candidate_restored' THEN NULL
              ELSE state.transition
            END
        )
        RETURNING sm.id
      ),
      matched_inputs AS (
        SELECT DISTINCT current_subject_id AS subject_id
        FROM candidate_materializations
        WHERE current_subject_id IS NOT NULL
          AND material_content_hash = current_content_hash
          AND material_contract_hash = %5$L
      )
      SELECT ci.subject_id, ci.input
      FROM current_inputs ci
      WHERE NOT EXISTS (
        SELECT 1
        FROM matched_inputs matched
        WHERE matched.subject_id = ci.subject_id
      )
      ORDER BY ci.subject_id
    $sql$,
    index_row.candidate_query,
    index_row.max_candidate_rows,
    index_row.task_name,
    index_row.record_type,
    current_contract_hash,
    current_input_shaping
  );
END;
$$;

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
  wrapped_query text;
  candidate_plan jsonb;
  candidate_plan_cost numeric;
BEGIN
  IF index_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet semantic join index name % must be a simple identifier', index_name;
  END IF;

  IF semantic_task_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet semantic join index name % creates invalid task name %', index_name, semantic_task_name;
  END IF;

  SELECT preflight.candidate_plan, preflight.candidate_plan_cost
  INTO candidate_plan, candidate_plan_cost
  FROM otlet.preflight_candidate_query(candidate_query) preflight;

  wrapped_query := format(
    'SELECT subject_id, input FROM otlet.semantic_join_refresh_inputs(%L)',
    index_name
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
    candidate_plan,
    candidate_plan_cost,
    candidate_preflight_at,
    updated_at
  )
  VALUES (
    index_name,
    semantic_task_name,
    candidate_query,
    semantic_record_type,
    model_name,
    bounded_rows,
    candidate_plan,
    candidate_plan_cost,
    now(),
    now()
  )
  ON CONFLICT (name) DO UPDATE
    SET task_name = EXCLUDED.task_name,
        candidate_query = EXCLUDED.candidate_query,
        record_type = EXCLUDED.record_type,
        model_name = EXCLUDED.model_name,
        max_candidate_rows = EXCLUDED.max_candidate_rows,
        candidate_plan = EXCLUDED.candidate_plan,
        candidate_plan_cost = EXCLUDED.candidate_plan_cost,
        candidate_preflight_at = EXCLUDED.candidate_preflight_at,
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

CREATE FUNCTION otlet.complete_and_materialize_job(
  job_id bigint,
  output jsonb,
  raw_output text,
  actions jsonb,
  prompt_hash text,
  input_hash text,
  output_schema_hash text,
  raw_output_hash text,
  trace_summary jsonb,
  model_name text,
  selection_role text,
  selection_reason text
) RETURNS TABLE (
  output_id bigint,
  semantic_materialized boolean,
  completion_error text,
  materialization_error text
)
LANGUAGE plpgsql
AS $$
BEGIN
  BEGIN
    SELECT completed.id
    INTO output_id
    FROM otlet.complete_job(
      complete_and_materialize_job.job_id,
      complete_and_materialize_job.output,
      complete_and_materialize_job.raw_output,
      complete_and_materialize_job.actions,
      complete_and_materialize_job.prompt_hash,
      complete_and_materialize_job.input_hash,
      complete_and_materialize_job.output_schema_hash,
      complete_and_materialize_job.raw_output_hash,
      trace_summary => complete_and_materialize_job.trace_summary,
      model_name => complete_and_materialize_job.model_name,
      selection_role => complete_and_materialize_job.selection_role,
      selection_reason => complete_and_materialize_job.selection_reason
    )
    AS completed
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    completion_error := SQLERRM;
    RETURN NEXT;
    RETURN;
  END;

  IF output_id IS NULL THEN
    RETURN NEXT;
    RETURN;
  END IF;

  BEGIN
    PERFORM otlet.materialize_completed_semantic_job(
      complete_and_materialize_job.job_id
    );
    semantic_materialized := true;
  EXCEPTION WHEN OTHERS THEN
    materialization_error := SQLERRM;
    BEGIN
      PERFORM otlet.record_worker_event(
        'semantic_materialization_failed',
        j.id,
        'linked_inproc',
        'otlet semantic materialization failed',
        jsonb_build_object(
          'task_name', j.task_name,
          'subject_id', j.subject_id,
          'model_name', complete_and_materialize_job.model_name,
          'error', materialization_error
        )
      )
      FROM otlet.jobs j
      WHERE j.id = complete_and_materialize_job.job_id;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END;

  RETURN NEXT;
END;
$$;
