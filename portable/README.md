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
export OTLET_DATABASE_URL='postgresql://otlet_worker:replace-me@database.example:5432/app?sslmode=verify-full'
export OTLET_PORTABLE_WORKER_ID='customer-vpc-worker'
export OTLET_PORTABLE_PROTOCOL_VERSION='1'
export OTLET_PORTABLE_RUNTIME_IDENTITY_HASH='registered-runtime-identity-sha256'
export OTLET_MODEL_NAME='qwen35_4b'
export OTLET_MODEL_PATH='/models/Qwen3.5-4B-Q4_K_M.gguf'
export OTLET_MODEL_SHA256='registered-model-sha256'
export OTLET_PORTABLE_RENEW_MS='1000'

otlet_worker
```

The process verifies the GGUF digest before loading it. PostgreSQL assembles the exact prompt from the shaped snapshot and task contract, then recomputes and validates the terminal identities, schema result, output, actions, and receipt lineage

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

Worker logs are one-line JSON events with IDs and bounded reason codes. llama.cpp diagnostics and raw prompt or source evidence are not written to the worker log

See [the customer-VPC example](../examples/customer-vpc-portable-worker/README.md) for a small container deployment and [the production contract](../docs/production-contract.md) for the trust boundary

## Run The Real Smoke Test

After `./scripts/otlet-setup.sh` has placed the demo GGUF in Docker, run:

```sh
./scripts/otlet-portable-worker-demo.sh
```

The script creates a disposable SQL-only database, builds the worker, runs real local inference, and checks trusted receipt lineage. It also proves pause, resume, cancellation, claim loss, process restart, database restart, reclaim, duplicate delivery, drain, source denial, and redacted structured logs before dropping the database and role
