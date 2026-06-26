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
  expected jsonb
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
BEGIN
  RETURN otlet.semantic_join_matches(
    semantic_join_matches_auto.index_name,
    semantic_join_matches_auto.subject_id,
    semantic_join_matches_auto.expected
  );
END;
$$;

CREATE FUNCTION otlet.semantic_plan_from_counts(
  p_name text,
  p_task_name text,
  p_record_type text,
  p_model_name text,
  p_source_relation text,
  p_lookup_path text,
  p_empty_reason text,
  p_fresh_reason text,
  p_fail_closed_reason text,
  p_partial_refresh_reason text,
  p_full_refresh_path text,
  p_full_refresh_reason text,
  p_total_subjects bigint,
  p_fresh_subjects bigint,
  p_stale_subjects bigint,
  p_missing_subjects bigint
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
  v_total_subjects bigint := COALESCE(p_total_subjects, 0);
  v_fresh_subjects bigint := COALESCE(p_fresh_subjects, 0);
  v_stale_subjects bigint := COALESCE(p_stale_subjects, 0);
  v_missing_subjects bigint := COALESCE(p_missing_subjects, 0);
  v_refresh_subjects bigint := 0;
  v_inflight_subjects bigint := 0;
  v_worker_queue_depth bigint := 0;
  v_available_queue_slots bigint := 0;
  v_wait_subjects bigint := 0;
  v_queue_subjects bigint := 0;
  v_fail_closed_subjects bigint := 0;
  v_model_ms numeric := 2500;
  v_model_cost_source text := 'static_fallback';
  v_lookup_ms numeric := 1;
  v_queue_ms numeric := 1;
  v_path_cost numeric := 1;
  v_stale_policy text := 'lookup_only_fail_closed';
  v_selected_path text;
  v_reason text;
  v_runtime_name text := 'linked_inproc';
BEGIN
  v_refresh_subjects := v_stale_subjects + v_missing_subjects;

  SELECT count(DISTINCT j.subject_id) FILTER (WHERE j.status IN ('queued', 'running', 'cancel_requested'))
  INTO v_inflight_subjects
  FROM otlet.jobs j
  WHERE j.task_name = p_task_name;

  SELECT
    count(*) FILTER (WHERE j.status IN ('queued', 'running', 'cancel_requested'))::bigint,
    COALESCE(otlet.available_model_queue_slots(p_model_name), 0)::bigint
  INTO v_worker_queue_depth, v_available_queue_slots
  FROM otlet.tasks t
  LEFT JOIN otlet.jobs j ON j.task_name = t.name
  WHERE t.model_name = p_model_name;

  SELECT COALESCE(m.runtime_name, 'linked_inproc')
  INTO v_runtime_name
  FROM otlet.models m
  WHERE m.name = p_model_name;

  SELECT
    COALESCE(task_receipt.generate_ms, slot_cost.last_generate_ms, model_receipt.generate_ms, 2500)::numeric,
    CASE
      WHEN task_receipt.generate_ms IS NOT NULL THEN 'task_receipt'
      WHEN slot_cost.last_generate_ms IS NOT NULL THEN 'runtime_slot'
      WHEN model_receipt.generate_ms IS NOT NULL THEN 'model_receipt'
      ELSE 'static_fallback'
    END
  INTO v_model_ms, v_model_cost_source
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (
    SELECT r.generate_ms::numeric AS generate_ms
    FROM otlet.inference_receipts r
    WHERE r.task_name = p_task_name
      AND r.model_name = p_model_name
      AND r.status = 'complete'
      AND r.schema_validation_status = 'passed'
      AND COALESCE(r.generate_ms, 0) > 0
    ORDER BY r.finished_at DESC
    LIMIT 1
  ) task_receipt ON true
  LEFT JOIN LATERAL (
    SELECT rs.last_generate_ms::numeric AS last_generate_ms
    FROM otlet.runtime_slots rs
    WHERE rs.model_name = p_model_name
      AND rs.runtime_name = v_runtime_name
      AND COALESCE(rs.last_generate_ms, 0) > 0
    ORDER BY rs.last_used_at DESC NULLS LAST
    LIMIT 1
  ) slot_cost ON true
  LEFT JOIN LATERAL (
    SELECT r.generate_ms::numeric AS generate_ms
    FROM otlet.inference_receipts r
    WHERE r.model_name = p_model_name
      AND r.status = 'complete'
      AND r.schema_validation_status = 'passed'
      AND COALESCE(r.generate_ms, 0) > 0
    ORDER BY r.finished_at DESC
    LIMIT 1
  ) model_receipt ON true;

  SELECT COALESCE(policy.stale_policy, 'lookup_only_fail_closed')
  INTO v_stale_policy
  FROM otlet.production_policy policy
  LIMIT 1;

  IF v_total_subjects = 0 THEN
    v_selected_path := p_lookup_path;
    v_reason := p_empty_reason;
  ELSIF COALESCE(v_inflight_subjects, 0) > 0 THEN
    v_selected_path := 'wait_for_refresh';
    v_reason := 'refresh already active';
    v_wait_subjects := v_inflight_subjects;
  ELSIF v_refresh_subjects = 0 THEN
    v_selected_path := p_lookup_path;
    v_reason := p_fresh_reason;
  ELSIF v_stale_policy = 'lookup_only_fail_closed' THEN
    v_selected_path := 'lookup_fail_closed';
    v_reason := p_fail_closed_reason;
    v_fail_closed_subjects := v_refresh_subjects;
  ELSIF v_refresh_subjects < v_total_subjects THEN
    v_selected_path := 'queue_refresh';
    v_reason := p_partial_refresh_reason;
    v_queue_subjects := LEAST(v_refresh_subjects, COALESCE(v_available_queue_slots, 0));
  ELSE
    v_selected_path := p_full_refresh_path;
    v_reason := p_full_refresh_reason;
    v_queue_subjects := LEAST(v_refresh_subjects, COALESCE(v_available_queue_slots, 0));
  END IF;

  v_lookup_ms := round(1 + (v_fresh_subjects::numeric * 0.05), 2);
  v_queue_ms := round(v_lookup_ms + (v_refresh_subjects::numeric * COALESCE(v_model_ms, 2500)), 2);
  v_path_cost := CASE v_selected_path
    WHEN p_lookup_path THEN v_lookup_ms
    WHEN 'lookup_fail_closed' THEN v_lookup_ms
    WHEN 'wait_for_refresh' THEN round(v_lookup_ms + (v_wait_subjects::numeric * 0.50), 2)
    ELSE v_queue_ms
  END;

  RETURN QUERY SELECT
    v_selected_path,
    v_reason,
    v_stale_policy,
    p_name,
    p_task_name,
    p_record_type,
    p_model_name,
    COALESCE(v_runtime_name, 'linked_inproc'),
    p_source_relation,
    v_total_subjects,
    v_fresh_subjects,
    v_stale_subjects,
    v_missing_subjects,
    COALESCE(v_inflight_subjects, 0),
    v_fresh_subjects,
    v_wait_subjects,
    v_queue_subjects,
    0::bigint,
    v_fail_closed_subjects,
    CASE WHEN v_total_subjects = 0 THEN 1::numeric ELSE round(v_fresh_subjects::numeric / v_total_subjects, 4) END,
    round(COALESCE(v_model_ms, 2500), 2),
    COALESCE(v_model_cost_source, 'static_fallback'),
    0.05::numeric,
    v_lookup_ms,
    v_queue_ms,
    0::numeric,
    v_path_cost,
    COALESCE(v_worker_queue_depth, 0),
    COALESCE(v_available_queue_slots, 0),
    clock_timestamp();
END;
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
  index_row otlet.semantic_join_indexes%ROWTYPE;
  v_total_subjects bigint := 0;
  v_fresh_subjects bigint := 0;
  v_stale_subjects bigint := 0;
  v_missing_subjects bigint := 0;
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
  INTO v_total_subjects, v_fresh_subjects, v_stale_subjects, v_missing_subjects;

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
    v_missing_subjects
  );
END;
$$;
