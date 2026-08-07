CREATE TEMP TABLE promotion_shadow_rollback_proof (
  shadow_case_hash text,
  shadow_contract_hash text,
  shadow_run_hash text,
  shadow_report_hash text,
  qualification_contract_hash text,
  decision_event_hash text,
  pack_application_event_hash text,
  repeated_pack_application_event_hash text,
  activation_event_hash text,
  repeated_activation_event_hash text,
  pack_rollback_event_hash text,
  repeated_pack_rollback_event_hash text,
  rollback_event_hash text,
  repeated_rollback_event_hash text,
  shadow_ready boolean NOT NULL DEFAULT false,
  shadow_non_authoritative boolean NOT NULL DEFAULT false,
  bad_evidence_blocked boolean NOT NULL DEFAULT false,
  stale_activation_blocked boolean NOT NULL DEFAULT false,
  missing_pack_decision_blocked boolean NOT NULL DEFAULT false,
  raw_activation_blocked boolean NOT NULL DEFAULT false,
  activation_conflict_blocked boolean NOT NULL DEFAULT false,
  rollback_conflict_blocked boolean NOT NULL DEFAULT false,
  active_status_verified boolean NOT NULL DEFAULT false,
  pause_resume_verified boolean NOT NULL DEFAULT false,
  rollback_status_verified boolean NOT NULL DEFAULT false
) ON COMMIT DROP;
INSERT INTO promotion_shadow_rollback_proof DEFAULT VALUES;

DO $body$
DECLARE
  saved_action_id bigint;
  saved_label_id bigint;
  saved_case_hash text;
BEGIN
  SELECT action.id
  INTO saved_action_id
  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  WHERE job.task_name = 'evaluation_slice_probe_task'
    AND job.subject_id = 'slice-f'
    AND job.execution_mode = 'production'
    AND action.action_type = 'review_flag';
  IF saved_action_id IS NULL THEN
    RAISE EXCEPTION 'promotion shadow fixture has no slice-f action';
  END IF;

  SELECT label.id
  INTO saved_label_id
  FROM otlet.label_action(
    saved_action_id,
    expected_answer => 'reject',
    expected_confidence => 'high',
    expected_action_type => 'review_flag',
    reason => 'Approved promotion shadow fixture',
    label_source => 'manual_correction'
  ) label;
  PERFORM otlet.adjudicate_eval_label(
    saved_label_id,
    'accepted',
    1.0,
    'Accepted promotion shadow label'
  );
  saved_case_hash := otlet.register_evaluation_case(
    saved_label_id,
    'shadow',
    'Approved promotion shadow snapshot'
  );

  UPDATE promotion_shadow_rollback_proof
  SET shadow_case_hash = saved_case_hash;
  IF (SELECT labeled FROM evaluation_slice_cases WHERE fixture_id = 'slice-f') THEN
    RAISE EXCEPTION 'promotion shadow fixture entered the qualification manifest';
  END IF;
END
$body$;

DO $body$
DECLARE
  proof evaluation_slice_proof%ROWTYPE;
  shadow_case_hash text;
  shadow_members jsonb;
  shadow_thresholds jsonb;
  selected_shadow_contract_hash text;
BEGIN
  SELECT * INTO proof FROM evaluation_slice_proof;
  SELECT saved.shadow_case_hash
  INTO shadow_case_hash
  FROM promotion_shadow_rollback_proof saved;
  SELECT jsonb_agg(jsonb_build_object(
    'lineage_hash', evaluation_case.lineage_hash,
    'case_hash', evaluation_case.case_hash,
    'included', true
  ))
  INTO shadow_members
  FROM otlet.evaluation_cases evaluation_case
  WHERE evaluation_case.case_hash = shadow_case_hash;
  SELECT jsonb_object_agg(
    threshold.key,
    jsonb_set(threshold.value, '{minimum_support}', '1'::jsonb)
  )
  INTO shadow_thresholds
  FROM jsonb_each(proof.thresholds) threshold;

  selected_shadow_contract_hash := otlet.register_workload_acceptance_contract(
    'evaluation_slice_probe_task',
    proof.candidate_revision_hash,
    proof.baseline_revision_hash,
    jsonb_build_object(
      'mode', 'full',
      'rule', jsonb_build_object(
        'kind', 'promotion_shadow',
        'eligible_members', shadow_members
      )
    ),
    clock_timestamp() + interval '250 milliseconds',
    clock_timestamp() + interval '5.25 seconds',
    '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
    shadow_thresholds,
    proof.contract_hash
  );
  UPDATE promotion_shadow_rollback_proof
  SET shadow_contract_hash = selected_shadow_contract_hash;
  UPDATE evaluation_slice_proof
  SET contract_hash = selected_shadow_contract_hash;
END
$body$;

DO $body$
DECLARE
  proof evaluation_slice_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM evaluation_slice_proof;
  BEGIN
    PERFORM otlet.promote_workload_revision(
      'evaluation_slice_probe_task',
      proof.candidate_revision_hash,
      proof.baseline_revision_hash
    );
    RAISE EXCEPTION 'raw shadow promotion unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
         'otlet qualified workload revision requires governed promotion or rollback' THEN
      RAISE;
    END IF;
  END;
  UPDATE promotion_shadow_rollback_proof SET raw_activation_blocked = true;
END
$body$;

SELECT pg_sleep(GREATEST(
  0,
  extract(epoch FROM (
    (
      SELECT contract.definition #>> '{observation_window,starts_at}'
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.contract_hash = (
        SELECT shadow_contract_hash FROM promotion_shadow_rollback_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.02
)::double precision) \g /dev/null

UPDATE promotion_shadow_rollback_proof proof
SET shadow_run_hash = otlet.start_replay_evaluation(
  proof.shadow_contract_hash,
  ARRAY[proof.shadow_case_hash],
  'promotion-shadow-v1',
  'Compare the inactive candidate with the active revision'
);

UPDATE otlet.jobs job
SET status = 'running',
    attempts = 1,
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
FROM otlet.evaluation_executions execution
JOIN promotion_shadow_rollback_proof proof
  ON proof.shadow_run_hash = execution.run_hash
WHERE execution.job_id = job.id;

DO $body$
DECLARE
  execution record;
  job_output jsonb;
  job_actions jsonb;
BEGIN
  FOR execution IN
    SELECT evaluation_execution.*, job.claim_token, job.started_at
    FROM otlet.evaluation_executions evaluation_execution
    JOIN promotion_shadow_rollback_proof proof
      ON proof.shadow_run_hash = evaluation_execution.run_hash
    JOIN otlet.jobs job ON job.id = evaluation_execution.job_id
    ORDER BY evaluation_execution.variant
  LOOP
    job_actions := jsonb_build_array(jsonb_build_object(
      'type', 'review_flag',
      'body', jsonb_build_object('reason', 'promotion shadow fixture')
    ));
    IF execution.variant = 'baseline' THEN
      job_output := '{"decision":"reject","confidence":"high"}'::jsonb;
      PERFORM otlet.complete_job(
        job_id => execution.job_id,
        output => job_output,
        raw_output => jsonb_build_object(
          'output', job_output,
          'actions', job_actions
        )::text,
        actions => job_actions,
        started_at => execution.started_at,
        trace_summary => '{
          "schema_validation_status":"passed",
          "generate_ms":2,
          "worker_process_rss_bytes":1002
        }'::jsonb,
        model_name => 'evaluation_slice_baseline',
        expected_claim_token => execution.claim_token
      );
    ELSE
      PERFORM otlet.record_model_attempt(
        execution.job_id,
        'evaluation_slice_cheap',
        output => '{"decision":"unclear","confidence":"high"}'::jsonb,
        raw_output => '{"decision":"unclear","confidence":"high"}',
        started_at => execution.started_at,
        trace_summary => '{
          "schema_validation_status":"passed",
          "generate_ms":1,
          "worker_process_rss_bytes":2001
        }'::jsonb,
        selection_role => 'cheap',
        selection_status => 'rejected',
        selection_reason => 'abstained',
        expected_claim_token => execution.claim_token,
        actions => '[]'::jsonb
      );
      job_output := '{"decision":"reject","confidence":"high"}'::jsonb;
      job_actions := jsonb_build_array(jsonb_build_object(
        'type', 'review_flag',
        'body', jsonb_build_object('reason', 'candidate shadow fixture')
      ));
      PERFORM otlet.complete_job(
        job_id => execution.job_id,
        output => job_output,
        raw_output => jsonb_build_object(
          'output', job_output,
          'actions', job_actions
        )::text,
        actions => job_actions,
        started_at => execution.started_at,
        trace_summary => '{
          "schema_validation_status":"passed",
          "generate_ms":3,
          "worker_process_rss_bytes":3003
        }'::jsonb,
        model_name => 'evaluation_slice_strong',
        selection_role => 'strong',
        selection_reason => 'cheap_abstained',
        expected_claim_token => execution.claim_token
      );
    END IF;
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
        SELECT shadow_contract_hash FROM promotion_shadow_rollback_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.05
)::double precision) \g /dev/null

UPDATE promotion_shadow_rollback_proof proof
SET shadow_report_hash = otlet.record_evaluation_slice_report(
  proof.shadow_run_hash,
  (
    SELECT jsonb_agg(jsonb_build_object(
      'case_hash', proof.shadow_case_hash,
      'variant', execution.variant,
      'seconds', 1,
      'evidence_hash', otlet.identity_hash(
        'promotion_shadow_reviewer_observation',
        jsonb_build_object('job_id', job.id)
      ),
      'observed_at', to_char(
        job.finished_at AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
      )
    ) ORDER BY execution.variant)
    FROM otlet.evaluation_executions execution
    JOIN otlet.jobs job ON job.id = execution.job_id
    WHERE execution.run_hash = proof.shadow_run_hash
  ),
  'Record the active and candidate shadow comparison'
);

UPDATE promotion_shadow_rollback_proof proof
SET shadow_ready = (
      SELECT count(*) = 1
        AND bool_and(
          replay.same_input_snapshot
          AND replay.baseline_job_status = 'complete'
          AND replay.candidate_job_status = 'complete'
          AND replay.baseline_result_hash IS NOT NULL
          AND replay.candidate_result_hash IS NOT NULL
          AND replay.baseline_actions_hash <> replay.candidate_actions_hash
          AND replay.non_authoritative
        )
      FROM otlet.evaluation_replay_status replay
      WHERE replay.run_hash = proof.shadow_run_hash
    )
    AND (
      SELECT count(*) = 2
        AND bool_and(status.population_kind = 'shadow')
        AND bool_and(status.sampling_method ->> 'mode' = 'full')
        AND bool_and(status.eligible_count = 1)
        AND bool_and(status.labeled_count = 1)
        AND bool_and(status.included_count = 1)
        AND bool_and(status.non_authoritative)
      FROM otlet.evaluation_slice_status status
      WHERE status.report_hash = proof.shadow_report_hash
        AND status.slice_kind = 'overall'
    )
    AND (
      SELECT jsonb_array_length(
        report.definition #> '{reviewer_time,observations}'
      ) = 2
      FROM otlet.evaluation_slice_reports report
      WHERE report.report_hash = proof.shadow_report_hash
    )
    AND EXISTS (
      SELECT 1
      FROM otlet.workload_shadow_comparison_status comparison
      WHERE comparison.report_hash = proof.shadow_report_hash
        AND comparison.run_hash = proof.shadow_run_hash
        AND comparison.shadow_contract_hash = proof.shadow_contract_hash
        AND comparison.case_count = 1
        AND comparison.non_authoritative
        AND comparison.comparison_ready
    ),
    shadow_non_authoritative = NOT EXISTS (
      SELECT 1
      FROM otlet.evaluation_executions execution
      JOIN otlet.actions action ON action.job_id = execution.job_id
      WHERE execution.run_hash = proof.shadow_run_hash
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.evaluation_executions execution
      JOIN otlet.review_events event ON event.job_id = execution.job_id
      WHERE execution.run_hash = proof.shadow_run_hash
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.evaluation_executions execution
      JOIN otlet.runs run ON run.job_id = execution.job_id
      WHERE execution.run_hash = proof.shadow_run_hash
    );

SELECT pg_temp.assert_true(
  proof.shadow_ready AND proof.shadow_non_authoritative,
  'promotion shadow comparison is incomplete or authoritative'
)
FROM promotion_shadow_rollback_proof proof;

\ir /work/scripts/demo/production_model_qualification.sql

UPDATE promotion_shadow_rollback_proof proof
SET qualification_contract_hash = qualification.contract_hash
FROM production_model_qualification_proof qualification;

DO $body$
DECLARE
  proof promotion_shadow_rollback_proof%ROWTYPE;
  qualification_report_hash text;
  bad_decision_hash text;
BEGIN
  SELECT * INTO proof FROM promotion_shadow_rollback_proof;
  SELECT report_hash
  INTO qualification_report_hash
  FROM production_model_qualification_runs
  ORDER BY repeat_number
  LIMIT 1;
  BEGIN
    bad_decision_hash := otlet.record_workload_promotion_decision(
      contract_hash => proof.qualification_contract_hash,
      outcome => 'promote',
      evidence_hash => qualification_report_hash,
      evidence_summary => jsonb_build_object(
        'shadow_report_hash', qualification_report_hash,
        'non_authoritative', true
      ),
      reason => 'Reject non-shadow promotion evidence',
      qualification_run_hashes => ARRAY(
        SELECT run_hash
        FROM production_model_qualification_runs
        ORDER BY run_hash
      )
    );
    PERFORM otlet.activate_workload_promotion(
      bad_decision_hash,
      (SELECT baseline_revision_hash FROM evaluation_slice_proof)
    );
    RAISE EXCEPTION 'non-shadow evidence unexpectedly activated';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet workload promotion activation shadow comparison is not ready' THEN
      RAISE;
    END IF;
  END;
  UPDATE promotion_shadow_rollback_proof SET bad_evidence_blocked = true;
END
$body$;

UPDATE promotion_shadow_rollback_proof proof
SET decision_event_hash = otlet.record_workload_promotion_decision(
  contract_hash => proof.qualification_contract_hash,
  outcome => 'promote',
  evidence_hash => proof.shadow_report_hash,
  evidence_summary => jsonb_build_object(
    'shadow_report_hash', proof.shadow_report_hash,
    'shadow_run_hash', proof.shadow_run_hash,
    'non_authoritative', true,
    'same_input_snapshot', true
  ),
  reason => 'Activate the qualified candidate after shadow comparison',
  qualification_run_hashes => ARRAY(
    SELECT run_hash
    FROM production_model_qualification_runs
    ORDER BY run_hash
  ),
  ticket => 'OTLET-58'
);

DO $body$
DECLARE
  proof promotion_shadow_rollback_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM promotion_shadow_rollback_proof;
  BEGIN
    PERFORM otlet.activate_workload_promotion(
      proof.decision_event_hash,
      (SELECT candidate_revision_hash FROM evaluation_slice_proof)
    );
    RAISE EXCEPTION 'stale activation head unexpectedly accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet workload promotion activation head conflict' THEN
      RAISE;
    END IF;
  END;
  UPDATE promotion_shadow_rollback_proof SET stale_activation_blocked = true;
END
$body$;

DO $body$
BEGIN
  BEGIN
    PERFORM otlet.apply_workload_pack(
      (SELECT candidate_pack_hash FROM evaluation_slice_proof),
      (SELECT baseline_pack_spec_hash FROM evaluation_slice_proof),
      (SELECT baseline_revision_hash FROM evaluation_slice_proof),
      'Reject a governed pack without its decision',
      'OTLET-58-PACK'
    );
    RAISE EXCEPTION 'governed workload pack unexpectedly applied without a decision';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet governed workload pack requires a promotion decision event' THEN
      RAISE;
    END IF;
  END;
  UPDATE promotion_shadow_rollback_proof
  SET missing_pack_decision_blocked = true;
END
$body$;

UPDATE promotion_shadow_rollback_proof proof
SET pack_application_event_hash = otlet.apply_workload_pack(
  (SELECT candidate_pack_hash FROM evaluation_slice_proof),
  (SELECT baseline_pack_spec_hash FROM evaluation_slice_proof),
  (SELECT baseline_revision_hash FROM evaluation_slice_proof),
  'Apply the qualified evaluation slice pack',
  'OTLET-58-PACK',
  proof.decision_event_hash
);
UPDATE promotion_shadow_rollback_proof proof
SET repeated_pack_application_event_hash = otlet.apply_workload_pack(
  (SELECT candidate_pack_hash FROM evaluation_slice_proof),
  (SELECT baseline_pack_spec_hash FROM evaluation_slice_proof),
  (SELECT baseline_revision_hash FROM evaluation_slice_proof),
  'Apply the qualified evaluation slice pack',
  'OTLET-58-PACK',
  proof.decision_event_hash
);
UPDATE promotion_shadow_rollback_proof proof
SET activation_event_hash = application.governance_event_hash,
    repeated_activation_event_hash = repeated.governance_event_hash
FROM otlet.workload_pack_events application,
     otlet.workload_pack_events repeated
WHERE application.event_hash = proof.pack_application_event_hash
  AND repeated.event_hash = proof.repeated_pack_application_event_hash;

UPDATE promotion_shadow_rollback_proof proof
SET active_status_verified = EXISTS (
  SELECT 1
  FROM otlet.workload_promotion_status status
  WHERE status.activation_event_hash = proof.activation_event_hash
    AND status.promotion_decision_event_hash = proof.decision_event_hash
    AND status.shadow_contract_hash = proof.shadow_contract_hash
    AND status.shadow_run_hash = proof.shadow_run_hash
    AND status.shadow_report_hash = proof.shadow_report_hash
    AND status.promotion_state = 'active'
    AND status.rollback_ready
    AND status.activation_reason =
      'Activate the qualified candidate after shadow comparison'
    AND status.activation_ticket = 'OTLET-58'
    AND EXISTS (
      SELECT 1
      FROM otlet.workload_pack_status pack_status
      JOIN evaluation_slice_proof slice
        ON pack_status.pack_hash = slice.candidate_pack_hash
      JOIN otlet.workload_pack_events application
        ON application.event_hash = pack_status.application_event_hash
      JOIN otlet.administrative_change_events administrative
        ON administrative.event_id = application.administrative_event_id
      JOIN otlet.workload_acceptance_events activation
        ON activation.event_hash = application.governance_event_hash
      JOIN otlet.workload_revision_heads head
        ON head.task_name = application.task_name
      WHERE pack_status.application_event_hash =
            proof.pack_application_event_hash
        AND pack_status.promotion_activation_event_hash =
            proof.activation_event_hash
        AND pack_status.state = 'applied'
        AND NOT pack_status.configured_drift
        AND pack_status.rollback_ready
        AND application.event_kind = 'apply'
        AND application.application_pack_hash = slice.candidate_pack_hash
        AND application.pack_name = 'evaluation_slice_probe'
        AND application.task_name = 'evaluation_slice_probe_task'
        AND application.prior_pack_hash = otlet.workload_pack_hash(
          jsonb_set(slice.baseline_pack_definition, '{version}', '2'::jsonb)
        )
        AND application.result_pack_hash = slice.candidate_pack_hash
        AND application.prior_spec_hash = slice.baseline_pack_spec_hash
        AND application.result_spec_hash = slice.candidate_pack_spec_hash
        AND application.prior_definition = jsonb_set(
          slice.baseline_pack_definition,
          '{version}',
          '2'::jsonb
        )
        AND application.result_definition = slice.candidate_pack_definition
        AND application.prior_workload_revision_hash =
            slice.baseline_revision_hash
        AND application.result_workload_revision_hash =
            slice.candidate_revision_hash
        AND activation.event_kind = 'promotion_activation'
        AND activation.definition #>>
            '{payload,promotion_decision_event_hash}' =
            proof.decision_event_hash
        AND activation.definition #>> '{payload,task_name}' =
            application.task_name
        AND activation.definition #>>
            '{payload,prior_workload_revision_hash}' =
            slice.baseline_revision_hash
        AND activation.definition #>>
            '{payload,resulting_workload_revision_hash}' =
            slice.candidate_revision_hash
        AND administrative.object_type = 'workload_pack'
        AND administrative.object_name = 'evaluation_slice_probe'
        AND administrative.operation = 'apply'
        AND administrative.reason =
            'Apply the qualified evaluation slice pack'
        AND administrative.ticket = 'OTLET-58-PACK'
        AND otlet.export_workload_pack('evaluation_slice_probe', 2) =
            slice.candidate_pack_definition
        AND head.active_workload_revision_hash =
            slice.candidate_revision_hash
        AND head.previous_workload_revision_hash =
            slice.baseline_revision_hash
    )
);

SELECT otlet.set_task_lifecycle(
  'evaluation_slice_probe_task',
  'paused',
  (SELECT candidate_revision_hash FROM evaluation_slice_proof)
) \g /dev/null
SELECT otlet.set_task_lifecycle(
  'evaluation_slice_probe_task',
  'active',
  (SELECT candidate_revision_hash FROM evaluation_slice_proof)
) \g /dev/null
UPDATE promotion_shadow_rollback_proof
SET pause_resume_verified = EXISTS (
  SELECT 1
  FROM otlet.workload_revision_heads head
  JOIN evaluation_slice_proof slice
    ON head.task_name = 'evaluation_slice_probe_task'
  WHERE head.active_workload_revision_hash = slice.candidate_revision_hash
    AND head.previous_workload_revision_hash = slice.baseline_revision_hash
);

DO $body$
DECLARE
  proof promotion_shadow_rollback_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM promotion_shadow_rollback_proof;
  BEGIN
    PERFORM otlet.activate_workload_promotion(
      proof.decision_event_hash,
      (SELECT candidate_revision_hash FROM evaluation_slice_proof)
    );
    RAISE EXCEPTION 'conflicting activation retry unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet workload promotion activation retry conflicts' THEN
      RAISE;
    END IF;
  END;
  UPDATE promotion_shadow_rollback_proof SET activation_conflict_blocked = true;
END
$body$;

UPDATE promotion_shadow_rollback_proof proof
SET pack_rollback_event_hash = otlet.rollback_workload_pack(
  proof.pack_application_event_hash,
  (SELECT candidate_pack_spec_hash FROM evaluation_slice_proof),
  (SELECT candidate_revision_hash FROM evaluation_slice_proof),
  'Restore the prior active workload revision',
  'OTLET-58-ROLLBACK'
);
UPDATE promotion_shadow_rollback_proof proof
SET repeated_pack_rollback_event_hash = otlet.rollback_workload_pack(
  proof.pack_application_event_hash,
  (SELECT candidate_pack_spec_hash FROM evaluation_slice_proof),
  (SELECT candidate_revision_hash FROM evaluation_slice_proof),
  'Restore the prior active workload revision',
  'OTLET-58-ROLLBACK'
);
UPDATE promotion_shadow_rollback_proof proof
SET rollback_event_hash = rollback.governance_event_hash,
    repeated_rollback_event_hash = repeated.governance_event_hash
FROM otlet.workload_pack_events rollback,
     otlet.workload_pack_events repeated
WHERE rollback.event_hash = proof.pack_rollback_event_hash
  AND repeated.event_hash = proof.repeated_pack_rollback_event_hash;

UPDATE promotion_shadow_rollback_proof proof
SET rollback_status_verified = EXISTS (
  SELECT 1
  FROM otlet.workload_promotion_status status
  WHERE status.activation_event_hash = proof.activation_event_hash
    AND status.rollback_event_hash = proof.rollback_event_hash
    AND status.promotion_state = 'rolled_back'
    AND NOT status.rollback_ready
    AND status.rollback_reason = 'Restore the prior active workload revision'
    AND status.rollback_ticket = 'OTLET-58-ROLLBACK'
    AND EXISTS (
      SELECT 1
      FROM otlet.workload_pack_status pack_status
      JOIN evaluation_slice_proof slice
        ON pack_status.pack_hash = slice.candidate_pack_hash
      JOIN otlet.workload_pack_events rollback
        ON rollback.event_hash = pack_status.rollback_event_hash
      JOIN otlet.workload_pack_events application
        ON application.event_hash = rollback.rollback_of_event_hash
      JOIN otlet.administrative_change_events administrative
        ON administrative.event_id = rollback.administrative_event_id
      JOIN otlet.workload_acceptance_events governance
        ON governance.event_hash = rollback.governance_event_hash
      JOIN otlet.workload_revision_heads head
        ON head.task_name = rollback.task_name
      WHERE pack_status.rollback_event_hash = proof.pack_rollback_event_hash
        AND pack_status.promotion_rollback_event_hash =
            proof.rollback_event_hash
        AND pack_status.state = 'rolled_back'
        AND NOT pack_status.configured_drift
        AND NOT pack_status.rollback_ready
        AND pack_status.rollback_blocker = 'already_rolled_back'
        AND rollback.event_kind = 'rollback'
        AND rollback.application_pack_hash = slice.candidate_pack_hash
        AND rollback.predecessor_event_hash = application.event_hash
        AND rollback.rollback_of_event_hash = application.event_hash
        AND rollback.prior_pack_hash = slice.candidate_pack_hash
        AND rollback.result_pack_hash = application.prior_pack_hash
        AND rollback.prior_spec_hash = slice.candidate_pack_spec_hash
        AND rollback.result_spec_hash = slice.baseline_pack_spec_hash
        AND rollback.prior_definition = slice.candidate_pack_definition
        AND rollback.result_definition = jsonb_set(
          slice.baseline_pack_definition,
          '{version}',
          '2'::jsonb
        )
        AND rollback.prior_workload_revision_hash =
            slice.candidate_revision_hash
        AND rollback.result_workload_revision_hash =
            slice.baseline_revision_hash
        AND governance.event_kind = 'promotion_rollback'
        AND governance.definition #>>
            '{payload,promotion_activation_event_hash}' =
            proof.activation_event_hash
        AND governance.definition #>> '{payload,task_name}' =
            rollback.task_name
        AND governance.definition #>>
            '{payload,prior_workload_revision_hash}' =
            slice.candidate_revision_hash
        AND governance.definition #>>
            '{payload,resulting_workload_revision_hash}' =
            slice.baseline_revision_hash
        AND administrative.object_type = 'workload_pack'
        AND administrative.object_name = 'evaluation_slice_probe'
        AND administrative.operation = 'rollback'
        AND administrative.reason =
            'Restore the prior active workload revision'
        AND administrative.ticket = 'OTLET-58-ROLLBACK'
        AND otlet.export_workload_pack('evaluation_slice_probe', 2) =
            jsonb_set(
              slice.baseline_pack_definition,
              '{version}',
              '2'::jsonb
            )
        AND head.active_workload_revision_hash =
            slice.baseline_revision_hash
        AND head.previous_workload_revision_hash IS NULL
    )
);

DO $body$
DECLARE
  proof promotion_shadow_rollback_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM promotion_shadow_rollback_proof;
  BEGIN
    PERFORM otlet.rollback_workload_promotion(
      proof.activation_event_hash,
      (SELECT candidate_revision_hash FROM evaluation_slice_proof),
      'Conflicting rollback retry',
      'OTLET-58-ROLLBACK'
    );
    RAISE EXCEPTION 'conflicting rollback retry unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet workload promotion rollback retry conflicts' THEN
      RAISE;
    END IF;
  END;
  UPDATE promotion_shadow_rollback_proof SET rollback_conflict_blocked = true;
END
$body$;

CREATE TEMP TABLE promotion_shadow_rollback_contract ON COMMIT DROP AS
SELECT concat_ws('|',
  proof.shadow_ready,
  proof.shadow_non_authoritative,
  proof.bad_evidence_blocked,
  proof.stale_activation_blocked AND proof.missing_pack_decision_blocked,
  proof.raw_activation_blocked,
  proof.pack_application_event_hash =
      proof.repeated_pack_application_event_hash
    AND proof.activation_event_hash = proof.repeated_activation_event_hash
    AND proof.activation_conflict_blocked
    AND proof.active_status_verified
    AND proof.pause_resume_verified,
  proof.pack_rollback_event_hash = proof.repeated_pack_rollback_event_hash
    AND proof.rollback_event_hash = proof.repeated_rollback_event_hash
    AND proof.rollback_conflict_blocked
    AND proof.rollback_status_verified,
  (SELECT head.active_workload_revision_hash = slice.baseline_revision_hash
     AND head.previous_workload_revision_hash IS NULL
   FROM otlet.workload_revision_heads head
   JOIN evaluation_slice_proof slice
     ON head.task_name = 'evaluation_slice_probe_task'),
  EXISTS (
    SELECT 1
    FROM otlet.administrative_change_events event
    JOIN evaluation_slice_proof slice ON true
    WHERE event.object_type = 'task'
      AND event.object_name = 'evaluation_slice_probe_task'
      AND event.operation = 'rollback'
      AND event.old_revision_hash = slice.candidate_revision_hash
      AND event.new_revision_hash = slice.baseline_revision_hash
      AND event.reason = 'Restore the prior active workload revision'
      AND event.ticket = 'OTLET-58-ROLLBACK'
  ),
  NOT EXISTS (
    SELECT 1
    FROM otlet.evaluation_executions execution
    JOIN otlet.actions action ON action.job_id = execution.job_id
    WHERE execution.run_hash = proof.shadow_run_hash
  ),
  NOT pg_catalog.has_function_privilege(
    'public', 'otlet.activate_workload_promotion(text,text)', 'EXECUTE'
  )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.rollback_workload_promotion(text,text,text,text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.workload_shadow_comparison_status', 'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.workload_promotion_status', 'SELECT'
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
) AS contract
FROM promotion_shadow_rollback_proof proof;

SELECT pg_temp.assert_true(
  contract = 't|t|t|t|t|t|t|t|t|t|t|t',
  'promotion shadow and rollback contract mismatch: ' || contract
)
FROM promotion_shadow_rollback_contract;

SELECT 'promotion_shadow_rollback_contract=' || contract
FROM promotion_shadow_rollback_contract;

\ir /work/scripts/demo/quality_data_drift.sql
