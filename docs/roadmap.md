# Otlet roadmap

Otlet should make local model work feel like database work: planned by Postgres, run beside source rows, checked against schemas, tied to row identity, visible through SQL, and recorded with receipts

Use this roadmap to judge future changes. A feature belongs here when it improves model choice, row freshness, planner behavior, operator visibility, action safety, or production packaging

## Current Shape

Otlet has three public entry points today:

| Surface | Purpose |
| --- | --- |
| `scripts/otlet-setup.sh` | build and start the local Postgres extension stack |
| `scripts/otlet-demo.sh` | run the worked demo path with local inference |
| `scripts/otlet-benchmark-models.sh` | compare GGUF models on Otlet workloads |

The extension keeps source rows in user tables. Users choose rows with SQL, Otlet passes compact JSON to a resident local model, and Postgres stores derived outputs, actions, traces, and receipts under the `otlet` schema

## Priorities

| Order | Track | Outcome |
| --- | --- | --- |
| 1 | Benchmarks | Compare local models on Otlet tasks with latency, quality, memory, and crash evidence |
| 2 | Planner work | Cost and explain semantic lookup, refresh, wait, fail-closed, and infer-now paths |
| 3 | Actions | Let models propose typed database actions with receipts and approval |
| 4 | Throughput | Improve queued materialization before pushing synchronous inference |
| 5 | Model selection | Pick small or strong resident models from measured task history |
| 6 | Core limits | Test Access Method and Postgres-fork paths where extension hooks fall short |

## Benchmarking

Otlet needs its own benchmark suite. Generic chat benchmarks miss the work this extension performs: row classification, entity resolution, structured extraction, semantic action proposals, stale-row refresh, schema-following, and trace-heavy debug runs

`scripts/otlet-benchmark-models.sh` should compare multiple GGUF models against the same SQL workload. Each run should record model path, quantization, artifact size, runtime options, hardware, load time, warm latency, p50 and p95 job latency, tokens per second, memory use, JSON validity, schema failures, cache hits, trace overhead, stale refresh latency, infer-now latency, and crash status

The public report should rank models by useful local work instead of raw token speed. A practical score can start with:

```text
task_quality * completed_jobs_per_second / resident_gb
```

The benchmark data should live in SQL rows first, then export to Markdown or CSV for README snippets and release notes

## Planner And Executor

The planner path should keep moving from lookup helper toward semantic access over source tuples. The CustomScan node should start with a Postgres-built child plan, preserve ordinary quals, read source tuple identity, look up semantic state, then choose lookup, refresh, wait, fail closed, or bounded infer-now

`EXPLAIN (ANALYZE, VERBOSE)` should show selected model, resident state, source identity, source hash, stale policy, cache decision, worker handoff, token counts, schema validation, trace policy, receipt IDs, provenance links, estimated model time, and actual model time

Costing should use measured runtime history: load time, warm generation time, token counts, schema failures, cache hits, stale refresh rate, worker queue depth, and materialization coverage. Postgres should choose the cheap fresh lookup path when it can, and show the reason when it cannot

The Access Method track should stay evidence-driven. We should try honest `CREATE ACCESS METHOD`, `IndexAmRoutine`, operator classes, `amcostestimate`, tuple/TID semantics, build, insert, vacuum, update, and bitmap/gettuple paths. If PostgreSQL extension APIs cannot represent semantic model access without lying, document the exact missing contract and keep the CustomScan path as the extension answer

## Throughput

The production throughput path starts with queued materialization. Users should generate candidate rows in SQL, enqueue bounded model work, keep a model resident in the Postgres worker, materialize semantic state under `otlet`, mark state stale from source changes, and let planner paths read fresh state

Worker batching deserves a narrow test. Batch jobs when model, runtime options, output schema, prompt shape, and token budget match. Measure throughput gain, first-job latency, memory growth, failure isolation, and receipt ordering before keeping it

A model warm pool can help once one resident slot works well. Useful slots include a small classifier, a stronger row-judgment model, a trace/debug model, and a schema/action compiler model. Planner choices should prefer a resident model when quality remains close, and escalate when confidence or policy calls for it

The resident inference cache should explain each hit and miss. Its key should include model name, artifact hash, prompt hash, runtime options, output schema, task, subject ID, source hash, and MVCC identity where available. SQL should expose hit reason, miss reason, invalidation reason, size, evictions, and skipped-cache reason

## Model Selection

Otlet should choose models from measured database facts. Task type, row count, freshness, prior quality, prior latency, schema validity, cache probability, confidence policy, and trace mode should feed cost estimates

A good first path is cheap-first execution: run the small model, accept high-confidence valid output, escalate low-confidence or invalid output, store both attempts in receipts, and feed results back into benchmarks and costing

A small local compiler model also fits Otlet. Train or fine-tune it on accepted actions, rejected actions, schema failures, human-approved merges, dry-run errors, and synthetic schema tasks. It should emit Otlet action ASTs with high JSON validity and conservative table or column references

## Explain And Trace

Verbose EXPLAIN should make model work inspectable from Postgres. Users should see why Otlet reused a materialized result, refreshed a row, waited, failed closed, or ran infer-now

Token-level tracing should stay optional and bounded. Debug mode can show chosen token IDs, token text, probabilities or logprobs when llama.cpp exposes them, top-k alternatives, partial generated text, stop reason, schema validation, and trace storage policy

Production defaults should keep tracing low-detail or off. The system should explain disabled tracing through SQL instead of storing unbounded token streams

## Actions

Otlet should start with typed actions before model-written SQL. Useful action types include record creation, review flags, merge proposals, refresh requests, follow-up jobs, notes, and update proposals

Each action should carry JSON Schema validation, source row IDs, source hashes, receipt ID, model hash, prompt hash, dry-run result, approval status, applied timestamp, and rollback or provenance hints. Risky actions should wait for human approval through SQL or an external UI

Model-compiled SQL can come later through a constrained path. The model proposes intent or an AST, Otlet validates allowed schemas, tables, columns, functions, and write targets, runs `EXPLAIN`, stores a dry-run receipt, then applies the action after policy or human approval

## Packaging And Security

Open-source packaging should keep the first run small: one setup script, one demo script, one benchmark script, a small model path, Docker instructions, crash-log scanning, CPU-only defaults, resource warnings, extension versioning, and upgrade notes

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
