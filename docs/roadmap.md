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
| Portable worker platform parity | A managed-PostgreSQL deployment needs more than queued task execution |

## Portable worker

The SQL-only install supports queued tasks through `otlet.run_task(...)` and `otlet.run_task_subject(...)`, fenced polling claims, local GGUF inference, trusted completion, receipts, actions, and worker lifecycle control

| Surface | Portable status |
| --- | --- |
| `otlet.ask(...)` | The portable path cannot run it because an external worker cannot see a job created inside the caller's open transaction. Add an asynchronous enqueue API with status and result reads |
| Watches and semantic reads | The installer omits these surfaces. Add the SQL-only watch lifecycle, change enqueue, completion materialization, reads, and status |
| Model selection | The current worker supports one registered model per process. It does not run cheap-to-strong escalation or multi-model routing |
| Planner integration | The native extension owns CustomScan, infer-now, shared memory, and resident-worker status. Keep them outside portable parity |

Require isolated portable smoke proof against a SQL-only database before moving a surface out of this section

## Non-negotiables

- source rows stay in user tables and derived state stays under `otlet`
- PostgreSQL validates trusted output, action contracts, portable results, and claim fencing
- mutation requires workflow authority, fresh source state, dry-run evidence, approval, replay checks, and execution receipts
- normal application queries remain independent of a live worker
- no second database or required remote model API enters the core path
