# Production Contract

Use this after the entity-resolution and semantic-watch checks. It inspects the production surfaces that keep model work bounded, visible, and database-owned

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

Those booleans prove receipts, token steps, top-k alternatives, bounded trace tokens, and top-k width were present

## Step 2 - Inspect Runtime Status After Advanced Runs

Runtime status shows the resident model slot, cache bounds, memory samples, and last run metrics

```sql
SELECT runtime_status || '|' ||
       slot_state || '|' ||
       COALESCE(tokens_per_second::text, '') || '|' ||
       (COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0))::text || '|' ||
       COALESCE(worker_memory_sample_policy, '') AS runtime_contract
FROM otlet.runtime_status
WHERE model_name = 'qwen3_1_7b'
LIMIT 1;
```

Representative output from the demo run:

```text
runtime_status_contract=ready|ready|35.71|true|linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run
```

The value reports a ready runtime, a ready model slot, bounded cache entries, and Linux process-status memory sampling after a worker run

## Step 3 - Inspect Production Policy

The production policy row and status views are ordinary SQL state under `otlet`: `production_policy_status`, `production_status`, `model_queue_status`, `worker_throughput_status`, and `cleanup_policy_state(true)`

Queue caps are admission-time controls. Rows enter `otlet.jobs` through `run_task`, watch refresh, semantic refresh, or `ask`; direct inserts are internal/testing-only and can bypass admission accounting. `verify_invariants()` reports `queued_jobs_within_model_cap` if queued depth for any model exceeds `max_queued_jobs_per_model`

Otlet debounces suppressed queue-admission events per task and reason for one minute, so a full queue stays visible without flooding `worker_events`. `production_status` also exposes `semantic_materialization_failed_events` and `semantic_materialization_last_failed_at`. Nonzero `max_worker_rss_bytes` budgets require Linux process-status RSS sampling; unsupported builds reject the option during runtime-option validation instead of letting jobs fail later. Cleanup can prune old failed/canceled jobs only when outputs, actions, eval labels, and receipt references no longer keep them alive

The resident worker attaches to the `postgres` database. Multi-database worker registration needs separate shared-memory and latch routing work before it is a supported deployment shape

Native llama.cpp faults happen below Rust's normal error boundary. Otlet's containment contract is Postgres worker restart plus lease recovery: Otlet trusts no partial model output, and `otlet.sweep_expired_jobs()` fails expired running jobs that reached the attempt limit with a receipt. The full demo also scans container logs and prints `docker_crash_log_scan=ok` when no worker crash, panic, assertion, or terminated server process appears during the run

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

## Step 4 - Know The Remaining Production Boundaries

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
