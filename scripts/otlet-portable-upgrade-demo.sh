#!/usr/bin/env bash
set -euo pipefail

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
database="otlet_portable_upgrade_demo_$$"
operator_role="otlet_portable_upgrade_operator_$$"

cleanup() {
  docker exec "$container" dropdb -U postgres --if-exists "$database" >/dev/null 2>&1 || true
  docker exec "$container" psql -U postgres -d postgres -X -q \
    -c "DROP ROLE IF EXISTS $operator_role" >/dev/null 2>&1 || true
}
trap cleanup EXIT

install_portable() {
  docker exec -w /work "$container" \
    psql -U postgres -d "$database" -X -q -v ON_ERROR_STOP=1 \
    -f crates/otlet_worker/sql/install.sql
}

claim_probe_jobs() {
  docker exec "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -c "SELECT count(*) FROM otlet.claim_jobs('model_concurrency_probe', $1)"
}

model_capacity_contract() {
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  status.active_claimed_jobs,
  status.max_active_jobs,
  status.available_active_job_slots,
  status.running_jobs,
  status.cancel_requested_jobs,
  status.expired_running_jobs,
  status.queued_jobs,
  (SELECT count(*) FROM otlet.verify_invariants() violation
   WHERE violation.invariant_name = 'active_claimed_jobs_within_model_cap')
)
FROM otlet.model_queue_status status
WHERE status.model_name = 'model_concurrency_probe';
SQL
}

cleanup
docker exec "$container" createdb -U postgres "$database"
install_portable

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE TABLE public.portable_upgrade_sentinel (
  id integer PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO public.portable_upgrade_sentinel VALUES (1, 'preserved');
SQL

install_portable

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 -v operator_role="$operator_role" <<'SQL' >/dev/null
CREATE ROLE :"operator_role" NOLOGIN;
GRANT USAGE ON SCHEMA otlet TO :"operator_role";
GRANT EXECUTE ON FUNCTION otlet.application_retry_job(bigint, text) TO :"operator_role";
SQL

contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  max(version),
  count(*),
  array_agg(version ORDER BY version) = ARRAY(SELECT generate_series(1, 50)),
  bool_and(file ~ ('(^|/)' || lpad(version::text, 4, '0') || '_')),
  (SELECT value FROM public.portable_upgrade_sentinel),
  (SELECT count(*) FROM otlet.verify_invariants())
)
FROM otlet.portable_schema_migrations;
SQL
)"
[ "$contract" = "50|50|t|t|preserved|0" ] || {
  echo "Portable repeat-install contract mismatch: $contract" >&2
  exit 1
}

application_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 -v operator_role="$operator_role" <<'SQL'
SELECT concat_ws('|',
  (
    SELECT count(*) = 7
    FROM information_schema.columns
    WHERE table_schema = 'otlet'
      AND table_name = 'jobs'
      AND column_name IN (
        'application_owner_role_oid',
        'application_authenticated_role_oid',
        'application_invocation_role_oid',
        'application_request_key',
        'application_request_payload_hash',
        'retry_of_job_id',
        'retry_mode'
      )
  ),
  to_regprocedure('otlet.application_submit_task_subject(text,text,text)') IS NOT NULL,
  to_regprocedure('otlet.application_job_status(bigint)') IS NOT NULL,
  to_regprocedure('otlet.application_cancel_job(bigint)') IS NOT NULL,
  to_regprocedure('otlet.application_retry_job(bigint,text)') IS NOT NULL,
  to_regprocedure('otlet.grant_application_access(regrole)') IS NOT NULL,
  to_regclass('otlet.application_access_policy_status') IS NOT NULL,
  (SELECT application_functions = 3
          AND application_security_definer_functions = 3
          AND application_fixed_search_path_functions = 3
   FROM otlet.application_access_policy_status),
  (SELECT function.prosecdef
          AND function.proconfig @> ARRAY['search_path=pg_catalog, otlet, pg_temp']
   FROM pg_catalog.pg_proc function
   WHERE function.oid = 'otlet.application_retry_job(bigint,text)'::regprocedure),
  pg_catalog.has_schema_privilege(:'operator_role', 'otlet', 'USAGE')
  AND pg_catalog.has_function_privilege(
    :'operator_role',
    'otlet.application_retry_job(bigint,text)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_function_privilege(
    :'operator_role',
    'otlet.application_submit_task_subject(text,text,text)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_table_privilege(:'operator_role', 'otlet.jobs', 'SELECT'),
  (SELECT count(*) = 3
   FROM pg_catalog.pg_constraint constraint_row
   WHERE constraint_row.conrelid = 'otlet.jobs'::regclass
     AND constraint_row.conname IN (
       'jobs_application_provenance_check',
       'jobs_retry_mode_check',
       'jobs_retry_parent_check'
     )),
  (SELECT count(*) = 2
   FROM pg_catalog.pg_indexes index_row
   WHERE index_row.schemaname = 'otlet'
     AND index_row.indexname IN (
       'jobs_application_request_key_idx',
       'jobs_retry_of_job_id_idx'
     )),
  (SELECT count(*) = 0
   FROM pg_catalog.pg_proc function
   JOIN pg_catalog.pg_namespace namespace ON namespace.oid = function.pronamespace
   WHERE namespace.nspname = 'otlet'
     AND function.proname IN (
       'application_submit_task_subject',
       'application_job_status',
       'application_cancel_job',
       'application_retry_job',
       'grant_application_access'
     )
     AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')),
  NOT pg_catalog.has_table_privilege(
    'public',
    'otlet.application_access_policy_status',
    'SELECT'
  )
);
SQL
)"
[ "$application_migration_contract" = "t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable application migration contract mismatch: $application_migration_contract" >&2
  exit 1
}

lifecycle_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*) = 5
   FROM information_schema.columns
   WHERE table_schema = 'otlet'
     AND table_name = 'tasks'
     AND column_name IN (
       'lifecycle_state',
       'lifecycle_revision_hash',
       'lifecycle_previous_revision_hash',
       'lifecycle_promoted_at',
       'lifecycle_changed_at'
     )),
  (SELECT is_nullable = 'NO' AND column_default = '''active''::text'
   FROM information_schema.columns
   WHERE table_schema = 'otlet'
     AND table_name = 'tasks'
     AND column_name = 'lifecycle_state'),
  (SELECT count(*) = 7
   FROM pg_catalog.pg_constraint constraint_row
   WHERE constraint_row.conrelid = 'otlet.tasks'::regclass
     AND constraint_row.conname IN (
       'tasks_lifecycle_state_check',
       'tasks_lifecycle_revision_hash_check',
       'tasks_lifecycle_previous_revision_hash_check',
       'tasks_lifecycle_pin_check',
       'tasks_lifecycle_previous_distinct_check',
       'tasks_lifecycle_revision_fk',
       'tasks_lifecycle_previous_revision_fk'
     )),
  to_regprocedure('otlet.set_task_lifecycle(text,text,text)') IS NOT NULL,
  to_regprocedure('otlet.drop_watch(text,text)') IS NOT NULL,
  to_regprocedure('otlet.drop_watch(text)') IS NOT NULL,
  to_regclass('otlet.task_lifecycle_status') IS NOT NULL,
  NOT EXISTS (SELECT 1 FROM otlet.tasks WHERE lifecycle_state <> 'active'),
  (SELECT count(*) = 0
   FROM pg_catalog.pg_proc function
   WHERE function.oid IN (
     'otlet.set_task_lifecycle(text,text,text)'::regprocedure,
     'otlet.drop_watch(text)'::regprocedure,
     'otlet.drop_watch(text,text)'::regprocedure
   )
     AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')),
  NOT pg_catalog.has_table_privilege('public', 'otlet.task_lifecycle_status', 'SELECT'),
  NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.drop_watch_registry(text)',
    'EXECUTE'
  ),
  to_regprocedure('otlet.watch_source_relation_drift(text,text)') IS NOT NULL
    AND to_regprocedure('otlet.lock_task_source_relations(text)') IS NOT NULL
    AND to_regprocedure('otlet.repair_source_query_contract(text,text)') IS NOT NULL
    AND to_regprocedure('otlet.guard_task_definition_write()') IS NOT NULL
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.watch_source_relation_drift(text,text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.lock_task_source_relations(text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.repair_source_query_contract(text,text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.guard_task_definition_write()',
      'EXECUTE'
    ),
  to_regprocedure('otlet.current_workload_revision_status(text)') IS NOT NULL
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.current_workload_revision_status(text)',
      'EXECUTE'
    ),
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 50
      AND file ~ '0050_task_watch_operational_lifecycle.sql$'
  )
);
SQL
)"
[ "$lifecycle_migration_contract" = "t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable lifecycle migration contract mismatch: $lifecycle_migration_contract" >&2
  exit 1
}

identity_vector_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  otlet.identity_hash(
    'test_vector',
    '{"b":2.00,"a":[1.0,"é"]}'::jsonb
  ) = 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_hash(
    'test_vector',
    '{"a":[1.00,"é"],"b":2}'::jsonb
  ) = 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_hash(
    'other_vector',
    '{"b":2.00,"a":[1.0,"é"]}'::jsonb
  ) <> 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_text_hash(
    'text_vector',
    E'Otlet\n🙂'
  ) = 'otlet:v1:sha256:96077dacfe042898c24b4f06ed6d91b8d21e13a52d36738fe1009032d0d13f72'
);
SQL
)"
[ "$identity_vector_contract" = "t|t|t|t" ] || {
  echo "Portable identity vector contract mismatch: $identity_vector_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
SELECT otlet.register_model(
  'model_concurrency_probe',
  '/tmp/model_concurrency_probe.gguf',
  repeat('1', 64),
  jsonb_build_object(
    'sha256', repeat('1', 64),
    'bytes', 1,
    'source', 'portable-upgrade-demo',
    'revision', 'model-concurrency-v1',
    'quantization', 'test',
    'license', 'test'
  ),
  3
);
SELECT otlet.create_task(
  task_name => 'model_concurrency_probe',
  input_query => NULL,
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'model_concurrency_probe',
  input_shaping => '{"source_fields":["value"]}'::jsonb
);
SQL

portable_task_lifecycle_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL' | tail -n 1
BEGIN;
CREATE TEMP TABLE lifecycle_probe (
  revision_hash text NOT NULL,
  admission_rejected boolean NOT NULL DEFAULT false,
  transition_guarded boolean NOT NULL DEFAULT false,
  identity_change_guarded boolean NOT NULL DEFAULT false,
  unfinished_guarded boolean NOT NULL DEFAULT false
);
INSERT INTO lifecycle_probe (revision_hash)
VALUES (otlet.ensure_active_workload_revision('model_concurrency_probe'));
SELECT otlet.create_watch(
  watch_name => 'portable_lifecycle_identity_probe',
  kind => 'pair',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'model_concurrency_probe',
  candidate_query => 'SELECT ''one''::text AS subject_id, ''{}''::jsonb AS input',
  max_candidate_rows => 1
) \g /dev/null
DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.create_watch(
      watch_name => 'portable_lifecycle_identity_probe',
      kind => 'pair',
      instruction => 'Return an empty object',
      output_schema => '{"type":"object"}'::jsonb,
      model_name => 'model_concurrency_probe',
      candidate_query => 'SELECT ''two''::text AS subject_id, ''{}''::jsonb AS input',
      max_candidate_rows => 1
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('requires retirement and pinned deletion' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE lifecycle_probe SET identity_change_guarded = true;
    RETURN;
  END;
  RAISE EXCEPTION 'watch identity change unexpectedly succeeded';
END
$proof$;
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('model_concurrency_probe', 'lifecycle-queued', '{"value":0}'::jsonb);
SELECT otlet.set_task_lifecycle(
  'model_concurrency_probe',
  'paused',
  (SELECT revision_hash FROM lifecycle_probe)
) \g /dev/null
DO $proof$
BEGIN
  BEGIN
    UPDATE otlet.tasks
    SET lifecycle_state = 'retired'
    WHERE name = 'model_concurrency_probe';
  EXCEPTION WHEN OTHERS THEN
    IF position('require set_task_lifecycle' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE lifecycle_probe SET transition_guarded = true;
    RETURN;
  END;
  RAISE EXCEPTION 'direct lifecycle transition unexpectedly succeeded';
END
$proof$;
DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.set_task_lifecycle(
      'model_concurrency_probe',
      'retired',
      (SELECT revision_hash FROM lifecycle_probe)
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('unfinished jobs' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE lifecycle_probe SET unfinished_guarded = true;
    RETURN;
  END;
  RAISE EXCEPTION 'unfinished task retirement unexpectedly succeeded';
END
$proof$;
DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.admit_task_input(
      'model_concurrency_probe',
      'lifecycle-blocked',
      '{"value":1}'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('is paused' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE lifecycle_probe SET admission_rejected = true;
    RETURN;
  END;
  RAISE EXCEPTION 'paused lifecycle admission unexpectedly succeeded';
END
$proof$;
CREATE TEMP TABLE lifecycle_paused_claims AS
SELECT id FROM otlet.claim_jobs('model_concurrency_probe', 1);
SELECT otlet.set_task_lifecycle(
  'model_concurrency_probe',
  'active',
  (SELECT revision_hash FROM lifecycle_probe)
) \g /dev/null
CREATE TEMP TABLE lifecycle_resumed_claim AS
SELECT id, claim_token FROM otlet.claim_jobs('model_concurrency_probe', 1);
SELECT *
FROM otlet.cancel_job(
  (SELECT id FROM lifecycle_resumed_claim),
  (SELECT claim_token FROM lifecycle_resumed_claim),
  'portable lifecycle proof'
) \g /dev/null
SELECT otlet.set_task_lifecycle(
  'model_concurrency_probe',
  'paused',
  (SELECT revision_hash FROM lifecycle_probe)
) \g /dev/null
SELECT otlet.set_task_lifecycle(
  'model_concurrency_probe',
  'retired',
  (SELECT revision_hash FROM lifecycle_probe)
) \g /dev/null
SELECT concat_ws('|',
  (SELECT lifecycle_state = 'retired'
          AND pinned_workload_revision_hash = (SELECT revision_hash FROM lifecycle_probe)
   FROM otlet.task_lifecycle_status
   WHERE task_name = 'model_concurrency_probe'),
  (SELECT admission_rejected FROM lifecycle_probe),
  (SELECT transition_guarded FROM lifecycle_probe),
  (SELECT identity_change_guarded FROM lifecycle_probe),
  (SELECT unfinished_guarded FROM lifecycle_probe),
  (SELECT count(*) = 0 FROM lifecycle_paused_claims),
  (SELECT count(*) = 1 FROM lifecycle_resumed_claim),
  (SELECT count(*) = 0 FROM otlet.workload_revision_heads
   WHERE task_name = 'model_concurrency_probe'),
  (SELECT count(*) = 1 FROM otlet.workload_revisions
   WHERE task_name = 'model_concurrency_probe'),
  (SELECT count(*) = 1 AND bool_and(status = 'canceled') FROM otlet.jobs
   WHERE task_name = 'model_concurrency_probe'),
  (SELECT count(*) = 0 FROM otlet.verify_invariants())
);
ROLLBACK;
SQL
)"
[ "$portable_task_lifecycle_contract" = "t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable task lifecycle contract mismatch: $portable_task_lifecycle_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
WITH revision AS (
  SELECT otlet.ensure_active_workload_revision('model_concurrency_probe') AS revision_hash
)
INSERT INTO otlet.jobs (task_name, workload_revision_hash, subject_id, input)
SELECT
  'model_concurrency_probe',
  revision_hash,
  'subject-' || subject_number,
  jsonb_build_object('value', subject_number)
FROM revision
CROSS JOIN generate_series(1, 6) AS subject_number;
SQL

batch_claims="$(claim_probe_jobs 8)"
batch_capacity_contract="$(model_capacity_contract)"
[ "$batch_claims|$batch_capacity_contract" = "3|3|3|0|3|0|0|3|0" ] || {
  echo "Portable batch model capacity contract mismatch: $batch_claims|$batch_capacity_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
UPDATE otlet.jobs
SET status = 'queued',
    attempts = 0,
    leased_until = NULL,
    claim_token = NULL,
    started_at = NULL
WHERE task_name = 'model_concurrency_probe';
SQL

docker exec "$container" psql -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -c "BEGIN; SELECT pg_advisory_xact_lock(hashtext('otlet_queue_admission')); SELECT pg_sleep(2); COMMIT" \
  >/dev/null &
capacity_lock_pid=$!
sleep 1
claim_pids=()
for _ in 1 2; do
  claim_probe_jobs 8 >/dev/null &
  claim_pids+=("$!")
done
wait "$capacity_lock_pid"
for claim_pid in "${claim_pids[@]}"; do
  wait "$claim_pid"
done

concurrent_capacity_contract="$(model_capacity_contract)"
[ "$concurrent_capacity_contract" = "3|3|0|3|0|0|3|0" ] || {
  echo "Portable concurrent model capacity contract mismatch: $concurrent_capacity_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
UPDATE otlet.jobs
SET status = 'cancel_requested',
    cancel_requested_at = now(),
    error = 'cancellation requested'
WHERE id = (
  SELECT id
  FROM otlet.jobs
  WHERE task_name = 'model_concurrency_probe'
    AND status = 'running'
  ORDER BY id
  LIMIT 1
);
SQL

cancel_blocked_claims="$(claim_probe_jobs 8)"
[ "$cancel_blocked_claims" = "0" ] || {
  echo "Live cancellation released model capacity: $cancel_blocked_claims" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second',
    attempts = (SELECT max_attempts FROM otlet.production_policy WHERE name = 'default')
WHERE task_name = 'model_concurrency_probe'
  AND status = 'cancel_requested';
SQL

replacement_claims="$(claim_probe_jobs 8)"
lease_capacity_contract="$(model_capacity_contract)"
[ "$replacement_claims|$lease_capacity_contract" = "1|3|3|0|3|1|1|2|0" ] || {
  echo "Portable lease model capacity contract mismatch: $replacement_claims|$lease_capacity_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
DELETE FROM otlet.jobs WHERE task_name = 'model_concurrency_probe';
SELECT otlet.register_model(
  model.name,
  model.artifact_path,
  model.artifact_hash,
  model.artifact_identity,
  1
)
FROM otlet.models model
WHERE model.name = 'model_concurrency_probe';
WITH revision AS (
  SELECT otlet.ensure_active_workload_revision('model_concurrency_probe') AS revision_hash
), inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    status,
    attempts,
    leased_until,
    claim_token,
    started_at
  )
  SELECT
    'model_concurrency_probe',
    revision_hash,
    'renewed',
    '{"value":1}'::jsonb,
    'running',
    (SELECT max_attempts FROM otlet.production_policy WHERE name = 'default'),
    clock_timestamp() + interval '2 seconds',
    'renewal-owner',
    clock_timestamp()
  FROM revision
  RETURNING workload_revision_hash
)
INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input
)
SELECT
  'model_concurrency_probe',
  workload_revision_hash,
  'replacement',
  '{"value":2}'::jsonb
FROM inserted;
SQL

docker exec "$container" psql -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -c "BEGIN; SELECT id FROM otlet.jobs WHERE task_name = 'model_concurrency_probe' AND subject_id = 'renewed' FOR UPDATE; SELECT pg_sleep(5); COMMIT" \
  >/dev/null &
renewal_row_lock_pid=$!
sleep 0.5
docker exec "$container" psql -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -c "SELECT count(*) FROM otlet.renew_job_lease((SELECT id FROM otlet.jobs WHERE task_name = 'model_concurrency_probe' AND subject_id = 'renewed'), 'renewal-owner')" \
  >/dev/null &
renewal_pid=$!
sleep 3
renewal_race_claims="$(claim_probe_jobs 8)"
wait "$renewal_row_lock_pid"
wait "$renewal_pid"

renewal_race_contract="$renewal_race_claims|$(model_capacity_contract)"
[ "$renewal_race_contract" = "1|1|1|0|2|0|1|0|0" ] || {
  echo "Portable renewal race contract mismatch: $renewal_race_contract" >&2
  exit 1
}

echo "portable_upgrade_contract=$contract"
echo "portable_identity_vector_contract=$identity_vector_contract"
echo "portable_application_migration_contract=$application_migration_contract"
echo "portable_lifecycle_migration_contract=$lifecycle_migration_contract"
echo "portable_task_lifecycle_contract=$portable_task_lifecycle_contract"
echo "portable_model_capacity_contract=$batch_claims|$batch_capacity_contract|$concurrent_capacity_contract|$cancel_blocked_claims|$replacement_claims|$lease_capacity_contract"
echo "portable_renewal_race_contract=$renewal_race_contract"
