#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
db="${OTLET_PG_DATABASE:-postgres}"
db_user="${OTLET_PG_USER:-postgres}"
models_file="${OTLET_BENCH_MODELS:-$script_dir/models.tsv}"
models_metadata_file="${OTLET_BENCH_MODELS_METADATA:-$script_dir/report/latest/models_metadata.tsv}"
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
selected_models_tsv="$run_dir/models.tsv"
selected_models_metadata_tsv="$run_dir/models_metadata.tsv"
case_results_tsv="$run_dir/case_results.tsv"
model_summary_tsv="$run_dir/model_summary.tsv"
explain_txt="$run_dir/explain.txt"
cleanup_done=0
sensitive_mode_enabled=0
artifact_bytes_removed_early=0

mkdir -p "$run_dir"
: > "$downloaded_paths"
: > "$created_models"
: > "$explain_txt"


source "$script_dir/lib.sh"
source "$script_dir/sql_state.sh"
source "$script_dir/model_artifacts.sh"
source "$script_dir/report_publish.sh"

trap perform_cleanup EXIT

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
  local numeric_task="${17}"
  local extraction_task="${18}"
  local policy_task="${19}"
  local join_task="${20}"
  local row_task="${21}"
  local join_index="${22}"
  local wall_ms="${23}"
  local source_unchanged="${24}"
  local stale_leak_count="${25}"
  local worker_crash_count="${26}"

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
    -v numeric_task="$numeric_task" \
    -v extraction_task="$extraction_task" \
    -v policy_task="$policy_task" \
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
  local numeric_task="${run_id}_${run_model_key}_numeric"
  local extraction_task="${run_id}_${run_model_key}_extract"
  local policy_task="${run_id}_${run_model_key}_policy"
  local join_index="${run_id}_${run_model_key}_join"
  local join_task="${join_index}_task"
  local row_index="${run_id}_${run_model_key}_row"
  local row_task="${row_index}_task"
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

  score_current_model_run() {
    score_model_run \
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
      "$numeric_task" \
      "$extraction_task" \
      "$policy_task" \
      "$join_task" \
      "$row_task" \
      "$join_index" \
      "$wall_ms" \
      "$source_unchanged" \
      "$stale_leak_count" \
      "$worker_crash_count"
  }

  run_and_wait() {
    local task="$1"
    local label="$2"
    if ! psql_exec -v task_name="$task" >/dev/null <<'SQL'
SELECT otlet.run_task(:'task_name');
SQL
    then
      fail_current_model "$label enqueue failed"
      return 1
    fi
    if ! wait_for_task "$task"; then
      fail_current_model "$label timed out"
      return 1
    fi
  }

  refresh_and_wait() {
    local kind="$1"
    local index_name="$2"
    local task="$3"
    local label="$4"
    if [[ "$kind" = "join" ]]; then
      if ! psql_exec -v index_name="$index_name" >/dev/null <<'SQL'
SELECT otlet.refresh_semantic_join_index(:'index_name');
SQL
      then
        fail_current_model "$label enqueue failed"
        return 1
      fi
    else
      if ! psql_exec -v index_name="$index_name" >/dev/null <<'SQL'
SELECT otlet.refresh_semantic_index(:'index_name');
SQL
      then
        fail_current_model "$label enqueue failed"
        return 1
      fi
    fi
    if ! wait_for_task "$task"; then
      fail_current_model "$label timed out"
      return 1
    fi
  }

  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  started_s="$(date +%s)"

  if ! psql_file "$script_dir/fixtures.sql" \
    -v model_name="$model_name" \
    -v direct_task="$direct_task" \
    -v triage_task="$triage_task" \
    -v numeric_task="$numeric_task" \
    -v extraction_task="$extraction_task" \
    -v policy_task="$policy_task" \
    -v join_index="$join_index" \
    -v row_index="$row_index" >/dev/null; then
    fail_current_model "fixture setup failed"
    return
  fi

  if ! before_hash="$(source_hash)"; then
    fail_current_model "source hash before direct task failed"
    return
  fi

  if ! run_and_wait "$direct_task" "direct task"; then
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
    printf 'model=%s skip_diagnostics=true direct_schema_valid_rate=%s min_direct_schema_rate=%s\n' "$run_model_key" "$direct_rate" "$min_direct_schema_rate"
    if ! score_current_model_run; then
      fail_current_model "scoring failed after direct task"
      return
    fi
    cleanup_downloaded_model "$model_name" "$base_model_key" "$external_artifact"
    return
  fi

  if ! run_and_wait "$triage_task" "triage task"; then
    return
  fi

  if ! run_and_wait "$numeric_task" "numeric task"; then
    return
  fi

  if ! run_and_wait "$extraction_task" "extraction task"; then
    return
  fi

  if ! run_and_wait "$policy_task" "policy task"; then
    return
  fi

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
    if ! score_current_model_run; then
      fail_current_model "scoring failed after direct task"
      return
    fi
    cleanup_downloaded_model "$model_name" "$base_model_key" "$external_artifact"
    return
  fi

  if ! refresh_and_wait "join" "$join_index" "$join_task" "semantic join refresh"; then
    return
  fi

  if ! refresh_and_wait "row" "$row_index" "$row_task" "semantic row refresh"; then
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

  if ! run_explain_smoke "$join_index" "$row_index"; then
    fail_current_model "EXPLAIN smoke failed"
    return
  fi

  if ! psql_exec >/dev/null <<'SQL'
SELECT otlet.watch_semantic_stale('otlet_bench_source.vendor_entity'::regclass, 'id');
UPDATE otlet_bench_source.vendor_entity
SET notes = notes || ' benchmark stale proof mutation'
WHERE id = 'bench-1001';
UPDATE otlet_bench_source.vendor_entity
SET notes = notes || ' benchmark stale proof right-side mutation'
WHERE id = 'bench-42';
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

  if ! score_current_model_run; then
    fail_current_model "scoring failed"
    return
  fi

  cleanup_downloaded_model "$model_name" "$base_model_key" "$external_artifact"
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

  ensure_extension
  current_sensitive_mode="$(psql_value -c "SELECT sensitive_evidence_mode FROM otlet.production_policy_status;")"
  if [[ "$current_sensitive_mode" != "redacted" ]]; then
    printf 'benchmark_blocker=expected redacted sensitive evidence mode before benchmark, got %s\n' "$current_sensitive_mode" >&2
    exit 1
  fi
  psql_exec -c "UPDATE otlet.production_policy SET sensitive_evidence_mode = 'diagnostic' WHERE name = 'default';" >/dev/null
  sensitive_mode_enabled=1
  if [[ "$(psql_value -c "SELECT sensitive_evidence_mode FROM otlet.production_policy_status;")" != "diagnostic" ]]; then
    printf 'benchmark_blocker=failed to enable diagnostic sensitive evidence mode\n' >&2
    exit 1
  fi
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
  printf 'psql_smoke_audit_exports=%s\n' "$(psql_value <<'SQL'
SELECT (SELECT count(*) FROM otlet.redaction_policy_status) || '|' ||
       (SELECT count(*) FROM otlet.audit_receipt_export) || '|' ||
       (SELECT count(*) FROM otlet.semantic_dependency_audit);
SQL
)"

  append_runtime_metadata

  perform_cleanup

  local report_path
  report_path="$(python3 "$script_dir/report.py" "$run_dir")"
  publish_report_artifacts
  printf 'benchmark_report=%s\n' "$report_path"
  printf 'benchmark_pareto_chart=%s\n' "$run_dir/pareto.svg"
  printf 'benchmark_latency_chart=%s\n' "$run_dir/latency.svg"
  printf 'benchmark_ttft_chart=%s\n' "$run_dir/ttft.svg"
  printf 'benchmark_prompt_decode_chart=%s\n' "$run_dir/prompt_decode.svg"
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
