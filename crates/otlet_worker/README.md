# Portable Worker

The portable worker covers Otlet's asynchronous SQL surface: one-off inference, row and pair watches, model-selection escalation, materialization, semantic reads and predicates, receipts, actions, evaluation, status, cleanup, export, cancellation, and restart recovery

Use this path when PostgreSQL allows ordinary SQL but cannot load the native Otlet extension worker. The reference worker connects through `psql`, claims one model's bounded snapshots, runs one local GGUF with llama.cpp, and submits results through the fenced portable RPCs

Synchronous `otlet.ask(...)`, CustomScan, and infer-now remain native-only because they require an in-process PostgreSQL worker or extension hooks. Portable callers use committed queues and the same SQL read functions

Each process loads one registered model. Register a separate role and worker identity for each additional model. The worker has no remote model API and no direct access to source or Otlet tables

## Install The SQL Contract

Run the installer as the database owner from the repository checkout:

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f crates/otlet_worker/sql/install.sql
```

The install transaction creates the task, job, receipt, review, action, evaluation, freshness, and portable protocol state with SQL and PL/pgSQL only. The database keeps zero `otlet` extension objects and zero C-language Otlet functions

## Register The Worker

Create one dedicated login with `NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`. Register the model first, then grant and bind the worker:

```sql
SELECT otlet.grant_portable_worker_access('otlet_worker'::regrole);

SELECT otlet.register_portable_worker(
  'customer-vpc-worker',
  'otlet_worker'::regrole,
  1,
  'qwen35_4b',
  'otlet-portable-worker',
  '0.1.0',
  '{"engine":"llama.cpp","protocol_version":1,"transport":"postgres_psql","worker":"otlet-portable-worker","worker_version":"0.1.0"}'::jsonb
);
```

Read the exact runtime identity from the binary:

```sh
otlet_worker --print-runtime-identity
```

The worker role receives schema usage, one protocol compatibility view, and seven fixed-search-path RPCs. It receives no table, source, owner, review, or action authority

## Run One Worker

```sh
export OTLET_DATABASE_URL='postgresql://otlet_worker:replace-me@database.example:5432/app?sslmode=verify-full&sslrootcert=/run/secrets/database-ca.pem'
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

The process runs deployment preflight before it can claim work, then verifies the GGUF digest before loading it. PostgreSQL assembles the exact prompt from the shaped snapshot and task contract, then recomputes and validates the terminal identities, schema result, output, actions, and receipt lineage

## Enqueue One-Off Inference

Portable workers cannot see work created inside the open transaction used by synchronous `otlet.ask(...)`. Queue the request, commit it, then read status and trusted output from `otlet.runs`:

```sql
BEGIN;
SELECT otlet.enqueue_ask(
  'qwen35_4b',
  'Summarize the note',
  '{"note":"Customer requested a procurement summary"}',
  '{"type":"object","required":["summary"],"additionalProperties":false,"properties":{"summary":{"type":"string"}}}'
) AS job_id \gset
COMMIT;

SELECT status, output, receipt_id, error
FROM otlet.runs
WHERE job_id = :'job_id';
```

`enqueue_ask(...)` returns `0` when queue admission rejects the request. It uses the same task, input shaping, queue limits, PostgreSQL validation, receipt, and cancellation state as other jobs

## Route Across Models

Register cheap and strong model workers, then use the normal selection policy:

```sql
SELECT otlet.set_model_selection_policy(
  'vendor_summary_task',
  'qwen3_1_7b',
  'qwen35_4b',
  '{"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);
```

PostgreSQL assigns the cheap claim, validates its result, and either accepts it or records a rejected receipt before requeuing the same job for the strong worker. The handoff preserves the job ID, lease fencing, retry budget, receipt history, queue accounting, and status reads

## Watch Source Rows

Create a row watch with automatic enqueue, then commit source changes before polling results:

```sql
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
  trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  input_columns => ARRAY['note']::text[]
);

INSERT INTO vendor_notes VALUES ('vendor-1', 'Customer requested a procurement summary');

SELECT *
FROM otlet.semantic_index_current_rows('vendor_note_summary');

SELECT *
FROM otlet.semantic_index_status
WHERE name = 'vendor_note_summary';
```

PostgreSQL queues inserts and updates in the source transaction, so the external worker sees them after commit. Portable completion stores the output and semantic materialization in one transaction. Deletes mark prior materializations stale and remove them from current-row reads. Canceled jobs do not materialize

Pair watches use the same `create_watch(..., kind => 'pair')`, `refresh_semantic_join_index(...)`, `semantic_join_index_current_rows(...)`, and `semantic_join_index_plan(...)` functions as the native installation. Candidate preflight, bounded refresh, pair-source stale triggers, completion materialization, deletion reconciliation, watch export, and status are PostgreSQL-owned and work without the extension

## Run Deployment Preflight

Run the same image, mounts, network, and environment with `--preflight` before starting the supervised worker:

```sh
otlet_worker --preflight
```

A passing preflight connects through libpq, authenticates the dedicated role, checks all seven worker RPCs and the exact protocol version, verifies the runtime and model registrations, confirms TLS is active when required, hashes the local GGUF, and probes the runtime directory. It exits before loading llama.cpp or claiming a job

Failures are one-line JSON with a stable reason such as `database_unavailable`, `tls_verification_failed`, `credentials_rejected`, `database_contract_missing`, `protocol_incompatible`, `runtime_not_allowlisted`, `model_not_allowlisted`, `model_hash_mismatch`, or `runtime_path_unwritable`. Use `sslmode=verify-full` and a trusted CA in the libpq connection string. The deployment must block model-provider egress; the worker has no remote model client

## Pause, Drain, And Recover

The database owner controls new claims without sharing owner authority with the worker role:

```sql
SELECT otlet.set_portable_worker_control('customer-vpc-worker', 'paused');
SELECT otlet.set_portable_worker_control('customer-vpc-worker', 'running');
SELECT otlet.set_portable_worker_control('customer-vpc-worker', 'draining');
```

Pause lets the current claim finish and blocks the next claim. Drain also lets the current claim finish, records `drained`, and exits the process. A supervisor can then restart or replace the container

The worker renews each live claim while llama.cpp runs. Cancellation interrupts decode and finishes through the fenced cancel RPC. A rejected renewal or database disconnect interrupts decode without a terminal write, leaving the lease available for safe reclaim. Exact terminal requests retry three times, and PostgreSQL returns the stored terminal result for duplicate delivery

The continuous process reconnects after PostgreSQL restarts. `--once` fails on a database disconnect so batch callers receive a nonzero exit instead of an indefinite wait

Inspect the process, model, queue, and lease state without exposing prompt text or claim tokens:

```sql
SELECT * FROM otlet.portable_worker_status;
SELECT * FROM otlet.portable_claim_status ORDER BY claim_id DESC;
```

Worker logs contain one-line JSON events with IDs and bounded reason codes. They omit llama.cpp diagnostics, raw prompts, and source evidence

See [the customer-VPC example](../../docs/examples/customer-vpc-portable-worker/README.md) for a small container deployment and [the production contract](../../docs/production-contract.md) for the trust boundary

## Run The Real Smoke Test

After `./scripts/otlet-setup.sh` has placed the demo GGUF in Docker, run:

```sh
./scripts/otlet-portable-worker-demo.sh
```

The script creates a disposable SQL-only database, builds the worker, and runs real local inference through direct, cheap-to-strong, row-watch, and pair-watch paths. It also proves receipt lineage, semantic reads, update and delete reconciliation, pause, resume, cancellation, claim loss, process restart, database restart, reclaim, duplicate delivery, drain, source denial, and redacted structured logs before dropping the database and roles

Run the isolated deployment-preflight proof:

```sh
./scripts/otlet-portable-preflight-demo.sh
```

It starts a TLS-enabled disposable PostgreSQL on an internal-only Docker network, proves a valid configuration leaves a queued job unclaimed, then breaks connectivity, TLS, credentials, grants, protocol, runtime identity, model registration, artifact access, runtime storage, and client availability one dependency at a time
