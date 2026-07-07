log "Checking pair strip-key freshness"
psql_exec \
  -v watch_name="$pair_strip_watch" \
  -v model_name="$strong_model_name" >/dev/null <<'SQL'
DROP VIEW IF EXISTS public.otlet_demo_pair_strip_input;
DROP TABLE IF EXISTS public.otlet_demo_pair_strip;
CREATE TABLE public.otlet_demo_pair_strip (
  id text PRIMARY KEY,
  left_name text NOT NULL,
  right_name text NOT NULL,
  volatile_note text NOT NULL
);
INSERT INTO public.otlet_demo_pair_strip
VALUES ('pair-strip-1', 'Northstar Logistics LLC', 'N-Star Freight Services', 'first volatile note');
CREATE VIEW public.otlet_demo_pair_strip_input AS
SELECT
  id AS subject_id,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_pair_strip',
      'subject_id', id
    ),
    'left_name', left_name,
    'right_name', right_name,
    'volatile_note', volatile_note
  ) AS input
FROM public.otlet_demo_pair_strip;

SELECT otlet.create_watch(
  watch_name => :'watch_name',
  kind => 'pair',
  instruction => 'Return status ok with confidence high and no actions. Return JSON only.',
  output_schema => '{"type":"object","required":["status","confidence"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]},"confidence":{"enum":["high"]}}}'::jsonb,
  model_name => :'model_name',
  candidate_query => $$
    SELECT subject_id, input
    FROM public.otlet_demo_pair_strip_input
  $$,
  record_type => 'pair_strip_result',
  runtime_options => '{"max_tokens":64,"reasoning":"off","inference_cache":false}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  input_shaping => '{"strip_keys":["volatile_note"]}'::jsonb,
  decision_contract => '{"answer_field":"status","abstain_values":[],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb,
  max_candidate_rows => 5
);
SELECT otlet.refresh_semantic_join_index(:'watch_name');
SQL
wait_task_complete "$pair_strip_task" 1 900 1
pair_strip_receipts_before="$(psql_value "
SELECT count(*)
FROM otlet.inference_receipts r
JOIN otlet.jobs j ON j.id = r.job_id
WHERE j.task_name = '$pair_strip_task';
")"
psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_demo_pair_strip
SET volatile_note = 'second volatile note'
WHERE id = 'pair-strip-1';
SQL
pair_strip_contract="$(psql_value "
WITH live AS (
  SELECT input
  FROM public.otlet_demo_pair_strip_input
  WHERE subject_id = 'pair-strip-1'
), materialized AS (
  SELECT sm.source_hash
  FROM otlet.semantic_materializations sm
  WHERE sm.task_name = '$pair_strip_task'
    AND sm.subject_id = 'pair-strip-1'
  ORDER BY sm.updated_at DESC, sm.id DESC
  LIMIT 1
)
SELECT (SELECT count(*) FROM otlet.semantic_join_index_current_rows('$pair_strip_watch', true))::text || '|' ||
       (SELECT stale_subjects::text FROM otlet.semantic_join_index_plan('$pair_strip_watch', true)) || '|' ||
       (SELECT (materialized.source_hash IS DISTINCT FROM md5(live.input::text))::text FROM materialized, live) || '|' ||
       '$pair_strip_receipts_before' || '|' ||
       (
         SELECT count(*)::text
         FROM otlet.inference_receipts r
         JOIN otlet.jobs j ON j.id = r.job_id
         WHERE j.task_name = '$pair_strip_task'
       );
")"
echo "pair_strip_contract=$pair_strip_contract"
[ "$pair_strip_contract" = "1|0|true|1|1" ] || {
  echo "Expected pair strip-key update to stay fresh with unchanged receipts, got $pair_strip_contract" >&2
  exit 1
}

log "Running non-ER row triage watch"
psql_exec \
  -v model_name="$strong_model_name" \
  -v row_triage_watch="$row_triage_watch" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_triage_signal;
CREATE TABLE public.otlet_demo_triage_signal (
  id text PRIMARY KEY,
  blockers integer NOT NULL,
  approvals integer NOT NULL,
  evidence text NOT NULL
);

SELECT otlet.create_watch(
  :'row_triage_watch',
  'row',
  'Classify one operational row. Use input.row.blockers and input.row.approvals. If blockers is greater than 0, output decision flag with confidence high and exactly one review_flag action. The review_flag body must have severity high and a short reason. If blockers = 0 and approvals > 0, output decision pass with confidence high and no actions. Otherwise output decision unclear with confidence medium and one review_flag action. Return JSON only.',
  '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["flag", "pass", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 160}
    }
  }'::jsonb,
  :'model_name',
  'public.otlet_demo_triage_signal'::regclass,
  'id',
  NULL,
  'demo_triage_fact',
  '{"max_tokens":160,"reasoning":"off","inference_cache":true}'::jsonb,
  '{}'::jsonb,
  '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  ARRAY['review_flag'],
  'refresh_then_fail_closed',
  '{}'::jsonb,
  '{"answer_field":"decision","abstain_values":["unclear"],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);

INSERT INTO public.otlet_demo_triage_signal
VALUES (
  'triage-1',
  2,
  0,
  'Wire instructions changed after invoice approval and the requester used urgent payment language'
);
SQL
wait_task_complete "$row_triage_task" 1 900 1

row_triage_contract="$(psql_value "
SELECT count(DISTINCT r.job_id) FILTER (WHERE r.status = 'complete')::text || '|' ||
       COALESCE(max(r.output->>'decision'), '') || '|' ||
       COALESCE(max(r.output->>'confidence'), '') || '|' ||
       count(a.action_id) FILTER (WHERE a.action_type = 'review_flag')::text || '|' ||
       count(a.action_id) FILTER (WHERE a.action_type = 'review_flag' AND a.error IS NULL)::text || '|' ||
       (
         SELECT (count(*) FILTER (WHERE s.freshness_basis = 'content_hash_match') >= 1)::text
         FROM otlet.inference_receipt_trace_status s
         WHERE s.task_name = '$row_triage_task'
           AND s.accepted
       )
FROM otlet.runs r
LEFT JOIN otlet.action_status a ON a.job_id = r.job_id
WHERE r.task_name = '$row_triage_task';
")"
echo "row_triage_contract=$row_triage_contract"
[ "$row_triage_contract" = "1|flag|high|1|1|true" ] || {
  echo "Expected non-ER triage task to produce one flagged output and one valid review action, got $row_triage_contract" >&2
  exit 1
}

row_triage_action_id="$(psql_value "
SELECT min(action_id)
FROM otlet.action_status
WHERE task_name = '$row_triage_task'
  AND action_type = 'review_flag'
  AND error IS NULL;
")"
[ -n "$row_triage_action_id" ] || {
  echo "Expected row triage review action id" >&2
  exit 1
}
psql_exec >/dev/null <<SQL
SELECT * FROM otlet.label_action($row_triage_action_id, label_source => 'approved_action');
SQL
row_eval_label_contract="$(psql_value "
WITH status AS (
  SELECT *
  FROM otlet.eval_label_status
  WHERE action_id = $row_triage_action_id
), exported AS (
  SELECT *
  FROM otlet.export_eval_cases(50)
  WHERE action_id = $row_triage_action_id
)
SELECT count(*)::text || '|' ||
       COALESCE(max(status.expected_answer), '') || '|' ||
       COALESCE(max(status.observed_answer), '') || '|' ||
       COALESCE(max(exported.expected_answer), '') || '|' ||
       COALESCE(max(exported.case_kind), '')
FROM status, exported;
")"
echo "row_eval_label_contract=$row_eval_label_contract"
[ "$row_eval_label_contract" = "1|flag|flag|flag|positive" ] || {
  echo "Expected row triage eval label/export to use decision as expected_answer, got $row_eval_label_contract" >&2
  exit 1
}
row_eval_label_reject_contract="$(
  psql_exec -qAt -v action_id="$row_triage_action_id" <<'SQL'
CREATE TEMP TABLE eval_label_reject_params(action_id bigint);
CREATE TEMP TABLE eval_label_reject_result(message text);
INSERT INTO eval_label_reject_params VALUES (:action_id);
DO $$
DECLARE
  target_action_id bigint;
BEGIN
  SELECT action_id INTO target_action_id FROM eval_label_reject_params;
  BEGIN
    PERFORM * FROM otlet.label_action(target_action_id, expected_answer => 'same_entity');
    INSERT INTO eval_label_reject_result VALUES ('no error');
  EXCEPTION WHEN others THEN
    INSERT INTO eval_label_reject_result VALUES (SQLERRM);
  END;
END $$;
SELECT message FROM eval_label_reject_result;
SQL
)"
echo "row_eval_label_reject_contract=$row_eval_label_reject_contract"
require_contains "$row_eval_label_reject_contract" "otlet expected_answer same_entity is not valid for task $row_triage_task field decision" "Expected invalid expected_answer to be rejected against task enum"

row_review_queue_contract="$(psql_value "
SELECT count(*)::text || '|' ||
       COALESCE(max(queue_kind), '') || '|' ||
       COALESCE(max(watch_name), '') || '|' ||
       COALESCE(max(source_stale::text), '') || '|' ||
       (max(receipt_id) IS NOT NULL)::text
FROM otlet.review_queue
WHERE action_id = $row_triage_action_id;
")"
echo "row_review_queue_contract=$row_review_queue_contract"
[ "$row_review_queue_contract" = "1|review_flag|$row_triage_watch|false|true" ] || {
  echo "Expected row review action in review_queue with receipt and fresh source identity, got $row_review_queue_contract" >&2
  exit 1
}
psql_exec >/dev/null <<SQL
SELECT * FROM otlet.correct_action(
  $row_triage_action_id,
  '{"decision":"pass","confidence":"high","action_type":"review_flag"}'::jsonb,
  'demo correction'
);
SQL
row_correction_contract="$(psql_value "
SELECT a.status || '|' ||
       a.approval_status || '|' ||
       (SELECT count(*) FROM otlet.eval_labels WHERE action_id = $row_triage_action_id AND label_source = 'manual_correction')::text || '|' ||
       (SELECT count(*) FROM otlet.export_eval_cases(50) WHERE action_id = $row_triage_action_id AND case_kind = 'gold')::text || '|' ||
       (SELECT count(*) FROM otlet.review_queue WHERE action_id = $row_triage_action_id)::text
FROM otlet.actions a
WHERE a.id = $row_triage_action_id;
")"
echo "row_correction_contract=$row_correction_contract"
[ "$row_correction_contract" = "rejected|rejected|1|1|0" ] || {
  echo "Expected correction to reject action, write gold label, and remove review queue row, got $row_correction_contract" >&2
  exit 1
}

log "Running numeric evidence triage watch"
psql_exec \
  -v model_name="$strong_model_name" \
  -v numeric_triage_watch="$numeric_triage_watch" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_numeric_triage;
CREATE TABLE public.otlet_demo_numeric_triage (
  id text PRIMARY KEY,
  amount_cents integer NOT NULL,
  limit_cents integer NOT NULL,
  note text NOT NULL
);

SELECT otlet.create_watch(
  :'numeric_triage_watch',
  'row',
  'Classify one numeric control row. Use only input.row.amount_cents and input.row.limit_cents. If amount_cents is greater than limit_cents, output decision flag with confidence high and exactly one review_flag action. The review_flag body must have severity high and a short reason. Return JSON only.',
  '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["flag"]},
      "confidence": {"enum": ["high"]},
      "reason": {"type": "string", "maxLength": 120}
    }
  }'::jsonb,
  :'model_name',
  'public.otlet_demo_numeric_triage'::regclass,
  'id',
  NULL,
  'numeric_triage_fact',
  '{"max_tokens":160,"reasoning":"off","inference_cache":true}'::jsonb,
  '{}'::jsonb,
  '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  ARRAY['review_flag'],
  'refresh_then_fail_closed',
  '{}'::jsonb,
  '{"answer_field":"decision","abstain_values":[],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);

INSERT INTO public.otlet_demo_numeric_triage
VALUES (
  'numeric-1',
  25000,
  10000,
  'Payment exceeds the declared approval threshold'
);
SQL
wait_task_complete "$numeric_triage_task" 1 900 1
numeric_triage_action_id="$(psql_value "
SELECT min(action_id)
FROM otlet.action_status
WHERE task_name = '$numeric_triage_task'
  AND action_type = 'review_flag'
  AND error IS NULL;
")"
[ -n "$numeric_triage_action_id" ] || {
  echo "Expected numeric triage review_flag action" >&2
  exit 1
}
numeric_triage_contract="$(psql_value "
SELECT r.status || '|' ||
       COALESCE(r.output->>'decision', '') || '|' ||
       COALESCE(r.output->>'confidence', '') || '|' ||
       (r.output_id IS NOT NULL)::text || '|' ||
       (msa.receipt_id IS NOT NULL)::text || '|' ||
       COALESCE(a.action_type, '') || '|' ||
       (a.output_id IS NOT NULL)::text || '|' ||
       (rq.receipt_id IS NOT NULL)::text || '|' ||
       COALESCE(rq.queue_kind, '')
FROM otlet.runs r
JOIN otlet.model_selection_attempts msa ON msa.job_id = r.job_id
JOIN otlet.action_status a
  ON a.job_id = r.job_id
 AND a.action_type = 'review_flag'
LEFT JOIN otlet.review_queue rq ON rq.action_id = a.action_id
WHERE r.task_name = '$numeric_triage_task'
ORDER BY r.job_id DESC
LIMIT 1;
")"
echo "numeric_triage_contract=$numeric_triage_contract"
[ "$numeric_triage_contract" = "complete|flag|high|true|true|review_flag|true|true|review_flag" ] || {
  echo "Expected numeric triage surfaces to render without NULL surprises, got $numeric_triage_contract" >&2
  exit 1
}
psql_exec >/dev/null <<SQL
SELECT * FROM otlet.label_action($numeric_triage_action_id, label_source => 'approved_action');
SQL
numeric_triage_label_contract="$(psql_value "
WITH status AS (
  SELECT *
  FROM otlet.eval_label_status
  WHERE action_id = $numeric_triage_action_id
), exported AS (
  SELECT *
  FROM otlet.export_eval_cases(50)
  WHERE action_id = $numeric_triage_action_id
)
SELECT count(*)::text || '|' ||
       COALESCE(max(status.expected_answer), '') || '|' ||
       COALESCE(max(status.observed_answer), '') || '|' ||
       COALESCE(max(exported.expected_action_type), '') || '|' ||
       COALESCE(max(exported.case_kind), '')
FROM status, exported;
")"
echo "numeric_triage_label_contract=$numeric_triage_label_contract"
[ "$numeric_triage_label_contract" = "1|flag|flag|review_flag|positive" ] || {
  echo "Expected numeric triage label/export to round trip through non-ER action, got $numeric_triage_label_contract" >&2
  exit 1
}

cleanup_task "$no_abstain_eval_task"
no_abstain_eval_contract="$(
  psql_exec -qAt -v task_name="$no_abstain_eval_task" -v model_name="$strong_model_name" <<'SQL'
CREATE TEMP TABLE no_abstain_eval_result (
  key text PRIMARY KEY,
  value text NOT NULL
);
CREATE TEMP TABLE no_abstain_eval_params (
  task_name text NOT NULL,
  model_name text NOT NULL
);
INSERT INTO no_abstain_eval_params VALUES (:'task_name', :'model_name');
DO $$
DECLARE
  task_name_value text;
  model_name_value text;
  positive_job_id bigint;
  alias_job_id bigint;
  positive_action_id bigint;
  alias_action_id bigint;
BEGIN
  SELECT task_name, model_name
  INTO task_name_value, model_name_value
  FROM no_abstain_eval_params;

  PERFORM otlet.create_task(
    task_name_value,
    $source$
      SELECT 'no-abstain-positive'::text AS subject_id,
             '{"action_ids":{"left_id":"noab-left","right_id":"noab-right"}}'::jsonb AS input
      UNION ALL
      SELECT 'alias-match'::text AS subject_id,
             '{"action_ids":{"left_id":"alias-left","right_id":"alias-right"}}'::jsonb AS input
    $source$::text,
    'Return JSON only.',
    '{"type":"object","required":["match","confidence"],"additionalProperties":false,"properties":{"match":{"enum":["same_entity","different_entity"]},"confidence":{"enum":["high"]}}}'::jsonb,
    model_name_value,
    '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
  );

  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  VALUES (
    task_name_value,
    'no-abstain-positive',
    '{"action_ids":{"left_id":"noab-left","right_id":"noab-right"}}'::jsonb,
    'running',
    1,
    now(),
    now() + interval '5 minutes'
  )
  RETURNING id INTO positive_job_id;

  PERFORM otlet.complete_job(
    positive_job_id,
    '{"match":"same_entity","confidence":"high"}'::jsonb,
    '{"output":{"match":"same_entity","confidence":"high"},"actions":[{"type":"merge_candidate","body":{"left_id":"noab-left","right_id":"noab-right","confidence":"high","reason":"same"}}]}',
    '[{"type":"merge_candidate","body":{"left_id":"noab-left","right_id":"noab-right","confidence":"high","reason":"same"}}]'::jsonb,
    NULL,
    NULL,
    NULL,
    md5('{"output":{"match":"same_entity","confidence":"high"},"actions":[{"type":"merge_candidate","body":{"left_id":"noab-left","right_id":"noab-right","confidence":"high","reason":"same"}}]}'),
    now(),
    '{"schema_validation_status":"passed"}'::jsonb,
    model_name_value
  );

  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  VALUES (
    task_name_value,
    'alias-match',
    '{"action_ids":{"left_id":"alias-left","right_id":"alias-right"}}'::jsonb,
    'running',
    1,
    now(),
    now() + interval '5 minutes'
  )
  RETURNING id INTO alias_job_id;

  PERFORM otlet.complete_job(
    alias_job_id,
    '{"match":"same_entity","confidence":"high"}'::jsonb,
    '{"output":{"match":"same_entity","confidence":"high"},"actions":[{"type":"merge_candidate","body":{"left_id":"alias-left","right_id":"alias-right","confidence":"high","reason":"same"}}]}',
    '[{"type":"merge_candidate","body":{"left_id":"alias-left","right_id":"alias-right","confidence":"high","reason":"same"}}]'::jsonb,
    NULL,
    NULL,
    NULL,
    md5('{"output":{"match":"same_entity","confidence":"high"},"actions":[{"type":"merge_candidate","body":{"left_id":"alias-left","right_id":"alias-right","confidence":"high","reason":"same"}}]}'),
    now(),
    '{"schema_validation_status":"passed"}'::jsonb,
    model_name_value
  );

  SELECT a.id INTO positive_action_id
  FROM otlet.actions a
  WHERE a.job_id = positive_job_id
  ORDER BY a.id DESC
  LIMIT 1;
  PERFORM otlet.approve_action(positive_action_id);
  PERFORM otlet.label_action(positive_action_id, label_source => 'approved_action');

  SELECT a.id INTO alias_action_id
  FROM otlet.actions a
  WHERE a.job_id = alias_job_id
  ORDER BY a.id DESC
  LIMIT 1;
  PERFORM otlet.correct_action(
    alias_action_id,
    '{"match":"same_entity","confidence":"high","action_type":"merge_candidate"}'::jsonb,
    'alias key smoke'
  );

  INSERT INTO no_abstain_eval_result
  SELECT 'positive',
         COALESCE(max(case_kind), '') || '|' || COALESCE(max(expected_answer), '')
  FROM otlet.export_eval_cases(50)
  WHERE action_id = positive_action_id;

  INSERT INTO no_abstain_eval_result
  SELECT 'alias',
         COALESCE(max(label_source), '') || '|' ||
         COALESCE(max(expected_answer), '') || '|' ||
         COALESCE(max(expected_confidence), '') || '|' ||
         COALESCE(max(expected_action_type), '')
  FROM otlet.eval_label_status
  WHERE action_id = alias_action_id;
END;
$$;
SELECT (SELECT value FROM no_abstain_eval_result WHERE key = 'positive') || '|' ||
       (SELECT value FROM no_abstain_eval_result WHERE key = 'alias');
SQL
)"
echo "no_abstain_eval_contract=$no_abstain_eval_contract"
[ "$no_abstain_eval_contract" = "positive|same_entity|manual_correction|same_entity|high|merge_candidate" ] || {
  echo "Expected no-abstain eval export and match alias correction to work, got $no_abstain_eval_contract" >&2
  exit 1
}

row_watch_status_contract="$(psql_value "
SELECT watch_name || '|' || kind || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queued_jobs::text || '|' ||
       complete_jobs::text || '|' ||
       count_basis
FROM otlet.watch_status
WHERE watch_name = '$row_triage_watch';
")"
echo "row_watch_status_contract=$row_watch_status_contract"
[ "$row_watch_status_contract" = "$row_triage_watch|row|1|1|0|0|0|1|estimated" ] || {
  echo "Expected row watch status to show one fresh completed row, got $row_watch_status_contract" >&2
  exit 1
}
row_plan_basis_contract="$(psql_value "
SELECT count_basis || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text
FROM otlet.semantic_index_plan('$row_triage_watch');
SELECT count_basis || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text
FROM otlet.semantic_index_plan('$row_triage_watch', true);
")"
row_plan_estimated="$(head -n 1 <<<"$row_plan_basis_contract")"
row_plan_exact="$(tail -n 1 <<<"$row_plan_basis_contract")"
echo "row_plan_basis_contract=$row_plan_estimated|exact=$row_plan_exact"
[ "$row_plan_estimated|$row_plan_exact" = "estimated|1|1|0|0|exact|1|1|0|0" ] || {
  echo "Expected estimated and exact row plan counts to match on demo row, got $row_plan_estimated|$row_plan_exact" >&2
  exit 1
}
row_lookup_basis_contract="$(psql_value "
SELECT COALESCE(string_agg(freshness_basis, ',' ORDER BY subject_id), '')
FROM otlet.semantic_index_current_rows('$row_triage_watch', true);
")"
echo "row_lookup_basis_contract=$row_lookup_basis_contract"
[ "$row_lookup_basis_contract" = "mvcc_match" ] || {
  echo "Expected unchanged row lookup to report mvcc_match freshness basis, got $row_lookup_basis_contract" >&2
  exit 1
}
row_fresh_customscan_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_triage_signal
WHERE otlet.semantic_matches_auto('$row_triage_watch', id, '{"decision":"flag"}'::jsonb);
SQL
)"
printf '%s\n' "$row_fresh_customscan_plan"
require_contains "$row_fresh_customscan_plan" "Otlet Node: Semantic Source CustomScan" "Expected fresh CustomScan explain details"
require_contains "$row_fresh_customscan_plan" "Planner Selected Path: semantic_lookup" "Expected fresh CustomScan lookup path"
require_contains "$row_fresh_customscan_plan" "Count Basis: exact" "Expected fresh CustomScan exact count basis"
require_contains "$row_fresh_customscan_plan" "Model Cost Source:" "Expected fresh CustomScan model cost source"
require_contains "$row_fresh_customscan_plan" "Preloaded Fresh Subjects / Basis: 1" "Expected fresh CustomScan preload count and basis"
require_contains "$row_fresh_customscan_plan" "Emitted Freshness Basis:" "Expected fresh CustomScan emitted freshness basis breakdown"
require_contains "$row_fresh_customscan_plan" "Rows Returned: 1" "Expected fresh CustomScan returned row"
require_contains "$row_fresh_customscan_plan" "Actual Fresh Subjects: 1" "Expected fresh CustomScan fresh count"
require_contains "$row_fresh_customscan_plan" "Actual Stale Subjects: 0" "Expected fresh CustomScan stale count"
require_contains "$row_fresh_customscan_plan" "Infer Now Batches: 0" "Expected fresh CustomScan zero infer-now"
require_contains "$row_fresh_customscan_plan" "Infer Now Receipts: 0" "Expected fresh CustomScan zero infer-now receipts"

log "Checking visible row update freshness"
row_receipts_before_visible_update="$(psql_value "
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = '$row_triage_task';
")"
row_visible_stale_contract="$(psql_value "
BEGIN;
UPDATE public.otlet_demo_triage_signal
SET blockers = 0,
    approvals = 1,
    evidence = 'Updated review cleared the blocker and recorded manager approval'
WHERE id = 'triage-1';
SELECT count(*)::text
FROM otlet.semantic_index_current_rows('$row_triage_watch', true);
SELECT (count(*) FILTER (WHERE stale AND stale_reason = 'source_update') >= 1)::text
FROM otlet.semantic_materializations
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1';
SELECT otlet.semantic_matches('$row_triage_watch', 'triage-1', '{\"decision\":\"flag\"}'::jsonb)::text;
SELECT count(*)::text
FROM otlet.semantic_index_current_rows('$row_triage_watch', true)
WHERE subject_id = 'triage-1';
SAVEPOINT pending_reason_probe;
UPDATE otlet.semantic_materializations
SET stale_reason = NULL
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1';
SELECT COALESCE(stale_reasons->>'content_revalidation_pending', '0')
FROM otlet.semantic_index_plan('$row_triage_watch', true);
ROLLBACK TO SAVEPOINT pending_reason_probe;
COMMIT;
")"
row_visible_fresh_before="$(head -n 1 <<<"$row_visible_stale_contract")"
row_visible_source_update="$(sed -n '2p' <<<"$row_visible_stale_contract")"
row_visible_predicate_match="$(sed -n '3p' <<<"$row_visible_stale_contract")"
row_visible_fdw_rows="$(sed -n '4p' <<<"$row_visible_stale_contract")"
row_pending_reason="$(sed -n '5p' <<<"$row_visible_stale_contract")"
echo "row_visible_update_stale_contract=$row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_fdw_rows"
[ "$row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_fdw_rows" = "0|true|false|0" ] || {
  echo "Expected visible row update to fail closed across lookup surfaces, got $row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_fdw_rows" >&2
  exit 1
}
echo "row_content_revalidation_pending_contract=$row_pending_reason"
[ "$row_pending_reason" = "1" ] || {
  echo "Expected stale current row with no stored reason to expose content_revalidation_pending, got $row_pending_reason" >&2
  exit 1
}
wait_task_complete "$row_triage_task" 2 900 1
row_visible_refresh_contract="$(psql_value "
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = '$row_triage_task';
SELECT count(*)::text
FROM otlet.semantic_index_current_rows('$row_triage_watch', true);
")"
row_receipts_after_visible_update="$(head -n 1 <<<"$row_visible_refresh_contract")"
row_visible_fresh_after="$(tail -n 1 <<<"$row_visible_refresh_contract")"
row_visible_receipt_delta=$((row_receipts_after_visible_update - row_receipts_before_visible_update))
echo "row_visible_update_refresh_contract=$row_visible_receipt_delta|$row_visible_fresh_after"
[ "$row_visible_receipt_delta|$row_visible_fresh_after" = "1|1" ] || {
  echo "Expected visible row update to produce exactly one receipt and one fresh row, got $row_visible_receipt_delta|$row_visible_fresh_after" >&2
  exit 1
}

log "Checking content-keyed inference cache on row revert"
psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_demo_triage_signal
SET blockers = 2,
    approvals = 0,
    evidence = 'Wire instructions changed after invoice approval and the requester used urgent payment language'
WHERE id = 'triage-1';
SQL
psql_exec >/dev/null <<SQL
INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT
  '$row_triage_task',
  (src.id)::text,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_triage_signal',
      'subject_id', (src.id)::text,
      'ctid', src.ctid::text,
      'xmin', src.xmin::text
    ),
    'table', 'public.otlet_demo_triage_signal',
    'row', otlet.semantic_project_row(to_jsonb(src), NULL::text[])
  )
FROM public.otlet_demo_triage_signal AS src
WHERE src.id = 'triage-1';
SELECT otlet.wake_worker();
SQL
wait_task_complete "$row_triage_task" 3 900 1
row_cache_revert_contract="$(psql_value "
SELECT inference_cache_hit::text || '|' ||
       COALESCE(inference_cache_reason, '') || '|' ||
       COALESCE(inference_cache_key_basis, '') || '|' ||
       COALESCE(inference_cache_eviction_reason, '')
FROM otlet.inference_receipt_trace_status
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1'
  AND status = 'complete'
ORDER BY receipt_id DESC
LIMIT 1;
SELECT count(*)::text
FROM otlet.semantic_index_current_rows('$row_triage_watch', true);
")"
row_cache_revert_trace="$(head -n 1 <<<"$row_cache_revert_contract")"
row_cache_revert_fresh="$(tail -n 1 <<<"$row_cache_revert_contract")"
echo "row_cache_revert_contract=$row_cache_revert_trace|fresh=$row_cache_revert_fresh"
[ "$row_cache_revert_trace|$row_cache_revert_fresh" = "true|hit|content_hash_contract_hash_model_fingerprint|none|1" ] || {
  echo "Expected reverted row content to hit inference cache and remain fresh, got $row_cache_revert_trace|$row_cache_revert_fresh" >&2
  exit 1
}

log "Checking contract-change inference cache miss"
psql_exec >/dev/null <<SQL
WITH current_task AS (
  SELECT *
  FROM otlet.tasks
  WHERE name = '$row_triage_task'
)
SELECT (otlet.create_task(
    name,
    input_query,
    instruction || ' Cache contract drift demo $script_started.',
    output_schema,
    model_name,
    runtime_options,
    input_shaping,
    decision_contract
  )).name
FROM current_task;

INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT
  '$row_triage_task',
  (src.id)::text,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_triage_signal',
      'subject_id', (src.id)::text,
      'ctid', src.ctid::text,
      'xmin', src.xmin::text
    ),
    'table', 'public.otlet_demo_triage_signal',
    'row', otlet.semantic_project_row(to_jsonb(src), NULL::text[])
  )
FROM public.otlet_demo_triage_signal AS src
WHERE src.id = 'triage-1';
SELECT otlet.wake_worker();
SQL
wait_task_complete "$row_triage_task" 4 900 1
row_contract_cache_contract="$(psql_value "
SELECT inference_cache_hit::text || '|' ||
       COALESCE(inference_cache_reason, '') || '|' ||
       COALESCE(inference_cache_key_basis, '')
FROM otlet.inference_receipt_trace_status
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1'
  AND status = 'complete'
ORDER BY receipt_id DESC
LIMIT 1;
")"
echo "row_contract_cache_contract=$row_contract_cache_contract"
[ "$row_contract_cache_contract" = "false|contract_changed|content_hash_contract_hash_model_fingerprint" ] || {
  echo "Expected contract edit to miss inference cache with contract_changed reason, got $row_contract_cache_contract" >&2
  exit 1
}

row_manual_reason_contract="$(psql_value "
SELECT (otlet.mark_semantic_stale(NULL, 'triage-1', 'manual') >= 1)::text;
SELECT (count(*) FILTER (WHERE stale AND stale_reason = 'manual') >= 1)::text
FROM otlet.semantic_materializations
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1';
")"
row_manual_marked="$(head -n 1 <<<"$row_manual_reason_contract")"
row_manual_reason="$(tail -n 1 <<<"$row_manual_reason_contract")"
echo "row_manual_reason_contract=$row_manual_marked|$row_manual_reason"
[ "$row_manual_marked|$row_manual_reason" = "true|true" ] || {
  echo "Expected manual mark to expose manual stale reason, got $row_manual_marked|$row_manual_reason" >&2
  exit 1
}

log "Checking row delete freshness"
psql_exec >/dev/null <<'SQL'
DELETE FROM public.otlet_demo_triage_signal
WHERE id = 'triage-1';
SQL
row_delete_contract="$(psql_value "
SELECT count(*)::text
FROM otlet.semantic_index_current_rows('$row_triage_watch', true);
SELECT (count(*) FILTER (WHERE stale AND stale_reason = 'source_delete') >= 1)::text
FROM otlet.semantic_materializations
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1';
")"
row_delete_fresh="$(head -n 1 <<<"$row_delete_contract")"
row_delete_reason="$(tail -n 1 <<<"$row_delete_contract")"
echo "row_delete_contract=$row_delete_fresh|$row_delete_reason"
[ "$row_delete_fresh|$row_delete_reason" = "0|true" ] || {
  echo "Expected row delete to fail closed with source_delete reason, got $row_delete_fresh|$row_delete_reason" >&2
  exit 1
}

psql_exec -v task_name="$row_triage_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
CREATE TEMP TABLE row_triage_invalid_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  VALUES (
    :'task_name',
    'triage-invalid-json',
    '{"row":{"id":"triage-invalid-json","blockers":1,"approvals":0,"evidence":"invalid model answer smoke"}}'::jsonb,
    'running',
    1,
    now(),
    now() + interval '5 minutes'
  )
  RETURNING id
)
SELECT id FROM inserted;

SELECT otlet.fail_job(
  id,
  'invalid model JSON: expected object',
  'not json',
  NULL,
  NULL,
  md5('{"type":"object","required":["decision","confidence","reason"]}'),
  md5('not json'),
  now(),
  'failed',
  '{"schema_validation_status":"failed"}'::jsonb,
  :'model_name',
  'direct',
  'failed',
  'invalid_model_json'
)
FROM row_triage_invalid_claim;
SQL
row_triage_invalid_contract="$(psql_value "
SELECT j.status || '|' ||
       (j.error LIKE 'invalid model JSON:%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.schema_validation_status || '|' ||
       (r.raw_output_hash = md5('not json'))::text || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       (SELECT count(*) FROM otlet.actions WHERE job_id = j.id)::text || '|' ||
       (
         SELECT count(*)::text
         FROM otlet.semantic_materializations sm
         JOIN otlet.records rec ON rec.id = sm.record_id
         JOIN otlet.actions act ON act.id = rec.action_id
         WHERE act.job_id = j.id
       )
FROM otlet.jobs j
JOIN otlet.inference_receipts r ON r.job_id = j.id
WHERE j.task_name = '$row_triage_task'
  AND j.subject_id = 'triage-invalid-json'
ORDER BY j.id DESC, r.id DESC
LIMIT 1;
")"
echo "row_triage_invalid_answer_contract=$row_triage_invalid_contract"
[ "$row_triage_invalid_contract" = "failed|true|failed|failed|failed|true|0|0|0" ] || {
  echo "Expected invalid non-ER model answer to leave only a failed receipt, got $row_triage_invalid_contract" >&2
  exit 1
}


source "$demo_dir/customscan.sh"

log "Running non-ER triage selection policy"
psql_exec \
  -v cheap_policy_model="$strong_model_name" \
  -v strong_policy_model="$strong_alias_model_name" \
  -v row_triage_policy_watch="$row_triage_policy_watch" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_triage_policy_signal;
CREATE TABLE public.otlet_demo_triage_policy_signal (
  id text PRIMARY KEY,
  blockers integer NOT NULL,
  approvals integer NOT NULL,
  evidence text NOT NULL
);

SELECT otlet.create_watch(
  :'row_triage_policy_watch',
  'row',
  'Classify one operational row. Use input.row.blockers and input.row.approvals. If blockers > 0, output decision flag with confidence high and one review_flag action. If blockers = 0 and approvals > 0, output decision pass with confidence high and no actions. Otherwise output decision unclear with confidence medium and one review_flag action with severity medium and a short reason. Return JSON only.',
  '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["flag", "pass", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 160}
    }
  }'::jsonb,
  :'cheap_policy_model',
  'public.otlet_demo_triage_policy_signal'::regclass,
  'id',
  NULL,
  'demo_triage_policy_fact',
  '{"max_tokens":160,"reasoning":"off","inference_cache":true}'::jsonb,
  jsonb_build_object(
    'cheap_model_name', :'cheap_policy_model',
    'strong_model_name', :'strong_policy_model'
  ),
  '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  ARRAY['review_flag'],
  'refresh_then_fail_closed',
  '{}'::jsonb,
  '{"preset":"row_triage_decision_v1"}'::jsonb
);

INSERT INTO public.otlet_demo_triage_policy_signal
VALUES (
  'triage-unclear',
  0,
  0,
  'No decisive blocker and no approval evidence; send to human review'
);
SQL
wait_task_complete "$row_triage_policy_task" 1 900 1

row_triage_policy_contract="$(psql_value "
WITH attempts AS (
  SELECT selection_role, selection_status, selection_reason
  FROM otlet.model_selection_attempts
  WHERE task_name = '$row_triage_policy_task'
)
SELECT
  (SELECT count(*) FROM attempts WHERE selection_role = 'cheap' AND selection_status = 'rejected' AND selection_reason = 'abstained_output')::text || '|' ||
  (SELECT count(*) FROM attempts WHERE selection_role = 'strong' AND selection_status = 'accepted')::text || '|' ||
  COALESCE((SELECT output->>'decision' FROM otlet.runs WHERE task_name = '$row_triage_policy_task'), '') || '|' ||
  (SELECT count(*) FROM otlet.action_status WHERE task_name = '$row_triage_policy_task' AND action_type = 'review_flag')::text;
")"
echo "row_triage_policy_contract=$row_triage_policy_contract"
[ "$row_triage_policy_contract" = "1|1|unclear|1" ] || {
  echo "Expected declared triage policy to reject cheap unclear then accept strong unclear with one review action, got $row_triage_policy_contract" >&2
  exit 1
}
row_triage_preset_contract="$(psql_value "
SELECT COALESCE(t.decision_contract ->> 'preset', '') || '|' ||
       ((t.decision_contract ->> 'preset_contract_hash') ~ '^[0-9a-f]{32}$')::text || '|' ||
       COALESCE(p.accept_field_checks ->> 'answer_field', '') || '|' ||
       (p.accept_field_checks -> 'abstain_values' ? 'unclear')::text || '|' ||
       (p.accept_field_checks -> 'accepted_confidence' ? 'medium')::text
FROM otlet.tasks t
JOIN otlet.model_selection_policies p ON p.task_name = t.name
WHERE t.name = '$row_triage_policy_task';
")"
echo "row_triage_preset_contract=$row_triage_preset_contract"
[ "$row_triage_preset_contract" = "row_triage_decision_v1|true|decision|true|true" ] || {
  echo "Expected triage preset to drive selection policy labels, got $row_triage_preset_contract" >&2
  exit 1
}
set +e
model_selection_shape_output="$(
  psql_exec -qAt \
    -v task_name="$row_triage_policy_task" \
    -v cheap_policy_model="$strong_model_name" \
    -v strong_policy_model="$strong_alias_model_name" 2>&1 <<'SQL'
SELECT otlet.set_model_selection_policy(
  :'task_name',
  :'cheap_policy_model',
  :'strong_policy_model',
  '{"abstain_values":["unclear"]}'::jsonb
);
SQL
)"
model_selection_shape_status=$?
set -e
if [ "$model_selection_shape_status" -eq 0 ]; then
  echo "Expected orphan abstain_values policy to be rejected" >&2
  exit 1
fi
require_contains "$model_selection_shape_output" "otlet accept_field_checks.abstain_values requires answer_field" "Expected orphan abstain_values rejection message"
echo "model_selection_shape_contract=rejected"
row_triage_preset_trace_contract="$(psql_value "
SELECT COALESCE(s.decision_preset_name, '') || '|' ||
       (s.decision_preset_contract_hash = t.decision_contract ->> 'preset_contract_hash')::text || '|' ||
       (s.decision_preset_contract_hash = md5(otlet.semantic_canonical_jsonb(p.decision_contract)::text))::text
FROM otlet.inference_receipt_trace_status s
JOIN otlet.tasks t ON t.name = s.task_name
JOIN otlet.decision_rule_presets p ON p.name = s.decision_preset_name
WHERE s.task_name = '$row_triage_policy_task'
  AND s.selection_role = 'strong'
  AND s.selection_status = 'accepted'
ORDER BY s.receipt_id DESC
LIMIT 1;
")"
echo "row_triage_preset_trace_contract=$row_triage_preset_trace_contract"
[ "$row_triage_preset_trace_contract" = "row_triage_decision_v1|true|true" ] || {
  echo "Expected receipt trace status to expose row triage preset provenance, got $row_triage_preset_trace_contract" >&2
  exit 1
}
preset_immutability_contract="$(
  psql_exec -qAt <<'SQL'
DO $$
BEGIN
  UPDATE otlet.decision_rule_presets
  SET decision_contract = decision_contract || '{"demo_edit":true}'::jsonb
  WHERE name = 'row_triage_decision_v1';
  RAISE EXCEPTION 'expected preset update to be rejected';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'otlet decision rule preset row_triage_decision_v1 is immutable%' THEN
      RAISE;
    END IF;
END;
$$;
SELECT 'raised';
SQL
)"
echo "preset_immutability_contract=$preset_immutability_contract"
[ "$preset_immutability_contract" = "raised" ] || {
  echo "Expected decision rule preset updates to be rejected, got $preset_immutability_contract" >&2
  exit 1
}
row_triage_abstention_contract="$(psql_value "
WITH task_abstentions AS (
  SELECT count(*)::bigint AS abstained_outputs
  FROM otlet.outputs o
  JOIN otlet.jobs j ON j.id = o.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
  CROSS JOIN LATERAL (
    SELECT COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match') AS answer_field,
           COALESCE(t.decision_contract -> 'abstain_values', '[]'::jsonb) AS abstain_values
  ) contract
  WHERE j.task_name = '$row_triage_policy_task'
    AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(contract.abstain_values) value(abstain_value)
      WHERE o.output ->> contract.answer_field = value.abstain_value
    )
)
SELECT task_abstentions.abstained_outputs::text || '|' ||
       output_reliability_status.abstained_outputs::text
FROM task_abstentions
CROSS JOIN otlet.output_reliability_status;
")"
echo "row_triage_abstention_contract=$row_triage_abstention_contract"
require_regex "$row_triage_abstention_contract" '^[1-9][0-9]*\|[1-9][0-9]*$' "Expected nonzero abstention counters for the triage preset"

psql_exec \
  -v task_name="$skip_abstain_task" \
  -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'skip-1'::text AS subject_id,
           '{"row":{"note":"no evidence available"}}'::jsonb AS input
  $source$::text,
  'Return decision skip with confidence medium and no actions. Return JSON only.',
  '{"type":"object","required":["decision","confidence"],"additionalProperties":false,"properties":{"decision":{"enum":["skip"]},"confidence":{"enum":["medium"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":64,"reasoning":"off","inference_cache":false}'::jsonb,
  '{}'::jsonb,
  '{"answer_field":"decision","abstain_values":["skip"],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_complete "$skip_abstain_task" 1 900 1
skip_abstention_contract="$(psql_value "
WITH task_abstentions AS (
  SELECT count(*)::bigint AS abstained_outputs
  FROM otlet.outputs o
  JOIN otlet.jobs j ON j.id = o.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
  CROSS JOIN LATERAL (
    SELECT COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match') AS answer_field,
           COALESCE(t.decision_contract -> 'abstain_values', '[]'::jsonb) AS abstain_values
  ) contract
  WHERE j.task_name = '$skip_abstain_task'
    AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(contract.abstain_values) value(abstain_value)
      WHERE o.output ->> contract.answer_field = value.abstain_value
    )
)
SELECT task_abstentions.abstained_outputs::text || '|' ||
       (output_reliability_status.abstained_outputs >= task_abstentions.abstained_outputs)::text
FROM task_abstentions
CROSS JOIN otlet.output_reliability_status;
")"
echo "skip_abstention_contract=$skip_abstention_contract"
[ "$skip_abstention_contract" = "1|true" ] || {
  echo "Expected non-default skip abstention vocabulary to count, got $skip_abstention_contract" >&2
  exit 1
}
