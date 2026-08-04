log "Proving replayable evaluation"

psql_exec -qAt <<'SQL'
BEGIN;
SET LOCAL client_min_messages TO warning;

CREATE TEMP TABLE replayable_evaluation_proof (
  baseline_revision_hash text,
  candidate_revision_hash text,
  label_id bigint,
  case_hash text,
  contract_hash text,
  run_hash text,
  initial_visibility_receipts bigint NOT NULL,
  case_idempotent boolean NOT NULL DEFAULT false,
  run_idempotent boolean NOT NULL DEFAULT false,
  mismatch_rejected boolean NOT NULL DEFAULT false,
  rollback_verified boolean NOT NULL DEFAULT false,
  production_isolation_verified boolean NOT NULL DEFAULT false,
  inactive_candidate_claimed boolean NOT NULL DEFAULT false,
  immutability_verified boolean NOT NULL DEFAULT false
) ON COMMIT DROP;
INSERT INTO replayable_evaluation_proof (initial_visibility_receipts)
SELECT receipt_count FROM otlet.inference_visibility_status;

SELECT otlet.register_model(
  'replay_eval_baseline',
  '/tmp/replay_eval_baseline.gguf',
  repeat('a', 64),
  jsonb_build_object(
    'sha256', repeat('a', 64),
    'bytes', 1,
    'source', 'repository-demo',
    'revision', 'baseline',
    'quantization', 'fixture',
    'license', 'fixture'
  ),
  2
) \g /dev/null
SELECT otlet.register_model(
  'replay_eval_candidate',
  '/tmp/replay_eval_candidate.gguf',
  repeat('b', 64),
  jsonb_build_object(
    'sha256', repeat('b', 64),
    'bytes', 1,
    'source', 'repository-demo',
    'revision', 'candidate',
    'quantization', 'fixture',
    'license', 'fixture'
  ),
  2
) \g /dev/null

CREATE TABLE public.otlet_demo_replayable_evaluation (
  id text PRIMARY KEY,
  review_state text NOT NULL,
  protected_note text NOT NULL
);
INSERT INTO public.otlet_demo_replayable_evaluation
VALUES ('case-1', 'pending', 'DO_NOT_TOUCH');

SELECT otlet.create_watch(
  watch_name => 'replayable_evaluation_probe',
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
  model_name => 'replay_eval_baseline',
  table_name => 'public.otlet_demo_replayable_evaluation'::regclass,
  subject_column => 'id',
  runtime_options => '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  action_types => ARRAY['update_row'],
  decision_contract => '{
    "answer_field":"decision",
    "abstain_values":[],
    "confidence_field":"confidence",
    "accepted_confidence":["high"],
    "redact_output_fields":["decision"]
  }'::jsonb
) \g /dev/null
SELECT otlet.register_action_target(
  'replayable_evaluation_target',
  'public.otlet_demo_replayable_evaluation'::regclass,
  'id',
  ARRAY['review_state']::name[]
) \g /dev/null
SELECT otlet.register_action_workflow_policy(
  'replayable_evaluation_probe_task',
  'update_row',
  'replayable_evaluation_target',
  'bounded_mutation',
  'evaluated'
) \g /dev/null

DO $$
DECLARE
  baseline_revision text;
  baseline_input jsonb;
  baseline_output jsonb := '{"decision":"approve","confidence":"high"}'::jsonb;
  baseline_actions jsonb := '[{
    "type":"update_row",
    "body":{
      "target":"replayable_evaluation_target",
      "identity":"case-1",
      "changes":{"review_state":"baseline"}
    }
  }]'::jsonb;
  baseline_job_id bigint;
  baseline_claim_token text;
  selected_action_id bigint;
  selected_label_id bigint;
  selected_case_hash text;
  repeated_case_hash text;
BEGIN
  SELECT active_workload_revision_hash
  INTO baseline_revision
  FROM otlet.workload_revision_heads
  WHERE task_name = 'replayable_evaluation_probe_task';

  SELECT jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_replayable_evaluation',
      'subject_id', source.id,
      'ctid', source.ctid::text,
      'xmin', source.xmin::text
    ),
    'table', 'public.otlet_demo_replayable_evaluation',
    'row', to_jsonb(source)
  )
  INTO baseline_input
  FROM public.otlet_demo_replayable_evaluation source
  WHERE source.id = 'case-1';

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
    'replayable_evaluation_probe_task',
    baseline_revision,
    'case-1',
    baseline_input,
    'running',
    1,
    now(),
    now() + interval '5 minutes',
    gen_random_uuid()::text
  )
  RETURNING id, claim_token INTO baseline_job_id, baseline_claim_token;

  PERFORM otlet.complete_job(
    job_id => baseline_job_id,
    output => baseline_output,
    raw_output => jsonb_build_object(
      'output', baseline_output,
      'actions', baseline_actions
    )::text,
    actions => baseline_actions,
    started_at => now(),
    trace_summary => '{
      "schema_validation_status":"passed",
      "generate_ms":111,
      "mvcc":{"table":"public.otlet_demo_replayable_evaluation"}
    }'::jsonb,
    model_name => 'replay_eval_baseline',
    expected_claim_token => baseline_claim_token
  );

  SELECT id
  INTO selected_action_id
  FROM otlet.actions
  WHERE job_id = baseline_job_id;

  SELECT id
  INTO selected_label_id
  FROM otlet.label_action(
    selected_action_id,
    expected_answer => 'approve',
    expected_confidence => 'high',
    expected_action_type => 'update_row',
    reason => 'Approved baseline replay fixture',
    label_source => 'manual_correction'
  );

  selected_case_hash := otlet.register_evaluation_case(
    selected_label_id,
    'Approved immutable shaped snapshot for replay'
  );
  repeated_case_hash := otlet.register_evaluation_case(
    selected_label_id,
    'Approved immutable shaped snapshot for replay'
  );

  UPDATE replayable_evaluation_proof
  SET baseline_revision_hash = baseline_revision,
      label_id = selected_label_id,
      case_hash = selected_case_hash,
      case_idempotent = selected_case_hash = repeated_case_hash
        AND (SELECT count(*) FROM otlet.evaluation_cases) = 1;
END
$$;

UPDATE otlet.tasks
SET instruction = 'Return a candidate decision, confidence, and one update_row recommendation',
    output_schema = '{
      "title":"Candidate evaluation output",
      "type":"object",
      "required":["decision","confidence"],
      "additionalProperties":false,
      "properties":{
        "decision":{"enum":["approve","reject"]},
        "confidence":{"enum":["high"]}
      }
    }'::jsonb,
    runtime_options = '{"max_tokens":48,"reasoning":"off","inference_cache":false}'::jsonb,
    input_shaping = input_shaping || '{"strip_keys":["table"]}'::jsonb
WHERE name = 'replayable_evaluation_probe_task';
SELECT otlet.set_model_selection_policy(
  'replayable_evaluation_probe_task',
  'replay_eval_candidate',
  'replay_eval_baseline',
  '{
    "answer_field":"decision",
    "abstain_values":[],
    "confidence_field":"confidence",
    "accepted_confidence":["high"]
  }'::jsonb
) \g /dev/null
SELECT otlet.register_action_workflow_policy(
  'replayable_evaluation_probe_task',
  'update_row',
  'replayable_evaluation_target',
  'bounded_mutation',
  'evaluated'
) \g /dev/null

DO $$
DECLARE
  proof replayable_evaluation_proof%ROWTYPE;
  candidate_revision text;
  thresholds jsonb;
  selected_contract_hash text;
  selected_run_hash text;
  repeated_run_hash text;
  production_job_id bigint;
BEGIN
  SELECT * INTO proof FROM replayable_evaluation_proof;
  SELECT active_workload_revision_hash
  INTO candidate_revision
  FROM otlet.workload_revision_heads
  WHERE task_name = 'replayable_evaluation_probe_task';
  IF candidate_revision IS NOT DISTINCT FROM proof.baseline_revision_hash THEN
    RAISE EXCEPTION 'replay candidate revision was not captured';
  END IF;

  PERFORM otlet.promote_workload_revision(
    'replayable_evaluation_probe_task',
    proof.baseline_revision_hash,
    candidate_revision
  );

  SELECT jsonb_object_agg(
    category,
    jsonb_build_object(
      'metric', category,
      'statistic', CASE
        WHEN category IN ('review_age', 'review_minutes', 'freshness', 'latency', 'recovery')
          THEN 'p95'
        ELSE 'rate'
      END,
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
    'candidate_recall',
    'false_trust',
    'abstention',
    'review_age',
    'review_minutes',
    'freshness',
    'latency',
    'database_impact',
    'unit_cost',
    'recovery',
    'downstream_outcome'
  ]) category;

  selected_contract_hash := otlet.register_workload_acceptance_contract(
    'replayable_evaluation_probe_task',
    candidate_revision,
    proof.baseline_revision_hash,
    '{"mode":"full","rule":{"kind":"all_declared_subjects"}}'::jsonb,
    statement_timestamp() + interval '1 hour',
    statement_timestamp() + interval '32 days',
    '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
    thresholds
  );

  selected_run_hash := otlet.start_replay_evaluation(
    selected_contract_hash,
    ARRAY[proof.case_hash],
    'replayable-evaluation-v1',
    'Compare the exact approved population'
  );
  repeated_run_hash := otlet.start_replay_evaluation(
    selected_contract_hash,
    ARRAY[proof.case_hash],
    'replayable-evaluation-v1',
    'Compare the exact approved population'
  );

  UPDATE replayable_evaluation_proof
  SET candidate_revision_hash = candidate_revision,
      contract_hash = selected_contract_hash,
      run_hash = selected_run_hash,
      run_idempotent = selected_run_hash = repeated_run_hash
        AND (SELECT count(*) FROM otlet.evaluation_runs) = 1;

  production_job_id := otlet.application_submit_task_subject(
    'replayable_evaluation_probe_task',
    'case-1',
    'replay-production-isolation-v1'
  );
  PERFORM 1
  FROM otlet.request_job_cancellation(
    production_job_id,
    'Replay production-isolation probe complete'
  );
  UPDATE replayable_evaluation_proof
  SET production_isolation_verified = EXISTS (
        SELECT 1
        FROM otlet.jobs job
        WHERE job.id = production_job_id
          AND job.execution_mode = 'production'
          AND job.status = 'canceled'
      )
      AND (
        SELECT count(*)
        FROM otlet.jobs job
        WHERE job.task_name = 'replayable_evaluation_probe_task'
          AND job.execution_mode = 'evaluation'
          AND job.status = 'queued'
      ) = 2
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.runs run
        JOIN otlet.evaluation_executions execution ON execution.job_id = run.job_id
        WHERE execution.run_hash = selected_run_hash
      );

  BEGIN
    PERFORM otlet.start_replay_evaluation(
      selected_contract_hash,
      ARRAY[proof.case_hash],
      'replayable-evaluation-v1',
      'Conflicting replay definition'
    );
    RAISE EXCEPTION 'replay run mismatch unexpectedly accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation run key already has a different definition' THEN
      RAISE;
    END IF;
  END;
  UPDATE replayable_evaluation_proof SET mismatch_rejected = true;

  BEGIN
    PERFORM otlet.start_replay_evaluation(
      selected_contract_hash,
      ARRAY[proof.case_hash],
      'replayable-evaluation-rollback',
      'Rollback probe'
    );
    RAISE EXCEPTION 'replay rollback marker';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'replay rollback marker' THEN
      RAISE;
    END IF;
  END;
  UPDATE replayable_evaluation_proof
  SET rollback_verified = NOT EXISTS (
    SELECT 1
    FROM otlet.evaluation_runs
    WHERE run_key = 'replayable-evaluation-rollback'
  );
END
$$;

CREATE TEMP TABLE replayable_baseline_claim ON COMMIT DROP AS
SELECT * FROM otlet.claim_jobs('replay_eval_baseline', 1);
CREATE TEMP TABLE replayable_candidate_claim ON COMMIT DROP AS
SELECT * FROM otlet.claim_jobs('replay_eval_candidate', 1);

DO $$
DECLARE
  proof replayable_evaluation_proof%ROWTYPE;
  baseline_claim otlet.jobs%ROWTYPE;
  candidate_claim otlet.jobs%ROWTYPE;
  baseline_output jsonb := '{"decision":"approve","confidence":"high"}'::jsonb;
  candidate_output jsonb := '{"decision":"reject","confidence":"high"}'::jsonb;
  baseline_actions jsonb := '[{
    "type":"update_row",
    "body":{
      "target":"replayable_evaluation_target",
      "identity":"case-1",
      "changes":{"review_state":"baseline"}
    }
  }]'::jsonb;
  candidate_actions jsonb := '[{
    "type":"update_row",
    "body":{
      "target":"replayable_evaluation_target",
      "identity":"case-1",
      "changes":{"review_state":"candidate"}
    }
  }]'::jsonb;
BEGIN
  SELECT * INTO proof FROM replayable_evaluation_proof;
  IF (SELECT count(*) FROM replayable_baseline_claim) <> 1
     OR (SELECT count(*) FROM replayable_candidate_claim) <> 1 THEN
    RAISE EXCEPTION 'replay evaluation jobs were not claimed exactly once';
  END IF;
  SELECT * INTO baseline_claim FROM replayable_baseline_claim;
  SELECT * INTO candidate_claim FROM replayable_candidate_claim;

  UPDATE replayable_evaluation_proof
  SET inactive_candidate_claimed = candidate_claim.status = 'running'
    AND candidate_claim.workload_revision_hash = proof.candidate_revision_hash
    AND (SELECT active_workload_revision_hash
         FROM otlet.workload_revision_heads
         WHERE task_name = 'replayable_evaluation_probe_task') = proof.baseline_revision_hash
    AND candidate_claim.id = (
      SELECT job_id
      FROM otlet.evaluation_executions
      WHERE run_hash = proof.run_hash
        AND variant = 'candidate'
    );

  PERFORM otlet.complete_job(
    job_id => baseline_claim.id,
    output => baseline_output,
    raw_output => jsonb_build_object(
      'output', baseline_output,
      'actions', baseline_actions
    )::text,
    actions => baseline_actions,
    started_at => baseline_claim.started_at,
    trace_summary => '{"schema_validation_status":"passed","generate_ms":999}'::jsonb,
    model_name => 'replay_eval_baseline',
    expected_claim_token => baseline_claim.claim_token
  );
  PERFORM otlet.complete_job(
    job_id => candidate_claim.id,
    output => candidate_output,
    raw_output => jsonb_build_object(
      'output', candidate_output,
      'actions', candidate_actions
    )::text,
    actions => candidate_actions,
    started_at => candidate_claim.started_at,
    trace_summary => '{"schema_validation_status":"passed","generate_ms":888}'::jsonb,
    model_name => 'replay_eval_candidate',
    expected_claim_token => candidate_claim.claim_token
  );
END
$$;

DO $$
DECLARE
  proof replayable_evaluation_proof%ROWTYPE;
  case_guarded boolean := false;
  run_guarded boolean := false;
  result_guarded boolean := false;
BEGIN
  SELECT * INTO proof FROM replayable_evaluation_proof;
  BEGIN
    UPDATE otlet.evaluation_cases
    SET approval_reason = 'changed'
    WHERE case_hash = proof.case_hash;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation evidence is append only' THEN
      RAISE;
    END IF;
    case_guarded := true;
  END;
  BEGIN
    DELETE FROM otlet.evaluation_runs WHERE run_hash = proof.run_hash;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation evidence is append only' THEN
      RAISE;
    END IF;
    run_guarded := true;
  END;
  BEGIN
    UPDATE otlet.evaluation_results
    SET decision_diff = '{}'::jsonb
    WHERE run_hash = proof.run_hash;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation evidence is append only' THEN
      RAISE;
    END IF;
    result_guarded := true;
  END;
  UPDATE replayable_evaluation_proof
  SET immutability_verified = case_guarded AND run_guarded AND result_guarded;
END
$$;

CREATE TEMP TABLE replayable_evaluation_contract ON COMMIT DROP AS
WITH proof AS (
  SELECT * FROM replayable_evaluation_proof
), status AS (
  SELECT replay.*
  FROM otlet.evaluation_replay_status replay, proof
  WHERE replay.run_hash = proof.run_hash
), evaluation_jobs AS (
  SELECT execution.job_id
  FROM otlet.evaluation_executions execution, proof
  WHERE execution.run_hash = proof.run_hash
)
SELECT concat_ws('|',
  (SELECT case_idempotent
     AND (SELECT count(*) FROM otlet.evaluation_cases) = 1
   FROM proof),
  (SELECT run_idempotent
     AND mismatch_rejected
     AND rollback_verified
     AND production_isolation_verified
     AND (SELECT count(*) FROM otlet.evaluation_runs) = 1
   FROM proof),
  (SELECT same_population
     AND baseline_job_id <> candidate_job_id
     AND (SELECT baseline.input = candidate.input
          FROM otlet.jobs baseline, otlet.jobs candidate
          WHERE baseline.id = status.baseline_job_id
            AND candidate.id = status.candidate_job_id)
     AND shaped_input_hash = otlet.identity_hash(
       'evaluation_shaped_snapshot',
       (SELECT input FROM otlet.jobs WHERE id = status.baseline_job_id)
     )
   FROM status),
  (SELECT proof.inactive_candidate_claimed
     AND status.baseline_job_status = 'complete'
     AND status.candidate_job_status = 'complete'
     AND status.baseline_workload_revision_hash = proof.baseline_revision_hash
     AND status.candidate_workload_revision_hash = proof.candidate_revision_hash
     AND (SELECT active_workload_revision_hash
          FROM otlet.workload_revision_heads
          WHERE task_name = status.task_name) = proof.baseline_revision_hash
   FROM proof, status),
  (SELECT (revision_diff #>> '{components,model,changed}')::boolean
     AND (revision_diff #>> '{components,prompt,changed}')::boolean
     AND (revision_diff #>> '{components,schema,changed}')::boolean
     AND (revision_diff #>> '{components,runtime,changed}')::boolean
     AND (revision_diff #>> '{components,selection,changed}')::boolean
     AND (revision_diff #>> '{components,candidate,changed}')::boolean
   FROM status),
  (SELECT (baseline_decision_diff ->> 'answer_matches')::boolean
     AND (baseline_decision_diff ->> 'confidence_matches')::boolean
     AND baseline_decision_diff ->> 'observed_answer' = 'approve'
     AND (baseline_decision_diff ->> 'non_authoritative')::boolean
   FROM status),
  (SELECT NOT (candidate_decision_diff ->> 'answer_matches')::boolean
     AND (candidate_decision_diff ->> 'confidence_matches')::boolean
     AND candidate_decision_diff ->> 'observed_answer' = 'reject'
     AND (candidate_decision_diff ->> 'non_authoritative')::boolean
   FROM status),
  (SELECT (baseline_approval_diff ->> 'matches_expected')::boolean
     AND (baseline_approval_diff ->> 'expected_action_present')::boolean
     AND (baseline_approval_diff ->> 'requires_approval')::boolean
     AND baseline_approval_diff ->> 'recommendation' = 'approve'
     AND baseline_approval_diff -> 'valid_action_types' = '["update_row"]'::jsonb
   FROM status),
  (SELECT NOT (candidate_approval_diff ->> 'matches_expected')::boolean
     AND (candidate_approval_diff ->> 'expected_action_present')::boolean
     AND (candidate_approval_diff ->> 'requires_approval')::boolean
     AND candidate_approval_diff ->> 'recommendation' = 'reject'
     AND candidate_approval_diff -> 'valid_action_types' = '["update_row"]'::jsonb
   FROM status),
  (SELECT jsonb_array_length(baseline_mutation_diffs) = 1
     AND jsonb_array_length(candidate_mutation_diffs) = 1
     AND (baseline_mutation_diffs #>> '{0,non_authoritative}')::boolean
     AND (candidate_mutation_diffs #>> '{0,non_authoritative}')::boolean
     AND (baseline_mutation_diffs #>> '{0,target_contract_matches}')::boolean
     AND (candidate_mutation_diffs #>> '{0,target_contract_matches}')::boolean
     AND baseline_mutation_diffs #> '{0,changed_columns}' = '["review_state"]'::jsonb
     AND candidate_mutation_diffs #> '{0,changed_columns}' = '["review_state"]'::jsonb
     AND baseline_mutation_diffs #>> '{0,before_hash}' =
         candidate_mutation_diffs #>> '{0,before_hash}'
     AND baseline_mutation_diffs #>> '{0,result_hash}' <>
         candidate_mutation_diffs #>> '{0,result_hash}'
     AND NOT ((baseline_mutation_diffs -> 0) ? 'error')
     AND NOT ((candidate_mutation_diffs -> 0) ? 'error')
   FROM status),
  (SELECT review_state = 'pending' AND protected_note = 'DO_NOT_TOUCH'
   FROM public.otlet_demo_replayable_evaluation
   WHERE id = 'case-1'),
  (SELECT NOT EXISTS (
       SELECT 1 FROM otlet.actions action
       WHERE action.job_id IN (SELECT job_id FROM evaluation_jobs)
     )
     AND NOT EXISTS (
       SELECT 1
       FROM otlet.records record
       JOIN otlet.actions action ON action.id = record.action_id
       WHERE action.job_id IN (SELECT job_id FROM evaluation_jobs)
     )
     AND NOT EXISTS (
       SELECT 1
       FROM otlet.semantic_materializations materialization
       JOIN otlet.records record ON record.id = materialization.record_id
       JOIN otlet.actions action ON action.id = record.action_id
       WHERE action.job_id IN (SELECT job_id FROM evaluation_jobs)
     )
     AND NOT EXISTS (
       SELECT 1 FROM otlet.review_events event
       WHERE event.job_id IN (SELECT job_id FROM evaluation_jobs)
     )
     AND NOT EXISTS (
       SELECT 1 FROM otlet.runs run
       WHERE run.job_id IN (SELECT job_id FROM evaluation_jobs)
     )
     AND NOT EXISTS (
       SELECT 1 FROM otlet.model_selection_attempts attempt
       WHERE attempt.job_id IN (SELECT job_id FROM evaluation_jobs)
     )
     AND NOT EXISTS (
       SELECT 1
       FROM otlet.model_selection_status selection_status, proof
       WHERE selection_status.workload_revision_hash = proof.candidate_revision_hash
     )
     AND NOT EXISTS (
       SELECT 1
       FROM otlet.inference_receipt_trace_status trace
       WHERE trace.job_id IN (SELECT job_id FROM evaluation_jobs)
     )
     AND NOT EXISTS (
       SELECT 1
       FROM otlet.runtime_stage_timing_status timing
       WHERE timing.job_id IN (SELECT job_id FROM evaluation_jobs)
     )
     AND (SELECT receipt_count = 2
          FROM otlet.task_inference_cache_status
          WHERE task_name = 'replayable_evaluation_probe_task')
     AND (SELECT receipt_count FROM otlet.inference_visibility_status) =
         proof.initial_visibility_receipts + 2
     AND (SELECT model_ms = 111 AND model_cost_source = 'task_receipt'
          FROM otlet.semantic_plan_from_counts(
            'replayable_evaluation_probe',
            'replayable_evaluation_probe_task',
            'replayable_evaluation_probe_record',
            'replay_eval_baseline',
            'public.otlet_demo_replayable_evaluation',
            'lookup',
            'empty',
            'fresh',
            'fail_closed',
            'partial',
            'full',
            'full_reason',
            1,
            1,
            0,
            0
          ))
   FROM proof),
  (SELECT (SELECT count(*) FROM evaluation_jobs) = 2
     AND (SELECT count(*) FROM otlet.evaluation_results result
          WHERE result.job_id IN (SELECT job_id FROM evaluation_jobs)) = 2
     AND (SELECT count(*) FROM otlet.outputs output
          WHERE output.job_id IN (SELECT job_id FROM evaluation_jobs)) = 2
     AND NOT EXISTS (
       SELECT 1 FROM otlet.outputs output
       WHERE output.job_id IN (SELECT job_id FROM evaluation_jobs)
         AND output.output ->> 'decision' IS DISTINCT FROM '[REDACTED]'
     )
     AND (SELECT count(*) FROM otlet.inference_receipts receipt
          WHERE receipt.job_id IN (SELECT job_id FROM evaluation_jobs)) = 2),
  (SELECT immutability_verified FROM proof),
  (SELECT non_authoritative
     AND NULLIF(started_by, '') IS NOT NULL
     AND NULLIF(started_as, '') IS NOT NULL
     AND reason = 'Compare the exact approved population'
     AND EXISTS (
       SELECT 1
       FROM otlet.evaluation_case_status evaluation_case, proof
       WHERE evaluation_case.case_hash = proof.case_hash
         AND evaluation_case.source_mode = 'approved_shaped_snapshot'
         AND evaluation_case.approval_reason =
           'Approved immutable shaped snapshot for replay'
     )
   FROM status)
) AS contract;

DO $$
DECLARE
  observed text;
BEGIN
  SELECT contract INTO observed FROM replayable_evaluation_contract;
  IF observed <> 't|t|t|t|t|t|t|t|t|t|t|t|t|t|t' THEN
    RAISE EXCEPTION 'replayable evaluation contract mismatch: %', observed;
  END IF;
END
$$;

SELECT 'replayable_evaluation_contract=' || contract
FROM replayable_evaluation_contract;

ROLLBACK;
SQL
