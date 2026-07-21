# Otlet roadmap

This file lists unshipped library work. The other docs describe the current system

Otlet runs local model judgment through Postgres contracts. New work must preserve SQL-visible state, bounded resources, source freshness, validated output, review, actions, and receipts

## Priorities

| Priority | Track | Next proof |
| --- | --- | --- |
| 1 | Release | Reproducible artifacts, safe defaults, permission checks, upgrade preflight, and rollback |
| 2 | Portable runtime | One SQL-only install and reference worker for Postgres hosts that block native workers |
| 3 | Trust and evidence | Fenced writes, database-side validation, bounded evidence, retention, and redacted export |
| 4 | Packs and decisions | Versioned workload packs, evaluation gates, review state, and replay-safe actions |
| 5 | GPU and research | Device support or reopened research only after a measured trigger |

Each change needs SQL-visible state, a closed failure mode, and demo, conformance, or benchmark proof

## Release

- build reproducible extension and linked-runtime artifacts
- test one PostgreSQL, operating-system, CPU, and llama.cpp matrix
- record exact binary, model, prompt, schema, pack, and runtime identity
- verify SHA-256 or stronger digests and model provenance
- generate a software bill of materials and vulnerability report
- check file, directory, model, schema, and database-role permissions
- ship nonzero memory limits and bounded defaults
- prove install, restart, upgrade preflight, rollback, and crash-log checks
- make the native database configurable and close or disable unsafe CustomScan rescan shapes before a zero-crash soak

Artifact digests prove identity, not parser safety. Malformed-model tests must fail without corrupting the database process

## Portable Runtime

Use the native background worker where Postgres permits it. Add one external worker where the host blocks native code

The portable path must:

- use the same task, job, receipt, review, action, evaluation, and freshness state
- keep source rows in the primary database and avoid a second database
- claim a bounded evidence snapshot instead of reading source tables
- version the worker RPC protocol, publish compatibility rules, and allowlist runtime identities
- use a claim token on renew, attempt, complete, fail, and cancel
- reject expired claims and make duplicate completion harmless
- let Postgres recompute identities and validate output and actions
- expose fixed-search-path `SECURITY DEFINER` RPCs with no direct table writes
- use separate installer, worker, reviewer, auditor, and action roles with verified TLS
- preflight DNS, TLS, roles, required functions, and egress-denied operation
- require candidate-query `EXPLAIN`, statement timeout, row, input-byte, queue-depth, and queued-byte caps
- run local GGUF inference without a required remote model API
- keep application queries independent of a live worker

Start with one worker, one database, and one model. The conformance suite must cover worker loss, full queues, stale claims, duplicate writes, database restart or failover, credential rotation, malformed output, stale rows, upgrade, and rollback

Track queue, memory, connections, disk, WAL, storage, autovacuum, and application latency. Pause claims when configured database-health limits fail

## Trust And Evidence

Treat source text, model files, model output, identifiers, and imported configuration as untrusted input

- document native and portable threat models
- allowlist source fields, model paths, action types, and action targets
- bound input, output, token, trace, cache, queue, evidence, and memory use
- test prompt injection, secret canaries, Unicode, malicious identifiers, oversized fields, and malformed artifacts
- prevent model text from choosing action authority or target identity
- keep adversarial or unevaluated cases recommendation-only
- apply retention to inputs, outputs, actions, corrections, traces, events, labels, and materializations
- support structured-output redaction, cleanup dry runs, retention holds, and cleanup receipts
- account for storage, WAL, backup, restore, and point-in-time-recovery copies
- document deletion limits for backups and point-in-time recovery
- expose structured logs, metrics, permission state, and redaction state without raw source text by default
- test where a sensitive canary appears and when cleanup removes it from active state
- export a complete decision trace and add signed manifests for future tamper evidence

JSON Schema constrains structure. Evaluation and review still determine semantic correctness

## Packs And Decisions

Use `otlet.watch.v1` for portable workload configuration. Keep SQL, JSON Schema, and ordinary files as the authoring surface

Each pack contains bounded candidate SQL, prompts, schemas, model policy, fixtures, labels, expected receipts, version metadata, digests, and benchmark gates. SQL import, lint, dry run, diff, export, and rollback complete the lifecycle

Ship one entity-resolution pack with vendor, account, and catalog-item fixtures. Add other workloads only when they reuse the same contracts

Keep review state in SQL:

- reviewer identity, role, reason, timestamp, and freshness state
- approve, reject, correct, defer, and abstain outcomes
- review history and deterministic links to source identity, receipt, output, action, model, prompt, and schema
- label import and export without required source-row export
- workload-weighted quality, abstention, action, latency, and reviewer-time metrics
- baseline comparisons and regression gates for model, prompt, schema, runtime, and pack changes

Keep recommendation-only operation as the default. Mutation or export requires target allowlists, a fresh source-state check, dry-run evidence, approval, replay checks, execution receipts, receiver-enforced idempotency, authenticated destination acknowledgement, and reconciliation

Provide SQL and CSV export plus a signed recommendation envelope. Leave network delivery outside the library

Do not add a plugin system, registry process, custom workflow language, or connector catalog

## GPU And Deferred Research

A GPU path must preserve the worker and SQL contracts. Report device policy, memory, throughput, energy when available, database responsiveness, crash behavior, cancellation, and CPU fallback

Reopen measured research only when its trigger changes:

| Avenue | Trigger |
| --- | --- |
| Single-context batching | llama.cpp or memory changes remove the throughput and RSS tradeoff |
| Multi-model residency | Two useful contexts fit with Postgres headroom |
| Speculative decode | Compatible draft heads and safe caller hooks exist |
| Persisted cache | Restart or eviction misses consume material workload time |
| PostgreSQL core changes | A required planner or executor contract has no extension hook |
| New CPU paths | Hardware exposes a distinct BLAS, NUMA, SMT, or energy condition |

Any reopened path must preserve correctness, trusted quality, memory bounds, database responsiveness, and crash behavior

## Boundaries

- local inference runs through the resident worker or SQL-bound reference worker
- source rows stay in user tables
- derived state stays under `otlet`
- Postgres validates trusted output and action contracts
- portable writes require live claim fencing
- user-table writes require typed actions, approval, fresh source state, and receipts
- review and evaluation state remain SQL-visible
- SQL selects candidates before model judgment
- normal application queries do not wait for inference
- EXPLAIN and status views expose model work
- no second database or required remote model API enters the core path
