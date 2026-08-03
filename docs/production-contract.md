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
SELECT 'runtime_status_contract=' ||
       runtime_status || '|' ||
       slot_state || '|' ||
       COALESCE(tokens_per_second::text, '') || '|' ||
       (COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0))::text || '|' ||
       (COALESCE(inference_cache_max_entries, 0) > 0)::text || '|' ||
       (COALESCE(inference_cache_max_bytes, 0) > 0)::text || '|' ||
       COALESCE(inference_cache_last_eviction_reason, '') || '|' ||
       COALESCE(worker_memory_sample_policy, '') AS runtime_status_contract
FROM otlet.runtime_status
WHERE model_name = 'qwen3_1_7b'
LIMIT 1;
```

Representative output:

```text
runtime_status_contract=ready|ready|37.78|true|true|true|none|linux_proc_self_and_optional_cgroup_v2_memory_pressure_v1
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

The production policy row and status views expose SQL state under `otlet`: `production_policy_status`, `production_status`, `model_queue_status`, `worker_throughput_status`, and `cleanup_policy_state(true)`. Cross-task batch entries expose every claimed task through `task_names`

Native and portable claims share the task-cursor ring. Within each ring segment and task, expired claims rank before queued work, reclaim replaces the claim token, cancellation state survives reclaim, and model residency does not change the order

`max_active_jobs` caps live claimed leases per model across native claims, portable claims, and infer-now. A `running` or `cancel_requested` job consumes one slot while `leased_until >= now()`; an expired or null lease consumes none. Claims stop at the smaller of the requested batch and the remaining slots. Claims, infer-now admission, and renewal share the queue-admission fence. Otlet locks the lease row before it checks wall time and rejects a renewal if its lease expired while waiting. `model_queue_status` and `worker_throughput_status` expose `active_claimed_jobs` and `available_active_job_slots`, and `verify_invariants()` reports `active_claimed_jobs_within_model_cap`

Native batches contain only claims with the same immutable lease horizon. Before each direct, cheap, or deferred strong attempt, the worker locks and validates every claim it still holds, then renews the full set in one transaction. The worker stops the batch without a partial renewal when any claim is stale. The worker renews the current token before Otlet records `job_started` or touches runtime state. The Docker test expires the old visible deadlines while the worker holds renewal locks; a second claimer and the sweeper return zero without changing attempts or ownership, and each job receives one start event and one receipt

```text
claimed_batch_pre_contract=4|0|0|1|2
claimed_batch_lease_contract=0|0|4|true|true|true|true|true|true
```

The resident worker can preload one registered local model and context at startup. The default is unset. Configure the model, then restart the Postgres worker process:

```sql
UPDATE otlet.production_policy
SET preload_model_name = 'qwen35_4b'
WHERE name = 'default';
```

Preload applies `default_runtime_options`, including the default 8 GiB `max_worker_rss_bytes`, and uses the normal artifact, fingerprint, memory, cgroup, and RSS admission checks. Set `OTLET_MAX_WORKER_RSS_BYTES` during setup or update the policy to override it; an explicit `0` disables RSS enforcement. Preload creates no job or receipt. Inspect the ready slot in `otlet.runtime_status` and the latest `model_preload_succeeded` or `model_preload_failed` row in `otlet.worker_events`. Set `preload_model_name = NULL` and restart to restore the cold default

Admission caps cover bulk rows, raw bytes per job, queue depth, queued bytes per model, and total queued bytes. Bulk `run_task` calls enqueue every eligible row or none. Single-subject watch triggers return without waiting when capacity is unavailable. Rows enter `otlet.jobs` through `run_task`, watch refresh, semantic refresh, or `ask`; direct inserts are internal/testing-only and bypass admission accounting. `verify_invariants()` returns one row per violation and the demo requires zero violations

Pair-watch creation stores a non-executing candidate `EXPLAIN` plan on the immutable workload revision and rejects invalid or over-cost plans. Every pair execution revalidates dependencies and plan cost, and watch status compares the accepted evidence with a live read-only plan. Candidate overflow rejects the operation before jobs or `candidate_removed` reconciliation. Pair refresh requires a caller `statement_timeout` from 1 ms through the policy limit because Postgres cannot arm a timeout from inside the statement already running. See [the workload admission contract](workload-admission.md) for the transaction form and SQL-visible limits

Claimed jobs use `otlet.effective_job_lease_interval(...)`, which covers the task attempt timeout plus 30 seconds of completion grace. The claim function creates a random opaque token each time. Renew, attempt, complete, fail, and worker-owned cancel calls must present the token while its lease is live. Reclaim replaces the token, so an expired or displaced worker cannot add trusted state. Exact terminal retries return the existing result; PostgreSQL rejects a retry that changes the terminal request. `model_selection_policy_status.effective_job_lease_interval` exposes the derived interval

Requester cancellation is a separate operation. `request_job_cancellation` marks live work for the owner to stop and can cancel queued work before it starts. `cancel_job` is the fenced terminal write and requires the live claim token

PostgreSQL validates accepted results again before it stores a receipt, output, or action. The SQL-installable schema subset supports object, array, string, number, integer, boolean, and null types; `enum`; `const`; required and bounded properties; string, numeric, and array bounds; one `items` schema; and boolean `additionalProperties`. `json_schema_support_report(...)` names every unsupported keyword or malformed construct, and task registration rejects an unsupported schema

Completion parses the raw envelope and requires it to match the submitted output and actions. PostgreSQL recomputes SHA-256 identities for the task, input, source snapshot, prompt, schema, registered model, effective runtime options, raw output, structured output, and actions. It rejects mismatched worker hashes, malformed output, schema violations, and stale MVCC-backed source data. Worker-submitted validation status is diagnostic input only; the receipt stores PostgreSQL's result. Existing action contracts recheck workflow policy and target allowlists, so unauthorized proposals remain rejected evidence and cannot become records

Portable protocol `otlet.portable.worker.v1` uses exact-version compatibility and an owner-registered runtime identity bound to one database role. `grant_portable_worker_access(...)` grants that dedicated role one compatibility view and seven fixed-search-path `SECURITY DEFINER` RPCs for heartbeat, claim, renewal, attempt, completion, failure, and cancellation. It grants no source or Otlet table access

Portable callers use `enqueue_ask(...)` for one-off inference. Commit the transaction, then read status or trusted output from `otlet.runs` with the returned job ID. Queue rejection returns `0`; synchronous `otlet.ask(...)` remains native-only because an external worker cannot see uncommitted work

Portable row watches use `create_watch(..., kind => 'row')` with `mark_stale_and_enqueue`. Pair watches use bounded candidate preflight and `refresh_semantic_join_index(...)`. PostgreSQL marks row or pair materializations stale when source data changes. The external worker sees committed work. `portable_complete_job(...)` stores the trusted output and semantic materialization in one transaction. SQL-only installations expose the row and pair read, predicate, plan, status, export, cleanup, and audit functions. PostgreSQL reconciles current results after deletes; canceled work does not materialize

`portable_claim_jobs(...)` returns the shaped input snapshot, database-built prompt and prompt hash, task contract, selected model role, registered model policy, effective runtime options, evidence limits including the immutable effective `max_attempt_ms`, a live claim token, and no source-table authority. Each registered worker uses one model and cannot claim work for another artifact. PostgreSQL validates cheap results against the selection policy and requeues rejected or schema-invalid attempts for the strong model in the same transaction. PostgreSQL keeps the job ID, retry budget, and receipt history. A cheap runtime failure with no model output remains terminal, matching the native worker. Every later RPC requires the same role, worker ID, protocol version, runtime identity hash, job ID, and claim token

The owner sets a worker to `running`, `paused`, or `draining`. The heartbeat returns that desired state, records process and model health, and does not grant owner controls to the worker role. Pause and drain block new claims. The reference worker starts a monotonic deadline before the claim RPC, uses the database-issued duration for prompt decode and generation, and stops renewal when that deadline arrives. PostgreSQL uses `clock_timestamp()` at claim time and refuses renewal after the same immutable budget; a renewal that crosses the deadline rolls back. Timeout uses the native `attempt_timeout` job error, receipt selection reason, failed schema status, and trace stop reason. The live lease retains completion grace for a result that finished before the worker deadline. Cancellation and pre-deadline claim loss remain authoritative

`portable_worker_status`, `portable_claim_status`, and `portable_receipt_status` expose identity, desired and reported state, model health, queue depth, live and expired claims, lease and attempt deadlines, terminal state, and receipt attribution without exposing claim tokens. Exact duplicate terminal delivery returns the prior result; PostgreSQL rejects a changed retry

The [reference external worker](../crates/otlet_worker/README.md) uses ordinary `psql` connections and a local llama.cpp runtime. It verifies the configured GGUF SHA-256 before loading, compares each claim with the registered model identity, submits accepted output through `portable_complete_job(...)`, and submits claimed failures through `portable_fail_job(...)`. Its one-line JSON logs carry identifiers and reason codes without llama.cpp diagnostics, prompts, or source evidence. It has no HTTP model client. The SQL-only installer creates no extension object or C-language function. It applies the portable migration manifest in dependency order and skips recorded migrations on later runs

Before any portable claim, deployment preflight connects through libpq, authenticates the registered role, checks the seven RPC grants and active protocol version, verifies the runtime and model allowlists, confirms TLS is active when required, hashes the local GGUF, and probes the runtime directory. `otlet_worker --preflight` runs the same checks and exits without loading the model or claiming work. Use `sslmode=verify-full` with a trusted CA and enforce model-provider egress denial in the deployment network

Otlet debounces suppressed queue-admission events per task and reason for one minute, so a full queue stays visible without flooding `worker_events`. `production_status` exposes `semantic_materialization_failed_events` and `semantic_materialization_last_failed_at`. Nonzero `max_worker_rss_bytes` budgets require Linux RSS, total-memory, and available-memory samples. A cache miss also requires artifact metadata and a no-allocation llama.cpp projection; missing evidence or insufficient headroom rejects the load before tensor allocation. Cleanup can prune old failed or canceled jobs after outputs, actions, eval labels, and receipts no longer reference them

The resident worker attaches to `OTLET_DATABASE`, which defaults to `postgres`. One PostgreSQL cluster runs Otlet against one database because cross-database worker registration requires separate shared-memory and latch routing. Setup refuses an Otlet installation in a second database and checks the target database, extension files, model files, schema access, runtime role, and memory budget before enabling the worker

Before claiming jobs, the worker validates `default_runtime_options`. It records `worker_started` with the database, role, and memory budget on success. Invalid policy records `worker_startup_failed`, leaves queued jobs untouched, and retries the preflight at a bounded interval

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

Contract output:

```text
production_policy_contract=default|refresh_then_fail_closed|3|300000|8|redacted
production_status_contract=true|true|true|true
model_queue_status_contract=queue_accepting|0|0|0|8|8
throughput_status_contract=queue_accepting|0|0|4|4|0|0|8
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

Every task also has an explicit top-level source-field allowlist in `input_shaping.source_fields`. A missing allowlist becomes an empty array, so Otlet admits only `{}` until the owner names fields. `create_task`, `run_task`, `admit_task_input`, watch refresh, direct job insertion, and claim all enforce the same contract. Row watches store their selected column list at creation; a later table column does not enter model input by accident

```sql
SELECT name, input_shaping -> 'source_fields' AS source_fields
FROM otlet.tasks
ORDER BY name;
```

The production policy bounds each stored evidence family before a write can commit:

```sql
SELECT max_raw_output_bytes,
       max_structured_output_bytes,
       max_actions_per_job,
       max_action_bytes,
       max_trace_bytes,
       max_error_bytes,
       max_event_message_bytes,
       max_event_detail_bytes,
       max_receipt_bytes
FROM otlet.production_policy_status;
```

Oversized evidence raises an error before output, action, event, or receipt storage. Use `decision_contract.redact_output_fields` and `decision_contract.redact_action_fields` for recursive structured redaction. `identity_fields` names workload-specific identifiers that redaction must preserve; Otlet also protects its built-in action and control identifiers

```sql
SELECT otlet.create_task(
  task_name => 'redacted_review',
  input_query => NULL,
  instruction => 'Return a review decision',
  output_schema => '{"type":"object"}',
  model_name => 'qwen3_1_7b',
  input_shaping => '{"source_fields":["case_id","note"]}',
  decision_contract => '{
    "redact_output_fields":["note"],
    "redact_action_fields":["reason"],
    "identity_fields":["case_id"]
  }'
);
```

`otlet.operational_event_log` exposes event type, task and model identity, status, reason, counts, timing, byte limits, and redaction state without the raw event message or detail document. Auditor exports add structured and action redaction state without exposing job input, source rows, raw model text, or full traces

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
performance_ratio_contract=40|49|1.225|16548|413.700
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

Operators query redacted, read-only projections through `otlet.audit_receipt_export`, `otlet.audit_review_export`, `otlet.audit_review_event_export`, `otlet.audit_action_execution_export`, `otlet.audit_eval_label_export`, `otlet.semantic_dependency_audit`, `otlet.operational_event_log`, and `otlet.worker_batch_timing_status`. `otlet.redaction_policy_status` lists withheld fields

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
- `otlet.audit_review_event_export`
- `otlet.audit_action_execution_export`
- `otlet.audit_eval_label_export`
- `otlet.action_workflow_policy_status`
- `otlet.semantic_dependency_audit`
- `otlet.operational_event_log`
- `otlet.worker_batch_timing_status`

The grant also includes three pure JSON hashing helpers required by `audit_review_export`; those helpers read no database rows. The operator capability includes auditor access plus these functions:

- `otlet.approve_action`
- `otlet.reject_action`
- `otlet.label_action`
- `otlet.correct_action`
- `otlet.defer_action`
- `otlet.abstain_review`
- `otlet.dry_run_action`
- `otlet.apply_action`

The eight operator functions run as the extension owner with `search_path` fixed to `pg_catalog, otlet, pg_temp`. Operators receive no direct table writes. The owner alone registers targets and workflow policies, disables them, and imports or exports watches. Watch exports contain instructions, policies, schemas, source identifiers, and owner-authored candidate SQL, so auditor and operator roles cannot read or import them

Approval, rejection, correction, deferral, and abstention append immutable rows to `otlet.review_events`. Otlet derives `reviewer_identity` from `session_user` and `reviewer_role` from the active `SET ROLE` state; none of the review functions accepts either value from the caller. Each event snapshots its reason, timestamp, source freshness, and links to the job, action or output, receipt, model artifact, prompt, schema, runtime, and output identities

`otlet.defer_action(...)` leaves the action in the review queue. `otlet.abstain_review(...)` records the final review of an abstention or an output rejected without an action and removes that item from the queue. Inspect the append-only audit projection without raw source rows:

```sql
SELECT outcome, reviewer_identity, reviewer_role, reason,
       source_freshness, action_id, output_id, receipt_id,
       model_name, prompt_hash, output_schema_hash, reviewed_at
FROM otlet.audit_review_event_export
ORDER BY review_event_id;
```

An action target must be an ordinary non-partitioned table without RLS, use one primary-key column, and list each writable non-key column. A row-watch task must also allow `update_row` and bind that action to the target with `otlet.register_action_workflow_policy(...)`. The policy starts recommendation-only and unevaluated unless the owner marks it `bounded_mutation` and `evaluated`. Otlet snapshots the task, target, source namespace, and authority hashes, then revalidates them during dry run and apply

Raw targets, execution receipts, outputs, source evidence, trace summaries, token traces, worker functions, model registration, watch administration, cleanup, and the grant helpers stay owner-only. Auditors see execution mode, status, hashes, changed-column names, affected-row count, and replay linkage through `otlet.audit_action_execution_export`. They do not see target row values

Check the installed policy:

```sql
SELECT * FROM otlet.access_policy_status;
```

The demo proves the catalog ACLs, 15 auditor views, 11 operator function grants, seven existing operator paths, 18 exact security-definer functions, seven portable RPCs, and 61 denied paths. The delegated operator role proves all five review outcomes:

```text
review_provenance_contract=true|true|true|true|true|true|true|true|true|true|true
permission_contract=public=0/0/0|auditor=15/3|operator=15/11|definer=18/18|portable=7/7/7|positive=7|denied=61
```

Your application still owns these deployment boundaries:

- add RLS or schema isolation if multiple tenants share the database
- schedule `otlet.cleanup_policy_state(false)` for worker-event, trace-detail, diagnostic evidence, stale materialization, and unreferenced failed/canceled job pruning
- allow action types your application has code to interpret
- decide which users inherit the auditor and operator roles
