ALTER TABLE otlet.jobs
ADD COLUMN application_owner_role_oid oid;

CREATE FUNCTION otlet.application_submit_task_subject(
  task_name text,
  subject_id text
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  caller_role_oid oid;
  revision_hash text;
  queued bigint;
  queued_job_id bigint;
BEGIN
  IF application_submit_task_subject.task_name IS NULL
     OR application_submit_task_subject.subject_id IS NULL THEN
    RAISE EXCEPTION 'otlet application task_name and subject_id are required';
  END IF;

  SELECT role.oid
  INTO caller_role_oid
  FROM pg_catalog.pg_roles role
  WHERE role.rolname = session_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet application session role does not exist';
  END IF;

  SELECT head.active_workload_revision_hash
  INTO revision_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = application_submit_task_subject.task_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % has no active workload revision',
      application_submit_task_subject.task_name;
  END IF;

  queued := otlet.run_task_subject(
    application_submit_task_subject.task_name,
    application_submit_task_subject.subject_id,
    revision_hash
  );
  IF queued = 0 THEN
    RETURN 0;
  END IF;

  UPDATE otlet.jobs job
  SET application_owner_role_oid = caller_role_oid
  WHERE job.task_name = application_submit_task_subject.task_name
    AND job.workload_revision_hash = revision_hash
    AND job.subject_id = application_submit_task_subject.subject_id
    AND job.status = 'queued'
    AND job.application_owner_role_oid IS NULL
  RETURNING job.id INTO queued_job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet application job is missing after admission';
  END IF;

  RETURN queued_job_id;
END;
$$;

CREATE FUNCTION otlet.application_job_status(requested_job_id bigint)
RETURNS TABLE (
  job_id bigint,
  status text,
  trusted_output jsonb,
  created_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  cancel_requested_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT
    job.id,
    job.status,
    output.output,
    job.created_at,
    job.started_at,
    job.finished_at,
    job.cancel_requested_at
  FROM otlet.jobs job
  LEFT JOIN otlet.outputs output ON output.job_id = job.id
  WHERE job.id = application_job_status.requested_job_id
    AND job.application_owner_role_oid = (
      SELECT role.oid
      FROM pg_catalog.pg_roles role
      WHERE role.rolname = session_user
    )
$$;

CREATE FUNCTION otlet.application_cancel_job(requested_job_id bigint) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  job_status text;
BEGIN
  PERFORM 1
  FROM otlet.jobs job
  WHERE job.id = application_cancel_job.requested_job_id
    AND job.application_owner_role_oid = (
      SELECT role.oid
      FROM pg_catalog.pg_roles role
      WHERE role.rolname = session_user
    )
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT canceled.status
  INTO job_status
  FROM otlet.request_job_cancellation(
    application_cancel_job.requested_job_id,
    'canceled by application'
  ) canceled;

  RETURN job_status;
END;
$$;

CREATE VIEW otlet.application_access_policy_status AS
SELECT
  count(*)::bigint AS application_functions,
  count(*) FILTER (WHERE function.prosecdef)::bigint AS application_security_definer_functions,
  count(*) FILTER (
    WHERE function.proconfig @> ARRAY['search_path=pg_catalog, otlet, pg_temp']
  )::bigint AS application_fixed_search_path_functions
FROM pg_catalog.pg_proc function
JOIN pg_catalog.pg_namespace namespace ON namespace.oid = function.pronamespace
WHERE namespace.nspname = 'otlet'
  AND function.proname IN (
    'application_submit_task_subject',
    'application_job_status',
    'application_cancel_job'
  );

CREATE FUNCTION otlet.grant_application_access(target_role regrole) RETURNS void
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
  WHERE oid = grant_application_access.target_role::oid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'role with oid % does not exist', grant_application_access.target_role::oid;
  END IF;

  EXECUTE pg_catalog.format('GRANT USAGE ON SCHEMA otlet TO %I', role_name);
  EXECUTE pg_catalog.format(
    'GRANT EXECUTE ON FUNCTION '
    'otlet.application_submit_task_subject(text, text), '
    'otlet.application_job_status(bigint), '
    'otlet.application_cancel_job(bigint) TO %I',
    role_name
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION otlet.application_submit_task_subject(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.application_job_status(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.application_cancel_job(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.grant_application_access(regrole) FROM PUBLIC;
REVOKE ALL ON TABLE otlet.application_access_policy_status FROM PUBLIC;
