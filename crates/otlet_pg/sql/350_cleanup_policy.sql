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
BEGIN
  SELECT
    worker_event_retention,
    trace_detail_retention,
    eval_label_retention,
    delete_stale_materialization_retention,
    sensitive_evidence_mode,
    sensitive_evidence_retention,
    failed_job_retention
  INTO
    worker_retention,
    trace_retention,
    eval_retention,
    delete_stale_retention,
    sensitive_mode,
    sensitive_retention,
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
    cleanup_policy_state.requested_dry_run;
END;
$$;
