#!/usr/bin/env bash
set -euo pipefail

image="${OTLET_PG_IMAGE:-otlet-postgres-dev:18.4-trixie}"
container="${OTLET_PG_CONTAINER:-otlet-postgres}"
volume="${OTLET_PG_VOLUME:-otlet-postgres-data}"
port="${OTLET_PG_PORT:-55432}"
password="${POSTGRES_PASSWORD:-postgres}"
database="${OTLET_DATABASE-postgres}"
pgrx_features="${OTLET_PGRX_FEATURES:-pg18,native,openmp}"
worker_count="${OTLET_WORKER_COUNT:-1}"
max_worker_rss_bytes="${OTLET_MAX_WORKER_RSS_BYTES:-8589934592}"
llama_threads="${OTLET_LLAMA_THREADS:-}"
llama_batch_threads="${OTLET_LLAMA_BATCH_THREADS:-}"
llama_batch_tokens="${OTLET_LLAMA_BATCH_TOKENS:-}"
llama_ubatch_tokens="${OTLET_LLAMA_UBATCH_TOKENS:-}"
llama_mmap="${OTLET_LLAMA_MMAP:-}"
llama_mlock="${OTLET_LLAMA_MLOCK:-}"
llama_flash_attn="${OTLET_LLAMA_FLASH_ATTN:-}"
llama_no_perf="${OTLET_LLAMA_NO_PERF:-}"
llama_kv_type="${OTLET_LLAMA_KV_TYPE:-}"
llama_kv_type_k="${OTLET_LLAMA_KV_TYPE_K:-}"
llama_kv_type_v="${OTLET_LLAMA_KV_TYPE_V:-}"
omp_proc_bind="${OMP_PROC_BIND:-}"
omp_places="${OMP_PLACES:-}"
gomp_cpu_affinity="${GOMP_CPU_AFFINITY:-}"
model_dir="${OTLET_MODEL_DIR:-/var/lib/postgresql/otlet-models}"
cheap_model_file="${OTLET_CHEAP_MODEL_FILE:-Qwen3-1.7B-Q8_0.gguf}"
cheap_model_url="${OTLET_CHEAP_MODEL_URL:-https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf}"
cheap_model_repo_cache="${OTLET_CHEAP_MODEL_REPO_CACHE:-models--Qwen--Qwen3-1.7B-GGUF}"
strong_model_file="${OTLET_STRONG_MODEL_FILE:-Qwen3.5-4B-Q4_K_M.gguf}"
strong_model_url="${OTLET_STRONG_MODEL_URL:-https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf}"
strong_model_repo_cache="${OTLET_STRONG_MODEL_REPO_CACHE:-models--unsloth--Qwen3.5-4B-GGUF}"

if ! [[ "$worker_count" =~ ^[0-9]+$ ]] || [ "$worker_count" -lt 1 ]; then
  worker_count=1
elif [ "$worker_count" -gt 4 ]; then
  worker_count=4
fi

if [ -z "$database" ] || [ "$(printf '%s' "$database" | wc -c | tr -d ' ')" -gt 63 ] ||
  ! [[ "$database" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
  echo "OTLET_DATABASE must be at most 63 bytes and contain only ASCII letters, digits, underscore, dot, and hyphen" >&2
  exit 1
fi

if ! [[ "$max_worker_rss_bytes" =~ ^[0-9]+$ ]]; then
  echo "OTLET_MAX_WORKER_RSS_BYTES must be between 0 and 70368744177664" >&2
  exit 1
fi
max_worker_rss_bytes="$(printf '%s' "$max_worker_rss_bytes" | sed 's/^0*//')"
max_worker_rss_bytes="${max_worker_rss_bytes:-0}"
if [ "${#max_worker_rss_bytes}" -gt 14 ] ||
  { [ "${#max_worker_rss_bytes}" -eq 14 ] && [[ "$max_worker_rss_bytes" > 70368744177664 ]]; }; then
  echo "OTLET_MAX_WORKER_RSS_BYTES must be between 0 and 70368744177664" >&2
  exit 1
fi

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

wait_ready_for() {
  local target_container="$1"

  for _ in {1..60}; do
    docker exec "$target_container" pg_isready -U postgres >/dev/null 2>&1 && return
    if [ "$(docker inspect -f '{{.State.Running}}' "$target_container" 2>/dev/null || echo false)" != "true" ]; then
      docker logs --tail 80 "$target_container" >&2 || true
      return 1
    fi
    sleep 1
  done

  docker logs --tail 80 "$target_container" >&2 || true
  return 1
}

wait_ready() {
  wait_ready_for "$container"
}

wait_worker() {
  local active_workers

  for _ in {1..60}; do
    active_workers="$(
      docker exec "$container" psql -U postgres -d "$database" -qAt \
        -c "select count(*) from pg_stat_activity where backend_type = 'otlet worker' and datname = current_database();"
    )"
    if [ "$active_workers" = "$worker_count" ]; then
      return
    fi
    sleep 1
  done

  docker exec "$container" psql -U postgres -d "$database" -P border=2 -P null='' \
    -c "select pid, backend_type, state from pg_stat_activity order by pid;" >&2
  docker logs --tail 80 "$container" >&2
  exit 1
}

psql_exec() {
  docker exec -i "$container" psql -U postgres -d "$database" -v ON_ERROR_STOP=1 "$@"
}

psql_admin() {
  docker exec -i "$container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

append_optional_env() {
  local name="$1"
  local value="$2"

  if [ -n "$value" ]; then
    container_env_args+=(-e "$name=$value")
  fi
}

volume_has_database() {
  docker volume inspect "$volume" >/dev/null 2>&1 || return 1
  docker run --rm \
    --entrypoint sh \
    -v "$volume:/var/lib/postgresql:ro" \
    "$image" \
    -c 'find /var/lib/postgresql -type f -name PG_VERSION -print -quit | grep -q .'
}

volume_otlet_database() {
  docker volume inspect "$volume" >/dev/null 2>&1 || return 1
  docker run --rm \
    --entrypoint sh \
    -v "$volume:/var/lib/postgresql:ro" \
    "$image" \
    -c 'test -r /var/lib/postgresql/.otlet-database && cat /var/lib/postgresql/.otlet-database'
}

reset_persisted_preload() {
  local recovery_container="${container}-preload-reset"

  if docker container inspect "$recovery_container" >/dev/null 2>&1; then
    log "Removing stale preload recovery container $recovery_container"
    docker rm -f "$recovery_container" >/dev/null
  fi

  log "Resetting persisted Postgres preload state"
  docker run -d \
    --name "$recovery_container" \
    -e POSTGRES_PASSWORD="$password" \
    -v "$volume:/var/lib/postgresql" \
    "$image" \
    postgres -c "shared_preload_libraries=" >/dev/null

  if ! wait_ready_for "$recovery_container"; then
    docker rm -f "$recovery_container" >/dev/null
    return 1
  fi

  if ! docker exec "$recovery_container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "ALTER SYSTEM RESET shared_preload_libraries;" >/dev/null; then
    docker logs --tail 80 "$recovery_container" >&2 || true
    docker rm -f "$recovery_container" >/dev/null
    return 1
  fi

  docker rm -f "$recovery_container" >/dev/null
}

prepare_volume_for_new_container() {
  if volume_has_database; then
    reset_persisted_preload
  fi
}

create_container() {
  docker run -d \
    --name "$container" \
    --label "otlet.setup.config=$container_config_signature" \
    "${container_env_args[@]}" \
    -p "127.0.0.1:$port:5432" \
    -v "$volume:/var/lib/postgresql" \
    -v "$PWD:/work:ro" \
    -v otlet-cargo-target:/target \
    -w /work \
    "$image" >/dev/null
}

ensure_model() {
  local repo_cache="$1"
  local model_file="$2"
  local model_url="$3"
  local cached

  cached="$(
    docker exec "$container" sh -c '
      find -L "$1" "$2" -type f -name "$3" -print 2>/dev/null |
        while IFS= read -r path; do
          if [ "$(head -c 4 "$path" 2>/dev/null)" = GGUF ]; then
            printf "%s\n" "$path"
            break
          fi
        done
    ' sh "/var/lib/postgresql/.cache/huggingface/hub/$repo_cache/snapshots" "$model_dir" "$model_file"
  )"
  if [ -n "$cached" ]; then
    printf '%s\n' "$cached"
    return
  fi

  if ! docker exec "$container" sh -c '
    set -eu
    destination="$1/$2"
    temporary="$destination.part"
    mkdir -p "$1"
    rm -f "$temporary"
    trap '\''rm -f "$temporary"'\'' EXIT
    curl -fL --retry 3 --connect-timeout 20 "$3" -o "$temporary"
    [ "$(head -c 4 "$temporary" 2>/dev/null)" = GGUF ] || {
      echo "Downloaded model is not a GGUF artifact: $3" >&2
      exit 1
    }
    mv "$temporary" "$destination"
  ' sh "$model_dir" "$model_file" "$model_url"; then
    return 1
  fi
  printf '%s/%s\n' "$model_dir" "$model_file"
}

container_env_args=(
  -e "POSTGRES_PASSWORD=$password"
  -e CARGO_TARGET_DIR=/target
  -e "OTLET_DATABASE=$database"
  -e "OTLET_WORKER_COUNT=$worker_count"
)
append_optional_env OTLET_LLAMA_THREADS "$llama_threads"
append_optional_env OTLET_LLAMA_BATCH_THREADS "$llama_batch_threads"
append_optional_env OTLET_LLAMA_BATCH_TOKENS "$llama_batch_tokens"
append_optional_env OTLET_LLAMA_UBATCH_TOKENS "$llama_ubatch_tokens"
append_optional_env OTLET_LLAMA_MMAP "$llama_mmap"
append_optional_env OTLET_LLAMA_MLOCK "$llama_mlock"
append_optional_env OTLET_LLAMA_FLASH_ATTN "$llama_flash_attn"
append_optional_env OTLET_LLAMA_NO_PERF "$llama_no_perf"
append_optional_env OTLET_LLAMA_KV_TYPE "$llama_kv_type"
append_optional_env OTLET_LLAMA_KV_TYPE_K "$llama_kv_type_k"
append_optional_env OTLET_LLAMA_KV_TYPE_V "$llama_kv_type_v"
append_optional_env OMP_PROC_BIND "$omp_proc_bind"
append_optional_env OMP_PLACES "$omp_places"
append_optional_env GOMP_CPU_AFFINITY "$gomp_cpu_affinity"
container_config_signature="$(printf '%s\0' "${container_env_args[@]}" | cksum | awk '{print $1 "-" $2}')"

log "Building Postgres image $image"
docker build --provenance=false -t "$image" -f docker/postgres/Dockerfile .
image_id="$(docker image inspect -f '{{.Id}}' "$image")"

container_exists=false
if docker container inspect "$container" >/dev/null 2>&1; then
  container_exists=true
fi

recorded_database=""
if volume_has_database; then
  recorded_database="$(volume_otlet_database || true)"
  if [ -z "$recorded_database" ] && [ "$container_exists" = true ]; then
    recorded_database="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" |
      sed -n 's/^OTLET_DATABASE=//p' | tail -n 1)"
  fi
  recorded_database="${recorded_database:-postgres}"
  if [ -n "$recorded_database" ] && [ "$recorded_database" != "$database" ]; then
    echo "PostgreSQL volume $volume is configured for Otlet database $recorded_database" >&2
    echo "Use a separate volume instead of changing OTLET_DATABASE to $database" >&2
    exit 1
  fi
fi

if [ "$container_exists" = true ]; then
  container_image_id="$(docker inspect -f '{{.Image}}' "$container")"
  container_config_signature_actual="$(docker inspect -f '{{index .Config.Labels "otlet.setup.config"}}' "$container")"
  if [ "$container_image_id" != "$image_id" ] || [ "$container_config_signature_actual" != "$container_config_signature" ]; then
    log "Replacing stale container image or llama.cpp setting"
    docker rm -f "$container" >/dev/null
    container_exists=false
  fi
fi

if [ "$container_exists" = false ]; then
  log "Creating container $container"
  prepare_volume_for_new_container
  create_container
  wait_ready
else
  log "Starting container $container"
  if ! docker start "$container" >/dev/null || ! wait_ready; then
    log "Recreating container after failed startup"
    docker rm -f "$container" >/dev/null
    prepare_volume_for_new_container
    create_container
    wait_ready
  fi
fi

other_otlet_databases=()
existing_databases="$(psql_admin -qAt -v database="$database" <<'SQL'
SELECT datname
FROM pg_database
WHERE datallowconn
  AND NOT datistemplate
  AND datname <> :'database'
ORDER BY datname;
SQL
)"
while IFS= read -r existing_database; do
  [ -n "$existing_database" ] || continue
  if ! has_otlet="$(docker exec "$container" psql -U postgres -d "$existing_database" -qAt -v ON_ERROR_STOP=1 \
    -c "select exists (select 1 from pg_extension where extname = 'otlet');")"; then
    echo "Cannot inspect database $existing_database for an existing Otlet installation" >&2
    exit 1
  fi
  if [ "$has_otlet" = "t" ]; then
    other_otlet_databases+=("$existing_database")
  fi
done <<<"$existing_databases"

if [ "${#other_otlet_databases[@]}" -gt 0 ]; then
  echo "Otlet is already installed in another database: ${other_otlet_databases[*]}" >&2
  echo "Use a separate PostgreSQL volume or remove the other installation before targeting $database" >&2
  exit 1
fi

psql_admin -v database="$database" >/dev/null <<'SQL'
SELECT format('CREATE DATABASE %I', :'database')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'database')
\gexec
SELECT format('ALTER DATABASE %I REFRESH COLLATION VERSION', :'database')
\gexec
SQL

log "Installing Otlet extension with features: $pgrx_features"
if docker exec "$container" sh -lc 'test -d /target/llama-cmake-cache && grep -q "GGML_OPENMP:BOOL=OFF" /target/llama-cmake-cache/*/build/CMakeCache.txt 2>/dev/null'; then
  log "Clearing stale llama.cpp build so OpenMP/native flags take effect"
  docker exec "$container" rm -rf /target/llama-cmake-cache
fi
psql_exec -c "ALTER SYSTEM RESET shared_preload_libraries;" >/dev/null
docker restart "$container" >/dev/null
wait_ready

docker exec "$container" cargo pgrx install \
  -p otlet_pg \
  --pg-config /usr/bin/pg_config \
  --release \
  --no-default-features \
  --features "$pgrx_features"

psql_exec \
  -c "DROP EXTENSION IF EXISTS otlet CASCADE;" \
  -c "CREATE EXTENSION otlet;" \
  -Atc "select count(*) from pg_tables where schemaname = 'otlet';"

psql_exec -v max_worker_rss_bytes="$max_worker_rss_bytes" >/dev/null <<'SQL'
UPDATE otlet.production_policy
SET default_runtime_options = jsonb_set(
  default_runtime_options,
  '{max_worker_rss_bytes}',
  to_jsonb(:'max_worker_rss_bytes'::bigint)
)
WHERE name = 'default';
SQL

cheap_model_artifact="$(ensure_model "$cheap_model_repo_cache" "$cheap_model_file" "$cheap_model_url")"
strong_model_artifact="$(ensure_model "$strong_model_repo_cache" "$strong_model_file" "$strong_model_url")"

docker exec -u postgres "$container" sh -c '
  set -eu
  extension_library="$(pg_config --pkglibdir)/otlet.so"
  extension_control="$(pg_config --sharedir)/extension/otlet.control"
  test -r "$extension_library" || {
    echo "Postgres cannot read extension library $extension_library" >&2
    exit 1
  }
  test -r "$extension_control" || {
    echo "Postgres cannot read extension control file $extension_control" >&2
    exit 1
  }
  test -d "$1" && test -x "$1" || {
    echo "Postgres cannot access model directory $1" >&2
    exit 1
  }
  for artifact in "$2" "$3"; do
    test -r "$artifact" || {
      echo "Postgres cannot read model artifact $artifact" >&2
      exit 1
    }
    test "$(head -c 4 "$artifact")" = GGUF || {
      echo "Model artifact does not have a GGUF header: $artifact" >&2
      exit 1
    }
  done
' sh "$model_dir" "$cheap_model_artifact" "$strong_model_artifact"

native_startup_preflight="$(psql_exec -qAt -v max_worker_rss_bytes="$max_worker_rss_bytes" <<'SQL'
SELECT current_database() || '|' || current_user || '|' ||
       has_database_privilege(current_user, current_database(), 'CONNECT')::text || '|' ||
       has_schema_privilege(current_user, 'otlet', 'USAGE')::text || '|' ||
       COALESCE(default_runtime_options ->> 'max_worker_rss_bytes', '')
FROM otlet.production_policy
WHERE name = 'default';
SQL
)"
expected_native_startup_preflight="$database|postgres|true|true|$max_worker_rss_bytes"
if [ "$native_startup_preflight" != "$expected_native_startup_preflight" ]; then
  echo "Native startup preflight failed: $native_startup_preflight" >&2
  exit 1
fi
log "Native startup preflight passed for database $database"

docker exec "$container" sh -c '
  set -eu
  marker=/var/lib/postgresql/.otlet-database
  temporary="$marker.tmp"
  umask 022
  printf "%s\n" "$1" >"$temporary"
  mv "$temporary" "$marker"
' sh "$database"

psql_exec -c "ALTER SYSTEM SET shared_preload_libraries = 'otlet';"

docker restart "$container" >/dev/null
wait_ready
wait_worker

worker_startup_contract=""
for _ in {1..60}; do
  worker_startup_contract="$(psql_exec -qAt <<'SQL'
SELECT (detail ->> 'database') || '|' || (detail ->> 'role') || '|' ||
       COALESCE(detail ->> 'default_max_worker_rss_bytes', '')
FROM otlet.worker_events
WHERE event_type = 'worker_started'
ORDER BY id DESC
LIMIT 1;
SQL
)"
  [ "$worker_startup_contract" = "$database|postgres|$max_worker_rss_bytes" ] && break
  sleep 1
done
if [ "$worker_startup_contract" != "$database|postgres|$max_worker_rss_bytes" ]; then
  echo "Worker startup status failed: $worker_startup_contract" >&2
  exit 1
fi

printf 'postgres_url=postgres://postgres:%s@127.0.0.1:%s/%s\n' "$password" "$port" "$database"
printf 'database=%s\n' "$database"
printf 'worker_count=%s\n' "$worker_count"
printf 'max_worker_rss_bytes=%s\n' "$max_worker_rss_bytes"
printf 'cheap_model_artifact=%s\n' "$cheap_model_artifact"
printf 'strong_model_artifact=%s\n' "$strong_model_artifact"
printf 'cheap_model_sha256=%s\n' "$(docker exec "$container" sha256sum "$cheap_model_artifact" | awk '{print $1}')"
printf 'strong_model_sha256=%s\n' "$(docker exec "$container" sha256sum "$strong_model_artifact" | awk '{print $1}')"
printf 'cheap_model_bytes=%s\n' "$(docker exec "$container" stat -Lc %s "$cheap_model_artifact")"
printf 'strong_model_bytes=%s\n' "$(docker exec "$container" stat -Lc %s "$strong_model_artifact")"
