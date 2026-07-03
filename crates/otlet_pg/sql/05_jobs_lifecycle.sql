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
  eligible_tasks AS (
    SELECT
      j.task_name,
      m.name AS model_name,
      m.runtime_name,
      m.artifact_path,
      bool_or(s.status = 'ready' AND s.artifact_path IS NOT DISTINCT FROM m.artifact_path) AS warm_model,
      min(CASE WHEN j.status IN ('running', 'cancel_requested') AND (j.leased_until IS NULL OR j.leased_until < now()) THEN 0 ELSE 1 END) AS retry_rank,
      min(j.created_at) AS first_created_at,
      min(j.id) AS first_job_id
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
    GROUP BY
      j.task_name,
      m.name,
      m.runtime_name,
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

CREATE FUNCTION otlet.action_validation_error(
  action jsonb,
  output jsonb DEFAULT NULL,
  job_subject_id text DEFAULT NULL,
  job_input jsonb DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_action_type text := COALESCE(action ->> 'type', '');
  body jsonb := action -> 'body';
  output_match text := NULLIF(output ->> 'match', '');
  output_confidence text := NULLIF(output ->> 'confidence', '');
  action_confidence text;
  output_rank int;
  action_rank int;
  expected_left_id text;
  expected_right_id text;
BEGIN
  IF jsonb_typeof(action) IS DISTINCT FROM 'object' THEN
    RETURN 'action must be an object';
  END IF;

  IF v_action_type = '' THEN
    RETURN 'action missing type';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_object_keys(action) AS key
    WHERE key NOT IN ('type', 'body')
  ) THEN
    RETURN 'action has unsupported key';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.action_type_schemas s
    WHERE s.action_type = v_action_type
  ) THEN
    RETURN 'unsupported action type';
  END IF;

  IF jsonb_typeof(body) IS DISTINCT FROM 'object' THEN
    RETURN 'action body must be an object';
  END IF;

  expected_left_id := NULLIF(job_input #>> '{action_ids,left_id}', '');
  expected_right_id := NULLIF(job_input #>> '{action_ids,right_id}', '');

  IF expected_left_id IS NULL
     AND expected_right_id IS NULL
     AND job_subject_id LIKE '%:%'
     AND array_length(string_to_array(job_subject_id, ':'), 1) = 2 THEN
    expected_left_id := split_part(job_subject_id, ':', 1);
    expected_right_id := split_part(job_subject_id, ':', 2);
  END IF;

  IF output_confidence IS NOT NULL THEN
    output_rank := CASE output_confidence
      WHEN 'low' THEN 1
      WHEN 'medium' THEN 2
      WHEN 'high' THEN 3
      ELSE NULL
    END;
  END IF;

  IF v_action_type = 'create_record' THEN
    IF NULLIF(action ->> 'record_type', '') IS NULL THEN
      RETURN 'create_record missing record_type';
    END IF;
    RETURN NULL;
  END IF;

  IF v_action_type = 'merge_candidate' THEN
    IF output_match IS NOT NULL AND output_match <> 'same_entity' THEN
      RETURN 'merge_candidate requires same_entity output';
    END IF;
    IF NULLIF(body ->> 'left_id', '') IS NULL THEN
      RETURN 'merge_candidate missing left_id';
    END IF;
    IF NULLIF(body ->> 'right_id', '') IS NULL THEN
      RETURN 'merge_candidate missing right_id';
    END IF;
    IF expected_left_id IS NOT NULL
       AND (body ->> 'left_id' <> expected_left_id OR body ->> 'right_id' <> expected_right_id) THEN
      RETURN 'merge_candidate subject ids must match job subject_id';
    END IF;
    action_confidence := body ->> 'confidence';
    IF action_confidence NOT IN ('low', 'medium', 'high') THEN
      RETURN 'merge_candidate confidence must be low, medium, or high';
    END IF;
    action_rank := CASE action_confidence WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 END;
    IF output_rank IS NOT NULL AND action_rank > output_rank THEN
      RETURN 'merge_candidate confidence cannot exceed output confidence';
    END IF;
    IF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'merge_candidate missing reason';
    END IF;
    IF body ? 'evidence'
       AND COALESCE(jsonb_typeof(body -> 'evidence'), '') NOT IN ('array', 'string') THEN
      RETURN 'merge_candidate evidence must be an array or string';
    END IF;
    IF body ? 'evidence'
       AND ((jsonb_typeof(body -> 'evidence') = 'array' AND jsonb_array_length(body -> 'evidence') = 0)
       OR (jsonb_typeof(body -> 'evidence') = 'string' AND btrim(body ->> 'evidence') = '')) THEN
      RETURN 'merge_candidate missing decisive evidence';
    END IF;
    RETURN NULL;
  END IF;

  IF v_action_type = 'new_entity' THEN
    IF output_match IS NOT NULL AND output_match <> 'different_entity' THEN
      RETURN 'new_entity requires different_entity output';
    END IF;
    IF NULLIF(body ->> 'entity_id', '') IS NULL THEN
      RETURN 'new_entity missing entity_id';
    END IF;
    IF expected_right_id IS NOT NULL AND body ->> 'entity_id' <> expected_right_id THEN
      RETURN 'new_entity entity_id must match job right subject_id';
    END IF;
    IF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'new_entity missing reason';
    END IF;
    IF body ? 'evidence'
       AND COALESCE(jsonb_typeof(body -> 'evidence'), '') NOT IN ('array', 'string') THEN
      RETURN 'new_entity evidence must be an array or string';
    END IF;
    IF body ? 'evidence'
       AND ((jsonb_typeof(body -> 'evidence') = 'array' AND jsonb_array_length(body -> 'evidence') = 0)
       OR (jsonb_typeof(body -> 'evidence') = 'string' AND btrim(body ->> 'evidence') = '')) THEN
      RETURN 'new_entity missing separation evidence';
    END IF;
    RETURN NULL;
  END IF;

  IF v_action_type = 'review_flag' THEN
    IF output_match IS NOT NULL AND output_match <> 'unclear' THEN
      RETURN 'review_flag requires unclear output';
    END IF;
    IF expected_left_id IS NOT NULL
       AND NULLIF(body ->> 'left_id', '') IS NOT NULL
       AND (body ->> 'left_id' <> expected_left_id OR body ->> 'right_id' <> expected_right_id) THEN
      RETURN 'review_flag subject ids must match job subject_id';
    END IF;
    IF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'review_flag missing reason';
    END IF;
    IF body ->> 'severity' NOT IN ('low', 'medium', 'high') THEN
      RETURN 'review_flag severity must be low, medium, or high';
    END IF;
    RETURN NULL;
  END IF;

  IF v_action_type = 'note' THEN
    IF NULLIF(body ->> 'subject_id', '') IS NULL THEN
      RETURN 'note missing subject_id';
    END IF;
    IF NULLIF(body ->> 'text', '') IS NULL THEN
      RETURN 'note missing text';
    END IF;
    RETURN NULL;
  END IF;

  RETURN 'unsupported action type';
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
  action_payload jsonb;
  action_body jsonb;
  saved_action_id bigint;
  action_error text;
  action_type_name text;
  action_status text;
  action_approval_status text;
  action_subject_id text;
  action_requires_approval boolean;
  action_creates_record boolean;
  action_record_type text;
  action_record_body jsonb;
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

  IF jsonb_typeof(COALESCE(complete_job.actions, '[]'::jsonb)) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'otlet complete_job actions must be an array';
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
    action_payload := CASE
      WHEN jsonb_typeof(action) = 'object' THEN action
      ELSE jsonb_build_object('invalid_action', action)
    END;
    action_body := CASE
      WHEN jsonb_typeof(action_payload -> 'body') = 'object' THEN action_payload -> 'body'
      ELSE '{}'::jsonb
    END;
    action_type_name := COALESCE(NULLIF(action ->> 'type', ''), 'invalid');
    action_error := otlet.action_validation_error(action, complete_job.output, job_row.subject_id, job_row.input);
    action_requires_approval := false;
    action_creates_record := false;
    IF action_error IS NULL THEN
      SELECT s.requires_approval, s.creates_record
      INTO action_requires_approval, action_creates_record
      FROM otlet.action_type_schemas s
      WHERE s.action_type = action_type_name;
    END IF;
    action_subject_id := COALESCE(
      NULLIF(action_payload ->> 'subject_id', ''),
      NULLIF(action_payload ->> 'entity_id', ''),
      NULLIF(action_payload ->> 'right_id', ''),
      NULLIF(action_body ->> 'subject_id', ''),
      NULLIF(action_body ->> 'entity_id', ''),
      NULLIF(action_body ->> 'right_id', ''),
      job_row.subject_id
    );
    action_status := CASE
      WHEN action_error IS NOT NULL THEN 'rejected'
      WHEN action_creates_record AND NOT action_requires_approval THEN 'complete'
      ELSE 'proposed'
    END;
    action_approval_status := CASE
      WHEN action_error IS NOT NULL THEN 'not_required'
      WHEN action_requires_approval THEN 'required'
      ELSE 'not_required'
    END;

    INSERT INTO otlet.actions (
      job_id,
      output_id,
      receipt_id,
      action_type,
      payload,
      status,
      approval_status,
      subject_id,
      source_table,
      source_hash,
      error
    )
    VALUES (
      complete_job.job_id,
      saved_output.id,
      saved_receipt.id,
      action_type_name,
      action_payload,
      action_status,
      action_approval_status,
      action_subject_id,
      complete_job.trace_summary #>> '{mvcc,table}',
      COALESCE(
        complete_job.trace_summary #>> '{mvcc,source_hash}',
        md5((complete_job.trace_summary -> 'mvcc')::text)
      ),
      action_error
    )
    RETURNING id INTO saved_action_id;

    IF action_creates_record THEN
      action_record_type := CASE
        WHEN action_type_name = 'note' THEN COALESCE(NULLIF(action_payload ->> 'record_type', ''), 'note')
        ELSE action_payload ->> 'record_type'
      END;
      action_record_body := action_body;

      INSERT INTO otlet.records (action_id, record_type, subject_id, body)
      VALUES (
        saved_action_id,
        action_record_type,
        action_subject_id,
        action_record_body
      );
    END IF;
  END LOOP;

  RETURN NEXT saved_output;
END;
$$;

CREATE FUNCTION otlet.approve_action(action_id bigint) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
AS $$
DECLARE
  action_row otlet.actions%ROWTYPE;
BEGIN
  UPDATE otlet.actions
  SET status = 'approved',
      approval_status = 'approved',
      approved_at = now(),
      error = NULL
  WHERE id = approve_action.action_id
    AND status = 'proposed'
    AND approval_status = 'required'
  RETURNING * INTO action_row;

  IF FOUND THEN
    RETURN NEXT action_row;
  END IF;
END;
$$;

CREATE FUNCTION otlet.reject_action(
  action_id bigint,
  reason text DEFAULT 'rejected'
) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
AS $$
DECLARE
  action_row otlet.actions%ROWTYPE;
BEGIN
  UPDATE otlet.actions
  SET status = 'rejected',
      approval_status = 'rejected',
      error = reject_action.reason
  WHERE id = reject_action.action_id
    AND status <> 'applied'
  RETURNING * INTO action_row;

  IF FOUND THEN
    RETURN NEXT action_row;
  END IF;
END;
$$;

CREATE FUNCTION otlet.dry_run_action(action_id bigint) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
AS $$
DECLARE
  action_row otlet.actions%ROWTYPE;
  validation_error text;
BEGIN
  SELECT *
  INTO action_row
  FROM otlet.actions
  WHERE id = dry_run_action.action_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  validation_error := otlet.action_validation_error(action_row.payload);
  IF action_row.status = 'rejected' THEN
    validation_error := COALESCE(action_row.error, validation_error, 'rejected action cannot be dry-run');
  END IF;

  UPDATE otlet.actions
  SET dry_run_status = CASE WHEN validation_error IS NULL THEN 'passed' ELSE 'failed' END,
      error = COALESCE(validation_error, error)
  WHERE id = action_row.id
  RETURNING * INTO action_row;

  RETURN NEXT action_row;
END;
$$;

CREATE FUNCTION otlet.apply_action(action_id bigint) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
AS $$
DECLARE
  action_row otlet.actions%ROWTYPE;
  validation_error text;
  next_status text;
  next_apply_status text;
  next_error text;
  next_applied_at timestamptz;
BEGIN
  SELECT *
  INTO action_row
  FROM otlet.actions
  WHERE id = apply_action.action_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  validation_error := otlet.action_validation_error(action_row.payload);
  next_status := action_row.status;
  next_apply_status := action_row.apply_status;
  next_error := action_row.error;
  next_applied_at := action_row.applied_at;

  IF validation_error IS NOT NULL THEN
    next_apply_status := 'failed';
    next_error := validation_error;
  ELSIF action_row.status = 'rejected' THEN
    next_apply_status := 'failed';
    next_error := COALESCE(action_row.error, 'rejected action cannot be applied');
  ELSIF action_row.approval_status = 'required' THEN
    next_apply_status := 'failed';
    next_error := 'action requires approval';
  ELSIF action_row.action_type IN ('create_record', 'note') THEN
    next_status := 'applied';
    next_apply_status := 'applied';
    next_applied_at := now();
    next_error := NULL;
  ELSE
    next_apply_status := 'not_applicable';
    next_error := 'action type has no apply path';
  END IF;

  UPDATE otlet.actions
  SET status = next_status,
      apply_status = next_apply_status,
      applied_at = next_applied_at,
      error = next_error
  WHERE id = action_row.id
  RETURNING * INTO action_row;

  RETURN NEXT action_row;
END;
$$;

CREATE FUNCTION otlet.label_action(
  action_id bigint,
  expected_match text DEFAULT NULL,
  expected_confidence text DEFAULT NULL,
  expected_action_type text DEFAULT NULL,
  reason text DEFAULT NULL,
  label_source text DEFAULT NULL
) RETURNS SETOF otlet.eval_labels
LANGUAGE plpgsql
AS $$
DECLARE
  action_row otlet.actions%ROWTYPE;
  output_body jsonb;
  receipt_trace jsonb;
  saved_label otlet.eval_labels%ROWTYPE;
  final_source text;
  final_match text;
  final_confidence text;
  final_action_type text;
BEGIN
  SELECT a.*
  INTO action_row
  FROM otlet.actions a
  WHERE a.id = label_action.action_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT o.output
  INTO output_body
  FROM otlet.outputs o
  WHERE o.id = action_row.output_id;

  SELECT r.trace_summary
  INTO receipt_trace
  FROM otlet.inference_receipts r
  WHERE r.id = action_row.receipt_id;

  final_source := COALESCE(
    NULLIF(label_action.label_source, ''),
    CASE
      WHEN action_row.status IN ('approved', 'applied') OR action_row.approval_status = 'approved' THEN 'approved_action'
      WHEN action_row.status = 'rejected' OR action_row.approval_status = 'rejected' THEN 'rejected_action'
      ELSE 'manual_correction'
    END
  );

  final_match := COALESCE(
    NULLIF(label_action.expected_match, ''),
    CASE
      WHEN action_row.action_type = 'merge_candidate' AND final_source = 'approved_action' THEN 'same_entity'
      WHEN action_row.action_type = 'merge_candidate' AND final_source = 'rejected_action' THEN 'different_entity'
      WHEN action_row.action_type = 'new_entity' AND final_source = 'approved_action' THEN 'different_entity'
      WHEN action_row.action_type = 'review_flag' AND final_source = 'approved_action' THEN 'unclear'
      ELSE output_body ->> 'match'
    END
  );
  final_confidence := COALESCE(
    NULLIF(label_action.expected_confidence, ''),
    output_body ->> 'confidence',
    CASE WHEN final_match = 'unclear' THEN 'medium' ELSE 'high' END
  );
  final_action_type := COALESCE(NULLIF(label_action.expected_action_type, ''), action_row.action_type);

  INSERT INTO otlet.eval_labels (
    action_id,
    output_id,
    receipt_id,
    source_table,
    subject_id,
    source_hash,
    expected_match,
    expected_confidence,
    expected_action_type,
    label_source,
    reason
  )
  VALUES (
    action_row.id,
    action_row.output_id,
    action_row.receipt_id,
    COALESCE(action_row.source_table, receipt_trace #>> '{mvcc,table}'),
    COALESCE(action_row.subject_id, ''),
    COALESCE(
      action_row.source_hash,
      receipt_trace #>> '{mvcc,source_hash}',
      md5((receipt_trace -> 'mvcc')::text)
    ),
    final_match,
    final_confidence,
    final_action_type,
    final_source,
    label_action.reason
  )
  RETURNING * INTO saved_label;

  RETURN NEXT saved_label;
END;
$$;

CREATE FUNCTION otlet.export_eval_cases(max_rows integer DEFAULT 1000)
RETURNS TABLE (
  label_id bigint,
  fixture_source text,
  case_kind text,
  manual_gold boolean,
  source_table text,
  subject_id text,
  source_hash text,
  expected_match text,
  expected_confidence text,
  expected_action_type text,
  label_source text,
  reason text,
  action_id bigint,
  output_id bigint,
  receipt_id bigint,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    l.id,
    'otlet_eval_labels_generated'::text,
    CASE
      WHEN a.action_type = 'merge_candidate'
        AND l.expected_match <> 'same_entity' THEN 'false_trusted'
      WHEN l.label_source = 'manual_correction' THEN 'gold'
      WHEN l.expected_action_type = 'merge_candidate'
        AND l.expected_match = 'same_entity' THEN 'positive'
      WHEN l.expected_action_type = 'new_entity'
        AND l.expected_match = 'different_entity' THEN 'hard_negative'
      WHEN l.expected_action_type = 'review_flag'
        OR l.expected_match = 'unclear' THEN 'abstention'
      ELSE 'gold'
    END,
    l.label_source = 'manual_correction',
    l.source_table,
    l.subject_id,
    l.source_hash,
    l.expected_match,
    l.expected_confidence,
    l.expected_action_type,
    l.label_source,
    l.reason,
    l.action_id,
    l.output_id,
    l.receipt_id,
    l.created_at
  FROM otlet.eval_labels l
  LEFT JOIN otlet.actions a ON a.id = l.action_id
  ORDER BY l.created_at DESC, l.id DESC
  LIMIT GREATEST(0, LEAST(COALESCE(max_rows, 1000), 100000));
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
