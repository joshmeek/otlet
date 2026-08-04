application_capability_role="otlet_demo_application"
application_login_a="otlet_demo_application_a"
application_login_b="otlet_demo_application_b"
application_task="application_invocation_demo"
application_denied_count=0

cleanup_application_roles() {
  local role

  for role in "$application_login_a" "$application_login_b" "$application_capability_role"; do
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
  -v login_b="$application_login_b" >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS public.otlet_demo_application_input (
  id text PRIMARY KEY,
  note text NOT NULL
);
TRUNCATE public.otlet_demo_application_input;
INSERT INTO public.otlet_demo_application_input VALUES
  ('complete-1', 'Return the configured accepted result'),
  ('cancel-1', 'Cancel this request before a worker can see it'),
  ('live-cancel-1', 'Request cancellation after this job holds a live claim');

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
SELECT otlet.ensure_active_workload_revision(:'task_name');

CREATE ROLE :"capability_role" NOLOGIN;
CREATE ROLE :"login_a" LOGIN;
CREATE ROLE :"login_b" LOGIN;
GRANT :"capability_role" TO :"login_a", :"login_b";
SELECT otlet.grant_application_access(:'capability_role'::regrole);
SQL

application_complete_contract="$(psql_value \
  -v task_name="$application_task" \
  -v model_name="$strong_model_name" \
  -v login_a="$application_login_a" \
  -v login_b="$application_login_b" <<'SQL'
BEGIN;
SET SESSION AUTHORIZATION :"login_a";
SELECT otlet.application_submit_task_subject(:'task_name', 'complete-1') AS job_id
\gset application_
SELECT status AS status,
       (trusted_output IS NULL)::text AS output_is_null
FROM otlet.application_job_status(:'application_job_id'::bigint)
\gset queued_
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
SELECT otlet.application_cancel_job(:'application_job_id'::bigint) AS status
\gset terminal_cancel_
RESET SESSION AUTHORIZATION;
COMMIT;

SELECT :'queued_status' || '|' ||
       :'queued_output_is_null' || '|' ||
       :'cross_duplicate_job_id' || '|' ||
       (:'claimed_job_id'::bigint = :'application_job_id'::bigint)::text || '|' ||
       (:'completed_output_id'::bigint > 0)::text || '|' ||
       :'cross_visible_rows' || '|' ||
       :'cross_cancel_cancel_is_null' || '|' ||
       :'trusted_status' || '|' ||
       :'trusted_output_matches' || '|' ||
       :'terminal_cancel_status';
SQL
)"
[ "$application_complete_contract" = "queued|true|0|true|true|0|true|complete|true|complete" ] || {
  echo "Expected owned queued and trusted completion state, got $application_complete_contract" >&2
  exit 1
}

application_cancel_contract="$(psql_value \
  -v task_name="$application_task" \
  -v login_a="$application_login_a" \
  -v login_b="$application_login_b" <<'SQL'
BEGIN;
SET SESSION AUTHORIZATION :"login_b";
SELECT otlet.application_submit_task_subject(:'task_name', 'cancel-1') AS job_id
\gset application_
SELECT status AS status,
       (trusted_output IS NULL)::text AS output_is_null
FROM otlet.application_job_status(:'application_job_id'::bigint)
\gset queued_
SELECT otlet.application_cancel_job(:'application_job_id'::bigint) AS status
\gset canceled_
SELECT status AS status,
       (trusted_output IS NULL)::text AS output_is_null
FROM otlet.application_job_status(:'application_job_id'::bigint)
\gset final_
RESET SESSION AUTHORIZATION;
COMMIT;

SELECT (:'application_job_id'::bigint > 0)::text || '|' ||
       :'queued_status' || '|' ||
       :'queued_output_is_null' || '|' ||
       :'canceled_status' || '|' ||
       :'final_status' || '|' ||
       :'final_output_is_null';
SQL
)"
[ "$application_cancel_contract" = "true|queued|true|canceled|canceled|true" ] || {
  echo "Expected owned queued cancellation, got $application_cancel_contract" >&2
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
expect_application_denied "$application_login_a" "SELECT otlet.drop_watch('denied')" "application watch administration"
expect_application_denied "$application_login_a" "SELECT * FROM otlet.approve_action(0)" "application review authority"
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
echo "application_invocation_contract=$application_complete_contract|$application_cancel_contract|$application_live_cancel_contract|$application_acl_contract|denied=$application_denied_count"
[ "$application_acl_contract" = "true|0|0|3|0|3|3|3" ] || {
  echo "Expected exact application capability ACLs, got $application_acl_contract" >&2
  exit 1
}
[ "$application_denied_count" = "12" ] || {
  echo "Expected 12 denied application paths, got $application_denied_count" >&2
  exit 1
}

cleanup_task "$application_task"
cleanup_application_roles
