CREATE FUNCTION otlet.refresh_semantic_materializations(
  record_type text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  refreshed bigint;
BEGIN
  INSERT INTO otlet.semantic_materializations (
    record_id,
    record_type,
    source_table,
    subject_id,
    task_name,
    model_name,
    body,
    stale,
    source_hash,
    content_hash,
    contract_hash,
    stale_reason,
    freshness_basis,
    updated_at
  )
  SELECT
    r.id,
    r.record_type,
    j.input ->> 'table',
    r.subject_id,
    j.task_name,
    t.model_name,
    r.body,
    false,
    md5(j.input::text),
    otlet.semantic_content_hash(j.input),
    otlet.task_contract_hash(t.instruction, t.output_schema, t.model_name, t.runtime_options, t.input_shaping, t.decision_contract),
    NULL,
    'content_hash_match',
    now()
  FROM otlet.records r
  JOIN otlet.actions a ON a.id = r.action_id
  JOIN otlet.jobs j ON j.id = a.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
  WHERE refresh_semantic_materializations.record_type IS NULL
     OR r.record_type = refresh_semantic_materializations.record_type
  ON CONFLICT (record_id) DO UPDATE
    SET record_type = EXCLUDED.record_type,
        source_table = EXCLUDED.source_table,
        subject_id = EXCLUDED.subject_id,
        task_name = EXCLUDED.task_name,
        model_name = EXCLUDED.model_name,
        body = EXCLUDED.body,
        stale = false,
        source_hash = EXCLUDED.source_hash,
        content_hash = EXCLUDED.content_hash,
        contract_hash = EXCLUDED.contract_hash,
        stale_reason = NULL,
        freshness_basis = EXCLUDED.freshness_basis,
        updated_at = now();

  GET DIAGNOSTICS refreshed = ROW_COUNT;
  RETURN refreshed;
END;
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
