log "Checking signed decision exports"

signed_receipt_id="$(psql_value <<'SQL'
SELECT receipt.id
FROM otlet.inference_receipts receipt
WHERE EXISTS (SELECT 1 FROM otlet.outputs output WHERE output.receipt_id = receipt.id)
  AND EXISTS (SELECT 1 FROM otlet.review_events review WHERE review.receipt_id = receipt.id)
  AND EXISTS (
    SELECT 1
    FROM otlet.actions action
    JOIN otlet.action_execution_receipts execution ON execution.action_id = action.id
    WHERE action.receipt_id = receipt.id
  )
ORDER BY receipt.id
LIMIT 1;
SQL
)"
[[ "$signed_receipt_id" =~ ^[1-9][0-9]*$ ]] || {
  echo "Expected one reviewed recommendation with an execution receipt" >&2
  exit 1
}

signed_trace_contract="$(psql_value -v receipt_id="$signed_receipt_id" <<'SQL'
SELECT
  (decision_trace ?& ARRAY[
    'source', 'task', 'model', 'prompt', 'schema', 'runtime',
    'output', 'review', 'action', 'freshness', 'receipt'
  ])::text || '|' ||
  (jsonb_array_length(decision_trace -> 'review') > 0)::text || '|' ||
  (jsonb_array_length(decision_trace -> 'action') > 0)::text || '|' ||
  EXISTS (
    SELECT 1
    FROM jsonb_array_elements(decision_trace -> 'action') action,
         jsonb_array_elements(action -> 'executions') execution
    WHERE execution ->> 'execution_receipt_id' IS NOT NULL
  )::text || '|' ||
  (recommendation_id = 'sha256:' || decision_trace_sha256)::text || '|' ||
  (
    decision_trace::text NOT LIKE '%"payload":%'
    AND decision_trace::text NOT LIKE '%"reason":%'
    AND decision_trace::text NOT LIKE '%"raw_output":%'
    AND decision_trace::text NOT LIKE '%"source_row":%'
  )::text
FROM otlet.decision_trace_export
WHERE receipt_id = :'receipt_id'::bigint;
SQL
)"
[ "$signed_trace_contract" = "true|true|true|true|true|true" ] || {
  echo "Expected a complete decision identity trace, got $signed_trace_contract" >&2
  exit 1
}

repo_root="$(cd "$demo_dir/../.." && pwd)"
signed_export_tmp="$(mktemp -d "${TMPDIR:-/tmp}/otlet-signed-export.XXXXXX")"
signing_key="$signed_export_tmp/signing-key.pem"
bundle_a="$signed_export_tmp/bundle-a"
bundle_b="$signed_export_tmp/bundle-b"
openssl genpkey -algorithm ED25519 -out "$signing_key"

OTLET_PG_CONTAINER="$container" OTLET_DATABASE="$database" \
  "$repo_root/scripts/otlet-export-decision.sh" \
  "$signed_receipt_id" "$bundle_a" "$signing_key" >/dev/null
"$repo_root/scripts/otlet-verify-decision-export.sh" "$bundle_a" >/dev/null
OTLET_PG_CONTAINER="$container" OTLET_DATABASE="$database" \
  "$repo_root/scripts/otlet-export-decision.sh" \
  "$signed_receipt_id" "$bundle_b" "$signing_key" >/dev/null

deterministic_bundle=false
if diff -rq "$bundle_a" "$bundle_b" >/dev/null; then
  deterministic_bundle=true
fi

sql_import_count="$({
  cat "$bundle_a/decision.sql"
  printf '%s\n' 'SELECT count(*) FROM otlet_decision_trace_export;'
} | docker exec \
  -e PGOPTIONS='-c search_path=pg_temp' \
  -i "$container" \
  psql -U postgres -d "$database" -v ON_ERROR_STOP=1 -qAt)"

cp "$bundle_a/decision.csv" "$signed_export_tmp/decision.csv.original"
printf 'tamper\n' >>"$bundle_a/decision.csv"
payload_tamper_rejected=false
if ! "$repo_root/scripts/otlet-verify-decision-export.sh" "$bundle_a" >/dev/null 2>&1; then
  payload_tamper_rejected=true
fi
cp "$signed_export_tmp/decision.csv.original" "$bundle_a/decision.csv"

cp "$bundle_a/audit-manifest.json" "$signed_export_tmp/audit-manifest.original"
printf ' ' >>"$bundle_a/audit-manifest.json"
manifest_tamper_rejected=false
if ! "$repo_root/scripts/otlet-verify-decision-export.sh" "$bundle_a" >/dev/null 2>&1; then
  manifest_tamper_rejected=true
fi
cp "$signed_export_tmp/audit-manifest.original" "$bundle_a/audit-manifest.json"
"$repo_root/scripts/otlet-verify-decision-export.sh" "$bundle_a" >/dev/null

key_boundary_contract="$(psql_value <<'SQL'
SELECT count(*)
FROM information_schema.columns
WHERE table_schema = 'otlet'
  AND column_name IN ('private_key', 'signing_key', 'signing_private_key');
SQL
)"
private_key_external=false
if [ "$key_boundary_contract" = "0" ] && [ ! -e "$bundle_a/signing-key.pem" ]; then
  private_key_external=true
fi

signed_decision_export_contract="$signed_trace_contract|$deterministic_bundle|$sql_import_count|$payload_tamper_rejected|$manifest_tamper_rejected|$private_key_external"
echo "signed_decision_export_contract=$signed_decision_export_contract"
[ "$signed_decision_export_contract" = "true|true|true|true|true|true|true|1|true|true|true" ] || {
  echo "Expected deterministic signed decision exports and tamper rejection, got $signed_decision_export_contract" >&2
  exit 1
}

rm -rf -- "$signed_export_tmp"
