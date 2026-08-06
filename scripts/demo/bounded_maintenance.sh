log "Checking bounded maintenance execution"

bounded_maintenance_contract="$(psql_exec -qAt <<'SQL' | tail -n 1
BEGIN;
SET LOCAL statement_timeout = '5000ms';

CREATE FUNCTION pg_temp.assert_true(value boolean, message text) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF value IS DISTINCT FROM true THEN
    RAISE EXCEPTION '%', message;
  END IF;
END;
$$;

CREATE FUNCTION pg_temp.expect_error(statement text, message_fragment text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  BEGIN
    EXECUTE expect_error.statement;
  EXCEPTION WHEN OTHERS THEN
    IF position(expect_error.message_fragment IN SQLERRM) = 0 THEN
      RAISE EXCEPTION 'expected error containing %, got %',
        expect_error.message_fragment,
        SQLERRM;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'expected error containing %, but statement succeeded',
    expect_error.message_fragment;
END;
$$;

SELECT pg_temp.assert_true(
  maintenance_max_rows = 64
    AND maintenance_max_wal_bytes = 16777216
    AND maintenance_max_time_ms = 1000,
  'bounded maintenance policy defaults changed'
)
FROM otlet.production_policy_status;
SELECT pg_temp.expect_error(
  $$SELECT otlet.create_maintenance_run('unknown', NULL, NULL, 1, 1, 1)$$,
  'kind'
);
SELECT pg_temp.expect_error(
  $$SELECT otlet.create_maintenance_run('cleanup', NULL, NULL, 0, 1, 1)$$,
  'row budget'
);
SELECT pg_temp.expect_error(
  $$SELECT otlet.create_maintenance_run('cleanup', NULL, NULL, 1, 0, 1)$$,
  'WAL budget'
);
SELECT pg_temp.expect_error(
  $$SELECT otlet.create_maintenance_run('cleanup', NULL, NULL, 1, 1, 0)$$,
  'time budget'
);
SELECT pg_temp.expect_error(
  $$SELECT * FROM otlet.cleanup_policy_state(false)$$,
  'mutating cleanup requires a bounded maintenance run'
);
SELECT pg_temp.expect_error(
  $$SELECT otlet.cleanup_eval_label_series(clock_timestamp(), false)$$,
  'mutating evaluation label cleanup requires a bounded maintenance run'
);

SELECT otlet.register_model(
  'bounded_maintenance_model',
  '/tmp/bounded-maintenance.gguf',
  repeat('b', 64),
  jsonb_build_object(
    'sha256', repeat('b', 64),
    'bytes', 1,
    'source', 'bounded-maintenance-proof',
    'revision', 'v1',
    'quantization', 'none',
    'license', 'test'
  )
) \g /dev/null
UPDATE otlet.production_policy
SET worker_event_retention = interval '1 day',
    failed_job_retention = interval '1000 years',
    trace_detail_retention = interval '1000 years',
    eval_label_retention = interval '1000 years',
    delete_stale_materialization_retention = interval '1000 years',
    sensitive_evidence_mode = 'diagnostic',
    sensitive_evidence_retention = interval '1000 years'
WHERE name = 'default';

INSERT INTO otlet.worker_events (event_type, created_at)
SELECT 'bounded_maintenance_row', clock_timestamp() - interval '200 years'
FROM generate_series(1, 3);

SELECT otlet.create_maintenance_run(
  'cleanup', NULL, NULL, 2, 16777216, 1000
) AS row_run_id \gset
SELECT otlet.run_maintenance_slice(:row_run_id, 0) \g /dev/null
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1 FROM otlet.worker_events
   WHERE event_type = 'bounded_maintenance_row'),
  'cleanup row budget did not stop after two items'
);
SELECT pg_temp.assert_true(
  processed_items = 2
    AND changed_rows = 2
    AND last_slice_items = 2
    AND last_stop_reason = 'row_budget'
    AND control_state = 'running',
  'cleanup progress did not record its row-budget stop'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :row_run_id;
SELECT otlet.run_maintenance_slice(:row_run_id, 1) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'complete'
    AND processed_items = 3
    AND changed_rows = 3
    AND vacuum_handoff_required
    AND vacuum_relations = ARRAY['otlet.worker_events']::text[]
    AND vacuum_handoff_sql = ARRAY[
      'VACUUM (ANALYZE) otlet.worker_events'
    ]::text[],
  'cleanup completion did not expose its vacuum handoff'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :row_run_id;
SELECT otlet.acknowledge_maintenance_vacuum(
  :row_run_id, 2, 'bounded maintenance proof'
) \g /dev/null
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.acknowledge_maintenance_vacuum(%s, 3, %L)',
    :row_run_id,
    'replacement acknowledgement'
  ),
  'already acknowledged'
);
SELECT pg_temp.assert_true(
  generation = 3
    AND NOT vacuum_handoff_required
    AND vacuum_acknowledgement_reason = 'bounded maintenance proof',
  'vacuum acknowledgement was not generation fenced'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :row_run_id;

INSERT INTO otlet.worker_events (event_type, created_at)
SELECT 'bounded_maintenance_control', clock_timestamp() - interval '200 years'
FROM generate_series(1, 2);
SELECT otlet.create_maintenance_run(
  'cleanup', NULL, NULL, 1, 16777216, 1000
) AS control_run_id \gset
SELECT otlet.run_maintenance_slice(:control_run_id, 0) \g /dev/null
SELECT otlet.set_maintenance_run_state(
  :control_run_id, 1, 'paused', 'proof pause'
) \g /dev/null
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.run_maintenance_slice(%s, 1)',
    :control_run_id
  ),
  'generation changed'
);
SELECT otlet.run_maintenance_slice(:control_run_id, 2) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'paused'
    AND generation = 2
    AND processed_items = 1
    AND last_stop_reason = 'paused',
  'paused maintenance run made progress'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :control_run_id;
SELECT otlet.set_maintenance_run_state(
  :control_run_id, 2, 'running', 'proof resume'
) \g /dev/null
SELECT otlet.run_maintenance_slice(:control_run_id, 3) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'running'
    AND generation = 4
    AND processed_items = 2
    AND last_stop_reason = 'row_budget',
  'resumed maintenance run did not continue at the next item'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :control_run_id;
SELECT otlet.run_maintenance_slice(:control_run_id, 4) \g /dev/null

INSERT INTO otlet.worker_events (event_type, created_at)
VALUES ('bounded_maintenance_cancel', clock_timestamp() - interval '200 years');
SELECT otlet.create_maintenance_run(
  'cleanup', NULL, NULL, 1, 16777216, 1000
) AS canceled_run_id \gset
SELECT otlet.run_maintenance_slice(:canceled_run_id, 0) \g /dev/null
SELECT otlet.set_maintenance_run_state(
  :canceled_run_id, 1, 'canceled', 'proof cancellation'
) \g /dev/null
SELECT otlet.run_maintenance_slice(:canceled_run_id, 2) \g /dev/null
SELECT otlet.acknowledge_maintenance_vacuum(
  :canceled_run_id, 2, 'canceled maintenance proof'
) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'canceled'
    AND generation = 3
    AND processed_items = 1
    AND last_stop_reason = 'canceled'
    AND NOT vacuum_handoff_required,
  'canceled maintenance run lost its terminal handoff'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :canceled_run_id;

INSERT INTO otlet.worker_events (event_type, created_at)
SELECT 'bounded_maintenance_wal', clock_timestamp() - interval '200 years'
FROM generate_series(1, 2);
SELECT otlet.create_maintenance_run(
  'cleanup', NULL, NULL, 64, 1, 1000
) AS wal_run_id \gset
SELECT otlet.run_maintenance_slice(:wal_run_id, 0) \g /dev/null
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1 FROM otlet.worker_events
   WHERE event_type = 'bounded_maintenance_wal')
    AND last_slice_items = 1
    AND last_slice_wal_bytes > 0
    AND last_stop_reason = 'wal_budget',
  'cleanup WAL budget did not stop after its minimum atomic item'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :wal_run_id;
SELECT otlet.run_maintenance_slice(:wal_run_id, 1) \g /dev/null
SELECT otlet.run_maintenance_slice(:wal_run_id, 2) \g /dev/null

CREATE FUNCTION pg_temp.bounded_maintenance_fail_second() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.event_type = 'bounded_maintenance_partial_failure' THEN
    RAISE EXCEPTION '%',
      'bounded maintenance partial failure proof ' || repeat('界', 1500);
  END IF;
  RETURN OLD;
END;
$$;
CREATE TRIGGER bounded_maintenance_fail_second
BEFORE DELETE ON otlet.worker_events
FOR EACH ROW EXECUTE FUNCTION pg_temp.bounded_maintenance_fail_second();
INSERT INTO otlet.worker_events (event_type, created_at)
VALUES
  ('bounded_maintenance_partial_success', clock_timestamp() - interval '200 years'),
  ('bounded_maintenance_partial_failure', clock_timestamp() - interval '200 years');
SELECT otlet.create_maintenance_run(
  'cleanup', NULL, NULL, 64, 16777216, 1000
) AS partial_run_id \gset
SELECT otlet.run_maintenance_slice(:partial_run_id, 0) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'retryable'
    AND processed_items = 1
    AND changed_rows = 1
    AND last_slice_items = 1
    AND last_item_kind = 'worker_event'
    AND last_stop_reason = 'failed'
    AND position('partial failure proof' IN last_error) > 0
    AND octet_length(last_error) <= 4096,
  'partial maintenance failure lost completed progress'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :partial_run_id;
DROP TRIGGER bounded_maintenance_fail_second ON otlet.worker_events;
SELECT otlet.set_maintenance_run_state(
  :partial_run_id, 1, 'retry', 'partial failure cleared'
) \g /dev/null
SELECT otlet.run_maintenance_slice(:partial_run_id, 2) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'complete'
    AND generation = 3
    AND retry_count = 1
    AND processed_items = 2
    AND changed_rows = 2,
  'partial maintenance failure did not resume cleanly'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :partial_run_id;

CREATE FUNCTION pg_temp.bounded_maintenance_delay() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.event_type = 'bounded_maintenance_time' THEN
    PERFORM pg_sleep(0.05);
  END IF;
  RETURN OLD;
END;
$$;
CREATE TRIGGER bounded_maintenance_delay
BEFORE DELETE ON otlet.worker_events
FOR EACH ROW EXECUTE FUNCTION pg_temp.bounded_maintenance_delay();
INSERT INTO otlet.worker_events (event_type, created_at)
SELECT 'bounded_maintenance_time', clock_timestamp() - interval '200 years'
FROM generate_series(1, 2);
SELECT otlet.create_maintenance_run(
  'cleanup', NULL, NULL, 64, 16777216, 1
) AS time_run_id \gset
SELECT otlet.run_maintenance_slice(:time_run_id, 0) \g /dev/null
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1 FROM otlet.worker_events
   WHERE event_type = 'bounded_maintenance_time')
    AND last_slice_items = 1
    AND last_slice_elapsed_ms >= 1
    AND last_stop_reason = 'time_budget',
  'cleanup time budget did not stop after its minimum atomic item'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :time_run_id;
DROP TRIGGER bounded_maintenance_delay ON otlet.worker_events;
SELECT otlet.run_maintenance_slice(:time_run_id, 1) \g /dev/null

SELECT otlet.create_task(
  'bounded_maintenance_archive',
  NULL,
  'Bounded archive proof',
  '{"type":"object"}'::jsonb,
  'bounded_maintenance_model'
) \g /dev/null
SELECT otlet.ensure_active_workload_revision(
  'bounded_maintenance_archive'
) AS archive_revision \gset
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('bounded_maintenance_archive', 'retained', '{}'::jsonb)
RETURNING id AS archive_job_id \gset
SELECT otlet.set_task_lifecycle(
  'bounded_maintenance_archive', 'paused', :'archive_revision'
) \g /dev/null
SELECT otlet.create_maintenance_run(
  'archive', 'bounded_maintenance_archive', :'archive_revision',
  1, 16777216, 1000
) AS archive_run_id \gset
SELECT otlet.run_maintenance_slice(:archive_run_id, 0) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'retryable'
    AND last_stop_reason = 'failed'
    AND position('unfinished jobs' IN last_error) > 0,
  'archive failure did not become retryable'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :archive_run_id;
SELECT count(*) AS archive_event_count
FROM otlet.administrative_change_events
WHERE object_type = 'task'
  AND object_name = 'bounded_maintenance_archive' \gset
SELECT *
FROM otlet.request_job_cancellation(
  :archive_job_id, 'bounded maintenance archive retry'
) \g /dev/null
SELECT otlet.set_maintenance_run_state(
  :archive_run_id, 1, 'retry', 'unfinished job canceled'
) \g /dev/null
SELECT otlet.run_maintenance_slice(:archive_run_id, 2) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'complete'
    AND retry_count = 1
    AND processed_items = 1
    AND vacuum_relations = ARRAY[
      'otlet.administrative_change_events',
      'otlet.semantic_materializations',
      'otlet.semantic_planner_statistics',
      'otlet.tasks'
    ]::text[]
    AND (
      SELECT count(*) = :archive_event_count::bigint + 1
      FROM otlet.administrative_change_events
      WHERE object_type = 'task'
        AND object_name = 'bounded_maintenance_archive'
    ),
  'archive retry did not complete'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :archive_run_id;
SELECT pg_temp.assert_true(
  lifecycle_state = 'retired'
    AND active_workload_revision_hash IS NULL
    AND pinned_workload_revision_hash = :'archive_revision'
    AND terminal_jobs = 1
    AND watch_deletion_blocker = 'retained_task_archive'
    AND EXISTS (
      SELECT 1 FROM otlet.jobs WHERE id = :archive_job_id
    ),
  'archive maintenance did not retain terminal evidence'
)
FROM otlet.task_lifecycle_status
WHERE task_name = 'bounded_maintenance_archive';

CREATE TABLE public.bounded_maintenance_repair_source (
  id text PRIMARY KEY,
  payload text NOT NULL
);
INSERT INTO public.bounded_maintenance_repair_source
VALUES
  ('repair-1', 'payload'),
  ('due-1', 'payload'),
  ('backoff-1', 'payload'),
  ('exhausted-1', 'payload'),
  ('time-1', 'payload');
SELECT otlet.create_watch(
  watch_name => 'bounded_maintenance_repair',
  kind => 'row',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'bounded_maintenance_model',
  table_name => 'public.bounded_maintenance_repair_source'::regclass,
  subject_column => 'id',
  input_columns => ARRAY['id', 'payload'],
  trigger_policy => jsonb_build_object(
    'on_change', 'mark_stale_and_enqueue',
    'max_age_ms', 1000,
    'refresh_window_ms', 500,
    'on_overdue', 'reconcile'
  )
) \g /dev/null
SELECT active_workload_revision_hash AS repair_revision
FROM otlet.workload_revision_heads
WHERE task_name = 'bounded_maintenance_repair_task' \gset
DELETE FROM otlet.semantic_planner_statistics
WHERE task_name = 'bounded_maintenance_repair_task'
  AND workload_revision_hash = :'repair_revision';
SELECT otlet.create_maintenance_run(
  'repair', 'bounded_maintenance_repair_task', :'repair_revision',
  1, 16777216, 1000
) AS repair_run_id \gset
SELECT otlet.run_maintenance_slice(:repair_run_id, 0) \g /dev/null
SELECT pg_temp.assert_true(
  run.control_state = 'complete'
    AND run.processed_items = 1
    AND statistics.count_basis = 'maintained',
  'repair maintenance did not recreate planner statistics'
)
FROM otlet.maintenance_run_status run
JOIN otlet.semantic_planner_statistics_status statistics
  ON statistics.task_name = run.target_name
 AND statistics.workload_revision_hash = run.target_revision_hash
WHERE run.maintenance_run_id = :repair_run_id;

SELECT otlet.record_watch_reconciliation(
  'bounded_maintenance_repair',
  'due-1',
  :'repair_revision',
  otlet.semantic_source_hash(
    otlet.semantic_row_subject_input(:'repair_revision', 'due-1')
  ),
  false
) \g /dev/null
SELECT otlet.create_maintenance_run(
  'reconciliation', NULL, NULL, 1, 16777216, 1000
) AS reconciliation_run_id \gset
SELECT otlet.run_maintenance_slice(:reconciliation_run_id, 0) \g /dev/null
SELECT otlet.run_maintenance_slice(:reconciliation_run_id, 1) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'complete'
    AND generation = 2
    AND processed_items = 1
    AND last_item_kind = 'watch_reconciliation_queued'
    AND EXISTS (
      SELECT 1
      FROM otlet.jobs
      WHERE task_name = 'bounded_maintenance_repair_task'
        AND subject_id = 'due-1'
        AND status = 'queued'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.watch_reconciliation
      WHERE watch_name = 'bounded_maintenance_repair'
        AND subject_id = 'due-1'
    ),
  'reconciliation maintenance did not process a due row'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :reconciliation_run_id;

SELECT otlet.record_watch_reconciliation(
  'bounded_maintenance_repair',
  'backoff-1',
  :'repair_revision',
  otlet.semantic_source_hash(
    otlet.semantic_row_subject_input(:'repair_revision', 'backoff-1')
  ),
  false
) \g /dev/null
UPDATE otlet.watch_reconciliation
SET next_attempt_at = clock_timestamp() + interval '1 day'
WHERE watch_name = 'bounded_maintenance_repair'
  AND subject_id = 'backoff-1';
SELECT otlet.create_maintenance_run(
  'reconciliation', NULL, NULL, 1, 16777216, 1000
) AS backoff_run_id \gset
SELECT otlet.run_maintenance_slice(:backoff_run_id, 0) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'running'
    AND generation = 1
    AND processed_items = 0
    AND last_stop_reason = 'waiting',
  'reconciliation maintenance did not preserve backoff'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :backoff_run_id;
UPDATE otlet.watch_reconciliation
SET next_attempt_at = clock_timestamp()
WHERE watch_name = 'bounded_maintenance_repair'
  AND subject_id = 'backoff-1';
SELECT otlet.run_maintenance_slice(:backoff_run_id, 1) \g /dev/null
SELECT otlet.run_maintenance_slice(:backoff_run_id, 2) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'complete'
    AND generation = 3
    AND processed_items = 1,
  'reconciliation maintenance did not resume a due backoff row'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :backoff_run_id;

SELECT otlet.record_watch_reconciliation(
  'bounded_maintenance_repair',
  'exhausted-1',
  :'repair_revision',
  otlet.semantic_source_hash(
    otlet.semantic_row_subject_input(:'repair_revision', 'exhausted-1')
  ),
  false
) \g /dev/null
UPDATE otlet.watch_reconciliation
SET state = 'exhausted',
    attempts = attempt_limit,
    next_attempt_at = NULL,
    last_error = 'bounded maintenance exhausted proof'
WHERE watch_name = 'bounded_maintenance_repair'
  AND subject_id = 'exhausted-1';
SELECT otlet.create_maintenance_run(
  'reconciliation', NULL, NULL, 1, 16777216, 1000
) AS exhausted_run_id \gset
SELECT otlet.run_maintenance_slice(:exhausted_run_id, 0) \g /dev/null
SELECT otlet.run_maintenance_slice(:exhausted_run_id, 1) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'complete'
    AND processed_items = 1
    AND EXISTS (
      SELECT 1
      FROM otlet.jobs
      WHERE task_name = 'bounded_maintenance_repair_task'
        AND subject_id = 'exhausted-1'
        AND status = 'queued'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.watch_reconciliation
      WHERE watch_name = 'bounded_maintenance_repair'
        AND subject_id = 'exhausted-1'
    ),
  'reconciliation maintenance did not retry exhausted work'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :exhausted_run_id;

WITH fixture AS (
  SELECT watch.*, revision.definition, revision.workload_revision_hash
  FROM otlet.watches watch
  JOIN otlet.workload_revision_heads head ON head.task_name = watch.task_name
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE watch.name = 'bounded_maintenance_repair'
), input AS (
  SELECT fixture.*,
         otlet.semantic_row_subject_input(
           fixture.workload_revision_hash,
           'time-1'
         ) AS value
  FROM fixture
), saved_record AS (
  INSERT INTO otlet.records (record_type, subject_id, body)
  SELECT record_type, 'time-1', '{"status":"seeded"}'::jsonb
  FROM input
  RETURNING id
)
INSERT INTO otlet.semantic_materializations (
  record_id,
  record_type,
  source_table,
  subject_id,
  source_dependencies,
  task_name,
  model_name,
  body,
  stale,
  source_hash,
  content_hash,
  contract_hash,
  freshness_basis,
  created_at,
  updated_at
)
SELECT
  saved_record.id,
  input.record_type,
  input.source_table,
  'time-1',
  otlet.semantic_input_dependencies(input.value),
  input.task_name,
  input.model_name,
  '{"status":"seeded"}'::jsonb,
  false,
  otlet.semantic_source_hash(input.value),
  otlet.semantic_content_hash(
    input.value,
    input.definition #> '{task,input_shaping}'
  ),
  input.workload_revision_hash,
  'content_hash_match',
  clock_timestamp() - interval '2 seconds',
  clock_timestamp() - interval '2 seconds'
FROM input
CROSS JOIN saved_record;
SELECT pg_temp.assert_true(
  EXISTS (
    SELECT 1
    FROM otlet.watch_time_freshness
    WHERE watch_name = 'bounded_maintenance_repair'
      AND subject_id = 'time-1'
      AND refresh_due_at <= statement_timestamp()
      AND attempted_at IS NULL
  ),
  'time reconciliation fixture was not due'
);
SELECT otlet.create_maintenance_run(
  'reconciliation', NULL, NULL, 1, 16777216, 1000
) AS seeded_run_id \gset
SELECT otlet.run_maintenance_slice(:seeded_run_id, 0) \g /dev/null
SELECT otlet.run_maintenance_slice(:seeded_run_id, 1) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'complete'
    AND processed_items = 1
    AND EXISTS (
      SELECT 1
      FROM otlet.watch_time_freshness
      WHERE watch_name = 'bounded_maintenance_repair'
        AND subject_id = 'time-1'
        AND attempted_at IS NOT NULL
    )
    AND EXISTS (
      SELECT 1
      FROM otlet.jobs
      WHERE task_name = 'bounded_maintenance_repair_task'
        AND subject_id = 'time-1'
        AND status = 'queued'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.watch_reconciliation
      WHERE watch_name = 'bounded_maintenance_repair'
        AND subject_id = 'time-1'
    )
    AND position(
      'SKIP LOCKED' IN upper(pg_get_functiondef(
        'otlet.replay_watch_reconciliation(boolean)'::regprocedure
      ))
    ) > 0
    AND vacuum_relations = ARRAY[
      'otlet.jobs',
      'otlet.semantic_materializations',
      'otlet.semantic_planner_statistics',
      'otlet.task_backfill_subjects',
      'otlet.watch_reconciliation',
      'otlet.watch_time_freshness',
      'otlet.worker_events'
    ]::text[],
  'reconciliation maintenance did not seed due time refresh work'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :seeded_run_id;

UPDATE otlet.semantic_materializations
SET stale = true,
    stale_reason = 'source_delete',
    updated_at = clock_timestamp() - interval '2 days'
WHERE task_name = 'bounded_maintenance_repair_task'
  AND subject_id = 'time-1';
UPDATE otlet.production_policy
SET delete_stale_materialization_retention = interval '1 day'
WHERE name = 'default';
SELECT otlet.create_maintenance_run(
  'cleanup', NULL, NULL, 1, 16777216, 1000
) AS cascade_run_id \gset
SELECT otlet.run_maintenance_slice(:cascade_run_id, 0) \g /dev/null
SELECT otlet.run_maintenance_slice(:cascade_run_id, 1) \g /dev/null
SELECT pg_temp.assert_true(
  control_state = 'complete'
    AND changed_rows = 1
    AND vacuum_relations = ARRAY[
      'otlet.semantic_materializations',
      'otlet.semantic_planner_statistics',
      'otlet.watch_time_freshness'
    ]::text[]
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.semantic_materializations
      WHERE task_name = 'bounded_maintenance_repair_task'
        AND subject_id = 'time-1'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.watch_time_freshness
      WHERE watch_name = 'bounded_maintenance_repair'
        AND subject_id = 'time-1'
    ),
  'stale materialization cleanup omitted a cascaded vacuum relation'
)
FROM otlet.maintenance_run_status
WHERE maintenance_run_id = :cascade_run_id;

SELECT pg_temp.assert_true(
  NOT has_table_privilege('public', 'otlet.maintenance_runs', 'SELECT')
    AND NOT has_table_privilege(
      'public', 'otlet.maintenance_run_status', 'SELECT'
    )
    AND NOT has_function_privilege(
      'public',
      'otlet.create_maintenance_run(text,text,text,integer,bigint,integer)',
      'EXECUTE'
    )
    AND NOT has_function_privilege(
      'public',
      'otlet.set_maintenance_run_state(bigint,bigint,text,text)',
      'EXECUTE'
    )
    AND NOT has_function_privilege(
      'public', 'otlet.run_maintenance_slice(bigint,bigint)', 'EXECUTE'
    )
    AND NOT has_function_privilege(
      'public',
      'otlet.acknowledge_maintenance_vacuum(bigint,bigint,text)',
      'EXECUTE'
    ),
  'bounded maintenance privileges are open to PUBLIC'
);
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants()),
  'bounded maintenance left an invariant violation'
);

SELECT 'budgets|cleanup|progress|partial_retry|pause_resume_cancel|wal|time|archive_retry|reconciliation_due_backoff_exhausted_seeded|repair|vacuum|cascade_vacuum|public_closed|invariants_clean';
ROLLBACK;
SQL
)"

skip_locked_contract="$({
  set -euo pipefail
  skip_locked_run_id=""
  skip_locked_holder_pid=""

  bounded_maintenance_skip_locked_cleanup() {
    if [ -n "$skip_locked_holder_pid" ]; then
      kill "$skip_locked_holder_pid" >/dev/null 2>&1 || true
      wait "$skip_locked_holder_pid" >/dev/null 2>&1 || true
    fi
    if [ -n "$skip_locked_run_id" ]; then
      psql_exec -qAt -v run_id="$skip_locked_run_id" >/dev/null 2>&1 <<'SQL' || true
SELECT otlet.set_maintenance_run_state(
  maintenance.id,
  maintenance.generation,
  'canceled',
  'bounded maintenance lock proof cleanup'
)
FROM otlet.maintenance_runs maintenance
WHERE maintenance.id = :'run_id'::bigint
  AND maintenance.control_state IN ('running', 'paused', 'retryable');
SQL
    fi
    psql_exec -qAt >/dev/null 2>&1 <<'SQL' || true
DELETE FROM otlet.worker_events
WHERE id IN (-840000000002, -840000000001);
SQL
  }
  trap bounded_maintenance_skip_locked_cleanup EXIT

  psql_exec -qAt >/dev/null <<'SQL'
SELECT otlet.set_maintenance_run_state(
  maintenance.id,
  maintenance.generation,
  'canceled',
  'bounded maintenance lock proof restart'
)
FROM otlet.maintenance_runs maintenance
WHERE maintenance.kind = 'cleanup'
  AND maintenance.state_reason = 'bounded maintenance lock proof'
  AND maintenance.control_state IN ('running', 'paused', 'retryable');
DELETE FROM otlet.worker_events
WHERE id IN (-840000000002, -840000000001);
INSERT INTO otlet.worker_events (id, event_type, created_at)
VALUES
  (-840000000002, 'bounded_maintenance_locked', clock_timestamp() - interval '200 years'),
  (-840000000001, 'bounded_maintenance_unlocked', clock_timestamp() - interval '200 years');
SQL

  skip_locked_run_id="$(psql_value <<'SQL'
SELECT otlet.create_maintenance_run(
  'cleanup', NULL, NULL, 1, 16777216, 1000
);
SQL
)"
  psql_exec -qAt -v run_id="$skip_locked_run_id" >/dev/null <<'SQL'
SELECT otlet.set_maintenance_run_state(
  :'run_id'::bigint, 0, 'paused', 'bounded maintenance lock proof'
);
SELECT otlet.set_maintenance_run_state(
  :'run_id'::bigint, 1, 'running', 'bounded maintenance lock proof'
);
SQL

  docker exec -e PGAPPNAME=otlet-bounded-maintenance-lock "$container" \
    psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
    -c "BEGIN; SELECT id FROM otlet.worker_events WHERE id = -840000000002 FOR UPDATE; SELECT pg_sleep(5); ROLLBACK" \
    >/dev/null &
  skip_locked_holder_pid=$!

  skip_locked_holder_ready=false
  for _ in {1..100}; do
    if [ "$(psql_value <<'SQL'
SELECT EXISTS (
  SELECT 1
  FROM pg_stat_activity
  WHERE application_name = 'otlet-bounded-maintenance-lock'
    AND wait_event = 'PgSleep'
);
SQL
)" = "t" ]; then
      skip_locked_holder_ready=true
      break
    fi
    sleep 0.05
  done
  [ "$skip_locked_holder_ready" = true ] || {
    echo "Bounded maintenance lock holder did not acquire its row" >&2
    exit 1
  }

  skip_locked_first="$(psql_value -v run_id="$skip_locked_run_id" <<'SQL'
SELECT otlet.run_maintenance_slice(:'run_id'::bigint, 2) \g /dev/null
SELECT concat_ws('|',
  (SELECT count(*) = 1
   FROM otlet.worker_events
   WHERE id IN (-840000000002, -840000000001)),
  EXISTS (
    SELECT 1 FROM otlet.worker_events WHERE id = -840000000002
  ),
  (SELECT generation = 3
          AND last_slice_items = 1
          AND last_stop_reason = 'row_budget'
   FROM otlet.maintenance_run_status
   WHERE maintenance_run_id = :'run_id'::bigint)
);
SQL
)"

  wait "$skip_locked_holder_pid"
  skip_locked_holder_pid=""
  skip_locked_final="$(psql_value -v run_id="$skip_locked_run_id" <<'SQL'
SELECT otlet.run_maintenance_slice(:'run_id'::bigint, 3) \g /dev/null
SELECT otlet.run_maintenance_slice(:'run_id'::bigint, 4) \g /dev/null
SELECT concat_ws('|',
  NOT EXISTS (
    SELECT 1
    FROM otlet.worker_events
    WHERE id IN (-840000000002, -840000000001)
  ),
  (SELECT control_state = 'complete'
          AND generation = 5
          AND processed_items = 2
     FROM otlet.maintenance_run_status
    WHERE maintenance_run_id = :'run_id'::bigint)
);
SQL
)"
  printf '%s|%s\n' "$skip_locked_first" "$skip_locked_final"
})"

[ "$skip_locked_contract" = "t|t|t|t|t" ] || {
  echo "Bounded maintenance SKIP LOCKED mismatch: $skip_locked_contract" >&2
  exit 1
}
bounded_maintenance_contract="$bounded_maintenance_contract|skip_locked"

echo "bounded_maintenance_contract=$bounded_maintenance_contract"
[ "$bounded_maintenance_contract" = "budgets|cleanup|progress|partial_retry|pause_resume_cancel|wal|time|archive_retry|reconciliation_due_backoff_exhausted_seeded|repair|vacuum|cascade_vacuum|public_closed|invariants_clean|skip_locked" ] || {
  echo "Bounded maintenance contract mismatch: $bounded_maintenance_contract" >&2
  exit 1
}

crash_scan
