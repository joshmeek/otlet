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

Otlet keeps source rows in user tables. Users select rows with SQL. `otlet.ask(...)` handles one-off row questions through the resident worker. Named watches own repeatable row and pair jobs, stale policy, candidate SQL, model policy, and runtime options. Otlet passes compact JSON to local GGUF models, runs cheap-first model selection for tasks with a policy, drains bounded queue batches, and stores outputs, attempts, actions, traces, receipts, eval labels, and semantic materializations under `otlet`. The bounded write path can update one owner-registered source row after dry run and approval

The linked runtime stops after one balanced JSON object. Otlet then requires the fixed `output` plus `actions` envelope and applies task JSON Schema, action, decision, and selection validation. Invalid JSON, schema failures, rejected attempts, and rejected actions stay in receipt evidence outside trusted output

Extension owners can export row and pair watch definitions as `otlet.watch.v1` JSONB and import them through the same validation path as `create_watch`. The document carries configuration and owner-authored SQL without database state or model artifacts

The planner contract covers semantic lookup, fail-closed stale reads, queue refresh, wait, fresh inference, bounded CustomScan infer-now, current-row SQL lookup, cache decisions, and live EXPLAIN vocabulary. SQL exposes cache keys, invalidation reasons, hit/miss counters, size bounds, runtime status, source-delete and pair-candidate stale reasons, queue admission, fair claims, attempt bounds, cancellation, pre-load model admission, memory pressure, RSS budget failures, malformed-schema failures, and cleanup dry-run evidence. Requester timeouts are also worker-owned: a timed-out SQL transaction cannot roll back the worker's cancellation or materialize a late trusted output

Run `./scripts/otlet-setup.sh`, then `./scripts/otlet-demo.sh` to prove the contract. Use `benchmarks/run.sh` for SQL-scored model comparisons

## Priority Order

| Order | Track | Status | Next work |
| --- | --- | --- | --- |
| 1 | Packaging and security | Active hardening | Maintain a small setup and demo; add release packaging proof |
| 2 | Output reliability and benchmark truth | Measured default | Maintain the raw `/no_think` Q4_K_M path and existing fast/full gates |
| 3 | Planner, executor, and cache | Active hardening | Measure multi-model residency and persisted-cache need, then close Access Method and fork evidence |
| 4 | Semantic freshness | Implemented contract | Maintain row, pair, delete, candidate, and schema-drift freshness gates |
| 5 | Action safety | Implemented contract | Maintain the one-table, one-key, one-row `update_row` boundary |
| 6 | Managed Postgres packaging | Open | Test native workers where providers allow them and a SQL-bound agent where providers block them |
| 7 | GPU acceleration | Open | Add device policy after the CPU resident-worker path has measured proof |
| 8 | Core limits | Open research | Test Access Method and Postgres-fork paths for missing planner or executor contracts |

## Open Tracks

| Track | Next contract |
| --- | --- |
| Planner, executor, and cache hardening | Keep SQL plan rows, semantic status views, CustomScan EXPLAIN, receipts, runtime/cache views, and demo output aligned |
| Model residency and timing | Keep the measured sequential decoder; test safe multi-model residency before changing slot policy |
| Persisted cache storage | Add disk-backed cache after a measured workload proves in-process cache misses hurt |
| Managed Postgres external worker | Build a trusted SQL-bound worker that claims jobs, heartbeats, writes receipts, and fails closed |
| GPU acceleration | Report device policy, memory accounting, throughput, energy per trusted job, crash behavior, and EXPLAIN-visible device state |
| Core limits research | Test Access Method and fork paths when CustomScan cannot expose a required contract |
| Entity resolution packs | Ship vendor, customer, and product packs that reuse `otlet.watch.v1` definitions with prompts, fixtures, and gates |

Define each open track through SQL-visible state, a closed failure mode, and demo or benchmark proof before adding code

## Output Reliability

Otlet treats output reliability as part of the database contract. Trusted output uses a fixed top-level `output` plus `actions` envelope. Invalid JSON, schema failures, bad action envelopes, false merges, and failed model attempts stay in receipts and diagnostic benchmark data, outside trusted output

Keep greedy decoding with balanced-object stopping. A same-host native grammar probe reduced steady generation speed, so grammar-constrained decode did not meet Otlet's no-regression bar and is not planned

Qwen3.5 4B stays the default stable model under the 4B and 4 GB project cap. The fast probe filters smaller candidates before a full benchmark run. MiniStral 3B, Phi-4 mini, SmolLM3 3B, and GLM Edge 4B run faster in CPU quick probes. Each model failed at least one adversarial row-text, numeric-threshold, markdown-fence, or schema gate

The current Qwen3.5 prompt and quantization contract is measured through one Otlet SQL fixture. The raw `/no_think` prompt passed `5/5` correctness and schema gates. Removing `/no_think` repeated at `4/5` correctness and schema. The GGUF's embedded one-user template is byte-equivalent to the smallest explicit Qwen ChatML wrapper; that form repeated at `0/5` and produced no schema-valid object. Q4_K_M passed `5/5`; same-revision Q5_K_M passed schema but obeyed adversarial row text, fell to `4/5`, used 14.8 percent more model bytes, and decoded more slowly. Neither candidate qualified for a full run, so the raw Q4_K_M default remains unchanged

Benchmark policy:

- Use the five-case quick probe and focused live contracts for runtime-only work. Reserve the 447-job full suite for output-affecting changes, published comparisons, unexplained regressions, and final integration
- Use interleaved repeated same-host A/B when thermal load or run order can obscure a runtime result
- Run comparable model sweeps after harness changes so public charts show workload roles, trusted quality, resource fit, and out-of-running reasons across small, medium, and ceiling local models
- Limit routine benchmark runs to `include_by_default=true`; run candidate, diagnostic, historical, heavy, and blocked rows by request
- Use `benchmarks/quick_probe.sh` to reject weak candidates before running the full suite
- Sweep `OTLET_PROBE_LLAMA_THREADS` through `benchmarks/quick_probe.sh` before treating CPU token rates as fixed
- Use larger local models as ceiling checks; cap Otlet defaults at 4B active parameters and about 4 GB on disk

## Planner, Executor, And Cache

Use one decision vocabulary for semantic lookup, queue refresh, wait, fail-closed, fresh inference, bounded infer-now, and cache reuse. Align SQL plan functions, semantic status views, CustomScan EXPLAIN, receipts, current-row SQL, and demo output on that vocabulary. The EXPLAIN field table in `docs/semantic-watches.md` (Step 6) anchors `selected_path` / `Planner Selected Path`, `freshness_basis`, and related labels

`EXPLAIN (ANALYZE, VERBOSE)` shows selected model, resident state, source identity, source hash, stale policy, cache decision, worker handoff, token counts, schema validation, trace policy, receipt IDs, provenance links, estimated model time, and model runtime

Treat cache behavior as part of the runtime contract. Cache keys, invalidation reasons, hit and miss counters, size bounds, EXPLAIN output, runtime status, and benchmark gates must agree. Add persisted cache storage after a measured workload proves the bounded in-process cache misses hurt

Use measured runtime history for costing: load time, warm generation time, token counts, schema failures, cache hits, cache invalidation reasons, stale refresh rate, worker queue depth, model-selection attempts, and materialization coverage. Postgres chooses the cheap fresh lookup path when it can and shows the reason when it cannot

The timing split records `tokenize_ms`, `prompt_decode_ms`, `generate_ms`, `finish_sql_ms`, and `materialize_ms`. Use those fields to decide whether prompt decode, SQL finish work, or materialization owns warm-job latency. Worker complete/fail paths stamp `finish_sql_ms` and `materialize_ms` onto receipt `trace_summary`; `inference_receipt_trace_status` and `inference_trace_summary` expose them as nullable columns

Receipts, trace views, runtime status, infer-now EXPLAIN, demo contracts, and benchmark artifacts share one versioned runtime fingerprint. It binds artifact identity and quantization, prompt-template name and exact reasoning-prefix/body hash, linked llama.cpp revision and build flags, effective context, batch, ubatch, KV, mmap, mlock, flash-attention, threads, affinity, NUMA, CPU topology, and memory capacity. The inference cache includes the output-affecting subset while host-capacity observations stay outside cache invalidation

Preserve cache-hit performance. A live smoke run completed cached jobs in milliseconds with no generation, so future watch and demo work disables trace mode for cacheable production paths and preserves stable content, contract, and model keys. Cache-hit receipt hashes still match the miss path; they stream the prompt and input bytes without allocating the full prompt string

CPU tuning runs through the SQL path. Current controls cover release builds, native CPU code, OpenMP, a six-thread default cap, per-job `llama_threads`, batch and ubatch size, mmap, mlock, flash attention, perf counters, and KV type. The current ARM64 host has one hardware thread per core and no NUMA interface, the linked llama.cpp build has no BLAS backend, and available energy counters require unavailable elevated host access. Explicit OpenMP placement either timed out or ran slower. Rotated F16/Q8 KV probes found no repeatable Q8 gain, while Q4 failed one adversarial decision. Keep six threads, unset placement, F16 KV, and the existing 4096-token contract

Explicit worker budgets now admit a replacement model before tensor allocation. The worker reads llama.cpp metadata without allocating tensors, projects model, KV, and prompt-decode workspace bytes, and compares the total with worker-budget headroom, Linux `MemAvailable`, and finite cgroup-v2 headroom. Current resident model, context, prefix cache, and worker state are already charged in current RSS. Missing required Linux samples fail closed. Receipts, model-swap and rejection events, and runtime status expose the projection, decision, RSS, swap, major faults, model-file reads, PSI, and supported cgroup counters. Budget `0` remains reporting-only

One-client `SELECT 1` probes measured 38 microseconds p50 and 46 microseconds p95 while idle, 40 and 69 microseconds through cold load plus five judgments, and 39 and 87 microseconds during four concurrent callers. All transactions succeeded. The four callers filled the bounded infer-now queue and completed with passed schemas, one resident worker, no swap, faults, reads, PSI events, timeout, cancellation, or crash

Gate resident-worker parallelism on measured proof. A qwen35_4b probe on the current Docker CPU measured four warm concurrent infer-now callers at `11.22s` with one worker and six threads, `13.02s` with two workers and six threads each, and `11.51s` with two workers and three threads each. Extra workers created overlapping llama.cpp generation, doubled resident model contexts, and failed to beat the one-worker default. Pre-load admission, per-run memory evidence, queue fairness, and worker health now guard the one-worker path. Any later worker-count change must also preserve database responsiveness

Idle expired-job sweeps run at most every 30 seconds. After a productive claim drain, the worker makes the next sweep due so lease reclaim stays prompt under load

Single-context multi-sequence decoding did not clear the no-regression gate. Four jobs were slower than sequential execution. An eight-job candidate improved wall time from `28.338s` to `20.574s`, but raised peak worker RSS from `5.919 GB` to `6.605 GB`. Smaller prompt buffers and dropping the resident context reduced memory but erased the speed gain. All outputs and schemas passed, cancellation stayed isolated, and database responsiveness did not regress, but no candidate preserved both throughput and memory. Otlet therefore keeps one sequential resident decoder. Requester timeouts now use the existing shared abort marker and let the worker persist `otlet.cancel_job` before output acceptance, so a caller-side exception cannot roll back cancellation and permit late output

Test multi-resident model contexts before changing slot policy. Alternating cheap and strong models pays model-load time on each swap; a keyed model cache can remove that cost when the memory budget allows both artifacts

The resident default uses linked llama.cpp with models that fit the memory budget. Open ceiling research on SSD-streamed experts, distributed execution, Medusa, or MTP after a measured Otlet workload requires a larger model

Production status names the schema invariant `complete_receipts_are_schema_validated`. Worker batch status uses throughput counters such as `completed_jobs` and `last_batch_completed_jobs`

## Watch And Review Contracts

Named watch definitions carry source queries, candidate queries, output schemas, action schemas, stale policies, model policies, and trigger or schedule policy. The watch record owns the durable contract. Source tables stay under application control

The review queue exposes task, subject, decision, confidence, action type, approval state, correction state, stale state, schema status, receipt ID, source identity, and reviewer reason through SQL

Approval, rejection, correction, and unclear decisions create eval labels without exporting source data. Maintain stable queue views for psql, dashboards, and other clients

Watch import and export use the owner-only `otlet.watch.v1` document and the same validation path as `create_watch`

## Semantic Freshness

Otlet tracks the source dependencies behind row indexes, semantic joins, candidate queries, deletes, and schema changes. Stale state fails closed or refreshes before lookup

Each answer records the source rows read, trusted hash or MVCC identity, candidate set, and reuse/rejection reason for materialized state

`otlet.semantic_dependency_audit` returns the latest materialization row per subject with `stale_reason`, hashes, and `source_dependencies`. Row triggers record source updates and deletes. Pair refresh records removed and changed candidates from the bounded candidate query, restores identical returning candidates, and sends changed or new candidates through the existing queue

## Entity Resolution Packs

Ship MIT packs for vendor, customer, and product resolution. Each pack carries candidate SQL, input shape, output schema, action schema, prompt text, fixture rows, eval labels, and benchmark gates

Limit packs to an auditable size. Packs can depend on SQL candidate generation, schema validation, receipts, review queues, and eval labels. Packs expose source writes through typed actions

## Explain And Trace

Use verbose EXPLAIN to inspect model work from Postgres. Users see why Otlet reused a materialized result, refreshed a row, waited, failed closed, or ran infer-now

Bound optional token-level tracing. Production receipts keep chosen token IDs, probabilities or logprobs, numeric top-k alternatives, stop reason, schema validation, and trace storage policy. The default write path removes token text and reconstructed chosen text

Production defaults use numeric low-detail tracing or disable it. SQL explains disabled tracing without storing unbounded token streams

Use `generation_trace_top_k=0` when token alternatives are not part of the question. In a smoke probe, Otlet kept probability and chosen-token trace while avoiding the top-alternative scan cost

Otlet exposes read-only audit surfaces through `otlet.audit_receipt_export`, `otlet.audit_review_export`, `otlet.audit_action_execution_export`, `otlet.audit_eval_label_export`, `otlet.semantic_dependency_audit`, and `otlet.worker_batch_timing_status`. `otlet.redaction_policy_status` reports write-time storage mode, retention, observed sensitive rows, and compliance. `otlet.access_policy_status` reports the enforced `PUBLIC`, auditor, and operator boundary. The demo proves allowed audit reads, operator-only action functions, raw-state denial, fixed security-definer search paths, hash-only prompt evidence, and text-free production traces

## Action Safety

The action lifecycle covers proposed, pending dry run, pending approval, approved, rejected, corrected, unclear, ready to apply, applied, replayed, and failed states. SQL functions record reviewer reason and write eval labels from accepted, rejected, and corrected decisions

`update_row` is the only source-table write action. The owner maps one short target name to one ordinary table, its sole primary key, and at most 16 writable columns. Model output contains only target, identity, and changed values. Otlet requires the job subject and source table to match, converts values through PostgreSQL types, hashes dry-run and apply evidence, locks and rechecks the row, writes exactly once, and records replay or failure without row values. Operators can run the bounded lifecycle but cannot administer targets or update the source table directly

## Packaging And Security

Limit open-source packaging to one setup script, one demo script, a small model path, Docker instructions, crash-log scanning, CPU-only defaults, resource warnings, extension versioning, and upgrade notes

Otlet remains greenfield before its first stable release. Current builds recreate the extension; versioned upgrade and downgrade paths begin with the stable packaging contract

Cover schema permissions, model artifact path permissions, allowed write targets, action approval, prompt visibility, trace visibility, row-level security, superuser requirements, and extension install risk. Redact traces because prompts and token traces can contain source values

Stored sensitive-evidence redaction is installed by default. Assembled prompts stay in worker memory. Receipts keep prompt and raw-output hashes, structured accepted output, structured rejected candidates, and numeric traces. The write boundary removes raw model text and token text in `redacted` mode. Owner-only `diagnostic` mode has bounded retention, and cleanup scrubs expired evidence or all evidence after a switch back to `redacted`

Role-scoped access is installed by default. `PUBLIC` has no Otlet schema, table, sequence, or function access. Extension-owner grant helpers give caller-managed roles the redacted auditor capability or the bounded action-operator capability

Use admission control for predictable Postgres behavior under model load: per-task budgets, pre-load model projection, queue fairness, cancellation, worker RSS policy, model unload behavior, and fail-closed semantics under pressure

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
