#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <control-plane|worker>" >&2
    exit 1
fi

PROFILE="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_TEMPLATE="${SCRIPT_DIR}/kubelet-auto-config@.service"
PROFILE_ENV="${SCRIPT_DIR}/kubelet-auto-config@${PROFILE}.env"

if [[ ! -f "$PROFILE_ENV" ]]; then
    echo "Unknown profile template: ${PROFILE_ENV}" >&2
    exit 1
fi

SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="kubelet-auto-config@${PROFILE}.service"
SERVICE_PATH="${SYSTEMD_DIR}/kubelet-auto-config@.service"
DROPIN_DIR="${SYSTEMD_DIR}/${SERVICE_NAME}.d"
DROPIN_FILE="${DROPIN_DIR}/10-env.conf"
ENV_TARGET_DIR="/etc/kubelet-auto-config"
ENV_TARGET="${ENV_TARGET_DIR}/kubelet-auto-config@${PROFILE}.env"

install -Dm0644 "$SERVICE_TEMPLATE" "$SERVICE_PATH"
install -Dm0644 "$PROFILE_ENV" "$ENV_TARGET"
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_FILE" <<EOF
[Service]
EnvironmentFile=$ENV_TARGET
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
