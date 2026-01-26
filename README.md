# Slipstream Docker

A Docker container that bundles Shadowsocks server and Slipstream server into a single DNS tunnel solution. Features an interactive setup wizard that guides you through configuration and outputs a ready-to-use `ss://` URL for the Android Shadowsocks app with the slipstream plugin.

## Quick Start

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/dalisyron/slipstream-docker
cd slipstream-docker

# Build the container
docker build -t slipstream-ss .

# Run interactively (wizard guides you through setup)
docker run -it -p 53:53/udp -v slipstream-data:/data slipstream-ss
```

The interactive wizard will prompt you for:
1. Your DNS tunnel domain
2. Connection mode (recursive or authoritative)
3. Shadowsocks password (auto-generate or custom)

After setup, copy the displayed `ss://` URL to your Android Shadowsocks app.

## Architecture

```
Client (Android SS app + slipstream plugin)
    |
    v (DNS queries over UDP port 53)
Docker Container:
    slipstream-server (port 53/udp)
        |
        v (decapsulated TCP)
    ssserver (127.0.0.1:7749)
        |
        v
    Internet
```

## Configuration Options

### Interactive Mode (Default)

Run with `-it` flag for the interactive setup wizard:

```bash
docker run -it -p 53:53/udp -v slipstream-data:/data slipstream-ss
```

### Non-Interactive Mode

Set environment variables to skip prompts (useful for automation):

```bash
docker run -d --name slipstream-ss \
  -p 53:53/udp \
  -v slipstream-data:/data \
  -e DOMAIN=tunnel.example.com \
  -e MODE=recursive \
  -e RESOLVER=8.8.8.8 \
  -e NON_INTERACTIVE=true \
  slipstream-ss
```

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DOMAIN` | Yes* | - | DNS tunnel domain |
| `MODE` | No | `recursive` | `recursive` or `authoritative` |
| `RESOLVER` | No | `8.8.8.8` | DNS resolver for recursive mode |
| `SERVER_IP` | If auth | - | Server IP for authoritative mode |
| `SS_PASSWORD` | No | (auto-generated) | Shadowsocks password |
| `SS_METHOD` | No | `chacha20-ietf-poly1305` | Encryption method |
| `NON_INTERACTIVE` | No | `false` | Set `true` to skip all prompts |

*Required in non-interactive mode; prompted in interactive mode

## Connection Modes

### Recursive Mode (Recommended)

Clients query a public DNS resolver (e.g., 8.8.8.8) which resolves your domain. This mode:
- Works behind most firewalls
- More stealthy
- Requires your domain's DNS records to point to the server

### Authoritative/Direct Mode

Clients connect directly to your server's IP address. This mode:
- Higher performance with pacing-based polling
- Uses BBR congestion control
- Best when you control both endpoints
- Requires clients can reach port 53 directly

## Usage Examples

### First-time Setup (Interactive)

```bash
# Build
docker build -t slipstream-ss .

# Run interactively
docker run -it --name slipstream-ss \
  -p 53:53/udp \
  -v slipstream-data:/data \
  slipstream-ss
```

### Subsequent Runs

```bash
# Container remembers config from first run
docker start -ai slipstream-ss

# Or retrieve saved config
docker exec slipstream-ss cat /data/config/client-config.txt
```

### Using Docker Compose

```bash
# Interactive mode
docker compose run --rm slipstream-ss

# Or build and run in background (requires env vars)
docker compose up -d
```

### Automated Deployment

```bash
docker run -d --name slipstream-ss \
  -p 53:53/udp \
  -v slipstream-data:/data \
  -e DOMAIN=tunnel.example.com \
  -e MODE=recursive \
  -e RESOLVER=8.8.8.8 \
  -e NON_INTERACTIVE=true \
  slipstream-ss

# Get config from logs
docker logs slipstream-ss
```

## Retrieving Client Configuration

After setup, the client configuration (including the `ss://` URL) is saved to `/data/config/client-config.txt`:

```bash
# View saved configuration
docker exec slipstream-ss cat /data/config/client-config.txt

# Or from logs
docker logs slipstream-ss | grep -A5 "ss://"
```

## Android Client Setup

1. Install the [Shadowsocks](https://play.google.com/store/apps/details?id=com.github.shadowsocks) app from Play Store
2. Install the slipstream plugin APK (from the `cert-sha256-plugin` branch build)
3. In the Shadowsocks app:
   - Tap **+** to add a new profile
   - Choose **Scan QR Code** or paste the `ss://` URL
4. Select **slipstream** as the plugin
5. Connect and verify traffic flows through the tunnel

## Troubleshooting

### Container exits immediately

Make sure to run with `-it` flags for interactive mode:
```bash
docker run -it -p 53:53/udp slipstream-ss
```

### Port 53 already in use

Stop any existing DNS services:
```bash
# On Linux with systemd-resolved
sudo systemctl stop systemd-resolved
# Or use a different host port
docker run -it -p 5353:53/udp slipstream-ss
```

### Can't connect from client

1. Verify the container is running: `docker ps`
2. Check firewall allows UDP port 53
3. Verify DNS records point to your server (recursive mode)
4. Ensure the domain in client config matches your setup

### View container logs

```bash
docker logs slipstream-ss
```

### Reset configuration

Remove the data volume to start fresh:
```bash
docker volume rm slipstream-data
```

## Building from Source

The Dockerfile uses a multi-stage build:

1. **Stage 1**: Builds slipstream-server from the local submodule
2. **Stage 2**: Builds shadowsocks-rust v1.21.2
3. **Stage 3**: Creates a minimal runtime image

```bash
# Ensure submodules are initialized
git submodule update --init --recursive

# Build
docker build -t slipstream-ss .
```

## License

This project bundles:
- [slipstream-rust](https://github.com/dalisyron/slipstream-rust) - DNS tunnel implementation
- [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) - Shadowsocks implementation

See individual projects for their respective licenses.
