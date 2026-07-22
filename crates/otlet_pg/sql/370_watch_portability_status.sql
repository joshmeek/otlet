CREATE FUNCTION otlet.watch_pack_with_digest(definition jsonb) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  WITH canonical AS (
    SELECT otlet.semantic_canonical_jsonb($1 - 'content_digest') AS value
  )
  SELECT value || jsonb_build_object('content_digest', md5(value::text))
  FROM canonical;
$$;

CREATE FUNCTION otlet.validate_watch_pack(definition jsonb) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  allowed_keys constant text[] := ARRAY[
    'format', 'name', 'kind', 'instruction', 'output_schema', 'model_name',
    'model_artifact_identity', 'table_name', 'subject_column', 'candidate_query',
    'record_type', 'runtime_options', 'selection_policy', 'trigger_policy',
    'action_types', 'stale_policy', 'input_shaping', 'decision_contract',
    'max_candidate_rows', 'input_columns', 'pair_sources', 'content_digest',
    'version_metadata', 'fixtures', 'labels', 'expected_receipts', 'evaluation_gates'
  ];
  required_keys constant text[] := ARRAY[
    'format', 'name', 'kind', 'instruction', 'output_schema', 'model_name',
    'model_artifact_identity', 'table_name', 'subject_column', 'candidate_query',
    'record_type', 'runtime_options', 'selection_policy', 'trigger_policy',
    'action_types', 'stale_policy', 'input_shaping', 'decision_contract',
    'max_candidate_rows', 'input_columns', 'pair_sources'
  ];
  pack jsonb := validate_watch_pack.definition;
  object_key text;
  object_field text;
  array_field text;
  provided_digest text;
  canonical_table text;
  source_table regclass;
  source_column text;
  source jsonb;
  normalized jsonb;
  cheap_model_name text;
  strong_model_name text;
BEGIN
  IF jsonb_typeof(pack) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch definition must be a JSON object';
  END IF;
  IF octet_length(pack::text) > 16777216 THEN
    RAISE EXCEPTION 'otlet watch definition exceeds 16777216 bytes';
  END IF;

  SELECT key INTO object_key
  FROM jsonb_object_keys(pack) key
  WHERE NOT key = ANY(allowed_keys)
  ORDER BY key
  LIMIT 1;
  IF object_key IS NOT NULL THEN
    RAISE EXCEPTION 'otlet watch definition has unsupported key %', object_key;
  END IF;

  SELECT key INTO object_key
  FROM unnest(required_keys) key
  WHERE NOT pack ? key
  ORDER BY key
  LIMIT 1;
  IF object_key IS NOT NULL THEN
    RAISE EXCEPTION 'otlet watch definition is missing key %', object_key;
  END IF;

  provided_digest := pack ->> 'content_digest';
  IF pack ? 'content_digest'
     AND (
       jsonb_typeof(pack -> 'content_digest') IS DISTINCT FROM 'string'
       OR provided_digest !~ '^[0-9a-f]{32}$'
     ) THEN
    RAISE EXCEPTION 'otlet watch definition content_digest must be a lowercase MD5 digest';
  END IF;

  pack := pack || jsonb_build_object(
    'version_metadata', COALESCE(pack -> 'version_metadata', '{}'::jsonb),
    'fixtures', COALESCE(pack -> 'fixtures', '[]'::jsonb),
    'labels', COALESCE(pack -> 'labels', '[]'::jsonb),
    'expected_receipts', COALESCE(pack -> 'expected_receipts', '[]'::jsonb),
    'evaluation_gates', COALESCE(pack -> 'evaluation_gates', '{}'::jsonb)
  );

  IF pack ->> 'format' IS DISTINCT FROM 'otlet.watch.v1' THEN
    RAISE EXCEPTION 'otlet watch definition format must be otlet.watch.v1';
  END IF;
  FOREACH object_key IN ARRAY ARRAY['name', 'kind', 'instruction', 'model_name', 'record_type', 'stale_policy'] LOOP
    IF jsonb_typeof(pack -> object_key) IS DISTINCT FROM 'string'
       OR NULLIF(pack ->> object_key, '') IS NULL THEN
      RAISE EXCEPTION 'otlet watch definition % must be a non-empty string', object_key;
    END IF;
  END LOOP;
  IF pack ->> 'name' !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet watch definition name must be a simple identifier';
  END IF;
  IF pack ->> 'kind' NOT IN ('row', 'pair') THEN
    RAISE EXCEPTION 'otlet watch definition kind must be row or pair';
  END IF;
  IF jsonb_typeof(pack -> 'output_schema') IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch definition output_schema must be an object';
  END IF;

  FOREACH object_field IN ARRAY ARRAY[
    'runtime_options', 'selection_policy', 'trigger_policy', 'input_shaping',
    'decision_contract', 'model_artifact_identity', 'version_metadata', 'evaluation_gates'
  ] LOOP
    IF jsonb_typeof(pack -> object_field) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'otlet watch definition % must be an object', object_field;
    END IF;
  END LOOP;

  FOREACH array_field IN ARRAY ARRAY[
    'action_types', 'pair_sources', 'fixtures', 'labels', 'expected_receipts'
  ] LOOP
    IF jsonb_typeof(pack -> array_field) IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'otlet watch definition % must be an array', array_field;
    END IF;
  END LOOP;
  IF jsonb_array_length(pack -> 'fixtures') > 10000
     OR jsonb_array_length(pack -> 'labels') > 10000
     OR jsonb_array_length(pack -> 'expected_receipts') > 10000 THEN
    RAISE EXCEPTION 'otlet watch pack evidence arrays must contain at most 10000 entries';
  END IF;
  FOREACH array_field IN ARRAY ARRAY['fixtures', 'labels', 'expected_receipts'] LOOP
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(pack -> array_field) item(value)
      WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'object'
    ) THEN
      RAISE EXCEPTION 'otlet watch definition % entries must be objects', array_field;
    END IF;
    SELECT COALESCE(
      jsonb_agg(item.value ORDER BY otlet.semantic_canonical_jsonb(item.value)::text),
      '[]'::jsonb
    )
    INTO normalized
    FROM jsonb_array_elements(pack -> array_field) item(value);
    pack := jsonb_set(pack, ARRAY[array_field], normalized, true);
  END LOOP;

  IF jsonb_typeof(pack -> 'input_columns') NOT IN ('array', 'null') THEN
    RAISE EXCEPTION 'otlet watch definition input_columns must be an array or null';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(pack -> 'action_types') item(value)
    WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'string'
       OR NULLIF(item.value #>> '{}', '') IS NULL
       OR NOT EXISTS (
         SELECT 1
         FROM otlet.action_type_schemas schema
         WHERE schema.action_type = item.value #>> '{}'
       )
  ) THEN
    RAISE EXCEPTION 'otlet watch definition action_types contains an unsupported action type';
  END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(value) ORDER BY value), '[]'::jsonb)
  INTO normalized
  FROM (
    SELECT DISTINCT value
    FROM jsonb_array_elements_text(pack -> 'action_types') item(value)
  ) action_type;
  pack := jsonb_set(pack, '{action_types}', normalized, true);
  pack := jsonb_set(pack, '{decision_contract,action_types}', normalized, true);

  IF jsonb_typeof(pack -> 'input_columns') = 'array' THEN
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(pack -> 'input_columns') item(value)
      WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'string'
         OR NULLIF(item.value #>> '{}', '') IS NULL
    ) THEN
      RAISE EXCEPTION 'otlet watch definition input_columns entries must be non-empty strings';
    END IF;
    SELECT COALESCE(jsonb_agg(to_jsonb(value) ORDER BY value), '[]'::jsonb)
    INTO normalized
    FROM (
      SELECT DISTINCT value
      FROM jsonb_array_elements_text(pack -> 'input_columns') item(value)
    ) input_column;
    pack := jsonb_set(pack, '{input_columns}', normalized, true);
  END IF;

  IF jsonb_typeof(pack -> 'max_candidate_rows') IS DISTINCT FROM 'number'
     OR (pack ->> 'max_candidate_rows') !~ '^[1-9][0-9]*$'
     OR (pack ->> 'max_candidate_rows')::numeric > 100000 THEN
    RAISE EXCEPTION 'otlet watch definition max_candidate_rows must be an integer between 1 and 100000';
  END IF;

  PERFORM 1 FROM otlet.models model WHERE model.name = pack ->> 'model_name';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet watch definition model % does not exist', pack ->> 'model_name';
  END IF;
  PERFORM 1
  FROM otlet.models model
  WHERE model.name = pack ->> 'model_name'
    AND model.artifact_identity = pack -> 'model_artifact_identity';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet watch definition model artifact identity does not match registered model %', pack ->> 'model_name';
  END IF;

  cheap_model_name := COALESCE(
    pack #>> '{selection_policy,cheap_model_name}',
    pack #>> '{selection_policy,cheap_model}'
  );
  strong_model_name := COALESCE(
    pack #>> '{selection_policy,strong_model_name}',
    pack #>> '{selection_policy,strong_model}'
  );
  IF cheap_model_name IS NOT NULL OR strong_model_name IS NOT NULL THEN
    IF cheap_model_name IS NULL OR strong_model_name IS NULL THEN
      RAISE EXCEPTION 'otlet watch selection_policy requires both cheap_model_name and strong_model_name';
    END IF;
    PERFORM 1 FROM otlet.models model WHERE model.name = cheap_model_name;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'otlet watch selection policy model % does not exist', cheap_model_name;
    END IF;
    PERFORM 1 FROM otlet.models model WHERE model.name = strong_model_name;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'otlet watch selection policy model % does not exist', strong_model_name;
    END IF;
  END IF;

  IF pack ->> 'kind' = 'row' THEN
    IF jsonb_typeof(pack -> 'table_name') IS DISTINCT FROM 'string'
       OR NULLIF(pack ->> 'table_name', '') IS NULL THEN
      RAISE EXCEPTION 'otlet row watch definition requires table_name';
    END IF;
    source_table := to_regclass(pack ->> 'table_name');
    IF source_table IS NULL THEN
      RAISE EXCEPTION 'otlet row watch definition table % does not exist', pack ->> 'table_name';
    END IF;
    source_column := pack ->> 'subject_column';
    IF jsonb_typeof(pack -> 'subject_column') IS DISTINCT FROM 'string'
       OR NULLIF(source_column, '') IS NULL
       OR NOT EXISTS (
         SELECT 1 FROM pg_attribute
         WHERE attrelid = source_table
           AND attname = source_column
           AND attnum > 0
           AND NOT attisdropped
       ) THEN
      RAISE EXCEPTION 'otlet row watch definition subject column % does not exist', source_column;
    END IF;
    IF pack -> 'candidate_query' <> 'null'::jsonb OR pack -> 'pair_sources' <> '[]'::jsonb THEN
      RAISE EXCEPTION 'otlet row watch definition cannot declare pair fields';
    END IF;
    SELECT format('%I.%I', namespace.nspname, relation.relname)
    INTO canonical_table
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE relation.oid = source_table;
    pack := jsonb_set(pack, '{table_name}', to_jsonb(canonical_table), true);
    pack := jsonb_set(
      pack,
      '{input_shaping,source_fields}',
      '["_otlet_mvcc","row","table"]'::jsonb,
      true
    );
  ELSE
    IF jsonb_typeof(pack -> 'candidate_query') IS DISTINCT FROM 'string'
       OR NULLIF(pack ->> 'candidate_query', '') IS NULL THEN
      RAISE EXCEPTION 'otlet pair watch definition requires candidate_query';
    END IF;
    IF pack -> 'table_name' <> 'null'::jsonb
       OR pack -> 'subject_column' <> 'null'::jsonb
       OR pack -> 'input_columns' <> 'null'::jsonb THEN
      RAISE EXCEPTION 'otlet pair watch definition cannot declare row fields';
    END IF;
    PERFORM 1 FROM otlet.preflight_candidate_query(pack ->> 'candidate_query');

    normalized := '[]'::jsonb;
    FOR source IN SELECT value FROM jsonb_array_elements(pack -> 'pair_sources') item(value) LOOP
      IF jsonb_typeof(source) IS DISTINCT FROM 'object'
         OR EXISTS (
           SELECT 1 FROM jsonb_object_keys(source) key
           WHERE key NOT IN ('table', 'source_table', 'subject_column')
         ) THEN
        RAISE EXCEPTION 'otlet watch definition pair_sources entries must be source objects';
      END IF;
      source_table := to_regclass(COALESCE(source ->> 'table', source ->> 'source_table'));
      source_column := COALESCE(NULLIF(source ->> 'subject_column', ''), 'id');
      IF source_table IS NULL THEN
        RAISE EXCEPTION 'otlet pair source table % does not exist', COALESCE(source ->> 'table', source ->> 'source_table');
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM pg_attribute
        WHERE attrelid = source_table
          AND attname = source_column
          AND attnum > 0
          AND NOT attisdropped
      ) THEN
        RAISE EXCEPTION 'otlet pair source subject column % does not exist on %', source_column, source_table;
      END IF;
      SELECT format('%I.%I', namespace.nspname, relation.relname)
      INTO canonical_table
      FROM pg_class relation
      JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
      WHERE relation.oid = source_table;
      normalized := normalized || jsonb_build_array(jsonb_build_object(
        'table', canonical_table,
        'subject_column', source_column
      ));
    END LOOP;
    SELECT COALESCE(
      jsonb_agg(item.value ORDER BY item.value ->> 'table', item.value ->> 'subject_column'),
      '[]'::jsonb
    )
    INTO normalized
    FROM jsonb_array_elements(normalized) item(value);
    pack := jsonb_set(pack, '{pair_sources}', normalized, true);
  END IF;

  pack := otlet.watch_pack_with_digest(pack);
  IF provided_digest IS NOT NULL AND provided_digest IS DISTINCT FROM pack ->> 'content_digest' THEN
    RAISE EXCEPTION 'otlet watch definition content digest does not match canonical content';
  END IF;
  RETURN pack;
END;
$$;

CREATE FUNCTION otlet.export_watch(watch_name text) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  definition jsonb;
BEGIN
  SELECT jsonb_build_object(
    'format', 'otlet.watch.v1',
    'name', w.name,
    'kind', w.kind,
    'instruction', t.instruction,
    'output_schema', w.output_schema,
    'model_name', w.model_name,
    'model_artifact_identity', m.artifact_identity,
    'table_name', w.source_table,
    'subject_column', w.subject_column,
    'candidate_query', w.candidate_query,
    'record_type', w.record_type,
    'runtime_options', w.runtime_options,
    'selection_policy', w.selection_policy,
    'trigger_policy', w.trigger_policy,
    'action_types', COALESCE(
      (
        SELECT jsonb_agg(action_type ORDER BY action_type)
        FROM unnest(w.action_types) action_type
      ),
      '[]'::jsonb
    ),
    'stale_policy', w.stale_policy,
    'input_shaping', w.input_shaping,
    'decision_contract', w.decision_contract,
    'max_candidate_rows', w.max_candidate_rows,
    'input_columns', CASE
      WHEN w.input_columns IS NULL THEN 'null'::jsonb
      ELSE to_jsonb(ARRAY(SELECT column_name FROM unnest(w.input_columns) column_name ORDER BY column_name))
    END,
    'pair_sources', COALESCE(
      (
        SELECT jsonb_agg(source.value ORDER BY source.value ->> 'table', source.value ->> 'subject_column')
        FROM jsonb_array_elements(w.pair_sources) source(value)
      ),
      '[]'::jsonb
    ),
    'version_metadata', COALESCE(version.definition -> 'version_metadata', '{}'::jsonb),
    'fixtures', COALESCE(version.definition -> 'fixtures', '[]'::jsonb),
    'labels', COALESCE(version.definition -> 'labels', '[]'::jsonb),
    'expected_receipts', COALESCE(version.definition -> 'expected_receipts', '[]'::jsonb),
    'evaluation_gates', COALESCE(version.definition -> 'evaluation_gates', '{}'::jsonb)
  )
  INTO definition
  FROM otlet.watches w
  JOIN otlet.tasks t ON t.name = w.task_name
  JOIN otlet.models m ON m.name = w.model_name
  LEFT JOIN otlet.watch_pack_heads head ON head.watch_name = w.name
  LEFT JOIN otlet.watch_pack_versions version ON version.id = head.version_id
  WHERE w.name = export_watch.watch_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet watch % does not exist', watch_name;
  END IF;

  RETURN otlet.watch_pack_with_digest(definition);
END;
$$;

CREATE FUNCTION otlet.record_watch_pack_version(definition jsonb)
RETURNS otlet.watch_pack_versions
LANGUAGE plpgsql
AS $$
DECLARE
  canonical jsonb := otlet.watch_pack_with_digest(record_watch_pack_version.definition);
  saved otlet.watch_pack_versions%ROWTYPE;
  next_version integer;
  pack_watch_name text := canonical ->> 'name';
BEGIN
  IF jsonb_typeof(record_watch_pack_version.definition) IS DISTINCT FROM 'object'
     OR canonical IS DISTINCT FROM record_watch_pack_version.definition THEN
    RAISE EXCEPTION 'otlet watch pack version requires a canonical definition';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('otlet.watch_pack:' || pack_watch_name, 0));
  SELECT COALESCE(max(version.version_number), 0) + 1
  INTO next_version
  FROM otlet.watch_pack_versions version
  WHERE version.watch_name = pack_watch_name;

  INSERT INTO otlet.watch_pack_versions (
    watch_name,
    version_number,
    content_digest,
    definition
  )
  VALUES (
    pack_watch_name,
    next_version,
    canonical ->> 'content_digest',
    canonical
  )
  RETURNING * INTO saved;

  INSERT INTO otlet.watch_pack_heads (watch_name, version_id, updated_at)
  VALUES (pack_watch_name, saved.id, now())
  ON CONFLICT (watch_name) DO UPDATE
    SET version_id = EXCLUDED.version_id,
        updated_at = now();

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.import_watch(
  definition jsonb,
  replace_existing boolean DEFAULT false
) RETURNS otlet.watches
LANGUAGE plpgsql
AS $$
DECLARE
  watch_name text;
  watch_kind text;
  table_name regclass;
  action_types text[];
  input_columns text[];
  saved otlet.watches%ROWTYPE;
BEGIN
  definition := otlet.validate_watch_pack(import_watch.definition);

  watch_name := import_watch.definition ->> 'name';
  watch_kind := import_watch.definition ->> 'kind';

  IF EXISTS (SELECT 1 FROM otlet.watches w WHERE w.name = watch_name)
     AND NOT COALESCE(import_watch.replace_existing, false) THEN
    RAISE EXCEPTION 'otlet watch % already exists', watch_name;
  END IF;

  IF watch_kind = 'row' THEN
    table_name := to_regclass(import_watch.definition ->> 'table_name');
  END IF;

  SELECT COALESCE(array_agg(value ORDER BY value), ARRAY[]::text[])
  INTO action_types
  FROM jsonb_array_elements_text(import_watch.definition -> 'action_types') value;

  IF jsonb_typeof(import_watch.definition -> 'input_columns') = 'array' THEN
    SELECT COALESCE(array_agg(value ORDER BY value), ARRAY[]::text[])
    INTO input_columns
    FROM jsonb_array_elements_text(import_watch.definition -> 'input_columns') value;
  END IF;

  SELECT * INTO saved
  FROM otlet.create_watch(
    watch_name => watch_name,
    kind => watch_kind,
    instruction => import_watch.definition ->> 'instruction',
    output_schema => import_watch.definition -> 'output_schema',
    model_name => import_watch.definition ->> 'model_name',
    table_name => table_name,
    subject_column => COALESCE(import_watch.definition ->> 'subject_column', 'id'),
    candidate_query => import_watch.definition ->> 'candidate_query',
    record_type => import_watch.definition ->> 'record_type',
    runtime_options => import_watch.definition -> 'runtime_options',
    selection_policy => import_watch.definition -> 'selection_policy',
    trigger_policy => import_watch.definition -> 'trigger_policy',
    action_types => action_types,
    stale_policy => import_watch.definition ->> 'stale_policy',
    input_shaping => import_watch.definition -> 'input_shaping',
    decision_contract => import_watch.definition -> 'decision_contract',
    max_candidate_rows => (import_watch.definition ->> 'max_candidate_rows')::integer,
    input_columns => input_columns,
    pair_sources => import_watch.definition -> 'pair_sources'
  );

  PERFORM otlet.record_watch_pack_version(import_watch.definition);

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.lint_watch_pack(definition jsonb)
RETURNS TABLE(valid boolean, content_digest text)
LANGUAGE sql
AS $$
  SELECT true, otlet.validate_watch_pack($1) ->> 'content_digest';
$$;

CREATE FUNCTION otlet.dry_run_watch_pack(definition jsonb) RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT otlet.validate_watch_pack($1);
$$;

CREATE FUNCTION otlet.diff_watch_packs(before_definition jsonb, after_definition jsonb)
RETURNS TABLE (
  field_name text,
  change_type text,
  before_value jsonb,
  after_value jsonb
)
LANGUAGE sql
AS $$
  WITH packs AS (
    SELECT
      otlet.validate_watch_pack($1) - 'content_digest' AS before_pack,
      otlet.validate_watch_pack($2) - 'content_digest' AS after_pack
  ), fields AS (
    SELECT key
    FROM packs
    CROSS JOIN LATERAL (
      SELECT jsonb_object_keys(before_pack) AS key
      UNION
      SELECT jsonb_object_keys(after_pack) AS key
    ) keys
  )
  SELECT
    fields.key,
    CASE
      WHEN NOT packs.before_pack ? fields.key THEN 'added'
      WHEN NOT packs.after_pack ? fields.key THEN 'removed'
      ELSE 'changed'
    END,
    packs.before_pack -> fields.key,
    packs.after_pack -> fields.key
  FROM packs
  CROSS JOIN fields
  WHERE packs.before_pack -> fields.key IS DISTINCT FROM packs.after_pack -> fields.key
  ORDER BY fields.key;
$$;

CREATE FUNCTION otlet.rollback_watch_pack(
  watch_name text,
  version_number integer
) RETURNS otlet.watches
LANGUAGE plpgsql
AS $$
DECLARE
  definition jsonb;
  saved otlet.watches%ROWTYPE;
BEGIN
  SELECT version.definition
  INTO definition
  FROM otlet.watch_pack_versions version
  WHERE version.watch_name = rollback_watch_pack.watch_name
    AND version.version_number = rollback_watch_pack.version_number;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet watch pack version %.% does not exist', watch_name, version_number;
  END IF;

  SELECT *
  INTO saved
  FROM otlet.import_watch(definition, true);
  RETURN saved;
END;
$$;

CREATE VIEW otlet.watch_pack_history AS
SELECT
  version.id,
  version.watch_name,
  version.version_number,
  version.content_digest,
  head.version_id = version.id AS current_version,
  version.definition -> 'version_metadata' AS version_metadata,
  version.definition ->> 'candidate_query' AS candidate_query,
  version.definition ->> 'instruction' AS instruction,
  version.definition -> 'output_schema' AS output_schema,
  version.definition -> 'selection_policy' AS model_policy,
  version.definition -> 'fixtures' AS fixtures,
  version.definition -> 'labels' AS labels,
  version.definition -> 'expected_receipts' AS expected_receipts,
  version.definition -> 'evaluation_gates' AS evaluation_gates,
  version.created_by,
  version.created_at
FROM otlet.watch_pack_versions version
LEFT JOIN otlet.watch_pack_heads head ON head.watch_name = version.watch_name;

CREATE VIEW otlet.watch_status AS
WITH watch_sources AS (
  SELECT
    COALESCE(w.name, si.name) AS watch_name,
    'row'::text AS kind,
    si.task_name,
    si.name AS semantic_index_name,
    NULL::text AS semantic_join_index_name,
    si.source_table,
    si.subject_column,
    si.input_columns,
    '[]'::jsonb AS pair_sources,
    si.record_type,
    si.model_name,
    NULL::jsonb AS candidate_plan,
    NULL::numeric AS candidate_plan_cost,
    NULL::timestamptz AS candidate_preflight_at,
    COALESCE(w.stale_policy, 'refresh_then_fail_closed') AS stale_policy,
    COALESCE(w.trigger_policy, '{"on_change":"mark_stale"}'::jsonb) AS trigger_policy,
    COALESCE(w.selection_policy, '{}'::jsonb) AS selection_policy
  FROM otlet.semantic_indexes si
  LEFT JOIN otlet.watches w ON w.semantic_index_name = si.name
  UNION ALL
  SELECT
    COALESCE(w.name, ji.name) AS watch_name,
    'pair'::text AS kind,
    ji.task_name,
    NULL::text AS semantic_index_name,
    ji.name AS semantic_join_index_name,
    NULL::text AS source_table,
    NULL::text AS subject_column,
    NULL::text[] AS input_columns,
    COALESCE(w.pair_sources, '[]'::jsonb) AS pair_sources,
    ji.record_type,
    ji.model_name,
    ji.candidate_plan,
    ji.candidate_plan_cost,
    ji.candidate_preflight_at,
    COALESCE(w.stale_policy, 'refresh_then_fail_closed') AS stale_policy,
    COALESCE(w.trigger_policy, '{"on_change":"mark_stale"}'::jsonb) AS trigger_policy,
    COALESCE(w.selection_policy, '{}'::jsonb) AS selection_policy
  FROM otlet.semantic_join_indexes ji
  LEFT JOIN otlet.watches w ON w.semantic_join_index_name = ji.name
), watch_plans AS (
  SELECT w.watch_name, p.*
  FROM (
    SELECT *
    FROM watch_sources
    WHERE kind = 'row'
  ) w
  JOIN LATERAL otlet.semantic_index_plan(w.semantic_index_name) p ON true
  UNION ALL
  SELECT w.watch_name, p.*
  FROM (
    SELECT *
    FROM watch_sources
    WHERE kind = 'pair'
  ) w
  JOIN LATERAL otlet.semantic_join_index_plan(w.semantic_join_index_name) p ON true
), watch_tasks AS (
  SELECT DISTINCT task_name
  FROM watch_sources
), watch_materialization_keys AS (
  SELECT DISTINCT task_name, record_type
  FROM watch_sources
), job_counts AS (
  SELECT
    j.task_name,
    count(*) FILTER (WHERE j.status = 'queued')::bigint AS queued_jobs,
    count(*) FILTER (WHERE j.status = 'running')::bigint AS running_jobs,
    count(*) FILTER (WHERE j.status = 'complete')::bigint AS complete_jobs,
    count(*) FILTER (WHERE j.status IN ('failed', 'canceled'))::bigint AS failed_jobs
  FROM otlet.jobs j
  JOIN watch_tasks USING (task_name)
  GROUP BY j.task_name
), action_counts AS (
  SELECT
    j.task_name,
    count(*) FILTER (WHERE a.status = 'proposed')::bigint AS proposed_actions,
    count(*) FILTER (WHERE a.status = 'complete')::bigint AS complete_actions,
    count(*) FILTER (WHERE a.status = 'rejected')::bigint AS rejected_actions
  FROM otlet.actions a
  JOIN otlet.jobs j ON j.id = a.job_id
  JOIN watch_tasks USING (task_name)
  GROUP BY j.task_name
), suppression AS (
  SELECT
    e.detail ->> 'task_name' AS task_name,
    count(*)::bigint AS suppressed_events,
    max(e.created_at) AS last_suppressed_at
  FROM otlet.worker_events e
  JOIN watch_tasks ON watch_tasks.task_name = e.detail ->> 'task_name'
  WHERE e.event_type = 'queue_admission_suppressed'
    AND e.detail ? 'task_name'
  GROUP BY e.detail ->> 'task_name'
), materialized AS (
  SELECT
    sm.task_name,
    sm.record_type,
    max(sm.updated_at) AS last_materialized_at,
    count(*) FILTER (WHERE sm.freshness_basis = 'revalidated_after_benign_update')::bigint AS revalidated_materializations
  FROM otlet.semantic_materializations sm
  JOIN watch_materialization_keys USING (task_name, record_type)
  GROUP BY sm.task_name, sm.record_type
)
SELECT
  w.watch_name,
  w.kind,
  w.task_name,
  w.semantic_index_name,
  w.semantic_join_index_name,
  w.source_table,
  w.subject_column,
  w.input_columns,
  w.pair_sources,
  w.record_type,
  w.model_name,
  w.candidate_plan,
  w.candidate_plan_cost,
  w.candidate_preflight_at,
  w.stale_policy,
  w.trigger_policy,
  w.selection_policy,
  COALESCE(plan.total_subjects, 0)::bigint AS total_subjects,
  COALESCE(plan.fresh_subjects, 0)::bigint AS fresh_subjects,
  COALESCE(plan.stale_subjects, 0)::bigint AS stale_subjects,
  COALESCE(plan.missing_subjects, 0)::bigint AS missing_subjects,
  COALESCE(plan.inflight_subjects, 0)::bigint AS inflight_subjects,
  COALESCE(plan.queue_subjects, 0)::bigint AS queue_subjects,
  COALESCE(plan.fail_closed_subjects, 0)::bigint AS fail_closed_subjects,
  plan.selected_path,
  plan.reason,
  COALESCE(plan.stale_reasons, '{}'::jsonb) AS stale_reasons,
  COALESCE(plan.freshness, 0)::numeric AS freshness,
  COALESCE(plan.worker_queue_depth, 0)::bigint AS worker_queue_depth,
  COALESCE(plan.available_queue_slots, 0)::bigint AS available_queue_slots,
  COALESCE(plan.count_basis, 'estimated') AS count_basis,
  COALESCE(job_counts.queued_jobs, 0)::bigint AS queued_jobs,
  COALESCE(job_counts.running_jobs, 0)::bigint AS running_jobs,
  COALESCE(job_counts.complete_jobs, 0)::bigint AS complete_jobs,
  COALESCE(job_counts.failed_jobs, 0)::bigint AS failed_jobs,
  COALESCE(action_counts.proposed_actions, 0)::bigint AS proposed_actions,
  COALESCE(action_counts.complete_actions, 0)::bigint AS complete_actions,
  COALESCE(action_counts.rejected_actions, 0)::bigint AS rejected_actions,
  COALESCE(suppression.suppressed_events, 0)::bigint AS queue_admission_suppressed_events,
  suppression.last_suppressed_at AS queue_admission_last_suppressed_at,
  COALESCE(row_index.last_refresh_at, join_index.last_refresh_at) AS last_refresh_at,
  COALESCE(row_index.last_lookup_at, join_index.last_lookup_at) AS last_lookup_at,
  join_index.last_materialized_at AS last_join_materialized_at,
  materialized.last_materialized_at,
  COALESCE(materialized.revalidated_materializations, 0)::bigint AS revalidated_materializations,
  COALESCE(plan.checked_at, now()) AS checked_at
FROM watch_sources w
LEFT JOIN otlet.semantic_indexes row_index ON row_index.name = w.semantic_index_name
LEFT JOIN otlet.semantic_join_indexes join_index ON join_index.name = w.semantic_join_index_name
LEFT JOIN watch_plans plan ON plan.watch_name = w.watch_name
LEFT JOIN job_counts ON job_counts.task_name = w.task_name
LEFT JOIN action_counts ON action_counts.task_name = w.task_name
LEFT JOIN suppression ON suppression.task_name = w.task_name
LEFT JOIN materialized ON materialized.task_name = w.task_name
  AND materialized.record_type = w.record_type;
