application_capability_role="otlet_demo_application"
application_login_a="otlet_demo_application_a"
application_login_b="otlet_demo_application_b"
application_operator_role="otlet_demo_application_operator"
application_operator_login="otlet_demo_application_operator_login"
application_task="application_invocation_demo"
application_denied_count=0

cleanup_application_roles() {
  local role

  for role in \
    "$application_login_a" \
    "$application_login_b" \
    "$application_operator_login" \
    "$application_operator_role" \
    "$application_capability_role"; do
    if [ "$(psql_value -v role_name="$role" <<'SQL'
SELECT count(*) FROM pg_catalog.pg_roles WHERE rolname = :'role_name';
SQL
)" = "1" ]; then
      psql_exec -c "DROP OWNED BY $role" -c "DROP ROLE $role" >/dev/null
    fi
  done
}

expect_application_denied() {
  local role="$1"
  local statement="$2"
  local label="$3"
  local output

  if output="$(psql_exec -X -c "SET SESSION AUTHORIZATION $role; $statement" 2>&1)"; then
    echo "Expected $label to be denied for $role" >&2
    exit 1
  fi
  require_contains "$output" "permission denied" "Expected permission denied for $label, got $output"
  application_denied_count=$((application_denied_count + 1))
}

log "Proving least-privilege application invocation"
cleanup_task "$application_task"
cleanup_application_roles

psql_exec \
  -v model_name="$strong_model_name" \
  -v task_name="$application_task" \
  -v capability_role="$application_capability_role" \
  -v login_a="$application_login_a" \
  -v login_b="$application_login_b" \
  -v operator_role="$application_operator_role" \
  -v operator_login="$application_operator_login" >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS public.otlet_demo_application_input (
  id text PRIMARY KEY,
  note text NOT NULL
);
TRUNCATE public.otlet_demo_application_input;
INSERT INTO public.otlet_demo_application_input VALUES
  ('complete-1', 'Return the configured accepted result'),
  ('cancel-1', 'Cancel this request before a worker can see it'),
  ('live-cancel-1', 'Request cancellation after this job holds a live claim'),
  ('concurrent-1', 'Converge concurrent requests on one job');

SELECT otlet.create_task(
  :'task_name',
  $query$
    SELECT source.id AS subject_id,
           jsonb_build_object('row', to_jsonb(source)) AS input
    FROM public.otlet_demo_application_input source
  $query$,
  'Return decision accepted and no actions',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"const":"accepted"}}}'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"source_fields":["row"]}'::jsonb
);
WITH captured AS (
  SELECT otlet.capture_workload_revision(:'task_name') AS revision_hash
), active AS (
  SELECT otlet.ensure_active_workload_revision(:'task_name') AS revision_hash
)
SELECT otlet.promote_workload_revision(
  :'task_name',
  captured.revision_hash,
  active.revision_hash
)
FROM captured
CROSS JOIN active
WHERE captured.revision_hash IS DISTINCT FROM active.revision_hash;

CREATE ROLE :"capability_role" NOLOGIN;
CREATE ROLE :"login_a" LOGIN;
CREATE ROLE :"login_b" LOGIN;
CREATE ROLE :"operator_role" NOLOGIN;
CREATE ROLE :"operator_login" LOGIN;
GRANT :"capability_role" TO :"login_a", :"login_b";
GRANT :"operator_role" TO :"operator_login";
SELECT otlet.grant_application_access(:'capability_role'::regrole);
SELECT otlet.grant_operator_access(:'operator_role'::regrole);
SQL

application_complete_contract="$(psql_value \
  -v task_name="$application_task" \
  -v model_name="$strong_model_name" \
  -v capability_role="$application_capability_role" \
  -v login_a="$application_login_a" \
  -v login_b="$application_login_b" <<'SQL'
BEGIN;
SET SESSION AUTHORIZATION :"login_a";
SET ROLE :"capability_role";
SELECT otlet.application_submit_task_subject(
  :'task_name',
  'complete-1',
  'application-complete-request'
) AS job_id
\gset application_
SELECT otlet.application_submit_task_subject(
  :'task_name',
  'complete-1',
  'application-complete-request'
) AS job_id
\gset exact_
SELECT status AS status,
       (trusted_output IS NULL)::text AS output_is_null
FROM otlet.application_job_status(:'application_job_id'::bigint)
\gset queued_
RESET ROLE;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION :"login_b";
SELECT otlet.application_submit_task_subject(:'task_name', 'complete-1') AS job_id
\gset cross_duplicate_
SELECT count(*) AS visible_rows
FROM otlet.application_job_status(:'application_job_id'::bigint)
\gset cross_
SELECT (otlet.application_cancel_job(:'application_job_id'::bigint) IS NULL)::text AS cancel_is_null
\gset cross_cancel_
RESET SESSION AUTHORIZATION;

UPDATE otlet.jobs
SET status = 'running',
    attempts = 1,
    leased_until = now() + interval '5 minutes',
    claim_token = 'application-complete-claim',
    started_at = now()
WHERE id = :'application_job_id'::bigint
RETURNING id AS job_id, claim_token
\gset claimed_
SELECT id AS output_id
FROM otlet.complete_job(
  job_id => :'application_job_id'::bigint,
  output => '{"decision":"accepted"}'::jsonb,
  raw_output => '{"output":{"decision":"accepted"},"actions":[]}',
  actions => '[]'::jsonb,
  trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
  model_name => :'model_name',
  expected_claim_token => :'claimed_claim_token'
)
\gset completed_

SET SESSION AUTHORIZATION :"login_a";
SELECT status AS status,
       (trusted_output = '{"decision":"accepted"}'::jsonb)::text AS output_matches
FROM otlet.application_job_status(:'application_job_id'::bigint)
\gset trusted_
RESET SESSION AUTHORIZATION;

UPDATE public.otlet_demo_application_input
SET note = 'Return the changed source result'
WHERE id = 'complete-1';

SET SESSION AUTHORIZATION :"login_a";
SET ROLE :"capability_role";
SELECT otlet.application_submit_task_subject(
  :'task_name',
  'complete-1',
  'application-complete-request'
) AS job_id
\gset drift_exact_
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT
  (job.application_owner_role_oid = authenticated.oid)::text AS owner_matches,
  (job.application_authenticated_role_oid = authenticated.oid)::text AS authenticated_matches,
  (job.application_invocation_role_oid = invoked.oid)::text AS invocation_matches,
  (job.application_request_payload_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$')::text AS payload_hash_valid
FROM otlet.jobs job
JOIN pg_catalog.pg_roles authenticated ON authenticated.rolname = :'login_a'
JOIN pg_catalog.pg_roles invoked ON invoked.rolname = :'capability_role'
WHERE job.id = :'application_job_id'::bigint
\gset provenance_

SET SESSION AUTHORIZATION :"login_a";
SELECT otlet.application_cancel_job(:'application_job_id'::bigint) AS status
\gset terminal_cancel_
RESET SESSION AUTHORIZATION;
COMMIT;

SELECT :'queued_status' || '|' ||
       :'queued_output_is_null' || '|' ||
       (:'exact_job_id'::bigint = :'application_job_id'::bigint)::text || '|' ||
       :'cross_duplicate_job_id' || '|' ||
       (:'claimed_job_id'::bigint = :'application_job_id'::bigint)::text || '|' ||
       (:'completed_output_id'::bigint > 0)::text || '|' ||
       :'cross_visible_rows' || '|' ||
       :'cross_cancel_cancel_is_null' || '|' ||
       :'trusted_status' || '|' ||
       :'trusted_output_matches' || '|' ||
       (:'drift_exact_job_id'::bigint = :'application_job_id'::bigint)::text || '|' ||
       :'provenance_owner_matches' || '|' ||
       :'provenance_authenticated_matches' || '|' ||
       :'provenance_invocation_matches' || '|' ||
       :'provenance_payload_hash_valid' || '|' ||
       :'terminal_cancel_status';
SQL
)"
[ "$application_complete_contract" = "queued|true|true|0|true|true|0|true|complete|true|true|true|true|true|true|complete" ] || {
  echo "Expected owned queued and trusted completion state, got $application_complete_contract" >&2
  exit 1
}

if application_key_conflict_output="$(psql_exec -X -c "
  SET SESSION AUTHORIZATION $application_login_a;
  SET ROLE $application_capability_role;
  SELECT otlet.application_submit_task_subject(
    '$application_task',
    'cancel-1',
    'application-complete-request'
  );
" 2>&1)"; then
  echo "Expected changed application request payload to be rejected" >&2
  exit 1
fi
require_contains \
  "$application_key_conflict_output" \
  "otlet application request key was reused with a different payload" \
  "Expected changed application request payload conflict"

application_key_conflict_contract="$(psql_value \
  -v login_a="$application_login_a" <<'SQL'
SELECT count(*)
FROM otlet.jobs job
JOIN pg_catalog.pg_roles role ON role.oid = job.application_owner_role_oid
WHERE role.rolname = :'login_a'
  AND job.application_request_key = 'application-complete-request';
SQL
)"
[ "$application_key_conflict_contract" = "1" ] || {
  echo "Expected payload conflict to leave one keyed job, got $application_key_conflict_contract" >&2
  exit 1
}

application_cancel_contract="$(psql_value \
  -v task_name="$application_task" \
  -v capability_role="$application_capability_role" \
  -v login_a="$application_login_a" \
  -v login_b="$application_login_b" <<'SQL'
BEGIN;
SET SESSION AUTHORIZATION :"login_b";
SET ROLE :"capability_role";
SELECT otlet.application_submit_task_subject(
  :'task_name',
  'cancel-1',
  'application-complete-request'
) AS job_id
\gset application_
SELECT status AS status,
       (trusted_output IS NULL)::text AS output_is_null
FROM otlet.application_job_status(:'application_job_id'::bigint)
\gset queued_
SELECT otlet.application_cancel_job(:'application_job_id'::bigint) AS status
\gset canceled_
SELECT status AS status,
       (trusted_output IS NULL)::text AS output_is_null,
       failure_reason_code,
       failure_stage,
       failure_retryability,
       failure_owner_action,
       recommended_retry_mode,
       raw_detail_visibility,
       (retry_of_job_id IS NULL AND retry_mode IS NULL)::text AS no_retry_lineage
FROM otlet.application_job_status(:'application_job_id'::bigint)
\gset final_
RESET ROLE;
RESET SESSION AUTHORIZATION;
COMMIT;

SELECT (:'application_job_id'::bigint > 0)::text || '|' ||
       :'queued_status' || '|' ||
       :'queued_output_is_null' || '|' ||
       :'canceled_status' || '|' ||
       :'final_status' || '|' ||
       :'final_output_is_null' || '|' ||
       :'final_failure_reason_code' || '|' ||
       :'final_failure_stage' || '|' ||
       :'final_failure_retryability' || '|' ||
       :'final_failure_owner_action' || '|' ||
       :'final_recommended_retry_mode' || '|' ||
       :'final_raw_detail_visibility' || '|' ||
       :'final_no_retry_lineage';
SQL
)"
[ "$application_cancel_contract" = "true|queued|true|canceled|canceled|true|otlet.failure.v1.canceled|cancellation|manual_retry|application_retry_job|original_snapshot|database_owner_only|true" ] || {
  echo "Expected owned queued cancellation, got $application_cancel_contract" >&2
  exit 1
}

application_concurrent_one="$(mktemp)"
application_concurrent_two="$(mktemp)"
psql_exec -qAt \
  -v task_name="$application_task" \
  -v capability_role="$application_capability_role" \
  -v login_b="$application_login_b" >"$application_concurrent_one" <<'SQL' &
BEGIN;
SET SESSION AUTHORIZATION :"login_b";
SET ROLE :"capability_role";
SELECT otlet.application_submit_task_subject(
  :'task_name',
  'concurrent-1',
  'application-concurrent-request'
);
COMMIT;
SQL
application_concurrent_one_pid=$!
psql_exec -qAt \
  -v task_name="$application_task" \
  -v capability_role="$application_capability_role" \
  -v login_b="$application_login_b" >"$application_concurrent_two" <<'SQL' &
BEGIN;
SET SESSION AUTHORIZATION :"login_b";
SET ROLE :"capability_role";
SELECT otlet.application_submit_task_subject(
  :'task_name',
  'concurrent-1',
  'application-concurrent-request'
);
COMMIT;
SQL
application_concurrent_two_pid=$!
wait "$application_concurrent_one_pid"
wait "$application_concurrent_two_pid"
application_concurrent_one_id="$(tr -d '[:space:]' <"$application_concurrent_one")"
application_concurrent_two_id="$(tr -d '[:space:]' <"$application_concurrent_two")"
rm -f "$application_concurrent_one" "$application_concurrent_two"

application_concurrent_contract="$(psql_value \
  -v first_job_id="$application_concurrent_one_id" \
  -v second_job_id="$application_concurrent_two_id" \
  -v login_b="$application_login_b" <<'SQL'
BEGIN;
SELECT
  (:'first_job_id'::bigint = :'second_job_id'::bigint)::text AS same_job,
  (:'first_job_id'::bigint > 0)::text AS valid_job,
  (
    SELECT count(*)
    FROM otlet.jobs job
    JOIN pg_catalog.pg_roles role ON role.oid = job.application_owner_role_oid
    WHERE role.rolname = :'login_b'
      AND job.application_request_key = 'application-concurrent-request'
  ) AS keyed_jobs
\gset concurrent_
SET SESSION AUTHORIZATION :"login_b";
SELECT otlet.application_cancel_job(:'first_job_id'::bigint) AS status
\gset canceled_
RESET SESSION AUTHORIZATION;
COMMIT;
SELECT :'concurrent_same_job' || '|' ||
       :'concurrent_valid_job' || '|' ||
       :'concurrent_keyed_jobs' || '|' ||
       (:'canceled_status' IN ('canceled', 'cancel_requested', 'complete'))::text;
SQL
)"
[ "$application_concurrent_contract" = "true|true|1|true" ] || {
  echo "Expected concurrent keyed requests to converge, got $application_concurrent_contract" >&2
  exit 1
}

application_original_job_id="$(psql_value -v login_a="$application_login_a" <<'SQL'
SELECT job.id
FROM otlet.jobs job
JOIN pg_catalog.pg_roles role ON role.oid = job.application_owner_role_oid
WHERE role.rolname = :'login_a'
  AND job.application_request_key = 'application-complete-request';
SQL
)"

application_original_retry_contract="$(psql_value \
  -v original_job_id="$application_original_job_id" \
  -v login_a="$application_login_a" \
  -v operator_role="$application_operator_role" \
  -v operator_login="$application_operator_login" <<'SQL'
BEGIN;
SET SESSION AUTHORIZATION :"operator_login";
SET ROLE :"operator_role";
SELECT otlet.application_retry_job(
  :'original_job_id'::bigint,
  'original_snapshot'
) AS job_id
\gset retry_
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT
  (child.id > parent.id)::text AS newer_job,
  (child.application_owner_role_oid = owner_role.oid)::text AS owner_preserved,
  (child.application_authenticated_role_oid = authenticated_role.oid)::text AS authenticated_matches,
  (child.application_invocation_role_oid = invocation_role.oid)::text AS invocation_matches,
  (child.input = parent.input)::text AS input_matches,
  (child.workload_revision_hash = parent.workload_revision_hash)::text AS revision_matches,
  (child.retry_of_job_id = parent.id)::text AS lineage_matches,
  child.retry_mode AS retry_mode,
  (child.application_request_key IS NULL)::text AS request_key_is_null,
  (child.application_request_payload_hash = otlet.identity_hash(
    'application_retry_request',
    jsonb_build_object(
      'operation', 'retry_job',
      'job_id', parent.id,
      'retry_mode', child.retry_mode
    )
  ))::text AS payload_hash_valid
FROM otlet.jobs child
JOIN otlet.jobs parent ON parent.id = :'original_job_id'::bigint
JOIN pg_catalog.pg_roles owner_role ON owner_role.rolname = :'login_a'
JOIN pg_catalog.pg_roles authenticated_role ON authenticated_role.rolname = :'operator_login'
JOIN pg_catalog.pg_roles invocation_role ON invocation_role.rolname = :'operator_role'
WHERE child.id = :'retry_job_id'::bigint
\gset proof_

SET SESSION AUTHORIZATION :"login_a";
SELECT count(*) AS visible_rows
FROM otlet.application_job_status(:'retry_job_id'::bigint)
\gset owner_
SELECT otlet.application_cancel_job(:'retry_job_id'::bigint) AS status
\gset canceled_
SELECT
  failure_reason_code,
  (retry_of_job_id = :'original_job_id'::bigint)::text AS lineage_matches,
  retry_mode
FROM otlet.application_job_status(:'retry_job_id'::bigint)
\gset retry_status_
RESET SESSION AUTHORIZATION;
COMMIT;

SELECT :'proof_newer_job' || '|' ||
       :'proof_owner_preserved' || '|' ||
       :'proof_authenticated_matches' || '|' ||
       :'proof_invocation_matches' || '|' ||
       :'proof_input_matches' || '|' ||
       :'proof_revision_matches' || '|' ||
       :'proof_lineage_matches' || '|' ||
       :'proof_retry_mode' || '|' ||
       :'proof_request_key_is_null' || '|' ||
       :'proof_payload_hash_valid' || '|' ||
       :'owner_visible_rows' || '|' ||
       :'canceled_status' || '|' ||
       :'retry_status_failure_reason_code' || '|' ||
       :'retry_status_lineage_matches' || '|' ||
       :'retry_status_retry_mode';
SQL
)"
[ "$application_original_retry_contract" = "true|true|true|true|true|true|true|original_snapshot|true|true|1|canceled|otlet.failure.v1.canceled|true|original_snapshot" ] || {
  echo "Expected original-snapshot retry provenance and ownership, got $application_original_retry_contract" >&2
  exit 1
}

psql_exec -v task_name="$application_task" >/dev/null <<'SQL'
SELECT active_workload_revision_hash AS revision_hash
FROM otlet.workload_revision_heads
WHERE task_name = :'task_name'
\gset prior_
UPDATE otlet.tasks
SET instruction = 'Return decision accepted under the promoted retry revision'
WHERE name = :'task_name';
SELECT otlet.capture_workload_revision(:'task_name') AS revision_hash
\gset promoted_
SELECT otlet.promote_workload_revision(
  :'task_name',
  :'promoted_revision_hash',
  :'prior_revision_hash'
);
SQL

if application_inactive_retry_output="$(psql_exec -X -c "
  SET SESSION AUTHORIZATION $application_operator_login;
  SET ROLE $application_operator_role;
  SELECT otlet.application_retry_job(
    $application_original_job_id,
    'original_snapshot'
  );
" 2>&1)"; then
  echo "Expected inactive original-snapshot retry to be rejected" >&2
  exit 1
fi
require_contains \
  "$application_inactive_retry_output" \
  "otlet workload revision is not active for task $application_task" \
  "Expected inactive original-snapshot retry rejection"

application_latest_retry_file="$(mktemp)"
psql_value \
  -v original_job_id="$application_original_job_id" \
  -v task_name="$application_task" \
  -v capability_role="$application_capability_role" \
  -v login_a="$application_login_a" \
  -v operator_role="$application_operator_role" \
  -v operator_login="$application_operator_login" >"$application_latest_retry_file" <<'SQL'
BEGIN;
SET SESSION AUTHORIZATION :"operator_login";
SET ROLE :"operator_role";
SELECT otlet.application_retry_job(
  :'original_job_id'::bigint,
  'latest_source'
) AS job_id
\gset retry_
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT
  (child.application_owner_role_oid = owner_role.oid)::text AS owner_preserved,
  (child.application_authenticated_role_oid = authenticated_role.oid)::text AS authenticated_matches,
  (child.application_invocation_role_oid = invocation_role.oid)::text AS invocation_matches,
  (child.input IS DISTINCT FROM parent.input)::text AS input_changed,
  (child.input #>> '{row,note}' = 'Return the changed source result')::text AS latest_source,
  (child.workload_revision_hash IS DISTINCT FROM parent.workload_revision_hash)::text AS revision_changed,
  (child.retry_of_job_id = parent.id)::text AS lineage_matches,
  child.retry_mode AS retry_mode,
  (child.application_request_payload_hash = otlet.identity_hash(
    'application_retry_request',
    jsonb_build_object(
      'operation', 'retry_job',
      'job_id', parent.id,
      'retry_mode', child.retry_mode
    )
  ))::text AS payload_hash_valid
FROM otlet.jobs child
JOIN otlet.jobs parent ON parent.id = :'original_job_id'::bigint
JOIN pg_catalog.pg_roles owner_role ON owner_role.rolname = :'login_a'
JOIN pg_catalog.pg_roles authenticated_role ON authenticated_role.rolname = :'operator_login'
JOIN pg_catalog.pg_roles invocation_role ON invocation_role.rolname = :'operator_role'
WHERE child.id = :'retry_job_id'::bigint
\gset proof_

SET SESSION AUTHORIZATION :"login_a";
SET ROLE :"capability_role";
SELECT otlet.application_submit_task_subject(
  :'task_name',
  'complete-1',
  'application-complete-request'
) AS job_id
\gset exact_
SELECT otlet.application_cancel_job(:'retry_job_id'::bigint) AS status
\gset canceled_
RESET ROLE;
RESET SESSION AUTHORIZATION;
COMMIT;

SELECT :'proof_owner_preserved' || '|' ||
       :'proof_authenticated_matches' || '|' ||
       :'proof_invocation_matches' || '|' ||
       :'proof_input_changed' || '|' ||
       :'proof_latest_source' || '|' ||
       :'proof_revision_changed' || '|' ||
       :'proof_lineage_matches' || '|' ||
       :'proof_retry_mode' || '|' ||
       :'proof_payload_hash_valid' || '|' ||
       (:'exact_job_id'::bigint = :'original_job_id'::bigint)::text || '|' ||
       :'canceled_status';
SQL
application_latest_retry_contract="$(tr -d '\n' <"$application_latest_retry_file")"
rm -f "$application_latest_retry_file"
[ "$application_latest_retry_contract" = "true|true|true|true|true|true|true|latest_source|true|true|canceled" ] || {
  echo "Expected latest-source retry provenance and revision, got $application_latest_retry_contract" >&2
  exit 1
}

application_live_cancel_contract="$(psql_value \
  -v task_name="$application_task" \
  -v login_a="$application_login_a" <<'SQL'
BEGIN;
SET SESSION AUTHORIZATION :"login_a";
SELECT otlet.application_submit_task_subject(:'task_name', 'live-cancel-1') AS job_id
\gset application_
RESET SESSION AUTHORIZATION;

UPDATE otlet.jobs
SET status = 'running',
    attempts = 1,
    leased_until = now() + interval '5 minutes',
    claim_token = 'application-live-cancel-claim',
    started_at = now()
WHERE id = :'application_job_id'::bigint;

SET SESSION AUTHORIZATION :"login_a";
SELECT otlet.application_cancel_job(:'application_job_id'::bigint) AS status
\gset cancel_
SELECT status AS status,
       (trusted_output IS NULL)::text AS output_is_null,
       (cancel_requested_at IS NOT NULL)::text AS requested_at_set
FROM otlet.application_job_status(:'application_job_id'::bigint)
\gset final_
RESET SESSION AUTHORIZATION;
COMMIT;

SELECT (:'application_job_id'::bigint > 0)::text || '|' ||
       :'cancel_status' || '|' ||
       :'final_status' || '|' ||
       :'final_output_is_null' || '|' ||
       :'final_requested_at_set';
SQL
)"
[ "$application_live_cancel_contract" = "true|cancel_requested|cancel_requested|true|true" ] || {
  echo "Expected owned live cancellation request, got $application_live_cancel_contract" >&2
  exit 1
}

expect_application_denied "$application_login_a" "SELECT count(*) FROM otlet.jobs" "application jobs table read"
expect_application_denied "$application_login_a" "SELECT count(*) FROM otlet.outputs" "application outputs table read"
expect_application_denied "$application_login_a" "SELECT count(*) FROM otlet.runs" "application owner run view read"
expect_application_denied "$application_login_a" "SELECT count(*) FROM otlet.inference_receipts" "application receipt read"
expect_application_denied "$application_login_a" "SELECT count(*) FROM public.otlet_demo_application_input" "application source read"
expect_application_denied "$application_login_a" "SELECT otlet.create_task('denied', NULL, 'denied', '{}'::jsonb, 'denied')" "application task administration"
expect_application_denied "$application_login_a" "SELECT otlet.register_model('denied', '/tmp/denied', repeat('0', 64), jsonb_build_object('sha256', repeat('0', 64), 'bytes', 1, 'source', 'denied', 'revision', 'denied', 'quantization', 'denied', 'license', 'denied'))" "application model administration"
expect_application_denied "$application_login_a" "SELECT otlet.drop_watch('denied', 'denied')" "application watch administration"
expect_application_denied "$application_login_a" "SELECT otlet.set_task_lifecycle('denied', 'paused', 'denied')" "application task lifecycle administration"
expect_application_denied "$application_login_a" "SELECT count(*) FROM otlet.task_lifecycle_status" "application task lifecycle status"
expect_application_denied "$application_login_a" "SELECT * FROM otlet.approve_action(0)" "application review authority"
expect_application_denied "$application_login_a" "SELECT otlet.application_retry_job(0, 'latest_source')" "application operator retry"
expect_application_denied "$application_login_a" "SELECT * FROM otlet.request_job_cancellation(0)" "application raw cancellation"
expect_application_denied "$application_login_a" "SELECT * FROM otlet.claim_jobs()" "application worker claim"
expect_application_denied "$application_login_a" "SELECT otlet.grant_application_access('$application_capability_role'::regrole)" "application grant helper"

application_acl_contract="$(psql_value \
  -v capability_role="$application_capability_role" \
  -v login_a="$application_login_a" <<'SQL'
SELECT
  pg_catalog.has_schema_privilege(:'login_a', 'otlet', 'USAGE')::text || '|' ||
  (SELECT count(*) FROM information_schema.role_table_grants WHERE grantee = :'capability_role')::text || '|' ||
  (SELECT count(*) FROM information_schema.role_usage_grants WHERE grantee = :'capability_role' AND object_type = 'SEQUENCE')::text || '|' ||
  (SELECT count(*) FROM information_schema.routine_privileges WHERE grantee = :'capability_role' AND specific_schema = 'otlet')::text || '|' ||
  (SELECT count(*) FROM information_schema.routine_privileges
   WHERE grantee = :'capability_role'
     AND specific_schema = 'otlet'
     AND routine_name NOT IN (
       'application_submit_task_subject',
       'application_job_status',
       'application_cancel_job'
     ))::text || '|' ||
  access.application_functions::text || '|' ||
  access.application_security_definer_functions::text || '|' ||
  access.application_fixed_search_path_functions::text
FROM otlet.application_access_policy_status access;
SQL
)"
echo "application_invocation_contract=$application_complete_contract|conflict=$application_key_conflict_contract|$application_cancel_contract|$application_concurrent_contract|$application_original_retry_contract|$application_latest_retry_contract|$application_live_cancel_contract|$application_acl_contract|denied=$application_denied_count"
[ "$application_acl_contract" = "true|0|0|3|0|3|3|3" ] || {
  echo "Expected exact application capability ACLs, got $application_acl_contract" >&2
  exit 1
}
[ "$application_denied_count" = "15" ] || {
  echo "Expected 15 denied application paths, got $application_denied_count" >&2
  exit 1
}

cleanup_task "$application_task"
cleanup_application_roles
