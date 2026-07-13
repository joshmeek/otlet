# Otlet roadmap

This file lists unshipped work. The README, worked example, runtime, production, semantic-watch, and benchmark docs describe the current system

Otlet is a general Postgres-local row-judgment system. Entity resolution is its first proof workload. New workloads must reuse the same SQL, receipt, review, action, and freshness contracts

## Open Work

| Priority | Track | Next contract |
| --- | --- | --- |
| 1 | Release packaging | Prove a small reproducible install, upgrade, downgrade, and artifact-permission path |
| 2 | Managed Postgres | Prove native workers where providers allow them and a SQL-bound external worker where they do not |
| 3 | GPU acceleration | Add a device policy after throughput, memory, energy, responsiveness, and crash gates pass |
| 4 | Reusable workload packs | Package portable watch definitions, prompts, schemas, fixtures, and gates for more row-judgment workloads |

These tracks are outside the completed core runtime and PostgreSQL research scope

## Release Packaging

Keep the public install surface small. A release path needs:

- reproducible extension and linked-runtime artifacts
- one setup path and one demo path
- extension versioning plus tested upgrade and downgrade behavior
- model artifact, schema, and install permission checks
- CPU resource guidance and crash-log proof

Do not add compatibility layers or migrations before the first stable release contract requires them

## Managed Postgres

Prefer the native extension when a provider permits shared libraries and background workers. For blocked providers, prove one external worker that uses Otlet's SQL lease and receipt APIs without creating a second database or control path

The proof must cover job claims, heartbeats, source identity, bounded reads, stale decisions, failures, receipts, actions, approvals, runtime status, and operator permissions

## GPU Acceleration

Preserve the resident-worker and SQL contracts. A GPU path must expose device policy, model and context memory, admission decisions, throughput, database responsiveness, crash behavior, and EXPLAIN-visible runtime state

Report energy per trusted job when the host exposes reliable counters. Do not trade correctness, schema validity, stale safety, CPU fallback behavior, or database responsiveness for token speed

## Reusable Workload Packs

Use `otlet.watch.v1`. Do not add a registry, plugin system, service, or CLI. A pack should contain a watch definition, prompt, input and output schemas, action schema, bounded fixtures, and benchmark gates

Entity resolution can supply vendor, customer, and product examples. Extraction, policy review, triage, reconciliation, and row-quality packs would test the general system from different angles

## Research Worth Reopening

Each measured result below stays closed until its trigger changes

| Avenue | Reopen trigger | Required proof |
| --- | --- | --- |
| Single-context batching | A linked llama.cpp or memory change removes the current throughput/RSS tradeoff | Beat sequential 1/4/8-job wall time without raising peak memory, losing cancellation isolation, or slowing Postgres |
| Multi-model residency | Two useful model contexts fit below the worker budget with Postgres headroom | Beat grouped model swaps on a real cheap-to-strong workload with stable RSS and database latency |
| Speculative decode | Installed artifacts expose compatible draft or MTP heads and the linked runtime exports the caller symbols | Preserve all five quick-probe decisions and schema gates while improving latency and memory together |
| Persisted inference cache | Repeated restart or eviction misses consume material workload time | Preserve output identity, invalidation, redaction, restart, and crash contracts while reducing end-to-end time |
| PostgreSQL core changes | A required planner or executor contract has no extension hook | Prove the gap first, then preserve MVCC, scan-shape parity, planner cost, EXPLAIN, receipts, permissions, and crash behavior |
| New CPU and host paths | Hardware exposes a distinct BLAS, NUMA, SMT, or energy condition | Use interleaved SQL-path A/B runs and keep correctness, token rate, memory, and database responsiveness together |

## Constraints For Future Work

- Local inference stays behind the resident Postgres worker unless the managed-Postgres track proves the SQL-bound external-worker contract
- Source rows stay in user tables and derived state stays under `otlet`
- Trusted outputs pass schema validation
- User-table writes require typed actions, approval, and receipts
- Stale semantic state cannot become a silent trusted result
- Prompt, cache, trace, output, queue, and memory use stay bounded
- SQL selects candidates before model judgment
- EXPLAIN and SQL status expose model work
- A retained change must preserve correctness, trusted quality, latency, throughput, memory, database responsiveness, and crash behavior

Define each new roadmap item through SQL-visible state, a closed failure mode, and demo or benchmark proof before adding code
