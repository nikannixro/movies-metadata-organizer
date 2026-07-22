#!/usr/bin/env bash
# ============================================================================
# Kaelix — Unix/macOS Installer
# https://github.com/nikannixro/kaelix
# ============================================================================
set -euo pipefail

REPO_URL="https://github.com/nikannixro/kaelix.git"
REPO_NAME="kaelix"

# --- Colors -------------------------------------------------------------------

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
GRAY='\033[0;37m'
NC='\033[0m'

# --- Logging ------------------------------------------------------------------

LOG_DIR="${HOME}/.kaelix"
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# --- Output helpers ------------------------------------------------------------

banner() {
    local width
    width=$(tput cols 2>/dev/null || echo 80)
    local height
    height=$(tput lines 2>/dev/null || echo 24)
    local max_len=41
    local banner_height=5
    local top_pad=$(( (height - banner_height) / 2 ))
    local left_pad
    left_pad=$(printf '%*s' $(( (width - max_len) / 2 )) '')
    local i

    for ((i = 0; i < top_pad; i++)); do echo ""; done
    echo -e "${GREEN}${left_pad}=========================================${NC}"
    echo -e "${GREEN}${left_pad}            K A E L I X${NC}"
    echo -e "${GREEN}${left_pad}=========================================${NC}"
    echo ""
}

step() {
    local num=$1 total=$2
    shift 2
    echo -ne "  ${GRAY}[${NC}${YELLOW}${num}/${total}${NC}${GRAY}]${NC} "
    echo "$*"
}

echo_ok() {
    echo -e "       ${GREEN}✓ $*${NC}"
    log "SUCCESS" "$*"
}

echo_fail() {
    echo -e "       ${RED}✗ $*${NC}"
    log "ERROR" "$*"
}

echo_warn() {
    echo -e "       ${YELLOW}⚠ $*${NC}"
    log "WARN" "$*"
}

echo_info() {
    echo -e "       ${BLUE}⟳ $*${NC}"
    log "INFO" "$*"
}

has() { command -v "$1" >/dev/null 2>&1; }

# --- Root detection ------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo_fail "This script must be run as root."
        echo -e "       ${YELLOW}Please run: sudo bash install.sh${NC}"
        exit 1
    fi
}

# --- Download with retry -------------------------------------------------------

download_file() {
    local url="$1"
    local output="$2"
    local max_retries="${3:-3}"
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        echo_info "Downloading: $url (attempt $attempt/$max_retries)"
        log "INFO" "Downloading: $url (attempt $attempt/$max_retries)"

        if has curl; then
            if curl -L --progress-bar -o "$output" "$url" 2>&1; then
                echo_ok "Download complete."
                log "SUCCESS" "Download complete: $output"
                return 0
            fi
        elif has wget; then
            if wget --show-progress -O "$output" "$url" 2>&1; then
                echo_ok "Download complete."
                log "SUCCESS" "Download complete: $output"
                return 0
            fi
        fi

        echo_warn "Download failed. Retrying in $((attempt * 2)) seconds..."
        log "WARN" "Download failed, retrying..."
        sleep $((attempt * 2))
        attempt=$((attempt + 1))
    done

    echo_fail "Download failed after $max_retries attempts."
    log "ERROR" "Download failed: $url"
    return 1
}

# --- OS and distro detection ---------------------------------------------------

detect_os() {
    OS=""
    DISTRO=""

    case "$(uname -s)" in
        Linux*)
            case "$(uname -o)" in
                GNU/Linux)
                    OS="linux"
                    detect_distro
                    ;;
                *)
                    OS="wsl"
                    DISTRO="${WSL_DISTRO_NAME:-unknown}"
                    ;;
            esac
            ;;
        Darwin*)
            OS="macos"
            ;;
        *)
            echo_fail "Unsupported operating system: $(uname -s). Use install.ps1 for Windows."
            exit 1
            ;;
    esac
}

detect_distro() {
    if [ ! -f /etc/os-release ]; then
        echo_fail "Cannot detect Linux distribution."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        ubuntu)              DISTRO="ubuntu" ;;
        debian)              DISTRO="debian" ;;
        linuxmint)           DISTRO="linuxmint" ;;
        arch|manjaro|endeavouros) DISTRO="arch" ;;
        fedora)              DISTRO="fedora" ;;
        centos)              DISTRO="centos" ;;
        rhel|rocky|almalinux) DISTRO="rhel" ;;
        opensuse*|suse)      DISTRO="opensuse" ;;
        alpine)              DISTRO="alpine" ;;
        void)                DISTRO="void" ;;
        nixos)               DISTRO="nixos" ;;
        *)
            case "${ID_LIKE:-}" in
                ubuntu|debian) DISTRO="debian" ;;
                arch)          DISTRO="arch" ;;
                fedora|rhel)   DISTRO="rhel" ;;
                suse)          DISTRO="opensuse" ;;
                *)             DISTRO="unknown" ;;
            esac
            ;;
    esac
}

# --- Dependency installation ---------------------------------------------------

install_deps() {
    case "$OS" in
        linux)
            install_deps_linux
            ;;
        macos)
            install_deps_macos
            ;;
    esac
}

install_deps_linux() {
    case "$DISTRO" in
        ubuntu|debian|linuxmint)
            install_deps_debian
            ;;
        arch|manjaro|endeavouros)
            install_deps_arch
            ;;
        fedora)
            install_deps_fedora
            ;;
        centos|rhel)
            install_deps_rhel
            ;;
        opensuse)
            install_deps_opensuse
            ;;
        alpine)
            install_deps_alpine
            ;;
        void)
            install_deps_void
            ;;
        nixos)
            install_deps_nixos
            ;;
        *)
            install_deps_fallback
            ;;
    esac
}

install_deps_debian() {
    echo_info "Installing dependencies (apt)..."
    apt-get update -y -qq
    apt-get install -y -qq git python3 python3-pip mkvtoolnix ffmpeg
    echo_ok "System dependencies installed."
}

install_deps_arch() {
    echo_info "Installing dependencies (pacman)..."
    pacman -Sy --noconfirm --quiet git python python-pip mkvtoolnix ffmpeg
    echo_ok "System dependencies installed."
}

install_deps_fedora() {
    echo_info "Installing dependencies (dnf)..."
    dnf install -y python3 python3-pip git mkvtoolnix ffmpeg
    echo_ok "System dependencies installed."
}

install_deps_rhel() {
    echo_info "Installing dependencies (yum/dnf)..."
    if has dnf; then
        dnf install -y python3 python3-pip git mkvtoolnix ffmpeg
    else
        yum install -y python3 python3-pip git mkvtoolnix ffmpeg
    fi
    echo_ok "System dependencies installed."
}

install_deps_opensuse() {
    echo_info "Installing dependencies (zypper)..."
    zypper install -y python3 python3-pip git mkvtoolnix ffmpeg
    echo_ok "System dependencies installed."
}

install_deps_alpine() {
    echo_info "Installing dependencies (apk)..."
    apk add python3 py3-pip git mkvtoolnix ffmpeg
    echo_ok "System dependencies installed."
}

install_deps_void() {
    echo_info "Installing dependencies (xbps)..."
    xbps-install -Sy git python3 python3-pip mkvtoolnix ffmpeg
    echo_ok "System dependencies installed."
}

install_deps_nixos() {
    echo_info "Installing dependencies (nix)..."
    nix-env -i git python3 mkvtoolnix ffmpeg
    echo_ok "System dependencies installed."
}

install_deps_fallback() {
    echo_warn "Unknown distribution, attempting fallback..."

    # Try snap first
    if has snap; then
        echo_info "Trying snap..."
        snap install python3 --classic 2>/dev/null || true
        snap install ffmpeg 2>/dev/null || true
    fi

    # Try flatpak
    if has flatpak; then
        echo_info "Trying flatpak..."
        flatpak install -y flathub org.python.Platform 2>/dev/null || true
    fi

    # Try common package managers
    if has apt-get; then
        apt-get update -y -qq && apt-get install -y -qq git python3 python3-pip mkvtoolnix ffmpeg
    elif has dnf; then
        dnf install -y python3 python3-pip git mkvtoolnix ffmpeg
    elif has yum; then
        yum install -y python3 python3-pip git mkvtoolnix ffmpeg
    elif has pacman; then
        pacman -Sy --noconfirm --quiet git python python-pip mkvtoolnix ffmpeg
    elif has zypper; then
        zypper install -y python3 python3-pip git mkvtoolnix ffmpeg
    elif has apk; then
        apk add python3 py3-pip git mkvtoolnix ffmpeg
    elif has xbps-install; then
        xbps-install -Sy git python3 python3-pip mkvtoolnix ffmpeg
    elif has nix-env; then
        nix-env -i git python3 mkvtoolnix ffmpeg
    else
        echo_fail "No supported package manager found."
        echo -e "       ${YELLOW}Please install manually: git python3 pip mkvtoolnix ffmpeg${NC}"
        exit 1
    fi

    echo_ok "System dependencies installed."
}

install_deps_macos() {
    echo_info "Installing dependencies (brew)..."
    if ! has brew; then
        echo_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    brew install git python mkvtoolnix ffmpeg -q
    echo_ok "System dependencies installed."
}

# --- Repository management -----------------------------------------------------

manage_repo() {
    local target_dir
    target_dir="$(pwd)/${REPO_NAME}"

    if [ -d "$target_dir/.git" ]; then
        local remote
        remote="$(git -C "$target_dir" remote get-url origin 2>/dev/null || echo "")"
        if [ "$remote" = "$REPO_URL" ] || [ "$remote" = "${REPO_URL%.git}.git" ]; then
            update_repo "$target_dir"
        else
            echo_warn "Directory exists but is not the correct repository."
            echo_info "Cloning fresh..."
            rm -rf "$target_dir"
            clone_repo "$target_dir"
        fi
    else
        clone_repo "$target_dir"
    fi

    cd "$target_dir"
}

clone_repo() {
    local target_dir="$1"
    echo_info "Cloning repository..."
    git clone "$REPO_URL" 2>/dev/null
    echo_ok "Repository cloned."
}

update_repo() {
    local target_dir="$1"
    echo_info "Checking for updates..."

    git -C "$target_dir" fetch origin --quiet 2>/dev/null

    local local_hash remote_hash
    local_hash="$(git -C "$target_dir" rev-parse HEAD)"
    remote_hash="$(git -C "$target_dir" rev-parse origin/main 2>/dev/null || \
                   git -C "$target_dir" rev-parse origin/master 2>/dev/null || \
                   echo "$local_hash")"

    if [ "$local_hash" = "$remote_hash" ]; then
        echo_ok "Already up to date."
    else
        echo_info "Updates available. Pulling..."
        git -C "$target_dir" pull --quiet 2>/dev/null
        echo_ok "Updated to latest version."
    fi
}

# --- Python dependencies -------------------------------------------------------

install_python_deps() {
    echo_info "Installing Python dependencies..."
    if has pip3; then
        pip3 install --user -r requirements.txt -q 2>/dev/null || \
        pip3 install --user -r requirements.txt -q
    elif has pip; then
        pip install --user -r requirements.txt -q 2>/dev/null || \
        pip install --user -r requirements.txt -q
    fi
    echo_ok "Dependencies installed."
}

install_package() {
    echo_info "Registering kaelix command..."
    if has pip3; then
        pip3 install --user -e . -q 2>/dev/null || \
        pip3 install --user -e . -q
    elif has pip; then
        pip install --user -e . -q 2>/dev/null || \
        pip install --user -e . -q
    fi
    echo_ok "Kaelix installed."
}

# --- Uninstall ----------------------------------------------------------------

uninstall() {
    echo_info "Uninstalling Kaelix..."

    # Remove Python package
    if has pip3; then
        pip3 uninstall kaelix -y 2>/dev/null || true
    elif has pip; then
        pip uninstall kaelix -y 2>/dev/null || true
    fi

    # Remove repository
    local target_dir
    target_dir="$(pwd)/${REPO_NAME}"
    if [ -d "$target_dir" ]; then
        echo_info "Removing repository directory..."
        rm -rf "$target_dir"
    fi

    # Remove log directory
    if [ -d "$HOME/.kaelix" ]; then
        echo_info "Removing log directory..."
        rm -rf "$HOME/.kaelix"
    fi

    echo_ok "Kaelix uninstalled."
}

# --- Non-interactive helpers ---------------------------------------------------

NONINTERACTIVE="${KAElix_NONINTERACTIVE:-0}"

prompt_or_default() {
    local varname="$1"
    local prompt="$2"
    local default="$3"

    if [ "$NONINTERACTIVE" = "1" ]; then
        eval "$varname='$default'"
    else
        read -rp "$prompt" "$varname"
        eval "$varname=\"\${$varname:-$default}\""
    fi
}

# --- Entry point ---------------------------------------------------------------

main() {
    # Parse arguments
    case "${1:-}" in
        -u|--uninstall)
            banner
            check_root
            uninstall
            exit 0
            ;;
        -h|--help)
            echo "Usage: install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -u, --uninstall    Uninstall Kaelix"
            echo "  -h, --help         Show this help"
            echo ""
            echo "Environment variables:"
            echo "  KAElix_NONINTERACTIVE=1  Non-interactive mode"
            exit 0
            ;;
    esac

    banner
    check_root
    detect_os
    install_deps
    manage_repo
    install_python_deps
    install_package
    echo ""
    echo_ok "Installation complete."
    echo -e "  ${GREEN}Type \"kaelix\" to start.${NC}"
    echo ""
}

main "$@"
