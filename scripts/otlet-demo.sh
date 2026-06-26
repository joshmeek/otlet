#!/usr/bin/env bash
set -euo pipefail

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
runtime_name="${OTLET_RUNTIME_NAME:-linked_inproc}"
runtime_endpoint="${OTLET_RUNTIME_ENDPOINT:-linked}"
cheap_model_name="${OTLET_CHEAP_MODEL_NAME:-linked_qwen_0_6b}"
strong_model_name="${OTLET_STRONG_MODEL_NAME:-linked_qwen_1_7b}"
cheap_model_artifact="${OTLET_CHEAP_MODEL_ARTIFACT:-}"
strong_model_artifact="${OTLET_STRONG_MODEL_ARTIFACT:-}"
entity_task="${OTLET_ENTITY_TASK_NAME:-entity_resolution_demo}"
join_index_name="${OTLET_ENTITY_JOIN_INDEX_NAME:-demo_entity_resolution_idx}"
join_task="${join_index_name}_task"
join_foreign_table="${OTLET_ENTITY_JOIN_FOREIGN_TABLE:-demo_entity_resolution_pairs}"
record_type="${OTLET_ENTITY_RECORD_TYPE:-entity_hypothesis}"
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

ensure_model_artifacts() {
  local cached
  local model_dir="${OTLET_MODEL_DIR:-/var/lib/postgresql/otlet-models}"
  local cheap_model_file="${OTLET_CHEAP_MODEL_FILE:-Qwen3-0.6B-Q8_0.gguf}"
  local cheap_model_url="${OTLET_CHEAP_MODEL_URL:-https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf}"
  local strong_model_file="${OTLET_STRONG_MODEL_FILE:-Qwen3-1.7B-Q8_0.gguf}"
  local strong_model_url="${OTLET_STRONG_MODEL_URL:-https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf}"

  if [ -z "$cheap_model_artifact" ]; then
    cached="$(
      docker exec "$container" sh -lc \
        "find /var/lib/postgresql/.cache/huggingface/hub/models--Qwen--Qwen3-0.6B-GGUF/snapshots '$model_dir' -name '$cheap_model_file' -print -quit 2>/dev/null"
    )"
    if [ -n "$cached" ]; then
      cheap_model_artifact="$cached"
    else
      docker exec "$container" sh -lc "mkdir -p '$model_dir' && curl -fL --retry 3 '$cheap_model_url' -o '$model_dir/$cheap_model_file'"
      cheap_model_artifact="$model_dir/$cheap_model_file"
    fi
  fi

  if [ -z "$strong_model_artifact" ]; then
    cached="$(
      docker exec "$container" sh -lc \
        "find /var/lib/postgresql/.cache/huggingface/hub/models--Qwen--Qwen3-1.7B-GGUF/snapshots '$model_dir' -name '$strong_model_file' -print -quit 2>/dev/null"
    )"
    if [ -n "$cached" ]; then
      strong_model_artifact="$cached"
    else
      docker exec "$container" sh -lc "mkdir -p '$model_dir' && curl -fL --retry 3 '$strong_model_url' -o '$model_dir/$strong_model_file'"
      strong_model_artifact="$model_dir/$strong_model_file"
    fi
  fi
}

register_runtime_models() {
  ensure_model_artifacts
  psql_exec \
    -v runtime_name="$runtime_name" \
    -v runtime_endpoint="$runtime_endpoint" \
    -v cheap_model_name="$cheap_model_name" \
    -v cheap_model_artifact="$cheap_model_artifact" \
    -v strong_model_name="$strong_model_name" \
    -v strong_model_artifact="$strong_model_artifact" >/dev/null <<'SQL'
SET client_min_messages TO warning;
CREATE EXTENSION IF NOT EXISTS otlet;
SELECT otlet.register_runtime(:'runtime_name', :'runtime_endpoint');
SELECT otlet.register_model(:'cheap_model_name', :'cheap_model_artifact', :'runtime_name');
SELECT otlet.register_model(:'strong_model_name', :'strong_model_artifact', :'runtime_name');
SQL
}

cleanup_task() {
  local task="$1"

  psql_exec -v task_name="$task" >/dev/null <<'SQL'
DELETE FROM otlet.worker_events e
USING otlet.jobs j
WHERE e.job_id = j.id
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
DELETE FROM otlet.inference_receipts r
USING otlet.jobs j
WHERE r.job_id = j.id
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
register_runtime_models

production_policy_contract="$(psql_value "
SELECT name || '|' || stale_policy || '|' || max_attempts::text || '|' || worker_claim_batch_size::text
FROM otlet.production_policy_status;
")"
echo "production_policy_contract=$production_policy_contract"
[ "$production_policy_contract" = "default|refresh_then_fail_closed|3|8" ] || {
  echo "Expected default production policy, got $production_policy_contract" >&2
  exit 1
}

production_status_contract="$(psql_value "
SELECT no_expired_running_jobs::text || '|' ||
       completed_jobs_are_schema_validated::text || '|' ||
       cache_within_bounds::text || '|' ||
       trace_within_bounds::text
FROM otlet.production_status;
")"
echo "production_status_contract=$production_status_contract"
[ "$production_status_contract" = "true|true|true|true" ] || {
  echo "Expected healthy production status, got $production_status_contract" >&2
  exit 1
}

psql_exec \
  -v old_index_name="demo_semantic_vendor_idx" \
  -v join_index_name="$join_index_name" \
  -v join_foreign_table="$join_foreign_table" >/dev/null <<'SQL'
SELECT otlet.drop_semantic_index(:'old_index_name');
SELECT otlet.drop_semantic_join_index(:'join_index_name');
SELECT format('DROP FOREIGN TABLE IF EXISTS otlet.%I', :'join_foreign_table') \gexec
SQL
cleanup_task "row_review_demo"
cleanup_task "entity_hypothesis_demo"
cleanup_task "$entity_task"
cleanup_task "$join_task"

model_queue_status_contract="$(psql_value "
SELECT queue_state || '|' || queued_jobs::text || '|' || running_jobs::text
FROM otlet.model_queue_status
WHERE model_name = '$cheap_model_name';
")"
echo "model_queue_status_contract=$model_queue_status_contract"
[ "$model_queue_status_contract" = "queue_accepting|0|0" ] || {
  echo "Expected empty accepting model queue, got $model_queue_status_contract" >&2
  exit 1
}

log "Running entity-resolution demo"
psql_exec >/dev/null <<'SQL'
DROP VIEW IF EXISTS public.otlet_demo_vendor_pair_input;
DROP TABLE IF EXISTS public.otlet_demo_vendor_pair;
DROP TABLE IF EXISTS public.otlet_demo_vendor_entity;
CREATE TABLE public.otlet_demo_vendor_entity (
  id text PRIMARY KEY,
  legal_name text NOT NULL,
  website text,
  address text,
  notes text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE public.otlet_demo_vendor_pair (
  pair_id text PRIMARY KEY,
  left_id text NOT NULL REFERENCES public.otlet_demo_vendor_entity(id),
  right_id text NOT NULL REFERENCES public.otlet_demo_vendor_entity(id)
);
INSERT INTO public.otlet_demo_vendor_entity (id, legal_name, website, address, notes)
VALUES
  ('vendor-1001', 'Northstar Logistics LLC', 'northstar-logistics.example', '41 W Lake St, Chicago, IL', 'legacy freight vendor from the 2021 import; AP contact ops@northstar-logistics.example'),
  ('vendor-42', 'N-Star Freight Services', 'nstar-freight.example', '41 West Lake Street, Suite 900, Chicago', 'same remittance account ending 8821; internal note says Northstar rebranded after acquisition'),
  ('vendor-77', 'Clearwater Medical Supplies', 'clearwatermed.example', '500 Hospital Way, Phoenix, AZ', 'hospital supply distributor; no shared tax id, domain, payment account, AP contact, remittance account, city, or industry with the freight vendor'),
  ('vendor-313', 'North Star Medical Logistics', 'northstarmedlog.example', '41 West Lake Street, Chicago, IL', 'medical logistics broker; same building and similar name, but different domain, payment account, AP contact, and no acquisition note'),
  ('vendor-314', 'Northstar Freight Canada Inc.', 'northstar-canada.example', '88 King St W, Toronto, ON', 'freight carrier with similar brand; different country, bank account, AP contact, and no shared remittance account in the ledger');
INSERT INTO public.otlet_demo_vendor_pair (pair_id, left_id, right_id)
VALUES
  ('vendor-1001:vendor-42', 'vendor-1001', 'vendor-42'),
  ('vendor-1001:vendor-77', 'vendor-1001', 'vendor-77'),
  ('vendor-1001:vendor-313', 'vendor-1001', 'vendor-313'),
  ('vendor-1001:vendor-314', 'vendor-1001', 'vendor-314');
CREATE VIEW public.otlet_demo_vendor_pair_input AS
SELECT
  p.pair_id AS subject_id,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_vendor_entity',
      'subject_id', p.pair_id,
      'left_id', p.left_id,
      'right_id', p.right_id,
      'left_ctid', l.ctid::text,
      'left_xmin', l.xmin::text,
      'right_ctid', r.ctid::text,
      'right_xmin', r.xmin::text
    ),
    'table', 'public.otlet_demo_vendor_entity',
    'pair_id', p.pair_id,
    'left_id', p.left_id,
    'right_id', p.right_id,
    'candidate_evidence',
    CASE p.pair_id
      WHEN 'vendor-1001:vendor-42' THEN jsonb_build_array(
        'same remittance account ending 8821',
        'internal note says Northstar rebranded after acquisition'
      )
      WHEN 'vendor-1001:vendor-77' THEN jsonb_build_array(
        'different industry and city',
        'no shared tax id, domain, payment account, AP contact, or remittance account'
      )
      WHEN 'vendor-1001:vendor-313' THEN jsonb_build_array(
        'same office building and similar North Star name',
        'medical logistics versus freight vendor',
        'different domain, payment account, AP contact, and no acquisition note',
        'weak signals conflict with important identifiers'
      )
      WHEN 'vendor-1001:vendor-314' THEN jsonb_build_array(
        'similar Northstar freight brand',
        'different country, bank account, AP contact, and no shared remittance account',
        'no acquisition or rebrand note connecting the records',
        'name similarity alone is not enough'
      )
      ELSE '[]'::jsonb
    END,
    'left_record', jsonb_build_object(
      'id', l.id,
      'legal_name', l.legal_name,
      'website', l.website,
      'address', l.address,
      'notes', l.notes
    ),
    'right_record', jsonb_build_object(
      'id', r.id,
      'legal_name', r.legal_name,
      'website', r.website,
      'address', r.address,
      'notes', r.notes
    )
  ) AS input
FROM public.otlet_demo_vendor_pair p
JOIN public.otlet_demo_vendor_entity l ON l.id = p.left_id
JOIN public.otlet_demo_vendor_entity r ON r.id = p.right_id;
SQL

psql_exec \
  -v cheap_model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" \
  -v task_name="$entity_task" \
  -v record_type="$record_type" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $$
    SELECT subject_id, input
    FROM public.otlet_demo_vendor_pair_input
    ORDER BY subject_id
  $$,
  'Use input.candidate_evidence as authority before names or notes. Shared means candidate_evidence says the identifier is shared by both records. Return only {"output":{"match":"same_entity|different_entity|unclear","confidence":"low|medium|high","reason":"short reason"},"actions":[]}. Return same_entity with high confidence when evidence contains shared remittance, rebrand, or acquisition. Return different_entity with high confidence when evidence says no shared identifiers or different industry and city. The word no means absence; a reason saying no shared identifiers must use match different_entity, not same_entity. Return unclear with medium confidence when evidence says weak signals conflict or name similarity alone is not enough. A same_entity reason must name the shared identifier that candidate_evidence says both records share. Do not add prose, markdown, labels, nested output, or action strings.',
  '{
    "type": "object",
    "required": ["match", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "match": {"enum": ["same_entity", "different_entity", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string"}
    },
    "allOf": [
      {
        "if": {"properties": {"match": {"const": "same_entity"}}, "required": ["match"]},
        "then": {"properties": {"reason": {"pattern": "remittance|rebrand|acquisition"}}}
      },
      {
        "if": {"properties": {"match": {"const": "different_entity"}}, "required": ["match"]},
        "then": {"properties": {"reason": {"pattern": "no shared|different"}}}
      }
    ]
  }'::jsonb,
  :'cheap_model_name',
  '{"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":16,"generation_trace_top_k":3}'::jsonb
);

SELECT otlet.set_model_selection_policy(:'task_name', :'cheap_model_name', :'strong_model_name');
SELECT otlet.run_task(:'task_name');
SQL
wait_task_complete "$entity_task" 4 1800 1

entity_contract="$(psql_value "
SELECT count(*) FILTER (WHERE r.status = 'complete')::text || '|' ||
       COALESCE(max(r.output->>'match') FILTER (WHERE r.subject_id = 'vendor-1001:vendor-42'), '') || '|' ||
       COALESCE(max(r.output->>'match') FILTER (WHERE r.subject_id = 'vendor-1001:vendor-77'), '') || '|' ||
       count(*) FILTER (WHERE r.receipt_id IS NOT NULL)::text || '|' ||
       count(*) FILTER (WHERE r.schema_validation_status = 'passed')::text
FROM otlet.runs r
WHERE r.task_name = '$entity_task';
")"
echo "entity_resolution_contract=$entity_contract"
[ "$entity_contract" = "4|same_entity|different_entity|4|4" ] || {
  echo "Entity-resolution proof failed: $entity_contract" >&2
  exit 1
}

model_selection_policy_contract="$(psql_value "
SELECT task_name || '|' || cheap_model_name || '|' || strong_model_name
FROM otlet.model_selection_policy_status
WHERE task_name = '$entity_task';
")"
echo "model_selection_policy_contract=$model_selection_policy_contract"
[ "$model_selection_policy_contract" = "$entity_task|$cheap_model_name|$strong_model_name" ] || {
  echo "Expected model selection policy contract, got $model_selection_policy_contract" >&2
  exit 1
}

model_selection_attempts="$(psql_value "
SELECT subject_id || '|' || attempt_index::text || '|' || selection_role || '|' ||
       selection_status || '|' || model_name || '|' ||
       COALESCE(output->>'confidence', '') || '|' || COALESCE(output->>'match', '')
FROM otlet.model_selection_attempts
WHERE task_name = '$entity_task'
ORDER BY subject_id, attempt_index;
")"
while IFS= read -r line; do
  [ -n "$line" ] && echo "model_selection_attempt_contract=$line"
done <<<"$model_selection_attempts"

model_selection_status_contract="$(psql_value "
SELECT (cheap_accepted >= 1)::text || '|' ||
       (strong_accepted >= 1)::text || '|' ||
       (escalated_jobs >= 1)::text || '|' ||
       cheap_attempts::text || '|' ||
       strong_attempts::text
FROM otlet.model_selection_status
WHERE task_name = '$entity_task';
")"
echo "model_selection_status_contract=$model_selection_status_contract"
require_regex "$model_selection_status_contract" '^true\|true\|true\|[0-9]+\|[1-9][0-9]*$' "Expected at least one cheap accepted and one strong accepted model-selection job"

accepted_output_anomalies="$(psql_value "
SELECT count(*)
FROM (
  SELECT job_id
  FROM otlet.outputs
  GROUP BY job_id
  HAVING count(*) <> 1
) bad;
")"
echo "accepted_output_anomalies=$accepted_output_anomalies"
[ "$accepted_output_anomalies" = "0" ] || {
  echo "Expected exactly one accepted output per completed job" >&2
  exit 1
}

log "Building semantic join entity-resolution path"
psql_exec \
  -v join_index_name="$join_index_name" \
  -v cheap_model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" \
  -v record_type="$record_type" >/dev/null <<'SQL'
SELECT name, task_name, record_type, max_candidate_rows
FROM otlet.create_semantic_join_index(
  :'join_index_name',
  $$
    SELECT subject_id, input
    FROM public.otlet_demo_vendor_pair_input
    ORDER BY subject_id
  $$,
  'Use input.candidate_evidence as authority before names or notes. Shared means candidate_evidence says the identifier is shared by both records. Return only {"output":{"match":"same_entity|different_entity|unclear","confidence":"low|medium|high","reason":"short reason"},"actions":[]}. Return same_entity with high confidence when evidence contains shared remittance, rebrand, or acquisition. Return different_entity with high confidence when evidence says no shared identifiers or different industry and city. The word no means absence; a reason saying no shared identifiers must use match different_entity, not same_entity. Return unclear with medium confidence when evidence says weak signals conflict or name similarity alone is not enough. A same_entity reason must name the shared identifier that candidate_evidence says both records share. Do not add prose, markdown, labels, nested output, or action strings.',
  '{
    "type": "object",
    "required": ["match", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "match": {"enum": ["same_entity", "different_entity", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string"}
    },
    "allOf": [
      {
        "if": {"properties": {"match": {"const": "same_entity"}}, "required": ["match"]},
        "then": {"properties": {"reason": {"pattern": "remittance|rebrand|acquisition"}}}
      },
      {
        "if": {"properties": {"match": {"const": "different_entity"}}, "required": ["match"]},
        "then": {"properties": {"reason": {"pattern": "no shared|different"}}}
      }
    ]
  }'::jsonb,
  :'cheap_model_name',
  :'record_type',
  '{"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":16,"generation_trace_top_k":3}'::jsonb,
  10
);
SELECT otlet.set_model_selection_policy(:'join_index_name' || '_task', :'cheap_model_name', :'strong_model_name');
SQL

queued="$(psql_value "SELECT otlet.refresh_semantic_join_index('$join_index_name');")"
echo "semantic_join_refresh_queued=$queued"
[ "$queued" = "4" ] || {
  echo "Expected 4 semantic join jobs, got $queued" >&2
  exit 1
}
wait_task_complete "$join_task" 4 1800 1
throughput_contracts="$(psql_value "
SELECT count(*) FILTER (WHERE a.action_type = 'create_record' AND a.status = 'complete')::text || '|' ||
       count(*) FILTER (WHERE r.record_type = '$record_type')::text
FROM otlet.jobs j
LEFT JOIN otlet.actions a ON a.job_id = j.id
LEFT JOIN otlet.records r ON r.action_id = a.id
WHERE j.task_name = '$join_task';

SELECT count(*)
FROM otlet.semantic_materializations
WHERE task_name = '$join_task'
  AND record_type = '$record_type'
  AND stale = false;

SELECT q.queue_state || '|' ||
       w.queued_jobs::text || '|' ||
       w.running_jobs::text || '|' ||
       w.last_batch_jobs::text || '|' ||
       w.last_batch_completed_jobs::text || '|' ||
       w.last_batch_failed_jobs::text
FROM otlet.worker_throughput_status w
JOIN otlet.model_queue_status q ON q.model_name = w.model_name
WHERE w.model_name = '$cheap_model_name';
")"
auto_records="$(sed -n '1p' <<<"$throughput_contracts")"
materialized="$(sed -n '2p' <<<"$throughput_contracts")"
throughput_status_contract="$(sed -n '3p' <<<"$throughput_contracts")"
echo "semantic_join_auto_records=$auto_records"
[ "$auto_records" = "4|4" ] || {
  echo "Expected 4 auto actions and records, got $auto_records" >&2
  exit 1
}

echo "semantic_join_auto_materialized=$materialized"
[ "$materialized" = "4" ] || {
  echo "Expected 4 automatic semantic join materializations, got $materialized" >&2
  exit 1
}

echo "throughput_status_contract=$throughput_status_contract"
[ "$throughput_status_contract" = "queue_accepting|0|0|4|4|0" ] || {
  echo "Expected throughput status contract queue_accepting|0|0|4|4|0, got $throughput_status_contract" >&2
  exit 1
}

join_status_contract="$(psql_value "
SELECT selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queue_subjects::text || '|' ||
       fail_closed_subjects::text
FROM otlet.semantic_join_index_plan('$join_index_name');
")"
echo "semantic_join_status_contract=$join_status_contract"
[ "$join_status_contract" = "semantic_join_lookup|4|4|0|0|0|0" ] || {
  echo "Expected fresh semantic join status, got $join_status_contract" >&2
  exit 1
}

join_lookup_contract="$(psql_value "
SELECT count(*)::text || '|' ||
       count(*) FILTER (WHERE body @> '{\"match\":\"same_entity\"}'::jsonb)::text || '|' ||
       count(*) FILTER (WHERE body @> '{\"match\":\"different_entity\"}'::jsonb)::text
FROM otlet.semantic_join_index_current_rows('$join_index_name', true);
")"
echo "semantic_join_lookup_contract=$join_lookup_contract"
require_regex "$join_lookup_contract" '^4\|[1-9][0-9]*\|[1-9][0-9]*$' "Expected semantic join lookup to include 4 rows, at least one same_entity, and at least one different_entity"

join_match_contract="$(psql_value "
SELECT otlet.semantic_join_matches('$join_index_name', 'vendor-1001:vendor-42', '{\"match\":\"same_entity\"}'::jsonb)::text || '|' ||
       otlet.semantic_join_matches('$join_index_name', 'vendor-1001:vendor-77', '{\"match\":\"different_entity\"}'::jsonb)::text;
")"
echo "semantic_join_match_contract=$join_match_contract"
[ "$join_match_contract" = "true|true" ] || {
  echo "Expected semantic join matches, got $join_match_contract" >&2
  exit 1
}

psql_exec \
  -v foreign_table="$join_foreign_table" \
  -v join_index_name="$join_index_name" >/dev/null <<'SQL'
SELECT format('DROP FOREIGN TABLE IF EXISTS otlet.%I', :'foreign_table') \gexec
SELECT otlet.create_semantic_join_foreign_table(:'foreign_table', :'join_index_name');
SQL
[[ "$join_foreign_table" =~ ^[a-z][a-z0-9_]*$ ]] || {
  echo "Unexpected join foreign table identifier: $join_foreign_table" >&2
  exit 1
}

fdw_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM otlet.$join_foreign_table
WHERE subject_id = 'vendor-1001:vendor-42';
SQL
)"
printf '%s\n' "$fdw_plan"
require_contains "$fdw_plan" "Foreign Scan on" "Expected semantic join FDW Foreign Scan"
require_contains "$fdw_plan" "Otlet Node: Semantic Foreign Scan" "Expected Otlet FDW explain details"
require_contains "$fdw_plan" "Selected Path: semantic_join_lookup" "Expected FDW selected path"
require_contains "$fdw_plan" "Queue Subjects: 0" "Expected FDW queue subject count"
require_contains "$fdw_plan" "Path Cost:" "Expected FDW path cost"

log "Checking stale entity-resolution state"
psql_exec >/dev/null <<'SQL'
SELECT otlet.watch_semantic_stale('public.otlet_demo_vendor_entity'::regclass, 'id');
UPDATE public.otlet_demo_vendor_entity
SET notes = notes || '; updated AP contact confirms remittance migration',
    updated_at = clock_timestamp()
WHERE id = 'vendor-1001';
SQL
join_stale_contract="$(psql_value "
SELECT stale_subjects::text || '|' || fresh_subjects::text
FROM otlet.semantic_join_index_plan('$join_index_name');
SELECT count(*)::text
FROM otlet.semantic_join_index_current_rows('$join_index_name', true);
")"
join_stale_subjects="$(head -n 1 <<<"$join_stale_contract")"
join_fresh_after_lookup="$(tail -n 1 <<<"$join_stale_contract")"
echo "semantic_join_stale_contract=$join_stale_subjects|fresh_after_lookup=$join_fresh_after_lookup"
[ "$join_stale_subjects|$join_fresh_after_lookup" = "4|0|0" ] || {
  echo "Expected semantic join stale contract 4|0|0, got $join_stale_subjects|$join_fresh_after_lookup" >&2
  exit 1
}

trace_contract="$(psql_value "
SELECT count(*) FILTER (WHERE receipt_id > 0)::text || '|' ||
       count(*) FILTER (WHERE prompt_tokens > 0)::text || '|' ||
       count(*) FILTER (WHERE generated_tokens >= 0)::text || '|' ||
       count(*) FILTER (WHERE schema_validation_status = 'passed')::text
FROM otlet.inference_receipt_trace_status
WHERE task_name IN ('$entity_task', '$join_task')
  AND status = 'complete';
")"
echo "receipt_trace_contract=$trace_contract"
[ "$trace_contract" = "8|8|8|8" ] || {
  echo "Expected receipt trace contract 8|8|8|8, got $trace_contract" >&2
  exit 1
}

visibility_status="$(psql_value "
SELECT (count(*) > 0)::text || '|' ||
       (COALESCE(sum(detailed_trace_captured_tokens), 0) > 0)::text || '|' ||
       (COALESCE(sum(detailed_trace_captured_tokens * detailed_trace_top_k), 0) > 0)::text || '|' ||
       (COALESCE(max(detailed_trace_max_tokens), 0) > 0)::text || '|' ||
       (COALESCE(max(detailed_trace_top_k), 0) = 3)::text
FROM otlet.inference_receipt_trace_status
WHERE task_name IN ('$entity_task', '$join_task')
  AND status = 'complete';
")"
echo "inference_visibility_status=$visibility_status"
require_contains "$visibility_status" "true|true|true|true|true" "Expected bounded token/top-k trace visibility counters"

cleanup_dry_run="$(psql_value "
SELECT worker_events::text || '|' ||
       token_trace_rows::text || '|' ||
       token_alternative_rows::text || '|' ||
       dry_run::text
FROM otlet.cleanup_policy_state(true);
")"
echo "cleanup_policy_dry_run=$cleanup_dry_run"
require_regex "$cleanup_dry_run" '^[0-9]+\|[0-9]+\|[0-9]+\|true$' "Expected cleanup dry run counts ending in true"

runtime_contract="$(psql_value "
SELECT runtime_status || '|' ||
       slot_state || '|' ||
       COALESCE(tokens_per_second::text, '') || '|' ||
       (COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0))::text || '|' ||
       COALESCE(worker_memory_sample_policy, '')
FROM otlet.runtime_status
WHERE runtime_name = '$runtime_name'
  AND model_name = '$cheap_model_name'
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
