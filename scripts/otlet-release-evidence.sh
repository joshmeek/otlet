#!/usr/bin/env bash
set -euo pipefail

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
database="${OTLET_DATABASE:-postgres}"
matrix_file="release/runtime-matrix.json"
release_epoch="$(git log -1 --format=%ct)"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"

for command in docker git jq sha256sum; do
  command -v "$command" >/dev/null || {
    echo "Missing release evidence command: $command" >&2
    exit 1
  }
done

[ -f "$matrix_file" ] || {
  echo "Missing runtime matrix $matrix_file" >&2
  exit 1
}
docker container inspect "$container" >/dev/null 2>&1 || {
  echo "Container $container is not available; run ./scripts/otlet-setup.sh first" >&2
  exit 1
}

if [ -n "${OTLET_RELEASE_OUTPUT:-}" ]; then
  output_dir="$OTLET_RELEASE_OUTPUT"
  [ ! -e "$output_dir" ] || {
    echo "Release evidence output already exists: $output_dir" >&2
    exit 1
  }
  mkdir -p "$output_dir"
else
  mkdir -p .local
  output_dir="$(mktemp -d .local/otlet-release-evidence.XXXXXX)"
fi
output_dir="$(cd "$output_dir" && pwd)"

host_tmp="$(mktemp -d "${TMPDIR:-/tmp}/otlet-release-evidence.XXXXXX")"
target_a="$(docker exec "$container" mktemp -d /target/otlet-release-a.XXXXXX)"
target_b="$(docker exec "$container" mktemp -d /target/otlet-release-b.XXXXXX)"
package_a="$(docker exec "$container" mktemp -d /tmp/otlet-release-package-a.XXXXXX)"
package_b="$(docker exec "$container" mktemp -d /tmp/otlet-release-package-b.XXXXXX)"

cleanup() {
  rm -rf "$host_tmp"
  docker exec "$container" rm -rf "$target_a" "$target_b" "$package_a" "$package_b" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_package() {
  local target_dir="$1"
  local package_dir="$2"
  local remap_flags

  remap_flags="--remap-path-prefix=/work=/src --remap-path-prefix=$target_dir=/target -C link-arg=-Wl,--no-gc-sections"
  docker exec \
    -e CARGO_INCREMENTAL=0 \
    -e CARGO_PROFILE_RELEASE_STRIP=debuginfo \
    -e CARGO_TARGET_DIR="$target_dir" \
    -e CFLAGS="-ffile-prefix-map=/work=/src -ffile-prefix-map=$target_dir=/target" \
    -e CXXFLAGS="-ffile-prefix-map=/work=/src -ffile-prefix-map=$target_dir=/target" \
    -e LC_ALL=C \
    -e RUSTFLAGS="$remap_flags" \
    -e SOURCE_DATE_EPOCH="$release_epoch" \
    -e TZ=UTC \
    -w /work \
    "$container" \
    cargo pgrx package \
      -p otlet_pg \
      --pg-config /usr/bin/pg_config \
      --out-dir "$package_dir" \
      --no-default-features \
      --features native,openmp
}

package_manifest() {
  local package_root="$1"
  local manifest="$2"
  local file relative sha bytes

  : >"$manifest.rows"
  while IFS= read -r file; do
    relative="${file#"$package_root"/}"
    sha="$(sha256sum "$file" | awk '{print $1}')"
    bytes="$(stat -f %z "$file" 2>/dev/null || stat -c %s "$file")"
    jq -cn \
      --arg path "$relative" \
      --arg sha256 "$sha" \
      --argjson bytes "$bytes" \
      '{path: $path, bytes: $bytes, sha256: $sha256}' >>"$manifest.rows"
  done < <(find "$package_root" -type f | LC_ALL=C sort)
  jq -s 'sort_by(.path)' "$manifest.rows" >"$manifest"
}

echo "Building release package A"
build_package "$target_a" "$package_a"
echo "Building release package B"
build_package "$target_b" "$package_b"

mkdir -p "$host_tmp/package-a" "$host_tmp/package-b"
docker cp "$container:$package_a/." "$host_tmp/package-a"
docker cp "$container:$package_b/." "$host_tmp/package-b"
package_manifest "$host_tmp/package-a" "$host_tmp/package-a.json"
package_manifest "$host_tmp/package-b" "$host_tmp/package-b.json"
if ! cmp -s "$host_tmp/package-a.json" "$host_tmp/package-b.json"; then
  diff -u "$host_tmp/package-a.json" "$host_tmp/package-b.json" >&2 || true
  echo "Release package manifests differ" >&2
  exit 1
fi
cp "$host_tmp/package-a.json" "$output_dir/package-manifest.json"

architecture="$(docker exec "$container" uname -m)"
archive_name="otlet-pg18-linux-${architecture}.tar.gz"
archive_tmp="/tmp/$run_id-$archive_name"
docker exec \
  -e SOURCE_DATE_EPOCH="$release_epoch" \
  "$container" sh -c '
    set -eu
    tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner -C "$1" -cf - . |
      gzip -n >"$2"
  ' sh "$package_a" "$archive_tmp"
docker cp "$container:$archive_tmp" "$output_dir/$archive_name"
docker exec "$container" rm -f "$archive_tmp"

source_manifest="$host_tmp/source-manifest.json"
: >"$host_tmp/source-manifest.rows"
while IFS= read -r file; do
  [ -f "$file" ] || continue
  jq -cn \
    --arg path "$file" \
    --arg sha256 "$(sha256sum "$file" | awk '{print $1}')" \
    '{path: $path, sha256: $sha256}' >>"$host_tmp/source-manifest.rows"
done < <(git ls-files --cached --others --exclude-standard | LC_ALL=C sort)
jq -s 'sort_by(.path)' "$host_tmp/source-manifest.rows" >"$source_manifest"
source_sha256="$(sha256sum "$source_manifest" | awk '{print $1}')"
cp "$source_manifest" "$output_dir/source-manifest.json"
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  source_clean=true
else
  source_clean=false
fi

docker exec -w /work "$container" cargo metadata --locked --format-version 1 >"$host_tmp/cargo-metadata.json"
cargo_version="$(docker exec "$container" cargo --version)"
rustc_version="$(docker exec "$container" rustc --version)"
jq \
  --arg cargo_version "$cargo_version" \
  --arg rustc_version "$rustc_version" \
  --arg source_sha256 "$source_sha256" '
  . as $metadata |
  ($metadata.workspace_members[0]) as $root_id |
  ($metadata.packages[] | select(.id == $root_id)) as $root |
  {
    bomFormat: "CycloneDX",
    specVersion: "1.6",
    version: 1,
    metadata: {
      component: {
        type: "application",
        "bom-ref": $root.id,
        name: $root.name,
        version: $root.version,
        properties: [
          {name: "otlet:source_sha256", value: $source_sha256}
        ]
      },
      tools: {
        components: [
          {type: "application", name: "cargo", version: $cargo_version},
          {type: "application", name: "rustc", version: $rustc_version}
        ]
      }
    },
    components: [
      $metadata.packages[] |
      select(.id != $root_id) |
      {
        type: "library",
        "bom-ref": .id,
        name: .name,
        version: .version,
        purl: ("pkg:cargo/" + .name + "@" + .version),
        licenses: (if .license then [{expression: .license}] else [] end),
        properties: [
          {name: "cargo:source", value: (.source // "workspace")}
        ]
      }
    ] | sort_by(.name, .version, .["bom-ref"]),
    dependencies: [
      $metadata.resolve.nodes[] |
      {ref: .id, dependsOn: ([.deps[].pkg] | sort | unique)}
    ] | sort_by(.ref)
  }' "$host_tmp/cargo-metadata.json" >"$output_dir/sbom.cdx.json"
jq -e '.bomFormat == "CycloneDX" and .specVersion == "1.6" and (.components | length > 0)' "$output_dir/sbom.cdx.json" >/dev/null

echo "Generating RustSec vulnerability report"
audit_status=0
docker exec -w /work "$container" cargo audit --json >"$output_dir/vulnerabilities.json" || audit_status=$?
jq -e '.database and .vulnerabilities' "$output_dir/vulnerabilities.json" >/dev/null

models_json="$(docker exec "$container" psql -U postgres -d "$database" -qAt -c "
  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', name, 'artifact_identity', artifact_identity) ORDER BY name), '[]'::jsonb)
  FROM otlet.models;
")"
task_contracts_json="$(docker exec "$container" psql -U postgres -d "$database" -qAt -c "
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'name', name,
    'instruction_sha256', encode(sha256(convert_to(instruction, 'UTF8')), 'hex'),
    'output_schema_sha256', encode(sha256(convert_to(otlet.semantic_canonical_jsonb(output_schema)::text, 'UTF8')), 'hex'),
    'runtime_options_sha256', encode(sha256(convert_to(otlet.semantic_canonical_jsonb(runtime_options)::text, 'UTF8')), 'hex')
  ) ORDER BY name), '[]'::jsonb)
  FROM otlet.tasks;
")"
runtime_json="$(docker exec "$container" psql -U postgres -d "$database" -qAt -c "
  SELECT COALESCE((
    SELECT runtime_fingerprint
    FROM otlet.inference_receipt_trace_status
    WHERE runtime_fingerprint IS NOT NULL
    ORDER BY receipt_id DESC
    LIMIT 1
  ), 'null'::jsonb);
")"
[ "$runtime_json" != "null" ] || {
  echo "Release evidence needs one completed runtime fingerprint; run ./scripts/otlet-demo.sh first" >&2
  exit 1
}

postgres_json="$(docker exec "$container" psql -U postgres -d "$database" -qAt -c "
  SELECT jsonb_build_object(
    'version', version(),
    'server_version', current_setting('server_version'),
    'server_version_num', current_setting('server_version_num')
  );
")"
os_json="$(docker exec "$container" sh -c '. /etc/os-release; printf "{\"id\":\"%s\",\"version\":\"%s\",\"codename\":\"%s\",\"pretty_name\":\"%s\"}\n" "$ID" "$VERSION_ID" "$VERSION_CODENAME" "$PRETTY_NAME"')"
cpu_model="$(docker exec "$container" awk -F ': ' '/^model name|^Model/ {print $2; exit}' /proc/cpuinfo)"
image_id="$(docker image inspect -f '{{.Id}}' "$(docker inspect -f '{{.Config.Image}}' "$container")")"
linked_libraries_json="$(docker exec "$container" sh -c 'ldd "$(pg_config --pkglibdir)/otlet.so"' | jq -Rsc 'split("\n") | map(select(length > 0))')"
package_sha256="$(sha256sum "$output_dir/$archive_name" | awk '{print $1}')"
sql_sha256="$(jq -r '.[] | select(.path | endswith(".sql")) | .sha256' "$output_dir/package-manifest.json")"
binary_sha256="$(jq -r '.[] | select(.path | endswith("/otlet.so")) | .sha256' "$output_dir/package-manifest.json")"
pack_manifest_json="$(jq '[.[] | select(.path | startswith("packs/"))]' "$source_manifest")"

pg_version_num="$(jq -r '.server_version_num' <<<"$postgres_json")"
pg_version="$((10#$pg_version_num / 10000)).$((10#$pg_version_num % 100))"
os_id="$(jq -r '.id' <<<"$os_json")"
os_version="$(jq -r '.version' <<<"$os_json")"
os_codename="$(jq -r '.codename' <<<"$os_json")"
llama_version="$(jq -r '.output_contract.llama_cpp.crate_version' <<<"$runtime_json")"
llama_revision="$(jq -r '.output_contract.llama_cpp.revision' <<<"$runtime_json")"
jq -e \
  --arg architecture "$architecture" \
  --arg llama_revision "$llama_revision" \
  --arg llama_version "$llama_version" \
  --arg os_codename "$os_codename" \
  --arg os_id "$os_id" \
  --arg os_version "$os_version" \
  --arg pg_version "$pg_version" '
  any(.supported[];
    (.postgres.tested == $pg_version) and
    (.os.id == $os_id) and
    (.os.version == $os_version) and
    (.os.codename == $os_codename) and
    (.cpu.architecture == $architecture) and
    (.runtime.llama_cpp_sys_version == $llama_version) and
    (.runtime.llama_cpp_revision == $llama_revision)
  )' "$matrix_file" >/dev/null || {
    echo "Current runtime is outside release/runtime-matrix.json" >&2
    exit 1
  }

jq -n \
  --arg archive "$archive_name" \
  --arg archive_sha256 "$package_sha256" \
  --arg architecture "$architecture" \
  --arg binary_sha256 "$binary_sha256" \
  --arg cargo_audit_version "$(docker exec "$container" cargo audit --version)" \
  --arg cargo_pgrx_version "$(docker exec "$container" cargo pgrx --version)" \
  --arg cargo_version "$cargo_version" \
  --arg cpu_model "$cpu_model" \
  --arg git_head "$(git rev-parse HEAD)" \
  --arg image_id "$image_id" \
  --arg release_epoch "$release_epoch" \
  --arg rustc_version "$rustc_version" \
  --arg source_sha256 "$source_sha256" \
  --arg sql_sha256 "$sql_sha256" \
  --argjson source_clean "$source_clean" \
  --argjson linked_libraries "$linked_libraries_json" \
  --argjson models "$models_json" \
  --argjson os "$os_json" \
  --argjson pack_manifest "$pack_manifest_json" \
  --argjson postgres "$postgres_json" \
  --argjson runtime "$runtime_json" \
  --argjson task_contracts "$task_contracts_json" \
  '{
    format: "otlet.release-evidence.v1",
    source: {
      git_head: $git_head,
      tree_sha256: $source_sha256,
      clean: $source_clean,
      source_date_epoch: ($release_epoch | tonumber)
    },
    artifacts: {
      archive: $archive,
      archive_sha256: $archive_sha256,
      extension_binary_sha256: $binary_sha256,
      extension_sql_sha256: $sql_sha256,
      repeated_build_manifests_equal: true
    },
    contracts: {
      models: $models,
      prompts_and_schemas: $task_contracts,
      packs: $pack_manifest,
      runtime_fingerprint: $runtime
    },
    platform: {
      postgres: $postgres,
      operating_system: $os,
      cpu: {architecture: $architecture, model: $cpu_model},
      linked_libraries: $linked_libraries,
      container_image_id: $image_id
    },
    build_tools: {
      rustc: $rustc_version,
      cargo: $cargo_version,
      cargo_pgrx: $cargo_pgrx_version,
      cargo_audit: $cargo_audit_version
    }
  }' >"$output_dir/release-identity.json"

cp "$matrix_file" "$output_dir/runtime-matrix.json"
for file in "$archive_name" package-manifest.json release-identity.json runtime-matrix.json sbom.cdx.json source-manifest.json vulnerabilities.json; do
  sha256sum "$output_dir/$file"
done | sed "s#  $output_dir/#  #" >"$output_dir/SHA256SUMS"

unsound_count="$(jq '(.warnings.unsound // []) | length' "$output_dir/vulnerabilities.json")"
yanked_count="$(jq '(.warnings.yanked // []) | length' "$output_dir/vulnerabilities.json")"
if [ "$audit_status" -ne 0 ] || [ "$unsound_count" -ne 0 ] || [ "$yanked_count" -ne 0 ]; then
  echo "RustSec reported release-blocking findings; inspect $output_dir/vulnerabilities.json" >&2
  exit 1
fi
echo "release_reproducibility_contract=true|$(jq 'length' "$output_dir/package-manifest.json")|$architecture|$pg_version|$llama_revision"
echo "release_evidence_output=$output_dir"
