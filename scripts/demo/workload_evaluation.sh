log "Checking workload evaluation gates"

workload_evaluation_contract="$(psql_exec -qAt -v pack_watch="$row_triage_watch" -v task_name="$row_triage_task" <<'SQL'
BEGIN;

CREATE TEMP TABLE evaluation_pack_v1 AS
SELECT otlet.validate_watch_pack(
  (otlet.export_watch(:'pack_watch') - 'content_digest') || jsonb_build_object(
    'version_metadata', '{"version":"evaluation-v1"}'::jsonb,
    'evaluation_gates', '{
      "min_coverage": 1,
      "min_quality": 1,
      "max_abstention": 0,
      "min_action_quality": 1,
      "max_latency_ms": 150,
      "max_reviewer_time_ms": 30
    }'::jsonb
  )
) AS definition;
CREATE TEMP TABLE evaluation_imported_pack_v1 AS
SELECT * FROM otlet.import_watch((SELECT definition FROM evaluation_pack_v1), true);

CREATE TEMP TABLE evaluation_pack_v2 AS
SELECT otlet.validate_watch_pack(
  (definition - 'content_digest') || jsonb_build_object(
    'instruction', definition ->> 'instruction' || ' Evaluation candidate version',
    'version_metadata', '{"version":"evaluation-v2"}'::jsonb
  )
) AS definition
FROM evaluation_pack_v1;
CREATE TEMP TABLE evaluation_imported_pack_v2 AS
SELECT * FROM otlet.import_watch((SELECT definition FROM evaluation_pack_v2), true);

CREATE TEMP TABLE evaluation_import AS
SELECT otlet.import_eval_cases(jsonb_build_array(
  jsonb_build_object(
    'workload_name', 'weighted_fixture',
    'case_key', 'heavy',
    'case_weight', 2,
    'task_name', :'task_name',
    'source_table', 'public.source_rows_not_exported',
    'subject_id', 'evaluation-heavy',
    'expected_answer', 'flag',
    'expected_confidence', 'high',
    'expected_action_type', 'review_flag',
    'label_source', 'manual_correction'
  ),
  jsonb_build_object(
    'workload_name', 'weighted_fixture',
    'case_key', 'light',
    'case_weight', 1,
    'task_name', :'task_name',
    'source_table', 'public.source_rows_not_exported',
    'subject_id', 'evaluation-light',
    'expected_answer', 'pass',
    'expected_confidence', 'high',
    'expected_action_type', 'note',
    'label_source', 'manual_correction'
  )
)) AS inserted;

CREATE TEMP TABLE evaluation_jobs AS
WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name, subject_id, input, status, attempts, started_at, finished_at
  )
  VALUES
    (:'task_name', 'evaluation-heavy', '{}'::jsonb, 'complete', 1, now() - interval '10 minutes 1 second', now() - interval '10 minutes'),
    (:'task_name', 'evaluation-light', '{}'::jsonb, 'complete', 1, now() - interval '10 minutes 1 second', now() - interval '10 minutes'),
    (:'task_name', 'evaluation-heavy', '{}'::jsonb, 'complete', 1, now() - interval '5 minutes 1 second', now() - interval '5 minutes'),
    (:'task_name', 'evaluation-light', '{}'::jsonb, 'complete', 1, now() - interval '5 minutes 1 second', now() - interval '5 minutes')
  RETURNING id, subject_id, input, started_at, finished_at
)
SELECT
  id,
  subject_id,
  CASE WHEN finished_at < now() - interval '7 minutes' THEN 'baseline' ELSE 'candidate' END AS version,
  started_at,
  finished_at
FROM inserted;

CREATE TEMP TABLE evaluation_receipts AS
WITH inserted AS (
  INSERT INTO otlet.inference_receipts (
    job_id, attempt_index, selection_role, selection_status, task_name, subject_id,
    model_name, model_artifact_path, model_artifact_hash, model_artifact_identity,
    runtime_name, runtime_endpoint, runtime_options, prompt_hash, input_hash,
    output_schema_hash, raw_output_hash, prompt_tokens, generated_tokens,
    generate_ms, schema_validation_status, trace_summary, started_at, finished_at,
    status
  )
  SELECT
    job.id,
    1,
    'direct',
    'accepted',
    :'task_name',
    job.subject_id,
    CASE job.version WHEN 'baseline' THEN 'fixture-model-v1' ELSE 'fixture-model-v2' END,
    '/fixture/model.gguf',
    repeat(CASE job.version WHEN 'baseline' THEN '1' ELSE '2' END, 64),
    '{}'::jsonb,
    CASE job.version WHEN 'baseline' THEN 'fixture-runtime-v1' ELSE 'fixture-runtime-v2' END,
    'local',
    '{}'::jsonb,
    CASE job.version WHEN 'baseline' THEN 'prompt-v1' ELSE 'prompt-v2' END,
    md5(job.subject_id || job.version),
    CASE job.version WHEN 'baseline' THEN 'schema-v1' ELSE 'schema-v2' END,
    md5(job.subject_id || job.version || 'output'),
    10,
    5,
    CASE
      WHEN job.version = 'baseline' AND job.subject_id = 'evaluation-heavy' THEN 100
      WHEN job.version = 'baseline' THEN 200
      WHEN job.subject_id = 'evaluation-heavy' THEN 300
      ELSE 200
    END,
    'passed',
    jsonb_build_object(
      'runtime_fingerprint_hash', CASE job.version WHEN 'baseline' THEN 'runtime-v1' ELSE 'runtime-v2' END
    ),
    job.started_at,
    job.finished_at,
    'complete'
  FROM evaluation_jobs job
  RETURNING *
)
SELECT * FROM inserted;

CREATE TEMP TABLE evaluation_outputs AS
WITH inserted AS (
  INSERT INTO otlet.outputs (job_id, receipt_id, output, created_at)
  SELECT
    receipt.job_id,
    receipt.id,
    jsonb_build_object(
      'decision', CASE
        WHEN receipt.model_name = 'fixture-model-v1' AND receipt.subject_id = 'evaluation-heavy' THEN 'flag'
        WHEN receipt.model_name = 'fixture-model-v1' THEN 'pass'
        WHEN receipt.subject_id = 'evaluation-heavy' THEN 'unclear'
        ELSE 'flag'
      END,
      'confidence', 'high'
    ),
    receipt.finished_at
  FROM evaluation_receipts receipt
  RETURNING *
)
SELECT * FROM inserted;

CREATE TEMP TABLE evaluation_actions AS
WITH inserted AS (
  INSERT INTO otlet.actions (
    job_id, output_id, receipt_id, action_type, authority_origin, authority_mode,
    evaluation_status, authority_policy_hash, subject_namespace, payload, status,
    approval_status, dry_run_status, apply_status, subject_id
  )
  SELECT
    receipt.job_id,
    output.id,
    receipt.id,
    CASE
      WHEN receipt.model_name = 'fixture-model-v1' AND receipt.subject_id = 'evaluation-light' THEN 'note'
      ELSE 'review_flag'
    END,
    'system',
    'recommendation_only',
    'evaluated',
    md5('evaluation-policy'),
    'evaluation_fixture',
    '{}'::jsonb,
    'complete',
    'not_required',
    'not_run',
    'not_applicable',
    receipt.subject_id
  FROM evaluation_receipts receipt
  JOIN evaluation_outputs output ON output.receipt_id = receipt.id
  RETURNING *
)
SELECT * FROM inserted;

INSERT INTO otlet.review_events (
  outcome, reviewer_identity, reviewer_role, reason, job_id, task_name, subject_id,
  action_id, output_id, receipt_id, source_freshness, model_name,
  model_artifact_hash, prompt_hash, output_schema_hash, output_hash,
  runtime_fingerprint_hash, reviewed_at
)
SELECT
  'approve',
  'fixture-reviewer',
  'fixture-role',
  'fixed evaluation review',
  receipt.job_id,
  receipt.task_name,
  receipt.subject_id,
  action.id,
  output.id,
  receipt.id,
  'unavailable',
  receipt.model_name,
  receipt.model_artifact_hash,
  receipt.prompt_hash,
  receipt.output_schema_hash,
  receipt.raw_output_hash,
  receipt.trace_summary ->> 'runtime_fingerprint_hash',
  receipt.finished_at + CASE
    WHEN receipt.model_name = 'fixture-model-v1' AND receipt.subject_id = 'evaluation-heavy' THEN interval '20 milliseconds'
    WHEN receipt.model_name = 'fixture-model-v1' THEN interval '40 milliseconds'
    WHEN receipt.subject_id = 'evaluation-heavy' THEN interval '60 milliseconds'
    ELSE interval '40 milliseconds'
  END
FROM evaluation_receipts receipt
JOIN evaluation_outputs output ON output.receipt_id = receipt.id
JOIN evaluation_actions action ON action.receipt_id = receipt.id;

CREATE TEMP TABLE evaluation_baseline AS
SELECT * FROM otlet.evaluate_workload(
  'weighted_fixture_baseline',
  'weighted_fixture',
  NULL,
  jsonb_build_object(
    'model_name', 'fixture-model-v1',
    'prompt_version', 'prompt-v1',
    'schema_version', 'schema-v1',
    'runtime_version', 'runtime-v1',
    'pack_name', :'pack_watch',
    'pack_version', 1
  )
);

CREATE TEMP TABLE evaluation_candidate AS
SELECT * FROM otlet.evaluate_workload(
  'weighted_fixture_candidate',
  'weighted_fixture',
  'weighted_fixture_baseline',
  jsonb_build_object(
    'model_name', 'fixture-model-v2',
    'prompt_version', 'prompt-v2',
    'schema_version', 'schema-v2',
    'runtime_version', 'runtime-v2',
    'pack_name', :'pack_watch',
    'pack_version', 2
  ),
  '{
    "max_quality_regression": 0.1,
    "max_abstention_regression": 0.1,
    "max_action_regression": 0.1,
    "max_latency_regression_ms": 25,
    "max_reviewer_time_regression_ms": 10
  }'::jsonb
);

CREATE FUNCTION pg_temp.evaluation_history_is_immutable(operation text)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    IF operation = 'update' THEN
      UPDATE otlet.workload_evaluation_runs SET gate_status = 'passed'
      WHERE name = 'weighted_fixture_candidate';
    ELSIF operation = 'delete' THEN
      DELETE FROM otlet.workload_evaluation_runs
      WHERE name = 'weighted_fixture_candidate';
    ELSE
      TRUNCATE otlet.workload_evaluation_runs CASCADE;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RETURN true;
  END;
  RETURN false;
END;
$function$;

SELECT
  ((SELECT inserted FROM evaluation_import) = 2)::text || '|' ||
  (otlet.import_eval_cases(
    COALESCE((SELECT jsonb_agg(to_jsonb(exported)) FROM otlet.export_eval_cases(100) exported WHERE workload_name = 'weighted_fixture'), '[]'::jsonb)
  ) = 0)::text || '|' ||
  (
    SELECT (
      count(*) = 2
      AND sum(case_weight) = 3
      AND bool_and(action_id IS NULL AND output_id IS NULL AND receipt_id IS NULL)
      AND bool_and(NOT to_jsonb(exported) ? 'input')
    )::text
    FROM otlet.export_eval_cases(100) exported
    WHERE workload_name = 'weighted_fixture'
  ) || '|' ||
  (
    SELECT (
      case_count = 2
      AND total_weight = 3
      AND coverage = 1
      AND quality = 1
      AND abstention = 0
      AND action_quality = 1
      AND round(latency_ms, 3) = 133.333
      AND round(reviewer_time_ms, 3) = 26.667
      AND gate_status = 'passed'
    )::text
    FROM otlet.workload_evaluation_status
    WHERE name = 'weighted_fixture_baseline'
  ) || '|' ||
  (
    SELECT (
      coverage = 1
      AND quality = 0
      AND round(abstention, 3) = 0.667
      AND round(action_quality, 3) = 0.667
      AND round(latency_ms, 3) = 266.667
      AND round(reviewer_time_ms, 3) = 53.333
      AND quality_regression = 1
      AND round(abstention_regression, 3) = 0.667
      AND round(action_regression, 3) = 0.333
      AND round(latency_regression_ms, 3) = 133.333
      AND round(reviewer_time_regression_ms, 3) = 26.667
      AND gate_status = 'failed'
    )::text
    FROM otlet.workload_evaluation_status
    WHERE name = 'weighted_fixture_candidate'
  ) || '|' ||
  (
    SELECT (
      model_changed AND prompt_changed AND schema_changed AND runtime_changed AND pack_changed
      AND coverage_passed
      AND NOT quality_passed
      AND NOT abstention_passed
      AND NOT action_quality_passed
      AND NOT latency_passed
      AND NOT reviewer_time_passed
      AND NOT quality_regression_passed
      AND NOT abstention_regression_passed
      AND NOT action_regression_passed
      AND NOT latency_regression_passed
      AND NOT reviewer_time_regression_passed
    )::text
    FROM otlet.workload_evaluation_status
    WHERE name = 'weighted_fixture_candidate'
  ) || '|' ||
  pg_temp.evaluation_history_is_immutable('update')::text || '|' ||
  pg_temp.evaluation_history_is_immutable('delete')::text || '|' ||
  pg_temp.evaluation_history_is_immutable('truncate')::text;
ROLLBACK;
SQL
)"

echo "workload_evaluation_contract=$workload_evaluation_contract"
[ "$workload_evaluation_contract" = "true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected portable labels, weighted metrics, named baseline comparisons, explicit gates, and immutable runs, got $workload_evaluation_contract" >&2
  exit 1
}
