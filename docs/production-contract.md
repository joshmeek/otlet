# Production Contract

Use this after the entity-resolution and semantic-watch checks. It inspects production surfaces for bounded, visible, database-owned model work

## Step 1 - Inspect Trace Visibility Across The System

The trace visibility view reports links from receipts to outputs, actions, token steps, top-k alternatives, provenance, stale policy, and CustomScan infer-now

```sql
SELECT 'inference_visibility_status=' ||
       (receipt_count > 0)::text || '|' ||
       (token_steps > 0)::text || '|' ||
       (top_k_alternatives > 0)::text || '|' ||
       (max_detailed_trace_tokens <= 16)::text || '|' ||
       (max_detailed_trace_top_k <= 3)::text AS inference_visibility_contract
FROM otlet.inference_visibility_status;
```

Representative output:

```text
inference_visibility_status=true|true|true|true|true
```

The five booleans confirm receipts, token steps, top-k alternatives, bounded trace tokens, and bounded top-k width

## Step 2 - Inspect Runtime Status After Demo Runs

Runtime status shows the resident model slot, cache bounds, memory samples, and last run metrics

```sql
SELECT runtime_status || '|' ||
       slot_state || '|' ||
       COALESCE(tokens_per_second::text, '') || '|' ||
       (COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0))::text || '|' ||
       (COALESCE(inference_cache_max_entries, 0) > 0)::text || '|' ||
       (COALESCE(inference_cache_max_bytes, 0) > 0)::text || '|' ||
       COALESCE(inference_cache_last_eviction_reason, '') || '|' ||
       COALESCE(worker_memory_sample_policy, '') AS runtime_contract
FROM otlet.runtime_status
WHERE model_name = 'qwen3_1_7b'
LIMIT 1;
```

Representative output from the demo run:

```text
runtime_status_contract=ready|ready|35.71|true|true|true|none|linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run
```

The value reports a ready runtime, a ready model slot, bounded cache entries and byte caps, no recent eviction, and Linux process-status memory sampling after a worker run

## Step 3 - Inspect Production Policy

The production policy row and status views expose SQL state under `otlet`: `production_policy_status`, `production_status`, `model_queue_status`, `worker_throughput_status`, and `cleanup_policy_state(true)`

Queue caps are admission-time controls. Rows enter `otlet.jobs` through `run_task`, watch refresh, semantic refresh, or `ask`; direct inserts are internal/testing-only and can bypass admission accounting. `verify_invariants()` returns one row per violation. The demo requires `SELECT count(*) FROM otlet.verify_invariants()` to return `0` (`invariant_contract=0`). The `queued_jobs_within_model_cap` check reports models whose queued depth exceeds `max_queued_jobs_per_model`

Claimed jobs use `otlet.effective_job_lease_interval(...)`, which covers the task attempt timeout plus 30 seconds of completion grace. Workers call `otlet.renew_job_lease(job_id, expected_attempt)` before each direct, cheap, or strong model attempt. The expected attempt is a fence: a stale worker cannot renew a job after another worker has reclaimed it. `model_selection_policy_status.effective_job_lease_interval` exposes the derived interval

Otlet debounces suppressed queue-admission events per task and reason for one minute, so a full queue stays visible without flooding `worker_events`. `production_status` exposes `semantic_materialization_failed_events` and `semantic_materialization_last_failed_at`. Nonzero `max_worker_rss_bytes` budgets require Linux process-status RSS sampling; runtime-option validation rejects unsupported builds before queue execution. Cleanup can prune old failed or canceled jobs after outputs, actions, eval labels, and receipts no longer reference them

The resident worker attaches to the `postgres` database. Supporting worker registration across multiple databases requires separate shared-memory and latch routing

Native llama.cpp faults bypass Rust's error boundary. Otlet contains them through Postgres worker restart and lease recovery. Otlet trusts no partial model output, and `otlet.sweep_expired_jobs()` fails expired running jobs that reached the attempt limit with a receipt. The demo scans container logs and prints `docker_crash_log_scan=ok` when the run contains no worker crash, panic, assertion, or terminated server process

```sql
SELECT otlet.sweep_expired_jobs();

SELECT j.status, j.error, r.status AS receipt_status, r.selection_reason
FROM otlet.jobs j
JOIN otlet.inference_receipts r ON r.job_id = j.id
WHERE r.selection_reason = 'job_lease_expired_after_max_attempts'
ORDER BY r.id DESC
LIMIT 1;
```

Representative targeted smoke output:

```text
ffi_sweep_safety_contract=1|failed|job lease expired after max attempts|failed|failed|job_lease_expired_after_max_attempts
```

Representative output from the demo contract:

```text
production_policy_contract=default|refresh_then_fail_closed|3|300000|8
production_status_contract=true|true|true|true
model_queue_status_contract=queue_accepting|0|0
throughput_status_contract=queue_accepting|0|0|4|4|0
cleanup_policy_dry_run=0|0|0|0|0|0|0|true
```

### Step 3b - Performance Ratios

`production_status` exposes trusted-output and model-work ratios. The demo prints them as one contract line:

```sql
SELECT trusted_output_rows::text || '|' ||
       model_invocations::text || '|' ||
       round(model_invocations_per_trusted_row, 3)::text || '|' ||
       model_processed_tokens::text || '|' ||
       round(model_processed_tokens_per_trusted_row, 3)::text
FROM otlet.production_status;
```

Representative demo output:

```text
performance_ratio_contract=34|43|1.265|15948|469.059
```

### Step 3c - Materialization Failure Visibility

```sql
BEGIN;
INSERT INTO otlet.worker_events (event_type, message, detail)
VALUES (
  'semantic_materialization_failed',
  'smoke',
  '{"task_name":"demo","model_name":"qwen35_4b","error":"smoke"}'::jsonb
);
SELECT (semantic_materialization_failed_events >= 1)::text || '|' ||
       (semantic_materialization_last_failed_at IS NOT NULL)::text
FROM otlet.production_status;
ROLLBACK;
```

Contract: `true|true` (demo prints `materialization_failure_status_contract=true|true`)

### Step 3d - Zero Invariant Violations

```sql
SELECT count(*) FROM otlet.verify_invariants();
```

Contract: `0` (demo prints `invariant_contract=0`). The suite fails closed on expired or NULL leases for `running` and `cancel_requested` jobs, complete receipts without schema pass, materializations missing `source_hash`, and error runtime slots. `production_status` and `verify_invariants` name the receipt invariant `complete_receipts_are_schema_validated`; throughput views use `completed_jobs` and `last_batch_completed_jobs`. Step 6 of `docs/semantic-watches.md` anchors the planner vocabulary for `selected_path` / `Planner Selected Path` and `freshness_basis`

Operators query redacted, read-only projections through `otlet.audit_receipt_export`, `otlet.audit_review_export`, `otlet.audit_eval_label_export`, `otlet.semantic_dependency_audit`, and `otlet.worker_batch_timing_status`. `otlet.redaction_policy_status` lists withheld fields

## Step 4 - Assign Application-Owned Controls

Otlet installs internal production policy, bounded queues, leases, sweeps, validation evidence, action approval state, status views, and cleanup dry-run/apply functions. Your application owns tenant access, app roles, and who may approve or apply actions

Check row-level security:

```sql
SELECT 'rls_contract=' ||
       count(*)::text || '|' ||
       (count(*) FILTER (WHERE relrowsecurity))::text
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'otlet'
  AND c.relkind = 'r';

SELECT 'installed_policies=' || count(*)::text
FROM pg_policies
WHERE schemaname = 'otlet';
```

Representative output:

```text
rls_contract=19|0
installed_policies=0
```

Check default grants visible through `information_schema`:

```sql
SELECT 'grant_contract=' ||
       string_agg(privilege_type || ':' || n::text, '|' ORDER BY privilege_type)
FROM (
  SELECT privilege_type, count(*) AS n
  FROM information_schema.role_table_grants
  WHERE table_schema = 'otlet'
  GROUP BY privilege_type
) grants;
```

Representative output:

```text
grant_contract=DELETE:44|INSERT:44|REFERENCES:44|SELECT:44|TRIGGER:44|TRUNCATE:44|UPDATE:44
```

Your application owns these production boundaries:

- create app roles with the views and functions you want
- add RLS or schema isolation if multiple tenants share the database
- schedule `otlet.cleanup_policy_state(false)` if your deployment wants periodic worker-event, trace, stale materialization, rejected raw-output, and unreferenced failed/canceled job pruning
- expose `otlet.approve_action`, `otlet.reject_action`, `otlet.dry_run_action`, and `otlet.apply_action` to action-operator roles
- allow action types your application has code to interpret
