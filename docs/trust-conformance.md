# Trust Conformance

Otlet treats source text, imported configuration, identifiers, model files, model output, and worker claims as untrusted input. PostgreSQL validates each transition before the data can become trusted output, action state, or audit evidence

## Assets And Principals

| Surface | Assets | Principal | Authority |
| --- | --- | --- | --- |
| PostgreSQL | Source rows, tasks, watches, policies, jobs, receipts, outputs, reviews, actions, and execution receipts | Installer or extension owner | Full database authority and outside this threat boundary |
| Native runtime | Registered GGUF files, verified artifact identity, worker process, shared memory, latches, and CustomScan state | Otlet background worker | Internal functions and tables needed to run claimed work |
| Application | Source rows and task invocation | Application role | Rights granted by the application owner; no Otlet operator authority by default |
| Operations | Review, dry run, apply, cancellation, and policy status | `otlet_operator` session | Allowlisted functions and redacted views |
| Audit | Receipts, labels, policy state, and redacted operational evidence | `otlet_auditor` session | Read-only allowlisted views |
| Portable authoring | `otlet.watch.v1`, SQL text, JSON Schema, model policy, runtime options, and ordinary files | Pack author and importer | Untrusted bytes until database validation and import |
| Portable protocol | Shaped snapshots and claim, attempt, completion, failure, and cancellation messages | Allowlisted external worker identity | Exact-version, role-bound, fenced RPC authority with no direct table access |

The native worker and PostgreSQL extension are trusted code. The local model is not a principal and receives no database authority. Its text stays untrusted until schema, decision, action, authority, identity, freshness, and evidence checks pass

## Trust Transitions

| Transition | Untrusted input | Control | Closed result |
| --- | --- | --- | --- |
| Configuration to registry | Task, watch, runtime, shaping, decision, and candidate SQL fields | JSON type checks, identifier constraints, allowlists, bounded candidate `EXPLAIN`, statement timeout, and transaction rollback | Reject the definition without a task, watch, or queue mutation |
| Artifact to native runtime | File path, bytes, digest, size, and GGUF structure | Registered identity, streamed SHA-256, byte count, parser check, and recheck before each load | Fail the job with a receipt and keep the worker available |
| Source to job snapshot | Candidate query rows and source fields | Row, byte, queue, plan-cost, timeout, and source-field admission | Queue every eligible row or none |
| Job snapshot to model | Prompt and row text | Input shaping, prompt and context bounds, local execution, and no model database credential | Fail the attempt without output or action state |
| Model response to evidence | Raw text, JSON, trace detail, and claimed model identity | Output envelope, JSON Schema, decision contract, evidence bounds, redaction, registered model role, and receipt hashes | Store a rejected or failed receipt, or one validated output |
| Model action to workflow state | Action type, subject, target, identity, and changes | Task action allowlist, registered workflow authority, target binding, source identity, and recommendation-only default | Reject the action or keep it non-applyable |
| Worker claim to terminal state | Worker identity, protocol version, job ID, attempt number, and lease | Role-bound runtime allowlist, fixed-search-path RPC, attempt fence, and live-lease check | Reject unauthorized, incompatible, reclaimed, or expired workers without partial trusted state |
| Evidence to reader | Receipts, events, traces, policies, and action state | Role grants and redacted status or export views | Deny raw tables and internal mutation functions |

The redacted storage mode keeps source input in the job snapshot until retention cleanup but removes a canary from raw model output, structured redacted fields, action redacted fields, trace detail, and operational events. Diagnostic mode can retain raw model text for its configured interval, so do not use it when that retention conflicts with a secret-handling requirement

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
- intercepted database traffic or permissive egress

The database enforces the runtime allowlist, exact protocol compatibility, fixed-search-path `SECURITY DEFINER` RPCs, a claim fence on every write, database-recomputed identity, idempotent terminal state, and no direct table grants. Before claims begin, the worker verifies hostname-checked TLS, credentials, grants, protocol, runtime identity, model registration, local artifact digest, writable runtime storage, and the deployment's egress declaration. Infrastructure still owns credential rotation and enforcement of the declared model-provider egress denial

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
