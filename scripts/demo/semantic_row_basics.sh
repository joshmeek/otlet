log "Checking pair strip-key freshness"
psql_candidate_exec \
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
pair_strip_receipts_before="$(psql_exec -qAt -v task_name="$pair_strip_task" <<'SQL'
SELECT count(*)
FROM otlet.inference_receipts r
JOIN otlet.jobs j ON j.id = r.job_id
WHERE j.task_name = :'task_name';
SQL
)"
psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_demo_pair_strip
SET volatile_note = 'second volatile note'
WHERE id = 'pair-strip-1';
SQL
pair_strip_contract="$(psql_exec -qAt \
  -v task_name="$pair_strip_task" \
  -v watch_name="$pair_strip_watch" \
  -v receipts_before="$pair_strip_receipts_before" <<'SQL'
WITH live AS (
  SELECT input
  FROM public.otlet_demo_pair_strip_input
  WHERE subject_id = 'pair-strip-1'
), materialized AS (
  SELECT sm.source_hash
  FROM otlet.semantic_materializations sm
  WHERE sm.task_name = :'task_name'
    AND sm.subject_id = 'pair-strip-1'
  ORDER BY sm.updated_at DESC, sm.id DESC
  LIMIT 1
)
SELECT (SELECT count(*) FROM otlet.semantic_join_index_current_rows(:'watch_name', true))::text || '|' ||
       (SELECT stale_subjects::text FROM otlet.semantic_join_index_plan(:'watch_name', true)) || '|' ||
       (SELECT (materialized.source_hash IS DISTINCT FROM md5(live.input::text))::text FROM materialized, live) || '|' ||
       :'receipts_before' || '|' ||
       (
         SELECT count(*)::text
         FROM otlet.inference_receipts r
         JOIN otlet.jobs j ON j.id = r.job_id
         WHERE j.task_name = :'task_name'
       );
SQL
)"
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

row_triage_contract="$(psql_exec -qAt -v task_name="$row_triage_task" <<'SQL'
SELECT count(DISTINCT r.job_id) FILTER (WHERE r.status = 'complete')::text || '|' ||
       COALESCE(max(r.output->>'decision'), '') || '|' ||
       COALESCE(max(r.output->>'confidence'), '') || '|' ||
       count(a.action_id) FILTER (WHERE a.action_type = 'review_flag')::text || '|' ||
       count(a.action_id) FILTER (WHERE a.action_type = 'review_flag' AND a.error IS NULL)::text || '|' ||
       (
         SELECT (count(*) FILTER (WHERE s.freshness_basis = 'content_hash_match') >= 1)::text
         FROM otlet.inference_receipt_trace_status s
         WHERE s.task_name = :'task_name'
           AND s.accepted
       )
FROM otlet.runs r
LEFT JOIN otlet.action_status a ON a.job_id = r.job_id
WHERE r.task_name = :'task_name';
SQL
)"
echo "row_triage_contract=$row_triage_contract"
[ "$row_triage_contract" = "1|flag|high|1|1|true" ] || {
  echo "Expected non-ER triage task to produce one flagged output and one valid review action, got $row_triage_contract" >&2
  exit 1
}

row_triage_action_id="$(psql_exec -qAt -v task_name="$row_triage_task" <<'SQL'
SELECT min(action_id)
FROM otlet.action_status
WHERE task_name = :'task_name'
  AND action_type = 'review_flag'
  AND error IS NULL;
SQL
)"
[ -n "$row_triage_action_id" ] || {
  echo "Expected row triage review action id" >&2
  exit 1
}
psql_exec -v action_id="$row_triage_action_id" >/dev/null <<'SQL'
SELECT * FROM otlet.label_action(:'action_id'::bigint, label_source => 'approved_action');
SQL
row_eval_label_contract="$(psql_exec -qAt -v action_id="$row_triage_action_id" <<'SQL'
WITH status AS (
  SELECT *
  FROM otlet.eval_label_status
  WHERE action_id = :'action_id'::bigint
), exported AS (
  SELECT *
  FROM otlet.export_eval_cases(50)
  WHERE action_id = :'action_id'::bigint
)
SELECT count(*)::text || '|' ||
       COALESCE(max(status.expected_answer), '') || '|' ||
       COALESCE(max(status.observed_answer), '') || '|' ||
       COALESCE(max(exported.expected_answer), '') || '|' ||
       COALESCE(max(exported.case_kind), '')
FROM status, exported;
SQL
)"
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

row_review_queue_contract="$(psql_exec -qAt -v action_id="$row_triage_action_id" <<'SQL'
SELECT count(*)::text || '|' ||
       COALESCE(max(queue_kind), '') || '|' ||
       COALESCE(max(watch_name), '') || '|' ||
       COALESCE(max(source_stale::text), '') || '|' ||
       (max(receipt_id) IS NOT NULL)::text
FROM otlet.review_queue
WHERE action_id = :'action_id'::bigint;
SQL
)"
echo "row_review_queue_contract=$row_review_queue_contract"
[ "$row_review_queue_contract" = "1|review_flag|$row_triage_watch|false|true" ] || {
  echo "Expected row review action in review_queue with receipt and fresh source identity, got $row_review_queue_contract" >&2
  exit 1
}
psql_exec -v action_id="$row_triage_action_id" >/dev/null <<'SQL'
SELECT * FROM otlet.correct_action(
  :'action_id'::bigint,
  '{"decision":"pass","confidence":"high","action_type":"review_flag"}'::jsonb,
  'demo correction'
);
SQL
row_correction_contract="$(psql_exec -qAt -v action_id="$row_triage_action_id" <<'SQL'
SELECT a.status || '|' ||
       a.approval_status || '|' ||
       (SELECT count(*) FROM otlet.eval_labels WHERE action_id = :'action_id'::bigint AND label_source = 'manual_correction')::text || '|' ||
       (SELECT count(*) FROM otlet.export_eval_cases(50) WHERE action_id = :'action_id'::bigint AND case_kind = 'gold')::text || '|' ||
       (SELECT count(*) FROM otlet.review_queue WHERE action_id = :'action_id'::bigint)::text
FROM otlet.actions a
WHERE a.id = :'action_id'::bigint;
SQL
)"
echo "row_correction_contract=$row_correction_contract"
[ "$row_correction_contract" = "rejected|rejected|1|1|0" ] || {
  echo "Expected correction to reject action, write gold label, and remove review queue row, got $row_correction_contract" >&2
  exit 1
}
