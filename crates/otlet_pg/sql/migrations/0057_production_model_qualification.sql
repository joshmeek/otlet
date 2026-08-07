CREATE FUNCTION otlet.production_model_qualification_rule_valid(
  rule jsonb
) RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
BEGIN
  IF jsonb_typeof(rule) IS DISTINCT FROM 'object'
     OR ARRAY(
       SELECT key FROM jsonb_object_keys(rule) key ORDER BY key
     ) IS DISTINCT FROM ARRAY[
       'cancellation',
       'customer_representative',
       'database_responsiveness'
     ]::text[]
     OR jsonb_typeof(rule -> 'customer_representative') IS DISTINCT FROM 'object'
     OR ARRAY(
       SELECT key
       FROM jsonb_object_keys(rule -> 'customer_representative') key
       ORDER BY key
     ) IS DISTINCT FROM ARRAY['basis', 'evidence_hash']::text[]
     OR jsonb_typeof(rule #> '{customer_representative,basis}')
       IS DISTINCT FROM 'string'
     OR NULLIF(btrim(rule #>> '{customer_representative,basis}'), '') IS NULL
     OR octet_length(rule #>> '{customer_representative,basis}') > 4096
     OR COALESCE(rule #>> '{customer_representative,evidence_hash}', '')
       !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
     OR jsonb_typeof(rule -> 'cancellation') IS DISTINCT FROM 'object'
     OR ARRAY(
       SELECT key FROM jsonb_object_keys(rule -> 'cancellation') key ORDER BY key
     ) IS DISTINCT FROM ARRAY['max_ms']::text[]
     OR jsonb_typeof(rule #> '{cancellation,max_ms}') IS DISTINCT FROM 'number'
     OR (rule #>> '{cancellation,max_ms}')::numeric
       <> trunc((rule #>> '{cancellation,max_ms}')::numeric)
     OR (rule #>> '{cancellation,max_ms}')::numeric NOT BETWEEN 1 AND 86400000
     OR jsonb_typeof(rule -> 'database_responsiveness') IS DISTINCT FROM 'object'
     OR ARRAY(
       SELECT key
       FROM jsonb_object_keys(rule -> 'database_responsiveness') key
       ORDER BY key
     ) IS DISTINCT FROM ARRAY['max_ms']::text[]
     OR jsonb_typeof(rule #> '{database_responsiveness,max_ms}')
       IS DISTINCT FROM 'number'
     OR (rule #>> '{database_responsiveness,max_ms}')::numeric NOT BETWEEN 0 AND 60000 THEN
    RETURN false;
  END IF;
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.stamp_job_wall_clock() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF NEW.status = 'running' AND OLD.status IS DISTINCT FROM 'running' THEN
    NEW.started_at := clock_timestamp();
  END IF;
  IF NEW.status = 'cancel_requested'
     AND OLD.status IS DISTINCT FROM 'cancel_requested' THEN
    NEW.cancel_requested_at := clock_timestamp();
  END IF;
  IF NEW.status IN ('complete', 'failed', 'canceled')
     AND OLD.status NOT IN ('complete', 'failed', 'canceled') THEN
    NEW.finished_at := clock_timestamp();
  END IF;
  RETURN NEW;
END;
$$;

ALTER TABLE otlet.workload_acceptance_events
DROP CONSTRAINT workload_acceptance_events_event_kind_check;

ALTER TABLE otlet.workload_acceptance_events
ADD CHECK (event_kind IN (
  'exception',
  'promotion_decision',
  'model_qualification'
));

CREATE UNIQUE INDEX workload_acceptance_events_one_model_qualification_idx
ON otlet.workload_acceptance_events (contract_hash)
WHERE event_kind = 'model_qualification';

CREATE OR REPLACE FUNCTION otlet.append_workload_acceptance_event(
  contract_hash text,
  event_kind text,
  payload jsonb
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  task_name text;
  previous_event_hash text;
  previous_event_order bigint;
  new_event_order bigint;
  definition jsonb;
  event_hash text;
  created_at timestamptz;
  authenticated_oid oid := session_user::regrole::oid;
  active_oid oid := current_user::regrole::oid;
  previous_append text := current_setting('otlet.workload_acceptance_append', true);
BEGIN
  IF append_workload_acceptance_event.event_kind NOT IN (
    'exception',
    'promotion_decision',
    'model_qualification'
  ) THEN
    RAISE EXCEPTION 'otlet workload acceptance event kind is invalid';
  END IF;
  IF jsonb_typeof(append_workload_acceptance_event.payload) IS DISTINCT FROM 'object'
     OR octet_length(append_workload_acceptance_event.payload::text) > 65536 THEN
    RAISE EXCEPTION 'otlet workload acceptance event payload must be a bounded object';
  END IF;
  SELECT contract.task_name
  INTO task_name
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.contract_hash = append_workload_acceptance_event.contract_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload acceptance contract does not exist';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'otlet_workload_acceptance_event:' || append_workload_acceptance_event.contract_hash,
      0
    )
  );
  SELECT event.event_hash, event.event_order
  INTO previous_event_hash, previous_event_order
  FROM otlet.workload_acceptance_events event
  WHERE event.contract_hash = append_workload_acceptance_event.contract_hash
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_events successor
      WHERE successor.contract_hash = event.contract_hash
        AND successor.supersedes_event_hash = event.event_hash
    );
  new_event_order := COALESCE(previous_event_order, 0) + 1;
  created_at := clock_timestamp();
  definition := jsonb_build_object(
    'format', 'otlet.workload_acceptance.event.v1',
    'event_kind', append_workload_acceptance_event.event_kind,
    'contract_hash', append_workload_acceptance_event.contract_hash,
    'event_order', new_event_order,
    'supersedes_event_hash', to_jsonb(previous_event_hash),
    'payload', append_workload_acceptance_event.payload
  );
  event_hash := otlet.identity_hash(
    'workload_acceptance_event',
    jsonb_build_object(
      'definition', definition,
      'authenticated_role_oid', authenticated_oid::text,
      'active_role_oid', active_oid::text,
      'created_at_epoch', EXTRACT(epoch FROM created_at)
    )
  );

  PERFORM set_config('otlet.workload_acceptance_append', 'on', true);
  INSERT INTO otlet.workload_acceptance_events (
    event_hash,
    contract_hash,
    task_name,
    event_kind,
    event_order,
    definition,
    supersedes_event_hash,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name,
    created_at
  ) VALUES (
    event_hash,
    append_workload_acceptance_event.contract_hash,
    task_name,
    append_workload_acceptance_event.event_kind,
    new_event_order,
    definition,
    previous_event_hash,
    authenticated_oid,
    session_user,
    active_oid,
    current_user,
    created_at
  );
  PERFORM set_config(
    'otlet.workload_acceptance_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN event_hash;
END;
$$;

CREATE TABLE otlet.production_model_database_samples (
  sample_hash text PRIMARY KEY CHECK (
    sample_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  contract_hash text NOT NULL REFERENCES otlet.workload_acceptance_contracts(contract_hash),
  run_hash text NOT NULL REFERENCES otlet.evaluation_runs(run_hash),
  live_job_id bigint NOT NULL REFERENCES otlet.jobs(id),
  latency_ms numeric NOT NULL CHECK (latency_ms >= 0),
  lease_expires_at timestamptz NOT NULL,
  started_at timestamptz NOT NULL,
  finished_at timestamptz NOT NULL CHECK (finished_at >= started_at),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  reason text NOT NULL CHECK (
    NULLIF(btrim(reason), '') IS NOT NULL
    AND octet_length(reason) <= 4096
  ),
  authenticated_role_oid oid NOT NULL,
  authenticated_role_name text NOT NULL CHECK (
    NULLIF(btrim(authenticated_role_name), '') IS NOT NULL
  ),
  active_role_oid oid NOT NULL,
  active_role_name text NOT NULL CHECK (
    NULLIF(btrim(active_role_name), '') IS NOT NULL
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX production_model_database_samples_run_idx
ON otlet.production_model_database_samples (run_hash, finished_at, sample_hash);

CREATE FUNCTION otlet.validate_production_model_database_sample() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
BEGIN
  IF NEW.definition IS DISTINCT FROM jsonb_build_object(
       'format', 'otlet.production_model.database_sample.v1',
       'contract_hash', NEW.contract_hash,
       'run_hash', NEW.run_hash,
       'live_job_id', NEW.live_job_id,
       'latency_ms', NEW.latency_ms,
       'lease_expires_at', to_char(
         NEW.lease_expires_at AT TIME ZONE 'UTC',
         'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
       ),
       'started_at', to_char(
         NEW.started_at AT TIME ZONE 'UTC',
         'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
       ),
       'finished_at', to_char(
         NEW.finished_at AT TIME ZONE 'UTC',
         'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
       ),
       'reason', NEW.reason
     )
     OR NEW.sample_hash IS DISTINCT FROM
       otlet.identity_hash('production_model_database_sample', NEW.definition)
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.evaluation_runs run
       JOIN otlet.evaluation_executions execution
         ON execution.run_hash = run.run_hash
        AND execution.variant = 'candidate'
       WHERE run.run_hash = NEW.run_hash
         AND run.contract_hash = NEW.contract_hash
         AND execution.job_id = NEW.live_job_id
     ) THEN
    RAISE EXCEPTION 'otlet production model database sample identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER production_model_database_samples_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.production_model_database_samples
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER production_model_database_samples_b_validate
BEFORE INSERT ON otlet.production_model_database_samples
FOR EACH ROW EXECUTE FUNCTION otlet.validate_production_model_database_sample();

CREATE TRIGGER production_model_database_samples_truncate_guard
BEFORE TRUNCATE ON otlet.production_model_database_samples
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE FUNCTION otlet.record_production_model_database_sample(
  run_hash text,
  reason text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
DECLARE
  run otlet.evaluation_runs%ROWTYPE;
  contract_definition jsonb;
  live_job_id bigint;
  lease_expires_at timestamptz;
  window_starts_at timestamptz;
  window_ends_at timestamptz;
  sample_started_at timestamptz;
  sample_finished_at timestamptz;
  latency_ms numeric;
  definition jsonb;
  sample_hash text;
  previous_append text := current_setting('otlet.evaluation_append', true);
BEGIN
  IF NULLIF(btrim(record_production_model_database_sample.reason), '') IS NULL
     OR octet_length(record_production_model_database_sample.reason) > 4096 THEN
    RAISE EXCEPTION 'otlet production model database sample reason is required and bounded';
  END IF;
  SELECT * INTO run
  FROM otlet.evaluation_runs stored
  WHERE stored.run_hash = record_production_model_database_sample.run_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet production model qualification run does not exist';
  END IF;
  SELECT contract.definition INTO contract_definition
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.contract_hash = run.contract_hash;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_production_model_qualification:' || run.contract_hash,
    0
  ));
  IF contract_definition #>> '{population,mode}' IS DISTINCT FROM 'full'
     OR NOT otlet.production_model_qualification_rule_valid(
       contract_definition #> '{population,rule,production_qualification}'
     ) THEN
    RAISE EXCEPTION 'otlet production model qualification declaration is invalid';
  END IF;
  window_starts_at := (
    contract_definition #>> '{observation_window,starts_at}'
  )::timestamptz;
  window_ends_at := (
    contract_definition #>> '{observation_window,ends_at}'
  )::timestamptz;
  IF clock_timestamp() < window_starts_at OR clock_timestamp() >= window_ends_at THEN
    RAISE EXCEPTION 'otlet production model database sample is outside the observation window';
  END IF;
  SELECT execution.job_id, job.leased_until
  INTO live_job_id, lease_expires_at
  FROM otlet.evaluation_executions execution
  JOIN otlet.jobs job ON job.id = execution.job_id
  WHERE execution.run_hash = run.run_hash
    AND execution.variant = 'candidate'
    AND job.status IN ('running', 'cancel_requested')
    AND job.started_at IS NOT NULL
    AND job.claim_token IS NOT NULL
    AND job.leased_until >= clock_timestamp()
  ORDER BY execution.job_id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet production model database sample requires live candidate inference';
  END IF;

  sample_started_at := clock_timestamp();
  PERFORM 1 FROM otlet.evaluation_runs stored WHERE stored.run_hash = run.run_hash;
  sample_finished_at := clock_timestamp();
  latency_ms := EXTRACT(epoch FROM sample_finished_at - sample_started_at) * 1000;
  definition := jsonb_build_object(
    'format', 'otlet.production_model.database_sample.v1',
    'contract_hash', run.contract_hash,
    'run_hash', run.run_hash,
    'live_job_id', live_job_id,
    'latency_ms', latency_ms,
    'lease_expires_at', to_char(
      lease_expires_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
    ),
    'started_at', to_char(
      sample_started_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
    ),
    'finished_at', to_char(
      sample_finished_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
    ),
    'reason', btrim(record_production_model_database_sample.reason)
  );
  sample_hash := otlet.identity_hash('production_model_database_sample', definition);

  PERFORM set_config('otlet.evaluation_append', 'on', true);
  INSERT INTO otlet.production_model_database_samples (
    sample_hash,
    contract_hash,
    run_hash,
    live_job_id,
    latency_ms,
    lease_expires_at,
    started_at,
    finished_at,
    definition,
    reason,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name,
    created_at
  ) VALUES (
    sample_hash,
    run.contract_hash,
    run.run_hash,
    live_job_id,
    latency_ms,
    lease_expires_at,
    sample_started_at,
    sample_finished_at,
    definition,
    btrim(record_production_model_database_sample.reason),
    session_user::regrole::oid,
    session_user,
    current_user::regrole::oid,
    current_user,
    sample_finished_at
  );
  PERFORM set_config('otlet.evaluation_append', COALESCE(previous_append, ''), true);
  RETURN sample_hash;
END;
$$;

CREATE TABLE otlet.production_model_cancellation_probes (
  probe_hash text PRIMARY KEY CHECK (
    probe_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  contract_hash text NOT NULL REFERENCES otlet.workload_acceptance_contracts(contract_hash),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  candidate_workload_revision_hash text NOT NULL,
  case_hash text NOT NULL REFERENCES otlet.evaluation_cases(case_hash),
  selection_role text NOT NULL CHECK (selection_role IN ('direct', 'cheap', 'strong')),
  model_name text NOT NULL,
  model_identity_hash text NOT NULL CHECK (
    model_identity_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  job_id bigint NOT NULL UNIQUE REFERENCES otlet.jobs(id),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  reason text NOT NULL CHECK (
    NULLIF(btrim(reason), '') IS NOT NULL
    AND octet_length(reason) <= 4096
  ),
  authenticated_role_oid oid NOT NULL,
  authenticated_role_name text NOT NULL CHECK (
    NULLIF(btrim(authenticated_role_name), '') IS NOT NULL
  ),
  active_role_oid oid NOT NULL,
  active_role_name text NOT NULL CHECK (
    NULLIF(btrim(active_role_name), '') IS NOT NULL
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (contract_hash, selection_role),
  FOREIGN KEY (task_name, candidate_workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash)
);

CREATE FUNCTION otlet.validate_production_model_cancellation_probe() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  revision_definition jsonb;
  expected_model jsonb;
  job otlet.jobs%ROWTYPE;
  evaluation_case otlet.evaluation_cases%ROWTYPE;
BEGIN
  SELECT revision.definition
  INTO revision_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = NEW.task_name
    AND revision.workload_revision_hash = NEW.candidate_workload_revision_hash;
  SELECT * INTO job FROM otlet.jobs stored WHERE stored.id = NEW.job_id;
  SELECT * INTO evaluation_case
  FROM otlet.evaluation_cases stored
  WHERE stored.case_hash = NEW.case_hash;
  expected_model := revision_definition -> 'models' -> NEW.selection_role;

  IF revision_definition IS NULL
     OR job.id IS NULL
     OR evaluation_case.case_hash IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.workload_acceptance_contracts contract
       WHERE contract.contract_hash = NEW.contract_hash
         AND contract.task_name = NEW.task_name
         AND contract.candidate_workload_revision_hash =
           NEW.candidate_workload_revision_hash
     )
     OR NEW.definition IS DISTINCT FROM jsonb_build_object(
       'format', 'otlet.production_model.cancellation_probe.v1',
       'contract_hash', NEW.contract_hash,
       'task_name', NEW.task_name,
       'candidate_workload_revision_hash', NEW.candidate_workload_revision_hash,
       'case_hash', NEW.case_hash,
       'selection_role', NEW.selection_role,
       'model_name', NEW.model_name,
       'model_identity_hash', NEW.model_identity_hash,
       'job_id', NEW.job_id,
       'reason', NEW.reason
     )
     OR NEW.probe_hash IS DISTINCT FROM
       otlet.identity_hash('production_model_cancellation_probe', NEW.definition)
     OR NEW.model_name IS DISTINCT FROM expected_model ->> 'name'
     OR NEW.model_identity_hash IS DISTINCT FROM otlet.identity_hash(
       'model_identity',
       jsonb_build_object(
         'name', expected_model ->> 'name',
         'artifact_hash', expected_model ->> 'artifact_hash',
         'artifact_identity', expected_model -> 'artifact_identity'
       )
     )
     OR job.task_name IS DISTINCT FROM NEW.task_name
     OR job.workload_revision_hash IS DISTINCT FROM NEW.candidate_workload_revision_hash
     OR job.execution_mode IS DISTINCT FROM 'evaluation'
     OR job.subject_id IS DISTINCT FROM evaluation_case.subject_id
     OR job.input IS DISTINCT FROM evaluation_case.shaped_input
     OR NOT (
       (
         NEW.selection_role = 'direct'
         AND jsonb_typeof(revision_definition -> 'selection') IS DISTINCT FROM 'object'
         AND job.routed_model_name IS NULL
       ) OR (
         NEW.selection_role = 'cheap'
         AND jsonb_typeof(revision_definition -> 'selection') = 'object'
         AND job.routed_model_name IS NULL
       ) OR (
         NEW.selection_role = 'strong'
         AND jsonb_typeof(revision_definition -> 'selection') = 'object'
         AND job.routed_model_name = NEW.model_name
       )
     ) THEN
    RAISE EXCEPTION 'otlet production model cancellation probe identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER production_model_cancellation_probes_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.production_model_cancellation_probes
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER production_model_cancellation_probes_b_validate
BEFORE INSERT ON otlet.production_model_cancellation_probes
FOR EACH ROW EXECUTE FUNCTION otlet.validate_production_model_cancellation_probe();

CREATE TRIGGER production_model_cancellation_probes_truncate_guard
BEFORE TRUNCATE ON otlet.production_model_cancellation_probes
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE FUNCTION otlet.start_production_model_cancellation_probes(
  contract_hash text,
  reason text
) RETURNS TABLE (probe_hash text, selection_role text, job_id bigint)
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  contract otlet.workload_acceptance_contracts%ROWTYPE;
  candidate_definition jsonb;
  qualification_rule jsonb;
  eligible_members jsonb;
  evaluation_case otlet.evaluation_cases%ROWTYPE;
  window_starts_at timestamptz;
  window_ends_at timestamptz;
  role record;
  saved_job_id bigint;
  saved_probe_hash text;
  probe_definition jsonb;
  expected_role_count integer;
  existing_role_count integer;
  previous_append text := current_setting('otlet.evaluation_append', true);
BEGIN
  IF NULLIF(btrim(start_production_model_cancellation_probes.reason), '') IS NULL
     OR octet_length(start_production_model_cancellation_probes.reason) > 4096 THEN
    RAISE EXCEPTION 'otlet production model cancellation probe reason is required and bounded';
  END IF;
  SELECT * INTO contract
  FROM otlet.workload_acceptance_contracts stored
  WHERE stored.contract_hash = start_production_model_cancellation_probes.contract_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload acceptance contract does not exist';
  END IF;
  IF EXISTS (
    SELECT 1 FROM otlet.workload_acceptance_contracts successor
    WHERE successor.task_name = contract.task_name
      AND successor.supersedes_contract_hash = contract.contract_hash
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification contract is not current';
  END IF;
  SELECT revision.definition INTO candidate_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = contract.task_name
    AND revision.workload_revision_hash = contract.candidate_workload_revision_hash;
  qualification_rule := contract.definition #> '{population,rule,production_qualification}';
  eligible_members := contract.definition #> '{population,rule,eligible_members}';
  IF contract.definition #>> '{population,mode}' IS DISTINCT FROM 'full'
     OR NOT otlet.production_model_qualification_rule_valid(qualification_rule)
     OR NOT otlet.evaluation_slice_member_manifest_valid(eligible_members)
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(eligible_members) member
       WHERE (member ->> 'included')::boolean IS DISTINCT FROM true
          OR NOT member ? 'case_hash'
     ) THEN
    RAISE EXCEPTION 'otlet production model qualification declaration is invalid';
  END IF;
  window_starts_at := (
    contract.definition #>> '{observation_window,starts_at}'
  )::timestamptz;
  window_ends_at := (
    contract.definition #>> '{observation_window,ends_at}'
  )::timestamptz;
  IF clock_timestamp() < window_starts_at OR clock_timestamp() >= window_ends_at THEN
    RAISE EXCEPTION 'otlet production model cancellation probe is outside the observation window';
  END IF;
  SELECT stored.* INTO evaluation_case
  FROM jsonb_array_elements(eligible_members) member
  JOIN otlet.evaluation_cases stored ON stored.case_hash = member ->> 'case_hash'
  ORDER BY stored.case_hash
  LIMIT 1;
  IF evaluation_case.case_hash IS NULL
     OR evaluation_case.task_name IS DISTINCT FROM contract.task_name
     OR evaluation_case.population_kind IS DISTINCT FROM 'qualification' THEN
    RAISE EXCEPTION 'otlet production model cancellation probe case is invalid';
  END IF;

  expected_role_count := CASE
    WHEN jsonb_typeof(candidate_definition -> 'selection') = 'object' THEN 2
    ELSE 1
  END;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_production_model_cancellation:' || contract.contract_hash,
    0
  ));
  SELECT count(*)::integer INTO existing_role_count
  FROM otlet.production_model_cancellation_probes probe
  WHERE probe.contract_hash = contract.contract_hash;
  IF existing_role_count > 0 THEN
    IF existing_role_count IS DISTINCT FROM expected_role_count
       OR EXISTS (
         SELECT 1
         FROM otlet.production_model_cancellation_probes probe
         WHERE probe.contract_hash = contract.contract_hash
           AND probe.reason IS DISTINCT FROM
             btrim(start_production_model_cancellation_probes.reason)
       ) THEN
      RAISE EXCEPTION 'otlet production model cancellation probe definition conflicts';
    END IF;
    RETURN QUERY
      SELECT probe.probe_hash, probe.selection_role, probe.job_id
      FROM otlet.production_model_cancellation_probes probe
      WHERE probe.contract_hash = contract.contract_hash
      ORDER BY probe.selection_role;
    RETURN;
  END IF;

  IF octet_length(evaluation_case.shaped_input::text) > (
    SELECT policy.max_input_bytes_per_job
    FROM otlet.production_policy policy
    WHERE policy.name = 'default'
  ) THEN
    RAISE EXCEPTION 'otlet production model cancellation probe input exceeds the byte cap';
  END IF;
  PERFORM set_config('otlet.evaluation_append', 'on', true);
  FOR role IN
    SELECT model.role, model.definition
    FROM jsonb_each(candidate_definition -> 'models') model(role, definition)
    WHERE CASE
      WHEN jsonb_typeof(candidate_definition -> 'selection') = 'object'
        THEN model.role IN ('cheap', 'strong')
      ELSE model.role = 'direct'
    END
    ORDER BY model.role
  LOOP
    INSERT INTO otlet.jobs (
      task_name,
      workload_revision_hash,
      subject_id,
      input,
      execution_mode,
      routed_model_name
    ) VALUES (
      contract.task_name,
      contract.candidate_workload_revision_hash,
      evaluation_case.subject_id,
      evaluation_case.shaped_input,
      'evaluation',
      CASE WHEN role.role = 'strong' THEN role.definition ->> 'name' END
    ) RETURNING id INTO saved_job_id;

    probe_definition := jsonb_build_object(
      'format', 'otlet.production_model.cancellation_probe.v1',
      'contract_hash', contract.contract_hash,
      'task_name', contract.task_name,
      'candidate_workload_revision_hash', contract.candidate_workload_revision_hash,
      'case_hash', evaluation_case.case_hash,
      'selection_role', role.role,
      'model_name', role.definition ->> 'name',
      'model_identity_hash', otlet.identity_hash(
        'model_identity',
        jsonb_build_object(
          'name', role.definition ->> 'name',
          'artifact_hash', role.definition ->> 'artifact_hash',
          'artifact_identity', role.definition -> 'artifact_identity'
        )
      ),
      'job_id', saved_job_id,
      'reason', btrim(start_production_model_cancellation_probes.reason)
    );
    saved_probe_hash := otlet.identity_hash(
      'production_model_cancellation_probe',
      probe_definition
    );
    INSERT INTO otlet.production_model_cancellation_probes (
      probe_hash,
      contract_hash,
      task_name,
      candidate_workload_revision_hash,
      case_hash,
      selection_role,
      model_name,
      model_identity_hash,
      job_id,
      definition,
      reason,
      authenticated_role_oid,
      authenticated_role_name,
      active_role_oid,
      active_role_name
    ) VALUES (
      saved_probe_hash,
      contract.contract_hash,
      contract.task_name,
      contract.candidate_workload_revision_hash,
      evaluation_case.case_hash,
      role.role,
      role.definition ->> 'name',
      probe_definition ->> 'model_identity_hash',
      saved_job_id,
      probe_definition,
      btrim(start_production_model_cancellation_probes.reason),
      session_user::regrole::oid,
      session_user,
      current_user::regrole::oid,
      current_user
    );
  END LOOP;
  PERFORM set_config('otlet.evaluation_append', COALESCE(previous_append, ''), true);
  PERFORM otlet.wake_worker();
  RETURN QUERY
    SELECT probe.probe_hash, probe.selection_role, probe.job_id
    FROM otlet.production_model_cancellation_probes probe
    WHERE probe.contract_hash = contract.contract_hash
    ORDER BY probe.selection_role;
END;
$$;

CREATE FUNCTION otlet.record_production_model_qualification(
  contract_hash text,
  reason text,
  ticket text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
DECLARE
  contract otlet.workload_acceptance_contracts%ROWTYPE;
  candidate_definition jsonb;
  qualification_rule jsonb;
  eligible_members jsonb;
  declared_case_hashes text[];
  label_ids bigint[];
  run_hashes text[];
  report_hashes text[];
  repeat_count integer;
  case_count integer;
  report_count integer;
  expected_role_count integer;
  window_starts_at timestamptz;
  window_ends_at timestamptz;
  role_evidence jsonb;
  cancellation_evidence jsonb;
  database_evidence jsonb;
  qualification_record jsonb;
  qualification_hash text;
  existing_event_hash text;
  existing_qualification_hash text;
BEGIN
  IF NULLIF(btrim(record_production_model_qualification.reason), '') IS NULL
     OR octet_length(record_production_model_qualification.reason) > 4096
     OR octet_length(COALESCE(record_production_model_qualification.ticket, '')) > 512 THEN
    RAISE EXCEPTION 'otlet production model qualification reason is required and bounded';
  END IF;
  SELECT * INTO contract
  FROM otlet.workload_acceptance_contracts stored
  WHERE stored.contract_hash = record_production_model_qualification.contract_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload acceptance contract does not exist';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_revision:' || contract.task_name,
    0
  ));
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_production_model_qualification:' || contract.contract_hash,
    0
  ));
  IF EXISTS (
    SELECT 1 FROM otlet.workload_acceptance_contracts successor
    WHERE successor.task_name = contract.task_name
      AND successor.supersedes_contract_hash = contract.contract_hash
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification contract is not current';
  END IF;
  SELECT revision.definition INTO candidate_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = contract.task_name
    AND revision.workload_revision_hash = contract.candidate_workload_revision_hash;
  qualification_rule := contract.definition #> '{population,rule,production_qualification}';
  eligible_members := contract.definition #> '{population,rule,eligible_members}';
  IF contract.definition #>> '{population,mode}' IS DISTINCT FROM 'full'
     OR NOT otlet.production_model_qualification_rule_valid(qualification_rule)
     OR NOT otlet.evaluation_slice_member_manifest_valid(eligible_members)
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(eligible_members) member
       WHERE (member ->> 'included')::boolean IS DISTINCT FROM true
          OR NOT member ? 'case_hash'
     ) THEN
    RAISE EXCEPTION 'otlet production model qualification declaration is invalid';
  END IF;
  IF EXISTS (
    WITH expected(category, metric, statistic, unit, operator) AS (
      VALUES
        ('candidate_recall', 'quality', 'rate', 'ratio', 'gte'),
        ('false_trust', 'false_trust', 'rate', 'ratio', 'lte'),
        ('latency', 'latency_ms', 'mean', 'milliseconds', 'lte'),
        ('database_impact', 'memory_bytes', 'max', 'bytes', 'lte')
    )
    SELECT 1
    FROM expected
    WHERE contract.definition #>> ARRAY['thresholds', category, 'metric']
            IS DISTINCT FROM metric
       OR contract.definition #>> ARRAY['thresholds', category, 'statistic']
            IS DISTINCT FROM statistic
       OR contract.definition #>> ARRAY['thresholds', category, 'unit']
            IS DISTINCT FROM unit
       OR contract.definition #>> ARRAY['thresholds', category, 'operator']
            IS DISTINCT FROM operator
       OR contract.definition #> ARRAY['thresholds', category, 'required']
            IS DISTINCT FROM 'true'::jsonb
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification thresholds are invalid';
  END IF;
  window_starts_at := (
    contract.definition #>> '{observation_window,starts_at}'
  )::timestamptz;
  window_ends_at := (
    contract.definition #>> '{observation_window,ends_at}'
  )::timestamptz;
  IF clock_timestamp() < window_ends_at THEN
    RAISE EXCEPTION 'otlet production model qualification observation window is still open';
  END IF;

  SELECT
    array_agg(member ->> 'case_hash' ORDER BY member ->> 'case_hash'),
    count(*)::integer
  INTO declared_case_hashes, case_count
  FROM jsonb_array_elements(eligible_members) member;
  IF (
       SELECT count(*)
       FROM otlet.evaluation_cases evaluation_case
       WHERE evaluation_case.case_hash = ANY(declared_case_hashes)
         AND evaluation_case.task_name = contract.task_name
         AND evaluation_case.population_kind = 'qualification'
     ) IS DISTINCT FROM case_count::bigint
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(eligible_members) member
       LEFT JOIN otlet.evaluation_cases evaluation_case
         ON evaluation_case.case_hash = member ->> 'case_hash'
       WHERE evaluation_case.lineage_hash IS DISTINCT FROM member ->> 'lineage_hash'
     ) THEN
    RAISE EXCEPTION 'otlet production model qualification population is invalid';
  END IF;
  SELECT array_agg(DISTINCT evaluation_case.label_id ORDER BY evaluation_case.label_id)
  INTO label_ids
  FROM otlet.evaluation_cases evaluation_case
  WHERE evaluation_case.case_hash = ANY(declared_case_hashes);
  PERFORM otlet.lock_eval_label_series(label_ids);
  IF cardinality(label_ids) IS DISTINCT FROM case_count
     OR EXISTS (
       SELECT 1
       FROM unnest(label_ids) candidate(label_id)
       LEFT JOIN otlet.eval_label_quality_status quality
         ON quality.label_id = candidate.label_id
       WHERE quality.qualification_eligible IS DISTINCT FROM true
     ) THEN
    RAISE EXCEPTION 'otlet production model qualification label is not eligible';
  END IF;

  SELECT
    array_agg(run.run_hash ORDER BY run.run_hash),
    count(*)::integer
  INTO run_hashes, repeat_count
  FROM otlet.evaluation_runs run
  WHERE run.contract_hash = contract.contract_hash;
  IF repeat_count < 3 THEN
    RAISE EXCEPTION 'otlet production model qualification requires at least three repeats';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.evaluation_runs run
    WHERE run.contract_hash = contract.contract_hash
      AND (
        run.task_name IS DISTINCT FROM contract.task_name
        OR run.baseline_workload_revision_hash IS DISTINCT FROM
          contract.baseline_workload_revision_hash
        OR run.candidate_workload_revision_hash IS DISTINCT FROM
          contract.candidate_workload_revision_hash
        OR run.case_hashes IS DISTINCT FROM declared_case_hashes
        OR run.created_at < window_starts_at
        OR run.created_at >= window_ends_at
      )
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification repeats are not exact';
  END IF;
  SELECT
    array_agg(report.report_hash ORDER BY report.run_hash),
    count(*)::integer
  INTO report_hashes, report_count
  FROM otlet.evaluation_slice_reports report
  WHERE report.run_hash = ANY(run_hashes);
  IF report_count IS DISTINCT FROM repeat_count THEN
    RAISE EXCEPTION 'otlet production model qualification requires one report per repeat';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM unnest(run_hashes) hash(run_hash)
    WHERE (
      SELECT count(*)
      FROM otlet.evaluation_executions execution
      WHERE execution.run_hash = hash.run_hash
    ) IS DISTINCT FROM case_count::bigint * 2
  ) OR EXISTS (
    SELECT 1
    FROM otlet.evaluation_executions execution
    JOIN otlet.jobs job ON job.id = execution.job_id
    LEFT JOIN otlet.evaluation_results result
      ON result.run_hash = execution.run_hash
     AND result.case_hash = execution.case_hash
     AND result.variant = execution.variant
    LEFT JOIN LATERAL (
      SELECT receipt.id, receipt.status, receipt.selection_status,
        receipt.schema_validation_status
      FROM otlet.inference_receipts receipt
      WHERE receipt.job_id = job.id
      ORDER BY receipt.attempt_index DESC, receipt.id DESC
      LIMIT 1
    ) terminal ON true
    WHERE execution.run_hash = ANY(run_hashes)
      AND (
        job.status IS DISTINCT FROM 'complete'
        OR job.started_at IS NULL
        OR job.finished_at IS NULL
        OR job.finished_at < job.started_at
        OR result.result_hash IS NULL
        OR terminal.id IS DISTINCT FROM result.receipt_id
        OR terminal.status IS DISTINCT FROM 'complete'
        OR terminal.selection_status IS DISTINCT FROM 'accepted'
        OR terminal.schema_validation_status IS DISTINCT FROM 'passed'
      )
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification paired evidence is incomplete';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.evaluation_results result
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = result.case_hash
    WHERE result.run_hash = ANY(run_hashes)
      AND result.variant = 'candidate'
      AND (
        result.approval_diff -> 'matches_expected' IS DISTINCT FROM 'true'::jsonb
        OR result.approval_diff -> 'expected_action_present' IS DISTINCT FROM 'true'::jsonb
        OR result.approval_diff -> 'valid_action_types'
          IS DISTINCT FROM jsonb_build_array(evaluation_case.expected_action_type)
        OR result.approval_diff -> 'proposed_action_types'
          IS DISTINCT FROM jsonb_build_array(evaluation_case.expected_action_type)
      )
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification action gate failed';
  END IF;

  IF (
    SELECT count(*)
    FROM otlet.evaluation_slice_reports report
    CROSS JOIN LATERAL jsonb_array_elements(report.definition -> 'slices') slice(value)
    WHERE report.run_hash = ANY(run_hashes)
      AND slice.value ->> 'variant' = 'candidate'
      AND slice.value ->> 'slice_kind' = 'overall'
      AND slice.value -> 'slice' = '{"all": true}'::jsonb
  ) IS DISTINCT FROM repeat_count::bigint OR EXISTS (
    WITH overall AS (
      SELECT
        report.run_hash,
        slice.value -> 'metrics' AS metrics
      FROM otlet.evaluation_slice_reports report
      CROSS JOIN LATERAL jsonb_array_elements(report.definition -> 'slices') slice(value)
      WHERE report.run_hash = ANY(run_hashes)
        AND slice.value ->> 'variant' = 'candidate'
        AND slice.value ->> 'slice_kind' = 'overall'
        AND slice.value -> 'slice' = '{"all": true}'::jsonb
    ), metric AS (
      SELECT
        overall.run_hash,
        value.name,
        CASE WHEN jsonb_typeof(value.definition -> 'value') = 'number'
          THEN (value.definition ->> 'value')::numeric
        END AS value,
        CASE WHEN jsonb_typeof(value.definition -> 'support') = 'number'
          THEN (value.definition ->> 'support')::numeric
        END AS support,
        value.definition -> 'meets_minimum_support' = 'true'::jsonb
          AS meets_minimum_support
      FROM overall
      CROSS JOIN LATERAL (VALUES
        ('quality'::text, overall.metrics -> 'quality'),
        ('false_trust', overall.metrics -> 'false_trust'),
        ('latency_ms', overall.metrics -> 'latency_ms'),
        ('memory_bytes', overall.metrics -> 'memory_bytes')
      ) value(name, definition)
    )
    SELECT 1
    FROM metric
    WHERE metric.value IS NULL
       OR metric.support IS DISTINCT FROM case_count::numeric
       OR NOT metric.meets_minimum_support
       OR CASE metric.name
         WHEN 'quality' THEN metric.value < (
           contract.definition #>> '{thresholds,candidate_recall,value}'
         )::numeric
         WHEN 'false_trust' THEN metric.value > (
           contract.definition #>> '{thresholds,false_trust,value}'
         )::numeric
         WHEN 'latency_ms' THEN metric.value > (
           contract.definition #>> '{thresholds,latency,value}'
         )::numeric
         WHEN 'memory_bytes' THEN metric.value > (
           contract.definition #>> '{thresholds,database_impact,value}'
         )::numeric
         ELSE true
       END
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification repeat threshold failed';
  END IF;
  IF (
    WITH expected_slice AS (
      SELECT count(*)::bigint AS count
      FROM (
        SELECT DISTINCT 'expected_answer'::text AS kind,
          evaluation_case.expected_answer AS value
        FROM otlet.evaluation_cases evaluation_case
        WHERE evaluation_case.case_hash = ANY(declared_case_hashes)
        UNION ALL
        SELECT DISTINCT 'source_table', COALESCE(evaluation_case.source_table, '')
        FROM otlet.evaluation_cases evaluation_case
        WHERE evaluation_case.case_hash = ANY(declared_case_hashes)
      ) slice
    ), actual_slice AS (
      SELECT count(*)::bigint AS count
      FROM otlet.evaluation_slice_reports report
      CROSS JOIN LATERAL jsonb_array_elements(report.definition -> 'slices') slice(value)
      WHERE report.run_hash = ANY(run_hashes)
        AND slice.value ->> 'variant' = 'candidate'
        AND slice.value ->> 'slice_kind' IN ('expected_answer', 'source_table')
    )
    SELECT actual_slice.count = expected_slice.count * repeat_count
    FROM expected_slice, actual_slice
  ) IS DISTINCT FROM true OR EXISTS (
    WITH expected_slice AS (
      SELECT 'expected_answer'::text AS slice_kind,
        jsonb_build_object('expected_answer', evaluation_case.expected_answer) AS slice
      FROM otlet.evaluation_cases evaluation_case
      WHERE evaluation_case.case_hash = ANY(declared_case_hashes)
      GROUP BY evaluation_case.expected_answer
      UNION ALL
      SELECT 'source_table', jsonb_build_object('source_table', evaluation_case.source_table)
      FROM otlet.evaluation_cases evaluation_case
      WHERE evaluation_case.case_hash = ANY(declared_case_hashes)
      GROUP BY evaluation_case.source_table
    ), required_slice AS (
      SELECT run.run_hash, slice.slice_kind, slice.slice
      FROM unnest(run_hashes) run(run_hash)
      CROSS JOIN expected_slice slice
    )
    SELECT 1
    FROM required_slice required
    WHERE NOT EXISTS (
      SELECT 1
      FROM otlet.evaluation_slice_reports report
      CROSS JOIN LATERAL jsonb_array_elements(report.definition -> 'slices') slice(value)
      WHERE report.run_hash = required.run_hash
        AND slice.value ->> 'variant' = 'candidate'
        AND slice.value ->> 'slice_kind' = required.slice_kind
        AND slice.value -> 'slice' = required.slice
    )
  ) OR EXISTS (
    WITH slice_metric AS (
      SELECT
        report.run_hash,
        slice.value ->> 'slice_kind' AS slice_kind,
        slice.value -> 'slice' AS slice,
        CASE WHEN jsonb_typeof(slice.value -> 'case_support') = 'number'
          THEN (slice.value ->> 'case_support')::numeric
        END AS case_support,
        slice.value #> '{metrics,quality}' AS quality,
        slice.value #> '{metrics,false_trust}' AS false_trust
      FROM otlet.evaluation_slice_reports report
      CROSS JOIN LATERAL jsonb_array_elements(report.definition -> 'slices') slice(value)
      WHERE report.run_hash = ANY(run_hashes)
        AND slice.value ->> 'variant' = 'candidate'
        AND slice.value ->> 'slice_kind' IN ('expected_answer', 'source_table')
    ), metric AS (
      SELECT
        slice_metric.*,
        value.name,
        CASE WHEN jsonb_typeof(value.definition -> 'value') = 'number'
          THEN (value.definition ->> 'value')::numeric
        END AS value,
        CASE WHEN jsonb_typeof(value.definition -> 'support') = 'number'
          THEN (value.definition ->> 'support')::numeric
        END AS support,
        value.definition -> 'meets_minimum_support' = 'true'::jsonb
          AS meets_minimum_support
      FROM slice_metric
      CROSS JOIN LATERAL (VALUES
        ('quality'::text, slice_metric.quality),
        ('false_trust', slice_metric.false_trust)
      ) value(name, definition)
    )
    SELECT 1
    FROM metric
    WHERE metric.case_support IS NULL
       OR metric.value IS NULL
       OR metric.support IS DISTINCT FROM metric.case_support
       OR NOT metric.meets_minimum_support
       OR CASE metric.name
         WHEN 'quality' THEN metric.value < (
           contract.definition #>> '{thresholds,candidate_recall,value}'
         )::numeric
         WHEN 'false_trust' THEN metric.value > (
           contract.definition #>> '{thresholds,false_trust,value}'
         )::numeric
         ELSE true
       END
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification class or source gate failed';
  END IF;

  expected_role_count := CASE
    WHEN jsonb_typeof(candidate_definition -> 'selection') = 'object' THEN 2
    ELSE 1
  END;
  IF (
    WITH expected_role AS (
      SELECT model.role, model.definition
      FROM jsonb_each(candidate_definition -> 'models') model(role, definition)
      WHERE CASE
        WHEN jsonb_typeof(candidate_definition -> 'selection') = 'object'
          THEN model.role IN ('cheap', 'strong')
        ELSE model.role = 'direct'
      END
    )
    SELECT count(*)
    FROM expected_role role
    JOIN otlet.models model ON model.name = role.definition ->> 'name'
    WHERE jsonb_typeof(role.definition) = 'object'
      AND model.artifact_hash = role.definition ->> 'artifact_hash'
      AND model.artifact_identity = role.definition -> 'artifact_identity'
  ) IS DISTINCT FROM expected_role_count::bigint THEN
    RAISE EXCEPTION 'otlet production model qualification artifact is not currently registered';
  END IF;
  IF EXISTS (
    WITH expected_role AS (
      SELECT model.role, model.definition
      FROM jsonb_each(candidate_definition -> 'models') model(role, definition)
      WHERE CASE
        WHEN jsonb_typeof(candidate_definition -> 'selection') = 'object'
          THEN model.role IN ('cheap', 'strong')
        ELSE model.role = 'direct'
      END
    )
    SELECT 1
    FROM otlet.evaluation_executions execution
    JOIN otlet.inference_receipts receipt ON receipt.job_id = execution.job_id
    LEFT JOIN expected_role role ON role.role = receipt.selection_role
    WHERE execution.run_hash = ANY(run_hashes)
      AND execution.variant = 'candidate'
      AND (
        role.role IS NULL
        OR receipt.selection_status NOT IN ('accepted', 'rejected')
        OR CASE receipt.selection_status
          WHEN 'accepted' THEN receipt.status = 'complete'
          WHEN 'rejected' THEN receipt.status = 'rejected'
          ELSE false
        END IS DISTINCT FROM true
        OR receipt.schema_validation_status IS DISTINCT FROM 'passed'
        OR receipt.model_name IS DISTINCT FROM role.definition ->> 'name'
        OR receipt.model_artifact_hash IS DISTINCT FROM role.definition ->> 'artifact_hash'
        OR receipt.model_artifact_identity IS DISTINCT FROM role.definition -> 'artifact_identity'
        OR receipt.model_identity_hash IS DISTINCT FROM otlet.identity_hash(
          'model_identity',
          jsonb_build_object(
            'name', role.definition ->> 'name',
            'artifact_hash', role.definition ->> 'artifact_hash',
            'artifact_identity', role.definition -> 'artifact_identity'
          )
        )
        OR receipt.runtime_options_hash IS DISTINCT FROM otlet.portable_json_hash(
          candidate_definition #> '{runtime,effective_options}'
        )
      )
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification model identity is inconsistent';
  END IF;
  IF EXISTS (
    WITH expected_role AS (
      SELECT model.role
      FROM jsonb_each(candidate_definition -> 'models') model(role, definition)
      WHERE CASE
        WHEN jsonb_typeof(candidate_definition -> 'selection') = 'object'
          THEN model.role IN ('cheap', 'strong')
        ELSE model.role = 'direct'
      END
    ), receipt_runtime AS (
      SELECT
        receipt.selection_role,
        otlet.identity_hash(
          'production_model_runtime_identity',
          jsonb_build_object(
            'runtime_name', receipt.runtime_name,
            'runtime_endpoint', receipt.runtime_endpoint,
            'runtime_options_hash', receipt.runtime_options_hash,
            'portable_runtime_identity_hash', portable.runtime_identity_hash
          )
        ) AS runtime_identity_hash
      FROM otlet.evaluation_executions execution
      JOIN otlet.inference_receipts receipt ON receipt.job_id = execution.job_id
      LEFT JOIN LATERAL (
        SELECT claim.runtime_identity_hash
        FROM otlet.portable_receipt_links link
        JOIN otlet.portable_claims claim ON claim.id = link.claim_id
        WHERE link.receipt_id = receipt.id
        LIMIT 1
      ) portable ON true
      WHERE execution.run_hash = ANY(run_hashes)
        AND execution.variant = 'candidate'
    )
    SELECT 1
    FROM expected_role role
    LEFT JOIN receipt_runtime receipt ON receipt.selection_role = role.role
    GROUP BY role.role
    HAVING count(receipt.runtime_identity_hash) = 0
       OR count(DISTINCT receipt.runtime_identity_hash) <> 1
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification runtime identity is inconsistent';
  END IF;
  WITH expected_role AS (
    SELECT model.role, model.definition
    FROM jsonb_each(candidate_definition -> 'models') model(role, definition)
    WHERE CASE
      WHEN jsonb_typeof(candidate_definition -> 'selection') = 'object'
        THEN model.role IN ('cheap', 'strong')
      ELSE model.role = 'direct'
    END
  ), receipt_runtime AS (
    SELECT
      receipt.selection_role,
      otlet.identity_hash(
        'production_model_runtime_identity',
        jsonb_build_object(
          'runtime_name', receipt.runtime_name,
          'runtime_endpoint', receipt.runtime_endpoint,
          'runtime_options_hash', receipt.runtime_options_hash,
          'portable_runtime_identity_hash', portable.runtime_identity_hash
        )
      ) AS runtime_identity_hash
    FROM otlet.evaluation_executions execution
    JOIN otlet.inference_receipts receipt ON receipt.job_id = execution.job_id
    LEFT JOIN LATERAL (
      SELECT claim.runtime_identity_hash
      FROM otlet.portable_receipt_links link
      JOIN otlet.portable_claims claim ON claim.id = link.claim_id
      WHERE link.receipt_id = receipt.id
      LIMIT 1
    ) portable ON true
    WHERE execution.run_hash = ANY(run_hashes)
      AND execution.variant = 'candidate'
  ), role_runtime AS (
    SELECT
      receipt.selection_role,
      min(receipt.runtime_identity_hash) AS runtime_identity_hash,
      count(*)::integer AS receipt_count
    FROM receipt_runtime receipt
    GROUP BY receipt.selection_role
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'selection_role', role.role,
      'model_name', role.definition ->> 'name',
      'artifact_hash', role.definition ->> 'artifact_hash',
      'artifact_identity', role.definition -> 'artifact_identity',
      'model_identity_hash', otlet.identity_hash(
        'model_identity',
        jsonb_build_object(
          'name', role.definition ->> 'name',
          'artifact_hash', role.definition ->> 'artifact_hash',
          'artifact_identity', role.definition -> 'artifact_identity'
        )
      ),
      'runtime_identity_hash', runtime.runtime_identity_hash,
      'receipt_count', runtime.receipt_count
    ) ORDER BY role.role
  )
  INTO role_evidence
  FROM expected_role role
  JOIN role_runtime runtime ON runtime.selection_role = role.role;

  IF (
    SELECT count(*)
    FROM otlet.production_model_cancellation_probes probe
    WHERE probe.contract_hash = contract.contract_hash
  ) IS DISTINCT FROM expected_role_count::bigint OR EXISTS (
    WITH expected_role AS (
      SELECT model.role, model.definition
      FROM jsonb_each(candidate_definition -> 'models') model(role, definition)
      WHERE CASE
        WHEN jsonb_typeof(candidate_definition -> 'selection') = 'object'
          THEN model.role IN ('cheap', 'strong')
        ELSE model.role = 'direct'
      END
    ), qualified_runtime AS (
      SELECT
        role.value ->> 'selection_role' AS selection_role,
        role.value ->> 'runtime_identity_hash' AS runtime_identity_hash
      FROM jsonb_array_elements(role_evidence) role(value)
    ), probe_evidence AS (
      SELECT
        probe.*,
        job.started_at,
        job.cancel_requested_at,
        job.finished_at,
        job.status AS job_status,
        terminal.id AS receipt_id,
        terminal.status AS receipt_status,
        terminal.selection_role AS receipt_selection_role,
        terminal.selection_status,
        terminal.schema_validation_status,
        terminal.candidate_output,
        terminal.model_name AS receipt_model_name,
        terminal.model_artifact_hash,
        terminal.model_artifact_identity,
        terminal.model_identity_hash AS receipt_model_identity_hash,
        otlet.identity_hash(
          'production_model_runtime_identity',
          jsonb_build_object(
            'runtime_name', terminal.runtime_name,
            'runtime_endpoint', terminal.runtime_endpoint,
            'runtime_options_hash', terminal.runtime_options_hash,
            'portable_runtime_identity_hash', terminal.portable_runtime_identity_hash
          )
        ) AS runtime_identity_hash
      FROM otlet.production_model_cancellation_probes probe
      JOIN otlet.jobs job ON job.id = probe.job_id
      LEFT JOIN LATERAL (
        SELECT
          receipt.*,
          portable.runtime_identity_hash AS portable_runtime_identity_hash
        FROM otlet.inference_receipts receipt
        LEFT JOIN LATERAL (
          SELECT claim.runtime_identity_hash
          FROM otlet.portable_receipt_links link
          JOIN otlet.portable_claims claim ON claim.id = link.claim_id
          WHERE link.receipt_id = receipt.id
          LIMIT 1
        ) portable ON true
        WHERE receipt.job_id = job.id
        ORDER BY receipt.attempt_index DESC, receipt.id DESC
        LIMIT 1
      ) terminal ON true
      WHERE probe.contract_hash = contract.contract_hash
    )
    SELECT 1
    FROM probe_evidence probe
    LEFT JOIN expected_role role ON role.role = probe.selection_role
    LEFT JOIN qualified_runtime runtime ON runtime.selection_role = probe.selection_role
    WHERE role.role IS NULL
       OR probe.created_at < window_starts_at
       OR probe.created_at >= window_ends_at
       OR probe.job_status IS DISTINCT FROM 'canceled'
       OR probe.started_at IS NULL
       OR probe.cancel_requested_at IS NULL
       OR probe.finished_at IS NULL
       OR probe.cancel_requested_at < probe.started_at
       OR probe.finished_at < probe.cancel_requested_at
       OR EXTRACT(epoch FROM probe.finished_at - probe.cancel_requested_at) * 1000 >
         (qualification_rule #>> '{cancellation,max_ms}')::numeric
       OR probe.receipt_id IS NULL
       OR probe.receipt_status IS DISTINCT FROM 'canceled'
       OR probe.receipt_selection_role IS DISTINCT FROM probe.selection_role
       OR probe.selection_status IS DISTINCT FROM 'failed'
       OR probe.candidate_output IS NOT NULL
       OR probe.receipt_model_name IS DISTINCT FROM role.definition ->> 'name'
       OR probe.model_artifact_hash IS DISTINCT FROM role.definition ->> 'artifact_hash'
       OR probe.model_artifact_identity IS DISTINCT FROM role.definition -> 'artifact_identity'
       OR probe.receipt_model_identity_hash IS DISTINCT FROM probe.model_identity_hash
       OR probe.runtime_identity_hash IS DISTINCT FROM runtime.runtime_identity_hash
       OR EXISTS (SELECT 1 FROM otlet.outputs output WHERE output.job_id = probe.job_id)
       OR EXISTS (SELECT 1 FROM otlet.actions action WHERE action.job_id = probe.job_id)
       OR NOT EXISTS (
         SELECT 1
         FROM otlet.evaluation_executions execution
         LEFT JOIN otlet.evaluation_results result
           ON result.run_hash = execution.run_hash
          AND result.case_hash = execution.case_hash
          AND result.variant = execution.variant
         JOIN otlet.inference_receipts receipt ON receipt.job_id = execution.job_id
         LEFT JOIN otlet.outputs output ON output.id = result.output_id
         LEFT JOIN LATERAL (
           SELECT claim.runtime_identity_hash
           FROM otlet.portable_receipt_links link
           JOIN otlet.portable_claims claim ON claim.id = link.claim_id
           WHERE link.receipt_id = receipt.id
           LIMIT 1
         ) portable ON true
         WHERE execution.run_hash = ANY(run_hashes)
           AND execution.variant = 'candidate'
           AND receipt.selection_role = probe.selection_role
           AND receipt.finished_at > probe.finished_at
           AND receipt.schema_validation_status = 'passed'
           AND CASE probe.selection_role
             WHEN 'cheap' THEN
               receipt.status = 'rejected'
               AND receipt.selection_status = 'rejected'
             ELSE
               receipt.status = 'complete'
               AND receipt.selection_status = 'accepted'
               AND result.receipt_id = receipt.id
               AND output.id IS NOT NULL
           END
           AND otlet.identity_hash(
             'production_model_runtime_identity',
             jsonb_build_object(
               'runtime_name', receipt.runtime_name,
               'runtime_endpoint', receipt.runtime_endpoint,
               'runtime_options_hash', receipt.runtime_options_hash,
               'portable_runtime_identity_hash', portable.runtime_identity_hash
             )
           ) = probe.runtime_identity_hash
       )
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification cancellation gate failed';
  END IF;

  WITH qualified_runtime AS (
    SELECT
      role.value ->> 'selection_role' AS selection_role,
      role.value ->> 'runtime_identity_hash' AS runtime_identity_hash
    FROM jsonb_array_elements(role_evidence) role(value)
  ), probe_evidence AS (
    SELECT
      probe.probe_hash,
      probe.selection_role,
      probe.job_id,
      receipt.id AS receipt_id,
      EXTRACT(epoch FROM job.finished_at - job.cancel_requested_at) * 1000
        AS cancellation_ms,
      followup.receipt_id AS healthy_followup_receipt_id
    FROM otlet.production_model_cancellation_probes probe
    JOIN otlet.jobs job ON job.id = probe.job_id
    JOIN qualified_runtime runtime ON runtime.selection_role = probe.selection_role
    JOIN LATERAL (
      SELECT stored.id
      FROM otlet.inference_receipts stored
      WHERE stored.job_id = job.id
      ORDER BY stored.attempt_index DESC, stored.id DESC
      LIMIT 1
    ) receipt ON true
    JOIN LATERAL (
      SELECT stored.id AS receipt_id
      FROM otlet.evaluation_executions execution
      LEFT JOIN otlet.evaluation_results result
        ON result.run_hash = execution.run_hash
       AND result.case_hash = execution.case_hash
       AND result.variant = execution.variant
      JOIN otlet.inference_receipts stored ON stored.job_id = execution.job_id
      LEFT JOIN otlet.outputs output ON output.id = result.output_id
      LEFT JOIN LATERAL (
        SELECT claim.runtime_identity_hash
        FROM otlet.portable_receipt_links link
        JOIN otlet.portable_claims claim ON claim.id = link.claim_id
        WHERE link.receipt_id = stored.id
        LIMIT 1
      ) portable ON true
      WHERE execution.run_hash = ANY(run_hashes)
        AND execution.variant = 'candidate'
        AND stored.selection_role = probe.selection_role
        AND stored.finished_at > job.finished_at
        AND stored.schema_validation_status = 'passed'
        AND CASE probe.selection_role
          WHEN 'cheap' THEN
            stored.status = 'rejected'
            AND stored.selection_status = 'rejected'
          ELSE
            stored.status = 'complete'
            AND stored.selection_status = 'accepted'
            AND result.receipt_id = stored.id
            AND output.id IS NOT NULL
        END
        AND otlet.identity_hash(
          'production_model_runtime_identity',
          jsonb_build_object(
            'runtime_name', stored.runtime_name,
            'runtime_endpoint', stored.runtime_endpoint,
            'runtime_options_hash', stored.runtime_options_hash,
            'portable_runtime_identity_hash', portable.runtime_identity_hash
          )
        ) = runtime.runtime_identity_hash
      ORDER BY stored.finished_at, stored.id
      LIMIT 1
    ) followup ON true
    WHERE probe.contract_hash = contract.contract_hash
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'probe_hash', probe.probe_hash,
      'selection_role', probe.selection_role,
      'job_id', probe.job_id,
      'receipt_id', probe.receipt_id,
      'cancellation_ms', probe.cancellation_ms,
      'healthy_followup_receipt_id', probe.healthy_followup_receipt_id
    ) ORDER BY probe.selection_role
  ) INTO cancellation_evidence
  FROM probe_evidence probe;

  IF EXISTS (
    SELECT 1
    FROM unnest(run_hashes) hash(run_hash)
    WHERE NOT EXISTS (
      SELECT 1
      FROM otlet.production_model_database_samples sample
      WHERE sample.contract_hash = contract.contract_hash
        AND sample.run_hash = hash.run_hash
    )
  ) OR EXISTS (
    SELECT 1
    FROM otlet.production_model_database_samples sample
    JOIN otlet.jobs job ON job.id = sample.live_job_id
    WHERE sample.contract_hash = contract.contract_hash
      AND (
        sample.run_hash <> ALL(run_hashes)
        OR sample.latency_ms > (
          qualification_rule #>> '{database_responsiveness,max_ms}'
        )::numeric
        OR sample.started_at < window_starts_at
        OR sample.finished_at >= window_ends_at
        OR sample.finished_at > sample.lease_expires_at
        OR job.started_at IS NULL
        OR sample.started_at < job.started_at
        OR job.finished_at IS NULL
        OR sample.finished_at > job.finished_at
      )
  ) THEN
    RAISE EXCEPTION 'otlet production model qualification database responsiveness gate failed';
  END IF;
  WITH per_run AS (
    SELECT
      sample.run_hash,
      array_agg(sample.sample_hash ORDER BY sample.sample_hash) AS sample_hashes,
      count(*)::integer AS sample_count,
      max(sample.latency_ms) AS max_latency_ms
    FROM otlet.production_model_database_samples sample
    WHERE sample.contract_hash = contract.contract_hash
    GROUP BY sample.run_hash
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'run_hash', sample.run_hash,
      'sample_hashes', to_jsonb(sample.sample_hashes),
      'sample_count', sample.sample_count,
      'max_latency_ms', sample.max_latency_ms
    ) ORDER BY sample.run_hash
  ) INTO database_evidence
  FROM per_run sample;

  qualification_record := jsonb_strip_nulls(jsonb_build_object(
    'format', 'otlet.production_model.qualification.v1',
    'contract_hash', contract.contract_hash,
    'task_name', contract.task_name,
    'candidate_workload_revision_hash', contract.candidate_workload_revision_hash,
    'baseline_workload_revision_hash', contract.baseline_workload_revision_hash,
    'observation_window', contract.definition -> 'observation_window',
    'customer_representative', qualification_rule -> 'customer_representative',
    'run_hashes', to_jsonb(run_hashes),
    'report_hashes', to_jsonb(report_hashes),
    'repeat_count', repeat_count,
    'case_count', case_count,
    'thresholds', jsonb_build_object(
      'candidate_recall', contract.definition #> '{thresholds,candidate_recall}',
      'false_trust', contract.definition #> '{thresholds,false_trust}',
      'latency', contract.definition #> '{thresholds,latency}',
      'database_impact', contract.definition #> '{thresholds,database_impact}'
    ),
    'roles', role_evidence,
    'cancellation', jsonb_build_object(
      'max_ms', (qualification_rule #>> '{cancellation,max_ms}')::numeric,
      'probes', cancellation_evidence
    ),
    'database_responsiveness', jsonb_build_object(
      'max_ms', (qualification_rule #>> '{database_responsiveness,max_ms}')::numeric,
      'runs', database_evidence
    ),
    'reason', btrim(record_production_model_qualification.reason),
    'ticket', NULLIF(btrim(record_production_model_qualification.ticket), '')
  ));
  qualification_hash := otlet.identity_hash(
    'production_model_qualification',
    qualification_record
  );
  SELECT
    event.event_hash,
    event.definition #>> '{payload,qualification_hash}'
  INTO existing_event_hash, existing_qualification_hash
  FROM otlet.workload_acceptance_events event
  WHERE event.contract_hash = contract.contract_hash
    AND event.event_kind = 'model_qualification'
  ORDER BY event.event_order DESC
  LIMIT 1;
  IF FOUND THEN
    IF existing_qualification_hash = qualification_hash THEN
      RETURN existing_event_hash;
    END IF;
    RAISE EXCEPTION 'otlet production model qualification already has a different record';
  END IF;
  RETURN otlet.append_workload_acceptance_event(
    contract.contract_hash,
    'model_qualification',
    qualification_record || jsonb_build_object(
      'qualification_hash', qualification_hash
    )
  );
END;
$$;

CREATE VIEW otlet.production_model_qualification_status AS
WITH qualification AS (
  SELECT
    event.*,
    event.definition -> 'payload' AS payload,
    NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_events later
      WHERE later.contract_hash = event.contract_hash
        AND later.event_kind = 'model_qualification'
        AND later.event_order > event.event_order
    ) AS latest_qualification
  FROM otlet.workload_acceptance_events event
  WHERE event.event_kind = 'model_qualification'
)
SELECT
  qualification.event_hash AS qualification_event_hash,
  qualification.payload ->> 'qualification_hash' AS qualification_hash,
  qualification.contract_hash,
  qualification.task_name,
  qualification.payload ->> 'candidate_workload_revision_hash'
    AS candidate_workload_revision_hash,
  role.value ->> 'selection_role' AS selection_role,
  role.value ->> 'model_name' AS model_name,
  role.value ->> 'artifact_hash' AS artifact_hash,
  role.value -> 'artifact_identity' AS artifact_identity,
  role.value ->> 'model_identity_hash' AS model_identity_hash,
  role.value ->> 'runtime_identity_hash' AS runtime_identity_hash,
  (role.value ->> 'receipt_count')::integer AS receipt_count,
  (qualification.payload ->> 'repeat_count')::integer AS repeat_count,
  (qualification.payload ->> 'case_count')::integer AS case_count,
  qualification.payload -> 'customer_representative' AS customer_representative,
  qualification.payload -> 'thresholds' AS thresholds,
  qualification.payload -> 'cancellation' AS cancellation,
  qualification.payload -> 'database_responsiveness' AS database_responsiveness,
  qualification.latest_qualification,
  qualification.latest_qualification
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_contracts successor
      WHERE successor.task_name = qualification.task_name
        AND successor.supersedes_contract_hash = qualification.contract_hash
    )
    AND (
      SELECT count(*)
      FROM jsonb_array_elements_text(qualification.payload -> 'run_hashes') hash(value)
      JOIN otlet.evaluation_runs run ON run.run_hash = hash.value
      WHERE run.contract_hash = qualification.contract_hash
    ) = jsonb_array_length(qualification.payload -> 'run_hashes')
    AND NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(qualification.payload -> 'run_hashes') hash(value)
      JOIN otlet.evaluation_runs run ON run.run_hash = hash.value
      JOIN otlet.evaluation_cases evaluation_case
        ON evaluation_case.case_hash = ANY(run.case_hashes)
      LEFT JOIN otlet.eval_label_quality_status quality
        ON quality.label_id = evaluation_case.label_id
      WHERE quality.qualification_eligible IS DISTINCT FROM true
    )
    AND EXISTS (
      SELECT 1
      FROM otlet.models model
      WHERE model.name = role.value ->> 'model_name'
        AND model.artifact_hash = role.value ->> 'artifact_hash'
        AND model.artifact_identity = role.value -> 'artifact_identity'
        AND otlet.identity_hash(
          'model_identity',
          jsonb_build_object(
            'name', model.name,
            'artifact_hash', model.artifact_hash,
            'artifact_identity', model.artifact_identity
          )
        ) = role.value ->> 'model_identity_hash'
    ) AS production_approved,
  qualification.authenticated_role_name AS recorded_by,
  qualification.active_role_name AS recorded_as,
  qualification.payload ->> 'reason' AS reason,
  qualification.payload ->> 'ticket' AS ticket,
  qualification.created_at
FROM qualification
CROSS JOIN LATERAL jsonb_array_elements(qualification.payload -> 'roles') role(value);

REVOKE ALL ON TABLE otlet.production_model_database_samples FROM PUBLIC;
REVOKE ALL ON TABLE otlet.production_model_cancellation_probes FROM PUBLIC;
REVOKE ALL ON TABLE otlet.production_model_qualification_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.production_model_qualification_rule_valid(jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_production_model_database_sample()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_production_model_database_sample(text, text)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_production_model_cancellation_probe()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.start_production_model_cancellation_probes(text, text)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_production_model_qualification(text, text, text)
FROM PUBLIC;
