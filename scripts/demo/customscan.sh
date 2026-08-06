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
row_schema_read_only_customscan_plan="$(
  psql_exec -P border=2 -P null='' -v watch_name="$row_scoped_watch" <<'SQL'
PREPARE otlet_schema_drift_customscan(text) AS
SELECT id
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches_auto($1, id, '{"decision":"pass"}'::jsonb);
EXECUTE otlet_schema_drift_customscan(:'watch_name');

ALTER TABLE public.otlet_demo_scoped_signal
  DROP COLUMN signal,
  ADD COLUMN signal text;

BEGIN READ ONLY;
SELECT 'read_only_customscan_before=' || concat_ws('|',
  current_setting('transaction_read_only'),
  pg_my_temp_schema() = 0
);
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
EXECUTE otlet_schema_drift_customscan(:'watch_name');
SELECT 'read_only_customscan_after=' || concat_ws('|',
  current_setting('transaction_read_only'),
  pg_my_temp_schema() = 0
);
COMMIT;
DEALLOCATE otlet_schema_drift_customscan;
SQL
)"
printf '%s\n' "$row_schema_read_only_customscan_plan"
require_contains "$row_schema_read_only_customscan_plan" "read_only_customscan_before=on|t" "Expected read-only CustomScan transaction without a temp schema"
require_contains "$row_schema_read_only_customscan_plan" "Otlet Node: Semantic Source CustomScan" "Expected read-only CustomScan explain details"
require_contains "$row_schema_read_only_customscan_plan" "Refresh Policy: fail_closed_no_refresh" "Expected read-only CustomScan refresh suppression"
require_contains "$row_schema_read_only_customscan_plan" "Worker Handoff: none_for_fail_closed_lookup" "Expected read-only CustomScan to avoid worker handoff"
require_contains "$row_schema_read_only_customscan_plan" "Infer Now Timeout Ms: 0" "Expected read-only CustomScan infer timeout to be disabled"
require_contains "$row_schema_read_only_customscan_plan" "Infer Now Max Rows: 0" "Expected read-only CustomScan infer rows to be disabled"
require_contains "$row_schema_read_only_customscan_plan" "Planner Selected Path: lookup_fail_closed" "Expected read-only CustomScan fail-closed path"
require_contains "$row_schema_read_only_customscan_plan" "schema_drift" "Expected read-only CustomScan schema drift reason"
require_contains "$row_schema_read_only_customscan_plan" "Actual Fail Closed Rows: 1" "Expected read-only CustomScan fail-closed row"
require_contains "$row_schema_read_only_customscan_plan" "Queued Refreshes: 0" "Expected read-only CustomScan to queue no refreshes"
require_contains "$row_schema_read_only_customscan_plan" "Infer Now Batches: 0" "Expected read-only CustomScan to run no inference"
require_contains "$row_schema_read_only_customscan_plan" "Rows Returned: 0" "Expected read-only CustomScan to return no rows"
require_contains "$row_schema_read_only_customscan_plan" "read_only_customscan_after=on|t" "Expected read-only CustomScan to leave no temp schema"
row_schema_execution_before="$(psql_exec -qAt -v task_name="$row_scoped_task" <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*) FROM otlet.jobs WHERE task_name = :'task_name'),
  (
    SELECT count(*)
    FROM otlet.inference_receipts receipt
    JOIN otlet.jobs job ON job.id = receipt.job_id
    WHERE job.task_name = :'task_name'
  ),
  (
    SELECT count(*)
    FROM otlet.outputs output
    JOIN otlet.jobs job ON job.id = output.job_id
    WHERE job.task_name = :'task_name'
  ),
  (SELECT count(*) FROM otlet.semantic_materializations WHERE task_name = :'task_name')
);
SQL
)"
set +e
row_schema_execution_output="$(psql_exec -qAt -v task_name="$row_scoped_task" 2>&1 <<'SQL'
SELECT otlet.run_task(:'task_name');
SQL
)"
row_schema_execution_status=$?
set -e
if [ "$row_schema_execution_status" -eq 0 ]; then
  echo "Expected schema drift to suspend task execution" >&2
  exit 1
fi
require_contains "$row_schema_execution_output" "semantic source column contract drifted" "Expected schema drift execution rejection"
row_schema_execution_after="$(psql_exec -qAt -v task_name="$row_scoped_task" <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*) FROM otlet.jobs WHERE task_name = :'task_name'),
  (
    SELECT count(*)
    FROM otlet.inference_receipts receipt
    JOIN otlet.jobs job ON job.id = receipt.job_id
    WHERE job.task_name = :'task_name'
  ),
  (
    SELECT count(*)
    FROM otlet.outputs output
    JOIN otlet.jobs job ON job.id = output.job_id
    WHERE job.task_name = :'task_name'
  ),
  (SELECT count(*) FROM otlet.semantic_materializations WHERE task_name = :'task_name')
);
SQL
)"
row_schema_execution_contract="$([ "$row_schema_execution_before" = "$row_schema_execution_after" ] && echo true || echo false)|$row_schema_execution_before"
echo "row_schema_execution_contract=$row_schema_execution_contract"
require_regex "$row_schema_execution_contract" '^true\|' "Expected schema drift rejection to preserve jobs, receipts, outputs, and materializations"
row_schema_read_only_contract="$(psql_exec -qAt \
  -v watch_name="$row_scoped_watch" \
  -v task_name="$row_scoped_task" <<'SQL'
BEGIN READ ONLY;
WITH plan AS MATERIALIZED (
  SELECT *
  FROM otlet.semantic_index_plan(:'watch_name', true)
), status AS MATERIALIZED (
  SELECT *
  FROM otlet.semantic_index_status
  WHERE name = :'watch_name'
), watch AS MATERIALIZED (
  SELECT *
  FROM otlet.watch_status
  WHERE watch_name = :'watch_name'
)
SELECT concat_ws('|',
  current_setting('transaction_read_only'),
  pg_my_temp_schema() = 0,
  (SELECT count(*) FROM otlet.semantic_index_current_rows(:'watch_name', true)),
  otlet.semantic_matches(:'watch_name', 'scoped-1', '{"decision":"pass"}'::jsonb),
  (SELECT selected_path FROM plan),
  (SELECT stale_subjects FROM plan),
  (SELECT COALESCE(stale_reasons->>'schema_drift', '0') FROM plan),
  (SELECT wait_subjects FROM plan),
  (SELECT infer_now_subjects FROM plan),
  (SELECT queue_subjects FROM plan),
  (SELECT fail_closed_subjects FROM plan),
  (SELECT selected_path FROM status),
  (SELECT COALESCE(stale_reasons->>'schema_drift', '0') FROM status),
  (SELECT selected_path FROM watch),
  (SELECT COALESCE(stale_reasons->>'schema_drift', '0') FROM watch),
  EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations
    WHERE task_name = :'task_name'
      AND subject_id = 'scoped-1'
      AND stale_reason = 'schema_drift'
  ),
  pg_my_temp_schema() = 0
);
COMMIT;
SQL
)"
echo "row_schema_read_only_contract=$row_schema_read_only_contract"
[ "$row_schema_read_only_contract" = "on|t|0|f|lookup_fail_closed|1|1|0|0|0|1|lookup_fail_closed|1|lookup_fail_closed|1|f|t" ] || {
  echo "Expected read-only row reads to detect schema drift, fail closed, and leave durable state untouched, got $row_schema_read_only_contract" >&2
  exit 1
}
row_schema_maintenance_marked="$(psql_exec -qAt \
  -v watch_name="$row_scoped_watch" <<'SQL'
SELECT otlet.mark_semantic_schema_drift(:'watch_name');
SQL
)"
row_schema_maintenance_recorded="$(psql_exec -qAt \
  -v task_name="$row_scoped_task" <<'SQL'
SELECT EXISTS (
  SELECT 1
  FROM otlet.semantic_materializations
  WHERE task_name = :'task_name'
    AND subject_id = 'scoped-1'
    AND stale_reason = 'schema_drift'
)::text;
SQL
)"
row_schema_maintenance_contract="$row_schema_maintenance_marked|$row_schema_maintenance_recorded"
echo "row_schema_maintenance_contract=$row_schema_maintenance_contract"
[ "$row_schema_maintenance_contract" = "1|true" ] || {
  echo "Expected explicit schema maintenance to record one drifted materialization, got $row_schema_maintenance_contract" >&2
  exit 1
}
row_schema_sql_plan="$(psql_exec -qAt -v watch_name="$row_scoped_watch" <<'SQL'
SELECT selected_path || '|' || stale_subjects::text || '|' || stale_reasons::text
FROM otlet.semantic_index_plan(:'watch_name');
SQL
)"
echo "row_schema_sql_plan_contract=$row_schema_sql_plan"
require_contains "$row_schema_sql_plan" "schema_drift" "Expected SQL plan stale reason to include schema_drift"
row_schema_revisions="$(psql_exec -qAt -v task_name="$row_scoped_task" <<'SQL'
WITH active AS MATERIALIZED (
  SELECT active_workload_revision_hash AS revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = :'task_name'
)
SELECT active.revision_hash || '|' || otlet.repair_source_query_contract(
  :'task_name',
  active.revision_hash
)
FROM active;
SQL
)"
IFS='|' read -r row_schema_old_revision row_schema_new_revision <<<"$row_schema_revisions"
row_schema_repair_contract="$(psql_exec -qAt \
  -v watch_name="$row_scoped_watch" \
  -v task_name="$row_scoped_task" \
  -v old_revision="$row_schema_old_revision" \
  -v new_revision="$row_schema_new_revision" <<'SQL'
SELECT concat_ws('|',
  :'new_revision' <> :'old_revision',
  EXISTS (
    SELECT 1
    FROM otlet.workload_revision_heads
    WHERE task_name = :'task_name'
      AND active_workload_revision_hash = :'new_revision'
  ),
  (
    SELECT otlet.semantic_schema_drift_error(definition) IS NULL
    FROM otlet.workload_revisions
    WHERE workload_revision_hash = :'new_revision'
  ),
  EXISTS (
    SELECT 1
    FROM otlet.watch_status
    WHERE watch_name = :'watch_name'
      AND source_dependency_status = 'ready'
  ),
  EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations
    WHERE task_name = :'task_name'
      AND contract_hash = :'old_revision'
      AND stale_reason = 'contract_changed'
  ),
  EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'public.otlet_demo_scoped_signal'::regclass
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgfoid = 'otlet.mark_semantic_stale_trigger()'::regprocedure
  )
);
SQL
)"
echo "row_schema_repair_contract=$row_schema_repair_contract"
[ "$row_schema_repair_contract" = "t|t|t|t|t|t" ] || {
  echo "Expected schema repair to promote the replacement-column contract and restore the watch, got $row_schema_repair_contract" >&2
  exit 1
}
row_schema_repair_job_id="$(psql_exec -qAt \
  -v task_name="$row_scoped_task" <<'SQL'
UPDATE public.otlet_demo_scoped_signal
SET signal = 'approve'
WHERE id = 'scoped-1';
SELECT otlet.run_task(:'task_name') \g /dev/null
SELECT id
FROM otlet.jobs
WHERE task_name = :'task_name'
ORDER BY id DESC
LIMIT 1;
SQL
)"
wait_task_complete "$row_scoped_task" 2 900 1
row_schema_repair_execution_contract="$(psql_exec -qAt \
  -v task_name="$row_scoped_task" \
  -v job_id="$row_schema_repair_job_id" \
  -v revision_hash="$row_schema_new_revision" \
  -v watch_name="$row_scoped_watch" <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.jobs
    WHERE id = :'job_id'::bigint
      AND task_name = :'task_name'
      AND workload_revision_hash = :'revision_hash'
      AND status = 'complete'
  ),
  EXISTS (
    SELECT 1
    FROM otlet.outputs output
    JOIN otlet.jobs job ON job.id = output.job_id
    WHERE job.id = :'job_id'::bigint
      AND job.workload_revision_hash = :'revision_hash'
  ),
  (SELECT count(*) = 1 FROM otlet.semantic_index_current_rows(:'watch_name', true))
);
SQL
)"
echo "row_schema_repair_execution_contract=$row_schema_repair_execution_contract"
[ "$row_schema_repair_execution_contract" = "t|t|t" ] || {
  echo "Expected schema repair to restore task execution and current semantic reads, got $row_schema_repair_execution_contract" >&2
  exit 1
}

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

correlated_customscan_plan="$(psql_exec -P border=2 -P null='' -v watch_name="$row_customscan_watch" <<'SQL'
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT repeated.pass, refreshed.id
FROM generate_series(1, 2) repeated(pass)
CROSS JOIN LATERAL (
  SELECT id
  FROM public.otlet_demo_customscan_signal
  WHERE otlet.semantic_matches_auto(:'watch_name', id, '{}'::jsonb)
    AND repeated.pass > 0
  OFFSET 0
) refreshed;
SQL
)"
printf '%s\n' "$correlated_customscan_plan"
require_contains "$correlated_customscan_plan" "Seq Scan on public.otlet_demo_customscan_signal" "Expected correlated semantic predicate to use the standard Postgres scan"
if [[ "$correlated_customscan_plan" == *"Otlet Semantic Source CustomScan"* ]]; then
  echo "Correlated semantic predicate must not use an Otlet CustomScan" >&2
  exit 1
fi

correlated_customscan_soak="$(psql_exec -qAt -v watch_name="$row_customscan_watch" <<'SQL'
SELECT count(*)::text || '|' ||
       count(*) FILTER (WHERE pass = 1 AND id = 'customscan-1')::text || '|' ||
       count(*) FILTER (WHERE pass = 1 AND id = 'customscan-2')::text || '|' ||
       count(*) FILTER (WHERE pass = 2 AND id = 'customscan-1')::text || '|' ||
       count(*) FILTER (WHERE pass = 2 AND id = 'customscan-2')::text
FROM generate_series(1, 25) soak(iteration)
CROSS JOIN generate_series(1, 2) repeated(pass)
CROSS JOIN LATERAL (
  SELECT id
  FROM public.otlet_demo_customscan_signal
  WHERE otlet.semantic_matches_auto(:'watch_name', id, '{}'::jsonb)
    AND soak.iteration > 0
    AND repeated.pass > 0
  OFFSET 0
) refreshed;
SQL
)"
echo "correlated_customscan_soak_contract=$correlated_customscan_soak"
[ "$correlated_customscan_soak" = "100|25|25|25|25" ] || {
  echo "Expected 25 stable correlated fallback scans, got $correlated_customscan_soak" >&2
  exit 1
}

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
row_customscan_read_only_plan="$(
  psql_exec -P border=2 -P null='' -v watch_name="$row_customscan_watch" <<'SQL'
BEGIN READ ONLY;
SELECT 'read_only_auto_before=' || concat_ws('|',
  current_setting('transaction_read_only'),
  pg_my_temp_schema() = 0
);
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_customscan_signal
WHERE otlet.semantic_matches_auto(:'watch_name', id, '{}'::jsonb);
SELECT 'read_only_auto_after=' || concat_ws('|',
  current_setting('transaction_read_only'),
  pg_my_temp_schema() = 0
);
COMMIT;
SQL
)"
printf '%s\n' "$row_customscan_read_only_plan"
require_contains "$row_customscan_read_only_plan" "read_only_auto_before=on|t" "Expected schema-current auto CustomScan to start read-only"
require_contains "$row_customscan_read_only_plan" "Otlet Node: Semantic Source CustomScan" "Expected schema-current read-only CustomScan node"
require_contains "$row_customscan_read_only_plan" "Refresh Policy: fail_closed_no_refresh" "Expected read-only auto refresh suppression"
require_contains "$row_customscan_read_only_plan" "Worker Handoff: none_for_fail_closed_lookup" "Expected read-only auto worker suppression"
require_contains "$row_customscan_read_only_plan" "Infer Now Timeout Ms: 0" "Expected read-only auto infer timeout to be disabled"
require_contains "$row_customscan_read_only_plan" "Infer Now Max Rows: 0" "Expected read-only auto infer rows to be disabled"
require_contains "$row_customscan_read_only_plan" "Planner Selected Path: lookup_fail_closed" "Expected schema-current read-only fail-closed path"
require_contains "$row_customscan_read_only_plan" "Actual Fail Closed Rows: 2" "Expected read-only auto scan to fail closed for both rows"
require_contains "$row_customscan_read_only_plan" "Queued Refreshes: 0" "Expected read-only auto scan to queue no refreshes"
require_contains "$row_customscan_read_only_plan" "Infer Now Batches: 0" "Expected read-only auto scan to run no inference"
require_contains "$row_customscan_read_only_plan" "Rows Returned: 0" "Expected read-only auto scan to return no rows"
require_contains "$row_customscan_read_only_plan" "read_only_auto_after=on|t" "Expected schema-current auto CustomScan to leave no temp schema"
row_customscan_queue_origin_contract="$(
  psql_exec -qAt \
    -v watch_name="$row_customscan_watch" \
    -v task_name="$row_customscan_task" <<'SQL' | tail -n 1
BEGIN;
UPDATE otlet.production_policy
SET stale_policy = 'refresh_then_fail_closed',
    semantic_auto_wait_ms = 0,
    semantic_auto_infer_ms = 0,
    semantic_auto_max_rows = 0
WHERE name = 'default';
\o /dev/null
SELECT id
FROM public.otlet_demo_customscan_signal
WHERE otlet.semantic_matches_auto(:'watch_name', id, '{}'::jsonb);
\o
SELECT count(*)::text || '|' || bool_and(job_origin = 'customscan')::text
FROM otlet.jobs
WHERE task_name = :'task_name'
  AND status = 'queued';
ROLLBACK;
SQL
)"
echo "row_customscan_queue_origin_contract=$row_customscan_queue_origin_contract"
[ "$row_customscan_queue_origin_contract" = "2|true" ] || {
  echo "Expected CustomScan to queue two customscan-origin jobs, got $row_customscan_queue_origin_contract" >&2
  exit 1
}
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
require_contains "$row_customscan_infer_plan" "Infer Now Runtime Fingerprint Hash:" "Expected infer-now EXPLAIN to identify the receipt runtime"
require_contains "$row_customscan_infer_plan" "Infer Now Trace Receipt Id:" "Expected infer-now receipt pointer"
require_contains "$row_customscan_infer_plan" "Rows Returned: 1" "Expected one inferred row returned after bounded infer-now"

row_customscan_infer_origin_contract="$(psql_value -v task_name="$row_customscan_task" <<'SQL'
SELECT job_origin
FROM otlet.inference_receipt_trace_status
WHERE task_name = :'task_name'
  AND executor_origin = 'customscan_infer_now'
ORDER BY receipt_id DESC
LIMIT 1;
SQL
)"
echo "row_customscan_infer_origin_contract=$row_customscan_infer_origin_contract"
[ "$row_customscan_infer_origin_contract" = "customscan" ] || {
  echo "Expected CustomScan infer-now receipt origin, got $row_customscan_infer_origin_contract" >&2
  exit 1
}

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

SELECT otlet.reconcile_watch_subject('row_queue_flood_demo', 'flood-1', true);
SELECT otlet.reconcile_watch_subject('row_queue_flood_demo', 'flood-2', true);

SELECT (
    SELECT count(*)
    FROM otlet.jobs
    WHERE task_name = 'row_queue_flood_demo_task'
      AND status = 'queued'
  )::text || '|' ||
  (
    SELECT count(*)::text || '|' || COALESCE(sum(attempts), 0)::text
    FROM otlet.watch_reconciliation
    WHERE watch_name = 'row_queue_flood_demo'
  ) || '|' ||
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
[ "$queue_suppression_contract" = "1|2|1|1|true|true|true" ] || {
  echo "Expected durable queue suppression contract 1|2|1|1|true|true|true, got $queue_suppression_contract" >&2
  exit 1
}
