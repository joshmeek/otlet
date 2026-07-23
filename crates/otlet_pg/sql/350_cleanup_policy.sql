CREATE TABLE otlet.retention_holds (
  id bigserial PRIMARY KEY,
  job_id bigint NOT NULL,
  task_name text NOT NULL,
  subject_id_hash text NOT NULL,
  reason text NOT NULL,
  held_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  released_at timestamptz,
  released_by text,
  release_reason text,
  CHECK (subject_id_hash ~ '^[0-9a-f]{32}$'),
  CHECK (NULLIF(reason, '') IS NOT NULL),
  CHECK (octet_length(reason) <= 4096),
  CHECK (release_reason IS NULL OR octet_length(release_reason) <= 4096),
  CHECK ((released_at IS NULL) = (released_by IS NULL)),
  CHECK ((released_at IS NULL) = (release_reason IS NULL))
);

CREATE UNIQUE INDEX retention_holds_one_active_job_idx
ON otlet.retention_holds (job_id)
WHERE released_at IS NULL;

CREATE TABLE otlet.cleanup_runs (
  id bigserial PRIMARY KEY,
  requested_by text NOT NULL,
  policy_snapshot jsonb NOT NULL CHECK (jsonb_typeof(policy_snapshot) = 'object'),
  candidate_digest text NOT NULL,
  family_counts jsonb NOT NULL CHECK (jsonb_typeof(family_counts) = 'object'),
  status text NOT NULL CHECK (status = 'applied'),
  started_at timestamptz NOT NULL,
  finished_at timestamptz NOT NULL DEFAULT now(),
  CHECK (candidate_digest ~ '^[0-9a-f]{32}$')
);

CREATE TABLE otlet.evidence_cleanup_receipts (
  id bigserial PRIMARY KEY,
  cleanup_run_id bigint NOT NULL REFERENCES otlet.cleanup_runs(id),
  job_id bigint NOT NULL UNIQUE,
  task_name text NOT NULL,
  subject_id_hash text NOT NULL,
  identity_hashes jsonb NOT NULL CHECK (jsonb_typeof(identity_hashes) = 'object'),
  family_counts jsonb NOT NULL CHECK (jsonb_typeof(family_counts) = 'object'),
  cleaned_at timestamptz NOT NULL DEFAULT now(),
  CHECK (subject_id_hash ~ '^[0-9a-f]{32}$')
);

CREATE FUNCTION otlet.place_retention_hold(
  job_id bigint,
  reason text
) RETURNS otlet.retention_holds
LANGUAGE plpgsql
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  saved otlet.retention_holds%ROWTYPE;
BEGIN
  IF NULLIF(place_retention_hold.reason, '') IS NULL THEN
    RAISE EXCEPTION 'otlet retention hold reason is required';
  END IF;
  SELECT * INTO job_row
  FROM otlet.jobs j
  WHERE j.id = place_retention_hold.job_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet job % does not exist', place_retention_hold.job_id;
  END IF;

  INSERT INTO otlet.retention_holds (
    job_id,
    task_name,
    subject_id_hash,
    reason,
    held_by
  )
  VALUES (
    job_row.id,
    job_row.task_name,
    md5(job_row.subject_id),
    place_retention_hold.reason,
    session_user
  )
  RETURNING * INTO saved;
  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.release_retention_hold(
  hold_id bigint,
  reason text
) RETURNS otlet.retention_holds
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.retention_holds%ROWTYPE;
BEGIN
  IF NULLIF(release_retention_hold.reason, '') IS NULL THEN
    RAISE EXCEPTION 'otlet retention hold release reason is required';
  END IF;
  UPDATE otlet.retention_holds h
  SET released_at = now(),
      released_by = session_user,
      release_reason = release_retention_hold.reason
  WHERE h.id = release_retention_hold.hold_id
    AND h.released_at IS NULL
  RETURNING * INTO saved;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet active retention hold % does not exist', release_retention_hold.hold_id;
  END IF;
  RETURN saved;
END;
$$;

CREATE VIEW otlet.retention_hold_status AS
SELECT
  h.id AS hold_id,
  h.job_id,
  h.task_name,
  h.subject_id_hash,
  md5(h.reason) AS reason_hash,
  h.held_by,
  h.created_at,
  h.released_at IS NULL AS active,
  h.released_at,
  h.released_by,
  CASE WHEN h.release_reason IS NULL THEN NULL ELSE md5(h.release_reason) END AS release_reason_hash
FROM otlet.retention_holds h;

CREATE VIEW otlet.cleanup_receipt_status AS
SELECT
  r.id AS cleanup_run_id,
  r.requested_by,
  r.policy_snapshot,
  r.candidate_digest,
  r.family_counts,
  r.status,
  count(e.id)::bigint AS job_receipts,
  r.started_at,
  r.finished_at
FROM otlet.cleanup_runs r
LEFT JOIN otlet.evidence_cleanup_receipts e ON e.cleanup_run_id = r.id
GROUP BY r.id;

CREATE VIEW otlet.retention_copy_status AS
SELECT
  'active_state_cleanup_v1'::text AS policy_name,
  true AS active_table_payloads_covered,
  true AS active_table_storage_reclaim_requires_vacuum,
  true AS cleanup_generates_wal,
  false AS prior_wal_copies_deleted,
  false AS physical_backup_copies_deleted,
  false AS restore_point_copies_deleted,
  false AS point_in_time_recovery_copies_deleted,
  'Cleanup removes eligible payloads from active Otlet tables. Existing WAL, backups, snapshots, restores, replicas, and point-in-time recovery windows follow infrastructure retention.'::text AS limitation;

CREATE FUNCTION otlet.cleanup_policy_state(
  requested_dry_run boolean DEFAULT true
) RETURNS TABLE (
  worker_events bigint,
  token_trace_rows bigint,
  token_alternative_rows bigint,
  eval_labels bigint,
  delete_stale_materializations bigint,
  sensitive_raw_outputs bigint,
  sensitive_chosen_texts bigint,
  sensitive_token_texts bigint,
  sensitive_alternative_token_texts bigint,
  failed_canceled_jobs bigint,
  terminal_jobs bigint,
  terminal_job_inputs bigint,
  terminal_outputs bigint,
  terminal_actions bigint,
  terminal_corrections bigint,
  terminal_receipt_payloads bigint,
  terminal_events bigint,
  terminal_records bigint,
  terminal_materializations bigint,
  cleanup_run_id bigint,
  dry_run boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
  worker_retention interval;
  trace_retention interval;
  eval_retention interval;
  delete_stale_retention interval;
  sensitive_mode text;
  sensitive_retention interval;
  failed_job_retention_interval interval;
  terminal_retention interval;
  worker_count bigint := 0;
  token_count bigint := 0;
  alternative_count bigint := 0;
  eval_count bigint := 0;
  delete_stale_count bigint := 0;
  sensitive_raw_output_count bigint := 0;
  sensitive_chosen_text_count bigint := 0;
  sensitive_token_text_count bigint := 0;
  sensitive_alternative_text_count bigint := 0;
  failed_canceled_job_count bigint := 0;
  deleted_worker_count bigint := 0;
  terminal_job_count bigint := 0;
  terminal_input_count bigint := 0;
  terminal_output_count bigint := 0;
  terminal_action_count bigint := 0;
  terminal_correction_count bigint := 0;
  terminal_receipt_count bigint := 0;
  terminal_event_count bigint := 0;
  terminal_record_count bigint := 0;
  terminal_materialization_count bigint := 0;
  applied_cleanup_run_id bigint := NULL;
  cleanup_started_at timestamptz := clock_timestamp();
BEGIN
  SELECT
    worker_event_retention,
    trace_detail_retention,
    eval_label_retention,
    delete_stale_materialization_retention,
    sensitive_evidence_mode,
    sensitive_evidence_retention,
    terminal_evidence_retention,
    failed_job_retention
  INTO
    worker_retention,
    trace_retention,
    eval_retention,
    delete_stale_retention,
    sensitive_mode,
    sensitive_retention,
    terminal_retention,
    failed_job_retention_interval
  FROM otlet.production_policy
  WHERE name = 'default';

  DROP TABLE IF EXISTS otlet_cleanup_job_candidates;
  CREATE TEMP TABLE otlet_cleanup_job_candidates ON COMMIT DROP AS
    SELECT j.id
    FROM otlet.jobs j
    WHERE j.status IN ('failed', 'canceled')
      AND (
        j.finished_at < now() - failed_job_retention_interval
        OR (
          j.finished_at IS NULL
          AND j.created_at < now() - failed_job_retention_interval
        )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.outputs o
        WHERE o.job_id = j.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.retention_holds h
        WHERE h.job_id = j.id
          AND h.released_at IS NULL
      )
      AND NOT EXISTS (
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
      );

  DROP TABLE IF EXISTS otlet_cleanup_terminal_candidates;
  CREATE TEMP TABLE otlet_cleanup_terminal_candidates ON COMMIT DROP AS
    SELECT j.id
    FROM otlet.jobs j
    WHERE j.status IN ('complete', 'failed', 'canceled')
      AND COALESCE(j.finished_at, j.created_at) < now() - terminal_retention
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.retention_holds h
        WHERE h.job_id = j.id
          AND h.released_at IS NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.evidence_cleanup_receipts receipt
        WHERE receipt.job_id = j.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.actions a
        WHERE a.job_id = j.id
          AND a.status IN ('proposed', 'approved')
      );

  SELECT
    (SELECT count(*) FROM otlet_cleanup_terminal_candidates),
    (SELECT count(*) FROM otlet_cleanup_terminal_candidates),
    (
      SELECT count(*)
      FROM otlet.outputs o
      JOIN otlet_cleanup_terminal_candidates c ON c.id = o.job_id
    ),
    (
      SELECT count(*)
      FROM otlet.actions a
      JOIN otlet_cleanup_terminal_candidates c ON c.id = a.job_id
    ),
    (
      SELECT count(DISTINCT l.id)
      FROM otlet.eval_labels l
      LEFT JOIN otlet.actions a ON a.id = l.action_id
      LEFT JOIN otlet.outputs o ON o.id = l.output_id
      LEFT JOIN otlet.inference_receipts r ON r.id = l.receipt_id
      JOIN otlet_cleanup_terminal_candidates c
        ON c.id = a.job_id OR c.id = o.job_id OR c.id = r.job_id
      WHERE l.label_source = 'manual_correction'
    ),
    (
      SELECT count(*)
      FROM otlet.inference_receipts r
      JOIN otlet_cleanup_terminal_candidates c ON c.id = r.job_id
    ),
    (
      SELECT count(*)
      FROM otlet.worker_events e
      JOIN otlet_cleanup_terminal_candidates c ON c.id = e.job_id
    ),
    (
      SELECT count(*)
      FROM otlet.records record
      JOIN otlet.actions a ON a.id = record.action_id
      JOIN otlet_cleanup_terminal_candidates c ON c.id = a.job_id
    ),
    (
      SELECT count(*)
      FROM otlet.semantic_materializations sm
      JOIN otlet.records record ON record.id = sm.record_id
      JOIN otlet.actions a ON a.id = record.action_id
      JOIN otlet_cleanup_terminal_candidates c ON c.id = a.job_id
    )
  INTO
    terminal_job_count,
    terminal_input_count,
    terminal_output_count,
    terminal_action_count,
    terminal_correction_count,
    terminal_receipt_count,
    terminal_event_count,
    terminal_record_count,
    terminal_materialization_count;

  IF cleanup_policy_state.requested_dry_run THEN
    WITH event_candidates AS (
      SELECT e.id
      FROM otlet.worker_events e
      WHERE e.created_at < now() - worker_retention
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.jobs j
          WHERE j.id = e.job_id
            AND j.status IN ('queued', 'running', 'cancel_requested')
        )
      UNION
      SELECT e.id
      FROM otlet.worker_events e
      JOIN otlet_cleanup_job_candidates c ON c.id = e.job_id
    )
    SELECT count(*)
    INTO worker_count
    FROM event_candidates;
  END IF;

  SELECT count(*)
  INTO failed_canceled_job_count
  FROM otlet_cleanup_job_candidates;

  WITH candidates AS (
    SELECT r.trace_summary #> '{detailed_trace,steps}' AS steps
    FROM otlet.inference_receipts r
    WHERE r.finished_at < now() - trace_retention
      AND jsonb_typeof(r.trace_summary #> '{detailed_trace,steps}') = 'array'
      AND jsonb_array_length(r.trace_summary #> '{detailed_trace,steps}') > 0
  )
  SELECT
    COALESCE(sum(jsonb_array_length(c.steps)), 0)::bigint,
    COALESCE(sum((
      SELECT count(*)::bigint
      FROM jsonb_array_elements(c.steps) step(value)
      CROSS JOIN LATERAL jsonb_array_elements(
        CASE
          WHEN jsonb_typeof(step.value -> 'top_alternatives') = 'array'
            THEN step.value -> 'top_alternatives'
          ELSE '[]'::jsonb
        END
      ) alt(value)
    )), 0)::bigint
  INTO token_count, alternative_count
  FROM candidates c;

  SELECT count(*)
  INTO eval_count
  FROM otlet.eval_labels l
  WHERE l.created_at < now() - eval_retention;

  SELECT count(*)
  INTO delete_stale_count
  FROM otlet.semantic_materializations sm
  WHERE sm.stale
    AND sm.stale_reason = 'source_delete'
    AND sm.updated_at < now() - delete_stale_retention;

  SELECT
    count(*) FILTER (WHERE r.raw_output IS NOT NULL),
    count(*) FILTER (WHERE r.trace_summary #>> '{detailed_trace,chosen_text}' IS NOT NULL)
  INTO sensitive_raw_output_count, sensitive_chosen_text_count
  FROM otlet.inference_receipts r
  WHERE sensitive_mode = 'redacted'
     OR r.finished_at < now() - sensitive_retention;

  SELECT count(*)
  INTO sensitive_token_text_count
  FROM otlet.inference_receipts r
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(r.trace_summary #> '{detailed_trace,steps}') = 'array'
        THEN r.trace_summary #> '{detailed_trace,steps}'
      ELSE '[]'::jsonb
    END
  ) step(value)
  WHERE (sensitive_mode = 'redacted' OR r.finished_at < now() - sensitive_retention)
    AND jsonb_typeof(step.value) = 'object'
    AND step.value ? 'token_text';

  SELECT count(*)
  INTO sensitive_alternative_text_count
  FROM otlet.inference_receipts r
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(r.trace_summary #> '{detailed_trace,steps}') = 'array'
        THEN r.trace_summary #> '{detailed_trace,steps}'
      ELSE '[]'::jsonb
    END
  ) step(value)
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(step.value -> 'top_alternatives') = 'array'
        THEN step.value -> 'top_alternatives'
      ELSE '[]'::jsonb
    END
  ) alt(value)
  WHERE (sensitive_mode = 'redacted' OR r.finished_at < now() - sensitive_retention)
    AND jsonb_typeof(alt.value) = 'object'
    AND alt.value ? 'token_text';

  IF NOT cleanup_policy_state.requested_dry_run THEN
    INSERT INTO otlet.cleanup_runs (
      requested_by,
      policy_snapshot,
      candidate_digest,
      family_counts,
      status,
      started_at
    )
    SELECT
      session_user,
      to_jsonb(p),
      md5(COALESCE((
        SELECT string_agg(
          c.id::text || ':' || md5(otlet.semantic_canonical_jsonb(j.input)::text),
          ',' ORDER BY c.id
        )
        FROM otlet_cleanup_terminal_candidates c
        JOIN otlet.jobs j ON j.id = c.id
      ), 'empty')),
      jsonb_build_object(
        'terminal_jobs', terminal_job_count,
        'job_inputs', terminal_input_count,
        'outputs', terminal_output_count,
        'actions', terminal_action_count,
        'corrections', terminal_correction_count,
        'receipt_payloads', terminal_receipt_count,
        'events', terminal_event_count,
        'records', terminal_record_count,
        'materializations', terminal_materialization_count
      ),
      'applied',
      cleanup_started_at
    FROM otlet.production_policy p
    WHERE p.name = 'default'
    RETURNING id INTO applied_cleanup_run_id;

    INSERT INTO otlet.evidence_cleanup_receipts (
      cleanup_run_id,
      job_id,
      task_name,
      subject_id_hash,
      identity_hashes,
      family_counts
    )
    SELECT
      applied_cleanup_run_id,
      j.id,
      j.task_name,
      md5(j.subject_id),
      jsonb_build_object(
        'input', md5(otlet.semantic_canonical_jsonb(j.input)::text),
        'job_error', md5(COALESCE(j.error, '')),
        'outputs', COALESCE((
          SELECT md5(string_agg(
            o.id::text || ':' || md5(otlet.semantic_canonical_jsonb(o.output)::text),
            ',' ORDER BY o.id
          ))
          FROM otlet.outputs o
          WHERE o.job_id = j.id
        ), md5('empty')),
        'actions', COALESCE((
          SELECT md5(string_agg(
            a.id::text || ':' || md5(otlet.semantic_canonical_jsonb(
              jsonb_build_object(
                'payload', a.payload,
                'error', a.error,
                'review_reason', a.review_reason
              )
            )::text),
            ',' ORDER BY a.id
          ))
          FROM otlet.actions a
          WHERE a.job_id = j.id
        ), md5('empty')),
        'receipts', COALESCE((
          SELECT md5(string_agg(
            r.id::text || ':' || md5(otlet.semantic_canonical_jsonb(
              jsonb_build_object(
                'raw_output', r.raw_output,
                'candidate_output', r.candidate_output,
                'trace_summary', r.trace_summary,
                'error', r.error
              )
            )::text),
            ',' ORDER BY r.id
          ))
          FROM otlet.inference_receipts r
          WHERE r.job_id = j.id
        ), md5('empty')),
        'events', COALESCE((
          SELECT md5(string_agg(
            e.id::text || ':' || md5(otlet.semantic_canonical_jsonb(
              jsonb_build_object('message', e.message, 'detail', e.detail)
            )::text),
            ',' ORDER BY e.id
          ))
          FROM otlet.worker_events e
          WHERE e.job_id = j.id
        ), md5('empty')),
        'labels', COALESCE((
          SELECT md5(string_agg(
            l.id::text || ':' || md5(otlet.semantic_canonical_jsonb(to_jsonb(l))::text),
            ',' ORDER BY l.id
          ))
          FROM otlet.eval_labels l
          LEFT JOIN otlet.actions a ON a.id = l.action_id
          LEFT JOIN otlet.outputs o ON o.id = l.output_id
          LEFT JOIN otlet.inference_receipts r ON r.id = l.receipt_id
          WHERE a.job_id = j.id OR o.job_id = j.id OR r.job_id = j.id
        ), md5('empty')),
        'records', COALESCE((
          SELECT md5(string_agg(
            record.id::text || ':' || md5(otlet.semantic_canonical_jsonb(record.body)::text),
            ',' ORDER BY record.id
          ))
          FROM otlet.records record
          JOIN otlet.actions a ON a.id = record.action_id
          WHERE a.job_id = j.id
        ), md5('empty')),
        'materializations', COALESCE((
          SELECT md5(string_agg(
            sm.id::text || ':' || md5(otlet.semantic_canonical_jsonb(
              jsonb_build_object('body', sm.body, 'source_dependencies', sm.source_dependencies)
            )::text),
            ',' ORDER BY sm.id
          ))
          FROM otlet.semantic_materializations sm
          JOIN otlet.records record ON record.id = sm.record_id
          JOIN otlet.actions a ON a.id = record.action_id
          WHERE a.job_id = j.id
        ), md5('empty'))
      ),
      jsonb_build_object(
        'outputs', (SELECT count(*) FROM otlet.outputs o WHERE o.job_id = j.id),
        'actions', (SELECT count(*) FROM otlet.actions a WHERE a.job_id = j.id),
        'receipts', (SELECT count(*) FROM otlet.inference_receipts r WHERE r.job_id = j.id),
        'events', (SELECT count(*) FROM otlet.worker_events e WHERE e.job_id = j.id),
        'labels', (
          SELECT count(*)
          FROM otlet.eval_labels l
          LEFT JOIN otlet.actions a ON a.id = l.action_id
          LEFT JOIN otlet.outputs o ON o.id = l.output_id
          LEFT JOIN otlet.inference_receipts r ON r.id = l.receipt_id
          WHERE a.job_id = j.id OR o.job_id = j.id OR r.job_id = j.id
        ),
        'records', (
          SELECT count(*)
          FROM otlet.records record
          JOIN otlet.actions a ON a.id = record.action_id
          WHERE a.job_id = j.id
        ),
        'materializations', (
          SELECT count(*)
          FROM otlet.semantic_materializations sm
          JOIN otlet.records record ON record.id = sm.record_id
          JOIN otlet.actions a ON a.id = record.action_id
          WHERE a.job_id = j.id
        )
      )
    FROM otlet_cleanup_terminal_candidates c
    JOIN otlet.jobs j ON j.id = c.id;

    WITH event_candidates AS (
      SELECT e.id
      FROM otlet.worker_events e
      WHERE e.created_at < now() - worker_retention
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.jobs j
          WHERE j.id = e.job_id
            AND j.status IN ('queued', 'running', 'cancel_requested')
        )
    )
    DELETE FROM otlet.worker_events e
    USING event_candidates c
    WHERE e.id = c.id;
    GET DIAGNOSTICS worker_count = ROW_COUNT;

    DELETE FROM otlet.worker_events e
    USING otlet_cleanup_job_candidates c
    WHERE e.job_id = c.id;
    GET DIAGNOSTICS deleted_worker_count = ROW_COUNT;
    worker_count := worker_count + deleted_worker_count;

    DELETE FROM otlet.inference_receipts r
    USING otlet_cleanup_job_candidates c
    WHERE r.job_id = c.id;

    DELETE FROM otlet.jobs j
    USING otlet_cleanup_job_candidates c
    WHERE j.id = c.id;

    UPDATE otlet.inference_receipts r
    SET trace_summary = jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(
            otlet.redact_trace_summary(r.trace_summary, 'redacted'),
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
    WHERE r.finished_at < now() - trace_retention
      AND jsonb_typeof(r.trace_summary #> '{detailed_trace,steps}') = 'array'
      AND jsonb_array_length(r.trace_summary #> '{detailed_trace,steps}') > 0;

    DELETE FROM otlet.eval_labels l
    WHERE l.created_at < now() - eval_retention;

    DELETE FROM otlet.semantic_materializations sm
    WHERE sm.stale
      AND sm.stale_reason = 'source_delete'
      AND sm.updated_at < now() - delete_stale_retention;

    UPDATE otlet.inference_receipts r
    SET raw_output = NULL,
        trace_summary = otlet.redact_trace_summary(r.trace_summary, 'redacted')
    WHERE (sensitive_mode = 'redacted' OR r.finished_at < now() - sensitive_retention)
      AND (
        r.raw_output IS NOT NULL
        OR r.trace_summary #>> '{detailed_trace,chosen_text}' IS NOT NULL
        OR jsonb_path_exists(r.trace_summary, '$.detailed_trace.steps[*].token_text')
        OR jsonb_path_exists(r.trace_summary, '$.detailed_trace.steps[*].top_alternatives[*].token_text')
      );

    DELETE FROM otlet.worker_events e
    USING otlet_cleanup_terminal_candidates c
    WHERE e.job_id = c.id;

    DELETE FROM otlet.eval_labels l
    WHERE EXISTS (
      SELECT 1
      FROM otlet_cleanup_terminal_candidates c
      LEFT JOIN otlet.actions a ON a.job_id = c.id AND a.id = l.action_id
      LEFT JOIN otlet.outputs o ON o.job_id = c.id AND o.id = l.output_id
      LEFT JOIN otlet.inference_receipts r ON r.job_id = c.id AND r.id = l.receipt_id
      WHERE a.id IS NOT NULL OR o.id IS NOT NULL OR r.id IS NOT NULL
    );

    DELETE FROM otlet.semantic_materializations sm
    USING otlet.records record, otlet.actions a, otlet_cleanup_terminal_candidates c
    WHERE sm.record_id = record.id
      AND record.action_id = a.id
      AND a.job_id = c.id;

    UPDATE otlet.records record
    SET subject_id = CASE
          WHEN record.subject_id IS NULL THEN NULL
          ELSE 'retained:' || md5(record.subject_id)
        END,
        body = '{"_otlet_retained":true}'::jsonb
    FROM otlet.actions a, otlet_cleanup_terminal_candidates c
    WHERE record.action_id = a.id
      AND a.job_id = c.id;

    UPDATE otlet.actions a
    SET payload = jsonb_build_object(
          'type', a.action_type,
          '_otlet_retained', true
        ),
        subject_id = CASE
          WHEN a.subject_id IS NULL THEN NULL
          ELSE 'retained:' || md5(a.subject_id)
        END,
        error = NULL,
        review_reason = NULL
    FROM otlet_cleanup_terminal_candidates c
    WHERE a.job_id = c.id;

    UPDATE otlet.outputs o
    SET output = '{"_otlet_retained":true}'::jsonb
    FROM otlet_cleanup_terminal_candidates c
    WHERE o.job_id = c.id;

    UPDATE otlet.inference_receipts r
    SET subject_id = 'retained:' || md5(r.subject_id),
        raw_output = NULL,
        candidate_output = NULL,
        trace_summary = jsonb_build_object(
          'retention_status', 'payload_removed',
          'cleanup_run_id', applied_cleanup_run_id
        ),
        error = NULL
    FROM otlet_cleanup_terminal_candidates c
    WHERE r.job_id = c.id;

    UPDATE otlet.jobs j
    SET subject_id = 'retained:' || md5(j.subject_id),
        input = '{}'::jsonb,
        error = NULL
    FROM otlet_cleanup_terminal_candidates c
    WHERE j.id = c.id;

    UPDATE otlet.cleanup_runs
    SET finished_at = clock_timestamp()
    WHERE id = applied_cleanup_run_id;
  END IF;

  RETURN QUERY SELECT
    worker_count,
    token_count,
    alternative_count,
    eval_count,
    delete_stale_count,
    sensitive_raw_output_count,
    sensitive_chosen_text_count,
    sensitive_token_text_count,
    sensitive_alternative_text_count,
    failed_canceled_job_count,
    terminal_job_count,
    terminal_input_count,
    terminal_output_count,
    terminal_action_count,
    terminal_correction_count,
    terminal_receipt_count,
    terminal_event_count,
    terminal_record_count,
    terminal_materialization_count,
    applied_cleanup_run_id,
    cleanup_policy_state.requested_dry_run;
END;
$$;
