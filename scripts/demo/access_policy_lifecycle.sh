access_policy_application_role="otlet_demo_policy_application"
access_policy_auditor_role="otlet_demo_policy_auditor"
access_policy_operator_role="otlet_demo_policy_operator"
access_policy_reviewer_role="otlet_demo_policy_reviewer"
access_policy_worker_role="otlet_demo_policy_worker"
access_policy_administrator_role="otlet_demo_policy_administrator"
access_policy_quoted_login_role="Otlet Demo Policy Login"
access_policy_managed_role="otlet_demo_policy_managed"
access_policy_renamed_role="otlet_demo_policy_application_renamed"

cleanup_access_policy_roles() {
  psql_exec >/dev/null <<SQL
DELETE FROM otlet.access_policy_roles
WHERE registered_role_name IN (
  '$access_policy_application_role',
  '$access_policy_auditor_role',
  '$access_policy_operator_role',
  '$access_policy_reviewer_role',
  '$access_policy_worker_role',
  '$access_policy_administrator_role',
  '$access_policy_managed_role'
);
DO \$cleanup\$
DECLARE
  role_name text;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_auth_members membership
    JOIN pg_catalog.pg_roles parent ON parent.oid = membership.roleid
    JOIN pg_catalog.pg_roles member ON member.oid = membership.member
    WHERE parent.rolname = '$access_policy_operator_role'
      AND member.rolname IN (
        '$access_policy_application_role',
        '$access_policy_renamed_role'
      )
  ) THEN
    EXECUTE pg_catalog.format(
      'REVOKE %I FROM %I',
      '$access_policy_operator_role',
      (SELECT rolname FROM pg_catalog.pg_roles
       WHERE rolname IN (
         '$access_policy_application_role',
         '$access_policy_renamed_role'
       ) LIMIT 1)
    );
  END IF;
  FOR role_name IN
    SELECT unnest(ARRAY[
      '$access_policy_application_role',
      '$access_policy_renamed_role',
      '$access_policy_auditor_role',
      '$access_policy_operator_role',
      '$access_policy_reviewer_role',
      '$access_policy_worker_role',
      '$access_policy_quoted_login_role',
      '$access_policy_administrator_role',
      '$access_policy_managed_role'
    ])
  LOOP
    IF EXISTS (
      SELECT 1 FROM pg_catalog.pg_roles role
      WHERE role.rolname = role_name
    ) THEN
      EXECUTE pg_catalog.format('DROP OWNED BY %I', role_name);
      EXECUTE pg_catalog.format('DROP ROLE %I', role_name);
    END IF;
  END LOOP;
END;
\$cleanup\$;
SQL
}

expect_access_policy_failure() {
  local role="$1"
  local statement="$2"
  local expected="$3"
  local output

  if output="$(psql_exec -X -c "SET ROLE $role; $statement" 2>&1)"; then
    echo "Expected access-policy statement to fail for $role" >&2
    exit 1
  fi
  require_contains "$output" "$expected" \
    "Expected access-policy failure containing $expected, got $output"
}

log "Proving access-policy lifecycle"
cleanup_access_policy_roles
trap 'cleanup_access_policy_roles; cleanup_permission_roles' EXIT

psql_exec >/dev/null <<SQL
CREATE ROLE $access_policy_application_role NOLOGIN;
CREATE ROLE $access_policy_auditor_role NOLOGIN;
CREATE ROLE $access_policy_operator_role NOLOGIN;
CREATE ROLE $access_policy_reviewer_role NOLOGIN;
CREATE ROLE $access_policy_worker_role NOLOGIN;
CREATE ROLE $access_policy_administrator_role NOLOGIN;
CREATE ROLE "$access_policy_quoted_login_role" LOGIN;
CREATE ROLE $access_policy_managed_role NOLOGIN;
SELECT otlet.register_access_policy_capability(
  '$access_policy_application_role'::regrole,
  'application',
  'Register demo application role'
);
SELECT otlet.register_access_policy_capability(
  '$access_policy_auditor_role'::regrole,
  'auditor',
  'Register demo auditor role'
);
SELECT otlet.register_access_policy_capability(
  '$access_policy_operator_role'::regrole,
  'operator',
  'Register demo operator role'
);
SELECT otlet.register_access_policy_capability(
  '$access_policy_reviewer_role'::regrole,
  'reviewer',
  'Register demo reviewer role'
);
SELECT otlet.register_access_policy_capability(
  '$access_policy_worker_role'::regrole,
  'portable_worker',
  'Register demo portable worker role'
);
SELECT otlet.register_access_policy_capability(
  '$access_policy_administrator_role'::regrole,
  'administrator',
  'Register demo access administrator'
);
GRANT $access_policy_administrator_role TO "$access_policy_quoted_login_role";
SQL

access_policy_registration_contract="$(psql_value <<SQL
SELECT count(*)::text || '|' ||
       count(*) FILTER (WHERE reconciled)::text || '|' ||
       sum(missing_privilege_count)::text || '|' ||
       sum(unexpected_privilege_count)::text || '|' ||
       count(*) FILTER (
         WHERE capabilities = ARRAY['administrator']::text[]
       )::text
FROM otlet.access_policy_role_status;
SQL
)"
echo "access_policy_registration_contract=$access_policy_registration_contract"
[ "$access_policy_registration_contract" = "6|6|0|0|1" ] || {
  echo "Expected six exact registered access policies, got $access_policy_registration_contract" >&2
  exit 1
}

psql_exec >/dev/null <<SQL
SET SESSION AUTHORIZATION "$access_policy_quoted_login_role";
SELECT otlet.register_access_policy_capability(
  '$access_policy_managed_role'::regrole,
  'application',
  'Quoted-login registration proof'
);
RESET SESSION AUTHORIZATION;
BEGIN;
SET LOCAL ROLE $access_policy_administrator_role;
SELECT count(*) FROM otlet.access_policy_role_status;
SELECT otlet.register_access_policy_capability(
  '$access_policy_auditor_role'::regrole,
  'application',
  'Combined capability proof'
);
SELECT otlet.revoke_access_policy_capability(
  '$access_policy_auditor_role'::regrole,
  'application',
  'Remove one capability'
);
COMMIT;
SQL

access_policy_revocation_contract="$(psql_value <<SQL
SELECT
  (policy.capabilities = ARRAY['auditor']::text[])::text || '|' ||
  policy.reconciled::text || '|' ||
  pg_catalog.has_table_privilege(
    '$access_policy_auditor_role',
    'otlet.audit_receipt_export',
    'SELECT'
  )::text || '|' ||
  pg_catalog.has_function_privilege(
    '$access_policy_auditor_role',
    'otlet.application_job_status(bigint)',
    'EXECUTE'
  )::text || '|' ||
  (managed.registered_by_oid = (
    SELECT role.oid
    FROM pg_catalog.pg_roles role
    WHERE role.rolname = '$access_policy_quoted_login_role'
  ))::text
FROM otlet.access_policy_role_status policy
CROSS JOIN otlet.access_policy_role_status managed
WHERE policy.role_oid = '$access_policy_auditor_role'::regrole::oid
  AND managed.role_oid = '$access_policy_managed_role'::regrole::oid;
SQL
)"
echo "access_policy_revocation_contract=$access_policy_revocation_contract"
[ "$access_policy_revocation_contract" = "true|true|true|false|true" ] || {
  echo "Expected one capability removed without disturbing auditor access, got $access_policy_revocation_contract" >&2
  exit 1
}

psql_exec >/dev/null <<SQL
REVOKE EXECUTE ON FUNCTION otlet.application_job_status(bigint)
FROM $access_policy_application_role;
GRANT EXECUTE ON FUNCTION
  otlet.register_model(text,text,text,jsonb,integer)
TO $access_policy_application_role;
GRANT SELECT(id) ON TABLE otlet.jobs
TO $access_policy_application_role;
SQL
access_policy_drift_before="$(psql_value <<SQL
SELECT missing_privilege_count::text || '|' ||
       unexpected_privilege_count::text || '|' ||
       reconciliation_status
FROM otlet.access_policy_role_status
WHERE role_oid = '$access_policy_application_role'::regrole::oid;
SQL
)"
psql_exec >/dev/null <<SQL
BEGIN;
SET LOCAL ROLE $access_policy_administrator_role;
SELECT otlet.reconcile_access_policy_role(
  '$access_policy_application_role'::regrole,
  'Repair direct ACL drift'
);
COMMIT;
SQL
access_policy_drift_after="$(psql_value <<SQL
SELECT missing_privilege_count::text || '|' ||
       unexpected_privilege_count::text || '|' ||
       reconciliation_status || '|' ||
       (NOT EXISTS (
         SELECT 1
         FROM pg_catalog.pg_attribute attribute
         CROSS JOIN LATERAL pg_catalog.aclexplode(attribute.attacl) privilege
         WHERE attribute.attrelid = 'otlet.jobs'::regclass
           AND attribute.attname = 'id'
           AND privilege.grantee = '$access_policy_application_role'::regrole::oid
       ))::text
FROM otlet.access_policy_role_status
WHERE role_oid = '$access_policy_application_role'::regrole::oid;
SQL
)"
echo "access_policy_drift_contract=$access_policy_drift_before|$access_policy_drift_after"
[ "$access_policy_drift_before|$access_policy_drift_after" = \
  "1|2|missing_privileges|0|0|reconciled|true" ] || {
  echo "Expected exact ACL drift detection and repair" >&2
  exit 1
}

psql_exec -c "
UPDATE otlet.access_policy_roles
SET desired_revision_hash = 'otlet:v1:sha256:' || repeat('0', 64)
WHERE role_oid = '$access_policy_administrator_role'::regrole::oid
" >/dev/null
access_policy_manifest_before="$(psql_value <<SQL
SELECT reconciliation_status
FROM otlet.access_policy_role_status
WHERE role_oid = '$access_policy_administrator_role'::regrole::oid;
SQL
)"
expect_access_policy_failure "$access_policy_administrator_role" \
  "SELECT otlet.reconcile_access_policy_role('$access_policy_managed_role'::regrole, 'Denied invalid administrator manifest')" \
  "administration is denied"
psql_exec -c "
SELECT otlet.reconcile_access_policy_role(
  '$access_policy_administrator_role'::regrole,
  'Repair administrator manifest'
)
" >/dev/null
access_policy_manifest_after="$(psql_value <<SQL
SELECT reconciliation_status
FROM otlet.access_policy_role_status
WHERE role_oid = '$access_policy_administrator_role'::regrole::oid;
SQL
)"
echo "access_policy_manifest_contract=$access_policy_manifest_before|$access_policy_manifest_after"
[ "$access_policy_manifest_before|$access_policy_manifest_after" = \
  "manifest_hash_mismatch|reconciled" ] || {
  echo "Expected invalid administrator manifest to fail closed and reconcile" >&2
  exit 1
}

psql_exec -c \
  "GRANT $access_policy_operator_role TO $access_policy_application_role" \
  >/dev/null
access_policy_membership_status="$(psql_value <<SQL
SELECT reconciliation_status || '|' || jsonb_array_length(inherited_roles)::text
FROM otlet.access_policy_role_status
WHERE role_oid = '$access_policy_application_role'::regrole::oid;
SQL
)"
expect_access_policy_failure "$access_policy_administrator_role" \
  "SELECT otlet.reconcile_access_policy_role('$access_policy_application_role'::regrole, 'Denied membership drift')" \
  "must not inherit"
psql_exec -c \
  "REVOKE $access_policy_operator_role FROM $access_policy_application_role" \
  >/dev/null
echo "access_policy_membership_contract=$access_policy_membership_status"
[ "$access_policy_membership_status" = "role_membership_drift|1" ] || {
  echo "Expected inherited role drift to fail closed, got $access_policy_membership_status" >&2
  exit 1
}

psql_exec -c \
  "ALTER ROLE $access_policy_application_role RENAME TO $access_policy_renamed_role" \
  >/dev/null
access_policy_rename_status="$(psql_value <<SQL
SELECT reconciliation_status
FROM otlet.access_policy_role_status
WHERE registered_role_name = '$access_policy_application_role';
SQL
)"
expect_access_policy_failure "$access_policy_administrator_role" \
  "SELECT otlet.reconcile_access_policy_role('$access_policy_renamed_role'::regrole, 'Denied identity drift')" \
  "role identity changed"
psql_exec -c \
  "ALTER ROLE $access_policy_renamed_role RENAME TO $access_policy_application_role" \
  >/dev/null
echo "access_policy_identity_contract=$access_policy_rename_status"
[ "$access_policy_rename_status" = "role_identity_mismatch" ] || {
  echo "Expected role rename to fail closed, got $access_policy_rename_status" >&2
  exit 1
}

expect_access_policy_failure "$access_policy_administrator_role" \
  "SELECT count(*) FROM otlet.access_policy_roles" \
  "permission denied"
expect_access_policy_failure "$access_policy_administrator_role" \
  "SELECT otlet.grant_application_access('$access_policy_managed_role'::regrole)" \
  "permission denied"
expect_access_policy_failure "$access_policy_administrator_role" \
  "CREATE TABLE otlet.denied_access_policy_write(id integer)" \
  "permission denied"
expect_access_policy_failure "$access_policy_administrator_role" \
  "SELECT otlet.register_access_policy_capability('postgres'::regrole, 'application', 'Denied owner target')" \
  "unprivileged dedicated role"
expect_access_policy_failure "$access_policy_administrator_role" \
  "SELECT otlet.register_access_policy_capability('$access_policy_managed_role'::regrole, 'administrator', 'Denied administrator delegation')" \
  "only the Otlet owner"
expect_access_policy_failure "$access_policy_administrator_role" \
  "SELECT otlet.revoke_access_policy_capability('$access_policy_managed_role'::regrole, NULL, 'Denied invalid revocation')" \
  "unsupported Otlet access-policy capability"

access_policy_closure_contract="$(psql_value <<'SQL'
SELECT
  pg_catalog.has_table_privilege(
    'public', 'otlet.access_policy_roles', 'SELECT'
  )::text || '|' ||
  pg_catalog.has_table_privilege(
    'public', 'otlet.access_policy_role_status', 'SELECT'
  )::text || '|' ||
  count(*) FILTER (
    WHERE pg_catalog.has_function_privilege('public', function_oid, 'EXECUTE')
  )::text
FROM unnest(ARRAY[
  'otlet.register_access_policy_capability(regrole,text,text,text)'::regprocedure::oid,
  'otlet.reconcile_access_policy_role(regrole,text,text)'::regprocedure::oid,
  'otlet.revoke_access_policy_capability(regrole,text,text,text)'::regprocedure::oid,
  'otlet.access_policy_role_status_rows()'::regprocedure::oid,
  'otlet.clear_access_policy_grants(regrole)'::regprocedure::oid,
  'otlet.apply_access_policy_capabilities(regrole,text[])'::regprocedure::oid
]) function_oid;
SQL
)"
access_policy_invariants="$(psql_value <<'SQL'
SELECT count(*) FROM otlet.verify_invariants();
SQL
)"
echo "access_policy_closure_contract=$access_policy_closure_contract"
echo "access_policy_invariant_contract=$access_policy_invariants"
[ "$access_policy_closure_contract" = "false|false|0" ] || {
  echo "Expected access-policy lifecycle PUBLIC closure" >&2
  exit 1
}
[ "$access_policy_invariants" = "0" ] || {
  echo "Expected zero access-policy invariants, got $access_policy_invariants" >&2
  exit 1
}

access_policy_contract="roles=6/6|revoke=auditor_preserved|drift=1/2_to_0/0|manifest=closed|membership=closed|rename=closed|admin=narrow|public=closed|invariants=0"
echo "access_policy_contract=$access_policy_contract"

cleanup_access_policy_roles
trap cleanup_permission_roles EXIT
