# Entity-Resolution Starter Pack

The starter pack is an executable `otlet.watch.v1` example for vendor, account, and catalog-item matching. It uses the ordinary pair-watch, receipt, action, review, label, evaluation, export, and rollback contracts

The installer creates these fixture tables:

- `public.otlet_entity_resolution_starter_record`
- `public.otlet_entity_resolution_starter_pair`

The six pairs cover one match and one non-match for each fixture kind. Candidate SQL stops at 100 rows and sends only shaped identity evidence to the model

Register a strong local model, then run the installer from the repository mount:

```sh
docker exec -i otlet-postgres psql \
  -U postgres \
  -d postgres \
  -v strong_model_name=qwen35_4b \
  -f /work/examples/entity-resolution-starter-pack.sql
```

The script lints and imports the pack, creates `entity_resolution_starter_task`, and imports six portable evaluation labels. It does not add an entity-resolution engine or workflow language

Inspect the installed evidence:

```sql
SELECT version_number, content_digest, current_version,
       jsonb_array_length(fixtures) AS fixtures,
       jsonb_array_length(labels) AS labels,
       jsonb_array_length(expected_receipts) AS expected_receipts,
       jsonb_array_length(review_outcomes) AS review_outcomes,
       evaluation_gates
FROM otlet.watch_pack_history
WHERE watch_name = 'entity_resolution_starter'
ORDER BY version_number;
```

Run the pack through the bounded candidate path:

```sql
SET LOCAL statement_timeout = '2000ms';
SELECT otlet.refresh_semantic_join_index('entity_resolution_starter');
```

The complete Docker demo waits for all six jobs, checks expected outputs and receipts, approves the three merge candidates, materializes current semantic rows, evaluates every label, exports the exact pack, imports a changed version, and rolls back to version 1

```text
entity_resolution_starter_contract=true|true|true|true|true|true|true|true|true|true
entity_resolution_starter_rollback_contract=true|true|true|true|true
```

The pack stores fixture data, prompts, schema, single-model policy, labels, expected receipt shapes, review outcomes, and evaluation gates in the common pack document. Replace the fixture tables and model name for application data; keep source-field shaping, candidate bounds, and evaluation gates explicit
