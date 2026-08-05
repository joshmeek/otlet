log "Proving reviewer rubric and calibration"

reviewer_role="otlet_demo_reviewer_role_$$"
reviewer_login="otlet_demo_reviewer_login_$$"
other_reviewer_login="otlet_demo_other_reviewer_login_$$"
gold_reader_role="otlet_demo_gold_reader_role_$$"

psql_exec -qAt \
  -v reviewer_role="$reviewer_role" \
  -v reviewer_login="$reviewer_login" \
  -v other_reviewer_login="$other_reviewer_login" \
  -v gold_reader_role="$gold_reader_role" <<'SQL'
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

CREATE TEMP TABLE reviewer_calibration_proof (
  task_name text PRIMARY KEY,
  reviewer_oid oid,
  other_reviewer_oid oid,
  original_revision_hash text,
  same_rubric_revision_hash text,
  changed_rubric_revision_hash text,
  failed_calibration_hash text,
  passing_calibration_hash text,
  refresh_calibration_hash text,
  changed_calibration_hash text,
  passing_member_two text,
  pre_action_id bigint,
  approved_action_id bigint,
  error_action_id bigint,
  blocked_action_id bigint,
  same_rubric_action_id bigint,
  changed_action_id bigint,
  final_action_id bigint,
  semantic_label_id bigint,
  semantic_review_event_id bigint,
  semantic_denied_label_id bigint,
  semantic_denied_review_event_id bigint,
  semantic_correction_hash text,
  semantic_expires_at timestamptz,
  invalid_correction_snapshot jsonb,
  sample_receipt_id bigint,
  sample_label_id bigint,
  denied_before_calibration boolean NOT NULL DEFAULT false,
  conflicting_response_rejected boolean NOT NULL DEFAULT false,
  reused_gold_rejected boolean NOT NULL DEFAULT false,
  denied_after_error boolean NOT NULL DEFAULT false,
  denied_after_rubric_change boolean NOT NULL DEFAULT false,
  conflicting_review_error_rejected boolean NOT NULL DEFAULT false,
  invalid_rubric_rejected boolean NOT NULL DEFAULT false,
  forged_review_provenance_rejected boolean NOT NULL DEFAULT false
) ON COMMIT DROP;
INSERT INTO reviewer_calibration_proof(task_name)
VALUES ('reviewer_calibration_probe_task');

CREATE TEMP TABLE reviewer_calibration_cases (
  ordinal integer PRIMARY KEY,
  label_id bigint NOT NULL UNIQUE,
  case_hash text NOT NULL UNIQUE
) ON COMMIT DROP;

SELECT otlet.register_model(
  'reviewer_calibration_model',
  '/tmp/reviewer-calibration-model.gguf',
  repeat('9', 64),
  jsonb_build_object(
    'sha256', repeat('9', 64),
    'bytes', 1,
    'source', 'repository-demo',
    'revision', 'reviewer-calibration-v1',
    'quantization', 'fixture',
    'license', 'fixture'
  ),
  4
) \g /dev/null

CREATE TABLE public.otlet_demo_reviewer_calibration (
  id text PRIMARY KEY,
  review_state text NOT NULL,
  protected_note text NOT NULL
);
INSERT INTO public.otlet_demo_reviewer_calibration
SELECT 'gold-' || ordinal, 'pending', 'DO_NOT_TOUCH'
FROM generate_series(1, 8) ordinal
UNION ALL
SELECT subject_id, 'pending', 'DO_NOT_TOUCH'
FROM unnest(ARRAY[
  'review-pre',
  'review-pass',
  'review-error',
  'review-blocked',
  'review-same-rubric',
  'review-changed',
  'review-final',
  'review-sample'
]) subject_id;

SELECT otlet.create_watch(
  watch_name => 'reviewer_calibration_probe',
  kind => 'row',
  instruction => 'Return approve or reject with high confidence and one update_row recommendation',
  output_schema => '{
    "type":"object",
    "required":["decision","confidence"],
    "additionalProperties":false,
    "properties":{
      "decision":{"enum":["approve","reject"]},
      "confidence":{"enum":["high"]}
    }
  }'::jsonb,
  model_name => 'reviewer_calibration_model',
  table_name => 'public.otlet_demo_reviewer_calibration'::regclass,
  subject_column => 'id',
  runtime_options => '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  action_types => ARRAY['update_row'],
  decision_contract => '{
    "answer_field":"decision",
    "abstain_values":[],
    "confidence_field":"confidence",
    "accepted_confidence":["high"],
    "review_rubric":{
      "format":"otlet.review_rubric.v1",
      "instructions":"Approve only when the proposed row update matches the shaped evidence",
      "minimum_gold_cases":2,
      "maximum_calibration_errors":0,
      "maximum_review_errors":0
    }
  }'::jsonb
) \g /dev/null
SELECT otlet.register_action_target(
  'reviewer_calibration_target',
  'public.otlet_demo_reviewer_calibration'::regclass,
  'id',
  ARRAY['review_state']::name[]
) \g /dev/null
SELECT otlet.register_action_workflow_policy(
  'reviewer_calibration_probe_task',
  'update_row',
  'reviewer_calibration_target',
  'bounded_mutation',
  'evaluated'
) \g /dev/null

UPDATE reviewer_calibration_proof
SET original_revision_hash = (
  SELECT head.active_workload_revision_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = reviewer_calibration_proof.task_name
);

CREATE FUNCTION pg_temp.make_reviewer_action(
  subject_id text,
  workload_revision_hash text
) RETURNS bigint
LANGUAGE plpgsql
AS $function$
DECLARE
  job_input jsonb;
  job_output jsonb := '{"decision":"approve","confidence":"high"}'::jsonb;
  job_actions jsonb;
  saved_job_id bigint;
  saved_action_id bigint;
  claim_token text;
BEGIN
  SELECT jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_reviewer_calibration',
      'subject_id', source.id,
      'ctid', source.ctid::text,
      'xmin', source.xmin::text
    ),
    'table', 'public.otlet_demo_reviewer_calibration',
    'row', to_jsonb(source)
  )
  INTO job_input
  FROM public.otlet_demo_reviewer_calibration source
  WHERE source.id = make_reviewer_action.subject_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reviewer calibration fixture subject is missing';
  END IF;
  job_actions := jsonb_build_array(jsonb_build_object(
    'type', 'update_row',
    'body', jsonb_build_object(
      'target', 'reviewer_calibration_target',
      'identity', make_reviewer_action.subject_id,
      'changes', jsonb_build_object('review_state', 'reviewed')
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
    'reviewer_calibration_probe_task',
    make_reviewer_action.workload_revision_hash,
    make_reviewer_action.subject_id,
    job_input,
    'running',
    1,
    now(),
    now() + interval '5 minutes',
    gen_random_uuid()::text
  ) RETURNING id, otlet.jobs.claim_token INTO saved_job_id, claim_token;
  PERFORM otlet.complete_job(
    job_id => saved_job_id,
    output => job_output,
    raw_output => jsonb_build_object(
      'output', job_output,
      'actions', job_actions
    )::text,
    actions => job_actions,
    started_at => now(),
    trace_summary => jsonb_build_object(
      'schema_validation_status', 'passed',
      'generate_ms', 10,
      'mvcc', jsonb_build_object(
        'table', 'public.otlet_demo_reviewer_calibration'
      )
    ),
    model_name => 'reviewer_calibration_model',
    expected_claim_token => claim_token
  );
  SELECT action.id
  INTO saved_action_id
  FROM otlet.actions action
  WHERE action.job_id = saved_job_id;
  RETURN saved_action_id;
END
$function$;

CREATE FUNCTION pg_temp.make_reviewer_gold(
  case_ordinal integer,
  workload_revision_hash text
) RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
  action_id bigint;
  label_id bigint;
  case_hash text;
BEGIN
  action_id := pg_temp.make_reviewer_action(
    'gold-' || make_reviewer_gold.case_ordinal,
    make_reviewer_gold.workload_revision_hash
  );
  SELECT label.id
  INTO label_id
  FROM otlet.label_action(
    action_id,
    expected_answer => 'approve',
    expected_confidence => 'high',
    expected_action_type => 'update_row',
    reason => 'Approved reviewer calibration gold fixture',
    label_source => 'manual_correction'
  ) label;
  PERFORM otlet.adjudicate_eval_label(
    label_id,
    'accepted',
    1.0,
    'Accepted reviewer calibration gold label'
  );
  case_hash := otlet.register_evaluation_case(
    label_id,
    'calibration',
    'Approved blinded reviewer calibration snapshot'
  );
  INSERT INTO reviewer_calibration_cases
  VALUES (make_reviewer_gold.case_ordinal, label_id, case_hash);
  RETURN case_hash;
END
$function$;

SELECT pg_temp.make_reviewer_gold(
  ordinal,
  (SELECT original_revision_hash FROM reviewer_calibration_proof)
)
FROM generate_series(1, 6) ordinal \g /dev/null

UPDATE reviewer_calibration_proof
SET pre_action_id = pg_temp.make_reviewer_action(
  'review-pre', original_revision_hash
),
approved_action_id = pg_temp.make_reviewer_action(
  'review-pass', original_revision_hash
),
error_action_id = pg_temp.make_reviewer_action(
  'review-error', original_revision_hash
),
blocked_action_id = pg_temp.make_reviewer_action(
  'review-blocked', original_revision_hash
);
SELECT * FROM otlet.dry_run_action(
  (SELECT pre_action_id FROM reviewer_calibration_proof)
) \g /dev/null
SELECT * FROM otlet.dry_run_action(
  (SELECT blocked_action_id FROM reviewer_calibration_proof)
) \g /dev/null

SELECT format('CREATE ROLE %I NOLOGIN', :'reviewer_role') \gexec
SELECT format('CREATE ROLE %I LOGIN INHERIT', :'reviewer_login') \gexec
SELECT format('CREATE ROLE %I LOGIN INHERIT', :'other_reviewer_login') \gexec
SELECT format('CREATE ROLE %I NOLOGIN', :'gold_reader_role') \gexec
SELECT format('GRANT %I TO %I', :'reviewer_role', :'reviewer_login') \gexec
SELECT format('GRANT %I TO %I', :'reviewer_role', :'other_reviewer_login') \gexec
SELECT format(
  'GRANT SELECT, UPDATE ON reviewer_calibration_proof TO %I',
  :'reviewer_login'
) \gexec
SELECT format(
  'GRANT SELECT ON reviewer_calibration_proof TO %I',
  :'other_reviewer_login'
) \gexec
SELECT otlet.grant_reviewer_access(:'reviewer_role'::regrole) \g /dev/null
UPDATE reviewer_calibration_proof
SET reviewer_oid = :'reviewer_login'::regrole::oid,
    other_reviewer_oid = :'other_reviewer_login'::regrole::oid;

SELECT format('GRANT USAGE ON SCHEMA otlet TO %I', :'gold_reader_role') \gexec
SELECT format(
  'GRANT SELECT ON otlet.evaluation_cases TO %I',
  :'gold_reader_role'
) \gexec
SELECT format(
  'GRANT %I TO %I WITH INHERIT FALSE, SET TRUE',
  :'gold_reader_role',
  :'other_reviewer_login'
) \gexec
SELECT pg_temp.assert_true(
  NOT pg_catalog.has_table_privilege(
    :'other_reviewer_login',
    'otlet.evaluation_cases',
    'SELECT'
  )
  AND pg_catalog.pg_has_role(
    :'other_reviewer_login'::regrole::oid,
    :'gold_reader_role'::regrole::oid,
    'SET'
  )
  AND pg_catalog.has_function_privilege(
    :'other_reviewer_login',
    'otlet.submit_reviewer_calibration(text,text,text,text,text)',
    'EXECUTE'
  )
  AND otlet.reviewer_gold_visibility_error(
    :'other_reviewer_login'::regrole::oid
  ) = 'reviewer identity can read gold evidence',
  'SET-reachable gold table access escaped reviewer closure'
);
DO $body$
BEGIN
  BEGIN
    PERFORM otlet.register_reviewer_calibration(
      (SELECT task_name FROM reviewer_calibration_proof),
      (SELECT other_reviewer_oid::regrole FROM reviewer_calibration_proof),
      'gold-visible-table',
      ARRAY[
        (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 1),
        (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 2)
      ],
      'SET-reachable table rejection probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet reviewer identity can read gold evidence' THEN
      RAISE;
    END IF;
  END;
END
$body$;
SELECT format(
  'REVOKE SELECT ON otlet.evaluation_cases FROM %I',
  :'gold_reader_role'
) \gexec
SELECT format(
  'GRANT SELECT (qualification_eligible) ON '
    'otlet.eval_label_quality_status TO %I',
  :'gold_reader_role'
) \gexec
SELECT pg_temp.assert_true(
  NOT pg_catalog.has_table_privilege(
    :'other_reviewer_login',
    'otlet.eval_label_quality_status',
    'SELECT'
  )
  AND pg_catalog.has_any_column_privilege(
    :'gold_reader_role',
    'otlet.eval_label_quality_status',
    'SELECT'
  )
  AND otlet.reviewer_gold_visibility_error(
    :'other_reviewer_login'::regrole::oid
  ) = 'reviewer identity can read gold evidence',
  'SET-reachable gold column access escaped reviewer closure'
);
DO $body$
BEGIN
  BEGIN
    PERFORM otlet.register_reviewer_calibration(
      (SELECT task_name FROM reviewer_calibration_proof),
      (SELECT other_reviewer_oid::regrole FROM reviewer_calibration_proof),
      'gold-visible-column',
      ARRAY[
        (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 1),
        (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 2)
      ],
      'SET-reachable column rejection probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet reviewer identity can read gold evidence' THEN
      RAISE;
    END IF;
  END;
END
$body$;
SELECT format(
  'REVOKE SELECT (qualification_eligible) ON '
    'otlet.eval_label_quality_status FROM %I',
  :'gold_reader_role'
) \gexec
SELECT format(
  'GRANT EXECUTE ON FUNCTION otlet.correct_action(bigint,jsonb,text) TO %I',
  :'gold_reader_role'
) \gexec
SELECT pg_temp.assert_true(
  NOT pg_catalog.has_function_privilege(
    :'other_reviewer_login',
    'otlet.correct_action(bigint,jsonb,text)',
    'EXECUTE'
  )
  AND pg_catalog.has_function_privilege(
    :'gold_reader_role',
    'otlet.correct_action(bigint,jsonb,text)',
    'EXECUTE'
  )
  AND otlet.reviewer_gold_visibility_error(
    :'other_reviewer_login'::regrole::oid
  ) = 'reviewer identity can read gold evidence',
  'SET-reachable raw correction access escaped reviewer closure'
);
SELECT format(
  'REVOKE EXECUTE ON FUNCTION '
    'otlet.correct_action(bigint,jsonb,text) FROM %I',
  :'gold_reader_role'
) \gexec
SELECT format(
  'GRANT EXECUTE ON FUNCTION otlet.export_eval_cases(integer) TO %I',
  :'gold_reader_role'
) \gexec
SELECT pg_temp.assert_true(
  NOT pg_catalog.has_function_privilege(
    :'other_reviewer_login',
    'otlet.export_eval_cases(integer)',
    'EXECUTE'
  )
  AND otlet.reviewer_gold_visibility_error(
    :'other_reviewer_login'::regrole::oid
  ) = 'reviewer identity can read gold evidence',
  'SET-reachable gold export access escaped reviewer closure'
);
SELECT format(
  'REVOKE EXECUTE ON FUNCTION otlet.export_eval_cases(integer) FROM %I',
  :'gold_reader_role'
) \gexec
SELECT format(
  'REVOKE %I FROM %I',
  :'gold_reader_role',
  :'other_reviewer_login'
) \gexec

SELECT pg_temp.assert_true(
  NOT pg_catalog.has_table_privilege(
    :'reviewer_login',
    'otlet.audit_eval_label_export',
    'SELECT'
  )
  AND NOT pg_catalog.has_table_privilege(
    :'reviewer_login',
    'otlet.audit_review_sample_export',
    'SELECT'
  )
  AND NOT pg_catalog.has_table_privilege(
    :'reviewer_login',
    'otlet.evaluation_cases',
    'SELECT'
  )
  AND pg_catalog.has_table_privilege(
    :'reviewer_login',
    'otlet.reviewer_calibration_queue',
    'SELECT'
  ),
  'Reviewer access exposes gold evidence or hides the blind queue'
);

SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1
    FROM otlet.reviewer_review_queue queue
    WHERE queue.task_name = (
      SELECT task_name FROM reviewer_calibration_proof
    )
  ),
  'Uncalibrated reviewer queue exposed review work'
);
DO $body$
DECLARE
  target_action_id bigint := (
    SELECT pre_action_id FROM reviewer_calibration_proof
  );
BEGIN
  BEGIN
    PERFORM otlet.approve_action(
      target_action_id,
      'Uncalibrated reviewer denial probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet reviewer authority denied: calibration_required' THEN
      RAISE;
    END IF;
  END;
  UPDATE reviewer_calibration_proof
  SET denied_before_calibration = true;
END
$body$;
RESET SESSION AUTHORIZATION;

SELECT pg_temp.assert_true(
  (SELECT status = 'proposed'
   FROM otlet.actions
   WHERE id = (SELECT pre_action_id FROM reviewer_calibration_proof))
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.review_events event
    WHERE event.action_id = (
      SELECT pre_action_id FROM reviewer_calibration_proof
    )
  ),
  'Uncalibrated review did not roll back atomically'
);

UPDATE reviewer_calibration_proof proof
SET failed_calibration_hash = otlet.register_reviewer_calibration(
  proof.task_name,
  :'reviewer_login'::regrole,
  'failed-v1',
  ARRAY[
    (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 1),
    (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 2)
  ],
  'Initial blinded reviewer calibration'
);

SELECT pg_temp.assert_true(
  (SELECT failed_calibration_hash FROM reviewer_calibration_proof) =
    otlet.register_reviewer_calibration(
      (SELECT task_name FROM reviewer_calibration_proof),
      :'reviewer_login'::regrole,
      'failed-v1',
      ARRAY[
        (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 1),
        (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 2)
      ],
      'Initial blinded reviewer calibration'
    ),
  'Reviewer calibration declaration retry was not exact'
);

SELECT format(
  'SET SESSION AUTHORIZATION %I',
  :'other_reviewer_login'
) \gexec
DO $body$
BEGIN
  BEGIN
    PERFORM *
    FROM otlet.reviewer_calibration_state(
      (SELECT failed_calibration_hash FROM reviewer_calibration_proof)
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
      'otlet reviewer calibration belongs to another reviewer' THEN
      RAISE;
    END IF;
  END;
END
$body$;
RESET SESSION AUTHORIZATION;

DO $body$
BEGIN
  BEGIN
    PERFORM otlet.register_reviewer_calibration(
      (SELECT task_name FROM reviewer_calibration_proof),
      (SELECT reviewer_oid::regrole FROM reviewer_calibration_proof),
      'reused-gold',
      ARRAY[
        (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 1),
        (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 3)
      ],
      'Gold reuse rejection probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet reviewer calibration gold case was already exposed' THEN
      RAISE;
    END IF;
  END;
  UPDATE reviewer_calibration_proof SET reused_gold_rejected = true;
END
$body$;

SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1
    FROM information_schema.columns column_state
    WHERE column_state.table_schema = 'otlet'
      AND column_state.table_name = 'reviewer_calibration_queue'
      AND column_state.column_name IN (
        'case_hash',
        'label_id',
        'expected_answer',
        'expected_confidence',
        'expected_action_type',
        'response_error'
      )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM information_schema.columns column_state
    WHERE column_state.table_schema = 'otlet'
      AND column_state.table_name = 'reviewer_review_queue'
      AND (
        column_state.column_name LIKE 'expected_%'
        OR column_state.column_name IN (
          'case_hash',
          'label_id',
          'calibration_hash',
          'member_token',
          'response_error'
        )
      )
  ),
  'Reviewer queues expose gold identity or answers'
);

SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT member_token AS failed_member_one
FROM otlet.reviewer_calibration_queue
WHERE calibration_hash = (
  SELECT failed_calibration_hash FROM reviewer_calibration_proof
)
  AND member_ordinal = 1 \gset
SELECT otlet.submit_reviewer_calibration(
  (SELECT failed_calibration_hash FROM reviewer_calibration_proof),
  :'failed_member_one',
  'reject',
  'high',
  'update_row'
) \g /dev/null
SELECT pg_temp.assert_true(
  (SELECT state = 'pending'
     AND response_count = 1
     AND calibration_error_count IS NULL
   FROM otlet.reviewer_calibration_state(
     (SELECT failed_calibration_hash FROM reviewer_calibration_proof)
   )),
  'Pending calibration exposed answer correctness'
);
SELECT member_token AS failed_member_two
FROM otlet.reviewer_calibration_queue
WHERE calibration_hash = (
  SELECT failed_calibration_hash FROM reviewer_calibration_proof
)
  AND member_ordinal = 2 \gset
SELECT otlet.submit_reviewer_calibration(
  (SELECT failed_calibration_hash FROM reviewer_calibration_proof),
  :'failed_member_two',
  'approve',
  'high',
  'update_row'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1
    FROM otlet.reviewer_review_queue queue
    WHERE queue.task_name = (
      SELECT task_name FROM reviewer_calibration_proof
    )
  ),
  'Failed calibration exposed review work'
);
RESET SESSION AUTHORIZATION;

SELECT pg_temp.assert_true(
  (SELECT state = 'calibration_threshold_breached'
     AND response_count = 2
     AND calibration_error_count = 1
     AND NOT review_authorized
   FROM otlet.audit_reviewer_calibration_export
   WHERE calibration_hash = (
     SELECT failed_calibration_hash FROM reviewer_calibration_proof
   )),
  'Failed reviewer calibration did not breach its threshold'
);

UPDATE reviewer_calibration_proof proof
SET passing_calibration_hash = otlet.register_reviewer_calibration(
  proof.task_name,
  :'reviewer_login'::regrole,
  'passing-v1',
  ARRAY[
    (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 3),
    (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 4)
  ],
  'Fresh passing reviewer calibration'
);

SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT member_token AS passing_member_one
FROM otlet.reviewer_calibration_queue
WHERE calibration_hash = (
  SELECT passing_calibration_hash FROM reviewer_calibration_proof
)
  AND member_ordinal = 1 \gset
SELECT otlet.submit_reviewer_calibration(
  (SELECT passing_calibration_hash FROM reviewer_calibration_proof),
  :'passing_member_one',
  'approve',
  'high',
  'update_row'
) \g /dev/null
SELECT member_token AS passing_member_two
FROM otlet.reviewer_calibration_queue
WHERE calibration_hash = (
  SELECT passing_calibration_hash FROM reviewer_calibration_proof
)
  AND member_ordinal = 2 \gset
UPDATE reviewer_calibration_proof
SET passing_member_two = :'passing_member_two';
SELECT otlet.submit_reviewer_calibration(
  (SELECT passing_calibration_hash FROM reviewer_calibration_proof),
  :'passing_member_two',
  'approve',
  'high',
  'update_row'
) \g /dev/null
SELECT otlet.submit_reviewer_calibration(
  (SELECT passing_calibration_hash FROM reviewer_calibration_proof),
  :'passing_member_two',
  'approve',
  'high',
  'update_row'
) \g /dev/null
DO $body$
BEGIN
  BEGIN
    PERFORM otlet.submit_reviewer_calibration(
      (SELECT passing_calibration_hash FROM reviewer_calibration_proof),
      (SELECT passing_member_two FROM reviewer_calibration_proof),
      'reject',
      'high',
      'update_row'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
      'otlet reviewer calibration response conflicts with its stored answer' THEN
      RAISE;
    END IF;
  END;
  UPDATE reviewer_calibration_proof
  SET conflicting_response_rejected = true;
END
$body$;
SELECT *
FROM otlet.approve_action(
  (SELECT approved_action_id FROM reviewer_calibration_proof),
  'Calibrated reviewer approval'
) \g /dev/null
SELECT *
FROM otlet.approve_action(
  (SELECT error_action_id FROM reviewer_calibration_proof),
  'Reviewer error threshold probe'
) \g /dev/null
RESET SESSION AUTHORIZATION;

UPDATE otlet.tasks task
SET instruction = task.instruction || ' Keep the response concise'
WHERE task.name = 'reviewer_calibration_probe_task';
UPDATE reviewer_calibration_proof proof
SET same_rubric_revision_hash = otlet.promote_configured_workload_revision(
  proof.task_name
);
UPDATE reviewer_calibration_proof proof
SET same_rubric_action_id = pg_temp.make_reviewer_action(
  'review-same-rubric', proof.same_rubric_revision_hash
);
SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT *
FROM otlet.approve_action(
  (SELECT same_rubric_action_id FROM reviewer_calibration_proof),
  'Same rubric revision approval'
) \g /dev/null
RESET SESSION AUTHORIZATION;

UPDATE reviewer_calibration_proof proof
SET blocked_action_id = pg_temp.make_reviewer_action(
  'review-blocked', proof.same_rubric_revision_hash
);
SELECT * FROM otlet.dry_run_action(
  (SELECT blocked_action_id FROM reviewer_calibration_proof)
) \g /dev/null

SAVEPOINT reviewer_gold_visible_probe;
SELECT format(
  'GRANT SELECT (qualification_eligible) ON '
    'otlet.eval_label_quality_status TO %I',
  :'gold_reader_role'
) \gexec
SELECT format(
  'GRANT %I TO %I WITH INHERIT FALSE, SET TRUE',
  :'gold_reader_role',
  :'reviewer_login'
) \gexec
SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT pg_temp.assert_true(
  (SELECT state = 'gold_visible' AND NOT review_authorized
   FROM otlet.reviewer_calibration_status
   WHERE calibration_hash = (
     SELECT passing_calibration_hash FROM reviewer_calibration_proof
   ))
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.reviewer_review_queue queue
    WHERE queue.task_name = (
      SELECT task_name FROM reviewer_calibration_proof
    )
  ),
  'Visible gold did not close the calibrated reviewer queue'
);
DO $body$
BEGIN
  BEGIN
    PERFORM otlet.approve_action(
      (SELECT blocked_action_id FROM reviewer_calibration_proof),
      'Visible-gold denial probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet reviewer authority denied: gold_visible' THEN
      RAISE;
    END IF;
  END;
END
$body$;
RESET SESSION AUTHORIZATION;
ROLLBACK TO SAVEPOINT reviewer_gold_visible_probe;
RELEASE SAVEPOINT reviewer_gold_visible_probe;
SELECT pg_temp.assert_true(
  (SELECT state = 'calibrated' AND review_authorized
   FROM otlet.audit_reviewer_calibration_export
   WHERE calibration_hash = (
     SELECT passing_calibration_hash FROM reviewer_calibration_proof
   )),
  'Revoked gold visibility did not restore reviewer authority'
);

SAVEPOINT reviewer_exposure_gold_visible_probe;
SELECT format(
  'GRANT SELECT (case_hash) ON '
    'otlet.evaluation_exposure_status TO %I',
  :'gold_reader_role'
) \gexec
SELECT format(
  'GRANT %I TO %I WITH INHERIT FALSE, SET TRUE',
  :'gold_reader_role',
  :'reviewer_login'
) \gexec
SELECT pg_temp.assert_true(
  NOT pg_catalog.has_table_privilege(
    :'reviewer_login',
    'otlet.evaluation_exposure_status',
    'SELECT'
  )
  AND pg_catalog.has_any_column_privilege(
    :'gold_reader_role',
    'otlet.evaluation_exposure_status',
    'SELECT'
  )
  AND pg_catalog.pg_has_role(
    :'reviewer_login'::regrole::oid,
    :'gold_reader_role'::regrole::oid,
    'SET'
  ),
  'Evaluation exposure column is not SET-reachable'
);
SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT pg_temp.assert_true(
  (SELECT state = 'gold_visible' AND NOT review_authorized
   FROM otlet.reviewer_calibration_status
   WHERE calibration_hash = (
     SELECT passing_calibration_hash FROM reviewer_calibration_proof
   ))
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.reviewer_review_queue queue
    WHERE queue.task_name = (
      SELECT task_name FROM reviewer_calibration_proof
    )
  ),
  'Visible evaluation exposure did not close the reviewer queue'
);
DO $body$
BEGIN
  BEGIN
    PERFORM otlet.approve_action(
      (SELECT blocked_action_id FROM reviewer_calibration_proof),
      'Visible evaluation exposure denial probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet reviewer authority denied: gold_visible' THEN
      RAISE;
    END IF;
  END;
END
$body$;
RESET SESSION AUTHORIZATION;
ROLLBACK TO SAVEPOINT reviewer_exposure_gold_visible_probe;
RELEASE SAVEPOINT reviewer_exposure_gold_visible_probe;
SELECT pg_temp.assert_true(
  (SELECT state = 'calibrated' AND review_authorized
   FROM otlet.audit_reviewer_calibration_export
   WHERE calibration_hash = (
     SELECT passing_calibration_hash FROM reviewer_calibration_proof
   )),
  'Revoked evaluation exposure did not restore reviewer authority'
);

SAVEPOINT reviewer_gold_invalid_probe;
UPDATE public.otlet_demo_reviewer_calibration
SET protected_note = 'STALE GOLD PROBE'
WHERE id = 'gold-3';
SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT pg_temp.assert_true(
  (SELECT state = 'gold_invalid' AND NOT review_authorized
   FROM otlet.reviewer_calibration_status
   WHERE calibration_hash = (
     SELECT passing_calibration_hash FROM reviewer_calibration_proof
   ))
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.reviewer_review_queue queue
    WHERE queue.task_name = (
      SELECT task_name FROM reviewer_calibration_proof
    )
  ),
  'Invalid gold did not close the calibrated reviewer queue'
);
DO $body$
BEGIN
  BEGIN
    PERFORM otlet.approve_action(
      (SELECT blocked_action_id FROM reviewer_calibration_proof),
      'Invalid-gold denial probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet reviewer authority denied: gold_invalid' THEN
      RAISE;
    END IF;
  END;
END
$body$;
RESET SESSION AUTHORIZATION;
ROLLBACK TO SAVEPOINT reviewer_gold_invalid_probe;
RELEASE SAVEPOINT reviewer_gold_invalid_probe;
SELECT pg_temp.assert_true(
  (SELECT state = 'calibrated' AND review_authorized
   FROM otlet.audit_reviewer_calibration_export
   WHERE calibration_hash = (
     SELECT passing_calibration_hash FROM reviewer_calibration_proof
   )),
  'Reverted gold drift did not restore reviewer authority'
);

UPDATE reviewer_calibration_proof proof
SET refresh_calibration_hash = otlet.register_reviewer_calibration(
  proof.task_name,
  :'reviewer_login'::regrole,
  'refresh-v1',
  ARRAY[
    (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 5),
    (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 6)
  ],
  'Pending refresh begun before reviewer error discovery'
);
SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT member_token AS refresh_member_one
FROM otlet.reviewer_calibration_queue
WHERE calibration_hash = (
  SELECT refresh_calibration_hash FROM reviewer_calibration_proof
)
  AND member_ordinal = 1 \gset
SELECT otlet.submit_reviewer_calibration(
  (SELECT refresh_calibration_hash FROM reviewer_calibration_proof),
  :'refresh_member_one', 'approve', 'high', 'update_row'
) \g /dev/null
SELECT pg_temp.assert_true(
  (SELECT state = 'pending' AND response_count = 1
   FROM otlet.reviewer_calibration_status
   WHERE calibration_hash = (
     SELECT refresh_calibration_hash FROM reviewer_calibration_proof
   )),
  'Pre-error reviewer refresh is not pending'
);
RESET SESSION AUTHORIZATION;

SELECT otlet.record_reviewer_error(
  event.id,
  'Reviewer approved an action that failed owner review'
) AS review_error_hash
FROM otlet.review_events event
WHERE event.action_id = (
    SELECT error_action_id FROM reviewer_calibration_proof
  )
  AND event.reviewer_identity = :'reviewer_login' \gset
SELECT pg_temp.assert_true(
  :'review_error_hash' = otlet.record_reviewer_error(
    event.id,
    'Reviewer approved an action that failed owner review'
  ),
  'Reviewer error declaration retry was not exact'
)
FROM otlet.review_events event
WHERE event.action_id = (
    SELECT error_action_id FROM reviewer_calibration_proof
  )
  AND event.reviewer_identity = :'reviewer_login';
DO $body$
BEGIN
  BEGIN
    PERFORM otlet.record_reviewer_error(
      event.id,
      'Conflicting reviewer error reason'
    )
    FROM otlet.review_events event
    WHERE event.action_id = (
        SELECT error_action_id FROM reviewer_calibration_proof
      )
      AND event.reviewer_identity = (
        SELECT reviewer_oid::regrole::text
        FROM reviewer_calibration_proof
      );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
      'otlet reviewer review error conflicts with its stored declaration' THEN
      RAISE;
    END IF;
  END;
  UPDATE reviewer_calibration_proof
  SET conflicting_review_error_rejected = true;
END
$body$;

SELECT pg_temp.assert_true(
  (SELECT state = 'review_error_threshold_breached'
     AND review_count = 3
     AND review_error_count = 1
     AND NOT review_authorized
   FROM otlet.audit_reviewer_calibration_export
   WHERE calibration_hash = (
     SELECT passing_calibration_hash FROM reviewer_calibration_proof
   )),
  'Recorded reviewer error did not breach the declared threshold'
);

SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT member_token AS refresh_member_two
FROM otlet.reviewer_calibration_queue
WHERE calibration_hash = (
  SELECT refresh_calibration_hash FROM reviewer_calibration_proof
)
  AND member_ordinal = 2 \gset
SELECT otlet.submit_reviewer_calibration(
  (SELECT refresh_calibration_hash FROM reviewer_calibration_proof),
  :'refresh_member_two', 'approve', 'high', 'update_row'
) \g /dev/null
SELECT pg_temp.assert_true(
  (SELECT state = 'review_error_threshold_breached'
     AND response_count = 2
     AND review_error_count = 1
     AND NOT review_authorized
   FROM otlet.reviewer_calibration_status
   WHERE calibration_hash = (
     SELECT refresh_calibration_hash FROM reviewer_calibration_proof
   )),
  'Pre-error refresh escaped the later reviewer error'
);
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1
    FROM otlet.reviewer_review_queue queue
    WHERE queue.task_name = (
      SELECT task_name FROM reviewer_calibration_proof
    )
  ),
  'Reviewer error threshold exposed review work'
);
DO $body$
BEGIN
  BEGIN
    PERFORM otlet.approve_action(
      (SELECT blocked_action_id FROM reviewer_calibration_proof),
      'Threshold-breached reviewer denial probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
      'otlet reviewer authority denied: review_error_threshold_breached' THEN
      RAISE;
    END IF;
  END;
  UPDATE reviewer_calibration_proof SET denied_after_error = true;
END
$body$;
RESET SESSION AUTHORIZATION;

DO $body$
BEGIN
  BEGIN
    UPDATE otlet.tasks task
    SET decision_contract = jsonb_set(
      task.decision_contract,
      '{review_rubric,instructions}',
      '[]'::jsonb
    )
    WHERE task.name = 'reviewer_calibration_probe_task';
    PERFORM otlet.capture_workload_revision(
      'reviewer_calibration_probe_task'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet review rubric is invalid' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    UPDATE otlet.tasks task
    SET decision_contract = jsonb_set(
      task.decision_contract,
      '{review_rubric,maximum_calibration_errors}',
      '2'::jsonb
    )
    WHERE task.name = 'reviewer_calibration_probe_task';
    PERFORM otlet.capture_workload_revision(
      'reviewer_calibration_probe_task'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
      'otlet review rubric calibration threshold must require one correct case' THEN
      RAISE;
    END IF;
  END;
  UPDATE reviewer_calibration_proof SET invalid_rubric_rejected = true;
END
$body$;

UPDATE otlet.tasks task
SET decision_contract = jsonb_set(
  task.decision_contract,
  '{review_rubric,instructions}',
  to_jsonb('Apply the revised evidence rubric before approving a row update'::text)
)
WHERE task.name = 'reviewer_calibration_probe_task';
UPDATE reviewer_calibration_proof proof
SET changed_rubric_revision_hash = otlet.promote_configured_workload_revision(
  proof.task_name
);
UPDATE reviewer_calibration_proof proof
SET changed_action_id = pg_temp.make_reviewer_action(
  'review-changed', proof.changed_rubric_revision_hash
);
SELECT * FROM otlet.dry_run_action(
  (SELECT changed_action_id FROM reviewer_calibration_proof)
) \g /dev/null

SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1
    FROM otlet.reviewer_review_queue queue
    WHERE queue.task_name = (
      SELECT task_name FROM reviewer_calibration_proof
    )
  ),
  'Changed rubric exposed review work'
);
DO $body$
BEGIN
  BEGIN
    PERFORM otlet.approve_action(
      (SELECT changed_action_id FROM reviewer_calibration_proof),
      'Changed rubric denial probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet reviewer authority denied: rubric_changed' THEN
      RAISE;
    END IF;
  END;
  UPDATE reviewer_calibration_proof SET denied_after_rubric_change = true;
END
$body$;
RESET SESSION AUTHORIZATION;

SELECT pg_temp.make_reviewer_gold(
  ordinal,
  (SELECT changed_rubric_revision_hash FROM reviewer_calibration_proof)
)
FROM generate_series(7, 8) ordinal \g /dev/null
UPDATE reviewer_calibration_proof proof
SET changed_calibration_hash = otlet.register_reviewer_calibration(
  proof.task_name,
  :'reviewer_login'::regrole,
  'changed-rubric-v1',
  ARRAY[
    (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 7),
    (SELECT case_hash FROM reviewer_calibration_cases WHERE ordinal = 8)
  ],
  'Calibration for the changed reviewer rubric'
),
final_action_id = pg_temp.make_reviewer_action(
  'review-final', proof.changed_rubric_revision_hash
);
SELECT * FROM otlet.dry_run_action(
  (SELECT final_action_id FROM reviewer_calibration_proof)
) \g /dev/null

SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT member_token AS changed_member_one
FROM otlet.reviewer_calibration_queue
WHERE calibration_hash = (
  SELECT changed_calibration_hash FROM reviewer_calibration_proof
)
  AND member_ordinal = 1 \gset
SELECT otlet.submit_reviewer_calibration(
  (SELECT changed_calibration_hash FROM reviewer_calibration_proof),
  :'changed_member_one', 'approve', 'high', 'update_row'
) \g /dev/null
SELECT member_token AS changed_member_two
FROM otlet.reviewer_calibration_queue
WHERE calibration_hash = (
  SELECT changed_calibration_hash FROM reviewer_calibration_proof
)
  AND member_ordinal = 2 \gset
SELECT otlet.submit_reviewer_calibration(
  (SELECT changed_calibration_hash FROM reviewer_calibration_proof),
  :'changed_member_two', 'approve', 'high', 'update_row'
) \g /dev/null
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1
     AND bool_and(queue.next_reviewer_step = 'approve')
     AND bool_and(queue.shaped_input #>> '{row,id}' = 'review-final')
     AND bool_and(NOT queue.shaped_input ? '_otlet_mvcc')
     AND bool_and(queue.output ->> 'decision' = 'approve')
     AND bool_and(jsonb_array_length(queue.proposed_actions) = 1)
     AND bool_and(
       queue.proposed_actions #>> '{0,action_id}' = queue.action_id::text
     )
     AND bool_and(
       queue.proposed_actions #>> '{0,action_type}' = 'update_row'
     )
     AND bool_and(
       (queue.proposed_actions #>> '{0,valid}')::boolean
     )
     AND bool_and(
       queue.review_rubric ->> 'format' = 'otlet.review_rubric.v1'
     )
     AND bool_and(
       queue.response_contract -> 'answer_values' ? 'approve'
     )
     AND bool_and(
       queue.response_contract -> 'action_types' ? 'update_row'
     )
     AND bool_and(queue.response_contract -> 'action_types' ? 'none')
   FROM otlet.reviewer_review_queue queue
   WHERE queue.action_id = (
     SELECT final_action_id FROM reviewer_calibration_proof
   ))
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.reviewer_review_queue queue
    WHERE queue.task_name <> (
      SELECT task_name FROM reviewer_calibration_proof
    )
  ),
  'Calibrated reviewer action queue is incomplete'
);
SELECT *
FROM otlet.approve_action(
  (SELECT final_action_id FROM reviewer_calibration_proof),
  'Changed rubric calibrated approval'
) \g /dev/null
RESET SESSION AUTHORIZATION;

SELECT pg_temp.assert_true(
  otlet.materialize_completed_semantic_job(job.id) > 0,
  'Semantic correction fixture did not materialize'
)
FROM reviewer_calibration_proof proof
JOIN otlet.actions action ON action.id = proof.changed_action_id
JOIN otlet.jobs job ON job.id = action.job_id;

UPDATE reviewer_calibration_proof proof
SET invalid_correction_snapshot = jsonb_build_object(
  'action', to_jsonb(action),
  'labels', COALESCE((
    SELECT jsonb_agg(to_jsonb(label) ORDER BY label.id)
    FROM otlet.eval_labels label
    WHERE label.action_id = proof.changed_action_id
  ), '[]'::jsonb),
  'review_events', COALESCE((
    SELECT jsonb_agg(to_jsonb(event) ORDER BY event.id)
    FROM otlet.review_events event
    WHERE event.action_id = proof.changed_action_id
  ), '[]'::jsonb)
)
FROM otlet.actions action
WHERE action.id = proof.changed_action_id;
SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
DO $body$
BEGIN
  BEGIN
    PERFORM 1
    FROM otlet.reviewer_correct_action(
      (SELECT changed_action_id FROM reviewer_calibration_proof),
      '{
        "decision":"reject",
        "confidence":"high",
        "action_type":"invented_action"
      }'::jsonb,
      'Undeclared correction action type probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
      'otlet reviewer correction action type is not declared' THEN
      RAISE;
    END IF;
  END;
END
$body$;
RESET SESSION AUTHORIZATION;
SELECT pg_temp.assert_true(
  (SELECT proof.invalid_correction_snapshot = jsonb_build_object(
     'action', to_jsonb(action),
     'labels', COALESCE((
       SELECT jsonb_agg(to_jsonb(label) ORDER BY label.id)
       FROM otlet.eval_labels label
       WHERE label.action_id = proof.changed_action_id
     ), '[]'::jsonb),
     'review_events', COALESCE((
       SELECT jsonb_agg(to_jsonb(event) ORDER BY event.id)
       FROM otlet.review_events event
       WHERE event.action_id = proof.changed_action_id
     ), '[]'::jsonb)
   )
   FROM reviewer_calibration_proof proof
   JOIN otlet.actions action ON action.id = proof.changed_action_id),
  'Rejected reviewer correction mutated its action or review evidence'
);
SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
UPDATE reviewer_calibration_proof proof
SET (semantic_label_id, semantic_review_event_id) = (
  SELECT corrected.label_id, corrected.review_event_id
  FROM otlet.reviewer_correct_action(
    proof.changed_action_id,
    '{
      "decision":"reject",
      "confidence":"high",
      "action_type":"update_row"
    }'::jsonb,
    'Calibrated semantic correction'
  ) corrected
);
UPDATE reviewer_calibration_proof proof
SET semantic_expires_at = clock_timestamp() + interval '500 milliseconds';
UPDATE reviewer_calibration_proof proof
SET semantic_correction_hash = otlet.approve_semantic_correction(
  proof.semantic_label_id,
  proof.semantic_review_event_id,
  '{"decision":"reject","confidence":"high"}'::jsonb,
  proof.semantic_expires_at,
  0.99,
  'Calibrated semantic correction approval'
);
SELECT pg_temp.assert_true(
  proof.semantic_correction_hash = otlet.approve_semantic_correction(
    proof.semantic_label_id,
    proof.semantic_review_event_id,
    '{"decision":"reject","confidence":"high"}'::jsonb,
    proof.semantic_expires_at,
    0.99,
    'Calibrated semantic correction approval'
  ),
  'Semantic correction approval retry was not exact'
)
FROM reviewer_calibration_proof proof;
SELECT pg_sleep(0.55);
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1
     AND bool_and(
       queue.next_reviewer_step = 're_review_semantic_correction'
     )
     AND bool_and(
       (queue.output ->> 'correction_label_id')::bigint =
         proof.semantic_label_id
     )
     AND bool_and(
       (queue.output ->> 'review_event_id')::bigint =
         proof.semantic_review_event_id
     )
   FROM otlet.reviewer_review_queue queue
   CROSS JOIN reviewer_calibration_proof proof
   WHERE queue.queue_kind = 'semantic_correction_re_review'
     AND queue.action_id = proof.changed_action_id),
  'Expired semantic correction is missing from the reviewer queue'
);
UPDATE reviewer_calibration_proof proof
SET (semantic_denied_label_id, semantic_denied_review_event_id) = (
  SELECT corrected.label_id, corrected.review_event_id
  FROM otlet.reviewer_correct_action(
    proof.changed_action_id,
    '{
      "decision":"reject",
      "confidence":"high",
      "action_type":"update_row"
    }'::jsonb,
    'Calibrated semantic correction renewal'
  ) corrected
);
RESET SESSION AUTHORIZATION;

SELECT pg_temp.assert_true(
  proof.semantic_label_id IS NOT NULL
  AND proof.semantic_denied_label_id IS NOT NULL
  AND proof.semantic_label_id <> proof.semantic_denied_label_id
  AND correction.correction_hash = proof.semantic_correction_hash
  AND correction.correction_author_identity = :'reviewer_login'
  AND correction.approver_identity = :'reviewer_login'
  AND (
    SELECT count(*) = 1
      AND bool_and(
        event.reviewer_calibration_hash = proof.changed_calibration_hash
      )
      AND bool_and(
        event.reviewer_rubric_hash = assignment.rubric_hash
      )
    FROM otlet.review_events event
    JOIN otlet.reviewer_calibrations assignment
      ON assignment.calibration_hash = proof.changed_calibration_hash
    WHERE event.action_id = proof.changed_action_id
      AND event.outcome = 'approve'
      AND event.reason =
        'Semantic correction approval: Calibrated semantic correction approval'
  ),
  'Calibrated semantic correction evidence is incomplete'
)
FROM reviewer_calibration_proof proof
JOIN otlet.semantic_correction_overrides correction
  ON correction.correction_hash = proof.semantic_correction_hash;

SELECT otlet.register_workload_acceptance_contract(
  (SELECT task_name FROM reviewer_calibration_proof),
  (SELECT changed_rubric_revision_hash FROM reviewer_calibration_proof),
  (SELECT changed_rubric_revision_hash FROM reviewer_calibration_proof),
  '{
    "mode":"sample",
    "rule":{
      "kind":"stable_hash",
      "basis":"receipt_id",
      "review_sampling":{
        "format":"otlet.review_sampling.v1",
        "action_free_rate":1
      }
    }
  }'::jsonb,
  clock_timestamp() + interval '100 milliseconds',
  clock_timestamp() + interval '1 hour',
  '{"name":"active_revision","definition":{"kind":"workload_revision"}}',
  (
    SELECT jsonb_object_agg(
      category,
      jsonb_build_object(
        'metric', category,
        'statistic', 'rate',
        'operator', 'lte',
        'value', 1,
        'unit', 'ratio',
        'minimum_support', 0,
        'required', false
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
    ]) category
  )
) \g /dev/null
SELECT pg_sleep(0.15) \g /dev/null

DO $body$
DECLARE
  proof reviewer_calibration_proof%ROWTYPE;
  job_input jsonb;
  job_output jsonb := '{"decision":"approve","confidence":"high"}'::jsonb;
  saved_job_id bigint;
  saved_output_id bigint;
  claim_token text := gen_random_uuid()::text;
  started_at timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO proof FROM reviewer_calibration_proof;
  SELECT jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_reviewer_calibration',
      'subject_id', source.id,
      'ctid', source.ctid::text,
      'xmin', source.xmin::text
    ),
    'table', 'public.otlet_demo_reviewer_calibration',
    'row', to_jsonb(source)
  )
  INTO job_input
  FROM public.otlet_demo_reviewer_calibration source
  WHERE source.id = 'review-sample';
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
    proof.task_name,
    proof.changed_rubric_revision_hash,
    'review-sample',
    job_input,
    'running',
    1,
    started_at,
    started_at + interval '5 minutes',
    claim_token
  ) RETURNING id INTO saved_job_id;
  SELECT completed.id
  INTO saved_output_id
  FROM otlet.complete_job(
    job_id => saved_job_id,
    output => job_output,
    raw_output => jsonb_build_object(
      'output', job_output,
      'actions', '[]'::jsonb
    )::text,
    actions => '[]'::jsonb,
    started_at => started_at,
    trace_summary => jsonb_build_object(
      'schema_validation_status', 'passed',
      'generate_ms', 1,
      'mvcc', jsonb_build_object(
        'table', 'public.otlet_demo_reviewer_calibration'
      )
    ),
    model_name => 'reviewer_calibration_model',
    expected_claim_token => claim_token
  ) completed;
  UPDATE reviewer_calibration_proof
  SET sample_receipt_id = (
    SELECT output.receipt_id
    FROM otlet.outputs output
    WHERE output.id = saved_output_id
  );
END
$body$;

SELECT format('SET SESSION AUTHORIZATION %I', :'reviewer_login') \gexec
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1
     AND bool_and(queue.queue_kind = 'sampled_output')
     AND bool_and(queue.next_reviewer_step = 'label_sample')
     AND bool_and(queue.action_id IS NULL)
     AND bool_and(queue.shaped_input #>> '{row,id}' = 'review-sample')
     AND bool_and(NOT queue.shaped_input ? '_otlet_mvcc')
     AND bool_and(queue.output ->> 'decision' = 'approve')
     AND bool_and(queue.proposed_actions = '[]'::jsonb)
     AND bool_and(
       queue.review_rubric ->> 'format' = 'otlet.review_rubric.v1'
     )
   FROM otlet.reviewer_review_queue queue
   WHERE queue.receipt_id = (
     SELECT sample_receipt_id FROM reviewer_calibration_proof
   )),
  'Calibrated sampled-output queue is incomplete'
);
UPDATE reviewer_calibration_proof proof
SET sample_label_id = (
  SELECT label.id
  FROM otlet.label_review_sample(
    proof.sample_receipt_id,
    'approve',
    'high',
    'none',
    'approve',
    'Calibrated sampled-output approval'
  ) label
);
SELECT pg_temp.assert_true(
  proof.sample_label_id = (
    SELECT label.id
    FROM otlet.label_review_sample(
      proof.sample_receipt_id,
      'approve',
      'high',
      'none',
      'approve',
      'Calibrated sampled-output approval'
    ) label
  )
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.reviewer_review_queue queue
    WHERE queue.receipt_id = proof.sample_receipt_id
  ),
  'Sampled-output review retry was not exact'
)
FROM reviewer_calibration_proof proof;
RESET SESSION AUTHORIZATION;

SELECT pg_temp.assert_true(
  proof.sample_label_id IS NOT NULL
  AND (
    SELECT count(*) = 1
      AND bool_and(event.action_id IS NULL)
      AND bool_and(event.outcome = 'approve')
      AND bool_and(
        event.reviewer_calibration_hash = proof.changed_calibration_hash
      )
      AND bool_and(
        event.reviewer_rubric_hash = assignment.rubric_hash
      )
    FROM otlet.review_events event
    JOIN otlet.reviewer_calibrations assignment
      ON assignment.calibration_hash = proof.changed_calibration_hash
    WHERE event.receipt_id = proof.sample_receipt_id
      AND event.reason = 'Calibrated sampled-output approval'
  ),
  'Calibrated sampled-output event lacks provenance'
)
FROM reviewer_calibration_proof proof;

SELECT :'reviewer_login' || '_renamed' AS renamed_reviewer_login \gset
SAVEPOINT reviewer_identity_probe;
SELECT format(
  'ALTER ROLE %I RENAME TO %I',
  :'reviewer_login',
  :'renamed_reviewer_login'
) \gexec
SELECT pg_temp.assert_true(
  (SELECT role.oid = proof.reviewer_oid
     AND role.rolname = :'renamed_reviewer_login'
   FROM reviewer_calibration_proof proof
   JOIN pg_catalog.pg_roles role ON role.oid = proof.reviewer_oid)
  AND (SELECT state = 'reviewer_identity_invalid'
         AND NOT review_authorized
       FROM otlet.audit_reviewer_calibration_export
       WHERE calibration_hash = (
         SELECT changed_calibration_hash FROM reviewer_calibration_proof
       )),
  'OID-preserving reviewer rename did not invalidate calibration identity'
);
SELECT format(
  'SET SESSION AUTHORIZATION %I',
  :'renamed_reviewer_login'
) \gexec
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1
    FROM otlet.reviewer_review_queue queue
    WHERE queue.task_name = (
      SELECT task_name FROM reviewer_calibration_proof
    )
  ),
  'Renamed reviewer identity exposed review work'
);
DO $body$
DECLARE
  proof reviewer_calibration_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM reviewer_calibration_proof;
  BEGIN
    PERFORM otlet.approve_semantic_correction(
      proof.semantic_denied_label_id,
      proof.semantic_denied_review_event_id,
      '{"decision":"reject","confidence":"high"}'::jsonb,
      proof.semantic_expires_at + interval '1 hour',
      0.99,
      'Renamed reviewer semantic correction denial',
      proof.semantic_correction_hash
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
      'otlet reviewer authority denied: reviewer_identity_invalid' THEN
      RAISE;
    END IF;
  END;
END
$body$;
RESET SESSION AUTHORIZATION;
ROLLBACK TO SAVEPOINT reviewer_identity_probe;
RELEASE SAVEPOINT reviewer_identity_probe;
SELECT pg_temp.assert_true(
  (SELECT role.oid = proof.reviewer_oid
     AND role.rolname = :'reviewer_login'
   FROM reviewer_calibration_proof proof
   JOIN pg_catalog.pg_roles role ON role.oid = proof.reviewer_oid)
  AND (SELECT state = 'calibrated' AND review_authorized
       FROM otlet.audit_reviewer_calibration_export
       WHERE calibration_hash = (
         SELECT changed_calibration_hash FROM reviewer_calibration_proof
       ))
  AND (SELECT label.adjudication_state = 'pending'
       FROM otlet.eval_labels label
       WHERE label.id = (
         SELECT semantic_denied_label_id FROM reviewer_calibration_proof
       ))
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.semantic_correction_overrides correction
    WHERE correction.correction_label_id = (
      SELECT semantic_denied_label_id FROM reviewer_calibration_proof
    )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.review_events event
    WHERE event.reason =
      'Semantic correction approval: Renamed reviewer semantic correction denial'
  ),
  'Reviewer rename rollback did not preserve semantic correction evidence'
);

DO $body$
BEGIN
  BEGIN
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
      runtime_fingerprint_hash,
      reviewer_rubric_hash,
      reviewer_calibration_hash
    )
    SELECT
      event.outcome,
      event.reviewer_identity,
      event.reviewer_role,
      'Forged calibrated event probe',
      event.job_id,
      event.task_name,
      event.subject_id,
      event.action_id,
      event.output_id,
      event.receipt_id,
      event.source_table,
      event.source_hash,
      event.content_hash,
      event.current_content_hash,
      event.source_freshness,
      event.model_name,
      event.model_artifact_hash,
      event.prompt_hash,
      event.output_schema_hash,
      event.output_hash,
      event.runtime_fingerprint_hash,
      event.reviewer_rubric_hash,
      proof.passing_calibration_hash
    FROM reviewer_calibration_proof proof
    JOIN otlet.review_events event
      ON event.action_id = proof.final_action_id;
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
      'otlet review event calibration provenance is invalid' THEN
      RAISE;
    END IF;
  END;
  UPDATE reviewer_calibration_proof
  SET forged_review_provenance_rejected = true;
END
$body$;

SELECT pg_temp.assert_true(
  (SELECT denied_before_calibration
     AND conflicting_response_rejected
     AND reused_gold_rejected
     AND denied_after_error
     AND denied_after_rubric_change
     AND conflicting_review_error_rejected
     AND invalid_rubric_rejected
     AND forged_review_provenance_rejected
   FROM reviewer_calibration_proof),
  'Reviewer calibration negative proof is incomplete'
);
SELECT pg_temp.assert_true(
  (SELECT state = 'calibrated' AND review_authorized
   FROM otlet.audit_reviewer_calibration_export
   WHERE calibration_hash = (
     SELECT changed_calibration_hash FROM reviewer_calibration_proof
   )),
  'Changed rubric calibration did not restore review authority'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) = 8
   FROM otlet.review_events event
   WHERE event.reviewer_identity = :'reviewer_login'
     AND event.reviewer_rubric_hash IS NOT NULL
     AND event.reviewer_calibration_hash IS NOT NULL),
  'Delegated review events lack calibration provenance'
);
SELECT pg_temp.assert_true(
  NOT pg_catalog.has_function_privilege(
    :'reviewer_role',
    'otlet.label_action(bigint,text,text,text,text,text)',
    'EXECUTE'
  )
  AND pg_catalog.has_function_privilege(
    :'reviewer_role',
    'otlet.reviewer_correct_action(bigint,jsonb,text)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_function_privilege(
    :'reviewer_role',
    'otlet.correct_action(bigint,jsonb,text)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_table_privilege(
    :'reviewer_role',
    'otlet.review_events',
    'SELECT'
  )
  AND NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.reviewer_correct_action(bigint,jsonb,text)',
    'EXECUTE'
  )
  AND pg_catalog.has_table_privilege(
    :'reviewer_role',
    'otlet.reviewer_review_queue',
    'SELECT'
  )
  AND pg_catalog.has_function_privilege(
    :'reviewer_role',
    'otlet.reviewer_review_queue_rows()',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_table_privilege(
    :'reviewer_role',
    'otlet.audit_review_export',
    'SELECT'
  )
  AND NOT pg_catalog.has_table_privilege(
    :'reviewer_role',
    'otlet.reviewer_review_errors',
    'SELECT'
  )
  AND NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.submit_reviewer_calibration(text,text,text,text,text)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.reviewer_review_queue_rows()',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_function_privilege(
    :'reviewer_role',
    'otlet.record_reviewer_error(bigint,text)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.record_reviewer_error(bigint,text)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_table_privilege(
    'public',
    'otlet.reviewer_calibrations',
    'SELECT'
  )
  AND NOT pg_catalog.has_table_privilege(
    'public',
    'otlet.reviewer_review_errors',
    'SELECT'
  ),
  'Reviewer calibration privilege closure failed'
);

DO $body$
BEGIN
  BEGIN
    UPDATE otlet.reviewer_calibrations
    SET reason = 'forbidden mutation'
    WHERE calibration_hash = (
      SELECT changed_calibration_hash FROM reviewer_calibration_proof
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation evidence is append only' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    TRUNCATE otlet.reviewer_calibration_responses;
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation evidence is append only' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    UPDATE otlet.reviewer_review_errors
    SET reason = 'forbidden mutation';
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation evidence is append only' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    TRUNCATE otlet.reviewer_review_errors;
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation evidence is append only' THEN
      RAISE;
    END IF;
  END;
END
$body$;

SELECT concat_ws('|',
  (SELECT denied_before_calibration FROM reviewer_calibration_proof),
  (SELECT state FROM otlet.audit_reviewer_calibration_export
   WHERE calibration_hash = (
     SELECT failed_calibration_hash FROM reviewer_calibration_proof
   )),
  (SELECT state FROM otlet.audit_reviewer_calibration_export
   WHERE calibration_hash = (
     SELECT passing_calibration_hash FROM reviewer_calibration_proof
   )),
  (SELECT state FROM otlet.audit_reviewer_calibration_export
   WHERE calibration_hash = (
     SELECT refresh_calibration_hash FROM reviewer_calibration_proof
   )),
  (SELECT state FROM otlet.audit_reviewer_calibration_export
   WHERE calibration_hash = (
     SELECT changed_calibration_hash FROM reviewer_calibration_proof
   )),
  (SELECT count(*) FROM otlet.reviewer_calibrations),
  (SELECT count(*) FROM otlet.reviewer_calibration_responses)
) AS reviewer_calibration_contract;

ROLLBACK;
SQL
