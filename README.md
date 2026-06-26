# Otlet

Otlet is a Postgres extension that runs local LLM inference **inside Postgres**, next to the rows it reads and acts on

My use case for building it came from an entity-resolution problem: when new data lands, Postgres should help decide whether a row is a new entity or a duplicate of something already in the database. Otlet runs through a resident Postgres worker, can try a cheap local model before escalating hard rows to a stronger local model, records receipts and source identity, drains bounded queued work, stores typed action proposals, and materializes results for later queries. The [roadmap](docs/roadmap.md) tracks the path toward packaging, security, and deeper planner work

Otlet uses a `pgrx` extension and a Postgres background worker loaded through `shared_preload_libraries` to keep local model work inside the database process. You can ask for model work from SQL, queue it from rows, refresh semantic state after source changes, and inspect the result without leaving Postgres

## Quick Example

SQL picks hard candidate pairs. Otlet passes compact row-pair JSON to a resident local model inside Postgres, validates the answer, escalates hard rows to a stronger local model, and stores typed action proposals without mutating source tables

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

The interesting part is not string similarity. SQL selected pairs like:

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

Source rows stayed in `public.otlet_demo_vendor_entity`. Otlet stored jobs, accepted outputs, failed attempts, receipts, trace state, and typed actions under `otlet`

## Docs

Start with [the worked example](docs/otlet-worked-example.md)

You run the local extension with SQL commands and real output. You start with the direct task path, then work through semantic indexes, automatic semantic materialization, stale rows, FDW, CustomScan, cancellation, retries, worker batches, traces, and production policy

Future work is tracked in [docs/roadmap.md](docs/roadmap.md)

## License

MIT, see [LICENSE](LICENSE)
