# Portable Worker

The portable worker runs one-off inference, model routing, and row or pair watches through Otlet's asynchronous SQL surface. Portable jobs reuse the existing materialization, read, action, status, audit, cleanup, cancellation, and recovery functions

Use this path when PostgreSQL allows ordinary SQL but cannot load the native Otlet extension worker. The reference worker connects through `psql`, claims one model's bounded snapshots, runs one local GGUF with llama.cpp, and submits results through the fenced portable RPCs

Synchronous `otlet.ask(...)`, CustomScan, and infer-now remain native-only because they require an in-process PostgreSQL worker or extension hooks. Portable callers use committed queues and the same SQL read functions

Each process loads one registered model. Register a separate role and worker identity for each additional model. The worker has no remote model API and no direct access to source or Otlet tables

## Install The SQL Contract

Run the installer as the database owner from the repository checkout:

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f crates/otlet_worker/sql/install.sql
```

The install transaction runs the current SQL contract as migrations `0001` through `0071`. Re-running it skips recorded migrations and preserves existing data. This greenfield path rejects older unversioned `otlet` schemas instead of converting them

The database keeps zero `otlet` extension objects and zero C-language Otlet functions

Model, task, watch, selection, action-policy, Otlet access-grant, and retention changes require a reason or ticket in the same transaction. Both native and SQL-only installs append those changes to `otlet.audit_administrative_change_export`

Deterministic task synthesis inside `otlet.enqueue_ask` is runtime bookkeeping. It appends no administrative event and restores the caller's suppression state

## Register The Worker

Create one dedicated login with `NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`. Register the model first. Read the exact runtime identity from the binary, then grant and bind the worker:

```sh
runtime_identity="$(otlet_worker --print-runtime-identity)"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v runtime_identity="$runtime_identity" <<'SQL'
BEGIN;
SELECT otlet.set_administrative_change_context('Grant and register the portable worker');
SELECT otlet.grant_portable_worker_access('otlet_worker'::regrole);
SELECT otlet.register_portable_worker(
  'customer-vpc-worker',
  'otlet_worker'::regrole,
  1,
  'qwen35_4b',
  'otlet-portable-worker',
  '0.1.0',
  :'runtime_identity'::jsonb
);
COMMIT;
SQL
```

The worker role receives schema usage, one protocol compatibility view, and eight fixed-search-path RPCs. It receives no table, source, owner, review, or action authority

## Run One Worker

```sh
export OTLET_DATABASE_URL='postgresql://otlet_worker@database.example:5432/app?sslmode=verify-full&sslrootcert=/run/secrets/database-ca.pem'
export PGPASSFILE='/run/secrets/otlet-worker.pgpass'
export OTLET_PORTABLE_WORKER_ID='customer-vpc-worker'
export OTLET_PORTABLE_PROTOCOL_VERSION='1'
export OTLET_PORTABLE_RUNTIME_IDENTITY_HASH='registered-runtime-identity-sha256'
export OTLET_MODEL_NAME='qwen35_4b'
export OTLET_MODEL_PATH='/models/Qwen3.5-4B-Q4_K_M.gguf'
export OTLET_MODEL_SHA256='registered-model-sha256'
export OTLET_PORTABLE_RUNTIME_DIR='/tmp'
export OTLET_PORTABLE_REQUIRE_TLS='1'
export OTLET_PORTABLE_RENEW_MS='1000'

otlet_worker
```

Store `database.example:5432:app:otlet_worker:replace-me` in the mounted password file and make it readable only by the worker user. `OTLET_DATABASE_URL` must be a PostgreSQL URI without a password; the worker passes that URI to `psql` while libpq reads the credential from `PGPASSFILE`. No credential enters a process argument or log, and logs omit the connection string

The process runs deployment preflight before it can claim work, rejects symlinks, hashes one open regular GGUF, and loads that verified file descriptor once at startup. Keep the model in a deployment-owned read-only mount. The reference runtime uses a 4,096-token context, 512-token batches, 128-token microbatches, and zero GPU layers. It samples Linux VmRSS before claim, before inference, and after inference. A missing sample or budget overage fails the claim or attempt without trusted output

Portable admission accepts `reasoning`, `max_tokens`, `max_attempt_ms`, `inference_cache`, `max_worker_rss_bytes`, `generation_trace`, `llama_threads`, and `llama_batch_threads`. Each task must set `inference_cache` to `false`. Tasks may omit `generation_trace` or set it to `false`. PostgreSQL rejects other options before it changes claim state, resolves missing or zero thread counts to the worker default, and returns the normalized settings for execution. The default production policy supplies a nonzero RSS budget

PostgreSQL assembles the exact prompt from the shaped snapshot and immutable task contract, then recomputes and validates the terminal identities, schema result, output, actions, and receipt lineage. It stores the database-authored requested, honored, defaulted, rejected, effective, artifact, context, thread, and RSS evidence on the claim and linked receipt

The worker permits one `psql` child at a time. It applies a 5-second connect limit, a 30-second ordinary query limit, a renewal limit of 30 seconds or the remaining attempt budget, and one 30-second deadline across all terminal retries. Requests stop at 128 MiB, stdout at 64 MiB, stderr at 64 KiB, and parsed results at 32 MiB. Each call also sets PostgreSQL statement and lock timeouts. A child that crosses its deadline is killed and reaped before the call returns

## Invoke a Configured Task

The database owner configures and activates the task, then grants the application capability to a login or inherited group role:

```sql
BEGIN;
SELECT otlet.set_administrative_change_context('Grant the application capability');
SELECT otlet.grant_application_access('app_otlet_application'::regrole);
COMMIT;
```

From an authenticated application connection, queue one known subject, commit it so the portable worker can see it, then read owned status, accepted output, safe failure guidance, and retry lineage:

```sql
BEGIN;
SELECT otlet.application_submit_task_subject(
  'procurement_summary',
  'note-1',
  'request-2026-08-02-001'
) AS job_id \gset
COMMIT;

SELECT status,
       trusted_output,
       failure_reason_code,
       failure_stage,
       failure_retryability,
       failure_owner_action,
       recommended_retry_mode,
       raw_detail_visibility,
       retry_of_job_id,
       retry_mode,
       started_at,
       finished_at
FROM otlet.application_job_status(:'job_id');

SELECT otlet.application_cancel_job(:'job_id');
```

The optional request key must contain 1 to 256 bytes and is unique for the authenticated owner. PostgreSQL hashes the submit operation, task, and subject. Repeating the same owner, key, and payload returns the prior job even after source or revision drift; reusing that key for another task or subject fails before mutation. Different authenticated owners may reuse the same key

Submission without a matching keyed job returns `0` when the subject is missing, queue admission rejects the input, or the same input has live work under the active revision. The application functions expose no source rows or raw Otlet data and grant no administrative, review/apply, worker, or further-grant authority. Job ownership follows the authenticated `session_user`; PostgreSQL stores that login and the active `SET ROLE` role in distinct provenance fields

Application status reports stable failure guidance and retry lineage without exposing raw job or receipt errors

The SQL-only owner grants the retry path with PostgreSQL privileges:

```sql
GRANT USAGE ON SCHEMA otlet TO app_otlet_operator;
GRANT EXECUTE ON FUNCTION otlet.application_retry_job(bigint, text) TO app_otlet_operator;
```

The operator can retry a terminal application job with `application_retry_job(job_id, 'original_snapshot')` or `application_retry_job(job_id, 'latest_source')`. Original-snapshot mode reuses the stored input and requires the original revision to remain active. Latest-source mode reads current source under the current revision. Both modes preserve the application's job owner, record the operator login and active role, and link the new job to the original

## Route Across Models

Register cheap and strong model workers, then use the normal selection policy:

```sql
BEGIN;
SELECT otlet.set_administrative_change_context('Route the vendor summary task');
SELECT otlet.set_model_selection_policy(
  'vendor_summary_task',
  'qwen3_1_7b',
  'qwen35_4b',
  '{"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);
COMMIT;
```

PostgreSQL assigns the cheap claim, validates the result, and completes accepted output. It records rejected output in a receipt and requeues the same job for the strong worker. PostgreSQL preserves the job ID, lease fence, retry budget, receipt history, queue accounting, and status reads

## Watch Source Rows

Create a row watch with durable automatic catch-up, then commit source changes before polling results:

```sql
BEGIN;
SELECT otlet.set_administrative_change_context('Create the vendor note watch');
CREATE TABLE vendor_notes (
  vendor_id text PRIMARY KEY,
  note text NOT NULL
);

SELECT otlet.create_watch(
  watch_name => 'vendor_note_summary',
  kind => 'row',
  instruction => 'Summarize the note',
  output_schema => '{"type":"object","required":["summary"],"additionalProperties":false,"properties":{"summary":{"type":"string"}}}'::jsonb,
  model_name => 'qwen35_4b',
  table_name => 'vendor_notes'::regclass,
  subject_column => 'vendor_id',
  runtime_options => '{"reasoning":"off","max_tokens":256,"inference_cache":false}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  input_columns => ARRAY['note']::text[]
);

INSERT INTO vendor_notes VALUES ('vendor-1', 'Customer requested a procurement summary');
COMMIT;

SELECT *
FROM otlet.semantic_index_current_rows('vendor_note_summary');

SELECT *
FROM otlet.semantic_index_status
WHERE name = 'vendor_note_summary';
```

PostgreSQL marks inserts and updates stale and writes one coalesced reconciliation entry per subject in the source transaction. A running worker replays one due entry from heartbeat after commit; admission failure backs off without losing the newest source identity. Portable completion stores the output and semantic materialization in one transaction. Deletes clear the durable entry without inference and remove prior materializations from current-row reads. Canceled jobs do not materialize

Pair watches use the same `create_watch(..., kind => 'pair')`, `refresh_semantic_join_index(...)`, `semantic_join_index_current_rows(...)`, and `semantic_join_index_plan(...)` functions as the native installation. Candidate preflight, bounded refresh, pair-source stale triggers, completion materialization, deletion reconciliation, watch export, and status are PostgreSQL-owned and work without the extension

## Run Deployment Preflight

Run the same image, mounts, network, and environment with `--preflight` before starting the supervised worker:

```sh
otlet_worker --preflight
```

A passing preflight connects through libpq, authenticates the dedicated role, checks all eight worker RPCs and the exact protocol version, verifies the runtime and model registrations, confirms TLS is active when required, hashes the local GGUF, and probes the runtime directory. It exits before starting a process incarnation, loading llama.cpp, or claiming a job

Failures are one-line JSON with a stable reason such as `database_unavailable`, `tls_verification_failed`, `credentials_rejected`, `database_contract_missing`, `protocol_incompatible`, `runtime_not_allowlisted`, `model_not_allowlisted`, `model_hash_mismatch`, or `runtime_path_unwritable`. Use `sslmode=verify-full` and a trusted CA in the libpq connection string. The deployment must block model-provider egress; the worker has no remote model client

## Pause, Drain, And Recover

The database owner controls new claims without sharing owner authority with the worker role:

```sql
SELECT otlet.set_portable_worker_control('customer-vpc-worker', 'paused');
SELECT otlet.set_portable_worker_control('customer-vpc-worker', 'running');
SELECT otlet.set_portable_worker_control('customer-vpc-worker', 'draining');
```

Pause lets the current claim finish and blocks the next claim. Drain also lets the current claim finish, records `drained`, and exits the process. After preflight, PostgreSQL issues the process a nonce and stores only its hash. Starting a replacement under the same worker ID marks the prior process claims replaced and rejects its next heartbeat, claim, renewal, attempt, completion, failure, or cancellation RPC

The worker converts the database-issued `max_attempt_ms` to one monotonic deadline before the claim RPC. Prompt decode, generation, the llama abort callback, and renewal share it. PostgreSQL refuses renewal after its claim-time deadline, and a timeout records `attempt_timeout` in the job, receipt selection reason, failed schema status, and trace. The redacted status reports `otlet.failure.v1.attempt_timeout` and keeps raw detail database-owner-only. Cancellation interrupts decode and finishes through the fenced cancel RPC. A renewal rejected before the deadline, a fenced incarnation, or a database disconnect interrupts decode without a terminal write, leaving the lease available for safe reclaim. Exact terminal requests retry three times inside one bounded deadline, and PostgreSQL returns the stored terminal result for duplicate delivery

The continuous process reconnects after PostgreSQL restarts. `--once` fails on a database disconnect so batch callers receive a nonzero exit instead of an indefinite wait

Inspect the process, incarnation hash, model, queue, and lease state without exposing the raw process nonce, prompt text, or claim tokens:

```sql
SELECT * FROM otlet.portable_worker_status;
SELECT * FROM otlet.portable_claim_status ORDER BY claim_id DESC;
```

Worker logs contain one-line JSON events with IDs and bounded reason codes. They omit database credentials and connection strings, llama.cpp diagnostics, raw prompts, and source evidence

See [the customer-VPC example](../../docs/examples/customer-vpc-portable-worker/README.md) for a small container deployment and [the production contract](../../docs/production-contract.md) for the trust boundary

## Run The Real Smoke Test

After `./scripts/otlet-setup.sh` has placed the demo GGUF in Docker, run:

```sh
./scripts/otlet-portable-worker-demo.sh
```

The script creates a disposable SQL-only database, builds the worker, and runs real local inference through direct, cheap-to-strong, row-watch, and pair-watch paths. It proves pre-claim rejection without claim mutation, normalized thread settings, exact artifact and context evidence, fail-closed RSS sampling, database-authored option status, and an absolute attempt timeout after a successful renewal with one receipt and no output. The timeout check requires matching `otlet.failure.v1.attempt_timeout` metadata, raw-detail availability, and `database_owner_only` visibility. The script also covers receipt lineage, semantic reads, update and delete reconciliation, worker controls, restart and reclaim, duplicate delivery, source denial, and logs without credentials, connection strings, or source evidence before dropping the database and roles

Run the isolated deployment-preflight proof:

```sh
./scripts/otlet-portable-preflight-demo.sh
```

It starts a TLS-enabled disposable PostgreSQL on an internal-only Docker network, proves a valid configuration leaves a queued job unclaimed, then breaks connectivity, TLS, credentials, grants, protocol, runtime identity, model registration, artifact access, runtime storage, and client availability one dependency at a time

Run the repeat-install proof:

```sh
./scripts/otlet-portable-upgrade-demo.sh
```

It installs through migration `0070`, grants existing operator and application roles plus a partial audit role, applies `0071`, grants a reviewer role, and repeats the current install. The proof checks all 71 migrations, existing data and grants, blinded reviewer calibration, review sampling, evidence-linked decisions, lifecycle, administrative-ledger, workload-acceptance and candidate-set promotion fences, entity-resolution quality decomposition, pair constraints, entity-graph conflict status and gates, bounded validators, queued ask behavior, `PUBLIC` closure, and invariants
