CREATE FUNCTION otlet.evaluate_workload(
  evaluation_name text,
  workload_name text,
  baseline_name text,
  candidate_identity jsonb,
  gate_thresholds jsonb DEFAULT '{}'::jsonb
) RETURNS otlet.workload_evaluation_runs
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  allowed_thresholds constant text[] := ARRAY[
    'min_coverage', 'min_quality', 'max_abstention', 'min_action_quality',
    'max_latency_ms', 'max_reviewer_time_ms', 'max_quality_regression',
    'max_abstention_regression', 'max_action_regression',
    'max_latency_regression_ms', 'max_reviewer_time_regression_ms'
  ];
  candidate_model text;
  candidate_prompt text;
  candidate_schema text;
  candidate_runtime text;
  candidate_pack text;
  candidate_pack_version integer;
  pack_digest text;
  pack_gates jsonb;
  threshold_input jsonb;
  thresholds jsonb;
  metrics jsonb;
  gates jsonb;
  aggregate record;
  baseline otlet.workload_evaluation_runs%ROWTYPE;
  quality_regression numeric := 0;
  abstention_regression numeric := 0;
  action_regression numeric := 0;
  latency_regression numeric := 0;
  reviewer_time_regression numeric := 0;
  passed boolean;
  saved otlet.workload_evaluation_runs%ROWTYPE;
  unsupported_key text;
BEGIN
  IF NULLIF(evaluate_workload.evaluation_name, '') IS NULL
     OR evaluate_workload.evaluation_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet evaluation name must use lowercase letters, digits, underscores, or hyphens';
  END IF;
  IF NULLIF(evaluate_workload.workload_name, '') IS NULL THEN
    RAISE EXCEPTION 'otlet workload name is required';
  END IF;
  IF jsonb_typeof(evaluate_workload.candidate_identity) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet candidate identity must be a JSON object';
  END IF;

  candidate_model := NULLIF(candidate_identity ->> 'model_name', '');
  candidate_prompt := NULLIF(candidate_identity ->> 'prompt_version', '');
  candidate_schema := NULLIF(candidate_identity ->> 'schema_version', '');
  candidate_runtime := NULLIF(candidate_identity ->> 'runtime_version', '');
  candidate_pack := NULLIF(candidate_identity ->> 'pack_name', '');
  IF candidate_identity ->> 'pack_version' !~ '^[1-9][0-9]*$' THEN
    RAISE EXCEPTION 'otlet candidate pack_version must be a positive integer';
  END IF;
  candidate_pack_version := (candidate_identity ->> 'pack_version')::integer;
  IF num_nulls(
       candidate_model,
       candidate_prompt,
       candidate_schema,
       candidate_runtime,
       candidate_pack
     ) > 0 THEN
    RAISE EXCEPTION 'otlet candidate identity requires model_name, prompt_version, schema_version, runtime_version, pack_name, and pack_version';
  END IF;

  SELECT version.content_digest, version.definition -> 'evaluation_gates'
  INTO pack_digest, pack_gates
  FROM otlet.watch_pack_versions version
  WHERE version.watch_name = candidate_pack
    AND version.version_number = candidate_pack_version;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet candidate pack %.% does not exist', candidate_pack, candidate_pack_version;
  END IF;

  IF evaluate_workload.baseline_name IS NOT NULL THEN
    SELECT *
    INTO baseline
    FROM otlet.workload_evaluation_runs run
    WHERE run.name = evaluate_workload.baseline_name;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'otlet baseline evaluation % does not exist', evaluate_workload.baseline_name;
    END IF;
    IF baseline.workload_name <> evaluate_workload.workload_name THEN
      RAISE EXCEPTION 'otlet baseline evaluation workload does not match %', evaluate_workload.workload_name;
    END IF;
  END IF;

  IF jsonb_typeof(COALESCE(evaluate_workload.gate_thresholds, '{}'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'otlet evaluation thresholds must be a JSON object';
  END IF;
  threshold_input := COALESCE(pack_gates, '{}'::jsonb)
    || COALESCE(evaluate_workload.gate_thresholds, '{}'::jsonb);
  SELECT key
  INTO unsupported_key
  FROM jsonb_object_keys(threshold_input) key
  WHERE NOT key = ANY(allowed_thresholds)
  ORDER BY key
  LIMIT 1;
  IF unsupported_key IS NOT NULL THEN
    RAISE EXCEPTION 'otlet evaluation threshold % is not supported', unsupported_key;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_each(threshold_input) threshold
    WHERE jsonb_typeof(threshold.value) <> 'number'
  ) THEN
    RAISE EXCEPTION 'otlet evaluation thresholds must be numbers';
  END IF;

  thresholds := jsonb_build_object(
    'min_coverage', COALESCE((threshold_input ->> 'min_coverage')::numeric, 1),
    'min_quality', COALESCE((threshold_input ->> 'min_quality')::numeric, 0),
    'max_abstention', COALESCE((threshold_input ->> 'max_abstention')::numeric, 1),
    'min_action_quality', COALESCE((threshold_input ->> 'min_action_quality')::numeric, 0),
    'max_latency_ms', COALESCE((threshold_input ->> 'max_latency_ms')::numeric, 1000000000000),
    'max_reviewer_time_ms', COALESCE((threshold_input ->> 'max_reviewer_time_ms')::numeric, 1000000000000),
    'max_quality_regression', COALESCE((threshold_input ->> 'max_quality_regression')::numeric, 1),
    'max_abstention_regression', COALESCE((threshold_input ->> 'max_abstention_regression')::numeric, 1),
    'max_action_regression', COALESCE((threshold_input ->> 'max_action_regression')::numeric, 1),
    'max_latency_regression_ms', COALESCE((threshold_input ->> 'max_latency_regression_ms')::numeric, 1000000000000),
    'max_reviewer_time_regression_ms', COALESCE((threshold_input ->> 'max_reviewer_time_regression_ms')::numeric, 1000000000000)
  );
  IF EXISTS (
    SELECT 1
    FROM jsonb_each_text(thresholds) threshold
    WHERE (threshold.key IN ('min_coverage', 'min_quality', 'max_abstention', 'min_action_quality',
                             'max_quality_regression', 'max_abstention_regression', 'max_action_regression')
           AND (threshold.value::numeric < 0 OR threshold.value::numeric > 1))
       OR (threshold.key NOT IN ('min_coverage', 'min_quality', 'max_abstention', 'min_action_quality',
                                 'max_quality_regression', 'max_abstention_regression', 'max_action_regression')
           AND threshold.value::numeric < 0)
  ) THEN
    RAISE EXCEPTION 'otlet evaluation thresholds are outside their supported ranges';
  END IF;

  WITH label_cases AS (
    SELECT
      l.id,
      l.case_weight,
      COALESCE(l.task_name, linked.task_name, linked_job.task_name) AS task_name,
      l.subject_id,
      l.source_hash,
      l.expected_answer,
      l.expected_action_type
    FROM otlet.eval_labels l
    LEFT JOIN otlet.inference_receipts linked ON linked.id = l.receipt_id
    LEFT JOIN otlet.actions linked_action ON linked_action.id = l.action_id
    LEFT JOIN otlet.jobs linked_job ON linked_job.id = COALESCE(linked.job_id, linked_action.job_id)
    WHERE COALESCE(l.workload_name, l.task_name, linked.task_name, linked_job.task_name) = evaluate_workload.workload_name
  ),
  observations AS (
    SELECT
      label.id,
      label.case_weight,
      label.expected_answer,
      label.expected_action_type,
      receipt.id AS receipt_id,
      receipt.generate_ms,
      receipt.finished_at,
      output.output ->> COALESCE(NULLIF(task.decision_contract ->> 'answer_field', ''), 'match') AS observed_answer,
      action.action_type AS observed_action_type,
      review.reviewed_at,
      COALESCE(task.decision_contract -> 'abstain_values', '[]'::jsonb) AS abstain_values
    FROM label_cases label
    LEFT JOIN otlet.tasks task ON task.name = label.task_name
    LEFT JOIN LATERAL (
      SELECT candidate.*
      FROM otlet.inference_receipts candidate
      WHERE candidate.task_name = label.task_name
        AND candidate.subject_id = label.subject_id
        AND candidate.model_name = candidate_model
        AND COALESCE(
          candidate.trace_summary #>> '{runtime_fingerprint,output_contract,prompt_template,hash}',
          candidate.prompt_hash
        ) = candidate_prompt
        AND candidate.output_schema_hash = candidate_schema
        AND candidate.trace_summary ->> 'runtime_fingerprint_hash' = candidate_runtime
        AND candidate.selection_status = 'accepted'
        AND candidate.status = 'complete'
        AND candidate.schema_validation_status = 'passed'
        AND (
          label.source_hash IS NULL
          OR label.source_hash = candidate.trace_summary #>> '{mvcc,source_hash}'
        )
      ORDER BY candidate.finished_at DESC, candidate.id DESC
      LIMIT 1
    ) receipt ON true
    LEFT JOIN otlet.outputs output ON output.receipt_id = receipt.id
    LEFT JOIN LATERAL (
      SELECT candidate_action.action_type
      FROM otlet.actions candidate_action
      WHERE candidate_action.receipt_id = receipt.id
      ORDER BY candidate_action.id
      LIMIT 1
    ) action ON true
    LEFT JOIN LATERAL (
      SELECT event.reviewed_at
      FROM otlet.review_events event
      WHERE event.receipt_id = receipt.id
      ORDER BY event.reviewed_at, event.id
      LIMIT 1
    ) review ON true
  )
  SELECT
    count(*)::bigint AS case_count,
    COALESCE(sum(case_weight), 0)::numeric AS total_weight,
    COALESCE(sum(case_weight) FILTER (WHERE receipt_id IS NOT NULL), 0)
      / NULLIF(sum(case_weight), 0) AS coverage,
    COALESCE(sum(case_weight) FILTER (WHERE observed_answer = expected_answer), 0)
      / NULLIF(sum(case_weight), 0) AS quality,
    COALESCE(sum(case_weight) FILTER (WHERE abstain_values ? observed_answer), 0)
      / NULLIF(sum(case_weight), 0) AS abstention,
    COALESCE(sum(case_weight) FILTER (WHERE observed_action_type = expected_action_type), 0)
      / NULLIF(sum(case_weight), 0) AS action_quality,
    COALESCE(
      sum(case_weight * generate_ms) FILTER (WHERE receipt_id IS NOT NULL AND generate_ms IS NOT NULL)
        / NULLIF(sum(case_weight) FILTER (WHERE receipt_id IS NOT NULL AND generate_ms IS NOT NULL), 0),
      0
    ) AS latency_ms,
    COALESCE(
      sum(case_weight * GREATEST(0, extract(epoch FROM reviewed_at - finished_at) * 1000))
        FILTER (WHERE reviewed_at IS NOT NULL)
        / NULLIF(sum(case_weight) FILTER (WHERE reviewed_at IS NOT NULL), 0),
      0
    ) AS reviewer_time_ms
  INTO aggregate
  FROM observations;

  metrics := jsonb_build_object(
    'case_count', aggregate.case_count,
    'total_weight', aggregate.total_weight,
    'coverage', COALESCE(aggregate.coverage, 0),
    'quality', COALESCE(aggregate.quality, 0),
    'abstention', COALESCE(aggregate.abstention, 0),
    'action_quality', COALESCE(aggregate.action_quality, 0),
    'latency_ms', aggregate.latency_ms,
    'reviewer_time_ms', aggregate.reviewer_time_ms
  );

  IF evaluate_workload.baseline_name IS NOT NULL THEN
    quality_regression := (baseline.metrics ->> 'quality')::numeric - (metrics ->> 'quality')::numeric;
    abstention_regression := (metrics ->> 'abstention')::numeric - (baseline.metrics ->> 'abstention')::numeric;
    action_regression := (baseline.metrics ->> 'action_quality')::numeric - (metrics ->> 'action_quality')::numeric;
    latency_regression := (metrics ->> 'latency_ms')::numeric - (baseline.metrics ->> 'latency_ms')::numeric;
    reviewer_time_regression := (metrics ->> 'reviewer_time_ms')::numeric - (baseline.metrics ->> 'reviewer_time_ms')::numeric;
  END IF;
  metrics := metrics || jsonb_build_object(
    'quality_regression', quality_regression,
    'abstention_regression', abstention_regression,
    'action_regression', action_regression,
    'latency_regression_ms', latency_regression,
    'reviewer_time_regression_ms', reviewer_time_regression
  );

  gates := jsonb_build_object(
    'coverage', (metrics ->> 'coverage')::numeric >= (thresholds ->> 'min_coverage')::numeric,
    'quality', (metrics ->> 'quality')::numeric >= (thresholds ->> 'min_quality')::numeric,
    'abstention', (metrics ->> 'abstention')::numeric <= (thresholds ->> 'max_abstention')::numeric,
    'action_quality', (metrics ->> 'action_quality')::numeric >= (thresholds ->> 'min_action_quality')::numeric,
    'latency', (metrics ->> 'latency_ms')::numeric <= (thresholds ->> 'max_latency_ms')::numeric,
    'reviewer_time', (metrics ->> 'reviewer_time_ms')::numeric <= (thresholds ->> 'max_reviewer_time_ms')::numeric,
    'quality_regression', quality_regression <= (thresholds ->> 'max_quality_regression')::numeric,
    'abstention_regression', abstention_regression <= (thresholds ->> 'max_abstention_regression')::numeric,
    'action_regression', action_regression <= (thresholds ->> 'max_action_regression')::numeric,
    'latency_regression', latency_regression <= (thresholds ->> 'max_latency_regression_ms')::numeric,
    'reviewer_time_regression', reviewer_time_regression <= (thresholds ->> 'max_reviewer_time_regression_ms')::numeric
  );
  SELECT bool_and(value::boolean)
  INTO passed
  FROM jsonb_each_text(gates);

  INSERT INTO otlet.workload_evaluation_runs (
    name,
    workload_name,
    baseline_name,
    identity,
    metrics,
    thresholds,
    gate_results,
    gate_status
  )
  VALUES (
    evaluate_workload.evaluation_name,
    evaluate_workload.workload_name,
    evaluate_workload.baseline_name,
    candidate_identity || jsonb_build_object('pack_digest', pack_digest),
    metrics,
    thresholds,
    gates,
    CASE WHEN passed THEN 'passed' ELSE 'failed' END
  )
  RETURNING * INTO saved;

  RETURN saved;
END;
$$;

CREATE VIEW otlet.workload_evaluation_status AS
SELECT
  run.name,
  run.workload_name,
  run.baseline_name,
  run.identity ->> 'model_name' AS model_name,
  run.identity ->> 'prompt_version' AS prompt_version,
  run.identity ->> 'schema_version' AS schema_version,
  run.identity ->> 'runtime_version' AS runtime_version,
  run.identity ->> 'pack_name' AS pack_name,
  (run.identity ->> 'pack_version')::integer AS pack_version,
  run.identity ->> 'pack_digest' AS pack_digest,
  baseline.identity ->> 'model_name' AS baseline_model_name,
  baseline.identity ->> 'prompt_version' AS baseline_prompt_version,
  baseline.identity ->> 'schema_version' AS baseline_schema_version,
  baseline.identity ->> 'runtime_version' AS baseline_runtime_version,
  baseline.identity ->> 'pack_name' AS baseline_pack_name,
  (baseline.identity ->> 'pack_version')::integer AS baseline_pack_version,
  CASE WHEN baseline.name IS NULL THEN NULL ELSE run.identity ->> 'model_name' IS DISTINCT FROM baseline.identity ->> 'model_name' END AS model_changed,
  CASE WHEN baseline.name IS NULL THEN NULL ELSE run.identity ->> 'prompt_version' IS DISTINCT FROM baseline.identity ->> 'prompt_version' END AS prompt_changed,
  CASE WHEN baseline.name IS NULL THEN NULL ELSE run.identity ->> 'schema_version' IS DISTINCT FROM baseline.identity ->> 'schema_version' END AS schema_changed,
  CASE WHEN baseline.name IS NULL THEN NULL ELSE run.identity ->> 'runtime_version' IS DISTINCT FROM baseline.identity ->> 'runtime_version' END AS runtime_changed,
  CASE WHEN baseline.name IS NULL THEN NULL ELSE (run.identity ->> 'pack_name', run.identity ->> 'pack_version') IS DISTINCT FROM (baseline.identity ->> 'pack_name', baseline.identity ->> 'pack_version') END AS pack_changed,
  (run.metrics ->> 'case_count')::bigint AS case_count,
  (run.metrics ->> 'total_weight')::numeric AS total_weight,
  (run.metrics ->> 'coverage')::numeric AS coverage,
  (run.metrics ->> 'quality')::numeric AS quality,
  (run.metrics ->> 'abstention')::numeric AS abstention,
  (run.metrics ->> 'action_quality')::numeric AS action_quality,
  (run.metrics ->> 'latency_ms')::numeric AS latency_ms,
  (run.metrics ->> 'reviewer_time_ms')::numeric AS reviewer_time_ms,
  (run.metrics ->> 'quality_regression')::numeric AS quality_regression,
  (run.metrics ->> 'abstention_regression')::numeric AS abstention_regression,
  (run.metrics ->> 'action_regression')::numeric AS action_regression,
  (run.metrics ->> 'latency_regression_ms')::numeric AS latency_regression_ms,
  (run.metrics ->> 'reviewer_time_regression_ms')::numeric AS reviewer_time_regression_ms,
  (run.thresholds ->> 'min_coverage')::numeric AS min_coverage,
  (run.thresholds ->> 'min_quality')::numeric AS min_quality,
  (run.thresholds ->> 'max_abstention')::numeric AS max_abstention,
  (run.thresholds ->> 'min_action_quality')::numeric AS min_action_quality,
  (run.thresholds ->> 'max_latency_ms')::numeric AS max_latency_ms,
  (run.thresholds ->> 'max_reviewer_time_ms')::numeric AS max_reviewer_time_ms,
  (run.thresholds ->> 'max_quality_regression')::numeric AS max_quality_regression,
  (run.thresholds ->> 'max_abstention_regression')::numeric AS max_abstention_regression,
  (run.thresholds ->> 'max_action_regression')::numeric AS max_action_regression,
  (run.thresholds ->> 'max_latency_regression_ms')::numeric AS max_latency_regression_ms,
  (run.thresholds ->> 'max_reviewer_time_regression_ms')::numeric AS max_reviewer_time_regression_ms,
  (run.gate_results ->> 'coverage')::boolean AS coverage_passed,
  (run.gate_results ->> 'quality')::boolean AS quality_passed,
  (run.gate_results ->> 'abstention')::boolean AS abstention_passed,
  (run.gate_results ->> 'action_quality')::boolean AS action_quality_passed,
  (run.gate_results ->> 'latency')::boolean AS latency_passed,
  (run.gate_results ->> 'reviewer_time')::boolean AS reviewer_time_passed,
  (run.gate_results ->> 'quality_regression')::boolean AS quality_regression_passed,
  (run.gate_results ->> 'abstention_regression')::boolean AS abstention_regression_passed,
  (run.gate_results ->> 'action_regression')::boolean AS action_regression_passed,
  (run.gate_results ->> 'latency_regression')::boolean AS latency_regression_passed,
  (run.gate_results ->> 'reviewer_time_regression')::boolean AS reviewer_time_regression_passed,
  run.gate_status,
  run.created_at
FROM otlet.workload_evaluation_runs run
LEFT JOIN otlet.workload_evaluation_runs baseline ON baseline.name = run.baseline_name;
