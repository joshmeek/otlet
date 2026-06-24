CREATE FUNCTION otlet.semantic_fdw_handler() RETURNS fdw_handler
AS 'MODULE_PATHNAME', 'otlet_semantic_fdw_handler'
LANGUAGE C STRICT;

CREATE FOREIGN DATA WRAPPER otlet_semantic_fdw
HANDLER otlet.semantic_fdw_handler;

CREATE SERVER otlet_semantic_server
FOREIGN DATA WRAPPER otlet_semantic_fdw;

CREATE FUNCTION otlet.create_semantic_foreign_table(
  table_name text,
  index_name text,
  schema_name text DEFAULT 'otlet',
  min_freshness numeric DEFAULT 1,
  allow_refresh boolean DEFAULT true
) RETURNS regclass
LANGUAGE plpgsql
AS $$
DECLARE
  fq_table text;
BEGIN
  IF table_name !~ '^[a-z][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'otlet semantic foreign table name % must be a simple SQL identifier', table_name;
  END IF;

  IF schema_name !~ '^[a-z][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'otlet semantic foreign schema name % must be a simple SQL identifier', schema_name;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM otlet.semantic_indexes si WHERE si.name = create_semantic_foreign_table.index_name) THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', index_name;
  END IF;

  fq_table := format('%I.%I', schema_name, table_name);
  EXECUTE format('DROP FOREIGN TABLE IF EXISTS %s', fq_table);
  EXECUTE format(
    $create$
      CREATE FOREIGN TABLE %s (
        subject_id text,
        body jsonb,
        stale boolean,
        source_hash text,
        updated_at text
      )
      SERVER otlet_semantic_server
      OPTIONS (
        index_name %L,
        min_freshness %L,
        allow_refresh %L
      )
    $create$,
    fq_table,
    index_name,
    GREATEST(0, LEAST(COALESCE(min_freshness, 1), 1))::text,
    CASE WHEN allow_refresh THEN 'true' ELSE 'false' END
  );

  RETURN fq_table::regclass;
END;
$$;

CREATE FUNCTION otlet.create_semantic_join_foreign_table(
  table_name text,
  index_name text,
  schema_name text DEFAULT 'otlet',
  allow_refresh boolean DEFAULT true
) RETURNS regclass
LANGUAGE plpgsql
AS $$
DECLARE
  fq_table text;
BEGIN
  IF table_name !~ '^[a-z][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'otlet semantic join foreign table name % must be a simple SQL identifier', table_name;
  END IF;

  IF schema_name !~ '^[a-z][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'otlet semantic join foreign schema name % must be a simple SQL identifier', schema_name;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM otlet.semantic_join_indexes sji WHERE sji.name = create_semantic_join_foreign_table.index_name) THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', index_name;
  END IF;

  fq_table := format('%I.%I', schema_name, table_name);
  EXECUTE format('DROP FOREIGN TABLE IF EXISTS %s', fq_table);
  EXECUTE format(
    $create$
      CREATE FOREIGN TABLE %s (
        subject_id text,
        body jsonb,
        stale boolean,
        source_hash text,
        updated_at text
      )
      SERVER otlet_semantic_server
      OPTIONS (
        join_index_name %L,
        allow_refresh %L
      )
    $create$,
    fq_table,
    index_name,
    CASE WHEN allow_refresh THEN 'true' ELSE 'false' END
  );

  RETURN fq_table::regclass;
END;
$$;
