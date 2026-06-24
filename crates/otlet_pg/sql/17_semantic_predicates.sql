
CREATE FUNCTION otlet.semantic_matches(
  index_name text,
  subject_id text,
  expected jsonb,
  min_freshness numeric DEFAULT 1,
  allow_refresh boolean DEFAULT false
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
DECLARE
  index_row record;
  current_source_hash text;
BEGIN
  SELECT
    si.source_table,
    si.subject_column
  INTO index_row
  FROM otlet.semantic_indexes si
  WHERE si.name = semantic_matches.index_name;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  EXECUTE format(
    $sql$
      SELECT md5(jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', %L,
          'subject_id', (src.%I)::text,
          'ctid', src.ctid::text,
          'xmin', src.xmin::text
        ),
        'table', %L,
        'row', to_jsonb(src)
      )::text)
      FROM %s AS src
      WHERE (src.%I)::text = $1
      LIMIT 1
    $sql$,
    index_row.source_table,
    index_row.subject_column,
    index_row.source_table,
    index_row.source_table,
    index_row.subject_column
  )
  INTO current_source_hash
  USING semantic_matches.subject_id;

  IF current_source_hash IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM (
      SELECT DISTINCT ON (sm.subject_id)
        sm.subject_id,
        sm.body,
        sm.updated_at,
        sm.id
      FROM otlet.semantic_materializations sm
      JOIN otlet.semantic_indexes si
        ON si.task_name = sm.task_name
       AND si.record_type = sm.record_type
      WHERE si.name = semantic_matches.index_name
        AND sm.subject_id = semantic_matches.subject_id
        AND sm.stale = false
        AND sm.source_hash = current_source_hash
      ORDER BY sm.subject_id, sm.updated_at DESC, sm.id DESC
    ) latest
    WHERE latest.body @> semantic_matches.expected
      AND GREATEST(0, LEAST(COALESCE(semantic_matches.min_freshness, 1), 1)) = 1
      AND semantic_matches.allow_refresh IS NOT NULL
  );
END;
$$;

CREATE FUNCTION otlet.semantic_matches_auto(
  index_name text,
  subject_id text,
  expected jsonb,
  max_wait_ms integer DEFAULT 10000,
  max_infer_ms integer DEFAULT 15000,
  max_rows integer DEFAULT 1,
  allow_refresh boolean DEFAULT true
) RETURNS boolean
LANGUAGE sql
STABLE
STRICT
COST 1000
AS $$
  SELECT otlet.semantic_matches(
    semantic_matches_auto.index_name,
    semantic_matches_auto.subject_id,
    semantic_matches_auto.expected
  )
    AND GREATEST(0, LEAST(COALESCE(semantic_matches_auto.max_wait_ms, 0), 30000)) >= 0
    AND GREATEST(0, LEAST(COALESCE(semantic_matches_auto.max_infer_ms, 0), 30000)) >= 0
    AND GREATEST(0, LEAST(COALESCE(semantic_matches_auto.max_rows, 1), 10)) >= 0
    AND semantic_matches_auto.allow_refresh IS NOT NULL;
$$;

CREATE FUNCTION otlet.semantic_matches_text(
  index_name text,
  subject_id text,
  predicate_text text,
  min_freshness numeric DEFAULT 1,
  allow_refresh boolean DEFAULT false
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
BEGIN
  RETURN otlet.semantic_matches(
    semantic_matches_text.index_name,
    semantic_matches_text.subject_id,
    otlet.compile_semantic_expected(semantic_matches_text.predicate_text),
    semantic_matches_text.min_freshness,
    semantic_matches_text.allow_refresh
  );
END;
$$;

CREATE FUNCTION otlet.semantic_matches_program(
  program_name text,
  subject_id text,
  allow_refresh boolean DEFAULT false
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
DECLARE
  program_row otlet.semantic_programs%ROWTYPE;
BEGIN
  SELECT *
  INTO program_row
  FROM otlet.semantic_programs sp
  WHERE sp.name = semantic_matches_program.program_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic program % does not exist', semantic_matches_program.program_name;
  END IF;

  RETURN otlet.semantic_matches(
    program_row.index_name,
    semantic_matches_program.subject_id,
    program_row.expected,
    1,
    semantic_matches_program.allow_refresh
  );
END;
$$;

CREATE FUNCTION otlet.semantic_matches_program_auto(
  program_name text,
  subject_id text,
  max_wait_ms integer DEFAULT 10000,
  max_infer_ms integer DEFAULT 15000,
  max_rows integer DEFAULT 1,
  allow_refresh boolean DEFAULT true
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
DECLARE
  program_row otlet.semantic_programs%ROWTYPE;
BEGIN
  SELECT *
  INTO program_row
  FROM otlet.semantic_programs sp
  WHERE sp.name = semantic_matches_program_auto.program_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic program % does not exist', semantic_matches_program_auto.program_name;
  END IF;

  RETURN otlet.semantic_matches_auto(
    program_row.index_name,
    semantic_matches_program_auto.subject_id,
    program_row.expected,
    semantic_matches_program_auto.max_wait_ms,
    semantic_matches_program_auto.max_infer_ms,
    semantic_matches_program_auto.max_rows,
    semantic_matches_program_auto.allow_refresh
  );
END;
$$;

CREATE FUNCTION otlet.semantic_join_matches_program(
  program_name text,
  subject_id text,
  allow_refresh boolean DEFAULT false
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
DECLARE
  program_row otlet.semantic_join_programs%ROWTYPE;
BEGIN
  SELECT *
  INTO program_row
  FROM otlet.semantic_join_programs sp
  WHERE sp.name = semantic_join_matches_program.program_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join program % does not exist', semantic_join_matches_program.program_name;
  END IF;

  RETURN otlet.semantic_join_matches(
    program_row.index_name,
    semantic_join_matches_program.subject_id,
    program_row.expected
  ) AND semantic_join_matches_program.allow_refresh IS NOT NULL;
END;
$$;

CREATE FUNCTION otlet.semantic_join_matches_program_auto(
  program_name text,
  subject_id text,
  max_wait_ms integer DEFAULT 10000,
  max_infer_ms integer DEFAULT 15000,
  max_rows integer DEFAULT 1,
  allow_refresh boolean DEFAULT true
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
DECLARE
  program_row otlet.semantic_join_programs%ROWTYPE;
BEGIN
  SELECT *
  INTO program_row
  FROM otlet.semantic_join_programs sp
  WHERE sp.name = semantic_join_matches_program_auto.program_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join program % does not exist', semantic_join_matches_program_auto.program_name;
  END IF;

  RETURN otlet.semantic_join_matches_auto(
    program_row.index_name,
    semantic_join_matches_program_auto.subject_id,
    program_row.expected,
    semantic_join_matches_program_auto.max_wait_ms,
    semantic_join_matches_program_auto.max_infer_ms,
    semantic_join_matches_program_auto.max_rows,
    semantic_join_matches_program_auto.allow_refresh
  );
END;
$$;

CREATE TYPE otlet.semantic_ref AS (
  index_name text,
  subject_id text
);

CREATE TYPE otlet.semantic_join_ref AS (
  index_name text,
  subject_id text
);

CREATE TYPE otlet.semantic_field_ref AS (
  index_name text,
  subject_id text,
  field_name text
);

CREATE TYPE otlet.semantic_action_ref AS (
  index_name text,
  subject_id text,
  action_type text
);

CREATE FUNCTION otlet.semantic_subject(
  index_name text,
  subject_id text
) RETURNS otlet.semantic_ref
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT ROW(semantic_subject.index_name, semantic_subject.subject_id)::otlet.semantic_ref;
$$;

CREATE FUNCTION otlet.semantic_join_subject(
  index_name text,
  subject_id text
) RETURNS otlet.semantic_join_ref
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT ROW(semantic_join_subject.index_name, semantic_join_subject.subject_id)::otlet.semantic_join_ref;
$$;

CREATE FUNCTION otlet.semantic_field(
  index_name text,
  subject_id text,
  field_name text
) RETURNS otlet.semantic_field_ref
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT ROW(semantic_field.index_name, semantic_field.subject_id, semantic_field.field_name)::otlet.semantic_field_ref;
$$;

CREATE FUNCTION otlet.semantic_action(
  index_name text,
  subject_id text,
  action_type text
) RETURNS otlet.semantic_action_ref
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT ROW(semantic_action.index_name, semantic_action.subject_id, semantic_action.action_type)::otlet.semantic_action_ref;
$$;

CREATE FUNCTION otlet.semantic_ref_matches(
  semantic_ref_value otlet.semantic_ref,
  expected jsonb
) RETURNS boolean
LANGUAGE sql
STABLE
STRICT
COST 1000
AS $$
  SELECT otlet.semantic_matches(
    (semantic_ref_matches.semantic_ref_value).index_name,
    (semantic_ref_matches.semantic_ref_value).subject_id,
    semantic_ref_matches.expected
  );
$$;

CREATE FUNCTION otlet.semantic_join_ref_matches(
  semantic_join_ref_value otlet.semantic_join_ref,
  expected jsonb
) RETURNS boolean
LANGUAGE sql
STABLE
STRICT
COST 1000
AS $$
  SELECT otlet.semantic_join_matches(
    (semantic_join_ref_matches.semantic_join_ref_value).index_name,
    (semantic_join_ref_matches.semantic_join_ref_value).subject_id,
    semantic_join_ref_matches.expected
  );
$$;

CREATE FUNCTION otlet.semantic_field_matches(
  semantic_field_value otlet.semantic_field_ref,
  expected text
) RETURNS boolean
LANGUAGE sql
STABLE
STRICT
COST 1000
AS $$
  SELECT otlet.semantic_matches(
    (semantic_field_matches.semantic_field_value).index_name,
    (semantic_field_matches.semantic_field_value).subject_id,
    jsonb_build_object((semantic_field_matches.semantic_field_value).field_name, semantic_field_matches.expected)
  );
$$;

CREATE FUNCTION otlet.semantic_field_bool_matches(
  semantic_field_value otlet.semantic_field_ref,
  expected boolean
) RETURNS boolean
LANGUAGE sql
STABLE
STRICT
COST 1000
AS $$
  SELECT otlet.semantic_matches(
    (semantic_field_bool_matches.semantic_field_value).index_name,
    (semantic_field_bool_matches.semantic_field_value).subject_id,
    jsonb_build_object((semantic_field_bool_matches.semantic_field_value).field_name, semantic_field_bool_matches.expected)
  );
$$;

CREATE FUNCTION otlet.semantic_action_matches(
  index_name text,
  subject_id text,
  action_type text,
  expected jsonb
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  matched boolean;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes
  WHERE name = semantic_action_matches.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', semantic_action_matches.index_name;
  END IF;

  EXECUTE format(
    $sql$
      WITH current_input AS (
        SELECT
          (src.%1$I)::text AS subject_id,
          md5(jsonb_build_object(
            '_otlet_mvcc', jsonb_build_object(
              'table', %2$L,
              'subject_id', (src.%1$I)::text,
              'ctid', src.ctid::text,
              'xmin', src.xmin::text
            ),
            'table', %2$L,
            'row', to_jsonb(src)
          )::text) AS source_hash
        FROM %3$s AS src
        WHERE (src.%1$I)::text = $1
        LIMIT 1
      ),
      latest AS (
        SELECT DISTINCT ON (sm.subject_id)
          sm.subject_id,
          sm.stale,
          sm.source_hash,
          sm.record_id,
          sm.updated_at,
          sm.id
        FROM otlet.semantic_materializations sm
        WHERE sm.task_name = %4$L
          AND sm.record_type = %5$L
          AND sm.subject_id = $1
        ORDER BY sm.subject_id, sm.updated_at DESC, sm.id DESC
      )
      SELECT EXISTS (
        SELECT 1
        FROM current_input ci
        JOIN latest l
          ON l.subject_id = ci.subject_id
         AND l.stale = false
         AND l.source_hash = ci.source_hash
        JOIN otlet.records r
          ON r.id = l.record_id
        JOIN otlet.actions a
          ON a.id = r.action_id
        JOIN otlet.jobs j
          ON j.id = a.job_id
        WHERE j.task_name = %4$L
          AND j.subject_id = ci.subject_id
          AND a.action_type = $2
          AND a.status = 'complete'
          AND a.payload @> $3
      ) AS matched
    $sql$,
    index_row.subject_column,
    index_row.source_table,
    index_row.source_table,
    index_row.task_name,
    index_row.record_type
  )
  INTO matched
  USING semantic_action_matches.subject_id,
        semantic_action_matches.action_type,
        semantic_action_matches.expected;

  RETURN COALESCE(matched, false);
END;
$$;

CREATE FUNCTION otlet.semantic_action_matches_auto(
  index_name text,
  subject_id text,
  action_type text,
  expected jsonb,
  max_wait_ms int DEFAULT 10000,
  max_infer_ms int DEFAULT 15000,
  max_rows int DEFAULT 1,
  allow_refresh boolean DEFAULT true
) RETURNS boolean
LANGUAGE sql
STABLE
STRICT
COST 1000
AS $$
  SELECT otlet.semantic_action_matches(
    semantic_action_matches_auto.index_name,
    semantic_action_matches_auto.subject_id,
    semantic_action_matches_auto.action_type,
    semantic_action_matches_auto.expected
  );
$$;

CREATE FUNCTION otlet.semantic_action_matches_text(
  index_name text,
  subject_id text,
  action_type text,
  predicate_text text,
  allow_refresh boolean DEFAULT false
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes si
  WHERE si.name = semantic_action_matches_text.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', semantic_action_matches_text.index_name;
  END IF;

  RETURN otlet.semantic_action_matches(
    semantic_action_matches_text.index_name,
    semantic_action_matches_text.subject_id,
    semantic_action_matches_text.action_type,
    otlet.compile_semantic_action_expected(
      semantic_action_matches_text.action_type,
      index_row.record_type,
      semantic_action_matches_text.predicate_text
    )
  ) AND semantic_action_matches_text.allow_refresh IS NOT NULL;
END;
$$;

CREATE FUNCTION otlet.semantic_action_matches_program(
  program_name text,
  subject_id text,
  allow_refresh boolean DEFAULT false
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
DECLARE
  program_row otlet.semantic_action_programs%ROWTYPE;
BEGIN
  SELECT *
  INTO program_row
  FROM otlet.semantic_action_programs sp
  WHERE sp.name = semantic_action_matches_program.program_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic action program % does not exist', semantic_action_matches_program.program_name;
  END IF;

  IF semantic_action_matches_program.allow_refresh THEN
    RETURN otlet.semantic_action_matches_auto(
      program_row.index_name,
      semantic_action_matches_program.subject_id,
      program_row.action_type,
      program_row.expected,
      0,
      0,
      0,
      true
    );
  END IF;

  RETURN otlet.semantic_action_matches(
    program_row.index_name,
    semantic_action_matches_program.subject_id,
    program_row.action_type,
    program_row.expected
  );
END;
$$;

CREATE FUNCTION otlet.semantic_action_matches_program_auto(
  program_name text,
  subject_id text,
  max_wait_ms integer DEFAULT 10000,
  max_infer_ms integer DEFAULT 15000,
  max_rows integer DEFAULT 1,
  allow_refresh boolean DEFAULT true
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
DECLARE
  program_row otlet.semantic_action_programs%ROWTYPE;
BEGIN
  SELECT *
  INTO program_row
  FROM otlet.semantic_action_programs sp
  WHERE sp.name = semantic_action_matches_program_auto.program_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic action program % does not exist', semantic_action_matches_program_auto.program_name;
  END IF;

  RETURN otlet.semantic_action_matches_auto(
    program_row.index_name,
    semantic_action_matches_program_auto.subject_id,
    program_row.action_type,
    program_row.expected,
    semantic_action_matches_program_auto.max_wait_ms,
    semantic_action_matches_program_auto.max_infer_ms,
    semantic_action_matches_program_auto.max_rows,
    semantic_action_matches_program_auto.allow_refresh
  );
END;
$$;

CREATE FUNCTION otlet.semantic_action_ref_matches(
  semantic_action_value otlet.semantic_action_ref,
  expected jsonb
) RETURNS boolean
LANGUAGE sql
STABLE
STRICT
COST 1000
AS $$
  SELECT otlet.semantic_action_matches(
    (semantic_action_ref_matches.semantic_action_value).index_name,
    (semantic_action_ref_matches.semantic_action_value).subject_id,
    (semantic_action_ref_matches.semantic_action_value).action_type,
    semantic_action_ref_matches.expected
  );
$$;

ALTER FUNCTION otlet.semantic_subject(text, text) PARALLEL SAFE;
ALTER FUNCTION otlet.semantic_join_subject(text, text) PARALLEL SAFE;
ALTER FUNCTION otlet.semantic_field(text, text, text) PARALLEL SAFE;
ALTER FUNCTION otlet.semantic_action(text, text, text) PARALLEL SAFE;

ALTER FUNCTION otlet.semantic_join_matches(text, text, jsonb) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_join_matches_auto(text, text, jsonb, integer, integer, integer, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_join_matches_program(text, text, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_join_matches_program_auto(text, text, integer, integer, integer, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_join_ref_matches(otlet.semantic_join_ref, jsonb) VOLATILE PARALLEL RESTRICTED;

ALTER FUNCTION otlet.semantic_matches(text, text, jsonb, numeric, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_matches_auto(text, text, jsonb, integer, integer, integer, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_matches_text(text, text, text, numeric, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_matches_program(text, text, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_matches_program_auto(text, text, integer, integer, integer, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_ref_matches(otlet.semantic_ref, jsonb) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_field_matches(otlet.semantic_field_ref, text) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_field_bool_matches(otlet.semantic_field_ref, boolean) VOLATILE PARALLEL RESTRICTED;

ALTER FUNCTION otlet.semantic_action_matches(text, text, text, jsonb) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_action_matches_auto(text, text, text, jsonb, integer, integer, integer, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_action_matches_text(text, text, text, text, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_action_matches_program(text, text, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_action_matches_program_auto(text, text, integer, integer, integer, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_action_ref_matches(otlet.semantic_action_ref, jsonb) VOLATILE PARALLEL RESTRICTED;

CREATE OPERATOR otlet.@? (
  LEFTARG = otlet.semantic_ref,
  RIGHTARG = jsonb,
  PROCEDURE = otlet.semantic_ref_matches
);

CREATE OPERATOR otlet.@? (
  LEFTARG = otlet.semantic_join_ref,
  RIGHTARG = jsonb,
  PROCEDURE = otlet.semantic_join_ref_matches
);

CREATE OPERATOR otlet.@? (
  LEFTARG = otlet.semantic_action_ref,
  RIGHTARG = jsonb,
  PROCEDURE = otlet.semantic_action_ref_matches
);

CREATE OPERATOR otlet.@= (
  LEFTARG = otlet.semantic_field_ref,
  RIGHTARG = text,
  PROCEDURE = otlet.semantic_field_matches
);

CREATE OPERATOR otlet.@= (
  LEFTARG = otlet.semantic_field_ref,
  RIGHTARG = boolean,
  PROCEDURE = otlet.semantic_field_bool_matches
);
