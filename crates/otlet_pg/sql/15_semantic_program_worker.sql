CREATE FUNCTION otlet.semantic_program_model_compiler_schema(
  compiler_kind text,
  action_type text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  match_kind text;
  target_name text;
  match_shape jsonb;
BEGIN
  IF compiler_kind = 'row' THEN
    match_kind := 'row_match';
    target_name := 'output';
    match_shape := jsonb_build_object(
      'type', 'object',
      'required', jsonb_build_array('kind', 'target', 'field', 'operator', 'value'),
      'properties', jsonb_build_object(
        'kind', jsonb_build_object('const', match_kind),
        'target', jsonb_build_object('const', target_name),
        'field', jsonb_build_object('type', 'string', 'pattern', '^[a-z_][a-z0-9_]*$'),
        'operator', jsonb_build_object('const', 'equals'),
        'value', jsonb_build_object('type', jsonb_build_array('string', 'boolean', 'number', 'integer')),
        'expected', jsonb_build_object('type', 'object')
      ),
      'additionalProperties', false
    );
  ELSIF compiler_kind = 'join' THEN
    match_kind := 'join_match';
    target_name := 'join_output';
    match_shape := jsonb_build_object(
      'type', 'object',
      'required', jsonb_build_array('kind', 'target', 'field', 'operator', 'value'),
      'properties', jsonb_build_object(
        'kind', jsonb_build_object('const', match_kind),
        'target', jsonb_build_object('const', target_name),
        'field', jsonb_build_object('type', 'string', 'pattern', '^[a-z_][a-z0-9_]*$'),
        'operator', jsonb_build_object('const', 'equals'),
        'value', jsonb_build_object('type', jsonb_build_array('string', 'boolean', 'number', 'integer')),
        'expected', jsonb_build_object('type', 'object')
      ),
      'additionalProperties', false
    );
  ELSIF compiler_kind = 'action' THEN
    IF action_type IS NULL THEN
      RAISE EXCEPTION 'otlet action compiler schema requires action_type';
    END IF;
    match_shape := jsonb_build_object(
      'type', 'object',
      'required', jsonb_build_array('kind', 'target', 'action_type', 'field_path', 'operator', 'value'),
      'properties', jsonb_build_object(
        'kind', jsonb_build_object('const', 'action_match'),
        'target', jsonb_build_object('const', 'action.payload'),
        'action_type', jsonb_build_object('const', action_type),
        'field_path', jsonb_build_object(
          'type', 'array',
          'minItems', 2,
          'maxItems', 2,
          'items', jsonb_build_object('type', 'string')
        ),
        'operator', jsonb_build_object('const', 'equals'),
        'value', jsonb_build_object('type', jsonb_build_array('string', 'boolean', 'number', 'integer')),
        'expected', jsonb_build_object('type', 'object')
      ),
      'additionalProperties', false
    );
  ELSE
    RAISE EXCEPTION 'otlet unknown semantic program compiler kind %', compiler_kind;
  END IF;

  RETURN jsonb_build_object(
    'oneOf',
    jsonb_build_array(
      match_shape,
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array('kind', 'reason'),
        'properties', jsonb_build_object(
          'kind', jsonb_build_object('const', 'unsupported'),
          'reason', jsonb_build_object('type', 'string')
        ),
        'additionalProperties', false
      )
    )
  );
END;
$$;

CREATE FUNCTION otlet.semantic_program_model_compiler_instruction(
  compiler_kind text,
  action_type text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF compiler_kind = 'row' THEN
    RETURN 'Compile the predicate_text into one narrow Otlet row semantic AST. Return output.kind=row_match only for a single exact equality over the model output object. Use target=output, operator=equals, field, value, and expected. If the text is broad, subjective, multi-field, unsafe, or not a direct equality predicate, return output.kind=unsupported with a short reason. Do not invent facts. Do not run inference over source rows.';
  ELSIF compiler_kind = 'join' THEN
    RETURN 'Compile the predicate_text into one narrow Otlet join semantic AST. Return output.kind=join_match only for a single exact equality over a materialized join output object. Use target=join_output, operator=equals, field, value, and expected. If the text is broad, subjective, multi-field, unsafe, or not a direct equality predicate, return output.kind=unsupported with a short reason. Do not invent facts. Do not run inference over candidate rows.';
  ELSIF compiler_kind = 'action' THEN
    RETURN format('Compile the predicate_text into one narrow Otlet action semantic AST for action_type=%s. Return output.kind=action_match only for a single exact equality over action.payload.body. Use target=action.payload, action_type=%s, field_path=["body","field"], operator=equals, value, and expected. If the text is broad, subjective, multi-field, unsafe, or not a direct equality predicate, return output.kind=unsupported with a short reason. Do not invent facts. Do not run inference over source rows.', action_type, action_type);
  END IF;

  RAISE EXCEPTION 'otlet unknown semantic program compiler kind %', compiler_kind;
END;
$$;

CREATE FUNCTION otlet.compile_semantic_program_model_async(
  compiler_kind text,
  program_name text,
  index_name text,
  action_type text,
  predicate_text text,
  runtime_options jsonb DEFAULT '{}'::jsonb
) RETURNS otlet.jobs
LANGUAGE plpgsql
AS $$
DECLARE
  model_name text;
  record_type text;
  compiler_task_name text;
  deterministic_supported boolean := false;
  saved_job otlet.jobs%ROWTYPE;
BEGIN
  IF compiler_kind NOT IN ('row', 'join', 'action') THEN
    RAISE EXCEPTION 'otlet unknown semantic program compiler kind %', compiler_kind;
  END IF;

  IF program_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet semantic program name % must be a simple identifier', program_name;
  END IF;

  IF compiler_kind = 'join' THEN
    SELECT sji.model_name, sji.record_type
    INTO model_name, record_type
    FROM otlet.semantic_join_indexes sji
    WHERE sji.name = compile_semantic_program_model_async.index_name;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'otlet semantic join index % does not exist', index_name;
    END IF;
  ELSE
    SELECT si.model_name, si.record_type
    INTO model_name, record_type
    FROM otlet.semantic_indexes si
    WHERE si.name = compile_semantic_program_model_async.index_name;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'otlet semantic index % does not exist', index_name;
    END IF;
  END IF;

  BEGIN
    IF compiler_kind = 'action' THEN
      PERFORM otlet.compile_semantic_action_expected(action_type, record_type, predicate_text);
    ELSE
      PERFORM otlet.compile_semantic_expected(predicate_text);
    END IF;
    deterministic_supported := true;
  EXCEPTION WHEN OTHERS THEN
    IF (compiler_kind = 'action' AND SQLERRM NOT LIKE 'otlet cannot compile semantic action%')
       OR (compiler_kind <> 'action' AND SQLERRM NOT LIKE 'otlet cannot compile semantic predicate%') THEN
      RAISE;
    END IF;
  END;

  IF deterministic_supported THEN
    RAISE EXCEPTION 'otlet deterministic compiler already supports %, use the deterministic compiler', predicate_text;
  END IF;

  compiler_task_name := 'otlet_spc_' || compiler_kind || '_' || substr(md5(model_name), 1, 12);
  PERFORM otlet.register_task(
    compiler_task_name,
    otlet.semantic_program_model_compiler_instruction(compiler_kind, action_type),
    otlet.semantic_program_model_compiler_schema(compiler_kind, action_type),
    model_name,
    jsonb_build_object('reasoning', 'off', 'max_tokens', 128, 'inference_cache', false) ||
      COALESCE(runtime_options, '{}'::jsonb)
  );

  SELECT * INTO saved_job
  FROM otlet.infer_async(
    compiler_task_name,
    program_name,
    jsonb_strip_nulls(jsonb_build_object(
      'compiler_kind', compiler_kind,
      'program_name', program_name,
      'index_name', compile_semantic_program_model_async.index_name,
      'action_type', action_type,
      'predicate_text', predicate_text,
      'record_type', record_type,
      'semantic_program_contract', 'compile_once_store_ast_execute_materialized_state'
    ))
  );

  RETURN saved_job;
END;
$$;

CREATE FUNCTION otlet.compile_semantic_program_model_async(
  program_name text,
  index_name text,
  predicate_text text,
  runtime_options jsonb DEFAULT '{}'::jsonb
) RETURNS otlet.jobs
LANGUAGE sql
AS $$
  SELECT otlet.compile_semantic_program_model_async('row', $1, $2, NULL::text, $3, $4);
$$;

CREATE FUNCTION otlet.apply_semantic_program_model_compile(
  job_id bigint,
  program_name text DEFAULT NULL
) RETURNS otlet.semantic_programs
LANGUAGE plpgsql
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  output_json jsonb;
  saved otlet.semantic_programs%ROWTYPE;
  expected_json jsonb;
  field_name text;
  task_output_schema jsonb;
  compiler_version text := 'otlet_semantic_program_model_v1';
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = apply_semantic_program_model_compile.job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic program compiler job % does not exist', job_id;
  END IF;

  IF job_row.input ->> 'compiler_kind' <> 'row' THEN
    RAISE EXCEPTION 'otlet compiler job % is not a row semantic program compiler job', job_id;
  END IF;

  IF program_name IS NOT NULL AND program_name <> job_row.subject_id THEN
    RAISE EXCEPTION 'otlet compiler job % subject % does not match requested program %', job_id, job_row.subject_id, program_name;
  END IF;

  IF job_row.status <> 'complete' THEN
    RAISE EXCEPTION 'otlet compiler job % is %, expected complete', job_id, job_row.status;
  END IF;

  SELECT o.output INTO output_json
  FROM otlet.outputs o
  WHERE o.job_id = apply_semantic_program_model_compile.job_id
  ORDER BY o.id DESC
  LIMIT 1;

  IF output_json IS NULL THEN
    RAISE EXCEPTION 'otlet compiler job % has no output row', job_id;
  END IF;

  IF output_json ->> 'kind' = 'unsupported' THEN
    RAISE EXCEPTION 'otlet model compiler rejected semantic predicate: %', COALESCE(output_json ->> 'reason', 'unsupported');
  END IF;

  IF output_json ->> 'kind' <> 'row_match'
     OR output_json ->> 'target' <> 'output'
     OR output_json ->> 'operator' <> 'equals' THEN
    RAISE EXCEPTION 'otlet compiler job % returned invalid row AST %', job_id, output_json;
  END IF;

  field_name := output_json ->> 'field';
  IF field_name !~ '^[a-z_][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'otlet compiler job % returned invalid field %', job_id, field_name;
  END IF;

  SELECT t.output_schema INTO task_output_schema
  FROM otlet.semantic_indexes si
  JOIN otlet.tasks t ON t.name = si.task_name
  WHERE si.name = job_row.input ->> 'index_name';

  IF jsonb_typeof(task_output_schema -> 'properties') = 'object'
     AND NOT (task_output_schema -> 'properties' ? field_name) THEN
    RAISE EXCEPTION 'otlet compiler job % returned output field % not declared by task schema', job_id, field_name;
  END IF;

  expected_json := COALESCE(output_json -> 'expected', jsonb_build_object(field_name, output_json -> 'value'));
  IF jsonb_typeof(expected_json) <> 'object' THEN
    RAISE EXCEPTION 'otlet compiler job % expected value must be an object', job_id;
  END IF;

  INSERT INTO otlet.semantic_programs (
    name,
    index_name,
    predicate,
    expected,
    compiler_version,
    program_hash,
    updated_at
  )
  VALUES (
    job_row.subject_id,
    job_row.input ->> 'index_name',
    job_row.input ->> 'predicate_text',
    expected_json,
    compiler_version,
    md5((job_row.input ->> 'index_name') || chr(31) || (job_row.input ->> 'predicate_text') || chr(31) || expected_json::text || chr(31) || compiler_version),
    now()
  )
  ON CONFLICT (name) DO UPDATE
    SET index_name = EXCLUDED.index_name,
        predicate = EXCLUDED.predicate,
        expected = EXCLUDED.expected,
        compiler_version = EXCLUDED.compiler_version,
        program_hash = EXCLUDED.program_hash,
        updated_at = now()
  RETURNING * INTO saved;

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.compile_semantic_join_program_model_async(
  program_name text,
  index_name text,
  predicate_text text,
  runtime_options jsonb DEFAULT '{}'::jsonb
) RETURNS otlet.jobs
LANGUAGE sql
AS $$
  SELECT otlet.compile_semantic_program_model_async('join', $1, $2, NULL::text, $3, $4);
$$;

CREATE FUNCTION otlet.apply_semantic_join_program_model_compile(
  job_id bigint,
  program_name text DEFAULT NULL
) RETURNS otlet.semantic_join_programs
LANGUAGE plpgsql
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  output_json jsonb;
  saved otlet.semantic_join_programs%ROWTYPE;
  expected_json jsonb;
  field_name text;
  task_output_schema jsonb;
  compiler_version text := 'otlet_semantic_join_program_model_v1';
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = apply_semantic_join_program_model_compile.job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join compiler job % does not exist', job_id;
  END IF;

  IF job_row.input ->> 'compiler_kind' <> 'join' THEN
    RAISE EXCEPTION 'otlet compiler job % is not a join semantic program compiler job', job_id;
  END IF;

  IF program_name IS NOT NULL AND program_name <> job_row.subject_id THEN
    RAISE EXCEPTION 'otlet compiler job % subject % does not match requested program %', job_id, job_row.subject_id, program_name;
  END IF;

  IF job_row.status <> 'complete' THEN
    RAISE EXCEPTION 'otlet compiler job % is %, expected complete', job_id, job_row.status;
  END IF;

  SELECT o.output INTO output_json
  FROM otlet.outputs o
  WHERE o.job_id = apply_semantic_join_program_model_compile.job_id
  ORDER BY o.id DESC
  LIMIT 1;

  IF output_json IS NULL THEN
    RAISE EXCEPTION 'otlet compiler job % has no output row', job_id;
  END IF;

  IF output_json ->> 'kind' = 'unsupported' THEN
    RAISE EXCEPTION 'otlet model compiler rejected semantic join predicate: %', COALESCE(output_json ->> 'reason', 'unsupported');
  END IF;

  IF output_json ->> 'kind' <> 'join_match'
     OR output_json ->> 'target' <> 'join_output'
     OR output_json ->> 'operator' <> 'equals' THEN
    RAISE EXCEPTION 'otlet compiler job % returned invalid join AST %', job_id, output_json;
  END IF;

  field_name := output_json ->> 'field';
  IF field_name !~ '^[a-z_][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'otlet compiler job % returned invalid field %', job_id, field_name;
  END IF;

  SELECT t.output_schema INTO task_output_schema
  FROM otlet.semantic_join_indexes sji
  JOIN otlet.tasks t ON t.name = sji.task_name
  WHERE sji.name = job_row.input ->> 'index_name';

  IF jsonb_typeof(task_output_schema -> 'properties') = 'object'
     AND NOT (task_output_schema -> 'properties' ? field_name) THEN
    RAISE EXCEPTION 'otlet compiler job % returned output field % not declared by task schema', job_id, field_name;
  END IF;

  expected_json := COALESCE(output_json -> 'expected', jsonb_build_object(field_name, output_json -> 'value'));
  IF jsonb_typeof(expected_json) <> 'object' THEN
    RAISE EXCEPTION 'otlet compiler job % expected value must be an object', job_id;
  END IF;

  INSERT INTO otlet.semantic_join_programs (
    name,
    index_name,
    predicate,
    expected,
    compiler_version,
    program_hash,
    updated_at
  )
  VALUES (
    job_row.subject_id,
    job_row.input ->> 'index_name',
    job_row.input ->> 'predicate_text',
    expected_json,
    compiler_version,
    md5((job_row.input ->> 'index_name') || chr(31) || (job_row.input ->> 'predicate_text') || chr(31) || expected_json::text || chr(31) || compiler_version),
    now()
  )
  ON CONFLICT (name) DO UPDATE
    SET index_name = EXCLUDED.index_name,
        predicate = EXCLUDED.predicate,
        expected = EXCLUDED.expected,
        compiler_version = EXCLUDED.compiler_version,
        program_hash = EXCLUDED.program_hash,
        updated_at = now()
  RETURNING * INTO saved;

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.compile_semantic_action_program_model_async(
  program_name text,
  index_name text,
  action_type text,
  predicate_text text,
  runtime_options jsonb DEFAULT '{}'::jsonb
) RETURNS otlet.jobs
LANGUAGE sql
AS $$
  SELECT otlet.compile_semantic_program_model_async('action', $1, $2, $3, $4, $5);
$$;

CREATE FUNCTION otlet.apply_semantic_action_program_model_compile(
  job_id bigint,
  program_name text DEFAULT NULL
) RETURNS otlet.semantic_action_programs
LANGUAGE plpgsql
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  index_row otlet.semantic_indexes%ROWTYPE;
  output_json jsonb;
  saved otlet.semantic_action_programs%ROWTYPE;
  expected_json jsonb;
  field_name text;
  field_path jsonb;
  compiler_version text := 'otlet_semantic_action_program_model_v1';
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = apply_semantic_action_program_model_compile.job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic action compiler job % does not exist', job_id;
  END IF;

  IF job_row.input ->> 'compiler_kind' <> 'action' THEN
    RAISE EXCEPTION 'otlet compiler job % is not an action semantic program compiler job', job_id;
  END IF;

  IF program_name IS NOT NULL AND program_name <> job_row.subject_id THEN
    RAISE EXCEPTION 'otlet compiler job % subject % does not match requested program %', job_id, job_row.subject_id, program_name;
  END IF;

  IF job_row.status <> 'complete' THEN
    RAISE EXCEPTION 'otlet compiler job % is %, expected complete', job_id, job_row.status;
  END IF;

  SELECT * INTO index_row
  FROM otlet.semantic_indexes si
  WHERE si.name = job_row.input ->> 'index_name';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', job_row.input ->> 'index_name';
  END IF;

  SELECT o.output INTO output_json
  FROM otlet.outputs o
  WHERE o.job_id = apply_semantic_action_program_model_compile.job_id
  ORDER BY o.id DESC
  LIMIT 1;

  IF output_json IS NULL THEN
    RAISE EXCEPTION 'otlet compiler job % has no output row', job_id;
  END IF;

  IF output_json ->> 'kind' = 'unsupported' THEN
    RAISE EXCEPTION 'otlet model compiler rejected semantic action predicate: %', COALESCE(output_json ->> 'reason', 'unsupported');
  END IF;

  IF output_json ->> 'kind' <> 'action_match'
     OR output_json ->> 'target' <> 'action.payload'
     OR output_json ->> 'operator' <> 'equals'
     OR output_json ->> 'action_type' <> job_row.input ->> 'action_type' THEN
    RAISE EXCEPTION 'otlet compiler job % returned invalid action AST %', job_id, output_json;
  END IF;

  field_path := output_json -> 'field_path';
  IF jsonb_typeof(field_path) <> 'array'
     OR jsonb_array_length(field_path) <> 2
     OR field_path ->> 0 <> 'body' THEN
    RAISE EXCEPTION 'otlet compiler job % returned invalid action field path %', job_id, field_path;
  END IF;

  field_name := field_path ->> 1;
  IF field_name !~ '^[a-z_][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'otlet compiler job % returned invalid action field %', job_id, field_name;
  END IF;

  expected_json := COALESCE(
    output_json -> 'expected',
    jsonb_build_object(
      'record_type', index_row.record_type,
      'body', jsonb_build_object(field_name, output_json -> 'value')
    )
  );
  IF jsonb_typeof(expected_json) <> 'object' THEN
    RAISE EXCEPTION 'otlet compiler job % expected value must be an object', job_id;
  END IF;

  INSERT INTO otlet.semantic_action_programs (
    name,
    index_name,
    action_type,
    predicate,
    expected,
    compiler_version,
    program_hash,
    updated_at
  )
  VALUES (
    job_row.subject_id,
    job_row.input ->> 'index_name',
    job_row.input ->> 'action_type',
    job_row.input ->> 'predicate_text',
    expected_json,
    compiler_version,
    md5((job_row.input ->> 'index_name') || chr(31) || (job_row.input ->> 'action_type') || chr(31) || (job_row.input ->> 'predicate_text') || chr(31) || expected_json::text || chr(31) || compiler_version),
    now()
  )
  ON CONFLICT (name) DO UPDATE
    SET index_name = EXCLUDED.index_name,
        action_type = EXCLUDED.action_type,
        predicate = EXCLUDED.predicate,
        expected = EXCLUDED.expected,
        compiler_version = EXCLUDED.compiler_version,
        program_hash = EXCLUDED.program_hash,
        updated_at = now()
  RETURNING * INTO saved;

  RETURN saved;
END;
$$;
