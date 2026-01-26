#!/bin/bash
# entrypoint.sh - Interactive setup wizard for Slipstream + Shadowsocks

set -e

# Source helper functions
source /app/config.sh

# Default values
SS_METHOD="${SS_METHOD:-chacha20-ietf-poly1305}"
SS_PORT="7749"
DNS_PORT="53"

# Shadowsocks config file path
SS_CONFIG="/data/config/ss-config.json"
# Slipstream TLS material paths (auto-generated if missing)
CERT_PATH="${CERT_PATH:-/data/config/cert.pem}"
KEY_PATH="${KEY_PATH:-/data/config/key.pem}"
# Slipstream reset seed path (auto-generated if missing)
RESET_SEED_PATH="${RESET_SEED_PATH:-/data/config/reset-seed}"

# Check if running in non-interactive mode
is_non_interactive() {
    [ "${NON_INTERACTIVE:-false}" = "true" ] || [ ! -t 0 ]
}

# Check if running in setup-only mode (exit after saving config)
is_setup_only() {
    [ "${SETUP_ONLY:-false}" = "true" ]
}

# Create Shadowsocks config file
create_ss_config() {
    mkdir -p "$(dirname "$SS_CONFIG")"
    cat > "$SS_CONFIG" << EOF
{
    "server": "127.0.0.1",
    "server_port": $SS_PORT,
    "password": "$SS_PASSWORD",
    "method": "$SS_METHOD"
}
EOF
}

# Ensure TLS cert/key exist for slipstream-server
ensure_cert_key() {
    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
        print_info "Generating self-signed TLS certificate..."
        mkdir -p "$(dirname "$CERT_PATH")"
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$KEY_PATH" \
            -out "$CERT_PATH" \
            -days 3650 \
            -subj "/CN=slipstream" >/dev/null 2>&1
        chmod 600 "$KEY_PATH" || true
    fi
}

# Ensure reset seed exists for slipstream-server
ensure_reset_seed() {
    if [ ! -f "$RESET_SEED_PATH" ]; then
        print_info "Generating reset seed..."
        mkdir -p "$(dirname "$RESET_SEED_PATH")"
        openssl rand -hex 16 > "$RESET_SEED_PATH"
        chmod 600 "$RESET_SEED_PATH" || true
    fi
}

# Optional DNS preflight check for recursive mode
maybe_dns_check() {
    if [ "$MODE" != "recursive" ]; then
        return 0
    fi
    if [ "${SKIP_DNS_CHECK:-false}" = "true" ]; then
        print_info "Skipping DNS preflight check (SKIP_DNS_CHECK=true)"
        return 0
    fi
    if ! command -v getent >/dev/null 2>&1; then
        print_warning "Skipping DNS preflight check (getent not available)"
        return 0
    fi
    local resolved
    resolved=$(getent ahosts "$DOMAIN" | awk '{print $1}' | sort -u | tr '\n' ' ')
    if [ -z "$resolved" ]; then
        print_warning "DNS preflight: $DOMAIN does not resolve yet"
        return 0
    fi
    if [ -n "${EXPECTED_PUBLIC_IP:-}" ]; then
        if echo "$resolved" | grep -q "$EXPECTED_PUBLIC_IP"; then
            print_success "DNS preflight: $DOMAIN resolves to expected IP $EXPECTED_PUBLIC_IP"
        else
            print_warning "DNS preflight: $DOMAIN resolves to $resolved (expected $EXPECTED_PUBLIC_IP)"
        fi
    else
        print_info "DNS preflight: $DOMAIN resolves to $resolved"
    fi
}

# Get cert-sha256 from slipstream-server
get_cert_sha256() {
    local output
    output=$(/app/slipstream-server \
        --domain "$DOMAIN" \
        --cert "$CERT_PATH" \
        --key "$KEY_PATH" \
        --print-ss-plugin 2>&1 || true)
    CERT_SHA256=$(echo "$output" | grep -oP 'cert-sha256=\K[a-fA-F0-9]+' | head -1)

    if [ -z "$CERT_SHA256" ]; then
        print_error "Failed to get cert-sha256 from slipstream-server"
        print_error "Output: $output"
        exit 1
    fi
}

# Build plugin options string
build_plugin_opts() {
    local opts="domain=$DOMAIN;cert-sha256=$CERT_SHA256"

    if [ "$MODE" = "recursive" ]; then
        opts="${opts};resolver=${RESOLVER}:53"
    else
        opts="${opts};authoritative=${SERVER_IP}:53"
    fi

    echo "$opts"
}

# Run interactive wizard
run_wizard() {
    print_header

    # Step 1: Domain Configuration
    print_bold "Step 1: Domain Configuration"
    echo ""
    while true; do
        prompt_input "Enter your DNS tunnel domain (e.g., tunnel.example.com)" "" DOMAIN
        if [ -z "$DOMAIN" ]; then
            print_error "Domain is required"
        elif validate_domain "$DOMAIN"; then
            break
        else
            print_error "Invalid domain format. Please enter a valid domain."
        fi
    done
    echo ""

    # Step 2: Connection Mode
    print_bold "Step 2: Connection Mode"
    echo ""
    echo "How will clients connect to this server?"
    echo ""
    print_color "$GREEN" "1) Recursive DNS (Recommended)"
    echo "   - Clients query public DNS (e.g., 8.8.8.8) which resolves your domain"
    echo "   - Works behind most firewalls, more stealthy"
    echo "   - Requires domain DNS records pointing to this server"
    echo ""
    print_color "$GREEN" "2) Authoritative/Direct"
    echo "   - Clients connect directly to your server IP"
    echo "   - Higher performance with pacing-based polling"
    echo "   - Best for servers you fully control"
    echo "   - Requires clients can reach port 53 directly"
    echo ""
    prompt_choice "Choose [1/2]" MODE_CHOICE

    if [ "$MODE_CHOICE" = "1" ]; then
        MODE="recursive"
        echo ""
        print_bold "Step 2a: DNS Resolver"
        echo "Enter the public DNS resolver clients should use:"
        echo "  Examples: 8.8.8.8, 1.1.1.1, 9.9.9.9"
        echo "  (Note: Android plugin currently supports only one resolver)"
        echo ""
        prompt_input "Resolver" "8.8.8.8" RESOLVER
    else
        MODE="authoritative"
        echo ""
        print_warning "NOTE: Authoritative mode uses BBR congestion control with pacing-based"
        print_warning "polling. This works best when you control both endpoints and can handle"
        print_warning "high query rates. Only use this if this is your own server."
        echo ""
        print_bold "Step 2b: Server IP"
        while true; do
            prompt_input "Enter this server's public IP address" "" SERVER_IP
            if [ -z "$SERVER_IP" ]; then
                print_error "Server IP is required for authoritative mode"
            elif validate_ip "$SERVER_IP"; then
                break
            else
                print_error "Invalid IP address format"
            fi
        done
    fi
    echo ""

    # Step 3: Shadowsocks Password
    print_bold "Step 3: Shadowsocks Password"
    echo ""
    echo "Shadowsocks password configuration:"
    echo ""
    print_color "$GREEN" "1) Generate secure random password (Recommended)"
    print_color "$GREEN" "2) Enter custom password"
    echo ""
    prompt_choice "Choose [1/2]" PASS_CHOICE

    if [ "$PASS_CHOICE" = "1" ]; then
        SS_PASSWORD=$(generate_password)
        echo ""
        print_success "Generated password: $SS_PASSWORD"
    else
        echo ""
        while true; do
            prompt_input "Enter password (min 8 characters)" "" SS_PASSWORD
            if [ ${#SS_PASSWORD} -ge 8 ]; then
                break
            else
                print_error "Password must be at least 8 characters"
            fi
        done
    fi
    echo ""

    # Step 4: Confirmation
    print_bold "=== Configuration Summary ==="
    echo ""
    echo -e "Domain:     ${GREEN}$DOMAIN${NC}"
    if [ "$MODE" = "recursive" ]; then
        echo -e "Mode:       ${GREEN}Recursive (via $RESOLVER)${NC}"
    else
        echo -e "Mode:       ${GREEN}Authoritative ($SERVER_IP)${NC}"
    fi
    echo -e "SS Method:  ${GREEN}$SS_METHOD${NC}"
    echo -e "Password:   ${GREEN}$SS_PASSWORD${NC}"
    echo ""
    echo -n "Press Enter to start servers, or Ctrl+C to abort..."
    read -r
}

# Run non-interactive setup
run_non_interactive() {
    print_info "Running in non-interactive mode..."

    # Validate required variables
    if [ -z "$DOMAIN" ]; then
        print_error "DOMAIN environment variable is required in non-interactive mode"
        exit 1
    fi

    # Set defaults
    MODE="${MODE:-recursive}"
    RESOLVER="${RESOLVER:-8.8.8.8}"
    SS_PASSWORD="${SS_PASSWORD:-$(generate_password)}"

    # Validate mode-specific requirements
    if [ "$MODE" = "authoritative" ] && [ -z "$SERVER_IP" ]; then
        print_error "SERVER_IP is required for authoritative mode"
        exit 1
    fi

    print_info "Configuration:"
    print_info "  Domain: $DOMAIN"
    print_info "  Mode: $MODE"
    if [ "$MODE" = "recursive" ]; then
        print_info "  Resolver: $RESOLVER"
    else
        print_info "  Server IP: $SERVER_IP"
    fi
}

# Main execution
main() {
    echo ""
    print_color "$CYAN" "Slipstream + Shadowsocks Docker Container"
    echo ""

    # Check for existing configuration
    if config_exists; then
        print_info "Found existing configuration at $CONFIG_FILE"

        if [ "${FORCE_RECONFIGURE:-false}" = "true" ]; then
            print_warning "FORCE_RECONFIGURE=true; ignoring existing configuration"
        elif is_non_interactive; then
            print_info "Using existing configuration..."
            load_config
        else
            prompt_yn "Use existing configuration?" "y" USE_EXISTING
            if [ "$USE_EXISTING" = "true" ]; then
                load_config
                print_success "Loaded existing configuration"
            else
                run_wizard
            fi
        fi
    fi

    if ! config_exists || [ "${FORCE_RECONFIGURE:-false}" = "true" ]; then
        if is_non_interactive; then
            run_non_interactive
        else
            run_wizard
        fi
    fi

    # Optional DNS check for recursive mode
    maybe_dns_check

    echo ""
    print_info "Starting services..."
    echo ""

    # Get cert-sha256 from slipstream-server
    print_info "Retrieving certificate fingerprint..."
    ensure_cert_key
    get_cert_sha256
    print_success "Cert SHA256: $CERT_SHA256"

    # Ensure reset seed exists for server restarts
    ensure_reset_seed

    # Save configuration
    save_config

    # If setup-only mode, exit after saving config
    if is_setup_only; then
        print_success "Configuration saved. Container will now exit."
        print_info "Restart the container to run the server."
        exit 0
    fi

    # Create Shadowsocks config
    print_info "Creating Shadowsocks configuration..."
    create_ss_config

    # Start Shadowsocks server in background
    print_info "Starting Shadowsocks server on 127.0.0.1:$SS_PORT..."
    /app/ssserver -c "$SS_CONFIG" &
    SS_PID=$!
    sleep 1

    # Check if ssserver started successfully
    if ! kill -0 $SS_PID 2>/dev/null; then
        print_error "Failed to start Shadowsocks server"
        exit 1
    fi
    print_success "Shadowsocks server started (PID: $SS_PID)"

    # Build plugin options
    PLUGIN_OPTS=$(build_plugin_opts)

    # Generate ss:// URL
    SS_URL=$(generate_ss_url "$SS_METHOD" "$SS_PASSWORD" "$DOMAIN" "$DNS_PORT" "$PLUGIN_OPTS" "Slipstream-$DOMAIN")

    # Save and display client configuration
    save_client_config "$SS_URL" "$PLUGIN_OPTS"
    print_client_config "$SS_URL" "$PLUGIN_OPTS"

    # Build slipstream-server arguments
    SLIPSTREAM_ARGS="--target-address 127.0.0.1:$SS_PORT"
    SLIPSTREAM_ARGS="$SLIPSTREAM_ARGS --domain $DOMAIN --cert $CERT_PATH --key $KEY_PATH"
    SLIPSTREAM_ARGS="$SLIPSTREAM_ARGS --dns-listen-port $DNS_PORT"
    SLIPSTREAM_ARGS="$SLIPSTREAM_ARGS --reset-seed $RESET_SEED_PATH"

    # Start slipstream-server in foreground
    print_info "Starting Slipstream server on 0.0.0.0:$DNS_PORT/udp..."
    print_info "Tunnel is ready! Waiting for connections..."
    echo ""
    print_line "-" 60
    echo ""

    # Handle graceful shutdown
    trap 'print_info "Shutting down..."; kill $SS_PID 2>/dev/null; exit 0' SIGTERM SIGINT

    # Run slipstream-server in foreground
    exec /app/slipstream-server $SLIPSTREAM_ARGS
}

main "$@"
