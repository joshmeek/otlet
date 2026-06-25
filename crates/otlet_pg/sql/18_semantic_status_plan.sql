CREATE FUNCTION otlet.semantic_index_plan(
  index_name text
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
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  v_total_rows bigint := 0;
  v_ready_rows bigint := 0;
  v_stale_rows bigint := 0;
  v_refresh_rows bigint := 0;
  v_active_jobs bigint := 0;
  v_completed_jobs bigint := 0;
  v_materialized_at timestamptz;
  v_generate_ms numeric := 2500;
  v_stale_policy text;
  v_selected_path text;
  v_reason text;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes si
  WHERE si.name = semantic_index_plan.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', semantic_index_plan.index_name;
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
  INTO v_total_rows, v_ready_rows, v_stale_rows, v_refresh_rows, v_materialized_at;

  v_total_rows := COALESCE(v_total_rows, 0);
  v_ready_rows := COALESCE(v_ready_rows, 0);
  v_stale_rows := COALESCE(v_stale_rows, 0);
  v_refresh_rows := COALESCE(v_refresh_rows, 0);

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

  IF v_total_rows = 0 THEN
    v_selected_path := 'semantic_lookup';
    v_reason := 'empty source';
  ELSIF v_active_jobs > 0 THEN
    v_selected_path := 'wait_for_refresh';
    v_reason := 'refresh already active';
  ELSIF v_refresh_rows = 0 THEN
    v_selected_path := 'semantic_lookup';
    v_reason := 'semantic index fully fresh';
  ELSIF v_stale_policy = 'lookup_only_fail_closed' THEN
    v_selected_path := 'semantic_lookup';
    v_reason := 'policy returns fresh lookup rows only';
  ELSIF v_refresh_rows < v_total_rows THEN
    v_selected_path := 'refresh_then_lookup';
    v_reason := 'partial refresh cheaper than full fresh inference';
  ELSE
    v_selected_path := 'fresh_inference_scan';
    v_reason := 'fresh inference has no reusable semantic coverage';
  END IF;

  RETURN QUERY
  SELECT
    v_selected_path,
    v_reason,
    v_stale_policy,
    index_row.name,
    index_row.task_name,
    index_row.source_table,
    v_total_rows,
    v_ready_rows,
    v_stale_rows,
    v_refresh_rows,
    GREATEST(v_total_rows - v_ready_rows, 0),
    CASE WHEN v_total_rows = 0 THEN 1::numeric ELSE round(v_ready_rows::numeric / v_total_rows, 4) END,
    CASE WHEN v_total_rows = 0 THEN 1::numeric ELSE round(GREATEST(v_total_rows - v_refresh_rows, 0)::numeric / v_total_rows, 4) END,
    round(1 + (v_ready_rows::numeric * 0.05), 2),
    round((v_refresh_rows::numeric * v_generate_ms) + 1 + (v_total_rows::numeric * 0.05), 2),
    round(v_total_rows::numeric * v_generate_ms, 2),
    v_active_jobs,
    v_completed_jobs;
END;
$$;

CREATE OR REPLACE VIEW otlet.semantic_index_status AS
SELECT
  plan.name,
  plan.task_name,
  plan.source_table,
  si.subject_column,
  si.record_type,
  si.model_name,
  si.last_refresh_at,
  si.last_lookup_at,
  plan.ready_rows,
  plan.stale_rows,
  plan.active_jobs,
  plan.completed_jobs,
  (
    SELECT max(sm.updated_at)
    FROM otlet.semantic_materializations sm
    WHERE sm.task_name = si.task_name
      AND sm.record_type = si.record_type
  ) AS last_materialized_at,
  plan.effective_stale_policy
FROM otlet.semantic_indexes si
JOIN LATERAL otlet.semantic_index_plan(si.name) plan ON true;
