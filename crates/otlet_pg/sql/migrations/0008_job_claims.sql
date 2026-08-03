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
    j.workload_revision_hash = head.active_workload_revision_hash AS active_revision
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

-- Atomic queue claim for the resident worker; returns zero rows when no work exists
CREATE FUNCTION otlet.claim_jobs(
  requested_model_name text DEFAULT NULL,
  requested_limit integer DEFAULT NULL
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
    WHERE j.status IN ('queued', 'running', 'cancel_requested')
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
    JOIN otlet.workload_revision_heads head ON head.task_name = j.task_name
  ),
  eligible_tasks AS (
    SELECT
      job.task_name,
      job.active_workload_revision_hash AS workload_revision_hash,
      job.selected_model ->> 'name' AS model_name,
      job.selected_model ->> 'artifact_path' AS artifact_path,
      job.definition #>> '{selection,cheap_model_name}' AS policy_cheap_model_name,
      job.definition #>> '{selection,strong_model_name}' AS policy_strong_model_name,
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
      AND otlet.source_fields_are_allowed(
        job.input,
        job.definition #> '{task,input_shaping}'
      )
      AND otlet.source_query_contract_error(
        job.definition #> '{source,query_contract}',
        true
      ) IS NULL
      AND job.workload_revision_hash = job.active_workload_revision_hash
    GROUP BY
      job.task_name,
      job.active_workload_revision_hash,
      job.selected_model,
      job.definition #>> '{selection,cheap_model_name}',
      job.definition #>> '{selection,strong_model_name}',
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
    CROSS JOIN policy p
  ),
  locked_tasks AS MATERIALIZED (
    SELECT task.*, revision.definition
    FROM same_model_tasks task
    JOIN otlet.workload_revision_heads head
      ON head.task_name = task.task_name
     AND head.active_workload_revision_hash = task.workload_revision_hash
    JOIN otlet.workload_revisions revision
      ON revision.task_name = task.task_name
     AND revision.workload_revision_hash = task.workload_revision_hash
    ORDER BY task.task_rank
    FOR UPDATE OF head
  ),
  guarded_tasks AS MATERIALIZED (
    SELECT task.*
    FROM locked_tasks task
    WHERE otlet.source_query_contract_guard(
      task.definition #> '{source,query_contract}',
      true
    )::text = ''
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
      AND otlet.source_fields_are_allowed(
        job.input,
        job.definition #> '{task,input_shaping}'
      )
      AND job.workload_revision_hash = job.active_workload_revision_hash
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
        WHERE task.task_name = candidate.task_name
          AND task.workload_revision_hash = candidate.workload_revision_hash
          AND otlet.source_fields_are_allowed(
            j.input,
            job.definition #> '{task,input_shaping}'
          )
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
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
  PERFORM 1
  FROM otlet.jobs j
  WHERE j.id = renew_job_lease.job_id
    AND j.claim_token = renew_job_lease.expected_claim_token
    AND j.status IN ('running', 'cancel_requested')
  FOR UPDATE OF j;

  RETURN QUERY
  WITH locked_job AS MATERIALIZED (
    SELECT
      j.id,
      revision.definition,
      (revision.definition #>> '{runtime,lease_ms}')::bigint
        * interval '1 millisecond' AS lease_interval
    FROM otlet.jobs j
    JOIN otlet.workload_revisions revision
      ON revision.workload_revision_hash = j.workload_revision_hash
     AND revision.task_name = j.task_name
    WHERE j.id = renew_job_lease.job_id
      AND j.claim_token = renew_job_lease.expected_claim_token
      AND j.status IN ('running', 'cancel_requested')
      AND j.leased_until IS NOT NULL
      AND j.leased_until >= clock_timestamp()
      AND otlet.source_query_contract_error(
        revision.definition #> '{source,query_contract}',
        true
      ) IS NULL
  ),
  guarded_job AS MATERIALIZED (
    SELECT locked_job.id, locked_job.lease_interval
    FROM locked_job
    WHERE otlet.source_query_contract_guard(
      locked_job.definition #> '{source,query_contract}',
      true
    )::text = ''
  )
  UPDATE otlet.jobs j
  SET leased_until = clock_timestamp()
    + guarded_job.lease_interval
  FROM guarded_job
  WHERE j.id = guarded_job.id
  RETURNING j.status, j.leased_until;
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

CREATE FUNCTION otlet.mark_job_started(job_id bigint) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_id bigint;
  v_task_name text;
  v_subject_id text;
  model_name text;
BEGIN
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
  WHERE j.id = mark_job_started.job_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  -- Warn-only path: skip slot/event noise when the task row is missing.
  IF model_name IS NULL THEN
    RETURN;
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
END;
$$;
