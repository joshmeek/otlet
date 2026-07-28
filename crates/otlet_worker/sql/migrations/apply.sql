SELECT NOT EXISTS (
  SELECT 1
  FROM otlet.portable_schema_migrations
  WHERE version = :portable_migration_version
) AS portable_apply_migration
\gset

\if :portable_apply_migration
\ir :portable_migration_file
INSERT INTO otlet.portable_schema_migrations (version, file)
VALUES (:portable_migration_version, :'portable_migration_file');
\endif
