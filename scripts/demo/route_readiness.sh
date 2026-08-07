log "Checking route readiness and stranded escalation"
psql_exec -qAt <<'SQL'
BEGIN;

CREATE FUNCTION pg_temp.assert_true(value boolean, message text) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF value IS DISTINCT FROM true THEN
    RAISE EXCEPTION '%', message;
  END IF;
END;
$$;

SELECT otlet.register_model(
  'route_readiness_cheap',
  '/tmp/route-readiness-cheap.gguf',
  repeat('8', 64),
  jsonb_build_object(
    'sha256', repeat('8', 64),
    'bytes', 24,
    'source', 'route-readiness-proof',
    'revision', 'cheap-v1',
    'quantization', 'test',
    'license', 'test',
    'context_window_tokens', 4096
  )
) \g /dev/null
SELECT otlet.register_model(
  'route_readiness_strong',
  '/tmp/route-readiness-strong.gguf',
  repeat('9', 64),
  jsonb_build_object(
    'sha256', repeat('9', 64),
    'bytes', 24,
    'source', 'route-readiness-proof',
    'revision', 'strong-v1',
    'quantization', 'test',
    'license', 'test',
    'context_window_tokens', 4096
  )
) \g /dev/null
SELECT otlet.create_task(
  'route_readiness_probe',
  NULL,
  'Return one decision',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"enum":["accept","reject"]}}}'::jsonb,
  'route_readiness_cheap',
  '{"reasoning":"off","max_tokens":16,"max_attempt_ms":1000,"inference_cache":false}'::jsonb
) \g /dev/null
SELECT otlet.set_model_selection_policy(
  'route_readiness_probe',
  'route_readiness_cheap',
  'route_readiness_strong',
  '{"answer_field":"decision","abstain_values":["reject"]}'::jsonb
) \g /dev/null
SELECT otlet.ensure_active_workload_revision(
  'route_readiness_probe'
) \g /dev/null

INSERT INTO otlet.runtime_slots(model_name, status, last_error)
VALUES ('route_readiness_strong', 'error', 'route readiness proof')
ON CONFLICT (model_name) DO UPDATE
SET status = EXCLUDED.status,
    last_error = EXCLUDED.last_error;

SELECT format(
  'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  role_name
)
FROM unnest(ARRAY[
  'otlet_route_readiness_cheap_worker',
  'otlet_route_readiness_strong_worker'
]) role_name \gexec
SELECT otlet.grant_portable_worker_access(
  role_name::regrole
)
FROM unnest(ARRAY[
  'otlet_route_readiness_cheap_worker',
  'otlet_route_readiness_strong_worker'
]) role_name \g /dev/null
SELECT otlet.register_portable_worker(
  'route-readiness-cheap-worker',
  'otlet_route_readiness_cheap_worker'::regrole,
  1,
  'route_readiness_cheap',
  'reference-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'build', 'route-readiness-cheap',
    'transport', 'postgres',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null
SELECT runtime_identity_hash AS cheap_identity_hash
FROM otlet.portable_workers
WHERE worker_id = 'route-readiness-cheap-worker' \gset

SET LOCAL ROLE otlet_route_readiness_cheap_worker;
SELECT incarnation_nonce AS cheap_incarnation_nonce
FROM otlet.portable_start_worker(
  'route-readiness-cheap-worker',
  1,
  :'cheap_identity_hash'
) \gset
SELECT *
FROM otlet.portable_worker_heartbeat(
  'route-readiness-cheap-worker',
  1,
  :'cheap_identity_hash',
  :'cheap_incarnation_nonce',
  'idle',
  'ready'
) \g /dev/null
RESET ROLE;

SELECT otlet.register_portable_worker(
  'route-readiness-strong-worker',
  'otlet_route_readiness_strong_worker'::regrole,
  1,
  'route_readiness_strong',
  'reference-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'build', 'route-readiness-strong',
    'transport', 'postgres',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null
SELECT runtime_identity_hash AS strong_identity_hash
FROM otlet.portable_workers
WHERE worker_id = 'route-readiness-strong-worker' \gset
SET LOCAL ROLE otlet_route_readiness_strong_worker;
SELECT incarnation_nonce AS strong_incarnation_nonce
FROM otlet.portable_start_worker(
  'route-readiness-strong-worker',
  1,
  :'strong_identity_hash'
) \gset
SELECT *
FROM otlet.portable_worker_heartbeat(
  'route-readiness-strong-worker',
  1,
  :'strong_identity_hash',
  :'strong_incarnation_nonce',
  'idle',
  'ready'
) \g /dev/null
RESET ROLE;

SELECT pg_temp.assert_true(
  count(*) = 1
    AND bool_and(portable_registered_workers = 1)
    AND bool_and(portable_compatible_workers = 0)
    AND bool_and(portable_eligible_workers = 0),
  'heartbeat-only worker fabricated portable resource compatibility'
)
FROM otlet.route_readiness_status
WHERE task_name = 'route_readiness_probe'
  AND selection_role = 'strong';

SET LOCAL ROLE otlet_route_readiness_strong_worker;
SELECT count(*) AS strong_empty_claims
FROM otlet.portable_claim_jobs(
  'route-readiness-strong-worker',
  1,
  :'strong_identity_hash',
  :'strong_incarnation_nonce',
  1048576,
  4,
  1
) \gset
RESET ROLE;
SELECT pg_temp.assert_true(
  :'strong_empty_claims'::integer = 0,
  'strong worker resource-evidence poll unexpectedly claimed work'
);
REVOKE EXECUTE ON FUNCTION otlet.portable_fail_job(
  text, integer, text, text, bigint, text, text, text, text,
  text, text, text, text, jsonb, text, text, jsonb, timestamptz
) FROM otlet_route_readiness_strong_worker;

INSERT INTO otlet.jobs(
  task_name,
  subject_id,
  input,
  created_at
)
VALUES (
  'route_readiness_probe',
  'route-readiness-subject',
  '{}'::jsonb,
  statement_timestamp() - interval '5 minutes'
);

SET LOCAL ROLE otlet_route_readiness_cheap_worker;
CREATE TEMP TABLE route_readiness_cheap_claim ON COMMIT DROP AS
SELECT *
FROM otlet.portable_claim_jobs(
  'route-readiness-cheap-worker',
  1,
  :'cheap_identity_hash',
  :'cheap_incarnation_nonce',
  1048576,
  4,
  1
);
SELECT job_id AS cheap_job_id, claim_token AS cheap_claim_token
FROM route_readiness_cheap_claim \gset
SELECT *
FROM otlet.portable_complete_job(
  'route-readiness-cheap-worker',
  1,
  :'cheap_identity_hash',
  :'cheap_incarnation_nonce',
  :'cheap_job_id'::bigint,
  :'cheap_claim_token',
  '{"decision":"reject"}'::jsonb,
  '{"output":{"decision":"reject"},"actions":[]}',
  '[]'::jsonb
) \g /dev/null
RESET ROLE;

SELECT pg_temp.assert_true(
  count(*) = 3
    AND count(*) FILTER (WHERE selection_role = 'direct') = 1
    AND count(*) FILTER (WHERE selection_role = 'cheap') = 1
    AND count(*) FILTER (WHERE selection_role = 'strong') = 1
    AND bool_and(active_revision)
    AND bool_and(queued_evaluation_jobs = 0)
    AND bool_and(queued_production_jobs = 1)
    AND bool_and(model_claim_ready AND artifact_ready)
    AND count(*) FILTER (
      WHERE selection_role IN ('direct', 'cheap')
        AND route_ready
        AND model_name = 'route_readiness_cheap'
        AND portable_eligible_workers = 1
    ) = 2
    AND count(*) FILTER (
      WHERE selection_role = 'strong'
        AND NOT route_ready
        AND model_name = 'route_readiness_strong'
        AND readiness_reason = 'native_runtime_error'
    ) = 1,
  'route readiness did not expose all configured routes'
)
FROM otlet.route_readiness_status
WHERE task_name = 'route_readiness_probe';
SELECT pg_temp.assert_true(
  count(*) = 1
    AND bool_and(escalation_reason = 'escalated_after_cheap_rejection')
    AND bool_and(stranded_reason = 'native_runtime_error')
    AND bool_and(cheap_receipt_id IS NOT NULL)
    AND bool_and(escalated_at = (
      SELECT receipt.finished_at
      FROM otlet.inference_receipts receipt
      WHERE receipt.id = stranded.cheap_receipt_id
    ))
    AND bool_and(escalation_age < interval '1 minute'),
  'queued strong fallback was not surfaced immediately with age and reason'
)
FROM otlet.stranded_escalation_status stranded
WHERE task_name = 'route_readiness_probe';

SELECT otlet.grant_portable_worker_access(
  'otlet_route_readiness_strong_worker'::regrole
) \g /dev/null

SELECT pg_temp.assert_true(
  count(*) = 1
    AND bool_and(route_ready)
    AND bool_and(portable_eligible_workers = 1)
    AND bool_and(readiness_reason = 'ready'),
  'healthy strong worker did not restore route readiness'
)
FROM otlet.route_readiness_status
WHERE task_name = 'route_readiness_probe'
  AND selection_role = 'strong';
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1
    FROM otlet.stranded_escalation_status
    WHERE task_name = 'route_readiness_probe'
  ),
  'recovered strong route remained stranded'
);

UPDATE otlet.portable_workers
SET last_heartbeat_at = statement_timestamp() - interval '3 minutes'
WHERE worker_id = 'route-readiness-strong-worker';
SELECT pg_temp.assert_true(
  count(*) = 1
    AND bool_and(NOT route_ready)
    AND bool_and(portable_eligible_workers = 0)
    AND bool_and(readiness_reason = 'native_runtime_error'),
  'stale strong worker remained route eligible'
)
FROM otlet.route_readiness_status
WHERE task_name = 'route_readiness_probe'
  AND selection_role = 'strong';

SELECT active_workload_revision_hash AS route_revision_hash
FROM otlet.workload_revision_heads
WHERE task_name = 'route_readiness_probe' \gset
SELECT otlet.set_task_lifecycle(
  'route_readiness_probe',
  'paused',
  :'route_revision_hash'
) \g /dev/null
SELECT pg_temp.assert_true(
  count(*) = 1
    AND bool_and(NOT active_revision)
    AND bool_and(NOT route_ready)
    AND bool_and(readiness_reason = 'task_paused'),
  'paused task hid or misclassified its queued strong route'
)
FROM otlet.route_readiness_status
WHERE task_name = 'route_readiness_probe'
  AND selection_role = 'strong';
SELECT pg_temp.assert_true(
  count(*) = 1
    AND bool_and(stranded_reason = 'task_paused'),
  'paused queued escalation did not report task_paused'
)
FROM otlet.stranded_escalation_status
WHERE task_name = 'route_readiness_probe';

SELECT otlet.create_task(
  'route_readiness_evaluation_probe',
  NULL,
  'Return one decision',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"enum":["accept","reject"]}}}'::jsonb,
  'route_readiness_cheap',
  '{"reasoning":"off","max_tokens":16,"max_attempt_ms":1000,"inference_cache":false}'::jsonb
) \g /dev/null
SELECT otlet.set_model_selection_policy(
  'route_readiness_evaluation_probe',
  'route_readiness_cheap',
  'route_readiness_strong',
  '{"answer_field":"decision","abstain_values":["reject"]}'::jsonb
) \g /dev/null
SELECT otlet.ensure_active_workload_revision(
  'route_readiness_evaluation_probe'
) AS evaluation_active_revision \gset
SELECT otlet.set_model_selection_policy(
  'route_readiness_evaluation_probe',
  'route_readiness_cheap',
  'route_readiness_strong',
  '{"answer_field":"decision","abstain_values":["accept"]}'::jsonb
) \g /dev/null
SELECT otlet.capture_workload_revision(
  'route_readiness_evaluation_probe'
) AS evaluation_candidate_revision \gset
SELECT pg_temp.assert_true(
  :'evaluation_candidate_revision' IS DISTINCT FROM
    :'evaluation_active_revision',
  'evaluation probe did not create a non-head revision'
);
SELECT pg_catalog.set_config('otlet.evaluation_append', 'on', true) \g /dev/null
INSERT INTO otlet.jobs(
  task_name,
  workload_revision_hash,
  subject_id,
  input,
  execution_mode
)
VALUES (
  'route_readiness_evaluation_probe',
  :'evaluation_candidate_revision',
  'route-readiness-evaluation-subject',
  '{}'::jsonb,
  'evaluation'
);
SELECT pg_catalog.set_config('otlet.evaluation_append', '', true) \g /dev/null
SELECT pg_temp.assert_true(
  count(*) = 3
    AND bool_and(NOT active_revision)
    AND bool_and(queued_evaluation_jobs = 1)
    AND bool_and(queued_production_jobs = 0)
    AND count(*) FILTER (WHERE selection_role = 'direct') = 1
    AND count(*) FILTER (WHERE selection_role = 'cheap') = 1
    AND count(*) FILTER (WHERE selection_role = 'strong') = 1,
  'queued non-head evaluation routes were hidden'
)
FROM otlet.route_readiness_status
WHERE task_name = 'route_readiness_evaluation_probe'
  AND workload_revision_hash = :'evaluation_candidate_revision';
DELETE FROM otlet.jobs
WHERE task_name = 'route_readiness_evaluation_probe'
  AND execution_mode = 'evaluation';
INSERT INTO otlet.jobs(task_name, subject_id, input)
VALUES (
  'route_readiness_evaluation_probe',
  'route-readiness-inactive-production-subject',
  '{}'::jsonb
);
SELECT otlet.promote_workload_revision(
  'route_readiness_evaluation_probe',
  :'evaluation_candidate_revision',
  :'evaluation_active_revision'
) \g /dev/null
SELECT pg_temp.assert_true(
  count(*) = 3
    AND bool_and(NOT active_revision)
    AND bool_and(queued_evaluation_jobs = 0)
    AND bool_and(queued_production_jobs = 1)
    AND bool_and(NOT route_ready)
    AND bool_and(readiness_reason = 'workload_revision_inactive'),
  'queued inactive production revision was reported claimable'
)
FROM otlet.route_readiness_status
WHERE task_name = 'route_readiness_evaluation_probe'
  AND workload_revision_hash = :'evaluation_active_revision';
DELETE FROM otlet.jobs
WHERE task_name = 'route_readiness_evaluation_probe'
  AND execution_mode = 'production';

SELECT otlet.create_task(
  'route_readiness_paused_direct_probe',
  NULL,
  'Return one decision',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"enum":["accept","reject"]}}}'::jsonb,
  'route_readiness_cheap',
  '{"reasoning":"off","max_tokens":16,"max_attempt_ms":1000,"inference_cache":false}'::jsonb
) \g /dev/null
INSERT INTO otlet.jobs(task_name, subject_id, input)
VALUES (
  'route_readiness_paused_direct_probe',
  'route-readiness-paused-direct-subject',
  '{}'::jsonb
);
SELECT active_workload_revision_hash AS paused_direct_revision
FROM otlet.workload_revision_heads
WHERE task_name = 'route_readiness_paused_direct_probe' \gset
SELECT otlet.set_task_lifecycle(
  'route_readiness_paused_direct_probe',
  'paused',
  :'paused_direct_revision'
) \g /dev/null
SELECT pg_temp.assert_true(
  count(*) = 1
    AND bool_and(selection_role = 'direct')
    AND bool_and(NOT active_revision)
    AND bool_and(NOT route_ready)
    AND bool_and(readiness_reason = 'task_paused'),
  'paused queued direct route was hidden or misclassified'
)
FROM otlet.route_readiness_status
WHERE task_name = 'route_readiness_paused_direct_probe';
DELETE FROM otlet.jobs
WHERE task_name = 'route_readiness_paused_direct_probe';

UPDATE otlet.runtime_slots
SET status = 'cold',
    last_error = NULL
WHERE model_name = 'route_readiness_strong';

SELECT pg_temp.assert_true(
  NOT pg_catalog.has_table_privilege(
    'public',
    'otlet.route_readiness_status',
    'SELECT'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public',
      'otlet.stranded_escalation_status',
      'SELECT'
    )
    AND NOT EXISTS (SELECT 1 FROM otlet.verify_invariants()),
  'route readiness privilege or invariant fence failed'
);

SELECT 'route_readiness_contract=true|3|resource_evidence|full_rpc|strong_stranded|strong_ready|stale|queued_revisions|paused|public_closed';
ROLLBACK;
SQL
