ALTER TABLE otlet.tasks
ADD COLUMN lifecycle_state text NOT NULL DEFAULT 'active',
ADD COLUMN lifecycle_revision_hash text,
ADD COLUMN lifecycle_previous_revision_hash text,
ADD COLUMN lifecycle_promoted_at timestamptz,
ADD COLUMN lifecycle_changed_at timestamptz NOT NULL DEFAULT now();

UPDATE otlet.tasks task
SET lifecycle_revision_hash = head.active_workload_revision_hash,
    lifecycle_previous_revision_hash = head.previous_workload_revision_hash,
    lifecycle_promoted_at = head.promoted_at
FROM otlet.workload_revision_heads head
WHERE head.task_name = task.name;

ALTER TABLE otlet.tasks
ADD CONSTRAINT tasks_lifecycle_state_check
  CHECK (lifecycle_state IN ('active', 'paused', 'retired')),
ADD CONSTRAINT tasks_lifecycle_revision_hash_check
  CHECK (
    lifecycle_revision_hash IS NULL
    OR lifecycle_revision_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
ADD CONSTRAINT tasks_lifecycle_previous_revision_hash_check
  CHECK (
    lifecycle_previous_revision_hash IS NULL
    OR lifecycle_previous_revision_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
ADD CONSTRAINT tasks_lifecycle_pin_check
  CHECK (
    (lifecycle_state = 'active')
    OR (lifecycle_revision_hash IS NOT NULL AND lifecycle_promoted_at IS NOT NULL)
  ),
ADD CONSTRAINT tasks_lifecycle_previous_distinct_check
  CHECK (
    lifecycle_previous_revision_hash IS NULL
    OR lifecycle_previous_revision_hash <> lifecycle_revision_hash
  ),
ADD CONSTRAINT tasks_lifecycle_revision_fk
  FOREIGN KEY (name, lifecycle_revision_hash)
  REFERENCES otlet.workload_revisions(task_name, workload_revision_hash)
  DEFERRABLE INITIALLY DEFERRED,
ADD CONSTRAINT tasks_lifecycle_previous_revision_fk
  FOREIGN KEY (name, lifecycle_previous_revision_hash)
  REFERENCES otlet.workload_revisions(task_name, workload_revision_hash)
  DEFERRABLE INITIALLY DEFERRED;

CREATE FUNCTION otlet.reject_task_lifecycle_bypass() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF (
       NEW.lifecycle_state,
       NEW.lifecycle_revision_hash,
       NEW.lifecycle_previous_revision_hash,
       NEW.lifecycle_promoted_at,
       NEW.lifecycle_changed_at
     ) IS DISTINCT FROM (
       OLD.lifecycle_state,
       OLD.lifecycle_revision_hash,
       OLD.lifecycle_previous_revision_hash,
       OLD.lifecycle_promoted_at,
       OLD.lifecycle_changed_at
     )
     AND current_setting('otlet.lifecycle_task', true) IS DISTINCT FROM OLD.name THEN
    RAISE EXCEPTION 'otlet task lifecycle changes require set_task_lifecycle';
  END IF;

  IF OLD.lifecycle_state = 'retired'
     AND (
       NEW.name,
       NEW.input_query,
       NEW.source_relations,
       NEW.source_query_contract,
       NEW.instruction,
       NEW.output_schema,
       NEW.model_name,
       NEW.runtime_options,
       NEW.input_shaping,
       NEW.decision_contract
     ) IS DISTINCT FROM (
       OLD.name,
       OLD.input_query,
       OLD.source_relations,
       OLD.source_query_contract,
       OLD.instruction,
       OLD.output_schema,
       OLD.model_name,
       OLD.runtime_options,
       OLD.input_shaping,
       OLD.decision_contract
     ) THEN
    RAISE EXCEPTION 'otlet retired task % is immutable', OLD.name;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER tasks_lifecycle_guard
BEFORE UPDATE ON otlet.tasks
FOR EACH ROW EXECUTE FUNCTION otlet.reject_task_lifecycle_bypass();

CREATE FUNCTION otlet.reject_task_delete() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'otlet task % is a retained evidence anchor; retire it instead', OLD.name;
END;
$$;

CREATE TRIGGER tasks_delete_guard
BEFORE DELETE ON otlet.tasks
FOR EACH ROW EXECUTE FUNCTION otlet.reject_task_delete();

CREATE FUNCTION otlet.guard_task_definition_write() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  BEGIN
    PERFORM 1
    FROM otlet.production_policy policy
    WHERE policy.name = 'default'
    FOR UPDATE NOWAIT;
  EXCEPTION WHEN lock_not_available THEN
    RAISE EXCEPTION 'otlet task % definition write conflicts with a lifecycle operation; retry',
      NEW.name
      USING ERRCODE = '55P03';
  END;

  IF NOT pg_try_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || NEW.name, 0)
  ) THEN
    RAISE EXCEPTION 'otlet task % definition write conflicts with a lifecycle operation; retry',
      NEW.name
      USING ERRCODE = '55P03';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER tasks_aa_definition_write_lock
BEFORE UPDATE OF input_query, source_relations, source_query_contract,
  instruction, output_schema, model_name, runtime_options, input_shaping,
  decision_contract ON otlet.tasks
FOR EACH ROW EXECUTE FUNCTION otlet.guard_task_definition_write();

CREATE FUNCTION otlet.guard_workload_revision_head() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  task_state text;
BEGIN
  SELECT task.lifecycle_state
  INTO task_state
  FROM otlet.tasks task
  WHERE task.name = NEW.task_name;

  IF task_state IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'otlet task % is % and cannot activate a workload revision',
      NEW.task_name,
      COALESCE(task_state, 'missing');
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_revision_heads_lifecycle_guard
BEFORE INSERT OR UPDATE ON otlet.workload_revision_heads
FOR EACH ROW EXECUTE FUNCTION otlet.guard_workload_revision_head();

CREATE FUNCTION otlet.sync_task_lifecycle_revision() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  previous_lifecycle_task text;
BEGIN
  previous_lifecycle_task := current_setting('otlet.lifecycle_task', true);
  PERFORM set_config('otlet.lifecycle_task', NEW.task_name, true);
  UPDATE otlet.tasks task
  SET lifecycle_revision_hash = NEW.active_workload_revision_hash,
      lifecycle_previous_revision_hash = NEW.previous_workload_revision_hash,
      lifecycle_promoted_at = NEW.promoted_at
  WHERE task.name = NEW.task_name;
  PERFORM set_config('otlet.lifecycle_task', COALESCE(previous_lifecycle_task, ''), true);
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_revision_heads_lifecycle_sync
AFTER INSERT OR UPDATE ON otlet.workload_revision_heads
FOR EACH ROW EXECUTE FUNCTION otlet.sync_task_lifecycle_revision();

CREATE FUNCTION otlet.guard_watch_configuration() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  task_state text;
BEGIN
  SELECT task.lifecycle_state
  INTO task_state
  FROM otlet.tasks task
  WHERE task.name = NEW.task_name;

  IF task_state IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'otlet watch % task is % and cannot reconfigure while inactive',
      NEW.name,
      COALESCE(task_state, 'missing');
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER watches_lifecycle_guard
BEFORE INSERT OR UPDATE ON otlet.watches
FOR EACH ROW EXECUTE FUNCTION otlet.guard_watch_configuration();

CREATE FUNCTION otlet.watch_source_relation_drift(
  task_name text,
  source_table text
) RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  WITH pinned AS (
    SELECT NULLIF(source.value ->> 'oid', '')::oid AS relation_oid
    FROM otlet.tasks task
    JOIN otlet.workload_revisions revision
      ON revision.task_name = task.name
     AND revision.workload_revision_hash = task.lifecycle_revision_hash
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
      revision.definition #> '{source,query_contract,declared_sources}',
      '[]'::jsonb
    )) source(value)
    WHERE task.name = $1
      AND source.value ->> 'name' = $2
  )
  SELECT COALESCE((
    SELECT to_regclass($2)::oid IS DISTINCT FROM pinned.relation_oid
       AND (
         to_regclass($2)::oid IS NOT NULL
         OR EXISTS (
           SELECT 1 FROM pg_class relation WHERE relation.oid = pinned.relation_oid
         )
       )
    FROM pinned
  ), true)
$$;

CREATE FUNCTION otlet.lock_task_source_relations(task_name text) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  source_relation regclass;
BEGIN
  FOR source_relation IN
    SELECT relation.oid::regclass
    FROM otlet.tasks task
    JOIN otlet.workload_revisions revision
      ON revision.task_name = task.name
     AND revision.workload_revision_hash = task.lifecycle_revision_hash
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
      revision.definition #> '{source,query_contract,declared_sources}',
      '[]'::jsonb
    )) source(value)
    JOIN pg_class relation ON relation.oid = NULLIF(source.value ->> 'oid', '')::oid
    WHERE task.name = lock_task_source_relations.task_name
    ORDER BY relation.oid
  LOOP
    EXECUTE format('LOCK TABLE %s IN SHARE ROW EXCLUSIVE MODE', source_relation);
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.repair_source_query_contract(
  task_name text,
  expected_active_workload_revision_hash text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  active_definition jsonb;
  active_contract jsonb;
  repaired_contract jsonb;
  repaired_definition jsonb;
  raw_search_path text := pg_catalog.current_setting('search_path');
  repaired_hash text;
  candidate_plan jsonb;
  candidate_plan_cost numeric;
  candidate_preflight_at timestamptz;
  repaired_relation regclass;
  pair_source jsonb;
  watch_row otlet.watches%ROWTYPE;
BEGIN
  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || repair_source_query_contract.task_name, 0)
  );
  PERFORM 1
  FROM otlet.tasks task
  WHERE task.name = repair_source_query_contract.task_name
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', repair_source_query_contract.task_name;
  END IF;

  SELECT revision.definition
  INTO active_definition
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = repair_source_query_contract.task_name
    AND head.active_workload_revision_hash =
      repair_source_query_contract.expected_active_workload_revision_hash
  FOR UPDATE OF head;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet source query repair conflict for task %',
      repair_source_query_contract.task_name;
  END IF;
  active_contract := active_definition #> '{source,query_contract}';
  IF active_contract IS NULL OR jsonb_typeof(active_contract) = 'null' THEN
    RAISE EXCEPTION 'otlet task % has no source query contract',
      repair_source_query_contract.task_name;
  END IF;
  IF current_user::regrole::oid IS DISTINCT FROM
     (active_contract #>> '{identity,oid}')::oid THEN
    RAISE EXCEPTION 'otlet source query repair requires the bound execution identity';
  END IF;

  PERFORM pg_catalog.set_config(
    'search_path',
    active_contract #>> '{search_path,raw}',
    true
  );
  repaired_contract := otlet.build_source_query_contract(
    active_contract #>> '{query,raw}',
    NULLIF(active_contract -> 'declared_sources', 'null'::jsonb)
  );

  UPDATE otlet.tasks task
  SET source_relations = NULLIF(repaired_contract -> 'declared_sources', 'null'::jsonb),
      source_query_contract = repaired_contract
  WHERE task.name = repair_source_query_contract.task_name
    AND task.input_query IS NOT DISTINCT FROM active_contract #>> '{query,raw}'
    AND task.source_relations IS NOT DISTINCT FROM
      NULLIF(active_contract -> 'declared_sources', 'null'::jsonb);

  repaired_definition := jsonb_set(
    active_definition,
    '{task,input_query}',
    to_jsonb(repaired_contract #>> '{query,resolved}')
  );
  repaired_definition := jsonb_set(
    repaired_definition,
    '{source,query_contract}',
    repaired_contract
  );
  repaired_definition := jsonb_set(
    repaired_definition,
    '{source,declared_relations}',
    COALESCE(repaired_contract -> 'declared_sources', 'null'::jsonb)
  );
  IF repaired_definition #>> '{source,kind}' = 'pair' THEN
    repaired_definition := jsonb_set(
      repaired_definition,
      '{source,candidate_query}',
      to_jsonb(repaired_contract #>> '{query,resolved}')
    );
  END IF;
  PERFORM otlet.workload_definition_complexity_guard(repaired_definition);
  IF repaired_definition #>> '{source,kind}' = 'row' THEN
    repaired_definition := jsonb_set(
      repaired_definition,
      '{source,semantic_column_contract}',
      otlet.semantic_source_column_contract(
        repaired_definition #>> '{source,source_table}',
        repaired_definition #>> '{source,subject_column}',
        ARRAY(
          SELECT value
          FROM jsonb_array_elements_text(COALESCE(
            repaired_definition #> '{source,input_columns}',
            '[]'::jsonb
          )) value
        )
      )
    );
    PERFORM otlet.workload_definition_complexity_guard(repaired_definition);
  END IF;
  PERFORM pg_catalog.set_config('search_path', raw_search_path, true);

  IF repaired_definition #>> '{source,kind}' = 'pair' THEN
    SELECT
      preflight.candidate_plan,
      preflight.candidate_plan_cost,
      preflight.candidate_preflight_at
    INTO candidate_plan, candidate_plan_cost, candidate_preflight_at
    FROM otlet.preflight_candidate_query(
      repaired_definition #>> '{source,candidate_query}',
      true,
      false,
      repaired_contract
    ) preflight;
  END IF;

  repaired_hash := otlet.identity_hash('workload_revision', repaired_definition);
  INSERT INTO otlet.workload_revisions (
    workload_revision_hash,
    task_name,
    definition,
    candidate_plan,
    candidate_plan_cost,
    candidate_preflight_at
  ) VALUES (
    repaired_hash,
    repair_source_query_contract.task_name,
    repaired_definition,
    candidate_plan,
    candidate_plan_cost,
    candidate_preflight_at
  )
  ON CONFLICT (workload_revision_hash) DO NOTHING;

  repaired_hash := otlet.promote_workload_revision(
    repair_source_query_contract.task_name,
    repaired_hash,
    repair_source_query_contract.expected_active_workload_revision_hash
  );

  SELECT watch.*
  INTO watch_row
  FROM otlet.watches watch
  WHERE watch.task_name = repair_source_query_contract.task_name;

  IF repaired_definition #>> '{source,kind}' = 'row' THEN
    repaired_relation := to_regclass(repaired_definition #>> '{source,source_table}');
    IF repaired_relation IS NULL THEN
      RAISE EXCEPTION 'otlet repaired row source relation is missing for task %',
        repair_source_query_contract.task_name;
    END IF;
    PERFORM otlet.watch_semantic_stale(
      repaired_relation,
      repaired_definition #>> '{source,subject_column}'
    );
    IF watch_row.name IS NOT NULL
       AND COALESCE(watch_row.trigger_policy ->> 'on_change', 'mark_stale') =
         'mark_stale_and_enqueue' THEN
      PERFORM otlet.watch_semantic_change(
        repaired_relation,
        repaired_definition #>> '{source,subject_column}',
        watch_row.name
      );
    END IF;
  ELSIF repaired_definition #>> '{source,kind}' = 'pair'
        AND watch_row.name IS NOT NULL THEN
    FOR pair_source IN
      SELECT value
      FROM jsonb_array_elements(
        COALESCE(repaired_definition #> '{source,pair_sources}', '[]'::jsonb)
      ) source(value)
    LOOP
      PERFORM otlet.watch_semantic_stale(
        (pair_source ->> 'table')::regclass,
        COALESCE(NULLIF(pair_source ->> 'subject_column', ''), 'id')
      );
    END LOOP;
  END IF;
  RETURN repaired_hash;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_catalog.set_config('search_path', raw_search_path, true);
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.ensure_active_workload_revision(task_name text) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  active_hash text;
  active_definition jsonb;
  task_state text;
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || ensure_active_workload_revision.task_name, 0)
  );

  SELECT task.lifecycle_state
  INTO task_state
  FROM otlet.tasks task
  WHERE task.name = ensure_active_workload_revision.task_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', ensure_active_workload_revision.task_name;
  END IF;
  IF task_state <> 'active' THEN
    RAISE EXCEPTION 'otlet task % is %', ensure_active_workload_revision.task_name, task_state;
  END IF;

  SELECT head.active_workload_revision_hash, revision.definition
  INTO active_hash, active_definition
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = ensure_active_workload_revision.task_name;
  IF FOUND THEN
    PERFORM otlet.workload_source_contract_guard(active_definition);
    RETURN active_hash;
  END IF;

  active_hash := otlet.capture_workload_revision(ensure_active_workload_revision.task_name);
  INSERT INTO otlet.workload_revision_heads (
    task_name,
    active_workload_revision_hash
  )
  VALUES (
    ensure_active_workload_revision.task_name,
    active_hash
  );
  SELECT revision.definition
  INTO active_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = ensure_active_workload_revision.task_name
    AND revision.workload_revision_hash = active_hash;
  PERFORM otlet.workload_source_contract_guard(active_definition);
  RETURN active_hash;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.promote_configured_workload_revision(task_name text) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  active_hash text;
  target_hash text;
  task_state text;
BEGIN
  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || promote_configured_workload_revision.task_name, 0)
  );

  SELECT task.lifecycle_state
  INTO task_state
  FROM otlet.tasks task
  WHERE task.name = promote_configured_workload_revision.task_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', promote_configured_workload_revision.task_name;
  END IF;
  IF task_state = 'retired' THEN
    RAISE EXCEPTION 'otlet task % is retired', promote_configured_workload_revision.task_name;
  END IF;

  target_hash := otlet.capture_workload_revision(promote_configured_workload_revision.task_name);
  IF task_state = 'paused' THEN
    RETURN target_hash;
  END IF;

  SELECT head.active_workload_revision_hash
  INTO active_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = promote_configured_workload_revision.task_name;

  IF active_hash IS NOT DISTINCT FROM target_hash THEN
    RETURN target_hash;
  END IF;
  RETURN otlet.promote_workload_revision(
    promote_configured_workload_revision.task_name,
    target_hash,
    active_hash
  );
END;
$$;

CREATE OR REPLACE FUNCTION otlet.watch_change_trigger() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  watch_on_change text;
  watch_input_columns text[];
  watch_revision_hash text;
  source_table text;
  row_input jsonb;
  reconciliation_input jsonb;
  subject_id text;
  old_subject_id text;
  row_ctid text;
  row_xmin text;
BEGIN
  SELECT
    COALESCE(w.trigger_policy ->> 'on_change', 'mark_stale'),
    CASE
      WHEN revision.definition #> '{source,input_columns}' IS NULL THEN NULL::text[]
      ELSE ARRAY(
        SELECT value
        FROM jsonb_array_elements_text(revision.definition #> '{source,input_columns}') value
      )
    END,
    revision.workload_revision_hash,
    revision.definition #>> '{source,source_table}'
  INTO
    watch_on_change,
    watch_input_columns,
    watch_revision_hash,
    source_table
  FROM otlet.watches w
  JOIN otlet.tasks task ON task.name = w.task_name
  LEFT JOIN otlet.workload_revision_heads head ON head.task_name = task.name
  JOIN otlet.workload_revisions revision
    ON revision.task_name = task.name
   AND revision.workload_revision_hash = COALESCE(
     head.active_workload_revision_hash,
     task.lifecycle_revision_hash
   )
  WHERE w.name = TG_ARGV[1]
    AND w.kind = 'row'
    AND task.lifecycle_state IN ('active', 'paused');

  IF NOT FOUND THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    row_input := to_jsonb(OLD);
    row_ctid := OLD.ctid::text;
    row_xmin := OLD.xmin::text;
  ELSE
    row_input := to_jsonb(NEW);
    row_ctid := NEW.ctid::text;
    row_xmin := NEW.xmin::text;
  END IF;

  subject_id := row_input ->> TG_ARGV[0];
  IF TG_OP = 'UPDATE' THEN
    old_subject_id := to_jsonb(OLD) ->> TG_ARGV[0];
    IF old_subject_id IS DISTINCT FROM subject_id
       AND old_subject_id IS NOT NULL THEN
      PERFORM otlet.mark_semantic_stale(
        format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME),
        old_subject_id,
        'source_delete'
      );
      IF watch_on_change = 'mark_stale_and_enqueue' THEN
        PERFORM otlet.record_watch_reconciliation(
          TG_ARGV[1],
          old_subject_id,
          watch_revision_hash,
          otlet.watch_source_delete_identity(TG_ARGV[1], old_subject_id),
          true
        );
      END IF;
    END IF;
  END IF;
  PERFORM otlet.mark_semantic_stale(
    format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME),
    subject_id,
    CASE WHEN TG_OP = 'DELETE' THEN 'source_delete' ELSE 'source_update' END
  );

  IF watch_on_change = 'mark_stale_and_enqueue'
     AND subject_id IS NOT NULL THEN
    IF TG_OP = 'DELETE' THEN
      PERFORM otlet.record_watch_reconciliation(
        TG_ARGV[1],
        subject_id,
        watch_revision_hash,
        otlet.watch_source_delete_identity(TG_ARGV[1], subject_id),
        true
      );
    ELSE
      reconciliation_input := jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', source_table,
          'subject_id', subject_id,
          'ctid', row_ctid,
          'xmin', row_xmin
        ),
        'table', source_table,
        'row', otlet.semantic_project_row(row_input, watch_input_columns)
      );
      PERFORM otlet.record_watch_reconciliation(
        TG_ARGV[1],
        subject_id,
        watch_revision_hash,
        otlet.semantic_source_hash(reconciliation_input),
        false
      );
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.defer_watch_reconciliation(
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
  task_state text;
  next_attempts integer;
  delay_ms bigint;
BEGIN
  SELECT task.lifecycle_state
  INTO task_state
  FROM otlet.watches watch
  JOIN otlet.tasks task ON task.name = watch.task_name
  WHERE watch.name = defer_watch_reconciliation.watch_name;
  IF task_state IS DISTINCT FROM 'active' THEN
    RETURN COALESCE(task_state, 'superseded');
  END IF;

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
    RETURN 'idle';
  END IF;
  RETURN otlet.reconcile_watch_subject(
    candidate.watch_name,
    candidate.subject_id,
    COALESCE(replay_watch_reconciliation.include_exhausted, false)
  );
END;
$$;

CREATE OR REPLACE FUNCTION otlet.drop_watch_row_index(
  index_name text
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_indexes%ROWTYPE;
  stale_trigger_name text;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_indexes si
  WHERE si.name = drop_watch_row_index.index_name;

  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF otlet.watch_source_relation_drift(
    index_row.task_name,
    index_row.source_table
  ) THEN
    RAISE EXCEPTION 'otlet source relation identity drift blocks semantic index deletion for %',
      index_row.name;
  END IF;

  UPDATE otlet.semantic_materializations sm
  SET stale = true,
      stale_reason = 'contract_changed',
      updated_at = now()
  WHERE sm.task_name = index_row.task_name
    AND sm.record_type = index_row.record_type;

  DELETE FROM otlet.semantic_indexes si
  WHERE si.name = index_row.name;

  IF to_regclass(index_row.source_table) IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.semantic_indexes si
    WHERE si.source_table = index_row.source_table
      AND si.subject_column = index_row.subject_column
  )
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.watches watch
    CROSS JOIN LATERAL jsonb_array_elements(
      COALESCE(watch.pair_sources, '[]'::jsonb)
    ) source(value)
    WHERE source.value ->> 'table' = index_row.source_table
      AND COALESCE(NULLIF(source.value ->> 'subject_column', ''), 'id') = index_row.subject_column
  ) THEN
    stale_trigger_name := 'otlet_stale_v1_' || substr(right(otlet.identity_text_hash(
      'semantic_stale_trigger',
      index_row.subject_column
    ), 64), 1, 16);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', stale_trigger_name, index_row.source_table);
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.drop_watch(watch_name text) RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN otlet.drop_watch_registry(drop_watch.watch_name);
END;
$$;

CREATE FUNCTION otlet.drop_watch_registry(
  watch_name text
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  watch_row otlet.watches%ROWTYPE;
  trigger_name text;
  pair_source jsonb;
  pair_source_table text;
  pair_source_subject_column text;
BEGIN
  SELECT *
  INTO watch_row
  FROM otlet.watches watch
  WHERE watch.name = drop_watch_registry.watch_name;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || watch_row.task_name, 0)
  );
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));

  PERFORM otlet.lock_task_source_relations(watch_row.task_name);
  SELECT *
  INTO watch_row
  FROM otlet.watches watch
  WHERE watch.name = drop_watch_registry.watch_name
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF EXISTS (
       SELECT 1
       FROM otlet.jobs job
       WHERE job.task_name = watch_row.task_name
         AND job.status IN ('queued', 'running', 'cancel_requested')
     ) OR EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation reconciliation
       WHERE reconciliation.watch_name = watch_row.name
     ) THEN
    RAISE EXCEPTION 'otlet watch % has unfinished work or reconciliation',
      watch_row.name;
  END IF;
  IF watch_row.kind = 'row'
     AND otlet.watch_source_relation_drift(
       watch_row.task_name,
       watch_row.source_table
     ) THEN
    RAISE EXCEPTION 'otlet source relation identity drift blocks watch deletion for %',
      watch_row.name;
  ELSIF watch_row.kind = 'pair' THEN
    FOR pair_source IN
      SELECT value
      FROM jsonb_array_elements(COALESCE(watch_row.pair_sources, '[]'::jsonb)) source(value)
    LOOP
      IF otlet.watch_source_relation_drift(
        watch_row.task_name,
        pair_source ->> 'table'
      ) THEN
        RAISE EXCEPTION 'otlet source relation identity drift blocks watch deletion for %',
          watch_row.name;
      END IF;
    END LOOP;
  END IF;

  IF watch_row.kind = 'row'
     AND watch_row.source_table IS NOT NULL
     AND to_regclass(watch_row.source_table) IS NOT NULL THEN
    trigger_name := 'otlet_watch_v1_' || substr(right(otlet.identity_text_hash(
      'watch_trigger',
      watch_row.subject_column || ':' || watch_row.name
    ), 64), 1, 16);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trigger_name, watch_row.source_table);
  END IF;

  DELETE FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = watch_row.name;

  DELETE FROM otlet.watches watch
  WHERE watch.name = watch_row.name;

  IF watch_row.kind = 'row' AND watch_row.semantic_index_name IS NOT NULL THEN
    PERFORM otlet.drop_watch_row_index(watch_row.semantic_index_name);
  ELSIF watch_row.kind = 'pair' AND watch_row.semantic_join_index_name IS NOT NULL THEN
    PERFORM otlet.drop_watch_pair_index(watch_row.semantic_join_index_name);
  END IF;

  IF watch_row.kind = 'pair' THEN
    FOR pair_source IN
      SELECT value
      FROM jsonb_array_elements(COALESCE(watch_row.pair_sources, '[]'::jsonb)) source(value)
    LOOP
      pair_source_table := pair_source ->> 'table';
      pair_source_subject_column := COALESCE(NULLIF(pair_source ->> 'subject_column', ''), 'id');

      IF pair_source_table IS NOT NULL
         AND to_regclass(pair_source_table) IS NOT NULL
         AND NOT EXISTS (
           SELECT 1
           FROM otlet.semantic_indexes si
           WHERE si.source_table = pair_source_table
             AND si.subject_column = pair_source_subject_column
         )
         AND NOT EXISTS (
           SELECT 1
           FROM otlet.watches watch
           CROSS JOIN LATERAL jsonb_array_elements(COALESCE(watch.pair_sources, '[]'::jsonb)) source(value)
           WHERE source.value ->> 'table' = pair_source_table
             AND COALESCE(NULLIF(source.value ->> 'subject_column', ''), 'id') = pair_source_subject_column
         ) THEN
        trigger_name := 'otlet_stale_v1_' || substr(right(otlet.identity_text_hash(
          'semantic_stale_trigger',
          pair_source_subject_column
        ), 64), 1, 16);
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trigger_name, pair_source_table);
      END IF;
    END LOOP;
  END IF;

  DELETE FROM otlet.workload_revision_heads head
  WHERE head.task_name = watch_row.task_name;

  RETURN true;
END;
$$;

CREATE FUNCTION otlet.set_task_lifecycle(
  task_name text,
  target_state text,
  expected_revision_hash text
) RETURNS otlet.tasks
LANGUAGE plpgsql
AS $$
DECLARE
  task_row otlet.tasks%ROWTYPE;
  head_row otlet.workload_revision_heads%ROWTYPE;
  live_jobs bigint;
  pending_reconciliation bigint;
  previous_lifecycle_task text;
BEGIN
  IF target_state IS NULL OR target_state NOT IN ('active', 'paused', 'retired') THEN
    RAISE EXCEPTION 'otlet task lifecycle state % is invalid', target_state;
  END IF;
  IF expected_revision_hash IS NULL THEN
    RAISE EXCEPTION 'otlet task lifecycle revision pin is required';
  END IF;

  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || set_task_lifecycle.task_name, 0)
  );

  SELECT *
  INTO task_row
  FROM otlet.tasks task
  WHERE task.name = set_task_lifecycle.task_name
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', set_task_lifecycle.task_name;
  END IF;

  SELECT *
  INTO head_row
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = task_row.name
  FOR UPDATE;

  IF task_row.lifecycle_state = 'active' THEN
    IF head_row.active_workload_revision_hash IS NULL THEN
      RAISE EXCEPTION 'otlet active task % has no workload revision to pin', task_row.name;
    END IF;
    IF head_row.active_workload_revision_hash IS DISTINCT FROM expected_revision_hash THEN
      RAISE EXCEPTION 'otlet task lifecycle revision conflict for task %', task_row.name;
    END IF;
  ELSIF task_row.lifecycle_revision_hash IS DISTINCT FROM expected_revision_hash THEN
    RAISE EXCEPTION 'otlet task lifecycle revision conflict for task %', task_row.name;
  END IF;

  IF task_row.lifecycle_state = target_state THEN
    RETURN task_row;
  END IF;
  IF task_row.lifecycle_state = 'retired' THEN
    RAISE EXCEPTION 'otlet task % is retired', task_row.name;
  END IF;
  IF task_row.lifecycle_state = 'active' AND target_state <> 'paused' THEN
    RAISE EXCEPTION 'otlet active task % must be paused before retirement', task_row.name;
  END IF;
  IF task_row.lifecycle_state = 'paused' AND target_state NOT IN ('active', 'retired') THEN
    RAISE EXCEPTION 'otlet task lifecycle transition from paused to % is invalid', target_state;
  END IF;

  IF task_row.lifecycle_state = 'active' THEN
    SELECT count(*)
    INTO live_jobs
    FROM otlet.jobs job
    WHERE job.task_name = task_row.name
      AND job.status IN ('running', 'cancel_requested');
    IF live_jobs > 0 THEN
      RAISE EXCEPTION 'otlet task % has % leased jobs; drain workers before pausing',
        task_row.name,
        live_jobs;
    END IF;

    previous_lifecycle_task := current_setting('otlet.lifecycle_task', true);
    PERFORM set_config('otlet.lifecycle_task', task_row.name, true);
    UPDATE otlet.tasks task
    SET lifecycle_state = 'paused',
        lifecycle_revision_hash = head_row.active_workload_revision_hash,
        lifecycle_previous_revision_hash = head_row.previous_workload_revision_hash,
        lifecycle_promoted_at = head_row.promoted_at,
        lifecycle_changed_at = now()
    WHERE task.name = task_row.name
    RETURNING * INTO task_row;
    PERFORM set_config('otlet.lifecycle_task', COALESCE(previous_lifecycle_task, ''), true);

    DELETE FROM otlet.workload_revision_heads head
    WHERE head.task_name = task_row.name;
    RETURN task_row;
  END IF;

  IF target_state = 'active' THEN
    previous_lifecycle_task := current_setting('otlet.lifecycle_task', true);
    PERFORM set_config('otlet.lifecycle_task', task_row.name, true);
    UPDATE otlet.tasks task
    SET lifecycle_state = 'active',
        lifecycle_changed_at = now()
    WHERE task.name = task_row.name
    RETURNING * INTO task_row;
    PERFORM set_config('otlet.lifecycle_task', COALESCE(previous_lifecycle_task, ''), true);

    INSERT INTO otlet.workload_revision_heads (
      task_name,
      active_workload_revision_hash,
      previous_workload_revision_hash,
      promoted_at
    ) VALUES (
      task_row.name,
      task_row.lifecycle_revision_hash,
      task_row.lifecycle_previous_revision_hash,
      task_row.lifecycle_promoted_at
    );
    SELECT *
    INTO task_row
    FROM otlet.tasks task
    WHERE task.name = set_task_lifecycle.task_name;
    RETURN task_row;
  END IF;

  PERFORM otlet.lock_task_source_relations(task_row.name);
  IF EXISTS (
    SELECT 1
    FROM (
      SELECT
        watch.source_table AS source_table
      FROM otlet.watches watch
      WHERE watch.task_name = task_row.name
        AND watch.kind = 'row'
      UNION ALL
      SELECT
        pair_source.value ->> 'table'
      FROM otlet.watches watch
      CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(watch.pair_sources, '[]'::jsonb)
      ) pair_source(value)
      WHERE watch.task_name = task_row.name
        AND watch.kind = 'pair'
    ) source
    WHERE otlet.watch_source_relation_drift(
      task_row.name,
      source.source_table
    )
  ) THEN
    RAISE EXCEPTION 'otlet task % has source relation identity drift and cannot retire',
      task_row.name;
  END IF;

  SELECT count(*)
  INTO live_jobs
  FROM otlet.jobs job
  WHERE job.task_name = task_row.name
    AND job.status IN ('queued', 'running', 'cancel_requested');
  IF live_jobs > 0 THEN
    RAISE EXCEPTION 'otlet task % has % unfinished jobs and cannot retire',
      task_row.name,
      live_jobs;
  END IF;
  SELECT count(*)
  INTO pending_reconciliation
  FROM otlet.watch_reconciliation reconciliation
  JOIN otlet.watches watch ON watch.name = reconciliation.watch_name
  WHERE watch.task_name = task_row.name;
  IF pending_reconciliation > 0 THEN
    RAISE EXCEPTION 'otlet task % has % unfinished watch reconciliation subjects and cannot retire',
      task_row.name,
      pending_reconciliation;
  END IF;

  previous_lifecycle_task := current_setting('otlet.lifecycle_task', true);
  PERFORM set_config('otlet.lifecycle_task', task_row.name, true);
  UPDATE otlet.tasks task
  SET lifecycle_state = 'retired',
      lifecycle_changed_at = now()
  WHERE task.name = task_row.name
  RETURNING * INTO task_row;
  PERFORM set_config('otlet.lifecycle_task', COALESCE(previous_lifecycle_task, ''), true);

  UPDATE otlet.semantic_materializations materialization
  SET stale = true,
      stale_reason = 'contract_changed',
      updated_at = now()
  WHERE materialization.task_name = task_row.name;

  RETURN task_row;
END;
$$;

CREATE FUNCTION otlet.drop_watch(
  watch_name text,
  expected_retired_revision_hash text
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  watch_row otlet.watches%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  unfinished_jobs bigint;
  pending_reconciliation bigint;
BEGIN
  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;

  SELECT *
  INTO watch_row
  FROM otlet.watches watch
  WHERE watch.name = drop_watch.watch_name;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || watch_row.task_name, 0)
  );
  SELECT *
  INTO task_row
  FROM otlet.tasks task
  WHERE task.name = watch_row.task_name
  FOR UPDATE;

  IF task_row.lifecycle_state <> 'retired' THEN
    RAISE EXCEPTION 'otlet watch % task must be retired before deletion', watch_row.name;
  END IF;
  IF task_row.lifecycle_revision_hash IS DISTINCT FROM expected_retired_revision_hash THEN
    RAISE EXCEPTION 'otlet watch deletion revision conflict for watch %', watch_row.name;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = task_row.name
  ) THEN
    RAISE EXCEPTION 'otlet retired task % still has an active workload revision', task_row.name;
  END IF;

  SELECT count(*)
  INTO unfinished_jobs
  FROM otlet.jobs job
  WHERE job.task_name = task_row.name
    AND job.status IN ('queued', 'running', 'cancel_requested');
  SELECT count(*)
  INTO pending_reconciliation
  FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = watch_row.name;
  IF unfinished_jobs > 0 OR pending_reconciliation > 0 THEN
    RAISE EXCEPTION 'otlet watch % still has operational dependencies', watch_row.name;
  END IF;

  RETURN otlet.drop_watch_registry(watch_row.name);
END;
$$;

CREATE FUNCTION otlet.current_workload_revision_status(task_name text)
RETURNS TABLE (
  configured_revision_hash text,
  configured_revision_error text
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  BEGIN
    configured_revision_hash := otlet.identity_hash(
      'workload_revision',
      otlet.current_workload_revision_definition(
        current_workload_revision_status.task_name
      )
    );
  EXCEPTION WHEN OTHERS THEN
    configured_revision_error := left(SQLERRM, 4096);
  END;
  RETURN NEXT;
END;
$$;

CREATE VIEW otlet.task_lifecycle_status AS
WITH configured AS (
  SELECT
    task.name AS task_name,
    configured.configured_revision_hash,
    configured.configured_revision_error
  FROM otlet.tasks task
  CROSS JOIN LATERAL otlet.current_workload_revision_status(task.name) configured
), job_counts AS (
  SELECT
    job.task_name,
    count(*)::bigint AS jobs,
    count(*) FILTER (WHERE job.status = 'queued')::bigint AS queued_jobs,
    count(*) FILTER (WHERE job.status = 'running')::bigint AS running_jobs,
    count(*) FILTER (WHERE job.status = 'cancel_requested')::bigint AS cancel_requested_jobs,
    count(*) FILTER (WHERE job.status IN ('complete', 'failed', 'canceled'))::bigint AS terminal_jobs
  FROM otlet.jobs job
  GROUP BY job.task_name
), materialization_counts AS (
  SELECT materialization.task_name, count(*)::bigint AS materializations
  FROM otlet.semantic_materializations materialization
  GROUP BY materialization.task_name
), revision_counts AS (
  SELECT revision.task_name, count(*)::bigint AS revisions
  FROM otlet.workload_revisions revision
  GROUP BY revision.task_name
), reconciliation_counts AS (
  SELECT watch.task_name, count(*)::bigint AS reconciliation_subjects
  FROM otlet.watch_reconciliation reconciliation
  JOIN otlet.watches watch ON watch.name = reconciliation.watch_name
  GROUP BY watch.task_name
), source_drift AS (
  SELECT
    watch.name AS watch_name,
    CASE
      WHEN watch.kind = 'row' THEN otlet.watch_source_relation_drift(
        watch.task_name,
        watch.source_table
      )
      ELSE EXISTS (
        SELECT 1
        FROM jsonb_array_elements(COALESCE(watch.pair_sources, '[]'::jsonb)) source(value)
        WHERE otlet.watch_source_relation_drift(
          watch.task_name,
          source.value ->> 'table'
        )
      )
    END AS source_relation_drift
  FROM otlet.watches watch
)
SELECT
  task.name AS task_name,
  watch.name AS watch_name,
  watch.kind AS watch_kind,
  task.lifecycle_state,
  head.active_workload_revision_hash,
  task.lifecycle_revision_hash AS pinned_workload_revision_hash,
  task.lifecycle_previous_revision_hash AS previous_workload_revision_hash,
  task.lifecycle_promoted_at,
  task.lifecycle_changed_at,
  configured.configured_revision_hash,
  configured.configured_revision_error,
  EXISTS (
    SELECT 1
    FROM otlet.workload_revisions revision
    WHERE revision.task_name = task.name
      AND revision.workload_revision_hash = configured.configured_revision_hash
  ) AS configured_revision_captured,
  configured.configured_revision_hash IS DISTINCT FROM task.lifecycle_revision_hash AS configured_revision_drift,
  COALESCE(revision_counts.revisions, 0) AS revisions,
  COALESCE(job_counts.jobs, 0) AS jobs,
  COALESCE(job_counts.queued_jobs, 0) AS queued_jobs,
  COALESCE(job_counts.running_jobs, 0) AS running_jobs,
  COALESCE(job_counts.cancel_requested_jobs, 0) AS cancel_requested_jobs,
  COALESCE(job_counts.terminal_jobs, 0) AS terminal_jobs,
  COALESCE(materialization_counts.materializations, 0) AS materializations,
  COALESCE(reconciliation_counts.reconciliation_subjects, 0) AS reconciliation_subjects,
  COALESCE(source_drift.source_relation_drift, false) AS source_relation_drift,
  task.lifecycle_state = 'active'
    AND head.active_workload_revision_hash IS NOT NULL
    AND COALESCE(job_counts.running_jobs, 0) = 0
    AND COALESCE(job_counts.cancel_requested_jobs, 0) = 0 AS can_pause,
  task.lifecycle_state = 'paused' AS can_resume,
  task.lifecycle_state = 'paused'
    AND COALESCE(job_counts.queued_jobs, 0) = 0
    AND COALESCE(job_counts.running_jobs, 0) = 0
    AND COALESCE(job_counts.cancel_requested_jobs, 0) = 0
    AND COALESCE(reconciliation_counts.reconciliation_subjects, 0) = 0
    AND NOT COALESCE(source_drift.source_relation_drift, false) AS can_retire,
  task.lifecycle_state = 'retired'
    AND watch.name IS NOT NULL
    AND head.task_name IS NULL
    AND COALESCE(job_counts.queued_jobs, 0) = 0
    AND COALESCE(job_counts.running_jobs, 0) = 0
    AND COALESCE(job_counts.cancel_requested_jobs, 0) = 0
    AND COALESCE(reconciliation_counts.reconciliation_subjects, 0) = 0
    AND NOT COALESCE(source_drift.source_relation_drift, false) AS can_drop_watch,
  CASE
    WHEN task.lifecycle_state <> 'retired' THEN 'task_not_retired'
    WHEN COALESCE(job_counts.queued_jobs, 0)
       + COALESCE(job_counts.running_jobs, 0)
       + COALESCE(job_counts.cancel_requested_jobs, 0) > 0 THEN 'unfinished_jobs'
    WHEN COALESCE(reconciliation_counts.reconciliation_subjects, 0) > 0 THEN 'watch_reconciliation'
    WHEN COALESCE(source_drift.source_relation_drift, false) THEN 'source_relation_identity_drift'
    WHEN watch.name IS NULL THEN 'retained_task_archive'
    ELSE 'ready'
  END AS watch_deletion_blocker
FROM otlet.tasks task
JOIN configured ON configured.task_name = task.name
LEFT JOIN otlet.watches watch ON watch.task_name = task.name
LEFT JOIN otlet.workload_revision_heads head ON head.task_name = task.name
LEFT JOIN job_counts ON job_counts.task_name = task.name
LEFT JOIN materialization_counts ON materialization_counts.task_name = task.name
LEFT JOIN revision_counts ON revision_counts.task_name = task.name
LEFT JOIN reconciliation_counts ON reconciliation_counts.task_name = task.name
LEFT JOIN source_drift ON source_drift.watch_name = watch.name;

REVOKE EXECUTE ON FUNCTION otlet.reject_task_lifecycle_bypass() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reject_task_delete() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_task_definition_write() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_workload_revision_head() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.sync_task_lifecycle_revision() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_watch_configuration() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.watch_source_relation_drift(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.lock_task_source_relations(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.repair_source_query_contract(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.ensure_active_workload_revision(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.promote_configured_workload_revision(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.watch_change_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.defer_watch_reconciliation(text, text, bigint, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.replay_watch_reconciliation(boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.drop_watch_row_index(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.drop_watch_registry(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.set_task_lifecycle(text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.drop_watch(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.drop_watch(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.current_workload_revision_status(text) FROM PUBLIC;
REVOKE ALL ON TABLE otlet.task_lifecycle_status FROM PUBLIC;
