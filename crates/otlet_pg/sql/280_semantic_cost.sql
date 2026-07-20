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
  p_missing_subjects bigint,
  p_stale_reasons jsonb DEFAULT '{}'::jsonb,
  p_count_basis text DEFAULT 'exact'
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
  v_infer_now_subjects bigint := 0;
  v_fail_closed_subjects bigint := 0;
  v_remaining_refresh_subjects bigint := 0;
  v_model_ms numeric := 2500;
  v_model_cost_source text := 'static_fallback';
  v_lookup_ms numeric := 1;
  v_queue_ms numeric := 1;
  v_infer_now_ms numeric := 0;
  v_path_cost numeric := 1;
  v_stale_policy text := 'lookup_only_fail_closed';
  v_auto_wait_ms integer := 10000;
  v_auto_infer_ms integer := 15000;
  v_auto_max_rows integer := 1;
  v_selected_path text;
  v_reason text;
  v_runtime_name text := 'linked_inproc';
  v_stale_reasons jsonb := COALESCE(p_stale_reasons, '{}'::jsonb);
BEGIN
  v_refresh_subjects := v_stale_subjects + v_missing_subjects;

  SELECT
    count(DISTINCT j.subject_id) FILTER (
      WHERE j.task_name = p_task_name
    )::bigint,
    count(j.id)::bigint,
    COALESCE(otlet.available_model_queue_slots(p_model_name), 0)::bigint
  INTO v_inflight_subjects, v_worker_queue_depth, v_available_queue_slots
  FROM otlet.tasks t
  LEFT JOIN otlet.jobs j
    ON j.task_name = t.name
   AND j.status IN ('queued', 'running', 'cancel_requested')
  WHERE t.model_name = p_model_name;

  SELECT
    COALESCE(task_cost.generate_ms, slot_cost.last_generate_ms, model_cost.generate_ms, 2500)::numeric,
    CASE
      WHEN task_cost.generate_ms IS NOT NULL THEN 'task_receipt'
      WHEN slot_cost.last_generate_ms IS NOT NULL THEN 'runtime_slot'
      WHEN model_cost.generate_ms IS NOT NULL THEN 'model_receipt'
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
  ) task_cost ON true
  LEFT JOIN LATERAL (
    SELECT rs.last_generate_ms::numeric AS last_generate_ms
    FROM otlet.runtime_slots rs
    WHERE task_cost.generate_ms IS NULL
      AND rs.model_name = p_model_name
      AND COALESCE(rs.last_generate_ms, 0) > 0
    ORDER BY rs.last_used_at DESC NULLS LAST
    LIMIT 1
  ) slot_cost ON true
  LEFT JOIN LATERAL (
    SELECT r.generate_ms::numeric AS generate_ms
    FROM otlet.inference_receipts r
    WHERE task_cost.generate_ms IS NULL
      AND slot_cost.last_generate_ms IS NULL
      AND r.model_name = p_model_name
      AND r.status = 'complete'
      AND r.schema_validation_status = 'passed'
      AND COALESCE(r.generate_ms, 0) > 0
    ORDER BY r.finished_at DESC
    LIMIT 1
  ) model_cost ON true;

  SELECT
    COALESCE(policy.stale_policy, 'lookup_only_fail_closed'),
    COALESCE(policy.semantic_auto_wait_ms, 10000),
    COALESCE(policy.semantic_auto_infer_ms, 15000),
    COALESCE(policy.semantic_auto_max_rows, 1)
  INTO v_stale_policy, v_auto_wait_ms, v_auto_infer_ms, v_auto_max_rows
  FROM otlet.production_policy policy
  WHERE policy.name = 'default';

  IF COALESCE(v_auto_infer_ms, 0) > 0 AND COALESCE(v_auto_max_rows, 0) > 0 THEN
    v_infer_now_subjects := LEAST(v_refresh_subjects, v_auto_max_rows::bigint);
  END IF;

  IF COALESCE(v_auto_wait_ms, 0) > 0 THEN
    v_wait_subjects := COALESCE(v_inflight_subjects, 0);
  END IF;

  v_remaining_refresh_subjects := GREATEST(v_refresh_subjects - v_infer_now_subjects, 0);

  IF v_stale_policy = 'refresh_then_fail_closed' THEN
    v_queue_subjects := LEAST(v_remaining_refresh_subjects, COALESCE(v_available_queue_slots, 0));
  END IF;

  v_fail_closed_subjects := GREATEST(
    v_refresh_subjects + COALESCE(v_inflight_subjects, 0) - v_wait_subjects - v_infer_now_subjects - v_queue_subjects,
    0
  );

  IF v_total_subjects = 0 THEN
    v_selected_path := p_lookup_path;
    v_reason := p_empty_reason;
  ELSIF v_infer_now_subjects > 0 THEN
    v_selected_path := 'bounded_infer_now';
    v_reason := format(
      'auto semantic policy: fresh=%s wait=%s infer=%s queue=%s fail_closed=%s',
      v_fresh_subjects,
      v_wait_subjects,
      v_infer_now_subjects,
      v_queue_subjects,
      v_fail_closed_subjects
    );
  ELSIF v_wait_subjects > 0 THEN
    v_selected_path := 'wait_for_refresh';
    v_reason := 'refresh already active';
  ELSIF v_refresh_subjects = 0 THEN
    v_selected_path := p_lookup_path;
    v_reason := p_fresh_reason;
  ELSIF v_stale_policy = 'lookup_only_fail_closed' THEN
    v_selected_path := 'lookup_fail_closed';
    v_reason := p_fail_closed_reason;
  ELSIF v_queue_subjects > 0 AND v_refresh_subjects < v_total_subjects THEN
    v_selected_path := 'queue_refresh';
    v_reason := p_partial_refresh_reason;
  ELSIF v_queue_subjects > 0 THEN
    v_selected_path := p_full_refresh_path;
    v_reason := p_full_refresh_reason;
  ELSE
    v_selected_path := 'lookup_fail_closed';
    v_reason := p_fail_closed_reason;
  END IF;

  v_lookup_ms := round(1 + (v_fresh_subjects::numeric * 0.05), 2);
  v_queue_ms := round(v_lookup_ms + (v_refresh_subjects::numeric * COALESCE(v_model_ms, 2500)), 2);
  v_infer_now_ms := round(v_infer_now_subjects::numeric * COALESCE(v_model_ms, 2500), 2);
  v_path_cost := CASE v_selected_path
    WHEN p_lookup_path THEN v_lookup_ms
    WHEN 'lookup_fail_closed' THEN v_lookup_ms
    WHEN 'wait_for_refresh' THEN round(v_lookup_ms + (v_wait_subjects::numeric * 0.50), 2)
    WHEN 'bounded_infer_now' THEN round(v_lookup_ms + v_infer_now_ms, 2)
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
    v_infer_now_subjects,
    v_fail_closed_subjects,
    CASE WHEN v_total_subjects = 0 THEN 1::numeric ELSE round(v_fresh_subjects::numeric / v_total_subjects, 4) END,
    round(COALESCE(v_model_ms, 2500), 2),
    COALESCE(v_model_cost_source, 'static_fallback'),
    0.05::numeric,
    v_lookup_ms,
    v_queue_ms,
    v_infer_now_ms,
    v_path_cost,
    COALESCE(v_worker_queue_depth, 0),
    COALESCE(v_available_queue_slots, 0),
    v_stale_reasons,
    COALESCE(NULLIF(p_count_basis, ''), 'exact'),
    clock_timestamp();
END;
$$;

