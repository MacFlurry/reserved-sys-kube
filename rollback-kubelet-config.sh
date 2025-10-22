#!/usr/bin/env bash
#
# rollback-kubelet-config.sh
# --------------------------
# Restore a previous kubelet config from automatic backups created by
# kubelet_auto_config.sh. The script prefers the rotating backups
#   /var/lib/kubelet/config.yaml.last-success.{1..3}
# (skipping index 0 which corresponds to the current configuration),
# then falls back to permanent backups created with --backup:
#   /var/lib/kubelet/config.yaml.backup.YYYYMMDD_HHMMSS
#
# Options:
#   --index <n>    : restore a specific rotating backup (1-3)
#   --dry-run      : show the selected backup without restoring
#   --no-restart   : do not restart kubelet after restoration
#
# Usage examples:
#   sudo ./rollback-kubelet-config.sh
#   sudo ./rollback-kubelet-config.sh --index 2
#   sudo ./rollback-kubelet-config.sh --dry-run
#
set -euo pipefail

CONFIG_PATH="/var/lib/kubelet/config.yaml"
ROT_PREFIX="/var/lib/kubelet/config.yaml.last-success"
PERM_PREFIX="/var/lib/kubelet/config.yaml.backup"

INDEX=""          # user-specified rotating index
DRY_RUN=false
RESTART=true

function usage() {
    cat <<'EOF'
Usage: rollback-kubelet-config.sh [--index N] [--dry-run] [--no-restart]

Restore kubelet configuration from automatic backups created by
kubelet_auto_config.sh. By default the script restores the most recent
old backup (.last-success.1). You can provide --index to target a specific
rotating backup (1-3). If rotating backups are unavailable, the script
falls back to permanent backups created with --backup.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --index)
            INDEX="${2:-}"
            if [[ -z "$INDEX" ]]; then
                echo "✗ Missing value for --index" >&2
                exit 1
            fi
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-restart)
            RESTART=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "✗ Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "✗ This script must be run as root (sudo)" >&2
    exit 1
fi

function list_rotating_backups() {
    ls -1t ${ROT_PREFIX}.* 2>/dev/null || true
}

function list_permanent_backups() {
    ls -1t ${PERM_PREFIX}.* 2>/dev/null || true
}

SELECTED=""
SOURCE_TYPE=""

rotating_backups=( $(list_rotating_backups) )
declare -A rotating_map=()
for path in "${rotating_backups[@]}"; do
    # extract last component after dot
    suffix="${path##*.}"
    rotating_map["$suffix"]="$path"
done

if [[ -n "$INDEX" ]]; then
    if [[ ! "$INDEX" =~ ^[1-9][0-9]*$ ]]; then
        echo "✗ Invalid index '$INDEX'. Expected a positive integer >=1." >&2
        exit 1
    fi
    if [[ -n "${rotating_map[$INDEX]:-}" ]]; then
        SELECTED="${rotating_map[$INDEX]}"
        SOURCE_TYPE="rotating (#$INDEX)"
    else
        echo "✗ Rotating backup .last-success.$INDEX not found." >&2
        exit 1
    fi
else
    # auto-select: prefer indices 1..3 (skip .0 which is the current config)
    for idx in 1 2 3; do
        if [[ -n "${rotating_map[$idx]:-}" ]]; then
            SELECTED="${rotating_map[$idx]}"
            SOURCE_TYPE="rotating (#$idx)"
            break
        fi
    done
fi

if [[ -z "$SELECTED" ]]; then
    # fallback to permanent backups
    permanent_backups=( $(list_permanent_backups) )
    if [[ ${#permanent_backups[@]} -gt 0 ]]; then
        SELECTED="${permanent_backups[0]}"
        SOURCE_TYPE="permanent"
    fi
fi

if [[ -z "$SELECTED" ]]; then
    echo "✗ No kubelet backup found (rotating or permanent)." >&2
    exit 1
fi

echo "=== Kubelet configuration rollback ==="
echo "Selected backup : $SELECTED ($SOURCE_TYPE)"
echo "Target config   : $CONFIG_PATH"
echo ""

if $DRY_RUN; then
    echo "Dry-run mode enabled, no changes applied."
    exit 0
fi

cp "$SELECTED" "$CONFIG_PATH"
echo "✓ Restored configuration from $SELECTED"

if $RESTART; then
    systemctl restart kubelet
    systemctl status kubelet --no-pager --lines=10 || true
else
    echo "ℹ️  Kubelet restart skipped (--no-restart). Please restart manually if required."
fi

echo "✅ Rollback finished."
