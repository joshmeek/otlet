CREATE VIEW otlet.production_policy_status AS
SELECT
  p.name,
  p.stale_policy,
  p.max_queued_jobs_per_model,
  p.max_attempts,
  p.max_attempt_ms,
  p.default_runtime_options,
  p.semantic_auto_wait_ms,
  p.semantic_auto_infer_ms,
  p.semantic_auto_max_rows,
  p.worker_claim_batch_size,
  p.worker_claim_task_cursor,
  p.job_lease_interval,
  p.worker_event_retention,
  p.trace_detail_retention,
  p.eval_label_retention,
  p.delete_stale_materialization_retention,
  p.rejected_receipt_raw_output_retention,
  p.failed_job_retention
FROM otlet.production_policy p
WHERE p.name = 'default';

CREATE VIEW otlet.model_queue_status AS
SELECT
  'linked_inproc'::text AS runtime_name,
  m.name AS model_name,
  m.max_active_jobs,
  p.max_queued_jobs_per_model,
  count(j.id) FILTER (WHERE j.status = 'queued')::bigint AS queued_jobs,
  count(j.id) FILTER (WHERE j.status = 'running')::bigint AS running_jobs,
  count(j.id) FILTER (WHERE j.status = 'cancel_requested')::bigint AS cancel_requested_jobs,
  count(j.id) FILTER (
    WHERE j.status IN ('running', 'cancel_requested')
      AND (j.leased_until IS NULL OR j.leased_until < now())
  )::bigint AS expired_running_jobs,
  GREATEST(
    p.max_queued_jobs_per_model::bigint
      - count(j.id) FILTER (WHERE j.status = 'queued'),
    0
  ) AS available_queue_slots,
  CASE
    WHEN count(j.id) FILTER (WHERE j.status = 'queued') >= p.max_queued_jobs_per_model
    THEN 'queue_full'
    ELSE 'queue_accepting'
  END AS queue_state,
  COALESCE(suppressed.suppressed_events, 0)::bigint AS queue_admission_suppressed_events,
  suppressed.last_suppressed_at AS queue_admission_last_suppressed_at
FROM otlet.models m
CROSS JOIN otlet.production_policy p
LEFT JOIN otlet.tasks t ON t.model_name = m.name
LEFT JOIN otlet.jobs j
  ON j.task_name = t.name
 AND j.status IN ('queued', 'running', 'cancel_requested')
LEFT JOIN LATERAL (
  SELECT
    count(*)::bigint AS suppressed_events,
    max(e.created_at) AS last_suppressed_at
  FROM otlet.worker_events e
  WHERE e.event_type = 'queue_admission_suppressed'
    AND e.detail ? 'model_name'
    AND e.detail ->> 'model_name' = m.name
) suppressed ON true
WHERE p.name = 'default'
GROUP BY
  m.name,
  m.max_active_jobs,
  p.max_queued_jobs_per_model,
  suppressed.suppressed_events,
  suppressed.last_suppressed_at;

CREATE VIEW otlet.worker_throughput_status AS
SELECT
  'linked_inproc'::text AS runtime_name,
  m.name AS model_name,
  p.worker_claim_batch_size,
  COALESCE(q.queued_jobs, 0) AS queued_jobs,
  COALESCE(q.running_jobs, 0) AS running_jobs,
  COALESCE(q.cancel_requested_jobs, 0) AS cancel_requested_jobs,
  COALESCE(q.available_queue_slots, 0) AS available_queue_slots,
  COALESCE((last_batch.detail ->> 'job_count')::bigint, 0) AS last_batch_jobs,
  COALESCE((last_batch.detail ->> 'completed_jobs')::bigint, 0) AS last_batch_completed_jobs,
  COALESCE((last_batch.detail ->> 'failed_jobs')::bigint, 0) AS last_batch_failed_jobs,
  COALESCE(last_batch.detail ->> 'task_name', '') AS last_batch_task_name,
  last_batch.created_at AS last_batch_at,
  COALESCE(recent_batches.recent_batch_tasks, '[]'::jsonb) AS recent_batch_tasks
FROM otlet.models m
CROSS JOIN otlet.production_policy p
LEFT JOIN otlet.model_queue_status q ON q.model_name = m.name
LEFT JOIN LATERAL (
  SELECT e.detail, e.created_at
  FROM otlet.worker_events e
  WHERE e.event_type = 'worker_batch_finished'
    AND e.detail ? 'model_name'
    AND e.detail ->> 'model_name' = m.name
  ORDER BY e.created_at DESC, e.id DESC
  LIMIT 1
) last_batch ON true
LEFT JOIN LATERAL (
  SELECT jsonb_agg(
           jsonb_build_object(
             'task_name', recent.task_name,
             'job_count', recent.job_count,
             'completed_jobs', recent.completed_jobs,
             'failed_jobs', recent.failed_jobs
           )
           ORDER BY recent.created_at DESC, recent.id DESC
         ) AS recent_batch_tasks
  FROM (
    SELECT
      e.id,
      e.created_at,
      COALESCE(e.detail ->> 'task_name', '') AS task_name,
      COALESCE((e.detail ->> 'job_count')::bigint, 0) AS job_count,
      COALESCE((e.detail ->> 'completed_jobs')::bigint, 0) AS completed_jobs,
      COALESCE((e.detail ->> 'failed_jobs')::bigint, 0) AS failed_jobs
    FROM otlet.worker_events e
    WHERE e.event_type = 'worker_batch_finished'
      AND e.detail ? 'model_name'
      AND e.detail ->> 'model_name' = m.name
    ORDER BY e.created_at DESC, e.id DESC
    LIMIT 16
  ) recent
) recent_batches ON true
WHERE p.name = 'default'
GROUP BY
  m.name,
  p.worker_claim_batch_size,
  q.queued_jobs,
  q.running_jobs,
  q.cancel_requested_jobs,
  q.available_queue_slots,
  last_batch.detail,
  last_batch.created_at,
  recent_batches.recent_batch_tasks;

CREATE VIEW otlet.model_selection_policy_status AS
SELECT
  p.task_name,
  p.cheap_model_name,
  p.strong_model_name,
  p.accept_field_checks,
  policy.default_runtime_options,
  policy.default_runtime_options || t.runtime_options AS effective_runtime_options,
  CASE
    WHEN (t.runtime_options ->> 'max_attempt_ms') ~ '^[0-9]+$'
    THEN (t.runtime_options ->> 'max_attempt_ms')::integer
    ELSE NULL
  END AS task_max_attempt_ms,
  policy.max_attempt_ms AS policy_max_attempt_ms,
  otlet.effective_task_max_attempt_ms(
    policy.default_runtime_options || t.runtime_options,
    policy.max_attempt_ms
  ) AS effective_max_attempt_ms,
  otlet.effective_job_lease_interval(
    policy.default_runtime_options || t.runtime_options,
    policy.max_attempt_ms,
    policy.job_lease_interval
  ) AS effective_job_lease_interval,
  cheap_q.queue_state AS cheap_queue_state,
  cheap_q.queued_jobs AS cheap_queued_jobs,
  cheap_q.running_jobs AS cheap_running_jobs,
  p.created_at,
  p.updated_at
FROM otlet.model_selection_policies p
JOIN otlet.tasks t ON t.name = p.task_name
CROSS JOIN otlet.production_policy policy
LEFT JOIN otlet.model_queue_status cheap_q ON cheap_q.model_name = p.cheap_model_name
WHERE policy.name = 'default';

CREATE VIEW otlet.model_selection_status AS
WITH job_counts AS (
  SELECT
    j.task_name,
    count(*)::bigint AS total_jobs,
    count(*) FILTER (WHERE j.status = 'complete')::bigint AS complete_jobs,
    count(*) FILTER (WHERE j.status = 'failed')::bigint AS failed_jobs
  FROM otlet.jobs j
  GROUP BY j.task_name
),
attempt_counts AS (
  SELECT
    r.task_name,
    count(*) FILTER (WHERE r.selection_role = 'cheap')::bigint AS cheap_attempts,
    count(*) FILTER (
      WHERE r.selection_role = 'cheap'
        AND r.selection_status = 'accepted'
    )::bigint AS cheap_accepted,
    count(*) FILTER (
      WHERE r.selection_role = 'cheap'
        AND r.selection_status = 'rejected'
    )::bigint AS cheap_rejected,
    count(*) FILTER (
      WHERE r.selection_role = 'cheap'
        AND r.schema_validation_status = 'failed'
    )::bigint AS cheap_schema_failed,
    count(*) FILTER (WHERE r.selection_role = 'strong')::bigint AS strong_attempts,
    count(*) FILTER (
      WHERE r.selection_role = 'strong'
        AND r.selection_status = 'accepted'
    )::bigint AS strong_accepted,
    count(*) FILTER (
      WHERE r.selection_role = 'strong'
        AND r.selection_status = 'failed'
    )::bigint AS strong_failed,
    count(DISTINCT r.job_id) FILTER (WHERE r.selection_role = 'strong')::bigint AS escalated_jobs
  FROM otlet.inference_receipts r
  GROUP BY r.task_name
)
SELECT
  p.task_name,
  COALESCE(j.total_jobs, 0)::bigint AS total_jobs,
  COALESCE(j.complete_jobs, 0)::bigint AS complete_jobs,
  COALESCE(j.failed_jobs, 0)::bigint AS failed_jobs,
  COALESCE(a.cheap_attempts, 0)::bigint AS cheap_attempts,
  COALESCE(a.cheap_accepted, 0)::bigint AS cheap_accepted,
  COALESCE(a.cheap_rejected, 0)::bigint AS cheap_rejected,
  COALESCE(a.cheap_schema_failed, 0)::bigint AS cheap_schema_failed,
  COALESCE(a.strong_attempts, 0)::bigint AS strong_attempts,
  COALESCE(a.strong_accepted, 0)::bigint AS strong_accepted,
  COALESCE(a.strong_failed, 0)::bigint AS strong_failed,
  COALESCE(a.escalated_jobs, 0)::bigint AS escalated_jobs
FROM otlet.model_selection_policies p
LEFT JOIN job_counts j ON j.task_name = p.task_name
LEFT JOIN attempt_counts a ON a.task_name = p.task_name;

CREATE FUNCTION otlet.verify_invariants(sample_limit integer DEFAULT NULL)
RETURNS TABLE (
  invariant_name text,
  object_type text,
  object_id text,
  detail jsonb
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  index_row record;
  join_row record;
  current_contract_hash text;
  bounded_sample_limit integer := NULLIF(GREATEST(COALESCE(sample_limit, 0), 0), 0);
  sample_clause text := '';
  sample_detail jsonb := '{}'::jsonb;
BEGIN
  IF bounded_sample_limit IS NOT NULL THEN
    sample_clause := format('ORDER BY subject_id LIMIT %s', bounded_sample_limit);
    sample_detail := jsonb_build_object(
      'scan_mode',
      'sampled',
      'sample_limit',
      bounded_sample_limit
    );
  END IF;

  RETURN QUERY
  SELECT
    'one_accepted_output_per_job'::text,
    'job'::text,
    o.job_id::text,
    jsonb_build_object('output_count', count(*))
  FROM otlet.outputs o
  GROUP BY o.job_id
  HAVING count(*) > 1;

  RETURN QUERY
  SELECT
    'every_output_has_accepted_receipt'::text,
    'output'::text,
    o.id::text,
    jsonb_build_object(
      'job_id', o.job_id,
      'receipt_id', o.receipt_id,
      'receipt_status', r.status,
      'selection_status', r.selection_status,
      'schema_validation_status', r.schema_validation_status,
      'receipt_job_id', r.job_id,
      'job_status', j.status
    )
  FROM otlet.outputs o
  LEFT JOIN otlet.inference_receipts r ON r.id = o.receipt_id
  LEFT JOIN otlet.jobs j ON j.id = o.job_id
  WHERE r.id IS NULL
     OR r.job_id IS DISTINCT FROM o.job_id
     OR r.status IS DISTINCT FROM 'complete'
     OR r.selection_status IS DISTINCT FROM 'accepted'
     OR r.schema_validation_status IS DISTINCT FROM 'passed'
     OR j.status IS DISTINCT FROM 'complete';

  RETURN QUERY
  SELECT
    'no_action_without_receipt_lineage'::text,
    'action'::text,
    a.id::text,
    jsonb_build_object(
      'job_id', a.job_id,
      'output_id', a.output_id,
      'receipt_id', a.receipt_id,
      'receipt_job_id', r.job_id,
      'output_job_id', o.job_id,
      'output_receipt_id', o.receipt_id
    )
  FROM otlet.actions a
  LEFT JOIN otlet.inference_receipts r ON r.id = a.receipt_id
  LEFT JOIN otlet.outputs o ON o.id = a.output_id
  WHERE a.receipt_id IS NULL
     OR r.id IS NULL
     OR r.job_id IS DISTINCT FROM a.job_id
     OR a.output_id IS NULL
     OR o.id IS NULL
     OR o.job_id IS DISTINCT FROM a.job_id
     OR o.receipt_id IS DISTINCT FROM a.receipt_id;

  RETURN QUERY
  SELECT
    'queued_jobs_within_model_cap'::text,
    'model'::text,
    q.model_name::text,
    jsonb_build_object(
      'queued_jobs',
      q.queued_jobs,
      'max_queued_jobs_per_model',
      q.max_queued_jobs_per_model
    )
  FROM (
    SELECT
      m.name AS model_name,
      count(j.id)::bigint AS queued_jobs,
      p.max_queued_jobs_per_model
    FROM otlet.production_policy p
    JOIN otlet.models m ON true
    LEFT JOIN otlet.tasks t ON t.model_name = m.name
    LEFT JOIN otlet.jobs j ON j.task_name = t.name AND j.status = 'queued'
    GROUP BY m.name, p.max_queued_jobs_per_model
  ) q
  WHERE q.queued_jobs > q.max_queued_jobs_per_model;

  RETURN QUERY
  SELECT
    'no_applied_action_without_approval'::text,
    'action'::text,
    a.id::text,
    jsonb_build_object(
      'action_type', a.action_type,
      'status', a.status,
      'approval_status', a.approval_status,
      'apply_status', a.apply_status
    )
  FROM otlet.actions a
  WHERE a.apply_status = 'applied'
    AND a.approval_status IS DISTINCT FROM 'approved';

  RETURN QUERY
  SELECT
    'no_expired_running_jobs'::text,
    'job'::text,
    j.id::text,
    jsonb_build_object(
      'status', j.status,
      'leased_until', j.leased_until,
      'attempts', j.attempts
    )
  FROM otlet.jobs j
  WHERE j.status IN ('running', 'cancel_requested')
    AND (j.leased_until IS NULL OR j.leased_until < now());

  RETURN QUERY
  SELECT
    'complete_receipts_are_schema_validated'::text,
    'receipt'::text,
    r.id::text,
    jsonb_build_object(
      'job_id', r.job_id,
      'status', r.status,
      'schema_validation_status', r.schema_validation_status
    )
  FROM otlet.inference_receipts r
  WHERE r.status = 'complete'
    AND r.schema_validation_status IS DISTINCT FROM 'passed';

  RETURN QUERY
  SELECT
    'materializations_have_source_hashes'::text,
    'materialization'::text,
    sm.id::text,
    jsonb_build_object(
      'task_name', sm.task_name,
      'subject_id', sm.subject_id,
      'stale', sm.stale
    )
  FROM otlet.semantic_materializations sm
  WHERE sm.source_hash IS NULL;

  RETURN QUERY
  SELECT
    'no_runtime_slot_errors'::text,
    'runtime'::text,
    rs.model_name::text,
    jsonb_build_object(
      'runtime_status', rs.runtime_status,
      'slot_state', rs.slot_state
    )
  FROM otlet.runtime_status rs
  WHERE rs.runtime_status = 'error'
     OR rs.slot_state = 'error';

  FOR index_row IN
    SELECT
      si.name,
      si.task_name,
      si.source_table,
      si.subject_column,
      si.input_columns,
      si.record_type,
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    FROM otlet.semantic_indexes si
    JOIN otlet.tasks t ON t.name = si.task_name
  LOOP
    current_contract_hash := otlet.task_contract_hash(
      index_row.instruction,
      index_row.output_schema,
      index_row.model_name,
      index_row.runtime_options,
      index_row.input_shaping,
      index_row.decision_contract
    );

    BEGIN
      RETURN QUERY EXECUTE format(
        $sql$
          WITH source_inputs AS (
            SELECT
              (src.%1$I)::text AS subject_id,
              jsonb_build_object(
                '_otlet_mvcc', jsonb_build_object(
                  'table', %2$L,
                  'subject_id', (src.%1$I)::text,
                  'ctid', src.ctid::text,
                  'xmin', src.xmin::text
                ),
                'table', %2$L,
                'row', otlet.semantic_project_row(to_jsonb(src), %6$L::text[])
              ) AS input
            FROM %3$s AS src
          ),
          current_inputs AS (
            SELECT *
            FROM source_inputs
            %11$s
          ),
          current_hashes AS (
            SELECT DISTINCT ON (subject_id)
              subject_id,
              otlet.semantic_content_hash(input, %9$L::jsonb) AS content_hash
            FROM current_inputs
            ORDER BY subject_id, input::text
          )
          SELECT
            'fresh_materialization_content_hash_matches_source'::text,
            'semantic_materialization'::text,
            sm.id::text,
            jsonb_build_object(
              'semantic_index', %8$L,
              'task_name', sm.task_name,
              'record_type', sm.record_type,
              'source_table', sm.source_table,
              'subject_id', sm.subject_id,
              'stored_content_hash', sm.content_hash,
              'current_content_hash', ch.content_hash,
              'stored_contract_hash', sm.contract_hash,
              'current_contract_hash', %7$L
            ) || %10$L::jsonb
          FROM otlet.semantic_materializations sm
          LEFT JOIN current_hashes ch ON ch.subject_id = sm.subject_id
          WHERE sm.task_name = %4$L
            AND sm.record_type = %5$L
            AND sm.source_table = %2$L
            AND sm.stale = false
            AND (
              ch.subject_id IS NULL
              OR sm.content_hash IS DISTINCT FROM ch.content_hash
              OR sm.contract_hash IS DISTINCT FROM %7$L
            )
        $sql$,
        index_row.subject_column,
        index_row.source_table,
        index_row.source_table,
        index_row.task_name,
        index_row.record_type,
        index_row.input_columns,
        current_contract_hash,
        index_row.name,
        index_row.input_shaping,
        sample_detail,
        sample_clause
      );
    EXCEPTION WHEN OTHERS THEN
      RETURN QUERY
      SELECT
        'fresh_materialization_source_query_runs'::text,
        'semantic_index'::text,
        index_row.name::text,
        jsonb_build_object(
          'task_name', index_row.task_name,
          'source_table', index_row.source_table,
          'error', SQLERRM
        ) || sample_detail;
    END;
  END LOOP;

  FOR join_row IN
    SELECT
      sji.name,
      sji.task_name,
      sji.candidate_query,
      sji.record_type,
      sji.max_candidate_rows,
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    FROM otlet.semantic_join_indexes sji
    JOIN otlet.tasks t ON t.name = sji.task_name
  LOOP
    current_contract_hash := otlet.task_contract_hash(
      join_row.instruction,
      join_row.output_schema,
      join_row.model_name,
      join_row.runtime_options,
      join_row.input_shaping,
      join_row.decision_contract
    );

    BEGIN
      RETURN QUERY EXECUTE format(
        $sql$
          WITH source_inputs AS (
            SELECT subject_id, input
            FROM (
              SELECT subject_id::text AS subject_id, input::jsonb AS input
              FROM (%1$s) otlet_join_candidate
              ORDER BY subject_id
              LIMIT %2$s
            ) otlet_join_input
          ),
          current_inputs AS (
            SELECT *
            FROM source_inputs
            %10$s
          ),
          current_hashes AS (
            SELECT DISTINCT ON (subject_id)
              subject_id,
              otlet.semantic_content_hash(input, %8$L::jsonb) AS content_hash
            FROM current_inputs
            ORDER BY subject_id, input::text
          )
          SELECT
            'fresh_materialization_content_hash_matches_source'::text,
            'semantic_materialization'::text,
            sm.id::text,
            jsonb_build_object(
              'semantic_join_index', %6$L,
              'task_name', sm.task_name,
              'record_type', sm.record_type,
              'source_table', sm.source_table,
              'subject_id', sm.subject_id,
              'stored_content_hash', sm.content_hash,
              'current_content_hash', ch.content_hash,
              'stored_contract_hash', sm.contract_hash,
              'current_contract_hash', %5$L
            ) || %9$L::jsonb
          FROM otlet.semantic_materializations sm
          LEFT JOIN current_hashes ch ON ch.subject_id = sm.subject_id
          WHERE sm.task_name = %3$L
            AND sm.record_type = %4$L
            AND sm.source_table = %7$L
            AND sm.stale = false
            AND (
              ch.subject_id IS NULL
              OR sm.content_hash IS DISTINCT FROM ch.content_hash
              OR sm.contract_hash IS DISTINCT FROM %5$L
            )
        $sql$,
        join_row.candidate_query,
        join_row.max_candidate_rows,
        join_row.task_name,
        join_row.record_type,
        current_contract_hash,
        join_row.name,
        'otlet.semantic_join:' || join_row.name,
        join_row.input_shaping,
        sample_detail,
        sample_clause
      );
    EXCEPTION WHEN OTHERS THEN
      RETURN QUERY
      SELECT
        'fresh_materialization_source_query_runs'::text,
        'semantic_join_index'::text,
        join_row.name::text,
        jsonb_build_object(
          'task_name', join_row.task_name,
          'error', SQLERRM
        ) || sample_detail;
    END;
  END LOOP;
END;
$$;

CREATE VIEW otlet.production_status AS
WITH queue AS (
  SELECT
    count(*) FILTER (WHERE status = 'queued')::bigint AS queued_jobs,
    count(*) FILTER (WHERE status = 'running')::bigint AS running_jobs,
    count(*) FILTER (WHERE status = 'cancel_requested')::bigint AS cancel_requested_jobs,
    count(*) FILTER (
      WHERE status IN ('running', 'cancel_requested')
        AND (leased_until IS NULL OR leased_until < now())
    )::bigint AS expired_running_jobs,
    count(*) FILTER (WHERE status = 'failed')::bigint AS failed_jobs,
    count(*) FILTER (WHERE status = 'canceled')::bigint AS canceled_jobs
  FROM otlet.jobs
),
receipts AS (
  SELECT
    count(*)::bigint AS receipt_count,
    count(*) FILTER (WHERE status IN ('complete', 'failed'))::bigint AS model_invocations,
    COALESCE(sum(COALESCE(prompt_tokens, 0) + COALESCE(generated_tokens, 0)) FILTER (WHERE status IN ('complete', 'failed')), 0)::bigint AS model_processed_tokens,
    count(*) FILTER (WHERE status = 'failed')::bigint AS failed_receipts,
    count(*) FILTER (WHERE schema_validation_status = 'passed')::bigint AS schema_passed_receipts,
    count(*) FILTER (WHERE schema_validation_status = 'failed')::bigint AS schema_failed_receipts,
    count(*) FILTER (WHERE schema_validation_status IS DISTINCT FROM 'passed' AND status = 'complete')::bigint AS complete_without_schema_pass
  FROM otlet.inference_receipts
),
trusted_output_rows AS (
  SELECT count(*)::bigint AS trusted_output_rows
  FROM otlet.outputs
),
semantic_state AS (
  SELECT
    count(*)::bigint AS materialization_count,
    count(*) FILTER (WHERE stale)::bigint AS stale_materializations,
    count(*) FILTER (WHERE NOT stale)::bigint AS fresh_materializations,
    count(*) FILTER (WHERE source_hash IS NULL)::bigint AS materializations_without_source_hash
  FROM otlet.semantic_materializations
),
runtime AS (
  SELECT
    count(*) FILTER (WHERE runtime_status = 'ready' AND slot_state = 'ready')::bigint AS ready_runtime_slots,
    count(*) FILTER (WHERE runtime_status = 'error' OR slot_state = 'error')::bigint AS error_runtime_slots,
    bool_and(COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0)) AS cache_entries_within_cap,
    bool_and(COALESCE(inference_cache_bytes, 0) <= COALESCE(inference_cache_max_bytes, 0)) AS cache_bytes_within_cap
  FROM otlet.runtime_status
),
trace AS (
  SELECT
    receipt_count AS trace_receipt_count,
    detailed_trace_receipts,
    max_detailed_trace_tokens,
    max_detailed_trace_top_k
  FROM otlet.inference_visibility_status
),
materialization_failures AS (
  SELECT
    count(*)::bigint AS semantic_materialization_failed_events,
    max(created_at) AS semantic_materialization_last_failed_at
  FROM otlet.worker_events
  WHERE event_type = 'semantic_materialization_failed'
)
SELECT
  p.name AS policy_name,
  p.stale_policy,
  p.max_queued_jobs_per_model,
  p.max_attempts,
  p.max_attempt_ms,
  p.default_runtime_options,
  p.semantic_auto_wait_ms,
  p.semantic_auto_infer_ms,
  p.semantic_auto_max_rows,
  p.worker_claim_batch_size,
  p.job_lease_interval,
  q.queued_jobs,
  q.running_jobs,
  q.cancel_requested_jobs,
  q.expired_running_jobs,
  q.failed_jobs,
  q.canceled_jobs,
  r.receipt_count,
  r.model_invocations,
  trusted.trusted_output_rows,
  CASE
    WHEN trusted.trusted_output_rows > 0 THEN r.model_invocations::numeric / trusted.trusted_output_rows::numeric
    ELSE 0::numeric
  END AS model_invocations_per_trusted_row,
  r.model_processed_tokens,
  CASE
    WHEN trusted.trusted_output_rows > 0 THEN r.model_processed_tokens::numeric / trusted.trusted_output_rows::numeric
    ELSE 0::numeric
  END AS model_processed_tokens_per_trusted_row,
  r.failed_receipts,
  r.schema_passed_receipts,
  r.schema_failed_receipts,
  r.complete_without_schema_pass,
  s.materialization_count,
  s.fresh_materializations,
  s.stale_materializations,
  s.materializations_without_source_hash,
  runtime.ready_runtime_slots,
  runtime.error_runtime_slots,
  COALESCE(runtime.cache_entries_within_cap, true) AS cache_entries_within_cap,
  COALESCE(runtime.cache_bytes_within_cap, true) AS cache_bytes_within_cap,
  trace.trace_receipt_count,
  trace.detailed_trace_receipts,
  trace.max_detailed_trace_tokens,
  trace.max_detailed_trace_top_k,
  materialization_failures.semantic_materialization_failed_events,
  materialization_failures.semantic_materialization_last_failed_at,
  (q.expired_running_jobs = 0) AS no_expired_running_jobs,
  (r.complete_without_schema_pass = 0) AS complete_receipts_are_schema_validated,
  (s.materializations_without_source_hash = 0) AS materializations_have_source_hashes,
  (COALESCE(runtime.error_runtime_slots, 0) = 0) AS no_runtime_slot_errors,
  (COALESCE(runtime.cache_entries_within_cap, true) AND COALESCE(runtime.cache_bytes_within_cap, true)) AS cache_within_bounds,
  (COALESCE(trace.max_detailed_trace_tokens, 0) <= 256 AND COALESCE(trace.max_detailed_trace_top_k, 0) <= 16) AS trace_within_bounds,
  now() AS checked_at
FROM otlet.production_policy p
CROSS JOIN queue q
CROSS JOIN receipts r
CROSS JOIN trusted_output_rows trusted
CROSS JOIN semantic_state s
CROSS JOIN runtime
CROSS JOIN trace
CROSS JOIN materialization_failures
WHERE p.name = 'default';

CREATE FUNCTION otlet.cleanup_policy_state(
  requested_dry_run boolean DEFAULT true
) RETURNS TABLE (
  worker_events bigint,
  token_trace_rows bigint,
  token_alternative_rows bigint,
  eval_labels bigint,
  delete_stale_materializations bigint,
  rejected_receipt_raw_outputs bigint,
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
  rejected_raw_output_retention interval;
  failed_job_retention_interval interval;
  worker_count bigint := 0;
  token_count bigint := 0;
  alternative_count bigint := 0;
  eval_count bigint := 0;
  delete_stale_count bigint := 0;
  rejected_raw_output_count bigint := 0;
  failed_canceled_job_count bigint := 0;
BEGIN
  SELECT
    worker_event_retention,
    trace_detail_retention,
    eval_label_retention,
    delete_stale_materialization_retention,
    rejected_receipt_raw_output_retention,
    failed_job_retention
  INTO
    worker_retention,
    trace_retention,
    eval_retention,
    delete_stale_retention,
    rejected_raw_output_retention,
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

  SELECT count(*)
  INTO rejected_raw_output_count
  FROM otlet.inference_receipts r
  WHERE r.selection_status = 'rejected'
    AND r.raw_output IS NOT NULL
    AND r.finished_at < now() - rejected_raw_output_retention;

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

    DELETE FROM otlet.worker_events e
    USING otlet_cleanup_job_candidates c
    WHERE e.job_id = c.id;

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
          jsonb_set(r.trace_summary, '{detailed_trace,steps}', '[]'::jsonb, true),
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
    SET raw_output = NULL
    WHERE r.selection_status = 'rejected'
      AND r.raw_output IS NOT NULL
      AND r.finished_at < now() - rejected_raw_output_retention;
  END IF;

  RETURN QUERY SELECT
    worker_count,
    token_count,
    alternative_count,
    eval_count,
    delete_stale_count,
    rejected_raw_output_count,
    failed_canceled_job_count,
    cleanup_policy_state.requested_dry_run;
END;
$$;
