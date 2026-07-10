CREATE FUNCTION otlet.effective_task_max_attempt_ms(
  runtime_options jsonb,
  policy_max_attempt_ms integer
) RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT LEAST(
    GREATEST(
      COALESCE(
        CASE
          WHEN COALESCE($1, '{}'::jsonb) ? 'max_attempt_ms'
           AND (COALESCE($1, '{}'::jsonb) ->> 'max_attempt_ms') ~ '^[0-9]+$'
          THEN (COALESCE($1, '{}'::jsonb) ->> 'max_attempt_ms')::numeric
          ELSE NULL
        END,
        COALESCE($2, 300000)::numeric
      ),
      1
    ),
    GREATEST(COALESCE($2, 300000), 1)::numeric
  )::integer;
$$;

CREATE FUNCTION otlet.create_task(
  task_name text,
  input_query text,
  instruction text,
  output_schema jsonb,
  model_name text,
  runtime_options jsonb DEFAULT '{}'::jsonb,
  input_shaping jsonb DEFAULT '{}'::jsonb,
  decision_contract jsonb DEFAULT '{}'::jsonb
) RETURNS otlet.tasks
LANGUAGE plpgsql
AS $$
DECLARE
  actual_runtime_options jsonb := COALESCE(create_task.runtime_options, '{}'::jsonb);
  actual_input_shaping jsonb := COALESCE(create_task.input_shaping, '{}'::jsonb);
  actual_decision_contract jsonb := COALESCE(create_task.decision_contract, '{}'::jsonb);
  preset_name text;
  preset_contract jsonb;
  preset_contract_hash text;
  saved_task otlet.tasks%ROWTYPE;
BEGIN
  IF jsonb_typeof(actual_runtime_options) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet runtime_options must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_input_shaping) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet input_shaping must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_decision_contract) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet decision_contract must be a JSON object';
  END IF;
  IF actual_runtime_options ? 'max_attempt_ms'
     AND (
       (actual_runtime_options ->> 'max_attempt_ms') IS NULL
       OR (actual_runtime_options ->> 'max_attempt_ms') !~ '^[0-9]+$'
     ) THEN
    RAISE EXCEPTION 'otlet runtime_options.max_attempt_ms must be a non-negative integer';
  END IF;

  preset_name := NULLIF(actual_decision_contract ->> 'preset', '');
  IF preset_name IS NOT NULL THEN
    SELECT
      p.decision_contract,
      md5(otlet.semantic_canonical_jsonb(p.decision_contract)::text)
    INTO preset_contract, preset_contract_hash
    FROM otlet.decision_rule_presets p
    WHERE p.name = preset_name;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'otlet decision rule preset % does not exist', preset_name;
    END IF;

    actual_decision_contract :=
      preset_contract
      || (actual_decision_contract - 'preset')
      || jsonb_build_object(
        'preset', preset_name,
        'preset_contract_hash', preset_contract_hash
      );
  END IF;

  INSERT INTO otlet.tasks (
    name,
    input_query,
    instruction,
    output_schema,
    model_name,
    runtime_options,
    input_shaping,
    decision_contract
  )
  VALUES (
    create_task.task_name,
    create_task.input_query,
    create_task.instruction,
    create_task.output_schema,
    create_task.model_name,
    actual_runtime_options,
    actual_input_shaping,
    actual_decision_contract
  )
  ON CONFLICT (name) DO UPDATE
    SET (input_query, instruction, output_schema, model_name, runtime_options, input_shaping, decision_contract) = (
      EXCLUDED.input_query,
      EXCLUDED.instruction,
      EXCLUDED.output_schema,
      EXCLUDED.model_name,
      EXCLUDED.runtime_options,
      EXCLUDED.input_shaping,
      EXCLUDED.decision_contract
    )
  RETURNING * INTO saved_task;

  UPDATE otlet.semantic_materializations sm
  SET stale = true,
      stale_reason = 'contract_changed',
      updated_at = now()
  WHERE sm.task_name = saved_task.name
    AND sm.contract_hash IS NOT NULL
    AND sm.contract_hash IS DISTINCT FROM otlet.task_contract_hash(
      saved_task.instruction,
      saved_task.output_schema,
      saved_task.model_name,
      saved_task.runtime_options,
      saved_task.input_shaping,
      saved_task.decision_contract
    );

  RETURN saved_task;
END;
$$;

CREATE FUNCTION otlet.ask(
  model_name text,
  instruction text,
  input jsonb DEFAULT '{}'::jsonb,
  output_schema jsonb DEFAULT '{"type":"object"}'::jsonb,
  runtime_options jsonb DEFAULT '{"max_tokens":256}'::jsonb,
  timeout_ms integer DEFAULT 30000
) RETURNS TABLE (
  output jsonb,
  job_id bigint,
  receipt_id bigint,
  raw_output_hash text
)
LANGUAGE plpgsql
AS $$
DECLARE
  actual_input jsonb := COALESCE(ask.input, '{}'::jsonb);
  actual_schema jsonb := COALESCE(ask.output_schema, '{"type":"object"}'::jsonb);
  actual_options jsonb := COALESCE(ask.runtime_options, '{"max_tokens":256}'::jsonb);
  direct_task_name text;
  direct_subject_id text;
  completed_job_id bigint;
BEGIN
  direct_task_name := 'ask_' || substr(md5(
    ask.model_name || chr(10) ||
    ask.instruction || chr(10) ||
    actual_schema::text || chr(10) ||
    actual_options::text
  ), 1, 24);
  direct_subject_id := 'ask_' || substr(md5(
    clock_timestamp()::text || chr(10) ||
    random()::text || chr(10) ||
    actual_input::text
  ), 1, 24);

  completed_job_id := otlet.worker_infer_now(
    direct_task_name,
    direct_subject_id,
    actual_input,
    LEAST(GREATEST(COALESCE(ask.timeout_ms, 30000), 0), 30000),
    ask.model_name,
    ask.instruction,
    actual_schema,
    actual_options
  );

  IF completed_job_id = 0 THEN
    RAISE EXCEPTION 'otlet ask worker is busy';
  END IF;

  RETURN QUERY
    SELECT r.output, r.job_id, r.receipt_id, r.raw_output_hash
    FROM otlet.runs r
    WHERE r.job_id = completed_job_id
      AND r.output_id IS NOT NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet ask job % produced no trusted output', completed_job_id;
  END IF;
END;
$$;

CREATE FUNCTION otlet.set_model_selection_policy(
  task_name text,
  cheap_model_name text,
  strong_model_name text,
  accept_field_checks jsonb DEFAULT NULL
) RETURNS otlet.model_selection_policies
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.model_selection_policies%ROWTYPE;
  actual_accept_field_checks jsonb;
BEGIN
  UPDATE otlet.tasks t
  SET model_name = set_model_selection_policy.cheap_model_name
  WHERE t.name = set_model_selection_policy.task_name;

  SELECT COALESCE(
    set_model_selection_policy.accept_field_checks,
    NULLIF(jsonb_strip_nulls(jsonb_build_object(
      'answer_field', t.decision_contract ->> 'answer_field',
      'abstain_values', t.decision_contract -> 'abstain_values',
      'confidence_field', t.decision_contract ->> 'confidence_field',
      'accepted_confidence', t.decision_contract -> 'accepted_confidence'
    )), '{}'::jsonb),
    otlet.default_accept_field_checks()
  )
  INTO actual_accept_field_checks
  FROM otlet.tasks t
  WHERE t.name = set_model_selection_policy.task_name;

  IF actual_accept_field_checks IS NULL THEN
    RAISE EXCEPTION 'otlet task % does not exist', set_model_selection_policy.task_name;
  END IF;
  IF jsonb_typeof(actual_accept_field_checks) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet accept_field_checks must be a JSON object';
  END IF;
  IF actual_accept_field_checks ? 'answer_field'
     AND (
       jsonb_typeof(actual_accept_field_checks -> 'answer_field') IS DISTINCT FROM 'string'
       OR NULLIF(actual_accept_field_checks ->> 'answer_field', '') IS NULL
     ) THEN
    RAISE EXCEPTION 'otlet accept_field_checks.answer_field must be a non-empty string';
  END IF;
  IF actual_accept_field_checks ? 'confidence_field'
     AND (
       jsonb_typeof(actual_accept_field_checks -> 'confidence_field') IS DISTINCT FROM 'string'
       OR NULLIF(actual_accept_field_checks ->> 'confidence_field', '') IS NULL
     ) THEN
    RAISE EXCEPTION 'otlet accept_field_checks.confidence_field must be a non-empty string';
  END IF;
  IF actual_accept_field_checks ? 'abstain_values' THEN
    IF NOT actual_accept_field_checks ? 'answer_field'
       OR NULLIF(actual_accept_field_checks ->> 'answer_field', '') IS NULL THEN
      RAISE EXCEPTION 'otlet accept_field_checks.abstain_values requires answer_field';
    END IF;
    IF jsonb_typeof(actual_accept_field_checks -> 'abstain_values') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'otlet accept_field_checks.abstain_values must be an array';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(actual_accept_field_checks -> 'abstain_values') value(item)
      WHERE jsonb_typeof(value.item) <> 'string'
    ) THEN
      RAISE EXCEPTION 'otlet accept_field_checks.abstain_values must contain only strings';
    END IF;
  END IF;
  IF actual_accept_field_checks ? 'accepted_confidence' THEN
    IF NOT actual_accept_field_checks ? 'confidence_field'
       OR NULLIF(actual_accept_field_checks ->> 'confidence_field', '') IS NULL THEN
      RAISE EXCEPTION 'otlet accept_field_checks.accepted_confidence requires confidence_field';
    END IF;
    IF jsonb_typeof(actual_accept_field_checks -> 'accepted_confidence') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'otlet accept_field_checks.accepted_confidence must be an array';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(actual_accept_field_checks -> 'accepted_confidence') value(item)
      WHERE jsonb_typeof(value.item) <> 'string'
    ) THEN
      RAISE EXCEPTION 'otlet accept_field_checks.accepted_confidence must contain only strings';
    END IF;
  END IF;

  INSERT INTO otlet.model_selection_policies (
    task_name,
    cheap_model_name,
    strong_model_name,
    accept_field_checks,
    updated_at
  )
  VALUES (
    set_model_selection_policy.task_name,
    set_model_selection_policy.cheap_model_name,
    set_model_selection_policy.strong_model_name,
    actual_accept_field_checks,
    now()
  )
  ON CONFLICT ON CONSTRAINT model_selection_policies_pkey DO UPDATE
    SET cheap_model_name = EXCLUDED.cheap_model_name,
        strong_model_name = EXCLUDED.strong_model_name,
        accept_field_checks = EXCLUDED.accept_field_checks,
        updated_at = now()
  RETURNING * INTO saved;

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.available_model_queue_slots(model_name text)
RETURNS integer
LANGUAGE sql
STABLE
AS $$
  SELECT GREATEST(
    p.max_queued_jobs_per_model
      - count(j.id),
    0
  )::integer
  FROM otlet.production_policy p
  LEFT JOIN otlet.tasks t ON t.model_name = $1
  LEFT JOIN otlet.jobs j ON j.task_name = t.name AND j.status = 'queued'
  GROUP BY p.max_queued_jobs_per_model;
$$;

CREATE FUNCTION otlet.record_queue_admission_suppressed(
  suppressed_task_name text,
  suppressed_model_name text,
  suppressed_subject_id text DEFAULT NULL,
  suppressed_queued_jobs bigint DEFAULT NULL,
  suppressed_queue_slots integer DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  inserted bigint := 0;
  suppressed_reason text := 'queue_cap';
  suppressed_detail jsonb;
BEGIN
  suppressed_detail := jsonb_strip_nulls(jsonb_build_object(
    'task_name', suppressed_task_name,
    'subject_id', suppressed_subject_id,
    'model_name', suppressed_model_name,
    'reason', suppressed_reason,
    'queued_jobs', suppressed_queued_jobs,
    'queue_slots', suppressed_queue_slots
  ));

  INSERT INTO otlet.worker_events (event_type, message, detail)
  SELECT
    'queue_admission_suppressed',
    'otlet queue admission suppressed by model queue cap',
    suppressed_detail
  WHERE NOT EXISTS (
    SELECT 1
    FROM otlet.worker_events e
    WHERE e.event_type = 'queue_admission_suppressed'
      AND e.detail ->> 'task_name' = suppressed_task_name
      AND e.detail ->> 'reason' = suppressed_reason
      AND e.created_at > now() - interval '1 minute'
  );
  GET DIAGNOSTICS inserted = ROW_COUNT;

  RETURN inserted > 0;
END;
$$;

CREATE FUNCTION otlet.run_task(task_name text) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  model_name text;
  queue_slots integer;
  queued bigint;
  has_pending boolean := false;
  has_overflow boolean := false;
BEGIN
  SELECT input_query, tasks.model_name
  INTO query, model_name
  FROM otlet.tasks
  WHERE name = task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', task_name;
  END IF;

  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', task_name;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue:' || model_name));
  SELECT otlet.available_model_queue_slots(model_name) INTO queue_slots;
  IF queue_slots <= 0 THEN
    EXECUTE format(
      'SELECT EXISTS (SELECT 1 FROM (%s) otlet_input LIMIT 1)',
      query
    )
    INTO has_pending;

    IF has_pending THEN
      PERFORM otlet.record_queue_admission_suppressed(run_task.task_name, model_name);
    END IF;

    RETURN 0;
  END IF;

  EXECUTE format(
    'WITH queue_capacity AS (
       SELECT GREATEST(
         p.max_queued_jobs_per_model
           - count(j.id),
         0
       )::integer AS slots
       FROM otlet.production_policy p
       LEFT JOIN otlet.tasks queued_tasks ON queued_tasks.model_name = %L
       LEFT JOIN otlet.jobs j
         ON j.task_name = queued_tasks.name
        AND j.status = ''queued''
       GROUP BY p.max_queued_jobs_per_model
     )
     INSERT INTO otlet.jobs (task_name, subject_id, input)
     SELECT %L, subject_id::text, input::jsonb
     FROM (
       SELECT subject_id::text AS subject_id, input::jsonb AS input
       FROM (%s) otlet_input
       ORDER BY subject_id
       LIMIT (SELECT slots FROM queue_capacity)
     ) otlet_bounded_input
     ON CONFLICT (task_name, subject_id)
     WHERE status IN (''queued'', ''running'', ''cancel_requested'')
     DO NOTHING',
    model_name,
    task_name,
    query
  );
  GET DIAGNOSTICS queued = ROW_COUNT;

  IF queued >= queue_slots THEN
    EXECUTE format(
      'SELECT EXISTS (
         SELECT 1
         FROM (
           SELECT subject_id::text AS subject_id, input::jsonb AS input
           FROM (%s) otlet_input
           ORDER BY subject_id
           OFFSET %s
           LIMIT 1
         ) otlet_overflow_input
       )',
      query,
      queue_slots
    )
    INTO has_overflow;

    IF has_overflow THEN
      PERFORM otlet.record_queue_admission_suppressed(
        run_task.task_name,
        model_name,
        suppressed_queued_jobs => queued,
        suppressed_queue_slots => queue_slots
      );
    END IF;
  END IF;

  IF queued > 0 THEN
    PERFORM otlet.wake_worker();
  END IF;

  RETURN queued;
END;
$$;

COMMENT ON FUNCTION otlet.run_task(text) IS
  'Queues current task source rows up to the model queue cap. Completed subjects are eligible for a new job on direct rerun; queued, running, and cancel-requested subjects are not duplicated.';

CREATE FUNCTION otlet.run_task_subject(
  task_name text,
  subject_id text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  model_name text;
  queue_slots integer;
  queued bigint;
  has_pending boolean := false;
BEGIN
  SELECT input_query, tasks.model_name
  INTO query, model_name
  FROM otlet.tasks
  WHERE name = run_task_subject.task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', run_task_subject.task_name;
  END IF;

  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', run_task_subject.task_name;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue:' || model_name));
  SELECT otlet.available_model_queue_slots(model_name) INTO queue_slots;
  IF queue_slots <= 0 THEN
    EXECUTE format(
      'SELECT EXISTS (
         SELECT 1
         FROM (%s) otlet_input
         WHERE subject_id::text = %L
         LIMIT 1
       )',
      query,
      run_task_subject.subject_id
    )
    INTO has_pending;

    IF has_pending THEN
      PERFORM otlet.record_queue_admission_suppressed(
        run_task_subject.task_name,
        model_name,
        run_task_subject.subject_id
      );
    END IF;

    RETURN 0;
  END IF;

  EXECUTE format(
    'WITH queue_capacity AS (
       SELECT GREATEST(
         p.max_queued_jobs_per_model
           - count(j.id),
         0
       )::integer AS slots
       FROM otlet.production_policy p
       LEFT JOIN otlet.tasks queued_tasks ON queued_tasks.model_name = %L
       LEFT JOIN otlet.jobs j
         ON j.task_name = queued_tasks.name
        AND j.status = ''queued''
       GROUP BY p.max_queued_jobs_per_model
     )
     INSERT INTO otlet.jobs (task_name, subject_id, input)
     SELECT %L, subject_id::text, input::jsonb FROM (%s) otlet_input
     WHERE subject_id::text = %L
       AND (SELECT slots FROM queue_capacity) > 0
     ON CONFLICT (task_name, subject_id)
     WHERE status IN (''queued'', ''running'', ''cancel_requested'')
     DO NOTHING',
    model_name,
    run_task_subject.task_name,
    query,
    run_task_subject.subject_id
  );
  GET DIAGNOSTICS queued = ROW_COUNT;
  IF queued > 0 THEN
    PERFORM otlet.wake_worker();
  END IF;

  RETURN queued;
END;
$$;
