# Portable Worker

Use this path when PostgreSQL allows ordinary SQL but cannot load the native Otlet extension worker. The reference worker connects through `psql`, claims one model's bounded snapshots, runs one local GGUF with llama.cpp, and submits results through the fenced portable RPCs

The first scope is one worker process, one database, and one registered model. It has no remote model API and no direct access to source or Otlet tables

## Install The SQL Contract

Run the installer as the database owner from the repository checkout:

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f portable/install.sql
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
export OTLET_PORTABLE_EGRESS_MODE='deny_model_providers'
export OTLET_PORTABLE_RENEW_MS='1000'

otlet_worker
```

The process runs deployment preflight before it can claim work, then verifies the GGUF digest before loading it. PostgreSQL assembles the exact prompt from the shaped snapshot and task contract, then recomputes and validates the terminal identities, schema result, output, actions, and receipt lineage

## Run Deployment Preflight

Run the same image, mounts, network, and environment with `--preflight` before starting the supervised worker:

```sh
otlet_worker --preflight
```

A passing preflight resolves and reaches the database, negotiates hostname-verified TLS with the configured CA, authenticates the dedicated role, checks all seven worker RPCs and the exact protocol version, verifies the runtime and model registrations, hashes the local GGUF, probes the runtime directory, and requires the declared `deny_model_providers` egress policy. It exits before loading llama.cpp or claiming a job

Failures are one-line JSON with a stable reason such as `dns_resolution_failed`, `database_unreachable`, `tls_verification_failed`, `credentials_rejected`, `database_contract_missing`, `protocol_incompatible`, `runtime_not_allowlisted`, `model_not_allowlisted`, `model_hash_mismatch`, or `runtime_path_unwritable`. The deployment must enforce the declared egress policy; the worker has no remote model client to test

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
SELECT * FROM otlet.database_health_status;
```

Worker heartbeats report process RSS, and the shared database-health gate pauses new claims when an owner-configured limit fails. Existing claims retain their lease and cancellation behavior. Worker logs are one-line JSON events with IDs and bounded reason codes. llama.cpp diagnostics and raw prompt or source evidence are not written to the worker log

Accepted portable receipts also appear in `otlet.decision_trace_export`. Run `scripts/otlet-export-decision.sh` from the repository host to create a local signed SQL and CSV bundle; signing keys remain outside the database and network delivery remains a separate deployment concern

Register each outbound receiver with `otlet.register_destination_export(...)`, then inspect `otlet.destination_reconciliation_status`. The signed envelope carries the stable receiver idempotency key. `scripts/otlet-record-destination-ack.sh` verifies signed receiver acknowledgements before recording their state, execution receipt, and replay decision

See [the customer-VPC example](../examples/customer-vpc-portable-worker/README.md) for a small container deployment and [the production contract](../docs/production-contract.md) for the trust boundary

## Run The Real Smoke Test

After `./scripts/otlet-setup.sh` has placed the demo GGUF in Docker, run:

```sh
./scripts/otlet-portable-worker-demo.sh
```

The script creates a disposable SQL-only database, builds the worker, runs real local inference, and checks trusted receipt lineage. It also proves pause, resume, cancellation, claim loss, process restart, database restart, reclaim, duplicate delivery, drain, source denial, and redacted structured logs before dropping the database and role

Run the isolated deployment-preflight proof separately:

```sh
./scripts/otlet-portable-preflight-demo.sh
```

It starts a TLS-enabled disposable PostgreSQL on an internal-only Docker network, proves a valid configuration leaves a queued job unclaimed, then breaks DNS, reachability, TLS, credentials, grants, protocol, runtime identity, model registration, artifact access, runtime storage, egress declaration, and client availability one dependency at a time
