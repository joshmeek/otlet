#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
script_started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
conformance_tmp="$(mktemp -d "${TMPDIR:-/tmp}/otlet-runtime-conformance.XXXXXX")"
cleanup() {
  find "$conformance_tmp" -depth -delete
}
trap cleanup EXIT

for command in docker grep tee; do
  command -v "$command" >/dev/null || {
    echo "Missing runtime conformance command: $command" >&2
    exit 1
  }
done

run_contract() {
  local name="$1"
  shift
  "$@" 2>&1 | tee "$conformance_tmp/$name.log"
}

require_contract() {
  local log_file="$1"
  local contract="$2"
  grep -Fq "$contract" "$log_file" || {
    echo "Runtime conformance output is missing: $contract" >&2
    exit 1
  }
}

run_contract setup ./scripts/otlet-setup.sh
run_contract demo ./scripts/otlet-demo.sh
run_contract portable_worker ./scripts/otlet-portable-worker-demo.sh
run_contract portable_preflight ./scripts/otlet-portable-preflight-demo.sh
run_contract lifecycle ./scripts/otlet-release-lifecycle.sh

demo_log="$conformance_tmp/demo.log"
portable_worker_log="$conformance_tmp/portable_worker.log"
portable_preflight_log="$conformance_tmp/portable_preflight.log"
lifecycle_log="$conformance_tmp/lifecycle.log"

require_contract "$demo_log" "runtime_equivalence_contract=true|true|true|true|true|true|true|true|true|true"
require_contract "$demo_log" "runtime_credential_rotation_contract=true|false|true"
require_contract "$demo_log" "queue_depth_contract=0|0|queue_depth_cap"
require_contract "$demo_log" "portable_duplicate_delivery_contract=complete|true|true"
require_contract "$demo_log" "portable_validation_contract=0|1|passed|passed|otlet_portable_validation_v1"
require_contract "$demo_log" "portable_incompatible_claim_contract=0|3"
require_contract "$demo_log" "row_visible_update_stale_contract=0|true|false|0"
require_contract "$demo_log" "workload_evaluation_contract=true|true|true|true|true|true|true|true|true"
require_contract "$demo_log" "performance_ratio_contract="
require_contract "$demo_log" "invariant_contract=0"
require_contract "$demo_log" "docker_crash_log_scan=ok"
require_contract "$portable_worker_log" "portable_external_worker_contract="
require_contract "$portable_worker_log" "portable_recovery_contract=complete|canceled|complete:2:1:1|complete:2:1:1|complete"
require_contract "$portable_preflight_log" "credentials=credentials_rejected"
require_contract "$portable_preflight_log" "protocol=protocol_incompatible"
require_contract "$lifecycle_log" "lifecycle_database_restart=ok"
require_contract "$lifecycle_log" "lifecycle_failed_upgrade_rollback=ok"
require_contract "$lifecycle_log" "lifecycle_failed_startup_rollback=ok"
require_contract "$lifecycle_log" "lifecycle_crash_log_scan=ok"

if docker logs --since "$script_started" "$container" 2>&1 |
  grep -Eiq 'segmentation|sigsegv|signal 11|core dump|panicked|assertion failed|server process .* was terminated'; then
  docker logs --since "$script_started" "$container" >&2
  exit 1
fi

echo "runtime_failure_matrix_contract=worker_loss,queue_full,stale_claim,duplicate_write,database_restart,credential_rotation,malformed_output,stale_source,protocol_change,upgrade,rollback|passed"
echo "runtime_performance_validation=workload_gates_and_bounded_smoke|passed"
echo "runtime_conformance_crash_log_scan=ok"
echo "runtime_conformance_suite=passed"
