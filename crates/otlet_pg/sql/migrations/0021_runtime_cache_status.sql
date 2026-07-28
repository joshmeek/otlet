CREATE VIEW otlet.runtime_stage_timing_status AS
WITH attempt_timing AS (
  SELECT
    s.job_id,
    count(*)::bigint AS model_attempts,
    max(s.receipt_finished_at) AS last_receipt_finished_at,
    bool_or(s.inference_cache_hit) AS inference_cache_hit,
    array_agg(DISTINCT s.model_name ORDER BY s.model_name) AS model_names,
    COALESCE(sum(s.runtime_prepare_ms), 0)::bigint AS runtime_prepare_ms,
    COALESCE(sum(s.model_load_ms), 0)::bigint AS model_load_ms,
    COALESCE(sum(s.model_context_ms), 0)::bigint AS model_context_ms,
    COALESCE(sum(s.tokenize_ms), 0)::bigint AS tokenize_ms,
    COALESCE(sum(s.prompt_decode_ms), 0)::bigint AS prompt_decode_ms,
    COALESCE(sum(s.generate_ms), 0)::bigint AS generate_ms,
    COALESCE(sum(s.postprocess_ms), 0)::bigint AS postprocess_ms,
    COALESCE(sum(s.finish_sql_ms), 0)::bigint AS finish_sql_ms,
    COALESCE(sum(s.materialize_ms), 0)::bigint AS materialize_ms
  FROM otlet.inference_receipt_trace_status s
  GROUP BY s.job_id
),
stage_totals AS (
  SELECT
    j.id AS job_id,
    j.task_name,
    j.subject_id,
    j.status,
    j.attempts AS claim_attempts,
    COALESCE(a.model_attempts, 0)::bigint AS model_attempts,
    COALESCE(a.model_names, ARRAY[]::text[]) AS model_names,
    COALESCE(a.inference_cache_hit, false) AS inference_cache_hit,
    j.created_at,
    j.started_at,
    j.finished_at,
    a.last_receipt_finished_at,
    CASE
      WHEN j.started_at IS NULL THEN NULL
      ELSE GREATEST(
        0,
        CEIL(EXTRACT(epoch FROM (j.started_at - j.created_at)) * 1000)::bigint
      )
    END AS queue_wait_ms,
    CASE
      WHEN j.started_at IS NULL
        OR COALESCE(a.last_receipt_finished_at, j.finished_at) IS NULL
        THEN NULL
      ELSE GREATEST(
        0,
        CEIL(EXTRACT(
          epoch FROM (COALESCE(a.last_receipt_finished_at, j.finished_at) - j.started_at)
        ) * 1000)::bigint
      ) + COALESCE(a.finish_sql_ms, 0) + COALESCE(a.materialize_ms, 0)
    END AS observed_worker_ms,
    COALESCE(a.runtime_prepare_ms, 0) AS runtime_prepare_ms,
    COALESCE(a.model_load_ms, 0) AS model_load_ms,
    COALESCE(a.model_context_ms, 0) AS model_context_ms,
    COALESCE(a.tokenize_ms, 0) AS tokenize_ms,
    COALESCE(a.prompt_decode_ms, 0) AS prompt_decode_ms,
    COALESCE(a.generate_ms, 0) AS generate_ms,
    COALESCE(a.postprocess_ms, 0) AS postprocess_ms,
    COALESCE(a.finish_sql_ms, 0) AS finish_sql_ms,
    COALESCE(a.materialize_ms, 0) AS materialize_ms,
    COALESCE(a.runtime_prepare_ms, 0)
      + COALESCE(a.model_load_ms, 0)
      + COALESCE(a.model_context_ms, 0)
      + COALESCE(a.tokenize_ms, 0)
      + COALESCE(a.prompt_decode_ms, 0)
      + COALESCE(a.generate_ms, 0)
      + COALESCE(a.postprocess_ms, 0)
      + COALESCE(a.finish_sql_ms, 0)
      + COALESCE(a.materialize_ms, 0) AS accounted_worker_ms
  FROM otlet.jobs j
  LEFT JOIN attempt_timing a ON a.job_id = j.id
)
SELECT
  s.*,
  CASE
    WHEN s.queue_wait_ms IS NULL OR s.observed_worker_ms IS NULL THEN NULL
    ELSE s.queue_wait_ms + s.observed_worker_ms
  END AS observed_end_to_end_ms,
  CASE
    WHEN s.observed_worker_ms IS NULL THEN NULL
    ELSE s.observed_worker_ms - s.accounted_worker_ms
  END AS reconciliation_delta_ms,
  CASE
    WHEN s.observed_worker_ms IS NULL THEN NULL
    ELSE GREATEST(s.observed_worker_ms - s.accounted_worker_ms, 0)
  END AS worker_overhead_ms,
  CASE
    WHEN s.observed_worker_ms IS NULL THEN NULL
    ELSE GREATEST(s.accounted_worker_ms - s.observed_worker_ms, 0)
  END AS timing_overrun_ms
FROM stage_totals s;

CREATE VIEW otlet.task_inference_cache_status AS
WITH receipt_cache AS MATERIALIZED (
  SELECT
    task_name,
    id AS receipt_id,
    selection_status,
    COALESCE(trace.summary ->> 'inference_cache_hit', 'false')::boolean AS inference_cache_hit,
    COALESCE(
      trace.summary #>> '{cache,key_basis}',
      trace.summary ->> 'inference_cache_key_basis'
    ) AS inference_cache_key_basis,
    COALESCE(
      trace.summary #>> '{cache,invalidation_reason}',
      trace.summary ->> 'inference_cache_invalidation_reason'
    ) AS inference_cache_reason,
    finished_at AS receipt_finished_at,
    (
      COALESCE(
        trace.summary #>> '{cache,invalidation_reason}',
        trace.summary ->> 'inference_cache_invalidation_reason'
      ) IS NOT NULL
      AND COALESCE(
        trace.summary #>> '{cache,invalidation_reason}',
        trace.summary ->> 'inference_cache_invalidation_reason'
      ) NOT IN ('disabled', 'disabled_for_generation_trace')
    ) AS cache_enabled
  FROM otlet.inference_receipts r
  CROSS JOIN LATERAL (
    -- Expand the toasted object once and keep the projection from being pulled up
    SELECT r.trace_summary || '{}'::jsonb AS summary
    OFFSET 0
  ) trace
),
task_cache AS (
  SELECT
    task_name,
    count(*)::bigint AS receipt_count,
    count(*) FILTER (WHERE selection_status = 'accepted')::bigint AS accepted_receipts,
    count(*) FILTER (WHERE selection_status = 'rejected')::bigint AS rejected_receipts,
    count(*) FILTER (WHERE selection_status = 'failed')::bigint AS failed_receipts,
    count(*) FILTER (WHERE cache_enabled)::bigint AS cache_enabled_receipts,
    count(*) FILTER (WHERE inference_cache_hit)::bigint AS inference_cache_hits,
    count(*) FILTER (WHERE cache_enabled AND NOT inference_cache_hit)::bigint AS inference_cache_misses,
    count(*) FILTER (WHERE selection_status = 'accepted' AND inference_cache_hit)::bigint AS accepted_cache_hits,
    count(*) FILTER (WHERE selection_status = 'rejected' AND inference_cache_hit)::bigint AS rejected_cache_hits,
    count(*) FILTER (WHERE selection_status = 'failed' AND inference_cache_hit)::bigint AS failed_cache_hits,
    array_remove(array_agg(DISTINCT inference_cache_key_basis), NULL) AS key_basis_values
  FROM receipt_cache
  GROUP BY task_name
),
latest_cache AS (
  SELECT DISTINCT ON (task_name)
    task_name,
    inference_cache_reason AS last_cache_reason
  FROM receipt_cache
  ORDER BY task_name, receipt_finished_at DESC, receipt_id DESC
),
reason_counts AS (
  SELECT
    task_name,
    COALESCE(inference_cache_reason, 'unknown') AS reason,
    count(*)::bigint AS receipt_count
  FROM receipt_cache
  GROUP BY task_name, COALESCE(inference_cache_reason, 'unknown')
),
task_reasons AS (
  SELECT
    task_name,
    jsonb_object_agg(reason, receipt_count ORDER BY reason) AS cache_reasons
  FROM reason_counts
  GROUP BY task_name
)
SELECT
  c.task_name,
  c.receipt_count,
  c.accepted_receipts,
  c.rejected_receipts,
  c.failed_receipts,
  c.cache_enabled_receipts,
  c.inference_cache_hits,
  c.inference_cache_misses,
  CASE
    WHEN c.cache_enabled_receipts > 0
      THEN c.inference_cache_hits::numeric / c.cache_enabled_receipts
    ELSE NULL
  END AS inference_cache_hit_rate,
  c.accepted_cache_hits,
  c.rejected_cache_hits,
  c.failed_cache_hits,
  to_jsonb(c.key_basis_values) AS inference_cache_key_bases,
  latest.last_cache_reason,
  COALESCE(reasons.cache_reasons, '{}'::jsonb) AS cache_reasons
FROM task_cache c
LEFT JOIN latest_cache latest USING (task_name)
LEFT JOIN task_reasons reasons USING (task_name);
