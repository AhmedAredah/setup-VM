#!/usr/bin/env bash
# If executed under sh (not bash), re-execute under bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail
trap 'print_error "An unexpected error occurred on line $LINENO. Exiting."; exit 1' ERR

# ============================================================================
# Color helpers and output functions
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

print_info()    { printf "${YELLOW}[INFO]${RESET}  %s\n" "$*"; }
print_success() { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
print_error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
die()           { print_error "$*"; exit 1; }

print_banner() {
    printf "${CYAN}${BOLD}"
    printf "================================================\n"
    printf "  Azure VM Setup Script\n"
    printf "  Docker + nginx + neofetch\n"
    printf "================================================\n"
    printf "${RESET}\n"
}

# ============================================================================
# Resolve actual user and HOME (for sudo invocations)
# ============================================================================

resolve_actual_user() {
    ACTUAL_USER="${SUDO_USER:-${USER:-$(logname 2>/dev/null || echo '')}}"

    if [ -z "$ACTUAL_USER" ] || [ "$ACTUAL_USER" = "root" ]; then
        ACTUAL_USER="root"
        print_info "Running as root."
    else
        # Correct HOME when running with sudo
        ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6)
        if [ -n "$ACTUAL_HOME" ]; then
            HOME="$ACTUAL_HOME"
        fi
        print_info "Actual user: $ACTUAL_USER, HOME: $HOME"
    fi
}

# ============================================================================
# Distribution detection
# ============================================================================

detect_distro() {
    if [ ! -f /etc/os-release ]; then
        die "/etc/os-release not found. Cannot detect distribution."
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    DISTRO_ID="${ID:-unknown}"
    DISTRO_ID_LIKE="${ID_LIKE:-}"

    case "$DISTRO_ID" in
        ubuntu | debian | linuxmint | pop)
            DISTRO_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        rhel | centos | almalinux | rocky | "red hat enterprise linux")
            DISTRO_FAMILY="rhel"
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        fedora)
            DISTRO_FAMILY="fedora"
            PKG_MANAGER="dnf"
            ;;
        alpine)
            DISTRO_FAMILY="alpine"
            PKG_MANAGER="apk"
            ;;
        *)
            case "$DISTRO_ID_LIKE" in
                *debian* | *ubuntu*)
                    DISTRO_FAMILY="debian"
                    PKG_MANAGER="apt"
                    ;;
                *rhel* | *centos* | *fedora*)
                    DISTRO_FAMILY="rhel"
                    PKG_MANAGER=$(command -v dnf >/dev/null 2>&1 && echo "dnf" || echo "yum")
                    ;;
                *)
                    die "Unsupported distribution: $DISTRO_ID. Supported: Ubuntu/Debian, RHEL/CentOS/Alma/Rocky, Fedora, Alpine."
                    ;;
            esac
            ;;
    esac

    print_info "Detected distribution: $DISTRO_ID (family: $DISTRO_FAMILY, package manager: $PKG_MANAGER)"
}

# ============================================================================
# Docker installation per distro
# ============================================================================

install_docker_ubuntu_debian() {
    print_info "Installing Docker CE for Debian/Ubuntu..."

    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    chmod a+r /etc/apt/keyrings/docker.gpg

    printf "deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n" \
        "$(dpkg --print-architecture)" "$DISTRO_ID" "$(. /etc/os-release && echo "$VERSION_CODENAME")" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    print_success "Docker CE installed (Debian/Ubuntu)."
}

install_docker_rhel() {
    print_info "Installing Docker CE for RHEL-family..."

    $PKG_MANAGER install -y epel-release 2>/dev/null || true
    $PKG_MANAGER install -y yum-utils

    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true

    $PKG_MANAGER install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    print_success "Docker CE installed (RHEL-family)."
}

install_docker_fedora() {
    print_info "Installing Docker CE for Fedora..."

    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null || true
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    print_success "Docker CE installed (Fedora)."
}

install_docker_alpine() {
    print_info "Installing Docker for Alpine Linux..."

    if ! grep -q "^https://dl-cdn.alpinelinux.org/alpine/.*/community" /etc/apk/repositories 2>/dev/null; then
        ALPINE_VER=$(. /etc/os-release && echo "$VERSION_ID" | cut -d. -f1-2)
        echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories
    fi

    apk update
    apk add docker docker-cli-compose

    print_success "Docker installed (Alpine)."
}

install_docker() {
    case "$DISTRO_FAMILY" in
        debian)  install_docker_ubuntu_debian ;;
        rhel)    install_docker_rhel ;;
        fedora)  install_docker_fedora ;;
        alpine)  install_docker_alpine ;;
    esac
}

# ============================================================================
# Docker service setup + user group
# ============================================================================

setup_docker_service() {
    print_info "Enabling and starting Docker service..."

    if [ "$DISTRO_FAMILY" = "alpine" ]; then
        rc-update add docker default 2>/dev/null || true
        service docker start 2>/dev/null || true
    else
        systemctl enable docker 2>/dev/null || true
        systemctl start docker 2>/dev/null || true
    fi

    if [ "$ACTUAL_USER" = "root" ]; then
        print_info "Running as root. Skipping docker group add (root has docker access by default)."
    else
        if [ "$DISTRO_FAMILY" = "alpine" ]; then
            addgroup "$ACTUAL_USER" docker 2>/dev/null || true
        else
            usermod -aG docker "$ACTUAL_USER" 2>/dev/null || true
        fi
        print_success "User '$ACTUAL_USER' added to the docker group."
        print_info "NOTE: You must log out and back in (or run 'newgrp docker') for group membership to take effect."
    fi
}

# ============================================================================
# Docker network prompt and creation
# ============================================================================

DOCKER_NETWORK_NAME="${1:-}"

prompt_docker_network() {
    if [ -z "$DOCKER_NETWORK_NAME" ]; then
        if [ ! -t 0 ]; then
            die "No TTY detected and no network name provided. Run: sh setup-vm.sh <network-name>"
        fi

        while true; do
            printf "${YELLOW}Enter the Docker network name to create: ${RESET}"
            read -r DOCKER_NETWORK_NAME

            if [ -z "$DOCKER_NETWORK_NAME" ]; then
                print_error "Network name cannot be empty. Please try again."
            else
                break
            fi
        done
    fi

    print_info "Creating Docker network: $DOCKER_NETWORK_NAME"

    if docker network create "$DOCKER_NETWORK_NAME" 2>/dev/null; then
        print_success "Docker network '$DOCKER_NETWORK_NAME' created."
    else
        print_info "Docker network '$DOCKER_NETWORK_NAME' may already exist. Continuing."
    fi
}

# ============================================================================
# Create nginx folder structure and files
# ============================================================================

create_nginx_structure() {
    NGINX_DIR="${HOME}/nginx"
    print_info "Creating nginx directory structure at $NGINX_DIR..."

    mkdir -p "$NGINX_DIR/logs"
    mkdir -p "$NGINX_DIR/config"

    # Write minimal nginx.conf
    cat > "$NGINX_DIR/config/nginx.conf" << 'NGINX_EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile        on;
    keepalive_timeout 65;

    server {
        listen 80;
        server_name _;

        location / {
            root   /usr/share/nginx/html;
            index  index.html index.htm;
        }

        error_page 404 /404.html;
        error_page 500 502 503 504 /50x.html;

        location = /50x.html {
            root /usr/share/nginx/html;
        }
    }
}
NGINX_EOF

    # Write docker-compose.yml (unquoted heredoc for variable expansion)
    cat > "$NGINX_DIR/docker-compose.yml" << COMPOSE_EOF
services:
  nginx:
    image: nginx:latest
    container_name: nginx
    restart: always
    ports:
      - "80:80"
    volumes:
      - ./config/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./logs:/var/log/nginx
    networks:
      - ${DOCKER_NETWORK_NAME}

networks:
  ${DOCKER_NETWORK_NAME}:
    external: true
COMPOSE_EOF

    print_success "nginx structure created at $NGINX_DIR"
}

# ============================================================================
# Install neofetch per distro
# ============================================================================

install_neofetch() {
    print_info "Installing neofetch..."

    case "$DISTRO_FAMILY" in
        debian)
            apt-get install -y neofetch
            ;;
        rhel)
            $PKG_MANAGER install -y epel-release 2>/dev/null || true
            $PKG_MANAGER install -y neofetch 2>/dev/null || \
                print_error "neofetch install failed. On RHEL, ensure EPEL is accessible."
            ;;
        fedora)
            dnf install -y neofetch
            ;;
        alpine)
            apk add neofetch
            ;;
    esac

    print_success "neofetch installed."
}

# ============================================================================
# Patch .bashrc (idempotent)
# ============================================================================

patch_bashrc() {
    BASHRC="${HOME}/.bashrc"
    MARKER="# --- setup-vm.sh additions ---"

    if grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
        print_info ".bashrc already patched. Skipping."
        return 0
    fi

    print_info "Appending neofetch and public IP to ~/.bashrc..."

    cat >> "$BASHRC" << 'BASHRC_EOF'

# --- setup-vm.sh additions ---
neofetch
echo "Public IP: $(curl -s ifconfig.me)"
# --- end setup-vm.sh additions ---
BASHRC_EOF

    print_success ".bashrc updated."
}

# ============================================================================
# Summary
# ============================================================================

print_summary() {
    printf "\n${GREEN}${BOLD}"
    printf "================================================\n"
    printf "  Setup Complete!\n"
    printf "================================================\n"
    printf "${RESET}\n"
    print_success "Docker CE installed and running"
    print_success "Docker network '$DOCKER_NETWORK_NAME' created"
    print_success "nginx structure created at ~/nginx"
    print_success "neofetch installed"
    print_success "~/.bashrc updated with neofetch and public IP"

    printf "\n${YELLOW}${BOLD}Next steps:${RESET}\n"
    printf "  1. Log out and back in to activate docker group membership\n"
    printf "     (or run: ${CYAN}newgrp docker${RESET})\n"
    printf "  2. Start nginx:\n"
    printf "     ${CYAN}cd ~/nginx && docker compose up -d${RESET}\n"
    printf "  3. Verify nginx is running:\n"
    printf "     ${CYAN}curl http://localhost${RESET}\n"
    printf "\n"
}

# ============================================================================
# Main
# ============================================================================

main() {
    print_banner
    resolve_actual_user
    detect_distro
    install_docker
    setup_docker_service
    prompt_docker_network
    create_nginx_structure
    install_neofetch
    patch_bashrc
    print_summary
}

main "$@"
