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
  selection_reason text DEFAULT NULL,
  expected_claim_attempt integer DEFAULT NULL
) RETURNS SETOF otlet.outputs
LANGUAGE plpgsql
AS $$
DECLARE
  saved_output otlet.outputs%ROWTYPE;
  saved_receipt otlet.inference_receipts%ROWTYPE;
  job_row otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  policy otlet.production_policy%ROWTYPE;
  action jsonb;
  action_payload jsonb;
  action_validation_payload jsonb;
  action_body jsonb;
  stored_action_payload jsonb;
  stored_action_body jsonb;
  action_redacted_fields text[] := ARRAY[]::text[];
  protected_fields text[] := ARRAY[
    'id', 'subject_id', 'entity_id', 'left_id', 'right_id', 'type', 'body',
    'match', 'confidence', 'action_type', 'record_type', 'target', 'identity', 'changes'
  ];
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
  action_idempotency_key text;
  workflow_policy otlet.action_workflow_policies%ROWTYPE;
  authority_mode text;
  authority_evaluation_status text;
  authority_policy_hash text;
  authority_subject_namespace text;
  authority_target_name text;
  proposed_target_name text;
  finish_started timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = complete_job.job_id
    AND status IN ('running', 'cancel_requested')
    AND (
      complete_job.expected_claim_attempt IS NULL
      OR (
        attempts = complete_job.expected_claim_attempt
        AND leased_until IS NOT NULL
        AND leased_until >= now()
      )
    )
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT t.model_name, t.input_shaping, t.decision_contract
  INTO task_row.model_name, task_row.input_shaping, task_row.decision_contract
  FROM otlet.tasks t
  WHERE t.name = job_row.task_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', job_row.task_name;
  END IF;
  SELECT *
  INTO policy
  FROM otlet.production_policy
  WHERE name = 'default';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet default production policy does not exist';
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
  IF octet_length(COALESCE(complete_job.raw_output, '')) > policy.max_raw_output_bytes THEN
    RAISE EXCEPTION 'otlet raw output exceeds evidence byte limit';
  END IF;
  IF octet_length(COALESCE(complete_job.output, 'null'::jsonb)::text) > policy.max_structured_output_bytes THEN
    RAISE EXCEPTION 'otlet structured output exceeds evidence byte limit';
  END IF;
  IF octet_length(COALESCE(complete_job.trace_summary, '{}'::jsonb)::text) > policy.max_trace_bytes THEN
    RAISE EXCEPTION 'otlet trace exceeds evidence byte limit';
  END IF;
  IF jsonb_array_length(COALESCE(complete_job.actions, '[]'::jsonb)) > policy.max_actions_per_job THEN
    RAISE EXCEPTION 'otlet actions exceed per-job evidence count limit';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(complete_job.actions, '[]'::jsonb)) action(value)
    WHERE octet_length(action.value::text) > policy.max_action_bytes
  ) THEN
    RAISE EXCEPTION 'otlet action exceeds evidence byte limit';
  END IF;

  SELECT COALESCE(array_agg(field_name ORDER BY field_name), ARRAY[]::text[])
  INTO action_redacted_fields
  FROM jsonb_array_elements_text(
    COALESCE(task_row.decision_contract -> 'redact_action_fields', '[]'::jsonb)
  ) fields(field_name);
  SELECT protected_fields || COALESCE(array_agg(field_name ORDER BY field_name), ARRAY[]::text[])
  INTO protected_fields
  FROM jsonb_array_elements_text(
    COALESCE(task_row.decision_contract -> 'identity_fields', '[]'::jsonb)
  ) fields(field_name);

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
      model_row.name,
      complete_job.expected_claim_attempt
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
    authority_mode := 'recommendation_only';
    authority_evaluation_status := 'unevaluated';
    authority_policy_hash := otlet.default_action_authority_hash(job_row.task_name, action_type_name);
    authority_subject_namespace := 'task:' || job_row.task_name;
    authority_target_name := NULL;
    SELECT * INTO workflow_policy
    FROM otlet.action_workflow_policies p
    WHERE p.task_name = job_row.task_name
      AND p.action_type = action_type_name
      AND p.enabled;
    IF FOUND THEN
      authority_mode := workflow_policy.authority_mode;
      authority_evaluation_status := workflow_policy.evaluation_status;
      authority_policy_hash := workflow_policy.policy_hash;
      authority_subject_namespace := workflow_policy.subject_namespace;
      authority_target_name := workflow_policy.target_name;
    END IF;

    action_error := CASE
      WHEN NOT COALESCE(task_row.decision_contract -> 'action_types', '[]'::jsonb) ? action_type_name
        THEN 'action type ' || action_type_name || ' is not allowed by workflow'
      ELSE NULL
    END;
    action_validation_payload := action_payload;
    IF action_type_name = 'update_row' THEN
      proposed_target_name := NULLIF(action_body ->> 'target', '');
      IF authority_target_name IS NULL THEN
        action_error := COALESCE(action_error, 'update_row requires registered workflow authority');
      ELSE
        IF proposed_target_name IS NOT NULL
           AND proposed_target_name IS DISTINCT FROM authority_target_name THEN
          action_error := COALESCE(action_error, 'update_row target does not match workflow authority');
        END IF;
        action_validation_payload := jsonb_set(
          action_validation_payload,
          '{body,target}',
          to_jsonb(authority_target_name),
          true
        );
        action_payload := action_validation_payload;
        action_body := action_payload -> 'body';
      END IF;
    END IF;
    IF action_error IS NULL THEN
      action_error := otlet.action_validation_error(
        action_validation_payload,
        complete_job.output,
        job_row.subject_id,
        job_row.input
      );
    END IF;
    action_requires_approval := false;
    action_creates_record := false;
    action_idempotency_key := NULL;
    IF action_error IS NULL THEN
      SELECT
        COALESCE(s.requires_approval, false),
        COALESCE(s.creates_record, false)
      INTO action_requires_approval, action_creates_record
      FROM (SELECT 1) seed
      LEFT JOIN otlet.action_type_schemas s ON s.action_type = action_type_name;
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
    IF action_error IS NULL AND action_type_name = 'update_row' THEN
      action_idempotency_key := otlet.update_row_idempotency_key(
        action_body,
        otlet.semantic_content_hash(job_row.input, task_row.input_shaping)
      );
    END IF;
    stored_action_payload := otlet.redact_jsonb_fields(
      action_payload,
      action_redacted_fields,
      protected_fields
    );
    stored_action_body := CASE
      WHEN jsonb_typeof(stored_action_payload -> 'body') = 'object'
        THEN stored_action_payload -> 'body'
      ELSE '{}'::jsonb
    END;

    INSERT INTO otlet.actions (
      job_id,
      output_id,
      receipt_id,
      action_type,
      authority_origin,
      authority_mode,
      evaluation_status,
      authority_policy_hash,
      subject_namespace,
      target_name,
      payload,
      status,
      approval_status,
      subject_id,
      source_table,
      source_hash,
      content_hash,
      idempotency_key,
      error
    )
    VALUES (
      complete_job.job_id,
      saved_output.id,
      saved_receipt.id,
      action_type_name,
      'workflow',
      authority_mode,
      authority_evaluation_status,
      authority_policy_hash,
      authority_subject_namespace,
      authority_target_name,
      stored_action_payload,
      action_status,
      action_approval_status,
      action_subject_id,
      complete_job.trace_summary #>> '{mvcc,table}',
      COALESCE(
        complete_job.trace_summary #>> '{mvcc,source_hash}',
        md5((complete_job.trace_summary -> 'mvcc')::text)
      ),
      otlet.semantic_content_hash(job_row.input, task_row.input_shaping),
      action_idempotency_key,
      action_error
    )
    RETURNING id INTO saved_action_id;

    IF action_creates_record THEN
      action_record_type := CASE
        WHEN action_type_name = 'note' THEN COALESCE(NULLIF(action_payload ->> 'record_type', ''), 'note')
        ELSE action_payload ->> 'record_type'
      END;
      action_record_body := stored_action_body;

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
  SET trace_summary = r.trace_summary
    || jsonb_build_object(
      'finish_sql_ms',
      GREATEST(
        0,
        CEIL(EXTRACT(epoch FROM (clock_timestamp() - finish_started)) * 1000)
      )::bigint
    )
    || jsonb_build_object(
      'evidence_redaction',
      COALESCE(r.trace_summary -> 'evidence_redaction', '{}'::jsonb)
      || jsonb_build_object(
        'actions', cardinality(action_redacted_fields) > 0,
        'action_field_count', cardinality(action_redacted_fields)
      )
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
  task_name text,
  output_body jsonb,
  current_content_hash text,
  validation_error text,
  authority_error text
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    a,
    s,
    j,
    j.task_name,
    o.output,
    otlet.current_task_subject_content_hash(j.task_name, j.subject_id),
    otlet.action_validation_error(a.payload, o.output, j.subject_id, j.input),
    CASE
      WHEN a.authority_origin = 'workflow' AND a.action_type = 'update_row' THEN
        otlet.action_workflow_policy_error(
          j.task_name,
          a.action_type,
          a.authority_policy_hash,
          a.target_name,
          a.subject_namespace,
          false
        )
      ELSE NULL
    END
  FROM otlet.actions a
  JOIN otlet.jobs j ON j.id = a.job_id
  LEFT JOIN otlet.action_type_schemas s ON s.action_type = a.action_type
  LEFT JOIN otlet.outputs o ON o.id = a.output_id
  WHERE a.id = validated_action_context.action_id
  FOR UPDATE OF a;
END;
$$;
