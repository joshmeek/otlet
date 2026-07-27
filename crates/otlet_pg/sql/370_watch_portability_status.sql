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
    )
  )
  INTO definition
  FROM otlet.watches w
  JOIN otlet.tasks t ON t.name = w.task_name
  JOIN otlet.models m ON m.name = w.model_name
  WHERE w.name = export_watch.watch_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet watch % does not exist', watch_name;
  END IF;

  RETURN definition;
END;
$$;

CREATE FUNCTION otlet.import_watch(
  definition jsonb,
  replace_existing boolean DEFAULT false
) RETURNS otlet.watches
LANGUAGE plpgsql
AS $$
DECLARE
  allowed_keys constant text[] := ARRAY[
    'format',
    'name',
    'kind',
    'instruction',
    'output_schema',
    'model_name',
    'model_artifact_identity',
    'table_name',
    'subject_column',
    'candidate_query',
    'record_type',
    'runtime_options',
    'selection_policy',
    'trigger_policy',
    'action_types',
    'stale_policy',
    'input_shaping',
    'decision_contract',
    'max_candidate_rows',
    'input_columns',
    'pair_sources'
  ];
  object_key text;
  object_field text;
  array_field text;
  watch_name text;
  watch_kind text;
  table_name regclass;
  action_types text[];
  input_columns text[];
  saved otlet.watches%ROWTYPE;
BEGIN
  IF jsonb_typeof(import_watch.definition) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch definition must be a JSON object';
  END IF;

  SELECT key INTO object_key
  FROM jsonb_object_keys(import_watch.definition) key
  WHERE NOT key = ANY(allowed_keys)
  ORDER BY key
  LIMIT 1;
  IF object_key IS NOT NULL THEN
    RAISE EXCEPTION 'otlet watch definition has unsupported key %', object_key;
  END IF;

  SELECT key INTO object_key
  FROM unnest(allowed_keys) key
  WHERE NOT import_watch.definition ? key
  ORDER BY key
  LIMIT 1;
  IF object_key IS NOT NULL THEN
    RAISE EXCEPTION 'otlet watch definition is missing key %', object_key;
  END IF;

  IF import_watch.definition ->> 'format' IS DISTINCT FROM 'otlet.watch.v1' THEN
    RAISE EXCEPTION 'otlet watch definition format must be otlet.watch.v1';
  END IF;

  FOREACH object_key IN ARRAY ARRAY['name', 'kind', 'instruction', 'model_name', 'record_type', 'stale_policy'] LOOP
    IF jsonb_typeof(import_watch.definition -> object_key) IS DISTINCT FROM 'string'
       OR NULLIF(import_watch.definition ->> object_key, '') IS NULL THEN
      RAISE EXCEPTION 'otlet watch definition % must be a non-empty string', object_key;
    END IF;
  END LOOP;

  IF jsonb_typeof(import_watch.definition -> 'output_schema') IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch definition output_schema must be an object';
  END IF;

  FOREACH object_field IN ARRAY ARRAY[
    'runtime_options',
    'selection_policy',
    'trigger_policy',
    'input_shaping',
    'decision_contract',
    'model_artifact_identity'
  ] LOOP
    IF jsonb_typeof(import_watch.definition -> object_field) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'otlet watch definition % must be an object', object_field;
    END IF;
  END LOOP;

  FOREACH array_field IN ARRAY ARRAY['action_types', 'pair_sources'] LOOP
    IF jsonb_typeof(import_watch.definition -> array_field) IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'otlet watch definition % must be an array', array_field;
    END IF;
  END LOOP;
  IF NOT import_watch.definition ? 'input_columns'
     OR jsonb_typeof(import_watch.definition -> 'input_columns') NOT IN ('array', 'null') THEN
    RAISE EXCEPTION 'otlet watch definition input_columns must be an array or null';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(import_watch.definition -> 'action_types') item(value)
    WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'string'
  ) THEN
    RAISE EXCEPTION 'otlet watch definition action_types entries must be strings';
  END IF;
  IF jsonb_typeof(import_watch.definition -> 'input_columns') = 'array'
     AND EXISTS (
       SELECT 1
       FROM jsonb_array_elements(import_watch.definition -> 'input_columns') item(value)
       WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'string'
     ) THEN
    RAISE EXCEPTION 'otlet watch definition input_columns entries must be strings';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(import_watch.definition -> 'pair_sources') item(value)
    WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'object'
  ) THEN
    RAISE EXCEPTION 'otlet watch definition pair_sources entries must be objects';
  END IF;

  IF jsonb_typeof(import_watch.definition -> 'max_candidate_rows') IS DISTINCT FROM 'number'
     OR (import_watch.definition ->> 'max_candidate_rows') !~ '^[1-9][0-9]*$'
     OR (import_watch.definition ->> 'max_candidate_rows')::numeric > 100000 THEN
    RAISE EXCEPTION 'otlet watch definition max_candidate_rows must be an integer between 1 and 100000';
  END IF;

  watch_name := import_watch.definition ->> 'name';
  watch_kind := import_watch.definition ->> 'kind';
  IF watch_kind NOT IN ('row', 'pair') THEN
    RAISE EXCEPTION 'otlet watch definition kind must be row or pair';
  END IF;

  PERFORM 1 FROM otlet.models m WHERE m.name = import_watch.definition ->> 'model_name';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet watch definition model % does not exist', import_watch.definition ->> 'model_name';
  END IF;
  PERFORM 1
  FROM otlet.models m
  WHERE m.name = import_watch.definition ->> 'model_name'
    AND m.artifact_identity = import_watch.definition -> 'model_artifact_identity';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet watch definition model artifact identity does not match registered model %', import_watch.definition ->> 'model_name';
  END IF;

  IF EXISTS (SELECT 1 FROM otlet.watches w WHERE w.name = watch_name)
     AND NOT COALESCE(import_watch.replace_existing, false) THEN
    RAISE EXCEPTION 'otlet watch % already exists', watch_name;
  END IF;

  IF watch_kind = 'row' THEN
    IF jsonb_typeof(import_watch.definition -> 'table_name') IS DISTINCT FROM 'string'
       OR NULLIF(import_watch.definition ->> 'table_name', '') IS NULL THEN
      RAISE EXCEPTION 'otlet row watch definition requires table_name';
    END IF;
    IF jsonb_typeof(import_watch.definition -> 'subject_column') IS DISTINCT FROM 'string'
       OR NULLIF(import_watch.definition ->> 'subject_column', '') IS NULL THEN
      RAISE EXCEPTION 'otlet row watch definition requires subject_column';
    END IF;
    IF import_watch.definition -> 'candidate_query' <> 'null'::jsonb
       OR import_watch.definition -> 'pair_sources' <> '[]'::jsonb THEN
      RAISE EXCEPTION 'otlet row watch definition cannot declare pair fields';
    END IF;
    table_name := to_regclass(import_watch.definition ->> 'table_name');
    IF table_name IS NULL THEN
      RAISE EXCEPTION 'otlet row watch definition table % does not exist', import_watch.definition ->> 'table_name';
    END IF;
  ELSE
    IF jsonb_typeof(import_watch.definition -> 'candidate_query') IS DISTINCT FROM 'string'
       OR NULLIF(import_watch.definition ->> 'candidate_query', '') IS NULL THEN
      RAISE EXCEPTION 'otlet pair watch definition requires candidate_query';
    END IF;
    IF import_watch.definition -> 'table_name' <> 'null'::jsonb
       OR import_watch.definition -> 'subject_column' <> 'null'::jsonb
       OR import_watch.definition -> 'input_columns' <> 'null'::jsonb THEN
      RAISE EXCEPTION 'otlet pair watch definition cannot declare row fields';
    END IF;
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

  RETURN saved;
END;
$$;

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
