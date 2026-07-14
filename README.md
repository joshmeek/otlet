# Otlet

Otlet is a Postgres extension that runs local LLM inference **inside Postgres**, next to the rows it reads and acts on

I started building it for an entity-resolution problem. New data arrived in Postgres, but the hard judgment would have to leave the database. I wanted a local model to do that work where the data already was, without copying rows into another system

Keeping inference beside the data is safer and more efficient because sensitive rows do not need to travel to a model provider. Postgres permissions, transactions, provenance, and audit state stay in the path, and the application avoids a separate data-export and result-ingest pipeline. The resulting decisions and feedback keep compounding in a system the institution owns

Otlet uses a `pgrx` extension and a resident Postgres background worker. You can ask for model work from SQL, queue work over rows, refresh derived state after source changes, and inspect the result without leaving Postgres

## Quick Example

Assume `qwen35_4b` is registered and `customer_notes` contains the rows. Pass the `SELECT` result to `otlet.ask`:

```sql
SELECT output
FROM otlet.ask(
  'qwen35_4b',
  'Summarize these customer notes in one sentence.',
  (SELECT jsonb_agg(to_jsonb(n))
   FROM customer_notes n WHERE customer = 'Riverline Labs'),
  '{"type":"object","required":["summary"],"additionalProperties":false,"properties":{"summary":{"type":"string"}}}'
);
```

One run returned:

```text
                                                                 output
----------------------------------------------------------------------------------------------------------------------------------------
 {"summary": "Riverline Labs requests CSV export, clarification on Otlet's source table changes, and a procurement summary by Friday."}
(1 row)
```

Otlet ran the model beside the selected rows, validated the JSON, and recorded a receipt under `otlet`

## Longer Example

Entity resolution uses a cheap local model for the first pass and a stronger local model when the first answer does not meet the decision contract. Start the local runtime, then register both GGUF files:

```sh
./scripts/otlet-setup.sh
```

```sql
SELECT name
FROM otlet.register_model('qwen3_1_7b', '/var/lib/postgresql/otlet-models/Qwen3-1.7B-Q8_0.gguf')
UNION ALL
SELECT name
FROM otlet.register_model('qwen35_4b', '/var/lib/postgresql/otlet-models/Qwen3.5-4B-Q4_K_M.gguf');
```

```text
    name
------------
 qwen3_1_7b
 qwen35_4b
(2 rows)
```

An Otlet task reads any SQL query that returns `subject_id` and row-shaped `input`. The [entity-resolution walkthrough](docs/entity-resolution-walkthrough.md) builds `public.otlet_demo_vendor_pair_input` from two application tables. The shortened task call includes the SQL API, output contract, trace settings, input shaping, and decision preset:

```sql
SELECT name, model_name
FROM otlet.create_task(
  task_name => 'entity_resolution_demo',
  input_query => $$
    SELECT subject_id, input
    FROM public.otlet_demo_vendor_pair_input
    ORDER BY subject_id
  $$,
  instruction => 'Decide whether each vendor pair is the same entity. Return match, confidence, a short reason, and one matching typed action.',
  output_schema => '{
    "type":"object",
    "required":["match","confidence","reason"],
    "additionalProperties":false,
    "properties":{
      "match":{"enum":["same_entity","different_entity","unclear"]},
      "confidence":{"enum":["low","medium","high"]},
      "reason":{"type":"string","maxLength":240}
    }
  }',
  model_name => 'qwen3_1_7b',
  runtime_options => '{"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":16,"generation_trace_top_k":3}',
  input_shaping => '{"evidence_fields":["candidate_evidence"],"action_id_fields":{"left_id":"left_id","right_id":"right_id"}}',
  decision_contract => '{"preset":"entity_resolution_evidence_v1"}'
);

SELECT task_name, cheap_model_name, strong_model_name
FROM otlet.set_model_selection_policy(
  'entity_resolution_demo', 'qwen3_1_7b', 'qwen35_4b'
);

SELECT otlet.run_task('entity_resolution_demo') AS queued_jobs;
```

```text
          name          | model_name
------------------------+------------
 entity_resolution_demo | qwen3_1_7b
(1 row)

       task_name        | cheap_model_name | strong_model_name
------------------------+------------------+-------------------
 entity_resolution_demo | qwen3_1_7b       | qwen35_4b
(1 row)

 queued_jobs
-------------
           4
(1 row)
```

Run the complete checked version, including the source rows and full instruction, with:

```sh
./scripts/otlet-demo.sh
```

One run produced these accepted outputs and typed actions. The query clips reasons to 48 characters:

```sql
SELECT r.subject_id, r.output->>'match' AS match,
       left(r.output->>'reason', 48) AS reason,
       a.action_type
FROM otlet.runs r
JOIN otlet.actions a ON a.job_id = r.job_id
WHERE r.task_name = 'entity_resolution_demo'
ORDER BY r.subject_id;
```

```text
       subject_id       |      match       |                      reason                      |   action_type
------------------------+------------------+--------------------------------------------------+-----------------
 vendor-1001:vendor-313 | different_entity | Conflicting stable identifiers found.            | new_entity
 vendor-1001:vendor-314 | different_entity | Conflicting stable identifiers: different countr | new_entity
 vendor-1001:vendor-42  | same_entity      | Same remittance account and tax ID match         | merge_candidate
 vendor-1001:vendor-77  | different_entity | Different industry and city; no shared identifie | new_entity
(4 rows)
```

Inspect the receipt trace for the matching pair. The cheap output passed JSON Schema and failed the stricter decision contract. Otlet escalated the pair to the strong model:

```sql
SELECT selection_role, selection_status, model_name,
       schema_validation_status, prompt_tokens, generated_tokens,
       runtime_fingerprint_hash IS NOT NULL AS fingerprinted
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'entity_resolution_demo'
  AND subject_id = 'vendor-1001:vendor-42'
ORDER BY attempt_index;
```

```text
 selection_role | selection_status | model_name | schema_validation_status | prompt_tokens | generated_tokens | fingerprinted
----------------+------------------+------------+--------------------------+---------------+------------------+---------------
 cheap          | rejected         | qwen3_1_7b | passed                   |           845 |               26 | t
 strong         | accepted         | qwen35_4b  | passed                   |           863 |              126 | t
(2 rows)
```

Otlet records both attempts and creates `merge_candidate` from the accepted output. The action requires operator approval. The source vendor rows remain unchanged

The full demo checks row and pair watches, candidate drift, CustomScan freshness, portable watch definitions, and bounded `update_row`. It covers receipt redaction, role grants, cancellation, model-load admission, memory pressure, cache bounds, prompt and runtime fingerprints, invariants, and Docker crash logs

## Docs

Start with [the worked example](docs/otlet-worked-example.md)

- [Entity resolution walkthrough](docs/entity-resolution-walkthrough.md)
- [Runtime and traces](docs/runtime-and-traces.md)
- [Semantic watches](docs/semantic-watches.md)
- [Production contract](docs/production-contract.md)
- [Model benchmarks](benchmarks/README.md)
- [Roadmap](docs/roadmap.md)

## License

MIT, see [LICENSE](LICENSE)
