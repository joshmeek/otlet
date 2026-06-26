# Otlet

Otlet is a Postgres extension that runs local LLM inference **inside Postgres**, next to the rows it reads and acts on

My use case for building it came from an entity-resolution problem: when new data lands, Postgres should help decide whether a row is a new entity or a duplicate of something already in the database. Otlet runs through a resident Postgres worker, can try a cheap local model before escalating hard rows to a stronger local model, records receipts and source identity, drains bounded queued work, and materializes results for later queries. The [roadmap](docs/roadmap.md) tracks the path toward action safety, packaging, and deeper planner work

Otlet uses a `pgrx` extension and a Postgres background worker loaded through `shared_preload_libraries` to keep local model work inside the database process. You can ask for model work from SQL, queue it from rows, refresh semantic state after source changes, and inspect the result without leaving Postgres

## Design

Otlet keeps the model inside Postgres instead of sending rows to a sidecar service. The extension uses `pgrx`; Postgres loads it with `shared_preload_libraries` and starts a resident background worker. That worker talks to Postgres through SPI, so it claims work and writes results through normal SQL

The loop is small:

1. You write a task query over your own tables
2. The query returns a stable `subject_id` and compact `input jsonb`
3. Otlet stores one job per subject in `otlet.jobs`
4. The worker claims jobs with `FOR UPDATE SKIP LOCKED`
5. The worker drains compatible queued jobs against warm local GGUF models
6. Otlet validates the JSON output before storing it
7. Low-confidence, unclear, or schema-failed cheap attempts can escalate to a stronger resident model
8. Semantic refresh jobs create Otlet-owned records and fresh materialized state automatically

Otlet leaves your source rows alone. It stores derived outputs, actions, receipts, traces, and runtime state under the `otlet` schema. To avoid reusing stale model output, Otlet tracks MVCC identity (`ctid`, `xmin`) and source hashes, and Postgres triggers mark semantic materializations stale when source rows change

The planner-facing pieces make that derived state usable from SQL. FDW and CustomScan hooks let Postgres read Otlet-owned semantic state during query planning and execution. Receipts, trace rows, runtime slots, queue status, and production policy views show job status, token use, cache behavior, stale state, cleanup state, model residency, and worker health

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
  ('vendor-1001', 'Northstar Logistics LLC', 'northstar-logistics.example', '41 W Lake St, Chicago, IL', 'legacy freight vendor from the 2021 import; AP contact is ops@northstar-logistics.example'),
  ('vendor-42', 'N-Star Freight Services', 'nstar-freight.example', '41 West Lake Street, Suite 900, Chicago', 'same remittance account ending 8821; internal note says Northstar rebranded after acquisition'),
  ('vendor-77', 'Clearwater Medical Supplies', 'clearwatermed.example', '500 Hospital Way, Phoenix, AZ', 'hospital supply distributor; no shared tax id, domain, payment account, AP contact, remittance account, city, or industry with the freight vendor'),
  ('vendor-313', 'North Star Medical Logistics', 'northstarmedlog.example', '41 West Lake Street, Chicago, IL', 'medical logistics broker; same building and similar name, but different domain, payment account, AP contact, and no acquisition note'),
  ('vendor-314', 'Northstar Freight Canada Inc.', 'northstar-canada.example', '88 King St W, Toronto, ON', 'freight carrier with similar brand; different country, bank account, AP contact, and no shared remittance account in the ledger');
```

The second argument to `otlet.create_task` is the source query. That is where you choose the table and the rows. Here the query receives candidate row-id pairs, joins the table twice by primary key, and turns each pair into one model input. It is not doing a fuzzy join or scanning every possible pair:

```sql
SELECT name, model_name
FROM otlet.create_task(
  'entity_resolution_example',
  $$
    WITH candidate_pairs(pair_id, left_id, right_id) AS (
      VALUES
        ('vendor-1001:vendor-42', 'vendor-1001', 'vendor-42'),
        ('vendor-1001:vendor-77', 'vendor-1001', 'vendor-77'),
        ('vendor-1001:vendor-313', 'vendor-1001', 'vendor-313'),
        ('vendor-1001:vendor-314', 'vendor-1001', 'vendor-314')
    )
    SELECT
      p.pair_id AS subject_id,
      jsonb_build_object(
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
          WHEN 'vendor-1001:vendor-313' THEN jsonb_build_array(
            'same office building and similar North Star name',
            'medical logistics versus freight vendor',
            'different domain, payment account, AP contact, and no acquisition note',
            'weak signals conflict with important identifiers'
          )
          WHEN 'vendor-1001:vendor-314' THEN jsonb_build_array(
            'similar Northstar freight brand',
            'different country, bank account, AP contact, and no shared remittance account',
            'no acquisition or rebrand note connecting the records',
            'name similarity alone is not enough'
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
    FROM candidate_pairs p
    JOIN public.vendor_entity l ON l.id = p.left_id
    JOIN public.vendor_entity r ON r.id = p.right_id
  $$,
  'Use input.candidate_evidence as authority before names or notes. Return same_entity with high confidence when evidence contains shared remittance, rebrand, or acquisition. Return different_entity with high confidence when evidence says no shared identifiers or different industry and city. Return unclear with medium confidence when evidence says weak signals conflict or name similarity alone is not enough. Do not add prose, markdown, labels, nested output, or action strings.',
  '{"type":"object","required":["match","confidence","reason"],"additionalProperties":false,"properties":{"match":{"enum":["same_entity","different_entity","unclear"]},"confidence":{"enum":["low","medium","high"]},"reason":{"type":"string"}},"allOf":[{"if":{"properties":{"match":{"const":"same_entity"}},"required":["match"]},"then":{"properties":{"reason":{"pattern":"remittance|rebrand|acquisition"}}}},{"if":{"properties":{"match":{"const":"different_entity"}},"required":["match"]},"then":{"properties":{"reason":{"pattern":"no shared|different"}}}}]}'::jsonb,
  'linked_qwen_0_6b',
  '{"max_tokens":256,"reasoning":"off"}'::jsonb
);

SELECT otlet.set_model_selection_policy(
  'entity_resolution_example',
  'linked_qwen_0_6b',
  'linked_qwen_1_7b'
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
           4
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
      subject_id       |      match       | confidence
-----------------------+------------------+------------
 vendor-1001:vendor-313 | same_entity      | high
 vendor-1001:vendor-314 | same_entity      | high
 vendor-1001:vendor-42  | same_entity      | high
 vendor-1001:vendor-77  | different_entity | high
(4 rows)
```

Inspect model attempts:

```sql
SELECT
  subject_id,
  attempt_index,
  selection_role,
  selection_status,
  model_name,
  output->>'match' AS match
FROM otlet.model_selection_attempts
WHERE task_name = 'entity_resolution_example'
ORDER BY subject_id, attempt_index;
```

Representative output:

```text
      subject_id       | attempt_index | selection_role | selection_status |    model_name    |      match
-----------------------+---------------+----------------+------------------+------------------+------------------
 vendor-1001:vendor-313 |             1 | cheap          | failed           | linked_qwen_0_6b |
 vendor-1001:vendor-313 |             2 | strong         | accepted         | linked_qwen_1_7b | same_entity
 vendor-1001:vendor-314 |             1 | cheap          | accepted         | linked_qwen_0_6b | same_entity
 vendor-1001:vendor-42  |             1 | cheap          | accepted         | linked_qwen_0_6b | same_entity
 vendor-1001:vendor-77  |             1 | cheap          | accepted         | linked_qwen_0_6b | different_entity
```

The user table stayed untouched. Otlet stored jobs, accepted outputs, rejected or failed attempts, receipts, and trace state under the `otlet` schema, keyed by the `subject_id` values from the source query. The full demo script also proves cheap-first model selection with Qwen3 0.6B and Qwen3 1.7B, worker batch drain, typed `entity_hypothesis` actions, automatic semantic materialization, semantic join lookup, and stale results after a source row update

## Docs

Start with [the worked example](docs/otlet-worked-example.md)

You run the local extension with SQL commands and real output. You start with the direct task path, then work through semantic indexes, automatic semantic materialization, stale rows, FDW, CustomScan, cancellation, retries, worker batches, traces, and production policy

Future work is tracked in [docs/roadmap.md](docs/roadmap.md)

## License

MIT, see [LICENSE](LICENSE)
