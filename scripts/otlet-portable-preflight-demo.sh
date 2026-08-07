#!/usr/bin/env bash
set -euo pipefail

database_container="otlet-portable-preflight-db-$$"
network="otlet-portable-preflight-$$"
credential_volume="otlet-portable-preflight-credentials-$$"
credential_worker_container="otlet-portable-credential-worker-$$"
worker_image="otlet-portable-worker:item20"
database_image="${OTLET_PG_IMAGE:-otlet-postgres-dev:18.4-trixie}"
database="otlet_preflight"
worker_role="otlet_preflight_worker"
ungranted_role="otlet_preflight_ungranted"
worker_id="portable-preflight-worker"
ungranted_worker_id="portable-preflight-ungranted"
model_name="portable_preflight_model"
worker_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
worker_password_next="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
ungranted_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
cert_dir="$(mktemp -d)"
worker_credential_env="$cert_dir/worker.env"
wrong_credential_env="$cert_dir/wrong.env"
ungranted_credential_env="$cert_dir/ungranted.env"
diagnostics=""
all_probe_output=""

cleanup() {
  docker rm -f "$credential_worker_container" >/dev/null 2>&1 || true
  docker rm -f "$database_container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm -f "$credential_volume" >/dev/null 2>&1 || true
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
      --env-file "${probe_credential_env:-$worker_credential_env}" \
      -v "$cert_dir:/run/certs:ro" \
      -v "$credential_volume:/run/credentials:ro" \
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
      "$@" \
      "$worker_image" --preflight 2>&1
  )"
  status=$?
  set -e
  all_probe_output="${all_probe_output}${all_probe_output:+$'\n'}${output}"

  for secret in \
    "$worker_password" \
    "$worker_password_next" \
    "$ungranted_password" \
    "${database_url:-}" \
    "${replacement_database_url:-}"; do
    if [ -n "$secret" ] && [[ "$output" == *"$secret"* ]]; then
      echo "Portable preflight log exposed connection data" >&2
      exit 1
    fi
  done

  if [ "$expected" = "passed" ]; then
    if [ "$status" != "0" ] || ! printf '%s\n' "$output" | jq -e \
      'select(.event == "preflight_passed" and .tls_required == true)' >/dev/null; then
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

write_pgpass() {
  local filename="$1"
  local role="$2"
  local password="$3"

  printf '*:*:*:%s:%s\n' "$role" "$password" |
    docker run --rm -i \
      -v "$credential_volume:/run/credentials" \
      --entrypoint sh \
      "$database_image" \
      -c "umask 077; cat >'/run/credentials/${filename}.next'; chown 10001:10001 '/run/credentials/${filename}.next'; mv '/run/credentials/${filename}.next' '/run/credentials/${filename}'"
}

docker rm -f "$database_container" >/dev/null 2>&1 || true
docker network rm "$network" >/dev/null 2>&1 || true
docker volume rm -f "$credential_volume" >/dev/null 2>&1 || true

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
ln -s preflight.gguf "$cert_dir/preflight-symlink.gguf"
printf 'PGPASSFILE=/run/credentials/worker.pgpass\n' >"$worker_credential_env"
printf 'PGPASSFILE=/run/credentials/wrong.pgpass\n' >"$wrong_credential_env"
printf 'PGPASSFILE=/run/credentials/replacement.pgpass\n' >"$ungranted_credential_env"
chmod 600 "$worker_credential_env" "$wrong_credential_env" "$ungranted_credential_env"
model_sha256="$(shasum -a 256 "$cert_dir/preflight.gguf" | awk '{print $1}')"
model_bytes="$(stat -f %z "$cert_dir/preflight.gguf" 2>/dev/null || stat -c %s "$cert_dir/preflight.gguf")"

docker build --provenance=false \
  -f docs/examples/customer-vpc-portable-worker/Dockerfile \
  -t "$worker_image" . >/dev/null
docker network create --internal "$network" >/dev/null
docker volume create "$credential_volume" >/dev/null
write_pgpass worker.pgpass "$worker_role" "$worker_password"
write_pgpass wrong.pgpass "$worker_role" wrong
write_pgpass replacement.pgpass "$ungranted_role" "$ungranted_password"
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
docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d postgres \
  -X -q -v ON_ERROR_STOP=1 -v database="$database" <<'SQL' >/dev/null
SELECT format(
  'ALTER DATABASE %I SET otlet.administrative_reason = %L',
  :'database',
  'portable preflight executable proof'
) \gexec
SQL
docker exec -w /work "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 -f crates/otlet_worker/sql/install.sql
runtime_identity="$(docker run --rm "$worker_image" --print-runtime-identity)"

docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE ROLE $worker_role LOGIN PASSWORD '$worker_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE $ungranted_role LOGIN PASSWORD '$ungranted_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
SQL

docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -v worker_role="$worker_role" \
  -v ungranted_role="$ungranted_role" \
  -v worker_id="$worker_id" \
  -v ungranted_worker_id="$ungranted_worker_id" \
  -v model_name="$model_name" \
  -v model_sha256="$model_sha256" \
  -v model_bytes="$model_bytes" \
  -v runtime_identity="$runtime_identity" <<'SQL' >/dev/null
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
    'license', 'test',
    'context_window_tokens', 4096
  )
);
SELECT otlet.register_access_policy_capability(
  :'worker_role'::regrole,
  'portable_worker',
  'Register initial portable credential role'
);
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
  :'model_name',
  '{"inference_cache":false}'::jsonb
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
database_url="postgresql://${worker_role}@database:5432/${database}?sslmode=verify-full&sslrootcert=/run/certs/ca.crt"

probe valid passed
probe dns database_unavailable \
  -e "OTLET_DATABASE_URL=postgresql://${worker_role}@missing-otlet-host:5432/${database}?sslmode=verify-full&sslrootcert=/run/certs/ca.crt"
probe network database_unavailable \
  -e "OTLET_DATABASE_URL=postgresql://${worker_role}@database:6543/${database}?sslmode=verify-full&sslrootcert=/run/certs/ca.crt"
probe tls_hostname tls_verification_failed \
  -e "OTLET_DATABASE_URL=postgresql://${worker_role}@${database_container}:5432/${database}?sslmode=verify-full&sslrootcert=/run/certs/ca.crt"
probe_credential_env="$wrong_credential_env" probe credentials credentials_rejected
probe_credential_env="$ungranted_credential_env" probe role database_contract_denied \
  -e "OTLET_DATABASE_URL=postgresql://${ungranted_role}@database:5432/${database}?sslmode=verify-full&sslrootcert=/run/certs/ca.crt" \
  -e "OTLET_PORTABLE_WORKER_ID=$ungranted_worker_id" \
  -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$ungranted_identity_hash"
probe protocol protocol_incompatible -e OTLET_PORTABLE_PROTOCOL_VERSION=2
probe runtime runtime_not_allowlisted -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$(printf '0%.0s' {1..64})"
probe model_allowlist model_not_allowlisted -e OTLET_MODEL_NAME=unregistered_model
probe model_path model_artifact_unreadable -e OTLET_MODEL_PATH=/models/missing.gguf
probe model_symlink model_artifact_symlink_rejected -e OTLET_MODEL_PATH=/models/preflight-symlink.gguf
probe model_hash model_hash_mismatch -e "OTLET_MODEL_SHA256=$(printf '0%.0s' {1..64})"
probe runtime_path runtime_path_unwritable -e OTLET_PORTABLE_RUNTIME_DIR=/proc
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
SELECT otlet.reconcile_access_policy_role(
  :'worker_role'::regrole,
  'Repair portable credential role'
);
SQL

preflight_state="$(
  docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" -X -qAt \
    -v ON_ERROR_STOP=1 -v worker_id="$worker_id" <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*) FROM otlet.portable_claims),
  (SELECT status FROM otlet.jobs WHERE subject_id = 'preflight-queued'),
  (SELECT reported_state || ':' || model_status
   FROM otlet.portable_worker_status WHERE worker_id = :'worker_id')
);
SQL
)"
if [ "$preflight_state" != "0|queued|registered:unverified" ]; then
  echo "Expected preflight to leave claims untouched, got $preflight_state" >&2
  exit 1
fi
if [ "$(docker network inspect -f '{{.Internal}}' "$network")" != "true" ]; then
  echo "Expected internal-only preflight network" >&2
  exit 1
fi

replacement_database_url="postgresql://${ungranted_role}@database:5432/${database}?sslmode=verify-full&sslrootcert=/run/certs/ca.crt"
docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -v worker_role="$worker_role" \
  -v replacement_role="$ungranted_role" \
  -v worker_id="$worker_id" \
  -v replacement_worker_id="$ungranted_worker_id" \
  -v runtime_identity_hash="$runtime_identity_hash" \
  -v replacement_identity_hash="$ungranted_identity_hash" <<'SQL' >/dev/null
DELETE FROM otlet.jobs WHERE subject_id = 'preflight-queued';
SELECT otlet.register_access_policy_capability(
  :'replacement_role'::regrole,
  'portable_worker',
  'Register replacement portable credential role'
);

SELECT pg_catalog.set_config('otlet.probe_worker_id', :'worker_id', false);
SELECT pg_catalog.set_config(
  'otlet.probe_runtime_identity_hash',
  :'runtime_identity_hash',
  false
);
SET ROLE :"worker_role";
SELECT pg_catalog.set_config(
  'otlet.probe_old_nonce',
  started.incarnation_nonce,
  false
)
FROM otlet.portable_start_worker(
  current_setting('otlet.probe_worker_id'),
  1,
  current_setting('otlet.probe_runtime_identity_hash')
) started;
SELECT *
FROM otlet.portable_worker_heartbeat(
  current_setting('otlet.probe_worker_id'),
  1,
  current_setting('otlet.probe_runtime_identity_hash'),
  current_setting('otlet.probe_old_nonce'),
  'idle',
  'ready',
  NULL
);
SELECT *
FROM otlet.portable_claim_jobs(
  current_setting('otlet.probe_worker_id'),
  1,
  current_setting('otlet.probe_runtime_identity_hash'),
  current_setting('otlet.probe_old_nonce'),
  1048576,
  1,
  1
);
RESET ROLE;

SELECT pg_catalog.set_config(
  'otlet.probe_worker_id',
  :'replacement_worker_id',
  false
);
SELECT pg_catalog.set_config(
  'otlet.probe_runtime_identity_hash',
  :'replacement_identity_hash',
  false
);
SET ROLE :"replacement_role";
SELECT pg_catalog.set_config(
  'otlet.probe_replaced_nonce',
  started.incarnation_nonce,
  false
)
FROM otlet.portable_start_worker(
  current_setting('otlet.probe_worker_id'),
  1,
  current_setting('otlet.probe_runtime_identity_hash')
) started;
SELECT *
FROM otlet.portable_worker_heartbeat(
  current_setting('otlet.probe_worker_id'),
  1,
  current_setting('otlet.probe_runtime_identity_hash'),
  current_setting('otlet.probe_replaced_nonce'),
  'idle',
  'ready',
  NULL
);
SELECT pg_catalog.set_config(
  'otlet.probe_replacement_nonce',
  started.incarnation_nonce,
  false
)
FROM otlet.portable_start_worker(
  current_setting('otlet.probe_worker_id'),
  1,
  current_setting('otlet.probe_runtime_identity_hash')
) started;
DO $$
BEGIN
  BEGIN
    PERFORM otlet.portable_worker_heartbeat(
      current_setting('otlet.probe_worker_id'),
      1,
      current_setting('otlet.probe_runtime_identity_hash'),
      current_setting('otlet.probe_replaced_nonce'),
      'idle',
      'ready',
      NULL
    );
    RAISE EXCEPTION 'replaced portable worker nonce remained authorized';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'replaced portable worker nonce remained authorized'
       OR SQLERRM NOT LIKE '%incarnation is not authorized%' THEN
      RAISE;
    END IF;
  END;
END;
$$;
SELECT *
FROM otlet.portable_worker_heartbeat(
  current_setting('otlet.probe_worker_id'),
  1,
  current_setting('otlet.probe_runtime_identity_hash'),
  current_setting('otlet.probe_replacement_nonce'),
  'idle',
  'ready',
  NULL
);
SELECT *
FROM otlet.portable_claim_jobs(
  current_setting('otlet.probe_worker_id'),
  1,
  current_setting('otlet.probe_runtime_identity_hash'),
  current_setting('otlet.probe_replacement_nonce'),
  1048576,
  1,
  1
);
RESET ROLE;
SQL

probe_credential_env="$ungranted_credential_env" probe replacement passed \
  -e "OTLET_DATABASE_URL=$replacement_database_url" \
  -e "OTLET_PORTABLE_WORKER_ID=$ungranted_worker_id" \
  -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$ungranted_identity_hash"

credential_overlap_contract="$(
  docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v worker_id="$worker_id" \
    -v replacement_worker_id="$ungranted_worker_id" <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*)
   FROM otlet.access_policy_role_status
   WHERE registered_role_name IN (
     'otlet_preflight_worker',
     'otlet_preflight_ungranted'
   )
     AND capabilities = ARRAY['portable_worker']::text[]
     AND reconciliation_status = 'reconciled'),
  (SELECT count(*)
   FROM otlet.portable_worker_status
   WHERE worker_id IN (:'worker_id', :'replacement_worker_id')
     AND enabled
     AND desired_state = 'running'
     AND reported_state = 'idle'
     AND model_status = 'ready'
     AND current_rss_bytes = 1048576),
  (SELECT portable_eligible_workers
   FROM otlet.route_readiness_status
   WHERE task_name = 'portable_preflight_task'
     AND selection_role = 'direct'),
  (SELECT route_ready
   FROM otlet.route_readiness_status
   WHERE task_name = 'portable_preflight_task'
     AND selection_role = 'direct')
);
SQL
)"
if [ "$credential_overlap_contract" != "2|2|2|t" ]; then
  docker exec "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
    -X -x -c "SELECT * FROM otlet.route_readiness_status WHERE task_name = 'portable_preflight_task'; SELECT worker_id, enabled, desired_state, reported_state, model_status, current_rss_bytes, worker_health FROM otlet.portable_worker_status ORDER BY worker_id" >&2
  echo "Expected two ready portable credential identities, got $credential_overlap_contract" >&2
  exit 1
fi

docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 -v worker_id="$worker_id" <<'SQL' >/dev/null
SELECT otlet.set_portable_worker_control(:'worker_id', 'draining');
CREATE FUNCTION public.portable_credential_start_delay() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.worker_id = 'portable-preflight-worker'
     AND OLD.incarnation_nonce_hash IS DISTINCT FROM NEW.incarnation_nonce_hash THEN
    PERFORM pg_sleep(5);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER portable_credential_start_delay
BEFORE UPDATE ON otlet.portable_workers
FOR EACH ROW EXECUTE FUNCTION public.portable_credential_start_delay();
SQL

docker run -d \
  --name "$credential_worker_container" \
  --network "$network" \
  --env-file "$worker_credential_env" \
  -v "$cert_dir:/run/certs:ro" \
  -v "$credential_volume:/run/credentials:ro" \
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
  -e OTLET_PORTABLE_POLL_MS=100 \
  "$worker_image" >/dev/null

credential_start_waiting="false"
for _ in {1..200}; do
  credential_start_waiting="$(
    docker exec "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
      -X -qAt -c "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = '$database' AND wait_event = 'PgSleep' AND query LIKE '%portable_start_worker%')"
  )"
  [ "$credential_start_waiting" = "t" ] && break
  sleep 0.05
done
if [ "$credential_start_waiting" != "t" ]; then
  docker logs "$credential_worker_container" >&2 || true
  echo "Portable credential rotation did not reach the reconnect window" >&2
  exit 1
fi
credential_process_snapshot="$(docker top "$credential_worker_container" -eo pid,args 2>&1)"
credential_environment_snapshot="$(docker inspect -f '{{json .Config.Env}}' "$credential_worker_container")"

printf "ALTER ROLE %s PASSWORD '%s';\n" "$worker_role" "$worker_password_next" |
  docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
    -X -q -v ON_ERROR_STOP=1 >/dev/null

credential_worker_output=""
for _ in {1..300}; do
  credential_worker_output="$(docker logs "$credential_worker_container" 2>&1)"
  [[ "$credential_worker_output" == *'"event":"database_unavailable"'* ]] && break
  sleep 0.05
done
if [[ "$credential_worker_output" != *'"event":"database_unavailable"'* ]]; then
  printf '%s\n' "$credential_worker_output" >&2
  echo "Portable worker did not reject its rotated credential" >&2
  exit 1
fi

write_pgpass worker.pgpass "$worker_role" "$worker_password_next"
for _ in {1..400}; do
  [ "$(docker inspect -f '{{.State.Running}}' "$credential_worker_container")" = "false" ] && break
  sleep 0.05
done
if [ "$(docker inspect -f '{{.State.Running}}' "$credential_worker_container")" != "false" ]; then
  docker logs "$credential_worker_container" >&2 || true
  echo "Portable worker did not drain after credential rotation" >&2
  exit 1
fi
credential_worker_output="$(docker logs "$credential_worker_container" 2>&1)"
credential_worker_exit="$(docker inspect -f '{{.State.ExitCode}}' "$credential_worker_container")"
if [ "$credential_worker_exit" != "0" ] || ! printf '%s\n' "$credential_worker_output" | jq -s -e '
  map(.event) as $events
  | ($events | index("preflight_passed")) != null
    and ($events | index("database_unavailable")) != null
    and ($events | index("database_recovered")) != null
    and ($events | index("worker_drained")) != null
' >/dev/null; then
  printf '%s\n' "$credential_worker_output" >&2
  echo "Portable credential rotation did not reconnect and drain" >&2
  exit 1
fi

docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
DROP TRIGGER portable_credential_start_delay ON otlet.portable_workers;
DROP FUNCTION public.portable_credential_start_delay();
SQL

credential_drain_contract="$(
  docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 -v worker_id="$worker_id" <<'SQL'
SELECT concat_ws('|', desired_state, reported_state, live_claims)
FROM otlet.portable_worker_status
WHERE worker_id = :'worker_id';
SQL
)"
if [ "$credential_drain_contract" != "draining|drained|0" ]; then
  echo "Expected the old credential worker to drain with no claims, got $credential_drain_contract" >&2
  exit 1
fi

docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
  -X -qAt -v ON_ERROR_STOP=1 \
  -v worker_id="$worker_id" -v worker_role="$worker_role" <<'SQL' >/dev/null
SELECT otlet.disable_portable_worker(:'worker_id');
SELECT otlet.revoke_access_policy_capability(
  :'worker_role'::regrole,
  'portable_worker',
  'Retire drained portable credential role'
);
SQL

probe old_revoked database_contract_denied
probe_credential_env="$ungranted_credential_env" probe replacement_active passed \
  -e "OTLET_DATABASE_URL=$replacement_database_url" \
  -e "OTLET_PORTABLE_WORKER_ID=$ungranted_worker_id" \
  -e "OTLET_PORTABLE_RUNTIME_IDENTITY_HASH=$ungranted_identity_hash"

credential_final_contract="$(
  docker exec -i "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 \
    -v worker_role="$worker_role" \
    -v worker_id="$worker_id" \
    -v replacement_worker_id="$ungranted_worker_id" <<'SQL'
SELECT concat_ws('|',
  (SELECT NOT enabled
   FROM otlet.portable_worker_status
   WHERE worker_id = :'worker_id'),
  NOT EXISTS (
    SELECT 1
    FROM otlet.access_policy_roles
    WHERE role_oid = :'worker_role'::regrole::oid
  ),
  (SELECT enabled
     AND desired_state = 'running'
     AND reported_state = 'idle'
     AND model_status = 'ready'
   FROM otlet.portable_worker_status
   WHERE worker_id = :'replacement_worker_id'),
  (SELECT reconciled
   FROM otlet.access_policy_role_status
   WHERE registered_role_name = 'otlet_preflight_ungranted'),
  (SELECT portable_eligible_workers
   FROM otlet.route_readiness_status
   WHERE task_name = 'portable_preflight_task'
     AND selection_role = 'direct'),
  (SELECT route_ready
   FROM otlet.route_readiness_status
   WHERE task_name = 'portable_preflight_task'
     AND selection_role = 'direct'),
  NOT pg_catalog.has_schema_privilege(:'worker_role', 'otlet', 'USAGE')
    AND NOT pg_catalog.has_table_privilege(
      :'worker_role',
      'otlet.portable_protocol_status',
      'SELECT'
    )
    AND (
      SELECT count(*) = 8
        AND count(*) FILTER (
          WHERE pg_catalog.has_function_privilege(
            :'worker_role',
            function.oid,
            'EXECUTE'
          )
        ) = 0
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname IN (
          'portable_start_worker',
          'portable_claim_jobs',
          'portable_renew_job',
          'portable_record_attempt',
          'portable_complete_job',
          'portable_fail_job',
          'portable_cancel_job',
          'portable_worker_heartbeat'
        )
    ),
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND function.proname IN (
        'portable_start_worker',
        'portable_claim_jobs',
        'portable_renew_job',
        'portable_record_attempt',
        'portable_complete_job',
        'portable_fail_job',
        'portable_cancel_job',
        'portable_worker_heartbeat'
      )
      AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
  ),
  (SELECT count(*) FROM otlet.verify_invariants())
);
SQL
)"
if [ "$credential_final_contract" != "t|t|t|t|1|t|t|t|0" ]; then
  echo "Expected a revoked old credential and ready replacement, got $credential_final_contract" >&2
  exit 1
fi

credential_status_evidence="$(
  docker exec "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
    -X -qAt -c "SELECT row_to_json(status) FROM otlet.portable_worker_status status ORDER BY worker_id"
)$(
  docker exec "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
    -X -qAt -c "SELECT row_to_json(status) FROM otlet.access_policy_role_status status ORDER BY registered_role_name"
)$(
  docker exec "$database_container" psql -h 127.0.0.1 -U postgres -d "$database" \
    -X -qAt -c "SELECT row_to_json(status) FROM otlet.route_readiness_status status ORDER BY task_name, selection_role"
)"
credential_database_evidence="$(
  docker exec "$database_container" pg_dump -h 127.0.0.1 -U postgres -d "$database" \
    --data-only --schema=otlet 2>/dev/null
)"
credential_database_logs="$(docker logs "$database_container" 2>&1)"
credential_evidence="$all_probe_output
$credential_worker_output
$credential_process_snapshot
$credential_environment_snapshot
$credential_status_evidence
$credential_database_evidence
$credential_database_logs"
for secret in "$worker_password" "$worker_password_next" "$ungranted_password"; do
  if [[ "$credential_evidence" == *"$secret"* ]]; then
    echo "Portable credential evidence exposed a password" >&2
    exit 1
  fi
done
if [[ "$credential_worker_output" == *"$database_url"* ]] \
   || [[ "$credential_worker_output" == *"$replacement_database_url"* ]]; then
  echo "Portable worker logs exposed connection data" >&2
  exit 1
fi

echo "portable_preflight_contract=$preflight_state|$diagnostics"
echo "portable_credential_lifecycle_contract=overlap:$credential_overlap_contract|reconnect_fenced|password_reloaded|drain:$credential_drain_contract|revoked|replacement_ready:$credential_final_contract|raw_secrets_external"
