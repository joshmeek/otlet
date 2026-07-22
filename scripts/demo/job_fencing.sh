log "Checking fenced job ownership"
cleanup_task "job_fencing_demo"

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
      '{"decision":"keep"}',
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
    '{"decision":"keep"}',
    trace_summary => '{"schema_validation_status":"passed"}',
    expected_claim_token => second_claim.token
  );
  SELECT id INTO retry_output_id
  FROM otlet.complete_job(
    second_claim.job_id,
    '{"decision":"keep"}',
    '{"decision":"keep"}',
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
      '{"decision":"keep"}',
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
      '{"decision":"drop"}',
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
