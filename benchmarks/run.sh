#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
db="${OTLET_PG_DATABASE:-postgres}"
db_user="${OTLET_PG_USER:-postgres}"
models_file="${OTLET_BENCH_MODELS:-$script_dir/models.tsv}"
models_metadata_file="${OTLET_BENCH_MODELS_METADATA:-$script_dir/models_metadata.tsv}"
output_root="${OTLET_BENCH_OUTPUT_DIR:-$script_dir/runs}"
bench_runs="${OTLET_BENCH_RUNS:-1}"
limit_models="${OTLET_BENCH_LIMIT_MODELS:-}"
download_enabled="${OTLET_BENCH_DOWNLOAD:-1}"
include_heavy="${OTLET_BENCH_INCLUDE_HEAVY:-0}"
strict_license="${OTLET_BENCH_STRICT_LICENSE:-0}"
max_artifact_gb="${OTLET_BENCH_MAX_ARTIFACT_GB:-8}"
keep_models="${OTLET_BENCH_KEEP_MODELS:-0}"
keep_sql_state="${OTLET_BENCH_KEEP_SQL_STATE:-0}"
timeout_seconds="${OTLET_BENCH_TIMEOUT_SECONDS:-7200}"
min_direct_schema_rate="${OTLET_BENCH_MIN_DIRECT_SCHEMA_RATE:-0.50}"
runtime_name="${OTLET_BENCH_RUNTIME_NAME:-linked_inproc}"
runtime_endpoint="${OTLET_BENCH_RUNTIME_ENDPOINT:-linked}"
scratch_root="${OTLET_BENCH_MODEL_DIR:-/var/lib/postgresql/otlet-benchmark-models}"
publish_report="${OTLET_BENCH_PUBLISH_REPORT:-0}"
publish_dir="${OTLET_BENCH_REPORT_DIR:-$script_dir/report/latest}"

run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_id="b$(date +%s)"
scratch_dir="$scratch_root/$run_id"
run_dir="$output_root/$run_stamp-$run_id"
metadata_tsv="$run_dir/metadata.tsv"
cleanup_tsv="$run_dir/cleanup.tsv"
downloaded_paths="$run_dir/downloaded_paths.tsv"
created_models="$run_dir/created_models.tsv"
created_foreign_tables="$run_dir/created_foreign_tables.tsv"
selected_models_tsv="$run_dir/models.tsv"
selected_models_metadata_tsv="$run_dir/models_metadata.tsv"
case_results_tsv="$run_dir/case_results.tsv"
model_summary_tsv="$run_dir/model_summary.tsv"
explain_txt="$run_dir/explain.txt"
cleanup_done=0
artifact_bytes_removed_early=0

mkdir -p "$run_dir"
: > "$downloaded_paths"
: > "$created_models"
: > "$created_foreign_tables"
: > "$explain_txt"

sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

psql_exec() {
  docker exec -i "$container" psql -U "$db_user" -d "$db" -X -v ON_ERROR_STOP=1 "$@"
}

psql_value() {
  docker exec -i "$container" psql -U "$db_user" -d "$db" -X -qAt -v ON_ERROR_STOP=1 "$@"
}

psql_file() {
  local file="$1"
  shift
  docker exec -i "$container" psql -U "$db_user" -d "$db" -X -v ON_ERROR_STOP=1 "$@" -f - < "$file"
}

psql_copy() {
  local query="$1"
  local dest="$2"
  docker exec -i "$container" psql -U "$db_user" -d "$db" -X -v ON_ERROR_STOP=1 \
    -c "\\copy ($query) TO STDOUT WITH CSV HEADER DELIMITER E'\t'" > "$dest"
}

write_kv_header() {
  printf 'key\tvalue\n' > "$1"
}

append_kv() {
  printf '%s\t%s\n' "$2" "$3" >> "$1"
}

container_path_exists() {
  local path="$1"
  docker exec "$container" sh -lc "test -e $(sh_quote "$path")"
}

container_file_size() {
  local path="$1"
  docker exec "$container" sh -lc "stat -Lc%s $(sh_quote "$path") 2>/dev/null || echo 0"
}

find_existing_artifact() {
  local hf_repo="$1"
  local filename="$2"
  local basename
  local repo_cache
  basename="$(basename "$filename")"
  repo_cache="models--${hf_repo//\//--}"
  docker exec "$container" sh -lc "find /var/lib/postgresql/otlet-models /var/lib/postgresql/.cache/huggingface/hub/$(sh_quote "$repo_cache")/snapshots -name $(sh_quote "$basename") -print -quit 2>/dev/null" | head -n 1 || true
}

download_artifact() {
  local hf_repo="$1"
  local filename="$2"
  local model_key="$3"
  local requires_split="${4:-false}"
  local dest_dir="$scratch_dir/$model_key"
  local dest="$dest_dir/$(basename "$filename")"
  local tmp="$dest.part"

  docker exec "$container" sh -lc "mkdir -p $(sh_quote "$dest_dir")"
  if [[ "$requires_split" = "true" && "$filename" =~ ^(.+)-00001-of-([0-9]+)\.gguf$ ]]; then
    local prefix="${BASH_REMATCH[1]}"
    local total="${BASH_REMATCH[2]}"
    local part
    for part in $(seq -f "%05g" 1 "$((10#$total))"); do
      local split_file="${prefix}-${part}-of-${total}.gguf"
      local split_dest="$dest_dir/$(basename "$split_file")"
      local split_tmp="$split_dest.part"
      local split_url="https://huggingface.co/$hf_repo/resolve/main/$split_file"
      docker exec "$container" sh -lc "rm -f $(sh_quote "$split_tmp") && curl -fL --retry 3 --connect-timeout 20 $(sh_quote "$split_url") -o $(sh_quote "$split_tmp") && mv $(sh_quote "$split_tmp") $(sh_quote "$split_dest")"
    done
  else
    local url="https://huggingface.co/$hf_repo/resolve/main/$filename"
    docker exec "$container" sh -lc "rm -f $(sh_quote "$tmp") && curl -fL --retry 3 --connect-timeout 20 $(sh_quote "$url") -o $(sh_quote "$tmp") && mv $(sh_quote "$tmp") $(sh_quote "$dest")"
  fi
  printf '%s\t%s\n' "$model_key" "$dest" >> "$downloaded_paths"
  printf '%s\n' "$dest"
}

model_artifact_path() {
  local model_name="$1"
  psql_value -v model_name="$model_name" <<'SQL'
SELECT artifact_path FROM otlet.models WHERE name = :'model_name';
SQL
}

ensure_runtime() {
  psql_exec -v runtime_name="$runtime_name" -v runtime_endpoint="$runtime_endpoint" >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS otlet;
SELECT otlet.register_runtime(:'runtime_name', :'runtime_endpoint');
SQL
}

register_model() {
  local model_name="$1"
  local artifact_path="$2"
  psql_exec -v model_name="$model_name" -v artifact_path="$artifact_path" -v runtime_name="$runtime_name" >/dev/null <<'SQL'
SELECT otlet.register_model(:'model_name', :'artifact_path', :'runtime_name');
SQL
}

ensure_result_tables() {
  psql_exec >/dev/null <<'SQL'
CREATE SCHEMA IF NOT EXISTS otlet_bench_source;
CREATE TABLE IF NOT EXISTS otlet_bench_source.case_result (
  run_id text NOT NULL,
  model_key text NOT NULL,
  case_id text NOT NULL,
  track text NOT NULL,
  subject_id text NOT NULL,
  expected_match text,
  actual_match text,
  raw_match text,
  expected_confidence_floor text,
  actual_confidence text,
  raw_confidence text,
  expected_action_type text,
  actual_action_type text,
  raw_action_type text,
  schema_valid boolean NOT NULL DEFAULT false,
  match_correct boolean NOT NULL DEFAULT false,
  diagnostic_match_correct boolean NOT NULL DEFAULT false,
  confidence_correct boolean NOT NULL DEFAULT false,
  diagnostic_confidence_correct boolean NOT NULL DEFAULT false,
  action_correct boolean NOT NULL DEFAULT false,
  diagnostic_action_correct boolean NOT NULL DEFAULT false,
  false_merge boolean NOT NULL DEFAULT false,
  injection_resisted boolean NOT NULL DEFAULT true,
  materialized boolean NOT NULL DEFAULT false,
  source_hash_present boolean NOT NULL DEFAULT false,
  receipt_id bigint,
  output_id bigint,
  raw_output_hash text,
  error text,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, model_key, case_id)
);
CREATE TABLE IF NOT EXISTS otlet_bench_source.model_summary (
  run_id text NOT NULL,
  model_key text NOT NULL,
  model_name text NOT NULL,
  family text,
  tier text,
  quant text,
  declared_params_b numeric,
  active_params_b numeric,
  context_tokens bigint,
  license_note text,
  source_url text,
  artifact_path text,
  artifact_bytes bigint,
  external_artifact boolean NOT NULL DEFAULT false,
  run_status text NOT NULL,
  unsupported_reason text,
  total_cases bigint NOT NULL DEFAULT 0,
  schema_valid_rate numeric NOT NULL DEFAULT 0,
  entity_accuracy numeric NOT NULL DEFAULT 0,
  abstention_false_merge_rate numeric NOT NULL DEFAULT 0,
  hallucinated_trusted_action_rate numeric NOT NULL DEFAULT 0,
  stale_leak_count bigint NOT NULL DEFAULT 0,
  source_table_mutated boolean NOT NULL DEFAULT false,
  worker_crash_count bigint NOT NULL DEFAULT 0,
  p50_generate_ms numeric,
  p95_generate_ms numeric,
  mean_tokens_per_second numeric,
  artifact_gb numeric,
  resident_gb numeric,
  jobs_per_second numeric,
  correct_jobs_per_second_per_gb numeric,
  quality_per_artifact_gb numeric,
  contract_score numeric NOT NULL DEFAULT 0,
  entity_resolution_score numeric NOT NULL DEFAULT 0,
  abstention_score numeric NOT NULL DEFAULT 0,
  dirty_data_score numeric NOT NULL DEFAULT 0,
  triage_score numeric NOT NULL DEFAULT 0,
  triage_abstention_score numeric NOT NULL DEFAULT 0,
  row_watch_score numeric NOT NULL DEFAULT 0,
  typed_action_score numeric NOT NULL DEFAULT 0,
  semantic_materialization_score numeric NOT NULL DEFAULT 0,
  confidence_score numeric NOT NULL DEFAULT 0,
  diagnostic_entity_accuracy numeric NOT NULL DEFAULT 0,
  diagnostic_triage_accuracy numeric NOT NULL DEFAULT 0,
  diagnostic_action_accuracy numeric NOT NULL DEFAULT 0,
  diagnostic_confidence_accuracy numeric NOT NULL DEFAULT 0,
  diagnostic_quality_score numeric NOT NULL DEFAULT 0,
  quality_score numeric NOT NULL DEFAULT 0,
  trusted_quality numeric NOT NULL DEFAULT 0,
  resource_fit numeric NOT NULL DEFAULT 0,
  overall_fit numeric NOT NULL DEFAULT 0,
  diagnostic_fit numeric NOT NULL DEFAULT 0,
  verdict text NOT NULL,
  cleanup_policy text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, model_key)
);

ALTER TABLE otlet_bench_source.model_summary
  ADD COLUMN IF NOT EXISTS trusted_quality numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS resource_fit numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS overall_fit numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS diagnostic_fit numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS triage_score numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS triage_abstention_score numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS diagnostic_triage_accuracy numeric NOT NULL DEFAULT 0;
SQL
}

insert_terminal_summary() {
  local model_key="$1"
  local model_name="$2"
  local family="$3"
  local tier="$4"
  local quant="$5"
  local declared_params_b="$6"
  local active_params_b="$7"
  local context_tokens="$8"
  local license_note="$9"
  local source_url="${10}"
  local artifact_path="${11}"
  local artifact_bytes="${12}"
  local external_artifact="${13}"
  local reason="${14}"
  local run_status="${15}"
  local verdict="${16}"
  psql_exec \
    -v run_id="$run_id" \
    -v model_key="$model_key" \
    -v model_name="$model_name" \
    -v family="$family" \
    -v tier="$tier" \
    -v quant="$quant" \
    -v declared_params_b="$declared_params_b" \
    -v active_params_b="$active_params_b" \
    -v context_tokens="$context_tokens" \
    -v license_note="$license_note" \
    -v source_url="$source_url" \
    -v artifact_path="$artifact_path" \
    -v artifact_bytes="$artifact_bytes" \
    -v external_artifact="$external_artifact" \
    -v reason="$reason" \
    -v run_status="$run_status" \
    -v verdict="$verdict" \
    -v cleanup_policy="$(cleanup_policy)" >/dev/null <<'SQL'
INSERT INTO otlet_bench_source.model_summary (
  run_id,
  model_key,
  model_name,
  family,
  tier,
  quant,
  declared_params_b,
  active_params_b,
  context_tokens,
  license_note,
  source_url,
  artifact_path,
  artifact_bytes,
  external_artifact,
  run_status,
  unsupported_reason,
  verdict,
  cleanup_policy
)
VALUES (
  :'run_id',
  :'model_key',
  :'model_name',
  :'family',
  :'tier',
  :'quant',
  NULLIF(:'declared_params_b', '')::numeric,
  NULLIF(:'active_params_b', '')::numeric,
  NULLIF(:'context_tokens', '')::bigint,
  :'license_note',
  :'source_url',
  :'artifact_path',
  (:'artifact_bytes')::bigint,
  (:'external_artifact')::boolean,
  :'run_status',
  :'reason',
  :'verdict',
  :'cleanup_policy'
)
ON CONFLICT (run_id, model_key) DO UPDATE
  SET run_status = EXCLUDED.run_status,
      unsupported_reason = EXCLUDED.unsupported_reason,
      verdict = EXCLUDED.verdict,
      cleanup_policy = EXCLUDED.cleanup_policy;
SQL
}

insert_unsupported_summary() {
  insert_terminal_summary "$@" not_supported not_supported
}

insert_failed_summary() {
  insert_terminal_summary "$@" failed too_unreliable
}

cleanup_policy() {
  printf 'models=%s sql_state=%s' "$keep_models" "$keep_sql_state"
}

task_prefix_like() {
  printf "%s\\_%%" "$run_id"
}

cleanup_sql_state() {
  local prefix
  prefix="$(task_prefix_like)"
  psql_exec -v prefix="$prefix" >/dev/null <<'SQL' || true
SELECT format('DROP FOREIGN TABLE IF EXISTS %I.%I', n.nspname, c.relname)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'f'
  AND n.nspname = 'otlet'
  AND c.relname LIKE :'prefix' ESCAPE '\'
\gexec
SQL
  psql_exec -v prefix="$prefix" >/dev/null <<'SQL' || true
WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.semantic_materializations sm
USING otlet.records r, otlet.actions a, bench_jobs bj
WHERE sm.record_id = r.id
  AND r.action_id = a.id
  AND a.job_id = bj.id;

WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.records r
USING otlet.actions a, bench_jobs bj
WHERE r.action_id = a.id
  AND a.job_id = bj.id;

WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.actions a
USING bench_jobs bj
WHERE a.job_id = bj.id;

WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.outputs o
USING bench_jobs bj
WHERE o.job_id = bj.id;

WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.inference_receipts r
USING bench_jobs bj
WHERE r.job_id = bj.id;

WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.worker_events e
USING bench_jobs bj
WHERE e.job_id = bj.id;

DELETE FROM otlet.jobs j
WHERE j.task_name LIKE :'prefix' ESCAPE '\';

DELETE FROM otlet.model_selection_policies p
WHERE p.task_name LIKE :'prefix' ESCAPE '\';

DELETE FROM otlet.watches w
WHERE w.name LIKE :'prefix' ESCAPE '\';

DELETE FROM otlet.semantic_join_indexes sji
WHERE sji.name LIKE :'prefix' ESCAPE '\';

DELETE FROM otlet.semantic_indexes si
WHERE si.name LIKE :'prefix' ESCAPE '\';

DELETE FROM otlet.tasks t
WHERE t.name LIKE :'prefix' ESCAPE '\';

DROP SCHEMA IF EXISTS otlet_bench_source CASCADE;
SQL
}

cleanup_models() {
  local names
  if [[ ! -s "$created_models" ]]; then
    return
  fi
  names="$(paste -sd, "$created_models")"
  psql_exec -v model_names="$names" >/dev/null <<'SQL'
WITH names AS (
  SELECT unnest(string_to_array(:'model_names', ',')) AS model_name
),
deleted_slots AS (
  DELETE FROM otlet.runtime_slots s
  USING names
  WHERE s.model_name = names.model_name
  RETURNING s.model_name
)
DELETE FROM otlet.models m
USING names
WHERE m.name = names.model_name;
SQL
}

created_model_residue_count() {
  local names
  if [[ ! -s "$created_models" ]]; then
    printf '0'
    return
  fi
  names="$(paste -sd, "$created_models")"
  psql_value -v model_names="$names" <<'SQL' || printf 'unknown'
WITH names AS (
  SELECT unnest(string_to_array(:'model_names', ',')) AS model_name
)
SELECT
  (SELECT count(*) FROM otlet.models m JOIN names ON names.model_name = m.name)
  + (SELECT count(*) FROM otlet.runtime_slots s JOIN names ON names.model_name = s.model_name);
SQL
}

scratch_bytes() {
  docker exec "$container" sh -lc "if [ -d $(sh_quote "$scratch_dir") ]; then du -sb $(sh_quote "$scratch_dir") 2>/dev/null | awk '{print \$1}'; else echo 0; fi"
}

container_dir_bytes() {
  local path="$1"
  docker exec "$container" sh -lc "if [ -d $(sh_quote "$path") ]; then du -sb $(sh_quote "$path") 2>/dev/null | awk '{print \$1}'; else echo 0; fi"
}

cleanup_downloaded_model() {
  local model_name="$1"
  local base_model_key="$2"
  local external_artifact="$3"
  local model_dir="$scratch_dir/$base_model_key"
  local removed_bytes=0

  if [[ "$keep_models" = "1" || "$external_artifact" != "false" ]]; then
    return
  fi

  psql_exec -v model_name="$model_name" >/dev/null <<'SQL' || true
DELETE FROM otlet.runtime_slots WHERE model_name = :'model_name';
SQL
  removed_bytes="$(container_dir_bytes "$model_dir")"
  docker exec "$container" sh -lc "rm -rf $(sh_quote "$model_dir")" >/dev/null || true
  artifact_bytes_removed_early=$((artifact_bytes_removed_early + removed_bytes))
}

perform_cleanup() {
  if [[ "$cleanup_done" = "1" ]]; then
    return
  fi
  cleanup_done=1
  write_kv_header "$cleanup_tsv"

  local removed_bytes=0
  local scratch_removed=false
  local sql_removed=false
  local models_removed=false
  local model_residue=0

  if [[ "$keep_sql_state" = "1" ]]; then
    append_kv "$cleanup_tsv" sql_state_removed false
  else
    cleanup_sql_state
    sql_removed=true
    append_kv "$cleanup_tsv" sql_state_removed true
  fi

  if [[ "$keep_models" = "1" ]]; then
    append_kv "$cleanup_tsv" model_artifacts_removed false
    append_kv "$cleanup_tsv" scratch_dir_kept "$scratch_dir"
  else
    cleanup_models
    removed_bytes="$(scratch_bytes)"
    docker exec "$container" sh -lc "rm -rf $(sh_quote "$scratch_dir")" >/dev/null || true
    removed_bytes=$((removed_bytes + artifact_bytes_removed_early))
    model_residue="$(created_model_residue_count)"
    if [[ "$model_residue" = "0" ]]; then
      models_removed=true
    fi
    scratch_removed=true
    append_kv "$cleanup_tsv" model_artifacts_removed true
    append_kv "$cleanup_tsv" scratch_dir_removed "$scratch_dir"
    append_kv "$cleanup_tsv" model_artifact_bytes_removed "$removed_bytes"
  fi

  append_kv "$cleanup_tsv" sql_cleanup_policy "$keep_sql_state"
  append_kv "$cleanup_tsv" model_cleanup_policy "$keep_models"
  append_kv "$cleanup_tsv" downloaded_path_count "$(wc -l < "$downloaded_paths" | tr -d ' ')"
  append_kv "$cleanup_tsv" created_model_count "$(wc -l < "$created_models" | tr -d ' ')"
  append_kv "$cleanup_tsv" created_model_residue_count "$model_residue"
  append_kv "$cleanup_tsv" cleanup_complete true
  append_kv "$cleanup_tsv" scratch_removed "$scratch_removed"
  append_kv "$cleanup_tsv" sql_removed "$sql_removed"
  append_kv "$cleanup_tsv" created_models_removed "$models_removed"
}

trap perform_cleanup EXIT

wait_for_task() {
  local task_name="$1"
  local deadline=$((SECONDS + timeout_seconds))
  local pending
  while true; do
    pending="$(psql_value -v task_name="$task_name" <<'SQL'
SELECT count(*) FROM otlet.jobs WHERE task_name = :'task_name' AND status IN ('queued', 'running', 'cancel_requested');
SQL
)"
    if [[ "$pending" = "0" ]]; then
      break
    fi
    if (( SECONDS >= deadline )); then
      printf 'task_timeout=%s pending=%s timeout_seconds=%s\n' "$task_name" "$pending" "$timeout_seconds" >&2
      return 1
    fi
    sleep 1
  done
}

source_hash() {
  psql_value -c "SELECT COALESCE(md5(string_agg(to_jsonb(v)::text, ',' ORDER BY v.id)), '') FROM otlet_bench_source.vendor_entity v;"
}

count_worker_crashes() {
  psql_value -v started_at="$1" <<'SQL'
SELECT count(*) FROM otlet.worker_events WHERE created_at >= (:'started_at')::timestamptz AND event_type ILIKE '%crash%';
SQL
}

direct_schema_rate() {
  local task_name="$1"
  psql_value -v task_name="$task_name" <<'SQL'
SELECT COALESCE(avg((
  status = 'complete'
  AND output_id IS NOT NULL
  AND schema_validation_status = 'passed'
)::int), 0)::numeric
FROM otlet.runs
WHERE task_name = :'task_name';
SQL
}

run_explain_smoke() {
  local join_index="$1"
  local foreign_table="$2"
  local row_index="$3"
  local custom_explain_file="$run_dir/${join_index}_customscan_explain.txt"
  local fdw_explain_file="$run_dir/${join_index}_fdw_explain.txt"
  printf '%s\n' "$foreign_table" >> "$created_foreign_tables"
  psql_exec -v foreign_table="$foreign_table" -v join_index="$join_index" >/dev/null <<'SQL'
SELECT otlet.create_semantic_join_foreign_table(:'foreign_table', :'join_index');
SQL
  psql_exec -c "EXPLAIN SELECT subject_id, body, stale FROM otlet.$foreign_table WHERE subject_id = 'bench-1001:bench-42';" > "$fdw_explain_file"
  psql_exec -v row_index="$row_index" > "$custom_explain_file" <<'SQL'
EXPLAIN SELECT v.id
FROM otlet_bench_source.vendor_entity v
WHERE otlet.semantic_matches_auto(:'row_index', v.id::text, '{"status":"needs_review"}'::jsonb);
SQL
  {
    printf '\n-- %s FDW EXPLAIN --\n' "$join_index"
    cat "$fdw_explain_file"
    printf '\n-- %s CustomScan EXPLAIN --\n' "$join_index"
    cat "$custom_explain_file"
  } >> "$explain_txt"
}

export_run_artifacts() {
  psql_copy "SELECT * FROM otlet_bench_source.case_result WHERE run_id = '$run_id' ORDER BY model_key, case_id" "$case_results_tsv" || return
  psql_copy "SELECT * FROM otlet_bench_source.model_summary WHERE run_id = '$run_id' ORDER BY overall_fit DESC, trusted_quality DESC, model_key" "$model_summary_tsv" || return
  python3 "$script_dir/report.py" "$run_dir" >/dev/null || return
}

publish_report_artifacts() {
  if [[ "$publish_report" != "1" ]]; then
    return
  fi
  mkdir -p "$publish_dir"
  rm -f "$publish_dir"/*
  cp \
    "$run_dir/otlet-model-benchmark.md" \
    "$run_dir/overall.svg" \
    "$run_dir/pareto.svg" \
    "$run_dir/params.svg" \
    "$run_dir/latency.svg" \
    "$run_dir/efficiency.svg" \
    "$run_dir/scorecard.tsv" \
    "$metadata_tsv" \
    "$selected_models_tsv" \
    "$case_results_tsv" \
    "$model_summary_tsv" \
    "$cleanup_tsv" \
    "$explain_txt" \
    "$publish_dir"/
  if [[ -f "$selected_models_metadata_tsv" ]]; then
    cp "$selected_models_metadata_tsv" "$publish_dir"/
  fi
  python3 "$script_dir/report.py" "$publish_dir" >/dev/null
}

score_model_run() {
  local run_model_key="$1"
  local model_key="$2"
  local model_name="$3"
  local family="$4"
  local tier="$5"
  local quant="$6"
  local declared_params_b="$7"
  local active_params_b="$8"
  local context_tokens="$9"
  local license_note="${10}"
  local source_url="${11}"
  local artifact_path="${12}"
  local artifact_bytes="${13}"
  local external_artifact="${14}"
  local direct_task="${15}"
  local triage_task="${16}"
  local join_task="${17}"
  local row_task="${18}"
  local join_index="${19}"
  local wall_ms="${20}"
  local source_unchanged="${21}"
  local stale_leak_count="${22}"
  local worker_crash_count="${23}"

  psql_file "$script_dir/scoring.sql" \
    -v run_id="$run_id" \
    -v model_key="$run_model_key" \
    -v model_name="$model_name" \
    -v family="$family" \
    -v tier="$tier" \
    -v quant="$quant" \
    -v declared_params_b="$declared_params_b" \
    -v active_params_b="$active_params_b" \
    -v context_tokens="$context_tokens" \
    -v license_note="$license_note" \
    -v source_url="$source_url" \
    -v artifact_path="$artifact_path" \
    -v artifact_bytes="$artifact_bytes" \
    -v external_artifact="$external_artifact" \
    -v direct_task="$direct_task" \
    -v triage_task="$triage_task" \
    -v join_task="$join_task" \
    -v row_task="$row_task" \
    -v join_index="$join_index" \
    -v wall_ms="$wall_ms" \
    -v source_unchanged="$source_unchanged" \
    -v stale_leak_count="$stale_leak_count" \
    -v worker_crash_count="$worker_crash_count" \
    -v run_status="complete" \
    -v unsupported_reason="" \
    -v cleanup_policy="$(cleanup_policy)"
}

run_one_model() {
  local base_model_key="$1"
  local hf_repo="$2"
  local filename="$3"
  local quant="$4"
  local family="$5"
  local tier="$6"
  local license_note="$7"
  local source_url="$8"
  local include_by_default="$9"
  local max_gb="${10}"
  local requires_split="${11}"
  local declared_params_b="${12}"
  local active_params_b="${13}"
  local context_tokens="${14}"
  local notes="${15}"
  local run_index="${16}"

  local run_model_key="$base_model_key"
  if [[ "$bench_runs" != "1" ]]; then
    run_model_key="${base_model_key}_r${run_index}"
  fi

  local model_name="$base_model_key"
  local artifact_path=""
  local artifact_bytes=0
  local external_artifact=true
  local unsupported_reason=""

  if [[ "$tier" = "blocked" ]]; then
    unsupported_reason="manifest tier is blocked"
  elif [[ "$tier" = "heavy" && "$include_heavy" != "1" ]]; then
    unsupported_reason="heavy tier skipped; set OTLET_BENCH_INCLUDE_HEAVY=1"
  elif [[ "$requires_split" = "true" && ! "$filename" =~ -00001-of-[0-9]+\.gguf$ ]]; then
    unsupported_reason="split GGUF filename must point at part 00001"
  elif [[ -z "$filename" ]]; then
    unsupported_reason="manifest has no runnable GGUF filename"
  elif [[ "$strict_license" = "1" && "$license_note" =~ (verify|other|terms) ]]; then
    unsupported_reason="license note requires review under OTLET_BENCH_STRICT_LICENSE=1"
  elif awk "BEGIN { exit !($max_gb > $max_artifact_gb) }"; then
    unsupported_reason="max artifact GB exceeds OTLET_BENCH_MAX_ARTIFACT_GB=$max_artifact_gb"
  fi

  if [[ -z "$unsupported_reason" ]]; then
    artifact_path="$(model_artifact_path "$base_model_key")"
    if [[ -n "$artifact_path" ]]; then
      external_artifact=true
      model_name="$base_model_key"
    else
      artifact_path="$(find_existing_artifact "$hf_repo" "$filename")"
      if [[ -n "$artifact_path" ]]; then
        external_artifact=true
        model_name="$base_model_key"
        if register_model "$model_name" "$artifact_path"; then
          printf '%s\n' "$model_name" >> "$created_models"
        else
          unsupported_reason="model registration failed for existing artifact"
          artifact_path=""
        fi
      elif [[ "$download_enabled" = "1" ]]; then
        local download_log="$run_dir/${run_model_key}_download.err"
        if artifact_path="$(download_artifact "$hf_repo" "$filename" "$base_model_key" "$requires_split" 2>"$download_log")"; then
          external_artifact=false
          model_name="${run_id}_${base_model_key}"
          if register_model "$model_name" "$artifact_path"; then
            printf '%s\n' "$model_name" >> "$created_models"
          else
            unsupported_reason="model registration failed for downloaded artifact"
            artifact_path=""
          fi
        else
          unsupported_reason="download failed; see $(basename "$download_log")"
          artifact_path=""
        fi
      else
        unsupported_reason="artifact not found and OTLET_BENCH_DOWNLOAD=0"
      fi
    fi
  fi

  if [[ -n "$artifact_path" ]]; then
    artifact_bytes="$(container_file_size "$artifact_path")"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_model_key" "$base_model_key" "$hf_repo" "$filename" "$quant" "$family" "$tier" \
    "$license_note" "$source_url" "$include_by_default" "$max_gb" "$requires_split" \
    "$declared_params_b" "$active_params_b" "$context_tokens" "$artifact_path" "$artifact_bytes" \
    "$external_artifact" "${unsupported_reason:-complete}" "$notes" >> "$selected_models_tsv"

  if [[ -n "$unsupported_reason" ]]; then
    printf 'model=%s verdict=not_supported reason=%s\n' "$run_model_key" "$unsupported_reason"
    insert_unsupported_summary "$run_model_key" "$model_name" "$family" "$tier" "$quant" "$declared_params_b" "$active_params_b" "$context_tokens" "$license_note" "$source_url" "$artifact_path" "$artifact_bytes" "$external_artifact" "$unsupported_reason"
    return
  fi

  local direct_task="${run_id}_${run_model_key}_direct"
  local triage_task="${run_id}_${run_model_key}_triage"
  local join_index="${run_id}_${run_model_key}_join"
  local join_task="${join_index}_task"
  local row_index="${run_id}_${run_model_key}_row"
  local row_task="${row_index}_task"
  local foreign_table="${run_id}_${run_model_key}_ft"
  local started_at
  local started_s
  local ended_s
  local wall_ms
  local before_hash
  local after_hash
  local source_unchanged
  local stale_leak_count
  local worker_crash_count

  printf 'model=%s artifact=%s\n' "$run_model_key" "$artifact_path"

  fail_current_model() {
    local reason="$1"
    printf 'model=%s verdict=failed reason=%s\n' "$run_model_key" "$reason"
    insert_failed_summary "$run_model_key" "$model_name" "$family" "$tier" "$quant" "$declared_params_b" "$active_params_b" "$context_tokens" "$license_note" "$source_url" "$artifact_path" "$artifact_bytes" "$external_artifact" "$reason"
    cleanup_downloaded_model "$model_name" "$base_model_key" "$external_artifact"
  }

  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  started_s="$(date +%s)"

  if ! psql_file "$script_dir/fixtures.sql" \
    -v model_name="$model_name" \
    -v direct_task="$direct_task" \
    -v triage_task="$triage_task" \
    -v join_index="$join_index" \
    -v row_index="$row_index" >/dev/null; then
    fail_current_model "fixture setup failed"
    return
  fi

  if ! before_hash="$(source_hash)"; then
    fail_current_model "source hash before direct task failed"
    return
  fi

  if ! psql_exec -v task_name="$direct_task" >/dev/null <<'SQL'
SELECT otlet.run_task(:'task_name');
SQL
  then
    fail_current_model "direct task enqueue failed"
    return
  fi
  if ! wait_for_task "$direct_task"; then
    fail_current_model "direct task timed out"
    return
  fi

  if ! psql_exec -v task_name="$triage_task" >/dev/null <<'SQL'
SELECT otlet.run_task(:'task_name');
SQL
  then
    fail_current_model "triage task enqueue failed"
    return
  fi
  if ! wait_for_task "$triage_task"; then
    fail_current_model "triage task timed out"
    return
  fi

  local direct_rate
  if ! direct_rate="$(direct_schema_rate "$direct_task")"; then
    fail_current_model "direct schema-rate query failed"
    return
  fi
  if awk "BEGIN { exit !($direct_rate < $min_direct_schema_rate) }"; then
    if ! after_hash="$(source_hash)"; then
      fail_current_model "source hash after direct task failed"
      return
    fi
    if [[ "$before_hash" = "$after_hash" ]]; then
      source_unchanged=true
    else
      source_unchanged=false
    fi
    ended_s="$(date +%s)"
    wall_ms="$(( (ended_s - started_s) * 1000 ))"
    stale_leak_count=0
    if ! worker_crash_count="$(count_worker_crashes "$started_at")"; then
      fail_current_model "worker crash query failed"
      return
    fi
    printf 'model=%s skip_semantic=true direct_schema_valid_rate=%s min_direct_schema_rate=%s\n' "$run_model_key" "$direct_rate" "$min_direct_schema_rate"
    if ! score_model_run \
      "$run_model_key" \
      "$base_model_key" \
      "$model_name" \
      "$family" \
      "$tier" \
      "$quant" \
      "$declared_params_b" \
      "$active_params_b" \
      "$context_tokens" \
      "$license_note" \
      "$source_url" \
      "$artifact_path" \
      "$artifact_bytes" \
      "$external_artifact" \
      "$direct_task" \
      "$triage_task" \
      "$join_task" \
      "$row_task" \
      "$join_index" \
      "$wall_ms" \
      "$source_unchanged" \
      "$stale_leak_count" \
      "$worker_crash_count"; then
      fail_current_model "scoring failed after direct task"
      return
    fi
    cleanup_downloaded_model "$model_name" "$base_model_key" "$external_artifact"
    return
  fi

  if ! psql_exec -v join_index="$join_index" >/dev/null <<'SQL'
SELECT otlet.refresh_semantic_join_index(:'join_index');
SQL
  then
    fail_current_model "semantic join refresh enqueue failed"
    return
  fi
  if ! wait_for_task "$join_task"; then
    fail_current_model "semantic join refresh timed out"
    return
  fi

  if ! psql_exec -v row_index="$row_index" >/dev/null <<'SQL'
SELECT otlet.refresh_semantic_index(:'row_index');
SQL
  then
    fail_current_model "semantic row refresh enqueue failed"
    return
  fi
  if ! wait_for_task "$row_task"; then
    fail_current_model "semantic row refresh timed out"
    return
  fi

  if ! after_hash="$(source_hash)"; then
    fail_current_model "source hash after semantic refresh failed"
    return
  fi
  if [[ "$before_hash" = "$after_hash" ]]; then
    source_unchanged=true
  else
    source_unchanged=false
  fi

  if ! run_explain_smoke "$join_index" "$foreign_table" "$row_index"; then
    fail_current_model "EXPLAIN smoke failed"
    return
  fi

  if ! psql_exec >/dev/null <<'SQL'
SELECT otlet.watch_semantic_stale('otlet_bench_source.vendor_entity'::regclass, 'id');
UPDATE otlet_bench_source.vendor_entity
SET notes = notes || ' benchmark stale proof mutation'
WHERE id = 'bench-1001';
SQL
  then
    fail_current_model "stale proof mutation failed"
    return
  fi
  if ! stale_leak_count="$(psql_value -v join_index="$join_index" <<'SQL'
SELECT count(*)
FROM otlet_bench_source.case_input ci
WHERE ci.subject_id LIKE 'bench-1001:%'
  AND otlet.semantic_join_matches(:'join_index', ci.subject_id, '{}'::jsonb);
SQL
  )"; then
    fail_current_model "stale leak query failed"
    return
  fi

  ended_s="$(date +%s)"
  wall_ms="$(( (ended_s - started_s) * 1000 ))"
  if ! worker_crash_count="$(count_worker_crashes "$started_at")"; then
    fail_current_model "worker crash query failed"
    return
  fi

  if ! score_model_run \
    "$run_model_key" \
    "$base_model_key" \
    "$model_name" \
    "$family" \
    "$tier" \
    "$quant" \
    "$declared_params_b" \
    "$active_params_b" \
    "$context_tokens" \
    "$license_note" \
    "$source_url" \
    "$artifact_path" \
    "$artifact_bytes" \
    "$external_artifact" \
    "$direct_task" \
    "$triage_task" \
    "$join_task" \
    "$row_task" \
    "$join_index" \
    "$wall_ms" \
    "$source_unchanged" \
    "$stale_leak_count" \
    "$worker_crash_count"; then
    fail_current_model "scoring failed"
    return
  fi

  cleanup_downloaded_model "$model_name" "$base_model_key" "$external_artifact"
}

write_metadata() {
  write_kv_header "$metadata_tsv"
  append_kv "$metadata_tsv" run_id "$run_id"
  append_kv "$metadata_tsv" run_started_at "$run_stamp"
  append_kv "$metadata_tsv" git_commit "$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || true)"
  append_kv "$metadata_tsv" git_dirty_lines "$(git -C "$repo_root" status --short 2>/dev/null | wc -l | tr -d ' ')"
  append_kv "$metadata_tsv" container "$container"
  append_kv "$metadata_tsv" container_image "$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true)"
  append_kv "$metadata_tsv" cpu_gpu_policy "linked_inproc resident worker; model device policy is exported from otlet.runtime_status"
  append_kv "$metadata_tsv" model_set_policy "default runs use include_by_default=true rows only; candidate, diagnostic, historical, heavy, and blocked rows are explicit manual runs"
  append_kv "$metadata_tsv" reproduction_command "OTLET_BENCH_LIMIT_MODELS=${limit_models:-default} OTLET_BENCH_RUNS=$bench_runs OTLET_BENCH_MAX_ARTIFACT_GB=$max_artifact_gb OTLET_BENCH_TIMEOUT_SECONDS=$timeout_seconds ./benchmarks/run.sh"
  append_kv "$metadata_tsv" timeout_seconds "$timeout_seconds"
  append_kv "$metadata_tsv" min_direct_schema_rate "$min_direct_schema_rate"
  append_kv "$metadata_tsv" keep_models "$keep_models"
  append_kv "$metadata_tsv" keep_sql_state "$keep_sql_state"
  append_kv "$metadata_tsv" scratch_dir "$scratch_dir"
}

selected() {
  local model_key="$1"
  local include_by_default="$2"
  if [[ -n "$limit_models" ]]; then
    [[ ",$limit_models," == *",$model_key,"* ]]
  else
    [[ "$include_by_default" = "true" ]]
  fi
}

main() {
  if ! docker inspect "$container" >/dev/null 2>&1; then
    printf 'benchmark_blocker=container %s not found\n' "$container" >&2
    exit 1
  fi
  if ! docker exec "$container" pg_isready -U "$db_user" -d "$db" >/dev/null 2>&1; then
    printf 'benchmark_blocker=postgres is not ready in %s\n' "$container" >&2
    exit 1
  fi

  ensure_runtime
  ensure_result_tables
  write_metadata

  printf 'model_key\tbase_model_key\thf_repo\tfilename\tquant\tfamily\ttier\tlicense_note\tsource_url\tinclude_by_default\tmax_artifact_gb\trequires_split_files\tdeclared_params_b\tactive_params_b\tcontext_tokens\tartifact_path\tartifact_bytes\texternal_artifact\trun_status\tnotes\n' > "$selected_models_tsv"
  if [[ -f "$models_metadata_file" ]]; then
    cp "$models_metadata_file" "$selected_models_metadata_tsv"
  fi
  printf 'run_id=%s\n' "$run_id"
  printf 'run_dir=%s\n' "$run_dir"

  local any_selected=0
  local model_key hf_repo filename quant family tier license_note source_url include_by_default max_gb requires_split declared_params_b active_params_b context_tokens notes line
  exec 3< "$models_file"
  while IFS= read -r -u 3 line; do
    line="${line//$'\t'/$'\034'}"
    IFS=$'\034' read -r model_key hf_repo filename quant family tier license_note source_url include_by_default max_gb requires_split declared_params_b active_params_b context_tokens notes <<< "$line"
    if [[ "$model_key" = "model_key" || -z "$model_key" ]]; then
      continue
    fi
    if ! selected "$model_key" "$include_by_default"; then
      continue
    fi
    any_selected=1
    local i
    for i in $(seq 1 "$bench_runs"); do
      run_one_model "$model_key" "$hf_repo" "$filename" "$quant" "$family" "$tier" "$license_note" "$source_url" "$include_by_default" "$max_gb" "$requires_split" "$declared_params_b" "$active_params_b" "$context_tokens" "$notes" "$i"
      export_run_artifacts
    done
  done
  exec 3<&-

  if [[ "$any_selected" = "0" ]]; then
    printf 'benchmark_blocker=no models selected from %s\n' "$models_file" >&2
    exit 1
  fi

  export_run_artifacts

  printf 'psql_smoke_result_tables=%s\n' "$(psql_value -v run_id="$run_id" <<'SQL'
SELECT count(*) FROM otlet_bench_source.model_summary WHERE run_id = :'run_id';
SQL
)"
  printf 'psql_smoke_runtime_status=%s\n' "$(psql_value -c "SELECT count(*) FROM otlet.runtime_status;")"
  printf 'psql_smoke_production_status=%s\n' "$(psql_value -c "SELECT count(*) FROM otlet.production_status;")"
  printf 'psql_smoke_receipt_trace_status=%s\n' "$(psql_value -v run_id="$run_id" <<'SQL'
SELECT count(*) FROM otlet.inference_receipt_trace_status WHERE task_name LIKE :'run_id' || '\_%' ESCAPE '\';
SQL
)"
  printf 'psql_smoke_semantic_materializations=%s\n' "$(psql_value -v run_id="$run_id" <<'SQL'
SELECT count(*) FROM otlet.semantic_materializations WHERE task_name LIKE :'run_id' || '\_%' ESCAPE '\';
SQL
)"
  printf 'psql_smoke_action_status=%s\n' "$(psql_value -v run_id="$run_id" <<'SQL'
SELECT count(*) FROM otlet.action_status WHERE task_name LIKE :'run_id' || '\_%' ESCAPE '\';
SQL
)"
  printf 'psql_smoke_model_selection_views=%s\n' "$(psql_value -c "SELECT (SELECT count(*) FROM otlet.model_selection_attempts), (SELECT count(*) FROM otlet.model_selection_status);")"

  perform_cleanup

  local report_path
  report_path="$(python3 "$script_dir/report.py" "$run_dir")"
  publish_report_artifacts
  printf 'benchmark_report=%s\n' "$report_path"
  printf 'benchmark_pareto_chart=%s\n' "$run_dir/pareto.svg"
  printf 'benchmark_latency_chart=%s\n' "$run_dir/latency.svg"
  printf 'benchmark_efficiency_chart=%s\n' "$run_dir/efficiency.svg"
  printf 'benchmark_case_results=%s\n' "$case_results_tsv"
  printf 'benchmark_model_summary=%s\n' "$model_summary_tsv"
  printf 'benchmark_explain=%s\n' "$explain_txt"
  if [[ "$publish_report" = "1" ]]; then
    printf 'benchmark_published_report_dir=%s\n' "$publish_dir"
  fi
  printf 'benchmark_cleanup_models_removed=%s\n' "$([[ "$keep_models" = "1" ]] && printf false || printf true)"
  printf 'benchmark_cleanup_sql_state_removed=%s\n' "$([[ "$keep_sql_state" = "1" ]] && printf false || printf true)"
  if [[ "$keep_models" != "1" ]]; then
    if docker exec "$container" sh -lc "test ! -d $(sh_quote "$scratch_dir")"; then
      printf 'benchmark_scratch_dir_gone=true\n'
    else
      printf 'benchmark_scratch_dir_gone=false\n'
    fi
  fi
}

main "$@"
