log "Proving task and watch operational lifecycle"

task_watch_lifecycle_contract="$(psql_exec -qAt <<'SQL' | tail -n 1
BEGIN;
SET LOCAL statement_timeout = '3000ms';

CREATE FUNCTION pg_temp.assert_true(condition boolean, failure text) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
  IF assert_true.condition IS NOT TRUE THEN
    RAISE EXCEPTION '%', assert_true.failure;
  END IF;
END
$body$;

CREATE FUNCTION pg_temp.expect_error(statement text, message_fragment text) RETURNS void
LANGUAGE plpgsql
AS $body$
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
END
$body$;

SELECT otlet.register_model(
  'task_watch_lifecycle_model',
  '/tmp/task-watch-lifecycle.gguf',
  repeat('a', 64),
  jsonb_build_object(
    'sha256', repeat('a', 64),
    'bytes', 1,
    'source', 'fixture',
    'revision', 'lifecycle',
    'quantization', 'none',
    'license', 'test'
  )
) \g /dev/null

SELECT otlet.create_task(
  'task_lifecycle_demo',
  NULL,
  'Return an empty object',
  '{"type":"object"}'::jsonb,
  'task_watch_lifecycle_model'
) \g /dev/null

CREATE TEMP TABLE task_lifecycle_revisions AS
SELECT otlet.ensure_active_workload_revision('task_lifecycle_demo') AS revision_a,
       NULL::text AS revision_b;

INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('task_lifecycle_demo', 'queued-before-pause', '{}'::jsonb);

SELECT otlet.set_task_lifecycle(
  'task_lifecycle_demo',
  'paused',
  (SELECT revision_a FROM task_lifecycle_revisions)
) \g /dev/null

SELECT pg_temp.assert_true(
  (
    SELECT lifecycle_state = 'paused'
       AND active_workload_revision_hash IS NULL
       AND pinned_workload_revision_hash = (SELECT revision_a FROM task_lifecycle_revisions)
       AND queued_jobs = 1
    FROM otlet.task_lifecycle_status
    WHERE task_name = 'task_lifecycle_demo'
  ),
  'pause did not remove execution authority at the pinned revision'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$UPDATE otlet.tasks
    SET lifecycle_state = 'retired'
    WHERE name = 'task_lifecycle_demo'$$,
  'require set_task_lifecycle'
) \g /dev/null
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.set_task_lifecycle(%L, %L, %L)',
    'task_lifecycle_demo',
    'retired',
    (SELECT revision_a FROM task_lifecycle_revisions)
  ),
  'unfinished jobs'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$SELECT otlet.admit_task_input('task_lifecycle_demo', 'blocked', '{}'::jsonb)$$,
  'is paused'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$INSERT INTO otlet.jobs (task_name, subject_id, input)
    VALUES ('task_lifecycle_demo', 'raw-blocked', '{}'::jsonb)$$,
  'is paused'
) \g /dev/null
SELECT pg_temp.assert_true(
  (SELECT count(*) = 0 FROM otlet.claim_jobs('task_watch_lifecycle_model', 1)),
  'paused queued work remained claimable'
) \g /dev/null

UPDATE otlet.tasks
SET instruction = 'Return a different empty object'
WHERE name = 'task_lifecycle_demo';
UPDATE task_lifecycle_revisions
SET revision_b = otlet.promote_configured_workload_revision('task_lifecycle_demo');
SELECT pg_temp.assert_true(
  (
    SELECT configured_revision_captured
       AND configured_revision_drift
       AND pinned_workload_revision_hash = (SELECT revision_a FROM task_lifecycle_revisions)
       AND NOT EXISTS (
         SELECT 1
         FROM otlet.workload_revision_heads
         WHERE task_name = 'task_lifecycle_demo'
       )
    FROM otlet.task_lifecycle_status
    WHERE task_name = 'task_lifecycle_demo'
  ),
  'paused configuration did not remain an unpromoted draft'
) \g /dev/null

SELECT otlet.set_task_lifecycle(
  'task_lifecycle_demo',
  'active',
  (SELECT revision_a FROM task_lifecycle_revisions)
) \g /dev/null
SELECT pg_temp.assert_true(
  (
    SELECT active_workload_revision_hash = (SELECT revision_a FROM task_lifecycle_revisions)
    FROM otlet.workload_revision_heads
    WHERE task_name = 'task_lifecycle_demo'
  ),
  'resume did not restore the pinned revision'
) \g /dev/null

CREATE TEMP TABLE task_lifecycle_claim AS
SELECT id, claim_token
FROM otlet.claim_jobs('task_watch_lifecycle_model', 1);
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1 FROM task_lifecycle_claim),
  'resumed queued work was not claimable'
) \g /dev/null
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.set_task_lifecycle(%L, %L, %L)',
    'task_lifecycle_demo',
    'paused',
    (SELECT revision_a FROM task_lifecycle_revisions)
  ),
  'drain workers'
) \g /dev/null
SELECT *
FROM otlet.cancel_job(
  (SELECT id FROM task_lifecycle_claim),
  (SELECT claim_token FROM task_lifecycle_claim),
  'lifecycle proof drain'
) \g /dev/null

SELECT otlet.promote_workload_revision(
  'task_lifecycle_demo',
  (SELECT revision_b FROM task_lifecycle_revisions),
  (SELECT revision_a FROM task_lifecycle_revisions)
) \g /dev/null
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.set_task_lifecycle(%L, %L, %L)',
    'task_lifecycle_demo',
    'paused',
    (SELECT revision_a FROM task_lifecycle_revisions)
  ),
  'revision conflict'
) \g /dev/null

SELECT otlet.set_task_lifecycle(
  'task_lifecycle_demo',
  'paused',
  (SELECT revision_b FROM task_lifecycle_revisions)
) \g /dev/null
SELECT otlet.set_task_lifecycle(
  'task_lifecycle_demo',
  'retired',
  (SELECT revision_b FROM task_lifecycle_revisions)
) \g /dev/null
SELECT pg_temp.expect_error(
  $$SELECT otlet.admit_task_input('task_lifecycle_demo', 'retired', '{}'::jsonb)$$,
  'is retired'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$UPDATE otlet.tasks SET instruction = 'mutated' WHERE name = 'task_lifecycle_demo'$$,
  'is immutable'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$UPDATE otlet.tasks
    SET lifecycle_state = 'active'
    WHERE name = 'task_lifecycle_demo'$$,
  'require set_task_lifecycle'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$DELETE FROM otlet.tasks WHERE name = 'task_lifecycle_demo'$$,
  'retained evidence anchor'
) \g /dev/null
SELECT pg_temp.assert_true(
  (
    SELECT lifecycle_state = 'retired'
       AND pinned_workload_revision_hash = (SELECT revision_b FROM task_lifecycle_revisions)
       AND active_workload_revision_hash IS NULL
       AND revisions = 2
       AND terminal_jobs = 1
       AND watch_deletion_blocker = 'retained_task_archive'
    FROM otlet.task_lifecycle_status
    WHERE task_name = 'task_lifecycle_demo'
  ),
  'retired task did not retain its pinned revision and evidence'
) \g /dev/null

CREATE TABLE public.otlet_task_watch_lifecycle_source (
  id text PRIMARY KEY,
  payload text NOT NULL
);
INSERT INTO public.otlet_task_watch_lifecycle_source VALUES ('subject-1', 'before');

SELECT otlet.create_watch(
  watch_name => 'task_watch_lifecycle_demo',
  kind => 'row',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'task_watch_lifecycle_model',
  table_name => 'public.otlet_task_watch_lifecycle_source'::regclass,
  subject_column => 'id',
  input_columns => ARRAY['id', 'payload'],
  trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb
) \g /dev/null
SELECT pg_temp.expect_error(
  $statement$
    SELECT otlet.create_watch(
      watch_name => 'task_watch_lifecycle_demo',
      kind => 'row',
      instruction => 'Return an empty object',
      output_schema => '{"type":"object"}'::jsonb,
      model_name => 'task_watch_lifecycle_model',
      table_name => 'public.otlet_task_watch_lifecycle_source'::regclass,
      subject_column => 'id',
      input_columns => ARRAY['id', 'payload'],
      record_type => 'different_identity',
      trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb
    )
  $statement$,
  'requires retirement and pinned deletion'
) \g /dev/null

CREATE TEMP TABLE task_watch_revision AS
SELECT active_workload_revision_hash AS revision_hash
FROM otlet.workload_revision_heads
WHERE task_name = 'task_watch_lifecycle_demo_task';
WITH saved_record AS (
  INSERT INTO otlet.records (record_type, subject_id, body)
  VALUES ('task_watch_lifecycle_demo', 'subject-1', '{}'::jsonb)
  RETURNING id
)
INSERT INTO otlet.semantic_materializations (
  record_id,
  record_type,
  source_table,
  subject_id,
  task_name,
  model_name,
  body,
  contract_hash,
  source_hash,
  content_hash
)
SELECT
  saved_record.id,
  'task_watch_lifecycle_demo',
  'public.otlet_task_watch_lifecycle_source',
  'subject-1',
  'task_watch_lifecycle_demo_task',
  'task_watch_lifecycle_model',
  '{}'::jsonb,
  task_watch_revision.revision_hash,
  otlet.semantic_source_hash('{}'::jsonb),
  otlet.semantic_content_hash('{}'::jsonb, '{}'::jsonb)
FROM saved_record
CROSS JOIN task_watch_revision;

SELECT otlet.set_task_lifecycle(
  'task_watch_lifecycle_demo_task',
  'paused',
  (SELECT revision_hash FROM task_watch_revision)
) \g /dev/null
SELECT pg_temp.expect_error(
  $statement$
    SELECT otlet.create_watch(
      watch_name => 'task_watch_lifecycle_demo',
      kind => 'row',
      instruction => 'Return an empty object',
      output_schema => '{"type":"object"}'::jsonb,
      model_name => 'task_watch_lifecycle_model',
      table_name => 'public.otlet_task_watch_lifecycle_source'::regclass,
      subject_column => 'id',
      input_columns => ARRAY['id', 'payload'],
      trigger_policy => '{"on_change":"mark_stale"}'::jsonb
    )
  $statement$,
  'cannot reconfigure while inactive'
) \g /dev/null
UPDATE public.otlet_task_watch_lifecycle_source SET payload = 'after-1' WHERE id = 'subject-1';
UPDATE public.otlet_task_watch_lifecycle_source SET payload = 'after-2' WHERE id = 'subject-1';
SELECT pg_temp.assert_true(
  (
    SELECT count(*) = 1
       AND bool_and(attempts = 0)
       AND bool_and(workload_revision_hash = (SELECT revision_hash FROM task_watch_revision))
    FROM otlet.watch_reconciliation
    WHERE watch_name = 'task_watch_lifecycle_demo'
      AND subject_id = 'subject-1'
  )
  AND (
    SELECT stale AND stale_reason = 'source_update'
    FROM otlet.semantic_materializations
    WHERE task_name = 'task_watch_lifecycle_demo_task'
      AND subject_id = 'subject-1'
  )
  AND otlet.replay_watch_reconciliation(false) = 'idle',
  'paused watch did not coalesce a dormant reconciliation backlog'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$SELECT *
    FROM otlet.semantic_index_current_rows('task_watch_lifecycle_demo', true)$$,
  'does not exist'
) \g /dev/null
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.set_task_lifecycle(%L, %L, %L)',
    'task_watch_lifecycle_demo_task',
    'retired',
    (SELECT revision_hash FROM task_watch_revision)
  ),
  'unfinished watch reconciliation'
) \g /dev/null

SELECT otlet.set_task_lifecycle(
  'task_watch_lifecycle_demo_task',
  'active',
  (SELECT revision_hash FROM task_watch_revision)
) \g /dev/null
SELECT pg_temp.assert_true(
  otlet.reconcile_watch_subject('task_watch_lifecycle_demo', 'subject-1', true) = 'queued',
  'resumed watch did not reconcile the newest source row'
) \g /dev/null
SELECT pg_temp.assert_true(
  (
    SELECT count(*) = 1
    FROM otlet.jobs
    WHERE task_name = 'task_watch_lifecycle_demo_task'
      AND subject_id = 'subject-1'
      AND status = 'queued'
  ),
  'watch reconciliation did not create one queued job'
) \g /dev/null
SELECT *
FROM otlet.request_job_cancellation((
  SELECT id
  FROM otlet.jobs
  WHERE task_name = 'task_watch_lifecycle_demo_task'
    AND subject_id = 'subject-1'
)) \g /dev/null

SELECT otlet.set_task_lifecycle(
  'task_watch_lifecycle_demo_task',
  'paused',
  (SELECT revision_hash FROM task_watch_revision)
) \g /dev/null
ALTER TABLE public.otlet_task_watch_lifecycle_source
RENAME TO otlet_task_watch_lifecycle_source_renamed;
SELECT pg_temp.assert_true(
  (
    SELECT source_relation_drift AND NOT can_retire
    FROM otlet.task_lifecycle_status
    WHERE task_name = 'task_watch_lifecycle_demo_task'
  ),
  'renamed source did not close retirement readiness'
) \g /dev/null
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.set_task_lifecycle(%L, %L, %L)',
    'task_watch_lifecycle_demo_task',
    'retired',
    (SELECT revision_hash FROM task_watch_revision)
  ),
  'source relation identity drift'
) \g /dev/null
CREATE TABLE public.otlet_task_watch_lifecycle_source (
  id text PRIMARY KEY,
  payload text NOT NULL
);
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.set_task_lifecycle(%L, %L, %L)',
    'task_watch_lifecycle_demo_task',
    'retired',
    (SELECT revision_hash FROM task_watch_revision)
  ),
  'source relation identity drift'
) \g /dev/null
DROP TABLE public.otlet_task_watch_lifecycle_source;
ALTER TABLE public.otlet_task_watch_lifecycle_source_renamed
RENAME TO otlet_task_watch_lifecycle_source;
SELECT otlet.set_task_lifecycle(
  'task_watch_lifecycle_demo_task',
  'retired',
  (SELECT revision_hash FROM task_watch_revision)
) \g /dev/null
SELECT otlet.create_watch(
  watch_name => 'task_watch_lifecycle_shared_pair',
  kind => 'pair',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'task_watch_lifecycle_model',
  candidate_query => $query$
    SELECT id AS subject_id,
           jsonb_build_object('id', id, 'payload', payload) AS input
    FROM public.otlet_task_watch_lifecycle_source
  $query$,
  max_candidate_rows => 10,
  pair_sources => '[{
    "table":"public.otlet_task_watch_lifecycle_source",
    "subject_column":"id"
  }]'::jsonb
) \g /dev/null
ALTER TABLE public.otlet_task_watch_lifecycle_source
RENAME TO otlet_task_watch_lifecycle_source_renamed;
SELECT pg_temp.assert_true(
  (
    SELECT source_relation_drift
       AND NOT can_drop_watch
       AND watch_deletion_blocker = 'source_relation_identity_drift'
    FROM otlet.task_lifecycle_status
    WHERE task_name = 'task_watch_lifecycle_demo_task'
  ),
  'renamed source did not close watch deletion readiness'
) \g /dev/null
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.drop_watch(%L, %L)',
    'task_watch_lifecycle_demo',
    (SELECT revision_hash FROM task_watch_revision)
  ),
  'source relation identity drift'
) \g /dev/null
ALTER TABLE public.otlet_task_watch_lifecycle_source_renamed
RENAME TO otlet_task_watch_lifecycle_source;
SET LOCAL search_path = pg_catalog, pg_temp;
SELECT pg_temp.expect_error(
  $$SELECT otlet.drop_watch('task_watch_lifecycle_demo', 'otlet:v1:sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff')$$,
  'revision conflict'
) \g /dev/null
SELECT pg_temp.assert_true(
  EXISTS (SELECT 1 FROM otlet.watches WHERE name = 'task_watch_lifecycle_demo')
  AND EXISTS (SELECT 1 FROM otlet.semantic_indexes WHERE name = 'task_watch_lifecycle_demo')
  AND (
    SELECT can_drop_watch AND watch_deletion_blocker = 'ready'
    FROM otlet.task_lifecycle_status
    WHERE task_name = 'task_watch_lifecycle_demo_task'
  ),
  'wrong watch deletion pin changed operational state'
) \g /dev/null
SELECT pg_temp.assert_true(
  otlet.drop_watch(
    'task_watch_lifecycle_demo',
    (SELECT revision_hash FROM task_watch_revision)
  ),
  'exact pinned watch deletion failed'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT 1 FROM otlet.watches WHERE name = 'task_watch_lifecycle_demo')
  AND NOT EXISTS (SELECT 1 FROM otlet.semantic_indexes WHERE name = 'task_watch_lifecycle_demo')
  AND NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.otlet_task_watch_lifecycle_source'::regclass
      AND NOT tgisinternal
      AND tgname LIKE 'otlet_watch_v1_%'
  )
  AND EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.otlet_task_watch_lifecycle_source'::regclass
      AND NOT tgisinternal
      AND tgfoid = 'otlet.mark_semantic_stale_trigger()'::regprocedure
  )
  AND EXISTS (
    SELECT 1 FROM public.otlet_task_watch_lifecycle_source WHERE id = 'subject-1'
  )
  AND EXISTS (
    SELECT 1
    FROM otlet.workload_revisions
    WHERE task_name = 'task_watch_lifecycle_demo_task'
      AND workload_revision_hash = (SELECT revision_hash FROM task_watch_revision)
  )
  AND EXISTS (
    SELECT 1
    FROM otlet.jobs
    WHERE task_name = 'task_watch_lifecycle_demo_task'
      AND status = 'canceled'
  )
  AND EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations
    WHERE task_name = 'task_watch_lifecycle_demo_task'
      AND stale
      AND stale_reason = 'contract_changed'
  ),
  'pinned watch deletion removed source rows or retained evidence'
) \g /dev/null
SELECT pg_temp.assert_true(
  otlet.drop_watch_registry('task_watch_lifecycle_shared_pair'),
  'shared pair fixture deletion failed'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.otlet_task_watch_lifecycle_source'::regclass
      AND NOT tgisinternal
      AND tgname LIKE 'otlet_%'
  ),
  'shared stale trigger outlived its final dependency'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants()),
  'task and watch lifecycle violated an Otlet invariant'
) \g /dev/null

SELECT 'task_watch_lifecycle_contract=pin_conflict|pause_fenced|live_claim_fenced|unfinished_fenced|draft_unpromoted|watch_reconfig_fenced|resume_pinned|retire_fenced|watch_backlog|backlog_retire_fenced|watch_resume|rename_retire_fenced|name_reuse_fenced|rename_drop_fenced|drop_pin_fenced|archive_retained|exact_drop|path_independent_cleanup|shared_trigger_preserved|shared_trigger_released|invariants_clean';
ROLLBACK;
SQL
)"

expected_task_watch_lifecycle_contract="task_watch_lifecycle_contract=pin_conflict|pause_fenced|live_claim_fenced|unfinished_fenced|draft_unpromoted|watch_reconfig_fenced|resume_pinned|retire_fenced|watch_backlog|backlog_retire_fenced|watch_resume|rename_retire_fenced|name_reuse_fenced|rename_drop_fenced|drop_pin_fenced|archive_retained|exact_drop|path_independent_cleanup|shared_trigger_preserved|shared_trigger_released|invariants_clean"
if [ "$task_watch_lifecycle_contract" != "$expected_task_watch_lifecycle_contract" ]; then
  echo "Task and watch lifecycle contract failed: $task_watch_lifecycle_contract" >&2
  exit 1
fi
echo "$task_watch_lifecycle_contract"

race_suffix="$$"
race_watch="task_watch_retire_race_${race_suffix}"
race_task="${race_watch}_task"
race_source="otlet_task_watch_retire_race_${race_suffix}"
race_target="${race_watch}_target"

psql_exec \
  -v model_name="$cheap_model_name" \
  -v source_table="public.$race_source" \
  -v task_name="$race_task" \
  -v watch_name="$race_watch" \
  -v target_name="$race_target" >/dev/null <<'SQL'
SELECT format(
  'CREATE TABLE %I.%I (id text PRIMARY KEY, payload text NOT NULL)',
  split_part(:'source_table', '.', 1),
  split_part(:'source_table', '.', 2)
) \gexec
SELECT format(
  'INSERT INTO %s VALUES (%L, %L)',
  to_regclass(:'source_table'),
  'subject-1',
  'before'
) \gexec
SELECT otlet.create_watch(
  watch_name => :'watch_name',
  kind => 'row',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => :'model_name',
  table_name => to_regclass(:'source_table'),
  subject_column => 'id',
  input_columns => ARRAY['id', 'payload'],
  action_types => ARRAY['update_row'],
  trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb
);
SELECT otlet.register_action_target(
  :'target_name',
  to_regclass(:'source_table'),
  'id',
  ARRAY['payload']::name[]
);
SELECT otlet.register_action_workflow_policy(
  :'task_name',
  'update_row',
  :'target_name'
);
SQL

race_revision="$(psql_value -v task_name="$race_task" <<'SQL'
SELECT lifecycle_revision_hash
FROM otlet.tasks
WHERE name = :'task_name';
SQL
)"

repair_holder_app="otlet-task-watch-repair-holder-${race_suffix}"
repair_lifecycle_app="otlet-task-watch-repair-lifecycle-${race_suffix}"
definition_writer_app="otlet-task-watch-definition-writer-${race_suffix}"
action_policy_writer_app="otlet-task-watch-policy-writer-${race_suffix}"
repair_worker_app="otlet-task-watch-repair-worker-${race_suffix}"
authority_holder_app="otlet-task-watch-authority-holder-${race_suffix}"
authority_register_app="otlet-task-watch-authority-register-${race_suffix}"
authority_disable_app="otlet-task-watch-authority-disable-${race_suffix}"

docker exec -e PGAPPNAME="$repair_holder_app" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
  -v task_name="$race_task" <<'SQL' >/dev/null &
BEGIN;
SELECT pg_advisory_xact_lock(
  hashtextextended('otlet_workload_revision:' || :'task_name', 0)
);
SELECT pg_sleep(8);
COMMIT;
SQL
repair_holder_pid=$!

repair_holder_sleeping=false
for _ in {1..40}; do
  if [ "$(psql_value -v application_name="$repair_holder_app" <<'SQL'
SELECT count(*)
FROM pg_stat_activity
WHERE application_name = :'application_name'
  AND wait_event = 'PgSleep';
SQL
)" = "1" ]; then
    repair_holder_sleeping=true
    break
  fi
  sleep 0.05
done
if [ "$repair_holder_sleeping" != "true" ]; then
  echo "Lifecycle repair holder did not reach its lock fence" >&2
  wait "$repair_holder_pid" || true
  exit 1
fi

docker exec -e PGAPPNAME="$repair_lifecycle_app" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
  -v task_name="$race_task" -v revision_hash="$race_revision" <<'SQL' >/dev/null &
SET statement_timeout = '10000ms';
SELECT otlet.set_task_lifecycle(:'task_name', 'paused', :'revision_hash');
SQL
repair_lifecycle_pid=$!

repair_lifecycle_waiting=false
for _ in {1..40}; do
  if [ "$(psql_value -v application_name="$repair_lifecycle_app" <<'SQL'
SELECT count(*)
FROM pg_stat_activity
WHERE application_name = :'application_name'
  AND wait_event_type = 'Lock';
SQL
)" = "1" ]; then
    repair_lifecycle_waiting=true
    break
  fi
  sleep 0.05
done
if [ "$repair_lifecycle_waiting" != "true" ]; then
  echo "Lifecycle transition did not wait behind the repair lock holder" >&2
  wait "$repair_holder_pid" || true
  wait "$repair_lifecycle_pid" || true
  exit 1
fi

docker exec -e PGAPPNAME="$definition_writer_app" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
  -v task_name="$race_task" <<'SQL' >/dev/null &
SET statement_timeout = '10000ms';
CREATE TEMP TABLE definition_parameters AS
SELECT :'task_name'::text AS task_name;
DO $proof$
DECLARE
  parameters record;
BEGIN
  SELECT * INTO parameters FROM definition_parameters;
  UPDATE otlet.tasks
  SET instruction = instruction || ' concurrent draft'
  WHERE name = parameters.task_name;
  PERFORM otlet.promote_configured_workload_revision(parameters.task_name);
  RAISE EXCEPTION 'concurrent task definition write unexpectedly succeeded';
EXCEPTION WHEN OTHERS THEN
  IF position('definition write conflicts with a lifecycle operation' IN SQLERRM) = 0 THEN
    RAISE;
  END IF;
END
$proof$;
SQL
definition_writer_pid=$!

docker exec -e PGAPPNAME="$action_policy_writer_app" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
  -v source_table="public.$race_source" \
  -v task_name="$race_task" \
  -v target_name="$race_target" <<'SQL' >/dev/null &
SET statement_timeout = '10000ms';
BEGIN;
SELECT otlet.register_action_target(
  :'target_name',
  to_regclass(:'source_table'),
  'id',
  ARRAY['payload']::name[]
);
SELECT otlet.register_action_workflow_policy(
  :'task_name',
  'update_row',
  :'target_name',
  'recommendation_only',
  'evaluated'
);
COMMIT;
SQL
action_policy_writer_pid=$!

action_policy_writer_waiting=false
for _ in {1..40}; do
  if [ "$(psql_value -v application_name="$action_policy_writer_app" <<'SQL'
SELECT count(*)
FROM pg_stat_activity
WHERE application_name = :'application_name'
  AND wait_event_type = 'Lock';
SQL
)" = "1" ]; then
    action_policy_writer_waiting=true
    break
  fi
  sleep 0.05
done

docker exec -e PGAPPNAME="$repair_worker_app" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
  -v task_name="$race_task" -v revision_hash="$race_revision" <<'SQL' >/dev/null &
SET statement_timeout = '10000ms';
CREATE TEMP TABLE repair_parameters AS
SELECT :'task_name'::text AS task_name, :'revision_hash'::text AS revision_hash;
DO $proof$
DECLARE
  parameters record;
BEGIN
  SELECT * INTO parameters FROM repair_parameters;
  PERFORM otlet.repair_source_query_contract(
    parameters.task_name,
    parameters.revision_hash
  );
  RAISE EXCEPTION 'source query repair unexpectedly succeeded';
EXCEPTION WHEN OTHERS THEN
  IF position('source query repair conflict' IN SQLERRM) = 0 THEN
    RAISE;
  END IF;
END
$proof$;
SQL
repair_worker_pid=$!

repair_worker_waiting=false
for _ in {1..40}; do
  if [ "$(psql_value -v application_name="$repair_worker_app" <<'SQL'
SELECT count(*)
FROM pg_stat_activity
WHERE application_name = :'application_name'
  AND wait_event_type = 'Lock';
SQL
)" = "1" ]; then
    repair_worker_waiting=true
    break
  fi
  sleep 0.05
done

set +e
wait "$repair_holder_pid"
repair_holder_status=$?
wait "$repair_lifecycle_pid"
repair_lifecycle_status=$?
wait "$definition_writer_pid"
definition_writer_status=$?
wait "$action_policy_writer_pid"
action_policy_writer_status=$?
wait "$repair_worker_pid"
repair_worker_status=$?
set -e
if [ "$action_policy_writer_waiting" != "true" ] \
   || [ "$repair_worker_waiting" != "true" ] \
   || [ "$repair_holder_status" -ne 0 ] \
   || [ "$repair_lifecycle_status" -ne 0 ] \
   || [ "$definition_writer_status" -ne 0 ] \
   || [ "$action_policy_writer_status" -ne 0 ] \
   || [ "$repair_worker_status" -ne 0 ]; then
  echo "Lifecycle and source-query repair did not serialize without deadlock" >&2
  exit 1
fi
definition_write_contract="t"
action_policy_serialization_contract="t"
repair_serialization_contract="t"

docker exec -e PGAPPNAME="$authority_holder_app" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
  -v task_name="$race_task" <<'SQL' >/dev/null &
BEGIN;
SELECT pg_advisory_xact_lock(
  hashtextextended('otlet_workload_revision:' || :'task_name', 0)
);
SELECT pg_sleep(5);
COMMIT;
SQL
authority_holder_pid=$!

authority_holder_sleeping=false
for _ in {1..40}; do
  if [ "$(psql_value -v application_name="$authority_holder_app" <<'SQL'
SELECT count(*)
FROM pg_stat_activity
WHERE application_name = :'application_name'
  AND wait_event = 'PgSleep';
SQL
)" = "1" ]; then
    authority_holder_sleeping=true
    break
  fi
  sleep 0.05
done
if [ "$authority_holder_sleeping" != "true" ]; then
  echo "Authority holder did not reach its lock fence" >&2
  wait "$authority_holder_pid" || true
  exit 1
fi

docker exec -e PGAPPNAME="$authority_register_app" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
  -v task_name="$race_task" -v target_name="$race_target" <<'SQL' >/dev/null &
SET statement_timeout = '10000ms';
SELECT otlet.register_action_workflow_policy(
  :'task_name',
  'update_row',
  :'target_name',
  'recommendation_only',
  'evaluated'
);
SQL
authority_register_pid=$!

authority_register_waiting=false
for _ in {1..40}; do
  if [ "$(psql_value -v application_name="$authority_register_app" <<'SQL'
SELECT count(*)
FROM pg_stat_activity
WHERE application_name = :'application_name'
  AND wait_event_type = 'Lock';
SQL
)" = "1" ]; then
    authority_register_waiting=true
    break
  fi
  sleep 0.05
done
if [ "$authority_register_waiting" != "true" ]; then
  echo "Authority registration did not wait behind the task lock holder" >&2
  wait "$authority_holder_pid" || true
  wait "$authority_register_pid" || true
  exit 1
fi

docker exec -e PGAPPNAME="$authority_disable_app" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
  -v task_name="$race_task" <<'SQL' >/dev/null &
SET statement_timeout = '10000ms';
SELECT otlet.disable_action_workflow_policy(:'task_name', 'update_row');
SQL
authority_disable_pid=$!

authority_disable_waiting=false
for _ in {1..40}; do
  if [ "$(psql_value -v application_name="$authority_disable_app" <<'SQL'
SELECT count(*)
FROM pg_stat_activity
WHERE application_name = :'application_name'
  AND wait_event_type = 'Lock';
SQL
)" = "1" ]; then
    authority_disable_waiting=true
    break
  fi
  sleep 0.05
done

set +e
wait "$authority_holder_pid"
authority_holder_status=$?
wait "$authority_register_pid"
authority_register_status=$?
wait "$authority_disable_pid"
authority_disable_status=$?
set -e
if [ "$authority_disable_waiting" != "true" ] \
   || [ "$authority_holder_status" -ne 0 ] \
   || [ "$authority_register_status" -ne 0 ] \
   || [ "$authority_disable_status" -ne 0 ]; then
  echo "Authority registration and disable did not serialize without deadlock" >&2
  exit 1
fi

psql_exec -v task_name="$race_task" -v target_name="$race_target" >/dev/null <<'SQL'
SELECT otlet.register_action_workflow_policy(
  :'task_name',
  'update_row',
  :'target_name',
  'recommendation_only',
  'evaluated'
);
SQL

docker exec -e PGAPPNAME=otlet-task-watch-source-race -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
  -v source_table="public.$race_source" <<'SQL' >/dev/null &
BEGIN;
SELECT format(
  'UPDATE %s SET payload = %L WHERE id = %L',
  to_regclass(:'source_table'),
  'after',
  'subject-1'
) \gexec
SELECT pg_sleep(3);
COMMIT;
SQL
race_source_pid=$!

race_source_sleeping=false
for _ in {1..40}; do
  if [ "$(psql_value <<'SQL'
SELECT count(*)
FROM pg_stat_activity
WHERE application_name = 'otlet-task-watch-source-race'
  AND wait_event = 'PgSleep';
SQL
)" = "1" ]; then
    race_source_sleeping=true
    break
  fi
  sleep 0.05
done
if [ "$race_source_sleeping" != "true" ]; then
  echo "Lifecycle source race did not reach its commit fence" >&2
  wait "$race_source_pid" || true
  exit 1
fi

set +e
race_retirement_output="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v task_name="$race_task" \
    -v revision_hash="$race_revision" <<'SQL' 2>&1
SELECT otlet.set_task_lifecycle(:'task_name', 'retired', :'revision_hash');
SQL
)"
race_retirement_status=$?
set -e
wait "$race_source_pid"
if [ "$race_retirement_status" -eq 0 ] || [[ "$race_retirement_output" != *"unfinished watch reconciliation"* ]]; then
  echo "Concurrent retirement did not preserve the source reconciliation backlog" >&2
  printf '%s\n' "$race_retirement_output" >&2
  exit 1
fi

race_resume_contract="$(
  psql_value \
    -v revision_hash="$race_revision" \
    -v task_name="$race_task" \
    -v watch_name="$race_watch" <<'SQL'
BEGIN;
CREATE TEMP TABLE race_state AS
SELECT lifecycle_state = 'paused'
   AND (SELECT count(*) FROM otlet.watch_reconciliation reconciliation
        WHERE reconciliation.watch_name = :'watch_name') = 1 AS backlog_preserved
FROM otlet.tasks
WHERE name = :'task_name';
SELECT otlet.set_task_lifecycle(:'task_name', 'active', :'revision_hash') \g /dev/null
CREATE TEMP TABLE race_reconciled AS
SELECT otlet.reconcile_watch_subject(:'watch_name', 'subject-1', true) AS result;
SELECT otlet.request_job_cancellation(job.id)
FROM otlet.jobs job
WHERE job.task_name = :'task_name'
  AND job.subject_id = 'subject-1'
  AND job.status = 'queued'
\g /dev/null
SELECT otlet.set_task_lifecycle(:'task_name', 'paused', :'revision_hash') \g /dev/null
SELECT concat_ws('|',
  (SELECT backlog_preserved FROM race_state),
  (SELECT result = 'queued' FROM race_reconciled),
  (SELECT count(*) = 1 AND bool_and(status = 'canceled')
   FROM otlet.jobs
   WHERE task_name = :'task_name'
     AND subject_id = 'subject-1'),
  (SELECT lifecycle_state = 'paused'
   FROM otlet.tasks
   WHERE name = :'task_name')
);
COMMIT;
SQL
)"

psql_exec -v source_table="public.$race_source" >/dev/null <<'SQL'
SELECT format('DROP TABLE %s', to_regclass(:'source_table')) \gexec
SQL

race_drop_contract="$(psql_value \
  -v source_table="public.$race_source" \
  -v revision_hash="$race_revision" \
  -v task_name="$race_task" \
  -v watch_name="$race_watch" <<'SQL'
BEGIN;
CREATE TEMP TABLE race_missing_status AS
SELECT lifecycle_state = 'paused'
   AND configured_revision_hash IS NULL
   AND configured_revision_error LIKE '%semantic source relation is missing%'
   AND configured_revision_drift
   AND can_retire AS status_closed
FROM otlet.task_lifecycle_status
WHERE task_name = :'task_name';
SELECT otlet.set_task_lifecycle(:'task_name', 'retired', :'revision_hash') \g /dev/null
CREATE TEMP TABLE race_watch_drop AS
SELECT otlet.drop_watch(:'watch_name', :'revision_hash') AS dropped;
SELECT concat_ws('|',
  to_regclass(:'source_table') IS NULL,
  (SELECT status_closed FROM race_missing_status),
  (SELECT lifecycle_state = 'retired'
   FROM otlet.tasks
   WHERE name = :'task_name'),
  (SELECT dropped FROM race_watch_drop),
  (SELECT lifecycle_state = 'retired'
     AND lifecycle_revision_hash = :'revision_hash'
   FROM otlet.tasks
   WHERE name = :'task_name'),
  NOT EXISTS (SELECT 1 FROM otlet.watches WHERE name = :'watch_name'),
  NOT EXISTS (SELECT 1 FROM otlet.semantic_indexes WHERE name = :'watch_name'),
  NOT EXISTS (SELECT 1 FROM otlet.watch_reconciliation WHERE watch_name = :'watch_name'),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
COMMIT;
SQL
)"

expected_task_watch_lifecycle_race_contract="t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t"
task_watch_lifecycle_race_contract="$definition_write_contract|$action_policy_serialization_contract|$repair_serialization_contract|t|$race_resume_contract|$race_drop_contract"
if [ "$task_watch_lifecycle_race_contract" != "$expected_task_watch_lifecycle_race_contract" ]; then
  echo "Task and watch lifecycle race contract failed: $task_watch_lifecycle_race_contract" >&2
  exit 1
fi
echo "task_watch_lifecycle_race_contract=definition_write_fenced|action_policy_serialized|repair_serialized|retirement_serialized|backlog_preserved|resume_queued|queue_canceled|repaused|source_missing|status_closed|retired|exact_drop|archive_retained|registry_removed|index_removed|reconciliation_removed|invariants_clean"
