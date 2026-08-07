log "Checking bounded trust-boundary properties"
trust_boundary_property_contract="$(psql_exec -X -qAt \
  -v model_name="$strong_model_name" \
  < "$demo_dir/trust_boundary_properties.sql")"
expected_trust_boundary_property_contract='malformed_json=8|schema_depth=4|identifiers=8|unicode=8|claim_sequences=8|sql_dependencies=8|action_payloads=8|crash_points=4|unauthorized_state=0|raw_secret_leaks=0|partial_trusted_writes=0|backend_pid_preserved=true|invariants=0'
[ "$trust_boundary_property_contract" = "$expected_trust_boundary_property_contract" ] || {
  echo "Trust-boundary property contract mismatch: $trust_boundary_property_contract" >&2
  exit 1
}
echo "trust_boundary_property_contract=$trust_boundary_property_contract"
