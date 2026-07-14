CREATE VIEW otlet.access_policy_status AS
WITH operator_functions(oid) AS (
  SELECT unnest(ARRAY[
    'otlet.approve_action(bigint,text)'::regprocedure::oid,
    'otlet.reject_action(bigint,text,text)'::regprocedure::oid,
    'otlet.label_action(bigint,text,text,text,text,text)'::regprocedure::oid,
    'otlet.correct_action(bigint,jsonb,text)'::regprocedure::oid,
    'otlet.dry_run_action(bigint)'::regprocedure::oid,
    'otlet.apply_action(bigint)'::regprocedure::oid
  ])
),
operator_status AS (
  SELECT
    count(*)::bigint AS function_count,
    count(*) FILTER (WHERE p.prosecdef)::bigint AS security_definer_count,
    count(*) FILTER (
      WHERE p.proconfig @> ARRAY['search_path=pg_catalog, otlet, pg_temp']
    )::bigint AS fixed_search_path_count
  FROM operator_functions expected
  JOIN pg_catalog.pg_proc p ON p.oid = expected.oid
)
SELECT
  'owner_granted_roles'::text AS policy_name,
  1::integer AS policy_version,
  pg_catalog.has_schema_privilege('public', 'otlet', 'USAGE') AS public_schema_usage,
  (
    SELECT count(*)::bigint
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'otlet'
      AND pg_catalog.has_function_privilege('public', p.oid, 'EXECUTE')
  ) AS public_executable_functions,
  (
    SELECT count(*)::bigint
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'otlet'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND (
        pg_catalog.has_table_privilege('public', c.oid, 'SELECT')
        OR pg_catalog.has_table_privilege('public', c.oid, 'INSERT')
        OR pg_catalog.has_table_privilege('public', c.oid, 'UPDATE')
        OR pg_catalog.has_table_privilege('public', c.oid, 'DELETE')
        OR pg_catalog.has_table_privilege('public', c.oid, 'TRUNCATE')
        OR pg_catalog.has_table_privilege('public', c.oid, 'REFERENCES')
        OR pg_catalog.has_table_privilege('public', c.oid, 'TRIGGER')
      )
  ) AS public_table_privileges,
  (
    SELECT count(*)::bigint
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'otlet'
      AND c.relkind = 'S'
      AND (
        pg_catalog.has_sequence_privilege('public', c.oid, 'USAGE')
        OR pg_catalog.has_sequence_privilege('public', c.oid, 'SELECT')
        OR pg_catalog.has_sequence_privilege('public', c.oid, 'UPDATE')
      )
  ) AS public_sequence_privileges,
  operator_status.function_count AS operator_functions,
  operator_status.security_definer_count AS operator_security_definer_functions,
  operator_status.fixed_search_path_count AS operator_fixed_search_path_functions
FROM operator_status;

CREATE FUNCTION otlet.grant_auditor_access(target_role regrole) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text;
BEGIN
  SELECT rolname
  INTO role_name
  FROM pg_catalog.pg_roles
  WHERE oid = grant_auditor_access.target_role::oid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'role with oid % does not exist', grant_auditor_access.target_role::oid;
  END IF;

  EXECUTE pg_catalog.format('GRANT USAGE ON SCHEMA otlet TO %I', role_name);
  EXECUTE pg_catalog.format(
    'GRANT SELECT ON TABLE '
    'otlet.redaction_policy_status, '
    'otlet.access_policy_status, '
    'otlet.audit_receipt_export, '
    'otlet.audit_review_export, '
    'otlet.audit_action_execution_export, '
    'otlet.audit_eval_label_export, '
    'otlet.semantic_dependency_audit, '
    'otlet.worker_batch_timing_status TO %I',
    role_name
  );
  EXECUTE pg_catalog.format(
    'GRANT EXECUTE ON FUNCTION '
    'otlet.semantic_canonical_jsonb(jsonb), '
    'otlet.semantic_shaped_input(jsonb, jsonb), '
    'otlet.semantic_content_hash(jsonb, jsonb) TO %I',
    role_name
  );
END;
$$;

CREATE FUNCTION otlet.grant_operator_access(target_role regrole) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text;
BEGIN
  SELECT rolname
  INTO role_name
  FROM pg_catalog.pg_roles
  WHERE oid = grant_operator_access.target_role::oid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'role with oid % does not exist', grant_operator_access.target_role::oid;
  END IF;

  PERFORM otlet.grant_auditor_access(grant_operator_access.target_role);
  EXECUTE pg_catalog.format(
    'GRANT USAGE ON TYPE otlet.actions, otlet.eval_labels TO %I',
    role_name
  );
  EXECUTE pg_catalog.format(
    'GRANT EXECUTE ON FUNCTION '
    'otlet.approve_action(bigint, text), '
    'otlet.reject_action(bigint, text, text), '
    'otlet.label_action(bigint, text, text, text, text, text), '
    'otlet.correct_action(bigint, jsonb, text), '
    'otlet.dry_run_action(bigint), '
    'otlet.apply_action(bigint) TO %I',
    role_name
  );
END;
$$;

-- Keep this file after every extension object definition
REVOKE ALL ON SCHEMA otlet FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA otlet FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA otlet FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA otlet FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA otlet FROM PUBLIC;
