\set ON_ERROR_STOP on

BEGIN;
SELECT pg_advisory_xact_lock(hashtext('otlet_portable_schema_upgrade')) \g /dev/null
\ir migrate.sql
COMMIT;
