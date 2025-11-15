#!/usr/bin/env bash
set -euo pipefail

#
# remove-kubelet-auto-config.sh
# ------------------------------
# Cleanly remove kubelet_auto_config.sh, rollback-kubelet-config.sh and all
# kubelet-auto-config@*.service instances without restarting the kubelet.
#
# Usage:
#   sudo ./remove-kubelet-auto-config.sh
#   sudo ./remove-kubelet-auto-config.sh --dry-run
#

DRY_RUN=false

usage() {
    cat <<'EOF'
Usage: remove-kubelet-auto-config.sh [--dry-run]

Disable every kubelet-auto-config@*.service unit, remove the associated
EnvironmentFile drop-ins, delete the installed scripts under /usr/local/bin
and clean /usr/local/lib/kubelet-auto-config. The kubelet process is not
restarted so running workloads stay untouched.

Options:
  --dry-run   Display the actions that would be executed without touching the node.
  -h, --help  Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "✗ This script must be run as root (sudo)." >&2
    exit 1
fi

log_info() {
    printf '[INFO] %s\n' "$*"
}

log_success() {
    printf '[OK]   %s\n' "$*"
}

log_warning() {
    printf '[WARN] %s\n' "$*"
}

run_cmd() {
    if $DRY_RUN; then
        log_info "[dry-run] $*"
    else
        "$@"
    fi
}

remove_path() {
    local path="$1"
    local kind="$2"

    if [[ -e "$path" ]] || [[ -L "$path" ]]; then
        if $DRY_RUN; then
            log_info "[dry-run] removing ${kind}: $path"
        else
            rm -rf --preserve-root "$path"
            log_success "Removed ${kind}: $path"
        fi
    fi
}

service_exists() {
    local unit="$1"
    if systemctl list-unit-files "$unit" --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit"; then
        return 0
    fi
    if systemctl list-units "$unit" --all --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit"; then
        return 0
    fi
    return 1
}

ENV_DIR="/etc/kubelet-auto-config"
SERVICE_TEMPLATE="/etc/systemd/system/kubelet-auto-config@.service"
LIB_DIR="/usr/local/lib/kubelet-auto-config"
LOCK_FILE="/var/lock/kubelet-auto-config.lock"
BINARIES=(
    "/usr/local/bin/kubelet_auto_config.sh"
    "/usr/local/bin/rollback-kubelet-config.sh"
    "/usr/local/bin/remove-kubelet-auto-config.sh"
)

declare -A SERVICES=()

# Discover services from existing environment files
if [[ -d "$ENV_DIR" ]]; then
    shopt -s nullglob
    for env_file in "$ENV_DIR"/kubelet-auto-config@*.env; do
        [[ -e "$env_file" ]] || continue
        profile="${env_file##*@}"
        profile="${profile%.env}"
        service="kubelet-auto-config@${profile}.service"
        SERVICES["$service"]=1
    done
    shopt -u nullglob
fi

# Fall back to systemctl discovery
while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    [[ "$unit" == "kubelet-auto-config@.service" ]] && continue
    SERVICES["$unit"]=1
done < <(systemctl list-unit-files 'kubelet-auto-config@*.service' --no-legend --no-pager 2>/dev/null | awk '{print $1}')

if [[ ${#SERVICES[@]} -eq 0 ]]; then
    log_info "No kubelet-auto-config@*.service instances detected."
else
    for service in "${!SERVICES[@]}"; do
        if service_exists "$service"; then
            log_info "Disabling $service..."
            if ! run_cmd systemctl disable --now "$service"; then
                log_warning "Failed to disable $service (continuing)."
            fi
        else
            log_warning "Service $service not registered, skipping disable."
        fi

        dropin_dir="/etc/systemd/system/${service}.d"
        if [[ -d "$dropin_dir" ]]; then
            remove_path "$dropin_dir" "drop-in for $service"
        fi
    done
fi

# Remove environment files after services are stopped
if [[ -d "$ENV_DIR" ]]; then
    shopt -s nullglob
    for env_file in "$ENV_DIR"/kubelet-auto-config@*.env; do
        remove_path "$env_file" "environment file"
    done
    shopt -u nullglob

    if [[ -d "$ENV_DIR" ]] && [[ -z "$(ls -A "$ENV_DIR")" ]]; then
        remove_path "$ENV_DIR" "directory"
    fi
fi

# Remove the systemd template
remove_path "$SERVICE_TEMPLATE" "systemd template"

# Clean binaries and library directory
for binary in "${BINARIES[@]}"; do
    remove_path "$binary" "binary"
done
remove_path "$LIB_DIR" "library directory"

# Remove the leftover lock file if present
remove_path "$LOCK_FILE" "lock file"

run_cmd systemctl daemon-reload

log_success "kubelet auto configuration tooling removed."
