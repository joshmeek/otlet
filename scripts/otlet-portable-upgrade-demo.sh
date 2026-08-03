#!/usr/bin/env bash
set -euo pipefail

container="${OTLET_PG_CONTAINER:-otlet-postgres}"
database="otlet_portable_upgrade_demo_$$"

cleanup() {
  docker exec "$container" dropdb -U postgres --if-exists "$database" >/dev/null 2>&1 || true
}
trap cleanup EXIT

install_portable() {
  docker exec -w /work "$container" \
    psql -U postgres -d "$database" -X -q -v ON_ERROR_STOP=1 \
    -f crates/otlet_worker/sql/install.sql
}

cleanup
docker exec "$container" createdb -U postgres "$database"
install_portable

docker exec -i "$container" psql -U postgres -d "$database" \
  -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE TABLE public.portable_upgrade_sentinel (
  id integer PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO public.portable_upgrade_sentinel VALUES (1, 'preserved');
SQL

install_portable

contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  max(version),
  count(*),
  array_agg(version ORDER BY version) = ARRAY(SELECT generate_series(1, 43)),
  bool_and(file ~ ('(^|/)' || lpad(version::text, 4, '0') || '_')),
  (SELECT value FROM public.portable_upgrade_sentinel),
  (SELECT count(*) FROM otlet.verify_invariants())
)
FROM otlet.portable_schema_migrations;
SQL
)"
[ "$contract" = "43|43|t|t|preserved|0" ] || {
  echo "Portable repeat-install contract mismatch: $contract" >&2
  exit 1
}

identity_vector_contract="$(
  docker exec -i "$container" psql -U postgres -d "$database" \
    -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
SELECT concat_ws('|',
  otlet.identity_hash(
    'test_vector',
    '{"b":2.00,"a":[1.0,"é"]}'::jsonb
  ) = 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_hash(
    'test_vector',
    '{"a":[1.00,"é"],"b":2}'::jsonb
  ) = 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_hash(
    'other_vector',
    '{"b":2.00,"a":[1.0,"é"]}'::jsonb
  ) <> 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_text_hash(
    'text_vector',
    E'Otlet\n🙂'
  ) = 'otlet:v1:sha256:96077dacfe042898c24b4f06ed6d91b8d21e13a52d36738fe1009032d0d13f72'
);
SQL
)"
[ "$identity_vector_contract" = "t|t|t|t" ] || {
  echo "Portable identity vector contract mismatch: $identity_vector_contract" >&2
  exit 1
}

echo "portable_upgrade_contract=$contract"
echo "portable_identity_vector_contract=$identity_vector_contract"
