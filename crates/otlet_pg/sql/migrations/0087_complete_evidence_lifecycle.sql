ALTER TABLE otlet.production_policy
ADD COLUMN evidence_lifecycle_enabled boolean NOT NULL DEFAULT false,
ADD COLUMN successful_job_retention interval,
ADD COLUMN evidence_max_chain_rows integer NOT NULL DEFAULT 1000,
ADD CONSTRAINT production_policy_successful_job_retention_bound CHECK (
  successful_job_retention IS NULL
  OR successful_job_retention >= interval '1 minute'
),
ADD CONSTRAINT production_policy_evidence_chain_rows_bound CHECK (
  evidence_max_chain_rows BETWEEN 1 AND 100000
);

COMMENT ON COLUMN otlet.production_policy.successful_job_retention IS
'Retention for complete production jobs; null disables automatic adoption';
COMMENT ON COLUMN otlet.production_policy.evidence_lifecycle_enabled IS
'Whether retention automatically adopts terminal jobs into governed export and deletion';
COMMENT ON COLUMN otlet.production_policy.evidence_max_chain_rows IS
'Maximum rows in one atomically archived and deleted evidence chain';

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.production_policy_status'::regclass,
    true
  );
  old_fragment := $old$    maintenance_max_time_ms
   FROM otlet.production_policy p$old$;
  new_fragment := $new$    maintenance_max_time_ms,
    governance_enforced,
    evidence_lifecycle_enabled,
    successful_job_retention,
    evidence_max_chain_rows
   FROM otlet.production_policy p$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence policy status rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.production_policy_status AS '
    || pg_catalog.replace(definition, old_fragment, new_fragment);
END;
$migration$;

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.record_administrative_row_change()'::regprocedure
  );
  IF position(
    $old$'governance_enforced', old_state -> 'governance_enforced'$old$
    IN definition
  ) = 0 OR position(
    $old$'governance_enforced', new_state -> 'governance_enforced'$old$
    IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet evidence retention ledger rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(
    definition,
    $old$'governance_enforced', old_state -> 'governance_enforced'$old$,
    $new$'governance_enforced', old_state -> 'governance_enforced',
          'evidence_lifecycle_enabled', old_state -> 'evidence_lifecycle_enabled',
          'successful_job_retention', old_state -> 'successful_job_retention',
          'evidence_max_chain_rows', old_state -> 'evidence_max_chain_rows'$new$
  );
  EXECUTE pg_catalog.replace(
    definition,
    $old$'governance_enforced', new_state -> 'governance_enforced'$old$,
    $new$'governance_enforced', new_state -> 'governance_enforced',
          'evidence_lifecycle_enabled', new_state -> 'evidence_lifecycle_enabled',
          'successful_job_retention', new_state -> 'successful_job_retention',
          'evidence_max_chain_rows', new_state -> 'evidence_max_chain_rows'$new$
  );
END;
$migration$;

DROP TRIGGER production_policy_retention_administrative_change
ON otlet.production_policy;

CREATE TRIGGER production_policy_retention_administrative_change
AFTER INSERT OR DELETE OR UPDATE OF worker_event_retention,
  trace_detail_retention, eval_label_retention,
  delete_stale_materialization_retention, sensitive_evidence_mode,
  sensitive_evidence_retention, failed_job_retention,
  governance_enforced, evidence_lifecycle_enabled,
  successful_job_retention, evidence_max_chain_rows
ON otlet.production_policy
FOR EACH ROW EXECUTE FUNCTION otlet.record_administrative_row_change();

CREATE TABLE otlet.evidence_lifecycle_records (
  job_id bigint PRIMARY KEY,
  task_name text NOT NULL CHECK (NULLIF(task_name, '') IS NOT NULL),
  workload_revision_hash text NOT NULL CHECK (
    workload_revision_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  terminal_status text NOT NULL CHECK (
    terminal_status IN ('complete', 'failed', 'canceled')
  ),
  terminal_at timestamptz NOT NULL,
  subject_identity_hash text NOT NULL CHECK (
    subject_identity_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  job_identity_hash text NOT NULL CHECK (
    job_identity_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  lifecycle_state text NOT NULL DEFAULT 'requested' CHECK (
    lifecycle_state IN ('requested', 'archived', 'deleted')
  ),
  generation bigint NOT NULL DEFAULT 0 CHECK (generation >= 0),
  retain_history boolean NOT NULL DEFAULT false,
  held boolean NOT NULL DEFAULT false,
  held_by_oid oid,
  held_by_name text,
  held_at timestamptz,
  archive_manifest_hash text CHECK (
    archive_manifest_hash IS NULL
    OR archive_manifest_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  archive_row_count integer CHECK (archive_row_count BETWEEN 1 AND 100000),
  archive_row_counts jsonb CHECK (
    archive_row_counts IS NULL OR jsonb_typeof(archive_row_counts) = 'object'
  ),
  export_state text NOT NULL DEFAULT 'unprepared' CHECK (
    export_state IN ('unprepared', 'pending', 'complete', 'failed')
  ),
  export_reference_hash text CHECK (
    export_reference_hash IS NULL
    OR export_reference_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  exported_by_oid oid,
  exported_by_name text,
  exported_at timestamptz,
  deleted_row_counts jsonb CHECK (
    deleted_row_counts IS NULL OR jsonb_typeof(deleted_row_counts) = 'object'
  ),
  tombstone_hash text CHECK (
    tombstone_hash IS NULL
    OR tombstone_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  requested_by_oid oid NOT NULL,
  requested_by_name text NOT NULL CHECK (
    NULLIF(requested_by_name, '') IS NOT NULL
  ),
  requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  deleted_at timestamptz,
  CHECK ((held_by_oid IS NULL) = (held_by_name IS NULL)),
  CHECK ((held_by_oid IS NULL) = (held_at IS NULL)),
  CHECK (held = (held_at IS NOT NULL)),
  CHECK (
    (lifecycle_state = 'requested'
      AND archive_manifest_hash IS NULL
      AND archive_row_count IS NULL
      AND archive_row_counts IS NULL
      AND export_state = 'unprepared'
      AND export_reference_hash IS NULL
      AND exported_at IS NULL
      AND deleted_row_counts IS NULL
      AND tombstone_hash IS NULL
      AND deleted_at IS NULL)
    OR
    (lifecycle_state = 'archived'
      AND archive_manifest_hash IS NOT NULL
      AND archive_row_count IS NOT NULL
      AND archive_row_counts IS NOT NULL
      AND export_state <> 'unprepared'
      AND (export_state = 'complete') = (exported_at IS NOT NULL)
      AND (export_state = 'complete') = (export_reference_hash IS NOT NULL)
      AND deleted_row_counts IS NULL
      AND tombstone_hash IS NULL
      AND deleted_at IS NULL)
    OR
    (lifecycle_state = 'deleted'
      AND archive_manifest_hash IS NOT NULL
      AND archive_row_count IS NOT NULL
      AND archive_row_counts IS NOT NULL
      AND export_state = 'complete'
      AND export_reference_hash IS NOT NULL
      AND exported_at IS NOT NULL
      AND deleted_row_counts IS NOT NULL
      AND tombstone_hash IS NOT NULL
      AND deleted_at IS NOT NULL)
  ),
  CHECK (
    (exported_by_oid IS NULL) = (exported_by_name IS NULL)
    AND (exported_by_oid IS NULL) = (exported_at IS NULL)
    AND (exported_by_oid IS NULL) = (export_reference_hash IS NULL)
  )
);

CREATE INDEX evidence_lifecycle_records_state_job_idx
ON otlet.evidence_lifecycle_records (lifecycle_state, job_id);

CREATE TABLE otlet.action_idempotency_tombstones (
  idempotency_key text PRIMARY KEY CHECK (
    idempotency_key ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  source_job_id bigint NOT NULL REFERENCES otlet.evidence_lifecycle_records(job_id),
  source_job_identity_hash text NOT NULL CHECK (
    source_job_identity_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  before_hash text CHECK (
    before_hash IS NULL OR before_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  result_hash text CHECK (
    result_hash IS NULL OR result_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  replay_metadata_hash text NOT NULL CHECK (
    replay_metadata_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  tombstone_hash text NOT NULL UNIQUE CHECK (
    tombstone_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  created_at timestamptz NOT NULL
);

CREATE INDEX action_idempotency_tombstones_source_idx
ON otlet.action_idempotency_tombstones (source_job_id, tombstone_hash);

CREATE INDEX action_execution_receipts_replay_source_idx
ON otlet.action_execution_receipts (replay_of_receipt_id)
WHERE replay_of_receipt_id IS NOT NULL;

CREATE INDEX portable_claims_evidence_job_idx
ON otlet.portable_claims (job_id);

CREATE INDEX watch_time_freshness_materialization_idx
ON otlet.watch_time_freshness (materialization_id);

CREATE INDEX task_backfill_subjects_covered_job_idx
ON otlet.task_backfill_subjects (covered_job_id)
WHERE covered_job_id IS NOT NULL;

ALTER TABLE otlet.action_execution_receipts
ADD COLUMN replay_of_tombstone_hash text REFERENCES
  otlet.action_idempotency_tombstones(tombstone_hash),
DROP CONSTRAINT action_execution_receipts_check1,
ADD CONSTRAINT action_execution_receipts_replay_reference_check CHECK (
  CASE WHEN status = 'replayed'
    THEN num_nonnulls(replay_of_receipt_id, replay_of_tombstone_hash) = 1
    ELSE num_nonnulls(replay_of_receipt_id, replay_of_tombstone_hash) = 0
  END
);

CREATE FUNCTION otlet.guard_evidence_lifecycle_record() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF current_setting('otlet.evidence_lifecycle_write', true) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'otlet evidence lifecycle state is function managed';
END;
$$;

CREATE TRIGGER evidence_lifecycle_records_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.evidence_lifecycle_records
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evidence_lifecycle_record();

CREATE TRIGGER evidence_lifecycle_records_truncate_guard
BEFORE TRUNCATE ON otlet.evidence_lifecycle_records
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evidence_lifecycle_record();

CREATE TRIGGER action_idempotency_tombstones_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.action_idempotency_tombstones
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evidence_lifecycle_record();

CREATE TRIGGER action_idempotency_tombstones_truncate_guard
BEFORE TRUNCATE ON otlet.action_idempotency_tombstones
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evidence_lifecycle_record();

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.apply_action(bigint)'::regprocedure
  );
  old_fragment := $old$  applied_receipt otlet.action_execution_receipts%ROWTYPE;$old$;
  new_fragment := $new$  applied_receipt otlet.action_execution_receipts%ROWTYPE;
  applied_tombstone otlet.action_idempotency_tombstones%ROWTYPE;$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet action replay tombstone declaration rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      SELECT * INTO applied_receipt
      FROM otlet.action_execution_receipts r
      WHERE r.idempotency_key = action_row.idempotency_key
        AND r.mode = 'apply'
        AND r.status = 'applied'
      ORDER BY r.id
      LIMIT 1;
    END IF;

    IF applied_receipt.id IS NOT NULL THEN$old$;
  new_fragment := $new$      SELECT * INTO applied_receipt
      FROM otlet.action_execution_receipts r
      WHERE r.idempotency_key = action_row.idempotency_key
        AND r.mode = 'apply'
        AND r.status = 'applied'
      ORDER BY r.id
      LIMIT 1;
      IF applied_receipt.id IS NULL THEN
        SELECT * INTO applied_tombstone
        FROM otlet.action_idempotency_tombstones tombstone
        WHERE tombstone.idempotency_key = action_row.idempotency_key;
        IF applied_tombstone.tombstone_hash IS NOT NULL
           AND applied_tombstone.replay_metadata_hash IS DISTINCT FROM
             otlet.identity_hash(
               'action_replay_metadata',
               jsonb_build_object(
                 'target_name', action_body ->> 'target',
                 'target_table', (
                   SELECT target.target_table::text
                   FROM otlet.action_targets target
                   WHERE target.name = action_body ->> 'target'
                 ),
                 'identity_hash', otlet.identity_hash(
                   'action_identity',
                   COALESCE(action_body -> 'identity', 'null'::jsonb)
                 ),
                 'changed_columns', to_jsonb(ARRAY(
                   SELECT key::name
                   FROM jsonb_object_keys(
                     COALESCE(action_body -> 'changes', '{}'::jsonb)
                   ) key
                   ORDER BY key
                 ))
               )
             ) THEN
          validation_error := 'action replay metadata changed after evidence deletion';
        END IF;
      END IF;
    END IF;

    IF validation_error IS NULL
       AND (applied_receipt.id IS NOT NULL
         OR applied_tombstone.tombstone_hash IS NOT NULL) THEN$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet action replay tombstone lookup rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$        result_hash,
        replay_of_receipt_id
      )$old$;
  new_fragment := $new$        result_hash,
        replay_of_receipt_id,
        replay_of_tombstone_hash
      )$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet action replay tombstone column rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$        applied_receipt.target_name,
        applied_receipt.target_table,
        applied_receipt.identity_hash,
        applied_receipt.changed_columns,
        0,
        applied_receipt.before_hash,
        applied_receipt.result_hash,
        applied_receipt.id
      );$old$;
  new_fragment := $new$        COALESCE(applied_receipt.target_name, action_body ->> 'target', ''),
        COALESCE(
          applied_receipt.target_table,
          (
            SELECT target.target_table::text
            FROM otlet.action_targets target
            WHERE target.name = action_body ->> 'target'
          ),
          action_row.source_table,
          ''
        ),
        COALESCE(
          applied_receipt.identity_hash,
          otlet.identity_hash(
            'action_identity',
            COALESCE(action_body -> 'identity', 'null'::jsonb)
          )
        ),
        COALESCE(
          applied_receipt.changed_columns,
          ARRAY(
            SELECT key::name
            FROM jsonb_object_keys(
              COALESCE(action_body -> 'changes', '{}'::jsonb)
            ) key
            ORDER BY key
          )
        ),
        0,
        COALESCE(applied_receipt.before_hash, applied_tombstone.before_hash),
        COALESCE(applied_receipt.result_hash, applied_tombstone.result_hash),
        applied_receipt.id,
        applied_tombstone.tombstone_hash
      );$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet action replay tombstone receipt rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_viewdef('otlet.action_status'::regclass, true);
  old_fragment := E'    execution.replay_of_receipt_id\n   FROM otlet.actions a';
  new_fragment := E'    execution.replay_of_receipt_id,\n'
    || E'    execution.replay_of_tombstone_hash AS '
    || E'execution_replay_of_tombstone_hash\n   FROM otlet.actions a';
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet action status tombstone replay rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  old_fragment := E'            er.replay_of_receipt_id,\n'
    || E'            er.created_at';
  new_fragment := E'            er.replay_of_receipt_id,\n'
    || E'            er.replay_of_tombstone_hash,\n'
    || E'            er.created_at';
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet action status replay source rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.action_status AS '
    || pg_catalog.replace(definition, old_fragment, new_fragment);

  definition := pg_catalog.pg_get_viewdef(
    'otlet.audit_action_execution_export'::regclass,
    true
  );
  old_fragment := E'    er.created_at\n   FROM otlet.action_execution_receipts er';
  new_fragment := E'    er.created_at,\n'
    || E'    er.replay_of_tombstone_hash\n'
    || E'   FROM otlet.action_execution_receipts er';
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet action audit tombstone replay rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.audit_action_execution_export AS '
    || pg_catalog.replace(definition, old_fragment, new_fragment);
END;
$migration$;

CREATE FUNCTION otlet.guard_evidence_lifecycle_job_delete() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF current_setting('otlet.evidence_lifecycle_cleanup', true) = 'on'
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.evidence_lifecycle_records record
       WHERE record.job_id = OLD.id
         AND record.lifecycle_state <> 'deleted'
     ) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'otlet evidence job % is lifecycle managed', OLD.id;
END;
$$;

CREATE TRIGGER jobs_evidence_lifecycle_delete_guard
BEFORE DELETE ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evidence_lifecycle_job_delete();

CREATE FUNCTION otlet.evidence_job_label_ids(requested_job_id bigint)
RETURNS TABLE (label_id bigint)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  WITH RECURSIVE label_series(id, supersedes_label_id) AS (
    SELECT label.id, label.supersedes_label_id
    FROM otlet.eval_labels label
    LEFT JOIN otlet.actions action ON action.id = label.action_id
    LEFT JOIN otlet.outputs output ON output.id = label.output_id
    LEFT JOIN otlet.inference_receipts receipt ON receipt.id = label.receipt_id
    WHERE action.job_id = $1 OR output.job_id = $1 OR receipt.job_id = $1

    UNION

    SELECT label.id, label.supersedes_label_id
    FROM otlet.eval_labels label
    JOIN label_series member
      ON label.supersedes_label_id = member.id
      OR label.id = member.supersedes_label_id
  )
  SELECT id
  FROM label_series;
$$;

CREATE FUNCTION otlet.evidence_lifecycle_manages_job(requested_job_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT requested_job_id IS NOT NULL AND (
    EXISTS (
      SELECT 1
      FROM otlet.evidence_lifecycle_records record
      WHERE record.job_id = requested_job_id
        AND record.lifecycle_state <> 'deleted'
    )
    OR EXISTS (
      SELECT 1
      FROM otlet.jobs job
      CROSS JOIN otlet.production_policy policy
      WHERE job.id = requested_job_id
        AND policy.name = 'default'
        AND policy.evidence_lifecycle_enabled
        AND job.execution_mode = 'production'
        AND job.status IN ('complete', 'failed', 'canceled')
        AND (
          (job.status = 'complete'
            AND policy.successful_job_retention IS NOT NULL
            AND COALESCE(job.finished_at, job.created_at) <
              statement_timestamp() - policy.successful_job_retention)
          OR
          (job.status IN ('failed', 'canceled')
            AND COALESCE(job.finished_at, job.created_at) <
              statement_timestamp() - policy.failed_job_retention)
        )
    )
  );
$$;

CREATE FUNCTION otlet.evidence_lifecycle_manages_label_series(
  requested_task_name text,
  requested_source_table text,
  requested_subject_id text
) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM otlet.eval_labels label
    LEFT JOIN otlet.actions action ON action.id = label.action_id
    LEFT JOIN otlet.outputs output ON output.id = label.output_id
    LEFT JOIN otlet.inference_receipts receipt ON receipt.id = label.receipt_id
    WHERE label.task_name = requested_task_name
      AND label.source_table IS NOT DISTINCT FROM requested_source_table
      AND label.subject_id = requested_subject_id
      AND (
        otlet.evidence_lifecycle_manages_job(action.job_id)
        OR otlet.evidence_lifecycle_manages_job(output.job_id)
        OR otlet.evidence_lifecycle_manages_job(receipt.job_id)
      )
  );
$$;

CREATE FUNCTION otlet.evidence_lifecycle_manages_materialization(
  requested_materialization_id bigint
) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations materialization
    JOIN otlet.records record ON record.id = materialization.record_id
    JOIN otlet.actions action ON action.id = record.action_id
    WHERE materialization.id = requested_materialization_id
      AND otlet.evidence_lifecycle_manages_job(action.job_id)
  );
$$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.cleanup_policy_state_without_label_quality(boolean)'::regprocedure
  );

  old_fragment := $old$    WHERE j.status IN ('failed', 'canceled')$old$;
  new_fragment := $new$    WHERE NOT otlet.evidence_lifecycle_manages_job(j.id)
      AND j.status IN ('failed', 'canceled')$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence job cleanup preview fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      WHERE e.created_at < now() - worker_retention$old$;
  new_fragment := $new$      WHERE NOT otlet.evidence_lifecycle_manages_job(e.job_id)
        AND e.created_at < now() - worker_retention$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence event cleanup preview fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$    WHERE r.finished_at < now() - trace_retention$old$;
  new_fragment := $new$    WHERE NOT otlet.evidence_lifecycle_manages_job(r.job_id)
      AND r.finished_at < now() - trace_retention$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence trace cleanup preview fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  FROM otlet.semantic_materializations sm
  WHERE sm.stale$old$;
  new_fragment := $new$  FROM otlet.semantic_materializations sm
  WHERE NOT otlet.evidence_lifecycle_manages_materialization(sm.id)
    AND sm.stale$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence materialization cleanup preview fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  FROM otlet.inference_receipts r
  WHERE sensitive_mode = 'redacted'$old$;
  new_fragment := $new$  FROM otlet.inference_receipts r
  WHERE NOT otlet.evidence_lifecycle_manages_job(r.job_id)
    AND (sensitive_mode = 'redacted'$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet sensitive output cleanup preview fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  old_fragment := $old$     OR r.finished_at < now() - sensitive_retention;$old$;
  new_fragment := $new$     OR r.finished_at < now() - sensitive_retention);$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet sensitive output cleanup preview grouping is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  WHERE (sensitive_mode = 'redacted' OR r.finished_at < now() - sensitive_retention)$old$;
  new_fragment := $new$  WHERE NOT otlet.evidence_lifecycle_manages_job(r.job_id)
    AND (sensitive_mode = 'redacted' OR r.finished_at < now() - sensitive_retention)$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet sensitive trace cleanup preview fence is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);

  definition := pg_catalog.pg_get_functiondef(
    'otlet.cleanup_eval_label_series(timestamptz,boolean)'::regprocedure
  );
  old_fragment := $old$      WHERE status.last_event_at < cleanup_eval_label_series.cutoff$old$;
  new_fragment := $new$      WHERE NOT otlet.evidence_lifecycle_manages_label_series(
          status.task_name,
          status.source_table,
          status.subject_id
        )
        AND status.last_event_at < cleanup_eval_label_series.cutoff$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence label cleanup preview fence is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
END;
$migration$;

CREATE FUNCTION otlet.evidence_archive_row_count_bounded(
  requested_job_id bigint,
  requested_max_rows integer
) RETURNS integer
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  bounded_count integer;
BEGIN
  IF requested_max_rows NOT BETWEEN 1 AND 100000 THEN
    RAISE EXCEPTION 'otlet evidence chain limit must be between 1 and 100000';
  END IF;
  SELECT count(*)::integer INTO bounded_count
  FROM (
    SELECT 1
    FROM (
      SELECT 1 FROM otlet.jobs job WHERE job.id = requested_job_id
      UNION ALL
      SELECT 1 FROM otlet.inference_receipts receipt
      WHERE receipt.job_id = requested_job_id
      UNION ALL
      SELECT 1 FROM otlet.outputs output
      WHERE output.job_id = requested_job_id
      UNION ALL
      SELECT 1 FROM otlet.actions action
      WHERE action.job_id = requested_job_id
      UNION ALL
      SELECT 1
      FROM otlet.action_execution_receipts execution
      JOIN otlet.actions action ON action.id = execution.action_id
      WHERE action.job_id = requested_job_id
      UNION ALL
      SELECT 1
      FROM otlet.records record
      JOIN otlet.actions action ON action.id = record.action_id
      WHERE action.job_id = requested_job_id
      UNION ALL
      SELECT 1
      FROM otlet.semantic_materializations materialization
      JOIN otlet.records record ON record.id = materialization.record_id
      JOIN otlet.actions action ON action.id = record.action_id
      WHERE action.job_id = requested_job_id
      UNION ALL
      SELECT 1
      FROM otlet.watch_time_freshness freshness
      JOIN otlet.semantic_materializations materialization
        ON materialization.id = freshness.materialization_id
      JOIN otlet.records record ON record.id = materialization.record_id
      JOIN otlet.actions action ON action.id = record.action_id
      WHERE action.job_id = requested_job_id
      UNION ALL
      SELECT 1 FROM otlet.review_events review
      WHERE review.job_id = requested_job_id
      UNION ALL
      SELECT 1 FROM otlet.review_samples sample
      WHERE sample.job_id = requested_job_id
      UNION ALL
      SELECT 1 FROM otlet.evidence_job_label_ids(requested_job_id)
      UNION ALL
      SELECT 1
      FROM otlet.reviewer_review_errors review_error
      JOIN otlet.review_events review
        ON review.id = review_error.review_event_id
      WHERE review.job_id = requested_job_id
      UNION ALL
      SELECT 1 FROM otlet.worker_events event
      WHERE event.job_id = requested_job_id
      UNION ALL
      SELECT 1 FROM otlet.portable_claims claim
      WHERE claim.job_id = requested_job_id
      UNION ALL
      SELECT 1
      FROM otlet.portable_receipt_links link
      JOIN otlet.inference_receipts receipt ON receipt.id = link.receipt_id
      WHERE receipt.job_id = requested_job_id
    ) evidence
    LIMIT requested_max_rows + 1
  ) bounded;
  RETURN bounded_count;
END;
$$;

CREATE FUNCTION otlet.acquire_evidence_mutation_barrier() RETURNS boolean
LANGUAGE sql
VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT pg_catalog.pg_try_advisory_xact_lock(
    database.oid::integer,
    1330924613
  )
  FROM pg_catalog.pg_database database
  WHERE database.datname = current_database();
$$;

CREATE FUNCTION otlet.guard_evidence_mutation_barrier() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  database_oid integer;
BEGIN
  SELECT database.oid::integer INTO STRICT database_oid
  FROM pg_catalog.pg_database database
  WHERE database.datname = current_database();
  IF NOT pg_catalog.pg_try_advisory_xact_lock_shared(
    database_oid,
    1330924613
  ) THEN
    RAISE EXCEPTION 'otlet evidence lifecycle maintenance is active'
      USING ERRCODE = '55P03';
  END IF;
  RETURN NULL;
END;
$$;

DO $migration$
DECLARE
  relation_name text;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY[
    'action_execution_receipts',
    'action_idempotency_tombstones',
    'actions',
    'eval_labels',
    'evaluation_cases',
    'evaluation_executions',
    'evaluation_results',
    'evidence_lifecycle_records',
    'inference_receipts',
    'jobs',
    'outputs',
    'pair_constraint_facts',
    'portable_claims',
    'portable_receipt_links',
    'production_model_cancellation_probes',
    'production_model_database_samples',
    'production_policy',
    'records',
    'review_events',
    'review_samples',
    'reviewer_review_errors',
    'semantic_correction_overrides',
    'semantic_materializations',
    'task_backfill_subjects',
    'watch_time_freshness',
    'worker_events'
  ]::text[]
  LOOP
    EXECUTE pg_catalog.format(
      'CREATE TRIGGER evidence_mutation_barrier '
      'BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON otlet.%I '
      'FOR EACH STATEMENT EXECUTE FUNCTION '
      'otlet.guard_evidence_mutation_barrier()',
      relation_name
    );
  END LOOP;
END;
$migration$;

CREATE FUNCTION otlet.guard_evidence_review_event_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  PERFORM 1
  FROM otlet.jobs job
  WHERE job.id = NEW.job_id
  FOR KEY SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet review event job % does not exist', NEW.job_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER review_events_a_evidence_job
BEFORE INSERT ON otlet.review_events
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evidence_review_event_insert();

CREATE FUNCTION otlet.evidence_archive_rows(requested_job_id bigint)
RETURNS TABLE (
  evidence_kind text,
  evidence_key text,
  row_hash text,
  evidence jsonb
)
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
SET TimeZone = 'UTC'
AS $$
DECLARE
  max_rows integer;
BEGIN
  SELECT policy.evidence_max_chain_rows INTO STRICT max_rows
  FROM otlet.production_policy policy
  WHERE policy.name = 'default';
  IF otlet.evidence_archive_row_count_bounded($1, max_rows) > max_rows THEN
    RAISE EXCEPTION 'otlet evidence job % exceeds the chain limit', $1;
  END IF;
  RETURN QUERY
  WITH archived AS (
    SELECT 'job'::text AS kind, job.id::text AS key,
      to_jsonb(job) - ARRAY['claim_token', 'terminal_claim_token'] AS body
    FROM otlet.jobs job
    WHERE job.id = $1

    UNION ALL

    SELECT 'receipt', receipt.id::text, to_jsonb(receipt)
    FROM otlet.inference_receipts receipt
    WHERE receipt.job_id = $1

    UNION ALL

    SELECT 'output', output.id::text, to_jsonb(output)
    FROM otlet.outputs output
    WHERE output.job_id = $1

    UNION ALL

    SELECT 'action', action.id::text, to_jsonb(action)
    FROM otlet.actions action
    WHERE action.job_id = $1

    UNION ALL

    SELECT 'action_execution_receipt', execution.id::text, to_jsonb(execution)
    FROM otlet.action_execution_receipts execution
    JOIN otlet.actions action ON action.id = execution.action_id
    WHERE action.job_id = $1

    UNION ALL

    SELECT 'record', record.id::text, to_jsonb(record)
    FROM otlet.records record
    JOIN otlet.actions action ON action.id = record.action_id
    WHERE action.job_id = $1

    UNION ALL

    SELECT 'semantic_materialization', materialization.id::text,
      to_jsonb(materialization)
    FROM otlet.semantic_materializations materialization
    JOIN otlet.records record ON record.id = materialization.record_id
    JOIN otlet.actions action ON action.id = record.action_id
    WHERE action.job_id = $1

    UNION ALL

    SELECT 'watch_time_freshness',
      jsonb_build_array(
        freshness.watch_name,
        freshness.workload_revision_hash,
        freshness.subject_id
      )::text,
      to_jsonb(freshness)
    FROM otlet.watch_time_freshness freshness
    JOIN otlet.semantic_materializations materialization
      ON materialization.id = freshness.materialization_id
    JOIN otlet.records record ON record.id = materialization.record_id
    JOIN otlet.actions action ON action.id = record.action_id
    WHERE action.job_id = $1

    UNION ALL

    SELECT 'review_event', review.id::text, to_jsonb(review)
    FROM otlet.review_events review
    WHERE review.job_id = $1

    UNION ALL

    SELECT 'review_sample', sample.sample_hash, to_jsonb(sample)
    FROM otlet.review_samples sample
    WHERE sample.job_id = $1

    UNION ALL

    SELECT 'eval_label', label.id::text, to_jsonb(label)
    FROM otlet.eval_labels label
    JOIN otlet.evidence_job_label_ids($1) member ON member.label_id = label.id

    UNION ALL

    SELECT 'reviewer_review_error', review_error.review_error_hash,
      to_jsonb(review_error)
    FROM otlet.reviewer_review_errors review_error
    JOIN otlet.review_events review
      ON review.id = review_error.review_event_id
    WHERE review.job_id = $1

    UNION ALL

    SELECT 'worker_event', event.id::text, to_jsonb(event)
    FROM otlet.worker_events event
    WHERE event.job_id = $1

    UNION ALL

    SELECT 'portable_claim', claim.id::text, to_jsonb(claim)
    FROM otlet.portable_claims claim
    WHERE claim.job_id = $1

    UNION ALL

    SELECT 'portable_receipt_link', link.receipt_id::text, to_jsonb(link)
    FROM otlet.portable_receipt_links link
    JOIN otlet.inference_receipts receipt ON receipt.id = link.receipt_id
    WHERE receipt.job_id = $1
  )
  SELECT
    archived.kind,
    archived.key,
    otlet.identity_hash(
      'evidence_archive_row',
      jsonb_build_object(
        'kind', archived.kind,
        'key', archived.key,
        'evidence', archived.body
      )
    ),
    archived.body
  FROM archived
  ORDER BY archived.kind, archived.key COLLATE "C";
END;
$$;

CREATE FUNCTION otlet.evidence_archive_manifest(requested_job_id bigint)
RETURNS TABLE (
  row_count integer,
  row_counts jsonb,
  manifest_hash text
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
SET TimeZone = 'UTC'
AS $$
  WITH archived AS MATERIALIZED (
    SELECT evidence_kind, evidence_key, row_hash
    FROM otlet.evidence_archive_rows($1)
  ), counts AS (
    SELECT jsonb_object_agg(kind, count ORDER BY kind) AS value
    FROM (
      SELECT evidence_kind AS kind, count(*)::integer AS count
      FROM archived
      GROUP BY evidence_kind
    ) grouped
  ), manifest AS (
    SELECT
      count(*)::integer AS count,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'kind', evidence_kind,
            'key', evidence_key,
            'hash', row_hash
          ) ORDER BY evidence_kind, evidence_key COLLATE "C"
        ),
        '[]'::jsonb
      ) AS rows
    FROM archived
  )
  SELECT
    manifest.count,
    COALESCE(counts.value, '{}'::jsonb),
    otlet.identity_hash(
      'evidence_archive_manifest',
      jsonb_build_object(
        'format', 'otlet.evidence.archive.v1',
        'job_id', $1,
        'rows', manifest.rows
      )
    )
  FROM manifest
  CROSS JOIN counts;
$$;

CREATE FUNCTION otlet.evidence_delete_blockers(requested_job_id bigint)
RETURNS text[]
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  lifecycle otlet.evidence_lifecycle_records%ROWTYPE;
  job otlet.jobs%ROWTYPE;
  policy otlet.production_policy%ROWTYPE;
  archive record;
  blockers text[] := ARRAY[]::text[];
  bounded_row_count integer;
  retention interval;
BEGIN
  SELECT * INTO lifecycle
  FROM otlet.evidence_lifecycle_records record
  WHERE record.job_id = requested_job_id;
  IF NOT FOUND THEN
    RETURN ARRAY['not_registered']::text[];
  END IF;
  IF lifecycle.lifecycle_state = 'deleted' THEN
    RETURN ARRAY['already_deleted']::text[];
  END IF;

  SELECT * INTO job FROM otlet.jobs WHERE id = requested_job_id;
  IF NOT FOUND THEN
    RETURN ARRAY['live_job_missing']::text[];
  END IF;
  SELECT * INTO STRICT policy
  FROM otlet.production_policy
  WHERE name = 'default';

  IF lifecycle.held THEN
    blockers := array_append(blockers, 'held');
  END IF;
  IF job.execution_mode IS DISTINCT FROM 'production'
     OR job.task_name IS DISTINCT FROM lifecycle.task_name
     OR job.workload_revision_hash IS DISTINCT FROM
       lifecycle.workload_revision_hash
     OR job.status IS DISTINCT FROM lifecycle.terminal_status
     OR COALESCE(job.finished_at, job.created_at) IS DISTINCT FROM
       lifecycle.terminal_at
     OR lifecycle.subject_identity_hash IS DISTINCT FROM otlet.identity_hash(
       'evidence_subject',
       jsonb_build_object(
         'task_name', job.task_name,
         'subject_id', job.subject_id
       )
     )
     OR lifecycle.job_identity_hash IS DISTINCT FROM otlet.identity_hash(
       'evidence_job',
       jsonb_build_object(
         'job_id', job.id,
         'task_name', job.task_name,
         'workload_revision_hash', job.workload_revision_hash,
         'subject_id', job.subject_id,
         'terminal_status', job.status,
         'terminal_at', extract(epoch FROM COALESCE(job.finished_at, job.created_at))
       )
  ) THEN
    blockers := array_append(blockers, 'snapshot_changed');
  END IF;
  IF job.status NOT IN ('complete', 'failed', 'canceled') THEN
    blockers := array_append(blockers, 'non_terminal');
  END IF;
  IF lifecycle.lifecycle_state = 'requested' THEN
    blockers := array_append(blockers, 'archive_pending');
  END IF;

  retention := CASE
    WHEN lifecycle.terminal_status = 'complete'
      THEN policy.successful_job_retention
    ELSE policy.failed_job_retention
  END;
  IF retention IS NULL THEN
    blockers := array_append(blockers, 'retention_disabled');
  ELSIF lifecycle.terminal_at + retention > statement_timestamp() THEN
    blockers := array_append(blockers, 'retention_not_due');
  END IF;
  IF lifecycle.retain_history THEN
    blockers := array_append(blockers, 'history_retained');
  END IF;
  IF lifecycle.export_state IN ('unprepared', 'pending') THEN
    blockers := array_append(blockers, 'export_incomplete');
  ELSIF lifecycle.export_state = 'failed' THEN
    blockers := array_append(blockers, 'export_failed');
  END IF;

  bounded_row_count := otlet.evidence_archive_row_count_bounded(
    requested_job_id,
    policy.evidence_max_chain_rows
  );
  IF bounded_row_count > policy.evidence_max_chain_rows THEN
    blockers := array_append(blockers, 'chain_too_large');
  ELSIF lifecycle.archive_manifest_hash IS NOT NULL THEN
    SELECT * INTO archive
    FROM otlet.evidence_archive_manifest(requested_job_id);
    IF archive.manifest_hash IS DISTINCT FROM
       lifecycle.archive_manifest_hash THEN
      blockers := array_append(blockers, 'export_stale');
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM otlet.jobs retry
    WHERE retry.retry_of_job_id = requested_job_id
  ) THEN
    blockers := array_append(blockers, 'retry_successor');
  END IF;
  IF EXISTS (
    SELECT 1 FROM otlet.task_backfill_subjects subject
    WHERE subject.covered_job_id = requested_job_id
  ) THEN
    blockers := array_append(blockers, 'backfill_coverage');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM otlet.actions action
    WHERE action.job_id = requested_job_id
      AND action.status NOT IN ('complete', 'rejected', 'applied')
  ) THEN
    blockers := array_append(blockers, 'action_not_terminal');
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations materialization
    JOIN otlet.records record ON record.id = materialization.record_id
    JOIN otlet.actions action ON action.id = record.action_id
    WHERE action.job_id = requested_job_id
      AND NOT materialization.stale
  ) THEN
    blockers := array_append(blockers, 'record_materialized');
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.eval_labels label
    JOIN otlet.evidence_job_label_ids(requested_job_id) member
      ON member.label_id = label.id
    LEFT JOIN otlet.actions action ON action.id = label.action_id
    LEFT JOIN otlet.outputs output ON output.id = label.output_id
    LEFT JOIN otlet.inference_receipts receipt ON receipt.id = label.receipt_id
    WHERE (action.job_id IS NOT NULL AND action.job_id <> requested_job_id)
       OR (output.job_id IS NOT NULL AND output.job_id <> requested_job_id)
       OR (receipt.job_id IS NOT NULL AND receipt.job_id <> requested_job_id)
  ) THEN
    blockers := array_append(blockers, 'cross_job_label_series');
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.evaluation_cases evaluation_case
    JOIN otlet.evidence_job_label_ids(requested_job_id) label
      ON label.label_id = evaluation_case.label_id
  ) THEN
    blockers := array_append(blockers, 'evaluation_case');
  END IF;
  IF EXISTS (
    SELECT 1 FROM otlet.evaluation_executions execution
    WHERE execution.job_id = requested_job_id
  ) OR EXISTS (
    SELECT 1 FROM otlet.evaluation_results result
    WHERE result.job_id = requested_job_id
       OR result.output_id IN (
         SELECT output.id FROM otlet.outputs output
         WHERE output.job_id = requested_job_id
       )
       OR result.receipt_id IN (
         SELECT receipt.id FROM otlet.inference_receipts receipt
         WHERE receipt.job_id = requested_job_id
       )
  ) THEN
    blockers := array_append(blockers, 'evaluation_history');
  END IF;
  IF EXISTS (
    SELECT 1 FROM otlet.production_model_cancellation_probes probe
    WHERE probe.job_id = requested_job_id
  ) OR EXISTS (
    SELECT 1 FROM otlet.production_model_database_samples sample
    WHERE sample.live_job_id = requested_job_id
  ) THEN
    blockers := array_append(blockers, 'model_qualification_history');
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.review_events review
    WHERE review.job_id = requested_job_id
      AND review.reviewer_calibration_hash IS NOT NULL
  ) OR EXISTS (
    SELECT 1
    FROM otlet.reviewer_review_errors review_error
    JOIN otlet.review_events review
      ON review.id = review_error.review_event_id
    WHERE review.job_id = requested_job_id
  ) THEN
    blockers := array_append(blockers, 'review_calibration_history');
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.semantic_correction_overrides correction
    WHERE correction.correction_label_id IN (
        SELECT label_id FROM otlet.evidence_job_label_ids(requested_job_id)
      )
       OR correction.review_event_id IN (
        SELECT review.id FROM otlet.review_events review
        WHERE review.job_id = requested_job_id
      )
       OR correction.original_action_id IN (
        SELECT action.id FROM otlet.actions action
        WHERE action.job_id = requested_job_id
      )
       OR correction.original_output_id IN (
        SELECT output.id FROM otlet.outputs output
        WHERE output.job_id = requested_job_id
      )
       OR correction.original_receipt_id IN (
        SELECT receipt.id FROM otlet.inference_receipts receipt
        WHERE receipt.job_id = requested_job_id
      )
       OR correction.materialization_id IN (
        SELECT materialization.id
        FROM otlet.semantic_materializations materialization
        JOIN otlet.records record ON record.id = materialization.record_id
        JOIN otlet.actions action ON action.id = record.action_id
        WHERE action.job_id = requested_job_id
      )
  ) THEN
    blockers := array_append(blockers, 'semantic_correction');
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.pair_constraint_facts fact
    WHERE fact.correction_label_id IN (
        SELECT label_id FROM otlet.evidence_job_label_ids(requested_job_id)
      )
       OR fact.review_event_id IN (
        SELECT review.id FROM otlet.review_events review
        WHERE review.job_id = requested_job_id
      )
       OR fact.prior_review_event_id IN (
        SELECT review.id FROM otlet.review_events review
        WHERE review.job_id = requested_job_id
      )
  ) THEN
    blockers := array_append(blockers, 'pair_constraint');
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.action_execution_receipts external_receipt
    JOIN otlet.actions external_action
      ON external_action.id = external_receipt.action_id
    WHERE external_action.job_id <> requested_job_id
      AND external_receipt.replay_of_receipt_id IN (
        SELECT receipt.id
        FROM otlet.action_execution_receipts receipt
        JOIN otlet.actions action ON action.id = receipt.action_id
        WHERE action.job_id = requested_job_id
      )
  ) THEN
    blockers := array_append(blockers, 'action_receipt_replay');
  END IF;

  RETURN blockers;
END;
$$;

CREATE FUNCTION otlet.evidence_lifecycle_revision(requested_job_id bigint)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
SET TimeZone = 'UTC'
AS $$
  SELECT otlet.administrative_state_hash(
    'retention',
    to_jsonb(record) - ARRAY['updated_at']
  )
  FROM otlet.evidence_lifecycle_records record
  WHERE record.job_id = $1;
$$;

CREATE FUNCTION otlet.request_evidence_lifecycle(
  requested_job_id bigint,
  requested_retain_history boolean,
  requested_reason text DEFAULT NULL,
  requested_ticket text DEFAULT NULL
) RETURNS otlet.evidence_lifecycle_records
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  job otlet.jobs%ROWTYPE;
  existing otlet.evidence_lifecycle_records%ROWTYPE;
  saved otlet.evidence_lifecycle_records%ROWTYPE;
  actor_oid oid;
  previous_write text := current_setting('otlet.evidence_lifecycle_write', true);
  next_revision text;
BEGIN
  IF requested_retain_history IS NULL THEN
    RAISE EXCEPTION 'otlet evidence history choice is required';
  END IF;
  IF NOT otlet.acquire_evidence_mutation_barrier() THEN
    RAISE EXCEPTION 'otlet evidence lifecycle mutation is active'
      USING ERRCODE = '55P03';
  END IF;
  PERFORM otlet.set_administrative_change_context(
    requested_reason,
    requested_ticket
  );
  SELECT * INTO job
  FROM otlet.jobs
  WHERE id = requested_job_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evidence job % does not exist', requested_job_id;
  END IF;
  IF job.execution_mode <> 'production'
     OR job.status NOT IN ('complete', 'failed', 'canceled') THEN
    RAISE EXCEPTION 'otlet evidence lifecycle requires a terminal production job';
  END IF;

  SELECT * INTO existing
  FROM otlet.evidence_lifecycle_records record
  WHERE record.job_id = requested_job_id
  FOR UPDATE;
  IF FOUND THEN
    IF existing.retain_history IS NOT DISTINCT FROM requested_retain_history THEN
      RETURN existing;
    END IF;
    RAISE EXCEPTION 'otlet evidence lifecycle % already has a different history choice',
      requested_job_id;
  END IF;

  SELECT role.oid INTO STRICT actor_oid
  FROM pg_catalog.pg_roles role
  WHERE role.rolname = current_user;
  PERFORM set_config('otlet.evidence_lifecycle_write', 'on', true);
  INSERT INTO otlet.evidence_lifecycle_records (
    job_id,
    task_name,
    workload_revision_hash,
    terminal_status,
    terminal_at,
    subject_identity_hash,
    job_identity_hash,
    retain_history,
    requested_by_oid,
    requested_by_name
  ) VALUES (
    job.id,
    job.task_name,
    job.workload_revision_hash,
    job.status,
    COALESCE(job.finished_at, job.created_at),
    otlet.identity_hash(
      'evidence_subject',
      jsonb_build_object('task_name', job.task_name, 'subject_id', job.subject_id)
    ),
    otlet.identity_hash(
      'evidence_job',
      jsonb_build_object(
        'job_id', job.id,
        'task_name', job.task_name,
        'workload_revision_hash', job.workload_revision_hash,
        'subject_id', job.subject_id,
        'terminal_status', job.status,
        'terminal_at', extract(epoch FROM COALESCE(job.finished_at, job.created_at))
      )
    ),
    requested_retain_history,
    actor_oid,
    current_user
  )
  RETURNING * INTO saved;
  PERFORM set_config(
    'otlet.evidence_lifecycle_write',
    COALESCE(previous_write, ''),
    true
  );
  next_revision := otlet.evidence_lifecycle_revision(requested_job_id);
  PERFORM otlet.append_administrative_change(
    'retention',
    'job:' || requested_job_id::text,
    'request',
    NULL,
    next_revision
  );
  RETURN saved;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config(
    'otlet.evidence_lifecycle_write',
    COALESCE(previous_write, ''),
    true
  );
  RAISE;
END;
$$;

CREATE FUNCTION otlet.set_evidence_history_retention(
  requested_job_id bigint,
  expected_generation bigint,
  requested_retain_history boolean,
  requested_reason text DEFAULT NULL,
  requested_ticket text DEFAULT NULL
) RETURNS otlet.evidence_lifecycle_records
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  lifecycle otlet.evidence_lifecycle_records%ROWTYPE;
  saved otlet.evidence_lifecycle_records%ROWTYPE;
  old_revision text;
  new_revision text;
  previous_write text := current_setting('otlet.evidence_lifecycle_write', true);
BEGIN
  IF requested_retain_history IS NULL THEN
    RAISE EXCEPTION 'otlet evidence history choice is required';
  END IF;
  PERFORM otlet.set_administrative_change_context(
    requested_reason,
    requested_ticket
  );
  SELECT * INTO lifecycle
  FROM otlet.evidence_lifecycle_records record
  WHERE record.job_id = requested_job_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evidence lifecycle % does not exist', requested_job_id;
  END IF;
  IF lifecycle.lifecycle_state = 'deleted' THEN
    RAISE EXCEPTION 'otlet evidence lifecycle % is already deleted', requested_job_id;
  END IF;
  IF lifecycle.retain_history IS NOT DISTINCT FROM requested_retain_history THEN
    RETURN lifecycle;
  END IF;
  IF expected_generation IS NULL
     OR expected_generation <> lifecycle.generation THEN
    RAISE EXCEPTION 'otlet evidence lifecycle % generation changed', requested_job_id;
  END IF;

  old_revision := otlet.evidence_lifecycle_revision(requested_job_id);
  PERFORM set_config('otlet.evidence_lifecycle_write', 'on', true);
  UPDATE otlet.evidence_lifecycle_records record
  SET retain_history = requested_retain_history,
      generation = generation + 1,
      updated_at = clock_timestamp()
  WHERE record.job_id = requested_job_id
  RETURNING * INTO saved;
  PERFORM set_config(
    'otlet.evidence_lifecycle_write',
    COALESCE(previous_write, ''),
    true
  );
  new_revision := otlet.evidence_lifecycle_revision(requested_job_id);
  PERFORM otlet.append_administrative_change(
    'retention',
    'job:' || requested_job_id::text,
    CASE WHEN requested_retain_history THEN 'retain_history' ELSE 'delete_history' END,
    old_revision,
    new_revision
  );
  RETURN saved;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config(
    'otlet.evidence_lifecycle_write',
    COALESCE(previous_write, ''),
    true
  );
  RAISE;
END;
$$;

CREATE FUNCTION otlet.set_evidence_hold(
  requested_job_id bigint,
  expected_generation bigint,
  requested_held boolean,
  requested_reason text DEFAULT NULL,
  requested_ticket text DEFAULT NULL
) RETURNS otlet.evidence_lifecycle_records
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  lifecycle otlet.evidence_lifecycle_records%ROWTYPE;
  saved otlet.evidence_lifecycle_records%ROWTYPE;
  actor_oid oid;
  old_revision text;
  new_revision text;
  previous_write text := current_setting('otlet.evidence_lifecycle_write', true);
BEGIN
  IF requested_held IS NULL THEN
    RAISE EXCEPTION 'otlet evidence hold state is required';
  END IF;
  PERFORM otlet.set_administrative_change_context(
    requested_reason,
    requested_ticket
  );
  SELECT * INTO lifecycle
  FROM otlet.evidence_lifecycle_records record
  WHERE record.job_id = requested_job_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evidence lifecycle % does not exist', requested_job_id;
  END IF;
  IF lifecycle.lifecycle_state = 'deleted' THEN
    RAISE EXCEPTION 'otlet evidence lifecycle % is already deleted', requested_job_id;
  END IF;
  IF lifecycle.held IS NOT DISTINCT FROM requested_held THEN
    RETURN lifecycle;
  END IF;
  IF expected_generation IS NULL
     OR expected_generation <> lifecycle.generation THEN
    RAISE EXCEPTION 'otlet evidence lifecycle % generation changed', requested_job_id;
  END IF;

  SELECT role.oid INTO STRICT actor_oid
  FROM pg_catalog.pg_roles role
  WHERE role.rolname = current_user;
  old_revision := otlet.evidence_lifecycle_revision(requested_job_id);
  PERFORM set_config('otlet.evidence_lifecycle_write', 'on', true);
  UPDATE otlet.evidence_lifecycle_records record
  SET held = requested_held,
      held_by_oid = CASE WHEN requested_held THEN actor_oid END,
      held_by_name = CASE WHEN requested_held THEN current_user END,
      held_at = CASE WHEN requested_held THEN clock_timestamp() END,
      generation = generation + 1,
      updated_at = clock_timestamp()
  WHERE record.job_id = requested_job_id
  RETURNING * INTO saved;
  PERFORM set_config(
    'otlet.evidence_lifecycle_write',
    COALESCE(previous_write, ''),
    true
  );
  new_revision := otlet.evidence_lifecycle_revision(requested_job_id);
  PERFORM otlet.append_administrative_change(
    'retention',
    'job:' || requested_job_id::text,
    CASE WHEN requested_held THEN 'hold' ELSE 'release_hold' END,
    old_revision,
    new_revision
  );
  RETURN saved;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config(
    'otlet.evidence_lifecycle_write',
    COALESCE(previous_write, ''),
    true
  );
  RAISE;
END;
$$;

CREATE FUNCTION otlet.record_evidence_export(
  requested_job_id bigint,
  expected_generation bigint,
  expected_manifest_hash text,
  requested_export_reference_hash text,
  succeeded boolean,
  requested_reason text DEFAULT NULL,
  requested_ticket text DEFAULT NULL
) RETURNS otlet.evidence_lifecycle_records
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  lifecycle otlet.evidence_lifecycle_records%ROWTYPE;
  policy otlet.production_policy%ROWTYPE;
  archive record;
  saved otlet.evidence_lifecycle_records%ROWTYPE;
  actor_oid oid;
  old_revision text;
  new_revision text;
  next_state text;
  previous_write text := current_setting('otlet.evidence_lifecycle_write', true);
BEGIN
  IF succeeded IS NULL THEN
    RAISE EXCEPTION 'otlet evidence export result is required';
  END IF;
  IF expected_manifest_hash IS NULL
     OR expected_manifest_hash !~ '^otlet:v1:sha256:[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'otlet evidence export manifest is invalid';
  END IF;
  IF succeeded AND (
       requested_export_reference_hash IS NULL
       OR requested_export_reference_hash !~
         '^otlet:v1:sha256:[0-9a-f]{64}$'
     ) THEN
    RAISE EXCEPTION 'otlet evidence export reference is invalid';
  ELSIF NOT succeeded AND requested_export_reference_hash IS NOT NULL THEN
    RAISE EXCEPTION 'otlet failed evidence export cannot record a reference';
  END IF;
  IF succeeded AND NOT otlet.acquire_evidence_mutation_barrier() THEN
    RAISE EXCEPTION 'otlet evidence lifecycle mutation is active'
      USING ERRCODE = '55P03';
  END IF;
  PERFORM otlet.set_administrative_change_context(
    requested_reason,
    requested_ticket
  );
  SELECT * INTO lifecycle
  FROM otlet.evidence_lifecycle_records record
  WHERE record.job_id = requested_job_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evidence lifecycle % does not exist', requested_job_id;
  END IF;
  next_state := CASE WHEN succeeded THEN 'complete' ELSE 'failed' END;
  IF lifecycle.lifecycle_state <> 'archived' THEN
    RAISE EXCEPTION 'otlet evidence lifecycle % is not archived', requested_job_id;
  END IF;
  IF lifecycle.archive_manifest_hash IS DISTINCT FROM expected_manifest_hash THEN
    RAISE EXCEPTION 'otlet evidence lifecycle % manifest changed', requested_job_id;
  END IF;
  IF succeeded THEN
    SELECT * INTO STRICT policy
    FROM otlet.production_policy
    WHERE name = 'default';
    IF otlet.evidence_archive_row_count_bounded(
         requested_job_id,
         policy.evidence_max_chain_rows
       ) > policy.evidence_max_chain_rows THEN
      RAISE EXCEPTION 'otlet evidence lifecycle % exceeds the chain limit',
        requested_job_id;
    END IF;
    SELECT * INTO archive
    FROM otlet.evidence_archive_manifest(requested_job_id);
    IF archive.manifest_hash IS DISTINCT FROM expected_manifest_hash THEN
      RAISE EXCEPTION 'otlet evidence lifecycle % live manifest changed',
        requested_job_id;
    END IF;
  END IF;
  IF lifecycle.export_state = next_state
     AND lifecycle.export_reference_hash IS NOT DISTINCT FROM
       requested_export_reference_hash THEN
    RETURN lifecycle;
  END IF;
  IF expected_generation IS NULL
     OR expected_generation <> lifecycle.generation THEN
    RAISE EXCEPTION 'otlet evidence lifecycle % generation changed', requested_job_id;
  END IF;
  IF lifecycle.export_state = 'complete' THEN
    RAISE EXCEPTION 'otlet evidence lifecycle % export is already complete',
      requested_job_id;
  END IF;

  SELECT role.oid INTO STRICT actor_oid
  FROM pg_catalog.pg_roles role
  WHERE role.rolname = current_user;
  old_revision := otlet.evidence_lifecycle_revision(requested_job_id);
  PERFORM set_config('otlet.evidence_lifecycle_write', 'on', true);
  UPDATE otlet.evidence_lifecycle_records record
  SET export_state = next_state,
      export_reference_hash = CASE
        WHEN succeeded THEN requested_export_reference_hash
      END,
      exported_by_oid = CASE WHEN succeeded THEN actor_oid END,
      exported_by_name = CASE WHEN succeeded THEN current_user END,
      exported_at = CASE WHEN succeeded THEN clock_timestamp() END,
      generation = generation + 1,
      updated_at = clock_timestamp()
  WHERE record.job_id = requested_job_id
  RETURNING * INTO saved;
  PERFORM set_config(
    'otlet.evidence_lifecycle_write',
    COALESCE(previous_write, ''),
    true
  );
  new_revision := otlet.evidence_lifecycle_revision(requested_job_id);
  PERFORM otlet.append_administrative_change(
    'retention',
    'job:' || requested_job_id::text,
    CASE WHEN succeeded THEN 'complete_export' ELSE 'fail_export' END,
    old_revision,
    new_revision
  );
  RETURN saved;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config(
    'otlet.evidence_lifecycle_write',
    COALESCE(previous_write, ''),
    true
  );
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.reject_review_event_change() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE'
     AND current_setting('otlet.evidence_lifecycle_cleanup', true) = 'on' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'otlet review event history is immutable';
END;
$$;

CREATE OR REPLACE FUNCTION otlet.guard_review_sample_append() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT'
     AND current_setting('otlet.review_sample_append', true) = 'on' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE'
     AND current_setting('otlet.evidence_lifecycle_cleanup', true) = 'on' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'otlet review samples are append only';
END;
$$;

CREATE FUNCTION otlet.evidence_lifecycle_maintenance_pending() RETURNS boolean
LANGUAGE sql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  WITH policy AS (
    SELECT * FROM otlet.production_policy WHERE name = 'default'
  )
  SELECT EXISTS (
    SELECT 1
    FROM otlet.jobs job
    CROSS JOIN policy
    WHERE job.execution_mode = 'production'
      AND policy.evidence_lifecycle_enabled
      AND job.status IN ('complete', 'failed', 'canceled')
      AND NOT EXISTS (
        SELECT 1 FROM otlet.evidence_lifecycle_records record
        WHERE record.job_id = job.id
      )
      AND (
        (job.status = 'complete'
          AND policy.successful_job_retention IS NOT NULL
          AND COALESCE(job.finished_at, job.created_at) <
            statement_timestamp() - policy.successful_job_retention)
        OR
        (job.status IN ('failed', 'canceled')
          AND COALESCE(job.finished_at, job.created_at) <
            statement_timestamp() - policy.failed_job_retention)
      )
  ) OR EXISTS (
    SELECT 1
    FROM otlet.evidence_lifecycle_records record
    JOIN otlet.jobs job ON job.id = record.job_id
    CROSS JOIN policy
    CROSS JOIN LATERAL (
      SELECT otlet.evidence_archive_row_count_bounded(
        record.job_id,
        policy.evidence_max_chain_rows
      ) AS row_count
    ) bounded_archive
    CROSS JOIN LATERAL (
      SELECT CASE
        WHEN record.lifecycle_state = 'archived'
          AND bounded_archive.row_count <= policy.evidence_max_chain_rows
        THEN (
          SELECT manifest.manifest_hash
          FROM otlet.evidence_archive_manifest(record.job_id) manifest
        )
      END AS manifest_hash
    ) archive
    WHERE bounded_archive.row_count <= policy.evidence_max_chain_rows
      AND (
        record.lifecycle_state = 'requested'
        OR (record.lifecycle_state = 'archived'
          AND record.archive_manifest_hash IS DISTINCT FROM archive.manifest_hash)
        OR (record.lifecycle_state = 'archived'
          AND cardinality(otlet.evidence_delete_blockers(record.job_id)) = 0)
      )
  );
$$;

CREATE FUNCTION otlet.maintenance_evidence_lifecycle_step()
RETURNS TABLE (
  item_found boolean,
  item_kind text,
  affected_rows bigint,
  touched_relations text[]
)
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  policy otlet.production_policy%ROWTYPE;
  job otlet.jobs%ROWTYPE;
  lifecycle otlet.evidence_lifecycle_records%ROWTYPE;
  archive record;
  candidate_job_id bigint;
  adopted_job boolean := false;
  deleted_counts jsonb := '{}'::jsonb;
  deleted_row_count bigint;
  deletion_time timestamptz;
  action_tombstone_hashes jsonb;
  tombstone text;
  previous_write text := current_setting('otlet.evidence_lifecycle_write', true);
  previous_cleanup text := current_setting('otlet.evidence_lifecycle_cleanup', true);
  previous_label_cleanup text := current_setting('otlet.eval_label_cleanup', true);
BEGIN
  IF NOT otlet.evidence_lifecycle_maintenance_pending() THEN
    RETURN QUERY SELECT false, NULL::text, 0::bigint, ARRAY[]::text[];
    RETURN;
  END IF;
  IF NOT otlet.acquire_evidence_mutation_barrier() THEN
    RETURN QUERY SELECT false, NULL::text, 0::bigint, ARRAY[]::text[];
    RETURN;
  END IF;
  IF NOT otlet.evidence_lifecycle_maintenance_pending() THEN
    RETURN QUERY SELECT false, NULL::text, 0::bigint, ARRAY[]::text[];
    RETURN;
  END IF;
  SELECT * INTO STRICT policy
  FROM otlet.production_policy
  WHERE name = 'default';

  SELECT candidate.* INTO job
  FROM otlet.jobs candidate
  WHERE candidate.execution_mode = 'production'
    AND policy.evidence_lifecycle_enabled
    AND candidate.status IN ('complete', 'failed', 'canceled')
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.evidence_lifecycle_records existing
      WHERE existing.job_id = candidate.id
    )
    AND (
      (
        candidate.status = 'complete'
        AND policy.successful_job_retention IS NOT NULL
        AND COALESCE(candidate.finished_at, candidate.created_at) <
          statement_timestamp() - policy.successful_job_retention
      )
      OR (
        candidate.status IN ('failed', 'canceled')
        AND COALESCE(candidate.finished_at, candidate.created_at) <
          statement_timestamp() - policy.failed_job_retention
      )
    )
  ORDER BY COALESCE(candidate.finished_at, candidate.created_at), candidate.id
  LIMIT 1
  FOR UPDATE OF candidate SKIP LOCKED;
  IF FOUND THEN
    lifecycle := otlet.request_evidence_lifecycle(
      job.id,
      false,
      'automatic evidence retention',
      NULL
    );
    candidate_job_id := job.id;
    adopted_job := true;
  END IF;

  SELECT record.job_id INTO candidate_job_id
  FROM otlet.evidence_lifecycle_records record
  JOIN otlet.jobs live_job ON live_job.id = record.job_id
  CROSS JOIN LATERAL (
    SELECT otlet.evidence_archive_row_count_bounded(
      record.job_id,
      policy.evidence_max_chain_rows
    ) AS row_count
  ) bounded_archive
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN record.lifecycle_state = 'archived'
        AND bounded_archive.row_count <= policy.evidence_max_chain_rows
      THEN (
        SELECT manifest.manifest_hash
        FROM otlet.evidence_archive_manifest(record.job_id) manifest
      )
    END AS manifest_hash
  ) current_archive
  WHERE bounded_archive.row_count <= policy.evidence_max_chain_rows
    AND (candidate_job_id IS NULL OR record.job_id = candidate_job_id)
    AND (
      record.lifecycle_state = 'requested'
      OR (
        record.lifecycle_state = 'archived'
        AND record.archive_manifest_hash IS DISTINCT FROM
          current_archive.manifest_hash
      )
    )
  ORDER BY record.job_id
  LIMIT 1
  FOR UPDATE OF record, live_job SKIP LOCKED;
  IF FOUND THEN
    IF otlet.evidence_archive_row_count_bounded(
         candidate_job_id,
         policy.evidence_max_chain_rows
       ) > policy.evidence_max_chain_rows THEN
      RETURN QUERY SELECT false, NULL::text, 0::bigint, ARRAY[]::text[];
      RETURN;
    END IF;
    SELECT * INTO archive
    FROM otlet.evidence_archive_manifest(candidate_job_id);
    PERFORM set_config('otlet.evidence_lifecycle_write', 'on', true);
    UPDATE otlet.evidence_lifecycle_records record
    SET lifecycle_state = 'archived',
        generation = generation + 1,
        archive_manifest_hash = archive.manifest_hash,
        archive_row_count = archive.row_count,
        archive_row_counts = archive.row_counts,
        export_state = 'pending',
        export_reference_hash = NULL,
        exported_by_oid = NULL,
        exported_by_name = NULL,
        exported_at = NULL,
        updated_at = clock_timestamp()
    WHERE record.job_id = candidate_job_id;
    PERFORM set_config(
      'otlet.evidence_lifecycle_write',
      COALESCE(previous_write, ''),
      true
    );
    RETURN QUERY SELECT
      true,
      'evidence_archive'::text,
      CASE WHEN adopted_job THEN 2 ELSE 1 END::bigint,
      CASE WHEN adopted_job THEN ARRAY[
        'otlet.administrative_change_events',
        'otlet.evidence_lifecycle_records'
      ]::text[] ELSE ARRAY[
        'otlet.evidence_lifecycle_records'
      ]::text[] END;
    RETURN;
  END IF;

  IF adopted_job THEN
    RETURN QUERY SELECT
      true,
      'evidence_request'::text,
      2::bigint,
      ARRAY[
        'otlet.administrative_change_events',
        'otlet.evidence_lifecycle_records'
      ]::text[];
    RETURN;
  END IF;

  SELECT record.job_id INTO candidate_job_id
  FROM otlet.evidence_lifecycle_records record
  JOIN otlet.jobs live_job ON live_job.id = record.job_id
  WHERE record.lifecycle_state = 'archived'
    AND cardinality(otlet.evidence_delete_blockers(record.job_id)) = 0
  ORDER BY record.job_id
  LIMIT 1
  FOR UPDATE OF record, live_job SKIP LOCKED;
  IF FOUND THEN
    IF cardinality(otlet.evidence_delete_blockers(candidate_job_id)) <> 0 THEN
      RETURN QUERY SELECT false, NULL::text, 0::bigint, ARRAY[]::text[];
      RETURN;
    END IF;
    SELECT * INTO archive
    FROM otlet.evidence_archive_manifest(candidate_job_id);
    SELECT * INTO STRICT lifecycle
    FROM otlet.evidence_lifecycle_records record
    WHERE record.job_id = candidate_job_id;
    IF archive.manifest_hash IS DISTINCT FROM lifecycle.archive_manifest_hash THEN
      RAISE EXCEPTION 'otlet evidence lifecycle % manifest changed during deletion',
        candidate_job_id;
    END IF;

    deletion_time := clock_timestamp();
    PERFORM set_config('otlet.evidence_lifecycle_write', 'on', true);
    PERFORM set_config('otlet.evidence_lifecycle_cleanup', 'on', true);
    PERFORM set_config('otlet.eval_label_cleanup', 'on', true);

    INSERT INTO otlet.action_idempotency_tombstones (
      idempotency_key,
      source_job_id,
      source_job_identity_hash,
      before_hash,
      result_hash,
      replay_metadata_hash,
      tombstone_hash,
      created_at
    )
    SELECT
      execution.idempotency_key,
      candidate_job_id,
      lifecycle.job_identity_hash,
      execution.before_hash,
      execution.result_hash,
      otlet.identity_hash(
        'action_replay_metadata',
        jsonb_build_object(
          'target_name', execution.target_name,
          'target_table', execution.target_table,
          'identity_hash', execution.identity_hash,
          'changed_columns', to_jsonb(execution.changed_columns)
        )
      ),
      otlet.identity_hash(
        'action_idempotency_tombstone',
        jsonb_build_object(
          'format', 'otlet.action.idempotency-tombstone.v1',
          'idempotency_key', execution.idempotency_key,
          'source_job_identity_hash', lifecycle.job_identity_hash,
          'before_hash', execution.before_hash,
          'result_hash', execution.result_hash,
          'replay_metadata_hash', otlet.identity_hash(
            'action_replay_metadata',
            jsonb_build_object(
              'target_name', execution.target_name,
              'target_table', execution.target_table,
              'identity_hash', execution.identity_hash,
              'changed_columns', to_jsonb(execution.changed_columns)
            )
          )
        )
      ),
      deletion_time
    FROM otlet.action_execution_receipts execution
    JOIN otlet.actions action ON action.id = execution.action_id
    WHERE action.job_id = candidate_job_id
      AND execution.mode = 'apply'
      AND execution.status = 'applied'
    ON CONFLICT (idempotency_key) DO NOTHING;

    SELECT COALESCE(
      jsonb_agg(idempotency.tombstone_hash ORDER BY idempotency.tombstone_hash),
      '[]'::jsonb
    ) INTO action_tombstone_hashes
    FROM otlet.action_idempotency_tombstones idempotency
    WHERE idempotency.source_job_id = candidate_job_id;

    DELETE FROM otlet.review_samples sample
    WHERE sample.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('review_sample', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.eval_labels label
    WHERE label.id IN (
      SELECT member.label_id
      FROM otlet.evidence_job_label_ids(candidate_job_id) member
    );
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('eval_label', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.review_events review
    WHERE review.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('review_event', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.watch_time_freshness freshness
    USING otlet.semantic_materializations materialization,
      otlet.records record,
      otlet.actions action
    WHERE freshness.materialization_id = materialization.id
      AND materialization.record_id = record.id
      AND record.action_id = action.id
      AND action.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('watch_time_freshness', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.semantic_materializations materialization
    USING otlet.records record, otlet.actions action
    WHERE materialization.record_id = record.id
      AND record.action_id = action.id
      AND action.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('semantic_materialization', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.records record
    USING otlet.actions action
    WHERE record.action_id = action.id
      AND action.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('record', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.action_execution_receipts execution
    USING otlet.actions action
    WHERE execution.action_id = action.id
      AND action.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('action_execution_receipt', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.actions action
    WHERE action.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('action', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.outputs output
    WHERE output.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('output', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.portable_receipt_links link
    USING otlet.inference_receipts receipt
    WHERE link.receipt_id = receipt.id
      AND receipt.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('portable_receipt_link', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.portable_claims claim
    WHERE claim.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('portable_claim', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.worker_events event
    WHERE event.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('worker_event', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.inference_receipts receipt
    WHERE receipt.job_id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('receipt', deleted_row_count)
      ELSE '{}'::jsonb END;
    DELETE FROM otlet.jobs deleted_job
    WHERE deleted_job.id = candidate_job_id;
    GET DIAGNOSTICS deleted_row_count = ROW_COUNT;
    deleted_counts := deleted_counts || CASE WHEN deleted_row_count > 0
      THEN jsonb_build_object('job', deleted_row_count)
      ELSE '{}'::jsonb END;

    IF deleted_counts IS DISTINCT FROM archive.row_counts THEN
      RAISE EXCEPTION 'otlet evidence lifecycle % deletion counts changed',
        candidate_job_id;
    END IF;
    tombstone := otlet.identity_hash(
      'evidence_tombstone',
      jsonb_build_object(
        'format', 'otlet.evidence.tombstone.v1',
        'job_id', lifecycle.job_id,
        'job_identity_hash', lifecycle.job_identity_hash,
        'archive_manifest_hash', lifecycle.archive_manifest_hash,
        'export_reference_hash', lifecycle.export_reference_hash,
        'action_idempotency_tombstone_hashes', action_tombstone_hashes,
        'deleted_row_counts', deleted_counts,
        'deleted_at', extract(epoch FROM deletion_time)
      )
    );

    UPDATE otlet.evidence_lifecycle_records record
    SET lifecycle_state = 'deleted',
        generation = generation + 1,
        deleted_row_counts = deleted_counts,
        tombstone_hash = tombstone,
        deleted_at = deletion_time,
        updated_at = deletion_time
    WHERE record.job_id = candidate_job_id;
    PERFORM set_config(
      'otlet.eval_label_cleanup',
      COALESCE(previous_label_cleanup, ''),
      true
    );
    PERFORM set_config(
      'otlet.evidence_lifecycle_cleanup',
      COALESCE(previous_cleanup, ''),
      true
    );
    PERFORM set_config(
      'otlet.evidence_lifecycle_write',
      COALESCE(previous_write, ''),
      true
    );
    RETURN QUERY SELECT
      true,
      'evidence_delete'::text,
      archive.row_count::bigint,
      ARRAY[
        'otlet.action_execution_receipts',
        'otlet.action_idempotency_tombstones',
        'otlet.actions',
        'otlet.eval_labels',
        'otlet.evidence_lifecycle_records',
        'otlet.inference_receipts',
        'otlet.jobs',
        'otlet.outputs',
        'otlet.portable_claims',
        'otlet.portable_receipt_links',
        'otlet.records',
        'otlet.review_events',
        'otlet.review_samples',
        'otlet.semantic_materializations',
        'otlet.semantic_planner_statistics',
        'otlet.watch_time_freshness',
        'otlet.worker_events'
      ]::text[];
    RETURN;
  END IF;

  RETURN QUERY SELECT false, NULL::text, 0::bigint, ARRAY[]::text[];
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config(
    'otlet.eval_label_cleanup',
    COALESCE(previous_label_cleanup, ''),
    true
  );
  PERFORM set_config(
    'otlet.evidence_lifecycle_cleanup',
    COALESCE(previous_cleanup, ''),
    true
  );
  PERFORM set_config(
    'otlet.evidence_lifecycle_write',
    COALESCE(previous_write, ''),
    true
  );
  RAISE;
END;
$$;

DO $migration$
DECLARE
  definition text;
  old_header text :=
    'CREATE OR REPLACE FUNCTION otlet.maintenance_cleanup_step()';
  new_header text :=
    'CREATE OR REPLACE FUNCTION otlet.maintenance_cleanup_step_before_evidence()';
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.maintenance_cleanup_step()'::regprocedure
  );
  IF pg_catalog.strpos(definition, old_header) <> 1 THEN
    RAISE EXCEPTION 'otlet cleanup step clone is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_header, new_header);
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.maintenance_cleanup_step_before_evidence()'::regprocedure
  );
  old_fragment := $old$  WHERE job.status IN ('failed', 'canceled')$old$;
  new_fragment := $new$  WHERE NOT policy.evidence_lifecycle_enabled
    AND NOT otlet.evidence_lifecycle_manages_job(job.id)
    AND job.status IN ('failed', 'canceled')$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet legacy job cleanup rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.maintenance_cleanup_step_before_evidence()'::regprocedure
  );

  old_fragment := $old$  WHERE event.created_at < clock_timestamp() - policy.worker_event_retention$old$;
  new_fragment := $new$  WHERE NOT otlet.evidence_lifecycle_manages_job(event.job_id)
    AND event.created_at < clock_timestamp() - policy.worker_event_retention$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence worker-event cleanup fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  WHERE receipt.finished_at < clock_timestamp() - policy.trace_detail_retention$old$;
  new_fragment := $new$  WHERE NOT otlet.evidence_lifecycle_manages_job(receipt.job_id)
    AND receipt.finished_at < clock_timestamp() - policy.trace_detail_retention$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence trace cleanup fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  WHERE COALESCE(label.adjudicated_at, label.created_at) <$old$;
  new_fragment := $new$  WHERE NOT otlet.evidence_lifecycle_manages_label_series(
      label.task_name,
      label.source_table,
      label.subject_id
    )
    AND COALESCE(label.adjudicated_at, label.created_at) <$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence label cleanup fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      WHERE label.task_name = label_task_name$old$;
  new_fragment := $new$      WHERE NOT otlet.evidence_lifecycle_manages_label_series(
          label_task_name,
          label_source_table,
          label_subject_id
        )
        AND label.task_name = label_task_name$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence label cleanup recheck fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  WHERE materialization.stale
    AND materialization.stale_reason = 'source_delete'$old$;
  new_fragment := $new$  WHERE NOT otlet.evidence_lifecycle_manages_materialization(
      materialization.id
    )
    AND materialization.stale
    AND materialization.stale_reason = 'source_delete'$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence materialization cleanup fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  WHERE (
      policy.sensitive_evidence_mode = 'redacted'$old$;
  new_fragment := $new$  WHERE NOT otlet.evidence_lifecycle_manages_job(receipt.job_id)
    AND (
      policy.sensitive_evidence_mode = 'redacted'$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet sensitive evidence cleanup fence is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
END;
$migration$;

CREATE OR REPLACE FUNCTION otlet.maintenance_cleanup_step()
RETURNS TABLE (
  item_found boolean,
  item_kind text,
  affected_rows bigint,
  touched_relations text[]
)
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  step record;
BEGIN
  SELECT * INTO step FROM otlet.maintenance_evidence_lifecycle_step();
  IF COALESCE(step.item_found, false) THEN
    RETURN QUERY SELECT
      step.item_found,
      step.item_kind,
      step.affected_rows,
      step.touched_relations;
    RETURN;
  END IF;
  RETURN QUERY
  SELECT * FROM otlet.maintenance_cleanup_step_before_evidence();
END;
$$;

DO $migration$
DECLARE
  definition text;
  old_header text :=
    'CREATE OR REPLACE FUNCTION otlet.maintenance_cleanup_pending()';
  new_header text :=
    'CREATE OR REPLACE FUNCTION otlet.maintenance_cleanup_pending_before_evidence()';
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.maintenance_cleanup_pending()'::regprocedure
  );
  IF pg_catalog.strpos(definition, old_header) <> 1 THEN
    RAISE EXCEPTION 'otlet cleanup pending clone is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_header, new_header);
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.maintenance_cleanup_pending_before_evidence()'::regprocedure
  );
  old_fragment := $old$      WHERE job.status IN ('failed', 'canceled')$old$;
  new_fragment := $new$      WHERE NOT policy.evidence_lifecycle_enabled
        AND NOT otlet.evidence_lifecycle_manages_job(job.id)
        AND job.status IN ('failed', 'canceled')$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet legacy job cleanup pending rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.maintenance_cleanup_pending_before_evidence()'::regprocedure
  );

  old_fragment := $old$      WHERE event.created_at < clock_timestamp() - policy.worker_event_retention$old$;
  new_fragment := $new$      WHERE NOT otlet.evidence_lifecycle_manages_job(event.job_id)
        AND event.created_at < clock_timestamp() - policy.worker_event_retention$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence worker-event pending fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      WHERE receipt.finished_at <
          clock_timestamp() - policy.trace_detail_retention$old$;
  new_fragment := $new$      WHERE NOT otlet.evidence_lifecycle_manages_job(receipt.job_id)
        AND receipt.finished_at <
          clock_timestamp() - policy.trace_detail_retention$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence trace pending fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      WHERE COALESCE(label.adjudicated_at, label.created_at) <$old$;
  new_fragment := $new$      WHERE NOT otlet.evidence_lifecycle_manages_label_series(
          label.task_name,
          label.source_table,
          label.subject_id
        )
        AND COALESCE(label.adjudicated_at, label.created_at) <$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence label pending fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      WHERE materialization.stale
        AND materialization.stale_reason = 'source_delete'$old$;
  new_fragment := $new$      WHERE NOT otlet.evidence_lifecycle_manages_materialization(
          materialization.id
        )
        AND materialization.stale
        AND materialization.stale_reason = 'source_delete'$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evidence materialization pending fence is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      WHERE (
          policy.sensitive_evidence_mode = 'redacted'$old$;
  new_fragment := $new$      WHERE NOT otlet.evidence_lifecycle_manages_job(receipt.job_id)
        AND (
          policy.sensitive_evidence_mode = 'redacted'$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet sensitive evidence pending fence is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
END;
$migration$;

CREATE OR REPLACE FUNCTION otlet.maintenance_cleanup_pending() RETURNS boolean
LANGUAGE sql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT otlet.evidence_lifecycle_maintenance_pending()
    OR otlet.maintenance_cleanup_pending_before_evidence();
$$;

CREATE VIEW otlet.evidence_lifecycle_status AS
WITH status AS (
  SELECT
    record.*,
    job.id IS NOT NULL AS live_job_present,
    job.status AS live_job_status,
    bounded_archive.row_count AS current_row_count,
    archive.manifest_hash AS current_manifest_hash,
    CASE
      WHEN record.terminal_status = 'complete'
        AND policy.successful_job_retention IS NOT NULL
        THEN record.terminal_at + policy.successful_job_retention
      WHEN record.terminal_status IN ('failed', 'canceled')
        THEN record.terminal_at + policy.failed_job_retention
    END AS retention_deadline,
    CASE
      WHEN record.lifecycle_state = 'deleted' THEN ARRAY[]::text[]
      ELSE otlet.evidence_delete_blockers(record.job_id)
    END AS blocker_codes
  FROM otlet.evidence_lifecycle_records record
  CROSS JOIN otlet.production_policy policy
  LEFT JOIN otlet.jobs job ON job.id = record.job_id
  LEFT JOIN LATERAL (
    SELECT otlet.evidence_archive_row_count_bounded(
      record.job_id,
      policy.evidence_max_chain_rows
    ) AS row_count
  ) bounded_archive
    ON job.id IS NOT NULL
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN job.id IS NOT NULL
        AND bounded_archive.row_count <= policy.evidence_max_chain_rows
      THEN (
        SELECT manifest.manifest_hash
        FROM otlet.evidence_archive_manifest(record.job_id) manifest
      )
    END AS manifest_hash
  ) archive
  WHERE policy.name = 'default'
)
SELECT
  'otlet.evidence_lifecycle.status.v1'::text AS status_format,
  job_id,
  task_name,
  workload_revision_hash,
  terminal_status,
  terminal_at,
  subject_identity_hash,
  job_identity_hash,
  lifecycle_state,
  generation,
  retain_history,
  held,
  held_by_name,
  held_at,
  retention_deadline,
  archive_manifest_hash,
  archive_row_count,
  archive_row_counts,
  current_manifest_hash,
  current_row_count,
  archive_manifest_hash IS NOT DISTINCT FROM current_manifest_hash
    AND lifecycle_state <> 'requested' AS manifest_current,
  export_state,
  export_reference_hash,
  exported_by_name,
  exported_at,
  blocker_codes,
  lifecycle_state = 'archived'
    AND cardinality(blocker_codes) = 0 AS delete_eligible,
  deleted_row_counts,
  tombstone_hash,
  requested_by_name,
  requested_at,
  updated_at,
  deleted_at,
  live_job_present,
  live_job_status
FROM status;

DO $migration$
DECLARE
  definition text;
  old_header text;
  new_header text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.verify_invariants(integer)'::regprocedure
  );
  old_header := split_part(definition, E'\n', 1);
  new_header := pg_catalog.replace(
    old_header,
    'otlet.verify_invariants(',
    'otlet.verify_invariants_before_evidence_lifecycle('
  );
  IF new_header = old_header THEN
    RAISE EXCEPTION 'otlet evidence invariant clone is incomplete';
  END IF;
  definition := new_header
    || substring(definition FROM length(old_header) + 1);
  IF position('verify_invariants.sample_limit' IN definition) > 0 THEN
    definition := pg_catalog.replace(
      definition,
      'verify_invariants.sample_limit',
      'verify_invariants_before_evidence_lifecycle.sample_limit'
    );
  END IF;
  EXECUTE definition;
END;
$migration$;

CREATE OR REPLACE FUNCTION otlet.verify_invariants(
  sample_limit integer DEFAULT NULL
)
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
  FROM otlet.verify_invariants_before_evidence_lifecycle(
    verify_invariants.sample_limit
  ) invariant;

  RETURN QUERY
  SELECT
    'evidence_lifecycle_live_snapshot_matches'::text,
    'evidence_lifecycle'::text,
    record.job_id::text,
    jsonb_build_object(
      'lifecycle_state', record.lifecycle_state,
      'recorded_task_name', record.task_name,
      'live_task_name', job.task_name,
      'recorded_terminal_status', record.terminal_status,
      'live_status', job.status,
      'recorded_subject_identity_hash', record.subject_identity_hash,
      'live_subject_identity_hash', CASE WHEN job.id IS NOT NULL THEN
        otlet.identity_hash(
          'evidence_subject',
          jsonb_build_object(
            'task_name', job.task_name,
            'subject_id', job.subject_id
          )
        )
      END,
      'recorded_job_identity_hash', record.job_identity_hash,
      'live_job_identity_hash', CASE WHEN job.id IS NOT NULL THEN
        otlet.identity_hash(
          'evidence_job',
          jsonb_build_object(
            'job_id', job.id,
            'task_name', job.task_name,
            'workload_revision_hash', job.workload_revision_hash,
            'subject_id', job.subject_id,
            'terminal_status', job.status,
            'terminal_at', extract(
              epoch FROM COALESCE(job.finished_at, job.created_at)
            )
          )
        )
      END
    )
  FROM otlet.evidence_lifecycle_records record
  LEFT JOIN otlet.jobs job ON job.id = record.job_id
  WHERE record.lifecycle_state <> 'deleted'
    AND (
      job.id IS NULL
      OR job.execution_mode IS DISTINCT FROM 'production'
      OR job.task_name IS DISTINCT FROM record.task_name
      OR job.workload_revision_hash IS DISTINCT FROM
        record.workload_revision_hash
      OR job.status IS DISTINCT FROM record.terminal_status
      OR COALESCE(job.finished_at, job.created_at) IS DISTINCT FROM
        record.terminal_at
      OR record.subject_identity_hash IS DISTINCT FROM otlet.identity_hash(
        'evidence_subject',
        jsonb_build_object(
          'task_name', job.task_name,
          'subject_id', job.subject_id
        )
      )
      OR record.job_identity_hash IS DISTINCT FROM otlet.identity_hash(
        'evidence_job',
        jsonb_build_object(
          'job_id', job.id,
          'task_name', job.task_name,
          'workload_revision_hash', job.workload_revision_hash,
          'subject_id', job.subject_id,
          'terminal_status', job.status,
          'terminal_at', extract(
            epoch FROM COALESCE(job.finished_at, job.created_at)
          )
        )
      )
    )
  ORDER BY record.job_id
  LIMIT verify_invariants.sample_limit;

  RETURN QUERY
  SELECT
    'evidence_tombstone_has_no_live_chain'::text,
    'evidence_tombstone'::text,
    record.job_id::text,
    jsonb_build_object(
      'live_job', EXISTS (
        SELECT 1 FROM otlet.jobs job WHERE job.id = record.job_id
      ),
      'live_review_events', (
        SELECT count(*) FROM otlet.review_events review
        WHERE review.job_id = record.job_id
      )
    )
  FROM otlet.evidence_lifecycle_records record
  WHERE record.lifecycle_state = 'deleted'
    AND (
      EXISTS (SELECT 1 FROM otlet.jobs job WHERE job.id = record.job_id)
      OR EXISTS (
        SELECT 1 FROM otlet.review_events review
        WHERE review.job_id = record.job_id
      )
    )
  ORDER BY record.job_id
  LIMIT verify_invariants.sample_limit;

  RETURN QUERY
  SELECT
    'evidence_tombstone_counts_are_bounded'::text,
    'evidence_tombstone'::text,
    record.job_id::text,
    jsonb_build_object(
      'archive_row_count', record.archive_row_count,
      'archive_row_counts', record.archive_row_counts,
      'deleted_row_counts', record.deleted_row_counts
    )
  FROM otlet.evidence_lifecycle_records record
  WHERE record.lifecycle_state = 'deleted'
    AND (
      record.archive_row_counts IS DISTINCT FROM record.deleted_row_counts
      OR record.archive_row_count IS DISTINCT FROM (
        SELECT sum(CASE
          WHEN jsonb_typeof(count_entry.value) = 'number'
            AND count_entry.value::text ~ '^[1-9][0-9]*$'
            THEN count_entry.value::text::integer
        END)::integer
        FROM jsonb_each(record.archive_row_counts) count_entry
      )
      OR EXISTS (
        SELECT 1
        FROM jsonb_each(record.archive_row_counts) count_entry
        WHERE jsonb_typeof(count_entry.value) <> 'number'
          OR count_entry.value::text !~ '^[1-9][0-9]*$'
      )
      OR EXISTS (
        SELECT 1
        FROM jsonb_each(record.deleted_row_counts) count_entry
        WHERE jsonb_typeof(count_entry.value) <> 'number'
          OR count_entry.value::text !~ '^[1-9][0-9]*$'
      )
    )
  ORDER BY record.job_id
  LIMIT verify_invariants.sample_limit;

  RETURN QUERY
  SELECT
    'evidence_tombstone_hash_matches'::text,
    'evidence_tombstone'::text,
    record.job_id::text,
    jsonb_build_object(
      'recorded_tombstone_hash', record.tombstone_hash,
      'expected_tombstone_hash', otlet.identity_hash(
        'evidence_tombstone',
        jsonb_build_object(
          'format', 'otlet.evidence.tombstone.v1',
          'job_id', record.job_id,
          'job_identity_hash', record.job_identity_hash,
          'archive_manifest_hash', record.archive_manifest_hash,
          'export_reference_hash', record.export_reference_hash,
          'action_idempotency_tombstone_hashes', (
            SELECT COALESCE(
              jsonb_agg(
                idempotency.tombstone_hash
                ORDER BY idempotency.tombstone_hash
              ),
              '[]'::jsonb
            )
            FROM otlet.action_idempotency_tombstones idempotency
            WHERE idempotency.source_job_id = record.job_id
          ),
          'deleted_row_counts', record.deleted_row_counts,
          'deleted_at', extract(epoch FROM record.deleted_at)
        )
      )
    )
  FROM otlet.evidence_lifecycle_records record
  WHERE record.lifecycle_state = 'deleted'
    AND record.tombstone_hash IS DISTINCT FROM otlet.identity_hash(
      'evidence_tombstone',
      jsonb_build_object(
        'format', 'otlet.evidence.tombstone.v1',
        'job_id', record.job_id,
        'job_identity_hash', record.job_identity_hash,
        'archive_manifest_hash', record.archive_manifest_hash,
        'export_reference_hash', record.export_reference_hash,
        'action_idempotency_tombstone_hashes', (
          SELECT COALESCE(
            jsonb_agg(
              idempotency.tombstone_hash
              ORDER BY idempotency.tombstone_hash
            ),
            '[]'::jsonb
          )
          FROM otlet.action_idempotency_tombstones idempotency
          WHERE idempotency.source_job_id = record.job_id
        ),
        'deleted_row_counts', record.deleted_row_counts,
        'deleted_at', extract(epoch FROM record.deleted_at)
      )
    )
  ORDER BY record.job_id
  LIMIT verify_invariants.sample_limit;

  RETURN QUERY
  SELECT
    'action_idempotency_tombstone_hash_matches'::text,
    'action_idempotency_tombstone'::text,
    idempotency.idempotency_key,
    jsonb_build_object(
      'recorded_tombstone_hash', idempotency.tombstone_hash,
      'expected_tombstone_hash', otlet.identity_hash(
        'action_idempotency_tombstone',
        jsonb_build_object(
          'format', 'otlet.action.idempotency-tombstone.v1',
          'idempotency_key', idempotency.idempotency_key,
          'source_job_identity_hash', idempotency.source_job_identity_hash,
          'before_hash', idempotency.before_hash,
          'result_hash', idempotency.result_hash,
          'replay_metadata_hash', idempotency.replay_metadata_hash
        )
      )
    )
  FROM otlet.action_idempotency_tombstones idempotency
  LEFT JOIN otlet.evidence_lifecycle_records record
    ON record.job_id = idempotency.source_job_id
  WHERE record.job_id IS NULL
     OR record.lifecycle_state <> 'deleted'
     OR record.job_identity_hash IS DISTINCT FROM
       idempotency.source_job_identity_hash
     OR idempotency.tombstone_hash IS DISTINCT FROM otlet.identity_hash(
       'action_idempotency_tombstone',
       jsonb_build_object(
         'format', 'otlet.action.idempotency-tombstone.v1',
         'idempotency_key', idempotency.idempotency_key,
         'source_job_identity_hash', idempotency.source_job_identity_hash,
         'before_hash', idempotency.before_hash,
         'result_hash', idempotency.result_hash,
         'replay_metadata_hash', idempotency.replay_metadata_hash
       )
     )
  ORDER BY idempotency.idempotency_key
  LIMIT verify_invariants.sample_limit;

  RETURN QUERY
  SELECT
    'action_tombstone_replay_matches'::text,
    'action_execution_receipt'::text,
    receipt.id::text,
    jsonb_build_object(
      'receipt_idempotency_key', receipt.idempotency_key,
      'tombstone_idempotency_key', idempotency.idempotency_key,
      'receipt_before_hash', receipt.before_hash,
      'tombstone_before_hash', idempotency.before_hash,
      'receipt_result_hash', receipt.result_hash,
      'tombstone_result_hash', idempotency.result_hash,
      'recorded_replay_metadata_hash', idempotency.replay_metadata_hash,
      'receipt_replay_metadata_hash', otlet.identity_hash(
        'action_replay_metadata',
        jsonb_build_object(
          'target_name', receipt.target_name,
          'target_table', receipt.target_table,
          'identity_hash', receipt.identity_hash,
          'changed_columns', to_jsonb(receipt.changed_columns)
        )
      )
    )
  FROM otlet.action_execution_receipts receipt
  JOIN otlet.action_idempotency_tombstones idempotency
    ON idempotency.tombstone_hash = receipt.replay_of_tombstone_hash
  WHERE receipt.replay_of_tombstone_hash IS NOT NULL
    AND (
      receipt.idempotency_key IS DISTINCT FROM idempotency.idempotency_key
      OR receipt.before_hash IS DISTINCT FROM idempotency.before_hash
      OR receipt.result_hash IS DISTINCT FROM idempotency.result_hash
      OR idempotency.replay_metadata_hash IS DISTINCT FROM otlet.identity_hash(
        'action_replay_metadata',
        jsonb_build_object(
          'target_name', receipt.target_name,
          'target_table', receipt.target_table,
          'identity_hash', receipt.identity_hash,
          'changed_columns', to_jsonb(receipt.changed_columns)
        )
      )
    )
  ORDER BY receipt.id
  LIMIT verify_invariants.sample_limit;
END;
$$;

COMMENT ON TABLE otlet.evidence_lifecycle_records IS
'Guarded archive, hold, export, retention, and tombstone state for one terminal job';
COMMENT ON TABLE otlet.action_idempotency_tombstones IS
'Hash-only replay barriers retained after applied action evidence is deleted';
COMMENT ON COLUMN otlet.action_execution_receipts.replay_of_tombstone_hash IS
'Hash-only source for a replay after the original applied receipt was deleted';
COMMENT ON VIEW otlet.evidence_lifecycle_status IS
'Hash-only evidence lifecycle, conflict, export, hold, and tombstone status';
COMMENT ON FUNCTION otlet.evidence_archive_rows(bigint) IS
'Owner-only exact evidence rows used to create an external archive';
COMMENT ON FUNCTION otlet.evidence_lifecycle_maintenance_pending() IS
'Whether one evidence lifecycle item can make progress at statement start';
COMMENT ON FUNCTION otlet.maintenance_evidence_lifecycle_step() IS
'One bounded archive refresh or atomic terminal evidence-chain deletion';

REVOKE ALL ON TABLE otlet.evidence_lifecycle_records FROM PUBLIC;
REVOKE ALL ON TABLE otlet.action_idempotency_tombstones FROM PUBLIC;
REVOKE ALL ON TABLE otlet.evidence_lifecycle_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_evidence_lifecycle_record()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_evidence_lifecycle_job_delete()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evidence_job_label_ids(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evidence_lifecycle_manages_job(bigint)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evidence_lifecycle_manages_label_series(
  text,
  text,
  text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evidence_lifecycle_manages_materialization(
  bigint
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evidence_archive_row_count_bounded(
  bigint,
  integer
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.acquire_evidence_mutation_barrier()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_evidence_mutation_barrier()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_evidence_review_event_insert()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evidence_archive_rows(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evidence_archive_manifest(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evidence_delete_blockers(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evidence_lifecycle_revision(bigint)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.request_evidence_lifecycle(
  bigint,
  boolean,
  text,
  text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.set_evidence_history_retention(
  bigint,
  bigint,
  boolean,
  text,
  text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.set_evidence_hold(
  bigint,
  bigint,
  boolean,
  text,
  text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_evidence_export(
  bigint,
  bigint,
  text,
  text,
  boolean,
  text,
  text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reject_review_event_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_review_sample_append() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evidence_lifecycle_maintenance_pending()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.maintenance_evidence_lifecycle_step()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.maintenance_cleanup_step_before_evidence()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.maintenance_cleanup_step() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.maintenance_cleanup_pending_before_evidence()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.maintenance_cleanup_pending() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_invariants_before_evidence_lifecycle(
  integer
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_invariants(integer) FROM PUBLIC;
