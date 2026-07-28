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

echo "portable_upgrade_contract=$contract"
