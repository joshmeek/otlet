CREATE FUNCTION otlet.semantic_join_index_current_rows(
  index_name text,
  fresh_only boolean DEFAULT true,
  expected_workload_revision_hash text DEFAULT NULL
) RETURNS TABLE (
  subject_id text,
  body jsonb,
  stale boolean,
  source_hash text,
  freshness_basis text,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  fresh_sql text := CASE WHEN COALESCE(fresh_only, true) THEN 'true' ELSE 'false' END;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
BEGIN
  SELECT
    revision.definition #>> '{source,semantic_join_index_name}',
    revision.definition #>> '{task,name}',
    revision.definition #>> '{source,candidate_query}',
    revision.definition #>> '{source,record_type}',
    (revision.definition #>> '{source,max_candidate_rows}')::integer,
    head.active_workload_revision_hash,
    revision.definition #> '{task,input_shaping}'
  INTO
    index_row.name,
    index_row.task_name,
    index_row.candidate_query,
    index_row.record_type,
    index_row.max_candidate_rows,
    current_contract_hash,
    current_input_shaping
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_join_index_name}' = semantic_join_index_current_rows.index_name
    AND revision.definition #>> '{source,kind}' = 'pair';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', semantic_join_index_current_rows.index_name;
  END IF;

  IF semantic_join_index_current_rows.expected_workload_revision_hash IS NOT NULL
     AND semantic_join_index_current_rows.expected_workload_revision_hash IS DISTINCT FROM current_contract_hash THEN
    RAISE EXCEPTION 'otlet workload revision changed during semantic read for index %', index_row.name;
  END IF;

  RETURN QUERY EXECUTE format(
    $sql$
      WITH raw_inputs AS (
        SELECT subject_id, input
        FROM (
          SELECT subject_id::text AS subject_id, input::jsonb AS input
          FROM (%1$s) otlet_join_candidate
          ORDER BY subject_id
          LIMIT %2$s
        ) otlet_join_input
      ),
      current_inputs AS (
        SELECT
          subject_id,
          input,
          otlet.semantic_source_hash(input) AS source_hash,
          otlet.semantic_content_hash(input, %7$L::jsonb) AS content_hash
        FROM raw_inputs
      ),
      latest AS (
        SELECT DISTINCT ON (sm.subject_id)
          sm.subject_id,
          sm.body,
          sm.stale,
          sm.source_hash,
          sm.content_hash,
          sm.contract_hash,
          sm.stale_reason,
          sm.freshness_basis,
          sm.updated_at,
          sm.id
        FROM current_inputs ci
        JOIN otlet.semantic_materializations sm
          ON sm.subject_id = ci.subject_id
        WHERE sm.task_name = %3$L
          AND sm.record_type = %4$L
          AND sm.contract_hash = %5$L
        ORDER BY
          sm.subject_id,
          (
            sm.content_hash IS NOT DISTINCT FROM ci.content_hash
            AND sm.contract_hash IS NOT DISTINCT FROM %5$L
          ) DESC,
          sm.updated_at DESC,
          sm.id DESC
      )
      SELECT
        latest.subject_id,
        latest.body,
        status.is_stale AS stale,
        latest.source_hash,
        CASE
          WHEN status.freshness_basis = 'content_hash_match' THEN COALESCE(latest.freshness_basis, status.freshness_basis)
          ELSE status.freshness_basis
        END AS freshness_basis,
        latest.updated_at
      FROM current_inputs ci
      JOIN latest ON latest.subject_id = ci.subject_id
      CROSS JOIN LATERAL otlet.semantic_freshness_status(
        latest.content_hash,
        latest.contract_hash,
        latest.stale,
        latest.stale_reason,
        latest.source_hash,
        ci.content_hash,
        %5$L,
        ci.source_hash
      ) status
      WHERE (
        NOT %6$s
        OR status.is_fresh
      )
      ORDER BY latest.subject_id
    $sql$,
    index_row.candidate_query,
    index_row.max_candidate_rows,
    index_row.task_name,
    index_row.record_type,
    current_contract_hash,
    fresh_sql,
    current_input_shaping
  );
END;
$$;

CREATE FUNCTION otlet.semantic_join_matches(
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
  index_row otlet.semantic_join_indexes%ROWTYPE;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
  current_input jsonb;
  current_source_hash text;
  current_content_hash text;
BEGIN
  SELECT
    revision.definition #>> '{source,semantic_join_index_name}',
    revision.definition #>> '{task,name}',
    revision.definition #>> '{source,candidate_query}',
    revision.definition #>> '{source,record_type}',
    (revision.definition #>> '{source,max_candidate_rows}')::integer,
    head.active_workload_revision_hash,
    revision.definition #> '{task,input_shaping}'
  INTO
    index_row.name,
    index_row.task_name,
    index_row.candidate_query,
    index_row.record_type,
    index_row.max_candidate_rows,
    current_contract_hash,
    current_input_shaping
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_join_index_name}' = semantic_join_matches.index_name
    AND revision.definition #>> '{source,kind}' = 'pair';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', semantic_join_matches.index_name;
  END IF;

  EXECUTE format(
    $sql$
      SELECT input
      FROM (
        SELECT subject_id::text AS subject_id, input::jsonb AS input
        FROM (%s) otlet_join_candidate
      ) otlet_join_input
      WHERE subject_id = $1
      LIMIT 1
    $sql$,
    index_row.candidate_query
  )
  INTO current_input
  USING semantic_join_matches.subject_id;

  IF current_input IS NULL THEN
    RETURN false;
  END IF;

  current_source_hash := otlet.semantic_source_hash(current_input);
  current_content_hash := otlet.semantic_content_hash(current_input, current_input_shaping);

  RETURN EXISTS (
    SELECT 1
    FROM (
      SELECT DISTINCT ON (sm.subject_id)
        sm.subject_id,
        sm.body,
        sm.source_hash,
        sm.content_hash,
        sm.contract_hash,
        sm.stale,
        sm.stale_reason,
        sm.freshness_basis,
        sm.updated_at,
        sm.id
      FROM otlet.semantic_materializations sm
      WHERE sm.task_name = index_row.task_name
        AND sm.record_type = index_row.record_type
        AND sm.subject_id = semantic_join_matches.subject_id
        AND sm.contract_hash = current_contract_hash
      ORDER BY
        sm.subject_id,
        (
          sm.content_hash IS NOT DISTINCT FROM current_content_hash
          AND sm.contract_hash IS NOT DISTINCT FROM current_contract_hash
        ) DESC,
        sm.updated_at DESC,
        sm.id DESC
    ) latest
    CROSS JOIN LATERAL otlet.semantic_freshness_status(
      latest.content_hash,
      latest.contract_hash,
      latest.stale,
      latest.stale_reason,
      latest.source_hash,
      current_content_hash,
      current_contract_hash,
      current_source_hash
    ) status
    WHERE status.is_fresh
      AND latest.body @> semantic_join_matches.expected
  );
END;
$$;

CREATE FUNCTION otlet.semantic_join_matches_auto(
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
  RETURN otlet.semantic_join_matches(
    semantic_join_matches_auto.index_name,
    semantic_join_matches_auto.subject_id,
    semantic_join_matches_auto.expected
  );
END;
$$;
