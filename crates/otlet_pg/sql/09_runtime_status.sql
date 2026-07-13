CREATE VIEW otlet.runtime_status AS
WITH infer_state AS (
  SELECT otlet.worker_infer_now_state() AS s
),
worker_state AS (
  SELECT count(*)::bigint AS resident_worker_count
  FROM pg_stat_activity
  WHERE backend_type = 'otlet worker'
)
SELECT
  'linked_inproc'::text AS runtime_name,
  'linked'::text AS endpoint,
  COALESCE(s.status, 'cold') AS runtime_status,
  s.last_error,
  s.last_used_at AS checked_at,
  m.name AS model_name,
  s.status AS slot_state,
  COALESCE(s.artifact_path, m.artifact_path) AS artifact_path,
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
  fingerprint.runtime_fingerprint_version,
  fingerprint.runtime_fingerprint_hash,
  fingerprint.runtime_output_contract_hash,
  fingerprint.runtime_fingerprint,
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
  s.inference_cache_max_entries,
  s.inference_cache_max_bytes,
  s.inference_cache_evictions,
  s.inference_cache_last_eviction_reason,
  s.inference_cache_last_reason,
  infer.s ->> 'state' AS infer_now_state,
  COALESCE((infer.s ->> 'slot_count')::bigint, 0) AS infer_now_slot_count,
  COALESCE((infer.s ->> 'available_slots')::bigint, 0) AS infer_now_available_slots,
  COALESCE((infer.s ->> 'queue_depth')::bigint, 0) AS infer_now_queue_depth,
  COALESCE((infer.s ->> 'requested_slots')::bigint, 0) AS infer_now_requested_slots,
  COALESCE((infer.s ->> 'running_slots')::bigint, 0) AS infer_now_running_slots,
  COALESCE(worker_state.resident_worker_count, 0) AS resident_worker_count,
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
FROM otlet.models m
LEFT JOIN otlet.runtime_slots s ON s.model_name = m.name
LEFT JOIN infer_state infer ON true
LEFT JOIN worker_state ON true
LEFT JOIN LATERAL (
  SELECT
    r.trace_summary ->> 'runtime_fingerprint_version' AS runtime_fingerprint_version,
    r.trace_summary ->> 'runtime_fingerprint_hash' AS runtime_fingerprint_hash,
    r.trace_summary ->> 'runtime_output_contract_hash' AS runtime_output_contract_hash,
    r.trace_summary -> 'runtime_fingerprint' AS runtime_fingerprint
  FROM otlet.inference_receipts r
  WHERE r.model_name = m.name
    AND r.runtime_name = 'linked_inproc'
    AND r.status = 'complete'
    AND r.schema_validation_status = 'passed'
    AND COALESCE(r.generate_ms, 0) > 0
    AND r.trace_summary ->> 'runtime_fingerprint_hash' <> ''
  ORDER BY r.finished_at DESC, r.id DESC
  LIMIT 1
) fingerprint ON true
LEFT JOIN LATERAL (
  SELECT (pg_stat_file(COALESCE(s.artifact_path, m.artifact_path), true)).size::bigint AS artifact_bytes
  WHERE COALESCE(s.artifact_path, m.artifact_path) <> ''
) artifact_file ON true;
