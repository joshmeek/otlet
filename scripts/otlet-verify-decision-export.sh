#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 BUNDLE_DIR [ED25519_PUBLIC_KEY]" >&2
  exit 2
fi

bundle_dir="$1"
public_key="${2:-$bundle_dir/signing-public-key.pem}"
manifest="$bundle_dir/audit-manifest.json"
envelope="$bundle_dir/recommendation-envelope.json"
signature="$bundle_dir/recommendation-envelope.sig"

for command in jq openssl sha256sum stat cmp; do
  command -v "$command" >/dev/null || {
    echo "Missing decision verification command: $command" >&2
    exit 1
  }
done
for file in "$manifest" "$envelope" "$signature" "$public_key"; do
  [ -r "$file" ] || {
    echo "Decision export file is not readable: $file" >&2
    exit 1
  }
done

host_tmp="$(mktemp -d "${TMPDIR:-/tmp}/otlet-decision-verify.XXXXXX")"
cleanup() {
  rm -rf "$host_tmp"
}
trap cleanup EXIT

jq -S -c . "$manifest" | cmp -s - "$manifest" || {
  echo "Audit manifest is not canonical JSON" >&2
  exit 1
}
jq -S -c . "$envelope" | cmp -s - "$envelope" || {
  echo "Recommendation envelope is not canonical JSON" >&2
  exit 1
}
jq -e '
  .format == "otlet.audit-manifest.v1" and
  (.receipt_id | type == "number") and
  ([.files[].path] == ["decision.csv", "decision.sql"]) and
  all(.files[];
    (.bytes | type == "number") and
    (.sha256 | test("^[0-9a-f]{64}$"))
  )
' "$manifest" >/dev/null || {
  echo "Audit manifest contract is invalid" >&2
  exit 1
}

while IFS=$'\t' read -r path expected_bytes expected_sha256; do
  file="$bundle_dir/$path"
  [ -f "$file" ] || {
    echo "Manifest payload is missing: $path" >&2
    exit 1
  }
  actual_bytes="$(stat -f %z "$file" 2>/dev/null || stat -c %s "$file")"
  actual_sha256="$(sha256sum "$file" | awk '{print $1}')"
  [ "$actual_bytes" = "$expected_bytes" ] && [ "$actual_sha256" = "$expected_sha256" ] || {
    echo "Manifest payload mismatch: $path" >&2
    exit 1
  }
done < <(jq -r '.files[] | [.path, (.bytes | tostring), .sha256] | @tsv' "$manifest")

manifest_sha256="$(sha256sum "$manifest" | awk '{print $1}')"
openssl pkey -pubin -in "$public_key" -outform DER -out "$host_tmp/public.der"
signing_key_sha256="$(sha256sum "$host_tmp/public.der" | awk '{print $1}')"
receipt_id="$(jq -r '.receipt_id' "$manifest")"

jq -e \
  --arg manifest_sha256 "$manifest_sha256" \
  --arg signing_key_sha256 "$signing_key_sha256" \
  --argjson receipt_id "$receipt_id" '
  .recommendation.recommendation_id as $recommendation_id |
  .format == "otlet.signed-recommendation.v1" and
  .receipt_id == $receipt_id and
  .recommendation.receipt_id == $receipt_id and
  .manifest_sha256 == $manifest_sha256 and
  .signing_key_sha256 == $signing_key_sha256 and
  .recommendation.format == "otlet.recommendation.v1" and
  .recommendation.recommendation_id == ("sha256:" + .recommendation.decision_trace_sha256) and
  (.destinations | type == "array") and
  all(.destinations[];
    .recommendation_id == $recommendation_id and
    (.destination | test("^[a-z0-9][a-z0-9_.-]{0,127}$")) and
    (.idempotency_key | test("^sha256:[0-9a-f]{64}$")) and
    (.state == "exported" or .state == "received" or .state == "applied" or .state == "rejected" or .state == "unknown")
  )
' "$envelope" >/dev/null || {
  echo "Recommendation envelope contract is invalid" >&2
  exit 1
}

openssl base64 -d -A -in "$signature" -out "$host_tmp/signature.bin"
openssl pkeyutl \
  -verify \
  -pubin \
  -inkey "$public_key" \
  -rawin \
  -in "$envelope" \
  -sigfile "$host_tmp/signature.bin" >/dev/null || {
    echo "Recommendation signature is invalid" >&2
    exit 1
  }

echo "decision_export_verified=$receipt_id|$manifest_sha256|$signing_key_sha256"
