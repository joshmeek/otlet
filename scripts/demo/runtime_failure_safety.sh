require_regex "$oversized_prompt_contract" '^failed\|true\|failed\|failed\|direct_attempt_failed\|failed\|prompt(_and_generation)?_exceed(s_context_window|_context_window)\|0\|ready\|ready$' "Expected oversized prompt to produce a clean failed receipt and healthy worker"

cancel_decode_task="cancel_decode_worker_demo"
cleanup_task "$cancel_decode_task"
psql_exec -v task_name="$cancel_decode_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'cancel-decode-1'::text AS subject_id,
           jsonb_build_object('payload', repeat('cancel decode ', 1000)) AS input
  $source$::text,
  'Return JSON only: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":512,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"source_fields":["payload"]}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
cancel_decode_job_id=""
for _ in $(seq 1 300); do
  cancel_decode_job_id="$(psql_exec -qAt -v task_name="$cancel_decode_task" <<'SQL'
SELECT id FROM otlet.jobs
WHERE task_name = :'task_name' AND status = 'running'
ORDER BY id DESC LIMIT 1;
SQL
)"
  if [ -n "$cancel_decode_job_id" ]; then
    psql_exec -qAt -v job_id="$cancel_decode_job_id" >/dev/null <<'SQL'
SELECT count(*) FROM otlet.request_job_cancellation(:'job_id'::bigint, 'demo cancel mid-decode');
SQL
    break
  fi
  cancel_decode_terminal="$(psql_exec -qAt -v task_name="$cancel_decode_task" <<'SQL'
SELECT COALESCE(max(status), '') FROM otlet.jobs
WHERE task_name = :'task_name'
  AND status IN ('complete','failed','canceled');
SQL
)"
  if [ -n "$cancel_decode_terminal" ]; then
    echo "Expected cancel smoke to reach running state before terminal status, got $cancel_decode_terminal" >&2
    exit 1
  fi
  sleep 0.2
done
[ -n "$cancel_decode_job_id" ] || {
  echo "Timed out waiting for cancel smoke job to run" >&2
  exit 1
}
wait_task_failed "$cancel_decode_task" 1 240 1
cancel_decode_contract="$(psql_exec -qAt \
  -v task_name="$cancel_decode_task" \
  -v model_name="$strong_model_name" <<'SQL'
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = :'task_name'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, selection_reason, schema_validation_status
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
)
SELECT j.status || '|' ||
       (j.error = 'demo cancel mid-decode')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.selection_reason || '|' ||
       COALESCE(r.schema_validation_status, '') || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE(rs.runtime_status, '') || '|' ||
       COALESCE(rs.slot_state, '')
FROM job_row j
CROSS JOIN receipt_row r
JOIN otlet.runtime_status rs
  ON rs.model_name = :'model_name';
SQL
)"
echo "cancel_decode_worker_contract=$cancel_decode_contract"
[ "$cancel_decode_contract" = "canceled|true|canceled|failed|canceled|not_run|0|ready|ready" ] || {
  echo "Expected mid-decode cancel to produce a clean canceled receipt and healthy worker, got $cancel_decode_contract" >&2
  exit 1
}

invalid_json_task="invalid_json_safety_demo"
cleanup_task "$invalid_json_task"
psql_exec -v task_name="$invalid_json_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'invalid-json-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only.',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
);
CREATE TEMP TABLE invalid_json_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token)
  VALUES (:'task_name', 'invalid-json-1', '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes', gen_random_uuid()::text)
  RETURNING id, claim_token
)
SELECT id, claim_token FROM inserted;
SELECT otlet.fail_job(
  id,
  'invalid model JSON: expected object',
  'not json',
  NULL,
  NULL,
  NULL,
  otlet.portable_text_hash('not json'),
  now(),
  'failed',
  '{"schema_validation_status":"failed"}'::jsonb,
  :'model_name',
  'direct',
  'failed',
  'invalid_model_json',
  NULL,
  claim_token
)
FROM invalid_json_claim;
SQL
invalid_json_contract="$(psql_exec -qAt -v task_name="$invalid_json_task" <<'SQL'
WITH job_row AS (
  SELECT id, status, error
  FROM otlet.jobs
  WHERE task_name = :'task_name'
  ORDER BY id DESC
  LIMIT 1
),
receipt_row AS (
  SELECT status, selection_status, schema_validation_status
  FROM otlet.inference_receipts
  WHERE job_id = (SELECT id FROM job_row)
  ORDER BY id DESC
  LIMIT 1
),
materialized AS (
  SELECT count(*)::bigint AS materialization_count
  FROM otlet.semantic_materializations sm
  JOIN otlet.records rec ON rec.id = sm.record_id
  JOIN otlet.actions act ON act.id = rec.action_id
  WHERE act.job_id = (SELECT id FROM job_row)
)
SELECT j.status || '|' ||
       (j.error LIKE 'invalid model JSON:%')::text || '|' ||
       r.status || '|' ||
       r.selection_status || '|' ||
       r.schema_validation_status || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       (SELECT count(*) FROM otlet.actions WHERE job_id = j.id)::text || '|' ||
       (SELECT materialization_count FROM materialized)::text
FROM job_row j
CROSS JOIN receipt_row r;
SQL
)"
echo "invalid_json_safety_contract=$invalid_json_contract"
[ "$invalid_json_contract" = "failed|true|failed|failed|failed|0|0|0" ] || {
  echo "Expected invalid JSON to leave only a failed receipt, got $invalid_json_contract" >&2
  exit 1
}

cleanup_task "$output_envelope_task"
psql_exec -v task_name="$output_envelope_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'unused'::text AS subject_id, '{}'::jsonb AS input WHERE false
  $source$::text,
  'Return JSON only.',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
);

CREATE TEMP TABLE output_envelope_cases (
  subject_id text PRIMARY KEY,
  expected_error text NOT NULL,
  raw_output text NOT NULL
);

INSERT INTO output_envelope_cases (subject_id, expected_error, raw_output)
VALUES
  (
    'markdown-fence',
    'invalid model JSON: markdown fences are not allowed',
    $raw$```json
{"output":{"status":"ok"},"actions":[]}
```$raw$
  ),
  (
    'extra-top-level',
    'model JSON has unsupported top-level key',
    '{"output":{"status":"ok"},"actions":[],"extra":true}'
  ),
  (
    'non-object-action',
    'model JSON actions must contain objects',
    '{"output":{"status":"ok"},"actions":["bad"]}'
  );

WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token)
  SELECT :'task_name', subject_id, '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes', gen_random_uuid()::text
  FROM output_envelope_cases
  RETURNING id, subject_id, claim_token
)
SELECT otlet.fail_job(
  inserted.id,
  cases.expected_error,
  cases.raw_output,
  NULL,
  NULL,
  NULL,
  otlet.portable_text_hash(cases.raw_output),
  now(),
  'failed',
  '{}'::jsonb,
  :'model_name',
  'direct',
  'failed',
  'output_envelope_contract',
  NULL,
  inserted.claim_token
)
FROM inserted
JOIN output_envelope_cases cases USING (subject_id);
SQL
output_envelope_contract="$(psql_exec -qAt -v task_name="$output_envelope_task" <<'SQL'
WITH cases(subject_id, expected_error, raw_output) AS (
  VALUES
    (
      'markdown-fence',
      'invalid model JSON: markdown fences are not allowed',
      $raw$```json
{"output":{"status":"ok"},"actions":[]}
```$raw$
    ),
    (
      'extra-top-level',
      'model JSON has unsupported top-level key',
      '{"output":{"status":"ok"},"actions":[],"extra":true}'
    ),
    (
      'non-object-action',
      'model JSON actions must contain objects',
      '{"output":{"status":"ok"},"actions":["bad"]}'
    )
), rows AS (
  SELECT c.subject_id,
         c.expected_error,
         c.raw_output AS expected_raw_output,
         j.id AS job_id,
         j.status AS job_status,
         j.error AS job_error,
         r.status AS receipt_status,
         r.selection_status,
         r.schema_validation_status,
         r.error AS receipt_error,
         r.raw_output,
         r.raw_output_hash
  FROM cases c
  JOIN otlet.jobs j
    ON j.task_name = :'task_name'
   AND j.subject_id = c.subject_id
  JOIN otlet.inference_receipts r ON r.job_id = j.id
)
SELECT count(*) FILTER (WHERE subject_id = 'markdown-fence' AND job_error = expected_error AND receipt_error = expected_error)::text || '|' ||
       count(*) FILTER (WHERE subject_id = 'extra-top-level' AND job_error = expected_error AND receipt_error = expected_error)::text || '|' ||
       count(*) FILTER (WHERE subject_id = 'non-object-action' AND job_error = expected_error AND receipt_error = expected_error)::text || '|' ||
       bool_and(job_status = 'failed' AND receipt_status = 'failed' AND selection_status = 'failed' AND schema_validation_status = 'failed')::text || '|' ||
       bool_and(raw_output IS NULL AND raw_output_hash = otlet.portable_text_hash(expected_raw_output))::text || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id IN (SELECT job_id FROM rows))::text || '|' ||
       (SELECT count(*) FROM otlet.actions WHERE job_id IN (SELECT job_id FROM rows))::text
FROM rows;
SQL
)"
echo "output_envelope_contract=$output_envelope_contract"
[ "$output_envelope_contract" = "1|1|1|true|true|0|0" ] || {
  echo "Expected strict output envelope failures with raw output hashes, got $output_envelope_contract" >&2
  exit 1
}

hallucinated_action_task="hallucinated_action_safety_demo"
cleanup_task "$hallucinated_action_task"
psql_exec -v task_name="$hallucinated_action_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'hallucinated-action-1'::text AS subject_id, '{}'::jsonb AS input
  $source$::text,
  'Return JSON only.',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
);
CREATE TEMP TABLE hallucinated_action_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token)
  VALUES (:'task_name', 'hallucinated-action-1', '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes', gen_random_uuid()::text)
  RETURNING id, claim_token
)
SELECT id, claim_token FROM inserted;
SELECT otlet.complete_job(
  id,
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[{"type":"invented_action","body":{"subject_id":"hallucinated-action-1","text":"no record"}}]}',
  '[{"type":"invented_action","body":{"subject_id":"hallucinated-action-1","text":"no record"}}]'::jsonb,
  NULL,
  NULL,
  NULL,
  otlet.portable_text_hash('{"output":{"status":"ok"},"actions":[{"type":"invented_action","body":{"subject_id":"hallucinated-action-1","text":"no record"}}]}'),
  now(),
  '{"schema_validation_status":"passed"}'::jsonb,
  :'model_name',
  expected_claim_token => claim_token
)
FROM hallucinated_action_claim;
SQL
hallucinated_action_contract="$(psql_exec -qAt -v task_name="$hallucinated_action_task" <<'SQL'
WITH job_row AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name = :'task_name'
  ORDER BY id DESC
  LIMIT 1
)
SELECT (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       COALESCE((SELECT status || '|' || COALESCE(error, '') FROM otlet.actions WHERE job_id = j.id ORDER BY id DESC LIMIT 1), '') || '|' ||
       (SELECT count(*) FROM otlet.records r JOIN otlet.actions a ON a.id = r.action_id WHERE a.job_id = j.id)::text || '|' ||
       COALESCE((
         SELECT (r.raw_output IS NULL AND
                 r.raw_output_hash = otlet.portable_text_hash('{"output":{"status":"ok"},"actions":[{"type":"invented_action","body":{"subject_id":"hallucinated-action-1","text":"no record"}}]}'))::text
         FROM otlet.inference_receipts r
         WHERE r.job_id = j.id
         ORDER BY r.id DESC
         LIMIT 1
       ), 'false')
FROM job_row j;
SQL
)"
echo "hallucinated_action_safety_contract=$hallucinated_action_contract"
[ "$hallucinated_action_contract" = "1|rejected|action type invented_action is not allowed by workflow|0|true" ] || {
  echo "Expected hallucinated action type to be rejected without a record, got $hallucinated_action_contract" >&2
  exit 1
}
