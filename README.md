# Otlet

Otlet is a Postgres extension for row judgment. It runs local LLM inference **inside Postgres**, next to the rows it reads and acts on

Otlet answers questions about rows, validates JSON, keeps receipts, and stores trusted derived state while source tables stay unchanged. Entity resolution is the first full path: Otlet judges hard candidate row pairs, escalates from a small local model to a stronger one, proposes typed actions, and materializes results for later SQL

Otlet uses a `pgrx` extension and a Postgres background worker loaded through `shared_preload_libraries` to run local model work inside the database process. You can ask for model work from SQL, queue it from rows, refresh semantic state after source changes, and inspect the result without leaving Postgres

## Quick Example

Use `otlet.ask` for one-off questions over row-shaped JSON. This example summarizes customer notes and chooses a next step

```sh
./scripts/otlet-setup.sh
./scripts/otlet-demo.sh
```

```sql
SELECT name AS model
FROM otlet.register_model('qwen35_4b', '/var/lib/postgresql/otlet-models/Qwen3.5-4B-Q4_K_M.gguf');
```

```text
+-----------+
|   model   |
+-----------+
| qwen35_4b |
+-----------+
(1 row)
```

```sql
SELECT output, receipt_id IS NOT NULL AS receipt_recorded
FROM otlet.ask(
  'qwen35_4b',
  'Summarize these customer notes in one sentence and choose the next step.',
  '{
    "customer": "Riverline Labs",
    "notes": [
      "Trial team likes row-level receipts and wants CSV export.",
      "Security asked whether Otlet changes source tables.",
      "Procurement needs a one-paragraph summary by Friday."
    ]
  }'::jsonb,
  '{"type":"object","required":["summary","next_step"],"properties":{"summary":{"type":"string"},"next_step":{"enum":["ship","hold","ask_followup"]}}}'::jsonb
);
```

```text
+-----------------------------------------------------------------------------------------------------------------------------+------------------+
|                                                           output                                                            | receipt_recorded |
+-----------------------------------------------------------------------------------------------------------------------------+------------------+
| {"summary": "Riverline Labs customers want a CSV export and need a summary of Otlet changes.", "next_step": "ask_followup"} | t                |
+-----------------------------------------------------------------------------------------------------------------------------+------------------+
(1 row)
```

Otlet ran the local model inside Postgres, validated the JSON, and stored the receipt under the `otlet` schema

## Longer Example

Entity resolution extends the SQL and receipt path with candidate pairs, model selection, typed actions, and semantic materialization. The demo registers `qwen3_1_7b` as the cheap model and `qwen35_4b` as the stronger model. On this run, the strict output envelope rejects the cheap model on hard rows. Otlet records rejected receipts and escalates to the stronger model

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
model_selection_status_contract=true|true|true|4|4
action_type_contract=merge_candidate|new_entity
receipt_trace_contract=8|8|8|8
source_write_contract=5|...|5|...
```

Source rows stayed in `public.otlet_demo_vendor_entity`. Otlet stored jobs, accepted outputs, failed attempts, receipts, trace state, and typed actions under `otlet`

## Docs

Start with [the worked example](docs/otlet-worked-example.md)

The worked example pairs SQL commands with captured output and keeps the setup path short. Focused docs cover the longer paths:

- [Entity resolution walkthrough](docs/entity-resolution-walkthrough.md)
- [Runtime and traces](docs/runtime-and-traces.md)
- [Semantic watches](docs/semantic-watches.md)
- [Production contract](docs/production-contract.md) for role grants, audit export views, `otlet.access_policy_status`, redaction policy, and invariant naming

Use [benchmarks/README.md](benchmarks/README.md) to compare local GGUF models on Otlet’s row-pair, receipt, action, stale-state, and resource-fit contracts

See [docs/roadmap.md](docs/roadmap.md) for future work

## License

MIT, see [LICENSE](LICENSE)
