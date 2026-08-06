log "Checking model-bound context budgets"

model_bound_context_contract=$(psql_exec -qAt <<'SQL' | tail -n 1
BEGIN;
SET LOCAL otlet.administrative_reason = 'model-bound context budget proof';

CREATE TEMP TABLE model_bound_context_proof (
  immutable boolean NOT NULL DEFAULT false,
  invalid_limit_rejected boolean NOT NULL DEFAULT false,
  definition_limit_rejected boolean NOT NULL DEFAULT false
);
INSERT INTO model_bound_context_proof DEFAULT VALUES;

SELECT otlet.register_model(
  'model_bound_context_default',
  '/tmp/model-bound-context-default.gguf',
  repeat('8', 64),
  jsonb_build_object(
    'sha256', repeat('8', 64),
    'bytes', 1,
    'source', 'model-bound-context-proof',
    'revision', 'default-v1',
    'quantization', 'test',
    'license', 'test'
  ),
  1
) \g /dev/null

SELECT otlet.register_model(
  'model_bound_context_custom',
  '/tmp/model-bound-context-custom.gguf',
  repeat('9', 64),
  jsonb_build_object(
    'sha256', repeat('9', 64),
    'bytes', 1,
    'source', 'model-bound-context-proof',
    'revision', 'custom-v1',
    'quantization', 'test',
    'license', 'test',
    'context_window_tokens', 2048
  ),
  1
) \g /dev/null

DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.register_model(
      'model_bound_context_custom',
      '/tmp/model-bound-context-custom.gguf',
      repeat('9', 64),
      jsonb_build_object(
        'sha256', repeat('9', 64),
        'bytes', 1,
        'source', 'model-bound-context-proof',
        'revision', 'custom-v1',
        'quantization', 'test',
        'license', 'test',
        'context_window_tokens', 1024
      ),
      1
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%artifact identity is immutable%' THEN
      RAISE;
    END IF;
    UPDATE model_bound_context_proof SET immutable = true;
  END;

  BEGIN
    PERFORM otlet.register_model(
      'model_bound_context_invalid',
      '/tmp/model-bound-context-invalid.gguf',
      repeat('a', 64),
      jsonb_build_object(
        'sha256', repeat('a', 64),
        'bytes', 1,
        'source', 'model-bound-context-proof',
        'revision', 'invalid-v1',
        'quantization', 'test',
        'license', 'test',
        'context_window_tokens', 4097
      ),
      1
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%context_window_tokens must be an integer between 1 and 4096%' THEN
      RAISE;
    END IF;
    UPDATE model_bound_context_proof SET invalid_limit_rejected = true;
  END;
END;
$proof$;

SELECT otlet.create_task(
  task_name => 'model_bound_context_smaller',
  input_query => NULL,
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'model_bound_context_custom',
  runtime_options => '{
    "max_tokens":64,
    "inference_cache":false,
    "max_worker_rss_bytes":1048576,
    "context_window_tokens":1024
  }'::jsonb,
  input_shaping => '{"source_fields":["value"]}'::jsonb
) \g /dev/null

DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.create_task(
      task_name => 'model_bound_context_overflow',
      input_query => NULL,
      instruction => 'Return an empty object',
      output_schema => '{"type":"object"}'::jsonb,
      model_name => 'model_bound_context_custom',
      runtime_options => '{
        "max_tokens":64,
        "inference_cache":false,
        "max_worker_rss_bytes":1048576,
        "context_window_tokens":3072
      }'::jsonb,
      input_shaping => '{"source_fields":["value"]}'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%requested_context_window_exceeds_model_limit%' THEN
      RAISE;
    END IF;
    UPDATE model_bound_context_proof SET definition_limit_rejected = true;
  END;
END;
$proof$;

SELECT otlet.ensure_active_workload_revision('model_bound_context_smaller')
  \g /dev/null

WITH base_definition AS (
  SELECT
    otlet.current_workload_revision_definition(
      'model_bound_context_smaller'
    ) AS smaller
), definitions AS (
  SELECT
    smaller,
    jsonb_set(
      jsonb_set(
        smaller,
        '{task,runtime_options,context_window_tokens}',
        '3072'::jsonb
      ),
      '{runtime,effective_options,context_window_tokens}',
      '3072'::jsonb
    ) AS overflow
  FROM base_definition
), statuses AS (
  SELECT
    otlet.portable_runtime_option_status(
      definitions.smaller,
      jsonb_extract_path(definitions.smaller, 'models', 'direct'),
      jsonb_build_object(
        'runtime_contract', otlet.portable_reference_runtime_contract(),
        'model_artifact_hash',
          jsonb_extract_path_text(
            definitions.smaller, 'models', 'direct', 'artifact_hash'
          ),
        'model_artifact_bytes',
          jsonb_extract_path_text(
            definitions.smaller,
            'models',
            'direct',
            'artifact_identity',
            'bytes'
          )::bigint,
        'current_rss_bytes', 1,
        'default_llama_threads', 1
      )
    ) AS smaller,
    otlet.portable_runtime_option_status(
      definitions.overflow,
      jsonb_extract_path(definitions.overflow, 'models', 'direct'),
      jsonb_build_object(
        'runtime_contract', otlet.portable_reference_runtime_contract(),
        'model_artifact_hash',
          jsonb_extract_path_text(
            definitions.overflow, 'models', 'direct', 'artifact_hash'
          ),
        'model_artifact_bytes',
          jsonb_extract_path_text(
            definitions.overflow,
            'models',
            'direct',
            'artifact_identity',
            'bytes'
          )::bigint,
        'current_rss_bytes', 1,
        'default_llama_threads', 1
      )
    ) AS overflow,
    otlet.portable_runtime_option_status(
      definitions.smaller,
      jsonb_set(
        jsonb_extract_path(definitions.smaller, 'models', 'direct'),
        '{tested_context_window_tokens}',
        '1024'::jsonb
      ),
      jsonb_build_object(
        'runtime_contract', otlet.portable_reference_runtime_contract(),
        'model_artifact_hash',
          jsonb_extract_path_text(
            definitions.smaller, 'models', 'direct', 'artifact_hash'
          ),
        'model_artifact_bytes',
          jsonb_extract_path_text(
            definitions.smaller,
            'models',
            'direct',
            'artifact_identity',
            'bytes'
          )::bigint,
        'current_rss_bytes', 1,
        'default_llama_threads', 1
      )
    ) AS mismatch
  FROM definitions
)
SELECT concat_ws('|',
  (SELECT artifact_identity ->> 'context_window_tokens'
   FROM otlet.models WHERE name = 'model_bound_context_default'),
  (SELECT artifact_identity ->> 'context_window_tokens'
   FROM otlet.models WHERE name = 'model_bound_context_custom'),
  (SELECT tested_context_window_tokens
   FROM otlet.models WHERE name = 'model_bound_context_default'),
  (SELECT tested_context_window_tokens
   FROM otlet.models WHERE name = 'model_bound_context_custom'),
  otlet.workload_pack_artifact_identity('{}'::jsonb) ->>
    'context_window_tokens',
  otlet.workload_pack_artifact_identity(
    (SELECT artifact_identity FROM otlet.models
     WHERE name = 'model_bound_context_custom')
  ) ->> 'context_window_tokens',
  (SELECT immutable FROM model_bound_context_proof),
  (SELECT invalid_limit_rejected FROM model_bound_context_proof),
  (SELECT definition_limit_rejected FROM model_bound_context_proof),
  NOT EXISTS (
    SELECT 1 FROM otlet.tasks WHERE name = 'model_bound_context_overflow'
  ),
  NOT EXISTS (
    SELECT 1 FROM otlet.jobs WHERE task_name = 'model_bound_context_overflow'
  ),
  otlet.workload_model_definition('model_bound_context_custom') ->>
    'tested_context_window_tokens',
  jsonb_extract_path_text(statuses.smaller, 'requested', 'context_window_tokens'),
  jsonb_extract_path_text(statuses.smaller, 'effective', 'context_window_tokens'),
  jsonb_extract_path_text(
    statuses.smaller, 'envelope', 'tested_context_window_tokens'
  ),
  jsonb_extract_path_text(
    statuses.smaller, 'envelope', 'requested_context_window_tokens'
  ),
  jsonb_extract_path_text(
    statuses.smaller, 'envelope', 'effective_context_window_tokens'
  ),
  statuses.smaller ->> 'compatible',
  jsonb_extract_path_text(statuses.overflow, 'rejected', 'context_window_tokens'),
  jsonb_extract_path_text(
    statuses.overflow, 'envelope', 'tested_context_window_tokens'
  ),
  jsonb_extract_path_text(
    statuses.overflow, 'envelope', 'requested_context_window_tokens'
  ),
  jsonb_extract_path_text(
    statuses.overflow, 'envelope', 'effective_context_window_tokens'
  ),
  jsonb_extract_path_text(
    statuses.mismatch, 'rejected', 'model_context_window_tokens'
  ),
  otlet.classify_failure_reason(
    'failed', NULL, NULL, NULL,
    '{"stop_reason":"requested_context_window_exceeds_model_limit"}'::jsonb
  ),
  otlet.classify_failure_reason(
    'failed', NULL, NULL, NULL,
    '{"stop_reason":"request_memory_admission_rejected"}'::jsonb
  ),
  (SELECT count(*) FROM otlet.verify_invariants())
)
FROM statuses;
ROLLBACK;
SQL
)

[ "$model_bound_context_contract" = \
  "4096|2048|4096|2048|4096|2048|t|t|t|t|t|2048|1024|1024|2048|1024|1024|true|requested_context_window_exceeds_model_limit|2048|3072|2048|model_context_window_tokens_must_match_artifact_identity|otlet.failure.v1.runtime_configuration_rejected|otlet.failure.v1.resource_admission_rejected|0" ] || {
  echo "Model-bound context budget contract mismatch: $model_bound_context_contract" >&2
  exit 1
}

echo "model_bound_context_budget_contract=$model_bound_context_contract"

context_model_name="model_bound_context_native_2048"
context_physical_model_name="model_bound_context_native_2049"
context_success_task="model_bound_context_native_success"
context_physical_task="model_bound_context_native_physical"
context_prompt_overflow_task="model_bound_context_native_prompt_overflow"
context_limit_overflow_task="model_bound_context_native_limit_overflow"

psql_exec \
  -v source_model_name="$cheap_model_name" \
  -v context_model_name="$context_model_name" \
  -v context_physical_model_name="$context_physical_model_name" >/dev/null <<'SQL'
SELECT otlet.register_model(
  :'context_model_name',
  model.artifact_path,
  model.artifact_hash,
  model.artifact_identity || jsonb_build_object('context_window_tokens', 2048),
  1
)
FROM otlet.models model
WHERE model.name = :'source_model_name';

SELECT otlet.register_model(
  :'context_physical_model_name',
  model.artifact_path,
  model.artifact_hash,
  model.artifact_identity || jsonb_build_object('context_window_tokens', 2049),
  1
)
FROM otlet.models model
WHERE model.name = :'source_model_name';
SQL

for task_name in \
  "$context_success_task" \
  "$context_physical_task" \
  "$context_prompt_overflow_task" \
  "$context_limit_overflow_task"
do
  cleanup_task "$task_name"
done

psql_exec \
  -v task_name="$context_success_task" \
  -v model_name="$context_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $query$
    SELECT 'context-success'::text AS subject_id, '{}'::jsonb AS input
  $query$,
  'Return one JSON object only with top-level output and actions. output has ok true. actions is empty. No markdown.',
  '{"type":"object","required":["ok"],"additionalProperties":false,"properties":{"ok":{"const":true}}}'::jsonb,
  :'model_name',
  '{"reasoning":"off","max_tokens":32,"context_window_tokens":1024,"inference_cache":false,"max_worker_rss_bytes":7500000000}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_complete "$context_success_task" 1 300 1

native_success_contract="$(psql_value -v task_name="$context_success_task" <<'SQL'
WITH receipt AS (
  SELECT receipt.*, job.status AS job_status
  FROM otlet.inference_receipts receipt
  JOIN otlet.jobs job ON job.id = receipt.job_id
  WHERE job.task_name = :'task_name'
  ORDER BY receipt.id DESC
  LIMIT 1
)
SELECT concat_ws('|',
  receipt.job_status,
  receipt.status,
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_options_status', 'context_window', 'tested_context_window_tokens'
  ),
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_options_status', 'context_window', 'requested_context_window_tokens'
  ),
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_options_status', 'context_window', 'effective_context_window_tokens'
  ),
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_fingerprint', 'output_contract', 'context',
    'tested_context_window_tokens'
  ),
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_fingerprint', 'output_contract', 'context',
    'requested_context_window_tokens'
  ),
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_fingerprint', 'output_contract', 'context',
    'effective_context_window_tokens'
  ),
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_fingerprint', 'output_contract', 'context',
    'physical_context_window_tokens'
  ),
  receipt.trace_summary ->> 'context_window_tokens',
  jsonb_extract_path_text(
    receipt.trace_summary, 'memory', 'request_admission', 'decision'
  ),
  jsonb_extract_path_text(
    receipt.trace_summary, 'memory', 'request_admission', 'reason'
  ),
  (jsonb_extract_path_text(
    receipt.trace_summary, 'memory', 'request_admission', 'prompt_tokens'
  )::integer > 0),
  (jsonb_extract_path_text(
    receipt.trace_summary, 'memory', 'request_admission', 'max_generation_tokens'
  )::integer = 32),
  (jsonb_extract_path_text(
    receipt.trace_summary, 'memory', 'request_admission', 'projected_prompt_bytes'
  )::bigint > 0),
  (jsonb_extract_path_text(
    receipt.trace_summary, 'memory', 'request_admission', 'projected_decode_bytes'
  )::bigint > 0),
  (jsonb_extract_path_text(
    receipt.trace_summary,
    'memory', 'request_admission', 'projected_prompt_prefix_state_bytes'
  )::bigint = 536870912),
  NOT jsonb_extract_path_text(
    receipt.trace_summary, 'input_shaping', 'input_truncated'
  )::boolean,
  (SELECT count(*) FROM otlet.outputs output WHERE output.job_id = receipt.job_id)
)
FROM receipt;
SQL
)"
[ "$native_success_contract" = "complete|complete|2048|1024|1024|2048|1024|1024|2048|2048|allowed|prompt_decode_projection_fits_worker_rss_budget|t|t|t|t|t|t|1" ] || {
  echo "Native model-bound context success mismatch: $native_success_contract" >&2
  exit 1
}

psql_exec \
  -v task_name="$context_physical_task" \
  -v model_name="$context_physical_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $query$
    SELECT 'context-physical'::text AS subject_id, '{}'::jsonb AS input
  $query$,
  'Return one JSON object only with top-level output and actions. output has ok true. actions is empty. No markdown.',
  '{"type":"object","required":["ok"],"additionalProperties":false,"properties":{"ok":{"const":true}}}'::jsonb,
  :'model_name',
  '{"reasoning":"off","max_tokens":32,"context_window_tokens":1024,"inference_cache":false,"max_worker_rss_bytes":7500000000}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_complete "$context_physical_task" 1 300 1

native_physical_context_contract="$(psql_value -v task_name="$context_physical_task" <<'SQL'
WITH receipt AS (
  SELECT receipt.*, job.status AS job_status
  FROM otlet.inference_receipts receipt
  JOIN otlet.jobs job ON job.id = receipt.job_id
  WHERE job.task_name = :'task_name'
  ORDER BY receipt.id DESC
  LIMIT 1
)
SELECT concat_ws('|',
  receipt.job_status,
  receipt.status,
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_options_status', 'context_window', 'tested_context_window_tokens'
  ),
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_options_status', 'context_window', 'requested_context_window_tokens'
  ),
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_options_status', 'context_window', 'effective_context_window_tokens'
  ),
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_fingerprint', 'output_contract', 'context',
    'tested_context_window_tokens'
  ),
  jsonb_extract_path_text(
    receipt.trace_summary,
    'runtime_fingerprint', 'output_contract', 'context',
    'physical_context_window_tokens'
  ),
  receipt.trace_summary ->> 'context_window_tokens',
  NOT (receipt.trace_summary ->> 'model_cache_hit')::boolean,
  (SELECT count(*) FROM otlet.outputs output WHERE output.job_id = receipt.job_id)
)
FROM receipt;
SQL
)"
[ "$native_physical_context_contract" = \
  "complete|complete|2049|1024|1024|2049|2304|2304|t|1" ] || {
  echo "Native physical context contract mismatch: $native_physical_context_contract" >&2
  exit 1
}

psql_exec \
  -v task_name="$context_prompt_overflow_task" \
  -v model_name="$context_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $query$
    SELECT 'context-prompt-overflow'::text AS subject_id, '{}'::jsonb AS input
  $query$,
  'Return one JSON object only with top-level output and actions. output has ok true. actions is empty. No markdown.',
  '{"type":"object","required":["ok"],"additionalProperties":false,"properties":{"ok":{"const":true}}}'::jsonb,
  :'model_name',
  '{"reasoning":"off","max_tokens":32,"context_window_tokens":64,"inference_cache":false,"max_worker_rss_bytes":7500000000}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_failed "$context_prompt_overflow_task" 1 300 1

context_limit_definition_contract="$(psql_value <<'SQL'
CREATE TEMP TABLE context_limit_rejection(reason text NOT NULL);
DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.create_task(
      'model_bound_context_native_limit_overflow',
      $query$
        SELECT 'context-limit-overflow'::text AS subject_id, '{}'::jsonb AS input
      $query$,
      'Return one JSON object only with top-level output and actions. output has ok true. actions is empty. No markdown.',
      '{"type":"object","required":["ok"],"additionalProperties":false,"properties":{"ok":{"const":true}}}'::jsonb,
      'model_bound_context_native_2048',
      '{"reasoning":"off","max_tokens":32,"context_window_tokens":3072,"inference_cache":false,"max_worker_rss_bytes":7500000000}'::jsonb
    );
    RAISE EXCEPTION 'oversized context task definition was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%requested_context_window_exceeds_model_limit%' THEN
      RAISE;
    END IF;
    INSERT INTO context_limit_rejection
    VALUES ('requested_context_window_exceeds_model_limit');
  END;
END;
$proof$;
SELECT concat_ws('|',
  (SELECT reason FROM context_limit_rejection),
  NOT EXISTS (
    SELECT 1 FROM otlet.tasks
    WHERE name = 'model_bound_context_native_limit_overflow'
  ),
  NOT EXISTS (
    SELECT 1 FROM otlet.jobs
    WHERE task_name = 'model_bound_context_native_limit_overflow'
  )
);
SQL
)"
[ "$context_limit_definition_contract" = \
  "requested_context_window_exceeds_model_limit|t|t" ] || {
  echo "Native context definition rejection mismatch: $context_limit_definition_contract" >&2
  exit 1
}

native_rejection_contract="$(psql_value \
  -v prompt_task="$context_prompt_overflow_task" <<'SQL'
WITH failures AS (
  SELECT
    job.task_name,
    job.id AS job_id,
    job.status,
    job.failure_reason_code,
    receipt.trace_summary,
    receipt.trace_summary ->> 'stop_reason' AS stop_reason,
    receipt.failure_reason_code AS receipt_failure_reason_code
  FROM otlet.jobs job
  JOIN otlet.inference_receipts receipt ON receipt.job_id = job.id
  WHERE job.task_name = :'prompt_task'
)
SELECT concat_ws('|',
  (SELECT status FROM failures WHERE task_name = :'prompt_task'),
  (SELECT stop_reason IN (
    'prompt_exceeds_context_window',
    'prompt_and_generation_exceed_context_window'
  ) FROM failures WHERE task_name = :'prompt_task'),
  (SELECT failure_reason_code = 'otlet.failure.v1.runtime_configuration_rejected'
   FROM failures WHERE task_name = :'prompt_task'),
  (SELECT receipt_failure_reason_code = 'otlet.failure.v1.runtime_configuration_rejected'
   FROM failures WHERE task_name = :'prompt_task'),
  (SELECT count(*) FROM otlet.outputs output
   JOIN failures ON failures.job_id = output.job_id
   WHERE failures.task_name = :'prompt_task'),
  (SELECT jsonb_extract_path_text(
     trace_summary,
     'runtime_options_status', 'context_window', 'tested_context_window_tokens'
   ) FROM failures),
  (SELECT jsonb_extract_path_text(
     trace_summary,
     'runtime_options_status', 'context_window', 'requested_context_window_tokens'
   ) FROM failures),
  (SELECT jsonb_extract_path_text(
     trace_summary,
     'runtime_options_status', 'context_window', 'effective_context_window_tokens'
   ) FROM failures),
  (SELECT jsonb_extract_path_text(
     trace_summary, 'runtime_fingerprint', 'output_contract', 'context',
     'tested_context_window_tokens'
   ) FROM failures),
  (SELECT jsonb_extract_path_text(
     trace_summary, 'runtime_fingerprint', 'output_contract', 'context',
     'requested_context_window_tokens'
   ) FROM failures),
  (SELECT jsonb_extract_path_text(
     trace_summary, 'runtime_fingerprint', 'output_contract', 'context',
     'effective_context_window_tokens'
   ) FROM failures),
  (SELECT jsonb_extract_path_text(
     trace_summary, 'runtime_fingerprint', 'output_contract', 'context',
     'physical_context_window_tokens'
   ) FROM failures),
  (SELECT jsonb_extract_path_text(
     trace_summary, 'memory', 'request_admission', 'decision'
   ) = 'rejected' FROM failures),
  (SELECT jsonb_extract_path_text(
     trace_summary, 'memory', 'request_admission', 'reason'
   ) IN (
     'prompt_exceeds_context_window',
     'prompt_and_generation_exceed_context_window'
   ) FROM failures),
  (SELECT jsonb_extract_path_text(
     trace_summary, 'memory', 'request_admission', 'prompt_tokens'
   )::integer > 0 FROM failures),
  (SELECT jsonb_extract_path_text(
     trace_summary, 'memory', 'request_admission', 'projected_prompt_bytes'
   )::bigint > 0 FROM failures),
  (SELECT jsonb_extract_path_text(
     trace_summary, 'memory', 'request_admission', 'projected_decode_bytes'
   )::bigint > 0 FROM failures),
  (SELECT count(*) FROM otlet.verify_invariants()),
  (SELECT count(*) FROM otlet.runtime_status
   WHERE model_name = 'model_bound_context_native_2048'
     AND runtime_status = 'ready' AND slot_state = 'ready')
);
SQL
)"
[ "$native_rejection_contract" = \
  "failed|t|t|t|0|2048|64|64|2048|64|64|2048|t|t|t|t|t|0|1" ] || {
  echo "Native model-bound context rejection mismatch: $native_rejection_contract" >&2
  exit 1
}

echo "native_model_bound_context_success_contract=$native_success_contract"
echo "native_model_bound_context_physical_contract=$native_physical_context_contract"
echo "native_model_bound_context_definition_contract=$context_limit_definition_contract"
echo "native_model_bound_context_rejection_contract=$native_rejection_contract"
