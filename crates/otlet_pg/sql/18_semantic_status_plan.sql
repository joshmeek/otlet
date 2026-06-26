CREATE FUNCTION otlet.semantic_index_plan(
  index_name text
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
  checked_at timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  v_total_subjects bigint := 0;
  v_fresh_subjects bigint := 0;
  v_stale_subjects bigint := 0;
  v_missing_subjects bigint := 0;
  v_refresh_subjects bigint := 0;
  v_inflight_subjects bigint := 0;
  v_worker_queue_depth bigint := 0;
  v_available_queue_slots bigint := 0;
  v_lookup_subjects bigint := 0;
  v_wait_subjects bigint := 0;
  v_queue_subjects bigint := 0;
  v_infer_now_subjects bigint := 0;
  v_fail_closed_subjects bigint := 0;
  v_model_ms numeric := 2500;
  v_model_cost_source text := 'static_fallback';
  v_cache_hit_ms numeric := 0.05;
  v_lookup_ms numeric := 1;
  v_queue_ms numeric := 1;
  v_infer_now_ms numeric := 0;
  v_path_cost numeric := 1;
  v_stale_policy text;
  v_selected_path text;
  v_reason text;
  v_runtime_name text;
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
        count(*) FILTER (WHERE NOT has_materialization)::bigint
      FROM classified
    $sql$,
    index_row.subject_column,
    index_row.source_table,
    index_row.source_table,
    index_row.task_name,
    index_row.record_type
  )
  INTO v_total_subjects, v_fresh_subjects, v_stale_subjects, v_missing_subjects;

  v_total_subjects := COALESCE(v_total_subjects, 0);
  v_fresh_subjects := COALESCE(v_fresh_subjects, 0);
  v_stale_subjects := COALESCE(v_stale_subjects, 0);
  v_missing_subjects := COALESCE(v_missing_subjects, 0);
  v_refresh_subjects := v_stale_subjects + v_missing_subjects;

  SELECT
    count(DISTINCT j.subject_id) FILTER (WHERE j.status IN ('queued', 'running', 'cancel_requested'))
  INTO v_inflight_subjects
  FROM otlet.jobs j
  WHERE j.task_name = index_row.task_name;

  v_inflight_subjects := COALESCE(v_inflight_subjects, 0);

  SELECT
    count(*) FILTER (WHERE j.status IN ('queued', 'running', 'cancel_requested'))::bigint,
    COALESCE(otlet.available_model_queue_slots(index_row.model_name), 0)::bigint
  INTO v_worker_queue_depth, v_available_queue_slots
  FROM otlet.tasks t
  LEFT JOIN otlet.jobs j ON j.task_name = t.name
  WHERE t.model_name = index_row.model_name;

  v_worker_queue_depth := COALESCE(v_worker_queue_depth, 0);
  v_available_queue_slots := COALESCE(v_available_queue_slots, 0);

  SELECT m.runtime_name
  INTO v_runtime_name
  FROM otlet.models m
  WHERE m.name = index_row.model_name;

  v_runtime_name := COALESCE(v_runtime_name, 'linked_inproc');

  SELECT cost.model_ms, cost.model_cost_source
  INTO v_model_ms, v_model_cost_source
  FROM (
    SELECT
      COALESCE(task_receipt.generate_ms, slot_cost.last_generate_ms, model_receipt.generate_ms, 2500)::numeric AS model_ms,
      CASE
        WHEN task_receipt.generate_ms IS NOT NULL THEN 'task_receipt'
        WHEN slot_cost.last_generate_ms IS NOT NULL THEN 'runtime_slot'
        WHEN model_receipt.generate_ms IS NOT NULL THEN 'model_receipt'
        ELSE 'static_fallback'
      END AS model_cost_source
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (
      SELECT r.generate_ms::numeric AS generate_ms
      FROM otlet.inference_receipts r
      WHERE r.task_name = index_row.task_name
        AND r.model_name = index_row.model_name
        AND r.status = 'complete'
        AND r.schema_validation_status = 'passed'
        AND COALESCE(r.generate_ms, 0) > 0
      ORDER BY r.finished_at DESC
      LIMIT 1
    ) task_receipt ON true
    LEFT JOIN LATERAL (
      SELECT rs.last_generate_ms::numeric AS last_generate_ms
      FROM otlet.runtime_slots rs
      WHERE rs.model_name = index_row.model_name
        AND rs.runtime_name = v_runtime_name
        AND COALESCE(rs.last_generate_ms, 0) > 0
      ORDER BY rs.last_used_at DESC NULLS LAST
      LIMIT 1
    ) slot_cost ON true
    LEFT JOIN LATERAL (
      SELECT r.generate_ms::numeric AS generate_ms
      FROM otlet.inference_receipts r
      WHERE r.model_name = index_row.model_name
        AND r.status = 'complete'
        AND r.schema_validation_status = 'passed'
        AND COALESCE(r.generate_ms, 0) > 0
      ORDER BY r.finished_at DESC
      LIMIT 1
    ) model_receipt ON true
  ) cost;

  v_model_ms := COALESCE(v_model_ms, 2500);
  v_model_cost_source := COALESCE(v_model_cost_source, 'static_fallback');

  SELECT policy.stale_policy
  INTO v_stale_policy
  FROM otlet.production_policy policy
  LIMIT 1;

  v_stale_policy := COALESCE(v_stale_policy, 'lookup_only_fail_closed');
  v_lookup_subjects := v_fresh_subjects;

  IF v_total_subjects = 0 THEN
    v_selected_path := 'semantic_lookup';
    v_reason := 'empty source';
  ELSIF v_inflight_subjects > 0 THEN
    v_selected_path := 'wait_for_refresh';
    v_reason := 'refresh already active';
    v_wait_subjects := v_inflight_subjects;
  ELSIF v_refresh_subjects = 0 THEN
    v_selected_path := 'semantic_lookup';
    v_reason := 'semantic index fully fresh';
  ELSIF v_stale_policy = 'lookup_only_fail_closed' THEN
    v_selected_path := 'lookup_fail_closed';
    v_reason := 'policy returns fresh lookup rows only';
    v_fail_closed_subjects := v_refresh_subjects;
  ELSIF v_refresh_subjects < v_total_subjects THEN
    v_selected_path := 'queue_refresh';
    v_reason := 'partial refresh queued before lookup';
    v_queue_subjects := LEAST(v_refresh_subjects, v_available_queue_slots);
  ELSE
    v_selected_path := 'fresh_inference_scan';
    v_reason := 'fresh inference has no reusable semantic coverage';
    v_queue_subjects := LEAST(v_refresh_subjects, v_available_queue_slots);
  END IF;

  v_lookup_ms := round(1 + (v_lookup_subjects::numeric * 0.05), 2);
  v_queue_ms := round(v_lookup_ms + (v_refresh_subjects::numeric * v_model_ms), 2);
  v_infer_now_ms := 0;
  v_path_cost := CASE v_selected_path
    WHEN 'semantic_lookup' THEN v_lookup_ms
    WHEN 'lookup_fail_closed' THEN v_lookup_ms
    WHEN 'wait_for_refresh' THEN round(v_lookup_ms + (v_wait_subjects::numeric * 0.50), 2)
    ELSE v_queue_ms
  END;

  RETURN QUERY
  SELECT
    v_selected_path,
    v_reason,
    v_stale_policy,
    index_row.name,
    index_row.task_name,
    index_row.record_type,
    index_row.model_name,
    v_runtime_name,
    index_row.source_table,
    v_total_subjects,
    v_fresh_subjects,
    v_stale_subjects,
    v_missing_subjects,
    v_inflight_subjects,
    v_lookup_subjects,
    v_wait_subjects,
    v_queue_subjects,
    v_infer_now_subjects,
    v_fail_closed_subjects,
    CASE WHEN v_total_subjects = 0 THEN 1::numeric ELSE round(v_fresh_subjects::numeric / v_total_subjects, 4) END,
    round(v_model_ms, 2),
    v_model_cost_source,
    v_cache_hit_ms,
    v_lookup_ms,
    v_queue_ms,
    v_infer_now_ms,
    v_path_cost,
    v_worker_queue_depth,
    v_available_queue_slots,
    clock_timestamp();
END;
$$;

CREATE OR REPLACE VIEW otlet.semantic_index_status AS
SELECT
  plan.name,
  plan.task_name,
  plan.source_relation,
  si.subject_column,
  si.record_type,
  si.model_name,
  plan.runtime_name,
  si.last_refresh_at,
  si.last_lookup_at,
  plan.total_subjects,
  plan.fresh_subjects,
  plan.stale_subjects,
  plan.missing_subjects,
  plan.inflight_subjects,
  plan.lookup_subjects,
  plan.wait_subjects,
  plan.queue_subjects,
  plan.infer_now_subjects,
  plan.fail_closed_subjects,
  plan.selected_path,
  plan.reason,
  plan.freshness,
  plan.model_ms,
  plan.model_cost_source,
  plan.path_cost,
  plan.worker_queue_depth,
  plan.available_queue_slots,
  (
    SELECT max(sm.updated_at)
    FROM otlet.semantic_materializations sm
    WHERE sm.task_name = si.task_name
      AND sm.record_type = si.record_type
  ) AS last_materialized_at,
  plan.effective_stale_policy,
  plan.checked_at
FROM otlet.semantic_indexes si
JOIN LATERAL otlet.semantic_index_plan(si.name) plan ON true;
