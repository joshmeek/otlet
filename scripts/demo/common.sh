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
  docker exec -i "$container" psql -U postgres -d "$database" -v ON_ERROR_STOP=1 "$@"
}

psql_value() {
  psql_exec -qAt "$@"
}

psql_candidate_exec() {
  docker exec -e PGOPTIONS='-c statement_timeout=2000ms' -i "$container" \
    psql -U postgres -d "$database" -v ON_ERROR_STOP=1 "$@"
}

psql_candidate_value() {
  psql_candidate_exec -qAt "$@"
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
    IFS='|' read -r active complete failed <<<"$(psql_value -v task_name="$task" <<'SQL'
SELECT COALESCE(bool_or(status IN ('queued','running','cancel_requested')), false)::text || '|' ||
       count(*) FILTER (WHERE status = 'complete')::text || '|' ||
       count(*) FILTER (WHERE status IN ('failed','canceled'))::text
FROM otlet.jobs
WHERE task_name = :'task_name';
SQL
)"
    if [ "$active" = "t" ]; then
      sleep "$delay"
      continue
    fi
    if [ "$failed" != "0" ]; then
      psql_exec -P border=2 -P null='' -v task_name="$task" <<'SQL'
SELECT job_id, task_name, subject_id, status, error, raw_output
FROM otlet.runs
WHERE task_name = :'task_name'
ORDER BY job_id;
SQL
      return 1
    fi
    if [ "$complete" -ge "$expected_complete" ]; then
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
    IFS='|' read -r active complete failed <<<"$(psql_value -v task_name="$task" <<'SQL'
SELECT COALESCE(bool_or(status IN ('queued','running','cancel_requested')), false)::text || '|' ||
       count(*) FILTER (WHERE status = 'complete')::text || '|' ||
       count(*) FILTER (WHERE status IN ('failed','canceled'))::text
FROM otlet.jobs
WHERE task_name = :'task_name';
SQL
)"
    if [ "$active" = "t" ]; then
      sleep "$delay"
      continue
    fi
    if [ "$failed" -ge "$expected_failed" ]; then
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
