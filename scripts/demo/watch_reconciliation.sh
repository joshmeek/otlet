log "Checking durable watch reconciliation"

watch_reconciliation_contract="$(psql_exec -qAt -v model_name="$cheap_model_name" <<'SQL' | tail -n 1
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
UPDATE otlet.production_policy
SET max_queued_jobs_per_model = 1,
    watch_reconciliation_max_attempts = 3,
    watch_reconciliation_base_delay_ms = 10,
    watch_reconciliation_max_delay_ms = 40
WHERE name = 'default';

CREATE TABLE public.otlet_watch_reconciliation_source (
  id text PRIMARY KEY,
  payload text NOT NULL
);
SELECT otlet.create_task(
  'watch_reconciliation_blocker',
  NULL,
  'Return an empty object',
  '{"type":"object"}'::jsonb,
  :'model_name',
  input_shaping => '{"source_fields":["value"]}'::jsonb
) \g /dev/null
WITH revision AS (
  SELECT otlet.ensure_active_workload_revision('watch_reconciliation_blocker') AS revision_hash
)
INSERT INTO otlet.jobs (task_name, workload_revision_hash, subject_id, input)
SELECT 'watch_reconciliation_blocker', revision_hash, 'blocker', '{"value":1}'::jsonb
FROM revision;
SELECT otlet.create_watch(
  watch_name => 'watch_reconciliation_demo',
  kind => 'row',
  instruction => 'Return a decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_watch_reconciliation_source'::regclass,
  subject_column => 'id',
  trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb
) \g /dev/null

INSERT INTO otlet.watch_reconciliation (
  watch_name,
  subject_id,
  workload_revision_hash,
  source_identity,
  source_deleted,
  attempt_limit
)
SELECT
  'watch_reconciliation_missing',
  'orphan',
  head.active_workload_revision_hash,
  otlet.watch_source_delete_identity('watch_reconciliation_missing', 'orphan'),
  true,
  policy.watch_reconciliation_max_attempts
FROM otlet.workload_revision_heads head
CROSS JOIN otlet.production_policy policy
WHERE head.task_name = 'watch_reconciliation_demo_task'
  AND policy.name = 'default';
DO $proof$
DECLARE
  replay_result text;
BEGIN
  replay_result := otlet.replay_watch_reconciliation(true);
  IF replay_result <> 'missing'
     OR EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation
       WHERE watch_name = 'watch_reconciliation_missing'
         AND subject_id = 'orphan'
     ) THEN
    RAISE EXCEPTION 'watch replay did not prune an orphaned reconciliation row: %', replay_result;
  END IF;
END;
$proof$;

CREATE TEMP TABLE watch_reconciliation_generations (generation bigint NOT NULL);
INSERT INTO public.otlet_watch_reconciliation_source VALUES ('coalesce', 'v1');
INSERT INTO watch_reconciliation_generations
SELECT generation FROM otlet.watch_reconciliation
WHERE watch_name = 'watch_reconciliation_demo' AND subject_id = 'coalesce';
UPDATE public.otlet_watch_reconciliation_source SET payload = 'v2' WHERE id = 'coalesce';
INSERT INTO watch_reconciliation_generations
SELECT generation FROM otlet.watch_reconciliation
WHERE watch_name = 'watch_reconciliation_demo' AND subject_id = 'coalesce';
UPDATE public.otlet_watch_reconciliation_source SET payload = 'v3' WHERE id = 'coalesce';
INSERT INTO watch_reconciliation_generations
SELECT generation FROM otlet.watch_reconciliation
WHERE watch_name = 'watch_reconciliation_demo' AND subject_id = 'coalesce';
DO $proof$
DECLARE
  pending otlet.watch_reconciliation%ROWTYPE;
  current_identity text;
  result text;
BEGIN
  SELECT * INTO STRICT pending
  FROM otlet.watch_reconciliation
  WHERE watch_name = 'watch_reconciliation_demo'
    AND subject_id = 'coalesce';
  SELECT otlet.semantic_source_hash(otlet.task_subject_input(
    revision.definition #>> '{task,input_query}',
    'coalesce',
    revision.definition
  ))
  INTO current_identity
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = 'watch_reconciliation_demo_task'
    AND revision.workload_revision_hash = pending.workload_revision_hash;
  IF pending.generation <> (SELECT max(generation) FROM watch_reconciliation_generations)
     OR (SELECT count(*) FROM watch_reconciliation_generations) <> 3
     OR (SELECT count(DISTINCT generation) FROM watch_reconciliation_generations) <> 3
     OR pending.attempts <> 0
     OR pending.state <> 'pending'
     OR pending.source_identity IS DISTINCT FROM current_identity THEN
    RAISE EXCEPTION 'watch changes did not coalesce to the newest source identity';
  END IF;

  result := otlet.reconcile_watch_subject('watch_reconciliation_demo', 'coalesce', true);
  IF result <> 'pending' THEN
    RAISE EXCEPTION 'watch reconciliation did not record its first rejection';
  END IF;
  result := otlet.reconcile_watch_subject('watch_reconciliation_demo', 'coalesce', false);
  IF result <> 'deferred' THEN
    RAISE EXCEPTION 'watch reconciliation ignored its backoff';
  END IF;
  result := otlet.reconcile_watch_subject('watch_reconciliation_demo', 'coalesce', true);
  IF result <> 'pending' THEN
    RAISE EXCEPTION 'watch reconciliation did not retry after backoff';
  END IF;
  result := otlet.reconcile_watch_subject('watch_reconciliation_demo', 'coalesce', true);
  IF result <> 'exhausted' THEN
    RAISE EXCEPTION 'watch reconciliation did not reach bounded exhaustion';
  END IF;
END;
$proof$;

CREATE TEMP TABLE watch_reconciliation_exhausted_snapshot AS
SELECT generation, source_identity
FROM otlet.watch_reconciliation
WHERE watch_name = 'watch_reconciliation_demo'
  AND subject_id = 'coalesce';
INSERT INTO otlet.jobs (task_name, workload_revision_hash, subject_id, input)
SELECT
  'watch_reconciliation_demo_task',
  reconciliation.workload_revision_hash,
  'coalesce',
  otlet.task_subject_input(
    revision.definition #>> '{task,input_query}',
    'coalesce',
    revision.definition
  )
FROM otlet.watch_reconciliation reconciliation
JOIN otlet.workload_revisions revision
  ON revision.task_name = 'watch_reconciliation_demo_task'
 AND revision.workload_revision_hash = reconciliation.workload_revision_hash
WHERE reconciliation.watch_name = 'watch_reconciliation_demo'
  AND reconciliation.subject_id = 'coalesce';
UPDATE public.otlet_watch_reconciliation_source
SET payload = payload
WHERE id = 'coalesce';
DO $proof$
DECLARE
  pending otlet.watch_reconciliation%ROWTYPE;
  old_input jsonb;
  current_identity text;
  result text;
BEGIN
  SELECT * INTO STRICT pending
  FROM otlet.watch_reconciliation
  WHERE watch_name = 'watch_reconciliation_demo'
    AND subject_id = 'coalesce';
  SELECT input INTO STRICT old_input
  FROM otlet.jobs
  WHERE task_name = 'watch_reconciliation_demo_task'
    AND subject_id = 'coalesce';
  SELECT otlet.semantic_source_hash(otlet.task_subject_input(
    revision.definition #>> '{task,input_query}',
    'coalesce',
    revision.definition
  ))
  INTO current_identity
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = 'watch_reconciliation_demo_task'
    AND revision.workload_revision_hash = pending.workload_revision_hash;

  IF pending.state <> 'pending'
     OR pending.attempts <> 0
     OR pending.generation = (SELECT generation FROM watch_reconciliation_exhausted_snapshot)
     OR pending.source_identity = (SELECT source_identity FROM watch_reconciliation_exhausted_snapshot)
     OR pending.source_identity IS DISTINCT FROM current_identity
     OR otlet.resolve_watch_input_reconciliation(
       'watch_reconciliation_demo_task',
       pending.workload_revision_hash,
       'coalesce',
       old_input
     ) THEN
    RAISE EXCEPTION 'same-content source update did not re-arm an exact-snapshot reconciliation';
  END IF;

  result := otlet.reconcile_watch_subject('watch_reconciliation_demo', 'coalesce', true);
  IF result <> 'pending'
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation
       WHERE watch_name = 'watch_reconciliation_demo'
         AND subject_id = 'coalesce'
         AND attempts = 1
         AND last_error = 'active job still carries an older source identity'
     ) THEN
    RAISE EXCEPTION 'same-content older snapshot job cleared current dirty state';
  END IF;
END;
$proof$;
DELETE FROM otlet.jobs
WHERE task_name = 'watch_reconciliation_demo_task'
  AND subject_id = 'coalesce';
DO $proof$
DECLARE
  result text;
BEGIN
  result := otlet.reconcile_watch_subject('watch_reconciliation_demo', 'coalesce', true);
  IF result <> 'pending' THEN
    RAISE EXCEPTION 're-armed reconciliation did not retry before exhaustion';
  END IF;
  result := otlet.reconcile_watch_subject('watch_reconciliation_demo', 'coalesce', true);
  IF result <> 'exhausted' THEN
    RAISE EXCEPTION 're-armed reconciliation did not retain bounded exhaustion';
  END IF;
END;
$proof$;

INSERT INTO public.otlet_watch_reconciliation_source VALUES ('rename-old', 'rename');
UPDATE public.otlet_watch_reconciliation_source
SET id = 'rename-new'
WHERE id = 'rename-old';
DO $proof$
DECLARE
  new_pending otlet.watch_reconciliation%ROWTYPE;
  revision_definition jsonb;
BEGIN
  SELECT * INTO STRICT new_pending
  FROM otlet.watch_reconciliation
  WHERE watch_name = 'watch_reconciliation_demo'
    AND subject_id = 'rename-new';
  SELECT definition INTO STRICT revision_definition
  FROM otlet.workload_revisions
  WHERE task_name = 'watch_reconciliation_demo_task'
    AND workload_revision_hash = new_pending.workload_revision_hash;

  IF NOT EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation
       WHERE watch_name = 'watch_reconciliation_demo'
         AND subject_id = 'rename-old'
         AND source_deleted
         AND source_identity = otlet.watch_source_delete_identity(
           'watch_reconciliation_demo',
           'rename-old'
         )
     )
     OR new_pending.source_deleted
     OR new_pending.source_identity IS DISTINCT FROM otlet.semantic_source_hash(
       otlet.task_subject_input(
         revision_definition #>> '{task,input_query}',
         'rename-new',
         revision_definition
       )
     )
     OR otlet.reconcile_watch_subject(
       'watch_reconciliation_demo',
       'rename-old',
       true
     ) <> 'source_deleted'
     OR otlet.reconcile_watch_subject(
       'watch_reconciliation_demo',
       'rename-new',
       true
     ) <> 'pending' THEN
    RAISE EXCEPTION 'subject-key update did not reconcile old deletion and new snapshot';
  END IF;
  DELETE FROM otlet.watch_reconciliation
  WHERE watch_name = 'watch_reconciliation_demo'
    AND subject_id = 'rename-new';
END;
$proof$;

INSERT INTO public.otlet_watch_reconciliation_source VALUES ('pending-age', 'waiting');
UPDATE otlet.watch_reconciliation
SET first_dirty_at = clock_timestamp() - interval '10 minutes'
WHERE watch_name = 'watch_reconciliation_demo'
  AND subject_id = 'pending-age';
CREATE TEMP TABLE watch_reconciliation_ack_token AS
SELECT generation
FROM otlet.watch_reconciliation
WHERE watch_name = 'watch_reconciliation_demo'
  AND subject_id = 'coalesce';
DO $proof$
DECLARE
  exhausted_generation bigint;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.watch_status
    WHERE watch_name = 'watch_reconciliation_demo'
      AND reconciliation_pending_subjects = 1
      AND reconciliation_exhausted_subjects = 1
      AND reconciliation_oldest_pending_age >= interval '9 minutes'
  ) THEN
    RAISE EXCEPTION 'watch status did not expose pending age and exhaustion';
  END IF;

  SELECT generation INTO STRICT exhausted_generation
  FROM watch_reconciliation_ack_token;
  IF otlet.acknowledge_watch_reconciliation(
       'watch_reconciliation_demo',
       'coalesce',
       exhausted_generation - 1
     )
     OR NOT otlet.acknowledge_watch_reconciliation(
       'watch_reconciliation_demo',
       'coalesce',
       exhausted_generation
     ) THEN
    RAISE EXCEPTION 'watch reconciliation acknowledgement ignored its generation fence';
  END IF;
END;
$proof$;

UPDATE public.otlet_watch_reconciliation_source SET payload = 'v4' WHERE id = 'coalesce';
DO $proof$
DECLARE
  acknowledged_generation bigint;
  current_generation bigint;
BEGIN
  SELECT generation INTO STRICT acknowledged_generation
  FROM watch_reconciliation_ack_token;
  SELECT generation INTO STRICT current_generation
  FROM otlet.watch_reconciliation
  WHERE watch_name = 'watch_reconciliation_demo'
    AND subject_id = 'coalesce';
  IF current_generation = acknowledged_generation
     OR otlet.acknowledge_watch_reconciliation(
       'watch_reconciliation_demo',
       'coalesce',
       acknowledged_generation
     ) THEN
    RAISE EXCEPTION 'watch reconciliation reused an acknowledged generation';
  END IF;
END;
$proof$;
DELETE FROM otlet.jobs WHERE task_name = 'watch_reconciliation_blocker';
CREATE TEMP TABLE watch_reconciliation_expected AS
SELECT source_identity
FROM otlet.watch_reconciliation
WHERE watch_name = 'watch_reconciliation_demo'
  AND subject_id = 'coalesce';
CREATE TEMP TABLE watch_reconciliation_replay AS
SELECT otlet.reconcile_watch_subject(
  'watch_reconciliation_demo',
  'coalesce',
  true
) AS result;
DO $proof$
BEGIN
  IF (SELECT result FROM watch_reconciliation_replay) <> 'queued'
     OR EXISTS (
       SELECT 1 FROM otlet.watch_reconciliation
       WHERE watch_name = 'watch_reconciliation_demo'
         AND subject_id = 'coalesce'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.jobs job
       JOIN otlet.workload_revisions revision
         ON revision.task_name = job.task_name
        AND revision.workload_revision_hash = job.workload_revision_hash
       WHERE job.task_name = 'watch_reconciliation_demo_task'
         AND job.subject_id = 'coalesce'
         AND job.job_origin = 'catch_up'
         AND otlet.semantic_source_hash(job.input)
           = (SELECT source_identity FROM watch_reconciliation_expected)
     ) THEN
    RAISE EXCEPTION 'watch replay did not queue the newest source identity';
  END IF;
END;
$proof$;

INSERT INTO public.otlet_watch_reconciliation_source VALUES ('deleted', 'gone');
DELETE FROM public.otlet_watch_reconciliation_source WHERE id = 'deleted';
CREATE TEMP TABLE watch_reconciliation_delete AS
SELECT otlet.reconcile_watch_subject(
  'watch_reconciliation_demo',
  'deleted',
  true
) AS result;
DO $proof$
BEGIN
  IF (SELECT result FROM watch_reconciliation_delete) <> 'source_deleted'
     OR EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation
       WHERE watch_name = 'watch_reconciliation_demo'
         AND subject_id = 'deleted'
     )
     OR EXISTS (
       SELECT 1
       FROM otlet.jobs
       WHERE task_name = 'watch_reconciliation_demo_task'
         AND subject_id = 'deleted'
     ) THEN
    RAISE EXCEPTION 'watch source deletion did not resolve without inference';
  END IF;
  IF EXISTS (SELECT 1 FROM otlet.verify_invariants()) THEN
    RAISE EXCEPTION 'watch reconciliation left an invariant violation';
  END IF;
END;
$proof$;

SELECT 'orphan_pruned|coalesced|backoff|exhausted|snapshot_fenced|subject_rename|replayed|acknowledged|source_deleted|invariants_clean';
ROLLBACK;
SQL
)"

echo "watch_reconciliation_contract=$watch_reconciliation_contract"
[ "$watch_reconciliation_contract" = "orphan_pruned|coalesced|backoff|exhausted|snapshot_fenced|subject_rename|replayed|acknowledged|source_deleted|invariants_clean" ] || {
  echo "Expected durable watch reconciliation contract, got $watch_reconciliation_contract" >&2
  exit 1
}

psql_exec -qAt -v model_name="$cheap_model_name" <<'SQL' >/dev/null
DROP TABLE IF EXISTS public.otlet_watch_reconciliation_drop_race CASCADE;
CREATE TABLE public.otlet_watch_reconciliation_drop_race (
  id text PRIMARY KEY,
  payload text NOT NULL
);
SELECT otlet.create_watch(
  watch_name => 'watch_reconciliation_drop_race',
  kind => 'row',
  instruction => 'Return a decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_watch_reconciliation_drop_race'::regclass,
  subject_column => 'id',
  trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb
) \g /dev/null
SQL

docker exec -e PGOPTIONS="$demo_pgoptions" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 <<'SQL' >/dev/null &
BEGIN;
SELECT pg_advisory_xact_lock(
  hashtextextended('otlet_workload_revision:watch_reconciliation_drop_race_task', 0)
);
SELECT pg_sleep(3);
SELECT count(*) FROM public.otlet_watch_reconciliation_drop_race;
COMMIT;
SQL
watch_runtime_pid=$!
sleep 0.2
docker exec -e PGAPPNAME=otlet-watch-reconciliation-create \
  -e PGOPTIONS="$demo_pgoptions" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
  -v model_name="$cheap_model_name" <<'SQL' >/dev/null &
SELECT otlet.create_watch(
  watch_name => 'watch_reconciliation_drop_race',
  kind => 'row',
  instruction => 'Return the current decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_watch_reconciliation_drop_race'::regclass,
  subject_column => 'id',
  trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb
);
SQL
watch_create_pid=$!

watch_create_waiting=false
for _ in {1..40}; do
  if [ "$(psql_value <<'SQL'
SELECT count(*)
FROM pg_stat_activity
WHERE application_name = 'otlet-watch-reconciliation-create'
  AND wait_event_type = 'Lock';
SQL
)" = "1" ]; then
    watch_create_waiting=true
    break
  fi
  sleep 0.05
done
if [ "$watch_create_waiting" != "true" ]; then
  echo "Watch reconfiguration did not wait on the active workload" >&2
  exit 1
fi

watch_runtime_status=0
watch_create_status=0
wait "$watch_runtime_pid" || watch_runtime_status=$?
wait "$watch_create_pid" || watch_create_status=$?
if [ "$watch_runtime_status|$watch_create_status" != "0|0" ]; then
  echo "Watch runtime read and reconfiguration did not complete without a deadlock" >&2
  exit 1
fi

docker exec -e PGOPTIONS="$demo_pgoptions" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 <<'SQL' >/dev/null &
BEGIN;
LOCK TABLE public.otlet_watch_reconciliation_drop_race IN ROW EXCLUSIVE MODE;
SELECT pg_sleep(3);
INSERT INTO public.otlet_watch_reconciliation_drop_race VALUES ('race', 'current');
COMMIT;
SQL
watch_source_pid=$!
sleep 0.2
docker exec -e PGAPPNAME=otlet-watch-reconciliation-drop \
  -e PGOPTIONS="$demo_pgoptions" -i "$container" \
  psql -U postgres -d "$database" -X -qAt -v ON_ERROR_STOP=1 \
  -c "SET statement_timeout = '8s'; SELECT otlet.drop_watch_registry('watch_reconciliation_drop_race')" \
  >/dev/null &
watch_drop_pid=$!

watch_drop_waiting=false
for _ in {1..40}; do
  if [ "$(psql_value <<'SQL'
SELECT count(*)
FROM pg_stat_activity
WHERE application_name = 'otlet-watch-reconciliation-drop'
  AND wait_event_type = 'Lock';
SQL
)" = "1" ]; then
    watch_drop_waiting=true
    break
  fi
  sleep 0.05
done
if [ "$watch_drop_waiting" != "true" ]; then
  echo "Watch drop did not wait on the active source write" >&2
  exit 1
fi

watch_source_status=0
watch_drop_status=0
wait "$watch_source_pid" || watch_source_status=$?
wait "$watch_drop_pid" || watch_drop_status=$?
if [ "$watch_source_status|$watch_drop_status" != "0|0" ]; then
  echo "Watch source write and drop did not complete without a deadlock" >&2
  exit 1
fi

watch_drop_contract="$(psql_value <<'SQL'
SELECT concat_ws('|',
  NOT EXISTS (
    SELECT 1 FROM otlet.watches
    WHERE name = 'watch_reconciliation_drop_race'
  ),
  NOT EXISTS (
    SELECT 1 FROM otlet.watch_reconciliation
    WHERE watch_name = 'watch_reconciliation_drop_race'
  ),
  NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.otlet_watch_reconciliation_drop_race'::regclass
      AND tgname LIKE 'otlet_watch_v1_%'
      AND NOT tgisinternal
  ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
echo "watch_reconciliation_drop_contract=$watch_drop_contract"
if [ "$watch_drop_contract" != "t|t|t|t" ]; then
  echo "Expected watch drop to clean reconciliation state, got $watch_drop_contract" >&2
  exit 1
fi

psql_exec -qAt <<'SQL' >/dev/null
DROP TABLE public.otlet_watch_reconciliation_drop_race;
SQL
