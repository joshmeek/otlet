# Otlet roadmap

Otlet makes local model work feel like database work: Postgres plans it, runs it beside source rows, checks schemas, ties results to row identity, exposes state through SQL, and records receipts

Use this roadmap to judge future changes. A feature belongs here when it improves model choice, row freshness, planner behavior, operator visibility, action safety, or production packaging

## Current Shape

Otlet has two public entry points today:

| Surface | Purpose |
| --- | --- |
| `scripts/otlet-setup.sh` | build and start the local Postgres extension stack |
| `scripts/otlet-demo.sh` | run the worked demo path with local inference |

The extension keeps source rows in user tables. Users choose rows with SQL, Otlet passes compact JSON to resident local models, runs cheap-first model selection when a task has a policy, drains bounded compatible queue batches, and Postgres stores derived outputs, attempts, actions, traces, receipts, and semantic materializations under the `otlet` schema

## Priorities

| Order | Track | Outcome |
| --- | --- | --- |
| 1 | Packaging and security | Keep the open-source path small while tightening permissions and trace safety |
| 2 | Core limits | Test Access Method and Postgres-fork paths where extension hooks fall short |

## Planner And Executor

The planner path has one inspectable decision vocabulary for semantic lookup, queue refresh, wait, fail-closed, fresh inference, and bounded infer-now. Keep SQL plan functions, semantic status views, FDW EXPLAIN, CustomScan EXPLAIN, receipts, and demo output aligned on that vocabulary

`EXPLAIN (ANALYZE, VERBOSE)` shows selected model, resident state, source identity, source hash, stale policy, cache decision, worker handoff, token counts, schema validation, trace policy, receipt IDs, provenance links, estimated model time, and model runtime

Costing uses measured runtime history: load time, warm generation time, token counts, schema failures, cache hits, stale refresh rate, worker queue depth, model-selection attempts, and materialization coverage. Postgres chooses the cheap fresh lookup path when it can and shows the reason when it cannot

Keep the Access Method track evidence-driven. Test honest `CREATE ACCESS METHOD`, `IndexAmRoutine`, operator classes, `amcostestimate`, tuple/TID semantics, build, insert, vacuum, update, and bitmap/gettuple paths. If PostgreSQL extension APIs cannot represent semantic model access without lying, document the exact missing contract and keep the CustomScan path as the extension answer

## Explain And Trace

Verbose EXPLAIN makes model work inspectable from Postgres. Users see why Otlet reused a materialized result, refreshed a row, waited, failed closed, or ran infer-now

Keep token-level tracing optional and bounded. Debug mode can show chosen token IDs, token text, probabilities or logprobs when llama.cpp exposes them, top-k alternatives, partial generated text, stop reason, schema validation, and trace storage policy

Production defaults keep tracing low-detail or off. SQL explains disabled tracing without storing unbounded token streams

## Packaging And Security

Open-source packaging keeps the first run small: one setup script, one demo script, a small model path, Docker instructions, crash-log scanning, CPU-only defaults, resource warnings, extension versioning, and upgrade notes

Security work covers schema permissions, model artifact path permissions, allowed write targets, action approval, prompt visibility, trace visibility, row-level security, superuser requirements, and extension install risk. Trace redaction needs special care because prompts and token traces can contain source values

GPU support belongs on an acceleration track after the CPU path has solid evidence. A useful GPU release reports device policy, memory accounting, throughput per watt, crash behavior, and EXPLAIN-visible device state

If extension APIs hit a hard ceiling, a small Postgres fork proof must show the missing planner or executor contract. Keep the extension as the public path unless a fork proves a capability that PostgreSQL cannot expose through hooks

## Boundaries

Keep these constraints in place while the roadmap changes:

- Local inference runs through the resident Postgres worker
- Source rows stay in user tables
- Derived state lives under the `otlet` schema
- Trusted outputs pass schema validation
- User-table writes require typed actions and receipts
- Stale semantic state uses explicit policy
- Prompt, cache, trace, and output storage stay bounded
- SQL generates candidates before model judgment
- EXPLAIN and SQL views expose model work
