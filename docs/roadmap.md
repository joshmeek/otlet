# Otlet roadmap

Otlet turns local model work into database work. Postgres plans model calls, runs them beside source rows, validates JSON, ties results to row identity, exposes SQL state, and records receipts

Use this roadmap to judge changes. Add a feature when it improves model choice, row freshness, planner behavior, operator visibility, review state, action safety, or production packaging

## Current Contract

Otlet exposes three proof surfaces:

| Surface | Purpose |
| --- | --- |
| `scripts/otlet-setup.sh` | build and start the local Postgres extension stack |
| `scripts/otlet-demo.sh` | run the worked demo path with local inference |
| `benchmarks/run.sh` | compare local GGUF models on Otlet SQL, receipts, actions, row watches, materialization, stale state, and planner contracts |

Otlet keeps source rows in user tables. Users select rows with SQL. `otlet.ask(...)` handles one-off row questions through the resident worker. Named watches own repeatable row and pair jobs, stale policy, candidate SQL, model policy, and runtime options. Otlet passes compact JSON to local GGUF models, runs cheap-first model selection for tasks with a policy, drains bounded queue batches, and stores outputs, attempts, actions, traces, receipts, eval labels, and semantic materializations under `otlet`

The model harness requires a top-level `output` plus `actions` envelope. Otlet stores invalid JSON, schema failures, rejected attempts, and rejected actions as receipt evidence instead of trusted output

The planner contract covers semantic lookup, fail-closed stale reads, queue refresh, wait, fresh inference, bounded CustomScan infer-now, current-row SQL lookup, cache decisions, and live EXPLAIN vocabulary. SQL exposes cache keys, invalidation reasons, hit/miss counters, size bounds, runtime status, source-dependency stale reasons, queue admission, fair claims, attempt bounds, cancellation, RSS budget failures, malformed-schema failures, and cleanup dry-run evidence

Run `./scripts/otlet-setup.sh`, then `./scripts/otlet-demo.sh` to prove the contract. Use `benchmarks/run.sh` for SQL-scored model comparisons

## Priority Order

| Order | Track | Status | Next work |
| --- | --- | --- | --- |
| 1 | Packaging and security | Active hardening | Keep setup and demo small; add permission, redaction, and upgrade proof |
| 2 | Output reliability and benchmark truth | Active hardening | Repeat model sweeps and keep prompt/schema changes on the same fixture |
| 3 | Planner, executor, and cache | Active hardening | Tighten costing, EXPLAIN parity, cache status, and benchmark gates |
| 4 | Explain and trace | Active hardening | Add audit export views and SQL-visible redaction status |
| 5 | Semantic freshness | Active hardening | Export dependency audits for rows, joins, deletes, candidate changes, and schema drift |
| 6 | Action safety | Active hardening | Extend typed actions to bounded SQL proposals, target allowlists, and idempotent replay |
| 7 | Managed Postgres packaging | Open | Test native workers where providers allow them and a SQL-bound agent where providers block them |
| 8 | GPU acceleration | Open | Add device policy after the CPU resident-worker path has measured proof |
| 9 | Core limits | Open research | Test Access Method and Postgres-fork paths for missing planner or executor contracts |

## Track Status

| Track | Status | Next contract |
| --- | --- | --- |
| Output reliability | Implemented, harden | Fixed `output` plus `actions` envelope, receipt evidence, benchmark gates, and repeat model sweeps |
| Planner, executor, and cache | Implemented, harden | SQL plan rows, semantic status views, CustomScan EXPLAIN, receipts, runtime/cache views, and demo output must agree |
| Review queue contract | Implemented | SQL exposes approval, rejection, correction, abstention, reviewer reason, stale state, receipts, and eval labels |
| Action lifecycle | Implemented, extend | Approval, rejection, dry-run, and apply paths work for typed actions; add bounded SQL proposal actions |
| Semantic freshness | Implemented, harden | Source updates, deletes, schema drift, contract changes, and candidate changes fail closed; add dependency audit export |
| Watch definitions | Implemented, extend | Row and pair watches carry source, candidate, schema, stale, model, and runtime policy; add import/export |
| Explain and trace | Implemented, harden | Bounded token traces and EXPLAIN vocabulary exist; add audit export views and redaction policy |
| User-labeled eval loop | Implemented | Accepted, rejected, and corrected actions export local eval cases; feed more labels into benchmark gates |
| Single-worker admission | Implemented | Queue caps, fair claims, cancellation, leases, RSS budgets, and cleanup checks exist; extend after multi-worker support lands |
| SQL proposal actions | Open | Define bounded SQL action schemas, dry-run plans, approvals, receipts, and source-table write checks |
| Grammar-constrained decode | Open | Add grammar or JSON-schema decode after linked llama exposes a worker-safe hook |
| Persisted cache storage | Open | Add disk-backed cache after a measured workload proves in-process cache misses hurt |
| Managed Postgres external worker | Open | Build a trusted SQL-bound worker that claims jobs, heartbeats, writes receipts, and fails closed |
| GPU acceleration | Open | Report device policy, memory accounting, throughput, crash behavior, and EXPLAIN-visible device state |
| Core limits | Open research | Test Access Method and fork paths when CustomScan cannot expose a required contract |
| Entity resolution packs | Open | Ship vendor, customer, and product packs with candidate SQL, prompts, schemas, actions, fixtures, and gates |
| Audit export and redaction | Open | Add views and policies for decisions, receipts, source hashes, approvals, corrections, eval labels, and trace summaries |

Keep open tracks contract-first. Name the SQL-visible state, the closed failure mode, and the demo or benchmark proof before adding code

## Output Reliability

Otlet treats output reliability as part of the database contract. Trusted output uses a fixed top-level `output` plus `actions` envelope. Invalid JSON, schema failures, bad action envelopes, false merges, and failed model attempts stay in receipts and diagnostic benchmark data, outside trusted output

The Qwen3.5 4B benchmark pass leads the calibrated fixture today. Repeat runs and small-model comparisons come next

Next benchmark work:

- Run comparable model sweeps after harness changes so public charts show workload roles, trusted quality, resource fit, and out-of-running reasons across small, medium, and ceiling local models
- Keep routine benchmark runs on `include_by_default=true`; keep candidate, diagnostic, historical, heavy, and blocked rows manual
- Revisit grammar-constrained JSON after linked llama exposes a hook that cannot abort the resident worker
- Keep prompt and schema changes on the same benchmark fixture
- Test larger local models to find the quality/resource knee before defaulting to bigger models

## Planner, Executor, And Cache

Use one decision vocabulary for semantic lookup, queue refresh, wait, fail-closed, fresh inference, bounded infer-now, and cache reuse. Keep SQL plan functions, semantic status views, CustomScan EXPLAIN, receipts, current-row SQL, and demo output aligned on that vocabulary

`EXPLAIN (ANALYZE, VERBOSE)` shows selected model, resident state, source identity, source hash, stale policy, cache decision, worker handoff, token counts, schema validation, trace policy, receipt IDs, provenance links, estimated model time, and model runtime

Keep cache work inside the runtime contract. Cache keys, invalidation reasons, hit and miss counters, size bounds, EXPLAIN output, runtime status, and benchmark gates must agree. Add persisted cache storage after a measured workload proves the bounded in-process cache misses hurt

Use measured runtime history for costing: load time, warm generation time, token counts, schema failures, cache hits, cache invalidation reasons, stale refresh rate, worker queue depth, model-selection attempts, and materialization coverage. Postgres chooses the cheap fresh lookup path when it can and shows the reason when it cannot

## Watch And Review Contracts

Named watch definitions carry source queries, candidate queries, output schemas, action schemas, stale policies, model policies, and trigger or schedule policy. The watch record owns the durable contract. Source tables stay under application control

The review queue exposes task, subject, decision, confidence, action type, approval state, correction state, stale state, schema status, receipt ID, source identity, and reviewer reason through SQL

Approval, rejection, correction, and unclear decisions create eval labels without exporting source data. Keep queue views stable for psql, dashboards, and other clients

Add watch import/export after the in-database contract stops changing

## Semantic Freshness

Otlet tracks the source dependencies behind row indexes, semantic joins, candidate queries, deletes, and schema changes. Stale state fails closed or refreshes before lookup

Each answer records the source rows read, trusted hash or MVCC identity, candidate set, and reuse/rejection reason for materialized state

Add dependency audit exports for the row, join, delete, candidate-query, and schema-drift decisions that drive stale/fresh state

## Entity Resolution Packs

Ship MIT packs for vendor, customer, and product resolution. Each pack carries candidate SQL, input shape, output schema, action schema, prompt text, fixture rows, eval labels, and benchmark gates

Keep packs small enough to audit. Packs can depend on SQL candidate generation, schema validation, receipts, review queues, and eval labels. Packs expose source writes through typed actions

## Explain And Trace

Use verbose EXPLAIN to inspect model work from Postgres. Users see why Otlet reused a materialized result, refreshed a row, waited, failed closed, or ran infer-now

Keep token-level tracing optional and bounded. Debug mode shows chosen token IDs, token text, probabilities or logprobs when llama.cpp exposes them, top-k alternatives, partial generated text, stop reason, schema validation, and trace storage policy

Production defaults keep tracing low-detail or off. SQL explains disabled tracing without storing unbounded token streams

Add audit export views for decisions, receipts, source hashes, approvals, corrections, eval labels, and trace summaries. Add redaction policy before exporting prompt, source, or token detail

## Action Safety

The current action lifecycle covers proposed, pending review, approved, rejected, corrected, unclear, dry-run passed, applied, and failed states. SQL functions record reviewer reason and write eval labels from accepted, rejected, and corrected decisions

Next action work adds bounded SQL proposal actions. Source-table apply paths need target allowlists, dry-run plans, idempotency keys, approval records, replay checks, and failure receipts

## Packaging And Security

Keep open-source packaging small: one setup script, one demo script, a small model path, Docker instructions, crash-log scanning, CPU-only defaults, resource warnings, extension versioning, and upgrade notes

Cover schema permissions, model artifact path permissions, allowed write targets, action approval, prompt visibility, trace visibility, row-level security, superuser requirements, and extension install risk. Redact traces because prompts and token traces can contain source values

Define redaction policy for prompts, source values, traces, receipts, review queues, and audit exports. SQL status views show the active policy and withheld fields

Use admission control to keep Postgres predictable under model load: per-task budgets, queue fairness, cancellation, worker RSS policy, model unload behavior, and fail-closed semantics under pressure

## Managed Postgres Packaging

Avoid duplicate databases. Prefer the native extension where providers allow it. Providers that block native workers use an external worker that claims jobs, heartbeats, reads bounded source rows through watch definitions, and writes Otlet outputs, receipts, actions, approvals, and eval labels back into `otlet.*`

Keep the external worker protocol SQL-bound. Leases, source identity, runtime status, memory policy, receipt hashes, failure reasons, and stale-state decisions stay visible from Postgres

## GPU Acceleration

Add GPU support after the CPU path has measured proof. Report device policy, memory accounting, throughput per watt, crash behavior, and EXPLAIN-visible device state

Keep the SQL contract fixed: resident worker, source rows in user tables, derived state under `otlet`, schema-validated outputs, receipts, and EXPLAIN-visible runtime state

## Core Limits

Keep the Access Method track evidence-driven. Test honest `CREATE ACCESS METHOD`, `IndexAmRoutine`, operator classes, `amcostestimate`, tuple/TID semantics, build, insert, vacuum, update, and bitmap/gettuple paths. If PostgreSQL extension APIs cannot represent semantic model access, document the missing contract and keep the CustomScan path as the extension answer

If extension APIs hit a hard ceiling, prove the missing planner or executor contract with a small Postgres fork. Keep the extension as the public path unless a fork proves a capability PostgreSQL cannot expose through hooks

## Boundaries

Keep these constraints in place while the roadmap changes:

- Local inference runs through the resident Postgres worker
- Source rows stay in user tables
- Derived state lives under the `otlet` schema
- Trusted outputs pass schema validation
- User-table writes require typed actions and receipts
- Review state and eval labels stay in SQL
- Future audit exports read SQL state
- Stale semantic state uses explicit policy
- Prompt, cache, trace, and output storage stay bounded
- SQL generates candidates before model judgment
- Named watches define source, candidate, stale, schema, and runtime policy
- Future external workers use `otlet.*` lease and receipt APIs
- EXPLAIN and SQL views expose model work
