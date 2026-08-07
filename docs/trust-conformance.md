# Trust Conformance

Otlet treats source text, imported configuration, identifiers, model files, model output, and worker claims as untrusted input. PostgreSQL validates each transition before the data can become trusted output, action state, or audit evidence

## Assets And Principals

| Surface | Assets | Principal | Authority |
| --- | --- | --- | --- |
| PostgreSQL | Source rows, tasks, watches, policies, jobs, receipts, outputs, reviews, actions, and execution receipts | Installer or extension owner | Full database authority and outside this threat boundary |
| Replay evaluation | Approved post-shaping snapshots, exact revision pairs, receipts, and non-authoritative diffs | Installer or extension owner | Owner-only case and run creation; the replay path creates no action, review, materialization, or target write |
| Native runtime | Registered GGUF files, verified artifact identity, worker process, shared memory, latches, and CustomScan state | Otlet background worker | Internal functions and tables needed to run claimed work |
| Application | Source rows and bounded task-subject invocation | Authenticated application login through an owner-granted capability | Submit against any active task with optional owner-scoped idempotency and read or cancel owned jobs; no direct table access, administration, review/apply, retry, worker, or grant authority |
| Review | Shaped inputs, redacted outputs, proposed actions, optional rubrics and calibrations, labels, and review events | `otlet_reviewer` login | Bounded decision RPCs and queues with calibration required only by a declared rubric and no raw table access |
| Operations | Dry run, apply, bounded application retry, and policy status | `otlet_operator` session | Three allowlisted execution RPCs and redacted views with no review authority |
| Audit | Receipts, labels, policy state, administrative history, and redacted operational evidence | `otlet_auditor` session | Read-only allowlisted views |
| Access administration | Registered role identities, desired direct Otlet grants, and drift status | Owner-bootstrapped `otlet_access_administrator` role | Register, reconcile, or revoke non-administrator capabilities through three fixed-path RPCs with no raw registry, grant-helper, data, review, action, worker, or extension-owner authority |
| Evidence preservation | Terminal production job chains, archive rows, export references, holds, and tombstones | Installer or extension owner | Generation-fenced lifecycle changes and owner-only raw archive reads; external archive storage remains deployment-owned |
| Portable authoring | `otlet.watch.v1`, `otlet.workload_pack.v1`, SQL text, JSON Schema, model policy, runtime options, and ordinary files | Pack author and importer | Untrusted bytes until database validation, preparation, and apply |
| Portable protocol | Shaped snapshots and claim, attempt, completion, failure, and cancellation messages | Allowlisted external worker identity and current process incarnation | Exact-version, role-bound, fenced RPC authority with no direct table access |

Deployers trust the native worker and PostgreSQL extension code. The local model is not a principal and receives no database authority. Its text stays untrusted until schema, decision, action, authority, identity, freshness, and evidence checks pass

## Trust Transitions

| Transition | Untrusted input | Control | Closed result |
| --- | --- | --- | --- |
| Configuration to registry | Task, watch, runtime, shaping, decision, and candidate SQL fields | Fixed byte, depth, node, identifier, dependency, and prompt bounds before schema traversal, query binding, or hashing; allowlists, bounded candidate `EXPLAIN`, statement timeout, and transaction rollback | Reject the definition without a task, revision, watch, policy, queue, or materialization mutation |
| Administrative change to history | Model, task, watch, selection, action-policy, workload-pack, Otlet grant-helper, and retention mutations | Authenticated actor, active role, canonical prior and resulting identities, append guard, and transaction commit; optional reason or ticket under advisory governance and mandatory context after strict governance is enabled | Append an advisory event with null context, reject missing context in strict mode without registry mutation, and leave no event for no-ops or failed transactions |
| Intended role to installed privileges | Capability, role OID and name, current direct object and column ACLs, role attributes, ownership, and memberships | Dedicated-role validation, owner-only administrator bootstrap, target lock, direct Otlet ACL reset, current helper union, canonical manifest, policy version, and invariant | Reject privileged, renamed, owning, or inherited roles; expose drift; reconcile one exact direct grant set without changing privileges outside `otlet` |
| Terminal evidence to external archive and tombstone | Explicit lifecycle requests or terminal jobs adopted after automatic lifecycle enablement, history choice, hold, export result, and reference dependencies | Owner-only generation fences, bounded UTC-stable manifest, external export confirmation, named blockers, nonblocking database mutation barrier, and one atomic cleanup item | Retain each opted-in chain until every gate clears, then delete it exactly once and keep hash-only lifecycle and action replay tombstones; leave ordinary bounded failed-job cleanup available while automatic adoption is disabled |
| Task lifecycle to execution authority | Target state, expected revision pin, and same-name replacement | Advisory same-name replacement only without unfinished work or reconciliation; strict owner-only transition, production-policy, task, and declared-source locks, exact revision comparison, live-work drain, unfinished job and reconciliation checks, and revision-head authority | Replace an idle PoC watch directly, or reject a stale pin or unsafe strict transition without mutation; pause and retirement remove execution authority without losing queued, dirty-source, or terminal evidence |
| Artifact to native runtime | File path, bytes, digest, size, and GGUF structure | Registered identity, streamed SHA-256, byte count, parser check, and recheck before each load | Fail the job with a receipt and keep the worker available |
| Source to job snapshot | Candidate query rows, source fields, application request key, retry mode, and database-assigned job origin | Immutable workload revision and origin; row, job-byte, task-byte, model-byte, total-byte, queue-age, task-claim, model-claim, plan-cost, timeout, and source-field admission; authenticated owner and active-role provenance; owner-scoped key bound to a PostgreSQL-authored operation, task, and subject hash; original-snapshot retry limited to an active original revision | Queue every eligible row under one captured contract or none; retain origin through claims and receipts; return the prior keyed job for an exact retry; ignore caller-supplied origin and reject a changed payload, inactive original revision, or exhausted admission budget without partial mutation |
| Job snapshot to model | Prompt and row text | Revision-bound shaping for production or one immutable approved post-shaping evaluation snapshot; revision-bound prompt, schema, model artifact, selection, runtime and action contracts; local execution; no model database credential | Fail the attempt without output or action state |
| Model response to evidence | Raw text, JSON, trace detail, and claimed model identity | Output envelope, JSON Schema, decision contract, evidence bounds, redaction, registered model role, and receipt hashes | Store a rejected or failed receipt, or one validated output |
| Approved label to replay result | Label, post-shaping snapshot, run key, case set, revision pair, model response, and proposed actions | Owner-only entry points, exact label-job-receipt linkage, content identities, append guards, equal case population, evaluation job mode, ordinary claim fencing, production-status isolation, accepted-receipt hashes, and read-only target preview | Reject a mismatched or stale write in one transaction, or append non-authoritative diffs without actions, reviews, records, materializations, target writes, or production status evidence |
| Model action to workflow state | Action type, subject, target, identity, and changes | Task action allowlist, registered workflow authority, target binding, source identity, and recommendation-only default | Reject the action or keep it non-applyable |
| Worker claim to terminal state | Worker identity, process incarnation nonce, protocol version, job ID, attempt number, and lease | Role-bound runtime allowlist, fixed-search-path RPC, current incarnation hash, attempt fence, and live-lease check | Reject unauthorized, incompatible, replaced, reclaimed, or expired workers without partial trusted state |
| Evidence to reader | Receipts, events, traces, policies, and action state | Role grants and redacted status or export views | Deny raw tables and internal mutation functions |

The redacted storage mode keeps source input in each job snapshot until the applicable cleanup path deletes it: ordinary failed and canceled retention cleanup, or evidence-lifecycle deletion for a registered chain. It removes a canary from raw model output, structured redacted fields, action redacted fields, trace detail, and operational events. Owner-only archive rows can contain source input and diagnostic evidence. Diagnostic mode can retain raw model text for its configured interval, so do not use it when that retention conflicts with a secret-handling requirement

## Identity Test Vectors

Native and portable installs use the same canonical JSON, domain separation, version tag, and SHA-256 digest. Semantic, task, source, model, and mutation-authority identities use `otlet:v1:sha256:<digest>`. Artifact, prompt, input, output, schema, runtime, and claim-token checksums remain lowercase SHA-256 under their versioned contracts

| Vector | Canonical UTF-8 payload | Identity |
| --- | --- | --- |
| JSON | `{"format":"otlet.identity.v1","kind":"test_vector","value":{"a":[1,"é"],"b":2}}` | `otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109` |
| Unicode text | `{"format":"otlet.identity.v1","kind":"text_vector","value":"Otlet\n🙂"}` | `otlet:v1:sha256:96077dacfe042898c24b4f06ed6d91b8d21e13a52d36738fe1009032d0d13f72` |

`./scripts/otlet-demo.sh` checks the vectors through the native install. `./scripts/otlet-portable-upgrade-demo.sh` checks them through the SQL-only install

## Workload Revision Contract

PostgreSQL captures `otlet.workload.v1` before it runs candidate SQL. Its `otlet:v1:sha256` identity binds the query and sources, task fields, prompt builder, validator, deterministic decode mode, effective runtime options, direct and routed model artifacts, selection checks, and action authority. The job stores that identity; native and portable claims, receipts, actions, materialization, review, and historical status follow it instead of rereading mutable registry rows

`./scripts/demo/workload_revisions.sh` mutates a queued workload from A to B without model inference. A still uses its original shaped input, schema, runtime, cheap rejection rule, strong artifact, receipt identity, and action authority while a new job receives B. A superseded semantic completion cannot create current materialization state

```text
workload_revision_contract=ok
workload_revision_semantic_contract=ok
workload_revision_status_contract=ok
```

`./scripts/demo/revision_invalidation.sh` makes an input-query-only revision, promotes it, rolls back, repairs semantic state, and drops the watch. It checks `contract_changed` materializations, suspended action authority, and revision-bound receipts. The proof fences inactive queues, serializes claims with promotion, and rejects an active source query after watch removal

```text
revision_invalidation_contract=ok
revision_claim_serialization_contract=true|true
```

## Task And Watch Lifecycle Contract

`./scripts/demo/task_watch_lifecycle.sh` proves advisory same-name identity replacement, strict-mode rejection, pause authority removal, exact-pin resume, unpromoted paused drafts, concurrent definition retry, unfinished-work fences, and coalesced source changes. It fences renamed or replaced source identities, preserves cleanup after a source deletion, and serializes pause with action-target registration, workflow-policy changes, and source-query repair. Its source race proves concurrent work blocks retirement without losing the backlog, then resumes, drains, retires, and removes the watch-owned registry state, indexes, reconciliation, and triggers. The task, revision, canceled job, and other evidence remain. `./scripts/otlet-portable-upgrade-demo.sh` repeats the strict task-state contract through the SQL-only install and checks the migration-local `PUBLIC` fence

```text
task_watch_lifecycle_contract=pin_conflict|pause_fenced|live_claim_fenced|unfinished_fenced|draft_unpromoted|watch_reconfig_fenced|resume_pinned|retire_fenced|watch_backlog|backlog_retire_fenced|watch_resume|rename_retire_fenced|name_reuse_fenced|rename_drop_fenced|drop_pin_fenced|archive_retained|exact_drop|path_independent_cleanup|shared_trigger_preserved|shared_trigger_released|invariants_clean
task_watch_lifecycle_race_contract=definition_write_fenced|action_policy_serialized|repair_serialized|retirement_serialized|backlog_preserved|resume_queued|queue_canceled|repaused|source_missing|status_closed|retired|exact_drop|archive_retained|registry_removed|index_removed|reconciliation_removed|invariants_clean
portable_task_lifecycle_contract=t|t|t|t|t|t|t|t|t|t|t
```

## Bounded Maintenance Contract

`./scripts/demo/bounded_maintenance.sh` proves owner-driven cleanup, archive, reconciliation, and repair slices with fixed primary-item, cluster-WAL, and elapsed-time budgets. It checks persisted progress and partial-slice retry; generation-fenced pause, resume, cancellation, and stale callers; due and future-backoff reconciliation; exhausted retry; time-refresh seeding; failed archive retry with retained evidence; missing-statistics repair; a two-session `SKIP LOCKED` cleanup; cascaded and trigger-updated vacuum handoffs with write-once acknowledgement; owner-only APIs; zero invariants; and clean logs

```text
bounded_maintenance_contract=budgets|cleanup|progress|partial_retry|pause_resume_cancel|wal|time|archive_retry|reconciliation_due_backoff_exhausted_seeded|repair|vacuum|cascade_vacuum|public_closed|invariants_clean|live_lifecycle_retained|skip_locked
```

## Complete Evidence Lifecycle Contract

`./scripts/demo/complete_evidence_lifecycle.sh` proves automatic adoption disabled by default, explicit adoption while disabled, enabled automatic adoption, bounded full-chain archives, fixed-UTC manifests, claim-token omission, generation-fenced history, hold and export changes, stale export refresh, named reference blockers, atomic deletion, hash-only lifecycle and action replay tombstones, fail-closed target rebinding, null completion timestamps, mutation-barrier contention, legacy cleanup while disabled, registered-chain fencing, `PUBLIC` closure, zero invariants, and clean logs. The SQL-only upgrade applies all 88 migrations, preserves dependent function OIDs and legacy complete jobs under the disabled default, then proves explicit archive, export, deletion, repeat installation, and the same closure and invariant contract

```text
complete_evidence_lifecycle_contract=disabled_default|explicit_request|full_chain_archive|timezone_stable|direct_delete_guards|cleanup_fenced|claim_tokens_omitted|hold|failed_export|stale_refresh|completed_export|export_reference|atomic_delete_tombstone|action_tombstone_replay|replay_reference_constraint|replay_invariant|rebind_fail_closed|retain_history|named_conflict|bounded_auto_request|null_finished_adoption|snapshot_conflict|held_first|retry_backfill_conflicts|mutation_barrier_catalog|public_closed|raw_canary_absent|invariants_clean
evidence_mutation_barrier_contract=55P03|true
evidence_shared_barrier_contract=true|true|55P03|55P03
```

## Versioned Observability And Quality Status Contract

`./scripts/demo/versioned_observability_quality_status.sh` proves closed 15-minute, 1-hour, and 24-hour windows, future-row and evaluation exclusion, scoped failure occurrences, schema-rejection denominators, current backlog ages, route and heartbeat transitions, cleanup lag, dimension-matched pressure, and retry-stable event correlation. It checks registered batch task sets, unknown event and runtime redaction, ignored caller-supplied identities, native startup success and failure identities, stale model-swap claim fencing, one portable worker hash, executable auditor access, partial and `PUBLIC` closure, redaction policy version 8 with event message and detail withheld plus registered access-policy status, and zero invariants. The SQL-only upgrade keeps one legacy event and proves its versioned redacted projection with null legacy correlation fields

`./scripts/demo/entity_resolution_quality.sql` independently binds labeled-quality observation time and lag to the latest candidate-coverage, evaluation-slice, and review-economics source report

```text
versioned_observability_contract=windows|failures|backlogs|routes|heartbeats|cleanup|pressure|events|acl|invariants
labeled_quality_status_contract=7|denominators|lag|public_closed
```

## Workload Pack Promotion Contract

`./scripts/demo/workload_pack_promotion.sh` creates one watch, exports its canonical `otlet.workload_pack.v1` baseline, and exercises revisioned preparation, apply, status, and exact one-step rollback without model inference. The proof covers lint and semantic diff, source, schema, model, runtime, and action-target capability findings, stale readiness, source and result canary exclusion, seven-field artifact identities, exact preparation retries, stale compare-and-swap rejection, metadata-only revisions, rollback, append-only lineage, an untouched source row, no generated jobs, `PUBLIC` closure, and zero invariants. The SQL-only upgrade proof sources the same contract after applying all current migrations. `./scripts/demo/evaluation_slices_support.sh` sources the native promotion proof, which runs governed pack apply, retry, and rollback while checking the bound events, task, baseline, candidate, and active head

```text
workload_pack_promotion_contract=39|true
promotion_shadow_rollback_contract=t|t|t|t|t|t|t|t|t|t|t|t
```

## Administrative Change Contract

`./scripts/demo/administrative_change_ledger.sh` covers the seven registry, policy, access, and retention categories that predate workload packs, plus advisory context-free insertion and update, strict missing-context rejection, deletes and direct ledger calls, direct registry renames, retention delete and recreate, target recertification across relation renames, explicit workload promotion, revision chains, delegated active-role attribution, concurrent same-role grants, reason and ticket context, no-op and rollback suppression, append guards, the audit grant, export declaration, `PUBLIC` closure, hash shape, and invariants. The workload-pack proof covers the eighth category through preparation, apply, exact rollback, and failed-transaction suppression. Direct and queued ask proofs keep deterministic task synthesis out of administrative history. The action-target drift proof does the same for automatic generation bumps. The SQL-only upgrade proof checks migration 51, advisory model insert and update with strict rejection, the table, triggers, helpers, access events, revision chain, queued ask behavior, and closure

```text
administrative_change_ledger_contract=t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t
administrative_access_race_contract=t|t
portable_administrative_migration_contract=t|t|t|t|t|t|t
portable_ask_administrative_contract=t|t|t
direct_ask_administrative_contract=true
action_target_drift_contract=true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true
```

## Workload Acceptance Contract

`./scripts/demo/workload_acceptance_contract.sh` registers exact full-population and sampled declarations before their observation window against one baseline and candidate revision without creating jobs or promoting the candidate. It checks all 11 threshold categories, content identity, exact-repeat idempotency, compare-and-swap versioning, stale exact retries, invalid and rolled-back declarations, append-only exception and promotion-decision events, distinct authenticated and active roles, exact exception linkage, owner status, and `PUBLIC` closure. The SQL-only repeat-install proof checks migration 52, repeat installation, the core contract surfaces, and `PUBLIC` closure

```text
workload_acceptance_contract=t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t
portable_acceptance_migration_contract=t|t|t|t|t|t|t|t|t|t|t|t|t|t
```

## Replayable Evaluation Contract

`./scripts/demo/replayable_evaluation.sh` creates one approved case from a labeled production receipt, changes the task contract, restores the baseline revision, and runs both exact revisions over the same post-shaping snapshot. Evaluation mode keeps the inactive candidate revision claimable and carries no authority. Both variants pass through normal claim and receipt fences and use a separate native inference cache. Production semantic in-flight, runtime aggregate, run, receipt, timing, cache, cost, review, trust, action, record, and materialization state stays unchanged

The proof redacts the stored decision field and still requires the receipt-verified transient decision diff to match. It also requires read-only current-target mutation hashes, exact retry idempotency, conflicting-key rejection, rollback, append-only case, run, and result evidence, and an untouched target row. The SQL-only repeat-install proof checks migration 53, the replay surfaces, and `PUBLIC` closure

```text
replayable_evaluation_contract=t|t|t|t|t|t|t|t|t|t|t|t|t|t|t
portable_evaluation_migration_contract=t|t|t|t|t|t|t|t|t|t|t|t|t|t|t
```

## Evaluation Population and Exposure Lineage Contract

`./scripts/demo/evaluation_population_lineage.sh` registers tuning, calibration, shadow, and qualification cases from four labeled receipts. Otlet rejects attempts to change a snapshot population, mix populations in one run, or support a `promote` decision with tuning, calibration, or shadow runs. Two portable workers route one candidate job through cheap rejection and strong cancellation. The strong claim reports attempt 1 while its linked receipt records attempt 2, and the exposure view must retain the receipt attempt

The proof rebuilds each expected source, scheduled, portable-claim, attempt, and result exposure and compares the full multiset with the owner view. Model and prompt identities must match across scheduled and executed stages. Otlet accepts the promotion decision after the qualification run has both baseline and candidate results. The SQL-only proof checks migration 54, population and lineage columns, the exposure view, the promotion signature, and `PUBLIC` closure

```text
evaluation_population_lineage_contract=t|t|t|t|t|t|t|t|t
portable_population_lineage_migration_contract=t|t|t|t|t
```

## Access Policy Lifecycle Contract

`./scripts/demo/access_policy_lifecycle.sh` registers all six capabilities, adopts existing roles, revokes one capability from a multi-capability role, repairs object, column, and manifest drift, and closes role identity, membership, administrator, and `PUBLIC` boundaries

```text
access_policy_contract=roles=6/6|revoke=auditor_preserved|drift=1/2_to_0/0|manifest=closed|membership=closed|rename=closed|admin=narrow|public=closed|invariants=0
```

Otlet records events from installation forward and leaves earlier history absent. Raw database-owner `GRANT` or `REVOKE` statements remain outside lifecycle RPC attribution but appear as desired-versus-installed drift for registered roles. A database or extension owner can replace or disable the guards. Conditional signed audit checkpoints could let an external consumer detect later rewriting, but cannot prevent owner or superuser changes

## Native Threats

- Prompt text tries to override the instruction or choose an action target
- A model returns a forged subject, destination, registered-model name, or selection role
- A worker completes after its lease expires or another worker reclaims the job
- A GGUF file changes after registration, has the wrong size, fails the parser, or cannot be read
- Output, action, trace, event, error, or candidate fields exceed storage limits
- Native code faults and PostgreSQL restarts the worker

The suite expects rejection, bounded evidence, no apply receipt, worker availability, and a clean crash-log scan

## Portable Runtime Threats

The database protocol accepts shaped snapshots and fenced writes only from an enabled runtime identity bound to the invoking worker role. The reference external worker verifies one registered local GGUF, uses the database-built prompt, and returns every claimed result through a fenced RPC. It has no source-table grant or remote model API

The portable boundary covers these threats:

- stolen or replayed worker credentials
- claim replay after lease expiry or failover
- replacement process reuses one registered worker ID while the old process remains alive
- stuck or oversized `psql` child, output, or result
- credential exposure through process arguments or connection-data exposure through logs
- intercepted database traffic or permissive egress

The database enforces the runtime allowlist, exact protocol compatibility, fixed-search-path `SECURITY DEFINER` RPCs, a current process-incarnation fence on stale supplied nonces, a claim fence on the five claim-owned writes, database-recomputed identity, idempotent terminal state, and no direct table grants. The reference worker carries its nonce on all seven post-start calls. A heartbeat with no nonce is the read-only preflight exception. Startup returns one server-generated raw nonce while worker, claim, receipt, and status state retain only its SHA-256 hash. A replacement process fences the old process before new claims. Before claims begin, the worker verifies the database session, grants, protocol, runtime identity, model registration, TLS state, runtime storage, and one no-follow open GGUF whose digest, inode, and path remain bound through llama.cpp load. The deployment keeps that artifact read-only, and the worker rechecks it after inference before submitting a result. The reference worker permits one bounded `psql` child, applies fixed time and byte limits, and kills and reaps a stuck child. It rejects a connection URI containing a password, passes the passwordless URI to `psql`, and relies on libpq credential sources such as `PGPASSFILE`. Initial rejection fails preflight. After successful preflight, a continuous worker reconnects between claims and while draining through fresh `psql` calls that reread the credential file. A renewal rejection abandons the claim and stops inference. Role rotation uses distinct worker identities for overlap, then requires the old identity to report drained with zero live claims before disable and capability revocation. `./scripts/otlet-portable-preflight-demo.sh` scans raw password canaries across live process arguments, container configuration, worker and database logs, status, and Otlet data. No raw password appears in those surfaces, and logs omit connection data. Libpq enforces the configured CA and hostname checks. Infrastructure still owns credential issuance, storage, revocation, and model-provider egress denial

## Stable Decisions

| Case | Expected decision | Failure mode |
| --- | --- | --- |
| Prompt injection | `rejected` | Forged `update_row` has recommendation-only authority and no execution receipt |
| Secret canary | `redacted` | Canary remains in source input but not derived evidence under redacted mode |
| NFC and NFD subjects | `preserved` | Byte-distinct subject IDs remain distinct |
| SQL and bidirectional identifiers | `rejected` | Constraint or validator aborts before registry mutation |
| Oversized evidence field | `rejected` | Completion aborts before job, receipt, output, or action mutation |
| Malformed configuration | `rejected` | Task creation aborts without a task row |
| Forged model identity | `rejected` | Model does not match the task selection role and completion rolls back |
| Reclaimed or expired claim | `rejected` | Receipt, completion, failure, and fallback recovery write nothing |
| Malformed artifact | `rejected` | Worker records a closed artifact failure without output |
| Oversized prompt | `rejected` | Worker records a context-bound failure without output |
| Worker health | `preserved` | Worker remains registered after the cases |

Run the complete suite against the Docker OTLET and real local models:

```sh
./scripts/otlet-demo.sh
```

The trust proof prints one stable line:

```text
adversarial_trust_contract=prompt_injection=rejected|secret_canary=redacted|unicode_identity=preserved|malicious_identifier=rejected|oversized_field=rejected|malformed_configuration=rejected|forged_identity=rejected|stale_claim=rejected|worker_health=preserved|malformed_artifact=rejected|oversized_prompt=rejected
```

The bounded property proof exhausts every byte split across a fixed native and portable JSON corpus and every four-step portable claim-signal sequence. One shared SQL corpus then generates 52 malformed JSON, schema-depth, identifier, Unicode, claim, SQL-dependency, and action-payload cases. Four transaction-local triggers fail receipt, output, action, and record insertion without killing a backend. The outer transaction rolls back every fixture and requires no unauthorized state, raw-secret leak, partial trusted write, backend replacement, or invariant violation

The native and SQL-only runs print the same contract:

```text
trust_boundary_property_contract=malformed_json=8|schema_depth=4|identifiers=8|unicode=8|claim_sequences=8|sql_dependencies=8|action_payloads=8|crash_points=4|unauthorized_state=0|raw_secret_leaks=0|partial_trusted_writes=0|backend_pid_preserved=true|invariants=0
portable_trust_boundary_property_contract=malformed_json=8|schema_depth=4|identifiers=8|unicode=8|claim_sequences=8|sql_dependencies=8|action_payloads=8|crash_points=4|unauthorized_state=0|raw_secret_leaks=0|partial_trusted_writes=0|backend_pid_preserved=true|invariants=0
```

The native run must also finish with `invariant_contract=0` and `docker_crash_log_scan=ok`

## Limits

PostgreSQL superusers, the extension owner, host root, compromised PostgreSQL binaries, and attackers who can rewrite backups sit outside this boundary. Evidence deletion affects active tables and writes WAL. Infrastructure policy controls external archive protection and deletion, replicas, snapshots, backups, restores, and point-in-time recovery copies
