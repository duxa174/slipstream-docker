# syntax=docker/dockerfile:1.6
ARG SHADOWSOCKS_VERSION=1.21.2
ARG SLIPSTREAM_VERSION=0.1.0-certsha

# Stage 1: Download slipstream-rust binary
FROM debian:bookworm-slim AS slipstream-downloader
ARG SLIPSTREAM_VERSION
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
      amd64|x86_64) slipstream_arch="x86_64-unknown-linux-musl" ;; \
      arm64|aarch64) slipstream_arch="aarch64-unknown-linux-musl" ;; \
      386|i386|i686) slipstream_arch="i686-unknown-linux-musl" ;; \
      arm|armhf|armv7|armv7l) \
        if [ "$arch" = "armhf" ] || [ "$variant" = "v7" ]; then \
          slipstream_arch="armv7-unknown-linux-musleabihf"; \
        else \
          slipstream_arch="arm-unknown-linux-musleabihf"; \
        fi \
        ;; \
      armel) slipstream_arch="arm-unknown-linux-musleabi" ;; \
      *) echo "Unsupported architecture for slipstream: $arch $variant" >&2; exit 1 ;; \
    esac; \
    version="${SLIPSTREAM_VERSION#v}"; \
    file="slipstream-v${version}.${slipstream_arch}.tar.xz"; \
    url="https://github.com/dalisyron/slipstream-rust/releases/download/v${version}/${file}"; \
    curl -fsSL "$url" -o "/tmp/${file}"; \
    curl -fsSL "${url}.sha256" -o "/tmp/${file}.sha256"; \
    (cd /tmp && sha256sum -c "${file}.sha256"); \
    tar -xJf "/tmp/${file}" -C /tmp; \
    ss_bin="$(find /tmp -type f -name slipstream-server -perm -111 | head -n 1)"; \
    [ -n "$ss_bin" ]; \
    cp "$ss_bin" /build/slipstream-server

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
COPY --from=slipstream-downloader /build/slipstream-server /app/
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
