SET LOCAL statement_timeout = 0;

CREATE TEMP TABLE entity_resolution_quality_proof (
  contract_hash text,
  candidate_workload_revision_hash text,
  run_hash text,
  evaluation_report_hash text,
  candidate_coverage_report_hash text,
  review_economics_report_hash text,
  cheap_model_name text NOT NULL,
  strong_model_name text NOT NULL,
  reviewer_time jsonb,
  observations jsonb
) ON COMMIT DROP;
INSERT INTO entity_resolution_quality_proof (
  cheap_model_name,
  strong_model_name
) VALUES (
  :'cheap_model_name',
  :'strong_model_name'
);

DO $body$
DECLARE
  proof candidate_set_coverage_proof%ROWTYPE;
  action_row record;
  label_id bigint;
BEGIN
  SELECT * INTO proof FROM candidate_set_coverage_proof;
  FOR action_row IN
    SELECT action.id, job.subject_id
    FROM otlet.actions action
    JOIN otlet.jobs job ON job.id = action.job_id
    WHERE job.task_name = proof.task_name
      AND job.subject_id IN (
        'vendor-1001:vendor-77',
        'vendor-1001:vendor-314'
      )
      AND action.action_type = 'new_entity'
    ORDER BY job.subject_id, job.id DESC, action.id DESC
  LOOP
    SELECT label.id
    INTO label_id
    FROM otlet.label_action(
      action_row.id,
      CASE action_row.subject_id
        WHEN 'vendor-1001:vendor-314' THEN 'unclear'
        ELSE 'different_entity'
      END,
      'high',
      CASE action_row.subject_id
        WHEN 'vendor-1001:vendor-314' THEN 'review_flag'
        ELSE 'new_entity'
      END,
      'Entity-resolution quality negative',
      'manual_correction'
    ) label;
    PERFORM otlet.adjudicate_eval_label(
      label_id,
      'accepted',
      1,
      'Accept entity-resolution quality negative'
    );
  END LOOP;

  IF (
    SELECT count(*)
    FROM otlet.eval_label_quality_status quality
    WHERE quality.task_name = proof.task_name
      AND quality.qualification_eligible
      AND quality.expected_action_type IN (
        'merge_candidate', 'new_entity', 'review_flag'
      )
  ) <> 4 THEN
    RAISE EXCEPTION 'entity-resolution quality labels are incomplete';
  END IF;
END
$body$;

DO $body$
DECLARE
  proof candidate_set_coverage_proof%ROWTYPE;
  quality_thresholds jsonb;
  eligible_members jsonb;
  coverage_rule jsonb;
  starts_at timestamptz;
  label_row record;
BEGIN
  SELECT * INTO proof FROM candidate_set_coverage_proof;
  UPDATE entity_resolution_quality_proof
  SET candidate_workload_revision_hash =
    pg_temp.candidate_set_coverage_revision(
      proof.good_hash,
      instruction_suffix => ' Entity-resolution quality candidate.'
    );
  FOR label_row IN
    SELECT quality.label_id
    FROM otlet.eval_label_quality_status quality
    WHERE quality.task_name = proof.task_name
      AND quality.qualification_eligible
      AND quality.expected_action_type IN (
        'merge_candidate', 'new_entity', 'review_flag'
      )
    ORDER BY quality.label_id
  LOOP
    PERFORM otlet.register_evaluation_case(
      label_row.label_id,
      'shadow',
      'Approved entity-resolution quality case'
    );
  END LOOP;

  SELECT jsonb_agg(jsonb_build_object(
    'lineage_hash', evaluation_case.lineage_hash,
    'case_hash', evaluation_case.case_hash,
    'included', true
  ) ORDER BY evaluation_case.lineage_hash)
  INTO eligible_members
  FROM otlet.evaluation_cases evaluation_case
  JOIN otlet.eval_labels label ON label.id = evaluation_case.label_id
  JOIN otlet.eval_label_quality_status quality ON quality.label_id = label.id
  WHERE quality.task_name = proof.task_name
    AND quality.qualification_eligible
    AND quality.expected_action_type IN (
      'merge_candidate', 'new_entity', 'review_flag'
    );

  SELECT jsonb_object_agg(
    category,
    jsonb_build_object(
      'metric', CASE category
        WHEN 'candidate_recall' THEN 'quality'
        WHEN 'false_trust' THEN 'false_trust'
        WHEN 'abstention' THEN 'abstention'
        WHEN 'review_minutes' THEN 'reviewer_seconds'
        WHEN 'latency' THEN 'latency_ms'
        WHEN 'database_impact' THEN 'memory_bytes'
        WHEN 'recovery' THEN 'escalation'
        ELSE category
      END,
      'statistic', CASE category
        WHEN 'review_minutes' THEN 'mean'
        WHEN 'latency' THEN 'mean'
        WHEN 'database_impact' THEN 'max'
        ELSE 'rate'
      END,
      'operator', CASE WHEN category IN (
        'candidate_recall', 'downstream_outcome'
      ) THEN 'gte' ELSE 'lte' END,
      'value', CASE WHEN category IN (
        'candidate_recall', 'downstream_outcome'
      ) THEN 0.8 ELSE 0.2 END,
      'unit', CASE category
        WHEN 'review_minutes' THEN 'seconds'
        WHEN 'latency' THEN 'milliseconds'
        WHEN 'database_impact' THEN 'bytes'
        ELSE 'ratio'
      END,
      'minimum_support', 1,
      'required', true
    )
  )
  INTO quality_thresholds
  FROM unnest(ARRAY[
    'candidate_recall', 'false_trust', 'abstention', 'review_age',
    'review_minutes', 'freshness', 'latency', 'database_impact',
    'unit_cost', 'recovery', 'downstream_outcome'
  ]) category;

  coverage_rule := otlet.build_candidate_set_coverage_rule(
    pg_temp.candidate_set_coverage_query('good'),
    ARRAY['_otlet_mvcc', 'source'],
    2,
    1,
    1,
    1,
    0,
    0.4
  );
  starts_at := clock_timestamp() + interval '200 milliseconds';
  UPDATE entity_resolution_quality_proof
  SET contract_hash = otlet.register_workload_acceptance_contract(
    proof.task_name,
    (
      SELECT candidate_workload_revision_hash
      FROM entity_resolution_quality_proof
    ),
    proof.good_hash,
    jsonb_build_object(
      'mode', 'full',
      'rule', jsonb_build_object(
        'kind', 'review_economics',
        'eligible_members', eligible_members,
        'candidate_coverage', coverage_rule
      )
    ),
    starts_at,
    starts_at + interval '10 seconds',
    '{
      "name":"paired_entity_resolution_quality",
      "definition":{
        "format":"otlet.review_economics.v1",
        "cost_unit":"USD",
        "reviewer_cost_per_hour":60,
        "model_generation_cost_per_hour":60,
        "minimum_support":1
      }
    }'::jsonb,
    quality_thresholds,
    proof.decision_contract_hash
  );
END
$body$;

SELECT pg_sleep(GREATEST(
  0,
  extract(epoch FROM (
    (
      SELECT contract.definition #>> '{observation_window,starts_at}'
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.contract_hash = (
        SELECT contract_hash FROM entity_resolution_quality_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.02
)::double precision) \g /dev/null

UPDATE entity_resolution_quality_proof proof
SET run_hash = otlet.start_replay_evaluation(
  proof.contract_hash,
  ARRAY(
    SELECT member ->> 'case_hash'
    FROM otlet.workload_acceptance_contracts contract
    CROSS JOIN LATERAL jsonb_array_elements(
      contract.definition #> '{population,rule,eligible_members}'
    ) member
    WHERE contract.contract_hash = proof.contract_hash
    ORDER BY member ->> 'case_hash'
  ),
  'entity-resolution-quality-v1',
  'Measure the decomposed entity-resolution workflow'
);

UPDATE otlet.jobs job
SET status = 'running',
    attempts = 1,
    started_at = clock_timestamp(),
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
FROM otlet.evaluation_executions execution
WHERE execution.run_hash = (
    SELECT run_hash FROM entity_resolution_quality_proof
  )
  AND execution.job_id = job.id;

CREATE FUNCTION pg_temp.complete_entity_quality_run(
  target_run_hash text,
  cheap_model text,
  strong_model text,
  varied_candidate boolean
) RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
  execution record;
  answer text;
  output jsonb;
  actions jsonb;
  action_body jsonb;
  selection_role text;
BEGIN
  FOR execution IN
    SELECT
      evaluation_execution.*,
      evaluation_case.subject_id,
      evaluation_case.expected_answer,
      job.input,
      job.claim_token,
      job.started_at
    FROM otlet.evaluation_executions evaluation_execution
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = evaluation_execution.case_hash
    JOIN otlet.jobs job ON job.id = evaluation_execution.job_id
    WHERE evaluation_execution.run_hash =
      complete_entity_quality_run.target_run_hash
    ORDER BY evaluation_execution.variant, evaluation_case.subject_id
  LOOP
    answer := CASE
      WHEN execution.variant = 'baseline'
        OR NOT complete_entity_quality_run.varied_candidate
        THEN execution.expected_answer
      WHEN execution.subject_id = 'vendor-1001:vendor-313'
        THEN 'different_entity'
      WHEN execution.subject_id = 'vendor-1001:vendor-314'
        THEN 'unclear'
      ELSE execution.expected_answer
    END;
    output := jsonb_build_object(
      'match', answer,
      'confidence', 'high',
      'reason', 'controlled entity-resolution quality fixture'
    );
    action_body := CASE answer
      WHEN 'same_entity' THEN jsonb_build_object(
        'left_id', execution.input #>> '{action_ids,left_id}',
        'right_id', execution.input #>> '{action_ids,right_id}',
        'reason', 'controlled quality merge'
      )
      WHEN 'different_entity' THEN jsonb_build_object(
        'entity_id', execution.input #>> '{action_ids,right_id}',
        'reason', 'controlled quality separation'
      )
      ELSE jsonb_build_object(
        'reason', 'controlled quality abstention',
        'left_id', execution.input #>> '{action_ids,left_id}',
        'right_id', execution.input #>> '{action_ids,right_id}'
      )
    END;
    actions := jsonb_build_array(jsonb_build_object(
      'type', CASE answer
        WHEN 'same_entity' THEN 'merge_candidate'
        WHEN 'different_entity' THEN 'new_entity'
        ELSE 'review_flag'
      END,
      'body', action_body
    ));
    selection_role := CASE
      WHEN complete_entity_quality_run.varied_candidate
        AND execution.variant = 'candidate'
        AND execution.subject_id IN (
          'vendor-1001:vendor-42',
          'vendor-1001:vendor-313'
        ) THEN 'strong'
      ELSE 'cheap'
    END;
    PERFORM otlet.complete_job(
      job_id => execution.job_id,
      output => output,
      raw_output => jsonb_build_object(
        'output', output,
        'actions', actions
      )::text,
      actions => actions,
      started_at => execution.started_at,
      trace_summary => jsonb_build_object(
        'generate_ms', 1,
        'worker_process_rss_bytes', 1000
      ),
      model_name => CASE selection_role
        WHEN 'strong' THEN complete_entity_quality_run.strong_model
        ELSE complete_entity_quality_run.cheap_model
      END,
      selection_role => selection_role,
      selection_reason => CASE selection_role
        WHEN 'strong' THEN 'controlled_escalation'
        ELSE 'controlled_cheap_acceptance'
      END,
      expected_claim_token => execution.claim_token
    );
  END LOOP;
END;
$body$;

SELECT pg_temp.complete_entity_quality_run(
  proof.run_hash,
  proof.cheap_model_name,
  proof.strong_model_name,
  true
)
FROM entity_resolution_quality_proof proof \g /dev/null

DO $body$
DECLARE
  observed_at text := to_char(
    clock_timestamp() AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
  );
  reported_at text;
BEGIN
  UPDATE entity_resolution_quality_proof proof
  SET reviewer_time = (
    SELECT jsonb_agg(
      claim.value || jsonb_build_object(
        'evidence_hash', otlet.identity_hash(
          'review_economics_reviewer_time',
          claim.value
        )
      )
      ORDER BY claim.value ->> 'case_hash'
    )
    FROM (
      SELECT jsonb_build_object(
        'case_hash', execution.case_hash,
        'variant', 'candidate',
        'seconds', 1,
        'observed_at', observed_at
      ) AS value
      FROM otlet.evaluation_executions execution
      JOIN otlet.evaluation_cases evaluation_case
        ON evaluation_case.case_hash = execution.case_hash
      WHERE execution.run_hash = proof.run_hash
        AND execution.variant = 'candidate'
        AND evaluation_case.subject_id IN (
          'vendor-1001:vendor-42',
          'vendor-1001:vendor-77',
          'vendor-1001:vendor-313'
        )
    ) claim
  );

  reported_at := to_char(
    clock_timestamp() AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
  );
  UPDATE entity_resolution_quality_proof proof
  SET observations = (
    SELECT jsonb_agg(jsonb_build_object(
      'case_hash', execution.case_hash,
      'variant', execution.variant,
      'reported_disposition', CASE
        WHEN execution.variant = 'baseline' THEN 'accepted'
        WHEN evaluation_case.subject_id = 'vendor-1001:vendor-42'
          THEN 'accepted'
        WHEN evaluation_case.subject_id = 'vendor-1001:vendor-77'
          THEN 'corrected'
        WHEN evaluation_case.subject_id = 'vendor-1001:vendor-313'
          THEN 'rejected'
        ELSE 'accepted'
      END,
      'reported_downstream_success', CASE
        WHEN execution.variant = 'baseline' THEN true
        WHEN evaluation_case.subject_id = 'vendor-1001:vendor-42' THEN true
        ELSE false
      END,
      'reported_avoided_work_seconds', CASE
        WHEN execution.variant = 'baseline'
          OR evaluation_case.subject_id = 'vendor-1001:vendor-42' THEN 1
        ELSE 0
      END,
      'reported_at', reported_at
    ) ORDER BY execution.variant, execution.case_hash)
    FROM otlet.evaluation_executions execution
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = execution.case_hash
    WHERE execution.run_hash = proof.run_hash
  );
END
$body$;

SELECT pg_sleep(GREATEST(
  0,
  extract(epoch FROM (
    (
      SELECT contract.definition #>> '{observation_window,ends_at}'
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.contract_hash = (
        SELECT contract_hash FROM entity_resolution_quality_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.02
)::double precision) \g /dev/null

SET LOCAL statement_timeout = '2s';

UPDATE entity_resolution_quality_proof proof
SET evaluation_report_hash = otlet.record_evaluation_slice_report(
  proof.run_hash,
  proof.reviewer_time,
  'Record entity-resolution quality evaluation evidence'
);
UPDATE entity_resolution_quality_proof proof
SET candidate_coverage_report_hash = otlet.record_candidate_set_coverage(
  proof.contract_hash,
  'Record entity-resolution quality candidate coverage'
);
UPDATE entity_resolution_quality_proof proof
SET review_economics_report_hash = otlet.record_review_economics_report(
  proof.contract_hash,
  proof.evaluation_report_hash,
  proof.observations,
  'Record entity-resolution quality review outcomes'
);

SET LOCAL statement_timeout = 0;

DO $body$
DECLARE
  proof entity_resolution_quality_proof%ROWTYPE;
  contract text;
BEGIN
  SELECT * INTO proof FROM entity_resolution_quality_proof;
  SELECT string_agg(concat_ws(
    ':',
    status.metric,
    status.eligible_count,
    status.numerator,
    status.denominator,
    status.rate
  ), '|' ORDER BY status.metric)
  INTO contract
  FROM otlet.entity_resolution_quality_status status
  WHERE status.contract_hash = proof.contract_hash;

  IF contract IS DISTINCT FROM
    'abstention:4:1:4:0.250000000000|candidate_recall:2:2:2:1.000000000000|escalation:4:2:4:0.500000000000|pair_classification:3:2:3:0.666666666667|reported_correction:4:1:3:0.333333333333|reported_downstream_merge_outcome:2:1:1:1.000000000000|reported_reviewer_agreement:4:1:3:0.333333333333' THEN
    RAISE EXCEPTION 'entity-resolution quality decomposition mismatch: %',
      contract;
  END IF;
  IF (
    SELECT count(*)
    FROM otlet.entity_resolution_quality_status status
    WHERE status.contract_hash = proof.contract_hash
      AND status.evidence_ready
      AND status.current_contract
      AND status.active_baseline
      AND status.candidate_coverage_gate_passed
      AND status.candidate_label_manifest_current
      AND status.candidate_coverage_report_current
      AND status.evaluation_labels_current
      AND status.candidate_coverage_report_hash =
        proof.candidate_coverage_report_hash
      AND status.evaluation_report_hash = proof.evaluation_report_hash
      AND status.review_economics_report_hash =
        proof.review_economics_report_hash
      AND status.non_authoritative
  ) <> 7
     OR pg_catalog.has_table_privilege(
       'public', 'otlet.entity_resolution_quality_status', 'SELECT'
     )
     OR EXISTS (
       SELECT 1
       FROM otlet.entity_resolution_quality_status status
       WHERE status.contract_hash = proof.contract_hash
         AND status.metric IN ('accuracy', 'overall')
     )
     OR EXISTS (SELECT 1 FROM otlet.verify_invariants()) THEN
    RAISE EXCEPTION 'entity-resolution quality evidence contract is invalid';
  END IF;
END
$body$;

DO $body$
DECLARE
  fixture entity_resolution_quality_proof%ROWTYPE;
  evaluation_case record;
  first_contract jsonb;
  starts_at timestamptz;
  next_contract_hash text;
BEGIN
  SELECT * INTO fixture FROM entity_resolution_quality_proof;
  SELECT contract.definition
  INTO first_contract
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.contract_hash = fixture.contract_hash;
  SELECT
    candidate.lineage_hash,
    candidate.case_hash
  INTO evaluation_case
  FROM otlet.evaluation_cases candidate
  JOIN otlet.eval_label_quality_status quality
    ON quality.label_id = candidate.label_id
   AND quality.qualification_eligible
  JOIN candidate_set_coverage_proof proof
    ON proof.task_name = quality.task_name
  WHERE candidate.expected_answer = 'unclear'
    AND candidate.expected_action_type = 'review_flag'
  ORDER BY candidate.created_at DESC, candidate.case_hash
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'entity-resolution quality abstention case is missing';
  END IF;

  starts_at := clock_timestamp() + interval '200 milliseconds';
  next_contract_hash := otlet.register_workload_acceptance_contract(
    (SELECT task_name FROM candidate_set_coverage_proof),
    fixture.candidate_workload_revision_hash,
    (SELECT good_hash FROM candidate_set_coverage_proof),
    jsonb_build_object(
      'mode', 'full',
      'rule', jsonb_build_object(
        'kind', 'review_economics',
        'eligible_members', jsonb_build_array(jsonb_build_object(
          'lineage_hash', evaluation_case.lineage_hash,
          'case_hash', evaluation_case.case_hash,
          'included', true
        )),
        'candidate_coverage',
          first_contract #> '{population,rule,candidate_coverage}'
      )
    ),
    starts_at,
    starts_at + interval '5 seconds',
    first_contract -> 'baseline',
    first_contract -> 'thresholds',
    fixture.contract_hash
  );
  UPDATE entity_resolution_quality_proof
  SET contract_hash = next_contract_hash,
      run_hash = NULL,
      evaluation_report_hash = NULL,
      candidate_coverage_report_hash = NULL,
      review_economics_report_hash = NULL,
      reviewer_time = '[]'::jsonb,
      observations = NULL;
END
$body$;

SELECT pg_sleep(GREATEST(
  0,
  extract(epoch FROM (
    (
      SELECT contract.definition #>> '{observation_window,starts_at}'
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.contract_hash = (
        SELECT contract_hash FROM entity_resolution_quality_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.02
)::double precision) \g /dev/null

UPDATE entity_resolution_quality_proof proof
SET run_hash = otlet.start_replay_evaluation(
  proof.contract_hash,
  ARRAY(
    SELECT member ->> 'case_hash'
    FROM otlet.workload_acceptance_contracts contract
    CROSS JOIN LATERAL jsonb_array_elements(
      contract.definition #> '{population,rule,eligible_members}'
    ) member
    WHERE contract.contract_hash = proof.contract_hash
  ),
  'entity-resolution-quality-zero-v1',
  'Prove zero-support entity-resolution quality rows'
);

UPDATE otlet.jobs job
SET status = 'running',
    attempts = 1,
    started_at = clock_timestamp(),
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
FROM otlet.evaluation_executions execution
WHERE execution.run_hash = (
    SELECT run_hash FROM entity_resolution_quality_proof
  )
  AND execution.job_id = job.id;

SELECT pg_temp.complete_entity_quality_run(
  proof.run_hash,
  proof.cheap_model_name,
  proof.strong_model_name,
  false
)
FROM entity_resolution_quality_proof proof \g /dev/null

UPDATE entity_resolution_quality_proof proof
SET observations = (
  SELECT jsonb_agg(jsonb_build_object(
    'case_hash', execution.case_hash,
    'variant', execution.variant,
    'reported_disposition', 'accepted',
    'reported_downstream_success', true,
    'reported_avoided_work_seconds', 1,
    'reported_at', to_char(
      clock_timestamp() AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
    )
  ) ORDER BY execution.variant, execution.case_hash)
  FROM otlet.evaluation_executions execution
  WHERE execution.run_hash = proof.run_hash
);

SELECT pg_sleep(GREATEST(
  0,
  extract(epoch FROM (
    (
      SELECT contract.definition #>> '{observation_window,ends_at}'
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.contract_hash = (
        SELECT contract_hash FROM entity_resolution_quality_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.02
)::double precision) \g /dev/null

SET LOCAL statement_timeout = '2s';

UPDATE entity_resolution_quality_proof proof
SET evaluation_report_hash = otlet.record_evaluation_slice_report(
  proof.run_hash,
  proof.reviewer_time,
  'Record zero-support entity-resolution quality evaluation evidence'
);
UPDATE entity_resolution_quality_proof proof
SET candidate_coverage_report_hash = otlet.record_candidate_set_coverage(
  proof.contract_hash,
  'Record zero-support entity-resolution quality candidate coverage'
);
UPDATE entity_resolution_quality_proof proof
SET review_economics_report_hash = otlet.record_review_economics_report(
  proof.contract_hash,
  proof.evaluation_report_hash,
  proof.observations,
  'Record zero-support entity-resolution quality outcomes'
);

SET LOCAL statement_timeout = 0;

DO $body$
DECLARE
  proof entity_resolution_quality_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM entity_resolution_quality_proof;
  IF (
    SELECT count(*)
    FROM otlet.entity_resolution_quality_status status
    WHERE status.contract_hash = proof.contract_hash
      AND status.current_contract
      AND status.active_baseline
      AND status.candidate_coverage_gate_passed
      AND status.candidate_label_manifest_current
      AND status.candidate_coverage_report_current
      AND status.evaluation_labels_current
  ) <> 7
     OR (
       SELECT count(*)
       FROM otlet.entity_resolution_quality_status status
       WHERE status.contract_hash = proof.contract_hash
         AND status.metric IN (
           'pair_classification',
           'reported_reviewer_agreement',
           'reported_correction',
           'reported_downstream_merge_outcome'
         )
         AND status.denominator = 0
         AND status.rate IS NULL
         AND NOT status.evidence_ready
     ) <> 4
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.workload_revisions baseline
       JOIN otlet.workload_revisions candidate
         ON candidate.workload_revision_hash =
           proof.candidate_workload_revision_hash
       JOIN candidate_set_coverage_proof fixture
         ON fixture.good_hash = baseline.workload_revision_hash
       WHERE ROW(
         baseline.definition #>> '{source,candidate_query}',
         baseline.definition #>> '{source,max_candidate_rows}',
         baseline.definition #> '{task,decision_contract}',
         baseline.definition #> '{task,output_schema}'
       ) IS NOT DISTINCT FROM ROW(
         candidate.definition #>> '{source,candidate_query}',
         candidate.definition #>> '{source,max_candidate_rows}',
         candidate.definition #> '{task,decision_contract}',
         candidate.definition #> '{task,output_schema}'
       )
       AND baseline.definition #>> '{task,instruction}' IS DISTINCT FROM
         candidate.definition #>> '{task,instruction}'
     ) THEN
    RAISE EXCEPTION 'entity-resolution quality zero-support contract is invalid';
  END IF;
END
$body$;

DO $body$
DECLARE
  proof entity_resolution_quality_proof%ROWTYPE;
  old_label_id bigint;
  action_id bigint;
  new_label_id bigint;
BEGIN
  SELECT * INTO proof FROM entity_resolution_quality_proof;
  SELECT evaluation_case.label_id, label.action_id
  INTO old_label_id, action_id
  FROM otlet.evaluation_executions execution
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = execution.case_hash
  JOIN otlet.eval_labels label ON label.id = evaluation_case.label_id
  WHERE execution.run_hash = proof.run_hash
  LIMIT 1;
  SELECT label.id
  INTO new_label_id
  FROM otlet.label_action(
    action_id,
    'unclear',
    'high',
    'review_flag',
    'Supersede entity-resolution quality abstention',
    'manual_correction'
  ) label;
  PERFORM otlet.adjudicate_eval_label(
    new_label_id,
    'accepted',
    1,
    'Accept superseding entity-resolution quality abstention',
    old_label_id
  );
  IF (
    SELECT count(*)
    FROM otlet.entity_resolution_quality_status status
    WHERE status.contract_hash = proof.contract_hash
      AND NOT status.evaluation_labels_current
      AND NOT status.evidence_ready
      AND status.candidate_label_manifest_current
      AND status.candidate_coverage_report_current
  ) <> 7 THEN
    RAISE EXCEPTION 'entity-resolution quality stale labels remained current';
  END IF;
END
$body$;

DO $body$
DECLARE
  contract text := (
    SELECT contract_hash FROM entity_resolution_quality_proof
  );
BEGIN
  IF (
    SELECT count(*)
    FROM otlet.labeled_quality_status labeled
    JOIN otlet.entity_resolution_quality_status quality
      ON quality.contract_hash = labeled.contract_hash
     AND quality.metric = labeled.metric
     AND quality.numerator = labeled.numerator
     AND quality.denominator = labeled.denominator
     AND quality.rate IS NOT DISTINCT FROM labeled.rate
    JOIN otlet.candidate_set_coverage_reports coverage
      ON coverage.report_hash = quality.candidate_coverage_report_hash
    JOIN otlet.evaluation_slice_reports evaluation
      ON evaluation.report_hash = quality.evaluation_report_hash
    JOIN otlet.review_economics_reports economics
      ON economics.report_hash = quality.review_economics_report_hash
    WHERE labeled.contract_hash = contract
      AND labeled.quality_schema = 'otlet.labeled_quality.status.v1'
      AND labeled.observed_at = GREATEST(
        coverage.created_at,
        evaluation.created_at,
        economics.created_at
      )
      AND labeled.observation_lag_ms = GREATEST(
        ceil(extract(epoch FROM (
          GREATEST(
            coverage.created_at,
            evaluation.created_at,
            economics.created_at
          ) - (quality.observation_window ->> 'ends_at')::timestamptz
        )) * 1000)::bigint,
        0
      )
  ) <> 7
     OR pg_catalog.has_table_privilege(
       'public',
       'otlet.labeled_quality_status',
       'SELECT'
     ) THEN
    RAISE EXCEPTION 'otlet labeled quality status contract is invalid';
  END IF;
END
$body$;

SELECT 'labeled_quality_status_contract=7|denominators|lag|public_closed';

SELECT 'entity_resolution_quality_contract=' || count(*)::text || '|true'
FROM otlet.entity_resolution_quality_status status
WHERE status.contract_hash = (
  SELECT contract_hash FROM entity_resolution_quality_proof
);
