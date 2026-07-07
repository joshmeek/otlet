ensure_model_artifacts() {
  local cheap_model_file="${OTLET_CHEAP_MODEL_FILE:-Qwen3-1.7B-Q8_0.gguf}"
  local strong_model_file="${OTLET_STRONG_MODEL_FILE:-Qwen3.5-4B-Q4_K_M.gguf}"

  cheap_model_artifact="$(
    resolve_model_artifact \
      "cheap" \
      "OTLET_CHEAP_MODEL_ARTIFACT" \
      "$cheap_model_artifact" \
      "$cheap_model_file"
  )"
  strong_model_artifact="$(
    resolve_model_artifact \
      "strong" \
      "OTLET_STRONG_MODEL_ARTIFACT" \
      "$strong_model_artifact" \
      "$strong_model_file"
  )"
}

resolve_model_artifact() {
  local label="$1"
  local var_name="$2"
  local artifact="$3"
  local model_file="$4"

  if [ -z "$artifact" ]; then
    artifact="$(docker exec "$container" find /var/lib/postgresql -name "$model_file" -print -quit 2>/dev/null || true)"
  fi

  if [ -z "$artifact" ]; then
    echo "Missing $label model artifact. Set $var_name to an existing container path or run ./scripts/otlet-setup.sh first" >&2
    exit 1
  fi

  if ! docker exec "$container" test -f "$artifact"; then
    echo "Missing $label model artifact at $artifact from $var_name. Set $var_name to an existing container path or run ./scripts/otlet-setup.sh first" >&2
    exit 1
  fi

  printf '%s\n' "$artifact"
}

register_models() {
  ensure_model_artifacts
  psql_exec \
    -v cheap_model_name="$cheap_model_name" \
    -v cheap_model_artifact="$cheap_model_artifact" \
    -v strong_model_name="$strong_model_name" \
    -v strong_alias_model_name="$strong_alias_model_name" \
    -v strong_model_artifact="$strong_model_artifact" >/dev/null <<'SQL'
SET client_min_messages TO warning;
CREATE EXTENSION IF NOT EXISTS otlet;
SELECT otlet.register_model(:'cheap_model_name', :'cheap_model_artifact');
SELECT otlet.register_model(:'strong_model_name', :'strong_model_artifact');
SELECT otlet.register_model(:'strong_alias_model_name', :'strong_model_artifact');
SQL
}
