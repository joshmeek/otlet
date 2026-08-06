log "Proving administrative change ledger"

ledger_suffix="$$"
ledger_missing_model="administrative_missing_${ledger_suffix}"
ledger_autocommit_model="administrative_autocommit_${ledger_suffix}"
ledger_access_race_role="otlet_administrative_access_race_${ledger_suffix}"

set +e
missing_context_output="$(
  psql_exec -X -qAt \
    -v model_name="$ledger_missing_model" <<'SQL' 2>&1
SET otlet.administrative_reason = '';
SET otlet.administrative_ticket = '';
SELECT otlet.register_model(
  :'model_name',
  '/tmp/administrative-missing.gguf',
  repeat('1', 64),
  jsonb_build_object(
    'sha256', repeat('1', 64),
    'bytes', 1,
    'source', 'administrative-proof',
    'revision', 'missing',
    'quantization', 'test',
    'license', 'test'
  )
);
SQL
)"
missing_context_status=$?

autocommit_context_output="$(
  psql_exec -X -qAt \
    -v model_name="$ledger_autocommit_model" <<'SQL' 2>&1
SET otlet.administrative_reason = '';
SET otlet.administrative_ticket = '';
SELECT otlet.set_administrative_change_context('autocommit context', NULL);
SELECT otlet.register_model(
  :'model_name',
  '/tmp/administrative-autocommit.gguf',
  repeat('2', 64),
  jsonb_build_object(
    'sha256', repeat('2', 64),
    'bytes', 1,
    'source', 'administrative-proof',
    'revision', 'autocommit',
    'quantization', 'test',
    'license', 'test'
  )
);
SQL
)"
autocommit_context_status=$?
set -e

if [ "$missing_context_status" -eq 0 ] \
   || [[ "$missing_context_output" != *"administrative change requires SET LOCAL"* ]]; then
  echo "Administrative mutation did not reject missing context" >&2
  exit 1
fi
if [ "$autocommit_context_status" -eq 0 ] \
   || [[ "$autocommit_context_output" != *"administrative change requires SET LOCAL"* ]]; then
  echo "Autocommit administrative context leaked into a later statement" >&2
  exit 1
fi

psql_exec -X -q -v role_name="$ledger_access_race_role" <<'SQL' >/dev/null
SELECT format('CREATE ROLE %I NOLOGIN', :'role_name') \gexec
SQL
access_race_pids=()
for _ in 1 2; do
  psql_exec -X -qAt -v role_name="$ledger_access_race_role" <<'SQL' >/dev/null &
BEGIN;
SELECT otlet.set_administrative_change_context(
  'concurrent access grant proof'
) \g /dev/null
SELECT otlet.grant_application_access(:'role_name'::regrole) \g /dev/null
COMMIT;
SQL
  access_race_pids+=("$!")
done
for access_race_pid in "${access_race_pids[@]}"; do
  wait "$access_race_pid"
done

administrative_access_race_contract="$(
  psql_value -v role_name="$ledger_access_race_role" <<'SQL'
SELECT concat_ws('|',
  count(*) = 1,
  bool_and(
    operation = 'grant'
    AND actor_name = session_user
    AND active_role_name = session_user
    AND reason = 'concurrent access grant proof'
    AND ticket IS NULL
    AND old_revision_hash IS NOT NULL
    AND new_revision_hash IS NOT NULL
  )
)
FROM otlet.administrative_change_events
WHERE object_type = 'access_policy'
  AND object_name = 'application:' || :'role_name';
SQL
)"
[ "$administrative_access_race_contract" = "t|t" ] || {
  echo "Concurrent access grants did not serialize: $administrative_access_race_contract" >&2
  exit 1
}
psql_exec -X -q -v role_name="$ledger_access_race_role" <<'SQL' >/dev/null
SELECT format('DROP OWNED BY %I', :'role_name') \gexec
SELECT format('DROP ROLE %I', :'role_name') \gexec
SQL

ledger_model_a="administrative_model_a_${ledger_suffix}"
ledger_model_b="administrative_model_b_${ledger_suffix}"
ledger_renamed_model="administrative_model_renamed_${ledger_suffix}"
ledger_rollback_model="administrative_rollback_${ledger_suffix}"
ledger_source="otlet_administrative_source_${ledger_suffix}"
ledger_watch="administrative_watch_${ledger_suffix}"
ledger_task="${ledger_watch}_task"
ledger_first_task="administrative_first_task_${ledger_suffix}"
ledger_renamed_task="administrative_task_renamed_${ledger_suffix}"
ledger_target="administrative_target_${ledger_suffix}"
ledger_renamed_target="administrative_target_renamed_${ledger_suffix}"
ledger_delegate_role="otlet_administrative_delegate_${ledger_suffix}"
ledger_auditor_role="otlet_administrative_auditor_${ledger_suffix}"
ledger_operator_role="otlet_administrative_operator_${ledger_suffix}"
ledger_application_role="otlet_administrative_application_${ledger_suffix}"
ledger_portable_role="otlet_administrative_portable_${ledger_suffix}"

administrative_change_ledger_contract="$(
  psql_exec -X -qAt \
    -v model_a="$ledger_model_a" \
    -v model_b="$ledger_model_b" \
    -v renamed_model="$ledger_renamed_model" \
    -v rollback_model="$ledger_rollback_model" \
    -v source_table="public.$ledger_source" \
    -v watch_name="$ledger_watch" \
    -v task_name="$ledger_task" \
    -v first_task="$ledger_first_task" \
    -v renamed_task="$ledger_renamed_task" \
    -v target_name="$ledger_target" \
    -v renamed_target="$ledger_renamed_target" \
    -v delegate_role="$ledger_delegate_role" \
    -v auditor_role="$ledger_auditor_role" \
    -v operator_role="$ledger_operator_role" \
    -v application_role="$ledger_application_role" \
    -v portable_role="$ledger_portable_role" <<'SQL' | tail -n 1
BEGIN;
SELECT otlet.set_administrative_change_context(
  'administrative ledger executable proof',
  NULL
) \g /dev/null

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

SELECT format('CREATE ROLE %I NOLOGIN', role_name)
FROM unnest(ARRAY[
  :'delegate_role',
  :'auditor_role',
  :'operator_role',
  :'application_role',
  :'portable_role'
]) role(role_name)
\gexec

SELECT otlet.register_model(
  :'model_a',
  '/tmp/administrative-model-a.gguf',
  repeat('a', 64),
  jsonb_build_object(
    'sha256', repeat('a', 64),
    'bytes', 1,
    'source', 'administrative-proof',
    'revision', 'model-a',
    'quantization', 'test',
    'license', 'test'
  ),
  1
) \g /dev/null
SELECT otlet.register_model(
  :'model_a',
  '/tmp/administrative-model-a.gguf',
  repeat('a', 64),
  jsonb_build_object(
    'sha256', repeat('a', 64),
    'bytes', 1,
    'source', 'administrative-proof',
    'revision', 'model-a',
    'quantization', 'test',
    'license', 'test'
  ),
  1
) \g /dev/null
SELECT otlet.register_model(
  :'model_a',
  '/tmp/administrative-model-a.gguf',
  repeat('a', 64),
  jsonb_build_object(
    'sha256', repeat('a', 64),
    'bytes', 1,
    'source', 'administrative-proof',
    'revision', 'model-a',
    'quantization', 'test',
    'license', 'test'
  ),
  2
) \g /dev/null
SELECT otlet.register_model(
  :'model_b',
  '/tmp/administrative-model-b.gguf',
  repeat('b', 64),
  jsonb_build_object(
    'sha256', repeat('b', 64),
    'bytes', 1,
    'source', 'administrative-proof',
    'revision', 'model-b',
    'quantization', 'test',
    'license', 'test'
  ),
  1
) \g /dev/null

SELECT otlet.create_task(
  task_name => :'first_task',
  input_query => NULL,
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => :'model_a'
) \g /dev/null
UPDATE otlet.tasks SET name = :'renamed_task' WHERE name = :'first_task';
UPDATE otlet.tasks SET name = :'first_task' WHERE name = :'renamed_task';
SELECT otlet.ensure_active_workload_revision(:'first_task') \g /dev/null

SELECT otlet.create_watch(
  watch_name => :'watch_name',
  kind => 'row',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => :'model_a',
  table_name => to_regclass(:'source_table'),
  subject_column => 'id',
  input_columns => ARRAY['id', 'payload'],
  action_types => ARRAY['update_row'],
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb
) \g /dev/null
SELECT otlet.set_model_selection_policy(
  :'task_name',
  :'model_a',
  :'model_b'
) \g /dev/null
SELECT otlet.promote_configured_workload_revision(:'task_name') \g /dev/null

UPDATE otlet.tasks
SET instruction = instruction || ' revised'
WHERE name = :'task_name';
SELECT otlet.promote_configured_workload_revision(:'task_name') \g /dev/null

SELECT otlet.register_action_target(
  :'target_name',
  to_regclass(:'source_table'),
  'id',
  ARRAY['payload']::name[]
) \g /dev/null
UPDATE otlet.action_targets SET name = :'renamed_target' WHERE name = :'target_name';
UPDATE otlet.action_targets SET name = :'target_name' WHERE name = :'renamed_target';
CREATE TEMP TABLE administrative_recertification_count ON COMMIT DROP AS
SELECT
  count(*) AS event_count,
  max(event_id) AS last_event_id,
  (array_agg(new_revision_hash ORDER BY event_id DESC))[1] AS revision_hash
FROM otlet.administrative_change_events
WHERE object_type = 'action_policy'
  AND object_name = 'target:' || :'target_name';
SELECT format(
  'ALTER TABLE %s RENAME TO %I',
  target.target_table,
  split_part(:'source_table', '.', 2) || '_renamed'
)
FROM otlet.action_targets target
WHERE target.name = :'target_name'
\gexec
SELECT otlet.register_action_target(
  :'target_name',
  (SELECT target_table FROM otlet.action_targets WHERE name = :'target_name'),
  'id',
  ARRAY['payload']::name[]
) \g /dev/null
SELECT format(
  'ALTER TABLE %s RENAME TO %I',
  target.target_table,
  split_part(:'source_table', '.', 2)
)
FROM otlet.action_targets target
WHERE target.name = :'target_name'
\gexec
SELECT otlet.register_action_target(
  :'target_name',
  to_regclass(:'source_table'),
  'id',
  ARRAY['payload']::name[]
) \g /dev/null
SELECT otlet.register_action_target(
  :'target_name',
  to_regclass(:'source_table'),
  'id',
  ARRAY['payload']::name[]
) \g /dev/null
SELECT otlet.register_action_workflow_policy(
  :'task_name',
  'update_row',
  :'target_name',
  'recommendation_only',
  'evaluated'
) \g /dev/null
SELECT otlet.disable_action_workflow_policy(:'task_name', 'update_row') \g /dev/null

CREATE TEMP TABLE administrative_guard_proof (
  model_identity_guarded boolean NOT NULL DEFAULT false,
  insert_guarded boolean NOT NULL DEFAULT false,
  update_guarded boolean NOT NULL DEFAULT false,
  delete_guarded boolean NOT NULL DEFAULT false,
  truncate_guarded boolean NOT NULL DEFAULT false
) ON COMMIT DROP;
INSERT INTO administrative_guard_proof DEFAULT VALUES;
CREATE TEMP TABLE administrative_parameters ON COMMIT DROP AS
SELECT
  :'model_a'::text AS model_a,
  :'model_b'::text AS model_b,
  :'renamed_model'::text AS renamed_model,
  :'rollback_model'::text AS rollback_model;

DO $proof$
BEGIN
  BEGIN
    UPDATE otlet.models
    SET name = (SELECT renamed_model FROM administrative_parameters)
    WHERE name = (SELECT model_b FROM administrative_parameters);
    RAISE EXCEPTION 'model identity mutation was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
      'otlet model name and artifact identity are immutable; register a new model name' THEN
      RAISE;
    END IF;
    UPDATE administrative_guard_proof SET model_identity_guarded = true;
  END;

  BEGIN
    INSERT INTO otlet.administrative_change_events (
      object_type,
      object_name,
      operation,
      actor_oid,
      actor_name,
      active_role_oid,
      active_role_name,
      reason,
      new_revision_hash
    ) VALUES (
      'model',
      'forged',
      'insert',
      (SELECT oid FROM pg_roles WHERE rolname = session_user),
      session_user,
      (SELECT oid FROM pg_roles WHERE rolname = session_user),
      session_user,
      'forged',
      otlet.identity_hash('administrative_model', '{"forged":true}'::jsonb)
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('append only' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE administrative_guard_proof SET insert_guarded = true;
  END;

  BEGIN
    UPDATE otlet.administrative_change_events
    SET reason = 'changed'
    WHERE object_name = (SELECT model_a FROM administrative_parameters);
  EXCEPTION WHEN OTHERS THEN
    IF position('append only' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE administrative_guard_proof SET update_guarded = true;
  END;

  BEGIN
    DELETE FROM otlet.administrative_change_events
    WHERE object_name = (SELECT model_a FROM administrative_parameters);
  EXCEPTION WHEN OTHERS THEN
    IF position('append only' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE administrative_guard_proof SET delete_guarded = true;
  END;

  BEGIN
    TRUNCATE
      otlet.administrative_change_events,
      otlet.workload_pack_events,
      otlet.workload_pack_definitions;
  EXCEPTION WHEN OTHERS THEN
    IF position('append only' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE administrative_guard_proof SET truncate_guarded = true;
  END;
END
$proof$;

DO $proof$
DECLARE
  parameters record;
BEGIN
  SELECT * INTO parameters FROM administrative_parameters;
  BEGIN
    PERFORM otlet.register_model(
      parameters.rollback_model,
      '/tmp/administrative-rollback.gguf',
      repeat('c', 64),
      jsonb_build_object(
        'sha256', repeat('c', 64),
        'bytes', 1,
        'source', 'administrative-proof',
        'revision', 'rollback',
        'quantization', 'test',
        'license', 'test'
      )
    );
    RAISE EXCEPTION 'administrative ledger rollback marker';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'administrative ledger rollback marker' THEN
      RAISE;
    END IF;
  END;
END
$proof$;

CREATE TEMP TABLE administrative_policy_copy ON COMMIT DROP AS
SELECT * FROM otlet.production_policy WHERE name = 'default';
DELETE FROM otlet.production_policy WHERE name = 'default';
INSERT INTO otlet.production_policy SELECT * FROM administrative_policy_copy;

CREATE TEMP TABLE administrative_operational_count AS
SELECT count(*) AS event_count
FROM otlet.administrative_change_events;
UPDATE otlet.models SET last_used_at = now() WHERE name = :'model_a';
UPDATE otlet.production_policy
SET worker_claim_task_cursor = worker_claim_task_cursor || '_proof'
WHERE name = 'default';
SELECT set_config('otlet.administrative_suppress', 'on', true) \g /dev/null
UPDATE otlet.action_targets
SET contract_generation = contract_generation + 1
WHERE name = :'target_name';
UPDATE otlet.action_targets
SET contract_generation = contract_generation - 1
WHERE name = :'target_name';
SELECT set_config('otlet.administrative_suppress', '', true) \g /dev/null

SELECT otlet.set_administrative_change_context(NULL, 'OTLET-51') \g /dev/null
SET LOCAL intervalstyle = 'iso_8601';
UPDATE otlet.production_policy
SET worker_event_retention = worker_event_retention + interval '1 day'
WHERE name = 'default';

SELECT format('GRANT USAGE ON SCHEMA otlet TO %I', :'delegate_role') \gexec
SELECT format(
  'GRANT EXECUTE ON FUNCTION otlet.grant_auditor_access(regrole) TO %I',
  :'delegate_role'
) \gexec
SELECT format('SET LOCAL ROLE %I', :'delegate_role') \gexec
SELECT otlet.grant_auditor_access(:'auditor_role'::regrole) \g /dev/null
RESET ROLE;
SELECT otlet.grant_operator_access(:'operator_role'::regrole) \g /dev/null
SELECT otlet.grant_application_access(:'application_role'::regrole) \g /dev/null
SELECT otlet.grant_portable_worker_access(:'portable_role'::regrole) \g /dev/null

SELECT format('SET LOCAL ROLE %I', :'auditor_role') \gexec
SELECT count(*) > 0 AS auditor_ledger_read
FROM otlet.audit_administrative_change_export
WHERE object_type = 'access_policy'
\gset
RESET ROLE;

WITH model_chain AS (
  SELECT
    event_id,
    old_revision_hash,
    new_revision_hash,
    lag(new_revision_hash) OVER (ORDER BY event_id) AS prior_revision_hash
  FROM otlet.administrative_change_events
  WHERE object_type = 'model'
    AND object_name = :'model_a'
), access_chain AS (
  SELECT
    event_id,
    old_revision_hash,
    lag(new_revision_hash) OVER (ORDER BY event_id) AS prior_revision_hash
  FROM otlet.administrative_change_events
  WHERE object_type = 'access_policy'
    AND object_name IN (
      'auditor:' || :'operator_role',
      'operator:' || :'operator_role'
    )
), retention_chain AS (
  SELECT
    event_id,
    operation,
    old_revision_hash,
    new_revision_hash,
    lag(new_revision_hash) OVER (ORDER BY event_id) AS prior_revision_hash
  FROM otlet.administrative_change_events
  WHERE object_type = 'retention'
    AND object_name = 'default'
), target_recertification_chain AS (
  SELECT
    event_id,
    old_revision_hash,
    lag(
      new_revision_hash,
      1,
      (SELECT revision_hash FROM administrative_recertification_count)
    ) OVER (ORDER BY event_id) AS prior_revision_hash
  FROM otlet.administrative_change_events
  WHERE object_type = 'action_policy'
    AND object_name = 'target:' || :'target_name'
    AND event_id > (
      SELECT last_event_id FROM administrative_recertification_count
    )
), categories AS (
  SELECT array_agg(DISTINCT object_type ORDER BY object_type) AS observed
  FROM otlet.administrative_change_events
  WHERE object_name IN (
    :'model_a',
    :'model_b',
    :'first_task',
    :'task_name',
    :'watch_name',
    :'target_name',
    'target:' || :'target_name',
    'workflow:' || :'task_name' || ':update_row',
    'default',
    'auditor:' || :'auditor_role',
    'operator:' || :'operator_role',
    'application:' || :'application_role',
    'portable_worker:' || :'portable_role'
  )
), contract AS (
  SELECT concat_ws('|',
    categories.observed = ARRAY[
      'access_policy',
      'action_policy',
      'model',
      'retention',
      'selection',
      'task',
      'watch'
    ]::text[],
    (SELECT count(*) = 2
       AND bool_and(
         CASE
           WHEN prior_revision_hash IS NULL THEN old_revision_hash IS NULL
           ELSE old_revision_hash = prior_revision_hash
         END
       )
     FROM model_chain),
    (SELECT count(*) = 2
            AND bool_and(
              prior_revision_hash IS NULL
              OR old_revision_hash = prior_revision_hash
            )
     FROM access_chain),
    (SELECT count(*) = 3
            AND array_agg(operation ORDER BY event_id) = ARRAY['delete', 'insert', 'update']
            AND bool_and(
              (operation = 'insert' AND old_revision_hash IS NULL AND new_revision_hash IS NOT NULL)
              OR (operation = 'delete' AND old_revision_hash IS NOT NULL AND new_revision_hash IS NULL)
              OR (operation = 'update' AND old_revision_hash IS NOT NULL AND new_revision_hash IS NOT NULL)
            )
            AND bool_and(
              prior_revision_hash IS NULL
              OR old_revision_hash = prior_revision_hash
            )
     FROM retention_chain),
    (SELECT model_identity_guarded FROM administrative_guard_proof)
      AND EXISTS (
        SELECT 1 FROM otlet.models WHERE name = :'model_b'
      )
      AND NOT EXISTS (
        SELECT 1 FROM otlet.models WHERE name = :'renamed_model'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.administrative_change_events
        WHERE object_type = 'model'
          AND object_name = :'renamed_model'
      ) AND EXISTS (
      SELECT 1
      FROM otlet.administrative_change_events
      WHERE object_type = 'task'
        AND object_name = :'renamed_task'
        AND operation = 'update'
        AND old_revision_hash IS NOT NULL
        AND new_revision_hash IS NOT NULL
    ) AND EXISTS (
      SELECT 1
      FROM otlet.administrative_change_events
      WHERE object_type = 'action_policy'
        AND object_name = 'target:' || :'renamed_target'
        AND operation = 'update'
        AND old_revision_hash IS NOT NULL
        AND new_revision_hash IS NOT NULL
    ),
    (SELECT event_count + 3 = (
              SELECT count(*)
              FROM otlet.administrative_change_events
              WHERE object_type = 'action_policy'
                AND object_name = 'target:' || :'target_name'
            )
     FROM administrative_recertification_count),
    (SELECT count(*) = 3
            AND bool_and(old_revision_hash = prior_revision_hash)
     FROM target_recertification_chain),
    EXISTS (
      SELECT 1
      FROM otlet.administrative_change_events
      WHERE object_type = 'task'
        AND object_name = :'task_name'
        AND operation = 'promote'
        AND old_revision_hash IS NOT NULL
        AND new_revision_hash IS NOT NULL
    ),
    NOT EXISTS (
      SELECT 1
      FROM otlet.administrative_change_events
      WHERE object_type = 'task'
        AND object_name = :'first_task'
        AND operation = 'promote'
    ),
    EXISTS (
      SELECT 1
      FROM otlet.administrative_change_events
      WHERE object_type = 'access_policy'
        AND object_name = 'auditor:' || :'auditor_role'
        AND actor_name = session_user
        AND active_role_name = :'delegate_role'
        AND reason IS NULL
        AND ticket = 'OTLET-51'
        AND old_revision_hash IS NOT NULL
        AND new_revision_hash IS NOT NULL
    ),
    EXISTS (
      SELECT 1
      FROM otlet.administrative_change_events
      WHERE object_type = 'model'
        AND object_name = :'model_a'
        AND reason = 'administrative ledger executable proof'
        AND ticket IS NULL
    ) AND EXISTS (
      SELECT 1
      FROM otlet.administrative_change_events
      WHERE object_type = 'retention'
        AND object_name = 'default'
        AND reason IS NULL
        AND ticket = 'OTLET-51'
    ),
    NOT EXISTS (SELECT 1 FROM otlet.models WHERE name = :'rollback_model')
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.administrative_change_events
        WHERE object_name = :'rollback_model'
      ),
    (SELECT insert_guarded AND update_guarded AND delete_guarded AND truncate_guarded
     FROM administrative_guard_proof),
    (SELECT event_count = (SELECT count(*) FROM otlet.administrative_change_events) - 6
     FROM administrative_operational_count),
    :'auditor_ledger_read'::boolean
      AND pg_catalog.has_table_privilege(
        :'auditor_role',
        'otlet.audit_administrative_change_export',
        'SELECT'
      )
      AND NOT pg_catalog.has_table_privilege(
        :'auditor_role',
        'otlet.administrative_change_events',
        'SELECT'
      ),
    (SELECT 'otlet.audit_administrative_change_export' = ANY(export_views)
     FROM otlet.redaction_policy_status),
    NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.administrative_change_events',
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
    )
      AND NOT pg_catalog.has_table_privilege(
        'public',
        'otlet.audit_administrative_change_export',
        'SELECT'
      )
      AND NOT pg_catalog.has_sequence_privilege(
        'public',
        'otlet.administrative_change_events_event_id_seq',
        'USAGE,SELECT,UPDATE'
      )
      AND NOT pg_catalog.has_function_privilege(
        'public',
        'otlet.append_administrative_change(text,text,text,text,text)',
        'EXECUTE'
      ),
    NOT EXISTS (
      SELECT 1
      FROM otlet.administrative_change_events event
      WHERE num_nonnulls(event.reason, event.ticket) = 0
         OR num_nonnulls(event.old_revision_hash, event.new_revision_hash) = 0
         OR event.old_revision_hash IS NOT DISTINCT FROM event.new_revision_hash
         OR COALESCE(event.old_revision_hash, event.new_revision_hash)
           !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
    ),
    NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
  ) AS value
  FROM categories
)
SELECT 'administrative_change_ledger_contract=' || contract.value
FROM contract;
ROLLBACK;
SQL
)"

expected_administrative_change_ledger_contract="administrative_change_ledger_contract=t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t"
if [ "$administrative_change_ledger_contract" != "$expected_administrative_change_ledger_contract" ]; then
  echo "Administrative change ledger contract failed: $administrative_change_ledger_contract" >&2
  exit 1
fi

if [ "$(psql_value -v missing_model="$ledger_missing_model" -v autocommit_model="$ledger_autocommit_model" <<'SQL'
SELECT count(*)
FROM otlet.models
WHERE name IN (:'missing_model', :'autocommit_model');
SQL
)" != "0" ]; then
  echo "Rejected administrative context probes left model state" >&2
  exit 1
fi

echo "$administrative_change_ledger_contract"
echo "administrative_access_race_contract=$administrative_access_race_contract"
