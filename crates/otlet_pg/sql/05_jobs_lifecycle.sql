-- Atomic queue claim for the resident worker; returns zero rows when no work exists
CREATE FUNCTION otlet.claim_jobs() RETURNS SETOF otlet.jobs
LANGUAGE sql
AS $$
  WITH policy AS (
    SELECT
      worker_claim_batch_size AS batch_size,
      max_attempts,
      job_lease_interval
    FROM otlet.production_policy
  ),
  active_model AS (
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
  ),
  first_job AS (
    SELECT
      j.id,
      j.task_name,
      m.name AS model_name,
      m.runtime_name,
      m.artifact_path
    FROM otlet.jobs j
    JOIN otlet.tasks t ON t.name = j.task_name
    JOIN otlet.models m ON m.name = t.model_name
    CROSS JOIN policy p
    LEFT JOIN active_model ON active_model.model_name = m.name
    LEFT JOIN otlet.runtime_slots s
      ON s.runtime_name = m.runtime_name
     AND s.model_name = m.name
    WHERE (
        j.status = 'queued'
        OR (
          j.status = 'running'
          AND j.leased_until < now()
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
    ORDER BY
      CASE WHEN s.status = 'ready' AND s.artifact_path IS NOT DISTINCT FROM m.artifact_path THEN 0 ELSE 1 END,
      CASE WHEN j.status IN ('running', 'cancel_requested') AND (j.leased_until IS NULL OR j.leased_until < now()) THEN 0 ELSE 1 END,
      j.created_at,
      j.id
    FOR UPDATE OF j SKIP LOCKED
    LIMIT 1
  ),
  claimable AS (
    SELECT j.id
    FROM otlet.jobs j
    JOIN otlet.tasks t ON t.name = j.task_name
    JOIN otlet.models m ON m.name = t.model_name
    JOIN first_job f
      ON f.task_name = j.task_name
     AND f.model_name = m.name
     AND f.runtime_name = m.runtime_name
     AND f.artifact_path IS NOT DISTINCT FROM m.artifact_path
    CROSS JOIN policy p
    WHERE (
        j.status = 'queued'
        OR (
          j.status = 'running'
          AND j.leased_until < now()
          AND j.attempts < p.max_attempts
        )
        OR (
          j.status = 'cancel_requested'
          AND (j.leased_until IS NULL OR j.leased_until < now())
        )
      )
    ORDER BY
      CASE WHEN j.id = f.id THEN 0 ELSE 1 END,
      CASE WHEN j.status IN ('running', 'cancel_requested') AND (j.leased_until IS NULL OR j.leased_until < now()) THEN 0 ELSE 1 END,
      j.created_at,
      j.id
    FOR UPDATE OF j SKIP LOCKED
    LIMIT (SELECT batch_size FROM policy)
  ),
  updated AS (
    UPDATE otlet.jobs j
    SET status = CASE WHEN j.status = 'cancel_requested' THEN 'cancel_requested' ELSE 'running' END,
        attempts = attempts + 1,
        leased_until = now() + p.job_lease_interval,
        error = CASE WHEN j.status = 'cancel_requested' THEN j.error ELSE NULL END,
        raw_output = NULL,
        started_at = now(),
        finished_at = NULL
    FROM claimable
    CROSS JOIN policy p
    WHERE j.id = claimable.id
    RETURNING j.*
  )
  SELECT * FROM updated ORDER BY created_at, id;
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

CREATE FUNCTION otlet.record_model_attempt(
  job_id bigint,
  model_name text,
  output jsonb DEFAULT NULL,
  raw_output text DEFAULT NULL,
  prompt_hash text DEFAULT NULL,
  input_hash text DEFAULT NULL,
  output_schema_hash text DEFAULT NULL,
  raw_output_hash text DEFAULT NULL,
  started_at timestamptz DEFAULT NULL,
  trace_summary jsonb DEFAULT '{}'::jsonb,
  schema_validation_status text DEFAULT NULL,
  selection_role text DEFAULT 'direct',
  selection_status text DEFAULT 'accepted',
  selection_reason text DEFAULT NULL,
  error text DEFAULT NULL,
  receipt_status text DEFAULT NULL
) RETURNS otlet.inference_receipts
LANGUAGE plpgsql
AS $$
DECLARE
  saved_receipt otlet.inference_receipts%ROWTYPE;
  saved_output otlet.outputs%ROWTYPE;
  job_row otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  runtime_row otlet.runtimes%ROWTYPE;
  next_attempt int;
  actual_selection_status text := COALESCE(record_model_attempt.selection_status, 'accepted');
BEGIN
  SELECT *
  INTO job_row
  FROM otlet.jobs
  WHERE id = record_model_attempt.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet job % does not exist', record_model_attempt.job_id;
  END IF;

  SELECT * INTO task_row FROM otlet.tasks WHERE name = job_row.task_name;
  SELECT * INTO model_row FROM otlet.models WHERE name = record_model_attempt.model_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet model % does not exist', record_model_attempt.model_name;
  END IF;
  SELECT * INTO runtime_row FROM otlet.runtimes WHERE name = model_row.runtime_name;

  SELECT COALESCE(max(r.attempt_index), 0) + 1
  INTO next_attempt
  FROM otlet.inference_receipts r
  WHERE r.job_id = job_row.id;

  INSERT INTO otlet.inference_receipts (
    job_id,
    attempt_index,
    selection_role,
    selection_status,
    selection_reason,
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
    raw_output,
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
    next_attempt,
    COALESCE(record_model_attempt.selection_role, 'direct'),
    actual_selection_status,
    record_model_attempt.selection_reason,
    job_row.task_name,
    job_row.subject_id,
    model_row.name,
    model_row.artifact_path,
    model_row.artifact_hash,
    runtime_row.name,
    runtime_row.endpoint,
    task_row.runtime_options,
    record_model_attempt.prompt_hash,
    record_model_attempt.input_hash,
    record_model_attempt.output_schema_hash,
    COALESCE(record_model_attempt.raw_output_hash, md5(COALESCE(record_model_attempt.raw_output, ''))),
    record_model_attempt.raw_output,
    NULLIF(record_model_attempt.trace_summary ->> 'prompt_tokens', '')::bigint,
    NULLIF(record_model_attempt.trace_summary ->> 'generated_tokens', '')::bigint,
    NULLIF(record_model_attempt.trace_summary ->> 'generate_ms', '')::bigint,
    NULLIF(record_model_attempt.trace_summary ->> 'tokens_per_second', '')::numeric,
    COALESCE(record_model_attempt.schema_validation_status, record_model_attempt.trace_summary ->> 'schema_validation_status'),
    COALESCE(record_model_attempt.trace_summary, '{}'::jsonb),
    COALESCE(record_model_attempt.started_at, job_row.started_at, job_row.created_at, now()),
    COALESCE(
      record_model_attempt.receipt_status,
      CASE actual_selection_status
        WHEN 'accepted' THEN 'complete'
        WHEN 'rejected' THEN 'rejected'
        ELSE 'failed'
      END
    ),
    record_model_attempt.error
  )
  RETURNING * INTO saved_receipt;

  IF actual_selection_status = 'accepted' AND record_model_attempt.output IS NOT NULL THEN
    INSERT INTO otlet.outputs (job_id, receipt_id, output, raw_output)
    VALUES (
      job_row.id,
      saved_receipt.id,
      record_model_attempt.output,
      COALESCE(record_model_attempt.raw_output, '')
    )
    RETURNING * INTO saved_output;
  END IF;

  UPDATE otlet.models
  SET last_used_at = now()
  WHERE name = model_row.name;

  RETURN saved_receipt;
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
  SELECT * INTO model_row FROM otlet.models WHERE name = COALESCE(finish_canceled_job.model_name, task_row.model_name);
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
  trace_summary jsonb DEFAULT '{}'::jsonb,
  model_name text DEFAULT NULL,
  selection_role text DEFAULT 'direct',
  selection_status text DEFAULT 'accepted',
  selection_reason text DEFAULT NULL
) RETURNS SETOF otlet.outputs
LANGUAGE plpgsql
AS $$
DECLARE
  saved_output otlet.outputs%ROWTYPE;
  saved_receipt otlet.inference_receipts%ROWTYPE;
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

  SELECT * INTO task_row FROM otlet.tasks WHERE name = job_row.task_name;
  SELECT * INTO model_row FROM otlet.models WHERE name = COALESCE(complete_job.model_name, task_row.model_name);
  SELECT * INTO runtime_row FROM otlet.runtimes WHERE name = model_row.runtime_name;

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
      true,
      model_row.name
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

  SELECT *
  INTO saved_receipt
  FROM otlet.record_model_attempt(
    job_row.id,
    model_row.name,
    output => complete_job.output,
    raw_output => complete_job.raw_output,
    prompt_hash => complete_job.prompt_hash,
    input_hash => complete_job.input_hash,
    output_schema_hash => complete_job.output_schema_hash,
    raw_output_hash => COALESCE(complete_job.raw_output_hash, md5(complete_job.raw_output)),
    started_at => complete_job.started_at,
    trace_summary => complete_job.trace_summary,
    selection_role => COALESCE(complete_job.selection_role, 'direct'),
    selection_status => COALESCE(complete_job.selection_status, 'accepted'),
    selection_reason => complete_job.selection_reason,
    error => NULL
  );

  SELECT *
  INTO saved_output
  FROM otlet.outputs
  WHERE receipt_id = saved_receipt.id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

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
      'model_name', model_row.name,
      'selection_role', COALESCE(complete_job.selection_role, 'direct'),
      'selection_reason', complete_job.selection_reason
    )
  );

  FOR action IN SELECT value FROM jsonb_array_elements(COALESCE(complete_job.actions, '[]'::jsonb)) LOOP
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
  started_at timestamptz DEFAULT NULL,
  schema_validation_status text DEFAULT NULL,
  trace_summary jsonb DEFAULT '{}'::jsonb,
  model_name text DEFAULT NULL,
  selection_role text DEFAULT 'direct',
  selection_status text DEFAULT 'failed',
  selection_reason text DEFAULT NULL
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

  SELECT * INTO task_row FROM otlet.tasks WHERE name = saved_job.task_name;
  SELECT * INTO model_row FROM otlet.models WHERE name = COALESCE(fail_job.model_name, task_row.model_name);
  SELECT * INTO runtime_row FROM otlet.runtimes WHERE name = model_row.runtime_name;

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
        true,
        model_row.name
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

  PERFORM otlet.record_model_attempt(
    saved_job.id,
    model_row.name,
    raw_output => fail_job.raw_output,
    prompt_hash => fail_job.prompt_hash,
    input_hash => fail_job.input_hash,
    output_schema_hash => fail_job.output_schema_hash,
    raw_output_hash => COALESCE(fail_job.raw_output_hash, md5(COALESCE(fail_job.raw_output, ''))),
    started_at => fail_job.started_at,
    trace_summary => COALESCE(fail_job.trace_summary, '{}'::jsonb),
    schema_validation_status => fail_job.schema_validation_status,
    selection_role => COALESCE(fail_job.selection_role, 'direct'),
    selection_status => COALESCE(fail_job.selection_status, 'failed'),
    selection_reason => fail_job.selection_reason,
    error => fail_job.error
  );

  IF fail_job.schema_validation_status = 'failed' THEN
    PERFORM otlet.mark_runtime_health(runtime_row.name, 'ready', NULL);
    PERFORM otlet.touch_runtime_slot(runtime_row.name, model_row.name, 'ready', 0, NULL);
  ELSE
    PERFORM otlet.mark_runtime_health(runtime_row.name, 'error', fail_job.error);
    PERFORM otlet.touch_runtime_slot(runtime_row.name, model_row.name, 'error', 0, fail_job.error);
  END IF;
  PERFORM otlet.record_worker_event(
    'job_failed',
    saved_job.id,
    runtime_row.name,
    'otlet worker failed job',
    jsonb_build_object(
      'task_name', saved_job.task_name,
      'subject_id', saved_job.subject_id,
      'model_name', model_row.name,
      'selection_role', COALESCE(fail_job.selection_role, 'direct'),
      'error', fail_job.error
    )
  );

  RETURN NEXT saved_job;
END;
$$;

CREATE FUNCTION otlet.sweep_expired_jobs() RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  runtime_row otlet.runtimes%ROWTYPE;
  swept bigint := 0;
BEGIN
  FOR job_row IN
    SELECT j.*
    FROM otlet.jobs j
    CROSS JOIN otlet.production_policy p
    WHERE j.status = 'running'
      AND j.leased_until < now()
      AND j.attempts >= p.max_attempts
    ORDER BY j.id
    FOR UPDATE
  LOOP
    SELECT * INTO task_row FROM otlet.tasks WHERE name = job_row.task_name;
    SELECT * INTO model_row FROM otlet.models WHERE name = task_row.model_name;
    SELECT * INTO runtime_row FROM otlet.runtimes WHERE name = model_row.runtime_name;

    UPDATE otlet.jobs
    SET status = 'failed',
        leased_until = NULL,
        error = 'job lease expired after max attempts',
        raw_output = COALESCE(job_row.raw_output, ''),
        finished_at = now()
    WHERE id = job_row.id
    RETURNING * INTO job_row;

    PERFORM otlet.record_model_attempt(
      job_row.id,
      model_row.name,
      raw_output => COALESCE(job_row.raw_output, ''),
      raw_output_hash => md5(COALESCE(job_row.raw_output, '')),
      trace_summary => jsonb_build_object('schema_validation_status', 'not_run'),
      schema_validation_status => 'not_run',
      started_at => COALESCE(job_row.started_at, job_row.created_at, now()),
      selection_status => 'failed',
      selection_reason => 'job_lease_expired_after_max_attempts',
      error => job_row.error
    );

    PERFORM otlet.mark_runtime_health(runtime_row.name, 'error', job_row.error);
    PERFORM otlet.touch_runtime_slot(runtime_row.name, model_row.name, 'error', 0, job_row.error);
    swept := swept + 1;
  END LOOP;

  IF swept > 0 THEN
    PERFORM otlet.record_worker_event(
      'expired_job_sweep',
      NULL,
      NULL,
      'otlet expired running jobs failed after max attempts',
      jsonb_build_object('failed_jobs', swept)
    );
  END IF;

  RETURN swept;
END;
$$;
