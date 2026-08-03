# Otlet roadmap

Otlet keeps model work beside PostgreSQL data and keeps PostgreSQL in charge of task identity, validation, freshness, action authority, and evidence

The roadmap follows entity resolution and private data stewardship as the first reference workflow, from bounded candidate selection through local judgment, reviewed or corrected recommendations, labels, replay, and audit. Canonical merge and split execution remains application-owned unless its conditional gate opens

This roadmap classifies shipped, release-blocking, planned, conditional, and measured work

Every shipped track needs SQL-visible state, a closed failure path, executable Docker proof with real PostgreSQL data, upgrade and rollback coverage once supported releases exist, and an explicit native or portable support statement

## Roadmap stages

| Stage | Meaning |
| --- | --- |
| Current foundation | Behavior that exists in the repository and has executable proof |
| Release-blocking contract work | A current correctness, authority, security, or operability gap that should be closed before expanding the surface |
| Planned work | The next complete vertical slices after release-blocking contracts hold |
| Conditional research | Work that remains out of scope until a named workload, deployment, or measurement justifies it |
| Measured decision | A tested avenue that stays closed until the recorded reopen gate changes |

## Delivery sequence and proof gates

| Gate | Exit condition |
| --- | --- |
| Contract-safe alpha | Every release-blocking contract closes with focused regression proof, native and portable support is explicit, repository invariants are clean, and the affected real-data Docker ring passes without crash findings |
| External design-partner proof | One named external operator runs representative approved data through deterministic candidates, local judgment, abstention, review, correction, and measured errors under a predeclared workload acceptance contract while all results remain advisory |
| Supported beta | Stable SQL, packaged installation, an upgrade and rollback harness, backup and restore, access reconciliation, evidence retention, decommission, and native or portable conformance pass for one named deployment shape |
| Production-workflow proof | One named owner supplies a real queue, baseline, labeled sample, local-execution requirement, review budget, downstream outcome, deployment profile, and decommission plan and the workload clears its versioned acceptance contract |
| Expansion proof | Two independent deployments use the same workflow and deployment contract before Otlet adds fleet, marketplace, connector, or multi-workflow abstractions |

## Current foundation

| Feature | Explanation |
| --- | --- |
| Native local inference | A resident PostgreSQL background worker runs registered GGUF models through linked llama.cpp, enforces memory and context limits, records runtime fingerprints, and keeps source rows inside PostgreSQL |
| Portable local inference | A SQL-only installation and external worker run one registered local model per process through role-bound fenced RPCs, artifact preflight, and deployment-configured TLS checks that are required by default |
| SQL-only managed-compatible path | The SQL-only schema and customer-VPC worker are intended for databases that block native libraries or background workers while the customer database remains the system of record. Current proof uses an RDS-like Docker fixture; no named provider is certified |
| Durable jobs and claim fencing | Queued work survives requester sessions, workers claim with opaque lease tokens, stale owners lose write authority, and terminal retries must match the first terminal request |
| Cheap-to-strong routing | One job preserves its identity, receipts, retry budget, and queue accounting while PostgreSQL moves rejected cheap output to a stronger registered model |
| Trusted output and receipts | PostgreSQL rebuilds identities, validates the output envelope and supported JSON Schema subset, rechecks source freshness, and stores accepted output only after the contract passes |
| Artifact and runtime identity | Model registration records digest, size, source, revision, quantization, and license. Native receipts bind the effective runtime fingerprint, and portable receipts link to a registered worker identity |
| Versioned identity algorithms | PostgreSQL domain-separates semantic, task, source, model, and mutation-authority identities in canonical JSON and stores them as `otlet:v1:sha256` digests. Native and SQL-only installs share fixed JSON and Unicode vectors while protocol payload checksums remain raw SHA-256 |
| Immutable workload revisions | PostgreSQL captures candidate SQL and sources, task contracts, prompt and validator versions, deterministic decode settings, effective runtime options, direct and routed model artifacts, selection checks, and action authority in one content-addressed revision before candidate execution. Jobs, native claims, portable claims, receipts, actions, materialization, review, and historical status keep that revision |
| Complete revision invalidation | PostgreSQL marks dependent materializations `contract_changed` after output-affecting changes, suspends stale action authority, and keeps old receipt attribution. Revision diff, promotion, rollback, repair, claim fencing, input-query invalidation, and watch retirement have executable proof |
| Source-query contracts and drift repair | PostgreSQL stores raw and resolved query identity, exact declared sources, the fixed execution role, and `search_path`. It accepts read-only parsed SQL over supported source tables and types, then revalidates name binding, schema, functions, privileges, and RLS before use. Drift suspends claims, reads, refresh, CustomScan, and lifecycle work until repair promotes a new revision and restores watch triggers |
| Action-target drift fencing | PostgreSQL binds target columns, enforcing constraints and indexes, execution identity, effective privileges, RLS, and inheritance to each workflow authority revision; when a target changes, PostgreSQL suspends dry run and apply, advances a durable generation, and requires policy re-registration plus fresh action review before mutation |
| Bounded runtime reuse | The native worker keeps one resident model, a bounded exact-output cache, bounded prompt-prefix state, and a bounded task-contract cache with identity-based invalidation. Replacement admission credits only exact reclaimable mmap RSS, keeps anonymous KV and batch allocations inside existing headroom, and records the new residency even when the attempt fails after loading |
| Native same-model cross-task claims | The native task-cursor path can fill one bounded batch from compatible tasks while preserving FIFO order within retry class, claim fencing, and model-policy separation. The reference portable worker requests one claim at a time |
| Optional native model preload | An owner can preload one registered model with normal artifact, memory, cgroup, fingerprint, and failure checks when predictable first-request latency justifies resident memory |
| Semantic row watches | Row changes can mark one subject stale, enqueue refresh work, materialize trusted records, and fail closed when stored output no longer matches current source state |
| Semantic pair watches | Bounded candidate SQL drives pair judgments with plan-cost preflight, caller statement timeout, candidate drift detection, source dependencies, and pair materialization |
| Native semantic query planning | Native CustomScan serves supported fresh semantic predicates, refreshes bounded stale rows through infer-now, exposes plan evidence, and leaves unsupported correlated or row-locking shapes on a standard PostgreSQL plan |
| Semantic SQL reads | Native and SQL-only installations expose current row and pair materializations, freshness status, dependency audit, predicate reads, and plan-status functions |
| Typed actions and review | Models propose allowlisted typed actions. Reviewers can approve, reject, correct, defer, or abstain, and one bounded `update_row` path requires target registration, dry run, freshness, approval, idempotency, and an execution receipt |
| Evaluation labels | Operators can label approved, rejected, or corrected actions and export cases linked to source, output, receipt, model, and action identity |
| Workload admission | PostgreSQL caps bulk rows, input bytes, queue depth, queued bytes, pair candidate cost, and pair statement time before work enters the queue |
| Evidence bounds and redaction | Source-field allowlists, payload limits, bounded trace detail, redacted operational views, and cleanup policy constrain what becomes durable evidence |
| Native runtime containment | Model-load admission, worker RSS and cgroup checks, cancellation, lease expiry, crash recovery, and invariant checks keep native failures out of trusted state |
| Runtime and audit status | Owner-visible SQL views expose queue, worker, cache, memory, model, receipt, review, cleanup, permission, and dependency state. Delegated auditor and operator roles receive a narrower redacted allowlist |
| Audit and access controls | Owner-managed auditor and operator grants expose redacted views and bounded review functions while `PUBLIC` receives no Otlet schema, table, sequence, or function access |
| Watch portability | `otlet.watch.v1` exports and imports validated task, watch, policy, schema, and candidate SQL configuration without model files, source data, results, or secrets |
| Portable worker controls | Owners can register, pause, drain, disable, and inspect portable worker identities while workers receive no source-table or Otlet-table grants |
| Native lifecycle proof | Native checks cover fresh installation, worker and database restart, claim recovery, current-version upgrade preflight, synthetic failed-update rollback, and crash-log inspection |
| Portable migration proof | Portable checks cover repeat installation, ordered migration-ledger completeness, preserved database state, invariants, worker and database restart, and stale-claim rejection, not release-to-release rollback |
| Adversarial conformance | Executable cases cover prompt injection, secret canaries, Unicode identity, malicious identifiers, oversized evidence, malformed configuration, forged identity, stale claims, malformed artifacts, and oversized prompts |
| Evidence cleanup base | Existing policy prunes old events, trace detail, labels, delete-stale materializations, sensitive evidence, and unreferenced failed or canceled jobs |

## Release-blocking contract work

Work in this section closes demonstrated correctness and trust gaps before Otlet expands authority or claims a supported release

| Feature | Explanation |
| --- | --- |
| Deterministic input-relation contract | Require non-null unique subject IDs, one canonical input per subject, and deterministic ordering or cursor semantics. Reject conflicting duplicates atomically instead of relying on `LIMIT 1`, `ON CONFLICT DO NOTHING`, or an unstable tie |
| Candidate overflow and plan drift | Fetch enough information to distinguish a complete candidate set from cap overflow. Reject overflow or declare deterministic top-N semantics, never mark unseen overflow rows `candidate_removed`, re-run preflight after dependency or material plan drift, and expose prior versus current plan evidence |
| Scheduler decision conformance | Make live claim ordering match recorded measured decisions. Remove the current residual `warm_model` preference or remeasure and explicitly adopt it, then keep a model-free conformance fixture for task-cursor order, retries, cancellation, and starvation |
| Model concurrency semantics | Define whether `max_active_jobs` caps claimed jobs, executing inference, or worker processes and enforce that meaning through batch and concurrent claims. The status view and invariant must use the same definition |
| Claimed-batch lease ownership | Prevent later jobs in a sequential native batch from expiring behind an earlier attempt. Use a bounded reservation state or renew every held claim, and prove that a sweeper or second claimer cannot duplicate inference or consume retries for work that has not started |
| Portable absolute attempt deadline | Apply the effective task `max_attempt_ms` to prompt decode and generation from a database-issued claim budget without trusting synchronized wall clocks, stop renewal at the deadline, use the same terminal reason as native execution, and prove that renewal cannot extend work indefinitely |
| Portable runtime-option enforcement | Reject unsupported options before claim, enforce the declared artifact, context, load, and RSS envelope, and record requested, honored, defaulted, and rejected effective settings in each receipt. A portable worker must not accept work whose output-affecting or resource contract it cannot enforce |
| Portable RPC and process fencing | Bound connect, query, renewal, terminal-write, and child-process time; cap concurrent children, stdout, stderr, and result bytes; terminate a stuck `psql`; keep credentials out of process arguments and logs; and add a worker-incarnation nonce so a replacement process fences the old process even when both use one registered worker ID |
| Native and portable execution conformance | Require byte-identical shaped-input, prompt, schema, and revision hashes under one controlled fixture. Compare output, failure, and receipt semantics field by field while allowing attributable model bytes, timings, IDs, timestamps, and runtime identities to differ. Exercise real cheap-to-strong claims, model-attempt indices, receipt lineage, retry-budget preservation, cancellation, and max-attempt exhaustion |
| Artifact verification-to-load fencing | Close the path replacement window between digest verification and llama.cpp load. Bind the verified file object or require an immutable deployment-owned store, reject symlink or inode replacement, and prevent a receipt from claiming an artifact digest that was not loaded |
| Durable watch reconciliation | Persist one coalesced dirty entry per watch and subject when enqueue admission rejects work. Retain the newest source identity, handle source deletion, retry with bounded backoff, expose exhaustion and oldest-pending age, and allow replay or acknowledgement after native or portable restart |
| Read-only semantic status | Keep status, plan, and current-row reads free of hidden writes. A read-only transaction or standby must fail closed on detected schema drift while a separate maintenance path records and repairs the drift |
| Definition complexity bounds | Bound instruction, query, schema, runtime JSON, decision contract, nesting depth, node count, identifier count, and prompt-construction work so adversarial definitions fail atomically without backend instability |

## Near-term operating hardening

These tracks make the corrected core usable by applications and operators without blocking the narrower release-safety work above

| Feature | Explanation |
| --- | --- |
| Runtime capability discovery | Expose supported options, schema behavior, context limits, cancellation, tracing, artifact formats, runtime revision and build features, device settings, and resource admission for each runtime after the release-blocking portable enforcement contract exists |
| Application invocation contract | Add a least-privilege application capability for bounded submission, own-job status and trusted-result reads, and own-job cancellation without task, model, watch, review, action, or raw-table administration |
| Invocation provenance and caller idempotency | Persist authenticated `session_user` and the invocation role captured before privileged execution as separate fields, with `session_user` owning read and cancel authority until verified pooled identity exists. Add an optional request key, payload hash, retry lineage, and operator retry mode for original snapshot versus latest source; return the prior job for an exact retry and reject a changed payload under the same key |
| Task and watch operational lifecycle | Add `active`, `paused`, and `retired` states with dependency inspection and safe deletion at a pinned revision. Use unpromoted revisions for drafts, worker controls for drain, and retention policy for archives |
| Administrative change ledger | Append actor, active role, reason or ticket, old and new revision identity, and timestamp for model, task, watch, selection, action-policy, access-policy, and retention changes. Mutable registry timestamps alone are not an authorization history |
| Model and artifact-store lifecycle | Add database-side disable, deprecation, dependency inspection, drain, replacement, restore reconciliation, free-space status, and dry-run pruning plans. PostgreSQL controls references and readiness, replay and promotion qualify replacements, and deployment tooling owns deletion of external model files |
| Stable failure and retry taxonomy | Assign versioned reason code, stage, retryability, owner action, `retry_of_job_id`, replay mode, and raw-detail visibility across SQL, native, and portable paths while leaving automated quarantine conditional |

## Planned entity-resolution and stewardship work

These tracks complete the first product loop after the release-blocking contracts hold

| Feature | Explanation |
| --- | --- |
| Candidate-set coverage gates | Before promoting candidate SQL or a pair-decision policy, measure how many labeled positive pairs enter the bounded set, how many the cap excludes, candidate volume, per-source coverage, ordering bias, and SQL cost. Candidate generation remains ordinary application SQL |
| Entity-resolution quality decomposition | Report candidate recall, pair classification, abstention, escalation, reviewer agreement, correction, and downstream merge outcome with separate denominators. Do not collapse the workflow into one accuracy number |
| Pair constraint ledger | Store workload-scoped `must_link` and `cannot_link` facts with reviewer, source, and workload revision identity after a correction or repeated rejection. Reopen the fact after relevant source or contract change, and never let a model silently override it |
| Entity-graph conflict status | Detect deterministic conflicts such as `A=B`, `B=C`, and `A≠C`, block recommendation approval, promotion, or export, and route the conflict to a reviewer rather than inventing a clustering rule |
| Authoritative semantic correction | Let an approved typed correction replace current semantic state through an explicit override layer with source freshness, reviewer provenance, expiry, re-review, and preserved original output and receipt |
| Evidence-linked decisions | Let output and actions cite only fields or JSON paths in the shaped job snapshot allowed by `input_shaping.source_fields`. Verify the reference, store its path and value hash, and avoid duplicating another raw snapshot |
| Review sampling | Send an owner-set sample by task, decision class, or action-free outcome into review according to the workload acceptance contract. Link sampled outcomes to labels and evaluation without granting automatic training or promotion authority |
| Reviewer rubric and calibration | Version the decision rubric with each workload revision, use blinded gold cases before granting review authority, record calibration status, and require refresh after rubric change or a declared error threshold is breached |
| Time-based freshness | Let a watch declare `max_age`, refresh window, and overdue policy in addition to source-change freshness. Keep expired reads closed and feed overdue subjects through durable reconciliation |
| Minimal bounded backfill | Submit one revision over a deterministic paged subject set with progress, pause, cancellation, rate limits, and latest-source checks. Keep backfill behind interactive and catch-up work without building a general scheduler |
| Workload pack promotion | Extend `otlet.watch.v1` into versioned task, watch, schema, selection, and action-policy packs with lint, semantic diff, capability checks, transactional apply, and rollback metadata. Keep source data, results, secrets, and model files outside the pack |

## Planned evaluation and model-governance work

| Feature | Explanation |
| --- | --- |
| Workload acceptance contract | Before evaluation, version the population or sampling rule, observation window, baseline, candidate recall, false trust, abstention, review age and minutes, freshness, latency, database impact, unit cost, recovery, and downstream-outcome thresholds. Version every exception and promotion decision |
| Replayable evaluation | Version labeled cases with workload revision and a privacy-aware source resolver or approved shaped snapshot. Compare model, prompt, schema, runtime, selection, and candidate changes on the same population and include a non-authoritative decision, approval, and mutation diff against current registered targets |
| Evaluation population and exposure lineage | Separate tuning, calibration, shadow, and qualification cases, record every model, prompt, threshold, or policy exposure, and prohibit a case used to select a candidate from counting toward its promotion proof |
| Evaluation slices and support | Store population, label coverage, sampling method, observation window, class and source slices, minimum support, and excluded cases alongside quality, false-trust, abstention, escalation, latency, memory, and reviewer-time results |
| Label provenance and quality | Record label author, source, revision, confidence, adjudication state, and supersession. Detect contradictory or stale labels and keep them out of promotion gates until resolved |
| Production model qualification | Require at least three same-run full-workload repeats, customer-representative cases, schema validity, false-trust and action gates, cancellation, memory, latency, and database-responsiveness proof before naming a production-approved model |
| Promotion, shadow, and rollback | Require an owner promotion decision, run a candidate revision in non-authoritative shadow mode, compare it with the active revision, and retain one-step rollback without allowing shadow output to create mutation authority |
| Quality and data drift | Track input-shape, candidate-volume, class, abstention, escalation, reviewer-overturn, and false-trust drift against a declared baseline. Alert on evidence, not on model confidence alone |
| Review economics | Join reviewer minutes, queue age, touch rate, correction rate, machine resource attribution, downstream outcome, and avoided work into cost and reviewer time per accepted or corrected outcome versus the declared baseline without building a billing subsystem |
| Model license and use policy | Match registered license metadata against owner allowlists, deployment purpose, redistribution rules, and unresolved fields. Report policy state without interpreting license law |

## Planned runtime, scheduler, and planner work

| Feature | Explanation |
| --- | --- |
| Job origin and bounded workload budgets | Add a bounded `job_origin` vocabulary for direct ask, task run, row watch, pair watch, catch-up, backfill, and CustomScan. Apply per-task concurrency, queued bytes, and maximum queue age under the global policy and expose origin in queue, receipt, and resource status |
| Interactive and asynchronous service quantum | Interleave infer-now and queued work under sustained load so neither class starves the other. Declare p99 queue-age and cancellation-observation bounds before adding priority classes |
| Workload enablement preflight | Estimate candidates, jobs, input bytes, queue storage, model time, catch-up duration, and uncertainty from `EXPLAIN` plus observed runtime medians before enabling a large watch or backfill |
| Semantic planner statistics | Maintain generic fresh, stale, and missing counts outside planning and retain exact predicate counts for diagnostics |
| Bounded CustomScan state | Expose estimated and actual preload rows, bytes, and time, decline the CustomPath when a bounded estimate exceeds policy, and fail closed if executor state crosses a hard cap |
| Planner-shape conformance | Keep fixtures for the shipped planner surface: prepared generic and custom plans, nested-loop rescans, parameterized and correlated relations, row locking, supported isolation levels, schema drift, cancellation, and standard-plan fallback |
| Model-bound context budgets | Register the tested context limit for each artifact, let a task request a smaller cap, include prompt and decode memory in admission, and reject overflow with a stable reason without silent truncation |
| Native cancellation SLO | Measure request-to-observation and cancel-to-stop time through claimed-but-not-started batch wait, prompt decode, generation, cache hit, model load, strong fallback, and output acceptance. Expose p95 and p99 and add finer preemption only after the declared SLO fails |
| Worker database-operation deadlines | Bound internal claim, sweep, renewal, receipt, completion, and materialization lock waits so a blocked SPI transaction cannot stall the only native worker or silently lose leases |
| Route readiness and stranded escalation | Show whether every direct, cheap, and strong route has an eligible healthy worker and artifact. Surface stranded queued escalation immediately with age and reason instead of relying on retry churn |
| Bounded maintenance execution | Run cleanup, archive, reconciliation, and repair by row, WAL, and time budgets with progress, pause, resume, retry, `SKIP LOCKED` where safe, and a declared vacuum handoff |
| Versioned observability and quality status | Add time-windowed queue wait, run time, stale age, catch-up age, failure class, schema rejection, review backlog, route readiness, worker heartbeat, cleanup lag, and resource pressure. Version redacted low-cardinality event fields, correlate incidents through stable job, claim, receipt, revision, worker, and action identities, and keep labeled quality separate with denominator and observation lag |
| Resource and unit-cost attribution | Attribute request-local queue bytes, stored evidence, tokens, model time, failures, and maintenance work to task, workload revision, model, origin, and database caller role without storing raw evidence in metrics. Keep resident model and context RSS on the worker and model, with shared or unallocated capacity explicit until an allocation rule exists |

## Planned security, privacy, and governance work

| Feature | Explanation |
| --- | --- |
| Access-policy lifecycle | Register intended application, auditor, operator, portable worker, and administrator roles. Reconcile grants after upgrades, expose desired versus installed privileges, revoke one capability, and keep administration narrower than extension-owner authority |
| Complete evidence lifecycle | Extend cleanup to successful jobs, receipts, outputs, actions, reviews, labels, and optional history. Define archive-before-delete, hold precedence, export state, retention conflict, bounded execution, audit tombstones, and safe reference-chain deletion |
| Credential lifecycle | Exercise portable role rotation, overlap, revocation, reconnect, and drain without putting secrets in status, logs, command arguments, or database evidence. Leave issuance and secret storage to deployment IAM |
| Processing inventory export | Export tasks, allowed fields, source dependencies, models, runtimes, retention, roles, review policy, and action authority as an inventory snapshot for security review, not as a compliance certification |
| Trust-boundary fuzz and property checks | Generate bounded malformed JSON, schema depth, identifiers, Unicode, claim sequences, SQL dependencies, action payloads, and crash points and assert no unauthorized state, raw-secret leak, backend crash, or partial trusted write |
| Software and model supply chain | Pin source revisions and expected digests, produce checksummed packages, SBOMs, build provenance, dependency and vulnerability reports, and offline verification. Keep artifact authenticity distinct from model quality and license approval |

## Planned deployment, recovery, and operations work

| Feature | Explanation |
| --- | --- |
| Stable SQL and first compatibility promise | Before a supported beta or customer state exists, define stable functions and views, native or portable availability, transaction behavior, privileges, compatibility window, deprecation policy, and executable examples. Add immutable migration digests, prove fresh-install and upgraded-install convergence, and publish a database-schema, portable-protocol, and worker-binary compatibility matrix with upgrade order and mixed-version or drain behavior. Then ship data-preserving updates from each supported release without pre-beta compatibility scaffolding |
| Supported distribution | Publish the native versus portable matrix and supported PostgreSQL, Linux, CPU architecture, extension, worker, llama.cpp, and model-format combinations. Build pinned native packages and portable images with preflight, clean-install proof, failed-update rollback, and restore or forward-fix instructions; promise post-commit downgrade only where exercised |
| Backup and restore contract | Restore PostgreSQL state and the deployment-managed model store into a clean environment, verify artifact identities, fence pre-restore workers, expire or reclaim leases, rebuild process-local state, and require zero invariant violations |
| Point-in-time recovery semantics | Define queued, running, completed, reviewed, applied, stale, exported, and held state after recovery to an earlier WAL point. Detect external side effects PostgreSQL cannot roll back and require application reconciliation |
| Unified doctor and repair plans | Return one read-only report for versions, migrations, artifacts, capabilities, ACL drift, worker health, routes, queues, stale work, cleanup, dependencies, and invariants. Every finding gets severity and remediation text; only reversible, idempotent repairs receive a separate dry-run and apply path |
| Privacy-safe support bundle | Assemble owner-approved doctor output, canary results, versions, configuration hashes, aggregate status, and reason codes with an expiry. Exclude source rows, prompts, outputs, claim tokens, credentials, and secrets and make the exact manifest visible before export |
| Operational failure runbooks | Publish owner, detection, stop condition, evidence, remediation, reconciliation, and recovery steps for queue growth, worker loss, bad artifacts, schema drift, stalled watches, invalid outputs, failed actions, and restore events. Reuse pause, drain, disable, retry, and doctor controls instead of adding an orchestration layer |
| Synthetic end-to-end canary | Run an owner-scheduled synthetic fixture through queue, runtime, schema validation, receipt, and materialization with no application data or action authority |
| Configuration and capacity drift | Compare installed settings with the declared deployment profile and estimate model memory, queue storage, evidence growth, WAL, cleanup, and recovery capacity before a change is applied |
| Supported decommission and migration | Drain workers, freeze mutation, choose final export and retention behavior, revoke roles, verify no live claims, remove scoped Otlet triggers and state, and leave application rows, external model files, replicas, snapshots, and backups untouched |

## Planned ecosystem and product proof

| Feature | Explanation |
| --- | --- |
| Reference entity-resolution packs | Ship licensed or synthetic candidate SQL, schemas, decision contracts, labels, expected validation and receipt states, review outcomes, and audit output for vendor, account, and catalog examples without bundling model files, secrets, or customer data |
| Deterministic candidate interoperability | Document how ordinary SQL, `pg_trgm`, pgvector, probabilistic matchers, or application scores can nominate bounded candidates while Otlet owns only the private judgment, evidence, freshness, review, and action contract |
| Application review surface | Stabilize the redacted queue, evidence, decision, correction, and action operations needed by a customer-owned review interface without putting authentication, organization management, or a UI framework in the extension |
| Design-partner onboarding runbook | Document source mapping, baseline construction, acceptance-contract selection, reviewer preparation, advisory rollout, support ownership, decommission, and time to first accepted result for the first external operator |
| Public security and contributor lifecycle | Publish disclosure, supported-version, release-note, contribution, generated-artifact, and dependency-update policies before accepting a support obligation |

## Conditional semantic and workflow research

Start these tracks only after the named trigger exists

| Feature | Explanation |
| --- | --- |
| Incremental pair refresh | Start when a bounded full candidate refresh exceeds its source-write, queue, or catch-up budget. Preserve candidate completeness, deletions, deterministic ordering, source dependency identity, and repair from a full scan |
| Set-based watch invalidation | Start when per-row trigger time or enqueue amplification exceeds a declared source-write budget. Use statement transition tables, persist durable dirty state once per watch and subject set, and return control to the source transaction |
| Logical-decoding invalidation | Start when measured trigger and set-based cost still exceed budget. Preserve transaction boundaries, ordering, replay position, failover-slot readiness, source deletion, catch-up, and full reconciliation |
| Composable semantic dependencies | Start when a shipped dependency cannot use candidate SQL, ordinary views, or application orchestration. Declare edges, reject cycles, cap fan-out and depth, propagate invalidation, and make every intermediate receipt visible |
| Semantic revision history | Start for an as-of decision or audit case that retained receipts and outputs cannot answer. Store bounded materialization revisions with valid time, workload revision, source identity, supersession reason, and retention |
| Zero-downtime output-schema transition | Start when a named application cannot drain one immutable workload revision before activating the next. Classify additive and breaking schema changes, version consumer read contracts, allow bounded old and new coexistence, and block retirement until declared consumers and materializations migrate |
| Output-contract surface expansion | Start when a named workflow cannot express a required trusted result with the supported JSON Schema subset. Add the smallest missing keyword or type with PostgreSQL-owned validation, native and portable conformance, complexity bounds, migration behavior, and adversarial proof |
| Resumable backfill scheduler | Start when minimal paged submission cannot meet an observed backfill size or restart requirement. Reuse job origins, budgets, reconciliation, and pause state instead of adding a general workflow engine |
| Partitioned source support | Start for a concrete partitioned schema. Define partition attach and detach behavior, trigger coverage, dependency drift, candidate completeness, action lock ordering, and schema-change recovery |
| Composite subject identity | Start for a concrete workload whose subject cannot use one existing stable scalar key. Define typed canonical encoding, ordering, equality, migration, external representation, and native and portable test vectors |
| Group and aggregate watches | Start when a named workflow must judge a bounded changing group such as all notes for one customer or transactions for one account. Bind group key, ordered member identities, membership changes, content hash, source dependencies, and full-group repair |
| Review assignment and leases | Start when a named workflow has concurrent reviewers and duplicate or abandoned work exceeds its acceptance threshold. Add assignee, decision class, bounded priority, due time, backlog status, claim lease, expiry, and release without creating a general ticket system |
| Independent review and adjudication | Start when the acceptance contract requires two reviewers for one decision class. Preserve both blinded events, measure agreement against gold rather than agreement alone, and add an explicit adjudication result without overwriting history |
| Tenant and RLS isolation | Start for a named shared-database deployment. Carry tenant and invoking authority through candidates, jobs, materializations, review, actions, quotas, cleanup, and audit and prove cross-tenant denial |
| RLS-aware actions | Start after the owner-selectable task read-authority contract ships and a workflow needs mutation against an RLS target. Validate, dry run, approve, and apply under the intended application role |
| Additional bounded action types | Add one concrete typed action after a shipped workflow needs it. Generalize shared handler machinery only after two action types prove the same authority, freshness, idempotency, review, and receipt contract |
| Multi-row action plans | Start when one approved business operation must update a small row set atomically. Cap rows and bytes, lock in stable order, recheck every source, record before and after hashes, and define reversal |
| Canonical entity and merge or split state | Start when application-owned `merge_candidate` recommendations are insufficient in two independent deployments. Consume the planned pair-constraint and graph-conflict ledgers, keep canonical IDs and aliases in application tables, and add only versioned merge and split authority with human adjudication |
| Field-survivorship provenance | Start when an approved canonical merge must resolve conflicting fields. Let owner rules choose allowed source priority; a model may select an existing shaped value and cite its path and hash but may not synthesize authoritative source data |
| Merge and split impact plans | Start before Otlet can execute a canonical change. Preview affected foreign keys and rows, cap scope, lock in stable order, bind source and revision freshness, require idempotency and approval, and define reversal without adding a generic procedure runner |
| Multilingual and cross-script entity packs | Start for a named workload with labeled locale and script cases. Keep normalization and deterministic anti-merge rules outside the model, preserve original evidence, and report quality by language and script |
| Adjacent private-data workloads | Add human-reviewed extraction, data-quality repair, classification, or operational exception triage only after one workflow proves the same bounded SQL evidence, local judgment, correction, freshness, and action contract |
| Destination reconciliation | Start when two independent deployments need the same delivery contract. Export receiver-enforced idempotency keys and record acknowledgements, but keep network transport and connector credentials in the application layer |
| First-class semantic DDL | Start when function-based task and watch authoring blocks adoption and extension APIs can express the full contract without a PostgreSQL fork |

## Conditional runtime and deployment research

| Feature | Explanation |
| --- | --- |
| Priority, deadline, and caller budgets | Start when job-origin and per-task controls cannot meet interactive, watch, or backfill queue-age SLOs. Add bounded priority classes, expiry, aging, token, time, and escalation budgets, and per-caller limits only after verified caller identity exists; prove starvation bounds |
| Incremental admission accounting | Start when the global advisory lock or queue scans breach the declared admission p95 at measured queue sizes. Add transactional counters only with rollback, cancellation, requeue, crash, and invariant-rebuild proof |
| Predicate selectivity statistics | Start when recorded `EXPLAIN ANALYZE` execution time, row error, or preload bytes breach the workload threshold versus an exact-predicate baseline for the declared observation window. Add fingerprinted or sampled selectivity only for that predicate shape and prove planning cost and plan stability |
| Scalable claim path | Start when claim p95 or the policy-row lock wait exceeds its acceptance threshold for the declared observation window at representative queue size. Prove bounded plan cost, no duplicate claims, cursor fairness, and a repeatable throughput gain |
| Supported worker-pool scale-out | Start after one worker misses a declared throughput SLO and an A/B run proves `OTLET_WORKER_COUNT > 1` wins under aggregate RSS and database-load gates. Add per-process identity, model-filtered placement, fairness, and drain; claim availability only with separate failure-domain placement and host-loss recovery proof |
| Poison-job and artifact quarantine | Start when the same job revision or artifact crashes or wedges two distinct worker incarnations. Quarantine only that identity, preserve retry evidence, require explicit release or replacement, and keep transient host failure out of the count |
| Portable transport efficiency | Start when measured `psql` startup, polling, or row encoding consumes a declared share of portable latency or connection load. First reuse a bounded process or standard PostgreSQL client; add a long-lived protocol only with cancellation, fencing, credential, backpressure, and recovery proof |
| External runtime and model conformance kit | Start when an external maintainer adds a runtime or certifies a model family. Package the release-blocking fixture for prompt identity, claim fencing, cancellation, schema output, cheap-to-strong accounting, artifact and runtime identity, redaction, receipt parity, and recovery and reuse the portable protocol rather than creating a plugin SDK |
| Native process isolation | Start when measured llama.cpp crash or corruption risk violates the database SLO. Use a supervised helper and fenced IPC only if PostgreSQL worker restart cannot meet the contract |
| Multi-database cluster topology | Start when one PostgreSQL cluster must host Otlet in multiple databases. Prefer one portable registration per database until native shared-memory, latch, budget, and shutdown ownership have focused proof |
| Read-replica semantics | Start when an application needs Otlet reads from a standby. Permit redacted status and fresh-materialization reads with replay-LSN evidence and block claims, actions, cleanup, and administration |
| Production availability and single-writer failover | Start when a named production deployment declares RPO, RTO, maximum stale age, backlog recovery, and action-reconciliation thresholds that restart and restore cannot meet. Name the external HA authority that fences the old primary, prove one trusted terminal result per job, and drill the exact deployment before publishing an availability claim |
| Active-active databases | Start only when a named deployment requires multi-writer availability that the proven single-writer topology cannot meet. Define conflict authority for jobs, reviews, actions, labels, semantic state, and external side effects before prototyping |
| Database-health backpressure | Start when inference causes measured connection, lock, WAL, storage, autovacuum, replica-lag, or application-latency pressure. Pause admission or claims at explicit fail-closed thresholds and prove recovery without oscillation |
| Governed remote providers | Start for a deployment that cannot use native or portable local inference after its data-classification contract exists. Treat a provider as a portable runtime with capability declaration, credential isolation, TLS, egress policy, cancellation, cost, retention, and PostgreSQL validation |
| Confidential portable workers | Start when a named deployment cannot trust the worker host. Define attestation authority, freshness, key rotation, revocation, model identity, measured boot, and failure behavior before source evidence leaves PostgreSQL |
| Named-provider deployment certification | Start after one managed PostgreSQL provider and deployment shape are selected. Prove preflight, install, private connectivity, least privilege, upgrade, drain, backup, restore, and failure handling before publishing support |
| Air-gapped installation | Start for a deployment with a no-download requirement. Produce one offline bundle with exact packages, model metadata, checksums, migrations, preflight, install, and rollback material and verify it in a clean disconnected environment |
| New PostgreSQL major support | Add one major version at a time after its release and a supported packaging target exist. Exercise dump or in-place strategy, extension binary replacement, portable migrations, watch triggers, planner hooks, model store, roles, and rollback before listing support |
| PostgreSQL coexistence certification | Start with one requested combination such as `pg_trgm`, pgvector, PostGIS, partitioning, RLS, logical replication, pooling, or an HA tool. Prove installation and non-interference first, then only the candidate, planner, upgrade, and recovery semantics the combination actually touches |

## Conditional security and governance research

Start these tracks only for deployments whose authority or regulatory model requires them

| Feature | Explanation |
| --- | --- |
| Data classification and purpose binding | Start when a named deployment requires cross-class, provider, export, or regulatory enforcement. Let owners label fields, tasks, models, and runtimes with declared data classes and purposes and reject incompatible combinations without inferring legal classification |
| Owner-selectable task read authority | Start when delegated task authoring or a shared-database deployment needs source reads under a role other than the fixed Otlet execution identity. Let the owner bind a named per-task database role and preserve its RLS and column privileges through candidates, jobs, materializations, review, and actions |
| Verified pooled application and reviewer identity | Start when a connection pool shares one database role but policy must name an end user. Define the trusted issuer, audience, subject, nonce, transaction binding, verifier, expiry, and replay block; distinct database roles remain the default and free-text identity is never authoritative |
| Subject lineage and erasure plans | Start for a named regulated deployment. Trace one subject through jobs, outputs, receipts, reviews, actions, labels, and materializations and produce a dry-run deletion or redaction plan while keeping application rows, replicas, backups, and legal interpretation outside the claim |
| Separation of duties and break-glass access | Start before a named regulated workflow permits consequential mutation. Separate promotion, review, approval, and execution where required, deny self-approval, expire approvals after source or revision change, and record break-glass reason, approver, scope, and expiry |
| Signed audit checkpoints and offline bundles | Start when an external consumer must detect live-database-owner rewriting or verify evidence offline. Canonicalize a bounded export, sign or timestamp it with external keys, support rotation and revocation, and never claim protection from a compromised signer or PostgreSQL superuser |

## Conditional model and hardware research

| Feature | Explanation |
| --- | --- |
| Schema-guided generation | Start when invalid JSON or grammar-expressible schema rejection breaches its workload threshold for the declared observation window. Compile only the grammar-expressible subset, keep balanced-JSON generation for the rest, retain PostgreSQL validation, and require quality, latency, cancellation, and memory parity |
| Calibrated model routing | Start when strong-route share exceeds its workload threshold for the declared observation window. On an untouched qualification set, require offline calibration to lower strong work beneath that threshold without breaching false trust, abstention, or slice gates; keep fixed routing as the fallback |
| Long-context evidence plans | Start when context overflow or evidence truncation breaches its workload threshold for the declared observation window and better bounded evidence selection fails the same cases. Cap chunks, stages, receipts, latency, and memory and require a qualification-set gain over that baseline |
| Multimodal evidence | Start for a workload that needs image, audio, or document evidence. Bind object digest, parser, model capability, source freshness, redaction, retention, and receipt identity without making PostgreSQL an object store |
| Adapter and LoRA lifecycle | Start when an adapter beats prompt and base-model changes on a versioned evaluation set. Keep training outside PostgreSQL and register base artifact, adapter digest, license, promotion, compatibility, and rollback |
| Ensemble or consensus decisions | Start when one high-impact decision class breaches its false-trust threshold for the declared qualification window and independent models lower it beneath the gate versus the strongest single-model baseline. Preserve per-model receipts, latency and memory budgets, and one deterministic aggregation rule |
| Active learning | Start when label coverage or reviewer minutes breach the workload threshold for the declared observation window. Compare owner-approved uncertainty or coverage sampling with random or stratified baseline yield, keep sampling bias visible, and never train or promote automatically from review events |
| Privacy-preserving evaluation | Start when approved shaped snapshots cannot leave a deployment but cross-deployment evidence is required. Prefer aggregate metrics and minimum-support rules before federated computation or privacy-noise machinery |
| GPU execution | Start for a named deployment and device after native or portable proof preserves artifact identity, output quality, schema validation, memory admission, cancellation, fallback, and receipts |
| Alternate CPU, NPU, or edge execution | Start for hardware with a distinct capability the current llama.cpp CPU path cannot use. Compare on the same host where possible and bind device, driver, build, energy, thermal, memory, and fallback evidence |
| Speculative decoding | Reopen when installed artifacts expose compatible draft or MTP support and the linked runtime provides stable caller hooks. Count draft memory, acceptance, rejection work, cancellation, schema-valid output, and quality parity |

## Measured decisions and reopen gates

| Feature | Explanation |
| --- | --- |
| Cache-hit completion path | Direct exact hits measured `3ms` requester p50 after transaction fusion while retaining prompt, action, schema, contract, runtime-output, and model-identity validation. Keep the fault-isolated metrics and materialization boundaries; reopen only if a measured application SLO cannot tolerate the remaining path |
| CPU runtime defaults | Keep one native worker, six decode and batch threads, 512-token logical and physical batches, F16 KV, llama.cpp defaults for mmap, mlock, and flash attention, and unset OpenMP placement on the measured 12-core ARM64 host. Reprobe on each materially different host, runtime, or model instead of universalizing these settings |
| Benchmark baseline model | `qwen35_4b` remains the benchmark baseline, not a production-qualified default. Run `b1783967979` used model fingerprint `e66bad85956d6d75` and runtime fingerprint `e5797a21096dfddf`; its 447 jobs scored `0.7667` extraction, `0.3324` hallucinated trusted actions, and only one repeat. No model earns production approval until every gate passes in at least three same-run repeats |
| Optional startup preload | Three same-host pairs reduced median first-request latency from `10.131s` cold to `5.545s` preloaded while holding about `5.772 GB` of working-set memory. Keep preload opt-in until a workload has a first-request SLO and enough idle-memory headroom |
| Bounded multi-prefix state | An A/B/A probe restored 386 of 424 prompt tokens, reduced the repeated prompt decode from about `6.7s` to `1.143s`, and held two prefix states in about `130.6 MiB`. Keep the bounded cache and reconsider its cap only after measured eviction or memory pressure |
| Multiple native CPU workers | One worker remains the default. Two measured workers increased wall time or resident memory without a useful throughput win. Reopen on different hardware, model, or workload evidence with aggregate RSS, fairness, cancellation, and database-latency proof |
| Warm-model queue preference | The measured candidate reduced one model load but regressed median wall time and maximum queue wait. Keep it rejected, and resolve the residual live `warm_model` ordering under release-blocking scheduler conformance before treating this decision as enforced |
| Larger fallback claim batch | Batch size 16 reduced model loads and wall time but held a requested cancellation for 17.213 seconds. Keep the default at 8 until a candidate retains the throughput win and meets the cancellation SLO |
| Single-context decoder batching | The measured prototype ran slower at four jobs or used more RSS at eight jobs. Reopen after a runtime or model change can improve wall time while preserving output correctness, schema validity, cancellation, fairness, RSS, and PostgreSQL latency |
| Multi-model co-residency | The measured cheap and strong contexts projected about 9.941 GB against about 8.218 GB of physical memory before PostgreSQL reserve. Keep one resident context until two useful contexts fit with per-model admission and scheduling proof |
| Persisted cache | Current workloads show no eviction followed by a repeated miss, and trusted outputs already survive in outputs and semantic materializations. Keep the bounded process-local cache until eviction or restart misses consume material workload time |
| Prompt template | Raw prompting with `/no_think` passed the recorded five-case probe. Removing the marker failed one case, and the embedded template failed all five. Reopen only for a new model revision with the full prompt-identity and quality gate |
| Higher quantization | The tested Q5_K_M artifact used more memory, loaded more slowly, decoded more slowly, and regressed one adversarial case against Q4_K_M. Reopen on a new artifact or workload that clears the same quality and resource gate |
| PostgreSQL fork or Access Method | Existing extension hooks cover the shipped CustomScan and semantic-read contracts. Keep core patches, a maintained fork, and a new Access Method closed until one required contract lacks a supported hook |
| Semantic FDW | Keep the removed FDW path closed. Reopen for a concrete foreign-relation ownership or pushdown case that normal PostgreSQL FDWs and CustomScan cannot serve |

## Product boundaries

| Feature | Explanation |
| --- | --- |
| Source ownership | Application rows stay in application tables and derived Otlet state stays under `otlet` |
| Database authority | PostgreSQL remains the authority for workload definition, immutable revision identity, source identity, validation, claim fencing, freshness, action policy, review state, and trusted evidence |
| Query availability | Normal application queries and reads of fresh materialized results do not require a live model worker |
| Deterministic first, model last | SQL, rules, search, and specialized matchers should narrow candidates and settle easy cases. Otlet belongs on the bounded ambiguous tail where local model judgment adds measured value |
| Local-first execution | Native and portable local runtimes remain the default. Remote execution requires an explicit deployment policy and the same PostgreSQL validation path |
| Mutation authority | Models propose typed data. Owners register action contracts, reviewers approve bounded work, and PostgreSQL performs final freshness, policy, idempotency, and write checks |
| No partial trusted results | Token streams and provisional model output never become application-visible trusted state. Progress may be observable, but only a complete PostgreSQL-validated terminal result can enter outputs, semantic materializations, review, or actions |
| Application-owned entity state | Otlet does not become a master-data store. Canonical entities, aliases, foreign-key rewrites, downstream delivery, and business rollback remain application-owned unless two independent deployments require the same bounded merge and split contract and its conditional gate passes |
| SQL as the workflow surface | Tasks, candidate selection, watches, policies, reads, and status remain SQL and JSON Schema contracts |
| Existing PostgreSQL search | Otlet does not build a vector database, text-search engine, geospatial index, or duplicate application store. Candidate SQL composes installed PostgreSQL features |
| Application delivery | Webhooks, message buses, destination credentials, user interfaces, organization management, and customer workflows stay outside the extension until two independent deployments require the same delivery and reconciliation contract |
| No general agent framework | Otlet does not add model-authored SQL, arbitrary tool calls, an agent loop, a workflow language, or a plugin marketplace |
| No automatic training | Reviews and labels are evidence. Training, fine-tuning, data selection, and promotion require explicit external work and owner approval |
| No direct network inference | Keep HTTP clients and provider credentials out of the PostgreSQL worker. Use a governed portable runtime if a remote provider becomes necessary |
| No distributed llama.cpp RPC | Scale through fenced worker processes and the PostgreSQL queue after worker-pool contracts pass |
| No required second database | Native and portable deployments keep the customer PostgreSQL database as the system of record |
| Evidence minimization | Raw model text and token detail remain bounded by redaction and retention. New caches, exports, telemetry, and providers must preserve that boundary |
| Artifact trust boundary | GGUF files, llama.cpp builds, extension binaries, and worker binaries are deployment-approved inputs. Digests and provenance establish identity, not safety; untrusted artifacts require a separately proven isolated runtime |
| Infrastructure boundary | Otlet does not protect against host root, PostgreSQL superusers, extension owners, compromised binaries, or rewritten backups and does not provide encryption at rest, network policy, IAM, replica, snapshot, or secret-storage controls. Every supported deployment contract must name the owner and proof for each control |
| Compliance boundary | Otlet can export controls and evidence but does not certify legal compliance, interpret model licenses, or claim that local execution alone makes a workflow safe |
| Proof standard | Planner, runtime, recovery, security, and data-integrity changes use the smallest focused check plus the Docker validation ring required by the affected contract |
