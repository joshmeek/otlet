CREATE FUNCTION otlet.finish_canceled_job(
  job_id bigint,
  raw_output text DEFAULT NULL,
  prompt_hash text DEFAULT NULL,
  input_hash text DEFAULT NULL,
  output_schema_hash text DEFAULT NULL,
  raw_output_hash text DEFAULT NULL,
  started_at timestamptz DEFAULT NULL,
  release_runtime boolean DEFAULT true,
  model_name text DEFAULT NULL
) RETURNS SETOF otlet.jobs
LANGUAGE plpgsql
AS $$
DECLARE
  saved_job otlet.jobs%ROWTYPE;
  job_row otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = finish_canceled_job.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
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

  UPDATE otlet.jobs
  SET status = 'canceled',
      leased_until = NULL,
      error = COALESCE(job_row.error, 'canceled'),
      cancel_requested_at = COALESCE(job_row.cancel_requested_at, now()),
      finished_at = now()
  WHERE id = job_row.id
  RETURNING * INTO saved_job;

  PERFORM otlet.record_model_attempt(
    saved_job.id,
    model_row.name,
    raw_output => finish_canceled_job.raw_output,
    prompt_hash => finish_canceled_job.prompt_hash,
    input_hash => finish_canceled_job.input_hash,
    output_schema_hash => finish_canceled_job.output_schema_hash,
    raw_output_hash => COALESCE(finish_canceled_job.raw_output_hash, md5(COALESCE(finish_canceled_job.raw_output, ''))),
    started_at => finish_canceled_job.started_at,
    selection_status => 'failed',
    selection_reason => 'canceled',
    error => saved_job.error,
    receipt_status => 'canceled'
  );

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

CREATE FUNCTION otlet.cancel_job(
  job_id bigint,
  reason text DEFAULT 'canceled by user'
) RETURNS SETOF otlet.jobs
LANGUAGE plpgsql
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  saved_job otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = cancel_job.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF job_row.status = 'queued'
     OR (
       job_row.status = 'running'
       AND (job_row.leased_until IS NULL OR job_row.leased_until < now())
     ) THEN
    UPDATE otlet.jobs
    SET error = cancel_job.reason,
        cancel_requested_at = now()
    WHERE id = job_row.id;

    -- finish_canceled_job fail-closes on missing task/model; terminalize orphans
    -- without a receipt so cancel still succeeds on corrupt lineage.
    SELECT t.model_name
    INTO task_row.model_name
    FROM otlet.tasks t
    WHERE t.name = job_row.task_name;
    IF NOT FOUND THEN
      UPDATE otlet.jobs
      SET status = 'canceled',
          leased_until = NULL,
          error = cancel_job.reason,
          cancel_requested_at = COALESCE(cancel_requested_at, now()),
          finished_at = now()
      WHERE id = job_row.id
      RETURNING * INTO saved_job;
      RETURN NEXT saved_job;
      RETURN;
    END IF;
    SELECT m.name
    INTO model_row.name
    FROM otlet.models m
    WHERE m.name = task_row.model_name;
    IF NOT FOUND THEN
      UPDATE otlet.jobs
      SET status = 'canceled',
          leased_until = NULL,
          error = cancel_job.reason,
          cancel_requested_at = COALESCE(cancel_requested_at, now()),
          finished_at = now()
      WHERE id = job_row.id
      RETURNING * INTO saved_job;
      RETURN NEXT saved_job;
      RETURN;
    END IF;

    RETURN QUERY
      SELECT * FROM otlet.finish_canceled_job(job_row.id, release_runtime => job_row.status = 'running');
    RETURN;
  END IF;

  IF job_row.status = 'running' THEN
    UPDATE otlet.jobs
    SET status = 'cancel_requested',
        error = cancel_job.reason,
        cancel_requested_at = now()
    WHERE id = job_row.id
    RETURNING * INTO saved_job;

    SELECT t.model_name
    INTO task_row.model_name
    FROM otlet.tasks t
    WHERE t.name = saved_job.task_name;
    IF FOUND THEN
      SELECT m.name
      INTO model_row.name
      FROM otlet.models m
      WHERE m.name = task_row.model_name;
      IF FOUND THEN
        PERFORM otlet.record_worker_event(
          'job_cancel_requested',
          saved_job.id,
          'linked_inproc',
          'otlet job cancellation requested',
          jsonb_build_object(
            'task_name', saved_job.task_name,
            'subject_id', saved_job.subject_id,
            'model_name', model_row.name,
            'reason', cancel_job.reason
          )
        );
      END IF;
    END IF;

    RETURN NEXT saved_job;
    RETURN;
  END IF;

  RETURN NEXT job_row;
END;
$$;

