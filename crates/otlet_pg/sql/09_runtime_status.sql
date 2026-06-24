CREATE VIEW otlet.worker_scheduler_status AS
WITH active_by_model AS (
  SELECT
    t.model_name,
    count(*) FILTER (
      WHERE j.status = 'running'
        AND (j.leased_until IS NULL OR j.leased_until >= now())
    ) AS running_jobs,
    count(*) FILTER (WHERE j.status = 'cancel_requested') AS cancel_requested_jobs,
    count(*) FILTER (WHERE j.status = 'running' AND j.leased_until < now()) AS expired_running_jobs
  FROM otlet.jobs j
  JOIN otlet.tasks t ON t.name = j.task_name
  GROUP BY t.model_name
),
queued_by_model AS (
  SELECT
    t.model_name,
    count(*) FILTER (WHERE j.status = 'queued') AS queued_jobs,
    min(j.created_at) FILTER (WHERE j.status = 'queued') AS oldest_queued_at
  FROM otlet.jobs j
  JOIN otlet.tasks t ON t.name = j.task_name
  GROUP BY t.model_name
),
next_claimable AS (
  SELECT DISTINCT ON (m.name)
    m.name AS model_name,
    j.id AS next_job_id,
    j.task_name AS next_task_name,
    j.subject_id AS next_subject_id,
    j.created_at AS next_job_created_at,
    j.status AS next_job_status
  FROM otlet.jobs j
  JOIN otlet.tasks t ON t.name = j.task_name
  JOIN otlet.models m ON m.name = t.model_name
  LEFT JOIN active_by_model active_model ON active_model.model_name = m.name
  WHERE (
      j.status = 'queued'
      OR (j.status = 'running' AND j.leased_until < now())
    )
    AND (
      COALESCE(active_model.running_jobs, 0)
      + COALESCE(active_model.cancel_requested_jobs, 0)
    ) < m.max_active_jobs
  ORDER BY
    m.name,
    CASE WHEN j.status = 'running' AND j.leased_until < now() THEN 0 ELSE 1 END,
    j.created_at,
    j.id
),
base AS (
  SELECT
    m.runtime_name,
    m.name AS model_name,
    m.artifact_path,
    m.max_active_jobs,
    COALESCE(q.queued_jobs, 0) AS queued_jobs,
    COALESCE(a.running_jobs, 0) AS running_jobs,
    COALESCE(a.cancel_requested_jobs, 0) AS cancel_requested_jobs,
    COALESCE(a.expired_running_jobs, 0) AS expired_running_jobs,
    GREATEST(
      m.max_active_jobs
      - COALESCE(a.running_jobs, 0)
      - COALESCE(a.cancel_requested_jobs, 0),
      0
    ) AS available_model_slots,
    q.oldest_queued_at,
    s.status AS slot_status,
    s.artifact_path AS slot_artifact_path,
    s.last_used_at AS slot_last_used_at,
    (s.status = 'ready' AND s.artifact_path IS NOT DISTINCT FROM m.artifact_path) AS resident_match,
    n.next_job_id,
    n.next_task_name,
    n.next_subject_id,
    n.next_job_created_at,
    n.next_job_status,
    CASE
      WHEN n.next_job_id IS NOT NULL THEN 'claimable'
      WHEN COALESCE(q.queued_jobs, 0) + COALESCE(a.expired_running_jobs, 0) > 0
        THEN 'blocked_by_model_active_cap'
      ELSE 'idle'
    END AS admission_state
  FROM otlet.models m
  LEFT JOIN active_by_model a ON a.model_name = m.name
  LEFT JOIN queued_by_model q ON q.model_name = m.name
  LEFT JOIN next_claimable n ON n.model_name = m.name
  LEFT JOIN otlet.runtime_slots s
    ON s.runtime_name = m.runtime_name
   AND s.model_name = m.name
)
SELECT
  runtime_name,
  model_name,
  artifact_path,
  max_active_jobs,
  queued_jobs,
  running_jobs,
  cancel_requested_jobs,
  expired_running_jobs,
  available_model_slots,
  oldest_queued_at,
  slot_status,
  slot_artifact_path,
  slot_last_used_at,
  resident_match,
  next_job_id,
  next_task_name,
  next_subject_id,
  next_job_created_at,
  next_job_status,
  admission_state,
  CASE WHEN next_job_id IS NOT NULL THEN
    row_number() OVER (
      PARTITION BY next_job_id IS NULL
      ORDER BY
        CASE WHEN resident_match THEN 0 ELSE 1 END,
        CASE WHEN next_job_status = 'running' THEN 0 ELSE 1 END,
        next_job_created_at,
        next_job_id
    )
  END AS claim_rank
FROM base;

CREATE VIEW otlet.runtime_status AS
WITH infer_state AS (
  SELECT otlet.worker_infer_now_state() AS s
)
SELECT
  r.name AS runtime_name,
  r.endpoint,
  r.status AS runtime_status,
  r.last_error,
  r.checked_at,
  s.model_name,
  s.status AS slot_state,
  s.artifact_path,
  artifact_file.artifact_bytes,
  CASE
    WHEN s.artifact_path IS NOT NULL THEN 'resident_worker_loaded_model_context'
    WHEN s.status IS NOT NULL THEN 'resident_worker_slot_not_ready'
    ELSE 'no_resident_model_slot'
  END AS model_residency_policy,
  s.active_jobs,
  s.loaded_at,
  s.last_used_at,
  s.load_ms,
  s.ctx_ms,
  s.last_prompt_tokens,
  s.last_generated_tokens,
  s.last_generate_ms,
  s.tokens_per_second,
  s.model_memory_bytes,
  s.model_parameters,
  s.context_window_tokens,
  s.model_device_policy,
  s.resident_memory_tracked_bytes,
  s.memory_accounting_policy,
  s.worker_process_rss_bytes,
  s.worker_process_virtual_bytes,
  s.worker_memory_sample_policy,
  s.jobs_completed,
  s.failures,
  s.cache_hits,
  s.cache_misses,
  s.inference_cache_hits,
  s.inference_cache_misses,
  s.inference_cache_entries,
  s.inference_cache_bytes,
  128::bigint AS inference_cache_max_entries,
  1048576::bigint AS inference_cache_max_bytes,
  s.inference_cache_evictions,
  s.inference_cache_last_reason,
  infer.s ->> 'state' AS infer_now_state,
  COALESCE((infer.s ->> 'slot_count')::bigint, 0) AS infer_now_slot_count,
  COALESCE((infer.s ->> 'available_slots')::bigint, 0) AS infer_now_available_slots,
  COALESCE((infer.s ->> 'queue_depth')::bigint, 0) AS infer_now_queue_depth,
  COALESCE((infer.s ->> 'requested_slots')::bigint, 0) AS infer_now_requested_slots,
  COALESCE((infer.s ->> 'running_slots')::bigint, 0) AS infer_now_running_slots,
  COALESCE((infer.s ->> 'busy_rejections')::bigint, 0) AS infer_now_busy_rejections,
  COALESCE((infer.s ->> 'timeouts')::bigint, 0) AS infer_now_timeouts,
  COALESCE((infer.s ->> 'task_cap')::bigint, 0) AS infer_now_task_cap_bytes,
  COALESCE((infer.s ->> 'task_bytes')::bigint, 0) AS infer_now_task_bytes,
  COALESCE((infer.s ->> 'subject_cap')::bigint, 0) AS infer_now_subject_cap_bytes,
  COALESCE((infer.s ->> 'subject_bytes')::bigint, 0) AS infer_now_subject_bytes,
  COALESCE((infer.s ->> 'input_cap')::bigint, 0) AS infer_now_input_cap_bytes,
  COALESCE((infer.s ->> 'input_bytes')::bigint, 0) AS infer_now_input_bytes,
  COALESCE((infer.s ->> 'error_cap')::bigint, 0) AS infer_now_error_cap_bytes,
  length(COALESCE(infer.s ->> 'error', ''))::bigint AS infer_now_error_bytes,
  COALESCE((infer.s ->> 'max_wait_ms')::bigint, 0) AS infer_now_max_wait_ms,
  COALESCE((infer.s ->> 'last_elapsed_ms')::bigint, 0) AS infer_now_last_elapsed_ms
FROM otlet.runtimes r
LEFT JOIN otlet.runtime_slots s ON s.runtime_name = r.name
LEFT JOIN infer_state infer ON true
LEFT JOIN LATERAL (
  SELECT (pg_stat_file(s.artifact_path, true)).size::bigint AS artifact_bytes
  WHERE s.artifact_path IS NOT NULL AND s.artifact_path <> ''
) artifact_file ON true;
