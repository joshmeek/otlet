# Otlet roadmap

Otlet makes local model work feel like database work. Postgres plans model calls, runs them beside source rows, checks schemas, ties results to row identity, exposes state through SQL, and records receipts

Use this roadmap to judge changes. Add a feature when it improves model choice, row freshness, planner behavior, operator visibility, review state, action safety, or production packaging

## Current Shape

Otlet has three public surfaces today:

| Surface | Purpose |
| --- | --- |
| `scripts/otlet-setup.sh` | build and start the local Postgres extension stack |
| `scripts/otlet-demo.sh` | run the worked demo path with local inference |
| `benchmarks/run.sh` | compare local GGUF models on Otlet-specific SQL, receipt, action, row-watch, materialization, stale, and planner contracts |

Otlet keeps source rows in user tables. Users choose rows with SQL. `otlet.ask(...)` handles one-off row questions through the resident worker, while named tasks handle repeatable watches, queues, semantic refresh, and model selection. Otlet passes compact JSON to resident local models, runs cheap-first model selection when a task has a policy, drains bounded compatible queue batches, and stores derived outputs, attempts, actions, traces, receipts, eval labels, and semantic materializations under the `otlet` schema. The model harness uses a strict `output` plus `actions` envelope, stores invalid output as receipt evidence, and exposes decode mode through SQL

The current planner contract covers semantic lookup, fail-closed stale reads, queue refresh, wait, fresh inference, bounded CustomScan infer-now, FDW subject pushdown, cache decisions, and live EXPLAIN vocabulary. Cache keys, invalidation reasons, hit/miss counters, size bounds, runtime status, and demo checks are SQL-visible. Semantic row and join state tracks source updates, deletes, schema drift, contract changes, and candidate-set changes without silently reusing stale rows. Queue admission, fair claims, attempt bounds, cancellation, RSS budget failures, and malformed-schema failures produce clean SQL receipts and worker state

Reproduce the current contract with `./scripts/otlet-demo.sh` after `./scripts/otlet-setup.sh`

The benchmark lives under `benchmarks/` and reports SQL-scored evidence for Otlet behavior. Each score uses row JSON evidence and contract checks

## Priorities

| Order | Track | Outcome |
| --- | --- | --- |
| 1 | Packaging and security | Keep the open-source path small while tightening permissions and trace safety |
| 2 | Planner, executor, and cache | Tighten plan, status, and costing proof for semantic lookup, queue refresh, wait, fail-closed, fresh inference, and cache reuse |
| 3 | Explain and trace | Make bounded trace visibility useful without storing unbounded prompts or token streams |
| 4 | Semantic freshness | Prove row, join, delete, and candidate-set freshness without silent stale results |
| 5 | Action safety | Move from typed proposals to review queues, dry-run, approval, replay, eval labels, and no silent user-table writes |
| 6 | Managed Postgres packaging | Preserve the next-to-data thesis with a native worker where allowed and a SQL-bound external worker where providers block native workers |
| 7 | GPU acceleration | Add device-visible acceleration after the CPU resident-worker path has solid evidence |
| 8 | Core limits | Test Access Method and Postgres-fork paths where extension hooks fall short |

## Future Tracks

| Track | Outcome |
| --- | --- |
| SQL proposal actions | Let models propose bounded SQL through typed, inspectable actions with dry-run, approval, receipts, and no silent user-table writes |
| Review queue contract | Expose pending review, approval, rejection, correction, unclear state, reviewer reasons, and eval labels through SQL |
| Watch definition import/export | Make named source queries, candidate queries, stale policy, output schema, action schema, and runtime policy portable across installs |
| Persisted cache storage | Add disk-backed cache only after the bounded in-process cache misses a proven workload |
| Grammar-constrained decode | Retry grammar or JSON-schema decoding only behind a reliable linked llama hook; reject the exposed sampler path while it can abort the resident worker |
| Semantic dependency audit export | Export the source rows, joins, deletes, candidate-query changes, and schema-drift decisions that already drive stale/fresh state |
| Action execution sandbox | Prove dry-run, target allowlists, idempotency, approval, replay, failure receipts, and source-table write checks |
| Multi-worker admission policy | Extend the current queue, fairness, cancellation, RSS, and fail-closed policy when multiple workers share the same database |
| Managed Postgres deployment | Test the extension path where allowed and the customer-VPC agent path where providers block native workers |
| External worker protocol | Let a trusted process claim jobs, heartbeat, write receipts, actions, and results, and fail closed through SQL when native workers are unavailable |
| Entity resolution packs | Ship MIT vendor, customer, and product packs with candidate SQL, prompts, schemas, actions, fixtures, and benchmark gates |
| Audit export views | Expose decisions, receipts, source hashes, approvals, corrections, eval labels, and redacted trace summaries for export |
| Redaction policy | Keep prompt, source, trace, receipt, and export redaction configurable and visible through SQL |
| User-labeled eval loop | Turn accepted, rejected, and corrected actions into local eval cases and drift checks |

Keep SQL proposal actions out of the benchmark until Otlet has the typed action surface for them. Future benchmark cases score them through dry-run plans, approval records, receipts, and source-table write checks

Keep review surfaces SQL-first. Clients read queue, decision, approval, correction, eval, audit, and redaction state from stable views

Keep future tracks contract-first. For each feature, name the SQL-visible state, the closed failure mode, and the demo or benchmark proof

## Output Reliability

Otlet now treats output reliability as part of the database contract. Trusted entity-resolution output uses a fixed top-level `output` plus `actions` envelope. Invalid JSON, schema failures, bad action envelopes, false merges, and failed model attempts stay in receipts and diagnostic benchmark data, outside trusted output. The current Qwen3.5 4B benchmark pass is the leading single-run proof on the calibrated fixture; repeat runs and current small-model comparisons are the next proof step

Benchmark follow-up objective:

- Run current comparable model sweeps after harness changes so the public charts show workload roles, trusted quality, resource fit, and out-of-running reasons across small, medium, and ceiling local models. Routine benchmark runs use `include_by_default=true`; candidate, diagnostic, historical, heavy, and blocked rows stay explicit/manual
- Revisit grammar-constrained JSON only if the linked llama path exposes a hook that cannot abort the resident worker
- Keep improving prompt and schema wording against the same benchmark fixture
- Test a few larger local models to find the quality/resource knee before defaulting to bigger models

## Planner, Executor, And Cache

Use one inspectable decision vocabulary for semantic lookup, queue refresh, wait, fail-closed, fresh inference, bounded infer-now, and cache reuse. Keep SQL plan functions, semantic status views, FDW EXPLAIN, CustomScan EXPLAIN, receipts, and demo output aligned on that vocabulary

`EXPLAIN (ANALYZE, VERBOSE)` shows selected model, resident state, source identity, source hash, stale policy, cache decision, worker handoff, token counts, schema validation, trace policy, receipt IDs, provenance links, estimated model time, and model runtime

Keep cache work inside the existing runtime contract. Require cache keys, invalidation reasons, hit and miss counters, size bounds, EXPLAIN output, runtime status, and benchmark gates to agree. Add persisted cache storage after the bounded in-process cache misses a proven workload

Use measured runtime history for costing: load time, warm generation time, token counts, schema failures, cache hits, cache invalidation reasons, stale refresh rate, worker queue depth, model-selection attempts, and materialization coverage. Postgres chooses the cheap fresh lookup path when it can and shows the reason when it cannot

## Watch And Review Contracts

Use named watch definitions for source queries, candidate queries, output schemas, action schemas, stale policies, model policies, and trigger or schedule policy. The watch record owns the durable contract. Source tables stay under application control

Expose the review queue through SQL. Each row shows task, subject, decision, confidence, action type, approval state, correction state, stale state, schema status, receipt ID, source identity, and reviewer reason

Turn approval, rejection, correction, and unclear decisions into eval labels without exporting source data. Keep queue views stable for psql, dashboards, and other clients

## Semantic Freshness

Otlet covers more than one source row. It tracks the source dependencies behind row indexes, semantic joins, candidate queries, deletes, and schema changes so stale state fails closed or refreshes before lookup

For each answer, record the source rows read, trusted hash or MVCC identity, candidate set, and reason a later query reused or rejected the materialized state

## Entity Resolution Packs

Ship MIT packs for vendor, customer, and product resolution. Each pack carries candidate SQL, input shape, output schema, action schema, prompt text, fixture rows, eval labels, and benchmark gates

Keep packs small enough to audit. A pack can depend on SQL candidate generation, schema validation, receipts, review queues, and eval labels. Packs expose source writes only through typed actions

## Explain And Trace

Use verbose EXPLAIN to inspect model work from Postgres. Users see why Otlet reused a materialized result, refreshed a row, waited, failed closed, or ran infer-now

Keep token-level tracing optional and bounded. Debug mode shows chosen token IDs, token text, probabilities or logprobs when llama.cpp exposes them, top-k alternatives, partial generated text, stop reason, schema validation, and trace storage policy

Production defaults keep tracing low-detail or off. SQL explains disabled tracing without storing unbounded token streams

Expose audit export views for decisions, receipts, source hashes, approvals, corrections, eval labels, and redacted trace summaries. Exports show why Otlet trusted, rejected, refreshed, or failed closed for each decision

## Action Safety

Keep the action lifecycle explicit: proposed, pending review, approved, rejected, corrected, unclear, dry-run passed, applied, and failed. SQL functions record reviewer reason and write eval labels from accepted, rejected, and corrected decisions

Require source-table apply paths to run through target allowlists, dry-run plans, idempotency keys, approval records, replay checks, and failure receipts

## Packaging And Security

Keep open-source packaging small: one setup script, one demo script, a small model path, Docker instructions, crash-log scanning, CPU-only defaults, resource warnings, extension versioning, and upgrade notes

Cover schema permissions, model artifact path permissions, allowed write targets, action approval, prompt visibility, trace visibility, row-level security, superuser requirements, and extension install risk. Redact traces with care because prompts and token traces can contain source values

Define redaction policy for prompts, source values, traces, receipts, review queues, and audit exports. SQL status views show the active policy and the fields withheld

Use admission control to keep Postgres predictable under model load: per-task budgets, queue fairness, cancellation, worker RSS policy, model unload behavior, and fail-closed semantics under pressure

## Managed Postgres Packaging

Avoid duplicate databases. Prefer the native extension where providers allow it. Providers that block native workers use an external worker that claims jobs, heartbeats, reads bounded source rows through watch definitions, and writes Otlet outputs, receipts, actions, approvals, and eval labels back into `otlet.*`

Keep the external worker protocol SQL-bound. Leases, source identity, runtime status, memory policy, receipt hashes, failure reasons, and stale-state decisions must remain visible from Postgres

## GPU Acceleration

Add GPU support after the CPU path has solid evidence. Report device policy, memory accounting, throughput per watt, crash behavior, and EXPLAIN-visible device state

Keep the SQL contract the same: resident worker, source rows in user tables, derived state under `otlet`, schema-validated outputs, receipts, and EXPLAIN-visible runtime state

## Core Limits

Keep the Access Method track evidence-driven. Test honest `CREATE ACCESS METHOD`, `IndexAmRoutine`, operator classes, `amcostestimate`, tuple/TID semantics, build, insert, vacuum, update, and bitmap/gettuple paths. If PostgreSQL extension APIs cannot represent semantic model access without lying, document the exact missing contract and keep the CustomScan path as the extension answer

If extension APIs hit a hard ceiling, prove the missing planner or executor contract with a small Postgres fork. Keep the extension as the public path unless a fork proves a capability that PostgreSQL cannot expose through hooks

## Boundaries

Keep these constraints in place while the roadmap changes:

- Local inference runs through the resident Postgres worker
- Source rows stay in user tables
- Derived state lives under the `otlet` schema
- Trusted outputs pass schema validation
- User-table writes require typed actions and receipts
- Review state, eval labels, and audit exports stay in SQL
- Stale semantic state uses explicit policy
- Prompt, cache, trace, and output storage stay bounded
- SQL generates candidates before model judgment
- Named watches define source, candidate, stale, schema, and runtime policy
- External workers use `otlet.*` lease and receipt APIs and avoid duplicate database state
- EXPLAIN and SQL views expose model work
