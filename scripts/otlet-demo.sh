#!/usr/bin/env bash
set -euo pipefail

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
runtime_name="${OTLET_RUNTIME_NAME:-linked_inproc}"
runtime_endpoint="${OTLET_RUNTIME_ENDPOINT:-linked}"
cheap_model_name="${OTLET_CHEAP_MODEL_NAME:-qwen3_1_7b}"
strong_model_name="${OTLET_STRONG_MODEL_NAME:-qwen35_4b}"
strong_alias_model_name="${OTLET_STRONG_ALIAS_MODEL_NAME:-qwen35_4b_policy_alias}"
cheap_model_artifact="${OTLET_CHEAP_MODEL_ARTIFACT:-}"
strong_model_artifact="${OTLET_STRONG_MODEL_ARTIFACT:-}"
entity_task="${OTLET_ENTITY_TASK_NAME:-entity_resolution_demo}"
join_index_name="${OTLET_ENTITY_JOIN_INDEX_NAME:-demo_entity_resolution_idx}"
join_task="${join_index_name}_task"
join_foreign_table="${OTLET_ENTITY_JOIN_FOREIGN_TABLE:-demo_entity_resolution_pairs}"
record_type="${OTLET_ENTITY_RECORD_TYPE:-entity_hypothesis}"
row_triage_watch="${OTLET_ROW_TRIAGE_WATCH_NAME:-row_triage_demo}"
row_triage_task="${row_triage_watch}_task"
row_scoped_watch="${OTLET_ROW_SCOPED_WATCH_NAME:-row_scoped_demo}"
row_scoped_task="${row_scoped_watch}_task"
row_triage_policy_watch="${OTLET_ROW_TRIAGE_POLICY_WATCH_NAME:-row_triage_policy_demo}"
row_triage_policy_task="${row_triage_policy_watch}_task"
script_started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
entity_instruction='Never output different_entity when conflicting_stable_identifiers = 0. Never output same_entity when shared_stable_identifiers = 0. weak_matching_signals, missing_or_unknown_identifiers, and row_quality_warnings only explain unclear. Action type must be exactly merge_candidate, new_entity, or review_flag; never same_entity, different_entity, or unclear. same_entity uses merge_candidate body left_id, right_id, confidence, reason. different_entity uses new_entity body entity_id, reason, and entity_id must equal input.action_ids.right_id. unclear uses review_flag body left_id, right_id, severity, reason. Use input.action_ids.left_id and input.action_ids.right_id. Do not include an evidence field in actions. Keep output.reason and action body reason under 18 words. Quote every key and string. No markdown.'

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
  local cheap_model_file="${OTLET_CHEAP_MODEL_FILE:-Qwen3-1.7B-Q8_0.gguf}"
  local cheap_model_url="${OTLET_CHEAP_MODEL_URL:-https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf}"
  local cheap_model_repo_cache="${OTLET_CHEAP_MODEL_REPO_CACHE:-models--Qwen--Qwen3-1.7B-GGUF}"
  local strong_model_file="${OTLET_STRONG_MODEL_FILE:-Qwen3.5-4B-Q4_K_M.gguf}"
  local strong_model_url="${OTLET_STRONG_MODEL_URL:-https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf}"
  local strong_model_repo_cache="${OTLET_STRONG_MODEL_REPO_CACHE:-models--unsloth--Qwen3.5-4B-GGUF}"

  if [ -z "$cheap_model_artifact" ]; then
    cached="$(
      docker exec "$container" sh -lc \
        "find /var/lib/postgresql/.cache/huggingface/hub/$cheap_model_repo_cache/snapshots '$model_dir' -name '$cheap_model_file' -print -quit 2>/dev/null || true"
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
        "find /var/lib/postgresql/.cache/huggingface/hub/$strong_model_repo_cache/snapshots '$model_dir' -name '$strong_model_file' -print -quit 2>/dev/null || true"
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
    -v strong_alias_model_name="$strong_alias_model_name" \
    -v strong_model_artifact="$strong_model_artifact" >/dev/null <<'SQL'
SET client_min_messages TO warning;
CREATE EXTENSION IF NOT EXISTS otlet;
SELECT otlet.register_runtime(:'runtime_name', :'runtime_endpoint');
SELECT otlet.register_model(:'cheap_model_name', :'cheap_model_artifact', :'runtime_name');
SELECT otlet.register_model(:'strong_model_name', :'strong_model_artifact', :'runtime_name');
SELECT otlet.register_model(:'strong_alias_model_name', :'strong_model_artifact', :'runtime_name');
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
  -v join_index_name="$join_index_name" \
  -v join_foreign_table="$join_foreign_table" \
  -v row_triage_watch="$row_triage_watch" \
  -v row_scoped_watch="$row_scoped_watch" \
  -v row_triage_policy_watch="$row_triage_policy_watch" >/dev/null <<'SQL'
SELECT otlet.drop_watch(:'row_triage_watch');
SELECT otlet.drop_watch(:'row_scoped_watch');
SELECT otlet.drop_watch(:'row_triage_policy_watch');
SELECT otlet.drop_watch(:'join_index_name');
SELECT format('DROP FOREIGN TABLE IF EXISTS otlet.%I', :'join_foreign_table') \gexec
SQL
cleanup_task "row_review_demo"
cleanup_task "entity_hypothesis_demo"
cleanup_task "row_triage_demo"
cleanup_task "row_scoped_demo"
cleanup_task "row_triage_policy_demo"
cleanup_task "$row_triage_task"
cleanup_task "$row_scoped_task"
cleanup_task "$row_triage_policy_task"
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

log "Running direct ask demo"
psql_exec >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.readme_vendor_note;
CREATE TABLE public.readme_vendor_note (
  id text PRIMARY KEY,
  vendor_name text NOT NULL,
  note text NOT NULL
);
INSERT INTO public.readme_vendor_note VALUES (
  'note-1',
  'Northstar Logistics LLC',
  'AP says the bank account changed two days after a domain change. The request came from a new contact using urgent language. The invoice amount matches the open PO, but the remittance account does not match the vendor master record.'
);
SQL

direct_ask_output="$(
  psql_exec -qAt -v model_name="$strong_model_name" <<'SQL'
WITH asked AS (
  SELECT *
  FROM otlet.ask(
    :'model_name',
    'Read one vendor note. Return one JSON object with exactly two top-level keys: "output" then "actions". output has summary under 12 words, route, and reason under 10 words. route must be approve, review_payment, or block_payment. actions must be the empty array []. Do not close the outer object until after "actions":[] has been written. No markdown.',
    (SELECT jsonb_build_object('vendor_name', vendor_name, 'note', note)
     FROM public.readme_vendor_note
     WHERE id = 'note-1'),
    '{"type":"object","required":["summary","route","reason"],"additionalProperties":false,"properties":{"summary":{"type":"string"},"route":{"enum":["approve","review_payment","block_payment"]},"reason":{"type":"string"}}}'::jsonb,
    '{"max_tokens":128,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":16,"generation_trace_top_k":3}'::jsonb
  )
)
SELECT output->>'route' AS route, job_id, receipt_id
FROM asked
\gset direct_ask_
SELECT 'direct_ask_contract=' || :'direct_ask_route' || '|' || :'direct_ask_job_id' || '|' || :'direct_ask_receipt_id';
SELECT 'direct_ask_receipt_contract=' || s.model_name || '|' || s.status || '|' ||
       s.schema_validation_status || '|' || s.detailed_trace_captured_tokens::text
FROM otlet.inference_receipt_trace_status s
WHERE s.receipt_id = :'direct_ask_receipt_id'::bigint;
SQL
)"
printf '%s\n' "$direct_ask_output"
direct_ask_contract="$(sed -n 's/^direct_ask_contract=//p' <<<"$direct_ask_output")"
direct_ask_receipt_contract="$(sed -n 's/^direct_ask_receipt_contract=//p' <<<"$direct_ask_output")"
require_regex "$direct_ask_contract" '^review_payment\|[1-9][0-9]*\|[1-9][0-9]*$' "Expected direct ask to return review_payment with job and receipt ids"
require_regex "$direct_ask_receipt_contract" "^$strong_model_name\\|complete\\|passed\\|[1-9][0-9]*$" "Expected direct ask receipt evidence"

log "Running non-ER row triage watch"
psql_exec \
  -v model_name="$strong_model_name" \
  -v row_triage_watch="$row_triage_watch" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_triage_signal;
CREATE TABLE public.otlet_demo_triage_signal (
  id text PRIMARY KEY,
  blockers integer NOT NULL,
  approvals integer NOT NULL,
  evidence text NOT NULL
);

SELECT otlet.create_watch(
  :'row_triage_watch',
  'row',
  'Classify one operational row. Use input.row.blockers and input.row.approvals. If blockers is greater than 0, output decision flag with confidence high and exactly one review_flag action. The review_flag body must have severity high and a short reason. If blockers = 0 and approvals > 0, output decision pass with confidence high and no actions. Otherwise output decision unclear with confidence medium and one review_flag action. Return JSON only.',
  '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["flag", "pass", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 160}
    }
  }'::jsonb,
  :'model_name',
  'public.otlet_demo_triage_signal'::regclass,
  'id',
  NULL,
  'demo_triage_fact',
  '{"max_tokens":160,"reasoning":"off","inference_cache":true}'::jsonb,
  '{}'::jsonb,
  '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  ARRAY['review_flag'],
  'refresh_then_fail_closed',
  '{}'::jsonb,
  '{"answer_field":"decision","abstain_values":["unclear"],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);

INSERT INTO public.otlet_demo_triage_signal
VALUES (
  'triage-1',
  2,
  0,
  'Wire instructions changed after invoice approval and the requester used urgent payment language'
);
SQL
wait_task_complete "$row_triage_task" 1 900 1

row_triage_contract="$(psql_value "
SELECT count(DISTINCT r.job_id) FILTER (WHERE r.status = 'complete')::text || '|' ||
       COALESCE(max(r.output->>'decision'), '') || '|' ||
       COALESCE(max(r.output->>'confidence'), '') || '|' ||
       count(a.action_id) FILTER (WHERE a.action_type = 'review_flag')::text || '|' ||
       count(a.action_id) FILTER (WHERE a.action_type = 'review_flag' AND a.error IS NULL)::text
FROM otlet.runs r
LEFT JOIN otlet.action_status a ON a.job_id = r.job_id
WHERE r.task_name = '$row_triage_task';
")"
echo "row_triage_contract=$row_triage_contract"
[ "$row_triage_contract" = "1|flag|high|1|1" ] || {
  echo "Expected non-ER triage task to produce one flagged output and one valid review action, got $row_triage_contract" >&2
  exit 1
}

row_watch_status_contract="$(psql_value "
SELECT watch_name || '|' || kind || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queued_jobs::text || '|' ||
       complete_jobs::text
FROM otlet.watch_status
WHERE watch_name = '$row_triage_watch';
")"
echo "row_watch_status_contract=$row_watch_status_contract"
[ "$row_watch_status_contract" = "$row_triage_watch|row|1|1|0|0|0|1" ] || {
  echo "Expected row watch status to show one fresh completed row, got $row_watch_status_contract" >&2
  exit 1
}

log "Checking visible row update freshness"
row_receipts_before_visible_update="$(psql_value "
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = '$row_triage_task';
")"
psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_demo_triage_signal
SET blockers = 0,
    approvals = 1,
    evidence = 'Updated review cleared the blocker and recorded manager approval'
WHERE id = 'triage-1';
SQL
row_visible_stale_contract="$(psql_value "
SELECT count(*)::text
FROM otlet.semantic_index_current_rows('$row_triage_watch', true);
SELECT (count(*) FILTER (WHERE stale AND stale_reason = 'source_update') >= 1)::text
FROM otlet.semantic_materializations
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1';
SELECT otlet.semantic_matches('$row_triage_watch', 'triage-1', '{\"decision\":\"flag\"}'::jsonb)::text;
SELECT count(*)::text
FROM otlet.${row_triage_watch}_native
WHERE subject_id = 'triage-1';
")"
row_visible_fresh_before="$(head -n 1 <<<"$row_visible_stale_contract")"
row_visible_source_update="$(sed -n '2p' <<<"$row_visible_stale_contract")"
row_visible_predicate_match="$(sed -n '3p' <<<"$row_visible_stale_contract")"
row_visible_fdw_rows="$(tail -n 1 <<<"$row_visible_stale_contract")"
echo "row_visible_update_stale_contract=$row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_fdw_rows"
[ "$row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_fdw_rows" = "0|true|false|0" ] || {
  echo "Expected visible row update to fail closed across lookup surfaces, got $row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_fdw_rows" >&2
  exit 1
}
wait_task_complete "$row_triage_task" 2 900 1
row_visible_refresh_contract="$(psql_value "
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = '$row_triage_task';
SELECT count(*)::text
FROM otlet.semantic_index_current_rows('$row_triage_watch', true);
")"
row_receipts_after_visible_update="$(head -n 1 <<<"$row_visible_refresh_contract")"
row_visible_fresh_after="$(tail -n 1 <<<"$row_visible_refresh_contract")"
row_visible_receipt_delta=$((row_receipts_after_visible_update - row_receipts_before_visible_update))
echo "row_visible_update_refresh_contract=$row_visible_receipt_delta|$row_visible_fresh_after"
[ "$row_visible_receipt_delta|$row_visible_fresh_after" = "1|1" ] || {
  echo "Expected visible row update to produce exactly one receipt and one fresh row, got $row_visible_receipt_delta|$row_visible_fresh_after" >&2
  exit 1
}

log "Checking row delete freshness"
psql_exec >/dev/null <<'SQL'
DELETE FROM public.otlet_demo_triage_signal
WHERE id = 'triage-1';
SQL
row_delete_contract="$(psql_value "
SELECT count(*)::text
FROM otlet.semantic_index_current_rows('$row_triage_watch', true);
SELECT (count(*) FILTER (WHERE stale AND stale_reason = 'source_delete') >= 1)::text
FROM otlet.semantic_materializations
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1';
")"
row_delete_fresh="$(head -n 1 <<<"$row_delete_contract")"
row_delete_reason="$(tail -n 1 <<<"$row_delete_contract")"
echo "row_delete_contract=$row_delete_fresh|$row_delete_reason"
[ "$row_delete_fresh|$row_delete_reason" = "0|true" ] || {
  echo "Expected row delete to fail closed with source_delete reason, got $row_delete_fresh|$row_delete_reason" >&2
  exit 1
}

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
row_scoped_receipts_before="$(psql_value "
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = '$row_scoped_task';
")"
psql_exec >/dev/null <<'SQL'
ALTER TABLE public.otlet_demo_scoped_signal
ADD COLUMN unrelated_after_watch text DEFAULT 'not in model input';
UPDATE public.otlet_demo_scoped_signal
SET ignored_note = ignored_note || '; changed outside scoped input',
    unrelated_after_watch = 'changed after watch'
WHERE id = 'scoped-1';
SQL
row_scoped_contract="$(psql_value "
SELECT count(*)::text
FROM otlet.semantic_index_current_rows('$row_scoped_watch', true);
SELECT otlet.semantic_matches('$row_scoped_watch', 'scoped-1', '{\"decision\":\"pass\"}'::jsonb)::text;
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = '$row_scoped_task';
SELECT COALESCE(input_columns::text, '')
FROM otlet.watch_status
WHERE watch_name = '$row_scoped_watch';
")"
row_scoped_fresh_after="$(head -n 1 <<<"$row_scoped_contract")"
row_scoped_match_after="$(sed -n '2p' <<<"$row_scoped_contract")"
row_scoped_receipts_after="$(sed -n '3p' <<<"$row_scoped_contract")"
row_scoped_columns="$(tail -n 1 <<<"$row_scoped_contract")"
echo "row_scoped_contract=$row_scoped_fresh_after|$row_scoped_match_after|$row_scoped_receipts_before|$row_scoped_receipts_after|$row_scoped_columns"
[ "$row_scoped_fresh_after|$row_scoped_match_after|$row_scoped_receipts_before|$row_scoped_receipts_after|$row_scoped_columns" = "1|true|1|1|{signal}" ] || {
  echo "Expected scoped watch to stay fresh with unchanged receipts after unrelated column change, got $row_scoped_fresh_after|$row_scoped_match_after|$row_scoped_receipts_before|$row_scoped_receipts_after|$row_scoped_columns" >&2
  exit 1
}
psql_exec >/dev/null <<'SQL'
ALTER TABLE public.otlet_demo_scoped_signal
DROP COLUMN signal;
SQL
row_schema_drift_contract="$(psql_value "
SELECT count(*)::text
FROM otlet.semantic_index_current_rows('$row_scoped_watch', true);
SELECT (count(*) FILTER (WHERE stale AND stale_reason = 'schema_drift') >= 1)::text
FROM otlet.semantic_materializations
WHERE task_name = '$row_scoped_task'
  AND subject_id = 'scoped-1';
SELECT COALESCE(stale_reasons->>'schema_drift', '0')
FROM otlet.semantic_index_plan('$row_scoped_watch');
SELECT COALESCE(stale_reasons->>'schema_drift', '0')
FROM otlet.semantic_index_status
WHERE name = '$row_scoped_watch';
")"
row_schema_drift_fresh="$(head -n 1 <<<"$row_schema_drift_contract")"
row_schema_drift_reason="$(sed -n '2p' <<<"$row_schema_drift_contract")"
row_schema_drift_plan_reason="$(sed -n '3p' <<<"$row_schema_drift_contract")"
row_schema_drift_status_reason="$(tail -n 1 <<<"$row_schema_drift_contract")"
echo "row_schema_drift_contract=$row_schema_drift_fresh|$row_schema_drift_reason|$row_schema_drift_plan_reason|$row_schema_drift_status_reason"
[ "$row_schema_drift_fresh|$row_schema_drift_reason|$row_schema_drift_plan_reason|$row_schema_drift_status_reason" = "0|true|1|1" ] || {
  echo "Expected dropped scoped input column to write schema_drift and expose it in plan/status, got $row_schema_drift_fresh|$row_schema_drift_reason|$row_schema_drift_plan_reason|$row_schema_drift_status_reason" >&2
  exit 1
}
row_schema_fdw_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (VERBOSE, COSTS, SUMMARY OFF)
SELECT *
FROM otlet.${row_scoped_watch}_native;
SQL
)"
printf '%s\n' "$row_schema_fdw_plan"
require_contains "$row_schema_fdw_plan" "Otlet Node: Semantic Foreign Scan" "Expected row FDW explain details"
require_contains "$row_schema_fdw_plan" "Stale Reasons:" "Expected row FDW stale reason breakdown"
require_contains "$row_schema_fdw_plan" "schema_drift" "Expected row FDW stale reason to include schema_drift"
row_schema_customscan_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (VERBOSE, COSTS, SUMMARY OFF)
SELECT id
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches_auto('$row_scoped_watch', id, '{"decision":"pass"}'::jsonb);
SQL
)"
printf '%s\n' "$row_schema_customscan_plan"
require_contains "$row_schema_customscan_plan" "Otlet Node: Semantic Source CustomScan" "Expected CustomScan explain details"
require_contains "$row_schema_customscan_plan" "Planner Stale Reasons:" "Expected CustomScan stale reason breakdown"
require_contains "$row_schema_customscan_plan" "schema_drift" "Expected CustomScan stale reason to include schema_drift"

queue_suppression_output="$(psql_value "
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
  'Return JSON only: {\"output\":{\"status\":\"ok\"},\"actions\":[]}',
  '{\"type\":\"object\",\"required\":[\"status\"],\"additionalProperties\":false,\"properties\":{\"status\":{\"enum\":[\"ok\"]}}}'::jsonb,
  '$strong_model_name',
  'public.otlet_demo_queue_flood'::regclass,
  'id',
  NULL,
  'demo_queue_flood_fact',
  '{\"max_tokens\":64,\"reasoning\":\"off\"}'::jsonb,
  '{}'::jsonb,
  '{\"on_change\":\"mark_stale_and_enqueue\"}'::jsonb
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
    SELECT (queue_admission_suppressed_events >= 2)::text || '|' ||
           (queue_admission_last_suppressed_at IS NOT NULL)::text
    FROM otlet.model_queue_status
    WHERE model_name = '$strong_model_name'
  );
ROLLBACK;
")"
queue_suppression_contract="$(tail -n 1 <<<"$queue_suppression_output")"
echo "queue_suppression_contract=$queue_suppression_contract"
[ "$queue_suppression_contract" = "1|true|true" ] || {
  echo "Expected queue suppression contract 1|true|true, got $queue_suppression_contract" >&2
  exit 1
}

log "Running non-ER triage selection policy"
psql_exec \
  -v cheap_policy_model="$strong_model_name" \
  -v strong_policy_model="$strong_alias_model_name" \
  -v row_triage_policy_watch="$row_triage_policy_watch" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_triage_policy_signal;
CREATE TABLE public.otlet_demo_triage_policy_signal (
  id text PRIMARY KEY,
  blockers integer NOT NULL,
  approvals integer NOT NULL,
  evidence text NOT NULL
);

SELECT otlet.create_watch(
  :'row_triage_policy_watch',
  'row',
  'Classify one operational row. Use input.row.blockers and input.row.approvals. If blockers > 0, output decision flag with confidence high and one review_flag action. If blockers = 0 and approvals > 0, output decision pass with confidence high and no actions. Otherwise output decision unclear with confidence medium and one review_flag action with severity medium and a short reason. Return JSON only.',
  '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["flag", "pass", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 160}
    }
  }'::jsonb,
  :'cheap_policy_model',
  'public.otlet_demo_triage_policy_signal'::regclass,
  'id',
  NULL,
  'demo_triage_policy_fact',
  '{"max_tokens":160,"reasoning":"off","inference_cache":true}'::jsonb,
  jsonb_build_object(
    'cheap_model_name', :'cheap_policy_model',
    'strong_model_name', :'strong_policy_model',
    'accept_field_checks', '{"answer_field":"decision","abstain_values":["unclear"],"confidence_field":"confidence","accepted_confidence":["high","medium"]}'::jsonb
  ),
  '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  ARRAY['review_flag'],
  'refresh_then_fail_closed',
  '{}'::jsonb,
  '{"answer_field":"decision","abstain_values":["unclear"],"confidence_field":"confidence","accepted_confidence":["high","medium"]}'::jsonb
);

INSERT INTO public.otlet_demo_triage_policy_signal
VALUES (
  'triage-unclear',
  0,
  0,
  'No decisive blocker and no approval evidence; send to human review'
);
SQL
wait_task_complete "$row_triage_policy_task" 1 900 1

row_triage_policy_contract="$(psql_value "
WITH attempts AS (
  SELECT selection_role, selection_status, selection_reason
  FROM otlet.model_selection_attempts
  WHERE task_name = '$row_triage_policy_task'
)
SELECT
  (SELECT count(*) FROM attempts WHERE selection_role = 'cheap' AND selection_status = 'rejected' AND selection_reason = 'abstained_output')::text || '|' ||
  (SELECT count(*) FROM attempts WHERE selection_role = 'strong' AND selection_status = 'accepted')::text || '|' ||
  COALESCE((SELECT output->>'decision' FROM otlet.runs WHERE task_name = '$row_triage_policy_task'), '') || '|' ||
  (SELECT count(*) FROM otlet.action_status WHERE task_name = '$row_triage_policy_task' AND action_type = 'review_flag')::text;
")"
echo "row_triage_policy_contract=$row_triage_policy_contract"
[ "$row_triage_policy_contract" = "1|1|unclear|1" ] || {
  echo "Expected declared triage policy to reject cheap unclear then accept strong unclear with one review action, got $row_triage_policy_contract" >&2
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
  ('vendor-1001', 'Northstar Logistics LLC', 'northstar-logistics.example', '41 W Lake St, Chicago, IL', 'legacy freight vendor from the 2021 import; tax id 36-9918821; remittance account ending 8821; AP contact ops@northstar-logistics.example'),
  ('vendor-42', 'N-Star Freight Services', 'nstar-freight.example', '41 West Lake Street, Suite 900, Chicago', 'same remittance account ending 8821 and same tax id 36-9918821; internal note says Northstar rebranded after acquisition'),
  ('vendor-77', 'Clearwater Medical Supplies', 'clearwatermed.example', '500 Hospital Way, Phoenix, AZ', 'hospital supply distributor; no shared tax id, domain, payment account, AP contact, remittance account, city, or industry with the freight vendor'),
  ('vendor-313', 'North Star Medical Logistics', 'northstarmedlog.example', '41 West Lake Street, Chicago, IL', 'medical logistics broker; same building and similar name, but verified separate legal entity; different tax id 92-4403130; different remittance account ending 1199; different domain, payment account, AP contact, and no acquisition note'),
  ('vendor-314', 'Northstar Freight Canada Inc.', 'northstar-canada.example', '88 King St W, Toronto, ON', 'Canadian freight carrier with similar brand; different country, tax id CA-771314, bank account ending 4410, AP contact, and no shared remittance account or acquisition note in the ledger');
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
    'candidate_evidence', evidence.candidate_evidence,
    'evidence_counts', jsonb_build_object(
      'shared_stable_identifiers', jsonb_array_length(evidence.candidate_evidence -> 'shared_stable_identifiers'),
      'conflicting_stable_identifiers', jsonb_array_length(evidence.candidate_evidence -> 'conflicting_stable_identifiers'),
      'weak_matching_signals', jsonb_array_length(evidence.candidate_evidence -> 'weak_matching_signals'),
      'missing_or_unknown_identifiers', jsonb_array_length(evidence.candidate_evidence -> 'missing_or_unknown_identifiers'),
      'row_quality_warnings', jsonb_array_length(evidence.candidate_evidence -> 'row_quality_warnings')
    ),
    'action_ids', jsonb_build_object('left_id', p.left_id, 'right_id', p.right_id)
  ) AS input
FROM public.otlet_demo_vendor_pair p
JOIN public.otlet_demo_vendor_entity l ON l.id = p.left_id
JOIN public.otlet_demo_vendor_entity r ON r.id = p.right_id
CROSS JOIN LATERAL (
  SELECT CASE p.pair_id
    WHEN 'vendor-1001:vendor-42' THEN jsonb_build_object(
      'shared_stable_identifiers', jsonb_build_array(
        'same remittance account ending 8821',
        'same tax id 36-9918821',
        'Northstar rebrand after acquisition'
      ),
      'conflicting_stable_identifiers', '[]'::jsonb,
      'weak_matching_signals', jsonb_build_array('similar address'),
      'missing_or_unknown_identifiers', '[]'::jsonb,
      'row_quality_warnings', '[]'::jsonb
    )
    WHEN 'vendor-1001:vendor-77' THEN jsonb_build_object(
      'shared_stable_identifiers', '[]'::jsonb,
      'conflicting_stable_identifiers', jsonb_build_array(
        'different industry and city',
        'no shared tax id, domain, payment account, AP contact, or remittance account'
      ),
      'weak_matching_signals', '[]'::jsonb,
      'missing_or_unknown_identifiers', '[]'::jsonb,
      'row_quality_warnings', '[]'::jsonb
    )
    WHEN 'vendor-1001:vendor-313' THEN jsonb_build_object(
      'shared_stable_identifiers', '[]'::jsonb,
      'conflicting_stable_identifiers', jsonb_build_array(
        'medical logistics versus freight vendor',
        'different tax id 92-4403130',
        'different remittance account ending 1199',
        'different domain, payment account, AP contact, and no acquisition note'
      ),
      'weak_matching_signals', jsonb_build_array('same office building', 'similar North Star name'),
      'missing_or_unknown_identifiers', '[]'::jsonb,
      'row_quality_warnings', '[]'::jsonb
    )
    WHEN 'vendor-1001:vendor-314' THEN jsonb_build_object(
      'shared_stable_identifiers', '[]'::jsonb,
      'conflicting_stable_identifiers', jsonb_build_array(
        'different country and Canadian legal entity',
        'different tax id CA-771314',
        'different bank account ending 4410, AP contact, and no shared remittance account',
        'no acquisition or rebrand note connecting the records'
      ),
      'weak_matching_signals', jsonb_build_array('similar Northstar freight brand'),
      'missing_or_unknown_identifiers', '[]'::jsonb,
      'row_quality_warnings', '[]'::jsonb
    )
    ELSE jsonb_build_object(
      'shared_stable_identifiers', '[]'::jsonb,
      'conflicting_stable_identifiers', '[]'::jsonb,
      'weak_matching_signals', '[]'::jsonb,
      'missing_or_unknown_identifiers', jsonb_build_array('no decisive identity evidence'),
      'row_quality_warnings', '[]'::jsonb
    )
  END AS candidate_evidence
) evidence;
SQL

source_rows_before="$(psql_value "
SELECT count(*)::text || '|' ||
       md5(string_agg(to_jsonb(v)::text, ',' ORDER BY v.id))
FROM public.otlet_demo_vendor_entity v;
")"

psql_exec \
  -v cheap_model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" \
  -v task_name="$entity_task" \
  -v record_type="$record_type" \
  -v entity_instruction="$entity_instruction" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $$
    SELECT subject_id, input
    FROM public.otlet_demo_vendor_pair_input
    ORDER BY subject_id
  $$,
  :'entity_instruction',
  '{
    "type": "object",
    "required": ["match", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "match": {"enum": ["same_entity", "different_entity", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 240}
    }
  }'::jsonb,
  :'cheap_model_name',
  '{"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":16,"generation_trace_top_k":3}'::jsonb,
  '{"evidence_fields":["candidate_evidence"],"action_id_fields":{"left_id":"left_id","right_id":"right_id"}}'::jsonb,
  '{"preset":"entity_resolution_evidence_v1"}'::jsonb
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
SELECT (cheap_attempts >= 1)::text || '|' ||
       (strong_accepted >= 1)::text || '|' ||
       (escalated_jobs >= 1)::text || '|' ||
       cheap_attempts::text || '|' ||
       strong_attempts::text
FROM otlet.model_selection_status
WHERE task_name = '$entity_task';
")"
echo "model_selection_status_contract=$model_selection_status_contract"
require_regex "$model_selection_status_contract" '^true\|true\|true\|[1-9][0-9]*\|[1-9][0-9]*$' "Expected cheap attempts, strong acceptance, and escalation"

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

action_contract="$(psql_value "
WITH schema_check AS (
  SELECT string_agg(action_type, '|' ORDER BY action_type) AS value
  FROM otlet.action_type_schemas
  WHERE action_type IN ('follow_up_job', 'merge_candidate', 'new_entity', 'note', 'review_flag')
), type_check AS (
  SELECT COALESCE(string_agg(DISTINCT action_type, '|' ORDER BY action_type), '') AS value
  FROM otlet.action_status
  WHERE task_name = '$entity_task'
    AND trusted_output
), status_check AS (
  SELECT count(*)::text || '|' ||
         count(*) FILTER (WHERE trusted_output)::text || '|' ||
         count(*) FILTER (WHERE receipt_id IS NOT NULL AND output_id IS NOT NULL)::text || '|' ||
         count(*) FILTER (WHERE status = 'rejected')::text AS value
  FROM otlet.action_status
  WHERE task_name = '$entity_task'
), failed_check AS (
  SELECT count(*)::text AS value
  FROM otlet.action_status a
  JOIN otlet.inference_receipts r ON r.id = a.receipt_id
  WHERE a.task_name = '$entity_task'
    AND r.selection_status <> 'accepted'
)
SELECT concat_ws(E'\n',
  'action_schema_contract=' || schema_check.value,
  'action_type_contract=' || type_check.value,
  'action_status_contract=' || status_check.value,
  'failed_attempt_action_contract=' || failed_check.value
)
FROM schema_check, type_check, status_check, failed_check;
")"
printf '%s\n' "$action_contract"
require_contains "$action_contract" "action_schema_contract=follow_up_job|merge_candidate|new_entity|note|review_flag" "Expected built-in action schemas"
require_contains "$action_contract" "action_type_contract=merge_candidate|new_entity" "Expected entity-resolution merge_candidate and new_entity actions"
require_contains "$action_contract" "action_status_contract=4|4|4|0" "Expected four trusted valid entity actions"
require_contains "$action_contract" "failed_attempt_action_contract=0" "Expected failed/rejected attempts to create no actions"

merge_action_id="$(psql_value "
SELECT min(action_id)
FROM otlet.action_status
WHERE task_name = '$entity_task'
  AND action_type = 'merge_candidate';
")"
new_entity_action_id="$(psql_value "
SELECT min(action_id)
FROM otlet.action_status
WHERE task_name = '$entity_task'
  AND action_type = 'new_entity';
")"
[ -n "$merge_action_id" ] && [ -n "$new_entity_action_id" ] || {
  echo "Expected merge_candidate and new_entity action ids" >&2
  exit 1
}

action_approve_contract="$(psql_value "
SELECT status || '|' || approval_status
FROM otlet.approve_action($merge_action_id);
")"
echo "action_approve_contract=$action_approve_contract"
[ "$action_approve_contract" = "approved|approved" ] || {
  echo "Expected merge_candidate approval, got $action_approve_contract" >&2
  exit 1
}

action_dry_run_contract="$(psql_value "
SELECT status || '|' || approval_status || '|' || dry_run_status
FROM otlet.dry_run_action($merge_action_id);
")"
echo "action_dry_run_contract=$action_dry_run_contract"
[ "$action_dry_run_contract" = "approved|approved|passed" ] || {
  echo "Expected approved action dry-run pass, got $action_dry_run_contract" >&2
  exit 1
}

action_apply_contract="$(psql_value "
SELECT status || '|' || approval_status || '|' || apply_status
FROM otlet.apply_action($merge_action_id);
")"
echo "action_apply_contract=$action_apply_contract"
[ "$action_apply_contract" = "approved|approved|not_applicable" ] || {
  echo "Expected merge_candidate apply to stay not_applicable, got $action_apply_contract" >&2
  exit 1
}

action_reject_contract="$(psql_value "
SELECT status || '|' || approval_status
FROM otlet.reject_action($new_entity_action_id, 'demo rejection');
")"
echo "action_reject_contract=$action_reject_contract"
[ "$action_reject_contract" = "rejected|rejected" ] || {
  echo "Expected new_entity rejection, got $action_reject_contract" >&2
  exit 1
}

source_rows_after="$(psql_value "
SELECT count(*)::text || '|' ||
       md5(string_agg(to_jsonb(v)::text, ',' ORDER BY v.id))
FROM public.otlet_demo_vendor_entity v;
")"
source_write_contract="$source_rows_before|$source_rows_after"
echo "source_write_contract=$source_write_contract"
[ "$source_rows_before" = "$source_rows_after" ] || {
  echo "Expected action approval/apply to leave source rows unchanged" >&2
  exit 1
}

log "Building entity-resolution pair watch"
psql_exec \
  -v join_index_name="$join_index_name" \
  -v cheap_model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" \
  -v record_type="$record_type" \
  -v entity_instruction="$entity_instruction" >/dev/null <<'SQL'
SELECT name, task_name, record_type, max_candidate_rows
FROM otlet.create_watch(
  watch_name => :'join_index_name',
  kind => 'pair',
  instruction => :'entity_instruction',
  output_schema => '{
    "type": "object",
    "required": ["match", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "match": {"enum": ["same_entity", "different_entity", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 240}
    }
  }'::jsonb,
  model_name => :'cheap_model_name',
  candidate_query => $$
    SELECT subject_id, input
    FROM public.otlet_demo_vendor_pair_input
    ORDER BY subject_id
  $$,
  record_type => :'record_type',
  runtime_options => '{"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":16,"generation_trace_top_k":3}'::jsonb,
  selection_policy => jsonb_build_object(
    'cheap_model_name', :'cheap_model_name',
    'strong_model_name', :'strong_model_name'
  ),
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  action_types => ARRAY['merge_candidate', 'new_entity', 'review_flag'],
  input_shaping => '{"evidence_fields":["candidate_evidence"],"action_id_fields":{"left_id":"left_id","right_id":"right_id"}}'::jsonb,
  decision_contract => '{"preset":"entity_resolution_evidence_v1"}'::jsonb,
  max_candidate_rows => 10
);
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

pair_watch_status_contract="$(psql_value "
SELECT watch_name || '|' || kind || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queued_jobs::text || '|' ||
       complete_jobs::text || '|' ||
       (proposed_actions >= 4)::text
FROM otlet.watch_status
WHERE watch_name = '$join_index_name';
")"
echo "pair_watch_status_contract=$pair_watch_status_contract"
[ "$pair_watch_status_contract" = "$join_index_name|pair|4|4|0|0|0|4|true" ] || {
  echo "Expected pair watch status to show four fresh completed subjects, got $pair_watch_status_contract" >&2
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

log "Checking benign entity-resolution source update"
join_receipts_before_update="$(psql_value "
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = '$join_task';
")"
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
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = '$join_task';
")"
join_stale_subjects="$(head -n 1 <<<"$join_stale_contract")"
join_fresh_after_lookup="$(sed -n '2p' <<<"$join_stale_contract")"
join_receipts_after_update="$(tail -n 1 <<<"$join_stale_contract")"
echo "semantic_join_stale_contract=$join_stale_subjects|fresh_after_lookup=$join_fresh_after_lookup|receipts=$join_receipts_before_update|$join_receipts_after_update"
if [ "$join_stale_subjects|$join_fresh_after_lookup" != "0|4|4" ] || [ "$join_receipts_before_update" != "$join_receipts_after_update" ]; then
  echo "Expected semantic join benign-update contract 0|4|4 with unchanged receipts, got $join_stale_subjects|$join_fresh_after_lookup|$join_receipts_before_update|$join_receipts_after_update" >&2
  exit 1
fi

log "Checking contract-change freshness invalidation"
psql_exec >/dev/null <<SQL
WITH current_task AS (
  SELECT *
  FROM otlet.tasks
  WHERE name = '$join_task'
)
SELECT (otlet.create_task(
    name,
    input_query,
    instruction || ' Contract drift demo.',
    output_schema,
    model_name,
    runtime_options,
    input_shaping,
    decision_contract
  )).name
FROM current_task;
SQL
contract_change_contract="$(psql_value "
SELECT count(*) FILTER (WHERE sm.stale_reason = 'contract_changed')::text || '|' ||
       count(*) FILTER (WHERE sm.stale)::text
FROM otlet.semantic_materializations sm
WHERE sm.task_name = '$join_task';
SELECT count(*)::text
FROM otlet.semantic_join_index_current_rows('$join_index_name', true);
")"
contract_change_counts="$(head -n 1 <<<"$contract_change_contract")"
contract_change_fresh="$(tail -n 1 <<<"$contract_change_contract")"
echo "contract_change_contract=$contract_change_counts|fresh_after_contract_change=$contract_change_fresh"
[ "$contract_change_counts|$contract_change_fresh" = "4|4|0" ] || {
  echo "Expected contract-change freshness invalidation 4|4|0, got $contract_change_counts|$contract_change_fresh" >&2
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
