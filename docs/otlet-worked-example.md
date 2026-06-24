# Otlet Worked Example

Use this as a learning file, not a test harness (inspired by the _worked example_ research done in [this study](https://www.tandfonline.com/doi/full/10.1080/01443410.2023.2273762#abstract))

The file shows the smallest real Otlet loop: you start with a normal Postgres row, enqueue durable model work, let the resident worker run a local model, validate the output, store a typed action, write an Otlet-owned record, and keep the audit trail

The example data uses one counterparty review row with an invalid email, no tax form, and no verified bank account. Otlet classifies that row as `needs_review` without mutating the source table

## 1. Otlet In One Loop

```text
source table row
  -> otlet.jobs row
  -> resident Postgres worker
  -> linked local Qwen through llama.cpp
  -> JSON validation
  -> otlet.outputs
  -> otlet.actions
  -> otlet.records
  -> otlet.inference_receipts
```

Otlet keeps Postgres as the system of record

The model does not get direct write access to user tables. It receives bounded row-shaped input and returns structured JSON. Otlet decides whether that JSON is valid enough to store, and the only action used here is `create_record`, which writes to Otlet-owned tables

## 2. Start From A Running Local Otlet

Build and start the local Postgres container first:

```sh
./scripts/otlet-setup.sh
```

Then open `psql` with the local Qwen artifact path available as a variable:

```sh
docker exec -it otlet-postgres sh -lc '
  model_artifact="$(find /var/lib/postgresql -name Qwen3-0.6B-Q8_0.gguf -print -quit)"
  psql -U postgres -d postgres -v model_artifact="$model_artifact"
'
```

Paste the rest of the file into that `psql` session section by section

The output blocks below are representative output from real local runs. Job IDs, receipt IDs, timestamps, costs, timings, memory samples, and token rates vary by machine and model cache state

## 3. Register The Runtime And Model

```sql
CREATE EXTENSION IF NOT EXISTS otlet;

SELECT otlet.register_runtime('linked_inproc', 'linked');

SELECT otlet.register_model(
  'linked_qwen_0_6b',
  :'model_artifact',
  'linked_inproc'
);
```

`linked_inproc` means the Otlet background worker inside Postgres owns inference

This path uses no `llama-server`, app worker, or service call. The worker loads a local GGUF through linked llama.cpp and keeps the model resident across jobs

The architectural reason is locality. The queue, source row identity, output validation, receipts, traces, and runtime state are all visible from SQL

## 4. Create The Source Table

```sql
DROP TABLE IF EXISTS public.counterparty_review_case;

CREATE TABLE public.counterparty_review_case (
  id bigint PRIMARY KEY,
  entity_name text NOT NULL,
  contact_email text NOT NULL,
  tax_form_on_file boolean NOT NULL,
  bank_account_verified boolean NOT NULL,
  sanctions_screen_hit boolean NOT NULL,
  annual_spend_usd numeric NOT NULL
);

INSERT INTO public.counterparty_review_case
  (id, entity_name, contact_email, tax_form_on_file, bank_account_verified, sanctions_screen_hit, annual_spend_usd)
VALUES
  (1, 'Bad Invoice LLC', 'billing@', false, false, false, 126000);
```

This table is ordinary application data

Otlet does not own it. The model will not update it. If you want to approve, reject, merge, or remediate the counterparty later, that should be an explicit application workflow outside this model pass

## 5. Clear Old Demo State

```sql
DELETE FROM otlet.worker_events e
USING otlet.jobs j
WHERE e.job_id = j.id
  AND j.task_name = 'counterparty_review_task';

DELETE FROM otlet.inference_receipts r
USING otlet.jobs j
WHERE r.job_id = j.id
  AND j.task_name = 'counterparty_review_task';

DELETE FROM otlet.records r
USING otlet.actions a, otlet.jobs j
WHERE r.action_id = a.id
  AND a.job_id = j.id
  AND j.task_name = 'counterparty_review_task';

DELETE FROM otlet.actions a
USING otlet.jobs j
WHERE a.job_id = j.id
  AND j.task_name = 'counterparty_review_task';

DELETE FROM otlet.outputs o
USING otlet.jobs j
WHERE o.job_id = j.id
  AND j.task_name = 'counterparty_review_task';

DELETE FROM otlet.jobs
WHERE task_name = 'counterparty_review_task';

DELETE FROM otlet.tasks
WHERE name = 'counterparty_review_task';
```

The product flow does not need this cleanup

It only makes the example rerunnable

## 6. Create The Task

```sql
SELECT name, model_name
FROM otlet.create_task(
  'counterparty_review_task',
  $$
    SELECT
      id::text AS subject_id,
      to_jsonb(counterparty_review_case)::jsonb AS input
    FROM public.counterparty_review_case
  $$,
  'This counterparty review row is invalid because contact_email is exactly "billing@", tax_form_on_file is false, and bank_account_verified is false. Return exactly this JSON object: {"output":{"decision":"needs_review","needs_review":true,"risk_level":"high","next_step":"manual_review"},"actions":[{"type":"create_record","record_type":"counterparty_review","subject_id":"1","body":{"decision":"needs_review","needs_review":true,"risk_level":"high","next_step":"manual_review"}}]}',
  '{
    "type": "object",
    "required": ["decision", "needs_review", "risk_level", "next_step"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["needs_review"]},
      "needs_review": {"type": "boolean"},
      "risk_level": {"enum": ["high"]},
      "next_step": {"enum": ["manual_review"]}
    }
  }'::jsonb,
  'linked_qwen_0_6b',
  '{
    "temperature": 0,
    "max_tokens": 256,
    "reasoning": "off",
    "inference_cache": true,
    "generation_trace": true,
    "generation_trace_max_tokens": 16,
    "generation_trace_top_k": 3
  }'::jsonb
);
```

Representative output:

```text
           name           |    model_name
--------------------------+------------------
 counterparty_review_task | linked_qwen_0_6b
(1 row)
```

`create_task` registers the model contract and input query

The task has six important parts:

- `task_name` gives the queue and receipt trail a stable name
- `input_query` converts source rows into `subject_id` and `input`
- `instruction` is the model contract for this task
- `output_schema` is the JSON schema Otlet enforces before storing output
- `model_name` chooses the registered local model
- `runtime_options` bound generation, tracing, and cache behavior

The schema separates model text from database state Otlet can store

If the model returns malformed JSON, missing fields, unknown fields, or values outside the enum, Otlet marks the job failed and keeps the raw evidence. It does not silently write output or records

## 7. Enqueue The Job

```sql
SELECT otlet.run_task('counterparty_review_task') AS queued_jobs;
```

Representative output:

```text
 queued_jobs
-------------
           1
(1 row)
```

`run_task` executes the task input query and inserts one row into `otlet.jobs`

The user transaction creates durable database work, then the resident worker claims it

The queue keeps the model run out of the client request. You can inspect the work in SQL while it is queued, running, complete, failed, or canceled

## 8. Watch The Worker

```sql
SELECT
  id,
  task_name,
  subject_id,
  status,
  attempts,
  created_at,
  started_at,
  finished_at,
  error
FROM otlet.jobs
WHERE task_name = 'counterparty_review_task'
ORDER BY id;
```

If it is still running, wait a moment and run the query again

Representative output:

```text
 id |        task_name         | subject_id |  status  | attempts |          created_at           |          started_at           |          finished_at          | error
----+--------------------------+------------+----------+----------+-------------------------------+-------------------------------+-------------------------------+-------
  2 | counterparty_review_task | 1          | complete |        1 | 2026-06-23 17:26:47.709993+00 | 2026-06-23 17:26:47.712008+00 | 2026-06-23 17:26:50.589436+00 |
(1 row)
```

The worker uses normal database state as its coordination surface. Jobs are claimed from `otlet.jobs`, outputs are written to Otlet tables, and worker events are visible in `otlet.worker_events`

## 9. Read The Model Output

```sql
SELECT
  v.id,
  v.entity_name,
  r.status,
  r.output ->> 'decision' AS decision,
  r.output ->> 'risk_level' AS risk_level,
  r.output ->> 'next_step' AS next_step,
  r.receipt_id,
  r.prompt_tokens,
  r.generated_tokens,
  r.generate_ms,
  r.tokens_per_second
FROM public.counterparty_review_case v
JOIN otlet.runs r
  ON r.subject_id = v.id::text
WHERE r.task_name = 'counterparty_review_task';
```

Representative output:

```text
 id |   entity_name   |  status  |   decision   | risk_level |   next_step   | receipt_id | prompt_tokens | generated_tokens | generate_ms | tokens_per_second
----+-----------------+----------+--------------+------------+---------------+------------+---------------+------------------+-------------+-------------------
  1 | Bad Invoice LLC | complete | needs_review | high       | manual_review |          2 |           323 |               71 |        1183 | 60.01690617075232
(1 row)
```

`otlet.runs` is a convenience view over jobs, outputs, and receipts

Otlet stores the result as database state. You do not have to scrape a terminal response

## 10. Inspect The Typed Action

```sql
SELECT
  a.action_type,
  a.status,
  a.payload
FROM otlet.actions a
JOIN otlet.jobs j ON j.id = a.job_id
WHERE j.task_name = 'counterparty_review_task';
```

Representative output:

```text
  action_type  |  status  |                                                                                              payload
---------------+----------+----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 create_record | complete | {"body": {"decision": "needs_review", "next_step": "manual_review", "risk_level": "high", "needs_review": true}, "type": "create_record", "subject_id": "1", "record_type": "counterparty_review"}
(1 row)
```

The model can propose an action. Otlet keeps the action vocabulary narrow

The example allows `create_record`. It writes an internal Otlet record and leaves `public.counterparty_review_case` alone

That gives v0 a useful write path without granting broad write authority to the model

## 11. Inspect The Otlet-Owned Record

```sql
SELECT
  rec.record_type,
  rec.subject_id,
  rec.body
FROM otlet.records rec
JOIN otlet.actions a ON a.id = rec.action_id
JOIN otlet.jobs j ON j.id = a.job_id
WHERE j.task_name = 'counterparty_review_task';
```

Representative output:

```text
     record_type     | subject_id |                                                  body
---------------------+------------+--------------------------------------------------------------------------------------------------------
 counterparty_review | 1          | {"decision": "needs_review", "next_step": "manual_review", "risk_level": "high", "needs_review": true}
(1 row)
```

Otlet turns fuzzy model output into typed database state here

The source row remains source data. The Otlet record is a derived fact with provenance back to a job, action, output, model, prompt hash, input hash, schema hash, and receipt

## 12. Read The Receipt

```sql
SELECT
  receipt_id,
  task_name,
  subject_id,
  status,
  model_name,
  runtime_name,
  prompt_tokens,
  generated_tokens,
  generate_ms,
  tokens_per_second,
  schema_validation_status,
  stop_reason,
  schema_force,
  model_cache_hit,
  inference_cache_hit
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'counterparty_review_task';
```

Representative output:

```text
 receipt_id |        task_name         | subject_id |  status  |    model_name    | runtime_name  | prompt_tokens | generated_tokens | generate_ms | tokens_per_second | schema_validation_status |  stop_reason  |              schema_force              | model_cache_hit | inference_cache_hit
------------+--------------------------+------------+----------+------------------+---------------+---------------+------------------+-------------+-------------------+--------------------------+---------------+----------------------------------------+-----------------+---------------------
          2 | counterparty_review_task | 1          | complete | linked_qwen_0_6b | linked_inproc |           323 |               71 |        1183 | 60.01690617075232 | passed                   | json_complete | post_generation_json_schema_validation | t               | f
(1 row)
```

A receipt records evidence for one model run

It links the model, artifact, runtime options, prompt hash, input hash, output schema hash, raw output hash, validation status, timing, token counts, memory summary, and trace summary

Otlet stores receipts when jobs fail because failures produce evidence too

## 13. Inspect Runtime Residency

```sql
SELECT
  runtime_name,
  endpoint,
  runtime_status,
  model_name,
  slot_state,
  model_residency_policy,
  active_jobs,
  model_memory_bytes,
  model_parameters,
  context_window_tokens,
  worker_process_rss_bytes,
  worker_process_virtual_bytes,
  inference_cache_entries,
  inference_cache_max_entries,
  inference_cache_bytes,
  inference_cache_max_bytes,
  inference_cache_last_reason
FROM otlet.runtime_status
WHERE runtime_name = 'linked_inproc';
```

Representative output:

```text
 runtime_name  | endpoint | runtime_status |    model_name    | slot_state |        model_residency_policy        | active_jobs | model_memory_bytes | model_parameters | context_window_tokens | worker_process_rss_bytes | worker_process_virtual_bytes | inference_cache_entries | inference_cache_max_entries | inference_cache_bytes | inference_cache_max_bytes |  inference_cache_last_reason
---------------+----------+----------------+------------------+------------+--------------------------------------+-------------+--------------------+------------------+-----------------------+--------------------------+------------------------------+-------------------------+-----------------------------+-----------------------+---------------------------+-------------------------------
 linked_inproc | linked   | ready          | linked_qwen_0_6b | ready      | resident_worker_loaded_model_context |           0 |          633495552 |        596049920 |                  4096 |               1229848576 |                   1823137792 |                       0 |                         128 |                     0 |                   1048576 | disabled_for_generation_trace
(1 row)
```

Otlet exposes model residency here

The worker keeps the local model/context warm across jobs. SQL can see the slot state, memory sample, context window, cache entries, cache bounds, and the last cache reason

Otlet favors observability. SQL should show whether the model loaded, is busy, failed, cached, or went over budget

## 14. Inspect Token Traces

The task enabled bounded generation tracing:

```json
{
  "generation_trace": true,
  "generation_trace_max_tokens": 16,
  "generation_trace_top_k": 3
}
```

That stores a bounded trace summary on the receipt instead of storing an unbounded prompt or logits blob

Look at the token steps:

```sql
SELECT
  receipt_id,
  step,
  token_id,
  token_text_readable,
  chosen_probability,
  chosen_rank,
  stop_reason
FROM otlet.inference_receipt_token_trace
WHERE task_name = 'counterparty_review_task'
ORDER BY receipt_id, step
LIMIT 5;
```

Representative output:

```text
 receipt_id | step | token_id | token_text_readable | chosen_probability | chosen_rank |  stop_reason
------------+------+----------+---------------------+--------------------+-------------+---------------
          2 |    1 |     4710 |  \n\n               |           0.630815 |           1 | json_complete
          2 |    2 |     5097 | Output              |           0.383669 |           1 | json_complete
          2 |    3 |      510 | :\n                 |           0.714491 |           1 | json_complete
          2 |    4 |     4913 | {"                  |           0.925151 |           1 | json_complete
          2 |    5 |     3006 | output              |           0.999448 |           1 | json_complete
(5 rows)
```

Look at the top alternatives captured for each traced token:

```sql
SELECT
  receipt_id,
  step,
  alternative_rank,
  token_text_readable,
  probability
FROM otlet.inference_receipt_token_alternative_trace
WHERE task_name = 'counterparty_review_task'
ORDER BY receipt_id, step, alternative_rank
LIMIT 5;
```

Representative output:

```text
 receipt_id | step | alternative_rank | token_text_readable | probability
------------+------+------------------+---------------------+-------------
          2 |    1 |                1 |  \n\n               |    0.630815
          2 |    1 |                2 | }\n\n\n             |    0.068029
          2 |    1 |                3 |  \n                 |     0.03416
          2 |    2 |                1 | Output              |    0.383669
          2 |    2 |                2 | The                 |    0.072367
(5 rows)
```

Trace data records:

- Prompt tokens used by the row
- Model tokens generated
- Generation stop reason
- Were probabilities available from llama.cpp logits
- Receipt, row identity, input hash, and schema hash attached to the trace
- Did this run use the resident model cache or inference-output cache

Otlet bounds tracing so prompt, token, and logits storage does not turn observability into a data retention problem

## 15. Check The Whole Chain

```sql
SELECT
  (SELECT count(*) FROM otlet.outputs o JOIN otlet.jobs j ON j.id = o.job_id WHERE j.task_name = 'counterparty_review_task') AS outputs,
  (SELECT count(*) FROM otlet.actions a JOIN otlet.jobs j ON j.id = a.job_id WHERE j.task_name = 'counterparty_review_task') AS actions,
  (SELECT count(*) FROM otlet.records r JOIN otlet.actions a ON a.id = r.action_id JOIN otlet.jobs j ON j.id = a.job_id WHERE j.task_name = 'counterparty_review_task') AS records,
  (SELECT count(*) FROM otlet.inference_receipts r WHERE r.task_name = 'counterparty_review_task') AS receipts;
```

Representative output:

```text
 outputs | actions | records | receipts
---------+---------+---------+----------
       1 |       1 |       1 |        1
(1 row)
```

That count covers the v0 shape:

```text
one source row
one job
one validated output
one typed action
one Otlet-owned record
one receipt
bounded trace state
SQL-visible runtime state
```

## 16. Bad Output

If the model returns invalid JSON or a value outside the schema, Otlet fails closed

You should expect:

- `otlet.jobs.status = 'failed'`
- `otlet.jobs.error` contains the validation or parse failure
- raw model text is kept for inspection
- no validated `otlet.outputs` row is stored
- no `otlet.actions` row is executed
- no `otlet.records` row is created
- an error receipt preserves the model/runtime evidence when available

The task schema and action rules decide whether model output can become database truth

## 17. Semantic Indexes

The direct task path gives you the shortest way to learn Otlet

Semantic indexes are the next layer. They are for repeated lookup over source rows, stale-row tracking, refresh decisions, native FDW reads, and source-row CustomScan predicates

Use a direct task when:

- you want to review or transform a known batch of rows
- you want to inspect jobs, outputs, actions, records, receipts, and traces directly
- you are still designing the model contract

Use a semantic index when:

- you want model-derived state to be reusable in normal queries
- source rows change and stale results must fail closed
- lookup should skip rows whose source hash is already fresh
- you want executor-visible semantic access through FDW or CustomScan paths

The direct task path teaches the Otlet contract. The semantic path adds query ergonomics and freshness policy on top of that contract

## 18. Map The Otlet Schema

The direct task path gives you the smallest loop. The rest of Otlet uses the same tables

Use the catalog to see the durable state Otlet owns:

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'otlet'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;
```

Representative output:

```text
        table_name
---------------------------
 actions
 inference_receipts
 jobs
 model_versions
 models
 outputs
 records
 runtime_slots
 runtimes
 semantic_action_programs
 semantic_indexes
 semantic_join_indexes
 semantic_join_programs
 semantic_materializations
 semantic_programs
 tasks
 worker_events
(17 rows)
```

The base tables split into a few jobs:

- `runtimes`, `models`, `model_versions`, and `runtime_slots` describe the local model runtime
- `tasks` and `jobs` describe durable work
- `outputs`, `actions`, `records`, `inference_receipts`, and `worker_events` describe what happened
- `semantic_indexes`, `semantic_materializations`, and semantic program tables make model-derived state queryable
- `semantic_join_indexes` and `semantic_join_programs` do the same for pairwise candidate rows

The read models and planner surfaces are views:

```sql
SELECT table_name
FROM information_schema.views
WHERE table_schema = 'otlet'
ORDER BY table_name
LIMIT 11;
```

Representative output:

```text
                table_name
-------------------------------------------
 demo_semantic_vendor_idx_source
 inference_receipt_token_alternative_trace
 inference_receipt_token_trace
 inference_receipt_trace_status
 inference_trace_alternatives
 inference_trace_chain
 inference_trace_summary
 inference_trace_timeline
 inference_visibility_status
 model_access_status
 runs
(11 rows)
```

Use `otlet.runs` for application reads. Use trace and status views for debugging, proof, and learning

## 19. Group The SQL API Surface

Otlet exposes many SQL functions around a small set of concepts

```sql
SELECT
  CASE
    WHEN proname LIKE '%semantic_join%' THEN 'semantic join'
    WHEN proname LIKE '%semantic%' THEN 'semantic index and predicates'
    WHEN proname LIKE '%task%' OR proname LIKE '%scan%' THEN 'tasks and scans'
    WHEN proname LIKE '%job%' THEN 'job lifecycle'
    WHEN proname LIKE '%runtime%' OR proname LIKE '%model%' OR proname LIKE '%worker%' THEN 'runtime and worker'
    ELSE 'other'
  END AS area,
  count(*)
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'otlet'
GROUP BY area
ORDER BY area;
```

Representative output:

```text
             area              | count
-------------------------------+-------
 job lifecycle                 |     6
 other                         |     3
 runtime and worker            |    10
 semantic index and predicates |    50
 semantic join                 |    21
 tasks and scans               |     6
(6 rows)
```

The count looks large because Postgres needs separate functions for planner hooks, predicates, materialization, direct lookup, auto lookup, and typed refs

You mostly use these groups:

- register a runtime and model
- create a task or semantic index
- enqueue or scan work
- inspect jobs, runs, receipts, traces, and runtime state
- materialize and query semantic state
- use planner-visible predicates through FDW or CustomScan

## 20. Plan Work Before Running It

`otlet.inference_scan_plan` tells you what a direct task would enqueue before you run it

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
  'linked_qwen_0_6b',
  '{"temperature":0,"max_tokens":64,"reasoning":"off"}'::jsonb
);

SELECT * FROM otlet.inference_scan_plan('learning_retry_task');
```

Representative output:

```text
        name         | has_input_query |    model_name
---------------------+-----------------+------------------
 learning_retry_task | t               | linked_qwen_0_6b
(1 row)

      task_name      |    model_name    | runtime_name  | input_rows | active_rows | queueable_rows | avg_generate_ms | estimated_model_ms |        model_residency_policy
---------------------+------------------+---------------+------------+-------------+----------------+-----------------+--------------------+--------------------------------------
 learning_retry_task | linked_qwen_0_6b | linked_inproc |          1 |           0 |              1 |             999 |                999 | resident_worker_loaded_model_context
(1 row)
```

`input_rows` counts task query results. `active_rows` counts rows already queued or running for the same task and subject. `queueable_rows` counts what Otlet can enqueue now

Semantic indexes use the same planning idea later. Direct tasks expose it first

## 21. Cancel Queued Work

Cancellation changes job lifecycle state

Use a queued job that the worker has not claimed yet:

```sql
SELECT name, model_name
FROM otlet.register_task(
  'learning_cancel_task',
  'Lifecycle task used to show queued cancellation',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  'linked_qwen_0_6b',
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
 learning_cancel_task | linked_qwen_0_6b
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

## 22. Understand Retry And Failed-Run Evidence

Otlet leaves failed jobs visible. A failed job is terminal, so the same task and subject can be queued again

The partial unique index only blocks duplicate active work:

```sql
CREATE UNIQUE INDEX jobs_active_subject_idx
ON otlet.jobs (task_name, subject_id)
WHERE status IN ('queued', 'running', 'cancel_requested');
```

This run created one synthetic failed job, then allowed `run_task` to enqueue a second job for the same subject

The real worker claimed the second job and rejected the output against the strict JSON contract:

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

## 23. Check Worker Events And Receipt Statuses

Events are the operational trail. Receipts are the inference trail

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
 job_completed |     1
 job_failed    |     2
 job_started   |     1
(4 rows)

           task_name           |  status  | count
-------------------------------+----------+-------
 learning_action_boundary_task | complete |     1
 learning_cancel_task          | canceled |     1
 learning_retry_task           | failed   |     2
(3 rows)
```

Use events for worker behavior. Use receipts for model behavior

## 24. Learn The Action Boundary

Otlet keeps the v0 action vocabulary narrow

`create_record` can create an Otlet-owned record. Otlet captures unsupported action types as rejected actions and does not mutate user tables:

```sql
SELECT name, model_name
FROM otlet.register_task(
  'learning_action_boundary_task',
  'Lifecycle task used to show rejected action types',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  'linked_qwen_0_6b',
  '{}'::jsonb
);

INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at)
VALUES ('learning_action_boundary_task', 'action-1', '{"kind":"manual running job"}'::jsonb, 'running', 1, now())
RETURNING id, task_name, subject_id, status, attempts;

SELECT job_id, output
FROM otlet.complete_job(
  (SELECT id FROM otlet.jobs WHERE task_name = 'learning_action_boundary_task' AND subject_id = 'action-1'),
  '{"status":"ok"}'::jsonb,
  '{"output":{"status":"ok"},"actions":[{"type":"update_source_table","table":"public.anything"}]}',
  '[{"type":"update_source_table","table":"public.anything"}]'::jsonb
);

SELECT a.action_type, a.status, a.error, count(r.id) AS records_created
FROM otlet.actions a
LEFT JOIN otlet.records r ON r.action_id = a.id
JOIN otlet.jobs j ON j.id = a.job_id
WHERE j.task_name = 'learning_action_boundary_task'
GROUP BY a.action_type, a.status, a.error
ORDER BY a.action_type;
```

Representative output:

```text
             name              |    model_name
-------------------------------+------------------
 learning_action_boundary_task | linked_qwen_0_6b
(1 row)

 id |           task_name           | subject_id | status  | attempts
----+-------------------------------+------------+---------+----------
 10 | learning_action_boundary_task | action-1   | running |        1
(1 row)

 job_id |      output
--------+------------------
     10 | {"status": "ok"}
(1 row)

     action_type     |  status  |          error          | records_created
---------------------+----------+-------------------------+-----------------
 update_source_table | rejected | unsupported action type |               0
(1 row)
```

Otlet draws the write-authority line here. The model can ask, but Otlet decides which action types can become database state

## 25. Materialize Records Into Semantic State

Actions and records are one layer. Semantic materializations are the reusable query layer over those records

This sequence materializes an entity-pair record, watches source changes, and marks the record stale through an update trigger:

```sql
SELECT record_type, subject_id, body, stale, source_table
FROM otlet.semantic_materializations
WHERE record_type = 'entity_hypothesis'
ORDER BY id;

SELECT otlet.refresh_semantic_materializations('entity_hypothesis') AS refreshed_materializations;

SELECT otlet.watch_semantic_stale('public.otlet_entity_vendor'::regclass, 'id') AS stale_trigger_name;

UPDATE public.otlet_entity_vendor
SET city = 'Austin Learning'
WHERE id = 1;

SELECT count(*) AS stale_materializations
FROM otlet.semantic_materializations
WHERE record_type = 'entity_hypothesis'
  AND stale;
```

Representative output:

```text
    record_type    | subject_id |                                          body                                           | stale |        source_table
-------------------+------------+-----------------------------------------------------------------------------------------+-------+----------------------------
 entity_hypothesis | 1:2        | {"match": "yes", "reason": "same normalized name, phone, and city", "confidence": 0.95} | t     | public.otlet_entity_vendor
(1 row)

 refreshed_materializations
----------------------------
                          1
(1 row)

      stale_trigger_name
------------------------------
 otlet_stale_f2ddcf358c8f1d1f
(1 row)

UPDATE 1

 stale_materializations
------------------------
                      1
(1 row)
```

The trigger does not rerun the model. It marks the previous derived fact stale so reads can fail closed or request refresh

## 26. Build A Semantic Index

A semantic index wraps a source table with an Otlet task, materialized records, stale tracking, a source view, and a native FDW table

The creation shape is:

```sql
SELECT otlet.create_semantic_index(
  'demo_semantic_vendor_idx',
  'public.otlet_demo_semantic_vendor'::regclass,
  'id',
  'Otlet demo semantic index. Return exactly this JSON object for every input row: {"output":{"status":"needs_review","needs_review":true,"issues":["demo semantic index"]},"actions":[{"type":"create_record","record_type":"demo_semantic_fact","subject_id":"db-owned","body":{"status":"needs_review","needs_review":true,"semantic":"indexed row"}}]}',
  '{
    "type": "object",
    "required": ["status", "needs_review", "issues"],
    "additionalProperties": false,
    "properties": {
      "status": {"enum": ["needs_review"]},
      "needs_review": {"type": "boolean"},
      "issues": {"type": "array", "items": {"type": "string"}}
    }
  }'::jsonb,
  'linked_qwen_0_6b',
  '{"temperature":0,"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":12,"generation_trace_top_k":3}'::jsonb,
  'demo_semantic_fact'
);

SELECT otlet.refresh_semantic_index('demo_semantic_vendor_idx') AS queued;

DO $$
DECLARE
  active_jobs bigint;
  complete_jobs bigint;
  failed_jobs bigint;
BEGIN
  FOR i IN 1..180 LOOP
    SELECT
      count(*) FILTER (WHERE status IN ('queued','running','cancel_requested')),
      count(*) FILTER (WHERE status = 'complete'),
      count(*) FILTER (WHERE status IN ('failed','canceled'))
    INTO active_jobs, complete_jobs, failed_jobs
    FROM otlet.jobs
    WHERE task_name = 'demo_semantic_vendor_idx_task';

    IF failed_jobs > 0 THEN
      RAISE EXCEPTION 'semantic index refresh failed';
    END IF;

    IF complete_jobs >= 3 AND active_jobs = 0 THEN
      RETURN;
    END IF;

    PERFORM pg_sleep(1);
  END LOOP;

  RAISE EXCEPTION 'timed out waiting for semantic index refresh';
END $$;

SELECT otlet.materialize_semantic_index('demo_semantic_vendor_idx') AS materialized;
```

Compact output from the demo run:

```text
semantic_index_refresh_queued=3
semantic_index_materialized=3
```

Once materialized, the index has planner-visible status:

```sql
SELECT name, task_name, source_table, ready_rows, stale_rows, active_jobs, completed_jobs
FROM otlet.semantic_index_status
WHERE name = 'demo_semantic_vendor_idx';

SELECT selected_path, reason, total_rows, ready_rows, stale_rows, refresh_rows, freshness
FROM otlet.semantic_index_plan('demo_semantic_vendor_idx');
```

Representative output:

```text
           name           |           task_name           |           source_table            | ready_rows | stale_rows | active_jobs | completed_jobs
--------------------------+-------------------------------+-----------------------------------+------------+------------+-------------+----------------
 demo_semantic_vendor_idx | demo_semantic_vendor_idx_task | public.otlet_demo_semantic_vendor |          3 |          0 |           0 |              4
(1 row)

  selected_path  |           reason           | total_rows | ready_rows | stale_rows | refresh_rows | freshness
-----------------+----------------------------+------------+------------+------------+--------------+-----------
 semantic_lookup | semantic index fully fresh |          3 |          3 |          0 |            0 |    1.0000
(1 row)
```

`semantic_index_plan` is Otlet deciding whether it can reuse materialized state, should refresh, should wait, or should run fresh inference

## 27. Read Through FDW And The Source View

`create_semantic_index` also creates a native foreign table and a source view

The FDW table holds materialized semantic state:

```sql
SELECT subject_id, body, stale
FROM otlet.demo_semantic_vendor_idx_native
ORDER BY subject_id;
```

Representative output:

```text
 subject_id |                                    body                                     | stale
------------+-----------------------------------------------------------------------------+-------
 1          | {"status": "needs_review", "semantic": "indexed row", "needs_review": true} | f
 2          | {"status": "needs_review", "semantic": "indexed row", "needs_review": true} | f
 3          | {"status": "needs_review", "semantic": "indexed row", "needs_review": true} | f
(3 rows)
```

The source view joins source rows to their semantic state:

```sql
SELECT id, name, otlet_semantic_ready, otlet_semantic_stale, otlet_semantic_body
FROM otlet.demo_semantic_vendor_idx_source
ORDER BY id;
```

Representative output:

```text
 id |     name      | otlet_semantic_ready | otlet_semantic_stale |                             otlet_semantic_body
----+---------------+----------------------+----------------------+-----------------------------------------------------------------------------
  1 | Demo Vendor 1 | t                    | f                    | {"status": "needs_review", "semantic": "indexed row", "needs_review": true}
  2 | Demo Vendor 2 | t                    | f                    | {"status": "needs_review", "semantic": "indexed row", "needs_review": true}
  3 | Demo Vendor 3 | t                    | f                    | {"status": "needs_review", "semantic": "indexed row", "needs_review": true}
(3 rows)
```

Use the FDW table for semantic rows. Use the source view for source rows plus semantic columns

## 28. Inspect The Native FDW Plan

The native table uses `otlet_semantic_fdw`

```sql
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM otlet.demo_semantic_vendor_idx_native
WHERE subject_id = '2';
```

Representative output excerpt:

```text
Foreign Scan on otlet.demo_semantic_vendor_idx_native  (cost=0.00..1.05 rows=1 width=129) (actual rows=1.00 loops=1)
  Output: subject_id, body, stale, source_hash, updated_at
  Filter: (demo_semantic_vendor_idx_native.subject_id = '2'::text)
  Otlet Node: Semantic Foreign Scan
  Executor Boundary: Foreign Scan
  Stale Result Policy: fail_closed_zero_subject_rows_until_worker_refresh_commits
  Worker Handoff: shared_memory_xact_commit_latch
  Access Kind: semantic_index
  Selected Path: semantic_lookup
  Reason: pushed subject rows fresh
  Task Name: demo_semantic_vendor_idx_task
  Total Rows: 1
  Refresh Rows: 0
  Freshness: 1.00
  Actual Rows Loaded: 1
  Actual Rows Emitted: 1
  Pushed Subject Id: 2
```

The FDW runs inside Postgres as a native access path over Otlet-owned semantic materializations

## 29. Compile Semantic Programs

Semantic programs turn a reusable text predicate into a stored expected JSON shape

The demo already compiled these two programs:

```sql
SELECT name, index_name, expected, program_hash
FROM otlet.semantic_programs
WHERE name = 'demo_vendor_needs_review';

SELECT name, index_name, action_type, expected, program_hash
FROM otlet.semantic_action_programs
WHERE name = 'demo_vendor_action_indexed';
```

Representative output:

```text
           name           |        index_name        |          expected          |           program_hash
--------------------------+--------------------------+----------------------------+----------------------------------
 demo_vendor_needs_review | demo_semantic_vendor_idx | {"status": "needs_review"} | 5c201902979781d1fdf36416efbe4373
(1 row)

            name            |        index_name        |  action_type  |                                  expected                                  |           program_hash
----------------------------+--------------------------+---------------+----------------------------------------------------------------------------+----------------------------------
 demo_vendor_action_indexed | demo_semantic_vendor_idx | create_record | {"body": {"semantic": "indexed row"}, "record_type": "demo_semantic_fact"} | 74179009d163da1fc16d8542741245a1
(1 row)
```

Then predicates can use explicit JSON, a compiled output program, or a compiled action program:

```sql
SELECT v.id,
       otlet.semantic_matches('demo_semantic_vendor_idx', v.id::text, '{"status":"needs_review"}'::jsonb) AS direct_match,
       otlet.semantic_matches_program('demo_vendor_needs_review', v.id::text) AS program_match,
       otlet.semantic_action_matches_program('demo_vendor_action_indexed', v.id::text) AS action_match
FROM public.otlet_demo_semantic_vendor v
ORDER BY v.id;
```

Representative output:

```text
 id | direct_match | program_match | action_match
----+--------------+---------------+--------------
  1 | t            | t             | t
  2 | t            | t             | t
  3 | t            | t             | t
(3 rows)
```

Otlet deduplicates programs by hash for each index. The same predicate cannot hide under a second name as unrelated logic

## 30. Use CustomScan For Source-Row Predicates

Otlet can own a semantic predicate against the source table through a CustomScan

```sql
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM public.otlet_demo_semantic_vendor v
WHERE otlet.semantic_matches('demo_semantic_vendor_idx', v.id::text, '{"status":"needs_review"}'::jsonb);
```

Representative output excerpt:

```text
Custom Scan (Otlet Semantic Source CustomScan) on public.otlet_demo_semantic_vendor v  (cost=1.00..4.14 rows=3 width=144) (actual rows=3.00 loops=1)
  Output: id, name, email, phone, city, updated_at
  Otlet Node: Semantic Source CustomScan
  Semantic Predicate Owner: otlet_customscan_executor
  Child Semantic Filter: stripped_before_child_plan
  Semantic Index: demo_semantic_vendor_idx
  Semantic Predicate Kind: materialization
  Semantic Predicate: {"status":"needs_review"}
  Refresh Policy: fail_closed_no_refresh
  Worker Handoff: none_for_fail_closed_lookup
  Planner Semantic Reason: all source rows resolved from fresh semantic state; fresh=3
  Planner Source Rows: 3
  Planner Fresh Match Rows: 3
  Planner Stale Rows: 0
  Rows Seen: 3
  Rows Returned: 3
  Semantic Cache Hits: 3
  Semantic Cache Misses: 0
  ->  Seq Scan on public.otlet_demo_semantic_vendor v
```

The child scan reads the source table. Otlet strips the semantic predicate from the child plan and evaluates it against preloaded semantic state

## 31. Fail Closed On Stale Rows

Changing a source row makes its materialized semantic state stale

```sql
UPDATE public.otlet_demo_semantic_vendor
SET email = 'learning-stale@example.test', updated_at = clock_timestamp()
WHERE id = 2;

SELECT name, ready_rows, stale_rows, active_jobs
FROM otlet.semantic_index_status
WHERE name = 'demo_semantic_vendor_idx';

SELECT count(*) AS fail_closed_rows
FROM public.otlet_demo_semantic_vendor v
WHERE v.id = 2
  AND otlet.semantic_matches('demo_semantic_vendor_idx', v.id::text, '{"status":"needs_review"}'::jsonb, 1, false);
```

Representative output:

```text
UPDATE 1

           name           | ready_rows | stale_rows | active_jobs
--------------------------+------------+------------+-------------
 demo_semantic_vendor_idx |          2 |          1 |           0
(1 row)

 fail_closed_rows
------------------
                0
(1 row)
```

Fail closed means stale facts do not match because old model output looked right

## 32. Let CustomScan Refresh A Stale Row With Infer-Now

`semantic_matches_auto` lets a source-table query use bounded infer-now for stale or missing rows

```sql
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_semantic_vendor v
WHERE otlet.semantic_matches_auto('demo_semantic_vendor_idx', v.id::text, '{"status":"needs_review"}'::jsonb, 0, 15000, 1, false);
```

Representative output excerpt:

```text
Custom Scan (Otlet Semantic Source CustomScan) on public.otlet_demo_semantic_vendor v  (cost=1.00..12.17 rows=3 width=8) (actual rows=3.00 loops=1)
  Otlet Node: Semantic Source CustomScan
  Semantic Predicate Owner: otlet_customscan_executor
  Semantic Index: demo_semantic_vendor_idx
  Refresh Policy: auto_lookup_wait_infer_refresh_fail_closed
  Worker Handoff: auto_resident_worker_wait_infer_or_commit_latch
  Infer Now Timeout Ms: 15000
  Infer Now Max Rows: 1
  Infer Now Admission Policy: bounded_shared_memory_infer_queue_4_slots
  Infer Now Input Path: tuple_slot_mvcc_json_no_spi
  Planner Semantic Reason: auto semantic policy: fresh=2 wait=0 infer=1 queue=0 fail_closed=0
  Planner Stale Rows: 1
  Actual Lookup Rows: 2
  Actual Infer Resolved Rows: 1
  Actual Infer Returned Rows: 1
  Infer Now Batches: 1
  Infer Now Receipts: 1
  Infer Now Outputs: 1
  Infer Now Actions: 1
  Infer Now Materializations: 1
  Infer Now Trace Receipt Id: 14
  Infer Now Trace Version: otlet_generation_trace_v1
  Infer Now Detailed Trace Captured Tokens: 12
  Infer Now Detailed Trace Top K: 3
```

The executor refreshed the stale row with a bounded infer-now budget and a receipt

Inspect that receipt:

```sql
SELECT receipt_id, task_name, subject_id, executor_origin, executor_node, semantic_index_name, stale_policy, status, prompt_tokens, generated_tokens
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'demo_semantic_vendor_idx_task'
  AND subject_id = '2'
ORDER BY receipt_id DESC
LIMIT 1;
```

Representative output:

```text
 receipt_id |           task_name           | subject_id |   executor_origin    |          executor_node           |   semantic_index_name    |            stale_policy             |  status  | prompt_tokens | generated_tokens
------------+-------------------------------+------------+----------------------+----------------------------------+--------------------------+-------------------------------------+----------+---------------+------------------
         14 | demo_semantic_vendor_idx_task | 2          | customscan_infer_now | Otlet Semantic Source CustomScan | demo_semantic_vendor_idx | fail_closed_no_silent_stale_results | complete |           362 |               62
(1 row)
```

Receipts carry executor provenance because the same model task can run from the worker queue or from CustomScan infer-now

## 33. Read The Planner Decision Ledger

`otlet.explain_semantic_index_plan` compresses the status, cost, executor boundary, and worker scheduling decisions into SQL rows

```sql
SELECT step_order, node, detail
FROM otlet.explain_semantic_index_plan('demo_semantic_vendor_idx')
ORDER BY step_order;
```

Representative output:

```text
 step_order |         node         | detail
------------+----------------------+-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
          1 | SemanticIndexStats   | {"freshness": 1.0000, "index_name": "demo_semantic_vendor_idx", "ready_rows": 3, "stale_rows": 0, "total_rows": 3, "missing_rows": 0, "refresh_rows": 0, "source_table": "public.otlet_demo_semantic_vendor", "refresh_coverage": 1.0000}
          2 | SemanticIndexCost    | {"lookup_ms": 1.15, "fresh_inference_ms": 3303.00, "refresh_then_lookup_ms": 1.15}
          3 | SemanticPathDecision | {"reason": "semantic index fully fresh", "allow_refresh": true, "min_freshness": 1, "selected_path": "semantic_lookup"}
          4 | ExecutorBoundary     | {"selected_node": "Foreign Scan via otlet_semantic_fdw plus Custom Scan via set_rel_pathlist_hook", "worker_handoff": "shared_memory_xact_commit_latch", "native_pushdown": "fdw_pushdown_subject_body_stale_source_hash", "custom_path_status": "selected_for_semantic_matches", "default_source_view": "otlet.demo_semantic_vendor_idx_source", "planner_hook_status": "installed_semantic_matches", "stale_result_policy": "fail_closed_zero_subject_rows_until_worker_refresh_commits", "default_source_view_exists": true}
          5 | WorkerScheduling     | {"state": {"handoff": "shared_memory_xact_commit_latch", "worker_pid": 41, "wake_aborts": 0, "wake_misses": 0, "wake_commits": 7, "wake_requests": 8, "wake_successes": 8, "worker_wake_cycles": 206, "worker_jobs_drained": 9, "worker_registrations": 1, "worker_max_drain_count": 3, "missed_wake_recovery_ms": 5000, "worker_last_drain_count": 0, "worker_latch_registered": true, "worker_lifecycle_policy": "clear_latch_on_clean_stop_and_reregister_on_postmaster_restart", "worker_empty_wake_cycles": 199}, "infer_now_state": "idle", "infer_now_timeouts": 0, "infer_now_slot_count": 4, "infer_now_queue_depth": 0, "scheduler_status_rows": 1, "infer_now_busy_rejections": 0, "infer_now_available_slots": 4}
(5 rows)
```

This ledger explains why Otlet chose a semantic access path

## 34. Build A Semantic Join Index

Semantic indexes are row-oriented. Semantic join indexes are pair-oriented

The candidate query supplies `subject_id` and `input` for candidate pairs:

```sql
SELECT otlet.drop_semantic_join_index('learning_entity_pair_idx');

DROP TABLE IF EXISTS public.learning_entity;

CREATE TABLE public.learning_entity (
  id bigint PRIMARY KEY,
  name text NOT NULL,
  phone text NOT NULL,
  city text NOT NULL
);

INSERT INTO public.learning_entity VALUES
  (1, 'Acme Logistics LLC', '512-555-0100', 'Austin'),
  (2, 'ACME Logistics', '512-555-0100', 'Austin');

SELECT name, task_name, record_type, max_candidate_rows
FROM otlet.create_semantic_join_index(
  'learning_entity_pair_idx',
  $$
    SELECT
      a.id::text || ':' || b.id::text AS subject_id,
      jsonb_build_object('left', to_jsonb(a), 'right', to_jsonb(b)) AS input
    FROM public.learning_entity a
    JOIN public.learning_entity b ON a.id < b.id
  $$,
  'The two input entities are the same company. Return exactly this JSON object: {"output":{"match":"yes","confidence":0.95,"needs_review":false},"actions":[{"type":"create_record","record_type":"learning_entity_pair","subject_id":"1:2","body":{"match":"yes","confidence":0.95,"reason":"same phone and city"}}]}',
  '{"type":"object","required":["match","confidence","needs_review"],"additionalProperties":false,"properties":{"match":{"enum":["yes"]},"confidence":{"type":"number"},"needs_review":{"type":"boolean"}}}'::jsonb,
  'linked_qwen_0_6b',
  'learning_entity_pair',
  '{"temperature":0,"max_tokens":160,"reasoning":"off"}'::jsonb,
  10
);

SELECT otlet.refresh_semantic_join_index('learning_entity_pair_idx') AS queued_pairs;

DO $$
DECLARE
  active_jobs bigint;
  complete_jobs bigint;
  failed_jobs bigint;
BEGIN
  FOR i IN 1..180 LOOP
    SELECT
      count(*) FILTER (WHERE status IN ('queued','running','cancel_requested')),
      count(*) FILTER (WHERE status = 'complete'),
      count(*) FILTER (WHERE status IN ('failed','canceled'))
    INTO active_jobs, complete_jobs, failed_jobs
    FROM otlet.jobs
    WHERE task_name = 'learning_entity_pair_idx_task';

    IF failed_jobs > 0 THEN
      RAISE EXCEPTION 'semantic join refresh failed';
    END IF;

    IF complete_jobs >= 1 AND active_jobs = 0 THEN
      RETURN;
    END IF;

    PERFORM pg_sleep(1);
  END LOOP;

  RAISE EXCEPTION 'timed out waiting for semantic join refresh';
END $$;

SELECT otlet.materialize_semantic_join_index('learning_entity_pair_idx') AS materialized_pairs;
```

Representative output:

```text
           name           |           task_name           |     record_type      | max_candidate_rows
--------------------------+-------------------------------+----------------------+--------------------
 learning_entity_pair_idx | learning_entity_pair_idx_task | learning_entity_pair |                 10
(1 row)

 queued_pairs
--------------
            1
(1 row)

DO

 materialized_pairs
--------------------
                  1
(1 row)
```

Now inspect the join index:

```sql
SELECT name, task_name, total_pairs, ready_pairs, stale_pairs, missing_pairs, freshness
FROM otlet.semantic_join_index_stats('learning_entity_pair_idx');

SELECT subject_id, body, stale
FROM otlet.semantic_join_index_lookup('learning_entity_pair_idx')
ORDER BY subject_id;
```

Representative output:

```text
           name           |           task_name           | total_pairs | ready_pairs | stale_pairs | missing_pairs | freshness
--------------------------+-------------------------------+-------------+-------------+-------------+---------------+-----------
 learning_entity_pair_idx | learning_entity_pair_idx_task |           1 |           1 |           0 |             0 |    1.0000
(1 row)

 subject_id |                                 body                                  | stale
------------+-----------------------------------------------------------------------+-------
 1:2        | {"match": "yes", "reason": "same phone and city", "confidence": 0.95} | f
(1 row)
```

A semantic join index uses the same contract: jobs, outputs, actions, records, materializations, receipts

## 35. Query A Semantic Join Program

Join programs compile reusable pair predicates

```sql
SELECT name, index_name, expected, program_hash
FROM otlet.compile_semantic_join_program(
  'learning_join_same_company',
  'learning_entity_pair_idx',
  'match equals yes'
);

SELECT subject_id,
       otlet.semantic_join_matches('learning_entity_pair_idx', subject_id, '{"match":"yes"}'::jsonb) AS direct_match,
       otlet.semantic_join_matches_program('learning_join_same_company', subject_id) AS program_match
FROM otlet.semantic_join_index_lookup('learning_entity_pair_idx')
ORDER BY subject_id;
```

Representative output:

```text
            name            |        index_name        |     expected     |           program_hash
----------------------------+--------------------------+------------------+----------------------------------
 learning_join_same_company | learning_entity_pair_idx | {"match": "yes"} | b7ead8d08190dfa1eea552f190ed1cc0
(1 row)

 subject_id | direct_match | program_match
------------+--------------+---------------
 1:2        | t            | t
(1 row)
```

Use this as the join version of `semantic_matches_program`

## 36. Inspect Trace Visibility Across The System

The trace visibility view tells you whether receipts are linked to outputs, actions, token steps, top-k alternatives, provenance, stale policy, and CustomScan infer-now

```sql
SELECT
  receipt_count,
  detailed_trace_receipts,
  token_steps,
  top_k_alternatives,
  output_linked_receipts,
  action_linked_receipts,
  provenance_linked_receipts,
  customscan_trace_receipts,
  max_detailed_trace_tokens,
  max_detailed_trace_top_k
FROM otlet.inference_visibility_status;
```

Representative output after the demo:

```text
 receipt_count | detailed_trace_receipts | token_steps | top_k_alternatives | output_linked_receipts | action_linked_receipts | provenance_linked_receipts | customscan_trace_receipts | max_detailed_trace_tokens | max_detailed_trace_top_k
---------------+-------------------------+-------------+--------------------+------------------------+------------------------+----------------------------+---------------------------+---------------------------+--------------------------
            12 |                       5 |          64 |                192 |                      9 |                      8 |                          1 |                         1 |                        16 |                        3
(1 row)
```

The demo contract checked this as:

```text
inference_visibility_status=true|true|true|true|true|true
```

Those booleans prove receipts, token steps, top-k alternatives, CustomScan trace receipts, bounded trace tokens, and top-k width were present

## 37. Inspect Runtime Status After Advanced Runs

Runtime status shows the resident model slot, cache bounds, memory samples, and last run metrics

```sql
SELECT runtime_status || '|' ||
       slot_state || '|' ||
       COALESCE(tokens_per_second::text, '') || '|' ||
       (COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0))::text || '|' ||
       COALESCE(worker_memory_sample_policy, '') AS runtime_contract
FROM otlet.runtime_status
WHERE runtime_name = 'linked_inproc'
  AND model_name = 'linked_qwen_0_6b'
LIMIT 1;
```

Representative output from the demo run:

```text
runtime_status_contract=ready|ready|60.61|true|linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run
```

The value reports a ready runtime, a ready model slot, bounded cache entries, and Linux process-status memory sampling after a worker run

## 38. Know The Production Boundaries

Otlet installs internal tables and functions. Your application must add RLS policies, tenant roles, retention jobs, and approval workflows

Check row-level security:

```sql
SELECT relname, relrowsecurity
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'otlet'
  AND c.relkind = 'r'
ORDER BY relname;

SELECT count(*) AS installed_policies
FROM pg_policies
WHERE schemaname = 'otlet';
```

Representative output:

```text
          relname          | relrowsecurity
---------------------------+----------------
 actions                   | f
 inference_receipts        | f
 jobs                      | f
 model_versions            | f
 models                    | f
 outputs                   | f
 records                   | f
 runtime_slots             | f
 runtimes                  | f
 semantic_action_programs  | f
 semantic_indexes          | f
 semantic_join_indexes     | f
 semantic_join_programs    | f
 semantic_materializations | f
 semantic_programs         | f
 tasks                     | f
 worker_events             | f
(17 rows)

 installed_policies
--------------------
                  0
(1 row)
```

Check default grants visible through `information_schema`:

```sql
SELECT privilege_type, count(*)
FROM information_schema.role_table_grants
WHERE table_schema = 'otlet'
GROUP BY privilege_type
ORDER BY privilege_type;
```

Representative output:

```text
 privilege_type | count
----------------+-------
 DELETE         |    37
 INSERT         |    37
 REFERENCES     |    37
 SELECT         |    37
 TRIGGER        |    37
 TRUNCATE       |    37
 UPDATE         |    37
(7 rows)
```

Production policy belongs above this extension:

- create app roles that expose only the views and functions you want
- add RLS or schema isolation if multiple tenants share the database
- add retention policy for raw outputs, trace summaries, and receipts if your data policy requires it
- keep approval workflows outside model output, then consume Otlet records as evidence
- allow only the action types your application can safely interpret

## 39. Run The Full Demo Contract

The repo includes a script that exercises the broad path used in this learning file:

```sh
./scripts/otlet-demo.sh
```

Representative contract output from the demo run:

```text
row_review_contract=1|complete|true|1
action_receipt_contract=1|1|1|1
semantic_materialization_stale_rows=1
semantic_index_refresh_queued=3
semantic_index_materialized=3
model_access_status_contract=semantic_lookup|otlet.demo_semantic_vendor_idx_native|Foreign Scan via otlet_semantic_fdw plus Custom Scan via set_rel_pathlist_hook|installed_semantic_matches|selected_for_semantic_matches|fail_closed_zero_subject_rows_until_worker_refresh_commits|shared_memory_xact_commit_latch
semantic_program_hash=5c201902979781d1fdf36416efbe4373
semantic_action_program_hash=74179009d163da1fc16d8542741245a1
custom_scan_rows=3,3,3
semantic_index_stale_rows=1
stale_fail_closed_rows=0
trace_visibility_contract=true|true|true|otlet_generation_trace_v1|chosen_token_softmax_from_llama_logits|customscan_infer_now|Otlet Semantic Source CustomScan|demo_semantic_vendor_idx|fail_closed_no_silent_stale_results
inference_visibility_status=true|true|true|true|true|true
runtime_status_contract=ready|ready|60.61|true|linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run
docker_crash_log_scan=ok
```

Use that script as the compact regression proof. Use this Markdown to learn the same system
