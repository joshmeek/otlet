
CREATE FUNCTION otlet.semantic_index_stats(
  index_name text
) RETURNS TABLE (
  name text,
  task_name text,
  source_table text,
  subject_column text,
  record_type text,
  model_name text,
  total_rows bigint,
  ready_rows bigint,
  stale_rows bigint,
  refresh_rows bigint,
  missing_rows bigint,
  active_jobs bigint,
  completed_jobs bigint,
  freshness numeric,
  refresh_coverage numeric,
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
  index_row otlet.semantic_indexes%ROWTYPE;
  source_rows bigint;
  fresh_rows bigint;
  current_stale_rows bigint;
  rows_to_refresh bigint;
  active_count bigint;
  complete_count bigint;
  materialized_at timestamptz;
  generate_ms numeric;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes si
  WHERE si.name = semantic_index_stats.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', semantic_index_stats.index_name;
  END IF;

  EXECUTE format(
    $sql$
      WITH current_inputs AS (
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
            'row', to_jsonb(src)
          ) AS input
        FROM %3$s AS src
      ),
      latest AS (
        SELECT DISTINCT ON (sm.subject_id)
          sm.subject_id,
          sm.stale,
          sm.source_hash,
          sm.updated_at,
          sm.id
        FROM otlet.semantic_materializations sm
        WHERE sm.task_name = %4$L
          AND sm.record_type = %5$L
        ORDER BY sm.subject_id, sm.updated_at DESC, sm.id DESC
      ),
      classified AS (
        SELECT
          ci.subject_id,
          l.subject_id IS NOT NULL AS has_materialization,
          l.updated_at,
          (
            l.subject_id IS NOT NULL
            AND l.stale = false
            AND l.source_hash = md5(ci.input::text)
          ) AS is_fresh,
          (
            l.subject_id IS NOT NULL
            AND NOT (
              l.stale = false
              AND l.source_hash = md5(ci.input::text)
            )
          ) AS is_stale
        FROM current_inputs ci
        LEFT JOIN latest l USING (subject_id)
      )
      SELECT
        count(*)::bigint,
        count(*) FILTER (WHERE is_fresh)::bigint,
        count(*) FILTER (WHERE is_stale)::bigint,
        count(*) FILTER (WHERE NOT is_fresh)::bigint,
        max(updated_at)
      FROM classified
    $sql$,
    index_row.subject_column,
    index_row.source_table,
    index_row.source_table,
    index_row.task_name,
    index_row.record_type
  )
  INTO source_rows, fresh_rows, current_stale_rows, rows_to_refresh, materialized_at;

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
    index_row.source_table,
    index_row.subject_column,
    index_row.record_type,
    index_row.model_name,
    COALESCE(source_rows, 0),
    COALESCE(fresh_rows, 0),
    COALESCE(current_stale_rows, 0),
    COALESCE(rows_to_refresh, 0),
    GREATEST(COALESCE(source_rows, 0) - COALESCE(fresh_rows, 0), 0),
    COALESCE(active_count, 0),
    COALESCE(complete_count, 0),
    CASE WHEN COALESCE(source_rows, 0) = 0 THEN 1::numeric ELSE round(COALESCE(fresh_rows, 0)::numeric / source_rows, 4) END,
    CASE WHEN COALESCE(source_rows, 0) = 0 THEN 1::numeric ELSE round(GREATEST(source_rows - COALESCE(rows_to_refresh, 0), 0)::numeric / source_rows, 4) END,
    generate_ms,
    round(1 + (COALESCE(fresh_rows, 0)::numeric * 0.05), 2),
    round((COALESCE(rows_to_refresh, 0)::numeric * generate_ms) + 1 + (COALESCE(source_rows, 0)::numeric * 0.05), 2),
    round(COALESCE(source_rows, 0)::numeric * generate_ms, 2),
    index_row.last_refresh_at,
    index_row.last_lookup_at,
    materialized_at;
END;
$$;

CREATE OR REPLACE VIEW otlet.semantic_index_status AS
SELECT
  stats.name,
  stats.task_name,
  stats.source_table,
  stats.subject_column,
  stats.record_type,
  stats.model_name,
  stats.last_refresh_at,
  stats.last_lookup_at,
  stats.ready_rows,
  stats.stale_rows,
  stats.active_jobs,
  stats.completed_jobs,
  stats.last_materialized_at,
  policy.stale_policy AS effective_stale_policy
FROM otlet.semantic_indexes si
JOIN LATERAL otlet.semantic_index_stats(si.name) stats ON true
CROSS JOIN otlet.production_policy policy;

CREATE FUNCTION otlet.semantic_index_plan(
  index_name text,
  min_freshness numeric DEFAULT 1,
  allow_refresh boolean DEFAULT true
) RETURNS TABLE (
  selected_path text,
  reason text,
  effective_stale_policy text,
  name text,
  task_name text,
  source_table text,
  total_rows bigint,
  ready_rows bigint,
  stale_rows bigint,
  refresh_rows bigint,
  missing_rows bigint,
  freshness numeric,
  refresh_coverage numeric,
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
    FROM otlet.semantic_index_stats($1)
  ),
  decision AS (
    SELECT
      CASE
        WHEN total_rows = 0 THEN 'semantic_lookup'
        WHEN active_jobs > 0 THEN 'wait_for_refresh'
        WHEN refresh_rows = 0 THEN 'semantic_lookup'
        WHEN policy.stale_policy = 'lookup_only_fail_closed' THEN 'semantic_lookup'
        WHEN freshness >= GREATEST(0, LEAST(COALESCE($2, 1), 1)) THEN 'semantic_lookup'
        WHEN $3 AND refresh_rows < total_rows THEN 'refresh_then_lookup'
        ELSE 'fresh_inference_scan'
      END AS selected_path,
      CASE
        WHEN total_rows = 0 THEN 'empty source'
        WHEN active_jobs > 0 THEN 'refresh already active'
        WHEN refresh_rows = 0 THEN 'semantic index fully fresh'
        WHEN policy.stale_policy = 'lookup_only_fail_closed' THEN 'policy returns fresh lookup rows only'
        WHEN freshness >= GREATEST(0, LEAST(COALESCE($2, 1), 1)) THEN 'semantic index meets freshness threshold'
        WHEN $3 AND refresh_rows < total_rows THEN 'partial refresh cheaper than full fresh inference'
        ELSE 'fresh inference has no reusable semantic coverage'
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
    source_table,
    total_rows,
    ready_rows,
    stale_rows,
    refresh_rows,
    missing_rows,
    freshness,
    refresh_coverage,
    estimated_lookup_ms,
    estimated_refresh_ms,
    estimated_fresh_inference_ms,
    active_jobs,
    completed_jobs
  FROM decision;
$$;
