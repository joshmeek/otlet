# Otlet roadmap

Otlet should make local model work feel like database work: planned by Postgres, run beside source rows, checked against schemas, tied to row identity, visible through SQL, and recorded with receipts

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
| 1 | Actions | Let models propose typed database actions with receipts and approval |
| 2 | Packaging and security | Keep the open-source path small while tightening permissions and trace safety |
| 3 | Core limits | Test Access Method and Postgres-fork paths where extension hooks fall short |

## Planner And Executor

The planner path now has one inspectable decision vocabulary for semantic lookup, queue refresh, wait, fail-closed, fresh inference, and bounded infer-now. SQL plan functions, semantic status views, FDW EXPLAIN, CustomScan EXPLAIN, receipts, and demo output should stay aligned on that vocabulary

`EXPLAIN (ANALYZE, VERBOSE)` should keep showing selected model, resident state, source identity, source hash, stale policy, cache decision, worker handoff, token counts, schema validation, trace policy, receipt IDs, provenance links, estimated model time, and actual model time

Costing should use measured runtime history: load time, warm generation time, token counts, schema failures, cache hits, stale refresh rate, worker queue depth, model-selection attempts, and materialization coverage. Postgres should choose the cheap fresh lookup path when it can, and show the reason when it cannot

The Access Method track should stay evidence-driven. We should try honest `CREATE ACCESS METHOD`, `IndexAmRoutine`, operator classes, `amcostestimate`, tuple/TID semantics, build, insert, vacuum, update, and bitmap/gettuple paths. If PostgreSQL extension APIs cannot represent semantic model access without lying, document the exact missing contract and keep the CustomScan path as the extension answer

## Explain And Trace

Verbose EXPLAIN should make model work inspectable from Postgres. Users should see why Otlet reused a materialized result, refreshed a row, waited, failed closed, or ran infer-now

Token-level tracing should stay optional and bounded. Debug mode can show chosen token IDs, token text, probabilities or logprobs when llama.cpp exposes them, top-k alternatives, partial generated text, stop reason, schema validation, and trace storage policy

Production defaults should keep tracing low-detail or off. The system should explain disabled tracing through SQL instead of storing unbounded token streams

## Actions

Otlet should start with typed actions before model-written SQL. Useful action types include record creation, review flags, merge proposals, refresh requests, follow-up jobs, notes, and update proposals

Each action should carry JSON Schema validation, source row IDs, source hashes, receipt ID, model hash, prompt hash, dry-run result, approval status, applied timestamp, and rollback or provenance hints. Risky actions should wait for human approval through SQL or an external UI

Model-compiled SQL can come later through a constrained path. The model proposes intent or an AST, Otlet validates allowed schemas, tables, columns, functions, and write targets, runs `EXPLAIN`, stores a dry-run receipt, then applies the action after policy or human approval

## Packaging And Security

Open-source packaging should keep the first run small: one setup script, one demo script, a small model path, Docker instructions, crash-log scanning, CPU-only defaults, resource warnings, extension versioning, and upgrade notes

Security work should cover schema permissions, model artifact path permissions, allowed write targets, action approval, prompt visibility, trace visibility, row-level security, superuser requirements, and extension install risk. Trace redaction needs special care because prompts and token traces can contain source values

GPU support belongs on an acceleration track after the CPU path has solid evidence. A useful GPU release would report device policy, memory accounting, throughput per watt, crash behavior, and EXPLAIN-visible device state

If extension APIs hit a hard ceiling, a small Postgres fork proof should show the missing planner or executor contract. The extension should remain the public path unless a fork proves a capability that PostgreSQL cannot expose through hooks

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
