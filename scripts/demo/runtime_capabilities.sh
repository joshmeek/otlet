log "Checking runtime capability discovery"

runtime_capability_contract="$(psql_exec -qAt -v model_name="$cheap_model_name" <<'SQL' | tail -n 1
BEGIN;

CREATE ROLE otlet_runtime_capability_worker
NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

CREATE TEMP TABLE runtime_capability_snapshot AS
SELECT
  (SELECT count(*) FROM otlet.portable_workers) AS workers,
  (SELECT count(*) FROM otlet.jobs) AS jobs,
  (SELECT count(*) FROM otlet.inference_receipts) AS receipts;

CREATE TEMP TABLE runtime_capability_fixture AS
SELECT :'model_name'::text AS model_name;

SELECT otlet.register_portable_worker(
  'runtime-capability-fixture',
  'otlet_runtime_capability_worker'::regrole,
  1,
  :'model_name',
  'otlet-portable-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null

CREATE FUNCTION pg_temp.reject_changed_capability() RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM otlet.register_portable_worker(
    'runtime-capability-changed',
    'otlet_runtime_capability_worker'::regrole,
    1,
    (SELECT model_name FROM runtime_capability_fixture),
    'otlet-portable-worker',
    '0.1.0',
    jsonb_build_object(
      'engine', 'llama.cpp',
      'runtime_contract', jsonb_set(
        otlet.portable_reference_runtime_contract(),
        '{context_limits,context_window_tokens}',
        '8192'::jsonb
      )
    )
  );
  RETURN false;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM = 'otlet portable runtime contract is incompatible';
END
$function$;

WITH capability AS (
  SELECT *,
    jsonb_typeof(supported_runtime_options) = 'array'
      AND jsonb_typeof(schema_behavior) = 'object'
      AND jsonb_typeof(context_limits) = 'object'
      AND jsonb_typeof(cancellation) = 'object'
      AND jsonb_typeof(tracing) = 'object'
      AND jsonb_typeof(artifact_formats) = 'object'
      AND jsonb_typeof(runtime_build) = 'object'
      AND jsonb_typeof(device_settings) = 'object'
      AND jsonb_typeof(resource_admission) = 'object' AS complete
  FROM otlet.runtime_capability_status
),
proof AS (
  SELECT
    (SELECT count(*) = 1 AND bool_and(complete)
     FROM capability WHERE runtime_kind = 'native') AS native_complete,
    (SELECT count(*) = 1 AND bool_and(complete)
     FROM capability WHERE runtime_id = 'portable:runtime-capability-fixture') AS portable_complete,
    (SELECT context_limits ->> 'context_window_tokens' = '4096'
       AND runtime_build ->> 'revision' = '94a220cd6'
       AND device_settings ->> 'policy' = 'cpu_only_n_gpu_layers_0'
       AND tracing ->> 'generation_trace' = 'optional'
     FROM capability WHERE runtime_kind = 'native') AS native_contract,
    (SELECT context_limits ->> 'context_window_tokens' = '4096'
       AND runtime_build ->> 'revision' = '94a220cd6'
       AND device_settings ->> 'policy' = 'cpu_only_n_gpu_layers_0'
       AND tracing ->> 'generation_trace' = 'unsupported_must_be_false'
     FROM capability WHERE runtime_id = 'portable:runtime-capability-fixture') AS portable_contract,
    pg_temp.reject_changed_capability() AS changed_capability_rejected,
    NOT pg_catalog.has_table_privilege(
      'public', 'otlet.runtime_capability_status', 'SELECT'
    ) AS public_denied,
    (SELECT count(*) = snapshot.workers + 1 FROM otlet.portable_workers)
      AND (SELECT count(*) = snapshot.jobs FROM otlet.jobs)
      AND (SELECT count(*) = snapshot.receipts FROM otlet.inference_receipts) AS state_preserved
  FROM runtime_capability_snapshot snapshot
)
SELECT native_complete::text || '|' ||
       portable_complete::text || '|' ||
       native_contract::text || '|' ||
       portable_contract::text || '|' ||
       changed_capability_rejected::text || '|' ||
       public_denied::text || '|' ||
       state_preserved::text
FROM proof;

ROLLBACK;
SQL
)"

echo "runtime_capability_contract=$runtime_capability_contract"
[ "$runtime_capability_contract" = "true|true|true|true|true|true|true" ] || {
  echo "Expected complete fenced native and portable runtime capabilities, got $runtime_capability_contract" >&2
  exit 1
}
