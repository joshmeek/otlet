ALTER TABLE otlet.worker_events
ADD COLUMN claim_attempt_index integer CHECK (
  claim_attempt_index IS NULL OR claim_attempt_index > 0
),
ADD COLUMN claim_identity_hash text CHECK (
  claim_identity_hash IS NULL
  OR claim_identity_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
),
ADD COLUMN worker_identity_hash text CHECK (
  worker_identity_hash IS NULL
  OR worker_identity_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
);

CREATE FUNCTION otlet.bind_worker_event_identities() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  job_attempt_index integer;
  portable_claim_id bigint;
  portable_worker_id text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF ROW(
      NEW.job_id,
      NEW.claim_attempt_index,
      NEW.claim_identity_hash,
      NEW.worker_identity_hash
    ) IS DISTINCT FROM ROW(
      OLD.job_id,
      OLD.claim_attempt_index,
      OLD.claim_identity_hash,
      OLD.worker_identity_hash
    ) THEN
      RAISE EXCEPTION 'otlet worker event identities are immutable';
    END IF;
    RETURN NEW;
  END IF;

  NEW.claim_attempt_index := NULL;
  NEW.claim_identity_hash := NULL;
  NEW.worker_identity_hash := NULL;

  IF NEW.job_id IS NOT NULL THEN
    SELECT job.attempts
    INTO job_attempt_index
    FROM otlet.jobs job
    WHERE job.id = NEW.job_id;

    SELECT claim.id, claim.worker_id
    INTO portable_claim_id, portable_worker_id
    FROM otlet.portable_claims claim
    WHERE claim.job_id = NEW.job_id
      AND claim.attempt_index = job_attempt_index
    ORDER BY claim.id DESC
    LIMIT 1;

    IF job_attempt_index > 0 THEN
      NEW.claim_attempt_index := job_attempt_index;
      NEW.claim_identity_hash := otlet.identity_hash(
        'claim_correlation',
        jsonb_build_object(
          'job_id', NEW.job_id,
          'attempt_index', job_attempt_index
        )
      );
    END IF;
  END IF;

  NEW.worker_identity_hash := COALESCE(
    CASE WHEN portable_claim_id IS NOT NULL THEN otlet.identity_text_hash(
      'portable_worker',
      portable_worker_id
    ) END,
    CASE WHEN EXISTS (
      SELECT 1
      FROM pg_catalog.pg_stat_activity activity
      WHERE activity.pid = pg_catalog.pg_backend_pid()
        AND activity.backend_type = 'otlet worker'
    ) THEN NULLIF(current_setting('otlet.worker_identity_hash', true), '') END
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER worker_events_identities
BEFORE INSERT OR UPDATE OF
  job_id,
  claim_attempt_index,
  claim_identity_hash,
  worker_identity_hash
ON otlet.worker_events
FOR EACH ROW EXECUTE FUNCTION otlet.bind_worker_event_identities();

CREATE INDEX jobs_observability_started_idx
ON otlet.jobs (started_at DESC, id)
INCLUDE (task_name, workload_revision_hash, created_at)
WHERE execution_mode = 'production' AND started_at IS NOT NULL;

CREATE INDEX jobs_observability_finished_idx
ON otlet.jobs (finished_at DESC, id)
INCLUDE (task_name, workload_revision_hash, started_at)
WHERE execution_mode = 'production' AND finished_at IS NOT NULL;

CREATE INDEX inference_receipts_observability_finished_idx
ON otlet.inference_receipts (finished_at DESC, id)
INCLUDE (
  job_id,
  task_name,
  workload_revision_hash,
  schema_validation_status,
  failure_reason_code
);

CREATE INDEX semantic_materializations_stale_observability_idx
ON otlet.semantic_materializations (
  task_name,
  contract_hash,
  updated_at,
  id
)
WHERE stale;

CREATE INDEX maintenance_runs_kind_updated_idx
ON otlet.maintenance_runs (kind, updated_at DESC, id DESC);

CREATE OR REPLACE VIEW otlet.operational_event_log AS
WITH redacted AS (
SELECT
  event.id AS event_id,
  event.created_at,
  CASE event.event_type
    WHEN 'worker_started' THEN 'worker_started'
    WHEN 'worker_startup_failed' THEN 'worker_startup_failed'
    WHEN 'worker_batch_finished' THEN 'worker_batch_finished'
    WHEN 'job_started' THEN 'job_started'
    WHEN 'job_completed' THEN 'job_completed'
    WHEN 'job_failed' THEN 'job_failed'
    WHEN 'job_cancel_requested' THEN 'job_cancel_requested'
    WHEN 'job_cancel_observed' THEN 'job_cancel_observed'
    WHEN 'job_canceled' THEN 'job_canceled'
    WHEN 'expired_job_sweep' THEN 'expired_job_sweep'
    WHEN 'expired_cancel_requested_sweep' THEN 'expired_cancel_requested_sweep'
    WHEN 'queue_admission_suppressed' THEN 'queue_admission_suppressed'
    WHEN 'semantic_materialization_failed' THEN 'semantic_materialization_failed'
    WHEN 'model_admission_rejected' THEN 'model_admission_rejected'
    WHEN 'model_preload_failed' THEN 'model_preload_failed'
    WHEN 'model_preload_succeeded' THEN 'model_preload_succeeded'
    WHEN 'model_swap' THEN 'model_swap'
    WHEN 'model_unloaded' THEN 'model_unloaded'
    ELSE 'other'
  END AS event_type,
  CASE
    WHEN event.event_type IN (
      'worker_started',
      'worker_batch_finished',
      'job_started',
      'job_completed'
    ) THEN 'lifecycle'
    WHEN event.event_type IN (
      'job_cancel_requested',
      'job_cancel_observed',
      'job_canceled',
      'expired_cancel_requested_sweep'
    ) THEN 'cancellation'
    WHEN event.event_type IN (
      'job_failed',
      'semantic_materialization_failed',
      'model_preload_failed',
      'worker_startup_failed'
    ) THEN 'failure'
    WHEN event.event_type IN (
      'queue_admission_suppressed',
      'model_admission_rejected'
    ) THEN 'admission'
    WHEN event.event_type IN (
      'model_preload_succeeded',
      'model_swap',
      'model_unloaded'
    ) THEN 'runtime'
    WHEN event.event_type = 'expired_job_sweep' THEN 'recovery'
    ELSE 'other'
  END AS event_class,
  CASE
    WHEN event.event_type IN (
      'job_failed',
      'semantic_materialization_failed',
      'model_preload_failed',
      'worker_startup_failed'
    ) THEN 'error'
    WHEN event.event_type IN (
      'job_cancel_requested',
      'job_cancel_observed',
      'job_canceled',
      'expired_job_sweep',
      'expired_cancel_requested_sweep',
      'queue_admission_suppressed',
      'model_admission_rejected'
    ) THEN 'warning'
    ELSE 'info'
  END AS severity,
  CASE
    WHEN job.failure_reason_code IS NOT NULL THEN job.failure_reason_code
    WHEN event.event_type = 'queue_admission_suppressed'
      AND event.detail ->> 'reason' IN (
        'row_cap',
        'queue_depth_cap',
        'input_byte_cap',
        'task_queue_age_cap',
        'task_queued_input_byte_cap',
        'model_queued_input_byte_cap',
        'total_queued_input_byte_cap'
      ) THEN event.detail ->> 'reason'
    WHEN event.event_type = 'model_admission_rejected'
      THEN 'model_resource_admission'
    ELSE NULL
  END AS reason,
  event.job_id,
  CASE
    WHEN event.runtime_name IS NULL THEN NULL
    WHEN event.runtime_name = 'linked_inproc' THEN 'linked_inproc'
    WHEN event.runtime_name LIKE 'portable:%' THEN 'portable'
    ELSE 'other'
  END AS runtime_name,
  COALESCE(job.task_name, event_task.name) AS task_name,
  CASE
    WHEN event.event_type = 'worker_batch_finished'
      THEN batch_task.task_names
    WHEN COALESCE(job.task_name, event_task.name) IS NOT NULL
      THEN jsonb_build_array(COALESCE(job.task_name, event_task.name))
  END AS task_names,
  COALESCE(latest_receipt.model_name, job.routed_model_name, event_model.name)
    AS model_name,
  job.status,
  CASE WHEN event.detail ->> 'job_count' ~ '^[0-9]{1,18}$'
    THEN (event.detail ->> 'job_count')::bigint
  END AS job_count,
  CASE WHEN event.detail ->> 'completed_jobs' ~ '^[0-9]{1,18}$'
    THEN (event.detail ->> 'completed_jobs')::bigint
  END AS completed_jobs,
  CASE WHEN event.detail ->> 'failed_jobs' ~ '^[0-9]{1,18}$'
    THEN (event.detail ->> 'failed_jobs')::bigint
  END AS failed_jobs,
  CASE WHEN event.detail ->> 'batch_ms' ~ '^[0-9]{1,18}$'
    THEN (event.detail ->> 'batch_ms')::bigint
  END AS batch_ms,
  CASE WHEN event.detail ->> 'input_bytes' ~ '^[0-9]{1,18}$'
    THEN (event.detail ->> 'input_bytes')::bigint
  END AS input_bytes,
  CASE WHEN event.detail ->> 'limit_bytes' ~ '^[0-9]{1,18}$'
    THEN (event.detail ->> 'limit_bytes')::bigint
  END AS limit_bytes,
  event.message IS NOT NULL OR event.detail <> '{}'::jsonb
    AS evidence_redacted,
  job.workload_revision_hash,
  event.claim_attempt_index,
  event.claim_identity_hash,
  portable_claim.id AS portable_claim_id,
  COALESCE(receipt.receipt_ids, ARRAY[]::bigint[]) AS receipt_ids,
  event.worker_identity_hash,
  COALESCE(action.action_ids, ARRAY[]::bigint[]) AS action_ids,
  COALESCE(latest_receipt.selection_role, portable_claim.selection_role)
    AS selection_role
FROM otlet.worker_events event
LEFT JOIN otlet.jobs job ON job.id = event.job_id
LEFT JOIN otlet.tasks event_task
  ON event_task.name = event.detail ->> 'task_name'
LEFT JOIN LATERAL (
  SELECT jsonb_agg(task.name ORDER BY listed.ordinality) AS task_names
  FROM jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(event.detail -> 'task_names') = 'array'
      THEN event.detail -> 'task_names'
      ELSE '[]'::jsonb
    END
  ) WITH ORDINALITY listed(name, ordinality)
  JOIN otlet.tasks task ON task.name = listed.name
) batch_task ON event.event_type = 'worker_batch_finished'
LEFT JOIN LATERAL (
  SELECT claim.id, claim.selection_role
  FROM otlet.portable_claims claim
  WHERE claim.job_id = event.job_id
    AND claim.attempt_index = event.claim_attempt_index
  ORDER BY claim.id DESC
  LIMIT 1
) portable_claim ON true
LEFT JOIN LATERAL (
  SELECT array_agg(receipt.id ORDER BY receipt.attempt_index, receipt.id)
    AS receipt_ids
  FROM otlet.inference_receipts receipt
  WHERE receipt.job_id = event.job_id
    AND receipt.attempt_index = event.claim_attempt_index
) receipt ON true
LEFT JOIN LATERAL (
  SELECT array_agg(action.id ORDER BY action.id) AS action_ids
  FROM otlet.actions action
  JOIN otlet.inference_receipts receipt ON receipt.id = action.receipt_id
  WHERE action.job_id = event.job_id
    AND receipt.attempt_index = event.claim_attempt_index
) action ON true
LEFT JOIN LATERAL (
  SELECT receipt.model_name, receipt.selection_role
  FROM otlet.inference_receipts receipt
  WHERE receipt.job_id = event.job_id
    AND receipt.attempt_index = event.claim_attempt_index
  ORDER BY receipt.attempt_index DESC, receipt.id DESC
  LIMIT 1
) latest_receipt ON true
LEFT JOIN otlet.models event_model
  ON event_model.name = event.detail ->> 'model_name'
)
SELECT
  event_id,
  created_at,
  event_type,
  job_id,
  runtime_name,
  task_name,
  task_names,
  model_name,
  reason,
  status,
  job_count,
  completed_jobs,
  failed_jobs,
  batch_ms,
  input_bytes,
  limit_bytes,
  evidence_redacted,
  'otlet.observability.event.v1'::text AS event_schema,
  1::integer AS event_version,
  event_class,
  severity,
  workload_revision_hash,
  claim_attempt_index,
  claim_identity_hash,
  portable_claim_id,
  receipt_ids,
  worker_identity_hash,
  action_ids,
  selection_role
FROM redacted;

CREATE VIEW otlet.operational_observability_status_internal AS
WITH observation AS MATERIALIZED (
  SELECT statement_timestamp() AS observed_at
), windows(window_name, duration) AS (
  VALUES
    ('15m'::text, interval '15 minutes'),
    ('1h'::text, interval '1 hour'),
    ('24h'::text, interval '24 hours')
), revision_window AS MATERIALIZED (
  SELECT
    revision.task_name,
    revision.workload_revision_hash,
    window_spec.window_name,
    observed.observed_at - window_spec.duration AS window_started_at,
    observed.observed_at
  FROM otlet.workload_revisions revision
  CROSS JOIN windows window_spec
  CROSS JOIN observation observed
), timing AS MATERIALIZED (
  SELECT
    revision.task_name,
    revision.workload_revision_hash,
    revision.window_name,
    revision.window_started_at,
    revision.observed_at,
    count(job.id) FILTER (
      WHERE job.started_at >= revision.window_started_at
        AND job.started_at <= revision.observed_at
    )::bigint AS queue_samples,
    percentile_disc(0.50) WITHIN GROUP (
      ORDER BY GREATEST(
        extract(epoch FROM job.started_at - job.created_at) * 1000,
        0
      )
    ) FILTER (
      WHERE job.started_at >= revision.window_started_at
        AND job.started_at <= revision.observed_at
    ) AS queue_p50,
    percentile_disc(0.95) WITHIN GROUP (
      ORDER BY GREATEST(
        extract(epoch FROM job.started_at - job.created_at) * 1000,
        0
      )
    ) FILTER (
      WHERE job.started_at >= revision.window_started_at
        AND job.started_at <= revision.observed_at
    ) AS queue_p95,
    percentile_disc(0.99) WITHIN GROUP (
      ORDER BY GREATEST(
        extract(epoch FROM job.started_at - job.created_at) * 1000,
        0
      )
    ) FILTER (
      WHERE job.started_at >= revision.window_started_at
        AND job.started_at <= revision.observed_at
    ) AS queue_p99,
    max(GREATEST(
      extract(epoch FROM job.started_at - job.created_at) * 1000,
      0
    )) FILTER (
      WHERE job.started_at >= revision.window_started_at
        AND job.started_at <= revision.observed_at
    ) AS queue_max,
    count(job.id) FILTER (
      WHERE job.finished_at >= revision.window_started_at
        AND job.finished_at <= revision.observed_at
        AND job.started_at IS NOT NULL
    )::bigint AS run_samples,
    percentile_disc(0.50) WITHIN GROUP (
      ORDER BY GREATEST(
        extract(epoch FROM job.finished_at - job.started_at) * 1000,
        0
      )
    ) FILTER (
      WHERE job.finished_at >= revision.window_started_at
        AND job.finished_at <= revision.observed_at
        AND job.started_at IS NOT NULL
    ) AS run_p50,
    percentile_disc(0.95) WITHIN GROUP (
      ORDER BY GREATEST(
        extract(epoch FROM job.finished_at - job.started_at) * 1000,
        0
      )
    ) FILTER (
      WHERE job.finished_at >= revision.window_started_at
        AND job.finished_at <= revision.observed_at
        AND job.started_at IS NOT NULL
    ) AS run_p95,
    percentile_disc(0.99) WITHIN GROUP (
      ORDER BY GREATEST(
        extract(epoch FROM job.finished_at - job.started_at) * 1000,
        0
      )
    ) FILTER (
      WHERE job.finished_at >= revision.window_started_at
        AND job.finished_at <= revision.observed_at
        AND job.started_at IS NOT NULL
    ) AS run_p99,
    max(GREATEST(
      extract(epoch FROM job.finished_at - job.started_at) * 1000,
      0
    )) FILTER (
      WHERE job.finished_at >= revision.window_started_at
        AND job.finished_at <= revision.observed_at
        AND job.started_at IS NOT NULL
    ) AS run_max
  FROM revision_window revision
  LEFT JOIN otlet.jobs job
    ON job.task_name = revision.task_name
   AND job.workload_revision_hash = revision.workload_revision_hash
   AND job.execution_mode = 'production'
   AND (
     job.started_at BETWEEN revision.window_started_at AND revision.observed_at
     OR job.finished_at BETWEEN revision.window_started_at AND revision.observed_at
   )
  GROUP BY
    revision.task_name,
    revision.workload_revision_hash,
    revision.window_name,
    revision.window_started_at,
    revision.observed_at
), schema_status AS MATERIALIZED (
  SELECT
    revision.task_name,
    revision.workload_revision_hash,
    revision.window_name,
    revision.window_started_at,
    revision.observed_at,
    count(receipt.id) FILTER (
      WHERE receipt.schema_validation_status = 'failed'
    )::bigint AS rejected,
    count(receipt.id)::bigint AS checked
  FROM revision_window revision
  LEFT JOIN otlet.jobs job
    ON job.task_name = revision.task_name
   AND job.workload_revision_hash = revision.workload_revision_hash
   AND job.execution_mode = 'production'
  LEFT JOIN otlet.inference_receipts receipt
    ON receipt.job_id = job.id
   AND receipt.finished_at >= revision.window_started_at
   AND receipt.finished_at <= revision.observed_at
   AND receipt.schema_validation_status IS NOT NULL
  GROUP BY
    revision.task_name,
    revision.workload_revision_hash,
    revision.window_name,
    revision.window_started_at,
    revision.observed_at
), stale_status AS MATERIALIZED (
  SELECT
    materialization.task_name,
    materialization.contract_hash AS workload_revision_hash,
    count(*)::bigint AS stale_count,
    max(GREATEST(
      extract(epoch FROM observed.observed_at - materialization.updated_at)
        * 1000,
      0
    )) AS oldest_age_ms
  FROM otlet.semantic_materializations materialization
  CROSS JOIN observation observed
  WHERE materialization.stale
  GROUP BY materialization.task_name, materialization.contract_hash
), catch_up_item AS MATERIALIZED (
  SELECT
    watch.task_name,
    reconciliation.workload_revision_hash,
    reconciliation.first_dirty_at AS waiting_since
  FROM otlet.watch_reconciliation reconciliation
  JOIN otlet.watches watch ON watch.name = reconciliation.watch_name
  WHERE reconciliation.state IN ('pending', 'exhausted')

  UNION ALL

  SELECT
    backfill.task_name,
    backfill.workload_revision_hash,
    backfill.created_at
  FROM otlet.task_backfills backfill
  JOIN otlet.task_backfill_subjects subject
    ON subject.backfill_id = backfill.id
   AND subject.disposition = 'pending'
  WHERE backfill.control_state = 'running'
), catch_up_status AS MATERIALIZED (
  SELECT
    item.task_name,
    item.workload_revision_hash,
    count(*)::bigint AS pending_count,
    max(GREATEST(
      extract(epoch FROM observed.observed_at - item.waiting_since) * 1000,
      0
    )) AS oldest_age_ms
  FROM catch_up_item item
  CROSS JOIN observation observed
  GROUP BY item.task_name, item.workload_revision_hash
), review_status AS MATERIALIZED (
  SELECT
    queue.task_name,
    queue.workload_revision_hash,
    count(*)::bigint AS backlog_count,
    max(GREATEST(
      extract(epoch FROM observed.observed_at - queue.created_at) * 1000,
      0
    )) AS oldest_age_ms
  FROM otlet.review_queue queue
  CROSS JOIN observation observed
  GROUP BY queue.task_name, queue.workload_revision_hash
), latest_cleanup AS MATERIALIZED (
  SELECT
    count(*)::bigint AS runs,
    max(completed_at) FILTER (WHERE control_state = 'complete')
      AS last_completed_at,
    count(*) FILTER (
      WHERE control_state IN ('running', 'paused', 'retryable')
    )::bigint AS unfinished_runs
  FROM otlet.maintenance_runs
  WHERE kind = 'cleanup'
), cleanup_status AS MATERIALIZED (
  SELECT
    cleanup.*,
    otlet.maintenance_cleanup_pending() AS pending,
    observed.observed_at
  FROM latest_cleanup cleanup
  CROSS JOIN observation observed
)
SELECT
  'otlet.observability.status.v1'::text AS observability_schema,
  timing.window_name,
  timing.window_started_at,
  timing.observed_at,
  'queue_wait_ms'::text AS metric_name,
  timing.task_name,
  timing.workload_revision_hash,
  NULL::text AS worker_identity_hash,
  NULL::text AS category,
  timing.queue_samples AS sample_count,
  timing.queue_samples AS denominator,
  NULL::numeric AS value_numeric,
  timing.queue_p50::numeric AS p50,
  timing.queue_p95::numeric AS p95,
  timing.queue_p99::numeric AS p99,
  timing.queue_max::numeric AS maximum,
  'milliseconds'::text AS unit,
  CASE WHEN timing.queue_samples = 0 THEN 'no_samples' ELSE 'observed' END
    AS status
FROM timing

UNION ALL

SELECT
  'otlet.observability.status.v1',
  timing.window_name,
  timing.window_started_at,
  timing.observed_at,
  'run_time_ms',
  timing.task_name,
  timing.workload_revision_hash,
  NULL,
  NULL,
  timing.run_samples,
  timing.run_samples,
  NULL,
  timing.run_p50,
  timing.run_p95,
  timing.run_p99,
  timing.run_max,
  'milliseconds',
  CASE WHEN timing.run_samples = 0 THEN 'no_samples' ELSE 'observed' END
FROM timing

UNION ALL

SELECT
  'otlet.observability.status.v1',
  revision.window_name,
  revision.window_started_at,
  revision.observed_at,
  'failure_occurrence',
  job.task_name,
  job.workload_revision_hash,
  NULL,
  failure.failure_scope || ':' || failure.failure_reason_code,
  count(*)::bigint,
  NULL,
  count(*)::numeric,
  NULL,
  NULL,
  NULL,
  NULL,
  'occurrences',
  'observed'
FROM revision_window revision
JOIN otlet.failure_retry_status failure
  ON failure.finished_at >= revision.window_started_at
 AND failure.finished_at <= revision.observed_at
JOIN otlet.jobs job
  ON job.id = failure.job_id
 AND job.task_name = revision.task_name
 AND job.workload_revision_hash = revision.workload_revision_hash
 AND job.execution_mode = 'production'
GROUP BY
  revision.window_name,
  revision.window_started_at,
  revision.observed_at,
  job.task_name,
  job.workload_revision_hash,
  failure.failure_scope,
  failure.failure_reason_code

UNION ALL

SELECT
  'otlet.observability.status.v1',
  schema_status.window_name,
  schema_status.window_started_at,
  schema_status.observed_at,
  'schema_rejection_rate',
  schema_status.task_name,
  schema_status.workload_revision_hash,
  NULL,
  'failed',
  schema_status.rejected,
  schema_status.checked,
  schema_status.rejected::numeric / NULLIF(schema_status.checked, 0),
  NULL,
  NULL,
  NULL,
  NULL,
  'ratio',
  CASE WHEN schema_status.checked = 0 THEN 'no_samples' ELSE 'observed' END
FROM schema_status

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'stale_age_ms',
  revision.task_name,
  revision.workload_revision_hash,
  NULL,
  NULL,
  COALESCE(stale.stale_count, 0),
  NULL,
  stale.oldest_age_ms,
  NULL,
  NULL,
  NULL,
  stale.oldest_age_ms,
  'milliseconds',
  CASE WHEN stale.stale_count IS NULL THEN 'clear' ELSE 'stale' END
FROM otlet.workload_revisions revision
CROSS JOIN observation observed
LEFT JOIN stale_status stale
  ON stale.task_name = revision.task_name
 AND stale.workload_revision_hash = revision.workload_revision_hash

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'catch_up_age_ms',
  revision.task_name,
  revision.workload_revision_hash,
  NULL,
  NULL,
  COALESCE(catch_up.pending_count, 0),
  NULL,
  catch_up.oldest_age_ms,
  NULL,
  NULL,
  NULL,
  catch_up.oldest_age_ms,
  'milliseconds',
  CASE WHEN catch_up.pending_count IS NULL THEN 'clear' ELSE 'waiting' END
FROM otlet.workload_revisions revision
CROSS JOIN observation observed
LEFT JOIN catch_up_status catch_up
  ON catch_up.task_name = revision.task_name
 AND catch_up.workload_revision_hash = revision.workload_revision_hash

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'review_backlog_age_ms',
  revision.task_name,
  revision.workload_revision_hash,
  NULL,
  NULL,
  COALESCE(review.backlog_count, 0),
  NULL,
  review.oldest_age_ms,
  NULL,
  NULL,
  NULL,
  review.oldest_age_ms,
  'milliseconds',
  CASE WHEN review.backlog_count IS NULL THEN 'clear' ELSE 'waiting' END
FROM otlet.workload_revisions revision
CROSS JOIN observation observed
LEFT JOIN review_status review
  ON review.task_name = revision.task_name
 AND review.workload_revision_hash = revision.workload_revision_hash

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'review_backlog_age_ms',
  review.task_name,
  NULL,
  NULL,
  NULL,
  review.backlog_count,
  NULL,
  review.oldest_age_ms,
  NULL,
  NULL,
  NULL,
  review.oldest_age_ms,
  'milliseconds',
  'waiting'
FROM review_status review
CROSS JOIN observation observed
WHERE review.workload_revision_hash IS NULL

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'route_readiness',
  route.task_name,
  route.workload_revision_hash,
  NULL,
  route.selection_role || ':' || route.readiness_reason,
  count(*)::bigint,
  count(*)::bigint,
  count(*) FILTER (WHERE route.route_ready)::numeric,
  NULL,
  NULL,
  NULL,
  NULL,
  'routes',
  CASE WHEN bool_and(route.route_ready) THEN 'ready' ELSE 'not_ready' END
FROM otlet.route_readiness_status route
CROSS JOIN observation observed
GROUP BY
  observed.observed_at,
  route.task_name,
  route.workload_revision_hash,
  route.selection_role,
  route.readiness_reason

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'portable_worker_heartbeat_age_ms',
  NULL,
  NULL,
  otlet.identity_text_hash('portable_worker', worker.worker_id),
  worker.worker_health,
  1,
  1,
  CASE WHEN worker.last_heartbeat_at IS NULL THEN NULL ELSE GREATEST(
    extract(epoch FROM observed.observed_at - worker.last_heartbeat_at) * 1000,
    0
  ) END,
  NULL,
  NULL,
  NULL,
  CASE WHEN worker.last_heartbeat_at IS NULL THEN NULL ELSE GREATEST(
    extract(epoch FROM observed.observed_at - worker.last_heartbeat_at) * 1000,
    0
  ) END,
  'milliseconds',
  worker.worker_health
FROM otlet.portable_worker_status worker
CROSS JOIN observation observed

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'native_worker_liveness',
  NULL,
  NULL,
  NULL,
  'native:linked_inproc',
  count(activity.pid)::bigint,
  NULL,
  count(activity.pid)::numeric,
  NULL,
  NULL,
  NULL,
  NULL,
  'workers',
  CASE WHEN count(activity.pid) > 0 THEN 'healthy' ELSE 'absent' END
FROM observation observed
LEFT JOIN pg_catalog.pg_stat_activity activity
  ON activity.backend_type = 'otlet worker'
 AND activity.datname = current_database()
GROUP BY observed.observed_at

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  cleanup.observed_at,
  'cleanup_lag_ms',
  NULL,
  NULL,
  NULL,
  CASE
    WHEN cleanup.pending AND cleanup.last_completed_at IS NULL
      THEN 'pending_never_completed'
    WHEN cleanup.pending THEN 'pending'
    WHEN cleanup.last_completed_at IS NULL THEN 'idle_never_run'
    ELSE 'idle'
  END,
  cleanup.runs,
  NULL,
  CASE WHEN cleanup.last_completed_at IS NULL THEN NULL ELSE GREATEST(
    extract(epoch FROM cleanup.observed_at - cleanup.last_completed_at) * 1000,
    0
  ) END,
  NULL,
  NULL,
  NULL,
  CASE WHEN cleanup.last_completed_at IS NULL THEN NULL ELSE GREATEST(
    extract(epoch FROM cleanup.observed_at - cleanup.last_completed_at) * 1000,
    0
  ) END,
  'milliseconds',
  CASE
    WHEN cleanup.pending THEN 'pending'
    WHEN cleanup.unfinished_runs > 0 THEN 'unfinished'
    ELSE 'idle'
  END
FROM cleanup_status cleanup

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'resource_pressure',
  queue.task_name,
  head.active_workload_revision_hash,
  NULL,
  'task_queued_input_bytes',
  queue.queued_jobs,
  queue.max_queued_input_bytes_per_task,
  queue.queued_input_bytes,
  NULL,
  NULL,
  NULL,
  queue.max_queued_input_bytes_per_task,
  'bytes',
  CASE WHEN queue.queue_bytes_exhausted THEN 'pressured' ELSE 'available' END
FROM otlet.task_queue_capacity queue
JOIN otlet.workload_revision_heads head ON head.task_name = queue.task_name
CROSS JOIN observation observed

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'resource_pressure',
  queue.task_name,
  head.active_workload_revision_hash,
  NULL,
  'task_queue_age_ms',
  queue.queued_jobs,
  extract(epoch FROM queue.max_queue_age) * 1000,
  CASE WHEN queue.oldest_queue_age IS NULL THEN NULL ELSE
    extract(epoch FROM queue.oldest_queue_age) * 1000
  END,
  NULL,
  NULL,
  NULL,
  extract(epoch FROM queue.max_queue_age) * 1000,
  'milliseconds',
  CASE
    WHEN queue.max_queue_age IS NULL THEN 'disabled'
    WHEN queue.queue_age_exceeded THEN 'pressured'
    ELSE 'available'
  END
FROM otlet.task_queue_capacity queue
JOIN otlet.workload_revision_heads head ON head.task_name = queue.task_name
CROSS JOIN observation observed

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'resource_pressure',
  capacity.task_name,
  head.active_workload_revision_hash,
  NULL,
  'task_active_claims',
  capacity.active_claimed_jobs,
  capacity.max_active_jobs_per_task,
  capacity.active_claimed_jobs,
  NULL,
  NULL,
  NULL,
  capacity.max_active_jobs_per_task,
  'jobs',
  CASE WHEN capacity.available_active_job_slots = 0
    THEN 'pressured'
    ELSE 'available'
  END
FROM otlet.task_claim_capacity capacity
JOIN otlet.workload_revision_heads head ON head.task_name = capacity.task_name
CROSS JOIN observation observed

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'resource_pressure',
  NULL,
  NULL,
  NULL,
  'model_queued_input_bytes:' || queue.model_name,
  queue.queued_jobs,
  queue.max_queued_input_bytes_per_model,
  queue.queued_input_bytes,
  NULL,
  NULL,
  NULL,
  queue.max_queued_input_bytes_per_model,
  'bytes',
  CASE WHEN queue.available_model_queue_input_bytes = 0
    THEN 'pressured'
    ELSE 'available'
  END
FROM otlet.model_queue_status queue
CROSS JOIN observation observed

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'resource_pressure',
  NULL,
  NULL,
  NULL,
  'model_queued_jobs:' || queue.model_name,
  queue.queued_jobs,
  queue.max_queued_jobs_per_model,
  queue.queued_jobs,
  NULL,
  NULL,
  NULL,
  queue.max_queued_jobs_per_model,
  'jobs',
  CASE WHEN queue.available_queue_slots = 0
    THEN 'pressured'
    ELSE 'available'
  END
FROM otlet.model_queue_status queue
CROSS JOIN observation observed

UNION ALL

SELECT
  'otlet.observability.status.v1',
  'current',
  NULL,
  observed.observed_at,
  'resource_pressure',
  NULL,
  NULL,
  NULL,
  'total_queued_input_bytes',
  total.queued_jobs,
  total.max_queued_input_bytes_total,
  total.total_queued_input_bytes,
  NULL,
  NULL,
  NULL,
  total.max_queued_input_bytes_total,
  'bytes',
  CASE WHEN total.total_queued_input_bytes >= total.max_queued_input_bytes_total
    THEN 'pressured'
    ELSE 'available'
  END
FROM (
  SELECT
    sum(queue.queued_jobs)::bigint AS queued_jobs,
    max(queue.max_queued_input_bytes_total)::bigint
      AS max_queued_input_bytes_total,
    max(queue.total_queued_input_bytes)::bigint AS total_queued_input_bytes
  FROM otlet.model_queue_status queue
  HAVING count(*) > 0
) total
CROSS JOIN observation observed;

CREATE FUNCTION otlet.operational_observability_status_rows()
RETURNS SETOF otlet.operational_observability_status_internal
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT * FROM otlet.operational_observability_status_internal;
$$;

CREATE VIEW otlet.operational_observability_status AS
SELECT * FROM otlet.operational_observability_status_rows();

CREATE VIEW otlet.labeled_quality_status_internal AS
SELECT
  'otlet.labeled_quality.status.v1'::text AS quality_schema,
  quality.contract_hash,
  quality.task_name,
  quality.baseline_workload_revision_hash,
  quality.candidate_workload_revision_hash,
  (quality.observation_window ->> 'starts_at')::timestamptz
    AS observation_started_at,
  (quality.observation_window ->> 'ends_at')::timestamptz
    AS observation_ended_at,
  GREATEST(
    coverage.created_at,
    evaluation.created_at,
    economics.created_at
  ) AS observed_at,
  quality.metric,
  quality.eligible_count,
  quality.numerator,
  quality.denominator,
  quality.rate,
  GREATEST(
    ceil(extract(epoch FROM (
      GREATEST(
        coverage.created_at,
        evaluation.created_at,
        economics.created_at
      ) - (quality.observation_window ->> 'ends_at')::timestamptz
    )) * 1000)::bigint,
    0
  ) AS observation_lag_ms,
  quality.denominator_definition,
  quality.evidence_kind,
  quality.current_contract,
  quality.active_baseline,
  quality.evidence_ready,
  quality.non_authoritative
FROM otlet.entity_resolution_quality_status quality
JOIN otlet.candidate_set_coverage_reports coverage
  ON coverage.report_hash = quality.candidate_coverage_report_hash
JOIN otlet.evaluation_slice_reports evaluation
  ON evaluation.report_hash = quality.evaluation_report_hash
JOIN otlet.review_economics_reports economics
  ON economics.report_hash = quality.review_economics_report_hash;

CREATE FUNCTION otlet.labeled_quality_status_rows()
RETURNS SETOF otlet.labeled_quality_status_internal
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT * FROM otlet.labeled_quality_status_internal;
$$;

CREATE VIEW otlet.labeled_quality_status AS
SELECT * FROM otlet.labeled_quality_status_rows();

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
  granted_role text;
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.redaction_policy_status'::regclass,
    true
  );
  old_fragment := $old$'receipt_error'::text] AS withheld_fields$old$;
  new_fragment := $new$'receipt_error'::text, 'worker_event_message'::text, 'worker_event_detail'::text] AS withheld_fields$new$;
  IF pg_catalog.strpos(definition, old_fragment) = 0 THEN
    RAISE EXCEPTION 'otlet observability withheld-field rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  old_fragment := $old$'otlet.operational_event_log'::text, 'otlet.worker_batch_timing_status'::text$old$;
  new_fragment := $new$'otlet.operational_event_log'::text, 'otlet.operational_observability_status'::text, 'otlet.labeled_quality_status'::text, 'otlet.worker_batch_timing_status'::text$new$;
  IF pg_catalog.strpos(definition, old_fragment) = 0 THEN
    RAISE EXCEPTION 'otlet observability redaction status rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  IF pg_catalog.strpos(definition, '6 AS policy_version') = 0 THEN
    RAISE EXCEPTION 'otlet observability redaction policy version is unexpected';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.redaction_policy_status AS '
    || pg_catalog.replace(
      definition,
      '6 AS policy_version',
      '7 AS policy_version'
    );

  definition := pg_catalog.pg_get_functiondef(
    'otlet.grant_auditor_access(regrole)'::regprocedure
  );
  old_fragment := $old$    'otlet.stranded_escalation_status TO %I',$old$;
  new_fragment := $new$    'otlet.stranded_escalation_status, '
    'otlet.operational_observability_status, '
    'otlet.labeled_quality_status TO %I',$new$;
  IF pg_catalog.strpos(definition, old_fragment) = 0 THEN
    RAISE EXCEPTION 'otlet observability auditor grant rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$    'otlet.stranded_escalation_status_rows() TO %I',$old$;
  new_fragment := $new$    'otlet.stranded_escalation_status_rows(), '
    'otlet.operational_observability_status_rows(), '
    'otlet.labeled_quality_status_rows() TO %I',$new$;
  IF pg_catalog.strpos(definition, old_fragment) = 0 THEN
    RAISE EXCEPTION 'otlet observability auditor function grant rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);

  FOR granted_role IN
    SELECT role.rolname
    FROM pg_catalog.pg_roles role
    JOIN LATERAL pg_catalog.aclexplode(
      (SELECT relation.relacl
       FROM pg_catalog.pg_class relation
       WHERE relation.oid = 'otlet.stranded_escalation_status'::regclass)
    ) privilege ON privilege.grantee = role.oid
    WHERE privilege.privilege_type = 'SELECT'
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE otlet.operational_event_log, '
        || 'otlet.operational_observability_status, '
        || 'otlet.labeled_quality_status TO %I',
      granted_role
    );
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
        || 'otlet.operational_observability_status_rows(), '
        || 'otlet.labeled_quality_status_rows() TO %I',
      granted_role
    );
  END LOOP;
END;
$migration$;

COMMENT ON VIEW otlet.operational_event_log IS
'Versioned low-cardinality worker events with raw payloads withheld and stable incident identities';
COMMENT ON VIEW otlet.operational_observability_status IS
'Fixed 15-minute, 1-hour, and 24-hour operational windows plus honest current gauges';
COMMENT ON VIEW otlet.labeled_quality_status IS
'Non-authoritative entity-resolution quality with exact denominators and immutable observation lag';

REVOKE EXECUTE ON FUNCTION otlet.bind_worker_event_identities() FROM PUBLIC;
REVOKE ALL ON TABLE otlet.operational_event_log FROM PUBLIC;
REVOKE ALL ON TABLE otlet.operational_observability_status_internal FROM PUBLIC;
REVOKE ALL ON TABLE otlet.operational_observability_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.labeled_quality_status_internal FROM PUBLIC;
REVOKE ALL ON TABLE otlet.labeled_quality_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.operational_observability_status_rows()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.labeled_quality_status_rows() FROM PUBLIC;
