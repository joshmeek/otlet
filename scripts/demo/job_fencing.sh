log "Checking fenced job ownership"
cleanup_task "job_fencing_demo"

claimed_batch_task="claimed_batch_lease_probe"
claimed_batch_long_task="claimed_batch_lease_z_long"
cleanup_claimed_batch_lease() {
  cleanup_task "$claimed_batch_task"
  cleanup_task "$claimed_batch_long_task"
  psql_exec -qAt >/dev/null <<'SQL'
DROP TRIGGER IF EXISTS claimed_batch_lease_before ON otlet.jobs;
DROP TRIGGER IF EXISTS claimed_batch_lease_after ON otlet.jobs;
DROP FUNCTION IF EXISTS public.claimed_batch_lease_probe();
DROP TABLE IF EXISTS public.claimed_batch_lease_results;
DROP TABLE IF EXISTS public.claimed_batch_lease_state;
DROP TABLE IF EXISTS public.claimed_batch_lease_baseline;
DELETE FROM otlet.worker_events
WHERE event_type = 'worker_batch_finished'
  AND detail -> 'task_names' ? 'claimed_batch_lease_probe';
DELETE FROM otlet.runtime_slots
WHERE model_name = 'claimed_batch_lease_model';
UPDATE otlet.production_policy
SET worker_claim_batch_size = 8,
    worker_claim_task_cursor = '',
    job_lease_interval = interval '5 minutes',
    max_attempts = 3
WHERE name = 'default';
SQL
}

cleanup_claimed_batch_lease
trap cleanup_claimed_batch_lease EXIT

psql_exec >/dev/null <<'SQL'
INSERT INTO otlet.models (
  name,
  artifact_path,
  artifact_hash,
  artifact_identity,
  max_active_jobs
)
VALUES (
  'claimed_batch_lease_model',
  '/tmp/claimed-batch-missing.gguf',
  repeat('9', 64),
  jsonb_build_object(
    'sha256', repeat('9', 64),
    'bytes', 24,
    'source', 'smoke',
    'revision', 'v1',
    'quantization', 'test',
    'license', 'test'
  ),
  5
)
ON CONFLICT (name) DO NOTHING;
UPDATE otlet.models
SET max_active_jobs = 5
WHERE name = 'claimed_batch_lease_model';
SQL

psql_exec >/dev/null <<'SQL'
CREATE TABLE public.claimed_batch_lease_baseline (
  job_id bigint PRIMARY KEY,
  subject_id text NOT NULL,
  attempts integer NOT NULL,
  claim_token text NOT NULL
);
CREATE TABLE public.claimed_batch_lease_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  renewals integer NOT NULL DEFAULT 0
);
INSERT INTO public.claimed_batch_lease_state DEFAULT VALUES;
CREATE TABLE public.claimed_batch_lease_results (
  operation text PRIMARY KEY,
  value bigint NOT NULL
);

CREATE FUNCTION public.claimed_batch_lease_probe() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  renewal_count integer;
BEGIN
  IF TG_WHEN = 'BEFORE'
     AND OLD.task_name = 'claimed_batch_lease_probe'
     AND OLD.status = 'queued'
     AND NEW.status = 'running' THEN
    IF NEW.subject_id IN ('held-reclaim', 'held-sweep-a', 'held-sweep-b') THEN
      NEW.leased_until := clock_timestamp() + interval '1 second';
    END IF;
    IF NEW.subject_id IN ('held-sweep-a', 'held-sweep-b') THEN
      SELECT max_attempts INTO NEW.attempts
      FROM otlet.production_policy
      WHERE name = 'default';
    END IF;
    INSERT INTO public.claimed_batch_lease_baseline (
      job_id,
      subject_id,
      attempts,
      claim_token
    )
    VALUES (NEW.id, NEW.subject_id, NEW.attempts, NEW.claim_token);
    RETURN NEW;
  END IF;

  IF TG_WHEN = 'AFTER'
     AND OLD.task_name = 'claimed_batch_lease_probe'
     AND OLD.status = 'running'
     AND NEW.status = 'running'
     AND NEW.subject_id IN ('held-reclaim', 'held-sweep-a', 'held-sweep-b')
     AND NEW.leased_until > OLD.leased_until THEN
    UPDATE public.claimed_batch_lease_state
    SET renewals = renewals + 1
    RETURNING renewals INTO renewal_count;
    IF renewal_count = 1 THEN
      PERFORM pg_sleep(5);
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER claimed_batch_lease_before
BEFORE UPDATE ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION public.claimed_batch_lease_probe();
CREATE TRIGGER claimed_batch_lease_after
AFTER UPDATE ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION public.claimed_batch_lease_probe();

BEGIN;
SELECT pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
UPDATE otlet.production_policy
SET worker_claim_batch_size = 5,
    worker_claim_task_cursor = '',
    job_lease_interval = interval '1 second',
    max_attempts = 3
WHERE name = 'default';
SELECT otlet.create_task(
  'claimed_batch_lease_probe',
  'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
  'Claimed batch lease probe',
  '{"type":"object"}'::jsonb,
  'claimed_batch_lease_model',
  '{"max_tokens":1,"max_attempt_ms":1000,"reasoning":"off"}'::jsonb
);
SELECT otlet.create_task(
  'claimed_batch_lease_z_long',
  'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
  'Claimed batch lease cohort probe',
  '{"type":"object"}'::jsonb,
  'claimed_batch_lease_model',
  '{"max_tokens":1,"max_attempt_ms":200000,"reasoning":"off"}'::jsonb
);
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES
  ('claimed_batch_lease_probe', 'first', '{}'),
  ('claimed_batch_lease_probe', 'held-reclaim', '{}'),
  ('claimed_batch_lease_probe', 'held-sweep-a', '{}'),
  ('claimed_batch_lease_probe', 'held-sweep-b', '{}'),
  ('claimed_batch_lease_z_long', 'long', '{}');
COMMIT;
SQL

claimed_batch_sleeping=false
for _ in {1..100}; do
  if [ "$(psql_value -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'otlet worker' AND wait_event = 'PgSleep';")" = "1" ]; then
    claimed_batch_sleeping=true
    break
  fi
  sleep 0.1
done
[ "$claimed_batch_sleeping" = "true" ] || {
  docker logs --tail 120 "$container" >&2
  echo "Worker did not enter the held-claim overlap" >&2
  exit 1
}

claimed_batch_pre_contract="$(
  psql_value <<'SQL'
SELECT
  (SELECT count(*) FROM public.claimed_batch_lease_baseline)::text || '|' ||
  (SELECT count(*)
   FROM otlet.worker_events event
   JOIN otlet.jobs job ON job.id = event.job_id
   WHERE job.task_name = 'claimed_batch_lease_probe'
     AND event.event_type = 'job_started')::text || '|' ||
  (SELECT count(*)
   FROM otlet.inference_receipts receipt
   JOIN otlet.jobs job ON job.id = receipt.job_id
   WHERE job.task_name = 'claimed_batch_lease_probe')::text || '|' ||
  (SELECT count(*)
   FROM otlet.jobs
   WHERE task_name = 'claimed_batch_lease_z_long'
     AND status = 'queued')::text || '|' ||
  (SELECT count(DISTINCT jsonb_extract_path_text(revision.definition, 'runtime', 'lease_ms'))
   FROM otlet.jobs job
   JOIN otlet.workload_revisions revision
     ON revision.task_name = job.task_name
    AND revision.workload_revision_hash = job.workload_revision_hash
   WHERE job.task_name IN (
     'claimed_batch_lease_probe',
     'claimed_batch_lease_z_long'
   ))::text;
SQL
)"
echo "claimed_batch_pre_contract=$claimed_batch_pre_contract"
[ "$claimed_batch_pre_contract" = "4|0|0|1|2" ] || {
  echo "Expected one lease cohort with held claims unstarted, got $claimed_batch_pre_contract" >&2
  exit 1
}

psql_exec -qAt -c "DELETE FROM otlet.jobs WHERE task_name = 'claimed_batch_lease_z_long' AND status = 'queued';" >/dev/null

claimed_batch_expired=false
for _ in {1..100}; do
  if [ "$(psql_value -c "SELECT count(*) FROM otlet.jobs WHERE task_name = 'claimed_batch_lease_probe' AND subject_id IN ('held-reclaim', 'held-sweep-a', 'held-sweep-b') AND leased_until < clock_timestamp();")" = "3" ]; then
    claimed_batch_expired=true
    break
  fi
  sleep 0.1
done
[ "$claimed_batch_expired" = "true" ] || {
  echo "Held-claim deadlines did not become externally reclaimable" >&2
  exit 1
}

psql_exec -qAt -c "INSERT INTO public.claimed_batch_lease_results SELECT 'claim', count(*) FROM otlet.claim_jobs('claimed_batch_lease_model', 5);" >/dev/null &
claimed_batch_claim_pid="$!"
psql_exec -qAt -c "INSERT INTO public.claimed_batch_lease_results VALUES ('sweep', otlet.sweep_expired_jobs());" >/dev/null &
claimed_batch_sweep_pid="$!"
wait "$claimed_batch_claim_pid"
wait "$claimed_batch_sweep_pid"

claimed_batch_terminal=false
for _ in {1..100}; do
  if [ "$(psql_value -c "SELECT count(*) FROM otlet.jobs WHERE task_name = 'claimed_batch_lease_probe' AND status IN ('complete', 'failed', 'canceled');")" = "4" ]; then
    claimed_batch_terminal=true
    break
  fi
  sleep 0.1
done
[ "$claimed_batch_terminal" = "true" ] || {
  psql_exec -P border=2 -P null='' <<'SQL'
SELECT id, subject_id, status, attempts, claim_token, leased_until, error
FROM otlet.jobs
WHERE task_name = 'claimed_batch_lease_probe'
ORDER BY id;
SQL
  docker logs --tail 120 "$container" >&2
  exit 1
}

claimed_batch_finished=false
for _ in {1..100}; do
  if [ "$(psql_value -c "SELECT count(*) FROM otlet.worker_events WHERE event_type = 'worker_batch_finished' AND detail -> 'task_names' ? 'claimed_batch_lease_probe';")" = "1" ]; then
    claimed_batch_finished=true
    break
  fi
  sleep 0.1
done
[ "$claimed_batch_finished" = "true" ] || {
  echo "Worker did not record the claimed-batch completion" >&2
  exit 1
}

claimed_batch_lease_contract="$(
  psql_value <<'SQL'
SELECT
  (SELECT value FROM public.claimed_batch_lease_results WHERE operation = 'claim')::text || '|' ||
  (SELECT value FROM public.claimed_batch_lease_results WHERE operation = 'sweep')::text || '|' ||
  count(*)::text || '|' ||
  bool_and(job.status = 'failed')::text || '|' ||
  bool_and(job.attempts = baseline.attempts)::text || '|' ||
  bool_and(job.terminal_claim_token = baseline.claim_token)::text || '|' ||
  (SELECT (count(*) = 4 AND count(DISTINCT receipt.job_id) = 4)::text
   FROM otlet.inference_receipts receipt
   JOIN otlet.jobs receipt_job ON receipt_job.id = receipt.job_id
   WHERE receipt_job.task_name = 'claimed_batch_lease_probe') || '|' ||
  (SELECT (count(*) = 4 AND count(DISTINCT event.job_id) = 4)::text
   FROM otlet.worker_events event
   JOIN otlet.jobs started_job ON started_job.id = event.job_id
   WHERE started_job.task_name = 'claimed_batch_lease_probe'
     AND event.event_type = 'job_started') || '|' ||
  (SELECT (
     min(event.id) FILTER (WHERE started_job.subject_id = 'first')
       < min(event.id) FILTER (WHERE started_job.subject_id <> 'first')
   )::text
   FROM otlet.worker_events event
   JOIN otlet.jobs started_job ON started_job.id = event.job_id
   WHERE started_job.task_name = 'claimed_batch_lease_probe'
     AND event.event_type = 'job_started')
FROM otlet.jobs job
JOIN public.claimed_batch_lease_baseline baseline ON baseline.job_id = job.id
WHERE job.task_name = 'claimed_batch_lease_probe';
SQL
)"
echo "claimed_batch_lease_contract=$claimed_batch_lease_contract"
[ "$claimed_batch_lease_contract" = "0|0|4|true|true|true|true|true|true" ] || {
  echo "Expected held claims to keep ownership and one attempt, got $claimed_batch_lease_contract" >&2
  exit 1
}

cleanup_claimed_batch_lease
trap - EXIT

job_fencing_output="$(
  psql_exec -qAt -v task_name="job_fencing_demo" -v model_name="$strong_model_name" <<'SQL'
CREATE TEMP TABLE fencing_claims (
  label text PRIMARY KEY,
  job_id bigint NOT NULL,
  attempt integer NOT NULL,
  token text NOT NULL
);

SELECT otlet.create_task(
  :'task_name',
  $source$SELECT 'unused'::text AS subject_id, '{}'::jsonb AS input$source$,
  'Return JSON only',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"enum":["keep","drop"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb,
  '{}'::jsonb,
  '{}'::jsonb
);

BEGIN;
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (:'task_name', 'complete-case', '{}');
INSERT INTO fencing_claims
SELECT 'first', id, attempts, claim_token
FROM otlet.claim_jobs()
WHERE task_name = :'task_name';
COMMIT;

DO $$
DECLARE
  first_claim fencing_claims%ROWTYPE;
BEGIN
  SELECT * INTO first_claim FROM fencing_claims WHERE label = 'first';
  IF first_claim.token !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'claim token is not a UUID';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.renew_job_lease(first_claim.job_id, first_claim.token)
  ) THEN
    RAISE EXCEPTION 'live claim did not renew';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.renew_job_lease(first_claim.job_id, gen_random_uuid()::text)
  ) THEN
    RAISE EXCEPTION 'mismatched claim renewed';
  END IF;
  IF otlet.mark_job_started(first_claim.job_id, gen_random_uuid()::text) THEN
    RAISE EXCEPTION 'mismatched claim marked started';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.worker_events
    WHERE job_id = first_claim.job_id
      AND event_type = 'job_started'
  ) THEN
    RAISE EXCEPTION 'mismatched start marker emitted an event';
  END IF;
END
$$;

UPDATE otlet.jobs
SET leased_until = now() - interval '1 second'
WHERE id = (SELECT job_id FROM fencing_claims WHERE label = 'first');

DO $$
DECLARE
  first_claim fencing_claims%ROWTYPE;
  model_name_value text;
BEGIN
  SELECT * INTO first_claim FROM fencing_claims WHERE label = 'first';
  SELECT t.model_name INTO model_name_value
  FROM otlet.jobs j
  JOIN otlet.tasks t ON t.name = j.task_name
  WHERE j.id = first_claim.job_id;
  IF EXISTS (
    SELECT 1
    FROM otlet.renew_job_lease(first_claim.job_id, first_claim.token)
  ) THEN
    RAISE EXCEPTION 'expired claim renewed';
  END IF;
  BEGIN
    PERFORM otlet.record_model_attempt(
      first_claim.job_id,
      model_name_value,
      selection_status => 'rejected',
      expected_claim_token => first_claim.token
    );
    RAISE EXCEPTION 'expired claim wrote an attempt';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%job claim is stale%' THEN
      RAISE;
    END IF;
  END;
END
$$;

INSERT INTO fencing_claims
SELECT 'second', id, attempts, claim_token
FROM otlet.claim_jobs()
WHERE id = (SELECT job_id FROM fencing_claims WHERE label = 'first');

DO $$
DECLARE
  first_claim fencing_claims%ROWTYPE;
  second_claim fencing_claims%ROWTYPE;
  model_name_value text;
  first_output_id bigint;
  retry_output_id bigint;
BEGIN
  SELECT * INTO first_claim FROM fencing_claims WHERE label = 'first';
  SELECT * INTO second_claim FROM fencing_claims WHERE label = 'second';
  SELECT t.model_name INTO model_name_value
  FROM otlet.jobs j
  JOIN otlet.tasks t ON t.name = j.task_name
  WHERE j.id = second_claim.job_id;
  IF second_claim.token = first_claim.token OR second_claim.attempt <= first_claim.attempt THEN
    RAISE EXCEPTION 'reclaim did not replace ownership';
  END IF;

  BEGIN
    PERFORM * FROM otlet.complete_job(
      first_claim.job_id,
      '{"decision":"keep"}',
      '{"output":{"decision":"keep"},"actions":[]}',
      trace_summary => '{"schema_validation_status":"passed"}',
      expected_claim_token => first_claim.token
    );
    RAISE EXCEPTION 'replaced claim completed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%job claim is stale%' THEN
      RAISE;
    END IF;
  END;

  PERFORM otlet.record_model_attempt(
    second_claim.job_id,
    model_name_value,
    selection_status => 'rejected',
    selection_reason => 'fencing_smoke',
    expected_claim_token => second_claim.token
  );

  SELECT id INTO first_output_id
  FROM otlet.complete_job(
    second_claim.job_id,
    '{"decision":"keep"}',
    '{"output":{"decision":"keep"},"actions":[]}',
    trace_summary => '{"schema_validation_status":"passed"}',
    expected_claim_token => second_claim.token
  );
  SELECT id INTO retry_output_id
  FROM otlet.complete_job(
    second_claim.job_id,
    '{"decision":"keep"}',
    '{"output":{"decision":"keep"},"actions":[]}',
    trace_summary => '{"schema_validation_status":"passed"}',
    expected_claim_token => second_claim.token
  );
  IF first_output_id IS NULL OR retry_output_id IS DISTINCT FROM first_output_id THEN
    RAISE EXCEPTION 'exact completion retry did not converge';
  END IF;
  IF (SELECT count(*) FROM otlet.outputs WHERE job_id = second_claim.job_id) <> 1 THEN
    RAISE EXCEPTION 'completion retry duplicated output';
  END IF;

  BEGIN
    PERFORM * FROM otlet.complete_job(
      second_claim.job_id,
      '{"decision":"keep"}',
      '{"output":{"decision":"keep"},"actions":[]}',
      trace_summary => '{"schema_validation_status":"passed"}'
    );
    RAISE EXCEPTION 'tokenless completion retry succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%job claim is stale%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM * FROM otlet.complete_job(
      second_claim.job_id,
      '{"decision":"drop"}',
      '{"output":{"decision":"drop"},"actions":[]}',
      trace_summary => '{"schema_validation_status":"passed"}',
      expected_claim_token => second_claim.token
    );
    RAISE EXCEPTION 'conflicting completion retry succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%conflicting terminal retry%' THEN
      RAISE;
    END IF;
  END;
END
$$;

BEGIN;
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (:'task_name', 'cancel-case', '{}');
INSERT INTO fencing_claims
SELECT 'cancel', id, attempts, claim_token
FROM otlet.claim_jobs()
WHERE task_name = :'task_name' AND subject_id = 'cancel-case';
COMMIT;

DO $$
DECLARE
  cancel_claim fencing_claims%ROWTYPE;
  first_status text;
  retry_status text;
BEGIN
  SELECT * INTO cancel_claim FROM fencing_claims WHERE label = 'cancel';
  PERFORM * FROM otlet.request_job_cancellation(cancel_claim.job_id, 'fencing cancel');
  IF (SELECT status FROM otlet.jobs WHERE id = cancel_claim.job_id) <> 'cancel_requested' THEN
    RAISE EXCEPTION 'requester cancellation did not signal the owner';
  END IF;
  SELECT status INTO first_status
  FROM otlet.cancel_job(
    cancel_claim.job_id,
    cancel_claim.token,
    'fencing cancel'
  );
  SELECT status INTO retry_status
  FROM otlet.cancel_job(
    cancel_claim.job_id,
    cancel_claim.token,
    'fencing cancel'
  );
  IF first_status <> 'canceled' OR retry_status <> 'canceled' THEN
    RAISE EXCEPTION 'cancellation retry did not converge';
  END IF;
  BEGIN
    PERFORM * FROM otlet.cancel_job(
      cancel_claim.job_id,
      cancel_claim.token,
      'conflict'
    );
    RAISE EXCEPTION 'conflicting cancellation retry succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%conflicting terminal retry%' THEN
      RAISE;
    END IF;
  END;
END
$$;

SELECT
  ((SELECT token FROM fencing_claims WHERE label = 'first') <>
    (SELECT token FROM fencing_claims WHERE label = 'second'))::text || '|' ||
  (SELECT status FROM otlet.jobs WHERE id = (SELECT job_id FROM fencing_claims WHERE label = 'second')) || '|' ||
  (SELECT count(*) FROM otlet.outputs WHERE job_id = (SELECT job_id FROM fencing_claims WHERE label = 'second')) || '|' ||
  (SELECT status FROM otlet.jobs WHERE id = (SELECT job_id FROM fencing_claims WHERE label = 'cancel'));
SQL
)"
job_fencing_contract="$(tail -n 1 <<<"$job_fencing_output")"
echo "job_fencing_contract=$job_fencing_contract"
[ "$job_fencing_contract" = "true|complete|1|canceled" ] || {
  echo "Expected fenced claims and idempotent terminal retries, got $job_fencing_contract" >&2
  exit 1
}

cleanup_task "job_fencing_demo"
