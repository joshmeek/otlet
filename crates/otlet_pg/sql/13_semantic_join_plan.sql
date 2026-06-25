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

CREATE FUNCTION otlet.semantic_join_index_stats(
  index_name text
) RETURNS TABLE (
  name text,
  task_name text,
  record_type text,
  model_name text,
  max_candidate_rows integer,
  total_pairs bigint,
  ready_pairs bigint,
  stale_pairs bigint,
  missing_pairs bigint,
  refresh_pairs bigint,
  active_jobs bigint,
  completed_jobs bigint,
  freshness numeric,
  avg_generate_ms numeric,
  estimated_lookup_ms numeric,
  estimated_refresh_ms numeric,
  estimated_fresh_inference_ms numeric,
  last_refresh_at timestamptz,
  last_lookup_at timestamptz,
  last_materialized_at timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  total_count bigint;
  ready_count bigint;
  stale_count bigint;
  missing_count bigint;
  active_count bigint;
  complete_count bigint;
  generate_ms numeric;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = semantic_join_index_stats.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', semantic_join_index_stats.index_name;
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
        count(*)::bigint AS total_pairs,
        count(*) FILTER (WHERE has_materialization AND stale = false AND source_fresh)::bigint AS ready_pairs,
        count(*) FILTER (WHERE has_materialization AND NOT (stale = false AND source_fresh))::bigint AS stale_pairs,
        count(*) FILTER (WHERE NOT has_materialization)::bigint AS missing_pairs
      FROM classified
    $sql$,
    index_row.candidate_query,
    index_row.max_candidate_rows,
    index_row.task_name,
    index_row.record_type
  )
  INTO total_count, ready_count, stale_count, missing_count;

  SELECT
    count(*) FILTER (WHERE j.status IN ('queued', 'running', 'cancel_requested')),
    count(*) FILTER (WHERE j.status = 'complete')
  INTO active_count, complete_count
  FROM otlet.jobs j
  WHERE j.task_name = index_row.task_name;

  SELECT COALESCE(NULLIF(rs.last_generate_ms, 0), 2500)::numeric
  INTO generate_ms
  FROM otlet.runtime_slots rs
  JOIN otlet.models m ON m.name = index_row.model_name
  WHERE rs.model_name = index_row.model_name
    AND rs.runtime_name = m.runtime_name
  ORDER BY rs.last_used_at DESC NULLS LAST
  LIMIT 1;

  generate_ms := COALESCE(generate_ms, 2500);

  RETURN QUERY
  SELECT
    index_row.name,
    index_row.task_name,
    index_row.record_type,
    index_row.model_name,
    index_row.max_candidate_rows,
    COALESCE(total_count, 0),
    COALESCE(ready_count, 0),
    COALESCE(stale_count, 0),
    COALESCE(missing_count, 0),
    COALESCE(stale_count, 0) + COALESCE(missing_count, 0),
    COALESCE(active_count, 0),
    COALESCE(complete_count, 0),
    CASE WHEN COALESCE(total_count, 0) = 0 THEN 1::numeric ELSE round(COALESCE(ready_count, 0)::numeric / total_count, 4) END,
    generate_ms,
    round(1 + (COALESCE(ready_count, 0)::numeric * 0.05), 2),
    round(((COALESCE(stale_count, 0) + COALESCE(missing_count, 0))::numeric * generate_ms) + 1 + (COALESCE(total_count, 0)::numeric * 0.05), 2),
    round(COALESCE(total_count, 0)::numeric * generate_ms, 2),
    index_row.last_refresh_at,
    index_row.last_lookup_at,
    index_row.last_materialized_at;
END;
$$;

CREATE FUNCTION otlet.semantic_join_index_plan(
  index_name text,
  allow_refresh boolean DEFAULT true
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
LANGUAGE sql
AS $$
  WITH stats AS (
    SELECT *
    FROM otlet.semantic_join_index_stats($1)
  ),
  decision AS (
    SELECT
      CASE
        WHEN total_pairs = 0 THEN 'semantic_join_lookup'
        WHEN active_jobs > 0 THEN 'wait_for_refresh'
        WHEN refresh_pairs = 0 THEN 'semantic_join_lookup'
        WHEN policy.stale_policy = 'lookup_only_fail_closed' THEN 'semantic_join_lookup'
        WHEN $2 THEN 'refresh_then_lookup'
        ELSE 'fresh_pair_inference'
      END AS selected_path,
      CASE
        WHEN total_pairs = 0 THEN 'empty candidate set'
        WHEN active_jobs > 0 THEN 'pair refresh already active'
        WHEN refresh_pairs = 0 THEN 'semantic join index fully fresh'
        WHEN policy.stale_policy = 'lookup_only_fail_closed' THEN 'policy returns fresh pair lookup rows only'
        WHEN $2 THEN 'bounded pair refresh required'
        ELSE 'fresh pair inference required'
      END AS reason,
      policy.stale_policy AS effective_stale_policy,
      stats.*
    FROM stats
    CROSS JOIN otlet.production_policy policy
  )
  SELECT
    selected_path,
    reason,
    effective_stale_policy,
    name,
    task_name,
    record_type,
    total_pairs,
    ready_pairs,
    stale_pairs,
    missing_pairs,
    refresh_pairs,
    freshness,
    estimated_lookup_ms,
    estimated_refresh_ms,
    estimated_fresh_inference_ms,
    active_jobs,
    completed_jobs
  FROM decision;
$$;
