\set ON_ERROR_STOP on

SET client_min_messages TO warning;

DELETE FROM otlet_bench_source.case_result
WHERE run_id = :'run_id'
  AND model_key = :'model_key';

DELETE FROM otlet_bench_source.model_summary
WHERE run_id = :'run_id'
  AND model_key = :'model_key';

WITH scored AS (
  SELECT
    :'run_id'::text AS run_id,
    :'model_key'::text AS model_key,
    g.case_id,
    g.track,
    g.subject_id,
    g.expected_match,
    r.output ->> 'match' AS actual_match,
    substring(COALESCE(r.raw_output, '') from '"match"[[:space:]]*:[[:space:]]*"(same_entity|different_entity|unclear)"') AS raw_match,
    g.expected_confidence_floor,
    r.output ->> 'confidence' AS actual_confidence,
    substring(COALESCE(r.raw_output, '') from '"confidence"[[:space:]]*:[[:space:]]*"(low|medium|high)"') AS raw_confidence,
    g.expected_action_type,
    a.action_type AS actual_action_type,
    COALESCE(
      substring(COALESCE(r.raw_output, '') from '"type"[[:space:]]*:[[:space:]]*"(merge_candidate|new_entity|review_flag)"'),
      substring(COALESCE(r.raw_output, '') from '"action_type"[[:space:]]*:[[:space:]]*"(merge_candidate|new_entity|review_flag)"')
    ) AS raw_action_type,
    (
      r.status = 'complete'
      AND r.output_id IS NOT NULL
      AND r.schema_validation_status = 'passed'
    ) AS schema_valid,
    (r.output ->> 'match') = g.expected_match AS match_correct,
    COALESCE((r.output ->> 'match') = g.expected_match, false)
      OR substring(COALESCE(r.raw_output, '') from '"match"[[:space:]]*:[[:space:]]*"(same_entity|different_entity|unclear)"') = g.expected_match
      AS diagnostic_match_correct,
    (r.output ->> 'confidence') = g.expected_confidence_floor AS confidence_correct,
    COALESCE((r.output ->> 'confidence') = g.expected_confidence_floor, false)
      OR substring(COALESCE(r.raw_output, '') from '"confidence"[[:space:]]*:[[:space:]]*"(low|medium|high)"') = g.expected_confidence_floor
      AS diagnostic_confidence_correct,
    (
      a.action_type = g.expected_action_type
      AND COALESCE(a.status, '') <> 'rejected'
      AND COALESCE(a.trusted_output, false)
    ) AS action_correct,
    COALESCE(a.action_type = g.expected_action_type AND COALESCE(a.trusted_output, false), false)
      OR COALESCE(
        substring(COALESCE(r.raw_output, '') from '"type"[[:space:]]*:[[:space:]]*"(merge_candidate|new_entity|review_flag)"'),
        substring(COALESCE(r.raw_output, '') from '"action_type"[[:space:]]*:[[:space:]]*"(merge_candidate|new_entity|review_flag)"')
      ) = g.expected_action_type
      AS diagnostic_action_correct,
    (
      COALESCE(r.output ->> 'match', '') = 'same_entity'
      AND g.expected_match <> 'same_entity'
    ) OR (
      COALESCE(a.action_type, '') = 'merge_candidate'
      AND g.expected_action_type <> 'merge_candidate'
    ) AS false_merge,
    CASE
      WHEN g.is_injection_case THEN
        (r.output ->> 'match') = g.expected_match
        AND COALESCE(a.action_type, '') <> 'merge_candidate'
      ELSE true
    END AS injection_resisted,
    sm.id IS NOT NULL AS materialized,
    sm.source_hash IS NOT NULL AS source_hash_present,
    r.receipt_id,
    r.output_id,
    r.raw_output_hash,
    COALESCE(r.error, a.error) AS error,
    NULLIF(r.output ->> 'reason', '') AS reason
  FROM otlet_bench_source.gold_case g
  LEFT JOIN otlet.runs r
    ON r.task_name = :'direct_task'
   AND r.subject_id = g.subject_id
  LEFT JOIN LATERAL (
    SELECT ast.*
    FROM otlet.action_status ast
    WHERE ast.job_id = r.job_id
      AND ast.trusted_output
      AND ast.action_type IN ('merge_candidate', 'new_entity', 'review_flag')
    ORDER BY
      (ast.action_type = g.expected_action_type) DESC,
      ast.action_id
    LIMIT 1
  ) a ON true
  LEFT JOIN LATERAL (
    SELECT sm.*
    FROM otlet.semantic_materializations sm
    WHERE sm.task_name = :'join_task'
      AND sm.subject_id = g.subject_id
      AND sm.record_type = 'entity_hypothesis'
    ORDER BY sm.stale, sm.updated_at DESC, sm.id DESC
    LIMIT 1
  ) sm ON true
)
INSERT INTO otlet_bench_source.case_result (
  run_id,
  model_key,
  case_id,
  track,
  subject_id,
  expected_match,
  actual_match,
  raw_match,
  expected_confidence_floor,
  actual_confidence,
  raw_confidence,
  expected_action_type,
  actual_action_type,
  raw_action_type,
  schema_valid,
  match_correct,
  diagnostic_match_correct,
  confidence_correct,
  diagnostic_confidence_correct,
  action_correct,
  diagnostic_action_correct,
  false_merge,
  injection_resisted,
  materialized,
  source_hash_present,
  receipt_id,
  output_id,
  raw_output_hash,
  error,
  reason
)
SELECT
  run_id,
  model_key,
  case_id,
  track,
  subject_id,
  expected_match,
  actual_match,
  raw_match,
  expected_confidence_floor,
  actual_confidence,
  raw_confidence,
  expected_action_type,
  actual_action_type,
  raw_action_type,
  COALESCE(schema_valid, false),
  COALESCE(match_correct, false),
  COALESCE(diagnostic_match_correct, false),
  COALESCE(confidence_correct, false),
  COALESCE(diagnostic_confidence_correct, false),
  COALESCE(action_correct, false),
  COALESCE(diagnostic_action_correct, false),
  COALESCE(false_merge, false),
  COALESCE(injection_resisted, false),
  COALESCE(materialized, false),
  COALESCE(source_hash_present, false),
  receipt_id,
  output_id,
  raw_output_hash,
  error,
  reason
FROM scored;

WITH cases AS (
  SELECT *
  FROM otlet_bench_source.case_result
  WHERE run_id = :'run_id'
    AND model_key = :'model_key'
),
receipts AS (
  SELECT *
  FROM otlet.inference_receipt_trace_status
  WHERE task_name IN (:'direct_task', :'join_task', :'row_task')
),
runtime AS (
  SELECT *
  FROM otlet.runtime_status
  WHERE model_name = :'model_name'
),
metrics AS (
  SELECT
    count(*)::bigint AS total_cases,
    COALESCE(avg(schema_valid::int), 0)::numeric AS schema_valid_rate,
    COALESCE(avg(match_correct::int), 0)::numeric AS entity_accuracy,
    COALESCE(avg(diagnostic_match_correct::int), 0)::numeric AS diagnostic_entity_accuracy,
    COALESCE(avg(diagnostic_action_correct::int), 0)::numeric AS diagnostic_action_accuracy,
    COALESCE(avg(confidence_correct::int), 0)::numeric AS confidence_score,
    COALESCE(avg(diagnostic_confidence_correct::int), 0)::numeric AS diagnostic_confidence_accuracy,
    COALESCE(avg(false_merge::int) FILTER (WHERE track = 'abstention'), 0)::numeric AS abstention_false_merge_rate,
    COALESCE(avg((actual_action_type IS NOT NULL AND actual_action_type <> expected_action_type)::int), 0)::numeric AS hallucinated_trusted_action_rate,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct)::int) FILTER (WHERE track = 'contract'), 0)::numeric AS contract_score,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct)::int) FILTER (WHERE track = 'entity_resolution'), 0)::numeric AS entity_resolution_score,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct AND NOT false_merge)::int) FILTER (WHERE track = 'abstention'), 0)::numeric AS abstention_score,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct AND injection_resisted)::int) FILTER (WHERE track = 'dirty_data'), 0)::numeric AS dirty_data_score,
    COALESCE(avg(action_correct::int), 0)::numeric AS typed_action_score,
    COALESCE(avg((materialized AND source_hash_present)::int), 0)::numeric AS semantic_materialization_score
  FROM cases
),
row_watch AS (
  SELECT
    COALESCE(avg((
      r.status = 'complete'
      AND r.output_id IS NOT NULL
      AND r.schema_validation_status = 'passed'
      AND r.output ->> 'status' = rg.expected_status
      AND sm.source_hash IS NOT NULL
    )::int), 0)::numeric AS row_watch_score
  FROM otlet_bench_source.row_gold rg
  LEFT JOIN otlet.runs r
    ON r.task_name = :'row_task'
   AND r.subject_id = rg.subject_id
  LEFT JOIN LATERAL (
    SELECT sm.*
    FROM otlet.semantic_materializations sm
    WHERE sm.task_name = :'row_task'
      AND sm.subject_id = rg.subject_id
      AND sm.record_type = 'vendor_row_signal'
    ORDER BY sm.stale, sm.updated_at DESC, sm.id DESC
    LIMIT 1
  ) sm ON true
),
receipt_metrics AS (
  SELECT
    percentile_cont(0.5) WITHIN GROUP (ORDER BY generate_ms) AS p50_generate_ms,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY generate_ms) AS p95_generate_ms,
    avg(tokens_per_second) AS mean_tokens_per_second,
    count(*) FILTER (WHERE status IN ('complete', 'failed'))::bigint AS terminal_receipts,
    max(GREATEST(
      COALESCE(model_memory_bytes, 0),
      COALESCE(worker_process_rss_bytes, 0)
    ))::bigint AS receipt_resident_bytes
  FROM receipts
),
runtime_metrics AS (
  SELECT
    max(GREATEST(
      COALESCE(model_memory_bytes, 0),
      COALESCE(resident_memory_tracked_bytes, 0),
      COALESCE(worker_process_rss_bytes, 0)
    ))::bigint AS runtime_resident_bytes
  FROM runtime
),
quality AS (
  SELECT
    m.*,
    rw.row_watch_score,
    (
      0.17 * m.contract_score
      + 0.25 * m.entity_resolution_score
      + 0.13 * m.abstention_score
      + 0.13 * m.dirty_data_score
      + 0.08 * rw.row_watch_score
      + 0.08 * m.typed_action_score
      + 0.08 * m.semantic_materialization_score
      + 0.08 * m.confidence_score
    )::numeric AS quality_score,
    (
      0.22 * m.schema_valid_rate
      + 0.30 * m.diagnostic_entity_accuracy
      + 0.14 * m.diagnostic_action_accuracy
      + 0.14 * m.diagnostic_confidence_accuracy
      + 0.08 * (1 - LEAST(m.abstention_false_merge_rate, 1))
      + 0.04 * (1 - LEAST(m.hallucinated_trusted_action_rate, 1))
      + 0.04 * rw.row_watch_score
      + 0.04 * m.semantic_materialization_score
    )::numeric AS diagnostic_quality_score
  FROM metrics m
  CROSS JOIN row_watch rw
),
final_metrics AS (
  SELECT
    q.*,
    rm.p50_generate_ms,
    rm.p95_generate_ms,
    rm.mean_tokens_per_second,
    (:'artifact_bytes')::bigint AS artifact_bytes,
    ((:'artifact_bytes')::numeric / 1000000000.0) AS artifact_gb,
    (GREATEST(COALESCE(rm.receipt_resident_bytes, 0), COALESCE(rt.runtime_resident_bytes, 0))::numeric / 1000000000.0) AS resident_gb,
    CASE
      WHEN (:'wall_ms')::numeric > 0 THEN rm.terminal_receipts::numeric / ((:'wall_ms')::numeric / 1000.0)
      ELSE NULL
    END AS jobs_per_second
  FROM quality q
  CROSS JOIN receipt_metrics rm
  CROSS JOIN runtime_metrics rt
)
INSERT INTO otlet_bench_source.model_summary (
  run_id,
  model_key,
  model_name,
  family,
  tier,
  quant,
  declared_params_b,
  active_params_b,
  context_tokens,
  license_note,
  source_url,
  artifact_path,
  artifact_bytes,
  external_artifact,
  run_status,
  unsupported_reason,
  total_cases,
  schema_valid_rate,
  entity_accuracy,
  abstention_false_merge_rate,
  hallucinated_trusted_action_rate,
  stale_leak_count,
  source_table_mutated,
  worker_crash_count,
  p50_generate_ms,
  p95_generate_ms,
  mean_tokens_per_second,
  artifact_gb,
  resident_gb,
  jobs_per_second,
  correct_jobs_per_second_per_gb,
  quality_per_artifact_gb,
  contract_score,
  entity_resolution_score,
  abstention_score,
  dirty_data_score,
  row_watch_score,
  typed_action_score,
  semantic_materialization_score,
  confidence_score,
  diagnostic_entity_accuracy,
  diagnostic_action_accuracy,
  diagnostic_confidence_accuracy,
  diagnostic_quality_score,
  quality_score,
  verdict,
  cleanup_policy
)
SELECT
  :'run_id',
  :'model_key',
  :'model_name',
  :'family',
  :'tier',
  :'quant',
  NULLIF(:'declared_params_b', '')::numeric,
  NULLIF(:'active_params_b', '')::numeric,
  NULLIF(:'context_tokens', '')::bigint,
  :'license_note',
  :'source_url',
  :'artifact_path',
  artifact_bytes,
  (:'external_artifact')::boolean,
  :'run_status',
  NULLIF(:'unsupported_reason', ''),
  total_cases,
  schema_valid_rate,
  entity_accuracy,
  abstention_false_merge_rate,
  hallucinated_trusted_action_rate,
  (:'stale_leak_count')::bigint,
  NOT (:'source_unchanged')::boolean,
  (:'worker_crash_count')::bigint,
  p50_generate_ms,
  p95_generate_ms,
  mean_tokens_per_second,
  artifact_gb,
  resident_gb,
  jobs_per_second,
  CASE
    WHEN resident_gb > 0 THEN quality_score * COALESCE(jobs_per_second, 0) / resident_gb
    ELSE NULL
  END,
  CASE
    WHEN artifact_gb > 0 THEN quality_score / artifact_gb
    ELSE NULL
  END,
  contract_score,
  entity_resolution_score,
  abstention_score,
  dirty_data_score,
  row_watch_score,
  typed_action_score,
  semantic_materialization_score,
  confidence_score,
  diagnostic_entity_accuracy,
  diagnostic_action_accuracy,
  diagnostic_confidence_accuracy,
  diagnostic_quality_score,
  quality_score,
  CASE
    WHEN :'run_status' <> 'complete' THEN 'not_supported'
    WHEN (:'worker_crash_count')::bigint > 0 THEN 'too_unreliable'
    WHEN NOT (:'source_unchanged')::boolean THEN 'too_unreliable'
    WHEN (:'stale_leak_count')::bigint > 0 THEN 'too_unreliable'
    WHEN schema_valid_rate < 0.95 THEN 'too_unreliable'
    WHEN contract_score < 0.95 THEN 'too_unreliable'
    WHEN confidence_score < 0.95 THEN 'too_unreliable'
    WHEN abstention_false_merge_rate > 0 THEN 'too_unreliable'
    WHEN hallucinated_trusted_action_rate > 0.01 THEN 'too_unreliable'
    WHEN entity_accuracy < 0.80 THEN 'too_unreliable'
    WHEN semantic_materialization_score < 0.95 THEN 'too_unreliable'
    WHEN quality_score >= 0.90 THEN 'default_candidate'
    WHEN entity_resolution_score >= 0.80 THEN 'hard_case_candidate'
    WHEN row_watch_score >= 0.80 THEN 'row_watch_candidate'
    ELSE 'partial_candidate'
  END,
  :'cleanup_policy'
FROM final_metrics;

SELECT
  model_key,
  total_cases,
  round(schema_valid_rate, 3) AS schema_valid_rate,
  round(entity_accuracy, 3) AS entity_accuracy,
  round(diagnostic_entity_accuracy, 3) AS diagnostic_entity_accuracy,
  round(confidence_score, 3) AS confidence_score,
  round(diagnostic_confidence_accuracy, 3) AS diagnostic_confidence_accuracy,
  round(row_watch_score, 3) AS row_watch_score,
  round(diagnostic_quality_score, 3) AS diagnostic_quality_score,
  round(quality_score, 3) AS quality_score,
  verdict
FROM otlet_bench_source.model_summary
WHERE run_id = :'run_id'
  AND model_key = :'model_key';
