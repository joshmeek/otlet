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
  selection_reason text DEFAULT NULL,
  candidate_output jsonb DEFAULT NULL,
  expected_claim_token text DEFAULT NULL
) RETURNS SETOF otlet.jobs
LANGUAGE plpgsql
AS $$
DECLARE
  saved_job otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  saved_receipt_id bigint;
  finish_started timestamptz := clock_timestamp();
  request_hash text;
BEGIN
  request_hash := otlet.job_terminal_request_hash(
    'fail',
    jsonb_build_array(
      fail_job.error,
      fail_job.raw_output,
      fail_job.prompt_hash,
      fail_job.input_hash,
      fail_job.output_schema_hash,
      fail_job.raw_output_hash,
      fail_job.started_at,
      fail_job.schema_validation_status,
      fail_job.trace_summary,
      fail_job.model_name,
      fail_job.selection_role,
      fail_job.selection_status,
      fail_job.selection_reason,
      fail_job.candidate_output
    )
  );

  SELECT * INTO saved_job
  FROM otlet.jobs
  WHERE id = fail_job.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF saved_job.status IN ('complete', 'failed', 'canceled') THEN
    IF fail_job.expected_claim_token IS NULL
       OR saved_job.terminal_claim_token IS DISTINCT FROM fail_job.expected_claim_token THEN
      RAISE EXCEPTION 'otlet job claim is stale';
    END IF;
    IF saved_job.terminal_request_hash IS DISTINCT FROM request_hash THEN
      RAISE EXCEPTION 'otlet conflicting terminal retry';
    END IF;
    RETURN NEXT saved_job;
    RETURN;
  END IF;

  IF fail_job.expected_claim_token IS NULL
     OR saved_job.claim_token IS DISTINCT FROM fail_job.expected_claim_token
     OR saved_job.status NOT IN ('running', 'cancel_requested')
     OR saved_job.leased_until IS NULL
     OR saved_job.leased_until < now() THEN
    RAISE EXCEPTION 'otlet job claim is stale';
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
        model_row.name,
        fail_job.expected_claim_token,
        request_hash
      );
    RETURN;
  END IF;

  SELECT id
  INTO saved_receipt_id
  FROM otlet.record_model_attempt(
    saved_job.id,
    model_row.name,
    output => fail_job.candidate_output,
    raw_output => fail_job.raw_output,
    prompt_hash => fail_job.prompt_hash,
    input_hash => fail_job.input_hash,
    output_schema_hash => fail_job.output_schema_hash,
    raw_output_hash => COALESCE(
      fail_job.raw_output_hash,
      otlet.portable_text_hash(COALESCE(fail_job.raw_output, ''))
    ),
    started_at => fail_job.started_at,
    trace_summary => COALESCE(fail_job.trace_summary, '{}'::jsonb),
    schema_validation_status => fail_job.schema_validation_status,
    selection_role => COALESCE(fail_job.selection_role, 'direct'),
    selection_status => COALESCE(fail_job.selection_status, 'failed'),
    selection_reason => fail_job.selection_reason,
    error => fail_job.error,
    expected_claim_token => fail_job.expected_claim_token
  );

  UPDATE otlet.jobs
  SET status = 'failed',
      leased_until = NULL,
      claim_token = NULL,
      terminal_claim_token = fail_job.expected_claim_token,
      terminal_request_hash = request_hash,
      error = fail_job.error,
      finished_at = now()
  WHERE id = fail_job.job_id
  RETURNING * INTO saved_job;

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
    SELECT j.id, j.task_name, j.started_at, j.created_at, j.error
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
          claim_token = NULL,
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
          claim_token = NULL,
          error = 'orphan job: missing model',
          finished_at = now()
      WHERE id = job_row.id;
      swept := swept + 1;
      CONTINUE;
    END IF;

    UPDATE otlet.jobs
    SET leased_until = now() + interval '1 minute',
        claim_token = gen_random_uuid()::text
    WHERE id = job_row.id
    RETURNING * INTO job_row;

    PERFORM otlet.fail_job(
      job_row.id,
      'job lease expired after max attempts',
      raw_output_hash => otlet.portable_text_hash(''),
      trace_summary => jsonb_build_object('schema_validation_status', 'not_run'),
      schema_validation_status => 'not_run',
      started_at => COALESCE(job_row.started_at, job_row.created_at, now()),
      model_name => model_row.name,
      selection_status => 'failed',
      selection_reason => 'job_lease_expired_after_max_attempts',
      expected_claim_token => job_row.claim_token
    );

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
          claim_token = NULL,
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
          claim_token = NULL,
          error = COALESCE(job_row.error, 'orphan job: missing model'),
          finished_at = now()
      WHERE id = job_row.id;
      canceled_swept := canceled_swept + 1;
      CONTINUE;
    END IF;

    UPDATE otlet.jobs
    SET leased_until = now() + interval '1 minute',
        claim_token = gen_random_uuid()::text
    WHERE id = job_row.id
    RETURNING * INTO job_row;

    PERFORM otlet.finish_canceled_job(
      job_row.id,
      release_runtime => true,
      expected_claim_token => job_row.claim_token
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
