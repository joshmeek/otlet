CREATE VIEW otlet.production_policy_status AS
SELECT
  p.name,
  p.stale_policy,
  p.max_queued_jobs_per_model,
  p.max_admission_rows,
  p.max_input_bytes_per_job,
  p.max_queued_input_bytes_per_model,
  p.max_queued_input_bytes_total,
  p.max_candidate_query_cost,
  p.candidate_query_statement_timeout_ms,
  p.max_raw_output_bytes,
  p.max_structured_output_bytes,
  p.max_actions_per_job,
  p.max_action_bytes,
  p.max_trace_bytes,
  p.max_error_bytes,
  p.max_event_message_bytes,
  p.max_event_detail_bytes,
  p.max_receipt_bytes,
  p.max_attempts,
  p.max_attempt_ms,
  p.default_runtime_options,
  p.preload_model_name,
  p.semantic_auto_wait_ms,
  p.semantic_auto_infer_ms,
  p.semantic_auto_max_rows,
  p.worker_claim_batch_size,
  p.worker_claim_task_cursor,
  p.job_lease_interval,
  p.worker_event_retention,
  p.trace_detail_retention,
  p.eval_label_retention,
  p.delete_stale_materialization_retention,
  p.sensitive_evidence_mode,
  p.sensitive_evidence_retention,
  p.failed_job_retention
FROM otlet.production_policy p
WHERE p.name = 'default';

CREATE VIEW otlet.model_queue_status AS
SELECT
  'linked_inproc'::text AS runtime_name,
  m.name AS model_name,
  m.max_active_jobs,
  p.max_queued_jobs_per_model,
  p.max_queued_input_bytes_per_model,
  p.max_queued_input_bytes_total,
  count(j.id) FILTER (WHERE j.status = 'queued')::bigint AS queued_jobs,
  COALESCE(sum(octet_length(j.input::text)) FILTER (WHERE j.status = 'queued'), 0)::bigint AS queued_input_bytes,
  total_queue.queued_input_bytes AS total_queued_input_bytes,
  count(j.id) FILTER (WHERE j.status = 'running')::bigint AS running_jobs,
  count(j.id) FILTER (WHERE j.status = 'cancel_requested')::bigint AS cancel_requested_jobs,
  count(j.id) FILTER (
    WHERE j.status IN ('running', 'cancel_requested')
      AND (j.leased_until IS NULL OR j.leased_until < now())
  )::bigint AS expired_running_jobs,
  GREATEST(
    p.max_queued_jobs_per_model::bigint
      - count(j.id) FILTER (WHERE j.status = 'queued'),
    0
  ) AS available_queue_slots,
  GREATEST(
    p.max_queued_input_bytes_per_model
      - COALESCE(sum(octet_length(j.input::text)) FILTER (WHERE j.status = 'queued'), 0),
    0
  )::bigint AS available_model_queue_input_bytes,
  GREATEST(
    p.max_queued_input_bytes_total - total_queue.queued_input_bytes,
    0
  )::bigint AS available_total_queue_input_bytes,
  CASE
    WHEN count(j.id) FILTER (WHERE j.status = 'queued') >= p.max_queued_jobs_per_model
      OR COALESCE(sum(octet_length(j.input::text)) FILTER (WHERE j.status = 'queued'), 0) >= p.max_queued_input_bytes_per_model
      OR total_queue.queued_input_bytes >= p.max_queued_input_bytes_total
    THEN 'queue_full'
    ELSE 'queue_accepting'
  END AS queue_state,
  COALESCE(suppressed.suppressed_events, 0)::bigint AS queue_admission_suppressed_events,
  suppressed.last_suppressed_at AS queue_admission_last_suppressed_at
FROM otlet.models m
CROSS JOIN otlet.production_policy p
LEFT JOIN otlet.tasks t ON t.model_name = m.name
LEFT JOIN otlet.jobs j
  ON j.task_name = t.name
 AND j.status IN ('queued', 'running', 'cancel_requested')
LEFT JOIN LATERAL (
  SELECT COALESCE(sum(octet_length(queued.input::text)), 0)::bigint AS queued_input_bytes
  FROM otlet.jobs queued
  WHERE queued.status = 'queued'
) total_queue ON true
LEFT JOIN LATERAL (
  SELECT
    count(*)::bigint AS suppressed_events,
    max(e.created_at) AS last_suppressed_at
  FROM otlet.worker_events e
  WHERE e.event_type = 'queue_admission_suppressed'
    AND e.detail ? 'model_name'
    AND e.detail ->> 'model_name' = m.name
) suppressed ON true
WHERE p.name = 'default'
GROUP BY
  m.name,
  m.max_active_jobs,
  p.max_queued_jobs_per_model,
  p.max_queued_input_bytes_per_model,
  p.max_queued_input_bytes_total,
  total_queue.queued_input_bytes,
  suppressed.suppressed_events,
  suppressed.last_suppressed_at;

CREATE VIEW otlet.worker_throughput_status AS
SELECT
  'linked_inproc'::text AS runtime_name,
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
  COALESCE(
    last_batch.detail -> 'task_names',
    jsonb_build_array(COALESCE(last_batch.detail ->> 'task_name', ''))
  ) AS last_batch_task_names,
  last_batch.created_at AS last_batch_at,
  COALESCE(recent_batches.recent_batch_tasks, '[]'::jsonb) AS recent_batch_tasks
FROM otlet.models m
CROSS JOIN otlet.production_policy p
LEFT JOIN otlet.model_queue_status q ON q.model_name = m.name
LEFT JOIN LATERAL (
  SELECT e.detail, e.created_at
  FROM otlet.worker_events e
  WHERE e.event_type = 'worker_batch_finished'
    AND e.detail ? 'model_name'
    AND e.detail ->> 'model_name' = m.name
  ORDER BY e.created_at DESC, e.id DESC
  LIMIT 1
) last_batch ON true
LEFT JOIN LATERAL (
  SELECT jsonb_agg(
           jsonb_build_object(
             'task_name', recent.task_name,
             'task_names', recent.task_names,
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
      COALESCE(
        e.detail -> 'task_names',
        jsonb_build_array(COALESCE(e.detail ->> 'task_name', ''))
      ) AS task_names,
      COALESCE((e.detail ->> 'job_count')::bigint, 0) AS job_count,
      COALESCE((e.detail ->> 'completed_jobs')::bigint, 0) AS completed_jobs,
      COALESCE((e.detail ->> 'failed_jobs')::bigint, 0) AS failed_jobs
    FROM otlet.worker_events e
    WHERE e.event_type = 'worker_batch_finished'
      AND e.detail ? 'model_name'
      AND e.detail ->> 'model_name' = m.name
    ORDER BY e.created_at DESC, e.id DESC
    LIMIT 16
  ) recent
) recent_batches ON true
WHERE p.name = 'default'
GROUP BY
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
  policy.default_runtime_options,
  policy.default_runtime_options || t.runtime_options AS effective_runtime_options,
  CASE
    WHEN (t.runtime_options ->> 'max_attempt_ms') ~ '^[0-9]+$'
    THEN (t.runtime_options ->> 'max_attempt_ms')::integer
    ELSE NULL
  END AS task_max_attempt_ms,
  policy.max_attempt_ms AS policy_max_attempt_ms,
  otlet.effective_task_max_attempt_ms(
    policy.default_runtime_options || t.runtime_options,
    policy.max_attempt_ms
  ) AS effective_max_attempt_ms,
  otlet.effective_job_lease_interval(
    policy.default_runtime_options || t.runtime_options,
    policy.max_attempt_ms,
    policy.job_lease_interval
  ) AS effective_job_lease_interval,
  cheap_q.queue_state AS cheap_queue_state,
  cheap_q.queued_jobs AS cheap_queued_jobs,
  cheap_q.running_jobs AS cheap_running_jobs,
  p.created_at,
  p.updated_at
FROM otlet.model_selection_policies p
JOIN otlet.tasks t ON t.name = p.task_name
CROSS JOIN otlet.production_policy policy
LEFT JOIN otlet.model_queue_status cheap_q ON cheap_q.model_name = p.cheap_model_name
WHERE policy.name = 'default';

CREATE VIEW otlet.model_selection_status AS
WITH job_counts AS (
  SELECT
    j.task_name,
    count(*)::bigint AS total_jobs,
    count(*) FILTER (WHERE j.status = 'complete')::bigint AS complete_jobs,
    count(*) FILTER (WHERE j.status = 'failed')::bigint AS failed_jobs
  FROM otlet.jobs j
  GROUP BY j.task_name
),
attempt_counts AS (
  SELECT
    r.task_name,
    count(*) FILTER (WHERE r.selection_role = 'cheap')::bigint AS cheap_attempts,
    count(*) FILTER (
      WHERE r.selection_role = 'cheap'
        AND r.selection_status = 'accepted'
    )::bigint AS cheap_accepted,
    count(*) FILTER (
      WHERE r.selection_role = 'cheap'
        AND r.selection_status = 'rejected'
    )::bigint AS cheap_rejected,
    count(*) FILTER (
      WHERE r.selection_role = 'cheap'
        AND r.schema_validation_status = 'failed'
    )::bigint AS cheap_schema_failed,
    count(*) FILTER (WHERE r.selection_role = 'strong')::bigint AS strong_attempts,
    count(*) FILTER (
      WHERE r.selection_role = 'strong'
        AND r.selection_status = 'accepted'
    )::bigint AS strong_accepted,
    count(*) FILTER (
      WHERE r.selection_role = 'strong'
        AND r.selection_status = 'failed'
    )::bigint AS strong_failed,
    count(DISTINCT r.job_id) FILTER (WHERE r.selection_role = 'strong')::bigint AS escalated_jobs
  FROM otlet.inference_receipts r
  GROUP BY r.task_name
)
SELECT
  p.task_name,
  COALESCE(j.total_jobs, 0)::bigint AS total_jobs,
  COALESCE(j.complete_jobs, 0)::bigint AS complete_jobs,
  COALESCE(j.failed_jobs, 0)::bigint AS failed_jobs,
  COALESCE(a.cheap_attempts, 0)::bigint AS cheap_attempts,
  COALESCE(a.cheap_accepted, 0)::bigint AS cheap_accepted,
  COALESCE(a.cheap_rejected, 0)::bigint AS cheap_rejected,
  COALESCE(a.cheap_schema_failed, 0)::bigint AS cheap_schema_failed,
  COALESCE(a.strong_attempts, 0)::bigint AS strong_attempts,
  COALESCE(a.strong_accepted, 0)::bigint AS strong_accepted,
  COALESCE(a.strong_failed, 0)::bigint AS strong_failed,
  COALESCE(a.escalated_jobs, 0)::bigint AS escalated_jobs
FROM otlet.model_selection_policies p
LEFT JOIN job_counts j ON j.task_name = p.task_name
LEFT JOIN attempt_counts a ON a.task_name = p.task_name;
