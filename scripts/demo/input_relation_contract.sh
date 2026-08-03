log "Proving deterministic input relations"

input_relation_contract="$(psql_candidate_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
SET LOCAL statement_timeout = '2000ms';

CREATE TEMP TABLE input_relation_config AS
SELECT :'model_name'::text AS model_name;

CREATE FUNCTION pg_temp.assert_true(condition boolean, failure text) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
  IF assert_true.condition IS NOT TRUE THEN
    RAISE EXCEPTION '%', assert_true.failure;
  END IF;
END
$body$;

CREATE FUNCTION pg_temp.expect_error(statement text, message_fragment text) RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
  BEGIN
    EXECUTE expect_error.statement;
  EXCEPTION WHEN OTHERS THEN
    IF position(expect_error.message_fragment IN SQLERRM) = 0 THEN
      RAISE EXCEPTION 'expected error containing %, got %',
        expect_error.message_fragment,
        SQLERRM;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'expected error containing %, but statement succeeded',
    expect_error.message_fragment;
END
$body$;

CREATE TABLE public.otlet_input_relation_demo (
  row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subject_id text,
  input jsonb
);

INSERT INTO public.otlet_input_relation_demo (subject_id, input)
VALUES
  ('b', '{"value":2}'),
  ('a', '{"value":1}'),
  ('c', '{"value":3}');

SELECT otlet.create_task(
  task_name => 'input_relation_demo',
  input_query => $query$
    SELECT subject_id, input
    FROM public.otlet_input_relation_demo
    ORDER BY row_id DESC
  $query$,
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => (SELECT model_name FROM input_relation_config),
  input_shaping => '{"source_fields":["a","b","value"]}'::jsonb,
  source_relations => '[{"table":"public.otlet_input_relation_demo"}]'::jsonb
) \g /dev/null

SELECT pg_temp.assert_true(
  otlet.run_task('input_relation_demo') = 3,
  'valid input relation did not queue three jobs'
) \g /dev/null

SELECT pg_temp.assert_true(
  (
    SELECT string_agg(subject_id, ',' ORDER BY id)
    FROM otlet.jobs
    WHERE task_name = 'input_relation_demo'
  ) = 'a,b,c',
  'valid input relation was not admitted in C-collated subject order'
) \g /dev/null

SELECT pg_temp.assert_true(
  (
    SELECT revision.definition #> '{task,input_relation}'
    FROM otlet.workload_revision_heads head
    JOIN otlet.workload_revisions revision
      ON revision.task_name = head.task_name
     AND revision.workload_revision_hash = head.active_workload_revision_hash
    WHERE head.task_name = 'input_relation_demo'
  ) = '{
    "version":"otlet_input_relation_v1",
    "subject_id":"non_null_unique_text",
    "input":"one_non_null_jsonb_per_subject",
    "order":"subject_id_collate_c_asc"
  }'::jsonb,
  'workload revision omitted the input relation contract'
) \g /dev/null

DELETE FROM otlet.jobs WHERE task_name = 'input_relation_demo';
DELETE FROM public.otlet_input_relation_demo;

INSERT INTO public.otlet_input_relation_demo (subject_id, input)
VALUES (NULL, '{}');
SELECT pg_temp.expect_error(
  $$SELECT otlet.run_task('input_relation_demo')$$,
  'input relation produced null subject_id'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT 1 FROM otlet.jobs WHERE task_name = 'input_relation_demo'),
  'null subject admission was not atomic'
) \g /dev/null
DELETE FROM public.otlet_input_relation_demo;

INSERT INTO public.otlet_input_relation_demo (subject_id, input)
VALUES ('null-input', NULL);
SELECT pg_temp.expect_error(
  $$SELECT otlet.run_task('input_relation_demo')$$,
  'input relation produced null input'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT 1 FROM otlet.jobs WHERE task_name = 'input_relation_demo'),
  'null input admission was not atomic'
) \g /dev/null
DELETE FROM public.otlet_input_relation_demo;

INSERT INTO public.otlet_input_relation_demo (subject_id, input)
VALUES
  ('duplicate', '{"b":2,"a":1.0}'),
  ('duplicate', '{"a":1,"b":2}');
SELECT pg_temp.expect_error(
  $$SELECT otlet.run_task('input_relation_demo')$$,
  'input relation produced duplicate subject_id duplicate'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT 1 FROM otlet.jobs WHERE task_name = 'input_relation_demo'),
  'canonical duplicate admission was not atomic'
) \g /dev/null
DELETE FROM public.otlet_input_relation_demo;

INSERT INTO public.otlet_input_relation_demo (subject_id, input)
VALUES
  ('conflict', '{"value":1}'),
  ('conflict', '{"value":2}'),
  ('valid', '{}');
SELECT pg_temp.expect_error(
  $$SELECT otlet.run_task('input_relation_demo')$$,
  'input relation produced conflicting inputs for subject conflict'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$SELECT otlet.run_task_subject('input_relation_demo', 'valid')$$,
  'input relation produced conflicting inputs for subject conflict'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT 1 FROM otlet.jobs WHERE task_name = 'input_relation_demo'),
  'conflicting duplicate admission was not atomic'
) \g /dev/null
DELETE FROM public.otlet_input_relation_demo;

INSERT INTO public.otlet_input_relation_demo (subject_id, input)
VALUES ('active', '{"value":1}');
SELECT pg_temp.assert_true(
  otlet.run_task('input_relation_demo') = 1,
  'active input fixture did not queue'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT otlet.admit_task_input('input_relation_demo', 'active', '{"value":1}'::jsonb),
  'same active input was not idempotent'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$SELECT otlet.admit_task_input('input_relation_demo', 'active', '{"value":2}'::jsonb)$$,
  'input relation conflicts with active input for subject active'
) \g /dev/null
UPDATE public.otlet_input_relation_demo
SET input = '{"value":2}'
WHERE subject_id = 'active';
SELECT pg_temp.expect_error(
  $$SELECT otlet.run_task('input_relation_demo')$$,
  'input relation conflicts with active input for subject active'
) \g /dev/null
SELECT pg_temp.assert_true(
  (
    SELECT count(*) = 1 AND bool_and(input = '{"value":1}'::jsonb)
    FROM otlet.jobs
    WHERE task_name = 'input_relation_demo'
  ),
  'active input conflict changed the queued job'
) \g /dev/null
DELETE FROM otlet.jobs WHERE task_name = 'input_relation_demo';
DELETE FROM public.otlet_input_relation_demo;

INSERT INTO public.otlet_input_relation_demo (subject_id, input)
VALUES ('requested', '{}');
SELECT pg_temp.expect_error(
  $$SELECT * FROM otlet.run_task_subjects('input_relation_demo', ARRAY['requested', NULL])$$,
  'input relation produced null subject_id'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$SELECT * FROM otlet.run_task_subjects('input_relation_demo', ARRAY['requested', 'requested'])$$,
  'input relation produced duplicate requested subject_id'
) \g /dev/null
DELETE FROM public.otlet_input_relation_demo;

CREATE TABLE public.otlet_input_relation_row_demo (
  subject_id text,
  payload text NOT NULL
);

SELECT pg_temp.expect_error(
  $$
    SELECT otlet.create_watch(
      watch_name => 'input_relation_row_demo',
      kind => 'row',
      instruction => 'Return an empty object',
      output_schema => '{"type":"object"}'::jsonb,
      model_name => (SELECT model_name FROM pg_temp.input_relation_config),
      table_name => 'public.otlet_input_relation_row_demo'::regclass,
      subject_column => 'subject_id'
    )
  $$,
  'must be NOT NULL with an immediate unique key'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT 1 FROM otlet.watches WHERE name = 'input_relation_row_demo')
  AND NOT EXISTS (SELECT 1 FROM otlet.tasks WHERE name = 'input_relation_row_demo_task')
  AND NOT EXISTS (SELECT 1 FROM otlet.semantic_indexes WHERE name = 'input_relation_row_demo')
  AND NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.otlet_input_relation_row_demo'::regclass
      AND NOT tgisinternal
  ),
  'nullable row watch rejection left partial state'
) \g /dev/null

ALTER TABLE public.otlet_input_relation_row_demo
ALTER COLUMN subject_id SET NOT NULL;
SELECT pg_temp.expect_error(
  $$
    SELECT otlet.create_watch(
      watch_name => 'input_relation_row_demo',
      kind => 'row',
      instruction => 'Return an empty object',
      output_schema => '{"type":"object"}'::jsonb,
      model_name => (SELECT model_name FROM pg_temp.input_relation_config),
      table_name => 'public.otlet_input_relation_row_demo'::regclass,
      subject_column => 'subject_id'
    )
  $$,
  'must be NOT NULL with an immediate unique key'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT 1 FROM otlet.watches WHERE name = 'input_relation_row_demo')
  AND NOT EXISTS (SELECT 1 FROM otlet.tasks WHERE name = 'input_relation_row_demo_task')
  AND NOT EXISTS (SELECT 1 FROM otlet.semantic_indexes WHERE name = 'input_relation_row_demo'),
  'non-unique row watch rejection left partial state'
) \g /dev/null

CREATE UNIQUE INDEX otlet_input_relation_row_subject_key
ON public.otlet_input_relation_row_demo (subject_id);
SELECT otlet.create_watch(
  watch_name => 'input_relation_row_demo',
  kind => 'row',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => (SELECT model_name FROM input_relation_config),
  table_name => 'public.otlet_input_relation_row_demo'::regclass,
  subject_column => 'subject_id'
) \g /dev/null
SELECT pg_temp.assert_true(
  EXISTS (SELECT 1 FROM otlet.watches WHERE name = 'input_relation_row_demo')
  AND EXISTS (SELECT 1 FROM otlet.tasks WHERE name = 'input_relation_row_demo_task')
  AND EXISTS (SELECT 1 FROM otlet.semantic_indexes WHERE name = 'input_relation_row_demo')
  AND EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.otlet_input_relation_row_demo'::regclass
      AND NOT tgisinternal
  ),
  'valid row watch did not create its task, index, and trigger'
) \g /dev/null

CREATE TABLE public.otlet_input_relation_pair_demo (
  row_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subject_id text NOT NULL,
  input jsonb NOT NULL
);
INSERT INTO public.otlet_input_relation_pair_demo (subject_id, input)
VALUES
  ('a', '{"value":1}'),
  ('a', '{"value":2}'),
  ('z', '{"value":3}');

SELECT otlet.create_watch(
  watch_name => 'input_relation_pair_demo',
  kind => 'pair',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => (SELECT model_name FROM input_relation_config),
  candidate_query => $query$
    SELECT subject_id, input
    FROM public.otlet_input_relation_pair_demo
    ORDER BY row_id DESC
  $query$,
  max_candidate_rows => 1,
  pair_sources => '[{
    "table":"public.otlet_input_relation_pair_demo",
    "subject_column":"row_id"
  }]'::jsonb
) \g /dev/null

CREATE TEMP TABLE input_relation_pair_revision AS
SELECT active_workload_revision_hash AS revision_hash
FROM otlet.workload_revision_heads
WHERE task_name = 'input_relation_pair_demo_task';

SELECT pg_temp.expect_error(
  $$SELECT otlet.refresh_semantic_join_index('input_relation_pair_demo')$$,
  'input relation produced conflicting inputs for subject a'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$SELECT otlet.semantic_join_matches('input_relation_pair_demo', 'a', '{}'::jsonb)$$,
  'input relation produced conflicting inputs for subject a'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$
    SELECT otlet.current_task_subject_content_hash(
      'input_relation_pair_demo_task',
      'a',
      (SELECT revision_hash FROM pg_temp.input_relation_pair_revision)
    )
  $$,
  'input relation produced conflicting inputs for subject a'
) \g /dev/null
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1 FROM otlet.jobs
    WHERE task_name = 'input_relation_pair_demo_task'
  )
  AND NOT EXISTS (
    SELECT 1 FROM otlet.semantic_materializations
    WHERE task_name = 'input_relation_pair_demo_task'
  ),
  'pair conflict changed jobs or materializations'
) \g /dev/null

DELETE FROM public.otlet_input_relation_pair_demo;
INSERT INTO public.otlet_input_relation_pair_demo (subject_id, input)
VALUES
  ('a', '{"value":1}'),
  ('b', '{"value":2}'),
  ('c', '{"value":3}');

WITH revision AS (
  SELECT revision.workload_revision_hash, revision.definition
  FROM otlet.workload_revisions revision
  JOIN input_relation_pair_revision selected
    ON selected.revision_hash = revision.workload_revision_hash
), seeded_record AS (
  INSERT INTO otlet.records (record_type, subject_id, body)
  SELECT definition #>> '{source,record_type}', 'b', '{"match":"seeded"}'::jsonb
  FROM revision
  RETURNING id
)
INSERT INTO otlet.semantic_materializations (
  record_id,
  record_type,
  subject_id,
  task_name,
  model_name,
  body,
  source_hash,
  content_hash,
  contract_hash,
  freshness_basis
)
SELECT
  seeded_record.id,
  revision.definition #>> '{source,record_type}',
  'b',
  'input_relation_pair_demo_task',
  (SELECT model_name FROM input_relation_config),
  '{"match":"seeded"}'::jsonb,
  otlet.semantic_source_hash('{"value":2}'::jsonb),
  otlet.semantic_content_hash(
    '{"value":2}'::jsonb,
    revision.definition #> '{task,input_shaping}'
  ),
  revision.workload_revision_hash,
  'content_hash_match'
FROM revision
CROSS JOIN seeded_record;

SELECT pg_temp.expect_error(
  $$SELECT * FROM otlet.semantic_join_refresh_inputs('input_relation_pair_demo')$$,
  'candidate query for semantic join index input_relation_pair_demo exceeds max_candidate_rows 1'
) \g /dev/null
SELECT pg_temp.expect_error(
  $$SELECT otlet.semantic_join_matches(
    'input_relation_pair_demo',
    'b',
    '{"match":"seeded"}'::jsonb
  )$$,
  'candidate query for semantic join index input_relation_pair_demo exceeds max_candidate_rows 1'
) \g /dev/null
SELECT pg_temp.assert_true(
  (
    SELECT NOT stale AND stale_reason IS NULL
    FROM otlet.semantic_materializations
    WHERE task_name = 'input_relation_pair_demo_task'
      AND subject_id = 'b'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.jobs
    WHERE task_name = 'input_relation_pair_demo_task'
  ),
  'candidate overflow changed jobs or unseen materialization state'
) \g /dev/null

DELETE FROM public.otlet_input_relation_pair_demo
WHERE subject_id <> 'b';
UPDATE otlet.tasks
SET instruction = 'Return an empty object after promotion'
WHERE name = 'input_relation_pair_demo_task';
SELECT otlet.promote_configured_workload_revision(
  'input_relation_pair_demo_task'
) \g /dev/null
SELECT pg_temp.assert_true(
  (SELECT active_workload_revision_hash
   FROM otlet.workload_revision_heads
   WHERE task_name = 'input_relation_pair_demo_task') <>
    (SELECT revision_hash FROM pg_temp.input_relation_pair_revision)
  AND otlet.current_task_subject_content_hash(
      'input_relation_pair_demo_task',
      'b',
      (SELECT revision_hash FROM pg_temp.input_relation_pair_revision)
    ) = otlet.semantic_content_hash(
      '{"value":2}'::jsonb,
      (SELECT revision.definition #> '{task,input_shaping}'
       FROM otlet.workload_revisions revision
       JOIN pg_temp.input_relation_pair_revision saved
         ON saved.revision_hash = revision.workload_revision_hash)
    ),
  'superseded pair revision could not read its candidate set'
) \g /dev/null

SELECT 'canonical_order|null_and_duplicates|active_conflict|row_unique_key|pair_overflow|pair_history';
ROLLBACK;
SQL
)"

echo "input_relation_contract=$input_relation_contract"
[ "$input_relation_contract" = "canonical_order|null_and_duplicates|active_conflict|row_unique_key|pair_overflow|pair_history" ] || {
  echo "Expected deterministic input relation contract, got $input_relation_contract" >&2
  exit 1
}

infer_now_task="input_relation_infer_now_demo"
cleanup_task "$infer_now_task"
psql_exec -qAt -v task_name="$infer_now_task" >/dev/null <<'SQL'
DELETE FROM otlet.workload_revision_heads WHERE task_name = :'task_name';
SQL

psql_exec -qAt -v task_name="$infer_now_task" -v model_name="$cheap_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  task_name => :'task_name',
  input_query => NULL,
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => :'model_name',
  input_shaping => '{"source_fields":["value"]}'::jsonb
) \g /dev/null

WITH revision AS (
  SELECT otlet.ensure_active_workload_revision(:'task_name') AS revision_hash
)
INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input,
  status,
  attempts,
  leased_until,
  claim_token,
  started_at
)
SELECT
  :'task_name',
  revision_hash,
  'active',
  '{"value":1}'::jsonb,
  'running',
  1,
  now() + interval '1 hour',
  gen_random_uuid()::text,
  now()
FROM revision;
SQL

set +e
infer_now_conflict_output="$(psql_exec -qAt -v task_name="$infer_now_task" 2>&1 <<'SQL'
SELECT otlet.worker_infer_now(
  :'task_name',
  'active',
  '{"value":2}'::jsonb,
  5000
);
SQL
)"
infer_now_conflict_exit=$?
set -e

infer_now_conflict_state="$(psql_value -v task_name="$infer_now_task" <<'SQL'
SELECT status || '|' || (input = '{"value":1}'::jsonb)::text || '|' ||
       count(*) OVER ()::text
FROM otlet.jobs
WHERE task_name = :'task_name';
SQL
)"

cleanup_task "$infer_now_task"
psql_exec -qAt -v task_name="$infer_now_task" >/dev/null <<'SQL'
DELETE FROM otlet.workload_revision_heads WHERE task_name = :'task_name';
SQL

if [ "$infer_now_conflict_exit" -eq 0 ] \
   || [[ "$infer_now_conflict_output" != *"input relation conflicts with active input for subject active"* ]] \
   || [ "$infer_now_conflict_state" != "running|true|1" ]; then
  echo "Native infer-now did not reject the active input conflict atomically" >&2
  printf '%s\n' "$infer_now_conflict_output" >&2
  echo "state=$infer_now_conflict_state" >&2
  exit 1
fi
echo "infer_now_input_conflict_contract=failed|$infer_now_conflict_state"
