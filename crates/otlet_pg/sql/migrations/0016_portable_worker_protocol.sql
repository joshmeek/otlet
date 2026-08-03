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
  model_artifact_hash text NOT NULL CHECK (model_artifact_hash ~ '^[0-9a-f]{64}$'),
  model_artifact_bytes bigint NOT NULL CHECK (model_artifact_bytes > 0),
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
  incarnation_nonce_hash text CHECK (
    incarnation_nonce_hash IS NULL OR incarnation_nonce_hash ~ '^[0-9a-f]{64}$'
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
  current_rss_bytes bigint CHECK (current_rss_bytes > 0),
  process_started_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX portable_workers_role_runtime_idx
ON otlet.portable_workers (database_role_oid, runtime_identity_hash);

CREATE TABLE otlet.portable_claims (
  id bigserial PRIMARY KEY,
  job_id bigint NOT NULL,
  workload_revision_hash text NOT NULL,
  worker_id text NOT NULL REFERENCES otlet.portable_workers(worker_id),
  protocol_version integer NOT NULL,
  runtime_identity_hash text NOT NULL,
  incarnation_nonce_hash text NOT NULL CHECK (incarnation_nonce_hash ~ '^[0-9a-f]{64}$'),
  attempt_index integer NOT NULL CHECK (attempt_index > 0),
  selection_role text NOT NULL CHECK (selection_role IN ('direct', 'cheap', 'strong')),
  claim_token_hash text NOT NULL UNIQUE CHECK (claim_token_hash ~ '^[0-9a-f]{64}$'),
  status text NOT NULL DEFAULT 'claimed' CHECK (
    status IN ('claimed', 'renewed', 'complete', 'failed', 'canceled', 'replaced')
  ),
  runtime_options_status jsonb NOT NULL CHECK (
    jsonb_typeof(runtime_options_status) = 'object'
    AND runtime_options_status @> '{"compatible":true}'::jsonb
    AND octet_length(runtime_options_status::text) <= 65536
  ),
  claimed_at timestamptz NOT NULL DEFAULT now(),
  last_renewed_at timestamptz,
  finished_at timestamptz,
  FOREIGN KEY (job_id, workload_revision_hash)
    REFERENCES otlet.jobs(id, workload_revision_hash) ON DELETE CASCADE
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

CREATE FUNCTION otlet.lock_portable_worker_claim_jobs(worker_id text) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM job.id
  FROM otlet.jobs job
  JOIN otlet.portable_claims claim ON claim.job_id = job.id
  WHERE claim.worker_id = lock_portable_worker_claim_jobs.worker_id
    AND claim.status IN ('claimed', 'renewed')
  ORDER BY job.id
  FOR UPDATE OF job;
END;
$$;

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
  model_row otlet.models%ROWTYPE;
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
  IF register_portable_worker.runtime_identity -> 'runtime_contract'
       IS DISTINCT FROM otlet.portable_reference_runtime_contract() THEN
    RAISE EXCEPTION 'otlet portable runtime contract is incompatible';
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

  SELECT m.*
  INTO model_row
  FROM otlet.models m
  WHERE m.name = register_portable_worker.model_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable worker model does not exist';
  END IF;

  INSERT INTO otlet.portable_workers (
    worker_id,
    database_role_oid,
    protocol_version,
    model_name,
    model_artifact_hash,
    model_artifact_bytes,
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
    model_row.artifact_hash,
    (model_row.artifact_identity ->> 'bytes')::bigint,
    register_portable_worker.runtime_name,
    register_portable_worker.runtime_version,
    register_portable_worker.runtime_identity,
    otlet.portable_json_hash(register_portable_worker.runtime_identity)
  )
  ON CONFLICT ON CONSTRAINT portable_workers_pkey DO UPDATE
  SET database_role_oid = EXCLUDED.database_role_oid,
      protocol_version = EXCLUDED.protocol_version,
      model_name = EXCLUDED.model_name,
      model_artifact_hash = EXCLUDED.model_artifact_hash,
      model_artifact_bytes = EXCLUDED.model_artifact_bytes,
      runtime_name = EXCLUDED.runtime_name,
      runtime_version = EXCLUDED.runtime_version,
      runtime_identity = EXCLUDED.runtime_identity,
      runtime_identity_hash = EXCLUDED.runtime_identity_hash,
      incarnation_nonce_hash = NULL,
      enabled = true,
      desired_state = 'running',
      reported_state = 'registered',
      model_status = 'unverified',
      last_error_code = NULL,
      last_heartbeat_at = NULL,
      current_rss_bytes = NULL,
      process_started_at = NULL,
      updated_at = now()
  RETURNING * INTO saved_worker;

  PERFORM otlet.lock_portable_worker_claim_jobs(saved_worker.worker_id);
  UPDATE otlet.portable_claims c
  SET status = 'replaced',
      finished_at = COALESCE(c.finished_at, now())
  WHERE c.worker_id = saved_worker.worker_id
    AND c.status IN ('claimed', 'renewed');

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

CREATE FUNCTION otlet.registered_portable_worker(
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
  WHERE p.protocol_version = registered_portable_worker.protocol_version
    AND p.status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable protocol version % is incompatible',
      registered_portable_worker.protocol_version;
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
  WHERE w.worker_id = registered_portable_worker.worker_id
    AND w.protocol_version = registered_portable_worker.protocol_version
    AND w.runtime_identity_hash = registered_portable_worker.runtime_identity_hash
    AND w.database_role_oid = invoker_role_oid
    AND w.enabled
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable worker identity is not authorized';
  END IF;

  RETURN worker_row;
END;
$$;

CREATE FUNCTION otlet.portable_start_worker(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text
) RETURNS TABLE (
  incarnation_nonce text,
  desired_state text,
  registered_model_name text,
  registered_model_artifact_hash text,
  registered_model_artifact_bytes bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  raw_nonce text := gen_random_uuid()::text;
  worker_row otlet.portable_workers%ROWTYPE;
BEGIN
  worker_row := otlet.registered_portable_worker(
    portable_start_worker.requested_worker_id,
    portable_start_worker.requested_protocol_version,
    portable_start_worker.requested_runtime_identity_hash
  );

  UPDATE otlet.portable_workers w
  SET incarnation_nonce_hash = otlet.portable_text_hash(raw_nonce),
      reported_state = 'starting',
      model_status = 'unverified',
      last_error_code = NULL,
      last_seen_at = now(),
      last_heartbeat_at = NULL,
      current_rss_bytes = NULL,
      process_started_at = clock_timestamp(),
      updated_at = now()
  WHERE w.worker_id = worker_row.worker_id
  RETURNING * INTO worker_row;

  PERFORM otlet.lock_portable_worker_claim_jobs(worker_row.worker_id);
  UPDATE otlet.portable_claims c
  SET status = 'replaced',
      finished_at = COALESCE(c.finished_at, now())
  WHERE c.worker_id = worker_row.worker_id
    AND c.status IN ('claimed', 'renewed');

  incarnation_nonce := raw_nonce;
  desired_state := worker_row.desired_state;
  registered_model_name := worker_row.model_name;
  registered_model_artifact_hash := worker_row.model_artifact_hash;
  registered_model_artifact_bytes := worker_row.model_artifact_bytes;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.authorized_portable_worker(
  worker_id text,
  protocol_version integer,
  runtime_identity_hash text,
  incarnation_nonce text
) RETURNS otlet.portable_workers
LANGUAGE plpgsql
AS $$
DECLARE
  worker_row otlet.portable_workers%ROWTYPE;
BEGIN
  IF authorized_portable_worker.incarnation_nonce IS NULL
     OR authorized_portable_worker.incarnation_nonce !~
       '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'otlet portable worker incarnation is not authorized';
  END IF;

  worker_row := otlet.registered_portable_worker(
    authorized_portable_worker.worker_id,
    authorized_portable_worker.protocol_version,
    authorized_portable_worker.runtime_identity_hash
  );
  IF worker_row.incarnation_nonce_hash IS DISTINCT FROM
       otlet.portable_text_hash(authorized_portable_worker.incarnation_nonce) THEN
    RAISE EXCEPTION 'otlet portable worker incarnation is not authorized';
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
  incarnation_nonce_hash text,
  job_id bigint,
  claim_token text,
  lock_workload_revision boolean DEFAULT false
) RETURNS otlet.portable_claims
LANGUAGE plpgsql
AS $$
DECLARE
  claim_row otlet.portable_claims%ROWTYPE;
  claim_task_name text;
  claim_selection_role text;
BEGIN
  SELECT j.task_name, c.selection_role
  INTO claim_task_name, claim_selection_role
  FROM otlet.portable_claims c
  JOIN otlet.jobs j ON j.id = c.job_id
  WHERE c.worker_id = authorized_portable_claim.worker_id
    AND c.incarnation_nonce_hash = authorized_portable_claim.incarnation_nonce_hash
    AND c.job_id = authorized_portable_claim.job_id
    AND c.claim_token_hash = otlet.portable_text_hash(authorized_portable_claim.claim_token)
    AND c.status <> 'replaced';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable job claim is stale or belongs to another worker';
  END IF;

  IF authorized_portable_claim.lock_workload_revision
     AND claim_selection_role = 'cheap' THEN
    PERFORM pg_advisory_xact_lock(
      hashtextextended('otlet_workload_revision:' || claim_task_name, 0)
    );
  END IF;

  PERFORM 1
  FROM otlet.jobs j
  WHERE j.id = authorized_portable_claim.job_id
  FOR UPDATE;

  SELECT c.*
  INTO claim_row
  FROM otlet.portable_claims c
  WHERE c.worker_id = authorized_portable_claim.worker_id
    AND c.incarnation_nonce_hash = authorized_portable_claim.incarnation_nonce_hash
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
  stored_incarnation_nonce_hash text;
  stored_runtime_options_status jsonb;
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

  SELECT c.incarnation_nonce_hash, c.runtime_options_status
  INTO stored_incarnation_nonce_hash, stored_runtime_options_status
  FROM otlet.portable_claims c
  WHERE c.id = link_portable_receipt.claim_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable receipt claim does not exist';
  END IF;
  UPDATE otlet.inference_receipts r
  SET trace_summary = r.trace_summary || jsonb_build_object(
    'worker_incarnation_nonce_hash', stored_incarnation_nonce_hash,
    'runtime_options_status',
    stored_runtime_options_status
  )
  WHERE r.id = link_portable_receipt.receipt_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable receipt does not exist';
  END IF;
END;
$$;

CREATE FUNCTION otlet.reconcile_portable_terminal_claim() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  claim_row otlet.portable_claims%ROWTYPE;
  terminal_receipt_id bigint;
BEGIN
  IF NEW.status NOT IN ('complete', 'failed', 'canceled')
     OR NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT claim.*
  INTO claim_row
  FROM otlet.portable_claims claim
  WHERE claim.job_id = NEW.id
    AND claim.status IN ('claimed', 'renewed')
  ORDER BY claim.id DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  SELECT receipt.id
  INTO terminal_receipt_id
  FROM otlet.inference_receipts receipt
  JOIN otlet.portable_workers worker ON worker.worker_id = claim_row.worker_id
  WHERE receipt.job_id = NEW.id
    AND receipt.workload_revision_hash = claim_row.workload_revision_hash
    AND receipt.selection_role = claim_row.selection_role
    AND receipt.model_name = worker.model_name
    AND receipt.status = NEW.status
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.portable_receipt_links link
      WHERE link.receipt_id = receipt.id
    )
  ORDER BY receipt.attempt_index DESC, receipt.id DESC
  LIMIT 1;

  IF terminal_receipt_id IS NULL THEN
    RAISE EXCEPTION 'otlet portable terminal job has no matching receipt';
  END IF;
  UPDATE otlet.inference_receipts receipt
  SET runtime_name = 'portable:control',
      runtime_endpoint = 'postgres_rpc'
  WHERE receipt.id = terminal_receipt_id
    AND (
      receipt.runtime_name IS NULL
      OR receipt.runtime_name NOT LIKE 'portable:%'
      OR receipt.runtime_endpoint IS DISTINCT FROM 'postgres_rpc'
    );
  PERFORM otlet.link_portable_receipt(claim_row.id, terminal_receipt_id);

  UPDATE otlet.portable_claims claim
  SET status = NEW.status,
      finished_at = COALESCE(claim.finished_at, now())
  WHERE claim.id = claim_row.id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER portable_terminal_claim_reconcile
AFTER UPDATE OF status ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION otlet.reconcile_portable_terminal_claim();

CREATE FUNCTION otlet.portable_worker_heartbeat(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text,
  requested_incarnation_nonce text,
  reported_state text,
  model_status text DEFAULT NULL,
  error_code text DEFAULT NULL
) RETURNS TABLE (
  desired_state text,
  registered_model_name text,
  registered_model_artifact_hash text,
  registered_model_artifact_bytes bigint
)
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

  IF portable_worker_heartbeat.requested_incarnation_nonce IS NULL THEN
    worker_row := otlet.registered_portable_worker(
      portable_worker_heartbeat.requested_worker_id,
      portable_worker_heartbeat.requested_protocol_version,
      portable_worker_heartbeat.requested_runtime_identity_hash
    );
    desired_state := worker_row.desired_state;
    registered_model_name := worker_row.model_name;
    registered_model_artifact_hash := worker_row.model_artifact_hash;
    registered_model_artifact_bytes := worker_row.model_artifact_bytes;
    RETURN NEXT;
    RETURN;
  END IF;

  worker_row := otlet.authorized_portable_worker(
    portable_worker_heartbeat.requested_worker_id,
    portable_worker_heartbeat.requested_protocol_version,
    portable_worker_heartbeat.requested_runtime_identity_hash,
    portable_worker_heartbeat.requested_incarnation_nonce
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
  RETURNING
    w.desired_state,
    w.model_name,
    w.model_artifact_hash,
    w.model_artifact_bytes
  INTO
    desired_state,
    registered_model_name,
    registered_model_artifact_hash,
    registered_model_artifact_bytes;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.portable_claim_jobs(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text,
  requested_incarnation_nonce text,
  requested_current_rss_bytes bigint,
  requested_default_llama_threads integer,
  requested_claim_limit integer DEFAULT NULL
) RETURNS TABLE (
  protocol_version integer,
  worker_id text,
  job_id bigint,
  workload_revision_hash text,
  claim_token text,
  claim_status text,
  selection_role text,
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
  model jsonb,
  evidence_limits jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  worker_row otlet.portable_workers%ROWTYPE;
  claimed_job otlet.jobs%ROWTYPE;
  policy_row otlet.production_policy%ROWTYPE;
  saved_claim otlet.portable_claims%ROWTYPE;
  revision_definition jsonb;
  selected_model jsonb;
  claim_contract jsonb;
  runtime_options_status jsonb;
  claim_selection_role text;
BEGIN
  IF portable_claim_jobs.requested_current_rss_bytes IS NULL
     OR portable_claim_jobs.requested_current_rss_bytes <= 0 THEN
    RAISE EXCEPTION 'otlet portable current RSS bytes must be positive';
  END IF;
  IF portable_claim_jobs.requested_default_llama_threads IS NULL
     OR portable_claim_jobs.requested_default_llama_threads NOT BETWEEN 1 AND 1024 THEN
    RAISE EXCEPTION 'otlet portable default llama threads must be between 1 and 1024';
  END IF;
  IF portable_claim_jobs.requested_claim_limit IS NOT NULL
     AND portable_claim_jobs.requested_claim_limit NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION 'otlet portable claim limit must be between 1 and 128';
  END IF;
  worker_row := otlet.authorized_portable_worker(
    portable_claim_jobs.requested_worker_id,
    portable_claim_jobs.requested_protocol_version,
    portable_claim_jobs.requested_runtime_identity_hash,
    portable_claim_jobs.requested_incarnation_nonce
  );
  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE OF policy;
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
  PERFORM otlet.sweep_expired_jobs();
  IF worker_row.desired_state <> 'running' THEN
    RETURN;
  END IF;
  UPDATE otlet.portable_workers w
  SET current_rss_bytes = portable_claim_jobs.requested_current_rss_bytes,
      updated_at = now()
  WHERE w.worker_id = worker_row.worker_id
  RETURNING * INTO worker_row;
  claim_contract := jsonb_build_object(
    'runtime_contract', worker_row.runtime_identity -> 'runtime_contract',
    'model_artifact_hash', worker_row.model_artifact_hash,
    'model_artifact_bytes', worker_row.model_artifact_bytes,
    'current_rss_bytes', worker_row.current_rss_bytes,
    'default_llama_threads', portable_claim_jobs.requested_default_llama_threads
  );
  SELECT p.* INTO policy_row FROM otlet.production_policy p WHERE p.name = 'default';

  FOR claimed_job IN
    SELECT *
    FROM otlet.claim_jobs(
      worker_row.model_name,
      portable_claim_jobs.requested_claim_limit,
      claim_contract
    )
  LOOP
    SELECT revision.definition
    INTO revision_definition
    FROM otlet.workload_revisions revision
    WHERE revision.workload_revision_hash = claimed_job.workload_revision_hash
      AND revision.task_name = claimed_job.task_name;

    claim_selection_role := CASE
      WHEN claimed_job.routed_model_name IS NOT NULL THEN 'strong'
      WHEN jsonb_typeof(revision_definition -> 'selection') = 'object' THEN 'cheap'
      ELSE 'direct'
    END;
    selected_model := CASE claim_selection_role
      WHEN 'cheap' THEN revision_definition #> '{models,cheap}'
      WHEN 'strong' THEN revision_definition #> '{models,strong}'
      ELSE revision_definition #> '{models,direct}'
    END;
    runtime_options_status := otlet.portable_runtime_option_status(
      revision_definition,
      selected_model,
      claim_contract
    );
    IF selected_model ->> 'name' IS DISTINCT FROM worker_row.model_name
       OR NOT COALESCE((runtime_options_status ->> 'compatible')::boolean, false) THEN
      RAISE EXCEPTION 'otlet portable workload is incompatible with worker contract';
    END IF;

    UPDATE otlet.portable_claims c
    SET status = 'replaced',
        finished_at = now()
    WHERE c.job_id = claimed_job.id
      AND c.status IN ('claimed', 'renewed');

    INSERT INTO otlet.portable_claims (
      job_id,
      workload_revision_hash,
      worker_id,
      protocol_version,
      runtime_identity_hash,
      incarnation_nonce_hash,
      attempt_index,
      selection_role,
      claim_token_hash,
      runtime_options_status,
      claimed_at
    )
    VALUES (
      claimed_job.id,
      claimed_job.workload_revision_hash,
      worker_row.worker_id,
      worker_row.protocol_version,
      worker_row.runtime_identity_hash,
      worker_row.incarnation_nonce_hash,
      claimed_job.attempts,
      claim_selection_role,
      otlet.portable_text_hash(claimed_job.claim_token),
      runtime_options_status,
      clock_timestamp()
    )
    RETURNING * INTO saved_claim;

    UPDATE otlet.portable_workers w
    SET last_claimed_at = now(),
        last_heartbeat_at = now(),
        reported_state = 'running'
    WHERE w.worker_id = worker_row.worker_id;

    protocol_version := worker_row.protocol_version;
    worker_id := worker_row.worker_id;
    job_id := claimed_job.id;
    workload_revision_hash := claimed_job.workload_revision_hash;
    claim_token := claimed_job.claim_token;
    claim_status := claimed_job.status;
    selection_role := saved_claim.selection_role;
    attempt_index := claimed_job.attempts;
    leased_until := claimed_job.leased_until;
    task_name := claimed_job.task_name;
    subject_id := claimed_job.subject_id;
    instruction := revision_definition #>> '{task,instruction}';
    output_schema := revision_definition #> '{task,output_schema}';
    runtime_options := revision_definition #> '{runtime,effective_options}';
    decision_contract := revision_definition #> '{task,decision_contract}';
    input_snapshot := otlet.semantic_shaped_input(
      claimed_job.input,
      revision_definition #> '{task,input_shaping}'
    );
    prompt := otlet.portable_prompt_text(
      instruction,
      output_schema,
      input_snapshot,
      runtime_options,
      decision_contract
    );
    prompt_hash := otlet.portable_text_hash(prompt);
    runtime_options := runtime_options_status -> 'effective';
    model := selected_model;
    evidence_limits := jsonb_build_object(
      'max_input_bytes', policy_row.max_input_bytes_per_job,
      'max_raw_output_bytes', policy_row.max_raw_output_bytes,
      'max_structured_output_bytes', policy_row.max_structured_output_bytes,
      'max_actions_per_job', policy_row.max_actions_per_job,
      'max_action_bytes', policy_row.max_action_bytes,
      'max_trace_bytes', policy_row.max_trace_bytes,
      'max_error_bytes', policy_row.max_error_bytes,
      'max_attempt_ms', (revision_definition #>> '{runtime,effective_max_attempt_ms}')::integer
    );
    RETURN NEXT;
  END LOOP;
END;
$$;

CREATE FUNCTION otlet.portable_renew_job(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text,
  requested_incarnation_nonce text,
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
  attempt_deadline timestamptz;
BEGIN
  worker_row := otlet.authorized_portable_worker(
    portable_renew_job.requested_worker_id,
    portable_renew_job.requested_protocol_version,
    portable_renew_job.requested_runtime_identity_hash,
    portable_renew_job.requested_incarnation_nonce
  );
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
  claim_row := otlet.authorized_portable_claim(
    worker_row.worker_id,
    worker_row.incarnation_nonce_hash,
    portable_renew_job.requested_job_id,
    portable_renew_job.requested_claim_token
  );
  SELECT claim_row.claimed_at
         + (revision.definition #>> '{runtime,effective_max_attempt_ms}')::bigint
           * interval '1 millisecond'
  INTO attempt_deadline
  FROM otlet.workload_revisions revision
  WHERE revision.workload_revision_hash = claim_row.workload_revision_hash;
  IF attempt_deadline IS NULL OR clock_timestamp() >= attempt_deadline THEN
    RAISE EXCEPTION 'otlet portable attempt deadline expired';
  END IF;

  SELECT renewed.status, renewed.leased_until
  INTO job_status, portable_renew_job.leased_until
  FROM otlet.renew_job_lease(
    portable_renew_job.requested_job_id,
    portable_renew_job.requested_claim_token
  ) renewed;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable job claim is stale';
  END IF;
  IF clock_timestamp() >= attempt_deadline THEN
    RAISE EXCEPTION 'otlet portable attempt deadline expired';
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
  requested_incarnation_nonce text,
  requested_job_id bigint,
  requested_claim_token text,
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
    portable_record_attempt.requested_runtime_identity_hash,
    portable_record_attempt.requested_incarnation_nonce
  );
  claim_row := otlet.authorized_portable_claim(
    worker_row.worker_id,
    worker_row.incarnation_nonce_hash,
    portable_record_attempt.requested_job_id,
    portable_record_attempt.requested_claim_token
  );
  IF COALESCE(portable_record_attempt.selection_status, '') NOT IN ('rejected', 'failed') THEN
    RAISE EXCEPTION 'otlet portable attempt must be rejected or failed';
  END IF;

  receipt_row := otlet.record_model_attempt(
    portable_record_attempt.requested_job_id,
    worker_row.model_name,
    output => portable_record_attempt.output,
    raw_output => portable_record_attempt.raw_output,
    prompt_hash => portable_record_attempt.prompt_hash,
    input_hash => portable_record_attempt.input_hash,
    output_schema_hash => portable_record_attempt.output_schema_hash,
    raw_output_hash => portable_record_attempt.raw_output_hash,
    started_at => portable_record_attempt.started_at,
    trace_summary => portable_record_attempt.trace_summary,
    schema_validation_status => portable_record_attempt.schema_validation_status,
    selection_role => claim_row.selection_role,
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

CREATE FUNCTION otlet.portable_selection_acceptance(
  output jsonb,
  accept_field_checks jsonb
) RETURNS TABLE (accepted boolean, reason text)
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  confidence_field text := NULLIF(portable_selection_acceptance.accept_field_checks ->> 'confidence_field', '');
  answer_field text := NULLIF(portable_selection_acceptance.accept_field_checks ->> 'answer_field', '');
  field_value text;
BEGIN
  IF confidence_field IS NOT NULL THEN
    IF jsonb_typeof(portable_selection_acceptance.output -> confidence_field) IS DISTINCT FROM 'string' THEN
      RETURN QUERY SELECT false, 'missing_confidence_field'::text;
      RETURN;
    END IF;
    field_value := portable_selection_acceptance.output ->> confidence_field;
    IF jsonb_typeof(portable_selection_acceptance.accept_field_checks -> 'accepted_confidence') = 'array'
       AND EXISTS (
         SELECT 1
         FROM jsonb_array_elements(
           portable_selection_acceptance.accept_field_checks -> 'accepted_confidence'
         ) item(value)
         WHERE jsonb_typeof(item.value) = 'string'
       )
       AND NOT EXISTS (
         SELECT 1
         FROM jsonb_array_elements(
           portable_selection_acceptance.accept_field_checks -> 'accepted_confidence'
         ) item(value)
         WHERE jsonb_typeof(item.value) = 'string'
           AND item.value #>> '{}' = field_value
       ) THEN
      RETURN QUERY SELECT false, 'confidence_below_policy'::text;
      RETURN;
    END IF;
  END IF;

  IF answer_field IS NULL THEN
    RETURN QUERY SELECT true, 'accepted_by_policy'::text;
    RETURN;
  END IF;
  IF jsonb_typeof(portable_selection_acceptance.output -> answer_field) IS DISTINCT FROM 'string' THEN
    RETURN QUERY SELECT false, 'missing_decision_field'::text;
    RETURN;
  END IF;
  field_value := portable_selection_acceptance.output ->> answer_field;
  IF jsonb_typeof(portable_selection_acceptance.accept_field_checks -> 'abstain_values') = 'array'
     AND EXISTS (
       SELECT 1
       FROM jsonb_array_elements(
         portable_selection_acceptance.accept_field_checks -> 'abstain_values'
       ) item(value)
       WHERE jsonb_typeof(item.value) = 'string'
         AND item.value #>> '{}' = field_value
     ) THEN
    RETURN QUERY SELECT false, 'abstained_output'::text;
    RETURN;
  END IF;

  RETURN QUERY SELECT true, 'accepted_by_policy'::text;
END;
$$;

CREATE FUNCTION otlet.requeue_portable_job_to_strong(
  job_id bigint,
  claim_id bigint,
  expected_claim_token text
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  job_task_name text;
  strong_model_name text;
  revision_active boolean;
  terminal_status text;
  terminal_receipt_id bigint;
  changed bigint;
BEGIN
  SELECT j.task_name
  INTO job_task_name
  FROM otlet.jobs j
  WHERE j.id = requeue_portable_job_to_strong.job_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet portable job does not exist';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || job_task_name, 0)
  );
  SELECT
    revision.definition #>> '{selection,strong_model_name}',
    EXISTS (
      SELECT 1
      FROM otlet.workload_revision_heads head
      WHERE head.task_name = j.task_name
        AND head.active_workload_revision_hash = j.workload_revision_hash
    )
  INTO strong_model_name, revision_active
  FROM otlet.jobs j
  JOIN otlet.workload_revisions revision
    ON revision.workload_revision_hash = j.workload_revision_hash
  WHERE j.id = requeue_portable_job_to_strong.job_id;

  IF NOT FOUND OR strong_model_name IS NULL THEN
    RAISE EXCEPTION 'otlet portable job has no strong model route';
  END IF;

  IF NOT revision_active THEN
    SELECT canceled.status
    INTO terminal_status
    FROM otlet.cancel_job(
      requeue_portable_job_to_strong.job_id,
      requeue_portable_job_to_strong.expected_claim_token,
      'workload revision changed before portable strong fallback',
      'portable:control',
      'postgres_rpc'
    ) canceled;
    IF terminal_status IS NULL THEN
      RAISE EXCEPTION 'otlet portable job claim is stale';
    END IF;

    SELECT receipt.id
    INTO terminal_receipt_id
    FROM otlet.inference_receipts receipt
    WHERE receipt.job_id = requeue_portable_job_to_strong.job_id
    ORDER BY receipt.id DESC
    LIMIT 1;
    PERFORM otlet.link_portable_receipt(
      requeue_portable_job_to_strong.claim_id,
      terminal_receipt_id
    );
    UPDATE otlet.portable_claims claim
    SET status = 'canceled',
        finished_at = COALESCE(claim.finished_at, now())
    WHERE claim.id = requeue_portable_job_to_strong.claim_id;
    RETURN terminal_status;
  END IF;

  UPDATE otlet.jobs j
  SET status = 'queued',
      attempts = GREATEST(j.attempts - 1, 0),
      routed_model_name = strong_model_name,
      leased_until = NULL,
      claim_token = NULL,
      terminal_claim_token = NULL,
      terminal_request_hash = NULL,
      error = NULL,
      finished_at = NULL,
      cancel_requested_at = NULL
  WHERE j.id = requeue_portable_job_to_strong.job_id
    AND j.claim_token = requeue_portable_job_to_strong.expected_claim_token
    AND j.status = 'running';
  GET DIAGNOSTICS changed = ROW_COUNT;
  IF changed <> 1 THEN
    RAISE EXCEPTION 'otlet portable job claim is stale';
  END IF;

  UPDATE otlet.portable_claims c
  SET status = 'replaced',
      finished_at = COALESCE(c.finished_at, now())
  WHERE c.id = requeue_portable_job_to_strong.claim_id;
  PERFORM otlet.wake_worker();
  RETURN 'queued';
END;
$$;

CREATE FUNCTION otlet.portable_strong_selection_reason(job_id bigint)
RETURNS text
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
  SELECT CASE r.selection_status
    WHEN 'rejected' THEN 'escalated_after_cheap_rejection'
    WHEN 'failed' THEN 'escalated_after_cheap_schema_failure'
  END
  FROM otlet.inference_receipts r
  WHERE r.job_id = portable_strong_selection_reason.job_id
    AND r.selection_role = 'cheap'
  ORDER BY r.attempt_index DESC, r.id DESC
  LIMIT 1
$$;

CREATE FUNCTION otlet.portable_complete_job(
  requested_worker_id text,
  requested_protocol_version integer,
  requested_runtime_identity_hash text,
  requested_incarnation_nonce text,
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
  receipt_row otlet.inference_receipts%ROWTYPE;
  validated_identity jsonb;
  acceptance_accepted boolean;
  acceptance_reason text;
  current_job_status text;
BEGIN
  worker_row := otlet.authorized_portable_worker(
    portable_complete_job.requested_worker_id,
    portable_complete_job.requested_protocol_version,
    portable_complete_job.requested_runtime_identity_hash,
    portable_complete_job.requested_incarnation_nonce
  );
  claim_row := otlet.authorized_portable_claim(
    worker_row.worker_id,
    worker_row.incarnation_nonce_hash,
    portable_complete_job.requested_job_id,
    portable_complete_job.requested_claim_token,
    true
  );
  SELECT j.status
  INTO current_job_status
  FROM otlet.jobs j
  WHERE j.id = portable_complete_job.requested_job_id;

  IF claim_row.selection_role = 'cheap'
     AND current_job_status = 'running' THEN
    validated_identity := otlet.validate_portable_result(
      portable_complete_job.requested_job_id,
      portable_complete_job.output,
      portable_complete_job.raw_output,
      portable_complete_job.actions,
      worker_row.model_name,
      claim_row.selection_role,
      portable_complete_job.prompt_hash,
      portable_complete_job.input_hash,
      portable_complete_job.output_schema_hash,
      portable_complete_job.raw_output_hash,
      portable_complete_job.trace_summary
    );
    SELECT accepted, reason
    INTO acceptance_accepted, acceptance_reason
    FROM otlet.portable_selection_acceptance(
      portable_complete_job.output,
      (
        SELECT revision.definition #> '{selection,accept_field_checks}'
        FROM otlet.workload_revisions revision
        WHERE revision.workload_revision_hash = claim_row.workload_revision_hash
      )
    );
    IF NOT acceptance_accepted THEN
      receipt_row := otlet.record_model_attempt(
        portable_complete_job.requested_job_id,
        worker_row.model_name,
        output => portable_complete_job.output,
        raw_output => portable_complete_job.raw_output,
        prompt_hash => validated_identity ->> 'prompt_hash',
        input_hash => validated_identity ->> 'input_hash',
        output_schema_hash => validated_identity ->> 'output_schema_hash',
        raw_output_hash => validated_identity ->> 'raw_output_hash',
        started_at => portable_complete_job.started_at,
        trace_summary => portable_complete_job.trace_summary,
        schema_validation_status => 'passed',
        selection_role => 'cheap',
        selection_status => 'rejected',
        selection_reason => acceptance_reason,
        expected_claim_token => portable_complete_job.requested_claim_token,
        actions => portable_complete_job.actions,
        runtime_name => 'portable:' || worker_row.runtime_name,
        runtime_endpoint => 'postgres_rpc'
      );
      PERFORM otlet.link_portable_receipt(claim_row.id, receipt_row.id);
      job_status := otlet.requeue_portable_job_to_strong(
        portable_complete_job.requested_job_id,
        claim_row.id,
        portable_complete_job.requested_claim_token
      );
      job_id := portable_complete_job.requested_job_id;
      receipt_id := receipt_row.id;
      output_id := NULL;
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

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
    model_name => worker_row.model_name,
    selection_role => claim_row.selection_role,
    selection_status => 'accepted',
    selection_reason => COALESCE(
      portable_complete_job.selection_reason,
      CASE claim_row.selection_role
        WHEN 'strong' THEN otlet.portable_strong_selection_reason(
          portable_complete_job.requested_job_id
        )
      END,
      acceptance_reason
    ),
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
  PERFORM otlet.materialize_completed_semantic_job(
    portable_complete_job.requested_job_id
  );

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
  requested_incarnation_nonce text,
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
  receipt_row otlet.inference_receipts%ROWTYPE;
  current_job_status text;
BEGIN
  worker_row := otlet.authorized_portable_worker(
    portable_fail_job.requested_worker_id,
    portable_fail_job.requested_protocol_version,
    portable_fail_job.requested_runtime_identity_hash,
    portable_fail_job.requested_incarnation_nonce
  );
  claim_row := otlet.authorized_portable_claim(
    worker_row.worker_id,
    worker_row.incarnation_nonce_hash,
    portable_fail_job.requested_job_id,
    portable_fail_job.requested_claim_token,
    true
  );
  SELECT j.status
  INTO current_job_status
  FROM otlet.jobs j
  WHERE j.id = portable_fail_job.requested_job_id;

  IF claim_row.selection_role = 'cheap'
     AND current_job_status = 'running'
     AND portable_fail_job.raw_output IS NOT NULL THEN
    receipt_row := otlet.record_model_attempt(
      portable_fail_job.requested_job_id,
      worker_row.model_name,
      output => portable_fail_job.candidate_output,
      raw_output => portable_fail_job.raw_output,
      prompt_hash => portable_fail_job.prompt_hash,
      input_hash => portable_fail_job.input_hash,
      output_schema_hash => portable_fail_job.output_schema_hash,
      raw_output_hash => portable_fail_job.raw_output_hash,
      started_at => portable_fail_job.started_at,
      trace_summary => portable_fail_job.trace_summary,
      schema_validation_status => portable_fail_job.schema_validation_status,
      selection_role => 'cheap',
      selection_status => 'failed',
      selection_reason => COALESCE(
        portable_fail_job.selection_reason,
        'cheap_attempt_failed'
      ),
      error => portable_fail_job.error,
      expected_claim_token => portable_fail_job.requested_claim_token,
      runtime_name => 'portable:' || worker_row.runtime_name,
      runtime_endpoint => 'postgres_rpc'
    );
    PERFORM otlet.link_portable_receipt(claim_row.id, receipt_row.id);
    job_status := otlet.requeue_portable_job_to_strong(
      portable_fail_job.requested_job_id,
      claim_row.id,
      portable_fail_job.requested_claim_token
    );
    job_id := portable_fail_job.requested_job_id;
    receipt_id := receipt_row.id;
    RETURN NEXT;
    RETURN;
  END IF;

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
    model_name => worker_row.model_name,
    selection_role => claim_row.selection_role,
    selection_status => portable_fail_job.selection_status,
    selection_reason => COALESCE(
      portable_fail_job.selection_reason,
      CASE claim_row.selection_role
        WHEN 'strong' THEN otlet.portable_strong_selection_reason(
          portable_fail_job.requested_job_id
        )
      END
    ),
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
  requested_incarnation_nonce text,
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
    portable_cancel_job.requested_runtime_identity_hash,
    portable_cancel_job.requested_incarnation_nonce
  );
  claim_row := otlet.authorized_portable_claim(
    worker_row.worker_id,
    worker_row.incarnation_nonce_hash,
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
  w.model_artifact_hash,
  w.model_artifact_bytes,
  w.runtime_name,
  w.runtime_version,
  w.runtime_identity_hash,
  w.incarnation_nonce_hash,
  w.runtime_identity -> 'runtime_contract' AS runtime_contract,
  w.enabled,
  w.desired_state,
  w.reported_state,
  w.model_status,
  w.last_error_code,
  w.last_seen_at,
  w.last_heartbeat_at,
  w.last_claimed_at,
  w.current_rss_bytes,
  w.process_started_at,
  CASE
    WHEN NOT w.enabled THEN 'disabled'
    WHEN w.desired_state = 'draining' AND w.reported_state = 'drained' THEN 'drained'
    WHEN w.last_heartbeat_at IS NULL THEN 'never_seen'
    WHEN w.last_heartbeat_at < now() - interval '2 minutes' THEN 'stale'
    WHEN w.desired_state = 'paused' THEN 'paused'
    WHEN w.desired_state = 'draining' THEN 'draining'
    ELSE 'healthy'
  END AS worker_health,
  queue.queued_jobs,
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
  max(c.claimed_at) AS latest_claimed_at,
  queue.suspended_revision_queued_jobs
FROM otlet.portable_workers w
LEFT JOIN LATERAL (
  SELECT
    count(*) FILTER (
      WHERE queued_job.workload_revision_hash = queued_head.active_workload_revision_hash
    )::bigint AS queued_jobs,
    count(*) FILTER (
      WHERE queued_job.workload_revision_hash IS DISTINCT FROM queued_head.active_workload_revision_hash
    )::bigint AS suspended_revision_queued_jobs
  FROM otlet.jobs queued_job
  JOIN otlet.workload_revisions queued_revision
    ON queued_revision.task_name = queued_job.task_name
   AND queued_revision.workload_revision_hash = queued_job.workload_revision_hash
  LEFT JOIN otlet.workload_revision_heads queued_head
    ON queued_head.task_name = queued_job.task_name
  WHERE queued_job.status = 'queued'
    AND COALESCE(
      queued_job.routed_model_name,
      queued_revision.definition #>> '{models,direct,name}'
    ) = w.model_name
) queue ON true
LEFT JOIN otlet.portable_claims c ON c.worker_id = w.worker_id
LEFT JOIN otlet.jobs j ON j.id = c.job_id
GROUP BY
  w.worker_id,
  w.database_role_oid,
  w.protocol_version,
  w.model_name,
  w.model_artifact_hash,
  w.model_artifact_bytes,
  w.runtime_name,
  w.runtime_version,
  w.runtime_identity_hash,
  w.incarnation_nonce_hash,
  w.runtime_identity,
  w.enabled,
  w.desired_state,
  w.reported_state,
  w.model_status,
  w.last_error_code,
  w.last_seen_at,
  w.last_heartbeat_at,
  w.last_claimed_at,
  w.current_rss_bytes,
  w.process_started_at,
  queue.queued_jobs,
  queue.suspended_revision_queued_jobs;

CREATE VIEW otlet.portable_claim_status AS
SELECT
  c.id AS claim_id,
  c.job_id,
  c.workload_revision_hash,
  c.worker_id,
  c.protocol_version,
  c.runtime_identity_hash,
  c.incarnation_nonce_hash,
  c.attempt_index,
  c.selection_role,
  c.runtime_options_status,
  CASE
    WHEN c.status IN ('claimed', 'renewed')
      AND j.status IN ('complete', 'failed', 'canceled') THEN j.status
    ELSE c.status
  END AS claim_status,
  j.status AS job_status,
  j.task_name,
  j.subject_id,
  j.leased_until,
  c.claimed_at
    + (revision.definition #>> '{runtime,effective_max_attempt_ms}')::bigint
      * interval '1 millisecond' AS attempt_deadline_at,
  CASE
    WHEN c.status NOT IN ('claimed', 'renewed')
      OR j.status IN ('complete', 'failed', 'canceled') THEN 'terminal'
    WHEN j.leased_until IS NULL OR j.leased_until < now() THEN 'expired'
    ELSE 'live'
  END AS lease_health,
  c.claimed_at,
  c.last_renewed_at,
  c.finished_at
FROM otlet.portable_claims c
JOIN otlet.jobs j ON j.id = c.job_id
JOIN otlet.workload_revisions revision
  ON revision.workload_revision_hash = c.workload_revision_hash;

CREATE VIEW otlet.portable_receipt_status AS
SELECT
  l.receipt_id,
  l.claim_id,
  c.job_id,
  c.workload_revision_hash,
  r.workload_revision_hash AS receipt_workload_revision_hash,
  c.worker_id,
  c.protocol_version,
  c.runtime_identity_hash,
  c.incarnation_nonce_hash,
  c.runtime_options_status,
  r.attempt_index,
  r.status AS receipt_status,
  r.selection_role,
  r.selection_status,
  r.schema_validation_status,
  r.model_name,
  r.runtime_name,
  r.runtime_endpoint,
  r.trace_summary ->> 'worker_incarnation_nonce_hash' AS receipt_incarnation_nonce_hash,
  r.trace_summary -> 'runtime_options_status' AS receipt_runtime_options_status,
  r.finished_at,
  l.linked_at
FROM otlet.portable_receipt_links l
JOIN otlet.portable_claims c ON c.id = l.claim_id
JOIN otlet.inference_receipts r ON r.id = l.receipt_id;
