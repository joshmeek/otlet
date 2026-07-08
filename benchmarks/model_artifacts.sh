container_path_exists() {
  local path="$1"
  docker exec "$container" sh -lc "test -e $(sh_quote "$path")"
}

container_file_size() {
  local path="$1"
  docker exec "$container" sh -lc "stat -Lc%s $(sh_quote "$path") 2>/dev/null || echo 0"
}

find_existing_artifact() {
  local hf_repo="$1"
  local filename="$2"
  local basename
  local repo_cache
  local search_model_dir="${model_dir:-/var/lib/postgresql/otlet-models}"
  basename="$(basename "$filename")"
  repo_cache="models--${hf_repo//\//--}"
  docker exec "$container" sh -lc "find $(sh_quote "$search_model_dir") /var/lib/postgresql/.cache/huggingface/hub/$(sh_quote "$repo_cache")/snapshots -name $(sh_quote "$basename") -print -quit 2>/dev/null" | head -n 1 || true
}

download_artifact() {
  local hf_repo="$1"
  local filename="$2"
  local model_key="$3"
  local requires_split="${4:-false}"
  local dest_dir="$scratch_dir/$model_key"
  local dest="$dest_dir/$(basename "$filename")"
  local tmp="$dest.part"

  docker exec "$container" sh -lc "mkdir -p $(sh_quote "$dest_dir")"
  if [[ "$requires_split" = "true" && "$filename" =~ ^(.+)-00001-of-([0-9]+)\.gguf$ ]]; then
    local prefix="${BASH_REMATCH[1]}"
    local total="${BASH_REMATCH[2]}"
    local part
    for part in $(seq -f "%05g" 1 "$((10#$total))"); do
      local split_file="${prefix}-${part}-of-${total}.gguf"
      local split_dest="$dest_dir/$(basename "$split_file")"
      local split_tmp="$split_dest.part"
      local split_url="https://huggingface.co/$hf_repo/resolve/main/$split_file"
      docker exec "$container" sh -lc "rm -f $(sh_quote "$split_tmp") && curl -fL --retry 3 --connect-timeout 20 $(sh_quote "$split_url") -o $(sh_quote "$split_tmp") && mv $(sh_quote "$split_tmp") $(sh_quote "$split_dest")"
    done
  else
    local url="https://huggingface.co/$hf_repo/resolve/main/$filename"
    docker exec "$container" sh -lc "rm -f $(sh_quote "$tmp") && curl -fL --retry 3 --connect-timeout 20 $(sh_quote "$url") -o $(sh_quote "$tmp") && mv $(sh_quote "$tmp") $(sh_quote "$dest")"
  fi
  printf '%s\t%s\n' "$model_key" "$dest" >> "$downloaded_paths"
  printf '%s\n' "$dest"
}

model_artifact_path() {
  local model_name="$1"
  psql_value -v model_name="$model_name" <<'SQL'
SELECT artifact_path FROM otlet.models WHERE name = :'model_name';
SQL
}

ensure_extension() {
  psql_exec >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS otlet;
SQL
}

register_model() {
  local model_name="$1"
  local artifact_path="$2"
  psql_exec -v model_name="$model_name" -v artifact_path="$artifact_path" >/dev/null <<'SQL'
SELECT otlet.register_model(:'model_name', :'artifact_path');
SQL
}

cleanup_downloaded_model() {
  local model_name="$1"
  local base_model_key="$2"
  local external_artifact="$3"
  local model_dir="$scratch_dir/$base_model_key"
  local removed_bytes=0

  if [[ "$keep_models" = "1" || "$external_artifact" != "false" ]]; then
    return
  fi

  psql_exec -v model_name="$model_name" >/dev/null <<'SQL' || true
DELETE FROM otlet.runtime_slots WHERE model_name = :'model_name';
SQL
  removed_bytes="$(container_dir_bytes "$model_dir")"
  docker exec "$container" sh -lc "rm -rf $(sh_quote "$model_dir")" >/dev/null || true
  artifact_bytes_removed_early=$((artifact_bytes_removed_early + removed_bytes))
}
