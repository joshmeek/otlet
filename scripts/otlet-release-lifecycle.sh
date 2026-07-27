#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

image="${OTLET_PG_IMAGE:-otlet-postgres-dev:18.4-trixie}"
database="postgres"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
container="${OTLET_LIFECYCLE_CONTAINER:-otlet-lifecycle-$run_id}"
recovery_container="${container}-recovery"
volume="${OTLET_LIFECYCLE_VOLUME:-otlet-lifecycle-$run_id}"
script_started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

for command in docker grep; do
  command -v "$command" >/dev/null || {
    echo "Missing lifecycle command: $command" >&2
    exit 1
  }
done
docker image inspect "$image" >/dev/null 2>&1 || {
  echo "Image $image is unavailable; run ./scripts/otlet-setup.sh first" >&2
  exit 1
}
for name in "$container" "$recovery_container"; do
  if docker container inspect "$name" >/dev/null 2>&1; then
    echo "Lifecycle container already exists: $name" >&2
    exit 1
  fi
done
if docker volume inspect "$volume" >/dev/null 2>&1; then
  echo "Lifecycle volume already exists: $volume" >&2
  exit 1
fi

cleanup() {
  docker rm -f "$container" "$recovery_container" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_ready() {
  local target="$1"

  for _ in {1..60}; do
    docker exec "$target" pg_isready -U postgres >/dev/null 2>&1 && return
    if [ "$(docker inspect -f '{{.State.Running}}' "$target" 2>/dev/null || true)" != "true" ]; then
      docker logs --tail 80 "$target" >&2 || true
      return 1
    fi
    sleep 1
  done
  docker logs --tail 80 "$target" >&2 || true
  return 1
}

psql_exec() {
  docker exec -i "$container" psql -U postgres -d "$database" -v ON_ERROR_STOP=1 "$@"
}

psql_value() {
  psql_exec -qAt "$@"
}

wait_worker() {
  local excluded_pid="${1:-}"
  local worker_pid

  for _ in {1..60}; do
    worker_pid="$(psql_value -v excluded_pid="$excluded_pid" <<'SQL'
SELECT pid
FROM pg_stat_activity
WHERE backend_type = 'otlet worker'
  AND datname = current_database()
  AND (NULLIF(:'excluded_pid', '') IS NULL OR pid <> NULLIF(:'excluded_pid', '')::integer)
ORDER BY pid
LIMIT 1;
SQL
)"
    if [[ "$worker_pid" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$worker_pid"
      return
    fi
    sleep 1
  done
  docker logs --tail 80 "$container" >&2 || true
  return 1
}

wait_worker_stopped() {
  local active_workers

  for _ in {1..60}; do
    active_workers="$(psql_value -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'otlet worker' AND datname = current_database();")"
    [ "$active_workers" = "0" ] && return
    sleep 1
  done
  return 1
}

assert_database_state() {
  local expected_version="$1"
  local state

  state="$(psql_value <<'SQL'
SELECT e.extversion || '|' || s.value || '|' || count(v.*)
FROM pg_extension e
CROSS JOIN public.otlet_lifecycle_sentinel s
LEFT JOIN LATERAL otlet.verify_invariants() v ON true
WHERE e.extname = 'otlet'
GROUP BY e.extversion, s.value;
SQL
)"
  [ "$state" = "$expected_version|preserved|0" ] || {
    echo "Lifecycle database state mismatch: $state" >&2
    exit 1
  }
}

docker volume create "$volume" >/dev/null
docker run -d \
  --name "$container" \
  -e POSTGRES_PASSWORD=postgres \
  -e CARGO_TARGET_DIR=/target \
  -e OTLET_DATABASE="$database" \
  -e OTLET_WORKER_COUNT=1 \
  -v "$volume:/var/lib/postgresql" \
  -v "$repo_root:/work:ro" \
  -v otlet-cargo-target:/target \
  -w /work \
  "$image" >/dev/null
wait_ready "$container"

docker exec "$container" cargo pgrx install \
  -p otlet_pg \
  --pg-config /usr/bin/pg_config \
  --release \
  --no-default-features \
  --features pg18,native,openmp >/dev/null
psql_exec >/dev/null <<'SQL'
CREATE EXTENSION otlet;
CREATE TABLE public.otlet_lifecycle_sentinel (
  id integer PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO public.otlet_lifecycle_sentinel VALUES (1, 'preserved');
ALTER SYSTEM SET shared_preload_libraries = 'otlet';
SQL
installed_version="$(psql_value -c "SELECT extversion FROM pg_extension WHERE extname = 'otlet';")"

docker restart "$container" >/dev/null
wait_ready "$container"
worker_pid="$(wait_worker)"
assert_database_state "$installed_version"
echo "lifecycle_fresh_install=ok|$installed_version|$worker_pid"

docker exec "$container" kill -TERM "$worker_pid"
wait_worker_stopped
assert_database_state "$installed_version"
echo "lifecycle_worker_clean_stop=ok|$worker_pid"

docker restart "$container" >/dev/null
wait_ready "$container"
database_restart_worker_pid="$(wait_worker)"
assert_database_state "$installed_version"
echo "lifecycle_database_restart=ok|$worker_pid|$database_restart_worker_pid"

OTLET_PG_CONTAINER="$container" OTLET_DATABASE="$database" \
  ./scripts/otlet-upgrade-preflight.sh "$installed_version"

synthetic_version="${installed_version}.lifecycle-failure"
extension_dir="$(docker exec "$container" pg_config --sharedir)/extension"
upgrade_fixture="$extension_dir/otlet--$installed_version--$synthetic_version.sql"
docker exec "$container" sh -c '
  printf "%s\n" "DO \$\$ BEGIN RAISE EXCEPTION '\''otlet lifecycle injected upgrade failure'\''; END \$\$;" >"$1"
' sh "$upgrade_fixture"
OTLET_PG_CONTAINER="$container" OTLET_DATABASE="$database" \
  ./scripts/otlet-upgrade-preflight.sh "$synthetic_version"

set +e
upgrade_output="$(docker exec -i "$container" psql -U postgres -d "$database" -v ON_ERROR_STOP=1 -v target_version="$synthetic_version" 2>&1 <<'SQL'
ALTER EXTENSION otlet UPDATE TO :'target_version';
SQL
)"
upgrade_exit_code=$?
set -e
if [ "$upgrade_exit_code" -eq 0 ] || ! grep -Fq 'otlet lifecycle injected upgrade failure' <<<"$upgrade_output"; then
  echo "Injected extension upgrade did not fail with usable diagnostics" >&2
  printf '%s\n' "$upgrade_output" >&2
  exit 1
fi
assert_database_state "$installed_version"
docker exec "$container" rm -f "$upgrade_fixture"
echo "lifecycle_failed_upgrade_rollback=ok|$installed_version"

startup_failure_started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
psql_exec -c "ALTER SYSTEM SET shared_preload_libraries = 'otlet,otlet_lifecycle_missing';" >/dev/null
docker restart "$container" >/dev/null 2>&1 || true
for _ in {1..30}; do
  [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ] && break
  sleep 1
done
if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = "true" ]; then
  echo "Injected startup failure did not stop Postgres" >&2
  exit 1
fi
startup_failure_logs="$(docker logs --since "$startup_failure_started" "$container" 2>&1)"
if ! grep -Fq 'could not access file' <<<"$startup_failure_logs" ||
  ! grep -Fq 'otlet_lifecycle_missing' <<<"$startup_failure_logs"; then
  echo "Injected startup failure did not provide the expected diagnostic" >&2
  printf '%s\n' "$startup_failure_logs" >&2
  exit 1
fi

docker run -d \
  --name "$recovery_container" \
  -v "$volume:/var/lib/postgresql" \
  "$image" \
  postgres -c shared_preload_libraries= >/dev/null
wait_ready "$recovery_container"
docker exec "$recovery_container" psql -U postgres -d "$database" -v ON_ERROR_STOP=1 \
  -c "ALTER SYSTEM SET shared_preload_libraries = 'otlet';" >/dev/null
docker rm -f "$recovery_container" >/dev/null
docker start "$container" >/dev/null
wait_ready "$container"
recovered_worker_pid="$(wait_worker)"
assert_database_state "$installed_version"
echo "lifecycle_failed_startup_rollback=ok|$recovered_worker_pid"

if docker logs --since "$script_started" "$container" 2>&1 | grep -Eiq 'segmentation|sigsegv|signal 11|core dump|panicked|assertion failed|server process .* was terminated'; then
  docker logs --since "$script_started" "$container" >&2
  exit 1
fi
echo "lifecycle_crash_log_scan=ok"
echo "release_lifecycle_contract=ok|$installed_version|preserved"
