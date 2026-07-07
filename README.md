# Otlet

Otlet is a Postgres extension that runs local LLM inference **inside Postgres**, next to the rows it reads and acts on

Otlet is built for row judgment inside Postgres: ask a local model about rows, validate the JSON, keep receipts, and store trusted derived state without writing back to source tables. Entity resolution is the first full path: Otlet can judge hard candidate row pairs, escalate from a small local model to a stronger one, propose typed actions, and materialize the result for later SQL

Otlet uses a `pgrx` extension and a Postgres background worker loaded through `shared_preload_libraries` to keep local model work inside the database process. You can ask for model work from SQL, queue it from rows, refresh semantic state after source changes, and inspect the result without leaving Postgres

## Quick Example

This asks one local model to read one source row and return a structured triage answer. The row stays in `public`; the model output, receipt, trace, and hashes stay under `otlet`

After setup creates the in-process llama.cpp worker runtime, register the model:

```sql
SELECT name AS model_name FROM otlet.register_model('qwen35_4b', '<Qwen3.5-4B-Q4_K_M.gguf>');
```

```text
  model_name
-------------
 qwen35_4b
(1 row)
```

Assume this source row already exists. It has enough ambiguity that a simple string or threshold rule is not the point:

```sql
SELECT id, vendor_name, left(note, 92) || '...' AS note
FROM public.readme_vendor_note
WHERE id = 'note-1';
```

```text
+--------+-------------------------+-------------------------------------------------------------------------------------------------+
|   id   |       vendor_name       |                                              note                                               |
+--------+-------------------------+-------------------------------------------------------------------------------------------------+
| note-1 | Northstar Logistics LLC | AP says the bank account changed two days after a domain change. The request came from a new... |
+--------+-------------------------+-------------------------------------------------------------------------------------------------+
(1 row)
```

Call the model from SQL. `otlet.ask` creates Otlet-owned task, job, output, and receipt rows:

```sql
SELECT a.output->>'route' AS route,
       a.output->>'summary' AS summary,
       a.job_id,
       a.receipt_id
FROM otlet.ask(
  'qwen35_4b',
  'Read one vendor note. Return one JSON object with exactly two top-level keys: "output" then "actions". output has summary under 12 words, route, and reason under 10 words. route must be approve, review_payment, or block_payment. actions must be the empty array []. Do not close the outer object until after "actions":[] has been written. No markdown.',
  (SELECT jsonb_build_object('vendor_name', vendor_name, 'note', note)
   FROM public.readme_vendor_note
   WHERE id = 'note-1'),
  '{"type":"object","required":["summary","route","reason"],"additionalProperties":false,"properties":{"summary":{"type":"string"},"route":{"enum":["approve","review_payment","block_payment"]},"reason":{"type":"string"}}}'::jsonb,
  '{"max_tokens":128,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":16,"generation_trace_top_k":3}'::jsonb
) a;
```

The local LLM inference happens inside the `otlet worker`: Postgres hands the row JSON to the resident worker, the worker loads `qwen35_4b` through llama.cpp, validates the JSON, and stores only the trusted `output`

```text
+----------------+------------------------------------------------------------------------------------------+--------+------------+
|     route      |                                         summary                                          | job_id | receipt_id |
+----------------+------------------------------------------------------------------------------------------+--------+------------+
| review_payment | AP flagged bank account change after domain change with urgent request from new contact. |      2 |          2 |
+----------------+------------------------------------------------------------------------------------------+--------+------------+
(1 row)
```

The returned `receipt_id` opens the audit trail:

```sql
SELECT model_name, status, schema_validation_status AS schema,
       prompt_tokens AS prompt, generated_tokens AS output,
       detailed_trace_captured_tokens AS traced,
       left(receipt_raw_output_hash, 8) AS hash
FROM otlet.inference_receipt_trace_status
WHERE receipt_id = 2;
```

```text
+------------+----------+--------+--------+--------+--------+----------+
| model_name |  status  | schema | prompt | output | traced |   hash   |
+------------+----------+--------+--------+--------+--------+----------+
| qwen35_4b  | complete | passed |    394 |     46 |     16 | 91d7ca21 |
+------------+----------+--------+--------+--------+--------+----------+
(1 row)
```

## Longer Example

Entity resolution uses the same SQL and receipt path, but adds candidate pairs, model selection, typed actions, and semantic materialization. The demo registers `qwen3_1_7b` as the cheap model and `qwen35_4b` as the stronger model. On this run, the cheap model fails the strict output envelope on hard rows, so Otlet records failed receipts and escalates to the stronger model

The task reads candidate vendor pairs, joins source rows, and gives the model compact evidence buckets:

```sql
SELECT p.pair_id, r.legal_name AS right_name,
       left(v.input->'candidate_evidence'->>'shared_stable_identifiers', 34) AS shared,
       left(v.input->'candidate_evidence'->>'conflicting_stable_identifiers', 42) AS conflicts
FROM public.otlet_demo_vendor_pair p
JOIN public.otlet_demo_vendor_entity r ON r.id = p.right_id
JOIN public.otlet_demo_vendor_pair_input v ON v.subject_id = p.pair_id
ORDER BY p.pair_id
```

```text
+------------------------+-------------------------------+------------------------------------+--------------------------------------------+
|        pair_id         |          right_name           |               shared               |                 conflicts                  |
+------------------------+-------------------------------+------------------------------------+--------------------------------------------+
| vendor-1001:vendor-313 | North Star Medical Logistics  | []                                 | ["medical logistics versus freight vendor" |
| vendor-1001:vendor-314 | Northstar Freight Canada Inc. | []                                 | ["different country and Canadian legal ent |
| vendor-1001:vendor-42  | N-Star Freight Services       | ["same remittance account ending 8 | []                                         |
| vendor-1001:vendor-77  | Clearwater Medical Supplies   | []                                 | ["different industry and city", "no shared |
+------------------------+-------------------------------+------------------------------------+--------------------------------------------+
(4 rows)
```

Then SQL queues model work and reads validated answers:

```sql
SELECT otlet.run_task('entity_resolution_demo') AS queued_jobs;
SELECT subject_id, output->>'match' AS match, output->>'confidence' AS confidence
FROM otlet.runs
WHERE task_name = 'entity_resolution_demo' AND output_id IS NOT NULL
ORDER BY subject_id;
```

```text
+-------------+
| queued_jobs |
+-------------+
|           4 |
+-------------+
(1 row)

+------------------------+------------------+------------+
|       subject_id       |      match       | confidence |
+------------------------+------------------+------------+
| vendor-1001:vendor-313 | different_entity | high       |
| vendor-1001:vendor-314 | different_entity | high       |
| vendor-1001:vendor-42  | same_entity      | high       |
| vendor-1001:vendor-77  | different_entity | high       |
+------------------------+------------------+------------+
(4 rows)
```

Otlet also records model-selection attempts, typed actions, receipts, traces, and source-write proof under SQL-visible state. The demo emits compact contract lines for those paths:

```text
model_selection_status_contract=true|true|true|4|3
action_type_contract=merge_candidate|new_entity
receipt_trace_contract=8|8|8|8
source_write_contract=5|...|5|...
```

Source rows stayed in `public.otlet_demo_vendor_entity`. Otlet stored jobs, accepted outputs, failed attempts, receipts, trace state, and typed actions under `otlet`

## Docs

Start with [the worked example](docs/otlet-worked-example.md)

You run the extension with SQL commands and real output. The worked example keeps the setup path and full demo command short; the long chapters live in focused docs:

- [Entity resolution walkthrough](docs/entity-resolution-walkthrough.md)
- [Runtime and traces](docs/runtime-and-traces.md)
- [Semantic watches](docs/semantic-watches.md)
- [Production contract](docs/production-contract.md)

Use [benchmarks/README.md](benchmarks/README.md) to compare local GGUF models on Otlet’s row-pair, receipt, action, stale-state, and resource-fit contracts

See [docs/roadmap.md](docs/roadmap.md) for future work

## License

MIT, see [LICENSE](LICENSE)
