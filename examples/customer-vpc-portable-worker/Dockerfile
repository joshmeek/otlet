FROM rust:1.97.1-trixie@sha256:1bcff4befb740599103a2c7cb51058e14479b2e35e3a34a3f0dc4ede09927488 AS build

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential clang cmake libclang-dev libgomp1 pkg-config \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
RUN cargo build --locked --release -p otlet_worker

FROM debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libgomp1 postgresql-client \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --uid 10001 --user-group otlet

COPY --from=build /src/target/release/otlet_worker /usr/local/bin/otlet_worker

USER 10001
ENTRYPOINT ["/usr/local/bin/otlet_worker"]
