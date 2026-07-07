#!/usr/bin/env bash
set -euo pipefail

image="${OTLET_PG_IMAGE:-otlet-postgres-dev:18.4-trixie}"
container="${OTLET_PG_CONTAINER:-otlet-postgres}"
volume="${OTLET_PG_VOLUME:-otlet-postgres-data}"
port="${OTLET_PG_PORT:-55432}"
password="${POSTGRES_PASSWORD:-postgres}"
pgrx_features="${OTLET_PGRX_FEATURES:-pg18,native,openmp}"
model_dir="${OTLET_MODEL_DIR:-/var/lib/postgresql/otlet-models}"
cheap_model_file="${OTLET_CHEAP_MODEL_FILE:-Qwen3-1.7B-Q8_0.gguf}"
cheap_model_url="${OTLET_CHEAP_MODEL_URL:-https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf}"
cheap_model_repo_cache="${OTLET_CHEAP_MODEL_REPO_CACHE:-models--Qwen--Qwen3-1.7B-GGUF}"
strong_model_file="${OTLET_STRONG_MODEL_FILE:-Qwen3.5-4B-Q4_K_M.gguf}"
strong_model_url="${OTLET_STRONG_MODEL_URL:-https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf}"
strong_model_repo_cache="${OTLET_STRONG_MODEL_REPO_CACHE:-models--unsloth--Qwen3.5-4B-GGUF}"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

wait_ready() {
  for _ in {1..60}; do
    docker exec "$container" pg_isready -U postgres >/dev/null 2>&1 && return
    if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false)" != "true" ]; then
      docker logs --tail 80 "$container" >&2 || true
      exit 1
    fi
    sleep 1
  done

  docker logs --tail 80 "$container" >&2 || true
  exit 1
}

wait_worker() {
  local worker_count

  for _ in {1..60}; do
    worker_count="$(
      docker exec "$container" psql -U postgres -d postgres -qAt \
        -c "select count(*) from pg_stat_activity where backend_type = 'otlet worker';"
    )"
    if [ "$worker_count" = "1" ]; then
      return
    fi
    sleep 1
  done

  docker exec "$container" psql -U postgres -d postgres -P border=2 -P null='' \
    -c "select pid, backend_type, state from pg_stat_activity order by pid;" >&2
  docker logs --tail 80 "$container" >&2
  exit 1
}

psql_exec() {
  docker exec "$container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

ensure_qwen_model() {
  local repo_cache="$1"
  local model_file="$2"
  local model_url="$3"
  local cached

  cached="$(
    docker exec "$container" sh -lc \
      "find /var/lib/postgresql/.cache/huggingface/hub/$repo_cache/snapshots '$model_dir' -name '$model_file' -print -quit 2>/dev/null || true"
  )"
  if [ -n "$cached" ]; then
    printf '%s\n' "$cached"
    return
  fi

  docker exec "$container" sh -lc "mkdir -p '$model_dir' && curl -fL --retry 3 '$model_url' -o '$model_dir/$model_file'"
  printf '%s/%s\n' "$model_dir" "$model_file"
}

log "Building Postgres image $image"
docker build -t "$image" -f docker/postgres/Dockerfile .
image_id="$(docker image inspect -f '{{.Id}}' "$image")"

if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
  container_image_id="$(docker inspect -f '{{.Image}}' "$container")"
  if [ "$container_image_id" != "$image_id" ]; then
    log "Replacing stale container image"
    docker start "$container" >/dev/null 2>&1 || true
    docker exec "$container" psql -U postgres -d postgres \
      -c "ALTER SYSTEM RESET shared_preload_libraries;" >/dev/null 2>&1 || true
    docker rm -f "$container" >/dev/null
  fi
fi

if ! docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
  log "Creating container $container"
  docker run -d \
    --name "$container" \
    -e POSTGRES_PASSWORD="$password" \
    -e CARGO_TARGET_DIR=/target \
    -p "127.0.0.1:$port:5432" \
    -v "$volume:/var/lib/postgresql" \
    -v "$PWD:/work:ro" \
    -v otlet-cargo-target:/target \
    -w /work \
    "$image" >/dev/null
else
  log "Starting container $container"
  docker start "$container" >/dev/null
fi

wait_ready

psql_exec -c "ALTER DATABASE postgres REFRESH COLLATION VERSION;" >/dev/null

log "Installing Otlet extension with features: $pgrx_features"
if docker exec "$container" sh -lc 'test -d /target/llama-cmake-cache && grep -q "GGML_OPENMP:BOOL=OFF" /target/llama-cmake-cache/*/build/CMakeCache.txt 2>/dev/null'; then
  log "Clearing stale llama.cpp build so OpenMP/native flags take effect"
  docker exec "$container" rm -rf /target/llama-cmake-cache
fi
docker exec "$container" psql -U postgres -d postgres \
  -c "ALTER SYSTEM RESET shared_preload_libraries;" >/dev/null 2>&1 || true
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

psql_exec -c "ALTER SYSTEM SET shared_preload_libraries = 'otlet';"

docker restart "$container" >/dev/null
wait_ready
wait_worker

cheap_model_artifact="$(ensure_qwen_model "$cheap_model_repo_cache" "$cheap_model_file" "$cheap_model_url")"
strong_model_artifact="$(ensure_qwen_model "$strong_model_repo_cache" "$strong_model_file" "$strong_model_url")"
worker_count="$(docker exec "$container" psql -U postgres -d postgres -qAt -c "select count(*) from pg_stat_activity where backend_type = 'otlet worker';")"

printf 'postgres_url=postgres://postgres:%s@127.0.0.1:%s/postgres\n' "$password" "$port"
printf 'worker_count=%s\n' "$worker_count"
printf 'cheap_model_artifact=%s\n' "$cheap_model_artifact"
printf 'strong_model_artifact=%s\n' "$strong_model_artifact"
