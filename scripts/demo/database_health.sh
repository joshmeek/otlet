log "Checking database health protection"

database_health_contract="$(psql_value <<'SQL'
BEGIN;
CREATE TABLE public.otlet_health_application_probe (
  id integer PRIMARY KEY,
  value integer NOT NULL
);
INSERT INTO public.otlet_health_application_probe
SELECT i, i FROM generate_series(1, 2000) AS rows(i);

INSERT INTO otlet.models (name, artifact_path, artifact_hash, artifact_identity)
VALUES (
  'database_health_model',
  '/tmp/database-health-not-used.gguf',
  repeat('0', 64),
  jsonb_build_object(
    'sha256', repeat('0', 64),
    'bytes', 1,
    'source', 'database-health-proof',
    'revision', 'v1',
    'quantization', 'test',
    'license', 'test'
  )
);
INSERT INTO otlet.tasks (name, input_query, instruction, output_schema, model_name)
VALUES (
  'database_health_task',
  NULL,
  'Database health claim gate proof',
  '{"type":"object"}'::jsonb,
  'database_health_model'
);
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('database_health_task', 'health-1', '{}'::jsonb);

SELECT otlet.touch_runtime_slot('database_health_model', 'ready', 0, NULL) \g /dev/null
UPDATE otlet.runtime_slots
SET worker_process_rss_bytes = 1024
WHERE model_name = 'database_health_model';
SELECT otlet.record_application_latency(100) \g /dev/null
ALTER TABLE otlet.application_latency_probe SET (autovacuum_enabled = false);
UPDATE otlet.production_policy
SET health_max_queued_jobs = 0,
    health_max_worker_rss_bytes = 1,
    health_max_connections = 1,
    health_max_database_bytes = 1,
    health_max_wal_bytes_since_reset = 1,
    health_max_otlet_storage_bytes = 1,
    health_require_autovacuum = true,
    health_max_application_latency_ms = 1
WHERE name = 'default';

CREATE TEMP TABLE blocked_health AS
SELECT * FROM otlet.database_health_status;
CREATE TEMP TABLE blocked_claim AS
SELECT * FROM otlet.claim_jobs('database_health_model', 1);

CREATE FUNCTION pg_temp.application_query_latency_ms() RETURNS numeric
LANGUAGE plpgsql
AS $function$
DECLARE
  started_at timestamptz := clock_timestamp();
  result bigint;
BEGIN
  SELECT sum(value) INTO result FROM public.otlet_health_application_probe;
  IF result <> 2001000 THEN
    RAISE EXCEPTION 'application query returned an unexpected result';
  END IF;
  RETURN EXTRACT(epoch FROM clock_timestamp() - started_at) * 1000;
END;
$function$;
CREATE TEMP TABLE application_probe AS
SELECT pg_temp.application_query_latency_ms() AS latency_ms;

ALTER TABLE otlet.application_latency_probe RESET (autovacuum_enabled);
UPDATE otlet.production_policy
SET health_max_queued_jobs = NULL,
    health_max_worker_rss_bytes = NULL,
    health_max_connections = NULL,
    health_max_database_bytes = NULL,
    health_max_wal_bytes_since_reset = NULL,
    health_max_otlet_storage_bytes = NULL,
    health_require_autovacuum = false,
    health_max_application_latency_ms = 1000,
    health_application_latency_max_age = interval '1 minute'
WHERE name = 'default';
UPDATE otlet.application_latency_probe
SET latency_ms = 0,
    measured_at = now() - interval '1 hour'
WHERE name = 'default';
CREATE TEMP TABLE stale_latency_health AS
SELECT * FROM otlet.database_health_status;

UPDATE otlet.production_policy
SET health_max_application_latency_ms = NULL,
    health_application_latency_max_age = interval '5 minutes'
WHERE name = 'default';
SELECT otlet.record_application_latency((SELECT latency_ms FROM application_probe)) \g /dev/null

CREATE TEMP TABLE resumed_claim AS
SELECT * FROM otlet.claim_jobs('database_health_model', 1);
CREATE TEMP TABLE recovered_health AS
SELECT * FROM otlet.database_health_status;

SELECT array_to_string((SELECT failed_checks FROM blocked_health), ',') || '|' ||
       (SELECT claims_allowed FROM blocked_health)::text || '|' ||
       (SELECT count(*) FROM blocked_claim)::text || '|' ||
       (
         SELECT (
           queued_jobs = 1
           AND worker_process_rss_bytes >= 1024
           AND database_connections > 0
           AND database_size_bytes > 0
           AND wal_bytes_since_reset > 0
           AND otlet_storage_bytes > 0
           AND cluster_autovacuum_enabled
           AND autovacuum_disabled_tables > 0
           AND dead_tuples >= 0
           AND application_latency_ms = 100
         )::text
         FROM blocked_health
       ) || '|' ||
       (SELECT (latency_ms <= 250)::text FROM application_probe) || '|' ||
       (SELECT (failed_checks = ARRAY['application_latency'])::text FROM stale_latency_health) || '|' ||
       (SELECT count(*) FROM resumed_claim)::text || '|' ||
       (SELECT claims_allowed FROM recovered_health)::text || '|' ||
       (SELECT cardinality(failed_checks) FROM recovered_health)::text;
ROLLBACK;
SQL
)"
echo "database_health_contract=$database_health_contract"
[ "$database_health_contract" = "queue_pressure,worker_memory,database_connections,database_disk,wal,otlet_storage,autovacuum,application_latency|false|0|true|true|true|1|true|0" ] || {
  echo "Expected configured health failures to pause and recover claims without blocking the application query, got $database_health_contract" >&2
  exit 1
}
