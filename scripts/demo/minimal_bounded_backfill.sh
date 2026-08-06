log "Proving minimal bounded backfill"

minimal_bounded_backfill_output="$(mktemp)"
if ! psql_exec -qAt -v model_name="$cheap_model_name" \
  >"$minimal_bounded_backfill_output" <<'SQL'
BEGIN;
SET LOCAL statement_timeout = '2000ms';
SELECT 1
FROM otlet.production_policy
WHERE name = 'default'
FOR UPDATE \g /dev/null

CREATE FUNCTION pg_temp.assert_true(condition boolean, message text)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT COALESCE(assert_true.condition, false) THEN
    RAISE EXCEPTION '%', assert_true.message;
  END IF;
END;
$function$;

CREATE FUNCTION pg_temp.expect_error(statement text, message_fragment text)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    EXECUTE expect_error.statement;
    RAISE EXCEPTION 'expected statement to fail: %', expect_error.statement;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected statement to fail: ' || expect_error.statement
       OR position(expect_error.message_fragment IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;
END;
$function$;

CREATE TEMP TABLE backfill_proof_context (
  name text PRIMARY KEY,
  value text NOT NULL
) ON COMMIT DROP;
CREATE TEMP TABLE backfill_proof_rpc (
  name text PRIMARY KEY,
  submission_state text NOT NULL,
  current_generation bigint NOT NULL,
  processed_subjects integer NOT NULL,
  queued_jobs integer NOT NULL
) ON COMMIT DROP;
CREATE TEMP TABLE backfill_proof_claims (
  job_id bigint PRIMARY KEY,
  task_name text NOT NULL,
  subject_id text NOT NULL,
  claim_token text NOT NULL,
  backfill_deferred boolean NOT NULL
) ON COMMIT DROP;

CREATE TABLE public.otlet_bounded_backfill_source (
  id text PRIMARY KEY,
  payload text NOT NULL
);
INSERT INTO public.otlet_bounded_backfill_source VALUES
  ('e', 'v1'),
  ('c', 'v1'),
  ('a', 'v1'),
  ('d', 'v1'),
  ('b', 'v1');

SELECT otlet.create_watch(
  watch_name => 'bounded_backfill_a',
  kind => 'row',
  instruction => 'Return the decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_bounded_backfill_source'::regclass,
  subject_column => 'id',
  input_columns => ARRAY['id', 'payload'],
  trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb
) \g /dev/null
INSERT INTO backfill_proof_context
SELECT 'task_revision', head.active_workload_revision_hash
FROM otlet.workload_revision_heads head
WHERE head.task_name = 'bounded_backfill_a_task';

SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.create_task_backfill(%L, %L, 4, 2, 64, 64)',
    'bounded_backfill_a_task',
    (SELECT value FROM backfill_proof_context WHERE name = 'task_revision')
  ),
  'subject set exceeds requested maximum 4'
);
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1
    FROM otlet.task_backfills
    WHERE task_name = 'bounded_backfill_a_task'
  ),
  'overflowing backfill persisted state'
);

INSERT INTO backfill_proof_context
SELECT
  'rate_backfill',
  otlet.create_task_backfill(
    'bounded_backfill_a_task',
    (SELECT value FROM backfill_proof_context WHERE name = 'task_revision'),
    5,
    2,
    1,
    8
  )::text;
INSERT INTO backfill_proof_rpc
SELECT 'rate_first', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'rate_backfill'),
  0
) page;
SELECT pg_temp.assert_true(
  (SELECT (submission_state, current_generation, processed_subjects, queued_jobs)
   FROM backfill_proof_rpc WHERE name = 'rate_first') =
    ('submitted'::text, 1::bigint, 1, 1),
  'rate-limited backfill first page was incorrect'
);
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.create_task_backfill(%L, %L, 5, 2, 64, 64)',
    'bounded_backfill_a_task',
    (SELECT value FROM backfill_proof_context WHERE name = 'task_revision')
  ),
  'already has an unfinished backfill'
);
SELECT pg_temp.assert_true(
  otlet.run_task_subject(
    'bounded_backfill_a_task',
    'a',
    (SELECT value FROM backfill_proof_context WHERE name = 'task_revision')
  ) = 0,
  'foreground collision inserted a duplicate job'
);
SELECT pg_temp.assert_true(
  otlet.reconcile_watch_subject('bounded_backfill_a', 'a', true) = 'active_job',
  'foreground promotion left watch reconciliation pending'
);
INSERT INTO backfill_proof_rpc
SELECT 'rate_second', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'rate_backfill'),
  1
) page;
SELECT pg_temp.assert_true(
  (SELECT (submission_state, current_generation, processed_subjects, queued_jobs)
   FROM backfill_proof_rpc WHERE name = 'rate_second') =
    ('rate_limited'::text, 1::bigint, 0, 0),
  'promotion bypassed the backfill rate limit'
);
SELECT pg_temp.assert_true(
  otlet.set_task_backfill_state(
    (SELECT value::bigint FROM backfill_proof_context WHERE name = 'rate_backfill'),
    'canceled',
    'proof cancellation'
  ) = 'canceled',
  'backfill cancellation did not close the run'
);
SELECT pg_temp.assert_true(
  EXISTS (
    SELECT 1
    FROM otlet.jobs job
    WHERE job.backfill_id = (
      SELECT value::bigint FROM backfill_proof_context WHERE name = 'rate_backfill'
    )
      AND job.subject_id = 'a'
      AND NOT job.backfill_deferred
      AND job.status = 'queued'
  ),
  'backfill cancellation took ownership of a promoted job'
);
SELECT count(*)
FROM otlet.jobs job
CROSS JOIN LATERAL otlet.request_job_cancellation(job.id, 'rate proof cleanup') canceled
WHERE job.backfill_id = (
    SELECT value::bigint FROM backfill_proof_context WHERE name = 'rate_backfill'
  )
  AND job.subject_id = 'a'
  AND job.status = 'queued'
\g /dev/null

INSERT INTO backfill_proof_context
SELECT 'draining_backfill', otlet.create_task_backfill(
  'bounded_backfill_a_task',
  (SELECT value FROM backfill_proof_context WHERE name = 'task_revision'),
  5,
  1,
  8,
  8
)::text;
INSERT INTO backfill_proof_rpc
SELECT 'draining_page', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'draining_backfill'),
  0
) page;
INSERT INTO backfill_proof_claims
SELECT job.id, job.task_name, job.subject_id, job.claim_token, job.backfill_deferred
FROM otlet.claim_jobs(:'model_name', 1) job;
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1 AND bool_and(backfill_deferred)
   FROM backfill_proof_claims),
  'cancellation-drain proof did not claim its deferred job'
);
SELECT pg_temp.assert_true(
  otlet.set_task_backfill_state(
    (SELECT value::bigint FROM backfill_proof_context WHERE name = 'draining_backfill'),
    'canceled',
    'draining proof cancellation'
  ) = 'canceled',
  'backfill cancellation did not close its run'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1
   FROM otlet.jobs job
   JOIN backfill_proof_claims claimed ON claimed.job_id = job.id
   WHERE job.status = 'cancel_requested'),
  'backfill cancellation did not retain its leased drain'
);
SELECT pg_temp.expect_error(
  format(
    'SELECT otlet.create_task_backfill(%L, %L, 5, 1, 8, 8)',
    'bounded_backfill_a_task',
    (SELECT value FROM backfill_proof_context WHERE name = 'task_revision')
  ),
  'already has an unfinished backfill'
);
SELECT pg_temp.assert_true(
  (SELECT count(*)
   FROM backfill_proof_claims claimed
   CROSS JOIN LATERAL otlet.cancel_job(
     claimed.job_id,
     claimed.claim_token,
     'draining proof cleanup'
   )) = 1,
  'cancellation-drain proof did not finish its lease'
);
TRUNCATE backfill_proof_claims;

INSERT INTO backfill_proof_context
SELECT
  'main_backfill',
  otlet.create_task_backfill(
    'bounded_backfill_a_task',
    (SELECT value FROM backfill_proof_context WHERE name = 'task_revision'),
    5,
    2,
    64,
    2
  )::text;
SELECT pg_temp.assert_true(
  (SELECT string_agg(subject.subject_id, ',' ORDER BY subject.ordinal)
   FROM otlet.task_backfill_subjects subject
   WHERE subject.backfill_id = (
     SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'
   )) = 'a,b,c,d,e'
  AND (SELECT backfill.subject_count = 5
            AND backfill.subject_manifest_hash =
              otlet.task_backfill_manifest_hash(backfill.id)
       FROM otlet.task_backfills backfill
       WHERE backfill.id = (
         SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'
       )),
  'backfill subject manifest was not deterministic'
);
INSERT INTO backfill_proof_rpc
SELECT 'main_first', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'),
  0
) page;
SELECT pg_temp.assert_true(
  (SELECT (submission_state, current_generation, processed_subjects, queued_jobs)
   FROM backfill_proof_rpc WHERE name = 'main_first') =
    ('submitted'::text, 1::bigint, 2, 2),
  'main backfill first page was incorrect'
);
INSERT INTO backfill_proof_rpc
SELECT 'main_outstanding', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'),
  1
) page;
SELECT pg_temp.assert_true(
  (SELECT (submission_state, current_generation, processed_subjects, queued_jobs)
   FROM backfill_proof_rpc WHERE name = 'main_outstanding') =
    ('outstanding_limited'::text, 1::bigint, 0, 0),
  'outstanding backfill jobs did not block another page'
);
SELECT pg_temp.assert_true(
  otlet.set_task_backfill_state(
    (SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'),
    'paused',
    'proof pause'
  ) = 'paused',
  'backfill pause failed'
);
INSERT INTO backfill_proof_rpc
SELECT 'main_paused', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'),
  2
) page;
SELECT pg_temp.assert_true(
  (SELECT (submission_state, current_generation, processed_subjects, queued_jobs)
   FROM backfill_proof_rpc WHERE name = 'main_paused') =
    ('paused'::text, 2::bigint, 0, 0),
  'paused backfill admitted a page'
);
SELECT pg_temp.assert_true(
  otlet.set_task_backfill_state(
    (SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'),
    'running'
  ) = 'running',
  'backfill resume failed'
);
INSERT INTO backfill_proof_rpc
SELECT 'main_stale', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'),
  1
) page;
SELECT pg_temp.assert_true(
  (SELECT (submission_state, current_generation, processed_subjects, queued_jobs)
   FROM backfill_proof_rpc WHERE name = 'main_stale') =
    ('stale_generation'::text, 3::bigint, 0, 0),
  'pause and resume did not fence an old page token'
);

SELECT pg_temp.assert_true(
  otlet.run_task_subject(
    'bounded_backfill_a_task',
    'a',
    (SELECT value FROM backfill_proof_context WHERE name = 'task_revision')
  ) = 0,
  'interactive promotion inserted a duplicate job'
);
SELECT pg_temp.assert_true(
  otlet.reconcile_watch_subject('bounded_backfill_a', 'a', true) = 'active_job',
  'interactive promotion reconciliation failed'
);
SELECT otlet.record_watch_input_reconciliation(
  'bounded_backfill_a_task',
  (SELECT value FROM backfill_proof_context WHERE name = 'task_revision'),
  'b',
  otlet.current_task_subject_input_snapshot(
    'bounded_backfill_a_task',
    'b',
    (SELECT value FROM backfill_proof_context WHERE name = 'task_revision')
  )
) \g /dev/null
SELECT pg_temp.assert_true(
  otlet.reconcile_watch_subject('bounded_backfill_a', 'b', true) = 'active_job',
  'catch-up work did not adopt the active backfill job'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) = 2
     AND bool_and(NOT job.backfill_deferred)
   FROM otlet.jobs job
   WHERE job.backfill_id = (
     SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'
   )
     AND job.subject_id IN ('a', 'b'))
  AND (SELECT count(*) = 2
       FROM otlet.task_backfill_subjects subject
       WHERE subject.backfill_id = (
         SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'
       )
         AND subject.subject_id IN ('a', 'b')
         AND subject.disposition = 'covered'),
  'foreground promotion lost lineage or priority state'
);

INSERT INTO public.otlet_bounded_backfill_source VALUES ('late', 'v1');
SELECT pg_temp.assert_true(
  otlet.run_task_subject(
    'bounded_backfill_a_task',
    'late',
    (SELECT value FROM backfill_proof_context WHERE name = 'task_revision')
  ) = 1,
  'late foreground subject was not admitted'
);
UPDATE public.otlet_bounded_backfill_source SET payload = 'v2' WHERE id = 'c';
DELETE FROM public.otlet_bounded_backfill_source WHERE id = 'd';
INSERT INTO backfill_proof_rpc
SELECT 'main_second', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'),
  3
) page;
SELECT pg_temp.assert_true(
  (SELECT (submission_state, current_generation, processed_subjects, queued_jobs)
   FROM backfill_proof_rpc WHERE name = 'main_second') =
    ('submitted'::text, 4::bigint, 2, 1),
  'latest-source page did not update and delete deterministically'
);
SELECT pg_temp.assert_true(
  otlet.reconcile_watch_subject('bounded_backfill_a', 'c', true) = 'active_job'
  AND otlet.reconcile_watch_subject('bounded_backfill_a', 'd', true) = 'source_deleted',
  'source catch-up did not promote or resolve the page'
);
INSERT INTO backfill_proof_rpc
SELECT 'main_final', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'),
  4
) page;
SELECT pg_temp.assert_true(
  (SELECT (submission_state, current_generation, processed_subjects, queued_jobs)
   FROM backfill_proof_rpc WHERE name = 'main_final') =
    ('submission_complete'::text, 5::bigint, 1, 1),
  'main backfill final page was incorrect'
);

CREATE TABLE public.otlet_bounded_backfill_pair_source (
  subject_id text PRIMARY KEY,
  input jsonb NOT NULL
);
INSERT INTO public.otlet_bounded_backfill_pair_source VALUES
  ('pair-a', '{"left":"a","right":"b"}'::jsonb),
  ('pair-b', '{"left":"c","right":"d"}'::jsonb);
SELECT otlet.create_watch(
  watch_name => 'bounded_backfill_pair',
  kind => 'pair',
  instruction => 'Return the decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  candidate_query => 'SELECT subject_id, input FROM public.otlet_bounded_backfill_pair_source',
  record_type => 'bounded_backfill_pair',
  input_shaping => '{"source_fields":["left","right"]}'::jsonb,
  stale_policy => 'lookup_only_fail_closed',
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  max_candidate_rows => 4,
  pair_sources => '[{"table":"public.otlet_bounded_backfill_pair_source","subject_column":"subject_id"}]'::jsonb
) \g /dev/null
INSERT INTO backfill_proof_context
SELECT 'pair_revision', head.active_workload_revision_hash
FROM otlet.workload_revision_heads head
WHERE head.task_name = 'bounded_backfill_pair_task';
INSERT INTO backfill_proof_context
SELECT 'pair_backfill', otlet.create_task_backfill(
  'bounded_backfill_pair_task',
  (SELECT value FROM backfill_proof_context WHERE name = 'pair_revision'),
  2,
  2,
  8,
  8
)::text;
UPDATE public.otlet_bounded_backfill_pair_source
SET input = '{"left":"a","right":"changed"}'::jsonb
WHERE subject_id = 'pair-a';
DELETE FROM public.otlet_bounded_backfill_pair_source
WHERE subject_id = 'pair-b';
INSERT INTO backfill_proof_rpc
SELECT 'pair_page', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'pair_backfill'),
  0
) page;
SELECT pg_temp.assert_true(
  (SELECT (submission_state, current_generation, processed_subjects, queued_jobs)
   FROM backfill_proof_rpc WHERE name = 'pair_page') =
    ('submission_complete'::text, 1::bigint, 2, 1)
  AND (SELECT changed_source_subjects = 1 AND source_missing_subjects = 1
       FROM otlet.task_backfill_status
       WHERE backfill_id = (
         SELECT value::bigint FROM backfill_proof_context WHERE name = 'pair_backfill'
       ))
  AND EXISTS (
    SELECT 1
    FROM otlet.jobs job
    WHERE job.backfill_id = (
      SELECT value::bigint FROM backfill_proof_context WHERE name = 'pair_backfill'
    )
      AND job.subject_id = 'pair-a'
      AND job.input #>> '{right}' = 'changed'
  ),
  'pair page did not use the latest bounded candidate set'
);
SELECT pg_temp.assert_true(
  otlet.set_task_backfill_state(
    (SELECT value::bigint FROM backfill_proof_context WHERE name = 'pair_backfill'),
    'canceled',
    'pair proof cleanup'
  ) = 'canceled',
  'pair backfill cleanup failed'
);

SELECT otlet.create_task(
  'bounded_backfill_z',
  'SELECT ''z''::text AS subject_id, ''{"value":"z"}''::jsonb AS input',
  'Return the decision',
  '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  :'model_name',
  '{}'::jsonb,
  '{"source_fields":["value"]}'::jsonb
) \g /dev/null
INSERT INTO backfill_proof_context
SELECT 'z_revision', otlet.ensure_active_workload_revision('bounded_backfill_z');
SELECT pg_temp.assert_true(
  otlet.run_task_subject(
    'bounded_backfill_z',
    'z',
    (SELECT value FROM backfill_proof_context WHERE name = 'z_revision')
  ) = 1,
  'cross-task foreground subject was not admitted'
);
UPDATE otlet.production_policy
SET worker_claim_task_cursor = ''
WHERE name = 'default';
INSERT INTO backfill_proof_claims
SELECT job.id, job.task_name, job.subject_id, job.claim_token, job.backfill_deferred
FROM otlet.claim_jobs(:'model_name', 8) job;
SELECT pg_temp.assert_true(
  (SELECT count(*) = 5 AND bool_and(NOT backfill_deferred)
   FROM backfill_proof_claims)
  AND EXISTS (
    SELECT 1 FROM backfill_proof_claims
    WHERE task_name = 'bounded_backfill_z' AND subject_id = 'z'
  )
  AND NOT EXISTS (
    SELECT 1 FROM backfill_proof_claims WHERE subject_id = 'e'
  ),
  'foreground jobs did not stay ahead of backfill jobs globally'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM backfill_proof_claims claimed
   CROSS JOIN LATERAL otlet.cancel_job(
     claimed.job_id,
     claimed.claim_token,
     'foreground proof cleanup'
   )) = 5,
  'foreground proof jobs did not cancel'
);
TRUNCATE backfill_proof_claims;
UPDATE otlet.production_policy
SET worker_claim_task_cursor = ''
WHERE name = 'default';
INSERT INTO backfill_proof_claims
SELECT job.id, job.task_name, job.subject_id, job.claim_token, job.backfill_deferred
FROM otlet.claim_jobs(:'model_name', 8) job;
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1
       AND bool_and(backfill_deferred)
       AND min(subject_id) = 'e'
   FROM backfill_proof_claims),
  'backfill claim quantum was not one job'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM backfill_proof_claims claimed
   CROSS JOIN LATERAL otlet.cancel_job(
     claimed.job_id,
     claimed.claim_token,
     'backfill proof cleanup'
   )) = 1,
  'backfill proof job did not cancel'
);

SELECT otlet.create_task(
  'bounded_backfill_pause',
  'SELECT ''pause''::text AS subject_id, ''{"value":"pause"}''::jsonb AS input',
  'Return the decision',
  '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  :'model_name',
  '{}'::jsonb,
  '{"source_fields":["value"]}'::jsonb
) \g /dev/null
INSERT INTO backfill_proof_context
SELECT 'pause_revision', otlet.ensure_active_workload_revision('bounded_backfill_pause');
INSERT INTO backfill_proof_context
SELECT 'pause_backfill', otlet.create_task_backfill(
  'bounded_backfill_pause',
  (SELECT value FROM backfill_proof_context WHERE name = 'pause_revision'),
  1,
  1,
  8,
  8
)::text;
SELECT otlet.set_task_lifecycle(
  'bounded_backfill_pause',
  'paused',
  (SELECT value FROM backfill_proof_context WHERE name = 'pause_revision')
) \g /dev/null
INSERT INTO backfill_proof_rpc
SELECT 'task_paused', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'pause_backfill'),
  0
) page;
SELECT pg_temp.assert_true(
  (SELECT submission_state = 'task_paused' AND current_generation = 0
   FROM backfill_proof_rpc WHERE name = 'task_paused')
  AND (SELECT state = 'task_paused' AND revision_current
       FROM otlet.task_backfill_status
       WHERE backfill_id = (
         SELECT value::bigint FROM backfill_proof_context WHERE name = 'pause_backfill'
       )),
  'task pause superseded a same-revision backfill'
);
SELECT pg_temp.assert_true(
  otlet.set_task_backfill_state(
    (SELECT value::bigint FROM backfill_proof_context WHERE name = 'pause_backfill'),
    'paused'
  ) = 'paused'
  AND otlet.set_task_backfill_state(
    (SELECT value::bigint FROM backfill_proof_context WHERE name = 'pause_backfill'),
    'running'
  ) = 'task_paused',
  'backfill control ignored the task pause'
);
SELECT otlet.set_task_lifecycle(
  'bounded_backfill_pause',
  'active',
  (SELECT value FROM backfill_proof_context WHERE name = 'pause_revision')
) \g /dev/null
SELECT pg_temp.assert_true(
  otlet.set_task_backfill_state(
    (SELECT value::bigint FROM backfill_proof_context WHERE name = 'pause_backfill'),
    'running'
  ) = 'running'
  AND otlet.set_task_backfill_state(
    (SELECT value::bigint FROM backfill_proof_context WHERE name = 'pause_backfill'),
    'canceled',
    'pause proof cleanup'
  ) = 'canceled',
  'same-revision task resume did not preserve the backfill'
);

CREATE TABLE public.otlet_bounded_backfill_generic_source (
  subject_id text PRIMARY KEY,
  input jsonb NOT NULL
);
INSERT INTO public.otlet_bounded_backfill_generic_source VALUES
  ('revision-b', '{"value":"b"}'::jsonb),
  ('revision-a', '{"value":"a"}'::jsonb);
SELECT otlet.create_task(
  task_name => 'bounded_backfill_revision',
  input_query => 'SELECT subject_id, input FROM public.otlet_bounded_backfill_generic_source ORDER BY subject_id DESC',
  instruction => 'Return revision A',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  input_shaping => '{"source_fields":["value"]}'::jsonb,
  source_relations => '[{"table":"public.otlet_bounded_backfill_generic_source"}]'::jsonb
) \g /dev/null
INSERT INTO backfill_proof_context
SELECT 'revision_a', otlet.ensure_active_workload_revision('bounded_backfill_revision');
INSERT INTO backfill_proof_context
SELECT 'historical_backfill', otlet.create_task_backfill(
  'bounded_backfill_revision',
  (SELECT value FROM backfill_proof_context WHERE name = 'revision_a'),
  2,
  2,
  8,
  8
)::text;
UPDATE public.otlet_bounded_backfill_generic_source
SET input = '{"value":"changed"}'::jsonb
WHERE subject_id = 'revision-b';
INSERT INTO public.otlet_bounded_backfill_generic_source
VALUES ('revision-late', '{"value":"late"}'::jsonb);
INSERT INTO backfill_proof_rpc
SELECT 'historical_page', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'historical_backfill'),
  0
) page;
SELECT pg_temp.assert_true(
  (SELECT (submission_state, current_generation, processed_subjects, queued_jobs)
   FROM backfill_proof_rpc WHERE name = 'historical_page') =
    ('submission_complete'::text, 1::bigint, 2, 2)
  AND EXISTS (
    SELECT 1
    FROM otlet.jobs job
    WHERE job.backfill_id = (
      SELECT value::bigint FROM backfill_proof_context WHERE name = 'historical_backfill'
    )
      AND job.subject_id = 'revision-b'
      AND job.input = '{"value":"changed"}'::jsonb
  )
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.task_backfill_subjects subject
    WHERE subject.backfill_id = (
      SELECT value::bigint FROM backfill_proof_context WHERE name = 'historical_backfill'
    )
      AND subject.subject_id = 'revision-late'
  )
  AND (SELECT changed_source_subjects = 1
       FROM otlet.task_backfill_status
       WHERE backfill_id = (
         SELECT value::bigint FROM backfill_proof_context WHERE name = 'historical_backfill'
       )),
  'generic page did not use its fixed manifest and latest source input'
);
SELECT count(*)
FROM otlet.jobs job
CROSS JOIN LATERAL otlet.request_job_cancellation(job.id, 'historical proof cleanup') canceled
WHERE job.backfill_id = (
  SELECT value::bigint FROM backfill_proof_context WHERE name = 'historical_backfill'
)
\g /dev/null
DELETE FROM public.otlet_bounded_backfill_generic_source
WHERE subject_id = 'revision-late';
INSERT INTO backfill_proof_context
SELECT 'pending_revision_backfill', otlet.create_task_backfill(
  'bounded_backfill_revision',
  (SELECT value FROM backfill_proof_context WHERE name = 'revision_a'),
  2,
  2,
  8,
  8
)::text;
SELECT otlet.create_task(
  task_name => 'bounded_backfill_revision',
  input_query => 'SELECT subject_id, input FROM public.otlet_bounded_backfill_generic_source ORDER BY subject_id DESC',
  instruction => 'Return revision B',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  input_shaping => '{"source_fields":["value"]}'::jsonb,
  source_relations => '[{"table":"public.otlet_bounded_backfill_generic_source"}]'::jsonb
) \g /dev/null
INSERT INTO backfill_proof_context
SELECT 'revision_b', otlet.capture_workload_revision('bounded_backfill_revision');
SELECT otlet.promote_workload_revision(
  'bounded_backfill_revision',
  (SELECT value FROM backfill_proof_context WHERE name = 'revision_b'),
  (SELECT value FROM backfill_proof_context WHERE name = 'revision_a')
) \g /dev/null
INSERT INTO backfill_proof_rpc
SELECT 'historical_after_revision', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'historical_backfill'),
  1
) page;
INSERT INTO backfill_proof_rpc
SELECT 'revision_superseded', page.*
FROM otlet.submit_task_backfill_page(
  (SELECT value::bigint FROM backfill_proof_context WHERE name = 'pending_revision_backfill'),
  0
) page;
SELECT pg_temp.assert_true(
  (SELECT state = 'complete' AND NOT revision_current
   FROM otlet.task_backfill_status
   WHERE backfill_id = (
     SELECT value::bigint FROM backfill_proof_context WHERE name = 'historical_backfill'
   ))
  AND (SELECT submission_state = 'submission_complete'
       FROM backfill_proof_rpc WHERE name = 'historical_after_revision')
  AND (SELECT submission_state = 'superseded' AND current_generation = 1
       FROM backfill_proof_rpc WHERE name = 'revision_superseded')
  AND otlet.set_task_backfill_state(
    (SELECT value::bigint FROM backfill_proof_context WHERE name = 'pending_revision_backfill'),
    'canceled'
  ) = 'superseded',
  'revision fencing changed completed history or left pending work open'
);

SELECT pg_temp.assert_true(
  (SELECT state = 'complete'
       AND control_state = 'running'
       AND generation = 5
       AND subject_count = 5
       AND processed_subjects = 5
       AND pending_subjects = 0
       AND submitted_subjects = 1
       AND covered_subjects = 3
       AND source_missing_subjects = 1
       AND changed_source_subjects = 1
       AND jobs = 4
       AND outstanding_jobs = 0
       AND canceled_jobs_count = 4
   FROM otlet.task_backfill_status
   WHERE backfill_id = (
     SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'
   ))
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.task_backfill_subjects subject
    WHERE subject.backfill_id = (
      SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'
    )
      AND subject.subject_id = 'late'
  )
  AND EXISTS (
    SELECT 1
    FROM otlet.jobs job
    WHERE job.backfill_id = (
      SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'
    )
      AND job.subject_id = 'c'
      AND job.input #>> '{row,payload}' = 'v2'
  ),
  'final backfill progress or latest-source state was incorrect'
);
SELECT pg_temp.assert_true(
  NOT pg_catalog.has_table_privilege('public', 'otlet.task_backfills', 'SELECT')
  AND NOT pg_catalog.has_table_privilege('public', 'otlet.task_backfill_subjects', 'SELECT')
  AND NOT pg_catalog.has_table_privilege('public', 'otlet.task_backfill_status', 'SELECT')
  AND NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.create_task_backfill(text,text,integer,integer,integer,integer)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.submit_task_backfill_page(bigint,bigint)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.set_task_backfill_state(bigint,text,text)',
    'EXECUTE'
  ),
  'backfill objects were exposed to public'
);

SELECT 'backfill_invariant=' || to_jsonb(invariant)::text
FROM otlet.verify_invariants() invariant;

SELECT concat_ws('|',
  NOT EXISTS (
    SELECT 1 FROM otlet.task_backfills
    WHERE task_name = 'bounded_backfill_a_task'
      AND id < (SELECT value::bigint FROM backfill_proof_context WHERE name = 'rate_backfill')
  ),
  (SELECT control_state = 'canceled' AND generation = 2
   FROM otlet.task_backfills
   WHERE id = (SELECT value::bigint FROM backfill_proof_context WHERE name = 'rate_backfill')),
  (SELECT subject_manifest_hash = otlet.task_backfill_manifest_hash(id)
   FROM otlet.task_backfills
   WHERE id = (SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill')),
  (SELECT submission_state = 'stale_generation'
   FROM backfill_proof_rpc WHERE name = 'main_stale'),
  (SELECT count(*) = 3 AND bool_and(NOT job.backfill_deferred)
   FROM otlet.jobs job
   WHERE job.backfill_id = (
     SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'
   )
     AND job.subject_id IN ('a', 'b', 'c')),
  (SELECT count(*) = 1 AND bool_and(backfill_deferred)
   FROM backfill_proof_claims),
  (SELECT changed_source_subjects = 1 AND source_missing_subjects = 1
   FROM otlet.task_backfill_status
   WHERE backfill_id = (
     SELECT value::bigint FROM backfill_proof_context WHERE name = 'main_backfill'
   )),
  (SELECT control_state = 'canceled' AND generation = 3
   FROM otlet.task_backfills
   WHERE id = (SELECT value::bigint FROM backfill_proof_context WHERE name = 'pause_backfill')),
  (SELECT state = 'superseded'
   FROM otlet.task_backfill_status
   WHERE backfill_id = (
     SELECT value::bigint FROM backfill_proof_context WHERE name = 'pending_revision_backfill'
   )),
  NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.submit_task_backfill_page(bigint,bigint)',
    'EXECUTE'
  ),
  (SELECT count(*) FROM otlet.verify_invariants())
);
ROLLBACK;
SQL
then
  rm -f "$minimal_bounded_backfill_output"
  exit 1
fi

minimal_bounded_backfill_contract="$(tail -n 1 "$minimal_bounded_backfill_output")"

echo "minimal_bounded_backfill_contract=$minimal_bounded_backfill_contract"
[ "$minimal_bounded_backfill_contract" = "t|t|t|t|t|t|t|t|t|t|0" ] || {
  sed -n '/^backfill_invariant=/p' "$minimal_bounded_backfill_output" >&2
  rm -f "$minimal_bounded_backfill_output"
  echo "Expected minimal bounded backfill contract, got $minimal_bounded_backfill_contract" >&2
  exit 1
}
rm -f "$minimal_bounded_backfill_output"
