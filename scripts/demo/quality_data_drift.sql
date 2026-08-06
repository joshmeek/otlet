CREATE TEMP TABLE quality_data_drift_proof (
  case_g_hash text,
  case_h_hash text,
  baseline_observation_hash text,
  observed_observation_hash text,
  contract_hash text,
  run_hash text,
  evaluation_report_hash text,
  drift_report_hash text,
  repeated_report_hash text,
  malformed_baseline_blocked boolean NOT NULL DEFAULT false,
  wrong_variant_blocked boolean NOT NULL DEFAULT false,
  pending_verified boolean NOT NULL DEFAULT false,
  candidate_volume_verified boolean NOT NULL DEFAULT false,
  wrong_report_blocked boolean NOT NULL DEFAULT false,
  wrong_observation_blocked boolean NOT NULL DEFAULT false,
  conflicting_retry_blocked boolean NOT NULL DEFAULT false,
  observation_immutable boolean NOT NULL DEFAULT false,
  report_immutable boolean NOT NULL DEFAULT false
) ON COMMIT DROP;
INSERT INTO quality_data_drift_proof DEFAULT VALUES;

INSERT INTO public.otlet_demo_evaluation_slice_primary (
  id,
  review_state,
  shape_probe,
  protected_note
) VALUES
  ('slice-g', 'pending', '{"kind":"stable"}'::jsonb, 'DO_NOT_TOUCH'),
  ('slice-h', 'pending', '"changed"'::jsonb, 'DO_NOT_TOUCH');

SET LOCAL statement_timeout = '2s';
SELECT pg_temp.assert_true(
  otlet.run_task_subject('evaluation_slice_probe_task', 'slice-g')
    + otlet.run_task_subject('evaluation_slice_probe_task', 'slice-h') = 2,
  'quality and data drift source rows did not queue once each'
);
SET LOCAL statement_timeout = 0;

UPDATE otlet.jobs
SET status = 'running',
    attempts = 1,
    started_at = clock_timestamp(),
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
WHERE task_name = 'evaluation_slice_probe_task'
  AND subject_id IN ('slice-g', 'slice-h')
  AND execution_mode = 'production';

DO $body$
DECLARE
  saved_job otlet.jobs%ROWTYPE;
  saved_action_id bigint;
  saved_label_id bigint;
  saved_case_hash text;
BEGIN
  FOR saved_job IN
    SELECT job.*
    FROM otlet.jobs job
    WHERE job.task_name = 'evaluation_slice_probe_task'
      AND job.subject_id IN ('slice-g', 'slice-h')
      AND job.execution_mode = 'production'
    ORDER BY job.subject_id
  LOOP
    PERFORM otlet.complete_job(
      job_id => saved_job.id,
      output => '{"decision":"approve","confidence":"high"}'::jsonb,
      raw_output => '{
        "output":{"decision":"approve","confidence":"high"},
        "actions":[{"type":"review_flag","body":{"reason":"drift fixture"}}]
      }',
      actions => '[{
        "type":"review_flag",
        "body":{"reason":"drift fixture"}
      }]'::jsonb,
      started_at => saved_job.started_at,
      trace_summary => '{
        "schema_validation_status":"passed",
        "generate_ms":1,
        "worker_process_rss_bytes":1
      }'::jsonb,
      model_name => 'evaluation_slice_baseline',
      expected_claim_token => saved_job.claim_token
    );
    SELECT action.id INTO saved_action_id
    FROM otlet.actions action
    WHERE action.job_id = saved_job.id
      AND action.action_type = 'review_flag';

    IF saved_job.subject_id = 'slice-g' THEN
      SELECT label.id INTO saved_label_id
      FROM otlet.correct_action(
        saved_action_id,
        '{
          "expected_answer":"reject",
          "expected_confidence":"high",
          "expected_action_type":"review_flag"
        }'::jsonb,
        'Reviewer corrected the approval'
      ) label;
    ELSE
      PERFORM otlet.record_review_event(
        'approve',
        saved_action_id,
        NULL,
        'Reviewer accepted the approval'
      );
      SELECT label.id INTO saved_label_id
      FROM otlet.label_action(
        saved_action_id,
        expected_answer => 'approve',
        expected_confidence => 'low',
        expected_action_type => 'review_flag',
        reason => 'Approved confidence-only mismatch fixture',
        label_source => 'manual_correction'
      ) label;
    END IF;

    PERFORM otlet.adjudicate_eval_label(
      saved_label_id,
      'accepted',
      1.0,
      'Accepted quality and data drift label'
    );
    saved_case_hash := otlet.register_evaluation_case(
      saved_label_id,
      'qualification',
      'Approved quality and data drift snapshot'
    );
    UPDATE quality_data_drift_proof
    SET case_g_hash = CASE saved_job.subject_id
          WHEN 'slice-g' THEN saved_case_hash ELSE case_g_hash END,
        case_h_hash = CASE saved_job.subject_id
          WHEN 'slice-h' THEN saved_case_hash ELSE case_h_hash END;
  END LOOP;
END
$body$;

UPDATE quality_data_drift_proof proof
SET baseline_observation_hash = observation.observation_hash
FROM LATERAL (
  SELECT candidate.observation_hash
  FROM otlet.task_candidate_observations candidate
  JOIN evaluation_slice_proof slice ON true
  WHERE candidate.task_name = 'evaluation_slice_probe_task'
    AND candidate.workload_revision_hash = slice.baseline_revision_hash
    AND candidate.candidate_rows = 6
    AND candidate.admitted
  ORDER BY candidate.created_at, candidate.observation_hash
  LIMIT 1
) observation;

DO $body$
DECLARE
  slice evaluation_slice_proof%ROWTYPE;
  promotion promotion_shadow_rollback_proof%ROWTYPE;
  proof quality_data_drift_proof%ROWTYPE;
  baseline_report_hash text;
  eligible_members jsonb;
  declaration jsonb;
  starts_at timestamptz;
  ends_at timestamptz;
BEGIN
  SELECT * INTO slice FROM evaluation_slice_proof;
  SELECT * INTO promotion FROM promotion_shadow_rollback_proof;
  SELECT * INTO proof FROM quality_data_drift_proof;
  SELECT qualification.report_hash INTO baseline_report_hash
  FROM production_model_qualification_runs qualification
  WHERE qualification.repeat_number = 1;
  IF proof.baseline_observation_hash IS NULL THEN
    RAISE EXCEPTION 'quality and data drift baseline candidate observation is missing';
  END IF;
  SELECT jsonb_agg(jsonb_build_object(
    'lineage_hash', evaluation_case.lineage_hash,
    'case_hash', evaluation_case.case_hash,
    'included', true
  ) ORDER BY evaluation_case.lineage_hash)
  INTO eligible_members
  FROM otlet.evaluation_cases evaluation_case
  WHERE evaluation_case.case_hash IN (
    proof.case_g_hash,
    proof.case_h_hash,
    (SELECT case_hash FROM evaluation_slice_cases WHERE fixture_id = 'slice-a'),
    (SELECT case_hash FROM evaluation_slice_cases WHERE fixture_id = 'slice-b')
  );
  declaration := jsonb_build_object(
    'format', 'otlet.quality_data_drift.v1',
    'report_hash', baseline_report_hash,
    'variant', 'baseline',
    'candidate_observation_hash', proof.baseline_observation_hash,
    'reviewer_overturn', otlet.quality_data_reviewer_overturn(
      baseline_report_hash
    ),
    'minimum_support', 2,
    'maximum_drift', jsonb_build_object(
      'input_shape', 0.1,
      'candidate_volume', 0.2,
      'class', 0.05,
      'abstention', 0.2,
      'escalation', 0.5,
      'reviewer_overturn', 0.2,
      'false_trust', 0.1
    )
  );

  starts_at := clock_timestamp() + interval '500 milliseconds';
  ends_at := starts_at + interval '3 seconds';
  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'evaluation_slice_probe_task',
      slice.baseline_revision_hash,
      slice.baseline_revision_hash,
      jsonb_build_object(
        'mode', 'full',
        'rule', jsonb_build_object(
          'kind', 'quality_data_drift',
          'eligible_members', eligible_members
        )
      ),
      starts_at,
      ends_at,
      jsonb_build_object(
        'name', 'qualification_baseline_report',
        'definition', declaration || '{"confidence":"high"}'::jsonb
      ),
      slice.thresholds,
      promotion.qualification_contract_hash
    );
    RAISE EXCEPTION 'malformed quality and data drift baseline unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet quality and data drift baseline is invalid' THEN
      RAISE;
    END IF;
    UPDATE quality_data_drift_proof
    SET malformed_baseline_blocked = true;
  END;

  starts_at := clock_timestamp() + interval '500 milliseconds';
  ends_at := starts_at + interval '3 seconds';
  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'evaluation_slice_probe_task',
      slice.baseline_revision_hash,
      slice.baseline_revision_hash,
      jsonb_build_object(
        'mode', 'full',
        'rule', jsonb_build_object(
          'kind', 'quality_data_drift',
          'eligible_members', eligible_members
        )
      ),
      starts_at,
      ends_at,
      jsonb_build_object(
        'name', 'qualification_baseline_report',
        'definition', jsonb_set(declaration, '{variant}', '"candidate"'::jsonb)
      ),
      slice.thresholds,
      promotion.qualification_contract_hash
    );
    RAISE EXCEPTION 'wrong quality and data drift baseline variant unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet quality and data drift baseline revision is invalid' THEN
      RAISE;
    END IF;
    UPDATE quality_data_drift_proof SET wrong_variant_blocked = true;
  END;

  starts_at := clock_timestamp() + interval '500 milliseconds';
  ends_at := starts_at + interval '3 seconds';
  UPDATE quality_data_drift_proof
  SET contract_hash = otlet.register_workload_acceptance_contract(
    'evaluation_slice_probe_task',
    slice.baseline_revision_hash,
    slice.baseline_revision_hash,
    jsonb_build_object(
      'mode', 'full',
      'rule', jsonb_build_object(
        'kind', 'quality_data_drift',
        'eligible_members', eligible_members
      )
    ),
    starts_at,
    ends_at,
    jsonb_build_object(
      'name', 'qualification_baseline_report',
      'definition', declaration
    ),
    slice.thresholds,
    promotion.qualification_contract_hash
  );
END
$body$;

UPDATE quality_data_drift_proof proof
SET pending_verified = (
  SELECT count(*) = 7
    AND bool_and(status.status = 'insufficient_evidence')
    AND bool_and(NOT status.evidence_ready)
    AND bool_and(NOT status.alert)
    AND bool_and(status.baseline_support = 0)
    AND bool_and(status.observed_support = 0)
  FROM otlet.quality_data_drift_status status
  WHERE status.contract_hash = proof.contract_hash
);

SELECT pg_sleep(GREATEST(
  0,
  extract(epoch FROM (
    (
      SELECT contract.definition #>> '{observation_window,starts_at}'
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.contract_hash = (
        SELECT contract_hash FROM quality_data_drift_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.02
)::double precision) \g /dev/null

UPDATE quality_data_drift_proof proof
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
  'quality-data-drift-v1',
  'Observe quality and data drift against the declared baseline'
);

DELETE FROM public.otlet_demo_evaluation_slice_primary WHERE id <> 'slice-h';
DELETE FROM public.otlet_demo_evaluation_slice_secondary;

SET LOCAL statement_timeout = '2s';
DO $body$
DECLARE
  queued bigint;
  observed_hash text;
BEGIN
  queued := otlet.run_task('evaluation_slice_probe_task');
  SELECT observation.observation_hash INTO observed_hash
  FROM otlet.task_candidate_observations observation
  JOIN quality_data_drift_proof proof ON true
  JOIN otlet.workload_acceptance_contracts contract
    ON contract.contract_hash = proof.contract_hash
  WHERE observation.task_name = 'evaluation_slice_probe_task'
    AND observation.workload_revision_hash = contract.candidate_workload_revision_hash
    AND observation.created_at >= (
      contract.definition #>> '{observation_window,starts_at}'
    )::timestamptz
    AND observation.created_at < (
      contract.definition #>> '{observation_window,ends_at}'
    )::timestamptz
  ORDER BY observation.created_at DESC, observation.observation_hash DESC
  LIMIT 1;
  UPDATE quality_data_drift_proof
  SET observed_observation_hash = observed_hash,
      candidate_volume_verified = queued = 1
        AND observed_hash IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM otlet.task_candidate_observations observation
          WHERE observation.observation_hash = observed_hash
            AND observation.candidate_rows = 1
            AND observation.admitted
        );
END
$body$;
SET LOCAL statement_timeout = 0;

UPDATE otlet.jobs job
SET status = 'running',
    attempts = 1,
    started_at = clock_timestamp(),
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
FROM otlet.evaluation_executions execution
WHERE execution.run_hash = (SELECT run_hash FROM quality_data_drift_proof)
  AND execution.job_id = job.id;

DO $body$
DECLARE
  execution record;
  output jsonb;
  actions jsonb;
BEGIN
  FOR execution IN
    SELECT
      evaluation_execution.*,
      evaluation_case.subject_id,
      evaluation_case.expected_answer,
      job.claim_token,
      job.started_at
    FROM otlet.evaluation_executions evaluation_execution
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = evaluation_execution.case_hash
    JOIN otlet.jobs job ON job.id = evaluation_execution.job_id
    WHERE evaluation_execution.run_hash = (
      SELECT run_hash FROM quality_data_drift_proof
    )
    ORDER BY evaluation_execution.variant, evaluation_case.subject_id
  LOOP
    output := jsonb_build_object(
      'decision', CASE
        WHEN execution.variant = 'candidate' AND execution.subject_id = 'slice-a'
          THEN 'unclear'
        WHEN execution.variant = 'candidate' AND execution.subject_id = 'slice-g'
          THEN 'approve'
        ELSE execution.expected_answer
      END,
      'confidence', 'high'
    );
    actions := CASE
      WHEN execution.variant = 'candidate' AND execution.subject_id = 'slice-a'
        THEN '[]'::jsonb
      ELSE jsonb_build_array(jsonb_build_object(
        'type', 'review_flag',
        'body', jsonb_build_object('reason', 'quality drift replay')
      ))
    END;
    PERFORM otlet.complete_job(
      job_id => execution.job_id,
      output => output,
      raw_output => jsonb_build_object('output', output, 'actions', actions)::text,
      actions => actions,
      started_at => execution.started_at,
      trace_summary => '{
        "schema_validation_status":"passed",
        "generate_ms":1,
        "worker_process_rss_bytes":1000
      }'::jsonb,
      model_name => 'evaluation_slice_baseline',
      expected_claim_token => execution.claim_token
    );
  END LOOP;
END
$body$;

SELECT pg_sleep(GREATEST(
  0,
  extract(epoch FROM (
    (
      SELECT contract.definition #>> '{observation_window,ends_at}'
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.contract_hash = (
        SELECT contract_hash FROM quality_data_drift_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.05
)::double precision) \g /dev/null

UPDATE quality_data_drift_proof proof
SET evaluation_report_hash = otlet.record_evaluation_slice_report(
  proof.run_hash,
  '[]'::jsonb,
  'Record quality and data drift evidence'
);

DO $body$
BEGIN
  BEGIN
    PERFORM otlet.record_quality_data_drift_report(
      (SELECT contract_hash FROM quality_data_drift_proof),
      (SELECT report_hash FROM production_model_qualification_runs
        WHERE repeat_number = 1),
      (SELECT observed_observation_hash FROM quality_data_drift_proof),
      'Reject a report from another contract'
    );
    RAISE EXCEPTION 'wrong quality and data drift report unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet quality and data drift observed report is invalid' THEN
      RAISE;
    END IF;
    UPDATE quality_data_drift_proof SET wrong_report_blocked = true;
  END;

  BEGIN
    PERFORM otlet.record_quality_data_drift_report(
      (SELECT contract_hash FROM quality_data_drift_proof),
      (SELECT evaluation_report_hash FROM quality_data_drift_proof),
      (SELECT baseline_observation_hash FROM quality_data_drift_proof),
      'Reject an observation outside the window'
    );
    RAISE EXCEPTION 'wrong quality and data drift observation unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet quality and data drift candidate observation is invalid' THEN
      RAISE;
    END IF;
    UPDATE quality_data_drift_proof SET wrong_observation_blocked = true;
  END;
END
$body$;

UPDATE quality_data_drift_proof proof
SET drift_report_hash = otlet.record_quality_data_drift_report(
  proof.contract_hash,
  proof.evaluation_report_hash,
  proof.observed_observation_hash,
  'Record bounded quality and data drift evidence'
);

DO $body$
DECLARE
  saved_action_id bigint;
BEGIN
  SELECT action.id INTO saved_action_id
  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  WHERE job.task_name = 'evaluation_slice_probe_task'
    AND job.subject_id = 'slice-h'
    AND job.execution_mode = 'production'
  ORDER BY action.id DESC
  LIMIT 1;
  PERFORM otlet.record_review_event(
    'reject',
    saved_action_id,
    NULL,
    'Post-report review cannot rewrite recorded drift evidence'
  );
END
$body$;

UPDATE quality_data_drift_proof proof
SET repeated_report_hash = otlet.record_quality_data_drift_report(
  proof.contract_hash,
  proof.evaluation_report_hash,
  proof.observed_observation_hash,
  'Record bounded quality and data drift evidence'
);

DO $body$
BEGIN
  BEGIN
    PERFORM otlet.record_quality_data_drift_report(
      (SELECT contract_hash FROM quality_data_drift_proof),
      (SELECT evaluation_report_hash FROM quality_data_drift_proof),
      (SELECT observed_observation_hash FROM quality_data_drift_proof),
      'Conflicting quality and data drift evidence'
    );
    RAISE EXCEPTION 'conflicting quality and data drift retry unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
         'otlet quality and data drift contract already has a different report' THEN
      RAISE;
    END IF;
    UPDATE quality_data_drift_proof SET conflicting_retry_blocked = true;
  END;

  BEGIN
    UPDATE otlet.task_candidate_observations
    SET candidate_rows = candidate_rows + 1
    WHERE observation_hash = (
      SELECT observed_observation_hash FROM quality_data_drift_proof
    );
  EXCEPTION WHEN OTHERS THEN
    UPDATE quality_data_drift_proof SET observation_immutable = true;
  END;

  BEGIN
    DELETE FROM otlet.quality_data_drift_reports
    WHERE report_hash = (SELECT drift_report_hash FROM quality_data_drift_proof);
  EXCEPTION WHEN OTHERS THEN
    UPDATE quality_data_drift_proof SET report_immutable = true;
  END;
END
$body$;

CREATE TEMP TABLE quality_data_drift_contract ON COMMIT DROP AS
SELECT concat_ws('|',
  proof.malformed_baseline_blocked
    AND proof.wrong_variant_blocked
    AND proof.pending_verified
    AND proof.candidate_volume_verified,
  proof.wrong_report_blocked
    AND proof.wrong_observation_blocked
    AND proof.conflicting_retry_blocked,
  proof.drift_report_hash = proof.repeated_report_hash
    AND proof.observation_immutable
    AND proof.report_immutable,
  (SELECT count(*) = 7
      AND bool_and(status.evidence_ready)
      AND bool_and(status.current_contract)
      AND count(*) FILTER (WHERE status.alert) = 6
      AND count(*) FILTER (WHERE status.status = 'drifted') = 6
      AND count(*) FILTER (WHERE status.status = 'within_baseline') = 1
   FROM otlet.quality_data_drift_status status
   WHERE status.contract_hash = proof.contract_hash),
  (SELECT status.drift = 0.25
      AND status.alert
      AND status.baseline_support = 5
      AND status.observed_support = 4
      AND status.measurement ? 'baseline_distribution'
      AND status.measurement ? 'observed_distribution'
   FROM otlet.quality_data_drift_status status
   WHERE status.contract_hash = proof.contract_hash
     AND status.dimension = 'input_shape'),
  (SELECT status.baseline_value = 6
      AND status.observed_value = 1
      AND status.drift = 5::numeric / 6
      AND status.minimum_support = 1
      AND status.alert
      AND status.measurement ->> 'definition' = 'pre_admission_source_query_rows'
   FROM otlet.quality_data_drift_status status
   WHERE status.contract_hash = proof.contract_hash
     AND status.dimension = 'candidate_volume'),
  (SELECT status.drift = 0.1
      AND status.baseline_support = 5
      AND status.observed_support = 4
      AND status.alert
   FROM otlet.quality_data_drift_status status
   WHERE status.contract_hash = proof.contract_hash
     AND status.dimension = 'class'),
  (SELECT status.baseline_value = 0
      AND status.observed_value = 0.25
      AND status.alert
   FROM otlet.quality_data_drift_status status
   WHERE status.contract_hash = proof.contract_hash
     AND status.dimension = 'abstention'),
  (SELECT status.baseline_value = 0
      AND status.observed_value = 0
      AND status.drift = 0
      AND NOT status.alert
   FROM otlet.quality_data_drift_status status
   WHERE status.contract_hash = proof.contract_hash
     AND status.dimension = 'escalation'),
  (SELECT status.baseline_value = 0
      AND status.observed_value = 0.25
      AND status.baseline_support = 5
      AND status.observed_support = 4
      AND status.alert
      AND status.measurement ->> 'definition' = 'latest_terminal_review_event'
      AND otlet.quality_data_reviewer_overturn(
        proof.evaluation_report_hash
      ) #>> '{value}' = '0.50000000000000000000'
   FROM otlet.quality_data_drift_status status
   WHERE status.contract_hash = proof.contract_hash
     AND status.dimension = 'reviewer_overturn'),
  (SELECT status.baseline_value = 0
      AND status.observed_value = 1::numeric / 3
      AND status.baseline_support = 5
      AND status.observed_support = 3
      AND status.alert
      AND status.measurement ->> 'definition' =
        'trusted_non_abstain_answer_and_valid_action'
   FROM otlet.quality_data_drift_status status
   WHERE status.contract_hash = proof.contract_hash
     AND status.dimension = 'false_trust'),
  (SELECT status.metrics #>> '{false_trust,value}' = '0.75000000000000000000'
      AND status.metrics #>> '{false_trust,support}' = '4'
   FROM otlet.evaluation_slice_status status
   WHERE status.report_hash = proof.evaluation_report_hash
     AND status.variant = 'candidate'
     AND status.slice_kind = 'overall'
     AND status.slice = '{"all":true}'::jsonb),
  position(
    'confidence' IN lower(
      pg_get_viewdef('otlet.quality_data_drift_status'::regclass, true)
    )
  ) = 0
    AND position(
      'confidence' IN lower((
        SELECT report.definition::text
        FROM otlet.quality_data_drift_reports report
        WHERE report.report_hash = proof.drift_report_hash
      ))
    ) = 0
    AND NOT EXISTS (
      SELECT 1
      FROM information_schema.columns column_row
      WHERE column_row.table_schema = 'otlet'
        AND column_row.table_name = 'quality_data_drift_status'
        AND column_row.column_name IN ('input', 'shaped_input')
    ),
  otlet.quality_data_input_shape('{"field":1}'::jsonb) =
      otlet.quality_data_input_shape('{"field":2}'::jsonb)
    AND otlet.quality_data_input_shape('{"field":1}'::jsonb) <>
      otlet.quality_data_input_shape('{"field":"1"}'::jsonb)
    AND otlet.quality_data_input_shape(jsonb_build_object(
      'items',
      (SELECT jsonb_agg(value) FROM generate_series(1, 4097) value)
    )) IS NULL,
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.task_candidate_observations',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.quality_data_drift_reports',
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.quality_data_drift_status', 'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM unnest(ARRAY[
        'otlet.record_task_candidate_observation(text,text,bigint,bigint,bigint,boolean,text)'::regprocedure,
        'otlet.quality_data_input_shape(jsonb)'::regprocedure,
        'otlet.quality_data_distribution_drift(jsonb,jsonb)'::regprocedure,
        'otlet.quality_data_reviewer_overturn(text)'::regprocedure,
        'otlet.quality_data_report_metrics(text,text)'::regprocedure,
        'otlet.quality_data_drift_declaration_valid(jsonb)'::regprocedure,
        'otlet.validate_quality_data_drift_contract()'::regprocedure,
        'otlet.record_quality_data_drift_report(text,text,text,text)'::regprocedure
      ]) function_row(oid)
      WHERE pg_catalog.has_function_privilege('public', function_row.oid, 'EXECUTE')
    ),
  (SELECT count(*) = 1
   FROM otlet.quality_data_drift_reports report
   WHERE report.contract_hash = proof.contract_hash),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
) AS contract
FROM quality_data_drift_proof proof;

SELECT pg_temp.assert_true(
  contract = 't|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t',
  'quality and data drift contract mismatch: ' || contract
)
FROM quality_data_drift_contract;

SELECT 'quality_data_drift_contract=' || contract
FROM quality_data_drift_contract;

\ir /work/scripts/demo/review_economics.sql
