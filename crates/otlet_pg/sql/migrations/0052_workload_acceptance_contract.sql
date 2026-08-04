CREATE FUNCTION otlet.workload_acceptance_contract_error(definition jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  required_thresholds constant text[] := ARRAY[
    'candidate_recall',
    'false_trust',
    'abstention',
    'review_age',
    'review_minutes',
    'freshness',
    'latency',
    'database_impact',
    'unit_cost',
    'recovery',
    'downstream_outcome'
  ];
  threshold_name text;
  threshold jsonb;
  json_depth integer;
  json_nodes bigint;
BEGIN
  IF jsonb_typeof(workload_acceptance_contract_error.definition) IS DISTINCT FROM 'object' THEN
    RETURN 'definition must be a JSON object';
  END IF;
  IF octet_length(workload_acceptance_contract_error.definition::text) > 262144 THEN
    RETURN 'definition exceeds 262144 bytes';
  END IF;
  SELECT complexity.json_depth, complexity.json_nodes
  INTO json_depth, json_nodes
  FROM otlet.bounded_jsonb_complexity(
    workload_acceptance_contract_error.definition,
    16,
    4096
  ) complexity;
  IF json_depth > 16 THEN
    RETURN 'definition exceeds JSON depth 16';
  END IF;
  IF json_nodes > 4096 THEN
    RETURN 'definition exceeds 4096 JSON nodes';
  END IF;
  IF workload_acceptance_contract_error.definition ->> 'format'
       IS DISTINCT FROM 'otlet.workload_acceptance.v1' THEN
    RETURN 'format must be otlet.workload_acceptance.v1';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_object_keys(workload_acceptance_contract_error.definition) key
    WHERE key <> ALL(ARRAY[
      'format',
      'task_name',
      'candidate_workload_revision_hash',
      'baseline_workload_revision_hash',
      'population',
      'observation_window',
      'baseline',
      'thresholds',
      'supersedes_contract_hash'
    ])
  ) THEN
    RETURN 'definition contains an unsupported field';
  END IF;
  IF COALESCE(workload_acceptance_contract_error.definition ->> 'task_name', '')
       !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RETURN 'task_name is invalid';
  END IF;
  IF COALESCE(
       workload_acceptance_contract_error.definition ->> 'candidate_workload_revision_hash',
       ''
     )
       !~ '^otlet:v1:sha256:[0-9a-f]{64}$' THEN
    RETURN 'candidate workload revision hash is invalid';
  END IF;
  IF COALESCE(
       workload_acceptance_contract_error.definition ->> 'baseline_workload_revision_hash',
       ''
     )
       !~ '^otlet:v1:sha256:[0-9a-f]{64}$' THEN
    RETURN 'baseline workload revision hash is invalid';
  END IF;
  IF jsonb_typeof(
       workload_acceptance_contract_error.definition -> 'supersedes_contract_hash'
     ) IS DISTINCT FROM 'null'
     AND COALESCE(
       workload_acceptance_contract_error.definition ->> 'supersedes_contract_hash',
       ''
     )
       !~ '^otlet:v1:sha256:[0-9a-f]{64}$' THEN
    RETURN 'supersedes contract hash is invalid';
  END IF;

  IF jsonb_typeof(workload_acceptance_contract_error.definition -> 'population')
       IS DISTINCT FROM 'object' THEN
    RETURN 'population must be a JSON object';
  END IF;
  IF COALESCE(workload_acceptance_contract_error.definition #>> '{population,mode}', '')
       NOT IN ('full', 'sample') THEN
    RETURN 'population mode must be full or sample';
  END IF;
  IF jsonb_typeof(workload_acceptance_contract_error.definition #> '{population,rule}')
       IS DISTINCT FROM 'object'
     OR workload_acceptance_contract_error.definition #> '{population,rule}' = '{}'::jsonb THEN
    RETURN 'population rule must be a non-empty JSON object';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_object_keys(workload_acceptance_contract_error.definition -> 'population') key
    WHERE key <> ALL(ARRAY['mode', 'rule'])
  ) THEN
    RETURN 'population contains an unsupported field';
  END IF;

  IF jsonb_typeof(workload_acceptance_contract_error.definition -> 'observation_window')
       IS DISTINCT FROM 'object' THEN
    RETURN 'observation_window must be a JSON object';
  END IF;
  IF COALESCE(
       workload_acceptance_contract_error.definition #>> '{observation_window,starts_at}',
       ''
     )
       !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{6}Z$'
     OR COALESCE(
       workload_acceptance_contract_error.definition #>> '{observation_window,ends_at}',
       ''
     )
       !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{6}Z$' THEN
    RETURN 'observation window timestamps must be canonical UTC timestamps';
  END IF;
  IF (workload_acceptance_contract_error.definition #>> '{observation_window,starts_at}')::timestamptz
       >= (workload_acceptance_contract_error.definition #>> '{observation_window,ends_at}')::timestamptz THEN
    RETURN 'observation window end must be after start';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_object_keys(
      workload_acceptance_contract_error.definition -> 'observation_window'
    ) key
    WHERE key <> ALL(ARRAY['starts_at', 'ends_at'])
  ) THEN
    RETURN 'observation_window contains an unsupported field';
  END IF;

  IF jsonb_typeof(workload_acceptance_contract_error.definition -> 'baseline')
       IS DISTINCT FROM 'object'
     OR NULLIF(btrim(
       workload_acceptance_contract_error.definition #>> '{baseline,name}'
     ), '') IS NULL
     OR octet_length(workload_acceptance_contract_error.definition #>> '{baseline,name}') > 256
     OR jsonb_typeof(workload_acceptance_contract_error.definition #> '{baseline,definition}')
       IS DISTINCT FROM 'object'
     OR workload_acceptance_contract_error.definition #> '{baseline,definition}' = '{}'::jsonb THEN
    RETURN 'baseline must contain a bounded name and non-empty definition object';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_object_keys(workload_acceptance_contract_error.definition -> 'baseline') key
    WHERE key <> ALL(ARRAY['name', 'definition'])
  ) THEN
    RETURN 'baseline contains an unsupported field';
  END IF;

  IF jsonb_typeof(workload_acceptance_contract_error.definition -> 'thresholds')
       IS DISTINCT FROM 'object' THEN
    RETURN 'thresholds must be a JSON object';
  END IF;
  IF ARRAY(
    SELECT key
    FROM jsonb_object_keys(workload_acceptance_contract_error.definition -> 'thresholds') key
    ORDER BY key
  ) IS DISTINCT FROM ARRAY(
    SELECT key
    FROM unnest(required_thresholds) key
    ORDER BY key
  ) THEN
    RETURN 'thresholds must contain exactly the 11 required acceptance categories';
  END IF;

  FOREACH threshold_name IN ARRAY required_thresholds LOOP
    threshold := workload_acceptance_contract_error.definition
      #> ARRAY['thresholds', threshold_name];
    IF jsonb_typeof(threshold) IS DISTINCT FROM 'object' THEN
      RETURN format('threshold %s must be a JSON object', threshold_name);
    END IF;
    IF ARRAY(
      SELECT key FROM jsonb_object_keys(threshold) key ORDER BY key
    ) IS DISTINCT FROM ARRAY[
      'metric', 'minimum_support', 'operator', 'required', 'statistic', 'unit', 'value'
    ]::text[] THEN
      RETURN format('threshold %s has an invalid shape', threshold_name);
    END IF;
    IF COALESCE(threshold ->> 'metric', '') !~ '^[a-z][a-z0-9_]{0,63}$'
       OR COALESCE(threshold ->> 'statistic', '') !~ '^[a-z][a-z0-9_]{0,63}$' THEN
      RETURN format('threshold %s metric or statistic is invalid', threshold_name);
    END IF;
    IF COALESCE(threshold ->> 'operator', '') NOT IN ('gte', 'lte') THEN
      RETURN format('threshold %s operator must be gte or lte', threshold_name);
    END IF;
    IF jsonb_typeof(threshold -> 'value') IS DISTINCT FROM 'number'
       OR (threshold ->> 'value')::numeric < 0 THEN
      RETURN format('threshold %s value must be a non-negative number', threshold_name);
    END IF;
    IF jsonb_typeof(threshold -> 'minimum_support') IS DISTINCT FROM 'number'
       OR threshold ->> 'minimum_support' !~ '^(0|[1-9][0-9]{0,9})$'
       OR (threshold ->> 'minimum_support')::numeric > 2147483647 THEN
      RETURN format('threshold %s minimum_support must be a bounded integer', threshold_name);
    END IF;
    IF jsonb_typeof(threshold -> 'required') IS DISTINCT FROM 'boolean' THEN
      RETURN format('threshold %s required must be boolean', threshold_name);
    END IF;
    IF jsonb_typeof(threshold -> 'unit') IS DISTINCT FROM 'string'
       OR NULLIF(btrim(threshold ->> 'unit'), '') IS NULL
       OR octet_length(threshold ->> 'unit') > 64 THEN
      RETURN format('threshold %s unit is invalid', threshold_name);
    END IF;
    IF threshold ->> 'unit' = 'ratio' AND (threshold ->> 'value')::numeric > 1 THEN
      RETURN format('threshold %s ratio cannot exceed 1', threshold_name);
    END IF;
  END LOOP;

  RETURN NULL;
EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
  RETURN 'observation window timestamps are invalid';
END;
$$;

CREATE TABLE otlet.workload_acceptance_contracts (
  contract_hash text PRIMARY KEY CHECK (
    contract_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  candidate_workload_revision_hash text NOT NULL,
  baseline_workload_revision_hash text NOT NULL,
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  supersedes_contract_hash text REFERENCES otlet.workload_acceptance_contracts(contract_hash),
  authenticated_role_oid oid NOT NULL,
  authenticated_role_name text NOT NULL CHECK (
    NULLIF(btrim(authenticated_role_name), '') IS NOT NULL
  ),
  active_role_oid oid NOT NULL,
  active_role_name text NOT NULL CHECK (
    NULLIF(btrim(active_role_name), '') IS NOT NULL
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (task_name, contract_hash),
  FOREIGN KEY (task_name, candidate_workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  FOREIGN KEY (task_name, baseline_workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  CHECK (supersedes_contract_hash IS DISTINCT FROM contract_hash)
);

CREATE UNIQUE INDEX workload_acceptance_contracts_one_root_idx
ON otlet.workload_acceptance_contracts (task_name)
WHERE supersedes_contract_hash IS NULL;

CREATE UNIQUE INDEX workload_acceptance_contracts_one_successor_idx
ON otlet.workload_acceptance_contracts (task_name, supersedes_contract_hash)
WHERE supersedes_contract_hash IS NOT NULL;

CREATE TABLE otlet.workload_acceptance_events (
  event_hash text PRIMARY KEY CHECK (
    event_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  contract_hash text NOT NULL REFERENCES otlet.workload_acceptance_contracts(contract_hash),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  event_kind text NOT NULL CHECK (event_kind IN ('exception', 'promotion_decision')),
  event_order bigint NOT NULL CHECK (event_order > 0),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  supersedes_event_hash text REFERENCES otlet.workload_acceptance_events(event_hash),
  authenticated_role_oid oid NOT NULL,
  authenticated_role_name text NOT NULL CHECK (
    NULLIF(btrim(authenticated_role_name), '') IS NOT NULL
  ),
  active_role_oid oid NOT NULL,
  active_role_name text NOT NULL CHECK (
    NULLIF(btrim(active_role_name), '') IS NOT NULL
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (task_name, contract_hash)
    REFERENCES otlet.workload_acceptance_contracts(task_name, contract_hash),
  UNIQUE (contract_hash, event_order),
  CHECK (supersedes_event_hash IS DISTINCT FROM event_hash)
);

CREATE UNIQUE INDEX workload_acceptance_events_one_root_idx
ON otlet.workload_acceptance_events (contract_hash)
WHERE supersedes_event_hash IS NULL;

CREATE UNIQUE INDEX workload_acceptance_events_one_successor_idx
ON otlet.workload_acceptance_events (contract_hash, supersedes_event_hash)
WHERE supersedes_event_hash IS NOT NULL;

CREATE FUNCTION otlet.guard_workload_acceptance_append() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT'
     AND current_setting('otlet.workload_acceptance_append', true) = 'on' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'otlet workload acceptance evidence is append only';
END;
$$;

CREATE FUNCTION otlet.validate_workload_acceptance_contract() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  validation_error text;
BEGIN
  validation_error := otlet.workload_acceptance_contract_error(NEW.definition);
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet workload acceptance contract is invalid: %', validation_error;
  END IF;
  IF NEW.task_name IS DISTINCT FROM NEW.definition ->> 'task_name'
     OR NEW.candidate_workload_revision_hash IS DISTINCT FROM
       NEW.definition ->> 'candidate_workload_revision_hash'
     OR NEW.baseline_workload_revision_hash IS DISTINCT FROM
       NEW.definition ->> 'baseline_workload_revision_hash'
     OR NEW.supersedes_contract_hash IS DISTINCT FROM
       NULLIF(NEW.definition ->> 'supersedes_contract_hash', '')
     OR NEW.contract_hash IS DISTINCT FROM
       otlet.identity_hash('workload_acceptance_contract', NEW.definition) THEN
    RAISE EXCEPTION 'otlet workload acceptance contract identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION otlet.validate_workload_acceptance_event() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  expected_hash text;
BEGIN
  IF NEW.definition ->> 'format' IS DISTINCT FROM 'otlet.workload_acceptance.event.v1'
     OR NEW.definition ->> 'event_kind' IS DISTINCT FROM NEW.event_kind
     OR NEW.definition ->> 'contract_hash' IS DISTINCT FROM NEW.contract_hash
     OR NEW.definition ->> 'event_order' IS DISTINCT FROM NEW.event_order::text
     OR NEW.supersedes_event_hash IS DISTINCT FROM
       NULLIF(NEW.definition ->> 'supersedes_event_hash', '')
     OR octet_length(NEW.definition::text) > 65536 THEN
    RAISE EXCEPTION 'otlet workload acceptance event identity is invalid';
  END IF;
  expected_hash := otlet.identity_hash(
    'workload_acceptance_event',
    jsonb_build_object(
      'definition', NEW.definition,
      'authenticated_role_oid', NEW.authenticated_role_oid::text,
      'active_role_oid', NEW.active_role_oid::text,
      'created_at_epoch', EXTRACT(epoch FROM NEW.created_at)
    )
  );
  IF NEW.event_hash IS DISTINCT FROM expected_hash THEN
    RAISE EXCEPTION 'otlet workload acceptance event hash is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_acceptance_contracts_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.workload_acceptance_contracts
FOR EACH ROW EXECUTE FUNCTION otlet.guard_workload_acceptance_append();

CREATE TRIGGER workload_acceptance_contracts_b_validate
BEFORE INSERT ON otlet.workload_acceptance_contracts
FOR EACH ROW EXECUTE FUNCTION otlet.validate_workload_acceptance_contract();

CREATE TRIGGER workload_acceptance_contracts_truncate_guard
BEFORE TRUNCATE ON otlet.workload_acceptance_contracts
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_workload_acceptance_append();

CREATE TRIGGER workload_acceptance_events_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.workload_acceptance_events
FOR EACH ROW EXECUTE FUNCTION otlet.guard_workload_acceptance_append();

CREATE TRIGGER workload_acceptance_events_b_validate
BEFORE INSERT ON otlet.workload_acceptance_events
FOR EACH ROW EXECUTE FUNCTION otlet.validate_workload_acceptance_event();

CREATE TRIGGER workload_acceptance_events_truncate_guard
BEFORE TRUNCATE ON otlet.workload_acceptance_events
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_workload_acceptance_append();

CREATE FUNCTION otlet.register_workload_acceptance_contract(
  task_name text,
  candidate_workload_revision_hash text,
  baseline_workload_revision_hash text,
  population jsonb,
  observation_starts_at timestamptz,
  observation_ends_at timestamptz,
  baseline jsonb,
  thresholds jsonb,
  expected_current_contract_hash text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
DECLARE
  new_definition jsonb;
  new_contract_hash text;
  current_contract_hash text;
  validation_error text;
  previous_append text := current_setting('otlet.workload_acceptance_append', true);
  authenticated_oid oid := session_user::regrole::oid;
  active_oid oid := current_user::regrole::oid;
BEGIN
  new_definition := jsonb_build_object(
    'format', 'otlet.workload_acceptance.v1',
    'task_name', register_workload_acceptance_contract.task_name,
    'candidate_workload_revision_hash',
      register_workload_acceptance_contract.candidate_workload_revision_hash,
    'baseline_workload_revision_hash',
      register_workload_acceptance_contract.baseline_workload_revision_hash,
    'population', register_workload_acceptance_contract.population,
    'observation_window', jsonb_build_object(
      'starts_at', to_char(
        register_workload_acceptance_contract.observation_starts_at AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
      ),
      'ends_at', to_char(
        register_workload_acceptance_contract.observation_ends_at AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
      )
    ),
    'baseline', register_workload_acceptance_contract.baseline,
    'thresholds', register_workload_acceptance_contract.thresholds,
    'supersedes_contract_hash',
      to_jsonb(register_workload_acceptance_contract.expected_current_contract_hash)
  );
  validation_error := otlet.workload_acceptance_contract_error(new_definition);
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet workload acceptance contract is invalid: %', validation_error;
  END IF;
  new_contract_hash := otlet.identity_hash('workload_acceptance_contract', new_definition);

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'otlet_workload_acceptance:' || register_workload_acceptance_contract.task_name,
      0
    )
  );
  PERFORM 1
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = register_workload_acceptance_contract.task_name
    AND revision.workload_revision_hash IN (
      register_workload_acceptance_contract.candidate_workload_revision_hash,
      register_workload_acceptance_contract.baseline_workload_revision_hash
    )
  GROUP BY revision.task_name
  HAVING count(DISTINCT revision.workload_revision_hash) =
    CASE
      WHEN register_workload_acceptance_contract.candidate_workload_revision_hash =
        register_workload_acceptance_contract.baseline_workload_revision_hash THEN 1
      ELSE 2
    END;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet acceptance candidate and baseline revisions must belong to task %',
      register_workload_acceptance_contract.task_name;
  END IF;

  SELECT contract.contract_hash
  INTO current_contract_hash
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.task_name = register_workload_acceptance_contract.task_name
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_contracts successor
      WHERE successor.task_name = contract.task_name
        AND successor.supersedes_contract_hash = contract.contract_hash
    );
  IF current_contract_hash IS NOT DISTINCT FROM new_contract_hash THEN
    RETURN new_contract_hash;
  END IF;
  IF current_contract_hash IS DISTINCT FROM
       register_workload_acceptance_contract.expected_current_contract_hash THEN
    RAISE EXCEPTION 'otlet workload acceptance contract version conflict for task %',
      register_workload_acceptance_contract.task_name;
  END IF;
  IF register_workload_acceptance_contract.observation_starts_at < clock_timestamp() THEN
    RAISE EXCEPTION 'otlet workload acceptance contract must be registered before its observation window';
  END IF;

  PERFORM set_config('otlet.workload_acceptance_append', 'on', true);
  INSERT INTO otlet.workload_acceptance_contracts (
    contract_hash,
    task_name,
    candidate_workload_revision_hash,
    baseline_workload_revision_hash,
    definition,
    supersedes_contract_hash,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name
  ) VALUES (
    new_contract_hash,
    register_workload_acceptance_contract.task_name,
    register_workload_acceptance_contract.candidate_workload_revision_hash,
    register_workload_acceptance_contract.baseline_workload_revision_hash,
    new_definition,
    register_workload_acceptance_contract.expected_current_contract_hash,
    authenticated_oid,
    session_user,
    active_oid,
    current_user
  );
  PERFORM set_config(
    'otlet.workload_acceptance_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN new_contract_hash;
END;
$$;

CREATE FUNCTION otlet.append_workload_acceptance_event(
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
  IF append_workload_acceptance_event.event_kind NOT IN ('exception', 'promotion_decision') THEN
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

CREATE FUNCTION otlet.record_workload_acceptance_exception(
  contract_hash text,
  threshold_name text,
  override jsonb,
  scope jsonb,
  reason text,
  ticket text DEFAULT NULL,
  expires_at timestamptz DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
DECLARE
  contract_definition jsonb;
BEGIN
  SELECT contract.definition
  INTO contract_definition
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.contract_hash = record_workload_acceptance_exception.contract_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload acceptance contract does not exist';
  END IF;
  IF NOT contract_definition #> ARRAY[
       'thresholds', record_workload_acceptance_exception.threshold_name
     ] IS NOT NULL THEN
    RAISE EXCEPTION 'otlet workload acceptance threshold % does not exist',
      record_workload_acceptance_exception.threshold_name;
  END IF;
  IF jsonb_typeof(record_workload_acceptance_exception.override) IS DISTINCT FROM 'object'
     OR record_workload_acceptance_exception.override = '{}'::jsonb
     OR jsonb_typeof(record_workload_acceptance_exception.scope) IS DISTINCT FROM 'object'
     OR NULLIF(btrim(record_workload_acceptance_exception.reason), '') IS NULL
     OR octet_length(record_workload_acceptance_exception.reason) > 4096
     OR octet_length(COALESCE(record_workload_acceptance_exception.ticket, '')) > 512
     OR record_workload_acceptance_exception.expires_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'otlet workload acceptance exception is invalid';
  END IF;
  RETURN otlet.append_workload_acceptance_event(
    record_workload_acceptance_exception.contract_hash,
    'exception',
    jsonb_strip_nulls(jsonb_build_object(
      'threshold_name', record_workload_acceptance_exception.threshold_name,
      'override', record_workload_acceptance_exception.override,
      'scope', record_workload_acceptance_exception.scope,
      'reason', btrim(record_workload_acceptance_exception.reason),
      'ticket', NULLIF(btrim(record_workload_acceptance_exception.ticket), ''),
      'expires_at', CASE
        WHEN record_workload_acceptance_exception.expires_at IS NULL THEN NULL
        ELSE to_char(
          record_workload_acceptance_exception.expires_at AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        )
      END
    ))
  );
END;
$$;

CREATE FUNCTION otlet.record_workload_promotion_decision(
  contract_hash text,
  outcome text,
  evidence_hash text,
  evidence_summary jsonb,
  reason text,
  exception_hashes text[] DEFAULT ARRAY[]::text[],
  ticket text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  contract_definition jsonb;
  normalized_exception_hashes text[];
BEGIN
  SELECT contract.definition
  INTO contract_definition
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.contract_hash = record_workload_promotion_decision.contract_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload acceptance contract does not exist';
  END IF;
  IF COALESCE(record_workload_promotion_decision.outcome, '')
       NOT IN ('promote', 'reject', 'defer')
     OR COALESCE(record_workload_promotion_decision.evidence_hash, '')
       !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
     OR jsonb_typeof(record_workload_promotion_decision.evidence_summary)
       IS DISTINCT FROM 'object'
     OR record_workload_promotion_decision.evidence_summary = '{}'::jsonb
     OR octet_length(record_workload_promotion_decision.evidence_summary::text) > 32768
     OR NULLIF(btrim(record_workload_promotion_decision.reason), '') IS NULL
     OR octet_length(record_workload_promotion_decision.reason) > 4096
     OR octet_length(COALESCE(record_workload_promotion_decision.ticket, '')) > 512 THEN
    RAISE EXCEPTION 'otlet workload promotion decision is invalid';
  END IF;
  SELECT COALESCE(array_agg(DISTINCT hash ORDER BY hash), ARRAY[]::text[])
  INTO normalized_exception_hashes
  FROM unnest(COALESCE(
    record_workload_promotion_decision.exception_hashes,
    ARRAY[]::text[]
  )) hash;
  IF EXISTS (
    SELECT 1
    FROM unnest(normalized_exception_hashes) hash
    WHERE NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_events event
      WHERE event.event_hash = hash
        AND event.contract_hash = record_workload_promotion_decision.contract_hash
        AND event.event_kind = 'exception'
        AND (
          event.definition #>> '{payload,expires_at}' IS NULL
          OR (event.definition #>> '{payload,expires_at}')::timestamptz > clock_timestamp()
        )
    )
  ) THEN
    RAISE EXCEPTION 'otlet workload promotion decision references an invalid exception';
  END IF;
  RETURN otlet.append_workload_acceptance_event(
    record_workload_promotion_decision.contract_hash,
    'promotion_decision',
    jsonb_strip_nulls(jsonb_build_object(
      'candidate_workload_revision_hash',
        contract_definition ->> 'candidate_workload_revision_hash',
      'baseline_workload_revision_hash',
        contract_definition ->> 'baseline_workload_revision_hash',
      'outcome', record_workload_promotion_decision.outcome,
      'evidence_hash', record_workload_promotion_decision.evidence_hash,
      'evidence_summary', record_workload_promotion_decision.evidence_summary,
      'exception_hashes', to_jsonb(normalized_exception_hashes),
      'reason', btrim(record_workload_promotion_decision.reason),
      'ticket', NULLIF(btrim(record_workload_promotion_decision.ticket), '')
    ))
  );
END;
$$;

CREATE FUNCTION otlet.current_workload_acceptance_contract(task_name text)
RETURNS TABLE (contract_hash text, definition jsonb)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT contract.contract_hash, contract.definition
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.task_name = current_workload_acceptance_contract.task_name
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_contracts successor
      WHERE successor.task_name = contract.task_name
        AND successor.supersedes_contract_hash = contract.contract_hash
    )
$$;

CREATE VIEW otlet.workload_acceptance_status AS
SELECT
  contract.contract_hash,
  contract.task_name,
  contract.candidate_workload_revision_hash,
  contract.baseline_workload_revision_hash,
  contract.supersedes_contract_hash,
  NOT EXISTS (
    SELECT 1
    FROM otlet.workload_acceptance_contracts successor
    WHERE successor.task_name = contract.task_name
      AND successor.supersedes_contract_hash = contract.contract_hash
  ) AS current,
  contract.definition -> 'population' AS population,
  contract.definition -> 'observation_window' AS observation_window,
  contract.definition -> 'baseline' AS baseline,
  contract.definition -> 'thresholds' AS thresholds,
  11::integer AS threshold_categories,
  count(event.event_hash) FILTER (WHERE event.event_kind = 'exception')::bigint AS exceptions,
  count(event.event_hash) FILTER (WHERE event.event_kind = 'promotion_decision')::bigint
    AS promotion_decisions,
  latest.event_hash AS latest_event_hash,
  latest.event_kind AS latest_event_kind,
  latest_promotion.outcome AS latest_promotion_outcome,
  contract.authenticated_role_name AS registered_by,
  contract.active_role_name AS registered_as,
  contract.created_at
FROM otlet.workload_acceptance_contracts contract
LEFT JOIN otlet.workload_acceptance_events event
  ON event.contract_hash = contract.contract_hash
LEFT JOIN LATERAL (
  SELECT candidate.event_hash, candidate.event_kind
  FROM otlet.workload_acceptance_events candidate
  WHERE candidate.contract_hash = contract.contract_hash
  ORDER BY candidate.event_order DESC
  LIMIT 1
) latest ON true
LEFT JOIN LATERAL (
  SELECT candidate.definition #>> '{payload,outcome}' AS outcome
  FROM otlet.workload_acceptance_events candidate
  WHERE candidate.contract_hash = contract.contract_hash
    AND candidate.event_kind = 'promotion_decision'
  ORDER BY candidate.event_order DESC
  LIMIT 1
) latest_promotion ON true
GROUP BY
  contract.contract_hash,
  contract.task_name,
  contract.candidate_workload_revision_hash,
  contract.baseline_workload_revision_hash,
  contract.supersedes_contract_hash,
  contract.definition,
  contract.authenticated_role_name,
  contract.active_role_name,
  contract.created_at,
  latest.event_hash,
  latest.event_kind,
  latest_promotion.outcome;

CREATE VIEW otlet.audit_workload_acceptance_event_export AS
SELECT
  event.event_hash,
  event.contract_hash,
  event.task_name,
  event.event_kind,
  event.event_order,
  event.supersedes_event_hash,
  event.definition -> 'payload' AS decision,
  event.authenticated_role_oid,
  event.authenticated_role_name,
  event.active_role_oid,
  event.active_role_name,
  event.created_at
FROM otlet.workload_acceptance_events event;

REVOKE ALL ON TABLE otlet.workload_acceptance_contracts FROM PUBLIC;
REVOKE ALL ON TABLE otlet.workload_acceptance_events FROM PUBLIC;
REVOKE ALL ON TABLE otlet.workload_acceptance_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.audit_workload_acceptance_event_export FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.workload_acceptance_contract_error(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_workload_acceptance_append() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_workload_acceptance_contract() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_workload_acceptance_event() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.register_workload_acceptance_contract(
  text, text, text, jsonb, timestamptz, timestamptz, jsonb, jsonb, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.append_workload_acceptance_event(text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_workload_acceptance_exception(
  text, text, jsonb, jsonb, text, text, timestamptz
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_workload_promotion_decision(
  text, text, text, jsonb, text, text[], text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.current_workload_acceptance_contract(text) FROM PUBLIC;
