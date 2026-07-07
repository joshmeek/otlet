run_explain_smoke() {
  local join_index="$1"
  local row_index="$2"
  local join_explain_file="$run_dir/${join_index}_current_rows_explain.txt"
  local custom_explain_file="$run_dir/${join_index}_customscan_explain.txt"
  psql_exec -v join_index="$join_index" > "$join_explain_file" <<'SQL'
EXPLAIN SELECT subject_id, body, stale
FROM otlet.semantic_join_index_current_rows(:'join_index', true)
WHERE subject_id = 'bench-1001:bench-42';
SQL
  psql_exec -v row_index="$row_index" > "$custom_explain_file" <<'SQL'
EXPLAIN SELECT v.id
FROM otlet_bench_source.vendor_entity v
WHERE otlet.semantic_matches_auto(:'row_index', v.id::text, '{"status":"needs_review"}'::jsonb);
SQL
  {
    printf '\n-- %s current-row SQL EXPLAIN --\n' "$join_index"
    cat "$join_explain_file"
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
