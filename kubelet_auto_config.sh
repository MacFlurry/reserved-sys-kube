#!/bin/bash
################################################################################
# Script de configuration automatique des réservations kubelet
# Version: 2.0.13
# Compatible: Kubernetes v1.32+, cgroups v1/v2, systemd, Ubuntu
#
# Voir CHANGELOG_v2.0.8.md pour l'historique des versions précédentes
#
# Usage:
#   ./kubelet_auto_config.sh [OPTIONS]
#
# Options:
#   --profile <gke|eks|conservative|minimal>  Profil de calcul (défaut: gke)
#   --density-factor <float>                   Facteur multiplicateur 0.1-5.0 (défaut: 1.0, recommandé: 0.5-3.0)
#   --target-pods <int>                        Nombre de pods cible (calcul auto du facteur)
#   --node-type <control-plane|worker|auto>    Type de nœud (défaut: auto - détection automatique)
#   --dry-run                                  Affiche la config sans appliquer
#   --backup                                   Conserve le backup (par défaut supprimé si succès)
#   --help                                     Affiche l'aide
#
# Exemples:
#   ./kubelet_auto_config.sh
#   ./kubelet_auto_config.sh --profile conservative --density-factor 1.5
#   ./kubelet_auto_config.sh --target-pods 110 --profile conservative
#   ./kubelet_auto_config.sh --node-type control-plane  # Forcer le mode control-plane
#   ./kubelet_auto_config.sh --dry-run
#
# Dépendances: bc, jq, systemctl, yq
################################################################################

set -euo pipefail

# Version
VERSION="2.0.13"

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
NODE_TYPE="auto"
NODE_TYPE_DETECTED=""
DRY_RUN=false
BACKUP=false
KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
LOCK_FILE="/var/lock/kubelet-auto-config.lock"

# Seuils et garde-fous
MIN_ALLOC_CPU_PERCENT=25         # Pourcentage minimum de CPU allocatable autorisé
MIN_ALLOC_MEM_PERCENT=20         # Pourcentage minimum de mémoire allocatable autorisé
CONTROL_PLANE_MAX_DENSITY=1.0    # Density-factor maximum autorisé sur un control-plane

# Fonction de nettoyage pour le trap
cleanup() {
    if [[ -n "${LOCK_FILE:-}" ]] && [[ -d "$LOCK_FILE" ]]; then
        rm -rf "$LOCK_FILE" 2>/dev/null || true
    fi
}

# Enregistrer le trap dès le début
trap cleanup EXIT

################################################################################
# Fonctions utilitaires
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
        echo ""
        return
    fi

    if [[ "$value" =~ m$ ]]; then
        echo "${value%m}"
        return
    fi

    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        # Convert cores to milli-cores (arrondi à l'entier le plus proche)
        printf "%.0f" "$(echo "$value * 1000" | bc -l)"
        return
    fi

    echo ""
}

normalize_memory_to_mib() {
    local value=$1

    if [[ -z "$value" ]]; then
        echo ""
        return
    fi

    if [[ "$value" =~ Ki$ ]]; then
        local ki=${value%Ki}
        if [[ "$ki" =~ ^[0-9]+$ ]]; then
            echo $(( (ki + 512) / 1024 ))
            return
        fi
    elif [[ "$value" =~ Mi$ ]]; then
        local mi=${value%Mi}
        if [[ "$mi" =~ ^[0-9]+$ ]]; then
            echo "$mi"
            return
        fi
    elif [[ "$value" =~ Gi$ ]]; then
        local gi=${value%Gi}
        if [[ "$gi" =~ ^[0-9]+$ ]]; then
            echo $(( gi * 1024 ))
            return
        fi
    fi

    echo ""
}

get_current_allocatable_snapshot() {
    if ! command -v kubectl >/dev/null 2>&1; then
        echo ""
        return
    fi

    local kubeconfig=""
    if [[ -f /etc/kubernetes/kubelet.conf ]]; then
        kubeconfig="--kubeconfig=/etc/kubernetes/kubelet.conf"
    fi

    local node_name
    node_name=$(hostname)

    local raw
    if ! raw=$(kubectl $kubeconfig get node "$node_name" -o jsonpath='{.status.allocatable.cpu},{.status.allocatable.memory}' 2>/dev/null); then
        echo ""
        return
    fi

    local cpu_value=${raw%%,*}
    local mem_value=${raw##*,}
    local cpu_milli
    cpu_milli=$(normalize_cpu_to_milli "$cpu_value")
    local mem_mib
    mem_mib=$(normalize_memory_to_mib "$mem_value")

    if [[ -z "$cpu_milli" ]] || [[ -z "$mem_mib" ]]; then
        echo ""
        return
    fi

    echo "${cpu_milli}:${mem_mib}"
}

usage() {
    # Afficher uniquement la section Usage jusqu'à Dépendances
    sed -n '/^# Usage:/,/^# Dépendances:/p' "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Ce script doit être exécuté en tant que root (sudo)"
    fi
}

check_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID}" != "ubuntu" ]]; then
            log_error "Système non supporté détecté (${PRETTY_NAME:-$ID}). Ce script est compatible uniquement avec Ubuntu."
        fi
    else
        log_error "Impossible de détecter la distribution (fichier /etc/os-release introuvable). Ce script supporte uniquement Ubuntu."
    fi
}

acquire_lock() {
    local timeout=30
    local elapsed=0

    # Nettoyage préventif si le lock est un dossier orphelin
    if [[ -d "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")

        # Vérifier si le processus existe encore
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            log_warning "Lock file orphelin détecté (PID $lock_pid mort), nettoyage..."
            rm -rf "$LOCK_FILE"
        fi
    fi

    while ! mkdir "$LOCK_FILE" 2>/dev/null; do
        if (( elapsed >= timeout )); then
            log_error "Un autre processus exécute déjà ce script (timeout après ${timeout}s)"
        fi
        log_warning "Script déjà en cours d'exécution... Attente ($elapsed/$timeout s)"
        sleep 2
        ((elapsed += 2))
    done

    echo $$ > "$LOCK_FILE/pid"
    log_info "Lock acquis (PID $$)"
}

install_dependencies() {
    local missing_apt=()
    local need_yq=false

    # Vérifier bc et jq
    for cmd in bc jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_apt+=("$cmd")
        fi
    done

    # Vérifier yq (et sa version)
    if ! command -v yq &> /dev/null; then
        need_yq=true
    else
        # Vérifier que c'est la bonne version (mikefarah v4+, pas Python v3)
        if ! yq --version 2>&1 | grep -q "mikefarah"; then
            log_warning "yq installé mais version incorrecte (Python v3 détectée)"
            log_info "Remplacement par yq v4 (mikefarah)..."
            need_yq=true
        fi
    fi

    # Rien à faire si tout est OK
    if [[ ${#missing_apt[@]} -eq 0 ]] && [[ "$need_yq" == "false" ]]; then
        return 0
    fi

    # Installation automatique
    log_info "Installation automatique des dépendances manquantes..."

    # Installer bc et jq via apt
    if [[ ${#missing_apt[@]} -gt 0 ]]; then
        log_info "Installation de ${missing_apt[*]} via apt..."
        apt-get update -qq >/dev/null 2>&1 || log_error "apt update échoué"
        apt-get install -y -qq "${missing_apt[@]}" >/dev/null 2>&1 || log_error "Installation ${missing_apt[*]} échouée"
        log_success "${missing_apt[*]} installé(s)"
    fi

    # Installer yq v4
    if [[ "$need_yq" == "true" ]]; then
        log_info "Installation de yq v4 depuis GitHub..."

        # Détecter l'architecture
        local arch
        arch=$(uname -m)
        local yq_binary
        case "$arch" in
            x86_64|amd64)   yq_binary="yq_linux_amd64" ;;
            arm64|aarch64)  yq_binary="yq_linux_arm64" ;;
            *) log_error "Architecture non supportée pour yq: $arch" ;;
        esac

        # Télécharger yq v4
        local yq_version="v4.44.3"
        local yq_url="https://github.com/mikefarah/yq/releases/download/${yq_version}/${yq_binary}"

        wget -qO /tmp/yq "$yq_url" >/dev/null 2>&1 || log_error "Téléchargement yq échoué depuis $yq_url"
        chmod +x /tmp/yq
        mv /tmp/yq /usr/local/bin/yq || log_error "Installation yq échouée"

        log_success "yq $yq_version installé"
    fi
}

check_dependencies() {
    # Installer automatiquement les dépendances manquantes
    install_dependencies

    # Vérifier que tout est bien installé
    local missing=()
    for cmd in bc jq systemctl yq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dépendances manquantes après installation: ${missing[*]}"
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

validate_calculated_value() {
    local value=$1
    local name=$2
    local min=${3:-0}

    # Vérifier que la valeur n'est pas vide
    if [[ -z "$value" ]]; then
        log_error "Calcul invalide pour $name: valeur vide"
    fi

    # Vérifier que c'est un nombre entier valide
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error "Calcul invalide pour $name: '$value' n'est pas un entier valide"
    fi

    # Vérifier le minimum
    if (( value < min )); then
        log_error "Calcul invalide pour $name: $value < $min (minimum requis)"
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

validate_node_type() {
    local node_type=$1
    case $node_type in
        control-plane|worker|auto)
            return 0
            ;;
        *)
            log_error "Type de nœud invalide: $node_type. Valeurs acceptées: control-plane, worker, auto"
            ;;
    esac
}

################################################################################
# Détection du type de nœud (control-plane vs worker)
################################################################################

detect_node_type() {
    log_info "Détection du type de nœud..."

    # Vérifier la présence de static pods control-plane dans /etc/kubernetes/manifests
    local manifests_dir="/etc/kubernetes/manifests"
    local is_control_plane=false

    if [[ -d "$manifests_dir" ]]; then
        # Vérifier la présence des manifestes des composants control-plane
        if [[ -f "$manifests_dir/kube-apiserver.yaml" ]] || \
           [[ -f "$manifests_dir/kube-controller-manager.yaml" ]] || \
           [[ -f "$manifests_dir/kube-scheduler.yaml" ]] || \
           [[ -f "$manifests_dir/etcd.yaml" ]]; then
            is_control_plane=true
        fi
    fi

    if [[ "$is_control_plane" == true ]]; then
        NODE_TYPE_DETECTED="control-plane"
        log_success "Nœud détecté: CONTROL-PLANE (static pods détectés dans $manifests_dir)"
        log_warning "Mode control-plane: kube-reserved ne sera PAS enforced (pour préserver les static pods critiques)"
    else
        NODE_TYPE_DETECTED="worker"
        log_success "Nœud détecté: WORKER (aucun static pod control-plane trouvé)"
        log_info "Mode worker: kube-reserved sera enforced normalement"
    fi

    echo "$NODE_TYPE_DETECTED"
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

detect_ephemeral_capacity_mib() {
    local path="/var/lib/kubelet"

    if [[ ! -d "$path" ]]; then
        path="/"
    fi

    local df_output
    if ! df_output=$(df -BM "$path" 2>/dev/null); then
        log_warning "Impossible de détecter la capacité de stockage éphémère (df échoue sur $path)"
        echo "0"
        return
    fi

    local size_mb
    size_mb=$(awk 'NR==2 {print $2}' <<< "$df_output" | tr -d 'M')

    if [[ -z "$size_mb" ]]; then
        log_warning "Capacité de stockage éphémère introuvable (df vide sur $path)"
        echo "0"
        return
    fi

    if ! [[ "$size_mb" =~ ^[0-9]+$ ]]; then
        log_warning "Valeur de capacité éphémère invalide: $size_mb"
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
        log_warning "Capacité de stockage éphémère introuvable, utilisation des valeurs par défaut (10Gi / 5Gi)"
    fi

    echo "$system_mib $kube_mib"
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

    # Normaliser ram_gib en entier pour calculs arithmétiques bash
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

    # Normaliser ram_gib en entier pour calculs arithmétiques bash
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

    # Normaliser ram_gib en entier pour calculs arithmétiques bash
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
# Application du density-factor
################################################################################

apply_density_factor() {
    local sys_cpu=$1
    local sys_mem=$2
    local kube_cpu=$3
    local kube_mem=$4
    local factor=$5

    # Appliquer le facteur et forcer la conversion en entier (sans décimales)
    sys_cpu=$(printf "%.0f" "$(echo "$sys_cpu * $factor" | bc)")
    sys_mem=$(printf "%.0f" "$(echo "$sys_mem * $factor" | bc)")
    kube_cpu=$(printf "%.0f" "$(echo "$kube_cpu * $factor" | bc)")
    kube_mem=$(printf "%.0f" "$(echo "$kube_mem * $factor" | bc)")

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
                log_success "kubelet.slice créé (systemd montera la slice à la demande)"
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
# Attachement du service kubelet à kubelet.slice
################################################################################

ensure_kubelet_slice_attachment() {
    log_info "Vérification de l'attachement du service kubelet à kubelet.slice..."

    # Vérifier si kubelet.service existe
    if ! systemctl cat kubelet.service &>/dev/null; then
        log_warning "Le service kubelet.service n'existe pas encore sur ce système"
        log_warning "L'attachement à kubelet.slice devra être configuré manuellement après installation de kubelet"
        return 0
    fi

    # Vérifier l'attachement actuel du service kubelet
    local current_slice
    current_slice=$(systemctl show kubelet.service -p Slice --value 2>/dev/null)

    if [[ "$current_slice" == "kubelet.slice" ]]; then
        log_success "Service kubelet déjà attaché à kubelet.slice"
        return 0
    fi

    # Le kubelet n'est pas dans la bonne slice
    log_warning "Service kubelet actuellement dans : ${current_slice:-system.slice}"
    log_info "Configuration de l'attachement à kubelet.slice..."

    # Créer le répertoire drop-in si nécessaire
    local dropin_dir="/etc/systemd/system/kubelet.service.d"
    mkdir -p "$dropin_dir"

    # Créer le drop-in pour attacher kubelet à kubelet.slice
    local dropin_file="${dropin_dir}/11-kubelet-slice.conf"

    cat > "$dropin_file" <<'EOF'
# Configuration automatique des réservations kubelet
# Attache le service kubelet à kubelet.slice pour l'enforcement de kube-reserved
# Généré automatiquement par kubelet_auto_config.sh

[Unit]
# S'assurer que la slice existe avant de démarrer kubelet
After=kubelet.slice
Requires=kubelet.slice

[Service]
# Placer kubelet dans kubelet.slice au lieu de system.slice
Slice=kubelet.slice
EOF

    log_success "Drop-in systemd créé : $dropin_file"

    # Recharger la configuration systemd
    log_info "Rechargement de la configuration systemd..."
    systemctl daemon-reload

    # Vérifier que le changement est pris en compte
    local new_slice
    new_slice=$(systemctl show kubelet.service -p Slice --value 2>/dev/null)

    if [[ "$new_slice" == "kubelet.slice" ]]; then
        log_success "Service kubelet configuré pour s'attacher à kubelet.slice"
        log_info "  → Le changement prendra effet au prochain redémarrage du kubelet"
    else
        log_error "Échec de la configuration de l'attachement (slice détectée: $new_slice)"
    fi
}

################################################################################
# Validation de l'attachement effectif du kubelet
################################################################################

validate_kubelet_slice_attachment() {
    log_info "Validation de l'attachement effectif du kubelet à kubelet.slice..."

    # Attendre un peu que le kubelet démarre complètement
    sleep 3

    # Vérifier le slice effectif via systemctl
    local effective_slice
    effective_slice=$(systemctl show kubelet.service -p Slice --value 2>/dev/null)

    if [[ "$effective_slice" == "kubelet.slice" ]]; then
        log_success "✓ Service kubelet correctement attaché à kubelet.slice"
    else
        log_error $'✗ Service kubelet PAS dans kubelet.slice (détecté: '"${effective_slice:-N/A}"$')\n  → kube-reserved ne sera PAS appliqué au kubelet lui-même!\n  → Vérifiez : systemctl status kubelet | grep Cgroup'
    fi

    # Vérifier via le cgroup réel du processus kubelet
    local kubelet_pid
    kubelet_pid=$(systemctl show kubelet.service -p MainPID --value 2>/dev/null)

    if [[ -n "$kubelet_pid" ]] && [[ "$kubelet_pid" != "0" ]]; then
        local kubelet_cgroup
        kubelet_cgroup=$(cat "/proc/$kubelet_pid/cgroup" 2>/dev/null | grep -E '0::|0:/' | cut -d: -f3)

        if echo "$kubelet_cgroup" | grep -q "kubelet.slice"; then
            log_success "✓ Processus kubelet (PID $kubelet_pid) dans le bon cgroup"
            log_info "  → Cgroup: $kubelet_cgroup"
        else
            log_warning "✗ Processus kubelet dans un cgroup inattendu: $kubelet_cgroup"
        fi
    fi

    return 0
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
    log_info "Réservations éphémères calculées: system=${system_ephemeral_mib}Mi, kube=${kube_ephemeral_mib}Mi"

    # Adapter enforceNodeAllocatable selon le type de nœud
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
# Configuration générée automatiquement le $(date)
# Profil: $PROFILE | Density-factor: $DENSITY_FACTOR | Type: $node_type
# Nœud: ${vcpu} vCPU / ${ram_gib} GiB RAM

apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

# ============================================================
# RÉSERVATIONS SYSTÈME ET KUBERNETES
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
# ENFORCEMENT DES RÉSERVATIONS
# ============================================================
# Type de nœud: $node_type
# $(if [[ "$node_type" == "control-plane" ]]; then echo "kube-reserved NON enforced (préserve les static pods critiques)"; else echo "kube-reserved enforced (worker node)"; fi)
enforceNodeAllocatable:
$enforce_list

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

    # Calcul des seuils d'éviction
    read -r eviction_hard_mem eviction_soft_mem <<< $(calculate_eviction_thresholds "$ram_gib" "$ram_mib")

    local system_ephemeral_mib kube_ephemeral_mib
    read -r system_ephemeral_mib kube_ephemeral_mib <<< "$(calculate_ephemeral_reservations)"
    log_info "Réservations éphémères calculées: system=${system_ephemeral_mib}Mi, kube=${kube_ephemeral_mib}Mi"

    # Si le fichier de config kubelet existe, merger avec l'existant
    if [[ -f "$KUBELET_CONFIG" ]]; then
        log_info "Fusion avec la configuration existante (préservation des tweaks personnalisés)..."

        # Copier l'existant comme base
        cp "$KUBELET_CONFIG" "$output_file"

        # Ajouter un commentaire de traçabilité en haut du fichier
        local header_comment="# Mis à jour automatiquement le $(date) - Profil: $PROFILE | Density-factor: $DENSITY_FACTOR | Type: $node_type"
        sed -i.tmp "1i\\
$header_comment
" "$output_file"
        rm -f "${output_file}.tmp"

        # Modifier UNIQUEMENT les champs gérés par ce script avec yq
        log_info "Mise à jour des réservations système et Kubernetes..."

        # systemReserved
        yq eval -i ".systemReserved.cpu = \"${sys_cpu}m\"" "$output_file"
        yq eval -i ".systemReserved.memory = \"${sys_mem}Mi\"" "$output_file"
        yq eval -i ".systemReserved.\"ephemeral-storage\" = \"${system_ephemeral_mib}Mi\"" "$output_file"

        # kubeReserved
        yq eval -i ".kubeReserved.cpu = \"${kube_cpu}m\"" "$output_file"
        yq eval -i ".kubeReserved.memory = \"${kube_mem}Mi\"" "$output_file"
        yq eval -i ".kubeReserved.\"ephemeral-storage\" = \"${kube_ephemeral_mib}Mi\"" "$output_file"

        # enforceNodeAllocatable (adapter selon le type de nœud)
        if [[ "$node_type" == "control-plane" ]]; then
            log_warning "Mode control-plane: enforcement de kube-reserved désactivé"
            yq eval -i '.enforceNodeAllocatable = ["pods", "system-reserved"]' "$output_file"
        else
            log_info "Mode worker: enforcement complet (pods, system-reserved, kube-reserved)"
            yq eval -i '.enforceNodeAllocatable = ["pods", "system-reserved", "kube-reserved"]' "$output_file"
        fi

        # Cgroups
        yq eval -i '.cgroupDriver = "systemd"' "$output_file"
        yq eval -i '.cgroupRoot = "/"' "$output_file"
        yq eval -i '.systemReservedCgroup = "/system.slice"' "$output_file"
        yq eval -i '.kubeReservedCgroup = "/kubelet.slice"' "$output_file"

        # Seuils d'éviction
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

        log_success "Configuration fusionnée : tweaks existants préservés"

    else
        log_info "Aucune configuration existante, génération d'une configuration complète..."

        # Générer une config complète depuis zéro
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
    local node_type=$7

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
    echo "  Type:              $node_type"
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
            --node-type)
                NODE_TYPE="$2"
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
    check_os
    acquire_lock
    check_dependencies

    local pre_alloc_snapshot
    pre_alloc_snapshot=$(get_current_allocatable_snapshot || true)
    if [[ -n "$pre_alloc_snapshot" ]]; then
        local pre_cpu_m=${pre_alloc_snapshot%%:*}
        local pre_mem_mi=${pre_alloc_snapshot##*:}
        log_info "Allocatable actuel -> CPU: ${pre_cpu_m}m | Mémoire: ${pre_mem_mi}Mi"
    fi

    # Validation des entrées
    validate_profile "$PROFILE"
    validate_node_type "$NODE_TYPE"
    validate_density_factor "$DENSITY_FACTOR"

    # Détection des ressources
    log_info "Détection des ressources système..."
    VCPU=$(detect_vcpu)
    RAM_MIB=$(detect_ram_mib)
    RAM_GIB=$(detect_ram_gib)

    log_success "Détecté: ${VCPU} vCPU, ${RAM_GIB} GiB RAM (${RAM_MIB} MiB)"

    # Détection du type de nœud (control-plane vs worker)
    if [[ "$NODE_TYPE" == "auto" ]]; then
        NODE_TYPE_DETECTED=$(detect_node_type)
    else
        NODE_TYPE_DETECTED="$NODE_TYPE"
        log_info "Type de nœud forcé manuellement: $NODE_TYPE_DETECTED"
    fi

    if [[ "$NODE_TYPE_DETECTED" == "control-plane" ]]; then
        if (( $(echo "$DENSITY_FACTOR > $CONTROL_PLANE_MAX_DENSITY" | bc -l) )); then
            log_warning "Density-factor $DENSITY_FACTOR trop élevé pour un control-plane. Limite appliquée: $CONTROL_PLANE_MAX_DENSITY"
            DENSITY_FACTOR=$CONTROL_PLANE_MAX_DENSITY
        fi
    fi

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

    # Validation de RAM_GIB_INT avec fallback
    if [[ -z "$RAM_GIB_INT" ]] || [[ "$RAM_GIB_INT" == "0" ]]; then
        RAM_GIB_INT=1
        log_warning "RAM GiB invalide ou vide (valeur: '$RAM_GIB'), utilisation valeur minimale: 1 GiB"
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

    # Validation des valeurs calculées
    validate_calculated_value "$SYS_CPU" "system-reserved CPU" 50
    validate_calculated_value "$SYS_MEM" "system-reserved Memory" 100
    validate_calculated_value "$KUBE_CPU" "kube-reserved CPU" 50
    validate_calculated_value "$KUBE_MEM" "kube-reserved Memory" 100

    # Application du density-factor
    if [[ $(echo "$DENSITY_FACTOR != 1.0" | bc -l) -eq 1 ]]; then
        log_info "Application du density-factor ${DENSITY_FACTOR}..."
        read -r SYS_CPU SYS_MEM KUBE_CPU KUBE_MEM <<< $(apply_density_factor "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM" "$DENSITY_FACTOR")

        # Re-validation après application du facteur
        validate_calculated_value "$SYS_CPU" "system-reserved CPU (après facteur)" 50
        validate_calculated_value "$SYS_MEM" "system-reserved Memory (après facteur)" 100
        validate_calculated_value "$KUBE_CPU" "kube-reserved CPU (après facteur)" 50
        validate_calculated_value "$KUBE_MEM" "kube-reserved Memory (après facteur)" 100
    fi

    # Validation: s'assurer que l'allocatable n'est pas négatif
    local total_cpu_reserved=$((SYS_CPU + KUBE_CPU))
    local total_mem_reserved=$((SYS_MEM + KUBE_MEM))
    local total_cpu_capacity=$((VCPU * 1000))
    local total_mem_capacity=$(echo "scale=0; $RAM_GIB * 1024" | bc | cut -d. -f1)

    if (( total_cpu_reserved >= total_cpu_capacity )); then
        log_error "Réservations CPU totales ($total_cpu_reserved m) >= Capacité CPU ($total_cpu_capacity m)! Réduisez le density-factor."
    fi

    if (( total_mem_reserved >= total_mem_capacity )); then
        log_error "Réservations mémoire totales ($total_mem_reserved Mi) >= Capacité mémoire ($total_mem_capacity Mi)! Réduisez le density-factor."
    fi

    # Calcul des allocatable estimés et des pourcentages restants
    local alloc_cpu_milli=$((total_cpu_capacity - total_cpu_reserved))
    local alloc_mem_mib=$((total_mem_capacity - total_mem_reserved))
    local cpu_alloc_percent=$(echo "scale=2; ($alloc_cpu_milli / $total_cpu_capacity) * 100" | bc)
    local mem_alloc_percent=$(echo "scale=2; ($alloc_mem_mib / $total_mem_capacity) * 100" | bc)

    # Afficher la variation estimée par rapport à l'état initial (si récupérable)
    if [[ -n "$pre_alloc_snapshot" ]]; then
        local pre_cpu_m=${pre_alloc_snapshot%%:*}
        local pre_mem_mi=${pre_alloc_snapshot##*:}
        local cpu_diff=$((alloc_cpu_milli - pre_cpu_m))
        local mem_diff=$((alloc_mem_mib - pre_mem_mi))
        local cpu_diff_fmt
        local mem_diff_fmt
        cpu_diff_fmt=$(format_diff "$cpu_diff")
        mem_diff_fmt=$(format_diff "$mem_diff")
        log_info "Allocatable estimé -> CPU: ${alloc_cpu_milli}m (${cpu_diff_fmt}m) | Mémoire: ${alloc_mem_mib}Mi (${mem_diff_fmt}Mi)"
    else
        log_info "Allocatable estimé -> CPU: ${alloc_cpu_milli}m | Mémoire: ${alloc_mem_mib}Mi"
    fi

    # Avertissements préventifs
    if (( $(echo "$cpu_alloc_percent < 10" | bc -l) )); then
        log_warning "Allocatable CPU très faible: ${cpu_alloc_percent}% (< 10% de la capacité)"
    fi

    if (( $(echo "$mem_alloc_percent < 10" | bc -l) )); then
        log_warning "Allocatable mémoire très faible: ${mem_alloc_percent}% (< 10% de la capacité)"
    fi

    # Garde-fous stricts
    local min_cpu_percent=$MIN_ALLOC_CPU_PERCENT
    local min_mem_percent=$MIN_ALLOC_MEM_PERCENT
    if [[ "$NODE_TYPE_DETECTED" == "control-plane" ]]; then
        min_cpu_percent=$((min_cpu_percent + 5))
        min_mem_percent=$((min_mem_percent + 5))
    fi

    if (( $(echo "$cpu_alloc_percent < $min_cpu_percent" | bc -l) )); then
        log_error "Allocatable CPU tomberait à ${cpu_alloc_percent}% (< ${min_cpu_percent}%). Réduisez le density-factor ou choisissez un profil plus léger."
    fi

    if (( $(echo "$mem_alloc_percent < $min_mem_percent" | bc -l) )); then
        log_error "Allocatable mémoire tomberait à ${mem_alloc_percent}% (< ${min_mem_percent}%). Réduisez le density-factor ou choisissez un profil plus léger."
    fi

    # Affichage du résumé
    display_summary "$VCPU" "$RAM_GIB" "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM" "$NODE_TYPE_DETECTED"

    # Mode dry-run : afficher la config sans appliquer
    if [[ "$DRY_RUN" == true ]]; then
        log_warning "Mode DRY-RUN activé - Configuration non appliquée"
        echo ""

        # Créer un fichier temporaire pour le dry-run
        local temp_dryrun
        temp_dryrun=$(mktemp /tmp/kubelet-config-dryrun.XXXXXX)
        mv "$temp_dryrun" "${temp_dryrun}.yaml"
        temp_dryrun="${temp_dryrun}.yaml"

        generate_kubelet_config "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM" "$VCPU" "$RAM_GIB" "$RAM_MIB" "$temp_dryrun" "$NODE_TYPE_DETECTED"

        echo "Configuration qui serait générée:"
        echo "───────────────────────────────────────────────────────────────────────────"
        cat "$temp_dryrun"
        echo ""

        # Nettoyage
        rm -f "$temp_dryrun"

        log_info "Pour appliquer réellement, relancez sans --dry-run"
        exit 0
    fi

    # Vérification et création des cgroups
    ensure_cgroups

    # Configuration de l'attachement du service kubelet à kubelet.slice
    ensure_kubelet_slice_attachment

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
    temp_config=$(mktemp /tmp/kubelet-config.XXXXXX)
    mv "$temp_config" "${temp_config}.yaml"
    temp_config="${temp_config}.yaml"

    log_info "Génération de la nouvelle configuration kubelet..."
    generate_kubelet_config "$SYS_CPU" "$SYS_MEM" "$KUBE_CPU" "$KUBE_MEM" "$VCPU" "$RAM_GIB" "$RAM_MIB" "$temp_config" "$NODE_TYPE_DETECTED"

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
        log_warning "Échec du redémarrage du kubelet"

        # Tentative de rollback
        if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
            log_warning "Tentative de restauration de la configuration précédente..."
            cp "$BACKUP_FILE" "$KUBELET_CONFIG"

            if systemctl restart kubelet; then
                log_warning "Configuration restaurée, kubelet redémarré avec l'ancienne config"
            else
                log_warning "Échec de la restauration automatique. Vérifiez manuellement: journalctl -u kubelet -f"
            fi
        else
            log_warning "Pas de backup disponible pour restauration automatique"
        fi

        log_error "La nouvelle configuration a causé un problème. Vérifiez les logs: journalctl -u kubelet -n 100"
    fi

    log_success "Kubelet redémarré avec succès"

    # Vérification de la stabilité
    log_info "Vérification de la stabilité du kubelet (jusqu'à 60s)..."
    local wait_interval=5
    local max_wait=60
    local elapsed=0
    local kubelet_active=false

    while (( elapsed < max_wait )); do
        if systemctl is-active --quiet kubelet; then
            kubelet_active=true
            break
        fi

        ((elapsed += wait_interval))
        log_info "  → Kubelet encore en démarrage (${elapsed}s/${max_wait}s)..."
        sleep "$wait_interval"
    done

    if [[ "$kubelet_active" == true ]]; then
        log_success "✓ Kubelet actif et opérationnel"

        # Validation de l'attachement effectif du kubelet à kubelet.slice
        validate_kubelet_slice_attachment

        # Récupération de l'allocatable réel après application (si possible)
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
            log_info "Δ allocatable réel -> CPU: ${post_cpu_m}m (${cpu_diff_fmt}m) | Mémoire: ${post_mem_mi}Mi (${mem_diff_fmt}Mi)"
        fi

        # Gestion intelligente du backup avec rotation
        if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
            local max_rotation=4

            if [[ "$BACKUP" == true ]]; then
                # --backup spécifié : conserver le backup timestampé permanent
                log_success "Backup permanent conservé : $BACKUP_FILE"
                log_info "  → Backup manuel permanent (conservé jusqu'à 90 jours)"
            fi

            # Rotation des backups automatiques (toujours effectuée)
            log_info "Rotation des backups automatiques..."

            # Rotation : .3 → supprimé, .2 → .3, .1 → .2, .0 → .1
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

            # Le nouveau backup devient .0
            if [[ "$BACKUP" == true ]]; then
                # Copier (car on garde aussi l'original timestampé)
                cp "$BACKUP_FILE" "/var/lib/kubelet/config.yaml.last-success.0"
            else
                # Déplacer (pas de backup permanent demandé)
                mv "$BACKUP_FILE" "/var/lib/kubelet/config.yaml.last-success.0"
            fi

            log_info "Backup rotatif créé : /var/lib/kubelet/config.yaml.last-success.0"

            # Compter les backups disponibles dans l'historique
            local history_count=0
            for i in $(seq 0 $((max_rotation - 1))); do
                if [[ -f "/var/lib/kubelet/config.yaml.last-success.$i" ]]; then
                    history_count=$((history_count + 1))
                fi
            done
            log_info "  → $history_count backup(s) rotatif(s) disponibles : .last-success.{0..$((history_count - 1))}"
            log_info "  → .0 = plus récent, .$((history_count - 1)) = plus ancien"

            # Nettoyage des vieux backups permanents timestampés (>90 jours)
            local old_count=$(find /var/lib/kubelet -name 'config.yaml.backup.2*' -mtime +90 2>/dev/null | wc -l)
            if (( old_count > 0 )); then
                find /var/lib/kubelet -name 'config.yaml.backup.2*' -mtime +90 -delete 2>/dev/null
                log_info "Nettoyé $old_count backup(s) permanent(s) > 90 jours"
            fi
        fi
    else
        log_warning "✗ Kubelet non actif après ${max_wait}s !"

        # Rollback automatique
        if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
            log_warning "Rollback automatique en cours..."
            cp "$BACKUP_FILE" "$KUBELET_CONFIG"
            if systemctl restart kubelet; then
                log_warning "Configuration restaurée. Kubelet redémarré avec l'ancienne configuration"
            else
                log_warning "La restauration n'a pas réussi. Analysez les logs: journalctl -u kubelet -n 100"
            fi
        fi

        log_error "Abandon: kubelet non actif après redémarrage. Consultez journalctl -u kubelet -n 100"
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
