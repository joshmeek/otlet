CREATE FUNCTION otlet.model_lifecycle_revision(
  model_name text,
  lifecycle_state text,
  replacement_model_name text
) RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT otlet.identity_hash(
    'model_lifecycle',
    jsonb_build_object(
      'format', 'otlet.model_lifecycle.v1',
      'model_name', $1,
      'lifecycle_state', $2,
      'replacement_model_name', to_jsonb($3)
    )
  );
$$;

ALTER TABLE otlet.models
ADD COLUMN lifecycle_state text NOT NULL DEFAULT 'active',
ADD COLUMN replacement_model_name text,
ADD COLUMN lifecycle_revision_hash text;

UPDATE otlet.models model
SET lifecycle_revision_hash = otlet.model_lifecycle_revision(
  model.name,
  model.lifecycle_state,
  model.replacement_model_name
);

ALTER TABLE otlet.models
ALTER COLUMN lifecycle_revision_hash SET NOT NULL,
ADD CONSTRAINT models_lifecycle_state_check CHECK (
  lifecycle_state IN ('active', 'deprecated', 'draining', 'disabled')
),
ADD CONSTRAINT models_replacement_check CHECK (
  replacement_model_name IS NULL
  OR (
    lifecycle_state <> 'active'
    AND replacement_model_name <> name
  )
),
ADD CONSTRAINT models_lifecycle_revision_check CHECK (
  lifecycle_revision_hash = otlet.model_lifecycle_revision(
    name,
    lifecycle_state,
    replacement_model_name
  )
),
ADD CONSTRAINT models_replacement_fkey FOREIGN KEY (replacement_model_name)
  REFERENCES otlet.models(name);

ALTER TABLE otlet.production_policy
ADD CONSTRAINT production_policy_preload_model_fkey
FOREIGN KEY (preload_model_name) REFERENCES otlet.models(name);

CREATE FUNCTION otlet.guard_model_registration() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
    RAISE EXCEPTION 'otlet model registrations are retained; use lifecycle state and the pruning plan';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.lifecycle_state IS DISTINCT FROM 'active'
       OR NEW.replacement_model_name IS NOT NULL THEN
      RAISE EXCEPTION 'otlet new model registrations must start active without a replacement';
    END IF;
    NEW.lifecycle_revision_hash := otlet.model_lifecycle_revision(
      NEW.name,
      NEW.lifecycle_state,
      NEW.replacement_model_name
    );
    RETURN NEW;
  END IF;
  IF NEW.name IS DISTINCT FROM OLD.name
     OR NEW.artifact_path IS DISTINCT FROM OLD.artifact_path
     OR NEW.artifact_hash IS DISTINCT FROM OLD.artifact_hash
     OR NEW.artifact_identity IS DISTINCT FROM OLD.artifact_identity THEN
    RAISE EXCEPTION 'otlet model name and artifact identity are immutable; register a new model name';
  END IF;
  IF (
       NEW.lifecycle_state IS DISTINCT FROM OLD.lifecycle_state
       OR NEW.replacement_model_name IS DISTINCT FROM OLD.replacement_model_name
       OR NEW.lifecycle_revision_hash IS DISTINCT FROM OLD.lifecycle_revision_hash
     )
     AND current_setting('otlet.model_lifecycle_write', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'otlet model lifecycle changes require set_model_lifecycle';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER models_registration_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.models
FOR EACH ROW EXECUTE FUNCTION otlet.guard_model_registration();

CREATE TRIGGER models_registration_truncate_guard
BEFORE TRUNCATE ON otlet.models
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_model_registration();

CREATE OR REPLACE FUNCTION otlet.register_model(
  model_name text,
  artifact_path text,
  artifact_hash text,
  artifact_identity jsonb,
  max_active_jobs int DEFAULT 1
) RETURNS otlet.models
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  saved otlet.models%ROWTYPE;
  normalized_hash text := lower(register_model.artifact_hash);
BEGIN
  SELECT model.*
  INTO saved
  FROM otlet.models model
  WHERE model.name = register_model.model_name
  FOR UPDATE;
  IF FOUND THEN
    IF saved.artifact_path IS DISTINCT FROM register_model.artifact_path
       OR saved.artifact_hash IS DISTINCT FROM normalized_hash
       OR saved.artifact_identity IS DISTINCT FROM register_model.artifact_identity THEN
      RAISE EXCEPTION 'otlet model % artifact identity is immutable; register a new model name',
        register_model.model_name;
    END IF;
    UPDATE otlet.models model
    SET max_active_jobs = GREATEST(
      1,
      LEAST(COALESCE(register_model.max_active_jobs, 1), 1024)
    )
    WHERE model.name = register_model.model_name
    RETURNING * INTO saved;
    RETURN saved;
  END IF;

  INSERT INTO otlet.models (
    name,
    artifact_path,
    artifact_hash,
    artifact_identity,
    max_active_jobs
  ) VALUES (
    register_model.model_name,
    register_model.artifact_path,
    normalized_hash,
    register_model.artifact_identity,
    GREATEST(1, LEAST(COALESCE(register_model.max_active_jobs, 1), 1024))
  )
  RETURNING * INTO saved;
  RETURN saved;
END;
$$;

DROP TRIGGER models_administrative_change ON otlet.models;
CREATE TRIGGER models_administrative_change
AFTER INSERT OR DELETE OR UPDATE OF name, artifact_path, artifact_hash,
  artifact_identity, max_active_jobs, lifecycle_state, replacement_model_name,
  lifecycle_revision_hash ON otlet.models
FOR EACH ROW EXECUTE FUNCTION otlet.record_administrative_row_change();

CREATE FUNCTION otlet.current_postmaster_epoch() RETURNS text
LANGUAGE sql
STABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT to_char(
    pg_postmaster_start_time() AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
  );
$$;

CREATE FUNCTION otlet.model_artifact_store_observation_valid(definition jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  artifact jsonb;
BEGIN
  IF jsonb_typeof(definition) IS DISTINCT FROM 'object'
     OR octet_length(definition::text) > 1048576 THEN
    RETURN false;
  END IF;
  IF ARRAY(
       SELECT key
       FROM jsonb_object_keys(definition) key
       ORDER BY key COLLATE "C"
     ) IS DISTINCT FROM ARRAY[
       'artifacts',
       'available_bytes',
       'capacity_bytes',
       'evidence_source',
       'format',
       'store_root'
     ]::text[]
     OR definition ->> 'format' IS DISTINCT FROM
       'otlet.model_artifact_store.observation.v1'
     OR definition ->> 'evidence_source' IS DISTINCT FROM
       'deployment_reported'
     OR jsonb_typeof(definition -> 'store_root') IS DISTINCT FROM 'string'
     OR left(definition ->> 'store_root', 1) <> '/'
     OR definition ->> 'store_root' = '/'
     OR definition ->> 'store_root' <> btrim(definition ->> 'store_root')
     OR right(definition ->> 'store_root', 1) = '/'
     OR definition ->> 'store_root' LIKE '%//%'
     OR definition ->> 'store_root' ~ '/[.][.]?(/|$)'
     OR octet_length(definition ->> 'store_root') > 4096
     OR jsonb_typeof(definition -> 'capacity_bytes') IS DISTINCT FROM 'number'
     OR definition ->> 'capacity_bytes' !~ '^[1-9][0-9]{0,18}$'
     OR (definition ->> 'capacity_bytes')::numeric > 9223372036854775807
     OR jsonb_typeof(definition -> 'available_bytes') IS DISTINCT FROM 'number'
     OR definition ->> 'available_bytes' !~ '^(0|[1-9][0-9]{0,18})$'
     OR (definition ->> 'available_bytes')::numeric > 9223372036854775807
     OR (definition ->> 'available_bytes')::numeric >
       (definition ->> 'capacity_bytes')::numeric
     OR jsonb_typeof(definition -> 'artifacts') IS DISTINCT FROM 'array'
     OR jsonb_array_length(definition -> 'artifacts') > 1024 THEN
    RETURN false;
  END IF;
  IF definition -> 'artifacts' IS DISTINCT FROM (
    SELECT COALESCE(
      jsonb_agg(item.value ORDER BY (item.value ->> 'path') COLLATE "C"),
      '[]'::jsonb
    )
    FROM jsonb_array_elements(definition -> 'artifacts') item(value)
  ) OR (
    SELECT count(*)
    FROM jsonb_array_elements(definition -> 'artifacts') item(value)
  ) IS DISTINCT FROM (
    SELECT count(DISTINCT (item.value ->> 'path') COLLATE "C")
    FROM jsonb_array_elements(definition -> 'artifacts') item(value)
  ) THEN
    RETURN false;
  END IF;

  FOR artifact IN
    SELECT item.value
    FROM jsonb_array_elements(definition -> 'artifacts') item(value)
  LOOP
    IF jsonb_typeof(artifact) IS DISTINCT FROM 'object' THEN
      RETURN false;
    END IF;
    IF ARRAY(
         SELECT key
         FROM jsonb_object_keys(artifact) key
         ORDER BY key COLLATE "C"
       ) IS DISTINCT FROM ARRAY['bytes', 'path', 'sha256']::text[]
       OR jsonb_typeof(artifact -> 'path') IS DISTINCT FROM 'string'
       OR artifact ->> 'path' <> btrim(artifact ->> 'path')
       OR left(artifact ->> 'path', 1) <> '/'
       OR artifact ->> 'path' LIKE '%//%'
       OR artifact ->> 'path' ~ '/[.][.]?(/|$)'
       OR right(artifact ->> 'path', 1) = '/'
       OR octet_length(artifact ->> 'path') > 4096
       OR left(
         artifact ->> 'path',
         length(definition ->> 'store_root') + 1
       ) <> definition ->> 'store_root' || '/'
       OR jsonb_typeof(artifact -> 'sha256') IS DISTINCT FROM 'string'
       OR artifact ->> 'sha256' !~ '^[0-9a-f]{64}$'
       OR jsonb_typeof(artifact -> 'bytes') IS DISTINCT FROM 'number'
       OR artifact ->> 'bytes' !~ '^[1-9][0-9]{0,18}$'
       OR (artifact ->> 'bytes')::numeric > 9223372036854775807 THEN
      RETURN false;
    END IF;
  END LOOP;
  IF (definition ->> 'available_bytes')::numeric + (
    SELECT COALESCE(sum((item.value ->> 'bytes')::numeric), 0)
    FROM jsonb_array_elements(definition -> 'artifacts') item(value)
  ) > (definition ->> 'capacity_bytes')::numeric THEN
    RETURN false;
  END IF;
  RETURN true;
END;
$$;

CREATE FUNCTION otlet.model_artifact_store_observation_hash(
  generation bigint,
  postmaster_epoch text,
  definition jsonb
) RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT otlet.identity_hash(
    'model_artifact_store_observation',
    jsonb_build_object(
      'generation', $1,
      'postmaster_epoch', $2,
      'definition', $3
    )
  );
$$;

CREATE TABLE otlet.model_artifact_store_observations (
  name text PRIMARY KEY DEFAULT 'default' CHECK (name = 'default'),
  generation bigint NOT NULL CHECK (generation > 0),
  postmaster_epoch text NOT NULL CHECK (
    postmaster_epoch ~
      '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$'
  ),
  observation_hash text NOT NULL CHECK (
    observation_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  definition jsonb NOT NULL CHECK (
    otlet.model_artifact_store_observation_valid(definition)
    AND observation_hash = otlet.model_artifact_store_observation_hash(
      generation,
      postmaster_epoch,
      definition
    )
  ),
  observed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION otlet.guard_model_artifact_store_observation() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE')
     AND current_setting('otlet.model_artifact_store_write', true) = 'on' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'otlet model artifact store observations require reconcile_model_artifact_store';
END;
$$;

CREATE TRIGGER model_artifact_store_observations_row_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.model_artifact_store_observations
FOR EACH ROW EXECUTE FUNCTION otlet.guard_model_artifact_store_observation();

CREATE TRIGGER model_artifact_store_observations_truncate_guard
BEFORE TRUNCATE ON otlet.model_artifact_store_observations
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_model_artifact_store_observation();

CREATE FUNCTION otlet.reconcile_model_artifact_store(
  generation bigint,
  definition jsonb,
  reason text DEFAULT NULL,
  ticket text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  stored otlet.model_artifact_store_observations%ROWTYPE;
  epoch text := otlet.current_postmaster_epoch();
  new_hash text;
  previous_write text := current_setting(
    'otlet.model_artifact_store_write',
    true
  );
BEGIN
  IF reconcile_model_artifact_store.generation < 1 THEN
    RAISE EXCEPTION 'otlet model artifact store generation must be positive';
  END IF;
  IF NOT otlet.model_artifact_store_observation_valid(
    reconcile_model_artifact_store.definition
  ) THEN
    RAISE EXCEPTION 'otlet model artifact store observation is invalid';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('otlet_queue_admission')
  );
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('otlet_model_artifact_store:default', 0)
  );
  SELECT observation.*
  INTO stored
  FROM otlet.model_artifact_store_observations observation
  WHERE observation.name = 'default';
  new_hash := otlet.model_artifact_store_observation_hash(
    reconcile_model_artifact_store.generation,
    epoch,
    reconcile_model_artifact_store.definition
  );
  IF FOUND AND stored.generation = reconcile_model_artifact_store.generation THEN
    IF stored.observation_hash = new_hash THEN
      RETURN new_hash;
    END IF;
    RAISE EXCEPTION 'otlet model artifact store generation conflicts with the current observation';
  END IF;
  IF FOUND AND reconcile_model_artifact_store.generation < stored.generation THEN
    RAISE EXCEPTION 'otlet model artifact store generation is stale';
  END IF;
  PERFORM otlet.set_administrative_change_context(
    reconcile_model_artifact_store.reason,
    reconcile_model_artifact_store.ticket
  );
  PERFORM set_config('otlet.model_artifact_store_write', 'on', true);
  INSERT INTO otlet.model_artifact_store_observations (
    name,
    generation,
    postmaster_epoch,
    observation_hash,
    definition
  ) VALUES (
    'default',
    reconcile_model_artifact_store.generation,
    epoch,
    new_hash,
    reconcile_model_artifact_store.definition
  )
  ON CONFLICT (name) DO UPDATE
  SET generation = EXCLUDED.generation,
      postmaster_epoch = EXCLUDED.postmaster_epoch,
      observation_hash = EXCLUDED.observation_hash,
      definition = EXCLUDED.definition,
      observed_at = clock_timestamp();
  PERFORM set_config(
    'otlet.model_artifact_store_write',
    COALESCE(previous_write, ''),
    true
  );
  PERFORM otlet.append_administrative_change(
    'model',
    'artifact_store:default',
    'reconcile',
    stored.observation_hash,
    new_hash
  );
  RETURN new_hash;
END;
$$;

CREATE FUNCTION otlet.model_artifact_reconciliation_state(model_name text)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  WITH registered AS (
    SELECT model.*
    FROM otlet.models model
    WHERE model.name = $1
  ), observation AS (
    SELECT stored.*
    FROM otlet.model_artifact_store_observations stored
    WHERE stored.name = 'default'
  ), matched AS (
    SELECT artifact.value
    FROM observation stored
    CROSS JOIN registered model
    CROSS JOIN LATERAL jsonb_array_elements(
      stored.definition -> 'artifacts'
    ) artifact(value)
    WHERE artifact.value ->> 'path' = model.artifact_path
  )
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM registered) THEN 'registration_missing'
    WHEN NOT EXISTS (SELECT 1 FROM observation) THEN 'unmanaged'
    WHEN NOT EXISTS (
      SELECT 1
      FROM observation stored
      CROSS JOIN registered model
      WHERE left(
        model.artifact_path,
        length(stored.definition ->> 'store_root') + 1
      ) = stored.definition ->> 'store_root' || '/'
    ) THEN 'unmanaged'
    WHEN (SELECT postmaster_epoch FROM observation)
      IS DISTINCT FROM otlet.current_postmaster_epoch() THEN 'stale_epoch'
    WHEN NOT EXISTS (SELECT 1 FROM matched) THEN 'missing'
    WHEN EXISTS (
      SELECT 1
      FROM matched artifact
      CROSS JOIN registered model
      WHERE artifact.value ->> 'sha256' IS DISTINCT FROM model.artifact_hash
    ) THEN 'hash_mismatch'
    WHEN EXISTS (
      SELECT 1
      FROM matched artifact
      CROSS JOIN registered model
      WHERE (artifact.value ->> 'bytes')::bigint IS DISTINCT FROM
        (model.artifact_identity ->> 'bytes')::bigint
    ) THEN 'size_mismatch'
    ELSE 'verified'
  END;
$$;

CREATE FUNCTION otlet.model_artifact_ready(model_name text) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT otlet.model_artifact_reconciliation_state($1) IN (
    'unmanaged',
    'verified'
  );
$$;

CREATE FUNCTION otlet.workload_revision_model_routes(definition jsonb)
RETURNS TABLE (
  selection_role text,
  model_name text,
  model_definition jsonb
)
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT route.key, route.value ->> 'name', route.value
  FROM jsonb_each(COALESCE($1 -> 'models', '{}'::jsonb)) route(key, value)
  WHERE jsonb_typeof(route.value) = 'object';
$$;

CREATE FUNCTION otlet.model_has_unfinished_work(model_name text) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM otlet.jobs job
    JOIN otlet.workload_revisions revision
      ON revision.task_name = job.task_name
     AND revision.workload_revision_hash = job.workload_revision_hash
    WHERE job.status IN ('queued', 'running', 'cancel_requested')
      AND EXISTS (
        SELECT 1
        FROM otlet.workload_revision_model_routes(revision.definition) route
        WHERE route.model_name = $1
      )
  );
$$;

CREATE FUNCTION otlet.set_model_lifecycle(
  model_name text,
  lifecycle_state text,
  replacement_model_name text DEFAULT NULL,
  expected_lifecycle_revision_hash text DEFAULT NULL,
  reason text DEFAULT NULL,
  ticket text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  model otlet.models%ROWTYPE;
  replacement otlet.models%ROWTYPE;
  new_hash text;
  previous_write text := current_setting('otlet.model_lifecycle_write', true);
BEGIN
  IF set_model_lifecycle.lifecycle_state NOT IN (
    'active', 'deprecated', 'draining', 'disabled'
  ) THEN
    RAISE EXCEPTION 'otlet model lifecycle state is invalid';
  END IF;
  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('otlet_queue_admission')
  );
  SELECT registered.*
  INTO model
  FROM otlet.models registered
  WHERE registered.name = set_model_lifecycle.model_name
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet model % does not exist', set_model_lifecycle.model_name;
  END IF;
  IF set_model_lifecycle.expected_lifecycle_revision_hash IS NOT NULL
     AND model.lifecycle_revision_hash IS DISTINCT FROM
       set_model_lifecycle.expected_lifecycle_revision_hash THEN
    RAISE EXCEPTION 'otlet model lifecycle revision conflict for %',
      set_model_lifecycle.model_name;
  END IF;
  IF set_model_lifecycle.lifecycle_state = 'active'
     AND set_model_lifecycle.replacement_model_name IS NOT NULL THEN
    RAISE EXCEPTION 'otlet active model lifecycle cannot declare a replacement';
  END IF;
  IF set_model_lifecycle.lifecycle_state = 'active'
     AND NOT otlet.model_artifact_ready(set_model_lifecycle.model_name) THEN
    RAISE EXCEPTION 'otlet model artifact reconciliation is not ready for activation';
  END IF;
  IF set_model_lifecycle.replacement_model_name IS NOT NULL THEN
    SELECT candidate.*
    INTO replacement
    FROM otlet.models candidate
    WHERE candidate.name = set_model_lifecycle.replacement_model_name;
    IF NOT FOUND
       OR replacement.lifecycle_state <> 'active'
       OR NOT otlet.model_artifact_ready(replacement.name) THEN
      RAISE EXCEPTION 'otlet replacement model must be an active ready registration';
    END IF;
    IF replacement.name = model.name
       OR (
         replacement.artifact_path = model.artifact_path
         AND replacement.artifact_hash = model.artifact_hash
         AND replacement.artifact_identity = model.artifact_identity
       ) THEN
      RAISE EXCEPTION 'otlet replacement model must have a distinct artifact identity';
    END IF;
  END IF;
  new_hash := otlet.model_lifecycle_revision(
    model.name,
    set_model_lifecycle.lifecycle_state,
    set_model_lifecycle.replacement_model_name
  );
  IF model.lifecycle_revision_hash = new_hash THEN
    RETURN new_hash;
  END IF;
  PERFORM otlet.set_administrative_change_context(
    set_model_lifecycle.reason,
    set_model_lifecycle.ticket
  );
  PERFORM set_config('otlet.model_lifecycle_write', 'on', true);
  UPDATE otlet.models registered
  SET lifecycle_state = set_model_lifecycle.lifecycle_state,
      replacement_model_name = set_model_lifecycle.replacement_model_name,
      lifecycle_revision_hash = new_hash
  WHERE registered.name = model.name;
  PERFORM set_config(
    'otlet.model_lifecycle_write',
    COALESCE(previous_write, ''),
    true
  );
  PERFORM otlet.wake_worker();
  RETURN new_hash;
END;
$$;

CREATE FUNCTION otlet.model_definition_registration_state(definition jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  registered otlet.models%ROWTYPE;
  artifact_state text;
BEGIN
  IF jsonb_typeof(definition) IS DISTINCT FROM 'object'
     OR NULLIF(definition ->> 'name', '') IS NULL THEN
    RETURN 'invalid_definition';
  END IF;
  SELECT model.*
  INTO registered
  FROM otlet.models model
  WHERE model.name = definition ->> 'name';
  IF NOT FOUND THEN
    RETURN 'registration_missing';
  END IF;
  IF registered.artifact_path IS DISTINCT FROM definition ->> 'artifact_path'
     OR registered.artifact_hash IS DISTINCT FROM definition ->> 'artifact_hash'
     OR registered.artifact_identity IS DISTINCT FROM definition -> 'artifact_identity' THEN
    RETURN 'identity_mismatch';
  END IF;
  artifact_state := otlet.model_artifact_reconciliation_state(registered.name);
  IF artifact_state NOT IN ('unmanaged', 'verified') THEN
    RETURN 'artifact_' || artifact_state;
  END IF;
  RETURN registered.lifecycle_state;
END;
$$;

CREATE FUNCTION otlet.guard_workload_revision_models() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  route record;
  registration_state text;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('otlet_queue_admission')
  );
  IF EXISTS (
    SELECT 1
    FROM otlet.workload_revisions revision
    WHERE revision.workload_revision_hash = NEW.workload_revision_hash
      AND revision.task_name = NEW.task_name
      AND revision.definition = NEW.definition
  ) THEN
    RETURN NEW;
  END IF;
  IF jsonb_typeof(NEW.definition #> '{models,direct}')
       IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet workload revision requires a direct model definition';
  END IF;
  FOR route IN
    SELECT * FROM otlet.workload_revision_model_routes(NEW.definition)
  LOOP
    registration_state := otlet.model_definition_registration_state(
      route.model_definition
    );
    IF registration_state IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'otlet workload revision model % route % is %',
        route.model_name,
        route.selection_role,
        registration_state;
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_revisions_model_lifecycle_guard
BEFORE INSERT ON otlet.workload_revisions
FOR EACH ROW EXECUTE FUNCTION otlet.guard_workload_revision_models();

CREATE FUNCTION otlet.guard_workload_revision_head_models() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  route record;
  definition jsonb;
  registration_state text;
  allow_deprecated boolean := false;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.active_workload_revision_hash IS NOT DISTINCT FROM
       OLD.active_workload_revision_hash THEN
    RETURN NEW;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('otlet_queue_admission')
  );
  IF TG_OP = 'INSERT' THEN
    SELECT EXISTS (
      SELECT 1
      FROM otlet.tasks task
      WHERE task.name = NEW.task_name
        AND task.lifecycle_revision_hash = NEW.active_workload_revision_hash
    ) INTO allow_deprecated;
  ELSE
    allow_deprecated := NEW.active_workload_revision_hash IS NOT DISTINCT FROM
      OLD.previous_workload_revision_hash;
  END IF;
  SELECT revision.definition
  INTO definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = NEW.task_name
    AND revision.workload_revision_hash = NEW.active_workload_revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision head target does not exist';
  END IF;
  FOR route IN
    SELECT * FROM otlet.workload_revision_model_routes(definition)
  LOOP
    registration_state := otlet.model_definition_registration_state(
      route.model_definition
    );
    IF registration_state IS DISTINCT FROM 'active'
       AND NOT (allow_deprecated AND registration_state = 'deprecated') THEN
      RAISE EXCEPTION 'otlet workload revision head model % route % is %',
        route.model_name,
        route.selection_role,
        registration_state;
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_revision_heads_model_lifecycle_guard
BEFORE INSERT OR UPDATE ON otlet.workload_revision_heads
FOR EACH ROW EXECUTE FUNCTION otlet.guard_workload_revision_head_models();

CREATE FUNCTION otlet.guard_job_model_admission() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  route record;
  definition jsonb;
  registration_state text;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('otlet_queue_admission')
  );
  SELECT revision.definition
  INTO definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = NEW.task_name
    AND revision.workload_revision_hash = NEW.workload_revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet job workload revision does not exist';
  END IF;
  FOR route IN
    SELECT * FROM otlet.workload_revision_model_routes(definition)
  LOOP
    registration_state := otlet.model_definition_registration_state(
      route.model_definition
    );
    IF registration_state NOT IN ('active', 'deprecated') THEN
      RAISE EXCEPTION 'otlet job model % route % is % and cannot accept new work',
        route.model_name,
        route.selection_role,
        registration_state;
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

CREATE TRIGGER jobs_model_lifecycle_admission
BEFORE INSERT ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION otlet.guard_job_model_admission();

CREATE FUNCTION otlet.guard_preload_model_lifecycle() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  model_state text;
BEGIN
  IF NEW.preload_model_name IS NULL
     OR (
       TG_OP = 'UPDATE'
       AND NEW.preload_model_name IS NOT DISTINCT FROM OLD.preload_model_name
     ) THEN
    RETURN NEW;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('otlet_queue_admission')
  );
  SELECT model.lifecycle_state
  INTO model_state
  FROM otlet.models model
  WHERE model.name = NEW.preload_model_name
    AND otlet.model_artifact_ready(model.name);
  IF model_state IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'otlet preload model must be an active ready registration';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER production_policy_preload_model_lifecycle_guard
BEFORE INSERT OR UPDATE OF preload_model_name ON otlet.production_policy
FOR EACH ROW EXECUTE FUNCTION otlet.guard_preload_model_lifecycle();

CREATE FUNCTION otlet.guard_portable_worker_model_lifecycle() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  model otlet.models%ROWTYPE;
BEGIN
  IF NOT NEW.enabled THEN
    RETURN NEW;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('otlet_queue_admission')
  );
  SELECT registered.*
  INTO model
  FROM otlet.models registered
  WHERE registered.name = NEW.model_name;
  IF NOT FOUND
     OR model.artifact_hash IS DISTINCT FROM NEW.model_artifact_hash
     OR (model.artifact_identity ->> 'bytes')::bigint IS DISTINCT FROM
       NEW.model_artifact_bytes
     OR NOT otlet.model_artifact_ready(model.name)
     OR model.lifecycle_state IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'otlet portable worker binding requires an active ready model';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER portable_workers_model_lifecycle_guard
BEFORE INSERT OR UPDATE OF database_role_oid, protocol_version, model_name,
  model_artifact_hash, model_artifact_bytes, runtime_name, runtime_version,
  runtime_identity, runtime_identity_hash, enabled ON otlet.portable_workers
FOR EACH ROW EXECUTE FUNCTION otlet.guard_portable_worker_model_lifecycle();

CREATE FUNCTION otlet.guard_portable_worker_model_start() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  model otlet.models%ROWTYPE;
BEGIN
  IF NEW.incarnation_nonce_hash IS NOT DISTINCT FROM OLD.incarnation_nonce_hash
     AND NOT (
       NEW.reported_state = 'starting'
       AND NEW.reported_state IS DISTINCT FROM OLD.reported_state
     ) THEN
    RETURN NEW;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('otlet_queue_admission')
  );
  SELECT registered.*
  INTO model
  FROM otlet.models registered
  WHERE registered.name = NEW.model_name;
  IF NOT FOUND
     OR model.artifact_hash IS DISTINCT FROM NEW.model_artifact_hash
     OR (model.artifact_identity ->> 'bytes')::bigint IS DISTINCT FROM
       NEW.model_artifact_bytes
     OR NOT otlet.model_artifact_ready(model.name)
     OR model.lifecycle_state NOT IN ('active', 'deprecated', 'draining') THEN
    RAISE EXCEPTION 'otlet portable worker model is not ready for start';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER portable_workers_model_start_guard
BEFORE UPDATE OF incarnation_nonce_hash, reported_state
ON otlet.portable_workers
FOR EACH ROW EXECUTE FUNCTION otlet.guard_portable_worker_model_start();

CREATE OR REPLACE VIEW otlet.model_claim_capacity AS
WITH policy AS (
  SELECT max_attempts
  FROM otlet.production_policy
  WHERE name = 'default'
), job_models AS (
  SELECT
    COALESCE(
      j.routed_model_name,
      revision.definition #>> '{models,direct,name}'
    ) AS model_name,
    ((CASE
        WHEN j.routed_model_name = revision.definition #>> '{selection,strong_model_name}'
          THEN revision.definition #> '{models,strong}'
        WHEN j.routed_model_name = revision.definition #>> '{selection,cheap_model_name}'
          THEN revision.definition #> '{models,cheap}'
        ELSE revision.definition #> '{models,direct}'
      END) ->> 'max_active_jobs')::integer AS max_active_jobs,
    j.status,
    j.attempts,
    j.leased_until,
    (
      j.execution_mode = 'evaluation'
      OR j.workload_revision_hash = head.active_workload_revision_hash
    ) AS active_revision
  FROM otlet.jobs j
  JOIN otlet.workload_revisions revision
    ON revision.workload_revision_hash = j.workload_revision_hash
   AND revision.task_name = j.task_name
  LEFT JOIN otlet.workload_revision_heads head ON head.task_name = j.task_name
  WHERE j.status IN ('queued', 'running', 'cancel_requested')
), revision_routes AS (
  SELECT model_name, min(max_active_jobs) AS max_active_jobs
  FROM job_models
  GROUP BY model_name
), relevant_limits AS (
  SELECT model_name, min(max_active_jobs) AS max_active_jobs
  FROM job_models
  CROSS JOIN policy
  WHERE (
      status IN ('running', 'cancel_requested')
      AND leased_until >= now()
    )
    OR (
      active_revision
      AND (
        status = 'queued'
        OR (
          status IN ('running', 'cancel_requested')
          AND (leased_until IS NULL OR leased_until < now())
          AND attempts < policy.max_attempts
        )
      )
    )
  GROUP BY model_name
), model_routes AS (
  SELECT
    model.name AS model_name,
    LEAST(
      model.max_active_jobs,
      COALESCE(relevant.max_active_jobs, model.max_active_jobs)
    ) AS max_active_jobs,
    true AS registered,
    model.lifecycle_state <> 'disabled'
      AND otlet.model_artifact_ready(model.name) AS claimable
  FROM otlet.models model
  LEFT JOIN relevant_limits relevant ON relevant.model_name = model.name
  UNION ALL
  SELECT
    revision.model_name,
    COALESCE(relevant.max_active_jobs, revision.max_active_jobs),
    false,
    false
  FROM revision_routes revision
  LEFT JOIN relevant_limits relevant ON relevant.model_name = revision.model_name
  WHERE NOT EXISTS (
    SELECT 1 FROM otlet.models model WHERE model.name = revision.model_name
  )
), claim_counts AS (
  SELECT
    model_name,
    count(*) FILTER (
      WHERE status = 'running' AND leased_until >= now()
    )::bigint AS live_running_jobs,
    count(*) FILTER (
      WHERE status = 'cancel_requested' AND leased_until >= now()
    )::bigint AS live_cancel_requested_jobs
  FROM job_models
  GROUP BY model_name
)
SELECT
  route.model_name,
  route.max_active_jobs,
  COALESCE(claim.live_running_jobs, 0) AS live_running_jobs,
  COALESCE(claim.live_cancel_requested_jobs, 0) AS live_cancel_requested_jobs,
  COALESCE(claim.live_running_jobs, 0)
    + COALESCE(claim.live_cancel_requested_jobs, 0) AS active_claimed_jobs,
  CASE
    WHEN route.registered AND route.claimable THEN GREATEST(
      route.max_active_jobs::bigint
        - COALESCE(claim.live_running_jobs, 0)
        - COALESCE(claim.live_cancel_requested_jobs, 0),
      0
    )
    ELSE 0::bigint
  END AS available_active_job_slots
FROM model_routes route
LEFT JOIN claim_counts claim ON claim.model_name = route.model_name;

CREATE FUNCTION otlet.model_artifact_release_requested(model_name text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT COALESCE((
    SELECT model.lifecycle_state = 'disabled'
      OR (
        model.lifecycle_state = 'draining'
        AND NOT otlet.model_has_unfinished_work(model.name)
      )
    FROM otlet.models model
    WHERE model.name = $1
  ), false);
$$;

CREATE FUNCTION otlet.synchronize_portable_worker_model_release()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF otlet.model_artifact_release_requested(NEW.model_name) THEN
    NEW.desired_state := 'draining';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER portable_workers_model_release
BEFORE INSERT OR UPDATE ON otlet.portable_workers
FOR EACH ROW EXECUTE FUNCTION otlet.synchronize_portable_worker_model_release();

CREATE VIEW otlet.model_artifact_dependency_status AS
WITH dependency(
  model_name,
  dependency_class,
  dependency_type,
  dependency_key,
  task_name,
  workload_revision_hash,
  blocks_pruning,
  detail
) AS (
  SELECT
    task.model_name,
    CASE WHEN task.lifecycle_state = 'retired'
      THEN 'historical_only' ELSE 'operational' END,
    'task_configuration'::text,
    task.name || ':direct',
    task.name,
    NULL::text,
    task.lifecycle_state <> 'retired',
    jsonb_build_object(
      'task_lifecycle_state', task.lifecycle_state,
      'selection_role', 'direct'
    )
  FROM otlet.tasks task

  UNION ALL
  SELECT
    route.model_name,
    CASE WHEN task.lifecycle_state = 'retired'
      THEN 'historical_only' ELSE 'operational' END,
    'selection_configuration',
    policy.task_name || ':' || route.selection_role,
    policy.task_name,
    NULL::text,
    task.lifecycle_state <> 'retired',
    jsonb_build_object(
      'task_lifecycle_state', task.lifecycle_state,
      'selection_role', route.selection_role
    )
  FROM otlet.model_selection_policies policy
  JOIN otlet.tasks task ON task.name = policy.task_name
  CROSS JOIN LATERAL (VALUES
    ('cheap'::text, policy.cheap_model_name),
    ('strong'::text, policy.strong_model_name)
  ) route(selection_role, model_name)

  UNION ALL
  SELECT
    index.model_name,
    CASE WHEN task.lifecycle_state = 'retired'
      THEN 'historical_only' ELSE 'operational' END,
    'semantic_index_configuration',
    index.name,
    index.task_name,
    NULL::text,
    task.lifecycle_state <> 'retired',
    '{}'::jsonb
  FROM otlet.semantic_indexes index
  JOIN otlet.tasks task ON task.name = index.task_name

  UNION ALL
  SELECT
    index.model_name,
    CASE WHEN task.lifecycle_state = 'retired'
      THEN 'historical_only' ELSE 'operational' END,
    'semantic_join_index_configuration',
    index.name,
    index.task_name,
    NULL::text,
    task.lifecycle_state <> 'retired',
    '{}'::jsonb
  FROM otlet.semantic_join_indexes index
  JOIN otlet.tasks task ON task.name = index.task_name

  UNION ALL
  SELECT
    watch.model_name,
    CASE WHEN task.lifecycle_state = 'retired'
      THEN 'historical_only' ELSE 'operational' END,
    'watch_configuration',
    watch.name,
    watch.task_name,
    NULL::text,
    task.lifecycle_state <> 'retired',
    jsonb_build_object('watch_kind', watch.kind)
  FROM otlet.watches watch
  JOIN otlet.tasks task ON task.name = watch.task_name

  UNION ALL
  SELECT
    route.model_name,
    'operational',
    'active_workload_revision',
    head.task_name || ':' || route.selection_role,
    head.task_name,
    head.active_workload_revision_hash,
    true,
    jsonb_build_object('selection_role', route.selection_role)
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  CROSS JOIN LATERAL otlet.workload_revision_model_routes(
    revision.definition
  ) route

  UNION ALL
  SELECT
    route.model_name,
    'rollback_replay',
    'rollback_workload_revision',
    head.task_name || ':' || route.selection_role,
    head.task_name,
    head.previous_workload_revision_hash,
    true,
    jsonb_build_object('selection_role', route.selection_role)
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.previous_workload_revision_hash
  CROSS JOIN LATERAL otlet.workload_revision_model_routes(
    revision.definition
  ) route
  WHERE head.previous_workload_revision_hash IS NOT NULL

  UNION ALL
  SELECT
    route.model_name,
    'rollback_replay',
    'current_replay_contract',
    contract.contract_hash || ':' || variant.name || ':' || route.selection_role,
    contract.task_name,
    variant.workload_revision_hash,
    true,
    jsonb_build_object(
      'contract_hash', contract.contract_hash,
      'variant', variant.name,
      'selection_role', route.selection_role
    )
  FROM otlet.workload_acceptance_contracts contract
  CROSS JOIN LATERAL (VALUES
    ('baseline'::text, contract.baseline_workload_revision_hash),
    ('candidate'::text, contract.candidate_workload_revision_hash)
  ) variant(name, workload_revision_hash)
  JOIN otlet.workload_revisions revision
    ON revision.task_name = contract.task_name
   AND revision.workload_revision_hash = variant.workload_revision_hash
  CROSS JOIN LATERAL otlet.workload_revision_model_routes(
    revision.definition
  ) route
  WHERE NOT EXISTS (
    SELECT 1
    FROM otlet.workload_acceptance_contracts successor
    WHERE successor.supersedes_contract_hash = contract.contract_hash
  )

  UNION ALL
  SELECT
    route.model_name,
    'operational',
    'unfinished_job',
    job.id::text,
    job.task_name,
    job.workload_revision_hash,
    true,
    jsonb_build_object(
      'job_status', job.status,
      'execution_mode', job.execution_mode,
      'selection_role', route.selection_role
    )
  FROM otlet.jobs job
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  CROSS JOIN LATERAL otlet.workload_revision_model_routes(
    revision.definition
  ) route
  WHERE job.status IN ('queued', 'running', 'cancel_requested')

  UNION ALL
  SELECT
    policy.preload_model_name,
    'operational',
    'native_preload',
    policy.name,
    NULL::text,
    NULL::text,
    true,
    '{}'::jsonb
  FROM otlet.production_policy policy
  WHERE policy.preload_model_name IS NOT NULL

  UNION ALL
  SELECT
    slot.model_name,
    'operational',
    'native_residency',
    slot.model_name,
    NULL::text,
    NULL::text,
    true,
    jsonb_build_object(
      'status', slot.status,
      'artifact_path', slot.artifact_path,
      'active_jobs', slot.active_jobs
    )
  FROM otlet.runtime_slots slot
  WHERE slot.artifact_path IS NOT NULL
     OR slot.resident_memory_tracked_bytes > 0
     OR slot.status IN ('ready', 'running')

  UNION ALL
  SELECT
    worker.model_name,
    CASE WHEN (worker.enabled AND worker.desired_state <> 'draining')
           OR worker.reported_state NOT IN ('drained', 'stopped')
           OR worker.model_status NOT IN ('unverified', 'error')
      THEN 'operational' ELSE 'historical_only' END,
    'portable_worker',
    worker.worker_id,
    NULL::text,
    NULL::text,
    (worker.enabled AND worker.desired_state <> 'draining')
      OR worker.reported_state NOT IN ('drained', 'stopped')
      OR worker.model_status NOT IN ('unverified', 'error'),
    jsonb_build_object(
      'enabled', worker.enabled,
      'desired_state', worker.desired_state,
      'reported_state', worker.reported_state,
      'model_status', worker.model_status
    )
  FROM otlet.portable_workers worker

  UNION ALL
  SELECT
    model.replacement_model_name,
    'rollback_replay',
    'replacement_target',
    model.name,
    NULL::text,
    NULL::text,
    true,
    jsonb_build_object(
      'replaced_model_name', model.name,
      'replaced_model_state', model.lifecycle_state
    )
  FROM otlet.models model
  WHERE model.replacement_model_name IS NOT NULL

  UNION ALL
  SELECT
    model.name,
    'shared_file',
    'shared_artifact_path',
    other.name,
    NULL::text,
    NULL::text,
    false,
    jsonb_build_object(
      'artifact_path', model.artifact_path,
      'other_model_name', other.name,
      'same_hash', other.artifact_hash = model.artifact_hash
    )
  FROM otlet.models model
  JOIN otlet.models other
    ON other.artifact_path = model.artifact_path
   AND other.name <> model.name

  UNION ALL
  SELECT
    route.model_name,
    'historical_only',
    'historical_workload_revision',
    revision.workload_revision_hash || ':' || route.selection_role,
    revision.task_name,
    revision.workload_revision_hash,
    false,
    jsonb_build_object('selection_role', route.selection_role)
  FROM otlet.workload_revisions revision
  CROSS JOIN LATERAL otlet.workload_revision_model_routes(
    revision.definition
  ) route
  WHERE NOT EXISTS (
    SELECT 1
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = revision.task_name
      AND revision.workload_revision_hash IN (
        head.active_workload_revision_hash,
        head.previous_workload_revision_hash
      )
  )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.task_name = revision.task_name
        AND revision.workload_revision_hash IN (
          contract.baseline_workload_revision_hash,
          contract.candidate_workload_revision_hash
        )
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.workload_acceptance_contracts successor
          WHERE successor.supersedes_contract_hash = contract.contract_hash
        )
    )
)
SELECT * FROM dependency;

CREATE VIEW otlet.model_lifecycle_status AS
WITH dependency AS (
  SELECT
    model_name,
    count(*)::bigint AS dependencies,
    count(*) FILTER (
      WHERE dependency_class = 'operational'
    )::bigint AS operational_dependencies,
    count(*) FILTER (
      WHERE dependency_class = 'rollback_replay'
    )::bigint AS rollback_replay_dependencies,
    count(*) FILTER (
      WHERE dependency_class = 'historical_only'
    )::bigint AS historical_dependencies,
    count(*) FILTER (
      WHERE dependency_class = 'shared_file'
    )::bigint AS shared_file_dependencies,
    count(*) FILTER (WHERE blocks_pruning)::bigint AS blocking_dependencies,
    count(*) FILTER (
      WHERE blocks_pruning
        AND dependency_type IN (
          'unfinished_job',
          'native_residency',
          'portable_worker'
        )
    )::bigint AS runtime_dependencies,
    count(DISTINCT dependency_key) FILTER (
      WHERE dependency_type = 'unfinished_job'
    )::bigint AS unfinished_jobs
  FROM otlet.model_artifact_dependency_status
  GROUP BY model_name
)
SELECT
  model.name AS model_name,
  model.artifact_path,
  model.artifact_hash,
  (model.artifact_identity ->> 'bytes')::bigint AS artifact_bytes,
  model.lifecycle_state,
  model.replacement_model_name,
  replacement.lifecycle_state AS replacement_lifecycle_state,
  model.lifecycle_revision_hash,
  otlet.model_artifact_reconciliation_state(model.name)
    AS artifact_reconciliation_state,
  CASE
    WHEN otlet.model_artifact_reconciliation_state(model.name) = 'missing'
      AND model.lifecycle_state = 'disabled'
      AND COALESCE(dependency.blocking_dependencies, 0) = 0
      THEN 'expected_absent'
    ELSE otlet.model_artifact_reconciliation_state(model.name)
  END AS artifact_availability_state,
  otlet.model_artifact_ready(model.name) AS artifact_ready,
  model.lifecycle_state = 'active'
    AND otlet.model_artifact_ready(model.name) AS revision_binding_ready,
  model.lifecycle_state IN ('active', 'deprecated')
    AND otlet.model_artifact_ready(model.name) AS admission_ready,
  model.lifecycle_state IN ('active', 'deprecated', 'draining')
    AND otlet.model_artifact_ready(model.name) AS claim_ready,
  otlet.model_artifact_release_requested(model.name) AS release_requested,
  COALESCE(dependency.dependencies, 0) AS dependencies,
  COALESCE(dependency.operational_dependencies, 0)
    AS operational_dependencies,
  COALESCE(dependency.rollback_replay_dependencies, 0)
    AS rollback_replay_dependencies,
  COALESCE(dependency.historical_dependencies, 0)
    AS historical_dependencies,
  COALESCE(dependency.shared_file_dependencies, 0)
    AS shared_file_dependencies,
  COALESCE(dependency.blocking_dependencies, 0) AS blocking_dependencies,
  COALESCE(dependency.runtime_dependencies, 0) AS runtime_dependencies,
  COALESCE(dependency.unfinished_jobs, 0) AS unfinished_jobs,
  COALESCE(dependency.runtime_dependencies, 0) = 0 AS drain_complete
FROM otlet.models model
LEFT JOIN otlet.models replacement
  ON replacement.name = model.replacement_model_name
LEFT JOIN dependency ON dependency.model_name = model.name;

CREATE VIEW otlet.model_artifact_pruning_plan AS
WITH observation AS (
  SELECT stored.*
  FROM otlet.model_artifact_store_observations stored
  WHERE stored.name = 'default'
), artifact AS (
  SELECT
    stored.observation_hash,
    stored.postmaster_epoch,
    item.value ->> 'path' AS artifact_path,
    item.value ->> 'sha256' AS observed_artifact_hash,
    (item.value ->> 'bytes')::bigint AS observed_artifact_bytes
  FROM observation stored
  CROSS JOIN LATERAL jsonb_array_elements(
    stored.definition -> 'artifacts'
  ) item(value)
), registered AS (
  SELECT
    artifact.*,
    ARRAY(
      SELECT model.name
      FROM otlet.models model
      WHERE model.artifact_path = artifact.artifact_path
      ORDER BY model.name COLLATE "C"
    ) AS model_names,
    ARRAY(
      SELECT model.lifecycle_state
      FROM otlet.models model
      WHERE model.artifact_path = artifact.artifact_path
      ORDER BY model.name COLLATE "C"
    ) AS lifecycle_states,
    ARRAY(
      SELECT model.artifact_hash
      FROM otlet.models model
      WHERE model.artifact_path = artifact.artifact_path
      ORDER BY model.name COLLATE "C"
    ) AS registered_artifact_hashes,
    (
      SELECT count(*)::bigint
      FROM otlet.models model
      WHERE model.artifact_path = artifact.artifact_path
        AND model.artifact_hash = artifact.observed_artifact_hash
        AND (model.artifact_identity ->> 'bytes')::bigint =
          artifact.observed_artifact_bytes
    ) AS matching_registrations,
    NOT EXISTS (
      SELECT 1
      FROM otlet.models model
      WHERE model.artifact_path = artifact.artifact_path
        AND model.lifecycle_state <> 'disabled'
    ) AS all_models_disabled
  FROM artifact
), dependency AS (
  SELECT
    registered.*,
    (
      SELECT count(*)::bigint
      FROM otlet.model_artifact_dependency_status status
      WHERE status.model_name = ANY(registered.model_names)
        AND status.blocks_pruning
        AND status.dependency_class = 'operational'
    ) AS operational_dependencies,
    (
      SELECT count(*)::bigint
      FROM otlet.model_artifact_dependency_status status
      WHERE status.model_name = ANY(registered.model_names)
        AND status.blocks_pruning
        AND status.dependency_class = 'rollback_replay'
    ) AS rollback_replay_dependencies,
    ARRAY(
      SELECT DISTINCT
        (status.dependency_class || ':' || status.dependency_type)
          COLLATE "C" AS dependency_type
      FROM otlet.model_artifact_dependency_status status
      WHERE status.model_name = ANY(registered.model_names)
        AND status.blocks_pruning
      ORDER BY dependency_type
    ) AS blocking_dependency_types
  FROM registered
), planned AS (
  SELECT
    dependency.*,
    array_remove(ARRAY[
      CASE WHEN dependency.postmaster_epoch IS DISTINCT FROM
        otlet.current_postmaster_epoch() THEN 'stale_observation' END,
      CASE WHEN cardinality(dependency.model_names) = 0
        THEN 'registration_missing' END,
      CASE WHEN dependency.matching_registrations IS DISTINCT FROM
        cardinality(dependency.model_names)::bigint
        THEN 'registration_identity_mismatch' END,
      CASE WHEN NOT dependency.all_models_disabled
        THEN 'model_not_disabled' END,
      CASE WHEN dependency.operational_dependencies > 0
        THEN 'operational_dependencies' END,
      CASE WHEN dependency.rollback_replay_dependencies > 0
        THEN 'rollback_replay_dependencies' END
    ]::text[], NULL) AS blockers
  FROM dependency
), decided AS (
  SELECT
    planned.*,
    cardinality(planned.blockers) = 0 AS prune_ready,
    CASE WHEN cardinality(planned.blockers) = 0
      THEN planned.observed_artifact_bytes ELSE 0::bigint END
      AS reclaimable_bytes,
    CASE WHEN cardinality(planned.blockers) = 0
      THEN 'delete_external_file' ELSE 'retain' END AS action
  FROM planned
)
SELECT
  decided.artifact_path,
  decided.observed_artifact_hash,
  decided.observed_artifact_bytes,
  decided.model_names,
  decided.lifecycle_states,
  decided.registered_artifact_hashes,
  cardinality(decided.model_names)::bigint AS registration_count,
  decided.matching_registrations,
  decided.operational_dependencies,
  decided.rollback_replay_dependencies,
  decided.blocking_dependency_types,
  decided.blockers,
  decided.prune_ready,
  decided.reclaimable_bytes,
  decided.action,
  'deployment'::text AS deletion_owner,
  true AS dry_run,
  otlet.identity_hash(
    'model_artifact_pruning_plan',
    jsonb_build_object(
      'format', 'otlet.model_artifact_pruning_plan.v1',
      'observation_hash', decided.observation_hash,
      'artifact_path', decided.artifact_path,
      'observed_artifact_hash', decided.observed_artifact_hash,
      'observed_artifact_bytes', decided.observed_artifact_bytes,
      'model_names', to_jsonb(decided.model_names),
      'lifecycle_states', to_jsonb(decided.lifecycle_states),
      'registered_artifact_hashes',
        to_jsonb(decided.registered_artifact_hashes),
      'blocking_dependency_types',
        to_jsonb(decided.blocking_dependency_types),
      'blockers', to_jsonb(decided.blockers),
      'action', decided.action,
      'deletion_owner', 'deployment'
    )
  ) AS plan_hash
FROM decided;

CREATE VIEW otlet.model_artifact_store_status AS
WITH observation AS (
  SELECT stored.*
  FROM otlet.model_artifact_store_observations stored
  WHERE stored.name = 'default'
), observed AS (
  SELECT
    count(artifact.value)::bigint AS artifacts,
    COALESCE(sum((artifact.value ->> 'bytes')::bigint), 0)::bigint
      AS artifact_bytes,
    count(artifact.value) FILTER (
      WHERE NOT EXISTS (
        SELECT 1
        FROM otlet.models model
        WHERE model.artifact_path = artifact.value ->> 'path'
      )
    )::bigint AS unregistered_artifacts
  FROM observation stored
  LEFT JOIN LATERAL jsonb_array_elements(
    stored.definition -> 'artifacts'
  ) artifact(value) ON true
), registered AS (
  SELECT
    count(*) FILTER (WHERE state <> 'unmanaged')::bigint AS managed_models,
    count(*) FILTER (WHERE state = 'unmanaged')::bigint AS unmanaged_models,
    count(*) FILTER (WHERE state = 'verified')::bigint AS verified_models,
    count(*) FILTER (WHERE state = 'missing')::bigint AS missing_models,
    count(*) FILTER (
      WHERE state = 'missing'
        AND lifecycle_state = 'disabled'
        AND blocking_dependencies = 0
    )::bigint AS expected_absent_models,
    count(*) FILTER (
      WHERE state = 'missing'
        AND (
          lifecycle_state <> 'disabled'
          OR blocking_dependencies > 0
        )
    )::bigint AS unexpected_missing_models,
    count(*) FILTER (
      WHERE state IN ('hash_mismatch', 'size_mismatch')
    )::bigint AS mismatched_models
  FROM (
    SELECT
      model.lifecycle_state,
      otlet.model_artifact_reconciliation_state(model.name) AS state,
      (
        SELECT count(*)::bigint
        FROM otlet.model_artifact_dependency_status dependency
        WHERE dependency.model_name = model.name
          AND dependency.blocks_pruning
      ) AS blocking_dependencies
    FROM otlet.models model
  ) model_state
), pruning AS (
  SELECT
    count(*) FILTER (WHERE plan.prune_ready)::bigint AS prunable_artifacts,
    COALESCE(sum(plan.reclaimable_bytes), 0)::bigint AS reclaimable_bytes
  FROM otlet.model_artifact_pruning_plan plan
), recorded AS (
  SELECT
    event.actor_name,
    event.active_role_name,
    event.reason,
    event.ticket
  FROM observation stored
  LEFT JOIN LATERAL (
    SELECT change.*
    FROM otlet.administrative_change_events change
    WHERE change.object_type = 'model'
      AND change.object_name = 'artifact_store:default'
      AND change.new_revision_hash = stored.observation_hash
    ORDER BY change.changed_at DESC, change.event_id DESC
    LIMIT 1
  ) event ON true
)
SELECT
  'default'::text AS store_name,
  stored.generation,
  stored.observation_hash,
  stored.observed_at,
  stored.postmaster_epoch,
  otlet.current_postmaster_epoch() AS current_postmaster_epoch,
  stored.definition ->> 'store_root' AS store_root,
  stored.definition ->> 'evidence_source' AS evidence_source,
  (stored.definition ->> 'capacity_bytes')::bigint AS capacity_bytes,
  (stored.definition ->> 'available_bytes')::bigint AS available_bytes,
  CASE WHEN stored.definition IS NULL THEN NULL::bigint ELSE
    (stored.definition ->> 'capacity_bytes')::bigint
      - (stored.definition ->> 'available_bytes')::bigint
  END AS used_bytes,
  CASE
    WHEN stored.name IS NULL THEN 'unreported'
    WHEN stored.postmaster_epoch IS DISTINCT FROM
      otlet.current_postmaster_epoch() THEN 'stale_epoch'
    ELSE 'reconciled'
  END AS reconciliation_state,
  COALESCE(observed.artifacts, 0) AS observed_artifacts,
  COALESCE(observed.artifact_bytes, 0) AS observed_artifact_bytes,
  COALESCE(observed.unregistered_artifacts, 0) AS unregistered_artifacts,
  COALESCE(registered.managed_models, 0) AS managed_models,
  COALESCE(registered.unmanaged_models, 0) AS unmanaged_models,
  COALESCE(registered.verified_models, 0) AS verified_models,
  COALESCE(registered.missing_models, 0) AS missing_models,
  COALESCE(registered.expected_absent_models, 0) AS expected_absent_models,
  COALESCE(registered.unexpected_missing_models, 0)
    AS unexpected_missing_models,
  COALESCE(registered.mismatched_models, 0) AS mismatched_models,
  COALESCE(pruning.prunable_artifacts, 0) AS prunable_artifacts,
  COALESCE(pruning.reclaimable_bytes, 0) AS reclaimable_bytes,
  CASE WHEN stored.definition IS NULL THEN NULL::bigint ELSE LEAST(
    (stored.definition ->> 'capacity_bytes')::numeric,
    (stored.definition ->> 'available_bytes')::numeric
      + COALESCE(pruning.reclaimable_bytes, 0)::numeric
  )::bigint END AS projected_available_bytes,
  recorded.actor_name AS recorded_by,
  recorded.active_role_name AS recorded_as,
  recorded.reason,
  recorded.ticket,
  'deployment'::text AS deletion_owner
FROM (VALUES ('default'::text)) singleton(name)
LEFT JOIN observation stored ON stored.name = singleton.name
CROSS JOIN observed
CROSS JOIN registered
CROSS JOIN pruning
LEFT JOIN recorded ON true;

REVOKE ALL ON TABLE otlet.model_artifact_store_observations FROM PUBLIC;
REVOKE ALL ON TABLE otlet.model_artifact_dependency_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.model_lifecycle_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.model_artifact_pruning_plan FROM PUBLIC;
REVOKE ALL ON TABLE otlet.model_artifact_store_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.model_lifecycle_revision(text, text, text)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_model_registration() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.register_model(text, text, text, jsonb, integer)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.current_postmaster_epoch() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.model_artifact_store_observation_valid(jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.model_artifact_store_observation_hash(
  bigint, text, jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_model_artifact_store_observation()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reconcile_model_artifact_store(
  bigint, jsonb, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.model_artifact_reconciliation_state(text)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.model_artifact_ready(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.workload_revision_model_routes(jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.model_has_unfinished_work(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.set_model_lifecycle(
  text, text, text, text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.model_definition_registration_state(jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_workload_revision_models() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_workload_revision_head_models()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_job_model_admission() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_preload_model_lifecycle() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_portable_worker_model_lifecycle()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_portable_worker_model_start()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.synchronize_portable_worker_model_release()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.model_artifact_release_requested(text)
FROM PUBLIC;
