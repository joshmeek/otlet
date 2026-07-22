# Workload Admission

Otlet admits bounded source work before it creates jobs. Bulk `run_task` calls enqueue every eligible row or none, while single-subject calls return false when capacity is unavailable so row-watch triggers do not block application writes on worker availability

The default production policy sets these limits:

| Limit | Default |
| --- | ---: |
| Rows per bulk admission | 1,000 |
| Raw input bytes per job | 1 MiB |
| Queued jobs per model | 1,000 |
| Queued input bytes per model | 64 MiB |
| Total queued input bytes | 256 MiB |
| Candidate plan cost | 1,000,000 |
| Candidate statement timeout | 2,000 ms |

`otlet.model_queue_status`, `otlet.production_policy_status`, and `otlet.production_status` expose current limits and queue bytes. `otlet.verify_invariants()` checks queue depth, per-job bytes, per-model bytes, and total bytes

Pair-watch creation runs `EXPLAIN (FORMAT JSON)` without executing candidate rows. Otlet stores the plan, total cost, and preflight timestamp on the semantic join index and rejects invalid or over-cost plans before watch mutation

Postgres cannot arm `statement_timeout` from inside the statement already executing. Set it in the session or in a transaction before every pair refresh:

```sql
BEGIN;
SET LOCAL statement_timeout = '2000ms';
SELECT otlet.refresh_semantic_join_index('vendor_pairs');
COMMIT;
```

Otlet rejects a pair refresh when the timeout is zero or exceeds `candidate_query_statement_timeout_ms`. A timed-out query creates no jobs

`input_shaping.max_shaped_input_bytes` accepts integers from 1 through 1 MiB. Row and pair watches, imported `otlet.watch.v1` definitions, direct tasks, and the shared `admit_task_input` database path use the same task and admission checks. `ask` keeps its stricter 8 KiB shared-memory input cap

Capacity rejection records a debounced `queue_admission_suppressed` event with a stable reason such as `row_cap`, `input_byte_cap`, `queue_depth_cap`, `model_queued_input_byte_cap`, or `total_queued_input_byte_cap`
