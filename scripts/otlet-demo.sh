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
row_customscan_watch="${OTLET_ROW_CUSTOMSCAN_WATCH_NAME:-row_customscan_demo}"
row_customscan_task="${row_customscan_watch}_task"
row_triage_policy_watch="${OTLET_ROW_TRIAGE_POLICY_WATCH_NAME:-row_triage_policy_demo}"
row_triage_policy_task="${row_triage_policy_watch}_task"
numeric_triage_watch="numeric_triage_demo"
numeric_triage_task="${numeric_triage_watch}_task"
prompt_identity_preset_task="prompt_identity_preset_smoke"
prompt_identity_direct_task="prompt_identity_direct_smoke"
output_envelope_task="output_envelope_safety_demo"
prompt_diet_verbatim_task="prompt_diet_verbatim_demo"
prompt_diet_compact_task="prompt_diet_compact_demo"
custom_action_schema_task="custom_action_schema_demo"
action_allowlist_watch="action_allowlist_demo"
action_allowlist_task="${action_allowlist_watch}_task"
direct_gate_task="direct_decision_gate_demo"
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
DELETE FROM otlet.eval_labels l
USING otlet.actions a, otlet.jobs j
WHERE l.action_id = a.id
  AND a.job_id = j.id
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

wait_task_failed() {
  local task="$1"
  local expected_failed="${2:-1}"
  local attempts="${3:-300}"
  local delay="${4:-1}"
  local active complete failed

  for _ in $(seq 1 "$attempts"); do
    active="$(psql_value "SELECT count(*) FROM otlet.jobs WHERE task_name = '$task' AND status IN ('queued','running','cancel_requested');")"
    complete="$(psql_value "SELECT count(*) FROM otlet.jobs WHERE task_name = '$task' AND status = 'complete';")"
    failed="$(psql_value "SELECT count(*) FROM otlet.jobs WHERE task_name = '$task' AND status IN ('failed','canceled');")"
    if [ "$failed" -ge "$expected_failed" ] && [ "$active" = "0" ]; then
      return 0
    fi
    if [ "$complete" != "0" ]; then
      psql_exec -P border=2 -P null='' -v task_name="$task" <<'SQL'
SELECT job_id, task_name, subject_id, status, error, raw_output
FROM otlet.runs
WHERE task_name = :'task_name'
ORDER BY job_id;
SQL
      return 1
    fi
    sleep "$delay"
  done

  echo "Timed out waiting for task $task failed=$failed active=$active expected=$expected_failed" >&2
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
SELECT name || '|' || stale_policy || '|' || max_attempts::text || '|' ||
       max_attempt_ms::text || '|' || worker_claim_batch_size::text
FROM otlet.production_policy_status;
")"
echo "production_policy_contract=$production_policy_contract"
[ "$production_policy_contract" = "default|refresh_then_fail_closed|3|300000|8" ] || {
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
  -v row_customscan_watch="$row_customscan_watch" \
  -v row_triage_policy_watch="$row_triage_policy_watch" \
  -v numeric_triage_watch="$numeric_triage_watch" \
  -v action_allowlist_watch="$action_allowlist_watch" >/dev/null <<'SQL'
SELECT otlet.drop_watch(:'row_triage_watch');
SELECT otlet.drop_watch(:'row_scoped_watch');
SELECT otlet.drop_watch(:'row_customscan_watch');
SELECT otlet.drop_watch(:'row_triage_policy_watch');
SELECT otlet.drop_watch(:'numeric_triage_watch');
SELECT otlet.drop_watch(:'action_allowlist_watch');
SELECT otlet.drop_watch(:'join_index_name');
SELECT format('DROP FOREIGN TABLE IF EXISTS otlet.%I', :'join_foreign_table') \gexec
SQL
cleanup_task "row_review_demo"
cleanup_task "entity_hypothesis_demo"
cleanup_task "row_triage_demo"
cleanup_task "row_scoped_demo"
cleanup_task "row_customscan_demo"
cleanup_task "row_triage_policy_demo"
cleanup_task "$numeric_triage_task"
cleanup_task "$prompt_identity_preset_task"
cleanup_task "$prompt_identity_direct_task"
cleanup_task "$output_envelope_task"
cleanup_task "$prompt_diet_verbatim_task"
cleanup_task "$prompt_diet_compact_task"
cleanup_task "$custom_action_schema_task"
cleanup_task "$action_allowlist_task"
cleanup_task "$direct_gate_task"
cleanup_task "input_shape_mvcc_raw_demo"
cleanup_task "input_shape_mvcc_hand_demo"
cleanup_task "input_shape_truncate_demo"
cleanup_task "$row_triage_task"
cleanup_task "$row_scoped_task"
cleanup_task "$row_customscan_task"
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

queue_fairness_big_task="queue_fairness_big_demo"
queue_fairness_small_task="queue_fairness_small_demo"
cleanup_task "$queue_fairness_big_task"
cleanup_task "$queue_fairness_small_task"
queue_fairness_output="$(
  psql_exec \
    -qAt \
    -v big_task="$queue_fairness_big_task" \
    -v small_task="$queue_fairness_small_task" \
    -v model_name="$strong_model_name" <<'SQL'
CREATE TEMP TABLE queue_fairness_params (
  big_task text,
  small_task text,
  model_name text
);
INSERT INTO queue_fairness_params VALUES (:'big_task', :'small_task', :'model_name');
CREATE TEMP TABLE queue_fairness_claims (
  batch_no int,
  task_name text,
  job_id bigint
);

SELECT otlet.create_task(
  :'big_task',
  'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
  'Queue fairness smoke placeholder',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":1,"reasoning":"off"}'::jsonb
);
SELECT otlet.create_task(
  :'small_task',
  'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
  'Queue fairness smoke placeholder',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":1,"reasoning":"off"}'::jsonb
);

INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT :'big_task', 'big-' || lpad(i::text, 4, '0'), '{}'::jsonb
FROM generate_series(1, 1000) AS g(i);
INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT :'small_task', 'small-' || i::text, '{}'::jsonb
FROM generate_series(1, 4) AS g(i);

UPDATE otlet.production_policy
SET worker_claim_batch_size = 8,
    worker_claim_task_cursor = ''
WHERE name = 'default';

DO $$
DECLARE
  batch_no int;
  claimed_count int;
  claimed_task text;
  task_model text;
  task_runtime text;
  job_row otlet.jobs%ROWTYPE;
  small_task_name text;
BEGIN
  SELECT small_task INTO small_task_name FROM queue_fairness_params;

  FOR batch_no IN 1..4 LOOP
    claimed_count := 0;
    claimed_task := NULL;

    FOR job_row IN SELECT * FROM otlet.claim_jobs() LOOP
      claimed_count := claimed_count + 1;
      claimed_task := job_row.task_name;
      INSERT INTO queue_fairness_claims VALUES (batch_no, job_row.task_name, job_row.id);
      PERFORM otlet.complete_job(
        job_row.id,
        '{"status":"ok"}'::jsonb,
        '{"output":{"status":"ok"},"actions":[]}',
        '[]'::jsonb,
        trace_summary => '{"schema_validation_status":"passed","trace_version":"queue_fairness_smoke"}'::jsonb
      );
    END LOOP;

    IF claimed_count > 1 THEN
      SELECT t.model_name, m.runtime_name
      INTO task_model, task_runtime
      FROM otlet.tasks t
      JOIN otlet.models m ON m.name = t.model_name
      WHERE t.name = claimed_task;

      PERFORM otlet.record_worker_event(
        'worker_batch_finished',
        NULL,
        task_runtime,
        'worker_batch_finished',
        jsonb_build_object(
          'task_name', claimed_task,
          'model_name', task_model,
          'job_count', claimed_count,
          'completed_jobs', claimed_count,
          'failed_jobs', 0
        )
      );
    END IF;

    EXIT WHEN (
      SELECT count(*)
      FROM otlet.jobs
      WHERE task_name = small_task_name
        AND status = 'complete'
    ) = 4;
  END LOOP;
END;
$$;

WITH params AS (
  SELECT * FROM queue_fairness_params
),
summary AS (
  SELECT
    count(*) FILTER (WHERE c.task_name = p.small_task)::bigint AS small_claimed,
    max(c.batch_no) FILTER (WHERE c.task_name = p.small_task) AS last_small_batch
  FROM params p
  LEFT JOIN queue_fairness_claims c ON true
  GROUP BY p.small_task
),
status AS (
  SELECT w.recent_batch_tasks
  FROM params p
  JOIN otlet.worker_throughput_status w ON w.model_name = p.model_name
),
visible_batches AS (
  SELECT
    EXISTS (
      SELECT 1
      FROM status s, params p, jsonb_array_elements(s.recent_batch_tasks) item
      WHERE item ->> 'task_name' = p.big_task
    ) AS has_big,
    EXISTS (
      SELECT 1
      FROM status s, params p, jsonb_array_elements(s.recent_batch_tasks) item
      WHERE item ->> 'task_name' = p.small_task
    ) AS has_small
)
SELECT (small_claimed = 4)::text || '|' ||
       (last_small_batch <= 2)::text || '|' ||
       (has_big AND has_small)::text
FROM summary, visible_batches;
SQL
)"
queue_fairness_contract="$(tail -n 1 <<<"$queue_fairness_output")"
echo "queue_fairness_contract=$queue_fairness_contract"
[ "$queue_fairness_contract" = "true|true|true" ] || {
  echo "Expected queue fairness contract true|true|true, got $queue_fairness_contract" >&2
  exit 1
}
cleanup_task "$queue_fairness_big_task"
cleanup_task "$queue_fairness_small_task"

queue_race_task="queue_admission_race_demo"
cleanup_task "$queue_race_task"
psql_exec -v task_name="$queue_race_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'race-' || i::text AS subject_id, '{}'::jsonb AS input
    FROM generate_series(1, 50) AS g(i)
  $source$::text,
  'Queue admission race smoke placeholder',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":1,"reasoning":"off"}'::jsonb
);
UPDATE otlet.production_policy
SET max_queued_jobs_per_model = 5,
    worker_claim_batch_size = 8,
    worker_claim_task_cursor = ''
WHERE name = 'default';
SQL
psql_exec >/dev/null <<'SQL' &
BEGIN;
SELECT 1 FROM otlet.production_policy WHERE name = 'default' FOR UPDATE;
SELECT pg_sleep(10);
COMMIT;
SQL
queue_lock_pid="$!"
sleep 1
queue_race_pids=()
for _ in $(seq 1 8); do
  psql_exec -qAt -v task_name="$queue_race_task" >/dev/null <<'SQL' &
SELECT otlet.run_task(:'task_name');
SQL
  queue_race_pids+=("$!")
done
for pid in "${queue_race_pids[@]}"; do
  wait "$pid"
done
queue_race_contract="$(psql_value "
SELECT (count(*) FILTER (WHERE status = 'queued') <= 5)::text || '|' ||
       (count(*) = 5)::text
FROM otlet.jobs
WHERE task_name = '$queue_race_task';
")"
echo "queue_admission_race_contract=$queue_race_contract"
cleanup_task "$queue_race_task"
wait "$queue_lock_pid"
psql_exec >/dev/null <<'SQL'
UPDATE otlet.production_policy
SET max_queued_jobs_per_model = 1000,
    max_attempt_ms = 300000,
    worker_claim_batch_size = 8,
    worker_claim_task_cursor = ''
WHERE name = 'default';
SQL
[ "$queue_race_contract" = "true|true" ] || {
  echo "Expected concurrent run_task admission to keep queued jobs at the cap, got $queue_race_contract" >&2
  exit 1
}

attempt_timeout_task="attempt_timeout_demo"
cleanup_task "$attempt_timeout_task"
psql_exec -v task_name="$attempt_timeout_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'timeout-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":256,"reasoning":"off","inference_cache":false}'::jsonb
);
UPDATE otlet.production_policy
SET max_attempt_ms = 1
WHERE name = 'default';
SELECT otlet.run_task(:'task_name');
SQL
attempt_timeout_failed="0"
attempt_timeout_complete="0"
for _ in $(seq 1 180); do
  attempt_timeout_state="$(psql_value "
SELECT count(*) FILTER (WHERE status IN ('queued','running','cancel_requested'))::text || '|' ||
       count(*) FILTER (WHERE status = 'failed')::text || '|' ||
       count(*) FILTER (WHERE status = 'complete')::text
FROM otlet.jobs
WHERE task_name = '$attempt_timeout_task';
")"
  attempt_timeout_failed="$(cut -d'|' -f2 <<<"$attempt_timeout_state")"
  attempt_timeout_complete="$(cut -d'|' -f3 <<<"$attempt_timeout_state")"
  if [ "$attempt_timeout_failed" = "1" ]; then
    break
  fi
  if [ "$attempt_timeout_complete" != "0" ]; then
    echo "Expected timeout smoke to fail, got state $attempt_timeout_state" >&2
    exit 1
  fi
  sleep 1
done
[ "$attempt_timeout_failed" = "1" ] || {
  echo "Timed out waiting for attempt-timeout smoke, complete=$attempt_timeout_complete failed=$attempt_timeout_failed" >&2
  exit 1
}
attempt_timeout_contract="$(psql_value "
SELECT j.status || '|' ||
       COALESCE(j.error, '') || '|' ||
       COALESCE(s.selection_reason, '') || '|' ||
       COALESCE(s.schema_validation_status, '') || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM otlet.inference_receipt_trace_status s
JOIN otlet.jobs j ON j.id = s.job_id
JOIN otlet.runtime_status rs
  ON rs.runtime_name = '$runtime_name'
 AND rs.model_name = '$strong_model_name'
WHERE s.task_name = '$attempt_timeout_task'
ORDER BY s.receipt_id DESC
LIMIT 1;
")"
echo "attempt_timeout_contract=$attempt_timeout_contract"
psql_exec >/dev/null <<'SQL'
UPDATE otlet.production_policy
SET max_attempt_ms = 300000
WHERE name = 'default';
SQL
[ "$attempt_timeout_contract" = "failed|attempt_timeout|attempt_timeout|failed|ready|ready" ] || {
  echo "Expected attempt timeout to fail cleanly with healthy worker, got $attempt_timeout_contract" >&2
  exit 1
}

malformed_schema_task="malformed_schema_worker_demo"
cleanup_task "$malformed_schema_task"
psql_exec -v task_name="$malformed_schema_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'malformed-schema-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only.',
  '{"type":"not_a_valid_json_schema_type"}'::jsonb,
  :'model_name',
  '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_failed "$malformed_schema_task" 1 120 1
malformed_schema_contract="$(psql_value "
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = '$malformed_schema_task'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, selection_reason, schema_validation_status, trace_summary
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
)
SELECT j.status || '|' ||
       (j.error LIKE 'invalid output schema:%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.selection_reason || '|' ||
       r.schema_validation_status || '|' ||
       COALESCE(r.trace_summary ->> 'stop_reason', '') || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM job_row j
CROSS JOIN receipt_row r
JOIN otlet.runtime_status rs
  ON rs.runtime_name = '$runtime_name'
 AND rs.model_name = '$strong_model_name';
")"
echo "malformed_schema_worker_contract=$malformed_schema_contract"
[ "$malformed_schema_contract" = "failed|true|failed|failed|direct_attempt_failed|failed|invalid_output_schema|0|ready|ready" ] || {
  echo "Expected malformed schema to produce a clean failed receipt and healthy worker, got $malformed_schema_contract" >&2
  exit 1
}

rss_budget_task="rss_budget_worker_demo"
cleanup_task "$rss_budget_task"
psql_exec -v task_name="$rss_budget_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'rss-budget-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":16,"reasoning":"off","inference_cache":false,"max_worker_rss_bytes":1}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_failed "$rss_budget_task" 1 240 1
rss_budget_contract="$(psql_value "
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = '$rss_budget_task'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, selection_reason, schema_validation_status, trace_summary
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
)
SELECT j.status || '|' ||
       (j.error LIKE 'linked worker RSS budget%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.selection_reason || '|' ||
       r.schema_validation_status || '|' ||
       COALESCE(r.trace_summary ->> 'stop_reason', '') || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM job_row j
CROSS JOIN receipt_row r
JOIN otlet.runtime_status rs
  ON rs.runtime_name = '$runtime_name'
 AND rs.model_name = '$strong_model_name';
")"
echo "rss_budget_worker_contract=$rss_budget_contract"
[ "$rss_budget_contract" = "failed|true|failed|failed|direct_attempt_failed|failed|worker_rss_budget_exceeded|0|ready|ready" ] || {
  echo "Expected RSS budget hit to produce a clean failed receipt and healthy worker, got $rss_budget_contract" >&2
  exit 1
}

oversized_prompt_task="oversized_prompt_worker_demo"
cleanup_task "$oversized_prompt_task"
psql_exec -v task_name="$oversized_prompt_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'oversized-prompt-1'::text AS subject_id,
           jsonb_build_object('payload', repeat('oversized prompt ', 50000)) AS input
  $source$::text,
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":4096,"reasoning":"off","inference_cache":false}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_failed "$oversized_prompt_task" 1 300 1
oversized_prompt_contract="$(psql_value "
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = '$oversized_prompt_task'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, selection_reason, schema_validation_status, trace_summary
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
)
SELECT j.status || '|' ||
       (j.error LIKE 'linked llama.cpp prompt has%exceeds context window%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.selection_reason || '|' ||
       r.schema_validation_status || '|' ||
       COALESCE(r.trace_summary ->> 'stop_reason', '') || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM job_row j
CROSS JOIN receipt_row r
JOIN otlet.runtime_status rs
  ON rs.runtime_name = '$runtime_name'
 AND rs.model_name = '$strong_model_name';
")"
echo "oversized_prompt_worker_contract=$oversized_prompt_contract"
require_regex "$oversized_prompt_contract" '^failed\|true\|failed\|failed\|direct_attempt_failed\|failed\|prompt(_and_generation)?_exceed(s_context_window|_context_window)\|0\|ready\|ready$' "Expected oversized prompt to produce a clean failed receipt and healthy worker"

cancel_decode_task="cancel_decode_worker_demo"
cleanup_task "$cancel_decode_task"
psql_exec -v task_name="$cancel_decode_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'cancel-decode-1'::text AS subject_id,
           jsonb_build_object('payload', repeat('cancel decode ', 1000)) AS input
  $source$::text,
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":512,"reasoning":"off","inference_cache":false}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
cancel_decode_job_id=""
for _ in $(seq 1 300); do
  cancel_decode_job_id="$(psql_value "SELECT id FROM otlet.jobs WHERE task_name = '$cancel_decode_task' AND status = 'running' ORDER BY id DESC LIMIT 1;")"
  if [ -n "$cancel_decode_job_id" ]; then
    psql_value "SELECT count(*) FROM otlet.cancel_job($cancel_decode_job_id, 'demo cancel mid-decode');" >/dev/null
    break
  fi
  cancel_decode_terminal="$(psql_value "SELECT COALESCE(max(status), '') FROM otlet.jobs WHERE task_name = '$cancel_decode_task' AND status IN ('complete','failed','canceled');")"
  if [ -n "$cancel_decode_terminal" ]; then
    echo "Expected cancel smoke to reach running state before terminal status, got $cancel_decode_terminal" >&2
    exit 1
  fi
  sleep 0.2
done
[ -n "$cancel_decode_job_id" ] || {
  echo "Timed out waiting for cancel smoke job to run" >&2
  exit 1
}
wait_task_failed "$cancel_decode_task" 1 240 1
cancel_decode_contract="$(psql_value "
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = '$cancel_decode_task'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, selection_reason, schema_validation_status
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
)
SELECT j.status || '|' ||
       (j.error = 'demo cancel mid-decode')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.selection_reason || '|' ||
       COALESCE(r.schema_validation_status, '') || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM job_row j
CROSS JOIN receipt_row r
JOIN otlet.runtime_status rs
  ON rs.runtime_name = '$runtime_name'
 AND rs.model_name = '$strong_model_name';
")"
echo "cancel_decode_worker_contract=$cancel_decode_contract"
[ "$cancel_decode_contract" = "canceled|true|canceled|failed|canceled||0|ready|ready" ] || {
  echo "Expected mid-decode cancel to produce a clean canceled receipt and healthy worker, got $cancel_decode_contract" >&2
  exit 1
}

invalid_json_task="invalid_json_safety_demo"
cleanup_task "$invalid_json_task"
psql_exec -v task_name="$invalid_json_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'invalid-json-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only.',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
);
CREATE TEMP TABLE invalid_json_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  VALUES (:'task_name', 'invalid-json-1', '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes')
  RETURNING id
)
SELECT id FROM inserted;
SELECT otlet.fail_job(
  id,
  'invalid model JSON: expected object',
  'not json',
  NULL,
  NULL,
  NULL,
  md5('not json'),
  now(),
  'failed',
  '{"schema_validation_status":"failed"}'::jsonb,
  :'model_name',
  'direct',
  'failed',
  'invalid_model_json'
)
FROM invalid_json_claim;
SQL
invalid_json_contract="$(psql_value "
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = '$invalid_json_task'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, schema_validation_status
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
),
materialized AS (
  SELECT count(*)::bigint AS materialization_count
  FROM otlet.semantic_materializations sm
  JOIN otlet.records rec ON rec.id = sm.record_id
  JOIN otlet.actions act ON act.id = rec.action_id
  WHERE act.job_id = (SELECT id FROM job_row)
)
SELECT j.status || '|' ||
       (j.error LIKE 'invalid model JSON:%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.schema_validation_status || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       (SELECT count(*) FROM otlet.actions WHERE job_id = j.id)::text || '|' ||
       (SELECT materialization_count FROM materialized)::text
FROM job_row j
CROSS JOIN receipt_row r;
")"
echo "invalid_json_safety_contract=$invalid_json_contract"
[ "$invalid_json_contract" = "failed|true|failed|failed|failed|0|0|0" ] || {
  echo "Expected invalid JSON to leave only a failed receipt, got $invalid_json_contract" >&2
  exit 1
}

cleanup_task "$output_envelope_task"
psql_exec -v task_name="$output_envelope_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'unused'::text AS subject_id, '{}'::jsonb AS input WHERE false
  $source$::text,
  'Return JSON only.',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
);

CREATE TEMP TABLE output_envelope_cases (
  subject_id text PRIMARY KEY,
  expected_error text NOT NULL,
  raw_output text NOT NULL
);

INSERT INTO output_envelope_cases (subject_id, expected_error, raw_output)
VALUES
  (
    'markdown-fence',
    $err$invalid model JSON: markdown fences are not allowed: ```json
{"output":{"status":"ok"},"actions":[]}
```$err$,
    $raw$```json
{"output":{"status":"ok"},"actions":[]}
```$raw$
  ),
  (
    'extra-top-level',
    'model JSON unsupported top-level key: extra',
    '{"output":{"status":"ok"},"actions":[],"extra":true}'
  ),
  (
    'non-object-action',
    'model JSON actions must contain objects',
    '{"output":{"status":"ok"},"actions":["bad"]}'
  );

WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  SELECT :'task_name', subject_id, '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes'
  FROM output_envelope_cases
  RETURNING id, subject_id
)
SELECT otlet.fail_job(
  inserted.id,
  cases.expected_error,
  cases.raw_output,
  NULL,
  NULL,
  NULL,
  md5(cases.raw_output),
  now(),
  'failed',
  '{}'::jsonb,
  :'model_name',
  'direct',
  'failed',
  'output_envelope_contract'
)
FROM inserted
JOIN output_envelope_cases cases USING (subject_id);
SQL
output_envelope_contract="$(psql_value "
WITH cases(subject_id, expected_error, raw_output) AS (
  VALUES
    (
      'markdown-fence',
      \$err\$invalid model JSON: markdown fences are not allowed: \`\`\`json
{\"output\":{\"status\":\"ok\"},\"actions\":[]}
\`\`\`\$err\$,
      \$raw\$\`\`\`json
{\"output\":{\"status\":\"ok\"},\"actions\":[]}
\`\`\`\$raw\$
    ),
    (
      'extra-top-level',
      'model JSON unsupported top-level key: extra',
      '{\"output\":{\"status\":\"ok\"},\"actions\":[],\"extra\":true}'
    ),
    (
      'non-object-action',
      'model JSON actions must contain objects',
      '{\"output\":{\"status\":\"ok\"},\"actions\":[\"bad\"]}'
    )
), rows AS (
  SELECT c.subject_id,
         c.expected_error,
         c.raw_output AS expected_raw_output,
         j.id AS job_id,
         j.status AS job_status,
         j.error AS job_error,
         r.status AS receipt_status,
         r.selection_status,
         r.schema_validation_status,
         r.error AS receipt_error,
         r.raw_output,
         r.raw_output_hash
  FROM cases c
  JOIN otlet.jobs j
    ON j.task_name = '$output_envelope_task'
   AND j.subject_id = c.subject_id
  JOIN otlet.inference_receipts r ON r.job_id = j.id
)
SELECT count(*) FILTER (WHERE subject_id = 'markdown-fence' AND job_error = expected_error AND receipt_error = expected_error)::text || '|' ||
       count(*) FILTER (WHERE subject_id = 'extra-top-level' AND job_error = expected_error AND receipt_error = expected_error)::text || '|' ||
       count(*) FILTER (WHERE subject_id = 'non-object-action' AND job_error = expected_error AND receipt_error = expected_error)::text || '|' ||
       bool_and(job_status = 'failed' AND receipt_status = 'failed' AND selection_status = 'failed' AND schema_validation_status = 'failed')::text || '|' ||
       bool_and(raw_output = expected_raw_output AND raw_output_hash = md5(expected_raw_output))::text || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id IN (SELECT job_id FROM rows))::text || '|' ||
       (SELECT count(*) FROM otlet.actions WHERE job_id IN (SELECT job_id FROM rows))::text
FROM rows;
")"
echo "output_envelope_contract=$output_envelope_contract"
[ "$output_envelope_contract" = "1|1|1|true|true|0|0" ] || {
  echo "Expected strict output envelope failures with raw output hashes, got $output_envelope_contract" >&2
  exit 1
}

hallucinated_action_task="hallucinated_action_safety_demo"
cleanup_task "$hallucinated_action_task"
psql_exec -v task_name="$hallucinated_action_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'hallucinated-action-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only.',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
);
CREATE TEMP TABLE hallucinated_action_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  VALUES (:'task_name', 'hallucinated-action-1', '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes')
  RETURNING id
)
SELECT id FROM inserted;
SELECT otlet.complete_job(
  id,
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[{"type":"invented_action","body":{"subject_id":"hallucinated-action-1","text":"no record"}}]}',
  '[{"type":"invented_action","body":{"subject_id":"hallucinated-action-1","text":"no record"}}]'::jsonb,
  NULL,
  NULL,
  NULL,
  md5('{"output":{"status":"ok"},"actions":[{"type":"invented_action","body":{"subject_id":"hallucinated-action-1","text":"no record"}}]}'),
  now(),
  '{"schema_validation_status":"passed"}'::jsonb,
  :'model_name'
)
FROM hallucinated_action_claim;
SQL
hallucinated_action_contract="$(psql_value "
WITH job_row AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name = '$hallucinated_action_task'
  ORDER BY id DESC
  LIMIT 1
)
SELECT (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE((SELECT status || '|' || COALESCE(error, '') FROM otlet.actions WHERE job_id = j.id ORDER BY id DESC LIMIT 1), '') || '|' ||
       (SELECT count(*) FROM otlet.records r JOIN otlet.actions a ON a.id = r.action_id WHERE a.job_id = j.id)::text
FROM job_row j;
")"
echo "hallucinated_action_safety_contract=$hallucinated_action_contract"
[ "$hallucinated_action_contract" = "1|rejected|unsupported action type|0" ] || {
  echo "Expected hallucinated action type to be rejected without a record, got $hallucinated_action_contract" >&2
  exit 1
}

cleanup_task "$custom_action_schema_task"
psql_exec -v task_name="$custom_action_schema_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
DELETE FROM otlet.action_type_schemas
WHERE action_type = 'custom_review';

INSERT INTO otlet.action_type_schemas (
  action_type,
  requires_approval,
  creates_record,
  payload_schema
)
VALUES (
  'custom_review',
  false,
  false,
  '{
    "required": ["subject_id", "severity"],
    "additionalProperties": false,
    "properties": {
      "subject_id": {"type": "string", "minLength": 1, "required_error": "custom_review missing subject_id"},
      "severity": {"type": "string", "enum": ["low", "high"], "enum_error": "custom_review severity must be low or high"},
      "reason": {"type": "string", "minLength": 1}
    }
  }'::jsonb
);

SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'custom-action-valid'::text AS subject_id, '{}'::jsonb AS input
    UNION ALL
    SELECT 'custom-action-invalid'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only.',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
);

CREATE TEMP TABLE custom_action_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  VALUES
    (:'task_name', 'custom-action-valid', '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes'),
    (:'task_name', 'custom-action-invalid', '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes')
  RETURNING id, subject_id
)
SELECT id, subject_id FROM inserted;

SELECT otlet.complete_job(
  id,
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[{"type":"custom_review","body":{"subject_id":"custom-action-valid","severity":"high","reason":"ok"}}]}',
  '[{"type":"custom_review","body":{"subject_id":"custom-action-valid","severity":"high","reason":"ok"}}]'::jsonb,
  NULL,
  NULL,
  NULL,
  md5('{"output":{"status":"ok"},"actions":[{"type":"custom_review","body":{"subject_id":"custom-action-valid","severity":"high","reason":"ok"}}]}'),
  now(),
  '{"schema_validation_status":"passed"}'::jsonb,
  :'model_name'
)
FROM custom_action_claim
WHERE subject_id = 'custom-action-valid';

SELECT otlet.complete_job(
  id,
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[{"type":"custom_review","body":{"subject_id":"custom-action-invalid","severity":"urgent","reason":"bad"}}]}',
  '[{"type":"custom_review","body":{"subject_id":"custom-action-invalid","severity":"urgent","reason":"bad"}}]'::jsonb,
  NULL,
  NULL,
  NULL,
  md5('{"output":{"status":"ok"},"actions":[{"type":"custom_review","body":{"subject_id":"custom-action-invalid","severity":"urgent","reason":"bad"}}]}'),
  now(),
  '{"schema_validation_status":"passed"}'::jsonb,
  :'model_name'
)
FROM custom_action_claim
WHERE subject_id = 'custom-action-invalid';
SQL
custom_action_schema_contract="$(psql_value "
SELECT count(*) FILTER (WHERE action_type = 'custom_review' AND status = 'proposed' AND approval_status = 'not_required' AND error IS NULL)::text || '|' ||
       count(*) FILTER (WHERE action_type = 'custom_review' AND status = 'rejected' AND error = 'custom_review severity must be low or high')::text || '|' ||
       count(*) FILTER (WHERE receipt_id IS NOT NULL AND output_id IS NOT NULL)::text || '|' ||
       (SELECT (payload_schema ? 'properties')::text FROM otlet.action_type_schemas WHERE action_type = 'custom_review')
FROM otlet.action_status
WHERE task_name = '$custom_action_schema_task';
")"
echo "custom_action_schema_contract=$custom_action_schema_contract"
[ "$custom_action_schema_contract" = "1|1|2|true" ] || {
  echo "Expected custom action payload schema accept/reject evidence, got $custom_action_schema_contract" >&2
  exit 1
}

log "Checking watch action allowlist"
psql_exec \
  -v watch_name="$action_allowlist_watch" \
  -v model_name="$strong_model_name" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_action_allowlist;
CREATE TABLE public.otlet_demo_action_allowlist (
  id text PRIMARY KEY,
  note text NOT NULL
);
INSERT INTO public.otlet_demo_action_allowlist VALUES ('allow-1', 'allowlist smoke row');

SELECT otlet.create_watch(
  :'watch_name',
  'row',
  'Return a decision and actions.',
  '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["flag", "pass"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 80}
    }
  }'::jsonb,
  :'model_name',
  'public.otlet_demo_action_allowlist'::regclass,
  'id',
  NULL,
  'action_allowlist_fact',
  '{"max_tokens":80,"reasoning":"off"}'::jsonb,
  '{}'::jsonb,
  '{"on_change":"mark_stale"}'::jsonb,
  ARRAY['review_flag'],
  'refresh_then_fail_closed',
  '{}'::jsonb,
  '{"answer_field":"decision","abstain_values":[],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);

WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  SELECT
    :'watch_name' || '_task',
    src.id,
    jsonb_build_object(
      '_otlet_mvcc', jsonb_build_object(
        'table', 'public.otlet_demo_action_allowlist',
        'subject_id', src.id,
        'ctid', src.ctid::text,
        'xmin', src.xmin::text
      ),
      'table', 'public.otlet_demo_action_allowlist',
      'row', to_jsonb(src)
    ),
    'running',
    1,
    now(),
    now() + interval '5 minutes'
  FROM public.otlet_demo_action_allowlist src
  RETURNING id
)
SELECT otlet.complete_job(
  job_id => id,
  output => '{"decision":"flag","confidence":"high","reason":"allowlist smoke"}'::jsonb,
  raw_output => '{"output":{"decision":"flag","confidence":"high","reason":"allowlist smoke"},"actions":[{"type":"note","body":{"subject_id":"allow-1","text":"not allowed"}}]}',
  actions => '[{"type":"note","body":{"subject_id":"allow-1","text":"not allowed"}}]'::jsonb,
  raw_output_hash => md5('{"output":{"decision":"flag","confidence":"high","reason":"allowlist smoke"},"actions":[{"type":"note","body":{"subject_id":"allow-1","text":"not allowed"}}]}'),
  started_at => now(),
  trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
  model_name => :'model_name'
)
FROM inserted;
SQL
action_allowlist_contract="$(psql_value "
SELECT count(*) FILTER (
         WHERE action_type = 'note'
           AND status = 'rejected'
           AND error = 'action type note is not allowed by watch'
       )::text || '|' ||
       count(*) FILTER (WHERE action_type = 'note' AND output_id IS NOT NULL AND receipt_id IS NOT NULL)::text || '|' ||
       (
         SELECT count(*)::text
         FROM otlet.records r
         JOIN otlet.actions a ON a.id = r.action_id
         JOIN otlet.jobs j ON j.id = a.job_id
         WHERE j.task_name = '$action_allowlist_task'
       )
FROM otlet.action_status
WHERE task_name = '$action_allowlist_task';
")"
echo "action_allowlist_contract=$action_allowlist_contract"
[ "$action_allowlist_contract" = "1|1|0" ] || {
  echo "Expected watch action allowlist to reject note without creating a record, got $action_allowlist_contract" >&2
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
SELECT 'direct_ask_cache_contract=' || s.inference_cache_hit::text || '|' ||
       COALESCE(s.inference_cache_reason, '') || '|' ||
       COALESCE(s.inference_cache_key_basis, '') || '|' ||
       (COALESCE(s.inference_cache_max_entries, 0) > 0)::text || '|' ||
       COALESCE(s.inference_cache_eviction_reason, '')
FROM otlet.inference_receipt_trace_status s
WHERE s.receipt_id = :'direct_ask_receipt_id'::bigint;
SQL
)"
printf '%s\n' "$direct_ask_output"
direct_ask_contract="$(sed -n 's/^direct_ask_contract=//p' <<<"$direct_ask_output")"
direct_ask_receipt_contract="$(sed -n 's/^direct_ask_receipt_contract=//p' <<<"$direct_ask_output")"
direct_ask_cache_contract="$(sed -n 's/^direct_ask_cache_contract=//p' <<<"$direct_ask_output")"
require_regex "$direct_ask_contract" '^review_payment\|[1-9][0-9]*\|[1-9][0-9]*$' "Expected direct ask to return review_payment with job and receipt ids"
require_regex "$direct_ask_receipt_contract" "^$strong_model_name\\|complete\\|passed\\|[1-9][0-9]*$" "Expected direct ask receipt evidence"
[ "$direct_ask_cache_contract" = "false|disabled_for_generation_trace|content_hash_contract_hash_model_fingerprint|true|none" ] || {
  echo "Expected direct ask trace to make cache-disabled-under-generation-trace explicit, got $direct_ask_cache_contract" >&2
  exit 1
}

log "Checking opt-in direct decision contract gate"
psql_exec \
  -v task_name="$direct_gate_task" \
  -v model_name="$strong_model_name" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_direct_gate;
CREATE TABLE public.otlet_demo_direct_gate (
  id text PRIMARY KEY,
  note text NOT NULL
);
INSERT INTO public.otlet_demo_direct_gate VALUES ('direct-gate-1', 'No decisive signal; send to review');

SELECT otlet.create_task(
  :'task_name',
  $query$
    SELECT
      src.id AS subject_id,
      jsonb_build_object('row', to_jsonb(src)) AS input
    FROM public.otlet_demo_direct_gate src
  $query$,
  'Return exactly one JSON object. output.decision must be unclear, output.confidence must be medium, output.reason must be short, and actions must be []. No markdown.',
  '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["unclear"]},
      "confidence": {"enum": ["medium"]},
      "reason": {"type": "string", "maxLength": 80}
    }
  }'::jsonb,
  :'model_name',
  '{"max_tokens":96,"reasoning":"off","inference_cache":false}'::jsonb,
  '{}'::jsonb,
  '{"answer_field":"decision","abstain_values":["unclear"],"confidence_field":"confidence","accepted_confidence":["high"],"enforce_on_direct":true}'::jsonb
);

SELECT otlet.run_task(:'task_name');
SQL
wait_task_failed "$direct_gate_task" 1 900 1
direct_gate_contract="$(psql_value "
SELECT j.status || '|' ||
       r.selection_status || '|' ||
       r.selection_reason || '|' ||
       r.schema_validation_status || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       (SELECT count(*) FROM otlet.review_queue WHERE receipt_id = r.id)::text || '|' ||
       COALESCE((SELECT output->>'decision' FROM otlet.review_queue WHERE receipt_id = r.id LIMIT 1), '')
FROM otlet.jobs j
JOIN otlet.inference_receipts r ON r.job_id = j.id
WHERE j.task_name = '$direct_gate_task'
ORDER BY j.id DESC, r.id DESC
LIMIT 1;
")"
echo "direct_gate_contract=$direct_gate_contract"
[ "$direct_gate_contract" = "failed|rejected|direct_rejected_by_decision_contract|passed|0|1|unclear" ] || {
  echo "Expected opt-in direct gate to reject an abstention without trusted output and expose review_queue, got $direct_gate_contract" >&2
  exit 1
}

log "Checking decision-contract prompt identity"
psql_exec \
  -v model_name="$strong_model_name" \
  -v preset_task="$prompt_identity_preset_task" \
  -v direct_task="$prompt_identity_direct_task" \
  -v entity_instruction="$entity_instruction" >/dev/null <<'SQL'
WITH params AS (
  SELECT
    '{
      "type": "object",
      "required": ["match", "confidence", "reason"],
      "additionalProperties": false,
      "properties": {
        "match": {"enum": ["same_entity", "different_entity", "unclear"]},
        "confidence": {"enum": ["low", "medium", "high"]},
        "reason": {"type": "string", "maxLength": 240}
      }
    }'::jsonb AS output_schema,
    '{"max_tokens":256,"reasoning":"off","inference_cache":false}'::jsonb AS runtime_options,
    '{"evidence_fields":["candidate_evidence"],"action_id_fields":{"left_id":"left_id","right_id":"right_id"}}'::jsonb AS input_shaping
)
SELECT otlet.create_task(
  :'preset_task',
  $source$
    SELECT 'prompt-identity'::text AS subject_id,
           jsonb_build_object(
             'left_id', 'vendor-1001',
             'right_id', 'vendor-42',
             'candidate_evidence', jsonb_build_object(
               'shared_stable_identifiers', jsonb_build_array('same tax id 36-9918821'),
               'conflicting_stable_identifiers', '[]'::jsonb,
               'weak_matching_signals', jsonb_build_array('similar name'),
               'missing_or_unknown_identifiers', '[]'::jsonb,
               'row_quality_warnings', '[]'::jsonb
             )
           ) AS input
  $source$::text,
  :'entity_instruction',
  output_schema,
  :'model_name',
  runtime_options,
  input_shaping,
  '{"preset":"entity_resolution_evidence_v1"}'::jsonb
)
FROM params;

WITH params AS (
  SELECT
    '{
      "type": "object",
      "required": ["match", "confidence", "reason"],
      "additionalProperties": false,
      "properties": {
        "match": {"enum": ["same_entity", "different_entity", "unclear"]},
        "confidence": {"enum": ["low", "medium", "high"]},
        "reason": {"type": "string", "maxLength": 240}
      }
    }'::jsonb AS output_schema,
    '{"max_tokens":256,"reasoning":"off","inference_cache":false}'::jsonb AS runtime_options,
    '{"evidence_fields":["candidate_evidence"],"action_id_fields":{"left_id":"left_id","right_id":"right_id"}}'::jsonb AS input_shaping
)
SELECT otlet.create_task(
  :'direct_task',
  $source$
    SELECT 'prompt-identity'::text AS subject_id,
           jsonb_build_object(
             'left_id', 'vendor-1001',
             'right_id', 'vendor-42',
             'candidate_evidence', jsonb_build_object(
               'shared_stable_identifiers', jsonb_build_array('same tax id 36-9918821'),
               'conflicting_stable_identifiers', '[]'::jsonb,
               'weak_matching_signals', jsonb_build_array('similar name'),
               'missing_or_unknown_identifiers', '[]'::jsonb,
               'row_quality_warnings', '[]'::jsonb
             )
           ) AS input
  $source$::text,
  :'entity_instruction',
  output_schema,
  :'model_name',
  runtime_options,
  input_shaping,
  (SELECT decision_contract FROM otlet.decision_rule_presets WHERE name = 'entity_resolution_evidence_v1')
)
FROM params;

SELECT otlet.run_task(:'preset_task');
SELECT otlet.run_task(:'direct_task');
SQL
wait_task_complete "$prompt_identity_preset_task" 1 900 1
wait_task_complete "$prompt_identity_direct_task" 1 900 1
prompt_identity_contract="$(psql_value "
WITH receipts AS (
  SELECT task_name, prompt_hash, status, schema_validation_status
  FROM otlet.inference_receipt_trace_status
  WHERE task_name IN ('$prompt_identity_preset_task', '$prompt_identity_direct_task')
)
SELECT count(*)::text || '|' ||
       count(DISTINCT prompt_hash)::text || '|' ||
       bool_and(status = 'complete')::text || '|' ||
       bool_and(schema_validation_status = 'passed')::text
FROM receipts;
")"
echo "prompt_identity_contract=$prompt_identity_contract"
[ "$prompt_identity_contract" = "2|1|true|true" ] || {
  echo "Expected preset and expanded decision contract to produce byte-identical prompts, got $prompt_identity_contract" >&2
  exit 1
}

psql_exec \
  -v model_name="$strong_model_name" \
  -v raw_task="input_shape_mvcc_raw_demo" \
  -v hand_task="input_shape_mvcc_hand_demo" \
  -v trunc_task="input_shape_truncate_demo" >/dev/null <<'SQL'
WITH params AS (
  SELECT
    'Return status ok with confidence high and no actions.'::text AS instruction,
    '{"type":"object","required":["status","confidence"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]},"confidence":{"enum":["high"]}}}'::jsonb AS output_schema,
    '{"max_tokens":64,"reasoning":"off","inference_cache":false}'::jsonb AS runtime_options
)
SELECT otlet.create_task(
  :'raw_task',
  $source$
    SELECT 'shape-mvcc'::text AS subject_id,
           '{"_otlet_mvcc":{"table":"public.shape","subject_id":"shape-mvcc","ctid":"(0,1)","xmin":"7"},"row":{"status":"ok"}}'::jsonb AS input
  $source$::text,
  instruction,
  output_schema,
  :'model_name',
  runtime_options,
  '{}'::jsonb,
  '{"answer_field":"status","abstain_values":[],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
)
FROM params;

WITH params AS (
  SELECT
    'Return status ok with confidence high and no actions.'::text AS instruction,
    '{"type":"object","required":["status","confidence"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]},"confidence":{"enum":["high"]}}}'::jsonb AS output_schema,
    '{"max_tokens":64,"reasoning":"off","inference_cache":false}'::jsonb AS runtime_options
)
SELECT otlet.create_task(
  :'hand_task',
  $source$
    SELECT 'shape-mvcc'::text AS subject_id,
           '{"row":{"status":"ok"}}'::jsonb AS input
  $source$::text,
  instruction,
  output_schema,
  :'model_name',
  runtime_options,
  '{}'::jsonb,
  '{"answer_field":"status","abstain_values":[],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
)
FROM params;

SELECT otlet.create_task(
  :'trunc_task',
  $source$
    SELECT 'shape-truncate'::text AS subject_id,
           jsonb_build_object('row', jsonb_build_object('payload', repeat('oversized input ', 400))) AS input
  $source$::text,
  'If input._otlet_input_truncated is true, return status truncated with confidence high and no actions. Return JSON only.',
  '{"type":"object","required":["status","confidence"],"additionalProperties":false,"properties":{"status":{"enum":["truncated"]},"confidence":{"enum":["high"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":64,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"max_shaped_input_bytes":256}'::jsonb,
  '{"answer_field":"status","abstain_values":["truncated"],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);

SELECT otlet.run_task(:'raw_task');
SELECT otlet.run_task(:'hand_task');
SELECT otlet.run_task(:'trunc_task');
SQL
wait_task_complete "input_shape_mvcc_raw_demo" 1 900 1
wait_task_complete "input_shape_mvcc_hand_demo" 1 900 1
wait_task_complete "input_shape_truncate_demo" 1 900 1
input_shape_mvcc_contract="$(psql_value "
WITH receipts AS (
  SELECT task_name, prompt_hash, input_shaping_applied
  FROM otlet.inference_receipt_trace_status
  WHERE task_name IN ('input_shape_mvcc_raw_demo', 'input_shape_mvcc_hand_demo')
)
SELECT count(*)::text || '|' ||
       count(DISTINCT prompt_hash)::text || '|' ||
       bool_or(input_shaping_applied)::text || '|' ||
       (NOT (otlet.semantic_shaped_input('{\"_otlet_mvcc\":{\"xmin\":\"7\"},\"row\":{\"status\":\"ok\"}}'::jsonb, '{}'::jsonb) ? '_otlet_mvcc'))::text || '|' ||
       (
         otlet.semantic_content_hash('{\"_otlet_mvcc\":{\"xmin\":\"7\"},\"row\":{\"status\":\"ok\"}}'::jsonb, '{}'::jsonb)
         = otlet.semantic_content_hash('{\"row\":{\"status\":\"ok\"}}'::jsonb, '{}'::jsonb)
       )::text
FROM receipts;
")"
echo "input_shape_mvcc_contract=$input_shape_mvcc_contract"
[ "$input_shape_mvcc_contract" = "2|1|true|true|true" ] || {
  echo "Expected MVCC stripping to produce equal prompt/content hashes, got $input_shape_mvcc_contract" >&2
  exit 1
}
input_shape_truncate_contract="$(psql_value "
SELECT input_truncated::text || '|' ||
       input_shaping_applied::text || '|' ||
       (original_shaped_input_bytes > max_shaped_input_bytes)::text || '|' ||
       max_shaped_input_bytes::text || '|' ||
       (shaped_input_bytes > 0)::text
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'input_shape_truncate_demo'
ORDER BY receipt_id DESC
LIMIT 1;
")"
echo "input_shape_truncate_contract=$input_shape_truncate_contract"
[ "$input_shape_truncate_contract" = "true|true|true|256|true" ] || {
  echo "Expected oversized shaped input truncation evidence, got $input_shape_truncate_contract" >&2
  exit 1
}

psql_exec \
  -v model_name="$strong_model_name" \
  -v verbatim_task="$prompt_diet_verbatim_task" \
  -v compact_task="$prompt_diet_compact_task" >/dev/null <<'SQL'
WITH params AS (
  SELECT
    'Return every output field with the exact obvious value from its enum: status ok, priority low, category schema_prompt, confidence high, phase alpha, queue primary, policy default, outcome accepted, route review, owner ops, and reason ok. Use no actions.'::text AS instruction,
    $source$
      SELECT 'prompt-diet'::text AS subject_id, '{}'::jsonb AS input
    $source$::text AS input_query,
    '{
      "type": "object",
      "title": "Prompt diet smoke schema",
      "description": "Verbose JSON Schema metadata that should not be needed in the model prompt because the compact renderer keeps only the field names, required markers, types, and enum values.",
      "required": ["status", "priority", "category", "confidence", "phase", "queue", "policy", "outcome", "route", "owner", "reason"],
      "additionalProperties": false,
      "properties": {
        "status": {"description": "Fixed smoke status chosen by the instruction", "enum": ["ok", "needs_review"]},
        "priority": {"description": "Fixed smoke priority chosen by the instruction", "enum": ["low", "medium", "high"]},
        "category": {"description": "Fixed smoke category chosen by the instruction", "enum": ["schema_prompt", "other"]},
        "confidence": {"description": "Fixed smoke confidence chosen by the instruction", "enum": ["low", "medium", "high"]},
        "phase": {"description": "Fixed smoke phase chosen by the instruction", "enum": ["alpha", "beta", "ga"]},
        "queue": {"description": "Fixed smoke queue chosen by the instruction", "enum": ["primary", "secondary"]},
        "policy": {"description": "Fixed smoke policy chosen by the instruction", "enum": ["default", "override"]},
        "outcome": {"description": "Fixed smoke outcome chosen by the instruction", "enum": ["accepted", "rejected"]},
        "route": {"description": "Fixed smoke route chosen by the instruction", "enum": ["review", "archive"]},
        "owner": {"description": "Fixed smoke owner chosen by the instruction", "enum": ["ops", "finance"]},
        "reason": {"description": "Short smoke reason", "type": "string", "maxLength": 240}
      }
    }'::jsonb AS schema
)
SELECT otlet.create_task(
  :'verbatim_task',
  input_query,
  instruction,
  schema,
  :'model_name',
  '{"max_tokens":192,"reasoning":"off","schema_prompt":"verbatim","generation_trace":true,"generation_trace_max_tokens":4,"generation_trace_top_k":1}'::jsonb
)
FROM params;

WITH params AS (
  SELECT
    'Return every output field with the exact obvious value from its enum: status ok, priority low, category schema_prompt, confidence high, phase alpha, queue primary, policy default, outcome accepted, route review, owner ops, and reason ok. Use no actions.'::text AS instruction,
    $source$
      SELECT 'prompt-diet'::text AS subject_id, '{}'::jsonb AS input
    $source$::text AS input_query,
    '{
      "type": "object",
      "title": "Prompt diet smoke schema",
      "description": "Verbose JSON Schema metadata that should not be needed in the model prompt because the compact renderer keeps only the field names, required markers, types, and enum values.",
      "required": ["status", "priority", "category", "confidence", "phase", "queue", "policy", "outcome", "route", "owner", "reason"],
      "additionalProperties": false,
      "properties": {
        "status": {"description": "Fixed smoke status chosen by the instruction", "enum": ["ok", "needs_review"]},
        "priority": {"description": "Fixed smoke priority chosen by the instruction", "enum": ["low", "medium", "high"]},
        "category": {"description": "Fixed smoke category chosen by the instruction", "enum": ["schema_prompt", "other"]},
        "confidence": {"description": "Fixed smoke confidence chosen by the instruction", "enum": ["low", "medium", "high"]},
        "phase": {"description": "Fixed smoke phase chosen by the instruction", "enum": ["alpha", "beta", "ga"]},
        "queue": {"description": "Fixed smoke queue chosen by the instruction", "enum": ["primary", "secondary"]},
        "policy": {"description": "Fixed smoke policy chosen by the instruction", "enum": ["default", "override"]},
        "outcome": {"description": "Fixed smoke outcome chosen by the instruction", "enum": ["accepted", "rejected"]},
        "route": {"description": "Fixed smoke route chosen by the instruction", "enum": ["review", "archive"]},
        "owner": {"description": "Fixed smoke owner chosen by the instruction", "enum": ["ops", "finance"]},
        "reason": {"description": "Short smoke reason", "type": "string", "maxLength": 240}
      }
    }'::jsonb AS schema
)
SELECT otlet.create_task(
  :'compact_task',
  input_query,
  instruction,
  schema,
  :'model_name',
  '{"max_tokens":192,"reasoning":"off","schema_prompt":"compact","generation_trace":true,"generation_trace_max_tokens":4,"generation_trace_top_k":1}'::jsonb
)
FROM params;

SELECT otlet.run_task(:'verbatim_task');
SELECT otlet.run_task(:'compact_task');
SQL
wait_task_complete "$prompt_diet_verbatim_task" 1 900 1
wait_task_complete "$prompt_diet_compact_task" 1 900 1
prompt_diet_contract="$(psql_value "
WITH receipt_pairs AS (
  SELECT
    max(prompt_tokens) FILTER (WHERE task_name = '$prompt_diet_verbatim_task') AS verbatim_tokens,
    max(prompt_tokens) FILTER (WHERE task_name = '$prompt_diet_compact_task') AS compact_tokens,
    count(*) FILTER (WHERE task_name = '$prompt_diet_verbatim_task') AS verbatim_receipts,
    count(*) FILTER (WHERE task_name = '$prompt_diet_compact_task') AS compact_receipts,
    bool_and(schema_validation_status = 'passed') AS schema_passed
  FROM otlet.inference_receipt_trace_status
  WHERE task_name IN ('$prompt_diet_verbatim_task', '$prompt_diet_compact_task')
)
SELECT (verbatim_receipts = 1)::text || '|' ||
       (compact_receipts = 1)::text || '|' ||
       verbatim_tokens::text || '|' ||
       compact_tokens::text || '|' ||
       (compact_tokens < verbatim_tokens)::text || '|' ||
       schema_passed::text
FROM receipt_pairs;
")"
echo "prompt_diet_contract=$prompt_diet_contract"
require_regex "$prompt_diet_contract" '^true\|true\|[0-9]+\|[0-9]+\|true\|true$' "Expected compact schema prompt to reduce prompt tokens with schema-valid direct outputs"

prompt_diet_requeued="$(psql_value "SELECT otlet.run_task('$prompt_diet_compact_task');")"
[ "$prompt_diet_requeued" = "1" ] || {
  echo "Expected direct run_task to re-enqueue one completed compact prompt subject, got $prompt_diet_requeued" >&2
  exit 1
}
wait_task_complete "$prompt_diet_compact_task" 2 900 1
run_task_reenqueue_contract="$(psql_value "
SELECT count(*)::text || '|' ||
       count(DISTINCT subject_id)::text || '|' ||
       count(*) FILTER (WHERE status = 'complete')::text
FROM otlet.jobs
WHERE task_name = '$prompt_diet_compact_task';
")"
echo "run_task_reenqueue_contract=$run_task_reenqueue_contract"
[ "$run_task_reenqueue_contract" = "2|1|2" ] || {
  echo "Expected direct run_task rerun to create a second completed job for the same subject, got $run_task_reenqueue_contract" >&2
  exit 1
}

prefix_kv_off_task="prefix_kv_off_demo"
prefix_kv_on_task="prefix_kv_on_demo"
prefix_kv_mismatch_task="prefix_kv_mismatch_demo"
cleanup_task "$prefix_kv_off_task"
cleanup_task "$prefix_kv_on_task"
cleanup_task "$prefix_kv_mismatch_task"

psql_exec \
  -v model_name="$strong_model_name" \
  -v off_task="$prefix_kv_off_task" >/dev/null <<'SQL'
WITH params AS (
  SELECT
    'For every input row, output status ok, confidence high, and reason prefix kv reuse. Use no actions. Do not copy input fields. Return JSON only.'::text AS instruction,
    $source$
      SELECT 'prefix-kv-' || i::text AS subject_id,
             jsonb_build_object('row_id', i, 'signal', 'constant') AS input
      FROM generate_series(1, 8) AS g(i)
    $source$::text AS input_query,
    '{
      "type": "object",
      "required": ["status", "confidence", "reason"],
      "additionalProperties": false,
      "properties": {
        "status": {"enum": ["ok"]},
        "confidence": {"enum": ["high"]},
        "reason": {"type": "string", "maxLength": 80}
      }
    }'::jsonb AS schema
)
SELECT otlet.create_task(
  :'off_task',
  input_query,
  instruction,
  schema,
  :'model_name',
  '{"max_tokens":96,"reasoning":"off","inference_cache":false,"prefix_kv_reuse":false}'::jsonb
)
FROM params;

SELECT otlet.run_task(:'off_task');
SQL
wait_task_complete "$prefix_kv_off_task" 8 1800 1

psql_exec \
  -v model_name="$strong_model_name" \
  -v on_task="$prefix_kv_on_task" >/dev/null <<'SQL'
WITH params AS (
  SELECT
    'For every input row, output status ok, confidence high, and reason prefix kv reuse. Use no actions. Do not copy input fields. Return JSON only.'::text AS instruction,
    $source$
      SELECT 'prefix-kv-' || i::text AS subject_id,
             jsonb_build_object('row_id', i, 'signal', 'constant') AS input
      FROM generate_series(1, 8) AS g(i)
    $source$::text AS input_query,
    '{
      "type": "object",
      "required": ["status", "confidence", "reason"],
      "additionalProperties": false,
      "properties": {
        "status": {"enum": ["ok"]},
        "confidence": {"enum": ["high"]},
        "reason": {"type": "string", "maxLength": 80}
      }
    }'::jsonb AS schema
)
SELECT otlet.create_task(
  :'on_task',
  input_query,
  instruction,
  schema,
  :'model_name',
  '{"max_tokens":96,"reasoning":"off","inference_cache":false,"prefix_kv_reuse":true}'::jsonb
)
FROM params;

SELECT otlet.run_task(:'on_task');
SQL
wait_task_complete "$prefix_kv_on_task" 8 1800 1

psql_exec \
  -v model_name="$strong_model_name" \
  -v mismatch_task="$prefix_kv_mismatch_task" >/dev/null <<'SQL'
WITH params AS (
  SELECT
    'For this fallback smoke, output status ok, confidence high, and reason prefix mismatch fallback. Use no actions. Return JSON only.'::text AS instruction,
    $source$
      SELECT 'prefix-kv-mismatch'::text AS subject_id,
             jsonb_build_object('row_id', 99, 'signal', 'different-prefix') AS input
    $source$::text AS input_query,
    '{
      "type": "object",
      "required": ["status", "confidence", "reason"],
      "additionalProperties": false,
      "properties": {
        "status": {"enum": ["ok"]},
        "confidence": {"enum": ["high"]},
        "reason": {"type": "string", "maxLength": 80}
      }
    }'::jsonb AS schema
)
SELECT otlet.create_task(
  :'mismatch_task',
  input_query,
  instruction,
  schema,
  :'model_name',
  '{"max_tokens":96,"reasoning":"off","inference_cache":false,"prefix_kv_reuse":true}'::jsonb
)
FROM params;

SELECT otlet.run_task(:'mismatch_task');
SQL
wait_task_complete "$prefix_kv_mismatch_task" 1 900 1

prefix_kv_contract="$(psql_value "
WITH off_receipts AS (
  SELECT subject_id, receipt_raw_output_hash AS raw_output_hash
  FROM otlet.inference_receipt_trace_status
  WHERE task_name = '$prefix_kv_off_task'
    AND status = 'complete'
),
on_receipts AS (
  SELECT
    subject_id,
    receipt_raw_output_hash AS raw_output_hash,
    prompt_prefix_hash,
    prompt_prefix_reused_tokens,
    prompt_prefix_reuse_status,
    worker_process_rss_bytes
  FROM otlet.inference_receipt_trace_status
  WHERE task_name = '$prefix_kv_on_task'
    AND status = 'complete'
),
off_batch AS (
  SELECT detail
  FROM otlet.worker_events
  WHERE event_type = 'worker_batch_finished'
    AND detail ->> 'task_name' = '$prefix_kv_off_task'
  ORDER BY id DESC
  LIMIT 1
),
on_batch AS (
  SELECT detail
  FROM otlet.worker_events
  WHERE event_type = 'worker_batch_finished'
    AND detail ->> 'task_name' = '$prefix_kv_on_task'
  ORDER BY id DESC
  LIMIT 1
),
mismatch AS (
  SELECT prompt_prefix_reuse_status, prompt_prefix_reuse_reason
  FROM otlet.inference_receipt_trace_status
  WHERE task_name = '$prefix_kv_mismatch_task'
  ORDER BY receipt_id DESC
  LIMIT 1
),
batch_numbers AS (
  SELECT
    COALESCE((SELECT (detail ->> 'batch_ms')::bigint FROM off_batch), 0) AS off_ms,
    COALESCE((SELECT (detail ->> 'batch_ms')::bigint FROM on_batch), 0) AS on_ms,
    COALESCE((SELECT (detail ->> 'prompt_prefix_reused_tokens')::bigint FROM off_batch), 0) AS off_reused,
    COALESCE((SELECT (detail ->> 'prompt_prefix_reused_tokens')::bigint FROM on_batch), 0) AS on_reused
)
SELECT
  ((SELECT count(*) FROM off_receipts) = 8)::text || '|' ||
  ((SELECT count(*) FROM on_receipts) = 8)::text || '|' ||
  COALESCE((SELECT bool_and(o.raw_output_hash = n.raw_output_hash) FROM off_receipts o JOIN on_receipts n USING (subject_id)), false)::text || '|' ||
  ((SELECT count(*) FROM on_receipts WHERE prompt_prefix_reuse_status = 'hit' AND prompt_prefix_reused_tokens > 0) >= 7)::text || '|' ||
  ((SELECT COALESCE(sum(prompt_prefix_reused_tokens), 0) FROM on_receipts) > 0)::text || '|' ||
  ((SELECT count(DISTINCT prompt_prefix_hash) FROM on_receipts) = 1)::text || '|' ||
  (COALESCE((SELECT min(worker_process_rss_bytes) FROM on_receipts), 0) > 0)::text || '|' ||
  (SELECT (off_reused = 0)::text || '|' || (on_reused > 0)::text || '|' || (off_ms > 0 AND on_ms > 0)::text || '|' || ((off_ms - on_ms) > 0)::text || '|' || off_ms::text || '|' || on_ms::text || '|' || (off_ms - on_ms)::text FROM batch_numbers) || '|' ||
  COALESCE((SELECT (prompt_prefix_reuse_status = 'fallback' AND prompt_prefix_reuse_reason = 'prefix_hash_mismatch_full_decode')::text FROM mismatch), 'false');
")"
echo "prefix_kv_contract=$prefix_kv_contract"
require_regex "$prefix_kv_contract" '^true\|true\|true\|true\|true\|true\|true\|true\|true\|true\|true\|[1-9][0-9]*\|[1-9][0-9]*\|[1-9][0-9]*\|true$' "Expected prefix KV reuse to be byte-identical, faster, RSS-visible, and mismatch-safe"

json_mask_task="json_mask_adversarial_demo"
cleanup_task "$json_mask_task"
psql_exec \
  -v model_name="$strong_model_name" \
  -v task_name="$json_mask_task" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'json-mask-1'::text AS subject_id,
           '{"request":"Answer in markdown prose before the JSON object."}'::jsonb AS input
  $source$::text,
  'Adversarial smoke: answer in markdown prose with a heading and bullets before any JSON. The required final data is status ok, confidence high, and reason masked json. Use no actions.',
  '{
    "type": "object",
    "required": ["status", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "status": {"enum": ["ok"]},
      "confidence": {"enum": ["high"]},
      "reason": {"type": "string", "maxLength": 80}
    }
  }'::jsonb,
  :'model_name',
  '{"max_tokens":128,"reasoning":"off","inference_cache":false,"json_logit_mask":true}'::jsonb
);

SELECT otlet.run_task(:'task_name');
SQL
wait_task_complete "$json_mask_task" 1 900 1
json_mask_contract="$(psql_value "
SELECT
  r.status || '|' ||
  r.schema_validation_status || '|' ||
  COALESCE(s.decode_constraint, '') || '|' ||
  s.json_logit_mask_enabled::text || '|' ||
  (COALESCE(s.json_logit_mask_sampled_tokens, 0) > 0)::text || '|' ||
  (COALESCE(s.json_logit_mask_candidates_checked, 0) >= COALESCE(s.json_logit_mask_sampled_tokens, 0))::text || '|' ||
  (COALESCE(s.json_logit_mask_fallbacks, 0) = 0)::text || '|' ||
  (COALESCE(s.json_logit_mask_overhead_ms, 0) >= 0)::text || '|' ||
  (r.output ->> 'status') || '|' ||
  (r.output ->> 'confidence')
FROM otlet.runs r
JOIN otlet.inference_receipt_trace_status s USING (receipt_id)
WHERE r.task_name = '$json_mask_task'
ORDER BY r.receipt_id DESC
LIMIT 1;
")"
echo "json_mask_contract=$json_mask_contract"
[ "$json_mask_contract" = "complete|passed|json_logit_mask_v1|true|true|true|true|true|ok|high" ] || {
  echo "Expected JSON logit mask smoke to complete with schema-valid JSON and mask trace evidence, got $json_mask_contract" >&2
  exit 1
}

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
       count(a.action_id) FILTER (WHERE a.action_type = 'review_flag' AND a.error IS NULL)::text || '|' ||
       (
         SELECT (count(*) FILTER (WHERE s.freshness_basis = 'content_hash_match') >= 1)::text
         FROM otlet.inference_receipt_trace_status s
         WHERE s.task_name = '$row_triage_task'
           AND s.accepted
       )
FROM otlet.runs r
LEFT JOIN otlet.action_status a ON a.job_id = r.job_id
WHERE r.task_name = '$row_triage_task';
")"
echo "row_triage_contract=$row_triage_contract"
[ "$row_triage_contract" = "1|flag|high|1|1|true" ] || {
  echo "Expected non-ER triage task to produce one flagged output and one valid review action, got $row_triage_contract" >&2
  exit 1
}

row_triage_action_id="$(psql_value "
SELECT min(action_id)
FROM otlet.action_status
WHERE task_name = '$row_triage_task'
  AND action_type = 'review_flag'
  AND error IS NULL;
")"
[ -n "$row_triage_action_id" ] || {
  echo "Expected row triage review action id" >&2
  exit 1
}
psql_exec >/dev/null <<SQL
SELECT * FROM otlet.label_action($row_triage_action_id, label_source => 'approved_action');
SQL
row_eval_label_contract="$(psql_value "
WITH status AS (
  SELECT *
  FROM otlet.eval_label_status
  WHERE action_id = $row_triage_action_id
), exported AS (
  SELECT *
  FROM otlet.export_eval_cases(50)
  WHERE action_id = $row_triage_action_id
)
SELECT count(*)::text || '|' ||
       COALESCE(max(status.expected_answer), '') || '|' ||
       COALESCE(max(status.observed_answer), '') || '|' ||
       COALESCE(max(exported.expected_answer), '') || '|' ||
       COALESCE(max(exported.case_kind), '')
FROM status, exported;
")"
echo "row_eval_label_contract=$row_eval_label_contract"
[ "$row_eval_label_contract" = "1|flag|flag|flag|positive" ] || {
  echo "Expected row triage eval label/export to use decision as expected_answer, got $row_eval_label_contract" >&2
  exit 1
}
row_eval_label_reject_contract="$(
  psql_exec -qAt -v action_id="$row_triage_action_id" <<'SQL'
CREATE TEMP TABLE eval_label_reject_params(action_id bigint);
CREATE TEMP TABLE eval_label_reject_result(message text);
INSERT INTO eval_label_reject_params VALUES (:action_id);
DO $$
DECLARE
  target_action_id bigint;
BEGIN
  SELECT action_id INTO target_action_id FROM eval_label_reject_params;
  BEGIN
    PERFORM * FROM otlet.label_action(target_action_id, expected_answer => 'same_entity');
    INSERT INTO eval_label_reject_result VALUES ('no error');
  EXCEPTION WHEN others THEN
    INSERT INTO eval_label_reject_result VALUES (SQLERRM);
  END;
END $$;
SELECT message FROM eval_label_reject_result;
SQL
)"
echo "row_eval_label_reject_contract=$row_eval_label_reject_contract"
require_contains "$row_eval_label_reject_contract" "otlet expected_answer same_entity is not valid for task $row_triage_task field decision" "Expected invalid expected_answer to be rejected against task enum"

row_review_queue_contract="$(psql_value "
SELECT count(*)::text || '|' ||
       COALESCE(max(queue_kind), '') || '|' ||
       COALESCE(max(watch_name), '') || '|' ||
       COALESCE(max(source_stale::text), '') || '|' ||
       (max(receipt_id) IS NOT NULL)::text
FROM otlet.review_queue
WHERE action_id = $row_triage_action_id;
")"
echo "row_review_queue_contract=$row_review_queue_contract"
[ "$row_review_queue_contract" = "1|review_flag|$row_triage_watch|false|true" ] || {
  echo "Expected row review action in review_queue with receipt and fresh source identity, got $row_review_queue_contract" >&2
  exit 1
}
psql_exec >/dev/null <<SQL
SELECT * FROM otlet.correct_action(
  $row_triage_action_id,
  '{"expected_answer":"pass","expected_confidence":"high","expected_action_type":"review_flag"}'::jsonb,
  'demo correction'
);
SQL
row_correction_contract="$(psql_value "
SELECT a.status || '|' ||
       a.approval_status || '|' ||
       (SELECT count(*) FROM otlet.eval_labels WHERE action_id = $row_triage_action_id AND label_source = 'manual_correction')::text || '|' ||
       (SELECT count(*) FROM otlet.export_eval_cases(50) WHERE action_id = $row_triage_action_id AND case_kind = 'gold')::text || '|' ||
       (SELECT count(*) FROM otlet.review_queue WHERE action_id = $row_triage_action_id)::text
FROM otlet.actions a
WHERE a.id = $row_triage_action_id;
")"
echo "row_correction_contract=$row_correction_contract"
[ "$row_correction_contract" = "rejected|rejected|1|1|0" ] || {
  echo "Expected correction to reject action, write gold label, and remove review queue row, got $row_correction_contract" >&2
  exit 1
}

log "Running numeric evidence triage watch"
psql_exec \
  -v model_name="$strong_model_name" \
  -v numeric_triage_watch="$numeric_triage_watch" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_numeric_triage;
CREATE TABLE public.otlet_demo_numeric_triage (
  id text PRIMARY KEY,
  amount_cents integer NOT NULL,
  limit_cents integer NOT NULL,
  note text NOT NULL
);

SELECT otlet.create_watch(
  :'numeric_triage_watch',
  'row',
  'Classify one numeric control row. Use only input.row.amount_cents and input.row.limit_cents. If amount_cents is greater than limit_cents, output decision flag with confidence high and exactly one review_flag action. The review_flag body must have severity high and a short reason. Return JSON only.',
  '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["flag"]},
      "confidence": {"enum": ["high"]},
      "reason": {"type": "string", "maxLength": 120}
    }
  }'::jsonb,
  :'model_name',
  'public.otlet_demo_numeric_triage'::regclass,
  'id',
  NULL,
  'numeric_triage_fact',
  '{"max_tokens":160,"reasoning":"off","inference_cache":true}'::jsonb,
  '{}'::jsonb,
  '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  ARRAY['review_flag'],
  'refresh_then_fail_closed',
  '{}'::jsonb,
  '{"answer_field":"decision","abstain_values":[],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);

INSERT INTO public.otlet_demo_numeric_triage
VALUES (
  'numeric-1',
  25000,
  10000,
  'Payment exceeds the declared approval threshold'
);
SQL
wait_task_complete "$numeric_triage_task" 1 900 1
numeric_triage_action_id="$(psql_value "
SELECT min(action_id)
FROM otlet.action_status
WHERE task_name = '$numeric_triage_task'
  AND action_type = 'review_flag'
  AND error IS NULL;
")"
[ -n "$numeric_triage_action_id" ] || {
  echo "Expected numeric triage review_flag action" >&2
  exit 1
}
numeric_triage_contract="$(psql_value "
SELECT r.status || '|' ||
       COALESCE(r.output->>'decision', '') || '|' ||
       COALESCE(r.output->>'confidence', '') || '|' ||
       (r.output_id IS NOT NULL)::text || '|' ||
       (msa.receipt_id IS NOT NULL)::text || '|' ||
       COALESCE(a.action_type, '') || '|' ||
       (a.output_id IS NOT NULL)::text || '|' ||
       (rq.receipt_id IS NOT NULL)::text || '|' ||
       COALESCE(rq.queue_kind, '')
FROM otlet.runs r
JOIN otlet.model_selection_attempts msa ON msa.job_id = r.job_id
JOIN otlet.action_status a
  ON a.job_id = r.job_id
 AND a.action_type = 'review_flag'
LEFT JOIN otlet.review_queue rq ON rq.action_id = a.action_id
WHERE r.task_name = '$numeric_triage_task'
ORDER BY r.job_id DESC
LIMIT 1;
")"
echo "numeric_triage_contract=$numeric_triage_contract"
[ "$numeric_triage_contract" = "complete|flag|high|true|true|review_flag|true|true|review_flag" ] || {
  echo "Expected numeric triage surfaces to render without NULL surprises, got $numeric_triage_contract" >&2
  exit 1
}
psql_exec >/dev/null <<SQL
SELECT * FROM otlet.label_action($numeric_triage_action_id, label_source => 'approved_action');
SQL
numeric_triage_label_contract="$(psql_value "
WITH status AS (
  SELECT *
  FROM otlet.eval_label_status
  WHERE action_id = $numeric_triage_action_id
), exported AS (
  SELECT *
  FROM otlet.export_eval_cases(50)
  WHERE action_id = $numeric_triage_action_id
)
SELECT count(*)::text || '|' ||
       COALESCE(max(status.expected_answer), '') || '|' ||
       COALESCE(max(status.observed_answer), '') || '|' ||
       COALESCE(max(exported.expected_action_type), '') || '|' ||
       COALESCE(max(exported.case_kind), '')
FROM status, exported;
")"
echo "numeric_triage_label_contract=$numeric_triage_label_contract"
[ "$numeric_triage_label_contract" = "1|flag|flag|review_flag|positive" ] || {
  echo "Expected numeric triage label/export to round trip through non-ER action, got $numeric_triage_label_contract" >&2
  exit 1
}

row_watch_status_contract="$(psql_value "
SELECT watch_name || '|' || kind || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queued_jobs::text || '|' ||
       complete_jobs::text || '|' ||
       count_basis
FROM otlet.watch_status
WHERE watch_name = '$row_triage_watch';
")"
echo "row_watch_status_contract=$row_watch_status_contract"
[ "$row_watch_status_contract" = "$row_triage_watch|row|1|1|0|0|0|1|estimated" ] || {
  echo "Expected row watch status to show one fresh completed row, got $row_watch_status_contract" >&2
  exit 1
}
row_plan_basis_contract="$(psql_value "
SELECT count_basis || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text
FROM otlet.semantic_index_plan('$row_triage_watch');
SELECT count_basis || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text
FROM otlet.semantic_index_plan('$row_triage_watch', true);
")"
row_plan_estimated="$(head -n 1 <<<"$row_plan_basis_contract")"
row_plan_exact="$(tail -n 1 <<<"$row_plan_basis_contract")"
echo "row_plan_basis_contract=$row_plan_estimated|exact=$row_plan_exact"
[ "$row_plan_estimated|$row_plan_exact" = "estimated|1|1|0|0|exact|1|1|0|0" ] || {
  echo "Expected estimated and exact row plan counts to match on demo row, got $row_plan_estimated|$row_plan_exact" >&2
  exit 1
}
row_lookup_basis_contract="$(psql_value "
SELECT COALESCE(string_agg(freshness_basis, ',' ORDER BY subject_id), '')
FROM otlet.semantic_index_current_rows('$row_triage_watch', true);
")"
echo "row_lookup_basis_contract=$row_lookup_basis_contract"
[ "$row_lookup_basis_contract" = "mvcc_match" ] || {
  echo "Expected unchanged row lookup to report mvcc_match freshness basis, got $row_lookup_basis_contract" >&2
  exit 1
}
row_fresh_customscan_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_triage_signal
WHERE otlet.semantic_matches_auto('$row_triage_watch', id, '{"decision":"flag"}'::jsonb);
SQL
)"
printf '%s\n' "$row_fresh_customscan_plan"
require_contains "$row_fresh_customscan_plan" "Otlet Node: Semantic Source CustomScan" "Expected fresh CustomScan explain details"
require_contains "$row_fresh_customscan_plan" "Planner Selected Path: semantic_lookup" "Expected fresh CustomScan lookup path"
require_contains "$row_fresh_customscan_plan" "Count Basis: exact" "Expected fresh CustomScan exact count basis"
require_contains "$row_fresh_customscan_plan" "Model Cost Source:" "Expected fresh CustomScan model cost source"
require_contains "$row_fresh_customscan_plan" "Preloaded Fresh Subjects: 1" "Expected fresh CustomScan preload count"
require_contains "$row_fresh_customscan_plan" "Preloaded Freshness Basis:" "Expected fresh CustomScan freshness basis breakdown"
require_contains "$row_fresh_customscan_plan" "Rows Returned: 1" "Expected fresh CustomScan returned row"
require_contains "$row_fresh_customscan_plan" "Actual Fresh Subjects: 1" "Expected fresh CustomScan fresh count"
require_contains "$row_fresh_customscan_plan" "Actual Stale Subjects: 0" "Expected fresh CustomScan stale count"
require_contains "$row_fresh_customscan_plan" "Infer Now Batches: 0" "Expected fresh CustomScan zero infer-now"
require_contains "$row_fresh_customscan_plan" "Infer Now Receipts: 0" "Expected fresh CustomScan zero infer-now receipts"

log "Checking visible row update freshness"
row_receipts_before_visible_update="$(psql_value "
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = '$row_triage_task';
")"
row_visible_stale_contract="$(psql_value "
BEGIN;
UPDATE public.otlet_demo_triage_signal
SET blockers = 0,
    approvals = 1,
    evidence = 'Updated review cleared the blocker and recorded manager approval'
WHERE id = 'triage-1';
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
SAVEPOINT pending_reason_probe;
UPDATE otlet.semantic_materializations
SET stale_reason = NULL
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1';
SELECT COALESCE(stale_reasons->>'content_revalidation_pending', '0')
FROM otlet.semantic_index_plan('$row_triage_watch', true);
ROLLBACK TO SAVEPOINT pending_reason_probe;
COMMIT;
")"
row_visible_fresh_before="$(head -n 1 <<<"$row_visible_stale_contract")"
row_visible_source_update="$(sed -n '2p' <<<"$row_visible_stale_contract")"
row_visible_predicate_match="$(sed -n '3p' <<<"$row_visible_stale_contract")"
row_visible_fdw_rows="$(sed -n '4p' <<<"$row_visible_stale_contract")"
row_pending_reason="$(sed -n '5p' <<<"$row_visible_stale_contract")"
echo "row_visible_update_stale_contract=$row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_fdw_rows"
[ "$row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_fdw_rows" = "0|true|false|0" ] || {
  echo "Expected visible row update to fail closed across lookup surfaces, got $row_visible_fresh_before|$row_visible_source_update|$row_visible_predicate_match|$row_visible_fdw_rows" >&2
  exit 1
}
echo "row_content_revalidation_pending_contract=$row_pending_reason"
[ "$row_pending_reason" = "1" ] || {
  echo "Expected stale current row with no stored reason to expose content_revalidation_pending, got $row_pending_reason" >&2
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

log "Checking content-keyed inference cache on row revert"
psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_demo_triage_signal
SET blockers = 2,
    approvals = 0,
    evidence = 'Wire instructions changed after invoice approval and the requester used urgent payment language'
WHERE id = 'triage-1';
SQL
psql_exec >/dev/null <<SQL
INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT
  '$row_triage_task',
  (src.id)::text,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_triage_signal',
      'subject_id', (src.id)::text,
      'ctid', src.ctid::text,
      'xmin', src.xmin::text
    ),
    'table', 'public.otlet_demo_triage_signal',
    'row', otlet.semantic_project_row(to_jsonb(src), NULL::text[])
  )
FROM public.otlet_demo_triage_signal AS src
WHERE src.id = 'triage-1';
SELECT otlet.wake_worker();
SQL
wait_task_complete "$row_triage_task" 3 900 1
row_cache_revert_contract="$(psql_value "
SELECT inference_cache_hit::text || '|' ||
       COALESCE(inference_cache_reason, '') || '|' ||
       COALESCE(inference_cache_key_basis, '') || '|' ||
       COALESCE(inference_cache_eviction_reason, '')
FROM otlet.inference_receipt_trace_status
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1'
  AND status = 'complete'
ORDER BY receipt_id DESC
LIMIT 1;
SELECT count(*)::text
FROM otlet.semantic_index_current_rows('$row_triage_watch', true);
")"
row_cache_revert_trace="$(head -n 1 <<<"$row_cache_revert_contract")"
row_cache_revert_fresh="$(tail -n 1 <<<"$row_cache_revert_contract")"
echo "row_cache_revert_contract=$row_cache_revert_trace|fresh=$row_cache_revert_fresh"
[ "$row_cache_revert_trace|$row_cache_revert_fresh" = "true|hit|content_hash_contract_hash_model_fingerprint|none|1" ] || {
  echo "Expected reverted row content to hit inference cache and remain fresh, got $row_cache_revert_trace|$row_cache_revert_fresh" >&2
  exit 1
}

log "Checking contract-change inference cache miss"
psql_exec >/dev/null <<SQL
WITH current_task AS (
  SELECT *
  FROM otlet.tasks
  WHERE name = '$row_triage_task'
)
SELECT (otlet.create_task(
    name,
    input_query,
    instruction || ' Cache contract drift demo $script_started.',
    output_schema,
    model_name,
    runtime_options,
    input_shaping,
    decision_contract
  )).name
FROM current_task;

INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT
  '$row_triage_task',
  (src.id)::text,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_triage_signal',
      'subject_id', (src.id)::text,
      'ctid', src.ctid::text,
      'xmin', src.xmin::text
    ),
    'table', 'public.otlet_demo_triage_signal',
    'row', otlet.semantic_project_row(to_jsonb(src), NULL::text[])
  )
FROM public.otlet_demo_triage_signal AS src
WHERE src.id = 'triage-1';
SELECT otlet.wake_worker();
SQL
wait_task_complete "$row_triage_task" 4 900 1
row_contract_cache_contract="$(psql_value "
SELECT inference_cache_hit::text || '|' ||
       COALESCE(inference_cache_reason, '') || '|' ||
       COALESCE(inference_cache_key_basis, '')
FROM otlet.inference_receipt_trace_status
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1'
  AND status = 'complete'
ORDER BY receipt_id DESC
LIMIT 1;
")"
echo "row_contract_cache_contract=$row_contract_cache_contract"
[ "$row_contract_cache_contract" = "false|contract_changed|content_hash_contract_hash_model_fingerprint" ] || {
  echo "Expected contract edit to miss inference cache with contract_changed reason, got $row_contract_cache_contract" >&2
  exit 1
}

row_manual_reason_contract="$(psql_value "
SELECT (otlet.mark_semantic_stale(NULL, 'triage-1', 'manual') >= 1)::text;
SELECT (count(*) FILTER (WHERE stale AND stale_reason = 'manual') >= 1)::text
FROM otlet.semantic_materializations
WHERE task_name = '$row_triage_task'
  AND subject_id = 'triage-1';
")"
row_manual_marked="$(head -n 1 <<<"$row_manual_reason_contract")"
row_manual_reason="$(tail -n 1 <<<"$row_manual_reason_contract")"
echo "row_manual_reason_contract=$row_manual_marked|$row_manual_reason"
[ "$row_manual_marked|$row_manual_reason" = "true|true" ] || {
  echo "Expected manual mark to expose manual stale reason, got $row_manual_marked|$row_manual_reason" >&2
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

psql_exec -v task_name="$row_triage_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
CREATE TEMP TABLE row_triage_invalid_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  VALUES (
    :'task_name',
    'triage-invalid-json',
    '{"row":{"id":"triage-invalid-json","blockers":1,"approvals":0,"evidence":"invalid model answer smoke"}}'::jsonb,
    'running',
    1,
    now(),
    now() + interval '5 minutes'
  )
  RETURNING id
)
SELECT id FROM inserted;

SELECT otlet.fail_job(
  id,
  'invalid model JSON: expected object',
  'not json',
  NULL,
  NULL,
  md5('{"type":"object","required":["decision","confidence","reason"]}'),
  md5('not json'),
  now(),
  'failed',
  '{"schema_validation_status":"failed"}'::jsonb,
  :'model_name',
  'direct',
  'failed',
  'invalid_model_json'
)
FROM row_triage_invalid_claim;
SQL
row_triage_invalid_contract="$(psql_value "
SELECT j.status || '|' ||
       (j.error LIKE 'invalid model JSON:%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.schema_validation_status || '|' ||
       (r.raw_output_hash = md5('not json'))::text || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       (SELECT count(*) FROM otlet.actions WHERE job_id = j.id)::text || '|' ||
       (
         SELECT count(*)::text
         FROM otlet.semantic_materializations sm
         JOIN otlet.records rec ON rec.id = sm.record_id
         JOIN otlet.actions act ON act.id = rec.action_id
         WHERE act.job_id = j.id
       )
FROM otlet.jobs j
JOIN otlet.inference_receipts r ON r.job_id = j.id
WHERE j.task_name = '$row_triage_task'
  AND j.subject_id = 'triage-invalid-json'
ORDER BY j.id DESC, r.id DESC
LIMIT 1;
")"
echo "row_triage_invalid_answer_contract=$row_triage_invalid_contract"
[ "$row_triage_invalid_contract" = "failed|true|failed|failed|failed|true|0|0|0" ] || {
  echo "Expected invalid non-ER model answer to leave only a failed receipt, got $row_triage_invalid_contract" >&2
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
SELECT COALESCE(string_agg(freshness_basis, ',' ORDER BY subject_id), '')
FROM otlet.${row_scoped_watch}_native;
")"
row_scoped_fresh_after="$(head -n 1 <<<"$row_scoped_contract")"
row_scoped_match_after="$(sed -n '2p' <<<"$row_scoped_contract")"
row_scoped_receipts_after="$(sed -n '3p' <<<"$row_scoped_contract")"
row_scoped_columns="$(sed -n '4p' <<<"$row_scoped_contract")"
row_scoped_basis="$(tail -n 1 <<<"$row_scoped_contract")"
echo "row_scoped_contract=$row_scoped_fresh_after|$row_scoped_match_after|$row_scoped_receipts_before|$row_scoped_receipts_after|$row_scoped_columns|$row_scoped_basis"
[ "$row_scoped_fresh_after|$row_scoped_match_after|$row_scoped_receipts_before|$row_scoped_receipts_after|$row_scoped_columns|$row_scoped_basis" = "1|true|1|1|{signal}|revalidated_after_benign_update" ] || {
  echo "Expected scoped watch to stay fresh with unchanged receipts and revalidated basis after unrelated column change, got $row_scoped_fresh_after|$row_scoped_match_after|$row_scoped_receipts_before|$row_scoped_receipts_after|$row_scoped_columns|$row_scoped_basis" >&2
  exit 1
}
row_scoped_fdw_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM otlet.${row_scoped_watch}_native
WHERE subject_id = 'scoped-1';
SQL
)"
printf '%s\n' "$row_scoped_fdw_plan"
require_contains "$row_scoped_fdw_plan" "Otlet Node: Semantic Foreign Scan" "Expected row FDW explain details"
require_contains "$row_scoped_fdw_plan" "Selected Path: semantic_lookup" "Expected row FDW lookup path"
require_contains "$row_scoped_fdw_plan" "Reason: pushed subject rows fresh" "Expected row FDW pushed-subject reason"
require_contains "$row_scoped_fdw_plan" "Total Subjects: 1" "Expected row FDW scoped total"
require_contains "$row_scoped_fdw_plan" "Fresh Subjects: 1" "Expected row FDW scoped fresh count"
require_contains "$row_scoped_fdw_plan" "Count Basis: estimated" "Expected row FDW count basis"
require_contains "$row_scoped_fdw_plan" "Model Cost Source:" "Expected row FDW model cost source"
require_contains "$row_scoped_fdw_plan" "Path Cost:" "Expected row FDW path cost"
require_contains "$row_scoped_fdw_plan" "Actual Rows Loaded: 1" "Expected row FDW loaded row count"
require_contains "$row_scoped_fdw_plan" "Pushed Subject Id: scoped-1" "Expected row FDW pushed subject"
row_empty_fdw_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM otlet.${row_scoped_watch}_native
WHERE subject_id = ANY (ARRAY[]::text[]);
SQL
)"
printf '%s\n' "$row_empty_fdw_plan"
require_contains "$row_empty_fdw_plan" "Selected Path: semantic_lookup" "Expected empty pushed subject lookup path"
require_contains "$row_empty_fdw_plan" "Reason: pushed subject filter empty" "Expected empty pushed subject reason"
require_contains "$row_empty_fdw_plan" "Total Subjects: 0" "Expected empty pushed subject total"
require_contains "$row_empty_fdw_plan" "Actual Rows Loaded: 0" "Expected empty pushed subject loaded row count"
require_contains "$row_empty_fdw_plan" "Pushed Subject Filter: empty" "Expected empty pushed subject marker"
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
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_scoped_signal
WHERE otlet.semantic_matches('$row_scoped_watch', id, '{"decision":"pass"}'::jsonb);
SQL
)"
printf '%s\n' "$row_schema_customscan_plan"
require_contains "$row_schema_customscan_plan" "Otlet Node: Semantic Source CustomScan" "Expected CustomScan explain details"
require_contains "$row_schema_customscan_plan" "Planner Selected Path: lookup_fail_closed" "Expected stale CustomScan fail-closed path"
require_contains "$row_schema_customscan_plan" "Planner Reason: fail closed" "Expected stale CustomScan fail-closed reason"
require_contains "$row_schema_customscan_plan" "Planner Stale Reasons:" "Expected CustomScan stale reason breakdown"
require_contains "$row_schema_customscan_plan" "schema_drift" "Expected CustomScan stale reason to include schema_drift"
require_contains "$row_schema_customscan_plan" "Count Basis: exact" "Expected stale CustomScan exact count basis"
require_contains "$row_schema_customscan_plan" "Model Cost Source:" "Expected stale CustomScan model cost source"
require_contains "$row_schema_customscan_plan" "Planner Fail Closed Subjects: 1" "Expected stale CustomScan planned fail-closed count"
require_contains "$row_schema_customscan_plan" "Preloaded Freshness Basis:" "Expected stale CustomScan freshness basis breakdown"
require_contains "$row_schema_customscan_plan" "Actual Fail Closed Rows: 1" "Expected stale CustomScan actual fail-closed count"
require_contains "$row_schema_customscan_plan" "Actual Stale Subjects: 1" "Expected stale CustomScan actual stale count"
require_contains "$row_schema_customscan_plan" "Rows Returned: 0" "Expected stale CustomScan to return no rows"

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
psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_demo_customscan_signal
SET signal = 'flag';

UPDATE otlet.production_policy
SET stale_policy = 'lookup_only_fail_closed',
    semantic_auto_wait_ms = 0,
    semantic_auto_infer_ms = 30000,
    semantic_auto_max_rows = 1
WHERE name = 'default';
SQL
row_customscan_infer_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_customscan_signal
WHERE otlet.semantic_matches_auto('$row_customscan_watch', id, '{}'::jsonb);
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
require_contains "$row_customscan_infer_plan" "Infer Now Trace Receipt Id:" "Expected infer-now receipt pointer"
require_contains "$row_customscan_infer_plan" "Rows Returned: 1" "Expected one inferred row returned after bounded infer-now"

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
    'strong_model_name', :'strong_policy_model'
  ),
  '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  ARRAY['review_flag'],
  'refresh_then_fail_closed',
  '{}'::jsonb,
  '{"preset":"row_triage_decision_v1"}'::jsonb
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
row_triage_preset_contract="$(psql_value "
SELECT COALESCE(t.decision_contract ->> 'preset', '') || '|' ||
       COALESCE(p.accept_field_checks ->> 'answer_field', '') || '|' ||
       (p.accept_field_checks -> 'abstain_values' ? 'unclear')::text || '|' ||
       (p.accept_field_checks -> 'accepted_confidence' ? 'medium')::text
FROM otlet.tasks t
JOIN otlet.model_selection_policies p ON p.task_name = t.name
WHERE t.name = '$row_triage_policy_task';
")"
echo "row_triage_preset_contract=$row_triage_preset_contract"
[ "$row_triage_preset_contract" = "row_triage_decision_v1|decision|true|true" ] || {
  echo "Expected triage preset to drive selection policy labels, got $row_triage_preset_contract" >&2
  exit 1
}
row_triage_abstention_contract="$(psql_value "
WITH task_abstentions AS (
  SELECT count(*)::bigint AS abstained_outputs
  FROM otlet.outputs o
  JOIN otlet.jobs j ON j.id = o.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
  CROSS JOIN LATERAL (
    SELECT COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match') AS answer_field,
           COALESCE(t.decision_contract -> 'abstain_values', '[]'::jsonb) AS abstain_values
  ) contract
  WHERE j.task_name = '$row_triage_policy_task'
    AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(contract.abstain_values) value(abstain_value)
      WHERE o.output ->> contract.answer_field = value.abstain_value
    )
)
SELECT task_abstentions.abstained_outputs::text || '|' ||
       output_reliability_status.abstained_outputs::text
FROM task_abstentions
CROSS JOIN otlet.output_reliability_status;
")"
echo "row_triage_abstention_contract=$row_triage_abstention_contract"
require_regex "$row_triage_abstention_contract" '^[1-9][0-9]*\|[1-9][0-9]*$' "Expected nonzero abstention counters for the triage preset"

psql_exec \
  -v task_name="$row_triage_policy_task" \
  -v cheap_policy_model="$strong_model_name" \
  -v strong_policy_model="$strong_alias_model_name" >/dev/null <<'SQL'
SELECT otlet.set_model_selection_policy(
  :'task_name',
  :'cheap_policy_model',
  :'strong_policy_model',
  '{"answer_field":"decision","abstain_values":["unclear"],"confidence_field":"confidence","accepted_confidence":["high","medium"]}'::jsonb,
  2,
  0.5,
  2
);

WITH source_job AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name = :'task_name'
  ORDER BY id
  LIMIT 1
), seeds AS (
  SELECT generate_series(1, 2)
)
SELECT (otlet.record_model_attempt(
  source_job.id,
  :'cheap_policy_model',
  trace_summary => '{"generate_ms":0}'::jsonb,
  selection_role => 'cheap',
  selection_status => 'failed',
  selection_reason => 'seeded_recent_failure',
  error => 'seeded recent cheap failure'
)).id
FROM source_job, seeds;
SQL

cheap_skip_seed_contract="$(psql_value "
SELECT recent_attempts::text || '|' ||
       recent_accepted::text || '|' ||
       skip_cheap::text || '|' ||
       probe_due::text
FROM otlet.model_selection_recent_acceptance('$row_triage_policy_task');
")"
echo "cheap_skip_seed_contract=$cheap_skip_seed_contract"
[ "$cheap_skip_seed_contract" = "2|0|true|false" ] || {
  echo "Expected seeded cheap failures to enable cheap skip, got $cheap_skip_seed_contract" >&2
  exit 1
}

psql_exec >/dev/null <<'SQL'
INSERT INTO public.otlet_demo_triage_policy_signal
VALUES (
  'triage-skip',
  0,
  0,
  'No decisive blocker and no approval evidence; skip cheap after seeded failures'
);
SQL
wait_task_complete "$row_triage_policy_task" 2 900 1

cheap_skip_contract="$(psql_value "
WITH attempts AS (
  SELECT selection_role, selection_status, selection_reason
  FROM otlet.model_selection_attempts
  WHERE task_name = '$row_triage_policy_task'
    AND subject_id = 'triage-skip'
)
SELECT
  (SELECT count(*) FROM attempts WHERE selection_role = 'cheap')::text || '|' ||
  (SELECT count(*) FROM attempts WHERE selection_role = 'strong' AND selection_reason = 'cheap_skipped_low_recent_acceptance')::text || '|' ||
  (SELECT count(*) FROM attempts WHERE selection_role = 'strong' AND selection_status = 'accepted')::text || '|' ||
  (SELECT cheap_skipped::text || '|' || cheap_probe_due::text FROM otlet.model_selection_status WHERE task_name = '$row_triage_policy_task');
")"
echo "cheap_skip_contract=$cheap_skip_contract"
[ "$cheap_skip_contract" = "0|1|1|1|true" ] || {
  echo "Expected cheap skip and next-job probe due, got $cheap_skip_contract" >&2
  exit 1
}

psql_exec >/dev/null <<'SQL'
INSERT INTO public.otlet_demo_triage_policy_signal
VALUES (
  'triage-probe',
  0,
  0,
  'No decisive blocker and no approval evidence; probe cheap at the configured interval'
);
SQL
wait_task_complete "$row_triage_policy_task" 3 900 1

cheap_probe_contract="$(psql_value "
WITH attempts AS (
  SELECT selection_role, selection_reason
  FROM otlet.model_selection_attempts
  WHERE task_name = '$row_triage_policy_task'
    AND subject_id = 'triage-probe'
)
SELECT
  (SELECT count(*) FROM attempts WHERE selection_role = 'cheap' AND selection_reason = 'cheap_probe_recent_acceptance')::text || '|' ||
  (SELECT cheap_probe_attempts::text || '|' || cheap_probe_due::text FROM otlet.model_selection_status WHERE task_name = '$row_triage_policy_task');
")"
echo "cheap_probe_contract=$cheap_probe_contract"
[ "$cheap_probe_contract" = "1|1|false" ] || {
  echo "Expected configured cheap probe attempt, got $cheap_probe_contract" >&2
  exit 1
}

cheap_skip_latency_delta_ms="$(psql_value "
WITH totals AS (
  SELECT subject_id, sum(COALESCE(generate_ms, 0))::bigint AS total_ms
  FROM otlet.model_selection_attempts
  WHERE task_name = '$row_triage_policy_task'
    AND subject_id IN ('triage-unclear', 'triage-skip')
  GROUP BY subject_id
)
SELECT 'triage-skip|' ||
       COALESCE((SELECT total_ms FROM totals WHERE subject_id = 'triage-skip'), 0)::text || '|' ||
       COALESCE((SELECT total_ms FROM totals WHERE subject_id = 'triage-unclear'), 0)::text || '|' ||
       (
         COALESCE((SELECT total_ms FROM totals WHERE subject_id = 'triage-skip'), 0) -
         COALESCE((SELECT total_ms FROM totals WHERE subject_id = 'triage-unclear'), 0)
       )::text;
")"
echo "cheap_skip_latency_delta_ms=$cheap_skip_latency_delta_ms"
require_regex "$cheap_skip_latency_delta_ms" '^triage-skip\|[0-9]+\|[0-9]+\|-?[0-9]+$' "Expected receipt-derived cheap-skip latency delta"

psql_exec \
  -v task_name="$row_triage_policy_task" \
  -v cheap_policy_model="$strong_model_name" \
  -v strong_policy_model="$strong_alias_model_name" >/dev/null <<'SQL'
SELECT otlet.set_model_selection_policy(
  :'task_name',
  :'cheap_policy_model',
  :'strong_policy_model',
  '{"answer_field":"decision","abstain_values":["unclear"],"confidence_field":"confidence","accepted_confidence":["high","medium"]}'::jsonb,
  2,
  0,
  2
);
SQL

psql_exec >/dev/null <<'SQL'
INSERT INTO public.otlet_demo_triage_policy_signal
VALUES (
  'triage-skip-disabled',
  0,
  0,
  'No decisive blocker and no approval evidence; threshold zero must keep cheap-first behavior'
);
SQL
wait_task_complete "$row_triage_policy_task" 4 900 1

cheap_skip_disabled_contract="$(psql_value "
WITH attempts AS (
  SELECT selection_role, selection_reason
  FROM otlet.model_selection_attempts
  WHERE task_name = '$row_triage_policy_task'
    AND subject_id = 'triage-skip-disabled'
)
SELECT
  (SELECT count(*) FROM attempts WHERE selection_role = 'cheap')::text || '|' ||
  (SELECT count(*) FROM attempts WHERE selection_role = 'strong' AND selection_reason = 'cheap_skipped_low_recent_acceptance')::text || '|' ||
  (SELECT cheap_skip_recommended::text FROM otlet.model_selection_status WHERE task_name = '$row_triage_policy_task');
")"
echo "cheap_skip_disabled_contract=$cheap_skip_disabled_contract"
[ "$cheap_skip_disabled_contract" = "1|0|false" ] || {
  echo "Expected cheap skip disabled at threshold 0, got $cheap_skip_disabled_contract" >&2
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
        CASE
          WHEN r.notes ILIKE '%rebranded after acquisition%' THEN 'Northstar rebrand after acquisition'
          ELSE 'no rebrand evidence in notes'
        END
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

model_swap_contract="$(psql_value "
WITH swaps AS (
  SELECT detail
  FROM otlet.worker_events
  WHERE event_type = 'model_swap'
    AND created_at >= '$script_started'::timestamptz
)
SELECT (count(*) FILTER (WHERE detail ->> 'model_name' = '$cheap_model_name') >= 1)::text || '|' ||
       (count(*) FILTER (WHERE detail ->> 'model_name' = '$strong_model_name') >= 1)::text || '|' ||
       COALESCE(bool_and(
         COALESCE((detail ->> 'load_ms')::bigint, -1) >= 0
         AND COALESCE((detail ->> 'model_memory_bytes')::bigint, 0) > 0
         AND COALESCE((detail ->> 'worker_process_rss_bytes')::bigint, 0) > 0
         AND (
           COALESCE((detail ->> 'worker_memory_budget_bytes')::bigint, 0) = 0
           OR COALESCE((detail ->> 'worker_process_rss_bytes')::bigint, 0)
              <= COALESCE((detail ->> 'worker_memory_budget_bytes')::bigint, 0)
         )
       ), false)::text
FROM swaps;
")"
echo "model_swap_contract=$model_swap_contract"
[ "$model_swap_contract" = "true|true|true" ] || {
  echo "Expected model swap events for cheap and strong models with memory evidence, got $model_swap_contract" >&2
  exit 1
}

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
  WHERE action_type IN ('merge_candidate', 'new_entity', 'note', 'review_flag')
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
require_contains "$action_contract" "action_schema_contract=merge_candidate|new_entity|note|review_flag" "Expected built-in action schemas"
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

psql_exec >/dev/null <<SQL
SELECT * FROM otlet.label_action($merge_action_id);
SELECT * FROM otlet.label_action($new_entity_action_id);
SQL
er_eval_label_contract="$(psql_value "
WITH labels AS (
  SELECT *
  FROM otlet.eval_labels
  WHERE action_id IN ($merge_action_id, $new_entity_action_id)
), exported AS (
  SELECT *
  FROM otlet.export_eval_cases(50)
  WHERE action_id IN ($merge_action_id, $new_entity_action_id)
)
SELECT count(*)::text || '|' ||
       COALESCE(max(labels.expected_answer) FILTER (WHERE labels.action_id = $merge_action_id), '') || '|' ||
       COALESCE(max(exported.case_kind) FILTER (WHERE exported.action_id = $merge_action_id), '') || '|' ||
       COALESCE(max(labels.expected_answer) FILTER (WHERE labels.action_id = $new_entity_action_id), '') || '|' ||
       COALESCE(max(exported.case_kind) FILTER (WHERE exported.action_id = $new_entity_action_id), '')
FROM labels
JOIN exported USING (action_id);
")"
echo "er_eval_label_contract=$er_eval_label_contract"
[ "$er_eval_label_contract" = "2|same_entity|positive|different_entity|hard_negative" ] || {
  echo "Expected ER eval export parity after expected_answer rename, got $er_eval_label_contract" >&2
  exit 1
}

dry_run_source_identity_contract="$(
  psql_exec -qAt -v action_id="$merge_action_id" <<'SQL'
CREATE TEMP TABLE dry_run_source_identity_original(notes text);
CREATE TEMP TABLE dry_run_source_identity_result(ord int, phase text, status text, dry_run_status text, error text);
INSERT INTO dry_run_source_identity_original
SELECT notes FROM public.otlet_demo_vendor_entity WHERE id = 'vendor-42';
UPDATE public.otlet_demo_vendor_entity
SET notes = replace(notes, 'rebranded after acquisition', 'separate vendor without acquisition')
WHERE id = 'vendor-42';
INSERT INTO dry_run_source_identity_result
SELECT 1, 'after_update', status, dry_run_status, COALESCE(error, '')
FROM otlet.dry_run_action(:action_id);
UPDATE public.otlet_demo_vendor_entity
SET notes = (SELECT notes FROM dry_run_source_identity_original)
WHERE id = 'vendor-42';
INSERT INTO dry_run_source_identity_result
SELECT 2, 'after_revert', status, dry_run_status, COALESCE(error, '')
FROM otlet.dry_run_action(:action_id);
SELECT string_agg(phase || ':' || status || ':' || dry_run_status || ':' || error, '|' ORDER BY ord)
FROM dry_run_source_identity_result;
SQL
)"
echo "dry_run_source_identity_contract=$dry_run_source_identity_contract"
[ "$dry_run_source_identity_contract" = "after_update:approved:failed:source identity stale|after_revert:approved:passed:" ] || {
  echo "Expected dry-run source identity failure after edit and pass after revert, got $dry_run_source_identity_contract" >&2
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
       fail_closed_subjects::text || '|' ||
       count_basis
FROM otlet.semantic_join_index_plan('$join_index_name');
SELECT selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queue_subjects::text || '|' ||
       fail_closed_subjects::text || '|' ||
       count_basis
FROM otlet.semantic_join_index_plan('$join_index_name', true);
")"
join_status_estimated="$(head -n 1 <<<"$join_status_contract")"
join_status_exact="$(tail -n 1 <<<"$join_status_contract")"
echo "semantic_join_status_contract=$join_status_contract"
[ "$join_status_estimated|$join_status_exact" = "semantic_join_lookup|4|4|0|0|0|0|estimated|semantic_join_lookup|4|4|0|0|0|0|exact" ] || {
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
join_customscan_plan="$(
  psql_exec -P border=2 -P null='' <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT subject_id
FROM (
  SELECT subject_id
  FROM public.otlet_demo_vendor_pair_input
  OFFSET 0
) pair_subjects
WHERE otlet.semantic_join_matches_auto('$join_index_name', subject_id, '{"match":"same_entity"}'::jsonb);
SQL
)"
printf '%s\n' "$join_customscan_plan"
require_contains "$join_customscan_plan" "Otlet Node: Semantic Source CustomScan" "Expected join CustomScan explain details"
require_contains "$join_customscan_plan" "Semantic Index Kind: join" "Expected join CustomScan index kind"
require_contains "$join_customscan_plan" "Planner Selected Path: semantic_join_lookup" "Expected join CustomScan lookup path"
require_contains "$join_customscan_plan" "Count Basis: estimated" "Expected join CustomScan estimated count basis"
require_contains "$join_customscan_plan" "Model Cost Source:" "Expected join CustomScan model cost source"
require_contains "$join_customscan_plan" "Preloaded Fresh Subjects: 4" "Expected join CustomScan preload count"
require_contains "$join_customscan_plan" "Preloaded Freshness Basis:" "Expected join CustomScan freshness basis breakdown"
require_contains "$join_customscan_plan" "Actual Fresh Subjects: 4" "Expected join CustomScan fresh count"
require_contains "$join_customscan_plan" "Actual Stale Subjects: 0" "Expected join CustomScan stale count"
require_contains "$join_customscan_plan" "Actual Lookup Rows: 4" "Expected join CustomScan lookup rows"
require_contains "$join_customscan_plan" "Infer Now Batches: 0" "Expected join CustomScan zero infer-now"
require_contains "$join_customscan_plan" "Child Plan Source Rows: 4" "Expected join CustomScan child rows"

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
require_contains "$fdw_plan" "Reason: pushed subject rows fresh" "Expected join FDW pushed-subject reason"
require_contains "$fdw_plan" "Total Subjects: 1" "Expected join FDW scoped total"
require_contains "$fdw_plan" "Fresh Subjects: 1" "Expected join FDW scoped fresh count"
require_contains "$fdw_plan" "Queue Subjects: 0" "Expected FDW queue subject count"
require_contains "$fdw_plan" "Count Basis: estimated" "Expected join FDW count basis"
require_contains "$fdw_plan" "Model Cost Source:" "Expected join FDW model cost source"
require_contains "$fdw_plan" "Path Cost:" "Expected FDW path cost"
require_contains "$fdw_plan" "Actual Rows Loaded: 1" "Expected join FDW loaded row count"
require_contains "$fdw_plan" "Pushed Subject Id: vendor-1001:vendor-42" "Expected join FDW pushed subject"

log "Checking entity-resolution dependency update"
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
if [ "$join_stale_subjects|$join_fresh_after_lookup" != "4|0|0" ] || [ "$join_receipts_before_update" != "$join_receipts_after_update" ]; then
  echo "Expected semantic join dependency update to fail closed with unchanged receipts, got $join_stale_subjects|$join_fresh_after_lookup|$join_receipts_before_update|$join_receipts_after_update" >&2
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
       eval_labels::text || '|' ||
       delete_stale_materializations::text || '|' ||
       rejected_receipt_raw_outputs::text || '|' ||
       dry_run::text
FROM otlet.cleanup_policy_state(true);
")"
echo "cleanup_policy_dry_run=$cleanup_dry_run"
require_regex "$cleanup_dry_run" '^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|true$' "Expected cleanup dry run counts ending in true"

runtime_contract="$(psql_value "
SELECT runtime_status || '|' ||
       slot_state || '|' ||
       COALESCE(tokens_per_second::text, '') || '|' ||
       (COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0))::text || '|' ||
       (COALESCE(inference_cache_max_entries, 0) > 0)::text || '|' ||
       (COALESCE(inference_cache_max_bytes, 0) > 0)::text || '|' ||
       COALESCE(inference_cache_last_eviction_reason, '') || '|' ||
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
  "|true|true|" \
  "|none|" \
  "linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run"; do
  require_contains "$runtime_contract" "$term" "Expected runtime status to contain $term"
done

log "Checking estimated planner on 1M-row source"
planner_1m_output="$(
  psql_exec -qAt -v model_name="$strong_model_name" <<'SQL'
DROP TABLE IF EXISTS public.otlet_plan_1m;
CREATE TABLE public.otlet_plan_1m AS
SELECT gs::text AS id, (gs % 10)::int AS bucket, 'plan row ' || gs::text AS note
FROM generate_series(1, 1000000) AS gs;
ALTER TABLE public.otlet_plan_1m ADD PRIMARY KEY (id);
ANALYZE public.otlet_plan_1m;
SELECT (otlet.create_watch(
  'plan_1m_demo',
  'row',
  'Classify one synthetic row. Return JSON only.',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"enum":["keep","drop"]}}}'::jsonb,
  :'model_name',
  'public.otlet_plan_1m'::regclass,
  'id',
  NULL,
  'plan_fact',
  '{"max_tokens":16,"reasoning":"off","inference_cache":true}'::jsonb,
  '{}'::jsonb,
  '{"on_change":"mark_stale"}'::jsonb,
  ARRAY[]::text[],
  'refresh_then_fail_closed',
  '{}'::jsonb,
  '{}'::jsonb
)).name;
DROP TABLE IF EXISTS pg_temp.otlet_plan_1m_timing;
CREATE TEMP TABLE otlet_plan_1m_timing (
  count_basis text,
  total_subjects bigint,
  elapsed_ms numeric
);
DO $$
DECLARE
  started_at timestamptz;
  planned_row record;
  elapsed numeric;
BEGIN
  started_at := clock_timestamp();
  SELECT count_basis, total_subjects
  INTO planned_row
  FROM otlet.semantic_index_plan('plan_1m_demo');
  elapsed := EXTRACT(epoch FROM clock_timestamp() - started_at) * 1000;
  INSERT INTO pg_temp.otlet_plan_1m_timing
  VALUES (planned_row.count_basis, planned_row.total_subjects, elapsed);
END $$;
SELECT count_basis || '|' ||
       total_subjects::text || '|' ||
       round(elapsed_ms, 3)::text || '|' ||
       (elapsed_ms < 100)::text
FROM pg_temp.otlet_plan_1m_timing;
SQL
)"
planner_1m_contract="$(tail -n 1 <<<"$planner_1m_output")"
planner_1m_basis="$(cut -d'|' -f1 <<<"$planner_1m_contract")"
planner_1m_total="$(cut -d'|' -f2 <<<"$planner_1m_contract")"
planner_1m_fast="$(cut -d'|' -f4 <<<"$planner_1m_contract")"
echo "planner_1m_contract=$planner_1m_contract"
[ "$planner_1m_basis" = "estimated" ] && [ "$planner_1m_total" -ge 1000000 ] && [ "$planner_1m_fast" = "true" ] || {
  echo "Expected estimated 1M-row plan under 100ms, got $planner_1m_contract" >&2
  exit 1
}

colon_subject_watch="colon_subject_demo"
colon_subject_task="${colon_subject_watch}_task"
psql_exec -v watch_name="$colon_subject_watch" >/dev/null <<'SQL'
SELECT otlet.drop_watch(:'watch_name');
DROP TABLE IF EXISTS public.otlet_demo_colon_subject;
SQL
psql_exec \
  -v watch_name="$colon_subject_watch" \
  -v task_name="$colon_subject_task" \
  -v model_name="$strong_model_name" >/dev/null <<'SQL'
CREATE TABLE public.otlet_demo_colon_subject (
  id text PRIMARY KEY,
  signal text NOT NULL
);
INSERT INTO public.otlet_demo_colon_subject VALUES ('tenant:colon-fragment-only:1', 'pass');

SELECT otlet.create_watch(
  watch_name => :'watch_name',
  kind => 'row',
  table_name => 'public.otlet_demo_colon_subject'::regclass,
  subject_column => 'id',
  instruction => 'Classify the row as pass. Return JSON only.',
  output_schema => '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["pass"]},
      "confidence": {"enum": ["high"]},
      "reason": {"type": "string", "maxLength": 80}
    }
  }'::jsonb,
  model_name => :'model_name',
  record_type => 'colon_subject_record',
  runtime_options => '{"max_tokens":64,"reasoning":"off","inference_cache":false}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb
);

CREATE TEMP TABLE colon_subject_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  SELECT
    :'task_name',
    src.id,
    jsonb_build_object(
      '_otlet_mvcc', jsonb_build_object(
        'table', 'public.otlet_demo_colon_subject',
        'subject_id', src.id::text,
        'ctid', src.ctid::text,
        'xmin', src.xmin::text
      ),
      'table', 'public.otlet_demo_colon_subject',
      'row', otlet.semantic_project_row(to_jsonb(src), NULL::text[])
    ),
    'running',
    1,
    now(),
    now() + interval '5 minutes'
  FROM public.otlet_demo_colon_subject src
  WHERE src.id = 'tenant:colon-fragment-only:1'
  RETURNING id
)
SELECT id FROM inserted;
SELECT otlet.complete_job(
  id,
  '{"decision":"pass","confidence":"high","reason":"colon subject"}'::jsonb,
  '{"output":{"decision":"pass","confidence":"high","reason":"colon subject"},"actions":[]}',
  '[]'::jsonb,
  NULL,
  NULL,
  NULL,
  md5('{"output":{"decision":"pass","confidence":"high","reason":"colon subject"},"actions":[]}'),
  now(),
  '{"schema_validation_status":"passed"}'::jsonb,
  :'model_name'
)
FROM colon_subject_claim;
WITH output_row AS (
  SELECT
    j.id AS job_id,
    j.subject_id,
    j.input,
    o.id AS output_id,
    o.receipt_id,
    o.output
  FROM colon_subject_claim c
  JOIN otlet.jobs j ON j.id = c.id
  JOIN otlet.outputs o ON o.job_id = j.id
),
action_row AS (
  INSERT INTO otlet.actions (
    job_id,
    output_id,
    receipt_id,
    action_type,
    payload,
    status,
    subject_id,
    source_table,
    source_hash
  )
  SELECT
    job_id,
    output_id,
    receipt_id,
    'create_record',
    jsonb_build_object(
      'type', 'create_record',
      'record_type', 'colon_subject_record',
      'subject_id', subject_id,
      'body', output
    ),
    'complete',
    subject_id,
    'public.otlet_demo_colon_subject',
    md5(input::text)
  FROM output_row
  RETURNING id, subject_id
)
INSERT INTO otlet.records (action_id, record_type, subject_id, body)
SELECT
  a.id,
  'colon_subject_record',
  o.subject_id,
  o.output
FROM action_row a
JOIN output_row o ON o.subject_id = a.subject_id;
SELECT otlet.materialize_semantic_index_subject(:'watch_name', 'tenant:colon-fragment-only:1');
SQL
colon_subject_contract="$(psql_value "
CREATE TEMP TABLE colon_subject_contract_parts (
  key text PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO colon_subject_contract_parts
SELECT 'before_mark',
       count(*)::text
FROM otlet.semantic_index_current_rows('$colon_subject_watch', true)
WHERE subject_id = 'tenant:colon-fragment-only:1';
INSERT INTO colon_subject_contract_parts
SELECT 'fragment_mark',
       otlet.mark_semantic_stale(NULL, 'colon-fragment-only', 'manual')::text;
INSERT INTO colon_subject_contract_parts
SELECT 'after_fragment',
       count(*)::text
FROM otlet.semantic_materializations
WHERE task_name = '$colon_subject_task'
  AND subject_id = 'tenant:colon-fragment-only:1'
  AND stale;
INSERT INTO colon_subject_contract_parts
SELECT 'exact_mark',
       otlet.mark_semantic_stale(NULL, 'tenant:colon-fragment-only:1', 'manual')::text;
INSERT INTO colon_subject_contract_parts
SELECT 'after_exact',
       count(*)::text
FROM otlet.semantic_materializations
WHERE task_name = '$colon_subject_task'
  AND subject_id = 'tenant:colon-fragment-only:1'
  AND stale;
INSERT INTO colon_subject_contract_parts
SELECT 'lookup_after_exact',
       count(*)::text
FROM otlet.semantic_index_current_rows('$colon_subject_watch', true)
WHERE subject_id = 'tenant:colon-fragment-only:1';
WITH validation AS (
  SELECT
    COALESCE(otlet.action_validation_error(
      '{\"type\":\"merge_candidate\",\"body\":{\"left_id\":\"tenant:left:1\",\"right_id\":\"tenant:right:2\",\"confidence\":\"high\",\"reason\":\"same\"}}'::jsonb,
      '{\"match\":\"same_entity\",\"confidence\":\"high\",\"reason\":\"same\"}'::jsonb,
      'tenant:left:1:tenant:right:2',
      '{\"action_ids\":{\"left_id\":\"tenant:left:1\",\"right_id\":\"tenant:right:2\"}}'::jsonb
    ), 'ok') AS valid_pair,
    COALESCE(otlet.action_validation_error(
      '{\"type\":\"merge_candidate\",\"body\":{\"left_id\":\"tenant:left:1\",\"right_id\":\"tenant:right:wrong\",\"confidence\":\"high\",\"reason\":\"same\"}}'::jsonb,
      '{\"match\":\"same_entity\",\"confidence\":\"high\",\"reason\":\"same\"}'::jsonb,
      'tenant:left:1:tenant:right:2',
      '{\"action_ids\":{\"left_id\":\"tenant:left:1\",\"right_id\":\"tenant:right:2\"}}'::jsonb
    ), 'ok') AS invalid_pair
)
SELECT (SELECT value FROM colon_subject_contract_parts WHERE key = 'before_mark') || '|' ||
       (SELECT value FROM colon_subject_contract_parts WHERE key = 'fragment_mark') || '|' ||
       (SELECT value FROM colon_subject_contract_parts WHERE key = 'after_fragment') || '|' ||
       (SELECT value FROM colon_subject_contract_parts WHERE key = 'exact_mark') || '|' ||
       (SELECT value FROM colon_subject_contract_parts WHERE key = 'after_exact') || '|' ||
       (SELECT value FROM colon_subject_contract_parts WHERE key = 'lookup_after_exact') || '|' ||
       (SELECT valid_pair FROM validation) || '|' ||
       (SELECT invalid_pair FROM validation);
")"
echo "colon_subject_safety_contract=$colon_subject_contract"
[ "$colon_subject_contract" = "1|0|0|1|1|0|ok|merge_candidate subject ids must match job subject_id" ] || {
  echo "Expected colon subject IDs to validate and stale-mark only by exact subject, got $colon_subject_contract" >&2
  exit 1
}
psql_exec -v watch_name="$colon_subject_watch" >/dev/null <<'SQL'
SELECT otlet.drop_watch(:'watch_name');
DROP TABLE IF EXISTS public.otlet_demo_colon_subject;
SQL

performance_ratio_contract="$(psql_value "
SELECT trusted_output_rows::text || '|' ||
       model_invocations::text || '|' ||
       round(model_invocations_per_trusted_row, 3)::text || '|' ||
       model_processed_tokens::text || '|' ||
       round(model_processed_tokens_per_trusted_row, 3)::text
FROM otlet.production_status;
")"
echo "performance_ratio_contract=$performance_ratio_contract"
require_regex "$performance_ratio_contract" '^[1-9][0-9]*\|[1-9][0-9]*\|[0-9]+(\.[0-9]+)?\|[1-9][0-9]*\|[0-9]+(\.[0-9]+)?$' "Expected production_status to expose positive model-work ratios"

invariant_contract="$(psql_value "SELECT count(*) FROM otlet.verify_invariants();")"
echo "invariant_contract=$invariant_contract"
if [ "$invariant_contract" != "0" ]; then
  psql_exec -P border=2 -P null='' <<'SQL'
SELECT invariant_name, object_type, object_id, detail
FROM otlet.verify_invariants()
ORDER BY invariant_name, object_type, object_id
LIMIT 20;
SQL
  echo "Expected zero Otlet invariant violations, got $invariant_contract" >&2
  exit 1
fi

crash_scan
log "Otlet demo passed"
