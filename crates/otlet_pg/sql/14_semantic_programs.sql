CREATE FUNCTION otlet.compile_semantic_program(
  program_name text,
  index_name text,
  predicate_text text,
  expected jsonb
) RETURNS otlet.semantic_programs
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.semantic_programs%ROWTYPE;
  compiler_version text := 'otlet_semantic_program_v1';
BEGIN
  IF program_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet semantic program name % must be a simple identifier', program_name;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM otlet.semantic_indexes si WHERE si.name = compile_semantic_program.index_name) THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', compile_semantic_program.index_name;
  END IF;

  IF jsonb_typeof(expected) <> 'object' THEN
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
    expected,
    compiler_version,
    md5(index_name || chr(31) || predicate_text || chr(31) || expected::text || chr(31) || compiler_version),
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

CREATE FUNCTION otlet.compile_semantic_join_program(
  program_name text,
  index_name text,
  predicate_text text,
  expected jsonb
) RETURNS otlet.semantic_join_programs
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.semantic_join_programs%ROWTYPE;
  compiler_version text := 'otlet_semantic_join_program_v1';
BEGIN
  IF program_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet semantic join program name % must be a simple identifier', program_name;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM otlet.semantic_join_indexes sji WHERE sji.name = compile_semantic_join_program.index_name) THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', compile_semantic_join_program.index_name;
  END IF;

  IF jsonb_typeof(expected) <> 'object' THEN
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
    expected,
    compiler_version,
    md5(index_name || chr(31) || predicate_text || chr(31) || expected::text || chr(31) || compiler_version),
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

CREATE FUNCTION otlet.compile_semantic_action_program(
  program_name text,
  index_name text,
  action_type text,
  predicate_text text,
  expected jsonb
) RETURNS otlet.semantic_action_programs
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.semantic_action_programs%ROWTYPE;
  compiler_version text := 'otlet_semantic_action_program_v1';
BEGIN
  IF program_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet semantic action program name % must be a simple identifier', program_name;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM otlet.semantic_indexes si WHERE si.name = compile_semantic_action_program.index_name) THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', compile_semantic_action_program.index_name;
  END IF;

  IF jsonb_typeof(expected) <> 'object' THEN
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
    expected,
    compiler_version,
    md5(index_name || chr(31) || action_type || chr(31) || predicate_text || chr(31) || expected::text || chr(31) || compiler_version),
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
