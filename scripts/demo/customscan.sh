log "Checking column-scoped row freshness"
psql_exec \
  -v model_name="$strong_model_name" \
  -v row_scoped_watch="$row_scoped_watch" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_scoped_signal;
CREATE TABLE public.otlet_demo_scoped_signal (
  id text PRIMARY KEY,
  signal text NOT NULL,
  ignored_note text NOT NULL
);

SELECT otlet.create_watch(
  watch_name => :'row_scoped_watch',
  kind => 'row',
  instruction => 'Classify one scoped row. Use only input.row.signal. If signal is approve, output decision pass with confidence high. Otherwise output decision flag with confidence high. Return JSON only.',
  output_schema => '{
    "type": "object",
    "required": ["decision", "confidence"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["pass", "flag"]},
      "confidence": {"enum": ["low", "medium", "high"]}
    }
  }'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_demo_scoped_signal'::regclass,
  subject_column => 'id',
  record_type => 'demo_scoped_fact',
  runtime_options => '{"max_tokens":120,"reasoning":"off","inference_cache":true}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  decision_contract => '{"answer_field":"decision","abstain_values":[],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb,
  input_columns => ARRAY['signal']
);

INSERT INTO public.otlet_demo_scoped_signal
VALUES ('scoped-1', 'approve', 'initial note outside the model input');

SELECT otlet.run_task(:'row_scoped_watch' || '_task');
SQL
wait_task_complete "$row_scoped_task" 1 900 1
row_scoped_receipts_before="$(psql_exec -qAt -v task_name="$row_scoped_task" <<'SQL'
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = :'task_name';
SQL
)"
psql_exec >/dev/null <<'SQL'
ALTER TABLE public.otlet_demo_scoped_signal
ADD COLUMN unrelated_after_watch text DEFAULT 'not in model input';
UPDATE public.otlet_demo_scoped_signal
SET ignored_note = ignored_note || '; changed outside scoped input',
    unrelated_after_watch = 'changed after watch'
WHERE id = 'scoped-1';
SQL
row_scoped_contract="$(psql_value \
  -v watch_name="$row_scoped_watch" \
  -v task_name="$row_scoped_task" <<'SQL'
WITH cur AS (
  SELECT subject_id, freshness_basis
  FROM otlet.semantic_index_current_rows(:'watch_name', true)
)
SELECT
  (SELECT count(*)::text FROM cur) || '|' ||
  otlet.semantic_matches(:'watch_name', 'scoped-1', '{"decision":"pass"}'::jsonb)::text || '|' ||
  (
    SELECT count(*)::text
    FROM otlet.inference_receipts ar
    JOIN otlet.jobs j ON j.id = ar.job_id
    WHERE j.task_name = :'task_name'
  ) || '|' ||
  (
    SELECT COALESCE(input_columns::text, '')
    FROM otlet.watch_status
    WHERE watch_name = :'watch_name'
  ) || '|' ||
  (SELECT COALESCE(string_agg(freshness_basis, ',' ORDER BY subject_id), '') FROM cur);
SQL
)"
IFS='|' read -r row_scoped_fresh_after row_scoped_match_after row_scoped_receipts_after row_scoped_columns row_scoped_basis <<<"$row_scoped_contract"
echo "row_scoped_contract=$row_scoped_fresh_after|$row_scoped_match_after|$row_scoped_receipts_before|$row_scoped_receipts_after|$row_scoped_columns|$row_scoped_basis"
[ "$row_scoped_fresh_after|$row_scoped_match_after|$row_scoped_receipts_before|$row_scoped_receipts_after|$row_scoped_columns|$row_scoped_basis" = "1|true|1|1|{signal}|revalidated_after_benign_update" ] || {
  echo "Expected scoped watch to stay fresh with unchanged receipts and revalidated basis after unrelated column change, got $row_scoped_fresh_after|$row_scoped_match_after|$row_scoped_receipts_before|$row_scoped_receipts_after|$row_scoped_columns|$row_scoped_basis" >&2
  exit 1
}
row_scoped_sql_contract="$(psql_value -v watch_name="$row_scoped_watch" <<'SQL'
WITH cur AS (
  SELECT subject_id
  FROM otlet.semantic_index_current_rows(:'watch_name', true)
)
SELECT
  (SELECT count(*)::text FROM cur WHERE subject_id = 'scoped-1') || E'\n' ||
  (
    SELECT selected_path || '|' ||
           total_subjects::text || '|' ||
           fresh_subjects::text || '|' ||
           stale_subjects::text || '|' ||
           queue_subjects::text || '|' ||
           count_basis
    FROM otlet.semantic_index_plan(:'watch_name', true)
  ) || E'\n' ||
  (SELECT count(*)::text FROM cur WHERE subject_id = ANY (ARRAY[]::text[]));
SQL
)"
row_scoped_subject_rows="$(sed -n '1p' <<<"$row_scoped_sql_contract")"
row_scoped_plan="$(sed -n '2p' <<<"$row_scoped_sql_contract")"
row_empty_subject_rows="$(sed -n '3p' <<<"$row_scoped_sql_contract")"
echo "row_scoped_sql_contract=$row_scoped_subject_rows|$row_scoped_plan|$row_empty_subject_rows"
[ "$row_scoped_subject_rows|$row_empty_subject_rows" = "1|0" ] || {
  echo "Expected current-row SQL subject and empty-subject filters to return 1|0, got $row_scoped_subject_rows|$row_empty_subject_rows" >&2
  exit 1
}
require_regex "$row_scoped_plan" '^semantic_lookup\|1\|1\|0\|0\|' "Expected row scoped SQL plan lookup with one fresh subject"
psql_exec >/dev/null <<'SQL'
ALTER TABLE public.otlet_demo_scoped_signal
DROP COLUMN signal;
SQL
row_schema_drift_contract="$(psql_exec -qAt \
  -v watch_name="$row_scoped_watch" \
  -v task_name="$row_scoped_task" <<'SQL'
SELECT count(*)::text
FROM otlet.semantic_index_current_rows(:'watch_name', true);
SELECT (count(*) FILTER (WHERE stale AND stale_reason = 'schema_drift') >= 1)::text
FROM otlet.semantic_materializations
WHERE task_name = :'task_name'
  AND subject_id = 'scoped-1';
SELECT COALESCE(stale_reasons->>'schema_drift', '0')
FROM otlet.semantic_index_plan(:'watch_name');
SELECT COALESCE(stale_reasons->>'schema_drift', '0')
FROM otlet.semantic_index_status
WHERE name = :'watch_name';
SQL
)"
row_schema_drift_fresh="$(head -n 1 <<<"$row_schema_drift_contract")"
row_schema_drift_reason="$(sed -n '2p' <<<"$row_schema_drift_contract")"
row_schema_drift_plan_reason="$(sed -n '3p' <<<"$row_schema_drift_contract")"
row_schema_drift_status_reason="$(tail -n 1 <<<"$row_schema_drift_contract")"
echo "row_schema_drift_contract=$row_schema_drift_fresh|$row_schema_drift_reason|$row_schema_drift_plan_reason|$row_schema_drift_status_reason"
[ "$row_schema_drift_fresh|$row_schema_drift_reason|$row_schema_drift_plan_reason|$row_schema_drift_status_reason" = "0|true|1|1" ] || {
  echo "Expected dropped scoped input column to write schema_drift and expose it in plan/status, got $row_schema_drift_fresh|$row_schema_drift_reason|$row_schema_drift_plan_reason|$row_schema_drift_status_reason" >&2
  exit 1
}
row_schema_sql_plan="$(psql_exec -qAt -v watch_name="$row_scoped_watch" <<'SQL'
SELECT selected_path || '|' || stale_subjects::text || '|' || stale_reasons::text
FROM otlet.semantic_index_plan(:'watch_name');
SQL
)"
echo "row_schema_sql_plan_contract=$row_schema_sql_plan"
require_contains "$row_schema_sql_plan" "schema_drift" "Expected SQL plan stale reason to include schema_drift"
row_schema_customscan_plan="$(
  psql_exec -P border=2 -P null='' -v watch_name="$row_scoped_watch" <<'SQL'
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches(:'watch_name', id, '{"decision":"pass"}'::jsonb);
SQL
)"
printf '%s\n' "$row_schema_customscan_plan"
require_contains "$row_schema_customscan_plan" "Otlet Node: Semantic Source CustomScan" "Expected CustomScan explain details"
require_contains "$row_schema_customscan_plan" "Planner Selected Path: lookup_fail_closed" "Expected stale CustomScan fail-closed path"
require_contains "$row_schema_customscan_plan" "Planner Reason: fail closed" "Expected stale CustomScan fail-closed reason"
require_contains "$row_schema_customscan_plan" "Planner Stale Reasons:" "Expected CustomScan stale reason breakdown"
require_contains "$row_schema_customscan_plan" "schema_drift" "Expected CustomScan stale reason to include schema_drift"
require_contains "$row_schema_customscan_plan" "Count Basis: exact" "Expected stale CustomScan exact count basis"
require_contains "$row_schema_customscan_plan" "Model Cost Source:" "Expected stale CustomScan model cost source"
require_contains "$row_schema_customscan_plan" "Planner Fail Closed Subjects: 1" "Expected stale CustomScan planned fail-closed count"
require_contains "$row_schema_customscan_plan" "Preloaded Fresh Subjects / Basis:" "Expected stale CustomScan preload count and basis"
require_contains "$row_schema_customscan_plan" "Actual Fail Closed Rows: 1" "Expected stale CustomScan actual fail-closed count"
require_contains "$row_schema_customscan_plan" "Actual Stale Subjects: 1" "Expected stale CustomScan actual stale count"
require_contains "$row_schema_customscan_plan" "Rows Returned: 0" "Expected stale CustomScan to return no rows"

log "Checking CustomScan bounded infer-now"
psql_exec \
  -v model_name="$strong_model_name" \
  -v row_customscan_watch="$row_customscan_watch" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_customscan_signal;
CREATE TABLE public.otlet_demo_customscan_signal (
  id text PRIMARY KEY,
  signal text NOT NULL
);

SELECT otlet.create_watch(
  watch_name => :'row_customscan_watch',
  kind => 'row',
  instruction => 'Classify one CustomScan proof row. Use only input.row.signal. If signal is flag, output decision flag with confidence high. Otherwise output decision pass with confidence high. Return JSON only.',
  output_schema => '{
    "type": "object",
    "required": ["decision", "confidence"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["pass", "flag"]},
      "confidence": {"enum": ["low", "medium", "high"]}
    }
  }'::jsonb,
  model_name => :'model_name',
  table_name => 'public.otlet_demo_customscan_signal'::regclass,
  subject_column => 'id',
  record_type => 'demo_customscan_fact',
  runtime_options => '{"max_tokens":120,"reasoning":"off","inference_cache":true}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  decision_contract => '{"answer_field":"decision","abstain_values":[],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb,
  input_columns => ARRAY['signal']
);

INSERT INTO public.otlet_demo_customscan_signal
VALUES
  ('customscan-1', 'flag'),
  ('customscan-2', 'flag');

SELECT otlet.run_task(:'row_customscan_watch' || '_task');
SQL
wait_task_complete "$row_customscan_task" 2 900 1
psql_exec \
  -v row_customscan_watch="$row_customscan_watch" >/dev/null <<'SQL'
UPDATE public.otlet_demo_customscan_signal
SET signal = 'pass';

SELECT otlet.run_task(:'row_customscan_watch' || '_task');
SQL
wait_task_complete "$row_customscan_task" 4 900 1
psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_demo_customscan_signal
SET signal = 'manual-review';

UPDATE otlet.production_policy
SET stale_policy = 'lookup_only_fail_closed',
    semantic_auto_wait_ms = 0,
    semantic_auto_infer_ms = 30000,
    semantic_auto_max_rows = 1
WHERE name = 'default';
SQL
row_customscan_sql_plan_contract="$(psql_exec -qAt -v watch_name="$row_customscan_watch" <<'SQL'
SELECT selected_path || '|' ||
       infer_now_subjects::text || '|' ||
       fail_closed_subjects::text || '|' ||
       (infer_now_ms > 0)::text || '|' ||
       count_basis
FROM otlet.semantic_index_plan(:'watch_name', true);
SQL
)"
row_customscan_infer_plan="$(
  psql_exec -P border=2 -P null='' -v watch_name="$row_customscan_watch" <<'SQL'
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_customscan_signal
WHERE otlet.semantic_matches_auto(:'watch_name', id, '{}'::jsonb);
SQL
)"
psql_exec >/dev/null <<'SQL'
UPDATE otlet.production_policy
SET stale_policy = 'refresh_then_fail_closed',
    semantic_auto_wait_ms = 10000,
    semantic_auto_infer_ms = 15000,
    semantic_auto_max_rows = 1
WHERE name = 'default';
SQL
printf '%s\n' "$row_customscan_infer_plan"
echo "row_customscan_sql_plan_contract=$row_customscan_sql_plan_contract"
[ "$row_customscan_sql_plan_contract" = "bounded_infer_now|1|1|true|exact" ] || {
  echo "Expected SQL plan to predict one infer-now and one fail-closed row, got $row_customscan_sql_plan_contract" >&2
  exit 1
}
require_contains "$row_customscan_infer_plan" "Planner Selected Path: bounded_infer_now" "Expected CustomScan bounded infer-now path"
require_contains "$row_customscan_infer_plan" "Count Basis: exact" "Expected infer CustomScan exact count basis"
require_contains "$row_customscan_infer_plan" "Model Cost Source:" "Expected infer CustomScan model cost source"
require_contains "$row_customscan_infer_plan" "Planner Infer Now Subjects: 1" "Expected planned infer-now count"
require_contains "$row_customscan_infer_plan" "Planner Fail Closed Subjects: 1" "Expected planned fail-closed count"
require_contains "$row_customscan_infer_plan" "Infer Now Max Rows: 1" "Expected bounded infer-now max rows"
require_contains "$row_customscan_infer_plan" "Infer Now Admission Policy: bounded_shared_memory_infer_queue_4_slots" "Expected infer-now admission details"
require_contains "$row_customscan_infer_plan" "Actual Infer Resolved Rows: 1" "Expected one stale row to resolve through bounded infer-now"
require_contains "$row_customscan_infer_plan" "Actual Infer Returned Rows: 1" "Expected one inferred row to return"
require_contains "$row_customscan_infer_plan" "Actual Fail Closed Rows: 1" "Expected one stale row to fail closed after bounded infer-now"
require_contains "$row_customscan_infer_plan" "Actual Stale Subjects: 2" "Expected two stale source rows"
require_contains "$row_customscan_infer_plan" "Infer Now Batches: 1" "Expected one infer-now batch"
require_contains "$row_customscan_infer_plan" "Infer Now Receipts: 1" "Expected one infer-now receipt"
require_contains "$row_customscan_infer_plan" "Infer Now Trace Receipt Id:" "Expected infer-now receipt pointer"
require_contains "$row_customscan_infer_plan" "Rows Returned: 1" "Expected one inferred row returned after bounded infer-now"

queue_suppression_output="$(psql_exec -qAt -v model_name="$strong_model_name" <<'SQL'
BEGIN;
UPDATE otlet.production_policy
SET max_queued_jobs_per_model = 1
WHERE name = 'default';

DROP TABLE IF EXISTS public.otlet_demo_queue_flood;
CREATE TABLE public.otlet_demo_queue_flood (
  id text PRIMARY KEY,
  note text NOT NULL
);

SELECT otlet.create_watch(
  'row_queue_flood_demo',
  'row',
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  'public.otlet_demo_queue_flood'::regclass,
  'id',
  NULL,
  'demo_queue_flood_fact',
  '{"max_tokens":64,"reasoning":"off"}'::jsonb,
  '{}'::jsonb,
  '{"on_change":"mark_stale_and_enqueue"}'::jsonb
);

INSERT INTO public.otlet_demo_queue_flood
VALUES
  ('flood-1', 'first flood row'),
  ('flood-2', 'second flood row'),
  ('flood-3', 'third flood row');

SELECT (
    SELECT count(*)
    FROM otlet.jobs
    WHERE task_name = 'row_queue_flood_demo_task'
      AND status = 'queued'
  )::text || '|' ||
  (
    SELECT count(*)::text || '|' ||
           (count(*) = 1)::text || '|' ||
           bool_or(e.created_at IS NOT NULL)::text
    FROM otlet.worker_events e
    WHERE e.event_type = 'queue_admission_suppressed'
      AND e.detail ->> 'task_name' = 'row_queue_flood_demo_task'
  ) || '|' ||
  (
    SELECT (queue_admission_suppressed_events >= 1)::text
    FROM otlet.model_queue_status
    WHERE model_name = :'model_name'
  );
ROLLBACK;
SQL
)"
queue_suppression_contract="$(tail -n 1 <<<"$queue_suppression_output")"
echo "queue_suppression_contract=$queue_suppression_contract"
[ "$queue_suppression_contract" = "1|1|true|true|true" ] || {
  echo "Expected queue suppression contract 1|1|true|true|true, got $queue_suppression_contract" >&2
  exit 1
}
