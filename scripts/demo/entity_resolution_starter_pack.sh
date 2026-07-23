log "Checking entity-resolution starter pack"

psql_exec \
  -v strong_model_name="$strong_model_name" \
  -f /work/examples/entity-resolution-starter-pack.sql >/dev/null

starter_queued="$(psql_candidate_value <<'SQL'
SELECT otlet.refresh_semantic_join_index('entity_resolution_starter');
SQL
)"
[ "$starter_queued" = "6" ] || {
  echo "Expected six starter-pack jobs, got $starter_queued" >&2
  exit 1
}

wait_task_complete "entity_resolution_starter_task" 6 1800 1

psql_exec >/dev/null <<'SQL'
SELECT action_review.*
FROM (
  SELECT action.id
  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  JOIN public.otlet_entity_resolution_starter_pair pair ON pair.pair_id = job.subject_id
  WHERE job.task_name = 'entity_resolution_starter_task'
    AND pair.expected_match = 'same_entity'
) action
CROSS JOIN LATERAL otlet.approve_action(action.id, 'starter pack approval') action_review;

SELECT otlet.materialize_semantic_join_index('entity_resolution_starter');
SQL

psql_exec -qAt >/dev/null <<'SQL'
WITH identity AS (
  SELECT
    receipt.model_name,
    receipt.trace_summary #>> '{runtime_fingerprint,output_contract,prompt_template,hash}' AS prompt_version,
    receipt.output_schema_hash AS schema_version,
    receipt.trace_summary ->> 'runtime_fingerprint_hash' AS runtime_version
  FROM otlet.inference_receipts receipt
  WHERE receipt.task_name = 'entity_resolution_starter_task'
    AND receipt.selection_status = 'accepted'
  ORDER BY receipt.id
  LIMIT 1
)
SELECT evaluation.*
FROM identity
CROSS JOIN LATERAL otlet.evaluate_workload(
  'entity_resolution_starter_v1',
  'entity_resolution_starter',
  NULL,
  jsonb_build_object(
    'model_name', identity.model_name,
    'prompt_version', identity.prompt_version,
    'schema_version', identity.schema_version,
    'runtime_version', identity.runtime_version,
    'pack_name', 'entity_resolution_starter',
    'pack_version', 1
  )
) evaluation;
SQL

starter_pack_contract="$(psql_value <<'SQL'
WITH result_contract AS (
  SELECT
    count(*) = 6
      AND count(*) FILTER (WHERE run.output ->> 'match' = pair.expected_match) = 6
      AND count(*) FILTER (WHERE run.schema_validation_status = 'passed') = 6 AS valid
  FROM otlet.runs run
  JOIN public.otlet_entity_resolution_starter_pair pair ON pair.pair_id = run.subject_id
  WHERE run.task_name = 'entity_resolution_starter_task'
), receipt_contract AS (
  SELECT count(*) = 6
    AND bool_and(receipt.selection_role = 'direct')
    AND bool_and(receipt.selection_status = 'accepted')
    AND bool_and(receipt.schema_validation_status = 'passed') AS valid
  FROM otlet.inference_receipts receipt
  WHERE receipt.task_name = 'entity_resolution_starter_task'
), action_contract AS (
  SELECT count(*) = 6
    AND count(*) FILTER (
      WHERE pair.expected_match = 'same_entity' AND action.action_type = 'merge_candidate'
    ) = 3
    AND count(*) FILTER (
      WHERE pair.expected_match = 'different_entity' AND action.action_type = 'new_entity'
    ) = 3 AS valid
  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  JOIN public.otlet_entity_resolution_starter_pair pair ON pair.pair_id = job.subject_id
  WHERE job.task_name = 'entity_resolution_starter_task'
    AND action.action_type IN ('merge_candidate', 'new_entity')
), pack AS (
  SELECT otlet.export_watch('entity_resolution_starter') AS definition
), pack_contract AS (
  SELECT
    jsonb_array_length(definition -> 'fixtures') = 6
      AND jsonb_array_length(definition -> 'labels') = 6
      AND jsonb_array_length(definition -> 'expected_receipts') = 6
      AND jsonb_array_length(definition -> 'review_outcomes') = 6
      AND definition #>> '{selection_policy,mode}' = 'single_model'
      AND jsonb_typeof(definition -> 'evaluation_gates') = 'object'
      AND definition ->> 'candidate_query' LIKE '%LIMIT 100%'
      AND definition ->> 'instruction' <> ''
      AND jsonb_typeof(definition -> 'output_schema') = 'object' AS valid
  FROM pack
), fixture_contract AS (
  SELECT count(DISTINCT fixture ->> 'fixture_kind') = 3
    AND string_agg(DISTINCT fixture ->> 'fixture_kind', ',' ORDER BY fixture ->> 'fixture_kind') =
      'account,catalog_item,vendor' AS valid
  FROM pack
  CROSS JOIN LATERAL jsonb_array_elements(definition -> 'fixtures') fixture
), review_contract AS (
  SELECT count(*) = 3
    AND bool_and(event.outcome = 'approve')
    AND bool_and(event.reason = 'starter pack approval') AS valid
  FROM otlet.review_events event
  WHERE event.task_name = 'entity_resolution_starter_task'
), materialization_contract AS (
  SELECT count(*) = 6 AS valid
  FROM otlet.semantic_materializations
  WHERE task_name = 'entity_resolution_starter_task'
    AND NOT stale
), evaluation_contract AS (
  SELECT
    case_count = 6
      AND coverage = 1
      AND quality = 1
      AND abstention = 0
      AND action_quality = 1
      AND gate_status = 'passed' AS valid
  FROM otlet.workload_evaluation_status
  WHERE name = 'entity_resolution_starter_v1'
)
SELECT
  (SELECT valid FROM result_contract)::text || '|' ||
  (SELECT valid FROM receipt_contract)::text || '|' ||
  (SELECT valid FROM action_contract)::text || '|' ||
  (SELECT valid FROM pack_contract)::text || '|' ||
  (SELECT valid FROM fixture_contract)::text || '|' ||
  (SELECT valid FROM review_contract)::text || '|' ||
  (SELECT valid FROM materialization_contract)::text || '|' ||
  (SELECT valid FROM evaluation_contract)::text || '|' ||
  ((SELECT count(*) FROM otlet.eval_labels WHERE workload_name = 'entity_resolution_starter') = 6)::text || '|' ||
  ((SELECT count(*) FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet' AND function.proname LIKE 'entity_resolution%') = 0)::text;
SQL
)"

echo "entity_resolution_starter_contract=$starter_pack_contract"
[ "$starter_pack_contract" = "true|true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected starter pack import, run, review, evaluation, and common-contract reuse, got $starter_pack_contract" >&2
  exit 1
}

starter_rollback_contract="$(psql_value <<'SQL'
BEGIN;
CREATE TEMP TABLE baseline AS
SELECT otlet.export_watch('entity_resolution_starter') AS definition;
CREATE TEMP TABLE candidate AS
SELECT otlet.validate_watch_pack(
  (definition - 'content_digest') || jsonb_build_object(
    'instruction', definition ->> 'instruction' || ' Candidate revision',
    'version_metadata', '{"version":"2.0.0","workload":"entity_resolution","policy":"single_strong_local"}'::jsonb
  )
) AS definition
FROM baseline;
CREATE TEMP TABLE imported_candidate AS
SELECT * FROM otlet.import_watch((SELECT definition FROM candidate), true);
CREATE TEMP TABLE restored AS
SELECT * FROM otlet.rollback_watch_pack('entity_resolution_starter', 1);

SELECT
  ((SELECT count(*) FROM otlet.diff_watch_packs(
    (SELECT definition FROM baseline),
    (SELECT definition FROM candidate)
  )) = 2)::text || '|' ||
  ((SELECT count(*) FROM otlet.watch_pack_history
    WHERE watch_name = 'entity_resolution_starter') = 3)::text || '|' ||
  ((SELECT count(*) FROM otlet.watch_pack_history
    WHERE watch_name = 'entity_resolution_starter' AND current_version) = 1)::text || '|' ||
  (otlet.export_watch('entity_resolution_starter') = (SELECT definition FROM baseline))::text || '|' ||
  ((SELECT review_outcomes FROM otlet.watch_pack_history
    WHERE watch_name = 'entity_resolution_starter' AND current_version) =
   (SELECT definition -> 'review_outcomes' FROM baseline))::text;
ROLLBACK;
SQL
)"

echo "entity_resolution_starter_rollback_contract=$starter_rollback_contract"
[ "$starter_rollback_contract" = "true|true|true|true|true" ] || {
  echo "Expected starter pack semantic diff and exact rollback, got $starter_rollback_contract" >&2
  exit 1
}
