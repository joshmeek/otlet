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

## Open Tracks

| Track | Next contract |
| --- | --- |
| Output reliability hardening | Repeat model sweeps and keep prompt/schema changes on the same fixture |
| Planner, executor, and cache hardening | Keep SQL plan rows, semantic status views, CustomScan EXPLAIN, receipts, runtime/cache views, and demo output aligned |
| Action lifecycle extension | Add bounded SQL proposal actions, dry-run plans, approvals, receipts, and source-table write checks |
| Semantic freshness hardening | Add dependency audit export for source updates, deletes, schema drift, contract changes, and candidate changes |
| Watch definition export | Add import/export for row and pair watches |
| Explain and trace hardening | Add audit export views and redaction policy |
| Model residency and timing | Keep one-worker default; add per-worker RSS totals, model-slot admission, and worker-count probes before changing slot policy |
| Grammar-constrained decode | Add grammar or JSON-schema decode after linked llama exposes a worker-safe hook |
| Persisted cache storage | Add disk-backed cache after a measured workload proves in-process cache misses hurt |
| Managed Postgres external worker | Build a trusted SQL-bound worker that claims jobs, heartbeats, writes receipts, and fails closed |
| GPU acceleration | Report device policy, memory accounting, throughput, crash behavior, and EXPLAIN-visible device state |
| Core limits research | Test Access Method and fork paths when CustomScan cannot expose a required contract |
| Entity resolution packs | Ship vendor, customer, and product packs with candidate SQL, prompts, schemas, actions, fixtures, and gates |
| Audit export and redaction | Add views and policies for decisions, receipts, source hashes, approvals, corrections, eval labels, and trace summaries |

Keep open tracks contract-first. Name the SQL-visible state, the closed failure mode, and the demo or benchmark proof before adding code

## Output Reliability

Otlet treats output reliability as part of the database contract. Trusted output uses a fixed top-level `output` plus `actions` envelope. Invalid JSON, schema failures, bad action envelopes, false merges, and failed model attempts stay in receipts and diagnostic benchmark data, outside trusted output

Qwen3.5 4B stays the default stable model under the 4B and 4 GB project cap. The fast probe filters smaller candidates before a full benchmark run. MiniStral 3B, Phi-4 mini, SmolLM3 3B, and GLM Edge 4B are faster on CPU in quick probes, but each failed adversarial row-text, numeric-threshold, markdown-fence, or schema gates

Next benchmark work:

- Run comparable model sweeps after harness changes so public charts show workload roles, trusted quality, resource fit, and out-of-running reasons across small, medium, and ceiling local models
- Keep routine benchmark runs on `include_by_default=true`; keep candidate, diagnostic, historical, heavy, and blocked rows manual
- Use `benchmarks/quick_probe.sh` to reject weak candidates before running the full suite
- Use `benchmarks/thread_sweep.sh` to find the host-specific `llama_threads` setting before treating CPU token rates as fixed
- Revisit grammar-constrained JSON after linked llama exposes a hook that cannot abort the resident worker
- Keep prompt and schema changes on the same benchmark fixture
- Test larger local models only as ceiling checks; keep Otlet defaults under 4B active parameters and about 4 GB on disk

## Planner, Executor, And Cache

Use one decision vocabulary for semantic lookup, queue refresh, wait, fail-closed, fresh inference, bounded infer-now, and cache reuse. Keep SQL plan functions, semantic status views, CustomScan EXPLAIN, receipts, current-row SQL, and demo output aligned on that vocabulary

`EXPLAIN (ANALYZE, VERBOSE)` shows selected model, resident state, source identity, source hash, stale policy, cache decision, worker handoff, token counts, schema validation, trace policy, receipt IDs, provenance links, estimated model time, and model runtime

Keep cache work inside the runtime contract. Cache keys, invalidation reasons, hit and miss counters, size bounds, EXPLAIN output, runtime status, and benchmark gates must agree. Add persisted cache storage after a measured workload proves the bounded in-process cache misses hurt

Use measured runtime history for costing: load time, warm generation time, token counts, schema failures, cache hits, cache invalidation reasons, stale refresh rate, worker queue depth, model-selection attempts, and materialization coverage. Postgres chooses the cheap fresh lookup path when it can and shows the reason when it cannot

Add a timing split before the next executor rewrite: `tokenize_ms`, `prompt_decode_ms`, `generate_ms`, `finish_sql_ms`, and `materialize_ms`. Use those fields to decide whether prompt decode, SQL finish work, or materialization owns warm-job latency

Keep cache-hit paths easy to preserve. A live smoke run completed cached jobs in milliseconds with no generation, so future watch and demo work keeps trace mode off for cacheable production paths and keeps stable content, contract, and model keys

Keep CPU tuning measurable. Current controls cover release builds, native CPU code, OpenMP, a six-thread default cap, per-job `llama_threads`, startup `OTLET_LLAMA_BATCH_TOKENS`, `OTLET_LLAMA_MMAP`, `OTLET_LLAMA_MLOCK`, and `OTLET_LLAMA_FLASH_ATTN`. Add BLAS, KV-cache quantization, context-window policy, grammar decoding, or device offload only after a probe shows better Otlet pass rate or latency on the SQL path

Keep resident-worker parallelism gated. A qwen35_4b probe on the current Docker CPU measured four warm concurrent infer-now callers at `11.22s` with one worker and six threads, `13.02s` with two workers and six threads each, and `11.51s` with two workers and three threads each. Extra workers created overlapping llama.cpp generation, doubled resident model contexts, and failed to beat the one-worker default. Before changing the default, add per-worker RSS totals, model-specific admission caps, queue fairness proof, and database responsiveness checks

Test multi-resident model contexts before changing slot policy. Alternating cheap and strong models pays model-load time on each swap; a keyed model cache can remove that cost when the memory budget allows both artifacts

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

Use `generation_trace_top_k=0` when token alternatives are not part of the question. In a smoke probe, Otlet kept probability and chosen-token trace while avoiding the top-alternative scan cost

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
