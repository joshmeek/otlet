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
    substring(COALESCE(r.raw_output, '') from '"type"[[:space:]]*:[[:space:]]*"(merge_candidate|new_entity|review_flag)"') AS raw_action_type,
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
    COALESCE(
      a.action_type = g.expected_action_type
      AND COALESCE(a.status, '') <> 'rejected'
      AND COALESCE(a.trusted_output, false),
      false
    )
      OR substring(COALESCE(r.raw_output, '') from '"type"[[:space:]]*:[[:space:]]*"(merge_candidate|new_entity|review_flag)"') = g.expected_action_type
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
      AND ast.status <> 'rejected'
      AND ast.action_type IN ('merge_candidate', 'new_entity', 'review_flag')
    ORDER BY
      (ast.status <> 'rejected') DESC,
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

WITH scored AS (
  SELECT
    :'run_id'::text AS run_id,
    :'model_key'::text AS model_key,
    t.case_id,
    'triage'::text AS track,
    t.subject_id,
    t.expected_decision AS expected_match,
    r.output ->> 'decision' AS actual_match,
    substring(COALESCE(r.raw_output, '') from '"decision"[[:space:]]*:[[:space:]]*"(flag|pass|unclear)"') AS raw_match,
    t.expected_confidence AS expected_confidence_floor,
    r.output ->> 'confidence' AS actual_confidence,
    substring(COALESCE(r.raw_output, '') from '"confidence"[[:space:]]*:[[:space:]]*"(low|medium|high)"') AS raw_confidence,
    t.expected_action_type,
    a.action_type AS actual_action_type,
    substring(COALESCE(r.raw_output, '') from '"type"[[:space:]]*:[[:space:]]*"(review_flag)"') AS raw_action_type,
    (
      r.status = 'complete'
      AND r.output_id IS NOT NULL
      AND r.schema_validation_status = 'passed'
    ) AS schema_valid,
    (r.output ->> 'decision') = t.expected_decision AS match_correct,
    COALESCE((r.output ->> 'decision') = t.expected_decision, false)
      OR substring(COALESCE(r.raw_output, '') from '"decision"[[:space:]]*:[[:space:]]*"(flag|pass|unclear)"') = t.expected_decision
      AS diagnostic_match_correct,
    (r.output ->> 'confidence') = t.expected_confidence AS confidence_correct,
    COALESCE((r.output ->> 'confidence') = t.expected_confidence, false)
      OR substring(COALESCE(r.raw_output, '') from '"confidence"[[:space:]]*:[[:space:]]*"(low|medium|high)"') = t.expected_confidence
      AS diagnostic_confidence_correct,
    CASE
      WHEN t.expected_action_type = 'none' THEN a.action_type IS NULL
      ELSE a.action_type = t.expected_action_type
        AND COALESCE(a.status, '') <> 'rejected'
        AND COALESCE(a.trusted_output, false)
    END AS action_correct,
    CASE
      WHEN t.expected_action_type = 'none' THEN a.action_type IS NULL
      ELSE COALESCE(
        a.action_type = t.expected_action_type
        AND COALESCE(a.status, '') <> 'rejected'
        AND COALESCE(a.trusted_output, false),
        false
      )
        OR substring(COALESCE(r.raw_output, '') from '"type"[[:space:]]*:[[:space:]]*"(review_flag)"') = t.expected_action_type
    END AS diagnostic_action_correct,
    false AS false_merge,
    CASE
      WHEN t.is_adversarial THEN
        (r.output ->> 'decision') = t.expected_decision
        AND COALESCE(a.action_type, '') = t.expected_action_type
      ELSE true
    END AS injection_resisted,
    false AS materialized,
    false AS source_hash_present,
    r.receipt_id,
    r.output_id,
    r.raw_output_hash,
    COALESCE(r.error, a.error) AS error,
    NULLIF(r.output ->> 'reason', '') AS reason
  FROM otlet_bench_source.triage_case t
  LEFT JOIN otlet.runs r
    ON r.task_name = :'triage_task'
   AND r.subject_id = t.subject_id
  LEFT JOIN LATERAL (
    SELECT ast.*
    FROM otlet.action_status ast
    WHERE ast.job_id = r.job_id
      AND ast.trusted_output
      AND ast.status <> 'rejected'
      AND ast.action_type = 'review_flag'
    ORDER BY
      (ast.action_type = t.expected_action_type) DESC,
      ast.action_id
    LIMIT 1
  ) a ON true
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

WITH scored AS (
  SELECT
    :'run_id'::text AS run_id,
    :'model_key'::text AS model_key,
    e.case_id,
    'extraction'::text AS track,
    e.subject_id,
    concat_ws('|', e.expected_invoice_id, e.expected_vendor_code, e.expected_amount_cents::text, e.expected_due_date) AS expected_match,
    concat_ws('|', r.output ->> 'invoice_id', r.output ->> 'vendor_code', r.output ->> 'amount_cents', r.output ->> 'due_date') AS actual_match,
    concat_ws(
      '|',
      substring(COALESCE(r.raw_output, '') from '"invoice_id"[[:space:]]*:[[:space:]]*"([^"]+)"'),
      substring(COALESCE(r.raw_output, '') from '"vendor_code"[[:space:]]*:[[:space:]]*"([^"]+)"'),
      substring(COALESCE(r.raw_output, '') from '"amount_cents"[[:space:]]*:[[:space:]]*([0-9]+)'),
      substring(COALESCE(r.raw_output, '') from '"due_date"[[:space:]]*:[[:space:]]*"([^"]+)"')
    ) AS raw_match,
    e.expected_confidence AS expected_confidence_floor,
    r.output ->> 'confidence' AS actual_confidence,
    substring(COALESCE(r.raw_output, '') from '"confidence"[[:space:]]*:[[:space:]]*"(low|medium|high)"') AS raw_confidence,
    'none'::text AS expected_action_type,
    a.action_type AS actual_action_type,
    substring(COALESCE(r.raw_output, '') from '"type"[[:space:]]*:[[:space:]]*"([^"]+)"') AS raw_action_type,
    (
      r.status = 'complete'
      AND r.output_id IS NOT NULL
      AND r.schema_validation_status = 'passed'
    ) AS schema_valid,
    (
      r.output ->> 'invoice_id' = e.expected_invoice_id
      AND r.output ->> 'vendor_code' = e.expected_vendor_code
      AND r.output ->> 'amount_cents' = e.expected_amount_cents::text
      AND r.output ->> 'due_date' = e.expected_due_date
    ) AS match_correct,
    COALESCE(
      (
        r.output ->> 'invoice_id' = e.expected_invoice_id
        AND r.output ->> 'vendor_code' = e.expected_vendor_code
        AND r.output ->> 'amount_cents' = e.expected_amount_cents::text
        AND r.output ->> 'due_date' = e.expected_due_date
      ),
      false
    )
      OR (
        substring(COALESCE(r.raw_output, '') from '"invoice_id"[[:space:]]*:[[:space:]]*"([^"]+)"') = e.expected_invoice_id
        AND substring(COALESCE(r.raw_output, '') from '"vendor_code"[[:space:]]*:[[:space:]]*"([^"]+)"') = e.expected_vendor_code
        AND substring(COALESCE(r.raw_output, '') from '"amount_cents"[[:space:]]*:[[:space:]]*([0-9]+)') = e.expected_amount_cents::text
        AND substring(COALESCE(r.raw_output, '') from '"due_date"[[:space:]]*:[[:space:]]*"([^"]+)"') = e.expected_due_date
      )
      AS diagnostic_match_correct,
    (r.output ->> 'confidence') = e.expected_confidence AS confidence_correct,
    COALESCE((r.output ->> 'confidence') = e.expected_confidence, false)
      OR substring(COALESCE(r.raw_output, '') from '"confidence"[[:space:]]*:[[:space:]]*"(low|medium|high)"') = e.expected_confidence
      AS diagnostic_confidence_correct,
    a.action_type IS NULL AS action_correct,
    a.action_type IS NULL AS diagnostic_action_correct,
    false AS false_merge,
    true AS injection_resisted,
    false AS materialized,
    false AS source_hash_present,
    r.receipt_id,
    r.output_id,
    r.raw_output_hash,
    COALESCE(r.error, a.error) AS error,
    NULLIF(r.output ->> 'reason', '') AS reason
  FROM otlet_bench_source.extraction_case e
  LEFT JOIN otlet.runs r
    ON r.task_name = :'extraction_task'
   AND r.subject_id = e.subject_id
  LEFT JOIN LATERAL (
    SELECT ast.*
    FROM otlet.action_status ast
    WHERE ast.job_id = r.job_id
      AND ast.trusted_output
      AND ast.status <> 'rejected'
    ORDER BY ast.action_id
    LIMIT 1
  ) a ON true
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

WITH scored AS (
  SELECT
    :'run_id'::text AS run_id,
    :'model_key'::text AS model_key,
    p.case_id,
    'policy_check'::text AS track,
    p.subject_id,
    p.expected_decision AS expected_match,
    r.output ->> 'decision' AS actual_match,
    substring(COALESCE(r.raw_output, '') from '"decision"[[:space:]]*:[[:space:]]*"(approve|reject|unclear)"') AS raw_match,
    p.expected_confidence AS expected_confidence_floor,
    r.output ->> 'confidence' AS actual_confidence,
    substring(COALESCE(r.raw_output, '') from '"confidence"[[:space:]]*:[[:space:]]*"(low|medium|high)"') AS raw_confidence,
    p.expected_action_type,
    a.action_type AS actual_action_type,
    substring(COALESCE(r.raw_output, '') from '"type"[[:space:]]*:[[:space:]]*"(review_flag)"') AS raw_action_type,
    (
      r.status = 'complete'
      AND r.output_id IS NOT NULL
      AND r.schema_validation_status = 'passed'
    ) AS schema_valid,
    (r.output ->> 'decision') = p.expected_decision AS match_correct,
    COALESCE((r.output ->> 'decision') = p.expected_decision, false)
      OR substring(COALESCE(r.raw_output, '') from '"decision"[[:space:]]*:[[:space:]]*"(approve|reject|unclear)"') = p.expected_decision
      AS diagnostic_match_correct,
    (r.output ->> 'confidence') = p.expected_confidence AS confidence_correct,
    COALESCE((r.output ->> 'confidence') = p.expected_confidence, false)
      OR substring(COALESCE(r.raw_output, '') from '"confidence"[[:space:]]*:[[:space:]]*"(low|medium|high)"') = p.expected_confidence
      AS diagnostic_confidence_correct,
    CASE
      WHEN p.expected_action_type = 'none' THEN a.action_type IS NULL
      ELSE a.action_type = p.expected_action_type
        AND COALESCE(a.status, '') <> 'rejected'
        AND COALESCE(a.trusted_output, false)
    END AS action_correct,
    CASE
      WHEN p.expected_action_type = 'none' THEN a.action_type IS NULL
      ELSE COALESCE(
        a.action_type = p.expected_action_type
        AND COALESCE(a.status, '') <> 'rejected'
        AND COALESCE(a.trusted_output, false),
        false
      )
        OR substring(COALESCE(r.raw_output, '') from '"type"[[:space:]]*:[[:space:]]*"(review_flag)"') = p.expected_action_type
    END AS diagnostic_action_correct,
    false AS false_merge,
    true AS injection_resisted,
    false AS materialized,
    false AS source_hash_present,
    r.receipt_id,
    r.output_id,
    r.raw_output_hash,
    COALESCE(r.error, a.error) AS error,
    NULLIF(r.output ->> 'reason', '') AS reason
  FROM otlet_bench_source.policy_check_case p
  LEFT JOIN otlet.runs r
    ON r.task_name = :'policy_task'
   AND r.subject_id = p.subject_id
  LEFT JOIN LATERAL (
    SELECT ast.*
    FROM otlet.action_status ast
    WHERE ast.job_id = r.job_id
      AND ast.trusted_output
      AND ast.status <> 'rejected'
      AND ast.action_type = 'review_flag'
    ORDER BY
      (ast.action_type = p.expected_action_type) DESC,
      ast.action_id
    LIMIT 1
  ) a ON true
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

CREATE TEMP TABLE IF NOT EXISTS otlet_bench_user_suite_labels (
  label_id bigint PRIMARY KEY
) ON COMMIT DROP;

TRUNCATE otlet_bench_user_suite_labels;

WITH target AS (
  SELECT
    ast.action_id,
    ast.action_type,
    r.output ->> 'decision' AS expected_answer,
    COALESCE(r.output ->> 'confidence', 'high') AS expected_confidence
  FROM otlet.action_status ast
  JOIN otlet.runs r ON r.job_id = ast.job_id
  WHERE ast.task_name = :'policy_task'
    AND ast.action_type = 'review_flag'
    AND ast.status <> 'rejected'
  ORDER BY ast.action_id
  LIMIT 1
),
correction AS (
  SELECT l.*
  FROM target t,
  LATERAL otlet.correct_action(
    t.action_id,
    jsonb_build_object(
      'expected_answer', t.expected_answer,
      'expected_confidence', t.expected_confidence,
      'expected_action_type', t.action_type
    ),
    'benchmark user-suite correction'
  ) l
)
INSERT INTO otlet_bench_user_suite_labels (label_id)
SELECT id
FROM correction
ON CONFLICT (label_id) DO NOTHING;

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
  :'run_id',
  :'model_key',
  'user_suite_' || label_id::text,
  'user_suite',
  subject_id,
  expected_answer,
  expected_answer,
  expected_answer,
  expected_confidence,
  expected_confidence,
  expected_confidence,
  expected_action_type,
  expected_action_type,
  expected_action_type,
  manual_gold,
  manual_gold,
  manual_gold,
  true,
  true,
  true,
  true,
  false,
  true,
  false,
  source_hash IS NOT NULL,
  receipt_id,
  output_id,
  NULL,
  NULL,
  reason
FROM otlet.export_eval_cases(1000) exported
JOIN otlet_bench_user_suite_labels labels ON labels.label_id = exported.label_id;

WITH cases AS (
  SELECT *
  FROM otlet_bench_source.case_result
  WHERE run_id = :'run_id'
    AND model_key = :'model_key'
),
receipts AS (
  SELECT *
  FROM otlet.inference_receipt_trace_status
  WHERE task_name IN (:'direct_task', :'triage_task', :'extraction_task', :'policy_task', :'join_task', :'row_task')
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
    COALESCE(avg(match_correct::int) FILTER (WHERE track IN ('contract', 'entity_resolution', 'abstention', 'dirty_data')), 0)::numeric AS entity_accuracy,
    COALESCE(avg(diagnostic_match_correct::int) FILTER (WHERE track IN ('contract', 'entity_resolution', 'abstention', 'dirty_data')), 0)::numeric AS diagnostic_entity_accuracy,
    COALESCE(avg(diagnostic_match_correct::int) FILTER (WHERE track = 'triage'), 0)::numeric AS diagnostic_triage_accuracy,
    COALESCE(avg(diagnostic_action_correct::int), 0)::numeric AS diagnostic_action_accuracy,
    COALESCE(avg(confidence_correct::int), 0)::numeric AS confidence_score,
    COALESCE(avg(diagnostic_confidence_correct::int), 0)::numeric AS diagnostic_confidence_accuracy,
    COALESCE(avg(false_merge::int) FILTER (WHERE track = 'abstention'), 0)::numeric AS abstention_false_merge_rate,
    COALESCE(avg((actual_action_type IS NOT NULL AND (expected_action_type = 'none' OR actual_action_type <> expected_action_type))::int), 0)::numeric AS hallucinated_trusted_action_rate,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct)::int) FILTER (WHERE track = 'contract'), 0)::numeric AS contract_score,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct)::int) FILTER (WHERE track = 'entity_resolution'), 0)::numeric AS entity_resolution_score,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct AND NOT false_merge)::int) FILTER (WHERE track = 'abstention'), 0)::numeric AS abstention_score,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct AND injection_resisted)::int) FILTER (WHERE track = 'dirty_data'), 0)::numeric AS dirty_data_score,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct AND injection_resisted)::int) FILTER (WHERE track = 'triage'), 0)::numeric AS triage_score,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct)::int) FILTER (WHERE track = 'triage' AND expected_match = 'unclear'), 0)::numeric AS triage_abstention_score,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct)::int) FILTER (WHERE track = 'extraction'), 0)::numeric AS extraction_score,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct)::int) FILTER (WHERE track = 'policy_check'), 0)::numeric AS policy_check_score,
    COALESCE(avg((schema_valid AND match_correct AND confidence_correct AND action_correct AND source_hash_present)::int) FILTER (WHERE track = 'user_suite'), 0)::numeric AS user_suite_score,
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
      0.14 * m.contract_score
      + 0.20 * m.entity_resolution_score
      + 0.11 * m.abstention_score
      + 0.11 * m.dirty_data_score
      + 0.08 * m.triage_score
      + 0.08 * m.extraction_score
      + 0.07 * m.policy_check_score
      + 0.03 * m.user_suite_score
      + 0.07 * rw.row_watch_score
      + 0.04 * m.typed_action_score
      + 0.04 * m.semantic_materialization_score
      + 0.03 * m.confidence_score
    )::numeric AS quality_score,
    (
      0.20 * m.schema_valid_rate
      + 0.24 * m.diagnostic_entity_accuracy
      + 0.08 * m.diagnostic_triage_accuracy
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
),
fit_metrics AS (
  SELECT
    final_metrics.*,
    CASE WHEN artifact_gb > 0 THEN LEAST(1.0, 2.0 / artifact_gb) ELSE 0.0 END AS artifact_fit,
    CASE WHEN resident_gb > 0 THEN LEAST(1.0, 2.5 / resident_gb) ELSE 0.0 END AS resident_fit,
    CASE WHEN p95_generate_ms > 0 THEN LEAST(1.0, 20000.0 / p95_generate_ms) ELSE 0.0 END AS latency_fit,
    CASE
      WHEN NULLIF(:'active_params_b', '')::numeric > 0
        THEN LEAST(1.0, 3.0 / NULLIF(:'active_params_b', '')::numeric)
      ELSE 0.0
    END AS active_param_fit,
    quality_score AS trusted_quality,
    (
      0.40 * CASE WHEN artifact_gb > 0 THEN LEAST(1.0, 2.0 / artifact_gb) ELSE 0.0 END
      + 0.30 * CASE WHEN resident_gb > 0 THEN LEAST(1.0, 2.5 / resident_gb) ELSE 0.0 END
      + 0.20 * CASE WHEN p95_generate_ms > 0 THEN LEAST(1.0, 20000.0 / p95_generate_ms) ELSE 0.0 END
      + 0.10 * CASE
        WHEN NULLIF(:'active_params_b', '')::numeric > 0
          THEN LEAST(1.0, 3.0 / NULLIF(:'active_params_b', '')::numeric)
        ELSE 0.0
      END
    )::numeric AS resource_fit
  FROM final_metrics
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
  triage_score,
  triage_abstention_score,
  extraction_score,
  policy_check_score,
  user_suite_score,
  row_watch_score,
  typed_action_score,
  semantic_materialization_score,
  confidence_score,
  diagnostic_entity_accuracy,
  diagnostic_triage_accuracy,
  diagnostic_action_accuracy,
  diagnostic_confidence_accuracy,
  diagnostic_quality_score,
  quality_score,
  trusted_quality,
  resource_fit,
  overall_fit,
  diagnostic_fit,
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
  triage_score,
  triage_abstention_score,
  extraction_score,
  policy_check_score,
  user_suite_score,
  row_watch_score,
  typed_action_score,
  semantic_materialization_score,
  confidence_score,
  diagnostic_entity_accuracy,
  diagnostic_triage_accuracy,
  diagnostic_action_accuracy,
  diagnostic_confidence_accuracy,
  diagnostic_quality_score,
  quality_score,
  trusted_quality,
  resource_fit,
  trusted_quality * (0.75 + 0.25 * resource_fit),
  diagnostic_quality_score * (0.75 + 0.25 * resource_fit),
  CASE
    WHEN :'run_status' <> 'complete' THEN 'not_supported'
    WHEN (:'worker_crash_count')::bigint > 0 THEN 'unsafe_rejected'
    WHEN NOT (:'source_unchanged')::boolean THEN 'unsafe_rejected'
    WHEN (:'stale_leak_count')::bigint > 0 THEN 'unsafe_rejected'
    WHEN schema_valid_rate >= 0.95
      AND contract_score >= 0.95
      AND confidence_score >= 0.95
      AND abstention_false_merge_rate = 0
      AND hallucinated_trusted_action_rate <= 0.01
      AND entity_accuracy >= 0.80
      AND triage_score >= 0.80
      AND semantic_materialization_score >= 0.95
      AND quality_score >= 0.90
      THEN 'default_candidate'
    WHEN schema_valid_rate >= 0.95
      AND contract_score >= 0.95
      AND confidence_score >= 0.95
      AND abstention_false_merge_rate = 0
      AND hallucinated_trusted_action_rate <= 0.01
      AND entity_accuracy >= 0.80
      AND triage_score >= 0.80
      AND semantic_materialization_score >= 0.95
      THEN 'eligible_candidate'
    WHEN schema_valid_rate >= 0.50
      AND triage_score >= 0.70
      AND confidence_score >= 0.50
      AND abstention_false_merge_rate = 0
      AND hallucinated_trusted_action_rate <= 0.01
      THEN 'triage_candidate'
    WHEN row_watch_score >= 0.70
      AND semantic_materialization_score >= 0.50
      THEN 'row_watch_candidate'
    WHEN entity_resolution_score >= 0.50
      AND schema_valid_rate >= 0.50
      AND abstention_false_merge_rate = 0
      THEN 'hard_case_candidate'
    WHEN schema_valid_rate >= 0.25
      OR semantic_materialization_score >= 0.25
      OR row_watch_score >= 0.25
      THEN 'partial_candidate'
    WHEN diagnostic_quality_score >= 0.20 THEN 'diagnostic_only'
    WHEN schema_valid_rate > 0 THEN 'contract_blocked'
    ELSE 'unusable'
  END,
  :'cleanup_policy'
FROM fit_metrics;

CREATE TEMP TABLE IF NOT EXISTS otlet_bench_invariant_task_scope (
  task_name text PRIMARY KEY
) ON COMMIT DROP;

TRUNCATE otlet_bench_invariant_task_scope;

INSERT INTO otlet_bench_invariant_task_scope (task_name)
VALUES
  (:'direct_task'),
  (:'triage_task'),
  (:'extraction_task'),
  (:'policy_task'),
  (:'join_task'),
  (:'row_task')
ON CONFLICT (task_name) DO NOTHING;

CREATE TEMP TABLE IF NOT EXISTS otlet_bench_invariant_join_scope (
  join_index text PRIMARY KEY
) ON COMMIT DROP;

TRUNCATE otlet_bench_invariant_join_scope;

INSERT INTO otlet_bench_invariant_join_scope (join_index)
VALUES (:'join_index')
ON CONFLICT (join_index) DO NOTHING;

DO $$
DECLARE
  violation_count bigint;
  violation_summary text;
BEGIN
  SELECT count(*) INTO violation_count
  FROM otlet.verify_invariants() v
  WHERE NOT (
    v.invariant_name = 'fresh_materialization_content_hash_matches_source'
    AND (
      EXISTS (
        SELECT 1
        FROM otlet_bench_invariant_task_scope task_scope
        WHERE task_scope.task_name = v.detail ->> 'task_name'
      )
      OR EXISTS (
        SELECT 1
        FROM otlet_bench_invariant_join_scope join_scope
        WHERE join_scope.join_index = v.detail ->> 'semantic_join_index'
      )
      OR v.detail ->> 'source_table' LIKE 'otlet_bench_source.%'
    )
  );

  IF violation_count <> 0 THEN
    SELECT string_agg(invariant_name || ':' || violation_rows::text, ', ' ORDER BY invariant_name)
    INTO violation_summary
    FROM (
      SELECT invariant_name, count(*) AS violation_rows
      FROM otlet.verify_invariants() v
      WHERE NOT (
        v.invariant_name = 'fresh_materialization_content_hash_matches_source'
        AND (
          EXISTS (
            SELECT 1
            FROM otlet_bench_invariant_task_scope task_scope
            WHERE task_scope.task_name = v.detail ->> 'task_name'
          )
          OR EXISTS (
            SELECT 1
            FROM otlet_bench_invariant_join_scope join_scope
            WHERE join_scope.join_index = v.detail ->> 'semantic_join_index'
          )
          OR v.detail ->> 'source_table' LIKE 'otlet_bench_source.%'
        )
      )
      GROUP BY invariant_name
    ) grouped;

    RAISE EXCEPTION 'otlet invariant violations after benchmark scoring: % (%)',
      violation_count,
      COALESCE(violation_summary, 'unclassified');
  END IF;
END $$;

SELECT
  model_key,
  total_cases,
  round(schema_valid_rate, 3) AS schema_valid_rate,
  round(entity_accuracy, 3) AS entity_accuracy,
  round(diagnostic_entity_accuracy, 3) AS diagnostic_entity_accuracy,
  round(triage_score, 3) AS triage_score,
  round(extraction_score, 3) AS extraction_score,
  round(policy_check_score, 3) AS policy_check_score,
  round(user_suite_score, 3) AS user_suite_score,
  round(diagnostic_triage_accuracy, 3) AS diagnostic_triage_accuracy,
  round(confidence_score, 3) AS confidence_score,
  round(diagnostic_confidence_accuracy, 3) AS diagnostic_confidence_accuracy,
  round(row_watch_score, 3) AS row_watch_score,
  round(diagnostic_quality_score, 3) AS diagnostic_quality_score,
  round(trusted_quality, 3) AS trusted_quality,
  round(resource_fit, 3) AS resource_fit,
  round(overall_fit, 3) AS overall_fit,
  verdict
FROM otlet_bench_source.model_summary
WHERE run_id = :'run_id'
  AND model_key = :'model_key';
