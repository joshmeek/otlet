# Release Evidence

Otlet currently supports one tested release matrix: PostgreSQL 18.4 on Debian 13 `trixie`, Linux `aarch64`, and the linked llama.cpp revision recorded in [runtime-matrix.json](../release/runtime-matrix.json)

Run setup and the full demo before producing evidence:

```sh
./scripts/otlet-setup.sh
./scripts/otlet-demo.sh
./scripts/otlet-release-evidence.sh
```

The release command builds the pgrx package twice with isolated Cargo targets and deterministic path, locale, timezone, timestamp, and strip settings. It stops if the package file manifests differ or the live runtime is outside the checked matrix

The output directory contains:

- `otlet-pg18-linux-aarch64.tar.gz` with the extension binary and its linked llama.cpp runtime, control file, and generated SQL
- `package-manifest.json` with paths, byte sizes, and SHA-256 digests from both equivalent builds
- `source-manifest.json` with the source-file digests behind the release tree identity
- `release-identity.json` with source, binary, SQL, model, prompt, schema, pack, runtime, PostgreSQL, operating-system, CPU, linked-library, container, and build-tool identities
- `sbom.cdx.json` with the CycloneDX 1.6 Cargo dependency graph
- `vulnerabilities.json` with the RustSec report from pinned `cargo-audit`
- `runtime-matrix.json` with the tested release target
- `SHA256SUMS` for every emitted artifact and report

Set `OTLET_RELEASE_OUTPUT` to choose a new output directory. The command refuses to overwrite an existing path

The command fails on RustSec vulnerabilities, unsound dependencies, or yanked dependencies. Informational maintenance notices remain visible in the report
