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
  UPDATE otlet.semantic_materializations sm
  SET stale = true,
      stale_reason = COALESCE(mark_semantic_stale.stale_reason, 'manual'),
      updated_at = now()
  WHERE (mark_semantic_stale.source_table IS NULL OR sm.source_table = mark_semantic_stale.source_table)
    AND (
      mark_semantic_stale.subject_id IS NULL
      OR sm.subject_id = mark_semantic_stale.subject_id
    );

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
