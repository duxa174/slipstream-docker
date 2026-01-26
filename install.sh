#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

REPO_URL="https://github.com/dalisyron/slipstream-docker.git"
DEFAULT_REPO_DIR="${HOME:-/root}/slipstream-docker"
IMAGE_NAME="slipstream-ss"
CONTAINER_NAME="slipstream-ss"
DATA_VOLUME="slipstream-data"
HOST_DNS_PORT_DEFAULT="53"

log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

has_tty() {
  [ -t 0 ] && [ -t 1 ]
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This installer must be run as root. Example: sudo bash install.sh"
  fi
}

require_script_deps() {
  local missing=()
  for dep in curl git; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing+=("$dep")
    fi
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    die "Missing required dependencies for this installer: ${missing[*]}. Install them first, then re-run."
  fi
}

setup_prompt_fd() {
  if [ -t 0 ]; then
    PROMPT_FD=0
  elif [ -r /dev/tty ]; then
    exec 3</dev/tty
    PROMPT_FD=3
  else
    die "No TTY available for interactive prompts."
  fi
}

prompt_yn() {
  local prompt="$1"
  local default="$2"
  local reply=""
  local suffix=""

  if [ "$default" = "Y" ]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  while true; do
    read -r -u "$PROMPT_FD" -p "$prompt $suffix " reply || die "Input cancelled."
    reply="${reply:-$default}"
    case "$reply" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
  done
}

prompt_input() {
  local prompt="$1"
  local default="${2:-}"
  local reply=""

  if [ -n "$default" ]; then
    read -r -u "$PROMPT_FD" -p "$prompt [$default]: " reply || die "Input cancelled."
    reply="${reply:-$default}"
  else
    read -r -u "$PROMPT_FD" -p "$prompt: " reply || die "Input cancelled."
  fi
  printf '%s' "$reply"
}

is_repo_root() {
  local dir="$1"
  [ -f "$dir/Dockerfile" ] && [ -f "$dir/entrypoint.sh" ] && [ -f "$dir/config.sh" ]
}

detect_repo_dir() {
  local script_dir=""
  local cwd=""

  if [ -n "${BASH_SOURCE[0]-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  cwd="$(pwd)"

  if [ -n "$script_dir" ] && is_repo_root "$script_dir"; then
    REPO_DIR="$script_dir"
    return
  fi
  if is_repo_root "$cwd"; then
    REPO_DIR="$cwd"
    return
  fi

  REPO_DIR="$DEFAULT_REPO_DIR"
  log "Repository not found. Cloning to $REPO_DIR"
  if [ -e "$REPO_DIR" ] && [ ! -d "$REPO_DIR/.git" ]; then
    die "Target directory exists and is not a git repo: $REPO_DIR"
  fi
  if [ -d "$REPO_DIR/.git" ]; then
    log "Using existing repo at $REPO_DIR"
  else
    git clone --recurse-submodules "$REPO_URL" "$REPO_DIR"
  fi
}

ensure_submodule() {
  if [ ! -f "$REPO_DIR/slipstream-rust/Cargo.toml" ]; then
    warn "slipstream-rust submodule is missing."
    if prompt_yn "Initialize submodules now?" "Y"; then
      git -C "$REPO_DIR" submodule update --init --recursive
    else
      die "slipstream-rust submodule is required to build the container."
    fi
  fi
}

detect_os() {
  OS_ID=""
  OS_LIKE=""
  OS_VERSION_CODENAME=""
  UBUNTU_CODENAME=""
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
    UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"
  fi

  OS_FAMILY="unknown"
  case "$OS_ID" in
    ubuntu|debian|raspbian|linuxmint) OS_FAMILY="debian" ;;
    fedora) OS_FAMILY="fedora" ;;
    rhel|centos|rocky|almalinux|ol) OS_FAMILY="rhel" ;;
    arch|manjaro|endeavouros) OS_FAMILY="arch" ;;
    opensuse*|sles|sled) OS_FAMILY="suse" ;;
    alpine) OS_FAMILY="alpine" ;;
  esac

  if [ "$OS_FAMILY" = "unknown" ]; then
    if echo "$OS_LIKE" | grep -qi "debian"; then
      OS_FAMILY="debian"
    elif echo "$OS_LIKE" | grep -Eqi "rhel|fedora|centos"; then
      OS_FAMILY="rhel"
    elif echo "$OS_LIKE" | grep -qi "arch"; then
      OS_FAMILY="arch"
    fi
  fi

  if [ "$OS_FAMILY" = "unknown" ]; then
    die "Unsupported Linux distribution. Please install Docker manually and re-run."
  fi
}

install_docker_debian() {
  local docker_os="$OS_ID"
  local codename="$OS_VERSION_CODENAME"

  if [ "$OS_ID" = "linuxmint" ]; then
    docker_os="ubuntu"
    codename="${UBUNTU_CODENAME:-$codename}"
  fi
  if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -cs || true)"
  fi
  if [ -z "$codename" ]; then
    die "Unable to determine distro codename for Docker repo."
  fi

  log "Installing Docker Engine (apt)"
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${docker_os}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_os} ${codename} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_fedora() {
  log "Installing Docker Engine (dnf)"
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
  dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rhel() {
  log "Installing Docker Engine (yum/dnf)"
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    yum -y install yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
}

install_docker_arch() {
  log "Installing Docker Engine (pacman)"
  pacman -Sy --noconfirm docker docker-compose docker-buildx
}

install_docker_suse() {
  log "Installing Docker Engine (zypper)"
  zypper refresh
  zypper install -y docker docker-compose
}

install_docker_alpine() {
  log "Installing Docker Engine (apk)"
  apk add --no-cache docker docker-cli-compose
}

install_docker() {
  case "$OS_FAMILY" in
    debian) install_docker_debian ;;
    fedora) install_docker_fedora ;;
    rhel) install_docker_rhel ;;
    arch) install_docker_arch ;;
    suse) install_docker_suse ;;
    alpine) install_docker_alpine ;;
    *) die "Unsupported Linux distribution. Please install Docker manually." ;;
  esac
}

install_compose_plugin() {
  case "$OS_FAMILY" in
    debian) apt-get install -y docker-compose-plugin docker-buildx-plugin ;;
    fedora) dnf -y install docker-compose-plugin docker-buildx-plugin ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then
        dnf -y install docker-compose-plugin docker-buildx-plugin
      else
        yum -y install docker-compose-plugin docker-buildx-plugin
      fi
      ;;
    arch) pacman -Sy --noconfirm docker-compose docker-buildx ;;
    suse) zypper install -y docker-compose ;;
    alpine) apk add --no-cache docker-cli-compose ;;
    *) die "Unsupported Linux distribution. Please install docker compose plugin manually." ;;
  esac
}

ensure_docker_running() {
  if docker info >/dev/null 2>&1; then
    return
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || true
  elif command -v service >/dev/null 2>&1; then
    service docker start || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service docker start || true
  fi

  sleep 1
  docker info >/dev/null 2>&1 || die "Docker daemon is not running. Please start docker and re-run."
}

is_valid_port() {
  local port="$1"
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    return 1
  fi
}

is_udp_port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lunH "sport = :$port" 2>/dev/null | grep -q .
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lun 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -i UDP:"$port" >/dev/null 2>&1
    return $?
  fi
  return 2
}

choose_dns_port() {
  HOST_DNS_PORT="${HOST_DNS_PORT:-$HOST_DNS_PORT_DEFAULT}"
  if ! is_valid_port "$HOST_DNS_PORT"; then
    warn "Invalid HOST_DNS_PORT='$HOST_DNS_PORT'. Falling back to $HOST_DNS_PORT_DEFAULT."
    HOST_DNS_PORT="$HOST_DNS_PORT_DEFAULT"
  fi

  if [ "$HOST_DNS_PORT" != "$HOST_DNS_PORT_DEFAULT" ]; then
    return
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      warn "systemd-resolved is active and may be using UDP port 53."
    fi
  fi

  if is_udp_port_in_use "$HOST_DNS_PORT_DEFAULT"; then
    warn "UDP port 53 appears to be in use."
    if prompt_yn "Use an alternate host UDP port instead?" "Y"; then
      while true; do
        local port
        port="$(prompt_input "Enter alternate UDP port" "5353")"
        if is_valid_port "$port"; then
          HOST_DNS_PORT="$port"
          break
        fi
        warn "Invalid port. Please enter a number between 1 and 65535."
      done
    else
      warn "Continuing with port 53 (this may fail if the port is busy)."
    fi
  elif [ "$?" -eq 2 ]; then
    warn "Unable to check whether UDP port 53 is in use. Continuing."
  fi
}

build_image() {
  log "Building Docker image ($IMAGE_NAME). This can take a while on first run."
  DOCKER_BUILDKIT=1 docker build -t "$IMAGE_NAME" "$REPO_DIR"
}

run_interactive_container() {
  if ! has_tty; then
    warn "No TTY detected for docker run; interactive setup requires a TTY."
    cat <<EOF
Re-run from an interactive shell, for example:
  ssh -t user@host "curl -fsSL https://raw.githubusercontent.com/dalisyron/slipstream-docker/main/install.sh | sudo bash"

Or run locally with:
  sudo ./install.sh

If you prefer non-interactive setup, re-run and choose 'No' when prompted.
EOF
    return
  fi
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    warn "Container '$CONTAINER_NAME' is already running."
    printf 'You can view logs with: docker logs -f %s\n' "$CONTAINER_NAME"
    return
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    if prompt_yn "Container '$CONTAINER_NAME' exists but is stopped. Start it now?" "Y"; then
      docker start -ai "$CONTAINER_NAME"
      return
    fi
    if prompt_yn "Remove existing container (data volume preserved)?" "Y"; then
      docker rm "$CONTAINER_NAME"
    else
      return
    fi
  fi

  log "Starting interactive setup. Follow the prompts to generate your ss:// link."
  docker run -it --name "$CONTAINER_NAME" \
    -p "$HOST_DNS_PORT":53/udp \
    -v "$DATA_VOLUME":/data \
    "$IMAGE_NAME"
}

print_noninteractive_instructions() {
  cat <<EOF

Non-interactive setup example:

  docker run -d --name ${CONTAINER_NAME} \\
    -p ${HOST_DNS_PORT}:53/udp \\
    -v ${DATA_VOLUME}:/data \\
    -e DOMAIN=your.domain.example \\
    -e MODE=recursive \\
    -e RESOLVER=8.8.8.8 \\
    -e NON_INTERACTIVE=true \\
    ${IMAGE_NAME}

To retrieve the ss:// link later:

  docker exec ${CONTAINER_NAME} cat /data/config/client-config.txt

If you need to re-run configuration, set FORCE_RECONFIGURE=true or remove the volume:
  docker volume rm ${DATA_VOLUME}
EOF
}

main() {
  require_root
  require_script_deps
  setup_prompt_fd

  detect_repo_dir
  cd "$REPO_DIR"
  ensure_submodule

  detect_os

  if ! command -v docker >/dev/null 2>&1; then
    if prompt_yn "Docker Engine is missing. Install it now?" "Y"; then
      install_docker
    else
      die "Docker is required to run this repository."
    fi
  fi

  if ! docker compose version >/dev/null 2>&1; then
    if prompt_yn "Docker Compose plugin is missing. Install it now?" "Y"; then
      install_compose_plugin
    else
      warn "Docker Compose plugin not installed. You can still use docker run."
    fi
  fi

  ensure_docker_running
  choose_dns_port

  if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    if prompt_yn "Docker image '$IMAGE_NAME' already exists. Rebuild?" "N"; then
      build_image
    fi
  else
    build_image
  fi

  log "Dependencies ready."
  if prompt_yn "Proceed with interactive server setup now?" "Y"; then
    run_interactive_container
  else
    print_noninteractive_instructions
  fi
}

main "$@"
