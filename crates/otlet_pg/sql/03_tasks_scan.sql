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
