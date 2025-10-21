#!/bin/bash
################################################################################
# Script de configuration automatique des réservations kubelet
# Version: 2.0.2
# Compatible Kubernetes v1.32+, cgroups v1/v2, systemd
#
# Améliorations v2.0.2:
#   - Conservation intelligente des backups (.last-success)
#   - Auto-nettoyage des anciens backups timestampés (>30j)
#
# Améliorations v2.0.0:
#   - Validation complète des entrées
#   - Détection RAM améliorée (précision MiB)
#   - Seuils d'éviction dynamiques selon la taille du nœud
#   - Vérification et création automatique des cgroups
#   - Rollback automatique en cas d'échec
#   - Validation YAML avant application
#   - Backup automatique de sécurité
#
# Usage:
#   ./kubelet_auto_config.sh [OPTIONS]
#
# Options:
#   --profile <gke|eks|conservative|minimal>  Profil de calcul (défaut: gke)
#   --density-factor <float>                   Facteur multiplicateur 0.1-5.0 (défaut: 1.0, recommandé: 0.5-3.0)
#   --target-pods <int>                        Nombre de pods cible (calcul auto du facteur)
#   --dry-run                                  Affiche la config sans appliquer
#   --backup                                   Conserve le backup (par défaut supprimé si succès)
#   --help                                     Affiche l'aide
#
# Exemples:
#   ./kubelet_auto_config.sh
#   ./kubelet_auto_config.sh --profile conservative --density-factor 1.5
#   ./kubelet_auto_config.sh --target-pods 110 --profile conservative
#   ./kubelet_auto_config.sh --dry-run
#
# Dépendances: bc, jq, systemctl, yq
################################################################################

set -euo pipefail

# Version
VERSION="2.0.2"

# Couleurs pour l'output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Variables globales
PROFILE="gke"
DENSITY_FACTOR=1.0
TARGET_PODS=""
DRY_RUN=false
BACKUP=false
KUBELET_CONFIG="/var/lib/kubelet/config.yaml"

################################################################################
# Fonctions utilitaires
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
    exit 1
}

usage() {
    head -n 25 "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Ce script doit être exécuté en tant que root (sudo)"
    fi
}

check_dependencies() {
    local missing=()
    for cmd in bc jq systemctl yq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dépendances manquantes: ${missing[*]}. Installez-les avec: apt install bc jq systemd yq"
    fi
}

validate_positive_integer() {
    local value=$1
    local name=$2

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error "$name doit être un entier positif (reçu: $value)"
    fi

    if (( value <= 0 )); then
        log_error "$name doit être supérieur à 0 (reçu: $value)"
    fi
}

validate_density_factor() {
    local factor=$1

    if ! [[ "$factor" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        log_error "Le density-factor doit être un nombre valide (reçu: $factor)"
    fi

    if (( $(echo "$factor < 0.1" | bc -l) )); then
        log_error "Le density-factor doit être >= 0.1 (reçu: $factor)"
    fi

    if (( $(echo "$factor > 5.0" | bc -l) )); then
        log_error "Le density-factor doit être <= 5.0 (reçu: $factor)"
    fi

    if (( $(echo "$factor < 0.5 || $factor > 3.0" | bc -l) )); then
        log_warning "Le density-factor $factor est hors de la plage recommandée (0.5-3.0)"
    fi
}

validate_profile() {
    local profile=$1
    case $profile in
        gke|eks|conservative|minimal)
            return 0
            ;;
        *)
            log_error "Profil invalide: $profile. Valeurs acceptées: gke, eks, conservative, minimal"
            ;;
    esac
}

################################################################################
# Détection des ressources système
################################################################################

detect_vcpu() {
    local vcpu
    vcpu=$(nproc)

    if (( vcpu <= 0 )); then
        log_error "Impossible de détecter le nombre de vCPU"
    fi

    echo "$vcpu"
}

detect_ram_gib() {
    # Retourne la RAM totale en GiB (calculé depuis MiB pour plus de précision)
    local ram_mib
    ram_mib=$(detect_ram_mib)
    echo "scale=2; $ram_mib / 1024" | bc
}

detect_ram_mib() {
    # Retourne la RAM totale en MiB (précis)
    local ram_mib
    ram_mib=$(free -m | awk '/^Mem:/ {print $2}')

    if (( ram_mib <= 0 )); then
        log_error "Impossible de détecter la RAM système"
    fi

    echo "$ram_mib"
}

################################################################################
# Calcul du density-factor automatique
################################################################################

calculate_density_factor() {
    local target_pods=$1
    local factor

    # Validate input
    validate_positive_integer "$target_pods" "target-pods"

    if (( target_pods > 500 )); then
        log_warning "target-pods très élevé ($target_pods). Maximum recommandé: 500"
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
            excess=90  # Cap à 200 pods total
        fi
        factor=$(echo "scale=2; 1.5 + ($excess / 180.0)" | bc)
    fi

    echo "$factor"
}

################################################################################
# Formules de calcul des réservations
################################################################################

# Profil GKE (Google Kubernetes Engine)
calculate_gke() {
    local vcpu=$1
    local ram_gib=$2
    local ram_mib=$3
    
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
    if (( ram_gib < 64 )); then
        sys_mem_percent=$(echo "scale=0; $ram_mib * 0.01" | bc)
    else
        sys_mem_percent=$(echo "scale=0; $ram_mib * 0.005" | bc)
    fi
    local sys_mem_kernel=$((ram_gib * 11))
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
    if (( ram_gib <= 64 )); then
        kube_mem_dynamic=$((ram_gib * 11))
    else
        kube_mem_dynamic=$((64 * 11 + (ram_gib - 64) * 8))
    fi
    local kube_mem=$((kube_mem_base + kube_mem_dynamic))
    
    echo "$sys_cpu $sys_mem $kube_cpu $kube_mem"
}

# Profil EKS (Amazon Elastic Kubernetes Service)
calculate_eks() {
    local vcpu=$1
    local ram_gib=$2
    local ram_mib=$3
    
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
    local sys_mem=$(echo "scale=0; 100 + ($ram_mib * $sys_mem_percent)" | bc)
    
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
    local kube_mem=$((255 + ram_gib * 11))
    
    echo "$sys_cpu $sys_mem $kube_cpu $kube_mem"
}

# Profil Conservative (Red Hat OpenShift-like)
calculate_conservative() {
    local vcpu=$1
    local ram_gib=$2
    local ram_mib=$3
    
    # system-reserved CPU
    local sys_cpu=$(echo "scale=0; 500 + ($vcpu * 1000 * 0.01)" | bc)
    
    # system-reserved Memory
    local sys_mem=$(echo "scale=0; 1024 + ($ram_mib * 0.02)" | bc)
    
    # kube-reserved CPU
    local kube_cpu=$(echo "scale=0; 500 + ($vcpu * 1000 * 0.015)" | bc)
    
    # kube-reserved Memory
    local kube_mem=$(echo "scale=0; 1024 + ($ram_mib * 0.05)" | bc)
    
    echo "$sys_cpu $sys_mem $kube_cpu $kube_mem"
}

# Profil Minimal
calculate_minimal() {
    local vcpu=$1
    local ram_gib=$2
    local ram_mib=$3
    
    # system-reserved CPU
    local sys_cpu
    if (( vcpu < 8 )); then
        sys_cpu=100
    else
        sys_cpu=150
    fi
    
    # system-reserved Memory
    local sys_mem=$((256 + ram_gib * 8))
    
    # kube-reserved CPU
    local kube_cpu=$((60 + vcpu * 5))
    
    # kube-reserved Memory
    local kube_mem=$((256 + ram_gib * 8))
    
    echo "$sys_cpu $sys_mem $kube_cpu $kube_mem"
}

################################################################################
# Application du density-factor
################################################################################

apply_density_factor() {
    local sys_cpu=$1
    local sys_mem=$2
    local kube_cpu=$3
    local kube_mem=$4
    local factor=$5
    
    sys_cpu=$(echo "scale=0; $sys_cpu * $factor" | bc | cut -d. -f1)
    sys_mem=$(echo "scale=0; $sys_mem * $factor" | bc | cut -d. -f1)
    kube_cpu=$(echo "scale=0; $kube_cpu * $factor" | bc | cut -d. -f1)
    kube_mem=$(echo "scale=0; $kube_mem * $factor" | bc | cut -d. -f1)
    
    echo "$sys_cpu $sys_mem $kube_cpu $kube_mem"
}

################################################################################
# Vérification et création des cgroups
################################################################################

ensure_cgroups() {
    log_info "Vérification des cgroups requis..."

    # Détecter la version de cgroup
    local cgroup_version
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        cgroup_version="v2"
        log_info "Système cgroup v2 détecté"
    else
        cgroup_version="v1"
        log_info "Système cgroup v1 détecté"
    fi

    # Pour cgroup v2
    if [[ "$cgroup_version" == "v2" ]]; then
        # Vérifier system.slice
        if [[ ! -d /sys/fs/cgroup/system.slice ]]; then
            log_warning "Cgroup /system.slice n'existe pas, il sera créé par systemd"
        else
            log_success "Cgroup /system.slice existe"
        fi

        # Vérifier kubelet.slice
        if [[ ! -d /sys/fs/cgroup/kubelet.slice ]]; then
            log_info "Création du cgroup /kubelet.slice..."
            if systemctl cat kubelet.slice &>/dev/null; then
                log_success "kubelet.slice déjà configuré dans systemd"
            else
                log_warning "kubelet.slice n'existe pas. Création d'une unit systemd..."
                cat > /etc/systemd/system/kubelet.slice <<'EOF'
[Unit]
Description=Kubelet Slice
Before=slices.target

[Slice]
CPUAccounting=yes
MemoryAccounting=yes
EOF
                systemctl daemon-reload
                systemctl start kubelet.slice
                log_success "kubelet.slice créé et démarré"
            fi
        else
            log_success "Cgroup /kubelet.slice existe"
        fi
    else
        # Pour cgroup v1
        log_warning "Cgroup v1 détecté. Assurez-vous que les cgroups sont configurés manuellement si nécessaire."
    fi
}

################################################################################
# Calcul des seuils d'éviction dynamiques
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
# Génération de la configuration kubelet
################################################################################

generate_kubelet_config() {
    local sys_cpu=$1
    local sys_mem=$2
    local kube_cpu=$3
    local kube_mem=$4
    local vcpu=$5
    local ram_gib=$6
    local ram_mib=$7

    # Calcul des seuils d'éviction
    read -r eviction_hard_mem eviction_soft_mem <<< $(calculate_eviction_thresholds "$ram_gib" "$ram_mib")

    cat <<EOF
# Configuration générée automatiquement le $(date)
# Profil: $PROFILE | Density-factor: $DENSITY_FACTOR
# Nœud: ${vcpu} vCPU / ${ram_gib} GiB RAM

apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

# ============================================================
# RÉSERVATIONS SYSTÈME ET KUBERNETES
# ============================================================
systemReserved:
  cpu: "${sys_cpu}m"
  memory: "${sys_mem}Mi"
  ephemeral-storage: "10Gi"

kubeReserved:
  cpu: "${kube_cpu}m"
  memory: "${kube_mem}Mi"
  ephemeral-storage: "5Gi"

# ============================================================
# ENFORCEMENT DES RÉSERVATIONS
# ============================================================
enforceNodeAllocatable:
  - "pods"
  - "system-reserved"
  - "kube-reserved"

cgroupDriver: "systemd"
cgroupRoot: "/"

systemReservedCgroup: "/system.slice"
kubeReservedCgroup: "/kubelet.slice"

# ============================================================
# SEUILS D'ÉVICTION (dynamiques selon la taille du nœud)
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

################################################################################
# Validation YAML
################################################################################

validate_yaml() {
    local config_file=$1

    log_info "Validation de la configuration YAML..."

    if ! yq eval '.' "$config_file" > /dev/null 2>&1; then
        log_error "La configuration générée n'est pas un YAML valide"
    fi

    # Vérifications supplémentaires
    local api_version
    api_version=$(yq eval '.apiVersion' "$config_file" 2>/dev/null)
    if [[ "$api_version" != "kubelet.config.k8s.io/v1beta1" ]]; then
        log_error "apiVersion invalide dans la configuration: $api_version"
    fi

    local kind
    kind=$(yq eval '.kind' "$config_file" 2>/dev/null)
    if [[ "$kind" != "KubeletConfiguration" ]]; then
        log_error "kind invalide dans la configuration: $kind"
    fi

    log_success "Configuration YAML validée"
}

################################################################################
# Affichage du résumé
################################################################################

display_summary() {
    local vcpu=$1
    local ram_gib=$2
    local sys_cpu=$3
    local sys_mem=$4
    local kube_cpu=$5
    local kube_mem=$6

    local total_cpu=$((sys_cpu + kube_cpu))
    local total_mem=$((sys_mem + kube_mem))
    local alloc_cpu=$((vcpu * 1000 - total_cpu))
    local alloc_mem=$(echo "scale=2; ($ram_gib * 1024 - $total_mem) / 1024" | bc)
    local cpu_percent=$(echo "scale=2; ($total_cpu / ($vcpu * 1000)) * 100" | bc)
    local mem_percent=$(echo "scale=2; ($total_mem / ($ram_gib * 1024)) * 100" | bc)
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  CONFIGURATION KUBELET - RÉSERVATIONS CALCULÉES"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Configuration nœud:"
    echo "  vCPU:              $vcpu"
    echo "  RAM:               $ram_gib GiB"
    echo "  Profil:            $PROFILE"
    echo "  Density-factor:    $DENSITY_FACTOR"
    echo ""
    echo "───────────────────────────────────────────────────────────────────────────"
    echo "Réservations:"
    echo "───────────────────────────────────────────────────────────────────────────"
    echo ""
    echo "  system-reserved:"
    echo "    CPU:             ${sys_cpu}m"
    echo "    Mémoire:         ${sys_mem} MiB ($(echo "scale=2; $sys_mem / 1024" | bc) GiB)"
    echo ""
    echo "  kube-reserved:"
    echo "    CPU:             ${kube_cpu}m"
    echo "    Mémoire:         ${kube_mem} MiB ($(echo "scale=2; $kube_mem / 1024" | bc) GiB)"
    echo ""
    echo "───────────────────────────────────────────────────────────────────────────"
    echo "Totaux:"
    echo "───────────────────────────────────────────────────────────────────────────"
    echo ""
    echo "  CPU réservé:       ${total_cpu}m (${cpu_percent}%)"
    echo "  Mémoire réservée:  ${total_mem} MiB (${mem_percent}%)"
    echo ""
    echo "───────────────────────────────────────────────────────────────────────────"
    echo "Allocatable (capacité disponible pour les pods):"
    echo "───────────────────────────────────────────────────────────────────────────"
    echo ""
    echo "  CPU:               ${alloc_cpu}m (sur $((vcpu * 1000))m)"
    echo "  Mémoire:           ${alloc_mem} GiB (sur ${ram_gib} GiB)"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
}

################################################################################
# Fonction principale
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
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --backup)
                BACKUP=true
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

    # Vérifications système
    check_root
    check_dependencies

    # Validation des entrées
    validate_profile "$PROFILE"
    validate_density_factor "$DENSITY_FACTOR"

    # Détection des ressources
    log_info "Détection des ressources système..."
    VCPU=$(detect_vcpu)
    RAM_MIB=$(detect_ram_mib)
    RAM_GIB=$(detect_ram_gib)

    log_success "Détecté: ${VCPU} vCPU, ${RAM_GIB} GiB RAM (${RAM_MIB} MiB)"

    # Calcul automatique du density-factor si target-pods spécifié
    if [[ -n "$TARGET_PODS" ]]; then
        log_info "Calcul automatique du density-factor pour $TARGET_PODS pods cible..."
        DENSITY_FACTOR=$(calculate_density_factor "$TARGET_PODS")
        log_success "Density-factor calculé: $DENSITY_FACTOR"
    fi

    # Calcul des réservations selon le profil
    log_info "Calcul des réservations avec profil '$PROFILE'..."

    # Note: RAM_GIB peut être une décimale maintenant, on doit l'arrondir pour les calculs
    RAM_GIB_INT=$(echo "$RAM_GIB" | cut -d. -f1)

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

    # Application du density-factor
    if [[ $(echo "$DENSITY_FACTOR != 1.0" | bc -l) -eq 1 ]]; then
        log_info "Application du density-factor ${DENSITY_FACTOR}..."
        read -r SYS_CPU SYS_MEM KUBE_CPU KUBE_MEM <<< $(apply_density_factor "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM" "$DENSITY_FACTOR")
    fi

    # Affichage du résumé
    display_summary "$VCPU" "$RAM_GIB" "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM"

    # Mode dry-run : afficher la config sans appliquer
    if [[ "$DRY_RUN" == true ]]; then
        log_warning "Mode DRY-RUN activé - Configuration non appliquée"
        echo ""
        echo "Configuration qui serait générée:"
        echo "───────────────────────────────────────────────────────────────────────────"
        generate_kubelet_config "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM" "$VCPU" "$RAM_GIB" "$RAM_MIB"
        echo ""
        log_info "Pour appliquer réellement, relancez sans --dry-run"
        exit 0
    fi

    # Vérification et création des cgroups
    ensure_cgroups

    # Backup automatique de la configuration existante (toujours faire un backup en production)
    BACKUP_FILE=""
    if [[ -f "$KUBELET_CONFIG" ]]; then
        BACKUP_FILE="${KUBELET_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Sauvegarde automatique de la configuration existante..."
        cp "$KUBELET_CONFIG" "$BACKUP_FILE"
        log_success "Sauvegarde créée: $BACKUP_FILE"
    fi

    # Génération de la nouvelle configuration dans un fichier temporaire
    local temp_config
    temp_config=$(mktemp /tmp/kubelet-config.XXXXXX.yaml)

    log_info "Génération de la nouvelle configuration kubelet..."
    generate_kubelet_config "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM" "$VCPU" "$RAM_GIB" "$RAM_MIB" > "$temp_config"

    # Validation YAML
    validate_yaml "$temp_config"

    # Application de la configuration
    log_info "Application de la nouvelle configuration..."
    cp "$temp_config" "$KUBELET_CONFIG"
    rm -f "$temp_config"
    log_success "Configuration écrite dans $KUBELET_CONFIG"

    # Redémarrage du kubelet avec rollback en cas d'échec
    log_info "Redémarrage du kubelet..."
    if ! systemctl restart kubelet; then
        log_error "Échec du redémarrage du kubelet!"

        # Tentative de rollback
        if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
            log_warning "Tentative de restauration de la configuration précédente..."
            cp "$BACKUP_FILE" "$KUBELET_CONFIG"

            if systemctl restart kubelet; then
                log_warning "Configuration restaurée, kubelet redémarré avec l'ancienne config"
                log_error "La nouvelle configuration a causé un problème. Vérifiez les logs: journalctl -u kubelet -n 100"
            else
                log_error "Échec de la restauration! Vérifiez manuellement: journalctl -u kubelet -f"
            fi
        else
            log_error "Pas de backup disponible pour restauration. Vérifiez les logs: journalctl -u kubelet -f"
        fi

        exit 1
    fi

    log_success "Kubelet redémarré avec succès"

    # Vérification de la stabilité
    log_info "Vérification de la stabilité du kubelet (15s)..."
    sleep 15

    if systemctl is-active --quiet kubelet; then
        log_success "✓ Kubelet actif et opérationnel"

        # Gestion intelligente du backup
        if [[ "$BACKUP" != true ]] && [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
            # Conserver comme .last-success au lieu de supprimer
            LAST_SUCCESS_BACKUP="/var/lib/kubelet/config.yaml.last-success"
            mv "$BACKUP_FILE" "$LAST_SUCCESS_BACKUP"

            log_info "Backup de sécurité conservé : $LAST_SUCCESS_BACKUP"
            log_info "  → Permet un rollback manuel si nécessaire"
            log_info "  → Utilisez --backup pour conserver des backups timestampés multiples"

            # Nettoyage automatique des anciens backups timestampés (>30 jours)
            local old_count=$(find /var/lib/kubelet -name 'config.yaml.backup.2*' -mtime +30 2>/dev/null | wc -l)
            if (( old_count > 0 )); then
                find /var/lib/kubelet -name 'config.yaml.backup.2*' -mtime +30 -delete 2>/dev/null
                log_info "Nettoyé $old_count ancien(s) backup(s) timestampé(s) > 30 jours"
            fi
        elif [[ "$BACKUP" == true ]] && [[ -n "$BACKUP_FILE" ]]; then
            log_success "Backup timestampé conservé : $BACKUP_FILE"
        fi
    else
        log_error "✗ Kubelet non actif après redémarrage!"

        # Rollback automatique
        if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
            log_warning "Rollback automatique en cours..."
            cp "$BACKUP_FILE" "$KUBELET_CONFIG"
            systemctl restart kubelet
            log_error "Configuration restaurée. Analysez les logs: journalctl -u kubelet -n 100"
        fi

        exit 1
    fi

    echo ""
    log_success "Configuration terminée avec succès!"
    echo ""
    echo "Prochaines étapes:"
    echo "  1. Vérifier les logs kubelet:    journalctl -u kubelet -f"
    echo "  2. Vérifier l'allocatable:       kubectl describe node \$(hostname)"
    echo "  3. Vérifier les cgroups:         systemd-cgls | grep -E 'system.slice|kubepods'"
    if [[ "$BACKUP" == true ]] && [[ -n "$BACKUP_FILE" ]]; then
        echo "  4. Backup conservé:              $BACKUP_FILE"
    fi
    echo ""
}

# Exécution
main "$@"