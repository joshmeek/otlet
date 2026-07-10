sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

psql_exec() {
  docker exec -i "$container" psql -U "$db_user" -d "$db" -X -v ON_ERROR_STOP=1 "$@"
}

psql_value() {
  psql_exec -qAt "$@"
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
