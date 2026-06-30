# Otlet roadmap

Otlet makes local model work feel like database work. Postgres plans model calls, runs them beside source rows, checks schemas, ties results to row identity, exposes state through SQL, and records receipts

Use this roadmap to judge changes. Add a feature when it improves model choice, row freshness, planner behavior, operator visibility, action safety, or production packaging

## Current Shape

Otlet has three public surfaces today:

| Surface | Purpose |
| --- | --- |
| `scripts/otlet-setup.sh` | build and start the local Postgres extension stack |
| `scripts/otlet-demo.sh` | run the worked demo path with local inference |
| `benchmarks/run.sh` | compare local GGUF models on Otlet-specific SQL, receipt, action, row-watch, materialization, stale, and planner contracts |

Otlet keeps source rows in user tables. Users choose rows with SQL. Otlet passes compact JSON to resident local models, runs cheap-first model selection when a task has a policy, drains bounded compatible queue batches, and stores derived outputs, attempts, actions, traces, receipts, and semantic materializations under the `otlet` schema. The benchmark lives under `benchmarks/` and reports SQL-scored evidence for Otlet behavior. Each score uses row JSON evidence and contract checks

## Priorities

| Order | Track | Outcome |
| --- | --- | --- |
| 1 | Packaging and security | Keep the open-source path small while tightening permissions and trace safety |
| 2 | Constrained output reliability | Make small resident models produce schema-valid trusted state before hardware speed |
| 3 | Planner, executor, and cache | Tighten plan, status, and costing proof for semantic lookup, queue refresh, wait, fail-closed, fresh inference, and cache reuse |
| 4 | Explain and trace | Make bounded trace visibility useful without storing unbounded prompts or token streams |
| 5 | Semantic freshness | Prove row, join, delete, and candidate-set freshness without silent stale results |
| 6 | Action safety | Move from typed proposals to dry-run, approval, replay, and no silent user-table writes |
| 7 | Managed Postgres packaging | Preserve the next-to-data thesis when providers block native background workers |
| 8 | GPU acceleration | Add device-visible acceleration after the CPU resident-worker path has solid evidence |
| 9 | Core limits | Test Access Method and Postgres-fork paths where extension hooks fall short |

## Future Tracks

| Track | Outcome |
| --- | --- |
| SQL proposal actions | Let models propose bounded SQL through typed, inspectable actions with dry-run, approval, receipts, and no silent user-table writes |
| Cache contract | Put cache keys, invalidation reasons, hit rates, bounds, and EXPLAIN/runtime visibility in the SQL contract |
| Constrained output reliability | Test schema-constrained decoding, prompt compaction, abstain calibration, confidence labels, and strict action envelopes |
| Semantic dependency tracking | Track freshness across source rows, joins, deletes, candidate-query changes, and schema drift |
| Action execution sandbox | Prove dry-run, target allowlists, idempotency, approval, replay, failure receipts, and source-table write checks |
| Admission control and resource policy | Keep model work bounded with per-task budgets, queue fairness, cancellation, RSS policy, and fail-closed behavior |
| Managed Postgres deployment | Test the extension path where allowed and the customer-VPC agent path where providers block native workers |
| User-labeled eval loop | Turn accepted, rejected, and corrected actions into local eval cases and drift checks |

Keep SQL proposal actions out of the benchmark until Otlet has the typed action surface for them. Future benchmark cases score them through dry-run plans, approval records, receipts, and source-table write checks

Keep future tracks contract-first. For each feature, name the SQL-visible state, the closed failure mode, and the demo or benchmark proof

## Output Reliability

Use the benchmark to improve trusted state before publishing model rank. Test schema-constrained decoding, prompt compaction, abstain calibration, confidence labels, and action envelope parsing until small resident models pass production gates. Keep invalid JSON, false merges, and hallucinated actions in diagnostic data, outside trusted output

Benchmark follow-up objective:

- Improve structured output reliability before treating more model runs as the answer
- Tighten prompt and schema wording where benchmark failures come from harness or contract shape
- Test grammar-constrained JSON if llama.cpp exposes a small reliable path for it
- Show trusted quality, resource fit, and combined overall fit separately in benchmark reports
- Test a few larger local models to find the quality/resource knee before defaulting to bigger models

## Planner, Executor, And Cache

Use one inspectable decision vocabulary for semantic lookup, queue refresh, wait, fail-closed, fresh inference, bounded infer-now, and cache reuse. Keep SQL plan functions, semantic status views, FDW EXPLAIN, CustomScan EXPLAIN, receipts, and demo output aligned on that vocabulary

Make `EXPLAIN (ANALYZE, VERBOSE)` show selected model, resident state, source identity, source hash, stale policy, cache decision, worker handoff, token counts, schema validation, trace policy, receipt IDs, provenance links, estimated model time, and model runtime

Keep cache work inside the existing runtime contract. Require cache keys, invalidation reasons, hit and miss counters, size bounds, EXPLAIN output, runtime status, and benchmark gates to agree. Add persisted cache storage after the bounded in-process cache misses a proven workload

Use measured runtime history for costing: load time, warm generation time, token counts, schema failures, cache hits, cache invalidation reasons, stale refresh rate, worker queue depth, model-selection attempts, and materialization coverage. Postgres chooses the cheap fresh lookup path when it can and shows the reason when it cannot

## Semantic Freshness

Cover more than one source row. Track the source dependencies behind row indexes, semantic joins, candidate queries, deletes, and schema changes so stale state fails closed or refreshes before lookup

For each answer, record the source rows read, trusted hash or MVCC identity, candidate set, and reason a later query reused or rejected the materialized state

## Explain And Trace

Use verbose EXPLAIN to inspect model work from Postgres. Users see why Otlet reused a materialized result, refreshed a row, waited, failed closed, or ran infer-now

Keep token-level tracing optional and bounded. Debug mode shows chosen token IDs, token text, probabilities or logprobs when llama.cpp exposes them, top-k alternatives, partial generated text, stop reason, schema validation, and trace storage policy

Production defaults keep tracing low-detail or off. SQL explains disabled tracing without storing unbounded token streams

Turn accepted, rejected, and corrected actions into fixture rows for reruns and drift checks without exporting source data

## Packaging And Security

Keep open-source packaging small: one setup script, one demo script, a small model path, Docker instructions, crash-log scanning, CPU-only defaults, resource warnings, extension versioning, and upgrade notes

Cover schema permissions, model artifact path permissions, allowed write targets, action approval, prompt visibility, trace visibility, row-level security, superuser requirements, and extension install risk. Redact traces with care because prompts and token traces can contain source values

Before trusting any apply path, prove dry-run plans, target allowlists, idempotency keys, approval records, replay behavior, failure receipts, and source-table write checks

Use admission control to keep Postgres predictable under model load: per-task budgets, queue fairness, cancellation, worker RSS policy, model unload behavior, and fail-closed semantics under pressure

For managed Postgres, avoid duplicate databases. Prefer the native extension where providers allow it; otherwise test a customer-VPC agent that reads source rows and writes Otlet outputs, receipts, and approvals back into `otlet.*`. Use a hosted control plane for packaging and observability while Postgres remains the system of record

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
- Stale semantic state uses explicit policy
- Prompt, cache, trace, and output storage stay bounded
- SQL generates candidates before model judgment
- EXPLAIN and SQL views expose model work
