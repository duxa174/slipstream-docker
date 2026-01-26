# syntax=docker/dockerfile:1.6
ARG RUST_IMAGE=rust:1.93-bookworm
ARG SHADOWSOCKS_VERSION=v1.21.2

# Stage 1: Build slipstream-server from local submodule
FROM ${RUST_IMAGE} AS slipstream-builder

# Install build dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    pkg-config \
    libssl-dev \
    git \
    clang \
    && rm -rf /var/lib/apt/lists/*

# Copy the slipstream-rust submodule
COPY slipstream-rust/ /build/slipstream-rust/

WORKDIR /build/slipstream-rust

# Build slipstream-server in release mode
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/build/slipstream-rust/target,sharing=locked \
    cargo build -p slipstream-server --release && \
    cp /build/slipstream-rust/target/release/slipstream-server /build/slipstream-server

# Stage 2: Build shadowsocks-rust v1.21.2
FROM ${RUST_IMAGE} AS ss-builder
ARG SHADOWSOCKS_VERSION

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone and build shadowsocks-rust v1.21.2
RUN git clone --depth 1 --branch ${SHADOWSOCKS_VERSION} https://github.com/shadowsocks/shadowsocks-rust.git

WORKDIR /build/shadowsocks-rust

RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/build/shadowsocks-rust/target,sharing=locked \
    cargo build --release --bin ssserver && \
    cp /build/shadowsocks-rust/target/release/ssserver /build/ssserver

# Stage 3: Runtime image
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    openssl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /app /data/config

# Copy binaries from builders
COPY --from=slipstream-builder /build/slipstream-server /app/
COPY --from=ss-builder /build/ssserver /app/

# Copy entrypoint and config scripts
COPY entrypoint.sh /app/
COPY config.sh /app/

# Make scripts executable
RUN chmod +x /app/entrypoint.sh /app/config.sh

# Set working directory
WORKDIR /app

# Expose DNS port
EXPOSE 53/udp

# Volume for persistent config
VOLUME /data

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]
