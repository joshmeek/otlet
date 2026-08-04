CREATE FUNCTION otlet.grant_portable_worker_access(target_role regrole) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text;
  rpc regprocedure;
  old_revision_hash text;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'otlet_access_policy:' || grant_portable_worker_access.target_role::oid::text,
      0
    )
  );
  old_revision_hash := otlet.access_policy_revision(
    grant_portable_worker_access.target_role
  );
  SELECT rolname
  INTO role_name
  FROM pg_catalog.pg_roles
  WHERE oid = grant_portable_worker_access.target_role::oid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'role with oid % does not exist', grant_portable_worker_access.target_role::oid;
  END IF;

  EXECUTE pg_catalog.format('GRANT USAGE ON SCHEMA otlet TO %I', role_name);
  EXECUTE pg_catalog.format(
    'GRANT SELECT ON TABLE otlet.portable_protocol_status TO %I',
    role_name
  );
  FOR rpc IN
    SELECT p.oid::regprocedure
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'otlet'
      AND p.proname IN (
        'portable_start_worker',
        'portable_claim_jobs',
        'portable_renew_job',
        'portable_record_attempt',
        'portable_complete_job',
        'portable_fail_job',
        'portable_cancel_job',
        'portable_worker_heartbeat'
      )
    ORDER BY p.proname
  LOOP
    EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION %s TO %I', rpc, role_name);
  END LOOP;
  PERFORM otlet.finish_access_policy_grant(
    'portable_worker',
    grant_portable_worker_access.target_role,
    old_revision_hash
  );
END;
$$;
