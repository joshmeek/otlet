#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

models="${OTLET_SWEEP_MODELS:-qwen3_1_7b,qwen35_4b}"
threads_csv="${OTLET_SWEEP_THREADS:-1,2,4,6,8,12}"
download="${OTLET_SWEEP_DOWNLOAD:-0}"

first=true
IFS=',' read -ra thread_values <<< "$threads_csv"
for threads in "${thread_values[@]}"; do
  output="$(
    OTLET_PROBE_LIMIT_MODELS="$models" \
      OTLET_PROBE_LLAMA_THREADS="$threads" \
      OTLET_PROBE_DOWNLOAD="$download" \
      "$script_dir/quick_probe.sh"
  )"
  if [[ "$first" == "true" ]]; then
    printf 'threads\t%s\n' "$(head -n 1 <<< "$output")"
    first=false
  fi
  tail -n +2 <<< "$output" | awk -v threads="$threads" 'NF {print threads "\t" $0}'
done
