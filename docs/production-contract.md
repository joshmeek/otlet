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

`otlet.runtime_capability_status` is the cold declaration for native and registered portable runtimes. It exposes supported options, schema behavior, context limits, cancellation, tracing, GGUF handling, llama.cpp revision and build features, device settings, and admission policy without requiring a receipt. `otlet.runtime_status` remains the observed native state after work runs

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
WHERE runtime_status = 'ready'
  AND slot_state = 'ready'
ORDER BY last_used_at DESC NULLS LAST, model_name
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

Model, task, watch, selection, action-policy, workload-pack, Otlet access-grant, and retention changes require a reason or ticket in the same transaction. The helper uses transaction-local settings, so calling it in autocommit mode does not authorize a later statement:

Otlet treats deterministic task synthesis for direct and queued one-off asks, plus automatic target-generation bumps after contract drift, as runtime bookkeeping. These paths append no administrative event and restore the caller's suppression state. Explicit task changes, target recertification, and workload promotion append events

```sql
BEGIN;
SELECT otlet.set_administrative_change_context(
  reason => 'Raise diagnostic retention for one incident',
  ticket => 'OPS-123'
);

-- Run the administrative statements here

COMMIT;
```

PostgreSQL appends the authenticated actor, active role, operation, prior and resulting `otlet:v1:sha256` identities, reason or ticket, and time. Inserts and deletes use null for the absent side. No-ops and rolled-back work leave no event. Read the hash-only projection as the owner, auditor, or operator:

```sql
SELECT event_id, object_type, object_name, operation,
       actor_name, active_role_name, reason, ticket,
       old_revision_hash, new_revision_hash, changed_at
FROM otlet.audit_administrative_change_export
ORDER BY event_id DESC;
```

Otlet records changes from migration installation forward and leaves earlier history absent. Raw owner `GRANT` and `REVOKE` statements are outside the grant-helper ledger until the planned access-policy lifecycle. The database or extension owner can disable or replace database guards; the planned signed-checkpoint work covers that stronger boundary. Repository demo connections and disposable SQL-only databases supply a generic proof reason. Production sessions should supply a specific transaction-local context

Workload packs are owner-only administrative changes for an existing active watch. `prepare_workload_pack(...)` stores one immutable canonical candidate against the expected configured spec and active workload revision; `apply_workload_pack(...)` rechecks both and changes the task, watch, selection, and action-policy configuration in one transaction. A governed candidate must cite the current promotion decision so Otlet reuses the existing activation gate. `rollback_workload_pack(...)` restores only the exact predecessor of the latest application and records both pack and administrative lineage. Pack status reports configured drift and rollback readiness without creating work

Workload acceptance policy lives outside executable workload revisions. `register_workload_acceptance_contract(...)` pins one immutable declaration to exact candidate and baseline revisions, one full-population or sample rule, a closed future UTC window, a named baseline, and all 11 required threshold categories. The declaration must exist before its observation window begins. Owners must name the current contract hash in each successor declaration, so concurrent or stale edits fail instead of forking the chain. `record_workload_acceptance_exception(...)` and `record_workload_promotion_decision(...)` append attributed, content-addressed events with bounded evidence and exact exception and qualification-run links

These functions declare governance evidence. They do not run an evaluation, infer that a threshold passed, promote a workload revision, or create a job. Otlet accepts a `promote` decision after the caller cites at least one complete qualification run for the same contract, task, baseline, and candidate revisions. Read the owner-only declaration and history through `otlet.workload_acceptance_status` and `otlet.audit_workload_acceptance_event_export`. Metric calculation, shadow execution, and authoritative promotion remain separate contracts

An acceptance contract can opt production outcomes into review with `population.rule.review_sampling`. The declaration sets task, decision-class, and action-free rates from 0 through 1; action-free, decision-class, then task rates take precedence, so a specific zero excludes that stratum. Completion uses a portable SHA-derived bucket and persists selected receipt and output identity before commit. A redacted answer cannot define a class stratum, and task or action-free sampling stores no redacted or unbounded answer. `otlet.review_queue` suppresses the sampled row when a mandatory review path already owns the receipt. Auditors and operators read redacted sampling evidence through `otlet.audit_review_sample_export`. A calibrated reviewer reads sampled work through `otlet.reviewer_review_queue` and calls `label_review_sample(...)` with an explicit `approve` or `correct` outcome. Approval requires visible answer and confidence plus no actions for `none` or exactly one valid matching action; redacted evidence and multi-action outputs require correction. The call atomically creates one pending receipt label and one immutable review event; correction can set `none`, exact retries add nothing, and retention cleanup cannot reopen the sample. Label adjudication, `register_evaluation_case(...)`, qualification, training, and promotion remain separate owner actions

A workload revision opts into delegated review with the exact `task.decision_contract.review_rubric` keys `format`, `instructions`, `minimum_gold_cases`, `maximum_calibration_errors`, and `maximum_review_errors`. The format is `otlet.review_rubric.v1`; instructions are nonblank and at most 32 KiB; minimum gold is 1 through 64; calibration errors are 0 through 63 and must leave at least one correct case; review errors are 0 through 999999. Without this object, review remains owner-only

The owner calls `register_reviewer_calibration(...)` for a login role that already has reviewer access. Cases must be current, qualification-eligible manual corrections from the calibration population, meet the rubric count, use distinct source lineage, and never have been authored, adjudicated, or previously exposed to that reviewer. Otlet also rejects reviewers that can read label, evaluation, sampling, correction, acceptance-population, or derived report surfaces or call the owner-only label, correction, or gold-export RPCs, including access reachable through inherited or `SET ROLE` membership

`otlet.reviewer_calibration_queue` exposes opaque member tokens, the rubric, shaped input, and allowed answer, confidence, and action values. It never exposes case identities, expected answers, correctness, or the running error count. `submit_reviewer_calibration(...)` accepts exact retries, rejects changed answers, and reveals the result only after every member is answered. `otlet.reviewer_calibration_status` reports `pending`, `calibration_threshold_breached`, `calibrated`, `gold_invalid`, `gold_visible`, `rubric_changed`, `review_error_threshold_breached`, or `reviewer_identity_invalid`

Only `calibrated` opens `otlet.reviewer_review_queue`. That queue contains shaped input, storage-redacted output, bounded proposed actions, the rubric, and the response contract, but no raw job, audit, or gold tables. Review events bind the calibration and rubric hashes. The owner may call `record_reviewer_error(review_event_id, reason)` against one immutable calibrated event; once errors exceed the rubric maximum, a later calibration is required. A workload revision with the same rubric preserves authority, while rubric, identity, gold, or visible-gold drift closes it. Calibration creates no jobs, labels, actions, materializations, training, promotion, review-work assignments, or leases

Replay uses a separate owner-only path. `register_evaluation_case(label_id, population_kind, reason)` binds an approved label to its source job, receipt, exact workload revision, expected decision, immutable post-shaping snapshot, and one of `tuning`, `calibration`, `shadow`, or `qualification`. Otlet derives logical source and shaped-snapshot lineage without label or population inputs. Otlet accepts one registration per snapshot, so evidence used for selection cannot enter the qualification population. Cases reject updates and deletes and remain owner-only

`start_replay_evaluation(contract_hash, case_hashes, run_key, reason)` validates one workload acceptance contract, sorts its cases, requires unique cases from one population, and creates paired evaluation jobs for the exact baseline and candidate revisions. Exact retries return the original run; a reused key with different content fails before mutation. Evaluation jobs use the ordinary native or portable claim, lease, attempt, receipt, output, and model-capacity paths, including inactive candidate revisions. Production dedupe, semantic in-flight accounting, receipt, timing, cache, cost, result, selection, review, and trust status ignore evaluation jobs; completion creates no actions, records, or materializations. Native evaluation uses a separate in-memory inference cache and does not update production runtime aggregates

Completion verifies the submitted envelope against its accepted receipt, uses it during the call so storage redaction does not corrupt the comparison, and stores content hashes plus decision, approval, action-type, and bounded mutation diffs. Mutation preview reads the current registered target and records changed-column and before/result hashes without writing it. Read case and run evidence through `otlet.evaluation_case_status`, `otlet.evaluation_replay_status`, and `otlet.audit_evaluation_replay_export`. `otlet.evaluation_exposure_status` reconstructs exact source, scheduled, portable-claim, attempt, and result lineage for models, prompts, thresholds, policies, selection roles, receipts, and attempt indexes. It marks tuning and calibration exposure as selection-influencing. All four views remain owner-only

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

Admission caps cover bulk rows, raw bytes per job, queue depth, queued bytes per model, and total queued bytes. Bulk `run_task` calls enqueue every eligible row or none. Row-watch source triggers never wait for queue capacity; they persist one coalesced dirty identity per watch and subject. Native pre-claim and portable heartbeat reconciliation each retry one due subject per transaction. Rejected admission backs off to the policy cap, while exhausted entries remain visible for owner replay or generation-fenced acknowledgement. Rows enter `otlet.jobs` through `run_task`, durable watch reconciliation, watch refresh, semantic refresh, `ask`, or owner-only replay evaluation; direct inserts are internal/testing-only and bypass admission accounting. `verify_invariants()` returns one row per violation and the demo requires zero violations

Time-based row refresh reuses that reconciliation path. One indexed current deadline per watch revision and subject becomes eligible at the refresh window; no semantic read writes or queues work. Reconciliation rechecks lifecycle, pinned revision, immutable age anchor, current content, existing terminal or active work, and expiry before submission. Paused tasks retain due state without replay, source-change reconciliation supersedes time refresh, and exact-generation acknowledgement suppresses the same deadline without suppressing newer evidence. Job admission records one durable attempt on the deadline so normal terminal-job cleanup cannot reseed it; newer evidence resets the marker. Correction-owned materializations keep their explicit expiry and re-review path. Pair expiry remains fail-closed until an explicit bounded pair refresh

An owner can create one unfinished backfill per active task revision with `create_task_backfill(...)`. Creation stores a capped C-ordered subject manifest and rolls back if the source exceeds the declared cap. `submit_task_backfill_page(...)` accepts the current generation, rereads source input for the next page, and returns its state, new generation, processed-subject count, and queued-job count. `task_backfill_status` reports manifest progress, changed and missing sources, linked job states, rate headroom, and revision currency. Use `set_task_backfill_state(...)` to pause, resume, or cancel the run

Backfill jobs remain deferred until foreground task or watch work adopts them. Claims serve foreground work before a one-job backfill quantum. Cancellation owns deferred jobs from that run and leaves adopted foreground jobs intact. Each page also enforces its jobs-per-minute and outstanding-job limits plus the global queue and input-byte caps

```sql
BEGIN;
SET LOCAL statement_timeout = '5s';

SELECT otlet.create_task_backfill(
  'entity_resolution_task',
  otlet.ensure_active_workload_revision('entity_resolution_task'),
  1000,
  64,
  64,
  64
) AS backfill_id \gset

SELECT * FROM otlet.submit_task_backfill_page(:backfill_id, 0);
SELECT * FROM otlet.task_backfill_status WHERE backfill_id = :backfill_id;
COMMIT;
```

Definition limits are fixed and SQL-visible through `otlet.definition_complexity_limits`; `otlet.definition_complexity_status` reports the same measurements for active workload revisions. Shared guards reject oversized or structurally excessive task, ask, watch, import, policy, preset, source-query, and revision definitions before recursive schema validation, query binding, identity hashing, or prompt construction. `scripts/demo/definition_complexity.sh` checks every limit and public authoring path in one transaction, including direct table writes, and requires the original task, revision, watch, policy, queue, materialization, and backend state after every rejection

Pair-watch creation stores a non-executing candidate `EXPLAIN` plan on the immutable workload revision and rejects invalid or over-cost plans. Every pair execution revalidates dependencies and plan cost, and watch status compares the accepted evidence with a live read-only plan. Otlet rebinds stored SQL against the recorded author path, executes and explains the resolved query under one canonical path with `pg_catalog` first, and restores the caller path. Candidate overflow rejects the operation before jobs or `candidate_removed` reconciliation. Pair refresh requires a caller `statement_timeout` from 1 ms through the policy limit because Postgres cannot arm a timeout from inside the statement already running. See [the workload admission contract](workload-admission.md) for the transaction form and SQL-visible limits

Candidate-set coverage is an optional predeclared field inside the workload acceptance contract's `population.rule`. Build the field before registering the contract; the query remains ordinary application SQL and returns the complete ranked pool as `candidate_rank bigint`, `subject_id text`, and `input jsonb`:

```sql
SELECT otlet.build_candidate_set_coverage_rule(
  $$
    SELECT
      row_number() OVER (ORDER BY score DESC, pair_id) AS candidate_rank,
      pair_id AS subject_id,
      input
    FROM app.entity_pair_candidates
  $$,
  ARRAY['_otlet_mvcc', 'source'],
  20,   -- minimum positive support
  0.95, -- minimum overall coverage
  5,    -- minimum support per source
  0.90, -- minimum coverage per source
  1,    -- maximum positives excluded by the cap
  0.20  -- maximum range in per-source mean normalized rank
);
```

Store the returned object at `population.rule.candidate_coverage`. Non-empty ranks must be unique and contiguous from 1, subjects must be unique, and the full pool is limited to 100,000 rows. An empty result records candidate collapse rather than raising. After the observation window closes, record the report under the normal candidate-query statement timeout:

```sql
BEGIN;
SET LOCAL statement_timeout = '2s';
SELECT otlet.record_candidate_set_coverage(
  'otlet:v1:sha256:contract_hash',
  'Measure the proposed candidate set'
);
COMMIT;
```

Otlet executes the declared full-pool query, binds it to the source-query contract, and requires the target revision's candidate SQL to return the exact rows and inputs in its prefix through `max_candidate_rows`. It derives every current accepted, fresh, noncontradictory `merge_candidate` positive label, rejects duplicate positive subjects or missing string source values, and records full and bounded volume, SQL misses, cap exclusions, overall and per-source coverage, per-source mean normalized rank and range, and both query costs. The report stores hashes and aggregates, not candidate subjects or inputs

Production pair execution is unchanged: `max_candidate_rows` remains an overflow-reject fence and never truncates work. `candidate_set_coverage_status` shows stored evidence and contract, baseline, and label currency without executing application SQL. Promotion reruns both queries, revalidates plan cost, and compares the live full-pool, target-prefix, input, and label manifests with the passing report. Run the promotion or activation call under the same bounded candidate-query `statement_timeout`

Changing candidate SQL, `max_candidate_rows`, output schema, or the pair decision contract requires a current passing report for the exact active-to-candidate revision pair. First activation and one-step rollback remain available. Source-contract repair, model, task instruction, runtime, and unrelated revision changes do not require another candidate-set report. A review-economics contract may still declare and record candidate coverage for an unchanged candidate-set contract so it can measure the full entity-resolution workflow

`entity_resolution_quality_status` joins candidate coverage, the exact replay evaluation report, and review-economics observations only when all three belong to the same acceptance contract and candidate revision. It emits one candidate row per stage with `eligible_count`, numerator, denominator, rate, denominator definition, evidence kind, and all three source report hashes:

| Metric | Numerator | Denominator |
| --- | --- | --- |
| `candidate_recall` | Merge-positive labels inside the bounded candidate set | Eligible merge-positive labels recorded in the coverage report |
| `pair_classification` | Correct decisive answers for decisive gold cases | Decisive terminal candidate results for decisive gold cases |
| `abstention` | Terminal abstaining answers | Terminal candidate results with an observed answer |
| `escalation` | Candidate evaluations with a strong-route receipt | Candidate evaluations with any receipt |
| `reported_reviewer_agreement` | Reviewer-touched outcomes reported accepted | Reviewer-touched outcomes reported accepted, corrected, or rejected |
| `reported_correction` | Reviewer-touched outcomes reported corrected | Reviewer-touched outcomes reported accepted, corrected, or rejected |
| `reported_downstream_merge_outcome` | Successful reported merge outcomes | Reported outcomes for accepted or corrected cases whose approved label expects `merge_candidate` |

Rates are null when their denominator is zero. `eligible_count` keeps missing decisions, reviews, receipts, or downstream observations visible instead of silently shrinking the workflow. `evidence_ready` also requires the current contract, active baseline, passing and current coverage, and currently qualified evaluation labels; historical or failed evidence remains visible with that flag false. Reviewer and downstream rows remain non-authoritative authenticated-role attestations because `merge_candidate` has no Otlet apply path. Otlet does not produce a combined accuracy score

Semantic row and pair status, plan, current-row, predicate, and invariant reads pin one workload revision and use read-only source-contract checks. They do not create temporary views or mark materializations stale, and status views reject a concurrent revision change instead of combining revisions. Detected row-source column-contract drift returns no current matches and a `lookup_fail_closed` plan with no wait, infer, or queue work in read-only transactions; the same contract suspends writable execution checkpoints. During PostgreSQL recovery, CustomScan suppresses wait, infer, and queue work. Otlet does not yet claim physical-standby read support. Run `mark_semantic_schema_drift(...)` from a writable owner maintenance session to persist `schema_drift`; after repairing the source, run `repair_source_query_contract(...)` to promote the revised contract and restore watch triggers and execution

Claimed jobs use `otlet.effective_job_lease_interval(...)`, which covers the task attempt timeout plus 30 seconds of completion grace. The claim function creates a random opaque token each time. Renew, attempt, complete, fail, and worker-owned cancel calls must present the token while its lease is live. Reclaim replaces the token, so an expired or displaced worker cannot add trusted state. Exact terminal retries return the existing result; PostgreSQL rejects a retry that changes the terminal request. `model_selection_policy_status.effective_job_lease_interval` exposes the derived interval

Requester cancellation is a separate operation. `request_job_cancellation` marks live work for the owner to stop and can cancel queued work before it starts. `cancel_job` is the fenced terminal write and requires the live claim token

PostgreSQL validates accepted results again before it stores a receipt, output, or action. The SQL-installable schema subset supports object, array, string, number, integer, boolean, and null types; `enum`; `const`; required and bounded properties; string, numeric, and array bounds; one `items` schema; and boolean `additionalProperties`. `json_schema_support_report(...)` names every unsupported keyword or malformed construct, and task registration rejects an unsupported schema

Completion parses the raw envelope and requires it to match the submitted output and actions. PostgreSQL recomputes SHA-256 identities for the task, input, source snapshot, prompt, schema, registered model, effective runtime options, raw output, structured output, and actions. It rejects mismatched worker hashes, malformed output, schema violations, and stale MVCC-backed source data. Worker-submitted validation status is diagnostic input only; the receipt stores PostgreSQL's result. Existing action contracts recheck workflow policy and target allowlists, so unauthorized proposals remain rejected evidence and cannot become records

Portable protocol `otlet.portable.worker.v1` uses exact-version compatibility and an owner-registered runtime identity bound to one database role. `grant_portable_worker_access(...)` grants that dedicated role one compatibility view and eight fixed-search-path `SECURITY DEFINER` RPCs for startup, heartbeat, claim, renewal, attempt, completion, failure, and cancellation. It grants no source or Otlet table access

Application callers use `application_submit_task_subject(...)` to queue one subject from a configured task with an active revision. The fixed-path function reuses the task's bound source query, immutable revision, input-relation checks, plan preflight, and queue limits. PostgreSQL stores the authenticated `session_user` role as owner and authenticated actor, plus the active `SET ROLE` role in a distinct provenance field

Callers may supply a nonblank request key of at most 256 bytes. The key is scoped to the authenticated owner and binds a PostgreSQL-authored hash of the submit operation, task, and subject. Repeating the same owner, key, and payload returns the prior job even after source or revision drift. Reusing the key for another task or subject fails before mutation. Without a matching keyed job, submission returns `0` when the source has no matching subject, admission rejects the input, or the same input already has live work under that revision

`application_retry_job(...)` lets an owner-granted operator retry a terminal application job. `original_snapshot` reuses the stored input and original revision but fails after that revision stops being active. `latest_source` reads current source under the current revision. Both modes preserve the application's owner, record the operator's authenticated login and active role, and link the new job to its original

Otlet assigns each failed or canceled job and each failed, rejected, or canceled receipt one code from the immutable `otlet.failure.v1` taxonomy. `failure_retry_status` joins the code to its execution path, stage, retryability, owner action, recommended existing retry mode, raw-detail availability, and application retry lineage. Owners, auditors, and operators can read this redacted status. The database owner alone can read raw job and receipt errors. Classification does not quarantine jobs or artifacts

`application_job_status(...)` returns lifecycle timestamps, status, accepted structured output, stable failure code, stage, retryability, owner action, recommended retry mode, raw-detail visibility, and retry lineage for a job owned by that authenticated login. It never returns input, raw error detail, candidate or raw output, receipts, traces, actions, model details, or claim state. `application_cancel_job(...)` applies the existing queued and live cancellation contract after the same ownership check. Commit queued native or portable work before expecting a worker to see it

Existing cleanup can remove unreferenced failed or canceled jobs and sets a surviving retry's parent link to null when it removes that parent. Request-key idempotency and retry lineage last as long as those job rows. The current cleanup base retains complete jobs

Tasks own one operational state shared by any attached watch. `active` tasks hold a revision head. `set_task_lifecycle(..., 'paused', expected_revision_hash)` requires an exact active pin and no leased work, removes the head, and blocks new admission, claims, semantic reads, action authority, reconciliation retries, and watch-registry reconfiguration. Existing queued jobs remain queued. Resume restores the same revision and does not promote task definitions captured while paused. A task definition write that meets a concurrent lifecycle lock fails with a retry error before waiting across the task-row lock. Action target registration and workflow policy changes take the policy lock before any source-table fence, so lifecycle transitions serialize with authority changes. Operators use the existing native or portable worker controls to drain leases before pause

Retirement is terminal and requires a paused task with no queued, running, or cancellation-requested jobs and no watch reconciliation backlog. PostgreSQL locks the pinned source relation identities before the final check, so a concurrent source change either remains blocked behind retirement or commits a backlog that blocks retirement. Resume and reconcile, or acknowledge the exact generation, before retrying. Retirement retains the task, immutable revisions, terminal jobs, receipts, outputs, actions, records, labels, reviews, and materializations as the archive. `task_lifecycle_status` reports the pin, configured drift, dependency counts, source identity drift, transition readiness, and watch-deletion blocker. `drop_watch(watch_name, expected_retired_revision_hash)` removes only the retired watch registry, indexes, reconciliation, and Otlet-owned source triggers at the exact pin. A rename, schema move, or reused relation name reports `source_relation_identity_drift`; restore the pinned name and identity before retirement or deletion. A removed application-owned source remains safe to clean up. Deletion never removes a surviving source table or the task archive and does not make the retired name reusable

Portable row watches use `create_watch(..., kind => 'row')` with `mark_stale_and_enqueue`. A source change marks prior state stale and persists the newest source identity in `watch_reconciliation`; a running worker heartbeat replays one due entry after commit. Source deletion resolves without inference. Pair watches keep bounded candidate preflight and explicit atomic `refresh_semantic_join_index(...)` under the caller statement timeout. `portable_complete_job(...)` stores the trusted output and semantic materialization in one transaction. SQL-only installations expose row and pair reads, predicates, plans, status, watch reconciliation, export, cleanup, and audit functions. Canceled work does not materialize

`portable_claim_jobs(...)` requires the worker's current Linux VmRSS and default llama thread count. PostgreSQL compares the registered runtime contract and artifact snapshot with each immutable workload revision before it changes attempts, tokens, leases, or cursor state. It skips work with an unknown option, enabled inference cache or generation trace, invalid resource limit, artifact mismatch, or RSS overage. Compatible claims return the shaped input, database-built prompt and hash, selected model role, normalized execution settings, immutable effective `max_attempt_ms`, evidence limits, and a live claim token without source-table authority

PostgreSQL stores a database-authored `runtime_options_status` on each portable claim with the requested, honored, defaulted, rejected, effective, and runtime-envelope fields. It copies that status into every linked receipt and overwrites a worker-supplied value. Each registered worker uses one snapshotted model artifact. `portable_start_worker(...)` returns one server-generated incarnation nonce and stores only its SHA-256 hash on the worker, its claims, and linked receipts. Starting a replacement process for the same registered worker immediately fences the prior incarnation and its live claims; re-registration clears the current incarnation. PostgreSQL validates cheap results against the selection policy and requeues rejected or schema-invalid attempts for the strong model in the same transaction. PostgreSQL keeps the job ID, retry budget, and receipt history. A cheap runtime failure with no model output remains terminal, matching the native worker. The reference worker carries the same role, worker ID, protocol version, runtime identity hash, and process incarnation nonce on all seven post-start RPCs. PostgreSQL rejects a stale supplied nonce before mutation. A heartbeat with no nonce is the read-only preflight exception. Renewal, attempt, completion, failure, and cancellation also require the job ID and claim token

The owner sets a worker to `running`, `paused`, or `draining`. The heartbeat returns that desired state with the snapshotted model digest and byte size, records process and model health, and does not grant owner controls to the worker role. Pause and drain block new claims. The reference worker starts a monotonic deadline before the claim RPC, uses the database-issued duration for prompt decode and generation, and stops renewal when that deadline arrives. PostgreSQL uses `clock_timestamp()` at claim time and refuses renewal after the same immutable budget; a renewal that crosses the deadline rolls back. Timeout uses the native `attempt_timeout` job error, receipt selection reason, failed schema status, and trace stop reason. The live lease retains completion grace for a result that finished before the worker deadline. Cancellation and pre-deadline claim loss remain authoritative

`portable_worker_status`, `portable_claim_status`, and `portable_receipt_status` expose the registered artifact and runtime contract, current RSS, normalized option status, desired and reported state, model health, queue depth, claim health, deadlines, terminal state, receipt attribution, and incarnation hashes without exposing raw nonces or claim tokens. Exact duplicate terminal delivery returns the prior result; PostgreSQL rejects a changed retry

The [reference external worker](../crates/otlet_worker/README.md) uses ordinary `psql` connections and a local llama.cpp runtime. It rejects symlink artifacts, hashes one open regular GGUF, loads llama.cpp through that descriptor, and rejects path, inode, or content changes before accepting a result. Keep the GGUF in a deployment-owned read-only mount. The worker loads the model once at startup, fixes llama.cpp to a 4,096-token context with 512/128 batches and zero GPU layers, applies the normalized decode and batch thread counts, and samples `/proc/self/status` VmRSS before claim, before inference, and after inference. A missing sample or budget overage fails closed. One shared process slot permits one `psql` child at a time. Fixed connect, query, renewal, and terminal deadlines become PostgreSQL statement and lock timeouts; request, stdout, stderr, and parsed-result bytes have fixed caps. A timed-out child is killed and reaped. The worker rejects a connection URI containing a password, passes the passwordless URI to `psql`, and leaves credentials to libpq sources such as `PGPASSFILE`. No credential appears in process arguments. The worker keeps inference caching and generation tracing off. It submits accepted output through `portable_complete_job(...)` and claimed failures through `portable_fail_job(...)`. Its one-line JSON logs carry identifiers and reason codes without llama.cpp diagnostics, prompts, source evidence, or connection data. It has no HTTP model client. The SQL-only installer creates no extension object or C-language function. It applies the portable migration manifest in dependency order and skips recorded migrations on later runs

Before any portable claim, deployment preflight connects through libpq, authenticates the registered role, checks the eight RPC grants and active protocol version, verifies the runtime and model allowlists, confirms TLS is active when required, opens and hashes the local GGUF with no symlink following, and holds that descriptor through startup and model load. `otlet_worker --preflight` runs the same checks and exits without starting a process incarnation, loading the model, or claiming work. Use `sslmode=verify-full` with a trusted CA and enforce model-provider egress denial in the deployment network

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
SELECT otlet.set_administrative_change_context(
  'Bounded diagnostic evidence window'
);
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

Tasks can opt into evidence-linked decisions by declaring an `evidence` array in the output schema and asking actions to return `body.evidence`. Each entry is a JSON path written as an array of text segments. A one-segment path cites a top-level field

```json
{
  "output": {
    "decision": "review",
    "evidence": [["row", "email"]]
  },
  "actions": [{
    "type": "review_flag",
    "body": {
      "reason": "email needs review",
      "evidence": [["row", "email"]]
    }
  }]
}
```

PostgreSQL resolves every path against the pinned shaped job input before the receipt, output, or action can commit. The first segment must appear in the revision's `input_shaping.source_fields`, including when shaping adds another derived top-level field. The pinned workload revision must declare `otlet_decision_evidence_v1`, so an upgrade cannot change citation acceptance under an old revision hash. Each output or action may cite at most 32 paths, each path may contain at most 16 nonempty segments of 128 bytes each, and one result may store at most 128 links. Array offsets use canonical nonnegative decimal text such as `0` or `12`. Repeated links collapse to one receipt entry

`otlet.audit_decision_evidence_export` exposes the output or action target, canonical path, and PostgreSQL-derived `otlet:v1:sha256` value hash. It does not expose the referenced value or copy the shaped snapshot

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
BEGIN;
SELECT otlet.set_administrative_change_context(
  'Create the redacted review task'
);
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
COMMIT;
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

Auditors and operators query redacted, read-only projections through `otlet.audit_receipt_export`, `otlet.audit_review_sample_export`, `otlet.audit_review_export`, `otlet.audit_review_event_export`, `otlet.audit_reviewer_calibration_export`, `otlet.audit_action_execution_export`, `otlet.audit_eval_label_export`, `otlet.audit_administrative_change_export`, `otlet.audit_decision_evidence_export`, `otlet.semantic_dependency_audit`, `otlet.operational_event_log`, `otlet.worker_batch_timing_status`, and `otlet.failure_retry_status`. `otlet.redaction_policy_status` lists withheld evidence for the audit exports. `otlet.failure_retry_status` exposes whether raw error detail exists without exposing the detail

## Step 4 - Grant Role-Scoped Access

Otlet revokes schema, table, sequence, and function access from `PUBLIC`. The extension owner keeps raw and administrative access. Applications create their own login or group roles, then the extension owner grants one of four bounded capabilities

Create roles through your normal provisioning path. These `NOLOGIN` roles show the grant contract:

```sql
BEGIN;
SELECT otlet.set_administrative_change_context(
  'Grant the application and review capabilities',
  'ACCESS-42'
);
CREATE ROLE app_otlet_auditor NOLOGIN;
CREATE ROLE app_otlet_operator NOLOGIN;
CREATE ROLE app_otlet_reviewer NOLOGIN;
CREATE ROLE app_otlet_application NOLOGIN;

SELECT otlet.grant_auditor_access('app_otlet_auditor'::regrole);
SELECT otlet.grant_operator_access('app_otlet_operator'::regrole);
SELECT otlet.grant_reviewer_access('app_otlet_reviewer'::regrole);
SELECT otlet.grant_application_access('app_otlet_application'::regrole);
COMMIT;
```

The application capability grants three functions: `application_submit_task_subject(...)`, `application_job_status(...)`, and `application_cancel_job(...)`. Login roles may inherit one shared capability role, but job ownership remains the authenticated `session_user`; PostgreSQL records the active `SET ROLE` value as invocation provenance and leaves ownership unchanged. The grant can invoke every active task in the database, so grant it to logins allowed to use that full task set. The capability grants no direct source or Otlet table access, task, model, or watch administration, review or apply authority, worker RPCs, receipt, trace, or cleanup views, retry authority, or further grant authority

The auditor capability grants read-only access to these redacted policy and audit surfaces:

- `otlet.redaction_policy_status`
- `otlet.access_policy_status`
- `otlet.audit_receipt_export`
- `otlet.audit_review_sample_export`
- `otlet.audit_review_export`
- `otlet.audit_review_event_export`
- `otlet.audit_reviewer_calibration_export`
- `otlet.audit_action_execution_export`
- `otlet.audit_eval_label_export`
- `otlet.audit_administrative_change_export`
- `otlet.audit_semantic_correction_export`
- `otlet.audit_decision_evidence_export`
- `otlet.action_workflow_policy_status`
- `otlet.semantic_dependency_audit`
- `otlet.operational_event_log`
- `otlet.worker_batch_timing_status`
- `otlet.runtime_capability_status`
- `otlet.portable_protocol_status`
- `otlet.portable_worker_status`
- `otlet.portable_claim_status`
- `otlet.portable_receipt_status`
- `otlet.failure_taxonomy`
- `otlet.failure_retry_status`

The grant also includes the pure JSON hashing helpers required by `audit_review_export`, the native capability reader used by `runtime_capability_status`, the task-scoped entity-graph and semantic-correction status readers, and the calibration-state reader. The operator capability includes auditor access plus these functions:

- `otlet.dry_run_action`
- `otlet.apply_action`
- `otlet.application_retry_job`

The reviewer capability grants `SELECT` only on `otlet.reviewer_review_queue`, `otlet.reviewer_calibration_queue`, and `otlet.reviewer_calibration_status`, plus these decision RPCs:

- `otlet.approve_action`
- `otlet.reject_action`
- `otlet.reviewer_correct_action`
- `otlet.defer_action`
- `otlet.abstain_review`
- `otlet.approve_semantic_correction`
- `otlet.label_review_sample`
- `otlet.submit_reviewer_calibration`

The reviewer grant also includes three fixed-path queue and state helpers. `reviewer_correct_action(...)` accepts only a declared response action type or `none`, then returns the new label and immutable review-event IDs needed for semantic-correction approval without exposing either raw table. The three operator RPCs, eight reviewer RPCs, and reviewer helpers run as the extension owner with `search_path` fixed to `pg_catalog, otlet, pg_temp`. The retry RPC preserves the original application's job owner while recording the operator login and active role. Review RPCs require a current calibration for the authenticated login, even under `SET ROLE`. Operators and reviewers receive no direct table writes. `label_action(...)` and the unbounded `correct_action(...)` stay owner-only. The owner alone registers targets and workflow policies, disables them, and imports or exports watches. Watch exports contain instructions, policies, schemas, source identifiers, and owner-authored candidate SQL, so delegated roles cannot read or import them

The SQL-only install exposes the same operator and reviewer grants through PostgreSQL. The portable worker permission sweep leaves all other Otlet functions and tables closed unless the owner grants them

Approval, rejection, correction, deferral, abstention, and semantic-correction approval append immutable rows to `otlet.review_events`. Otlet derives `reviewer_identity` from `session_user` and `reviewer_role` from the active `SET ROLE` state; none of the review functions accepts either value from the caller. Each event snapshots its reason, timestamp, source freshness, reviewer rubric and calibration hashes, and links to the job, action or output, receipt, model artifact, prompt, schema, runtime, and output identities

`otlet.defer_action(...)` leaves the action in the review queue. `otlet.abstain_review(...)` records the final review of an abstention or an output rejected without an action and removes that item from the queue. Inspect the append-only audit projection without raw source rows:

```sql
SELECT outcome, reviewer_identity, reviewer_role, reason,
       source_freshness, action_id, output_id, receipt_id,
       model_name, prompt_hash, output_schema_hash,
       reviewer_rubric_hash, reviewer_calibration_hash, reviewed_at
FROM otlet.audit_review_event_export
ORDER BY review_event_id;
```

An action target must be an ordinary non-partitioned table without RLS, use one primary-key column, and list each writable non-key column. A row-watch task must also allow `update_row` and bind that action to the target with `otlet.register_action_workflow_policy(...)`. The policy starts recommendation-only and unevaluated unless the owner marks it `bounded_mutation` and `evaluated`. Otlet snapshots the task, target, source namespace, and authority hashes, then revalidates them during dry run and apply

Raw targets, execution receipts, outputs, source evidence, trace summaries, token traces, worker functions, model registration, watch administration, cleanup, and the grant helpers stay owner-only. Auditors see execution mode, status, hashes, changed-column names, affected-row count, and replay linkage through `otlet.audit_action_execution_export`. They do not see target row values

Check the installed policy:

```sql
SELECT * FROM otlet.access_policy_status;
SELECT * FROM otlet.application_access_policy_status;
```

The demo proves the catalog ACLs, 23 auditor relations and 24 function grants, 23 operator relations and 27 function grants, three reviewer relations and 11 function grants, three operator RPCs, eight reviewer RPCs, 37 exact security-definer functions, three application RPCs, eight portable RPCs, seven positive delegated paths, and 112 denied paths. The calibrated reviewer proves all five review outcomes:

```text
review_provenance_contract=true|true|true|true|true|true|true|true|true|true|true
permission_contract=public=0/0/0|auditor=23/24|operator=23/27|reviewer=3/11|definer=37/37|application=3/3/3|operator_rpc=3/3/3|reviewer_rpc=8/8/8|portable=8/8/8|positive=7|denied=112
```

Your application still owns these deployment boundaries:

- add RLS or schema isolation if multiple tenants share the database
- schedule `otlet.cleanup_policy_state(false)` for worker-event, trace-detail, diagnostic evidence, stale materialization, and unreferenced failed/canceled job pruning
- allow action types your application has code to interpret
- decide which users inherit the auditor, operator, and reviewer roles, keeping reviewer logins away from gold access
