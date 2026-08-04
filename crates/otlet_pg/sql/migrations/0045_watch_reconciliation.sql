ALTER TABLE otlet.production_policy
  ADD COLUMN watch_reconciliation_max_attempts integer NOT NULL DEFAULT 12,
  ADD COLUMN watch_reconciliation_base_delay_ms integer NOT NULL DEFAULT 1000,
  ADD COLUMN watch_reconciliation_max_delay_ms integer NOT NULL DEFAULT 300000,
  ADD CONSTRAINT production_policy_watch_reconciliation_attempts_check
    CHECK (watch_reconciliation_max_attempts BETWEEN 1 AND 100),
  ADD CONSTRAINT production_policy_watch_reconciliation_base_delay_check
    CHECK (watch_reconciliation_base_delay_ms BETWEEN 1 AND 60000),
  ADD CONSTRAINT production_policy_watch_reconciliation_max_delay_check
    CHECK (
      watch_reconciliation_max_delay_ms BETWEEN watch_reconciliation_base_delay_ms AND 3600000
    );

CREATE SEQUENCE otlet.watch_reconciliation_generation_seq AS bigint;

CREATE TABLE otlet.watch_reconciliation (
  watch_name text NOT NULL,
  subject_id text NOT NULL,
  workload_revision_hash text NOT NULL REFERENCES otlet.workload_revisions(workload_revision_hash),
  source_identity text NOT NULL CHECK (
    source_identity ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  source_deleted boolean NOT NULL DEFAULT false,
  generation bigint NOT NULL DEFAULT nextval('otlet.watch_reconciliation_generation_seq')
    CHECK (generation > 0),
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'exhausted')),
  attempts integer NOT NULL DEFAULT 0,
  attempt_limit integer NOT NULL CHECK (attempt_limit BETWEEN 1 AND 100),
  first_dirty_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_dirty_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_attempt_at timestamptz,
  next_attempt_at timestamptz DEFAULT clock_timestamp(),
  last_error text,
  PRIMARY KEY (watch_name, subject_id),
  CHECK (attempts BETWEEN 0 AND attempt_limit),
  CHECK (
    (state = 'pending' AND attempts < attempt_limit AND next_attempt_at IS NOT NULL)
    OR
    (state = 'exhausted' AND attempts = attempt_limit AND next_attempt_at IS NULL)
  ),
  CHECK (last_dirty_at >= first_dirty_at)
);

ALTER SEQUENCE otlet.watch_reconciliation_generation_seq
OWNED BY otlet.watch_reconciliation.generation;

CREATE INDEX watch_reconciliation_due_idx
ON otlet.watch_reconciliation (state, next_attempt_at, first_dirty_at, watch_name, subject_id);

CREATE FUNCTION otlet.watch_source_delete_identity(
  watch_name text,
  subject_id text
) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
BEGIN ATOMIC
  SELECT otlet.identity_hash(
    'watch_source_delete',
    jsonb_build_object(
      'watch_name', watch_source_delete_identity.watch_name,
      'subject_id', watch_source_delete_identity.subject_id
    )
  );
END;

CREATE FUNCTION otlet.record_watch_reconciliation(
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
    attempt_limit
  )
  VALUES (
    record_watch_reconciliation.watch_name,
    record_watch_reconciliation.subject_id,
    record_watch_reconciliation.workload_revision_hash,
    record_watch_reconciliation.source_identity,
    COALESCE(record_watch_reconciliation.source_deleted, false),
    policy_attempt_limit
  )
  ON CONFLICT ON CONSTRAINT watch_reconciliation_pkey DO UPDATE
  SET workload_revision_hash = EXCLUDED.workload_revision_hash,
      source_identity = EXCLUDED.source_identity,
      source_deleted = EXCLUDED.source_deleted,
      generation = EXCLUDED.generation,
      state = CASE
        WHEN otlet.watch_reconciliation.workload_revision_hash IS DISTINCT FROM EXCLUDED.workload_revision_hash
          OR otlet.watch_reconciliation.source_identity IS DISTINCT FROM EXCLUDED.source_identity
          OR otlet.watch_reconciliation.source_deleted IS DISTINCT FROM EXCLUDED.source_deleted
          THEN 'pending'
        ELSE otlet.watch_reconciliation.state
      END,
      attempts = CASE
        WHEN otlet.watch_reconciliation.workload_revision_hash IS DISTINCT FROM EXCLUDED.workload_revision_hash
          OR otlet.watch_reconciliation.source_identity IS DISTINCT FROM EXCLUDED.source_identity
          OR otlet.watch_reconciliation.source_deleted IS DISTINCT FROM EXCLUDED.source_deleted
          THEN 0
        ELSE otlet.watch_reconciliation.attempts
      END,
      attempt_limit = CASE
        WHEN otlet.watch_reconciliation.workload_revision_hash IS DISTINCT FROM EXCLUDED.workload_revision_hash
          OR otlet.watch_reconciliation.source_identity IS DISTINCT FROM EXCLUDED.source_identity
          OR otlet.watch_reconciliation.source_deleted IS DISTINCT FROM EXCLUDED.source_deleted
          THEN EXCLUDED.attempt_limit
        ELSE otlet.watch_reconciliation.attempt_limit
      END,
      next_attempt_at = CASE
        WHEN otlet.watch_reconciliation.workload_revision_hash IS DISTINCT FROM EXCLUDED.workload_revision_hash
          OR otlet.watch_reconciliation.source_identity IS DISTINCT FROM EXCLUDED.source_identity
          OR otlet.watch_reconciliation.source_deleted IS DISTINCT FROM EXCLUDED.source_deleted
          THEN clock_timestamp()
        ELSE otlet.watch_reconciliation.next_attempt_at
      END,
      last_error = CASE
        WHEN otlet.watch_reconciliation.workload_revision_hash IS DISTINCT FROM EXCLUDED.workload_revision_hash
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

CREATE FUNCTION otlet.record_watch_input_reconciliation(
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
    attempt_limit
  ) VALUES (
    saved_watch_name,
    record_watch_input_reconciliation.subject_id,
    record_watch_input_reconciliation.workload_revision_hash,
    otlet.semantic_source_hash(record_watch_input_reconciliation.input),
    false,
    policy_attempt_limit
  )
  ON CONFLICT ON CONSTRAINT watch_reconciliation_pkey DO NOTHING
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

CREATE FUNCTION otlet.resolve_watch_input_reconciliation(
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
    AND NOT reconciliation.source_deleted
    AND reconciliation.source_identity = otlet.semantic_source_hash(
      resolve_watch_input_reconciliation.input
    );
  GET DIAGNOSTICS removed = ROW_COUNT;
  RETURN removed > 0;
END;
$$;

CREATE FUNCTION otlet.defer_watch_reconciliation(
  watch_name text,
  subject_id text,
  expected_generation bigint,
  error text
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  pending otlet.watch_reconciliation%ROWTYPE;
  policy otlet.production_policy%ROWTYPE;
  next_attempts integer;
  delay_ms bigint;
BEGIN
  SELECT *
  INTO pending
  FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = defer_watch_reconciliation.watch_name
    AND reconciliation.subject_id = defer_watch_reconciliation.subject_id
    AND reconciliation.generation = defer_watch_reconciliation.expected_generation
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN 'superseded';
  END IF;
  IF pending.state = 'exhausted' THEN
    RETURN 'exhausted';
  END IF;

  SELECT *
  INTO policy
  FROM otlet.production_policy production
  WHERE production.name = 'default';

  next_attempts := pending.attempts + 1;
  IF next_attempts >= pending.attempt_limit THEN
    UPDATE otlet.watch_reconciliation reconciliation
    SET attempts = pending.attempt_limit,
        state = 'exhausted',
        last_attempt_at = clock_timestamp(),
        next_attempt_at = NULL,
        last_error = left(COALESCE(defer_watch_reconciliation.error, 'watch reconciliation failed'), 4096)
    WHERE reconciliation.watch_name = pending.watch_name
      AND reconciliation.subject_id = pending.subject_id
      AND reconciliation.generation = pending.generation;
    RETURN 'exhausted';
  END IF;

  delay_ms := LEAST(
    policy.watch_reconciliation_max_delay_ms::numeric,
    policy.watch_reconciliation_base_delay_ms::numeric
      * power(2::numeric, GREATEST(next_attempts - 1, 0)::numeric)
  )::bigint;
  UPDATE otlet.watch_reconciliation reconciliation
  SET attempts = next_attempts,
      last_attempt_at = clock_timestamp(),
      next_attempt_at = clock_timestamp() + delay_ms * interval '1 millisecond',
      last_error = left(COALESCE(defer_watch_reconciliation.error, 'watch reconciliation failed'), 4096)
  WHERE reconciliation.watch_name = pending.watch_name
    AND reconciliation.subject_id = pending.subject_id
    AND reconciliation.generation = pending.generation;

  RETURN 'pending';
END;
$$;

CREATE FUNCTION otlet.reconcile_watch_subject(
  watch_name text,
  subject_id text,
  force_replay boolean DEFAULT false
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  observed otlet.watch_reconciliation%ROWTYPE;
  pending otlet.watch_reconciliation%ROWTYPE;
  watch_row otlet.watches%ROWTYPE;
  revision_definition jsonb;
  active_revision_hash text;
  pending_input jsonb;
  current_identity text;
  current_content_hash text;
  current_deleted boolean;
  replacement_identity text;
  active_current boolean := false;
  active_other boolean := false;
  fresh_current boolean := false;
  queued boolean := false;
  retry_error text;
  policy_attempt_limit integer;
BEGIN
  SELECT *
  INTO observed
  FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = reconcile_watch_subject.watch_name
    AND reconciliation.subject_id = reconcile_watch_subject.subject_id;

  IF NOT FOUND THEN
    RETURN 'missing';
  END IF;
  IF observed.state = 'exhausted' AND NOT COALESCE(reconcile_watch_subject.force_replay, false) THEN
    RETURN 'exhausted';
  END IF;
  IF observed.state = 'pending'
     AND observed.next_attempt_at > clock_timestamp()
     AND NOT COALESCE(reconcile_watch_subject.force_replay, false) THEN
    RETURN 'deferred';
  END IF;

  SELECT *
  INTO watch_row
  FROM otlet.watches watch
  WHERE watch.name = reconcile_watch_subject.watch_name;
  IF NOT FOUND THEN
    DELETE FROM otlet.watch_reconciliation reconciliation
    WHERE reconciliation.watch_name = observed.watch_name
      AND reconciliation.subject_id = observed.subject_id
      AND reconciliation.generation = observed.generation;
    RETURN 'missing';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || watch_row.task_name, 0)
  );

  SELECT *
  INTO pending
  FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = reconcile_watch_subject.watch_name
    AND reconciliation.subject_id = reconcile_watch_subject.subject_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN 'missing';
  END IF;
  IF pending.generation IS DISTINCT FROM observed.generation THEN
    RETURN 'superseded';
  END IF;
  IF pending.state = 'exhausted' AND NOT COALESCE(reconcile_watch_subject.force_replay, false) THEN
    RETURN 'exhausted';
  END IF;
  IF pending.state = 'pending'
     AND pending.next_attempt_at > clock_timestamp()
     AND NOT COALESCE(reconcile_watch_subject.force_replay, false) THEN
    RETURN 'deferred';
  END IF;

  SELECT *
  INTO watch_row
  FROM otlet.watches watch
  WHERE watch.name = pending.watch_name;
  IF NOT FOUND
     OR watch_row.kind <> 'row'
     OR COALESCE(watch_row.trigger_policy ->> 'on_change', 'mark_stale') <> 'mark_stale_and_enqueue' THEN
    DELETE FROM otlet.watch_reconciliation reconciliation
    WHERE reconciliation.watch_name = pending.watch_name
      AND reconciliation.subject_id = pending.subject_id
      AND reconciliation.generation = pending.generation;
    RETURN 'disabled';
  END IF;

  SELECT head.active_workload_revision_hash, revision.definition
  INTO active_revision_hash, revision_definition
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = watch_row.task_name;
  IF NOT FOUND THEN
    retry_error := 'watch workload revision is missing';
  END IF;

  IF COALESCE(reconcile_watch_subject.force_replay, false)
     AND pending.state = 'exhausted' THEN
    SELECT policy.watch_reconciliation_max_attempts
    INTO policy_attempt_limit
    FROM otlet.production_policy policy
    WHERE policy.name = 'default';
    UPDATE otlet.watch_reconciliation reconciliation
    SET state = 'pending',
        attempts = 0,
        attempt_limit = policy_attempt_limit,
        next_attempt_at = clock_timestamp(),
        last_error = NULL
    WHERE reconciliation.watch_name = pending.watch_name
      AND reconciliation.subject_id = pending.subject_id
      AND reconciliation.generation = pending.generation
    RETURNING * INTO pending;
  END IF;

  IF retry_error IS NULL THEN
    BEGIN
      pending_input := otlet.task_subject_input(
        revision_definition #>> '{task,input_query}',
        pending.subject_id,
        revision_definition
      );
      IF pending_input IS NOT NULL THEN
        current_identity := otlet.semantic_source_hash(pending_input);
        current_content_hash := otlet.semantic_content_hash(
          pending_input,
          revision_definition #> '{task,input_shaping}'
        );
      END IF;
    EXCEPTION WHEN OTHERS THEN
      retry_error := SQLERRM;
    END;
  END IF;
  IF retry_error IS NOT NULL THEN
    RETURN otlet.defer_watch_reconciliation(
      pending.watch_name,
      pending.subject_id,
      pending.generation,
      retry_error
    );
  END IF;

  current_deleted := current_identity IS NULL;
  replacement_identity := COALESCE(
    current_identity,
    otlet.watch_source_delete_identity(pending.watch_name, pending.subject_id)
  );
  IF pending.workload_revision_hash IS DISTINCT FROM active_revision_hash
     OR pending.source_identity IS DISTINCT FROM replacement_identity
     OR pending.source_deleted IS DISTINCT FROM current_deleted THEN
    SELECT policy.watch_reconciliation_max_attempts
    INTO policy_attempt_limit
    FROM otlet.production_policy policy
    WHERE policy.name = 'default';
    UPDATE otlet.watch_reconciliation reconciliation
    SET workload_revision_hash = active_revision_hash,
        source_identity = replacement_identity,
        source_deleted = current_deleted,
        generation = nextval('otlet.watch_reconciliation_generation_seq'),
        state = 'pending',
        attempts = 0,
        attempt_limit = policy_attempt_limit,
        next_attempt_at = clock_timestamp(),
        last_error = NULL
    WHERE reconciliation.watch_name = pending.watch_name
      AND reconciliation.subject_id = pending.subject_id
      AND reconciliation.generation = pending.generation
    RETURNING * INTO pending;
  END IF;

  IF current_deleted THEN
    PERFORM otlet.mark_semantic_stale(
      watch_row.source_table,
      pending.subject_id,
      'source_delete'
    );
    DELETE FROM otlet.watch_reconciliation reconciliation
    WHERE reconciliation.watch_name = pending.watch_name
      AND reconciliation.subject_id = pending.subject_id
      AND reconciliation.generation = pending.generation;
    RETURN 'source_deleted';
  END IF;

  SELECT
    COALESCE(bool_or(
      otlet.semantic_source_hash(job.input)
        = current_identity
    ), false),
    count(*) > 0
  INTO active_current, active_other
  FROM otlet.jobs job
  WHERE job.task_name = watch_row.task_name
    AND job.workload_revision_hash = active_revision_hash
    AND job.subject_id = pending.subject_id
    AND job.status IN ('queued', 'running', 'cancel_requested');
  active_other := active_other AND NOT active_current;

  SELECT EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations materialization
    WHERE materialization.task_name = watch_row.task_name
      AND materialization.record_type = watch_row.record_type
      AND materialization.subject_id = pending.subject_id
      AND materialization.contract_hash = active_revision_hash
      AND materialization.content_hash = current_content_hash
      AND NOT materialization.stale
  ) INTO fresh_current;

  IF active_current OR fresh_current THEN
    DELETE FROM otlet.watch_reconciliation reconciliation
    WHERE reconciliation.watch_name = pending.watch_name
      AND reconciliation.subject_id = pending.subject_id
      AND reconciliation.generation = pending.generation;
    RETURN CASE WHEN active_current THEN 'active_job' ELSE 'fresh' END;
  END IF;
  IF active_other THEN
    RETURN otlet.defer_watch_reconciliation(
      pending.watch_name,
      pending.subject_id,
      pending.generation,
      'active job still carries an older source identity'
    );
  END IF;
  IF pending_input IS NULL THEN
    RETURN otlet.defer_watch_reconciliation(
      pending.watch_name,
      pending.subject_id,
      pending.generation,
      'current watch source did not produce pending input'
    );
  END IF;

  BEGIN
    queued := otlet.admit_task_input(
      watch_row.task_name,
      pending.subject_id,
      pending_input,
      active_revision_hash
    );
  EXCEPTION WHEN OTHERS THEN
    retry_error := SQLERRM;
  END;

  IF retry_error IS NOT NULL THEN
    RETURN otlet.defer_watch_reconciliation(
      pending.watch_name,
      pending.subject_id,
      pending.generation,
      retry_error
    );
  END IF;
  IF queued THEN
    DELETE FROM otlet.watch_reconciliation reconciliation
    WHERE reconciliation.watch_name = pending.watch_name
      AND reconciliation.subject_id = pending.subject_id
      AND reconciliation.generation = pending.generation;
    PERFORM otlet.wake_worker();
    RETURN 'queued';
  END IF;

  SELECT COALESCE(bool_or(
    otlet.semantic_source_hash(job.input)
      = current_identity
  ), false)
  INTO active_current
  FROM otlet.jobs job
  WHERE job.task_name = watch_row.task_name
    AND job.workload_revision_hash = active_revision_hash
    AND job.subject_id = pending.subject_id
    AND job.status IN ('queued', 'running', 'cancel_requested');
  IF active_current THEN
    DELETE FROM otlet.watch_reconciliation reconciliation
    WHERE reconciliation.watch_name = pending.watch_name
      AND reconciliation.subject_id = pending.subject_id
      AND reconciliation.generation = pending.generation;
    RETURN 'active_job';
  END IF;

  RETURN otlet.defer_watch_reconciliation(
    pending.watch_name,
    pending.subject_id,
    pending.generation,
    'queue admission rejected watch reconciliation'
  );
EXCEPTION WHEN OTHERS THEN
  RETURN otlet.defer_watch_reconciliation(
    reconcile_watch_subject.watch_name,
    reconcile_watch_subject.subject_id,
    observed.generation,
    SQLERRM
  );
END;
$$;

CREATE FUNCTION otlet.replay_watch_reconciliation(
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
  WHERE (
      reconciliation.state = 'pending'
      AND reconciliation.next_attempt_at <= clock_timestamp()
    )
    OR (
      COALESCE(replay_watch_reconciliation.include_exhausted, false)
      AND reconciliation.state = 'exhausted'
    )
  ORDER BY
    CASE reconciliation.state WHEN 'pending' THEN 0 ELSE 1 END,
    reconciliation.next_attempt_at NULLS LAST,
    reconciliation.first_dirty_at,
    reconciliation.watch_name,
    reconciliation.subject_id
  LIMIT 1;

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

CREATE FUNCTION otlet.acknowledge_watch_reconciliation(
  watch_name text,
  subject_id text,
  expected_generation bigint
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  removed bigint;
BEGIN
  DELETE FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = acknowledge_watch_reconciliation.watch_name
    AND reconciliation.subject_id = acknowledge_watch_reconciliation.subject_id
    AND reconciliation.generation = acknowledge_watch_reconciliation.expected_generation;
  GET DIAGNOSTICS removed = ROW_COUNT;
  RETURN removed > 0;
END;
$$;

CREATE VIEW otlet.watch_reconciliation_status AS
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
    AND reconciliation.next_attempt_at <= clock_timestamp() AS retry_due
FROM otlet.watch_reconciliation reconciliation
JOIN otlet.watches watch ON watch.name = reconciliation.watch_name;

REVOKE ALL ON TABLE otlet.watch_reconciliation FROM PUBLIC;
REVOKE ALL ON TABLE otlet.watch_reconciliation_status FROM PUBLIC;
REVOKE ALL ON SEQUENCE otlet.watch_reconciliation_generation_seq FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.watch_source_delete_identity(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_watch_reconciliation(text, text, text, text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_watch_input_reconciliation(text, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.resolve_watch_input_reconciliation(text, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.defer_watch_reconciliation(text, text, bigint, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reconcile_watch_subject(text, text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.replay_watch_reconciliation(boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.acknowledge_watch_reconciliation(text, text, bigint) FROM PUBLIC;
