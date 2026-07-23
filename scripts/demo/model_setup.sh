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
  local cheap_model_sha256 strong_model_sha256 cheap_model_bytes strong_model_bytes
  local cheap_model_source strong_model_source cheap_model_revision strong_model_revision
  local cheap_model_quantization strong_model_quantization cheap_model_license strong_model_license

  cheap_model_sha256="$(docker exec "$container" sha256sum "$cheap_model_artifact" | awk '{print $1}')"
  strong_model_sha256="$(docker exec "$container" sha256sum "$strong_model_artifact" | awk '{print $1}')"
  cheap_model_bytes="$(docker exec "$container" stat -Lc %s "$cheap_model_artifact")"
  strong_model_bytes="$(docker exec "$container" stat -Lc %s "$strong_model_artifact")"
  cheap_model_source="${OTLET_CHEAP_MODEL_SOURCE:-https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf}"
  strong_model_source="${OTLET_STRONG_MODEL_SOURCE:-https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf}"
  cheap_model_revision="${OTLET_CHEAP_MODEL_REVISION:-main}"
  strong_model_revision="${OTLET_STRONG_MODEL_REVISION:-main}"
  cheap_model_quantization="${OTLET_CHEAP_MODEL_QUANTIZATION:-${cheap_model_artifact##*-}}"
  strong_model_quantization="${OTLET_STRONG_MODEL_QUANTIZATION:-${strong_model_artifact##*-}}"
  cheap_model_quantization="${cheap_model_quantization%.gguf}"
  strong_model_quantization="${strong_model_quantization%.gguf}"
  cheap_model_license="${OTLET_CHEAP_MODEL_LICENSE:-unknown}"
  strong_model_license="${OTLET_STRONG_MODEL_LICENSE:-unknown}"
  psql_exec \
    -v cheap_model_name="$cheap_model_name" \
    -v cheap_model_artifact="$cheap_model_artifact" \
    -v cheap_model_sha256="$cheap_model_sha256" \
    -v cheap_model_bytes="$cheap_model_bytes" \
    -v cheap_model_source="$cheap_model_source" \
    -v cheap_model_revision="$cheap_model_revision" \
    -v cheap_model_quantization="$cheap_model_quantization" \
    -v cheap_model_license="$cheap_model_license" \
    -v strong_model_name="$strong_model_name" \
    -v strong_alias_model_name="$strong_alias_model_name" \
    -v strong_model_artifact="$strong_model_artifact" \
    -v strong_model_sha256="$strong_model_sha256" \
    -v strong_model_bytes="$strong_model_bytes" \
    -v strong_model_source="$strong_model_source" \
    -v strong_model_revision="$strong_model_revision" \
    -v strong_model_quantization="$strong_model_quantization" \
    -v strong_model_license="$strong_model_license" >/dev/null <<'SQL'
SET client_min_messages TO warning;
CREATE EXTENSION IF NOT EXISTS otlet;
SELECT otlet.register_model(
  :'cheap_model_name',
  :'cheap_model_artifact',
  :'cheap_model_sha256',
  jsonb_build_object(
    'sha256', :'cheap_model_sha256',
    'bytes', :'cheap_model_bytes'::bigint,
    'source', :'cheap_model_source',
    'revision', :'cheap_model_revision',
    'quantization', :'cheap_model_quantization',
    'license', :'cheap_model_license'
  )
);
SELECT otlet.register_model(
  :'strong_model_name',
  :'strong_model_artifact',
  :'strong_model_sha256',
  jsonb_build_object(
    'sha256', :'strong_model_sha256',
    'bytes', :'strong_model_bytes'::bigint,
    'source', :'strong_model_source',
    'revision', :'strong_model_revision',
    'quantization', :'strong_model_quantization',
    'license', :'strong_model_license'
  )
);
SELECT otlet.register_model(
  :'strong_alias_model_name',
  :'strong_model_artifact',
  :'strong_model_sha256',
  jsonb_build_object(
    'sha256', :'strong_model_sha256',
    'bytes', :'strong_model_bytes'::bigint,
    'source', :'strong_model_source',
    'revision', :'strong_model_revision',
    'quantization', :'strong_model_quantization',
    'license', :'strong_model_license'
  )
);
SQL
}
