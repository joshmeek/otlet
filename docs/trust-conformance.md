# Trust Conformance

Otlet treats source text, imported configuration, identifiers, model files, model output, and worker claims as untrusted input. PostgreSQL validates each transition before the data can become trusted output, action state, or audit evidence

## Assets And Principals

| Surface | Assets | Principal | Authority |
| --- | --- | --- | --- |
| PostgreSQL | Source rows, tasks, watches, policies, jobs, receipts, outputs, reviews, actions, and execution receipts | Installer or extension owner | Full database authority and outside this threat boundary |
| Native runtime | Registered GGUF files, verified artifact identity, worker process, shared memory, latches, and CustomScan state | Otlet background worker | Internal functions and tables needed to run claimed work |
| Application | Source rows and bounded task-subject invocation | Authenticated application login through an owner-granted capability | Submit against any active task with optional owner-scoped idempotency and read or cancel owned jobs; no direct table access, administration, review/apply, retry, worker, or grant authority |
| Operations | Review, dry run, apply, bounded application retry, cancellation, and policy status | `otlet_operator` session | Allowlisted functions and redacted views |
| Audit | Receipts, labels, policy state, administrative history, and redacted operational evidence | `otlet_auditor` session | Read-only allowlisted views |
| Portable authoring | `otlet.watch.v1`, SQL text, JSON Schema, model policy, runtime options, and ordinary files | Pack author and importer | Untrusted bytes until database validation and import |
| Portable protocol | Shaped snapshots and claim, attempt, completion, failure, and cancellation messages | Allowlisted external worker identity and current process incarnation | Exact-version, role-bound, fenced RPC authority with no direct table access |

Deployers trust the native worker and PostgreSQL extension code. The local model is not a principal and receives no database authority. Its text stays untrusted until schema, decision, action, authority, identity, freshness, and evidence checks pass

## Trust Transitions

| Transition | Untrusted input | Control | Closed result |
| --- | --- | --- | --- |
| Configuration to registry | Task, watch, runtime, shaping, decision, and candidate SQL fields | Fixed byte, depth, node, identifier, dependency, and prompt bounds before schema traversal, query binding, or hashing; allowlists, bounded candidate `EXPLAIN`, statement timeout, and transaction rollback | Reject the definition without a task, revision, watch, policy, queue, or materialization mutation |
| Administrative change to history | Model, task, watch, selection, action-policy, Otlet grant-helper, and retention mutations | Required reason or ticket, authenticated actor, active role, canonical prior and resulting identities, append guard, and transaction commit | Reject missing context without registry mutation; append one committed change while no-ops and rollbacks leave no event |
| Task lifecycle to execution authority | Target state and expected revision pin | Owner-only transition, production-policy, task, and declared-source locks, exact revision comparison, live-work drain, unfinished job and reconciliation checks, and revision-head authority | Reject a stale pin or unsafe transition without mutation; pause and retirement remove execution authority without losing queued, dirty-source, or terminal evidence |
| Artifact to native runtime | File path, bytes, digest, size, and GGUF structure | Registered identity, streamed SHA-256, byte count, parser check, and recheck before each load | Fail the job with a receipt and keep the worker available |
| Source to job snapshot | Candidate query rows, source fields, application request key, and retry mode | Immutable workload revision, row, byte, queue, plan-cost, timeout, and source-field admission; authenticated owner and active-role provenance; owner-scoped key bound to a PostgreSQL-authored operation, task, and subject hash; original-snapshot retry limited to an active original revision | Queue every eligible row under one captured contract or none; return the prior keyed job for an exact retry; reject a changed payload or inactive original revision without mutation |
| Job snapshot to model | Prompt and row text | Revision-bound shaping, prompt, schema, model artifact, selection, runtime and action contracts, local execution, and no model database credential | Fail the attempt without output or action state |
| Model response to evidence | Raw text, JSON, trace detail, and claimed model identity | Output envelope, JSON Schema, decision contract, evidence bounds, redaction, registered model role, and receipt hashes | Store a rejected or failed receipt, or one validated output |
| Model action to workflow state | Action type, subject, target, identity, and changes | Task action allowlist, registered workflow authority, target binding, source identity, and recommendation-only default | Reject the action or keep it non-applyable |
| Worker claim to terminal state | Worker identity, process incarnation nonce, protocol version, job ID, attempt number, and lease | Role-bound runtime allowlist, fixed-search-path RPC, current incarnation hash, attempt fence, and live-lease check | Reject unauthorized, incompatible, replaced, reclaimed, or expired workers without partial trusted state |
| Evidence to reader | Receipts, events, traces, policies, and action state | Role grants and redacted status or export views | Deny raw tables and internal mutation functions |

The redacted storage mode keeps source input in the job snapshot until retention cleanup but removes a canary from raw model output, structured redacted fields, action redacted fields, trace detail, and operational events. Diagnostic mode can retain raw model text for its configured interval, so do not use it when that retention conflicts with a secret-handling requirement

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

`./scripts/demo/task_watch_lifecycle.sh` removes execution authority at pause, keeps queued work dormant until exact-pin resume, leaves paused task edits as unpromoted drafts, rejects concurrent definition writes for retry, rejects watch reconfiguration and retirement with unfinished work, and coalesces source changes without retrying them. It fences renamed or replaced source identities, preserves cleanup after a source deletion, and serializes pause with action-target registration, workflow-policy changes, and source-query repair. Its source race proves concurrent work blocks retirement without losing the backlog, then resumes, drains, retires, and removes the watch-owned registry state, indexes, reconciliation, and triggers. The task, revision, canceled job, and other evidence remain. `./scripts/otlet-portable-upgrade-demo.sh` repeats the task-state contract through the SQL-only install and checks the migration-local `PUBLIC` fence

```text
task_watch_lifecycle_contract=pin_conflict|pause_fenced|live_claim_fenced|unfinished_fenced|draft_unpromoted|watch_reconfig_fenced|resume_pinned|retire_fenced|watch_backlog|backlog_retire_fenced|watch_resume|rename_retire_fenced|name_reuse_fenced|rename_drop_fenced|drop_pin_fenced|archive_retained|exact_drop|path_independent_cleanup|shared_trigger_preserved|shared_trigger_released|invariants_clean
task_watch_lifecycle_race_contract=definition_write_fenced|action_policy_serialized|repair_serialized|retirement_serialized|backlog_preserved|resume_queued|queue_canceled|repaused|source_missing|status_closed|retired|exact_drop|archive_retained|registry_removed|index_removed|reconciliation_removed|invariants_clean
portable_task_lifecycle_contract=t|t|t|t|t|t|t|t|t|t|t
```

## Administrative Change Contract

`./scripts/demo/administrative_change_ledger.sh` covers all seven administrative categories, direct registry renames, retention delete and recreate, target recertification across relation renames, explicit workload promotion, revision chains, delegated active-role attribution, concurrent same-role grants, reason and ticket context, missing-context rejection, no-op and rollback suppression, append guards, the audit grant, export declaration, `PUBLIC` closure, hash shape, and invariants. Direct and queued ask proofs keep deterministic task synthesis out of administrative history. The action-target drift proof does the same for automatic generation bumps. The SQL-only upgrade proof checks migration 51, the table, triggers, helpers, access events, revision chain, queued ask behavior, and closure

```text
administrative_change_ledger_contract=t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t
administrative_access_race_contract=t|t
portable_administrative_migration_contract=t|t|t|t|t|t|t
portable_ask_administrative_contract=t|t|t
direct_ask_administrative_contract=true
action_target_drift_contract=true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true
```

Otlet records events from installation forward and leaves earlier history absent. Raw database-owner `GRANT` or `REVOKE` statements remain outside Otlet helper coverage until the access-policy lifecycle ships. A database or extension owner can replace or disable the guards; the planned signed checkpoints cover that stronger boundary

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

The database enforces the runtime allowlist, exact protocol compatibility, fixed-search-path `SECURITY DEFINER` RPCs, a current process-incarnation fence on stale supplied nonces, a claim fence on the five claim-owned writes, database-recomputed identity, idempotent terminal state, and no direct table grants. The reference worker carries its nonce on all seven post-start calls. A heartbeat with no nonce is the read-only preflight exception. Startup returns one server-generated raw nonce while worker, claim, receipt, and status state retain only its SHA-256 hash. A replacement process fences the old process before new claims. Before claims begin, the worker verifies the database session, grants, protocol, runtime identity, model registration, TLS state, runtime storage, and one no-follow open GGUF whose digest, inode, and path remain bound through llama.cpp load. The deployment keeps that artifact read-only, and the worker rechecks it after inference before submitting a result. The reference worker permits one bounded `psql` child, applies fixed time and byte limits, and kills and reaps a stuck child. It rejects a connection URI containing a password, passes the passwordless URI to `psql`, and relies on libpq credential sources such as `PGPASSFILE`. No credential appears in process arguments or logs, and logs omit connection data. Libpq enforces the configured CA and hostname checks. Infrastructure still owns credential rotation and model-provider egress denial

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

The same run must finish with `invariant_contract=0` and `docker_crash_log_scan=ok`

## Limits

PostgreSQL superusers, the extension owner, host root, compromised PostgreSQL binaries, and attackers who can rewrite backups sit outside this boundary. Retention cleanup affects active tables and writes WAL; infrastructure policy controls replicas, snapshots, backups, restores, and point-in-time recovery copies
