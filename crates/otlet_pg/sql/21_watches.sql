CREATE FUNCTION otlet.watch_change_trigger() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  watch_row otlet.watches%ROWTYPE;
  row_input jsonb;
  subject_id text;
BEGIN
  SELECT *
  INTO watch_row
  FROM otlet.watches w
  WHERE w.name = TG_ARGV[1]
    AND w.kind = 'row';

  IF NOT FOUND THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    END IF;
    RETURN NEW;
  END IF;

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

  IF TG_OP <> 'DELETE'
     AND COALESCE(watch_row.trigger_policy ->> 'on_change', 'mark_stale') = 'mark_stale_and_enqueue'
     AND subject_id IS NOT NULL THEN
    PERFORM otlet.run_task_subject(watch_row.task_name, subject_id);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION otlet.watch_semantic_change(
  table_name regclass,
  subject_column text DEFAULT 'id',
  watch_name text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  trigger_name text := 'otlet_watch_' || substr(md5(table_name::text || ':' || subject_column || ':' || COALESCE(watch_name, '')), 1, 16);
BEGIN
  IF watch_name IS NULL OR watch_name = '' THEN
    RAISE EXCEPTION 'otlet watch name is required';
  END IF;

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
    'CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION otlet.watch_change_trigger(%L, %L)',
    trigger_name,
    table_name,
    subject_column,
    watch_name
  );

  RETURN trigger_name;
END;
$$;

CREATE FUNCTION otlet.drop_watch(
  watch_name text
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  watch_row otlet.watches%ROWTYPE;
  trigger_name text;
BEGIN
  SELECT *
  INTO watch_row
  FROM otlet.watches w
  WHERE w.name = drop_watch.watch_name;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF watch_row.kind = 'row'
     AND watch_row.source_table IS NOT NULL
     AND to_regclass(watch_row.source_table) IS NOT NULL THEN
    trigger_name := 'otlet_watch_' || substr(md5(to_regclass(watch_row.source_table)::text || ':' || watch_row.subject_column || ':' || watch_row.name), 1, 16);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trigger_name, watch_row.source_table);
  END IF;

  DELETE FROM otlet.watches w
  WHERE w.name = watch_row.name;

  IF watch_row.kind = 'row' AND watch_row.semantic_index_name IS NOT NULL THEN
    PERFORM otlet.drop_watch_row_index(watch_row.semantic_index_name);
  ELSIF watch_row.kind = 'pair' AND watch_row.semantic_join_index_name IS NOT NULL THEN
    PERFORM otlet.drop_watch_pair_index(watch_row.semantic_join_index_name);
  END IF;

  RETURN true;
END;
$$;

CREATE FUNCTION otlet.create_watch(
  watch_name text,
  kind text,
  instruction text,
  output_schema jsonb,
  model_name text,
  table_name regclass DEFAULT NULL,
  subject_column text DEFAULT 'id',
  candidate_query text DEFAULT NULL,
  record_type text DEFAULT NULL,
  runtime_options jsonb DEFAULT '{}'::jsonb,
  selection_policy jsonb DEFAULT '{}'::jsonb,
  trigger_policy jsonb DEFAULT '{"on_change":"mark_stale"}'::jsonb,
  action_types text[] DEFAULT '{}'::text[],
  stale_policy text DEFAULT 'refresh_then_fail_closed',
  input_shaping jsonb DEFAULT '{}'::jsonb,
  decision_contract jsonb DEFAULT '{}'::jsonb,
  max_candidate_rows integer DEFAULT 1000
) RETURNS otlet.watches
LANGUAGE plpgsql
AS $$
DECLARE
  actual_kind text := lower(COALESCE(create_watch.kind, ''));
  actual_record_type text := COALESCE(create_watch.record_type, create_watch.watch_name);
  actual_runtime_options jsonb := COALESCE(create_watch.runtime_options, '{}'::jsonb);
  actual_selection_policy jsonb := COALESCE(create_watch.selection_policy, '{}'::jsonb);
  actual_trigger_policy jsonb := COALESCE(create_watch.trigger_policy, '{"on_change":"mark_stale"}'::jsonb);
  actual_action_types text[] := COALESCE(create_watch.action_types, '{}'::text[]);
  actual_stale_policy text := COALESCE(create_watch.stale_policy, 'refresh_then_fail_closed');
  actual_input_shaping jsonb := COALESCE(create_watch.input_shaping, '{}'::jsonb);
  actual_decision_contract jsonb := COALESCE(create_watch.decision_contract, '{}'::jsonb);
  actual_max_candidate_rows integer := GREATEST(1, LEAST(COALESCE(create_watch.max_candidate_rows, 1000), 100000));
  source_table_name text;
  task_name text;
  row_index otlet.semantic_indexes%ROWTYPE;
  join_index otlet.semantic_join_indexes%ROWTYPE;
  saved otlet.watches%ROWTYPE;
  cheap_model_name text;
  strong_model_name text;
BEGIN
  IF create_watch.watch_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet watch name % must be a simple identifier', create_watch.watch_name;
  END IF;
  IF actual_kind NOT IN ('row', 'pair') THEN
    RAISE EXCEPTION 'otlet watch kind % must be row or pair', create_watch.kind;
  END IF;
  IF jsonb_typeof(create_watch.output_schema) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch output_schema must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_runtime_options) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch runtime_options must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_selection_policy) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch selection_policy must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_trigger_policy) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch trigger_policy must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_input_shaping) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch input_shaping must be a JSON object';
  END IF;
  IF jsonb_typeof(actual_decision_contract) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet watch decision_contract must be a JSON object';
  END IF;
  IF COALESCE(actual_trigger_policy ->> 'on_change', 'mark_stale') NOT IN ('mark_stale', 'mark_stale_and_enqueue') THEN
    RAISE EXCEPTION 'otlet watch trigger_policy.on_change must be mark_stale or mark_stale_and_enqueue';
  END IF;
  IF actual_stale_policy NOT IN ('lookup_only_fail_closed', 'refresh_then_fail_closed') THEN
    RAISE EXCEPTION 'otlet watch stale_policy % is not supported', actual_stale_policy;
  END IF;

  IF EXISTS (SELECT 1 FROM otlet.watches w WHERE w.name = create_watch.watch_name) THEN
    PERFORM otlet.drop_watch(create_watch.watch_name);
  END IF;

  IF actual_kind = 'row' THEN
    IF create_watch.table_name IS NULL THEN
      RAISE EXCEPTION 'otlet row watch % requires table_name', create_watch.watch_name;
    END IF;

    SELECT format('%I.%I', n.nspname, c.relname)
    INTO source_table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = create_watch.table_name;

    SELECT *
    INTO row_index
    FROM otlet.create_watch_row_index(
      index_name => create_watch.watch_name,
      table_name => create_watch.table_name,
      subject_column => create_watch.subject_column,
      instruction => create_watch.instruction,
      output_schema => create_watch.output_schema,
      model_name => create_watch.model_name,
      runtime_options => actual_runtime_options,
      record_type => actual_record_type,
      input_shaping => actual_input_shaping,
      decision_contract => actual_decision_contract
    );
    task_name := row_index.task_name;
  ELSE
    IF NULLIF(create_watch.candidate_query, '') IS NULL THEN
      RAISE EXCEPTION 'otlet pair watch % requires candidate_query', create_watch.watch_name;
    END IF;

    SELECT *
    INTO join_index
    FROM otlet.create_watch_pair_index(
      index_name => create_watch.watch_name,
      candidate_query => create_watch.candidate_query,
      instruction => create_watch.instruction,
      output_schema => create_watch.output_schema,
      model_name => create_watch.model_name,
      record_type => actual_record_type,
      runtime_options => actual_runtime_options,
      max_candidate_rows => actual_max_candidate_rows,
      input_shaping => actual_input_shaping,
      decision_contract => actual_decision_contract
    );
    task_name := join_index.task_name;
  END IF;

  INSERT INTO otlet.watches (
    name,
    kind,
    task_name,
    semantic_index_name,
    semantic_join_index_name,
    source_table,
    subject_column,
    candidate_query,
    output_schema,
    action_types,
    stale_policy,
    selection_policy,
    trigger_policy,
    input_shaping,
    decision_contract,
    model_name,
    record_type,
    runtime_options,
    max_candidate_rows,
    updated_at
  )
  VALUES (
    create_watch.watch_name,
    actual_kind,
    task_name,
    CASE WHEN actual_kind = 'row' THEN row_index.name END,
    CASE WHEN actual_kind = 'pair' THEN join_index.name END,
    CASE WHEN actual_kind = 'row' THEN source_table_name END,
    CASE WHEN actual_kind = 'row' THEN create_watch.subject_column END,
    CASE WHEN actual_kind = 'pair' THEN create_watch.candidate_query END,
    create_watch.output_schema,
    actual_action_types,
    actual_stale_policy,
    actual_selection_policy,
    actual_trigger_policy,
    actual_input_shaping,
    actual_decision_contract,
    create_watch.model_name,
    actual_record_type,
    actual_runtime_options,
    actual_max_candidate_rows,
    now()
  )
  RETURNING * INTO saved;

  cheap_model_name := COALESCE(
    actual_selection_policy ->> 'cheap_model_name',
    actual_selection_policy ->> 'cheap_model'
  );
  strong_model_name := COALESCE(
    actual_selection_policy ->> 'strong_model_name',
    actual_selection_policy ->> 'strong_model'
  );

  IF cheap_model_name IS NOT NULL OR strong_model_name IS NOT NULL THEN
    IF cheap_model_name IS NULL OR strong_model_name IS NULL THEN
      RAISE EXCEPTION 'otlet watch selection_policy requires both cheap_model_name and strong_model_name';
    END IF;

    PERFORM otlet.set_model_selection_policy(
      saved.task_name,
      cheap_model_name,
      strong_model_name,
      actual_selection_policy -> 'accept_field_checks'
    );
  END IF;

  IF saved.kind = 'row'
     AND COALESCE(saved.trigger_policy ->> 'on_change', 'mark_stale') = 'mark_stale_and_enqueue' THEN
    PERFORM otlet.watch_semantic_change(create_watch.table_name, saved.subject_column, saved.name);
  END IF;

  RETURN saved;
END;
$$;

CREATE VIEW otlet.watch_status AS
WITH watch_plans AS (
  SELECT w.name AS watch_name, p.*
  FROM (
    SELECT *
    FROM otlet.watches
    WHERE kind = 'row'
      AND semantic_index_name IS NOT NULL
  ) w
  JOIN LATERAL otlet.semantic_index_plan(w.semantic_index_name) p ON true
  UNION ALL
  SELECT w.name AS watch_name, p.*
  FROM (
    SELECT *
    FROM otlet.watches
    WHERE kind = 'pair'
      AND semantic_join_index_name IS NOT NULL
  ) w
  JOIN LATERAL otlet.semantic_join_index_plan(w.semantic_join_index_name) p ON true
)
SELECT
  w.name AS watch_name,
  w.kind,
  w.task_name,
  w.semantic_index_name,
  w.semantic_join_index_name,
  w.source_table,
  w.subject_column,
  w.record_type,
  w.model_name,
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
  COALESCE(plan.freshness, 0)::numeric AS freshness,
  COALESCE(plan.worker_queue_depth, 0)::bigint AS worker_queue_depth,
  COALESCE(plan.available_queue_slots, 0)::bigint AS available_queue_slots,
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
  COALESCE(plan.checked_at, now()) AS checked_at
FROM otlet.watches w
LEFT JOIN otlet.semantic_indexes row_index ON row_index.name = w.semantic_index_name
LEFT JOIN otlet.semantic_join_indexes join_index ON join_index.name = w.semantic_join_index_name
LEFT JOIN watch_plans plan ON plan.watch_name = w.name
LEFT JOIN LATERAL (
  SELECT
    count(*) FILTER (WHERE j.status = 'queued')::bigint AS queued_jobs,
    count(*) FILTER (WHERE j.status = 'running')::bigint AS running_jobs,
    count(*) FILTER (WHERE j.status = 'complete')::bigint AS complete_jobs,
    count(*) FILTER (WHERE j.status IN ('failed', 'canceled'))::bigint AS failed_jobs
  FROM otlet.jobs j
  WHERE j.task_name = w.task_name
) job_counts ON true
LEFT JOIN LATERAL (
  SELECT
    count(*) FILTER (WHERE a.status = 'proposed')::bigint AS proposed_actions,
    count(*) FILTER (WHERE a.status = 'complete')::bigint AS complete_actions,
    count(*) FILTER (WHERE a.status = 'rejected')::bigint AS rejected_actions
  FROM otlet.actions a
  JOIN otlet.jobs j ON j.id = a.job_id
  WHERE j.task_name = w.task_name
) action_counts ON true
LEFT JOIN LATERAL (
  SELECT
    count(*)::bigint AS suppressed_events,
    max(e.created_at) AS last_suppressed_at
  FROM otlet.worker_events e
  WHERE e.event_type = 'queue_admission_suppressed'
    AND e.detail ->> 'task_name' = w.task_name
) suppression ON true
LEFT JOIN LATERAL (
  SELECT max(sm.updated_at) AS last_materialized_at
  FROM otlet.semantic_materializations sm
  WHERE sm.task_name = w.task_name
    AND sm.record_type = w.record_type
) materialized ON true;
