log "Proving evaluation populations and exposure lineage"

psql_exec -qAt <<'SQL'
BEGIN;
SET LOCAL client_min_messages TO warning;

CREATE FUNCTION pg_temp.assert_true(condition boolean, failure text) RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  IF assert_true.condition IS NOT TRUE THEN
    RAISE EXCEPTION '%', assert_true.failure;
  END IF;
END
$function$;

CREATE TEMP TABLE evaluation_population_lineage_proof (
  baseline_revision_hash text,
  candidate_revision_hash text,
  contract_hash text,
  qualification_run_hash text,
  qualification_event_hash text,
  case_idempotent boolean NOT NULL DEFAULT false,
  invalid_population_rejected boolean NOT NULL DEFAULT false,
  duplicate_snapshot_rejected boolean NOT NULL DEFAULT false,
  mixed_population_rejected boolean NOT NULL DEFAULT false,
  incomplete_qualification_rejected boolean NOT NULL DEFAULT false,
  nonqualification_rejected boolean NOT NULL DEFAULT false,
  population_immutable boolean NOT NULL DEFAULT false
) ON COMMIT DROP;
INSERT INTO evaluation_population_lineage_proof DEFAULT VALUES;

CREATE TEMP TABLE evaluation_population_cases (
  population_kind text PRIMARY KEY,
  action_id bigint NOT NULL,
  label_id bigint NOT NULL,
  case_hash text NOT NULL UNIQUE
) ON COMMIT DROP;

CREATE TEMP TABLE evaluation_population_runs (
  population_kind text PRIMARY KEY,
  run_hash text NOT NULL UNIQUE
) ON COMMIT DROP;

SELECT otlet.register_model(
  'evaluation_population_baseline',
  '/tmp/evaluation-population-baseline.gguf',
  repeat('c', 64),
  jsonb_build_object(
    'sha256', repeat('c', 64),
    'bytes', 1,
    'source', 'repository-demo',
    'revision', 'population-baseline',
    'quantization', 'fixture',
    'license', 'fixture'
  ),
  4
) \g /dev/null
SELECT otlet.register_model(
  'evaluation_population_candidate',
  '/tmp/evaluation-population-candidate.gguf',
  repeat('d', 64),
  jsonb_build_object(
    'sha256', repeat('d', 64),
    'bytes', 1,
    'source', 'repository-demo',
    'revision', 'population-candidate',
    'quantization', 'fixture',
    'license', 'fixture'
  ),
  4
) \g /dev/null

CREATE TABLE public.otlet_demo_evaluation_population (
  id text PRIMARY KEY,
  population_kind text NOT NULL,
  review_state text NOT NULL,
  protected_note text NOT NULL
);
INSERT INTO public.otlet_demo_evaluation_population
VALUES
  ('tuning-1', 'tuning', 'pending', 'DO_NOT_TOUCH'),
  ('calibration-1', 'calibration', 'pending', 'DO_NOT_TOUCH'),
  ('shadow-1', 'shadow', 'pending', 'DO_NOT_TOUCH'),
  ('qualification-1', 'qualification', 'pending', 'DO_NOT_TOUCH');

SELECT otlet.create_watch(
  watch_name => 'evaluation_population_probe',
  kind => 'row',
  instruction => 'Return a decision, confidence, and one update_row recommendation',
  output_schema => '{
    "type":"object",
    "required":["decision","confidence"],
    "additionalProperties":false,
    "properties":{
      "decision":{"enum":["approve","reject"]},
      "confidence":{"enum":["high"]}
    }
  }'::jsonb,
  model_name => 'evaluation_population_baseline',
  table_name => 'public.otlet_demo_evaluation_population'::regclass,
  subject_column => 'id',
  runtime_options => '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  action_types => ARRAY['update_row'],
  decision_contract => '{
    "answer_field":"decision",
    "abstain_values":[],
    "confidence_field":"confidence",
    "accepted_confidence":["high"]
  }'::jsonb
) \g /dev/null
SELECT otlet.register_action_target(
  'evaluation_population_target',
  'public.otlet_demo_evaluation_population'::regclass,
  'id',
  ARRAY['review_state']::name[]
) \g /dev/null
SELECT otlet.register_action_workflow_policy(
  'evaluation_population_probe_task',
  'update_row',
  'evaluation_population_target',
  'bounded_mutation',
  'evaluated'
) \g /dev/null

UPDATE evaluation_population_lineage_proof
SET baseline_revision_hash = (
  SELECT active_workload_revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = 'evaluation_population_probe_task'
);

DO $body$
DECLARE
  fixture record;
  proof evaluation_population_lineage_proof%ROWTYPE;
  job_input jsonb;
  job_output jsonb := '{"decision":"approve","confidence":"high"}'::jsonb;
  job_actions jsonb;
  saved_job_id bigint;
  claim_token text;
  action_id bigint;
  label_id bigint;
  case_hash text;
BEGIN
  SELECT * INTO proof FROM evaluation_population_lineage_proof;
  FOR fixture IN
    SELECT *
    FROM public.otlet_demo_evaluation_population
    ORDER BY population_kind
  LOOP
    SELECT jsonb_build_object(
      '_otlet_mvcc', jsonb_build_object(
        'table', 'public.otlet_demo_evaluation_population',
        'subject_id', source.id,
        'ctid', source.ctid::text,
        'xmin', source.xmin::text
      ),
      'table', 'public.otlet_demo_evaluation_population',
      'row', to_jsonb(source)
    )
    INTO job_input
    FROM public.otlet_demo_evaluation_population source
    WHERE source.id = fixture.id;

    job_actions := jsonb_build_array(jsonb_build_object(
      'type', 'update_row',
      'body', jsonb_build_object(
        'target', 'evaluation_population_target',
        'identity', fixture.id,
        'changes', jsonb_build_object('review_state', fixture.population_kind)
      )
    ));

    INSERT INTO otlet.jobs (
      task_name,
      workload_revision_hash,
      subject_id,
      input,
      status,
      attempts,
      started_at,
      leased_until,
      claim_token
    ) VALUES (
      'evaluation_population_probe_task',
      proof.baseline_revision_hash,
      fixture.id,
      job_input,
      'running',
      1,
      now(),
      now() + interval '5 minutes',
      gen_random_uuid()::text
    )
    RETURNING id, otlet.jobs.claim_token INTO saved_job_id, claim_token;

    PERFORM otlet.complete_job(
      job_id => saved_job_id,
      output => job_output,
      raw_output => jsonb_build_object('output', job_output, 'actions', job_actions)::text,
      actions => job_actions,
      started_at => now(),
      trace_summary => jsonb_build_object(
        'schema_validation_status', 'passed',
        'generate_ms', 10,
        'mvcc', jsonb_build_object('table', 'public.otlet_demo_evaluation_population')
      ),
      model_name => 'evaluation_population_baseline',
      expected_claim_token => claim_token
    );

    SELECT action.id INTO action_id
    FROM otlet.actions action
    WHERE action.job_id = saved_job_id;
    SELECT label.id INTO label_id
    FROM otlet.label_action(
      action_id,
      expected_answer => 'approve',
      expected_confidence => 'high',
      expected_action_type => 'update_row',
      reason => 'Approved evaluation population fixture',
      label_source => 'manual_correction'
    ) label;
    case_hash := otlet.register_evaluation_case(
      label_id,
      fixture.population_kind,
      'Approved immutable population snapshot'
    );
    INSERT INTO evaluation_population_cases
    VALUES (fixture.population_kind, action_id, label_id, case_hash);
  END LOOP;
END
$body$;

DO $body$
DECLARE
  selection_case evaluation_population_cases%ROWTYPE;
  duplicate_label_id bigint;
  repeated_hash text;
BEGIN
  SELECT * INTO selection_case
  FROM evaluation_population_cases
  WHERE population_kind = 'tuning';

  repeated_hash := otlet.register_evaluation_case(
    selection_case.label_id,
    'tuning',
    'Approved immutable population snapshot'
  );
  UPDATE evaluation_population_lineage_proof
  SET case_idempotent = repeated_hash = selection_case.case_hash
    AND (SELECT count(*) FROM otlet.evaluation_cases) = 4;

  SELECT label.id INTO duplicate_label_id
  FROM otlet.label_action(
    selection_case.action_id,
    expected_answer => 'approve',
    expected_confidence => 'high',
    expected_action_type => 'update_row',
    reason => 'Duplicate logical snapshot probe',
    label_source => 'manual_correction'
  ) label;

  BEGIN
    PERFORM otlet.register_evaluation_case(
      duplicate_label_id,
      'invalid',
      'Invalid population probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation population must be tuning, calibration, shadow, or qualification' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_population_lineage_proof
  SET invalid_population_rejected = true;

  BEGIN
    PERFORM otlet.register_evaluation_case(
      duplicate_label_id,
      'qualification',
      'Cross-population duplicate probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation snapshot lineage is already registered as tuning' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_population_lineage_proof
  SET duplicate_snapshot_rejected = true;
END
$body$;

UPDATE otlet.tasks
SET instruction = 'Return a candidate decision, confidence, and one update_row recommendation',
    model_name = 'evaluation_population_candidate',
    runtime_options = '{"max_tokens":48,"reasoning":"off","inference_cache":false}'::jsonb,
    input_shaping = input_shaping || '{"strip_keys":["table"]}'::jsonb
WHERE name = 'evaluation_population_probe_task';
SELECT otlet.set_model_selection_policy(
  'evaluation_population_probe_task',
  'evaluation_population_candidate',
  'evaluation_population_baseline',
  '{
    "answer_field":"decision",
    "abstain_values":["reject"],
    "confidence_field":"confidence",
    "accepted_confidence":["high"]
  }'::jsonb
) \g /dev/null
SELECT otlet.register_action_workflow_policy(
  'evaluation_population_probe_task',
  'update_row',
  'evaluation_population_target',
  'bounded_mutation',
  'evaluated'
) \g /dev/null

UPDATE evaluation_population_lineage_proof
SET candidate_revision_hash = (
  SELECT active_workload_revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = 'evaluation_population_probe_task'
);
SELECT otlet.promote_workload_revision(
  'evaluation_population_probe_task',
  baseline_revision_hash,
  candidate_revision_hash
)
FROM evaluation_population_lineage_proof \g /dev/null

DO $body$
DECLARE
  proof evaluation_population_lineage_proof%ROWTYPE;
  thresholds jsonb;
BEGIN
  SELECT * INTO proof FROM evaluation_population_lineage_proof;
  SELECT jsonb_object_agg(
    category,
    jsonb_build_object(
      'metric', category,
      'statistic', 'rate',
      'operator', CASE
        WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 'gte'
        ELSE 'lte'
      END,
      'value', CASE
        WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 0.90
        ELSE 0.10
      END,
      'unit', 'ratio',
      'minimum_support', 1,
      'required', true
    )
  )
  INTO thresholds
  FROM unnest(ARRAY[
    'candidate_recall', 'false_trust', 'abstention', 'review_age',
    'review_minutes', 'freshness', 'latency', 'database_impact',
    'unit_cost', 'recovery', 'downstream_outcome'
  ]) category;

  UPDATE evaluation_population_lineage_proof
  SET contract_hash = otlet.register_workload_acceptance_contract(
    'evaluation_population_probe_task',
    proof.candidate_revision_hash,
    proof.baseline_revision_hash,
    '{"mode":"full","rule":{"kind":"all_declared_subjects"}}'::jsonb,
    statement_timestamp() + interval '1 hour',
    statement_timestamp() + interval '32 days',
    '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
    thresholds
  );
END
$body$;

DO $body$
DECLARE
  proof evaluation_population_lineage_proof%ROWTYPE;
  before_runs bigint;
  before_jobs bigint;
  before_executions bigint;
  item evaluation_population_cases%ROWTYPE;
  run_hash text;
BEGIN
  SELECT * INTO proof FROM evaluation_population_lineage_proof;
  SELECT count(*) INTO before_runs FROM otlet.evaluation_runs;
  SELECT count(*) INTO before_jobs FROM otlet.jobs;
  SELECT count(*) INTO before_executions FROM otlet.evaluation_executions;
  BEGIN
    PERFORM otlet.start_replay_evaluation(
      proof.contract_hash,
      ARRAY[
        (SELECT case_hash FROM evaluation_population_cases WHERE population_kind = 'tuning'),
        (SELECT case_hash FROM evaluation_population_cases WHERE population_kind = 'calibration')
      ],
      'evaluation-population-mixed',
      'Mixed population rejection probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation runs require one homogeneous case population' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_population_lineage_proof
  SET mixed_population_rejected =
    (SELECT count(*) FROM otlet.evaluation_runs) = before_runs
    AND (SELECT count(*) FROM otlet.jobs) = before_jobs
    AND (SELECT count(*) FROM otlet.evaluation_executions) = before_executions;

  FOR item IN
    SELECT * FROM evaluation_population_cases
    WHERE population_kind <> 'qualification'
    ORDER BY CASE population_kind
      WHEN 'tuning' THEN 1
      WHEN 'calibration' THEN 2
      ELSE 3
    END
  LOOP
    run_hash := otlet.start_replay_evaluation(
      proof.contract_hash,
      ARRAY[item.case_hash],
      'evaluation-population-' || item.population_kind,
      'Prove the ' || item.population_kind || ' evaluation population'
    );
    INSERT INTO evaluation_population_runs VALUES (item.population_kind, run_hash);
  END LOOP;
END
$body$;

SELECT format(
  'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  role_name
)
FROM (VALUES
  ('otlet_evaluation_population_candidate_worker'),
  ('otlet_evaluation_population_baseline_worker')
) role(role_name) \gexec
SELECT otlet.grant_portable_worker_access(
  role_name::regrole
)
FROM unnest(ARRAY[
  'otlet_evaluation_population_candidate_worker',
  'otlet_evaluation_population_baseline_worker'
]) role(role_name) \g /dev/null
SELECT otlet.register_portable_worker(
  'evaluation_population_candidate_worker',
  'otlet_evaluation_population_candidate_worker'::regrole,
  1,
  'evaluation_population_candidate',
  'reference-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'build', 'evaluation-population-proof',
    'transport', 'postgres',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null
SELECT otlet.register_portable_worker(
  'evaluation_population_baseline_worker',
  'otlet_evaluation_population_baseline_worker'::regrole,
  1,
  'evaluation_population_baseline',
  'reference-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'build', 'evaluation-population-proof',
    'transport', 'postgres',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null
SELECT runtime_identity_hash AS identity_hash
FROM otlet.portable_workers
WHERE worker_id = 'evaluation_population_candidate_worker'
\gset evaluation_population_candidate_
SELECT runtime_identity_hash AS identity_hash
FROM otlet.portable_workers
WHERE worker_id = 'evaluation_population_baseline_worker'
\gset evaluation_population_baseline_

SET LOCAL ROLE otlet_evaluation_population_candidate_worker;
SELECT incarnation_nonce
FROM otlet.portable_start_worker(
  'evaluation_population_candidate_worker',
  1,
  :'evaluation_population_candidate_identity_hash'
)
\gset evaluation_population_candidate_
CREATE TEMP TABLE evaluation_population_portable_cheap_claim ON COMMIT DROP AS
SELECT *
FROM otlet.portable_claim_jobs(
  'evaluation_population_candidate_worker',
  1,
  :'evaluation_population_candidate_identity_hash',
  :'evaluation_population_candidate_incarnation_nonce',
  1048576,
  4,
  1
);
SELECT pg_temp.assert_true(
  count(*) = 1 AND bool_and(selection_role = 'cheap'),
  'portable cheap evaluation claim was not created exactly once'
)
FROM evaluation_population_portable_cheap_claim;
SELECT *
FROM otlet.portable_complete_job(
  'evaluation_population_candidate_worker',
  1,
  :'evaluation_population_candidate_identity_hash',
  :'evaluation_population_candidate_incarnation_nonce',
  (SELECT job_id FROM evaluation_population_portable_cheap_claim),
  (SELECT claim_token FROM evaluation_population_portable_cheap_claim),
  '{"decision":"reject","confidence":"high"}'::jsonb,
  '{"output":{"decision":"reject","confidence":"high"},"actions":[]}',
  '[]'::jsonb
) \g /dev/null
RESET ROLE;

SET LOCAL ROLE otlet_evaluation_population_baseline_worker;
SELECT incarnation_nonce
FROM otlet.portable_start_worker(
  'evaluation_population_baseline_worker',
  1,
  :'evaluation_population_baseline_identity_hash'
)
\gset evaluation_population_baseline_
CREATE TEMP TABLE evaluation_population_portable_claim ON COMMIT DROP AS
SELECT *
FROM otlet.portable_claim_jobs(
  'evaluation_population_baseline_worker',
  1,
  :'evaluation_population_baseline_identity_hash',
  :'evaluation_population_baseline_incarnation_nonce',
  1048576,
  4,
  4
);
SELECT canceled.*
FROM evaluation_population_portable_claim claim
CROSS JOIN LATERAL otlet.portable_cancel_job(
  'evaluation_population_baseline_worker',
  1,
  :'evaluation_population_baseline_identity_hash',
  :'evaluation_population_baseline_incarnation_nonce',
  claim.job_id,
  claim.claim_token,
  'Portable exposure proof complete'
) canceled \g /dev/null
CREATE TEMP TABLE evaluation_population_portable_routed_claim ON COMMIT DROP AS
SELECT *
FROM otlet.portable_claim_jobs(
  'evaluation_population_baseline_worker',
  1,
  :'evaluation_population_baseline_identity_hash',
  :'evaluation_population_baseline_incarnation_nonce',
  1048576,
  4,
  1
);
SELECT canceled.*
FROM evaluation_population_portable_routed_claim claim
CROSS JOIN LATERAL otlet.portable_cancel_job(
  'evaluation_population_baseline_worker',
  1,
  :'evaluation_population_baseline_identity_hash',
  :'evaluation_population_baseline_incarnation_nonce',
  claim.job_id,
  claim.claim_token,
  'Portable routed exposure proof complete'
) canceled \g /dev/null
RESET ROLE;
SELECT pg_temp.assert_true(
  count(*) = 4
    AND count(*) FILTER (WHERE selection_role = 'strong') = 1,
  'portable strong evaluation claim was not linked to its routed attempt: ' ||
    string_agg(selection_role || ':' || attempt_index::text, ',' ORDER BY job_id)
)
FROM (
  SELECT job_id, selection_role, attempt_index
  FROM evaluation_population_portable_claim
  UNION ALL
  SELECT job_id, selection_role, attempt_index
  FROM evaluation_population_portable_routed_claim
) claim;

DO $body$
DECLARE
  proof evaluation_population_lineage_proof%ROWTYPE;
  nonqualification_run record;
  qualification_case_hash text;
BEGIN
  SELECT * INTO proof FROM evaluation_population_lineage_proof;
  SELECT case_hash INTO qualification_case_hash
  FROM evaluation_population_cases
  WHERE population_kind = 'qualification';
  proof.qualification_run_hash := otlet.start_replay_evaluation(
    proof.contract_hash,
    ARRAY[qualification_case_hash],
    'evaluation-population-qualification',
    'Prove the qualification evaluation population'
  );
  INSERT INTO evaluation_population_runs
  VALUES ('qualification', proof.qualification_run_hash);
  UPDATE evaluation_population_lineage_proof
  SET qualification_run_hash = proof.qualification_run_hash;

  FOR nonqualification_run IN
    SELECT population_kind, run_hash
    FROM evaluation_population_runs
    WHERE population_kind <> 'qualification'
    ORDER BY population_kind
  LOOP
    BEGIN
      PERFORM otlet.record_workload_promotion_decision(
        contract_hash => proof.contract_hash,
        outcome => 'promote',
        evidence_hash => otlet.identity_hash(
          'evaluation_population_lineage_evidence',
          jsonb_build_object('run_hash', nonqualification_run.run_hash)
        ),
        evidence_summary => jsonb_build_object(
          'status', 'nonqualification_probe',
          'population_kind', nonqualification_run.population_kind
        ),
        reason => 'Nonqualification promotion rejection probe',
        qualification_run_hashes => ARRAY[nonqualification_run.run_hash]
      );
      RAISE EXCEPTION 'negative probe unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'otlet workload promotion decision references a nonqualification run' THEN
        RAISE;
      END IF;
    END;
  END LOOP;
  UPDATE evaluation_population_lineage_proof SET nonqualification_rejected = true;

  BEGIN
    PERFORM otlet.record_workload_promotion_decision(
      contract_hash => proof.contract_hash,
      outcome => 'promote',
      evidence_hash => otlet.identity_hash(
        'evaluation_population_lineage_evidence',
        jsonb_build_object('run_hash', proof.qualification_run_hash)
      ),
      evidence_summary => '{"status":"incomplete_probe"}'::jsonb,
      reason => 'Incomplete qualification rejection probe',
      qualification_run_hashes => ARRAY[proof.qualification_run_hash]
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet workload promotion qualification run is incomplete' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_population_lineage_proof
  SET incomplete_qualification_rejected = true;
END
$body$;

SELECT 1
FROM otlet.evaluation_executions execution
JOIN evaluation_population_runs run ON run.run_hash = execution.run_hash
CROSS JOIN LATERAL otlet.request_job_cancellation(
  execution.job_id,
  'Nonqualification exposure proof complete'
) canceled
WHERE run.population_kind <> 'qualification' \g /dev/null

CREATE TEMP TABLE evaluation_population_baseline_claim ON COMMIT DROP AS
SELECT * FROM otlet.claim_jobs('evaluation_population_baseline', 1);
CREATE TEMP TABLE evaluation_population_candidate_claim ON COMMIT DROP AS
SELECT * FROM otlet.claim_jobs('evaluation_population_candidate', 1);

DO $body$
DECLARE
  baseline_claim otlet.jobs%ROWTYPE;
  candidate_claim otlet.jobs%ROWTYPE;
  job_output jsonb;
  job_actions jsonb;
  job_prompt_hash text;
BEGIN
  IF (SELECT count(*) FROM evaluation_population_baseline_claim) <> 1
     OR (SELECT count(*) FROM evaluation_population_candidate_claim) <> 1 THEN
    RAISE EXCEPTION 'qualification jobs were not claimed exactly once';
  END IF;
  SELECT * INTO baseline_claim FROM evaluation_population_baseline_claim;
  SELECT * INTO candidate_claim FROM evaluation_population_candidate_claim;

  job_output := '{"decision":"approve","confidence":"high"}'::jsonb;
  job_actions := '[{
    "type":"update_row",
    "body":{
      "target":"evaluation_population_target",
      "identity":"qualification-1",
      "changes":{"review_state":"baseline"}
    }
  }]'::jsonb;
  SELECT otlet.portable_prompt_hash(
    revision.definition #>> '{task,instruction}',
    revision.definition #> '{task,output_schema}',
    baseline_claim.input,
    revision.definition #> '{runtime,effective_options}',
    revision.definition #> '{task,decision_contract}'
  ) INTO job_prompt_hash
  FROM otlet.workload_revisions revision
  WHERE revision.workload_revision_hash = baseline_claim.workload_revision_hash;
  PERFORM otlet.complete_job(
    job_id => baseline_claim.id,
    output => job_output,
    raw_output => jsonb_build_object('output', job_output, 'actions', job_actions)::text,
    actions => job_actions,
    prompt_hash => job_prompt_hash,
    started_at => baseline_claim.started_at,
    trace_summary => '{"schema_validation_status":"passed","generate_ms":20}'::jsonb,
    model_name => 'evaluation_population_baseline',
    expected_claim_token => baseline_claim.claim_token
  );

  job_output := '{"decision":"reject","confidence":"high"}'::jsonb;
  job_actions := '[{
    "type":"update_row",
    "body":{
      "target":"evaluation_population_target",
      "identity":"qualification-1",
      "changes":{"review_state":"candidate"}
    }
  }]'::jsonb;
  SELECT otlet.portable_prompt_hash(
    revision.definition #>> '{task,instruction}',
    revision.definition #> '{task,output_schema}',
    candidate_claim.input,
    revision.definition #> '{runtime,effective_options}',
    revision.definition #> '{task,decision_contract}'
  ) INTO job_prompt_hash
  FROM otlet.workload_revisions revision
  WHERE revision.workload_revision_hash = candidate_claim.workload_revision_hash;
  PERFORM otlet.complete_job(
    job_id => candidate_claim.id,
    output => job_output,
    raw_output => jsonb_build_object('output', job_output, 'actions', job_actions)::text,
    actions => job_actions,
    prompt_hash => job_prompt_hash,
    started_at => candidate_claim.started_at,
    trace_summary => '{"schema_validation_status":"passed","generate_ms":30}'::jsonb,
    model_name => 'evaluation_population_candidate',
    expected_claim_token => candidate_claim.claim_token
  );
END
$body$;

UPDATE evaluation_population_lineage_proof proof
SET qualification_event_hash = otlet.record_workload_promotion_decision(
  contract_hash => proof.contract_hash,
  outcome => 'promote',
  evidence_hash => otlet.identity_hash(
    'evaluation_population_lineage_evidence',
    jsonb_build_object('run_hash', proof.qualification_run_hash)
  ),
  evidence_summary => '{"status":"qualification_complete"}'::jsonb,
  reason => 'Completed qualification replay proof',
  qualification_run_hashes => ARRAY[proof.qualification_run_hash]
);

DO $body$
DECLARE
  qualification_case_hash text;
BEGIN
  SELECT case_hash INTO qualification_case_hash
  FROM evaluation_population_cases
  WHERE population_kind = 'qualification';
  BEGIN
    UPDATE otlet.evaluation_cases
    SET population_kind = 'tuning'
    WHERE case_hash = qualification_case_hash;
    RAISE EXCEPTION 'evaluation population unexpectedly changed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation evidence is append only' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_population_lineage_proof SET population_immutable = true;
END
$body$;

CREATE TEMP TABLE evaluation_population_lineage_contract ON COMMIT DROP AS
WITH proof AS (
  SELECT * FROM evaluation_population_lineage_proof
), exposure AS (
  SELECT status.*
  FROM otlet.evaluation_exposure_status status
  WHERE status.case_hash IN (SELECT case_hash FROM evaluation_population_cases)
), expected_context AS (
  SELECT
    run.run_hash,
    run.contract_hash,
    evaluation_case.population_kind,
    evaluation_case.lineage_hash,
    evaluation_case.case_hash,
    execution.variant,
    execution.workload_revision_hash,
    execution.job_id,
    evaluation_case.shaped_input,
    revision.definition AS revision_definition,
    contract.definition AS contract_definition
  FROM otlet.evaluation_executions execution
  JOIN otlet.evaluation_runs run ON run.run_hash = execution.run_hash
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = execution.case_hash
  JOIN otlet.workload_revisions revision
    ON revision.workload_revision_hash = execution.workload_revision_hash
  JOIN otlet.workload_acceptance_contracts contract
    ON contract.contract_hash = run.contract_hash
  WHERE execution.run_hash IN (SELECT run_hash FROM evaluation_population_runs)
), expected_exposure AS (
  SELECT
    'source'::text AS exposure_stage,
    evaluation_case.population_kind,
    evaluation_case.lineage_hash,
    evaluation_case.case_hash,
    NULL::text AS contract_hash,
    NULL::text AS run_hash,
    NULL::text AS variant,
    evaluation_case.workload_revision_hash,
    NULL::bigint AS job_id,
    NULL::bigint AS receipt_id,
    NULL::integer AS attempt_index,
    'source'::text AS component_kind,
    'approved_shaped_snapshot'::text AS component_name,
    evaluation_case.shaped_input_hash AS component_hash,
    NULL::text AS selection_role
  FROM otlet.evaluation_cases evaluation_case
  WHERE evaluation_case.case_hash IN (SELECT case_hash FROM evaluation_population_cases)
  UNION ALL
  SELECT
    'scheduled',
    context.population_kind,
    context.lineage_hash,
    context.case_hash,
    context.contract_hash,
    context.run_hash,
    context.variant,
    context.workload_revision_hash,
    context.job_id,
    NULL::bigint,
    NULL::integer,
    component.kind,
    component.name,
    component.hash,
    component.selection_role
  FROM expected_context context
  CROSS JOIN LATERAL (
    SELECT
      'model'::text,
      model.role,
      otlet.identity_hash(
        'model_identity',
        jsonb_build_object(
          'name', model.definition ->> 'name',
          'artifact_hash', model.definition ->> 'artifact_hash',
          'artifact_identity', model.definition -> 'artifact_identity'
        )
      ),
      model.role
    FROM jsonb_each(context.revision_definition -> 'models') model(role, definition)
    WHERE jsonb_typeof(model.definition) = 'object'
    UNION ALL
    SELECT
      'prompt',
      'portable_prompt_v1',
      otlet.identity_text_hash('evaluation_prompt_exposure', prompt.hash),
      NULL::text
    FROM LATERAL (
      SELECT otlet.portable_prompt_hash(
        context.revision_definition #>> '{task,instruction}',
        context.revision_definition #> '{task,output_schema}',
        context.shaped_input,
        context.revision_definition #> '{runtime,effective_options}',
        context.revision_definition #> '{task,decision_contract}'
      ) AS hash
    ) prompt
    UNION ALL
    SELECT
      'threshold',
      threshold.name,
      otlet.identity_hash(
        'evaluation_threshold_exposure',
        jsonb_build_object('name', threshold.name, 'definition', threshold.definition)
      ),
      NULL::text
    FROM jsonb_each(context.contract_definition -> 'thresholds') threshold(name, definition)
    UNION ALL
    SELECT
      'policy',
      policy.name,
      otlet.identity_hash(
        'evaluation_policy_exposure',
        jsonb_build_object('name', policy.name, 'definition', policy.definition)
      ),
      NULL::text
    FROM (VALUES
      ('decision_contract', context.revision_definition #> '{task,decision_contract}'),
      ('selection', context.revision_definition -> 'selection'),
      ('action_policies', context.revision_definition -> 'action_policies')
    ) policy(name, definition)
  ) component(kind, name, hash, selection_role)
  UNION ALL
  SELECT
    'portable_claim',
    context.population_kind,
    context.lineage_hash,
    context.case_hash,
    context.contract_hash,
    context.run_hash,
    context.variant,
    context.workload_revision_hash,
    context.job_id,
    receipt_link.receipt_id,
    COALESCE(linked_receipt.attempt_index, claim.attempt_index),
    component.kind,
    component.name,
    component.hash,
    claim.selection_role
  FROM expected_context context
  JOIN otlet.portable_claims claim ON claim.job_id = context.job_id
  LEFT JOIN otlet.portable_receipt_links receipt_link
    ON receipt_link.claim_id = claim.id
  LEFT JOIN otlet.inference_receipts linked_receipt
    ON linked_receipt.id = receipt_link.receipt_id
  CROSS JOIN LATERAL (
    SELECT
      'model'::text,
      claim.selection_role,
      otlet.identity_hash(
        'model_identity',
        jsonb_build_object(
          'name', model.definition ->> 'name',
          'artifact_hash', model.definition ->> 'artifact_hash',
          'artifact_identity', model.definition -> 'artifact_identity'
        )
      )
    FROM LATERAL (
      SELECT context.revision_definition -> 'models' -> claim.selection_role AS definition
    ) model
    UNION ALL
    SELECT
      'prompt'::text,
      'portable_prompt_v1'::text,
      otlet.identity_text_hash('evaluation_prompt_exposure', prompt.hash)
    FROM LATERAL (
      SELECT otlet.portable_prompt_hash(
        context.revision_definition #>> '{task,instruction}',
        context.revision_definition #> '{task,output_schema}',
        context.shaped_input,
        context.revision_definition #> '{runtime,effective_options}',
        context.revision_definition #> '{task,decision_contract}'
      ) AS hash
    ) prompt
  ) component(kind, name, hash)
  UNION ALL
  SELECT
    'attempt',
    context.population_kind,
    context.lineage_hash,
    context.case_hash,
    context.contract_hash,
    context.run_hash,
    context.variant,
    context.workload_revision_hash,
    context.job_id,
    receipt.id,
    receipt.attempt_index,
    component.kind,
    component.name,
    component.hash,
    receipt.selection_role
  FROM expected_context context
  JOIN otlet.inference_receipts receipt ON receipt.job_id = context.job_id
  CROSS JOIN LATERAL (VALUES
    (
      'model'::text,
      receipt.selection_role,
      receipt.model_identity_hash
    ),
    (
      'prompt'::text,
      'portable_prompt_v1'::text,
      otlet.identity_text_hash('evaluation_prompt_exposure', receipt.prompt_hash)
    )
  ) component(kind, name, hash)
  WHERE component.kind <> 'prompt' OR receipt.prompt_hash IS NOT NULL
  UNION ALL
  SELECT
    'result',
    context.population_kind,
    context.lineage_hash,
    context.case_hash,
    context.contract_hash,
    context.run_hash,
    context.variant,
    context.workload_revision_hash,
    context.job_id,
    result.receipt_id,
    receipt.attempt_index,
    'result',
    result.variant,
    result.result_hash,
    receipt.selection_role
  FROM expected_context context
  JOIN otlet.evaluation_results result ON result.job_id = context.job_id
  JOIN otlet.inference_receipts receipt ON receipt.id = result.receipt_id
)
SELECT concat_ws('|',
  (SELECT count(*) = 4
     AND count(DISTINCT population_kind) = 4
     AND count(DISTINCT lineage_hash) = 4
     AND bool_and(lineage_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$')
     AND bool_and(lineage_hash = otlet.identity_hash(
       'evaluation_case_lineage',
       jsonb_strip_nulls(jsonb_build_object(
         'task_name', task_name,
         'subject_id', subject_id,
         'source_table', source_table,
         'source_hash', source_hash,
         'shaped_input_hash', shaped_input_hash
       ))
     ))
   FROM otlet.evaluation_cases),
  (SELECT case_idempotent
     AND invalid_population_rejected
     AND duplicate_snapshot_rejected
     AND mixed_population_rejected
   FROM proof),
  (SELECT count(*) = 4 AND count(DISTINCT population_kind) = 4
   FROM (
     SELECT execution.run_hash, min(evaluation_case.population_kind) AS population_kind
     FROM otlet.evaluation_executions execution
     JOIN otlet.evaluation_cases evaluation_case
       ON evaluation_case.case_hash = execution.case_hash
     WHERE execution.run_hash IN (SELECT run_hash FROM evaluation_population_runs)
     GROUP BY execution.run_hash
     HAVING count(DISTINCT evaluation_case.population_kind) = 1
   ) classified_run),
  (SELECT count(*) = 6 AND bool_and(job.status = 'canceled')
   FROM otlet.evaluation_executions execution
   JOIN otlet.jobs job ON job.id = execution.job_id
   JOIN evaluation_population_runs run ON run.run_hash = execution.run_hash
   WHERE run.population_kind <> 'qualification'),
  NOT EXISTS (
    (SELECT
       exposure_stage,
       population_kind,
       lineage_hash,
       case_hash,
       contract_hash,
       run_hash,
       variant,
       workload_revision_hash,
       job_id,
       receipt_id,
       attempt_index,
       component_kind,
       component_name,
       component_hash,
       selection_role
     FROM exposure
     EXCEPT ALL
     SELECT * FROM expected_exposure)
    UNION ALL
    (SELECT * FROM expected_exposure
     EXCEPT ALL
     SELECT
       exposure_stage,
       population_kind,
       lineage_hash,
       case_hash,
       contract_hash,
       run_hash,
       variant,
       workload_revision_hash,
       job_id,
       receipt_id,
       attempt_index,
       component_kind,
       component_name,
       component_hash,
       selection_role
     FROM exposure)
  ) AND NOT EXISTS (
    SELECT 1
    FROM exposure recorded
    WHERE recorded.exposure_stage IN ('portable_claim', 'attempt')
      AND recorded.component_kind IN ('model', 'prompt')
      AND NOT EXISTS (
        SELECT 1
        FROM exposure scheduled
        WHERE scheduled.exposure_stage = 'scheduled'
          AND scheduled.job_id = recorded.job_id
          AND scheduled.component_kind = recorded.component_kind
          AND scheduled.component_name = recorded.component_name
          AND scheduled.component_hash = recorded.component_hash
      )
  ) AND EXISTS (
    SELECT 1
    FROM exposure recorded
    JOIN otlet.portable_receipt_links receipt_link
      ON receipt_link.receipt_id = recorded.receipt_id
    JOIN otlet.portable_claims claim ON claim.id = receipt_link.claim_id
    JOIN otlet.inference_receipts receipt ON receipt.id = receipt_link.receipt_id
    WHERE recorded.exposure_stage = 'portable_claim'
      AND recorded.job_id = claim.job_id
      AND recorded.selection_role = claim.selection_role
      AND recorded.attempt_index = receipt.attempt_index
      AND claim.attempt_index <> receipt.attempt_index
      AND claim.selection_role = 'strong'
  ),
  (SELECT bool_and(
     selection_influencing = (population_kind IN ('tuning', 'calibration'))
   ) FROM exposure),
  (SELECT incomplete_qualification_rejected
     AND nonqualification_rejected
     AND qualification_event_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
     AND EXISTS (
       SELECT 1
       FROM otlet.workload_acceptance_events event
       WHERE event.event_hash = qualification_event_hash
         AND event.definition #> '{payload,qualification_run_hashes}' =
           to_jsonb(ARRAY[qualification_run_hash])
     )
   FROM proof),
  (SELECT population_immutable FROM proof),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.evaluation_exposure_status', 'SELECT'
  )
  AND NOT pg_catalog.has_table_privilege(
    'public', 'otlet.evaluation_cases', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND function.proname IN (
        'register_evaluation_case',
        'start_replay_evaluation',
        'record_workload_promotion_decision'
      )
      AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
  )
  AND NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
) AS contract;

SELECT pg_temp.assert_true(
  contract = 't|t|t|t|t|t|t|t|t',
  'evaluation population lineage contract mismatch: ' || contract
)
FROM evaluation_population_lineage_contract;

SELECT 'evaluation_population_lineage_contract=' || contract
FROM evaluation_population_lineage_contract;

ROLLBACK;
SQL
