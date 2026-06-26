# Otlet

Otlet is a Postgres extension that runs local LLM inference **inside Postgres**, next to the rows it reads and acts on

I built Otlet for entity resolution: when new data lands, Postgres helps decide whether a row is a new entity or a duplicate. Otlet runs through a resident Postgres worker, tries a cheap local model before escalating hard rows to a stronger local model, records receipts and source identity, drains bounded queued work, stores typed action proposals, and materializes results for later queries. The [roadmap](docs/roadmap.md) tracks packaging, security, and planner work

Otlet uses a `pgrx` extension and a Postgres background worker loaded through `shared_preload_libraries` to keep local model work inside the database process. You can ask for model work from SQL, queue it from rows, refresh semantic state after source changes, and inspect the result without leaving Postgres

## Quick Example

The demo task reads `public.otlet_demo_vendor_pair`, joins each side to `public.otlet_demo_vendor_entity`, and builds one compact JSON input per pair. Each input includes the two rows plus evidence such as shared remittance accounts, acquisition notes, missing identifiers, and conflicting name/address signals

Otlet asks the resident worker for `same_entity`, `different_entity`, or `unclear`, with confidence and a reason. The task starts with Qwen3 0.6B and escalates hard rows to Qwen3 1.7B. The model can propose typed actions like `merge_candidate` or `new_entity`; source rows stay untouched

The task input looks like this:

```sql
SELECT
  subject_id,
  input #>> '{left_record,legal_name}' AS left_name,
  input #>> '{right_record,legal_name}' AS right_name,
  input #>> '{candidate_evidence,0}' AS first_evidence
FROM public.otlet_demo_vendor_pair_input
ORDER BY subject_id
LIMIT 3;
```

```text
       subject_id       |        left_name        |          right_name           |                  first_evidence
------------------------+-------------------------+-------------------------------+--------------------------------------------------
 vendor-1001:vendor-313 | Northstar Logistics LLC | North Star Medical Logistics  | same office building and similar North Star name
 vendor-1001:vendor-314 | Northstar Logistics LLC | Northstar Freight Canada Inc. | similar Northstar freight brand
 vendor-1001:vendor-42  | Northstar Logistics LLC | N-Star Freight Services       | same remittance account ending 8821
```

```sql
SELECT otlet.run_task('entity_resolution_demo') AS queued_jobs;

SELECT
  subject_id,
  output->>'match' AS match,
  output->>'confidence' AS confidence
FROM otlet.runs
WHERE task_name = 'entity_resolution_demo'
ORDER BY subject_id;
```

Real output from `./scripts/otlet-demo.sh`:

```text
 queued_jobs
-------------
           4

       subject_id       |      match       | confidence
------------------------+------------------+------------
 vendor-1001:vendor-313 | different_entity | high
 vendor-1001:vendor-314 | different_entity | high
 vendor-1001:vendor-42  | same_entity      | high
 vendor-1001:vendor-77  | different_entity | high
```

Some pairs need evidence beyond string similarity. SQL sends evidence like:

```text
vendor-1001:vendor-42
  same remittance account ending 8821
  internal note says Northstar rebranded after acquisition

vendor-1001:vendor-77
  different industry and city
  no shared tax id, domain, payment account, AP contact, or remittance account

vendor-1001:vendor-313
  same office building and similar North Star name
  medical logistics versus freight vendor
  different domain, payment account, AP contact, and no acquisition note
```

Otlet keeps the trail in SQL:

```sql
SELECT
  subject_id,
  selection_role,
  selection_status,
  model_name,
  output->>'match' AS match
FROM otlet.model_selection_attempts
WHERE task_name = 'entity_resolution_demo'
ORDER BY subject_id, attempt_index;

SELECT action_type, status, approval_status, count(*) AS actions
FROM otlet.action_status
WHERE task_name = 'entity_resolution_demo'
GROUP BY action_type, status, approval_status
ORDER BY action_type;
```

```text
       subject_id       | selection_role | selection_status |    model_name    |      match
------------------------+----------------+------------------+------------------+------------------
 vendor-1001:vendor-313 | cheap          | failed           | linked_qwen_0_6b |
 vendor-1001:vendor-313 | strong         | accepted         | linked_qwen_1_7b | different_entity
 vendor-1001:vendor-42  | cheap          | accepted         | linked_qwen_0_6b | same_entity

   action_type   |  status  | approval_status | actions
-----------------+----------+-----------------+---------
 merge_candidate | proposed | required        |       1
 new_entity      | proposed | not_required    |       3
```

Postgres can inspect each model attempt, schema result, token count, bounded trace, and output hash:

```sql
SELECT
  subject_id,
  selection_role,
  status,
  schema_validation_status AS schema,
  prompt_tokens,
  generated_tokens,
  detailed_trace_captured_tokens AS traced_tokens,
  left(receipt_raw_output_hash, 8) AS output_hash
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'entity_resolution_demo'
ORDER BY subject_id, attempt_index
LIMIT 4;
```

```text
       subject_id       | selection_role |  status  | schema | prompt_tokens | generated_tokens | traced_tokens | output_hash
------------------------+----------------+----------+--------+---------------+------------------+---------------+-------------
 vendor-1001:vendor-313 | cheap          | failed   | failed |           801 |              139 |            16 | 8e564078
 vendor-1001:vendor-313 | strong         | complete | passed |           801 |               66 |            16 | 66f14495
 vendor-1001:vendor-314 | cheap          | failed   | failed |           806 |              192 |            16 | 908d9787
 vendor-1001:vendor-314 | strong         | complete | passed |           806 |               66 |            16 | 096a78cd
```

Source rows stayed in `public.otlet_demo_vendor_entity`. Otlet stored jobs, accepted outputs, failed attempts, receipts, trace state, and typed actions under `otlet`

## Docs

Start with [the worked example](docs/otlet-worked-example.md)

You run the extension with SQL commands and real output. The worked example starts with the direct task path, then covers semantic indexes, automatic semantic materialization, stale rows, FDW, CustomScan, cancellation, retries, worker batches, traces, and production policy

See [docs/roadmap.md](docs/roadmap.md) for future work

## License

MIT, see [LICENSE](LICENSE)
