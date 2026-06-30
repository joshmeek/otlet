# Otlet

Otlet is a Postgres extension that runs local LLM inference **inside Postgres**, next to the rows it reads and acts on

I built Otlet for entity resolution: when new data lands, Postgres helps decide whether a row is a new entity or a duplicate. Otlet runs through a resident Postgres worker, tries a cheap local model before escalating hard rows to a stronger local model, records receipts and source identity, drains bounded queued work, stores typed action proposals, and materializes results for later queries. The [roadmap](docs/roadmap.md) tracks packaging, security, and planner work

Otlet uses a `pgrx` extension and a Postgres background worker loaded through `shared_preload_libraries` to keep local model work inside the database process. You can ask for model work from SQL, queue it from rows, refresh semantic state after source changes, and inspect the result without leaving Postgres

## Quick Example

After setup creates the default worker runtime, the demo registers two local GGUF models. The model paths come from `./scripts/otlet-setup.sh`; the [worked example](docs/otlet-worked-example.md) shows the full copy/paste setup. I trimmed the local demo output below for width

The LLM runs inside Postgres: the `otlet worker` background worker loads linked llama.cpp, tries `linked_qwen_0_6b` first, and escalates hard rows to `linked_qwen_1_7b`

```sql
SELECT name AS model_name FROM otlet.register_model('linked_qwen_0_6b', '<Qwen3-0.6B-Q8_0.gguf>');
SELECT name AS model_name FROM otlet.register_model('linked_qwen_1_7b', '<Qwen3-1.7B-Q8_0.gguf>');
```

```text
    model_name
------------------
 linked_qwen_0_6b
(1 row)

    model_name
------------------
 linked_qwen_1_7b
(1 row)
```

The task reads candidate vendor pairs, joins the source rows, and builds compact row-pair JSON for the model:

```sql
SELECT p.pair_id, r.legal_name AS right_name, left(r.notes, 55) || '...' AS evidence
FROM public.otlet_demo_vendor_pair p
JOIN public.otlet_demo_vendor_entity r ON r.id = p.right_id
ORDER BY p.pair_id
LIMIT 3;
```

```text
        pair_id         |          right_name           |                          evidence
------------------------+-------------------------------+------------------------------------------------------------
 vendor-1001:vendor-313 | North Star Medical Logistics  | medical logistics broker; same building and similar nam...
 vendor-1001:vendor-314 | Northstar Freight Canada Inc. | freight carrier with similar brand; different country, ...
 vendor-1001:vendor-42  | N-Star Freight Services       | same remittance account ending 8821; internal note says...
(3 rows)
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
 queued_jobs
-------------
           4
(1 row)

       subject_id       |      match       | confidence
------------------------+------------------+------------
 vendor-1001:vendor-313 | different_entity | high
 vendor-1001:vendor-314 | different_entity | high
 vendor-1001:vendor-42  | same_entity      | high
 vendor-1001:vendor-77  | different_entity | high
(4 rows)
```

Otlet keeps the model-selection and action trail in Postgres:

`cheap` and `strong` are selection roles for the two registered models

```sql
SELECT subject_id, selection_role AS role, selection_status AS status, model_name AS model, output->>'match' AS match
FROM otlet.model_selection_attempts
WHERE task_name = 'entity_resolution_demo'
  AND subject_id IN ('vendor-1001:vendor-313', 'vendor-1001:vendor-42')
ORDER BY subject_id, attempt_index;

SELECT action_type, status, approval_status AS approval, count(*) AS actions
FROM otlet.action_status WHERE task_name = 'entity_resolution_demo'
GROUP BY action_type, status, approval_status ORDER BY action_type;
```

```text
       subject_id       |  role  |  status  |      model       |      match
------------------------+--------+----------+------------------+------------------
 vendor-1001:vendor-313 | cheap  | failed   | linked_qwen_0_6b |
 vendor-1001:vendor-313 | strong | accepted | linked_qwen_1_7b | different_entity
 vendor-1001:vendor-42  | cheap  | accepted | linked_qwen_0_6b | same_entity
(3 rows)

   action_type   |  status  |   approval   | actions
-----------------+----------+--------------+---------
 merge_candidate | approved | approved     |       1
 new_entity      | proposed | not_required |       2
 new_entity      | rejected | rejected     |       1
(3 rows)
```

Receipts expose schema validation, token counts, bounded traces, and output hashes:

```sql
SELECT subject_id, selection_role AS role, status, schema_validation_status AS schema,
       prompt_tokens AS prompt, generated_tokens AS output,
       detailed_trace_captured_tokens AS traced,
       left(receipt_raw_output_hash, 8) AS hash
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'entity_resolution_demo'
ORDER BY subject_id, attempt_index LIMIT 4;
```

```text
       subject_id       |  role  |  status  | schema | prompt | output | traced |   hash
------------------------+--------+----------+--------+--------+--------+--------+----------
 vendor-1001:vendor-313 | cheap  | failed   | failed |    801 |     39 |     16 | 88821dee
 vendor-1001:vendor-313 | strong | complete | passed |    801 |     66 |     16 | 66f14495
 vendor-1001:vendor-314 | cheap  | failed   | failed |    806 |    178 |     16 | b0287f64
 vendor-1001:vendor-314 | strong | complete | passed |    806 |     54 |     16 | 837b8e2f
(4 rows)
```

Source rows stayed in `public.otlet_demo_vendor_entity`. Otlet stored jobs, accepted outputs, failed attempts, receipts, trace state, and typed actions under `otlet`

## Docs

Start with [the worked example](docs/otlet-worked-example.md)

You run the extension with SQL commands and real output. The worked example starts with the direct task path, then covers semantic indexes, automatic semantic materialization, stale rows, FDW, CustomScan, cancellation, retries, worker batches, traces, and production policy

See [docs/roadmap.md](docs/roadmap.md) for future work

## License

MIT, see [LICENSE](LICENSE)
