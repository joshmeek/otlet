# Customer-VPC Portable Worker

This example runs one Otlet worker beside an RDS-like PostgreSQL service. The service allows SQL and PL/pgSQL and blocks native extension workers. The example contains one Dockerfile and one run command

## Network Shape

- Place the worker in a private subnet that can resolve and reach the database endpoint on port 5432
- Allow database ingress only from the worker security group
- Give the worker no inbound listener or public IP
- Mount one GGUF from VPC-local storage, the database CA bundle, and the libpq password file as read-only files
- Keep model-provider egress closed because inference is local

Install [the portable SQL contract](../../../crates/otlet_worker/README.md), create the dedicated login, register the exact worker identity, and register the model artifact before starting the container

## Build And Run

Build from the repository root so the Dockerfile can copy the workspace:

```sh
docker build \
  -f docs/examples/customer-vpc-portable-worker/Dockerfile \
  -t otlet-portable-worker:0.1.0 \
  .
```

Copy `worker.env.example` outside the checkout, replace every placeholder, and keep the file out of source control. Create `/run/secrets/otlet-worker.pgpass` outside the checkout with mode `0600` and this libpq password-file entry:

```text
database.example:5432:app:otlet_worker:replace-me
```

Then run one process:

```sh
docker run --rm \
  --env-file /run/secrets/otlet-worker.env \
  --mount type=bind,src=/srv/models,dst=/models,readonly \
  --mount type=bind,src=/run/secrets/rds-ca.pem,dst=/run/secrets/rds-ca.pem,readonly \
  --mount type=bind,src=/run/secrets/otlet-worker.pgpass,dst=/run/secrets/otlet-worker.pgpass,readonly \
  otlet-portable-worker:0.1.0 --preflight

docker run --rm \
  --env-file /run/secrets/otlet-worker.env \
  --mount type=bind,src=/srv/models,dst=/models,readonly \
  --mount type=bind,src=/run/secrets/rds-ca.pem,dst=/run/secrets/rds-ca.pem,readonly \
  --mount type=bind,src=/run/secrets/otlet-worker.pgpass,dst=/run/secrets/otlet-worker.pgpass,readonly \
  otlet-portable-worker:0.1.0
```

The first command must emit `preflight_passed` and exit without starting a process incarnation or claiming work. The passwordless libpq connection string uses `sslmode=verify-full` and the mounted CA while `PGPASSFILE` supplies the credential. The worker rejects a connection URI containing a password. No credential enters a process argument or log, and logs omit the connection string. The worker has no HTTP client or model-provider credential and must run in a subnet or network policy that blocks model-provider egress. It reconnects after a database restart and exits after an owner-requested drain. Database networking, credentials, CA distribution, model distribution, process supervision, and log collection remain customer-VPC responsibilities

Use `otlet.set_portable_worker_control(...)` to pause, resume, or drain the process. Monitor `otlet.portable_worker_status` for heartbeat, model, queue, lease, and process-incarnation health. Starting a replacement process with the same registered worker identity receives a new server nonce and fences the old process. The process emits one-line JSON logs without prompt, source evidence, or connection data

Each process loads one model. Run a separate registered identity and role for each additional model, including cheap and strong workers used by a selection policy. PostgreSQL routes jobs and performs the atomic handoff
