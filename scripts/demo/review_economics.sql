CREATE TEMP TABLE review_economics_proof (
  contract_hash text,
  run_hash text,
  evaluation_report_hash text,
  economics_report_hash text,
  repeated_report_hash text,
  reviewer_time jsonb,
  observations jsonb,
  malformed_declaration_blocked boolean NOT NULL DEFAULT false,
  sample_population_blocked boolean NOT NULL DEFAULT false,
  same_revision_blocked boolean NOT NULL DEFAULT false,
  pending_verified boolean NOT NULL DEFAULT false,
  malformed_observations_blocked boolean NOT NULL DEFAULT false,
  inconsistent_observations_blocked boolean NOT NULL DEFAULT false,
  insufficient_evidence_blocked boolean NOT NULL DEFAULT false,
  wrong_report_blocked boolean NOT NULL DEFAULT false,
  disposition_consistency_blocked boolean NOT NULL DEFAULT false,
  timestamp_blocked boolean NOT NULL DEFAULT false,
  review_order_blocked boolean NOT NULL DEFAULT false,
  conflicting_retry_blocked boolean NOT NULL DEFAULT false,
  immutable boolean NOT NULL DEFAULT false
) ON COMMIT DROP;
INSERT INTO review_economics_proof DEFAULT VALUES;

CREATE FUNCTION pg_temp.review_economics_observation_change(
  observations jsonb,
  observation_index integer,
  patch jsonb
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT jsonb_set(
    $1,
    ARRAY[$2::text],
    ($1 -> $2) || $3
  )
$function$;

CREATE TEMP TABLE review_economics_cases (
  fixture_id text PRIMARY KEY,
  expected_answer text NOT NULL,
  expected_confidence text NOT NULL,
  case_hash text UNIQUE,
  lineage_hash text UNIQUE
) ON COMMIT DROP;
INSERT INTO review_economics_cases (
  fixture_id,
  expected_answer,
  expected_confidence
) VALUES
  ('economics-a', 'approve', 'low'),
  ('economics-b', 'reject', 'high'),
  ('economics-f', 'approve', 'high'),
  ('economics-g', 'reject', 'high'),
  ('economics-r', 'approve', 'high'),
  ('economics-u', 'reject', 'high');

INSERT INTO public.otlet_demo_evaluation_slice_primary (
  id,
  review_state,
  shape_probe,
  protected_note
)
SELECT fixture_id, 'pending', '{"kind":"stable"}'::jsonb, 'DO_NOT_TOUCH'
FROM review_economics_cases;

SELECT pg_temp.assert_true(
  sum(otlet.run_task_subject('evaluation_slice_probe_task', fixture_id)) = 6,
  'review economics source rows did not queue once each'
)
FROM review_economics_cases;

UPDATE otlet.jobs
SET status = 'running',
    attempts = 1,
    started_at = clock_timestamp(),
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
WHERE task_name = 'evaluation_slice_probe_task'
  AND subject_id IN (SELECT fixture_id FROM review_economics_cases)
  AND execution_mode = 'production';

DO $body$
DECLARE
  saved_job otlet.jobs%ROWTYPE;
  saved_case review_economics_cases%ROWTYPE;
  saved_action_id bigint;
  saved_label_id bigint;
  saved_case_hash text;
BEGIN
  FOR saved_job IN
    SELECT job.*
    FROM otlet.jobs job
    WHERE job.task_name = 'evaluation_slice_probe_task'
      AND job.subject_id IN (SELECT fixture_id FROM review_economics_cases)
      AND job.execution_mode = 'production'
    ORDER BY job.subject_id
  LOOP
    SELECT * INTO saved_case
    FROM review_economics_cases
    WHERE fixture_id = saved_job.subject_id;
    PERFORM otlet.complete_job(
      job_id => saved_job.id,
      output => jsonb_build_object(
        'decision', saved_case.expected_answer,
        'confidence', 'high'
      ),
      raw_output => jsonb_build_object(
        'output', jsonb_build_object(
          'decision', saved_case.expected_answer,
          'confidence', 'high'
        ),
        'actions', jsonb_build_array(jsonb_build_object(
          'type', 'review_flag',
          'body', jsonb_build_object('reason', 'review economics label')
        ))
      )::text,
      actions => jsonb_build_array(jsonb_build_object(
        'type', 'review_flag',
        'body', jsonb_build_object('reason', 'review economics label')
      )),
      started_at => saved_job.started_at,
      trace_summary => '{
        "schema_validation_status":"passed",
        "generate_ms":1,
        "worker_process_rss_bytes":1000
      }'::jsonb,
      model_name => 'evaluation_slice_baseline',
      expected_claim_token => saved_job.claim_token
    );
    SELECT action.id INTO saved_action_id
    FROM otlet.actions action
    WHERE action.job_id = saved_job.id
      AND action.action_type = 'review_flag';
    SELECT label.id INTO saved_label_id
    FROM otlet.label_action(
      saved_action_id,
      expected_answer => saved_case.expected_answer,
      expected_confidence => saved_case.expected_confidence,
      expected_action_type => 'review_flag',
      reason => 'Review economics reference label',
      label_source => 'manual_correction'
    ) label;
    PERFORM otlet.adjudicate_eval_label(
      saved_label_id,
      'accepted',
      1.0,
      'Accepted review economics label'
    );
    saved_case_hash := otlet.register_evaluation_case(
      saved_label_id,
      'shadow',
      'Approved review economics snapshot'
    );
    UPDATE review_economics_cases stored
    SET case_hash = saved_case_hash,
        lineage_hash = evaluation_case.lineage_hash
    FROM otlet.evaluation_cases evaluation_case
    WHERE stored.fixture_id = saved_case.fixture_id
      AND evaluation_case.case_hash = saved_case_hash;
  END LOOP;
END
$body$;

DO $body$
DECLARE
  slice evaluation_slice_proof%ROWTYPE;
  quality quality_data_drift_proof%ROWTYPE;
  eligible_members jsonb;
  declaration jsonb;
  starts_at timestamptz;
  ends_at timestamptz;
BEGIN
  SELECT * INTO slice FROM evaluation_slice_proof;
  SELECT * INTO quality FROM quality_data_drift_proof;
  SELECT jsonb_agg(jsonb_build_object(
    'lineage_hash', economics_case.lineage_hash,
    'case_hash', economics_case.case_hash,
    'included', true
  ) ORDER BY economics_case.lineage_hash)
  INTO eligible_members
  FROM review_economics_cases economics_case;
  declaration := '{
    "format":"otlet.review_economics.v1",
    "cost_unit":"USD",
    "reviewer_cost_per_hour":60,
    "model_generation_cost_per_hour":3600,
    "minimum_support":2
  }'::jsonb;

  starts_at := clock_timestamp() + interval '500 milliseconds';
  ends_at := starts_at + interval '15 seconds';
  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'evaluation_slice_probe_task',
      slice.candidate_revision_hash,
      slice.baseline_revision_hash,
      jsonb_build_object(
        'mode', 'full',
        'rule', jsonb_build_object(
          'kind', 'review_economics',
          'eligible_members', eligible_members
        )
      ),
      starts_at,
      ends_at,
      jsonb_build_object(
        'name', 'paired_review_economics',
        'definition', declaration || '{"currency":"USD"}'::jsonb
      ),
      slice.thresholds,
      quality.contract_hash
    );
    RAISE EXCEPTION 'malformed review economics declaration unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics declaration is invalid' THEN
      RAISE;
    END IF;
    UPDATE review_economics_proof SET malformed_declaration_blocked = true;
  END;

  starts_at := clock_timestamp() + interval '500 milliseconds';
  ends_at := starts_at + interval '15 seconds';
  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'evaluation_slice_probe_task',
      slice.candidate_revision_hash,
      slice.baseline_revision_hash,
      jsonb_build_object(
        'mode', 'sample',
        'rule', jsonb_build_object(
          'kind', 'review_economics',
          'eligible_members', eligible_members
        )
      ),
      starts_at,
      ends_at,
      jsonb_build_object(
        'name', 'paired_review_economics',
        'definition', declaration
      ),
      slice.thresholds,
      quality.contract_hash
    );
    RAISE EXCEPTION 'sampled review economics population unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics requires an exact full manifest' THEN
      RAISE;
    END IF;
    UPDATE review_economics_proof SET sample_population_blocked = true;
  END;

  starts_at := clock_timestamp() + interval '500 milliseconds';
  ends_at := starts_at + interval '15 seconds';
  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'evaluation_slice_probe_task',
      slice.baseline_revision_hash,
      slice.baseline_revision_hash,
      jsonb_build_object(
        'mode', 'full',
        'rule', jsonb_build_object(
          'kind', 'review_economics',
          'eligible_members', eligible_members
        )
      ),
      starts_at,
      ends_at,
      jsonb_build_object(
        'name', 'paired_review_economics',
        'definition', declaration
      ),
      slice.thresholds,
      quality.contract_hash
    );
    RAISE EXCEPTION 'same-revision review economics contract unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics requires distinct revisions' THEN
      RAISE;
    END IF;
    UPDATE review_economics_proof SET same_revision_blocked = true;
  END;

  starts_at := clock_timestamp() + interval '500 milliseconds';
  ends_at := starts_at + interval '15 seconds';
  UPDATE review_economics_proof
  SET contract_hash = otlet.register_workload_acceptance_contract(
    'evaluation_slice_probe_task',
    slice.candidate_revision_hash,
    slice.baseline_revision_hash,
    jsonb_build_object(
      'mode', 'full',
      'rule', jsonb_build_object(
        'kind', 'review_economics',
        'eligible_members', eligible_members
      )
    ),
    starts_at,
    ends_at,
    jsonb_build_object(
      'name', 'paired_review_economics',
      'definition', declaration
    ),
    slice.thresholds,
    quality.contract_hash
  );
END
$body$;

UPDATE review_economics_proof proof
SET pending_verified = (
  SELECT status.status = 'insufficient_evidence'
    AND NOT status.evidence_ready
    AND status.report_hash IS NULL
    AND status.current_contract
  FROM otlet.review_economics_status status
  WHERE status.contract_hash = proof.contract_hash
);

SELECT pg_sleep(GREATEST(
  0,
  extract(epoch FROM (
    (
      SELECT contract.definition #>> '{observation_window,starts_at}'
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.contract_hash = (
        SELECT contract_hash FROM review_economics_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.02
)::double precision) \g /dev/null

UPDATE review_economics_proof proof
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
  'review-economics-v1',
  'Measure paired review economics against the declared baseline'
);

UPDATE otlet.jobs job
SET status = 'running',
    attempts = 1,
    started_at = clock_timestamp(),
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
FROM otlet.evaluation_executions execution
WHERE execution.run_hash = (SELECT run_hash FROM review_economics_proof)
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
      SELECT run_hash FROM review_economics_proof
    )
    ORDER BY evaluation_execution.variant, evaluation_case.subject_id
  LOOP
    output := jsonb_build_object(
      'decision', CASE
        WHEN execution.variant = 'candidate'
          AND execution.subject_id IN ('economics-g', 'economics-u')
          THEN 'approve'
        ELSE execution.expected_answer
      END,
      'confidence', 'high'
    );
    actions := jsonb_build_array(jsonb_build_object(
      'type', 'review_flag',
      'body', jsonb_build_object('reason', 'review economics fixture')
    ));
    IF execution.variant = 'baseline' THEN
      PERFORM otlet.complete_job(
        job_id => execution.job_id,
        output => output,
        raw_output => jsonb_build_object('output', output, 'actions', actions)::text,
        actions => actions,
        started_at => execution.started_at,
        trace_summary => jsonb_build_object(
          'generate_ms', 1,
          'worker_process_rss_bytes', 1000
        ),
        model_name => 'evaluation_slice_baseline',
        expected_claim_token => execution.claim_token
      );
    ELSIF execution.subject_id = 'economics-f' THEN
      PERFORM otlet.fail_job(
        job_id => execution.job_id,
        error => 'review economics runtime failure',
        raw_output => 'review economics runtime failure',
        started_at => execution.started_at,
        schema_validation_status => 'failed',
        trace_summary => '{
          "generate_ms":4,
          "worker_process_rss_bytes":2500
        }'::jsonb,
        model_name => 'evaluation_slice_cheap',
        selection_role => 'cheap',
        selection_status => 'failed',
        selection_reason => 'runtime_failed',
        candidate_output => NULL,
        expected_claim_token => execution.claim_token
      );
    ELSIF execution.subject_id = 'economics-g' THEN
      PERFORM otlet.record_model_attempt(
        execution.job_id,
        'evaluation_slice_cheap',
        output => '{"decision":"unclear","confidence":"high"}'::jsonb,
        raw_output => '{"decision":"unclear","confidence":"high"}',
        started_at => execution.started_at,
        trace_summary => '{
          "generate_ms":2,
          "worker_process_rss_bytes":2000
        }'::jsonb,
        selection_role => 'cheap',
        selection_status => 'rejected',
        selection_reason => 'abstained',
        expected_claim_token => execution.claim_token,
        actions => '[]'::jsonb
      );
      PERFORM otlet.complete_job(
        job_id => execution.job_id,
        output => output,
        raw_output => jsonb_build_object('output', output, 'actions', actions)::text,
        actions => actions,
        started_at => execution.started_at,
        trace_summary => '{
          "generate_ms":3,
          "worker_process_rss_bytes":3000
        }'::jsonb,
        model_name => 'evaluation_slice_strong',
        selection_role => 'strong',
        selection_reason => 'cheap_abstained',
        expected_claim_token => execution.claim_token
      );
    ELSE
      PERFORM otlet.complete_job(
        job_id => execution.job_id,
        output => output,
        raw_output => jsonb_build_object('output', output, 'actions', actions)::text,
        actions => actions,
        started_at => execution.started_at,
        trace_summary => '{
          "generate_ms":2,
          "worker_process_rss_bytes":2000
        }'::jsonb,
        model_name => 'evaluation_slice_cheap',
        selection_role => 'cheap',
        selection_reason => 'cheap_accepted',
        expected_claim_token => execution.claim_token
      );
    END IF;
  END LOOP;
END
$body$;

DO $body$
DECLARE
  starts_at timestamptz;
  ends_at timestamptz;
BEGIN
  SELECT
    (contract.definition #>> '{observation_window,starts_at}')::timestamptz,
    (contract.definition #>> '{observation_window,ends_at}')::timestamptz
  INTO starts_at, ends_at
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.contract_hash = (
    SELECT contract_hash FROM review_economics_proof
  );

  UPDATE review_economics_proof proof
  SET reviewer_time = (
    SELECT jsonb_agg(
      claim.value || jsonb_build_object(
        'evidence_hash', otlet.identity_hash(
          'review_economics_reviewer_time',
          claim.value
        )
      )
      ORDER BY claim.value ->> 'case_hash', claim.value ->> 'variant'
    )
    FROM (
      SELECT jsonb_build_object(
        'case_hash', execution.case_hash,
        'variant', execution.variant,
        'seconds', CASE
          WHEN execution.variant = 'baseline' THEN 60
          WHEN evaluation_case.subject_id = 'economics-r' THEN 60
          ELSE 180
        END,
        'observed_at', to_char(
          (job.finished_at + CASE execution.variant
            WHEN 'baseline' THEN interval '1 second'
            ELSE interval '2 seconds'
          END) AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        )
      ) AS value
      FROM otlet.evaluation_executions execution
      JOIN otlet.evaluation_cases evaluation_case
        ON evaluation_case.case_hash = execution.case_hash
      JOIN otlet.jobs job ON job.id = execution.job_id
      WHERE execution.run_hash = proof.run_hash
        AND (
          execution.variant = 'baseline'
            AND evaluation_case.subject_id
              IN ('economics-a', 'economics-b', 'economics-r')
          OR execution.variant = 'candidate'
            AND evaluation_case.subject_id IN ('economics-g', 'economics-r')
        )
    ) claim
  );

  UPDATE review_economics_proof proof
  SET observations = (
    SELECT jsonb_agg(
      claim.value
      ORDER BY claim.value ->> 'variant', claim.value ->> 'case_hash'
    )
    FROM (
      SELECT jsonb_build_object(
        'case_hash', execution.case_hash,
        'variant', execution.variant,
        'reported_disposition', CASE
          WHEN execution.variant = 'candidate'
            AND evaluation_case.subject_id = 'economics-f' THEN 'failed'
          WHEN execution.variant = 'candidate'
            AND evaluation_case.subject_id = 'economics-g' THEN 'corrected'
          WHEN execution.variant = 'candidate'
            AND evaluation_case.subject_id = 'economics-r' THEN 'rejected'
          WHEN execution.variant = 'candidate'
            AND evaluation_case.subject_id = 'economics-u' THEN 'unreviewed'
          ELSE 'accepted'
        END,
        'reported_downstream_success', NOT (
          execution.variant = 'baseline'
            AND evaluation_case.subject_id = 'economics-g'
          OR execution.variant = 'candidate'
            AND evaluation_case.subject_id
              IN ('economics-f', 'economics-r', 'economics-u')
        ),
        'reported_avoided_work_seconds', CASE
          WHEN execution.variant = 'baseline'
            AND evaluation_case.subject_id = 'economics-g' THEN 0
          WHEN execution.variant = 'baseline' THEN 60
          WHEN evaluation_case.subject_id = 'economics-g' THEN 180
          WHEN evaluation_case.subject_id
            IN ('economics-f', 'economics-r', 'economics-u')
            THEN 0
          ELSE 120
        END,
        'reported_at', to_char(
          (job.finished_at + CASE
            WHEN execution.variant = 'baseline'
              AND evaluation_case.subject_id
                IN ('economics-a', 'economics-b', 'economics-r')
              THEN interval '1250 milliseconds'
            WHEN execution.variant = 'candidate'
              AND evaluation_case.subject_id IN ('economics-g', 'economics-r')
              THEN interval '2250 milliseconds'
            ELSE interval '500 milliseconds'
          END) AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        )
      ) AS value
      FROM otlet.evaluation_executions execution
      JOIN otlet.evaluation_cases evaluation_case
        ON evaluation_case.case_hash = execution.case_hash
      JOIN otlet.jobs job ON job.id = execution.job_id
      WHERE execution.run_hash = proof.run_hash
    ) claim
  );

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements((SELECT reviewer_time FROM review_economics_proof))
      observation
    WHERE (observation ->> 'observed_at')::timestamptz < starts_at
       OR (observation ->> 'observed_at')::timestamptz >= ends_at
  ) THEN
    RAISE EXCEPTION 'review economics fixture exceeded its observation window';
  END IF;
END
$body$;

SELECT pg_sleep(GREATEST(
  0,
  extract(epoch FROM (
    (
      SELECT contract.definition #>> '{observation_window,ends_at}'
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.contract_hash = (
        SELECT contract_hash FROM review_economics_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.05
)::double precision) \g /dev/null

UPDATE review_economics_proof proof
SET evaluation_report_hash = otlet.record_evaluation_slice_report(
  proof.run_hash,
  proof.reviewer_time,
  'Record review economics evaluation evidence'
);

DO $body$
DECLARE
  proof review_economics_proof%ROWTYPE;
  changed jsonb;
  candidate_a_index integer;
  candidate_g_index integer;
  candidate_u_index integer;
  early_observed_at text;
  pre_review_reported_at text;
BEGIN
  SELECT * INTO proof FROM review_economics_proof;
  SELECT (item.ordinality - 1)::integer INTO candidate_a_index
  FROM jsonb_array_elements(proof.observations) WITH ORDINALITY item(value, ordinality)
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = item.value ->> 'case_hash'
  WHERE item.value ->> 'variant' = 'candidate'
    AND evaluation_case.subject_id = 'economics-a';
  SELECT (item.ordinality - 1)::integer INTO candidate_g_index
  FROM jsonb_array_elements(proof.observations) WITH ORDINALITY item(value, ordinality)
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = item.value ->> 'case_hash'
  WHERE item.value ->> 'variant' = 'candidate'
    AND evaluation_case.subject_id = 'economics-g';
  SELECT (item.ordinality - 1)::integer INTO candidate_u_index
  FROM jsonb_array_elements(proof.observations) WITH ORDINALITY item(value, ordinality)
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = item.value ->> 'case_hash'
  WHERE item.value ->> 'variant' = 'candidate'
    AND evaluation_case.subject_id = 'economics-u';
  BEGIN
    PERFORM otlet.record_review_economics_report(
      proof.contract_hash,
      proof.evaluation_report_hash,
      jsonb_set(proof.observations, '{0,extra}', 'true'::jsonb),
      'Reject malformed observations'
    );
    RAISE EXCEPTION 'malformed review economics observations unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics observations are invalid' THEN
      RAISE;
    END IF;
    UPDATE review_economics_proof SET malformed_observations_blocked = true;
  END;

  changed := pg_temp.review_economics_observation_change(
    proof.observations,
    candidate_a_index,
    '{"reported_disposition":"corrected"}'::jsonb
  );
  BEGIN
    PERFORM otlet.record_review_economics_report(
      proof.contract_hash,
      proof.evaluation_report_hash,
      changed,
      'Reject correction without reviewer evidence'
    );
    RAISE EXCEPTION 'inconsistent review economics observations unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics observation evidence is inconsistent' THEN
      RAISE;
    END IF;
    UPDATE review_economics_proof SET inconsistent_observations_blocked = true;
  END;

  changed := pg_temp.review_economics_observation_change(
    proof.observations,
    candidate_a_index,
    '{
      "reported_downstream_success":null,
      "reported_avoided_work_seconds":null
    }'::jsonb
  );
  BEGIN
    PERFORM otlet.record_review_economics_report(
      proof.contract_hash,
      proof.evaluation_report_hash,
      changed,
      'Reject incomplete downstream evidence'
    );
    RAISE EXCEPTION 'insufficient review economics evidence unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics evidence is insufficient' THEN
      RAISE;
    END IF;
    UPDATE review_economics_proof SET insufficient_evidence_blocked = true;
  END;

  changed := pg_temp.review_economics_observation_change(
    proof.observations,
    candidate_u_index,
    '{"reported_disposition":"accepted"}'::jsonb
  );
  BEGIN
    PERFORM otlet.record_review_economics_report(
      proof.contract_hash,
      proof.evaluation_report_hash,
      changed,
      'Reject accepted mismatched outcome'
    );
    RAISE EXCEPTION 'accepted mismatched economics outcome unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics observation evidence is inconsistent' THEN
      RAISE;
    END IF;
    UPDATE review_economics_proof SET disposition_consistency_blocked = true;
  END;

  SELECT to_char(
    (job.finished_at - interval '1 second') AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
  ) INTO early_observed_at
  FROM otlet.evaluation_executions execution
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = execution.case_hash
  JOIN otlet.jobs job ON job.id = execution.job_id
  WHERE execution.run_hash = proof.run_hash
    AND execution.variant = 'candidate'
    AND evaluation_case.subject_id = 'economics-a';
  changed := pg_temp.review_economics_observation_change(
    proof.observations,
    candidate_a_index,
    jsonb_build_object('reported_at', early_observed_at)
  );
  BEGIN
    PERFORM otlet.record_review_economics_report(
      proof.contract_hash,
      proof.evaluation_report_hash,
      changed,
      'Reject outcome evidence before completion'
    );
    RAISE EXCEPTION 'early review economics outcome unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics observation evidence is inconsistent' THEN
      RAISE;
    END IF;
    UPDATE review_economics_proof SET timestamp_blocked = true;
  END;

  SELECT to_char(
    (job.finished_at + interval '1 second') AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
  ) INTO pre_review_reported_at
  FROM otlet.evaluation_executions execution
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = execution.case_hash
  JOIN otlet.jobs job ON job.id = execution.job_id
  WHERE execution.run_hash = proof.run_hash
    AND execution.variant = 'candidate'
    AND evaluation_case.subject_id = 'economics-g';
  changed := pg_temp.review_economics_observation_change(
    proof.observations,
    candidate_g_index,
    jsonb_build_object('reported_at', pre_review_reported_at)
  );
  BEGIN
    PERFORM otlet.record_review_economics_report(
      proof.contract_hash,
      proof.evaluation_report_hash,
      changed,
      'Reject corrected outcome before review'
    );
    RAISE EXCEPTION 'pre-review economics outcome unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics observation evidence is inconsistent' THEN
      RAISE;
    END IF;
    UPDATE review_economics_proof SET review_order_blocked = true;
  END;

  BEGIN
    PERFORM otlet.record_review_economics_report(
      proof.contract_hash,
      (SELECT evaluation_report_hash FROM quality_data_drift_proof),
      proof.observations,
      'Reject a report from another contract'
    );
    RAISE EXCEPTION 'wrong review economics report unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics evaluation report is invalid' THEN
      RAISE;
    END IF;
    UPDATE review_economics_proof SET wrong_report_blocked = true;
  END;
END
$body$;

UPDATE review_economics_proof proof
SET economics_report_hash = otlet.record_review_economics_report(
  proof.contract_hash,
  proof.evaluation_report_hash,
  proof.observations,
  'Record paired review economics evidence'
);

UPDATE review_economics_proof proof
SET repeated_report_hash = otlet.record_review_economics_report(
  proof.contract_hash,
  proof.evaluation_report_hash,
  proof.observations,
  'Record paired review economics evidence'
);

DO $body$
BEGIN
  BEGIN
    PERFORM otlet.record_review_economics_report(
      (SELECT contract_hash FROM review_economics_proof),
      (SELECT evaluation_report_hash FROM review_economics_proof),
      (SELECT observations FROM review_economics_proof),
      'Conflicting review economics evidence'
    );
    RAISE EXCEPTION 'conflicting review economics retry unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
      'otlet review economics contract already has a different report' THEN
      RAISE;
    END IF;
    UPDATE review_economics_proof SET conflicting_retry_blocked = true;
  END;

  BEGIN
    UPDATE otlet.review_economics_reports
    SET reason = 'mutated';
    RAISE EXCEPTION 'review economics evidence unexpectedly mutated';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics evidence is append only' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    DELETE FROM otlet.review_economics_reports;
    RAISE EXCEPTION 'review economics evidence unexpectedly deleted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics evidence is append only' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    EXECUTE 'TRUNCATE TABLE otlet.review_economics_reports';
    RAISE EXCEPTION 'review economics evidence unexpectedly truncated';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review economics evidence is append only' THEN
      RAISE;
    END IF;
  END;
  UPDATE review_economics_proof SET immutable = true;
END
$body$;

CREATE TEMP TABLE review_economics_contract ON COMMIT DROP AS
SELECT concat_ws('|',
  proof.malformed_declaration_blocked,
  proof.sample_population_blocked,
  proof.same_revision_blocked,
  proof.pending_verified,
  proof.malformed_observations_blocked,
  proof.inconsistent_observations_blocked,
  proof.insufficient_evidence_blocked,
  proof.wrong_report_blocked,
  proof.disposition_consistency_blocked,
  proof.timestamp_blocked,
  proof.review_order_blocked,
  proof.economics_report_hash = proof.repeated_report_hash,
  proof.conflicting_retry_blocked,
  proof.immutable,
  (SELECT status.evidence_ready
      AND status.status = 'ready'
      AND status.current_contract
      AND status.cost_unit = 'USD'
      AND status.reviewer_cost_per_hour = 60
      AND status.model_generation_cost_per_hour = 3600
   FROM otlet.review_economics_status status
   WHERE status.contract_hash = proof.contract_hash),
  (SELECT report.definition #>> '{baseline_metrics,case_count}' = '6'
      AND report.definition #>> '{candidate_metrics,case_count}' = '6'
      AND (report.definition #>>
        '{baseline_metrics,evaluation_reviewer_touch,rate}')::numeric =
        0.5
      AND (report.definition #>>
        '{candidate_metrics,evaluation_reviewer_touch,rate}')::numeric =
        round(1::numeric / 3, 12)
      AND (report.definition #>>
        '{baseline_metrics,reported_correction,rate}')::numeric = 0
      AND (report.definition #>>
        '{candidate_metrics,reported_correction,rate}')::numeric = 0.5
      AND report.definition #>>
        '{candidate_metrics,reported_outcomes,accepted_or_corrected}' = '3'
      AND report.definition #>>
        '{candidate_metrics,reported_outcomes,rejected}' = '1'
      AND report.definition #>>
        '{candidate_metrics,reported_outcomes,unreviewed}' = '1'
      AND report.definition #>>
        '{candidate_metrics,reported_outcomes,failed}' = '1'
      AND (report.definition #>>
        '{comparisons,evaluation_reviewer_touch_rate,absolute_delta}')::numeric =
        round(-1::numeric / 6, 12)
      AND report.definition #>
        '{comparisons,reported_correction_rate,evidence_ready}' =
        'true'::jsonb
      AND (report.definition #>>
        '{comparisons,reported_correction_rate,absolute_delta}')::numeric = 0.5
   FROM otlet.review_economics_reports report
   WHERE report.report_hash = proof.economics_report_hash),
  (SELECT (report.definition #>>
        '{baseline_metrics,reviewer_time,minutes_per_reported_accepted_or_corrected}')::numeric
          = 0.5
      AND (report.definition #>>
        '{candidate_metrics,reviewer_time,minutes_per_reported_accepted_or_corrected}')::numeric
          = round(4::numeric / 3, 12)
      AND (report.definition #>>
        '{comparisons,reviewer_minutes_per_reported_accepted_or_corrected,absolute_delta}')::numeric
          = round(5::numeric / 6, 12)
      AND (report.definition #>>
        '{baseline_metrics,evaluation_review_wait,mean_seconds}')::numeric = 1
      AND (report.definition #>>
        '{candidate_metrics,evaluation_review_wait,mean_seconds}')::numeric = 2
      AND report.definition #>
        '{comparisons,evaluation_review_wait_mean_seconds,evidence_ready}' =
          'true'::jsonb
      AND (report.definition #>>
        '{comparisons,evaluation_review_wait_mean_seconds,absolute_delta}')::numeric
          = 1
   FROM otlet.review_economics_reports report
   WHERE report.report_hash = proof.economics_report_hash),
  (SELECT report.definition #>>
        '{baseline_metrics,machine,model_generation_milliseconds}' = '6'
      AND report.definition #>>
        '{candidate_metrics,machine,model_generation_milliseconds}' = '17'
      AND report.definition #>> '{candidate_metrics,machine,costed_measurement}' =
        'model_generation_time_only'
      AND report.definition #>>
        '{candidate_metrics,machine,process_rss_definition}' =
          'shared_worker_process_snapshot_not_costed'
      AND report.definition #> '{baseline_metrics,machine,attribution}' =
        jsonb_build_array(jsonb_build_object(
          'workload_revision_hash', run.baseline_workload_revision_hash,
          'model_name', 'evaluation_slice_baseline',
          'model_artifact_hash', repeat('1', 64),
          'runtime_name', 'linked_inproc',
          'route', 'direct',
          'case_count', 6,
          'receipt_count', 6,
          'model_generation_milliseconds', 6,
          'peak_process_rss_bytes', 1000
        ))
      AND report.definition #> '{candidate_metrics,machine,attribution}' =
        jsonb_build_array(
          jsonb_build_object(
            'workload_revision_hash', run.candidate_workload_revision_hash,
            'model_name', 'evaluation_slice_cheap',
            'model_artifact_hash', repeat('2', 64),
            'runtime_name', 'linked_inproc',
            'route', 'cheap',
            'case_count', 6,
            'receipt_count', 6,
            'model_generation_milliseconds', 14,
            'peak_process_rss_bytes', 2500
          ),
          jsonb_build_object(
            'workload_revision_hash', run.candidate_workload_revision_hash,
            'model_name', 'evaluation_slice_strong',
            'model_artifact_hash', repeat('3', 64),
            'runtime_name', 'linked_inproc',
            'route', 'strong',
            'case_count', 1,
            'receipt_count', 1,
            'model_generation_milliseconds', 3,
            'peak_process_rss_bytes', 3000
          )
        )
   FROM otlet.review_economics_reports report
   JOIN otlet.evaluation_runs run ON run.run_hash = proof.run_hash
   WHERE report.report_hash = proof.economics_report_hash),
  (SELECT (report.definition #>>
        '{baseline_metrics,reported_downstream,success_rate}')::numeric =
          round(5::numeric / 6, 12)
      AND (report.definition #>>
        '{candidate_metrics,reported_downstream,success_rate}')::numeric = 1
      AND (report.definition #>>
        '{baseline_metrics,reported_avoided_work,minutes_per_reported_accepted_or_corrected}')::numeric
          = round(5::numeric / 6, 12)
      AND (report.definition #>>
        '{candidate_metrics,reported_avoided_work,minutes_per_reported_accepted_or_corrected}')::numeric
          = round(7::numeric / 3, 12)
      AND (report.definition #>>
        '{comparisons,reported_downstream_success_rate,absolute_delta}')::numeric
          = round(1::numeric / 6, 12)
      AND (report.definition #>>
        '{comparisons,reported_avoided_work_minutes_per_reported_accepted_or_corrected,absolute_delta}')::numeric
          = 1.5
   FROM otlet.review_economics_reports report
   WHERE report.report_hash = proof.economics_report_hash),
  (SELECT (report.definition #>>
        '{baseline_metrics,estimated_cost,total}')::numeric = 3.006
      AND (report.definition #>>
        '{candidate_metrics,estimated_cost,total}')::numeric = 4.017
      AND (report.definition #>>
        '{baseline_metrics,estimated_cost,per_reported_accepted_or_corrected}')::numeric =
          0.501
      AND (report.definition #>>
        '{candidate_metrics,estimated_cost,per_reported_accepted_or_corrected}')::numeric =
          1.339
      AND (report.definition #>>
        '{comparisons,estimated_cost_per_reported_accepted_or_corrected,absolute_delta}')::numeric
          = 0.838
   FROM otlet.review_economics_reports report
   WHERE report.report_hash = proof.economics_report_hash),
  (SELECT COALESCE(
      (result.approval_diff ->> 'matches_expected')::boolean,
      false
    ) = false
      AND (result.decision_diff ->> 'answer_matches')::boolean
      AND (result.approval_diff ->> 'expected_action_present')::boolean
   FROM otlet.evaluation_results result
   JOIN otlet.evaluation_cases evaluation_case
     ON evaluation_case.case_hash = result.case_hash
   WHERE result.run_hash = proof.run_hash
     AND result.variant = 'candidate'
     AND evaluation_case.subject_id = 'economics-a'),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.review_economics_reports',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.review_economics_status', 'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname IN (
          'guard_review_economics_append',
          'review_economics_observation_manifest_valid',
          'review_economics_declaration_valid',
          'validate_review_economics_contract',
          'review_economics_comparison',
          'review_economics_metrics',
          'validate_review_economics_report',
          'record_review_economics_report'
        )
        AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
    ),
  (SELECT count(*) = 1
   FROM otlet.review_economics_reports report
   WHERE report.contract_hash = proof.contract_hash),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
) AS contract
FROM review_economics_proof proof;

SELECT pg_temp.assert_true(
  contract = 't|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t',
  'review economics contract mismatch: ' || contract
)
FROM review_economics_contract;

SELECT 'review_economics_contract=' || contract
FROM review_economics_contract;

\ir /work/scripts/demo/model_license_use_policy.sql
