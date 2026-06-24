
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
  stats.last_materialized_at
FROM otlet.semantic_indexes si
JOIN LATERAL otlet.semantic_index_stats(si.name) stats ON true;

CREATE FUNCTION otlet.semantic_index_plan(
  index_name text,
  min_freshness numeric DEFAULT 1,
  allow_refresh boolean DEFAULT true
) RETURNS TABLE (
  selected_path text,
  reason text,
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
        WHEN freshness >= GREATEST(0, LEAST(COALESCE($2, 1), 1)) THEN 'semantic_lookup'
        WHEN $3 AND refresh_rows < total_rows THEN 'refresh_then_lookup'
        ELSE 'fresh_inference_scan'
      END AS selected_path,
      CASE
        WHEN total_rows = 0 THEN 'empty source'
        WHEN active_jobs > 0 THEN 'refresh already active'
        WHEN refresh_rows = 0 THEN 'semantic index fully fresh'
        WHEN freshness >= GREATEST(0, LEAST(COALESCE($2, 1), 1)) THEN 'semantic index meets freshness threshold'
        WHEN $3 AND refresh_rows < total_rows THEN 'partial refresh cheaper than full fresh inference'
        ELSE 'fresh inference has no reusable semantic coverage'
      END AS reason,
      stats.*
    FROM stats
  )
  SELECT
    selected_path,
    reason,
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

CREATE VIEW otlet.model_access_status AS
SELECT
  p.name AS index_name,
  p.task_name,
  p.source_table,
  si.model_name,
  p.selected_path,
  p.reason,
  p.total_rows,
  p.ready_rows,
  p.stale_rows,
  p.refresh_rows,
  p.freshness,
  p.refresh_coverage,
  p.active_jobs,
  p.completed_jobs,
  p.estimated_lookup_ms,
  p.estimated_refresh_ms,
  p.estimated_fresh_inference_ms,
  format('otlet.%I', otlet.semantic_native_table_name(si.name)) AS default_native_foreign_table,
  format('otlet.%I', otlet.semantic_source_view_name(si.name)) AS default_source_view,
  to_regclass(format('otlet.%I', otlet.semantic_source_view_name(si.name))) IS NOT NULL AS default_source_view_exists,
  COALESCE(native_tables.tables, ARRAY[]::text[]) AS native_foreign_tables,
  'Foreign Scan via otlet_semantic_fdw plus Custom Scan via set_rel_pathlist_hook'::text AS native_node,
  'fdw_pushdown_subject_body_stale_source_hash'::text AS native_pushdown,
  'installed_semantic_matches'::text AS planner_hook_status,
  'selected_for_semantic_matches'::text AS custom_path_status,
  'fail_closed_zero_subject_rows_until_worker_refresh_commits'::text AS stale_result_policy,
  'shared_memory_xact_commit_latch'::text AS worker_handoff,
  rs.runtime_name,
  rs.runtime_status,
  rs.slot_state,
  rs.artifact_path,
  rs.artifact_bytes,
  rs.model_memory_bytes,
  rs.model_parameters,
  rs.context_window_tokens,
  rs.model_device_policy,
  rs.resident_memory_tracked_bytes,
  rs.memory_accounting_policy,
  rs.worker_process_rss_bytes,
  rs.worker_process_virtual_bytes,
  rs.worker_memory_sample_policy,
  rs.model_residency_policy,
  rs.loaded_at,
  rs.last_used_at,
  rs.last_generate_ms,
  rs.tokens_per_second,
  rs.inference_cache_hits,
  rs.inference_cache_misses,
  rs.inference_cache_entries,
  rs.inference_cache_bytes,
  rs.inference_cache_max_entries,
  rs.inference_cache_max_bytes,
  rs.inference_cache_evictions,
  rs.inference_cache_last_reason,
  rs.infer_now_state,
  rs.infer_now_slot_count,
  rs.infer_now_available_slots,
  rs.infer_now_queue_depth,
  rs.infer_now_requested_slots,
  rs.infer_now_running_slots,
  rs.infer_now_busy_rejections,
  rs.infer_now_timeouts,
  rs.infer_now_task_cap_bytes,
  rs.infer_now_task_bytes,
  rs.infer_now_subject_cap_bytes,
  rs.infer_now_subject_bytes,
  rs.infer_now_input_cap_bytes,
  rs.infer_now_input_bytes,
  rs.infer_now_error_cap_bytes,
  rs.infer_now_error_bytes,
  rs.infer_now_max_wait_ms,
  rs.infer_now_last_elapsed_ms,
  otlet.worker_wake_state() AS worker_wake_state
FROM otlet.semantic_indexes si
JOIN otlet.models m ON m.name = si.model_name
CROSS JOIN LATERAL otlet.semantic_index_plan(si.name) p
LEFT JOIN LATERAL (
  SELECT array_agg(format('%I.%I', ns.nspname, c.relname) ORDER BY ns.nspname, c.relname) AS tables
  FROM pg_foreign_table ft
  JOIN pg_class c ON c.oid = ft.ftrelid
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  WHERE ft.ftoptions @> ARRAY['index_name=' || si.name]
) native_tables ON true
LEFT JOIN otlet.runtime_status rs
  ON rs.model_name = si.model_name
 AND rs.runtime_name = m.runtime_name;

CREATE FUNCTION otlet.explain_semantic_index_plan(
  index_name text,
  min_freshness numeric DEFAULT 1,
  allow_refresh boolean DEFAULT true
) RETURNS TABLE (
  step_order int,
  node text,
  detail jsonb
)
LANGUAGE sql
AS $$
  WITH plan AS (
    SELECT *
    FROM otlet.semantic_index_plan($1, $2, $3)
  ), status AS (
    SELECT *
    FROM otlet.model_access_status
    WHERE index_name = $1
  )
  SELECT *
  FROM (
    SELECT
      1,
      'SemanticIndexStats',
      jsonb_build_object(
        'index_name', name,
        'source_table', source_table,
        'total_rows', total_rows,
        'ready_rows', ready_rows,
        'stale_rows', stale_rows,
        'refresh_rows', refresh_rows,
        'missing_rows', missing_rows,
        'freshness', freshness,
        'refresh_coverage', refresh_coverage
      )
    FROM plan
    UNION ALL
    SELECT
      2,
      'SemanticIndexCost',
      jsonb_build_object(
        'lookup_ms', estimated_lookup_ms,
        'refresh_then_lookup_ms', estimated_refresh_ms,
        'fresh_inference_ms', estimated_fresh_inference_ms
      )
    FROM plan
    UNION ALL
    SELECT
      3,
      'SemanticPathDecision',
      jsonb_build_object(
        'selected_path', selected_path,
        'reason', reason,
        'min_freshness', GREATEST(0, LEAST(COALESCE($2, 1), 1)),
        'allow_refresh', $3
      )
    FROM plan
    UNION ALL
    SELECT
      4,
      'ExecutorBoundary',
      jsonb_build_object(
        'selected_node', native_node,
        'default_source_view', default_source_view,
        'default_source_view_exists', default_source_view_exists,
        'native_pushdown', native_pushdown,
        'planner_hook_status', planner_hook_status,
        'custom_path_status', custom_path_status,
        'stale_result_policy', stale_result_policy,
        'worker_handoff', worker_handoff
      )
    FROM status
    UNION ALL
    SELECT
      5,
      'WorkerScheduling',
      jsonb_build_object(
        'scheduler_status_rows', (
          SELECT count(*)
          FROM otlet.worker_scheduler_status w
          WHERE w.model_name = s.model_name
        ),
        'infer_now_state', infer_now_state,
        'infer_now_slot_count', infer_now_slot_count,
        'infer_now_available_slots', infer_now_available_slots,
        'infer_now_queue_depth', infer_now_queue_depth,
        'infer_now_busy_rejections', infer_now_busy_rejections,
        'infer_now_timeouts', infer_now_timeouts,
        'state', worker_wake_state
      )
    FROM status s
  ) explained(step_order, node, detail)
  ORDER BY step_order;
$$;

CREATE FUNCTION otlet.semantic_index_scan(
  index_name text,
  min_freshness numeric DEFAULT 1,
  allow_refresh boolean DEFAULT true
) RETURNS TABLE (
  subject_id text,
  body jsonb,
  stale boolean,
  source_hash text,
  updated_at timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
  plan_row record;
  queued_jobs bigint;
BEGIN
  SELECT *
  INTO plan_row
  FROM otlet.semantic_index_plan(
    semantic_index_scan.index_name,
    semantic_index_scan.min_freshness,
    semantic_index_scan.allow_refresh
  );

  queued_jobs := 0;

  IF plan_row.selected_path = 'refresh_then_lookup' THEN
    SELECT otlet.refresh_semantic_index(semantic_index_scan.index_name) INTO queued_jobs;
  ELSIF plan_row.selected_path = 'fresh_inference_scan' THEN
    SELECT count(*) INTO queued_jobs
    FROM otlet.inference_scan(plan_row.task_name);
  END IF;

  IF queued_jobs > 0 OR plan_row.selected_path = 'wait_for_refresh' THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    lookup.subject_id,
    lookup.body,
    lookup.stale,
    lookup.source_hash,
    lookup.updated_at
  FROM otlet.semantic_index_lookup(semantic_index_scan.index_name, true) lookup;
END;
$$;
