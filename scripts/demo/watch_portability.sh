log "Checking watch definition portability"
watch_replace_contract="$(psql_exec -qAt \
  -v row_watch="$numeric_triage_watch" \
  -v pair_watch="$join_index_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE watch_portability_definitions AS
SELECT name, otlet.export_watch(name) AS definition
FROM (VALUES (:'row_watch'), (:'pair_watch')) names(name);
CREATE TEMP TABLE watch_portability_before AS
SELECT
  (SELECT string_agg(c.oid::text || ':' || t.tgname, '|' ORDER BY c.oid, t.tgname)
   FROM pg_catalog.pg_trigger t
   JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
   WHERE NOT t.tgisinternal AND t.tgname LIKE 'otlet_%') AS trigger_signature,
  (SELECT count(*) FROM otlet.semantic_index_current_rows(:'row_watch', true)) AS row_count,
  otlet.semantic_join_matches(:'pair_watch', 'vendor-1001:vendor-42', '{"match":"same_entity"}'::jsonb) AS pair_same,
  otlet.semantic_join_matches(:'pair_watch', 'vendor-1001:vendor-77', '{"match":"different_entity"}'::jsonb) AS pair_different;
WITH imported AS MATERIALIZED (
  SELECT otlet.import_watch(definition, true)
  FROM watch_portability_definitions
)
SELECT
  (SELECT count(*) = 2 FROM imported)::text || '|' ||
  (SELECT bool_and(otlet.export_watch(name) = definition) FROM watch_portability_definitions)::text || '|' ||
  (
    (SELECT array_agg(key ORDER BY key)
     FROM jsonb_object_keys((SELECT definition FROM watch_portability_definitions WHERE name = :'row_watch')) key)
    =
    (SELECT array_agg(key ORDER BY key)
     FROM jsonb_object_keys((SELECT definition FROM watch_portability_definitions WHERE name = :'pair_watch')) key)
  )::text || '|' ||
  (SELECT bool_and(definition ->> 'format' = 'otlet.watch.v1') FROM watch_portability_definitions)::text || '|' ||
  (SELECT bool_and(NOT definition ?| ARRAY['task_name','created_at','updated_at','artifact_path','jobs','receipts']) FROM watch_portability_definitions)::text || '|' ||
  (SELECT bool_and(definition::text NOT LIKE '%Payment exceeds the declared approval threshold%') FROM watch_portability_definitions)::text || '|' ||
  ((SELECT trigger_signature FROM watch_portability_before) =
   (SELECT string_agg(c.oid::text || ':' || t.tgname, '|' ORDER BY c.oid, t.tgname)
    FROM pg_catalog.pg_trigger t
    JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
    WHERE NOT t.tgisinternal AND t.tgname LIKE 'otlet_%'))::text || '|' ||
  ((SELECT row_count FROM watch_portability_before) =
   (SELECT count(*) FROM otlet.semantic_index_current_rows(:'row_watch', true)))::text || '|' ||
  ((SELECT pair_same FROM watch_portability_before) =
   otlet.semantic_join_matches(:'pair_watch', 'vendor-1001:vendor-42', '{"match":"same_entity"}'::jsonb))::text || '|' ||
  ((SELECT pair_different FROM watch_portability_before) =
   otlet.semantic_join_matches(:'pair_watch', 'vendor-1001:vendor-77', '{"match":"different_entity"}'::jsonb))::text;
ROLLBACK;
SQL
)"
echo "watch_replace_contract=$watch_replace_contract"
[ "$watch_replace_contract" = "true|true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected watch replacement to preserve definitions, triggers, and lookup behavior, got $watch_replace_contract" >&2
  exit 1
}

watch_round_trip_contract="$(psql_exec -qAt \
  -v row_watch="$numeric_triage_watch" \
  -v pair_watch="$join_index_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE watch_round_trip_definitions AS
SELECT name, otlet.export_watch(name) AS definition
FROM (VALUES (:'row_watch'), (:'pair_watch')) names(name);
CREATE TEMP TABLE watch_round_trip_triggers AS
SELECT string_agg(c.oid::text || ':' || t.tgname, '|' ORDER BY c.oid, t.tgname) AS signature
FROM pg_catalog.pg_trigger t
JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
WHERE NOT t.tgisinternal AND t.tgname LIKE 'otlet_%';
DO $body$
DECLARE item record;
BEGIN
  FOR item IN SELECT * FROM watch_round_trip_definitions ORDER BY name LOOP
    PERFORM otlet.drop_watch(item.name);
    PERFORM otlet.import_watch(item.definition);
  END LOOP;
END
$body$;
SELECT
  (SELECT bool_and(otlet.export_watch(name) = definition) FROM watch_round_trip_definitions)::text || '|' ||
  (SELECT count(*) = 2 FROM otlet.watches WHERE name IN (:'row_watch', :'pair_watch'))::text || '|' ||
  (SELECT count(*) = 2 FROM otlet.tasks t JOIN otlet.watches w ON w.task_name = t.name WHERE w.name IN (:'row_watch', :'pair_watch'))::text || '|' ||
  ((SELECT count(*) FROM otlet.semantic_indexes WHERE name IN (:'row_watch', :'pair_watch')) +
   (SELECT count(*) FROM otlet.semantic_join_indexes WHERE name IN (:'row_watch', :'pair_watch')) = 2)::text || '|' ||
  ((SELECT signature FROM watch_round_trip_triggers) =
   (SELECT string_agg(c.oid::text || ':' || t.tgname, '|' ORDER BY c.oid, t.tgname)
    FROM pg_catalog.pg_trigger t
    JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
    WHERE NOT t.tgisinternal AND t.tgname LIKE 'otlet_%'))::text;
ROLLBACK;
SQL
)"
echo "watch_round_trip_contract=$watch_round_trip_contract"
[ "$watch_round_trip_contract" = "true|true|true|true|true" ] || {
  echo "Expected row and pair watch definitions to round trip, got $watch_round_trip_contract" >&2
  exit 1
}

watch_import_failure_contract="$(psql_exec -qAt \
  -v row_watch="$numeric_triage_watch" \
  -v pair_watch="$join_index_name" <<'SQL'
BEGIN;
CREATE FUNCTION pg_temp.expect_watch_import_error(definition jsonb, replace_existing boolean, expected text)
RETURNS boolean LANGUAGE plpgsql AS $function$
DECLARE actual text;
BEGIN
  BEGIN
    PERFORM otlet.import_watch(definition, replace_existing);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS actual = MESSAGE_TEXT;
    IF position(expected IN actual) = 0 THEN
      RAISE EXCEPTION 'expected %, got %', expected, actual;
    END IF;
    RETURN true;
  END;
  RAISE EXCEPTION 'expected import error containing %', expected;
END
$function$;
WITH definitions AS (
  SELECT otlet.export_watch(:'row_watch') AS row_definition,
         otlet.export_watch(:'pair_watch') AS pair_definition
), checks AS (
  SELECT pg_temp.expect_watch_import_error('null'::jsonb, false, 'must be a JSON object') AS ok FROM definitions
  UNION ALL SELECT pg_temp.expect_watch_import_error(row_definition || '{"format":"otlet.watch.v2"}', false, 'format must be otlet.watch.v1') FROM definitions
  UNION ALL SELECT pg_temp.expect_watch_import_error(row_definition || '{"extra":true}', false, 'unsupported key extra') FROM definitions
  UNION ALL SELECT pg_temp.expect_watch_import_error(row_definition - 'model_name', false, 'missing key model_name') FROM definitions
  UNION ALL SELECT pg_temp.expect_watch_import_error(row_definition || '{"model_name":"missing_model"}', false, 'model missing_model does not exist') FROM definitions
  UNION ALL SELECT pg_temp.expect_watch_import_error(jsonb_set(row_definition, '{model_artifact_identity,sha256}', to_jsonb(repeat('0', 64))), true, 'model artifact identity does not match') FROM definitions
  UNION ALL SELECT pg_temp.expect_watch_import_error(row_definition || '{"table_name":"public.missing_table"}', true, 'table public.missing_table does not exist') FROM definitions
  UNION ALL SELECT pg_temp.expect_watch_import_error(row_definition || '{"subject_column":"missing_column"}', true, 'subject column missing_column does not exist') FROM definitions
  UNION ALL SELECT pg_temp.expect_watch_import_error(pair_definition || jsonb_build_object('candidate_query', 'SELECT broken'), true, 'column "broken" does not exist') FROM definitions
  UNION ALL SELECT pg_temp.expect_watch_import_error(row_definition, false, 'already exists') FROM definitions
)
SELECT count(*)::text || '|' || bool_and(ok)::text FROM checks;
ROLLBACK;
SQL
)"
echo "watch_import_failure_contract=$watch_import_failure_contract"
[ "$watch_import_failure_contract" = "10|true" ] || {
  echo "Expected ten watch import failures to roll back cleanly, got $watch_import_failure_contract" >&2
  exit 1
}

join_customscan_plan="$(
  psql_exec -P border=2 -P null='' -v index_name="$join_index_name" <<'SQL'
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT subject_id
FROM (
  SELECT subject_id
  FROM public.otlet_demo_vendor_pair_input
  OFFSET 0
) pair_subjects
WHERE otlet.semantic_join_matches_auto(:'index_name', subject_id, '{"match":"same_entity"}'::jsonb);
SQL
)"
printf '%s\n' "$join_customscan_plan"
require_contains "$join_customscan_plan" "Otlet Node: Semantic Source CustomScan" "Expected join CustomScan explain details"
require_contains "$join_customscan_plan" "Semantic Index Kind: join" "Expected join CustomScan index kind"
require_contains "$join_customscan_plan" "Planner Selected Path: semantic_join_lookup" "Expected join CustomScan lookup path"
require_contains "$join_customscan_plan" "Count Basis: estimated" "Expected join CustomScan estimated count basis"
require_contains "$join_customscan_plan" "Model Cost Source:" "Expected join CustomScan model cost source"
require_contains "$join_customscan_plan" "Preloaded Fresh Subjects / Basis: 4" "Expected join CustomScan preload count and basis"
require_contains "$join_customscan_plan" "Emitted Freshness Basis:" "Expected join CustomScan emitted freshness basis breakdown"
require_contains "$join_customscan_plan" "Actual Fresh Subjects: 4" "Expected join CustomScan fresh count"
require_contains "$join_customscan_plan" "Actual Stale Subjects: 0" "Expected join CustomScan stale count"
require_contains "$join_customscan_plan" "Actual Lookup Rows: 4" "Expected join CustomScan lookup rows"
require_contains "$join_customscan_plan" "Infer Now Batches: 0" "Expected join CustomScan zero infer-now"
require_contains "$join_customscan_plan" "Child Plan Source Rows: 4" "Expected join CustomScan child rows"

join_current_row_contract="$(psql_exec -qAt -v index_name="$join_index_name" <<'SQL'
SELECT count(*)::text
FROM otlet.semantic_join_index_current_rows(:'index_name', true)
WHERE subject_id = 'vendor-1001:vendor-42';
SELECT selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       queue_subjects::text || '|' ||
       count_basis
FROM otlet.semantic_join_index_plan(:'index_name', true);
SQL
)"
join_subject_rows="$(head -n 1 <<<"$join_current_row_contract")"
join_sql_plan="$(tail -n 1 <<<"$join_current_row_contract")"
echo "semantic_join_current_row_contract=$join_subject_rows|$join_sql_plan"
[ "$join_subject_rows" = "1" ] || {
  echo "Expected semantic join current-row SQL to expose vendor-1001:vendor-42, got $join_subject_rows" >&2
  exit 1
}
require_regex "$join_sql_plan" '^semantic_join_lookup\|4\|4\|0\|0\|' "Expected semantic join SQL plan lookup with four fresh subjects"
