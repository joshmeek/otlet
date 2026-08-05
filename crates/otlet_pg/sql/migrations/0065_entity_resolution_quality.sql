CREATE OR REPLACE FUNCTION otlet.validate_candidate_set_coverage_contract()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  rule jsonb := NEW.definition #> '{population,rule,candidate_coverage}';
  baseline_definition jsonb;
  candidate_definition jsonb;
BEGIN
  IF rule IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.definition #>> '{population,mode}' IS DISTINCT FROM 'full'
     OR otlet.candidate_set_coverage_rule_valid(rule) IS NOT TRUE THEN
    RAISE EXCEPTION 'otlet candidate-set coverage declaration is invalid';
  END IF;

  SELECT revision.definition
  INTO baseline_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = NEW.task_name
    AND revision.workload_revision_hash =
      NEW.baseline_workload_revision_hash;
  SELECT revision.definition
  INTO candidate_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = NEW.task_name
    AND revision.workload_revision_hash =
      NEW.candidate_workload_revision_hash;

  IF baseline_definition #>> '{source,kind}' IS DISTINCT FROM 'pair'
     OR otlet.candidate_set_coverage_workload_eligible(
       candidate_definition
     ) IS NOT TRUE
     OR NEW.baseline_workload_revision_hash =
       NEW.candidate_workload_revision_hash
     OR (
       NEW.definition #>> '{population,rule,kind}' IS DISTINCT FROM
         'review_economics'
       AND ROW(
         baseline_definition #>> '{source,candidate_query}',
         baseline_definition #>> '{source,max_candidate_rows}',
         baseline_definition #> '{task,decision_contract}',
         baseline_definition #> '{task,output_schema}'
       ) IS NOT DISTINCT FROM ROW(
         candidate_definition #>> '{source,candidate_query}',
         candidate_definition #>> '{source,max_candidate_rows}',
         candidate_definition #> '{task,decision_contract}',
         candidate_definition #> '{task,output_schema}'
       )
     ) THEN
    RAISE EXCEPTION 'otlet candidate-set coverage contract is ineligible';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = NEW.task_name
      AND head.active_workload_revision_hash =
        NEW.baseline_workload_revision_hash
  ) THEN
    RAISE EXCEPTION 'otlet candidate-set coverage baseline is not active';
  END IF;
  RETURN NEW;
END;
$$;

CREATE VIEW otlet.entity_resolution_quality_status AS
WITH compatible AS MATERIALIZED (
  SELECT
    contract.contract_hash,
    contract.task_name,
    contract.baseline_workload_revision_hash,
    contract.candidate_workload_revision_hash,
    contract.definition -> 'observation_window' AS observation_window,
    coverage.report_hash AS candidate_coverage_report_hash,
    coverage.metrics AS candidate_coverage_metrics,
    coverage.gate_passed AS candidate_coverage_gate_passed,
    coverage.positive_label_manifest_hash,
    evaluation.report_hash AS evaluation_report_hash,
    evaluation.run_hash,
    economics.report_hash AS review_economics_report_hash,
    economics.observations,
    NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_contracts successor
      WHERE successor.task_name = contract.task_name
        AND successor.supersedes_contract_hash = contract.contract_hash
    ) AS current_contract,
    COALESCE(
      head.active_workload_revision_hash =
        contract.baseline_workload_revision_hash,
      false
    ) AS active_baseline,
    coverage.positive_label_manifest_hash =
      otlet.candidate_set_positive_manifest_hash(contract.contract_hash)
      AS candidate_label_manifest_current,
    COALESCE(
      otlet.candidate_set_coverage_report_current(coverage.report_hash),
      false
    ) AS candidate_coverage_report_current,
    NOT EXISTS (
      SELECT 1
      FROM otlet.evaluation_executions execution
      JOIN otlet.evaluation_cases evaluation_case
        ON evaluation_case.case_hash = execution.case_hash
      LEFT JOIN otlet.eval_label_quality_status quality
        ON quality.label_id = evaluation_case.label_id
       AND quality.task_name = contract.task_name
       AND quality.qualification_eligible
      WHERE execution.run_hash = evaluation.run_hash
        AND quality.label_id IS NULL
    ) AS evaluation_labels_current
  FROM otlet.workload_acceptance_contracts contract
  JOIN otlet.workload_revisions candidate_revision
    ON candidate_revision.task_name = contract.task_name
   AND candidate_revision.workload_revision_hash =
     contract.candidate_workload_revision_hash
  JOIN otlet.candidate_set_coverage_reports coverage
    ON coverage.contract_hash = contract.contract_hash
   AND coverage.task_name = contract.task_name
   AND coverage.baseline_workload_revision_hash =
     contract.baseline_workload_revision_hash
   AND coverage.candidate_workload_revision_hash =
     contract.candidate_workload_revision_hash
  JOIN otlet.review_economics_reports economics
    ON economics.contract_hash = contract.contract_hash
  JOIN otlet.evaluation_slice_reports evaluation
    ON evaluation.report_hash = economics.evaluation_report_hash
  JOIN otlet.evaluation_runs run
    ON run.run_hash = evaluation.run_hash
   AND run.contract_hash = contract.contract_hash
   AND run.task_name = contract.task_name
   AND run.baseline_workload_revision_hash =
     contract.baseline_workload_revision_hash
   AND run.candidate_workload_revision_hash =
     contract.candidate_workload_revision_hash
  LEFT JOIN otlet.workload_revision_heads head
    ON head.task_name = contract.task_name
  WHERE contract.definition #>> '{population,rule,kind}' = 'review_economics'
    AND jsonb_typeof(
      contract.definition #> '{population,rule,candidate_coverage}'
    ) = 'object'
    AND otlet.candidate_set_coverage_workload_eligible(
      candidate_revision.definition
    )
), candidate_execution AS MATERIALIZED (
  SELECT
    compatible.contract_hash,
    execution.case_hash,
    evaluation_case.expected_answer,
    evaluation_case.expected_action_type,
    result.result_hash IS NOT NULL AS has_result,
    result.decision_diff ->> 'observed_answer' AS observed_answer,
    COALESCE(
      (result.decision_diff ->> 'answer_matches')::boolean,
      false
    ) AS answer_matches,
    COALESCE(
      revision.definition #> '{task,decision_contract,abstain_values}',
      '["unclear"]'::jsonb
    ) AS abstain_values,
    EXISTS (
      SELECT 1
      FROM otlet.inference_receipts receipt
      WHERE receipt.job_id = execution.job_id
    ) AS has_receipt,
    EXISTS (
      SELECT 1
      FROM otlet.inference_receipts receipt
      WHERE receipt.job_id = execution.job_id
        AND receipt.selection_role = 'strong'
    ) AS escalated
  FROM compatible
  JOIN otlet.evaluation_executions execution
    ON execution.run_hash = compatible.run_hash
   AND execution.variant = 'candidate'
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = execution.case_hash
  JOIN otlet.workload_revisions revision
    ON revision.task_name = compatible.task_name
   AND revision.workload_revision_hash = execution.workload_revision_hash
  LEFT JOIN otlet.evaluation_results result
    ON result.run_hash = execution.run_hash
   AND result.case_hash = execution.case_hash
   AND result.variant = execution.variant
), decision_rollup AS (
  SELECT
    compatible.contract_hash,
    count(execution.case_hash)::bigint AS eligible_count,
    count(execution.case_hash) FILTER (
      WHERE NOT execution.abstain_values ? execution.expected_answer
    )::bigint AS classification_eligible_count,
    count(execution.case_hash) FILTER (
      WHERE execution.has_result
        AND NOT execution.abstain_values ? execution.expected_answer
        AND execution.observed_answer IS NOT NULL
        AND NOT execution.abstain_values ? execution.observed_answer
        AND execution.answer_matches
    )::bigint AS classification_numerator,
    count(execution.case_hash) FILTER (
      WHERE execution.has_result
        AND NOT execution.abstain_values ? execution.expected_answer
        AND execution.observed_answer IS NOT NULL
        AND NOT execution.abstain_values ? execution.observed_answer
    )::bigint AS classification_denominator,
    count(execution.case_hash) FILTER (
      WHERE execution.has_result
        AND execution.observed_answer IS NOT NULL
        AND execution.abstain_values ? execution.observed_answer
    )::bigint AS abstention_numerator,
    count(execution.case_hash) FILTER (
      WHERE execution.has_result
        AND execution.observed_answer IS NOT NULL
    )::bigint AS abstention_denominator,
    count(execution.case_hash) FILTER (
      WHERE execution.has_receipt AND execution.escalated
    )::bigint AS escalation_numerator,
    count(execution.case_hash) FILTER (
      WHERE execution.has_receipt
    )::bigint AS escalation_denominator
  FROM compatible
  LEFT JOIN candidate_execution execution
    ON execution.contract_hash = compatible.contract_hash
  GROUP BY compatible.contract_hash
), reviewer_touch AS (
  SELECT
    compatible.contract_hash,
    observation ->> 'case_hash' AS case_hash
  FROM compatible
  JOIN otlet.evaluation_slice_reports evaluation
    ON evaluation.report_hash = compatible.evaluation_report_hash
  CROSS JOIN LATERAL jsonb_array_elements(
    evaluation.definition #> '{reviewer_time,observations}'
  ) observation
  WHERE observation ->> 'variant' = 'candidate'
), reported_outcome AS (
  SELECT
    compatible.contract_hash,
    observation ->> 'case_hash' AS case_hash,
    observation ->> 'reported_disposition' AS disposition,
    (observation ->> 'reported_downstream_success')::boolean
      AS downstream_success
  FROM compatible
  CROSS JOIN LATERAL jsonb_array_elements(compatible.observations) observation
  WHERE observation ->> 'variant' = 'candidate'
), review_rollup AS (
  SELECT
    compatible.contract_hash,
    count(execution.case_hash)::bigint AS eligible_count,
    count(outcome.case_hash) FILTER (
      WHERE touch.case_hash IS NOT NULL
        AND outcome.disposition = 'accepted'
    )::bigint AS agreement_numerator,
    count(outcome.case_hash) FILTER (
      WHERE touch.case_hash IS NOT NULL
        AND outcome.disposition IN ('accepted', 'corrected', 'rejected')
    )::bigint AS review_denominator,
    count(outcome.case_hash) FILTER (
      WHERE touch.case_hash IS NOT NULL
        AND outcome.disposition = 'corrected'
    )::bigint AS correction_numerator
  FROM compatible
  LEFT JOIN candidate_execution execution
    ON execution.contract_hash = compatible.contract_hash
  LEFT JOIN reviewer_touch touch
    ON touch.contract_hash = execution.contract_hash
   AND touch.case_hash = execution.case_hash
  LEFT JOIN reported_outcome outcome
    ON outcome.contract_hash = execution.contract_hash
   AND outcome.case_hash = execution.case_hash
  GROUP BY compatible.contract_hash
), downstream_rollup AS (
  SELECT
    compatible.contract_hash,
    count(execution.case_hash) FILTER (
      WHERE execution.expected_action_type = 'merge_candidate'
    )::bigint AS eligible_count,
    count(outcome.case_hash) FILTER (
      WHERE execution.expected_action_type = 'merge_candidate'
        AND outcome.disposition IN ('accepted', 'corrected')
        AND outcome.downstream_success
    )::bigint AS downstream_numerator,
    count(outcome.case_hash) FILTER (
      WHERE execution.expected_action_type = 'merge_candidate'
        AND outcome.disposition IN ('accepted', 'corrected')
        AND outcome.downstream_success IS NOT NULL
    )::bigint AS downstream_denominator
  FROM compatible
  LEFT JOIN candidate_execution execution
    ON execution.contract_hash = compatible.contract_hash
  LEFT JOIN reported_outcome outcome
    ON outcome.contract_hash = execution.contract_hash
   AND outcome.case_hash = execution.case_hash
  GROUP BY compatible.contract_hash
), metric AS (
  SELECT
    compatible.contract_hash,
    'candidate_recall'::text AS metric,
    (compatible.candidate_coverage_metrics ->> 'positive_pairs')::bigint
      AS eligible_count,
    (compatible.candidate_coverage_metrics ->>
      'positive_pairs_in_bounded_set')::bigint AS numerator,
    (compatible.candidate_coverage_metrics ->> 'positive_pairs')::bigint
      AS denominator,
    'eligible merge-positive labels recorded in the coverage report'::text
      AS denominator_definition,
    'source-bound candidate-set coverage report'::text AS evidence_kind
  FROM compatible
  UNION ALL
  SELECT
    rollup.contract_hash,
    'pair_classification',
    rollup.classification_eligible_count,
    rollup.classification_numerator,
    rollup.classification_denominator,
    'non-abstaining terminal candidate results for non-abstaining gold cases',
    'immutable replay decision evidence'
  FROM decision_rollup rollup
  UNION ALL
  SELECT
    rollup.contract_hash,
    'abstention',
    rollup.eligible_count,
    rollup.abstention_numerator,
    rollup.abstention_denominator,
    'terminal candidate evaluation results with an observed answer',
    'immutable replay decision evidence'
  FROM decision_rollup rollup
  UNION ALL
  SELECT
    rollup.contract_hash,
    'escalation',
    rollup.eligible_count,
    rollup.escalation_numerator,
    rollup.escalation_denominator,
    'candidate evaluation executions with at least one receipt',
    'immutable replay receipt evidence'
  FROM decision_rollup rollup
  UNION ALL
  SELECT
    rollup.contract_hash,
    'reported_reviewer_agreement',
    rollup.eligible_count,
    rollup.agreement_numerator,
    rollup.review_denominator,
    'reviewer-touched accepted, corrected, or rejected candidate outcomes',
    'content-bound reviewer observation and authenticated-role attestation'
  FROM review_rollup rollup
  UNION ALL
  SELECT
    rollup.contract_hash,
    'reported_correction',
    rollup.eligible_count,
    rollup.correction_numerator,
    rollup.review_denominator,
    'reviewer-touched accepted, corrected, or rejected candidate outcomes',
    'content-bound reviewer observation and authenticated-role attestation'
  FROM review_rollup rollup
  UNION ALL
  SELECT
    rollup.contract_hash,
    'reported_downstream_merge_outcome',
    rollup.eligible_count,
    rollup.downstream_numerator,
    rollup.downstream_denominator,
    'reported accepted or corrected merge-positive candidate outcomes',
    'authenticated-role attested external outcome'
  FROM downstream_rollup rollup
)
SELECT
  compatible.contract_hash,
  compatible.task_name,
  compatible.baseline_workload_revision_hash,
  compatible.candidate_workload_revision_hash,
  compatible.observation_window,
  compatible.candidate_coverage_report_hash,
  compatible.evaluation_report_hash,
  compatible.review_economics_report_hash,
  compatible.current_contract,
  compatible.active_baseline,
  compatible.candidate_coverage_gate_passed,
  compatible.candidate_label_manifest_current,
  compatible.candidate_coverage_report_current,
  compatible.evaluation_labels_current,
  metric.metric,
  metric.eligible_count,
  metric.numerator,
  metric.denominator,
  round(
    metric.numerator::numeric / NULLIF(metric.denominator, 0),
    12
  ) AS rate,
  COALESCE(
    metric.denominator > 0
      AND compatible.current_contract
      AND compatible.active_baseline
      AND compatible.candidate_coverage_gate_passed
      AND compatible.candidate_label_manifest_current
      AND compatible.candidate_coverage_report_current
      AND compatible.evaluation_labels_current,
    false
  ) AS evidence_ready,
  metric.denominator_definition,
  metric.evidence_kind,
  true AS non_authoritative
FROM compatible
JOIN metric ON metric.contract_hash = compatible.contract_hash;

REVOKE ALL ON TABLE otlet.entity_resolution_quality_status FROM PUBLIC;
