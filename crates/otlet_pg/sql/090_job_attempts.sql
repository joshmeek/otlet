CREATE FUNCTION otlet.redact_trace_summary(
  trace_summary jsonb,
  sensitive_evidence_mode text
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  result jsonb := COALESCE(redact_trace_summary.trace_summary, '{}'::jsonb);
  detail jsonb;
  redacted_steps jsonb;
BEGIN
  IF jsonb_typeof(result) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet trace summary must be a JSON object';
  END IF;
  IF redact_trace_summary.sensitive_evidence_mode NOT IN ('redacted', 'diagnostic') THEN
    RAISE EXCEPTION 'otlet sensitive evidence mode must be redacted or diagnostic';
  END IF;

  result := result - ARRAY[
    'prompt',
    'prompt_text',
    'input',
    'input_text',
    'source_row',
    'raw_output'
  ];

  detail := CASE
    WHEN jsonb_typeof(result -> 'detailed_trace') = 'object'
      THEN result -> 'detailed_trace'
    ELSE '{}'::jsonb
  END;

  IF redact_trace_summary.sensitive_evidence_mode = 'redacted' THEN
    SELECT COALESCE(jsonb_agg(
      CASE
        WHEN jsonb_typeof(step.value) = 'object' THEN
          (step.value - 'token_text') ||
          CASE
            WHEN jsonb_typeof(step.value -> 'top_alternatives') = 'array' THEN
              jsonb_build_object(
                'top_alternatives',
                (
                  SELECT COALESCE(jsonb_agg(
                    CASE
                      WHEN jsonb_typeof(alt.value) = 'object' THEN alt.value - 'token_text'
                      ELSE alt.value
                    END
                    ORDER BY alt.ordinality
                  ), '[]'::jsonb)
                  FROM jsonb_array_elements(step.value -> 'top_alternatives')
                    WITH ORDINALITY AS alt(value, ordinality)
                )
              )
            ELSE '{}'::jsonb
          END
        ELSE step.value
      END
      ORDER BY step.ordinality
    ), '[]'::jsonb)
    INTO redacted_steps
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(detail -> 'steps') = 'array' THEN detail -> 'steps'
        ELSE '[]'::jsonb
      END
    ) WITH ORDINALITY AS step(value, ordinality);

    detail := jsonb_set(detail - 'chosen_text', '{steps}', redacted_steps, true);
  END IF;

  detail := detail || jsonb_build_object(
    'text_storage', redact_trace_summary.sensitive_evidence_mode,
    'redaction_version', 1
  );

  RETURN jsonb_set(result, '{detailed_trace}', detail, true);
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
  receipt_status text DEFAULT NULL,
  expected_claim_token text DEFAULT NULL,
  actions jsonb DEFAULT NULL
) RETURNS otlet.inference_receipts
LANGUAGE plpgsql
AS $$
DECLARE
  saved_receipt otlet.inference_receipts%ROWTYPE;
  saved_output otlet.outputs%ROWTYPE;
  job_row otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  policy otlet.production_policy%ROWTYPE;
  next_attempt int;
  actual_selection_status text := COALESCE(record_model_attempt.selection_status, 'accepted');
  policy_mode text;
  output_redacted_fields text[] := ARRAY[]::text[];
  protected_fields text[] := ARRAY[
    'id', 'subject_id', 'entity_id', 'left_id', 'right_id', 'type', 'body',
    'match', 'confidence', 'action_type', 'record_type', 'target', 'identity', 'changes'
  ];
  stored_output jsonb;
  stored_trace_summary jsonb;
  expected_model_name text;
  portable_identity jsonb;
  schema_error text;
  authoritative_schema_status text;
  actual_raw_output_hash text;
  actual_output_schema_hash text;
  actual_runtime_options_hash text;
  actual_model_identity_hash text;
BEGIN
  SELECT j.*
  INTO job_row
  FROM otlet.jobs j
  WHERE j.id = record_model_attempt.job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet job % does not exist', record_model_attempt.job_id;
  END IF;

  IF record_model_attempt.expected_claim_token IS NULL
     OR job_row.claim_token IS DISTINCT FROM record_model_attempt.expected_claim_token
     OR job_row.status NOT IN ('running', 'cancel_requested')
     OR job_row.leased_until IS NULL
     OR job_row.leased_until < now() THEN
    RAISE EXCEPTION 'otlet job claim is stale';
  END IF;

  SELECT t.model_name, t.runtime_options, t.decision_contract, t.output_schema
  INTO task_row.model_name, task_row.runtime_options, task_row.decision_contract, task_row.output_schema
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
  policy_mode := policy.sensitive_evidence_mode;
  SELECT name, artifact_path, artifact_hash, artifact_identity
  INTO model_row.name, model_row.artifact_path, model_row.artifact_hash, model_row.artifact_identity
  FROM otlet.models
  WHERE name = record_model_attempt.model_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet model % does not exist', record_model_attempt.model_name;
  END IF;

  IF jsonb_typeof(COALESCE(record_model_attempt.trace_summary, '{}'::jsonb)) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet record_model_attempt trace_summary must be a JSON object';
  END IF;
  IF COALESCE(record_model_attempt.selection_role, 'direct') NOT IN ('direct', 'cheap', 'strong') THEN
    RAISE EXCEPTION 'otlet record_model_attempt selection_role must be direct, cheap, or strong';
  END IF;
  IF COALESCE(record_model_attempt.selection_role, 'direct') = 'direct' THEN
    expected_model_name := task_row.model_name;
  ELSE
    SELECT CASE record_model_attempt.selection_role
      WHEN 'cheap' THEN selection_policy.cheap_model_name
      ELSE selection_policy.strong_model_name
    END
    INTO expected_model_name
    FROM otlet.model_selection_policies selection_policy
    WHERE selection_policy.task_name = job_row.task_name;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'otlet task % has no model selection policy', job_row.task_name;
    END IF;
  END IF;
  IF model_row.name IS DISTINCT FROM expected_model_name THEN
    RAISE EXCEPTION 'otlet model identity does not match task selection role';
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
  IF octet_length(COALESCE(record_model_attempt.raw_output, '')) > policy.max_raw_output_bytes THEN
    RAISE EXCEPTION 'otlet raw output exceeds evidence byte limit';
  END IF;
  IF octet_length(COALESCE(record_model_attempt.output, 'null'::jsonb)::text) > policy.max_structured_output_bytes THEN
    RAISE EXCEPTION 'otlet structured output exceeds evidence byte limit';
  END IF;
  IF octet_length(COALESCE(record_model_attempt.trace_summary, '{}'::jsonb)::text) > policy.max_trace_bytes THEN
    RAISE EXCEPTION 'otlet trace exceeds evidence byte limit';
  END IF;
  IF octet_length(COALESCE(record_model_attempt.error, '')) > policy.max_error_bytes THEN
    RAISE EXCEPTION 'otlet receipt error exceeds evidence byte limit';
  END IF;

  actual_raw_output_hash := otlet.portable_text_hash(COALESCE(record_model_attempt.raw_output, ''));
  IF record_model_attempt.raw_output IS NOT NULL
     AND record_model_attempt.raw_output_hash IS NOT NULL
     AND record_model_attempt.raw_output_hash IS DISTINCT FROM actual_raw_output_hash THEN
    RAISE EXCEPTION 'otlet record_model_attempt raw output hash is forged';
  END IF;
  actual_output_schema_hash := otlet.portable_json_hash(task_row.output_schema);
  actual_runtime_options_hash := otlet.portable_json_hash(
    policy.default_runtime_options || task_row.runtime_options
  );
  actual_model_identity_hash := otlet.portable_json_hash(jsonb_build_object(
    'name', model_row.name,
    'artifact_hash', model_row.artifact_hash,
    'artifact_identity', model_row.artifact_identity
  ));

  IF actual_selection_status = 'accepted' THEN
    portable_identity := otlet.validate_portable_result(
      job_row.id,
      record_model_attempt.output,
      record_model_attempt.raw_output,
      COALESCE(record_model_attempt.actions, '[]'::jsonb),
      model_row.name,
      record_model_attempt.selection_role,
      record_model_attempt.prompt_hash,
      record_model_attempt.input_hash,
      record_model_attempt.output_schema_hash,
      record_model_attempt.raw_output_hash,
      record_model_attempt.trace_summary
    );
    authoritative_schema_status := 'passed';
  ELSIF record_model_attempt.output IS NOT NULL THEN
    schema_error := otlet.json_schema_validation_error(
      task_row.output_schema,
      record_model_attempt.output
    );
    authoritative_schema_status := CASE WHEN schema_error IS NULL THEN 'passed' ELSE 'failed' END;
  ELSE
    authoritative_schema_status := CASE
      WHEN record_model_attempt.schema_validation_status = 'failed' THEN 'failed'
      ELSE 'not_run'
    END;
  END IF;

  SELECT COALESCE(array_agg(field_name ORDER BY field_name), ARRAY[]::text[])
  INTO output_redacted_fields
  FROM jsonb_array_elements_text(
    COALESCE(task_row.decision_contract -> 'redact_output_fields', '[]'::jsonb)
  ) fields(field_name);
  SELECT protected_fields || COALESCE(array_agg(field_name ORDER BY field_name), ARRAY[]::text[])
  INTO protected_fields
  FROM jsonb_array_elements_text(
    COALESCE(task_row.decision_contract -> 'identity_fields', '[]'::jsonb)
  ) fields(field_name);
  stored_output := otlet.redact_jsonb_fields(
    record_model_attempt.output,
    output_redacted_fields,
    protected_fields
  );

  stored_trace_summary := otlet.redact_trace_summary(
    COALESCE(record_model_attempt.trace_summary, '{}'::jsonb),
    policy_mode
  ) || jsonb_build_object(
    'evidence_redaction',
    jsonb_build_object(
      'structured_output', cardinality(output_redacted_fields) > 0,
      'structured_output_field_count', cardinality(output_redacted_fields)
    )
  ) || jsonb_build_object(
    'schema_validation_status', authoritative_schema_status,
    'schema_force', 'postgres_portable_json_schema_validation'
  ) || CASE
    WHEN portable_identity IS NULL THEN '{}'::jsonb
    ELSE jsonb_build_object('portable_validation', portable_identity)
  END;

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
    model_artifact_identity,
    runtime_name,
    runtime_endpoint,
    runtime_options,
    task_identity_hash,
    source_identity_hash,
    model_identity_hash,
    runtime_options_hash,
    prompt_hash,
    input_hash,
    output_schema_hash,
    output_hash,
    actions_hash,
    raw_output_hash,
    raw_output,
    candidate_output,
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
    model_row.artifact_identity,
    'linked_inproc',
    'linked',
    policy.default_runtime_options || task_row.runtime_options,
    portable_identity ->> 'task_identity_hash',
    portable_identity ->> 'source_identity_hash',
    COALESCE(portable_identity ->> 'model_identity_hash', actual_model_identity_hash),
    COALESCE(portable_identity ->> 'runtime_options_hash', actual_runtime_options_hash),
    COALESCE(portable_identity ->> 'prompt_hash', record_model_attempt.prompt_hash),
    COALESCE(portable_identity ->> 'input_hash', record_model_attempt.input_hash),
    actual_output_schema_hash,
    portable_identity ->> 'output_hash',
    portable_identity ->> 'actions_hash',
    actual_raw_output_hash,
    CASE WHEN policy_mode = 'diagnostic' THEN record_model_attempt.raw_output ELSE NULL END,
    CASE WHEN actual_selection_status = 'rejected' THEN stored_output ELSE NULL END,
    NULLIF(record_model_attempt.trace_summary ->> 'prompt_tokens', '')::bigint,
    NULLIF(record_model_attempt.trace_summary ->> 'generated_tokens', '')::bigint,
    NULLIF(record_model_attempt.trace_summary ->> 'generate_ms', '')::bigint,
    NULLIF(record_model_attempt.trace_summary ->> 'tokens_per_second', '')::numeric,
    authoritative_schema_status,
    stored_trace_summary,
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

  IF actual_selection_status = 'accepted' AND stored_output IS NOT NULL THEN
    INSERT INTO otlet.outputs (job_id, receipt_id, output)
    VALUES (
      job_row.id,
      saved_receipt.id,
      stored_output
    )
    RETURNING * INTO saved_output;
  END IF;

  UPDATE otlet.models
  SET last_used_at = now()
  WHERE name = model_row.name;

  RETURN saved_receipt;
END;
$$;
