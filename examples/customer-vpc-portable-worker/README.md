# Customer-VPC Portable Worker

This example runs one Otlet worker beside an RDS-like PostgreSQL service where SQL and PL/pgSQL are available and native extension worker loading is blocked. The example contains one Dockerfile and one run command

## Network Shape

- Place the worker in a private subnet that can resolve and reach the database endpoint on port 5432
- Allow database ingress only from the worker security group
- Give the worker no inbound listener or public IP
- Mount one GGUF from VPC-local storage and the database CA bundle as read-only files
- Keep model-provider egress closed because inference is local

Install [the portable SQL contract](../../portable/README.md), create the dedicated login, register the exact worker identity, and register the model artifact before starting the container

## Build And Run

Build from the repository root so the Dockerfile can copy the workspace:

```sh
docker build \
  -f examples/customer-vpc-portable-worker/Dockerfile \
  -t otlet-portable-worker:0.1.0 \
  .
```

Copy `worker.env.example` outside the checkout, replace every placeholder, and keep the file out of source control. Then run one process:

```sh
docker run --rm \
  --env-file /run/secrets/otlet-worker.env \
  --mount type=bind,src=/srv/models,dst=/models,readonly \
  --mount type=bind,src=/run/secrets/rds-ca.pem,dst=/run/secrets/rds-ca.pem,readonly \
  otlet-portable-worker:0.1.0 --preflight

docker run --rm \
  --env-file /run/secrets/otlet-worker.env \
  --mount type=bind,src=/srv/models,dst=/models,readonly \
  --mount type=bind,src=/run/secrets/rds-ca.pem,dst=/run/secrets/rds-ca.pem,readonly \
  otlet-portable-worker:0.1.0
```

The first command must emit `preflight_passed` and exit without claiming work. The libpq connection string uses `sslmode=verify-full` and the mounted CA. The worker requires the `deny_model_providers` egress declaration, has no HTTP client or model-provider credential, and must run in a subnet or network policy that blocks model-provider egress. It reconnects after a database restart and exits after an owner-requested drain. Database networking, credentials, CA distribution, model distribution, process supervision, and log collection remain customer-VPC responsibilities

Use `otlet.set_portable_worker_control(...)` to pause, resume, or drain the process. Monitor `otlet.portable_worker_status` for heartbeat, model, queue, and lease health. The process emits one-line JSON logs without prompt or source evidence

This first deployment supports one process, one database, and one model. Use a separate registered identity and role for each additional worker
