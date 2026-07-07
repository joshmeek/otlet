# Otlet Worked Example

Use this as a learning file, not a test harness. The format follows _worked example_ research from [this study](https://www.tandfonline.com/doi/full/10.1080/01443410.2023.2273762#abstract)

You start with the smallest real Otlet loop for entity resolution: keep vendor rows in ordinary Postgres tables, select hard candidate pairs in SQL, enqueue durable model work, let the resident worker try a cheap local model and escalate hard rows to a stronger local model, validate `same_entity` / `different_entity` / `unclear`, record typed action proposals, and keep the audit trail

The example data uses vendors where string normalization fails. One pair is a rebrand with a shared remittance account and acquisition note. One pair has no shared identifiers and belongs in a separate entity. Two pairs carry weak name/address/brand signals that force harder model work. Otlet judges the pairs without mutating source tables

## Otlet In One Loop

```text
source candidate pair
  -> otlet.jobs row
  -> resident Postgres worker
  -> cheap local Qwen3 1.7B through llama.cpp
  -> stronger local Qwen3.5 4B when policy escalates
  -> JSON and action validation
  -> otlet.outputs
  -> otlet.actions
  -> otlet.records
  -> otlet.semantic_materializations
  -> otlet.inference_receipts
```

Otlet keeps Postgres as the system of record

Source tables stay under application control. Otlet sends the model bounded pair-shaped input and accepts structured JSON. Otlet validates output and typed actions before storage. Semantic refresh jobs create Otlet-owned `create_record` actions, records, and materialized semantic rows from validated output so downstream SQL can read fresh state

For one-off row questions, use `otlet.ask(...)`. It inlines the prompt, row JSON, output schema, and model name, then returns trusted output with `job_id` and `receipt_id`. Otlet writes the internal task, job, receipt, trace, and output rows. Named tasks below are for repeatable watches, queues, semantic refresh, and model selection

## Start From A Running Local Otlet

Build and start the local Postgres container first:

```sh
./scripts/otlet-setup.sh
```

Open `psql` with both local Qwen artifact paths available as variables:

```sh
docker exec -it otlet-postgres sh -lc '
  cheap_model_artifact="$(find /var/lib/postgresql -name Qwen3-1.7B-Q8_0.gguf -print -quit)"
  strong_model_artifact="$(find /var/lib/postgresql -name Qwen3.5-4B-Q4_K_M.gguf -print -quit)"
  psql -U postgres -d postgres \
    -v cheap_model_artifact="$cheap_model_artifact" \
    -v strong_model_artifact="$strong_model_artifact"
'
```

Paste the linked walkthrough sections into that `psql` session when you want the long form

Output blocks show representative output from real local runs. Job IDs, receipt IDs, timestamps, costs, timings, memory samples, and token rates vary by machine and model cache state

## Detailed Walkthroughs

Use these files when you want the long SQL walkthrough instead of the compact demo script:

- [Entity resolution walkthrough](entity-resolution-walkthrough.md)
- [Runtime and traces](runtime-and-traces.md)
- [Semantic watches](semantic-watches.md)
- [Production contract](production-contract.md)

## Run The Full Demo Contract

The repo includes a script that exercises the entity-resolution path used in this learning file:

```sh
./scripts/otlet-demo.sh
```

Representative contract output from the demo run:

```text
direct_ask_contract=review_payment|2|2
entity_resolution_contract=4|same_entity|different_entity|4|4
model_selection_status_contract=true|true|true|4|3
action_type_contract=merge_candidate|new_entity
source_write_contract=5|...|5|...
semantic_join_auto_materialized=4
receipt_trace_contract=8|8|8|8
```

Use that script as the compact regression proof. Use this Markdown to learn the same system
