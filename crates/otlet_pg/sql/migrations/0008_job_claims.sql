CREATE VIEW otlet.model_claim_capacity AS
WITH policy AS (
  SELECT max_attempts
  FROM otlet.production_policy
  WHERE name = 'default'
), job_models AS (
  SELECT
    COALESCE(
      j.routed_model_name,
      revision.definition #>> '{models,direct,name}'
    ) AS model_name,
    ((CASE
        WHEN j.routed_model_name = revision.definition #>> '{selection,strong_model_name}'
          THEN revision.definition #> '{models,strong}'
        WHEN j.routed_model_name = revision.definition #>> '{selection,cheap_model_name}'
          THEN revision.definition #> '{models,cheap}'
        ELSE revision.definition #> '{models,direct}'
      END) ->> 'max_active_jobs')::integer AS max_active_jobs,
    j.status,
    j.attempts,
    j.leased_until,
    (
      j.execution_mode = 'evaluation'
      OR j.workload_revision_hash = head.active_workload_revision_hash
    ) AS active_revision
  FROM otlet.jobs j
  JOIN otlet.workload_revisions revision
    ON revision.workload_revision_hash = j.workload_revision_hash
   AND revision.task_name = j.task_name
  LEFT JOIN otlet.workload_revision_heads head ON head.task_name = j.task_name
  WHERE j.status IN ('queued', 'running', 'cancel_requested')
), revision_routes AS (
  SELECT model_name, min(max_active_jobs) AS max_active_jobs
  FROM job_models
  GROUP BY model_name
), relevant_limits AS (
  SELECT model_name, min(max_active_jobs) AS max_active_jobs
  FROM job_models
  CROSS JOIN policy
  WHERE (
      status IN ('running', 'cancel_requested')
      AND leased_until >= now()
    )
    OR (
      active_revision
      AND (
        status = 'queued'
        OR (
          status IN ('running', 'cancel_requested')
          AND (leased_until IS NULL OR leased_until < now())
          AND attempts < policy.max_attempts
        )
      )
    )
  GROUP BY model_name
), model_routes AS (
  SELECT
    model.name AS model_name,
    LEAST(
      model.max_active_jobs,
      COALESCE(relevant.max_active_jobs, model.max_active_jobs)
    ) AS max_active_jobs,
    true AS registered
  FROM otlet.models model
  LEFT JOIN relevant_limits relevant ON relevant.model_name = model.name
  UNION ALL
  SELECT
    revision.model_name,
    COALESCE(relevant.max_active_jobs, revision.max_active_jobs),
    false
  FROM revision_routes revision
  LEFT JOIN relevant_limits relevant ON relevant.model_name = revision.model_name
  WHERE NOT EXISTS (
    SELECT 1 FROM otlet.models model WHERE model.name = revision.model_name
  )
), claim_counts AS (
  SELECT
    model_name,
    count(*) FILTER (
      WHERE status = 'running' AND leased_until >= now()
    )::bigint AS live_running_jobs,
    count(*) FILTER (
      WHERE status = 'cancel_requested' AND leased_until >= now()
    )::bigint AS live_cancel_requested_jobs
  FROM job_models
  GROUP BY model_name
)
SELECT
  route.model_name,
  route.max_active_jobs,
  COALESCE(claim.live_running_jobs, 0) AS live_running_jobs,
  COALESCE(claim.live_cancel_requested_jobs, 0) AS live_cancel_requested_jobs,
  COALESCE(claim.live_running_jobs, 0)
    + COALESCE(claim.live_cancel_requested_jobs, 0) AS active_claimed_jobs,
  CASE
    WHEN route.registered THEN GREATEST(
      route.max_active_jobs::bigint
        - COALESCE(claim.live_running_jobs, 0)
        - COALESCE(claim.live_cancel_requested_jobs, 0),
      0
    )
    ELSE 0::bigint
  END AS available_active_job_slots
FROM model_routes route
LEFT JOIN claim_counts claim ON claim.model_name = route.model_name;

CREATE FUNCTION otlet.portable_reference_runtime_contract() RETURNS jsonb
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'version', 'otlet_runtime_capabilities_v1',
    'supported_runtime_options', jsonb_build_array(
      'reasoning',
      'max_tokens',
      'max_attempt_ms',
      'inference_cache',
      'max_worker_rss_bytes',
      'generation_trace',
      'llama_threads',
      'llama_batch_threads'
    ),
    'schema_behavior', jsonb_build_object(
      'input', 'postgres_jsonb_shaped_snapshot',
      'response', 'json_object_output_actions_envelope',
      'decode_constraint', 'greedy_balanced_json_object_then_database_validation',
      'validation', 'postgres_authoritative_json_schema_subset',
      'unsupported_schema', 'rejected_at_task_registration',
      'supported_types', jsonb_build_array(
        'object', 'array', 'string', 'number', 'integer', 'boolean', 'null'
      ),
      'supported_keywords', jsonb_build_array(
        '$schema', '$id', 'title', 'description', 'default', 'examples',
        'type', 'enum', 'const', 'required', 'properties', 'additionalProperties',
        'items', 'minLength', 'maxLength', 'minimum', 'maximum',
        'exclusiveMinimum', 'exclusiveMaximum', 'minItems', 'maxItems',
        'minProperties', 'maxProperties'
      ),
      'additional_properties', 'boolean_only',
      'items', 'one_schema'
    ),
    'context_limits', jsonb_build_object(
      'context_window_tokens', 4096,
      'batch_tokens', 512,
      'ubatch_tokens', 128,
      'max_generation_tokens', 4096
    ),
    'cancellation', jsonb_build_object(
      'policy', 'claim_signal_before_inference_and_llama_abort_during_decode_generation',
      'claim_loss', 'authoritative',
      'attempt_deadline', 'monotonic_worker_and_database_deadline'
    ),
    'tracing', jsonb_build_object(
      'summary', 'otlet_portable_worker_trace_v1',
      'generation_trace', 'unsupported_must_be_false',
      'raw_prompt_storage', 'none'
    ),
    'artifact_formats', jsonb_build_object(
      'accepted', jsonb_build_array('gguf'),
      'verification', 'sha256_verified_open_regular_file_descriptor',
      'symlinks', 'rejected'
    ),
    'runtime_build', jsonb_build_object(
      'engine', 'llama.cpp',
      'crate', 'llama-cpp-sys-4',
      'crate_version', '0.3.1',
      'revision', '94a220cd6',
      'features', jsonb_build_object('native', true, 'openmp', true)
    ),
    'device_settings', jsonb_build_object(
      'policy', 'cpu_only_n_gpu_layers_0',
      'gpu_layers', 0,
      'load_policy', 'eager_single_resident_model'
    ),
    'resource_admission', jsonb_build_object(
      'budget_option', 'max_worker_rss_bytes',
      'rss_policy', 'linux_proc_status_vmrss_fail_closed',
      'required_evidence', jsonb_build_array('current_rss_bytes', 'artifact_bytes'),
      'process_slots', 1
    )
  )
$$;

CREATE FUNCTION otlet.portable_runtime_option_status(
  workload_definition jsonb,
  selected_model jsonb,
  claim_contract jsonb
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  reference_contract constant jsonb := otlet.portable_reference_runtime_contract();
  requested jsonb := COALESCE(
    portable_runtime_option_status.workload_definition #> '{task,runtime_options}',
    '{}'::jsonb
  );
  supplied_effective jsonb := COALESCE(
    portable_runtime_option_status.workload_definition #> '{runtime,effective_options}',
    '{}'::jsonb
  );
  runtime_contract jsonb := portable_runtime_option_status.claim_contract -> 'runtime_contract';
  artifact_hash text := portable_runtime_option_status.claim_contract ->> 'model_artifact_hash';
  artifact_bytes_text text := portable_runtime_option_status.claim_contract ->> 'model_artifact_bytes';
  current_rss_text text := portable_runtime_option_status.claim_contract ->> 'current_rss_bytes';
  default_llama_threads_text text := portable_runtime_option_status.claim_contract ->> 'default_llama_threads';
  effective_attempt_text text := portable_runtime_option_status.workload_definition #>> '{runtime,effective_max_attempt_ms}';
  option_name text;
  artifact_bytes_valid boolean;
  current_rss_valid boolean;
  max_tokens_valid boolean;
  effective_attempt_valid boolean;
  max_worker_rss_valid boolean;
  option_value_valid boolean;
  default_llama_threads_valid boolean;
  effective_llama_threads jsonb;
  effective_llama_batch_threads jsonb;
  effective jsonb;
  honored jsonb := '{}'::jsonb;
  defaulted jsonb := '{}'::jsonb;
  rejected jsonb := '{}'::jsonb;
BEGIN
  IF jsonb_typeof(requested) IS DISTINCT FROM 'object' THEN
    rejected := rejected || jsonb_build_object('runtime_options', 'requested_options_must_be_object');
    requested := '{}'::jsonb;
  END IF;
  IF jsonb_typeof(supplied_effective) IS DISTINCT FROM 'object' THEN
    rejected := rejected || jsonb_build_object('effective_options', 'effective_options_must_be_object');
    supplied_effective := '{}'::jsonb;
  END IF;
  artifact_bytes_valid := COALESCE(artifact_bytes_text ~ '^[1-9][0-9]{0,18}$', false);
  IF artifact_bytes_valid AND length(artifact_bytes_text) = 19 THEN
    artifact_bytes_valid := artifact_bytes_text <= '9223372036854775807';
  END IF;
  current_rss_valid := COALESCE(current_rss_text ~ '^[0-9]{1,19}$', false);
  IF current_rss_valid AND length(current_rss_text) = 19 THEN
    current_rss_valid := current_rss_text <= '9223372036854775807';
  END IF;
  default_llama_threads_valid := COALESCE(
    jsonb_typeof(portable_runtime_option_status.claim_contract -> 'default_llama_threads') = 'number'
      AND default_llama_threads_text ~ '^[1-9][0-9]{0,3}$',
    false
  );
  IF default_llama_threads_valid AND length(default_llama_threads_text) = 4 THEN
    default_llama_threads_valid := default_llama_threads_text <= '1024';
  END IF;
  IF jsonb_typeof(portable_runtime_option_status.claim_contract) IS DISTINCT FROM 'object'
     OR runtime_contract IS DISTINCT FROM reference_contract THEN
    rejected := rejected || jsonb_build_object('runtime_contract', 'runtime_contract_mismatch');
  END IF;
  IF artifact_hash IS NULL
     OR artifact_hash !~ '^[0-9a-f]{64}$'
     OR artifact_hash IS DISTINCT FROM portable_runtime_option_status.selected_model ->> 'artifact_hash'
     OR artifact_hash IS DISTINCT FROM portable_runtime_option_status.selected_model #>> '{artifact_identity,sha256}'
     OR NOT artifact_bytes_valid
     OR artifact_bytes_text IS DISTINCT FROM portable_runtime_option_status.selected_model #>> '{artifact_identity,bytes}' THEN
    rejected := rejected || jsonb_build_object('model_artifact', 'model_artifact_identity_mismatch');
  END IF;
  IF NOT current_rss_valid THEN
    rejected := rejected || jsonb_build_object('current_rss_bytes', 'current_rss_bytes_must_be_non_negative_integer');
  END IF;
  IF NOT default_llama_threads_valid THEN
    rejected := rejected || jsonb_build_object(
      'default_llama_threads',
      'default_llama_threads_must_be_integer_1_to_1024'
    );
  END IF;

  FOR option_name IN
    SELECT key
    FROM jsonb_object_keys(requested || supplied_effective) key
    WHERE key <> ALL(ARRAY[
      'reasoning', 'max_tokens', 'max_attempt_ms', 'inference_cache',
      'max_worker_rss_bytes', 'generation_trace', 'llama_threads',
      'llama_batch_threads'
    ])
    ORDER BY key
  LOOP
    rejected := rejected || jsonb_build_object(option_name, 'unsupported_runtime_option');
  END LOOP;

  IF supplied_effective ? 'reasoning'
     AND (
       jsonb_typeof(supplied_effective -> 'reasoning') IS DISTINCT FROM 'string'
       OR supplied_effective ->> 'reasoning' NOT IN ('on', 'off')
     ) THEN
    rejected := rejected || jsonb_build_object('reasoning', 'reasoning_must_be_on_or_off');
  END IF;
  max_tokens_valid := NOT supplied_effective ? 'max_tokens';
  IF NOT max_tokens_valid THEN
    max_tokens_valid := jsonb_typeof(supplied_effective -> 'max_tokens') = 'number'
      AND supplied_effective ->> 'max_tokens' ~ '^[1-9][0-9]{0,3}$';
    IF max_tokens_valid AND length(supplied_effective ->> 'max_tokens') = 4 THEN
      max_tokens_valid := supplied_effective ->> 'max_tokens' <= '4096';
    END IF;
  END IF;
  IF NOT max_tokens_valid THEN
    rejected := rejected || jsonb_build_object('max_tokens', 'max_tokens_must_be_integer_1_to_4096');
  END IF;
  effective_attempt_valid := COALESCE(effective_attempt_text ~ '^[1-9][0-9]{0,6}$', false);
  IF effective_attempt_valid AND length(effective_attempt_text) = 7 THEN
    effective_attempt_valid := effective_attempt_text <= '3600000';
  END IF;
  option_value_valid := COALESCE(
    NOT supplied_effective ? 'max_attempt_ms'
      OR supplied_effective ->> 'max_attempt_ms' ~ '^[0-9]+$',
    false
  );
  IF NOT effective_attempt_valid OR NOT option_value_valid THEN
    rejected := rejected || jsonb_build_object('max_attempt_ms', 'max_attempt_ms_must_be_non_negative_integer');
  END IF;
  IF NOT requested ? 'inference_cache'
     OR jsonb_typeof(requested -> 'inference_cache') IS DISTINCT FROM 'boolean'
     OR requested -> 'inference_cache' <> 'false'::jsonb
     OR supplied_effective -> 'inference_cache' IS DISTINCT FROM 'false'::jsonb THEN
    rejected := rejected || jsonb_build_object('inference_cache', 'inference_cache_must_be_explicitly_false');
  END IF;
  max_worker_rss_valid := supplied_effective ? 'max_worker_rss_bytes'
    AND jsonb_typeof(supplied_effective -> 'max_worker_rss_bytes') = 'number'
    AND supplied_effective ->> 'max_worker_rss_bytes' ~ '^[0-9]{1,14}$';
  IF max_worker_rss_valid
     AND length(supplied_effective ->> 'max_worker_rss_bytes') = 14 THEN
    max_worker_rss_valid := supplied_effective ->> 'max_worker_rss_bytes' <= '70368744177664';
  END IF;
  IF NOT max_worker_rss_valid THEN
    rejected := rejected || jsonb_build_object('max_worker_rss_bytes', 'max_worker_rss_bytes_must_be_integer_0_to_70368744177664');
  ELSIF current_rss_valid
        AND (supplied_effective ->> 'max_worker_rss_bytes')::bigint > 0 THEN
    IF current_rss_text::bigint = 0 THEN
      rejected := rejected || jsonb_build_object('current_rss_bytes', 'current_rss_bytes_required_for_positive_budget');
    ELSIF current_rss_text::bigint > (supplied_effective ->> 'max_worker_rss_bytes')::bigint THEN
      rejected := rejected || jsonb_build_object('max_worker_rss_bytes', 'current_rss_exceeds_max_worker_rss_bytes');
    ELSIF artifact_bytes_valid THEN
      IF artifact_bytes_text::bigint > (supplied_effective ->> 'max_worker_rss_bytes')::bigint THEN
        rejected := rejected || jsonb_build_object('max_worker_rss_bytes', 'artifact_exceeds_max_worker_rss_bytes');
      END IF;
    END IF;
  END IF;
  IF supplied_effective ? 'generation_trace'
     AND (
       jsonb_typeof(supplied_effective -> 'generation_trace') IS DISTINCT FROM 'boolean'
       OR supplied_effective -> 'generation_trace' <> 'false'::jsonb
     ) THEN
    rejected := rejected || jsonb_build_object('generation_trace', 'generation_trace_must_be_false');
  END IF;
  effective_llama_threads := CASE
    WHEN default_llama_threads_valid THEN to_jsonb(default_llama_threads_text::integer)
    ELSE '0'::jsonb
  END;
  FOREACH option_name IN ARRAY ARRAY['llama_threads', 'llama_batch_threads']
  LOOP
    option_value_valid := NOT supplied_effective ? option_name;
    IF NOT option_value_valid THEN
      option_value_valid := jsonb_typeof(supplied_effective -> option_name) = 'number'
        AND supplied_effective ->> option_name ~ '^[0-9]{1,4}$';
      IF option_value_valid AND length(supplied_effective ->> option_name) = 4 THEN
        option_value_valid := supplied_effective ->> option_name <= '1024';
      END IF;
    END IF;
    IF NOT option_value_valid THEN
      rejected := rejected || jsonb_build_object(option_name, option_name || '_must_be_integer_0_to_1024');
    ELSIF option_name = 'llama_threads' THEN
      IF supplied_effective ? option_name
         AND supplied_effective ->> option_name <> '0' THEN
        effective_llama_threads := supplied_effective -> option_name;
      END IF;
    ELSE
      effective_llama_batch_threads := effective_llama_threads;
      IF supplied_effective ? option_name
         AND supplied_effective ->> option_name <> '0' THEN
        effective_llama_batch_threads := supplied_effective -> option_name;
      END IF;
    END IF;
  END LOOP;

  effective := jsonb_build_object(
    'reasoning', CASE
      WHEN supplied_effective ->> 'reasoning' IN ('on', 'off')
        THEN supplied_effective -> 'reasoning'
      ELSE '"off"'::jsonb
    END,
    'max_tokens', CASE
      WHEN max_tokens_valid AND supplied_effective ? 'max_tokens'
        THEN supplied_effective -> 'max_tokens'
      ELSE '512'::jsonb
    END,
    'max_attempt_ms', CASE
      WHEN effective_attempt_valid
        THEN to_jsonb(effective_attempt_text::bigint)
      ELSE '0'::jsonb
    END,
    'inference_cache', COALESCE(supplied_effective -> 'inference_cache', 'false'::jsonb),
    'max_worker_rss_bytes', COALESCE(supplied_effective -> 'max_worker_rss_bytes', '0'::jsonb),
    'generation_trace', COALESCE(supplied_effective -> 'generation_trace', 'false'::jsonb),
    'llama_threads', effective_llama_threads,
    'llama_batch_threads', effective_llama_batch_threads
  );

  FOREACH option_name IN ARRAY ARRAY[
    'reasoning', 'max_tokens', 'max_attempt_ms', 'inference_cache',
    'max_worker_rss_bytes', 'generation_trace', 'llama_threads',
    'llama_batch_threads'
  ]
  LOOP
    IF NOT rejected ? option_name THEN
      IF requested ? option_name THEN
        honored := honored || jsonb_build_object(option_name, effective -> option_name);
      ELSE
        defaulted := defaulted || jsonb_build_object(option_name, effective -> option_name);
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'version', 'otlet_portable_runtime_options_status_v1',
    'compatible', rejected = '{}'::jsonb,
    'requested', requested,
    'honored', honored,
    'defaulted', defaulted,
    'rejected', rejected,
    'effective', effective,
    'envelope', jsonb_build_object(
      'model_artifact_hash', artifact_hash,
      'model_artifact_bytes', CASE
        WHEN artifact_bytes_valid THEN to_jsonb(artifact_bytes_text::bigint)
        ELSE 'null'::jsonb
      END,
      'context_window_tokens', reference_contract #> '{context_limits,context_window_tokens}',
      'batch_tokens', reference_contract #> '{context_limits,batch_tokens}',
      'ubatch_tokens', reference_contract #> '{context_limits,ubatch_tokens}',
      'load_policy', reference_contract #> '{device_settings,load_policy}',
      'device_policy', reference_contract #> '{device_settings,policy}',
      'rss_policy', reference_contract #> '{resource_admission,rss_policy}',
      'default_llama_threads', CASE
        WHEN default_llama_threads_valid THEN to_jsonb(default_llama_threads_text::integer)
        ELSE 'null'::jsonb
      END,
      'current_rss_bytes', CASE
        WHEN current_rss_valid THEN to_jsonb(current_rss_text::bigint)
        ELSE 'null'::jsonb
      END,
      'max_worker_rss_bytes', effective -> 'max_worker_rss_bytes'
    )
  );
END;
$$;

-- Atomic queue claim for the resident worker; returns zero rows when no work exists
CREATE FUNCTION otlet.claim_jobs(
  requested_model_name text DEFAULT NULL,
  requested_limit integer DEFAULT NULL,
  requested_portable_claim_contract jsonb DEFAULT NULL
) RETURNS SETOF otlet.jobs
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM 1
  FROM otlet.production_policy p
  WHERE p.name = 'default'
  FOR UPDATE OF p;
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));

  RETURN QUERY
  WITH policy AS (
    SELECT
      CASE
        WHEN claim_jobs.requested_limit IS NULL THEN p.worker_claim_batch_size
        ELSE LEAST(p.worker_claim_batch_size, GREATEST(claim_jobs.requested_limit, 1))
      END AS batch_size,
      p.worker_claim_task_cursor AS task_cursor,
      p.max_attempts
    FROM otlet.production_policy p
    WHERE p.name = 'default'
  ),
  invalid_heads AS MATERIALIZED (
    SELECT
      head.task_name,
      head.active_workload_revision_hash
    FROM otlet.workload_revision_heads head
    WHERE EXISTS (
      SELECT 1
      FROM otlet.jobs j
      JOIN otlet.workload_revisions revision
        ON revision.workload_revision_hash = j.workload_revision_hash
      WHERE j.task_name = head.task_name
        AND j.workload_revision_hash = head.active_workload_revision_hash
        AND j.execution_mode = 'production'
        AND j.status IN ('queued', 'running', 'cancel_requested')
        AND (
          claim_jobs.requested_model_name IS NULL
          OR COALESCE(
            j.routed_model_name,
            revision.definition #>> '{models,direct,name}'
          ) = claim_jobs.requested_model_name
        )
        AND NOT otlet.source_fields_are_allowed(
          j.input,
          revision.definition #> '{task,input_shaping}'
        )
    )
    ORDER BY head.task_name
    FOR UPDATE OF head
  ),
  invalid_claim_input AS MATERIALIZED (
    SELECT j.id
    FROM otlet.jobs j
    JOIN otlet.workload_revisions revision
      ON revision.workload_revision_hash = j.workload_revision_hash
    JOIN invalid_heads head
      ON head.task_name = j.task_name
     AND head.active_workload_revision_hash = j.workload_revision_hash
    WHERE j.execution_mode = 'production'
      AND j.status IN ('queued', 'running', 'cancel_requested')
      AND (
        claim_jobs.requested_model_name IS NULL
        OR COALESCE(
          j.routed_model_name,
          revision.definition #>> '{models,direct,name}'
        ) = claim_jobs.requested_model_name
      )
      AND NOT otlet.source_fields_are_allowed(
        j.input,
        revision.definition #> '{task,input_shaping}'
      )
    ORDER BY j.created_at, j.id
    FOR UPDATE OF j SKIP LOCKED
    LIMIT (SELECT batch_size FROM policy)
  ),
  rejected_claim_input AS (
    UPDATE otlet.jobs j
    SET status = 'failed',
        leased_until = NULL,
        claim_token = NULL,
        error = 'source field allowlist violation',
        finished_at = now()
    FROM invalid_claim_input invalid
    WHERE j.id = invalid.id
    RETURNING j.id
  ),
  job_contracts AS MATERIALIZED (
    SELECT
      j.*,
      revision.definition,
      head.active_workload_revision_hash,
      CASE
        WHEN j.routed_model_name = revision.definition #>> '{selection,strong_model_name}'
          THEN revision.definition #> '{models,strong}'
        WHEN j.routed_model_name = revision.definition #>> '{selection,cheap_model_name}'
          THEN revision.definition #> '{models,cheap}'
        ELSE revision.definition #> '{models,direct}'
      END AS selected_model
    FROM otlet.jobs j
    JOIN otlet.workload_revisions revision
      ON revision.workload_revision_hash = j.workload_revision_hash
     AND revision.task_name = j.task_name
    LEFT JOIN otlet.workload_revision_heads head ON head.task_name = j.task_name
  ),
  eligible_tasks AS (
    SELECT
      job.task_name,
      job.workload_revision_hash,
      job.execution_mode,
      job.selected_model ->> 'name' AS model_name,
      job.selected_model ->> 'artifact_path' AS artifact_path,
      job.definition #>> '{selection,cheap_model_name}' AS policy_cheap_model_name,
      job.definition #>> '{selection,strong_model_name}' AS policy_strong_model_name,
      (job.definition #>> '{runtime,lease_ms}')::bigint AS lease_ms,
      capacity.available_active_job_slots,
      min(CASE WHEN job.status IN ('running', 'cancel_requested') AND (job.leased_until IS NULL OR job.leased_until < now()) THEN 0 ELSE 1 END) AS retry_rank,
      min(job.created_at) AS first_created_at,
      min(job.id) AS first_job_id
    FROM job_contracts job
    CROSS JOIN policy p
    JOIN otlet.model_claim_capacity capacity
      ON capacity.model_name = job.selected_model ->> 'name'
    WHERE (
        job.status = 'queued'
        OR (
          job.status = 'running'
          AND (job.leased_until IS NULL OR job.leased_until < now())
          AND job.attempts < p.max_attempts
        )
        OR (
          job.status = 'cancel_requested'
          AND (job.leased_until IS NULL OR job.leased_until < now())
          AND job.attempts < p.max_attempts
        )
      )
      AND capacity.available_active_job_slots > 0
      AND (
        claim_jobs.requested_model_name IS NULL
        OR job.selected_model ->> 'name' = claim_jobs.requested_model_name
      )
      AND CASE job.execution_mode
        WHEN 'evaluation' THEN true
        ELSE otlet.source_fields_are_allowed(
          job.input,
          job.definition #> '{task,input_shaping}'
        )
      END
      AND CASE job.execution_mode
        WHEN 'evaluation' THEN true
        ELSE otlet.source_query_contract_error(
          job.definition #> '{source,query_contract}',
          true
        ) IS NULL
      END
      AND (
        claim_jobs.requested_portable_claim_contract IS NULL
        OR COALESCE((otlet.portable_runtime_option_status(
          job.definition,
          job.selected_model,
          claim_jobs.requested_portable_claim_contract
        ) ->> 'compatible')::boolean, false)
      )
      AND (
        job.execution_mode = 'evaluation'
        OR job.workload_revision_hash = job.active_workload_revision_hash
      )
    GROUP BY
      job.task_name,
      job.workload_revision_hash,
      job.execution_mode,
      job.selected_model,
      job.definition #>> '{selection,cheap_model_name}',
      job.definition #>> '{selection,strong_model_name}',
      job.definition #>> '{runtime,lease_ms}',
      capacity.available_active_job_slots
  ),
  selected_task AS (
    SELECT e.*
    FROM eligible_tasks e
    CROSS JOIN policy p
    ORDER BY
      CASE
        WHEN COALESCE(p.task_cursor, '') = '' THEN 0
        WHEN e.task_name > p.task_cursor THEN 0
        ELSE 1
      END,
      e.retry_rank,
      e.task_name,
      e.first_created_at,
      e.first_job_id
    LIMIT 1
  ),
  same_model_tasks AS (
    SELECT
      e.*,
      row_number() OVER (
        ORDER BY
          CASE
            WHEN COALESCE(p.task_cursor, '') = '' THEN 0
            WHEN e.task_name > p.task_cursor THEN 0
            ELSE 1
          END,
          e.retry_rank,
          e.task_name,
          e.first_created_at,
          e.first_job_id
      ) AS task_rank
    FROM eligible_tasks e
    JOIN selected_task f
      ON f.model_name = e.model_name
     AND f.artifact_path IS NOT DISTINCT FROM e.artifact_path
     AND f.policy_cheap_model_name IS NOT DISTINCT FROM e.policy_cheap_model_name
     AND f.policy_strong_model_name IS NOT DISTINCT FROM e.policy_strong_model_name
     AND f.lease_ms = e.lease_ms
    CROSS JOIN policy p
  ),
  locked_production_tasks AS MATERIALIZED (
    SELECT task.*, revision.definition
    FROM same_model_tasks task
    JOIN otlet.workload_revision_heads head
      ON head.task_name = task.task_name
     AND head.active_workload_revision_hash = task.workload_revision_hash
    JOIN otlet.workload_revisions revision
      ON revision.task_name = task.task_name
     AND revision.workload_revision_hash = task.workload_revision_hash
    WHERE task.execution_mode = 'production'
    ORDER BY task.task_rank
    FOR UPDATE OF head
  ),
  evaluation_tasks AS MATERIALIZED (
    SELECT task.*, revision.definition
    FROM same_model_tasks task
    JOIN otlet.workload_revision_heads head
      ON head.task_name = task.task_name
    JOIN otlet.tasks task_state
      ON task_state.name = task.task_name
     AND task_state.lifecycle_state = 'active'
    JOIN otlet.workload_revisions revision
      ON revision.task_name = task.task_name
     AND revision.workload_revision_hash = task.workload_revision_hash
    WHERE task.execution_mode = 'evaluation'
    ORDER BY task.task_rank
    FOR UPDATE OF head
  ),
  locked_tasks AS MATERIALIZED (
    SELECT * FROM locked_production_tasks
    UNION ALL
    SELECT * FROM evaluation_tasks
  ),
  guarded_tasks AS MATERIALIZED (
    SELECT task.*
    FROM locked_tasks task
    WHERE CASE task.execution_mode
      WHEN 'evaluation' THEN true
      ELSE otlet.workload_source_contract_guard(task.definition)::text = ''
    END
  ),
  ranked_candidates AS (
    SELECT
      job.id,
      job.task_name,
      job.workload_revision_hash,
      (job.definition #>> '{runtime,lease_ms}')::bigint
        * interval '1 millisecond' AS lease_interval,
      f.task_rank,
      row_number() OVER (
        PARTITION BY job.task_name
        ORDER BY
          CASE WHEN job.status IN ('running', 'cancel_requested') AND (job.leased_until IS NULL OR job.leased_until < now()) THEN 0 ELSE 1 END,
          job.created_at,
          job.id
      ) AS task_job_rank
    FROM job_contracts job
    JOIN guarded_tasks f
      ON f.task_name = job.task_name
     AND f.workload_revision_hash = job.workload_revision_hash
     AND f.execution_mode = job.execution_mode
     AND f.model_name = job.selected_model ->> 'name'
     AND f.artifact_path IS NOT DISTINCT FROM job.selected_model ->> 'artifact_path'
    CROSS JOIN policy p
    WHERE (
        job.status = 'queued'
        OR (
          job.status = 'running'
          AND (job.leased_until IS NULL OR job.leased_until < now())
          AND job.attempts < p.max_attempts
        )
        OR (
          job.status = 'cancel_requested'
          AND (job.leased_until IS NULL OR job.leased_until < now())
          AND job.attempts < p.max_attempts
        )
      )
      AND CASE job.execution_mode
        WHEN 'evaluation' THEN true
        ELSE otlet.source_fields_are_allowed(
          job.input,
          job.definition #> '{task,input_shaping}'
        )
      END
      AND (
        job.execution_mode = 'evaluation'
        OR job.workload_revision_hash = job.active_workload_revision_hash
      )
  ),
  claimable AS (
    SELECT
      j.id,
      candidate.task_name,
      candidate.lease_interval,
      candidate.task_rank,
      candidate.task_job_rank
    FROM otlet.jobs j
    JOIN ranked_candidates candidate ON candidate.id = j.id
    CROSS JOIN policy p
    WHERE (
        j.status = 'queued'
        OR (
          j.status = 'running'
          AND (j.leased_until IS NULL OR j.leased_until < now())
          AND j.attempts < p.max_attempts
        )
        OR (
          j.status = 'cancel_requested'
          AND (j.leased_until IS NULL OR j.leased_until < now())
          AND j.attempts < p.max_attempts
        )
      )
      AND j.task_name = candidate.task_name
      AND j.workload_revision_hash = candidate.workload_revision_hash
      AND EXISTS (
        SELECT 1
        FROM guarded_tasks task
        JOIN job_contracts job
          ON job.id = j.id
         AND job.task_name = task.task_name
         AND job.workload_revision_hash = task.workload_revision_hash
         AND job.execution_mode = task.execution_mode
        WHERE task.task_name = candidate.task_name
          AND task.workload_revision_hash = candidate.workload_revision_hash
          AND CASE job.execution_mode
            WHEN 'evaluation' THEN true
            ELSE otlet.source_fields_are_allowed(
              j.input,
              job.definition #> '{task,input_shaping}'
            )
          END
      )
    ORDER BY
      candidate.task_job_rank,
      candidate.task_rank
    FOR UPDATE OF j SKIP LOCKED
    LIMIT COALESCE((
      SELECT LEAST(p.batch_size::bigint, task.available_active_job_slots)
      FROM policy p
      CROSS JOIN selected_task task
    ), 0)
  ),
  advance_cursor AS (
    UPDATE otlet.production_policy p
    SET worker_claim_task_cursor = (
      SELECT task_name
      FROM claimable
      ORDER BY task_job_rank DESC, task_rank DESC
      LIMIT 1
    )
    WHERE p.name = 'default'
      AND EXISTS (SELECT 1 FROM claimable)
    RETURNING p.worker_claim_task_cursor
  ),
  updated AS (
    UPDATE otlet.jobs j
    SET status = CASE WHEN j.status = 'cancel_requested' THEN 'cancel_requested' ELSE 'running' END,
        attempts = attempts + 1,
        leased_until = now() + claimable.lease_interval,
        claim_token = gen_random_uuid()::text,
        terminal_claim_token = NULL,
        terminal_request_hash = NULL,
        error = CASE WHEN j.status = 'cancel_requested' THEN j.error ELSE NULL END,
        started_at = now(),
        finished_at = NULL
    FROM claimable
    CROSS JOIN advance_cursor
    WHERE j.id = claimable.id
    RETURNING j.*
  )
  SELECT updated.*
  FROM updated
  JOIN claimable ON claimable.id = updated.id
  CROSS JOIN (SELECT count(*) FROM rejected_claim_input) rejected
  ORDER BY claimable.task_rank, claimable.task_job_rank;
END;
$$;

CREATE FUNCTION otlet.renew_job_leases(
  job_ids bigint[],
  expected_claim_tokens text[]
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  claim_count integer := COALESCE(cardinality(renew_job_leases.job_ids), 0);
  locked_count bigint;
  valid_count bigint;
  renewed_count bigint := 0;
  updated_count bigint;
  claim_row record;
BEGIN
  IF claim_count <> COALESCE(cardinality(renew_job_leases.expected_claim_tokens), 0) THEN
    RAISE EXCEPTION 'otlet job lease renewal arrays must have equal length';
  END IF;
  IF claim_count = 0 THEN
    RETURN 0;
  END IF;
  IF claim_count > 128 THEN
    RAISE EXCEPTION 'otlet can renew at most 128 job leases at once';
  END IF;
  IF (
    SELECT count(DISTINCT job_id)
    FROM unnest(renew_job_leases.job_ids) job_id
  ) <> claim_count THEN
    RETURN 0;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
  PERFORM 1
  FROM unnest(
    renew_job_leases.job_ids,
    renew_job_leases.expected_claim_tokens
  ) claim(job_id, claim_token)
  JOIN otlet.jobs j
    ON j.id = claim.job_id
   AND j.claim_token = claim.claim_token
   AND j.status IN ('running', 'cancel_requested')
  ORDER BY j.id
  FOR UPDATE OF j;
  GET DIAGNOSTICS locked_count = ROW_COUNT;
  IF locked_count <> claim_count THEN
    RETURN 0;
  END IF;

  WITH live_claims AS MATERIALIZED (
    SELECT j.id, j.execution_mode, revision.definition
    FROM unnest(
      renew_job_leases.job_ids,
      renew_job_leases.expected_claim_tokens
    ) claim(job_id, claim_token)
    JOIN otlet.jobs j
      ON j.id = claim.job_id
     AND j.claim_token = claim.claim_token
     AND j.status IN ('running', 'cancel_requested')
    JOIN otlet.workload_revisions revision
      ON revision.workload_revision_hash = j.workload_revision_hash
     AND revision.task_name = j.task_name
    WHERE j.leased_until IS NOT NULL
      AND j.leased_until >= clock_timestamp()
      AND CASE j.execution_mode
        WHEN 'evaluation' THEN true
        ELSE otlet.source_query_contract_error(
          revision.definition #> '{source,query_contract}',
          true
        ) IS NULL
      END
  ), guarded_claims AS MATERIALIZED (
    SELECT live_claims.id
    FROM live_claims
    WHERE CASE live_claims.execution_mode
      WHEN 'evaluation' THEN true
      ELSE otlet.workload_source_contract_guard(live_claims.definition)::text = ''
    END
  )
  SELECT count(*) INTO valid_count
  FROM guarded_claims;
  IF valid_count <> claim_count THEN
    RETURN 0;
  END IF;

  -- ponytail: Policy caps batches at 128, so ordered row renewal stays bounded
  FOR claim_row IN
    SELECT
      j.id,
      claim.claim_token,
      (revision.definition #>> '{runtime,lease_ms}')::bigint
        * interval '1 millisecond' AS lease_interval
    FROM unnest(
      renew_job_leases.job_ids,
      renew_job_leases.expected_claim_tokens
    ) claim(job_id, claim_token)
    JOIN otlet.jobs j
      ON j.id = claim.job_id
     AND j.claim_token = claim.claim_token
     AND j.status IN ('running', 'cancel_requested')
    JOIN otlet.workload_revisions revision
      ON revision.task_name = j.task_name
     AND revision.workload_revision_hash = j.workload_revision_hash
    ORDER BY j.id
  LOOP
    UPDATE otlet.jobs j
    SET leased_until = clock_timestamp() + claim_row.lease_interval
    WHERE j.id = claim_row.id
      AND j.claim_token = claim_row.claim_token
      AND j.status IN ('running', 'cancel_requested');
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    IF updated_count <> 1 THEN
      RAISE EXCEPTION 'otlet lost job % during lease renewal', claim_row.id;
    END IF;
    renewed_count := renewed_count + 1;
  END LOOP;
  RETURN renewed_count;
END;
$$;

CREATE FUNCTION otlet.renew_job_lease(
  job_id bigint,
  expected_claim_token text
) RETURNS TABLE (
  status text,
  leased_until timestamptz
)
LANGUAGE plpgsql
AS $$
BEGIN
  IF otlet.renew_job_leases(
    ARRAY[renew_job_lease.job_id],
    ARRAY[renew_job_lease.expected_claim_token]
  ) <> 1 THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT j.status, j.leased_until
  FROM otlet.jobs j
  WHERE j.id = renew_job_lease.job_id
    AND j.claim_token = renew_job_lease.expected_claim_token
    AND j.status IN ('running', 'cancel_requested');
END;
$$;

CREATE FUNCTION otlet.job_terminal_request_hash(
  operation text,
  request jsonb
) RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT otlet.identity_hash('job_terminal_request', jsonb_build_object(
    'operation', job_terminal_request_hash.operation,
    'request', job_terminal_request_hash.request
  ))
$$;

CREATE FUNCTION otlet.mark_job_started(
  job_id bigint,
  expected_claim_token text
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  claim_status text;
  v_id bigint;
  v_task_name text;
  v_subject_id text;
  model_name text;
BEGIN
  SELECT renewed.status
  INTO claim_status
  FROM otlet.renew_job_lease(
    mark_job_started.job_id,
    mark_job_started.expected_claim_token
  ) renewed;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- claim_jobs / insert_infer_now_job already stamp started_at; this only
  -- records the runtime slot + worker event for the claimed/running job.
  SELECT
    j.id,
    j.task_name,
    j.subject_id,
    COALESCE(
      j.routed_model_name,
      revision.definition #>> '{models,direct,name}'
    )
  INTO v_id, v_task_name, v_subject_id, model_name
  FROM otlet.jobs j
  JOIN otlet.workload_revisions revision
    ON revision.workload_revision_hash = j.workload_revision_hash
  WHERE j.id = mark_job_started.job_id
    AND j.claim_token = mark_job_started.expected_claim_token
    AND j.status = claim_status;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  -- Warn-only path: skip slot/event noise when the task row is missing.
  IF model_name IS NULL THEN
    RETURN false;
  END IF;

  PERFORM otlet.touch_runtime_slot(model_name, 'running', 1, NULL);
  PERFORM otlet.record_worker_event(
    'job_started',
    v_id,
    'linked_inproc',
    'otlet worker started job',
    jsonb_build_object(
      'task_name', v_task_name,
      'subject_id', v_subject_id,
      'model_name', model_name
    )
  );
  RETURN true;
END;
$$;
