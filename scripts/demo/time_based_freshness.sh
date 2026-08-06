log "Proving time-based freshness"

time_based_freshness_expect_customscan="${time_based_freshness_expect_customscan:-true}"
time_based_freshness_output="$(mktemp)"
if ! psql_exec -qAt \
  -v model_name="$cheap_model_name" \
  -v expect_customscan="$time_based_freshness_expect_customscan" \
  >"$time_based_freshness_output" <<'SQL'
BEGIN;
SELECT set_config(
  'otlet.time_freshness_expect_customscan',
  :'expect_customscan',
  true
) \g /dev/null

CREATE FUNCTION pg_temp.expect_error(statement text, message_fragment text)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    EXECUTE statement;
    RAISE EXCEPTION 'expected statement to fail: %', statement;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected statement to fail: ' || statement
       OR position(message_fragment IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;
END;
$function$;

CREATE TABLE public.otlet_time_freshness_row_source (
  id text PRIMARY KEY,
  payload text NOT NULL,
  note text
);
INSERT INTO public.otlet_time_freshness_row_source VALUES
  ('refresh-row', 'refresh', NULL),
  ('closed-row', 'closed', NULL),
  ('zero-row', 'zero', NULL),
  ('legacy-row', 'legacy', NULL),
  ('receipt-row', 'receipt', NULL),
  ('ack-row', 'ack', NULL),
  ('terminal-row', 'terminal', NULL),
  ('latest-row', 'latest', NULL),
  ('revalidated-row', 'revalidated', NULL),
  ('manual-row', 'manual', NULL),
  ('correction-row', 'correction', NULL),
  ('expired-correction-row', 'expired correction', NULL),
  ('collision-row', 'collision', NULL),
  ('backoff-row', 'backoff', NULL),
  ('paused-row', 'paused', NULL),
  ('revision-row', 'revision', NULL);

CREATE TABLE public.otlet_time_freshness_pair_source (
  subject_id text PRIMARY KEY,
  input jsonb NOT NULL
);
INSERT INTO public.otlet_time_freshness_pair_source
VALUES ('expired-pair', '{"left":"a","right":"b"}'::jsonb);

SELECT otlet.create_watch(
  watch_name => 'time_refresh_row',
  kind => 'row',
  instruction => 'Return the decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_time_freshness_row_source'::regclass,
  subject_column => 'id',
  input_columns => ARRAY['id', 'payload'],
  trigger_policy => '{"on_change":"mark_stale_and_enqueue","max_age_ms":600000,"refresh_window_ms":120000,"on_overdue":"reconcile"}'::jsonb
) \g /dev/null

SELECT otlet.create_watch(
  watch_name => 'time_closed_row',
  kind => 'row',
  instruction => 'Return the decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_time_freshness_row_source'::regclass,
  subject_column => 'id',
  input_columns => ARRAY['id', 'payload'],
  stale_policy => 'lookup_only_fail_closed',
  trigger_policy => '{"on_change":"mark_stale","max_age_ms":600000,"refresh_window_ms":120000,"on_overdue":"fail_closed"}'::jsonb
) \g /dev/null

SELECT otlet.create_watch(
  watch_name => 'time_legacy_row',
  kind => 'row',
  instruction => 'Return the decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_time_freshness_row_source'::regclass,
  subject_column => 'id',
  input_columns => ARRAY['id', 'payload']
) \g /dev/null

SELECT otlet.create_watch(
  watch_name => 'time_zero_row',
  kind => 'row',
  instruction => 'Return the decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_time_freshness_row_source'::regclass,
  subject_column => 'id',
  input_columns => ARRAY['id', 'payload'],
  stale_policy => 'lookup_only_fail_closed',
  trigger_policy => '{"on_change":"mark_stale","max_age_ms":600000,"refresh_window_ms":0,"on_overdue":"fail_closed"}'::jsonb
) \g /dev/null

SELECT otlet.create_watch(
  watch_name => 'time_refresh_pair',
  kind => 'pair',
  instruction => 'Return the decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  candidate_query => 'SELECT subject_id, input FROM public.otlet_time_freshness_pair_source',
  record_type => 'time_refresh_pair',
  input_shaping => '{"source_fields":["left","right"]}'::jsonb,
  stale_policy => 'lookup_only_fail_closed',
  trigger_policy => '{"on_change":"mark_stale","max_age_ms":600000,"refresh_window_ms":120000,"on_overdue":"fail_closed"}'::jsonb,
  max_candidate_rows => 10,
  pair_sources => '[{"table":"public.otlet_time_freshness_pair_source","subject_column":"subject_id"}]'::jsonb
) \g /dev/null

SELECT pg_temp.expect_error(
  $$UPDATE otlet.watches
    SET trigger_policy = '{"on_change":"mark_stale","unknown":1}'::jsonb
    WHERE name = 'time_refresh_row'$$,
  'unsupported key unknown'
);
SELECT pg_temp.expect_error(
  $$UPDATE otlet.watches
    SET trigger_policy = '{"on_change":"mark_stale","refresh_window_ms":1,"on_overdue":"reconcile"}'::jsonb
    WHERE name = 'time_refresh_row'$$,
  'require max_age_ms'
);
SELECT pg_temp.expect_error(
  $$UPDATE otlet.watches
    SET trigger_policy = '{"on_change":"mark_stale_and_enqueue","max_age_ms":10,"refresh_window_ms":10,"on_overdue":"reconcile"}'::jsonb
    WHERE name = 'time_refresh_row'$$,
  'must be less than max_age_ms'
);
SELECT pg_temp.expect_error(
  $$UPDATE otlet.watches
    SET trigger_policy = '{"on_change":"mark_stale_and_enqueue","max_age_ms":10,"refresh_window_ms":1,"on_overdue":"reconcile"}'::jsonb
    WHERE name = 'time_refresh_pair'$$,
  'supported only for row watches'
);

DO $proof$
DECLARE
  before_policy jsonb;
  after_policy jsonb;
  active_hash text;
BEGIN
  SELECT trigger_policy INTO STRICT before_policy
  FROM otlet.watches WHERE name = 'time_refresh_row';
  PERFORM pg_temp.expect_error(
    $$UPDATE otlet.watches
      SET trigger_policy = '{"on_change":"mark_stale","max_age_ms":600000,"refresh_window_ms":120000,"on_overdue":"reconcile"}'::jsonb
      WHERE name = 'time_refresh_row'$$,
    'requires on_change mark_stale_and_enqueue'
  );
  SELECT trigger_policy INTO STRICT after_policy
  FROM otlet.watches WHERE name = 'time_refresh_row';
  IF before_policy IS DISTINCT FROM after_policy THEN
    RAISE EXCEPTION 'invalid trigger policy mutation was not atomic';
  END IF;

  SELECT head.active_workload_revision_hash
  INTO STRICT active_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = 'time_refresh_row_task';
  IF active_hash IS DISTINCT FROM otlet.identity_hash(
       'workload_revision',
       otlet.current_workload_revision_definition('time_refresh_row_task')
     )
     OR (
       SELECT definition #> '{source,time_freshness}'
       FROM otlet.workload_revisions
       WHERE workload_revision_hash = active_hash
     ) IS DISTINCT FROM
       '{"max_age_ms":600000,"refresh_window_ms":120000,"on_overdue":"reconcile"}'::jsonb
     OR (
       SELECT definition #> '{source,time_freshness}' IS NOT NULL
       FROM otlet.workload_revisions revision
       JOIN otlet.workload_revision_heads head
         ON head.active_workload_revision_hash = revision.workload_revision_hash
       WHERE head.task_name = 'time_legacy_row_task'
     )
     OR otlet.export_watch('time_refresh_row') -> 'trigger_policy' IS DISTINCT FROM
       before_policy THEN
    RAISE EXCEPTION 'time policy revision or watch export contract is not exact';
  END IF;

  PERFORM otlet.import_watch(otlet.export_watch('time_refresh_row'), true);
  IF (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'time_refresh_row_task'
  ) IS DISTINCT FROM active_hash THEN
    RAISE EXCEPTION 'watch v1 round trip changed the timed workload revision';
  END IF;
END;
$proof$;

CREATE FUNCTION pg_temp.add_time_materialization(
  watch_name text,
  subject_id text,
  age interval,
  is_stale boolean DEFAULT false,
  stale_reason text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $function$
DECLARE
  fixture record;
  input jsonb;
  saved_record_id bigint;
  saved_materialization_id bigint;
BEGIN
  SELECT watch.*, revision.definition, revision.workload_revision_hash
  INTO STRICT fixture
  FROM otlet.watches watch
  JOIN otlet.workload_revision_heads head ON head.task_name = watch.task_name
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE watch.name = add_time_materialization.watch_name;

  IF fixture.kind = 'row' THEN
    input := otlet.semantic_row_subject_input(
      fixture.workload_revision_hash,
      add_time_materialization.subject_id
    );
  ELSE
    input := otlet.task_subject_input(
      fixture.definition #>> '{task,input_query}',
      add_time_materialization.subject_id,
      fixture.definition
    );
  END IF;
  IF input IS NULL THEN
    RAISE EXCEPTION 'time freshness fixture source % is missing',
      add_time_materialization.subject_id;
  END IF;

  INSERT INTO otlet.records (record_type, subject_id, body)
  VALUES (fixture.record_type, add_time_materialization.subject_id, '{"decision":"keep"}'::jsonb)
  RETURNING id INTO saved_record_id;

  INSERT INTO otlet.semantic_materializations (
    record_id,
    record_type,
    source_table,
    subject_id,
    source_dependencies,
    task_name,
    model_name,
    body,
    stale,
    source_hash,
    content_hash,
    contract_hash,
    stale_reason,
    freshness_basis,
    created_at,
    updated_at
  ) VALUES (
    saved_record_id,
    fixture.record_type,
    fixture.source_table,
    add_time_materialization.subject_id,
    otlet.semantic_input_dependencies(input),
    fixture.task_name,
    fixture.model_name,
    '{"decision":"keep"}'::jsonb,
    add_time_materialization.is_stale,
    otlet.semantic_source_hash(input),
    otlet.semantic_content_hash(input, fixture.definition #> '{task,input_shaping}'),
    fixture.workload_revision_hash,
    CASE WHEN add_time_materialization.is_stale
      THEN add_time_materialization.stale_reason
    END,
    CASE WHEN add_time_materialization.is_stale
      THEN NULL
      ELSE 'content_hash_match'
    END,
    statement_timestamp() - add_time_materialization.age,
    statement_timestamp() - add_time_materialization.age
  )
  RETURNING id INTO saved_materialization_id;
  RETURN saved_materialization_id;
END;
$function$;

CREATE FUNCTION pg_temp.add_time_correction(
  materialization_id bigint,
  age interval,
  expires_in interval DEFAULT interval '1 day'
) RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
  materialization otlet.semantic_materializations%ROWTYPE;
  revision_definition jsonb;
  correction otlet.semantic_correction_overrides%ROWTYPE;
BEGIN
  SELECT * INTO STRICT materialization
  FROM otlet.semantic_materializations
  WHERE id = add_time_correction.materialization_id;
  SELECT definition INTO STRICT revision_definition
  FROM otlet.workload_revisions
  WHERE task_name = materialization.task_name
    AND workload_revision_hash = materialization.contract_hash;

  correction.task_name := materialization.task_name;
  correction.subject_id := materialization.subject_id;
  correction.record_type := materialization.record_type;
  correction.workload_revision_hash := materialization.contract_hash;
  correction.relevant_contract_hash :=
    otlet.pair_constraint_contract_hash(revision_definition);
  correction.source_table := materialization.source_table;
  correction.source_hash := materialization.source_hash;
  correction.content_hash := materialization.content_hash;
  correction.materialization_id := materialization.id;
  correction.correction_label_id := 900000000000000000 + materialization.id;
  correction.review_event_id := 910000000000000000 + materialization.id;
  correction.original_action_id := 920000000000000000 + materialization.id;
  correction.original_output_id := 930000000000000000 + materialization.id;
  correction.original_receipt_id := 940000000000000000 + materialization.id;
  correction.original_body_hash := otlet.portable_json_hash(materialization.body);
  correction.original_output_hash := 'time-correction-output';
  correction.corrected_body := '{"decision":"corrected"}'::jsonb;
  correction.corrected_body_hash :=
    otlet.portable_json_hash(correction.corrected_body);
  correction.expected_answer := 'keep';
  correction.expected_confidence := 'high';
  correction.expected_action_type := 'none';
  correction.correction_author_identity := session_user;
  correction.correction_author_role := current_user;
  correction.correction_reason := 'time freshness proof';
  correction.approver_identity := session_user;
  correction.approver_role := current_user;
  correction.approval_confidence := 1;
  correction.approval_reason := 'time freshness proof';
  correction.created_at := statement_timestamp() - add_time_correction.age;
  correction.expires_at := statement_timestamp() + add_time_correction.expires_in;
  correction.correction_hash :=
    otlet.semantic_correction_override_hash(correction);

  EXECUTE 'ALTER TABLE otlet.semantic_correction_overrides DISABLE TRIGGER semantic_correction_overrides_a_reviewer_authority';
  INSERT INTO otlet.semantic_correction_overrides SELECT correction.*;
  EXECUTE 'ALTER TABLE otlet.semantic_correction_overrides ENABLE TRIGGER semantic_correction_overrides_a_reviewer_authority';
  RETURN correction.correction_hash;
END;
$function$;

CREATE FUNCTION pg_temp.add_time_reconciliation(
  watch_name text,
  subject_id text
) RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  inserted bigint;
BEGIN
  INSERT INTO otlet.watch_reconciliation (
    watch_name,
    subject_id,
    workload_revision_hash,
    source_identity,
    attempt_limit,
    reconciliation_reason,
    time_expires_at
  )
  SELECT
    freshness.watch_name,
    freshness.subject_id,
    freshness.workload_revision_hash,
    freshness.source_identity,
    policy.watch_reconciliation_max_attempts,
    'time_refresh',
    freshness.expires_at
  FROM otlet.watch_time_freshness freshness
  CROSS JOIN otlet.production_policy policy
  WHERE freshness.watch_name = add_time_reconciliation.watch_name
    AND freshness.subject_id = add_time_reconciliation.subject_id
    AND policy.name = 'default';
  GET DIAGNOSTICS inserted = ROW_COUNT;
  IF inserted <> 1 THEN
    RAISE EXCEPTION 'time reconciliation fixture %:% inserted % rows',
      add_time_reconciliation.watch_name,
      add_time_reconciliation.subject_id,
      inserted;
  END IF;
END;
$function$;

SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'refresh-row', interval '9 minutes'
) \g /dev/null
SELECT pg_temp.add_time_materialization(
  'time_closed_row', 'closed-row', interval '11 minutes'
) \g /dev/null
SELECT pg_temp.add_time_materialization(
  'time_zero_row', 'zero-row', interval '11 minutes'
) \g /dev/null
SELECT pg_temp.add_time_materialization(
  'time_refresh_pair', 'expired-pair', interval '11 minutes'
) \g /dev/null
SELECT pg_temp.add_time_materialization(
  'time_legacy_row', 'legacy-row', interval '1 day'
) \g /dev/null

CREATE TEMP TABLE time_receipt_job AS
WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    subject_id,
    input,
    status,
    attempts,
    started_at,
    leased_until,
    claim_token
  )
  SELECT
    'time_refresh_row_task',
    'receipt-row',
    otlet.semantic_row_subject_input(
      head.active_workload_revision_hash,
      'receipt-row'
    ),
    'running',
    1,
    clock_timestamp(),
    clock_timestamp() + interval '5 minutes',
    gen_random_uuid()::text
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = 'time_refresh_row_task'
  RETURNING id, claim_token
)
SELECT * FROM inserted;

SELECT otlet.complete_job(
  job_id => id,
  output => '{"decision":"receipt"}'::jsonb,
  raw_output => '{"output":{"decision":"receipt"},"actions":[]}',
  actions => '[]'::jsonb,
  raw_output_hash => otlet.portable_text_hash(
    '{"output":{"decision":"receipt"},"actions":[]}'
  ),
  started_at => clock_timestamp(),
  trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
  model_name => :'model_name',
  expected_claim_token => claim_token
)
FROM time_receipt_job \g /dev/null

SELECT otlet.materialize_completed_semantic_job(id)
FROM time_receipt_job \g /dev/null

UPDATE otlet.semantic_materializations materialization
SET created_at = materialization.created_at - interval '1 hour'
WHERE materialization.task_name = 'time_refresh_row_task'
  AND materialization.subject_id = 'receipt-row';

DO $proof$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.watch_time_freshness freshness
    JOIN otlet.semantic_materializations materialization
      ON materialization.id = freshness.materialization_id
    JOIN otlet.records record ON record.id = materialization.record_id
    JOIN otlet.actions action ON action.id = record.action_id
    JOIN otlet.outputs output ON output.id = action.output_id
    JOIN otlet.inference_receipts receipt ON receipt.id = output.receipt_id
    WHERE freshness.watch_name = 'time_refresh_row'
      AND freshness.subject_id = 'receipt-row'
      AND freshness.refreshed_at = receipt.finished_at
      AND freshness.refreshed_at IS DISTINCT FROM materialization.created_at
  ) THEN
    RAISE EXCEPTION 'accepted receipt did not anchor the time freshness deadline';
  END IF;
END;
$proof$;

SET LOCAL statement_timeout = '2s';

DO $proof$
DECLARE
  reconciliation_count bigint;
BEGIN
  SELECT count(*) INTO reconciliation_count FROM otlet.watch_reconciliation;
  IF reconciliation_count <> 0
     OR NOT otlet.semantic_matches(
       'time_refresh_row', 'refresh-row', '{"decision":"keep"}'::jsonb
     )
     OR otlet.semantic_matches(
       'time_closed_row', 'closed-row', '{"decision":"keep"}'::jsonb
     )
     OR otlet.semantic_join_matches(
       'time_refresh_pair', 'expired-pair', '{"decision":"keep"}'::jsonb
     )
     OR NOT otlet.semantic_matches(
       'time_legacy_row', 'legacy-row', '{"decision":"keep"}'::jsonb
     ) THEN
    RAISE EXCEPTION 'time freshness read boundary is incorrect';
  END IF;

  IF NOT EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness_status
       WHERE watch_name = 'time_refresh_row'
         AND subject_id = 'refresh-row'
         AND freshness_state = 'refresh_due'
         AND time_readable
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness_status
       WHERE watch_name = 'time_closed_row'
         AND subject_id = 'closed-row'
         AND freshness_state = 'time_expired'
         AND NOT time_readable
         AND stale_reason = 'time_expired'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness_status
       WHERE watch_name = 'time_zero_row'
         AND subject_id = 'zero-row'
         AND refresh_due_at = expires_at
         AND freshness_state = 'time_expired'
         AND NOT time_readable
     )
     OR (SELECT count(*) FROM otlet.semantic_index_current_rows(
       'time_closed_row', true
     ) WHERE subject_id = 'closed-row') <> 0
     OR (SELECT count(*) FROM otlet.semantic_join_index_current_rows(
       'time_refresh_pair', true
     ) WHERE subject_id = 'expired-pair') <> 0
     OR (SELECT count(*) FROM otlet.semantic_join_refresh_inputs(
       'time_refresh_pair'
     ) WHERE subject_id = 'expired-pair') <> 1 THEN
    RAISE EXCEPTION 'time freshness status or bounded read surface is incorrect: %',
      jsonb_build_object(
        'refresh_status', EXISTS (
          SELECT 1 FROM otlet.watch_time_freshness_status
          WHERE watch_name = 'time_refresh_row'
            AND subject_id = 'refresh-row'
            AND freshness_state = 'refresh_due'
            AND time_readable
        ),
        'closed_status', EXISTS (
          SELECT 1 FROM otlet.watch_time_freshness_status
          WHERE watch_name = 'time_closed_row'
            AND subject_id = 'closed-row'
            AND freshness_state = 'time_expired'
            AND NOT time_readable
            AND stale_reason = 'time_expired'
        ),
        'row_current', (
          SELECT count(*) FROM otlet.semantic_index_current_rows(
            'time_closed_row', true
          ) WHERE subject_id = 'closed-row'
        ),
        'pair_current', (
          SELECT count(*) FROM otlet.semantic_join_index_current_rows(
            'time_refresh_pair', true
          ) WHERE subject_id = 'expired-pair'
        ),
        'pair_refresh', (
          SELECT count(*) FROM otlet.semantic_join_refresh_inputs(
            'time_refresh_pair'
          ) WHERE subject_id = 'expired-pair'
        )
      );
  END IF;

  IF NOT EXISTS (
       SELECT 1
       FROM otlet.semantic_index_plan('time_closed_row', true)
       WHERE COALESCE((stale_reasons ->> 'time_expired')::bigint, 0) = 1
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.semantic_index_plan('time_closed_row', false)
       WHERE stale_subjects >= 1
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.semantic_dependency_audit
       WHERE task_name = 'time_closed_row_task'
         AND subject_id = 'closed-row'
         AND stale
         AND stale_reason = 'time_expired'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.workload_revision_status
       WHERE task_name = 'time_closed_row_task'
         AND fresh_materializations = 0
     ) THEN
    RAISE EXCEPTION 'time freshness plan or status claims are incorrect';
  END IF;

  IF reconciliation_count IS DISTINCT FROM (
       SELECT count(*) FROM otlet.watch_reconciliation
     ) THEN
    RAISE EXCEPTION 'read-only time freshness checks created reconciliation work';
  END IF;
END;
$proof$;

SAVEPOINT time_pair_refresh_proof;
DO $proof$
DECLARE
  queued bigint;
  queued_jobs bigint;
BEGIN
  queued := otlet.refresh_semantic_join_index('time_refresh_pair');
  SELECT count(*) INTO queued_jobs
  FROM otlet.jobs
  WHERE task_name = 'time_refresh_pair_task'
    AND subject_id = 'expired-pair'
    AND status = 'queued';
  IF queued <> 1 OR queued_jobs <> 1 THEN
    RAISE EXCEPTION 'explicit bounded pair refresh did not queue the expired pair: %|%',
      queued,
      queued_jobs;
  END IF;
END;
$proof$;
ROLLBACK TO SAVEPOINT time_pair_refresh_proof;
RELEASE SAVEPOINT time_pair_refresh_proof;
SET LOCAL statement_timeout = 0;

PREPARE time_expired_customscan AS
SELECT id
FROM public.otlet_time_freshness_row_source
WHERE otlet.semantic_matches(
  'time_closed_row',
  id,
  '{"decision":"keep"}'::jsonb
);

PREPARE time_refresh_due_customscan AS
SELECT id
FROM public.otlet_time_freshness_row_source
WHERE otlet.semantic_matches(
  'time_refresh_row',
  id,
  '{"decision":"keep"}'::jsonb
);

DO $proof$
DECLARE
  plan_line text;
  plan_text text := '';
  matched_id text;
  matched_ids text[] := ARRAY[]::text[];
BEGIN
  FOR plan_line IN EXECUTE 'EXPLAIN (COSTS OFF) EXECUTE time_expired_customscan'
  LOOP
    plan_text := plan_text || plan_line;
  END LOOP;
  IF current_setting('otlet.time_freshness_expect_customscan')::boolean
     AND position('Otlet Semantic Source CustomScan' IN plan_text) = 0 THEN
    RAISE EXCEPTION 'time-expired predicate did not select CustomScan';
  END IF;
  EXECUTE 'EXECUTE time_expired_customscan' INTO matched_id;
  IF matched_id IS NOT NULL THEN
    RAISE EXCEPTION 'time-expired CustomScan returned %', matched_id;
  END IF;

  plan_text := '';
  FOR plan_line IN EXECUTE 'EXPLAIN (COSTS OFF) EXECUTE time_refresh_due_customscan'
  LOOP
    plan_text := plan_text || plan_line;
  END LOOP;
  IF current_setting('otlet.time_freshness_expect_customscan')::boolean
     AND position('Otlet Semantic Source CustomScan' IN plan_text) = 0 THEN
    RAISE EXCEPTION 'refresh-due predicate did not select CustomScan';
  END IF;
  FOR matched_id IN EXECUTE 'EXECUTE time_refresh_due_customscan'
  LOOP
    matched_ids := array_append(matched_ids, matched_id);
  END LOOP;
  IF matched_ids IS DISTINCT FROM ARRAY['refresh-row']::text[] THEN
    RAISE EXCEPTION 'refresh-due CustomScan returned %', matched_ids;
  END IF;
END;
$proof$;

DO $proof$
DECLARE
  replay_result text;
BEGIN
  replay_result := otlet.replay_watch_reconciliation(false);
  IF replay_result <> 'queued'
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.jobs
       WHERE task_name = 'time_refresh_row_task'
         AND subject_id = 'refresh-row'
         AND status = 'queued'
     ) THEN
    RAISE EXCEPTION 'idle replay did not seed and queue time reconciliation: %, source=%',
      replay_result,
      (
        SELECT otlet.task_subject_input(
          revision.definition #>> '{task,input_query}',
          'refresh-row',
          revision.definition
        )
        FROM otlet.workload_revisions revision
        JOIN otlet.workload_revision_heads head
          ON head.active_workload_revision_hash = revision.workload_revision_hash
        WHERE head.task_name = 'time_refresh_row_task'
      );
  END IF;
END;
$proof$;

SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'ack-row', interval '11 minutes'
) \g /dev/null

DO $proof$
DECLARE
  expected_generation bigint;
  wrong_ack boolean;
  exact_ack boolean;
  acknowledged boolean;
  seed_result text;
BEGIN
  IF otlet.seed_watch_time_reconciliation() <> 'time_expired' THEN
    RAISE EXCEPTION 'expired acknowledgement subject was not seeded';
  END IF;
  SELECT reconciliation.generation INTO STRICT expected_generation
  FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = 'time_refresh_row'
    AND reconciliation.subject_id = 'ack-row';
  UPDATE otlet.watch_reconciliation reconciliation
  SET state = 'exhausted',
      attempts = attempt_limit,
      next_attempt_at = NULL,
      last_attempt_at = clock_timestamp(),
      last_error = 'proof exhaustion'
  WHERE reconciliation.watch_name = 'time_refresh_row'
    AND reconciliation.subject_id = 'ack-row';
  wrong_ack := otlet.acknowledge_watch_reconciliation(
    'time_refresh_row', 'ack-row', expected_generation - 1
  );
  exact_ack := otlet.acknowledge_watch_reconciliation(
    'time_refresh_row', 'ack-row', expected_generation
  );
  SELECT EXISTS (
    SELECT 1
    FROM otlet.watch_time_freshness
    WHERE watch_name = 'time_refresh_row'
      AND subject_id = 'ack-row'
      AND acknowledged_at IS NOT NULL
  ) INTO acknowledged;
  seed_result := otlet.seed_watch_time_reconciliation();
  IF wrong_ack OR NOT exact_ack OR NOT acknowledged OR seed_result <> 'idle' THEN
    RAISE EXCEPTION 'time reconciliation acknowledgement fence is incorrect: %',
      jsonb_build_object(
        'wrong_ack', wrong_ack,
        'exact_ack', exact_ack,
        'acknowledged', acknowledged,
        'seed_result', seed_result
      );
  END IF;
END;
$proof$;

SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'terminal-row', interval '11 minutes'
) \g /dev/null

DO $proof$
BEGIN
  IF otlet.seed_watch_time_reconciliation() <> 'time_expired' THEN
    RAISE EXCEPTION 'terminal race subject was not seeded';
  END IF;
END;
$proof$;

INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input,
  execution_mode,
  status,
  finished_at
)
SELECT
  watch.task_name,
  head.active_workload_revision_hash,
  'terminal-row',
  otlet.semantic_row_subject_input(
    head.active_workload_revision_hash,
    'terminal-row'
  ),
  'production',
  'failed',
  clock_timestamp()
FROM otlet.watches watch
JOIN otlet.workload_revision_heads head ON head.task_name = watch.task_name
JOIN otlet.workload_revisions revision
  ON revision.workload_revision_hash = head.active_workload_revision_hash
WHERE watch.name = 'time_refresh_row';

DO $proof$
DECLARE
  reconcile_result text;
BEGIN
  IF EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation
       WHERE watch_name = 'time_refresh_row'
         AND subject_id = 'terminal-row'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness
       WHERE watch_name = 'time_refresh_row'
         AND subject_id = 'terminal-row'
         AND attempted_at IS NOT NULL
     )
     OR (
       SELECT count(*)
       FROM otlet.jobs
       WHERE task_name = 'time_refresh_row_task'
         AND subject_id = 'terminal-row'
     ) <> 1 THEN
    RAISE EXCEPTION 'job admission did not retire the seeded time queue';
  END IF;

  DELETE FROM otlet.jobs
  WHERE task_name = 'time_refresh_row_task'
    AND subject_id = 'terminal-row';

  INSERT INTO otlet.watch_reconciliation (
    watch_name,
    subject_id,
    workload_revision_hash,
    source_identity,
    attempt_limit,
    reconciliation_reason,
    time_expires_at
  )
  SELECT
    freshness.watch_name,
    freshness.subject_id,
    freshness.workload_revision_hash,
    freshness.source_identity,
    policy.watch_reconciliation_max_attempts,
    'time_refresh',
    freshness.expires_at
  FROM otlet.watch_time_freshness freshness
  CROSS JOIN otlet.production_policy policy
  WHERE freshness.watch_name = 'time_refresh_row'
    AND freshness.subject_id = 'terminal-row'
    AND policy.name = 'default';

  reconcile_result := otlet.reconcile_watch_subject(
    'time_refresh_row', 'terminal-row', false
  );
  IF reconcile_result <> 'existing_job'
     OR EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation
       WHERE watch_name = 'time_refresh_row'
         AND subject_id = 'terminal-row'
     )
     OR otlet.seed_watch_time_reconciliation() <> 'idle' THEN
    RAISE EXCEPTION 'attempt marker did not suppress cleanup-before-replay: %',
      reconcile_result;
  END IF;
END;
$proof$;

SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'latest-row', interval '20 minutes'
) \g /dev/null

DO $proof$
BEGIN
  IF otlet.seed_watch_time_reconciliation() <> 'time_expired' THEN
    RAISE EXCEPTION 'old evidence was not seeded before successor proof';
  END IF;
  UPDATE otlet.watch_reconciliation
  SET state = 'exhausted',
      attempts = attempt_limit,
      next_attempt_at = NULL,
      last_attempt_at = clock_timestamp(),
      last_error = 'old evidence exhausted'
  WHERE watch_name = 'time_refresh_row'
    AND subject_id = 'latest-row';
END;
$proof$;

SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'latest-row', interval '1 minute'
) \g /dev/null

DO $proof$
BEGIN
  IF (SELECT count(*) FROM otlet.watch_time_freshness
      WHERE watch_name = 'time_refresh_row' AND subject_id = 'latest-row') <> 1
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness_status
       WHERE watch_name = 'time_refresh_row'
         AND subject_id = 'latest-row'
         AND freshness_state = 'fresh'
         AND time_readable
     )
     OR EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation
       WHERE watch_name = 'time_refresh_row'
         AND subject_id = 'latest-row'
     )
     OR NOT otlet.semantic_matches(
       'time_refresh_row', 'latest-row', '{"decision":"keep"}'::jsonb
     )
     OR otlet.seed_watch_time_reconciliation() <> 'idle' THEN
    RAISE EXCEPTION 'historical materialization reseeded after a fresh successor';
  END IF;
END;
$proof$;

CREATE TEMP TABLE time_revalidated_materialization(id bigint NOT NULL);
INSERT INTO time_revalidated_materialization
SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'revalidated-row', interval '11 minutes'
);

DO $proof$
BEGIN
  IF otlet.seed_watch_time_reconciliation() <> 'time_expired' THEN
    RAISE EXCEPTION 'benign revalidation subject was not seeded';
  END IF;
END;
$proof$;

UPDATE public.otlet_time_freshness_row_source
SET note = 'unprojected change'
WHERE id = 'revalidated-row';

CREATE TEMP TABLE time_revalidation_result AS
SELECT *
FROM otlet.revalidate_semantic_subjects(
  'time_refresh_row',
  ARRAY['revalidated-row']
);

SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'manual-row', interval '11 minutes', true, 'manual'
) \g /dev/null

CREATE TEMP TABLE time_correction_materialization(id bigint NOT NULL);
INSERT INTO time_correction_materialization
SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'correction-row', interval '20 minutes'
);
SELECT pg_temp.add_time_reconciliation(
  'time_refresh_row', 'correction-row'
) \g /dev/null
SELECT pg_temp.add_time_correction(
  (SELECT id FROM time_correction_materialization),
  interval '11 minutes'
) \g /dev/null

CREATE TEMP TABLE time_expired_correction_materialization(id bigint NOT NULL);
INSERT INTO time_expired_correction_materialization
SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'expired-correction-row', interval '21 minutes'
);
SELECT pg_temp.add_time_reconciliation(
  'time_refresh_row', 'expired-correction-row'
) \g /dev/null
SELECT pg_temp.add_time_correction(
  (SELECT id FROM time_expired_correction_materialization),
  interval '11 minutes',
  -interval '1 minute'
) \g /dev/null

SELECT pg_temp.add_time_correction(
  (
    SELECT materialization.id
    FROM otlet.semantic_materializations materialization
    WHERE materialization.task_name = 'time_refresh_pair_task'
      AND materialization.subject_id = 'expired-pair'
    ORDER BY materialization.id DESC
    LIMIT 1
  ),
  interval '11 minutes',
  -interval '1 minute'
) \g /dev/null

DO $proof$
DECLARE
  time_replay text;
  revision_hash text;
BEGIN
  IF NOT EXISTS (
       SELECT 1
       FROM time_revalidation_result
       WHERE subject_id = 'revalidated-row'
         AND revalidated
         AND freshness_basis = 'revalidated_after_benign_update'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness_status
       WHERE watch_name = 'time_refresh_row'
         AND subject_id = 'revalidated-row'
         AND freshness_state = 'time_expired'
         AND NOT time_readable
         AND stale_reason = 'time_expired'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.semantic_materializations_effective
       WHERE task_name = 'time_refresh_row_task'
         AND subject_id = 'manual-row'
         AND stale
         AND stale_reason = 'manual'
     )
     OR NOT otlet.semantic_matches(
       'time_refresh_row', 'correction-row', '{"decision":"corrected"}'::jsonb
     )
     OR EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness
       WHERE watch_name = 'time_refresh_row'
         AND subject_id = 'correction-row'
     )
     OR EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation
       WHERE watch_name = 'time_refresh_row'
         AND subject_id = 'correction-row'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.semantic_materializations_effective
       WHERE task_name = 'time_refresh_row_task'
         AND subject_id = 'expired-correction-row'
         AND stale
         AND stale_reason = 'semantic_correction_re_review'
         AND correction_status = 're_review'
     )
     OR otlet.semantic_matches(
       'time_refresh_row',
       'expired-correction-row',
       '{"decision":"corrected"}'::jsonb
     )
     OR EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness
       WHERE subject_id = 'expired-correction-row'
     )
     OR EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation
       WHERE subject_id = 'expired-correction-row'
     )
     OR EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness
       WHERE watch_name = 'time_refresh_pair'
         AND subject_id = 'expired-pair'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.semantic_materializations materialization
       WHERE materialization.id = (SELECT id FROM time_correction_materialization)
         AND materialization.body = '{"decision":"keep"}'::jsonb
     ) THEN
    RAISE EXCEPTION 'immutable age, stale reason, or correction freshness is incorrect';
  END IF;

  SELECT active_workload_revision_hash INTO STRICT revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = 'time_refresh_row_task';
  IF NOT otlet.resolve_watch_input_reconciliation(
    'time_refresh_row_task',
    revision_hash,
    'revalidated-row',
    otlet.semantic_row_subject_input(revision_hash, 'revalidated-row')
  ) THEN
    RAISE EXCEPTION 'benign revalidation did not resolve source reconciliation';
  END IF;
  time_replay := otlet.replay_watch_reconciliation(false);
  IF time_replay <> 'queued'
     OR otlet.replay_watch_reconciliation(false) <> 'idle'
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.jobs
       WHERE task_name = 'time_refresh_row_task'
         AND subject_id = 'revalidated-row'
         AND status = 'queued'
     ) THEN
    RAISE EXCEPTION 'benign revalidation lost or looped its time refresh: %',
      time_replay;
  END IF;
END;
$proof$;

SET LOCAL statement_timeout = '2s';
DO $proof$
BEGIN
  IF otlet.refresh_semantic_join_index('time_refresh_pair') <> 0 THEN
    RAISE EXCEPTION 'expired pair correction returned to model-age refresh';
  END IF;
END;
$proof$;
SET LOCAL statement_timeout = 0;

SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'collision-row', interval '11 minutes'
) \g /dev/null

DO $proof$
BEGIN
  IF otlet.seed_watch_time_reconciliation() <> 'time_expired' THEN
    RAISE EXCEPTION 'source-collision subject was not seeded';
  END IF;
  UPDATE public.otlet_time_freshness_row_source
  SET payload = 'collision changed'
  WHERE id = 'collision-row';
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.watch_reconciliation
    WHERE watch_name = 'time_refresh_row'
      AND subject_id = 'collision-row'
      AND reconciliation_reason = 'source_change'
      AND time_expires_at IS NULL
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations_effective materialization
    WHERE materialization.task_name = 'time_refresh_row_task'
      AND materialization.subject_id = 'collision-row'
      AND materialization.stale
      AND materialization.stale_reason = 'source_update'
  ) THEN
    RAISE EXCEPTION 'source change did not retain precedence over time freshness';
  END IF;
  DELETE FROM otlet.watch_reconciliation
  WHERE watch_name = 'time_refresh_row'
    AND subject_id = 'collision-row';
END;
$proof$;

SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'backoff-row', interval '11 minutes'
) \g /dev/null

UPDATE otlet.production_policy
SET max_queued_jobs_per_model = 2
WHERE name = 'default';

DO $proof$
DECLARE
  result text;
BEGIN
  IF otlet.seed_watch_time_reconciliation() <> 'time_expired' THEN
    RAISE EXCEPTION 'backoff subject was not seeded';
  END IF;
  result := otlet.reconcile_watch_subject(
    'time_refresh_row', 'backoff-row', false
  );
  IF result <> 'pending'
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation
       WHERE watch_name = 'time_refresh_row'
         AND subject_id = 'backoff-row'
         AND reconciliation_reason = 'time_refresh'
         AND state = 'pending'
         AND attempts = 1
         AND next_attempt_at > clock_timestamp()
     ) THEN
    RAISE EXCEPTION 'time reconciliation did not retain durable backoff: %', result;
  END IF;
END;
$proof$;

SELECT pg_temp.add_time_materialization(
  'time_refresh_row', 'paused-row', interval '11 minutes'
) \g /dev/null

DO $proof$
DECLARE
  revision_hash text;
  expected_generation bigint;
  reconcile_result text;
BEGIN
  IF otlet.seed_watch_time_reconciliation() <> 'time_expired' THEN
    RAISE EXCEPTION 'pause-retained subject was not seeded';
  END IF;
  SELECT active_workload_revision_hash INTO STRICT revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = 'time_refresh_row_task';
  SELECT reconciliation.generation INTO STRICT expected_generation
  FROM otlet.watch_reconciliation reconciliation
  WHERE reconciliation.watch_name = 'time_refresh_row'
    AND reconciliation.subject_id = 'paused-row';

  PERFORM otlet.set_task_lifecycle(
    'time_refresh_row_task', 'paused', revision_hash
  );
  reconcile_result := otlet.reconcile_watch_subject(
    'time_refresh_row', 'paused-row', false
  );
  IF reconcile_result <> 'paused'
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation reconciliation
       WHERE reconciliation.watch_name = 'time_refresh_row'
         AND reconciliation.subject_id = 'paused-row'
         AND reconciliation.generation = expected_generation
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness_status freshness
       WHERE freshness.watch_name = 'time_refresh_row'
         AND freshness.subject_id = 'paused-row'
         AND freshness.kind = 'row'
         AND freshness.overdue_policy = 'reconcile'
         AND freshness.freshness_state = 'time_expired'
         AND NOT freshness.time_readable
         AND freshness.reconciliation_generation = expected_generation
     )
     OR EXISTS (SELECT 1 FROM otlet.verify_time_freshness_invariants()) THEN
    RAISE EXCEPTION 'paused time reconciliation was not retained: %',
      reconcile_result;
  END IF;

  PERFORM otlet.set_task_lifecycle(
    'time_refresh_row_task', 'active', revision_hash
  );
  IF NOT otlet.acknowledge_watch_reconciliation(
    'time_refresh_row', 'paused-row', expected_generation
  ) THEN
    RAISE EXCEPTION 'resumed time reconciliation acknowledgement failed';
  END IF;
END;
$proof$;

SAVEPOINT time_revision_proof;
SELECT otlet.create_watch(
  watch_name => 'time_revision_row',
  kind => 'row',
  instruction => 'Return the decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_time_freshness_row_source'::regclass,
  subject_column => 'id',
  input_columns => ARRAY['id', 'payload'],
  trigger_policy => '{"on_change":"mark_stale_and_enqueue","max_age_ms":600000,"refresh_window_ms":120000,"on_overdue":"reconcile"}'::jsonb
) \g /dev/null
SELECT pg_temp.add_time_materialization(
  'time_revision_row', 'revision-row', interval '20 minutes'
) \g /dev/null

SAVEPOINT time_live_drift_proof;
UPDATE otlet.watches
SET trigger_policy = '{"on_change":"mark_stale"}'::jsonb
WHERE name = 'time_revision_row';
DO $proof$
DECLARE
  seed_result text;
  seed_attempts integer := 0;
  reconcile_result text;
BEGIN
  LOOP
    seed_attempts := seed_attempts + 1;
    seed_result := otlet.seed_watch_time_reconciliation();
    EXIT WHEN EXISTS (
      SELECT 1
      FROM otlet.watch_reconciliation
      WHERE watch_name = 'time_revision_row'
        AND subject_id = 'revision-row'
    );
    IF seed_result = 'idle' OR seed_attempts >= 32 THEN
      RAISE EXCEPTION 'pinned time policy did not seed through live watch drift: %',
        seed_result;
    END IF;
  END LOOP;
  IF NOT EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness_status freshness
       WHERE freshness.watch_name = 'time_revision_row'
         AND freshness.subject_id = 'revision-row'
         AND freshness.kind = 'row'
         AND freshness.overdue_policy = 'reconcile'
         AND freshness.reconciliation_reason = 'time_refresh'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.task_lifecycle_status status
       WHERE status.task_name = 'time_revision_row_task'
         AND status.configured_revision_drift
     ) THEN
    RAISE EXCEPTION 'pinned time policy did not survive live watch drift: %',
      jsonb_build_object(
        'status', EXISTS (
          SELECT 1
          FROM otlet.watch_time_freshness_status freshness
          WHERE freshness.watch_name = 'time_revision_row'
            AND freshness.subject_id = 'revision-row'
            AND freshness.kind = 'row'
            AND freshness.overdue_policy = 'reconcile'
            AND freshness.reconciliation_reason = 'time_refresh'
        ),
        'configured_drift', EXISTS (
          SELECT 1
          FROM otlet.task_lifecycle_status status
          WHERE status.task_name = 'time_revision_row_task'
            AND status.configured_revision_drift
        )
      );
  END IF;
  UPDATE otlet.production_policy
  SET max_queued_jobs_per_model = 1000
  WHERE name = 'default';
  reconcile_result := otlet.reconcile_watch_subject(
    'time_revision_row', 'revision-row', false
  );
  IF reconcile_result <> 'queued' THEN
    RAISE EXCEPTION 'pinned time reconciliation followed live watch drift: %',
      reconcile_result;
  END IF;
END;
$proof$;
ROLLBACK TO SAVEPOINT time_live_drift_proof;
RELEASE SAVEPOINT time_live_drift_proof;

DO $proof$
DECLARE
  old_revision_hash text;
  new_revision_hash text;
  seed_result text;
  seed_attempts integer := 0;
  reconcile_result text;
BEGIN
  LOOP
    seed_attempts := seed_attempts + 1;
    seed_result := otlet.seed_watch_time_reconciliation();
    EXIT WHEN EXISTS (
      SELECT 1
      FROM otlet.watch_reconciliation
      WHERE watch_name = 'time_revision_row'
        AND subject_id = 'revision-row'
    );
    IF seed_result = 'idle' OR seed_attempts >= 32 THEN
      RAISE EXCEPTION 'old revision time work was not seeded: %', seed_result;
    END IF;
  END LOOP;
  SELECT active_workload_revision_hash INTO STRICT old_revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = 'time_revision_row_task';

  UPDATE otlet.tasks
  SET instruction = 'Return the current decision'
  WHERE name = 'time_revision_row_task';
  new_revision_hash := otlet.promote_configured_workload_revision(
    'time_revision_row_task'
  );
  IF new_revision_hash = old_revision_hash
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation reconciliation
       WHERE reconciliation.watch_name = 'time_revision_row'
         AND reconciliation.subject_id = 'revision-row'
         AND reconciliation.workload_revision_hash = old_revision_hash
         AND reconciliation.reconciliation_reason = 'time_refresh'
     )
     OR EXISTS (SELECT 1 FROM otlet.verify_time_freshness_invariants()) THEN
    RAISE EXCEPTION 'valid promotion invalidated retained time work';
  END IF;

  reconcile_result := otlet.reconcile_watch_subject(
    'time_revision_row', 'revision-row', false
  );
  IF reconcile_result <> 'superseded'
     OR EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation reconciliation
       WHERE reconciliation.watch_name = 'time_revision_row'
         AND reconciliation.subject_id = 'revision-row'
     ) THEN
    RAISE EXCEPTION 'old revision time work did not close as superseded: %',
      reconcile_result;
  END IF;
  PERFORM pg_temp.add_time_reconciliation(
    'time_revision_row', 'revision-row'
  );

  PERFORM pg_temp.add_time_materialization(
    'time_revision_row', 'revision-row', interval '1 minute'
  );
  IF EXISTS (
       SELECT 1
       FROM otlet.watch_reconciliation reconciliation
       WHERE reconciliation.watch_name = 'time_revision_row'
         AND reconciliation.subject_id = 'revision-row'
     )
     OR (SELECT count(*) FROM otlet.watch_time_freshness freshness
         WHERE freshness.watch_name = 'time_revision_row'
           AND freshness.subject_id = 'revision-row') <> 1
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.watch_time_freshness_status freshness
       WHERE freshness.watch_name = 'time_revision_row'
         AND freshness.subject_id = 'revision-row'
         AND freshness.workload_revision_hash = new_revision_hash
         AND freshness.freshness_state = 'fresh'
         AND freshness.time_readable
     ) THEN
    RAISE EXCEPTION 'new revision evidence did not retire old time work';
  END IF;
END;
$proof$;
ROLLBACK TO SAVEPOINT time_revision_proof;
RELEASE SAVEPOINT time_revision_proof;

INSERT INTO public.otlet_time_freshness_pair_source
SELECT
  'overflow-' || value::text,
  jsonb_build_object('left', value, 'right', value + 1)
FROM generate_series(1, 10) value;
SET LOCAL statement_timeout = '2s';
DO $proof$
DECLARE
  jobs_before bigint;
BEGIN
  SELECT count(*) INTO jobs_before
  FROM otlet.jobs
  WHERE task_name = 'time_refresh_pair_task';
  PERFORM pg_temp.expect_error(
    $$SELECT otlet.refresh_semantic_join_index('time_refresh_pair')$$,
    'exceeds max_candidate_rows 10'
  );
  IF jobs_before IS DISTINCT FROM (
    SELECT count(*)
    FROM otlet.jobs
    WHERE task_name = 'time_refresh_pair_task'
  ) THEN
    RAISE EXCEPTION 'pair overflow left partial refresh jobs';
  END IF;
END;
$proof$;
SET LOCAL statement_timeout = 0;
DELETE FROM public.otlet_time_freshness_pair_source
WHERE subject_id LIKE 'overflow-%';

DO $proof$
BEGIN
  IF otlet.semantic_time_freshness_state(
       '2026-01-01 00:00:00+00', 1000, 200, '2026-01-01 00:00:00.799+00'
     ) <> 'fresh'
     OR otlet.semantic_time_freshness_state(
       '2026-01-01 00:00:00+00', 1000, 200, '2026-01-01 00:00:00.800+00'
     ) <> 'refresh_due'
     OR otlet.semantic_time_freshness_state(
       '2026-01-01 00:00:00+00', 1000, 200, '2026-01-01 00:00:01+00'
     ) <> 'time_expired'
     OR otlet.semantic_time_freshness_state(
       '2026-01-01 00:00:00+00', 1000, 0, '2026-01-01 00:00:01+00'
     ) <> 'time_expired' THEN
    RAISE EXCEPTION 'time freshness boundary equality is incorrect';
  END IF;

  IF has_table_privilege('public', 'otlet.watch_time_freshness', 'SELECT')
     OR has_table_privilege('public', 'otlet.watch_time_freshness_status', 'SELECT')
     OR has_function_privilege(
       'public',
       'otlet.semantic_time_freshness_state('
         'timestamptz,bigint,bigint,timestamptz)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'public',
       'otlet.seed_watch_time_reconciliation()',
       'EXECUTE'
     )
     OR EXISTS (SELECT 1 FROM otlet.verify_invariants()) THEN
    RAISE EXCEPTION 'time freshness permissions or invariants are incorrect: %',
      COALESCE(
        (SELECT jsonb_agg(to_jsonb(invariant)) FROM otlet.verify_invariants() invariant),
        '[]'::jsonb
      );
  END IF;
END;
$proof$;

SELECT concat_ws('|',
  (SELECT freshness_state = 'refresh_due' AND time_readable
   FROM otlet.watch_time_freshness_status
   WHERE watch_name = 'time_refresh_row' AND subject_id = 'refresh-row'),
  (SELECT freshness_state = 'time_expired' AND NOT time_readable
   FROM otlet.watch_time_freshness_status
   WHERE watch_name = 'time_closed_row' AND subject_id = 'closed-row'),
  (SELECT count(*) = 0
   FROM otlet.watch_time_freshness
   WHERE watch_name = 'time_refresh_pair' AND subject_id = 'expired-pair'),
  (SELECT count(*) = 1
   FROM otlet.jobs
   WHERE task_name = 'time_refresh_row_task'
     AND subject_id = 'refresh-row'
     AND status = 'queued'),
  (SELECT count(*) = 0
   FROM otlet.watch_reconciliation
   WHERE watch_name = 'time_refresh_pair'),
  (SELECT count(*) = 1
   FROM otlet.watch_time_freshness
   WHERE watch_name = 'time_refresh_row' AND subject_id = 'latest-row'),
  (SELECT reconciliation_reason = 'time_refresh' AND attempts = 1
   FROM otlet.watch_reconciliation
   WHERE watch_name = 'time_refresh_row' AND subject_id = 'backoff-row'),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
ROLLBACK;
SQL
then
  rm -f "$time_based_freshness_output"
  exit 1
fi

time_based_freshness_contract="$(tail -n 1 "$time_based_freshness_output")"
rm -f "$time_based_freshness_output"

echo "time_based_freshness_contract=$time_based_freshness_contract"
[ "$time_based_freshness_contract" = "t|t|t|t|t|t|t|t" ] || {
  echo "Expected time-based freshness contract, got $time_based_freshness_contract" >&2
  exit 1
}
