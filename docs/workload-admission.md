# Workload Admission

Otlet admits bounded source work before it creates jobs. Bulk `run_task` calls enqueue every eligible row or none, while single-subject calls return false when capacity is unavailable. Row-watch triggers persist coalesced dirty state instead of waiting on worker or queue availability

The default production policy sets these limits:

| Limit | Default |
| --- | ---: |
| Rows per bulk admission | 1,000 |
| Raw input bytes per job | 1 MiB |
| Queued jobs per model | 1,000 |
| Queued input bytes per model | 64 MiB |
| Queued input bytes per task | 64 MiB |
| Total queued input bytes | 256 MiB |
| Active claimed jobs per task | 8 |
| Maximum queue age per task | 1 day |
| Native interactive queue-age p99 target | 30,000 ms |
| Native asynchronous queue-age p99 target | 30,000 ms |
| Native cancellation-observation p99 target | 1,000 ms |
| Watch reconciliation attempts | 12 |
| Watch reconciliation base delay | 1,000 ms |
| Watch reconciliation maximum delay | 300,000 ms |
| Candidate plan cost | 1,000,000 |
| Candidate statement timeout | 2,000 ms |

Definition authoring uses fixed platform limits rather than production-policy settings:

| Definition limit | Maximum |
| --- | ---: |
| Instruction | 64 KiB |
| Query | 256 KiB |
| Output schema | 256 KiB |
| Runtime JSON | 64 KiB |
| Input shaping | 64 KiB |
| Decision contract | 256 KiB |
| Complete definition | 1 MiB |
| JSON depth | 32 |
| JSON nodes | 8,192 |
| Definition identifiers | 4,096 |
| Query identifiers | 4,096 |
| Empty-input prompt template | 256 KiB |

`otlet.definition_complexity_limits` exposes the limits. `otlet.definition_complexity_status` reports the measured instruction, query, schema, runtime, shaping, decision, complete-definition, JSON, identifier, and prompt sizes for every active workload revision. Query binding also caps resolved query text and source dependencies. Task, ask, watch, import, policy, preset, query-binding, and revision writes reject excess work before schema traversal, hashing, or prompt construction, and the surrounding transaction leaves no partial registry state

Each model registration sets `max_active_jobs`, with a default of one. The production policy also sets `max_active_jobs_per_task`, from 1 through 1,024. Both limits count live claimed leases across native, portable, and infer-now execution. A `running` or `cancel_requested` job consumes a slot while its lease is live. Queued, terminal, null-lease, and expired-lease jobs consume none. A claim needs both a model slot and a task slot

The singleton production policy applies task limits separately to each task. `max_queued_input_bytes_per_task` accepts 1 byte through 1 GiB and cannot exceed `max_queued_input_bytes_total`. `max_queue_age` accepts 1 second through 30 days. Otlet has no per-task or per-origin override

Operators set three positive bounded native p99 targets. The interactive and asynchronous queue targets remain declared and unmeasured, while `native_cancellation_slo_status` measures the cancellation target. Admission backpressure continues to use `max_queue_age`

PostgreSQL assigns one immutable origin at admission:

| Ingress | `job_origin` |
| --- | --- |
| Synchronous or queued ask | `direct_ask` |
| Ordinary task run and replay evaluation | `task_run` |
| Row-watch refresh | `row_watch` |
| Pair-watch refresh | `pair_watch` |
| Durable watch reconciliation | `catch_up` |
| Bounded backfill | `backfill` |
| Queued or infer-now CustomScan | `customscan` |

Foreground adoption of a deferred backfill job keeps `backfill`. Public task admission defaults to `task_run`; a session setting cannot change it

`otlet.model_queue_status`, `otlet.production_policy_status`, and `otlet.production_status` expose current limits and queue bytes. `otlet.task_queue_status` groups queued rows, bytes, and oldest age by task and origin and repeats the task-wide byte and age headroom. `otlet.task_resource_status` groups live claims by task and origin and reports task-wide slots. Model and worker status expose model slots. `otlet.runs`, `otlet.inference_receipt_trace_status`, `otlet.portable_receipt_status`, and `otlet.audit_receipt_export` expose the stored origin. `otlet.verify_invariants()` checks live model claims, queue depth, per-job bytes, per-model bytes, and total bytes; migration 0075 adds no task-budget invariant

Queue bytes count evaluation work plus production work under each active task revision, matching global admission accounting. Queue age starts at the oldest counted queued job's `created_at`. An exceeded age or byte limit rejects new work for that task with `task_queue_age_cap` or `task_queued_input_byte_cap`; other tasks continue independently. Existing jobs remain queued and claimable. Fallback requeue can temporarily put stored bytes above an admission cap, so byte and age limits are admission backpressure rather than expiry or hard queue-state invariants

Admission also requires an active task revision. Pausing a task removes its revision head after leased work drains, so direct, application, native, portable, and watch admission reject new work and claims leave existing queued jobs untouched. Exact-pin resume restores that queue under the same revision. Retirement requires an empty queue and watch-reconciliation backlog, locks the pinned source identities, and is terminal. `task_lifecycle_status` exposes the state, pin, queue and reconciliation counts, source identity drift, and transition blockers

## Enablement Preflight

The extension owner can inspect one active watch refresh or bounded backfill before admission. Pass the expected active revision so a concurrent revision change fails instead of producing a report for the wrong workload:

```sql
SELECT *
FROM otlet.workload_enablement_preflight(
  requested_task_name => 'entity_resolution_task',
  expected_workload_revision_hash => (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'entity_resolution_task'
  ),
  requested_enablement_kind => 'backfill',
  requested_max_subjects => 1000,
  requested_page_size => 64,
  requested_max_jobs_per_minute => 64,
  requested_max_outstanding_jobs => 64
);
```

Use `watch` without backfill bounds for an existing row or pair watch. The function can run inside a read-only transaction and creates no jobs, backfill, observation, or capacity reservation. It checks stored source identity, dependencies, and row schema, then uses non-executing `EXPLAIN`. It does not run candidate rows or the temp-view source-query rebind, and names those estimate limits in `uncertainty_reasons`

`estimated_candidates` is the estimated work set before active-job subtraction. Row watches use estimated stale and missing semantic state. Pair watches combine the candidate plan with known fresh and stale materializations because membership is not executed. `estimated_jobs` removes current in-flight subjects. Generic backfills use plan cardinality and active same-revision jobs. Recent nonempty candidate observations other than row-cap overflow supply input size; otherwise the estimate uses plan width

Semantic plans read revision-pinned generic counts maintained outside planning. Row source triggers maintain inserts, subject moves, updates, deletes, delete-reinsert sequences, and truncation. A pair source change invalidates its snapshot; plans use the bounded `max_candidate_rows` as missing work until `refresh_semantic_join_index(...)` or explicit `maintain_semantic_planner_statistics(...)` enumerates the candidate set. `semantic_predicate_counts(...)` provides an exact read-only JSON predicate diagnostic and never supplies planning input

`model_ms_p25`, `model_ms_p50`, and `model_ms_p75` cover prompt decode plus generation. The matching `service_ms_*` fields use stage-accounted worker time. Samples prefer the active revision, then the task on a current route, then other production work on a current route, with at most 101 observations per scope. Missing history falls back to the revision attempt deadline

Catch-up scenarios use serial stage-accounted service time, current queued, running, and cancel-requested model work, and the backfill rate floor. They exclude worker parallelism, manual delay between backfill pages, and unmeasured worker overhead. Observed and current queue bytes use `octet_length(input::text)`; the no-observation fallback uses plan width. Neither estimates heap, index, TOAST, or WAL storage

`within_current_policy` is true only when `policy_blockers` is empty. Backfill capacity uses the lower of estimated jobs and requested outstanding jobs, preserves one foreground model slot and one maximum-input reserve under the task, model, and total byte caps, and rejects another unfinished backfill for the task revision. Exact watch refresh or backfill admission rechecks source binding, candidate execution, queue state, and every policy limit under its own transaction fence

Pair-watch creation runs `EXPLAIN (FORMAT JSON)` without executing candidate rows. Otlet stores the accepted plan, total cost, and preflight timestamp on the immutable workload revision and rejects invalid or over-cost plans before watch mutation

Every pair execution revalidates source dependencies and reruns plan-cost preflight. `otlet.watch_status` keeps the accepted revision evidence separate from the current read-only plan, reports drift and current preflight status, and suspends the watch when the live plan exceeds policy. Source-query repair must capture fresh accepted evidence before it can promote a revision

Candidate execution reads one row past `max_candidate_rows`. Otlet rejects overflow before it returns rows, creates jobs, or reconciles removed candidates. This makes `candidate_removed` evidence depend on a complete candidate set rather than a truncated top-N result

Postgres cannot arm `statement_timeout` from inside the statement already executing. Set it in the session or in a transaction before every pair refresh:

```sql
BEGIN;
SET LOCAL statement_timeout = '2000ms';
SELECT otlet.refresh_semantic_join_index('vendor_pairs');
COMMIT;
```

Otlet rejects a pair refresh when the timeout is zero or exceeds `candidate_query_statement_timeout_ms`. A timed-out query creates no jobs

`input_shaping.source_fields` is the top-level source-field allowlist. A missing list becomes empty. `input_shaping.max_shaped_input_bytes` accepts integers from 1 through 1 MiB. Row and pair watches, imported `otlet.watch.v1` definitions, direct tasks, and the shared `admit_task_input` database path use the same task and admission checks. `ask` keeps its stricter 8 KiB shared-memory input cap

Capacity rejection records a debounced `queue_admission_suppressed` event with a stable reason such as `row_cap`, `input_byte_cap`, `queue_depth_cap`, `task_queue_age_cap`, `task_queued_input_byte_cap`, `model_queued_input_byte_cap`, or `total_queued_input_byte_cap`. For `mark_stale_and_enqueue` row watches, PostgreSQL retains the newest source identity and retries through `watch_reconciliation`. `watch_status` exposes pending count, exhausted count, oldest age, and next retry; `watch_reconciliation_status` exposes each entry for owner replay or generation-fenced acknowledgement
