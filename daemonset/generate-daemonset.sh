#!/bin/bash
################################################################################
# Script de déploiement du DaemonSet kubelet-config
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCRIPT_PATH="$PROJECT_ROOT/kubelet_auto_config.sh"
DAEMONSET_PATH="$SCRIPT_DIR/kubelet-config-daemonset-only.yaml"

echo "=== Déploiement du DaemonSet kubelet-config ==="
echo ""

# Vérifier que le script source existe
if [[ ! -f "$SCRIPT_PATH" ]]; then
    echo "ERREUR: Script source non trouvé: $SCRIPT_PATH"
    exit 1
fi

# Créer le ConfigMap depuis le fichier
echo "1. Création du ConfigMap avec le script..."
kubectl create configmap kubelet-config-script \
  --from-file=kubelet_auto_config.sh="$SCRIPT_PATH" \
  --namespace=kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "2. Déploiement du DaemonSet..."
kubectl apply -f "$DAEMONSET_PATH"

echo ""
echo "✓ DaemonSet déployé"
echo ""
echo "Pour surveiller les logs:"
echo "  kubectl logs -n kube-system -l app=kubelet-config-updater -f"
echo ""
echo "Pour vérifier les pods:"
echo "  kubectl get pods -n kube-system -l app=kubelet-config-updater"
echo ""
echo "Pour nettoyer:"
echo "  kubectl delete daemonset -n kube-system kubelet-config-updater"
echo "  kubectl delete configmap -n kube-system kubelet-config-script"
