#!/usr/bin/env bash
set -euo pipefail

image="${OTLET_PG_IMAGE:-otlet-postgres-dev:18.4-trixie}"
container="${OTLET_PG_CONTAINER:-otlet-postgres}"
volume="${OTLET_PG_VOLUME:-otlet-postgres-data}"
port="${OTLET_PG_PORT:-55432}"
password="${POSTGRES_PASSWORD:-postgres}"
pgrx_features="${OTLET_PGRX_FEATURES:-pg18}"
model_dir="${OTLET_MODEL_DIR:-/var/lib/postgresql/otlet-models}"
model_file="${OTLET_MODEL_FILE:-Qwen3-0.6B-Q8_0.gguf}"
model_url="${OTLET_MODEL_URL:-https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf}"

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
  local cached

  cached="$(
    docker exec "$container" sh -lc \
      "find /var/lib/postgresql/.cache/huggingface/hub/models--Qwen--Qwen3-0.6B-GGUF/snapshots '$model_dir' -name '$model_file' -print -quit 2>/dev/null"
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
docker exec "$container" psql -U postgres -d postgres \
  -c "ALTER SYSTEM RESET shared_preload_libraries;" >/dev/null 2>&1 || true
docker restart "$container" >/dev/null
wait_ready

docker exec "$container" cargo pgrx install \
  -p otlet_pg \
  --pg-config /usr/bin/pg_config \
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

model_artifact="$(ensure_qwen_model)"
worker_count="$(docker exec "$container" psql -U postgres -d postgres -qAt -c "select count(*) from pg_stat_activity where backend_type = 'otlet worker';")"

printf 'postgres_url=postgres://postgres:%s@127.0.0.1:%s/postgres\n' "$password" "$port"
printf 'worker_count=%s\n' "$worker_count"
printf 'model_artifact=%s\n' "$model_artifact"
