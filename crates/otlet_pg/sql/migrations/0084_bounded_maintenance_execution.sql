ALTER TABLE otlet.production_policy
ADD COLUMN maintenance_max_rows integer NOT NULL DEFAULT 64,
ADD COLUMN maintenance_max_wal_bytes bigint NOT NULL DEFAULT 16777216,
ADD COLUMN maintenance_max_time_ms integer NOT NULL DEFAULT 1000,
ADD CONSTRAINT production_policy_maintenance_rows_bound CHECK (
  maintenance_max_rows BETWEEN 1 AND 100000
),
ADD CONSTRAINT production_policy_maintenance_wal_bound CHECK (
  maintenance_max_wal_bytes BETWEEN 1 AND 1073741824
),
ADD CONSTRAINT production_policy_maintenance_time_bound CHECK (
  maintenance_max_time_ms BETWEEN 1 AND 300000
);

COMMENT ON COLUMN otlet.production_policy.maintenance_max_rows IS
'Maximum primary maintenance items in one caller-driven slice';
COMMENT ON COLUMN otlet.production_policy.maintenance_max_wal_bytes IS
'Maximum cluster WAL insert bytes observed during one maintenance slice';
COMMENT ON COLUMN otlet.production_policy.maintenance_max_time_ms IS
'Maximum elapsed milliseconds observed between maintenance items';

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
  old_fragment := $old$    customscan_preload_max_ms
   FROM otlet.production_policy p$old$;
  new_fragment := $new$    customscan_preload_max_ms,
    maintenance_max_rows,
    maintenance_max_wal_bytes,
    maintenance_max_time_ms
   FROM otlet.production_policy p$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet maintenance policy status rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.production_policy_status AS '
    || pg_catalog.replace(definition, old_fragment, new_fragment);
END;
$migration$;

CREATE TABLE otlet.maintenance_runs (
  id bigserial PRIMARY KEY,
  kind text NOT NULL CHECK (
    kind IN ('cleanup', 'archive', 'reconciliation', 'repair')
  ),
  target_name text,
  target_revision_hash text CHECK (
    target_revision_hash IS NULL
    OR target_revision_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  control_state text NOT NULL DEFAULT 'running' CHECK (
    control_state IN ('running', 'paused', 'retryable', 'complete', 'canceled')
  ),
  generation bigint NOT NULL DEFAULT 0 CHECK (generation >= 0),
  row_budget integer NOT NULL CHECK (row_budget BETWEEN 1 AND 100000),
  wal_budget_bytes bigint NOT NULL CHECK (
    wal_budget_bytes BETWEEN 1 AND 1073741824
  ),
  time_budget_ms integer NOT NULL CHECK (time_budget_ms BETWEEN 1 AND 300000),
  processed_items bigint NOT NULL DEFAULT 0 CHECK (processed_items >= 0),
  changed_rows bigint NOT NULL DEFAULT 0 CHECK (changed_rows >= 0),
  observed_wal_bytes bigint NOT NULL DEFAULT 0 CHECK (observed_wal_bytes >= 0),
  observed_elapsed_ms bigint NOT NULL DEFAULT 0 CHECK (observed_elapsed_ms >= 0),
  slice_count bigint NOT NULL DEFAULT 0 CHECK (slice_count >= 0),
  retry_count bigint NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  last_slice_items integer NOT NULL DEFAULT 0 CHECK (last_slice_items >= 0),
  last_slice_changed_rows bigint NOT NULL DEFAULT 0 CHECK (
    last_slice_changed_rows >= 0
  ),
  last_slice_wal_bytes bigint NOT NULL DEFAULT 0 CHECK (
    last_slice_wal_bytes >= 0
  ),
  last_slice_elapsed_ms bigint NOT NULL DEFAULT 0 CHECK (
    last_slice_elapsed_ms >= 0
  ),
  last_item_kind text,
  last_stop_reason text NOT NULL DEFAULT 'created' CHECK (
    last_stop_reason IN (
      'created',
      'row_budget',
      'wal_budget',
      'time_budget',
      'waiting',
      'complete',
      'failed',
      'paused',
      'canceled'
    )
  ),
  last_error text CHECK (
    last_error IS NULL OR octet_length(last_error) BETWEEN 1 AND 4096
  ),
  state_reason text CHECK (
    state_reason IS NULL OR octet_length(state_reason) BETWEEN 1 AND 4096
  ),
  vacuum_relations text[] NOT NULL DEFAULT ARRAY[]::text[],
  vacuum_acknowledged_at timestamptz,
  vacuum_acknowledged_by name,
  vacuum_acknowledgement_reason text CHECK (
    vacuum_acknowledgement_reason IS NULL
    OR octet_length(vacuum_acknowledgement_reason) BETWEEN 1 AND 4096
  ),
  created_by name NOT NULL DEFAULT session_user,
  created_active_role name NOT NULL DEFAULT current_user,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  CHECK (
    (kind = 'cleanup' AND target_name IS NULL AND target_revision_hash IS NULL)
    OR (
      kind = 'reconciliation'
      AND target_name IS NULL
      AND target_revision_hash IS NULL
    )
    OR (
      kind IN ('archive', 'repair')
      AND NULLIF(target_name, '') IS NOT NULL
      AND target_revision_hash IS NOT NULL
    )
  ),
  CHECK ((control_state = 'complete') = (completed_at IS NOT NULL)),
  CHECK (
    (vacuum_acknowledged_at IS NULL) = (vacuum_acknowledged_by IS NULL)
  )
);

CREATE UNIQUE INDEX maintenance_runs_unfinished_target_idx
ON otlet.maintenance_runs (
  kind,
  COALESCE(target_name, ''),
  COALESCE(target_revision_hash, '')
)
WHERE control_state IN ('running', 'paused', 'retryable');

CREATE FUNCTION otlet.maintenance_observed_wal_bytes() RETURNS bigint
LANGUAGE sql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT pg_catalog.pg_wal_lsn_diff(
    pg_catalog.pg_current_wal_insert_lsn(),
    '0/0'::pg_lsn
  )::bigint;
$$;

CREATE FUNCTION otlet.merge_maintenance_relations(
  existing_relations text[],
  added_relations text[]
) RETURNS text[]
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT COALESCE(
    pg_catalog.array_agg(DISTINCT relation_name ORDER BY relation_name),
    ARRAY[]::text[]
  )
  FROM pg_catalog.unnest(
    COALESCE(existing_relations, ARRAY[]::text[])
      || COALESCE(added_relations, ARRAY[]::text[])
  ) relation(relation_name);
$$;

CREATE VIEW otlet.maintenance_run_status AS
SELECT
  run.id AS maintenance_run_id,
  run.kind,
  run.target_name,
  run.target_revision_hash,
  run.control_state,
  run.generation,
  run.row_budget,
  run.wal_budget_bytes,
  run.time_budget_ms,
  run.processed_items,
  run.changed_rows,
  run.observed_wal_bytes,
  run.observed_elapsed_ms,
  run.slice_count,
  run.retry_count,
  run.last_slice_items,
  run.last_slice_changed_rows,
  run.last_slice_wal_bytes,
  run.last_slice_elapsed_ms,
  run.last_item_kind,
  run.last_stop_reason,
  run.last_error,
  run.state_reason,
  run.vacuum_relations,
  cardinality(run.vacuum_relations) > 0
    AND run.vacuum_acknowledged_at IS NULL AS vacuum_handoff_required,
  ARRAY(
    SELECT format('VACUUM (ANALYZE) %s', relation_name)
    FROM unnest(run.vacuum_relations) relation(relation_name)
    ORDER BY relation_name
  ) AS vacuum_handoff_sql,
  run.vacuum_acknowledged_at,
  run.vacuum_acknowledged_by,
  run.vacuum_acknowledgement_reason,
  run.created_by,
  run.created_active_role,
  run.created_at,
  run.updated_at,
  run.completed_at
FROM otlet.maintenance_runs run;

CREATE FUNCTION otlet.create_maintenance_run(
  requested_kind text,
  requested_target_name text DEFAULT NULL,
  requested_target_revision_hash text DEFAULT NULL,
  requested_row_budget integer DEFAULT NULL,
  requested_wal_budget_bytes bigint DEFAULT NULL,
  requested_time_budget_ms integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  policy otlet.production_policy%ROWTYPE;
  row_budget integer;
  wal_budget bigint;
  time_budget integer;
  created_id bigint;
BEGIN
  SELECT * INTO STRICT policy
  FROM otlet.production_policy
  WHERE name = 'default';

  IF requested_kind NOT IN ('cleanup', 'archive', 'reconciliation', 'repair') THEN
    RAISE EXCEPTION 'otlet maintenance kind % is invalid', requested_kind;
  END IF;
  row_budget := COALESCE(requested_row_budget, policy.maintenance_max_rows);
  wal_budget := COALESCE(
    requested_wal_budget_bytes,
    policy.maintenance_max_wal_bytes
  );
  time_budget := COALESCE(requested_time_budget_ms, policy.maintenance_max_time_ms);
  IF row_budget NOT BETWEEN 1 AND policy.maintenance_max_rows THEN
    RAISE EXCEPTION 'otlet maintenance row budget must be between 1 and %',
      policy.maintenance_max_rows;
  END IF;
  IF wal_budget NOT BETWEEN 1 AND policy.maintenance_max_wal_bytes THEN
    RAISE EXCEPTION 'otlet maintenance WAL budget must be between 1 and %',
      policy.maintenance_max_wal_bytes;
  END IF;
  IF time_budget NOT BETWEEN 1 AND policy.maintenance_max_time_ms THEN
    RAISE EXCEPTION 'otlet maintenance time budget must be between 1 and %',
      policy.maintenance_max_time_ms;
  END IF;

  IF requested_kind = 'cleanup' THEN
    IF requested_target_name IS NOT NULL
       OR requested_target_revision_hash IS NOT NULL THEN
      RAISE EXCEPTION 'otlet cleanup maintenance does not accept a target';
    END IF;
  ELSIF requested_kind = 'reconciliation' THEN
    IF requested_target_name IS NOT NULL
       OR requested_target_revision_hash IS NOT NULL THEN
      RAISE EXCEPTION 'otlet reconciliation maintenance does not accept a target';
    END IF;
  ELSIF requested_kind = 'archive' THEN
    IF requested_target_name IS NULL OR requested_target_revision_hash IS NULL THEN
      RAISE EXCEPTION 'otlet archive maintenance requires a task and revision';
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM otlet.tasks task
      WHERE task.name = requested_target_name
        AND task.lifecycle_state = 'paused'
        AND task.lifecycle_revision_hash = requested_target_revision_hash
    ) THEN
      RAISE EXCEPTION 'otlet archive maintenance requires the exact paused task revision';
    END IF;
  ELSE
    IF requested_target_name IS NULL OR requested_target_revision_hash IS NULL THEN
      RAISE EXCEPTION 'otlet repair maintenance requires a task and revision';
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM otlet.workload_revision_heads head
      JOIN otlet.workload_revisions revision
        ON revision.task_name = head.task_name
       AND revision.workload_revision_hash = head.active_workload_revision_hash
      WHERE head.task_name = requested_target_name
        AND head.active_workload_revision_hash = requested_target_revision_hash
        AND revision.definition #>> '{source,kind}' IN ('row', 'pair')
    ) THEN
      RAISE EXCEPTION 'otlet repair maintenance requires an active row or pair revision';
    END IF;
  END IF;

  INSERT INTO otlet.maintenance_runs (
    kind,
    target_name,
    target_revision_hash,
    row_budget,
    wal_budget_bytes,
    time_budget_ms
  ) VALUES (
    requested_kind,
    requested_target_name,
    requested_target_revision_hash,
    row_budget,
    wal_budget,
    time_budget
  )
  RETURNING id INTO created_id;
  RETURN created_id;
END;
$$;

CREATE FUNCTION otlet.set_maintenance_run_state(
  requested_run_id bigint,
  expected_generation bigint,
  requested_state text,
  requested_reason text DEFAULT NULL
) RETURNS otlet.maintenance_runs
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  run otlet.maintenance_runs%ROWTYPE;
BEGIN
  IF requested_state NOT IN ('running', 'paused', 'retry', 'canceled') THEN
    RAISE EXCEPTION 'otlet maintenance state % is invalid', requested_state;
  END IF;
  IF requested_reason IS NOT NULL
     AND octet_length(requested_reason) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'otlet maintenance state reason must be between 1 and 4096 bytes';
  END IF;
  SELECT * INTO run
  FROM otlet.maintenance_runs
  WHERE id = requested_run_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet maintenance run % does not exist', requested_run_id;
  END IF;
  IF expected_generation IS NULL OR expected_generation <> run.generation THEN
    RAISE EXCEPTION 'otlet maintenance run % generation changed', requested_run_id;
  END IF;
  IF requested_state = 'paused' AND run.control_state <> 'running' THEN
    RAISE EXCEPTION 'otlet only a running maintenance run can pause';
  ELSIF requested_state = 'running' AND run.control_state <> 'paused' THEN
    RAISE EXCEPTION 'otlet only a paused maintenance run can resume';
  ELSIF requested_state = 'retry' AND run.control_state <> 'retryable' THEN
    RAISE EXCEPTION 'otlet only a retryable maintenance run can retry';
  ELSIF requested_state = 'canceled'
        AND run.control_state IN ('complete', 'canceled') THEN
    RETURN run;
  END IF;

  UPDATE otlet.maintenance_runs maintenance
  SET control_state = CASE requested_state
        WHEN 'retry' THEN 'running'
        ELSE requested_state
      END,
      generation = generation + 1,
      retry_count = retry_count + CASE requested_state WHEN 'retry' THEN 1 ELSE 0 END,
      last_stop_reason = CASE requested_state
        WHEN 'paused' THEN 'paused'
        WHEN 'canceled' THEN 'canceled'
        ELSE 'created'
      END,
      last_error = CASE requested_state WHEN 'retry' THEN NULL ELSE last_error END,
      state_reason = requested_reason,
      updated_at = clock_timestamp()
  WHERE maintenance.id = run.id
  RETURNING * INTO run;
  RETURN run;
END;
$$;

CREATE FUNCTION otlet.acknowledge_maintenance_vacuum(
  requested_run_id bigint,
  expected_generation bigint,
  requested_reason text
) RETURNS otlet.maintenance_runs
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  run otlet.maintenance_runs%ROWTYPE;
BEGIN
  IF requested_reason IS NULL
     OR octet_length(requested_reason) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'otlet vacuum acknowledgement reason must be between 1 and 4096 bytes';
  END IF;
  SELECT * INTO run
  FROM otlet.maintenance_runs
  WHERE id = requested_run_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet maintenance run % does not exist', requested_run_id;
  END IF;
  IF expected_generation IS NULL OR expected_generation <> run.generation THEN
    RAISE EXCEPTION 'otlet maintenance run % generation changed', requested_run_id;
  END IF;
  IF run.control_state NOT IN ('complete', 'canceled')
     OR cardinality(run.vacuum_relations) = 0 THEN
    RAISE EXCEPTION 'otlet maintenance run % has no terminal vacuum handoff',
      requested_run_id;
  END IF;
  IF run.vacuum_acknowledged_at IS NOT NULL THEN
    RAISE EXCEPTION 'otlet maintenance run % vacuum handoff is already acknowledged',
      requested_run_id;
  END IF;
  UPDATE otlet.maintenance_runs maintenance
  SET generation = generation + 1,
      vacuum_acknowledged_at = clock_timestamp(),
      vacuum_acknowledged_by = current_user,
      vacuum_acknowledgement_reason = requested_reason,
      updated_at = clock_timestamp()
  WHERE maintenance.id = run.id
  RETURNING * INTO run;
  RETURN run;
END;
$$;

CREATE FUNCTION otlet.maintenance_cleanup_step()
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
  candidate_job_id bigint;
  candidate_event_id bigint;
  candidate_receipt_id bigint;
  candidate_materialization_id bigint;
  label_task_name text;
  label_source_table text;
  label_subject_id text;
  changed bigint;
  total_changed bigint := 0;
  previous_cleanup text := current_setting('otlet.eval_label_cleanup', true);
BEGIN
  SELECT * INTO STRICT policy
  FROM otlet.production_policy
  WHERE name = 'default';

  SELECT job.id
  INTO candidate_job_id
  FROM otlet.jobs job
  WHERE job.status IN ('failed', 'canceled')
    AND job.execution_mode = 'production'
    AND (
      job.finished_at < clock_timestamp() - policy.failed_job_retention
      OR (
        job.finished_at IS NULL
        AND job.created_at < clock_timestamp() - policy.failed_job_retention
      )
    )
    AND NOT EXISTS (
      SELECT 1 FROM otlet.outputs output WHERE output.job_id = job.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM otlet.actions action WHERE action.job_id = job.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM otlet.review_samples sample WHERE sample.job_id = job.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.evaluation_results result
      WHERE result.job_id = job.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.evaluation_executions execution
      WHERE execution.job_id = job.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.production_model_cancellation_probes probe
      WHERE probe.job_id = job.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.production_model_database_samples sample
      WHERE sample.live_job_id = job.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.inference_receipts receipt
      WHERE receipt.job_id = job.id
        AND (
          EXISTS (
            SELECT 1 FROM otlet.outputs output
            WHERE output.receipt_id = receipt.id
          )
          OR EXISTS (
            SELECT 1 FROM otlet.actions action
            WHERE action.receipt_id = receipt.id
          )
          OR EXISTS (
            SELECT 1 FROM otlet.eval_labels label
            WHERE label.receipt_id = receipt.id
          )
          OR EXISTS (
            SELECT 1 FROM otlet.evaluation_results result
            WHERE result.receipt_id = receipt.id
          )
          OR EXISTS (
            SELECT 1 FROM otlet.review_samples sample
            WHERE sample.receipt_id = receipt.id
          )
        )
    )
  ORDER BY job.id
  LIMIT 1
  FOR UPDATE OF job SKIP LOCKED;
  IF FOUND THEN
    DELETE FROM otlet.worker_events event
    WHERE event.job_id = candidate_job_id;
    GET DIAGNOSTICS changed = ROW_COUNT;
    total_changed := total_changed + changed;
    DELETE FROM otlet.inference_receipts receipt
    WHERE receipt.job_id = candidate_job_id;
    GET DIAGNOSTICS changed = ROW_COUNT;
    total_changed := total_changed + changed;
    DELETE FROM otlet.jobs job
    WHERE job.id = candidate_job_id;
    GET DIAGNOSTICS changed = ROW_COUNT;
    total_changed := total_changed + changed;
    RETURN QUERY SELECT
      true,
      'failed_canceled_job'::text,
      total_changed,
      ARRAY[
        'otlet.inference_receipts',
        'otlet.jobs',
        'otlet.portable_claims',
        'otlet.portable_receipt_links',
        'otlet.task_backfill_subjects',
        'otlet.worker_events'
      ]::text[];
    RETURN;
  END IF;

  SELECT event.id
  INTO candidate_event_id
  FROM otlet.worker_events event
  WHERE event.created_at < clock_timestamp() - policy.worker_event_retention
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.jobs job
      WHERE job.id = event.job_id
        AND job.status IN ('queued', 'running', 'cancel_requested')
    )
  ORDER BY event.id
  LIMIT 1
  FOR UPDATE OF event SKIP LOCKED;
  IF FOUND THEN
    DELETE FROM otlet.worker_events event
    WHERE event.id = candidate_event_id;
    GET DIAGNOSTICS changed = ROW_COUNT;
    RETURN QUERY SELECT
      true,
      'worker_event'::text,
      changed,
      ARRAY['otlet.worker_events']::text[];
    RETURN;
  END IF;

  SELECT receipt.id
  INTO candidate_receipt_id
  FROM otlet.inference_receipts receipt
  WHERE receipt.finished_at < clock_timestamp() - policy.trace_detail_retention
    AND jsonb_typeof(receipt.trace_summary #> '{detailed_trace,steps}') = 'array'
    AND jsonb_array_length(
      receipt.trace_summary #> '{detailed_trace,steps}'
    ) > 0
  ORDER BY receipt.id
  LIMIT 1
  FOR UPDATE OF receipt SKIP LOCKED;
  IF FOUND THEN
    UPDATE otlet.inference_receipts receipt
    SET trace_summary = jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(
            otlet.redact_trace_summary(receipt.trace_summary, 'redacted'),
            '{detailed_trace,steps}',
            '[]'::jsonb,
            true
          ),
          '{detailed_trace,chosen_token_ids}',
          '[]'::jsonb,
          true
        ),
        '{detailed_trace,status}',
        '"pruned"'::jsonb,
        true
      ),
      '{detailed_trace,pruned_at}',
      to_jsonb(clock_timestamp()),
      true
    )
    WHERE receipt.id = candidate_receipt_id;
    GET DIAGNOSTICS changed = ROW_COUNT;
    RETURN QUERY SELECT
      true,
      'trace_detail'::text,
      changed,
      ARRAY['otlet.inference_receipts']::text[];
    RETURN;
  END IF;

  SELECT label.task_name, label.source_table, label.subject_id
  INTO label_task_name, label_source_table, label_subject_id
  FROM otlet.eval_labels label
  WHERE COALESCE(label.adjudicated_at, label.created_at) <
        clock_timestamp() - policy.eval_label_retention
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.eval_labels newer
      WHERE newer.task_name = label.task_name
        AND newer.source_table IS NOT DISTINCT FROM label.source_table
        AND newer.subject_id = label.subject_id
        AND COALESCE(newer.adjudicated_at, newer.created_at) >=
          clock_timestamp() - policy.eval_label_retention
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.eval_labels member
      JOIN otlet.evaluation_cases evaluation_case
        ON evaluation_case.label_id = member.id
      WHERE member.task_name = label.task_name
        AND member.source_table IS NOT DISTINCT FROM label.source_table
        AND member.subject_id = label.subject_id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.eval_labels member
      JOIN otlet.review_samples sample
        ON sample.receipt_id = member.receipt_id
      WHERE member.task_name = label.task_name
        AND member.source_table IS NOT DISTINCT FROM label.source_table
        AND member.subject_id = label.subject_id
    )
  ORDER BY label.task_name, label.source_table NULLS FIRST, label.subject_id
  LIMIT 1;
  IF FOUND THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(
      concat_ws(
        ':',
        'otlet_eval_label',
        label_task_name,
        COALESCE(label_source_table, ''),
        label_subject_id
      ),
      0
    ));
    IF EXISTS (
      SELECT 1
      FROM otlet.eval_labels label
      WHERE label.task_name = label_task_name
        AND label.source_table IS NOT DISTINCT FROM label_source_table
        AND label.subject_id = label_subject_id
      HAVING max(COALESCE(label.adjudicated_at, label.created_at)) <
          clock_timestamp() - policy.eval_label_retention
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.eval_labels member
          JOIN otlet.evaluation_cases evaluation_case
            ON evaluation_case.label_id = member.id
          WHERE member.task_name = label_task_name
            AND member.source_table IS NOT DISTINCT FROM label_source_table
            AND member.subject_id = label_subject_id
        )
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.eval_labels member
          JOIN otlet.review_samples sample
            ON sample.receipt_id = member.receipt_id
          WHERE member.task_name = label_task_name
            AND member.source_table IS NOT DISTINCT FROM label_source_table
            AND member.subject_id = label_subject_id
        )
    ) THEN
      PERFORM set_config('otlet.eval_label_cleanup', 'on', true);
      DELETE FROM otlet.eval_labels label
      WHERE label.task_name = label_task_name
        AND label.source_table IS NOT DISTINCT FROM label_source_table
        AND label.subject_id = label_subject_id;
      GET DIAGNOSTICS changed = ROW_COUNT;
      PERFORM set_config(
        'otlet.eval_label_cleanup',
        COALESCE(previous_cleanup, ''),
        true
      );
      RETURN QUERY SELECT
        true,
        'eval_label_series'::text,
        changed,
        ARRAY['otlet.eval_labels']::text[];
      RETURN;
    END IF;
  END IF;

  SELECT materialization.id
  INTO candidate_materialization_id
  FROM otlet.semantic_materializations materialization
  WHERE materialization.stale
    AND materialization.stale_reason = 'source_delete'
    AND materialization.updated_at <
      clock_timestamp() - policy.delete_stale_materialization_retention
  ORDER BY materialization.id
  LIMIT 1
  FOR UPDATE OF materialization SKIP LOCKED;
  IF FOUND THEN
    DELETE FROM otlet.semantic_materializations materialization
    WHERE materialization.id = candidate_materialization_id;
    GET DIAGNOSTICS changed = ROW_COUNT;
    RETURN QUERY SELECT
      true,
      'delete_stale_materialization'::text,
      changed,
      ARRAY[
        'otlet.semantic_materializations',
        'otlet.semantic_planner_statistics',
        'otlet.watch_time_freshness'
      ]::text[];
    RETURN;
  END IF;

  SELECT receipt.id
  INTO candidate_receipt_id
  FROM otlet.inference_receipts receipt
  WHERE (
      policy.sensitive_evidence_mode = 'redacted'
      OR receipt.finished_at <
        clock_timestamp() - policy.sensitive_evidence_retention
    )
    AND (
      receipt.raw_output IS NOT NULL
      OR receipt.trace_summary #>> '{detailed_trace,chosen_text}' IS NOT NULL
      OR jsonb_path_exists(
        receipt.trace_summary,
        '$.detailed_trace.steps[*].token_text'
      )
      OR jsonb_path_exists(
        receipt.trace_summary,
        '$.detailed_trace.steps[*].top_alternatives[*].token_text'
      )
    )
  ORDER BY receipt.id
  LIMIT 1
  FOR UPDATE OF receipt SKIP LOCKED;
  IF FOUND THEN
    UPDATE otlet.inference_receipts receipt
    SET raw_output = NULL,
        trace_summary = otlet.redact_trace_summary(
          receipt.trace_summary,
          'redacted'
        )
    WHERE receipt.id = candidate_receipt_id;
    GET DIAGNOSTICS changed = ROW_COUNT;
    RETURN QUERY SELECT
      true,
      'sensitive_evidence'::text,
      changed,
      ARRAY['otlet.inference_receipts']::text[];
    RETURN;
  END IF;

  RETURN QUERY SELECT false, NULL::text, 0::bigint, ARRAY[]::text[];
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config(
    'otlet.eval_label_cleanup',
    COALESCE(previous_cleanup, ''),
    true
  );
  RAISE;
END;
$$;

CREATE FUNCTION otlet.maintenance_cleanup_pending() RETURNS boolean
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
      WHERE job.status IN ('failed', 'canceled')
        AND job.execution_mode = 'production'
        AND COALESCE(job.finished_at, job.created_at) <
          clock_timestamp() - policy.failed_job_retention
        AND NOT EXISTS (
          SELECT 1 FROM otlet.outputs output WHERE output.job_id = job.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM otlet.actions action WHERE action.job_id = job.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM otlet.review_samples sample WHERE sample.job_id = job.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM otlet.evaluation_results result
          WHERE result.job_id = job.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM otlet.evaluation_executions execution
          WHERE execution.job_id = job.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM otlet.production_model_cancellation_probes probe
          WHERE probe.job_id = job.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM otlet.production_model_database_samples sample
          WHERE sample.live_job_id = job.id
        )
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.inference_receipts receipt
          WHERE receipt.job_id = job.id
            AND (
              EXISTS (
                SELECT 1 FROM otlet.outputs output
                WHERE output.receipt_id = receipt.id
              )
              OR EXISTS (
                SELECT 1 FROM otlet.actions action
                WHERE action.receipt_id = receipt.id
              )
              OR EXISTS (
                SELECT 1 FROM otlet.eval_labels label
                WHERE label.receipt_id = receipt.id
              )
              OR EXISTS (
                SELECT 1 FROM otlet.evaluation_results result
                WHERE result.receipt_id = receipt.id
              )
              OR EXISTS (
                SELECT 1 FROM otlet.review_samples sample
                WHERE sample.receipt_id = receipt.id
              )
            )
        )
    ) OR EXISTS (
      SELECT 1
      FROM otlet.worker_events event
      CROSS JOIN policy
      WHERE event.created_at < clock_timestamp() - policy.worker_event_retention
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.jobs job
          WHERE job.id = event.job_id
            AND job.status IN ('queued', 'running', 'cancel_requested')
        )
    ) OR EXISTS (
      SELECT 1
      FROM otlet.inference_receipts receipt
      CROSS JOIN policy
      WHERE receipt.finished_at <
          clock_timestamp() - policy.trace_detail_retention
        AND jsonb_typeof(
          receipt.trace_summary #> '{detailed_trace,steps}'
        ) = 'array'
        AND jsonb_array_length(
          receipt.trace_summary #> '{detailed_trace,steps}'
        ) > 0
    ) OR EXISTS (
      SELECT 1
      FROM otlet.eval_labels label
      CROSS JOIN policy
      WHERE COALESCE(label.adjudicated_at, label.created_at) <
          clock_timestamp() - policy.eval_label_retention
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.eval_labels newer
          WHERE newer.task_name = label.task_name
            AND newer.source_table IS NOT DISTINCT FROM label.source_table
            AND newer.subject_id = label.subject_id
            AND COALESCE(newer.adjudicated_at, newer.created_at) >=
              clock_timestamp() - policy.eval_label_retention
        )
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.eval_labels member
          JOIN otlet.evaluation_cases evaluation_case
            ON evaluation_case.label_id = member.id
          WHERE member.task_name = label.task_name
            AND member.source_table IS NOT DISTINCT FROM label.source_table
            AND member.subject_id = label.subject_id
        )
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.eval_labels member
          JOIN otlet.review_samples sample
            ON sample.receipt_id = member.receipt_id
          WHERE member.task_name = label.task_name
            AND member.source_table IS NOT DISTINCT FROM label.source_table
            AND member.subject_id = label.subject_id
        )
    ) OR EXISTS (
      SELECT 1
      FROM otlet.semantic_materializations materialization
      CROSS JOIN policy
      WHERE materialization.stale
        AND materialization.stale_reason = 'source_delete'
        AND materialization.updated_at < clock_timestamp()
          - policy.delete_stale_materialization_retention
    ) OR EXISTS (
      SELECT 1
      FROM otlet.inference_receipts receipt
      CROSS JOIN policy
      WHERE (
          policy.sensitive_evidence_mode = 'redacted'
          OR receipt.finished_at <
            clock_timestamp() - policy.sensitive_evidence_retention
        )
        AND (
          receipt.raw_output IS NOT NULL
          OR receipt.trace_summary #>> '{detailed_trace,chosen_text}' IS NOT NULL
          OR jsonb_path_exists(
            receipt.trace_summary,
            '$.detailed_trace.steps[*].token_text'
          )
          OR jsonb_path_exists(
            receipt.trace_summary,
            '$.detailed_trace.steps[*].top_alternatives[*].token_text'
          )
        )
    );
$$;

CREATE FUNCTION otlet.maintenance_reconciliation_step() RETURNS TABLE (
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
  result text;
BEGIN
  result := otlet.replay_watch_reconciliation(true);
  IF result = 'idle' THEN
    RETURN QUERY SELECT false, NULL::text, 0::bigint, ARRAY[]::text[];
    RETURN;
  END IF;
  RETURN QUERY SELECT
    true,
    ('watch_reconciliation_' || result)::text,
    1::bigint,
    ARRAY[
      'otlet.jobs',
      'otlet.semantic_materializations',
      'otlet.semantic_planner_statistics',
      'otlet.task_backfill_subjects',
      'otlet.watch_reconciliation',
      'otlet.watch_time_freshness',
      'otlet.worker_events'
    ]::text[];
END;
$$;

CREATE FUNCTION otlet.maintenance_reconciliation_pending() RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM otlet.watch_reconciliation reconciliation
    LEFT JOIN otlet.watches watch ON watch.name = reconciliation.watch_name
    LEFT JOIN otlet.tasks task ON task.name = watch.task_name
    WHERE (watch.name IS NULL OR task.lifecycle_state = 'active')
      AND reconciliation.state IN ('pending', 'exhausted')
  );
$$;

CREATE FUNCTION otlet.run_maintenance_slice(
  requested_run_id bigint,
  expected_generation bigint
) RETURNS otlet.maintenance_runs
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  run otlet.maintenance_runs%ROWTYPE;
  saved otlet.maintenance_runs%ROWTYPE;
  step record;
  start_time timestamptz;
  start_wal bigint;
  slice_items integer := 0;
  slice_changed bigint := 0;
  slice_wal bigint := 0;
  slice_elapsed bigint := 0;
  slice_relations text[] := ARRAY[]::text[];
  stop_reason text;
  error_message text;
  archive_materializations bigint;
BEGIN
  SELECT * INTO run
  FROM otlet.maintenance_runs
  WHERE id = requested_run_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet maintenance run % does not exist', requested_run_id;
  END IF;
  IF expected_generation IS NULL OR expected_generation <> run.generation THEN
    RAISE EXCEPTION 'otlet maintenance run % generation changed', requested_run_id;
  END IF;
  IF run.control_state <> 'running' THEN
    RETURN run;
  END IF;
  IF run.kind = 'cleanup'
     AND current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'otlet cleanup maintenance requires read committed isolation';
  END IF;

  start_time := clock_timestamp();
  start_wal := otlet.maintenance_observed_wal_bytes();

  LOOP
    step := NULL;
    BEGIN
      IF run.kind = 'cleanup' THEN
        SELECT * INTO step
        FROM otlet.maintenance_cleanup_step();
      ELSIF run.kind = 'reconciliation' THEN
        SELECT * INTO step
        FROM otlet.maintenance_reconciliation_step();
      ELSIF run.kind = 'archive' THEN
        SELECT count(*)::bigint
        INTO archive_materializations
        FROM otlet.semantic_materializations materialization
        WHERE materialization.task_name = run.target_name;
        PERFORM otlet.set_task_lifecycle(
          run.target_name,
          'retired',
          run.target_revision_hash
        );
        SELECT
          true AS item_found,
          'task_archive'::text AS item_kind,
          archive_materializations + 1 AS affected_rows,
          ARRAY[
            'otlet.administrative_change_events',
            'otlet.semantic_materializations',
            'otlet.semantic_planner_statistics',
            'otlet.tasks'
          ]::text[] AS touched_relations
        INTO step;
      ELSE
        PERFORM otlet.maintain_semantic_planner_statistics(
          run.target_name,
          run.target_revision_hash
        );
        SELECT
          true AS item_found,
          'semantic_statistics_repair'::text AS item_kind,
          1::bigint AS affected_rows,
          ARRAY['otlet.semantic_planner_statistics']::text[] AS touched_relations
        INTO step;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
      slice_wal := GREATEST(
        otlet.maintenance_observed_wal_bytes() - start_wal,
        0
      );
      slice_elapsed := GREATEST(
        floor(extract(epoch FROM clock_timestamp() - start_time) * 1000)::bigint,
        0
      );
      UPDATE otlet.maintenance_runs maintenance
      SET control_state = 'retryable',
          generation = generation + 1,
          processed_items = processed_items + slice_items,
          changed_rows = changed_rows + slice_changed,
          observed_wal_bytes = observed_wal_bytes + slice_wal,
          observed_elapsed_ms = observed_elapsed_ms + slice_elapsed,
          slice_count = slice_count + 1,
          last_slice_items = slice_items,
          last_slice_changed_rows = slice_changed,
          last_slice_wal_bytes = slice_wal,
          last_slice_elapsed_ms = slice_elapsed,
          last_item_kind = COALESCE(run.last_item_kind, last_item_kind),
          last_stop_reason = 'failed',
          last_error = left(error_message, 1024),
          vacuum_relations = otlet.merge_maintenance_relations(
            vacuum_relations,
            slice_relations
          ),
          updated_at = clock_timestamp()
      WHERE maintenance.id = run.id
      RETURNING * INTO saved;
      RETURN saved;
    END;

    IF NOT COALESCE(step.item_found, false) THEN
      IF run.kind = 'cleanup' AND otlet.maintenance_cleanup_pending() THEN
        stop_reason := 'waiting';
      ELSIF run.kind = 'reconciliation'
            AND otlet.maintenance_reconciliation_pending() THEN
        stop_reason := 'waiting';
      ELSE
        stop_reason := 'complete';
      END IF;
      EXIT;
    END IF;

    slice_items := slice_items + 1;
    slice_changed := slice_changed + COALESCE(step.affected_rows, 0);
    slice_relations := otlet.merge_maintenance_relations(
      slice_relations,
      step.touched_relations
    );
    run.last_item_kind := step.item_kind;
    slice_wal := GREATEST(
      otlet.maintenance_observed_wal_bytes() - start_wal,
      0
    );
    slice_elapsed := GREATEST(
      floor(extract(epoch FROM clock_timestamp() - start_time) * 1000)::bigint,
      0
    );

    IF run.kind IN ('archive', 'repair') THEN
      stop_reason := 'complete';
      EXIT;
    ELSIF slice_items >= run.row_budget THEN
      stop_reason := 'row_budget';
      EXIT;
    ELSIF slice_wal >= run.wal_budget_bytes THEN
      stop_reason := 'wal_budget';
      EXIT;
    ELSIF slice_elapsed >= run.time_budget_ms THEN
      stop_reason := 'time_budget';
      EXIT;
    END IF;
  END LOOP;

  slice_wal := GREATEST(
    otlet.maintenance_observed_wal_bytes() - start_wal,
    0
  );
  slice_elapsed := GREATEST(
    floor(extract(epoch FROM clock_timestamp() - start_time) * 1000)::bigint,
    0
  );
  UPDATE otlet.maintenance_runs maintenance
  SET control_state = CASE stop_reason WHEN 'complete' THEN 'complete'
        ELSE control_state
      END,
      generation = generation + 1,
      processed_items = processed_items + slice_items,
      changed_rows = changed_rows + slice_changed,
      observed_wal_bytes = observed_wal_bytes + slice_wal,
      observed_elapsed_ms = observed_elapsed_ms + slice_elapsed,
      slice_count = slice_count + 1,
      last_slice_items = slice_items,
      last_slice_changed_rows = slice_changed,
      last_slice_wal_bytes = slice_wal,
      last_slice_elapsed_ms = slice_elapsed,
      last_item_kind = COALESCE(run.last_item_kind, last_item_kind),
      last_stop_reason = stop_reason,
      last_error = NULL,
      vacuum_relations = otlet.merge_maintenance_relations(
        vacuum_relations,
        slice_relations
      ),
      completed_at = CASE stop_reason WHEN 'complete' THEN clock_timestamp()
        ELSE NULL
      END,
      updated_at = clock_timestamp()
  WHERE maintenance.id = run.id
  RETURNING * INTO saved;
  RETURN saved;
END;
$$;

DO $migration$
DECLARE
  definition text;
  rewritten text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.replay_watch_reconciliation(boolean)'::regprocedure
  );
  IF position('SKIP LOCKED' IN definition) > 0 THEN
    RAISE EXCEPTION 'otlet watch reconciliation already has an unexpected lock rewrite';
  END IF;
  rewritten := pg_catalog.replace(
    definition,
    'LIMIT 1;',
    E'LIMIT 1\n  FOR UPDATE OF reconciliation SKIP LOCKED;'
  );
  IF rewritten = definition THEN
    RAISE EXCEPTION 'otlet watch reconciliation lock rewrite is incomplete';
  END IF;
  EXECUTE rewritten;
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.cleanup_policy_state(boolean)'::regprocedure
  );
  old_fragment := $old$BEGIN
  SELECT policy.eval_label_retention$old$;
  new_fragment := $new$BEGIN
  IF NOT COALESCE(cleanup_policy_state.requested_dry_run, true) THEN
    RAISE EXCEPTION 'otlet mutating cleanup requires a bounded maintenance run';
  END IF;
  SELECT policy.eval_label_retention$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet cleanup preview guard rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);

  definition := pg_catalog.pg_get_functiondef(
    'otlet.cleanup_policy_state_without_label_quality(boolean)'::regprocedure
  );
  old_fragment := $old$BEGIN
  SELECT
    worker_event_retention,$old$;
  new_fragment := $new$BEGIN
  IF NOT COALESCE(
    cleanup_policy_state_without_label_quality.requested_dry_run,
    true
  ) THEN
    RAISE EXCEPTION 'otlet mutating cleanup requires a bounded maintenance run';
  END IF;
  SELECT
    worker_event_retention,$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet cleanup helper guard rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  old_fragment := $old$      AND NOT EXISTS (
        SELECT 1
        FROM otlet.actions a
        WHERE a.job_id = j.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.inference_receipts r
        WHERE r.job_id = j.id
          AND (
            EXISTS (SELECT 1 FROM otlet.outputs o WHERE o.receipt_id = r.id)
            OR EXISTS (SELECT 1 FROM otlet.actions a WHERE a.receipt_id = r.id)
            OR EXISTS (SELECT 1 FROM otlet.eval_labels l WHERE l.receipt_id = r.id)
          )
      );$old$;
  new_fragment := $new$      AND NOT EXISTS (
        SELECT 1
        FROM otlet.actions a
        WHERE a.job_id = j.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM otlet.review_samples sample WHERE sample.job_id = j.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM otlet.evaluation_results result WHERE result.job_id = j.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.evaluation_executions execution
        WHERE execution.job_id = j.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.production_model_cancellation_probes probe
        WHERE probe.job_id = j.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.production_model_database_samples sample
        WHERE sample.live_job_id = j.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.inference_receipts r
        WHERE r.job_id = j.id
          AND (
            EXISTS (SELECT 1 FROM otlet.outputs o WHERE o.receipt_id = r.id)
            OR EXISTS (SELECT 1 FROM otlet.actions a WHERE a.receipt_id = r.id)
            OR EXISTS (SELECT 1 FROM otlet.eval_labels l WHERE l.receipt_id = r.id)
            OR EXISTS (
              SELECT 1 FROM otlet.evaluation_results result
              WHERE result.receipt_id = r.id
            )
            OR EXISTS (
              SELECT 1 FROM otlet.review_samples sample
              WHERE sample.receipt_id = r.id
            )
          )
      );$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet cleanup retained evidence preview rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);

  definition := pg_catalog.pg_get_functiondef(
    'otlet.cleanup_eval_label_series(timestamptz,boolean)'::regprocedure
  );
  old_fragment := $old$BEGIN
  IF cleanup_eval_label_series.cutoff IS NULL THEN$old$;
  new_fragment := $new$BEGIN
  IF NOT COALESCE(cleanup_eval_label_series.requested_dry_run, true) THEN
    RAISE EXCEPTION 'otlet mutating evaluation label cleanup requires a bounded maintenance run';
  END IF;
  IF cleanup_eval_label_series.cutoff IS NULL THEN$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet evaluation label cleanup guard rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
END;
$migration$;

COMMENT ON TABLE otlet.maintenance_runs IS
'Caller-driven cleanup, archive, reconciliation, and repair slices with immutable budgets';
COMMENT ON VIEW otlet.maintenance_run_status IS
'Owner-only progress, bounded failure, and post-commit vacuum handoff state';
COMMENT ON COLUMN otlet.maintenance_runs.changed_rows IS
'Logical row changes reported by completed primary maintenance items';
COMMENT ON COLUMN otlet.maintenance_runs.vacuum_relations IS
'Conservative allowlist of changed relations for post-commit vacuum review';
COMMENT ON FUNCTION otlet.run_maintenance_slice(bigint, bigint) IS
'Runs primary items until the row cap or an observed cluster-WAL or elapsed boundary; one atomic item may cross WAL or time';

REVOKE ALL ON TABLE otlet.maintenance_runs FROM PUBLIC;
REVOKE ALL ON TABLE otlet.maintenance_run_status FROM PUBLIC;
REVOKE ALL ON SEQUENCE otlet.maintenance_runs_id_seq FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.maintenance_observed_wal_bytes() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.merge_maintenance_relations(text[], text[])
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.maintenance_cleanup_step() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.maintenance_cleanup_pending() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.maintenance_reconciliation_step()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.maintenance_reconciliation_pending()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.create_maintenance_run(
  text, text, text, integer, bigint, integer
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.set_maintenance_run_state(
  bigint, bigint, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.run_maintenance_slice(bigint, bigint)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.acknowledge_maintenance_vacuum(
  bigint, bigint, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.cleanup_policy_state(boolean) FROM PUBLIC;
