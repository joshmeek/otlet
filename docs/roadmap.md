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

The model harness requires a top-level `output` plus `actions` envelope. Otlet records invalid JSON, schema failures, rejected attempts, and rejected actions as receipt evidence and excludes them from trusted output

The planner contract covers semantic lookup, fail-closed stale reads, queue refresh, wait, fresh inference, bounded CustomScan infer-now, current-row SQL lookup, cache decisions, and live EXPLAIN vocabulary. SQL exposes cache keys, invalidation reasons, hit/miss counters, size bounds, runtime status, source-dependency stale reasons, queue admission, fair claims, attempt bounds, cancellation, RSS budget failures, malformed-schema failures, and cleanup dry-run evidence

Run `./scripts/otlet-setup.sh`, then `./scripts/otlet-demo.sh` to prove the contract. Use `benchmarks/run.sh` for SQL-scored model comparisons

## Priority Order

| Order | Track | Status | Next work |
| --- | --- | --- | --- |
| 1 | Packaging and security | Active hardening | Maintain a small setup and demo; add stored redaction and release packaging proof |
| 2 | Output reliability and benchmark truth | Active hardening | Add prompt-template and quant sweeps under the existing quality gates |
| 3 | Planner, executor, and cache | Active hardening | Add runtime fingerprints, load admission, decoder-batch probes, and EXPLAIN parity |
| 4 | Explain and trace | Active hardening | Enforce stored prompt and trace redaction |
| 5 | Semantic freshness | Active hardening | Extend dependency audits to source deletes and candidate-set changes |
| 6 | Action safety | Active hardening | Extend typed actions to bounded SQL proposals, target allowlists, and idempotent replay |
| 7 | Managed Postgres packaging | Open | Test native workers where providers allow them and a SQL-bound agent where providers block them |
| 8 | GPU acceleration | Open | Add device policy after the CPU resident-worker path has measured proof |
| 9 | Core limits | Open research | Test Access Method and Postgres-fork paths for missing planner or executor contracts |

## Open Tracks

| Track | Next contract |
| --- | --- |
| Output reliability hardening | Compare prompt templates and quantizations for each model family under one fixture and gate set |
| Planner, executor, and cache hardening | Align SQL plan rows, semantic status views, runtime fingerprints, CustomScan EXPLAIN, receipts, runtime/cache views, and demo output |
| Action lifecycle extension | Add bounded SQL proposal actions, dry-run plans, approvals, receipts, and source-table write checks |
| Semantic freshness hardening | Extend dependency audit export to source deletes and candidate-set changes |
| Watch definition export | Add import/export for row and pair watches |
| Explain and trace hardening | Enforce stored prompt and trace redaction |
| Model residency and timing | Add pre-load memory admission, pressure metrics, and single-context decoder-batch probes before changing slot policy |
| Grammar-constrained decode | Add grammar or JSON-schema decode after linked llama exposes a worker-safe hook |
| Persisted cache storage | Add disk-backed cache after a measured workload proves in-process cache misses hurt |
| Managed Postgres external worker | Build a trusted SQL-bound worker that claims jobs, heartbeats, writes receipts, and fails closed |
| GPU acceleration | Report device policy, memory accounting, throughput, energy per trusted job, crash behavior, and EXPLAIN-visible device state |
| Core limits research | Test Access Method and fork paths when CustomScan cannot expose a required contract |
| Entity resolution packs | Ship vendor, customer, and product packs with candidate SQL, prompts, schemas, actions, fixtures, and gates |
| Audit export and redaction | Enforce redaction for stored prompts and token traces |

Define each open track through SQL-visible state, a closed failure mode, and demo or benchmark proof before adding code

## Output Reliability

Otlet treats output reliability as part of the database contract. Trusted output uses a fixed top-level `output` plus `actions` envelope. Invalid JSON, schema failures, bad action envelopes, false merges, and failed model attempts stay in receipts and diagnostic benchmark data, outside trusted output

Qwen3.5 4B stays the default stable model under the 4B and 4 GB project cap. The fast probe filters smaller candidates before a full benchmark run. MiniStral 3B, Phi-4 mini, SmolLM3 3B, and GLM Edge 4B run faster in CPU quick probes. Each model failed at least one adversarial row-text, numeric-threshold, markdown-fence, or schema gate

Next benchmark work:

- Run comparable model sweeps after harness changes so public charts show workload roles, trusted quality, resource fit, and out-of-running reasons across small, medium, and ceiling local models
- Limit routine benchmark runs to `include_by_default=true`; run candidate, diagnostic, historical, heavy, and blocked rows by request
- Use `benchmarks/quick_probe.sh` to reject weak candidates before running the full suite
- Sweep `OTLET_PROBE_LLAMA_THREADS` through `benchmarks/quick_probe.sh` before treating CPU token rates as fixed
- Compare the current raw prompt with and without `/no_think`, the GGUF chat template, and an explicit family template under one fixture and gate set
- Run quantization ladders for one base model; use a full-precision or hosted reference to distinguish base-model limits from local format and runtime failures
- Revisit grammar-constrained JSON after linked llama exposes a hook that cannot abort the resident worker
- Run prompt, template, quantization, and schema changes against one benchmark fixture
- Use larger local models as ceiling checks; cap Otlet defaults at 4B active parameters and about 4 GB on disk

## Planner, Executor, And Cache

Use one decision vocabulary for semantic lookup, queue refresh, wait, fail-closed, fresh inference, bounded infer-now, and cache reuse. Align SQL plan functions, semantic status views, CustomScan EXPLAIN, receipts, current-row SQL, and demo output on that vocabulary. The EXPLAIN field table in `docs/semantic-watches.md` (Step 6) anchors `selected_path` / `Planner Selected Path`, `freshness_basis`, and related labels

`EXPLAIN (ANALYZE, VERBOSE)` shows selected model, resident state, source identity, source hash, stale policy, cache decision, worker handoff, token counts, schema validation, trace policy, receipt IDs, provenance links, estimated model time, and model runtime

Treat cache behavior as part of the runtime contract. Cache keys, invalidation reasons, hit and miss counters, size bounds, EXPLAIN output, runtime status, and benchmark gates must agree. Add persisted cache storage after a measured workload proves the bounded in-process cache misses hurt

Use measured runtime history for costing: load time, warm generation time, token counts, schema failures, cache hits, cache invalidation reasons, stale refresh rate, worker queue depth, model-selection attempts, and materialization coverage. Postgres chooses the cheap fresh lookup path when it can and shows the reason when it cannot

The timing split records `tokenize_ms`, `prompt_decode_ms`, `generate_ms`, `finish_sql_ms`, and `materialize_ms`. Use those fields to decide whether prompt decode, SQL finish work, or materialization owns warm-job latency. Worker complete/fail paths stamp `finish_sql_ms` and `materialize_ms` onto receipt `trace_summary`; `inference_receipt_trace_status` and `inference_trace_summary` expose them as nullable columns

Add one runtime fingerprint to receipts, trace views, and benchmark artifacts. Include the artifact hash, quantization, prompt-template name and hash, linked llama.cpp revision and build flags, effective context, batch, ubatch, KV, mmap, mlock, flash-attention, thread, affinity, NUMA, CPU topology, and memory capacity. Add output-affecting fields to cache contracts before persisted cache storage ships

Preserve cache-hit performance. A live smoke run completed cached jobs in milliseconds with no generation, so future watch and demo work disables trace mode for cacheable production paths and preserves stable content, contract, and model keys. Cache-hit receipt hashes still match the miss path; they stream the prompt and input bytes without allocating the full prompt string

Measure CPU tuning through the SQL path. Current controls cover release builds, native CPU code, OpenMP, a six-thread default cap, per-job `llama_threads`, startup `OTLET_LLAMA_BATCH_TOKENS`, `OTLET_LLAMA_MMAP`, `OTLET_LLAMA_MLOCK`, and `OTLET_LLAMA_FLASH_ATTN`. Add BLAS, KV-cache quantization, context-window policy, grammar decoding, or device offload after a probe shows better Otlet pass rate or latency

Add pre-load memory admission. Estimate model, context, KV, prefix-cache, and Postgres headroom before loading a model; reject the load before memory pressure begins. Sample major faults, model-file reads, swap, and cgroup memory pressure around each run and expose supported fields through receipts and runtime status

Add host-scoped probes for physical cores versus SMT, NUMA-local versus interleaved placement, and energy where the host exposes counters. Report joules per trusted job with latency, RSS, and database responsiveness

Gate resident-worker parallelism on measured proof. A qwen35_4b probe on the current Docker CPU measured four warm concurrent infer-now callers at `11.22s` with one worker and six threads, `13.02s` with two workers and six threads each, and `11.51s` with two workers and three threads each. Extra workers created overlapping llama.cpp generation, doubled resident model contexts, and failed to beat the one-worker default. Before changing the default, add per-worker RSS totals, model-specific admission caps, queue fairness proof, and database responsiveness checks

Idle expired-job sweeps run at most every 30 seconds. After a productive claim drain, the worker makes the next sweep due so lease reclaim stays prompt under load

Test single-context multi-sequence decoding before adding workers. Compare 1, 4, and 8 homogeneous claimed jobs with shared prompt prefixes. Require stable quality gates, cancellation, queue order, RSS, tail latency, throughput, and database responsiveness before changing the sequential decoder path

Test multi-resident model contexts before changing slot policy. Alternating cheap and strong models pays model-load time on each swap; a keyed model cache can remove that cost when the memory budget allows both artifacts

The resident default uses linked llama.cpp with models that fit the memory budget. Open ceiling research on SSD-streamed experts, distributed execution, Medusa, or MTP after a measured Otlet workload requires a larger model

Production status names the schema invariant `complete_receipts_are_schema_validated`. Worker batch status uses throughput counters such as `completed_jobs` and `last_batch_completed_jobs`

## Watch And Review Contracts

Named watch definitions carry source queries, candidate queries, output schemas, action schemas, stale policies, model policies, and trigger or schedule policy. The watch record owns the durable contract. Source tables stay under application control

The review queue exposes task, subject, decision, confidence, action type, approval state, correction state, stale state, schema status, receipt ID, source identity, and reviewer reason through SQL

Approval, rejection, correction, and unclear decisions create eval labels without exporting source data. Maintain stable queue views for psql, dashboards, and other clients

Add watch import/export after the in-database contract stops changing

## Semantic Freshness

Otlet tracks the source dependencies behind row indexes, semantic joins, candidate queries, deletes, and schema changes. Stale state fails closed or refreshes before lookup

Each answer records the source rows read, trusted hash or MVCC identity, candidate set, and reuse/rejection reason for materialized state

Add dependency audit exports for the row, join, delete, candidate-query, and schema-drift decisions that drive stale/fresh state. `otlet.semantic_dependency_audit` returns the latest materialization row per subject with `stale_reason`, hashes, and `source_dependencies`. Delete/candidate-query drift export surfaces remain open

## Entity Resolution Packs

Ship MIT packs for vendor, customer, and product resolution. Each pack carries candidate SQL, input shape, output schema, action schema, prompt text, fixture rows, eval labels, and benchmark gates

Limit packs to an auditable size. Packs can depend on SQL candidate generation, schema validation, receipts, review queues, and eval labels. Packs expose source writes through typed actions

## Explain And Trace

Use verbose EXPLAIN to inspect model work from Postgres. Users see why Otlet reused a materialized result, refreshed a row, waited, failed closed, or ran infer-now

Bound optional token-level tracing. Debug mode shows chosen token IDs, token text, probabilities or logprobs when llama.cpp exposes them, top-k alternatives, partial generated text, stop reason, schema validation, and trace storage policy

Production defaults use low-detail tracing or disable it. SQL explains disabled tracing without storing unbounded token streams

Use `generation_trace_top_k=0` when token alternatives are not part of the question. In a smoke probe, Otlet kept probability and chosen-token trace while avoiding the top-alternative scan cost

Otlet exposes read-only audit surfaces through `otlet.audit_receipt_export`, `otlet.audit_review_export`, `otlet.audit_eval_label_export`, `otlet.semantic_dependency_audit`, and `otlet.worker_batch_timing_status`. `otlet.redaction_policy_status` documents withheld fields. `otlet.access_policy_status` reports the enforced `PUBLIC`, auditor, and operator boundary. The demo proves allowed audit reads, operator-only action functions, raw-state denial, and fixed security-definer search paths. Enforce stored redaction before exporting prompt, source, or token detail

## Action Safety

The current action lifecycle covers proposed, pending review, approved, rejected, corrected, unclear, dry-run passed, applied, and failed states. SQL functions record reviewer reason and write eval labels from accepted, rejected, and corrected decisions

Next action work adds bounded SQL proposal actions. Source-table apply paths need target allowlists, dry-run plans, idempotency keys, approval records, replay checks, and failure receipts

## Packaging And Security

Limit open-source packaging to one setup script, one demo script, a small model path, Docker instructions, crash-log scanning, CPU-only defaults, resource warnings, extension versioning, and upgrade notes

Otlet remains greenfield before its first stable release. Current builds recreate the extension; versioned upgrade and downgrade paths begin with the stable packaging contract

Cover schema permissions, model artifact path permissions, allowed write targets, action approval, prompt visibility, trace visibility, row-level security, superuser requirements, and extension install risk. Redact traces because prompts and token traces can contain source values

Define redaction policy for prompts, source values, traces, receipts, review queues, and audit exports. SQL status views show the active policy and withheld fields via `otlet.redaction_policy_status`. Enforcement that rewrites stored prompts or token traces remains open

Role-scoped access is installed by default. `PUBLIC` has no Otlet schema, table, sequence, or function access. Extension-owner grant helpers give caller-managed roles the redacted auditor capability or the bounded action-operator capability

Use admission control for predictable Postgres behavior under model load: per-task budgets, queue fairness, cancellation, worker RSS policy, model unload behavior, and fail-closed semantics under pressure

## Managed Postgres Packaging

Avoid duplicate databases. Prefer the native extension where providers allow it. Providers that block native workers use an external worker that claims jobs, heartbeats, reads bounded source rows through watch definitions, and writes Otlet outputs, receipts, actions, approvals, and eval labels back into `otlet.*`

Bind the external worker protocol to SQL. Leases, source identity, runtime status, memory policy, receipt hashes, failure reasons, and stale-state decisions stay visible from Postgres

## GPU Acceleration

Add GPU support after the CPU path has measured proof. Report device policy, memory accounting, throughput per watt, joules per trusted job where the host exposes counters, crash behavior, and EXPLAIN-visible device state

Preserve the SQL contract: resident worker, source rows in user tables, derived state under `otlet`, schema-validated outputs, receipts, and EXPLAIN-visible runtime state

## Core Limits

Base the Access Method track on evidence. Test `CREATE ACCESS METHOD`, `IndexAmRoutine`, operator classes, `amcostestimate`, tuple/TID semantics, build, insert, vacuum, update, and bitmap/gettuple paths. If PostgreSQL extension APIs cannot represent semantic model access, document the missing contract and use CustomScan as the extension path

If extension APIs hit a hard ceiling, prove the missing planner or executor contract with a small Postgres fork. Use the extension as the public path until a fork proves a capability PostgreSQL cannot expose through hooks

## Boundaries

Preserve these constraints while the roadmap changes:

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
