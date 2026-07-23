FROM postgres:18.4-trixie@sha256:3a82e1f56c8f0f5616a11103ac3d47e632c3938698946a7ad26da0df1334744a

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang \
    cmake \
    curl \
    libclang-dev \
    libgomp1 \
    pkg-config \
    postgresql-server-dev-18 \
  && rm -rf /var/lib/apt/lists/*

ENV CARGO_HOME=/usr/local/cargo
ENV PGRX_HOME=/usr/local/pgrx
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --default-toolchain 1.97.1 \
  && cargo install cargo-pgrx --version 0.18.1 --locked \
  && cargo install cargo-audit --version 0.22.2 --locked \
  && mkdir -p "$PGRX_HOME" \
  && cargo pgrx init --pg18 /usr/bin/pg_config
