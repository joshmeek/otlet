# Otlet roadmap

| Feature | Explanation |
| --- | --- |
| Portable watches and semantic reads | Install row and pair watch lifecycle in SQL-only PostgreSQL, enqueue source changes after commit, materialize portable completions, and expose semantic reads and status |
| Portable model routing | Route jobs across registered portable workers and support cheap-to-strong escalation without granting worker roles direct table access |
| Portable conformance | Extend the isolated portable smoke test across inference, watches, materialization, model routing, cancellation, restart, and failure paths |
| GPU and alternate CPU execution | Run models on GPUs and distinct CPU paths while preserving receipts, quality checks, memory bounds, cancellation, and fallback |
| Batching and speculative decoding | Improve throughput while keeping worker memory and PostgreSQL responsiveness bounded |
| Multi-model residency | Keep more than one useful model resident and schedule jobs by model without starving tasks |
| Persisted inference cache | Reuse inference state across restarts with bounded storage, eviction, and identity checks |
| PostgreSQL planner and executor integration | Add core PostgreSQL work for capabilities that extension hooks cannot provide |
| Remote model providers | Support deployments that cannot run the native or portable local runtime while keeping PostgreSQL validation and evidence in the path |
| Plugins and delivery | Package reusable workflows and shared delivery or reconciliation without replacing SQL and JSON Schema as the core contracts |
| Evaluation and history | Add evaluation gates, watch history, retention workflows, and signed decision bundles |
| Multi-node recovery | Add failover and recovery coverage beyond the current single-node restart path |
