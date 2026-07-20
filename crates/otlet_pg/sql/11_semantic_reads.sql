CREATE FUNCTION otlet.semantic_index_current_rows(
  index_name text,
  fresh_only boolean DEFAULT true
) RETURNS TABLE (
  subject_id text,
  body jsonb,
  stale boolean,
  source_hash text,
  freshness_basis text,
  updated_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes
  WHERE name = semantic_index_current_rows.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', semantic_index_current_rows.index_name;
  END IF;

  PERFORM otlet.mark_semantic_schema_drift(index_row.name);

  SELECT
    otlet.task_contract_hash(
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    ),
    t.input_shaping
  INTO current_contract_hash, current_input_shaping
  FROM otlet.tasks t
  WHERE t.name = index_row.task_name;

  RETURN QUERY EXECUTE format(
    $sql$
      WITH raw_inputs AS (
        SELECT
          (src.%1$I)::text AS subject_id,
          jsonb_build_object(
            '_otlet_mvcc', jsonb_build_object(
              'table', %2$L,
              'subject_id', (src.%1$I)::text,
              'ctid', src.ctid::text,
              'xmin', src.xmin::text
            ),
            'table', %2$L,
            'row', otlet.semantic_project_row(to_jsonb(src), %6$L::text[])
          ) AS input
        FROM %3$s AS src
      ),
      current_inputs AS (
        SELECT
          subject_id,
          input,
          md5(input::text) AS source_hash,
          otlet.semantic_content_hash(input, %9$L::jsonb) AS content_hash
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
        WHERE sm.task_name = %4$L
          AND sm.record_type = %5$L
        ORDER BY
          sm.subject_id,
          (
            sm.content_hash IS NOT DISTINCT FROM ci.content_hash
            AND sm.contract_hash IS NOT DISTINCT FROM %7$L
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
        %7$L,
        ci.source_hash
      ) status
      WHERE (
        NOT %8$s
        OR status.is_fresh
      )
      ORDER BY latest.subject_id, latest.updated_at DESC
    $sql$,
    index_row.subject_column,
    index_row.source_table,
    index_row.source_table,
    index_row.task_name,
    index_row.record_type,
    index_row.input_columns,
    current_contract_hash,
    CASE WHEN COALESCE(semantic_index_current_rows.fresh_only, true) THEN 'true' ELSE 'false' END,
    current_input_shaping
  );
END;
$$;

CREATE FUNCTION otlet.revalidate_semantic_subjects(
  index_name text,
  subject_ids text[] DEFAULT NULL
) RETURNS TABLE (
  subject_id text,
  revalidated boolean,
  stale_reason text,
  freshness_basis text
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes
  WHERE name = revalidate_semantic_subjects.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', revalidate_semantic_subjects.index_name;
  END IF;

  SELECT
    otlet.task_contract_hash(
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    ),
    t.input_shaping
  INTO current_contract_hash, current_input_shaping
  FROM otlet.tasks t
  WHERE t.name = index_row.task_name;

  RETURN QUERY EXECUTE format(
    $sql$
      WITH raw_inputs AS (
        SELECT
          (src.%1$I)::text AS subject_id,
          jsonb_build_object(
            '_otlet_mvcc', jsonb_build_object(
              'table', %2$L,
              'subject_id', (src.%1$I)::text,
              'ctid', src.ctid::text,
              'xmin', src.xmin::text
            ),
            'table', %2$L,
            'row', otlet.semantic_project_row(to_jsonb(src), %7$L::text[])
          ) AS input
        FROM %3$s AS src
        WHERE (%8$L::text[] IS NULL OR (src.%1$I)::text = ANY(%8$L::text[]))
      ),
      current_inputs AS (
        SELECT
          subject_id,
          input,
          md5(input::text) AS source_hash,
          otlet.semantic_content_hash(input, %6$L::jsonb) AS content_hash
        FROM raw_inputs
      ),
      latest AS (
        SELECT DISTINCT ON (sm.subject_id)
          sm.id,
          sm.subject_id,
          sm.stale,
          sm.source_hash,
          sm.content_hash,
          sm.contract_hash,
          sm.stale_reason,
          sm.freshness_basis,
          sm.updated_at
        FROM current_inputs ci
        JOIN otlet.semantic_materializations sm
          ON sm.subject_id = ci.subject_id
        WHERE sm.task_name = %4$L
          AND sm.record_type = %5$L
        ORDER BY
          sm.subject_id,
          (
            sm.content_hash IS NOT DISTINCT FROM ci.content_hash
            AND sm.contract_hash IS NOT DISTINCT FROM %9$L
          ) DESC,
          sm.updated_at DESC,
          sm.id DESC
      ),
      classified AS (
        SELECT
          ci.subject_id,
          l.id,
          l.stale,
          status.is_fresh,
          status.stale_reason,
          status.freshness_basis
        FROM current_inputs ci
        JOIN latest l USING (subject_id)
        CROSS JOIN LATERAL otlet.semantic_freshness_status(
          l.content_hash,
          l.contract_hash,
          l.stale,
          l.stale_reason,
          l.source_hash,
          ci.content_hash,
          %9$L,
          ci.source_hash
        ) status
      ),
      updated AS (
        UPDATE otlet.semantic_materializations sm
        SET stale = false,
            stale_reason = NULL,
            freshness_basis = 'revalidated_after_benign_update',
            updated_at = now()
        FROM classified c
        WHERE sm.id = c.id
          AND c.stale
          AND c.is_fresh
        RETURNING sm.id, sm.subject_id
      )
      SELECT
        c.subject_id,
        (u.id IS NOT NULL) AS revalidated,
        CASE
          WHEN u.id IS NOT NULL THEN NULL::text
          ELSE c.stale_reason
        END AS stale_reason,
        CASE
          WHEN u.id IS NOT NULL THEN 'revalidated_after_benign_update'
          ELSE c.freshness_basis
        END AS freshness_basis
      FROM classified c
      LEFT JOIN updated u ON u.id = c.id
      ORDER BY c.subject_id
    $sql$,
    index_row.subject_column,
    index_row.source_table,
    index_row.source_table,
    index_row.task_name,
    index_row.record_type,
    current_input_shaping,
    index_row.input_columns,
    revalidate_semantic_subjects.subject_ids,
    current_contract_hash
  );
END;
$$;
