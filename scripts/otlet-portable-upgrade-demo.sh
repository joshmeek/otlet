#!/usr/bin/env bash
set -euo pipefail

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
database="otlet_portable_upgrade_demo_$$"
operator_role="otlet_portable_upgrade_operator_$$"
reviewer_role="otlet_portable_upgrade_reviewer_$$"
reviewer_login="otlet_portable_upgrade_reviewer_login_$$"
application_role="otlet_portable_upgrade_application_$$"
partial_auditor_role="otlet_portable_upgrade_partial_auditor_$$"
preflight_role="otlet_portable_upgrade_preflight_$$"

cleanup() {
  docker exec "$container" dropdb -U postgres --if-exists "$database" >/dev/null 2>&1 || true
  docker exec "$container" psql -U postgres -d postgres -X -q \
    -c "DROP ROLE IF EXISTS $reviewer_login, $reviewer_role, $operator_role, $application_role, $partial_auditor_role, $preflight_role" >/dev/null 2>&1 || true
}
trap cleanup EXIT

install_portable() {
  docker exec -w /work "$container" \
    psql -U postgres -d "$database" -X -q -v ON_ERROR_STOP=1 \
    -f crates/otlet_worker/sql/install.sql
}

install_portable_through_79() {
  docker exec -w /work/crates/otlet_worker/sql "$container" \
    sed '/0080_model_bound_context_budgets.sql/,$d' migrate.sql |
    docker exec -i -w /work/crates/otlet_worker/sql "$container" \
      psql -U postgres -d "$database" -X -q -v ON_ERROR_STOP=1 --single-transaction
}

claim_probe_jobs() {
  docker exec "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -c "SELECT count(*) FROM otlet.claim_jobs('model_concurrency_probe', $1)"
}

model_capacity_contract() {
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  status.active_claimed_jobs,
  status.max_active_jobs,
  status.available_active_job_slots,
  status.running_jobs,
  status.cancel_requested_jobs,
  status.expired_running_jobs,
  status.queued_jobs,
  (SELECT count(*) FROM otlet.verify_invariants() violation
   WHERE violation.invariant_name = 'active_claimed_jobs_within_model_cap')
)
FROM otlet.model_queue_status status
WHERE status.model_name = 'model_concurrency_probe';
SQL
}

cleanup
docker exec "$container" createdb -U postgres "$database"
docker exec -i "$container" psql -U postgres -d postgres \
  -X -q -v ON_ERROR_STOP=1 -v database="$database" <<'SQL' >/dev/null
SELECT format(
  'ALTER DATABASE %I SET otlet.administrative_reason = %L',
  :'database',
  'portable upgrade executable proof'
) \gexec
SQL
install_portable_through_79

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE TABLE public.portable_upgrade_sentinel (
  id integer PRIMARY KEY,
  value text NOT NULL,
  export_function_oid oid,
  export_function_acl text,
  audit_review_oid oid,
  audit_review_acl text,
  production_policy_status_oid oid,
  production_policy_status_acl text,
  preflight_function_oid oid,
  preflight_function_acl text,
  semantic_index_plan_oid oid,
  semantic_index_plan_acl text,
  planner_statistics_version bigint,
  planner_statistics_refreshed_at timestamptz,
  legacy_watch_revision_hash text,
  legacy_materialization_id bigint,
  legacy_workload_pack_hash text
);
INSERT INTO public.portable_upgrade_sentinel VALUES (1, 'preserved');
SQL

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 \
  -v operator_role="$operator_role" \
  -v application_role="$application_role" \
  -v partial_auditor_role="$partial_auditor_role" \
  -v preflight_role="$preflight_role" <<'SQL' >/dev/null
CREATE ROLE :"operator_role" NOLOGIN;
CREATE ROLE :"application_role" NOLOGIN;
CREATE ROLE :"partial_auditor_role" NOLOGIN;
CREATE ROLE :"preflight_role" NOLOGIN;
SELECT otlet.grant_application_access(:'application_role'::regrole);
SELECT otlet.access_policy_revision(:'operator_role'::regrole)
  AS operator_old_revision \gset
GRANT USAGE ON SCHEMA otlet TO :"operator_role";
GRANT USAGE ON TYPE
  otlet.actions,
  otlet.eval_labels,
  otlet.review_events
TO :"operator_role";
GRANT SELECT ON TABLE
  otlet.redaction_policy_status,
  otlet.audit_receipt_export,
  otlet.audit_review_export,
  otlet.audit_review_event_export,
  otlet.audit_action_execution_export,
  otlet.audit_eval_label_export,
  otlet.audit_administrative_change_export,
  otlet.action_workflow_policy_status,
  otlet.semantic_dependency_audit,
  otlet.operational_event_log,
  otlet.worker_batch_timing_status,
  otlet.portable_protocol_status,
  otlet.runtime_capability_status,
  otlet.portable_worker_status,
  otlet.portable_claim_status,
  otlet.portable_receipt_status,
  otlet.failure_taxonomy,
  otlet.failure_retry_status,
  otlet.task_queue_status,
  otlet.task_resource_status,
  otlet.production_policy_status,
  otlet.audit_semantic_correction_export
TO :"operator_role";
GRANT EXECUTE ON FUNCTION
  otlet.approve_action(bigint, text),
  otlet.reject_action(bigint, text, text),
  otlet.label_action(bigint, text, text, text, text, text),
  otlet.correct_action(bigint, jsonb, text),
  otlet.defer_action(bigint, text),
  otlet.abstain_review(bigint, text),
  otlet.dry_run_action(bigint),
  otlet.apply_action(bigint),
  otlet.application_retry_job(bigint, text),
  otlet.export_eval_cases(integer),
  otlet.entity_graph_conflict_status_for_task(text),
  otlet.semantic_correction_status_for_task(text),
  otlet.approve_semantic_correction(
    bigint, bigint, jsonb, timestamptz, numeric, text, text
  )
TO :"operator_role";
SELECT otlet.finish_access_policy_grant(
  'operator',
  :'operator_role'::regrole,
  :'operator_old_revision'
);
GRANT USAGE ON SCHEMA otlet TO :"partial_auditor_role";
GRANT SELECT ON TABLE otlet.audit_review_export TO :"partial_auditor_role";
GRANT USAGE ON SCHEMA otlet TO :"preflight_role";
UPDATE public.portable_upgrade_sentinel sentinel
SET export_function_oid = function.oid,
    export_function_acl = function.proacl::text
FROM pg_catalog.pg_proc function
WHERE sentinel.id = 1
  AND function.oid = 'otlet.export_eval_cases(integer)'::regprocedure;
UPDATE public.portable_upgrade_sentinel sentinel
SET audit_review_oid = relation.oid,
    audit_review_acl = relation.relacl::text
FROM pg_catalog.pg_class relation
WHERE sentinel.id = 1
  AND relation.oid = 'otlet.audit_review_export'::regclass;
UPDATE public.portable_upgrade_sentinel sentinel
SET production_policy_status_oid = relation.oid,
    production_policy_status_acl = relation.relacl::text
FROM pg_catalog.pg_class relation
WHERE sentinel.id = 1
  AND relation.oid = 'otlet.production_policy_status'::regclass;
UPDATE public.portable_upgrade_sentinel sentinel
SET semantic_index_plan_oid = function.oid,
    semantic_index_plan_acl = function.proacl::text
FROM pg_catalog.pg_proc function
WHERE sentinel.id = 1
  AND function.oid =
    'otlet.semantic_index_plan(text,boolean,text)'::regprocedure;

SELECT otlet.register_model(
  'model_concurrency_probe',
  '/tmp/model_concurrency_probe.gguf',
  repeat('1', 64),
  jsonb_build_object(
    'sha256', repeat('1', 64),
    'bytes', 1,
    'source', 'portable-upgrade-demo',
    'revision', 'model-concurrency-v1',
    'quantization', 'test',
    'license', 'test'
  ),
  3
);
SELECT otlet.create_task(
  task_name => 'model_concurrency_probe',
  input_query => NULL,
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'model_concurrency_probe',
  input_shaping => '{"source_fields":["value"]}'::jsonb
);
SELECT otlet.create_task(
  task_name => 'decision_evidence_legacy',
  input_query => NULL,
  instruction => 'Return a legacy business evidence field',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'model_concurrency_probe',
  input_shaping => '{"source_fields":["value"]}'::jsonb
);
INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  started_at,
  leased_until,
  claim_token
) VALUES (
  'decision_evidence_legacy',
  'pre-0071',
  '{"value":"legacy"}'::jsonb,
  'running',
  1,
  now(),
  now() + interval '5 minutes',
  'decision-evidence-legacy-token'
);

CREATE TABLE public.portable_time_legacy_source (
  id text PRIMARY KEY,
  payload text NOT NULL
);
INSERT INTO public.portable_time_legacy_source
VALUES ('legacy-row', 'legacy');
SELECT otlet.create_watch(
  watch_name => 'portable_time_legacy',
  kind => 'row',
  instruction => 'Return the decision',
  output_schema => '{"type":"object","properties":{"decision":{"type":"string"}},"required":["decision"],"additionalProperties":false}'::jsonb,
  model_name => 'model_concurrency_probe',
  table_name => 'public.portable_time_legacy_source'::regclass,
  subject_column => 'id',
  input_columns => ARRAY['id', 'payload']
) \g /dev/null

DO $proof$
DECLARE
  revision_definition jsonb;
  revision_hash text;
  baseline_pack jsonb;
  candidate_pack jsonb;
  prepared_pack_hash text;
  input jsonb;
  record_id bigint;
  materialization_id bigint;
BEGIN
  SELECT revision.definition, revision.workload_revision_hash
  INTO STRICT revision_definition, revision_hash
  FROM otlet.workload_revisions revision
  JOIN otlet.workload_revision_heads head
    ON head.active_workload_revision_hash = revision.workload_revision_hash
  WHERE head.task_name = 'portable_time_legacy_task';
  baseline_pack := otlet.export_workload_pack('portable_time_legacy', 1);
  candidate_pack := jsonb_set(
    jsonb_set(baseline_pack, '{version}', '2'::jsonb),
    '{watch,instruction}',
    to_jsonb('Return the upgraded legacy decision'::text)
  );
  prepared_pack_hash := otlet.prepare_workload_pack(
    candidate_pack,
    otlet.workload_pack_spec_hash(baseline_pack),
    revision_hash,
    'Prepare a six-field legacy workload pack',
    'PORTABLE-UPGRADE'
  );
  input := otlet.task_subject_input(
    revision_definition #>> '{task,input_query}',
    'legacy-row',
    revision_definition
  );
  INSERT INTO otlet.records (record_type, subject_id, body)
  VALUES ('portable_time_legacy', 'legacy-row', '{"decision":"keep"}'::jsonb)
  RETURNING id INTO record_id;
  INSERT INTO otlet.semantic_materializations (
    record_id,
    record_type,
    source_table,
    subject_id,
    source_dependencies,
    task_name,
    model_name,
    body,
    source_hash,
    content_hash,
    contract_hash,
    freshness_basis,
    created_at,
    updated_at
  ) VALUES (
    record_id,
    'portable_time_legacy',
    'public.portable_time_legacy_source',
    'legacy-row',
    otlet.semantic_input_dependencies(input),
    'portable_time_legacy_task',
    'model_concurrency_probe',
    '{"decision":"keep"}'::jsonb,
    otlet.semantic_source_hash(input),
    otlet.semantic_content_hash(input, revision_definition #> '{task,input_shaping}'),
    revision_hash,
    'content_hash_match',
    statement_timestamp() - interval '1 day',
    statement_timestamp() - interval '1 day'
  ) RETURNING id INTO materialization_id;
  UPDATE public.portable_upgrade_sentinel
  SET legacy_watch_revision_hash = revision_hash,
      legacy_materialization_id = materialization_id,
      legacy_workload_pack_hash = prepared_pack_hash
  WHERE id = 1;
END;
$proof$;

UPDATE otlet.production_policy
SET max_input_bytes_per_job = 1024,
    max_queued_input_bytes_per_task = 4096,
    max_queued_input_bytes_per_model = 4096,
    max_queued_input_bytes_total = 4096
WHERE name = 'default';
SQL

install_portable

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
BEGIN READ ONLY;
DO $proof$
DECLARE
  revision_hash text;
  version_before bigint;
  refreshed_before timestamptz;
BEGIN
  IF NOT (
    SELECT customscan_preload_max_rows = 100000
      AND customscan_preload_max_bytes = 67108864
      AND customscan_preload_max_ms = 30000
    FROM otlet.production_policy_status
  ) THEN
    RAISE EXCEPTION 'portable CustomScan preload defaults are invalid';
  END IF;
  SELECT legacy_watch_revision_hash
  INTO STRICT revision_hash
  FROM public.portable_upgrade_sentinel
  WHERE id = 1;
  SELECT statistics_version, refreshed_at
  INTO STRICT version_before, refreshed_before
  FROM otlet.semantic_planner_statistics
  WHERE task_name = 'portable_time_legacy_task'
    AND workload_revision_hash = revision_hash;
  IF NOT (
    SELECT total_subjects = 1
      AND fresh_subjects = 1
      AND stale_subjects = 0
      AND missing_subjects = 0
      AND count_basis = 'maintained'
    FROM otlet.semantic_index_plan(
      'portable_time_legacy', false, revision_hash
    )
  ) THEN
    RAISE EXCEPTION 'portable semantic planner snapshot is invalid';
  END IF;
  IF NOT (
    SELECT total_subjects = 1
      AND fresh_matches = 1
      AND fresh_non_matches = 0
      AND stale_subjects = 0
      AND missing_subjects = 0
      AND count_basis = 'exact_predicate_diagnostic'
    FROM otlet.semantic_predicate_counts(
      'portable_time_legacy', '{"decision":"keep"}'::jsonb, revision_hash
    )
  ) THEN
    RAISE EXCEPTION 'portable semantic predicate diagnostic is invalid';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.semantic_planner_statistics
    WHERE task_name = 'portable_time_legacy_task'
      AND workload_revision_hash = revision_hash
      AND (
        statistics_version IS DISTINCT FROM version_before
        OR refreshed_at IS DISTINCT FROM refreshed_before
      )
  ) THEN
    RAISE EXCEPTION 'portable semantic planning changed its snapshot';
  END IF;
  BEGIN
    PERFORM *
    FROM otlet.semantic_predicate_counts(
      'portable_time_legacy', NULL, revision_hash
    );
    RAISE EXCEPTION 'portable semantic predicate diagnostic accepted null expected json';
  EXCEPTION WHEN OTHERS THEN
    IF position('require expected json' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;
  BEGIN
    PERFORM *
    FROM otlet.semantic_index_plan(
      'portable_time_legacy', false, repeat('0', 64)
    );
    RAISE EXCEPTION 'portable semantic planner accepted a stale revision';
  EXCEPTION WHEN OTHERS THEN
    IF position('workload revision changed' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;
END;
$proof$;
ROLLBACK;

BEGIN;
INSERT INTO public.portable_time_legacy_source
VALUES ('missing-row', 'missing');
DO $proof$
BEGIN
  IF NOT (
    SELECT total_subjects = 2
      AND fresh_subjects = 1
      AND stale_subjects = 0
      AND missing_subjects = 1
      AND count_basis = 'maintained'
    FROM otlet.semantic_planner_statistics_status
    WHERE task_name = 'portable_time_legacy_task'
  ) THEN
    RAISE EXCEPTION 'portable semantic source maintenance is invalid';
  END IF;
END;
$proof$;
ROLLBACK;

BEGIN;
DO $proof$
DECLARE
  trigger_name name;
BEGIN
  FOR trigger_name IN
    SELECT trigger_row.tgname
    FROM pg_catalog.pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
        'public.portable_time_legacy_source'::regclass
      AND trigger_row.tgfoid =
        'otlet.watch_change_trigger()'::regprocedure::oid
      AND NOT trigger_row.tgisinternal
  LOOP
    EXECUTE format(
      'ALTER TABLE public.portable_time_legacy_source DISABLE TRIGGER %I',
      trigger_name
    );
  END LOOP;
END;
$proof$;
UPDATE public.portable_time_legacy_source
SET id = 'moved-row'
WHERE id = 'legacy-row';
DO $proof$
DECLARE
  revision_hash text;
  revision_definition jsonb;
BEGIN
  SELECT sentinel.legacy_watch_revision_hash, revision.definition
  INTO STRICT revision_hash, revision_definition
  FROM public.portable_upgrade_sentinel sentinel
  JOIN otlet.workload_revisions revision
    ON revision.task_name = 'portable_time_legacy_task'
   AND revision.workload_revision_hash = sentinel.legacy_watch_revision_hash
  WHERE sentinel.id = 1;
  IF NOT (
    SELECT total_subjects = 1
      AND fresh_subjects = 0
      AND stale_subjects = 0
      AND missing_subjects = 1
      AND count_basis = 'maintained'
    FROM otlet.semantic_planner_statistics_status
    WHERE task_name = 'portable_time_legacy_task'
  ) OR NOT (
    SELECT total_subjects = 1
      AND fresh_subjects = 0
      AND stale_subjects = 0
      AND missing_subjects = 1
    FROM otlet.semantic_row_exact_counts(
      revision_definition,
      revision_hash
    )
  ) THEN
    RAISE EXCEPTION 'portable semantic subject move maintenance is invalid';
  END IF;
END;
$proof$;
ROLLBACK;

BEGIN;
DO $proof$
DECLARE
  trigger_name name;
BEGIN
  FOR trigger_name IN
    SELECT trigger_row.tgname
    FROM pg_catalog.pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
        'public.portable_time_legacy_source'::regclass
      AND trigger_row.tgfoid =
        'otlet.watch_change_trigger()'::regprocedure::oid
      AND NOT trigger_row.tgisinternal
  LOOP
    EXECUTE format(
      'ALTER TABLE public.portable_time_legacy_source DISABLE TRIGGER %I',
      trigger_name
    );
  END LOOP;
END;
$proof$;
DELETE FROM public.portable_time_legacy_source
WHERE id = 'legacy-row';
INSERT INTO public.portable_time_legacy_source
VALUES ('legacy-row', 'legacy');
DO $proof$
DECLARE
  revision_hash text;
  revision_definition jsonb;
  maintained_contract text;
  exact_contract text;
BEGIN
  SELECT sentinel.legacy_watch_revision_hash, revision.definition
  INTO STRICT revision_hash, revision_definition
  FROM public.portable_upgrade_sentinel sentinel
  JOIN otlet.workload_revisions revision
    ON revision.task_name = 'portable_time_legacy_task'
   AND revision.workload_revision_hash = sentinel.legacy_watch_revision_hash
  WHERE sentinel.id = 1;
  SELECT concat_ws('|', count_basis, total_subjects, fresh_subjects,
                   stale_subjects, missing_subjects)
  INTO STRICT maintained_contract
  FROM otlet.semantic_planner_statistics_status
  WHERE task_name = 'portable_time_legacy_task';
  SELECT concat_ws('|', total_subjects, fresh_subjects,
                   stale_subjects, missing_subjects)
  INTO STRICT exact_contract
  FROM otlet.semantic_row_exact_counts(
    revision_definition,
    revision_hash
  );
  IF maintained_contract <> 'maintained|1|0|1|0'
     OR exact_contract <> '1|1|0|0' THEN
    RAISE EXCEPTION 'portable semantic subject reinsert maintenance is invalid: % / %',
      maintained_contract, exact_contract;
  END IF;
END;
$proof$;
ROLLBACK;

BEGIN;
TRUNCATE public.portable_time_legacy_source;
DO $proof$
BEGIN
  IF NOT (
    SELECT total_subjects = 0
      AND fresh_subjects = 0
      AND stale_subjects = 0
      AND missing_subjects = 0
      AND count_basis = 'maintained'
    FROM otlet.semantic_planner_statistics_status
    WHERE task_name = 'portable_time_legacy_task'
  ) THEN
    RAISE EXCEPTION 'portable semantic truncate maintenance is invalid';
  END IF;
END;
$proof$;
ROLLBACK;

BEGIN;
UPDATE otlet.semantic_planner_statistics statistics
SET total_subjects = 3,
    fresh_subjects = 2,
    stale_subjects = 1,
    missing_subjects = 0,
    stale_reasons = '{"time_expired":1}'::jsonb,
    count_basis = 'maintained',
    valid_until = statement_timestamp() - interval '1 second',
    invalidated_at = NULL,
    invalidation_reason = NULL
FROM public.portable_upgrade_sentinel sentinel
WHERE sentinel.id = 1
  AND statistics.task_name = 'portable_time_legacy_task'
  AND statistics.workload_revision_hash = sentinel.legacy_watch_revision_hash;
DO $proof$
DECLARE
  revision_hash text;
BEGIN
  SELECT legacy_watch_revision_hash
  INTO STRICT revision_hash
  FROM public.portable_upgrade_sentinel
  WHERE id = 1;
  IF NOT (
    SELECT total_subjects = 3
      AND fresh_subjects = 0
      AND stale_subjects = 3
      AND missing_subjects = 0
      AND stale_reasons ->> 'time_expired' = '3'
      AND count_basis = 'maintained_expired'
    FROM otlet.semantic_planner_counts(
      'portable_time_legacy_task', revision_hash, 3
    )
  ) THEN
    RAISE EXCEPTION 'portable semantic expiry aggregation is invalid';
  END IF;
END;
$proof$;
ROLLBACK;

BEGIN;
DO $proof$
DECLARE
  duplicate_definition jsonb := jsonb_build_object(
    'source', jsonb_build_object(
      'kind', 'pair',
      'pair_sources', jsonb_build_array(
        jsonb_build_object('table', 'public.portable_time_legacy_source'),
        jsonb_build_object('table', 'public.portable_time_legacy_source')
      )
    )
  );
  trigger_prefix text := 'otlet_stats_' ||
    substr(md5('portable_duplicate_source_probe'), 1, 16);
BEGIN
  PERFORM otlet.install_semantic_planner_source_triggers(
    'portable_duplicate_source_probe', duplicate_definition
  );
  IF (
    SELECT count(*)
    FROM pg_catalog.pg_trigger trigger
    WHERE trigger.tgrelid = 'public.portable_time_legacy_source'::regclass
      AND trigger.tgname LIKE trigger_prefix || '%'
      AND NOT trigger.tgisinternal
  ) <> 4 THEN
    RAISE EXCEPTION 'portable duplicate source trigger installation is invalid';
  END IF;
END;
$proof$;
ROLLBACK;

UPDATE public.portable_upgrade_sentinel sentinel
SET planner_statistics_version = statistics.statistics_version,
    planner_statistics_refreshed_at = statistics.refreshed_at
FROM otlet.semantic_planner_statistics statistics
WHERE sentinel.id = 1
  AND statistics.task_name = 'portable_time_legacy_task'
  AND statistics.workload_revision_hash = sentinel.legacy_watch_revision_hash;
SQL

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 -v preflight_role="$preflight_role" <<'SQL' >/dev/null
GRANT EXECUTE ON FUNCTION otlet.workload_enablement_preflight(
  text, text, text, integer, integer, integer, integer
) TO :"preflight_role";
UPDATE public.portable_upgrade_sentinel sentinel
SET preflight_function_oid = function.oid,
    preflight_function_acl = function.proacl::text
FROM pg_catalog.pg_proc function
WHERE sentinel.id = 1
  AND function.oid =
    'otlet.workload_enablement_preflight(text,text,text,integer,integer,integer,integer)'::regprocedure;

CREATE TABLE public.portable_preflight_source (
  id text PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO public.portable_preflight_source
VALUES ('one', '1'), ('two', '2'), ('three', '3');
ANALYZE public.portable_preflight_source;
SELECT otlet.create_task(
  task_name => 'portable_preflight_probe',
  input_query => $$
    SELECT id AS subject_id, jsonb_build_object('value', value) AS input
    FROM public.portable_preflight_source
  $$,
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'model_concurrency_probe',
  runtime_options => '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb,
  input_shaping => '{"source_fields":["value"]}'::jsonb,
  source_relations => '[{"table":"public.portable_preflight_source","subject_column":"id"}]'::jsonb
) \g /dev/null
SELECT otlet.promote_configured_workload_revision('portable_preflight_probe') \g /dev/null

BEGIN READ ONLY;
DO $proof$
BEGIN
  IF NOT (
    SELECT candidate_plan_status = 'ready'
      AND estimated_candidates = 3
      AND estimated_jobs = 3
    FROM otlet.workload_enablement_preflight(
      'portable_preflight_probe',
      (
        SELECT active_workload_revision_hash
        FROM otlet.workload_revision_heads
        WHERE task_name = 'portable_preflight_probe'
      ),
      'backfill',
      3,
      3,
      64,
      3
    )
  ) THEN
    RAISE EXCEPTION 'portable workload preflight is not read-only';
  END IF;
END
$proof$;
ROLLBACK;
SQL

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
UPDATE otlet.production_policy
SET customscan_preload_max_rows = 99999,
    customscan_preload_max_bytes = 67108863,
    customscan_preload_max_ms = 29999
WHERE name = 'default';
SQL

install_portable

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
SELECT otlet.register_model(
  'portable_context_limit_probe',
  '/tmp/portable_context_limit_probe.gguf',
  repeat('8', 64),
  jsonb_build_object(
    'sha256', repeat('8', 64),
    'bytes', 1,
    'source', 'portable-upgrade-demo',
    'revision', 'context-limit-v1',
    'quantization', 'test',
    'license', 'test',
    'context_window_tokens', 1024
  ),
  1
) \g /dev/null
SELECT otlet.create_task(
  task_name => 'portable_context_selection_probe',
  input_query => NULL,
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'model_concurrency_probe',
  runtime_options => '{"context_window_tokens":2048}'::jsonb,
  input_shaping => '{"source_fields":["value"]}'::jsonb
) \g /dev/null
SQL

contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v operator_role="$operator_role" \
    -v partial_auditor_role="$partial_auditor_role" \
    -v preflight_role="$preflight_role" <<'SQL'
CREATE FUNCTION pg_temp.reject_invalid_service_targets() RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
  interactive_rejected boolean := false;
  asynchronous_rejected boolean := false;
  cancellation_rejected boolean := false;
  preload_rows_rejected boolean := false;
  preload_rows_upper_rejected boolean := false;
  preload_bytes_rejected boolean := false;
  preload_bytes_upper_rejected boolean := false;
  preload_ms_rejected boolean := false;
  preload_ms_upper_rejected boolean := false;
BEGIN
  BEGIN
    UPDATE otlet.production_policy
    SET interactive_queue_age_p99_target_ms = 0
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    interactive_rejected := true;
  END;
  BEGIN
    UPDATE otlet.production_policy
    SET asynchronous_queue_age_p99_target_ms = 0
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    asynchronous_rejected := true;
  END;
  BEGIN
    UPDATE otlet.production_policy
    SET cancellation_observation_p99_target_ms = 0
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    cancellation_rejected := true;
  END;
  BEGIN
    UPDATE otlet.production_policy
    SET customscan_preload_max_rows = 0
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    preload_rows_rejected := true;
  END;
  BEGIN
    UPDATE otlet.production_policy
    SET customscan_preload_max_rows = 1000001
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    preload_rows_upper_rejected := true;
  END;
  BEGIN
    UPDATE otlet.production_policy
    SET customscan_preload_max_bytes = 1023
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    preload_bytes_rejected := true;
  END;
  BEGIN
    UPDATE otlet.production_policy
    SET customscan_preload_max_bytes = 1073741825
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    preload_bytes_upper_rejected := true;
  END;
  BEGIN
    UPDATE otlet.production_policy
    SET customscan_preload_max_ms = 0
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    preload_ms_rejected := true;
  END;
  BEGIN
    UPDATE otlet.production_policy
    SET customscan_preload_max_ms = 300001
    WHERE name = 'default';
  EXCEPTION WHEN check_violation THEN
    preload_ms_upper_rejected := true;
  END;
  RETURN interactive_rejected
    AND asynchronous_rejected
    AND cancellation_rejected
    AND preload_rows_rejected
    AND preload_rows_upper_rejected
    AND preload_bytes_rejected
    AND preload_bytes_upper_rejected
    AND preload_ms_rejected
    AND preload_ms_upper_rejected;
END
$function$;

CREATE FUNCTION pg_temp.expect_error(statement text, fragment text) RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    EXECUTE expect_error.statement;
  EXCEPTION WHEN OTHERS THEN
    RETURN position(expect_error.fragment IN SQLERRM) > 0;
  END;
  RETURN false;
END
$function$;

SELECT concat_ws('|',
  max(version),
  count(*),
  array_agg(version ORDER BY version) = ARRAY(SELECT generate_series(1, 80)),
  bool_and(file ~ ('(^|/)' || lpad(version::text, 4, '0') || '_')),
  (SELECT value FROM public.portable_upgrade_sentinel),
  (
    SELECT NOT model.artifact_identity ? 'context_window_tokens'
      AND model.tested_context_window_tokens = 4096
    FROM otlet.models model
    WHERE model.name = 'model_concurrency_probe'
  ),
  (
    SELECT COALESCE(
      otlet.workload_model_definition(model.name) ->>
        'tested_context_window_tokens',
      'NULL'
    )
    FROM otlet.models model
    WHERE model.name = 'model_concurrency_probe'
  ),
  (
    SELECT otlet.workload_pack_shape_error(definition.definition) IS NULL
      AND NOT (
        definition.definition #> '{watch,model_artifact_identity}'
          ? 'context_window_tokens'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_each(definition.definition -> 'models') role
        WHERE role.value -> 'artifact_identity' ? 'context_window_tokens'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.workload_pack_capability_report(definition.definition) report
        WHERE report.component = 'model'
          AND NOT report.compatible
      )
    FROM public.portable_upgrade_sentinel sentinel
    JOIN otlet.workload_pack_definitions definition
      ON definition.pack_hash = sentinel.legacy_workload_pack_hash
    WHERE sentinel.id = 1
  ),
  pg_temp.expect_error(
    $statement$
      SELECT otlet.create_task(
        task_name => 'portable_context_direct_rejected',
        input_query => NULL,
        instruction => 'Return an empty object',
        output_schema => '{"type":"object"}'::jsonb,
        model_name => 'portable_context_limit_probe',
        runtime_options => '{"context_window_tokens":2048}'::jsonb,
        input_shaping => '{"source_fields":["value"]}'::jsonb
      )
    $statement$,
    'requested_context_window_exceeds_model_limit'
  ) AND pg_temp.expect_error(
    $statement$
      SELECT otlet.set_model_selection_policy(
        'portable_context_selection_probe',
        'portable_context_limit_probe',
        'model_concurrency_probe'
      )
    $statement$,
    'requested_context_window_exceeds_model_limit'
  ) AND pg_temp.expect_error(
    $statement$
      SELECT otlet.set_model_selection_policy(
        'portable_context_selection_probe',
        'model_concurrency_probe',
        'portable_context_limit_probe'
      )
    $statement$,
    'requested_context_window_exceeds_model_limit'
  ),
  (
    SELECT position('''context_window''' IN function.prosrc) > 0
      AND position('''tested_context_window_tokens''' IN function.prosrc) > 0
      AND position('''requested_context_window_tokens''' IN function.prosrc) > 0
      AND position('''effective_context_window_tokens''' IN function.prosrc) > 0
      AND position('runtime_options_status' IN function.prosrc) > 0
    FROM pg_catalog.pg_proc function
    WHERE function.oid =
      'otlet.portable_claim_jobs(text,integer,text,text,bigint,integer,integer)'::regprocedure
  ),
  (
    SELECT sentinel.legacy_watch_revision_hash = head.active_workload_revision_hash
      AND head.active_workload_revision_hash IS DISTINCT FROM otlet.identity_hash(
        'workload_revision',
        otlet.current_workload_revision_definition('portable_time_legacy_task')
      )
      AND otlet.semantic_matches(
        'portable_time_legacy',
        'legacy-row',
        '{"decision":"keep"}'::jsonb
      )
      AND EXISTS (
        SELECT 1
        FROM otlet.semantic_materializations_effective materialization
        WHERE materialization.id = sentinel.legacy_materialization_id
          AND materialization.subject_id = 'legacy-row'
          AND NOT materialization.stale
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.watch_time_freshness freshness
        WHERE freshness.watch_name = 'portable_time_legacy'
      )
    FROM public.portable_upgrade_sentinel sentinel
    JOIN otlet.workload_revision_heads head
      ON head.task_name = 'portable_time_legacy_task'
  ),
  (SELECT count(*) FROM otlet.verify_invariants()),
  pg_catalog.has_function_privilege(
    :'operator_role',
    'otlet.semantic_time_freshness_state('
      'timestamptz,bigint,bigint,timestamptz)',
    'EXECUTE'
  ),
  NOT pg_catalog.has_function_privilege(
    :'partial_auditor_role',
    'otlet.semantic_time_freshness_state('
      'timestamptz,bigint,bigint,timestamptz)',
    'EXECUTE'
  ),
  NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.semantic_time_freshness_state('
      'timestamptz,bigint,bigint,timestamptz)',
    'EXECUTE'
  ),
  (
    SELECT job_origin = 'task_run'
    FROM otlet.jobs
    WHERE task_name = 'decision_evidence_legacy'
  ),
  pg_catalog.has_table_privilege(
    :'operator_role', 'otlet.task_queue_status', 'SELECT'
  ),
  pg_catalog.has_table_privilege(
    :'operator_role', 'otlet.task_resource_status', 'SELECT'
  ),
  NOT pg_catalog.has_table_privilege(
    :'partial_auditor_role', 'otlet.task_queue_status', 'SELECT'
  ),
  (
    SELECT max_queued_input_bytes_per_task = 4096
      AND max_queued_input_bytes_per_model = 4096
      AND max_queued_input_bytes_total = 4096
    FROM otlet.production_policy_status
  ),
  (
    SELECT interactive_queue_age_p99_target_ms = 30000
      AND asynchronous_queue_age_p99_target_ms = 30000
      AND cancellation_observation_p99_target_ms = 1000
      AND customscan_preload_max_rows = 99999
      AND customscan_preload_max_bytes = 67108863
      AND customscan_preload_max_ms = 29999
      AND NOT pg_catalog.has_table_privilege(
        'public', 'otlet.production_policy_status', 'SELECT'
      )
    FROM otlet.production_policy_status
  ),
  pg_temp.reject_invalid_service_targets(),
  (
    SELECT relation.oid = sentinel.production_policy_status_oid
      AND relation.relacl::text = sentinel.production_policy_status_acl
      AND pg_catalog.has_table_privilege(
        :'operator_role', 'otlet.production_policy_status', 'SELECT'
      )
    FROM public.portable_upgrade_sentinel sentinel
    CROSS JOIN pg_catalog.pg_class relation
    WHERE relation.oid = 'otlet.production_policy_status'::regclass
  ),
  (
    SELECT report.candidate_plan_status = 'ready'
      AND report.candidate_plan_error IS NULL
      AND report.candidate_plan_rows = 3
      AND report.candidate_plan_rows = jsonb_extract_path_text(
        report.candidate_plan, '0', 'Plan', 'Plan Rows'
      )::bigint
      AND report.estimated_candidates = 3
      AND report.estimated_jobs = 3
      AND report.estimated_total_input_bytes =
        report.estimated_jobs * report.estimated_input_bytes_per_job
      AND report.estimated_peak_queue_input_bytes =
        report.estimated_total_input_bytes
      AND report.runtime_observations = 0
      AND report.runtime_sample_scope = 'attempt_deadline_fallback'
      AND report.model_ms_p25 = report.model_ms_p50
      AND report.model_ms_p50 = report.model_ms_p75
      AND report.service_ms_p25 = report.service_ms_p50
      AND report.service_ms_p50 = report.service_ms_p75
      AND report.estimated_catch_up_ms_p25 =
        report.estimated_catch_up_ms_p50
      AND report.estimated_catch_up_ms_p50 =
        report.estimated_catch_up_ms_p75
      AND report.capacity ->> 'estimated_peak_queue_jobs' = '3'
      AND report.capacity ->> 'effective_available_model_queue_slots' = '999'
      AND report.capacity ->> 'effective_available_task_queue_input_bytes' = '3072'
      AND report.capacity ->> 'effective_available_model_queue_input_bytes' = '3072'
      AND report.capacity ->> 'effective_available_total_queue_input_bytes' = '3072'
      AND report.uncertainty_level = 'high'
      AND report.uncertainty_reasons @> ARRAY[
        'planner_cardinality_estimate',
        'source_query_rebinding_not_executed',
        'input_bytes_from_plan_width',
        'runtime_history_missing'
      ]
      AND report.within_current_policy
      AND NOT EXISTS (
        SELECT 1 FROM otlet.jobs WHERE task_name = 'portable_preflight_probe'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.task_backfills
        WHERE task_name = 'portable_preflight_probe'
      )
      AND pg_temp.expect_error(
        format(
          'SELECT * FROM otlet.workload_enablement_preflight(%L, %L, %L)',
          'portable_preflight_probe',
          report.workload_revision_hash,
          'bulk'
        ),
        'kind must be'
      )
      AND pg_temp.expect_error(
        format(
          'SELECT * FROM otlet.workload_enablement_preflight(%L, %L, %L, NULL)',
          'portable_preflight_probe',
          report.workload_revision_hash,
          'backfill'
        ),
        'max subjects'
      )
      AND pg_temp.expect_error(
        format(
          'SELECT * FROM otlet.workload_enablement_preflight(%L, %L, %L)',
          'portable_preflight_probe',
          repeat('0', 64),
          'watch'
        ),
        'is not active'
      )
      AND function.oid = sentinel.preflight_function_oid
      AND function.proacl::text = sentinel.preflight_function_acl
      AND NOT function.prosecdef
      AND function.provolatile = 'v'
      AND function.proconfig @> ARRAY[
        'search_path=pg_catalog, otlet, pg_temp'
      ]
      AND pg_catalog.has_function_privilege(
        :'preflight_role', function.oid, 'EXECUTE'
      )
      AND NOT pg_catalog.has_function_privilege(
        'public', function.oid, 'EXECUTE'
      )
    FROM otlet.workload_enablement_preflight(
      'portable_preflight_probe',
      (
        SELECT active_workload_revision_hash
        FROM otlet.workload_revision_heads
        WHERE task_name = 'portable_preflight_probe'
      ),
      'backfill',
      3,
      3,
      64,
      3
    ) report
    CROSS JOIN public.portable_upgrade_sentinel sentinel
    CROSS JOIN pg_catalog.pg_proc function
    WHERE sentinel.id = 1
      AND function.oid =
        'otlet.workload_enablement_preflight(text,text,text,integer,integer,integer,integer)'::regprocedure
  ),
  (
    SELECT function.oid = sentinel.semantic_index_plan_oid
      AND function.proacl::text IS NOT DISTINCT FROM
        sentinel.semantic_index_plan_acl
      AND statistics.statistics_version =
        sentinel.planner_statistics_version
      AND statistics.refreshed_at =
        sentinel.planner_statistics_refreshed_at
      AND statistics.total_subjects = 1
      AND statistics.fresh_subjects = 1
      AND statistics.stale_subjects = 0
      AND statistics.missing_subjects = 0
      AND statistics.count_basis = 'maintained'
      AND NOT pg_catalog.has_table_privilege(
        'public', 'otlet.semantic_planner_statistics', 'SELECT'
      )
      AND NOT pg_catalog.has_table_privilege(
        'public', 'otlet.semantic_planner_statistics_status', 'SELECT'
      )
      AND NOT pg_catalog.has_function_privilege(
        'public',
        'otlet.semantic_predicate_counts(text,jsonb,text)',
        'EXECUTE'
      )
      AND NOT pg_catalog.has_function_privilege(
        'public',
        'otlet.recompute_reviewed_semantic_planner_statistics()',
        'EXECUTE'
      )
      AND position(
        'workload_revision_heads' IN pg_catalog.pg_get_viewdef(
          'otlet.semantic_planner_statistics_status'::regclass,
          true
        )
      ) > 0
      AND (
        SELECT position('relevant_contract_hash' IN changed.prosrc) > 0
          AND position('pair_constraint_contract_hash' IN changed.prosrc) > 0
          AND position('supersedes_correction_hash' IN changed.prosrc) > 0
        FROM pg_catalog.pg_proc changed
        WHERE changed.oid =
          'otlet.recompute_corrected_semantic_planner_statistics()'::regprocedure
      )
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.pg_trigger trigger
        WHERE trigger.tgname = 'pair_constraint_facts_planner_statistics'
          AND trigger.tgrelid = 'otlet.pair_constraint_facts'::regclass
          AND trigger.tgfoid =
            'otlet.recompute_constrained_semantic_planner_statistics()'::regprocedure::oid
          AND NOT trigger.tgisinternal
      )
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.pg_trigger trigger
        WHERE trigger.tgname = 'review_events_zz_semantic_planner_statistics'
          AND trigger.tgrelid = 'otlet.review_events'::regclass
          AND trigger.tgfoid =
            'otlet.recompute_reviewed_semantic_planner_statistics()'::regprocedure::oid
          AND NOT trigger.tgisinternal
      )
      AND (
        SELECT position('pg_trigger_depth() > 1' IN changed.prosrc) > 0
        FROM pg_catalog.pg_proc changed
        WHERE changed.oid =
          'otlet.recompute_changed_semantic_planner_statistics()'::regprocedure
      )
      AND (
        SELECT position('pg_trigger_depth() > 1' IN constrained.prosrc) > 0
        FROM pg_catalog.pg_proc constrained
        WHERE constrained.oid =
          'otlet.recompute_constrained_semantic_planner_statistics()'::regprocedure
      )
      AND (
        SELECT position('relevant_contract_hash' IN recompute.prosrc) > 0
          AND position('pair_constraint_contract_hash' IN recompute.prosrc) > 0
        FROM pg_catalog.pg_proc recompute
        WHERE recompute.oid =
          'otlet.recompute_semantic_planner_statistics(text,text,bigint,text)'::regprocedure
      )
    FROM public.portable_upgrade_sentinel sentinel
    JOIN otlet.semantic_planner_statistics statistics
      ON statistics.task_name = 'portable_time_legacy_task'
     AND statistics.workload_revision_hash =
       sentinel.legacy_watch_revision_hash
    CROSS JOIN pg_catalog.pg_proc function
    WHERE sentinel.id = 1
      AND function.oid =
        'otlet.semantic_index_plan(text,boolean,text)'::regprocedure
  )
)
FROM otlet.portable_schema_migrations;
SQL
)"
[ "$contract" = "80|80|t|t|preserved|t|4096|t|t|t|t|0|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable repeat-install contract mismatch: $contract" >&2
  exit 1
}
docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL'
UPDATE otlet.production_policy
SET max_input_bytes_per_job = 1048576,
    max_queued_input_bytes_per_task = 67108864,
    max_queued_input_bytes_per_model = 67108864,
    max_queued_input_bytes_total = 268435456
WHERE name = 'default';
SQL

portable_time_freshness_contract="$(
  (
    cheap_model_name="model_concurrency_probe"
    time_based_freshness_expect_customscan=false
    log() { :; }
    psql_exec() {
      docker exec -i "$container" psql -U postgres -d "$database" \
        -X -v ON_ERROR_STOP=1 "$@"
    }
    source "$(dirname "$0")/demo/time_based_freshness.sh"
  ) | awk 'NF { line = $0 } END { print line }'
)"
[ "$portable_time_freshness_contract" = \
  "time_based_freshness_contract=t|t|t|t|t|t|t|t" ] || {
  echo "Portable time-freshness contract mismatch: $portable_time_freshness_contract" >&2
  exit 1
}

portable_bounded_backfill_contract="$(
  (
    cheap_model_name="bounded_backfill_probe"
    log() { :; }
    psql_exec() {
      docker exec -i "$container" psql -U postgres -d "$database" \
        -X -v ON_ERROR_STOP=1 "$@"
    }
    psql_exec -q >/dev/null <<'SQL'
SELECT otlet.register_model(
  'bounded_backfill_probe',
  '/tmp/bounded_backfill_probe.gguf',
  repeat('b', 64),
  jsonb_build_object(
    'sha256', repeat('b', 64),
    'bytes', 1,
    'source', 'portable-upgrade-demo',
    'revision', 'bounded-backfill-v1',
    'quantization', 'test',
    'license', 'test'
  ),
  8
);
SQL
    source "$(dirname "$0")/demo/minimal_bounded_backfill.sh"
  ) | awk 'NF { line = $0 } END { print line }'
)"
[ "$portable_bounded_backfill_contract" = \
  "minimal_bounded_backfill_contract=t|t|t|t|t|t|t|t|t|t|0" ] || {
  echo "Portable bounded-backfill contract mismatch: $portable_bounded_backfill_contract" >&2
  exit 1
}

portable_workload_pack_promotion_contract="$(
  (
    log() { :; }
    psql_exec() {
      docker exec -i "$container" psql -U postgres -d "$database" \
        -X -v ON_ERROR_STOP=1 "$@"
    }
    source "$(dirname "$0")/demo/workload_pack_promotion.sh"
  ) | awk 'NF { line = $0 } END { print line }'
)"
[ "$portable_workload_pack_promotion_contract" = \
  "workload_pack_promotion_contract=39|true" ] || {
  echo "Portable workload-pack contract mismatch: $portable_workload_pack_promotion_contract" >&2
  exit 1
}

portable_job_origin_workload_budget_contract="$(
  (
    log() { :; }
    psql_exec() {
      docker exec -i "$container" psql -U postgres -d "$database" \
        -X -v ON_ERROR_STOP=1 "$@"
    }
    source "$(dirname "$0")/demo/job_origin_workload_budgets.sh"
  ) | awk 'NF { line = $0 } END { print line }'
)"
[ "$portable_job_origin_workload_budget_contract" = \
  "job_origin_workload_budget_contract=4|2|1|t|t|t|t" ] || {
  echo "Portable job-origin contract mismatch: $portable_job_origin_workload_budget_contract" >&2
  exit 1
}

application_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v operator_role="$operator_role" \
    -v application_role="$application_role" \
    -v partial_auditor_role="$partial_auditor_role" <<'SQL'
SELECT concat_ws('|',
  (
    SELECT count(*) = 7
    FROM information_schema.columns
    WHERE table_schema = 'otlet'
      AND table_name = 'jobs'
      AND column_name IN (
        'application_owner_role_oid',
        'application_authenticated_role_oid',
        'application_invocation_role_oid',
        'application_request_key',
        'application_request_payload_hash',
        'retry_of_job_id',
        'retry_mode'
      )
  ),
  to_regprocedure('otlet.application_submit_task_subject(text,text,text)') IS NOT NULL,
  to_regprocedure('otlet.application_job_status(bigint)') IS NOT NULL,
  to_regprocedure('otlet.application_cancel_job(bigint)') IS NOT NULL,
  to_regprocedure('otlet.application_retry_job(bigint,text)') IS NOT NULL,
  to_regprocedure('otlet.grant_application_access(regrole)') IS NOT NULL,
  to_regclass('otlet.application_access_policy_status') IS NOT NULL,
  (SELECT application_functions = 3
          AND application_security_definer_functions = 3
          AND application_fixed_search_path_functions = 3
   FROM otlet.application_access_policy_status),
  (SELECT function.prosecdef
          AND function.proconfig @> ARRAY['search_path=pg_catalog, otlet, pg_temp']
   FROM pg_catalog.pg_proc function
   WHERE function.oid = 'otlet.application_retry_job(bigint,text)'::regprocedure),
  pg_catalog.has_schema_privilege(:'operator_role', 'otlet', 'USAGE')
  AND pg_catalog.has_function_privilege(
    :'operator_role',
    'otlet.application_retry_job(bigint,text)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_function_privilege(
    :'operator_role',
    'otlet.application_submit_task_subject(text,text,text)',
    'EXECUTE'
  )
  AND pg_catalog.has_table_privilege(
    :'operator_role', 'otlet.failure_taxonomy', 'SELECT'
  )
  AND pg_catalog.has_table_privilege(
    :'operator_role', 'otlet.failure_retry_status', 'SELECT'
  )
  AND (SELECT bool_and(pg_catalog.has_table_privilege(
         :'operator_role', prior_surface.name, 'SELECT'
       ))
       FROM pg_catalog.unnest(ARRAY[
         'otlet.redaction_policy_status',
         'otlet.audit_receipt_export',
         'otlet.audit_review_export',
         'otlet.audit_review_event_export',
         'otlet.audit_action_execution_export',
         'otlet.audit_eval_label_export',
         'otlet.audit_administrative_change_export',
         'otlet.action_workflow_policy_status',
         'otlet.semantic_dependency_audit',
         'otlet.operational_event_log',
         'otlet.worker_batch_timing_status',
         'otlet.portable_protocol_status',
         'otlet.runtime_capability_status',
         'otlet.portable_worker_status',
         'otlet.portable_claim_status',
         'otlet.portable_receipt_status'
       ]::text[]) prior_surface(name))
  AND NOT pg_catalog.has_table_privilege(:'operator_role', 'otlet.jobs', 'SELECT'),
  pg_catalog.has_schema_privilege(:'application_role', 'otlet', 'USAGE')
  AND pg_catalog.has_function_privilege(
    :'application_role',
    'otlet.application_submit_task_subject(text,text,text)',
    'EXECUTE'
  )
  AND pg_catalog.has_function_privilege(
    :'application_role',
    'otlet.application_job_status(bigint)',
    'EXECUTE'
  )
  AND pg_catalog.has_function_privilege(
    :'application_role',
    'otlet.application_cancel_job(bigint)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_table_privilege(:'application_role', 'otlet.jobs', 'SELECT'),
  NOT pg_catalog.has_table_privilege(
    :'partial_auditor_role', 'otlet.failure_taxonomy', 'SELECT'
  )
  AND NOT pg_catalog.has_table_privilege(
    :'partial_auditor_role', 'otlet.failure_retry_status', 'SELECT'
  )
  AND pg_catalog.has_schema_privilege(:'partial_auditor_role', 'otlet', 'USAGE')
  AND pg_catalog.has_table_privilege(
    :'partial_auditor_role', 'otlet.audit_review_export', 'SELECT'
  )
  AND (SELECT count(*) = 1
       FROM pg_catalog.pg_class relation
       JOIN pg_catalog.pg_namespace namespace
         ON namespace.oid = relation.relnamespace
       CROSS JOIN LATERAL pg_catalog.aclexplode(relation.relacl) privilege
       WHERE namespace.nspname = 'otlet'
         AND relation.relkind IN ('r', 'p', 'v', 'm', 'f')
         AND privilege.grantee = :'partial_auditor_role'::regrole::oid
         AND privilege.privilege_type = 'SELECT'),
  (SELECT count(*) = 3
   FROM pg_catalog.pg_constraint constraint_row
   WHERE constraint_row.conrelid = 'otlet.jobs'::regclass
     AND constraint_row.conname IN (
       'jobs_application_provenance_check',
       'jobs_retry_mode_check',
       'jobs_retry_parent_check'
     )),
  (SELECT count(*) = 2
   FROM pg_catalog.pg_indexes index_row
   WHERE index_row.schemaname = 'otlet'
     AND index_row.indexname IN (
       'jobs_application_request_key_idx',
       'jobs_retry_of_job_id_idx'
     )),
  (SELECT count(*) = 0
   FROM pg_catalog.pg_proc function
   JOIN pg_catalog.pg_namespace namespace ON namespace.oid = function.pronamespace
   WHERE namespace.nspname = 'otlet'
     AND function.proname IN (
       'application_submit_task_subject',
       'application_job_status',
       'application_cancel_job',
       'application_retry_job',
       'grant_application_access'
     )
     AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')),
  NOT pg_catalog.has_table_privilege(
    'public',
    'otlet.application_access_policy_status',
    'SELECT'
  )
);
SQL
)"
[ "$application_migration_contract" = "t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable application migration contract mismatch: $application_migration_contract" >&2
  exit 1
}

lifecycle_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*) = 5
   FROM information_schema.columns
   WHERE table_schema = 'otlet'
     AND table_name = 'tasks'
     AND column_name IN (
       'lifecycle_state',
       'lifecycle_revision_hash',
       'lifecycle_previous_revision_hash',
       'lifecycle_promoted_at',
       'lifecycle_changed_at'
     )),
  (SELECT is_nullable = 'NO' AND column_default = '''active''::text'
   FROM information_schema.columns
   WHERE table_schema = 'otlet'
     AND table_name = 'tasks'
     AND column_name = 'lifecycle_state'),
  (SELECT count(*) = 7
   FROM pg_catalog.pg_constraint constraint_row
   WHERE constraint_row.conrelid = 'otlet.tasks'::regclass
     AND constraint_row.conname IN (
       'tasks_lifecycle_state_check',
       'tasks_lifecycle_revision_hash_check',
       'tasks_lifecycle_previous_revision_hash_check',
       'tasks_lifecycle_pin_check',
       'tasks_lifecycle_previous_distinct_check',
       'tasks_lifecycle_revision_fk',
       'tasks_lifecycle_previous_revision_fk'
     )),
  to_regprocedure('otlet.set_task_lifecycle(text,text,text)') IS NOT NULL,
  to_regprocedure('otlet.drop_watch(text,text)') IS NOT NULL,
  to_regprocedure('otlet.drop_watch(text)') IS NOT NULL,
  to_regclass('otlet.task_lifecycle_status') IS NOT NULL,
  NOT EXISTS (SELECT 1 FROM otlet.tasks WHERE lifecycle_state <> 'active'),
  (SELECT count(*) = 0
   FROM pg_catalog.pg_proc function
   WHERE function.oid IN (
     'otlet.set_task_lifecycle(text,text,text)'::regprocedure,
     'otlet.drop_watch(text)'::regprocedure,
     'otlet.drop_watch(text,text)'::regprocedure
   )
     AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')),
  NOT pg_catalog.has_table_privilege('public', 'otlet.task_lifecycle_status', 'SELECT'),
  NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.drop_watch_registry(text)',
    'EXECUTE'
  ),
  to_regprocedure('otlet.watch_source_relation_drift(text,text)') IS NOT NULL
    AND to_regprocedure('otlet.lock_task_source_relations(text)') IS NOT NULL
    AND to_regprocedure('otlet.repair_source_query_contract(text,text)') IS NOT NULL
    AND to_regprocedure('otlet.guard_task_definition_write()') IS NOT NULL
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.watch_source_relation_drift(text,text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.lock_task_source_relations(text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.repair_source_query_contract(text,text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.guard_task_definition_write()',
      'EXECUTE'
    ),
  to_regprocedure('otlet.current_workload_revision_status(text)') IS NOT NULL
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.current_workload_revision_status(text)',
      'EXECUTE'
    ),
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 50
      AND file ~ '0050_task_watch_operational_lifecycle.sql$'
  )
);
SQL
)"
[ "$lifecycle_migration_contract" = "t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable lifecycle migration contract mismatch: $lifecycle_migration_contract" >&2
  exit 1
}

administrative_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 -v operator_role="$operator_role" <<'SQL' | tail -n 1
BEGIN;
SELECT otlet.set_administrative_change_context(
  'portable administrative ledger proof'
) \g /dev/null
SELECT otlet.grant_application_access(:'operator_role'::regrole) \g /dev/null
SELECT otlet.grant_portable_worker_access(:'operator_role'::regrole) \g /dev/null
SELECT concat_ws('|',
  (SELECT count(*) = 13
   FROM information_schema.columns
   WHERE table_schema = 'otlet'
     AND table_name = 'administrative_change_events'),
  (SELECT count(*) = 9
   FROM pg_catalog.pg_trigger trigger
   WHERE trigger.tgrelid IN (
     'otlet.administrative_change_events'::regclass,
     'otlet.models'::regclass,
     'otlet.tasks'::regclass,
     'otlet.watches'::regclass,
     'otlet.model_selection_policies'::regclass,
     'otlet.action_targets'::regclass,
     'otlet.action_workflow_policies'::regclass,
     'otlet.production_policy'::regclass
   )
     AND trigger.tgname IN (
       'administrative_change_events_row_guard',
       'administrative_change_events_truncate_guard',
       'models_administrative_change',
       'tasks_administrative_change',
       'watches_administrative_change',
       'model_selection_policies_administrative_change',
       'action_targets_administrative_change',
       'action_workflow_policies_administrative_change',
       'production_policy_retention_administrative_change'
     )),
  to_regprocedure('otlet.set_administrative_change_context(text,text)') IS NOT NULL
    AND to_regprocedure('otlet.append_administrative_change(text,text,text,text,text)') IS NOT NULL
    AND to_regprocedure('otlet.record_administrative_row_change()') IS NOT NULL
    AND to_regprocedure('otlet.access_policy_revision(regrole)') IS NOT NULL
    AND to_regclass('otlet.audit_administrative_change_export') IS NOT NULL,
  (SELECT count(*) = 2
          AND count(DISTINCT object_name) = 2
          AND bool_and(
            operation = 'grant'
            AND actor_name = session_user
            AND active_role_name = session_user
            AND reason = 'portable administrative ledger proof'
            AND ticket IS NULL
            AND old_revision_hash IS NOT NULL
            AND new_revision_hash IS NOT NULL
            AND (
              prior_revision_hash IS NULL
              OR old_revision_hash = prior_revision_hash
            )
          )
   FROM (
     SELECT
       event.*,
       lag(new_revision_hash) OVER (ORDER BY event_id) AS prior_revision_hash
     FROM otlet.administrative_change_events event
     WHERE object_name IN (
       'application:' || :'operator_role',
       'portable_worker:' || :'operator_role'
     )
   ) access_chain),
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 51
      AND file ~ '0051_administrative_change_ledger.sql$'
  ),
  NOT pg_catalog.has_table_privilege(
    'public',
    'otlet.administrative_change_events',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.audit_administrative_change_export',
      'SELECT'
    )
    AND NOT pg_catalog.has_sequence_privilege(
      'public',
      'otlet.administrative_change_events_event_id_seq',
      'USAGE,SELECT,UPDATE'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM unnest(ARRAY[
        'otlet.guard_administrative_change_events()'::regprocedure,
        'otlet.set_administrative_change_context(text,text)'::regprocedure,
        'otlet.administrative_state_hash(text,jsonb)'::regprocedure,
        'otlet.append_administrative_change(text,text,text,text,text)'::regprocedure,
        'otlet.record_administrative_row_change()'::regprocedure,
        'otlet.access_policy_descriptor(regrole)'::regprocedure,
        'otlet.access_policy_revision(regrole)'::regprocedure,
        'otlet.finish_access_policy_grant(text,regrole,text)'::regprocedure
      ]) AS function_oid(oid)
      WHERE pg_catalog.has_function_privilege(
        'public',
        function_oid.oid,
        'EXECUTE'
      )
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
ROLLBACK;
SQL
)"
[ "$administrative_migration_contract" = "t|t|t|t|t|t|t" ] || {
  echo "Portable administrative migration contract mismatch: $administrative_migration_contract" >&2
  exit 1
}

acceptance_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL' | tail -n 1
BEGIN;
SELECT otlet.register_model(
  'acceptance_upgrade_probe',
  '/tmp/acceptance-upgrade.gguf',
  repeat('a', 64),
  jsonb_build_object(
    'sha256', repeat('a', 64),
    'bytes', 1,
    'source', 'portable-upgrade-demo',
    'revision', 'acceptance-v1',
    'quantization', 'test',
    'license', 'test'
  )
) \g /dev/null
SELECT otlet.create_task(
  'acceptance_upgrade_probe',
  NULL,
  'Return JSON',
  '{"type":"object"}'::jsonb,
  'acceptance_upgrade_probe'
) \g /dev/null
SELECT otlet.ensure_active_workload_revision('acceptance_upgrade_probe')
  AS revision_hash
\gset acceptance_
WITH thresholds AS (
  SELECT jsonb_object_agg(
    category,
    jsonb_build_object(
      'metric', category,
      'statistic', 'rate',
      'operator', CASE
        WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 'gte'
        ELSE 'lte'
      END,
      'value', CASE
        WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 0.9
        ELSE 0.1
      END,
      'unit', 'ratio',
      'minimum_support', 1,
      'required', true
    )
  ) AS definition
  FROM unnest(ARRAY[
    'candidate_recall', 'false_trust', 'abstention', 'review_age',
    'review_minutes', 'freshness', 'latency', 'database_impact',
    'unit_cost', 'recovery', 'downstream_outcome'
  ]) category
)
SELECT otlet.register_workload_acceptance_contract(
  'acceptance_upgrade_probe',
  :'acceptance_revision_hash',
  :'acceptance_revision_hash',
  '{"mode":"full","rule":{"kind":"all_declared_subjects"}}'::jsonb,
  date_trunc('day', statement_timestamp()) + interval '1 day',
  date_trunc('day', statement_timestamp()) + interval '32 days',
  '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
  thresholds.definition
) AS contract_hash
FROM thresholds
\gset acceptance_
SELECT otlet.record_workload_acceptance_exception(
  :'acceptance_contract_hash',
  'unit_cost',
  '{"required":false}'::jsonb,
  '{}'::jsonb,
  'Portable acceptance proof exception'
) AS exception_hash
\gset acceptance_
SELECT otlet.record_workload_promotion_decision(
  :'acceptance_contract_hash',
  'defer',
  otlet.identity_hash('acceptance_upgrade_evidence', '{}'::jsonb),
  '{"status":"declared_not_evaluated"}'::jsonb,
  'Portable acceptance proof decision',
  exception_hashes => ARRAY[:'acceptance_exception_hash']
) AS decision_hash
\gset acceptance_
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 52
      AND file ~ '0052_workload_acceptance_contract.sql$'
  ),
  to_regclass('otlet.workload_acceptance_contracts') IS NOT NULL,
  to_regclass('otlet.workload_acceptance_events') IS NOT NULL,
  to_regclass('otlet.workload_acceptance_status') IS NOT NULL,
  to_regprocedure(
    'otlet.register_workload_acceptance_contract(text,text,text,jsonb,timestamptz,timestamptz,jsonb,jsonb,text)'
  ) IS NOT NULL,
  (SELECT count(*) = 1 FROM otlet.workload_acceptance_contracts),
  (SELECT count(*) = 2 FROM otlet.workload_acceptance_events),
  (SELECT count(*) = 1
   FROM otlet.workload_acceptance_status
   WHERE current
     AND threshold_categories = 11
     AND exceptions = 1
     AND promotion_decisions = 1
     AND latest_promotion_outcome = 'defer'),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.workload_acceptance_contracts', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  ),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.workload_acceptance_events', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  ),
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND function.proname IN (
        'register_workload_acceptance_contract',
        'record_workload_acceptance_exception',
        'record_workload_promotion_decision'
      )
      AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
  ),
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
  ),
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class relation
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'otlet'
      AND relation.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.aclexplode(relation.relacl) privilege
        WHERE privilege.grantee = 0
      )
  ),
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class relation
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'otlet'
      AND relation.relkind = 'S'
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.aclexplode(relation.relacl) privilege
        WHERE privilege.grantee = 0
      )
  )
);
ROLLBACK;
SQL
)"
[ "$acceptance_migration_contract" = "t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable acceptance migration contract mismatch: $acceptance_migration_contract" >&2
  exit 1
}

evaluation_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 53
      AND file ~ '0053_replayable_evaluation.sql$'
  ),
  EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'otlet'
      AND table_name = 'jobs'
      AND column_name = 'execution_mode'
  ),
  to_regclass('otlet.evaluation_cases') IS NOT NULL,
  to_regclass('otlet.evaluation_runs') IS NOT NULL,
  to_regclass('otlet.evaluation_executions') IS NOT NULL,
  to_regclass('otlet.evaluation_results') IS NOT NULL,
  to_regclass('otlet.evaluation_case_status') IS NOT NULL,
  to_regclass('otlet.evaluation_replay_status') IS NOT NULL,
  to_regclass('otlet.audit_evaluation_replay_export') IS NOT NULL,
  to_regprocedure('otlet.register_evaluation_case(bigint,text,text)') IS NOT NULL,
  to_regprocedure('otlet.start_replay_evaluation(text,text[],text,text)') IS NOT NULL,
  to_regprocedure('otlet.record_evaluation_result(bigint,bigint,bigint,jsonb,jsonb)') IS NOT NULL,
  (SELECT count(*) = 18
   FROM pg_catalog.pg_trigger trigger
   WHERE trigger.tgrelid IN (
     'otlet.evaluation_cases'::regclass,
     'otlet.evaluation_runs'::regclass,
     'otlet.evaluation_executions'::regclass,
     'otlet.evaluation_results'::regclass,
     'otlet.jobs'::regclass
   )
     AND trigger.tgname LIKE '%evaluation%'),
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND function.proname LIKE '%evaluation%'
      AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
  ),
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class relation
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'otlet'
      AND relation.relname LIKE '%evaluation%'
      AND relation.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND EXISTS (
        SELECT 1
        FROM pg_catalog.aclexplode(relation.relacl) privilege
        WHERE privilege.grantee = 0
      )
  )
);
SQL
)"
[ "$evaluation_migration_contract" = "t|t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable evaluation migration contract mismatch: $evaluation_migration_contract" >&2
  exit 1
}

population_lineage_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*) = 2 AND bool_and(is_nullable = 'NO')
   FROM information_schema.columns
   WHERE table_schema = 'otlet'
     AND table_name = 'evaluation_cases'
     AND column_name IN ('population_kind', 'lineage_hash'))
    AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_index index_row
      JOIN pg_catalog.pg_class index_relation
        ON index_relation.oid = index_row.indexrelid
      WHERE index_row.indrelid = 'otlet.evaluation_cases'::regclass
        AND index_relation.relname = 'evaluation_cases_lineage_idx'
        AND NOT index_row.indisunique
        AND index_row.indnkeyatts = 3
    ),
  to_regprocedure('otlet.validate_evaluation_run_population()') IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_trigger trigger
      WHERE trigger.tgrelid = 'otlet.evaluation_runs'::regclass
        AND trigger.tgname = 'evaluation_runs_c_population'
    ),
  to_regclass('otlet.evaluation_exposure_status') IS NOT NULL
    AND (SELECT count(*) = 21
         FROM information_schema.columns
         WHERE table_schema = 'otlet'
           AND table_name = 'evaluation_exposure_status')
    AND to_regprocedure('otlet.register_evaluation_case(bigint,text,text)') IS NOT NULL
    AND to_regprocedure('otlet.register_evaluation_case(bigint,text)') IS NULL
    AND to_regprocedure(
      'otlet.record_workload_promotion_decision(text,text,text,jsonb,text,text[],text[],text)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.record_workload_promotion_decision(text,text,text,jsonb,text,text[],text)'
    ) IS NULL,
  (SELECT count(*) = 2
   FROM information_schema.columns
   WHERE table_schema = 'otlet'
     AND table_name IN (
       'evaluation_replay_status',
       'audit_evaluation_replay_export'
     )
     AND column_name = 'same_input_snapshot')
    AND NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'otlet'
        AND table_name IN (
          'evaluation_replay_status',
          'audit_evaluation_replay_export'
        )
        AND column_name = 'same_population'
    ),
  NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.register_evaluation_case(bigint,text,text)',
    'EXECUTE'
  )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.validate_evaluation_run_population()',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.record_workload_promotion_decision(text,text,text,jsonb,text,text[],text[],text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.evaluation_exposure_status',
      'SELECT'
    )
    AND NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$population_lineage_migration_contract" = "t|t|t|t|t" ] || {
  echo "Portable population-lineage migration contract mismatch: $population_lineage_migration_contract" >&2
  exit 1
}

evaluation_slices_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 55
      AND file ~ '0055_evaluation_slices_support.sql$'
  ),
  to_regclass('otlet.evaluation_slice_reports') IS NOT NULL,
  to_regclass('otlet.evaluation_slice_status') IS NOT NULL,
  to_regprocedure(
    'otlet.record_evaluation_slice_report(text,jsonb,text)'
  ) IS NOT NULL,
  (SELECT count(*) = 3
   FROM pg_catalog.pg_trigger trigger
   WHERE trigger.tgrelid = 'otlet.evaluation_slice_reports'::regclass
     AND trigger.tgname LIKE 'evaluation_slice_reports%'),
  to_regprocedure(
    'otlet.evaluation_slice_member_manifest_valid(jsonb)'
  ) IS NOT NULL
    AND to_regprocedure('otlet.stamp_job_wall_clock()') IS NOT NULL
    AND to_regprocedure('otlet.validate_evaluation_slice_run()') IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM pg_catalog.pg_trigger trigger
      WHERE trigger.tgrelid = 'otlet.jobs'::regclass
        AND trigger.tgname = 'jobs_wall_clock'
    )
    AND EXISTS (
      SELECT 1 FROM pg_catalog.pg_trigger trigger
      WHERE trigger.tgrelid = 'otlet.evaluation_runs'::regclass
        AND trigger.tgname = 'evaluation_runs_d_slices'
    )
    AND (
      SELECT column_default = 'clock_timestamp()'
      FROM information_schema.columns
      WHERE table_schema = 'otlet'
        AND table_name = 'jobs'
        AND column_name = 'created_at'
    )
    AND (
      SELECT column_default = 'clock_timestamp()'
      FROM information_schema.columns
      WHERE table_schema = 'otlet'
        AND table_name = 'inference_receipts'
        AND column_name = 'finished_at'
    ),
  NOT pg_catalog.has_table_privilege(
    'public',
    'otlet.evaluation_slice_reports',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.evaluation_slice_status', 'SELECT'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.record_evaluation_slice_report(text,jsonb,text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public', 'otlet.validate_evaluation_slice_report()', 'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public', 'otlet.evaluation_slice_member_manifest_valid(jsonb)', 'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public', 'otlet.stamp_job_wall_clock()', 'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public', 'otlet.validate_evaluation_slice_run()', 'EXECUTE'
    )
    AND NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$evaluation_slices_migration_contract" = "t|t|t|t|t|t|t" ] || {
  echo "Portable evaluation-slices migration contract mismatch: $evaluation_slices_migration_contract" >&2
  exit 1
}

label_provenance_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 56
      AND file ~ '0056_label_provenance_quality.sql$'
  ),
  (SELECT count(*) = 17
   FROM information_schema.columns
   WHERE table_schema = 'otlet'
     AND table_name = 'eval_labels'
     AND column_name IN (
       'task_name',
       'workload_revision_hash',
       'content_hash',
       'label_revision',
       'authenticated_role_oid',
       'authenticated_role_name',
       'active_role_oid',
       'active_role_name',
       'adjudication_state',
       'label_confidence',
       'supersedes_label_id',
       'adjudication_reason',
       'adjudicated_authenticated_role_oid',
       'adjudicated_authenticated_role_name',
       'adjudicated_active_role_oid',
       'adjudicated_active_role_name',
       'adjudicated_at'
     ))
    AND (SELECT count(*) = 10
      FROM information_schema.columns
      WHERE table_schema = 'otlet'
        AND table_name = 'eval_labels'
        AND is_nullable = 'NO'
        AND column_name IN (
          'source_hash',
          'task_name',
          'workload_revision_hash',
          'content_hash',
          'label_revision',
          'authenticated_role_oid',
          'authenticated_role_name',
          'active_role_oid',
          'active_role_name',
          'adjudication_state'
        ))
    AND (SELECT count(*) = 12
      FROM pg_catalog.pg_constraint constraint_row
      WHERE constraint_row.conrelid = 'otlet.eval_labels'::regclass
        AND constraint_row.conname IN (
          'eval_labels_content_hash_check',
          'eval_labels_label_revision_check',
          'eval_labels_authenticated_role_name_check',
          'eval_labels_active_role_name_check',
          'eval_labels_adjudication_state_check',
          'eval_labels_supersedes_label_check',
          'eval_labels_adjudication_reason_check',
          'eval_labels_workload_revision_fkey',
          'eval_labels_adjudication_fields_check',
          'eval_labels_rejected_supersession_check',
          'eval_labels_supersedes_self_check',
          'eval_labels_supersedes_label_fkey'
        )),
  to_regclass('otlet.eval_label_quality_status') IS NOT NULL
    AND to_regclass('otlet.eval_label_series_revisions') IS NOT NULL
    AND to_regprocedure(
      'otlet.adjudicate_eval_label(bigint,text,numeric,text,bigint)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.current_task_subject_source_hash(text,text,text)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.eval_label_current_source_hash(bigint)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.cleanup_eval_label_series(timestamptz,boolean)'
    ) IS NOT NULL
    AND (SELECT count(*) = 1 AND bool_and(dry_run)
      FROM otlet.cleanup_policy_state(true)),
  (SELECT count(*) = 4
   FROM pg_catalog.pg_trigger trigger
   WHERE trigger.tgrelid = 'otlet.eval_labels'::regclass
     AND trigger.tgname IN (
       'eval_labels_b_provenance',
       'eval_labels_c_adjudication',
       'eval_labels_d_delete_guard',
       'eval_labels_truncate_guard'
     ))
    AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_trigger trigger
      WHERE trigger.tgrelid = 'otlet.evaluation_cases'::regclass
        AND trigger.tgname = 'evaluation_cases_c_label_quality'
    )
    AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_trigger trigger
      WHERE trigger.tgrelid = 'otlet.evaluation_runs'::regclass
        AND trigger.tgname = 'evaluation_runs_e_label_quality'
    )
    AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_trigger trigger
      WHERE trigger.tgrelid = 'otlet.workload_acceptance_events'::regclass
        AND trigger.tgname = 'workload_acceptance_events_c_label_quality'
    ),
  EXISTS (
    SELECT 1
    FROM pg_catalog.pg_indexes index
    WHERE index.schemaname = 'otlet'
      AND index.indexname = 'evaluation_cases_lineage_idx'
      AND index.indexdef NOT LIKE 'CREATE UNIQUE INDEX%'
  )
    AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_index index_row
      WHERE index_row.indexrelid = 'otlet.eval_labels_series_revision_idx'::regclass
        AND index_row.indisunique
        AND index_row.indnullsnotdistinct
    )
    AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_index index_row
      WHERE index_row.indexrelid = 'otlet.eval_labels_supersedes_idx'::regclass
        AND index_row.indisunique
    )
    AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_index index_row
      WHERE index_row.indexrelid = 'otlet.eval_label_series_revisions_key'::regclass
        AND index_row.indisunique
        AND index_row.indnullsnotdistinct
    ),
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc function_row
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = function_row.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND function_row.proname IN (
        'current_task_subject_input_snapshot',
        'current_task_subject_content_hash',
        'current_task_subject_source_hash',
        'eval_label_current_source_hash',
        'populate_eval_label_provenance',
        'guard_eval_label_adjudication',
        'lock_eval_label_series',
        'guard_eval_label_delete',
        'cleanup_eval_label_series',
        'cleanup_policy_state_without_label_quality',
        'cleanup_policy_state',
        'adjudicate_eval_label',
        'validate_evaluation_case_label_quality',
        'validate_evaluation_run_label_quality',
        'validate_promotion_label_quality'
      )
      AND pg_catalog.has_function_privilege(
        'public', function_row.oid, 'EXECUTE'
      )
  )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_class relation
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'otlet'
        AND relation.relname IN (
          'eval_label_series_revisions',
          'eval_label_quality_status',
          'eval_label_status',
          'audit_eval_label_export',
          'evaluation_case_status'
        )
        AND pg_catalog.has_table_privilege(
          'public', relation.oid,
          'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
        )
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$label_provenance_migration_contract" = "t|t|t|t|t|t|t" ] || {
  echo "Portable label-provenance migration contract mismatch: $label_provenance_migration_contract" >&2
  exit 1
}

production_model_qualification_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 57
      AND file ~ '0057_production_model_qualification.sql$'
  ),
  to_regclass('otlet.production_model_database_samples') IS NOT NULL
    AND to_regclass('otlet.production_model_cancellation_probes') IS NOT NULL
    AND to_regclass('otlet.production_model_qualification_status') IS NOT NULL,
  to_regprocedure(
    'otlet.production_model_qualification_rule_valid(jsonb)'
  ) IS NOT NULL
    AND to_regprocedure(
      'otlet.record_production_model_database_sample(text,text)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.start_production_model_cancellation_probes(text,text)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.record_production_model_qualification(text,text,text)'
    ) IS NOT NULL,
  EXISTS (
    SELECT 1
    FROM pg_catalog.pg_constraint constraint_row
    WHERE constraint_row.conrelid = 'otlet.workload_acceptance_events'::regclass
      AND constraint_row.contype = 'c'
      AND pg_catalog.pg_get_constraintdef(constraint_row.oid)
        LIKE '%model_qualification%'
  )
    AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_indexes index_row
      WHERE index_row.schemaname = 'otlet'
        AND index_row.indexname =
          'workload_acceptance_events_one_model_qualification_idx'
    ),
  (SELECT count(*) = 6
   FROM pg_catalog.pg_trigger trigger
   WHERE trigger.tgrelid IN (
       'otlet.production_model_database_samples'::regclass,
       'otlet.production_model_cancellation_probes'::regclass
     )
     AND NOT trigger.tgisinternal)
    AND pg_get_functiondef('otlet.stamp_job_wall_clock()'::regprocedure)
      LIKE '%cancel_requested_at := clock_timestamp()%',
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'otlet.production_model_qualification_rule_valid(jsonb)'::regprocedure,
      'otlet.validate_production_model_database_sample()'::regprocedure,
      'otlet.record_production_model_database_sample(text,text)'::regprocedure,
      'otlet.validate_production_model_cancellation_probe()'::regprocedure,
      'otlet.start_production_model_cancellation_probes(text,text)'::regprocedure,
      'otlet.record_production_model_qualification(text,text,text)'::regprocedure
    ]) function_row(oid)
    WHERE pg_catalog.has_function_privilege('public', function_row.oid, 'EXECUTE')
  )
    AND NOT EXISTS (
      SELECT 1
      FROM unnest(ARRAY[
        'otlet.production_model_database_samples'::regclass,
        'otlet.production_model_cancellation_probes'::regclass,
        'otlet.production_model_qualification_status'::regclass
      ]) relation(oid)
      WHERE pg_catalog.has_table_privilege(
        'public', relation.oid,
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
      )
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$production_model_qualification_migration_contract" = "t|t|t|t|t|t|t" ] || {
  echo "Portable production-model-qualification migration contract mismatch: $production_model_qualification_migration_contract" >&2
  exit 1
}

promotion_shadow_rollback_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 58
      AND file ~ '0058_promotion_shadow_rollback.sql$'
  ),
  to_regclass('otlet.workload_shadow_comparison_status') IS NOT NULL
    AND to_regclass('otlet.workload_promotion_status') IS NOT NULL,
  to_regprocedure('otlet.validate_promotion_shadow_run()') IS NOT NULL
    AND to_regprocedure('otlet.guard_governed_workload_promotion()') IS NOT NULL
    AND to_regprocedure(
      'otlet.activate_workload_promotion(text,text)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.rollback_workload_promotion(text,text,text,text)'
    ) IS NOT NULL,
  EXISTS (
    SELECT 1
    FROM pg_catalog.pg_constraint constraint_row
    WHERE constraint_row.conrelid = 'otlet.workload_acceptance_events'::regclass
      AND constraint_row.contype = 'c'
      AND pg_catalog.pg_get_constraintdef(constraint_row.oid)
        LIKE '%promotion_activation%'
      AND pg_catalog.pg_get_constraintdef(constraint_row.oid)
        LIKE '%promotion_rollback%'
  )
    AND to_regclass(
      'otlet.workload_acceptance_events_one_promotion_activation_idx'
    ) IS NOT NULL
    AND to_regclass(
      'otlet.workload_acceptance_events_one_promotion_rollback_idx'
    ) IS NOT NULL,
  EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger trigger
    WHERE trigger.tgrelid = 'otlet.evaluation_runs'::regclass
      AND trigger.tgname = 'evaluation_runs_e_promotion_shadow'
      AND NOT trigger.tgisinternal
  )
    AND EXISTS (
      SELECT 1
      FROM pg_catalog.pg_trigger trigger
      WHERE trigger.tgrelid = 'otlet.workload_revision_heads'::regclass
        AND trigger.tgname = 'workload_revision_heads_governed_promotion'
        AND NOT trigger.tgisinternal
    )
    AND pg_get_functiondef(
      'otlet.promote_workload_revision(text,text,text)'::regprocedure
    ) LIKE '%otlet.workload_revision_operation%'
    AND pg_get_functiondef(
      'otlet.guard_governed_workload_promotion()'::regprocedure
    ) LIKE '%promotion_shadow%'
    AND pg_get_functiondef(
      'otlet.guard_governed_workload_promotion()'::regprocedure
    ) NOT LIKE '%successor%'
    AND pg_get_functiondef(
      'otlet.guard_governed_workload_promotion()'::regprocedure
    ) LIKE '%lifecycle_revision_hash%'
    AND pg_get_functiondef(
      'otlet.activate_workload_promotion(text,text)'::regprocedure
    ) LIKE '%requires distinct revisions%',
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'otlet.validate_promotion_shadow_run()'::regprocedure,
      'otlet.guard_governed_workload_promotion()'::regprocedure,
      'otlet.activate_workload_promotion(text,text)'::regprocedure,
      'otlet.rollback_workload_promotion(text,text,text,text)'::regprocedure
    ]) function_row(oid)
    WHERE pg_catalog.has_function_privilege('public', function_row.oid, 'EXECUTE')
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.workload_shadow_comparison_status', 'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.workload_promotion_status', 'SELECT'
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$promotion_shadow_rollback_migration_contract" = "t|t|t|t|t|t|t" ] || {
  echo "Portable promotion-shadow-rollback migration contract mismatch: $promotion_shadow_rollback_migration_contract" >&2
  exit 1
}

quality_data_drift_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 59
      AND file ~ '0059_quality_data_drift.sql$'
  ),
  to_regclass('otlet.task_candidate_observations') IS NOT NULL
    AND to_regclass('otlet.quality_data_drift_reports') IS NOT NULL
    AND to_regclass('otlet.quality_data_drift_status') IS NOT NULL
    AND (SELECT count(*) = 7
      FROM information_schema.columns
      WHERE table_schema = 'otlet'
        AND table_name = 'task_candidate_observations'
        AND column_name IN (
          'observation_hash',
          'task_name',
          'workload_revision_hash',
          'candidate_rows',
          'candidate_bytes',
          'largest_input_bytes',
          'admitted'
        )),
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'otlet.guard_quality_data_drift_append()'::regprocedure,
      'otlet.validate_task_candidate_observation()'::regprocedure,
      'otlet.record_task_candidate_observation(text,text,bigint,bigint,bigint,boolean,text)'::regprocedure,
      'otlet.quality_data_input_shape(jsonb)'::regprocedure,
      'otlet.quality_data_distribution_drift(jsonb,jsonb)'::regprocedure,
      'otlet.quality_data_reviewer_overturn(text)'::regprocedure,
      'otlet.quality_data_report_metrics(text,text)'::regprocedure,
      'otlet.quality_data_drift_declaration_valid(jsonb)'::regprocedure,
      'otlet.validate_quality_data_drift_contract()'::regprocedure,
      'otlet.validate_quality_data_drift_report()'::regprocedure,
      'otlet.record_quality_data_drift_report(text,text,text,text)'::regprocedure
    ]) function_row(oid)
    WHERE function_row.oid IS NULL
  )
    AND position(
      'record_task_candidate_observation' IN
      pg_get_functiondef('otlet.run_task_with_origin(text,text)'::regprocedure)
    ) > 0,
  (SELECT count(*) = 7
   FROM pg_catalog.pg_trigger trigger
   WHERE NOT trigger.tgisinternal
     AND trigger.tgname IN (
       'task_candidate_observations_a_guard',
       'task_candidate_observations_b_validate',
       'task_candidate_observations_truncate_guard',
       'workload_acceptance_contracts_c_quality_data_drift',
       'quality_data_drift_reports_a_guard',
       'quality_data_drift_reports_b_validate',
       'quality_data_drift_reports_truncate_guard'
     )),
  otlet.quality_data_drift_declaration_valid('{
    "format":"otlet.quality_data_drift.v1",
    "report_hash":"otlet:v1:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "variant":"candidate",
    "candidate_observation_hash":"otlet:v1:sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "reviewer_overturn":{
      "value":0,
      "support":2,
      "overturns":0,
      "evidence_hash":"otlet:v1:sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    },
    "minimum_support":2,
    "maximum_drift":{
      "input_shape":0,
      "candidate_volume":0.2,
      "class":0.1,
      "abstention":0.2,
      "escalation":0.5,
      "reviewer_overturn":0.2,
      "false_trust":0.1
    }
  }'::jsonb)
    AND NOT otlet.quality_data_drift_declaration_valid('{
      "format":"otlet.quality_data_drift.v1",
      "report_hash":"otlet:v1:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "variant":"candidate",
      "candidate_observation_hash":"otlet:v1:sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "reviewer_overturn":{
        "value":0,
        "support":2,
        "overturns":0,
        "evidence_hash":"otlet:v1:sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      },
      "minimum_support":2,
      "maximum_drift":{
        "input_shape":0.1,
        "candidate_volume":0.2,
        "class":0.1,
        "abstention":0.2,
        "escalation":0.5,
        "reviewer_overturn":0.2,
        "false_trust":0.1
      },
      "confidence":"high"
    }'::jsonb)
    AND otlet.quality_data_input_shape('{"field":1}'::jsonb) =
      otlet.quality_data_input_shape('{"field":2}'::jsonb)
    AND otlet.quality_data_input_shape('{"field":1}'::jsonb) <>
      otlet.quality_data_input_shape('{"field":"1"}'::jsonb)
    AND otlet.quality_data_distribution_drift(
      '{"a":0.5,"b":0.5}'::jsonb,
      '{"a":0.25,"c":0.75}'::jsonb
    ) = 0.75
    AND otlet.quality_data_input_shape(jsonb_build_object(
      'items',
      (SELECT jsonb_agg(value) FROM generate_series(1, 4097) value)
    )) IS NULL,
  position(
    'confidence' IN lower(pg_get_viewdef('otlet.quality_data_drift_status'::regclass, true))
  ) = 0
    AND pg_get_viewdef('otlet.quality_data_drift_status'::regclass, true)
      LIKE '%insufficient_evidence%'
    AND position(
      'confidence' IN lower(pg_get_functiondef(
        'otlet.quality_data_report_metrics(text,text)'::regprocedure
      ))
    ) = 0,
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.task_candidate_observations',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.quality_data_drift_reports',
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.quality_data_drift_status', 'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname IN (
          'guard_quality_data_drift_append',
          'validate_task_candidate_observation',
          'record_task_candidate_observation',
          'quality_data_input_shape',
          'quality_data_distribution_drift',
          'quality_data_reviewer_overturn',
          'quality_data_report_metrics',
          'quality_data_drift_declaration_valid',
          'validate_quality_data_drift_contract',
          'validate_quality_data_drift_report',
          'record_quality_data_drift_report'
        )
        AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
    ),
  (SELECT count(*) = 2
   FROM pg_catalog.pg_constraint constraint_row
   WHERE constraint_row.conrelid = 'otlet.quality_data_drift_reports'::regclass
     AND constraint_row.contype = 'u')
    AND (SELECT count(*) = 0 FROM otlet.quality_data_drift_reports)
    AND (SELECT count(*) = 0 FROM otlet.task_candidate_observations),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$quality_data_drift_migration_contract" = "t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable quality-data-drift migration contract mismatch: $quality_data_drift_migration_contract" >&2
  exit 1
}

review_economics_migration_contract_query() {
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 60
      AND file LIKE '%0060_review_economics.sql'
  ),
  to_regclass('otlet.review_economics_reports') IS NOT NULL
    AND to_regclass('otlet.review_economics_status') IS NOT NULL
    AND to_regprocedure(
      'otlet.review_economics_comparison(numeric,numeric,integer,integer,integer)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.review_economics_metrics(text,text,jsonb,numeric,numeric)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.record_review_economics_report(text,text,jsonb,text)'
    ) IS NOT NULL,
  (SELECT count(*) = 4
      AND bool_and(
        trigger.tgrelid = expected.relation
        AND trigger.tgfoid = expected.function
        AND trigger.tgtype = expected.trigger_type
        AND trigger.tgenabled = 'O'
      )
   FROM (VALUES
     (
       'workload_acceptance_contracts_d_review_economics'::name,
       'otlet.workload_acceptance_contracts'::regclass,
       'otlet.validate_review_economics_contract()'::regprocedure,
       7::smallint
     ),
     (
       'review_economics_reports_a_guard'::name,
       'otlet.review_economics_reports'::regclass,
       'otlet.guard_review_economics_append()'::regprocedure,
       31::smallint
     ),
     (
       'review_economics_reports_b_validate'::name,
       'otlet.review_economics_reports'::regclass,
       'otlet.validate_review_economics_report()'::regprocedure,
       7::smallint
     ),
     (
       'review_economics_reports_truncate_guard'::name,
       'otlet.review_economics_reports'::regclass,
       'otlet.guard_review_economics_append()'::regprocedure,
       34::smallint
     )
   ) expected(trigger_name, relation, function, trigger_type)
   JOIN pg_catalog.pg_trigger trigger
     ON trigger.tgname = expected.trigger_name
    AND NOT trigger.tgisinternal),
  otlet.review_economics_declaration_valid('{
    "format":"otlet.review_economics.v1",
    "cost_unit":"USD",
    "reviewer_cost_per_hour":60,
    "model_generation_cost_per_hour":3600,
    "minimum_support":2
  }'::jsonb)
    AND NOT otlet.review_economics_declaration_valid('{
      "format":"otlet.review_economics.v1",
      "cost_unit":"USD",
      "reviewer_cost_per_hour":60,
      "model_generation_cost_per_hour":3600,
      "minimum_support":2,
      "currency_conversion":true
    }'::jsonb),
  (WITH claim AS (
     SELECT jsonb_build_object(
       'case_hash', 'otlet:v1:sha256:' || repeat('a', 64),
       'variant', 'baseline',
       'reported_disposition', 'failed',
       'reported_downstream_success', false,
       'reported_avoided_work_seconds', 0,
       'reported_at', '2026-08-02T00:00:00.000000Z'
     ) AS value
   ), manifest AS (
     SELECT jsonb_build_array(claim.value) AS value
     FROM claim
   )
   SELECT otlet.review_economics_observation_manifest_valid(manifest.value)
     AND NOT otlet.review_economics_observation_manifest_valid(jsonb_set(
       manifest.value,
       '{0,unexpected}',
       'true'::jsonb
     ))
   FROM manifest),
  (otlet.review_economics_comparison(2, 3, 2, 2, 2) #>>
    '{absolute_delta}')::numeric = 1
    AND otlet.review_economics_comparison(2, 3, 2, 2, 2) ->
      'evidence_ready' = 'true'::jsonb
    AND otlet.review_economics_comparison(0, 1, 2, 1, 2) ->
      'evidence_ready' = 'false'::jsonb
    AND otlet.review_economics_comparison(0, 1, 2, 1, 2) ->
      'absolute_delta' = 'null'::jsonb
    AND otlet.review_economics_comparison(0, 1, 2, 1, 2) ->
      'relative_delta' = 'null'::jsonb
    AND (otlet.review_economics_comparison(0, 0, 2, 2, 2) #>>
      '{relative_delta}')::numeric = 0,
  pg_get_viewdef('otlet.review_economics_status'::regclass, true)
      LIKE '%insufficient_evidence%'
    AND pg_get_viewdef('otlet.review_economics_status'::regclass, true)
      LIKE '%partial_evidence%'
    AND pg_get_viewdef('otlet.review_economics_status'::regclass, true)
      LIKE '%model_generation_cost_per_hour%'
    AND pg_get_functiondef(
      'otlet.validate_review_economics_contract()'::regprocedure
    ) LIKE '%requires distinct revisions%'
    AND pg_get_viewdef('otlet.review_economics_status'::regclass, true)
      LIKE '%non_authoritative%'
    AND pg_get_functiondef(
      'otlet.review_economics_metrics(text,text,jsonb,numeric,numeric)'::regprocedure
    ) LIKE '%model_generation_time_only%'
    AND pg_get_functiondef(
      'otlet.review_economics_metrics(text,text,jsonb,numeric,numeric)'::regprocedure
    ) LIKE '%shared_worker_process_snapshot_not_costed%',
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.review_economics_reports',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.review_economics_status', 'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname IN (
          'guard_review_economics_append',
          'review_economics_observation_manifest_valid',
          'review_economics_declaration_valid',
          'validate_review_economics_contract',
          'review_economics_comparison',
          'review_economics_metrics',
          'validate_review_economics_report',
          'record_review_economics_report'
        )
        AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
    ),
  (SELECT count(*) = 1
   FROM pg_catalog.pg_constraint constraint_row
   WHERE constraint_row.conrelid = 'otlet.review_economics_reports'::regclass
     AND constraint_row.contype = 'u')
    AND (SELECT count(*) = 0 FROM otlet.review_economics_reports),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
}
review_economics_migration_contract="$(review_economics_migration_contract_query)"
[ "$review_economics_migration_contract" = "t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable review-economics migration contract mismatch: $review_economics_migration_contract" >&2
  exit 1
}

model_license_use_migration_contract_query() {
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SET LOCAL otlet.administrative_reason = 'portable model license use proof';
SELECT otlet.register_model(
  'model_license_use_upgrade_probe',
  '/tmp/model-license-use-upgrade.gguf',
  repeat('f', 64),
  jsonb_build_object(
    'sha256', repeat('f', 64),
    'bytes', 1,
    'source', 'portable-upgrade-demo',
    'revision', 'model-license-use-v1',
    'quantization', 'test',
    'license', 'unknown'
  )
) \g /dev/null
DO $body$
BEGIN
  BEGIN
    PERFORM otlet.register_model(
      'model_license_use_non_string_probe',
      '/tmp/model-license-use-non-string.gguf',
      repeat('e', 64),
      jsonb_build_object(
        'sha256', repeat('e', 64),
        'bytes', 1,
        'source', 'portable-upgrade-demo',
        'revision', 'model-license-use-v1',
        'quantization', 'test',
        'license', 5
      )
    );
    RAISE EXCEPTION 'non-string model license unexpectedly succeeded';
  EXCEPTION WHEN check_violation THEN
    PERFORM set_config('otlet.model_license_non_string_blocked', 'on', true);
  END;
END;
$body$;
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 61
      AND file LIKE '%0061_model_license_use_policy.sql'
  ),
  to_regclass('otlet.model_license_use_policies') IS NOT NULL
    AND to_regclass('otlet.model_license_use_policy_status') IS NOT NULL
    AND to_regprocedure(
      'otlet.model_license_use_policy_valid(jsonb)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.set_model_license_use_policy(jsonb,text,text)'
    ) IS NOT NULL
    AND current_setting('otlet.model_license_non_string_blocked', true) = 'on',
  (SELECT count(*) = 2
      AND bool_and(
        trigger.tgrelid = expected.relation
        AND trigger.tgfoid = expected.function
        AND trigger.tgtype = expected.trigger_type
        AND trigger.tgenabled = 'O'
      )
   FROM (VALUES
     (
       'model_license_use_policies_row_guard'::name,
       'otlet.model_license_use_policies'::regclass,
       'otlet.guard_model_license_use_policy()'::regprocedure,
       31::smallint
     ),
     (
       'model_license_use_policies_truncate_guard'::name,
       'otlet.model_license_use_policies'::regclass,
       'otlet.guard_model_license_use_policy()'::regprocedure,
       34::smallint
     )
   ) expected(trigger_name, relation, function, trigger_type)
   JOIN pg_catalog.pg_trigger trigger
     ON trigger.tgname = expected.trigger_name
    AND NOT trigger.tgisinternal),
  otlet.model_license_use_policy_valid('{
    "format":"otlet.model_license_use_policy.v1",
    "deployment_purpose":"customer_support",
    "redistribution_mode":"none",
    "license_allowlist":[{
      "license":"apache-2.0",
      "deployment_purposes":["customer_support"],
      "redistribution_modes":["none"],
      "unresolved_fields":[]
    }]
  }'::jsonb)
    AND NOT otlet.model_license_use_policy_valid('{
      "format":"otlet.model_license_use_policy.v1",
      "deployment_purpose":"customer_support",
      "redistribution_mode":"none",
      "license_allowlist":[],
      "legal_interpretation":true
    }'::jsonb),
  (SELECT count(*) = 0 FROM otlet.model_license_use_policies)
    AND (SELECT status.policy_state = 'unresolved'
      AND status.policy_reason = 'policy_missing'
      AND status.unresolved_fields = ARRAY['policy']::text[]
    FROM otlet.model_license_use_policy_status status
    WHERE status.model_name = 'model_license_use_upgrade_probe'),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.model_license_use_policies',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.model_license_use_policy_status', 'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname IN (
          'model_license_use_policy_valid',
          'guard_model_license_use_policy',
          'set_model_license_use_policy'
        )
        AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
ROLLBACK;
SQL
}
model_license_use_migration_contract="$(model_license_use_migration_contract_query)"
[ "$model_license_use_migration_contract" = "t|t|t|t|t|t|t" ] || {
  echo "Portable model-license-use migration contract mismatch: $model_license_use_migration_contract" >&2
  exit 1
}

model_artifact_lifecycle_migration_contract_query() {
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SET LOCAL otlet.administrative_reason = 'portable model lifecycle proof';
CREATE TEMP TABLE model_artifact_lifecycle_proof (
  identity_guarded boolean NOT NULL DEFAULT false,
  lifecycle_guarded boolean NOT NULL DEFAULT false,
  delete_guarded boolean NOT NULL DEFAULT false,
  observation_guarded boolean NOT NULL DEFAULT false
);
INSERT INTO model_artifact_lifecycle_proof DEFAULT VALUES;
SELECT otlet.register_model(
  'model_lifecycle_upgrade_old',
  '/tmp/model-lifecycle-upgrade/old.gguf',
  repeat('1', 64),
  jsonb_build_object(
    'sha256', repeat('1', 64),
    'bytes', 3,
    'source', 'portable-upgrade-demo',
    'revision', 'old-v1',
    'quantization', 'test',
    'license', 'test'
  )
) \g /dev/null
SELECT otlet.register_model(
  'model_lifecycle_upgrade_alias',
  '/tmp/model-lifecycle-upgrade/old.gguf',
  repeat('1', 64),
  jsonb_build_object(
    'sha256', repeat('1', 64),
    'bytes', 3,
    'source', 'portable-upgrade-demo',
    'revision', 'old-v1',
    'quantization', 'test',
    'license', 'test'
  )
) \g /dev/null
SELECT otlet.register_model(
  'model_lifecycle_upgrade_new',
  '/tmp/model-lifecycle-upgrade/new.gguf',
  repeat('2', 64),
  jsonb_build_object(
    'sha256', repeat('2', 64),
    'bytes', 4,
    'source', 'portable-upgrade-demo',
    'revision', 'new-v1',
    'quantization', 'test',
    'license', 'test'
  )
) \g /dev/null
DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.register_model(
      'model_lifecycle_upgrade_old',
      '/tmp/model-lifecycle-upgrade/replaced.gguf',
      repeat('3', 64),
      jsonb_build_object(
        'sha256', repeat('3', 64),
        'bytes', 5,
        'source', 'portable-upgrade-demo',
        'revision', 'changed',
        'quantization', 'test',
        'license', 'test'
      )
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('artifact identity is immutable' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof SET identity_guarded = true;
  END;
  BEGIN
    UPDATE otlet.models
    SET lifecycle_state = 'disabled'
    WHERE name = 'model_lifecycle_upgrade_old';
  EXCEPTION WHEN OTHERS THEN
    IF position('require set_model_lifecycle' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof SET lifecycle_guarded = true;
  END;
  BEGIN
    DELETE FROM otlet.models WHERE name = 'model_lifecycle_upgrade_old';
  EXCEPTION WHEN OTHERS THEN
    IF position('model registrations are retained' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof SET delete_guarded = true;
  END;
END
$proof$;
SELECT otlet.reconcile_model_artifact_store(
  1,
  jsonb_build_object(
    'format', 'otlet.model_artifact_store.observation.v1',
    'evidence_source', 'deployment_reported',
    'store_root', '/tmp/model-lifecycle-upgrade',
    'capacity_bytes', 100,
    'available_bytes', 90,
    'artifacts', jsonb_build_array(
      jsonb_build_object(
        'path', '/tmp/model-lifecycle-upgrade/new.gguf',
        'sha256', repeat('2', 64),
        'bytes', 4
      ),
      jsonb_build_object(
        'path', '/tmp/model-lifecycle-upgrade/old.gguf',
        'sha256', repeat('1', 64),
        'bytes', 3
      )
    )
  ),
  'portable model lifecycle proof',
  NULL
) \gset lifecycle_
SELECT otlet.reconcile_model_artifact_store(
  1,
  (SELECT definition FROM otlet.model_artifact_store_observations),
  'exact retry',
  NULL
) = :'lifecycle_reconcile_model_artifact_store' \g /dev/null
DO $proof$
BEGIN
  BEGIN
    UPDATE otlet.model_artifact_store_observations
    SET generation = generation + 1;
  EXCEPTION WHEN OTHERS THEN
    IF position('require reconcile_model_artifact_store' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof SET observation_guarded = true;
  END;
END
$proof$;
SELECT otlet.set_model_lifecycle(
  'model_lifecycle_upgrade_old',
  'deprecated',
  'model_lifecycle_upgrade_new',
  NULL,
  'replacement declared',
  NULL
) \g /dev/null
SELECT otlet.set_model_lifecycle(
  'model_lifecycle_upgrade_old',
  'draining',
  'model_lifecycle_upgrade_new',
  NULL,
  'drain old model',
  NULL
) \g /dev/null
SELECT otlet.set_model_lifecycle(
  'model_lifecycle_upgrade_old',
  'disabled',
  'model_lifecycle_upgrade_new',
  NULL,
  'disable old model',
  NULL
) \g /dev/null
SELECT otlet.set_model_lifecycle(
  'model_lifecycle_upgrade_alias',
  'disabled',
  NULL,
  NULL,
  'disable shared alias',
  NULL
) \g /dev/null
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 62
      AND file LIKE '%0062_model_artifact_lifecycle.sql'
  ),
  (SELECT identity_guarded AND lifecycle_guarded AND delete_guarded
      AND observation_guarded
    FROM model_artifact_lifecycle_proof),
  (SELECT count(*) = 3
      AND bool_and(artifact_reconciliation_state = 'verified')
    FROM otlet.model_lifecycle_status
    WHERE model_name LIKE 'model_lifecycle_upgrade_%'),
  (SELECT lifecycle_state = 'disabled'
      AND replacement_model_name = 'model_lifecycle_upgrade_new'
      AND release_requested
      AND drain_complete
    FROM otlet.model_lifecycle_status
    WHERE model_name = 'model_lifecycle_upgrade_old'),
  (SELECT prune_ready
      AND action = 'delete_external_file'
      AND registration_count = 2
      AND matching_registrations = 2
      AND reclaimable_bytes = 3
      AND deletion_owner = 'deployment'
      AND dry_run
    FROM otlet.model_artifact_pruning_plan
    WHERE artifact_path = '/tmp/model-lifecycle-upgrade/old.gguf'),
  (SELECT reconciliation_state = 'reconciled'
      AND capacity_bytes = 100
      AND available_bytes = 90
      AND reclaimable_bytes = 3
      AND projected_available_bytes = 93
      AND recorded_by = current_user
      AND deletion_owner = 'deployment'
    FROM otlet.model_artifact_store_status),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.model_artifact_store_observations',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.model_artifact_dependency_status', 'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.model_lifecycle_status', 'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.model_artifact_pruning_plan', 'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.model_artifact_store_status', 'SELECT'
    ),
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND function.proname IN (
        'set_model_lifecycle',
        'reconcile_model_artifact_store',
        'model_artifact_release_requested',
        'synchronize_portable_worker_model_release'
      )
      AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
  ),
  (SELECT count(*) = 1
    FROM otlet.administrative_change_events
    WHERE object_type = 'model'
      AND object_name = 'artifact_store:default'
      AND operation = 'reconcile'),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
ROLLBACK;
SQL
}
model_artifact_lifecycle_migration_contract="$(
  model_artifact_lifecycle_migration_contract_query
)"
[ "$model_artifact_lifecycle_migration_contract" = \
  "t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable model-artifact-lifecycle migration contract mismatch: $model_artifact_lifecycle_migration_contract" >&2
  exit 1
}

failure_retry_taxonomy_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 -v operator_role="$operator_role" <<'SQL'
BEGIN;
SELECT otlet.grant_application_access(:'operator_role'::regrole) \g /dev/null
SELECT otlet.grant_auditor_access(:'operator_role'::regrole) \g /dev/null
CREATE TEMP TABLE failure_taxonomy_immutability_proof (
  guarded boolean NOT NULL
) ON COMMIT DROP;
DO $body$
BEGIN
  BEGIN
    UPDATE otlet.failure_taxonomy
    SET owner_action = owner_action
    WHERE failure_reason_code = 'otlet.failure.v1.attempt_timeout';
    INSERT INTO failure_taxonomy_immutability_proof VALUES (false);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO failure_taxonomy_immutability_proof
    VALUES (SQLERRM LIKE 'otlet failure taxonomy rows are immutable%');
  END;
END
$body$;
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 63
      AND file LIKE '%0063_failure_retry_taxonomy.sql'
  ),
  (SELECT count(*) = 16
      AND min(taxonomy_version) = 1
      AND max(taxonomy_version) = 1
    FROM otlet.failure_taxonomy),
  (SELECT count(*) = 2
    FROM information_schema.columns
    WHERE table_schema = 'otlet'
      AND table_name IN ('jobs', 'inference_receipts')
      AND column_name = 'failure_reason_code'),
  (SELECT count(*) = 4
    FROM pg_catalog.pg_constraint constraint_row
    WHERE constraint_row.conname IN (
      'jobs_failure_reason_state_check',
      'jobs_failure_reason_fk',
      'inference_receipts_failure_reason_state_check',
      'inference_receipts_failure_reason_fk'
    )),
  to_regclass('otlet.failure_retry_status') IS NOT NULL,
  to_regprocedure('otlet.classify_failure_reason(text,text,text,text,jsonb,text,text)') IS NOT NULL,
  otlet.classify_failure_reason(
    'failed', 'direct', 'direct_attempt_failed', 'failed',
    '{"stop_reason":"prompt_exceeds_context_window"}'::jsonb,
    'linked llama.cpp prompt exceeds context window', 'linked_inproc'
  ) = 'otlet.failure.v1.runtime_configuration_rejected',
  otlet.classify_failure_reason(
    'failed', 'direct', 'attempt_timeout', 'failed',
    '{"stop_reason":"attempt_timeout"}'::jsonb,
    'attempt_timeout', 'portable:llama_cpp'
  ) = 'otlet.failure.v1.attempt_timeout',
  otlet.classify_failure_reason(
    'failed', NULL, NULL, NULL, '{}'::jsonb,
    'source field allowlist violation', NULL
  ) = 'otlet.failure.v1.source_contract_rejected',
  (SELECT bool_and(
      otlet.failure_reason_from_slug(failure_reason_code) = failure_reason_code
      AND otlet.failure_reason_from_slug(
        'otlet_error:' || reason_code || ':upgrade-proof'
      ) = failure_reason_code
    )
    FROM otlet.failure_taxonomy),
  (SELECT policy_version = 6
          AND withheld_fields @> ARRAY['job_error', 'receipt_error']::text[]
          AND export_views @> ARRAY['otlet.failure_retry_status']::text[]
   FROM otlet.redaction_policy_status),
  (SELECT guarded FROM failure_taxonomy_immutability_proof),
  pg_catalog.pg_get_function_result(
    'otlet.application_job_status(bigint)'::regprocedure
  ) LIKE '%failure_reason_code text%failure_stage text%failure_retryability text%recommended_retry_mode text%',
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.failure_taxonomy', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.failure_retry_status', 'SELECT'
    )
    AND NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.classify_failure_reason(text,text,text,text,jsonb,text,text)',
      'EXECUTE'
    ),
  pg_catalog.has_function_privilege(
    :'operator_role',
    'otlet.application_job_status(bigint)',
    'EXECUTE'
  )
    AND pg_catalog.has_table_privilege(
      :'operator_role', 'otlet.failure_taxonomy', 'SELECT'
    )
    AND pg_catalog.has_table_privilege(
      :'operator_role', 'otlet.failure_retry_status', 'SELECT'
    )
);
ROLLBACK;
SQL
)"
[ "$failure_retry_taxonomy_migration_contract" = \
  "t|t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable failure-retry-taxonomy migration contract mismatch: $failure_retry_taxonomy_migration_contract" >&2
  exit 1
}

candidate_set_coverage_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v operator_role="$operator_role" \
    -v partial_auditor_role="$partial_auditor_role" <<'SQL'
BEGIN;
CREATE TABLE public.otlet_candidate_set_coverage_upgrade_probe (
  subject_id text PRIMARY KEY,
  input jsonb NOT NULL
);
WITH built AS (
  SELECT otlet.build_candidate_set_coverage_rule(
    $query$
      SELECT 1::bigint AS candidate_rank, subject_id, input
      FROM public.otlet_candidate_set_coverage_upgrade_probe
    $query$,
    ARRAY['_otlet_mvcc', 'source'],
    20,
    0.95,
    5,
    0.9,
    1,
    0.2
  ) AS rule
)
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 64
      AND file LIKE '%0064_candidate_set_coverage.sql'
  ),
  to_regclass('otlet.candidate_set_coverage_reports') IS NOT NULL,
  to_regclass('otlet.candidate_set_coverage_status') IS NOT NULL,
  to_regprocedure(
    'otlet.record_candidate_set_coverage(text,text)'
  ) IS NOT NULL,
  to_regprocedure(
    'otlet.build_candidate_set_coverage_rule(text,text[],integer,numeric,integer,numeric,integer,numeric)'
  ) IS NOT NULL,
  (SELECT count(*) = 5
   FROM pg_catalog.pg_trigger trigger
   JOIN pg_catalog.pg_class relation ON relation.oid = trigger.tgrelid
   JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
   WHERE namespace.nspname = 'otlet'
     AND NOT trigger.tgisinternal
     AND trigger.tgname IN (
       'workload_acceptance_contracts_e_candidate_set_coverage',
       'candidate_set_coverage_reports_a_guard',
       'candidate_set_coverage_reports_b_validate',
       'candidate_set_coverage_reports_truncate_guard',
       'workload_revision_heads_candidate_set_coverage'
     )),
  pg_catalog.pg_get_functiondef(
    'otlet.guard_candidate_set_coverage_promotion()'::regprocedure
  ) LIKE '%source,candidate_query%source,max_candidate_rows%task,decision_contract%task,output_schema%measure_candidate_set_coverage%current passing candidate-set coverage report%'
    AND pg_catalog.pg_get_functiondef(
      'otlet.guard_candidate_set_coverage_promotion()'::regprocedure
    ) NOT LIKE '%source,query_contract%',
  pg_catalog.pg_get_functiondef(
    'otlet.rollback_workload_revision(text,text,text)'::regprocedure
  ) LIKE '%workload_revision_operation%rollback%previous_workload_revision_hash = NULL%',
  otlet.candidate_set_coverage_rule_valid(built.rule),
  NOT otlet.candidate_set_coverage_rule_valid(
    jsonb_set(built.rule, '{source_path}', '[]'::jsonb)
  ),
  otlet.candidate_set_coverage_workload_eligible('{
    "source":{"kind":"pair"},
    "task":{
      "decision_contract":{
        "answer_field":"match",
        "action_types":["merge_candidate"]
      },
      "output_schema":{"properties":{"match":{"enum":["same_entity"]}}}
    }
  }'::jsonb)
    AND NOT otlet.candidate_set_coverage_workload_eligible('{
      "source":{"kind":"pair"},
      "task":{
        "decision_contract":{"answer_field":"match"},
        "output_schema":{"properties":{"match":{"enum":["same_entity"]}}}
      }
    }'::jsonb),
  NOT EXISTS (SELECT 1 FROM otlet.candidate_set_coverage_reports),
  NOT pg_catalog.has_table_privilege(
    'public',
    'otlet.candidate_set_coverage_reports',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.candidate_set_coverage_status', 'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname LIKE '%candidate_set%'
        AND pg_catalog.has_function_privilege(
          'public', function.oid, 'EXECUTE'
        )
    ),
  NOT pg_catalog.has_table_privilege(
    :'operator_role', 'otlet.candidate_set_coverage_reports', 'SELECT'
  )
    AND NOT pg_catalog.has_table_privilege(
      :'partial_auditor_role',
      'otlet.candidate_set_coverage_status',
      'SELECT'
  ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
) FROM built;
ROLLBACK;
SQL
)"
[ "$candidate_set_coverage_migration_contract" = \
  "t|t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable candidate-set-coverage migration contract mismatch: $candidate_set_coverage_migration_contract" >&2
  exit 1
}

entity_resolution_quality_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v operator_role="$operator_role" \
    -v partial_auditor_role="$partial_auditor_role" <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 65
      AND file LIKE '%0065_entity_resolution_quality.sql'
  ),
  to_regclass('otlet.entity_resolution_quality_status') IS NOT NULL,
  (
    SELECT count(*) = 23
      AND count(*) FILTER (WHERE column_name IN (
        'candidate_coverage_report_hash',
        'evaluation_report_hash',
        'review_economics_report_hash',
        'evaluation_labels_current',
        'metric',
        'eligible_count',
        'numerator',
        'denominator',
        'rate',
        'denominator_definition',
        'evidence_kind',
        'non_authoritative'
      )) = 12
    FROM information_schema.columns
    WHERE table_schema = 'otlet'
      AND table_name = 'entity_resolution_quality_status'
  ),
  pg_catalog.pg_get_viewdef(
    'otlet.entity_resolution_quality_status'::regclass,
    true
  ) LIKE '%decision_diff%answer_matches%'
    AND pg_catalog.pg_get_viewdef(
      'otlet.entity_resolution_quality_status'::regclass,
      true
    ) LIKE '%expected_answer%'
    AND pg_catalog.pg_get_viewdef(
      'otlet.entity_resolution_quality_status'::regclass,
      true
    ) NOT LIKE '%approval_diff%'
    AND position('reported_downstream_success' IN pg_catalog.pg_get_viewdef(
      'otlet.entity_resolution_quality_status'::regclass,
      true
    )) > 0
    AND position('expected_action_type' IN pg_catalog.pg_get_viewdef(
      'otlet.entity_resolution_quality_status'::regclass,
      true
    )) > 0
    AND position('merge_candidate' IN pg_catalog.pg_get_viewdef(
      'otlet.entity_resolution_quality_status'::regclass,
      true
    )) > 0
    AND pg_catalog.pg_get_functiondef(
      'otlet.validate_candidate_set_coverage_contract()'::regprocedure
    ) LIKE '%review_economics%',
  (SELECT count(*) = 0 FROM otlet.entity_resolution_quality_status),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.entity_resolution_quality_status', 'SELECT'
  ),
  NOT pg_catalog.has_table_privilege(
    :'operator_role', 'otlet.entity_resolution_quality_status', 'SELECT'
  )
    AND NOT pg_catalog.has_table_privilege(
      :'partial_auditor_role',
      'otlet.entity_resolution_quality_status',
      'SELECT'
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$entity_resolution_quality_migration_contract" = \
  "t|t|t|t|t|t|t|t" ] || {
  echo "Portable entity-resolution-quality migration contract mismatch: $entity_resolution_quality_migration_contract" >&2
  exit 1
}

pair_constraint_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v operator_role="$operator_role" \
    -v partial_auditor_role="$partial_auditor_role" <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 66
      AND file LIKE '%0066_pair_constraint_ledger.sql'
  ),
  to_regclass('otlet.pair_constraint_facts') IS NOT NULL,
  to_regclass('otlet.pair_constraint_status') IS NOT NULL,
  to_regprocedure('otlet.pair_constraint_contract_hash(jsonb)') IS NOT NULL,
  (
    SELECT count(*) = 4
    FROM (VALUES
      (
        'pair_constraint_facts_immutable',
        'otlet.pair_constraint_facts'::regclass,
        'otlet.reject_pair_constraint_fact_change()'::regprocedure::oid,
        27::smallint
      ),
      (
        'pair_constraint_facts_no_truncate',
        'otlet.pair_constraint_facts'::regclass,
        'otlet.reject_pair_constraint_fact_change()'::regprocedure::oid,
        34::smallint
      ),
      (
        'review_events_pair_constraint_fact',
        'otlet.review_events'::regclass,
        'otlet.record_pair_constraint_fact()'::regprocedure::oid,
        5::smallint
      ),
      (
        'semantic_materializations_pair_constraint',
        'otlet.semantic_materializations'::regclass,
        'otlet.guard_pair_constraint_materialization()'::regprocedure::oid,
        23::smallint
      )
    ) expected(trigger_name, relation_oid, function_oid, trigger_type)
    JOIN pg_catalog.pg_trigger trigger
      ON trigger.tgname = expected.trigger_name
     AND trigger.tgrelid = expected.relation_oid
     AND trigger.tgfoid = expected.function_oid
     AND trigger.tgtype = expected.trigger_type
     AND NOT trigger.tgisinternal
  ),
  EXISTS (
    SELECT 1
    FROM pg_catalog.pg_constraint constraint_row
    WHERE constraint_row.conrelid = 'otlet.semantic_materializations'::regclass
      AND constraint_row.conname =
        'semantic_materializations_stale_reason_check'
      AND pg_catalog.pg_get_constraintdef(constraint_row.oid)
        LIKE '%pair_constraint_conflict%'
  ),
  (SELECT count(*) = 0 FROM otlet.pair_constraint_facts),
  (SELECT count(*) = 0 FROM otlet.pair_constraint_status),
  NOT pg_catalog.has_table_privilege(
    'public',
    'otlet.pair_constraint_facts',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.pair_constraint_status', 'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname LIKE '%pair_constraint%'
        AND pg_catalog.has_function_privilege(
          'public', function.oid, 'EXECUTE'
        )
    ),
  NOT pg_catalog.has_table_privilege(
    :'operator_role', 'otlet.pair_constraint_facts', 'SELECT'
  )
    AND NOT pg_catalog.has_table_privilege(
      :'partial_auditor_role', 'otlet.pair_constraint_status', 'SELECT'
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$pair_constraint_migration_contract" = \
  "t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable pair-constraint migration contract mismatch: $pair_constraint_migration_contract" >&2
  exit 1
}

entity_graph_conflict_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v operator_role="$operator_role" \
    -v partial_auditor_role="$partial_auditor_role" <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 67
      AND file LIKE '%0067_entity_graph_conflict_status.sql'
  ),
  to_regclass('otlet.entity_graph_conflict_status') IS NOT NULL
    AND to_regclass(
      'otlet.review_queue_without_entity_graph_conflicts'
    ) IS NOT NULL,
  to_regprocedure('otlet.lock_entity_graph_task(text)') IS NOT NULL
    AND to_regprocedure(
      'otlet.entity_graph_conflict_status_for_task(text)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.require_entity_graph_clear(text,text)'
    ) IS NOT NULL
    AND to_regprocedure('otlet.export_eval_cases(integer)') IS NOT NULL
    AND to_regprocedure(
      'otlet.export_eval_cases_unchecked(integer)'
    ) IS NULL,
  (
    SELECT function.prosecdef
      AND function.provolatile = 'v'
      AND function.proconfig @>
        ARRAY['search_path=pg_catalog, otlet, pg_temp']
    FROM pg_catalog.pg_proc function
    WHERE function.oid =
      'otlet.entity_graph_conflict_status_for_task(text)'::regprocedure
  ),
  (
    SELECT function.oid = sentinel.export_function_oid
      AND function.proacl::text = sentinel.export_function_acl
      AND function.prosecdef
      AND function.proconfig @>
        ARRAY['search_path=pg_catalog, otlet, pg_temp']
      AND pg_catalog.has_function_privilege(
        :'operator_role', function.oid, 'EXECUTE'
      )
    FROM pg_catalog.pg_proc function
    CROSS JOIN public.portable_upgrade_sentinel sentinel
    WHERE function.oid = 'otlet.export_eval_cases(integer)'::regprocedure
      AND sentinel.id = 1
  ),
  (
    SELECT count(*) = 3
    FROM (VALUES
      (
        'pair_constraint_facts_entity_graph_lock',
        'otlet.pair_constraint_facts'::regclass,
        'otlet.lock_entity_graph_fact_write()'::regprocedure::oid,
        7::smallint
      ),
      (
        'actions_entity_graph_approval',
        'otlet.actions'::regclass,
        'otlet.guard_entity_graph_action_approval()'::regprocedure::oid,
        19::smallint
      ),
      (
        'workload_revision_heads_entity_graph',
        'otlet.workload_revision_heads'::regclass,
        'otlet.guard_entity_graph_promotion()'::regprocedure::oid,
        21::smallint
      )
    ) expected(trigger_name, relation_oid, function_oid, trigger_type)
    JOIN pg_catalog.pg_trigger trigger
      ON trigger.tgname = expected.trigger_name
     AND trigger.tgrelid = expected.relation_oid
     AND trigger.tgfoid = expected.function_oid
     AND trigger.tgtype = expected.trigger_type
     AND NOT trigger.tgisinternal
  ),
  (
    SELECT count(*) = 8
    FROM information_schema.columns column_row
    WHERE column_row.table_schema = 'otlet'
      AND column_row.table_name = 'audit_review_export'
      AND column_row.column_name IN (
        'entity_graph_conflict_hash',
        'entity_graph_conflict_status',
        'entity_graph_cannot_fact_hash',
        'entity_graph_left_id',
        'entity_graph_right_id',
        'entity_graph_review_event_id',
        'entity_graph_reviewer_identity',
        'entity_graph_reviewer_role'
      )
  ),
  EXISTS (
    SELECT 1
    FROM pg_catalog.pg_rewrite rewrite
    JOIN pg_catalog.pg_depend dependency
      ON dependency.classid = 'pg_rewrite'::regclass
     AND dependency.objid = rewrite.oid
    WHERE rewrite.ev_class =
        'otlet.review_queue_without_semantic_corrections'::regclass
      AND dependency.refobjid =
        'otlet.entity_graph_conflict_status'::regclass
  ) AND EXISTS (
    SELECT 1
    FROM pg_catalog.pg_rewrite rewrite
    JOIN pg_catalog.pg_depend dependency
      ON dependency.classid = 'pg_rewrite'::regclass
     AND dependency.objid = rewrite.oid
    WHERE rewrite.ev_class = 'otlet.audit_review_export'::regclass
      AND dependency.refobjid = 'otlet.review_queue'::regclass
  ),
  (SELECT count(*) = 0 FROM otlet.entity_graph_conflict_status)
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.review_queue
      WHERE queue_kind = 'entity_graph_conflict'
    ),
  NOT pg_catalog.has_table_privilege(
      'public', 'otlet.entity_graph_conflict_status', 'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.review_queue_without_entity_graph_conflicts',
      'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND (
          function.proname LIKE '%entity_graph%'
          OR function.proname = 'export_eval_cases'
        )
        AND pg_catalog.has_function_privilege(
          'public', function.oid, 'EXECUTE'
        )
    ),
  pg_catalog.has_table_privilege(
    :'operator_role', 'otlet.audit_review_export', 'SELECT'
  )
    AND pg_catalog.has_function_privilege(
      :'operator_role',
      'otlet.entity_graph_conflict_status_for_task(text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_table_privilege(
      :'operator_role', 'otlet.entity_graph_conflict_status', 'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      :'operator_role',
      'otlet.review_queue_without_entity_graph_conflicts',
      'SELECT'
    ),
  pg_catalog.has_table_privilege(
    :'partial_auditor_role', 'otlet.audit_review_export', 'SELECT'
  )
    AND NOT pg_catalog.has_table_privilege(
      :'partial_auditor_role', 'otlet.audit_receipt_export', 'SELECT'
    )
    AND NOT pg_catalog.has_function_privilege(
      :'partial_auditor_role',
      'otlet.entity_graph_conflict_status_for_task(text)',
      'EXECUTE'
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$entity_graph_conflict_migration_contract" = \
  "t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable entity-graph-conflict migration contract mismatch: $entity_graph_conflict_migration_contract" >&2
  exit 1
}

semantic_correction_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v operator_role="$operator_role" \
    -v partial_auditor_role="$partial_auditor_role" <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 68
      AND file LIKE '%0068_authoritative_semantic_correction.sql'
  ),
  to_regclass('otlet.semantic_correction_overrides') IS NOT NULL
    AND to_regclass('otlet.semantic_correction_status') IS NOT NULL
    AND to_regclass('otlet.semantic_materializations_effective') IS NOT NULL
    AND to_regclass('otlet.audit_semantic_correction_export') IS NOT NULL
    AND to_regclass(
      'otlet.review_queue_without_semantic_corrections'
    ) IS NOT NULL
    AND (
      SELECT position('extract(epoch' IN lower(function.prosrc)) > 0
      FROM pg_catalog.pg_proc function
      WHERE function.oid =
        'otlet.semantic_correction_override_hash(otlet.semantic_correction_overrides)'::regprocedure
    ),
  to_regprocedure(
    'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamptz,numeric,text,text)'
  ) IS NOT NULL
    AND to_regprocedure(
      'otlet.semantic_correction_status_for_task(text)'
    ) IS NOT NULL,
  (
    SELECT function.prosecdef
      AND function.provolatile = 'v'
      AND function.proconfig @>
        ARRAY['search_path=pg_catalog, otlet, pg_temp']
      AND position(
        'json_schema_validation_error' IN function.prosrc
      ) > 0
      AND position('require_entity_graph_clear' IN function.prosrc) > 0
      AND position('lock_eval_label_series' IN function.prosrc) > 0
      AND position('lock_eval_label_series' IN function.prosrc) <
        position('require_entity_graph_clear' IN function.prosrc)
    FROM pg_catalog.pg_proc function
    WHERE function.oid =
      'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamptz,numeric,text,text)'::regprocedure
  ),
  (
    SELECT count(*) = 2
    FROM (VALUES
      (
        'semantic_correction_overrides_change_guard',
        27::smallint
      ),
      (
        'semantic_correction_overrides_truncate_guard',
        34::smallint
      )
    ) expected(trigger_name, trigger_type)
    JOIN pg_catalog.pg_trigger trigger
      ON trigger.tgname = expected.trigger_name
     AND trigger.tgrelid =
       'otlet.semantic_correction_overrides'::regclass
     AND trigger.tgtype = expected.trigger_type
     AND trigger.tgfoid =
       'otlet.reject_semantic_correction_change()'::regprocedure::oid
     AND NOT trigger.tgisinternal
  ),
  (
    SELECT count(*) = 4
    FROM pg_catalog.pg_proc function
    WHERE function.oid = ANY(ARRAY[
      'otlet.semantic_index_current_rows(text,boolean,text)'::regprocedure::oid,
      'otlet.semantic_join_index_current_rows(text,boolean,text)'::regprocedure::oid,
      'otlet.semantic_join_matches(text,text,jsonb)'::regprocedure::oid,
      'otlet.semantic_matches(text,text,jsonb)'::regprocedure::oid
    ])
      AND position(
        'semantic_materializations_effective' IN function.prosrc
      ) > 0
  ) AND (
    SELECT position('semantic_materializations_effective' IN function.prosrc) > 0
    FROM pg_catalog.pg_proc function
    WHERE function.oid =
      'otlet.recompute_semantic_planner_statistics(text,text,bigint,text)'::regprocedure
  ) AND (
    SELECT position('semantic_row_exact_counts' IN function.prosrc) > 0
    FROM pg_catalog.pg_proc function
    WHERE function.oid =
      'otlet.semantic_index_plan(text,boolean,text)'::regprocedure
  ) AND (
    SELECT position('semantic_pair_exact_counts' IN function.prosrc) > 0
    FROM pg_catalog.pg_proc function
    WHERE function.oid =
      'otlet.semantic_join_index_plan(text,boolean,text)'::regprocedure
  ),
  EXISTS (
    SELECT 1
    FROM pg_catalog.pg_rewrite rewrite
    JOIN pg_catalog.pg_depend dependency
      ON dependency.classid = 'pg_rewrite'::regclass
     AND dependency.objid = rewrite.oid
    WHERE rewrite.ev_class =
        'otlet.review_queue_without_review_samples'::regclass
      AND dependency.refobjid =
        'otlet.semantic_correction_status'::regclass
  ) AND (
    SELECT position('reopened_pair_constraint' IN function.prosrc) > 0
      AND position('pair_constraint_facts' IN function.prosrc) > 0
    FROM pg_catalog.pg_proc function
    WHERE function.oid =
      'otlet.semantic_correction_status_for_task(text)'::regprocedure
  ),
  (
    SELECT relation.oid = sentinel.audit_review_oid
      AND relation.relacl::text = sentinel.audit_review_acl
    FROM pg_catalog.pg_class relation
    CROSS JOIN public.portable_upgrade_sentinel sentinel
    WHERE relation.oid = 'otlet.audit_review_export'::regclass
      AND sentinel.id = 1
  ),
  (
    SELECT count(*) = 11
    FROM information_schema.columns column_row
    WHERE column_row.table_schema = 'otlet'
      AND column_row.table_name = 'audit_review_export'
      AND column_row.column_name LIKE 'semantic_correction%'
        OR (
          column_row.table_schema = 'otlet'
          AND column_row.table_name = 'audit_review_export'
          AND column_row.column_name IN (
            'semantic_corrected_body_hash',
            'semantic_supersedes_correction_hash'
          )
        )
  ),
  NOT EXISTS (
    SELECT 1
    FROM information_schema.columns column_row
    WHERE column_row.table_schema = 'otlet'
      AND column_row.table_name = 'audit_semantic_correction_export'
      AND column_row.column_name = 'corrected_body'
  ),
  pg_catalog.has_table_privilege(
    :'operator_role',
    'otlet.audit_semantic_correction_export',
    'SELECT'
  )
    AND pg_catalog.has_function_privilege(
      :'operator_role',
      'otlet.semantic_correction_status_for_task(text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_function_privilege(
      :'operator_role',
      'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamptz,numeric,text,text)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_table_privilege(
      :'operator_role',
      'otlet.semantic_correction_overrides',
      'SELECT'
    ),
  NOT pg_catalog.has_table_privilege(
      :'partial_auditor_role',
      'otlet.audit_semantic_correction_export',
      'SELECT'
    )
    AND NOT pg_catalog.has_function_privilege(
      :'partial_auditor_role',
      'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamptz,numeric,text,text)',
      'EXECUTE'
    ),
  NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.semantic_correction_overrides',
      'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.semantic_materializations_effective',
      'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname LIKE '%semantic_correction%'
        AND pg_catalog.has_function_privilege(
          'public', function.oid, 'EXECUTE'
        )
    ),
  (
    SELECT operator_functions = 3
      AND operator_security_definer_functions = 3
      AND operator_fixed_search_path_functions = 3
      AND reviewer_functions = 8
      AND reviewer_security_definer_functions = 8
      AND reviewer_fixed_search_path_functions = 8
    FROM otlet.access_policy_status
  ),
  (SELECT count(*) = 0 FROM otlet.semantic_correction_overrides)
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.review_queue
      WHERE queue_kind = 'semantic_correction_re_review'
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$semantic_correction_migration_contract" = \
  "t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable semantic-correction migration contract mismatch: $semantic_correction_migration_contract" >&2
  exit 1
}

decision_evidence_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v operator_role="$operator_role" \
    -v partial_auditor_role="$partial_auditor_role" <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 69
      AND file LIKE '%0069_evidence_linked_decisions.sql'
  ),
  to_regprocedure(
    'otlet.decision_evidence_path_links(jsonb,jsonb,jsonb,text,integer)'
  ) IS NOT NULL
    AND to_regprocedure(
      'otlet.validated_decision_evidence(jsonb,jsonb,jsonb,jsonb,text)'
    ) IS NOT NULL,
  to_regclass('otlet.audit_decision_evidence_export') IS NOT NULL
    AND (
      SELECT policy_version = 6
        AND export_views @>
          ARRAY['otlet.audit_decision_evidence_export']::text[]
      FROM otlet.redaction_policy_status
    ),
  pg_catalog.has_table_privilege(
    :'operator_role',
    'otlet.audit_decision_evidence_export',
    'SELECT'
  )
    AND NOT pg_catalog.has_function_privilege(
      :'operator_role',
      'otlet.validated_decision_evidence(jsonb,jsonb,jsonb,jsonb,text)',
      'EXECUTE'
    ),
  NOT pg_catalog.has_table_privilege(
    :'partial_auditor_role',
    'otlet.audit_decision_evidence_export',
    'SELECT'
  ),
  NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.audit_decision_evidence_export',
      'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname LIKE '%decision_evidence%'
        AND pg_catalog.has_function_privilege(
          'public', function.oid, 'EXECUTE'
        )
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$decision_evidence_migration_contract" = \
  "t|t|t|t|t|t|t" ] || {
  echo "Portable decision-evidence migration contract mismatch: $decision_evidence_migration_contract" >&2
  exit 1
}

review_sampling_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v operator_role="$operator_role" \
    -v partial_auditor_role="$partial_auditor_role" <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 70
      AND file LIKE '%0070_review_sampling.sql'
  ),
  to_regclass('otlet.review_samples') IS NOT NULL
    AND to_regclass('otlet.audit_review_sample_export') IS NOT NULL
    AND to_regprocedure(
      'otlet.review_sampling_rule_error(jsonb,jsonb,jsonb)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.record_review_sample(bigint,jsonb)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.label_review_sample(bigint,text,text,text,text,text)'
    ) IS NOT NULL,
  (
    SELECT policy_version = 6
      AND export_views @> ARRAY['otlet.audit_review_sample_export']::text[]
    FROM otlet.redaction_policy_status
  ),
  (
    SELECT operator_functions = 3
      AND operator_security_definer_functions = 3
      AND operator_fixed_search_path_functions = 3
      AND reviewer_functions = 8
      AND reviewer_security_definer_functions = 8
      AND reviewer_fixed_search_path_functions = 8
    FROM otlet.access_policy_status
  ),
  pg_catalog.has_table_privilege(
    :'operator_role',
    'otlet.audit_review_sample_export',
    'SELECT'
  )
    AND NOT pg_catalog.has_function_privilege(
      :'operator_role',
      'otlet.label_review_sample(bigint,text,text,text,text,text)',
      'EXECUTE'
    )
    AND pg_catalog.has_function_privilege(
      :'operator_role',
      'otlet.pair_constraint_contract_hash(jsonb)',
      'EXECUTE'
    )
    AND NOT pg_catalog.has_table_privilege(
      :'operator_role',
      'otlet.review_samples',
      'SELECT'
    ),
  NOT pg_catalog.has_table_privilege(
      :'partial_auditor_role',
      'otlet.audit_review_sample_export',
      'SELECT'
    )
    AND NOT pg_catalog.has_function_privilege(
      :'partial_auditor_role',
      'otlet.label_review_sample(bigint,text,text,text,text,text)',
      'EXECUTE'
    ),
  NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.review_samples',
      'SELECT'
    )
    AND NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.audit_review_sample_export',
      'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname LIKE '%review_sampl%'
        AND pg_catalog.has_function_privilege(
          'public', function.oid, 'EXECUTE'
        )
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$review_sampling_migration_contract" = \
  "t|t|t|t|t|t|t|t" ] || {
  echo "Portable review-sampling migration contract mismatch: $review_sampling_migration_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 \
  -v reviewer_role="$reviewer_role" \
  -v reviewer_login="$reviewer_login" <<'SQL' >/dev/null
CREATE ROLE :"reviewer_role" NOLOGIN;
CREATE ROLE :"reviewer_login" LOGIN INHERIT;
GRANT :"reviewer_role" TO :"reviewer_login";
SELECT otlet.grant_reviewer_access(:'reviewer_role'::regrole);
SQL

reviewer_calibration_migration_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v operator_role="$operator_role" \
    -v reviewer_role="$reviewer_role" \
    -v reviewer_login="$reviewer_login" \
    -v partial_auditor_role="$partial_auditor_role" <<'SQL'
SELECT concat_ws('|',
  EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 71
      AND file LIKE '%0071_reviewer_rubric_calibration.sql'
  ),
  to_regclass('otlet.reviewer_calibrations') IS NOT NULL
    AND to_regclass('otlet.reviewer_calibration_responses') IS NOT NULL
    AND to_regclass('otlet.reviewer_review_errors') IS NOT NULL
    AND to_regclass('otlet.reviewer_review_queue') IS NOT NULL
    AND to_regclass('otlet.reviewer_calibration_queue') IS NOT NULL
    AND to_regclass('otlet.reviewer_calibration_status') IS NOT NULL
    AND to_regclass('otlet.audit_reviewer_calibration_export') IS NOT NULL,
  to_regprocedure('otlet.reviewer_rubric_error(jsonb)') IS NOT NULL
    AND to_regprocedure('otlet.reviewer_rubric_hash(jsonb)') IS NOT NULL
    AND to_regprocedure(
      'otlet.register_reviewer_calibration(text,regrole,text,text[],text)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.submit_reviewer_calibration(text,text,text,text,text)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.reviewer_authority(text,text,oid)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.reviewer_review_queue_rows()'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.record_reviewer_error(bigint,text)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.validate_review_event_reviewer_calibration()'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.lock_review_action_task(bigint)'
    ) IS NOT NULL
    AND to_regprocedure(
      'otlet.reviewer_correct_action(bigint,jsonb,text)'
    ) IS NOT NULL
    AND to_regprocedure('otlet.grant_reviewer_access(regrole)') IS NOT NULL,
  (
    SELECT count(*) = 2
    FROM information_schema.columns
    WHERE table_schema = 'otlet'
      AND table_name = 'review_events'
      AND column_name IN (
        'reviewer_rubric_hash',
        'reviewer_calibration_hash'
      )
  ),
  (
    SELECT policy_version = 6
      AND export_views @>
        ARRAY['otlet.audit_reviewer_calibration_export']::text[]
    FROM otlet.redaction_policy_status
  ) AND (
    SELECT operator_functions = 3
      AND operator_security_definer_functions = 3
      AND operator_fixed_search_path_functions = 3
      AND reviewer_functions = 8
      AND reviewer_security_definer_functions = 8
      AND reviewer_fixed_search_path_functions = 8
    FROM otlet.access_policy_status
  ),
  pg_catalog.has_table_privilege(
      :'operator_role',
      'otlet.audit_reviewer_calibration_export',
      'SELECT'
    )
    AND pg_catalog.has_function_privilege(
      :'operator_role',
      'otlet.reviewer_calibration_state(text)',
      'EXECUTE'
    )
    AND (
      SELECT bool_and(pg_catalog.has_function_privilege(
        :'operator_role', function_oid, 'EXECUTE'
      ))
      FROM unnest(ARRAY[
        'otlet.dry_run_action(bigint)'::regprocedure::oid,
        'otlet.apply_action(bigint)'::regprocedure::oid,
        'otlet.application_retry_job(bigint,text)'::regprocedure::oid
      ]) function_oid
    )
    AND (
      SELECT bool_and(NOT pg_catalog.has_function_privilege(
        :'operator_role', function_oid, 'EXECUTE'
      ))
      FROM unnest(ARRAY[
        'otlet.approve_action(bigint,text)'::regprocedure::oid,
        'otlet.reject_action(bigint,text,text)'::regprocedure::oid,
        'otlet.label_action(bigint,text,text,text,text,text)'::regprocedure::oid,
        'otlet.correct_action(bigint,jsonb,text)'::regprocedure::oid,
        'otlet.reviewer_correct_action(bigint,jsonb,text)'::regprocedure::oid,
        'otlet.defer_action(bigint,text)'::regprocedure::oid,
        'otlet.abstain_review(bigint,text)'::regprocedure::oid,
        'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamptz,numeric,text,text)'::regprocedure::oid,
        'otlet.label_review_sample(bigint,text,text,text,text,text)'::regprocedure::oid,
        'otlet.submit_reviewer_calibration(text,text,text,text,text)'::regprocedure::oid,
        'otlet.record_reviewer_error(bigint,text)'::regprocedure::oid
      ]) function_oid
    ),
  pg_catalog.pg_has_role(:'reviewer_login', :'reviewer_role', 'MEMBER')
    AND (
      SELECT bool_and(pg_catalog.has_table_privilege(
        :'reviewer_role', relation_name, 'SELECT'
      ))
      FROM unnest(ARRAY[
        'otlet.reviewer_review_queue',
        'otlet.reviewer_calibration_queue',
        'otlet.reviewer_calibration_status'
      ]) relation_name
    )
    AND (
      SELECT bool_and(pg_catalog.has_function_privilege(
        :'reviewer_role', function_oid, 'EXECUTE'
      ))
      FROM unnest(ARRAY[
        'otlet.approve_action(bigint,text)'::regprocedure::oid,
        'otlet.reject_action(bigint,text,text)'::regprocedure::oid,
        'otlet.reviewer_correct_action(bigint,jsonb,text)'::regprocedure::oid,
        'otlet.defer_action(bigint,text)'::regprocedure::oid,
        'otlet.abstain_review(bigint,text)'::regprocedure::oid,
        'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamptz,numeric,text,text)'::regprocedure::oid,
        'otlet.label_review_sample(bigint,text,text,text,text,text)'::regprocedure::oid,
        'otlet.submit_reviewer_calibration(text,text,text,text,text)'::regprocedure::oid,
        'otlet.reviewer_calibration_state(text)'::regprocedure::oid,
        'otlet.reviewer_calibration_member_token(text,text)'::regprocedure::oid,
        'otlet.reviewer_review_queue_rows()'::regprocedure::oid
      ]) function_oid
    ),
  (
    SELECT bool_and(NOT pg_catalog.has_table_privilege(
      :'reviewer_role', relation_name, 'SELECT'
    ))
    FROM unnest(ARRAY[
      'otlet.evaluation_cases',
      'otlet.eval_labels',
      'otlet.review_samples',
      'otlet.reviewer_calibrations',
      'otlet.reviewer_calibration_responses',
      'otlet.reviewer_review_errors',
      'otlet.audit_review_export',
      'otlet.audit_reviewer_calibration_export'
    ]) relation_name
  ) AND (
    SELECT bool_and(NOT pg_catalog.has_function_privilege(
      :'reviewer_role', function_oid, 'EXECUTE'
    ))
    FROM unnest(ARRAY[
      'otlet.label_action(bigint,text,text,text,text,text)'::regprocedure::oid,
      'otlet.dry_run_action(bigint)'::regprocedure::oid,
      'otlet.apply_action(bigint)'::regprocedure::oid,
      'otlet.application_retry_job(bigint,text)'::regprocedure::oid,
      'otlet.record_reviewer_error(bigint,text)'::regprocedure::oid,
      'otlet.lock_review_action_task(bigint)'::regprocedure::oid,
      'otlet.correct_action(bigint,jsonb,text)'::regprocedure::oid
    ]) function_oid
  ),
  NOT pg_catalog.has_table_privilege(
      :'partial_auditor_role',
      'otlet.audit_reviewer_calibration_export',
      'SELECT'
    )
    AND NOT pg_catalog.has_function_privilege(
      :'partial_auditor_role',
      'otlet.reviewer_calibration_state(text)',
      'EXECUTE'
    ),
  (
    SELECT bool_and(NOT pg_catalog.has_table_privilege(
      'public', relation_name, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
    ))
    FROM unnest(ARRAY[
      'otlet.reviewer_calibrations',
      'otlet.reviewer_calibration_responses',
      'otlet.reviewer_review_errors',
      'otlet.reviewer_review_queue',
      'otlet.reviewer_calibration_queue',
      'otlet.reviewer_calibration_status',
      'otlet.audit_reviewer_calibration_export'
    ]) relation_name
  ) AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND (
        function.proname LIKE '%reviewer_calibration%'
        OR function.proname LIKE 'reviewer_rubric%'
        OR function.proname = 'reviewer_authority'
        OR function.proname = 'reviewer_review_queue_rows'
        OR function.proname IN (
          'record_reviewer_error',
          'validate_reviewer_review_error',
          'validate_review_event_reviewer_calibration',
          'lock_review_action_task',
          'reviewer_correct_action'
        )
      )
      AND pg_catalog.has_function_privilege(
        'public', function.oid, 'EXECUTE'
      )
  ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$reviewer_calibration_migration_contract" = \
  "t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable reviewer-calibration migration contract mismatch: $reviewer_calibration_migration_contract" >&2
  exit 1
}

portable_reviewer_calibration_contract="$(
  (
    log() { :; }
    psql_exec() {
      docker exec -i "$container" psql -U postgres -d "$database" \
        -X -v ON_ERROR_STOP=1 "$@"
    }
    source "$(dirname "$0")/demo/reviewer_rubric_calibration.sh"
  ) | awk 'NF { line = $0 } END { print line }'
)"
[ "$portable_reviewer_calibration_contract" = \
  "t|rubric_changed|rubric_changed|rubric_changed|calibrated|4|8" ] || {
  echo "Portable reviewer-calibration contract mismatch: $portable_reviewer_calibration_contract" >&2
  exit 1
}

portable_review_sampling_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v operator_role="$operator_role" <<'SQL'
CREATE TEMP TABLE review_sampling_upgrade_proof (
  case_hash text,
  run_hash text,
  invalid_rule_blocked boolean NOT NULL DEFAULT false,
  redacted_class_blocked boolean NOT NULL DEFAULT false,
  append_blocked boolean NOT NULL DEFAULT false,
  cleanup_preserved boolean NOT NULL DEFAULT false
);
INSERT INTO review_sampling_upgrade_proof DEFAULT VALUES;

UPDATE review_sampling_upgrade_proof
SET redacted_class_blocked = otlet.review_sampling_rule_error(
      '{
        "format":"otlet.review_sampling.v1",
        "decision_class_rates":{"same_entity":1}
      }'::jsonb,
      '{
        "type":"object",
        "properties":{"decision":{"enum":["same_entity"]}}
      }'::jsonb,
      '{
        "answer_field":"decision",
        "redact_output_fields":["decision"]
      }'::jsonb
    ) = 'review_sampling decision classes cannot use a redacted answer field';

SELECT otlet.create_task(
  task_name => 'review_sampling_upgrade',
  input_query => NULL,
  instruction => 'Return one review decision',
  output_schema => '{
    "type":"object",
    "required":["decision","confidence"],
    "additionalProperties":false,
    "properties":{
      "decision":{
        "type":"string",
        "enum":["same_entity","different_entity","other"]
      },
      "confidence":{
        "type":"string",
        "enum":["high","medium","low"]
      }
    }
  }'::jsonb,
  model_name => 'model_concurrency_probe',
  input_shaping => '{"source_fields":["value"]}'::jsonb,
  decision_contract => '{
    "answer_field":"decision",
    "confidence_field":"confidence",
    "abstain_values":[],
    "action_types":["note"]
  }'::jsonb
) \g /dev/null

SELECT otlet.ensure_active_workload_revision('review_sampling_upgrade')
  AS review_sampling_revision_hash \gset

WITH thresholds AS (
  SELECT jsonb_object_agg(
    category,
    jsonb_build_object(
      'metric', category,
      'statistic', 'rate',
      'operator', 'lte',
      'value', 1,
      'unit', 'ratio',
      'minimum_support', 1,
      'required', true
    )
  ) AS definition
  FROM unnest(ARRAY[
    'candidate_recall',
    'false_trust',
    'abstention',
    'review_age',
    'review_minutes',
    'freshness',
    'latency',
    'database_impact',
    'unit_cost',
    'recovery',
    'downstream_outcome'
  ]) category
)
SELECT otlet.register_workload_acceptance_contract(
  'review_sampling_upgrade',
  :'review_sampling_revision_hash',
  :'review_sampling_revision_hash',
  '{
    "mode":"sample",
    "rule":{
      "kind":"stable_hash",
      "basis":"subject_id",
      "rate":1,
      "review_sampling":{
        "format":"otlet.review_sampling.v1",
        "task_rate":1,
        "decision_class_rates":{
          "same_entity":1,
          "different_entity":0
        },
        "action_free_rate":1
      }
    }
  }'::jsonb,
  clock_timestamp() + interval '100 milliseconds',
  clock_timestamp() + interval '1 day',
  '{"name":"active_revision","definition":{"kind":"workload_revision"}}',
  thresholds.definition
) AS review_sampling_contract_hash
FROM thresholds
\gset

DO $body$
DECLARE
  thresholds jsonb;
  revision_hash text;
  contract_hash text;
BEGIN
  SELECT
    contract.definition -> 'thresholds',
    contract.candidate_workload_revision_hash,
    contract.contract_hash
  INTO thresholds, revision_hash, contract_hash
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.task_name = 'review_sampling_upgrade'
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_contracts successor
      WHERE successor.task_name = contract.task_name
        AND successor.supersedes_contract_hash = contract.contract_hash
    );
  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'review_sampling_upgrade',
      revision_hash,
      revision_hash,
      '{
        "mode":"sample",
        "rule":{
          "kind":"stable_hash",
          "basis":"subject_id",
          "rate":1,
          "review_sampling":{
            "format":"otlet.review_sampling.v1",
            "task_rate":2
          }
        }
      }'::jsonb,
      clock_timestamp() + interval '1 hour',
      clock_timestamp() + interval '1 day',
      '{"name":"active_revision","definition":{"kind":"workload_revision"}}',
      thresholds,
      contract_hash
    );
  EXCEPTION WHEN OTHERS THEN
    UPDATE review_sampling_upgrade_proof
    SET invalid_rule_blocked = SQLERRM LIKE '%task_rate must be between 0 and 1%';
  END;
END
$body$;

SELECT pg_sleep(0.12) \g /dev/null

DO $body$
DECLARE
  revision_hash text := (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'review_sampling_upgrade'
  );
  fixture record;
  output jsonb;
  raw_output text;
  job_id bigint;
BEGIN
  FOR fixture IN
    SELECT *
    FROM (VALUES
      ('action-free', 'different_entity', '[]'::jsonb),
      (
        'class',
        'same_entity',
        '[{"type":"note","body":{"subject_id":"class","text":"review"}}]'::jsonb
      ),
      (
        'task',
        'other',
        '[{"type":"note","body":{"subject_id":"task","text":"review"}}]'::jsonb
      ),
      (
        'excluded',
        'different_entity',
        '[{"type":"note","body":{"subject_id":"excluded","text":"review"}}]'::jsonb
      )
    ) item(subject_id, decision_class, actions)
  LOOP
    INSERT INTO otlet.jobs (
      task_name,
      workload_revision_hash,
      subject_id,
      input,
      status,
      attempts,
      started_at,
      leased_until,
      claim_token
    ) VALUES (
      'review_sampling_upgrade',
      revision_hash,
      fixture.subject_id,
      jsonb_build_object('value', fixture.subject_id),
      'running',
      1,
      clock_timestamp(),
      clock_timestamp() + interval '5 minutes',
      'review-sampling-upgrade-' || fixture.subject_id
    ) RETURNING id INTO job_id;
    output := jsonb_build_object(
      'decision', fixture.decision_class,
      'confidence', 'high'
    );
    raw_output := jsonb_build_object(
      'output', output,
      'actions', fixture.actions
    )::text;
    PERFORM *
    FROM otlet.complete_job(
      job_id => job_id,
      output => output,
      raw_output => raw_output,
      actions => fixture.actions,
      raw_output_hash => otlet.portable_text_hash(raw_output),
      trace_summary => '{"schema_validation_status":"passed"}',
      model_name => 'model_concurrency_probe',
      expected_claim_token =>
        'review-sampling-upgrade-' || fixture.subject_id
    );
  END LOOP;
END
$body$;

SELECT count(*)
FROM otlet.complete_job(
  job_id => (
    SELECT id
    FROM otlet.jobs
    WHERE task_name = 'review_sampling_upgrade'
      AND subject_id = 'action-free'
  ),
  output => '{"decision":"different_entity","confidence":"high"}',
  raw_output => jsonb_build_object(
    'output',
    '{"decision":"different_entity","confidence":"high"}'::jsonb,
    'actions',
    '[]'::jsonb
  )::text,
  actions => '[]',
  raw_output_hash => otlet.portable_text_hash(
    jsonb_build_object(
      'output',
      '{"decision":"different_entity","confidence":"high"}'::jsonb,
      'actions',
      '[]'::jsonb
    )::text
  ),
  trace_summary => '{"schema_validation_status":"passed"}',
  model_name => 'model_concurrency_probe',
  expected_claim_token => 'review-sampling-upgrade-action-free'
) \g /dev/null

SELECT count(*)
FROM otlet.label_review_sample(
  (
    SELECT receipt_id
    FROM otlet.audit_review_sample_export
    WHERE task_name = 'review_sampling_upgrade'
      AND action_free
  ),
  'different_entity',
  'high',
  'none',
  'approve',
  'Confirmed action-free sample'
) \g /dev/null

SELECT otlet.cleanup_eval_label_series(
  clock_timestamp() + interval '1 second',
  false
) \g /dev/null

UPDATE review_sampling_upgrade_proof
SET cleanup_preserved = (
      SELECT count(*) = 1
      FROM otlet.eval_labels label
      JOIN otlet.review_samples sample ON sample.receipt_id = label.receipt_id
      WHERE sample.task_name = 'review_sampling_upgrade'
        AND sample.action_free
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.review_queue queue
      JOIN otlet.review_samples sample
        ON sample.receipt_id = queue.receipt_id
      WHERE sample.task_name = 'review_sampling_upgrade'
        AND sample.action_free
    );

UPDATE review_sampling_upgrade_proof
SET case_hash = otlet.register_evaluation_case(
  (
    SELECT label.id
    FROM otlet.eval_labels label
    JOIN otlet.review_samples sample ON sample.receipt_id = label.receipt_id
    WHERE sample.task_name = 'review_sampling_upgrade'
      AND sample.action_free
  ),
  'tuning',
  'Explicit sampled outcome case'
);

UPDATE review_sampling_upgrade_proof
SET run_hash = otlet.start_replay_evaluation(
  :'review_sampling_contract_hash',
  ARRAY[case_hash],
  'review-sampling-upgrade-action-free-v1',
  'Replay the explicit action-free sample'
);

UPDATE otlet.jobs job
SET status = 'running',
    attempts = 1,
    started_at = clock_timestamp(),
    leased_until = clock_timestamp() + interval '5 minutes',
    claim_token = gen_random_uuid()::text
FROM otlet.evaluation_executions execution
JOIN review_sampling_upgrade_proof proof
  ON proof.run_hash = execution.run_hash
WHERE execution.job_id = job.id;

DO $body$
DECLARE
  execution record;
  output jsonb := '{"decision":"different_entity","confidence":"high"}'::jsonb;
  raw_output text;
BEGIN
  raw_output := jsonb_build_object('output', output, 'actions', '[]'::jsonb)::text;
  FOR execution IN
    SELECT job.id, job.started_at, job.claim_token
    FROM otlet.evaluation_executions evaluated
    JOIN otlet.jobs job ON job.id = evaluated.job_id
    JOIN review_sampling_upgrade_proof proof
      ON proof.run_hash = evaluated.run_hash
    ORDER BY evaluated.variant
  LOOP
    PERFORM otlet.complete_job(
      job_id => execution.id,
      output => output,
      raw_output => raw_output,
      actions => '[]'::jsonb,
      raw_output_hash => otlet.portable_text_hash(raw_output),
      started_at => execution.started_at,
      trace_summary => '{"schema_validation_status":"passed","generate_ms":1}',
      model_name => 'model_concurrency_probe',
      expected_claim_token => execution.claim_token
    );
  END LOOP;
END
$body$;

DO $body$
BEGIN
  BEGIN
    UPDATE otlet.review_samples
    SET sample_rate = sample_rate
    WHERE task_name = 'review_sampling_upgrade';
  EXCEPTION WHEN OTHERS THEN
    UPDATE review_sampling_upgrade_proof
    SET append_blocked = SQLERRM = 'otlet review samples are append only';
  END;
END
$body$;

SELECT concat_ws('|',
  (
    SELECT count(*) = 3
      AND count(*) FILTER (WHERE sampling_scope = 'task') = 1
      AND count(*) FILTER (WHERE sampling_scope = 'decision_class') = 1
      AND count(*) FILTER (WHERE sampling_scope = 'action_free') = 1
      AND count(*) FILTER (
        WHERE job.subject_id = 'excluded'
      ) = 0
    FROM otlet.review_samples sample
    JOIN otlet.jobs job ON job.id = sample.job_id
    WHERE sample.task_name = 'review_sampling_upgrade'
  ),
  (
    SELECT count(*) = 2
      AND bool_and(queue_kind = 'sampled_output')
    FROM otlet.review_queue
    WHERE task_name = 'review_sampling_upgrade'
  ),
  (
    SELECT count(*) = 3
      AND count(*) FILTER (WHERE label_id IS NOT NULL) = 1
      AND count(*) FILTER (
        WHERE evaluation_population = 'tuning'
      ) = 1
    FROM otlet.audit_review_sample_export
    WHERE task_name = 'review_sampling_upgrade'
  ),
  (
    SELECT count(*) = 1
      AND bool_and(label.action_id IS NULL)
      AND bool_and(label.expected_action_type = 'none')
      AND bool_and(label.adjudication_state = 'pending')
    FROM otlet.eval_labels label
    JOIN otlet.review_samples sample ON sample.receipt_id = label.receipt_id
    WHERE sample.task_name = 'review_sampling_upgrade'
  ),
  (
    SELECT count(*) = 1
      AND bool_and(outcome = 'approve')
      AND bool_and(action_id IS NULL)
    FROM otlet.review_events event
    WHERE event.task_name = 'review_sampling_upgrade'
  ),
  (
    SELECT count(*) = 1
      AND bool_and(population_kind = 'tuning')
    FROM otlet.evaluation_cases evaluation_case
    WHERE evaluation_case.task_name = 'review_sampling_upgrade'
  )
    AND (SELECT count(*) = 1
         FROM otlet.evaluation_runs run
         JOIN review_sampling_upgrade_proof proof
           ON proof.run_hash = run.run_hash)
    AND (SELECT count(*) = 2
         FROM otlet.evaluation_results result
         JOIN review_sampling_upgrade_proof proof
           ON proof.run_hash = result.run_hash
         WHERE (result.approval_diff ->> 'expected_action_present')::boolean
           AND (result.approval_diff ->> 'matches_expected')::boolean
           AND result.approval_diff -> 'proposed_action_types' = '[]'::jsonb
           AND result.approval_diff -> 'valid_action_types' = '[]'::jsonb)
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_events event
      WHERE event.contract_hash = :'review_sampling_contract_hash'
        AND event.event_kind = 'promotion_decision'
  ),
  (
    SELECT count(*) = 1
    FROM otlet.jobs job
    WHERE job.task_name = 'review_sampling_upgrade'
      AND job.subject_id = 'action-free'
      AND (SELECT count(*) FROM otlet.inference_receipts receipt
           WHERE receipt.job_id = job.id) = 1
      AND (SELECT count(*) FROM otlet.outputs output
           WHERE output.job_id = job.id) = 1
      AND (SELECT count(*) FROM otlet.review_samples sample
           WHERE sample.job_id = job.id) = 1
  ),
  (
    SELECT invalid_rule_blocked
      AND redacted_class_blocked
      AND append_blocked
      AND cleanup_preserved
    FROM review_sampling_upgrade_proof
  ),
  (
    SELECT count(*) = 1
      AND bool_and(contract_hash = :'review_sampling_contract_hash')
    FROM otlet.workload_acceptance_contracts
    WHERE task_name = 'review_sampling_upgrade'
  ),
  (
    SELECT active_workload_revision_hash = :'review_sampling_revision_hash'
    FROM otlet.workload_revision_heads
    WHERE task_name = 'review_sampling_upgrade'
  ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$portable_review_sampling_contract" = \
  "t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable review-sampling contract mismatch: $portable_review_sampling_contract" >&2
  exit 1
}

identity_vector_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  otlet.identity_hash(
    'test_vector',
    '{"b":2.00,"a":[1.0,"é"]}'::jsonb
  ) = 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_hash(
    'test_vector',
    '{"a":[1.00,"é"],"b":2}'::jsonb
  ) = 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_hash(
    'other_vector',
    '{"b":2.00,"a":[1.0,"é"]}'::jsonb
  ) <> 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_text_hash(
    'text_vector',
    E'Otlet\n🙂'
  ) = 'otlet:v1:sha256:96077dacfe042898c24b4f06ed6d91b8d21e13a52d36738fe1009032d0d13f72'
);
SQL
)"
[ "$identity_vector_contract" = "t|t|t|t" ] || {
  echo "Portable identity vector contract mismatch: $identity_vector_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
SELECT count(*)
FROM otlet.complete_job(
  (
    SELECT id
    FROM otlet.jobs
    WHERE task_name = 'decision_evidence_legacy'
  ),
  '{"business_evidence":"legacy-business-field"}'::jsonb,
  '{"output":{"business_evidence":"legacy-business-field"},"actions":[]}',
  '[]'::jsonb,
  expected_claim_token => 'decision-evidence-legacy-token'
);

SELECT otlet.register_model(
  'decision_evidence_upgrade_model',
  '/tmp/decision_evidence_upgrade_model.gguf',
  repeat('2', 64),
  jsonb_build_object(
    'sha256', repeat('2', 64),
    'bytes', 1,
    'source', 'portable-upgrade-demo',
    'revision', 'decision-evidence-v1',
    'quantization', 'test',
    'license', 'test'
  )
);
SELECT otlet.create_task(
  task_name => 'decision_evidence_upgrade',
  input_query => NULL,
  instruction => 'Return a decision with source paths',
  output_schema => '{
    "type":"object",
    "required":["decision","evidence"],
    "additionalProperties":false,
    "properties":{
      "decision":{"type":"string"},
      "evidence":{
        "type":"array",
        "items":{
          "type":"array",
          "minItems":1,
          "maxItems":16,
          "items":{"type":"string"}
        }
      }
    }
  }'::jsonb,
  model_name => 'decision_evidence_upgrade_model',
  input_shaping => '{"source_fields":["approved"]}'::jsonb,
  decision_contract => '{"action_types":["review_flag"]}'::jsonb
);
INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  started_at,
  leased_until,
  claim_token
) VALUES (
  'decision_evidence_upgrade',
  'portable-upgrade',
  '{
    "approved":{
      "aliases":[{"value":"PORTABLE-CANARY-A"},{"value":"PORTABLE-CANARY-B"}]
    }
  }'::jsonb,
  'running',
  1,
  now(),
  now() + interval '5 minutes',
  'decision-evidence-upgrade-token'
) RETURNING id \gset decision_evidence_upgrade_
SELECT count(*)
FROM otlet.complete_job(
  :decision_evidence_upgrade_id,
  '{
    "decision":"review",
    "evidence":[["approved","aliases","0","value"]]
  }'::jsonb,
  '{
    "output":{
      "decision":"review",
      "evidence":[["approved","aliases","0","value"]]
    },
    "actions":[{
      "type":"review_flag",
      "body":{
        "reason":"review aliases",
        "evidence":[["approved","aliases","1","value"]]
      }
    }]
  }',
  '[{
    "type":"review_flag",
    "body":{
      "reason":"review aliases",
      "evidence":[["approved","aliases","1","value"]]
    }
  }]'::jsonb,
  expected_claim_token => 'decision-evidence-upgrade-token'
);
SQL

portable_decision_evidence_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  (SELECT job.status = 'complete'
          AND output.output ->> 'business_evidence' = 'legacy-business-field'
          AND (
            receipt.trace_summary #> '{portable_validation}'
          ) ? 'decision_evidence'
          AND receipt.trace_summary #>
            '{portable_validation,decision_evidence}' = '[]'::jsonb
          AND (
            receipt.trace_summary #> '{portable_validation}'
          ) ? 'decision_evidence_version'
          AND (
            revision.definition #> '{validator}'
          ) ? 'decision_evidence_version'
   FROM otlet.jobs job
   JOIN otlet.inference_receipts receipt ON receipt.job_id = job.id
   JOIN otlet.outputs output ON output.job_id = job.id
   JOIN otlet.workload_revisions revision
     ON revision.task_name = job.task_name
    AND revision.workload_revision_hash = job.workload_revision_hash
   WHERE job.task_name = 'decision_evidence_legacy'),
  (SELECT status = 'complete'
          AND (SELECT count(*) FROM otlet.inference_receipts receipt
               WHERE receipt.job_id = job.id) = 1
          AND (SELECT count(*) FROM otlet.outputs output
               WHERE output.job_id = job.id) = 1
          AND (SELECT count(*) FROM otlet.actions action
               WHERE action.job_id = job.id) = 1
   FROM otlet.jobs job
   WHERE task_name = 'decision_evidence_upgrade'),
  (SELECT count(*) = 2
          AND count(*) FILTER (WHERE target_kind = 'output') = 1
          AND count(*) FILTER (WHERE target_kind = 'action') = 1
          AND bool_and(action_id IS NOT NULL OR target_kind = 'output')
   FROM otlet.audit_decision_evidence_export
   WHERE task_name = 'decision_evidence_upgrade'),
  (SELECT receipt.trace_summary #>>
            '{portable_validation,decision_evidence_version}' =
          revision.definition #>> '{validator,decision_evidence_version}'
          AND revision.definition #>>
            '{validator,decision_evidence_version}' =
            'otlet_decision_evidence_v1'
   FROM otlet.inference_receipts receipt
   JOIN otlet.workload_revisions revision
     ON revision.task_name = receipt.task_name
    AND revision.workload_revision_hash = receipt.workload_revision_hash
   WHERE receipt.task_name = 'decision_evidence_upgrade'),
  (SELECT receipt.trace_summary::text NOT LIKE '%PORTABLE-CANARY%'
          AND NOT EXISTS (
            SELECT 1
            FROM otlet.audit_decision_evidence_export export
            WHERE export.task_name = receipt.task_name
              AND to_jsonb(export)::text LIKE '%PORTABLE-CANARY%'
          )
   FROM otlet.inference_receipts receipt
   WHERE receipt.task_name = 'decision_evidence_upgrade'),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
);
SQL
)"
[ "$portable_decision_evidence_contract" = \
  "t|t|t|t|t|t" ] || {
  echo "Portable decision-evidence contract mismatch: $portable_decision_evidence_contract" >&2
  exit 1
}

portable_ask_administrative_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SET LOCAL otlet.administrative_reason = '';
SET LOCAL otlet.administrative_ticket = '';
SELECT otlet.enqueue_ask(
  'model_concurrency_probe',
  'Return an empty object',
  '{"value":1}'::jsonb
) AS job_id \gset
SELECT concat_ws('|',
  :'job_id'::bigint > 0,
  current_setting('otlet.administrative_suppress', true) IS DISTINCT FROM 'on',
  NOT EXISTS (
    SELECT 1
    FROM otlet.administrative_change_events event
    JOIN otlet.jobs job ON job.task_name = event.object_name
    WHERE job.id = :'job_id'::bigint
      AND event.object_type = 'task'
  )
);
ROLLBACK;
SQL
)"
[ "$portable_ask_administrative_contract" = "t|t|t" ] || {
  echo "Portable queued ask administrative contract mismatch: $portable_ask_administrative_contract" >&2
  exit 1
}

portable_task_lifecycle_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL' | tail -n 1
BEGIN;
CREATE TEMP TABLE lifecycle_probe (
  revision_hash text NOT NULL,
  admission_rejected boolean NOT NULL DEFAULT false,
  transition_guarded boolean NOT NULL DEFAULT false,
  identity_change_guarded boolean NOT NULL DEFAULT false,
  unfinished_guarded boolean NOT NULL DEFAULT false
);
INSERT INTO lifecycle_probe (revision_hash)
VALUES (otlet.ensure_active_workload_revision('model_concurrency_probe'));
SELECT otlet.create_watch(
  watch_name => 'portable_lifecycle_identity_probe',
  kind => 'pair',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => 'model_concurrency_probe',
  candidate_query => 'SELECT ''one''::text AS subject_id, ''{}''::jsonb AS input',
  max_candidate_rows => 1
) \g /dev/null
DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.create_watch(
      watch_name => 'portable_lifecycle_identity_probe',
      kind => 'pair',
      instruction => 'Return an empty object',
      output_schema => '{"type":"object"}'::jsonb,
      model_name => 'model_concurrency_probe',
      candidate_query => 'SELECT ''two''::text AS subject_id, ''{}''::jsonb AS input',
      max_candidate_rows => 1
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('requires retirement and pinned deletion' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE lifecycle_probe SET identity_change_guarded = true;
    RETURN;
  END;
  RAISE EXCEPTION 'watch identity change unexpectedly succeeded';
END
$proof$;
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('model_concurrency_probe', 'lifecycle-queued', '{"value":0}'::jsonb);
SELECT otlet.set_task_lifecycle(
  'model_concurrency_probe',
  'paused',
  (SELECT revision_hash FROM lifecycle_probe)
) \g /dev/null
DO $proof$
BEGIN
  BEGIN
    UPDATE otlet.tasks
    SET lifecycle_state = 'retired'
    WHERE name = 'model_concurrency_probe';
  EXCEPTION WHEN OTHERS THEN
    IF position('require set_task_lifecycle' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE lifecycle_probe SET transition_guarded = true;
    RETURN;
  END;
  RAISE EXCEPTION 'direct lifecycle transition unexpectedly succeeded';
END
$proof$;
DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.set_task_lifecycle(
      'model_concurrency_probe',
      'retired',
      (SELECT revision_hash FROM lifecycle_probe)
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('unfinished jobs' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE lifecycle_probe SET unfinished_guarded = true;
    RETURN;
  END;
  RAISE EXCEPTION 'unfinished task retirement unexpectedly succeeded';
END
$proof$;
DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.admit_task_input(
      'model_concurrency_probe',
      'lifecycle-blocked',
      '{"value":1}'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('is paused' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE lifecycle_probe SET admission_rejected = true;
    RETURN;
  END;
  RAISE EXCEPTION 'paused lifecycle admission unexpectedly succeeded';
END
$proof$;
CREATE TEMP TABLE lifecycle_paused_claims AS
SELECT id FROM otlet.claim_jobs('model_concurrency_probe', 1);
SELECT otlet.set_task_lifecycle(
  'model_concurrency_probe',
  'active',
  (SELECT revision_hash FROM lifecycle_probe)
) \g /dev/null
CREATE TEMP TABLE lifecycle_resumed_claim AS
SELECT id, claim_token FROM otlet.claim_jobs('model_concurrency_probe', 1);
SELECT *
FROM otlet.cancel_job(
  (SELECT id FROM lifecycle_resumed_claim),
  (SELECT claim_token FROM lifecycle_resumed_claim),
  'portable lifecycle proof'
) \g /dev/null
SELECT otlet.set_task_lifecycle(
  'model_concurrency_probe',
  'paused',
  (SELECT revision_hash FROM lifecycle_probe)
) \g /dev/null
SELECT otlet.set_task_lifecycle(
  'model_concurrency_probe',
  'retired',
  (SELECT revision_hash FROM lifecycle_probe)
) \g /dev/null
SELECT concat_ws('|',
  (SELECT lifecycle_state = 'retired'
          AND pinned_workload_revision_hash = (SELECT revision_hash FROM lifecycle_probe)
   FROM otlet.task_lifecycle_status
   WHERE task_name = 'model_concurrency_probe'),
  (SELECT admission_rejected FROM lifecycle_probe),
  (SELECT transition_guarded FROM lifecycle_probe),
  (SELECT identity_change_guarded FROM lifecycle_probe),
  (SELECT unfinished_guarded FROM lifecycle_probe),
  (SELECT count(*) = 0 FROM lifecycle_paused_claims),
  (SELECT count(*) = 1 FROM lifecycle_resumed_claim),
  (SELECT count(*) = 0 FROM otlet.workload_revision_heads
   WHERE task_name = 'model_concurrency_probe'),
  (SELECT count(*) = 1 FROM otlet.workload_revisions
   WHERE task_name = 'model_concurrency_probe'),
  (SELECT count(*) = 1 AND bool_and(status = 'canceled') FROM otlet.jobs
   WHERE task_name = 'model_concurrency_probe'),
  (SELECT count(*) = 0 FROM otlet.verify_invariants())
);
ROLLBACK;
SQL
)"
[ "$portable_task_lifecycle_contract" = "t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Portable task lifecycle contract mismatch: $portable_task_lifecycle_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
WITH revision AS (
  SELECT otlet.ensure_active_workload_revision('model_concurrency_probe') AS revision_hash
)
INSERT INTO otlet.jobs (task_name, workload_revision_hash, subject_id, input)
SELECT
  'model_concurrency_probe',
  revision_hash,
  'subject-' || subject_number,
  jsonb_build_object('value', subject_number)
FROM revision
CROSS JOIN generate_series(1, 6) AS subject_number;
SQL

batch_claims="$(claim_probe_jobs 8)"
batch_capacity_contract="$(model_capacity_contract)"
[ "$batch_claims|$batch_capacity_contract" = "3|3|3|0|3|0|0|3|0" ] || {
  echo "Portable batch model capacity contract mismatch: $batch_claims|$batch_capacity_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
UPDATE otlet.jobs
SET status = 'queued',
    attempts = 0,
    leased_until = NULL,
    claim_token = NULL,
    started_at = NULL
WHERE task_name = 'model_concurrency_probe';
SQL

docker exec "$container" psql -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -c "BEGIN; SELECT pg_advisory_xact_lock(hashtext('otlet_queue_admission')); SELECT pg_sleep(2); COMMIT" \
  >/dev/null &
capacity_lock_pid=$!
sleep 1
claim_pids=()
for _ in 1 2; do
  claim_probe_jobs 8 >/dev/null &
  claim_pids+=("$!")
done
wait "$capacity_lock_pid"
for claim_pid in "${claim_pids[@]}"; do
  wait "$claim_pid"
done

concurrent_capacity_contract="$(model_capacity_contract)"
[ "$concurrent_capacity_contract" = "3|3|0|3|0|0|3|0" ] || {
  echo "Portable concurrent model capacity contract mismatch: $concurrent_capacity_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
UPDATE otlet.jobs
SET status = 'cancel_requested',
    cancel_requested_at = now(),
    error = 'cancellation requested'
WHERE id = (
  SELECT id
  FROM otlet.jobs
  WHERE task_name = 'model_concurrency_probe'
    AND status = 'running'
  ORDER BY id
  LIMIT 1
);
SQL

cancel_blocked_claims="$(claim_probe_jobs 8)"
[ "$cancel_blocked_claims" = "0" ] || {
  echo "Live cancellation released model capacity: $cancel_blocked_claims" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second',
    attempts = (SELECT max_attempts FROM otlet.production_policy WHERE name = 'default')
WHERE task_name = 'model_concurrency_probe'
  AND status = 'cancel_requested';
SQL

replacement_claims="$(claim_probe_jobs 8)"
lease_capacity_contract="$(model_capacity_contract)"
[ "$replacement_claims|$lease_capacity_contract" = "1|3|3|0|3|1|1|2|0" ] || {
  echo "Portable lease model capacity contract mismatch: $replacement_claims|$lease_capacity_contract" >&2
  exit 1
}

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
DELETE FROM otlet.jobs WHERE task_name = 'model_concurrency_probe';
SELECT otlet.register_model(
  model.name,
  model.artifact_path,
  model.artifact_hash,
  model.artifact_identity,
  1
)
FROM otlet.models model
WHERE model.name = 'model_concurrency_probe';
WITH revision AS (
  SELECT otlet.ensure_active_workload_revision('model_concurrency_probe') AS revision_hash
), inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    status,
    attempts,
    leased_until,
    claim_token,
    started_at
  )
  SELECT
    'model_concurrency_probe',
    revision_hash,
    'renewed',
    '{"value":1}'::jsonb,
    'running',
    (SELECT max_attempts FROM otlet.production_policy WHERE name = 'default'),
    clock_timestamp() + interval '2 seconds',
    'renewal-owner',
    clock_timestamp()
  FROM revision
  RETURNING workload_revision_hash
)
INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input
)
SELECT
  'model_concurrency_probe',
  workload_revision_hash,
  'replacement',
  '{"value":2}'::jsonb
FROM inserted;
SQL

docker exec "$container" psql -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -c "BEGIN; SELECT id FROM otlet.jobs WHERE task_name = 'model_concurrency_probe' AND subject_id = 'renewed' FOR UPDATE; SELECT pg_sleep(5); COMMIT" \
  >/dev/null &
renewal_row_lock_pid=$!
sleep 0.5
docker exec "$container" psql -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -c "SELECT count(*) FROM otlet.renew_job_lease((SELECT id FROM otlet.jobs WHERE task_name = 'model_concurrency_probe' AND subject_id = 'renewed'), 'renewal-owner')" \
  >/dev/null &
renewal_pid=$!
sleep 3
renewal_race_claims="$(claim_probe_jobs 8)"
wait "$renewal_row_lock_pid"
wait "$renewal_pid"

renewal_race_contract="$renewal_race_claims|$(model_capacity_contract)"
[ "$renewal_race_contract" = "1|1|1|0|2|0|1|0|0" ] || {
  echo "Portable renewal race contract mismatch: $renewal_race_contract" >&2
  exit 1
}

echo "portable_upgrade_contract=$contract"
echo "portable_identity_vector_contract=$identity_vector_contract"
echo "portable_application_migration_contract=$application_migration_contract"
echo "portable_lifecycle_migration_contract=$lifecycle_migration_contract"
echo "portable_administrative_migration_contract=$administrative_migration_contract"
echo "portable_acceptance_migration_contract=$acceptance_migration_contract"
echo "portable_evaluation_migration_contract=$evaluation_migration_contract"
echo "portable_population_lineage_migration_contract=$population_lineage_migration_contract"
echo "portable_evaluation_slices_migration_contract=$evaluation_slices_migration_contract"
echo "portable_label_provenance_migration_contract=$label_provenance_migration_contract"
echo "portable_production_model_qualification_migration_contract=$production_model_qualification_migration_contract"
echo "portable_promotion_shadow_rollback_migration_contract=$promotion_shadow_rollback_migration_contract"
echo "portable_quality_data_drift_migration_contract=$quality_data_drift_migration_contract"
echo "portable_review_economics_migration_contract=$review_economics_migration_contract"
echo "portable_model_license_use_migration_contract=$model_license_use_migration_contract"
echo "portable_model_artifact_lifecycle_migration_contract=$model_artifact_lifecycle_migration_contract"
echo "portable_failure_retry_taxonomy_migration_contract=$failure_retry_taxonomy_migration_contract"
echo "portable_candidate_set_coverage_migration_contract=$candidate_set_coverage_migration_contract"
echo "portable_entity_resolution_quality_migration_contract=$entity_resolution_quality_migration_contract"
echo "portable_pair_constraint_migration_contract=$pair_constraint_migration_contract"
echo "portable_entity_graph_conflict_migration_contract=$entity_graph_conflict_migration_contract"
echo "portable_semantic_correction_migration_contract=$semantic_correction_migration_contract"
echo "portable_decision_evidence_migration_contract=$decision_evidence_migration_contract"
echo "portable_review_sampling_migration_contract=$review_sampling_migration_contract"
echo "portable_reviewer_calibration_migration_contract=$reviewer_calibration_migration_contract"
echo "portable_reviewer_calibration_contract=$portable_reviewer_calibration_contract"
echo "portable_review_sampling_contract=$portable_review_sampling_contract"
echo "portable_decision_evidence_contract=$portable_decision_evidence_contract"
echo "portable_ask_administrative_contract=$portable_ask_administrative_contract"
echo "portable_task_lifecycle_contract=$portable_task_lifecycle_contract"
echo "portable_$portable_workload_pack_promotion_contract"
echo "portable_$portable_job_origin_workload_budget_contract"
echo "portable_model_capacity_contract=$batch_claims|$batch_capacity_contract|$concurrent_capacity_contract|$cancel_blocked_claims|$replacement_claims|$lease_capacity_contract"
echo "portable_renewal_race_contract=$renewal_race_contract"
