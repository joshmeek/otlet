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
  body jsonb;
  schema_row otlet.action_type_schemas%ROWTYPE;
  expected_left_id text;
  expected_right_id text;
  output_confidence text := NULLIF(output ->> 'confidence', '');
  output_rank int;
  action_rank int;
  unsupported_key text;
BEGIN
  IF jsonb_typeof(action) IS DISTINCT FROM 'object' THEN
    RETURN 'action must be an object';
  END IF;

  IF v_action_type = '' THEN
    RETURN 'action missing type';
  END IF;

  SELECT *
  INTO schema_row
  FROM otlet.action_type_schemas s
  WHERE s.action_type = v_action_type;

  IF NOT FOUND THEN
    RETURN 'unsupported action type';
  END IF;

  body := CASE
    WHEN v_action_type = 'create_record' THEN action - 'type'
    ELSE action -> 'body'
  END;

  IF v_action_type <> 'create_record' THEN
    SELECT key
    INTO unsupported_key
    FROM jsonb_object_keys(action) AS key
    WHERE key NOT IN ('type', 'body')
    ORDER BY key
    LIMIT 1;

    IF unsupported_key IS NOT NULL THEN
      RETURN 'action has unsupported key';
    END IF;
  END IF;

  IF jsonb_typeof(body) IS DISTINCT FROM 'object' THEN
    RETURN 'action body must be an object';
  END IF;

  expected_left_id := NULLIF(job_input #>> '{action_ids,left_id}', '');
  expected_right_id := NULLIF(job_input #>> '{action_ids,right_id}', '');

  output_rank := CASE output_confidence WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 ELSE NULL END;

  IF v_action_type = 'create_record' THEN
    IF NULLIF(body ->> 'record_type', '') IS NULL THEN
      RETURN 'create_record missing record_type';
    ELSIF NULLIF(body ->> 'subject_id', '') IS NULL THEN
      RETURN 'create_record missing subject_id';
    ELSIF jsonb_typeof(body -> 'body') IS DISTINCT FROM 'object' THEN
      RETURN 'create_record missing body';
    END IF;
    SELECT key
    INTO unsupported_key
    FROM jsonb_object_keys(body) AS key
    WHERE key NOT IN ('record_type', 'subject_id', 'body')
    ORDER BY key
    LIMIT 1;
    IF unsupported_key IS NOT NULL THEN
      RETURN 'create_record unsupported payload field: ' || unsupported_key;
    END IF;
  ELSIF v_action_type = 'merge_candidate' THEN
    IF NULLIF(body ->> 'left_id', '') IS NULL THEN
      RETURN 'merge_candidate missing left_id';
    ELSIF NULLIF(body ->> 'right_id', '') IS NULL THEN
      RETURN 'merge_candidate missing right_id';
    ELSIF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'merge_candidate missing reason';
    ELSIF NULLIF(output ->> 'match', '') IS NOT NULL AND output ->> 'match' <> 'same_entity' THEN
      RETURN 'merge_candidate requires same_entity output';
    ELSIF expected_left_id IS NULL OR expected_right_id IS NULL THEN
      RETURN 'merge_candidate requires input.action_ids left_id and right_id';
    ELSIF body ->> 'left_id' <> expected_left_id OR body ->> 'right_id' <> expected_right_id THEN
      RETURN 'merge_candidate subject ids must match job subject_id';
    ELSIF body ? 'confidence' AND body ->> 'confidence' NOT IN ('low', 'medium', 'high') THEN
      RETURN 'merge_candidate confidence must be low, medium, or high';
    END IF;
    action_rank := CASE body ->> 'confidence' WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 ELSE NULL END;
    IF output_rank IS NOT NULL AND action_rank IS NOT NULL AND action_rank > output_rank THEN
      RETURN 'merge_candidate confidence cannot exceed output confidence';
    END IF;
    IF body ? 'evidence'
       AND NOT (
         (jsonb_typeof(body -> 'evidence') = 'array' AND jsonb_array_length(body -> 'evidence') > 0)
         OR (jsonb_typeof(body -> 'evidence') = 'string' AND btrim(body ->> 'evidence') <> '')
       ) THEN
      RETURN 'merge_candidate missing decisive evidence';
    END IF;
  ELSIF v_action_type = 'new_entity' THEN
    IF NULLIF(body ->> 'entity_id', '') IS NULL THEN
      RETURN 'new_entity missing entity_id';
    ELSIF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'new_entity missing reason';
    ELSIF NULLIF(output ->> 'match', '') IS NOT NULL AND output ->> 'match' <> 'different_entity' THEN
      RETURN 'new_entity requires different_entity output';
    ELSIF expected_right_id IS NULL THEN
      RETURN 'new_entity requires input.action_ids right_id';
    ELSIF body ->> 'entity_id' <> expected_right_id THEN
      RETURN 'new_entity entity_id must match job right subject_id';
    END IF;
    IF body ? 'evidence'
       AND NOT (
         (jsonb_typeof(body -> 'evidence') = 'array' AND jsonb_array_length(body -> 'evidence') > 0)
         OR (jsonb_typeof(body -> 'evidence') = 'string' AND btrim(body ->> 'evidence') <> '')
       ) THEN
      RETURN 'new_entity missing separation evidence';
    END IF;
  ELSIF v_action_type = 'review_flag' THEN
    IF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'review_flag missing reason';
    ELSIF body ? 'severity' AND body ->> 'severity' NOT IN ('low', 'medium', 'high') THEN
      RETURN 'review_flag severity must be low, medium, or high';
    ELSIF NULLIF(output ->> 'match', '') IS NOT NULL AND output ->> 'match' <> 'unclear' THEN
      RETURN 'review_flag requires unclear output';
    ELSIF expected_left_id IS NOT NULL
       AND NULLIF(body ->> 'left_id', '') IS NOT NULL
       AND (body ->> 'left_id' <> expected_left_id OR body ->> 'right_id' <> expected_right_id) THEN
      RETURN 'review_flag subject ids must match job subject_id';
    END IF;
  ELSIF v_action_type = 'note' THEN
    IF NULLIF(body ->> 'subject_id', '') IS NULL THEN
      RETURN 'note missing subject_id';
    ELSIF NULLIF(body ->> 'text', '') IS NULL THEN
      RETURN 'note missing text';
    END IF;
  END IF;

  RETURN NULL;
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
  action jsonb;
  action_payload jsonb;
  action_body jsonb;
  saved_action_id bigint;
  action_error text;
  action_type_name text;
  action_status text;
  action_approval_status text;
  action_rejected_by_watch boolean;
  action_subject_id text;
  action_requires_approval boolean;
  action_creates_record boolean;
  action_record_type text;
  action_record_body jsonb;
  has_action_type_restriction boolean := false;
  finish_started timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = complete_job.job_id
    AND status IN ('running', 'cancel_requested')
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT t.model_name, t.input_shaping
  INTO task_row.model_name, task_row.input_shaping
  FROM otlet.tasks t
  WHERE t.name = job_row.task_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', job_row.task_name;
  END IF;
  SELECT m.name
  INTO model_row.name
  FROM otlet.models m
  WHERE m.name = COALESCE(complete_job.model_name, task_row.model_name);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet model % does not exist',
      COALESCE(complete_job.model_name, task_row.model_name);
  END IF;

  -- Fail before mutating job/receipt state on a bad envelope.
  IF jsonb_typeof(COALESCE(complete_job.actions, '[]'::jsonb)) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'otlet complete_job actions must be an array';
  END IF;
  IF jsonb_typeof(COALESCE(complete_job.trace_summary, '{}'::jsonb)) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet complete_job trace_summary must be a JSON object';
  END IF;
  IF COALESCE(complete_job.selection_role, 'direct') NOT IN ('direct', 'cheap', 'strong') THEN
    RAISE EXCEPTION 'otlet complete_job selection_role must be direct, cheap, or strong';
  END IF;
  IF COALESCE(complete_job.selection_status, 'accepted') NOT IN ('accepted', 'rejected', 'failed') THEN
    RAISE EXCEPTION 'otlet complete_job selection_status must be accepted, rejected, or failed';
  END IF;
  IF COALESCE(complete_job.selection_status, 'accepted') <> 'accepted' THEN
    RAISE EXCEPTION 'otlet complete_job requires selection_status accepted';
  END IF;
  IF COALESCE(complete_job.trace_summary ->> 'schema_validation_status', 'not_run')
     IS DISTINCT FROM 'passed' THEN
    RAISE EXCEPTION 'otlet complete_job requires schema_validation_status passed';
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
      true,
      model_row.name
    );
    RETURN;
  END IF;

  UPDATE otlet.jobs
  SET status = 'complete',
      leased_until = NULL,
      error = NULL,
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

  -- outputs_one_per_job_idx; qualify column vs complete_job.job_id param.
  SELECT *
  INTO saved_output
  FROM otlet.outputs o
  WHERE o.job_id = job_row.id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  PERFORM otlet.touch_runtime_slot(model_row.name, 'ready', 0, NULL);
  PERFORM otlet.record_worker_event(
    'job_completed',
    job_row.id,
    'linked_inproc',
    'otlet worker completed job',
    jsonb_build_object(
      'task_name', job_row.task_name,
      'subject_id', job_row.subject_id,
      'model_name', model_row.name,
      'selection_role', COALESCE(complete_job.selection_role, 'direct'),
      'selection_reason', complete_job.selection_reason
    )
  );

  -- One probe for the job's task: skip per-action watch scans when unrestricted.
  SELECT EXISTS (
    SELECT 1
    FROM otlet.watches w
    WHERE w.task_name = job_row.task_name
      AND cardinality(w.action_types) > 0
  )
  INTO has_action_type_restriction;

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
    action_rejected_by_watch := false;
    action_requires_approval := false;
    action_creates_record := false;
    IF action_error IS NULL THEN
      SELECT
        CASE
          WHEN has_action_type_restriction THEN EXISTS (
            SELECT 1
            FROM otlet.watches w
            WHERE w.task_name = job_row.task_name
              AND cardinality(w.action_types) > 0
              AND NOT action_type_name = ANY(w.action_types)
          )
          ELSE false
        END,
        COALESCE(s.requires_approval, false),
        COALESCE(s.creates_record, false)
      INTO action_rejected_by_watch, action_requires_approval, action_creates_record
      FROM (SELECT 1) seed
      LEFT JOIN otlet.action_type_schemas s ON s.action_type = action_type_name;

      IF action_rejected_by_watch THEN
        action_error := 'action type ' || action_type_name || ' is not allowed by watch';
        action_requires_approval := false;
        action_creates_record := false;
      END IF;
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
      content_hash,
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
      otlet.semantic_content_hash(job_row.input, task_row.input_shaping),
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

  UPDATE otlet.inference_receipts r
  SET trace_summary = r.trace_summary || jsonb_build_object(
    'finish_sql_ms',
    GREATEST(
      0,
      CEIL(EXTRACT(epoch FROM (clock_timestamp() - finish_started)) * 1000)
    )::bigint
  )
  WHERE r.id = saved_receipt.id;

  RETURN NEXT saved_output;
END;
$$;

CREATE FUNCTION otlet.approve_action(
  action_id bigint,
  review_reason text DEFAULT NULL
) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  action_row otlet.actions%ROWTYPE;
BEGIN
  UPDATE otlet.actions
  SET status = 'approved',
      approval_status = 'approved',
      approved_at = now(),
      error = NULL,
      review_reason = NULLIF(approve_action.review_reason, '')
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
  reason text DEFAULT 'rejected',
  review_reason text DEFAULT NULL
) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  action_row otlet.actions%ROWTYPE;
BEGIN
  UPDATE otlet.actions
  SET status = 'rejected',
      approval_status = 'rejected',
      error = reject_action.reason,
      review_reason = COALESCE(NULLIF(reject_action.review_reason, ''), NULLIF(reject_action.reason, ''))
  WHERE id = reject_action.action_id
    AND status <> 'applied'
  RETURNING * INTO action_row;

  IF FOUND THEN
    RETURN NEXT action_row;
  END IF;
END;
$$;

CREATE FUNCTION otlet.validated_action_context(action_id bigint)
RETURNS TABLE (
  action_row otlet.actions,
  schema_row otlet.action_type_schemas,
  job_row otlet.jobs,
  output_body jsonb,
  current_content_hash text,
  validation_error text
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    a,
    s,
    j,
    o.output,
    otlet.current_task_subject_content_hash(j.task_name, j.subject_id),
    otlet.action_validation_error(a.payload, o.output, j.subject_id, j.input)
  FROM otlet.actions a
  JOIN otlet.jobs j ON j.id = a.job_id
  LEFT JOIN otlet.action_type_schemas s ON s.action_type = a.action_type
  LEFT JOIN otlet.outputs o ON o.id = a.output_id
  WHERE a.id = validated_action_context.action_id
  FOR UPDATE OF a;
END;
$$;

CREATE FUNCTION otlet.dry_run_action(action_id bigint) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  context_row record;
  validation_error text;
  action_row otlet.actions%ROWTYPE;
BEGIN
  SELECT *
  INTO context_row
  FROM otlet.validated_action_context(dry_run_action.action_id);

  IF NOT FOUND THEN
    RETURN;
  END IF;

  action_row := context_row.action_row;
  validation_error := context_row.validation_error;
  IF action_row.content_hash IS NOT NULL
     AND context_row.current_content_hash IS DISTINCT FROM action_row.content_hash THEN
    validation_error := 'source identity stale';
  END IF;
  IF action_row.status = 'rejected' THEN
    validation_error := COALESCE(action_row.error, validation_error, 'rejected action cannot be dry-run');
  END IF;

  UPDATE otlet.actions
  SET dry_run_status = CASE WHEN validation_error IS NULL THEN 'passed' ELSE 'failed' END,
      error = validation_error
  WHERE id = action_row.id
  RETURNING * INTO action_row;

  RETURN NEXT action_row;
END;
$$;

CREATE FUNCTION otlet.apply_action(action_id bigint) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  context_row record;
  action_row otlet.actions%ROWTYPE;
  schema_row otlet.action_type_schemas%ROWTYPE;
  validation_error text;
  next_status text;
  next_apply_status text;
  next_error text;
  next_applied_at timestamptz;
BEGIN
  SELECT *
  INTO context_row
  FROM otlet.validated_action_context(apply_action.action_id);

  IF NOT FOUND THEN
    RETURN;
  END IF;

  action_row := context_row.action_row;
  schema_row := context_row.schema_row;
  validation_error := context_row.validation_error;
  next_status := action_row.status;
  next_apply_status := action_row.apply_status;
  next_error := action_row.error;
  next_applied_at := action_row.applied_at;

  IF action_row.content_hash IS NOT NULL
     AND context_row.current_content_hash IS DISTINCT FROM action_row.content_hash THEN
    validation_error := 'source identity stale';
  END IF;

  IF validation_error IS NOT NULL THEN
    next_apply_status := 'failed';
    next_error := validation_error;
  ELSIF action_row.status = 'rejected' THEN
    next_apply_status := 'failed';
    next_error := COALESCE(action_row.error, 'rejected action cannot be applied');
  ELSIF action_row.approval_status = 'required' THEN
    next_apply_status := 'failed';
    next_error := 'action requires approval';
  ELSIF schema_row.applyable THEN
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
