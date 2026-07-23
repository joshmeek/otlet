# Otlet roadmap

This file lists unshipped library work. The shipped system is documented by the production contract, portable worker guide, release lifecycle, and runtime conformance suite

## Active work

No feature track is active after the 24-part execution pass

New work needs a measured trigger, SQL-visible state, a closed failure mode, and executable proof. Keep source freshness, bounded resources, PostgreSQL-owned validation, review state, action authority, receipts, and deployment recovery intact

## Known limits

- release and runtime evidence targets PostgreSQL 18 on Linux
- native execution requires a host that can load the extension and resident background worker
- the reference portable deployment uses one supervised worker, one database, and one local GGUF model
- the conformance ring proves database restart and recovery, not a multi-node failover product
- credential rotation proof covers PostgreSQL authentication; infrastructure still owns secret rollout and connection draining
- CPU execution is the supported runtime; no GPU scheduling or CPU fallback matrix ships in core
- signed decision bundles are local artifacts; applications own transport and receiver integration
- backup, snapshot, replica, restore, and point-in-time-recovery deletion remain deployment responsibilities
- bounded performance smoke detects obvious regression but does not replace hardware-specific throughput, latency, memory, energy, and database-responsiveness measurement

## Closed research

These tracks stay closed until their recorded trigger changes:

| Avenue | Reopen trigger |
| --- | --- |
| GPU execution and device scheduling | A supported deployment needs it and can preserve the worker, receipt, quality, memory, cancellation, and fallback contracts |
| Single-context batching | llama.cpp or memory behavior removes the throughput and RSS tradeoff |
| Multi-model residency and scheduling | Two useful contexts fit with measured PostgreSQL headroom |
| Speculative decoding | Compatible draft heads and safe caller hooks exist |
| Persisted inference cache | Restart or eviction misses consume material workload time |
| PostgreSQL core patches or a maintained fork | A required planner or executor contract has no extension hook |
| New CPU execution paths | Hardware exposes a distinct BLAS, NUMA, SMT, or energy condition |
| Provider matrices and remote model APIs | A concrete deployment cannot use the local native or portable runtime |
| Plugin systems, registry processes, custom workflow languages, and connector catalogs | Repeated shipped workloads cannot use SQL, JSON Schema, watch packs, and application-owned delivery |
| Built-in network delivery | Receiver reconciliation cannot remain an application transport concern |

## Boundaries

- source rows stay in user tables and derived state stays under `otlet`
- PostgreSQL validates trusted output, action contracts, portable results, and claim fencing
- mutation requires workflow authority, fresh source state, dry-run evidence, approval, replay checks, and execution receipts
- export requires content-addressed decision evidence, external signing keys, receiver idempotency, authenticated acknowledgement, and reconciliation
- normal application queries remain independent of a live worker
- no second database or required remote model API enters the core path
