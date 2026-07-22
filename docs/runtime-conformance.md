# Runtime conformance

Run the complete non-benchmark validation ring:

```bash
OTLET_MAX_WORKER_RSS_BYTES=12884901888 ./scripts/otlet-runtime-conformance.sh
```

The command creates a fresh native installation, runs the full real-model demo, runs the reference external worker and recovery proof, checks the isolated portable deployment preflight, and finishes with the disposable install and upgrade lifecycle

The native and portable equivalence fixture uses one MVCC-backed task and identical accepted, abstained, action-bearing, and malformed cases. It compares task, job, output, receipt, review, action, evaluation-label, source-freshness, and portable-claim state while allowing only the declared runtime name and endpoint to differ

## Failure matrix

| Case | Executable evidence |
| --- | --- |
| Worker loss | external worker kill, expired lease, reclaim, single accepted output, structured recovery events |
| Full queue | shared admission caps reject the extra claim without queue mutation |
| Stale claim | native and portable claim fences reject old tokens; the recovery worker abandons the lost claim |
| Duplicate write | exact terminal delivery returns the existing receipt and conflicting delivery fails |
| Database restart | the external worker reports database loss, reconnects, and completes new work after restart |
| Credential rotation | the old SCRAM password succeeds before rotation, fails after rotation, and the new password succeeds |
| Malformed output | native and portable completion reject the same malformed envelope without trusted output |
| Stale source | PostgreSQL recomputes MVCC-backed content and rejects stale portable completion |
| Protocol change | incompatible protocol versions claim no work and fail preflight with a stable reason |
| Installation upgrade | the lifecycle preflight validates the installed binary, control file, invariant state, preload state, and update path |
| Rollback | injected extension-upgrade and preload failures preserve database state and recover cleanly |

The final gate requires zero invariant violations and clean PostgreSQL crash-log scans. Performance validation uses the existing workload gates, planner smoke, bounded runtime status, and checked performance ratio; it does not publish a benchmark claim

Known limits and closed research triggers live in [the roadmap](roadmap.md)
