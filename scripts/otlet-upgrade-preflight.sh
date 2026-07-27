#!/usr/bin/env bash
set -euo pipefail

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
database="${OTLET_DATABASE:-postgres}"
target_version="${1:-}"

command -v docker >/dev/null || {
  echo "Missing upgrade preflight command: docker" >&2
  exit 1
}
if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]; then
  echo "Container $container is not running" >&2
  exit 1
fi

version_state="$(docker exec -i "$container" psql -U postgres -d "$database" -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT e.extversion || '|' || a.default_version
FROM pg_extension e
JOIN pg_available_extensions a ON a.name = e.extname
WHERE e.extname = 'otlet';
SQL
)"
[ -n "$version_state" ] || {
  echo "Otlet is not installed in database $database" >&2
  exit 1
}
IFS='|' read -r current_version default_version <<<"$version_state"
target_version="${target_version:-$default_version}"

readiness="$(docker exec -i "$container" psql -U postgres -d "$database" -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT count(*) FILTER (WHERE status IN ('queued', 'running', 'cancel_requested')) || '|' ||
       (SELECT count(*) FROM otlet.verify_invariants()) || '|' ||
       (current_setting('shared_preload_libraries') ~ '(^|,[[:space:]]*)otlet([[:space:]]*,|$)')::text
FROM otlet.jobs;
SQL
)"
IFS='|' read -r active_jobs invariant_violations preload_ready <<<"$readiness"
if [ "$active_jobs" != "0" ] || [ "$invariant_violations" != "0" ] || [ "$preload_ready" != "true" ]; then
  echo "Upgrade preflight blocked: active_jobs=$active_jobs invariant_violations=$invariant_violations preload_ready=$preload_ready" >&2
  exit 1
fi

docker exec -u postgres "$container" sh -c '
  test -r "$(pg_config --pkglibdir)/otlet.so" &&
    test -r "$(pg_config --sharedir)/extension/otlet.control"
' || {
  echo "Upgrade preflight could not read the installed Otlet binary or control file" >&2
  exit 1
}

action=noop
if [ "$target_version" != "$current_version" ]; then
  upgrade_path="$(docker exec -i "$container" psql -U postgres -d "$database" -qAt -v ON_ERROR_STOP=1 -v target_version="$target_version" -v current_version="$current_version" <<'SQL'
SELECT path
FROM pg_extension_update_paths('otlet')
WHERE source = :'current_version'
  AND target = :'target_version'
  AND path IS NOT NULL;
SQL
)"
  [ -n "$upgrade_path" ] || {
    echo "No Otlet upgrade path from $current_version to $target_version" >&2
    exit 1
  }
  action=update
fi

echo "upgrade_preflight=ready|$current_version|$target_version|$action|$active_jobs|$invariant_violations"
