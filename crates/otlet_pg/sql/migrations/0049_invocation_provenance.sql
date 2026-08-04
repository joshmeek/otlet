ALTER TABLE otlet.jobs
ADD COLUMN application_authenticated_role_oid oid,
ADD COLUMN application_invocation_role_oid oid,
ADD COLUMN application_request_key text,
ADD COLUMN application_request_payload_hash text,
ADD COLUMN retry_of_job_id bigint REFERENCES otlet.jobs(id) ON DELETE SET NULL,
ADD COLUMN retry_mode text;

UPDATE otlet.jobs
SET application_authenticated_role_oid = application_owner_role_oid,
    application_invocation_role_oid = application_owner_role_oid,
    application_request_payload_hash = otlet.identity_hash(
      'application_request',
      jsonb_build_object(
        'operation', 'submit_task_subject',
        'task_name', task_name,
        'subject_id', subject_id
      )
    )
WHERE application_owner_role_oid IS NOT NULL;

ALTER TABLE otlet.jobs
ADD CONSTRAINT jobs_application_provenance_check CHECK (
  (
    application_owner_role_oid IS NULL
    AND application_authenticated_role_oid IS NULL
    AND application_invocation_role_oid IS NULL
    AND application_request_key IS NULL
    AND application_request_payload_hash IS NULL
  )
  OR (
    application_owner_role_oid IS NOT NULL
    AND application_authenticated_role_oid IS NOT NULL
    AND application_invocation_role_oid IS NOT NULL
    AND application_request_payload_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
    AND (
      application_request_key IS NULL
      OR (
        octet_length(application_request_key) BETWEEN 1 AND 256
        AND btrim(application_request_key) <> ''
      )
    )
  )
),
ADD CONSTRAINT jobs_retry_mode_check CHECK (
  retry_mode IS NULL OR retry_mode IN ('original_snapshot', 'latest_source')
),
ADD CONSTRAINT jobs_retry_parent_check CHECK (
  retry_of_job_id IS NULL OR (
    retry_mode IS NOT NULL
    AND retry_of_job_id <> id
  )
);

CREATE UNIQUE INDEX jobs_application_request_key_idx
ON otlet.jobs (
  application_owner_role_oid,
  application_request_key COLLATE "C"
)
WHERE application_request_key IS NOT NULL;

CREATE INDEX jobs_retry_of_job_id_idx
ON otlet.jobs (retry_of_job_id, id)
WHERE retry_of_job_id IS NOT NULL;

DROP FUNCTION otlet.application_submit_task_subject(text, text);

CREATE FUNCTION otlet.application_submit_task_subject(
  task_name text,
  subject_id text,
  request_key text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  authenticated_role_oid oid;
  invocation_role_oid oid;
  role_setting text := pg_catalog.current_setting('role', true);
  payload_hash text;
  existing_job_id bigint;
  existing_payload_hash text;
  revision_hash text;
  queued bigint;
  queued_job_id bigint;
BEGIN
  IF application_submit_task_subject.task_name IS NULL
     OR application_submit_task_subject.subject_id IS NULL THEN
    RAISE EXCEPTION 'otlet application task_name and subject_id are required';
  END IF;
  IF application_submit_task_subject.request_key IS NOT NULL
     AND (
       octet_length(application_submit_task_subject.request_key) NOT BETWEEN 1 AND 256
       OR btrim(application_submit_task_subject.request_key) = ''
     ) THEN
    RAISE EXCEPTION 'otlet application request key must contain 1 to 256 bytes';
  END IF;

  SELECT role.oid
  INTO authenticated_role_oid
  FROM pg_catalog.pg_roles role
  WHERE role.rolname = session_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet application session role does not exist';
  END IF;

  IF role_setting IS NULL OR role_setting = 'none' THEN
    invocation_role_oid := authenticated_role_oid;
  ELSE
    invocation_role_oid := role_setting::pg_catalog.regrole::pg_catalog.oid;
  END IF;

  payload_hash := otlet.identity_hash(
    'application_request',
    jsonb_build_object(
      'operation', 'submit_task_subject',
      'task_name', application_submit_task_subject.task_name,
      'subject_id', application_submit_task_subject.subject_id
    )
  );

  IF application_submit_task_subject.request_key IS NOT NULL THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtext('otlet_queue_admission')
    );

    SELECT job.id, job.application_request_payload_hash
    INTO existing_job_id, existing_payload_hash
    FROM otlet.jobs job
    WHERE job.application_owner_role_oid = authenticated_role_oid
      AND job.application_request_key COLLATE "C" =
        application_submit_task_subject.request_key COLLATE "C";

    IF FOUND THEN
      IF existing_payload_hash IS DISTINCT FROM payload_hash THEN
        RAISE EXCEPTION 'otlet application request key was reused with a different payload';
      END IF;
      RETURN existing_job_id;
    END IF;
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
  SET application_owner_role_oid = authenticated_role_oid,
      application_authenticated_role_oid = authenticated_role_oid,
      application_invocation_role_oid = invocation_role_oid,
      application_request_key = application_submit_task_subject.request_key,
      application_request_payload_hash = payload_hash
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

CREATE FUNCTION otlet.application_retry_job(
  requested_job_id bigint,
  requested_retry_mode text
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  authenticated_role_oid oid;
  invocation_role_oid oid;
  role_setting text := pg_catalog.current_setting('role', true);
  actual_retry_mode text := lower(COALESCE(application_retry_job.requested_retry_mode, ''));
  original_job otlet.jobs%ROWTYPE;
  revision_hash text;
  payload_hash text;
  queued bigint;
  queued_job_id bigint;
BEGIN
  IF actual_retry_mode NOT IN ('original_snapshot', 'latest_source') THEN
    RAISE EXCEPTION 'otlet application retry mode must be original_snapshot or latest_source';
  END IF;

  SELECT *
  INTO original_job
  FROM otlet.jobs job
  WHERE job.id = application_retry_job.requested_job_id
    AND job.application_owner_role_oid IS NOT NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet application job % does not exist',
      application_retry_job.requested_job_id;
  END IF;
  IF original_job.status NOT IN ('complete', 'failed', 'canceled') THEN
    RAISE EXCEPTION 'otlet application job % is not terminal', original_job.id;
  END IF;

  SELECT role.oid
  INTO authenticated_role_oid
  FROM pg_catalog.pg_roles role
  WHERE role.rolname = session_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet application session role does not exist';
  END IF;

  IF role_setting IS NULL OR role_setting = 'none' THEN
    invocation_role_oid := authenticated_role_oid;
  ELSE
    invocation_role_oid := role_setting::pg_catalog.regrole::pg_catalog.oid;
  END IF;

  payload_hash := otlet.identity_hash(
    'application_retry_request',
    jsonb_build_object(
      'operation', 'retry_job',
      'job_id', original_job.id,
      'retry_mode', actual_retry_mode
    )
  );

  IF actual_retry_mode = 'original_snapshot' THEN
    revision_hash := original_job.workload_revision_hash;
    queued := otlet.admit_task_input(
      original_job.task_name,
      original_job.subject_id,
      original_job.input,
      revision_hash
    )::integer;
    IF queued > 0 THEN
      PERFORM otlet.wake_worker();
    END IF;
  ELSE
    SELECT head.active_workload_revision_hash
    INTO revision_hash
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = original_job.task_name;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'otlet task % has no active workload revision', original_job.task_name;
    END IF;

    queued := otlet.run_task_subject(
      original_job.task_name,
      original_job.subject_id,
      revision_hash
    );
  END IF;

  IF queued = 0 THEN
    RETURN 0;
  END IF;

  UPDATE otlet.jobs job
  SET application_owner_role_oid = original_job.application_owner_role_oid,
      application_authenticated_role_oid = authenticated_role_oid,
      application_invocation_role_oid = invocation_role_oid,
      application_request_payload_hash = payload_hash,
      retry_of_job_id = original_job.id,
      retry_mode = actual_retry_mode
  WHERE job.task_name = original_job.task_name
    AND job.workload_revision_hash = revision_hash
    AND job.subject_id = original_job.subject_id
    AND job.status = 'queued'
    AND job.application_owner_role_oid IS NULL
  RETURNING job.id INTO queued_job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet application retry job is missing after admission';
  END IF;

  RETURN queued_job_id;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.grant_application_access(target_role regrole) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text;
  old_revision_hash text;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'otlet_access_policy:' || grant_application_access.target_role::oid::text,
      0
    )
  );
  old_revision_hash := otlet.access_policy_revision(
    grant_application_access.target_role
  );
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
    'otlet.application_submit_task_subject(text, text, text), '
    'otlet.application_job_status(bigint), '
    'otlet.application_cancel_job(bigint) TO %I',
    role_name
  );
  PERFORM otlet.finish_access_policy_grant(
    'application',
    grant_application_access.target_role,
    old_revision_hash
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION otlet.application_submit_task_subject(text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.application_retry_job(bigint, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.grant_application_access(regrole) FROM PUBLIC;
