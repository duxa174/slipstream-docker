# syntax=docker/dockerfile:1.6
ARG RUST_IMAGE=rust:1.93-bookworm
ARG SHADOWSOCKS_VERSION=1.21.2

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

# Stage 2: Download shadowsocks-rust v1.21.2 binary
FROM debian:bookworm-slim AS ss-downloader
ARG SHADOWSOCKS_VERSION
ARG TARGETARCH
ARG TARGETVARIANT

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN set -eu; \
    arch="${TARGETARCH:-}"; \
    variant="${TARGETVARIANT:-}"; \
    if [ -z "$arch" ]; then \
      if command -v dpkg >/dev/null 2>&1; then \
        arch="$(dpkg --print-architecture)"; \
      else \
        arch="$(uname -m)"; \
      fi; \
    fi; \
    case "$arch" in \
      amd64|x86_64) ss_arch="x86_64-unknown-linux-musl" ;; \
      arm64|aarch64) ss_arch="aarch64-unknown-linux-musl" ;; \
      386|i386|i686) ss_arch="i686-unknown-linux-musl" ;; \
      arm|armhf|armv7|armv7l) \
        if [ "$arch" = "armhf" ] || [ "$variant" = "v7" ]; then \
          ss_arch="armv7-unknown-linux-musleabihf"; \
        else \
          ss_arch="arm-unknown-linux-musleabihf"; \
        fi \
        ;; \
      armel) ss_arch="arm-unknown-linux-musleabi" ;; \
      *) echo "Unsupported architecture for shadowsocks: $arch $variant" >&2; exit 1 ;; \
    esac; \
    version="${SHADOWSOCKS_VERSION#v}"; \
    file="shadowsocks-v${version}.${ss_arch}.tar.xz"; \
    url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}/${file}"; \
    curl -fsSL "$url" -o "/tmp/${file}"; \
    curl -fsSL "${url}.sha256" -o "/tmp/${file}.sha256"; \
    (cd /tmp && sha256sum -c "${file}.sha256"); \
    tar -xJf "/tmp/${file}" -C /tmp; \
    ss_bin="$(find /tmp -type f -name ssserver -perm -111 | head -n 1)"; \
    [ -n "$ss_bin" ]; \
    cp "$ss_bin" /build/ssserver

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
COPY --from=ss-downloader /build/ssserver /app/

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
