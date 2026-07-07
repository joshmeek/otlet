FROM postgres:18.4-trixie

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
  | sh -s -- -y --profile minimal --default-toolchain stable \
  && cargo install cargo-pgrx --version 0.18.1 --locked \
  && mkdir -p "$PGRX_HOME" \
  && cargo pgrx init --pg18 /usr/bin/pg_config
