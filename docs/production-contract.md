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

The five booleans confirm receipts, numeric token steps, numeric top-k alternatives, bounded trace tokens, and bounded top-k width. The default storage policy removes chosen text and token text before it writes the receipt

## Step 2 - Inspect Runtime Status After Demo Runs

Runtime status shows the resident model slot, cache bounds, memory samples, pressure, and last run metrics

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
runtime_status_contract=ready|ready|40.97|true|true|true|none|linux_proc_self_and_optional_cgroup_v2_memory_pressure_v1
```

The value reports a ready runtime, a ready model slot, bounded cache entries and byte caps, no recent eviction, and Linux process, system, PSI, and optional cgroup-v2 memory sampling around a worker run. Token rates vary with host state

The latest detailed receipt also binds runtime status to the same versioned fingerprint and output-affecting cache contract:

```sql
SELECT runtime_fingerprint_version,
       runtime_fingerprint_hash,
       runtime_output_contract_hash,
       runtime_fingerprint
FROM otlet.runtime_status
WHERE model_name = 'qwen35_4b';
```

The receipt view exposes the full `memory_evidence` document and typed columns for RSS, swap, available memory, major faults, file reads, pressure totals, cgroup events, and model-load admission. A nonzero `max_worker_rss_bytes` budget checks a replacement before tensor allocation:

```sql
SELECT j.status,
       s.stop_reason,
       s.model_load_admission_decision,
       s.model_load_admission_reason,
       s.model_load_allowed_additional_bytes,
       s.memory_evidence #>> '{admission,projected_total_bytes}' AS projected_total_bytes
FROM otlet.inference_receipt_trace_status s
JOIN otlet.jobs j ON j.id = s.job_id
WHERE s.task_name = 'preload_admission_demo'
ORDER BY s.receipt_id DESC
LIMIT 1;
```

The demo first makes the smaller model resident, then asks for the larger model with a budget above current RSS but below the projected load. Rejection creates a receipt and `model_admission_rejected` event without a model swap, worker restart, or loss of the resident model:

```text
preload_admission_contract=failed|model_load_admission_rejected|rejected|true|true|true|true|0|true|true|true|true
```

## Step 3 - Inspect Production Policy

The production policy row and status views expose SQL state under `otlet`: `production_policy_status`, `production_status`, `model_queue_status`, `worker_throughput_status`, and `cleanup_policy_state(true)`

Queue caps are admission-time controls. Rows enter `otlet.jobs` through `run_task`, watch refresh, semantic refresh, or `ask`; direct inserts are internal/testing-only and can bypass admission accounting. `verify_invariants()` returns one row per violation. The demo requires `SELECT count(*) FROM otlet.verify_invariants()` to return `0` (`invariant_contract=0`). The `queued_jobs_within_model_cap` check reports models whose queued depth exceeds `max_queued_jobs_per_model`

Claimed jobs use `otlet.effective_job_lease_interval(...)`, which covers the task attempt timeout plus 30 seconds of completion grace. Workers call `otlet.renew_job_lease(job_id, expected_attempt)` before each direct, cheap, or strong model attempt. The expected attempt is a fence: a stale worker cannot renew a job after another worker has reclaimed it. `model_selection_policy_status.effective_job_lease_interval` exposes the derived interval

Otlet debounces suppressed queue-admission events per task and reason for one minute, so a full queue stays visible without flooding `worker_events`. `production_status` exposes `semantic_materialization_failed_events` and `semantic_materialization_last_failed_at`. Nonzero `max_worker_rss_bytes` budgets require Linux RSS, total-memory, and available-memory samples. A cache miss also requires artifact metadata and a no-allocation llama.cpp projection; missing evidence or insufficient headroom rejects the load before tensor allocation. Cleanup can prune old failed or canceled jobs after outputs, actions, eval labels, and receipts no longer reference them

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
production_policy_contract=default|refresh_then_fail_closed|3|300000|8|redacted
production_status_contract=true|true|true|true
model_queue_status_contract=queue_accepting|0|0
throughput_status_contract=queue_accepting|0|0|4|4|0
cleanup_policy_dry_run=0|0|0|0|0|0|0|0|0|0|true
```

### Step 3a - Inspect Stored Evidence Redaction

Otlet keeps assembled prompts in worker memory and stores `prompt_hash` on receipts. The `redacted` production default stores raw-output hashes, structured accepted output, structured rejected candidates, token IDs, probabilities, and timing. It removes raw model text, reconstructed chosen text, and token text before receipt insertion

```sql
SELECT assembled_prompt_storage,
       sensitive_evidence_mode,
       raw_output_rows,
       chosen_text_rows,
       token_text_values,
       alternative_token_text_values,
       overdue_sensitive_rows,
       storage_compliant
FROM otlet.redaction_policy_status;
```

The demo contract is:

```text
redaction_status_contract=redacted|0|0|0|0|0|true
```

The extension owner can enable `diagnostic` mode for a bounded local investigation or benchmark. Otlet keeps diagnostic fields owner-only. `sensitive_evidence_retention` controls their lifetime. Switching back to `redacted` makes those fields cleanup candidates without waiting for the interval

```sql
BEGIN;
UPDATE otlet.production_policy
SET sensitive_evidence_mode = 'diagnostic'
WHERE name = 'default';

-- Run the bounded diagnostic work here

UPDATE otlet.production_policy
SET sensitive_evidence_mode = 'redacted'
WHERE name = 'default';
SELECT * FROM otlet.cleanup_policy_state(false);
COMMIT;
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

Contract: `0` (demo prints `invariant_contract=0`). The suite fails closed on expired or NULL leases for `running` and `cancel_requested` jobs, complete receipts without schema pass, sensitive evidence that violates the active storage policy, materializations missing `source_hash`, and error runtime slots. `production_status` and `verify_invariants` name the receipt invariant `complete_receipts_are_schema_validated`; throughput views use `completed_jobs` and `last_batch_completed_jobs`. Step 6 of `docs/semantic-watches.md` anchors the planner vocabulary for `selected_path` / `Planner Selected Path` and `freshness_basis`

Operators query redacted, read-only projections through `otlet.audit_receipt_export`, `otlet.audit_review_export`, `otlet.audit_action_execution_export`, `otlet.audit_eval_label_export`, `otlet.semantic_dependency_audit`, and `otlet.worker_batch_timing_status`. `otlet.redaction_policy_status` lists withheld fields

## Step 4 - Grant Role-Scoped Access

Otlet revokes schema, table, sequence, and function access from `PUBLIC`. The extension owner keeps raw and administrative access. Applications create their own login or group roles, then the extension owner grants one of two bounded capabilities

Create roles through your normal provisioning path. These `NOLOGIN` roles show the grant contract:

```sql
CREATE ROLE app_otlet_auditor NOLOGIN;
CREATE ROLE app_otlet_operator NOLOGIN;

SELECT otlet.grant_auditor_access('app_otlet_auditor'::regrole);
SELECT otlet.grant_operator_access('app_otlet_operator'::regrole);
```

The auditor capability grants these redacted policy and audit views:

- `otlet.redaction_policy_status`
- `otlet.access_policy_status`
- `otlet.audit_receipt_export`
- `otlet.audit_review_export`
- `otlet.audit_action_execution_export`
- `otlet.audit_eval_label_export`
- `otlet.semantic_dependency_audit`
- `otlet.worker_batch_timing_status`

The grant also includes three pure JSON hashing helpers required by `audit_review_export`; those helpers read no database rows. The operator capability includes auditor access plus these functions:

- `otlet.approve_action`
- `otlet.reject_action`
- `otlet.label_action`
- `otlet.correct_action`
- `otlet.dry_run_action`
- `otlet.apply_action`

The six operator functions run as the extension owner with `search_path` fixed to `pg_catalog, otlet, pg_temp`. Operators receive no direct table writes. The owner alone calls `otlet.register_action_target(...)`, `otlet.disable_action_target(...)`, `otlet.export_watch(...)`, and `otlet.import_watch(...)`. Watch exports contain instructions, policies, schemas, source identifiers, and owner-authored candidate SQL, so auditor and operator roles cannot read or import them

An action target must be an ordinary non-partitioned table without RLS, use one primary-key column, and list each writable non-key column. Otlet revalidates that contract during dry run and apply

Raw targets, execution receipts, outputs, source evidence, trace summaries, token traces, worker functions, model registration, watch administration, cleanup, and the grant helpers stay owner-only. Auditors see execution mode, status, hashes, changed-column names, affected-row count, and replay linkage through `otlet.audit_action_execution_export`. They do not see target row values

Check the installed policy:

```sql
SELECT * FROM otlet.access_policy_status;
```

The demo proves the catalog ACLs, eight auditor views, nine operator function grants, seven successful operator paths, and 48 denied paths:

```text
permission_contract=public=0/0/0|auditor=8/3|operator=8/9|definer=8/8|positive=7|denied=48
```

Your application still owns these deployment boundaries:

- add RLS or schema isolation if multiple tenants share the database
- schedule `otlet.cleanup_policy_state(false)` for worker-event, trace-detail, diagnostic evidence, stale materialization, and unreferenced failed/canceled job pruning
- allow action types your application has code to interpret
- decide which users inherit the auditor and operator roles
