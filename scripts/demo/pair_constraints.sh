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
  conflicting_materializations_stale boolean NOT NULL DEFAULT false,
  source_reopened boolean NOT NULL DEFAULT false,
  contract_reopened boolean NOT NULL DEFAULT false,
  facts_immutable boolean NOT NULL DEFAULT false,
  invariants_clean boolean NOT NULL DEFAULT false
) ON COMMIT DROP;

INSERT INTO pair_constraint_proof
VALUES (
  :'task_name',
  :'model_name',
  'vendor-1001:vendor-42',
  'vendor-1001:vendor-313',
  false,
  false,
  false,
  false,
  false,
  false,
  false
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

UPDATE public.otlet_demo_vendor_entity
SET notes = notes || ' pair constraint source change'
WHERE id = 'vendor-42';

UPDATE pair_constraint_proof proof
SET source_reopened = EXISTS (
  SELECT 1
  FROM otlet.pair_constraint_status status
  WHERE status.task_name = proof.task_name
    AND status.subject_id = proof.same_subject
    AND status.fact_state = 'reopened_source'
);

SAVEPOINT pair_constraint_source_reopen;
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
SET source_reopened = source_reopened
  AND :'reopened_materialization_allowed'::boolean;

SAVEPOINT pair_constraint_contract_reopen;
UPDATE otlet.tasks task
SET input_shaping = jsonb_set(
  task.input_shaping,
  '{strip_keys}',
  '[]'::jsonb,
  true
)
WHERE task.name = :'task_name';
SELECT otlet.promote_configured_workload_revision(:'task_name') \g /dev/null

SELECT EXISTS (
  SELECT 1
  FROM otlet.pair_constraint_status status
  JOIN pair_constraint_proof proof ON proof.task_name = status.task_name
  WHERE status.subject_id = proof.different_subject
    AND status.fact_state = 'reopened_contract'
) AS contract_reopened \gset
ROLLBACK TO SAVEPOINT pair_constraint_contract_reopen;

UPDATE pair_constraint_proof
SET contract_reopened = :'contract_reopened'::boolean;

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
    SELECT count(*) = 2
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
  proof.invariants_clean
)
FROM pair_constraint_proof proof;

ROLLBACK;
SQL
)"
echo "pair_constraint_ledger_contract=$pair_constraint_contract"
[ "$pair_constraint_contract" = "t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Pair constraint ledger contract mismatch: $pair_constraint_contract" >&2
  exit 1
}
