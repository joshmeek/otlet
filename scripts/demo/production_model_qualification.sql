CREATE TEMP TABLE production_model_qualification_proof (
  contract_hash text,
  qualification_hash text,
  repeated_hash text,
  run_count integer NOT NULL DEFAULT 0,
  sample_count integer NOT NULL DEFAULT 0,
  probe_count integer NOT NULL DEFAULT 0,
  exact_retry boolean NOT NULL DEFAULT false,
  conflicting_retry_blocked boolean NOT NULL DEFAULT false,
  sample_immutable boolean NOT NULL DEFAULT false,
  probe_immutable boolean NOT NULL DEFAULT false,
  event_immutable boolean NOT NULL DEFAULT false,
  artifact_drift_closed boolean NOT NULL DEFAULT false
) ON COMMIT DROP;
INSERT INTO production_model_qualification_proof DEFAULT VALUES;

CREATE TEMP TABLE production_model_qualification_runs (
  repeat_number integer PRIMARY KEY,
  run_hash text UNIQUE NOT NULL,
  sample_hash text,
  report_hash text
) ON COMMIT DROP;

CREATE TEMP TABLE production_model_qualification_probes (
  probe_hash text PRIMARY KEY,
  selection_role text UNIQUE NOT NULL,
  job_id bigint UNIQUE NOT NULL
) ON COMMIT DROP;

DO $body$
DECLARE
  proof evaluation_slice_proof%ROWTYPE;
  eligible_members jsonb;
  qualification_thresholds jsonb;
BEGIN
  SELECT * INTO proof FROM evaluation_slice_proof;
  SELECT jsonb_agg(
    jsonb_build_object(
      'lineage_hash', fixture.lineage_hash,
      'case_hash', fixture.case_hash,
      'included', true
    ) ORDER BY fixture.lineage_hash
  )
  INTO eligible_members
  FROM evaluation_slice_cases fixture
  WHERE fixture.labeled;

  SELECT jsonb_object_agg(
    threshold.key,
    jsonb_set(
      jsonb_set(
        threshold.value,
        '{minimum_support}',
        '1'::jsonb
      ),
      '{value}',
      to_jsonb(CASE threshold.key
        WHEN 'candidate_recall' THEN 1::numeric
        WHEN 'false_trust' THEN 0::numeric
        WHEN 'latency' THEN 10::numeric
        WHEN 'database_impact' THEN 10000::numeric
        ELSE (threshold.value ->> 'value')::numeric
      END)
    )
  )
  INTO qualification_thresholds
  FROM jsonb_each(proof.thresholds) threshold;

  UPDATE production_model_qualification_proof
  SET contract_hash = otlet.register_workload_acceptance_contract(
    'evaluation_slice_probe_task',
    proof.candidate_revision_hash,
    proof.baseline_revision_hash,
    jsonb_build_object(
      'mode', 'full',
      'rule', jsonb_build_object(
        'kind', 'customer_representative',
        'basis', jsonb_build_array('expected_answer', 'source_table'),
        'eligible_members', eligible_members,
        'production_qualification', jsonb_build_object(
          'customer_representative', jsonb_build_object(
            'basis', 'Approved rows span both decision classes and source tables',
            'evidence_hash', otlet.identity_hash(
              'production_model_representative_evidence',
              eligible_members
            )
          ),
          'cancellation', jsonb_build_object('max_ms', 5000),
          'database_responsiveness', jsonb_build_object('max_ms', 1000)
        )
      )
    ),
    clock_timestamp() + interval '250 milliseconds',
    clock_timestamp() + interval '10.25 seconds',
    '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
    qualification_thresholds,
    proof.contract_hash
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
        SELECT contract_hash FROM production_model_qualification_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.02
)::double precision) \g /dev/null

INSERT INTO production_model_qualification_probes
SELECT probe_hash, selection_role, job_id
FROM otlet.start_production_model_cancellation_probes(
  (SELECT contract_hash FROM production_model_qualification_proof),
  'Prove live cancellation for every candidate role'
);

UPDATE otlet.jobs job
SET status = 'running',
    attempts = 1,
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
FROM production_model_qualification_probes probe
WHERE probe.job_id = job.id;

SELECT canceled.id
FROM production_model_qualification_probes probe
CROSS JOIN LATERAL otlet.request_job_cancellation(
  probe.job_id,
  'Production qualification cancellation probe'
) canceled
ORDER BY probe.selection_role \g /dev/null

SELECT canceled.id
FROM production_model_qualification_probes probe
JOIN otlet.jobs job ON job.id = probe.job_id
CROSS JOIN LATERAL otlet.cancel_job(
  probe.job_id,
  job.claim_token,
  'Production qualification cancellation probe'
) canceled
ORDER BY probe.selection_role \g /dev/null

INSERT INTO production_model_qualification_runs (repeat_number, run_hash)
SELECT repeat_number, otlet.start_replay_evaluation(
  (SELECT contract_hash FROM production_model_qualification_proof),
  ARRAY(
    SELECT fixture.case_hash
    FROM evaluation_slice_cases fixture
    WHERE fixture.labeled
    ORDER BY fixture.case_hash
  ),
  'production-model-qualification-' || repeat_number,
  'Production model qualification repeat ' || repeat_number
)
FROM generate_series(1, 3) repeat_number;

UPDATE otlet.jobs job
SET status = 'running',
    attempts = 1,
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
FROM otlet.evaluation_executions execution
JOIN production_model_qualification_runs run USING (run_hash)
WHERE execution.job_id = job.id;

UPDATE production_model_qualification_runs run
SET sample_hash = otlet.record_production_model_database_sample(
  run.run_hash,
  'Measure indexed PostgreSQL response while candidate evaluation is live'
);

DO $body$
DECLARE
  execution record;
  output jsonb;
  actions jsonb;
BEGIN
  FOR execution IN
    SELECT
      run.repeat_number,
      evaluation_execution.*,
      evaluation_case.expected_answer,
      job.claim_token,
      job.started_at
    FROM production_model_qualification_runs run
    JOIN otlet.evaluation_executions evaluation_execution
      ON evaluation_execution.run_hash = run.run_hash
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = evaluation_execution.case_hash
    JOIN otlet.jobs job ON job.id = evaluation_execution.job_id
    ORDER BY run.repeat_number, evaluation_execution.variant,
      evaluation_execution.case_hash
  LOOP
    output := jsonb_build_object(
      'decision', execution.expected_answer,
      'confidence', 'high'
    );
    actions := jsonb_build_array(jsonb_build_object(
      'type', 'review_flag',
      'body', jsonb_build_object('reason', 'production qualification fixture')
    ));
    IF execution.variant = 'baseline' THEN
      PERFORM otlet.complete_job(
        job_id => execution.job_id,
        output => output,
        raw_output => jsonb_build_object('output', output, 'actions', actions)::text,
        actions => actions,
        started_at => execution.started_at,
        trace_summary => jsonb_build_object(
          'generate_ms', execution.repeat_number,
          'worker_process_rss_bytes', 1000 + execution.repeat_number
        ),
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
        trace_summary => jsonb_build_object(
          'generate_ms', 1,
          'worker_process_rss_bytes', 2000 + execution.repeat_number
        ),
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
        trace_summary => jsonb_build_object(
          'generate_ms', execution.repeat_number,
          'worker_process_rss_bytes', 3000 + execution.repeat_number
        ),
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
        SELECT contract_hash FROM production_model_qualification_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.05
)::double precision) \g /dev/null

UPDATE production_model_qualification_runs run
SET report_hash = otlet.record_evaluation_slice_report(
  run.run_hash,
  '[]'::jsonb,
  'Record production qualification repeat ' || run.repeat_number
);

UPDATE production_model_qualification_proof proof
SET qualification_hash = otlet.record_production_model_qualification(
      proof.contract_hash,
      'Approve the fully proven candidate model roles'
    ),
    run_count = (SELECT count(*) FROM production_model_qualification_runs),
    sample_count = (SELECT count(*) FROM otlet.production_model_database_samples sample
      WHERE sample.run_hash IN (
        SELECT run_hash FROM production_model_qualification_runs
      )),
    probe_count = (SELECT count(*) FROM production_model_qualification_probes);

UPDATE production_model_qualification_proof proof
SET repeated_hash = otlet.record_production_model_qualification(
      proof.contract_hash,
      'Approve the fully proven candidate model roles'
    ),
    exact_retry = proof.qualification_hash = otlet.record_production_model_qualification(
      proof.contract_hash,
      'Approve the fully proven candidate model roles'
    );

DO $body$
BEGIN
  BEGIN
    PERFORM otlet.record_production_model_qualification(
      (SELECT contract_hash FROM production_model_qualification_proof),
      'Conflicting production qualification decision'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet production model qualification already has a different record' THEN
      RAISE;
    END IF;
    UPDATE production_model_qualification_proof
    SET conflicting_retry_blocked = true;
    RETURN;
  END;
  RAISE EXCEPTION 'conflicting production qualification retry unexpectedly succeeded';
END
$body$;

DO $body$
BEGIN
  BEGIN
    UPDATE otlet.production_model_database_samples
    SET latency_ms = latency_ms + 1
    WHERE sample_hash = (
      SELECT sample_hash FROM production_model_qualification_runs LIMIT 1
    );
  EXCEPTION WHEN OTHERS THEN
    UPDATE production_model_qualification_proof SET sample_immutable = true;
  END;
  BEGIN
    DELETE FROM otlet.production_model_cancellation_probes
    WHERE probe_hash = (
      SELECT probe_hash FROM production_model_qualification_probes LIMIT 1
    );
  EXCEPTION WHEN OTHERS THEN
    UPDATE production_model_qualification_proof SET probe_immutable = true;
  END;
  BEGIN
    UPDATE otlet.workload_acceptance_events
    SET definition = definition || '{"changed":true}'::jsonb
    WHERE event_hash = (
      SELECT qualification_hash FROM production_model_qualification_proof
    );
  EXCEPTION WHEN OTHERS THEN
    UPDATE production_model_qualification_proof SET event_immutable = true;
  END;
END
$body$;

SELECT otlet.register_model(
  'evaluation_slice_cheap',
  '/tmp/evaluation_slice_cheap_replacement.gguf',
  repeat('4', 64),
  jsonb_build_object(
    'sha256', repeat('4', 64),
    'bytes', 1,
    'source', 'repository-demo',
    'revision', 'evaluation_slice_cheap_replacement',
    'quantization', 'fixture',
    'license', 'fixture'
  ),
  4
) \g /dev/null

UPDATE production_model_qualification_proof
SET artifact_drift_closed = (
  SELECT count(*) = 2
    AND count(*) FILTER (WHERE production_approved) = 1
    AND bool_and(NOT production_approved) FILTER (
      WHERE selection_role = 'cheap'
    )
  FROM otlet.production_model_qualification_status
  WHERE qualification_event_hash = (
    SELECT qualification_hash FROM production_model_qualification_proof
  )
);

SELECT otlet.register_model(
  'evaluation_slice_cheap',
  '/tmp/evaluation_slice_cheap.gguf',
  repeat('2', 64),
  jsonb_build_object(
    'sha256', repeat('2', 64),
    'bytes', 1,
    'source', 'repository-demo',
    'revision', 'evaluation_slice_cheap',
    'quantization', 'fixture',
    'license', 'fixture'
  ),
  4
) \g /dev/null

CREATE TEMP TABLE production_model_qualification_contract ON COMMIT DROP AS
SELECT concat_ws('|',
  proof.run_count = 3
    AND proof.sample_count = 3
    AND proof.probe_count = 2,
  proof.qualification_hash = proof.repeated_hash
    AND proof.exact_retry
    AND proof.conflicting_retry_blocked,
  proof.sample_immutable
    AND proof.probe_immutable
    AND proof.event_immutable,
  (SELECT count(*) = 2
     AND bool_and(status.production_approved)
     AND count(DISTINCT status.selection_role) = 2
     AND count(DISTINCT status.model_identity_hash) = 2
   FROM otlet.production_model_qualification_status status
   WHERE status.qualification_event_hash = proof.qualification_hash),
  proof.artifact_drift_closed,
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.production_model_database_samples',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.production_model_cancellation_probes',
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.production_model_qualification_status', 'SELECT'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.record_production_model_database_sample(text,text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.start_production_model_cancellation_probes(text,text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.record_production_model_qualification(text,text,text)',
      'EXECUTE'
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
) AS contract
FROM production_model_qualification_proof proof;

SELECT pg_temp.assert_true(
  contract = 't|t|t|t|t|t|t',
  'production model qualification contract mismatch: ' || contract
)
FROM production_model_qualification_contract;

SELECT 'production_model_qualification_contract=' || contract
FROM production_model_qualification_contract;
