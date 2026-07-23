log "Checking native and portable runtime conformance"

runtime_equivalence_contract="$(psql_exec -qAt \
  -v model_name="$strong_model_name" \
  -v worker_role=otlet_runtime_conformance_worker \
  -v worker_id=runtime-conformance-worker <<'SQL'
BEGIN;

SELECT format(
  'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  :'worker_role'
) \gexec
SELECT otlet.grant_portable_worker_access(:'worker_role'::regrole) \g /dev/null
SELECT otlet.register_portable_worker(
  :'worker_id',
  :'worker_role'::regrole,
  1,
  :'model_name',
  'runtime-conformance-worker',
  '0.1.0',
  '{"engine":"llama.cpp","transport":"postgres","fixture":"runtime-conformance"}'::jsonb
) \g /dev/null

CREATE TABLE public.otlet_runtime_conformance_source (
  subject_id text PRIMARY KEY,
  signal text NOT NULL
);
INSERT INTO public.otlet_runtime_conformance_source (subject_id, signal)
VALUES
  ('native-action', 'review'),
  ('portable-action', 'review'),
  ('native-abstain', 'abstain'),
  ('portable-abstain', 'abstain'),
  ('native-malformed', 'malformed'),
  ('portable-malformed', 'malformed');

CREATE VIEW public.otlet_runtime_conformance_snapshot AS
SELECT
  source.subject_id,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_runtime_conformance_source',
      'subject_id', source.subject_id,
      'ctid', source.ctid::text,
      'xmin', source.xmin::text
    ),
    'table', 'public.otlet_runtime_conformance_source',
    'row', jsonb_build_object('signal', source.signal)
  ) AS input
FROM public.otlet_runtime_conformance_source source;

SELECT otlet.create_task(
  'runtime_conformance_task',
  'SELECT subject_id, input FROM public.otlet_runtime_conformance_snapshot',
  'Return one bounded conformance decision',
  '{
    "type":"object",
    "required":["decision","confidence"],
    "additionalProperties":false,
    "properties":{
      "decision":{"enum":["flag","abstain"]},
      "confidence":{"enum":["medium","high"]}
    }
  }'::jsonb,
  :'model_name',
  '{"reasoning":"off","max_tokens":32,"inference_cache":false}'::jsonb,
  '{"source_fields":["_otlet_mvcc","table","row"]}'::jsonb,
  '{
    "answer_field":"decision",
    "abstain_values":["abstain"],
    "confidence_field":"confidence",
    "accepted_confidence":["high"],
    "action_types":["review_flag"]
  }'::jsonb
) \g /dev/null

CREATE TEMP TABLE conformance_jobs (
  subject_id text PRIMARY KEY,
  job_id bigint NOT NULL,
  claim_token text
);
WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token
  )
  SELECT
    'runtime_conformance_task',
    snapshot.subject_id,
    snapshot.input,
    'running',
    1,
    now(),
    now() + interval '5 minutes',
    gen_random_uuid()::text
  FROM public.otlet_runtime_conformance_snapshot snapshot
  WHERE snapshot.subject_id LIKE 'native-%'
  RETURNING id, subject_id, claim_token
)
INSERT INTO conformance_jobs (subject_id, job_id, claim_token)
SELECT subject_id, id, claim_token FROM inserted;

SELECT pg_catalog.set_config('otlet.runtime_conformance_model', :'model_name', true) \g /dev/null

SELECT count(*)
FROM otlet.complete_job(
  job_id => (SELECT job_id FROM conformance_jobs WHERE subject_id = 'native-action'),
  output => '{"decision":"flag","confidence":"high"}'::jsonb,
  raw_output => '{"output":{"decision":"flag","confidence":"high"},"actions":[{"type":"review_flag","body":{"severity":"high","reason":"conformance review"}}]}',
  actions => '[{"type":"review_flag","body":{"severity":"high","reason":"conformance review"}}]'::jsonb,
  model_name => :'model_name',
  expected_claim_token => (SELECT claim_token FROM conformance_jobs WHERE subject_id = 'native-action')
) \g /dev/null
SELECT count(*)
FROM otlet.complete_job(
  job_id => (SELECT job_id FROM conformance_jobs WHERE subject_id = 'native-abstain'),
  output => '{"decision":"abstain","confidence":"medium"}'::jsonb,
  raw_output => '{"output":{"decision":"abstain","confidence":"medium"},"actions":[]}',
  actions => '[]'::jsonb,
  model_name => :'model_name',
  expected_claim_token => (SELECT claim_token FROM conformance_jobs WHERE subject_id = 'native-abstain')
) \g /dev/null

DO $body$
DECLARE
  selected conformance_jobs%ROWTYPE;
BEGIN
  SELECT * INTO selected FROM conformance_jobs WHERE subject_id = 'native-malformed';
  BEGIN
    PERFORM * FROM otlet.complete_job(
      selected.job_id,
      '{"decision":"flag","confidence":"high"}'::jsonb,
      '{"output":',
      '[]'::jsonb,
      model_name => pg_catalog.current_setting('otlet.runtime_conformance_model'),
      expected_claim_token => selected.claim_token
    );
    RAISE EXCEPTION 'native malformed output was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%raw output is malformed JSON%' THEN
      RAISE;
    END IF;
  END;
  PERFORM * FROM otlet.fail_job(
    selected.job_id,
    'malformed output rejected',
    schema_validation_status => 'failed',
    model_name => pg_catalog.current_setting('otlet.runtime_conformance_model'),
    expected_claim_token => selected.claim_token
  );
END
$body$;

WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input)
  SELECT 'runtime_conformance_task', snapshot.subject_id, snapshot.input
  FROM public.otlet_runtime_conformance_snapshot snapshot
  WHERE snapshot.subject_id LIKE 'portable-%'
  RETURNING id, subject_id
)
INSERT INTO conformance_jobs (subject_id, job_id)
SELECT subject_id, id FROM inserted;

SELECT runtime_identity_hash AS portable_identity_hash
FROM otlet.portable_workers
WHERE worker_id = :'worker_id'
\gset
SELECT pg_catalog.set_config('otlet.runtime_conformance_worker_id', :'worker_id', true) \g /dev/null
SELECT pg_catalog.set_config('otlet.runtime_conformance_identity', :'portable_identity_hash', true) \g /dev/null

SET LOCAL ROLE :worker_role;
CREATE TEMP TABLE conformance_claims AS
SELECT *
FROM otlet.portable_claim_jobs(
  pg_catalog.current_setting('otlet.runtime_conformance_worker_id'),
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_identity'),
  3
);

SELECT count(*)
FROM otlet.portable_complete_job(
  pg_catalog.current_setting('otlet.runtime_conformance_worker_id'),
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_identity'),
  (SELECT job_id FROM conformance_claims WHERE subject_id = 'portable-action'),
  (SELECT claim_token FROM conformance_claims WHERE subject_id = 'portable-action'),
  '{"decision":"flag","confidence":"high"}'::jsonb,
  '{"output":{"decision":"flag","confidence":"high"},"actions":[{"type":"review_flag","body":{"severity":"high","reason":"conformance review"}}]}',
  '[{"type":"review_flag","body":{"severity":"high","reason":"conformance review"}}]'::jsonb,
  model_name => :'model_name'
) \g /dev/null
SELECT count(*)
FROM otlet.portable_complete_job(
  pg_catalog.current_setting('otlet.runtime_conformance_worker_id'),
  1,
  pg_catalog.current_setting('otlet.runtime_conformance_identity'),
  (SELECT job_id FROM conformance_claims WHERE subject_id = 'portable-abstain'),
  (SELECT claim_token FROM conformance_claims WHERE subject_id = 'portable-abstain'),
  '{"decision":"abstain","confidence":"medium"}'::jsonb,
  '{"output":{"decision":"abstain","confidence":"medium"},"actions":[]}',
  '[]'::jsonb,
  model_name => :'model_name'
) \g /dev/null

DO $body$
DECLARE
  selected conformance_claims%ROWTYPE;
BEGIN
  SELECT * INTO selected FROM conformance_claims WHERE subject_id = 'portable-malformed';
  BEGIN
    PERFORM * FROM otlet.portable_complete_job(
      pg_catalog.current_setting('otlet.runtime_conformance_worker_id'),
      1,
      pg_catalog.current_setting('otlet.runtime_conformance_identity'),
      selected.job_id,
      selected.claim_token,
      '{"decision":"flag","confidence":"high"}'::jsonb,
      '{"output":',
      '[]'::jsonb,
      model_name => pg_catalog.current_setting('otlet.runtime_conformance_model')
    );
    RAISE EXCEPTION 'portable malformed output was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%raw output is malformed JSON%' THEN
      RAISE;
    END IF;
  END;
  PERFORM * FROM otlet.portable_fail_job(
    pg_catalog.current_setting('otlet.runtime_conformance_worker_id'),
    1,
    pg_catalog.current_setting('otlet.runtime_conformance_identity'),
    selected.job_id,
    selected.claim_token,
    'malformed output rejected',
    schema_validation_status => 'failed',
    model_name => pg_catalog.current_setting('otlet.runtime_conformance_model')
  );
END
$body$;
RESET ROLE;

SELECT count(*)
FROM otlet.actions action
JOIN otlet.jobs job ON job.id = action.job_id
CROSS JOIN LATERAL otlet.reject_action(
  action.id,
  'conformance review',
  'conformance review'
) rejected
WHERE job.subject_id IN ('native-action', 'portable-action')
\g /dev/null
SELECT count(*)
FROM otlet.actions action
JOIN otlet.jobs job ON job.id = action.job_id
CROSS JOIN LATERAL otlet.label_action(
  action.id,
  'flag',
  'high',
  'review_flag',
  'conformance label',
  'manual_correction'
) label
WHERE job.subject_id IN ('native-action', 'portable-action')
\g /dev/null
SELECT count(*)
FROM otlet.inference_receipts receipt
CROSS JOIN LATERAL otlet.abstain_review(receipt.id, 'conformance abstention') review
WHERE receipt.subject_id IN ('native-abstain', 'portable-abstain')
  AND receipt.selection_status = 'accepted'
\g /dev/null

UPDATE public.otlet_runtime_conformance_source
SET signal = 'changed-after-review'
WHERE subject_id IN ('native-action', 'portable-action');

SELECT
  (
    SELECT count(*) = 6
      AND count(*) FILTER (WHERE subject_id LIKE '%-action' AND status = 'complete') = 2
      AND count(*) FILTER (WHERE subject_id LIKE '%-abstain' AND status = 'complete') = 2
      AND count(*) FILTER (WHERE subject_id LIKE '%-malformed' AND status = 'failed') = 2
    FROM otlet.jobs
    WHERE task_name = 'runtime_conformance_task'
  )::text || '|' ||
  (
    SELECT count(*) = 4
      AND count(*) FILTER (WHERE output ->> 'decision' = 'flag') = 2
      AND count(*) FILTER (WHERE output ->> 'decision' = 'abstain') = 2
    FROM otlet.outputs output
    JOIN otlet.jobs job ON job.id = output.job_id
    WHERE job.task_name = 'runtime_conformance_task'
  )::text || '|' ||
  (
    SELECT count(*) = 4
      AND bool_and(status = 'complete')
      AND bool_and(selection_status = 'accepted')
      AND bool_and(schema_validation_status = 'passed')
      AND count(*) FILTER (WHERE runtime_name = 'linked_inproc') = 2
      AND count(*) FILTER (WHERE runtime_name = 'portable:runtime-conformance-worker') = 2
    FROM otlet.inference_receipts
    WHERE task_name = 'runtime_conformance_task'
      AND selection_status = 'accepted'
  )::text || '|' ||
  (
    SELECT count(*) = 2
      AND bool_and(action_type = 'review_flag')
      AND bool_and(status = 'rejected')
      AND bool_and(trusted_output)
    FROM otlet.action_status
    WHERE task_name = 'runtime_conformance_task'
  )::text || '|' ||
  (
    SELECT count(*) = 4
      AND count(*) FILTER (WHERE outcome = 'reject') = 2
      AND count(*) FILTER (WHERE outcome = 'abstain') = 2
      AND bool_and(source_freshness = 'fresh')
    FROM otlet.review_events
    WHERE task_name = 'runtime_conformance_task'
  )::text || '|' ||
  (
    SELECT count(*) = 2
      AND bool_and(expected_answer = 'flag')
      AND bool_and(observed_answer = 'flag')
      AND bool_and(expected_action_type = 'review_flag')
      AND bool_and(observed_action_type = 'review_flag')
    FROM otlet.eval_label_status
    WHERE task_name = 'runtime_conformance_task'
  )::text || '|' ||
  (
    SELECT count(*) = 2
      AND bool_and(
        content_hash IS DISTINCT FROM otlet.current_task_subject_content_hash(
          'runtime_conformance_task',
          job_subject_id
        )
      )
    FROM otlet.action_status
    WHERE task_name = 'runtime_conformance_task'
  )::text || '|' ||
  (
    SELECT count(*) = 2
      AND bool_and(status = 'failed')
      AND bool_and(selection_status = 'failed')
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.outputs output
        JOIN otlet.jobs job ON job.id = output.job_id
        WHERE job.task_name = 'runtime_conformance_task'
          AND job.subject_id LIKE '%-malformed'
      )
    FROM otlet.inference_receipts
    WHERE task_name = 'runtime_conformance_task'
      AND subject_id LIKE '%-malformed'
  )::text || '|' ||
  (
    SELECT count(*) = 3
      AND count(*) FILTER (WHERE claim.status = 'complete') = 2
      AND count(*) FILTER (WHERE claim.status = 'failed') = 1
    FROM otlet.portable_claims claim
    JOIN otlet.jobs job ON job.id = claim.job_id
    WHERE job.task_name = 'runtime_conformance_task'
  )::text || '|' ||
  (NOT EXISTS (SELECT 1 FROM otlet.verify_invariants()))::text;

ROLLBACK;
SQL
)"
echo "runtime_equivalence_contract=$runtime_equivalence_contract"
[ "$runtime_equivalence_contract" = "true|true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected equivalent native and portable trusted state, got $runtime_equivalence_contract" >&2
  exit 1
}

credential_role="otlet_runtime_rotation_probe"
old_password="$(openssl rand -hex 24)"
new_password="$(openssl rand -hex 24)"
credential_host="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container")"
[ -n "$credential_host" ] || {
  echo "Could not resolve the database container address for credential rotation" >&2
  exit 1
}
psql_exec -qAt -v role_name="$credential_role" <<'SQL' >/dev/null
SELECT format('DROP ROLE IF EXISTS %I', :'role_name') \gexec
SQL
psql_exec -qAt -v role_name="$credential_role" -v role_password="$old_password" <<'SQL' >/dev/null
SELECT format(
  'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  :'role_name',
  :'role_password'
) \gexec
SQL
old_password_before=false
old_password_after=false
new_password_after=false
if docker exec -e "PGPASSWORD=$old_password" "$container" \
  psql -h "$credential_host" -U "$credential_role" -d "$database" -qAt \
  -c 'SELECT current_user' | grep -qx "$credential_role"; then
  old_password_before=true
fi
psql_exec -qAt -v role_name="$credential_role" -v role_password="$new_password" <<'SQL' >/dev/null
SELECT format('ALTER ROLE %I PASSWORD %L', :'role_name', :'role_password') \gexec
SQL
if docker exec -e "PGPASSWORD=$old_password" "$container" \
  psql -h "$credential_host" -U "$credential_role" -d "$database" -qAt \
  -c 'SELECT current_user' >/dev/null 2>&1; then
  old_password_after=true
fi
if docker exec -e "PGPASSWORD=$new_password" "$container" \
  psql -h "$credential_host" -U "$credential_role" -d "$database" -qAt \
  -c 'SELECT current_user' | grep -qx "$credential_role"; then
  new_password_after=true
fi
psql_exec -qAt -v role_name="$credential_role" <<'SQL' >/dev/null
SELECT format('DROP ROLE %I', :'role_name') \gexec
SQL

runtime_credential_rotation_contract="$old_password_before|$old_password_after|$new_password_after"
echo "runtime_credential_rotation_contract=$runtime_credential_rotation_contract"
[ "$runtime_credential_rotation_contract" = "true|false|true" ] || {
  echo "Expected old credentials to fail after rotation and new credentials to succeed" >&2
  exit 1
}
