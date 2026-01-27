#!/bin/bash
# config.sh - Helper functions for slipstream-docker setup wizard

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Config file path
CONFIG_FILE="/data/config/settings.env"
CLIENT_CONFIG_FILE="/data/config/client-config.txt"

# Print colored text
print_color() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
}

print_info() {
    echo -e "${BLUE}$*${NC}"
}

print_success() {
    echo -e "${GREEN}$*${NC}"
}

print_warning() {
    echo -e "${YELLOW}$*${NC}"
}

print_error() {
    echo -e "${RED}$*${NC}"
}

print_bold() {
    echo -e "${BOLD}$*${NC}"
}

# Print a horizontal line
print_line() {
    local char="${1:-=}"
    local width="${2:-60}"
    printf '%*s\n' "$width" '' | tr ' ' "$char"
}

# Print a box around text
print_box() {
    local title="$1"
    local width=62

    echo ""
    printf "${CYAN}+%s+${NC}\n" "$(printf '%*s' $((width-2)) '' | tr ' ' '-')"
    printf "${CYAN}|${NC} ${BOLD}%-$((width-4))s${NC} ${CYAN}|${NC}\n" "$title"
    printf "${CYAN}+%s+${NC}\n" "$(printf '%*s' $((width-2)) '' | tr ' ' '-')"
}

# Print header for setup wizard
print_header() {
    echo ""
    print_color "$CYAN" "========================================"
    print_color "$CYAN" "   Slipstream + Shadowsocks Setup"
    print_color "$CYAN" "========================================"
    echo ""
}

# Prompt for input with default value
prompt_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local result

    if [ -n "$default" ]; then
        echo -n -e "${BOLD}$prompt${NC} [${CYAN}$default${NC}]: "
    else
        echo -n -e "${BOLD}$prompt${NC}: "
    fi

    read -r result

    if [ -z "$result" ] && [ -n "$default" ]; then
        result="$default"
    fi

    eval "$var_name=\"$result\""
}

# Prompt for choice (1 or 2)
prompt_choice() {
    local prompt="$1"
    local var_name="$2"
    local result

    while true; do
        echo -n -e "${BOLD}$prompt${NC}: "
        read -r result

        if [ "$result" = "1" ] || [ "$result" = "2" ]; then
            eval "$var_name=\"$result\""
            return 0
        else
            print_error "Please enter 1 or 2"
        fi
    done
}

# Prompt for yes/no with default
prompt_yn() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local result

    local yn_hint
    if [ "$default" = "y" ]; then
        yn_hint="[Y/n]"
    else
        yn_hint="[y/N]"
    fi

    echo -n -e "${BOLD}$prompt${NC} $yn_hint: "
    read -r result

    if [ -z "$result" ]; then
        result="$default"
    fi

    result=$(echo "$result" | tr '[:upper:]' '[:lower:]')

    if [ "$result" = "y" ] || [ "$result" = "yes" ]; then
        eval "$var_name=true"
    else
        eval "$var_name=false"
    fi
}

# Generate secure random password
generate_password() {
    openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

# Validate domain format (basic check)
validate_domain() {
    local domain="$1"
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
        return 0
    fi
    return 1
}

# Validate IP address format
validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# Save configuration to file
save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# Slipstream Docker Configuration
# Generated on $(date)

DOMAIN="$DOMAIN"
MODE="$MODE"
RESOLVER="$RESOLVER"
SERVER_IP="$SERVER_IP"
SS_PASSWORD="$SS_PASSWORD"
SS_METHOD="$SS_METHOD"
KEEP_ALIVE_INTERVAL="$KEEP_ALIVE_INTERVAL"
CERT_SHA256="$CERT_SHA256"
CERT_PATH="$CERT_PATH"
KEY_PATH="$KEY_PATH"
RESET_SEED_PATH="$RESET_SEED_PATH"
EXPECTED_PUBLIC_IP="$EXPECTED_PUBLIC_IP"
EOF
    chmod 600 "$CONFIG_FILE"
}

# Load configuration from file
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# Check if config exists
config_exists() {
    [ -f "$CONFIG_FILE" ]
}

# Save client configuration
save_client_config() {
    local ss_url="$1"
    local plugin_opts="$2"

    mkdir -p "$(dirname "$CLIENT_CONFIG_FILE")"

    cat > "$CLIENT_CONFIG_FILE" << EOF
=== Slipstream + Shadowsocks Client Configuration ===
Generated on: $(date)

Domain:      $DOMAIN
Password:    $SS_PASSWORD
Method:      $SS_METHOD
Keep Alive:  $KEEP_ALIVE_INTERVAL
Mode:        $([ "$MODE" = "recursive" ] && echo "Recursive (via $RESOLVER)" || echo "Authoritative ($SERVER_IP)")
Cert SHA256: $CERT_SHA256

=== ss:// URL (copy to Android Shadowsocks app) ===

$ss_url

=== Plugin Options (for manual setup) ===

$plugin_opts
EOF
    chmod 600 "$CLIENT_CONFIG_FILE"
}

# Generate ss:// URL
generate_ss_url() {
    local method="$1"
    local password="$2"
    local server="$3"
    local port="$4"
    local plugin_opts="$5"
    local name="$6"

    # Base64 encode method:password
    local userinfo=$(echo -n "$method:$password" | base64 -w 0)

    # URL encode plugin opts
    local encoded_opts=$(echo -n "$plugin_opts" | jq -sRr @uri)

    # URL encode name
    local encoded_name=$(echo -n "$name" | jq -sRr @uri)

    echo "ss://${userinfo}@${server}:${port}/?plugin=slipstream%3B${encoded_opts}#${encoded_name}"
}

# Print client configuration box
print_client_config() {
    local ss_url="$1"
    local plugin_opts="$2"

    local mode_display
    if [ "$MODE" = "recursive" ]; then
        mode_display="Recursive (via $RESOLVER)"
    else
        mode_display="Authoritative ($SERVER_IP)"
    fi

    echo ""
    echo -e "${CYAN}+==============================================================+${NC}"
    echo -e "${CYAN}|${NC}                  ${BOLD}CLIENT CONFIGURATION${NC}                       ${CYAN}|${NC}"
    echo -e "${CYAN}+==============================================================+${NC}"
    echo -e "${CYAN}|${NC}                                                              ${CYAN}|${NC}"
    printf "${CYAN}|${NC}  Domain:      ${GREEN}%-44s${NC} ${CYAN}|${NC}\n" "$DOMAIN"
    printf "${CYAN}|${NC}  Password:    ${GREEN}%-44s${NC} ${CYAN}|${NC}\n" "$SS_PASSWORD"
    printf "${CYAN}|${NC}  Method:      ${GREEN}%-44s${NC} ${CYAN}|${NC}\n" "$SS_METHOD"
    printf "${CYAN}|${NC}  Mode:        ${GREEN}%-44s${NC} ${CYAN}|${NC}\n" "$mode_display"
    printf "${CYAN}|${NC}  Cert SHA256: ${GREEN}%-44s${NC} ${CYAN}|${NC}\n" "${CERT_SHA256:0:44}"
    if [ ${#CERT_SHA256} -gt 44 ]; then
        printf "${CYAN}|${NC}               ${GREEN}%-44s${NC} ${CYAN}|${NC}\n" "${CERT_SHA256:44}"
    fi
    echo -e "${CYAN}|${NC}                                                              ${CYAN}|${NC}"
    echo -e "${CYAN}+--------------------------------------------------------------+${NC}"
    echo -e "${CYAN}|${NC}  ${BOLD}COPY THIS ss:// URL TO YOUR ANDROID SHADOWSOCKS APP:${NC}        ${CYAN}|${NC}"
    echo -e "${CYAN}+--------------------------------------------------------------+${NC}"
    echo -e "${CYAN}|${NC}                                                              ${CYAN}|${NC}"
    echo -e "${YELLOW}$ss_url${NC}"
    echo -e "${CYAN}|${NC}                                                              ${CYAN}|${NC}"
    echo -e "${CYAN}+--------------------------------------------------------------+${NC}"
    echo -e "${CYAN}|${NC}  ${BOLD}Plugin Options (for manual setup):${NC}                         ${CYAN}|${NC}"
    echo -e "${CYAN}|${NC}  $plugin_opts"
    echo -e "${CYAN}|${NC}                                                              ${CYAN}|${NC}"
    printf "${CYAN}|${NC}  Config saved to: ${BLUE}%-40s${NC} ${CYAN}|${NC}\n" "$CLIENT_CONFIG_FILE"
    echo -e "${CYAN}+==============================================================+${NC}"
    echo ""
}
