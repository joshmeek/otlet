# Otlet roadmap

No feature track is active. New work needs a measured trigger, SQL-visible state, a closed failure mode, and executable proof

## Limits

- Docker validation targets PostgreSQL 18 on Linux
- native execution requires a host that can load the extension and resident background worker
- the reference portable deployment uses one supervised worker, one database, and one local GGUF model
- lifecycle tests cover database restart and recovery, not multi-node failover
- CPU execution is the supported runtime; no GPU scheduling or CPU fallback matrix ships in core
- backup, snapshot, replica, restore, and point-in-time-recovery deletion remain deployment responsibilities
- performance smoke does not replace hardware-specific measurement

## Deferred

| Track | Reopen when |
| --- | --- |
| Accelerators and alternate CPU paths | A supported deployment needs them and can preserve current runtime contracts |
| Batching, multi-model residency, speculative decoding, or persisted cache | Measurements justify their memory and complexity cost |
| PostgreSQL core changes | A required planner or executor contract has no extension hook |
| Remote providers, plugins, or built-in delivery | A shipped workload cannot use local inference and application-owned delivery |
| Evaluation gates, watch history, retention workflows, or signed bundles | A shipped deployment cannot keep those controls in CI, Git, or infrastructure policy |

## Non-negotiables

- source rows stay in user tables and derived state stays under `otlet`
- PostgreSQL validates trusted output, action contracts, portable results, and claim fencing
- mutation requires workflow authority, fresh source state, dry-run evidence, approval, replay checks, and execution receipts
- normal application queries remain independent of a live worker
- no second database or required remote model API enters the core path
