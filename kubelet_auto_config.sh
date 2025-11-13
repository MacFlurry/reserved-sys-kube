#!/bin/bash
################################################################################
# Automatic kubelet reservation configuration script
# Version: 3.0.1
# Tested on Kubernetes v1.32+, cgroups v1/v2, systemd, Ubuntu
#
# See CHANGELOG_v3.0.0.md for the full list of changes.
#
# Usage:
#   ./kubelet_auto_config.sh [OPTIONS]
#
# Options:
#   --profile <gke|eks|conservative|minimal>  Reservation profile (default: gke)
#   --density-factor <float>                  Multiplier between 0.1 and 5.0 (default: 1.0, recommended: 0.5-3.0)
#   --target-pods <int>                       Desired pod count (density factor computed automatically)
#   --node-type <control-plane|worker|auto>   Force the node type (default: auto detection)
#   --wait-timeout <seconds>                  Kubelet wait timeout in seconds (default: 60)
#   --dry-run                                 Show the configuration without applying it
#   --backup                                  Keep the timestamped backup (instead of only rotating)
#   --no-require-deps                         Disable strict dependency mode (lab only)
#   --help                                    Display this help message
#
# Examples:
#   ./kubelet_auto_config.sh
#   ./kubelet_auto_config.sh --profile conservative --density-factor 1.5
#   ./kubelet_auto_config.sh --target-pods 110 --profile conservative
#   ./kubelet_auto_config.sh --node-type control-plane  # Force control-plane mode
#   ./kubelet_auto_config.sh --dry-run
#
# Dependencies: bc, jq, systemctl, yq
################################################################################

set -euo pipefail

# Version
VERSION="3.0.1"

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
PROFILE="gke"
DENSITY_FACTOR=1.0
TARGET_PODS=""
NODE_TYPE="auto"
NODE_TYPE_DETECTED=""
DRY_RUN=false
BACKUP=false
REQUIRE_DEPENDENCIES=true  # Production mode: block when dependencies are missing
KUBELET_WAIT_TIMEOUT=60    # Kubelet wait timeout (seconds)
KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
LOCK_FILE="/var/lock/kubelet-auto-config.lock"
LOCK_FD=200  # File descriptor pour flock

# Seuils et garde-fous
MIN_ALLOC_CPU_PERCENT=25         # Minimum allowed allocatable CPU percentage
MIN_ALLOC_MEM_PERCENT=20         # Minimum allowed allocatable memory percentage
CONTROL_PLANE_MAX_DENSITY=1.0    # Maximum density factor allowed on a control-plane

# Cleanup helper for the trap
cleanup() {
    # Release the flock lock (automatically happens when the FD closes)
    if [[ -n "${LOCK_FD:-}" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
    fi
}

# Register the trap immediately
trap cleanup EXIT

################################################################################
# Utility functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

format_diff() {
    local value=$1
    if (( value > 0 )); then
        echo "+${value}"
    else
        echo "${value}"
    fi
}

normalize_cpu_to_milli() {
    local value=$1

    if [[ -z "$value" ]]; then
        log_error "normalize_cpu_to_milli: empty value received"
        return 1
    fi

    if [[ "$value" =~ m$ ]]; then
        local milli="${value%m}"
        if [[ "$milli" =~ ^[0-9]+$ ]]; then
            echo "$milli"
            return 0
        else
            log_error "normalize_cpu_to_milli: invalid format '$value' (non-numeric millicores)"
            return 1
        fi
    fi

    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        # Convert cores to milli-cores (rounded to the nearest integer)
        printf "%.0f" "$(echo "$value * 1000" | bc -l)"
        return 0
    fi

    log_error "normalize_cpu_to_milli: invalid format '$value' (expected '100m' or '1.5')"
    return 1
}

normalize_memory_to_mib() {
    local value=$1

    if [[ -z "$value" ]]; then
        log_error "normalize_memory_to_mib: empty value received"
        return 1
    fi

    if [[ "$value" =~ Ki$ ]]; then
        local ki=${value%Ki}
        if [[ "$ki" =~ ^[0-9]+$ ]]; then
            echo $(( (ki + 512) / 1024 ))
            return 0
        else
            log_error "normalize_memory_to_mib: invalid format '$value' (non-numeric Ki)"
            return 1
        fi
    elif [[ "$value" =~ Mi$ ]]; then
        local mi=${value%Mi}
        if [[ "$mi" =~ ^[0-9]+$ ]]; then
            echo "$mi"
            return 0
        else
            log_error "normalize_memory_to_mib: invalid format '$value' (non-numeric Mi)"
            return 1
        fi
    elif [[ "$value" =~ Gi$ ]]; then
        local gi=${value%Gi}
        if [[ "$gi" =~ ^[0-9]+$ ]]; then
            echo $(( gi * 1024 ))
            return 0
        else
            log_error "normalize_memory_to_mib: invalid format '$value' (non-numeric Gi)"
            return 1
        fi
    fi

    log_error "normalize_memory_to_mib: invalid format '$value' (expected '100Mi', '2Gi', '1024Ki')"
    return 1
}

get_current_allocatable_snapshot() {
    if ! command -v kubectl >/dev/null 2>&1; then
        echo ""
        return 0
    fi

    # Fallback kubeconfig with priorities
    local kubeconfig=""
    for conf in /etc/kubernetes/kubelet.conf "${KUBECONFIG:-}" ~/.kube/config; do
        if [[ -n "$conf" ]] && [[ -f "$conf" ]]; then
            kubeconfig="--kubeconfig=$conf"
            break
        fi
    done

    local node_name
    node_name=$(hostname)

    local raw
    if ! raw=$(kubectl $kubeconfig get node "$node_name" -o jsonpath='{.status.allocatable.cpu},{.status.allocatable.memory}' 2>/dev/null); then
        echo ""
        return 0
    fi

    local cpu_value=${raw%%,*}
    local mem_value=${raw##*,}

    # Best-effort normalization (non-blocking for snapshot)
    local cpu_milli
    local mem_mib
    if cpu_milli=$(normalize_cpu_to_milli "$cpu_value" 2>/dev/null) && \
       mem_mib=$(normalize_memory_to_mib "$mem_value" 2>/dev/null); then
        echo "${cpu_milli}:${mem_mib}"
    else
        echo ""
    fi

    return 0
}

usage() {
    # Print only the Usage section through Dependencies
    sed -n '/^# Usage:/,/^# Dependencies:/p' "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
    fi
}

check_os() {
    if [[ -r /etc/os-release ]]; then
        # Anti-injection validation: detect backticks or unquoted command substitution
        # Note: grep returns 1 when there is no match, so invert the logic
        if grep -qE '^[^#]*`[^"]*$|^\$\([^)]' /etc/os-release; then
            log_error "Fichier /etc/os-release contient des patterns d'injection dangereux"
        fi

        # shellcheck disable=SC1091
        source /etc/os-release

        if [[ "${ID}" != "ubuntu" ]]; then
            log_error "Unsupported system detected (${PRETTY_NAME:-$ID}). This script only supports Ubuntu."
        fi
    else
        log_error "Unable to detect distribution (/etc/os-release missing). This script only supports Ubuntu."
    fi
}

acquire_lock() {
    local timeout=30

    # Create the lock file if it does not exist
    touch "$LOCK_FILE" 2>/dev/null || log_error "Unable to create lock file: $LOCK_FILE"

    # Open the FD and try to acquire the lock with a timeout
    eval "exec $LOCK_FD>$LOCK_FILE"

    if ! flock -w "$timeout" "$LOCK_FD"; then
        log_error "Another process is already running this script (timeout after ${timeout}s)"
    fi

    # Write the PID to the lock file for traceability
    echo $$ >&"$LOCK_FD"

    log_info "Lock acquis (PID $$)"
}

install_dependencies() {
    local missing_apt=()
    local need_yq=false

    # Check bc and jq
    for cmd in bc jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_apt+=("$cmd")
        fi
    done

    # Check yq (and its version)
    if ! command -v yq &> /dev/null; then
        need_yq=true
    else
        # Ensure we are using the mikefarah v4+ binary (not Python v3)
        if ! yq --version 2>&1 | grep -q "mikefarah"; then
            log_warning "yq is installed but the version is incorrect (Python v3 detected)"
            log_info "Remplacement par yq v4 (mikefarah)..."
            need_yq=true
        fi
    fi

    # Nothing to do if everything is already compliant
    if [[ ${#missing_apt[@]} -eq 0 ]] && [[ "$need_yq" == "false" ]]; then
        return 0
    fi

    # Automatic installation
    log_info "Automatically installing missing dependencies..."

    # Install bc and jq via apt
    if [[ ${#missing_apt[@]} -gt 0 ]]; then
        log_info "Installation de ${missing_apt[*]} via apt..."

        # Production mode: abort if the installation fails
        if [[ "$REQUIRE_DEPENDENCIES" == true ]]; then
            log_warning "Production mode: automatically installing dependencies"
        fi

        # apt with a 30-second timeout
        if ! apt-get -o Acquire::http::Timeout=30 -o Acquire::ftp::Timeout=30 update -qq >/dev/null 2>&1; then
            if [[ "$REQUIRE_DEPENDENCIES" == true ]]; then
                log_error "apt update failed (timeout or network unreachable)"
            else
                log_warning "apt update failed, continuing..."
            fi
        fi

        if ! apt-get install -y -qq "${missing_apt[@]}" >/dev/null 2>&1; then
            if [[ "$REQUIRE_DEPENDENCIES" == true ]]; then
                log_error "Installation of ${missing_apt[*]} failed"
            else
                log_warning "Installation of ${missing_apt[*]} failed, continuant..."
            fi
        fi

        log_success "${missing_apt[*]} installed"
    fi

    # Install yq v4
    if [[ "$need_yq" == "true" ]]; then
        log_info "Installation de yq v4 depuis GitHub..."

        # Detect the architecture
        local arch
        arch=$(uname -m)
        local yq_binary
        local yq_sha256

        case "$arch" in
            x86_64|amd64)
                yq_binary="yq_linux_amd64"
                yq_sha256="f0cecf04c0eb85e6d8b8370a9e2629c88c7c15c1f94a828f9c3838515d779b5f"
                ;;
            arm64|aarch64)
                yq_binary="yq_linux_arm64"
                yq_sha256="4d10a57ff315ba5f7475bb43345f782c38a6cb5253b2b5c45e7de2fb9b7c87f8"
                ;;
            *)
                log_error "Unsupported architecture for yq: $arch"
                ;;
        esac

        # Download yq v4 with timeout and retries
        local yq_version="v4.44.3"
        local yq_url="https://github.com/mikefarah/yq/releases/download/${yq_version}/${yq_binary}"

        if ! wget --timeout=30 --tries=3 -qO /tmp/yq "$yq_url" 2>/dev/null; then
            if [[ "$REQUIRE_DEPENDENCIES" == true ]]; then
                log_error "Failed to download yq from $yq_url (timeout or unreachable network)"
            else
                log_warning "Failed to download yq, continuing..."
                return 0
            fi
        fi

        # Verify the SHA256 checksum (supply chain protection)
        log_info "Verifying yq integrity (SHA256)..."
        if ! echo "${yq_sha256}  /tmp/yq" | sha256sum -c - >/dev/null 2>&1; then
            rm -f /tmp/yq
            if [[ "$REQUIRE_DEPENDENCIES" == true ]]; then
                log_error "Invalid SHA256 checksum for yq! Possible supply chain attack. Download rejected."
            else
                log_warning "Invalid SHA256 checksum for yq! Continuing without yq (test mode)..."
                return 0
            fi
        fi

        chmod +x /tmp/yq
        mv /tmp/yq /usr/local/bin/yq || log_error "yq installation failed (unable to move binary to /usr/local/bin)"

        log_success "yq $yq_version installed (SHA256 verified)"
    fi
}

check_dependencies() {
    # Automatically install missing dependencies
    install_dependencies

    # Ensure everything was installed correctly
    local missing=()
    for cmd in bc jq systemctl yq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies after installation: ${missing[*]}"
    fi
}

validate_positive_integer() {
    local value=$1
    local name=$2

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error "$name must be a positive integer (received: $value)"
    fi

    if (( value <= 0 )); then
        log_error "$name must be greater than 0 (received: $value)"
    fi
}

validate_density_factor() {
    local factor=$1

    if ! [[ "$factor" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        log_error "Density-factor must be a valid number (received: $factor)"
    fi

    if (( $(echo "$factor < 0.1" | bc -l) )); then
        log_error "Density-factor must be >= 0.1 (received: $factor)"
    fi

    if (( $(echo "$factor > 5.0" | bc -l) )); then
        log_error "Density-factor must be <= 5.0 (received: $factor)"
    fi

    if (( $(echo "$factor < 0.5 || $factor > 3.0" | bc -l) )); then
        log_warning "Density-factor $factor is outside the recommended 0.5-3.0 range"
    fi
}

validate_calculated_value() {
    local value=$1
    local name=$2
    local min=${3:-0}

    # Ensure the value is not empty
    if [[ -z "$value" ]]; then
        log_error "Invalid calculation for $name: empty value"
    fi

    # Ensure it is a valid integer
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error "Invalid calculation for $name: '$value' is not a valid integer"
    fi

    # Enforce the minimum value
    if (( value < min )); then
        log_error "Invalid calculation for $name: $value < $min (minimum required)"
    fi
}

validate_profile() {
    local profile=$1
    case $profile in
        gke|eks|conservative|minimal)
            return 0
            ;;
        *)
            log_error "Invalid profile: $profile. Accepted values: gke, eks, conservative, minimal"
            ;;
    esac
}

validate_node_type() {
    local node_type=$1
    case $node_type in
        control-plane|worker|auto)
            return 0
            ;;
        *)
            log_error "Invalid node type: $node_type. Accepted values: control-plane, worker, auto"
            ;;
    esac
}

################################################################################
# Node type detection (control-plane vs worker)
################################################################################

detect_node_type() {
    log_info "Detecting node type..."

    # Look for control-plane static pods under /etc/kubernetes/manifests
    local manifests_dir="/etc/kubernetes/manifests"
    local is_control_plane=false

    if [[ -d "$manifests_dir" ]]; then
        # Check for control-plane component manifests
        if [[ -f "$manifests_dir/kube-apiserver.yaml" ]] || \
           [[ -f "$manifests_dir/kube-controller-manager.yaml" ]] || \
           [[ -f "$manifests_dir/kube-scheduler.yaml" ]] || \
           [[ -f "$manifests_dir/etcd.yaml" ]]; then
            is_control_plane=true
        fi
    fi

    if [[ "$is_control_plane" == true ]]; then
        NODE_TYPE_DETECTED="control-plane"
        log_success "Node detected: CONTROL-PLANE (static pods found in $manifests_dir)"
        log_warning "Control-plane mode: kube-reserved will NOT be enforced (critical static pods preserved)"
    else
        NODE_TYPE_DETECTED="worker"
        log_success "Node detected: WORKER (no control-plane static pods found)"
        log_info "Worker mode: kube-reserved will be enforced normally"
    fi

    echo "$NODE_TYPE_DETECTED"
}

################################################################################
# System resource detection
################################################################################

detect_vcpu() {
    local vcpu
    vcpu=$(nproc)

    if (( vcpu <= 0 )); then
        log_error "Unable to detect vCPU count"
    fi

    echo "$vcpu"
}

detect_ram_gib() {
    # Return total RAM in GiB (computed from MiB for accuracy)
    local ram_mib
    ram_mib=$(detect_ram_mib)
    echo "scale=2; $ram_mib / 1024" | bc
}

detect_ram_mib() {
    # Return total RAM in MiB (exact)
    local ram_mib
    ram_mib=$(free -m | awk '/^Mem:/ {print $2}')

    if (( ram_mib <= 0 )); then
        log_error "Unable to detect system memory"
    fi

    echo "$ram_mib"
}

detect_ephemeral_capacity_mib() {
    local path="/var/lib/kubelet"

    if [[ ! -d "$path" ]]; then
        path="/"
    fi

    local df_output
    if ! df_output=$(df -BM "$path" 2>/dev/null); then
        log_warning "Unable to detect ephemeral storage capacity (df failed on $path)"
        echo "0"
        return
    fi

    local size_mb
    size_mb=$(awk 'NR==2 {print $2}' <<< "$df_output" | tr -d 'M')

    if [[ -z "$size_mb" ]]; then
        log_warning "Ephemeral storage capacity not found (df output empty on $path)"
        echo "0"
        return
    fi

    if ! [[ "$size_mb" =~ ^[0-9]+$ ]]; then
        log_warning "Invalid ephemeral capacity value: $size_mb"
        echo "0"
        return
    fi

    echo "$size_mb"
}

calculate_ephemeral_reservations() {
    local capacity_mib
    capacity_mib=$(detect_ephemeral_capacity_mib)

    local system_default_mib=10240  # 10Gi
    local kube_default_mib=5120     # 5Gi

    local system_ratio=30
    local kube_ratio=20

    local system_mib=$system_default_mib
    local kube_mib=$kube_default_mib

    if (( capacity_mib > 0 )); then
        local system_cap=$(( capacity_mib * system_ratio / 100 ))
        local kube_cap=$(( capacity_mib * kube_ratio / 100 ))

        if (( system_cap <= 0 )); then
            system_cap=capacity_mib
        fi

        if (( kube_cap <= 0 )); then
            kube_cap=capacity_mib
        fi

        if (( system_cap > system_default_mib )); then
            system_cap=$system_default_mib
        fi

        if (( kube_cap > kube_default_mib )); then
            kube_cap=$kube_default_mib
        fi

        system_mib=$system_cap
        kube_mib=$kube_cap

        if (( system_mib < 256 )); then
            system_mib=256
        fi

        if (( kube_mib < 128 )); then
            kube_mib=128
        fi

        local total_reserved=$(( system_mib + kube_mib ))
        local max_reserved=$(( capacity_mib * 80 / 100 ))

        if (( max_reserved == 0 )); then
            max_reserved=$capacity_mib
        fi

        if (( total_reserved > max_reserved )); then
            if (( total_reserved > 0 )); then
                system_mib=$(( system_mib * max_reserved / total_reserved ))
                kube_mib=$(( kube_mib * max_reserved / total_reserved ))

                if (( system_mib < 128 )); then
                    system_mib=128
                fi

                if (( kube_mib < 64 )); then
                    kube_mib=64
                fi
            fi
        fi
    else
        log_warning "Ephemeral storage capacity missing, using defaults (10Gi / 5Gi)"
    fi

    echo "$system_mib $kube_mib"
}

################################################################################
# Automatic density-factor calculation
################################################################################

calculate_density_factor() {
    local target_pods=$1
    local factor

    # Validate input
    validate_positive_integer "$target_pods" "target-pods"

    if (( target_pods > 500 )); then
        log_warning "target-pods is very high ($target_pods). Recommended maximum: 500"
    fi

    if (( target_pods <= 30 )); then
        factor="1.0"
    elif (( target_pods <= 50 )); then
        # Interpolation: 1.0 + ((pods - 30) / 200)
        factor=$(echo "scale=2; 1.0 + (($target_pods - 30) / 200.0)" | bc)
    elif (( target_pods <= 80 )); then
        # Interpolation: 1.1 + ((pods - 50) / 300)
        factor=$(echo "scale=2; 1.1 + (($target_pods - 50) / 300.0)" | bc)
    elif (( target_pods <= 110 )); then
        # Interpolation: 1.2 + ((pods - 80) / 100)
        factor=$(echo "scale=2; 1.2 + (($target_pods - 80) / 100.0)" | bc)
    else
        # Croissance logarithmique
        local excess=$(( target_pods - 110 ))
        if (( excess > 90 )); then
            excess=90  # Cap at 200 pods total
        fi
        factor=$(echo "scale=2; 1.5 + ($excess / 180.0)" | bc)
    fi

    echo "$factor"
}

################################################################################
# Reservation calculation formulas
################################################################################

# Profil GKE (Google Kubernetes Engine)
calculate_gke() {
    local vcpu=$1
    local ram_gib=$2
    local ram_mib=$3

    # Normalize ram_gib to an integer for bash arithmetic
    local ram_gib_int
    ram_gib_int=$(printf "%.0f" "$ram_gib")

    # system-reserved CPU
    local sys_cpu
    if (( vcpu <= 2 )); then
        sys_cpu=100
    elif (( vcpu <= 8 )); then
        sys_cpu=$((100 + (vcpu - 2) * 20))
    elif (( vcpu <= 32 )); then
        sys_cpu=$((220 + (vcpu - 8) * 10))
    else
        sys_cpu=$((460 + (vcpu - 32) * 5))
    fi

    # system-reserved Memory
    local sys_mem_base=100
    local sys_mem_percent
    if (( ram_gib_int < 64 )); then
        sys_mem_percent=$(echo "scale=0; $ram_mib * 0.01 / 1" | bc)
    else
        sys_mem_percent=$(echo "scale=0; $ram_mib * 0.005 / 1" | bc)
    fi
    local sys_mem_kernel=$((ram_gib_int * 11))
    local sys_mem=$((sys_mem_base + sys_mem_percent + sys_mem_kernel))

    # kube-reserved CPU
    local kube_cpu_base=60
    local kube_cpu_dynamic=$((vcpu * 10))
    if (( kube_cpu_dynamic < 40 )); then
        kube_cpu_dynamic=40
    fi
    local kube_cpu=$((kube_cpu_base + kube_cpu_dynamic))

    # kube-reserved Memory
    local kube_mem_base=255
    local kube_mem_dynamic
    if (( ram_gib_int <= 64 )); then
        kube_mem_dynamic=$((ram_gib_int * 11))
    else
        kube_mem_dynamic=$((64 * 11 + (ram_gib_int - 64) * 8))
    fi
    local kube_mem=$((kube_mem_base + kube_mem_dynamic))

    echo "$sys_cpu $sys_mem $kube_cpu $kube_mem"
}

# Profil EKS (Amazon Elastic Kubernetes Service)
calculate_eks() {
    local vcpu=$1
    local ram_gib=$2
    local ram_mib=$3

    # Normalize ram_gib to an integer for bash arithmetic
    local ram_gib_int
    ram_gib_int=$(printf "%.0f" "$ram_gib")

    # system-reserved CPU (paliers)
    local sys_cpu
    local sys_mem_percent
    if (( vcpu < 8 )); then
        sys_cpu=100
        sys_mem_percent="0.01"
    elif (( vcpu <= 32 )); then
        sys_cpu=200
        sys_mem_percent="0.015"
    else
        sys_cpu=400
        sys_mem_percent="0.02"
    fi

    # system-reserved Memory
    local sys_mem
    sys_mem=$(echo "scale=0; (100 + ($ram_mib * $sys_mem_percent)) / 1" | bc)

    # kube-reserved CPU
    local kube_cpu
    if (( vcpu < 8 )); then
        kube_cpu=$((60 + vcpu * 10))
    elif (( vcpu <= 32 )); then
        kube_cpu=$((100 + vcpu * 10))
    else
        kube_cpu=$((150 + vcpu * 15))
    fi

    # kube-reserved Memory
    local kube_mem=$((255 + ram_gib_int * 11))

    echo "$sys_cpu $sys_mem $kube_cpu $kube_mem"
}

# Profil Conservative (Red Hat OpenShift-like)
calculate_conservative() {
    local vcpu=$1
    local ram_gib=$2
    local ram_mib=$3

    # system-reserved CPU
    local sys_cpu
    sys_cpu=$(echo "scale=0; (500 + ($vcpu * 1000 * 0.01)) / 1" | bc)

    # system-reserved Memory
    local sys_mem
    sys_mem=$(echo "scale=0; (1024 + ($ram_mib * 0.02)) / 1" | bc)

    # kube-reserved CPU
    local kube_cpu
    kube_cpu=$(echo "scale=0; (500 + ($vcpu * 1000 * 0.015)) / 1" | bc)

    # kube-reserved Memory
    local kube_mem
    kube_mem=$(echo "scale=0; (1024 + ($ram_mib * 0.05)) / 1" | bc)

    echo "$sys_cpu $sys_mem $kube_cpu $kube_mem"
}

# Profil Minimal
calculate_minimal() {
    local vcpu=$1
    local ram_gib=$2
    local ram_mib=$3

    # Normalize ram_gib to an integer for bash arithmetic
    local ram_gib_int
    ram_gib_int=$(printf "%.0f" "$ram_gib")

    # system-reserved CPU
    local sys_cpu
    if (( vcpu < 8 )); then
        sys_cpu=100
    else
        sys_cpu=150
    fi

    # system-reserved Memory
    local sys_mem=$((256 + ram_gib_int * 8))

    # kube-reserved CPU
    local kube_cpu=$((60 + vcpu * 5))

    # kube-reserved Memory
    local kube_mem=$((256 + ram_gib_int * 8))

    echo "$sys_cpu $sys_mem $kube_cpu $kube_mem"
}

################################################################################
# Applying the density factor
################################################################################

apply_density_factor() {
    local sys_cpu=$1
    local sys_mem=$2
    local kube_cpu=$3
    local kube_mem=$4
    local factor=$5

    # Apply the factor and force integer conversion (no decimals)
    sys_cpu=$(printf "%.0f" "$(echo "$sys_cpu * $factor" | bc)")
    sys_mem=$(printf "%.0f" "$(echo "$sys_mem * $factor" | bc)")
    kube_cpu=$(printf "%.0f" "$(echo "$kube_cpu * $factor" | bc)")
    kube_mem=$(printf "%.0f" "$(echo "$kube_mem * $factor" | bc)")

    echo "$sys_cpu $sys_mem $kube_cpu $kube_mem"
}

################################################################################
# Cgroup verification and creation
################################################################################

ensure_cgroups() {
    log_info "Checking required cgroups..."

    # Detect the cgroup version
    local cgroup_version
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        cgroup_version="v2"
        log_info "cgroup v2 system detected"
    else
        cgroup_version="v1"
        log_info "cgroup v1 system detected"
    fi

    # For cgroup v2
    if [[ "$cgroup_version" == "v2" ]]; then
        # Check system.slice
        if [[ ! -d /sys/fs/cgroup/system.slice ]]; then
            log_warning "Cgroup /system.slice does not exist, systemd will create it"
        else
            log_success "Cgroup /system.slice existe"
        fi

        # Check kubelet.slice
        if [[ ! -d /sys/fs/cgroup/kubelet.slice ]]; then
            log_info "Creating /kubelet.slice cgroup..."
            if systemctl cat kubelet.slice &>/dev/null; then
                log_success "kubelet.slice already configured in systemd"
            else
                log_warning "kubelet.slice does not exist. Creating a systemd unit..."
                cat > /etc/systemd/system/kubelet.slice <<'EOF'
[Unit]
Description=Kubelet Slice
Before=slices.target

[Slice]
CPUAccounting=yes
MemoryAccounting=yes
EOF
                systemctl daemon-reload
                log_success "kubelet.slice created (systemd will mount the slice on demand)"
            fi
        else
            log_success "Cgroup /kubelet.slice existe"
        fi
    else
        # Pour cgroup v1
        log_warning "cgroup v1 detected. Configure cgroups manually if needed."
    fi
}

################################################################################
# Attaching kubelet.service to kubelet.slice
################################################################################

ensure_kubelet_slice_attachment() {
    log_info "Checking kubelet service attachment to kubelet.slice..."

    # Check whether kubelet.service exists
    if ! systemctl cat kubelet.service &>/dev/null; then
        log_warning "The kubelet.service unit does not exist on this system yet"
        log_warning "Attachment to kubelet.slice must be configured manually after kubelet installation"
        return 0
    fi

    # Check the current slice used by kubelet.service
    local current_slice
    current_slice=$(systemctl show kubelet.service -p Slice --value 2>/dev/null)

    if [[ "$current_slice" == "kubelet.slice" ]]; then
        log_success "kubelet service already attached to kubelet.slice"
        return 0
    fi

    # Kubelet is not in the correct slice
    log_warning "Service kubelet actuellement dans : ${current_slice:-system.slice}"
    log_info "Configuring attachment to kubelet.slice..."

    # Create the drop-in directory if required
    local dropin_dir="/etc/systemd/system/kubelet.service.d"
    mkdir -p "$dropin_dir"

    # Create the drop-in to attach kubelet to kubelet.slice
    local dropin_file="${dropin_dir}/11-kubelet-slice.conf"

    cat > "$dropin_file" <<'EOF'
# Automatic kubelet reservation configuration
# Attach kubelet.service to kubelet.slice to enforce kube-reserved
# Generated automatically by kubelet_auto_config.sh

[Unit]
# Ensure the slice exists before starting kubelet
After=kubelet.slice
Requires=kubelet.slice

[Service]
# Placer kubelet dans kubelet.slice au lieu de system.slice
Slice=kubelet.slice
EOF

    log_success "systemd drop-in created: $dropin_file"

    # Reload the systemd configuration
    log_info "Rechargement de la configuration systemd..."
    systemctl daemon-reload

    # Ensure the change is applied
    local new_slice
    new_slice=$(systemctl show kubelet.service -p Slice --value 2>/dev/null)

    if [[ "$new_slice" == "kubelet.slice" ]]; then
        log_success "kubelet service configured to attach to kubelet.slice"
        log_info "  → Change will take effect after the next kubelet restart"
    else
        log_error "Failed to configure attachment (detected slice: $new_slice)"
    fi
}

################################################################################
# Validate the effective kubelet attachment
################################################################################

validate_kubelet_slice_attachment() {
    log_info "Validating kubelet attachment to kubelet.slice..."

    # Wait for the kubelet to fully start
    sleep 3

    # Check the effective slice via systemctl
    local effective_slice
    effective_slice=$(systemctl show kubelet.service -p Slice --value 2>/dev/null)

    if [[ "$effective_slice" == "kubelet.slice" ]]; then
        log_success "✓ kubelet service properly attached to kubelet.slice"
    else
        log_error $'✗ kubelet service NOT in kubelet.slice (detected: '"${effective_slice:-N/A}"$')\n  → kube-reserved will NOT be enforced on the kubelet itself!\n  → Check: systemctl status kubelet | grep Cgroup'
    fi

    # Check the real kubelet process cgroup
    local kubelet_pid
    kubelet_pid=$(systemctl show kubelet.service -p MainPID --value 2>/dev/null)

    if [[ -n "$kubelet_pid" ]] && [[ "$kubelet_pid" != "0" ]]; then
        local kubelet_cgroup

        # Robust parsing with cgroup v1/v2 fallback
        if [[ -f "/proc/$kubelet_pid/cgroup" ]]; then
            # cgroup v2: single line with "0::"
            kubelet_cgroup=$(grep -E '^0::' "/proc/$kubelet_pid/cgroup" 2>/dev/null | cut -d: -f3)

            # cgroup v1 fallback: search the cpu or memory line
            if [[ -z "$kubelet_cgroup" ]]; then
                kubelet_cgroup=$(grep -E '^[0-9]+:(cpu|memory):' "/proc/$kubelet_pid/cgroup" 2>/dev/null | head -n1 | cut -d: -f3)
            fi

            # Verification
            if [[ -n "$kubelet_cgroup" ]]; then
                if echo "$kubelet_cgroup" | grep -q "kubelet.slice"; then
                    log_success "✓ Kubelet process (PID $kubelet_pid) is in the correct cgroup"
                    log_info "  → Cgroup: $kubelet_cgroup"
                else
                    log_warning "✗ Kubelet process is in an unexpected cgroup: $kubelet_cgroup"
                fi
            else
                log_warning "Impossible de parser le cgroup du kubelet (format inattendu)"
            fi
        else
            log_warning "Fichier /proc/$kubelet_pid/cgroup introuvable"
        fi
    fi

    return 0
}

################################################################################
# Dynamic eviction threshold calculation
################################################################################

calculate_eviction_thresholds() {
    local ram_gib=$1
    local ram_mib=$2

    # Eviction hard memory - scale with RAM size
    local eviction_hard_mem
    if (( $(echo "$ram_gib < 8" | bc -l) )); then
        eviction_hard_mem="250Mi"
    elif (( $(echo "$ram_gib < 32" | bc -l) )); then
        eviction_hard_mem="500Mi"
    elif (( $(echo "$ram_gib < 64" | bc -l) )); then
        eviction_hard_mem="1Gi"
    else
        eviction_hard_mem="2Gi"
    fi

    # Eviction soft memory
    local eviction_soft_mem
    if (( $(echo "$ram_gib < 8" | bc -l) )); then
        eviction_soft_mem="500Mi"
    elif (( $(echo "$ram_gib < 32" | bc -l) )); then
        eviction_soft_mem="1Gi"
    elif (( $(echo "$ram_gib < 64" | bc -l) )); then
        eviction_soft_mem="2Gi"
    else
        eviction_soft_mem="4Gi"
    fi

    echo "$eviction_hard_mem $eviction_soft_mem"
}

################################################################################
# Kubelet configuration generation
################################################################################

generate_kubelet_config_from_scratch() {
    local sys_cpu=$1
    local sys_mem=$2
    local kube_cpu=$3
    local kube_mem=$4
    local vcpu=$5
    local ram_gib=$6
    local ram_mib=$7
    local eviction_hard_mem=$8
    local eviction_soft_mem=$9
    local node_type=${10}

    local system_ephemeral_mib kube_ephemeral_mib
    read -r system_ephemeral_mib kube_ephemeral_mib <<< "$(calculate_ephemeral_reservations)"
    log_info "Computed ephemeral reservations: system=${system_ephemeral_mib}Mi, kube=${kube_ephemeral_mib}Mi"

    # Adapt enforceNodeAllocatable based on node type
    local enforce_list
    if [[ "$node_type" == "control-plane" ]]; then
        enforce_list='  - "pods"
  - "system-reserved"'
    else
        enforce_list='  - "pods"
  - "system-reserved"
  - "kube-reserved"'
    fi

    cat <<EOF
# Configuration automatically generated on $(date)
# Profil: $PROFILE | Density-factor: $DENSITY_FACTOR | Type: $node_type
# Node: ${vcpu} vCPU / ${ram_gib} GiB RAM

apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

# ============================================================
# SYSTEM AND KUBE RESERVATIONS
# ============================================================
systemReserved:
  cpu: "${sys_cpu}m"
  memory: "${sys_mem}Mi"
  ephemeral-storage: "${system_ephemeral_mib}Mi"

kubeReserved:
  cpu: "${kube_cpu}m"
  memory: "${kube_mem}Mi"
  ephemeral-storage: "${kube_ephemeral_mib}Mi"

# ============================================================
# RESERVATION ENFORCEMENT
# ============================================================
# Node type: $node_type
# $(if [[ "$node_type" == "control-plane" ]]; then echo "kube-reserved NOT enforced (preserves critical static pods)"; else echo "kube-reserved enforced (worker node)"; fi)
enforceNodeAllocatable:
$enforce_list

cgroupDriver: "systemd"
cgroupRoot: "/"

systemReservedCgroup: "/system.slice"
kubeReservedCgroup: "/kubelet.slice"

# ============================================================
# EVICTION THRESHOLDS (dynamic based on node size)
# ============================================================
evictionHard:
  memory.available: "${eviction_hard_mem}"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"

evictionSoft:
  memory.available: "${eviction_soft_mem}"
  nodefs.available: "15%"
  imagefs.available: "20%"

evictionSoftGracePeriod:
  memory.available: "1m30s"
  nodefs.available: "2m"
  imagefs.available: "2m"

evictionPressureTransitionPeriod: "30s"

evictionMinimumReclaim:
  memory.available: "0Mi"
  nodefs.available: "500Mi"
  imagefs.available: "2Gi"

# ============================================================
# CONFIGURATION RUNTIME
# ============================================================
containerRuntimeEndpoint: "unix:///run/containerd/containerd.sock"

cpuCFSQuota: true
cpuCFSQuotaPeriod: "100ms"

nodeStatusUpdateFrequency: "10s"
nodeStatusReportFrequency: "5m"

logging:
  verbosity: 2
  format: text
EOF
}

generate_kubelet_config() {
    local sys_cpu=$1
    local sys_mem=$2
    local kube_cpu=$3
    local kube_mem=$4
    local vcpu=$5
    local ram_gib=$6
    local ram_mib=$7
    local output_file=$8
    local node_type=$9

    # Calculate eviction thresholds
    read -r eviction_hard_mem eviction_soft_mem <<< $(calculate_eviction_thresholds "$ram_gib" "$ram_mib")

    local system_ephemeral_mib kube_ephemeral_mib
    read -r system_ephemeral_mib kube_ephemeral_mib <<< "$(calculate_ephemeral_reservations)"
    log_info "Computed ephemeral reservations: system=${system_ephemeral_mib}Mi, kube=${kube_ephemeral_mib}Mi"

    # If the kubelet config file exists, merge with the existing one
    if [[ -f "$KUBELET_CONFIG" ]]; then
        log_info "Merging with existing configuration (preserving custom tweaks)..."

        # Copy the existing file as a base
        cp "$KUBELET_CONFIG" "$output_file"

        # Add a traceability comment at the top of the file
        local header_comment="# Automatically updated on $(date) - Profile: $PROFILE | Density-factor: $DENSITY_FACTOR | Type: $node_type"
        sed -i.tmp "1i\\
$header_comment
" "$output_file"
        rm -f "${output_file}.tmp"

        # Modify ONLY the fields managed by this script with yq
        log_info "Updating system and kube reservations..."

        # systemReserved
        yq eval -i ".systemReserved.cpu = \"${sys_cpu}m\"" "$output_file"
        yq eval -i ".systemReserved.memory = \"${sys_mem}Mi\"" "$output_file"
        yq eval -i ".systemReserved.\"ephemeral-storage\" = \"${system_ephemeral_mib}Mi\"" "$output_file"

        # kubeReserved
        yq eval -i ".kubeReserved.cpu = \"${kube_cpu}m\"" "$output_file"
        yq eval -i ".kubeReserved.memory = \"${kube_mem}Mi\"" "$output_file"
        yq eval -i ".kubeReserved.\"ephemeral-storage\" = \"${kube_ephemeral_mib}Mi\"" "$output_file"

        # enforceNodeAllocatable (adapt based on node type)
        if [[ "$node_type" == "control-plane" ]]; then
            log_warning "Control-plane mode: kube-reserved enforcement disabled"
            yq eval -i '.enforceNodeAllocatable = ["pods", "system-reserved"]' "$output_file"
        else
            log_info "Worker mode: full enforcement (pods, system-reserved, kube-reserved)"
            yq eval -i '.enforceNodeAllocatable = ["pods", "system-reserved", "kube-reserved"]' "$output_file"
        fi

        # Cgroups
        yq eval -i '.cgroupDriver = "systemd"' "$output_file"
        yq eval -i '.cgroupRoot = "/"' "$output_file"
        yq eval -i '.systemReservedCgroup = "/system.slice"' "$output_file"
        yq eval -i '.kubeReservedCgroup = "/kubelet.slice"' "$output_file"

        # Eviction thresholds
        yq eval -i ".evictionHard.\"memory.available\" = \"${eviction_hard_mem}\"" "$output_file"
        yq eval -i '.evictionHard."nodefs.available" = "10%"' "$output_file"
        yq eval -i '.evictionHard."nodefs.inodesFree" = "5%"' "$output_file"
        yq eval -i '.evictionHard."imagefs.available" = "15%"' "$output_file"

        yq eval -i ".evictionSoft.\"memory.available\" = \"${eviction_soft_mem}\"" "$output_file"
        yq eval -i '.evictionSoft."nodefs.available" = "15%"' "$output_file"
        yq eval -i '.evictionSoft."imagefs.available" = "20%"' "$output_file"

        yq eval -i '.evictionSoftGracePeriod."memory.available" = "1m30s"' "$output_file"
        yq eval -i '.evictionSoftGracePeriod."nodefs.available" = "2m"' "$output_file"
        yq eval -i '.evictionSoftGracePeriod."imagefs.available" = "2m"' "$output_file"

        yq eval -i '.evictionPressureTransitionPeriod = "30s"' "$output_file"

        yq eval -i '.evictionMinimumReclaim."memory.available" = "0Mi"' "$output_file"
        yq eval -i '.evictionMinimumReclaim."nodefs.available" = "500Mi"' "$output_file"
        yq eval -i '.evictionMinimumReclaim."imagefs.available" = "2Gi"' "$output_file"

        log_success "Configuration merged: existing tweaks preserved"

    else
        log_info "No existing configuration detected, generating a full config..."

        # Generate a complete config from scratch
        generate_kubelet_config_from_scratch "$sys_cpu" "$sys_mem" "$kube_cpu" "$kube_mem" \
            "$vcpu" "$ram_gib" "$ram_mib" "$eviction_hard_mem" "$eviction_soft_mem" "$node_type" > "$output_file"
    fi
}

################################################################################
# Validation YAML
################################################################################

validate_yaml() {
    local config_file=$1

    log_info "Validation de la configuration YAML..."

    if ! yq eval '.' "$config_file" > /dev/null 2>&1; then
        log_error "Generated configuration is not valid YAML"
    fi

    # Additional checks
    local api_version
    api_version=$(yq eval '.apiVersion' "$config_file" 2>/dev/null)
    if [[ "$api_version" != "kubelet.config.k8s.io/v1beta1" ]]; then
        log_error "Invalid apiVersion in configuration: $api_version"
    fi

    local kind
    kind=$(yq eval '.kind' "$config_file" 2>/dev/null)
    if [[ "$kind" != "KubeletConfiguration" ]]; then
        log_error "Invalid kind in configuration: $kind"
    fi

    log_success "YAML configuration validated"
}

################################################################################
# Summary display
################################################################################

display_summary() {
    local vcpu=$1
    local ram_gib=$2
    local sys_cpu=$3
    local sys_mem=$4
    local kube_cpu=$5
    local kube_mem=$6
    local node_type=$7

    local total_cpu=$((sys_cpu + kube_cpu))
    local total_mem=$((sys_mem + kube_mem))
    local alloc_cpu=$((vcpu * 1000 - total_cpu))
    local alloc_mem=$(echo "scale=2; ($ram_gib * 1024 - $total_mem) / 1024" | bc)
    local cpu_percent=$(echo "scale=2; ($total_cpu / ($vcpu * 1000)) * 100" | bc)
    local mem_percent=$(echo "scale=2; ($total_mem / ($ram_gib * 1024)) * 100" | bc)

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  KUBELET CONFIGURATION - CALCULATED RESERVATIONS"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Node configuration:"
    echo "  vCPU:              $vcpu"
    echo "  RAM:               $ram_gib GiB"
    echo "  Type:              $node_type"
    echo "  Profil:            $PROFILE"
    echo "  Density-factor:    $DENSITY_FACTOR"
    echo ""
    echo "───────────────────────────────────────────────────────────────────────────"
    echo "Reservations:"
    echo "───────────────────────────────────────────────────────────────────────────"
    echo ""
    echo "  system-reserved:"
    echo "    CPU:             ${sys_cpu}m"
    echo "    Memory:           ${sys_mem} MiB ($(echo "scale=2; $sys_mem / 1024" | bc) GiB)"
    echo ""
    echo "  kube-reserved:"
    echo "    CPU:             ${kube_cpu}m"
    echo "    Memory:           ${kube_mem} MiB ($(echo "scale=2; $kube_mem / 1024" | bc) GiB)"
    echo ""
    echo "───────────────────────────────────────────────────────────────────────────"
    echo "Totals:"
    echo "───────────────────────────────────────────────────────────────────────────"
    echo ""
    echo "  Reserved CPU:       ${total_cpu}m (${cpu_percent}%)"
    echo "  Reserved memory:    ${total_mem} MiB (${mem_percent}%)"
    echo ""
    echo "───────────────────────────────────────────────────────────────────────────"
    echo "Allocatable (available capacity for pods):"
    echo "───────────────────────────────────────────────────────────────────────────"
    echo ""
    echo "  CPU:               ${alloc_cpu}m (sur $((vcpu * 1000))m)"
    echo "  Memory:             ${alloc_mem} GiB (out of ${ram_gib} GiB)"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
}

################################################################################
# Main function
################################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --density-factor)
                DENSITY_FACTOR="$2"
                shift 2
                ;;
            --target-pods)
                TARGET_PODS="$2"
                shift 2
                ;;
            --node-type)
                NODE_TYPE="$2"
                shift 2
                ;;
            --wait-timeout)
                KUBELET_WAIT_TIMEOUT="$2"
                if ! [[ "$KUBELET_WAIT_TIMEOUT" =~ ^[0-9]+$ ]]; then
                    log_error "--wait-timeout must be a positive integer (received: $KUBELET_WAIT_TIMEOUT)"
                fi
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --backup)
                BACKUP=true
                shift
                ;;
            --no-require-deps)
                REQUIRE_DEPENDENCIES=false
                log_warning "Strict dependency mode disabled (not recommended in production)"
                shift
                ;;
            --help)
                usage
                ;;
            *)
                log_error "Option inconnue: $1. Utilisez --help pour l'aide."
                ;;
        esac
    done

    # System checks
    check_root
    check_os
    acquire_lock
    check_dependencies

    local pre_alloc_snapshot
    pre_alloc_snapshot=$(get_current_allocatable_snapshot || true)
    if [[ -n "$pre_alloc_snapshot" ]]; then
        local pre_cpu_m=${pre_alloc_snapshot%%:*}
        local pre_mem_mi=${pre_alloc_snapshot##*:}
        log_info "Current allocatable -> CPU: ${pre_cpu_m}m | Memory: ${pre_mem_mi}Mi"
    fi

    # Input validation
    validate_profile "$PROFILE"
    validate_node_type "$NODE_TYPE"
    validate_density_factor "$DENSITY_FACTOR"

    # Resource detection
    log_info "Detecting system resources..."
    VCPU=$(detect_vcpu)
    RAM_MIB=$(detect_ram_mib)
    RAM_GIB=$(detect_ram_gib)

    log_success "Detected: ${VCPU} vCPU, ${RAM_GIB} GiB RAM (${RAM_MIB} MiB)"

    # Node type detection (control-plane vs worker)
    if [[ "$NODE_TYPE" == "auto" ]]; then
        NODE_TYPE_DETECTED=$(detect_node_type)
    else
        NODE_TYPE_DETECTED="$NODE_TYPE"
        log_info "Node type manually forced: $NODE_TYPE_DETECTED"
    fi

    if [[ "$NODE_TYPE_DETECTED" == "control-plane" ]]; then
        if (( $(echo "$DENSITY_FACTOR > $CONTROL_PLANE_MAX_DENSITY" | bc -l) )); then
            log_warning "Density-factor $DENSITY_FACTOR is too high for a control-plane. Applying limit: $CONTROL_PLANE_MAX_DENSITY"
            DENSITY_FACTOR=$CONTROL_PLANE_MAX_DENSITY
        fi
    fi

    # Automatically compute density factor when target-pods is set
    if [[ -n "$TARGET_PODS" ]]; then
        log_info "Automatically computing density-factor for $TARGET_PODS target pods..."
        DENSITY_FACTOR=$(calculate_density_factor "$TARGET_PODS")
        log_success "Density-factor computed: $DENSITY_FACTOR"
    fi

    # Compute reservations according to the profile
    log_info "Calculating reservations with profile '$PROFILE'..."

    # Note: RAM_GIB may now be decimal, so round it for arithmetic
    RAM_GIB_INT=$(echo "$RAM_GIB" | cut -d. -f1)

    # Validation de RAM_GIB_INT avec fallback
    if [[ -z "$RAM_GIB_INT" ]] || [[ "$RAM_GIB_INT" == "0" ]]; then
        RAM_GIB_INT=1
        log_warning "Invalid or empty RAM GiB value ('$RAM_GIB'), using minimum value: 1 GiB"
    fi

    case $PROFILE in
        gke)
            read -r SYS_CPU SYS_MEM KUBE_CPU KUBE_MEM <<< $(calculate_gke "$VCPU" "$RAM_GIB_INT" "$RAM_MIB")
            ;;
        eks)
            read -r SYS_CPU SYS_MEM KUBE_CPU KUBE_MEM <<< $(calculate_eks "$VCPU" "$RAM_GIB_INT" "$RAM_MIB")
            ;;
        conservative)
            read -r SYS_CPU SYS_MEM KUBE_CPU KUBE_MEM <<< $(calculate_conservative "$VCPU" "$RAM_GIB_INT" "$RAM_MIB")
            ;;
        minimal)
            read -r SYS_CPU SYS_MEM KUBE_CPU KUBE_MEM <<< $(calculate_minimal "$VCPU" "$RAM_GIB_INT" "$RAM_MIB")
            ;;
    esac

    # Validate calculated values
    validate_calculated_value "$SYS_CPU" "system-reserved CPU" 50
    validate_calculated_value "$SYS_MEM" "system-reserved Memory" 100
    validate_calculated_value "$KUBE_CPU" "kube-reserved CPU" 50
    validate_calculated_value "$KUBE_MEM" "kube-reserved Memory" 100

    # Applying the density factor
    if [[ $(echo "$DENSITY_FACTOR != 1.0" | bc -l) -eq 1 ]]; then
        log_info "Applying density-factor ${DENSITY_FACTOR}..."
        read -r SYS_CPU SYS_MEM KUBE_CPU KUBE_MEM <<< $(apply_density_factor "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM" "$DENSITY_FACTOR")

        # Re-validate after applying the factor
        validate_calculated_value "$SYS_CPU" "system-reserved CPU (after factor)" 50
        validate_calculated_value "$SYS_MEM" "system-reserved Memory (after factor)" 100
        validate_calculated_value "$KUBE_CPU" "kube-reserved CPU (after factor)" 50
        validate_calculated_value "$KUBE_MEM" "kube-reserved Memory (after factor)" 100
    fi

    # Validate that the allocatable value is not negative
    local total_cpu_reserved=$((SYS_CPU + KUBE_CPU))
    local total_mem_reserved=$((SYS_MEM + KUBE_MEM))
    local total_cpu_capacity=$((VCPU * 1000))
    local total_mem_capacity=$(echo "scale=0; $RAM_GIB * 1024" | bc | cut -d. -f1)

    if (( total_cpu_reserved >= total_cpu_capacity )); then
        log_error "Total CPU reservations ($total_cpu_reserved m) >= CPU capacity ($total_cpu_capacity m)! Reduce the density factor."
    fi

    if (( total_mem_reserved >= total_mem_capacity )); then
        log_error "Total memory reservations ($total_mem_reserved Mi) >= memory capacity ($total_mem_capacity Mi)! Reduce the density factor."
    fi

    # Compute estimated allocatable values and remaining percentages
    local alloc_cpu_milli=$((total_cpu_capacity - total_cpu_reserved))
    local alloc_mem_mib=$((total_mem_capacity - total_mem_reserved))
    local cpu_alloc_percent=$(echo "scale=2; ($alloc_cpu_milli / $total_cpu_capacity) * 100" | bc)
    local mem_alloc_percent=$(echo "scale=2; ($alloc_mem_mib / $total_mem_capacity) * 100" | bc)

    # Display the estimated variation versus the initial state (if available)
    if [[ -n "$pre_alloc_snapshot" ]]; then
        local pre_cpu_m=${pre_alloc_snapshot%%:*}
        local pre_mem_mi=${pre_alloc_snapshot##*:}
        local cpu_diff=$((alloc_cpu_milli - pre_cpu_m))
        local mem_diff=$((alloc_mem_mib - pre_mem_mi))
        local cpu_diff_fmt
        local mem_diff_fmt
        cpu_diff_fmt=$(format_diff "$cpu_diff")
        mem_diff_fmt=$(format_diff "$mem_diff")
        log_info "Estimated allocatable -> CPU: ${alloc_cpu_milli}m (${cpu_diff_fmt}m) | Memory: ${alloc_mem_mib}Mi (${mem_diff_fmt}Mi)"
    else
        log_info "Estimated allocatable -> CPU: ${alloc_cpu_milli}m | Memory: ${alloc_mem_mib}Mi"
    fi

    # Preventive warnings
    if (( $(echo "$cpu_alloc_percent < 10" | bc -l) )); then
        log_warning "Allocatable CPU critically low: ${cpu_alloc_percent}% (< 10% of capacity)"
    fi

    if (( $(echo "$mem_alloc_percent < 10" | bc -l) )); then
        log_warning "Allocatable memory critically low: ${mem_alloc_percent}% (< 10% of capacity)"
    fi

    # Garde-fous stricts
    local min_cpu_percent=$MIN_ALLOC_CPU_PERCENT
    local min_mem_percent=$MIN_ALLOC_MEM_PERCENT
    if [[ "$NODE_TYPE_DETECTED" == "control-plane" ]]; then
        min_cpu_percent=$((min_cpu_percent + 5))
        min_mem_percent=$((min_mem_percent + 5))
    fi

    if (( $(echo "$cpu_alloc_percent < $min_cpu_percent" | bc -l) )); then
        log_error "Allocatable CPU would drop to ${cpu_alloc_percent}% (< ${min_cpu_percent}%). Reduce the density factor or use a lighter profile."
    fi

    if (( $(echo "$mem_alloc_percent < $min_mem_percent" | bc -l) )); then
        log_error "Allocatable memory would drop to ${mem_alloc_percent}% (< ${min_mem_percent}%). Reduce the density factor or use a lighter profile."
    fi

    # Summary display
    display_summary "$VCPU" "$RAM_GIB" "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM" "$NODE_TYPE_DETECTED"

    # Mode dry-run : afficher la config sans appliquer
    if [[ "$DRY_RUN" == true ]]; then
        log_warning "DRY-RUN mode enabled - configuration not applied"
        echo ""

        # Create a temporary file for the dry-run
        local temp_dryrun
        temp_dryrun=$(mktemp /tmp/kubelet-config-dryrun.XXXXXX)
        mv "$temp_dryrun" "${temp_dryrun}.yaml"
        temp_dryrun="${temp_dryrun}.yaml"

        generate_kubelet_config "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM" "$VCPU" "$RAM_GIB" "$RAM_MIB" "$temp_dryrun" "$NODE_TYPE_DETECTED"

        echo "Configuration that would be generated:"
        echo "───────────────────────────────────────────────────────────────────────────"
        cat "$temp_dryrun"
        echo ""

        # Cleanup
        rm -f "$temp_dryrun"

        log_info "Run again without --dry-run to apply the changes"
        exit 0
    fi

    # Cgroup verification and creation
    ensure_cgroups

    # Configure kubelet.service attachment to kubelet.slice
    ensure_kubelet_slice_attachment

    # Automatically back up the existing configuration (always keep a backup in production)
    BACKUP_FILE=""
    if [[ -f "$KUBELET_CONFIG" ]]; then
        BACKUP_FILE="${KUBELET_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Automatically backing up the existing configuration..."
        cp "$KUBELET_CONFIG" "$BACKUP_FILE"
        log_success "Backup created: $BACKUP_FILE"
    fi

    # Generate the new configuration in a temporary file
    local temp_config
    temp_config=$(mktemp /tmp/kubelet-config.XXXXXX)
    mv "$temp_config" "${temp_config}.yaml"
    temp_config="${temp_config}.yaml"

    log_info "Generating the new kubelet configuration..."
    generate_kubelet_config "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM" "$VCPU" "$RAM_GIB" "$RAM_MIB" "$temp_config" "$NODE_TYPE_DETECTED"

    # Validation YAML
    validate_yaml "$temp_config"

    # Apply the configuration
    log_info "Application de la nouvelle configuration..."
    cp "$temp_config" "$KUBELET_CONFIG"
    rm -f "$temp_config"
    log_success "Configuration written to $KUBELET_CONFIG"

    # Restart the kubelet with rollback on failure
    log_info "Restarting kubelet..."
    if ! systemctl restart kubelet; then
        log_warning "Kubelet restart failed"

        # Attempt rollback
        if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
            log_warning "Attempting to restore the previous configuration..."
            cp "$BACKUP_FILE" "$KUBELET_CONFIG"

            if systemctl restart kubelet; then
                log_warning "Configuration restored, kubelet restarted with the previous config"
            else
                log_warning "Automatic restoration failed. Check manually: journalctl -u kubelet -f"
            fi
        else
            log_warning "Pas de backup disponible pour restauration automatique"
        fi

        log_error "The new configuration caused a problem. Check journalctl -u kubelet -n 100"
    fi

    log_success "Kubelet restarted successfully"

    # Check stability
    log_info "Checking kubelet stability (up to ${KUBELET_WAIT_TIMEOUT}s)..."
    local wait_interval=5
    local max_wait=$KUBELET_WAIT_TIMEOUT
    local elapsed=0
    local kubelet_active=false

    while (( elapsed < max_wait )); do
        if systemctl is-active --quiet kubelet; then
            kubelet_active=true
            break
        fi

        ((elapsed += wait_interval))
        log_info "  → Kubelet still starting (${elapsed}s/${max_wait}s)..."
        sleep "$wait_interval"
    done

    if [[ "$kubelet_active" == true ]]; then
        log_success "✓ Kubelet active and healthy"

        # Validate the effective attachment of kubelet to kubelet.slice
        validate_kubelet_slice_attachment

        # Retrieve the real allocatable after application (when possible)
        local post_alloc_snapshot
        post_alloc_snapshot=$(get_current_allocatable_snapshot || true)
        if [[ -n "$pre_alloc_snapshot" ]] && [[ -n "$post_alloc_snapshot" ]]; then
            local pre_cpu_m=${pre_alloc_snapshot%%:*}
            local pre_mem_mi=${pre_alloc_snapshot##*:}
            local post_cpu_m=${post_alloc_snapshot%%:*}
            local post_mem_mi=${post_alloc_snapshot##*:}
            local cpu_diff=$((post_cpu_m - pre_cpu_m))
            local mem_diff=$((post_mem_mi - pre_mem_mi))
            local cpu_diff_fmt
            local mem_diff_fmt
            cpu_diff_fmt=$(format_diff "$cpu_diff")
            mem_diff_fmt=$(format_diff "$mem_diff")
            log_info "Δ real allocatable -> CPU: ${post_cpu_m}m (${cpu_diff_fmt}m) | Memory: ${post_mem_mi}Mi (${mem_diff_fmt}Mi)"
        fi

        # Intelligent backup rotation management
        if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
            local max_rotation=4

            if [[ "$BACKUP" == true ]]; then
                # --backup specified: keep the timestamped permanent backup
                log_success "Permanent backup kept: $BACKUP_FILE"
                log_info "  → Manual permanent backup (kept up to 90 days)"
            fi

            # Always rotate automatic backups
            log_info "Rotating automatic backups..."

            # Rotation: .3 → deleted, .2 → .3, .1 → .2, .0 → .1
            for i in $(seq $((max_rotation - 1)) -1 0); do
                local current="/var/lib/kubelet/config.yaml.last-success.$i"
                local next="/var/lib/kubelet/config.yaml.last-success.$((i + 1))"

                if [[ -f "$current" ]]; then
                    if (( i == max_rotation - 1 )); then
                        rm -f "$current"  # Supprime le plus ancien
                    else
                        mv "$current" "$next"
                    fi
                fi
            done

            # The new backup becomes .0
            if [[ "$BACKUP" == true ]]; then
                # Copy (because we also keep the timestamped original)
                cp "$BACKUP_FILE" "/var/lib/kubelet/config.yaml.last-success.0"
            else
                # Move (no permanent backup requested)
                mv "$BACKUP_FILE" "/var/lib/kubelet/config.yaml.last-success.0"
            fi

            log_info "Rotating backup created: /var/lib/kubelet/config.yaml.last-success.0"

            # Count the backups available in history
            local history_count=0
            for i in $(seq 0 $((max_rotation - 1))); do
                if [[ -f "/var/lib/kubelet/config.yaml.last-success.$i" ]]; then
                    history_count=$((history_count + 1))
                fi
            done
            log_info "  → $history_count rotating backup(s) available: .last-success.{0..$((history_count - 1))}"
            log_info "  → .0 = newest, .$((history_count - 1)) = oldest"

            # Clean up timestamped permanent backups (>90 days)
            local old_count=$(find /var/lib/kubelet -name 'config.yaml.backup.2*' -mtime +90 2>/dev/null | wc -l)
            if (( old_count > 0 )); then
                find /var/lib/kubelet -name 'config.yaml.backup.2*' -mtime +90 -delete 2>/dev/null
                log_info "Cleaned $old_count permanent backup(s) older than 90 days"
            fi
        fi
    else
        log_warning "✗ Kubelet not active after ${max_wait}s!"

        # Automatic rollback
        if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
            log_warning "Rollback automatique en cours..."
            cp "$BACKUP_FILE" "$KUBELET_CONFIG"
            if systemctl restart kubelet; then
                log_warning "Configuration restored. Kubelet restarted with the previous configuration"
            else
                log_warning "Restoration failed. Inspect journalctl -u kubelet -n 100"
            fi
        fi

        log_error "Abort: kubelet did not become active after restart. Check journalctl -u kubelet -n 100"
    fi

    echo ""
    log_success "Configuration completed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Check kubelet logs:          journalctl -u kubelet -f"
    echo "  2. Inspect allocatable:       kubectl describe node \$(hostname)"
    echo "  3. Inspect cgroups:             systemd-cgls | grep -E 'system.slice|kubepods'"
    if [[ "$BACKUP" == true ]] && [[ -n "$BACKUP_FILE" ]]; then
        echo "  4. Backup kept at:              $BACKUP_FILE"
    fi
    echo ""
}

# Execution
main "$@"
