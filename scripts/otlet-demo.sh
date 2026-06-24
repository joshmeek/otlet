#!/usr/bin/env bash
set -euo pipefail

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
runtime_name="${OTLET_RUNTIME_NAME:-linked_inproc}"
runtime_endpoint="${OTLET_RUNTIME_ENDPOINT:-linked}"
model_name="${OTLET_MODEL_NAME:-linked_qwen_0_6b}"
model_artifact="${OTLET_MODEL_ARTIFACT:-}"
row_task="${OTLET_ROW_TASK_NAME:-row_review_demo}"
entity_task="${OTLET_ENTITY_TASK_NAME:-entity_hypothesis_demo}"
index_name="${OTLET_DEMO_INDEX_NAME:-demo_semantic_vendor_idx}"
record_type="${OTLET_DEMO_RECORD_TYPE:-demo_semantic_fact}"
script_started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

require_container() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "Container $container is not running. Run ./scripts/otlet-setup.sh first" >&2
    exit 1
  fi
}

psql_exec() {
  docker exec -i "$container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

psql_value() {
  docker exec "$container" psql -U postgres -d postgres -qAt -v ON_ERROR_STOP=1 -c "$1"
}

require_contains() {
  local text="$1"
  local needle="$2"
  local message="$3"

  if [[ "$text" != *"$needle"* ]]; then
    echo "$message" >&2
    exit 1
  fi
}

require_regex() {
  local text="$1"
  local pattern="$2"
  local message="$3"

  if ! grep -Eq -- "$pattern" <<<"$text"; then
    echo "$message" >&2
    exit 1
  fi
}

reject_regex() {
  local text="$1"
  local pattern="$2"
  local message="$3"

  if grep -Eq -- "$pattern" <<<"$text"; then
    echo "$message" >&2
    exit 1
  fi
}

ensure_model_artifact() {
  local cached
  local model_dir="${OTLET_MODEL_DIR:-/var/lib/postgresql/otlet-models}"
  local model_file="${OTLET_MODEL_FILE:-Qwen3-0.6B-Q8_0.gguf}"
  local model_url="${OTLET_MODEL_URL:-https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf}"

  if [ -n "$model_artifact" ]; then
    return
  fi

  cached="$(
    docker exec "$container" sh -lc \
      "find /var/lib/postgresql/.cache/huggingface/hub/models--Qwen--Qwen3-0.6B-GGUF/snapshots '$model_dir' -name '$model_file' -print -quit 2>/dev/null"
  )"
  if [ -n "$cached" ]; then
    model_artifact="$cached"
    return
  fi

  docker exec "$container" sh -lc "mkdir -p '$model_dir' && curl -fL --retry 3 '$model_url' -o '$model_dir/$model_file'"
  model_artifact="$model_dir/$model_file"
}

register_runtime_model() {
  ensure_model_artifact
  psql_exec \
    -v runtime_name="$runtime_name" \
    -v runtime_endpoint="$runtime_endpoint" \
    -v model_name="$model_name" \
    -v model_artifact="$model_artifact" >/dev/null <<'SQL'
SET client_min_messages TO warning;
CREATE EXTENSION IF NOT EXISTS otlet;
SELECT otlet.register_runtime(:'runtime_name', :'runtime_endpoint');
SELECT otlet.register_model(:'model_name', :'model_artifact', :'runtime_name');
SQL
}

cleanup_task() {
  local task="$1"

  psql_exec -v task_name="$task" >/dev/null <<'SQL'
DELETE FROM otlet.worker_events e
USING otlet.jobs j
WHERE e.job_id = j.id
  AND j.task_name = :'task_name';
DELETE FROM otlet.inference_receipts r
USING otlet.jobs j
WHERE r.job_id = j.id
  AND j.task_name = :'task_name';
DELETE FROM otlet.semantic_materializations sm
USING otlet.records r, otlet.actions a, otlet.jobs j
WHERE sm.record_id = r.id
  AND r.action_id = a.id
  AND a.job_id = j.id
  AND j.task_name = :'task_name';
DELETE FROM otlet.records r
USING otlet.actions a, otlet.jobs j
WHERE r.action_id = a.id
  AND a.job_id = j.id
  AND j.task_name = :'task_name';
DELETE FROM otlet.actions a
USING otlet.jobs j
WHERE a.job_id = j.id
  AND j.task_name = :'task_name';
DELETE FROM otlet.outputs o
USING otlet.jobs j
WHERE o.job_id = j.id
  AND j.task_name = :'task_name';
DELETE FROM otlet.jobs WHERE task_name = :'task_name';
DELETE FROM otlet.tasks WHERE name = :'task_name';
SQL
}

wait_task_complete() {
  local task="$1"
  local expected_complete="${2:-1}"
  local attempts="${3:-300}"
  local delay="${4:-1}"
  local active complete failed

  for _ in $(seq 1 "$attempts"); do
    active="$(psql_value "SELECT count(*) FROM otlet.jobs WHERE task_name = '$task' AND status IN ('queued','running','cancel_requested');")"
    complete="$(psql_value "SELECT count(*) FROM otlet.jobs WHERE task_name = '$task' AND status = 'complete';")"
    failed="$(psql_value "SELECT count(*) FROM otlet.jobs WHERE task_name = '$task' AND status IN ('failed','canceled');")"
    if [ "$failed" != "0" ]; then
      psql_exec -P border=2 -P null='' -v task_name="$task" <<'SQL'
SELECT job_id, task_name, subject_id, status, error, raw_output
FROM otlet.runs
WHERE task_name = :'task_name'
ORDER BY job_id;
SQL
      return 1
    fi
    if [ "$complete" -ge "$expected_complete" ] && [ "$active" = "0" ]; then
      return 0
    fi
    sleep "$delay"
  done

  echo "Timed out waiting for task $task complete=$complete active=$active expected=$expected_complete" >&2
  return 1
}

crash_scan() {
  if docker logs --since "$script_started" "$container" 2>&1 | grep -Eiq 'segmentation|sigsegv|signal 11|core dump|panicked|assertion failed|server process .* was terminated'; then
    docker logs --since "$script_started" "$container" >&2
    exit 1
  fi
  echo "docker_crash_log_scan=ok"
}

require_container
register_runtime_model

log "Running linked row-review demo"
cleanup_task "$row_task"
psql_exec \
  -v model_name="$model_name" \
  -v task_name="$row_task" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_vendor_review;
CREATE TABLE public.otlet_demo_vendor_review (
  id bigserial PRIMARY KEY,
  name text NOT NULL,
  email text,
  phone text,
  city text NOT NULL
);

INSERT INTO public.otlet_demo_vendor_review (name, email, phone, city)
VALUES
  ('Northwind Supply', 'billing@northwind.example', '512-555-0100', 'Austin'),
  ('Bad Invoice LLC', 'billing@', NULL, 'Austin');

SELECT otlet.create_task(
  :'task_name',
  $$
    SELECT id::text AS subject_id, to_jsonb(otlet_demo_vendor_review)::jsonb AS input
    FROM public.otlet_demo_vendor_review
  $$,
  'This demo input row is invalid because email is exactly "billing@" and phone is null. Return exactly this JSON object: {"output":{"status":"needs_review","issues":["bad email","missing phone"],"needs_review":true},"actions":[]}',
  '{
    "type": "object",
    "required": ["status", "issues", "needs_review"],
    "additionalProperties": false,
    "properties": {
      "status": {"enum": ["needs_review"]},
      "issues": {"type": "array", "items": {"type": "string"}},
      "needs_review": {"type": "boolean"}
    }
  }'::jsonb,
  :'model_name',
  '{"temperature":0,"max_tokens":512}'::jsonb
);

SELECT (otlet.infer_async(
  :'task_name',
  '2',
  (
    SELECT to_jsonb(v)::jsonb
    FROM public.otlet_demo_vendor_review v
    WHERE id = 2
  )
)).id AS async_job_id;
SQL
wait_task_complete "$row_task" 1

row_contract="$(psql_value "
SELECT count(*)::text || '|' ||
       max(status) || '|' ||
       max(output->>'needs_review') || '|' ||
       count(*) FILTER (WHERE receipt_id IS NOT NULL)::text
FROM otlet.runs
WHERE task_name = '$row_task';
")"
echo "row_review_contract=$row_contract"
[ "$row_contract" = "1|complete|true|1" ] || {
  echo "Row review proof failed: $row_contract" >&2
  exit 1
}

log "Running action/record/provenance demo"
cleanup_task "$entity_task"
psql_exec \
  -v model_name="$model_name" \
  -v task_name="$entity_task" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_entity_vendor;
CREATE TABLE public.otlet_entity_vendor (
  id bigserial PRIMARY KEY,
  name text NOT NULL,
  phone text NOT NULL,
  city text NOT NULL
);

INSERT INTO public.otlet_entity_vendor (name, phone, city)
VALUES
  ('Acme Logistics LLC', '512-555-0100', 'Austin'),
  ('ACME Logistics', '512-555-0100', 'Austin');

SELECT otlet.create_task(
  :'task_name',
  $$
    SELECT
      v1.id::text || ':' || v2.id::text AS subject_id,
      jsonb_build_object(
        'table', 'public.otlet_entity_vendor',
        'vendor_a', to_jsonb(v1),
        'vendor_b', to_jsonb(v2)
      ) AS input
    FROM public.otlet_entity_vendor v1
    JOIN public.otlet_entity_vendor v2 ON v1.id < v2.id
  $$,
  'This demo pair is the same company: same normalized name, same phone, same city.
Return exactly this JSON object:
{"output":{"match":"yes","confidence":0.95,"reasons":["same normalized name","same phone","same city"],"needs_review":false},"actions":[{"type":"create_record","record_type":"entity_hypothesis","subject_id":"1:2","body":{"match":"yes","confidence":0.95,"reason":"same normalized name, phone, and city"}}]}',
  '{
    "type": "object",
    "required": ["match", "confidence", "reasons", "needs_review"],
    "additionalProperties": false,
    "properties": {
      "match": {"enum": ["yes", "no", "possible"]},
      "confidence": {"type": "number"},
      "reasons": {"type": "array", "items": {"type": "string"}},
      "needs_review": {"type": "boolean"}
    }
  }'::jsonb,
  :'model_name',
  '{"temperature":0}'::jsonb
);

SELECT otlet.run_task(:'task_name');
SQL
wait_task_complete "$entity_task" 1

entity_contract="$(psql_value "
SELECT
  (SELECT count(*) FROM otlet.outputs o JOIN otlet.jobs j ON j.id = o.job_id WHERE j.task_name = '$entity_task')::text || '|' ||
  (SELECT count(*) FROM otlet.actions a JOIN otlet.jobs j ON j.id = a.job_id WHERE j.task_name = '$entity_task' AND a.action_type = 'create_record')::text || '|' ||
  (SELECT count(*) FROM otlet.records r JOIN otlet.actions a ON a.id = r.action_id JOIN otlet.jobs j ON j.id = a.job_id WHERE j.task_name = '$entity_task' AND r.record_type = 'entity_hypothesis')::text || '|' ||
  (SELECT count(*) FROM otlet.inference_receipts r WHERE r.task_name = '$entity_task' AND r.status = 'complete')::text;
")"
echo "action_receipt_contract=$entity_contract"
[ "$entity_contract" = "1|1|1|1" ] || {
  echo "Action/receipt proof failed: $entity_contract" >&2
  exit 1
}

psql_exec -v task_name="$entity_task" >/dev/null <<'SQL'
SELECT otlet.refresh_semantic_materializations('entity_hypothesis');
SELECT otlet.watch_semantic_stale('public.otlet_entity_vendor'::regclass, 'id');
UPDATE public.otlet_entity_vendor SET city = 'Austin TX' WHERE id = 1;
SQL
stale_materializations="$(psql_value "SELECT count(*) FROM otlet.semantic_materializations WHERE task_name = '$entity_task' AND record_type = 'entity_hypothesis' AND stale;")"
echo "semantic_materialization_stale_rows=$stale_materializations"
[ "$stale_materializations" != "0" ] || {
  echo "Expected semantic materialization stale marking" >&2
  exit 1
}

log "Building semantic index and native paths"
psql_exec -v index_name="$index_name" >/dev/null <<'SQL'
SELECT otlet.drop_semantic_index(:'index_name');
SQL
index_task="${index_name}_task"
cleanup_task "$index_task"
psql_exec \
  -v model_name="$model_name" \
  -v index_name="$index_name" \
  -v record_type="$record_type" >/dev/null <<'SQL'
SET client_min_messages TO warning;
SELECT format('DROP VIEW IF EXISTS otlet.%I', otlet.semantic_source_view_name(:'index_name')) \gexec
SELECT format('DROP FOREIGN TABLE IF EXISTS otlet.%I', otlet.semantic_native_table_name(:'index_name')) \gexec
DROP TABLE IF EXISTS public.otlet_demo_semantic_vendor;
CREATE TABLE public.otlet_demo_semantic_vendor (
  id bigint PRIMARY KEY,
  name text NOT NULL,
  email text NOT NULL,
  phone text,
  city text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO public.otlet_demo_semantic_vendor (id, name, email, phone, city)
VALUES
  (1, 'Demo Vendor 1', 'billing1@example.test', '512-555-0001', 'Austin'),
  (2, 'Demo Vendor 2', 'billing@', '512-555-0002', 'Austin'),
  (3, 'Demo Vendor 3', 'billing3@example.test', NULL, 'Austin');

SELECT otlet.create_semantic_index(
  :'index_name',
  'public.otlet_demo_semantic_vendor'::regclass,
  'id',
  'Otlet demo semantic index. Return exactly this JSON object for every input row: {"output":{"status":"needs_review","needs_review":true,"issues":["demo semantic index"]},"actions":[{"type":"create_record","record_type":"' || :'record_type' || '","subject_id":"db-owned","body":{"status":"needs_review","needs_review":true,"semantic":"indexed row"}}]}',
  '{
    "type": "object",
    "required": ["status", "needs_review", "issues"],
    "additionalProperties": false,
    "properties": {
      "status": {"enum": ["needs_review"]},
      "needs_review": {"type": "boolean"},
      "issues": {"type": "array", "items": {"type": "string"}}
    }
  }'::jsonb,
  :'model_name',
  '{"temperature":0,"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":12,"generation_trace_top_k":3}'::jsonb,
  :'record_type'
);
SQL

queued="$(psql_value "SELECT otlet.refresh_semantic_index('$index_name');")"
echo "semantic_index_refresh_queued=$queued"
[ "$queued" = "3" ] || {
  echo "Expected 3 semantic index jobs, got $queued" >&2
  exit 1
}
wait_task_complete "$index_task" 3 1800 1
materialized="$(psql_value "SELECT otlet.materialize_semantic_index('$index_name');")"
echo "semantic_index_materialized=$materialized"
[ "$materialized" = "3" ] || {
  echo "Expected 3 materializations, got $materialized" >&2
  exit 1
}

native_table="$(psql_value "SELECT otlet.semantic_native_table_name('$index_name');")"
[[ "$native_table" =~ ^[a-z][a-z0-9_]*$ ]] || {
  echo "Unexpected native table identifier: $native_table" >&2
  exit 1
}

status_contract="$(psql_value "
SELECT selected_path || '|' ||
       default_native_foreign_table || '|' ||
       native_node || '|' ||
       planner_hook_status || '|' ||
       custom_path_status || '|' ||
       stale_result_policy || '|' ||
       worker_handoff
FROM otlet.model_access_status
WHERE index_name = '$index_name';
")"
echo "model_access_status_contract=$status_contract"
for term in \
  "semantic_lookup" \
  "otlet.$native_table" \
  "Foreign Scan via otlet_semantic_fdw" \
  "Custom Scan via set_rel_pathlist_hook" \
  "installed_semantic_matches" \
  "selected_for_semantic_matches" \
  "fail_closed_zero_subject_rows_until_worker_refresh_commits" \
  "shared_memory_xact_commit_latch"; do
  require_contains "$status_contract" "$term" "Expected model access status to contain $term"
done

fdw_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM otlet.$native_table
WHERE subject_id = '2';
SQL
)"
printf '%s\n' "$fdw_plan"
require_contains "$fdw_plan" "Foreign Scan on" "Expected FDW Foreign Scan"
require_contains "$fdw_plan" "Otlet Node: Semantic Foreign Scan" "Expected Otlet FDW explain details"

program_hash="$(psql_value "SELECT program_hash FROM otlet.compile_semantic_program('demo_vendor_needs_review', '$index_name', 'needs review');")"
action_program_hash="$(psql_value "SELECT program_hash FROM otlet.compile_semantic_action_program('demo_vendor_action_indexed', '$index_name', 'create_record', 'semantic is indexed row');")"
echo "semantic_program_hash=$program_hash"
echo "semantic_action_program_hash=$action_program_hash"

custom_scan_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM public.otlet_demo_semantic_vendor v
WHERE otlet.semantic_matches('$index_name', v.id::text, '{"status":"needs_review"}'::jsonb);

EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM public.otlet_demo_semantic_vendor v
WHERE otlet.semantic_matches_program('demo_vendor_needs_review', v.id::text);

EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM public.otlet_demo_semantic_vendor v
WHERE otlet.semantic_action_matches_program('demo_vendor_action_indexed', v.id::text);

SELECT
  (SELECT count(*) FROM public.otlet_demo_semantic_vendor v WHERE otlet.semantic_matches('$index_name', v.id::text, '{"status":"needs_review"}'::jsonb)) || ',' ||
  (SELECT count(*) FROM public.otlet_demo_semantic_vendor v WHERE otlet.semantic_matches_program('demo_vendor_needs_review', v.id::text)) || ',' ||
  (SELECT count(*) FROM public.otlet_demo_semantic_vendor v WHERE otlet.semantic_action_matches_program('demo_vendor_action_indexed', v.id::text)) AS custom_scan_rows;
SQL
)"
printf '%s\n' "$custom_scan_plan"
require_contains "$custom_scan_plan" "Custom Scan (Otlet Semantic Source CustomScan)" "Expected CustomScan plan"
require_contains "$custom_scan_plan" "Semantic Predicate Owner: otlet_customscan_executor" "Expected CustomScan predicate ownership"
require_contains "$custom_scan_plan" "Child Semantic Filter: stripped_before_child_plan" "Expected semantic filter stripped from child plan"
reject_regex "$custom_scan_plan" "Filter: .*semantic_matches|Filter: .*semantic_action_matches" "Semantic predicate leaked back into child SQL filter"
require_contains "$custom_scan_plan" "custom_scan_rows" "Expected CustomScan row proof"
require_contains "$custom_scan_plan" "3,3,3" "Expected all three semantic CustomScan predicates to match"

log "Checking stale fail-closed and bounded infer-now"
psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_demo_semantic_vendor
SET email = 'changed@example.test',
    updated_at = clock_timestamp()
WHERE id = 3;
SQL
stale_rows="$(psql_value "SELECT stale_rows FROM otlet.semantic_index_status WHERE name = '$index_name';")"
echo "semantic_index_stale_rows=$stale_rows"
[ "$stale_rows" != "0" ] || {
  echo "Expected stale semantic index row after source update" >&2
  exit 1
}
fail_closed_rows="$(psql_value "SELECT count(*) FROM public.otlet_demo_semantic_vendor v WHERE v.id = 3 AND otlet.semantic_matches('$index_name', v.id::text, '{\"status\":\"needs_review\"}'::jsonb, 1, false);")"
echo "stale_fail_closed_rows=$fail_closed_rows"
[ "$fail_closed_rows" = "0" ] || {
  echo "Expected stale row to fail closed before bounded infer-now" >&2
  exit 1
}

infer_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM public.otlet_demo_semantic_vendor v
WHERE otlet.semantic_matches_auto('$index_name', v.id::text, '{"status":"needs_review"}'::jsonb, 0, 15000, 1, false);
SQL
)"
printf '%s\n' "$infer_plan"
require_contains "$infer_plan" "Infer Now Batches: 1" "Expected bounded infer-now batch"
require_contains "$infer_plan" "Infer Now Input Path: tuple_slot_mvcc_json_no_spi" "Expected tuple-local infer-now input path"
require_contains "$infer_plan" "Infer Now Trace Version: otlet_generation_trace_v1" "Expected infer-now trace version"
require_regex "$infer_plan" "Infer Now Trace Receipt Id:[[:space:]]+[1-9][0-9]*" "Expected infer-now receipt trace id"

trace_contract="$(psql_value "
SELECT (receipt_id > 0)::text || '|' ||
       (prompt_tokens > 0)::text || '|' ||
       (generated_tokens >= 0)::text || '|' ||
       COALESCE(trace_version, '') || '|' ||
       COALESCE(probability_method, '') || '|' ||
       COALESCE(executor_origin, '') || '|' ||
       COALESCE(executor_node, '') || '|' ||
       COALESCE(semantic_index_name, '') || '|' ||
       COALESCE(stale_policy, '')
FROM otlet.inference_receipt_trace_status
WHERE task_name = '$index_task'
  AND subject_id = '3'
  AND status = 'complete'
ORDER BY receipt_id DESC
LIMIT 1;
")"
echo "trace_visibility_contract=$trace_contract"
for term in \
  "true|true|true|otlet_generation_trace_v1" \
  "customscan_infer_now" \
  "Otlet Semantic Source CustomScan" \
  "$index_name"; do
  require_contains "$trace_contract" "$term" "Expected trace visibility contract to contain $term"
done

visibility_status="$(psql_value "
SELECT (receipt_count > 0)::text || '|' ||
       (token_steps > 0)::text || '|' ||
       (top_k_alternatives > 0)::text || '|' ||
       (customscan_trace_receipts > 0)::text || '|' ||
       (max_detailed_trace_tokens > 0)::text || '|' ||
       (max_detailed_trace_top_k = 3)::text
FROM otlet.inference_visibility_status
LIMIT 1;
")"
echo "inference_visibility_status=$visibility_status"
require_contains "$visibility_status" "true|true|true|true|true|true" "Expected bounded token/top-k trace visibility counters"

runtime_contract="$(psql_value "
SELECT runtime_status || '|' ||
       slot_state || '|' ||
       COALESCE(tokens_per_second::text, '') || '|' ||
       (COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0))::text || '|' ||
       COALESCE(worker_memory_sample_policy, '')
FROM otlet.runtime_status
WHERE runtime_name = '$runtime_name'
  AND model_name = '$model_name'
LIMIT 1;
")"
echo "runtime_status_contract=$runtime_contract"
for term in \
  "ready|ready" \
  "|true|" \
  "linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run"; do
  require_contains "$runtime_contract" "$term" "Expected runtime status to contain $term"
done

crash_scan
log "Otlet demo passed"
