
CREATE FUNCTION otlet.semantic_matches(
  index_name text,
  subject_id text,
  expected jsonb
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

CREATE FUNCTION otlet.semantic_matches_program(
  program_name text,
  subject_id text
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
    program_row.expected
  );
END;
$$;

CREATE FUNCTION otlet.semantic_join_matches_program(
  program_name text,
  subject_id text
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
  );
END;
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

CREATE FUNCTION otlet.semantic_action_matches_program(
  program_name text,
  subject_id text
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

  RETURN otlet.semantic_action_matches(
    program_row.index_name,
    semantic_action_matches_program.subject_id,
    program_row.action_type,
    program_row.expected
  );
END;
$$;

ALTER FUNCTION otlet.semantic_join_matches(text, text, jsonb) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_join_matches_auto(text, text, jsonb, integer, integer, integer, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_join_matches_program(text, text) VOLATILE PARALLEL RESTRICTED;

ALTER FUNCTION otlet.semantic_matches(text, text, jsonb) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_matches_auto(text, text, jsonb, integer, integer, integer, boolean) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_matches_program(text, text) VOLATILE PARALLEL RESTRICTED;

ALTER FUNCTION otlet.semantic_action_matches(text, text, text, jsonb) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_action_matches_program(text, text) VOLATILE PARALLEL RESTRICTED;
