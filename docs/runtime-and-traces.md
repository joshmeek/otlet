# Runtime And Traces

Use this after the entity-resolution walkthrough queues work. It inspects model selection, receipts, runtime status, trace visibility, retries, cancellation, and failed-run evidence

## Step 1 - Inspect Model Selection Attempts

```sql
SELECT
  subject_id,
  attempt_index,
  selection_role,
  selection_status,
  model_name,
  output ->> 'match' AS match,
  output ->> 'confidence' AS confidence
FROM otlet.model_selection_attempts
WHERE task_name = 'entity_resolution_demo'
ORDER BY subject_id, attempt_index;
```

Representative output from the demo run:

```text
      subject_id       | attempt_index | selection_role | selection_status |    model_name    |      match       | confidence
-----------------------+---------------+----------------+------------------+------------------+------------------+------------
 vendor-1001:vendor-313 |             1 | cheap          | rejected         | qwen3_1_7b       |                  |
 vendor-1001:vendor-313 |             2 | strong         | accepted         | qwen35_4b        | different_entity | high
 vendor-1001:vendor-314 |             1 | cheap          | rejected         | qwen3_1_7b       |                  |
 vendor-1001:vendor-314 |             2 | strong         | accepted         | qwen35_4b        | different_entity | high
 vendor-1001:vendor-42  |             1 | cheap          | rejected         | qwen3_1_7b       |                  |
 vendor-1001:vendor-42  |             2 | strong         | accepted         | qwen35_4b        | same_entity      | high
 vendor-1001:vendor-77  |             1 | cheap          | rejected         | qwen3_1_7b       |                  |
 vendor-1001:vendor-77  |             2 | strong         | accepted         | qwen35_4b        | different_entity | high
(8 rows)
```

The cheap model is rejected by the stricter output/action envelope in this run. Rejected attempts stay visible as receipts, every row escalates to `qwen35_4b`, and Otlet materializes the accepted output for each job

## Step 2 - Read The Receipt

```sql
SELECT 'receipt_attempt_contract=' ||
       count(*)::text || '|' ||
       count(*) FILTER (WHERE selection_role = 'cheap')::text || '|' ||
       count(*) FILTER (WHERE selection_role = 'strong')::text || '|' ||
       count(*) FILTER (WHERE status = 'rejected')::text AS receipt_attempt_contract
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'entity_resolution_demo';
```

Representative output:

```text
receipt_attempt_contract=8|4|4|4
```

A receipt records evidence for one model run. A selected job can have multiple receipts for the same candidate pair

It links the model, artifact, runtime options, prompt hash, input hash, output schema hash, raw output hash, validation status, timing, token counts, memory summary, and trace summary

Otlet stores receipts when jobs fail because failures produce evidence too

## Step 3 - Inspect Runtime Residency

```sql
SELECT 'runtime_residency_contract=' ||
       runtime_status || '|' ||
       slot_state || '|' ||
       model_residency_policy || '|' ||
       (context_window_tokens > 0)::text || '|' ||
       (inference_cache_entries <= inference_cache_max_entries)::text AS runtime_residency_contract
FROM otlet.runtime_status
WHERE model_name = 'qwen35_4b';
```

Representative output:

```text
runtime_residency_contract=ready|ready|resident_worker_loaded_model_context|true|true
```

Otlet exposes model residency here

The worker keeps the local model/context warm across jobs. SQL can see the slot state, memory sample, context window, cache entries, cache bounds, and the last cache reason

SQL shows whether the model loaded, is busy, failed, cached, or went over budget

The inference-output cache stores schema-valid raw model output before Otlet applies selection trust. Accepted abstentions and rejected-but-valid attempts may reuse cached bytes; invalid JSON/schema failures stay out of the cache. The receipt still records accepted/rejected/failed status, and the cache key basis stays content hash + contract hash + model fingerprint

```sql
SELECT task_name,
       cache_enabled_receipts,
       inference_cache_hits,
       inference_cache_hit_rate,
       inference_cache_key_bases
FROM otlet.task_inference_cache_status
WHERE task_name = 'entity_resolution_demo';
```
## Step 4 - Inspect Token Traces

The task enabled bounded generation tracing:

```json
{
  "generation_trace": true,
  "generation_trace_max_tokens": 16,
  "generation_trace_top_k": 3
}
```

Otlet stores a bounded trace summary on the receipt instead of an unbounded prompt or logits blob

Check the bounded token trace:

```sql
SELECT 'token_trace_contract=' ||
       (SELECT count(*)::text FROM otlet.inference_receipt_token_trace WHERE task_name = 'entity_resolution_demo') || '|' ||
       (SELECT count(*)::text FROM otlet.inference_receipt_token_alternative_trace WHERE task_name = 'entity_resolution_demo') || '|' ||
       (SELECT (max(step) <= 16)::text FROM otlet.inference_receipt_token_trace WHERE task_name = 'entity_resolution_demo') || '|' ||
       (SELECT (max(alternative_rank) <= 3)::text FROM otlet.inference_receipt_token_alternative_trace WHERE task_name = 'entity_resolution_demo') AS token_trace_contract;
```

Representative output:

```text
token_trace_contract=128|384|true|true
```

Trace data records:

- Prompt tokens used by the row
- Model tokens generated
- Generation stop reason
- Probability availability from llama.cpp logits
- Receipt, row identity, input hash, and schema hash attached to the trace
- Resident model cache and inference-output cache use

Otlet bounds tracing so prompt, token, and logits storage does not turn observability into a data retention problem

## Step 5 - Check The Whole Chain

```sql
SELECT
  (SELECT count(*) FROM otlet.outputs o JOIN otlet.jobs j ON j.id = o.job_id WHERE j.task_name = 'entity_resolution_demo') AS outputs,
  (SELECT count(*) FROM otlet.actions a JOIN otlet.jobs j ON j.id = a.job_id WHERE j.task_name = 'entity_resolution_demo') AS actions,
  (SELECT count(*) FROM otlet.records r JOIN otlet.actions a ON a.id = r.action_id JOIN otlet.jobs j ON j.id = a.job_id WHERE j.task_name = 'entity_resolution_demo') AS records,
  (SELECT count(*) FROM otlet.inference_receipts r WHERE r.task_name = 'entity_resolution_demo') AS receipts;
```

Representative output:

```text
 outputs | actions | records | receipts
---------+---------+---------+----------
       4 |       4 |       0 |        8
(1 row)
```

That count covers the direct task shape:

```text
four source candidate pairs
four jobs
four accepted outputs
four typed action proposals
eight model-attempt receipts
bounded trace state
SQL-visible runtime state
```
## Step 6 - Bad Output

If the model returns invalid JSON or a value outside the schema, Otlet fails closed

Check these rows:

- `otlet.jobs.status = 'failed'`
- `otlet.jobs.error` contains the validation or parse failure
- `otlet.jobs.raw_output` keeps raw model text for inspection
- `otlet.outputs` has no validated row
- `otlet.actions` has no trusted row from a failed model attempt
- `otlet.records` has no row
- an error receipt preserves the model/runtime evidence when available

The task schema and action rules decide whether model output can become database truth. If output passes and a proposed action fails, Otlet keeps the rejected action as evidence and creates no record

## Step 7 - Create A Retry Task

The next examples reuse this task to show terminal failure evidence and safe requeueing

```sql
DROP TABLE IF EXISTS public.learning_retry_source;

CREATE TABLE public.learning_retry_source (
  id bigint PRIMARY KEY,
  note text NOT NULL
);

INSERT INTO public.learning_retry_source
VALUES (1, 'Retry me after a terminal failure');

SELECT name, input_query IS NOT NULL AS has_input_query, model_name
FROM otlet.create_task(
  'learning_retry_task',
  $$
    SELECT id::text AS subject_id, to_jsonb(learning_retry_source)::jsonb AS input
    FROM public.learning_retry_source
  $$,
  'Return exactly this JSON object: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  'qwen3_1_7b',
  '{"max_tokens":64,"reasoning":"off"}'::jsonb
);
```

Representative output:

```text
        name         | has_input_query |    model_name
---------------------+-----------------+------------------
 learning_retry_task | t               | qwen3_1_7b
(1 row)
```
## Step 8 - Cancel Queued Work

Cancellation changes job lifecycle state

Use a queued job that the worker has not claimed yet:

```sql
SELECT name, model_name
FROM otlet.create_task(
  'learning_cancel_task',
  NULL::text,
  'Lifecycle task used to show queued cancellation',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  'qwen3_1_7b',
  '{}'::jsonb
);

INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('learning_cancel_task', 'cancel-1', '{"kind":"manual queued job"}'::jsonb)
RETURNING id, task_name, subject_id, status, attempts;

SELECT id, task_name, subject_id, status, error
FROM otlet.cancel_job(
  (SELECT id FROM otlet.jobs WHERE task_name = 'learning_cancel_task' AND subject_id = 'cancel-1'),
  'learning example cancellation'
);

SELECT j.id, j.status, j.error, r.status AS receipt_status, r.error AS receipt_error
FROM otlet.jobs j
LEFT JOIN otlet.inference_receipts r ON r.job_id = j.id
WHERE j.task_name = 'learning_cancel_task'
ORDER BY j.id;
```

Representative output:

```text
         name         |    model_name
----------------------+------------------
 learning_cancel_task | qwen3_1_7b
(1 row)

 id |      task_name       | subject_id | status | attempts
----+----------------------+------------+--------+----------
  9 | learning_cancel_task | cancel-1   | queued |        0
(1 row)

 id |      task_name       | subject_id |  status  |             error
----+----------------------+------------+----------+-------------------------------
  9 | learning_cancel_task | cancel-1   | canceled | learning example cancellation
(1 row)

 id |  status  |             error             | receipt_status |         receipt_error
----+----------+-------------------------------+----------------+-------------------------------
  9 | canceled | learning example cancellation | canceled       | learning example cancellation
(1 row)
```

Canceled work still gets a receipt. A canceled model run still leaves evidence

## Step 9 - Understand Retry And Failed-Run Evidence

Otlet leaves failed jobs visible. A failed job is terminal, so you can queue the same task and subject again

The partial unique index blocks duplicate active work and leaves terminal history reusable:

```sql
CREATE UNIQUE INDEX jobs_active_subject_idx
ON otlet.jobs (task_name, subject_id)
WHERE status IN ('queued', 'running', 'cancel_requested');
```

This run creates one synthetic failed job, then lets `run_task` enqueue a second job for the same subject

The worker claims the second job and rejects the output against the strict JSON contract:

```sql
SELECT id, subject_id, status, attempts, error, raw_output IS NOT NULL AS has_raw_output
FROM otlet.jobs
WHERE task_name = 'learning_retry_task'
ORDER BY id;

SELECT id AS receipt_id, job_id, task_name, subject_id, status, schema_validation_status, error
FROM otlet.inference_receipts
WHERE task_name = 'learning_retry_task'
ORDER BY id;
```

Representative output:

```text
 id | subject_id | status | attempts |                                                                                                                                           error                                                                                                                                            | has_raw_output
----+------------+--------+----------+--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+----------------
 11 | 1          | failed |        1 | learning example synthetic failure                                                                                                                                                                                                                                                         | t
 12 | 1          | failed |        1 | invalid model JSON: The input is a single row of data. The output must be a JSON object with "output" and "actions" keys, and "actions" must be an array. The output must not have any markdown. The output must not have any prose. The output must not have any other keys than "output" | t
(2 rows)

 receipt_id | job_id |      task_name      | subject_id | status | schema_validation_status |                                                                                                                                           error
------------+--------+---------------------+------------+--------+--------------------------+--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
         11 |     11 | learning_retry_task | 1          | failed |                          | learning example synthetic failure
         12 |     12 | learning_retry_task | 1          | failed |                          | invalid model JSON: The input is a single row of data. The output must be a JSON object with "output" and "actions" keys, and "actions" must be an array. The output must not have any markdown. The output must not have any prose. The output must not have any other keys than "output"
(2 rows)
```

Failure keeps the raw output, stores the error, and records the attempt in a receipt
## Step 10 - Check Worker Events And Receipt Statuses

Events show worker behavior. Receipts show model behavior

```sql
SELECT event_type, count(*)
FROM otlet.worker_events e
JOIN otlet.jobs j ON j.id = e.job_id
WHERE j.task_name LIKE 'learning_%'
GROUP BY event_type
ORDER BY event_type;

SELECT task_name, status, count(*)
FROM otlet.inference_receipts
WHERE task_name LIKE 'learning_%'
GROUP BY task_name, status
ORDER BY task_name, status;
```

Representative output:

```text
 event_type   | count
---------------+-------
 job_canceled  |     1
 job_failed    |     2
 job_started   |     1
(3 rows)

      task_name       |  status  | count
----------------------+----------+-------
 learning_cancel_task | canceled |     1
 learning_retry_task  | failed   |     2
(2 rows)
```

Use events for worker behavior and receipts for model behavior
