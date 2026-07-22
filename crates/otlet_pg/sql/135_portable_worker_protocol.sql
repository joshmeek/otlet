CREATE TABLE otlet.portable_protocol_versions (
  protocol_version integer PRIMARY KEY,
  protocol_name text NOT NULL,
  compatibility_rule text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deprecated', 'disabled')),
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO otlet.portable_protocol_versions (
  protocol_version,
  protocol_name,
  compatibility_rule
)
VALUES (
  1,
  'otlet.portable.worker.v1',
  'worker and database protocol versions must match exactly'
);

CREATE TABLE otlet.portable_workers (
  worker_id text PRIMARY KEY CHECK (worker_id ~ '^[a-z0-9][a-z0-9_-]{0,62}$'),
  database_role_oid oid NOT NULL,
  protocol_version integer NOT NULL REFERENCES otlet.portable_protocol_versions(protocol_version),
  model_name text NOT NULL REFERENCES otlet.models(name),
  runtime_name text NOT NULL CHECK (runtime_name ~ '^[a-z0-9][a-z0-9_.-]{0,127}$'),
  runtime_version text NOT NULL CHECK (
    btrim(runtime_version) <> '' AND octet_length(runtime_version) <= 128
  ),
  runtime_identity jsonb NOT NULL CHECK (
    jsonb_typeof(runtime_identity) = 'object'
    AND octet_length(runtime_identity::text) <= 65536
  ),
  runtime_identity_hash text NOT NULL CHECK (
    runtime_identity_hash ~ '^[0-9a-f]{64}$'
    AND runtime_identity_hash = otlet.portable_json_hash(runtime_identity)
  ),
  enabled boolean NOT NULL DEFAULT true,
  desired_state text NOT NULL DEFAULT 'running' CHECK (
    desired_state IN ('running', 'paused', 'draining')
  ),
  reported_state text NOT NULL DEFAULT 'registered' CHECK (
    reported_state IN (
      'registered', 'starting', 'idle', 'running', 'paused', 'draining',
      'drained', 'stopped', 'error'
    )
  ),
  model_status text NOT NULL DEFAULT 'unverified' CHECK (
    model_status IN ('unverified', 'verifying', 'verified', 'loading', 'ready', 'error')
  ),
  last_error_code text CHECK (
    last_error_code IS NULL OR last_error_code ~ '^[a-z0-9][a-z0-9_.-]{0,127}$'
  ),
  last_seen_at timestamptz,
  last_heartbeat_at timestamptz,
  last_claimed_at timestamptz,
  process_started_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX portable_workers_role_runtime_idx
ON otlet.portable_workers (database_role_oid, runtime_identity_hash);

ALTER TABLE otlet.portable_worker_process_samples
ADD CONSTRAINT portable_worker_process_samples_worker_fk
FOREIGN KEY (worker_id) REFERENCES otlet.portable_workers(worker_id) ON DELETE CASCADE;

CREATE TABLE otlet.portable_claims (
  id bigserial PRIMARY KEY,
  job_id bigint NOT NULL REFERENCES otlet.jobs(id) ON DELETE CASCADE,
  worker_id text NOT NULL REFERENCES otlet.portable_workers(worker_id),
  protocol_version integer NOT NULL,
  runtime_identity_hash text NOT NULL,
  attempt_index integer NOT NULL CHECK (attempt_index > 0),
  claim_token_hash text NOT NULL UNIQUE CHECK (claim_token_hash ~ '^[0-9a-f]{64}$'),
  status text NOT NULL DEFAULT 'claimed' CHECK (
    status IN ('claimed', 'renewed', 'complete', 'failed', 'canceled', 'replaced')
  ),
  claimed_at timestamptz NOT NULL DEFAULT now(),
  last_renewed_at timestamptz,
  finished_at timestamptz
);

CREATE UNIQUE INDEX portable_claims_live_job_idx
ON otlet.portable_claims (job_id)
WHERE status IN ('claimed', 'renewed');

CREATE INDEX portable_claims_worker_claimed_idx
ON otlet.portable_claims (worker_id, claimed_at DESC, id DESC);

CREATE TABLE otlet.portable_receipt_links (
  receipt_id bigint PRIMARY KEY REFERENCES otlet.inference_receipts(id) ON DELETE CASCADE,
  claim_id bigint NOT NULL REFERENCES otlet.portable_claims(id) ON DELETE CASCADE,
  linked_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX portable_receipt_links_claim_idx
ON otlet.portable_receipt_links (claim_id, receipt_id);

CREATE FUNCTION otlet.register_portable_worker(
  worker_id text,
  target_role regrole,
  protocol_version integer,
  model_name text,
  runtime_name text,
  runtime_version text,
  runtime_identity jsonb
) RETURNS otlet.portable_workers
LANGUAGE plpgsql
AS $$
DECLARE
  role_row record;
  saved_worker otlet.portable_workers%ROWTYPE;
BEGIN
  IF register_portable_worker.worker_id !~ '^[a-z0-9][a-z0-9_-]{0,62}$' THEN
    RAISE EXCEPTION 'otlet portable worker id is invalid';
  END IF;
  IF register_portable_worker.runtime_name !~ '^[a-z0-9][a-z0-9_.-]{0,127}$'
     OR NULLIF(btrim(register_portable_worker.runtime_version), '') IS NULL
     OR octet_length(register_portable_worker.runtime_version) > 128 THEN
    RAISE EXCEPTION 'otlet portable runtime name or version is invalid';
  END IF;
  IF jsonb_typeof(register_portable_worker.runtime_identity) IS DISTINCT FROM 'object'
     OR octet_length(COALESCE(register_portable_worker.runtime_identity, '{}'::jsonb)::text) > 65536 THEN
    RAISE EXCEPTION 'otlet portable runtime identity must be a bounded object';
  END IF;

  PERFORM 1
  FROM otlet.portable_protocol_versions p
  WHERE p.protocol_version = register_portable_worker.protocol_version
    AND p.status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable protocol version % is incompatible',
      register_portable_worker.protocol_version;
  END IF;

  SELECT r.oid, r.rolsuper, r.rolcreatedb, r.rolcreaterole, r.rolreplication, r.rolbypassrls
  INTO role_row
  FROM pg_catalog.pg_roles r
  WHERE r.oid = register_portable_worker.target_role::oid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable worker database role does not exist';
  END IF;
  IF role_row.rolsuper
     OR role_row.rolcreatedb
     OR role_row.rolcreaterole
     OR role_row.rolreplication
     OR role_row.rolbypassrls THEN
    RAISE EXCEPTION 'otlet portable worker database role is overprivileged';
  END IF;

  INSERT INTO otlet.portable_workers (
    worker_id,
    database_role_oid,
    protocol_version,
    model_name,
    runtime_name,
    runtime_version,
    runtime_identity,
    runtime_identity_hash
  )
  VALUES (
    register_portable_worker.worker_id,
    register_portable_worker.target_role::oid,
    register_portable_worker.protocol_version,
    register_portable_worker.model_name,
    register_portable_worker.runtime_name,
    register_portable_worker.runtime_version,
    register_portable_worker.runtime_identity,
    otlet.portable_json_hash(register_portable_worker.runtime_identity)
  )
  ON CONFLICT ON CONSTRAINT portable_workers_pkey DO UPDATE
  SET database_role_oid = EXCLUDED.database_role_oid,
      protocol_version = EXCLUDED.protocol_version,
      model_name = EXCLUDED.model_name,
      runtime_name = EXCLUDED.runtime_name,
      runtime_version = EXCLUDED.runtime_version,
      runtime_identity = EXCLUDED.runtime_identity,
      runtime_identity_hash = EXCLUDED.runtime_identity_hash,
      enabled = true,
      desired_state = 'running',
      reported_state = 'registered',
      model_status = 'unverified',
      last_error_code = NULL,
      last_heartbeat_at = NULL,
      process_started_at = NULL,
      updated_at = now()
  RETURNING * INTO saved_worker;

  RETURN saved_worker;
END;
$$;

CREATE FUNCTION otlet.disable_portable_worker(worker_id text) RETURNS boolean
LANGUAGE sql
AS $$
  UPDATE otlet.portable_workers w
  SET enabled = false,
      desired_state = 'draining',
      updated_at = now()
  WHERE w.worker_id = disable_portable_worker.worker_id
    AND w.enabled
  RETURNING true
$$;

CREATE FUNCTION otlet.set_portable_worker_control(
  worker_id text,
  desired_state text
) RETURNS otlet.portable_workers
LANGUAGE plpgsql
AS $$
DECLARE
  saved_worker otlet.portable_workers%ROWTYPE;
BEGIN
  IF set_portable_worker_control.desired_state NOT IN ('running', 'paused', 'draining') THEN
    RAISE EXCEPTION 'otlet portable worker state must be running, paused, or draining';
  END IF;

  UPDATE otlet.portable_workers w
  SET desired_state = set_portable_worker_control.desired_state,
      updated_at = now()
  WHERE w.worker_id = set_portable_worker_control.worker_id
  RETURNING * INTO saved_worker;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable worker % does not exist', set_portable_worker_control.worker_id;
  END IF;

  RETURN saved_worker;
END;
$$;

CREATE FUNCTION otlet.authorized_portable_worker(
  worker_id text,
  protocol_version integer,
  runtime_identity_hash text
) RETURNS otlet.portable_workers
LANGUAGE plpgsql
AS $$
DECLARE
  role_setting text := pg_catalog.current_setting('role', true);
  invoker_role_oid oid;
  worker_row otlet.portable_workers%ROWTYPE;
BEGIN
  PERFORM 1
  FROM otlet.portable_protocol_versions p
  WHERE p.protocol_version = authorized_portable_worker.protocol_version
    AND p.status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable protocol version % is incompatible',
      authorized_portable_worker.protocol_version;
  END IF;

  IF role_setting IS NULL OR role_setting = 'none' THEN
    SELECT r.oid
    INTO invoker_role_oid
    FROM pg_catalog.pg_roles r
    WHERE r.rolname = session_user;
  ELSE
    SELECT r.oid
    INTO invoker_role_oid
    FROM pg_catalog.pg_roles r
    WHERE r.rolname = role_setting;
  END IF;

  SELECT w.*
  INTO worker_row
  FROM otlet.portable_workers w
  WHERE w.worker_id = authorized_portable_worker.worker_id
    AND w.protocol_version = authorized_portable_worker.protocol_version
    AND w.runtime_identity_hash = authorized_portable_worker.runtime_identity_hash
    AND w.database_role_oid = invoker_role_oid
    AND w.enabled
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable worker identity is not authorized';
  END IF;

  UPDATE otlet.portable_workers w
  SET last_seen_at = now()
  WHERE w.worker_id = worker_row.worker_id
  RETURNING * INTO worker_row;

  RETURN worker_row;
END;
$$;

CREATE FUNCTION otlet.authorized_portable_claim(
  worker_id text,
  job_id bigint,
  claim_token text
) RETURNS otlet.portable_claims
LANGUAGE plpgsql
AS $$
DECLARE
  claim_row otlet.portable_claims%ROWTYPE;
BEGIN
  SELECT c.*
  INTO claim_row
  FROM otlet.portable_claims c
  WHERE c.worker_id = authorized_portable_claim.worker_id
    AND c.job_id = authorized_portable_claim.job_id
    AND c.claim_token_hash = otlet.portable_text_hash(authorized_portable_claim.claim_token)
    AND c.status <> 'replaced'
  ORDER BY c.id DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable job claim is stale or belongs to another worker';
  END IF;

  RETURN claim_row;
END;
$$;

CREATE FUNCTION otlet.link_portable_receipt(
  claim_id bigint,
  receipt_id bigint
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  existing_claim_id bigint;
BEGIN
  IF link_portable_receipt.receipt_id IS NULL THEN
    RETURN;
  END IF;

  SELECT l.claim_id
  INTO existing_claim_id
  FROM otlet.portable_receipt_links l
  WHERE l.receipt_id = link_portable_receipt.receipt_id;
  IF FOUND AND existing_claim_id IS DISTINCT FROM link_portable_receipt.claim_id THEN
    RAISE EXCEPTION 'otlet portable receipt is already linked to another claim';
  END IF;
  IF NOT FOUND THEN
    INSERT INTO otlet.portable_receipt_links (receipt_id, claim_id)
    VALUES (link_portable_receipt.receipt_id, link_portable_receipt.claim_id);
  END IF;
END;
$$;

CREATE FUNCTION otlet.portable_worker_heartbeat(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text,
  reported_state text,
  model_status text DEFAULT NULL,
  error_code text DEFAULT NULL,
  worker_process_rss_bytes bigint DEFAULT 0
) RETURNS TABLE (desired_state text, registered_model_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  worker_row otlet.portable_workers%ROWTYPE;
BEGIN
  IF portable_worker_heartbeat.reported_state NOT IN (
    'starting', 'idle', 'running', 'paused', 'draining', 'drained', 'stopped', 'error'
  ) THEN
    RAISE EXCEPTION 'otlet portable worker reported state is invalid';
  END IF;
  IF portable_worker_heartbeat.model_status IS NOT NULL
     AND portable_worker_heartbeat.model_status NOT IN (
       'unverified', 'verifying', 'verified', 'loading', 'ready', 'error'
     ) THEN
    RAISE EXCEPTION 'otlet portable worker model status is invalid';
  END IF;
  IF portable_worker_heartbeat.error_code IS NOT NULL
     AND portable_worker_heartbeat.error_code !~ '^[a-z0-9][a-z0-9_.-]{0,127}$' THEN
    RAISE EXCEPTION 'otlet portable worker error code is invalid';
  END IF;
  IF portable_worker_heartbeat.worker_process_rss_bytes NOT BETWEEN 0 AND 70368744177664 THEN
    RAISE EXCEPTION 'otlet portable worker RSS sample is invalid';
  END IF;

  worker_row := otlet.authorized_portable_worker(
    portable_worker_heartbeat.requested_worker_id,
    portable_worker_heartbeat.requested_protocol_version,
    portable_worker_heartbeat.requested_runtime_identity_hash
  );
  UPDATE otlet.portable_workers w
  SET reported_state = portable_worker_heartbeat.reported_state,
      model_status = COALESCE(portable_worker_heartbeat.model_status, w.model_status),
      last_error_code = portable_worker_heartbeat.error_code,
      last_heartbeat_at = now(),
      process_started_at = CASE
        WHEN portable_worker_heartbeat.reported_state = 'starting'
         AND w.reported_state <> 'starting' THEN now()
        ELSE w.process_started_at
      END,
      updated_at = now()
  WHERE w.worker_id = worker_row.worker_id
  RETURNING w.desired_state, w.model_name INTO desired_state, registered_model_name;
  IF portable_worker_heartbeat.worker_process_rss_bytes > 0 THEN
    INSERT INTO otlet.portable_worker_process_samples (
      runtime_name,
      worker_id,
      worker_process_rss_bytes,
      sampled_at
    )
    VALUES (
      worker_row.runtime_name,
      worker_row.worker_id,
      portable_worker_heartbeat.worker_process_rss_bytes,
      now()
    )
    ON CONFLICT (runtime_name, worker_id) DO UPDATE
    SET worker_process_rss_bytes = EXCLUDED.worker_process_rss_bytes,
        sampled_at = EXCLUDED.sampled_at;
  END IF;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.portable_claim_jobs(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text,
  requested_claim_limit integer DEFAULT NULL
) RETURNS TABLE (
  protocol_version integer,
  worker_id text,
  job_id bigint,
  claim_token text,
  claim_status text,
  attempt_index integer,
  leased_until timestamptz,
  task_name text,
  subject_id text,
  instruction text,
  output_schema jsonb,
  runtime_options jsonb,
  decision_contract jsonb,
  input_snapshot jsonb,
  prompt text,
  prompt_hash text,
  model_policy jsonb,
  evidence_limits jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  worker_row otlet.portable_workers%ROWTYPE;
  claimed_job otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  policy_row otlet.production_policy%ROWTYPE;
  saved_claim otlet.portable_claims%ROWTYPE;
  selected_model_policy jsonb;
BEGIN
  IF portable_claim_jobs.requested_claim_limit IS NOT NULL
     AND portable_claim_jobs.requested_claim_limit NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION 'otlet portable claim limit must be between 1 and 128';
  END IF;
  worker_row := otlet.authorized_portable_worker(
    portable_claim_jobs.requested_worker_id,
    portable_claim_jobs.requested_protocol_version,
    portable_claim_jobs.requested_runtime_identity_hash
  );
  IF worker_row.desired_state <> 'running' THEN
    RETURN;
  END IF;
  SELECT p.* INTO policy_row FROM otlet.production_policy p WHERE p.name = 'default';

  FOR claimed_job IN
    SELECT *
    FROM otlet.claim_jobs(worker_row.model_name, portable_claim_jobs.requested_claim_limit)
  LOOP
    UPDATE otlet.portable_claims c
    SET status = 'replaced',
        finished_at = now()
    WHERE c.job_id = claimed_job.id
      AND c.status IN ('claimed', 'renewed');

    INSERT INTO otlet.portable_claims (
      job_id,
      worker_id,
      protocol_version,
      runtime_identity_hash,
      attempt_index,
      claim_token_hash
    )
    VALUES (
      claimed_job.id,
      worker_row.worker_id,
      worker_row.protocol_version,
      worker_row.runtime_identity_hash,
      claimed_job.attempts,
      otlet.portable_text_hash(claimed_job.claim_token)
    )
    RETURNING * INTO saved_claim;

    UPDATE otlet.portable_workers w
    SET last_claimed_at = now(),
        last_heartbeat_at = now(),
        reported_state = 'running'
    WHERE w.worker_id = worker_row.worker_id;

    SELECT t.*
    INTO task_row
    FROM otlet.tasks t
    WHERE t.name = claimed_job.task_name;

    SELECT jsonb_build_object(
      'direct', jsonb_build_object(
        'name', direct_model.name,
        'artifact_hash', direct_model.artifact_hash,
        'artifact_identity', direct_model.artifact_identity
      )
    ) || CASE
      WHEN selection.task_name IS NULL THEN '{}'::jsonb
      ELSE jsonb_build_object(
        'cheap', jsonb_build_object(
          'name', cheap_model.name,
          'artifact_hash', cheap_model.artifact_hash,
          'artifact_identity', cheap_model.artifact_identity
        ),
        'strong', jsonb_build_object(
          'name', strong_model.name,
          'artifact_hash', strong_model.artifact_hash,
          'artifact_identity', strong_model.artifact_identity
        ),
        'accept_field_checks', selection.accept_field_checks
      )
    END
    INTO selected_model_policy
    FROM otlet.models direct_model
    LEFT JOIN otlet.model_selection_policies selection ON selection.task_name = task_row.name
    LEFT JOIN otlet.models cheap_model ON cheap_model.name = selection.cheap_model_name
    LEFT JOIN otlet.models strong_model ON strong_model.name = selection.strong_model_name
    WHERE direct_model.name = task_row.model_name;

    protocol_version := worker_row.protocol_version;
    worker_id := worker_row.worker_id;
    job_id := claimed_job.id;
    claim_token := claimed_job.claim_token;
    claim_status := claimed_job.status;
    attempt_index := claimed_job.attempts;
    leased_until := claimed_job.leased_until;
    task_name := claimed_job.task_name;
    subject_id := claimed_job.subject_id;
    instruction := task_row.instruction;
    output_schema := task_row.output_schema;
    runtime_options := policy_row.default_runtime_options || task_row.runtime_options;
    decision_contract := task_row.decision_contract;
    input_snapshot := otlet.semantic_shaped_input(claimed_job.input, task_row.input_shaping);
    prompt := otlet.portable_prompt_text(
      task_row.instruction,
      task_row.output_schema,
      input_snapshot,
      runtime_options,
      task_row.decision_contract
    );
    prompt_hash := otlet.portable_text_hash(prompt);
    model_policy := selected_model_policy;
    evidence_limits := jsonb_build_object(
      'max_input_bytes', policy_row.max_input_bytes_per_job,
      'max_raw_output_bytes', policy_row.max_raw_output_bytes,
      'max_structured_output_bytes', policy_row.max_structured_output_bytes,
      'max_actions_per_job', policy_row.max_actions_per_job,
      'max_action_bytes', policy_row.max_action_bytes,
      'max_trace_bytes', policy_row.max_trace_bytes,
      'max_error_bytes', policy_row.max_error_bytes,
      'max_attempt_ms', policy_row.max_attempt_ms
    );
    RETURN NEXT;
  END LOOP;
END;
$$;

CREATE FUNCTION otlet.portable_renew_job(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text,
  requested_job_id bigint,
  requested_claim_token text
) RETURNS TABLE (job_status text, leased_until timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  worker_row otlet.portable_workers%ROWTYPE;
  claim_row otlet.portable_claims%ROWTYPE;
BEGIN
  worker_row := otlet.authorized_portable_worker(
    portable_renew_job.requested_worker_id,
    portable_renew_job.requested_protocol_version,
    portable_renew_job.requested_runtime_identity_hash
  );
  claim_row := otlet.authorized_portable_claim(
    worker_row.worker_id,
    portable_renew_job.requested_job_id,
    portable_renew_job.requested_claim_token
  );

  SELECT renewed.status, renewed.leased_until
  INTO job_status, portable_renew_job.leased_until
  FROM otlet.renew_job_lease(
    portable_renew_job.requested_job_id,
    portable_renew_job.requested_claim_token
  ) renewed;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable job claim is stale';
  END IF;

  UPDATE otlet.portable_claims c
  SET status = 'renewed',
      last_renewed_at = now()
  WHERE c.id = claim_row.id;
  UPDATE otlet.portable_workers w
  SET last_heartbeat_at = now(),
      reported_state = 'running'
  WHERE w.worker_id = worker_row.worker_id;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.portable_record_attempt(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text,
  requested_job_id bigint,
  requested_claim_token text,
  model_name text,
  selection_role text,
  selection_status text,
  selection_reason text DEFAULT NULL,
  output jsonb DEFAULT NULL,
  raw_output text DEFAULT NULL,
  prompt_hash text DEFAULT NULL,
  input_hash text DEFAULT NULL,
  output_schema_hash text DEFAULT NULL,
  raw_output_hash text DEFAULT NULL,
  trace_summary jsonb DEFAULT '{}'::jsonb,
  schema_validation_status text DEFAULT NULL,
  error text DEFAULT NULL,
  started_at timestamptz DEFAULT NULL
) RETURNS TABLE (
  receipt_id bigint,
  attempt_index integer,
  receipt_status text,
  schema_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  worker_row otlet.portable_workers%ROWTYPE;
  claim_row otlet.portable_claims%ROWTYPE;
  receipt_row otlet.inference_receipts%ROWTYPE;
BEGIN
  worker_row := otlet.authorized_portable_worker(
    portable_record_attempt.requested_worker_id,
    portable_record_attempt.requested_protocol_version,
    portable_record_attempt.requested_runtime_identity_hash
  );
  claim_row := otlet.authorized_portable_claim(
    worker_row.worker_id,
    portable_record_attempt.requested_job_id,
    portable_record_attempt.requested_claim_token
  );
  IF COALESCE(portable_record_attempt.selection_status, '') NOT IN ('rejected', 'failed') THEN
    RAISE EXCEPTION 'otlet portable attempt must be rejected or failed';
  END IF;

  receipt_row := otlet.record_model_attempt(
    portable_record_attempt.requested_job_id,
    portable_record_attempt.model_name,
    output => portable_record_attempt.output,
    raw_output => portable_record_attempt.raw_output,
    prompt_hash => portable_record_attempt.prompt_hash,
    input_hash => portable_record_attempt.input_hash,
    output_schema_hash => portable_record_attempt.output_schema_hash,
    raw_output_hash => portable_record_attempt.raw_output_hash,
    started_at => portable_record_attempt.started_at,
    trace_summary => portable_record_attempt.trace_summary,
    schema_validation_status => portable_record_attempt.schema_validation_status,
    selection_role => portable_record_attempt.selection_role,
    selection_status => portable_record_attempt.selection_status,
    selection_reason => portable_record_attempt.selection_reason,
    error => portable_record_attempt.error,
    expected_claim_token => portable_record_attempt.requested_claim_token,
    runtime_name => 'portable:' || worker_row.runtime_name,
    runtime_endpoint => 'postgres_rpc'
  );
  PERFORM otlet.link_portable_receipt(claim_row.id, receipt_row.id);

  receipt_id := receipt_row.id;
  attempt_index := receipt_row.attempt_index;
  receipt_status := receipt_row.status;
  schema_status := receipt_row.schema_validation_status;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.portable_complete_job(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text,
  requested_job_id bigint,
  requested_claim_token text,
  output jsonb,
  raw_output text,
  actions jsonb DEFAULT '[]'::jsonb,
  prompt_hash text DEFAULT NULL,
  input_hash text DEFAULT NULL,
  output_schema_hash text DEFAULT NULL,
  raw_output_hash text DEFAULT NULL,
  trace_summary jsonb DEFAULT '{}'::jsonb,
  model_name text DEFAULT NULL,
  selection_role text DEFAULT 'direct',
  selection_reason text DEFAULT NULL,
  started_at timestamptz DEFAULT NULL
) RETURNS TABLE (
  job_id bigint,
  job_status text,
  receipt_id bigint,
  output_id bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  worker_row otlet.portable_workers%ROWTYPE;
  claim_row otlet.portable_claims%ROWTYPE;
BEGIN
  worker_row := otlet.authorized_portable_worker(
    portable_complete_job.requested_worker_id,
    portable_complete_job.requested_protocol_version,
    portable_complete_job.requested_runtime_identity_hash
  );
  claim_row := otlet.authorized_portable_claim(
    worker_row.worker_id,
    portable_complete_job.requested_job_id,
    portable_complete_job.requested_claim_token
  );

  SELECT completed.id, completed.receipt_id
  INTO output_id, receipt_id
  FROM otlet.complete_job(
    portable_complete_job.requested_job_id,
    portable_complete_job.output,
    portable_complete_job.raw_output,
    portable_complete_job.actions,
    prompt_hash => portable_complete_job.prompt_hash,
    input_hash => portable_complete_job.input_hash,
    output_schema_hash => portable_complete_job.output_schema_hash,
    raw_output_hash => portable_complete_job.raw_output_hash,
    started_at => portable_complete_job.started_at,
    trace_summary => portable_complete_job.trace_summary,
    model_name => portable_complete_job.model_name,
    selection_role => portable_complete_job.selection_role,
    selection_status => 'accepted',
    selection_reason => portable_complete_job.selection_reason,
    expected_claim_token => portable_complete_job.requested_claim_token,
    runtime_name => 'portable:' || worker_row.runtime_name,
    runtime_endpoint => 'postgres_rpc'
  ) completed;

  SELECT j.id, j.status
  INTO job_id, job_status
  FROM otlet.jobs j
  WHERE j.id = portable_complete_job.requested_job_id;
  IF receipt_id IS NULL THEN
    SELECT r.id
    INTO receipt_id
    FROM otlet.inference_receipts r
    WHERE r.job_id = portable_complete_job.requested_job_id
    ORDER BY r.id DESC
    LIMIT 1;
  END IF;
  PERFORM otlet.link_portable_receipt(claim_row.id, receipt_id);

  UPDATE otlet.portable_claims c
  SET status = CASE job_status WHEN 'canceled' THEN 'canceled' ELSE 'complete' END,
      finished_at = COALESCE(c.finished_at, now())
  WHERE c.id = claim_row.id;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.portable_fail_job(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text,
  requested_job_id bigint,
  requested_claim_token text,
  error text,
  raw_output text DEFAULT NULL,
  prompt_hash text DEFAULT NULL,
  input_hash text DEFAULT NULL,
  output_schema_hash text DEFAULT NULL,
  raw_output_hash text DEFAULT NULL,
  schema_validation_status text DEFAULT NULL,
  trace_summary jsonb DEFAULT '{}'::jsonb,
  model_name text DEFAULT NULL,
  selection_role text DEFAULT 'direct',
  selection_status text DEFAULT 'failed',
  selection_reason text DEFAULT NULL,
  candidate_output jsonb DEFAULT NULL,
  started_at timestamptz DEFAULT NULL
) RETURNS TABLE (job_id bigint, job_status text, receipt_id bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  worker_row otlet.portable_workers%ROWTYPE;
  claim_row otlet.portable_claims%ROWTYPE;
BEGIN
  worker_row := otlet.authorized_portable_worker(
    portable_fail_job.requested_worker_id,
    portable_fail_job.requested_protocol_version,
    portable_fail_job.requested_runtime_identity_hash
  );
  claim_row := otlet.authorized_portable_claim(
    worker_row.worker_id,
    portable_fail_job.requested_job_id,
    portable_fail_job.requested_claim_token
  );

  SELECT failed.id, failed.status
  INTO job_id, job_status
  FROM otlet.fail_job(
    portable_fail_job.requested_job_id,
    portable_fail_job.error,
    raw_output => portable_fail_job.raw_output,
    prompt_hash => portable_fail_job.prompt_hash,
    input_hash => portable_fail_job.input_hash,
    output_schema_hash => portable_fail_job.output_schema_hash,
    raw_output_hash => portable_fail_job.raw_output_hash,
    started_at => portable_fail_job.started_at,
    schema_validation_status => portable_fail_job.schema_validation_status,
    trace_summary => portable_fail_job.trace_summary,
    model_name => portable_fail_job.model_name,
    selection_role => portable_fail_job.selection_role,
    selection_status => portable_fail_job.selection_status,
    selection_reason => portable_fail_job.selection_reason,
    candidate_output => portable_fail_job.candidate_output,
    expected_claim_token => portable_fail_job.requested_claim_token,
    runtime_name => 'portable:' || worker_row.runtime_name,
    runtime_endpoint => 'postgres_rpc'
  ) failed;
  SELECT r.id
  INTO receipt_id
  FROM otlet.inference_receipts r
  WHERE r.job_id = portable_fail_job.requested_job_id
  ORDER BY r.id DESC
  LIMIT 1;
  PERFORM otlet.link_portable_receipt(claim_row.id, receipt_id);

  UPDATE otlet.portable_claims c
  SET status = CASE job_status WHEN 'canceled' THEN 'canceled' ELSE 'failed' END,
      finished_at = COALESCE(c.finished_at, now())
  WHERE c.id = claim_row.id;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.portable_cancel_job(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text,
  requested_job_id bigint,
  requested_claim_token text,
  reason text DEFAULT 'canceled'
) RETURNS TABLE (job_id bigint, job_status text, receipt_id bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  worker_row otlet.portable_workers%ROWTYPE;
  claim_row otlet.portable_claims%ROWTYPE;
BEGIN
  worker_row := otlet.authorized_portable_worker(
    portable_cancel_job.requested_worker_id,
    portable_cancel_job.requested_protocol_version,
    portable_cancel_job.requested_runtime_identity_hash
  );
  claim_row := otlet.authorized_portable_claim(
    worker_row.worker_id,
    portable_cancel_job.requested_job_id,
    portable_cancel_job.requested_claim_token
  );

  SELECT canceled.id, canceled.status
  INTO job_id, job_status
  FROM otlet.cancel_job(
    portable_cancel_job.requested_job_id,
    portable_cancel_job.requested_claim_token,
    portable_cancel_job.reason,
    runtime_name => 'portable:' || worker_row.runtime_name,
    runtime_endpoint => 'postgres_rpc'
  ) canceled;
  SELECT r.id
  INTO receipt_id
  FROM otlet.inference_receipts r
  WHERE r.job_id = portable_cancel_job.requested_job_id
  ORDER BY r.id DESC
  LIMIT 1;
  PERFORM otlet.link_portable_receipt(claim_row.id, receipt_id);

  UPDATE otlet.portable_claims c
  SET status = 'canceled',
      finished_at = COALESCE(c.finished_at, now())
  WHERE c.id = claim_row.id;
  RETURN NEXT;
END;
$$;

CREATE VIEW otlet.portable_protocol_status AS
SELECT
  p.protocol_version,
  p.protocol_name,
  p.compatibility_rule,
  p.status,
  count(w.worker_id) AS registered_workers,
  count(w.worker_id) FILTER (WHERE w.enabled) AS enabled_workers
FROM otlet.portable_protocol_versions p
LEFT JOIN otlet.portable_workers w ON w.protocol_version = p.protocol_version
GROUP BY p.protocol_version, p.protocol_name, p.compatibility_rule, p.status;

CREATE VIEW otlet.portable_worker_status AS
SELECT
  w.worker_id,
  pg_catalog.pg_get_userbyid(w.database_role_oid) AS database_role,
  w.protocol_version,
  w.model_name,
  w.runtime_name,
  w.runtime_version,
  w.runtime_identity_hash,
  w.enabled,
  w.desired_state,
  w.reported_state,
  w.model_status,
  w.last_error_code,
  w.last_seen_at,
  w.last_heartbeat_at,
  w.last_claimed_at,
  w.process_started_at,
  sample.worker_process_rss_bytes,
  sample.sampled_at AS worker_memory_sampled_at,
  CASE
    WHEN NOT w.enabled THEN 'disabled'
    WHEN w.desired_state = 'draining' AND w.reported_state = 'drained' THEN 'drained'
    WHEN w.last_heartbeat_at IS NULL THEN 'never_seen'
    WHEN w.last_heartbeat_at < now() - interval '2 minutes' THEN 'stale'
    WHEN w.desired_state = 'paused' THEN 'paused'
    WHEN w.desired_state = 'draining' THEN 'draining'
    ELSE 'healthy'
  END AS worker_health,
  (
    SELECT count(*)
    FROM otlet.jobs queued_job
    JOIN otlet.tasks queued_task ON queued_task.name = queued_job.task_name
    WHERE queued_task.model_name = w.model_name
      AND queued_job.status = 'queued'
  ) AS queued_jobs,
  count(c.id) AS claims,
  count(c.id) FILTER (
    WHERE c.status IN ('claimed', 'renewed')
      AND j.status IN ('running', 'cancel_requested')
      AND j.leased_until >= now()
  ) AS live_claims,
  count(c.id) FILTER (
    WHERE c.status IN ('claimed', 'renewed')
      AND j.status IN ('running', 'cancel_requested')
      AND (j.leased_until IS NULL OR j.leased_until < now())
  ) AS expired_claims,
  min(j.leased_until) FILTER (
    WHERE c.status IN ('claimed', 'renewed')
      AND j.status IN ('running', 'cancel_requested')
  ) AS earliest_lease_expires_at,
  max(c.claimed_at) AS latest_claimed_at
FROM otlet.portable_workers w
LEFT JOIN otlet.portable_claims c ON c.worker_id = w.worker_id
LEFT JOIN otlet.jobs j ON j.id = c.job_id
LEFT JOIN otlet.portable_worker_process_samples sample
  ON sample.runtime_name = w.runtime_name
 AND sample.worker_id = w.worker_id
GROUP BY
  w.worker_id,
  w.database_role_oid,
  w.protocol_version,
  w.model_name,
  w.runtime_name,
  w.runtime_version,
  w.runtime_identity_hash,
  w.enabled,
  w.desired_state,
  w.reported_state,
  w.model_status,
  w.last_error_code,
  w.last_seen_at,
  w.last_heartbeat_at,
  w.last_claimed_at,
  w.process_started_at,
  sample.worker_process_rss_bytes,
  sample.sampled_at;

CREATE VIEW otlet.portable_claim_status AS
SELECT
  c.id AS claim_id,
  c.job_id,
  c.worker_id,
  c.protocol_version,
  c.runtime_identity_hash,
  c.attempt_index,
  c.status AS claim_status,
  j.status AS job_status,
  j.task_name,
  j.subject_id,
  j.leased_until,
  CASE
    WHEN c.status NOT IN ('claimed', 'renewed') THEN 'terminal'
    WHEN j.leased_until IS NULL OR j.leased_until < now() THEN 'expired'
    ELSE 'live'
  END AS lease_health,
  c.claimed_at,
  c.last_renewed_at,
  c.finished_at
FROM otlet.portable_claims c
JOIN otlet.jobs j ON j.id = c.job_id;

CREATE VIEW otlet.portable_receipt_status AS
SELECT
  l.receipt_id,
  l.claim_id,
  c.job_id,
  c.worker_id,
  c.protocol_version,
  c.runtime_identity_hash,
  r.attempt_index,
  r.status AS receipt_status,
  r.selection_role,
  r.selection_status,
  r.schema_validation_status,
  r.model_name,
  r.runtime_name,
  r.runtime_endpoint,
  r.finished_at,
  l.linked_at
FROM otlet.portable_receipt_links l
JOIN otlet.portable_claims c ON c.id = l.claim_id
JOIN otlet.inference_receipts r ON r.id = l.receipt_id;
