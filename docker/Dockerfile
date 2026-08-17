# syntax=docker/dockerfile:1
# Generic Rust service build. Uses cargo-chef so the dependency-compilation
# layer is a normal image layer (cacheable by the `type=gha` cache in CI)
# instead of a `--mount=type=cache` target that never survives across runs.
# Rebuilds therefore only recompile changed source, not every dependency
# (~15-30 min -> minutes). Mirrors Dockerfile.search_processing_service.
FROM rust:latest AS chef
ARG SERVICE_NAME
ENV SQLX_OFFLINE=true
WORKDIR /app
# rdkafka-sys (and any other C dep) needs cmake to build from source.
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# Installed once; cached from the second build onwards.
RUN cargo install cargo-chef

FROM chef AS planner
ARG SERVICE_NAME
COPY . .
RUN cargo chef prepare --recipe-path recipe.json --bin ${SERVICE_NAME}

FROM chef AS builder
ARG SERVICE_NAME
COPY --from=planner /app/recipe.json recipe.json
# Build dependencies only — this layer is cached by the image layer cache, so
# it only recompiles when Cargo.toml / Cargo.lock change.
RUN cargo chef cook --release --recipe-path recipe.json --bin ${SERVICE_NAME}
# Build the application binary (dependencies already compiled above).
COPY . .
RUN cargo build --release --bin ${SERVICE_NAME} && \
  strip /app/target/release/${SERVICE_NAME} && \
  cp /app/target/release/${SERVICE_NAME} /app/svc

# Create slim runner to run the service
FROM debian:trixie-slim AS runner
ARG SERVICE_NAME
WORKDIR /app

RUN : \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  dumb-init \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 --from=builder /app/svc /app/svc

ENV PORT=8080
EXPOSE ${PORT}

ENTRYPOINT ["dumb-init", "./svc"]
