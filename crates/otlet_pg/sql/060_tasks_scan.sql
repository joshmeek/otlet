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

CREATE FUNCTION otlet.effective_job_lease_interval(
  runtime_options jsonb,
  policy_max_attempt_ms integer,
  configured_lease_interval interval
) RETURNS interval
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT GREATEST(
    COALESCE($3, interval '5 minutes'),
    otlet.effective_task_max_attempt_ms($1, $2) * interval '1 millisecond'
      + interval '30 seconds'
  );
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
  contract_field text;
  saved_task otlet.tasks%ROWTYPE;
BEGIN
  IF jsonb_typeof(actual_runtime_options) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet runtime_options must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_input_shaping) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet input_shaping must be a JSON object';
  END IF;
  IF NOT actual_input_shaping ? 'source_fields' THEN
    actual_input_shaping := jsonb_set(actual_input_shaping, '{source_fields}', '[]'::jsonb, true);
  END IF;
  IF jsonb_typeof(actual_input_shaping -> 'source_fields') IS DISTINCT FROM 'array'
     OR jsonb_array_length(actual_input_shaping -> 'source_fields') > 64
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(actual_input_shaping -> 'source_fields') source_field(value)
       WHERE jsonb_typeof(source_field.value) IS DISTINCT FROM 'string'
          OR NULLIF(source_field.value #>> '{}', '') IS NULL
          OR octet_length(source_field.value #>> '{}') > 128
     ) THEN
    RAISE EXCEPTION 'otlet input_shaping.source_fields must contain at most 64 non-empty field names';
  END IF;
  SELECT jsonb_set(
    actual_input_shaping,
    '{source_fields}',
    COALESCE(jsonb_agg(source_field ORDER BY source_field), '[]'::jsonb),
    true
  )
  INTO actual_input_shaping
  FROM (
    SELECT DISTINCT value AS source_field
    FROM jsonb_array_elements_text(actual_input_shaping -> 'source_fields') source_field(value)
  ) normalized;
  IF actual_input_shaping ? 'max_shaped_input_bytes'
     AND (
       jsonb_typeof(actual_input_shaping -> 'max_shaped_input_bytes') IS DISTINCT FROM 'number'
       OR (actual_input_shaping ->> 'max_shaped_input_bytes') !~ '^[1-9][0-9]*$'
       OR (actual_input_shaping ->> 'max_shaped_input_bytes')::numeric > 1048576
     ) THEN
    RAISE EXCEPTION 'otlet input_shaping.max_shaped_input_bytes must be an integer between 1 and 1048576';
  END IF;
  IF jsonb_typeof(actual_decision_contract) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet decision_contract must be a JSON object';
  END IF;
  FOREACH contract_field IN ARRAY ARRAY['redact_output_fields', 'redact_action_fields', 'identity_fields'] LOOP
    IF actual_decision_contract ? contract_field
       AND (
         jsonb_typeof(actual_decision_contract -> contract_field) IS DISTINCT FROM 'array'
         OR jsonb_array_length(actual_decision_contract -> contract_field) > 64
         OR EXISTS (
           SELECT 1
           FROM jsonb_array_elements(actual_decision_contract -> contract_field) item(value)
           WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'string'
              OR NULLIF(item.value #>> '{}', '') IS NULL
              OR octet_length(item.value #>> '{}') > 128
         )
       ) THEN
      RAISE EXCEPTION 'otlet decision_contract.% must contain at most 64 non-empty field names', contract_field;
    END IF;
  END LOOP;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements_text(
      COALESCE(actual_decision_contract -> 'redact_output_fields', '[]'::jsonb)
      || COALESCE(actual_decision_contract -> 'redact_action_fields', '[]'::jsonb)
    ) redacted(field_name)
    WHERE redacted.field_name = ANY(ARRAY[
      'id', 'subject_id', 'entity_id', 'left_id', 'right_id', 'type', 'body',
      'match', 'confidence', 'action_type', 'record_type', 'target', 'identity', 'changes'
    ])
       OR redacted.field_name IN (
         SELECT identity.field_name
         FROM jsonb_array_elements_text(
           COALESCE(actual_decision_contract -> 'identity_fields', '[]'::jsonb)
         ) identity(field_name)
       )
  ) THEN
    RAISE EXCEPTION 'otlet evidence redaction cannot target identity or control fields';
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

  IF NOT actual_decision_contract ? 'action_types' THEN
    actual_decision_contract := jsonb_set(actual_decision_contract, '{action_types}', '[]'::jsonb, true);
  END IF;
  IF jsonb_typeof(actual_decision_contract -> 'action_types') IS DISTINCT FROM 'array'
     OR jsonb_array_length(actual_decision_contract -> 'action_types') > 64
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(actual_decision_contract -> 'action_types') action_type(value)
       WHERE jsonb_typeof(action_type.value) IS DISTINCT FROM 'string'
          OR NULLIF(action_type.value #>> '{}', '') IS NULL
          OR octet_length(action_type.value #>> '{}') > 128
     ) THEN
    RAISE EXCEPTION 'otlet decision_contract.action_types must contain at most 64 non-empty action types';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements_text(actual_decision_contract -> 'action_types') action_type(value)
    WHERE NOT EXISTS (
      SELECT 1
      FROM otlet.action_type_schemas schema
      WHERE schema.action_type = action_type.value
    )
  ) THEN
    RAISE EXCEPTION 'otlet decision_contract.action_types contains an unsupported action type';
  END IF;
  SELECT jsonb_set(
    actual_decision_contract,
    '{action_types}',
    COALESCE(jsonb_agg(action_type ORDER BY action_type), '[]'::jsonb),
    true
  )
  INTO actual_decision_contract
  FROM (
    SELECT DISTINCT value AS action_type
    FROM jsonb_array_elements_text(actual_decision_contract -> 'action_types') action_type(value)
  ) normalized;

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
  IF jsonb_typeof(actual_input) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet ask input must be a JSON object';
  END IF;
  direct_task_name := 'ask_' || substr(md5(
    ask.model_name || chr(10) ||
    ask.instruction || chr(10) ||
    actual_schema::text || chr(10) ||
    actual_options::text || chr(10) ||
    (
      SELECT COALESCE(jsonb_agg(input_field ORDER BY input_field), '[]'::jsonb)::text
      FROM jsonb_object_keys(actual_input) input_field
    )
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

CREATE FUNCTION otlet.preflight_candidate_query(candidate_query text)
RETURNS TABLE (
  candidate_plan jsonb,
  candidate_plan_cost numeric,
  statement_timeout_ms integer
)
LANGUAGE plpgsql
AS $$
DECLARE
  policy otlet.production_policy%ROWTYPE;
BEGIN
  IF NULLIF(btrim(preflight_candidate_query.candidate_query), '') IS NULL THEN
    RAISE EXCEPTION 'otlet candidate query is required';
  END IF;

  SELECT *
  INTO policy
  FROM otlet.production_policy
  WHERE name = 'default';

  BEGIN
    EXECUTE format(
      'EXPLAIN (FORMAT JSON) SELECT subject_id::text, input::jsonb FROM (%s) otlet_candidate',
      preflight_candidate_query.candidate_query
    ) INTO candidate_plan;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'otlet candidate query EXPLAIN failed: %', SQLERRM;
  END;

  candidate_plan_cost := (candidate_plan #>> '{0,Plan,Total Cost}')::numeric;
  statement_timeout_ms := policy.candidate_query_statement_timeout_ms;
  IF candidate_plan_cost > policy.max_candidate_query_cost THEN
    RAISE EXCEPTION 'otlet candidate query plan cost % exceeds limit %',
      candidate_plan_cost,
      policy.max_candidate_query_cost;
  END IF;

  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.require_candidate_query_timeout(task_name text)
RETURNS integer
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  timeout_limit integer;
  timeout_ms integer;
BEGIN
  SELECT p.candidate_query_statement_timeout_ms
  INTO timeout_limit
  FROM otlet.semantic_join_indexes sji
  CROSS JOIN otlet.production_policy p
  WHERE sji.task_name = require_candidate_query_timeout.task_name
    AND p.name = 'default';

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  timeout_ms := round(EXTRACT(epoch FROM current_setting('statement_timeout')::interval) * 1000)::integer;
  IF timeout_ms <= 0 OR timeout_ms > timeout_limit THEN
    RAISE EXCEPTION 'otlet candidate query requires statement_timeout between 1 ms and % ms', timeout_limit
      USING HINT = format(
        'Run SET LOCAL statement_timeout = %L before the refresh statement',
        timeout_limit || 'ms'
      );
  END IF;

  RETURN timeout_ms;
END;
$$;

CREATE FUNCTION otlet.available_model_queue_slots(model_name text)
RETURNS integer
LANGUAGE sql
STABLE
AS $$
  SELECT GREATEST(
    p.max_queued_jobs_per_model
      - (
        SELECT count(*)
        FROM otlet.jobs j
        JOIN otlet.tasks t ON t.name = j.task_name
        WHERE j.status = 'queued'
          AND t.model_name = $1
      ),
    0
  )::integer
  FROM otlet.production_policy p
  WHERE p.name = 'default';
$$;

CREATE FUNCTION otlet.record_queue_admission_suppressed(
  suppressed_task_name text,
  suppressed_model_name text,
  suppressed_subject_id text DEFAULT NULL,
  suppressed_queued_jobs bigint DEFAULT NULL,
  suppressed_queue_slots integer DEFAULT NULL,
  suppressed_reason text DEFAULT 'queue_depth_cap',
  suppressed_input_bytes bigint DEFAULT NULL,
  suppressed_limit_bytes bigint DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  inserted bigint := 0;
  suppressed_detail jsonb;
BEGIN
  suppressed_detail := jsonb_strip_nulls(jsonb_build_object(
    'task_name', suppressed_task_name,
    'subject_id', suppressed_subject_id,
    'model_name', suppressed_model_name,
    'reason', suppressed_reason,
    'queued_jobs', suppressed_queued_jobs,
    'queue_slots', suppressed_queue_slots,
    'input_bytes', suppressed_input_bytes,
    'limit_bytes', suppressed_limit_bytes
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
      AND e.detail ? 'model_name'
      AND e.detail ->> 'model_name' = suppressed_model_name
      AND e.detail ? 'task_name'
      AND e.detail ->> 'task_name' = suppressed_task_name
      AND e.detail ->> 'reason' = suppressed_reason
      AND e.created_at > now() - interval '1 minute'
  );
  GET DIAGNOSTICS inserted = ROW_COUNT;

  RETURN inserted > 0;
END;
$$;

CREATE FUNCTION otlet.admit_task_input(
  task_name text,
  subject_id text,
  input jsonb
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  task_model_name text;
  input_bytes bigint := octet_length(admit_task_input.input::text);
  policy otlet.production_policy%ROWTYPE;
  queued_jobs bigint;
  model_queued_bytes bigint;
  total_queued_bytes bigint;
  inserted bigint := 0;
  rejection_reason text;
  rejection_limit bigint;
BEGIN
  SELECT t.model_name
  INTO task_model_name
  FROM otlet.tasks t
  WHERE t.name = admit_task_input.task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', admit_task_input.task_name;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));

  SELECT *
  INTO policy
  FROM otlet.production_policy
  WHERE name = 'default';

  SELECT
    count(*) FILTER (WHERE t.model_name = task_model_name),
    COALESCE(sum(octet_length(j.input::text)) FILTER (WHERE t.model_name = task_model_name), 0),
    COALESCE(sum(octet_length(j.input::text)), 0)
  INTO queued_jobs, model_queued_bytes, total_queued_bytes
  FROM otlet.jobs j
  JOIN otlet.tasks t ON t.name = j.task_name
  WHERE j.status = 'queued';

  IF input_bytes > policy.max_input_bytes_per_job THEN
    rejection_reason := 'input_byte_cap';
    rejection_limit := policy.max_input_bytes_per_job;
  ELSIF queued_jobs >= policy.max_queued_jobs_per_model THEN
    rejection_reason := 'queue_depth_cap';
    rejection_limit := policy.max_queued_jobs_per_model;
  ELSIF model_queued_bytes + input_bytes > policy.max_queued_input_bytes_per_model THEN
    rejection_reason := 'model_queued_input_byte_cap';
    rejection_limit := policy.max_queued_input_bytes_per_model;
  ELSIF total_queued_bytes + input_bytes > policy.max_queued_input_bytes_total THEN
    rejection_reason := 'total_queued_input_byte_cap';
    rejection_limit := policy.max_queued_input_bytes_total;
  END IF;

  IF rejection_reason IS NOT NULL THEN
    PERFORM otlet.record_queue_admission_suppressed(
      admit_task_input.task_name,
      task_model_name,
      admit_task_input.subject_id,
      queued_jobs,
      GREATEST(policy.max_queued_jobs_per_model - queued_jobs, 0)::integer,
      rejection_reason,
      input_bytes,
      rejection_limit
    );
    RETURN false;
  END IF;

  INSERT INTO otlet.jobs (task_name, subject_id, input)
  VALUES (admit_task_input.task_name, admit_task_input.subject_id, admit_task_input.input)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS inserted = ROW_COUNT;

  RETURN inserted > 0;
END;
$$;

CREATE FUNCTION otlet.run_task(task_name text) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  task_model_name text;
  queue_slots integer;
  queued bigint := 0;
  candidate_rows bigint;
  candidate_bytes bigint;
  largest_input_bytes bigint;
  rejection_reason text;
  rejection_limit bigint;
BEGIN
  SELECT input_query, tasks.model_name
  INTO query, task_model_name
  FROM otlet.tasks
  WHERE name = task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', task_name;
  END IF;

  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', task_name;
  END IF;

  PERFORM otlet.require_candidate_query_timeout(run_task.task_name);
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));

  EXECUTE format(
    'WITH policy AS (
       SELECT *
       FROM otlet.production_policy p
       WHERE p.name = ''default''
     ),
     queue_state AS (
       SELECT
         count(*) FILTER (WHERE queued_tasks.model_name = %1$L)::bigint AS model_queued_jobs,
         COALESCE(sum(octet_length(j.input::text)) FILTER (WHERE queued_tasks.model_name = %1$L), 0)::bigint AS model_queued_bytes,
         COALESCE(sum(octet_length(j.input::text)), 0)::bigint AS total_queued_bytes
       FROM otlet.jobs j
       JOIN otlet.tasks queued_tasks ON queued_tasks.name = j.task_name
       WHERE j.status = ''queued''
     ),
     bounded_input AS MATERIALIZED (
       SELECT
         subject_id::text AS subject_id,
         input::jsonb AS input,
         octet_length(input::jsonb::text)::bigint AS input_bytes
       FROM (%2$s) otlet_input
       WHERE NOT EXISTS (
         SELECT 1
         FROM otlet.jobs active_job
         WHERE active_job.task_name = %3$L
           AND active_job.subject_id = otlet_input.subject_id::text
           AND active_job.status IN (''queued'', ''running'', ''cancel_requested'')
       )
       ORDER BY subject_id
       LIMIT (SELECT max_admission_rows + 1 FROM policy)
     ),
     candidate_state AS (
       SELECT
         count(*)::bigint AS candidate_rows,
         COALESCE(sum(input_bytes), 0)::bigint AS candidate_bytes,
         COALESCE(max(input_bytes), 0)::bigint AS largest_input_bytes
       FROM bounded_input
     ),
     decision AS (
       SELECT
         GREATEST(p.max_queued_jobs_per_model - q.model_queued_jobs, 0)::integer AS queue_slots,
         c.*,
         CASE
           WHEN c.candidate_rows > p.max_admission_rows THEN ''row_cap''
           WHEN c.candidate_rows > GREATEST(p.max_queued_jobs_per_model - q.model_queued_jobs, 0) THEN ''queue_depth_cap''
           WHEN c.largest_input_bytes > p.max_input_bytes_per_job THEN ''input_byte_cap''
           WHEN q.model_queued_bytes + c.candidate_bytes > p.max_queued_input_bytes_per_model THEN ''model_queued_input_byte_cap''
           WHEN q.total_queued_bytes + c.candidate_bytes > p.max_queued_input_bytes_total THEN ''total_queued_input_byte_cap''
         END AS rejection_reason,
         CASE
           WHEN c.candidate_rows > p.max_admission_rows THEN p.max_admission_rows::bigint
           WHEN c.candidate_rows > GREATEST(p.max_queued_jobs_per_model - q.model_queued_jobs, 0) THEN GREATEST(p.max_queued_jobs_per_model - q.model_queued_jobs, 0)::bigint
           WHEN c.largest_input_bytes > p.max_input_bytes_per_job THEN p.max_input_bytes_per_job
           WHEN q.model_queued_bytes + c.candidate_bytes > p.max_queued_input_bytes_per_model THEN p.max_queued_input_bytes_per_model
           WHEN q.total_queued_bytes + c.candidate_bytes > p.max_queued_input_bytes_total THEN p.max_queued_input_bytes_total
         END AS rejection_limit
       FROM policy p
       CROSS JOIN queue_state q
       CROSS JOIN candidate_state c
     ),
     inserted AS (
       INSERT INTO otlet.jobs (task_name, subject_id, input)
       SELECT %3$L, pending.subject_id, pending.input
       FROM bounded_input pending
       CROSS JOIN decision d
       WHERE d.rejection_reason IS NULL
       ORDER BY pending.subject_id
       ON CONFLICT (task_name, subject_id)
       WHERE status IN (''queued'', ''running'', ''cancel_requested'')
       DO NOTHING
       RETURNING 1
     )
     SELECT
       (SELECT count(*) FROM inserted),
       candidate_rows,
       candidate_bytes,
       largest_input_bytes,
       queue_slots,
       rejection_reason,
       rejection_limit
     FROM decision',
    task_model_name,
    query,
    task_name
  )
  INTO queued, candidate_rows, candidate_bytes, largest_input_bytes, queue_slots, rejection_reason, rejection_limit;

  IF rejection_reason IS NOT NULL THEN
    PERFORM otlet.record_queue_admission_suppressed(
      run_task.task_name,
      task_model_name,
      suppressed_queued_jobs => candidate_rows,
      suppressed_queue_slots => queue_slots,
      suppressed_reason => rejection_reason,
      suppressed_input_bytes => CASE
        WHEN rejection_reason = 'input_byte_cap' THEN largest_input_bytes
        ELSE candidate_bytes
      END,
      suppressed_limit_bytes => rejection_limit
    );
    RETURN 0;
  END IF;

  IF queued <> candidate_rows THEN
    RAISE EXCEPTION 'otlet queue admission changed concurrently; no jobs were committed';
  END IF;

  IF queued > 0 THEN
    PERFORM otlet.wake_worker();
  END IF;

  RETURN queued;
END;
$$;

COMMENT ON FUNCTION otlet.run_task(text) IS
  'Queues all current bounded task source rows or none. Completed subjects are eligible for a new job on direct rerun; queued, running, and cancel-requested subjects are not duplicated.';

CREATE FUNCTION otlet.run_task_subject(
  task_name text,
  subject_id text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  pending_input jsonb;
  pending_rows bigint;
  queued boolean;
BEGIN
  SELECT input_query
  INTO query
  FROM otlet.tasks
  WHERE name = run_task_subject.task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', run_task_subject.task_name;
  END IF;

  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', run_task_subject.task_name;
  END IF;

  PERFORM otlet.require_candidate_query_timeout(run_task_subject.task_name);
  EXECUTE format(
    'SELECT input::jsonb
     FROM (%s) otlet_input
     WHERE subject_id::text = %L
     LIMIT 1',
    query,
    run_task_subject.subject_id
  )
  INTO pending_input;
  GET DIAGNOSTICS pending_rows = ROW_COUNT;

  IF pending_rows = 0 THEN
    RETURN 0;
  END IF;
  IF pending_input IS NULL THEN
    RAISE EXCEPTION 'otlet task % produced null input for subject %',
      run_task_subject.task_name,
      run_task_subject.subject_id;
  END IF;

  queued := otlet.admit_task_input(
    run_task_subject.task_name,
    run_task_subject.subject_id,
    pending_input
  );
  IF queued THEN
    PERFORM otlet.wake_worker();
  END IF;

  RETURN queued::integer;
END;
$$;

CREATE FUNCTION otlet.run_task_subjects(
  task_name text,
  subject_ids text[]
) RETURNS TABLE(subject_id text, queued boolean)
LANGUAGE plpgsql
AS $$
BEGIN
  IF cardinality(run_task_subjects.subject_ids) > 64 THEN
    RAISE EXCEPTION 'otlet.run_task_subjects accepts at most 64 subjects';
  END IF;

  RETURN QUERY
  SELECT requested.subject_id,
         otlet.run_task_subject(run_task_subjects.task_name, requested.subject_id) > 0
  FROM unnest(COALESCE(run_task_subjects.subject_ids, ARRAY[]::text[])) WITH ORDINALITY
    AS requested(subject_id, ordinal)
  WHERE requested.subject_id IS NOT NULL
  ORDER BY requested.ordinal;
END;
$$;

COMMENT ON FUNCTION otlet.run_task_subjects(text, text[]) IS
  'Queues a bounded subject array in order through the existing per-subject task and admission contract';
