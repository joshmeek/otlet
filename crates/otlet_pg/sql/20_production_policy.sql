CREATE VIEW otlet.production_policy_status AS
SELECT
  p.name,
  p.stale_policy,
  p.max_queued_jobs_per_model,
  p.max_attempts,
  p.semantic_auto_wait_ms,
  p.semantic_auto_infer_ms,
  p.semantic_auto_max_rows,
  p.worker_claim_batch_size,
  p.worker_claim_task_cursor,
  p.job_lease_interval,
  p.worker_event_retention,
  p.trace_detail_retention,
  p.eval_label_retention
FROM otlet.production_policy p;

CREATE VIEW otlet.model_queue_status AS
SELECT
  m.runtime_name,
  m.name AS model_name,
  m.max_active_jobs,
  p.max_queued_jobs_per_model,
  count(j.id) FILTER (WHERE j.status = 'queued')::bigint AS queued_jobs,
  count(j.id) FILTER (WHERE j.status = 'running')::bigint AS running_jobs,
  count(j.id) FILTER (WHERE j.status = 'cancel_requested')::bigint AS cancel_requested_jobs,
  count(j.id) FILTER (WHERE j.status = 'running' AND j.leased_until < now())::bigint AS expired_running_jobs,
  otlet.available_model_queue_slots(m.name)::bigint AS available_queue_slots,
  CASE
    WHEN otlet.available_model_queue_slots(m.name) <= 0 THEN 'queue_full'
    ELSE 'queue_accepting'
  END AS queue_state,
  COALESCE(suppressed.suppressed_events, 0)::bigint AS queue_admission_suppressed_events,
  suppressed.last_suppressed_at AS queue_admission_last_suppressed_at
FROM otlet.models m
CROSS JOIN otlet.production_policy p
LEFT JOIN otlet.tasks t ON t.model_name = m.name
LEFT JOIN otlet.jobs j ON j.task_name = t.name
LEFT JOIN LATERAL (
  SELECT
    count(*)::bigint AS suppressed_events,
    max(e.created_at) AS last_suppressed_at
  FROM otlet.worker_events e
  WHERE e.event_type = 'queue_admission_suppressed'
    AND e.detail ->> 'model_name' = m.name
) suppressed ON true
GROUP BY
  m.runtime_name,
  m.name,
  m.max_active_jobs,
  p.max_queued_jobs_per_model,
  suppressed.suppressed_events,
  suppressed.last_suppressed_at;

CREATE VIEW otlet.worker_throughput_status AS
SELECT
  m.runtime_name,
  m.name AS model_name,
  p.worker_claim_batch_size,
  COALESCE(q.queued_jobs, 0) AS queued_jobs,
  COALESCE(q.running_jobs, 0) AS running_jobs,
  COALESCE(q.cancel_requested_jobs, 0) AS cancel_requested_jobs,
  COALESCE(q.available_queue_slots, 0) AS available_queue_slots,
  COALESCE((last_batch.detail ->> 'job_count')::bigint, 0) AS last_batch_jobs,
  COALESCE((last_batch.detail ->> 'completed_jobs')::bigint, 0) AS last_batch_completed_jobs,
  COALESCE((last_batch.detail ->> 'failed_jobs')::bigint, 0) AS last_batch_failed_jobs,
  COALESCE(last_batch.detail ->> 'task_name', '') AS last_batch_task_name,
  last_batch.created_at AS last_batch_at,
  COALESCE(recent_batches.recent_batch_tasks, '[]'::jsonb) AS recent_batch_tasks
FROM otlet.models m
CROSS JOIN otlet.production_policy p
LEFT JOIN otlet.model_queue_status q ON q.model_name = m.name
LEFT JOIN LATERAL (
  SELECT e.detail, e.created_at
  FROM otlet.worker_events e
  WHERE e.event_type = 'worker_batch_finished'
    AND e.runtime_name = m.runtime_name
    AND e.detail ->> 'model_name' = m.name
  ORDER BY e.created_at DESC, e.id DESC
  LIMIT 1
) last_batch ON true
LEFT JOIN LATERAL (
  SELECT jsonb_agg(
           jsonb_build_object(
             'task_name', recent.task_name,
             'job_count', recent.job_count,
             'completed_jobs', recent.completed_jobs,
             'failed_jobs', recent.failed_jobs
           )
           ORDER BY recent.created_at DESC, recent.id DESC
         ) AS recent_batch_tasks
  FROM (
    SELECT
      e.id,
      e.created_at,
      COALESCE(e.detail ->> 'task_name', '') AS task_name,
      COALESCE((e.detail ->> 'job_count')::bigint, 0) AS job_count,
      COALESCE((e.detail ->> 'completed_jobs')::bigint, 0) AS completed_jobs,
      COALESCE((e.detail ->> 'failed_jobs')::bigint, 0) AS failed_jobs
    FROM otlet.worker_events e
    WHERE e.event_type = 'worker_batch_finished'
      AND e.runtime_name = m.runtime_name
      AND e.detail ->> 'model_name' = m.name
    ORDER BY e.created_at DESC, e.id DESC
    LIMIT 16
  ) recent
) recent_batches ON true
GROUP BY
  m.runtime_name,
  m.name,
  p.worker_claim_batch_size,
  q.queued_jobs,
  q.running_jobs,
  q.cancel_requested_jobs,
  q.available_queue_slots,
  last_batch.detail,
  last_batch.created_at,
  recent_batches.recent_batch_tasks;

CREATE VIEW otlet.model_selection_policy_status AS
SELECT
  p.task_name,
  p.cheap_model_name,
  p.strong_model_name,
  p.accept_field_checks,
  p.cheap_skip_window,
  p.cheap_min_recent_acceptance,
  p.cheap_probe_interval,
  cheap_q.queue_state AS cheap_queue_state,
  cheap_q.queued_jobs AS cheap_queued_jobs,
  cheap_q.running_jobs AS cheap_running_jobs,
  p.created_at,
  p.updated_at
FROM otlet.model_selection_policies p
LEFT JOIN otlet.model_queue_status cheap_q ON cheap_q.model_name = p.cheap_model_name;

CREATE FUNCTION otlet.model_selection_recent_acceptance(task_name text)
RETURNS TABLE (
  cheap_skip_window integer,
  cheap_min_recent_acceptance double precision,
  cheap_probe_interval integer,
  recent_attempts bigint,
  recent_accepted bigint,
  recent_acceptance double precision,
  skipped_since_last_cheap bigint,
  skip_cheap boolean,
  probe_due boolean
)
LANGUAGE sql
STABLE
AS $$
WITH policy AS (
  SELECT *
  FROM otlet.model_selection_policies p
  WHERE p.task_name = model_selection_recent_acceptance.task_name
), recent AS (
  SELECT ranked.selection_status
  FROM (
    SELECT
      r.selection_status,
      p.cheap_skip_window,
      row_number() OVER (ORDER BY r.finished_at DESC, r.id DESC) AS row_number
    FROM otlet.inference_receipts r
    JOIN policy p ON true
    WHERE r.task_name = p.task_name
      AND r.model_name = p.cheap_model_name
      AND r.selection_role = 'cheap'
  ) ranked
  WHERE ranked.row_number <= ranked.cheap_skip_window
), counts AS (
  SELECT
    count(*)::bigint AS recent_attempts,
    count(*) FILTER (WHERE selection_status = 'accepted')::bigint AS recent_accepted
  FROM recent
), latest_cheap AS (
  SELECT COALESCE(max(r.id), 0) AS latest_cheap_receipt_id
  FROM policy p
  LEFT JOIN otlet.inference_receipts r
    ON r.task_name = p.task_name
   AND r.model_name = p.cheap_model_name
   AND r.selection_role = 'cheap'
), skipped AS (
  SELECT count(r.id)::bigint AS skipped_since_last_cheap
  FROM policy p
  CROSS JOIN latest_cheap latest
  LEFT JOIN otlet.inference_receipts r
    ON r.task_name = p.task_name
   AND r.model_name = p.strong_model_name
   AND r.selection_role = 'strong'
   AND r.selection_reason = 'cheap_skipped_low_recent_acceptance'
   AND r.id > latest.latest_cheap_receipt_id
), decision AS (
  SELECT
    p.cheap_skip_window,
    p.cheap_min_recent_acceptance,
    p.cheap_probe_interval,
    COALESCE(c.recent_attempts, 0) AS recent_attempts,
    COALESCE(c.recent_accepted, 0) AS recent_accepted,
    CASE
      WHEN COALESCE(c.recent_attempts, 0) = 0 THEN 0::double precision
      ELSE COALESCE(c.recent_accepted, 0)::double precision / c.recent_attempts::double precision
    END AS recent_acceptance,
    COALESCE(s.skipped_since_last_cheap, 0) AS skipped_since_last_cheap
  FROM policy p
  CROSS JOIN counts c
  CROSS JOIN skipped s
)
SELECT
  d.cheap_skip_window,
  d.cheap_min_recent_acceptance,
  d.cheap_probe_interval,
  d.recent_attempts,
  d.recent_accepted,
  d.recent_acceptance,
  d.skipped_since_last_cheap,
  (
    d.cheap_skip_window > 0
    AND d.cheap_min_recent_acceptance > 0
    AND d.recent_attempts >= d.cheap_skip_window
    AND d.recent_acceptance < d.cheap_min_recent_acceptance
    AND NOT (
      d.cheap_probe_interval > 0
      AND d.skipped_since_last_cheap + 1 >= d.cheap_probe_interval
    )
  ) AS skip_cheap,
  (
    d.cheap_skip_window > 0
    AND d.cheap_min_recent_acceptance > 0
    AND d.recent_attempts >= d.cheap_skip_window
    AND d.recent_acceptance < d.cheap_min_recent_acceptance
    AND d.cheap_probe_interval > 0
    AND d.skipped_since_last_cheap + 1 >= d.cheap_probe_interval
  ) AS probe_due
FROM decision d;
$$;

CREATE VIEW otlet.model_selection_status AS
SELECT
  p.task_name,
  p.cheap_skip_window,
  p.cheap_min_recent_acceptance,
  p.cheap_probe_interval,
  COALESCE(recent.recent_attempts, 0)::bigint AS cheap_recent_attempts,
  COALESCE(recent.recent_accepted, 0)::bigint AS cheap_recent_accepted,
  COALESCE(recent.recent_acceptance, 0)::double precision AS cheap_recent_acceptance,
  COALESCE(recent.skip_cheap, false) AS cheap_skip_recommended,
  COALESCE(recent.probe_due, false) AS cheap_probe_due,
  count(DISTINCT j.id)::bigint AS total_jobs,
  count(DISTINCT j.id) FILTER (WHERE j.status = 'complete')::bigint AS complete_jobs,
  count(DISTINCT j.id) FILTER (WHERE j.status = 'failed')::bigint AS failed_jobs,
  count(r.id) FILTER (WHERE r.selection_role = 'cheap')::bigint AS cheap_attempts,
  count(r.id) FILTER (WHERE r.selection_role = 'cheap' AND r.selection_status = 'accepted')::bigint AS cheap_accepted,
  count(r.id) FILTER (WHERE r.selection_role = 'cheap' AND r.selection_status = 'rejected')::bigint AS cheap_rejected,
  count(r.id) FILTER (WHERE r.selection_role = 'cheap' AND r.schema_validation_status = 'failed')::bigint AS cheap_schema_failed,
  count(r.id) FILTER (WHERE r.selection_role = 'cheap' AND r.selection_reason = 'cheap_probe_recent_acceptance')::bigint AS cheap_probe_attempts,
  count(r.id) FILTER (WHERE r.selection_role = 'strong')::bigint AS strong_attempts,
  count(r.id) FILTER (WHERE r.selection_role = 'strong' AND r.selection_status = 'accepted')::bigint AS strong_accepted,
  count(r.id) FILTER (WHERE r.selection_role = 'strong' AND r.selection_status = 'failed')::bigint AS strong_failed,
  count(r.id) FILTER (WHERE r.selection_role = 'strong' AND r.selection_reason = 'cheap_skipped_low_recent_acceptance')::bigint AS cheap_skipped,
  count(DISTINCT r.job_id) FILTER (WHERE r.selection_role = 'strong')::bigint AS escalated_jobs
FROM otlet.model_selection_policies p
LEFT JOIN LATERAL otlet.model_selection_recent_acceptance(p.task_name) recent ON true
LEFT JOIN otlet.jobs j ON j.task_name = p.task_name
LEFT JOIN otlet.inference_receipts r ON r.job_id = j.id
GROUP BY
  p.task_name,
  p.cheap_skip_window,
  p.cheap_min_recent_acceptance,
  p.cheap_probe_interval,
  recent.recent_attempts,
  recent.recent_accepted,
  recent.recent_acceptance,
  recent.skip_cheap,
  recent.probe_due;

CREATE VIEW otlet.production_status AS
WITH queue AS (
  SELECT
    count(*) FILTER (WHERE status = 'queued')::bigint AS queued_jobs,
    count(*) FILTER (WHERE status = 'running')::bigint AS running_jobs,
    count(*) FILTER (WHERE status = 'cancel_requested')::bigint AS cancel_requested_jobs,
    count(*) FILTER (WHERE status = 'running' AND leased_until < now())::bigint AS expired_running_jobs,
    count(*) FILTER (WHERE status = 'failed')::bigint AS failed_jobs,
    count(*) FILTER (WHERE status = 'canceled')::bigint AS canceled_jobs
  FROM otlet.jobs
),
receipts AS (
  SELECT
    count(*)::bigint AS receipt_count,
    count(*) FILTER (WHERE status = 'failed')::bigint AS failed_receipts,
    count(*) FILTER (WHERE schema_validation_status = 'passed')::bigint AS schema_passed_receipts,
    count(*) FILTER (WHERE schema_validation_status = 'failed')::bigint AS schema_failed_receipts,
    count(*) FILTER (WHERE schema_validation_status IS DISTINCT FROM 'passed' AND status = 'complete')::bigint AS complete_without_schema_pass
  FROM otlet.inference_receipts
),
semantic_state AS (
  SELECT
    count(*)::bigint AS materialization_count,
    count(*) FILTER (WHERE stale)::bigint AS stale_materializations,
    count(*) FILTER (WHERE NOT stale)::bigint AS fresh_materializations,
    count(*) FILTER (WHERE source_hash IS NULL)::bigint AS materializations_without_source_hash
  FROM otlet.semantic_materializations
),
runtime AS (
  SELECT
    count(*) FILTER (WHERE runtime_status = 'ready' AND slot_state = 'ready')::bigint AS ready_runtime_slots,
    count(*) FILTER (WHERE runtime_status = 'error' OR slot_state = 'error')::bigint AS error_runtime_slots,
    bool_and(COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0)) AS cache_entries_within_cap,
    bool_and(COALESCE(inference_cache_bytes, 0) <= COALESCE(inference_cache_max_bytes, 0)) AS cache_bytes_within_cap
  FROM otlet.runtime_status
),
trace AS (
  SELECT
    receipt_count AS trace_receipt_count,
    detailed_trace_receipts,
    max_detailed_trace_tokens,
    max_detailed_trace_top_k
  FROM otlet.inference_visibility_status
)
SELECT
  p.name AS policy_name,
  p.stale_policy,
  p.max_queued_jobs_per_model,
  p.max_attempts,
  p.semantic_auto_wait_ms,
  p.semantic_auto_infer_ms,
  p.semantic_auto_max_rows,
  p.worker_claim_batch_size,
  p.job_lease_interval,
  q.queued_jobs,
  q.running_jobs,
  q.cancel_requested_jobs,
  q.expired_running_jobs,
  q.failed_jobs,
  q.canceled_jobs,
  r.receipt_count,
  r.failed_receipts,
  r.schema_passed_receipts,
  r.schema_failed_receipts,
  r.complete_without_schema_pass,
  s.materialization_count,
  s.fresh_materializations,
  s.stale_materializations,
  s.materializations_without_source_hash,
  runtime.ready_runtime_slots,
  runtime.error_runtime_slots,
  COALESCE(runtime.cache_entries_within_cap, true) AS cache_entries_within_cap,
  COALESCE(runtime.cache_bytes_within_cap, true) AS cache_bytes_within_cap,
  trace.trace_receipt_count,
  trace.detailed_trace_receipts,
  trace.max_detailed_trace_tokens,
  trace.max_detailed_trace_top_k,
  (q.expired_running_jobs = 0) AS no_expired_running_jobs,
  (r.complete_without_schema_pass = 0) AS completed_jobs_are_schema_validated,
  (s.materializations_without_source_hash = 0) AS materializations_have_source_hashes,
  (COALESCE(runtime.error_runtime_slots, 0) = 0) AS no_runtime_slot_errors,
  (COALESCE(runtime.cache_entries_within_cap, true) AND COALESCE(runtime.cache_bytes_within_cap, true)) AS cache_within_bounds,
  (COALESCE(trace.max_detailed_trace_tokens, 0) <= 256 AND COALESCE(trace.max_detailed_trace_top_k, 0) <= 16) AS trace_within_bounds,
  now() AS checked_at
FROM otlet.production_policy p
CROSS JOIN queue q
CROSS JOIN receipts r
CROSS JOIN semantic_state s
CROSS JOIN runtime
CROSS JOIN trace;

CREATE FUNCTION otlet.cleanup_policy_state(
  requested_dry_run boolean DEFAULT true
) RETURNS TABLE (
  worker_events bigint,
  token_trace_rows bigint,
  token_alternative_rows bigint,
  eval_labels bigint,
  dry_run boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
  worker_retention interval;
  trace_retention interval;
  eval_retention interval;
  worker_count bigint := 0;
  token_count bigint := 0;
  alternative_count bigint := 0;
  eval_count bigint := 0;
BEGIN
  SELECT worker_event_retention, trace_detail_retention, eval_label_retention
  INTO worker_retention, trace_retention, eval_retention
  FROM otlet.production_policy;

  SELECT count(*)
  INTO worker_count
  FROM otlet.worker_events e
  WHERE e.created_at < now() - worker_retention
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.jobs j
      WHERE j.id = e.job_id
        AND j.status IN ('queued', 'running', 'cancel_requested')
    );

  WITH candidates AS (
    SELECT r.trace_summary #> '{detailed_trace,steps}' AS steps
    FROM otlet.inference_receipts r
    WHERE r.finished_at < now() - trace_retention
      AND jsonb_typeof(r.trace_summary #> '{detailed_trace,steps}') = 'array'
      AND jsonb_array_length(r.trace_summary #> '{detailed_trace,steps}') > 0
  )
  SELECT
    COALESCE(sum(jsonb_array_length(c.steps)), 0)::bigint,
    COALESCE(sum((
      SELECT count(*)::bigint
      FROM jsonb_array_elements(c.steps) step(value)
      CROSS JOIN LATERAL jsonb_array_elements(
        CASE
          WHEN jsonb_typeof(step.value -> 'top_alternatives') = 'array'
            THEN step.value -> 'top_alternatives'
          ELSE '[]'::jsonb
        END
      ) alt(value)
    )), 0)::bigint
  INTO token_count, alternative_count
  FROM candidates c;

  SELECT count(*)
  INTO eval_count
  FROM otlet.eval_labels l
  WHERE l.created_at < now() - eval_retention;

  IF NOT cleanup_policy_state.requested_dry_run THEN
    DELETE FROM otlet.worker_events e
    WHERE e.created_at < now() - worker_retention
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.jobs j
        WHERE j.id = e.job_id
          AND j.status IN ('queued', 'running', 'cancel_requested')
      );

    UPDATE otlet.inference_receipts r
    SET trace_summary = jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(r.trace_summary, '{detailed_trace,steps}', '[]'::jsonb, true),
          '{detailed_trace,chosen_token_ids}',
          '[]'::jsonb,
          true
        ),
        '{detailed_trace,status}',
        '"pruned"'::jsonb,
        true
      ),
      '{detailed_trace,pruned_at}',
      to_jsonb(clock_timestamp()),
      true
    )
    WHERE r.finished_at < now() - trace_retention
      AND jsonb_typeof(r.trace_summary #> '{detailed_trace,steps}') = 'array'
      AND jsonb_array_length(r.trace_summary #> '{detailed_trace,steps}') > 0;

    DELETE FROM otlet.eval_labels l
    WHERE l.created_at < now() - eval_retention;
  END IF;

  RETURN QUERY SELECT worker_count, token_count, alternative_count, eval_count, cleanup_policy_state.requested_dry_run;
END;
$$;
