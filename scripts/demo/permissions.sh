permission_auditor_role="otlet_demo_auditor"
permission_operator_role="otlet_demo_operator"
permission_denied_count=0

cleanup_permission_roles() {
  local role

  for role in "$permission_auditor_role" "$permission_operator_role"; do
    if [ "$(psql_value -v role_name="$role" <<'SQL'
SELECT count(*) FROM pg_catalog.pg_roles WHERE rolname = :'role_name';
SQL
)" = "1" ]; then
      psql_exec -c "DROP OWNED BY $role" -c "DROP ROLE $role" >/dev/null
    fi
  done
}

expect_permission_denied() {
  local role="$1"
  local statement="$2"
  local label="$3"
  local output

  if output="$(psql_exec -X -c "SET ROLE $role; $statement" 2>&1)"; then
    echo "Expected $label to be denied for $role" >&2
    exit 1
  fi
  require_contains "$output" "permission denied" "Expected permission denied for $label, got $output"
  permission_denied_count=$((permission_denied_count + 1))
}

log "Proving role-scoped access"
cleanup_permission_roles
trap cleanup_permission_roles EXIT

psql_exec >/dev/null <<SQL
CREATE ROLE $permission_auditor_role NOLOGIN;
CREATE ROLE $permission_operator_role NOLOGIN;
SELECT otlet.grant_auditor_access('$permission_auditor_role'::regrole);
SELECT otlet.grant_auditor_access('$permission_auditor_role'::regrole);
SELECT otlet.grant_operator_access('$permission_operator_role'::regrole);
SELECT otlet.grant_operator_access('$permission_operator_role'::regrole);
SQL

permission_apply_action_id="$(psql_value -v task_name="$bounded_action_task" <<'SQL'
SELECT min(a.id)
FROM otlet.actions a
JOIN otlet.jobs j ON j.id = a.job_id
WHERE a.action_type = 'update_row'
  AND a.authority_mode = 'bounded_mutation'
  AND a.evaluation_status = 'evaluated'
  AND a.status = 'approved'
  AND a.approval_status = 'approved'
  AND a.dry_run_status = 'passed'
  AND a.apply_status = 'not_applicable'
  AND j.task_name = :'task_name';
SQL
)"
[ -n "$permission_apply_action_id" ] || {
  echo "Expected an approved bounded update for permission proof" >&2
  exit 1
}

operator_state_before="$(psql_value -v review_action_id="$merge_action_id" -v apply_action_id="$permission_apply_action_id" <<'SQL'
SELECT (
         SELECT string_agg(
           id::text || ':' || status || ':' || approval_status || ':' || dry_run_status || ':' || apply_status,
           '|' ORDER BY id
         )
         FROM otlet.actions
         WHERE id IN (:'review_action_id'::bigint, :'apply_action_id'::bigint)
       ) || '|' ||
       (
         SELECT count(*)::text
         FROM otlet.eval_labels
         WHERE action_id IN (:'review_action_id'::bigint, :'apply_action_id'::bigint)
       );
SQL
)"

auditor_read_contract="$(psql_value <<SQL
BEGIN;
SET LOCAL ROLE $permission_auditor_role;
SELECT (SELECT count(*) = 1 FROM otlet.redaction_policy_status)::text || '|' ||
       (SELECT count(*) = 1 FROM otlet.access_policy_status)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_receipt_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_review_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_review_event_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_action_execution_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_eval_label_export)::text || '|' ||
       (SELECT count(*) >= 0 FROM otlet.audit_workload_evaluation_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.decision_trace_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.action_workflow_policy_status)::text || '|' ||
       (SELECT count(*) >= 0 FROM otlet.cleanup_receipt_status)::text || '|' ||
       (SELECT count(*) >= 0 FROM otlet.retention_hold_status)::text || '|' ||
       (SELECT count(*) = 1 FROM otlet.retention_copy_status)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.semantic_dependency_audit)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.operational_event_log)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.worker_batch_timing_status)::text || '|' ||
       (SELECT count(*) = 1 FROM otlet.database_health_status)::text || '|' ||
       (SELECT count(*) = 1 FROM otlet.portable_protocol_status)::text || '|' ||
       (SELECT count(*) >= 0 FROM otlet.portable_worker_status)::text || '|' ||
       (SELECT count(*) >= 0 FROM otlet.portable_claim_status)::text || '|' ||
       (SELECT count(*) >= 0 FROM otlet.portable_receipt_status)::text;
ROLLBACK;
SQL
)"
echo "auditor_read_contract=$auditor_read_contract"
[ "$auditor_read_contract" = "true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected auditor access to all redacted exports, got $auditor_read_contract" >&2
  exit 1
}

expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.inference_receipts" "auditor receipt table read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.jobs" "auditor jobs table read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.outputs" "auditor outputs table read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.actions" "auditor actions table read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.review_events" "auditor review event table read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.workload_evaluation_runs" "auditor evaluation run table read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.action_targets" "auditor action target read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.action_workflow_policies" "auditor action workflow policy read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.retention_holds" "auditor retention hold table read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.cleanup_runs" "auditor cleanup run table read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.evidence_cleanup_receipts" "auditor cleanup receipt table read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.action_execution_receipts" "auditor action execution receipt read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.inference_receipt_trace_status" "auditor raw receipt view read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.inference_receipt_token_trace" "auditor token trace read"
expect_permission_denied "$permission_auditor_role" "SELECT count(*) FROM otlet.inference_receipt_token_alternative_trace" "auditor token alternative read"
expect_permission_denied "$permission_auditor_role" "SELECT * FROM otlet.approve_action(0)" "auditor action approval"
expect_permission_denied "$permission_auditor_role" "SELECT * FROM otlet.reject_action(0)" "auditor action rejection"
expect_permission_denied "$permission_auditor_role" "SELECT * FROM otlet.label_action(0)" "auditor action labeling"
expect_permission_denied "$permission_auditor_role" "SELECT * FROM otlet.correct_action(0)" "auditor action correction"
expect_permission_denied "$permission_auditor_role" "SELECT * FROM otlet.defer_action(0)" "auditor action deferral"
expect_permission_denied "$permission_auditor_role" "SELECT * FROM otlet.abstain_review(0)" "auditor review abstention"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.import_eval_cases('[]'::jsonb)" "auditor evaluation import"
expect_permission_denied "$permission_auditor_role" "SELECT * FROM otlet.evaluate_workload('denied', 'denied', NULL, '{}'::jsonb)" "auditor workload evaluation"
expect_permission_denied "$permission_auditor_role" "SELECT * FROM otlet.dry_run_action(0)" "auditor action dry run"
expect_permission_denied "$permission_auditor_role" "SELECT * FROM otlet.apply_action(0)" "auditor action apply"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.register_model('denied', '/tmp/denied', repeat('0', 64), jsonb_build_object('sha256', repeat('0', 64), 'bytes', 24, 'source', 'denied', 'revision', 'denied', 'quantization', 'denied', 'license', 'denied'))" "auditor model registration"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.drop_watch('denied')" "auditor watch administration"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.register_action_target('denied', 'public.otlet_demo_bounded_actions'::regclass, 'id', ARRAY['review_state']::name[])" "auditor action target registration"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.disable_action_target('$bounded_action_target')" "auditor action target disable"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.register_action_workflow_policy('$bounded_action_task', 'update_row', '$bounded_action_target')" "auditor action workflow policy registration"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.disable_action_workflow_policy('$bounded_action_task', 'update_row')" "auditor action workflow policy disable"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.place_retention_hold($merge_action_id, 'denied')" "auditor retention hold creation"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.release_retention_hold(0, 'denied')" "auditor retention hold release"
expect_permission_denied "$permission_auditor_role" "SELECT * FROM otlet.request_job_cancellation(0)" "auditor job cancellation"
expect_permission_denied "$permission_auditor_role" "SELECT * FROM otlet.cleanup_policy_state(true)" "auditor cleanup"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.export_watch('$numeric_triage_watch')" "auditor watch export"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.import_watch('{}'::jsonb)" "auditor watch import"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.grant_auditor_access('$permission_auditor_role'::regrole)" "auditor grant helper"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.grant_operator_access('$permission_auditor_role'::regrole)" "auditor operator grant helper"
expect_permission_denied "$permission_auditor_role" "SELECT otlet.grant_portable_worker_access('$permission_auditor_role'::regrole)" "auditor portable worker grant helper"

operator_audit_contract="$(psql_value <<SQL
BEGIN;
UPDATE otlet.actions
SET status = 'proposed', approval_status = 'required', approved_at = NULL, error = NULL
WHERE id = $merge_action_id;
SET LOCAL ROLE $permission_operator_role;
SELECT (SELECT count(*) = 1 FROM otlet.audit_review_export WHERE action_id = $merge_action_id)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_receipt_export)::text || '|' ||
       (SELECT count(*) = 1 FROM otlet.access_policy_status)::text;
ROLLBACK;
SQL
)"
[ "$operator_audit_contract" = "true|true|true" ] || {
  echo "Expected operator access to auditor views, got $operator_audit_contract" >&2
  exit 1
}

operator_approve_contract="$(psql_value -v action_id="$merge_action_id" <<SQL
BEGIN;
UPDATE otlet.actions
SET status = 'proposed', approval_status = 'required', approved_at = NULL, error = NULL
WHERE id = :'action_id'::bigint;
SET LOCAL ROLE $permission_operator_role;
SELECT status || '|' || approval_status
FROM otlet.approve_action(:'action_id'::bigint, 'permission proof');
ROLLBACK;
SQL
)"

operator_reject_contract="$(psql_value -v action_id="$merge_action_id" <<SQL
BEGIN;
UPDATE otlet.actions
SET status = 'proposed', approval_status = 'required', approved_at = NULL, error = NULL
WHERE id = :'action_id'::bigint;
SET LOCAL ROLE $permission_operator_role;
SELECT status || '|' || approval_status
FROM otlet.reject_action(:'action_id'::bigint, 'permission proof');
ROLLBACK;
SQL
)"

operator_label_contract="$(psql_value -v action_id="$merge_action_id" <<SQL
BEGIN;
SET LOCAL ROLE $permission_operator_role;
SELECT count(*)
FROM otlet.label_action(:'action_id'::bigint, label_source => 'approved_action');
ROLLBACK;
SQL
)"

operator_correct_contract="$(psql_value -v action_id="$merge_action_id" <<SQL
BEGIN;
UPDATE otlet.actions
SET status = 'proposed', approval_status = 'required', approved_at = NULL, error = NULL
WHERE id = :'action_id'::bigint;
SET LOCAL ROLE $permission_operator_role;
SELECT count(*)
FROM otlet.correct_action(
  :'action_id'::bigint,
  '{"match":"same_entity","confidence":"high","action_type":"merge_candidate"}'::jsonb,
  'permission proof'
);
ROLLBACK;
SQL
)"

operator_dry_run_contract="$(psql_value -v action_id="$merge_action_id" <<SQL
BEGIN;
UPDATE otlet.actions
SET status = 'approved', approval_status = 'approved', dry_run_status = 'not_run', error = NULL
WHERE id = :'action_id'::bigint;
SET LOCAL ROLE $permission_operator_role;
SELECT dry_run_status
FROM otlet.dry_run_action(:'action_id'::bigint);
ROLLBACK;
SQL
)"

operator_apply_contract="$(psql_value -v action_id="$permission_apply_action_id" <<SQL
BEGIN;
SET LOCAL ROLE $permission_operator_role;
SELECT apply_status
FROM otlet.apply_action(:'action_id'::bigint);
ROLLBACK;
SQL
)"

operator_function_contract="$operator_approve_contract|$operator_reject_contract|$operator_label_contract|$operator_correct_contract|$operator_dry_run_contract|$operator_apply_contract"
echo "operator_function_contract=$operator_function_contract"
[ "$operator_function_contract" = "approved|approved|rejected|rejected|1|1|passed|applied" ] || {
  echo "Expected all operator functions to run through delegated access, got $operator_function_contract" >&2
  exit 1
}

operator_stale_contract="$(psql_value -v action_id="$merge_action_id" <<SQL
BEGIN;
UPDATE otlet.actions
SET status = 'approved', approval_status = 'approved', dry_run_status = 'not_run', error = NULL
WHERE id = :'action_id'::bigint;
UPDATE public.otlet_demo_vendor_entity
SET notes = replace(notes, 'rebranded after acquisition', 'separate vendor without acquisition')
WHERE id = 'vendor-42';
SET LOCAL ROLE $permission_operator_role;
SELECT dry_run_status || '|' || COALESCE(error, '')
FROM otlet.dry_run_action(:'action_id'::bigint);
ROLLBACK;
SQL
)"

operator_invalid_state_contract="$(psql_value -v action_id="$merge_action_id" <<SQL
BEGIN;
UPDATE otlet.actions
SET status = 'rejected', approval_status = 'rejected', dry_run_status = 'not_run', error = NULL
WHERE id = :'action_id'::bigint;
SET LOCAL ROLE $permission_operator_role;
SELECT dry_run_status || '|' || COALESCE(error, '')
FROM otlet.dry_run_action(:'action_id'::bigint);
ROLLBACK;
SQL
)"

operator_fail_closed_contract="$operator_stale_contract|$operator_invalid_state_contract"
echo "operator_fail_closed_contract=$operator_fail_closed_contract"
[ "$operator_fail_closed_contract" = "failed|source identity stale|failed|rejected action cannot be dry-run" ] || {
  echo "Expected delegated stale and invalid action checks to fail closed, got $operator_fail_closed_contract" >&2
  exit 1
}

operator_state_after="$(psql_value -v review_action_id="$merge_action_id" -v apply_action_id="$permission_apply_action_id" <<'SQL'
SELECT (
         SELECT string_agg(
           id::text || ':' || status || ':' || approval_status || ':' || dry_run_status || ':' || apply_status,
           '|' ORDER BY id
         )
         FROM otlet.actions
         WHERE id IN (:'review_action_id'::bigint, :'apply_action_id'::bigint)
       ) || '|' ||
       (
         SELECT count(*)::text
         FROM otlet.eval_labels
         WHERE action_id IN (:'review_action_id'::bigint, :'apply_action_id'::bigint)
       );
SQL
)"
[ "$operator_state_before" = "$operator_state_after" ] || {
  echo "Expected permission transactions to restore action and label state, before=$operator_state_before after=$operator_state_after" >&2
  exit 1
}

bounded_apply_one="$(mktemp)"
bounded_apply_two="$(mktemp)"
psql_exec -qAt <<SQL >"$bounded_apply_one" &
SET ROLE $permission_operator_role;
SELECT action.apply_status
FROM (SELECT pg_sleep(0.2)) barrier
CROSS JOIN LATERAL otlet.apply_action($bounded_apply_action_id) action;
SQL
bounded_apply_one_pid=$!
psql_exec -qAt <<SQL >"$bounded_apply_two" &
SET ROLE $permission_operator_role;
SELECT action.apply_status
FROM (SELECT pg_sleep(0.2)) barrier
CROSS JOIN LATERAL otlet.apply_action($bounded_replay_action_id) action;
SQL
bounded_apply_two_pid=$!
wait "$bounded_apply_one_pid"
wait "$bounded_apply_two_pid"
bounded_concurrent_contract="$(sort "$bounded_apply_one" "$bounded_apply_two" | paste -sd '|' -)"
rm -f "$bounded_apply_one" "$bounded_apply_two"
[ "$bounded_concurrent_contract" = "applied|replayed" ] || {
  echo "Expected concurrent bounded apply contract applied|replayed, got $bounded_concurrent_contract" >&2
  exit 1
}

bounded_replay_contract="$(psql_value <<SQL
SET ROLE $permission_operator_role;
SELECT apply_status FROM otlet.apply_action($bounded_apply_action_id);
SQL
)"
[ "$bounded_replay_contract" = "replayed" ] || {
  echo "Expected bounded replay status replayed, got $bounded_replay_contract" >&2
  exit 1
}

bounded_stale_contract="$(psql_value <<SQL
UPDATE public.otlet_demo_bounded_actions
SET review_reason = 'owner changed after dry run'
WHERE id = 'row-2';
SET ROLE $permission_operator_role;
SELECT apply_status || '|' || COALESCE(error, '')
FROM otlet.apply_action($bounded_stale_action_id);
SQL
)"
[ "$bounded_stale_contract" = "failed|source identity stale" ] || {
  echo "Expected bounded stale apply to fail closed, got $bounded_stale_contract" >&2
  exit 1
}

psql_exec -c "SELECT otlet.disable_action_target('$bounded_action_target')" >/dev/null
bounded_disabled_contract="$(psql_value <<SQL
SET ROLE $permission_operator_role;
SELECT apply_status || '|' || COALESCE(error, '')
FROM otlet.apply_action($bounded_disabled_action_id);
SQL
)"
[ "$bounded_disabled_contract" = "failed|action target is disabled" ] || {
  echo "Expected disabled bounded target to fail closed, got $bounded_disabled_contract" >&2
  exit 1
}

psql_exec -v target_name="$bounded_action_target" >/dev/null <<'SQL'
RESET ROLE;
SELECT otlet.register_action_target(
  :'target_name',
  'public.otlet_demo_bounded_actions'::regclass,
  'id',
  ARRAY['review_state', 'review_reason', 'priority']::name[]
);
SQL

bounded_execution_contract="$(psql_value -v task_name="$bounded_action_task" <<'SQL'
WITH executions AS (
  SELECT receipt.*
  FROM otlet.action_execution_receipts receipt
  JOIN otlet.actions action ON action.id = receipt.action_id
  JOIN otlet.jobs job ON job.id = action.job_id
  WHERE job.task_name = :'task_name'
)
SELECT
  (SELECT review_state || '|' || review_reason || '|' || priority::text || '|' || protected_note
   FROM public.otlet_demo_bounded_actions WHERE id = 'row-1') || '|' ||
  (SELECT review_state || '|' || COALESCE(review_reason, '') || '|' || priority::text || '|' || protected_note
   FROM public.otlet_demo_bounded_actions WHERE id = 'row-3') || '|' ||
  count(*) FILTER (WHERE mode = 'apply' AND status = 'applied')::text || '|' ||
  count(*) FILTER (WHERE mode = 'apply' AND status = 'replayed')::text || '|' ||
  count(*) FILTER (WHERE mode = 'apply' AND status = 'failed')::text || '|' ||
  count(*) FILTER (WHERE to_jsonb(executions)::text LIKE '%DO_NOT_TOUCH_SENTINEL%')::text
FROM executions;
SQL
)"
echo "bounded_execution_contract=$bounded_execution_contract"
[ "$bounded_execution_contract" = "approved|bounded apply|1|DO_NOT_TOUCH_SENTINEL|pending||0|DO_NOT_TOUCH_SENTINEL|1|2|2|0" ] || {
  echo "Unexpected bounded execution contract $bounded_execution_contract" >&2
  exit 1
}

psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_demo_bounded_actions
SET review_reason = NULL
WHERE id = 'row-2';
SQL

expect_permission_denied "$permission_operator_role" "UPDATE otlet.actions SET status = status WHERE false" "operator direct action update"
expect_permission_denied "$permission_operator_role" "SELECT count(*) FROM otlet.action_targets" "operator action target read"
expect_permission_denied "$permission_operator_role" "SELECT count(*) FROM otlet.action_workflow_policies" "operator action workflow policy read"
expect_permission_denied "$permission_operator_role" "SELECT count(*) FROM otlet.retention_holds" "operator retention hold table read"
expect_permission_denied "$permission_operator_role" "SELECT count(*) FROM otlet.cleanup_runs" "operator cleanup run table read"
expect_permission_denied "$permission_operator_role" "SELECT count(*) FROM otlet.evidence_cleanup_receipts" "operator cleanup receipt table read"
expect_permission_denied "$permission_operator_role" "SELECT count(*) FROM otlet.action_execution_receipts" "operator action execution receipt read"
expect_permission_denied "$permission_operator_role" "SELECT count(*) FROM otlet.review_events" "operator review event table read"
expect_permission_denied "$permission_operator_role" "SELECT count(*) FROM otlet.workload_evaluation_runs" "operator evaluation run table read"
expect_permission_denied "$permission_operator_role" "UPDATE public.otlet_demo_bounded_actions SET review_state = review_state WHERE false" "operator direct target update"
expect_permission_denied "$permission_operator_role" "INSERT INTO otlet.eval_labels DEFAULT VALUES" "operator direct eval label insert"
expect_permission_denied "$permission_operator_role" "SELECT otlet.import_eval_cases('[]'::jsonb)" "operator evaluation import"
expect_permission_denied "$permission_operator_role" "SELECT * FROM otlet.evaluate_workload('denied', 'denied', NULL, '{}'::jsonb)" "operator workload evaluation"
expect_permission_denied "$permission_operator_role" "DELETE FROM otlet.inference_receipts WHERE false" "operator direct receipt delete"
expect_permission_denied "$permission_operator_role" "SELECT count(*) FROM otlet.inference_receipt_trace_status" "operator raw receipt view read"
expect_permission_denied "$permission_operator_role" "SELECT count(*) FROM otlet.inference_receipt_token_trace" "operator token trace read"
expect_permission_denied "$permission_operator_role" "SELECT count(*) FROM otlet.inference_receipt_token_alternative_trace" "operator token alternative read"
expect_permission_denied "$permission_operator_role" "SELECT otlet.register_model('denied', '/tmp/denied', repeat('0', 64), jsonb_build_object('sha256', repeat('0', 64), 'bytes', 24, 'source', 'denied', 'revision', 'denied', 'quantization', 'denied', 'license', 'denied'))" "operator model registration"
expect_permission_denied "$permission_operator_role" "SELECT otlet.create_task('denied', 'SELECT 1', 'denied', '{}'::jsonb, 'denied')" "operator task administration"
expect_permission_denied "$permission_operator_role" "SELECT otlet.drop_watch('denied')" "operator watch administration"
expect_permission_denied "$permission_operator_role" "SELECT otlet.register_action_target('denied', 'public.otlet_demo_bounded_actions'::regclass, 'id', ARRAY['review_state']::name[])" "operator action target registration"
expect_permission_denied "$permission_operator_role" "SELECT otlet.disable_action_target('$bounded_action_target')" "operator action target disable"
expect_permission_denied "$permission_operator_role" "SELECT otlet.register_action_workflow_policy('$bounded_action_task', 'update_row', '$bounded_action_target')" "operator action workflow policy registration"
expect_permission_denied "$permission_operator_role" "SELECT otlet.disable_action_workflow_policy('$bounded_action_task', 'update_row')" "operator action workflow policy disable"
expect_permission_denied "$permission_operator_role" "SELECT otlet.place_retention_hold($merge_action_id, 'denied')" "operator retention hold creation"
expect_permission_denied "$permission_operator_role" "SELECT otlet.release_retention_hold(0, 'denied')" "operator retention hold release"
expect_permission_denied "$permission_operator_role" "SELECT * FROM otlet.claim_jobs()" "operator job claim"
expect_permission_denied "$permission_operator_role" "SELECT * FROM otlet.complete_job(0, '{}'::jsonb, '')" "operator job completion"
expect_permission_denied "$permission_operator_role" "SELECT * FROM otlet.fail_job(0, 'denied')" "operator job failure"
expect_permission_denied "$permission_operator_role" "SELECT otlet.sweep_expired_jobs()" "operator job sweep"
expect_permission_denied "$permission_operator_role" "SELECT * FROM otlet.cleanup_policy_state(true)" "operator cleanup"
expect_permission_denied "$permission_operator_role" "SELECT otlet.export_watch('$numeric_triage_watch')" "operator watch export"
expect_permission_denied "$permission_operator_role" "SELECT otlet.import_watch('{}'::jsonb)" "operator watch import"
expect_permission_denied "$permission_operator_role" "SELECT otlet.grant_auditor_access('$permission_operator_role'::regrole)" "operator auditor grant helper"
expect_permission_denied "$permission_operator_role" "SELECT otlet.grant_operator_access('$permission_operator_role'::regrole)" "operator grant helper"
expect_permission_denied "$permission_operator_role" "SELECT otlet.grant_portable_worker_access('$permission_operator_role'::regrole)" "operator portable worker grant helper"

permission_catalog_contract="$(psql_value -v auditor_role="$permission_auditor_role" -v operator_role="$permission_operator_role" <<'SQL'
WITH table_grants AS (
  SELECT
    count(*) FILTER (WHERE grantee = :'auditor_role')::bigint AS auditor_grants,
    count(*) FILTER (WHERE grantee = :'operator_role')::bigint AS operator_grants,
    count(*) FILTER (
      WHERE grantee IN (:'auditor_role', :'operator_role')
        AND (
          privilege_type <> 'SELECT'
          OR table_name NOT IN (
            'redaction_policy_status',
            'access_policy_status',
            'audit_receipt_export',
            'audit_review_export',
            'audit_review_event_export',
            'audit_action_execution_export',
            'audit_eval_label_export',
            'audit_workload_evaluation_export',
            'decision_trace_export',
            'action_workflow_policy_status',
            'cleanup_receipt_status',
            'retention_hold_status',
            'retention_copy_status',
            'semantic_dependency_audit',
            'operational_event_log',
            'worker_batch_timing_status',
            'database_health_status',
            'portable_protocol_status',
            'portable_worker_status',
            'portable_claim_status',
            'portable_receipt_status'
          )
        )
    )::bigint AS unexpected_grants
  FROM information_schema.role_table_grants
  WHERE table_schema = 'otlet'
), function_grants AS (
  SELECT
    count(*) FILTER (WHERE grantee = :'auditor_role')::bigint AS auditor_grants,
    count(*) FILTER (WHERE grantee = :'operator_role')::bigint AS operator_grants,
    count(*) FILTER (
      WHERE grantee = :'auditor_role'
        AND routine_name NOT IN (
          'semantic_canonical_jsonb',
          'semantic_shaped_input',
          'semantic_content_hash'
        )
    )::bigint AS unexpected_auditor_grants,
    count(*) FILTER (
      WHERE grantee = :'operator_role'
        AND routine_name NOT IN (
          'semantic_canonical_jsonb',
          'semantic_shaped_input',
          'semantic_content_hash',
          'approve_action',
          'reject_action',
          'label_action',
          'correct_action',
          'defer_action',
          'abstain_review',
          'dry_run_action',
          'apply_action'
        )
    )::bigint AS unexpected_operator_grants
  FROM information_schema.routine_privileges
  WHERE specific_schema = 'otlet'
), definer_status AS (
  SELECT
    count(*) FILTER (WHERE p.prosecdef)::bigint AS definer_functions,
    count(*) FILTER (
      WHERE p.prosecdef
        AND p.proconfig @> ARRAY['search_path=pg_catalog, otlet, pg_temp']
    )::bigint AS fixed_search_path_functions,
    count(*) FILTER (
      WHERE p.prosecdef
        AND p.oid NOT IN (
          'otlet.approve_action(bigint,text)'::regprocedure,
          'otlet.reject_action(bigint,text,text)'::regprocedure,
          'otlet.label_action(bigint,text,text,text,text,text)'::regprocedure,
          'otlet.correct_action(bigint,jsonb,text)'::regprocedure,
          'otlet.defer_action(bigint,text)'::regprocedure,
          'otlet.abstain_review(bigint,text)'::regprocedure,
          'otlet.dry_run_action(bigint)'::regprocedure,
          'otlet.apply_action(bigint)'::regprocedure,
          'otlet.grant_auditor_access(regrole)'::regprocedure,
          'otlet.grant_operator_access(regrole)'::regprocedure,
          'otlet.grant_portable_worker_access(regrole)'::regprocedure
        )
        AND p.proname NOT IN (
          'portable_claim_jobs',
          'portable_renew_job',
          'portable_record_attempt',
          'portable_complete_job',
          'portable_fail_job',
          'portable_cancel_job',
          'portable_worker_heartbeat'
        )
    )::bigint AS unexpected_definer_functions
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'otlet'
), direct_dml AS (
  SELECT count(*)::bigint AS grants
  FROM information_schema.role_table_grants
  WHERE table_schema = 'otlet'
    AND grantee IN (:'auditor_role', :'operator_role')
    AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER')
)
SELECT access.public_schema_usage::text || '|' ||
       access.public_executable_functions::text || '|' ||
       access.public_table_privileges::text || '|' ||
       access.public_sequence_privileges::text || '|' ||
       table_grants.auditor_grants::text || '|' ||
       function_grants.auditor_grants::text || '|' ||
       table_grants.operator_grants::text || '|' ||
       function_grants.operator_grants::text || '|' ||
       table_grants.unexpected_grants::text || '|' ||
       function_grants.unexpected_auditor_grants::text || '|' ||
       function_grants.unexpected_operator_grants::text || '|' ||
       direct_dml.grants::text || '|' ||
       definer_status.definer_functions::text || '|' ||
       definer_status.fixed_search_path_functions::text || '|' ||
       definer_status.unexpected_definer_functions::text || '|' ||
       access.portable_rpc_functions::text || '|' ||
       access.portable_rpc_security_definer_functions::text || '|' ||
       access.portable_rpc_fixed_search_path_functions::text || '|' ||
       pg_catalog.has_function_privilege(current_user, 'otlet.grant_auditor_access(regrole)', 'EXECUTE')::text
FROM otlet.access_policy_status access
CROSS JOIN table_grants
CROSS JOIN function_grants
CROSS JOIN direct_dml
CROSS JOIN definer_status;
SQL
)"
echo "permission_catalog_contract=$permission_catalog_contract"
[ "$permission_catalog_contract" = "false|0|0|0|21|3|21|11|0|0|0|0|18|18|0|7|7|7|true" ] || {
  echo "Expected exact public, auditor, operator, and owner ACLs, got $permission_catalog_contract" >&2
  exit 1
}

source "$demo_dir/review_provenance.sh"

permission_contract="public=0/0/0|auditor=21/3|operator=21/11|definer=18/18|portable=7/7/7|positive=7|denied=$permission_denied_count"
echo "permission_contract=$permission_contract"
[ "$permission_contract" = "public=0/0/0|auditor=21/3|operator=21/11|definer=18/18|portable=7/7/7|positive=7|denied=77" ] || {
  echo "Expected complete permission contract, got $permission_contract" >&2
  exit 1
}

cleanup_permission_roles
trap - EXIT
