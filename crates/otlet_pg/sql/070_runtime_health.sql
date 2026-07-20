CREATE FUNCTION otlet.record_worker_event(
  event_type text,
  job_id bigint DEFAULT NULL,
  runtime_name text DEFAULT NULL,
  message text DEFAULT NULL,
  detail jsonb DEFAULT '{}'::jsonb
) RETURNS otlet.worker_events
LANGUAGE sql
AS $$
  INSERT INTO otlet.worker_events (event_type, job_id, runtime_name, message, detail)
  VALUES ($1, $2, $3, $4, COALESCE($5, '{}'::jsonb))
  RETURNING *;
$$;

CREATE FUNCTION otlet.touch_runtime_slot(
  model_name text,
  status text,
  active_jobs int DEFAULT 0,
  last_error text DEFAULT NULL
) RETURNS otlet.runtime_slots
LANGUAGE sql
AS $$
  INSERT INTO otlet.runtime_slots (
    model_name,
    status,
    active_jobs,
    loaded_at,
    last_used_at,
    last_error
  )
  VALUES (
    $1,
    $2,
    GREATEST($3, 0),
    CASE WHEN $2 = 'ready' THEN now() END,
    now(),
    $4
  )
  ON CONFLICT (model_name) DO UPDATE
    SET status = EXCLUDED.status,
        active_jobs = GREATEST(EXCLUDED.active_jobs, 0),
        loaded_at = COALESCE(otlet.runtime_slots.loaded_at, EXCLUDED.loaded_at),
        last_used_at = now(),
        last_error = EXCLUDED.last_error,
        failures = otlet.runtime_slots.failures + CASE WHEN EXCLUDED.status = 'error' THEN 1 ELSE 0 END
  RETURNING *;
$$;

CREATE FUNCTION otlet.record_runtime_slot_metrics(
  model_name text,
  artifact_path text,
  load_ms bigint,
  ctx_ms bigint,
  prompt_tokens bigint,
  generated_tokens bigint,
  generate_ms bigint,
  cache_hit boolean DEFAULT false,
  inference_cache_hit boolean DEFAULT false,
  inference_cache_entries bigint DEFAULT 0,
  inference_cache_bytes bigint DEFAULT 0,
  inference_cache_evictions bigint DEFAULT 0,
  inference_cache_reason text DEFAULT NULL,
  model_memory_bytes bigint DEFAULT 0,
  model_parameters bigint DEFAULT 0,
  context_window_tokens bigint DEFAULT 0,
  model_device_policy text DEFAULT NULL,
  memory_accounting_policy text DEFAULT NULL,
  worker_process_rss_bytes bigint DEFAULT 0,
  worker_process_virtual_bytes bigint DEFAULT 0,
  worker_memory_sample_policy text DEFAULT NULL,
  inference_cache_max_entries bigint DEFAULT 0,
  inference_cache_max_bytes bigint DEFAULT 0,
  inference_cache_eviction_reason text DEFAULT NULL
) RETURNS otlet.runtime_slots
LANGUAGE sql
AS $$
  INSERT INTO otlet.runtime_slots (
    model_name,
    artifact_path,
    status,
    active_jobs,
    loaded_at,
    last_used_at,
    load_ms,
    ctx_ms,
    last_prompt_tokens,
    last_generated_tokens,
    last_generate_ms,
    tokens_per_second,
    model_memory_bytes,
    model_parameters,
    context_window_tokens,
    model_device_policy,
    resident_memory_tracked_bytes,
    memory_accounting_policy,
    worker_process_rss_bytes,
    worker_process_virtual_bytes,
    worker_memory_sample_policy,
    jobs_completed,
    cache_hits,
    cache_misses,
    inference_cache_hits,
    inference_cache_misses,
    inference_cache_entries,
    inference_cache_bytes,
    inference_cache_max_entries,
    inference_cache_max_bytes,
    inference_cache_evictions,
    inference_cache_last_eviction_reason,
    inference_cache_last_reason
  )
  VALUES (
    $1,
    $2,
    'ready',
    0,
    now(),
    now(),
    $3,
    $4,
    $5,
    $6,
    $7,
    CASE WHEN $7 > 0 THEN round(($6::numeric * 1000) / $7, 2) END,
    GREATEST($14, 0),
    GREATEST($15, 0),
    GREATEST($16, 0),
    COALESCE($17, 'cpu_only_n_gpu_layers_0'),
    GREATEST($14, 0) + GREATEST($11, 0),
    COALESCE($18, 'llama_model_size_measured_context_window_measured_inference_cache_bytes_measured_no_prompt_token_blob_storage'),
    GREATEST($19, 0),
    GREATEST($20, 0),
    COALESCE($21, 'linux_proc_self_and_optional_cgroup_v2_memory_pressure_v1'),
    1,
    CASE WHEN NOT $9 AND $8 THEN 1 ELSE 0 END,
    CASE WHEN NOT $9 AND NOT $8 THEN 1 ELSE 0 END,
    CASE WHEN $9 THEN 1 ELSE 0 END,
    CASE WHEN NOT $9 AND COALESCE($13, '') <> 'disabled' THEN 1 ELSE 0 END,
    GREATEST($10, 0),
    GREATEST($11, 0),
    GREATEST($22, 0),
    GREATEST($23, 0),
    GREATEST($12, 0),
    COALESCE($24, 'none'),
    $13
  )
  ON CONFLICT (model_name) DO UPDATE
    SET artifact_path = EXCLUDED.artifact_path,
        status = 'ready',
        active_jobs = 0,
        loaded_at = CASE
          WHEN $9 THEN otlet.runtime_slots.loaded_at
          WHEN NOT $8 THEN now()
          WHEN otlet.runtime_slots.artifact_path IS DISTINCT FROM EXCLUDED.artifact_path
            THEN now()
          ELSE COALESCE(otlet.runtime_slots.loaded_at, now())
        END,
        last_used_at = now(),
        last_error = NULL,
        load_ms = CASE WHEN $9 THEN otlet.runtime_slots.load_ms ELSE EXCLUDED.load_ms END,
        ctx_ms = CASE WHEN $9 THEN otlet.runtime_slots.ctx_ms ELSE EXCLUDED.ctx_ms END,
        last_prompt_tokens = CASE WHEN $9 THEN otlet.runtime_slots.last_prompt_tokens ELSE EXCLUDED.last_prompt_tokens END,
        last_generated_tokens = CASE WHEN $9 THEN otlet.runtime_slots.last_generated_tokens ELSE EXCLUDED.last_generated_tokens END,
        last_generate_ms = CASE WHEN $9 THEN otlet.runtime_slots.last_generate_ms ELSE EXCLUDED.last_generate_ms END,
        tokens_per_second = CASE
          WHEN $9 THEN otlet.runtime_slots.tokens_per_second
          ELSE COALESCE(EXCLUDED.tokens_per_second, otlet.runtime_slots.tokens_per_second)
        END,
        model_memory_bytes = CASE WHEN $9 THEN otlet.runtime_slots.model_memory_bytes ELSE GREATEST($14, 0) END,
        model_parameters = CASE WHEN $9 THEN otlet.runtime_slots.model_parameters ELSE GREATEST($15, 0) END,
        context_window_tokens = CASE WHEN $9 THEN otlet.runtime_slots.context_window_tokens ELSE GREATEST($16, 0) END,
        model_device_policy = CASE WHEN $9 THEN otlet.runtime_slots.model_device_policy ELSE COALESCE($17, otlet.runtime_slots.model_device_policy) END,
        resident_memory_tracked_bytes =
          (CASE WHEN $9 THEN otlet.runtime_slots.model_memory_bytes ELSE GREATEST($14, 0) END)
          + (CASE
              WHEN COALESCE($13, '') = 'disabled' THEN otlet.runtime_slots.inference_cache_bytes
              ELSE GREATEST($11, 0)
            END),
        memory_accounting_policy = CASE WHEN $9 THEN otlet.runtime_slots.memory_accounting_policy ELSE COALESCE($18, otlet.runtime_slots.memory_accounting_policy) END,
        worker_process_rss_bytes = CASE WHEN $19 > 0 THEN GREATEST($19, 0) ELSE otlet.runtime_slots.worker_process_rss_bytes END,
        worker_process_virtual_bytes = CASE WHEN $20 > 0 THEN GREATEST($20, 0) ELSE otlet.runtime_slots.worker_process_virtual_bytes END,
        worker_memory_sample_policy = COALESCE($21, otlet.runtime_slots.worker_memory_sample_policy),
        jobs_completed = otlet.runtime_slots.jobs_completed + 1,
        cache_hits = otlet.runtime_slots.cache_hits + CASE WHEN NOT $9 AND $8 THEN 1 ELSE 0 END,
        cache_misses = otlet.runtime_slots.cache_misses + CASE WHEN NOT $9 AND NOT $8 THEN 1 ELSE 0 END,
        inference_cache_hits = otlet.runtime_slots.inference_cache_hits + CASE WHEN $9 THEN 1 ELSE 0 END,
        inference_cache_misses = otlet.runtime_slots.inference_cache_misses + CASE WHEN NOT $9 AND COALESCE($13, '') <> 'disabled' THEN 1 ELSE 0 END,
        inference_cache_entries = CASE
          WHEN COALESCE($13, '') = 'disabled' THEN otlet.runtime_slots.inference_cache_entries
          ELSE EXCLUDED.inference_cache_entries
        END,
        inference_cache_bytes = CASE
          WHEN COALESCE($13, '') = 'disabled' THEN otlet.runtime_slots.inference_cache_bytes
          ELSE EXCLUDED.inference_cache_bytes
        END,
        inference_cache_max_entries = GREATEST($22, 0),
        inference_cache_max_bytes = GREATEST($23, 0),
        inference_cache_evictions = CASE
          WHEN COALESCE($13, '') = 'disabled' THEN otlet.runtime_slots.inference_cache_evictions
          ELSE EXCLUDED.inference_cache_evictions
        END,
        inference_cache_last_eviction_reason = COALESCE($24, otlet.runtime_slots.inference_cache_last_eviction_reason),
        inference_cache_last_reason = COALESCE($13, otlet.runtime_slots.inference_cache_last_reason)
  RETURNING *;
$$;
