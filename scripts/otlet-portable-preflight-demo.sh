#!/usr/bin/env bash
set -euo pipefail

database_container="otlet-portable-preflight-db-$$"
network="otlet-portable-preflight-$$"
worker_image="otlet-portable-worker:item20"
database_image="${OTLET_PG_IMAGE:-otlet-postgres-dev:18.4-trixie}"
database="otlet_preflight"
worker_role="otlet_preflight_worker"
ungranted_role="otlet_preflight_ungranted"
worker_id="portable-preflight-worker"
ungranted_worker_id="portable-preflight-ungranted"
model_name="portable_preflight_model"
worker_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
ungranted_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
cert_dir="$(mktemp -d)"
diagnostics=""

cleanup() {
  docker rm -f "$database_container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf -- "$cert_dir"
}

trap cleanup EXIT

probe() {
  local label="$1"
  local expected="$2"
  shift 2
  local output status reason

  set +e
  output="$(
    docker run --rm \
      --network "$network" \
      -v "$cert_dir:/run/certs:ro" \
      -v "$cert_dir:/models:ro" \
      -e "OTLET_DATABASE_URL=$database_url" \
      -e "OTLET_PORTABLE_WORKER_ID=$worker_id" \
      -e OTLET_PORTABLE_PROTOCOL_VERSION=1 \
      -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$runtime_identity_hash" \
      -e "OTLET_MODEL_NAME=$model_name" \
      -e OTLET_MODEL_PATH=/models/preflight.gguf \
      -e "OTLET_MODEL_SHA256=$model_sha256" \
      -e OTLET_PORTABLE_RUNTIME_DIR=/tmp \
      -e OTLET_PORTABLE_REQUIRE_TLS=1 \
      -e OTLET_PORTABLE_EGRESS_MODE=deny_model_providers \
      "$@" \
      "$worker_image" --preflight 2>&1
  )"
  status=$?
  set -e

  if [ "$expected" = "passed" ]; then
    if [ "$status" != "0" ] || ! printf '%s\n' "$output" | jq -e \
      'select(.event == "preflight_passed" and .tls_required == true and .egress_mode == "deny_model_providers")' >/dev/null; then
      echo "Expected valid portable preflight, got $output" >&2
      exit 1
    fi
  else
    reason="$(printf '%s\n' "$output" | jq -r 'select(.event == "preflight_failed") | .reason' | tail -n 1)"
    if [ "$status" = "0" ] || [ "$reason" != "$expected" ]; then
      echo "Expected $label diagnostic $expected, got status=$status output=$output" >&2
      exit 1
    fi
  fi
  diagnostics="${diagnostics}${diagnostics:+,}${label}=${expected}"
}

docker rm -f "$database_container" >/dev/null 2>&1 || true
docker network rm "$network" >/dev/null 2>&1 || true

openssl req -x509 -newkey rsa:2048 -nodes \
  -subj '/CN=Otlet portable preflight CA' \
  -keyout "$cert_dir/ca.key" \
  -out "$cert_dir/ca.crt" \
  -days 1 >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes \
  -subj '/CN=database' \
  -addext 'subjectAltName=DNS:database' \
  -keyout "$cert_dir/server.key" \
  -out "$cert_dir/server.csr" >/dev/null 2>&1
openssl x509 -req \
  -in "$cert_dir/server.csr" \
  -CA "$cert_dir/ca.crt" \
  -CAkey "$cert_dir/ca.key" \
  -CAcreateserial \
  -copy_extensions copy \
  -out "$cert_dir/server.crt" \
  -days 1 >/dev/null 2>&1
openssl rand -out "$cert_dir/preflight.gguf" 128
model_sha256="$(shasum -a 256 "$cert_dir/preflight.gguf" | awk '{print $1}')"
model_bytes="$(stat -f %z "$cert_dir/preflight.gguf" 2>/dev/null || stat -c %s "$cert_dir/preflight.gguf")"

docker build --provenance=false \
  -f examples/customer-vpc-portable-worker/Dockerfile \
  -t "$worker_image" . >/dev/null
docker network create --internal "$network" >/dev/null
docker run -d \
  --name "$database_container" \
  --network "$network" \
  --network-alias database \
  --entrypoint sh \
  -e POSTGRES_PASSWORD=postgres \
  -v "$PWD:/work:ro" \
  -v "$cert_dir:/bootstrap:ro" \
  "$database_image" \
  -c 'cp /bootstrap/server.crt /tmp/otlet-server.crt
      cp /bootstrap/server.key /tmp/otlet-server.key
      chown postgres:postgres /tmp/otlet-server.crt /tmp/otlet-server.key
      chmod 600 /tmp/otlet-server.key
      exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/otlet-server.crt -c ssl_key_file=/tmp/otlet-server.key' >/dev/null

for _ in {1..100}; do
  docker exec "$database_container" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && break
  sleep 0.1
done
if ! docker exec "$database_container" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
  docker logs --tail 120 "$database_container" >&2
  exit 1
fi

docker exec "$database_container" createdb -h 127.0.0.1 -U postgres "$database"
docker exec -w /work "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 -f portable/install.sql
runtime_identity="$(docker run --rm "$worker_image" --print-runtime-identity)"

docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -v worker_role="$worker_role" \
  -v worker_password="$worker_password" \
  -v ungranted_role="$ungranted_role" \
  -v ungranted_password="$ungranted_password" \
  -v worker_id="$worker_id" \
  -v ungranted_worker_id="$ungranted_worker_id" \
  -v model_name="$model_name" \
  -v model_sha256="$model_sha256" \
  -v model_bytes="$model_bytes" \
  -v runtime_identity="$runtime_identity" <<'SQL' >/dev/null
SELECT format(
  'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  :'worker_role',
  :'worker_password'
) \gexec
SELECT format(
  'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
  :'ungranted_role',
  :'ungranted_password'
) \gexec
SELECT otlet.register_model(
  :'model_name',
  '/models/preflight.gguf',
  :'model_sha256',
  jsonb_build_object(
    'sha256', :'model_sha256',
    'bytes', :'model_bytes'::bigint,
    'source', 'local-preflight',
    'revision', 'fixture-v1',
    'quantization', 'fixture',
    'license', 'test'
  )
);
SELECT otlet.grant_portable_worker_access(:'worker_role'::regrole);
SELECT otlet.register_portable_worker(
  :'worker_id',
  :'worker_role'::regrole,
  1,
  :'model_name',
  'otlet-portable-worker',
  '0.1.0',
  :'runtime_identity'::jsonb
);
SELECT otlet.register_portable_worker(
  :'ungranted_worker_id',
  :'ungranted_role'::regrole,
  1,
  :'model_name',
  'otlet-portable-worker',
  '0.1.0',
  :'runtime_identity'::jsonb
);
SELECT otlet.create_task(
  'portable_preflight_task',
  NULL,
  'Return status ok',
  '{"type":"object","required":["status"],"properties":{"status":{"const":"ok"}}}'::jsonb,
  :'model_name'
);
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('portable_preflight_task', 'preflight-queued', '{}'::jsonb);
SQL

runtime_identity_hash="$(
  docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" -X -qAt \
    -v ON_ERROR_STOP=1 -v worker_id="$worker_id" <<'SQL'
SELECT runtime_identity_hash
FROM otlet.portable_workers
WHERE worker_id = :'worker_id';
SQL
)"
ungranted_identity_hash="$(
  docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" -X -qAt \
    -v ON_ERROR_STOP=1 -v worker_id="$ungranted_worker_id" <<'SQL'
SELECT runtime_identity_hash
FROM otlet.portable_workers
WHERE worker_id = :'worker_id';
SQL
)"
database_url="postgresql://${worker_role}:${worker_password}@database:5432/${database}?connect_timeout=3&sslmode=verify-full&sslrootcert=/run/certs/ca.crt"

probe valid passed
probe dns dns_resolution_failed \
  -e "OTLET_DATABASE_URL=postgresql://${worker_role}:${worker_password}@missing-otlet-host:5432/${database}?connect_timeout=3&sslmode=verify-full&sslrootcert=/run/certs/ca.crt"
probe network database_unreachable \
  -e "OTLET_DATABASE_URL=postgresql://${worker_role}:${worker_password}@database:6543/${database}?connect_timeout=3&sslmode=verify-full&sslrootcert=/run/certs/ca.crt"
probe tls_mode tls_mode_invalid \
  -e "OTLET_DATABASE_URL=postgresql://${worker_role}:${worker_password}@database:5432/${database}?connect_timeout=3&sslmode=require&sslrootcert=/run/certs/ca.crt"
probe tls_ca_config tls_ca_missing \
  -e "OTLET_DATABASE_URL=postgresql://${worker_role}:${worker_password}@database:5432/${database}?connect_timeout=3&sslmode=verify-full"
probe tls_ca tls_ca_unreadable \
  -e "OTLET_DATABASE_URL=postgresql://${worker_role}:${worker_password}@database:5432/${database}?connect_timeout=3&sslmode=verify-full&sslrootcert=/run/certs/missing-ca.crt"
probe tls_hostname tls_verification_failed \
  -e "OTLET_DATABASE_URL=postgresql://${worker_role}:${worker_password}@${database_container}:5432/${database}?connect_timeout=3&sslmode=verify-full&sslrootcert=/run/certs/ca.crt"
probe credentials credentials_rejected \
  -e "OTLET_DATABASE_URL=postgresql://${worker_role}:wrong@database:5432/${database}?connect_timeout=3&sslmode=verify-full&sslrootcert=/run/certs/ca.crt"
probe role database_contract_denied \
  -e "OTLET_DATABASE_URL=postgresql://${ungranted_role}:${ungranted_password}@database:5432/${database}?connect_timeout=3&sslmode=verify-full&sslrootcert=/run/certs/ca.crt" \
  -e "OTLET_PORTABLE_WORKER_ID=$ungranted_worker_id" \
  -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$ungranted_identity_hash"
probe protocol protocol_incompatible -e OTLET_PORTABLE_PROTOCOL_VERSION=2
probe runtime runtime_not_allowlisted -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$(printf '0%.0s' {1..64})"
probe model_allowlist model_not_allowlisted -e OTLET_MODEL_NAME=unregistered_model
probe model_path model_artifact_unreadable -e OTLET_MODEL_PATH=/models/missing.gguf
probe model_hash model_hash_mismatch -e "OTLET_MODEL_SHA256=$(printf '0%.0s' {1..64})"
probe runtime_path runtime_path_unwritable -e OTLET_PORTABLE_RUNTIME_DIR=/proc
probe egress egress_policy_invalid -e OTLET_PORTABLE_EGRESS_MODE=allow
probe psql psql_unavailable -e OTLET_PSQL=/missing/psql

docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 -v worker_role="$worker_role" <<'SQL' >/dev/null
SELECT format(
  'REVOKE EXECUTE ON FUNCTION %s FROM %I',
  p.oid::regprocedure,
  :'worker_role'
)
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'otlet' AND p.proname = 'portable_fail_job'
\gexec
SQL
probe functions database_contract_missing
docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 -v worker_role="$worker_role" <<'SQL' >/dev/null
SELECT otlet.grant_portable_worker_access(:'worker_role'::regrole);
SQL

preflight_state="$(
  docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" -X -qAt \
    -v ON_ERROR_STOP=1 -v worker_id="$worker_id" <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*) FROM otlet.portable_claims),
  (SELECT status FROM otlet.jobs WHERE subject_id = 'preflight-queued'),
  (SELECT reported_state || ':' || model_status || ':' ||
          (worker_process_rss_bytes > 0)::text
   FROM otlet.portable_worker_status WHERE worker_id = :'worker_id')
);
SQL
)"
if [ "$preflight_state" != "0|queued|error:error:true" ]; then
  echo "Expected preflight to leave claims untouched, got $preflight_state" >&2
  exit 1
fi
if [ "$(docker network inspect -f '{{.Internal}}' "$network")" != "true" ]; then
  echo "Expected internal-only preflight network" >&2
  exit 1
fi

echo "portable_preflight_contract=$preflight_state|egress=denied|$diagnostics"
