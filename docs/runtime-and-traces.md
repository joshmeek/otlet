# Runtime And Traces

Use this after the entity-resolution walkthrough queues work. It inspects model selection, receipts, runtime status, trace visibility, retries, cancellation, and failed-run evidence

These diagnostic queries run as the extension owner because they expose receipt, structured output, error, and numeric token state. Raw model output and token text appear when the owner enables bounded diagnostic storage. Auditors use `otlet.audit_receipt_export` and the other redacted exports granted by `otlet.grant_auditor_access(...)`

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

The stricter output/action envelope leaves every cheap attempt untrusted in this captured demo. A cheap attempt can finish as `rejected` when its structured output fails the decision contract or `failed` when its output is malformed. Both states remain visible as receipts and escalate to `qwen35_4b`. In this run all four were `rejected`, and Otlet materialized the accepted strong-model output for each job

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

A receipt records evidence for one model run. A candidate pair can have multiple receipts when model selection escalates

Each accepted receipt links PostgreSQL-recomputed SHA-256 identities for the task, source snapshot, model, effective runtime options, prompt, input, output schema, raw output, structured output, and actions. It also records verified artifact provenance, the detailed runtime fingerprint, validation status, timing, token counts, memory summary, and trace summary. Otlet does not persist the assembled prompt

```sql
SELECT receipt_id,
       model_artifact_hash AS artifact_sha256,
       model_artifact_identity,
       runtime_fingerprint -> 'artifact' ->> 'verification' AS verification
FROM otlet.inference_receipt_trace_status
ORDER BY receipt_id DESC
LIMIT 1;
```

Linked llama.cpp uses greedy decoding and stops after one balanced JSON object. PostgreSQL parses that envelope again, requires the submitted output and actions to match it, validates the supported task JSON Schema subset, recomputes the portable identities, and applies the action, freshness, decision, and selection contracts. The worker's validation flag cannot authorize output. Inspect the decode and validation contract through the receipt:

```sql
SELECT schema_force, decode_constraint, decode_constraint_reason
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'entity_resolution_demo'
ORDER BY receipt_id DESC
LIMIT 1;
```

Portable execution uses the same receipt state and records `portable:<runtime_name>` with endpoint `postgres_rpc`. Inspect protocol compatibility, worker and model health, queue depth, lease health, claim ownership, and linked receipts without reading the underlying tables:

```sql
SELECT * FROM otlet.portable_protocol_status;
SELECT * FROM otlet.portable_worker_status;
SELECT * FROM otlet.portable_claim_status ORDER BY claim_id DESC;
SELECT * FROM otlet.portable_receipt_status ORDER BY receipt_id DESC;
```

The [reference external worker](../portable/README.md) runs the same database-built prompt with one local GGUF when the PostgreSQL host cannot load the native extension worker. It renews the lease during decode and interrupts work after cancellation, claim loss, or database disconnect. PostgreSQL still parses the returned envelope and owns every validation and trusted-state write

Receipt timing splits runtime preparation, model load, context creation, tokenization, prompt decode, generation, validation and post-processing, finish SQL, and semantic materialization. `otlet.runtime_stage_timing_status` aggregates every attempt for a job and leaves unmeasured worker work in `worker_overhead_ms`:

```sql
SELECT subject_id,
       model_attempts,
       queue_wait_ms,
       runtime_prepare_ms,
       model_load_ms + model_context_ms + tokenize_ms
         + prompt_decode_ms + generate_ms AS model_ms,
       postprocess_ms,
       finish_sql_ms,
       materialize_ms,
       worker_overhead_ms,
       observed_end_to_end_ms
FROM otlet.runtime_stage_timing_status
WHERE task_name = 'entity_resolution_demo'
ORDER BY subject_id;
```

`reconciliation_delta_ms` is observed worker time minus the recorded stages. A positive value is worker and transaction overhead. `timing_overrun_ms` exposes timer rounding or a broken timing boundary instead of hiding it

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

The worker keeps the local model/context warm across jobs. SQL can see the slot state, memory sample, context window, cache entries, cache bounds, last cache reason, and latest detailed runtime fingerprint

`otlet.runtime_status` also reports the latest infer-now request split as start latency, worker time, and requester delivery time through `infer_now_last_start_latency_ms`, `infer_now_last_worker_run_ms`, and `infer_now_last_delivery_ms`

The full fingerprint describes the artifact, linked build, effective generation settings, CPU placement, and host capacity. The prompt-template hash covers the exact reasoning prefix and static prompt body. Its output-contract hash omits observational host fields and joins content, task contract, and model identity in the inference-cache key:

```sql
SELECT receipt_id,
       runtime_fingerprint_version,
       runtime_fingerprint_hash,
       runtime_output_contract_hash,
       runtime_fingerprint -> 'artifact' ->> 'quantization' AS quantization,
       runtime_fingerprint #>> '{output_contract,prompt_template,name}' AS prompt_template
FROM otlet.inference_receipt_trace_status
WHERE runtime_fingerprint_hash IS NOT NULL
ORDER BY receipt_id DESC
LIMIT 1;
```

SQL shows whether the model loaded, is busy, failed, cached, or went over budget

Generated runs record `memory_evidence` before and after the model path. Typed receipt and runtime-status columns expose process RSS and swap, system available memory and swap, major-fault and file-read deltas, PSI totals, supported cgroup-v2 usage and events, and the model-load admission decision. With an explicit RSS budget, a cache miss loads llama.cpp metadata without tensor allocation and projects model, KV, and prompt-decode workspace bytes. Otlet rejects the load when that total exceeds worker-budget, system, or finite cgroup headroom. The current resident model stays usable

```sql
SELECT model_load_admission_decision,
       model_load_admission_reason,
       worker_process_rss_bytes,
       worker_process_swap_bytes,
       system_memory_available_bytes,
       worker_major_faults,
       worker_read_bytes,
       memory_pressure_some_us,
       cgroup_memory_oom_events
FROM otlet.inference_receipt_trace_status
ORDER BY receipt_id DESC
LIMIT 1;
```

The inference-output cache stores schema-valid raw model output before Otlet applies selection trust. Accepted abstentions and rejected-but-valid attempts may reuse cached bytes; invalid JSON/schema failures stay out of the cache. The receipt still records accepted/rejected/failed status, and the cache key basis is content hash + contract hash + runtime output-contract hash + model fingerprint

The process-local cache holds at most 512 entries or 8 MiB. Otlet does not persist it. The fresh demo and a stable restart probe showed no eviction pressure or repeated restart misses. Persisting exact raw envelopes would cross the default hash-only stored-evidence boundary, while parsed trusted output survives through outputs and semantic materializations

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

Otlet stores a bounded trace summary on each receipt. Under the default policy, token IDs, ranks, probabilities, and logprobs remain available while token text stays null

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

Otlet records:

- Prompt tokens used by the row
- Model tokens generated
- Generation stop reason
- Probability availability from llama.cpp logits
- Receipt, row identity, input hash, and schema hash attached to the trace
- Resident model cache and inference-output cache use

Token and top-k limits bound trace retention. `otlet.redaction_policy_status` reports whether any raw output or token text violates the active policy

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

The counts cover the direct task shape:

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
- the latest receipt keeps a raw-output hash without raw model text under the default policy
- `otlet.outputs` has no validated row
- `otlet.actions` has no trusted row from a failed model attempt
- `otlet.records` has no row
- an error receipt preserves the model/runtime evidence when available

The task schema and action rules decide whether model output can become database truth. If output passes and a proposed action fails, Otlet keeps the rejected action as evidence and creates no record

## Step 7 - Create A Retry Task

Reuse this task for terminal failure evidence and safe requeueing

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
  '{"max_tokens":64,"reasoning":"off"}'::jsonb,
  '{"source_fields":["id","note"]}'::jsonb
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
  '{}'::jsonb,
  '{"source_fields":["kind"]}'::jsonb
);

INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('learning_cancel_task', 'cancel-1', '{"kind":"manual queued job"}'::jsonb)
RETURNING id, task_name, subject_id, status, attempts;

SELECT id, task_name, subject_id, status, error
FROM otlet.request_job_cancellation(
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

Otlet records a receipt for canceled work and preserves model-run evidence

A synchronous infer-now caller can time out while the worker decodes. The requester records a shared abort marker and calls `otlet.request_job_cancellation`; the worker then closes the job with its live claim token before it can accept output. The caller's failed transaction cannot roll back that worker-owned cancellation

The demo requires the canceled job and receipt, zero outputs and actions, a recorded timeout and abort, the canceled job ID, and one healthy worker:

```text
requester_timeout_contract=canceled|true|canceled|canceled|0|0|true|true|true|1|ready|ready
```

## Step 9 - Understand Retry And Failed-Run Evidence

Otlet leaves failed jobs visible. A failed job is terminal, so you can requeue that task and subject

The partial unique index blocks duplicate active work and leaves terminal history reusable:

```sql
CREATE UNIQUE INDEX jobs_active_subject_idx
ON otlet.jobs (task_name, subject_id)
WHERE status IN ('queued', 'running', 'cancel_requested');
```

The example creates one synthetic failed job, then lets `run_task` enqueue a second job for that subject

The worker claims the second job and rejects the output against the strict JSON contract:

```sql
SELECT j.id, j.subject_id, j.status, j.attempts, j.error,
       (r.raw_output_hash IS NOT NULL) AS has_raw_output_hash,
       (r.raw_output IS NOT NULL) AS has_diagnostic_raw_output
FROM otlet.jobs j
LEFT JOIN LATERAL (
  SELECT receipt.raw_output_hash, receipt.raw_output
  FROM otlet.inference_receipts receipt
  WHERE receipt.job_id = j.id
  ORDER BY receipt.attempt_index DESC, receipt.id DESC
  LIMIT 1
) r ON true
WHERE j.task_name = 'learning_retry_task'
ORDER BY j.id;

SELECT id AS receipt_id, job_id, task_name, subject_id, status, schema_validation_status, error
FROM otlet.inference_receipts
WHERE task_name = 'learning_retry_task'
ORDER BY id;
```

Representative output:

```text
 id | subject_id | status | attempts |                      error                       | has_raw_output_hash | has_diagnostic_raw_output
----+------------+--------+----------+--------------------------------------------------+---------------------+---------------------------
 11 | 1          | failed |        1 | learning example synthetic failure               | t                   | f
 12 | 1          | failed |        1 | invalid model JSON: expected value at line 1 column 1 | t               | f
(2 rows)

 receipt_id | job_id |      task_name      | subject_id | status | schema_validation_status |                      error
------------+--------+---------------------+------------+--------+--------------------------+--------------------------------------------------
         11 |     11 | learning_retry_task | 1          | failed |                          | learning example synthetic failure
         12 |     12 | learning_retry_task | 1          | failed | failed                   | invalid model JSON: expected value at line 1 column 1
(2 rows)
```

Failure records a raw-output hash, a non-sensitive error, and an attempt receipt. Enable diagnostic mode when you need bounded raw text inside the database

## Step 10 - Check Worker Events And Receipt Statuses

Events show worker behavior. Receipts show model behavior

The portable worker emits one `preflight_passed` event before model load or claims. A failed explicit `--preflight` emits `preflight_failed` with one stable dependency code and no connection string, credential, prompt, or source value

`otlet.decision_trace_export` is the content-addressed export surface for accepted receipts. `decision_trace_sha256` covers the canonical identity trace and identifies its compact recommendation. Actions include payload hashes and ordered execution-receipt identities; reviews include reviewer, freshness, and evidence hashes without reason text

`otlet.destination_reconciliation_status` links that recommendation identity to each receiver-enforced idempotency key, authenticated acknowledgement, destination execution receipt, and replay decision. `acknowledgement_pending` keeps both never-acknowledged exports and explicitly unknown deliveries visible

Database health is a separate live surface:

```sql
SELECT queued_jobs,
       worker_process_rss_bytes,
       database_connections,
       database_size_bytes,
       wal_bytes_since_reset,
       otlet_storage_bytes,
       dead_tuples,
       application_latency_ms,
       claims_allowed,
       failed_checks
FROM otlet.database_health_status;
```

Native memory comes from the resident runtime slot while its worker is present. Portable memory comes from heartbeats sampled within the last two minutes. Configure an application-latency limit only when an owner-side monitor records representative query latency through `record_application_latency(...)`

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
