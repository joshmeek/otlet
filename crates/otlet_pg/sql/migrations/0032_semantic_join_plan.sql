CREATE FUNCTION otlet.semantic_join_index_plan(
  index_name text,
  exact boolean DEFAULT false,
  expected_workload_revision_hash text DEFAULT NULL
) RETURNS TABLE (
  selected_path text,
  reason text,
  effective_stale_policy text,
  name text,
  task_name text,
  record_type text,
  model_name text,
  runtime_name text,
  source_relation text,
  total_subjects bigint,
  fresh_subjects bigint,
  stale_subjects bigint,
  missing_subjects bigint,
  inflight_subjects bigint,
  lookup_subjects bigint,
  wait_subjects bigint,
  queue_subjects bigint,
  infer_now_subjects bigint,
  fail_closed_subjects bigint,
  freshness numeric,
  model_ms numeric,
  model_cost_source text,
  cache_hit_ms numeric,
  lookup_ms numeric,
  queue_ms numeric,
  infer_now_ms numeric,
  path_cost numeric,
  worker_queue_depth bigint,
  available_queue_slots bigint,
  stale_reasons jsonb,
  count_basis text,
  checked_at timestamptz
)
LANGUAGE plpgsql
ROWS 1
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  v_total_subjects bigint := 0;
  v_fresh_subjects bigint := 0;
  v_stale_subjects bigint := 0;
  v_missing_subjects bigint := 0;
  v_stale_reasons jsonb := '{}'::jsonb;
  v_count_basis text := CASE WHEN exact THEN 'exact' ELSE 'estimated' END;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
BEGIN
  SELECT
    revision.definition #>> '{source,semantic_join_index_name}',
    revision.definition #>> '{task,name}',
    revision.definition #>> '{source,record_type}',
    revision.definition #>> '{models,direct,name}',
    (revision.definition #>> '{source,max_candidate_rows}')::integer,
    head.active_workload_revision_hash,
    revision.definition #> '{task,input_shaping}'
  INTO
    index_row.name,
    index_row.task_name,
    index_row.record_type,
    index_row.model_name,
    index_row.max_candidate_rows,
    current_contract_hash,
    current_input_shaping
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_join_index_name}' = semantic_join_index_plan.index_name
    AND revision.definition #>> '{source,kind}' = 'pair';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', semantic_join_index_plan.index_name;
  END IF;

  IF semantic_join_index_plan.expected_workload_revision_hash IS NOT NULL
     AND semantic_join_index_plan.expected_workload_revision_hash IS DISTINCT FROM current_contract_hash THEN
    RAISE EXCEPTION 'otlet workload revision changed during semantic join plan for index %', index_row.name;
  END IF;

  IF NOT exact THEN
    PERFORM otlet.require_workload_source_contract(
      index_row.task_name,
      current_contract_hash,
      false
    );
  END IF;

  IF exact THEN
    EXECUTE format(
      $sql$
        WITH raw_inputs AS (
          SELECT subject_id, input
          FROM otlet.semantic_join_candidate_rows(%1$L, %4$L, false)
        ),
        current_inputs AS (
          SELECT
            subject_id,
            input,
            otlet.semantic_source_hash(input) AS source_hash,
            otlet.semantic_content_hash(input, %5$L::jsonb) AS content_hash
          FROM raw_inputs
        ),
        latest AS (
          SELECT DISTINCT ON (sm.subject_id)
            sm.subject_id,
            sm.stale,
            sm.source_hash,
            sm.content_hash,
            sm.contract_hash,
            sm.stale_reason,
            sm.updated_at,
            sm.id
          FROM current_inputs ci
          JOIN otlet.semantic_materializations sm
            ON sm.subject_id = ci.subject_id
          WHERE sm.task_name = %2$L
            AND sm.record_type = %3$L
            AND sm.contract_hash = %4$L
          ORDER BY
            sm.subject_id,
            (
              sm.content_hash IS NOT DISTINCT FROM ci.content_hash
              AND sm.contract_hash IS NOT DISTINCT FROM %4$L
            ) DESC,
            sm.updated_at DESC,
            sm.id DESC
        ),
        classified AS (
          SELECT
            ci.subject_id,
            l.subject_id IS NOT NULL AS has_materialization,
            COALESCE(status.is_fresh, false) AS source_fresh,
            (l.subject_id IS NOT NULL AND COALESCE(status.is_stale, true)) AS source_stale,
            COALESCE(status.stale_reason, 'content_revalidation_pending') AS stale_reason
          FROM current_inputs ci
          LEFT JOIN latest l USING (subject_id)
          LEFT JOIN LATERAL otlet.semantic_freshness_status(
            l.content_hash,
            l.contract_hash,
            l.stale,
            l.stale_reason,
            l.source_hash,
            ci.content_hash,
            %4$L,
            ci.source_hash
          ) status ON l.subject_id IS NOT NULL
        )
        SELECT
          count(*)::bigint,
          count(*) FILTER (WHERE has_materialization AND source_fresh)::bigint,
          count(*) FILTER (WHERE source_stale)::bigint,
          count(*) FILTER (WHERE NOT has_materialization)::bigint,
          COALESCE(
            (
              SELECT jsonb_object_agg(reason, reason_count ORDER BY reason)
              FROM (
                SELECT stale_reason AS reason, count(*) AS reason_count
                FROM classified
                WHERE source_stale
                GROUP BY stale_reason
              ) reasons
            ),
            '{}'::jsonb
          )
        FROM classified
      $sql$,
      index_row.name,
      index_row.task_name,
      index_row.record_type,
      current_contract_hash,
      current_input_shaping
    )
    INTO v_total_subjects, v_fresh_subjects, v_stale_subjects, v_missing_subjects, v_stale_reasons;
  ELSE
    WITH latest AS (
      SELECT DISTINCT ON (sm.subject_id)
        sm.subject_id,
        sm.stale,
        sm.source_hash,
        sm.content_hash,
        sm.contract_hash,
        sm.stale_reason,
        sm.updated_at,
        sm.id
      FROM otlet.semantic_materializations sm
      WHERE sm.task_name = index_row.task_name
        AND sm.record_type = index_row.record_type
        AND sm.contract_hash = current_contract_hash
      ORDER BY
        sm.subject_id,
        (
          NOT sm.stale
          AND sm.contract_hash IS NOT DISTINCT FROM current_contract_hash
        ) DESC,
        sm.updated_at DESC,
        sm.id DESC
    ),
    classified AS (
      SELECT
        subject_id,
        status.is_fresh,
        status.is_stale,
        COALESCE(status.stale_reason, 'content_revalidation_pending') AS stale_reason
      FROM latest
      CROSS JOIN LATERAL otlet.semantic_freshness_status(
        content_hash,
        contract_hash,
        stale,
        stale_reason,
        source_hash,
        content_hash,
        current_contract_hash,
        source_hash
      ) status
    ),
    materialized AS (
      SELECT
        count(*)::bigint AS materialized_subjects,
        count(*) FILTER (WHERE is_fresh)::bigint AS fresh_subjects,
        count(*) FILTER (WHERE is_stale)::bigint AS stale_subjects,
        COALESCE(
          (
            SELECT jsonb_object_agg(reason_rows.reason, reason_rows.reason_count ORDER BY reason_rows.reason)
            FROM (
              SELECT stale_reason AS reason, count(*) AS reason_count
              FROM classified
              WHERE is_stale
              GROUP BY stale_reason
            ) reason_rows
          ),
          '{}'::jsonb
        ) AS stale_reasons
      FROM classified
    )
    SELECT
      CASE
        WHEN m.materialized_subjects > 0 THEN m.materialized_subjects
        ELSE COALESCE(index_row.max_candidate_rows, 0)::bigint
      END,
      m.fresh_subjects,
      m.stale_subjects,
      GREATEST(
        (
          CASE
            WHEN m.materialized_subjects > 0 THEN m.materialized_subjects
            ELSE COALESCE(index_row.max_candidate_rows, 0)::bigint
          END
        ) - m.fresh_subjects - m.stale_subjects,
        0
      ),
      m.stale_reasons
    INTO v_total_subjects, v_fresh_subjects, v_stale_subjects, v_missing_subjects, v_stale_reasons
    FROM materialized m;
  END IF;

  RETURN QUERY
  SELECT *
  FROM otlet.semantic_plan_from_counts(
    index_row.name,
    index_row.task_name,
    index_row.record_type,
    index_row.model_name,
    'semantic_join:' || index_row.name,
    'semantic_join_lookup',
    'empty candidate set',
    'semantic join index fully fresh',
    'policy returns fresh pair lookup rows only',
    'partial pair refresh queued before lookup',
    'fresh_pair_inference',
    'fresh pair inference has no reusable semantic coverage',
    v_total_subjects,
    v_fresh_subjects,
    v_stale_subjects,
    v_missing_subjects,
    v_stale_reasons,
    v_count_basis
  );
END;
$$;
