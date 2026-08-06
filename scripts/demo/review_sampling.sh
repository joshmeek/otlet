log "Proving review sampling"

review_sampling_reviewer_role="otlet_review_sampling_reviewer_$$"
review_sampling_contract="$(
  psql_exec -qAt \
    -v model_name="$strong_model_name" \
    -v reviewer_role="$review_sampling_reviewer_role" <<'SQL'
BEGIN;
SET LOCAL client_min_messages TO warning;

DO $$
BEGIN
  PERFORM 1
  FROM otlet.production_policy
  WHERE name = 'default'
  FOR UPDATE;
END;
$$;

CREATE TEMP TABLE review_sampling_proof (
  model_name text NOT NULL,
  thresholds jsonb NOT NULL,
  workload_revision_hash text,
  redacted_workload_revision_hash text,
  contract_hash text,
  task_receipt_id bigint,
  class_receipt_id bigint,
  action_free_receipt_id bigint,
  zero_receipt_id bigint,
  mandatory_receipt_id bigint,
  multi_receipt_id bigint,
  long_receipt_id bigint,
  redacted_receipt_id bigint,
  task_label_id bigint,
  class_label_id bigint,
  action_free_label_id bigint,
  task_case_hash text,
  class_case_hash text,
  action_free_case_hash text,
  sample_run_hash text,
  invalid_rule_rejected boolean NOT NULL DEFAULT false,
  redacted_class_rejected boolean NOT NULL DEFAULT false,
  redaction_preserved boolean NOT NULL DEFAULT false,
  completion_retry_idempotent boolean NOT NULL DEFAULT false,
  label_retry_idempotent boolean NOT NULL DEFAULT false,
  changed_outcome_rejected boolean NOT NULL DEFAULT false,
  stale_outcome_rejected boolean NOT NULL DEFAULT false,
  mandatory_layering_rejected boolean NOT NULL DEFAULT false,
  multi_action_approve_rejected boolean NOT NULL DEFAULT false,
  redacted_approve_rejected boolean NOT NULL DEFAULT false,
  cleanup_preserved boolean NOT NULL DEFAULT false,
  pending_qualification_rejected boolean NOT NULL DEFAULT false
) ON COMMIT DROP;

INSERT INTO review_sampling_proof (model_name, thresholds)
SELECT
  :'model_name',
  jsonb_object_agg(
    category,
    jsonb_build_object(
      'metric', category,
      'statistic', CASE
        WHEN category IN (
          'review_age', 'review_minutes', 'freshness', 'latency', 'recovery'
        ) THEN 'p95'
        ELSE 'rate'
      END,
      'operator', CASE
        WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 'gte'
        ELSE 'lte'
      END,
      'value', CASE
        WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 0.9
        ELSE 0.1
      END,
      'unit', 'ratio',
      'minimum_support', 1,
      'required', true
    )
  )
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

SELECT otlet.create_task(
  'review_sampling_probe',
  NULL,
  'Return one declared review-sampling decision',
  jsonb_set(
    '{
      "type":"object",
      "required":["decision","confidence"],
      "additionalProperties":false,
      "properties":{
        "decision":{},
        "confidence":{"enum":["high"]}
      }
    }'::jsonb,
    '{properties,decision,enum}',
    to_jsonb(ARRAY['task', 'class', 'free', 'zero', repeat('x', 129)])
  ),
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb,
  '{}'::jsonb,
  '{
    "answer_field":"decision",
    "abstain_values":[],
    "confidence_field":"confidence",
    "accepted_confidence":["high"],
    "action_types":["note","review_flag"]
  }'::jsonb
) \g /dev/null

UPDATE review_sampling_proof
SET workload_revision_hash = otlet.ensure_active_workload_revision(
  'review_sampling_probe'
);

DO $$
DECLARE
  proof review_sampling_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM review_sampling_proof;
  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'review_sampling_probe',
      proof.workload_revision_hash,
      proof.workload_revision_hash,
      '{
        "mode":"sample",
        "rule":{
          "kind":"stable_hash",
          "review_sampling":{
            "format":"otlet.review_sampling.v1",
            "task_rate":2
          }
        }
      }'::jsonb,
      clock_timestamp() + interval '1 second',
      clock_timestamp() + interval '1 hour',
      '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
      proof.thresholds
    );
    RAISE EXCEPTION 'invalid review sampling rule unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF position(
      'review_sampling task_rate must be between 0 and 1' IN SQLERRM
    ) = 0 THEN
      RAISE;
    END IF;
    UPDATE review_sampling_proof SET invalid_rule_rejected = true;
  END;
END;
$$;

UPDATE review_sampling_proof
SET contract_hash = otlet.register_workload_acceptance_contract(
  'review_sampling_probe',
  workload_revision_hash,
  workload_revision_hash,
  '{
    "mode":"sample",
    "rule":{
      "kind":"stable_hash",
      "basis":"receipt_id",
      "review_sampling":{
        "format":"otlet.review_sampling.v1",
        "task_rate":1,
        "decision_class_rates":{"class":1,"zero":0},
        "action_free_rate":1
      }
    }
  }'::jsonb,
  clock_timestamp() + interval '100 milliseconds',
  clock_timestamp() + interval '1 hour',
  '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
  thresholds
);

SELECT pg_sleep(0.15) \g /dev/null

DO $$
DECLARE
  proof review_sampling_proof%ROWTYPE;
  item record;
  v_job_id bigint;
  v_claim_token text;
  v_output_id bigint;
  v_receipt_id bigint;
  v_repeated_output_id bigint;
  v_attempt_started_at timestamptz;
  v_output_body jsonb;
  v_actions_body jsonb;
  v_raw_output text;
  v_trace_summary jsonb := '{"schema_validation_status":"passed","generate_ms":1}'::jsonb;
  v_sample_count bigint;
  v_sample_hash text;
BEGIN
  SELECT * INTO proof FROM review_sampling_proof;
  FOR item IN
    SELECT *
    FROM (VALUES
      (1, 'task-sample', 'task', 'note', 1),
      (2, 'class-sample', 'class', 'note', 1),
      (3, 'action-free-sample', 'free', NULL, 0),
      (4, 'zero-class-control', 'zero', 'note', 1),
      (5, 'mandatory-sample', 'task', 'review_flag', 1),
      (6, 'multi-action-sample', 'task', 'note', 2),
      (7, 'long-task-sample', repeat('x', 129), 'note', 1)
    ) fixture(ordinal, subject_id, decision, action_type, action_count)
    ORDER BY ordinal
  LOOP
    v_claim_token := gen_random_uuid()::text;
    v_attempt_started_at := clock_timestamp();
    v_output_body := jsonb_build_object(
      'decision', item.decision,
      'confidence', 'high'
    );
    v_actions_body := CASE
      WHEN item.action_count = 0 THEN '[]'::jsonb
      WHEN item.action_count = 2 THEN jsonb_build_array(
        jsonb_build_object(
          'type', item.action_type,
          'body', jsonb_build_object(
            'subject_id', item.subject_id,
            'text', 'First review sampling fixture'
          )
        ),
        jsonb_build_object(
          'type', item.action_type,
          'body', jsonb_build_object(
            'subject_id', item.subject_id,
            'text', 'Second review sampling fixture'
          )
        )
      )
      ELSE jsonb_build_array(
        jsonb_build_object(
          'type', item.action_type,
          'body', CASE
            WHEN item.action_type = 'review_flag' THEN
              jsonb_build_object('reason', 'Review sampling fixture')
            ELSE jsonb_build_object(
              'subject_id', item.subject_id,
              'text', 'Review sampling fixture'
            )
          END
        )
      )
    END;
    v_raw_output := jsonb_build_object(
      'output', v_output_body,
      'actions', v_actions_body
    )::text;

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
      'review_sampling_probe',
      proof.workload_revision_hash,
      item.subject_id,
      '{}'::jsonb,
      'running',
      1,
      v_attempt_started_at,
      v_attempt_started_at + interval '5 minutes',
      v_claim_token
    )
    RETURNING id INTO v_job_id;

    SELECT completed.id
    INTO v_output_id
    FROM otlet.complete_job(
      job_id => v_job_id,
      output => v_output_body,
      raw_output => v_raw_output,
      actions => v_actions_body,
      started_at => v_attempt_started_at,
      trace_summary => v_trace_summary,
      model_name => proof.model_name,
      expected_claim_token => v_claim_token
    ) completed;
    SELECT output.receipt_id
    INTO v_receipt_id
    FROM otlet.outputs output
    WHERE output.id = v_output_id;

    UPDATE review_sampling_proof
    SET task_receipt_id = CASE
          WHEN item.subject_id = 'task-sample' THEN v_receipt_id
          ELSE task_receipt_id
        END,
        class_receipt_id = CASE
          WHEN item.decision = 'class' THEN v_receipt_id ELSE class_receipt_id
        END,
        action_free_receipt_id = CASE
          WHEN item.decision = 'free' THEN v_receipt_id ELSE action_free_receipt_id
        END,
        zero_receipt_id = CASE
          WHEN item.decision = 'zero' THEN v_receipt_id ELSE zero_receipt_id
        END,
        mandatory_receipt_id = CASE
          WHEN item.subject_id = 'mandatory-sample' THEN v_receipt_id
          ELSE mandatory_receipt_id
        END,
        multi_receipt_id = CASE
          WHEN item.subject_id = 'multi-action-sample' THEN v_receipt_id
          ELSE multi_receipt_id
        END,
        long_receipt_id = CASE
          WHEN item.subject_id = 'long-task-sample' THEN v_receipt_id
          ELSE long_receipt_id
        END;

    IF item.subject_id = 'task-sample' THEN
      SELECT count(*), min(sample.sample_hash)
      INTO v_sample_count, v_sample_hash
      FROM otlet.review_samples sample
      WHERE sample.receipt_id = v_receipt_id;
      SELECT completed.id
      INTO v_repeated_output_id
      FROM otlet.complete_job(
        job_id => v_job_id,
        output => v_output_body,
        raw_output => v_raw_output,
        actions => v_actions_body,
        started_at => v_attempt_started_at,
        trace_summary => v_trace_summary,
        model_name => proof.model_name,
        expected_claim_token => v_claim_token
      ) completed;
      UPDATE review_sampling_proof
      SET completion_retry_idempotent = v_repeated_output_id = v_output_id
        AND v_sample_count = 1
        AND (
          SELECT count(*) = 1
            AND min(sample.sample_hash) = v_sample_hash
          FROM otlet.review_samples sample
          WHERE sample.receipt_id = v_receipt_id
        );
    END IF;
  END LOOP;
END;
$$;

SELECT otlet.create_task(
  'review_sampling_redacted_probe',
  NULL,
  'Return one private review-sampling decision',
  '{
    "type":"object",
    "required":["decision","confidence"],
    "additionalProperties":false,
    "properties":{
      "decision":{"type":"string"},
      "confidence":{"enum":["high"]}
    }
  }'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb,
  '{}'::jsonb,
  '{
    "answer_field":"decision",
    "abstain_values":[],
    "confidence_field":"confidence",
    "accepted_confidence":["high"],
    "action_types":[],
    "redact_output_fields":["decision"]
  }'::jsonb
) \g /dev/null

UPDATE review_sampling_proof
SET redacted_workload_revision_hash = otlet.ensure_active_workload_revision(
  'review_sampling_redacted_probe'
);

DO $$
DECLARE
  proof review_sampling_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM review_sampling_proof;
  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'review_sampling_redacted_probe',
      proof.redacted_workload_revision_hash,
      proof.redacted_workload_revision_hash,
      '{
        "mode":"sample",
        "rule":{
          "kind":"stable_hash",
          "review_sampling":{
            "format":"otlet.review_sampling.v1",
            "decision_class_rates":{"private":1}
          }
        }
      }'::jsonb,
      clock_timestamp() + interval '1 second',
      clock_timestamp() + interval '1 hour',
      '{"name":"active_revision","definition":{"kind":"workload_revision"}}',
      proof.thresholds
    );
    RAISE EXCEPTION 'redacted decision-class sampling unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF position(
      'review_sampling decision classes cannot use a redacted answer field'
      IN SQLERRM
    ) = 0 THEN
      RAISE;
    END IF;
    UPDATE review_sampling_proof SET redacted_class_rejected = true;
  END;
END;
$$;

SELECT otlet.register_workload_acceptance_contract(
  'review_sampling_redacted_probe',
  (SELECT redacted_workload_revision_hash FROM review_sampling_proof),
  (SELECT redacted_workload_revision_hash FROM review_sampling_proof),
  '{
    "mode":"sample",
    "rule":{
      "kind":"stable_hash",
      "review_sampling":{
        "format":"otlet.review_sampling.v1",
        "task_rate":1
      }
    }
  }'::jsonb,
  clock_timestamp() + interval '100 milliseconds',
  clock_timestamp() + interval '1 hour',
  '{"name":"active_revision","definition":{"kind":"workload_revision"}}',
  (SELECT thresholds FROM review_sampling_proof)
) \g /dev/null

SELECT pg_sleep(0.15) \g /dev/null

DO $$
DECLARE
  job_id bigint;
  saved_output_id bigint;
  saved_receipt_id bigint;
  output jsonb := '{"decision":"private","confidence":"high"}'::jsonb;
  started_at timestamptz := clock_timestamp();
BEGIN
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
    'review_sampling_redacted_probe',
    (SELECT redacted_workload_revision_hash FROM review_sampling_proof),
    'private-sample',
    '{}'::jsonb,
    'running',
    1,
    started_at,
    started_at + interval '5 minutes',
    'review-sampling-redacted'
  ) RETURNING id INTO job_id;
  SELECT completed.id INTO saved_output_id
  FROM otlet.complete_job(
    job_id => job_id,
    output => output,
    raw_output => jsonb_build_object('output', output, 'actions', '[]'::jsonb)::text,
    actions => '[]'::jsonb,
    started_at => started_at,
    trace_summary => '{"schema_validation_status":"passed","generate_ms":1}',
    model_name => (SELECT model_name FROM review_sampling_proof),
    expected_claim_token => 'review-sampling-redacted'
  ) completed;
  SELECT stored.receipt_id INTO saved_receipt_id
  FROM otlet.outputs stored
  WHERE stored.id = saved_output_id;
  UPDATE review_sampling_proof
  SET redacted_receipt_id = saved_receipt_id,
      redaction_preserved = (
    SELECT stored.output ->> 'decision' = '[REDACTED]'
      AND sample.decision_class IS NULL
      AND sample.sampling_scope = 'task'
      AND NOT sample.definition::text LIKE '%private%'
      AND audit.decision_class IS NULL
    FROM otlet.outputs stored
    JOIN otlet.review_samples sample ON sample.output_id = stored.id
    JOIN otlet.audit_review_sample_export audit
      ON audit.sample_hash = sample.sample_hash
    WHERE stored.id = saved_output_id
  );
END;
$$;

CREATE TEMP TABLE review_sampling_queue_snapshot ON COMMIT DROP AS
SELECT
  (SELECT count(*) FROM otlet.review_samples sample
   WHERE sample.task_name = 'review_sampling_probe') AS samples,
  (SELECT count(*) FROM otlet.review_samples sample
   WHERE sample.task_name = 'review_sampling_probe'
     AND sample.sampling_scope = 'task') AS task_samples,
  (SELECT count(*) FROM otlet.review_samples sample
   WHERE sample.task_name = 'review_sampling_probe'
     AND sample.sampling_scope = 'decision_class') AS class_samples,
  (SELECT count(*) FROM otlet.review_samples sample
   WHERE sample.task_name = 'review_sampling_probe'
     AND sample.sampling_scope = 'action_free') AS action_free_samples,
  (SELECT count(*) FROM otlet.review_samples sample
   JOIN review_sampling_proof proof ON sample.receipt_id = proof.zero_receipt_id)
    AS zero_samples,
  (SELECT count(*) = 1
      AND bool_and(sample.decision_class IS NULL)
      AND bool_and(sample.sampling_scope = 'task')
      AND bool_and(NOT sample.definition ? 'decision_class')
   FROM otlet.review_samples sample
   JOIN review_sampling_proof proof ON sample.receipt_id = proof.long_receipt_id)
    AS long_task_bounded,
  (SELECT count(*) FROM otlet.review_queue queue
   WHERE queue.task_name = 'review_sampling_probe'
     AND queue.queue_kind = 'sampled_output'
     AND queue.next_operator_step = 'label_sample') AS queue_rows,
  (SELECT count(*) FROM otlet.audit_review_export audit
   WHERE audit.task_name = 'review_sampling_probe'
     AND audit.queue_kind = 'sampled_output') AS queue_audit_rows,
  (SELECT count(*) FROM otlet.audit_review_sample_export audit
   WHERE audit.task_name = 'review_sampling_probe'
     AND audit.review_state = 'pending_review') AS sample_audit_rows,
  (SELECT count(*) FROM otlet.evaluation_cases evaluation_case
   WHERE evaluation_case.task_name = 'review_sampling_probe') AS automatic_cases,
  (SELECT count(*) FROM otlet.evaluation_runs run
   WHERE run.task_name = 'review_sampling_probe') AS automatic_runs,
  (SELECT count(*) FROM otlet.jobs job
   WHERE job.task_name = 'review_sampling_probe'
     AND job.execution_mode = 'evaluation') AS automatic_evaluation_jobs,
  (SELECT count(*) FROM otlet.workload_acceptance_events event
   JOIN review_sampling_proof proof ON event.contract_hash = proof.contract_hash)
    AS automatic_promotion_events;

SELECT format('CREATE ROLE %I NOLOGIN', :'reviewer_role') \gexec
SELECT otlet.grant_reviewer_access(:'reviewer_role'::regrole) \g /dev/null

SELECT
  task_receipt_id AS task_receipt_id,
  class_receipt_id AS class_receipt_id,
  action_free_receipt_id AS action_free_receipt_id
FROM review_sampling_proof \gset review_sampling_

SELECT format('SET LOCAL ROLE %I', :'reviewer_role') \gexec
SELECT label.id AS label_id
FROM otlet.label_review_sample(
  :'review_sampling_task_receipt_id'::bigint,
  'task',
  'high',
  'note',
  'approve',
  'Task sample reviewed'
) label \gset review_sampling_task_
SELECT label.id AS label_id
FROM otlet.label_review_sample(
  :'review_sampling_class_receipt_id'::bigint,
  'task',
  'high',
  'none',
  'correct',
  'Decision class sample reviewed'
) label \gset review_sampling_class_
SELECT label.id AS label_id
FROM otlet.label_review_sample(
  :'review_sampling_action_free_receipt_id'::bigint,
  'free',
  'high',
  'none',
  'approve',
  'Action-free sample reviewed'
) label \gset review_sampling_action_free_
SELECT label.id AS repeated_label_id
FROM otlet.label_review_sample(
  :'review_sampling_action_free_receipt_id'::bigint,
  'free',
  'high',
  'none',
  'approve',
  'Action-free sample reviewed'
) label \gset review_sampling_action_free_retry_
RESET ROLE;

DO $$
DECLARE
  proof review_sampling_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM review_sampling_proof;
  BEGIN
    PERFORM otlet.label_review_sample(
      proof.action_free_receipt_id,
      'free',
      'high',
      'none',
      'correct',
      'Action-free sample reviewed'
    );
    RAISE EXCEPTION 'changed sample outcome unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review sample already has a different outcome' THEN
      RAISE;
    END IF;
    UPDATE review_sampling_proof SET changed_outcome_rejected = true;
  END;
END;
$$;

DO $$
DECLARE
  proof review_sampling_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM review_sampling_proof;
  BEGIN
    PERFORM otlet.label_review_sample(
      proof.mandatory_receipt_id,
      'task',
      'high',
      'review_flag',
      'approve',
      'Mandatory review owns this sample'
    );
    RAISE EXCEPTION 'mandatory review sample labeling unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review sample is not eligible for sampled review' THEN
      RAISE;
    END IF;
    UPDATE review_sampling_proof SET mandatory_layering_rejected = true;
  END;
END;
$$;

DO $$
DECLARE
  proof review_sampling_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM review_sampling_proof;
  BEGIN
    PERFORM otlet.label_review_sample(
      proof.multi_receipt_id,
      'task',
      'high',
      'note',
      'approve',
      'Multiple actions cannot be approved as one sample'
    );
    RAISE EXCEPTION 'multi-action sample approval unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
       'otlet approved review sample does not match its evidence' THEN
      RAISE;
    END IF;
    UPDATE review_sampling_proof
    SET multi_action_approve_rejected = true;
  END;
END;
$$;

DO $$
DECLARE
  proof review_sampling_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM review_sampling_proof;
  BEGIN
    PERFORM otlet.label_review_sample(
      proof.redacted_receipt_id,
      'private',
      'high',
      'none',
      'approve',
      'Redacted evidence cannot be approved'
    );
    RAISE EXCEPTION 'redacted sample approval unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
       'otlet approved review sample does not match its evidence' THEN
      RAISE;
    END IF;
    UPDATE review_sampling_proof SET redacted_approve_rejected = true;
  END;
END;
$$;

UPDATE review_sampling_proof
SET task_label_id = :'review_sampling_task_label_id'::bigint,
    class_label_id = :'review_sampling_class_label_id'::bigint,
    action_free_label_id = :'review_sampling_action_free_label_id'::bigint,
    label_retry_idempotent =
      :'review_sampling_action_free_label_id'::bigint =
        :'review_sampling_action_free_retry_repeated_label_id'::bigint
      AND (
        SELECT count(*) = 3
        FROM otlet.eval_labels label
        WHERE label.receipt_id IN (
          task_receipt_id,
          class_receipt_id,
          action_free_receipt_id
        )
      );

DO $$
DECLARE
  proof review_sampling_proof%ROWTYPE;
  replacement_label_id bigint;
BEGIN
  SELECT * INTO proof FROM review_sampling_proof;
  PERFORM otlet.adjudicate_eval_label(
    proof.task_label_id,
    'rejected',
    0.9,
    'Reject first sampled label'
  );
  SELECT label.id INTO replacement_label_id
  FROM otlet.label_review_sample(
    proof.task_receipt_id,
    'task',
    'high',
    'note',
    'correct',
    'Task sample reviewed'
  ) label;
  UPDATE review_sampling_proof SET task_label_id = replacement_label_id;
  BEGIN
    PERFORM otlet.label_review_sample(
      proof.task_receipt_id,
      'task',
      'high',
      'note',
      'approve',
      'Task sample reviewed'
    );
    RAISE EXCEPTION 'stale review outcome retry unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review sample already has a different outcome' THEN
      RAISE;
    END IF;
    UPDATE review_sampling_proof SET stale_outcome_rejected = true;
  END;
END;
$$;

ALTER TABLE otlet.eval_labels DISABLE TRIGGER eval_labels_c_adjudication;
UPDATE otlet.eval_labels
SET created_at = created_at - interval '2 days',
    adjudicated_at = adjudicated_at - interval '2 days'
WHERE task_name = 'review_sampling_probe';
ALTER TABLE otlet.eval_labels ENABLE TRIGGER eval_labels_c_adjudication;
UPDATE otlet.production_policy
SET eval_label_retention = interval '1 day'
WHERE name = 'default';
CREATE TEMP TABLE review_sampling_cleanup_preview AS
SELECT * FROM otlet.cleanup_policy_state(true);
SELECT otlet.create_maintenance_run('cleanup') AS review_cleanup_run_id \gset
CREATE TEMP TABLE review_sampling_cleanup AS
SELECT * FROM otlet.run_maintenance_slice(:review_cleanup_run_id, 0);

UPDATE review_sampling_proof
SET cleanup_preserved = (
      SELECT count(*) = 3
      FROM otlet.eval_labels label
      WHERE label.id IN (
        task_label_id,
        class_label_id,
        action_free_label_id
      )
    )
    AND (
      SELECT count(*) = 2
        AND bool_and(queue.receipt_id IN (multi_receipt_id, long_receipt_id))
      FROM otlet.review_queue queue
      WHERE queue.task_name = 'review_sampling_probe'
        AND queue.queue_kind = 'sampled_output'
    )
    AND (
      SELECT control_state = 'complete' AND processed_items = 0
      FROM review_sampling_cleanup
    )
    AND (
      SELECT eval_labels = 0
      FROM review_sampling_cleanup_preview
    );

DO $$
DECLARE
  proof review_sampling_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM review_sampling_proof;
  BEGIN
    PERFORM otlet.register_evaluation_case(
      proof.action_free_label_id,
      'qualification',
      'Pending sample qualification probe'
    );
    RAISE EXCEPTION 'pending sample qualification unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet qualification evaluation label is not eligible' THEN
      RAISE;
    END IF;
    UPDATE review_sampling_proof
    SET pending_qualification_rejected = true;
  END;
END;
$$;

UPDATE review_sampling_proof
SET task_case_hash = otlet.register_evaluation_case(
      task_label_id,
      'tuning',
      'Task review sample tuning case'
    ),
    class_case_hash = otlet.register_evaluation_case(
      class_label_id,
      'tuning',
      'Decision class review sample tuning case'
    ),
    action_free_case_hash = otlet.register_evaluation_case(
      action_free_label_id,
      'tuning',
      'Action-free review sample tuning case'
    );

UPDATE review_sampling_proof
SET sample_run_hash = otlet.start_replay_evaluation(
  contract_hash,
  ARRAY[class_case_hash, action_free_case_hash],
  'review-sampling-none-v1',
  'Replay action-free and corrected-to-none samples'
);

UPDATE otlet.jobs job
SET status = 'running',
    attempts = 1,
    started_at = clock_timestamp(),
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
FROM otlet.evaluation_executions execution
JOIN review_sampling_proof proof
  ON proof.sample_run_hash = execution.run_hash
WHERE job.id = execution.job_id;

DO $$
DECLARE
  proof review_sampling_proof%ROWTYPE;
  execution record;
  replay_output jsonb;
BEGIN
  SELECT * INTO proof FROM review_sampling_proof;
  FOR execution IN
    SELECT
      job.id,
      job.started_at,
      job.claim_token,
      evaluation_case.expected_answer,
      evaluation_case.expected_confidence
    FROM otlet.evaluation_executions evaluated
    JOIN otlet.jobs job ON job.id = evaluated.job_id
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = evaluated.case_hash
    WHERE evaluated.run_hash = proof.sample_run_hash
    ORDER BY evaluated.case_hash, evaluated.variant
  LOOP
    replay_output := jsonb_build_object(
      'decision', execution.expected_answer,
      'confidence', execution.expected_confidence
    );
    PERFORM otlet.complete_job(
      job_id => execution.id,
      output => replay_output,
      raw_output => jsonb_build_object(
        'output', replay_output,
        'actions', '[]'::jsonb
      )::text,
      actions => '[]'::jsonb,
      started_at => execution.started_at,
      trace_summary => '{"schema_validation_status":"passed","generate_ms":1}',
      model_name => proof.model_name,
      expected_claim_token => execution.claim_token
    );
  END LOOP;
END;
$$;

CREATE FUNCTION pg_temp.review_sample_history_is_immutable(operation text)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    IF operation = 'update' THEN
      UPDATE otlet.review_samples
      SET selected_at = selected_at
      WHERE task_name = 'review_sampling_probe';
    ELSIF operation = 'delete' THEN
      DELETE FROM otlet.review_samples
      WHERE task_name = 'review_sampling_probe';
    ELSE
      TRUNCATE otlet.review_samples;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM = 'otlet review samples are append only';
  END;
  RETURN false;
END;
$function$;

CREATE TEMP TABLE review_sampling_immutability ON COMMIT DROP AS
SELECT
  pg_temp.review_sample_history_is_immutable('update') AS update_guarded,
  pg_temp.review_sample_history_is_immutable('delete') AS delete_guarded,
  pg_temp.review_sample_history_is_immutable('truncate') AS truncate_guarded;

SELECT concat_ws('|',
  proof.invalid_rule_rejected,
  proof.redacted_class_rejected,
  proof.redaction_preserved,
  proof.completion_retry_idempotent,
  snapshot.samples = 6
    AND snapshot.task_samples = 4
    AND snapshot.class_samples = 1
    AND snapshot.action_free_samples = 1
    AND snapshot.zero_samples = 0
    AND snapshot.long_task_bounded,
  snapshot.queue_rows = 5
    AND snapshot.queue_audit_rows = 5
    AND snapshot.sample_audit_rows = 6,
  snapshot.automatic_cases = 0
    AND snapshot.automatic_runs = 0
    AND snapshot.automatic_evaluation_jobs = 0
    AND snapshot.automatic_promotion_events = 0,
  proof.label_retry_idempotent,
  proof.changed_outcome_rejected,
  proof.stale_outcome_rejected,
  proof.mandatory_layering_rejected,
  proof.multi_action_approve_rejected,
  proof.redacted_approve_rejected,
  proof.cleanup_preserved,
  (SELECT count(*) = 4
     AND count(*) FILTER (WHERE outcome = 'approve') = 2
     AND count(*) FILTER (WHERE outcome = 'correct') = 2
     AND bool_and(action_id IS NULL)
     AND count(DISTINCT receipt_id) = 3
   FROM otlet.review_events event
   WHERE event.task_name = 'review_sampling_probe'),
  (SELECT count(*) = 3
   FROM otlet.eval_labels label
   WHERE label.id IN (
     proof.task_label_id,
     proof.class_label_id,
     proof.action_free_label_id
   )
     AND label.action_id IS NULL
     AND label.output_id IS NOT NULL
     AND label.receipt_id IS NOT NULL
     AND label.adjudication_state = 'pending'),
  (SELECT expected_action_type = 'none'
     AND observed_answer = 'free'
   FROM otlet.eval_label_status
   WHERE label_id = proof.action_free_label_id),
  (SELECT count(*) = 2
     AND bool_and(queue.receipt_id IN (
       proof.multi_receipt_id,
       proof.long_receipt_id
     ))
   FROM otlet.review_queue queue
   WHERE queue.task_name = 'review_sampling_probe'
     AND queue.queue_kind = 'sampled_output'),
  proof.pending_qualification_rejected,
  (SELECT count(*) = 3
     AND bool_and(population_kind = 'tuning')
   FROM otlet.evaluation_cases evaluation_case
   WHERE evaluation_case.task_name = 'review_sampling_probe'),
  (SELECT count(*) = 6
     AND count(*) FILTER (
       WHERE evaluation_population = 'tuning'
         AND review_state = 'pending_adjudication'
     ) = 3
     AND count(*) FILTER (
       WHERE evaluation_population IS NULL
         AND review_state = 'pending_review'
     ) = 3
   FROM otlet.audit_review_sample_export audit
   WHERE audit.task_name = 'review_sampling_probe'),
  (SELECT count(*) = 1
   FROM otlet.evaluation_runs run
   WHERE run.run_hash = proof.sample_run_hash)
    AND (SELECT count(*) = 4
         FROM otlet.jobs job
         JOIN otlet.evaluation_executions execution
           ON execution.job_id = job.id
         WHERE execution.run_hash = proof.sample_run_hash
           AND job.execution_mode = 'evaluation'
           AND job.status = 'complete')
    AND (SELECT count(*) = 4
           AND bool_and(
             (result.approval_diff ->> 'expected_action_present')::boolean
             AND (result.approval_diff ->> 'matches_expected')::boolean
             AND result.approval_diff -> 'proposed_action_types' = '[]'::jsonb
             AND result.approval_diff -> 'valid_action_types' = '[]'::jsonb
           )
         FROM otlet.evaluation_results result
         WHERE result.run_hash = proof.sample_run_hash)
    AND (SELECT count(*) = 0
         FROM otlet.workload_acceptance_events event
         WHERE event.contract_hash = proof.contract_hash)
    AND (SELECT active_workload_revision_hash = proof.workload_revision_hash
         FROM otlet.workload_revision_heads head
         WHERE head.task_name = 'review_sampling_probe'),
  immutability.update_guarded
    AND immutability.delete_guarded
    AND immutability.truncate_guarded,
  pg_catalog.has_table_privilege(
    :'reviewer_role',
    'otlet.reviewer_review_queue',
    'SELECT'
  )
    AND NOT pg_catalog.has_table_privilege(
      :'reviewer_role',
      'otlet.audit_review_sample_export',
      'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      :'reviewer_role',
      'otlet.review_samples',
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
    )
    AND pg_catalog.has_function_privilege(
      :'reviewer_role',
      'otlet.label_review_sample(bigint,text,text,text,text,text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      :'reviewer_role',
      'otlet.register_evaluation_case(bigint,text,text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      :'reviewer_role',
      'otlet.adjudicate_eval_label(bigint,text,numeric,text,bigint)',
      'EXECUTE'
    ),
  (SELECT operator_functions = 3
     AND operator_security_definer_functions = 3
     AND operator_fixed_search_path_functions = 3
     AND reviewer_functions = 8
     AND reviewer_security_definer_functions = 8
     AND reviewer_fixed_search_path_functions = 8
     AND NOT public_schema_usage
     AND public_executable_functions = 0
     AND public_table_privileges = 0
     AND public_sequence_privileges = 0
   FROM otlet.access_policy_status),
  NOT pg_catalog.has_table_privilege(
    'public',
    'otlet.review_samples',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.review_queue_without_review_samples',
      'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.audit_review_sample_export',
      'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname IN (
          'review_sampling_rule_error',
          'validate_workload_acceptance_review_sampling',
          'review_sampling_choice',
          'guard_review_sample_append',
          'validate_review_sample',
          'record_review_sample',
          'label_review_sample'
        )
        AND pg_catalog.has_function_privilege(
          'public', function.oid, 'EXECUTE'
        )
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
)
FROM review_sampling_proof proof
CROSS JOIN review_sampling_queue_snapshot snapshot
CROSS JOIN review_sampling_immutability immutability;
ROLLBACK;
SQL
)"

echo "review_sampling_contract=$review_sampling_contract"
[ "$review_sampling_contract" = \
  "t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Review sampling contract mismatch: $review_sampling_contract" >&2
  exit 1
}
