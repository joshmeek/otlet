CREATE FUNCTION otlet.semantic_join_index_current_rows(
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
  index_row otlet.semantic_join_indexes%ROWTYPE;
  fresh_sql text := CASE WHEN COALESCE(fresh_only, true) THEN 'true' ELSE 'false' END;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = semantic_join_index_current_rows.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', semantic_join_index_current_rows.index_name;
  END IF;

  RETURN QUERY EXECUTE format(
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
      latest AS (
        SELECT DISTINCT ON (sm.subject_id)
          sm.subject_id,
          sm.body,
          sm.stale,
          sm.source_hash,
          sm.updated_at,
          sm.id
        FROM current_inputs ci
        JOIN otlet.semantic_materializations sm
          ON sm.subject_id = ci.subject_id
        WHERE sm.task_name = %3$L
          AND sm.record_type = %4$L
        ORDER BY
          sm.subject_id,
          (sm.stale = false AND sm.source_hash = md5(ci.input::text)) DESC,
          sm.updated_at DESC,
          sm.id DESC
      )
      SELECT
        latest.subject_id,
        latest.body,
        latest.stale OR latest.source_hash IS DISTINCT FROM md5(ci.input::text) AS stale,
        latest.source_hash,
        latest.updated_at
      FROM current_inputs ci
      JOIN latest ON latest.subject_id = ci.subject_id
      WHERE (
        NOT %5$s
        OR (latest.stale = false AND latest.source_hash = md5(ci.input::text))
      )
      ORDER BY latest.subject_id
    $sql$,
    index_row.candidate_query,
    index_row.max_candidate_rows,
    index_row.task_name,
    index_row.record_type,
    fresh_sql
  );
END;
$$;

CREATE FUNCTION otlet.semantic_join_matches(
  index_name text,
  subject_id text,
  expected jsonb
) RETURNS boolean
LANGUAGE sql
STABLE
STRICT
COST 1000
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM otlet.semantic_join_index_current_rows(index_name, true) lookup
    WHERE lookup.subject_id = semantic_join_matches.subject_id
      AND lookup.body @> semantic_join_matches.expected
  );
$$;

CREATE FUNCTION otlet.semantic_join_matches_auto(
  index_name text,
  subject_id text,
  expected jsonb,
  max_wait_ms integer DEFAULT 10000,
  max_infer_ms integer DEFAULT 15000,
  max_rows integer DEFAULT 1,
  allow_refresh boolean DEFAULT true
) RETURNS boolean
LANGUAGE sql
STABLE
STRICT
COST 1000
AS $$
  SELECT otlet.semantic_join_matches(
    semantic_join_matches_auto.index_name,
    semantic_join_matches_auto.subject_id,
    semantic_join_matches_auto.expected
  )
    AND GREATEST(0, LEAST(COALESCE(semantic_join_matches_auto.max_wait_ms, 0), 30000)) >= 0
    AND GREATEST(0, LEAST(COALESCE(semantic_join_matches_auto.max_infer_ms, 0), 30000)) >= 0
    AND GREATEST(0, LEAST(COALESCE(semantic_join_matches_auto.max_rows, 1), 10)) >= 0
    AND semantic_join_matches_auto.allow_refresh IS NOT NULL;
$$;

CREATE FUNCTION otlet.semantic_join_index_plan(
  index_name text
) RETURNS TABLE (
  selected_path text,
  reason text,
  effective_stale_policy text,
  name text,
  task_name text,
  record_type text,
  total_pairs bigint,
  ready_pairs bigint,
  stale_pairs bigint,
  missing_pairs bigint,
  refresh_pairs bigint,
  freshness numeric,
  estimated_lookup_ms numeric,
  estimated_refresh_ms numeric,
  estimated_fresh_inference_ms numeric,
  active_jobs bigint,
  completed_jobs bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  v_total_pairs bigint := 0;
  v_ready_pairs bigint := 0;
  v_stale_pairs bigint := 0;
  v_missing_pairs bigint := 0;
  v_refresh_pairs bigint := 0;
  v_active_jobs bigint := 0;
  v_completed_jobs bigint := 0;
  v_generate_ms numeric := 2500;
  v_stale_policy text;
  v_selected_path text;
  v_reason text;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = semantic_join_index_plan.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', semantic_join_index_plan.index_name;
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
      latest AS (
        SELECT DISTINCT ON (sm.subject_id)
          sm.subject_id,
          sm.stale,
          sm.source_hash,
          sm.updated_at,
          sm.id
        FROM current_inputs ci
        JOIN otlet.semantic_materializations sm
          ON sm.subject_id = ci.subject_id
        WHERE sm.task_name = %3$L
          AND sm.record_type = %4$L
        ORDER BY
          sm.subject_id,
          (sm.stale = false AND sm.source_hash = md5(ci.input::text)) DESC,
          sm.updated_at DESC,
          sm.id DESC
      ),
      classified AS (
        SELECT
          ci.subject_id,
          l.subject_id IS NOT NULL AS has_materialization,
          COALESCE(l.stale, true) AS stale,
          l.source_hash = md5(ci.input::text) AS source_fresh
        FROM current_inputs ci
        LEFT JOIN latest l USING (subject_id)
      )
      SELECT
        count(*)::bigint,
        count(*) FILTER (WHERE has_materialization AND stale = false AND source_fresh)::bigint,
        count(*) FILTER (WHERE has_materialization AND NOT (stale = false AND source_fresh))::bigint,
        count(*) FILTER (WHERE NOT has_materialization)::bigint
      FROM classified
    $sql$,
    index_row.candidate_query,
    index_row.max_candidate_rows,
    index_row.task_name,
    index_row.record_type
  )
  INTO v_total_pairs, v_ready_pairs, v_stale_pairs, v_missing_pairs;

  v_total_pairs := COALESCE(v_total_pairs, 0);
  v_ready_pairs := COALESCE(v_ready_pairs, 0);
  v_stale_pairs := COALESCE(v_stale_pairs, 0);
  v_missing_pairs := COALESCE(v_missing_pairs, 0);
  v_refresh_pairs := v_stale_pairs + v_missing_pairs;

  SELECT
    count(*) FILTER (WHERE j.status IN ('queued', 'running', 'cancel_requested')),
    count(*) FILTER (WHERE j.status = 'complete')
  INTO v_active_jobs, v_completed_jobs
  FROM otlet.jobs j
  WHERE j.task_name = index_row.task_name;

  v_active_jobs := COALESCE(v_active_jobs, 0);
  v_completed_jobs := COALESCE(v_completed_jobs, 0);

  SELECT COALESCE(NULLIF(rs.last_generate_ms, 0), 2500)::numeric
  INTO v_generate_ms
  FROM otlet.runtime_slots rs
  JOIN otlet.models m ON m.name = index_row.model_name
  WHERE rs.model_name = index_row.model_name
    AND rs.runtime_name = m.runtime_name
  ORDER BY rs.last_used_at DESC NULLS LAST
  LIMIT 1;

  v_generate_ms := COALESCE(v_generate_ms, 2500);

  SELECT policy.stale_policy
  INTO v_stale_policy
  FROM otlet.production_policy policy
  LIMIT 1;

  v_stale_policy := COALESCE(v_stale_policy, 'lookup_only_fail_closed');

  IF v_total_pairs = 0 THEN
    v_selected_path := 'semantic_join_lookup';
    v_reason := 'empty candidate set';
  ELSIF v_active_jobs > 0 THEN
    v_selected_path := 'wait_for_refresh';
    v_reason := 'pair refresh already active';
  ELSIF v_refresh_pairs = 0 THEN
    v_selected_path := 'semantic_join_lookup';
    v_reason := 'semantic join index fully fresh';
  ELSIF v_stale_policy = 'lookup_only_fail_closed' THEN
    v_selected_path := 'semantic_join_lookup';
    v_reason := 'policy returns fresh pair lookup rows only';
  ELSIF v_refresh_pairs < v_total_pairs THEN
    v_selected_path := 'refresh_then_lookup';
    v_reason := 'partial pair refresh cheaper than full fresh inference';
  ELSE
    v_selected_path := 'fresh_pair_inference';
    v_reason := 'fresh pair inference has no reusable semantic coverage';
  END IF;

  RETURN QUERY
  SELECT
    v_selected_path,
    v_reason,
    v_stale_policy,
    index_row.name,
    index_row.task_name,
    index_row.record_type,
    v_total_pairs,
    v_ready_pairs,
    v_stale_pairs,
    v_missing_pairs,
    v_refresh_pairs,
    CASE WHEN v_total_pairs = 0 THEN 1::numeric ELSE round(v_ready_pairs::numeric / v_total_pairs, 4) END,
    round(1 + (v_ready_pairs::numeric * 0.05), 2),
    round((v_refresh_pairs::numeric * v_generate_ms) + 1 + (v_total_pairs::numeric * 0.05), 2),
    round(v_total_pairs::numeric * v_generate_ms, 2),
    v_active_jobs,
    v_completed_jobs;
END;
$$;
