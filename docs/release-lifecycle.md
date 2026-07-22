# Release Lifecycle

Run the release lifecycle check after setup has built the pinned Postgres image:

```sh
./scripts/otlet-setup.sh
./scripts/otlet-release-lifecycle.sh
```

The command creates a fresh disposable Postgres volume and container, installs Otlet, and records a sentinel row. It then proves clean worker stop, worker registration after database restart, current-version upgrade preflight, transactional rollback from an injected failed upgrade, recovery from an injected preload failure, preserved database state, and a clean crash-log scan

The injected update file exists only inside the disposable container. It does not add a compatibility layer or migration to the extension

The lifecycle container and volume are removed when the command exits

Run a preflight against an existing installation before an upgrade:

```sh
./scripts/otlet-upgrade-preflight.sh 0.1.0
```

The preflight requires a readable extension binary and control file, zero active jobs, zero invariant violations, active preload configuration, and a PostgreSQL update path when the target differs from the installed version. It reads state without changing it
