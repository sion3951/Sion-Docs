#!/bin/bash
#===============================================================================
# Proxmox NVIDIA Container Script
# Follows host NVIDIA version exactly for userspace runtime packages
#===============================================================================

set -euo pipefail

CUDA_MAJOR="13"
CUDA_MINOR="2"
CUDA_SERIES="${CUDA_MAJOR}.${CUDA_MINOR}"
ARCH="x86_64"
HOST_VERSION_FILE="/etc/nvidia-host-version"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_root() {
    [[ $EUID -eq 0 ]] || { log_error "Run as root."; exit 1; }
}

detect_debian_profile() {
    local version_id codename
    version_id="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"

    case "${version_id}:${codename}" in
        11:*|*:bullseye) echo "debian11" ;;
        12:*|*:bookworm) echo "debian12" ;;
        13:*|*:trixie)   echo "debian13" ;;
        *) return 1 ;;
    esac
}

read_host_version() {
    [[ -f "$HOST_VERSION_FILE" ]] || return 1
    tr -d '[:space:]' < "$HOST_VERSION_FILE"
}

backup_file_if_exists() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    cp "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
}

debug_nvidia_sources() {
    local label="${1:-current}"
    log_info "APT NVIDIA-related sources (${label}):"
    grep -RHiE 'developer\.download\.nvidia\.com|/compute/cuda/repos/' \
        /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
}

clean_cuda_repo_config() {
    local backup_dir="/root/nvidia-repo-backups"
    mkdir -p "$backup_dir"

    if [[ -d /etc/apt/sources.list.d ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            if grep -qiE 'developer\.download\.nvidia\.com|/compute/cuda/repos/' "$f"; then
                mv "$f" "${backup_dir}/$(basename "$f").$(date +%Y%m%d%H%M%S).bak"
            fi
        done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null)
    fi

    if [[ -f /etc/apt/sources.list ]] && grep -qiE 'developer\.download\.nvidia\.com|/compute/cuda/repos/' /etc/apt/sources.list; then
        backup_file_if_exists /etc/apt/sources.list
        grep -viE 'developer\.download\.nvidia\.com|/compute/cuda/repos/' /etc/apt/sources.list > /tmp/sources.list.cleaned || true
        cat /tmp/sources.list.cleaned > /etc/apt/sources.list
        rm -f /tmp/sources.list.cleaned
    fi

    rm -f /etc/apt/sources.list.d/cuda*
    rm -f /etc/apt/sources.list.d/nvidia*
    rm -f /etc/apt/sources.list.d/*cuda*.list
    rm -f /etc/apt/sources.list.d/*cuda*.sources
    rm -f /etc/apt/sources.list.d/*nvidia*.list
    rm -f /etc/apt/sources.list.d/*nvidia*.sources

    rm -f /usr/share/keyrings/cuda*
    rm -f /etc/apt/keyrings/cuda*
    rm -f /etc/apt/keyrings/nvidia*
    rm -f /etc/apt/trusted.gpg.d/cuda*
    rm -f /etc/apt/trusted.gpg.d/nvidia*

    rm -rf /var/cuda-repo-*
    rm -f /var/lib/apt/lists/*developer.download.nvidia.com* 2>/dev/null || true
}

cleanup() {
    apt purge -y "nvidia-*" "libnvidia-*" "cuda-*" || true
    apt autoremove --purge -y || true
    rm -rf /usr/local/cuda*
    clean_cuda_repo_config
}

add_cuda_repo() {
    local profile="$1"
    local keydeb="/tmp/cuda-keyring_1.1-1_all.deb"
    local repo_url="https://developer.download.nvidia.com/compute/cuda/repos/${profile}/${ARCH}"

    clean_cuda_repo_config
    wget -q "${repo_url}/cuda-keyring_1.1-1_all.deb" -O "$keydeb" || return 1
    dpkg -i "$keydeb" >/dev/null 2>&1 || true

    if ! apt update 2>&1 | tee /tmp/apt-nvidia-update.log; then
        return 1
    fi

    if grep -qiE 'SHA1|Signing key .* not bound' /tmp/apt-nvidia-update.log; then
        log_error "APT rejected the NVIDIA repo for ${profile} due to signature policy."
        return 1
    fi
}

install_base_packages() {
    apt update
    apt install -y \
      build-essential make gcc g++ cmake git \
      pkg-config curl wget unzip sudo \
      ffmpeg nvtop htop libglvnd-dev
}

find_matching_pkgver() {
    local pkg="$1" hostver="$2"
    apt-cache madison "$pkg" | awk -v v="$hostver" '$3 ~ "^"v"-" {print $3; exit}'
}

write_cuda_env() {
    cat > /etc/profile.d/cuda.sh <<'EOF'
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
EOF
    chmod 644 /etc/profile.d/cuda.sh
}

ensure_cuda_symlink() {
    local target="/usr/local/cuda-${CUDA_SERIES}"
    if [[ -d "$target" ]]; then
        ln -sfn "$target" /usr/local/cuda
    elif [[ -d "/usr/local/cuda-${CUDA_MAJOR}" ]]; then
        ln -sfn "/usr/local/cuda-${CUDA_MAJOR}" /usr/local/cuda
    fi
}

install_ct() {
    local debrepo hostver pkgver_ml pkgver_cuda pkgver_drv toolkit_candidate

    debrepo="$(detect_debian_profile)" || {
        log_error "Unsupported Debian release inside container."
        exit 1
    }

    hostver="$(read_host_version)" || {
        log_error "Missing ${HOST_VERSION_FILE} inside container."
        exit 1
    }

    log_info "Detected CT repo profile: ${debrepo}"
    log_info "Following host NVIDIA version: ${hostver}"

    debug_nvidia_sources "before cleanup"
    cleanup
    debug_nvidia_sources "after cleanup"

    install_base_packages
    add_cuda_repo "$debrepo" || {
        log_error "Failed to configure NVIDIA repo for ${debrepo}."
        exit 1
    }

    pkgver_ml="$(find_matching_pkgver libnvidia-ml1 "$hostver")"
    pkgver_cuda="$(find_matching_pkgver libcuda1 "$hostver")"
    pkgver_drv="$(find_matching_pkgver nvidia-driver-cuda "$hostver")"

    [[ -n "$pkgver_ml" ]]   || { log_error "No libnvidia-ml1 matching host version $hostver"; exit 1; }
    [[ -n "$pkgver_cuda" ]] || { log_error "No libcuda1 matching host version $hostver"; exit 1; }
    [[ -n "$pkgver_drv" ]]  || { log_error "No nvidia-driver-cuda matching host version $hostver"; exit 1; }

    apt install -y \
      "libnvidia-ml1=${pkgver_ml}" \
      "libcuda1=${pkgver_cuda}" \
      "nvidia-driver-cuda=${pkgver_drv}"

    toolkit_candidate="$(apt-cache policy cuda-toolkit-${CUDA_MAJOR}-${CUDA_MINOR} | awk '/Candidate:/ {print $2}')"
    if [[ -n "$toolkit_candidate" && "$toolkit_candidate" != "(none)" ]]; then
        apt install -y "cuda-toolkit-${CUDA_MAJOR}-${CUDA_MINOR}"
    else
        log_warn "cuda-toolkit-${CUDA_MAJOR}-${CUDA_MINOR} not available; skipping toolkit."
    fi

    write_cuda_env
    ensure_cuda_symlink

    log_ok "Installed CT NVIDIA userspace matching host version ${hostver}"
}

verify() {
    nvidia-smi
    bash -lc 'source /etc/profile.d/cuda.sh && nvcc --version'
}

main() {
    check_root
    case "${1:-help}" in
        install) shift; install_ct ;;
        cleanup) shift; cleanup ;;
        verify) shift; verify ;;
        *)
            cat <<'EOF'
Usage:
  nvidia-proxmox-ct.sh install
  nvidia-proxmox-ct.sh cleanup
  nvidia-proxmox-ct.sh verify
EOF
            ;;
    esac
}

main "$@"
