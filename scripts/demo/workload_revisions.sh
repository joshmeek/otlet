log "Proving immutable workload revisions"

psql_exec -qAt <<'SQL'
BEGIN;

SELECT otlet.register_model(
  'revision_cheap',
  '/tmp/revision-cheap-a.gguf',
  repeat('1', 64),
  jsonb_build_object(
    'sha256', repeat('1', 64),
    'bytes', 1,
    'source', 'fixture',
    'revision', 'cheap-a',
    'quantization', 'none',
    'license', 'test'
  )
) \g /dev/null
SELECT otlet.register_model(
  'revision_strong',
  '/tmp/revision-strong-a.gguf',
  repeat('2', 64),
  jsonb_build_object(
    'sha256', repeat('2', 64),
    'bytes', 1,
    'source', 'fixture',
    'revision', 'strong-a',
    'quantization', 'none',
    'license', 'test'
  )
) \g /dev/null

SELECT otlet.create_task(
  'workload_revision_portable_probe',
  'SELECT ''portable-a''::text AS subject_id, ''{"x":"a","y":"hidden"}''::jsonb AS input',
  'Return the old decision',
  '{"type":"object","required":["old","confidence"],"additionalProperties":false,"properties":{"old":{"const":"a"},"confidence":{"enum":["low","high"]}}}'::jsonb,
  'revision_cheap',
  '{"max_tokens":35,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"source_fields":["x","y"],"strip_keys":["y"]}'::jsonb,
  '{"answer_field":"old","confidence_field":"confidence","accepted_confidence":["high"],"action_types":["review_flag"]}'::jsonb
) \g /dev/null
SELECT otlet.set_model_selection_policy(
  'workload_revision_portable_probe',
  'revision_cheap',
  'revision_strong',
  '{"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
) \g /dev/null

INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('workload_revision_portable_probe', 'old', '{"x":"a","y":"hidden"}'::jsonb);

CREATE TEMP TABLE revision_probe AS
SELECT id AS old_job_id, workload_revision_hash AS revision_a
FROM otlet.jobs
WHERE task_name = 'workload_revision_portable_probe'
  AND subject_id = 'old';

CREATE ROLE otlet_revision_cheap_worker
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE otlet_revision_strong_worker
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
SELECT otlet.grant_portable_worker_access('otlet_revision_cheap_worker'::regrole) \g /dev/null
SELECT otlet.grant_portable_worker_access('otlet_revision_strong_worker'::regrole) \g /dev/null
SELECT otlet.register_portable_worker(
  'revision-cheap-worker',
  'otlet_revision_cheap_worker'::regrole,
  1,
  'revision_cheap',
  'revision-proof',
  '1',
  jsonb_build_object(
    'proof', 'workload-revision',
    'role', 'cheap',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null
SELECT otlet.register_portable_worker(
  'revision-strong-worker',
  'otlet_revision_strong_worker'::regrole,
  1,
  'revision_strong',
  'revision-proof',
  '1',
  jsonb_build_object(
    'proof', 'workload-revision',
    'role', 'strong',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null

SELECT pg_catalog.set_config(
  'otlet.revision_cheap_identity',
  (SELECT runtime_identity_hash FROM otlet.portable_workers WHERE worker_id = 'revision-cheap-worker'),
  true
) \g /dev/null
SELECT pg_catalog.set_config(
  'otlet.revision_strong_identity',
  (SELECT runtime_identity_hash FROM otlet.portable_workers WHERE worker_id = 'revision-strong-worker'),
  true
) \g /dev/null
SET LOCAL ROLE otlet_revision_cheap_worker;
SELECT pg_catalog.set_config(
  'otlet.revision_cheap_incarnation',
  started.incarnation_nonce,
  true
)
FROM otlet.portable_start_worker(
  'revision-cheap-worker',
  1,
  pg_catalog.current_setting('otlet.revision_cheap_identity')
) started
\g /dev/null
RESET ROLE;
SET LOCAL ROLE otlet_revision_strong_worker;
SELECT pg_catalog.set_config(
  'otlet.revision_strong_incarnation',
  started.incarnation_nonce,
  true
)
FROM otlet.portable_start_worker(
  'revision-strong-worker',
  1,
  pg_catalog.current_setting('otlet.revision_strong_identity')
) started
\g /dev/null
RESET ROLE;

SELECT otlet.register_model(
  'revision_cheap',
  '/tmp/revision-cheap-b.gguf',
  repeat('3', 64),
  jsonb_build_object(
    'sha256', repeat('3', 64),
    'bytes', 1,
    'source', 'fixture',
    'revision', 'cheap-b',
    'quantization', 'none',
    'license', 'test'
  )
) \g /dev/null
SELECT otlet.register_model(
  'revision_strong',
  '/tmp/revision-strong-b.gguf',
  repeat('4', 64),
  jsonb_build_object(
    'sha256', repeat('4', 64),
    'bytes', 1,
    'source', 'fixture',
    'revision', 'strong-b',
    'quantization', 'none',
    'license', 'test'
  )
) \g /dev/null
SELECT otlet.create_task(
  'workload_revision_portable_probe',
  'SELECT ''portable-b''::text AS subject_id, ''{"y":"b"}''::jsonb AS input',
  'Return the new decision',
  '{"type":"object","required":["new","confidence"],"additionalProperties":false,"properties":{"new":{"const":"b"},"confidence":{"enum":["low","high"]}}}'::jsonb,
  'revision_cheap',
  '{"max_tokens":70,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"source_fields":["y"]}'::jsonb,
  '{"answer_field":"new","confidence_field":"confidence","accepted_confidence":["low"],"action_types":[]}'::jsonb
) \g /dev/null
SELECT otlet.set_model_selection_policy(
  'workload_revision_portable_probe',
  'revision_cheap',
  'revision_strong',
  '{"confidence_field":"confidence","accepted_confidence":["low"]}'::jsonb
) \g /dev/null
DELETE FROM otlet.action_type_schemas WHERE action_type = 'review_flag';

ALTER TABLE revision_probe ADD COLUMN revision_b text;
UPDATE revision_probe
SET revision_b = otlet.capture_workload_revision(
  'workload_revision_portable_probe'
);
DO $$
BEGIN
  UPDATE otlet.tasks
  SET decision_contract = jsonb_set(
    decision_contract,
    '{action_types}',
    '["review_flag"]'::jsonb
  )
  WHERE name = 'workload_revision_portable_probe';
  BEGIN
    PERFORM otlet.capture_workload_revision('workload_revision_portable_probe');
    RAISE EXCEPTION 'incomplete action revision was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet workload revision action contract is incomplete' THEN
      RAISE;
    END IF;
  END;
  UPDATE otlet.tasks
  SET decision_contract = jsonb_set(
    decision_contract,
    '{action_types}',
    '[]'::jsonb
  )
  WHERE name = 'workload_revision_portable_probe';
END
$$;
DELETE FROM otlet.model_selection_policies
WHERE task_name = 'workload_revision_portable_probe';
CREATE TABLE public.workload_revision_late_source (
  id text PRIMARY KEY,
  x text NOT NULL,
  y text NOT NULL
);
INSERT INTO public.workload_revision_late_source VALUES ('old', 'late', 'source');
INSERT INTO otlet.semantic_indexes (
  name,
  task_name,
  source_table,
  subject_column,
  input_columns,
  record_type,
  model_name
)
VALUES (
  'workload_revision_late_index',
  'workload_revision_portable_probe',
  'public.workload_revision_late_source',
  'id',
  ARRAY['id', 'x', 'y'],
  'workload_revision_late_record',
  'revision_cheap'
);

SET LOCAL ROLE otlet_revision_cheap_worker;
CREATE TEMP TABLE cheap_claim AS
SELECT *
FROM otlet.portable_claim_jobs(
  'revision-cheap-worker',
  1,
  pg_catalog.current_setting('otlet.revision_cheap_identity'),
  pg_catalog.current_setting('otlet.revision_cheap_incarnation'),
  1048576,
  6,
  1
);
CREATE TEMP TABLE cheap_result AS
SELECT *
FROM otlet.portable_complete_job(
  'revision-cheap-worker',
  1,
  pg_catalog.current_setting('otlet.revision_cheap_identity'),
  pg_catalog.current_setting('otlet.revision_cheap_incarnation'),
  (SELECT job_id FROM cheap_claim),
  (SELECT claim_token FROM cheap_claim),
  '{"old":"a","confidence":"low"}'::jsonb,
  '{"output":{"old":"a","confidence":"low"},"actions":[]}',
  '[]'::jsonb
);
RESET ROLE;

SET LOCAL ROLE otlet_revision_strong_worker;
CREATE TEMP TABLE strong_claim AS
SELECT *
FROM otlet.portable_claim_jobs(
  'revision-strong-worker',
  1,
  pg_catalog.current_setting('otlet.revision_strong_identity'),
  pg_catalog.current_setting('otlet.revision_strong_incarnation'),
  1048576,
  6,
  1
);
CREATE TEMP TABLE strong_result AS
SELECT *
FROM otlet.portable_complete_job(
  'revision-strong-worker',
  1,
  pg_catalog.current_setting('otlet.revision_strong_identity'),
  pg_catalog.current_setting('otlet.revision_strong_incarnation'),
  (SELECT job_id FROM strong_claim),
  (SELECT claim_token FROM strong_claim),
  '{"old":"a","confidence":"high"}'::jsonb,
  '{"output":{"old":"a","confidence":"high"},"actions":[{"type":"review_flag","body":{"reason":"revision a"}}]}',
  '[{"type":"review_flag","body":{"reason":"revision a"}}]'::jsonb
);
RESET ROLE;

INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (
  'workload_revision_portable_probe',
  'inactive-fallback',
  '{"x":"a","y":"hidden"}'::jsonb
);
SET LOCAL ROLE otlet_revision_cheap_worker;
CREATE TEMP TABLE inactive_cheap_claim AS
SELECT *
FROM otlet.portable_claim_jobs(
  'revision-cheap-worker',
  1,
  pg_catalog.current_setting('otlet.revision_cheap_identity'),
  pg_catalog.current_setting('otlet.revision_cheap_incarnation'),
  1048576,
  6,
  1
);
RESET ROLE;

SELECT otlet.promote_workload_revision(
  'workload_revision_portable_probe',
  (SELECT revision_b FROM revision_probe),
  (SELECT revision_a FROM revision_probe)
) \g /dev/null
SET LOCAL ROLE otlet_revision_cheap_worker;
CREATE TEMP TABLE inactive_cheap_result AS
SELECT *
FROM otlet.portable_complete_job(
  'revision-cheap-worker',
  1,
  pg_catalog.current_setting('otlet.revision_cheap_identity'),
  pg_catalog.current_setting('otlet.revision_cheap_incarnation'),
  (SELECT job_id FROM inactive_cheap_claim),
  (SELECT claim_token FROM inactive_cheap_claim),
  '{"old":"a","confidence":"low"}'::jsonb,
  '{"output":{"old":"a","confidence":"low"},"actions":[]}',
  '[]'::jsonb
);
RESET ROLE;
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('workload_revision_portable_probe', 'new', '{"y":"b"}'::jsonb);

DO $$
DECLARE
  cheap_record record;
  strong_record record;
  revision_b text;
BEGIN
  SELECT * INTO cheap_record FROM cheap_claim;
  SELECT * INTO strong_record FROM strong_claim;
  SELECT workload_revision_hash INTO revision_b
  FROM otlet.jobs
  WHERE task_name = 'workload_revision_portable_probe'
    AND subject_id = 'new';

  IF (SELECT definition #>> '{task,input_query}' FROM otlet.workload_revisions revision
      JOIN revision_probe probe ON probe.revision_a = revision.workload_revision_hash)
       NOT LIKE 'SELECT %portable-a%'
     OR (SELECT definition #>> '{prompt_builder,version}' FROM otlet.workload_revisions revision
         JOIN revision_probe probe ON probe.revision_a = revision.workload_revision_hash)
       <> 'otlet_raw_json_worker_v1'
     OR (SELECT definition #>> '{validator,version}' FROM otlet.workload_revisions revision
         JOIN revision_probe probe ON probe.revision_a = revision.workload_revision_hash)
       <> 'otlet_portable_validation_v1'
     OR (SELECT definition #>> '{decode,mode}' FROM otlet.workload_revisions revision
         JOIN revision_probe probe ON probe.revision_a = revision.workload_revision_hash)
       <> 'deterministic' THEN
    RAISE EXCEPTION 'revision A omitted an output-affecting contract field';
  END IF;
  IF otlet.current_task_subject_content_hash(
    'workload_revision_portable_probe',
    'old',
    (SELECT revision_a FROM revision_probe)
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'revision A adopted a source contract attached after capture';
  END IF;
  BEGIN
    UPDATE otlet.workload_revisions revision
    SET definition = definition || '{"forged":true}'::jsonb
    FROM revision_probe probe
    WHERE revision.workload_revision_hash = probe.revision_a;
    RAISE EXCEPTION 'workload revision mutation was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet workload revisions are immutable' THEN
      RAISE;
    END IF;
  END;
  IF cheap_record.workload_revision_hash IS DISTINCT FROM (SELECT revision_a FROM revision_probe)
     OR strong_record.workload_revision_hash IS DISTINCT FROM (SELECT revision_a FROM revision_probe)
     OR revision_b = (SELECT revision_a FROM revision_probe) THEN
    RAISE EXCEPTION 'workload revision lineage drifted';
  END IF;
  IF cheap_record.instruction <> 'Return the old decision'
     OR (cheap_record.output_schema #> '{properties}') ? 'new'
     OR cheap_record.runtime_options ->> 'max_tokens' <> '35'
     OR cheap_record.input_snapshot <> '{"x":"a"}'::jsonb
     OR cheap_record.model ->> 'artifact_hash' <> repeat('1', 64) THEN
    RAISE EXCEPTION 'cheap claim did not preserve revision A';
  END IF;
  IF strong_record.model ->> 'artifact_hash' <> repeat('2', 64)
     OR (strong_record.output_schema #> '{properties}') ? 'new'
     OR strong_record.runtime_options ->> 'max_tokens' <> '35' THEN
    RAISE EXCEPTION 'strong claim did not preserve revision A';
  END IF;
  IF (SELECT job_status FROM cheap_result) <> 'queued'
     OR (SELECT job_status FROM strong_result) <> 'complete' THEN
    RAISE EXCEPTION 'selection routing did not use revision A';
  END IF;
  IF (SELECT job_status FROM inactive_cheap_result) <> 'canceled'
     OR NOT EXISTS (
       SELECT 1
       FROM inactive_cheap_claim claim
       JOIN inactive_cheap_result result ON result.job_id = claim.job_id
       JOIN otlet.jobs job ON job.id = result.job_id
       JOIN otlet.portable_claims portable_claim
         ON portable_claim.job_id = claim.job_id
        AND portable_claim.claim_token_hash = otlet.portable_text_hash(claim.claim_token)
       JOIN otlet.inference_receipts receipt ON receipt.id = result.receipt_id
       JOIN otlet.portable_receipt_links link
         ON link.receipt_id = receipt.id
        AND link.claim_id = portable_claim.id
       JOIN revision_probe probe
         ON probe.revision_a = receipt.workload_revision_hash
       WHERE job.status = 'canceled'
         AND receipt.selection_role = 'cheap'
         AND receipt.selection_status = 'rejected'
         AND receipt.selection_reason = 'confidence_below_policy'
     ) THEN
    RAISE EXCEPTION 'inactive revision portable fallback was requeued or lost its receipt';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.inference_receipts receipt
    JOIN revision_probe probe ON probe.old_job_id = receipt.job_id
    WHERE receipt.workload_revision_hash = probe.revision_a
      AND receipt.model_artifact_hash = repeat('1', 64)
      AND receipt.selection_status = 'rejected'
      AND receipt.selection_reason = 'confidence_below_policy'
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.inference_receipts receipt
    JOIN revision_probe probe ON probe.old_job_id = receipt.job_id
    WHERE receipt.workload_revision_hash = probe.revision_a
      AND receipt.model_artifact_hash = repeat('2', 64)
      AND receipt.selection_status = 'accepted'
  ) THEN
    RAISE EXCEPTION 'receipt attribution did not preserve revision A';
  END IF;
  IF (SELECT count(*) FROM otlet.model_selection_status status
      WHERE status.task_name = 'workload_revision_portable_probe') <> 2
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.model_selection_status status
       JOIN revision_probe probe
         ON probe.revision_a = status.workload_revision_hash
       WHERE status.cheap_attempts = 3
         AND status.cheap_rejected = 2
         AND status.strong_attempts = 1
         AND status.strong_accepted = 1
     ) THEN
    RAISE EXCEPTION 'historical selection status depended on the current policy';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.actions action
    JOIN revision_probe probe ON probe.old_job_id = action.job_id
    JOIN otlet.workload_revisions revision
      ON revision.workload_revision_hash = probe.revision_a
    WHERE action.action_type = 'review_flag'
      AND action.status = 'proposed'
      AND action.authority_policy_hash =
        revision.definition #>> '{action_policies,review_flag,authority,policy_hash}'
  ) THEN
    RAISE EXCEPTION 'action authority did not preserve revision A';
  END IF;
END
$$;

SELECT 'workload_revision_contract=ok';
ROLLBACK;

BEGIN;

SELECT otlet.register_model(
  'revision_semantic',
  '/tmp/revision-semantic.gguf',
  repeat('5', 64),
  jsonb_build_object(
    'sha256', repeat('5', 64),
    'bytes', 1,
    'source', 'fixture',
    'revision', 'semantic-a',
    'quantization', 'none',
    'license', 'test'
  )
) \g /dev/null
CREATE TABLE public.workload_revision_semantic_source (
  id text PRIMARY KEY,
  signal text NOT NULL
);
INSERT INTO public.workload_revision_semantic_source VALUES ('one', 'a');

SELECT otlet.create_watch_row_index(
  'workload_revision_semantic_probe',
  'public.workload_revision_semantic_source'::regclass,
  'id',
  'Return status ok',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"const":"ok"}}}'::jsonb,
  'revision_semantic',
  '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb,
  'workload_revision_semantic_record',
  '{}'::jsonb,
  '{}'::jsonb,
  ARRAY['id', 'signal']
) \g /dev/null
SELECT otlet.run_task_subject('workload_revision_semantic_probe_task', 'one') \g /dev/null

CREATE TEMP TABLE semantic_claim AS
SELECT *
FROM otlet.claim_jobs('revision_semantic', 1);

UPDATE otlet.tasks
SET input_query = input_query || E'\n-- revision b'
WHERE name = 'workload_revision_semantic_probe_task';
CREATE TEMP TABLE semantic_revision_b AS
SELECT otlet.capture_workload_revision(
  'workload_revision_semantic_probe_task'
) AS workload_revision_hash;
SELECT otlet.promote_workload_revision(
  'workload_revision_semantic_probe_task',
  (SELECT workload_revision_hash FROM semantic_revision_b),
  (SELECT workload_revision_hash FROM semantic_claim)
) \g /dev/null
SELECT otlet.record_queue_admission_suppressed(
  'workload_revision_semantic_probe_task',
  'revision_semantic',
  suppressed_reason => 'revision_probe',
  suppressed_workload_revision_hash =>
    (SELECT workload_revision_hash FROM semantic_claim)
) \g /dev/null
SELECT otlet.record_queue_admission_suppressed(
  'workload_revision_semantic_probe_task',
  'revision_semantic',
  suppressed_reason => 'revision_probe',
  suppressed_workload_revision_hash =>
    (SELECT workload_revision_hash FROM semantic_revision_b)
) \g /dev/null

CREATE TEMP TABLE semantic_completion AS
SELECT *
FROM otlet.complete_and_materialize_job(
  (SELECT id FROM semantic_claim),
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[]}',
  '[]'::jsonb,
  NULL,
  NULL,
  NULL,
  NULL,
  '{}'::jsonb,
  'revision_semantic',
  'direct',
  'direct',
  (SELECT claim_token FROM semantic_claim)
);

DO $$
BEGIN
  IF (SELECT count(*) FROM semantic_claim) <> 1
     OR (SELECT output_id FROM semantic_completion) IS NULL
     OR (SELECT completion_error FROM semantic_completion) IS NOT NULL
     OR (SELECT materialization_error FROM semantic_completion) IS NOT NULL
     OR (SELECT semantic_materialized FROM semantic_completion) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'superseded semantic completion was reported as materialized';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM semantic_claim claim
    JOIN otlet.workload_revisions revision
      ON revision.workload_revision_hash = claim.workload_revision_hash
    WHERE revision.definition #>> '{source,kind}' = 'row'
      AND revision.definition #>> '{source,semantic_index_name}' =
        'workload_revision_semantic_probe'
      AND revision.definition #>> '{action_policies,create_record,authority,origin}' = 'system'
  ) THEN
    RAISE EXCEPTION 'semantic revision omitted source or create-record authority';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.actions action
    JOIN semantic_claim claim ON claim.id = action.job_id
    WHERE action.action_type = 'create_record'
  ) OR EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations materialization
    WHERE materialization.task_name = 'workload_revision_semantic_probe_task'
  ) THEN
    RAISE EXCEPTION 'superseded semantic output created current materialization state';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.watch_status status
    JOIN semantic_revision_b revision
      ON revision.workload_revision_hash = status.workload_revision_hash
    WHERE status.watch_name = 'workload_revision_semantic_probe'
      AND status.complete_jobs = 0
      AND status.queue_admission_suppressed_events = 1
  ) THEN
    RAISE EXCEPTION 'current watch status included superseded revision history';
  END IF;
END
$$;

SELECT 'workload_revision_semantic_contract=ok';
ROLLBACK;

BEGIN;

SELECT otlet.register_model(
  'revision_queue_a',
  '/tmp/revision-queue-a.gguf',
  repeat('6', 64),
  jsonb_build_object(
    'sha256', repeat('6', 64),
    'bytes', 1,
    'source', 'fixture',
    'revision', 'queue-a',
    'quantization', 'none',
    'license', 'test'
  ),
  7
) \g /dev/null
SELECT otlet.register_model(
  'revision_queue_b',
  '/tmp/revision-queue-b.gguf',
  repeat('7', 64),
  jsonb_build_object(
    'sha256', repeat('7', 64),
    'bytes', 1,
    'source', 'fixture',
    'revision', 'queue-b',
    'quantization', 'none',
    'license', 'test'
  )
) \g /dev/null
SELECT otlet.create_task(
  'workload_revision_queue_probe',
  NULL,
  'Return status ok',
  '{"type":"object"}'::jsonb,
  'revision_queue_a'
) \g /dev/null
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('workload_revision_queue_probe', 'old-route', '{}'::jsonb);
UPDATE otlet.tasks
SET model_name = 'revision_queue_b'
WHERE name = 'workload_revision_queue_probe';
DELETE FROM otlet.models WHERE name = 'revision_queue_a';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.model_queue_status status
    WHERE status.model_name = 'revision_queue_a'
      AND status.max_active_jobs = 7
      AND status.queued_jobs = 1
  ) THEN
    RAISE EXCEPTION 'queue status lost a revision-backed model route';
  END IF;
END
$$;

SELECT 'workload_revision_status_contract=ok';
ROLLBACK;
SQL
