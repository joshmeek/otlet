ALTER TABLE otlet.jobs
ADD COLUMN native_cancel_observed_at timestamptz,
ADD COLUMN native_cancel_observed_phase text,
ADD COLUMN native_cancel_stopped_at timestamptz,
ADD CONSTRAINT jobs_native_cancel_observation_pair CHECK (
  (native_cancel_observed_at IS NULL) = (native_cancel_observed_phase IS NULL)
),
ADD CONSTRAINT jobs_native_cancel_observation_phase CHECK (
  native_cancel_observed_phase IS NULL OR native_cancel_observed_phase IN (
    'claimed_batch_wait',
    'model_load',
    'prompt_decode',
    'generation',
    'inference_cache_hit',
    'strong_fallback',
    'output_acceptance'
  )
),
ADD CONSTRAINT jobs_native_cancel_observation_order CHECK (
  native_cancel_observed_at IS NULL OR (
    cancel_requested_at IS NOT NULL
    AND native_cancel_observed_at >= cancel_requested_at
    AND (finished_at IS NULL OR native_cancel_observed_at <= finished_at)
  )
),
ADD CONSTRAINT jobs_native_cancel_stop_order CHECK (
  native_cancel_stopped_at IS NULL OR (
    native_cancel_observed_at IS NOT NULL
    AND native_cancel_stopped_at >= native_cancel_observed_at
    AND (finished_at IS NULL OR native_cancel_stopped_at <= finished_at)
  )
);

CREATE FUNCTION otlet.observe_native_job_cancellation(
  job_id bigint,
  expected_claim_token text,
  observation_phase text
) RETURNS boolean
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  observed_at timestamptz;
BEGIN
  IF observe_native_job_cancellation.observation_phase IS NULL
     OR observe_native_job_cancellation.observation_phase NOT IN (
    'claimed_batch_wait',
    'model_load',
    'prompt_decode',
    'generation',
    'inference_cache_hit',
    'strong_fallback',
    'output_acceptance'
  ) THEN
    RAISE EXCEPTION 'otlet native cancellation observation phase is invalid';
  END IF;

  SELECT *
  INTO job_row
  FROM otlet.jobs job
  WHERE job.id = observe_native_job_cancellation.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet native cancellation job is missing';
  END IF;
  IF observe_native_job_cancellation.expected_claim_token IS NULL
     OR job_row.claim_token IS DISTINCT FROM
       observe_native_job_cancellation.expected_claim_token
     OR job_row.status NOT IN ('running', 'cancel_requested')
     OR job_row.leased_until IS NULL
     OR job_row.leased_until < clock_timestamp() THEN
    RAISE EXCEPTION 'otlet native cancellation job claim is stale';
  END IF;
  IF job_row.status = 'running' THEN
    RETURN false;
  END IF;

  IF job_row.native_cancel_observed_at IS NULL THEN
    observed_at := clock_timestamp();
    UPDATE otlet.jobs
    SET native_cancel_observed_at = observed_at,
        native_cancel_observed_phase =
          observe_native_job_cancellation.observation_phase
    WHERE id = job_row.id;

    INSERT INTO otlet.worker_events (
      event_type,
      job_id,
      runtime_name,
      message,
      detail,
      created_at
    ) VALUES (
      'job_cancel_observed',
      job_row.id,
      'linked_inproc',
      'otlet native worker observed cancellation',
      jsonb_build_object(
        'phase', observe_native_job_cancellation.observation_phase
      ),
      observed_at
    );
  END IF;
  RETURN true;
END;
$$;

CREATE FUNCTION otlet.stop_native_job_cancellation(
  job_id bigint,
  expected_claim_token text
) RETURNS boolean
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
BEGIN
  SELECT *
  INTO job_row
  FROM otlet.jobs job
  WHERE job.id = stop_native_job_cancellation.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet native cancellation job is missing';
  END IF;
  IF stop_native_job_cancellation.expected_claim_token IS NULL
     OR job_row.claim_token IS DISTINCT FROM
       stop_native_job_cancellation.expected_claim_token
     OR job_row.status <> 'cancel_requested'
     OR job_row.native_cancel_observed_at IS NULL THEN
    RAISE EXCEPTION 'otlet native cancellation job claim is stale';
  END IF;

  IF job_row.native_cancel_stopped_at IS NULL THEN
    UPDATE otlet.jobs
    SET native_cancel_stopped_at = clock_timestamp()
    WHERE id = job_row.id;
  END IF;
  RETURN true;
END;
$$;

DO $migration$
DECLARE
  definition text := pg_get_functiondef(
    'otlet.complete_job(bigint,jsonb,text,jsonb,text,text,text,text,timestamptz,jsonb,text,text,text,text,text,text,text)'::regprocedure
  );
  old_fragment text := $old$  IF job_row.status = 'cancel_requested' THEN
    PERFORM 1$old$;
  new_fragment text := $new$  IF job_row.status = 'cancel_requested' THEN
    IF COALESCE(complete_job.runtime_name, 'linked_inproc') = 'linked_inproc' THEN
      PERFORM otlet.observe_native_job_cancellation(
        complete_job.job_id,
        complete_job.expected_claim_token,
        'output_acceptance'
      );
      PERFORM otlet.stop_native_job_cancellation(
        complete_job.job_id,
        complete_job.expected_claim_token
      );
    END IF;
    PERFORM 1$new$;
BEGIN
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet native output-acceptance cancellation rewrite is incomplete';
  END IF;
  EXECUTE replace(definition, old_fragment, new_fragment);
END;
$migration$;

DO $migration$
DECLARE
  definition text := pg_get_functiondef(
    'otlet.complete_and_materialize_job(bigint,jsonb,text,jsonb,text,text,text,text,jsonb,text,text,text,text)'::regprocedure
  );
  old_fragment text := $old$  IF output_id IS NULL THEN
    RETURN NEXT;$old$;
  new_fragment text := $new$  IF output_id IS NULL THEN
    SELECT CASE WHEN job.status = 'canceled' THEN 'canceled' END
    INTO completion_error
    FROM otlet.jobs job
    WHERE job.id = complete_and_materialize_job.job_id;
    RETURN NEXT;$new$;
BEGIN
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet native canceled completion outcome rewrite is incomplete';
  END IF;
  EXECUTE replace(definition, old_fragment, new_fragment);
END;
$migration$;

DO $migration$
DECLARE
  definition text := pg_get_functiondef(
    'otlet.fail_job(bigint,text,text,text,text,text,text,timestamptz,text,jsonb,text,text,text,text,jsonb,text,text,text)'::regprocedure
  );
  old_fragment text := $old$  IF saved_job.status = 'cancel_requested' THEN
    RETURN QUERY$old$;
  new_fragment text := $new$  IF saved_job.status = 'cancel_requested' THEN
    IF COALESCE(fail_job.runtime_name, 'linked_inproc') = 'linked_inproc' THEN
      PERFORM otlet.observe_native_job_cancellation(
        fail_job.job_id,
        fail_job.expected_claim_token,
        'output_acceptance'
      );
      PERFORM otlet.stop_native_job_cancellation(
        fail_job.job_id,
        fail_job.expected_claim_token
      );
    END IF;
    RETURN QUERY$new$;
BEGIN
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet native failure cancellation rewrite is incomplete';
  END IF;
  EXECUTE replace(definition, old_fragment, new_fragment);
END;
$migration$;

CREATE VIEW otlet.native_cancellation_slo_status AS
WITH phases(phase, sort_order) AS (
  VALUES
    ('all'::text, 0),
    ('claimed_batch_wait'::text, 1),
    ('model_load'::text, 2),
    ('prompt_decode'::text, 3),
    ('generation'::text, 4),
    ('inference_cache_hit'::text, 5),
    ('strong_fallback'::text, 6),
    ('output_acceptance'::text, 7)
), samples AS MATERIALIZED (
  SELECT
    job.id AS job_id,
    job.native_cancel_observed_phase AS phase,
    CEIL(
      EXTRACT(epoch FROM (
        job.native_cancel_observed_at - job.cancel_requested_at
      )) * 1000
    )::bigint AS request_to_observation_ms,
    CASE WHEN job.native_cancel_stopped_at IS NOT NULL THEN
      CEIL(
        EXTRACT(epoch FROM (
          job.native_cancel_stopped_at - job.cancel_requested_at
        )) * 1000
      )::bigint
    END AS cancel_to_stop_ms
  FROM otlet.jobs job
  WHERE job.native_cancel_observed_at IS NOT NULL
), aggregate AS (
  SELECT
    phases.phase,
    phases.sort_order,
    count(samples.job_id)::bigint AS observation_samples,
    count(samples.cancel_to_stop_ms)::bigint AS stop_samples,
    percentile_disc(0.95) WITHIN GROUP (
      ORDER BY samples.request_to_observation_ms
    ) FILTER (WHERE samples.request_to_observation_ms IS NOT NULL)
      AS request_to_observation_p95_ms,
    percentile_disc(0.99) WITHIN GROUP (
      ORDER BY samples.request_to_observation_ms
    ) FILTER (WHERE samples.request_to_observation_ms IS NOT NULL)
      AS request_to_observation_p99_ms,
    percentile_disc(0.95) WITHIN GROUP (
      ORDER BY samples.cancel_to_stop_ms
    ) FILTER (WHERE samples.cancel_to_stop_ms IS NOT NULL)
      AS cancel_to_stop_p95_ms,
    percentile_disc(0.99) WITHIN GROUP (
      ORDER BY samples.cancel_to_stop_ms
    ) FILTER (WHERE samples.cancel_to_stop_ms IS NOT NULL)
      AS cancel_to_stop_p99_ms
  FROM phases
  LEFT JOIN samples
    ON phases.phase = 'all' OR samples.phase = phases.phase
  GROUP BY phases.phase, phases.sort_order
), active AS (
  SELECT
    count(*) FILTER (
      WHERE job.native_cancel_observed_at IS NULL
    )::bigint AS unobserved_cancellations,
    count(*) FILTER (
      WHERE job.native_cancel_observed_at IS NOT NULL
        AND job.native_cancel_stopped_at IS NULL
    )::bigint AS observed_not_stopped,
    count(*) FILTER (
      WHERE job.native_cancel_observed_at IS NULL
        AND clock_timestamp() - job.cancel_requested_at >
          make_interval(
            secs => policy.cancellation_observation_p99_target_ms / 1000.0
          )
    )::bigint AS overdue_unobserved_cancellations
  FROM otlet.jobs job
  CROSS JOIN otlet.production_policy policy
  WHERE policy.name = 'default'
    AND job.status = 'cancel_requested'
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.portable_claims claim
      WHERE claim.job_id = job.id
        AND claim.attempt_index = job.attempts
        AND claim.status IN ('claimed', 'renewed')
    )
)
SELECT
  aggregate.phase,
  aggregate.observation_samples,
  aggregate.stop_samples,
  aggregate.request_to_observation_p95_ms,
  aggregate.request_to_observation_p99_ms,
  aggregate.cancel_to_stop_p95_ms,
  aggregate.cancel_to_stop_p99_ms,
  policy.cancellation_observation_p99_target_ms,
  100::bigint AS minimum_observation_samples,
  CASE
    WHEN aggregate.observation_samples < 100 THEN NULL
    ELSE aggregate.request_to_observation_p99_ms <=
      policy.cancellation_observation_p99_target_ms
  END AS observation_target_met,
  CASE
    WHEN aggregate.request_to_observation_p99_ms IS NULL THEN 'no_samples'
    WHEN aggregate.observation_samples < 100 THEN 'collecting'
    WHEN aggregate.request_to_observation_p99_ms <=
      policy.cancellation_observation_p99_target_ms THEN 'met'
    ELSE 'missed'
  END AS measurement_status,
  CASE WHEN aggregate.phase = 'all' THEN active.unobserved_cancellations ELSE 0 END
    AS active_unobserved_cancellations,
  CASE WHEN aggregate.phase = 'all' THEN active.observed_not_stopped ELSE 0 END
    AS active_observed_not_stopped,
  CASE WHEN aggregate.phase = 'all' THEN active.overdue_unobserved_cancellations ELSE 0 END
    AS overdue_unobserved_cancellations,
  aggregate.observation_samples >= 100
    AND aggregate.request_to_observation_p99_ms >
      policy.cancellation_observation_p99_target_ms
    AS finer_preemption_required
FROM aggregate
CROSS JOIN otlet.production_policy policy
CROSS JOIN active
WHERE policy.name = 'default'
ORDER BY aggregate.sort_order;

COMMENT ON COLUMN otlet.production_policy.cancellation_observation_p99_target_ms IS
'Declared native cancel-request-to-runtime-observation p99 target measured by native_cancellation_slo_status';
COMMENT ON COLUMN otlet.jobs.native_cancel_observed_at IS
'First wall-clock time the active native worker observed cancel_requested';
COMMENT ON COLUMN otlet.jobs.native_cancel_observed_phase IS
'First native runtime boundary that observed cancel_requested';
COMMENT ON COLUMN otlet.jobs.native_cancel_stopped_at IS
'First wall-clock time the native runtime stopped canceled work';
COMMENT ON FUNCTION otlet.observe_native_job_cancellation(bigint, text, text) IS
'Active-claim native cancellation probe with first-write-wins phase evidence';
COMMENT ON FUNCTION otlet.stop_native_job_cancellation(bigint, text) IS
'Active-claim checkpoint after canceled native work has stopped';
COMMENT ON VIEW otlet.native_cancellation_slo_status IS
'Overall and per-phase native cancellation observation and stop percentiles';

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
  granted_role text;
BEGIN
  definition := pg_get_functiondef(
    'otlet.grant_auditor_access(regrole)'::regprocedure
  );
  old_fragment := $old$    'otlet.task_resource_status TO %I',$old$;
  new_fragment := $new$    'otlet.task_resource_status, '
    'otlet.native_cancellation_slo_status TO %I',$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet native cancellation auditor grant rewrite is incomplete';
  END IF;
  EXECUTE replace(definition, old_fragment, new_fragment);

  FOR granted_role IN
    SELECT role.rolname
    FROM pg_roles role
    JOIN LATERAL aclexplode(
      (SELECT relation.relacl
       FROM pg_class relation
       WHERE relation.oid = 'otlet.task_resource_status'::regclass)
    ) privilege ON privilege.grantee = role.oid
    WHERE privilege.privilege_type = 'SELECT'
  LOOP
    EXECUTE format(
      'GRANT SELECT ON TABLE otlet.native_cancellation_slo_status TO %I',
      granted_role
    );
  END LOOP;
END;
$migration$;

REVOKE ALL ON TABLE otlet.native_cancellation_slo_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.observe_native_job_cancellation(
  bigint, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.stop_native_job_cancellation(
  bigint, text
) FROM PUBLIC;
