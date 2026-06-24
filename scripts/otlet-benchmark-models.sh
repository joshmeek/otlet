#!/usr/bin/env bash
set -euo pipefail

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
runtime_name="${OTLET_RUNTIME_NAME:-linked_inproc}"
runtime_endpoint="${OTLET_RUNTIME_ENDPOINT:-linked}"
runs="${OTLET_BENCH_RUNS:-2}"
script_started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
suffix="${OTLET_BENCH_SUFFIX:-$(date +%s)}"

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

millis() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

stats() {
  python3 - "$@" <<'PY'
import math
import sys

values = sorted(int(v) for v in sys.argv[1:] if v)
if not values:
    print("0|0")
    raise SystemExit
p50 = values[(len(values) - 1) // 2]
p95 = values[max(0, math.ceil(len(values) * 0.95) - 1)]
print(f"{p50}|{p95}")
PY
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

reject_regex() {
  local text="$1"
  local pattern="$2"
  local message="$3"

  if grep -Eq -- "$pattern" <<<"$text"; then
    echo "$message" >&2
    exit 1
  fi
}

sanitize_name() {
  local raw="$1"
  local hash

  hash="$(printf '%s' "$raw" | cksum | awk '{print $1}')"
  printf 'bench_model_%s' "$hash"
}

ensure_default_artifact() {
  local cached
  local model_dir="${OTLET_MODEL_DIR:-/var/lib/postgresql/otlet-models}"
  local model_file="${OTLET_MODEL_FILE:-Qwen3-0.6B-Q8_0.gguf}"
  local model_url="${OTLET_MODEL_URL:-https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf}"

  cached="$(
    docker exec "$container" sh -lc \
      "find /var/lib/postgresql/.cache/huggingface/hub/models--Qwen--Qwen3-0.6B-GGUF/snapshots '$model_dir' -name '$model_file' -print -quit 2>/dev/null"
  )"
  if [ -n "$cached" ]; then
    printf '%s\n' "$cached"
    return
  fi

  docker exec "$container" sh -lc "mkdir -p '$model_dir' && curl -fL --retry 3 '$model_url' -o '$model_dir/$model_file'"
  printf '%s/%s\n' "$model_dir" "$model_file"
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

wait_job_done() {
  local job_id="$1"
  local label="$2"
  local attempts="${3:-300}"
  local delay="${4:-1}"
  local status

  for _ in $(seq 1 "$attempts"); do
    status="$(psql_value "SELECT status FROM otlet.jobs WHERE id = $job_id;")"
    case "$status" in
      complete|failed|canceled)
        printf '%s\n' "$status"
        return
        ;;
    esac
    sleep "$delay"
  done

  echo "Timed out waiting for $label job $job_id" >&2
  docker exec "$container" psql -U postgres -d postgres -P border=2 -P null='' \
    -c "SELECT id, task_name, subject_id, status, attempts, error FROM otlet.jobs WHERE id = $job_id;" >&2
  exit 1
}

wait_task_complete() {
  local task="$1"
  local expected_complete="${2:-1}"
  local attempts="${3:-600}"
  local delay="${4:-1}"
  local active complete failed

  for _ in $(seq 1 "$attempts"); do
    active="$(psql_value "SELECT count(*) FROM otlet.jobs WHERE task_name = '$task' AND status IN ('queued','running','cancel_requested');")"
    complete="$(psql_value "SELECT count(*) FROM otlet.jobs WHERE task_name = '$task' AND status = 'complete';")"
    failed="$(psql_value "SELECT count(*) FROM otlet.jobs WHERE task_name = '$task' AND status IN ('failed','canceled');")"
    if [ "$failed" != "0" ]; then
      docker exec "$container" psql -U postgres -d postgres -P border=2 -P null='' \
        -c "SELECT job_id, task_name, subject_id, status, error, raw_output FROM otlet.runs WHERE task_name = '$task' ORDER BY job_id;" >&2
      return 1
    fi
    if [ "$complete" -ge "$expected_complete" ] && [ "$active" = "0" ]; then
      return 0
    fi
    sleep "$delay"
  done

  echo "Timed out waiting for $task complete=$complete active=$active expected=$expected_complete" >&2
  return 1
}

crash_scan() {
  if docker logs --since "$script_started" "$container" 2>&1 | grep -Eiq 'segmentation|sigsegv|signal 11|core dump|panicked|assertion failed|server process .* was terminated'; then
    docker logs --since "$script_started" "$container" >&2
    exit 1
  fi
  echo "docker_crash_log_scan=ok"
}

run_row_job() {
  local model_name="$1"
  local task="$2"
  local subject="$3"
  local job_id status

  cleanup_task "$task"
  psql_exec \
    -v task_name="$task" \
    -v model_name="$model_name" >/dev/null <<'SQL'
SELECT otlet.register_task(
  :'task_name',
  'Benchmark row quality. Return exactly this JSON object: {"output":{"status":"needs_review","needs_review":true,"issues":["benchmark"]},"actions":[{"type":"create_record","record_type":"benchmark_fact","subject_id":"bench-row","body":{"status":"needs_review","semantic":"benchmark row"}}]}',
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
  '{"temperature":0,"max_tokens":192,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":12,"generation_trace_top_k":3}'::jsonb
);
SQL
  job_id="$(
    psql_exec -qAt -v task_name="$task" -v subject="$subject" <<'SQL'
SELECT id
FROM otlet.infer_async(
  :'task_name',
  :'subject',
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_model_benchmark_rows',
      'subject_id', :'subject',
      'ctid', '(0,1)',
      'xmin', '1',
      'source_hash', :'subject'
    ),
    'row', jsonb_build_object('id', :'subject', 'email', 'billing@', 'phone', NULL)
  )
);
SQL
  )"
  status="$(wait_job_done "$job_id" "$task" 600 1)"
  [ "$status" = "complete" ] || {
    echo "Expected row benchmark job to complete, got $status" >&2
    exit 1
  }
}

benchmark_model() {
  local artifact="$1"
  local model_name="$2"
  local index_name="bench_semantic_${model_name#bench_model_}_${suffix}"
  local index_task="${index_name}_task"
  local record_type="bench_semantic_fact_${model_name#bench_model_}"
  local trace_task="bench_trace_${model_name#bench_model_}_${suffix}"
  local timings=()
  local row_quality semantic_quality trace_quality stale_quality native_quality action_quality
  local total_ms p50 p95 artifact_bytes artifact_mb rss_mb tokens_per_second jobs_per_sec_per_gb
  local start end n row_contract queued materialized native_table fdw_plan custom_plan stale_rows fail_closed infer_plan trace_contract runtime_contract cache_reason

  log "Benchmarking $model_name"
  if ! docker exec "$container" test -s "$artifact"; then
    echo "Model artifact not found in container: $artifact" >&2
    exit 1
  fi

  psql_exec \
    -v runtime_name="$runtime_name" \
    -v runtime_endpoint="$runtime_endpoint" \
    -v model_name="$model_name" \
    -v model_artifact="$artifact" >/dev/null <<'SQL'
SET client_min_messages TO warning;
CREATE EXTENSION IF NOT EXISTS otlet;
DO $$
DECLARE
  idx record;
BEGIN
  FOR idx IN SELECT name FROM otlet.semantic_indexes WHERE name LIKE 'bench_semantic_%' LOOP
    PERFORM otlet.drop_semantic_index(idx.name);
  END LOOP;
END $$;
DROP TABLE IF EXISTS public.otlet_model_benchmark_rows;
CREATE TABLE public.otlet_model_benchmark_rows (
  id text PRIMARY KEY,
  body jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO public.otlet_model_benchmark_rows VALUES
  ('bench-row', '{"email":"billing@","phone":null}'::jsonb)
ON CONFLICT (id) DO UPDATE SET body = EXCLUDED.body, updated_at = clock_timestamp();
SELECT otlet.register_runtime(:'runtime_name', :'runtime_endpoint');
SELECT otlet.register_model(:'model_name', :'model_artifact', :'runtime_name');
SQL

  for n in $(seq 1 "$runs"); do
    start="$(millis)"
    run_row_job "$model_name" "bench_row_${model_name#bench_model_}_${suffix}_$n" "bench-row"
    end="$(millis)"
    timings+=("$((end - start))")
    echo "${model_name}_row_run_${n}_ms=$((end - start))"
  done
  IFS='|' read -r p50 p95 <<<"$(stats "${timings[@]}")"

  row_contract="$(psql_value "
SELECT count(*) FILTER (WHERE r.status = 'complete' AND r.output->>'status' = 'needs_review')::text || '|' ||
       count(*) FILTER (WHERE a.action_type = 'create_record')::text || '|' ||
       count(*) FILTER (WHERE ir.status = 'complete')::text
FROM otlet.runs r
LEFT JOIN otlet.jobs j ON j.id = r.job_id
LEFT JOIN otlet.actions a ON a.job_id = j.id
LEFT JOIN otlet.inference_receipts ir ON ir.job_id = j.id
WHERE r.task_name LIKE 'bench_row_${model_name#bench_model_}_${suffix}_%';
")"
  echo "${model_name}_row_contract=$row_contract"
  [ "$row_contract" = "$runs|$runs|$runs" ] && row_quality=20 || row_quality=0

  cleanup_task "$index_task"
  psql_exec -v index_name="$index_name" >/dev/null <<'SQL'
SELECT otlet.drop_semantic_index(:'index_name');
SQL
  psql_exec \
    -v index_name="$index_name" \
    -v model_name="$model_name" \
    -v record_type="$record_type" >/dev/null <<'SQL'
SET client_min_messages TO warning;
SELECT format('DROP VIEW IF EXISTS otlet.%I', otlet.semantic_source_view_name(:'index_name')) \gexec
SELECT format('DROP FOREIGN TABLE IF EXISTS otlet.%I', otlet.semantic_native_table_name(:'index_name')) \gexec
DROP TABLE IF EXISTS public.otlet_model_benchmark_vendor;
CREATE TABLE public.otlet_model_benchmark_vendor (
  id bigint PRIMARY KEY,
  name text NOT NULL,
  email text NOT NULL,
  phone text,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO public.otlet_model_benchmark_vendor (id, name, email, phone)
VALUES
  (1, 'Bench Vendor 1', 'billing1@example.test', '512-555-0001'),
  (2, 'Bench Vendor 2', 'billing@', '512-555-0002'),
  (3, 'Bench Vendor 3', 'billing3@example.test', NULL);
SELECT otlet.create_semantic_index(
  :'index_name',
  'public.otlet_model_benchmark_vendor'::regclass,
  'id',
  'Model benchmark semantic index. Return exactly this JSON object for every input row: {"output":{"status":"needs_review","needs_review":true,"issues":["model benchmark"]},"actions":[{"type":"create_record","record_type":"' || :'record_type' || '","subject_id":"db-owned","body":{"status":"needs_review","needs_review":true,"semantic":"indexed row"}}]}',
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
  '{"temperature":0,"max_tokens":192,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":12,"generation_trace_top_k":3}'::jsonb,
  :'record_type'
);
SQL
  queued="$(psql_value "SELECT otlet.refresh_semantic_index('$index_name');")"
  [ "$queued" = "3" ] || {
    echo "Expected 3 semantic benchmark jobs, got $queued" >&2
    exit 1
  }
  wait_task_complete "$index_task" 3 1800 1
  materialized="$(psql_value "SELECT otlet.materialize_semantic_index('$index_name');")"
  echo "${model_name}_semantic_materialized=$materialized"
  [ "$materialized" = "3" ] && semantic_quality=20 || semantic_quality=0

  native_table="$(psql_value "SELECT otlet.semantic_native_table_name('$index_name');")"
  fdw_plan="$(
    psql_exec -P border=0 -P pager=off <<SQL
EXPLAIN SELECT * FROM otlet.$native_table WHERE subject_id = '2';
SQL
  )"
  custom_plan="$(
    psql_exec -P border=0 -P pager=off <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM public.otlet_model_benchmark_vendor v
WHERE otlet.semantic_matches('$index_name', v.id::text, '{"status":"needs_review"}'::jsonb);
SQL
  )"
  require_contains "$fdw_plan" "Foreign Scan" "Expected FDW native path in benchmark"
  require_contains "$custom_plan" "Custom Scan (Otlet Semantic Source CustomScan)" "Expected CustomScan native path in benchmark"
  require_contains "$custom_plan" "Child Semantic Filter: stripped_before_child_plan" "Expected CustomScan semantic ownership"
  reject_regex "$custom_plan" "Filter: .*semantic_matches" "Benchmark semantic predicate leaked back to SQL filter"
  native_quality=15

  psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_model_benchmark_vendor
SET email = 'changed@example.test',
    updated_at = clock_timestamp()
WHERE id = 3;
SQL
  stale_rows="$(psql_value "SELECT stale_rows FROM otlet.semantic_index_status WHERE name = '$index_name';")"
  fail_closed="$(psql_value "SELECT count(*) FROM public.otlet_model_benchmark_vendor v WHERE v.id = 3 AND otlet.semantic_matches('$index_name', v.id::text, '{\"status\":\"needs_review\"}'::jsonb, 1, false);")"
  echo "${model_name}_stale_rows=$stale_rows"
  echo "${model_name}_stale_fail_closed_rows=$fail_closed"
  if [ "$stale_rows" != "0" ] && [ "$fail_closed" = "0" ]; then
    stale_quality=15
  else
    stale_quality=0
  fi

  infer_plan="$(
    psql_exec -P border=0 -P pager=off <<SQL
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM public.otlet_model_benchmark_vendor v
WHERE otlet.semantic_matches_auto('$index_name', v.id::text, '{"status":"needs_review"}'::jsonb, 0, 15000, 1, false);
SQL
  )"
  require_contains "$infer_plan" "Infer Now Batches: 1" "Expected benchmark infer-now"
  require_contains "$infer_plan" "Infer Now Input Path: tuple_slot_mvcc_json_no_spi" "Expected tuple-local infer-now"
  action_quality=10

  trace_contract="$(psql_value "
SELECT (receipt_id > 0)::text || '|' ||
       (prompt_tokens > 0)::text || '|' ||
       (generated_tokens >= 0)::text || '|' ||
       COALESCE(trace_version, '') || '|' ||
       COALESCE(probability_method, '') || '|' ||
       COALESCE(executor_origin, '') || '|' ||
       COALESCE(semantic_index_name, '')
FROM otlet.inference_receipt_trace_status
WHERE task_name = '$index_task'
  AND subject_id = '3'
  AND status = 'complete'
ORDER BY receipt_id DESC
LIMIT 1;
")"
  echo "${model_name}_trace_contract=$trace_contract"
  if [[ "$trace_contract" == true\|true\|true\|otlet_generation_trace_v1\|*\|customscan_infer_now\|"$index_name" ]]; then
    trace_quality=20
  else
    trace_quality=0
  fi

  cleanup_task "$trace_task"
  psql_exec \
    -v task_name="$trace_task" \
    -v model_name="$model_name" >/dev/null <<'SQL'
SELECT otlet.register_task(
  :'task_name',
  'Return exactly {"output":{"ok":true},"actions":[]}',
  '{"type":"object","required":["ok"],"additionalProperties":false,"properties":{"ok":{"type":"boolean"}}}'::jsonb,
  :'model_name',
  '{"temperature":0,"max_tokens":64,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":8,"generation_trace_top_k":3}'::jsonb
);
SQL
  for n in 1 2; do
    job_id="$(
      psql_exec -qAt -v task_name="$trace_task" -v subject="cache-row" <<'SQL'
SELECT id FROM otlet.infer_async(:'task_name', :'subject', '{"id":"cache-row","source_hash":"same"}'::jsonb);
SQL
    )"
    [ "$(wait_job_done "$job_id" "$trace_task" 600 1)" = "complete" ] || {
      echo "Trace/cache job failed" >&2
      exit 1
    }
  done
  cache_reason="$(psql_value "SELECT COALESCE(inference_cache_last_reason, '') FROM otlet.runtime_status WHERE runtime_name = '$runtime_name' AND model_name = '$model_name' LIMIT 1;")"
  echo "${model_name}_cache_last_reason=$cache_reason"

  runtime_contract="$(psql_value "
SELECT runtime_status || '|' ||
       slot_state || '|' ||
       COALESCE(tokens_per_second::text, '0') || '|' ||
       COALESCE(worker_process_rss_bytes::text, '0') || '|' ||
       COALESCE(model_memory_bytes::text, '0') || '|' ||
       (COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0))::text
FROM otlet.runtime_status
WHERE runtime_name = '$runtime_name'
  AND model_name = '$model_name'
LIMIT 1;
")"
  echo "${model_name}_runtime_contract=$runtime_contract"
  IFS='|' read -r runtime_status slot_state tokens_per_second rss_bytes model_memory_bytes cache_bounded <<<"$runtime_contract"
  [ "$runtime_status" = "ready" ] && [ "$slot_state" = "ready" ] && [ "$cache_bounded" = "true" ] || {
    echo "Expected ready bounded runtime, got $runtime_contract" >&2
    exit 1
  }

  artifact_bytes="$(docker exec "$container" stat -Lc '%s' "$artifact")"
  artifact_mb="$(python3 - "$artifact_bytes" <<'PY'
import sys
print(round(int(sys.argv[1]) / 1024 / 1024, 2))
PY
)"
  rss_mb="$(python3 - "$rss_bytes" <<'PY'
import sys
print(round(int(sys.argv[1]) / 1024 / 1024, 2))
PY
)"
  total_ms=0
  for elapsed in "${timings[@]}"; do
    total_ms=$((total_ms + elapsed))
  done
  quality=$((row_quality + semantic_quality + native_quality + stale_quality + action_quality + trace_quality))
  jobs_per_sec_per_gb="$(
    python3 - "$quality" "$runs" "$total_ms" "$artifact_bytes" <<'PY'
import sys
quality = int(sys.argv[1])
runs = int(sys.argv[2])
total_ms = max(int(sys.argv[3]), 1)
artifact_gb = max(int(sys.argv[4]) / 1024 / 1024 / 1024, 0.001)
if quality < 100:
    print("0")
else:
    print(round((runs / (total_ms / 1000)) / artifact_gb, 4))
PY
  )"
  verdict="pass"
  [ "$quality" = "100" ] || verdict="fail"

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$model_name" "$quality" "$p50" "$p95" "$tokens_per_second" "$rss_mb" "$artifact_mb" "$jobs_per_sec_per_gb" "$verdict"
}

require_container

artifacts=("$@")
if [ "${#artifacts[@]}" -eq 0 ]; then
  artifacts=("${OTLET_MODEL_ARTIFACT:-$(ensure_default_artifact)}")
fi

printf 'model|quality|p50_ms|p95_ms|tokens_per_second|rss_mb|artifact_mb|correct_jobs_per_sec_per_gb|verdict\n'
for artifact in "${artifacts[@]}"; do
  benchmark_model "$artifact" "$(sanitize_name "$artifact")"
done

crash_scan
