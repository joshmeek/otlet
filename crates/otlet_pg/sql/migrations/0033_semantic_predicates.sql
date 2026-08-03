
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
  current_content_hash text;
BEGIN
  SELECT
    revision.definition #>> '{source,source_table}' AS source_table,
    revision.definition #>> '{source,subject_column}' AS subject_column,
    ARRAY(
      SELECT value
      FROM jsonb_array_elements_text(COALESCE(revision.definition #> '{source,input_columns}', '[]'::jsonb)) value
    ) AS input_columns,
    revision.definition #>> '{task,name}' AS task_name,
    revision.definition #>> '{source,record_type}' AS record_type,
    revision.definition #> '{task,input_shaping}' AS input_shaping,
    head.active_workload_revision_hash AS contract_hash
  INTO index_row
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_index_name}' = semantic_matches.index_name
    AND revision.definition #>> '{source,kind}' = 'row';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', semantic_matches.index_name;
  END IF;

  EXECUTE format(
    $sql$
      SELECT otlet.semantic_content_hash(jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', %1$L,
          'subject_id', (src.%2$I)::text,
          'ctid', src.ctid::text,
          'xmin', src.xmin::text
        ),
        'table', %1$L,
        'row', otlet.semantic_project_row(to_jsonb(src), %3$L::text[])
      ), %5$L::jsonb)
      FROM %4$s AS src
      WHERE (src.%2$I)::text = $1
      LIMIT 1
    $sql$,
    index_row.source_table,
    index_row.subject_column,
    index_row.input_columns,
    index_row.source_table,
    index_row.input_shaping
  )
  INTO current_content_hash
  USING semantic_matches.subject_id;

  IF current_content_hash IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM (
      SELECT DISTINCT ON (sm.subject_id)
        sm.subject_id,
        sm.body,
        sm.content_hash,
        sm.contract_hash,
        sm.stale,
        sm.stale_reason,
        sm.updated_at,
        sm.id
      FROM otlet.semantic_materializations sm
      WHERE sm.task_name = index_row.task_name
        AND sm.record_type = index_row.record_type
        AND sm.subject_id = semantic_matches.subject_id
        AND sm.contract_hash = index_row.contract_hash
      ORDER BY
        sm.subject_id,
        (
          sm.content_hash IS NOT DISTINCT FROM current_content_hash
          AND sm.contract_hash IS NOT DISTINCT FROM index_row.contract_hash
        ) DESC,
        sm.updated_at DESC,
        sm.id DESC
    ) latest
    CROSS JOIN LATERAL otlet.semantic_freshness_status(
      latest.content_hash,
      latest.contract_hash,
      latest.stale,
      latest.stale_reason,
      NULL,
      current_content_hash,
      index_row.contract_hash,
      NULL
    ) status
    WHERE status.is_fresh
      AND latest.body @> semantic_matches.expected
  );
END;
$$;

-- CustomScan matches this wrapper name to enable bounded infer-now planning
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

COMMENT ON FUNCTION otlet.semantic_matches_auto(text, text, jsonb)
IS 'CustomScan hook anchor; intentionally delegates to semantic_matches without duplicating policy';

COMMENT ON FUNCTION otlet.semantic_join_matches_auto(text, text, jsonb)
IS 'CustomScan hook anchor; intentionally delegates to semantic_join_matches without duplicating policy';

ALTER FUNCTION otlet.semantic_join_matches(text, text, jsonb) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_join_matches_auto(text, text, jsonb) VOLATILE PARALLEL RESTRICTED;

ALTER FUNCTION otlet.semantic_matches(text, text, jsonb) VOLATILE PARALLEL RESTRICTED;
ALTER FUNCTION otlet.semantic_matches_auto(text, text, jsonb) VOLATILE PARALLEL RESTRICTED;
