# Stage 1: Build slipstream-server from local submodule
FROM rust:1.75-bookworm AS slipstream-builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    cmake \
    pkg-config \
    libssl-dev \
    git \
    clang \
    && rm -rf /var/lib/apt/lists/*

# Copy the slipstream-rust submodule
COPY slipstream-rust/ /build/slipstream-rust/

WORKDIR /build/slipstream-rust

# Initialize nested submodules (picoquic)
RUN git submodule update --init --recursive

# Build slipstream-server in release mode
RUN cargo build -p slipstream-server --release

# Stage 2: Build shadowsocks-rust v1.21.2
FROM rust:1.75-bookworm AS ss-builder

RUN apt-get update && apt-get install -y \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone and build shadowsocks-rust v1.21.2
RUN git clone --depth 1 --branch v1.21.2 https://github.com/shadowsocks/shadowsocks-rust.git && \
    cd shadowsocks-rust && \
    cargo build --release --bin ssserver

# Stage 3: Runtime image
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    openssl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /app /data/config

# Copy binaries from builders
COPY --from=slipstream-builder /build/slipstream-rust/target/release/slipstream-server /app/
COPY --from=ss-builder /build/shadowsocks-rust/target/release/ssserver /app/

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
