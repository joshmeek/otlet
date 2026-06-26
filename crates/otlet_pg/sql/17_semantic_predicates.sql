
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
  expected jsonb
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
BEGIN
  RETURN otlet.semantic_matches(
    semantic_matches_auto.index_name,
    semantic_matches_auto.subject_id,
    semantic_matches_auto.expected
  );
END;
$$;

ALTER FUNCTION otlet.semantic_join_matches(text, text, jsonb) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_join_matches_auto(text, text, jsonb) VOLATILE PARALLEL RESTRICTED;

ALTER FUNCTION otlet.semantic_matches(text, text, jsonb) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_matches_auto(text, text, jsonb) VOLATILE PARALLEL RESTRICTED;
