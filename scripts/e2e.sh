#!/usr/bin/env bash
set -euo pipefail

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

IMAGE=${IMAGE:-slipstream-ss}
DOMAIN=${DOMAIN:-t2.128938742.xyz}
MODE=${MODE:-authoritative}
HOST_DNS_PORT=${HOST_DNS_PORT:-5353}
SLIPSTREAM_TCP_PORT=${SLIPSTREAM_TCP_PORT:-7779}
SOCKS_PORT=${SOCKS_PORT:-1081}
DATA_VOLUME=${DATA_VOLUME:-slipstream-data-e2e}
SERVER_CONTAINER=${SERVER_CONTAINER:-slipstream-ss-e2e}
CLIENT_CONTAINER=${CLIENT_CONTAINER:-slipstream-client-e2e}
SSLOCAL_CONTAINER=${SSLOCAL_CONTAINER:-sslocal-e2e}
RUST_IMAGE=${RUST_IMAGE:-rust:1.93-bookworm}
CURL_IMAGE=${CURL_IMAGE:-curlimages/curl:8.5.0}
CURL_OPTS=${CURL_OPTS:--sS --max-time 10 --connect-timeout 5}
E2E_DIR=${E2E_DIR:-/tmp/slipstream-e2e}
BUILD_IMAGE=${BUILD_IMAGE:-true}
BUILD_CLIENT=${BUILD_CLIENT:-true}
BUILD_SSLOCAL=${BUILD_SSLOCAL:-true}
SLIPSTREAM_VERSION=${SLIPSTREAM_VERSION:-0.1.0-certsha}
SLIPSTREAM_ARCH=${SLIPSTREAM_ARCH:-}
SHADOWSOCKS_VERSION=${SHADOWSOCKS_VERSION:-1.21.2}
SHADOWSOCKS_ARCH=${SHADOWSOCKS_ARCH:-}
SKIP_INTERNET_TEST=${SKIP_INTERNET_TEST:-false}
SKIP_DNS_CHECK=${SKIP_DNS_CHECK:-true}
FORCE_RECONFIGURE=${FORCE_RECONFIGURE:-true}
SKIP_CLEANUP=${SKIP_CLEANUP:-false}
DOCKER_BUILDKIT=${DOCKER_BUILDKIT:-1}
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

cleanup() {
  if [ "$SKIP_CLEANUP" = "true" ]; then
    log "Skipping cleanup (SKIP_CLEANUP=true)"
    return
  fi
  log "Cleaning up containers..."
  docker rm -f "$SSLOCAL_CONTAINER" "$CLIENT_CONTAINER" "$SERVER_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || fail "docker not found"
command -v rg >/dev/null 2>&1 || fail "rg (ripgrep) not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -s)" = "Linux" ] || fail "This script requires Linux host networking (docker --network=host)"

detect_ss_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
    i686|i386) echo "i686-unknown-linux-musl" ;;
    armv7l|armv7|armhf) echo "armv7-unknown-linux-musleabihf" ;;
    armv6l|arm) echo "arm-unknown-linux-musleabihf" ;;
    *) return 1 ;;
  esac
}

detect_slipstream_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
    i686|i386) echo "i686-unknown-linux-musl" ;;
    armv7l|armv7|armhf) echo "armv7-unknown-linux-musleabihf" ;;
    armv6l|arm) echo "arm-unknown-linux-musleabihf" ;;
    *) return 1 ;;
  esac
}

check_tcp_port_free() {
  local port=$1
  local status=0
  set +e
  python3 - <<PY
import socket, sys
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(('127.0.0.1', int('$port')))
    except OSError:
        sys.exit(1)
    finally:
        s.close()
except PermissionError:
    sys.exit(2)
sys.exit(0)
PY
  status=$?
  set -e
  case $status in
    0) ;;
    1) fail "TCP port $port is in use. Set SLIPSTREAM_TCP_PORT or SOCKS_PORT to a free port." ;;
    2) log "Skipping TCP port check for $port (permission denied to bind sockets)" ;;
    *) fail "TCP port check failed for $port" ;;
  esac
}

check_udp_port_free() {
  local port=$1
  local status=0
  set +e
  python3 - <<PY
import socket, sys
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(('127.0.0.1', int('$port')))
    except OSError:
        sys.exit(1)
    finally:
        s.close()
except PermissionError:
    sys.exit(2)
sys.exit(0)
PY
  status=$?
  set -e
  case $status in
    0) ;;
    1) fail "UDP port $port is in use. Set HOST_DNS_PORT to a free port." ;;
    2) log "Skipping UDP port check for $port (permission denied to bind sockets)" ;;
    *) fail "UDP port check failed for $port" ;;
  esac
}

check_udp_port_free "$HOST_DNS_PORT"
check_tcp_port_free "$SLIPSTREAM_TCP_PORT"
check_tcp_port_free "$SOCKS_PORT"

if [ "$BUILD_IMAGE" = "true" ]; then
  log "Building server image ($IMAGE)"
  DOCKER_BUILDKIT="$DOCKER_BUILDKIT" docker build -t "$IMAGE" "$ROOT_DIR"
fi

mkdir -p "$E2E_DIR/bin"

if [ "$BUILD_CLIENT" = "true" ] && [ ! -x "$E2E_DIR/bin/slipstream-client" ]; then
  log "Downloading slipstream-client binary"
  if [ -z "$SLIPSTREAM_ARCH" ]; then
    SLIPSTREAM_ARCH="$(detect_slipstream_arch)" || fail "Unsupported architecture for slipstream-client download"
  fi
  SLIP_VERSION="${SLIPSTREAM_VERSION#v}"
  SLIP_FILE="slipstream-v${SLIP_VERSION}.${SLIPSTREAM_ARCH}.tar.xz"
  SLIP_URL="https://github.com/dalisyron/slipstream-rust/releases/download/v${SLIP_VERSION}/${SLIP_FILE}"
  curl -fsSL "$SLIP_URL" -o "$E2E_DIR/${SLIP_FILE}" || fail "Failed to download slipstream-client"
  curl -fsSL "${SLIP_URL}.sha256" -o "$E2E_DIR/${SLIP_FILE}.sha256" || fail "Failed to download slipstream checksum"
  (cd "$E2E_DIR" && sha256sum -c "${SLIP_FILE}.sha256") || fail "slipstream checksum failed"
  tar -xJf "$E2E_DIR/${SLIP_FILE}" -C "$E2E_DIR"
  SLIP_BIN=$(find "$E2E_DIR" -type f -name slipstream-client -perm -111 | head -n 1)
  [ -n "$SLIP_BIN" ] || fail "slipstream-client not found in archive"
  cp "$SLIP_BIN" "$E2E_DIR/bin/slipstream-client"
fi

if [ "$BUILD_SSLOCAL" = "true" ] && [ ! -x "$E2E_DIR/bin/sslocal" ]; then
  log "Downloading sslocal binary"
  if [ -z "$SHADOWSOCKS_ARCH" ]; then
    SHADOWSOCKS_ARCH="$(detect_ss_arch)" || fail "Unsupported architecture for sslocal download"
  fi
  SS_VERSION="${SHADOWSOCKS_VERSION#v}"
  SS_FILE="shadowsocks-v${SS_VERSION}.${SHADOWSOCKS_ARCH}.tar.xz"
  SS_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${SS_VERSION}/${SS_FILE}"
  curl -fsSL "$SS_URL" -o "$E2E_DIR/${SS_FILE}" || fail "Failed to download sslocal"
  curl -fsSL "${SS_URL}.sha256" -o "$E2E_DIR/${SS_FILE}.sha256" || fail "Failed to download sslocal checksum"
  (cd "$E2E_DIR" && sha256sum -c "${SS_FILE}.sha256") || fail "sslocal checksum failed"
  tar -xJf "$E2E_DIR/${SS_FILE}" -C "$E2E_DIR"
  SSLOCAL_BIN=$(find "$E2E_DIR" -type f -name sslocal -perm -111 | head -n 1)
  [ -n "$SSLOCAL_BIN" ] || fail "sslocal not found in archive"
  cp "$SSLOCAL_BIN" "$E2E_DIR/bin/sslocal"
fi

[ -x "$E2E_DIR/bin/slipstream-client" ] || fail "slipstream-client missing"
[ -x "$E2E_DIR/bin/sslocal" ] || fail "sslocal missing"

log "Starting server container ($SERVER_CONTAINER)"
docker rm -f "$SERVER_CONTAINER" >/dev/null 2>&1 || true

docker run -d --name "$SERVER_CONTAINER" \
  -p "$HOST_DNS_PORT":53/udp \
  -v "$DATA_VOLUME":/data \
  -e DOMAIN="$DOMAIN" \
  -e MODE="$MODE" \
  -e SERVER_IP=127.0.0.1 \
  -e NON_INTERACTIVE=true \
  -e SKIP_DNS_CHECK="$SKIP_DNS_CHECK" \
  -e FORCE_RECONFIGURE="$FORCE_RECONFIGURE" \
  "$IMAGE" >/dev/null

log "Waiting for server readiness..."
for i in $(seq 1 30); do
  if docker logs "$SERVER_CONTAINER" 2>&1 | rg -q "Tunnel is ready"; then
    break
  fi
  sleep 1
  if [ "$i" -eq 30 ]; then
    docker logs "$SERVER_CONTAINER" >&2 || true
    fail "server did not become ready"
  fi
 done

CERT_SHA256=$(docker exec "$SERVER_CONTAINER" sh -lc "sed -n 's/^Cert SHA256:[[:space:]]*//p' /data/config/client-config.txt | head -n 1")
SS_PASSWORD=$(docker exec "$SERVER_CONTAINER" sh -lc "sed -n 's/^Password:[[:space:]]*//p' /data/config/client-config.txt | head -n 1")
SS_METHOD=$(docker exec "$SERVER_CONTAINER" sh -lc "sed -n 's/^Method:[[:space:]]*//p' /data/config/client-config.txt | head -n 1")

[ -n "$CERT_SHA256" ] || fail "missing cert sha"
[ -n "$SS_PASSWORD" ] || fail "missing password"
[ -n "$SS_METHOD" ] || fail "missing method"

log "Starting slipstream-client"
docker rm -f "$CLIENT_CONTAINER" >/dev/null 2>&1 || true

docker run -d --name "$CLIENT_CONTAINER" --network=host \
  -v "$E2E_DIR/bin:/work" -w /work \
  "$RUST_IMAGE" \
  /work/slipstream-client \
  --tcp-listen-host 127.0.0.1 \
  --tcp-listen-port "$SLIPSTREAM_TCP_PORT" \
  --authoritative 127.0.0.1:"$HOST_DNS_PORT" \
  --domain "$DOMAIN" \
  --cert-sha256 "$CERT_SHA256" >/dev/null

log "Waiting for slipstream-client readiness..."
for i in $(seq 1 20); do
  if docker logs "$CLIENT_CONTAINER" 2>&1 | rg -q "Connection ready"; then
    break
  fi
  sleep 1
  if [ "$i" -eq 20 ]; then
    docker logs "$CLIENT_CONTAINER" >&2 || true
    fail "slipstream-client did not become ready"
  fi
 done

log "Starting sslocal"
docker rm -f "$SSLOCAL_CONTAINER" >/dev/null 2>&1 || true

docker run -d --name "$SSLOCAL_CONTAINER" --network=host \
  -v "$E2E_DIR/bin:/work" -w /work \
  "$RUST_IMAGE" \
  /work/sslocal \
  -b 127.0.0.1:"$SOCKS_PORT" \
  -s 127.0.0.1:"$SLIPSTREAM_TCP_PORT" \
  -k "$SS_PASSWORD" \
  -m "$SS_METHOD" >/dev/null

sleep 1
if [ "$(docker inspect -f '{{.State.Running}}' "$SSLOCAL_CONTAINER" 2>/dev/null || echo false)" != "true" ]; then
  docker logs "$SSLOCAL_CONTAINER" >&2 || true
  fail "sslocal failed to start"
fi

if [ "$SKIP_INTERNET_TEST" = "true" ]; then
  log "Skipping internet test (SKIP_INTERNET_TEST=true)"
else
  log "Testing internet via SOCKS proxy"
  CURL_OUT=""
  CURL_STATUS=0
  if docker exec "$SSLOCAL_CONTAINER" sh -lc "command -v curl" >/dev/null 2>&1; then
    set +e
    CURL_OUT=$(docker exec "$SSLOCAL_CONTAINER" sh -lc "curl $CURL_OPTS --socks5-hostname 127.0.0.1:$SOCKS_PORT -I https://example.com" 2>&1)
    CURL_STATUS=$?
    set -e
  else
    set +e
    CURL_OUT=$(docker run --rm --network=host "$CURL_IMAGE" curl $CURL_OPTS --socks5-hostname 127.0.0.1:$SOCKS_PORT -I https://example.com 2>&1)
    CURL_STATUS=$?
    set -e
  fi
  if [ "$CURL_STATUS" -ne 0 ]; then
    echo "$CURL_OUT" >&2
    fail "curl failed (exit $CURL_STATUS). Set SKIP_INTERNET_TEST=true to skip or verify outbound internet access."
  fi
  HTTP_LINE=$(printf '%s\n' "$CURL_OUT" | head -n 1)
  echo "$HTTP_LINE" | rg -q "200" || fail "internet test failed (got: $HTTP_LINE)"
fi

log "E2E test OK"
