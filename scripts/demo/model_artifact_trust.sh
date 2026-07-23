log "Checking model artifact trust"
artifact_test_dir=/var/lib/postgresql/otlet-artifact-smoke
malformed_artifact="$artifact_test_dir/malformed.gguf"
tampered_artifact="$artifact_test_dir/tampered.gguf"
truncated_artifact="$artifact_test_dir/truncated.gguf"
parser_malformed_artifact="$artifact_test_dir/parser-malformed.gguf"
unreadable_artifact="$artifact_test_dir/unreadable.gguf"
docker exec "$container" sh -c '
  set -eu
  mkdir -p "$1"
  printf %s NOPE0123456789abcdefghij > "$2"
  printf %s GGUF0123456789abcdefghij > "$3"
  printf %s GGUF0123 > "$4"
  printf %s GGUF0123456789abcdefghij > "$5"
' sh "$artifact_test_dir" "$malformed_artifact" "$tampered_artifact" "$truncated_artifact" "$parser_malformed_artifact"
malformed_sha256="$(docker exec "$container" sha256sum "$malformed_artifact" | awk '{print $1}')"
tampered_sha256="$(docker exec "$container" sha256sum "$tampered_artifact" | awk '{print $1}')"
truncated_sha256="$(docker exec "$container" sha256sum "$truncated_artifact" | awk '{print $1}')"
parser_malformed_sha256="$(docker exec "$container" sha256sum "$parser_malformed_artifact" | awk '{print $1}')"
docker exec "$container" sh -c 'printf %s GGUF0123456789abcdefghik > "$1"' sh "$tampered_artifact"

psql_exec \
  -v malformed_artifact="$malformed_artifact" \
  -v malformed_sha256="$malformed_sha256" \
  -v tampered_artifact="$tampered_artifact" \
  -v tampered_sha256="$tampered_sha256" \
  -v truncated_artifact="$truncated_artifact" \
  -v truncated_sha256="$truncated_sha256" \
  -v parser_malformed_artifact="$parser_malformed_artifact" \
  -v parser_malformed_sha256="$parser_malformed_sha256" \
  -v unreadable_artifact="$unreadable_artifact" >/dev/null <<'SQL'
SELECT otlet.register_model(
  'artifact_parser_malformed_smoke',
  :'parser_malformed_artifact',
  :'parser_malformed_sha256',
  jsonb_build_object('sha256', :'parser_malformed_sha256', 'bytes', 24, 'source', 'smoke', 'revision', 'v1', 'quantization', 'test', 'license', 'test')
);
SELECT otlet.register_model(
  'artifact_truncated_smoke',
  :'truncated_artifact',
  :'truncated_sha256',
  jsonb_build_object('sha256', :'truncated_sha256', 'bytes', 24, 'source', 'smoke', 'revision', 'v1', 'quantization', 'test', 'license', 'test')
);
SELECT otlet.register_model(
  'artifact_malformed_smoke',
  :'malformed_artifact',
  :'malformed_sha256',
  jsonb_build_object('sha256', :'malformed_sha256', 'bytes', 24, 'source', 'smoke', 'revision', 'v1', 'quantization', 'test', 'license', 'test')
);
SELECT otlet.register_model(
  'artifact_tampered_smoke',
  :'tampered_artifact',
  :'tampered_sha256',
  jsonb_build_object('sha256', :'tampered_sha256', 'bytes', 24, 'source', 'smoke', 'revision', 'v1', 'quantization', 'test', 'license', 'test')
);
SELECT otlet.register_model(
  'artifact_unreadable_smoke',
  :'unreadable_artifact',
  repeat('0', 64),
  jsonb_build_object('sha256', repeat('0', 64), 'bytes', 24, 'source', 'smoke', 'revision', 'v1', 'quantization', 'test', 'license', 'test')
);

SELECT otlet.create_task(
  'artifact_parser_malformed_smoke_task',
  'SELECT ''parser-malformed''::text AS subject_id, ''{}''::jsonb AS input',
  'Return JSON only',
  '{"type":"object"}'::jsonb,
  'artifact_parser_malformed_smoke'
);
SELECT otlet.create_task(
  'artifact_truncated_smoke_task',
  'SELECT ''truncated''::text AS subject_id, ''{}''::jsonb AS input',
  'Return JSON only',
  '{"type":"object"}'::jsonb,
  'artifact_truncated_smoke'
);
SELECT otlet.create_task(
  'artifact_malformed_smoke_task',
  'SELECT ''malformed''::text AS subject_id, ''{}''::jsonb AS input',
  'Return JSON only',
  '{"type":"object"}'::jsonb,
  'artifact_malformed_smoke'
);
SELECT otlet.create_task(
  'artifact_tampered_smoke_task',
  'SELECT ''tampered''::text AS subject_id, ''{}''::jsonb AS input',
  'Return JSON only',
  '{"type":"object"}'::jsonb,
  'artifact_tampered_smoke'
);
SELECT otlet.create_task(
  'artifact_unreadable_smoke_task',
  'SELECT ''unreadable''::text AS subject_id, ''{}''::jsonb AS input',
  'Return JSON only',
  '{"type":"object"}'::jsonb,
  'artifact_unreadable_smoke'
);
SELECT otlet.run_task('artifact_malformed_smoke_task');
SELECT otlet.run_task('artifact_tampered_smoke_task');
SELECT otlet.run_task('artifact_truncated_smoke_task');
SELECT otlet.run_task('artifact_parser_malformed_smoke_task');
SELECT otlet.run_task('artifact_unreadable_smoke_task');
SQL

wait_task_failed artifact_malformed_smoke_task 1 60 1
wait_task_failed artifact_tampered_smoke_task 1 60 1
wait_task_failed artifact_truncated_smoke_task 1 60 1
wait_task_failed artifact_parser_malformed_smoke_task 1 60 1
wait_task_failed artifact_unreadable_smoke_task 1 60 1

artifact_parser_safety_contract="$(psql_value <<'SQL'
SELECT j.status || '|' || r.status || '|' ||
       (j.error LIKE '%llama_projection_error%')::text || '|' ||
       (r.trace_summary ->> 'stop_reason') || '|' ||
       (SELECT count(*) FROM otlet.outputs o WHERE o.job_id = j.id)::text || '|' ||
       ((SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'otlet worker') > 0)::text
FROM otlet.jobs j
JOIN otlet.inference_receipts r ON r.job_id = j.id
WHERE j.task_name = 'artifact_parser_malformed_smoke_task';
SQL
)"
echo "artifact_parser_safety_contract=$artifact_parser_safety_contract"
[ "$artifact_parser_safety_contract" = "failed|failed|true|model_load_admission_rejected|0|true" ] || {
  echo "Expected parser-rejected GGUF to fail without worker loss, got $artifact_parser_safety_contract" >&2
  exit 1
}

docker exec "$container" sh -c 'printf %s GGUF0123456789abcdefghik > "$1"' sh "$parser_malformed_artifact"
psql_exec >/dev/null <<'SQL'
SELECT otlet.create_task(
  'artifact_changed_after_verify_smoke_task',
  'SELECT ''changed''::text AS subject_id, ''{}''::jsonb AS input',
  'Return JSON only',
  '{"type":"object"}'::jsonb,
  'artifact_parser_malformed_smoke'
);
SELECT otlet.run_task('artifact_changed_after_verify_smoke_task');
SQL
wait_task_failed artifact_changed_after_verify_smoke_task 1 60 1

artifact_changed_after_verify_contract="$(psql_value <<'SQL'
SELECT r.trace_summary ->> 'stop_reason'
FROM otlet.jobs j
JOIN otlet.inference_receipts r ON r.job_id = j.id
WHERE j.task_name = 'artifact_changed_after_verify_smoke_task';
SQL
)"
echo "artifact_changed_after_verify_contract=$artifact_changed_after_verify_contract"
[ "$artifact_changed_after_verify_contract" = "model_artifact_digest_mismatch" ] || {
  echo "Expected a changed verified artifact to invalidate its cached digest, got $artifact_changed_after_verify_contract" >&2
  exit 1
}

artifact_failure_contract="$(psql_value <<'SQL'
SELECT string_agg(j.task_name || '=' || (r.trace_summary ->> 'stop_reason'), '|' ORDER BY j.task_name)
FROM otlet.jobs j
JOIN otlet.inference_receipts r ON r.job_id = j.id
WHERE j.task_name IN (
  'artifact_malformed_smoke_task',
  'artifact_tampered_smoke_task',
  'artifact_truncated_smoke_task',
  'artifact_unreadable_smoke_task'
);
SQL
)"
echo "artifact_failure_contract=$artifact_failure_contract"
[ "$artifact_failure_contract" = "artifact_malformed_smoke_task=model_artifact_malformed|artifact_tampered_smoke_task=model_artifact_digest_mismatch|artifact_truncated_smoke_task=model_artifact_size_mismatch|artifact_unreadable_smoke_task=model_artifact_unreadable" ] || {
  echo "Expected model artifact failures to stay closed, got $artifact_failure_contract" >&2
  exit 1
}

artifact_identity_contract="$(psql_value -v model_name="$strong_model_name" <<'SQL'
SELECT (artifact_hash = artifact_identity ->> 'sha256')::text || '|' ||
       (jsonb_typeof(artifact_identity -> 'bytes') = 'number')::text || '|' ||
       (artifact_identity ?& ARRAY['source', 'revision', 'quantization', 'license'])::text
FROM otlet.models
WHERE name = :'model_name';
SQL
)"
echo "artifact_identity_contract=$artifact_identity_contract"
[ "$artifact_identity_contract" = "true|true|true" ] || {
  echo "Expected complete registered model identity, got $artifact_identity_contract" >&2
  exit 1
}

for task in artifact_malformed_smoke_task artifact_tampered_smoke_task artifact_truncated_smoke_task artifact_parser_malformed_smoke_task artifact_changed_after_verify_smoke_task artifact_unreadable_smoke_task; do
  cleanup_task "$task"
done
psql_exec >/dev/null <<'SQL'
DELETE FROM otlet.runtime_slots
WHERE model_name IN ('artifact_malformed_smoke', 'artifact_tampered_smoke', 'artifact_truncated_smoke', 'artifact_parser_malformed_smoke', 'artifact_unreadable_smoke');
DELETE FROM otlet.models
WHERE name IN ('artifact_malformed_smoke', 'artifact_tampered_smoke', 'artifact_truncated_smoke', 'artifact_parser_malformed_smoke', 'artifact_unreadable_smoke');
SQL
docker exec "$container" rm -rf "$artifact_test_dir"
