portable_protocol_task="portable_protocol_demo"
portable_worker_role="otlet_demo_portable_worker"
portable_unauthorized_role="otlet_demo_portable_unauthorized"
portable_worker_id="portable-demo-worker"
portable_denied_count=0

cleanup_portable_protocol() {
  cleanup_task "$portable_protocol_task"
  psql_exec -qAt -v worker_id="$portable_worker_id" <<'SQL' >/dev/null
DELETE FROM otlet.portable_workers WHERE worker_id = :'worker_id';
DROP TABLE IF EXISTS public.otlet_demo_portable_protocol_source;
SQL
  local role
  for role in "$portable_worker_role" "$portable_unauthorized_role"; do
    if [ "$(psql_value -v role_name="$role" <<'SQL'
SELECT count(*) FROM pg_catalog.pg_roles WHERE rolname = :'role_name';
SQL
)" = "1" ]; then
      psql_exec -c "DROP OWNED BY $role" -c "DROP ROLE $role" >/dev/null
    fi
  done
}

expect_portable_denied() {
  local role="$1"
  local statement="$2"
  local label="$3"
  local output

  if output="$(psql_exec -X -c "SET ROLE $role; $statement" 2>&1)"; then
    echo "Expected $label to be denied for $role" >&2
    exit 1
  fi
  require_contains "$output" "permission denied" "Expected permission denied for $label, got $output"
  portable_denied_count=$((portable_denied_count + 1))
}

log "Checking portable worker protocol"
cleanup_portable_protocol
trap cleanup_portable_protocol EXIT

psql_exec -qAt \
  -v worker_role="$portable_worker_role" \
  -v unauthorized_role="$portable_unauthorized_role" \
  -v worker_id="$portable_worker_id" <<'SQL' >/dev/null
SELECT format(
  'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  :'worker_role'
) \gexec
SELECT format(
  'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  :'unauthorized_role'
) \gexec
SELECT otlet.grant_portable_worker_access(:'worker_role'::regrole);
SELECT otlet.grant_portable_worker_access(:'worker_role'::regrole);
SELECT otlet.register_portable_worker(
  :'worker_id',
  :'worker_role'::regrole,
  1,
  'reference-worker',
  '0.1.0',
  '{"engine":"llama.cpp","build":"demo","transport":"postgres"}'::jsonb
);
CREATE TABLE public.otlet_demo_portable_protocol_source (
  id text PRIMARY KEY,
  protected_value text NOT NULL
);
INSERT INTO public.otlet_demo_portable_protocol_source VALUES ('source-1', 'not directly readable');
SQL

portable_identity_hash="$(psql_value -v worker_id="$portable_worker_id" <<'SQL'
SELECT runtime_identity_hash
FROM otlet.portable_workers
WHERE worker_id = :'worker_id';
SQL
)"

psql_exec -qAt \
  -v worker_role="$portable_worker_role" \
  -v worker_id="$portable_worker_id" \
  -v identity_hash="$portable_identity_hash" \
  -v task_name="$portable_protocol_task" \
  -v model_name="$strong_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE portable_created_task ON COMMIT DROP AS
SELECT otlet.create_task(
  :'task_name',
  NULL,
  'Return status ok and no actions',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"const":"ok"}}}'::jsonb,
  :'model_name',
  '{"reasoning":"off","max_tokens":16,"inference_cache":false}'::jsonb,
  '{"source_fields":["allowed","secret"],"strip_keys":["secret"]}'::jsonb
);
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES
  (:'task_name', 'complete', '{"allowed":"complete","secret":"hidden"}'::jsonb),
  (:'task_name', 'fail', '{"allowed":"fail","secret":"hidden"}'::jsonb),
  (:'task_name', 'cancel', '{"allowed":"cancel","secret":"hidden"}'::jsonb);
SELECT
  pg_catalog.set_config('otlet.demo_portable_identity_hash', :'identity_hash', true) AS configured_identity,
  pg_catalog.set_config('otlet.demo_portable_worker_id', :'worker_id', true) AS configured_worker
\gset

SET LOCAL ROLE :worker_role;
DO $body$
BEGIN
  BEGIN
    PERFORM * FROM otlet.portable_claim_jobs(
      pg_catalog.current_setting('otlet.demo_portable_worker_id'),
      2,
      pg_catalog.current_setting('otlet.demo_portable_identity_hash')
    );
    RAISE EXCEPTION 'incompatible portable runtime claimed work';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%protocol version 2 is incompatible%' THEN
      RAISE;
    END IF;
  END;
END
$body$;
RESET ROLE;
SELECT 'portable_incompatible_claim_contract=' ||
       (SELECT count(*) FROM otlet.portable_claims)::text || '|' ||
       (SELECT count(*) FROM otlet.jobs WHERE task_name = :'task_name' AND status = 'queued')::text;

SET LOCAL ROLE :worker_role;
DO $body$
BEGIN
  BEGIN
    PERFORM * FROM otlet.portable_claim_jobs(
      pg_catalog.current_setting('otlet.demo_portable_worker_id'),
      1,
      repeat('0', 64)
    );
    RAISE EXCEPTION 'forged portable runtime identity claimed work';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%worker identity is not authorized%' THEN
      RAISE;
    END IF;
  END;
END
$body$;

CREATE TEMP TABLE portable_demo_claims ON COMMIT DROP AS
SELECT *
FROM otlet.portable_claim_jobs(
  :'worker_id',
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash')
);

SELECT 'portable_snapshot_contract=' || count(*)::text || '|' ||
       bool_and(input_snapshot ? 'allowed')::text || '|' ||
       bool_and(NOT (input_snapshot ? 'secret'))::text || '|' ||
       bool_and(octet_length(input_snapshot::text) <= (evidence_limits ->> 'max_input_bytes')::bigint)::text || '|' ||
       bool_and(model_policy #>> '{direct,name}' = :'model_name')::text
FROM portable_demo_claims;

SELECT 'portable_renew_contract=' || job_status || '|' || (leased_until > now())::text
FROM otlet.portable_renew_job(
  :'worker_id',
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  (SELECT job_id FROM portable_demo_claims WHERE subject_id = 'complete'),
  (SELECT claim_token FROM portable_demo_claims WHERE subject_id = 'complete')
);

SELECT 'portable_attempt_contract=' || receipt_status || '|' || schema_status
FROM otlet.portable_record_attempt(
  :'worker_id',
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  (SELECT job_id FROM portable_demo_claims WHERE subject_id = 'complete'),
  (SELECT claim_token FROM portable_demo_claims WHERE subject_id = 'complete'),
  :'model_name',
  'direct',
  'rejected',
  'portable protocol rejected attempt',
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[]}',
  trace_summary => '{"schema_validation_status":"failed"}'::jsonb,
  schema_validation_status => 'failed'
);

SELECT 'portable_complete_contract=' || job_status || '|' ||
       (receipt_id IS NOT NULL)::text || '|' || (output_id IS NOT NULL)::text
FROM otlet.portable_complete_job(
  :'worker_id',
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  (SELECT job_id FROM portable_demo_claims WHERE subject_id = 'complete'),
  (SELECT claim_token FROM portable_demo_claims WHERE subject_id = 'complete'),
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[]}',
  '[]'::jsonb,
  trace_summary => '{"schema_validation_status":"failed"}'::jsonb,
  model_name => :'model_name'
);

SELECT 'portable_fail_contract=' || job_status || '|' || (receipt_id IS NOT NULL)::text
FROM otlet.portable_fail_job(
  :'worker_id',
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  (SELECT job_id FROM portable_demo_claims WHERE subject_id = 'fail'),
  (SELECT claim_token FROM portable_demo_claims WHERE subject_id = 'fail'),
  'portable worker failure',
  schema_validation_status => 'not_run',
  model_name => :'model_name'
);

SELECT 'portable_cancel_contract=' || job_status || '|' || (receipt_id IS NOT NULL)::text
FROM otlet.portable_cancel_job(
  :'worker_id',
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  (SELECT job_id FROM portable_demo_claims WHERE subject_id = 'cancel'),
  (SELECT claim_token FROM portable_demo_claims WHERE subject_id = 'cancel'),
  'portable cancellation'
);
RESET ROLE;
COMMIT;
SQL

expect_portable_denied "$portable_worker_role" \
  "SELECT count(*) FROM otlet.jobs" "portable worker job table read"
expect_portable_denied "$portable_worker_role" \
  "SELECT count(*) FROM otlet.portable_workers" "portable worker registry read"
expect_portable_denied "$portable_worker_role" \
  "SELECT count(*) FROM public.otlet_demo_portable_protocol_source" "portable worker source read"
expect_portable_denied "$portable_unauthorized_role" \
  "SELECT count(*) FROM otlet.portable_protocol_status" "unauthorized protocol status read"
expect_portable_denied "$portable_unauthorized_role" \
  "SELECT * FROM otlet.portable_claim_jobs('$portable_worker_id', 1, '$portable_identity_hash')" \
  "unauthorized portable claim"

portable_protocol_contract="$(psql_value \
  -v worker_role="$portable_worker_role" \
  -v worker_id="$portable_worker_id" \
  -v task_name="$portable_protocol_task" <<'SQL'
WITH rpc_catalog AS (
  SELECT
    count(*) AS rpc_count,
    count(*) FILTER (WHERE p.prosecdef) AS definer_count,
    count(*) FILTER (
      WHERE p.proconfig @> ARRAY['search_path=pg_catalog, otlet, pg_temp']
    ) AS fixed_path_count
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'otlet'
    AND p.proname IN (
      'portable_claim_jobs', 'portable_renew_job', 'portable_record_attempt',
      'portable_complete_job', 'portable_fail_job', 'portable_cancel_job'
    )
), worker_grants AS (
  SELECT
    count(*) FILTER (WHERE privilege_type = 'SELECT') AS table_grants
  FROM information_schema.role_table_grants
  WHERE grantee = :'worker_role'
    AND table_schema = 'otlet'
), function_grants AS (
  SELECT count(*) AS function_grants
  FROM information_schema.routine_privileges
  WHERE grantee = :'worker_role'
    AND specific_schema = 'otlet'
), claim_state AS (
  SELECT string_agg(subject_id || ':' || claim_status || ':' || job_status, ',' ORDER BY subject_id) AS value
  FROM otlet.portable_claim_status
  WHERE task_name = :'task_name'
), receipt_state AS (
  SELECT
    count(*) AS receipts,
    bool_and(runtime_name = 'portable:reference-worker') AS portable_runtime,
    bool_and(runtime_endpoint = 'postgres_rpc') AS portable_endpoint,
    count(*) FILTER (WHERE receipt_status = 'complete' AND schema_validation_status = 'passed') AS complete_receipts,
    count(*) FILTER (WHERE receipt_status = 'rejected') AS rejected_receipts,
    count(*) FILTER (WHERE receipt_status = 'failed') AS failed_receipts,
    count(*) FILTER (WHERE receipt_status = 'canceled') AS canceled_receipts
  FROM otlet.portable_receipt_status r
  JOIN otlet.jobs j ON j.id = r.job_id
  WHERE j.task_name = :'task_name'
)
SELECT
  protocol.protocol_version || '|' || protocol.status || '|' ||
  (protocol.compatibility_rule = 'worker and database protocol versions must match exactly')::text || '|' ||
  worker.enabled::text || '|' || worker.claims || '|' || worker.live_claims || '|' ||
  claims.value || '|' ||
  receipts.receipts || '|' || receipts.portable_runtime || '|' || receipts.portable_endpoint || '|' ||
  receipts.complete_receipts || '|' || receipts.rejected_receipts || '|' ||
  receipts.failed_receipts || '|' || receipts.canceled_receipts || '|' ||
  rpc.rpc_count || '|' || rpc.definer_count || '|' || rpc.fixed_path_count || '|' ||
  grants.table_grants || '|' || functions.function_grants || '|' ||
  pg_catalog.has_table_privilege(:'worker_role', 'otlet.jobs', 'SELECT')::text || '|' ||
  pg_catalog.has_table_privilege(:'worker_role', 'public.otlet_demo_portable_protocol_source', 'SELECT')::text
FROM otlet.portable_protocol_status protocol
JOIN otlet.portable_worker_status worker ON worker.worker_id = :'worker_id'
CROSS JOIN claim_state claims
CROSS JOIN receipt_state receipts
CROSS JOIN rpc_catalog rpc
CROSS JOIN worker_grants grants
CROSS JOIN function_grants functions
WHERE protocol.protocol_version = 1;
SQL
)"
echo "portable_protocol_contract=$portable_protocol_contract"
expected_portable_protocol_contract="1|active|true|true|3|0|cancel:canceled:canceled,complete:complete:complete,fail:failed:failed|4|true|true|1|1|1|1|6|6|6|1|6|false|false"
[ "$portable_protocol_contract" = "$expected_portable_protocol_contract" ] || {
  echo "Unexpected portable protocol contract: $portable_protocol_contract" >&2
  exit 1
}
[ "$portable_denied_count" = "5" ] || {
  echo "Expected five portable permission denials, got $portable_denied_count" >&2
  exit 1
}

cleanup_portable_protocol
trap - EXIT
