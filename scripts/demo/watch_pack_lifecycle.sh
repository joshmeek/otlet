log "Checking watch pack lifecycle"
watch_pack_contract="$(psql_exec -qAt -v pack_watch="$join_index_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE pack_params AS
SELECT :'pack_watch'::text AS pack_watch;
CREATE TEMP TABLE pack_before AS
SELECT
  otlet.export_watch(:'pack_watch') AS definition,
  (SELECT count(*) FROM otlet.watch_pack_versions) AS version_count,
  (SELECT count(*) FROM otlet.watch_pack_heads) AS head_count;

CREATE TEMP TABLE pack_v1 AS
SELECT otlet.validate_watch_pack(
  (definition - 'content_digest') || jsonb_build_object(
    'version_metadata', '{"version":"1.0.0","release":"fixture-baseline"}'::jsonb,
    'fixtures', '[
      {"subject_id":"fixture-b","input":{"right":"b","left":"a"}},
      {"subject_id":"fixture-a","input":{"left":"a","right":"a"}}
    ]'::jsonb,
    'labels', '[
      {"subject_id":"fixture-b","expected":"different_entity"},
      {"subject_id":"fixture-a","expected":"same_entity"}
    ]'::jsonb,
    'expected_receipts', '[{"attempts":2,"accepted_role":"strong"}]'::jsonb,
    'evaluation_gates', '{"min_quality":0.90,"max_abstention":0.20}'::jsonb
  )
) AS definition
FROM pack_before;

CREATE TEMP TABLE pack_lint AS
SELECT * FROM otlet.lint_watch_pack((SELECT definition FROM pack_v1));
CREATE TEMP TABLE pack_dry_run AS
SELECT otlet.dry_run_watch_pack((SELECT definition FROM pack_v1)) AS definition;
CREATE TEMP TABLE pack_lint_state AS
SELECT
  (SELECT version_count FROM pack_before) = (SELECT count(*) FROM otlet.watch_pack_versions) AS versions_unchanged,
  (SELECT head_count FROM pack_before) = (SELECT count(*) FROM otlet.watch_pack_heads) AS heads_unchanged,
  (SELECT definition FROM pack_before) = otlet.export_watch(:'pack_watch') AS watch_unchanged;

CREATE TEMP TABLE pack_v1_reordered AS
SELECT otlet.validate_watch_pack(
  (definition - 'content_digest') || jsonb_build_object(
    'fixtures', '[
      {"input":{"right":"a","left":"a"},"subject_id":"fixture-a"},
      {"input":{"left":"a","right":"b"},"subject_id":"fixture-b"}
    ]'::jsonb,
    'labels', '[
      {"expected":"same_entity","subject_id":"fixture-a"},
      {"expected":"different_entity","subject_id":"fixture-b"}
    ]'::jsonb
  )
) AS definition
FROM pack_v1;

SELECT otlet.import_watch((SELECT definition FROM pack_v1), true) \gset pack_import_v1_
CREATE TEMP TABLE pack_v1_import_state AS
SELECT otlet.export_watch(:'pack_watch') = (SELECT definition FROM pack_v1) AS exact;

CREATE TEMP TABLE pack_v2 AS
SELECT otlet.validate_watch_pack(
  (definition - 'content_digest') || jsonb_build_object(
    'instruction', definition ->> 'instruction' || ' Pack lifecycle version two',
    'version_metadata', '{"version":"2.0.0","release":"quality-gate"}'::jsonb,
    'fixtures', '[{"subject_id":"fixture-c","input":{"left":"c","right":"c"}}]'::jsonb,
    'labels', '[{"subject_id":"fixture-c","expected":"same_entity"}]'::jsonb,
    'expected_receipts', '[{"attempts":1,"accepted_role":"cheap"}]'::jsonb,
    'evaluation_gates', '{"min_quality":0.95,"max_abstention":0.10}'::jsonb
  )
) AS definition
FROM pack_v1;

CREATE TEMP TABLE pack_diff AS
SELECT *
FROM otlet.diff_watch_packs(
  (SELECT definition FROM pack_v1),
  (SELECT definition FROM pack_v2)
);
SELECT otlet.import_watch((SELECT definition FROM pack_v2), true) \gset pack_import_v2_

CREATE FUNCTION pg_temp.watch_pack_history_is_immutable(operation text)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    IF operation = 'update' THEN
      UPDATE otlet.watch_pack_versions
      SET content_digest = repeat('0', 32)
      WHERE watch_name = (SELECT pack_watch FROM pack_params) AND version_number = 1;
    ELSIF operation = 'delete' THEN
      DELETE FROM otlet.watch_pack_versions
      WHERE watch_name = (SELECT pack_watch FROM pack_params) AND version_number = 1;
    ELSE
      TRUNCATE otlet.watch_pack_heads, otlet.watch_pack_versions;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM = 'otlet watch pack history is immutable';
  END;
  RETURN false;
END;
$function$;

CREATE TEMP TABLE pack_immutability AS
SELECT
  pg_temp.watch_pack_history_is_immutable('update') AS update_immutable,
  pg_temp.watch_pack_history_is_immutable('delete') AS delete_immutable,
  pg_temp.watch_pack_history_is_immutable('truncate') AS truncate_immutable;

CREATE TEMP TABLE pack_before_rollback AS
SELECT
  count(*) = 2 AS two_versions,
  count(*) FILTER (WHERE current_version) = 1 AS one_current,
  max(version_number) FILTER (WHERE current_version) = 2 AS version_two_current,
  bool_and(candidate_query IS NOT NULL) AS candidate_sql_recorded,
  bool_and(jsonb_typeof(output_schema) = 'object') AS schemas_recorded,
  bool_and(jsonb_typeof(model_policy) = 'object') AS model_policy_recorded,
  bool_and(jsonb_typeof(fixtures) = 'array') AS fixtures_recorded,
  bool_and(jsonb_typeof(labels) = 'array') AS labels_recorded,
  bool_and(jsonb_typeof(expected_receipts) = 'array') AS receipts_recorded,
  bool_and(jsonb_typeof(evaluation_gates) = 'object') AS gates_recorded
FROM otlet.watch_pack_history
WHERE watch_name = :'pack_watch';

SELECT otlet.rollback_watch_pack(:'pack_watch', 1) \gset pack_rollback_

SELECT
  (
    (SELECT valid FROM pack_lint)
    AND (SELECT content_digest FROM pack_lint) = (SELECT definition ->> 'content_digest' FROM pack_v1)
  )::text || '|' ||
  ((SELECT definition FROM pack_dry_run) = (SELECT definition FROM pack_v1))::text || '|' ||
  (
    SELECT (versions_unchanged AND heads_unchanged AND watch_unchanged)::text
    FROM pack_lint_state
  ) || '|' ||
  (SELECT exact::text FROM pack_v1_import_state) || '|' ||
  (
    (SELECT definition ->> 'content_digest' FROM pack_v1) =
      (SELECT definition ->> 'content_digest' FROM pack_v1_reordered)
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.diff_watch_packs(
        (SELECT definition FROM pack_v1),
        (SELECT definition FROM pack_v1_reordered)
      )
    )
  )::text || '|' ||
  ((SELECT string_agg(field_name, ',' ORDER BY field_name) FROM pack_diff) =
    'evaluation_gates,expected_receipts,fixtures,instruction,labels,version_metadata')::text || '|' ||
  (
    SELECT (
      two_versions AND one_current AND version_two_current AND candidate_sql_recorded
      AND schemas_recorded AND model_policy_recorded AND fixtures_recorded
      AND labels_recorded AND receipts_recorded AND gates_recorded
    )::text
    FROM pack_before_rollback
  ) || '|' ||
  (
    SELECT (
      count(*) = 3
      AND count(*) FILTER (WHERE current_version) = 1
      AND max(version_number) FILTER (WHERE current_version) = 3
    )::text
    FROM otlet.watch_pack_history
    WHERE watch_name = :'pack_watch'
  ) || '|' ||
  (otlet.export_watch(:'pack_watch') = (SELECT definition FROM pack_v1))::text || '|' ||
  (
    SELECT (content_digest = (SELECT definition ->> 'content_digest' FROM pack_v1))::text
    FROM otlet.watch_pack_history
    WHERE watch_name = :'pack_watch' AND current_version
  ) || '|' ||
  (
    SELECT update_immutable::text || '|' || delete_immutable::text || '|' || truncate_immutable::text
    FROM pack_immutability
  );
ROLLBACK;
SQL
)"
echo "watch_pack_contract=$watch_pack_contract"
[ "$watch_pack_contract" = "true|true|true|true|true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected watch pack lint, dry run, semantic diff, history, and rollback to hold, got $watch_pack_contract" >&2
  exit 1
}
