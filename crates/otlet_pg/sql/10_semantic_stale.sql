CREATE FUNCTION otlet.semantic_input_dependencies(
  input jsonb
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  WITH mvcc AS (
    SELECT CASE
      WHEN jsonb_typeof($1 -> '_otlet_mvcc') = 'object' THEN $1 -> '_otlet_mvcc'
      ELSE '{}'::jsonb
    END AS doc
  ),
  source AS (
    SELECT NULLIF(doc ->> 'table', '') AS source_table, doc
    FROM mvcc
  ),
  dependencies AS (
    SELECT DISTINCT
      source_table,
      entry.value AS subject_id,
      entry.key AS field_name
    FROM source
    CROSS JOIN LATERAL jsonb_each_text(source.doc) AS entry(key, value)
    WHERE source_table IS NOT NULL
      AND NULLIF(entry.value, '') IS NOT NULL
      AND (entry.key = 'subject_id' OR entry.key ~ '(^|_)id$')
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'table', source_table,
        'subject_id', subject_id,
        'field', field_name
      )
      ORDER BY source_table, subject_id, field_name
    ),
    '[]'::jsonb
  )
  FROM dependencies;
$$;

CREATE FUNCTION otlet.mark_semantic_stale(
  source_table text DEFAULT NULL,
  subject_id text DEFAULT NULL,
  stale_reason text DEFAULT 'manual'
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  marked bigint;
BEGIN
  WITH targets AS (
    SELECT
      sm.id,
      (
        (mark_semantic_stale.source_table IS NULL OR sm.source_table = mark_semantic_stale.source_table)
        AND (
          mark_semantic_stale.subject_id IS NULL
          OR sm.subject_id = mark_semantic_stale.subject_id
        )
      ) AS exact_match,
      (
        mark_semantic_stale.source_table IS NOT NULL
        AND (
          (
            mark_semantic_stale.subject_id IS NULL
            AND sm.source_dependencies @> jsonb_build_array(jsonb_build_object(
              'table', mark_semantic_stale.source_table
            ))
          )
          OR (
            mark_semantic_stale.subject_id IS NOT NULL
            AND sm.source_dependencies @> jsonb_build_array(jsonb_build_object(
              'table', mark_semantic_stale.source_table,
              'subject_id', mark_semantic_stale.subject_id
            ))
          )
        )
      ) AS dependency_match
    FROM otlet.semantic_materializations sm
  )
  UPDATE otlet.semantic_materializations sm
  SET stale = true,
      stale_reason = CASE
        WHEN targets.exact_match THEN COALESCE(mark_semantic_stale.stale_reason, 'manual')
        WHEN COALESCE(mark_semantic_stale.stale_reason, 'manual') = 'source_update' THEN 'content_revalidation_pending'
        ELSE COALESCE(mark_semantic_stale.stale_reason, 'manual')
      END,
      updated_at = now()
  FROM targets
  WHERE sm.id = targets.id
    AND (targets.exact_match OR targets.dependency_match);

  GET DIAGNOSTICS marked = ROW_COUNT;
  RETURN marked;
END;
$$;

CREATE FUNCTION otlet.mark_semantic_stale_trigger() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  row_input jsonb;
  subject_id text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    row_input := to_jsonb(OLD);
  ELSE
    row_input := to_jsonb(NEW);
  END IF;

  subject_id := row_input ->> TG_ARGV[0];
  PERFORM otlet.mark_semantic_stale(
    format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME),
    subject_id,
    CASE WHEN TG_OP = 'DELETE' THEN 'source_delete' ELSE 'source_update' END
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION otlet.watch_semantic_stale(
  table_name regclass,
  subject_column text DEFAULT 'id'
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  trigger_name text := 'otlet_stale_' || substr(md5(table_name::text || ':' || subject_column), 1, 16);
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = table_name
      AND attname = subject_column
      AND attnum > 0
      AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'otlet subject column % does not exist on %', subject_column, table_name;
  END IF;

  EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trigger_name, table_name);
  EXECUTE format(
    'CREATE TRIGGER %I AFTER UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION otlet.mark_semantic_stale_trigger(%L)',
    trigger_name,
    table_name,
    subject_column
  );

  RETURN trigger_name;
END;
$$;
