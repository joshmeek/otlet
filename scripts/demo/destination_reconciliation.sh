log "Checking destination reconciliation"

destination_receipt_id="$(psql_value <<'SQL'
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
[[ "$destination_receipt_id" =~ ^[1-9][0-9]*$ ]] || {
  echo "Expected one recommendation for destination reconciliation" >&2
  exit 1
}

register_destination() {
  local destination="$1"
  psql_value -v receipt_id="$destination_receipt_id" -v destination="$destination" <<'SQL'
SELECT destination_export_id || '|' || recommendation_id || '|' || idempotency_key || '|' || reconciliation_state
FROM otlet.register_destination_export(:'receipt_id'::bigint, :'destination');
SQL
}

apply_export="$(register_destination 'demo-apply')"
apply_export_retry="$(register_destination 'demo-apply')"
received_export="$(register_destination 'demo-received')"
rejected_export="$(register_destination 'demo-rejected')"
unknown_export="$(register_destination 'demo-unknown')"
exported_export="$(register_destination 'demo-exported')"

IFS='|' read -r apply_export_id apply_recommendation_id apply_idempotency_key apply_state <<<"$apply_export"
IFS='|' read -r unknown_export_id _ _ unknown_state <<<"$unknown_export"
[ "$apply_export" = "$apply_export_retry" ] && [ "$apply_state" = "exported" ] && [ "$unknown_state" = "exported" ] || {
  echo "Expected stable destination export registration" >&2
  exit 1
}
psql_value -v export_id="$unknown_export_id" <<'SQL' >/dev/null
SELECT otlet.mark_destination_unknown(:'export_id'::bigint, 'delivery_timeout');
SQL

repo_root="$(cd "$demo_dir/../.." && pwd)"
destination_tmp="$(mktemp -d "${TMPDIR:-/tmp}/otlet-destination-reconciliation.XXXXXX")"
receiver_private_key="$destination_tmp/receiver-private.pem"
receiver_public_key="$destination_tmp/receiver-public.pem"
openssl genpkey -algorithm ED25519 -out "$receiver_private_key"
openssl pkey -in "$receiver_private_key" -pubout -out "$receiver_public_key"

write_destination_ack() {
  local destination="$1"
  local recommendation_id="$2"
  local idempotency_key="$3"
  local acknowledgement_id="$4"
  local state="$5"
  local execution_receipt_id="$6"
  local replay_decision="$7"
  local replay_of="$8"
  local output="$9"

  jq -S -c -n \
    --arg destination "$destination" \
    --arg recommendation_id "$recommendation_id" \
    --arg idempotency_key "$idempotency_key" \
    --arg acknowledgement_id "$acknowledgement_id" \
    --arg state "$state" \
    --arg execution_receipt_id "$execution_receipt_id" \
    --arg replay_decision "$replay_decision" \
    --arg replay_of "$replay_of" '
    {
      format: "otlet.destination-acknowledgement.v1",
      destination: $destination,
      recommendation_id: $recommendation_id,
      idempotency_key: $idempotency_key,
      acknowledgement_id: $acknowledgement_id,
      state: $state,
      destination_execution_receipt_id: (if $execution_receipt_id == "" then null else $execution_receipt_id end),
      replay_decision: $replay_decision,
      replay_of_acknowledgement_id: (if $replay_of == "" then null else $replay_of end)
    }' >"$output.json"
  openssl pkeyutl \
    -sign \
    -rawin \
    -inkey "$receiver_private_key" \
    -in "$output.json" |
    openssl base64 -A >"$output.sig"
  printf '\n' >>"$output.sig"
}

record_destination_ack() {
  local name="$1"
  "$repo_root/scripts/otlet-record-destination-ack.sh" \
    "$destination_tmp/$name.json" \
    "$destination_tmp/$name.sig" \
    "$receiver_public_key"
}

write_destination_ack \
  demo-apply "$apply_recommendation_id" "$apply_idempotency_key" \
  apply-received-1 received '' not_applicable '' "$destination_tmp/apply-received"
apply_received_first="$(record_destination_ack apply-received)"
apply_received_duplicate="$(record_destination_ack apply-received)"

write_destination_ack \
  demo-apply "$apply_recommendation_id" "$apply_idempotency_key" \
  apply-1 applied receiver-execution-1 fresh '' "$destination_tmp/apply"
record_destination_ack apply >/dev/null
write_destination_ack \
  demo-apply "$apply_recommendation_id" "$apply_idempotency_key" \
  apply-replay-1 applied receiver-execution-1 duplicate_replay apply-1 "$destination_tmp/apply-replay"
record_destination_ack apply-replay >/dev/null

IFS='|' read -r _ received_recommendation_id received_idempotency_key _ <<<"$received_export"
write_destination_ack \
  demo-received "$received_recommendation_id" "$received_idempotency_key" \
  received-1 received '' not_applicable '' "$destination_tmp/received"
record_destination_ack received >/dev/null

IFS='|' read -r _ rejected_recommendation_id rejected_idempotency_key _ <<<"$rejected_export"
write_destination_ack \
  demo-rejected "$rejected_recommendation_id" "$rejected_idempotency_key" \
  rejected-1 rejected '' not_applicable '' "$destination_tmp/rejected"
record_destination_ack rejected >/dev/null

write_destination_ack \
  demo-apply "$apply_recommendation_id" "$apply_idempotency_key" \
  apply-1 rejected '' not_applicable '' "$destination_tmp/conflict"
set +e
destination_conflict_output="$(record_destination_ack conflict 2>&1)"
destination_conflict_exit=$?
set -e
destination_conflict_rejected=false
if [ "$destination_conflict_exit" -ne 0 ] &&
   [[ "$destination_conflict_output" == *"acknowledgement conflicts with recorded evidence"* ]]; then
  destination_conflict_rejected=true
fi

destination_bundle="$destination_tmp/bundle"
OTLET_PG_CONTAINER="$container" OTLET_DATABASE="$database" \
  "$repo_root/scripts/otlet-export-decision.sh" \
  "$destination_receipt_id" "$destination_bundle" "$receiver_private_key" >/dev/null
"$repo_root/scripts/otlet-verify-decision-export.sh" "$destination_bundle" >/dev/null
exported_idempotency_key="$(jq -r '
  .destinations[] |
  select(.destination == "demo-apply") |
  .idempotency_key
' "$destination_bundle/recommendation-envelope.json")"

destination_status_contract="$(psql_value -v receipt_id="$destination_receipt_id" <<'SQL'
SELECT (
  count(*) = 5
  AND bool_or(destination = 'demo-exported' AND state = 'exported' AND acknowledgement_pending)
  AND bool_or(destination = 'demo-unknown' AND state = 'unknown' AND acknowledgement_pending AND acknowledgement_count = 0)
  AND bool_or(destination = 'demo-received' AND state = 'received' AND acknowledgement_count = 1)
  AND bool_or(destination = 'demo-rejected' AND state = 'rejected' AND acknowledgement_count = 1)
  AND bool_or(
    destination = 'demo-apply'
    AND state = 'applied'
    AND acknowledgement_count = 3
    AND destination_execution_receipt_id = 'receiver-execution-1'
    AND replay_decision = 'duplicate_replay'
    AND replay_of_acknowledgement_id = 'apply-1'
  )
  AND bool_and(recommendation_id = 'sha256:' || decision_trace_sha256)
  AND bool_and(cardinality(originating_execution_receipt_ids) > 0)
)::text
FROM otlet.destination_reconciliation_status
WHERE receipt_id = :'receipt_id'::bigint
  AND destination LIKE 'demo-%';
SQL
)"
destination_authentication_contract="$(psql_value <<'SQL'
SELECT (
  count(*) = 5
  AND bool_and(authentication_scheme = 'ed25519')
  AND bool_and(receiver_identity = session_user)
  AND bool_and(receiver_key_sha256 ~ '^[0-9a-f]{64}$')
  AND bool_and(signed_payload_sha256 ~ '^[0-9a-f]{64}$')
  AND bool_and(signature_sha256 ~ '^[0-9a-f]{64}$')
)::text
FROM otlet.destination_acknowledgements
JOIN otlet.destination_exports export ON export.id = destination_acknowledgements.destination_export_id
WHERE export.destination LIKE 'demo-%';
SQL
)"

destination_reconciliation_contract="$([ "$apply_received_first" != "$apply_received_duplicate" ] && echo true || echo false)|$([[ "$apply_received_first" == *'|received|false|'* && "$apply_received_duplicate" == *'|received|true|'* ]] && echo true || echo false)|$destination_status_contract|$destination_authentication_contract|$destination_conflict_rejected|$([ "$exported_idempotency_key" = "$apply_idempotency_key" ] && echo true || echo false)"
echo "destination_reconciliation_contract=$destination_reconciliation_contract"
[ "$destination_reconciliation_contract" = "true|true|true|true|true|true" ] || {
  echo "Expected destination retries, acknowledgements, replay, conflict, and missing-state reconciliation, got $destination_reconciliation_contract" >&2
  exit 1
}

rm -rf -- "$destination_tmp"
