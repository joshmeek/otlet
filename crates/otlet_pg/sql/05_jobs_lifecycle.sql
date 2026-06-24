-- Atomic queue claim for the resident worker; returns zero rows when no work exists
CREATE FUNCTION otlet.claim_job() RETURNS SETOF otlet.jobs
LANGUAGE sql
AS $$
  WITH next_job AS (
    SELECT j.id
    FROM otlet.jobs j
    JOIN otlet.tasks t ON t.name = j.task_name
    JOIN otlet.models m ON m.name = t.model_name
    LEFT JOIN (
      SELECT
        t.model_name,
        count(*) FILTER (
          WHERE j.status = 'running'
            AND (j.leased_until IS NULL OR j.leased_until >= now())
        ) AS running_jobs,
        count(*) FILTER (
          WHERE j.status = 'cancel_requested'
            AND j.leased_until >= now()
        ) AS cancel_requested_jobs
      FROM otlet.jobs j
      JOIN otlet.tasks t ON t.name = j.task_name
      GROUP BY t.model_name
    ) active_model ON active_model.model_name = m.name
    LEFT JOIN otlet.runtime_slots s
      ON s.runtime_name = m.runtime_name
     AND s.model_name = m.name
    WHERE (
        j.status = 'queued'
        OR (
          j.status = 'running'
          AND j.leased_until < now()
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
    ORDER BY
      CASE WHEN s.status = 'ready' AND s.artifact_path IS NOT DISTINCT FROM m.artifact_path THEN 0 ELSE 1 END,
      CASE WHEN j.status IN ('running', 'cancel_requested') AND (j.leased_until IS NULL OR j.leased_until < now()) THEN 0 ELSE 1 END,
      j.created_at,
      j.id
    FOR UPDATE OF j SKIP LOCKED
    LIMIT 1
  )
  UPDATE otlet.jobs j
  SET status = CASE WHEN j.status = 'cancel_requested' THEN 'cancel_requested' ELSE 'running' END,
      attempts = attempts + 1,
      leased_until = now() + interval '5 minutes',
      error = CASE WHEN j.status = 'cancel_requested' THEN j.error ELSE NULL END,
      raw_output = NULL,
      started_at = now(),
      finished_at = NULL
  FROM next_job
  WHERE j.id = next_job.id
  RETURNING j.*;
$$;

CREATE FUNCTION otlet.mark_job_started(job_id bigint) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  runtime_row otlet.runtimes%ROWTYPE;
BEGIN
  SELECT * INTO job_row FROM otlet.jobs WHERE id = mark_job_started.job_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  UPDATE otlet.jobs
  SET started_at = COALESCE(started_at, now())
  WHERE id = job_row.id;

  SELECT * INTO task_row FROM otlet.tasks WHERE name = job_row.task_name;
  SELECT * INTO model_row FROM otlet.models WHERE name = task_row.model_name;
  SELECT * INTO runtime_row FROM otlet.runtimes WHERE name = model_row.runtime_name;

  PERFORM otlet.mark_runtime_health(runtime_row.name, 'running', NULL);
  PERFORM otlet.touch_runtime_slot(runtime_row.name, model_row.name, 'running', 1, NULL);
  PERFORM otlet.record_worker_event(
    'job_started',
    job_row.id,
    runtime_row.name,
    'otlet worker started job',
    jsonb_build_object(
      'task_name', job_row.task_name,
      'subject_id', job_row.subject_id,
      'model_name', model_row.name
    )
  );
END;
$$;

CREATE FUNCTION otlet.finish_canceled_job(
  job_id bigint,
  raw_output text DEFAULT NULL,
  prompt_hash text DEFAULT NULL,
  input_hash text DEFAULT NULL,
  output_schema_hash text DEFAULT NULL,
  raw_output_hash text DEFAULT NULL,
  started_at timestamptz DEFAULT NULL,
  release_runtime boolean DEFAULT true
) RETURNS SETOF otlet.jobs
LANGUAGE plpgsql
AS $$
DECLARE
  saved_job otlet.jobs%ROWTYPE;
  job_row otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  runtime_row otlet.runtimes%ROWTYPE;
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = finish_canceled_job.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT * INTO task_row FROM otlet.tasks WHERE name = job_row.task_name;
  SELECT * INTO model_row FROM otlet.models WHERE name = task_row.model_name;
  SELECT * INTO runtime_row FROM otlet.runtimes WHERE name = model_row.runtime_name;

  UPDATE otlet.jobs
  SET status = 'canceled',
      leased_until = NULL,
      error = COALESCE(job_row.error, 'canceled'),
      raw_output = finish_canceled_job.raw_output,
      cancel_requested_at = COALESCE(job_row.cancel_requested_at, now()),
      finished_at = now()
  WHERE id = job_row.id
  RETURNING * INTO saved_job;

  INSERT INTO otlet.inference_receipts (
    job_id,
    task_name,
    subject_id,
    model_name,
    model_artifact_path,
    model_artifact_hash,
    runtime_name,
    runtime_endpoint,
    runtime_options,
    prompt_hash,
    input_hash,
    output_schema_hash,
    raw_output_hash,
    started_at,
    status,
    error
  )
  VALUES (
    saved_job.id,
    saved_job.task_name,
    saved_job.subject_id,
    model_row.name,
    model_row.artifact_path,
    model_row.artifact_hash,
    runtime_row.name,
    runtime_row.endpoint,
    task_row.runtime_options,
    finish_canceled_job.prompt_hash,
    finish_canceled_job.input_hash,
    finish_canceled_job.output_schema_hash,
    COALESCE(finish_canceled_job.raw_output_hash, md5(COALESCE(finish_canceled_job.raw_output, ''))),
    COALESCE(finish_canceled_job.started_at, saved_job.started_at, saved_job.created_at, now()),
    'canceled',
    saved_job.error
  )
  ON CONFLICT ON CONSTRAINT inference_receipts_job_id_key DO UPDATE
    SET finished_at = now(),
        status = EXCLUDED.status,
        error = EXCLUDED.error,
        raw_output_hash = EXCLUDED.raw_output_hash;

  IF finish_canceled_job.release_runtime THEN
    PERFORM otlet.mark_runtime_health(runtime_row.name, 'ready', NULL);
    PERFORM otlet.touch_runtime_slot(runtime_row.name, model_row.name, 'ready', 0, NULL);
  END IF;

  PERFORM otlet.record_worker_event(
    'job_canceled',
    saved_job.id,
    runtime_row.name,
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
  runtime_row otlet.runtimes%ROWTYPE;
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = cancel_job.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF job_row.status = 'queued'
     OR (job_row.status = 'running' AND job_row.leased_until < now()) THEN
    UPDATE otlet.jobs
    SET error = cancel_job.reason,
        cancel_requested_at = now()
    WHERE id = job_row.id;

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

    SELECT * INTO task_row FROM otlet.tasks WHERE name = saved_job.task_name;
    SELECT * INTO model_row FROM otlet.models WHERE name = task_row.model_name;
    SELECT * INTO runtime_row FROM otlet.runtimes WHERE name = model_row.runtime_name;

    PERFORM otlet.record_worker_event(
      'job_cancel_requested',
      saved_job.id,
      runtime_row.name,
      'otlet job cancellation requested',
      jsonb_build_object(
        'task_name', saved_job.task_name,
        'subject_id', saved_job.subject_id,
        'model_name', model_row.name,
        'reason', cancel_job.reason
      )
    );

    RETURN NEXT saved_job;
    RETURN;
  END IF;

  RETURN NEXT job_row;
END;
$$;

CREATE FUNCTION otlet.complete_job(
  job_id bigint,
  output jsonb,
  raw_output text,
  actions jsonb DEFAULT '[]'::jsonb,
  prompt_hash text DEFAULT NULL,
  input_hash text DEFAULT NULL,
  output_schema_hash text DEFAULT NULL,
  raw_output_hash text DEFAULT NULL,
  started_at timestamptz DEFAULT NULL,
  trace_summary jsonb DEFAULT '{}'::jsonb
) RETURNS SETOF otlet.outputs
LANGUAGE plpgsql
AS $$
DECLARE
  saved_output otlet.outputs%ROWTYPE;
  job_row otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  runtime_row otlet.runtimes%ROWTYPE;
  action jsonb;
  saved_action_id bigint;
  action_error text;
  action_type text;
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = complete_job.job_id
    AND status IN ('running', 'cancel_requested')
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF job_row.status = 'cancel_requested' THEN
    PERFORM 1
    FROM otlet.finish_canceled_job(
      complete_job.job_id,
      complete_job.raw_output,
      complete_job.prompt_hash,
      complete_job.input_hash,
      complete_job.output_schema_hash,
      COALESCE(complete_job.raw_output_hash, md5(complete_job.raw_output)),
      complete_job.started_at,
      true
    );
    RETURN;
  END IF;

  UPDATE otlet.jobs
  SET status = 'complete',
      leased_until = NULL,
      error = NULL,
      raw_output = NULL,
      finished_at = now()
  WHERE id = complete_job.job_id
  RETURNING * INTO job_row;

  SELECT * INTO task_row FROM otlet.tasks WHERE name = job_row.task_name;
  SELECT * INTO model_row FROM otlet.models WHERE name = task_row.model_name;
  SELECT * INTO runtime_row FROM otlet.runtimes WHERE name = model_row.runtime_name;

  INSERT INTO otlet.outputs (job_id, output, raw_output)
  VALUES (complete_job.job_id, complete_job.output, complete_job.raw_output)
  RETURNING * INTO saved_output;

  INSERT INTO otlet.inference_receipts (
    job_id,
    task_name,
    subject_id,
    model_name,
    model_artifact_path,
    model_artifact_hash,
    runtime_name,
    runtime_endpoint,
    runtime_options,
    prompt_hash,
    input_hash,
    output_schema_hash,
    raw_output_hash,
    prompt_tokens,
    generated_tokens,
    generate_ms,
    tokens_per_second,
    schema_validation_status,
    trace_summary,
    started_at,
    status,
    error
  )
  VALUES (
    job_row.id,
    job_row.task_name,
    job_row.subject_id,
    model_row.name,
    model_row.artifact_path,
    model_row.artifact_hash,
    runtime_row.name,
    runtime_row.endpoint,
    task_row.runtime_options,
    complete_job.prompt_hash,
    complete_job.input_hash,
    complete_job.output_schema_hash,
    COALESCE(complete_job.raw_output_hash, md5(complete_job.raw_output)),
    NULLIF(complete_job.trace_summary ->> 'prompt_tokens', '')::bigint,
    NULLIF(complete_job.trace_summary ->> 'generated_tokens', '')::bigint,
    NULLIF(complete_job.trace_summary ->> 'generate_ms', '')::bigint,
    NULLIF(complete_job.trace_summary ->> 'tokens_per_second', '')::numeric,
    complete_job.trace_summary ->> 'schema_validation_status',
    COALESCE(complete_job.trace_summary, '{}'::jsonb),
    COALESCE(complete_job.started_at, job_row.started_at, now()),
    'complete',
    NULL
  )
  ON CONFLICT ON CONSTRAINT inference_receipts_job_id_key DO UPDATE
    SET finished_at = now(),
        status = EXCLUDED.status,
        error = NULL,
        raw_output_hash = EXCLUDED.raw_output_hash,
        prompt_tokens = EXCLUDED.prompt_tokens,
        generated_tokens = EXCLUDED.generated_tokens,
        generate_ms = EXCLUDED.generate_ms,
        tokens_per_second = EXCLUDED.tokens_per_second,
        schema_validation_status = EXCLUDED.schema_validation_status,
        trace_summary = EXCLUDED.trace_summary;

  UPDATE otlet.models
  SET last_used_at = now()
  WHERE name = model_row.name;

  PERFORM otlet.mark_runtime_health(runtime_row.name, 'ready', NULL);
  PERFORM otlet.touch_runtime_slot(runtime_row.name, model_row.name, 'ready', 0, NULL);
  PERFORM otlet.record_worker_event(
    'job_completed',
    job_row.id,
    runtime_row.name,
    'otlet worker completed job',
    jsonb_build_object(
      'task_name', job_row.task_name,
      'subject_id', job_row.subject_id,
      'model_name', model_row.name
    )
  );

  FOR action IN SELECT value FROM jsonb_array_elements(complete_job.actions) LOOP
    action_type := COALESCE(action ->> 'type', '');
    action_error := NULL;

    IF action_type = 'create_record' THEN
      IF action ->> 'record_type' IS NULL THEN
        action_error := 'create_record missing record_type';
      ELSIF jsonb_typeof(action -> 'body') IS DISTINCT FROM 'object' THEN
        action_error := 'create_record body must be an object';
      END IF;
    ELSE
      action_error := 'unsupported action type';
    END IF;

    INSERT INTO otlet.actions (job_id, output_id, action_type, payload, status, error)
    VALUES (
      complete_job.job_id,
      saved_output.id,
      action_type,
      action,
      CASE WHEN action_error IS NULL THEN 'complete' ELSE 'rejected' END,
      action_error
    )
    RETURNING id INTO saved_action_id;

    IF action_error IS NULL THEN
      INSERT INTO otlet.records (action_id, record_type, subject_id, body)
      VALUES (
        saved_action_id,
        action ->> 'record_type',
        action ->> 'subject_id',
        action -> 'body'
      );
    END IF;
  END LOOP;

  RETURN NEXT saved_output;
END;
$$;

CREATE FUNCTION otlet.fail_job(
  job_id bigint,
  error text,
  raw_output text DEFAULT NULL,
  prompt_hash text DEFAULT NULL,
  input_hash text DEFAULT NULL,
  output_schema_hash text DEFAULT NULL,
  raw_output_hash text DEFAULT NULL,
  started_at timestamptz DEFAULT NULL
) RETURNS SETOF otlet.jobs
LANGUAGE plpgsql
AS $$
DECLARE
  saved_job otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  runtime_row otlet.runtimes%ROWTYPE;
BEGIN
  SELECT * INTO saved_job
  FROM otlet.jobs
  WHERE id = fail_job.job_id
    AND status IN ('running', 'cancel_requested')
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF saved_job.status = 'cancel_requested' THEN
    RETURN QUERY
      SELECT *
      FROM otlet.finish_canceled_job(
        fail_job.job_id,
        fail_job.raw_output,
        fail_job.prompt_hash,
        fail_job.input_hash,
        fail_job.output_schema_hash,
        fail_job.raw_output_hash,
        fail_job.started_at,
        true
      );
    RETURN;
  END IF;

  UPDATE otlet.jobs
  SET status = 'failed',
      leased_until = NULL,
      error = fail_job.error,
      raw_output = fail_job.raw_output,
      finished_at = now()
  WHERE id = fail_job.job_id
  RETURNING * INTO saved_job;

  SELECT * INTO task_row FROM otlet.tasks WHERE name = saved_job.task_name;
  SELECT * INTO model_row FROM otlet.models WHERE name = task_row.model_name;
  SELECT * INTO runtime_row FROM otlet.runtimes WHERE name = model_row.runtime_name;

  INSERT INTO otlet.inference_receipts (
    job_id,
    task_name,
    subject_id,
    model_name,
    model_artifact_path,
    model_artifact_hash,
    runtime_name,
    runtime_endpoint,
    runtime_options,
    prompt_hash,
    input_hash,
    output_schema_hash,
    raw_output_hash,
    started_at,
    status,
    error
  )
  VALUES (
    saved_job.id,
    saved_job.task_name,
    saved_job.subject_id,
    model_row.name,
    model_row.artifact_path,
    model_row.artifact_hash,
    runtime_row.name,
    runtime_row.endpoint,
    task_row.runtime_options,
    fail_job.prompt_hash,
    fail_job.input_hash,
    fail_job.output_schema_hash,
    COALESCE(fail_job.raw_output_hash, md5(COALESCE(fail_job.raw_output, ''))),
    COALESCE(fail_job.started_at, saved_job.started_at, now()),
    'failed',
    fail_job.error
  )
  ON CONFLICT ON CONSTRAINT inference_receipts_job_id_key DO UPDATE
    SET finished_at = now(),
        status = EXCLUDED.status,
        error = EXCLUDED.error,
        raw_output_hash = EXCLUDED.raw_output_hash;

  PERFORM otlet.mark_runtime_health(runtime_row.name, 'error', fail_job.error);
  PERFORM otlet.touch_runtime_slot(runtime_row.name, model_row.name, 'error', 0, fail_job.error);
  PERFORM otlet.record_worker_event(
    'job_failed',
    saved_job.id,
    runtime_row.name,
    'otlet worker failed job',
    jsonb_build_object(
      'task_name', saved_job.task_name,
      'subject_id', saved_job.subject_id,
      'model_name', model_row.name,
      'error', fail_job.error
    )
  );

  RETURN NEXT saved_job;
END;
$$;
