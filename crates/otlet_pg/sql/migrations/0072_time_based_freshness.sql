CREATE FUNCTION otlet.watch_trigger_policy_error(
  watch_kind text,
  trigger_policy jsonb
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  policy jsonb := COALESCE(watch_trigger_policy_error.trigger_policy, 'null'::jsonb);
  unsupported_key text;
  max_age_ms bigint;
  refresh_window_ms bigint;
BEGIN
  IF jsonb_typeof(policy) IS DISTINCT FROM 'object' THEN
    RETURN 'must be a JSON object';
  END IF;

  SELECT key
  INTO unsupported_key
  FROM jsonb_object_keys(policy) key
  WHERE key <> ALL (ARRAY[
    'on_change',
    'max_age_ms',
    'refresh_window_ms',
    'on_overdue'
  ])
  ORDER BY key
  LIMIT 1;
  IF unsupported_key IS NOT NULL THEN
    RETURN format('has unsupported key %s', unsupported_key);
  END IF;

  IF policy ? 'on_change'
     AND (
       jsonb_typeof(policy -> 'on_change') IS DISTINCT FROM 'string'
       OR policy ->> 'on_change' NOT IN ('mark_stale', 'mark_stale_and_enqueue')
     ) THEN
    RETURN 'on_change must be mark_stale or mark_stale_and_enqueue';
  END IF;

  IF NOT policy ? 'max_age_ms' THEN
    IF policy ? 'refresh_window_ms' OR policy ? 'on_overdue' THEN
      RETURN 'refresh_window_ms and on_overdue require max_age_ms';
    END IF;
    RETURN NULL;
  END IF;

  IF jsonb_typeof(policy -> 'max_age_ms') IS DISTINCT FROM 'number'
     OR policy ->> 'max_age_ms' !~ '^[1-9][0-9]{0,11}$' THEN
    RETURN 'max_age_ms must be an integer between 1 and 315576000000';
  END IF;
  max_age_ms := (policy ->> 'max_age_ms')::bigint;
  IF max_age_ms > 315576000000 THEN
    RETURN 'max_age_ms must be an integer between 1 and 315576000000';
  END IF;

  IF NOT policy ? 'refresh_window_ms'
     OR jsonb_typeof(policy -> 'refresh_window_ms') IS DISTINCT FROM 'number'
     OR policy ->> 'refresh_window_ms' !~ '^(0|[1-9][0-9]{0,11})$' THEN
    RETURN 'refresh_window_ms must be a nonnegative integer';
  END IF;
  refresh_window_ms := (policy ->> 'refresh_window_ms')::bigint;
  IF refresh_window_ms >= max_age_ms THEN
    RETURN 'refresh_window_ms must be less than max_age_ms';
  END IF;

  IF jsonb_typeof(policy -> 'on_overdue') IS DISTINCT FROM 'string'
     OR policy ->> 'on_overdue' NOT IN ('fail_closed', 'reconcile') THEN
    RETURN 'on_overdue must be fail_closed or reconcile';
  END IF;
  IF policy ->> 'on_overdue' = 'reconcile'
     AND watch_trigger_policy_error.watch_kind IS DISTINCT FROM 'row' THEN
    RETURN 'on_overdue reconcile is supported only for row watches';
  END IF;
  IF policy ->> 'on_overdue' = 'reconcile'
     AND COALESCE(policy ->> 'on_change', 'mark_stale') <> 'mark_stale_and_enqueue' THEN
    RETURN 'on_overdue reconcile requires on_change mark_stale_and_enqueue';
  END IF;
  RETURN NULL;
END;
$$;

DO $$
DECLARE
  invalid_watch record;
BEGIN
  SELECT watch.name, error.message
  INTO invalid_watch
  FROM otlet.watches watch
  CROSS JOIN LATERAL (
    SELECT otlet.watch_trigger_policy_error(
      watch.kind,
      watch.trigger_policy
    ) AS message
  ) error
  WHERE error.message IS NOT NULL
  ORDER BY watch.name
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'otlet watch % trigger_policy %',
      invalid_watch.name,
      invalid_watch.message;
  END IF;
END;
$$;

CREATE FUNCTION otlet.validate_watch_trigger_policy() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  validation_error text;
BEGIN
  validation_error := otlet.watch_trigger_policy_error(
    NEW.kind,
    NEW.trigger_policy
  );
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet watch trigger_policy %', validation_error;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER watches_trigger_policy_guard
BEFORE INSERT OR UPDATE OF kind, trigger_policy ON otlet.watches
FOR EACH ROW EXECUTE FUNCTION otlet.validate_watch_trigger_policy();

DO $migration$
DECLARE
  definition text;
  target text := '''record_type'', w.record_type';
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.current_workload_revision_definition(text)'::regprocedure
  );
  IF position(target IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet workload time-freshness revision rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    target,
    target || ',
        ''time_freshness'', CASE WHEN w.trigger_policy ? ''max_age_ms'' THEN
          jsonb_build_object(
            ''max_age_ms'', (w.trigger_policy ->> ''max_age_ms'')::bigint,
            ''refresh_window_ms'', (w.trigger_policy ->> ''refresh_window_ms'')::bigint,
            ''on_overdue'', w.trigger_policy ->> ''on_overdue''
          )
        END'
  );
END;
$migration$;

CREATE FUNCTION otlet.validate_workload_time_freshness() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  policy jsonb := NEW.definition #> '{source,time_freshness}';
  unsupported_key text;
  validation_error text;
BEGIN
  IF policy IS NULL THEN
    RETURN NEW;
  END IF;
  IF jsonb_typeof(policy) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet workload revision time_freshness must be a JSON object';
  END IF;
  SELECT key
  INTO unsupported_key
  FROM jsonb_object_keys(policy) key
  WHERE key <> ALL (ARRAY['max_age_ms', 'refresh_window_ms', 'on_overdue'])
  ORDER BY key
  LIMIT 1;
  IF unsupported_key IS NOT NULL
     OR NOT policy ?& ARRAY['max_age_ms', 'refresh_window_ms', 'on_overdue'] THEN
    RAISE EXCEPTION 'otlet workload revision time_freshness must contain exactly max_age_ms, refresh_window_ms, and on_overdue';
  END IF;
  validation_error := otlet.watch_trigger_policy_error(
    NEW.definition #>> '{source,kind}',
    policy || jsonb_build_object(
      'on_change',
      CASE policy ->> 'on_overdue'
        WHEN 'reconcile' THEN 'mark_stale_and_enqueue'
        ELSE 'mark_stale'
      END
    )
  );
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet workload revision time_freshness %', validation_error;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_revisions_time_freshness_guard
BEFORE INSERT OR UPDATE OF definition ON otlet.workload_revisions
FOR EACH ROW EXECUTE FUNCTION otlet.validate_workload_time_freshness();

CREATE FUNCTION otlet.semantic_time_freshness_state(
  refreshed_at timestamptz,
  max_age_ms bigint,
  refresh_window_ms bigint,
  as_of timestamptz
) RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
BEGIN ATOMIC
  SELECT CASE
    WHEN max_age_ms IS NULL THEN 'disabled'
    WHEN as_of >= refreshed_at + max_age_ms * interval '1 millisecond'
      THEN 'time_expired'
    WHEN as_of >= refreshed_at
      + (max_age_ms - COALESCE(refresh_window_ms, 0)) * interval '1 millisecond'
      THEN 'refresh_due'
    ELSE 'fresh'
  END;
END;

CREATE OR REPLACE VIEW otlet.semantic_materializations_effective AS
WITH classified AS (
  SELECT
    materialization.*,
    revision.definition AS workload_revision_definition,
    COALESCE(receipt.finished_at, materialization.created_at) AS accepted_at,
    correction.correction_hash,
    correction.corrected_body,
    correction.created_at AS correction_created_at,
    task.lifecycle_state = 'active'
      AND correction.expires_at > statement_timestamp()
      AND correction.source_hash = materialization.source_hash
      AND correction.content_hash = materialization.content_hash
      AND correction.relevant_contract_hash =
        otlet.pair_constraint_contract_hash(revision.definition)
      AND (
        NOT materialization.stale
        OR materialization.stale_reason = 'pair_constraint_conflict'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.pair_constraint_facts fact
        WHERE fact.task_name = materialization.task_name
          AND fact.subject_id = materialization.subject_id
          AND fact.source_hash = correction.source_hash
          AND fact.content_hash = correction.content_hash
          AND fact.relevant_contract_hash = correction.relevant_contract_hash
          AND fact.relation <> CASE correction.expected_answer
            WHEN 'same_entity' THEN 'must_link'
            WHEN 'different_entity' THEN 'cannot_link'
            ELSE NULL
          END
      ) AS correction_applies
  FROM otlet.semantic_materializations materialization
  JOIN otlet.tasks task ON task.name = materialization.task_name
  JOIN otlet.workload_revisions revision
    ON revision.task_name = materialization.task_name
   AND revision.workload_revision_hash = materialization.contract_hash
  LEFT JOIN otlet.records record ON record.id = materialization.record_id
  LEFT JOIN otlet.actions action ON action.id = record.action_id
  LEFT JOIN otlet.outputs output ON output.id = action.output_id
  LEFT JOIN otlet.inference_receipts receipt ON receipt.id = output.receipt_id
  LEFT JOIN LATERAL (
    SELECT candidate.*
    FROM otlet.semantic_correction_overrides candidate
    WHERE candidate.task_name = materialization.task_name
      AND candidate.record_type = materialization.record_type
      AND candidate.subject_id = materialization.subject_id
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.semantic_correction_overrides successor
        WHERE successor.supersedes_correction_hash = candidate.correction_hash
      )
    ORDER BY candidate.created_at DESC, candidate.correction_hash
    LIMIT 1
  ) correction ON true
), effective AS (
  SELECT
    classified.id,
    classified.record_id,
    classified.record_type,
    classified.source_table,
    classified.subject_id,
    classified.source_dependencies,
    classified.task_name,
    classified.model_name,
    CASE WHEN classified.correction_hash IS NULL
      THEN classified.body
      ELSE classified.corrected_body
    END AS body,
    CASE
      WHEN classified.correction_hash IS NULL THEN classified.stale
      WHEN NOT classified.correction_applies THEN true
      WHEN classified.stale_reason = 'source_update' THEN true
      ELSE false
    END AS stale,
    classified.source_hash,
    classified.content_hash,
    classified.contract_hash,
    CASE
      WHEN classified.correction_hash IS NULL THEN classified.stale_reason
      WHEN NOT classified.correction_applies
        THEN 'semantic_correction_re_review'
      ELSE 'semantic_correction'
    END AS stale_reason,
    CASE
      WHEN classified.correction_hash IS NULL THEN classified.freshness_basis
      WHEN classified.correction_applies THEN 'manual_correction'
      ELSE NULL
    END AS freshness_basis,
    classified.created_at,
    CASE WHEN classified.correction_hash IS NULL
      THEN classified.updated_at
      ELSE GREATEST(classified.updated_at, classified.correction_created_at)
    END AS legacy_updated_at,
    CASE WHEN classified.correction_applies
      THEN classified.correction_created_at
      ELSE classified.accepted_at
    END AS freshness_anchor,
    classified.correction_hash,
    CASE
      WHEN classified.correction_hash IS NULL THEN NULL
      WHEN classified.correction_applies THEN 'applied'
      ELSE 're_review'
    END AS correction_status,
    classified.workload_revision_definition
  FROM classified
), timed AS (
  SELECT
    effective.*,
    CASE WHEN effective.correction_hash IS NOT NULL THEN NULL
      ELSE effective.workload_revision_definition #> '{source,time_freshness}'
    END AS time_policy,
    otlet.semantic_time_freshness_state(
      effective.freshness_anchor,
      CASE WHEN effective.correction_hash IS NOT NULL THEN NULL
        ELSE NULLIF(
          effective.workload_revision_definition #>> '{source,time_freshness,max_age_ms}',
          ''
        )::bigint
      END,
      COALESCE(NULLIF(
        effective.workload_revision_definition #>> '{source,time_freshness,refresh_window_ms}',
        ''
      )::bigint, 0),
      statement_timestamp()
    ) AS time_freshness_state
  FROM effective
)
SELECT
  timed.id,
  timed.record_id,
  timed.record_type,
  timed.source_table,
  timed.subject_id,
  timed.source_dependencies,
  timed.task_name,
  timed.model_name,
  timed.body,
  timed.stale OR timed.time_freshness_state = 'time_expired' AS stale,
  timed.source_hash,
  timed.content_hash,
  timed.contract_hash,
  CASE
    WHEN timed.stale THEN timed.stale_reason
    WHEN timed.time_freshness_state = 'time_expired' THEN 'time_expired'
    ELSE timed.stale_reason
  END AS stale_reason,
  CASE
    WHEN timed.stale OR timed.time_freshness_state = 'time_expired' THEN NULL
    ELSE timed.freshness_basis
  END AS freshness_basis,
  timed.created_at,
  CASE WHEN timed.time_policy IS NULL
    THEN timed.legacy_updated_at
    ELSE timed.freshness_anchor
  END AS updated_at,
  timed.correction_hash,
  timed.correction_status
FROM timed;

CREATE TABLE otlet.watch_time_freshness (
  watch_name text NOT NULL REFERENCES otlet.watches(name) ON DELETE CASCADE,
  task_name text NOT NULL,
  workload_revision_hash text NOT NULL,
  subject_id text NOT NULL CHECK (NULLIF(subject_id, '') IS NOT NULL),
  materialization_id bigint NOT NULL REFERENCES otlet.semantic_materializations(id) ON DELETE CASCADE,
  source_identity text CHECK (
    source_identity IS NULL
    OR source_identity ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  anchor_identity text NOT NULL CHECK (NULLIF(anchor_identity, '') IS NOT NULL),
  refreshed_at timestamptz NOT NULL,
  refresh_due_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  acknowledged_at timestamptz,
  attempted_at timestamptz,
  PRIMARY KEY (watch_name, workload_revision_hash, subject_id),
  FOREIGN KEY (task_name, workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  CHECK (refresh_due_at >= refreshed_at),
  CHECK (expires_at >= refresh_due_at),
  CHECK (acknowledged_at IS NULL OR isfinite(acknowledged_at)),
  CHECK (attempted_at IS NULL OR isfinite(attempted_at))
);

CREATE INDEX watch_time_freshness_due_idx
ON otlet.watch_time_freshness (
  refresh_due_at,
  watch_name,
  workload_revision_hash,
  subject_id
)
WHERE acknowledged_at IS NULL AND attempted_at IS NULL;

CREATE INDEX watch_time_freshness_attempt_idx
ON otlet.watch_time_freshness (
  task_name,
  workload_revision_hash,
  subject_id
)
WHERE acknowledged_at IS NULL AND attempted_at IS NULL;

CREATE FUNCTION otlet.record_watch_time_freshness(
  materialization_id bigint
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  candidate record;
  changed bigint;
BEGIN
  SELECT
    watch.name AS watch_name,
    materialization.task_name,
    materialization.contract_hash AS workload_revision_hash,
    materialization.subject_id,
    materialization.id AS materialization_id,
    materialization.source_hash AS source_identity,
    materialization.correction_status,
    CASE WHEN materialization.correction_status = 'applied'
      THEN materialization.correction_hash
      ELSE 'materialization:' || materialization.id::text
    END AS anchor_identity,
    materialization.updated_at AS refreshed_at,
    materialization.updated_at
      + (
        (revision.definition #>> '{source,time_freshness,max_age_ms}')::bigint
        - (revision.definition #>> '{source,time_freshness,refresh_window_ms}')::bigint
      ) * interval '1 millisecond' AS refresh_due_at,
    materialization.updated_at
      + (revision.definition #>> '{source,time_freshness,max_age_ms}')::bigint
        * interval '1 millisecond' AS expires_at
  INTO candidate
  FROM otlet.semantic_materializations_effective materialization
  JOIN otlet.workload_revisions revision
    ON revision.task_name = materialization.task_name
   AND revision.workload_revision_hash = materialization.contract_hash
  JOIN otlet.watches watch
    ON watch.name = revision.definition #>> '{source,watch_name}'
   AND watch.task_name = materialization.task_name
  JOIN otlet.tasks task
    ON task.name = materialization.task_name
   AND task.lifecycle_revision_hash = materialization.contract_hash
   AND task.lifecycle_state IN ('active', 'paused')
  WHERE materialization.id = record_watch_time_freshness.materialization_id
    AND materialization.subject_id IS NOT NULL
    AND revision.definition #> '{source,time_freshness}' IS NOT NULL;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF candidate.correction_status IS NOT NULL THEN
    DELETE FROM otlet.watch_time_freshness freshness
    WHERE freshness.watch_name = candidate.watch_name
      AND freshness.subject_id = candidate.subject_id;
    DELETE FROM otlet.watch_reconciliation reconciliation
    WHERE reconciliation.watch_name = candidate.watch_name
      AND reconciliation.subject_id = candidate.subject_id
      AND reconciliation.reconciliation_reason = 'time_refresh';
    RETURN true;
  END IF;

  DELETE FROM otlet.watch_time_freshness freshness
  WHERE freshness.watch_name = candidate.watch_name
    AND freshness.subject_id = candidate.subject_id
    AND freshness.workload_revision_hash <> candidate.workload_revision_hash;

  INSERT INTO otlet.watch_time_freshness (
    watch_name,
    task_name,
    workload_revision_hash,
    subject_id,
    materialization_id,
    source_identity,
    anchor_identity,
    refreshed_at,
    refresh_due_at,
    expires_at
  ) VALUES (
    candidate.watch_name,
    candidate.task_name,
    candidate.workload_revision_hash,
    candidate.subject_id,
    candidate.materialization_id,
    candidate.source_identity,
    candidate.anchor_identity,
    candidate.refreshed_at,
    candidate.refresh_due_at,
    candidate.expires_at
  )
  ON CONFLICT (watch_name, workload_revision_hash, subject_id) DO UPDATE
  SET task_name = EXCLUDED.task_name,
      materialization_id = EXCLUDED.materialization_id,
      source_identity = EXCLUDED.source_identity,
      anchor_identity = EXCLUDED.anchor_identity,
      refreshed_at = EXCLUDED.refreshed_at,
      refresh_due_at = EXCLUDED.refresh_due_at,
      expires_at = EXCLUDED.expires_at,
      acknowledged_at = NULL,
      attempted_at = NULL
  WHERE (
    EXCLUDED.refreshed_at,
    EXCLUDED.materialization_id
  ) > (
    otlet.watch_time_freshness.refreshed_at,
    otlet.watch_time_freshness.materialization_id
  );
  GET DIAGNOSTICS changed = ROW_COUNT;
  DELETE FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = candidate.watch_name
    AND reconciliation.subject_id = candidate.subject_id
    AND reconciliation.reconciliation_reason = 'time_refresh'
    AND (
      reconciliation.workload_revision_hash <> candidate.workload_revision_hash
      OR changed > 0
    );
  RETURN changed > 0;
END;
$$;

CREATE FUNCTION otlet.record_materialization_time_freshness() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM otlet.record_watch_time_freshness(NEW.id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER semantic_materializations_time_freshness
AFTER INSERT ON otlet.semantic_materializations
FOR EACH ROW EXECUTE FUNCTION otlet.record_materialization_time_freshness();

CREATE FUNCTION otlet.record_correction_time_freshness() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM otlet.record_watch_time_freshness(NEW.materialization_id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER semantic_corrections_time_freshness
AFTER INSERT ON otlet.semantic_correction_overrides
FOR EACH ROW EXECUTE FUNCTION otlet.record_correction_time_freshness();

CREATE FUNCTION otlet.record_job_time_freshness_attempt() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  changed bigint;
BEGIN
  IF NEW.execution_mode <> 'production' OR NEW.subject_id IS NULL THEN
    RETURN NEW;
  END IF;

  UPDATE otlet.watch_time_freshness freshness
  SET attempted_at = clock_timestamp()
  FROM otlet.workload_revisions revision,
       otlet.semantic_materializations materialization
  WHERE freshness.task_name = NEW.task_name
    AND freshness.workload_revision_hash = NEW.workload_revision_hash
    AND freshness.subject_id = NEW.subject_id
    AND freshness.acknowledged_at IS NULL
    AND freshness.attempted_at IS NULL
    AND freshness.refresh_due_at <= clock_timestamp()
    AND revision.task_name = freshness.task_name
    AND revision.workload_revision_hash = freshness.workload_revision_hash
    AND materialization.id = freshness.materialization_id
    AND otlet.semantic_content_hash(
      NEW.input,
      revision.definition #> '{task,input_shaping}'
    ) = materialization.content_hash;
  GET DIAGNOSTICS changed = ROW_COUNT;
  IF changed > 0 THEN
    DELETE FROM otlet.watch_reconciliation reconciliation
    USING otlet.watch_time_freshness freshness
    WHERE freshness.task_name = NEW.task_name
      AND freshness.workload_revision_hash = NEW.workload_revision_hash
      AND freshness.subject_id = NEW.subject_id
      AND freshness.attempted_at IS NOT NULL
      AND reconciliation.watch_name = freshness.watch_name
      AND reconciliation.subject_id = freshness.subject_id
      AND reconciliation.workload_revision_hash = freshness.workload_revision_hash
      AND reconciliation.reconciliation_reason = 'time_refresh'
      AND reconciliation.time_expires_at = freshness.expires_at;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER jobs_time_freshness_attempt
AFTER INSERT OR UPDATE OF status ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION otlet.record_job_time_freshness_attempt();

ALTER TABLE otlet.watch_reconciliation
  ADD COLUMN reconciliation_reason text NOT NULL DEFAULT 'source_change'
    CHECK (reconciliation_reason IN ('source_change', 'time_refresh')),
  ADD COLUMN time_expires_at timestamptz,
  ADD CONSTRAINT watch_reconciliation_time_freshness_check CHECK (
    (reconciliation_reason = 'source_change' AND time_expires_at IS NULL)
    OR
    (reconciliation_reason = 'time_refresh' AND time_expires_at IS NOT NULL)
  );

CREATE OR REPLACE FUNCTION otlet.record_watch_reconciliation(
  watch_name text,
  subject_id text,
  workload_revision_hash text,
  source_identity text,
  source_deleted boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  policy_attempt_limit integer;
  saved_generation bigint;
BEGIN
  IF record_watch_reconciliation.subject_id IS NULL THEN
    RAISE EXCEPTION 'otlet watch reconciliation subject_id is required';
  END IF;

  SELECT policy.watch_reconciliation_max_attempts
  INTO policy_attempt_limit
  FROM otlet.production_policy policy
  WHERE policy.name = 'default';

  INSERT INTO otlet.watch_reconciliation (
    watch_name,
    subject_id,
    workload_revision_hash,
    source_identity,
    source_deleted,
    attempt_limit,
    reconciliation_reason
  ) VALUES (
    record_watch_reconciliation.watch_name,
    record_watch_reconciliation.subject_id,
    record_watch_reconciliation.workload_revision_hash,
    record_watch_reconciliation.source_identity,
    COALESCE(record_watch_reconciliation.source_deleted, false),
    policy_attempt_limit,
    'source_change'
  )
  ON CONFLICT ON CONSTRAINT watch_reconciliation_pkey DO UPDATE
  SET workload_revision_hash = EXCLUDED.workload_revision_hash,
      source_identity = EXCLUDED.source_identity,
      source_deleted = EXCLUDED.source_deleted,
      reconciliation_reason = 'source_change',
      time_expires_at = NULL,
      generation = EXCLUDED.generation,
      state = CASE
        WHEN otlet.watch_reconciliation.reconciliation_reason <> 'source_change'
          OR otlet.watch_reconciliation.workload_revision_hash IS DISTINCT FROM EXCLUDED.workload_revision_hash
          OR otlet.watch_reconciliation.source_identity IS DISTINCT FROM EXCLUDED.source_identity
          OR otlet.watch_reconciliation.source_deleted IS DISTINCT FROM EXCLUDED.source_deleted
          THEN 'pending'
        ELSE otlet.watch_reconciliation.state
      END,
      attempts = CASE
        WHEN otlet.watch_reconciliation.reconciliation_reason <> 'source_change'
          OR otlet.watch_reconciliation.workload_revision_hash IS DISTINCT FROM EXCLUDED.workload_revision_hash
          OR otlet.watch_reconciliation.source_identity IS DISTINCT FROM EXCLUDED.source_identity
          OR otlet.watch_reconciliation.source_deleted IS DISTINCT FROM EXCLUDED.source_deleted
          THEN 0
        ELSE otlet.watch_reconciliation.attempts
      END,
      attempt_limit = CASE
        WHEN otlet.watch_reconciliation.reconciliation_reason <> 'source_change'
          OR otlet.watch_reconciliation.workload_revision_hash IS DISTINCT FROM EXCLUDED.workload_revision_hash
          OR otlet.watch_reconciliation.source_identity IS DISTINCT FROM EXCLUDED.source_identity
          OR otlet.watch_reconciliation.source_deleted IS DISTINCT FROM EXCLUDED.source_deleted
          THEN EXCLUDED.attempt_limit
        ELSE otlet.watch_reconciliation.attempt_limit
      END,
      next_attempt_at = CASE
        WHEN otlet.watch_reconciliation.reconciliation_reason <> 'source_change'
          OR otlet.watch_reconciliation.workload_revision_hash IS DISTINCT FROM EXCLUDED.workload_revision_hash
          OR otlet.watch_reconciliation.source_identity IS DISTINCT FROM EXCLUDED.source_identity
          OR otlet.watch_reconciliation.source_deleted IS DISTINCT FROM EXCLUDED.source_deleted
          THEN clock_timestamp()
        ELSE otlet.watch_reconciliation.next_attempt_at
      END,
      last_error = CASE
        WHEN otlet.watch_reconciliation.reconciliation_reason <> 'source_change'
          OR otlet.watch_reconciliation.workload_revision_hash IS DISTINCT FROM EXCLUDED.workload_revision_hash
          OR otlet.watch_reconciliation.source_identity IS DISTINCT FROM EXCLUDED.source_identity
          OR otlet.watch_reconciliation.source_deleted IS DISTINCT FROM EXCLUDED.source_deleted
          THEN NULL
        ELSE otlet.watch_reconciliation.last_error
      END,
      last_dirty_at = clock_timestamp()
  RETURNING generation INTO saved_generation;

  PERFORM otlet.wake_worker();
  RETURN saved_generation;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.record_watch_input_reconciliation(
  task_name text,
  workload_revision_hash text,
  subject_id text,
  input jsonb
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  saved_watch_name text;
  policy_attempt_limit integer;
  saved_generation bigint;
BEGIN
  SELECT watch.name
  INTO saved_watch_name
  FROM otlet.watches watch
  JOIN otlet.workload_revisions revision
    ON revision.task_name = watch.task_name
   AND revision.workload_revision_hash = record_watch_input_reconciliation.workload_revision_hash
  WHERE watch.task_name = record_watch_input_reconciliation.task_name
    AND watch.kind = 'row'
    AND COALESCE(watch.trigger_policy ->> 'on_change', 'mark_stale') = 'mark_stale_and_enqueue';

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  SELECT policy.watch_reconciliation_max_attempts
  INTO policy_attempt_limit
  FROM otlet.production_policy policy
  WHERE policy.name = 'default';

  INSERT INTO otlet.watch_reconciliation (
    watch_name,
    subject_id,
    workload_revision_hash,
    source_identity,
    source_deleted,
    attempt_limit,
    reconciliation_reason
  ) VALUES (
    saved_watch_name,
    record_watch_input_reconciliation.subject_id,
    record_watch_input_reconciliation.workload_revision_hash,
    otlet.semantic_source_hash(record_watch_input_reconciliation.input),
    false,
    policy_attempt_limit,
    'source_change'
  )
  ON CONFLICT ON CONSTRAINT watch_reconciliation_pkey DO UPDATE
  SET workload_revision_hash = EXCLUDED.workload_revision_hash,
      source_identity = EXCLUDED.source_identity,
      source_deleted = false,
      reconciliation_reason = 'source_change',
      time_expires_at = NULL,
      generation = EXCLUDED.generation,
      state = 'pending',
      attempts = 0,
      attempt_limit = EXCLUDED.attempt_limit,
      next_attempt_at = clock_timestamp(),
      last_error = NULL,
      last_dirty_at = clock_timestamp()
  WHERE otlet.watch_reconciliation.reconciliation_reason = 'time_refresh'
     OR otlet.watch_reconciliation.workload_revision_hash IS DISTINCT FROM EXCLUDED.workload_revision_hash
     OR otlet.watch_reconciliation.source_identity IS DISTINCT FROM EXCLUDED.source_identity
     OR otlet.watch_reconciliation.source_deleted
  RETURNING generation INTO saved_generation;

  IF saved_generation IS NOT NULL THEN
    PERFORM otlet.wake_worker();
    RETURN saved_generation;
  END IF;
  SELECT reconciliation.generation
  INTO saved_generation
  FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = saved_watch_name
    AND reconciliation.subject_id = record_watch_input_reconciliation.subject_id;
  RETURN COALESCE(saved_generation, 0);
END;
$$;

CREATE OR REPLACE FUNCTION otlet.resolve_watch_input_reconciliation(
  task_name text,
  workload_revision_hash text,
  subject_id text,
  input jsonb
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  removed bigint;
BEGIN
  DELETE FROM otlet.watch_reconciliation reconciliation
  USING otlet.watches watch, otlet.workload_revisions revision
  WHERE watch.task_name = resolve_watch_input_reconciliation.task_name
    AND watch.kind = 'row'
    AND watch.name = reconciliation.watch_name
    AND revision.task_name = watch.task_name
    AND revision.workload_revision_hash = resolve_watch_input_reconciliation.workload_revision_hash
    AND reconciliation.subject_id = resolve_watch_input_reconciliation.subject_id
    AND reconciliation.workload_revision_hash = resolve_watch_input_reconciliation.workload_revision_hash
    AND reconciliation.reconciliation_reason = 'source_change'
    AND NOT reconciliation.source_deleted
    AND reconciliation.source_identity = otlet.semantic_source_hash(
      resolve_watch_input_reconciliation.input
    );
  GET DIAGNOSTICS removed = ROW_COUNT;
  RETURN removed > 0;
END;
$$;

CREATE VIEW otlet.watch_time_freshness_status AS
SELECT
  freshness.watch_name,
  revision.definition #>> '{source,kind}' AS kind,
  freshness.task_name,
  freshness.workload_revision_hash,
  freshness.subject_id,
  freshness.materialization_id,
  freshness.source_identity,
  freshness.refreshed_at,
  freshness.refresh_due_at,
  freshness.expires_at,
  otlet.semantic_time_freshness_state(
    freshness.refreshed_at,
    (revision.definition #>> '{source,time_freshness,max_age_ms}')::bigint,
    (revision.definition #>> '{source,time_freshness,refresh_window_ms}')::bigint,
    statement_timestamp()
  ) AS freshness_state,
  revision.definition #>> '{source,time_freshness,on_overdue}' AS overdue_policy,
  COALESCE(NOT materialization.stale, false) AS time_readable,
  materialization.stale_reason,
  freshness.acknowledged_at,
  freshness.attempted_at,
  reconciliation.reconciliation_reason,
  reconciliation.generation AS reconciliation_generation,
  reconciliation.state AS reconciliation_state,
  reconciliation.attempts AS reconciliation_attempts,
  reconciliation.next_attempt_at AS reconciliation_next_attempt_at
FROM otlet.watch_time_freshness freshness
JOIN otlet.watches watch ON watch.name = freshness.watch_name
JOIN otlet.tasks task ON task.name = freshness.task_name
LEFT JOIN otlet.workload_revision_heads head ON head.task_name = freshness.task_name
JOIN otlet.workload_revisions revision
  ON revision.task_name = freshness.task_name
 AND revision.workload_revision_hash = freshness.workload_revision_hash
LEFT JOIN otlet.semantic_materializations_effective materialization
  ON materialization.id = freshness.materialization_id
LEFT JOIN otlet.watch_reconciliation reconciliation
  ON reconciliation.watch_name = freshness.watch_name
 AND reconciliation.subject_id = freshness.subject_id
 AND reconciliation.workload_revision_hash = freshness.workload_revision_hash
 AND reconciliation.reconciliation_reason = 'time_refresh'
 AND reconciliation.time_expires_at = freshness.expires_at
WHERE (
    task.lifecycle_state = 'active'
    AND head.active_workload_revision_hash = freshness.workload_revision_hash
  )
  OR (
    task.lifecycle_state = 'paused'
    AND task.lifecycle_revision_hash = freshness.workload_revision_hash
  );

CREATE OR REPLACE VIEW otlet.watch_reconciliation_status AS
SELECT
  reconciliation.watch_name,
  watch.kind,
  watch.task_name,
  reconciliation.subject_id,
  reconciliation.workload_revision_hash,
  reconciliation.source_identity,
  reconciliation.source_deleted,
  reconciliation.generation,
  reconciliation.state,
  reconciliation.attempts,
  reconciliation.attempt_limit,
  reconciliation.first_dirty_at,
  reconciliation.last_dirty_at,
  reconciliation.last_attempt_at,
  reconciliation.next_attempt_at,
  reconciliation.last_error,
  GREATEST(clock_timestamp() - reconciliation.first_dirty_at, interval '0') AS pending_age,
  reconciliation.state = 'pending'
    AND reconciliation.next_attempt_at <= clock_timestamp() AS retry_due,
  reconciliation.reconciliation_reason,
  reconciliation.time_expires_at
FROM otlet.watch_reconciliation reconciliation
JOIN otlet.watches watch ON watch.name = reconciliation.watch_name;

CREATE FUNCTION otlet.semantic_row_subject_input(
  workload_revision_hash text,
  subject_id text
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  revision_definition jsonb;
  source_table text;
  subject_column text;
  input_columns text[];
  current_input jsonb;
BEGIN
  SELECT revision.definition
  INTO revision_definition
  FROM otlet.workload_revisions revision
  WHERE revision.workload_revision_hash =
      semantic_row_subject_input.workload_revision_hash
    AND revision.definition #>> '{source,kind}' = 'row';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision does not define a row source';
  END IF;

  PERFORM otlet.require_workload_source_contract(
    revision_definition #>> '{task,name}',
    semantic_row_subject_input.workload_revision_hash,
    false
  );
  source_table := revision_definition #>> '{source,source_table}';
  subject_column := revision_definition #>> '{source,subject_column}';
  SELECT array_agg(value ORDER BY ordinal)
  INTO input_columns
  FROM jsonb_array_elements_text(
    COALESCE(revision_definition #> '{source,input_columns}', '[]'::jsonb)
  ) WITH ORDINALITY field(value, ordinal);

  EXECUTE format(
    $sql$
      SELECT jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', %2$L,
          'subject_id', (source.%1$I)::text,
          'ctid', source.ctid::text,
          'xmin', source.xmin::text
        ),
        'table', %2$L,
        'row', otlet.semantic_project_row(to_jsonb(source), %3$L::text[])
      )
      FROM %4$s source
      WHERE (source.%1$I)::text = $1
    $sql$,
    subject_column,
    source_table,
    input_columns,
    source_table
  ) INTO current_input USING semantic_row_subject_input.subject_id;
  RETURN current_input;
END;
$$;

CREATE FUNCTION otlet.seed_watch_time_reconciliation() RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  candidate record;
  inserted_rows bigint;
BEGIN
  SELECT
    freshness.*,
    CASE WHEN freshness.expires_at <= statement_timestamp()
      THEN 'time_expired'
      ELSE 'refresh_due'
    END AS freshness_state
  INTO candidate
  FROM otlet.watch_time_freshness freshness
  JOIN otlet.watches watch ON watch.name = freshness.watch_name
  JOIN otlet.tasks task
    ON task.name = freshness.task_name
   AND task.lifecycle_state = 'active'
  JOIN otlet.workload_revision_heads head
    ON head.task_name = freshness.task_name
   AND head.active_workload_revision_hash = freshness.workload_revision_hash
  JOIN otlet.workload_revisions revision
    ON revision.task_name = freshness.task_name
   AND revision.workload_revision_hash = freshness.workload_revision_hash
  JOIN otlet.semantic_materializations materialization
    ON materialization.id = freshness.materialization_id
  WHERE freshness.acknowledged_at IS NULL
    AND freshness.attempted_at IS NULL
    AND freshness.refresh_due_at <= statement_timestamp()
    AND revision.definition #>> '{source,kind}' = 'row'
    AND revision.definition #>> '{source,time_freshness,on_overdue}' = 'reconcile'
    AND freshness.source_identity IS NOT NULL
    AND NOT materialization.stale
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.watch_reconciliation reconciliation
      WHERE reconciliation.watch_name = freshness.watch_name
        AND reconciliation.subject_id = freshness.subject_id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.jobs job
      WHERE job.task_name = freshness.task_name
        AND job.workload_revision_hash = freshness.workload_revision_hash
        AND job.subject_id = freshness.subject_id
        AND job.execution_mode = 'production'
        AND otlet.semantic_content_hash(
          job.input,
          revision.definition #> '{task,input_shaping}'
        ) = materialization.content_hash
        AND (
          job.status IN ('queued', 'running', 'cancel_requested')
          OR job.created_at >= freshness.refresh_due_at
        )
    )
  ORDER BY
    (freshness.expires_at <= statement_timestamp()) DESC,
    freshness.refresh_due_at,
    freshness.watch_name,
    freshness.subject_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN 'idle';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || candidate.task_name, 0)
  );

  SELECT
    freshness.*,
    CASE WHEN freshness.expires_at <= statement_timestamp()
      THEN 'time_expired'
      ELSE 'refresh_due'
    END AS freshness_state
  INTO candidate
  FROM otlet.watch_time_freshness freshness
  JOIN otlet.watches watch ON watch.name = freshness.watch_name
  JOIN otlet.tasks task
    ON task.name = freshness.task_name
   AND task.lifecycle_state = 'active'
  JOIN otlet.workload_revision_heads head
    ON head.task_name = freshness.task_name
   AND head.active_workload_revision_hash = freshness.workload_revision_hash
  JOIN otlet.workload_revisions revision
    ON revision.task_name = freshness.task_name
   AND revision.workload_revision_hash = freshness.workload_revision_hash
  JOIN otlet.semantic_materializations materialization
    ON materialization.id = freshness.materialization_id
  WHERE freshness.watch_name = candidate.watch_name
    AND freshness.workload_revision_hash = candidate.workload_revision_hash
    AND freshness.subject_id = candidate.subject_id
    AND freshness.materialization_id = candidate.materialization_id
    AND freshness.expires_at = candidate.expires_at
    AND freshness.acknowledged_at IS NULL
    AND freshness.attempted_at IS NULL
    AND freshness.refresh_due_at <= statement_timestamp()
    AND revision.definition #>> '{source,kind}' = 'row'
    AND revision.definition #>> '{source,time_freshness,on_overdue}' = 'reconcile'
    AND freshness.source_identity IS NOT NULL
    AND NOT materialization.stale
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.watch_reconciliation reconciliation
      WHERE reconciliation.watch_name = freshness.watch_name
        AND reconciliation.subject_id = freshness.subject_id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.jobs job
      WHERE job.task_name = freshness.task_name
        AND job.workload_revision_hash = freshness.workload_revision_hash
        AND job.subject_id = freshness.subject_id
        AND job.execution_mode = 'production'
        AND otlet.semantic_content_hash(
          job.input,
          revision.definition #> '{task,input_shaping}'
        ) = materialization.content_hash
        AND (
          job.status IN ('queued', 'running', 'cancel_requested')
          OR job.created_at >= freshness.refresh_due_at
        )
    )
  FOR UPDATE OF freshness;

  IF NOT FOUND THEN
    RETURN 'idle';
  END IF;

  INSERT INTO otlet.watch_reconciliation (
    watch_name,
    subject_id,
    workload_revision_hash,
    source_identity,
    source_deleted,
    attempt_limit,
    reconciliation_reason,
    time_expires_at
  )
  SELECT
    candidate.watch_name,
    candidate.subject_id,
    candidate.workload_revision_hash,
    candidate.source_identity,
    false,
    policy.watch_reconciliation_max_attempts,
    'time_refresh',
    candidate.expires_at
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  ON CONFLICT ON CONSTRAINT watch_reconciliation_pkey DO NOTHING;
  GET DIAGNOSTICS inserted_rows = ROW_COUNT;

  IF inserted_rows = 0 THEN
    RETURN 'idle';
  END IF;
  PERFORM otlet.wake_worker();
  RETURN candidate.freshness_state;
END;
$$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.reconcile_watch_subject(text,text,boolean)'::regprocedure
  );

  old_fragment := $old$  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || watch_row.task_name, 0)
  );

  SELECT *
  INTO pending
  FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = reconcile_watch_subject.watch_name
    AND reconciliation.subject_id = reconcile_watch_subject.subject_id
  FOR UPDATE;$old$;
  new_fragment := $new$  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || watch_row.task_name, 0)
  );
  IF observed.reconciliation_reason = 'time_refresh' THEN
    PERFORM 1
    FROM otlet.watch_time_freshness freshness
    WHERE freshness.watch_name = observed.watch_name
      AND freshness.workload_revision_hash = observed.workload_revision_hash
      AND freshness.subject_id = observed.subject_id
      AND freshness.expires_at = observed.time_expires_at
    FOR UPDATE;
  END IF;

  SELECT *
  INTO pending
  FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = reconcile_watch_subject.watch_name
    AND reconciliation.subject_id = reconcile_watch_subject.subject_id
  FOR UPDATE;$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet time reconciliation lock-order rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$IF NOT FOUND
     OR watch_row.kind <> 'row'
     OR COALESCE(watch_row.trigger_policy ->> 'on_change', 'mark_stale') <> 'mark_stale_and_enqueue' THEN$old$;
  new_fragment := $new$IF NOT FOUND
     OR (
       pending.reconciliation_reason <> 'time_refresh'
       AND (
         watch_row.kind <> 'row'
         OR COALESCE(watch_row.trigger_policy ->> 'on_change', 'mark_stale') <>
           'mark_stale_and_enqueue'
       )
     ) THEN$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet time reconciliation authorization rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$    RETURN 'disabled';
  END IF;

  SELECT head.active_workload_revision_hash, revision.definition$old$;
  new_fragment := $new$    RETURN 'disabled';
  END IF;
  IF pending.reconciliation_reason = 'time_refresh'
     AND EXISTS (
       SELECT 1
       FROM otlet.tasks task
       WHERE task.name = watch_row.task_name
         AND task.lifecycle_state = 'paused'
     ) THEN
    RETURN 'paused';
  END IF;

  SELECT head.active_workload_revision_hash, revision.definition$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet time reconciliation pause rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  IF NOT FOUND THEN
    retry_error := 'watch workload revision is missing';
  END IF;

  IF COALESCE(reconcile_watch_subject.force_replay, false)$old$;
  new_fragment := $new$  IF NOT FOUND THEN
    retry_error := 'watch workload revision is missing';
  END IF;
  IF pending.reconciliation_reason = 'time_refresh'
     AND (
       pending.workload_revision_hash IS DISTINCT FROM active_revision_hash
       OR revision_definition #>> '{source,kind}' IS DISTINCT FROM 'row'
       OR revision_definition #>> '{source,time_freshness,on_overdue}' IS DISTINCT FROM 'reconcile'
     ) THEN
    DELETE FROM otlet.watch_reconciliation reconciliation
    WHERE reconciliation.watch_name = pending.watch_name
      AND reconciliation.subject_id = pending.subject_id
      AND reconciliation.generation = pending.generation;
    RETURN 'superseded';
  END IF;

  IF COALESCE(reconcile_watch_subject.force_replay, false)$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet time reconciliation revision fence rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  IF COALESCE(reconcile_watch_subject.force_replay, false)
     AND pending.state = 'exhausted' THEN$old$;
  new_fragment := $new$  IF pending.reconciliation_reason = 'time_refresh'
     AND EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness freshness
       WHERE freshness.watch_name = pending.watch_name
         AND freshness.workload_revision_hash = pending.workload_revision_hash
         AND freshness.subject_id = pending.subject_id
         AND freshness.expires_at = pending.time_expires_at
         AND freshness.attempted_at IS NOT NULL
     ) THEN
    DELETE FROM otlet.watch_reconciliation reconciliation
    WHERE reconciliation.watch_name = pending.watch_name
      AND reconciliation.subject_id = pending.subject_id
      AND reconciliation.generation = pending.generation;
    RETURN 'existing_job';
  END IF;

  IF COALESCE(reconcile_watch_subject.force_replay, false)
     AND pending.state = 'exhausted' THEN$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet time reconciliation attempt-marker rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      pending_input := otlet.task_subject_input(
        revision_definition #>> '{task,input_query}',
        pending.subject_id,
        revision_definition
      );$old$;
  new_fragment := $new$      IF pending.reconciliation_reason = 'time_refresh' THEN
        pending_input := otlet.semantic_row_subject_input(
          active_revision_hash,
          pending.subject_id
        );
      ELSE
        pending_input := otlet.task_subject_input(
          revision_definition #>> '{task,input_query}',
          pending.subject_id,
          revision_definition
        );
      END IF;$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet time reconciliation row input rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  SELECT EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations materialization
    WHERE materialization.task_name = watch_row.task_name
      AND materialization.record_type = watch_row.record_type
      AND materialization.subject_id = pending.subject_id
      AND materialization.contract_hash = active_revision_hash
      AND materialization.content_hash = current_content_hash
      AND NOT materialization.stale
  ) INTO fresh_current;$old$;
  new_fragment := $new$  SELECT EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations_effective materialization
    WHERE materialization.task_name = watch_row.task_name
      AND materialization.record_type = CASE
        WHEN pending.reconciliation_reason = 'time_refresh'
          THEN revision_definition #>> '{source,record_type}'
        ELSE watch_row.record_type
      END
      AND materialization.subject_id = pending.subject_id
      AND materialization.contract_hash = active_revision_hash
      AND materialization.content_hash = current_content_hash
      AND NOT materialization.stale
      AND (
        pending.reconciliation_reason <> 'time_refresh'
        OR otlet.semantic_time_freshness_state(
          materialization.updated_at,
          NULLIF(revision_definition #>> '{source,time_freshness,max_age_ms}', '')::bigint,
          COALESCE(NULLIF(
            revision_definition #>> '{source,time_freshness,refresh_window_ms}',
            ''
          )::bigint, 0),
          statement_timestamp()
        ) IN ('disabled', 'fresh')
      )
  ) INTO fresh_current;$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet time reconciliation freshness rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      watch_row.source_table,
      pending.subject_id,
      'source_delete'$old$;
  new_fragment := $new$      CASE
        WHEN pending.reconciliation_reason = 'time_refresh'
          THEN revision_definition #>> '{source,source_table}'
        ELSE watch_row.source_table
      END,
      pending.subject_id,
      'source_delete'$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet time reconciliation source-delete rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  IF current_deleted THEN$old$;
  new_fragment := $new$  IF pending.reconciliation_reason = 'time_refresh'
     AND EXISTS (
       SELECT 1
       FROM otlet.jobs job
       WHERE job.task_name = watch_row.task_name
         AND job.workload_revision_hash = active_revision_hash
         AND job.subject_id = pending.subject_id
         AND job.execution_mode = 'production'
         AND otlet.semantic_content_hash(
           job.input,
           revision_definition #> '{task,input_shaping}'
         ) = current_content_hash
         AND (
           job.status IN ('queued', 'running', 'cancel_requested')
           OR job.created_at >= pending.time_expires_at
             - COALESCE(NULLIF(
                 revision_definition #>> '{source,time_freshness,refresh_window_ms}',
                 ''
               )::bigint, 0) * interval '1 millisecond'
         )
     ) THEN
    UPDATE otlet.watch_time_freshness freshness
    SET attempted_at = clock_timestamp()
    WHERE freshness.watch_name = pending.watch_name
      AND freshness.workload_revision_hash = pending.workload_revision_hash
      AND freshness.subject_id = pending.subject_id
      AND freshness.expires_at = pending.time_expires_at;
    DELETE FROM otlet.watch_reconciliation reconciliation
    WHERE reconciliation.watch_name = pending.watch_name
      AND reconciliation.subject_id = pending.subject_id
      AND reconciliation.generation = pending.generation;
    RETURN 'existing_job';
  END IF;

  IF current_deleted THEN$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet time reconciliation terminal-job rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  EXECUTE definition;
END;
$migration$;

CREATE OR REPLACE FUNCTION otlet.replay_watch_reconciliation(
  include_exhausted boolean DEFAULT false
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  candidate record;
BEGIN
  SELECT reconciliation.watch_name, reconciliation.subject_id
  INTO candidate
  FROM otlet.watch_reconciliation reconciliation
  LEFT JOIN otlet.watches watch ON watch.name = reconciliation.watch_name
  LEFT JOIN otlet.tasks task ON task.name = watch.task_name
  WHERE (watch.name IS NULL OR task.lifecycle_state = 'active')
    AND (
      (
        reconciliation.state = 'pending'
        AND reconciliation.next_attempt_at <= clock_timestamp()
      )
      OR (
        COALESCE(replay_watch_reconciliation.include_exhausted, false)
        AND reconciliation.state = 'exhausted'
      )
    )
  ORDER BY
    CASE reconciliation.state WHEN 'pending' THEN 0 ELSE 1 END,
    reconciliation.next_attempt_at NULLS LAST,
    reconciliation.first_dirty_at,
    reconciliation.watch_name,
    reconciliation.subject_id
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM otlet.seed_watch_time_reconciliation();
    SELECT reconciliation.watch_name, reconciliation.subject_id
    INTO candidate
    FROM otlet.watch_reconciliation reconciliation
    JOIN otlet.watches watch ON watch.name = reconciliation.watch_name
    JOIN otlet.tasks task
      ON task.name = watch.task_name
     AND task.lifecycle_state = 'active'
    WHERE reconciliation.state = 'pending'
      AND reconciliation.next_attempt_at <= clock_timestamp()
    ORDER BY
      reconciliation.next_attempt_at,
      reconciliation.first_dirty_at,
      reconciliation.watch_name,
      reconciliation.subject_id
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RETURN 'idle';
  END IF;
  RETURN otlet.reconcile_watch_subject(
    candidate.watch_name,
    candidate.subject_id,
    COALESCE(replay_watch_reconciliation.include_exhausted, false)
  );
END;
$$;

CREATE OR REPLACE FUNCTION otlet.acknowledge_watch_reconciliation(
  watch_name text,
  subject_id text,
  expected_generation bigint
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  pending otlet.watch_reconciliation%ROWTYPE;
  task_name text;
  removed bigint;
BEGIN
  SELECT watch.task_name
  INTO task_name
  FROM otlet.watch_reconciliation reconciliation
  JOIN otlet.watches watch ON watch.name = reconciliation.watch_name
  WHERE reconciliation.watch_name = acknowledge_watch_reconciliation.watch_name
    AND reconciliation.subject_id = acknowledge_watch_reconciliation.subject_id
    AND reconciliation.generation = acknowledge_watch_reconciliation.expected_generation;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || task_name, 0)
  );
  SELECT *
  INTO pending
  FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = acknowledge_watch_reconciliation.watch_name
    AND reconciliation.subject_id = acknowledge_watch_reconciliation.subject_id
    AND reconciliation.generation = acknowledge_watch_reconciliation.expected_generation;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF pending.reconciliation_reason = 'time_refresh' THEN
    PERFORM 1
    FROM otlet.watch_time_freshness freshness
    WHERE freshness.watch_name = pending.watch_name
      AND freshness.workload_revision_hash = pending.workload_revision_hash
      AND freshness.subject_id = pending.subject_id
      AND freshness.expires_at = pending.time_expires_at
    FOR UPDATE;
  END IF;

  SELECT *
  INTO pending
  FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = acknowledge_watch_reconciliation.watch_name
    AND reconciliation.subject_id = acknowledge_watch_reconciliation.subject_id
    AND reconciliation.generation = acknowledge_watch_reconciliation.expected_generation
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF pending.reconciliation_reason = 'time_refresh' THEN
    UPDATE otlet.watch_time_freshness freshness
    SET acknowledged_at = clock_timestamp()
    WHERE freshness.watch_name = pending.watch_name
      AND freshness.workload_revision_hash = pending.workload_revision_hash
      AND freshness.subject_id = pending.subject_id
      AND freshness.expires_at = pending.time_expires_at;
  END IF;

  DELETE FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = pending.watch_name
    AND reconciliation.subject_id = pending.subject_id
    AND reconciliation.generation = pending.generation;
  GET DIAGNOSTICS removed = ROW_COUNT;
  RETURN removed > 0;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.semantic_join_refresh_inputs(
  index_name text,
  workload_revision_hash text DEFAULT NULL
) RETURNS TABLE (
  subject_id text,
  input jsonb
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
  revision_definition jsonb;
  requested_revision_hash text := semantic_join_refresh_inputs.workload_revision_hash;
BEGIN
  IF requested_revision_hash IS NULL THEN
    SELECT head.active_workload_revision_hash
    INTO requested_revision_hash
    FROM otlet.workload_revision_heads head
    JOIN otlet.workload_revisions revision
      ON revision.task_name = head.task_name
     AND revision.workload_revision_hash = head.active_workload_revision_hash
    WHERE revision.definition #>> '{source,semantic_join_index_name}' =
      semantic_join_refresh_inputs.index_name
      AND revision.definition #>> '{source,kind}' = 'pair';
  END IF;

  SELECT revision.definition
  INTO revision_definition
  FROM otlet.workload_revisions revision
  JOIN otlet.workload_revision_heads head
    ON head.task_name = revision.task_name
   AND head.active_workload_revision_hash = revision.workload_revision_hash
  WHERE revision.workload_revision_hash = requested_revision_hash
    AND revision.definition #>> '{source,semantic_join_index_name}' =
      semantic_join_refresh_inputs.index_name
    AND revision.definition #>> '{source,kind}' = 'pair';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet active workload revision does not define semantic join index %',
      semantic_join_refresh_inputs.index_name;
  END IF;

  index_row.name := revision_definition #>> '{source,semantic_join_index_name}';
  index_row.task_name := revision_definition #>> '{task,name}';
  index_row.record_type := revision_definition #>> '{source,record_type}';
  current_input_shaping := revision_definition #> '{task,input_shaping}';
  current_contract_hash := requested_revision_hash;

  RETURN QUERY EXECUTE format(
    $sql$
      WITH current_inputs AS MATERIALIZED (
        SELECT
          candidate.subject_id,
          candidate.input,
          otlet.semantic_content_hash(candidate.input, %6$L::jsonb) AS content_hash
        FROM otlet.semantic_join_candidate_rows(%1$L, %2$L) candidate
      ),
      candidate_materializations AS (
        SELECT
          sm.id,
          sm.content_hash AS material_content_hash,
          sm.contract_hash AS material_contract_hash,
          sm.stale AS material_stale,
          sm.stale_reason,
          sm.updated_at AS material_updated_at,
          sm.correction_status,
          ci.subject_id AS current_subject_id,
          ci.content_hash AS current_content_hash,
          (
            sm.stale_reason IS NULL
            OR sm.stale_reason IN (
              'source_update',
              'content_revalidation_pending',
              'candidate_removed',
              'candidate_changed'
            )
          ) AS replace_reason
        FROM current_inputs ci
        FULL JOIN otlet.semantic_materializations_effective sm
          ON sm.task_name = %3$L
         AND sm.record_type = %4$L
         AND sm.subject_id = ci.subject_id
         AND sm.contract_hash = %5$L
        WHERE ci.subject_id IS NOT NULL
           OR (
             sm.task_name = %3$L
             AND sm.record_type = %4$L
             AND sm.contract_hash = %5$L
           )
      ),
      candidate_states AS (
        SELECT
          id,
          CASE
            WHEN current_subject_id IS NULL AND replace_reason THEN 'candidate_removed'
            WHEN current_content_hash IS DISTINCT FROM material_content_hash AND replace_reason
              THEN 'candidate_changed'
            WHEN current_content_hash IS NOT DISTINCT FROM material_content_hash
              AND stale_reason IN ('candidate_removed', 'candidate_changed')
              THEN 'candidate_restored'
            ELSE NULL
          END AS transition
        FROM candidate_materializations
        WHERE id IS NOT NULL
      ),
      reconciled AS (
        UPDATE otlet.semantic_materializations sm
        SET stale = state.transition <> 'candidate_restored',
            stale_reason = CASE
              WHEN state.transition = 'candidate_restored' THEN NULL
              ELSE state.transition
            END,
            freshness_basis = CASE
              WHEN state.transition = 'candidate_restored' THEN 'content_hash_match'
              ELSE sm.freshness_basis
            END,
            updated_at = now()
        FROM candidate_states state
        WHERE sm.id = state.id
          AND state.transition IS NOT NULL
          AND sm.stale_reason IS DISTINCT FROM 'contract_changed'
          AND (
            sm.stale IS DISTINCT FROM (state.transition <> 'candidate_restored')
            OR sm.stale_reason IS DISTINCT FROM CASE
              WHEN state.transition = 'candidate_restored' THEN NULL
              ELSE state.transition
            END
          )
        RETURNING sm.id
      ),
      matched_inputs AS (
        SELECT DISTINCT candidate.current_subject_id AS subject_id
        FROM candidate_materializations candidate
        LEFT JOIN candidate_states state ON state.id = candidate.id
        WHERE candidate.current_subject_id IS NOT NULL
          AND candidate.material_content_hash = candidate.current_content_hash
          AND candidate.material_contract_hash = %5$L
          AND (
            candidate.correction_status IS NOT NULL
            OR (
              (NOT candidate.material_stale OR state.transition = 'candidate_restored')
              AND otlet.semantic_time_freshness_state(
                candidate.material_updated_at,
                NULLIF(
                  (%7$L::jsonb) #>> '{source,time_freshness,max_age_ms}',
                  ''
                )::bigint,
                COALESCE(NULLIF(
                  (%7$L::jsonb) #>> '{source,time_freshness,refresh_window_ms}',
                  ''
                )::bigint, 0),
                statement_timestamp()
              ) IN ('disabled', 'fresh')
            )
          )
      )
      SELECT ci.subject_id, ci.input
      FROM current_inputs ci
      WHERE NOT EXISTS (
        SELECT 1
        FROM matched_inputs matched
        WHERE matched.subject_id = ci.subject_id
      )
      ORDER BY ci.subject_id COLLATE "C"
    $sql$,
    index_row.name,
    current_contract_hash,
    index_row.task_name,
    index_row.record_type,
    current_contract_hash,
    current_input_shaping,
    revision_definition
  );
END;
$$;

DO $migration$
DECLARE
  target regclass;
  definition text;
BEGIN
  FOREACH target IN ARRAY ARRAY[
    'otlet.production_status'::regclass,
    'otlet.workload_revision_status'::regclass,
    'otlet.watch_status'::regclass,
    'otlet.semantic_index_status'::regclass,
    'otlet.semantic_dependency_audit'::regclass
  ]
  LOOP
    definition := pg_catalog.pg_get_viewdef(target, true);
    IF position('otlet.semantic_materializations' IN definition) = 0 THEN
      RAISE EXCEPTION 'otlet time-freshness status rewrite is incomplete for %', target;
    END IF;
    IF target = 'otlet.production_status'::regclass THEN
      definition := pg_catalog.replace(
        definition,
        'FROM otlet.semantic_materializations',
        'FROM otlet.semantic_materializations_effective semantic_materializations'
      );
    ELSE
      definition := pg_catalog.replace(
        definition,
        'otlet.semantic_materializations',
        'otlet.semantic_materializations_effective'
      );
    END IF;
    EXECUTE 'CREATE OR REPLACE VIEW ' || target::text || ' AS ' || definition;
  END LOOP;
END;
$migration$;

CREATE FUNCTION otlet.verify_time_freshness_invariants()
RETURNS TABLE (
  invariant_name text,
  object_type text,
  object_id text,
  detail jsonb
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    'time_freshness_deadline_matches_evidence'::text,
    'watch_time_freshness'::text,
    freshness.watch_name || ':' || freshness.subject_id,
    jsonb_build_object(
      'task_name', freshness.task_name,
      'workload_revision_hash', freshness.workload_revision_hash,
      'materialization_id', freshness.materialization_id,
      'anchor_identity', freshness.anchor_identity
    )
  FROM otlet.watch_time_freshness freshness
  LEFT JOIN otlet.watches watch ON watch.name = freshness.watch_name
  LEFT JOIN otlet.workload_revisions revision
    ON revision.task_name = freshness.task_name
   AND revision.workload_revision_hash = freshness.workload_revision_hash
  LEFT JOIN otlet.semantic_materializations materialization
    ON materialization.id = freshness.materialization_id
  LEFT JOIN otlet.semantic_materializations_effective effective_materialization
    ON effective_materialization.id = freshness.materialization_id
  LEFT JOIN otlet.records record ON record.id = materialization.record_id
  LEFT JOIN otlet.actions action ON action.id = record.action_id
  LEFT JOIN otlet.outputs output ON output.id = action.output_id
  LEFT JOIN otlet.inference_receipts receipt ON receipt.id = output.receipt_id
  WHERE watch.name IS NULL
     OR watch.task_name IS DISTINCT FROM freshness.task_name
     OR revision.definition #>> '{source,watch_name}' IS DISTINCT FROM freshness.watch_name
     OR revision.definition #> '{source,time_freshness}' IS NULL
     OR materialization.task_name IS DISTINCT FROM freshness.task_name
     OR materialization.contract_hash IS DISTINCT FROM freshness.workload_revision_hash
     OR materialization.subject_id IS DISTINCT FROM freshness.subject_id
     OR materialization.source_hash IS DISTINCT FROM freshness.source_identity
     OR effective_materialization.correction_status IS NOT NULL
     OR freshness.refresh_due_at IS DISTINCT FROM freshness.refreshed_at
       + (
         (revision.definition #>> '{source,time_freshness,max_age_ms}')::bigint
         - (revision.definition #>> '{source,time_freshness,refresh_window_ms}')::bigint
       ) * interval '1 millisecond'
     OR freshness.expires_at IS DISTINCT FROM freshness.refreshed_at
       + (revision.definition #>> '{source,time_freshness,max_age_ms}')::bigint
         * interval '1 millisecond'
     OR freshness.anchor_identity IS DISTINCT FROM
       'materialization:' || freshness.materialization_id::text
     OR freshness.refreshed_at IS DISTINCT FROM
       COALESCE(receipt.finished_at, materialization.created_at)

  UNION ALL

  SELECT
    'time_freshness_deadline_is_current'::text,
    'watch_time_freshness'::text,
    freshness.watch_name || ':' || freshness.subject_id,
    jsonb_build_object(
      'materialization_id', freshness.materialization_id,
      'refreshed_at', freshness.refreshed_at
    )
  FROM otlet.watch_time_freshness freshness
  JOIN otlet.workload_revisions revision
    ON revision.task_name = freshness.task_name
   AND revision.workload_revision_hash = freshness.workload_revision_hash
  WHERE EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations_effective materialization
    WHERE materialization.task_name = freshness.task_name
      AND materialization.record_type = revision.definition #>> '{source,record_type}'
      AND materialization.contract_hash = freshness.workload_revision_hash
      AND materialization.subject_id = freshness.subject_id
      AND (materialization.updated_at, materialization.id) >
        (freshness.refreshed_at, freshness.materialization_id)
  )

  UNION ALL

  SELECT
    'time_reconciliation_uses_pinned_reconcile_policy'::text,
    'watch_reconciliation'::text,
    reconciliation.watch_name || ':' || reconciliation.subject_id,
    jsonb_build_object(
      'workload_revision_hash', reconciliation.workload_revision_hash,
      'time_expires_at', reconciliation.time_expires_at,
      'watch_kind', revision.definition #>> '{source,kind}',
      'task_state', task.lifecycle_state,
      'on_overdue', revision.definition #>> '{source,time_freshness,on_overdue}'
    )
  FROM otlet.watch_reconciliation reconciliation
  LEFT JOIN otlet.watches watch ON watch.name = reconciliation.watch_name
  LEFT JOIN otlet.tasks task ON task.name = watch.task_name
  LEFT JOIN otlet.workload_revisions revision
    ON revision.task_name = watch.task_name
   AND revision.workload_revision_hash = reconciliation.workload_revision_hash
  LEFT JOIN otlet.watch_time_freshness freshness
    ON freshness.watch_name = reconciliation.watch_name
   AND freshness.workload_revision_hash = reconciliation.workload_revision_hash
   AND freshness.subject_id = reconciliation.subject_id
   AND freshness.expires_at = reconciliation.time_expires_at
  WHERE reconciliation.reconciliation_reason = 'time_refresh'
    AND (
      watch.name IS NULL
      OR watch.task_name IS DISTINCT FROM revision.task_name
      OR task.lifecycle_state IS NULL
      OR task.lifecycle_state NOT IN ('active', 'paused')
      OR revision.definition #>> '{source,kind}' IS DISTINCT FROM 'row'
      OR revision.definition #>> '{source,time_freshness,on_overdue}' IS DISTINCT FROM
        'reconcile'
      OR freshness.watch_name IS NULL
      OR freshness.acknowledged_at IS NOT NULL
    )

  UNION ALL

  SELECT
    'time_expired_materialization_is_closed'::text,
    'semantic_materialization'::text,
    freshness.materialization_id::text,
    jsonb_build_object(
      'watch_name', freshness.watch_name,
      'subject_id', freshness.subject_id,
      'expires_at', freshness.expires_at,
      'stale_reason', materialization.stale_reason
    )
  FROM otlet.watch_time_freshness freshness
  JOIN otlet.semantic_materializations_effective materialization
    ON materialization.id = freshness.materialization_id
  WHERE freshness.expires_at <= statement_timestamp()
    AND NOT materialization.stale

  UNION ALL

  SELECT
    'completed_time_deadline_has_no_reconciliation'::text,
    'watch_time_freshness'::text,
    freshness.watch_name || ':' || freshness.subject_id,
    jsonb_build_object(
      'acknowledged_at', freshness.acknowledged_at,
      'attempted_at', freshness.attempted_at,
      'generation', reconciliation.generation
    )
  FROM otlet.watch_time_freshness freshness
  JOIN otlet.watch_reconciliation reconciliation
    ON reconciliation.watch_name = freshness.watch_name
   AND reconciliation.subject_id = freshness.subject_id
   AND reconciliation.reconciliation_reason = 'time_refresh'
   AND reconciliation.time_expires_at = freshness.expires_at
  WHERE freshness.acknowledged_at IS NOT NULL
     OR freshness.attempted_at IS NOT NULL;
$$;

ALTER FUNCTION otlet.verify_invariants(integer)
RENAME TO verify_core_invariants;

CREATE FUNCTION otlet.verify_invariants(sample_limit integer DEFAULT NULL)
RETURNS TABLE (
  invariant_name text,
  object_type text,
  object_id text,
  detail jsonb
)
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT invariant.*
  FROM otlet.verify_core_invariants(verify_invariants.sample_limit) invariant;

  RETURN QUERY
  SELECT invariant.*
  FROM otlet.verify_time_freshness_invariants() invariant;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.finish_access_policy_grant(
  policy_name text,
  target_role regrole,
  old_revision_hash text
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text;
  new_revision_hash text;
BEGIN
  SELECT role.rolname
  INTO role_name
  FROM pg_catalog.pg_roles role
  WHERE role.oid = finish_access_policy_grant.target_role::oid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'role with oid % does not exist',
      finish_access_policy_grant.target_role::oid;
  END IF;

  IF finish_access_policy_grant.policy_name IN ('auditor', 'operator') THEN
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE '
      'otlet.audit_administrative_change_export, '
      'otlet.audit_semantic_correction_export, '
      'otlet.audit_decision_evidence_export, '
      'otlet.audit_review_sample_export, '
      'otlet.audit_reviewer_calibration_export TO %I',
      role_name
    );
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.entity_graph_conflict_status_for_task(text), '
      'otlet.semantic_correction_status_for_task(text), '
      'otlet.pair_constraint_contract_hash(jsonb), '
      'otlet.reviewer_calibration_state(text), '
      'otlet.semantic_time_freshness_state('
      'timestamptz,bigint,bigint,timestamptz) TO %I',
      role_name
    );
  END IF;
  IF finish_access_policy_grant.policy_name = 'operator' THEN
    EXECUTE pg_catalog.format(
      'REVOKE EXECUTE ON FUNCTION '
      'otlet.approve_action(bigint,text), '
      'otlet.reject_action(bigint,text,text), '
      'otlet.label_action(bigint,text,text,text,text,text), '
      'otlet.correct_action(bigint,jsonb,text), '
      'otlet.reviewer_correct_action(bigint,jsonb,text), '
      'otlet.defer_action(bigint,text), '
      'otlet.abstain_review(bigint,text), '
      'otlet.approve_semantic_correction('
      'bigint,bigint,jsonb,timestamptz,numeric,text,text), '
      'otlet.label_review_sample(bigint,text,text,text,text,text) FROM %I',
      role_name
    );
  ELSIF finish_access_policy_grant.policy_name = 'reviewer' THEN
    EXECUTE pg_catalog.format(
      'REVOKE EXECUTE ON FUNCTION '
      'otlet.correct_action(bigint,jsonb,text) FROM %I',
      role_name
    );
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE '
      'otlet.reviewer_review_queue, '
      'otlet.reviewer_calibration_queue, '
      'otlet.reviewer_calibration_status TO %I',
      role_name
    );
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.approve_action(bigint,text), '
      'otlet.reject_action(bigint,text,text), '
      'otlet.reviewer_correct_action(bigint,jsonb,text), '
      'otlet.defer_action(bigint,text), '
      'otlet.abstain_review(bigint,text), '
      'otlet.approve_semantic_correction('
      'bigint,bigint,jsonb,timestamptz,numeric,text,text), '
      'otlet.label_review_sample(bigint,text,text,text,text,text), '
      'otlet.submit_reviewer_calibration(text,text,text,text,text), '
      'otlet.reviewer_calibration_state(text), '
      'otlet.reviewer_calibration_member_token(text,text), '
      'otlet.reviewer_review_queue_rows() TO %I',
      role_name
    );
  END IF;
  new_revision_hash := otlet.access_policy_revision(
    finish_access_policy_grant.target_role
  );
  PERFORM otlet.append_administrative_change(
    'access_policy',
    finish_access_policy_grant.policy_name || ':' || role_name,
    'grant',
    finish_access_policy_grant.old_revision_hash,
    new_revision_hash
  );
END;
$$;

DO $$
DECLARE
  role_name text;
BEGIN
  FOR role_name IN
    SELECT DISTINCT role.rolname
    FROM otlet.administrative_change_events event
    JOIN pg_catalog.pg_roles role
      ON role.rolname = substring(
        event.object_name FROM position(':' IN event.object_name) + 1
      )
    WHERE event.object_type = 'access_policy'
      AND split_part(event.object_name, ':', 1) IN ('auditor', 'operator')
      AND pg_catalog.has_table_privilege(
        role.oid,
        'otlet.audit_review_export',
        'SELECT'
      )
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.semantic_time_freshness_state('
      'timestamptz,bigint,bigint,timestamptz) TO %I',
      role_name
    );
  END LOOP;
END;
$$;

REVOKE ALL ON TABLE otlet.watch_time_freshness FROM PUBLIC;
REVOKE ALL ON TABLE otlet.watch_time_freshness_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.watch_trigger_policy_error(text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_watch_trigger_policy() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_workload_time_freshness() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.semantic_time_freshness_state(timestamptz, bigint, bigint, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_watch_time_freshness(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_materialization_time_freshness() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_correction_time_freshness() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_job_time_freshness_attempt() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.semantic_row_subject_input(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.seed_watch_time_reconciliation() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_time_freshness_invariants() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_core_invariants(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_invariants(integer) FROM PUBLIC;
