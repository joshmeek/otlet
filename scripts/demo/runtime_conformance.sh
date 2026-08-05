log "Checking native and portable runtime conformance"

conformance_task="runtime_conformance_task"
cleanup_task "$conformance_task"

psql_exec \
  -v task_name="$conformance_task" \
  -v cheap_model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  NULL,
  'Return exactly one decision. The decision must be keep',
  '{
    "type":"object",
    "required":["decision"],
    "additionalProperties":false,
    "properties":{"decision":{"const":"keep"}}
  }'::jsonb,
  :'cheap_model_name',
  '{"reasoning":"off","max_tokens":32,"inference_cache":false}'::jsonb,
  '{"source_fields":["signal"]}'::jsonb
);
SELECT otlet.set_model_selection_policy(
  :'task_name',
  :'cheap_model_name',
  :'strong_model_name',
  '{"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (:'task_name', 'route', '{"signal":"retain"}'::jsonb);
SQL

wait_task_complete "$conformance_task" 1 300 1

native_route_contract="$(psql_value -v task_name="$conformance_task" <<'SQL'
SELECT (
  job.status = 'complete'
  AND job.attempts = 1
  AND output.output = '{"decision":"keep"}'::jsonb
  AND (
    SELECT count(*) = 2
      AND array_agg(receipt.attempt_index ORDER BY receipt.attempt_index) = ARRAY[1, 2]
      AND array_agg(receipt.selection_role ORDER BY receipt.attempt_index) = ARRAY['cheap', 'strong']
      AND (array_agg(receipt.selection_status ORDER BY receipt.attempt_index))[1]
        IN ('rejected', 'failed')
      AND (array_agg(receipt.selection_status ORDER BY receipt.attempt_index))[2] = 'accepted'
      AND count(DISTINCT receipt.prompt_hash) = 1
      AND count(DISTINCT receipt.input_hash) = 1
      AND count(DISTINCT receipt.output_schema_hash) = 1
      AND bool_and(receipt.prompt_hash IS NOT NULL)
      AND bool_and(receipt.input_hash IS NOT NULL)
      AND bool_and(receipt.output_schema_hash IS NOT NULL)
    FROM otlet.inference_receipts receipt
    WHERE receipt.job_id = job.id
  )
)::text
FROM otlet.jobs job
JOIN otlet.outputs output ON output.job_id = job.id
WHERE job.task_name = :'task_name'
  AND job.subject_id = 'route';
SQL
)"
if [ "$native_route_contract" != "true" ]; then
  echo "Native conformance route did not complete the controlled cheap-to-strong fixture" >&2
  exit 1
fi

runtime_equivalence_contract="$(psql_exec -qAt \
  -v task_name="$conformance_task" \
  -v cheap_model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" \
  -v worker_role=otlet_runtime_conformance_worker <<'SQL'
BEGIN;

UPDATE otlet.production_policy
SET max_attempts = 2
WHERE name = 'default';

SELECT format(
  'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  :'worker_role'
) \gexec
SELECT otlet.grant_portable_worker_access(:'worker_role'::regrole) \g /dev/null
SELECT otlet.register_portable_worker(
  'runtime-conformance-cheap',
  :'worker_role'::regrole,
  1,
  :'cheap_model_name',
  'runtime-conformance-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'transport', 'postgres',
    'fixture', 'runtime-conformance',
    'model_name', :'cheap_model_name',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null
SELECT otlet.register_portable_worker(
  'runtime-conformance-strong',
  :'worker_role'::regrole,
  1,
  :'strong_model_name',
  'runtime-conformance-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'transport', 'postgres',
    'fixture', 'runtime-conformance',
    'model_name', :'strong_model_name',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null

SELECT runtime_identity_hash AS cheap_identity
FROM otlet.portable_workers
WHERE worker_id = 'runtime-conformance-cheap'
\gset
SELECT runtime_identity_hash AS strong_identity
FROM otlet.portable_workers
WHERE worker_id = 'runtime-conformance-strong'
\gset

SET LOCAL ROLE :worker_role;
SELECT incarnation_nonce AS cheap_incarnation
FROM otlet.portable_start_worker(
  'runtime-conformance-cheap',
  1,
  :'cheap_identity'
)
\gset
SELECT incarnation_nonce AS strong_incarnation
FROM otlet.portable_start_worker(
  'runtime-conformance-strong',
  1,
  :'strong_identity'
)
\gset
RESET ROLE;

SELECT pg_catalog.set_config(
  'otlet.runtime_conformance_cheap_identity',
  :'cheap_identity',
  true
) \g /dev/null
SELECT pg_catalog.set_config(
  'otlet.runtime_conformance_cheap_incarnation',
  :'cheap_incarnation',
  true
) \g /dev/null
SELECT pg_catalog.set_config(
  'otlet.runtime_conformance_strong_identity',
  :'strong_identity',
  true
) \g /dev/null
SELECT pg_catalog.set_config(
  'otlet.runtime_conformance_strong_incarnation',
  :'strong_incarnation',
  true
) \g /dev/null

CREATE TEMP TABLE conformance_jobs (
  lane text NOT NULL,
  scenario text NOT NULL,
  job_id bigint NOT NULL,
  PRIMARY KEY (lane, scenario)
);
INSERT INTO conformance_jobs (lane, scenario, job_id)
SELECT 'native', 'route', job.id
FROM otlet.jobs job
WHERE job.task_name = :'task_name'
  AND job.subject_id = 'route';

CREATE TEMP TABLE conformance_route_replay AS
SELECT
  cheap.selection_status AS cheap_selection_status,
  cheap.selection_reason AS cheap_selection_reason,
  cheap.schema_validation_status AS cheap_schema_validation_status,
  cheap.error AS cheap_error,
  cheap.candidate_output AS cheap_candidate_output,
  cheap.raw_output AS cheap_raw_output,
  cheap.input_hash AS cheap_input_hash,
  cheap.output_schema_hash AS cheap_output_schema_hash,
  strong.input_hash AS strong_input_hash,
  strong.output_schema_hash AS strong_output_schema_hash,
  strong.selection_reason AS strong_selection_reason,
  output.output AS accepted_output
FROM conformance_jobs fixture
JOIN otlet.inference_receipts cheap
  ON cheap.job_id = fixture.job_id
 AND cheap.selection_role = 'cheap'
JOIN otlet.inference_receipts strong
  ON strong.job_id = fixture.job_id
 AND strong.selection_role = 'strong'
JOIN otlet.outputs output ON output.job_id = fixture.job_id
WHERE fixture.lane = 'native'
  AND fixture.scenario = 'route';

CREATE TEMP TABLE conformance_native_claims (
  scenario text NOT NULL,
  claim_number integer NOT NULL,
  job_id bigint NOT NULL,
  claim_token text NOT NULL,
  attempt_index integer NOT NULL,
  PRIMARY KEY (scenario, claim_number)
);
CREATE TEMP TABLE conformance_portable_claims (
  scenario text NOT NULL,
  claim_number integer NOT NULL,
  job_id bigint NOT NULL,
  workload_revision_hash text NOT NULL,
  claim_token text NOT NULL,
  selection_role text NOT NULL,
  attempt_index integer NOT NULL,
  input_snapshot jsonb NOT NULL,
  prompt text NOT NULL,
  prompt_hash text NOT NULL,
  output_schema jsonb NOT NULL,
  PRIMARY KEY (scenario, claim_number)
);
CREATE TEMP TABLE conformance_checks (
  name text PRIMARY KEY,
  value bigint NOT NULL
);
GRANT SELECT ON conformance_jobs, conformance_route_replay TO :worker_role;
GRANT SELECT, INSERT ON conformance_portable_claims, conformance_checks TO :worker_role;

WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input
  )
  SELECT
    native.task_name,
    native.workload_revision_hash,
    native.subject_id,
    native.input
  FROM conformance_jobs fixture
  JOIN otlet.jobs native ON native.id = fixture.job_id
  WHERE fixture.lane = 'native'
    AND fixture.scenario = 'route'
  RETURNING id
)
INSERT INTO conformance_jobs (lane, scenario, job_id)
SELECT 'portable', 'route', id FROM inserted;

SET LOCAL ROLE :worker_role;
INSERT INTO conformance_portable_claims
SELECT
  'route',
  1,
  claim.job_id,
  claim.workload_revision_hash,
  claim.claim_token,
  claim.selection_role,
  claim.attempt_index,
  claim.input_snapshot,
  claim.prompt,
  claim.prompt_hash,
  claim.output_schema
FROM otlet.portable_claim_jobs(
  'runtime-conformance-cheap',
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_cheap_identity'),
  pg_catalog.current_setting('otlet.runtime_conformance_cheap_incarnation'),
  1048576,
  6,
  1
) claim;

DO $body$
DECLARE
  claim record;
  replay record;
  replay_raw text;
BEGIN
  SELECT * INTO claim
  FROM pg_temp.conformance_portable_claims
  WHERE scenario = 'route' AND claim_number = 1;
  SELECT * INTO replay FROM pg_temp.conformance_route_replay;

  IF replay.cheap_selection_status = 'rejected' THEN
    IF replay.cheap_candidate_output IS NULL THEN
      RAISE EXCEPTION 'native cheap rejection has no candidate output';
    END IF;
    replay_raw := jsonb_build_object(
      'output', replay.cheap_candidate_output,
      'actions', '[]'::jsonb
    )::text;
    PERFORM *
    FROM otlet.portable_complete_job(
      'runtime-conformance-cheap',
      1,
      pg_catalog.current_setting('otlet.runtime_conformance_cheap_identity'),
      pg_catalog.current_setting('otlet.runtime_conformance_cheap_incarnation'),
      claim.job_id,
      claim.claim_token,
      replay.cheap_candidate_output,
      replay_raw,
      '[]'::jsonb,
      prompt_hash => claim.prompt_hash,
      input_hash => replay.cheap_input_hash,
      output_schema_hash => replay.cheap_output_schema_hash
    );
  ELSIF replay.cheap_selection_status = 'failed' THEN
    replay_raw := COALESCE(
      replay.cheap_raw_output,
      jsonb_build_object(
        'output', replay.cheap_candidate_output,
        'actions', '[]'::jsonb
      )::text
    );
    PERFORM *
    FROM otlet.portable_fail_job(
      'runtime-conformance-cheap',
      1,
      pg_catalog.current_setting('otlet.runtime_conformance_cheap_identity'),
      pg_catalog.current_setting('otlet.runtime_conformance_cheap_incarnation'),
      claim.job_id,
      claim.claim_token,
      replay.cheap_error,
      raw_output => replay_raw,
      prompt_hash => claim.prompt_hash,
      input_hash => replay.cheap_input_hash,
      output_schema_hash => replay.cheap_output_schema_hash,
      schema_validation_status => replay.cheap_schema_validation_status,
      selection_reason => replay.cheap_selection_reason,
      candidate_output => replay.cheap_candidate_output
    );
  ELSE
    RAISE EXCEPTION 'native cheap route did not require strong fallback';
  END IF;
END
$body$;
RESET ROLE;

INSERT INTO conformance_checks (name, value)
SELECT 'portable_route_handoff_attempts', job.attempts
FROM conformance_jobs fixture
JOIN otlet.jobs job ON job.id = fixture.job_id
WHERE fixture.lane = 'portable'
  AND fixture.scenario = 'route';

SET LOCAL ROLE :worker_role;
INSERT INTO conformance_portable_claims
SELECT
  'route',
  2,
  claim.job_id,
  claim.workload_revision_hash,
  claim.claim_token,
  claim.selection_role,
  claim.attempt_index,
  claim.input_snapshot,
  claim.prompt,
  claim.prompt_hash,
  claim.output_schema
FROM otlet.portable_claim_jobs(
  'runtime-conformance-strong',
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_strong_identity'),
  pg_catalog.current_setting('otlet.runtime_conformance_strong_incarnation'),
  1048576,
  6,
  1
) claim;

DO $body$
DECLARE
  claim record;
  replay record;
BEGIN
  SELECT * INTO claim
  FROM pg_temp.conformance_portable_claims
  WHERE scenario = 'route' AND claim_number = 2;
  SELECT * INTO replay FROM pg_temp.conformance_route_replay;

  PERFORM *
  FROM otlet.portable_complete_job(
    'runtime-conformance-strong',
    1,
    pg_catalog.current_setting('otlet.runtime_conformance_strong_identity'),
    pg_catalog.current_setting('otlet.runtime_conformance_strong_incarnation'),
    claim.job_id,
    claim.claim_token,
    replay.accepted_output,
    jsonb_build_object(
      'output', replay.accepted_output,
      'actions', '[]'::jsonb
    )::text,
    '[]'::jsonb,
    prompt_hash => claim.prompt_hash,
    input_hash => replay.strong_input_hash,
    output_schema_hash => replay.strong_output_schema_hash,
    selection_reason => replay.strong_selection_reason
  );
END
$body$;
RESET ROLE;

WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    routed_model_name
  )
  SELECT
    native.task_name,
    native.workload_revision_hash,
    'failure',
    native.input,
    :'strong_model_name'
  FROM conformance_jobs fixture
  JOIN otlet.jobs native ON native.id = fixture.job_id
  WHERE fixture.lane = 'native'
    AND fixture.scenario = 'route'
  RETURNING id
)
INSERT INTO conformance_jobs (lane, scenario, job_id)
SELECT 'native', 'failure', id FROM inserted;
WITH claimed AS (
  SELECT * FROM otlet.claim_jobs(:'strong_model_name', 1)
)
INSERT INTO conformance_native_claims
SELECT 'failure', 1, id, claim_token, attempts FROM claimed;
SELECT count(*)
FROM otlet.fail_job(
  (SELECT job_id FROM conformance_native_claims WHERE scenario = 'failure'),
  'controlled failure',
  schema_validation_status => 'not_run',
  model_name => :'strong_model_name',
  selection_role => 'strong',
  selection_status => 'failed',
  selection_reason => 'controlled_failure',
  expected_claim_token => (
    SELECT claim_token FROM conformance_native_claims WHERE scenario = 'failure'
  )
) \g /dev/null

WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    routed_model_name
  )
  SELECT
    native.task_name,
    native.workload_revision_hash,
    native.subject_id,
    native.input,
    :'strong_model_name'
  FROM conformance_jobs fixture
  JOIN otlet.jobs native ON native.id = fixture.job_id
  WHERE fixture.lane = 'native'
    AND fixture.scenario = 'failure'
  RETURNING id
)
INSERT INTO conformance_jobs (lane, scenario, job_id)
SELECT 'portable', 'failure', id FROM inserted;
SET LOCAL ROLE :worker_role;
INSERT INTO conformance_portable_claims
SELECT
  'failure', 1, claim.job_id, claim.workload_revision_hash,
  claim.claim_token, claim.selection_role, claim.attempt_index,
  claim.input_snapshot, claim.prompt, claim.prompt_hash, claim.output_schema
FROM otlet.portable_claim_jobs(
  'runtime-conformance-strong',
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_strong_identity'),
  pg_catalog.current_setting('otlet.runtime_conformance_strong_incarnation'),
  1048576,
  6,
  1
) claim;
RESET ROLE;

DO $body$
BEGIN
  BEGIN
    UPDATE otlet.jobs
    SET status = 'failed',
        leased_until = NULL,
        claim_token = NULL,
        error = 'unlinked terminal mutation',
        finished_at = now()
    WHERE id = (
      SELECT job_id
      FROM conformance_portable_claims
      WHERE scenario = 'failure'
    );
    RAISE EXCEPTION 'unlinked portable terminal mutation was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%portable terminal job has no matching receipt%' THEN
      RAISE;
    END IF;
  END;
END
$body$;

SET LOCAL ROLE :worker_role;
SELECT count(*)
FROM otlet.portable_fail_job(
  'runtime-conformance-strong',
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_strong_identity'),
  pg_catalog.current_setting('otlet.runtime_conformance_strong_incarnation'),
  (SELECT job_id FROM conformance_portable_claims WHERE scenario = 'failure'),
  (SELECT claim_token FROM conformance_portable_claims WHERE scenario = 'failure'),
  'controlled failure',
  schema_validation_status => 'not_run',
  selection_reason => 'controlled_failure'
) \g /dev/null
RESET ROLE;

WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    routed_model_name
  )
  SELECT
    native.task_name,
    native.workload_revision_hash,
    'cancellation',
    native.input,
    :'strong_model_name'
  FROM conformance_jobs fixture
  JOIN otlet.jobs native ON native.id = fixture.job_id
  WHERE fixture.lane = 'native'
    AND fixture.scenario = 'route'
  RETURNING id
)
INSERT INTO conformance_jobs (lane, scenario, job_id)
SELECT 'native', 'cancellation', id FROM inserted;
WITH claimed AS (
  SELECT * FROM otlet.claim_jobs(:'strong_model_name', 1)
)
INSERT INTO conformance_native_claims
SELECT 'cancellation', 1, id, claim_token, attempts FROM claimed;
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second'
WHERE id = (SELECT job_id FROM conformance_native_claims WHERE scenario = 'cancellation');
SELECT count(*)
FROM otlet.request_job_cancellation(
  (SELECT job_id FROM conformance_native_claims WHERE scenario = 'cancellation'),
  'controlled cancellation'
) \g /dev/null

WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    routed_model_name
  )
  SELECT
    native.task_name,
    native.workload_revision_hash,
    native.subject_id,
    native.input,
    :'strong_model_name'
  FROM conformance_jobs fixture
  JOIN otlet.jobs native ON native.id = fixture.job_id
  WHERE fixture.lane = 'native'
    AND fixture.scenario = 'cancellation'
  RETURNING id
)
INSERT INTO conformance_jobs (lane, scenario, job_id)
SELECT 'portable', 'cancellation', id FROM inserted;
SET LOCAL ROLE :worker_role;
INSERT INTO conformance_portable_claims
SELECT
  'cancellation', 1, claim.job_id, claim.workload_revision_hash,
  claim.claim_token, claim.selection_role, claim.attempt_index,
  claim.input_snapshot, claim.prompt, claim.prompt_hash, claim.output_schema
FROM otlet.portable_claim_jobs(
  'runtime-conformance-strong',
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_strong_identity'),
  pg_catalog.current_setting('otlet.runtime_conformance_strong_incarnation'),
  1048576,
  6,
  1
) claim;
RESET ROLE;
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second'
WHERE id = (SELECT job_id FROM conformance_portable_claims WHERE scenario = 'cancellation');
SELECT count(*)
FROM otlet.request_job_cancellation(
  (SELECT job_id FROM conformance_portable_claims WHERE scenario = 'cancellation'),
  'controlled cancellation'
) \g /dev/null

WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    routed_model_name
  )
  SELECT
    native.task_name,
    native.workload_revision_hash,
    'retry',
    native.input,
    :'strong_model_name'
  FROM conformance_jobs fixture
  JOIN otlet.jobs native ON native.id = fixture.job_id
  WHERE fixture.lane = 'native'
    AND fixture.scenario = 'route'
  RETURNING id
)
INSERT INTO conformance_jobs (lane, scenario, job_id)
SELECT 'native', 'retry', id FROM inserted;
WITH claimed AS (
  SELECT * FROM otlet.claim_jobs(:'strong_model_name', 1)
)
INSERT INTO conformance_native_claims
SELECT 'retry', 1, id, claim_token, attempts FROM claimed;
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second'
WHERE id = (SELECT job_id FROM conformance_native_claims WHERE scenario = 'retry' AND claim_number = 1);
WITH claimed AS (
  SELECT * FROM otlet.claim_jobs(:'strong_model_name', 1)
)
INSERT INTO conformance_native_claims
SELECT 'retry', 2, id, claim_token, attempts FROM claimed;
SELECT count(*)
FROM otlet.complete_job(
  (SELECT job_id FROM conformance_native_claims WHERE scenario = 'retry' AND claim_number = 2),
  '{"decision":"keep"}'::jsonb,
  '{"output":{"decision":"keep"},"actions":[]}',
  '[]'::jsonb,
  model_name => :'strong_model_name',
  selection_role => 'strong',
  selection_reason => 'controlled_retry',
  expected_claim_token => (
    SELECT claim_token
    FROM conformance_native_claims
    WHERE scenario = 'retry' AND claim_number = 2
  )
) \g /dev/null

WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    routed_model_name
  )
  SELECT
    native.task_name,
    native.workload_revision_hash,
    native.subject_id,
    native.input,
    :'strong_model_name'
  FROM conformance_jobs fixture
  JOIN otlet.jobs native ON native.id = fixture.job_id
  WHERE fixture.lane = 'native'
    AND fixture.scenario = 'retry'
  RETURNING id
)
INSERT INTO conformance_jobs (lane, scenario, job_id)
SELECT 'portable', 'retry', id FROM inserted;
SET LOCAL ROLE :worker_role;
INSERT INTO conformance_portable_claims
SELECT
  'retry', 1, claim.job_id, claim.workload_revision_hash,
  claim.claim_token, claim.selection_role, claim.attempt_index,
  claim.input_snapshot, claim.prompt, claim.prompt_hash, claim.output_schema
FROM otlet.portable_claim_jobs(
  'runtime-conformance-strong',
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_strong_identity'),
  pg_catalog.current_setting('otlet.runtime_conformance_strong_incarnation'),
  1048576,
  6,
  1
) claim;
RESET ROLE;
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second'
WHERE id = (SELECT job_id FROM conformance_portable_claims WHERE scenario = 'retry' AND claim_number = 1);
SET LOCAL ROLE :worker_role;
INSERT INTO conformance_portable_claims
SELECT
  'retry', 2, claim.job_id, claim.workload_revision_hash,
  claim.claim_token, claim.selection_role, claim.attempt_index,
  claim.input_snapshot, claim.prompt, claim.prompt_hash, claim.output_schema
FROM otlet.portable_claim_jobs(
  'runtime-conformance-strong',
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_strong_identity'),
  pg_catalog.current_setting('otlet.runtime_conformance_strong_incarnation'),
  1048576,
  6,
  1
) claim;
SELECT count(*)
FROM otlet.portable_complete_job(
  'runtime-conformance-strong',
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_strong_identity'),
  pg_catalog.current_setting('otlet.runtime_conformance_strong_incarnation'),
  (SELECT job_id FROM conformance_portable_claims WHERE scenario = 'retry' AND claim_number = 2),
  (SELECT claim_token FROM conformance_portable_claims WHERE scenario = 'retry' AND claim_number = 2),
  '{"decision":"keep"}'::jsonb,
  '{"output":{"decision":"keep"},"actions":[]}',
  '[]'::jsonb,
  selection_reason => 'controlled_retry'
) \g /dev/null
RESET ROLE;

WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    routed_model_name
  )
  SELECT
    native.task_name,
    native.workload_revision_hash,
    'exhaustion',
    native.input,
    :'strong_model_name'
  FROM conformance_jobs fixture
  JOIN otlet.jobs native ON native.id = fixture.job_id
  WHERE fixture.lane = 'native'
    AND fixture.scenario = 'route'
  RETURNING id
)
INSERT INTO conformance_jobs (lane, scenario, job_id)
SELECT 'native', 'exhaustion', id FROM inserted;
WITH claimed AS (
  SELECT * FROM otlet.claim_jobs(:'strong_model_name', 1)
)
INSERT INTO conformance_native_claims
SELECT 'exhaustion', 1, id, claim_token, attempts FROM claimed;
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second'
WHERE id = (SELECT job_id FROM conformance_native_claims WHERE scenario = 'exhaustion' AND claim_number = 1);
WITH claimed AS (
  SELECT * FROM otlet.claim_jobs(:'strong_model_name', 1)
)
INSERT INTO conformance_native_claims
SELECT 'exhaustion', 2, id, claim_token, attempts FROM claimed;
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second'
WHERE id = (SELECT job_id FROM conformance_native_claims WHERE scenario = 'exhaustion' AND claim_number = 2);
SELECT otlet.sweep_expired_jobs() \g /dev/null

WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    routed_model_name
  )
  SELECT
    native.task_name,
    native.workload_revision_hash,
    native.subject_id,
    native.input,
    :'strong_model_name'
  FROM conformance_jobs fixture
  JOIN otlet.jobs native ON native.id = fixture.job_id
  WHERE fixture.lane = 'native'
    AND fixture.scenario = 'exhaustion'
  RETURNING id
)
INSERT INTO conformance_jobs (lane, scenario, job_id)
SELECT 'portable', 'exhaustion', id FROM inserted;
SET LOCAL ROLE :worker_role;
INSERT INTO conformance_portable_claims
SELECT
  'exhaustion', 1, claim.job_id, claim.workload_revision_hash,
  claim.claim_token, claim.selection_role, claim.attempt_index,
  claim.input_snapshot, claim.prompt, claim.prompt_hash, claim.output_schema
FROM otlet.portable_claim_jobs(
  'runtime-conformance-strong',
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_strong_identity'),
  pg_catalog.current_setting('otlet.runtime_conformance_strong_incarnation'),
  1048576,
  6,
  1
) claim;
RESET ROLE;
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second'
WHERE id = (SELECT job_id FROM conformance_portable_claims WHERE scenario = 'exhaustion' AND claim_number = 1);
SET LOCAL ROLE :worker_role;
INSERT INTO conformance_portable_claims
SELECT
  'exhaustion', 2, claim.job_id, claim.workload_revision_hash,
  claim.claim_token, claim.selection_role, claim.attempt_index,
  claim.input_snapshot, claim.prompt, claim.prompt_hash, claim.output_schema
FROM otlet.portable_claim_jobs(
  'runtime-conformance-strong',
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_strong_identity'),
  pg_catalog.current_setting('otlet.runtime_conformance_strong_incarnation'),
  1048576,
  6,
  1
) claim;
RESET ROLE;
UPDATE otlet.jobs
SET leased_until = now() - interval '1 second'
WHERE id = (SELECT job_id FROM conformance_portable_claims WHERE scenario = 'exhaustion' AND claim_number = 2);

CREATE TEMP TABLE conformance_runtime_slot AS
SELECT status, last_error, failures
FROM otlet.runtime_slots
WHERE model_name = :'strong_model_name';

SET LOCAL ROLE :worker_role;
INSERT INTO conformance_checks (name, value)
SELECT 'portable_exhaustion_third_claims', count(*)
FROM otlet.portable_claim_jobs(
  'runtime-conformance-strong',
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_strong_identity'),
  pg_catalog.current_setting('otlet.runtime_conformance_strong_incarnation'),
  1048576,
  6,
  1
);
RESET ROLE;

CREATE TEMP TABLE conformance_runtime_slot_after AS
SELECT status, last_error, failures
FROM otlet.runtime_slots
WHERE model_name = :'strong_model_name';
SELECT otlet.touch_runtime_slot(:'strong_model_name', 'ready', 0, NULL) \g /dev/null

CREATE TEMP VIEW conformance_semantics AS
SELECT
  fixture.lane,
  fixture.scenario,
  jsonb_build_object(
    'job', jsonb_build_object(
      'task_name', job.task_name,
      'workload_revision_hash', job.workload_revision_hash,
      'subject_id', job.subject_id,
      'input', job.input,
      'status', job.status,
      'attempts', job.attempts,
      'error', job.error,
      'failure_reason_code', job.failure_reason_code
    ),
    'output_count', (
      SELECT count(*) FROM otlet.outputs output WHERE output.job_id = job.id
    ),
    'output', (
      SELECT output.output FROM otlet.outputs output WHERE output.job_id = job.id
    ),
    'action_count', (
      SELECT count(*) FROM otlet.actions action WHERE action.job_id = job.id
    ),
    'receipts', COALESCE(receipts.value, '[]'::jsonb)
  ) AS value
FROM conformance_jobs fixture
JOIN otlet.jobs job ON job.id = fixture.job_id
LEFT JOIN LATERAL (
  SELECT jsonb_agg(
    jsonb_build_object(
      'workload_revision_hash', receipt.workload_revision_hash,
      'attempt_index', receipt.attempt_index,
      'selection_role', receipt.selection_role,
      'selection_status', receipt.selection_status,
      'selection_reason', receipt.selection_reason,
      'task_name', receipt.task_name,
      'subject_id', receipt.subject_id,
      'model_name', receipt.model_name,
      'runtime_options', receipt.runtime_options,
      'task_identity_hash', receipt.task_identity_hash,
      'source_identity_hash', receipt.source_identity_hash,
      'model_identity_hash', receipt.model_identity_hash,
      'runtime_options_hash', receipt.runtime_options_hash,
      'prompt_hash', receipt.prompt_hash,
      'input_hash', receipt.input_hash,
      'output_schema_hash', receipt.output_schema_hash,
      'output_hash', receipt.output_hash,
      'actions_hash', receipt.actions_hash,
      'schema_validation_status', receipt.schema_validation_status,
      'status', receipt.status,
      'error', receipt.error,
      'failure_reason_code', receipt.failure_reason_code
    )
    ORDER BY receipt.attempt_index
  ) AS value
  FROM otlet.inference_receipts receipt
  WHERE receipt.job_id = job.id
) receipts ON true;

SELECT
  (
    SELECT count(*) = 5 AND bool_and(native.value = portable.value)
    FROM conformance_semantics native
    JOIN conformance_semantics portable USING (scenario)
    WHERE native.lane = 'native'
      AND portable.lane = 'portable'
  )::text || '|' ||
  (
    SELECT count(*) = 2
      AND bool_and(claim.workload_revision_hash = receipt.workload_revision_hash)
      AND bool_and(claim.prompt_hash = receipt.prompt_hash)
      AND bool_and(otlet.portable_text_hash(claim.prompt) = receipt.prompt_hash)
      AND bool_and(otlet.portable_json_hash(claim.input_snapshot) = receipt.input_hash)
      AND bool_and(otlet.portable_json_hash(claim.output_schema) = receipt.output_schema_hash)
    FROM conformance_portable_claims claim
    JOIN conformance_jobs native
      ON native.lane = 'native'
     AND native.scenario = 'route'
    JOIN otlet.inference_receipts receipt
      ON receipt.job_id = native.job_id
     AND receipt.attempt_index = claim.claim_number
    WHERE claim.scenario = 'route'
  )::text || '|' ||
  (
    (
      SELECT value = 0
      FROM conformance_checks
      WHERE name = 'portable_route_handoff_attempts'
    )
    AND (
      SELECT count(*) = 2
        AND array_agg(claim.attempt_index ORDER BY claim.claim_number) = ARRAY[1, 1]
        AND array_agg(claim.selection_role ORDER BY claim.claim_number) = ARRAY['cheap', 'strong']
      FROM conformance_portable_claims claim
      WHERE claim.scenario = 'route'
    )
    AND (
      SELECT count(*) = 8
        AND count(*) FILTER (WHERE claim.status = 'replaced') = 3
        AND count(*) FILTER (WHERE claim.status = 'complete') = 2
        AND count(*) FILTER (WHERE claim.status = 'failed') = 2
        AND count(*) FILTER (WHERE claim.status = 'canceled') = 1
      FROM otlet.portable_claims claim
      JOIN conformance_jobs fixture ON fixture.job_id = claim.job_id
      WHERE fixture.lane = 'portable'
    )
    AND (
      SELECT count(*) = 6
      FROM otlet.portable_receipt_links link
      JOIN otlet.portable_claims claim ON claim.id = link.claim_id
      JOIN conformance_jobs fixture ON fixture.job_id = claim.job_id
      WHERE fixture.lane = 'portable'
    )
    AND (
      SELECT count(*) = 4
        AND bool_and(claim.job_id = fixture.job_id)
        AND array_agg(claim.attempt_index ORDER BY claim.scenario, claim.claim_number)
          = ARRAY[1, 1, 1, 2]
      FROM conformance_native_claims claim
      JOIN conformance_jobs fixture
        ON fixture.lane = 'native'
       AND fixture.scenario = claim.scenario
      WHERE claim.scenario IN ('failure', 'cancellation', 'retry')
    )
    AND (
      SELECT count(*) = 2
        AND array_agg(claim.attempt_index ORDER BY claim.claim_number) = ARRAY[1, 2]
      FROM conformance_native_claims claim
      JOIN conformance_jobs fixture
        ON fixture.lane = 'native'
       AND fixture.scenario = 'exhaustion'
       AND fixture.job_id = claim.job_id
      WHERE claim.scenario = 'exhaustion'
    )
    AND (
      SELECT value = 0
      FROM conformance_checks
      WHERE name = 'portable_exhaustion_third_claims'
    )
  )::text || '|' ||
  (
    EXISTS (
      SELECT 1
      FROM conformance_runtime_slot before
      JOIN conformance_runtime_slot_after after
        ON after.status = before.status
       AND after.last_error IS NOT DISTINCT FROM before.last_error
       AND after.failures = before.failures
    )
    AND EXISTS (
      SELECT 1
      FROM conformance_jobs fixture
      JOIN otlet.inference_receipts receipt ON receipt.job_id = fixture.job_id
      JOIN otlet.portable_receipt_links link ON link.receipt_id = receipt.id
      WHERE fixture.lane = 'portable'
        AND fixture.scenario = 'exhaustion'
        AND receipt.runtime_name = 'portable:control'
        AND receipt.runtime_endpoint = 'postgres_rpc'
        AND receipt.selection_reason = 'job_lease_expired_after_max_attempts'
    )
    AND EXISTS (
      SELECT 1
      FROM conformance_jobs fixture
      JOIN otlet.worker_events event ON event.job_id = fixture.job_id
      WHERE fixture.lane = 'portable'
        AND fixture.scenario = 'exhaustion'
        AND event.event_type = 'job_failed'
        AND event.runtime_name = 'portable:control'
    )
  )::text || '|' ||
  (NOT EXISTS (SELECT 1 FROM otlet.verify_invariants()))::text;

ROLLBACK;
SQL
)"

cleanup_task "$conformance_task"

echo "runtime_equivalence_contract=$runtime_equivalence_contract"
if [ "$runtime_equivalence_contract" != "true|true|true|true|true" ]; then
  echo "Expected equivalent native and portable execution state, got $runtime_equivalence_contract" >&2
  exit 1
fi
