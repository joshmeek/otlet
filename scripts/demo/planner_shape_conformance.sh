log "Checking planner-shape conformance"

prepared_custom_plan="$(psql_exec -qAt -v watch_name="$row_scoped_watch" <<'SQL'
BEGIN;
SET LOCAL plan_cache_mode = force_custom_plan;
PREPARE otlet_shape_custom(text, jsonb) AS
SELECT id
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches($1, id, $2);
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF, SUMMARY OFF, TIMING OFF)
EXECUTE otlet_shape_custom(:'watch_name', '{"decision":"pass"}'::jsonb);
DEALLOCATE otlet_shape_custom;
ROLLBACK;
SQL
)"
require_contains "$prepared_custom_plan" "Otlet Node: Semantic Source CustomScan" "Expected a prepared custom plan to use CustomScan"
require_regex "$prepared_custom_plan" 'Custom Scan \(Otlet Semantic Source CustomScan\).*actual rows=1(\.00)? loops=1' "Expected the prepared custom CustomScan to return one row"

prepared_generic_plan="$(psql_exec -qAt -v watch_name="$row_scoped_watch" <<'SQL'
BEGIN;
SET LOCAL plan_cache_mode = force_generic_plan;
PREPARE otlet_shape_generic(text, jsonb) AS
SELECT id
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches($1, id, $2);
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF, SUMMARY OFF, TIMING OFF)
EXECUTE otlet_shape_generic(:'watch_name', '{"decision":"pass"}'::jsonb);
DEALLOCATE otlet_shape_generic;
ROLLBACK;
SQL
)"
require_regex "$prepared_generic_plan" 'Seq Scan on public\.otlet_demo_scoped_signal.*actual rows=1(\.00)? loops=1' "Expected an unresolved prepared generic plan to return one row through the standard PostgreSQL scan"
if [[ "$prepared_generic_plan" == *"Otlet Semantic Source CustomScan"* ]]; then
  echo "Unresolved prepared generic parameters unexpectedly used CustomScan" >&2
  exit 1
fi

nested_loop_plan="$(psql_exec -qAt -v watch_name="$row_scoped_watch" <<'SQL'
BEGIN;
SET LOCAL enable_hashjoin = off;
SET LOCAL enable_mergejoin = off;
SET LOCAL enable_material = off;
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT repeated.pass, scoped.id
FROM (VALUES (1), (2), (3)) repeated(pass)
LEFT JOIN public.otlet_demo_scoped_signal scoped
  ON otlet.semantic_matches(:'watch_name', scoped.id, '{"decision":"pass"}'::jsonb);
ROLLBACK;
SQL
)"
require_contains "$nested_loop_plan" "Nested Loop Left Join" "Expected the rescan fixture to use a nested loop"
require_contains "$nested_loop_plan" "Otlet Node: Semantic Source CustomScan" "Expected the unparameterized nested-loop inner path to use CustomScan"
require_regex "$nested_loop_plan" 'Custom Scan \(Otlet Semantic Source CustomScan\).*actual rows=1(\.00)? loops=3' "Expected three CustomScan rescans"

parameterized_plan="$(psql_exec -qAt -v watch_name="$row_scoped_watch" <<'SQL'
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT requested.id, matched.id
FROM (VALUES ('scoped-1'::text), ('missing'::text)) requested(id)
CROSS JOIN LATERAL (
  SELECT scoped.id
  FROM public.otlet_demo_scoped_signal scoped
  WHERE scoped.id = requested.id
    AND otlet.semantic_matches(:'watch_name', scoped.id, '{"decision":"pass"}'::jsonb)
  OFFSET 0
) matched;
SQL
)"
require_contains "$parameterized_plan" "Filter: otlet.semantic_matches" "Expected the parameterized standard plan to retain the semantic predicate"
require_contains "$parameterized_plan" "actual rows=0.50 loops=2" "Expected the parameterized relation to run for both outer rows"
if [[ "$parameterized_plan" == *"Otlet Semantic Source CustomScan"* ]]; then
  echo "Parameterized semantic relation unexpectedly used CustomScan" >&2
  exit 1
fi

row_lock_plan="$(psql_exec -qAt -v watch_name="$row_scoped_watch" <<'SQL'
BEGIN;
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches(:'watch_name', id, '{"decision":"pass"}'::jsonb)
FOR UPDATE;
ROLLBACK;
SQL
)"
require_contains "$row_lock_plan" "LockRows" "Expected the row-mark fixture to retain PostgreSQL locking"
require_contains "$row_lock_plan" "Filter: otlet.semantic_matches" "Expected the row-mark standard plan to retain the semantic predicate"
if [[ "$row_lock_plan" == *"Otlet Semantic Source CustomScan"* ]]; then
  echo "Row-marked semantic query unexpectedly used CustomScan" >&2
  exit 1
fi

isolation_contract=""
check_planner_isolation() {
  local isolation_sql="$1"
  local isolation_name="$2"
  local isolation_plan
  isolation_plan="$(psql_exec -qAt -v watch_name="$row_scoped_watch" <<SQL
BEGIN ISOLATION LEVEL $isolation_sql READ ONLY;
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches(:'watch_name', id, '{"decision":"pass"}'::jsonb);
SELECT current_setting('transaction_isolation') || '|' || count(*)::text
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches(:'watch_name', id, '{"decision":"pass"}'::jsonb);
ROLLBACK;
SQL
)"
  require_contains "$isolation_plan" "Otlet Node: Semantic Source CustomScan" "Expected CustomScan under $isolation_name"
  require_regex "$isolation_plan" 'Custom Scan \(Otlet Semantic Source CustomScan\).*actual rows=1(\.00)? loops=1' "Expected one planned CustomScan row under $isolation_name"
  require_contains "$isolation_plan" "$isolation_name|1" "Expected one row under $isolation_name"
  isolation_contract="${isolation_contract}${isolation_contract:+,}${isolation_name// /_}"
}
check_planner_isolation "READ COMMITTED" "read committed"
check_planner_isolation "REPEATABLE READ" "repeatable read"
check_planner_isolation "SERIALIZABLE" "serializable"

require_contains "$correlated_customscan_plan" "Seq Scan on public.otlet_demo_customscan_signal" "Expected the correlated fixture to use the standard PostgreSQL scan"
[ "$correlated_customscan_soak" = "100|25|25|25|25" ] || {
  echo "Correlated fallback result parity changed: $correlated_customscan_soak" >&2
  exit 1
}
require_contains "$row_schema_read_only_contract" "lookup_fail_closed|1|1" "Expected schema drift to fail closed"
[ "$row_schema_repair_contract" = "t|t|t|t|t|t" ] || {
  echo "Schema-drift repair fixture changed: $row_schema_repair_contract" >&2
  exit 1
}

cancel_output="$(psql_exec -qAt -v ON_ERROR_STOP=0 \
  -v watch_name="$row_scoped_watch" \
  -v task_name="$row_scoped_task" 2>&1 <<'SQL'
SELECT
  (SELECT count(*) FROM otlet.jobs WHERE task_name = :'task_name') AS jobs_before,
  (
    SELECT count(*)
    FROM otlet.inference_receipts receipt
    JOIN otlet.jobs job ON job.id = receipt.job_id
    WHERE job.task_name = :'task_name'
  ) AS receipts_before,
  (
    SELECT count(*)
    FROM otlet.outputs output
    JOIN otlet.jobs job ON job.id = output.job_id
    WHERE job.task_name = :'task_name'
  ) AS outputs_before,
  (SELECT count(*) FROM otlet.semantic_materializations WHERE task_name = :'task_name') AS materializations_before
\gset
SET statement_timeout = 0;
SET plan_cache_mode = force_generic_plan;
PREPARE otlet_shape_cancel AS
SELECT id
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches(:'watch_name', id, '{"decision":"pass"}'::jsonb)
  AND pg_sleep(5) IS NULL;
EXPLAIN (VERBOSE, COSTS OFF, SUMMARY OFF) EXECUTE otlet_shape_cancel;
SET statement_timeout = '2s';
EXECUTE otlet_shape_cancel;
RESET statement_timeout;
DEALLOCATE otlet_shape_cancel;
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches(:'watch_name', id, '{"decision":"pass"}'::jsonb);
SELECT 'planner_cancel_recovery=' || count(*)::text || '|' ||
       (SELECT count(*) FROM otlet.verify_invariants())::text || '|' ||
       (
         :'jobs_before'::bigint = (SELECT count(*) FROM otlet.jobs WHERE task_name = :'task_name')
         AND :'receipts_before'::bigint = (
           SELECT count(*)
           FROM otlet.inference_receipts receipt
           JOIN otlet.jobs job ON job.id = receipt.job_id
           WHERE job.task_name = :'task_name'
         )
         AND :'outputs_before'::bigint = (
           SELECT count(*)
           FROM otlet.outputs output
           JOIN otlet.jobs job ON job.id = output.job_id
           WHERE job.task_name = :'task_name'
         )
         AND :'materializations_before'::bigint = (
           SELECT count(*)
           FROM otlet.semantic_materializations
           WHERE task_name = :'task_name'
         )
       )::text
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches(:'watch_name', id, '{"decision":"pass"}'::jsonb);
SQL
)"
require_contains "$cancel_output" "Otlet Node: Semantic Source CustomScan" "Expected the cached cancellation plan to use CustomScan"
require_contains "$cancel_output" "Executor Evidence: not collected for plan-only EXPLAIN" "Expected the cached cancellation plan to be the plan-only CustomScan"
require_contains "$cancel_output" "canceling statement due to statement timeout" "Expected PostgreSQL query cancellation"
require_regex "$cancel_output" 'Custom Scan \(Otlet Semantic Source CustomScan\).*actual rows=1(\.00)? loops=1' "Expected a later CustomScan to succeed in the same session"
cancel_recovery_contract="$(sed -n 's/^planner_cancel_recovery=//p' <<<"$cancel_output")"
[ "$cancel_recovery_contract" = "1|0|true" ] || {
  echo "Expected same-session recovery, unchanged durable state, and zero invariants after cancellation, got $cancel_recovery_contract" >&2
  exit 1
}

echo "planner_shape_conformance_contract=customscan|generic_fallback|rescan_3|parameterized_fallback|correlated_fallback|row_lock_fallback|$isolation_contract|schema_drift|query_canceled|$cancel_recovery_contract"
