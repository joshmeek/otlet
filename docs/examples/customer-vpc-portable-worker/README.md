# Customer-VPC Portable Worker

This example runs one Otlet worker beside an RDS-like PostgreSQL service. The service allows SQL and PL/pgSQL and blocks native extension workers. The example contains one Dockerfile and one run command

## Network Shape

- Place the worker in a private subnet that can resolve and reach the database endpoint on port 5432
- Allow database ingress only from the worker security group
- Give the worker no inbound listener or public IP
- Mount one GGUF from VPC-local storage, the database CA bundle, and the libpq credential directory as read-only paths
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

Copy `worker.env.example` outside the checkout, replace every placeholder, and keep the file out of source control. Set `PGPASSFILE=/run/credentials/worker.pgpass`. Create `/run/secrets/otlet-worker/worker.pgpass` outside the checkout, make it readable by container UID `10001`, and set mode `0600` with this libpq password-file entry:

```text
database.example:5432:app:otlet_worker:replace-me
```

Then run one process:

```sh
docker run --rm \
  --env-file /run/secrets/otlet-worker.env \
  --mount type=bind,src=/srv/models,dst=/models,readonly \
  --mount type=bind,src=/run/secrets/rds-ca.pem,dst=/run/secrets/rds-ca.pem,readonly \
  --mount type=bind,src=/run/secrets/otlet-worker,dst=/run/credentials,readonly \
  otlet-portable-worker:0.1.0 --preflight

docker run --rm \
  --env-file /run/secrets/otlet-worker.env \
  --mount type=bind,src=/srv/models,dst=/models,readonly \
  --mount type=bind,src=/run/secrets/rds-ca.pem,dst=/run/secrets/rds-ca.pem,readonly \
  --mount type=bind,src=/run/secrets/otlet-worker,dst=/run/credentials,readonly \
  otlet-portable-worker:0.1.0
```

The first command must emit `preflight_passed` and exit without starting a process incarnation or claiming work. The passwordless libpq connection string uses `sslmode=verify-full` and the mounted CA while `PGPASSFILE` supplies the credential. The worker rejects a connection URI containing a password. No credential enters a process argument or log, and logs omit the connection string. The worker has no HTTP client or model-provider credential and must run in a subnet or network policy that blocks model-provider egress. It reconnects after a database restart and exits after an owner-requested drain. Database networking, credentials, CA distribution, model distribution, process supervision, and log collection remain customer-VPC responsibilities

For password rotation, write a mode-`0600` temporary file owned by UID `10001` on the host side of the mounted credential directory, then atomically rename it over `worker.pgpass`. Mounting the directory lets the running container see the new inode. After successful preflight, a continuous worker reconnects between claims and while draining because each fresh `psql` call rereads the file. Credential rejection during renewal abandons the claim and stops inference. Initial credential rejection remains fatal

For role rotation, provision a distinct login and worker ID, register its `portable_worker` capability, and preflight it. Require both workers ready in `otlet.portable_worker_status`, both roles reconciled in `otlet.access_policy_role_status`, and `portable_eligible_workers = 2` with `route_ready` in `otlet.route_readiness_status` before draining the old worker. Wait for `reported_state = 'drained'` and `live_claims = 0`, disable it, then call `otlet.revoke_access_policy_capability(old_role, 'portable_worker', reason)`. Deployment IAM owns secret issuance, storage, and revocation

Use `otlet.set_portable_worker_control(...)` to pause, resume, or drain the process. Monitor `otlet.portable_worker_status` for heartbeat, model, queue, lease, and process-incarnation health. Starting a replacement process with the same registered worker identity receives a new server nonce and fences the old process. The process emits one-line JSON logs without prompt, source evidence, or connection data

Each process loads one model. Run a separate registered identity and role for each additional model, including cheap and strong workers used by a selection policy. PostgreSQL routes jobs and performs the atomic handoff
