CREATE OR REPLACE VIEW otlet.runtime_capability_status AS
WITH native_capability AS (
  SELECT otlet.linked_runtime_capabilities() AS contract
),
runtime_capabilities AS (
  SELECT
    'native:linked_inproc'::text AS runtime_id,
    'native'::text AS runtime_kind,
    NULL::text AS worker_id,
    NULL::text AS model_name,
    'linked_inproc'::text AS runtime_name,
    extension.extversion::text AS runtime_version,
    otlet.portable_json_hash(capability.contract) AS runtime_identity_hash,
    capability.contract
  FROM native_capability capability
  JOIN pg_catalog.pg_extension extension ON extension.extname = 'otlet'
  WHERE capability.contract IS NOT NULL

  UNION ALL

  SELECT
    'portable:' || worker.worker_id,
    'portable',
    worker.worker_id,
    worker.model_name,
    worker.runtime_name,
    worker.runtime_version,
    worker.runtime_identity_hash,
    worker.runtime_identity -> 'runtime_contract'
  FROM otlet.portable_workers worker
)
SELECT
  runtime_id,
  runtime_kind,
  worker_id,
  model_name,
  runtime_name,
  runtime_version,
  runtime_identity_hash,
  contract ->> 'version' AS capability_version,
  contract -> 'supported_runtime_options' AS supported_runtime_options,
  contract -> 'schema_behavior' AS schema_behavior,
  contract -> 'context_limits' AS context_limits,
  contract -> 'cancellation' AS cancellation,
  contract -> 'tracing' AS tracing,
  contract -> 'artifact_formats' AS artifact_formats,
  contract -> 'runtime_build' AS runtime_build,
  contract -> 'device_settings' AS device_settings,
  contract -> 'resource_admission' AS resource_admission,
  contract -> 'database_operations' AS database_operations
FROM runtime_capabilities;
