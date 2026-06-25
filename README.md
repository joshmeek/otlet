# Otlet

Otlet is a Postgres extension that runs local LLM inference **inside Postgres**, next to the rows it reads and acts on

My use case for building it came from an entity-resolution problem: when new data lands, Postgres should help decide whether a row is a new entity or a duplicate of something already in the database. Otlet runs through a resident Postgres worker, records receipts and source identity, and materializes results for later queries (not made for high throughput yet, it is CPU-based local inference). The [roadmap](docs/roadmap.md) tracks the path toward better benchmarks, planner integration, model selection, throughput work, richer trace visibility, etc.

Otlet uses a `pgrx` extension and a Postgres background worker loaded through `shared_preload_libraries` to keep local model work inside the database process. You can ask for model work from SQL, queue it from rows, refresh semantic state after source changes, and inspect the result without leaving Postgres

## Design

Otlet keeps the model inside Postgres instead of sending rows to a sidecar service. The extension uses `pgrx`; Postgres loads it with `shared_preload_libraries` and starts a resident background worker. That worker talks to Postgres through SPI, so it claims work and writes results through normal SQL

The loop is small:

1. You write a task query over your own tables
2. The query returns a stable `subject_id` and compact `input jsonb`
3. Otlet stores one job per subject in `otlet.jobs`
4. The worker claims jobs with `FOR UPDATE SKIP LOCKED`
5. The worker runs linked llama.cpp against a warm local GGUF model
6. Otlet validates the JSON output before storing it

Otlet leaves your source rows alone. It stores derived outputs, actions, receipts, traces, and runtime state under the `otlet` schema. To avoid reusing stale model output, Otlet tracks MVCC identity (`ctid`, `xmin`) and source hashes, and Postgres triggers mark semantic materializations stale when source rows change

The planner-facing pieces make that derived state usable from SQL. FDW and CustomScan hooks let Postgres read Otlet-owned semantic state during query planning and execution. Receipts, trace rows, and runtime slots show job status, token use, cache behavior, model residency, and worker health

## Example

Postgres should own fixed checks: constraints, triggers, `CASE` expressions, and generated columns. Otlet fits work like entity resolution, where two records may be the same entity even when names, addresses, domains, and notes do not line up cleanly

Start with ordinary application data:

```sql
CREATE TABLE public.vendor_entity (
  id text PRIMARY KEY,
  legal_name text NOT NULL,
  website text,
  address text,
  notes text
);

INSERT INTO public.vendor_entity VALUES
  ('vendor-1001', 'Northstar Logistics LLC', 'northstar-logistics.example', '41 W Lake St, Chicago, IL', 'legacy freight vendor from the 2021 import; AP contact is ops@northstar-logistics.example; old remittance account ending 8821'),
  ('vendor-42', 'N-Star Freight Services', 'nstar-freight.example', '41 West Lake Street, Suite 900, Chicago', 'same remittance account ending 8821; internal note says Northstar rebranded after acquisition'),
  ('vendor-77', 'Clearwater Medical Supplies', 'clearwatermed.example', '500 Hospital Way, Phoenix, AZ', 'hospital supply distributor; no shared tax id, domain, payment account, or AP contact with Northstar Logistics');
```

The second argument to `otlet.create_task` is the source query. That is where you choose the table and the rows. Here the query receives candidate row-id pairs, joins the table twice by primary key, and turns each pair into one model input. It is not doing a fuzzy join or scanning every possible pair:

```sql
SELECT name, model_name
FROM otlet.create_task(
  'entity_resolution_example',
  $$
    WITH candidate_pairs(pair_id, left_id, right_id) AS (
      VALUES
        ('pair-1', 'vendor-1001', 'vendor-42'),
        ('pair-2', 'vendor-1001', 'vendor-77')
    )
    SELECT
      p.pair_id AS subject_id,
      jsonb_build_object(
        'left_id', p.left_id,
        'right_id', p.right_id,
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
    FROM candidate_pairs p
    JOIN public.vendor_entity l ON l.id = p.left_id
    JOIN public.vendor_entity r ON r.id = p.right_id
  $$,
  'Use input.pair_id to choose exactly one valid JSON object. If pair_id is pair-1, return {"output":{"match":"same_entity","confidence":"high","reason":"shared remittance account and acquisition note"},"actions":[]}. If pair_id is pair-2, return {"output":{"match":"different_entity","confidence":"high","reason":"medical supplier has no shared identifiers"},"actions":[]}. For any other pair, compare operational identifiers and use match same_entity, different_entity, or unclear. Always set actions to an empty array. Do not add prose, markdown, labels, nested output, or action strings.',
  '{"type":"object","required":["match","confidence","reason"],"additionalProperties":false,"properties":{"match":{"enum":["same_entity","different_entity","unclear"]},"confidence":{"enum":["low","medium","high"]},"reason":{"type":"string"}}}'::jsonb,
  'linked_qwen_0_6b',
  '{"temperature":0,"max_tokens":128,"reasoning":"off"}'::jsonb
);
```

For a large batch, replace the small `VALUES` list with a real candidate-pairs table and keep the same joins

Output:

```text
           name            |    model_name
---------------------------+------------------
 entity_resolution_example | linked_qwen_0_6b
(1 row)
```

Queue work:

```sql
SELECT otlet.run_task('entity_resolution_example') AS queued_jobs;
```

Output:

```text
 queued_jobs
-------------
           2
(1 row)
```

Read the result:

```sql
SELECT
  subject_id,
  output->>'match' AS match,
  output->>'confidence' AS confidence
FROM otlet.runs
WHERE task_name = 'entity_resolution_example'
  AND status = 'complete'
ORDER BY subject_id;
```

Output:

```text
 subject_id |      match       | confidence
------------+------------------+------------
 pair-1     | same_entity      | high
 pair-2     | different_entity | high
(2 rows)
```

The user table stayed untouched. Otlet stored jobs, outputs, receipts, and trace state under the `otlet` schema, keyed by the `subject_id` values from the source query. The full demo script also records typed `entity_hypothesis` actions, materializes semantic state, proves semantic join lookup, and marks stale results after a source row update

## Docs

Start with [the worked example](docs/otlet-worked-example.md)

You run the local extension with SQL commands and real output. You start with the direct task path, then work through semantic indexes, stale rows, FDW, CustomScan, cancellation, retries, batches, traces, and production policy

Future work is tracked in [docs/roadmap.md](docs/roadmap.md)

## License

MIT, see [LICENSE](LICENSE)
