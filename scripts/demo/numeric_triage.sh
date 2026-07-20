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
numeric_triage_action_id="$(psql_exec -qAt -v task_name="$numeric_triage_task" <<'SQL'
SELECT min(action_id)
FROM otlet.action_status
WHERE task_name = :'task_name'
  AND action_type = 'review_flag'
  AND error IS NULL;
SQL
)"
[ -n "$numeric_triage_action_id" ] || {
  echo "Expected numeric triage review_flag action" >&2
  exit 1
}
numeric_triage_contract="$(psql_exec -qAt -v task_name="$numeric_triage_task" <<'SQL'
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
WHERE r.task_name = :'task_name'
ORDER BY r.job_id DESC
LIMIT 1;
SQL
)"
echo "numeric_triage_contract=$numeric_triage_contract"
[ "$numeric_triage_contract" = "complete|flag|high|true|true|review_flag|true|true|review_flag" ] || {
  echo "Expected numeric triage surfaces to render without NULL surprises, got $numeric_triage_contract" >&2
  exit 1
}
psql_exec -v action_id="$numeric_triage_action_id" >/dev/null <<'SQL'
SELECT * FROM otlet.label_action(:'action_id'::bigint, label_source => 'approved_action');
SQL
numeric_triage_label_contract="$(psql_exec -qAt -v action_id="$numeric_triage_action_id" <<'SQL'
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
       COALESCE(max(exported.expected_action_type), '') || '|' ||
       COALESCE(max(exported.case_kind), '')
FROM status, exported;
SQL
)"
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

row_status_plan_contracts="$(psql_value -v watch_name="$row_triage_watch" <<'SQL'
SELECT
  (
    SELECT watch_name || '|' || kind || '|' ||
           total_subjects::text || '|' ||
           fresh_subjects::text || '|' ||
           stale_subjects::text || '|' ||
           missing_subjects::text || '|' ||
           queued_jobs::text || '|' ||
           complete_jobs::text || '|' ||
           count_basis
    FROM otlet.watch_status
    WHERE watch_name = :'watch_name'
  ) || E'\n' ||
  (
    SELECT count_basis || '|' ||
           total_subjects::text || '|' ||
           fresh_subjects::text || '|' ||
           stale_subjects::text || '|' ||
           missing_subjects::text
    FROM otlet.semantic_index_plan(:'watch_name')
  ) || E'\n' ||
  (
    SELECT count_basis || '|' ||
           total_subjects::text || '|' ||
           fresh_subjects::text || '|' ||
           stale_subjects::text || '|' ||
           missing_subjects::text
    FROM otlet.semantic_index_plan(:'watch_name', true)
  );
SQL
)"
row_watch_status_contract="$(sed -n '1p' <<<"$row_status_plan_contracts")"
row_plan_estimated="$(sed -n '2p' <<<"$row_status_plan_contracts")"
row_plan_exact="$(sed -n '3p' <<<"$row_status_plan_contracts")"
echo "row_watch_status_contract=$row_watch_status_contract"
[ "$row_watch_status_contract" = "$row_triage_watch|row|1|1|0|0|0|1|estimated" ] || {
  echo "Expected row watch status to show one fresh completed row, got $row_watch_status_contract" >&2
  exit 1
}
echo "row_plan_basis_contract=$row_plan_estimated|exact=$row_plan_exact"
[ "$row_plan_estimated|$row_plan_exact" = "estimated|1|1|0|0|exact|1|1|0|0" ] || {
  echo "Expected estimated and exact row plan counts to match on demo row, got $row_plan_estimated|$row_plan_exact" >&2
  exit 1
}
row_lookup_basis_contract="$(psql_exec -qAt -v watch_name="$row_triage_watch" <<'SQL'
SELECT COALESCE(string_agg(freshness_basis, ',' ORDER BY subject_id), '')
FROM otlet.semantic_index_current_rows(:'watch_name', true);
SQL
)"
echo "row_lookup_basis_contract=$row_lookup_basis_contract"
[ "$row_lookup_basis_contract" = "mvcc_match" ] || {
  echo "Expected unchanged row lookup to report mvcc_match freshness basis, got $row_lookup_basis_contract" >&2
  exit 1
}
row_fresh_customscan_plan="$(
  psql_exec -P border=2 -P null='' -v watch_name="$row_triage_watch" <<'SQL'
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_triage_signal
WHERE otlet.semantic_matches_auto(:'watch_name', id, '{"decision":"flag"}'::jsonb);
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

