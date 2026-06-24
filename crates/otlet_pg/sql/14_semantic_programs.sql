CREATE FUNCTION otlet.compile_semantic_expected(
  predicate_text text
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
  normalized text := lower(btrim(predicate_text));
  parts text[];
  field_name text;
  field_value text;
BEGIN
  IF normalized IN ('needs review', 'needs_review') THEN
    RETURN jsonb_build_object('status', 'needs_review');
  END IF;

  parts := regexp_match(
    normalized,
    '^([a-z_][a-z0-9_]*)[[:space:]]*(=|is|equals)[[:space:]]*''?([a-z0-9_ -]+)''?$'
  );

  IF parts IS NULL THEN
    RAISE EXCEPTION 'otlet cannot compile semantic predicate %, provide expected jsonb explicitly', predicate_text;
  END IF;

  field_name := parts[1];
  field_value := replace(btrim(parts[3]), ' ', '_');

  IF field_value IN ('true', 'false') THEN
    RETURN jsonb_build_object(field_name, field_value::boolean);
  END IF;

  RETURN jsonb_build_object(field_name, field_value);
END;
$$;

CREATE FUNCTION otlet.compile_semantic_program(
  program_name text,
  index_name text,
  predicate_text text,
  expected jsonb DEFAULT NULL
) RETURNS otlet.semantic_programs
LANGUAGE plpgsql
AS $$
DECLARE
  compiled_expected jsonb := COALESCE(expected, otlet.compile_semantic_expected(predicate_text));
  saved otlet.semantic_programs%ROWTYPE;
  compiler_version text := 'otlet_semantic_program_v1';
BEGIN
  IF program_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet semantic program name % must be a simple identifier', program_name;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM otlet.semantic_indexes si WHERE si.name = compile_semantic_program.index_name) THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', compile_semantic_program.index_name;
  END IF;

  IF jsonb_typeof(compiled_expected) <> 'object' THEN
    RAISE EXCEPTION 'otlet semantic program expected output must be a JSON object';
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
    program_name,
    index_name,
    predicate_text,
    compiled_expected,
    compiler_version,
    md5(index_name || chr(31) || predicate_text || chr(31) || compiled_expected::text || chr(31) || compiler_version),
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

CREATE FUNCTION otlet.compile_semantic_program_auto(
  index_name text,
  predicate_text text,
  expected jsonb DEFAULT NULL
) RETURNS otlet.semantic_programs
LANGUAGE plpgsql
AS $$
DECLARE
  compiled_expected jsonb := COALESCE(expected, otlet.compile_semantic_expected(predicate_text));
  compiler_version text := 'otlet_semantic_program_v1';
  computed_hash text;
  saved otlet.semantic_programs%ROWTYPE;
BEGIN
  computed_hash := md5(index_name || chr(31) || predicate_text || chr(31) || compiled_expected::text || chr(31) || compiler_version);

  SELECT *
  INTO saved
  FROM otlet.semantic_programs sp
  WHERE sp.index_name = compile_semantic_program_auto.index_name
    AND sp.program_hash = computed_hash
  LIMIT 1;

  IF FOUND THEN
    RETURN saved;
  END IF;

  RETURN otlet.compile_semantic_program(
    'semantic_auto_' || substr(computed_hash, 1, 24),
    index_name,
    predicate_text,
    compiled_expected
  );
END;
$$;

CREATE FUNCTION otlet.compile_semantic_join_program(
  program_name text,
  index_name text,
  predicate_text text,
  expected jsonb DEFAULT NULL
) RETURNS otlet.semantic_join_programs
LANGUAGE plpgsql
AS $$
DECLARE
  compiled_expected jsonb := COALESCE(expected, otlet.compile_semantic_expected(predicate_text));
  saved otlet.semantic_join_programs%ROWTYPE;
  compiler_version text := 'otlet_semantic_join_program_v1';
BEGIN
  IF program_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet semantic join program name % must be a simple identifier', program_name;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM otlet.semantic_join_indexes sji WHERE sji.name = compile_semantic_join_program.index_name) THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', compile_semantic_join_program.index_name;
  END IF;

  IF jsonb_typeof(compiled_expected) <> 'object' THEN
    RAISE EXCEPTION 'otlet semantic join program expected output must be a JSON object';
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
    program_name,
    index_name,
    predicate_text,
    compiled_expected,
    compiler_version,
    md5(index_name || chr(31) || predicate_text || chr(31) || compiled_expected::text || chr(31) || compiler_version),
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

CREATE FUNCTION otlet.compile_semantic_join_program_auto(
  index_name text,
  predicate_text text,
  expected jsonb DEFAULT NULL
) RETURNS otlet.semantic_join_programs
LANGUAGE plpgsql
AS $$
DECLARE
  compiled_expected jsonb := COALESCE(expected, otlet.compile_semantic_expected(predicate_text));
  compiler_version text := 'otlet_semantic_join_program_v1';
  computed_hash text;
  saved otlet.semantic_join_programs%ROWTYPE;
BEGIN
  computed_hash := md5(index_name || chr(31) || predicate_text || chr(31) || compiled_expected::text || chr(31) || compiler_version);

  SELECT *
  INTO saved
  FROM otlet.semantic_join_programs sp
  WHERE sp.index_name = compile_semantic_join_program_auto.index_name
    AND sp.program_hash = computed_hash
  LIMIT 1;

  IF FOUND THEN
    RETURN saved;
  END IF;

  RETURN otlet.compile_semantic_join_program(
    'semantic_join_auto_' || substr(computed_hash, 1, 24),
    index_name,
    predicate_text,
    compiled_expected
  );
END;
$$;

CREATE FUNCTION otlet.compile_semantic_action_expected(
  action_type text,
  record_type text,
  predicate_text text
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
  normalized text := lower(btrim(predicate_text));
  parts text[];
  field_name text;
  field_value text;
BEGIN
  IF action_type <> 'create_record' THEN
    RAISE EXCEPTION 'otlet cannot compile semantic action type %, provide expected jsonb explicitly', action_type;
  END IF;

  IF normalized IN ('indexed row', 'semantic indexed row', 'semantic is indexed row', 'record semantic is indexed row') THEN
    RETURN jsonb_build_object(
      'record_type', record_type,
      'body', jsonb_build_object('semantic', 'indexed row')
    );
  END IF;

  parts := regexp_match(
    normalized,
    '^([a-z_][a-z0-9_]*)[[:space:]]*(=|is|equals)[[:space:]]*''?([a-z0-9_ -]+)''?$'
  );

  IF parts IS NULL THEN
    RAISE EXCEPTION 'otlet cannot compile semantic action predicate %, provide expected jsonb explicitly', predicate_text;
  END IF;

  field_name := parts[1];
  field_value := btrim(parts[3]);

  IF field_value IN ('true', 'false') THEN
    RETURN jsonb_build_object(
      'record_type', record_type,
      'body', jsonb_build_object(field_name, field_value::boolean)
    );
  END IF;

  RETURN jsonb_build_object(
    'record_type', record_type,
    'body', jsonb_build_object(
      field_name,
      CASE
        WHEN field_name = 'semantic' THEN field_value
        ELSE replace(field_value, ' ', '_')
      END
    )
  );
END;
$$;

CREATE FUNCTION otlet.compile_semantic_action_program(
  program_name text,
  index_name text,
  action_type text,
  predicate_text text,
  expected jsonb DEFAULT NULL
) RETURNS otlet.semantic_action_programs
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  compiled_expected jsonb;
  saved otlet.semantic_action_programs%ROWTYPE;
  compiler_version text := 'otlet_semantic_action_program_v1';
BEGIN
  IF program_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet semantic action program name % must be a simple identifier', program_name;
  END IF;

  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes si
  WHERE si.name = compile_semantic_action_program.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', compile_semantic_action_program.index_name;
  END IF;

  compiled_expected := COALESCE(
    expected,
    otlet.compile_semantic_action_expected(action_type, index_row.record_type, predicate_text)
  );

  IF jsonb_typeof(compiled_expected) <> 'object' THEN
    RAISE EXCEPTION 'otlet semantic action program expected payload must be a JSON object';
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
    program_name,
    index_name,
    action_type,
    predicate_text,
    compiled_expected,
    compiler_version,
    md5(index_name || chr(31) || action_type || chr(31) || predicate_text || chr(31) || compiled_expected::text || chr(31) || compiler_version),
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

CREATE FUNCTION otlet.compile_semantic_action_program_auto(
  index_name text,
  action_type text,
  predicate_text text,
  expected jsonb DEFAULT NULL
) RETURNS otlet.semantic_action_programs
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  compiled_expected jsonb;
  compiler_version text := 'otlet_semantic_action_program_v1';
  computed_hash text;
  saved otlet.semantic_action_programs%ROWTYPE;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes si
  WHERE si.name = compile_semantic_action_program_auto.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', compile_semantic_action_program_auto.index_name;
  END IF;

  compiled_expected := COALESCE(
    expected,
    otlet.compile_semantic_action_expected(action_type, index_row.record_type, predicate_text)
  );
  computed_hash := md5(index_name || chr(31) || action_type || chr(31) || predicate_text || chr(31) || compiled_expected::text || chr(31) || compiler_version);

  SELECT *
  INTO saved
  FROM otlet.semantic_action_programs sp
  WHERE sp.index_name = compile_semantic_action_program_auto.index_name
    AND sp.action_type = compile_semantic_action_program_auto.action_type
    AND sp.program_hash = computed_hash
  LIMIT 1;

  IF FOUND THEN
    RETURN saved;
  END IF;

  RETURN otlet.compile_semantic_action_program(
    'semantic_action_auto_' || substr(computed_hash, 1, 24),
    index_name,
    action_type,
    predicate_text,
    compiled_expected
  );
END;
$$;
