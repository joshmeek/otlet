CREATE VIEW otlet.production_status AS
WITH queue AS (
  SELECT
    count(*) FILTER (
      WHERE j.status = 'queued'
        AND (
          j.execution_mode = 'evaluation'
          OR j.workload_revision_hash = head.active_workload_revision_hash
        )
    )::bigint AS queued_jobs,
    COALESCE(sum(octet_length(j.input::text)) FILTER (
      WHERE j.status = 'queued'
        AND (
          j.execution_mode = 'evaluation'
          OR j.workload_revision_hash = head.active_workload_revision_hash
        )
    ), 0)::bigint AS queued_input_bytes,
    count(*) FILTER (WHERE j.status = 'running')::bigint AS running_jobs,
    count(*) FILTER (WHERE j.status = 'cancel_requested')::bigint AS cancel_requested_jobs,
    count(*) FILTER (
      WHERE j.status IN ('running', 'cancel_requested')
        AND (j.leased_until IS NULL OR j.leased_until < now())
    )::bigint AS expired_running_jobs,
    count(*) FILTER (
      WHERE j.status = 'failed' AND j.execution_mode = 'production'
    )::bigint AS failed_jobs,
    count(*) FILTER (
      WHERE j.status = 'canceled' AND j.execution_mode = 'production'
    )::bigint AS canceled_jobs,
    count(*) FILTER (
      WHERE j.status = 'queued'
        AND j.execution_mode = 'production'
        AND j.workload_revision_hash IS DISTINCT FROM head.active_workload_revision_hash
    )::bigint AS suspended_revision_queued_jobs
  FROM otlet.jobs j
  LEFT JOIN otlet.workload_revision_heads head ON head.task_name = j.task_name
),
receipts AS (
  SELECT
    count(*)::bigint AS receipt_count,
    count(*) FILTER (WHERE receipt.status IN ('complete', 'failed'))::bigint AS model_invocations,
    COALESCE(sum(
      COALESCE(receipt.prompt_tokens, 0) + COALESCE(receipt.generated_tokens, 0)
    ) FILTER (WHERE receipt.status IN ('complete', 'failed')), 0)::bigint AS model_processed_tokens,
    count(*) FILTER (WHERE receipt.status = 'failed')::bigint AS failed_receipts,
    count(*) FILTER (WHERE receipt.schema_validation_status = 'passed')::bigint AS schema_passed_receipts,
    count(*) FILTER (WHERE receipt.schema_validation_status = 'failed')::bigint AS schema_failed_receipts,
    count(*) FILTER (
      WHERE receipt.schema_validation_status IS DISTINCT FROM 'passed'
        AND receipt.status = 'complete'
    )::bigint AS complete_without_schema_pass
  FROM otlet.inference_receipts receipt
  JOIN otlet.jobs job ON job.id = receipt.job_id
  WHERE job.execution_mode = 'production'
),
trusted_output_rows AS (
  SELECT count(*)::bigint AS trusted_output_rows
  FROM otlet.outputs output
  JOIN otlet.jobs job ON job.id = output.job_id
  WHERE job.execution_mode = 'production'
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
    count(*)::bigint AS trace_receipt_count,
    count(*) FILTER (
      WHERE receipt.trace_summary #>> '{detailed_trace,status}' = 'available'
        AND receipt.trace_summary #>> '{detailed_trace,trace_contract}' =
          'receipt_trace_v2_bounded_token_steps'
    )::bigint AS detailed_trace_receipts,
    COALESCE(max(CASE
      WHEN jsonb_typeof(receipt.trace_summary #> '{detailed_trace,captured_tokens}') = 'number'
        THEN (receipt.trace_summary #>> '{detailed_trace,captured_tokens}')::bigint
    END), 0)::bigint AS max_detailed_trace_tokens,
    COALESCE(max(CASE
      WHEN jsonb_typeof(receipt.trace_summary #> '{detailed_trace,top_k}') = 'number'
        THEN (receipt.trace_summary #>> '{detailed_trace,top_k}')::bigint
    END), 0)::bigint AS max_detailed_trace_top_k
  FROM otlet.inference_receipts receipt
  JOIN otlet.jobs job ON job.id = receipt.job_id
  WHERE job.execution_mode = 'production'
),
materialization_failures AS (
  SELECT
    count(*)::bigint AS semantic_materialization_failed_events,
    max(created_at) AS semantic_materialization_last_failed_at
  FROM otlet.worker_events
  WHERE event_type = 'semantic_materialization_failed'
),
action_execution AS (
  SELECT
    count(*) FILTER (WHERE mode = 'apply' AND status = 'applied')::bigint AS applied_actions,
    count(*) FILTER (WHERE mode = 'apply' AND status = 'replayed')::bigint AS replayed_actions,
    count(*) FILTER (WHERE status = 'failed')::bigint AS failed_action_executions
  FROM otlet.action_execution_receipts
)
SELECT
  p.name AS policy_name,
  p.stale_policy,
  p.max_queued_jobs_per_model,
  p.max_admission_rows,
  p.max_input_bytes_per_job,
  p.max_queued_input_bytes_per_model,
  p.max_queued_input_bytes_total,
  p.max_candidate_query_cost,
  p.candidate_query_statement_timeout_ms,
  p.max_raw_output_bytes,
  p.max_structured_output_bytes,
  p.max_actions_per_job,
  p.max_action_bytes,
  p.max_trace_bytes,
  p.max_error_bytes,
  p.max_event_message_bytes,
  p.max_event_detail_bytes,
  p.max_receipt_bytes,
  p.max_attempts,
  p.max_attempt_ms,
  p.default_runtime_options,
  p.semantic_auto_wait_ms,
  p.semantic_auto_infer_ms,
  p.semantic_auto_max_rows,
  p.worker_claim_batch_size,
  p.job_lease_interval,
  q.queued_jobs,
  q.queued_input_bytes,
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
  action_execution.applied_actions,
  action_execution.replayed_actions,
  action_execution.failed_action_executions,
  (q.expired_running_jobs = 0) AS no_expired_running_jobs,
  (r.complete_without_schema_pass = 0) AS complete_receipts_are_schema_validated,
  (s.materializations_without_source_hash = 0) AS materializations_have_source_hashes,
  (COALESCE(runtime.error_runtime_slots, 0) = 0) AS no_runtime_slot_errors,
  (COALESCE(runtime.cache_entries_within_cap, true) AND COALESCE(runtime.cache_bytes_within_cap, true)) AS cache_within_bounds,
  (COALESCE(trace.max_detailed_trace_tokens, 0) <= 256 AND COALESCE(trace.max_detailed_trace_top_k, 0) <= 16) AS trace_within_bounds,
  now() AS checked_at,
  q.suspended_revision_queued_jobs
FROM otlet.production_policy p
CROSS JOIN queue q
CROSS JOIN receipts r
CROSS JOIN trusted_output_rows trusted
CROSS JOIN semantic_state s
CROSS JOIN runtime
CROSS JOIN trace
CROSS JOIN materialization_failures
CROSS JOIN action_execution
WHERE p.name = 'default';
