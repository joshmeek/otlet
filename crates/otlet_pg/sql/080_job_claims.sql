-- Atomic queue claim for the resident worker; returns zero rows when no work exists
CREATE FUNCTION otlet.claim_jobs() RETURNS SETOF otlet.jobs
LANGUAGE sql
AS $$
  WITH policy AS (
    SELECT
      worker_claim_batch_size AS batch_size,
      worker_claim_task_cursor AS task_cursor,
      max_attempts,
      max_attempt_ms,
      default_runtime_options,
      job_lease_interval
    FROM otlet.production_policy
    WHERE name = 'default'
    FOR UPDATE
  ),
  invalid_claim_input AS MATERIALIZED (
    SELECT j.id
    FROM otlet.jobs j
    JOIN otlet.tasks t ON t.name = j.task_name
    WHERE j.status IN ('queued', 'running', 'cancel_requested')
      AND NOT otlet.source_fields_are_allowed(j.input, t.input_shaping)
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
  active_model AS (
    SELECT
      t.model_name,
      -- Occupied only while a live lease holds; NULL / expired leases are reclaimable.
      count(*) FILTER (
        WHERE j.status = 'running'
          AND j.leased_until >= now()
      ) AS running_jobs,
      count(*) FILTER (
        WHERE j.status = 'cancel_requested'
          AND j.leased_until >= now()
      ) AS cancel_requested_jobs
    FROM otlet.jobs j
    JOIN otlet.tasks t ON t.name = j.task_name
    WHERE j.status IN ('running', 'cancel_requested')
    GROUP BY t.model_name
  ),
  eligible_tasks AS (
    SELECT
      j.task_name,
      m.name AS model_name,
      m.artifact_path,
      selection.cheap_model_name AS policy_cheap_model_name,
      selection.strong_model_name AS policy_strong_model_name,
      EXISTS (
        SELECT 1
        FROM otlet.runtime_slots s
        WHERE s.model_name = m.name
          AND s.status = 'ready'
          AND s.artifact_path IS NOT DISTINCT FROM m.artifact_path
      ) AS warm_model,
      min(CASE WHEN j.status IN ('running', 'cancel_requested') AND (j.leased_until IS NULL OR j.leased_until < now()) THEN 0 ELSE 1 END) AS retry_rank,
      min(j.created_at) AS first_created_at,
      min(j.id) AS first_job_id
    FROM otlet.jobs j
    JOIN otlet.tasks t ON t.name = j.task_name
    JOIN otlet.models m ON m.name = t.model_name
    LEFT JOIN otlet.model_selection_policies selection ON selection.task_name = t.name
    CROSS JOIN policy p
    LEFT JOIN active_model ON active_model.model_name = m.name
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
        )
      )
      AND (
        COALESCE(active_model.running_jobs, 0)
        + COALESCE(active_model.cancel_requested_jobs, 0)
      ) < m.max_active_jobs
      AND otlet.source_fields_are_allowed(j.input, t.input_shaping)
    GROUP BY
      j.task_name,
      m.name,
      m.artifact_path,
      selection.cheap_model_name,
      selection.strong_model_name
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
      CASE WHEN e.warm_model THEN 0 ELSE 1 END,
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
          CASE WHEN e.warm_model THEN 0 ELSE 1 END,
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
  ranked_candidates AS (
    SELECT
      j.id,
      j.task_name,
      otlet.effective_job_lease_interval(
        p.default_runtime_options || t.runtime_options,
        p.max_attempt_ms,
        p.job_lease_interval
      ) AS lease_interval,
      f.task_rank,
      row_number() OVER (
        PARTITION BY j.task_name
        ORDER BY
          CASE WHEN j.status IN ('running', 'cancel_requested') AND (j.leased_until IS NULL OR j.leased_until < now()) THEN 0 ELSE 1 END,
          j.created_at,
          j.id
      ) AS task_job_rank
    FROM otlet.jobs j
    JOIN otlet.tasks t ON t.name = j.task_name
    JOIN otlet.models m ON m.name = t.model_name
    JOIN same_model_tasks f
      ON f.task_name = j.task_name
     AND f.model_name = m.name
     AND f.artifact_path IS NOT DISTINCT FROM m.artifact_path
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
        )
      )
      AND otlet.source_fields_are_allowed(j.input, t.input_shaping)
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
        )
      )
      AND EXISTS (
        SELECT 1
        FROM otlet.tasks t
        WHERE t.name = j.task_name
          AND otlet.source_fields_are_allowed(j.input, t.input_shaping)
      )
    ORDER BY
      candidate.task_job_rank,
      candidate.task_rank
    FOR UPDATE OF j SKIP LOCKED
    LIMIT (SELECT batch_size FROM policy)
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
$$;

CREATE FUNCTION otlet.renew_job_lease(
  job_id bigint,
  expected_claim_token text
) RETURNS TABLE (
  status text,
  leased_until timestamptz
)
LANGUAGE sql
AS $$
  UPDATE otlet.jobs j
  SET leased_until = now() + otlet.effective_job_lease_interval(
    p.default_runtime_options || t.runtime_options,
    p.max_attempt_ms,
    p.job_lease_interval
  )
  FROM otlet.tasks t
  CROSS JOIN otlet.production_policy p
  WHERE j.id = renew_job_lease.job_id
    AND j.claim_token = renew_job_lease.expected_claim_token
    AND j.status IN ('running', 'cancel_requested')
    AND j.leased_until IS NOT NULL
    AND j.leased_until >= now()
    AND t.name = j.task_name
    AND p.name = 'default'
  RETURNING j.status, j.leased_until;
$$;

CREATE FUNCTION otlet.job_terminal_request_hash(
  operation text,
  request jsonb
) RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT encode(
    sha256(convert_to(job_terminal_request_hash.operation || ':' || job_terminal_request_hash.request::text, 'UTF8')),
    'hex'
  )
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
  SELECT j.id, j.task_name, j.subject_id, t.model_name
  INTO v_id, v_task_name, v_subject_id, model_name
  FROM otlet.jobs j
  LEFT JOIN otlet.tasks t ON t.name = j.task_name
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
