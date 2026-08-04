log "Proving evaluation slices and support"

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

CREATE TEMP TABLE evaluation_slice_proof (
  baseline_revision_hash text,
  candidate_revision_hash text,
  contract_hash text,
  run_hash text,
  incomplete_run_hash text,
  report_hash text,
  unlabeled_lineage_hash text,
  thresholds jsonb,
  reviewer_time jsonb,
  early_run_rejected boolean NOT NULL DEFAULT false,
  late_run_rejected boolean NOT NULL DEFAULT false,
  early_report_rejected boolean NOT NULL DEFAULT false,
  sample_mismatch_rejected boolean NOT NULL DEFAULT false,
  incomplete_rejected boolean NOT NULL DEFAULT false,
  reviewer_window_rejected boolean NOT NULL DEFAULT false,
  invalid_measurement_rejected boolean NOT NULL DEFAULT false,
  fractional_measurement_rejected boolean NOT NULL DEFAULT false,
  report_idempotent boolean NOT NULL DEFAULT false,
  conflict_rejected boolean NOT NULL DEFAULT false,
  immutable boolean NOT NULL DEFAULT false
) ON COMMIT DROP;
INSERT INTO evaluation_slice_proof DEFAULT VALUES;

CREATE TEMP TABLE evaluation_slice_cases (
  fixture_id text PRIMARY KEY,
  expected_answer text NOT NULL,
  source_table text NOT NULL,
  labeled boolean NOT NULL,
  included boolean NOT NULL,
  case_hash text UNIQUE,
  lineage_hash text UNIQUE
) ON COMMIT DROP;
INSERT INTO evaluation_slice_cases (
  fixture_id,
  expected_answer,
  source_table,
  labeled,
  included
) VALUES
  ('slice-a', 'approve', 'public.otlet_demo_evaluation_slice_primary', true, true),
  ('slice-b', 'reject', 'public.otlet_demo_evaluation_slice_primary', true, true),
  ('slice-c', 'approve', 'public.otlet_demo_evaluation_slice_secondary', true, true),
  ('slice-d', 'reject', 'public.otlet_demo_evaluation_slice_secondary', true, true),
  ('slice-e', 'approve', 'public.otlet_demo_evaluation_slice_primary', true, false),
  ('slice-f', 'reject', 'public.otlet_demo_evaluation_slice_secondary', false, false);

SELECT otlet.register_model(
  model_name,
  '/tmp/' || model_name || '.gguf',
  artifact_hash,
  jsonb_build_object(
    'sha256', artifact_hash,
    'bytes', 1,
    'source', 'repository-demo',
    'revision', model_name,
    'quantization', 'fixture',
    'license', 'fixture'
  ),
  4
)
FROM (VALUES
  ('evaluation_slice_baseline', repeat('1', 64)),
  ('evaluation_slice_cheap', repeat('2', 64)),
  ('evaluation_slice_strong', repeat('3', 64))
) model(model_name, artifact_hash) \g /dev/null

CREATE TABLE public.otlet_demo_evaluation_slice_primary (
  id text PRIMARY KEY,
  review_state text NOT NULL,
  protected_note text NOT NULL
);
INSERT INTO public.otlet_demo_evaluation_slice_primary
SELECT fixture_id, 'pending', 'DO_NOT_TOUCH'
FROM evaluation_slice_cases
WHERE source_table = 'public.otlet_demo_evaluation_slice_primary';

CREATE TABLE public.otlet_demo_evaluation_slice_secondary (
  id text PRIMARY KEY,
  review_state text NOT NULL,
  protected_note text NOT NULL
);
INSERT INTO public.otlet_demo_evaluation_slice_secondary
SELECT fixture_id, 'pending', 'DO_NOT_TOUCH'
FROM evaluation_slice_cases
WHERE source_table = 'public.otlet_demo_evaluation_slice_secondary';

SELECT otlet.create_task(
  task_name => 'evaluation_slice_probe_task',
  input_query => $query$
    SELECT
      source.id::text AS subject_id,
      jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', 'public.otlet_demo_evaluation_slice_primary',
          'subject_id', source.id::text,
          'ctid', source.ctid::text,
          'xmin', source.xmin::text
        ),
        'table', 'public.otlet_demo_evaluation_slice_primary',
        'row', to_jsonb(source)
      ) AS input
    FROM public.otlet_demo_evaluation_slice_primary source
    UNION ALL
    SELECT
      source.id::text AS subject_id,
      jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', 'public.otlet_demo_evaluation_slice_secondary',
          'subject_id', source.id::text,
          'ctid', source.ctid::text,
          'xmin', source.xmin::text
        ),
        'table', 'public.otlet_demo_evaluation_slice_secondary',
        'row', to_jsonb(source)
      ) AS input
    FROM public.otlet_demo_evaluation_slice_secondary source
  $query$,
  instruction => 'Return a decision, confidence, and one review flag',
  output_schema => '{
    "type":"object",
    "required":["decision","confidence"],
    "additionalProperties":false,
    "properties":{
      "decision":{"enum":["approve","reject","unclear"]},
      "confidence":{"enum":["high"]}
    }
  }'::jsonb,
  model_name => 'evaluation_slice_baseline',
  runtime_options => '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb,
  input_shaping => '{"source_fields":["_otlet_mvcc","row","table"]}'::jsonb,
  decision_contract => '{
    "answer_field":"decision",
    "abstain_values":["unclear"],
    "confidence_field":"confidence",
    "accepted_confidence":["high"],
    "action_types":["review_flag"]
  }'::jsonb,
  source_relations => '[
    {"table":"public.otlet_demo_evaluation_slice_primary"},
    {"table":"public.otlet_demo_evaluation_slice_secondary"}
  ]'::jsonb
) \g /dev/null

SELECT pg_temp.assert_true(
  otlet.run_task('evaluation_slice_probe_task') = 6,
  'multi-source evaluation fixture did not queue every source row'
) \g /dev/null

UPDATE evaluation_slice_proof
SET baseline_revision_hash = (
  SELECT active_workload_revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = 'evaluation_slice_probe_task'
);

UPDATE otlet.jobs
SET status = 'running',
    attempts = 1,
    started_at = clock_timestamp(),
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
WHERE task_name = 'evaluation_slice_probe_task'
  AND execution_mode = 'production';

DO $body$
DECLARE
  fixture evaluation_slice_cases%ROWTYPE;
  job record;
  job_output jsonb;
  job_actions jsonb;
  action_id bigint;
  saved_label_id bigint;
  saved_case_hash text;
BEGIN
  FOR job IN
    SELECT stored.*
    FROM otlet.jobs stored
    WHERE stored.task_name = 'evaluation_slice_probe_task'
      AND stored.execution_mode = 'production'
    ORDER BY stored.subject_id
  LOOP
    SELECT * INTO fixture
    FROM evaluation_slice_cases
    WHERE fixture_id = job.subject_id
      AND source_table = job.input #>> '{_otlet_mvcc,table}';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'multi-source evaluation fixture lost source identity';
    END IF;
    job_output := jsonb_build_object(
      'decision', fixture.expected_answer,
      'confidence', 'high'
    );
    job_actions := jsonb_build_array(jsonb_build_object(
      'type', 'review_flag',
      'body', jsonb_build_object('reason', 'evaluation slice fixture')
    ));
    PERFORM otlet.complete_job(
      job_id => job.id,
      output => job_output,
      raw_output => jsonb_build_object(
        'output', job_output,
        'actions', job_actions
      )::text,
      actions => job_actions,
      started_at => job.started_at,
      trace_summary => '{
        "schema_validation_status":"passed",
        "generate_ms":1,
        "worker_process_rss_bytes":1
      }'::jsonb,
      model_name => 'evaluation_slice_baseline',
      expected_claim_token => job.claim_token
    );
    IF fixture.labeled THEN
      SELECT action.id INTO action_id
      FROM otlet.actions action
      WHERE action.job_id = job.id
        AND action.action_type = 'review_flag';
      SELECT label.id INTO saved_label_id
      FROM otlet.label_action(
        action_id,
        expected_answer => fixture.expected_answer,
        expected_confidence => 'high',
        expected_action_type => 'review_flag',
        reason => 'Approved evaluation slice fixture',
        label_source => 'manual_correction'
      ) label;
      PERFORM otlet.adjudicate_eval_label(
        saved_label_id,
        'accepted',
        1.0,
        'Accepted evaluation slice label'
      );
      saved_case_hash := otlet.register_evaluation_case(
        saved_label_id,
        'qualification',
        'Approved evaluation slice snapshot'
      );
      UPDATE evaluation_slice_cases stored
      SET case_hash = saved_case_hash,
          lineage_hash = evaluation_case.lineage_hash
      FROM otlet.evaluation_cases evaluation_case
      WHERE stored.fixture_id = fixture.fixture_id
        AND evaluation_case.case_hash = saved_case_hash;
      PERFORM pg_temp.assert_true(
        EXISTS (
          SELECT 1
          FROM otlet.eval_labels label
          JOIN otlet.evaluation_cases evaluation_case
            ON evaluation_case.label_id = label.id
          WHERE label.id = saved_label_id
            AND label.source_table = job.input #>> '{_otlet_mvcc,table}'
            AND label.source_hash = otlet.semantic_source_hash(job.input)
            AND evaluation_case.source_table = label.source_table
            AND evaluation_case.source_hash = label.source_hash
        ),
        'evaluation case lineage did not come from the declared source row'
      );
    ELSE
      UPDATE evaluation_slice_cases stored
      SET lineage_hash = otlet.identity_hash(
        'evaluation_case_lineage',
        jsonb_strip_nulls(jsonb_build_object(
          'task_name', job.task_name,
          'subject_id', job.subject_id,
          'source_table', job.input #>> '{_otlet_mvcc,table}',
          'source_hash', otlet.semantic_source_hash(job.input),
          'shaped_input_hash', otlet.identity_hash(
            'evaluation_shaped_snapshot',
            otlet.semantic_shaped_input(
              job.input,
              (
                SELECT revision.definition #> '{task,input_shaping}'
                FROM otlet.workload_revisions revision
                WHERE revision.workload_revision_hash = job.workload_revision_hash
              )
            )
          )
        ))
      )
      WHERE stored.fixture_id = fixture.fixture_id;
    END IF;
  END LOOP;
END
$body$;

SELECT otlet.set_model_selection_policy(
  'evaluation_slice_probe_task',
  'evaluation_slice_cheap',
  'evaluation_slice_strong',
  '{
    "answer_field":"decision",
    "abstain_values":["unclear"],
    "confidence_field":"confidence",
    "accepted_confidence":["high"]
  }'::jsonb
) \g /dev/null
SELECT otlet.promote_configured_workload_revision(
  'evaluation_slice_probe_task'
) \g /dev/null
UPDATE evaluation_slice_proof
SET candidate_revision_hash = (
  SELECT active_workload_revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = 'evaluation_slice_probe_task'
), unlabeled_lineage_hash = (
  SELECT lineage_hash
  FROM evaluation_slice_cases
  WHERE fixture_id = 'slice-f'
);
SELECT otlet.promote_workload_revision(
  'evaluation_slice_probe_task',
  baseline_revision_hash,
  candidate_revision_hash
)
FROM evaluation_slice_proof \g /dev/null

DO $body$
DECLARE
  proof evaluation_slice_proof%ROWTYPE;
  eligible_members jsonb;
  configured_thresholds jsonb;
BEGIN
  SELECT * INTO proof FROM evaluation_slice_proof;
  SELECT jsonb_agg(member ORDER BY member ->> 'lineage_hash')
  INTO eligible_members
  FROM (
    SELECT jsonb_strip_nulls(jsonb_build_object(
      'lineage_hash', lineage_hash,
      'case_hash', case_hash,
      'included', included,
      'exclusion_reason', CASE WHEN included THEN NULL
        WHEN labeled THEN 'Held out by the declared stratified sample'
        ELSE 'No approved label before the observation window'
      END
    )) AS member
    FROM evaluation_slice_cases
  ) population;
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
      'operator', CASE
        WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 'gte'
        ELSE 'lte'
      END,
      'value', CASE
        WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 0.80
        ELSE 0.20
      END,
      'unit', CASE category
        WHEN 'review_minutes' THEN 'seconds'
        WHEN 'latency' THEN 'milliseconds'
        WHEN 'database_impact' THEN 'bytes'
        ELSE 'ratio'
      END,
      'minimum_support', 3,
      'required', true
    )
  )
  INTO configured_thresholds
  FROM unnest(ARRAY[
    'candidate_recall', 'false_trust', 'abstention', 'review_age',
    'review_minutes', 'freshness', 'latency', 'database_impact',
    'unit_cost', 'recovery', 'downstream_outcome'
  ]) category;

  UPDATE evaluation_slice_proof
  SET thresholds = configured_thresholds,
      contract_hash = otlet.register_workload_acceptance_contract(
        'evaluation_slice_probe_task',
        proof.candidate_revision_hash,
        proof.baseline_revision_hash,
        jsonb_build_object(
          'mode', 'sample',
          'rule', jsonb_build_object(
            'kind', 'stratified',
            'basis', jsonb_build_array('expected_answer', 'source_table'),
            'eligible_members', eligible_members
          )
        ),
        clock_timestamp() + interval '250 milliseconds',
        clock_timestamp() + interval '10.25 seconds',
        '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
        configured_thresholds
      );
END
$body$;

DO $body$
DECLARE
  proof evaluation_slice_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM evaluation_slice_proof;
  BEGIN
    PERFORM otlet.start_replay_evaluation(
      proof.contract_hash,
      ARRAY(
        SELECT case_hash
        FROM evaluation_slice_cases
        WHERE included
        ORDER BY case_hash
      ),
      'evaluation-slices-early-v2',
      'Prove early run rejection'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation run is outside the observation window' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_slice_proof SET early_run_rejected = true;
END
$body$;

SELECT pg_sleep(GREATEST(
  0,
  extract(epoch FROM (
    (
      SELECT contract.definition #>> '{observation_window,starts_at}'
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.contract_hash = (
        SELECT contract_hash FROM evaluation_slice_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.02
)::double precision) \g /dev/null

DO $body$
DECLARE
  proof evaluation_slice_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM evaluation_slice_proof;
  BEGIN
    PERFORM otlet.start_replay_evaluation(
      proof.contract_hash,
      ARRAY(
        SELECT case_hash
        FROM evaluation_slice_cases
        WHERE included AND fixture_id <> 'slice-d'
        ORDER BY case_hash
      ),
      'evaluation-slices-mismatched-v2',
      'Prove sample mismatch rejection'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation run must exactly match the predeclared sample' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_slice_proof SET sample_mismatch_rejected = true;
END
$body$;

UPDATE evaluation_slice_proof proof
SET run_hash = otlet.start_replay_evaluation(
  proof.contract_hash,
  ARRAY(
    SELECT case_hash
    FROM evaluation_slice_cases
    WHERE included
    ORDER BY case_hash
  ),
  'evaluation-slices-support-v2',
  'Measure the predeclared evaluation sample'
), incomplete_run_hash = otlet.start_replay_evaluation(
  proof.contract_hash,
  ARRAY(
    SELECT case_hash
    FROM evaluation_slice_cases
    WHERE included
    ORDER BY case_hash
  ),
  'evaluation-slices-incomplete-v2',
  'Prove incomplete evidence rejection'
);

DO $body$
DECLARE
  proof evaluation_slice_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM evaluation_slice_proof;
  BEGIN
    PERFORM otlet.record_evaluation_slice_report(
      proof.run_hash,
      '[]'::jsonb,
      'Early report probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation observation window is still open' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_slice_proof SET early_report_rejected = true;
END
$body$;

UPDATE otlet.jobs job
SET status = 'running',
    attempts = 1,
    started_at = clock_timestamp(),
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
FROM otlet.evaluation_executions execution
WHERE execution.run_hash = (SELECT run_hash FROM evaluation_slice_proof)
  AND execution.job_id = job.id;

DO $body$
DECLARE
  execution record;
  output jsonb;
  actions jsonb;
  generate_ms integer;
  memory_bytes integer;
BEGIN
  FOR execution IN
    SELECT
      evaluation_execution.*,
      evaluation_case.expected_answer,
      evaluation_case.subject_id,
      job.claim_token,
      job.started_at
    FROM otlet.evaluation_executions evaluation_execution
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = evaluation_execution.case_hash
    JOIN otlet.jobs job ON job.id = evaluation_execution.job_id
    WHERE evaluation_execution.run_hash = (
      SELECT run_hash FROM evaluation_slice_proof
    )
    ORDER BY evaluation_execution.variant, evaluation_case.subject_id
  LOOP
    actions := jsonb_build_array(jsonb_build_object(
      'type', 'review_flag',
      'body', jsonb_build_object('reason', 'evaluation slice replay')
    ));
    IF execution.variant = 'baseline' THEN
      output := jsonb_build_object(
        'decision', execution.expected_answer,
        'confidence', 'high'
      );
      generate_ms := CASE execution.subject_id
        WHEN 'slice-a' THEN 10
        WHEN 'slice-b' THEN 20
        WHEN 'slice-c' THEN 30
        ELSE 40
      END;
      memory_bytes := CASE execution.subject_id
        WHEN 'slice-a' THEN 1000
        WHEN 'slice-b' THEN 1100
        WHEN 'slice-c' THEN 1200
        ELSE 1300
      END;
      PERFORM otlet.complete_job(
        job_id => execution.job_id,
        output => output,
        raw_output => jsonb_build_object('output', output, 'actions', actions)::text,
        actions => actions,
        started_at => execution.started_at,
        trace_summary => jsonb_build_object(
          'generate_ms', generate_ms,
          'worker_process_rss_bytes', memory_bytes
        ),
        model_name => 'evaluation_slice_baseline',
        expected_claim_token => execution.claim_token
      );
    ELSIF execution.subject_id = 'slice-a' THEN
      PERFORM otlet.record_model_attempt(
        execution.job_id,
        'evaluation_slice_cheap',
        output => '{"decision":"unclear","confidence":"high"}'::jsonb,
        raw_output => '{"decision":"unclear","confidence":"high"}',
        started_at => execution.started_at,
        trace_summary => '{
          "generate_ms":5,
          "worker_process_rss_bytes":2000
        }'::jsonb,
        selection_role => 'cheap',
        selection_status => 'rejected',
        selection_reason => 'abstained',
        expected_claim_token => execution.claim_token,
        actions => '[]'::jsonb
      );
      output := '{"decision":"approve","confidence":"high"}'::jsonb;
      PERFORM otlet.complete_job(
        job_id => execution.job_id,
        output => output,
        raw_output => jsonb_build_object('output', output, 'actions', actions)::text,
        actions => actions,
        started_at => execution.started_at,
        trace_summary => '{
          "generate_ms":25,
          "worker_process_rss_bytes":3000
        }'::jsonb,
        model_name => 'evaluation_slice_strong',
        selection_role => 'strong',
        selection_reason => 'cheap_abstained',
        expected_claim_token => execution.claim_token
      );
    ELSIF execution.subject_id = 'slice-b' THEN
      output := '{"decision":"approve","confidence":"high"}'::jsonb;
      PERFORM otlet.complete_job(
        job_id => execution.job_id,
        output => output,
        raw_output => jsonb_build_object('output', output, 'actions', actions)::text,
        actions => actions,
        started_at => execution.started_at,
        trace_summary => '{
          "generate_ms":40,
          "worker_process_rss_bytes":4000
        }'::jsonb,
        model_name => 'evaluation_slice_strong',
        selection_role => 'strong',
        expected_claim_token => execution.claim_token
      );
    ELSIF execution.subject_id = 'slice-c' THEN
      PERFORM otlet.record_model_attempt(
        execution.job_id,
        'evaluation_slice_cheap',
        output => '{"decision":"unclear","confidence":"high"}'::jsonb,
        raw_output => '{"decision":"unclear","confidence":"high"}',
        started_at => execution.started_at,
        trace_summary => '{
          "generate_ms":10,
          "worker_process_rss_bytes":2000
        }'::jsonb,
        selection_role => 'cheap',
        selection_status => 'rejected',
        selection_reason => 'abstained',
        expected_claim_token => execution.claim_token,
        actions => '[]'::jsonb
      );
      PERFORM otlet.fail_job(
        job_id => execution.job_id,
        error => 'strong runtime failure',
        raw_output => 'strong runtime failure',
        started_at => execution.started_at,
        schema_validation_status => 'failed',
        trace_summary => '{
          "generate_ms":50,
          "worker_process_rss_bytes":6000
        }'::jsonb,
        model_name => 'evaluation_slice_strong',
        selection_role => 'strong',
        selection_status => 'failed',
        selection_reason => 'runtime_failed',
        candidate_output => NULL,
        expected_claim_token => execution.claim_token
      );
    ELSE
      PERFORM otlet.fail_job(
        job_id => execution.job_id,
        error => 'evaluation abstention',
        raw_output => '{"decision":"unclear","confidence":"high"}',
        started_at => execution.started_at,
        schema_validation_status => 'passed',
        trace_summary => '{
          "generate_ms":50,
          "worker_process_rss_bytes":5000
        }'::jsonb,
        model_name => 'evaluation_slice_cheap',
        selection_role => 'cheap',
        selection_status => 'rejected',
        selection_reason => 'abstained',
        candidate_output => '{"decision":"unclear","confidence":"high"}'::jsonb,
        expected_claim_token => execution.claim_token
      );
    END IF;
  END LOOP;
END
$body$;

DO $body$
DECLARE
  observed_at text := to_char(
    clock_timestamp() AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
  );
BEGIN
  UPDATE evaluation_slice_proof
  SET reviewer_time = (
    SELECT jsonb_agg(
      observation
      ORDER BY observation ->> 'case_hash', observation ->> 'variant'
    )
    FROM (
      SELECT jsonb_build_object(
        'case_hash', case_hash,
        'variant', 'baseline',
        'seconds', CASE fixture_id
          WHEN 'slice-a' THEN 30
          WHEN 'slice-b' THEN 60
          WHEN 'slice-c' THEN 90
          ELSE 120
        END,
        'evidence_hash', otlet.identity_hash(
          'evaluation_reviewer_time',
          jsonb_build_object('fixture_id', fixture_id, 'variant', 'baseline')
        ),
        'observed_at', observed_at
      ) AS observation
      FROM evaluation_slice_cases
      WHERE included
      UNION ALL
      SELECT jsonb_build_object(
        'case_hash', case_hash,
        'variant', 'candidate',
        'seconds', CASE fixture_id
          WHEN 'slice-a' THEN 60
          WHEN 'slice-b' THEN 90
          ELSE 120
        END,
        'evidence_hash', otlet.identity_hash(
          'evaluation_reviewer_time',
          jsonb_build_object('fixture_id', fixture_id, 'variant', 'candidate')
        ),
        'observed_at', observed_at
      )
      FROM evaluation_slice_cases
      WHERE included AND fixture_id <> 'slice-c'
    ) observations
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
        SELECT contract_hash FROM evaluation_slice_proof
      )
    )::timestamptz - clock_timestamp()
  )) + 0.05
)::double precision) \g /dev/null

DO $body$
DECLARE
  proof evaluation_slice_proof%ROWTYPE;
  outside_reviewer_time jsonb;
  repeated_hash text;
BEGIN
  SELECT * INTO proof FROM evaluation_slice_proof;
  BEGIN
    PERFORM otlet.start_replay_evaluation(
      proof.contract_hash,
      ARRAY(
        SELECT case_hash
        FROM evaluation_slice_cases
        WHERE included
        ORDER BY case_hash
      ),
      'evaluation-slices-late-v2',
      'Prove late run rejection'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation run is outside the observation window' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_slice_proof SET late_run_rejected = true;

  BEGIN
    PERFORM otlet.record_evaluation_slice_report(
      proof.incomplete_run_hash,
      '[]'::jsonb,
      'Incomplete evidence probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation slice report requires terminal paired evidence' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_slice_proof SET incomplete_rejected = true;

  outside_reviewer_time := jsonb_set(
    proof.reviewer_time,
    '{0,observed_at}',
    to_jsonb((
      SELECT contract.definition #>> '{observation_window,ends_at}'
      FROM otlet.workload_acceptance_contracts contract
      WHERE contract.contract_hash = proof.contract_hash
    ))
  );
  BEGIN
    PERFORM otlet.record_evaluation_slice_report(
      proof.run_hash,
      outside_reviewer_time,
      'Reviewer observation window probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation reviewer observation is outside the observation window' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_slice_proof SET reviewer_window_rejected = true;

  BEGIN
    UPDATE otlet.inference_receipts receipt
    SET trace_summary = jsonb_set(
      receipt.trace_summary,
      '{worker_process_rss_bytes}',
      '-1'::jsonb,
      true
    )
    FROM otlet.evaluation_executions execution
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = execution.case_hash
    WHERE execution.run_hash = proof.run_hash
      AND execution.variant = 'baseline'
      AND evaluation_case.subject_id = 'slice-a'
      AND receipt.job_id = execution.job_id;
    PERFORM otlet.record_evaluation_slice_report(
      proof.run_hash,
      proof.reviewer_time,
      'Invalid machine measurement probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation machine measurements must be non-negative bounded integers' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_slice_proof SET invalid_measurement_rejected = true;

  BEGIN
    UPDATE otlet.inference_receipts receipt
    SET trace_summary = jsonb_set(
      receipt.trace_summary,
      '{worker_process_rss_bytes}',
      '1.5'::jsonb,
      true
    )
    FROM otlet.evaluation_executions execution
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = execution.case_hash
    WHERE execution.run_hash = proof.run_hash
      AND execution.variant = 'baseline'
      AND evaluation_case.subject_id = 'slice-a'
      AND receipt.job_id = execution.job_id;
    PERFORM otlet.record_evaluation_slice_report(
      proof.run_hash,
      proof.reviewer_time,
      'Fractional machine measurement probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation machine measurements must be non-negative bounded integers' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_slice_proof SET fractional_measurement_rejected = true;

  proof.report_hash := otlet.record_evaluation_slice_report(
    proof.run_hash,
    proof.reviewer_time,
    'Record immutable evaluation slice evidence'
  );
  repeated_hash := otlet.record_evaluation_slice_report(
    proof.run_hash,
    proof.reviewer_time,
    'Record immutable evaluation slice evidence'
  );
  UPDATE evaluation_slice_proof
  SET report_hash = proof.report_hash,
      report_idempotent = repeated_hash = proof.report_hash
        AND (SELECT count(*) FROM otlet.evaluation_slice_reports) = 1;

  BEGIN
    PERFORM otlet.record_evaluation_slice_report(
      proof.run_hash,
      proof.reviewer_time,
      'Conflicting evaluation slice evidence'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation run already has a different slice report' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_slice_proof SET conflict_rejected = true;

  BEGIN
    UPDATE otlet.evaluation_slice_reports
    SET reason = 'changed'
    WHERE report_hash = proof.report_hash;
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation evidence is append only' THEN
      RAISE;
    END IF;
  END;
  UPDATE evaluation_slice_proof SET immutable = true;
END
$body$;

CREATE TEMP TABLE evaluation_slice_expected_fact (
  variant text NOT NULL,
  fixture_id text NOT NULL,
  quality boolean NOT NULL,
  false_trust boolean,
  abstention boolean,
  escalation boolean NOT NULL,
  latency_ms numeric NOT NULL,
  memory_bytes numeric NOT NULL,
  reviewer_seconds numeric
) ON COMMIT DROP;
INSERT INTO evaluation_slice_expected_fact VALUES
  ('baseline', 'slice-a', true,  false, false, false, 10, 1000, 30),
  ('baseline', 'slice-b', true,  false, false, false, 20, 1100, 60),
  ('baseline', 'slice-c', true,  false, false, false, 30, 1200, 90),
  ('baseline', 'slice-d', true,  false, false, false, 40, 1300, 120),
  ('candidate', 'slice-a', true,  false, false, true,  30, 3000, 60),
  ('candidate', 'slice-b', false, true,  false, true,  40, 4000, 90),
  ('candidate', 'slice-c', false, NULL,  NULL,  true,  60, 6000, NULL),
  ('candidate', 'slice-d', false, NULL,  true,  false, 50, 5000, 120);

CREATE TEMP TABLE evaluation_slice_contract ON COMMIT DROP AS
WITH proof AS (
  SELECT * FROM evaluation_slice_proof
), status AS (
  SELECT recorded.*
  FROM otlet.evaluation_slice_status recorded, proof
  WHERE recorded.report_hash = proof.report_hash
), actual_metric AS (
  SELECT
    status.variant,
    status.slice_kind,
    status.slice,
    status.case_support,
    metric.key AS metric,
    metric.value ->> 'statistic' AS statistic,
    metric.value ->> 'unit' AS unit,
    (metric.value ->> 'value')::numeric AS value,
    (metric.value ->> 'support')::integer AS support,
    (metric.value ->> 'minimum_support')::integer AS minimum_support,
    (metric.value ->> 'meets_minimum_support')::boolean AS meets_minimum_support
  FROM status
  CROSS JOIN LATERAL jsonb_each(status.metrics) metric
), expected_expanded AS (
  SELECT
    fact.*,
    fixture.expected_answer,
    fixture.source_table,
    slice.kind AS slice_kind,
    slice.value AS slice
  FROM evaluation_slice_expected_fact fact
  JOIN evaluation_slice_cases fixture USING (fixture_id)
  CROSS JOIN LATERAL (VALUES
    ('overall'::text, jsonb_build_object('all', true)),
    ('expected_answer', jsonb_build_object(
      'expected_answer', fixture.expected_answer
    )),
    ('source_table', jsonb_build_object(
      'source_table', fixture.source_table
    ))
  ) slice(kind, value)
), expected_rollup AS (
  SELECT
    variant,
    slice_kind,
    slice,
    count(*)::integer AS case_support,
    avg(quality::integer)::numeric AS quality,
    count(quality)::integer AS quality_support,
    avg(false_trust::integer)::numeric AS false_trust,
    count(false_trust)::integer AS false_trust_support,
    avg(abstention::integer)::numeric AS abstention,
    count(abstention)::integer AS abstention_support,
    avg(escalation::integer)::numeric AS escalation,
    count(escalation)::integer AS escalation_support,
    avg(latency_ms)::numeric AS latency_ms,
    count(latency_ms)::integer AS latency_support,
    max(memory_bytes)::numeric AS memory_bytes,
    count(memory_bytes)::integer AS memory_support,
    avg(reviewer_seconds)::numeric AS reviewer_seconds,
    count(reviewer_seconds)::integer AS reviewer_support
  FROM expected_expanded
  GROUP BY variant, slice_kind, slice
), expected_metric AS (
  SELECT
    rollup.variant,
    rollup.slice_kind,
    rollup.slice,
    rollup.case_support,
    value.metric,
    value.statistic,
    value.unit,
    value.value,
    value.support,
    3 AS minimum_support,
    value.support >= 3 AS meets_minimum_support
  FROM expected_rollup rollup
  CROSS JOIN LATERAL (VALUES
    ('quality'::text, 'rate'::text, 'ratio'::text,
      rollup.quality, rollup.quality_support),
    ('false_trust', 'rate', 'ratio',
      rollup.false_trust, rollup.false_trust_support),
    ('abstention', 'rate', 'ratio',
      rollup.abstention, rollup.abstention_support),
    ('escalation', 'rate', 'ratio',
      rollup.escalation, rollup.escalation_support),
    ('latency_ms', 'mean', 'milliseconds',
      rollup.latency_ms, rollup.latency_support),
    ('memory_bytes', 'max', 'bytes',
      rollup.memory_bytes, rollup.memory_support),
    ('reviewer_seconds', 'mean', 'seconds',
      rollup.reviewer_seconds, rollup.reviewer_support)
  ) value(metric, statistic, unit, value, support)
), metric_diff AS (
  (
    SELECT * FROM actual_metric
    EXCEPT ALL
    SELECT * FROM expected_metric
  )
  UNION ALL
  (
    SELECT * FROM expected_metric
    EXCEPT ALL
    SELECT * FROM actual_metric
  )
)
SELECT concat_ws('|',
  (SELECT early_run_rejected
     AND late_run_rejected
     AND early_report_rejected
     AND sample_mismatch_rejected
     AND incomplete_rejected
     AND reviewer_window_rejected
     AND invalid_measurement_rejected
     AND fractional_measurement_rejected
     AND report_idempotent
     AND conflict_rejected
     AND immutable
   FROM proof),
  (SELECT count(*) = 10
     AND bool_and(
       eligible_count = 6
       AND labeled_count = 5
       AND included_count = 4
       AND label_coverage = 5::numeric / 6
       AND sample_coverage = 4::numeric / 5
       AND jsonb_array_length(eligible_members) = 6
       AND jsonb_array_length(excluded_cases) = 2
       AND sampling_method #>> '{mode}' = 'sample'
       AND sampling_method #>> '{rule,kind}' = 'stratified'
       AND observation_window ?& ARRAY['starts_at', 'ends_at']
       AND non_authoritative
     )
   FROM status),
  (SELECT count(*) = 70 FROM actual_metric)
    AND NOT EXISTS (SELECT 1 FROM metric_diff),
  (SELECT count(*) = 8
     AND count(*) FILTER (WHERE job.status = 'complete') = 6
     AND count(*) FILTER (WHERE job.status = 'failed') = 2
     AND count(result.result_hash) = 6
   FROM otlet.evaluation_executions execution
   JOIN otlet.jobs job ON job.id = execution.job_id
   LEFT JOIN otlet.evaluation_results result
     ON result.run_hash = execution.run_hash
    AND result.case_hash = execution.case_hash
    AND result.variant = execution.variant
   WHERE execution.run_hash = (SELECT run_hash FROM proof))
  AND (SELECT count(*) = 1
       AND bool_and(receipt.selection_role = 'strong')
       FROM otlet.evaluation_executions execution
       JOIN otlet.evaluation_cases evaluation_case
         ON evaluation_case.case_hash = execution.case_hash
       JOIN otlet.inference_receipts receipt ON receipt.job_id = execution.job_id
       WHERE execution.run_hash = (SELECT run_hash FROM proof)
         AND execution.variant = 'candidate'
         AND evaluation_case.subject_id = 'slice-b')
  AND (SELECT count(*) = 2
       AND count(*) FILTER (
         WHERE receipt.selection_role = 'cheap'
           AND receipt.candidate_output ->> 'decision' = 'unclear'
       ) = 1
       AND count(*) FILTER (
         WHERE receipt.selection_role = 'strong'
           AND receipt.candidate_output IS NULL
       ) = 1
       FROM otlet.evaluation_executions execution
       JOIN otlet.evaluation_cases evaluation_case
         ON evaluation_case.case_hash = execution.case_hash
       JOIN otlet.inference_receipts receipt ON receipt.job_id = execution.job_id
       WHERE execution.run_hash = (SELECT run_hash FROM proof)
         AND execution.variant = 'candidate'
         AND evaluation_case.subject_id = 'slice-c'),
  (SELECT (SELECT count(*) FROM jsonb_object_keys(minimum_support)) = 7
     AND minimum_support #> '{quality}' = '{
       "threshold":"candidate_recall",
       "statistic":"rate",
       "unit":"ratio",
       "minimum_support":3
     }'::jsonb
     AND minimum_support #>> '{memory_bytes,statistic}' = 'max'
     AND minimum_support #>> '{memory_bytes,unit}' = 'bytes'
     AND minimum_support #>> '{reviewer_seconds,unit}' = 'seconds'
   FROM status
   LIMIT 1),
  (SELECT count(*) = 5
     AND count(*) FILTER (
       WHERE evaluation_case.source_table =
         'public.otlet_demo_evaluation_slice_primary'
     ) = 3
     AND count(*) FILTER (
       WHERE evaluation_case.source_table =
         'public.otlet_demo_evaluation_slice_secondary'
     ) = 2
     AND NOT EXISTS (
       SELECT 1
       FROM otlet.evaluation_cases hidden
       WHERE hidden.lineage_hash = (
         SELECT unlabeled_lineage_hash FROM proof
       )
     )
   FROM otlet.evaluation_cases evaluation_case
   WHERE evaluation_case.task_name = 'evaluation_slice_probe_task'),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.evaluation_slice_reports', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
  AND NOT pg_catalog.has_table_privilege(
    'public', 'otlet.evaluation_slice_status', 'SELECT'
  )
  AND NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.record_evaluation_slice_report(text,jsonb,text)',
    'EXECUTE'
  ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
) AS contract;

SELECT pg_temp.assert_true(
  contract = 't|t|t|t|t|t|t|t',
  'evaluation slices and support contract mismatch: ' || contract
)
FROM evaluation_slice_contract;

SELECT 'evaluation_slices_support_contract=' || contract
FROM evaluation_slice_contract;

\ir /work/scripts/demo/production_model_qualification.sql

ROLLBACK;
SQL
