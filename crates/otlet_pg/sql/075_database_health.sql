CREATE TABLE otlet.application_latency_probe (
  name text PRIMARY KEY DEFAULT 'default' CHECK (name = 'default'),
  latency_ms numeric NOT NULL CHECK (latency_ms >= 0 AND latency_ms <= 3600000),
  measured_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE otlet.portable_worker_process_samples (
  runtime_name text NOT NULL CHECK (
    runtime_name ~ '^[a-z0-9][a-z0-9_.-]{0,127}$'
  ),
  worker_id text NOT NULL CHECK (
    worker_id ~ '^[a-z0-9][a-z0-9_-]{0,127}$'
  ),
  worker_process_rss_bytes bigint NOT NULL CHECK (
    worker_process_rss_bytes BETWEEN 1 AND 70368744177664
  ),
  sampled_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (runtime_name, worker_id)
);

CREATE FUNCTION otlet.record_application_latency(latency_ms numeric) RETURNS void
LANGUAGE sql
AS $$
  INSERT INTO otlet.application_latency_probe (name, latency_ms, measured_at)
  VALUES ('default', record_application_latency.latency_ms, now())
  ON CONFLICT (name) DO UPDATE
  SET latency_ms = EXCLUDED.latency_ms,
      measured_at = EXCLUDED.measured_at;
$$;

CREATE VIEW otlet.database_health_status AS
WITH policy AS (
  SELECT *
  FROM otlet.production_policy
  WHERE name = 'default'
),
queue AS (
  SELECT
    count(*) FILTER (WHERE status = 'queued')::bigint AS queued_jobs,
    COALESCE(
      sum(octet_length(input::text)) FILTER (WHERE status = 'queued'),
      0
    )::bigint AS queued_input_bytes
  FROM otlet.jobs
),
native_memory AS (
  SELECT CASE
    WHEN EXISTS (
      SELECT 1 FROM pg_catalog.pg_stat_activity WHERE backend_type = 'otlet worker'
    ) THEN COALESCE(max(worker_process_rss_bytes), 0)::bigint
    ELSE 0::bigint
  END AS worker_process_rss_bytes
  FROM otlet.runtime_slots
),
portable_memory AS (
  SELECT COALESCE(max(worker_process_rss_bytes), 0)::bigint AS worker_process_rss_bytes
  FROM otlet.portable_worker_process_samples
  WHERE sampled_at >= now() - interval '2 minutes'
),
connections AS (
  SELECT count(*)::bigint AS database_connections
  FROM pg_catalog.pg_stat_activity
  WHERE datname = current_database()
),
disk AS (
  SELECT pg_catalog.pg_database_size(current_database())::bigint AS database_size_bytes
),
wal AS (
  SELECT wal_bytes, stats_reset
  FROM pg_catalog.pg_stat_wal
),
storage AS (
  SELECT COALESCE(sum(pg_catalog.pg_total_relation_size(c.oid)), 0)::numeric AS otlet_storage_bytes
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'otlet'
    AND c.relkind IN ('r', 'p', 'm')
),
vacuum AS (
  SELECT
    current_setting('autovacuum')::boolean AS cluster_autovacuum_enabled,
    count(*) FILTER (
      WHERE c.reloptions @> ARRAY['autovacuum_enabled=false']
    )::bigint AS autovacuum_disabled_tables,
    COALESCE(sum(s.n_dead_tup), 0)::bigint AS dead_tuples,
    max(s.last_autovacuum) AS last_autovacuum_at
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_catalog.pg_stat_user_tables s ON s.relid = c.oid
  WHERE n.nspname = 'otlet'
    AND c.relkind IN ('r', 'p', 'm')
),
latency AS (
  SELECT latency_ms, measured_at
  FROM otlet.application_latency_probe
  WHERE name = 'default'
),
metrics AS (
  SELECT
    p.*,
    q.queued_jobs,
    q.queued_input_bytes,
    GREATEST(native.worker_process_rss_bytes, portable.worker_process_rss_bytes) AS worker_process_rss_bytes,
    connection.database_connections,
    disk.database_size_bytes,
    wal.wal_bytes AS wal_bytes_since_reset,
    wal.stats_reset AS wal_stats_reset_at,
    storage.otlet_storage_bytes,
    vacuum.cluster_autovacuum_enabled,
    vacuum.autovacuum_disabled_tables,
    vacuum.dead_tuples,
    vacuum.last_autovacuum_at,
    latency.latency_ms AS application_latency_ms,
    latency.measured_at AS application_latency_measured_at
  FROM policy p
  CROSS JOIN queue q
  CROSS JOIN native_memory native
  CROSS JOIN portable_memory portable
  CROSS JOIN connections connection
  CROSS JOIN disk
  CROSS JOIN wal
  CROSS JOIN storage
  CROSS JOIN vacuum
  LEFT JOIN latency ON true
),
checks AS (
  SELECT
    metrics.*,
    (
      health_max_queued_jobs IS NULL
      OR queued_jobs <= health_max_queued_jobs
    ) AS queue_healthy,
    (
      health_max_worker_rss_bytes IS NULL
      OR worker_process_rss_bytes <= health_max_worker_rss_bytes
    ) AS worker_memory_healthy,
    (
      health_max_connections IS NULL
      OR database_connections <= health_max_connections
    ) AS connections_healthy,
    (
      health_max_database_bytes IS NULL
      OR database_size_bytes <= health_max_database_bytes
    ) AS database_disk_healthy,
    (
      health_max_wal_bytes_since_reset IS NULL
      OR wal_bytes_since_reset <= health_max_wal_bytes_since_reset
    ) AS wal_healthy,
    (
      health_max_otlet_storage_bytes IS NULL
      OR otlet_storage_bytes <= health_max_otlet_storage_bytes
    ) AS otlet_storage_healthy,
    (
      NOT health_require_autovacuum
      OR (cluster_autovacuum_enabled AND autovacuum_disabled_tables = 0)
    ) AS autovacuum_healthy,
    (
      health_max_application_latency_ms IS NULL
      OR COALESCE((
        application_latency_ms <= health_max_application_latency_ms
        AND application_latency_measured_at >= now() - health_application_latency_max_age
      ), false)
    ) AS application_latency_healthy
  FROM metrics
)
SELECT
  name AS policy_name,
  queued_jobs,
  queued_input_bytes,
  max_queued_input_bytes_total AS queue_input_admission_limit_bytes,
  health_max_queued_jobs,
  worker_process_rss_bytes,
  health_max_worker_rss_bytes,
  database_connections,
  health_max_connections,
  database_size_bytes,
  health_max_database_bytes,
  wal_bytes_since_reset,
  wal_stats_reset_at,
  health_max_wal_bytes_since_reset,
  otlet_storage_bytes,
  health_max_otlet_storage_bytes,
  cluster_autovacuum_enabled,
  autovacuum_disabled_tables,
  dead_tuples,
  last_autovacuum_at,
  health_require_autovacuum,
  application_latency_ms,
  application_latency_measured_at,
  health_max_application_latency_ms,
  health_application_latency_max_age,
  queue_healthy,
  worker_memory_healthy,
  connections_healthy,
  database_disk_healthy,
  wal_healthy,
  otlet_storage_healthy,
  autovacuum_healthy,
  application_latency_healthy,
  queue_healthy
    AND worker_memory_healthy
    AND connections_healthy
    AND database_disk_healthy
    AND wal_healthy
    AND otlet_storage_healthy
    AND autovacuum_healthy
    AND application_latency_healthy AS claims_allowed,
  array_remove(ARRAY[
    CASE WHEN NOT queue_healthy THEN 'queue_pressure' END,
    CASE WHEN NOT worker_memory_healthy THEN 'worker_memory' END,
    CASE WHEN NOT connections_healthy THEN 'database_connections' END,
    CASE WHEN NOT database_disk_healthy THEN 'database_disk' END,
    CASE WHEN NOT wal_healthy THEN 'wal' END,
    CASE WHEN NOT otlet_storage_healthy THEN 'otlet_storage' END,
    CASE WHEN NOT autovacuum_healthy THEN 'autovacuum' END,
    CASE WHEN NOT application_latency_healthy THEN 'application_latency' END
  ], NULL) AS failed_checks,
  now() AS checked_at
FROM checks;

CREATE FUNCTION otlet.database_health_claims_allowed() RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  policy otlet.production_policy%ROWTYPE;
  claims_allowed boolean;
BEGIN
  SELECT * INTO STRICT policy
  FROM otlet.production_policy
  WHERE name = 'default';
  IF policy.health_max_queued_jobs IS NULL
     AND policy.health_max_worker_rss_bytes IS NULL
     AND policy.health_max_connections IS NULL
     AND policy.health_max_database_bytes IS NULL
     AND policy.health_max_wal_bytes_since_reset IS NULL
     AND policy.health_max_otlet_storage_bytes IS NULL
     AND NOT policy.health_require_autovacuum
     AND policy.health_max_application_latency_ms IS NULL THEN
    RETURN true;
  END IF;
  SELECT status.claims_allowed INTO claims_allowed
  FROM otlet.database_health_status status;
  RETURN COALESCE(claims_allowed, false);
END;
$$;
