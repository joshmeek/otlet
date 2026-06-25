CREATE FUNCTION otlet.create_task(
  task_name text,
  input_query text,
  instruction text,
  output_schema jsonb,
  model_name text,
  runtime_options jsonb DEFAULT '{}'::jsonb
) RETURNS otlet.tasks
LANGUAGE sql
AS $$
  INSERT INTO otlet.tasks (name, input_query, instruction, output_schema, model_name, runtime_options)
  VALUES ($1, $2, $3, $4, $5, $6)
  ON CONFLICT (name) DO UPDATE
    SET (input_query, instruction, output_schema, model_name, runtime_options) = (
      EXCLUDED.input_query,
      EXCLUDED.instruction,
      EXCLUDED.output_schema,
      EXCLUDED.model_name,
      EXCLUDED.runtime_options
    )
  RETURNING *;
$$;

CREATE FUNCTION otlet.available_model_queue_slots(model_name text)
RETURNS integer
LANGUAGE sql
STABLE
AS $$
  SELECT GREATEST(
    p.max_queued_jobs_per_model
      - count(j.id) FILTER (WHERE j.status = 'queued'),
    0
  )::integer
  FROM otlet.production_policy p
  LEFT JOIN otlet.tasks t ON t.model_name = $1
  LEFT JOIN otlet.jobs j ON j.task_name = t.name
  GROUP BY p.max_queued_jobs_per_model;
$$;

CREATE FUNCTION otlet.run_task(task_name text) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  model_name text;
  queue_slots integer;
  queued bigint;
BEGIN
  SELECT input_query, tasks.model_name
  INTO query, model_name
  FROM otlet.tasks
  WHERE name = task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', task_name;
  END IF;

  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', task_name;
  END IF;

  SELECT otlet.available_model_queue_slots(model_name) INTO queue_slots;
  IF queue_slots <= 0 THEN
    RETURN 0;
  END IF;

  EXECUTE format(
    'INSERT INTO otlet.jobs (task_name, subject_id, input)
     SELECT %L, subject_id::text, input::jsonb
     FROM (
       SELECT subject_id::text AS subject_id, input::jsonb AS input
       FROM (%s) otlet_input
       ORDER BY subject_id
       LIMIT %s
     ) otlet_bounded_input
     ON CONFLICT (task_name, subject_id)
     WHERE status IN (''queued'', ''running'', ''cancel_requested'')
     DO NOTHING',
    task_name,
    query,
    queue_slots
  );
  GET DIAGNOSTICS queued = ROW_COUNT;
  IF queued > 0 THEN
    PERFORM otlet.wake_worker();
  END IF;

  RETURN queued;
END;
$$;

CREATE FUNCTION otlet.run_task_subject(
  task_name text,
  subject_id text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  model_name text;
  queue_slots integer;
  queued bigint;
BEGIN
  SELECT input_query, tasks.model_name
  INTO query, model_name
  FROM otlet.tasks
  WHERE name = run_task_subject.task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', run_task_subject.task_name;
  END IF;

  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', run_task_subject.task_name;
  END IF;

  SELECT otlet.available_model_queue_slots(model_name) INTO queue_slots;
  IF queue_slots <= 0 THEN
    RETURN 0;
  END IF;

  EXECUTE format(
    'INSERT INTO otlet.jobs (task_name, subject_id, input)
     SELECT %L, subject_id::text, input::jsonb FROM (%s) otlet_input
     WHERE subject_id::text = %L
     ON CONFLICT (task_name, subject_id)
     WHERE status IN (''queued'', ''running'', ''cancel_requested'')
     DO NOTHING',
    run_task_subject.task_name,
    query,
    run_task_subject.subject_id
  );
  GET DIAGNOSTICS queued = ROW_COUNT;
  IF queued > 0 THEN
    PERFORM otlet.wake_worker();
  END IF;

  RETURN queued;
END;
$$;

CREATE FUNCTION otlet.inference_scan_plan(requested_task_name text)
RETURNS TABLE (
  task_name text,
  model_name text,
  runtime_name text,
  input_rows bigint,
  active_rows bigint,
  queueable_rows bigint,
  avg_generate_ms numeric,
  estimated_model_ms numeric,
  model_residency_policy text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  runtime_row otlet.runtimes%ROWTYPE;
  slot_row otlet.runtime_slots%ROWTYPE;
  input_count bigint := 0;
  active_count bigint := 0;
  queueable_count bigint := 0;
  queue_slots integer := 0;
  avg_ms numeric := 1000;
  residency text := 'no_resident_model_slot';
BEGIN
  SELECT *
  INTO task_row
  FROM otlet.tasks t
  WHERE t.name = requested_task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', requested_task_name;
  END IF;

  SELECT *
  INTO model_row
  FROM otlet.models m
  WHERE m.name = task_row.model_name;

  SELECT *
  INTO runtime_row
  FROM otlet.runtimes r
  WHERE r.name = model_row.runtime_name;

  SELECT *
  INTO slot_row
  FROM otlet.runtime_slots s
  WHERE s.runtime_name = model_row.runtime_name
    AND s.model_name = model_row.name;

  IF task_row.input_query IS NOT NULL THEN
    EXECUTE format(
      'SELECT count(*)::bigint FROM (%s) otlet_input',
      task_row.input_query
    )
    INTO input_count;

    EXECUTE format(
      $sql$
        SELECT count(*)::bigint
        FROM (%1$s) otlet_input
        WHERE EXISTS (
          SELECT 1
          FROM otlet.jobs j
          WHERE j.task_name = %2$L
            AND j.subject_id = otlet_input.subject_id::text
            AND j.status IN ('queued', 'running', 'cancel_requested')
        )
      $sql$,
      task_row.input_query,
      task_row.name
    )
    INTO active_count;
  END IF;

  SELECT otlet.available_model_queue_slots(task_row.model_name) INTO queue_slots;
  queueable_count := GREATEST(input_count - active_count, 0);
  avg_ms := COALESCE(NULLIF(slot_row.last_generate_ms, 0), 1000)::numeric;
  residency := CASE
    WHEN slot_row.artifact_path IS NOT NULL THEN 'resident_worker_loaded_model_context'
    WHEN slot_row.status IS NOT NULL THEN 'resident_worker_slot_not_ready'
    ELSE 'no_resident_model_slot'
  END;

  RETURN QUERY
  SELECT
    task_row.name,
    model_row.name,
    runtime_row.name,
    input_count,
    active_count,
    LEAST(queueable_count, GREATEST(queue_slots, 0)::bigint),
    avg_ms,
    LEAST(queueable_count, GREATEST(queue_slots, 0)::bigint)::numeric * avg_ms,
    residency;
END;
$$;
