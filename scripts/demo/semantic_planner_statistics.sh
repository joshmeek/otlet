log "Checking semantic planner statistics"

semantic_statistics_contract="$(psql_candidate_exec -qAt \
  -v row_watch="$numeric_triage_watch" \
  -v pair_watch="$join_index_name" <<'SQL'
BEGIN READ ONLY;
WITH row_plan AS MATERIALIZED (
  SELECT * FROM otlet.semantic_index_plan(:'row_watch')
), pair_plan AS MATERIALIZED (
  SELECT * FROM otlet.semantic_join_index_plan(:'pair_watch')
), row_diagnostic AS MATERIALIZED (
  SELECT *
  FROM otlet.semantic_predicate_counts(
    :'row_watch', '{"decision":"flag"}'::jsonb
  )
), pair_diagnostic AS MATERIALIZED (
  SELECT *
  FROM otlet.semantic_predicate_counts(
    :'pair_watch', '{"match":"same_entity"}'::jsonb
  )
)
SELECT concat_ws('|',
  (SELECT count_basis FROM row_plan),
  (SELECT total_subjects FROM row_plan),
  (SELECT fresh_subjects FROM row_plan),
  (SELECT stale_subjects FROM row_plan),
  (SELECT missing_subjects FROM row_plan),
  (SELECT count_basis FROM pair_plan),
  (SELECT total_subjects FROM pair_plan),
  (SELECT fresh_subjects FROM pair_plan),
  (SELECT stale_subjects FROM pair_plan),
  (SELECT missing_subjects FROM pair_plan),
  (SELECT count_basis FROM row_diagnostic),
  (SELECT total_subjects FROM row_diagnostic),
  (SELECT fresh_matches FROM row_diagnostic),
  (SELECT fresh_non_matches FROM row_diagnostic),
  (SELECT stale_subjects FROM row_diagnostic),
  (SELECT missing_subjects FROM row_diagnostic),
  (SELECT count_basis FROM pair_diagnostic),
  (SELECT total_subjects FROM pair_diagnostic),
  (SELECT fresh_matches FROM pair_diagnostic),
  (SELECT fresh_non_matches FROM pair_diagnostic),
  (SELECT stale_subjects FROM pair_diagnostic),
  (SELECT missing_subjects FROM pair_diagnostic)
);
COMMIT;
SQL
)"
[ "$semantic_statistics_contract" = "maintained|1|1|0|0|maintained|4|4|0|0|exact_predicate_diagnostic|1|1|0|0|0|exact_predicate_diagnostic|4|1|3|0|0" ] || {
  echo "Semantic planner statistics contract mismatch: $semantic_statistics_contract" >&2
  exit 1
}

if psql_exec -qAt -v row_watch="$numeric_triage_watch" >/dev/null 2>&1 <<'SQL'
SELECT *
FROM otlet.semantic_index_plan(:'row_watch', false, repeat('0', 64));
SQL
then
  echo "Semantic planner accepted a stale workload revision" >&2
  exit 1
fi

semantic_plan_only_explain="$(psql_exec -P border=2 -P null='' \
  -v row_watch="$numeric_triage_watch" <<'SQL'
EXPLAIN (VERBOSE, COSTS, SUMMARY OFF)
SELECT id
FROM public.otlet_demo_numeric_triage
WHERE otlet.semantic_matches(
  :'row_watch', id, '{"decision":"flag"}'::jsonb
);
SQL
)"
require_contains "$semantic_plan_only_explain" \
  "Count Basis: maintained" \
  "Expected plan-only CustomScan to use maintained statistics"
require_contains "$semantic_plan_only_explain" \
  "Executor Evidence: not collected for plan-only EXPLAIN" \
  "Expected plan-only CustomScan to skip exact executor evidence"
if [[ "$semantic_plan_only_explain" == *"Preloaded Predicate Matches:"* ]]; then
  echo "Plan-only CustomScan unexpectedly preloaded predicate evidence" >&2
  exit 1
fi

row_statistics_change_contract="$(psql_exec -qAt \
  -v row_watch="$numeric_triage_watch" <<'SQL'
BEGIN;
INSERT INTO public.otlet_demo_numeric_triage
VALUES ('numeric-missing', 1, 2, 'missing semantic result');
SELECT concat_ws('|', count_basis, total_subjects, fresh_subjects,
                 stale_subjects, missing_subjects)
FROM otlet.semantic_planner_statistics_status
WHERE index_name = :'row_watch';
ROLLBACK;

BEGIN;
UPDATE public.otlet_demo_numeric_triage
SET amount_cents = amount_cents + 1
WHERE id = 'numeric-1';
SELECT concat_ws('|', count_basis, total_subjects, fresh_subjects,
                 stale_subjects, missing_subjects)
FROM otlet.semantic_planner_statistics_status
WHERE index_name = :'row_watch';
ROLLBACK;

BEGIN;
DELETE FROM public.otlet_demo_numeric_triage WHERE id = 'numeric-1';
SELECT concat_ws('|', count_basis, total_subjects, fresh_subjects,
                 stale_subjects, missing_subjects)
FROM otlet.semantic_planner_statistics_status
WHERE index_name = :'row_watch';
ROLLBACK;

BEGIN;
DELETE FROM public.otlet_demo_numeric_triage WHERE id = 'numeric-1';
INSERT INTO public.otlet_demo_numeric_triage
VALUES (
  'numeric-1',
  25000,
  10000,
  'Payment exceeds the declared approval threshold'
);
SELECT concat_ws('|', count_basis, total_subjects, fresh_subjects,
                 stale_subjects, missing_subjects)
FROM otlet.semantic_planner_statistics_status
WHERE index_name = :'row_watch';
ROLLBACK;

BEGIN;
TRUNCATE public.otlet_demo_numeric_triage;
SELECT concat_ws('|', count_basis, total_subjects, fresh_subjects,
                 stale_subjects, missing_subjects)
FROM otlet.semantic_planner_statistics_status
WHERE index_name = :'row_watch';
ROLLBACK;
SQL
)"
[ "$row_statistics_change_contract" = $'maintained|2|1|0|1\nmaintained|1|0|1|0\nmaintained|0|0|0|0\nmaintained|1|0|1|0\nmaintained|0|0|0|0' ] || {
  echo "Semantic row statistics maintenance mismatch: $row_statistics_change_contract" >&2
  exit 1
}

pair_statistics_change_contract="$(psql_exec -qAt \
  -v pair_watch="$join_index_name" <<'SQL'
BEGIN;
SELECT statistics_version AS pair_version_before
FROM otlet.semantic_planner_statistics_status
WHERE index_name = :'pair_watch' \gset
UPDATE public.otlet_demo_vendor_entity
SET updated_at = updated_at
WHERE false;
SELECT concat_ws('|',
  count_basis,
  statistics_version = :'pair_version_before'::bigint
)
FROM otlet.semantic_planner_statistics_status
WHERE index_name = :'pair_watch';
ROLLBACK;

BEGIN;
UPDATE public.otlet_demo_vendor_entity
SET updated_at = clock_timestamp()
WHERE id = 'vendor-1001';
SELECT concat_ws('|',
  status.count_basis,
  status.total_subjects,
  status.fresh_subjects,
  status.stale_subjects,
  status.missing_subjects,
  plan.count_basis,
  plan.total_subjects,
  plan.fresh_subjects,
  plan.stale_subjects,
  plan.missing_subjects
)
FROM otlet.semantic_planner_statistics_status status
CROSS JOIN otlet.semantic_join_index_plan(:'pair_watch') plan
WHERE status.index_name = :'pair_watch';
ROLLBACK;

BEGIN;
TRUNCATE public.otlet_demo_vendor_pair;
SELECT concat_ws('|', count_basis, invalidation_reason)
FROM otlet.semantic_planner_statistics_status
WHERE index_name = :'pair_watch';
ROLLBACK;
SQL
)"
[ "$pair_statistics_change_contract" = $'maintained|t\nmaintained_invalid|4|0|0|4|maintained_invalid|10|0|0|10\nmaintained_invalid|pair_source_truncate' ] || {
  echo "Semantic pair statistics invalidation mismatch: $pair_statistics_change_contract" >&2
  exit 1
}

row_statistics_change_summary="${row_statistics_change_contract//$'\n'/,}"
pair_statistics_change_summary="${pair_statistics_change_contract//$'\n'/,}"
echo "semantic_planner_statistics_contract=$semantic_statistics_contract|$row_statistics_change_summary|$pair_statistics_change_summary"
