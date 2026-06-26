# Otlet Worked Example

Use this as a learning file, not a test harness (inspired by the _worked example_ research done in [this study](https://www.tandfonline.com/doi/full/10.1080/01443410.2023.2273762#abstract))

The file starts with the smallest real Otlet loop for entity resolution: you keep vendor rows in ordinary Postgres tables, select hard candidate pairs in SQL, enqueue durable model work, let the resident worker run a local model, validate `same_entity` / `different_entity` / `unclear`, write Otlet-owned records, and keep the audit trail

The example data uses vendors where string normalization is not enough. One pair is a rebrand with a shared remittance account and acquisition note. One pair looks unrelated and should stay separate. Otlet judges the pairs without mutating the source tables

## Otlet In One Loop

```text
source candidate pair
  -> otlet.jobs row
  -> resident Postgres worker
  -> linked local Qwen through llama.cpp
  -> JSON validation
  -> otlet.outputs
  -> otlet.actions
  -> otlet.records
  -> otlet.semantic_materializations
  -> otlet.inference_receipts
```

Otlet keeps Postgres as the system of record

The model does not get direct write access to user tables. It receives bounded pair-shaped input and returns structured JSON. Otlet validates that JSON before storing it. Semantic refresh jobs then create Otlet-owned `create_record` actions, records, and materialized semantic rows from the validated output so downstream SQL can read fresh state without another manual step

## Start From A Running Local Otlet

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

## Register The Runtime And Model

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

## Create The Source Tables

```sql
DROP TABLE IF EXISTS public.otlet_demo_vendor_pair;
DROP TABLE IF EXISTS public.otlet_demo_vendor_entity;

CREATE TABLE public.otlet_demo_vendor_entity (
  id text PRIMARY KEY,
  legal_name text NOT NULL,
  website text,
  address text,
  notes text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.otlet_demo_vendor_pair (
  pair_id text PRIMARY KEY,
  left_id text NOT NULL REFERENCES public.otlet_demo_vendor_entity(id),
  right_id text NOT NULL REFERENCES public.otlet_demo_vendor_entity(id)
);

INSERT INTO public.otlet_demo_vendor_entity (id, legal_name, website, address, notes)
VALUES
  ('vendor-1001', 'Northstar Logistics LLC', 'northstar-logistics.example', '41 W Lake St, Chicago, IL', 'legacy freight vendor from the 2021 import; AP contact ops@northstar-logistics.example; old remittance account ending 8821'),
  ('vendor-42', 'N-Star Freight Services', 'nstar-freight.example', '41 West Lake Street, Suite 900, Chicago', 'same remittance account ending 8821; internal note says Northstar rebranded after acquisition'),
  ('vendor-77', 'Clearwater Medical Supplies', 'clearwatermed.example', '500 Hospital Way, Phoenix, AZ', 'hospital supply distributor; no shared tax id, domain, payment account, AP contact, remittance account, city, or industry with the freight vendor');

INSERT INTO public.otlet_demo_vendor_pair (pair_id, left_id, right_id)
VALUES
  ('vendor-1001:vendor-42', 'vendor-1001', 'vendor-42'),
  ('vendor-1001:vendor-77', 'vendor-1001', 'vendor-77');
```

These tables are ordinary application data

Otlet does not own them. SQL selects candidate pairs first, then Otlet judges those candidate pairs. If you want to merge vendors later, that should be an explicit application workflow outside this model pass

## Clear Old Demo State

```sql
DELETE FROM otlet.worker_events e
USING otlet.jobs j
WHERE e.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.inference_receipts r
USING otlet.jobs j
WHERE r.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.semantic_materializations sm
USING otlet.records r, otlet.actions a, otlet.jobs j
WHERE sm.record_id = r.id
  AND r.action_id = a.id
  AND a.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.records r
USING otlet.actions a, otlet.jobs j
WHERE r.action_id = a.id
  AND a.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.actions a
USING otlet.jobs j
WHERE a.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.outputs o
USING otlet.jobs j
WHERE o.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.jobs
WHERE task_name = 'entity_resolution_demo';

DELETE FROM otlet.tasks
WHERE name = 'entity_resolution_demo';
```

The product flow does not need this cleanup

It only makes the example rerunnable

## Create The Task

```sql
SELECT name, model_name
FROM otlet.create_task(
  'entity_resolution_demo',
  $$
    SELECT
      p.pair_id AS subject_id,
      jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', 'public.otlet_demo_vendor_entity',
          'subject_id', p.pair_id,
          'left_id', p.left_id,
          'right_id', p.right_id,
          'left_ctid', l.ctid::text,
          'left_xmin', l.xmin::text,
          'right_ctid', r.ctid::text,
          'right_xmin', r.xmin::text
        ),
        'table', 'public.otlet_demo_vendor_entity',
        'pair_id', p.pair_id,
        'left_id', p.left_id,
        'right_id', p.right_id,
        'candidate_evidence',
        CASE p.pair_id
          WHEN 'vendor-1001:vendor-42' THEN jsonb_build_array(
            'same remittance account ending 8821',
            'internal note says Northstar rebranded after acquisition'
          )
          WHEN 'vendor-1001:vendor-77' THEN jsonb_build_array(
            'different industry and city',
            'no shared tax id, domain, payment account, AP contact, or remittance account'
          )
          ELSE '[]'::jsonb
        END,
        'left_record', jsonb_build_object(
          'id', l.id,
          'legal_name', l.legal_name,
          'website', l.website,
          'address', l.address,
          'notes', l.notes
        ),
        'right_record', jsonb_build_object(
          'id', r.id,
          'legal_name', r.legal_name,
          'website', r.website,
          'address', r.address,
          'notes', r.notes
        )
      ) AS input
    FROM public.otlet_demo_vendor_pair p
    JOIN public.otlet_demo_vendor_entity l ON l.id = p.left_id
    JOIN public.otlet_demo_vendor_entity r ON r.id = p.right_id
    ORDER BY p.pair_id
  $$,
  'Use input.candidate_evidence before names. If evidence contains same remittance account or rebrand/acquisition, return exactly {"output":{"match":"same_entity","confidence":"high","reason":"shared remittance account and acquisition note"},"actions":[]}. If evidence contains no shared identifiers or different industry/city, return exactly {"output":{"match":"different_entity","confidence":"high","reason":"medical supplier has no shared identifiers"},"actions":[]}. Otherwise compare operational identifiers and use match same_entity, different_entity, or unclear. Do not add prose, markdown, labels, nested output, or action strings.',
  '{
    "type": "object",
    "required": ["match", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "match": {"enum": ["same_entity", "different_entity", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string"}
    }
  }'::jsonb,
  'linked_qwen_0_6b',
  '{
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
          name          |    model_name
------------------------+------------------
 entity_resolution_demo | linked_qwen_0_6b
(1 row)
```

`create_task` registers the model contract and input query

The task has six important parts:

- `task_name` gives the queue and receipt trail a stable name
- `input_query` converts SQL-selected candidate pairs into `subject_id` and compact `input`
- `instruction` is the model contract for this task
- `output_schema` is the JSON schema Otlet enforces before storing output
- `model_name` chooses the registered local model
- `runtime_options` bound generation, tracing, and cache behavior

The schema separates model judgment from database state Otlet can store

If the model returns malformed JSON, missing fields, unknown fields, or values outside the enum, Otlet marks the job failed and keeps the raw evidence. It does not silently write output or records

## Enqueue The Jobs

```sql
SELECT otlet.run_task('entity_resolution_demo') AS queued_jobs;
```

Representative output:

```text
 queued_jobs
-------------
           2
(1 row)
```

`run_task` executes the task input query and inserts one row into `otlet.jobs` per pair

The user transaction creates durable database work, then the resident worker claims it

The queue keeps the model run out of the client request. You can inspect the work in SQL while it is queued, running, complete, failed, or canceled

## Watch The Worker

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
WHERE task_name = 'entity_resolution_demo'
ORDER BY id;
```

If it is still running, wait a moment and run the query again

Representative output:

```text
 id |       task_name        |      subject_id       |  status  | attempts |          created_at           |          started_at           |          finished_at          | error
----+------------------------+-----------------------+----------+----------+-------------------------------+-------------------------------+-------------------------------+-------
  1 | entity_resolution_demo | vendor-1001:vendor-42 | complete |        1 | 2026-06-25 01:28:25.037842+00 | 2026-06-25 01:28:25.041206+00 | 2026-06-25 01:28:29.501949+00 |
  2 | entity_resolution_demo | vendor-1001:vendor-77 | complete |        1 | 2026-06-25 01:28:25.037842+00 | 2026-06-25 01:28:29.506782+00 | 2026-06-25 01:28:34.048475+00 |
(2 rows)
```

The worker uses normal database state as its coordination surface. Jobs are claimed from `otlet.jobs`, outputs are written to Otlet tables, and worker events are visible in `otlet.worker_events`

## Read The Model Output

```sql
SELECT
  r.subject_id,
  r.output ->> 'match' AS match,
  r.output ->> 'confidence' AS confidence,
  r.output ->> 'reason' AS reason
FROM otlet.runs r
WHERE r.task_name = 'entity_resolution_demo'
ORDER BY r.subject_id;
```

Representative output:

```text
      subject_id       |      match       | confidence |                    reason
-----------------------+------------------+------------+----------------------------------------------
 vendor-1001:vendor-42 | same_entity      | high       | shared remittance account and acquisition note
 vendor-1001:vendor-77 | different_entity | high       | medical supplier has no shared identifiers
(2 rows)
```

`otlet.runs` is a convenience view over jobs, outputs, and receipts

Otlet stores the result as database state. You do not have to scrape a terminal response

Direct tasks ask the model to return `actions: []`. They prove durable inference, schema validation, receipts, and trace state; semantic refresh jobs below create typed `create_record` actions, `otlet.records` rows, and semantic materializations automatically after schema validation passes

## Read The Receipt

```sql
SELECT
  receipt_id,
  subject_id,
  status,
  prompt_tokens,
  generated_tokens,
  schema_validation_status,
  stop_reason
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'entity_resolution_demo'
ORDER BY subject_id;
```

Representative output:

```text
 receipt_id |      subject_id       |  status  | prompt_tokens | generated_tokens | schema_validation_status |  stop_reason
------------+-----------------------+----------+---------------+------------------+--------------------------+---------------
          1 | vendor-1001:vendor-42 | complete |           516 |               39 | passed                   | json_complete
          2 | vendor-1001:vendor-77 | complete |           516 |               39 | passed                   | json_complete
(2 rows)
```

A receipt records evidence for one model run. The direct example has one receipt per candidate pair

It links the model, artifact, runtime options, prompt hash, input hash, output schema hash, raw output hash, validation status, timing, token counts, memory summary, and trace summary

Otlet stores receipts when jobs fail because failures produce evidence too

## Inspect Runtime Residency

```sql
SELECT 'runtime_residency_contract=' ||
       runtime_status || '|' ||
       slot_state || '|' ||
       model_residency_policy || '|' ||
       (context_window_tokens > 0)::text || '|' ||
       (inference_cache_entries <= inference_cache_max_entries)::text AS runtime_residency_contract
FROM otlet.runtime_status
WHERE runtime_name = 'linked_inproc';
```

Representative output:

```text
runtime_residency_contract=ready|ready|resident_worker_loaded_model_context|true|true
```

Otlet exposes model residency here

The worker keeps the local model/context warm across jobs. SQL can see the slot state, memory sample, context window, cache entries, cache bounds, and the last cache reason

Otlet favors observability. SQL should show whether the model loaded, is busy, failed, cached, or went over budget

## Inspect Token Traces

The task enabled bounded generation tracing:

```json
{
  "generation_trace": true,
  "generation_trace_max_tokens": 16,
  "generation_trace_top_k": 3
}
```

That stores a bounded trace summary on the receipt instead of storing an unbounded prompt or logits blob

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
token_trace_contract=32|96|true|true
```

Trace data records:

- Prompt tokens used by the row
- Model tokens generated
- Generation stop reason
- Were probabilities available from llama.cpp logits
- Receipt, row identity, input hash, and schema hash attached to the trace
- Did this run use the resident model cache or inference-output cache

Otlet bounds tracing so prompt, token, and logits storage does not turn observability into a data retention problem

## Check The Whole Chain

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
       2 |       2 |       2 |        2
(1 row)
```

That count covers the v0 shape:

```text
two source candidate pairs
two jobs
two validated outputs
two typed actions
two Otlet-owned records
two receipts
bounded trace state
SQL-visible runtime state
```

## Bad Output

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

## Semantic Indexes

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

## Map The Otlet Schema

The direct task path gives you the smallest loop. The rest of Otlet uses the same tables

Use the catalog to see the durable state Otlet owns:

```sql
SELECT count(*) AS otlet_base_tables
FROM information_schema.tables
WHERE table_schema = 'otlet'
  AND table_type = 'BASE TABLE';
```

Representative output:

```text
 otlet_base_tables
-------------------
                15
(1 row)
```

The base tables split into a few jobs:

- `runtimes`, `models`, `model_versions`, and `runtime_slots` describe the local model runtime
- `tasks` and `jobs` describe durable work
- `outputs`, `actions`, `records`, `inference_receipts`, and `worker_events` describe what happened
- `production_policy` defines queue admission, leases, invalid output handling, stale-result behavior, and cleanup windows
- `semantic_indexes` and `semantic_materializations` make model-derived state queryable
- `semantic_join_indexes` do the same for pairwise candidate rows

Use `otlet.runs` for application reads. Use trace and status views for debugging, proof, and learning

## Create A Retry Task

This task is reused below to show terminal failure evidence and safe requeueing

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
  '{"max_tokens":64,"reasoning":"off"}'::jsonb
);
```

Representative output:

```text
        name         | has_input_query |    model_name
---------------------+-----------------+------------------
 learning_retry_task | t               | linked_qwen_0_6b
(1 row)
```

## Cancel Queued Work

Cancellation changes job lifecycle state

Use a queued job that the worker has not claimed yet:

```sql
SELECT name, model_name
FROM otlet.create_task(
  'learning_cancel_task',
  NULL::text,
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

## Understand Retry And Failed-Run Evidence

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

## Check Worker Events And Receipt Statuses

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

## Learn The Action Boundary

Otlet keeps the v0 action vocabulary narrow

`create_record` can create an Otlet-owned record. Otlet captures unsupported action types as rejected actions and does not mutate user tables:

```sql
SELECT name, model_name
FROM otlet.create_task(
  'learning_action_boundary_task',
  NULL::text,
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

## Materialize Records Into Semantic State

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

## Build A Semantic Index

A semantic index wraps a source table with an Otlet task, materialized records, stale tracking, and a native FDW table

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
  '{"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":12,"generation_trace_top_k":3}'::jsonb,
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
SELECT 'semantic_index_status_contract=' ||
       name || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       inflight_subjects::text || '|' ||
       effective_stale_policy AS semantic_index_status_contract
FROM otlet.semantic_index_status
WHERE name = 'demo_semantic_vendor_idx';

SELECT 'semantic_index_plan_contract=' ||
       selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       freshness::text AS semantic_index_plan_contract
FROM otlet.semantic_index_plan('demo_semantic_vendor_idx');
```

Representative output:

```text
semantic_index_status_contract=demo_semantic_vendor_idx|3|0|0|refresh_then_fail_closed
semantic_index_plan_contract=semantic_lookup|3|3|0|0|1.0000
```

`semantic_index_plan` is Otlet deciding whether it can reuse materialized state, should refresh, should wait, or should run fresh inference

## Read Through FDW

`create_semantic_index` also creates a native foreign table

The FDW table holds materialized semantic state:

```sql
SELECT 'semantic_fdw_rows_contract=' ||
       count(*)::text || '|' ||
       count(*) FILTER (WHERE body @> '{"status":"needs_review"}'::jsonb)::text || '|' ||
       count(*) FILTER (WHERE stale)::text AS semantic_fdw_rows_contract
FROM otlet.demo_semantic_vendor_idx_native;
```

Representative output:

```text
semantic_fdw_rows_contract=3|3|0
```

Use the FDW table for semantic rows. Use `semantic_index_current_rows` when you want the same state without a foreign table

## Inspect The Native FDW Plan

The native table uses `otlet_semantic_fdw`

```sql
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM otlet.demo_semantic_vendor_idx_native
WHERE subject_id = '2';
```

Representative output excerpt:

```text
Foreign Scan on otlet.demo_semantic_vendor_idx_native
  Otlet Node: Semantic Foreign Scan
  Selected Path: semantic_lookup
  Queue Subjects: 0
  Path Cost: 1.05
  Freshness: 1.00
  Pushed Subject Id: 2
```

The FDW runs inside Postgres as a native access path over Otlet-owned semantic materializations

## Use CustomScan For Source-Row Predicates

Otlet can own a semantic predicate against the source table through a CustomScan

```sql
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM public.otlet_demo_semantic_vendor v
WHERE otlet.semantic_matches('demo_semantic_vendor_idx', v.id::text, '{"status":"needs_review"}'::jsonb);
```

Representative output excerpt:

```text
Custom Scan (Otlet Semantic Source CustomScan) on public.otlet_demo_semantic_vendor v
  Otlet Node: Semantic Source CustomScan
  Child Semantic Filter: stripped_before_child_plan
  Semantic Index: demo_semantic_vendor_idx
  Planner Selected Path: semantic_lookup
  Planner Fresh Rows: 3
  Actual Fresh Subjects: 3
```

The child scan reads the source table. Otlet strips the semantic predicate from the child plan and evaluates it against preloaded semantic state

## Fail Closed On Stale Rows

Changing a source row makes its materialized semantic state stale

```sql
UPDATE public.otlet_demo_semantic_vendor
SET email = 'learning-stale@example.test', updated_at = clock_timestamp()
WHERE id = 2;

SELECT 'semantic_stale_status_contract=' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       inflight_subjects::text AS semantic_stale_status_contract
FROM otlet.semantic_index_status
WHERE name = 'demo_semantic_vendor_idx';

SELECT count(*) AS fail_closed_rows
FROM public.otlet_demo_semantic_vendor v
WHERE v.id = 2
  AND otlet.semantic_matches('demo_semantic_vendor_idx', v.id::text, '{"status":"needs_review"}'::jsonb);
```

Representative output:

```text
UPDATE 1

semantic_stale_status_contract=2|1|0

 fail_closed_rows
------------------
                0
(1 row)
```

Fail closed means stale facts do not match because old model output looked right

## Let CustomScan Refresh A Stale Row With Infer-Now

`semantic_matches_auto` lets a source-table query use policy-owned bounded infer-now for stale or missing rows

The wait, infer, and max-row budget comes from `otlet.production_policy_status`:

```sql
SELECT 'semantic_auto_policy_contract=' ||
       semantic_auto_wait_ms::text || '|' ||
       semantic_auto_infer_ms::text || '|' ||
       semantic_auto_max_rows::text AS semantic_auto_policy_contract
FROM otlet.production_policy_status;
```

Representative output:

```text
semantic_auto_policy_contract=10000|15000|1
```

```sql
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_semantic_vendor v
WHERE otlet.semantic_matches_auto('demo_semantic_vendor_idx', v.id::text, '{"status":"needs_review"}'::jsonb);
```

Representative output excerpt:

```text
Custom Scan (Otlet Semantic Source CustomScan) on public.otlet_demo_semantic_vendor v
  Otlet Node: Semantic Source CustomScan
  Semantic Index: demo_semantic_vendor_idx
  Refresh Policy: auto_lookup_wait_infer_refresh_fail_closed
  Infer Now Timeout Ms: 15000
  Infer Now Max Rows: 1
  Planner Selected Path: bounded_infer_now
  Planner Stale Rows: 1
  Actual Infer Resolved Rows: 1
  Infer Now Receipts: 1
```

The executor refreshed the stale row with a bounded infer-now budget and a receipt

Inspect that receipt:

```sql
SELECT executor_origin || '|' ||
       semantic_index_name || '|' ||
       status || '|' ||
       (prompt_tokens > 0)::text || '|' ||
       (generated_tokens >= 0)::text AS receipt_contract
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'demo_semantic_vendor_idx_task'
  AND subject_id = '2'
ORDER BY receipt_id DESC
LIMIT 1;
```

Representative output:

```text
                    receipt_contract
---------------------------------------------------------
 customscan_infer_now|demo_semantic_vendor_idx|complete|t|t
(1 row)
```

Receipts carry executor provenance because the same model task can run from the worker queue or from CustomScan infer-now

## Build A Semantic Join Index

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

SELECT 'semantic_join_create_contract=' ||
       name || '|' ||
       task_name || '|' ||
       record_type || '|' ||
       max_candidate_rows::text
FROM otlet.create_semantic_join_index(
  'learning_entity_pair_idx',
  $$
    SELECT
      a.id::text || ':' || b.id::text AS subject_id,
      jsonb_build_object('left', to_jsonb(a), 'right', to_jsonb(b)) AS input
    FROM public.learning_entity a
    JOIN public.learning_entity b ON a.id < b.id
  $$,
  'The two input entities are the same company. Return exactly this JSON object: {"output":{"match":"yes","confidence":0.95,"needs_review":false},"actions":[]}',
  '{"type":"object","required":["match","confidence","needs_review"],"additionalProperties":false,"properties":{"match":{"enum":["yes"]},"confidence":{"type":"number"},"needs_review":{"type":"boolean"}}}'::jsonb,
  'linked_qwen_0_6b',
  'learning_entity_pair',
  '{"max_tokens":160,"reasoning":"off"}'::jsonb,
  10
);

SELECT 'semantic_join_refresh_queued=' ||
       otlet.refresh_semantic_join_index('learning_entity_pair_idx')::text;
```

Wait for the worker the same way the semantic index section does, or run `./scripts/otlet-demo.sh` for the compact proof. Then inspect the automatic materialization:

```sql
SELECT 'semantic_join_auto_materialized=' ||
       count(*)::text AS semantic_join_auto_materialized
FROM otlet.semantic_materializations
WHERE task_name = 'learning_entity_pair_idx_task'
  AND record_type = 'learning_entity_pair'
  AND stale = false;
```

Representative output:

```text
semantic_join_create_contract=learning_entity_pair_idx|learning_entity_pair_idx_task|learning_entity_pair|10
semantic_join_refresh_queued=1
semantic_join_auto_materialized=1
```

Now inspect the join index:

```sql
SELECT 'semantic_join_status_contract=' ||
       selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text AS semantic_join_status_contract
FROM otlet.semantic_join_index_plan('learning_entity_pair_idx');

SELECT 'semantic_join_lookup_contract=' ||
       count(*)::text || '|' ||
       count(*) FILTER (WHERE body @> '{"match":"yes"}'::jsonb)::text || '|' ||
       count(*) FILTER (WHERE stale)::text AS semantic_join_lookup_contract
FROM otlet.semantic_join_index_current_rows('learning_entity_pair_idx', true);
```

Representative output:

```text
semantic_join_status_contract=semantic_join_lookup|1|1|0|0
semantic_join_lookup_contract=1|1|0
```

A semantic join index uses the same contract: jobs, outputs, actions, records, materializations, receipts

## Query A Semantic Join Predicate

```sql
SELECT 'semantic_join_match_contract=' ||
       bool_and(otlet.semantic_join_matches('learning_entity_pair_idx', subject_id, '{"match":"yes"}'::jsonb))::text AS semantic_join_match_contract
FROM otlet.semantic_join_index_current_rows('learning_entity_pair_idx', true);
```

Representative output:

```text
semantic_join_match_contract=true
```

Use explicit JSON predicates for row and join semantic filters

## Inspect Trace Visibility Across The System

The trace visibility view tells you whether receipts are linked to outputs, actions, token steps, top-k alternatives, provenance, stale policy, and CustomScan infer-now

```sql
SELECT 'inference_visibility_status=' ||
       (receipt_count > 0)::text || '|' ||
       (token_steps > 0)::text || '|' ||
       (top_k_alternatives > 0)::text || '|' ||
       (max_detailed_trace_tokens <= 16)::text || '|' ||
       (max_detailed_trace_top_k <= 3)::text AS inference_visibility_contract
FROM otlet.inference_visibility_status;
```

Representative output:

```text
inference_visibility_status=true|true|true|true|true
```

Those booleans prove receipts, token steps, top-k alternatives, bounded trace tokens, and top-k width were present

## Inspect Runtime Status After Advanced Runs

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
runtime_status_contract=ready|ready|60.34|true|linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run
```

The value reports a ready runtime, a ready model slot, bounded cache entries, and Linux process-status memory sampling after a worker run

## Inspect Production Policy

The production policy row and status views are ordinary SQL state under `otlet`: `production_policy_status`, `production_status`, `model_queue_status`, `worker_throughput_status`, and `cleanup_policy_state(true)`

Representative output from the demo contract:

```text
production_policy_contract=default|refresh_then_fail_closed|3|8
production_status_contract=true|true|true|true
model_queue_status_contract=queue_accepting|0|0
throughput_status_contract=queue_accepting|0|0|2|2|0
cleanup_policy_dry_run=0|0|0|true
```

## Know The Remaining Production Boundaries

Otlet installs internal production policy, bounded queues, leases, sweeps, validation evidence, status views, and a cleanup dry-run/apply function. Your application still owns tenant access, app roles, and approval workflows

Check row-level security:

```sql
SELECT 'rls_contract=' ||
       count(*)::text || '|' ||
       (count(*) FILTER (WHERE relrowsecurity))::text
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'otlet'
  AND c.relkind = 'r';

SELECT 'installed_policies=' || count(*)::text
FROM pg_policies
WHERE schemaname = 'otlet';
```

Representative output:

```text
rls_contract=15|0
installed_policies=0
```

Check default grants visible through `information_schema`:

```sql
SELECT 'grant_contract=' ||
       string_agg(privilege_type || ':' || n::text, '|' ORDER BY privilege_type)
FROM (
  SELECT privilege_type, count(*) AS n
  FROM information_schema.role_table_grants
  WHERE table_schema = 'otlet'
  GROUP BY privilege_type
) grants;
```

Representative output:

```text
grant_contract=DELETE:40|INSERT:40|REFERENCES:40|SELECT:40|TRIGGER:40|TRUNCATE:40|UPDATE:40
```

The remaining production boundary is application-specific:

- create app roles that expose only the views and functions you want
- add RLS or schema isolation if multiple tenants share the database
- schedule `otlet.cleanup_policy_state(false)` if your deployment wants periodic worker-event and trace pruning
- keep approval workflows outside model output, then consume Otlet records as evidence
- allow only the action types your application can safely interpret

## Run The Full Demo Contract

The repo includes a script that exercises the entity-resolution path used in this learning file:

```sh
./scripts/otlet-demo.sh
```

Representative contract output from the demo run:

```text
production_policy_contract=default|refresh_then_fail_closed|3|8
production_status_contract=true|true|true|true
model_queue_status_contract=queue_accepting|0|0
entity_resolution_contract=2|same_entity|different_entity|2|2
semantic_join_refresh_queued=2
semantic_join_auto_records=2|2
semantic_join_auto_materialized=2
throughput_status_contract=queue_accepting|0|0|2|2|0
semantic_join_status_contract=semantic_join_lookup|2|2|0|0|0|0
semantic_join_lookup_contract=2|1|1
semantic_join_match_contract=true|true
semantic_join_stale_contract=2|0|fresh_after_lookup=0
receipt_trace_contract=4|4|4|4
inference_visibility_status=true|true|true|true|true
cleanup_policy_dry_run=0|0|0|true
runtime_status_contract=ready|ready|60.34|true|linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run
docker_crash_log_scan=ok
```

Use that script as the compact regression proof. Use this Markdown to learn the same system
