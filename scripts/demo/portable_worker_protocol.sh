portable_protocol_task="portable_protocol_demo"
portable_deadline_task="portable_deadline_demo"
portable_runtime_incompatible_task="aaa_portable_runtime_incompatible"
portable_worker_role="otlet_demo_portable_worker"
portable_unauthorized_role="otlet_demo_portable_unauthorized"
portable_worker_id="portable-demo-worker"
portable_denied_count=0

cleanup_portable_protocol() {
  cleanup_task "$portable_protocol_task"
  cleanup_task "$portable_deadline_task"
  cleanup_task "$portable_runtime_incompatible_task"
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
  -v worker_id="$portable_worker_id" \
  -v model_name="$strong_model_name" <<'SQL' >/dev/null
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
  :'model_name',
  'reference-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'build', 'demo',
    'transport', 'postgres',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
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
  -v incompatible_task_name="$portable_runtime_incompatible_task" \
  -v model_name="$strong_model_name" <<'SQL'
BEGIN;
SELECT otlet.create_task(
  :'incompatible_task_name',
  NULL,
  'Return status ok and no actions',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"const":"ok"}}}'::jsonb,
  :'model_name',
  '{"reasoning":"off","max_tokens":16,"inference_cache":false,"max_worker_rss_bytes":1,"n_gpu_layers":1}'::jsonb
) \g /dev/null
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (:'incompatible_task_name', 'runtime-incompatible', '{}'::jsonb);
CREATE TEMP TABLE portable_created_task ON COMMIT DROP AS
SELECT otlet.create_task(
  :'task_name',
  NULL,
  'Return status ok and no actions',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"const":"ok"}}}'::jsonb,
  :'model_name',
  '{"reasoning":"off","max_tokens":16,"inference_cache":false,"llama_threads":0}'::jsonb,
  '{"source_fields":["allowed","secret"],"strip_keys":["secret"]}'::jsonb
);
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES
  (:'task_name', 'complete', '{"allowed":"complete","secret":"hidden"}'::jsonb),
  (:'task_name', 'fail', '{"allowed":"fail","secret":"hidden"}'::jsonb),
  (:'task_name', 'cancel', '{"allowed":"cancel","secret":"hidden"}'::jsonb);
SELECT otlet.set_portable_worker_control(:'worker_id', 'paused') \g /dev/null
SELECT
  pg_catalog.set_config('otlet.demo_portable_identity_hash', :'identity_hash', true) AS configured_identity,
  pg_catalog.set_config('otlet.demo_portable_worker_id', :'worker_id', true) AS configured_worker
\gset

SET LOCAL ROLE :worker_role;
SELECT 'portable_pause_contract=' || desired_state
FROM otlet.portable_worker_heartbeat(
  pg_catalog.current_setting('otlet.demo_portable_worker_id'),
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  NULL,
  'paused',
  'ready'
);
RESET ROLE;
SELECT 'portable_prestart_read_contract=' || reported_state || '|' ||
       model_status || '|' || (incarnation_nonce_hash IS NULL)::text
FROM otlet.portable_worker_status
WHERE worker_id = :'worker_id';
SELECT otlet.set_portable_worker_control(:'worker_id', 'running') \g /dev/null

SET LOCAL ROLE :worker_role;
SELECT
  incarnation_nonce AS portable_incarnation_a,
  desired_state AS portable_start_desired_state,
  registered_model_name AS portable_start_model_name
FROM otlet.portable_start_worker(
  pg_catalog.current_setting('otlet.demo_portable_worker_id'),
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash')
) \gset
SELECT pg_catalog.set_config(
  'otlet.demo_portable_incarnation_nonce',
  :'portable_incarnation_a',
  true
) \g /dev/null
SELECT 'portable_start_contract=' || :'portable_start_desired_state' || '|' ||
       (:'portable_start_model_name' = :'model_name')::text;
SELECT 'portable_resume_contract=' || desired_state
FROM otlet.portable_worker_heartbeat(
  pg_catalog.current_setting('otlet.demo_portable_worker_id'),
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce'),
  'idle',
  'ready'
);
DO $body$
BEGIN
  BEGIN
    PERFORM * FROM otlet.portable_claim_jobs(
      pg_catalog.current_setting('otlet.demo_portable_worker_id'),
      2,
      pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
      pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce'),
      1048576,
      6
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
      repeat('0', 64),
      pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce'),
      1048576,
      6
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
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce'),
  1048576,
  6
);
RESET ROLE;

CREATE TEMP TABLE portable_incompatible_baseline ON COMMIT DROP AS
SELECT
  job.id AS job_id,
  job.status AS job_status,
  job.attempts,
  (SELECT count(*) FROM otlet.portable_claims claim WHERE claim.job_id = job.id) AS claims,
  (SELECT count(*) FROM otlet.inference_receipts receipt WHERE receipt.job_id = job.id) AS receipts,
  otlet.portable_runtime_option_status(
    revision.definition,
    revision.definition #> '{models,direct}',
    jsonb_build_object(
      'runtime_contract', worker.runtime_identity -> 'runtime_contract',
      'model_artifact_hash', worker.model_artifact_hash,
      'model_artifact_bytes', worker.model_artifact_bytes,
      'current_rss_bytes', 1048576,
      'default_llama_threads', 6
    )
  ) AS option_status
FROM otlet.jobs job
JOIN otlet.workload_revisions revision
  ON revision.workload_revision_hash = job.workload_revision_hash
JOIN otlet.portable_workers worker ON worker.worker_id = :'worker_id'
WHERE job.task_name = :'incompatible_task_name'
  AND job.subject_id = 'runtime-incompatible';
DO $body$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM portable_incompatible_baseline incompatible
    WHERE incompatible.job_status = 'queued'
      AND incompatible.attempts = 0
      AND incompatible.claims = 0
      AND incompatible.receipts = 0
      AND incompatible.option_status #>> '{compatible}' = 'false'
      AND incompatible.option_status #>> '{rejected,max_worker_rss_bytes}' =
        'current_rss_exceeds_max_worker_rss_bytes'
      AND incompatible.option_status #>> '{rejected,n_gpu_layers}' =
        'unsupported_runtime_option'
  ) THEN
    RAISE EXCEPTION 'portable runtime option fence is incomplete';
  END IF;
END
$body$;
SELECT 'portable_runtime_option_fence_contract=' || job_status || '|' ||
       attempts || '|' || claims || '|' || receipts || '|' ||
       (option_status #>> '{compatible}') || '|' ||
       (option_status #>> '{rejected,max_worker_rss_bytes}') || '|' ||
       (option_status #>> '{rejected,n_gpu_layers}')
FROM portable_incompatible_baseline;
DELETE FROM otlet.jobs
WHERE id = (SELECT job_id FROM portable_incompatible_baseline);
SET LOCAL ROLE :worker_role;

SELECT 'portable_snapshot_contract=' || count(*)::text || '|' ||
       bool_and(input_snapshot ? 'allowed')::text || '|' ||
       bool_and(NOT (input_snapshot ? 'secret'))::text || '|' ||
       bool_and(octet_length(input_snapshot::text) <= (evidence_limits ->> 'max_input_bytes')::bigint)::text || '|' ||
       bool_and(model ->> 'name' = :'model_name')::text
FROM portable_demo_claims;

SELECT 'portable_renew_contract=' || job_status || '|' || (leased_until > now())::text
FROM otlet.portable_renew_job(
  :'worker_id',
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce'),
  (SELECT job_id FROM portable_demo_claims WHERE subject_id = 'complete'),
  (SELECT claim_token FROM portable_demo_claims WHERE subject_id = 'complete')
);

SELECT 'portable_attempt_contract=' || receipt_status || '|' || schema_status
FROM otlet.portable_record_attempt(
  :'worker_id',
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce'),
  (SELECT job_id FROM portable_demo_claims WHERE subject_id = 'complete'),
  (SELECT claim_token FROM portable_demo_claims WHERE subject_id = 'complete'),
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
  pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce'),
  (SELECT job_id FROM portable_demo_claims WHERE subject_id = 'complete'),
  (SELECT claim_token FROM portable_demo_claims WHERE subject_id = 'complete'),
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[]}',
  '[]'::jsonb,
  trace_summary => '{"schema_validation_status":"failed"}'::jsonb
);

SELECT 'portable_duplicate_delivery_contract=' || job_status || '|' ||
       (receipt_id IS NOT NULL)::text || '|' || (output_id IS NOT NULL)::text
FROM otlet.portable_complete_job(
  :'worker_id',
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce'),
  (SELECT job_id FROM portable_demo_claims WHERE subject_id = 'complete'),
  (SELECT claim_token FROM portable_demo_claims WHERE subject_id = 'complete'),
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[]}',
  '[]'::jsonb,
  trace_summary => '{"schema_validation_status":"failed"}'::jsonb
);

SELECT 'portable_fail_contract=' || job_status || '|' || (receipt_id IS NOT NULL)::text
FROM otlet.portable_fail_job(
  :'worker_id',
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce'),
  (SELECT job_id FROM portable_demo_claims WHERE subject_id = 'fail'),
  (SELECT claim_token FROM portable_demo_claims WHERE subject_id = 'fail'),
  'portable worker failure',
  schema_validation_status => 'not_run'
);

SELECT 'portable_cancel_contract=' || job_status || '|' || (receipt_id IS NOT NULL)::text
FROM otlet.portable_cancel_job(
  :'worker_id',
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce'),
  (SELECT job_id FROM portable_demo_claims WHERE subject_id = 'cancel'),
  (SELECT claim_token FROM portable_demo_claims WHERE subject_id = 'cancel'),
  'portable cancellation'
);
RESET ROLE;
DO $body$
BEGIN
  IF (
    SELECT bool_and(
      delivered.runtime_options @> '{"llama_threads":6,"llama_batch_threads":6}'::jsonb
      AND claim.runtime_options_status #> '{requested,llama_threads}' = '0'::jsonb
      AND NOT (claim.runtime_options_status -> 'requested' ? 'llama_batch_threads')
      AND claim.runtime_options_status #> '{honored,llama_threads}' = '6'::jsonb
      AND claim.runtime_options_status #> '{defaulted,llama_batch_threads}' = '6'::jsonb
      AND claim.runtime_options_status -> 'effective' @>
        '{"llama_threads":6,"llama_batch_threads":6}'::jsonb
    )
    FROM portable_demo_claims delivered
    JOIN otlet.portable_claims claim ON claim.job_id = delivered.job_id
  ) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'portable claim did not normalize default thread settings';
  END IF;
END
$body$;

INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (:'task_name', 'fenced', '{"allowed":"fenced","secret":"hidden"}'::jsonb);
SET LOCAL ROLE :worker_role;
CREATE TEMP TABLE portable_fence_claim_a ON COMMIT DROP AS
SELECT *
FROM otlet.portable_claim_jobs(
  pg_catalog.current_setting('otlet.demo_portable_worker_id'),
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce'),
  1048576,
  6,
  1
);
SELECT incarnation_nonce AS portable_incarnation_b
FROM otlet.portable_start_worker(
  pg_catalog.current_setting('otlet.demo_portable_worker_id'),
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash')
) \gset
SELECT pg_catalog.set_config(
  'otlet.demo_portable_incarnation_b',
  :'portable_incarnation_b',
  true
) \g /dev/null
RESET ROLE;

CREATE TEMP TABLE portable_fence_baseline ON COMMIT DROP AS
SELECT
  job.status AS job_status,
  job.attempts,
  job.leased_until,
  job.error,
  claim.status AS claim_status,
  worker.incarnation_nonce_hash,
  worker.reported_state,
  worker.last_seen_at,
  worker.updated_at,
  (SELECT count(*) FROM otlet.inference_receipts receipt WHERE receipt.job_id = job.id) AS receipts,
  (SELECT count(*) FROM otlet.outputs output WHERE output.job_id = job.id) AS outputs
FROM portable_fence_claim_a fence
JOIN otlet.jobs job ON job.id = fence.job_id
JOIN otlet.portable_claims claim
  ON claim.job_id = fence.job_id
 AND claim.incarnation_nonce_hash = otlet.portable_text_hash(
   pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce')
 )
JOIN otlet.portable_workers worker
  ON worker.worker_id = pg_catalog.current_setting('otlet.demo_portable_worker_id');

SET LOCAL ROLE :worker_role;
DO $body$
DECLARE
  rejected integer := 0;
  fence_job_id bigint := (SELECT job_id FROM portable_fence_claim_a);
  fence_claim_token text := (SELECT claim_token FROM portable_fence_claim_a);
  worker_id text := pg_catalog.current_setting('otlet.demo_portable_worker_id');
  runtime_hash text := pg_catalog.current_setting('otlet.demo_portable_identity_hash');
  old_nonce text := pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce');
BEGIN
  BEGIN
    PERFORM * FROM otlet.portable_worker_heartbeat(
      worker_id, 1, runtime_hash, old_nonce, 'idle', 'ready'
    );
    RAISE EXCEPTION 'stale portable heartbeat was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%worker incarnation is not authorized%' THEN RAISE; END IF;
    rejected := rejected + 1;
  END;
  BEGIN
    PERFORM * FROM otlet.portable_claim_jobs(
      worker_id, 1, runtime_hash, old_nonce, 1048576, 6, 1
    );
    RAISE EXCEPTION 'stale portable claim was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%worker incarnation is not authorized%' THEN RAISE; END IF;
    rejected := rejected + 1;
  END;
  BEGIN
    PERFORM * FROM otlet.portable_renew_job(
      worker_id, 1, runtime_hash, old_nonce, fence_job_id, fence_claim_token
    );
    RAISE EXCEPTION 'stale portable renewal was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%worker incarnation is not authorized%' THEN RAISE; END IF;
    rejected := rejected + 1;
  END;
  BEGIN
    PERFORM * FROM otlet.portable_record_attempt(
      worker_id, 1, runtime_hash, old_nonce, fence_job_id, fence_claim_token,
      'failed', error => 'stale attempt'
    );
    RAISE EXCEPTION 'stale portable attempt was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%worker incarnation is not authorized%' THEN RAISE; END IF;
    rejected := rejected + 1;
  END;
  BEGIN
    PERFORM * FROM otlet.portable_complete_job(
      worker_id, 1, runtime_hash, old_nonce, fence_job_id, fence_claim_token,
      '{"status":"ok"}'::jsonb,
      '{"output":{"status":"ok"},"actions":[]}',
      '[]'::jsonb
    );
    RAISE EXCEPTION 'stale portable completion was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%worker incarnation is not authorized%' THEN RAISE; END IF;
    rejected := rejected + 1;
  END;
  BEGIN
    PERFORM * FROM otlet.portable_fail_job(
      worker_id, 1, runtime_hash, old_nonce, fence_job_id, fence_claim_token,
      'stale failure'
    );
    RAISE EXCEPTION 'stale portable failure was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%worker incarnation is not authorized%' THEN RAISE; END IF;
    rejected := rejected + 1;
  END;
  BEGIN
    PERFORM * FROM otlet.portable_cancel_job(
      worker_id, 1, runtime_hash, old_nonce, fence_job_id, fence_claim_token,
      'stale cancellation'
    );
    RAISE EXCEPTION 'stale portable cancellation was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%worker incarnation is not authorized%' THEN RAISE; END IF;
    rejected := rejected + 1;
  END;
  IF rejected <> 7 THEN
    RAISE EXCEPTION 'portable incarnation fence rejected % RPCs instead of 7', rejected;
  END IF;
END
$body$;
RESET ROLE;

DO $body$
BEGIN
  IF (SELECT count(*) FROM portable_fence_baseline) <> 1
     OR NOT EXISTS (
       SELECT 1
       FROM portable_fence_baseline baseline
       WHERE baseline.job_status = 'running'
         AND baseline.attempts = 1
         AND baseline.claim_status = 'replaced'
         AND baseline.incarnation_nonce_hash = otlet.portable_text_hash(
           pg_catalog.current_setting('otlet.demo_portable_incarnation_b')
         )
         AND baseline.reported_state = 'starting'
         AND baseline.receipts = 0
         AND baseline.outputs = 0
     )
     OR EXISTS (
    SELECT 1
    FROM portable_fence_baseline baseline
    JOIN portable_fence_claim_a fence ON true
    JOIN otlet.jobs job ON job.id = fence.job_id
    JOIN otlet.portable_claims claim
      ON claim.job_id = fence.job_id
     AND claim.incarnation_nonce_hash = otlet.portable_text_hash(
       pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce')
     )
    JOIN otlet.portable_workers worker
      ON worker.worker_id = pg_catalog.current_setting('otlet.demo_portable_worker_id')
    WHERE ROW(
      job.status,
      job.attempts,
      job.leased_until,
      job.error,
      claim.status,
      worker.incarnation_nonce_hash,
      worker.reported_state,
      worker.last_seen_at,
      worker.updated_at,
      (SELECT count(*) FROM otlet.inference_receipts receipt WHERE receipt.job_id = job.id),
      (SELECT count(*) FROM otlet.outputs output WHERE output.job_id = job.id)
    ) IS DISTINCT FROM ROW(
      baseline.job_status,
      baseline.attempts,
      baseline.leased_until,
      baseline.error,
      baseline.claim_status,
      baseline.incarnation_nonce_hash,
      baseline.reported_state,
      baseline.last_seen_at,
      baseline.updated_at,
      baseline.receipts,
      baseline.outputs
    )
  ) THEN
    RAISE EXCEPTION 'stale portable RPCs changed fenced state';
  END IF;
END
$body$;

SET LOCAL ROLE :worker_role;
DO $body$
BEGIN
  BEGIN
    PERFORM * FROM otlet.portable_renew_job(
      pg_catalog.current_setting('otlet.demo_portable_worker_id'),
      1,
      pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
      pg_catalog.current_setting('otlet.demo_portable_incarnation_b'),
      (SELECT job_id FROM portable_fence_claim_a),
      (SELECT claim_token FROM portable_fence_claim_a)
    );
    RAISE EXCEPTION 'replacement portable worker renewed the prior incarnation claim';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%job claim is stale%' THEN RAISE; END IF;
  END;
END
$body$;
RESET ROLE;

UPDATE otlet.jobs job
SET leased_until = clock_timestamp() - interval '1 second'
WHERE job.id = (SELECT job_id FROM portable_fence_claim_a);
SET LOCAL ROLE :worker_role;
CREATE TEMP TABLE portable_fence_claim_b ON COMMIT DROP AS
SELECT *
FROM otlet.portable_claim_jobs(
  pg_catalog.current_setting('otlet.demo_portable_worker_id'),
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  pg_catalog.current_setting('otlet.demo_portable_incarnation_b'),
  1048576,
  6,
  1
);
CREATE TEMP TABLE portable_fence_result_b ON COMMIT DROP AS
SELECT *
FROM otlet.portable_complete_job(
  pg_catalog.current_setting('otlet.demo_portable_worker_id'),
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  pg_catalog.current_setting('otlet.demo_portable_incarnation_b'),
  (SELECT job_id FROM portable_fence_claim_b),
  (SELECT claim_token FROM portable_fence_claim_b),
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[]}',
  '[]'::jsonb
);
RESET ROLE;

DO $body$
DECLARE
  exposed_status text;
BEGIN
  SELECT
    COALESCE((
      SELECT string_agg(to_jsonb(status)::text, '')
      FROM otlet.portable_worker_status status
      WHERE status.worker_id = pg_catalog.current_setting('otlet.demo_portable_worker_id')
    ), '') ||
    COALESCE((
      SELECT string_agg(to_jsonb(status)::text, '')
      FROM otlet.portable_claim_status status
      WHERE status.job_id = (SELECT job_id FROM portable_fence_claim_b)
    ), '') ||
    COALESCE((
      SELECT string_agg(to_jsonb(status)::text, '')
      FROM otlet.portable_receipt_status status
      WHERE status.job_id = (SELECT job_id FROM portable_fence_claim_b)
    ), '')
  INTO exposed_status;

  IF NOT EXISTS (
    SELECT 1
    FROM portable_fence_claim_a old_claim
    CROSS JOIN portable_fence_claim_b new_claim
    JOIN otlet.portable_workers worker
      ON worker.worker_id = pg_catalog.current_setting('otlet.demo_portable_worker_id')
    JOIN otlet.portable_claims stored_claim ON stored_claim.job_id = new_claim.job_id
      AND stored_claim.incarnation_nonce_hash = otlet.portable_text_hash(
        pg_catalog.current_setting('otlet.demo_portable_incarnation_b')
      )
    JOIN otlet.portable_claims prior_claim ON prior_claim.job_id = old_claim.job_id
      AND prior_claim.incarnation_nonce_hash = otlet.portable_text_hash(
        pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce')
      )
    JOIN otlet.portable_receipt_status receipt ON receipt.claim_id = stored_claim.id
    WHERE old_claim.attempt_index = 1
      AND new_claim.attempt_index = 2
      AND worker.incarnation_nonce_hash = otlet.portable_text_hash(
        pg_catalog.current_setting('otlet.demo_portable_incarnation_b')
      )
      AND prior_claim.status = 'replaced'
      AND stored_claim.status = 'complete'
      AND receipt.incarnation_nonce_hash = stored_claim.incarnation_nonce_hash
      AND receipt.receipt_incarnation_nonce_hash = stored_claim.incarnation_nonce_hash
      AND octet_length(stored_claim.incarnation_nonce_hash) = 64
      AND (SELECT job_status FROM portable_fence_result_b) = 'complete'
  ) THEN
    RAISE EXCEPTION 'replacement portable worker provenance is incomplete';
  END IF;
  IF exposed_status LIKE '%' || pg_catalog.current_setting('otlet.demo_portable_incarnation_nonce') || '%'
     OR exposed_status LIKE '%' || pg_catalog.current_setting('otlet.demo_portable_incarnation_b') || '%' THEN
    RAISE EXCEPTION 'portable status exposed a raw incarnation nonce';
  END IF;
END
$body$;
SELECT 'portable_incarnation_fence_contract=7|replaced|2|complete|hash_only';

DELETE FROM otlet.worker_events
WHERE job_id = (SELECT job_id FROM portable_fence_claim_b);
DELETE FROM otlet.outputs
WHERE job_id = (SELECT job_id FROM portable_fence_claim_b);
DELETE FROM otlet.inference_receipts
WHERE job_id = (SELECT job_id FROM portable_fence_claim_b);
DELETE FROM otlet.jobs
WHERE id = (SELECT job_id FROM portable_fence_claim_b);
SELECT otlet.register_portable_worker(
  :'worker_id',
  :'worker_role'::regrole,
  1,
  :'model_name',
  'reference-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'build', 'demo',
    'transport', 'postgres',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null
SET LOCAL ROLE :worker_role;
DO $body$
BEGIN
  BEGIN
    PERFORM * FROM otlet.portable_worker_heartbeat(
      pg_catalog.current_setting('otlet.demo_portable_worker_id'),
      1,
      pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
      pg_catalog.current_setting('otlet.demo_portable_incarnation_b'),
      'idle',
      'ready'
    );
    RAISE EXCEPTION 're-registration did not fence the portable worker';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%worker incarnation is not authorized%' THEN RAISE; END IF;
  END;
END
$body$;
RESET ROLE;
DO $body$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.portable_worker_status worker
    WHERE worker.worker_id = pg_catalog.current_setting('otlet.demo_portable_worker_id')
      AND worker.incarnation_nonce_hash IS NULL
      AND worker.reported_state = 'registered'
  ) OR EXISTS (SELECT 1 FROM otlet.verify_invariants()) THEN
    RAISE EXCEPTION 'portable re-registration fence is incomplete';
  END IF;
END
$body$;
SELECT 'portable_reregistration_fence_contract=' ||
       (incarnation_nonce_hash IS NULL)::text || '|' || reported_state || '|' ||
       (SELECT count(*) FROM otlet.verify_invariants())::text
FROM otlet.portable_worker_status
WHERE worker_id = :'worker_id';
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
  "SELECT * FROM otlet.portable_claim_jobs('$portable_worker_id', 1, '$portable_identity_hash', '00000000-0000-0000-0000-000000000000', 1048576, 6)" \
  "unauthorized portable claim"

portable_protocol_contract_query() {
  psql_value \
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
      'portable_start_worker', 'portable_claim_jobs', 'portable_renew_job',
      'portable_record_attempt',
      'portable_complete_job', 'portable_fail_job', 'portable_cancel_job',
      'portable_worker_heartbeat'
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
}
portable_protocol_contract="$(portable_protocol_contract_query)"
echo "portable_protocol_contract=$portable_protocol_contract"
expected_portable_protocol_contract="1|active|true|true|3|0|cancel:canceled:canceled,complete:complete:complete,fail:failed:failed|4|true|true|1|1|1|1|8|8|8|1|8|false|false"
[ "$portable_protocol_contract" = "$expected_portable_protocol_contract" ] || {
  echo "Unexpected portable protocol contract: $portable_protocol_contract" >&2
  exit 1
}
[ "$portable_denied_count" = "5" ] || {
  echo "Expected five portable permission denials, got $portable_denied_count" >&2
  exit 1
}

psql_exec -qAt \
  -v worker_role="$portable_worker_role" \
  -v worker_id="$portable_worker_id" \
  -v identity_hash="$portable_identity_hash" \
  -v task_name="$portable_protocol_task" \
  -v model_name="$strong_model_name" <<'SQL'
BEGIN;
SELECT pg_catalog.set_config('otlet.demo_portable_worker_id', :'worker_id', true) \g /dev/null
SELECT pg_catalog.set_config('otlet.demo_portable_identity_hash', :'identity_hash', true) \g /dev/null
SET LOCAL ROLE :worker_role;
SELECT incarnation_nonce AS reregister_incarnation_nonce
FROM otlet.portable_start_worker(:'worker_id', 1, :'identity_hash') \gset
SELECT pg_catalog.set_config(
  'otlet.demo_portable_reregister_incarnation',
  :'reregister_incarnation_nonce',
  true
) \g /dev/null
RESET ROLE;

INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (:'task_name', 'portable-reregistration-fence', '{}'::jsonb);
SET LOCAL ROLE :worker_role;
CREATE TEMP TABLE portable_reregister_claim ON COMMIT DROP AS
SELECT *
FROM otlet.portable_claim_jobs(
  pg_catalog.current_setting('otlet.demo_portable_worker_id'),
  1,
  pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
  pg_catalog.current_setting('otlet.demo_portable_reregister_incarnation'),
  1048576,
  6,
  1
);
RESET ROLE;
CREATE TEMP TABLE portable_reregister_baseline ON COMMIT DROP AS
SELECT
  job.id AS job_id,
  job.status AS job_status,
  job.attempts,
  job.leased_until,
  job.claim_token,
  job.error,
  claim.id AS claim_id,
  claim.status AS claim_status,
  claim.incarnation_nonce_hash
FROM portable_reregister_claim requested_claim
JOIN otlet.jobs job ON job.id = requested_claim.job_id
  AND job.subject_id = 'portable-reregistration-fence'
JOIN otlet.portable_claims claim
  ON claim.job_id = requested_claim.job_id
 AND claim.incarnation_nonce_hash = otlet.portable_text_hash(
   pg_catalog.current_setting('otlet.demo_portable_reregister_incarnation')
 );

SELECT otlet.register_portable_worker(
  :'worker_id',
  :'worker_role'::regrole,
  1,
  :'model_name',
  'reference-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'build', 'demo',
    'transport', 'postgres',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null
SET LOCAL ROLE :worker_role;
DO $body$
BEGIN
  BEGIN
    PERFORM * FROM otlet.portable_worker_heartbeat(
      pg_catalog.current_setting('otlet.demo_portable_worker_id'),
      1,
      pg_catalog.current_setting('otlet.demo_portable_identity_hash'),
      pg_catalog.current_setting('otlet.demo_portable_reregister_incarnation'),
      'idle',
      'ready'
    );
    RAISE EXCEPTION 're-registration accepted the prior live incarnation';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%worker incarnation is not authorized%' THEN RAISE; END IF;
  END;
END
$body$;
RESET ROLE;
DO $body$
BEGIN
  IF (SELECT count(*) FROM portable_reregister_baseline) <> 1
     OR NOT EXISTS (
       SELECT 1
       FROM portable_reregister_baseline baseline
       JOIN otlet.jobs job ON job.id = baseline.job_id
       JOIN otlet.portable_claims claim ON claim.id = baseline.claim_id
       JOIN otlet.portable_worker_status worker
         ON worker.worker_id = pg_catalog.current_setting('otlet.demo_portable_worker_id')
       WHERE baseline.claim_status = 'claimed'
         AND worker.incarnation_nonce_hash IS NULL
         AND worker.reported_state = 'registered'
         AND claim.status = 'replaced'
         AND claim.finished_at IS NOT NULL
         AND ROW(
           job.status,
           job.attempts,
           job.leased_until,
           job.claim_token,
           job.error
         ) IS NOT DISTINCT FROM ROW(
           baseline.job_status,
           baseline.attempts,
           baseline.leased_until,
           baseline.claim_token,
           baseline.error
         )
     )
     OR EXISTS (SELECT 1 FROM otlet.verify_invariants()) THEN
    RAISE EXCEPTION 'portable live-claim re-registration fence is incomplete';
  END IF;
END
$body$;
SELECT 'portable_reregistration_live_claim_contract=' || claim.status || '|' ||
       (ROW(
          job.status,
          job.attempts,
          job.leased_until,
          job.claim_token,
          job.error
        ) IS NOT DISTINCT FROM ROW(
          baseline.job_status,
          baseline.attempts,
          baseline.leased_until,
          baseline.claim_token,
          baseline.error
        ))::text || '|' ||
       (SELECT count(*) FROM otlet.verify_invariants())::text
FROM portable_reregister_baseline baseline
JOIN otlet.jobs job ON job.id = baseline.job_id
JOIN otlet.portable_claims claim ON claim.id = baseline.claim_id;
DELETE FROM otlet.worker_events
WHERE job_id = (SELECT job_id FROM portable_reregister_baseline);
DELETE FROM otlet.jobs
WHERE id = (SELECT job_id FROM portable_reregister_baseline);
COMMIT;
SQL

portable_deadline_contract="$(psql_value \
  -v worker_role="$portable_worker_role" \
  -v worker_id="$portable_worker_id" \
  -v identity_hash="$portable_identity_hash" \
  -v task_name="$portable_deadline_task" \
  -v model_name="$strong_model_name" <<'SQL'
BEGIN;
SELECT otlet.create_task(
  :'task_name',
  NULL,
  'Return status ok and no actions',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"const":"ok"}}}'::jsonb,
  :'model_name',
  '{"reasoning":"off","max_tokens":16,"max_attempt_ms":1000,"inference_cache":false}'::jsonb
) \g /dev/null
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (:'task_name', 'deadline', '{}'::jsonb);

SET LOCAL ROLE :worker_role;
SELECT incarnation_nonce AS portable_deadline_incarnation_nonce
FROM otlet.portable_start_worker(:'worker_id', 1, :'identity_hash') \gset
SELECT pg_catalog.set_config(
  'otlet.demo_portable_deadline_incarnation_nonce',
  :'portable_deadline_incarnation_nonce',
  true
) \g /dev/null
CREATE TEMP TABLE portable_deadline_claim ON COMMIT DROP AS
SELECT *
FROM otlet.portable_claim_jobs(
  :'worker_id',
  1,
  :'identity_hash',
  pg_catalog.current_setting('otlet.demo_portable_deadline_incarnation_nonce'),
  1048576,
  6,
  1
);
SELECT *
FROM otlet.portable_renew_job(
  :'worker_id',
  1,
  :'identity_hash',
  pg_catalog.current_setting('otlet.demo_portable_deadline_incarnation_nonce'),
  (SELECT job_id FROM portable_deadline_claim),
  (SELECT claim_token FROM portable_deadline_claim)
) \g /dev/null
RESET ROLE;

CREATE TEMP TABLE portable_deadline_renewal_baseline ON COMMIT DROP AS
SELECT job.leased_until
FROM otlet.jobs job
WHERE job.id = (SELECT job_id FROM portable_deadline_claim);
SELECT
  pg_catalog.set_config('otlet.demo_portable_deadline_worker_id', :'worker_id', true),
  pg_catalog.set_config('otlet.demo_portable_deadline_identity_hash', :'identity_hash', true),
  pg_catalog.set_config(
    'otlet.demo_portable_deadline_job_id',
    (SELECT job_id::text FROM portable_deadline_claim),
    true
  )
\g /dev/null
CREATE TEMP SEQUENCE portable_deadline_trigger_calls;
GRANT USAGE, SELECT ON SEQUENCE portable_deadline_trigger_calls TO :worker_role;
CREATE FUNCTION public.portable_deadline_renew_delay()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.id = pg_catalog.current_setting('otlet.demo_portable_deadline_job_id')::bigint THEN
    PERFORM pg_catalog.nextval('pg_temp.portable_deadline_trigger_calls'::regclass);
    PERFORM pg_sleep(1);
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER portable_deadline_renew_delay
AFTER UPDATE OF leased_until ON otlet.jobs
FOR EACH ROW
EXECUTE FUNCTION public.portable_deadline_renew_delay();
UPDATE otlet.portable_claims claim
SET claimed_at = clock_timestamp() - interval '200 milliseconds'
WHERE claim.job_id = (SELECT job_id FROM portable_deadline_claim);

SET LOCAL ROLE :worker_role;
DO $body$
BEGIN
  BEGIN
    PERFORM *
    FROM otlet.portable_renew_job(
      pg_catalog.current_setting('otlet.demo_portable_deadline_worker_id'),
      1,
      pg_catalog.current_setting('otlet.demo_portable_deadline_identity_hash'),
      pg_catalog.current_setting('otlet.demo_portable_deadline_incarnation_nonce'),
      (SELECT job_id FROM portable_deadline_claim),
      (SELECT claim_token FROM portable_deadline_claim)
    );
    RAISE EXCEPTION 'expired portable attempt renewed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%portable attempt deadline expired%' THEN
      RAISE;
    END IF;
  END;
END
$body$;
RESET ROLE;
CREATE TEMP TABLE portable_deadline_lease_check ON COMMIT DROP AS
SELECT job.leased_until = baseline.leased_until AS lease_unchanged
FROM otlet.jobs job
JOIN portable_deadline_claim claim ON claim.job_id = job.id
CROSS JOIN portable_deadline_renewal_baseline baseline;
DROP TRIGGER portable_deadline_renew_delay ON otlet.jobs;
DROP FUNCTION public.portable_deadline_renew_delay();

SET LOCAL ROLE :worker_role;
SELECT *
FROM otlet.portable_fail_job(
  :'worker_id',
  1,
  :'identity_hash',
  pg_catalog.current_setting('otlet.demo_portable_deadline_incarnation_nonce'),
  (SELECT job_id FROM portable_deadline_claim),
  (SELECT claim_token FROM portable_deadline_claim),
  'attempt_timeout',
  prompt_hash => (SELECT prompt_hash FROM portable_deadline_claim),
  schema_validation_status => 'failed',
  trace_summary => '{"trace_version":"otlet_portable_worker_trace_v1","schema_validation_status":"failed","schema_force":"attempt_timeout_before_schema_validation","stop_reason":"attempt_timeout"}'::jsonb,
  selection_reason => 'attempt_timeout'
) \g /dev/null
RESET ROLE;

SELECT concat_ws('|',
  claim.evidence_limits ->> 'max_attempt_ms',
  (portable_claim.last_renewed_at IS NOT NULL)::text,
  (SELECT lease_unchanged::text FROM portable_deadline_lease_check),
  (SELECT is_called::text FROM portable_deadline_trigger_calls),
  job.status,
  job.error,
  receipt.selection_reason,
  receipt.trace_summary ->> 'stop_reason',
  receipt.schema_validation_status,
  portable_claim.status,
  (SELECT count(*) FROM otlet.inference_receipts r WHERE r.job_id = job.id),
  (SELECT count(*) FROM otlet.outputs output WHERE output.job_id = job.id),
  (status.attempt_deadline_at <= clock_timestamp())::text
)
FROM portable_deadline_claim claim
JOIN otlet.jobs job ON job.id = claim.job_id
JOIN otlet.portable_claims portable_claim ON portable_claim.job_id = job.id
JOIN otlet.portable_claim_status status ON status.claim_id = portable_claim.id
JOIN otlet.inference_receipts receipt ON receipt.job_id = job.id;
ROLLBACK;
SQL
)"
expected_portable_deadline_contract="1000|true|true|true|failed|attempt_timeout|attempt_timeout|attempt_timeout|failed|failed|1|0|true"
echo "portable_deadline_contract=$portable_deadline_contract"
[ "$portable_deadline_contract" = "$expected_portable_deadline_contract" ] || {
  echo "Unexpected portable deadline contract: $portable_deadline_contract" >&2
  exit 1
}

cleanup_portable_protocol
trap - EXIT
