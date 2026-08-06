DO $migration$
DECLARE
  model record;
BEGIN
  FOR model IN
    SELECT name, artifact_identity -> 'context_window_tokens' AS tested_limit
    FROM otlet.models
    WHERE artifact_identity ? 'context_window_tokens'
  LOOP
    IF jsonb_typeof(model.tested_limit) IS DISTINCT FROM 'number'
       OR model.tested_limit::text !~ '^[1-9][0-9]{0,3}$'
       OR model.tested_limit::text::integer > 4096 THEN
      RAISE EXCEPTION
        'otlet model % context_window_tokens must be an integer between 1 and 4096',
        model.name;
    END IF;
  END LOOP;
END;
$migration$;

ALTER TABLE otlet.models
ADD COLUMN tested_context_window_tokens integer GENERATED ALWAYS AS (
  COALESCE((artifact_identity ->> 'context_window_tokens')::integer, 4096)
) STORED,
ADD CONSTRAINT models_tested_context_window_tokens_bound CHECK (
  tested_context_window_tokens BETWEEN 1 AND 4096
);

CREATE FUNCTION otlet.model_artifact_identity_with_context(identity jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT model_artifact_identity_with_context.identity || jsonb_build_object(
    'context_window_tokens',
    COALESCE(
      model_artifact_identity_with_context.identity -> 'context_window_tokens',
      '4096'::jsonb
    )
  );
$$;

CREATE OR REPLACE FUNCTION otlet.register_model(
  model_name text,
  artifact_path text,
  artifact_hash text,
  artifact_identity jsonb,
  max_active_jobs int DEFAULT 1
) RETURNS otlet.models
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  saved otlet.models%ROWTYPE;
  normalized_hash text := lower(register_model.artifact_hash);
  normalized_identity jsonb := otlet.model_artifact_identity_with_context(
    register_model.artifact_identity
  );
  saved_identity jsonb;
BEGIN
  IF jsonb_typeof(normalized_identity -> 'context_window_tokens')
       IS DISTINCT FROM 'number'
     OR normalized_identity ->> 'context_window_tokens'
       !~ '^[1-9][0-9]{0,3}$'
     OR (normalized_identity ->> 'context_window_tokens')::integer > 4096 THEN
    RAISE EXCEPTION
      'otlet model context_window_tokens must be an integer between 1 and 4096';
  END IF;

  SELECT model.*
  INTO saved
  FROM otlet.models model
  WHERE model.name = register_model.model_name
  FOR UPDATE;
  IF FOUND THEN
    saved_identity := otlet.model_artifact_identity_with_context(
      saved.artifact_identity
    );
    IF saved.artifact_path IS DISTINCT FROM register_model.artifact_path
       OR saved.artifact_hash IS DISTINCT FROM normalized_hash
       OR saved_identity IS DISTINCT FROM normalized_identity THEN
      RAISE EXCEPTION 'otlet model % artifact identity is immutable; register a new model name',
        register_model.model_name;
    END IF;
    UPDATE otlet.models model
    SET max_active_jobs = GREATEST(
      1,
      LEAST(COALESCE(register_model.max_active_jobs, 1), 1024)
    )
    WHERE model.name = register_model.model_name
    RETURNING * INTO saved;
    RETURN saved;
  END IF;

  INSERT INTO otlet.models (
    name,
    artifact_path,
    artifact_hash,
    artifact_identity,
    max_active_jobs
  ) VALUES (
    register_model.model_name,
    register_model.artifact_path,
    normalized_hash,
    normalized_identity,
    GREATEST(1, LEAST(COALESCE(register_model.max_active_jobs, 1), 1024))
  )
  RETURNING * INTO saved;
  RETURN saved;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.workload_model_definition(model_name text)
RETURNS jsonb
LANGUAGE sql
STABLE
STRICT
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT jsonb_build_object(
    'name', model.name,
    'artifact_path', model.artifact_path,
    'artifact_hash', model.artifact_hash,
    'artifact_identity', model.artifact_identity,
    'tested_context_window_tokens', model.tested_context_window_tokens,
    'max_active_jobs', model.max_active_jobs
  )
  FROM otlet.models model
  WHERE model.name = workload_model_definition.model_name;
$$;

CREATE OR REPLACE FUNCTION otlet.workload_pack_artifact_identity(identity jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT jsonb_build_object(
    'sha256', workload_pack_artifact_identity.identity -> 'sha256',
    'bytes', workload_pack_artifact_identity.identity -> 'bytes',
    'source', workload_pack_artifact_identity.identity -> 'source',
    'revision', workload_pack_artifact_identity.identity -> 'revision',
    'quantization', workload_pack_artifact_identity.identity -> 'quantization',
    'license', workload_pack_artifact_identity.identity -> 'license',
    'context_window_tokens', COALESCE(
      workload_pack_artifact_identity.identity -> 'context_window_tokens',
      '4096'::jsonb
    )
  );
$$;

DO $migration$
DECLARE
  definition text := pg_catalog.pg_get_functiondef(
    'otlet.workload_pack_shape_error(jsonb)'::regprocedure
  );
  rewritten text;
BEGIN
  rewritten := pg_catalog.replace(
    definition,
    $old$  artifact_keys constant text[] := ARRAY[
    'bytes', 'license', 'quantization', 'revision', 'sha256', 'source'
  ];$old$,
    $new$  artifact_keys constant text[] := ARRAY[
    'bytes', 'context_window_tokens', 'license', 'quantization', 'revision',
    'sha256', 'source'
  ];$new$
  );
  IF rewritten = definition THEN
    RAISE EXCEPTION 'otlet workload pack context identity key rewrite is incomplete';
  END IF;
  definition := rewritten;
  rewritten := pg_catalog.replace(
    definition,
    $old$FROM jsonb_object_keys(role_definition -> 'artifact_identity') key$old$,
    $new$FROM jsonb_object_keys(
           otlet.model_artifact_identity_with_context(
             role_definition -> 'artifact_identity'
           )
         ) key$new$
  );
  IF rewritten = definition THEN
    RAISE EXCEPTION 'otlet workload pack legacy context identity rewrite is incomplete';
  END IF;
  definition := rewritten;
  rewritten := pg_catalog.replace(
    definition,
    $old$      RETURN format('workload pack model role %s is invalid', role_name);
    END IF;
  END LOOP;$old$,
    $new$      RETURN format('workload pack model role %s is invalid', role_name);
    END IF;
    IF role_definition -> 'artifact_identity' ? 'context_window_tokens'
       AND (
         jsonb_typeof(
         role_definition #> '{artifact_identity,context_window_tokens}'
         ) IS DISTINCT FROM 'number'
         OR role_definition #>> '{artifact_identity,context_window_tokens}'
           !~ '^[1-9][0-9]{0,3}$'
       ) THEN
      RETURN format('workload pack model role %s is invalid', role_name);
    END IF;
    IF role_definition -> 'artifact_identity' ? 'context_window_tokens'
       AND (
      role_definition #>> '{artifact_identity,context_window_tokens}'
    )::integer > 4096 THEN
      RETURN format('workload pack model role %s is invalid', role_name);
    END IF;
  END LOOP;$new$
  );
  IF rewritten = definition THEN
    RAISE EXCEPTION 'otlet workload pack context identity validation rewrite is incomplete';
  END IF;
  EXECUTE rewritten;
END;
$migration$;

DO $migration$
DECLARE
  definition text := pg_catalog.pg_get_functiondef(
    'otlet.workload_pack_capability_report(jsonb)'::regprocedure
  );
  rewritten text;
BEGIN
  rewritten := pg_catalog.replace(
    definition,
    $old$required_model -> 'artifact_identity'$old$,
    $new$otlet.workload_pack_artifact_identity(
          required_model -> 'artifact_identity'
        )$new$
  );
  IF rewritten = definition THEN
    RAISE EXCEPTION 'otlet workload pack legacy capability rewrite is incomplete';
  END IF;
  EXECUTE rewritten;
END;
$migration$;

DO $migration$
DECLARE
  definition text := pg_catalog.pg_get_functiondef(
    'otlet.import_watch(jsonb,boolean)'::regprocedure
  );
  rewritten text;
BEGIN
  rewritten := pg_catalog.replace(
    definition,
    $old$m.artifact_identity = import_watch.definition -> 'model_artifact_identity'$old$,
    $new$otlet.model_artifact_identity_with_context(m.artifact_identity) =
      otlet.model_artifact_identity_with_context(
        import_watch.definition -> 'model_artifact_identity'
      )$new$
  );
  IF rewritten = definition THEN
    RAISE EXCEPTION 'otlet watch context identity rewrite is incomplete';
  END IF;
  EXECUTE rewritten;
END;
$migration$;

DO $migration$
DECLARE
  definition text := pg_catalog.pg_get_functiondef(
    'otlet.set_model_lifecycle(text,text,text,text,text,text)'::regprocedure
  );
  rewritten text;
BEGIN
  rewritten := pg_catalog.replace(
    definition,
    $old$replacement.artifact_identity = model.artifact_identity$old$,
    $new$otlet.model_artifact_identity_with_context(
           replacement.artifact_identity
         ) = otlet.model_artifact_identity_with_context(model.artifact_identity)$new$
  );
  IF rewritten = definition THEN
    RAISE EXCEPTION 'otlet model lifecycle context identity rewrite is incomplete';
  END IF;
  EXECUTE rewritten;
END;
$migration$;

CREATE FUNCTION otlet.model_context_window_error(
  runtime_options jsonb,
  model_names text[]
) RETURNS text
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  requested_text text;
  requested_tokens integer;
BEGIN
  IF NOT COALESCE(model_context_window_error.runtime_options, '{}'::jsonb)
       ? 'context_window_tokens' THEN
    RETURN NULL;
  END IF;
  requested_text := model_context_window_error.runtime_options ->>
    'context_window_tokens';
  IF jsonb_typeof(
       model_context_window_error.runtime_options -> 'context_window_tokens'
     ) IS DISTINCT FROM 'number'
     OR requested_text !~ '^[1-9][0-9]{0,3}$' THEN
    RETURN 'context_window_tokens_must_be_integer_1_to_4096';
  END IF;
  requested_tokens := requested_text::integer;
  IF requested_tokens > 4096 THEN
    RETURN 'context_window_tokens_must_be_integer_1_to_4096';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.models model
    WHERE model.name = ANY(model_context_window_error.model_names)
      AND model.tested_context_window_tokens < requested_tokens
  ) THEN
    RETURN 'requested_context_window_exceeds_model_limit';
  END IF;
  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.guard_model_context_window() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  runtime_options jsonb;
  model_names text[];
  validation_error text;
BEGIN
  IF TG_RELID = 'otlet.tasks'::regclass THEN
    runtime_options := NEW.runtime_options;
    model_names := ARRAY[NEW.model_name] || COALESCE((
      SELECT ARRAY[policy.cheap_model_name, policy.strong_model_name]
      FROM otlet.model_selection_policies policy
      WHERE policy.task_name = NEW.name
    ), ARRAY[]::text[]);
  ELSE
    SELECT task.runtime_options,
           ARRAY[task.model_name, NEW.cheap_model_name, NEW.strong_model_name]
    INTO runtime_options, model_names
    FROM otlet.tasks task
    WHERE task.name = NEW.task_name;
  END IF;
  validation_error := otlet.model_context_window_error(
    runtime_options,
    model_names
  );
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet %', validation_error;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER tasks_model_context_window
BEFORE INSERT OR UPDATE OF name, model_name, runtime_options ON otlet.tasks
FOR EACH ROW EXECUTE FUNCTION otlet.guard_model_context_window();

CREATE TRIGGER model_selection_policies_context_window
BEFORE INSERT OR UPDATE OF task_name, cheap_model_name, strong_model_name
ON otlet.model_selection_policies
FOR EACH ROW EXECUTE FUNCTION otlet.guard_model_context_window();

DO $migration$
DECLARE
  invalid_task text;
  validation_error text;
BEGIN
  SELECT task.name, checked.error
  INTO invalid_task, validation_error
  FROM otlet.tasks task
  LEFT JOIN otlet.model_selection_policies policy ON policy.task_name = task.name
  CROSS JOIN LATERAL (
    SELECT otlet.model_context_window_error(
      task.runtime_options,
      ARRAY[task.model_name, policy.cheap_model_name, policy.strong_model_name]
    ) AS error
  ) checked
  WHERE checked.error IS NOT NULL
  ORDER BY task.name
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'otlet task %: otlet %', invalid_task, validation_error;
  END IF;
END;
$migration$;

CREATE OR REPLACE FUNCTION otlet.portable_reference_runtime_contract()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT jsonb_build_object(
    'version', 'otlet_runtime_capabilities_v1',
    'supported_runtime_options', jsonb_build_array(
      'reasoning',
      'max_tokens',
      'max_attempt_ms',
      'inference_cache',
      'max_worker_rss_bytes',
      'context_window_tokens',
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
      'max_generation_tokens', 4096,
      'model_context_window_source',
        'artifact_identity.context_window_tokens',
      'task_context_window_option',
        'context_window_tokens_optional_lte_model_limit'
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
      'request_projection_policy', 'portable_prompt_decode_projection_v1',
      'process_slots', 1
    )
  );
$$;

CREATE OR REPLACE FUNCTION otlet.portable_runtime_option_status(
  workload_definition jsonb,
  selected_model jsonb,
  claim_contract jsonb
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
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
  runtime_contract jsonb := portable_runtime_option_status.claim_contract ->
    'runtime_contract';
  artifact_hash text := portable_runtime_option_status.claim_contract ->>
    'model_artifact_hash';
  artifact_bytes_text text := portable_runtime_option_status.claim_contract ->>
    'model_artifact_bytes';
  current_rss_text text := portable_runtime_option_status.claim_contract ->>
    'current_rss_bytes';
  default_llama_threads_text text :=
    portable_runtime_option_status.claim_contract ->> 'default_llama_threads';
  effective_attempt_text text :=
    portable_runtime_option_status.workload_definition #>>
      '{runtime,effective_max_attempt_ms}';
  artifact_context_text text := COALESCE(
    portable_runtime_option_status.selected_model #>>
      '{artifact_identity,context_window_tokens}',
    '4096'
  );
  tested_context_text text := COALESCE(
    portable_runtime_option_status.selected_model ->>
      'tested_context_window_tokens',
    portable_runtime_option_status.selected_model #>>
      '{artifact_identity,context_window_tokens}',
    '4096'
  );
  option_name text;
  artifact_bytes_valid boolean;
  current_rss_valid boolean;
  max_tokens_valid boolean;
  effective_attempt_valid boolean;
  max_worker_rss_valid boolean;
  option_value_valid boolean;
  default_llama_threads_valid boolean;
  artifact_context_valid boolean;
  tested_context_valid boolean;
  requested_context_valid boolean;
  effective_context_window_tokens jsonb;
  effective_llama_threads jsonb;
  effective_llama_batch_threads jsonb;
  effective jsonb;
  honored jsonb := '{}'::jsonb;
  defaulted jsonb := '{}'::jsonb;
  rejected jsonb := '{}'::jsonb;
BEGIN
  IF jsonb_typeof(requested) IS DISTINCT FROM 'object' THEN
    rejected := rejected ||
      jsonb_build_object('runtime_options', 'requested_options_must_be_object');
    requested := '{}'::jsonb;
  END IF;
  IF jsonb_typeof(supplied_effective) IS DISTINCT FROM 'object' THEN
    rejected := rejected ||
      jsonb_build_object('effective_options', 'effective_options_must_be_object');
    supplied_effective := '{}'::jsonb;
  END IF;
  artifact_bytes_valid := COALESCE(
    artifact_bytes_text ~ '^[1-9][0-9]{0,18}$',
    false
  );
  IF artifact_bytes_valid AND length(artifact_bytes_text) = 19 THEN
    artifact_bytes_valid := artifact_bytes_text <= '9223372036854775807';
  END IF;
  current_rss_valid := COALESCE(
    current_rss_text ~ '^[1-9][0-9]{0,18}$',
    false
  );
  IF current_rss_valid AND length(current_rss_text) = 19 THEN
    current_rss_valid := current_rss_text <= '9223372036854775807';
  END IF;
  default_llama_threads_valid := COALESCE(
    jsonb_typeof(
      portable_runtime_option_status.claim_contract -> 'default_llama_threads'
    ) = 'number'
      AND default_llama_threads_text ~ '^[1-9][0-9]{0,3}$',
    false
  );
  IF default_llama_threads_valid AND length(default_llama_threads_text) = 4 THEN
    default_llama_threads_valid := default_llama_threads_text <= '1024';
  END IF;
  tested_context_valid := COALESCE(
    tested_context_text ~ '^[1-9][0-9]{0,3}$',
    false
  );
  IF tested_context_valid THEN
    tested_context_valid := tested_context_text::integer <= 4096;
  END IF;
  artifact_context_valid := COALESCE(
    artifact_context_text ~ '^[1-9][0-9]{0,3}$',
    false
  );
  IF artifact_context_valid THEN
    artifact_context_valid := artifact_context_text::integer <= 4096;
  END IF;
  IF jsonb_typeof(portable_runtime_option_status.claim_contract)
       IS DISTINCT FROM 'object'
     OR runtime_contract IS DISTINCT FROM reference_contract THEN
    rejected := rejected ||
      jsonb_build_object('runtime_contract', 'runtime_contract_mismatch');
  END IF;
  IF artifact_hash IS NULL
     OR artifact_hash !~ '^[0-9a-f]{64}$'
     OR artifact_hash IS DISTINCT FROM
       portable_runtime_option_status.selected_model ->> 'artifact_hash'
     OR artifact_hash IS DISTINCT FROM
       portable_runtime_option_status.selected_model #>> '{artifact_identity,sha256}'
     OR NOT artifact_bytes_valid
     OR artifact_bytes_text IS DISTINCT FROM
       portable_runtime_option_status.selected_model #>> '{artifact_identity,bytes}' THEN
    rejected := rejected ||
      jsonb_build_object('model_artifact', 'model_artifact_identity_mismatch');
  END IF;
  IF NOT tested_context_valid
     OR NOT artifact_context_valid
     OR tested_context_text IS DISTINCT FROM artifact_context_text THEN
    rejected := rejected || jsonb_build_object(
      'model_context_window_tokens',
      'model_context_window_tokens_must_match_artifact_identity'
    );
  END IF;
  IF NOT current_rss_valid THEN
    rejected := rejected || jsonb_build_object(
      'current_rss_bytes',
      'current_rss_bytes_must_be_positive_integer'
    );
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
      'llama_batch_threads', 'context_window_tokens'
    ])
    ORDER BY key
  LOOP
    rejected := rejected ||
      jsonb_build_object(option_name, 'unsupported_runtime_option');
  END LOOP;

  IF supplied_effective ? 'reasoning'
     AND (
       jsonb_typeof(supplied_effective -> 'reasoning') IS DISTINCT FROM 'string'
       OR supplied_effective ->> 'reasoning' NOT IN ('on', 'off')
     ) THEN
    rejected := rejected ||
      jsonb_build_object('reasoning', 'reasoning_must_be_on_or_off');
  END IF;
  max_tokens_valid := NOT supplied_effective ? 'max_tokens';
  IF NOT max_tokens_valid THEN
    max_tokens_valid :=
      jsonb_typeof(supplied_effective -> 'max_tokens') = 'number'
      AND supplied_effective ->> 'max_tokens' ~ '^[1-9][0-9]{0,3}$';
    IF max_tokens_valid AND length(supplied_effective ->> 'max_tokens') = 4 THEN
      max_tokens_valid := supplied_effective ->> 'max_tokens' <= '4096';
    END IF;
  END IF;
  IF NOT max_tokens_valid THEN
    rejected := rejected || jsonb_build_object(
      'max_tokens',
      'max_tokens_must_be_integer_1_to_4096'
    );
  END IF;
  effective_attempt_valid := COALESCE(
    effective_attempt_text ~ '^[1-9][0-9]{0,6}$',
    false
  );
  IF effective_attempt_valid AND length(effective_attempt_text) = 7 THEN
    effective_attempt_valid := effective_attempt_text <= '3600000';
  END IF;
  option_value_valid := COALESCE(
    NOT supplied_effective ? 'max_attempt_ms'
      OR supplied_effective ->> 'max_attempt_ms' ~ '^[0-9]+$',
    false
  );
  IF NOT effective_attempt_valid OR NOT option_value_valid THEN
    rejected := rejected || jsonb_build_object(
      'max_attempt_ms',
      'max_attempt_ms_must_be_non_negative_integer'
    );
  END IF;
  IF NOT requested ? 'inference_cache'
     OR jsonb_typeof(requested -> 'inference_cache') IS DISTINCT FROM 'boolean'
     OR requested -> 'inference_cache' <> 'false'::jsonb
     OR supplied_effective -> 'inference_cache' IS DISTINCT FROM 'false'::jsonb THEN
    rejected := rejected || jsonb_build_object(
      'inference_cache',
      'inference_cache_must_be_explicitly_false'
    );
  END IF;
  max_worker_rss_valid := supplied_effective ? 'max_worker_rss_bytes'
    AND jsonb_typeof(supplied_effective -> 'max_worker_rss_bytes') = 'number'
    AND supplied_effective ->> 'max_worker_rss_bytes' ~ '^[1-9][0-9]{0,13}$';
  IF max_worker_rss_valid
     AND length(supplied_effective ->> 'max_worker_rss_bytes') = 14 THEN
    max_worker_rss_valid :=
      supplied_effective ->> 'max_worker_rss_bytes' <= '70368744177664';
  END IF;
  IF NOT max_worker_rss_valid THEN
    rejected := rejected || jsonb_build_object(
      'max_worker_rss_bytes',
      'max_worker_rss_bytes_must_be_integer_1_to_70368744177664'
    );
  ELSIF current_rss_valid THEN
    IF current_rss_text::bigint >
         (supplied_effective ->> 'max_worker_rss_bytes')::bigint THEN
      rejected := rejected || jsonb_build_object(
        'max_worker_rss_bytes',
        'current_rss_exceeds_max_worker_rss_bytes'
      );
    ELSIF artifact_bytes_valid AND artifact_bytes_text::bigint >
        (supplied_effective ->> 'max_worker_rss_bytes')::bigint THEN
      rejected := rejected || jsonb_build_object(
        'max_worker_rss_bytes',
        'artifact_exceeds_max_worker_rss_bytes'
      );
    END IF;
  END IF;
  IF supplied_effective ? 'generation_trace'
     AND (
       jsonb_typeof(supplied_effective -> 'generation_trace')
         IS DISTINCT FROM 'boolean'
       OR supplied_effective -> 'generation_trace' <> 'false'::jsonb
     ) THEN
    rejected := rejected || jsonb_build_object(
      'generation_trace',
      'generation_trace_must_be_false'
    );
  END IF;

  requested_context_valid := NOT requested ? 'context_window_tokens';
  IF NOT requested_context_valid THEN
    requested_context_valid :=
      jsonb_typeof(requested -> 'context_window_tokens') = 'number'
      AND requested ->> 'context_window_tokens' ~ '^[1-9][0-9]{0,3}$';
    IF requested_context_valid THEN
      requested_context_valid :=
        (requested ->> 'context_window_tokens')::integer <= 4096;
    END IF;
  END IF;
  IF NOT requested_context_valid THEN
    rejected := rejected || jsonb_build_object(
      'context_window_tokens',
      'context_window_tokens_must_be_integer_1_to_4096'
    );
  ELSIF requested ? 'context_window_tokens'
        AND tested_context_valid
        AND (requested ->> 'context_window_tokens')::integer >
          tested_context_text::integer THEN
    rejected := rejected || jsonb_build_object(
      'context_window_tokens',
      'requested_context_window_exceeds_model_limit'
    );
  END IF;
  effective_context_window_tokens := CASE
    WHEN requested_context_valid
      AND requested ? 'context_window_tokens'
      AND tested_context_valid
      AND (requested ->> 'context_window_tokens')::integer <=
        tested_context_text::integer
      THEN requested -> 'context_window_tokens'
    WHEN tested_context_valid THEN to_jsonb(tested_context_text::integer)
    ELSE '0'::jsonb
  END;

  effective_llama_threads := CASE
    WHEN default_llama_threads_valid THEN
      to_jsonb(default_llama_threads_text::integer)
    ELSE '0'::jsonb
  END;
  FOREACH option_name IN ARRAY ARRAY['llama_threads', 'llama_batch_threads']
  LOOP
    option_value_valid := NOT supplied_effective ? option_name;
    IF NOT option_value_valid THEN
      option_value_valid :=
        jsonb_typeof(supplied_effective -> option_name) = 'number'
        AND supplied_effective ->> option_name ~ '^[0-9]{1,4}$';
      IF option_value_valid AND length(supplied_effective ->> option_name) = 4 THEN
        option_value_valid := supplied_effective ->> option_name <= '1024';
      END IF;
    END IF;
    IF NOT option_value_valid THEN
      rejected := rejected || jsonb_build_object(
        option_name,
        option_name || '_must_be_integer_0_to_1024'
      );
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
      WHEN effective_attempt_valid THEN to_jsonb(effective_attempt_text::bigint)
      ELSE '0'::jsonb
    END,
    'inference_cache', COALESCE(
      supplied_effective -> 'inference_cache',
      'false'::jsonb
    ),
    'max_worker_rss_bytes', COALESCE(
      supplied_effective -> 'max_worker_rss_bytes',
      '0'::jsonb
    ),
    'generation_trace', COALESCE(
      supplied_effective -> 'generation_trace',
      'false'::jsonb
    ),
    'llama_threads', effective_llama_threads,
    'llama_batch_threads', effective_llama_batch_threads,
    'context_window_tokens', effective_context_window_tokens
  );

  FOREACH option_name IN ARRAY ARRAY[
    'reasoning', 'max_tokens', 'max_attempt_ms', 'inference_cache',
    'max_worker_rss_bytes', 'generation_trace', 'llama_threads',
    'llama_batch_threads', 'context_window_tokens'
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
      'tested_context_window_tokens', CASE
        WHEN tested_context_valid THEN to_jsonb(tested_context_text::integer)
        ELSE 'null'::jsonb
      END,
      'requested_context_window_tokens', COALESCE(
        requested -> 'context_window_tokens',
        'null'::jsonb
      ),
      'effective_context_window_tokens', effective_context_window_tokens,
      'context_window_tokens', effective_context_window_tokens,
      'batch_tokens', reference_contract #> '{context_limits,batch_tokens}',
      'ubatch_tokens', reference_contract #> '{context_limits,ubatch_tokens}',
      'load_policy', reference_contract #> '{device_settings,load_policy}',
      'device_policy', reference_contract #> '{device_settings,policy}',
      'rss_policy', reference_contract #> '{resource_admission,rss_policy}',
      'default_llama_threads', CASE
        WHEN default_llama_threads_valid THEN
          to_jsonb(default_llama_threads_text::integer)
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

DO $migration$
DECLARE
  definition text := pg_catalog.pg_get_functiondef(
    'otlet.portable_claim_jobs(text,integer,text,text,bigint,integer,integer)'::regprocedure
  );
  rewritten text;
BEGIN
  rewritten := pg_catalog.replace(
    definition,
    $old$      'max_error_bytes', policy_row.max_error_bytes,
      'max_attempt_ms', (revision_definition #>> '{runtime,effective_max_attempt_ms}')::integer
$old$,
    $new$      'max_error_bytes', policy_row.max_error_bytes,
      'max_attempt_ms', (revision_definition #>> '{runtime,effective_max_attempt_ms}')::integer,
      'context_window', jsonb_build_object(
        'tested_context_window_tokens', runtime_options_status
          #> '{envelope,tested_context_window_tokens}',
        'requested_context_window_tokens', runtime_options_status
          #> '{envelope,requested_context_window_tokens}',
        'effective_context_window_tokens', runtime_options_status
          #> '{envelope,effective_context_window_tokens}'
      )
$new$
  );
  IF rewritten = definition THEN
    RAISE EXCEPTION 'otlet portable claim context evidence rewrite is incomplete';
  END IF;
  EXECUTE rewritten;
END;
$migration$;

CREATE OR REPLACE FUNCTION otlet.classify_failure_reason(
  failure_status text,
  selection_role text DEFAULT NULL,
  selection_reason text DEFAULT NULL,
  schema_validation_status text DEFAULT NULL,
  trace_summary jsonb DEFAULT '{}'::jsonb,
  error text DEFAULT NULL,
  runtime_name text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  classified text;
  stop_reason text := COALESCE(
    classify_failure_reason.trace_summary,
    '{}'::jsonb
  ) ->> 'stop_reason';
BEGIN
  IF classify_failure_reason.failure_status NOT IN (
    'failed', 'rejected', 'canceled'
  ) THEN
    RETURN NULL;
  END IF;
  IF classify_failure_reason.failure_status = 'canceled' THEN
    RETURN 'otlet.failure.v1.canceled';
  END IF;

  IF lower(btrim(COALESCE(classify_failure_reason.error, ''))) =
       'requested_context_window_exceeds_model_limit' THEN
    RETURN 'otlet.failure.v1.runtime_configuration_rejected';
  END IF;
  IF lower(btrim(COALESCE(classify_failure_reason.error, ''))) =
       'request_memory_admission_rejected' THEN
    RETURN 'otlet.failure.v1.resource_admission_rejected';
  END IF;
  classified := otlet.failure_reason_from_slug(classify_failure_reason.error);
  IF classified IS NOT NULL THEN
    RETURN classified;
  END IF;

  IF lower(btrim(COALESCE(stop_reason, ''))) =
       'requested_context_window_exceeds_model_limit' THEN
    RETURN 'otlet.failure.v1.runtime_configuration_rejected';
  END IF;
  IF lower(btrim(COALESCE(stop_reason, ''))) =
       'request_memory_admission_rejected' THEN
    RETURN 'otlet.failure.v1.resource_admission_rejected';
  END IF;
  classified := otlet.failure_reason_from_slug(stop_reason);
  IF classified IS NOT NULL THEN
    RETURN classified;
  END IF;

  classified := otlet.failure_reason_from_slug(
    classify_failure_reason.selection_reason
  );
  IF classified IS NOT NULL THEN
    RETURN classified;
  END IF;

  IF classify_failure_reason.failure_status = 'rejected' THEN
    RETURN 'otlet.failure.v1.decision_rejected';
  END IF;
  IF classify_failure_reason.schema_validation_status = 'failed' THEN
    RETURN 'otlet.failure.v1.output_validation_failed';
  END IF;
  IF classify_failure_reason.runtime_name IS NOT NULL THEN
    RETURN 'otlet.failure.v1.runtime_failed';
  END IF;
  RETURN 'otlet.failure.v1.unclassified';
END;
$$;

REVOKE EXECUTE ON FUNCTION otlet.register_model(
  text, text, text, jsonb, integer
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.model_artifact_identity_with_context(jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.model_context_window_error(jsonb,text[])
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_model_context_window() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.workload_model_definition(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.portable_reference_runtime_contract() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.portable_runtime_option_status(
  jsonb, jsonb, jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.workload_pack_artifact_identity(jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.workload_pack_shape_error(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.classify_failure_reason(
  text, text, text, text, jsonb, text, text
) FROM PUBLIC;
