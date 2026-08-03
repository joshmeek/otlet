CREATE FUNCTION otlet.semantic_join_refresh_inputs(
  index_name text,
  workload_revision_hash text DEFAULT NULL
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
  revision_definition jsonb;
  requested_revision_hash text := semantic_join_refresh_inputs.workload_revision_hash;
BEGIN
  IF requested_revision_hash IS NULL THEN
    SELECT head.active_workload_revision_hash
    INTO requested_revision_hash
    FROM otlet.workload_revision_heads head
    JOIN otlet.workload_revisions revision
      ON revision.task_name = head.task_name
     AND revision.workload_revision_hash = head.active_workload_revision_hash
    WHERE revision.definition #>> '{source,semantic_join_index_name}' = semantic_join_refresh_inputs.index_name
      AND revision.definition #>> '{source,kind}' = 'pair';
  END IF;

  SELECT revision.definition
  INTO revision_definition
  FROM otlet.workload_revisions revision
  JOIN otlet.workload_revision_heads head
    ON head.task_name = revision.task_name
   AND head.active_workload_revision_hash = revision.workload_revision_hash
  WHERE revision.workload_revision_hash = requested_revision_hash
    AND revision.definition #>> '{source,semantic_join_index_name}' = semantic_join_refresh_inputs.index_name
    AND revision.definition #>> '{source,kind}' = 'pair';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet active workload revision does not define semantic join index %',
      semantic_join_refresh_inputs.index_name;
  END IF;

  PERFORM otlet.require_workload_source_contract(
    revision_definition #>> '{task,name}',
    requested_revision_hash
  );

  index_row.name := revision_definition #>> '{source,semantic_join_index_name}';
  index_row.task_name := revision_definition #>> '{task,name}';
  index_row.candidate_query := revision_definition #>> '{source,candidate_query}';
  index_row.record_type := revision_definition #>> '{source,record_type}';
  index_row.max_candidate_rows := (revision_definition #>> '{source,max_candidate_rows}')::integer;
  current_input_shaping := revision_definition #> '{task,input_shaping}';
  current_contract_hash := requested_revision_hash;

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
          sm.stale AS material_stale,
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
         AND sm.contract_hash = %5$L
        WHERE ci.subject_id IS NOT NULL
           OR (
             sm.task_name = %3$L
             AND sm.record_type = %4$L
             AND sm.contract_hash = %5$L
           )
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
          AND sm.stale_reason IS DISTINCT FROM 'contract_changed'
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
        SELECT DISTINCT candidate.current_subject_id AS subject_id
        FROM candidate_materializations candidate
        LEFT JOIN candidate_states state ON state.id = candidate.id
        WHERE candidate.current_subject_id IS NOT NULL
          AND candidate.material_content_hash = candidate.current_content_hash
          AND candidate.material_contract_hash = %5$L
          AND (NOT candidate.material_stale OR state.transition = 'candidate_restored')
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
  decision_contract jsonb DEFAULT '{}'::jsonb,
  pair_sources jsonb DEFAULT '[]'::jsonb
) RETURNS otlet.semantic_join_indexes
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.semantic_join_indexes%ROWTYPE;
  semantic_record_type text := COALESCE(record_type, index_name);
  semantic_task_name text := index_name || '_task';
  bounded_rows integer := GREATEST(1, LEAST(COALESCE(max_candidate_rows, 1000), 100000));
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

  PERFORM otlet.create_task(
    semantic_task_name,
    candidate_query,
    instruction,
    output_schema,
    model_name,
    runtime_options,
    input_shaping,
    decision_contract,
    pair_sources
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

  UPDATE otlet.semantic_materializations sm
  SET stale = true,
      stale_reason = 'contract_changed',
      updated_at = now()
  WHERE sm.task_name = index_row.task_name
    AND sm.record_type = index_row.record_type;

  DELETE FROM otlet.semantic_join_indexes sji
  WHERE sji.name = index_row.name;

  RETURN true;
END;
$$;

CREATE FUNCTION otlet.refresh_semantic_join_index(
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
  WHERE revision.definition #>> '{source,semantic_join_index_name}' = refresh_semantic_join_index.index_name
    AND revision.definition #>> '{source,kind}' = 'pair';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', refresh_semantic_join_index.index_name;
  END IF;

  SELECT otlet.run_task(task_name) INTO queued;

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
  revision_definition jsonb;
BEGIN
  SELECT
    revision.definition #>> '{source,semantic_join_index_name}',
    revision.definition #>> '{task,name}'
  INTO index_row.name, index_row.task_name
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_join_index_name}' = materialize_semantic_join_index.index_name
    AND revision.definition #>> '{source,kind}' = 'pair'
  FOR UPDATE OF head;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', materialize_semantic_join_index.index_name;
  END IF;

  SELECT active.definition
  INTO revision_definition
  FROM otlet.active_workload_revision(index_row.task_name) active;
  index_row.record_type := revision_definition #>> '{source,record_type}';
  index_row.candidate_query := revision_definition #>> '{source,candidate_query}';
  index_row.max_candidate_rows := (revision_definition #>> '{source,max_candidate_rows}')::integer;
  index_row.name := revision_definition #>> '{source,semantic_join_index_name}';

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

  RETURN refreshed;
END;
$$;

CREATE FUNCTION otlet.materialize_semantic_join_index_subject(
  index_name text,
  subject_id text,
  expected_workload_revision_hash text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  input_query text;
  refreshed bigint;
  revision_definition jsonb;
  active_revision_hash text;
BEGIN
  SELECT
    revision.definition #>> '{source,semantic_join_index_name}',
    revision.definition #>> '{task,name}',
    head.active_workload_revision_hash
  INTO index_row.name, index_row.task_name, active_revision_hash
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_join_index_name}' = materialize_semantic_join_index_subject.index_name
    AND revision.definition #>> '{source,kind}' = 'pair'
  FOR UPDATE OF head;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', materialize_semantic_join_index_subject.index_name;
  END IF;

  IF materialize_semantic_join_index_subject.expected_workload_revision_hash IS NOT NULL
     AND materialize_semantic_join_index_subject.expected_workload_revision_hash IS DISTINCT FROM active_revision_hash THEN
    RAISE EXCEPTION 'otlet workload revision changed during semantic materialization for index %', index_row.name;
  END IF;

  SELECT active.definition
  INTO revision_definition
  FROM otlet.active_workload_revision(index_row.task_name) active;
  index_row.record_type := revision_definition #>> '{source,record_type}';
  index_row.candidate_query := revision_definition #>> '{source,candidate_query}';
  index_row.max_candidate_rows := (revision_definition #>> '{source,max_candidate_rows}')::integer;
  index_row.name := revision_definition #>> '{source,semantic_join_index_name}';

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

  RETURN refreshed;
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
  selection_reason text,
  expected_claim_token text
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
      selection_reason => complete_and_materialize_job.selection_reason,
      expected_claim_token => complete_and_materialize_job.expected_claim_token
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
    SELECT otlet.materialize_completed_semantic_job(
      complete_and_materialize_job.job_id
    ) > 0
    INTO semantic_materialized;
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
