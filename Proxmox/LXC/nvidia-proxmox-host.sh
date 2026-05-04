#!/bin/bash
#===============================================================================
# Proxmox NVIDIA Host Script
#===============================================================================

set -euo pipefail

CUDA_MAJOR="13"
CUDA_MINOR="2"
CUDA_SERIES="${CUDA_MAJOR}.${CUDA_MINOR}"
ARCH="x86_64"
PROXMOX_CONF_DIR="/etc/pve/lxc"
HOST_VERSION_FILE="/etc/nvidia-host-version"
CT_SCRIPT_LOCAL="/root/nvidia-proxmox-ct.sh"

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

detect_host_nvidia_version() {
    local v=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        v="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d ' ')"
    fi
    if [[ -z "$v" ]]; then
        v="$(dpkg-query -W -f='${Version}\n' nvidia-driver 2>/dev/null | head -n1 | sed 's/-.*//')"
    fi
    [[ -n "$v" ]] || return 1
    echo "$v"
}

save_host_version() {
    local v="$1"
    echo "$v" > "$HOST_VERSION_FILE"
    chmod 644 "$HOST_VERSION_FILE"
    log_ok "Saved host NVIDIA version to $HOST_VERSION_FILE: $v"
}

clean_cuda_repo_config() {
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
}

add_cuda_repo_network() {
    local profile="$1"
    local keydeb="/tmp/cuda-keyring_1.1-1_all.deb"
    local repo_url="https://developer.download.nvidia.com/compute/cuda/repos/${profile}/${ARCH}"

    clean_cuda_repo_config
    wget -q "${repo_url}/cuda-keyring_1.1-1_all.deb" -O "$keydeb" || return 1
    dpkg -i "$keydeb" >/dev/null 2>&1 || true
    apt update
}

install_kernel_headers() {
    if uname -r | grep -q -- '-pve'; then
        apt install -y "proxmox-headers-$(uname -r)" build-essential dkms curl wget
    else
        apt install -y "linux-headers-$(uname -r)" build-essential dkms curl wget
    fi
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

host_core_packages() {
    cat <<'EOF'
firmware-nvidia-gsp
nvidia-driver
nvidia-driver-cuda
nvidia-driver-libs
nvidia-kernel-dkms
nvidia-kernel-support
nvidia-modprobe
nvidia-persistenced
EOF
}

host_optional_packages() {
    cat <<EOF
cuda-toolkit-${CUDA_MAJOR}-${CUDA_MINOR}
EOF
}

installed_nvidia_host_packages() {
    dpkg-query -W -f='${Package}\n' 2>/dev/null \
      | grep -E '^(nvidia-|libnvidia-|cuda-|firmware-nvidia-gsp$)' \
      | sort -u || true
}

install_host() {
    local debrepo hostver
    local pkgs=()

    debrepo="$(detect_debian_profile)" || {
        log_error "Unsupported Debian release on host."
        exit 1
    }

    log_info "Host repo target: $debrepo"
    add_cuda_repo_network "$debrepo"
    install_kernel_headers

    while IFS= read -r p; do [[ -n "$p" ]] && pkgs+=("$p"); done < <(host_core_packages)
    while IFS= read -r p; do [[ -n "$p" ]] && pkgs+=("$p"); done < <(installed_nvidia_host_packages)

    if apt-cache policy nvidia-open | grep -q 'Candidate:'; then
        pkgs+=("nvidia-open")
    fi

    if ! printf '%s\n' "${pkgs[@]}" | grep -qx "cuda-toolkit-${CUDA_MAJOR}-${CUDA_MINOR}"; then
        while IFS= read -r p; do [[ -n "$p" ]] && pkgs+=("$p"); done < <(host_optional_packages)
    fi

    mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | awk 'NF' | sort -u)

    log_info "Installing/upgrading host NVIDIA packages:"
    printf '  %s\n' "${pkgs[@]}"
    apt install -y "${pkgs[@]}"

    write_cuda_env
    ensure_cuda_symlink

    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        hostver="$(detect_host_nvidia_version)" || {
            log_error "Host driver works, but version detection failed."
            exit 1
        }
        save_host_version "$hostver"
        log_ok "Host NVIDIA install complete."
    else
        log_warn "Host packages installed, but nvidia-smi is not healthy yet."
        log_warn "A reboot may be required."
    fi
}

detect_nvidia_devices() {
    local devices=()
    for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
        [[ -c "$dev" ]] && devices+=("$dev")
    done
    if [[ -d /dev/nvidia-caps ]]; then
        for dev in /dev/nvidia-caps/*; do
            [[ -c "$dev" ]] && devices+=("$dev")
        done
    fi
    printf '%s\n' "${devices[@]}" | sort -u
}

get_major_number() {
    local dev="$1" hex_major
    hex_major=$(stat -c '%t' "$dev" 2>/dev/null || true)
    [[ -n "$hex_major" ]] && printf "%d" "0x${hex_major}" 2>/dev/null || true
}

generate_lxc_gpu_config() {
    local devices majors=() mounts=() has_caps=0
    devices="$(detect_nvidia_devices)"
    [[ -n "$devices" ]] || { log_error "No NVIDIA devices detected."; return 1; }

    while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue
        local major
        major="$(get_major_number "$dev")"
        [[ -n "$major" ]] || continue
        [[ " ${majors[*]} " =~ " ${major} " ]] || majors+=("$major")

        if [[ "$dev" == /dev/nvidia-caps/* ]]; then
            has_caps=1
            continue
        fi
        mounts+=("lxc.mount.entry: ${dev} dev/${dev#/dev/} none bind,optional,create=file")
    done <<< "$devices"

    echo "# --- NVIDIA GPU Passthrough ---"
    for major in "${majors[@]}"; do
        echo "lxc.cgroup2.devices.allow: c ${major}:* rwm"
    done
    for m in "${mounts[@]}"; do
        echo "$m"
    done
    [[ "$has_caps" -eq 1 ]] && echo "lxc.mount.entry: /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir"
    echo "# --- End NVIDIA GPU Passthrough ---"
}

backup_conf() {
    local ctid="$1" conf="${PROXMOX_CONF_DIR}/${ctid}.conf"
    [[ -f "$conf" ]] && cp "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
}

clean_ct_gpu_config() {
    local ctid="$1" conf="${PROXMOX_CONF_DIR}/${ctid}.conf"
    [[ -f "$conf" ]] || { log_error "Missing CT config: $conf"; return 1; }

    awk '
        BEGIN {skip=0}
        /^# --- NVIDIA GPU Passthrough ---$/ {skip=1; next}
        /^# --- End NVIDIA GPU Passthrough ---$/ {skip=0; next}
        skip==0 {print}
    ' "$conf" > "${conf}.tmp"

    mv "${conf}.tmp" "$conf"
}

apply_ct_gpu_config() {
    local ctid="$1" conf="${PROXMOX_CONF_DIR}/${ctid}.conf"
    [[ -f "$conf" ]] || { log_error "Missing CT config: $conf"; return 1; }

    backup_conf "$ctid"
    clean_ct_gpu_config "$ctid"
    printf '\n' >> "$conf"
    generate_lxc_gpu_config >> "$conf"
    log_ok "Applied NVIDIA GPU passthrough block to CT $ctid"
}

push_host_version() {
    [[ $# -gt 0 ]] || { log_error "Usage: $0 push-version <ctid> [ctid2] ..."; exit 1; }
    [[ -f "$HOST_VERSION_FILE" ]] || { log_error "Missing $HOST_VERSION_FILE on host."; exit 1; }

    for ctid in "$@"; do
        pct push "$ctid" "$HOST_VERSION_FILE" "$HOST_VERSION_FILE"
        log_ok "Pushed host version file to CT $ctid"
    done
}

push_ct_script() {
    [[ $# -gt 0 ]] || { log_error "Usage: $0 push-ct-script <ctid> [ctid2] ..."; exit 1; }
    [[ -f "$CT_SCRIPT_LOCAL" ]] || { log_error "Missing CT script at $CT_SCRIPT_LOCAL"; exit 1; }

    for ctid in "$@"; do
        pct push "$ctid" "$CT_SCRIPT_LOCAL" /root/nvidia-proxmox-ct.sh
        pct exec "$ctid" -- chmod +x /root/nvidia-proxmox-ct.sh
        log_ok "Pushed CT script to CT $ctid"
    done
}

run_detect() {
    log_info "=== Detecting NVIDIA devices on host ==="
    while IFS= read -r dev; do
        [[ -n "$dev" ]] && echo "$dev (major $(get_major_number "$dev"))"
    done < <(detect_nvidia_devices)
    echo
    generate_lxc_gpu_config
    echo
    if detect_host_nvidia_version >/dev/null 2>&1; then
        log_info "Detected host NVIDIA version: $(detect_host_nvidia_version)"
    else
        log_warn "Could not detect host NVIDIA version yet."
    fi
}

main() {
    check_root
    case "${1:-help}" in
        host-install) shift; install_host ;;
        ct-apply) shift; for ctid in "$@"; do apply_ct_gpu_config "$ctid"; done ;;
        push-version) shift; push_host_version "$@" ;;
        push-ct-script) shift; push_ct_script "$@" ;;
        detect) shift; run_detect ;;
        *)
            cat <<'EOF'
Usage:
  nvidia-proxmox-host.sh host-install
  nvidia-proxmox-host.sh ct-apply <id> [id2] ...
  nvidia-proxmox-host.sh push-version <id> [id2] ...
  nvidia-proxmox-host.sh push-ct-script <id> [id2] ...
  nvidia-proxmox-host.sh detect
EOF
            ;;
    esac
}

main "$@"
