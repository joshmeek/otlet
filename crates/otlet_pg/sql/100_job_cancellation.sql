CREATE FUNCTION otlet.finish_canceled_job(
  job_id bigint,
  raw_output text DEFAULT NULL,
  prompt_hash text DEFAULT NULL,
  input_hash text DEFAULT NULL,
  output_schema_hash text DEFAULT NULL,
  raw_output_hash text DEFAULT NULL,
  started_at timestamptz DEFAULT NULL,
  release_runtime boolean DEFAULT true,
  model_name text DEFAULT NULL,
  expected_claim_token text DEFAULT NULL,
  terminal_request_hash text DEFAULT NULL
) RETURNS SETOF otlet.jobs
LANGUAGE plpgsql
AS $$
DECLARE
  saved_job otlet.jobs%ROWTYPE;
  job_row otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  actual_request_hash text;
BEGIN
  actual_request_hash := COALESCE(
    finish_canceled_job.terminal_request_hash,
    otlet.job_terminal_request_hash(
      'cancel',
      jsonb_build_array(
        finish_canceled_job.raw_output,
        finish_canceled_job.prompt_hash,
        finish_canceled_job.input_hash,
        finish_canceled_job.output_schema_hash,
        finish_canceled_job.raw_output_hash,
        finish_canceled_job.started_at,
        finish_canceled_job.release_runtime,
        finish_canceled_job.model_name
      )
    )
  );

  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = finish_canceled_job.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF job_row.status IN ('complete', 'failed', 'canceled') THEN
    IF finish_canceled_job.expected_claim_token IS NULL
       OR job_row.terminal_claim_token IS DISTINCT FROM finish_canceled_job.expected_claim_token THEN
      RAISE EXCEPTION 'otlet job claim is stale';
    END IF;
    IF job_row.terminal_request_hash IS DISTINCT FROM actual_request_hash THEN
      RAISE EXCEPTION 'otlet conflicting terminal retry';
    END IF;
    RETURN NEXT job_row;
    RETURN;
  END IF;

  IF finish_canceled_job.expected_claim_token IS NULL
     OR job_row.claim_token IS DISTINCT FROM finish_canceled_job.expected_claim_token
     OR job_row.status NOT IN ('running', 'cancel_requested')
     OR job_row.leased_until IS NULL
     OR job_row.leased_until < now() THEN
    RAISE EXCEPTION 'otlet job claim is stale';
  END IF;

  SELECT t.model_name
  INTO task_row.model_name
  FROM otlet.tasks t
  WHERE t.name = job_row.task_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', job_row.task_name;
  END IF;
  SELECT m.name
  INTO model_row.name
  FROM otlet.models m
  WHERE m.name = COALESCE(finish_canceled_job.model_name, task_row.model_name);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet model % does not exist',
      COALESCE(finish_canceled_job.model_name, task_row.model_name);
  END IF;

  PERFORM otlet.record_model_attempt(
    job_row.id,
    model_row.name,
    raw_output => finish_canceled_job.raw_output,
    prompt_hash => finish_canceled_job.prompt_hash,
    input_hash => finish_canceled_job.input_hash,
    output_schema_hash => finish_canceled_job.output_schema_hash,
    raw_output_hash => COALESCE(finish_canceled_job.raw_output_hash, md5(COALESCE(finish_canceled_job.raw_output, ''))),
    started_at => finish_canceled_job.started_at,
    selection_status => 'failed',
    selection_reason => 'canceled',
    error => COALESCE(job_row.error, 'canceled'),
    receipt_status => 'canceled',
    expected_claim_token => finish_canceled_job.expected_claim_token
  );

  UPDATE otlet.jobs
  SET status = 'canceled',
      leased_until = NULL,
      claim_token = NULL,
      terminal_claim_token = finish_canceled_job.expected_claim_token,
      terminal_request_hash = actual_request_hash,
      error = COALESCE(job_row.error, 'canceled'),
      cancel_requested_at = COALESCE(job_row.cancel_requested_at, now()),
      finished_at = now()
  WHERE id = job_row.id
  RETURNING * INTO saved_job;

  IF finish_canceled_job.release_runtime THEN
    PERFORM otlet.touch_runtime_slot(model_row.name, 'ready', 0, NULL);
  END IF;

  PERFORM otlet.record_worker_event(
    'job_canceled',
    saved_job.id,
    'linked_inproc',
    'otlet job canceled',
    jsonb_build_object(
      'task_name', saved_job.task_name,
      'subject_id', saved_job.subject_id,
      'model_name', model_row.name,
      'release_runtime', finish_canceled_job.release_runtime
    )
  );

  RETURN NEXT saved_job;
END;
$$;

CREATE FUNCTION otlet.request_job_cancellation(
  job_id bigint,
  reason text DEFAULT 'canceled by user'
) RETURNS SETOF otlet.jobs
LANGUAGE plpgsql
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = request_job_cancellation.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF job_row.status IN ('complete', 'failed', 'canceled') THEN
    RETURN NEXT job_row;
    RETURN;
  END IF;

  IF job_row.status IN ('running', 'cancel_requested')
     AND job_row.leased_until IS NOT NULL
     AND job_row.leased_until >= now() THEN
    IF job_row.status = 'running' THEN
      UPDATE otlet.jobs
      SET status = 'cancel_requested',
          error = request_job_cancellation.reason,
          cancel_requested_at = now()
      WHERE id = job_row.id
      RETURNING * INTO job_row;

      PERFORM otlet.record_worker_event(
        'job_cancel_requested',
        job_row.id,
        'linked_inproc',
        'otlet job cancellation requested',
        jsonb_build_object(
          'task_name', job_row.task_name,
          'subject_id', job_row.subject_id,
          'model_name', t.model_name,
          'reason', request_job_cancellation.reason
        )
      )
      FROM otlet.tasks t
      WHERE t.name = job_row.task_name;
    END IF;

    RETURN NEXT job_row;
    RETURN;
  END IF;

  IF job_row.status IN ('queued', 'running', 'cancel_requested') THEN
    UPDATE otlet.jobs j
    SET status = 'cancel_requested',
        attempts = attempts + 1,
        leased_until = now() + otlet.effective_job_lease_interval(
          p.default_runtime_options || t.runtime_options,
          p.max_attempt_ms,
          p.job_lease_interval
        ),
        claim_token = gen_random_uuid()::text,
        error = request_job_cancellation.reason,
        cancel_requested_at = now()
    FROM otlet.tasks t
    CROSS JOIN otlet.production_policy p
    WHERE j.id = job_row.id
      AND t.name = j.task_name
      AND p.name = 'default'
    RETURNING j.* INTO job_row;

    RETURN QUERY
      SELECT * FROM otlet.cancel_job(
        job_row.id,
        job_row.claim_token,
        request_job_cancellation.reason
      );
    RETURN;
  END IF;
END;
$$;

CREATE FUNCTION otlet.cancel_job(
  job_id bigint,
  expected_claim_token text,
  reason text DEFAULT 'canceled'
) RETURNS SETOF otlet.jobs
LANGUAGE plpgsql
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  request_hash text := otlet.job_terminal_request_hash(
    'cancel',
    jsonb_build_array(cancel_job.reason)
  );
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = cancel_job.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF job_row.status IN ('complete', 'failed', 'canceled') THEN
    IF cancel_job.expected_claim_token IS NULL
       OR job_row.terminal_claim_token IS DISTINCT FROM cancel_job.expected_claim_token THEN
      RAISE EXCEPTION 'otlet job claim is stale';
    END IF;
    IF job_row.terminal_request_hash IS DISTINCT FROM request_hash THEN
      RAISE EXCEPTION 'otlet conflicting terminal retry';
    END IF;
    RETURN NEXT job_row;
    RETURN;
  END IF;

  IF cancel_job.expected_claim_token IS NULL
     OR job_row.claim_token IS DISTINCT FROM cancel_job.expected_claim_token
     OR job_row.status NOT IN ('running', 'cancel_requested')
     OR job_row.leased_until IS NULL
     OR job_row.leased_until < now() THEN
    RAISE EXCEPTION 'otlet job claim is stale';
  END IF;

  UPDATE otlet.jobs
  SET status = 'cancel_requested',
      error = cancel_job.reason,
      cancel_requested_at = COALESCE(cancel_requested_at, now())
  WHERE id = job_row.id;

  RETURN QUERY
    SELECT *
    FROM otlet.finish_canceled_job(
      job_row.id,
      release_runtime => true,
      expected_claim_token => cancel_job.expected_claim_token,
      terminal_request_hash => request_hash
    );
END;
$$;
