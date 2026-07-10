-- Atomic queue claim for the resident worker; returns zero rows when no work exists
CREATE FUNCTION otlet.claim_jobs() RETURNS SETOF otlet.jobs
LANGUAGE sql
AS $$
  WITH policy AS (
    SELECT
      worker_claim_batch_size AS batch_size,
      worker_claim_task_cursor AS task_cursor,
      max_attempts,
      job_lease_interval
    FROM otlet.production_policy
    WHERE name = 'default'
    FOR UPDATE
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
    GROUP BY
      j.task_name,
      m.name,
      m.artifact_path
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
  claimable AS (
    SELECT j.id
    FROM otlet.jobs j
    JOIN otlet.tasks t ON t.name = j.task_name
    JOIN otlet.models m ON m.name = t.model_name
    JOIN selected_task f
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
    ORDER BY
      CASE WHEN j.id = f.first_job_id THEN 0 ELSE 1 END,
      CASE WHEN j.status IN ('running', 'cancel_requested') AND (j.leased_until IS NULL OR j.leased_until < now()) THEN 0 ELSE 1 END,
      j.created_at,
      j.id
    FOR UPDATE OF j SKIP LOCKED
    LIMIT (SELECT batch_size FROM policy)
  ),
  advance_cursor AS (
    UPDATE otlet.production_policy p
    SET worker_claim_task_cursor = (SELECT task_name FROM selected_task)
    WHERE p.name = 'default'
      AND EXISTS (SELECT 1 FROM claimable)
    RETURNING p.worker_claim_task_cursor
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
    CROSS JOIN advance_cursor
    WHERE j.id = claimable.id
    RETURNING j.*
  )
  SELECT * FROM updated ORDER BY created_at, id;
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
  next_attempt int;
  actual_selection_status text := COALESCE(record_model_attempt.selection_status, 'accepted');
BEGIN
  SELECT j.id, j.task_name, j.subject_id, j.started_at, j.created_at
  INTO job_row.id, job_row.task_name, job_row.subject_id, job_row.started_at, job_row.created_at
  FROM otlet.jobs j
  WHERE j.id = record_model_attempt.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet job % does not exist', record_model_attempt.job_id;
  END IF;

  SELECT runtime_options
  INTO task_row.runtime_options
  FROM otlet.tasks
  WHERE name = job_row.task_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', job_row.task_name;
  END IF;
  SELECT name, artifact_path, artifact_hash
  INTO model_row.name, model_row.artifact_path, model_row.artifact_hash
  FROM otlet.models
  WHERE name = record_model_attempt.model_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet model % does not exist', record_model_attempt.model_name;
  END IF;

  IF jsonb_typeof(COALESCE(record_model_attempt.trace_summary, '{}'::jsonb)) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet record_model_attempt trace_summary must be a JSON object';
  END IF;
  IF record_model_attempt.output IS NOT NULL
     AND jsonb_typeof(record_model_attempt.output) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet record_model_attempt output must be a JSON object';
  END IF;
  IF COALESCE(record_model_attempt.selection_role, 'direct') NOT IN ('direct', 'cheap', 'strong') THEN
    RAISE EXCEPTION 'otlet record_model_attempt selection_role must be direct, cheap, or strong';
  END IF;
  IF COALESCE(record_model_attempt.selection_status, 'accepted') NOT IN ('accepted', 'rejected', 'failed') THEN
    RAISE EXCEPTION 'otlet record_model_attempt selection_status must be accepted, rejected, or failed';
  END IF;
  IF record_model_attempt.receipt_status IS NOT NULL
     AND record_model_attempt.receipt_status NOT IN ('complete', 'rejected', 'failed', 'canceled') THEN
    RAISE EXCEPTION 'otlet record_model_attempt receipt_status must be complete, rejected, failed, or canceled';
  END IF;
  IF record_model_attempt.schema_validation_status IS NOT NULL
     AND record_model_attempt.schema_validation_status NOT IN ('passed', 'failed', 'not_run') THEN
    RAISE EXCEPTION 'otlet record_model_attempt schema_validation_status must be passed, failed, or not_run';
  END IF;

  -- Prefer index-ordered peek over max() aggregate on (job_id, attempt_index).
  SELECT COALESCE((
    SELECT r.attempt_index
    FROM otlet.inference_receipts r
    WHERE r.job_id = job_row.id
    ORDER BY r.attempt_index DESC, r.id DESC
    LIMIT 1
  ), 0) + 1
  INTO next_attempt;

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
    'linked_inproc',
    'linked',
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

CREATE FUNCTION otlet.current_task_subject_content_hash(
  task_name text,
  subject_id text
) RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  task_row otlet.tasks%ROWTYPE;
  index_row otlet.semantic_indexes%ROWTYPE;
  current_input jsonb;
BEGIN
  SELECT t.name, t.input_shaping, t.input_query
  INTO task_row.name, task_row.input_shaping, task_row.input_query
  FROM otlet.tasks t
  WHERE t.name = current_task_subject_content_hash.task_name;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT si.subject_column, si.source_table, si.input_columns
  INTO index_row.subject_column, index_row.source_table, index_row.input_columns
  FROM otlet.semantic_indexes si
  WHERE si.task_name = task_row.name;

  IF FOUND THEN
    EXECUTE format(
      $sql$
        SELECT jsonb_build_object(
          '_otlet_mvcc', jsonb_build_object(
            'table', %2$L,
            'subject_id', (src.%1$I)::text,
            'ctid', src.ctid::text,
            'xmin', src.xmin::text
          ),
          'table', %2$L,
          'row', otlet.semantic_project_row(to_jsonb(src), %4$L::text[])
        )
        FROM %3$s AS src
        WHERE (src.%1$I)::text = $1
        LIMIT 1
      $sql$,
      index_row.subject_column,
      index_row.source_table,
      index_row.source_table,
      index_row.input_columns
    )
    INTO current_input
    USING current_task_subject_content_hash.subject_id;

    IF current_input IS NULL THEN
      RETURN NULL;
    END IF;

    RETURN otlet.semantic_content_hash(current_input, task_row.input_shaping);
  END IF;

  IF NULLIF(task_row.input_query, '') IS NULL THEN
    RETURN NULL;
  END IF;

  EXECUTE format(
    'SELECT q.input FROM (%s) AS q WHERE q.subject_id = $1 LIMIT 1',
    task_row.input_query
  )
  INTO current_input
  USING current_task_subject_content_hash.subject_id;

  IF current_input IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN otlet.semantic_content_hash(current_input, task_row.input_shaping);
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
  saved_receipt_id bigint;
  finish_started timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO saved_job
  FROM otlet.jobs
  WHERE id = fail_job.job_id
    AND status IN ('running', 'cancel_requested')
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT t.model_name
  INTO task_row.model_name
  FROM otlet.tasks t
  WHERE t.name = saved_job.task_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', saved_job.task_name;
  END IF;
  SELECT m.name
  INTO model_row.name
  FROM otlet.models m
  WHERE m.name = COALESCE(fail_job.model_name, task_row.model_name);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet model % does not exist',
      COALESCE(fail_job.model_name, task_row.model_name);
  END IF;

  IF jsonb_typeof(COALESCE(fail_job.trace_summary, '{}'::jsonb)) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet fail_job trace_summary must be a JSON object';
  END IF;
  IF COALESCE(fail_job.selection_role, 'direct') NOT IN ('direct', 'cheap', 'strong') THEN
    RAISE EXCEPTION 'otlet fail_job selection_role must be direct, cheap, or strong';
  END IF;
  IF COALESCE(fail_job.selection_status, 'failed') NOT IN ('accepted', 'rejected', 'failed') THEN
    RAISE EXCEPTION 'otlet fail_job selection_status must be accepted, rejected, or failed';
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

  SELECT id
  INTO saved_receipt_id
  FROM otlet.record_model_attempt(
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

  IF saved_receipt_id IS NOT NULL THEN
    UPDATE otlet.inference_receipts r
    SET trace_summary = r.trace_summary || jsonb_build_object(
      'finish_sql_ms',
      GREATEST(
        0,
        CEIL(EXTRACT(epoch FROM (clock_timestamp() - finish_started)) * 1000)
      )::bigint
    )
    WHERE r.id = saved_receipt_id;
  END IF;

  IF fail_job.schema_validation_status = 'failed'
     OR COALESCE(fail_job.selection_status, 'failed') = 'rejected' THEN
    PERFORM otlet.touch_runtime_slot(model_row.name, 'ready', 0, NULL);
  ELSE
    PERFORM otlet.touch_runtime_slot(model_row.name, 'error', 0, fail_job.error);
  END IF;
  PERFORM otlet.record_worker_event(
    'job_failed',
    saved_job.id,
    'linked_inproc',
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
  swept bigint := 0;
  canceled_swept bigint := 0;
BEGIN
  FOR job_row IN
    SELECT j.id, j.task_name, j.raw_output, j.started_at, j.created_at, j.error
    FROM otlet.jobs j
    CROSS JOIN otlet.production_policy p
    WHERE p.name = 'default'
      AND j.status = 'running'
      AND (j.leased_until IS NULL OR j.leased_until < now())
      AND j.attempts >= p.max_attempts
    ORDER BY j.id
    FOR UPDATE OF j
  LOOP
    SELECT t.model_name
    INTO task_row.model_name
    FROM otlet.tasks t
    WHERE t.name = job_row.task_name;
    IF NOT FOUND THEN
      -- Unclaimable orphan: terminalize without receipt/slot noise.
      UPDATE otlet.jobs
      SET status = 'failed',
          leased_until = NULL,
          error = 'orphan job: missing task',
          finished_at = now()
      WHERE id = job_row.id;
      swept := swept + 1;
      CONTINUE;
    END IF;
    SELECT m.name
    INTO model_row.name
    FROM otlet.models m
    WHERE m.name = task_row.model_name;
    IF NOT FOUND THEN
      UPDATE otlet.jobs
      SET status = 'failed',
          leased_until = NULL,
          error = 'orphan job: missing model',
          finished_at = now()
      WHERE id = job_row.id;
      swept := swept + 1;
      CONTINUE;
    END IF;

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

    PERFORM otlet.touch_runtime_slot(model_row.name, 'error', 0, job_row.error);
    swept := swept + 1;
  END LOOP;

  -- Symmetric terminalization for cancel_requested rows that exhausted attempts
  -- and lost their lease (prevents infinite reclaim under nested SPI failure).
  FOR job_row IN
    SELECT j.id, j.task_name, j.error
    FROM otlet.jobs j
    CROSS JOIN otlet.production_policy p
    WHERE p.name = 'default'
      AND j.status = 'cancel_requested'
      AND (j.leased_until IS NULL OR j.leased_until < now())
      AND j.attempts >= p.max_attempts
    ORDER BY j.id
    FOR UPDATE OF j
  LOOP
    -- finish_canceled_job fail-closes on missing task/model; terminalize orphans
    -- without a receipt so one corrupt row cannot abort the whole sweep.
    SELECT t.model_name
    INTO task_row.model_name
    FROM otlet.tasks t
    WHERE t.name = job_row.task_name;
    IF NOT FOUND THEN
      UPDATE otlet.jobs
      SET status = 'canceled',
          leased_until = NULL,
          error = COALESCE(job_row.error, 'orphan job: missing task'),
          finished_at = now()
      WHERE id = job_row.id;
      canceled_swept := canceled_swept + 1;
      CONTINUE;
    END IF;
    SELECT m.name
    INTO model_row.name
    FROM otlet.models m
    WHERE m.name = task_row.model_name;
    IF NOT FOUND THEN
      UPDATE otlet.jobs
      SET status = 'canceled',
          leased_until = NULL,
          error = COALESCE(job_row.error, 'orphan job: missing model'),
          finished_at = now()
      WHERE id = job_row.id;
      canceled_swept := canceled_swept + 1;
      CONTINUE;
    END IF;

    PERFORM otlet.finish_canceled_job(
      job_row.id,
      release_runtime => true
    );
    canceled_swept := canceled_swept + 1;
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

  IF canceled_swept > 0 THEN
    PERFORM otlet.record_worker_event(
      'expired_cancel_requested_sweep',
      NULL,
      NULL,
      'otlet expired cancel_requested jobs finished after max attempts',
      jsonb_build_object('canceled_jobs', canceled_swept)
    );
  END IF;

  RETURN swept + canceled_swept;
END;
$$;
