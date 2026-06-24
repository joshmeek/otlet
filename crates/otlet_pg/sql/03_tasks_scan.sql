CREATE FUNCTION otlet.register_task(
  task_name text,
  instruction text,
  output_schema jsonb,
  model_name text,
  runtime_options jsonb DEFAULT '{}'::jsonb
) RETURNS otlet.tasks
LANGUAGE sql
AS $$
  INSERT INTO otlet.tasks (name, input_query, instruction, output_schema, model_name, runtime_options)
  VALUES ($1, NULL, $2, $3, $4, $5)
  ON CONFLICT (name) DO UPDATE
    SET (input_query, instruction, output_schema, model_name, runtime_options) = (
      NULL,
      EXCLUDED.instruction,
      EXCLUDED.output_schema,
      EXCLUDED.model_name,
      EXCLUDED.runtime_options
    )
  RETURNING *;
$$;

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

CREATE FUNCTION otlet.run_task(task_name text) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  queued bigint;
BEGIN
  SELECT input_query
  INTO query
  FROM otlet.tasks
  WHERE name = task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', task_name;
  END IF;

  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', task_name;
  END IF;

  EXECUTE format(
    'INSERT INTO otlet.jobs (task_name, subject_id, input)
     SELECT %L, subject_id::text, input::jsonb FROM (%s) otlet_input
     ON CONFLICT (task_name, subject_id)
     WHERE status IN (''queued'', ''running'', ''cancel_requested'')
     DO NOTHING',
    task_name,
    query
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
  queued bigint;
BEGIN
  SELECT input_query
  INTO query
  FROM otlet.tasks
  WHERE name = run_task_subject.task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', run_task_subject.task_name;
  END IF;

  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', run_task_subject.task_name;
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

CREATE FUNCTION otlet.inference_scan(task_name text)
RETURNS TABLE (job_id bigint, subject_id text, input jsonb)
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  queued bigint;
BEGIN
  SELECT input_query
  INTO query
  FROM otlet.tasks
  WHERE name = inference_scan.task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', inference_scan.task_name;
  END IF;

  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', inference_scan.task_name;
  END IF;

  RETURN QUERY EXECUTE format(
    'INSERT INTO otlet.jobs (task_name, subject_id, input)
     SELECT %L, subject_id::text, input::jsonb FROM (%s) otlet_input
     ON CONFLICT (task_name, subject_id)
     WHERE status IN (''queued'', ''running'', ''cancel_requested'')
     DO NOTHING
     RETURNING id, subject_id, input',
    inference_scan.task_name,
    query
  );
  GET DIAGNOSTICS queued = ROW_COUNT;
  IF queued > 0 THEN
    PERFORM otlet.wake_worker();
  END IF;
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
    queueable_count,
    avg_ms,
    queueable_count::numeric * avg_ms,
    residency;
END;
$$;

CREATE FUNCTION otlet.explain_inference_plan(task_name text)
RETURNS TABLE (step_order int, node text, detail jsonb)
LANGUAGE sql
AS $$
  WITH scan_plan AS (
    SELECT *
    FROM otlet.inference_scan_plan($1)
  )
  SELECT *
  FROM (
    VALUES
      (1, 'TaskInputScan', jsonb_build_object('task_name', $1)),
      (2, 'QueueInsert', jsonb_build_object('table', 'otlet.jobs', 'active_dedupe', 'jobs_active_subject_idx')),
      (3, 'CommitLatchWake', jsonb_build_object('handoff', 'shared_memory_xact_commit_latch', 'state', 'otlet.worker_wake_state')),
      (4, 'WarmSlotAffinity', jsonb_build_object('table', 'otlet.runtime_slots', 'claim_order', 'ready matching artifact first')),
      (5, 'InferenceScanCost', (
        SELECT jsonb_build_object(
          'source', 'otlet.inference_scan_plan',
          'input_rows', input_rows,
          'active_rows', active_rows,
          'queueable_rows', queueable_rows,
          'avg_generate_ms', avg_generate_ms,
          'estimated_model_ms', estimated_model_ms,
          'model_residency_policy', model_residency_policy
        )
        FROM scan_plan
      )),
      (6, 'WorkerAdmission', jsonb_build_object(
        'table', 'otlet.worker_scheduler_status',
        'model_cap', 'otlet.models.max_active_jobs'
      )),
      (7, 'ResidentWorkerClaim', jsonb_build_object('lock', 'FOR UPDATE OF otlet.jobs SKIP LOCKED')),
      (8, 'LinkedResidentModel', jsonb_build_object('runtime', 'linked in-process llama.cpp', 'cache', 'one warm model/context per worker')),
      (9, 'LinkedResourceOwnership', jsonb_build_object(
        'model_handle_owner', 'Rust LinkedCache in resident worker process',
        'context_handle_owner', 'Rust LinkedCache in resident worker process',
        'drop_order', 'llama_context_freed_before_llama_model',
        'resource_scope', 'process_local_rebuilt_on_worker_restart',
        'inference_cache_owner', 'bounded Mutex<InferenceCache> in resident worker process',
        'persistent_blob_policy', 'no_prompt_token_logit_blob_cache'
      )),
      (10, 'MVCCResidentInferenceCache', jsonb_build_object('scope', 'bounded worker memory', 'keys', ARRAY['task','model','model_fingerprint','runtime_options','input_hash','schema_hash','row_version_identity'])),
      (11, 'KVReset', jsonb_build_object('reason', 'clear llama.cpp memory before each job while keeping model resident')),
      (12, 'CancellationGate', jsonb_build_object(
        'state', 'cancel_requested suppresses output/action materialization',
        'linked_policy', 'cooperative_before_prompt_decode_after_prompt_decode_and_each_generated_token',
        'prompt_decode_boundary', 'llama_decode_blocking_checked_before_and_after',
        'rss_budget_policy', 'runtime_options.max_worker_rss_bytes_fail_closed_no_output_action_record_materialization'
      )),
      (13, 'OutputValidation', jsonb_build_object('schema', 'otlet.tasks.output_schema')),
      (14, 'ReceiptMaterialization', jsonb_build_object('tables', ARRAY['otlet.outputs','otlet.actions','otlet.inference_receipts'])),
      (15, 'ReceiptTrace', jsonb_build_object(
        'scope', 'bounded compact receipt metadata plus opt-in bounded token steps',
        'fields', ARRAY['prompt_tokens','generated_tokens','generate_ms','tokens_per_second','trace_version','probability_summary','schema_force','worker_process_rss_bytes','worker_process_virtual_bytes','worker_memory_sample_policy','worker_memory_budget_bytes','worker_memory_budget_policy','detailed_trace.status','detailed_trace.steps','detailed_trace.chosen_token_ids','detailed_trace.top_alternatives'],
        'detailed_trace_contract', 'receipt_trace_v2_bounded_token_steps',
        'enable_policy', 'runtime_options.generation_trace=true bounded by generation_trace_max_tokens and generation_trace_top_k',
        'storage_policy', 'no unbounded persistent prompt token or logit blob cache'
      )),
      (16, 'ExecutorPathDecision', jsonb_build_object(
        'queue_node', 'Function Scan on otlet.inference_scan',
        'native_semantic_node', 'Foreign Scan via otlet_semantic_fdw plus Custom Scan via set_rel_pathlist_hook for row predicates and projected semantic_join_matches/program/operator candidate row sources',
        'custom_scan_node', 'Otlet Semantic Source CustomScan owned PG-created child scan over source rows or bounded join candidate subqueries',
        'reason', 'inference_scan remains the queueing primitive; semantic FDW scans materialized model state and typed semantic predicates can plan as a CustomScan-owned PG-created semantic-filter-free child scan with semantic state classification, automatic lookup/wait/infer/refresh/fail-closed policy for rows and bounded semantic join candidate rows'
      ))
  ) AS plan(step_order, node, detail);
$$;

CREATE FUNCTION otlet.infer_async(
  infer_task_name text,
  infer_subject_id text,
  infer_input jsonb
) RETURNS otlet.jobs
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.jobs%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM otlet.tasks WHERE name = infer_async.infer_task_name) THEN
    RAISE EXCEPTION 'otlet task % does not exist', infer_async.infer_task_name;
  END IF;

  INSERT INTO otlet.jobs (task_name, subject_id, input)
  VALUES (infer_async.infer_task_name, infer_async.infer_subject_id, infer_async.infer_input)
  ON CONFLICT (task_name, subject_id)
  WHERE status IN ('queued', 'running', 'cancel_requested')
  DO NOTHING
  RETURNING * INTO saved;

  IF NOT FOUND THEN
    SELECT * INTO saved
    FROM otlet.jobs
    WHERE task_name = infer_async.infer_task_name
      AND subject_id = infer_async.infer_subject_id
      AND status IN ('queued', 'running', 'cancel_requested')
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    PERFORM otlet.wake_worker();
  END IF;

  RETURN saved;
END;
$$;
