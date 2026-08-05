log "Proving pair constraint ledger"
pair_constraint_contract="$(psql_exec -qAt \
  -v task_name="$join_task" \
  -v model_name="$cheap_model_name" <<'SQL'
BEGIN;

CREATE TEMP TABLE pair_constraint_proof (
  task_name text NOT NULL,
  model_name text NOT NULL,
  same_subject text NOT NULL,
  different_subject text NOT NULL,
  duplicate_rejection_blocked boolean NOT NULL DEFAULT false,
  initial_facts_active boolean NOT NULL DEFAULT false,
  approval_export_control boolean NOT NULL DEFAULT false,
  conflict_detected boolean NOT NULL DEFAULT false,
  review_routed boolean NOT NULL DEFAULT false,
  approval_blocked boolean NOT NULL DEFAULT false,
  promotion_blocked boolean NOT NULL DEFAULT false,
  head_insert_blocked boolean NOT NULL DEFAULT false,
  export_blocked boolean NOT NULL DEFAULT false,
  analysis_limit_blocked boolean NOT NULL DEFAULT false,
  conflicting_materializations_stale boolean NOT NULL DEFAULT false,
  source_reopened boolean NOT NULL DEFAULT false,
  conflict_cleared boolean NOT NULL DEFAULT false,
  contract_reopened boolean NOT NULL DEFAULT false,
  facts_immutable boolean NOT NULL DEFAULT false,
  invariants_clean boolean NOT NULL DEFAULT false
) ON COMMIT DROP;

INSERT INTO pair_constraint_proof (
  task_name,
  model_name,
  same_subject,
  different_subject
) VALUES (
  :'task_name',
  :'model_name',
  'vendor-1001:vendor-42',
  'vendor-1001:vendor-313'
);

CREATE TEMP TABLE pair_constraint_jobs (
  fixture text PRIMARY KEY,
  job_id bigint NOT NULL,
  action_id bigint NOT NULL,
  output_id bigint NOT NULL,
  semantic_materialized boolean,
  materialization_error text
) ON COMMIT DROP;

CREATE FUNCTION pg_temp.complete_pair_constraint_job(
  fixture text,
  subject_id text,
  answer text
) RETURNS pair_constraint_jobs
LANGUAGE plpgsql
AS $function$
DECLARE
  proof pair_constraint_proof%ROWTYPE;
  revision_hash text;
  job_input jsonb;
  claim_token text := gen_random_uuid()::text;
  output jsonb;
  actions jsonb;
  envelope jsonb;
  saved_job_id bigint;
  saved_action_id bigint;
  completion record;
  saved pair_constraint_jobs%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM pair_constraint_proof;
  SELECT head.active_workload_revision_hash
  INTO revision_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = proof.task_name;
  job_input := otlet.current_task_subject_input_snapshot(
    proof.task_name,
    complete_pair_constraint_job.subject_id,
    revision_hash
  );
  IF job_input IS NULL THEN
    RAISE EXCEPTION 'pair constraint proof subject % is unavailable',
      complete_pair_constraint_job.subject_id;
  END IF;

  output := jsonb_build_object(
    'match', complete_pair_constraint_job.answer,
    'confidence', 'high',
    'reason', 'controlled pair constraint fixture'
  );
  actions := jsonb_build_array(jsonb_build_object(
    'type', CASE complete_pair_constraint_job.answer
      WHEN 'same_entity' THEN 'merge_candidate'
      WHEN 'different_entity' THEN 'new_entity'
    END,
    'body', CASE complete_pair_constraint_job.answer
      WHEN 'same_entity' THEN jsonb_build_object(
        'left_id', job_input #>> '{action_ids,left_id}',
        'right_id', job_input #>> '{action_ids,right_id}',
        'reason', 'controlled merge'
      )
      WHEN 'different_entity' THEN jsonb_build_object(
        'entity_id', job_input #>> '{action_ids,right_id}',
        'reason', 'controlled separation'
      )
    END
  ));
  envelope := jsonb_build_object('output', output, 'actions', actions);

  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    routed_model_name,
    status,
    attempts,
    started_at,
    leased_until,
    claim_token
  ) VALUES (
    proof.task_name,
    revision_hash,
    complete_pair_constraint_job.subject_id,
    job_input,
    proof.model_name,
    'running',
    1,
    clock_timestamp(),
    clock_timestamp() + interval '5 minutes',
    claim_token
  )
  RETURNING id INTO saved_job_id;

  SELECT *
  INTO completion
  FROM otlet.complete_and_materialize_job(
    job_id => saved_job_id,
    output => output,
    raw_output => envelope::text,
    actions => actions,
    prompt_hash => NULL,
    input_hash => NULL,
    output_schema_hash => NULL,
    raw_output_hash => otlet.portable_text_hash(envelope::text),
    trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
    model_name => proof.model_name,
    selection_role => 'cheap',
    selection_reason => 'controlled_pair_constraint_fixture',
    expected_claim_token => claim_token
  );

  SELECT action.id
  INTO saved_action_id
  FROM otlet.actions action
  WHERE action.job_id = saved_job_id
    AND action.action_type = CASE complete_pair_constraint_job.answer
      WHEN 'same_entity' THEN 'merge_candidate'
      WHEN 'different_entity' THEN 'new_entity'
    END;
  IF saved_action_id IS NULL OR completion.output_id IS NULL THEN
    RAISE EXCEPTION 'pair constraint proof completion failed: %',
      COALESCE(completion.completion_error, 'missing action');
  END IF;

  INSERT INTO pair_constraint_jobs (
    fixture,
    job_id,
    action_id,
    output_id,
    semantic_materialized,
    materialization_error
  ) VALUES (
    complete_pair_constraint_job.fixture,
    saved_job_id,
    saved_action_id,
    completion.output_id,
    completion.semantic_materialized,
    completion.materialization_error
  )
  RETURNING * INTO saved;
  RETURN saved;
END;
$function$;

SELECT pg_temp.complete_pair_constraint_job(
  'correction',
  different_subject,
  'same_entity'
)
FROM pair_constraint_proof \g /dev/null

SELECT count(*)
FROM pair_constraint_jobs job,
LATERAL otlet.correct_action(
  job.action_id,
  '{
    "expected_answer":"different_entity",
    "expected_confidence":"high"
  }'::jsonb,
  'controlled pair correction'
) correction
WHERE job.fixture = 'correction' \g /dev/null

SELECT pg_temp.complete_pair_constraint_job(
  'first_rejection',
  same_subject,
  'different_entity'
)
FROM pair_constraint_proof \g /dev/null

SELECT count(*)
FROM pair_constraint_jobs job,
LATERAL otlet.reject_action(
  job.action_id,
  'controlled rejection',
  'first distinct rejection'
) rejected
WHERE job.fixture = 'first_rejection' \g /dev/null

SELECT count(*)
FROM pair_constraint_jobs job,
LATERAL otlet.reject_action(
  job.action_id,
  'controlled rejection',
  'duplicate same-action rejection'
) rejected
WHERE job.fixture = 'first_rejection' \g /dev/null

UPDATE pair_constraint_proof proof
SET duplicate_rejection_blocked = (
  SELECT count(*) = 2
    AND count(DISTINCT event.action_id) = 1
    AND count(DISTINCT event.job_id) = 1
    AND count(DISTINCT event.receipt_id) = 1
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.pair_constraint_facts fact
      WHERE fact.task_name = proof.task_name
        AND fact.subject_id = proof.same_subject
    )
  FROM pair_constraint_jobs job
  JOIN otlet.review_events event ON event.action_id = job.action_id
  WHERE job.fixture = 'first_rejection'
    AND event.outcome = 'reject'
);

SELECT pg_temp.complete_pair_constraint_job(
  'second_rejection',
  same_subject,
  'different_entity'
)
FROM pair_constraint_proof \g /dev/null

SELECT count(*)
FROM pair_constraint_jobs job,
LATERAL otlet.reject_action(
  job.action_id,
  'controlled rejection',
  'second distinct rejection'
) rejected
WHERE job.fixture = 'second_rejection' \g /dev/null

UPDATE pair_constraint_proof proof
SET initial_facts_active = (
  SELECT count(*) = 2 AND bool_and(status.fact_state = 'active')
  FROM otlet.pair_constraint_status status
  WHERE status.task_name = proof.task_name
    AND status.subject_id IN (proof.same_subject, proof.different_subject)
);

SELECT pg_temp.complete_pair_constraint_job(
  'graph_export_control',
  same_subject,
  'same_entity'
)
FROM pair_constraint_proof \g /dev/null

SELECT count(*)
FROM pair_constraint_jobs job,
LATERAL otlet.approve_action(
  job.action_id,
  'entity graph open control'
) approved
WHERE job.fixture = 'graph_export_control' \g /dev/null

SELECT count(*)
FROM pair_constraint_jobs job,
LATERAL otlet.label_action(job.action_id) label
WHERE job.fixture = 'graph_export_control' \g /dev/null

UPDATE pair_constraint_proof
SET approval_export_control = (
  SELECT action.status = 'approved'
    AND action.approval_status = 'approved'
    AND EXISTS (
      SELECT 1
      FROM otlet.export_eval_cases(100000) exported
      JOIN otlet.eval_labels label ON label.action_id = exported.action_id
      WHERE exported.action_id = action.id
        AND label.label_source = 'approved_action'
    )
  FROM pair_constraint_jobs job
  JOIN otlet.actions action ON action.id = job.action_id
  WHERE job.fixture = 'graph_export_control'
);

INSERT INTO public.otlet_demo_vendor_pair (pair_id, left_id, right_id)
VALUES ('vendor-42:vendor-313', 'vendor-42', 'vendor-313');

SELECT pg_temp.complete_pair_constraint_job(
  'graph_bridge',
  'vendor-42:vendor-313',
  'different_entity'
) \g /dev/null

SELECT count(*)
FROM pair_constraint_jobs job,
LATERAL otlet.correct_action(
  job.action_id,
  '{
    "expected_answer":"same_entity",
    "expected_confidence":"high"
  }'::jsonb,
  'controlled graph bridge correction'
) correction
WHERE job.fixture = 'graph_bridge' \g /dev/null

UPDATE pair_constraint_proof proof
SET conflict_detected = (
  SELECT count(*) = 1
    AND bool_and(conflict.conflict_status = 'conflict')
    AND bool_and(conflict.conflict_hash ~
      '^otlet:v1:sha256:[0-9a-f]{64}$')
    AND bool_and(conflict.subject_id = proof.different_subject)
    AND bool_and(conflict.left_id = 'vendor-1001')
    AND bool_and(conflict.right_id = 'vendor-313')
    AND bool_and(conflict.active_fact_count = 3)
    AND bool_and(conflict.active_must_link_count = 2)
    AND bool_and(conflict.active_cannot_link_count = 1)
    AND bool_and(conflict.active_vertex_count = 3)
    AND bool_and(EXISTS (
      SELECT 1
      FROM otlet.pair_constraint_facts fact
      WHERE fact.fact_hash = conflict.cannot_fact_hash
        AND fact.relation = 'cannot_link'
        AND fact.review_event_id = conflict.review_event_id
        AND fact.reviewer_identity = conflict.reviewer_identity
        AND fact.reviewer_role = conflict.reviewer_role
    ))
  FROM otlet.entity_graph_conflict_status conflict
  WHERE conflict.task_name = proof.task_name
);

UPDATE pair_constraint_proof proof
SET review_routed = (
  SELECT count(*) = 1
    AND bool_and(queue.next_operator_step = 'review_graph_conflict')
    AND bool_and(queue.job_subject_id = proof.different_subject)
    AND bool_and(queue.action_id IS NULL)
    AND bool_and(queue.output ->> 'conflict_hash' =
      conflict.conflict_hash)
    AND bool_and(queue.output ->> 'cannot_fact_hash' =
      conflict.cannot_fact_hash)
    AND bool_and((queue.output ->> 'review_event_id')::bigint =
      conflict.review_event_id)
    AND bool_and(queue.output ->> 'reviewer_identity' =
      conflict.reviewer_identity)
    AND bool_and(queue.output ->> 'reviewer_role' =
      conflict.reviewer_role)
  FROM otlet.review_queue queue
  JOIN otlet.entity_graph_conflict_status conflict
    ON conflict.task_name = queue.task_name
   AND queue.review_reason = concat_ws(
     ': ',
     conflict.conflict_status,
     conflict.conflict_hash
   )
  WHERE queue.task_name = proof.task_name
    AND queue.queue_kind = 'entity_graph_conflict'
) AND (
  SELECT count(*) = 1
    AND bool_and(exported.next_operator_step = 'review_graph_conflict')
    AND bool_and(exported.action_id IS NULL)
    AND bool_and(exported.entity_graph_conflict_hash =
      conflict.conflict_hash)
    AND bool_and(exported.entity_graph_conflict_status =
      conflict.conflict_status)
    AND bool_and(exported.entity_graph_cannot_fact_hash =
      conflict.cannot_fact_hash)
    AND bool_and(exported.entity_graph_left_id = conflict.left_id)
    AND bool_and(exported.entity_graph_right_id = conflict.right_id)
    AND bool_and(exported.entity_graph_review_event_id =
      conflict.review_event_id)
    AND bool_and(exported.entity_graph_reviewer_identity =
      conflict.reviewer_identity)
    AND bool_and(exported.entity_graph_reviewer_role =
      conflict.reviewer_role)
  FROM otlet.audit_review_export exported
  JOIN otlet.entity_graph_conflict_status conflict
    ON conflict.task_name = exported.task_name
   AND conflict.conflict_hash = exported.entity_graph_conflict_hash
  WHERE exported.task_name = proof.task_name
    AND exported.queue_kind = 'entity_graph_conflict'
);

SELECT pg_temp.complete_pair_constraint_job(
  'graph_blocked_approval',
  same_subject,
  'same_entity'
)
FROM pair_constraint_proof \g /dev/null

CREATE FUNCTION pg_temp.entity_graph_approval_blocked(action_id bigint)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM 1
  FROM otlet.approve_action(
    entity_graph_approval_blocked.action_id,
    'must remain blocked'
  );
  RETURN false;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM LIKE
    'otlet entity graph blocker prevents recommendation approval for task %';
END;
$function$;

UPDATE pair_constraint_proof proof
SET approval_blocked = (
  SELECT pg_temp.entity_graph_approval_blocked(action.id)
    AND action.status = 'proposed'
    AND action.approval_status = 'required'
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.review_events event
      WHERE event.action_id = action.id
        AND event.outcome = 'approve'
    )
  FROM pair_constraint_jobs job
  JOIN otlet.actions action ON action.id = job.action_id
  WHERE job.fixture = 'graph_blocked_approval'
);

CREATE FUNCTION pg_temp.entity_graph_promotion_blocked(task_name text)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
  active_hash text;
  target_hash text;
  current_hash text;
  active_definition jsonb;
  target_definition jsonb;
  saved_candidate_plan jsonb;
  saved_candidate_plan_cost numeric;
  saved_candidate_preflight_at timestamptz;
BEGIN
  SELECT
    head.active_workload_revision_hash,
    revision.definition,
    revision.candidate_plan,
    revision.candidate_plan_cost,
    revision.candidate_preflight_at
  INTO
    active_hash,
    active_definition,
    saved_candidate_plan,
    saved_candidate_plan_cost,
    saved_candidate_preflight_at
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = entity_graph_promotion_blocked.task_name;

  target_definition := jsonb_set(
    active_definition,
    '{task,instruction}',
    to_jsonb(
      active_definition #>> '{task,instruction}'
      || ' Keep graph review pending.'
    ),
    true
  );
  target_hash := otlet.identity_hash(
    'workload_revision',
    target_definition
  );
  INSERT INTO otlet.workload_revisions (
    workload_revision_hash,
    task_name,
    definition,
    candidate_plan,
    candidate_plan_cost,
    candidate_preflight_at
  ) VALUES (
    target_hash,
    entity_graph_promotion_blocked.task_name,
    target_definition,
    saved_candidate_plan,
    saved_candidate_plan_cost,
    saved_candidate_preflight_at
  )
  ON CONFLICT (workload_revision_hash) DO NOTHING;

  BEGIN
    UPDATE otlet.workload_revision_heads head
    SET previous_workload_revision_hash = active_hash,
        active_workload_revision_hash = target_hash,
        promoted_at = clock_timestamp()
    WHERE head.task_name = entity_graph_promotion_blocked.task_name;
  EXCEPTION WHEN OTHERS THEN
    SELECT head.active_workload_revision_hash
    INTO current_hash
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = entity_graph_promotion_blocked.task_name;
    RETURN SQLERRM LIKE
      'otlet entity graph blocker prevents workload promotion for task %'
      AND current_hash = active_hash;
  END;
  RETURN false;
END;
$function$;

CREATE FUNCTION pg_temp.entity_graph_head_insert_blocked(task_name text)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
  saved_head otlet.workload_revision_heads%ROWTYPE;
BEGIN
  SELECT *
  INTO saved_head
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = entity_graph_head_insert_blocked.task_name;

  DELETE FROM otlet.workload_revision_heads head
  WHERE head.task_name = entity_graph_head_insert_blocked.task_name;
  INSERT INTO otlet.workload_revision_heads
  SELECT saved_head.*;
  RETURN false;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM LIKE
    'otlet entity graph blocker prevents workload promotion for task %'
    AND EXISTS (
      SELECT 1
      FROM otlet.workload_revision_heads head
      WHERE head.task_name = entity_graph_head_insert_blocked.task_name
        AND head.active_workload_revision_hash =
          saved_head.active_workload_revision_hash
    );
END;
$function$;

CREATE FUNCTION pg_temp.entity_graph_export_blocked()
RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM 1 FROM otlet.export_eval_cases(100000);
  RETURN false;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM LIKE
    'otlet entity graph blocker prevents evaluation export for task %';
END;
$function$;

UPDATE pair_constraint_proof proof
SET promotion_blocked = pg_temp.entity_graph_promotion_blocked(
      proof.task_name
    ),
    head_insert_blocked = pg_temp.entity_graph_head_insert_blocked(
      proof.task_name
    ),
    export_blocked = pg_temp.entity_graph_export_blocked();

SAVEPOINT entity_graph_analysis_limit;
CREATE TEMP TABLE entity_graph_limit_events
ON COMMIT DROP AS
WITH template AS (
  SELECT event.*
  FROM otlet.pair_constraint_facts fact
  JOIN otlet.review_events event ON event.id = fact.review_event_id
  JOIN pair_constraint_proof proof ON proof.task_name = fact.task_name
  WHERE fact.relation = 'cannot_link'
  ORDER BY fact.created_at
  LIMIT 1
), added AS (
  INSERT INTO otlet.review_events (
    outcome,
    reviewer_identity,
    reviewer_role,
    reason,
    job_id,
    task_name,
    subject_id,
    action_id,
    output_id,
    receipt_id,
    source_table,
    source_hash,
    content_hash,
    current_content_hash,
    source_freshness,
    model_name,
    model_artifact_hash,
    prompt_hash,
    output_schema_hash,
    output_hash,
    runtime_fingerprint_hash
  )
  SELECT
    'defer',
    template.reviewer_identity,
    template.reviewer_role,
    'entity graph analysis limit ' || series.n,
    template.job_id,
    template.task_name,
    template.subject_id,
    template.action_id,
    template.output_id,
    template.receipt_id,
    template.source_table,
    template.source_hash,
    template.content_hash,
    template.current_content_hash,
    template.source_freshness,
    template.model_name,
    template.model_artifact_hash,
    template.prompt_hash,
    template.output_schema_hash,
    template.output_hash,
    template.runtime_fingerprint_hash
  FROM template
  CROSS JOIN generate_series(1, 710) series(n)
  RETURNING id
)
SELECT
  added.id,
  row_number() OVER (ORDER BY added.id)::bigint AS n
FROM added;

INSERT INTO otlet.pair_constraint_facts (
  fact_hash,
  task_name,
  subject_id,
  left_id,
  right_id,
  relation,
  evidence_kind,
  workload_revision_hash,
  relevant_contract_hash,
  source_hash,
  content_hash,
  source_freshness,
  correction_label_id,
  prior_review_event_id,
  review_event_id,
  reviewer_identity,
  reviewer_role
)
SELECT
  otlet.identity_hash(
    'entity_graph_limit_fact',
    jsonb_build_object('task_name', template.task_name, 'n', event.n)
  ),
  template.task_name,
  template.subject_id,
  format('limit-%s-left', lpad(event.n::text, 4, '0')),
  format('limit-%s-right', lpad(event.n::text, 4, '0')),
  'cannot_link',
  'repeated_rejection',
  template.workload_revision_hash,
  template.relevant_contract_hash,
  template.source_hash,
  template.content_hash,
  'fresh',
  NULL,
  template.review_event_id,
  event.id,
  template.reviewer_identity,
  template.reviewer_role
FROM entity_graph_limit_events event
CROSS JOIN LATERAL (
  SELECT fact.*
  FROM otlet.pair_constraint_facts fact
  JOIN pair_constraint_proof proof ON proof.task_name = fact.task_name
  WHERE fact.relation = 'cannot_link'
  ORDER BY fact.created_at
  LIMIT 1
) template;

CREATE FUNCTION pg_temp.entity_graph_limit_gate_blocked(task_name text)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM otlet.require_entity_graph_clear(
    entity_graph_limit_gate_blocked.task_name,
    'analysis limit proof'
  );
  RETURN false;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM LIKE
    'otlet entity graph blocker prevents analysis limit proof for task %';
END;
$function$;

SELECT count(*) = 1
  AND bool_and(status.conflict_status = 'analysis_limit_exceeded')
  AND bool_and(status.cannot_fact_hash IS NULL)
  AND bool_and(status.estimated_state_count > 1000000)
  AND pg_temp.entity_graph_limit_gate_blocked(:'task_name')
  AS analysis_limit_blocked
FROM otlet.entity_graph_conflict_status_for_task(:'task_name') status
\gset
ROLLBACK TO SAVEPOINT entity_graph_analysis_limit;

UPDATE pair_constraint_proof
SET analysis_limit_blocked = :'analysis_limit_blocked'::boolean;

CREATE FUNCTION pg_temp.active_pair_constraint_update_blocked()
RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    UPDATE otlet.semantic_materializations materialization
    SET stale = false,
        stale_reason = NULL
    FROM otlet.records record
    JOIN otlet.actions action ON action.id = record.action_id
    JOIN pair_constraint_jobs job ON job.job_id = action.job_id
    WHERE materialization.record_id = record.id
      AND job.fixture = 'first_rejection';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM =
      'otlet active pair constraint conflicts with semantic result';
  END;
  RETURN false;
END;
$function$;

UPDATE pair_constraint_proof
SET conflicting_materializations_stale = (
  SELECT count(*) = 3
    AND count(DISTINCT job.fixture) = 3
    AND bool_and(job.semantic_materialized IS TRUE)
    AND bool_and(materialization.stale)
    AND bool_and(materialization.stale_reason = 'pair_constraint_conflict')
  FROM otlet.semantic_materializations materialization
  JOIN otlet.records record ON record.id = materialization.record_id
  JOIN otlet.actions action ON action.id = record.action_id
  JOIN pair_constraint_jobs job ON job.job_id = action.job_id
  WHERE job.fixture IN ('correction', 'first_rejection', 'second_rejection')
    AND materialization.body ->> 'match' IN (
      'same_entity',
      'different_entity'
    )
) AND pg_temp.active_pair_constraint_update_blocked();

SELECT pg_temp.complete_pair_constraint_job(
  'blocked_override',
  same_subject,
  'different_entity'
)
FROM pair_constraint_proof \g /dev/null

CREATE FUNCTION pg_temp.pair_constraint_fact_change_blocked(operation text)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    IF operation = 'update' THEN
      UPDATE otlet.pair_constraint_facts
      SET relation = relation
      WHERE fact_hash = (SELECT min(fact_hash) FROM otlet.pair_constraint_facts);
    ELSIF operation = 'delete' THEN
      DELETE FROM otlet.pair_constraint_facts
      WHERE fact_hash = (SELECT min(fact_hash) FROM otlet.pair_constraint_facts);
    ELSE
      TRUNCATE otlet.pair_constraint_facts;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM = 'otlet pair constraint facts are immutable';
  END;
  RETURN false;
END;
$function$;

SAVEPOINT pair_constraint_source_reopen;
UPDATE public.otlet_demo_vendor_entity
SET notes = notes || ' pair constraint source change'
WHERE id = 'vendor-42';

SELECT EXISTS (
  SELECT 1
  FROM otlet.pair_constraint_status status
  JOIN pair_constraint_proof proof ON proof.task_name = status.task_name
  WHERE status.subject_id = proof.same_subject
    AND status.fact_state = 'reopened_source'
) AS source_reopened,
NOT EXISTS (
  SELECT 1
  FROM otlet.entity_graph_conflict_status conflict
  WHERE conflict.task_name = :'task_name'
) AND NOT EXISTS (
  SELECT 1
  FROM otlet.review_queue queue
  WHERE queue.task_name = :'task_name'
    AND queue.queue_kind = 'entity_graph_conflict'
) AND EXISTS (
  SELECT 1
  FROM pair_constraint_jobs job
  JOIN otlet.export_eval_cases(100000) exported
    ON exported.action_id = job.action_id
  WHERE job.fixture = 'graph_export_control'
) AS conflict_cleared
\gset

WITH reactivated AS (
  UPDATE otlet.semantic_materializations materialization
  SET stale = false,
      stale_reason = NULL
  FROM otlet.records record
  JOIN otlet.actions action ON action.id = record.action_id
  JOIN pair_constraint_jobs job ON job.job_id = action.job_id
  WHERE materialization.record_id = record.id
    AND job.fixture IN ('first_rejection', 'second_rejection')
  RETURNING materialization.id
)
SELECT count(*) = 2 AS reopened_materialization_allowed
FROM reactivated \gset
ROLLBACK TO SAVEPOINT pair_constraint_source_reopen;

UPDATE pair_constraint_proof
SET source_reopened = :'source_reopened'::boolean
      AND :'reopened_materialization_allowed'::boolean,
    conflict_cleared = :'conflict_cleared'::boolean;

SAVEPOINT pair_constraint_contract_reopen;
CREATE TEMP TABLE pair_constraint_contract_target
ON COMMIT DROP AS
SELECT
  revision.task_name,
  head.active_workload_revision_hash AS active_hash,
  jsonb_set(
    revision.definition,
    '{task,input_shaping,strip_keys}',
    '[]'::jsonb,
    true
  ) AS definition,
  revision.candidate_plan,
  revision.candidate_plan_cost,
  revision.candidate_preflight_at
FROM otlet.workload_revision_heads head
JOIN otlet.workload_revisions revision
  ON revision.task_name = head.task_name
 AND revision.workload_revision_hash = head.active_workload_revision_hash
WHERE head.task_name = :'task_name';

ALTER TABLE pair_constraint_contract_target
ADD COLUMN target_hash text;
UPDATE pair_constraint_contract_target
SET target_hash = otlet.identity_hash('workload_revision', definition);

INSERT INTO otlet.workload_revisions (
  workload_revision_hash,
  task_name,
  definition,
  candidate_plan,
  candidate_plan_cost,
  candidate_preflight_at
)
SELECT
  target_hash,
  task_name,
  definition,
  candidate_plan,
  candidate_plan_cost,
  candidate_preflight_at
FROM pair_constraint_contract_target;

UPDATE otlet.workload_revision_heads head
SET previous_workload_revision_hash = target.active_hash,
    active_workload_revision_hash = target.target_hash,
    promoted_at = clock_timestamp()
FROM pair_constraint_contract_target target
WHERE head.task_name = target.task_name;

SELECT (
  SELECT count(*) = 3
    AND bool_and(status.fact_state = 'reopened_contract')
  FROM otlet.pair_constraint_status status
  WHERE status.task_name = :'task_name'
) AND NOT EXISTS (
  SELECT 1
  FROM otlet.entity_graph_conflict_status conflict
  WHERE conflict.task_name = :'task_name'
) AND NOT EXISTS (
  SELECT 1
  FROM otlet.review_queue queue
  WHERE queue.task_name = :'task_name'
    AND queue.queue_kind = 'entity_graph_conflict'
) AND EXISTS (
  SELECT 1
  FROM pair_constraint_jobs job
  JOIN otlet.export_eval_cases(100000) exported
    ON exported.action_id = job.action_id
  WHERE job.fixture = 'graph_export_control'
) AS contract_reopened
\gset
ROLLBACK TO SAVEPOINT pair_constraint_contract_reopen;

UPDATE pair_constraint_proof
SET contract_reopened = :'contract_reopened'::boolean
  AND EXISTS (
    SELECT 1
    FROM otlet.entity_graph_conflict_status conflict
    WHERE conflict.task_name = :'task_name'
      AND conflict.conflict_status = 'conflict'
  );

UPDATE pair_constraint_proof
SET facts_immutable =
      pg_temp.pair_constraint_fact_change_blocked('update')
      AND pg_temp.pair_constraint_fact_change_blocked('delete')
      AND pg_temp.pair_constraint_fact_change_blocked('truncate'),
    invariants_clean = NOT EXISTS (SELECT 1 FROM otlet.verify_invariants());

SELECT invariant_name, detail
FROM otlet.verify_invariants()
ORDER BY invariant_name, detail \g /dev/stderr

SELECT concat_ws('|',
  (
    SELECT count(*) = 3
      AND count(*) FILTER (
        WHERE relation = 'cannot_link'
          AND evidence_kind = 'correction'
          AND correction_label_id IS NOT NULL
          AND prior_review_event_id IS NULL
          AND EXISTS (
            SELECT 1
            FROM otlet.eval_labels label
            JOIN otlet.review_events event
              ON event.id = fact.review_event_id
             AND event.action_id = label.action_id
            WHERE label.id = fact.correction_label_id
              AND label.label_source = 'manual_correction'
              AND label.task_name = fact.task_name
              AND label.subject_id = fact.subject_id
              AND label.workload_revision_hash = fact.workload_revision_hash
              AND label.source_hash = fact.source_hash
              AND label.content_hash = fact.content_hash
              AND label.expected_answer = 'different_entity'
              AND label.authenticated_role_name = fact.reviewer_identity
              AND label.active_role_name = fact.reviewer_role
              AND event.outcome = 'correct'
              AND event.task_name = fact.task_name
              AND event.subject_id = fact.subject_id
              AND event.source_hash = fact.source_hash
              AND event.content_hash = fact.content_hash
              AND event.reviewer_identity = fact.reviewer_identity
              AND event.reviewer_role = fact.reviewer_role
          )
      ) = 1
      AND count(*) FILTER (
        WHERE relation = 'must_link'
          AND evidence_kind = 'correction'
          AND correction_label_id IS NOT NULL
          AND prior_review_event_id IS NULL
      ) = 1
      AND count(*) FILTER (
        WHERE relation = 'must_link'
          AND evidence_kind = 'repeated_rejection'
          AND correction_label_id IS NULL
          AND prior_review_event_id IS NOT NULL
      ) = 1
      AND bool_and(left_id COLLATE "C" < right_id COLLATE "C")
      AND bool_and(reviewer_identity = session_user::text)
      AND bool_and(reviewer_role = session_user::text)
    FROM otlet.pair_constraint_facts fact
    WHERE fact.task_name = proof.task_name
  ),
  proof.duplicate_rejection_blocked,
  (
    SELECT count(*) = 1
      AND bool_and(current_event.outcome = 'reject')
      AND bool_and(prior_event.outcome = 'reject')
      AND bool_and(current_event.action_id <> prior_event.action_id)
      AND bool_and(current_event.job_id <> prior_event.job_id)
      AND bool_and(current_event.receipt_id <> prior_event.receipt_id)
      AND bool_and(current_event.task_name = fact.task_name)
      AND bool_and(prior_event.task_name = fact.task_name)
      AND bool_and(current_event.subject_id = fact.subject_id)
      AND bool_and(prior_event.subject_id = fact.subject_id)
      AND bool_and(current_event.source_hash = fact.source_hash)
      AND bool_and(prior_event.source_hash = fact.source_hash)
      AND bool_and(current_event.content_hash = fact.content_hash)
      AND bool_and(prior_event.content_hash = fact.content_hash)
      AND bool_and(current_event.reviewer_identity = fact.reviewer_identity)
      AND bool_and(current_event.reviewer_role = fact.reviewer_role)
      AND bool_and(current_job.workload_revision_hash = fact.workload_revision_hash)
      AND bool_and(prior_job.workload_revision_hash = fact.workload_revision_hash)
      AND bool_and(CASE current_action.action_type
        WHEN 'merge_candidate' THEN 'cannot_link'
        WHEN 'new_entity' THEN 'must_link'
      END = fact.relation)
      AND bool_and(CASE prior_action.action_type
        WHEN 'merge_candidate' THEN 'cannot_link'
        WHEN 'new_entity' THEN 'must_link'
      END = fact.relation)
    FROM otlet.pair_constraint_facts fact
    JOIN otlet.review_events current_event
      ON current_event.id = fact.review_event_id
    JOIN otlet.review_events prior_event
      ON prior_event.id = fact.prior_review_event_id
    JOIN otlet.actions current_action
      ON current_action.id = current_event.action_id
    JOIN otlet.actions prior_action
      ON prior_action.id = prior_event.action_id
    JOIN otlet.jobs current_job ON current_job.id = current_event.job_id
    JOIN otlet.jobs prior_job ON prior_job.id = prior_event.job_id
    WHERE fact.task_name = proof.task_name
      AND fact.evidence_kind = 'repeated_rejection'
  ),
  proof.initial_facts_active,
  proof.approval_export_control,
  proof.conflict_detected,
  proof.review_routed,
  proof.approval_blocked,
  proof.promotion_blocked,
  proof.head_insert_blocked,
  proof.export_blocked,
  proof.analysis_limit_blocked,
  proof.conflicting_materializations_stale,
  (
    SELECT output_id IS NOT NULL
      AND semantic_materialized IS NULL
      AND materialization_error =
        'otlet active pair constraint conflicts with semantic result'
      AND EXISTS (
        SELECT 1
        FROM otlet.outputs output
        JOIN otlet.inference_receipts receipt
          ON receipt.id = output.receipt_id
        WHERE output.id = blocked.output_id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.semantic_materializations materialization
        JOIN otlet.records record ON record.id = materialization.record_id
        JOIN otlet.actions action ON action.id = record.action_id
        WHERE action.job_id = blocked.job_id
      )
    FROM pair_constraint_jobs blocked
    WHERE blocked.fixture = 'blocked_override'
  ),
  proof.source_reopened,
  proof.conflict_cleared,
  proof.contract_reopened,
  proof.facts_immutable,
  NOT pg_catalog.has_table_privilege(
    'public',
    'otlet.pair_constraint_facts',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.pair_constraint_status',
      'SELECT'
    ),
  NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.entity_graph_conflict_status',
      'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.review_queue_without_entity_graph_conflicts',
      'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname LIKE '%entity_graph%'
        AND pg_catalog.has_function_privilege(
          'public', function.oid, 'EXECUTE'
        )
    ),
  proof.invariants_clean
)
FROM pair_constraint_proof proof;

ROLLBACK;
SQL
)"
echo "pair_constraint_ledger_contract=$pair_constraint_contract"
[ "$pair_constraint_contract" = "t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Pair constraint ledger contract mismatch: $pair_constraint_contract" >&2
  exit 1
}
