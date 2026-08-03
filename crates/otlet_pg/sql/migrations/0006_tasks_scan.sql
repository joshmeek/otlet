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
  decision_contract jsonb DEFAULT '{}'::jsonb,
  source_relations jsonb DEFAULT NULL
) RETURNS otlet.tasks
LANGUAGE plpgsql
AS $$
DECLARE
  actual_runtime_options jsonb := COALESCE(create_task.runtime_options, '{}'::jsonb);
  actual_input_shaping jsonb := COALESCE(create_task.input_shaping, '{}'::jsonb);
  actual_decision_contract jsonb := COALESCE(create_task.decision_contract, '{}'::jsonb);
  actual_source_relations jsonb := create_task.source_relations;
  preset_name text;
  preset_contract jsonb;
  preset_contract_hash text;
  contract_field text;
  schema_error text;
  saved_task otlet.tasks%ROWTYPE;
BEGIN
  SELECT report.error
  INTO schema_error
  FROM otlet.json_schema_support_report(create_task.output_schema) report
  ORDER BY report.schema_path, report.keyword
  LIMIT 1;
  IF schema_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet output schema is unsupported: %', schema_error;
  END IF;
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
  IF actual_source_relations IS NOT NULL
     AND jsonb_typeof(actual_source_relations) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'otlet source_relations must be a JSON array';
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
      otlet.identity_hash('decision_rule_preset', p.decision_contract)
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
    source_relations,
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
    actual_source_relations,
    create_task.instruction,
    create_task.output_schema,
    create_task.model_name,
    actual_runtime_options,
    actual_input_shaping,
    actual_decision_contract
  )
  ON CONFLICT (name) DO UPDATE
    SET (input_query, source_relations, instruction, output_schema, model_name, runtime_options, input_shaping, decision_contract) = (
      EXCLUDED.input_query,
      EXCLUDED.source_relations,
      EXCLUDED.instruction,
      EXCLUDED.output_schema,
      EXCLUDED.model_name,
      EXCLUDED.runtime_options,
      EXCLUDED.input_shaping,
      EXCLUDED.decision_contract
    )
  RETURNING * INTO saved_task;

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
  direct_task_name := 'ask_v1_' || substr(right(otlet.identity_hash(
    'direct_task',
    jsonb_build_object(
      'model_name', ask.model_name,
      'instruction', ask.instruction,
      'output_schema', actual_schema,
      'runtime_options', actual_options,
      'input_fields', (
        SELECT COALESCE(jsonb_agg(input_field ORDER BY input_field), '[]'::jsonb)
        FROM jsonb_object_keys(actual_input) input_field
      )
    )
  ), 64), 1, 24);
  direct_subject_id := 'ask_' || gen_random_uuid()::text;

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
  query_contract jsonb;
BEGIN
  IF NULLIF(btrim(preflight_candidate_query.candidate_query), '') IS NULL THEN
    RAISE EXCEPTION 'otlet candidate query is required';
  END IF;

  SELECT *
  INTO policy
  FROM otlet.production_policy
  WHERE name = 'default';

  BEGIN
    query_contract := otlet.build_source_query_contract(
      preflight_candidate_query.candidate_query
    );
    EXECUTE format(
      'EXPLAIN (FORMAT JSON) SELECT subject_id::text, input::jsonb FROM (%s) otlet_candidate',
      query_contract #>> '{query,resolved}'
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
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  CROSS JOIN otlet.production_policy p
  WHERE head.task_name = require_candidate_query_timeout.task_name
    AND revision.definition #>> '{source,kind}' = 'pair'
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

CREATE FUNCTION otlet.require_task_input_relation(input_error text) RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
  IF require_task_input_relation.input_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet %', require_task_input_relation.input_error;
  END IF;
  RETURN true;
END;
$$;

CREATE FUNCTION otlet.validated_task_input_rows(
  input_query text,
  max_rows integer DEFAULT NULL,
  active_task_name text DEFAULT NULL,
  active_workload_revision_hash text DEFAULT NULL
) RETURNS TABLE(subject_id text, input jsonb)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  candidate record;
  previous_subject text;
  previous_input jsonb;
  seen_subject boolean := false;
  returned_rows integer := 0;
BEGIN
  IF NULLIF(btrim(validated_task_input_rows.input_query), '') IS NULL THEN
    RAISE EXCEPTION 'otlet input relation query is required';
  END IF;
  IF validated_task_input_rows.max_rows IS NOT NULL
     AND validated_task_input_rows.max_rows < 1 THEN
    RAISE EXCEPTION 'otlet input relation max_rows must be positive';
  END IF;
  IF (validated_task_input_rows.active_task_name IS NULL)
     <> (validated_task_input_rows.active_workload_revision_hash IS NULL) THEN
    RAISE EXCEPTION 'otlet active input filter requires task and workload revision';
  END IF;

  FOR candidate IN EXECUTE format(
    $sql$
      SELECT
        source.subject_id::text AS subject_id,
        source.input::jsonb AS input,
        active.id AS active_job_id,
        active.input AS active_input
      FROM (%1$s) source
      LEFT JOIN otlet.jobs active
        ON %2$L IS NOT NULL
       AND active.task_name = %2$L
       AND active.workload_revision_hash = %3$L
       AND active.subject_id = source.subject_id::text
       AND active.status IN ('queued', 'running', 'cancel_requested')
      ORDER BY source.subject_id::text COLLATE "C" NULLS FIRST
    $sql$,
    validated_task_input_rows.input_query,
    validated_task_input_rows.active_task_name,
    validated_task_input_rows.active_workload_revision_hash
  ) LOOP
    IF candidate.subject_id IS NULL THEN
      RAISE EXCEPTION 'otlet input relation produced null subject_id';
    END IF;
    IF candidate.input IS NULL THEN
      RAISE EXCEPTION 'otlet input relation produced null input';
    END IF;
    IF seen_subject AND candidate.subject_id = previous_subject THEN
      IF candidate.input IS DISTINCT FROM previous_input THEN
        RAISE EXCEPTION 'otlet input relation produced conflicting inputs for subject %',
          candidate.subject_id;
      END IF;
      RAISE EXCEPTION 'otlet input relation produced duplicate subject_id %',
        candidate.subject_id;
    END IF;

    seen_subject := true;
    previous_subject := candidate.subject_id;
    previous_input := candidate.input;

    IF candidate.active_job_id IS NOT NULL THEN
      IF candidate.active_input IS DISTINCT FROM candidate.input THEN
        RAISE EXCEPTION 'otlet input relation conflicts with active input for subject %',
          candidate.subject_id;
      END IF;
    ELSIF validated_task_input_rows.max_rows IS NULL
       OR returned_rows < validated_task_input_rows.max_rows THEN
      subject_id := candidate.subject_id;
      input := candidate.input;
      RETURN NEXT;
      returned_rows := returned_rows + 1;
    END IF;
  END LOOP;
END;
$$;

CREATE FUNCTION otlet.task_subject_input(
  input_query text,
  subject_id text
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  selected_input jsonb;
BEGIN
  IF task_subject_input.subject_id IS NULL THEN
    RAISE EXCEPTION 'otlet input relation produced null subject_id';
  END IF;

  SELECT candidate.input
  INTO selected_input
  FROM otlet.validated_task_input_rows(task_subject_input.input_query) candidate
  WHERE candidate.subject_id = task_subject_input.subject_id;

  RETURN selected_input;
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
        JOIN otlet.workload_revision_heads head
          ON head.task_name = j.task_name
         AND head.active_workload_revision_hash = j.workload_revision_hash
        JOIN otlet.workload_revisions revision
          ON revision.task_name = j.task_name
         AND revision.workload_revision_hash = j.workload_revision_hash
        WHERE j.status = 'queued'
          AND COALESCE(
            j.routed_model_name,
            revision.definition #>> '{models,direct,name}'
          ) = $1
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
  suppressed_limit_bytes bigint DEFAULT NULL,
  suppressed_workload_revision_hash text DEFAULT NULL
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
    'workload_revision_hash', suppressed_workload_revision_hash,
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
      AND e.detail ->> 'workload_revision_hash' IS NOT DISTINCT FROM
        suppressed_workload_revision_hash
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
  input jsonb,
  workload_revision_hash text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  task_model_name text;
  revision_hash text;
  existing_input jsonb;
  input_bytes bigint := octet_length(admit_task_input.input::text);
  policy otlet.production_policy%ROWTYPE;
  queued_jobs bigint;
  model_queued_bytes bigint;
  total_queued_bytes bigint;
  rejection_reason text;
  rejection_limit bigint;
BEGIN
  IF admit_task_input.subject_id IS NULL THEN
    RAISE EXCEPTION 'otlet input relation produced null subject_id';
  END IF;
  IF admit_task_input.input IS NULL THEN
    RAISE EXCEPTION 'otlet input relation produced null input';
  END IF;

  revision_hash := otlet.ensure_active_workload_revision(admit_task_input.task_name);
  IF admit_task_input.workload_revision_hash IS NOT NULL
     AND admit_task_input.workload_revision_hash IS DISTINCT FROM revision_hash THEN
    RAISE EXCEPTION 'otlet workload revision is not active for task %', admit_task_input.task_name;
  END IF;
  SELECT revision.definition #>> '{models,direct,name}'
  INTO task_model_name
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = admit_task_input.task_name
    AND revision.workload_revision_hash = revision_hash;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision does not belong to task %', admit_task_input.task_name;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));

  SELECT active.input
  INTO existing_input
  FROM otlet.jobs active
  WHERE active.task_name = admit_task_input.task_name
    AND active.workload_revision_hash = revision_hash
    AND active.subject_id = admit_task_input.subject_id
    AND active.status IN ('queued', 'running', 'cancel_requested')
  FOR UPDATE;
  IF FOUND THEN
    IF existing_input IS DISTINCT FROM admit_task_input.input THEN
      RAISE EXCEPTION 'otlet input relation conflicts with active input for subject %',
        admit_task_input.subject_id;
    END IF;
    RETURN false;
  END IF;

  SELECT *
  INTO policy
  FROM otlet.production_policy
  WHERE name = 'default';

  SELECT
    count(*) FILTER (WHERE COALESCE(
      j.routed_model_name,
      revision.definition #>> '{models,direct,name}'
    ) = task_model_name),
    COALESCE(sum(octet_length(j.input::text)) FILTER (
      WHERE COALESCE(
        j.routed_model_name,
        revision.definition #>> '{models,direct,name}'
      ) = task_model_name
    ), 0),
    COALESCE(sum(octet_length(j.input::text)), 0)
  INTO queued_jobs, model_queued_bytes, total_queued_bytes
  FROM otlet.jobs j
  JOIN otlet.workload_revision_heads head
    ON head.task_name = j.task_name
   AND head.active_workload_revision_hash = j.workload_revision_hash
  JOIN otlet.workload_revisions revision
    ON revision.task_name = j.task_name
   AND revision.workload_revision_hash = j.workload_revision_hash
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
      rejection_limit,
      revision_hash
    );
    RETURN false;
  END IF;

  INSERT INTO otlet.jobs (task_name, workload_revision_hash, subject_id, input)
  VALUES (
    admit_task_input.task_name,
    revision_hash,
    admit_task_input.subject_id,
    admit_task_input.input
  );

  RETURN true;
END;
$$;

CREATE FUNCTION otlet.enqueue_ask(
  model_name text,
  instruction text,
  input jsonb DEFAULT '{}'::jsonb,
  output_schema jsonb DEFAULT '{"type":"object"}'::jsonb,
  runtime_options jsonb DEFAULT '{"max_tokens":256}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  actual_input jsonb := COALESCE(enqueue_ask.input, '{}'::jsonb);
  actual_schema jsonb := COALESCE(enqueue_ask.output_schema, '{"type":"object"}'::jsonb);
  actual_options jsonb := COALESCE(enqueue_ask.runtime_options, '{"max_tokens":256}'::jsonb);
  input_fields jsonb;
  direct_task_name text;
  direct_subject_id text;
  queued_job_id bigint;
BEGIN
  IF jsonb_typeof(actual_input) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet ask input must be a JSON object';
  END IF;

  SELECT COALESCE(jsonb_agg(input_field ORDER BY input_field), '[]'::jsonb)
  INTO input_fields
  FROM jsonb_object_keys(actual_input) input_field;

  direct_task_name := 'ask_v1_' || substr(right(otlet.identity_hash(
    'direct_task',
    jsonb_build_object(
      'model_name', enqueue_ask.model_name,
      'instruction', enqueue_ask.instruction,
      'output_schema', actual_schema,
      'runtime_options', actual_options,
      'input_fields', input_fields
    )
  ), 64), 1, 24);
  direct_subject_id := 'ask_' || gen_random_uuid()::text;

  PERFORM otlet.create_task(
    direct_task_name,
    NULL,
    enqueue_ask.instruction,
    actual_schema,
    enqueue_ask.model_name,
    actual_options,
    jsonb_build_object('source_fields', input_fields)
  );

  IF NOT otlet.admit_task_input(direct_task_name, direct_subject_id, actual_input) THEN
    RETURN 0;
  END IF;

  SELECT id
  INTO queued_job_id
  FROM otlet.jobs
  WHERE task_name = direct_task_name
    AND subject_id = direct_subject_id
    AND status = 'queued';

  IF queued_job_id IS NULL THEN
    RAISE EXCEPTION 'otlet queued ask is missing after admission';
  END IF;

  PERFORM otlet.wake_worker();
  RETURN queued_job_id;
END;
$$;

COMMENT ON FUNCTION otlet.enqueue_ask(text, text, jsonb, jsonb, jsonb) IS
  'Queues one-off inference and returns its job ID, or zero when queue admission rejects it';

CREATE FUNCTION otlet.run_task(task_name text) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  task_model_name text;
  revision_hash text;
  source_kind text;
  semantic_join_index_name text;
  queue_slots integer;
  queued bigint := 0;
  candidate_rows bigint;
  candidate_bytes bigint;
  largest_input_bytes bigint;
  rejection_reason text;
  rejection_limit bigint;
BEGIN
  revision_hash := otlet.ensure_active_workload_revision(run_task.task_name);
  SELECT
    revision.definition #>> '{task,input_query}',
    revision.definition #>> '{models,direct,name}',
    revision.definition #>> '{source,kind}',
    revision.definition #>> '{source,semantic_join_index_name}'
  INTO query, task_model_name, source_kind, semantic_join_index_name
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = run_task.task_name
    AND revision.workload_revision_hash = revision_hash;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', task_name;
  END IF;

  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', task_name;
  END IF;
  IF source_kind = 'pair' THEN
    query := format(
      'SELECT subject_id, input FROM otlet.semantic_join_refresh_inputs(%L, %L)',
      semantic_join_index_name,
      revision_hash
    );
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
         count(*) FILTER (
           WHERE COALESCE(
             j.routed_model_name,
             queued_revisions.definition #>> ''{models,direct,name}''
           ) = %1$L
         )::bigint AS model_queued_jobs,
         COALESCE(sum(octet_length(j.input::text)) FILTER (
           WHERE COALESCE(
             j.routed_model_name,
             queued_revisions.definition #>> ''{models,direct,name}''
           ) = %1$L
         ), 0)::bigint AS model_queued_bytes,
         COALESCE(sum(octet_length(j.input::text)), 0)::bigint AS total_queued_bytes
       FROM otlet.jobs j
       JOIN otlet.workload_revision_heads queued_heads
         ON queued_heads.task_name = j.task_name
        AND queued_heads.active_workload_revision_hash = j.workload_revision_hash
       JOIN otlet.workload_revisions queued_revisions
         ON queued_revisions.task_name = j.task_name
        AND queued_revisions.workload_revision_hash = j.workload_revision_hash
       WHERE j.status = ''queued''
     ),
     bounded_input AS MATERIALIZED (
       SELECT
         otlet_input.subject_id,
         otlet_input.input,
         octet_length(otlet_input.input::text)::bigint AS input_bytes
       FROM otlet.validated_task_input_rows(
         %2$L,
         (SELECT max_admission_rows + 1 FROM policy),
         %3$L,
         %4$L
       ) otlet_input
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
       INSERT INTO otlet.jobs (task_name, workload_revision_hash, subject_id, input)
       SELECT %3$L, %4$L, pending.subject_id, pending.input
       FROM bounded_input pending
       CROSS JOIN decision d
       WHERE d.rejection_reason IS NULL
       ORDER BY pending.subject_id COLLATE "C"
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
    task_name,
    revision_hash
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
      suppressed_limit_bytes => rejection_limit,
      suppressed_workload_revision_hash => revision_hash
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
  'Queues all current bounded task source rows or none. Completed subjects are eligible for a new job on direct rerun; live subjects in the active workload revision are not duplicated.';

CREATE FUNCTION otlet.run_task_subject(
  task_name text,
  subject_id text,
  expected_workload_revision_hash text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  revision_hash text;
  source_kind text;
  semantic_join_index_name text;
  pending_input jsonb;
  queued boolean;
BEGIN
  revision_hash := otlet.ensure_active_workload_revision(run_task_subject.task_name);
  IF run_task_subject.expected_workload_revision_hash IS NOT NULL
     AND run_task_subject.expected_workload_revision_hash IS DISTINCT FROM revision_hash THEN
    RAISE EXCEPTION 'otlet workload revision changed during subject admission for task %', run_task_subject.task_name;
  END IF;
  SELECT
    revision.definition #>> '{task,input_query}',
    revision.definition #>> '{source,kind}',
    revision.definition #>> '{source,semantic_join_index_name}'
  INTO query, source_kind, semantic_join_index_name
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = run_task_subject.task_name
    AND revision.workload_revision_hash = revision_hash;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', run_task_subject.task_name;
  END IF;

  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', run_task_subject.task_name;
  END IF;
  IF source_kind = 'pair' THEN
    query := format(
      'SELECT subject_id, input FROM otlet.semantic_join_refresh_inputs(%L, %L)',
      semantic_join_index_name,
      revision_hash
    );
  END IF;

  PERFORM otlet.require_candidate_query_timeout(run_task_subject.task_name);
  pending_input := otlet.task_subject_input(
    query,
    run_task_subject.subject_id
  );

  IF pending_input IS NULL THEN
    RETURN 0;
  END IF;

  queued := otlet.admit_task_input(
    run_task_subject.task_name,
    run_task_subject.subject_id,
    pending_input,
    revision_hash
  );
  IF queued THEN
    PERFORM otlet.wake_worker();
  END IF;

  RETURN queued::integer;
END;
$$;

CREATE FUNCTION otlet.run_task_subjects(
  task_name text,
  subject_ids text[],
  expected_workload_revision_hash text DEFAULT NULL
) RETURNS TABLE(subject_id text, queued boolean)
LANGUAGE plpgsql
AS $$
BEGIN
  IF cardinality(run_task_subjects.subject_ids) > 64 THEN
    RAISE EXCEPTION 'otlet.run_task_subjects accepts at most 64 subjects';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM unnest(COALESCE(run_task_subjects.subject_ids, ARRAY[]::text[])) requested(subject_id)
    WHERE requested.subject_id IS NULL
  ) THEN
    RAISE EXCEPTION 'otlet input relation produced null subject_id';
  END IF;
  IF cardinality(COALESCE(run_task_subjects.subject_ids, ARRAY[]::text[])) IS DISTINCT FROM (
    SELECT count(DISTINCT requested.subject_id)
    FROM unnest(COALESCE(run_task_subjects.subject_ids, ARRAY[]::text[])) requested(subject_id)
  ) THEN
    RAISE EXCEPTION 'otlet input relation produced duplicate requested subject_id';
  END IF;

  RETURN QUERY
  SELECT requested.subject_id,
         otlet.run_task_subject(
           run_task_subjects.task_name,
           requested.subject_id,
           run_task_subjects.expected_workload_revision_hash
         ) > 0
  FROM unnest(COALESCE(run_task_subjects.subject_ids, ARRAY[]::text[])) WITH ORDINALITY
    AS requested(subject_id, ordinal)
  ORDER BY requested.ordinal;
END;
$$;

COMMENT ON FUNCTION otlet.run_task_subjects(text, text[], text) IS
  'Queues a bounded subject array in order through the existing per-subject task and admission contract';
