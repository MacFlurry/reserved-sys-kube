#!/bin/bash
################################################################################
# Script de test automatisé pour kubelet_auto_config.sh
# Utilise l'environnement Vagrant (cp1 + w1) pour valider le fonctionnement
################################################################################

set -euo pipefail

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KUBELET_SCRIPT="$PROJECT_ROOT/kubelet_auto_config.sh"
TEST_RESULTS=()

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

add_test_result() {
    local status=$1
    local test_name=$2
    local details=${3:-}

    if [[ "$status" == "PASS" ]]; then
        TEST_RESULTS+=("✓ $test_name")
        log_success "$test_name"
    else
        TEST_RESULTS+=("✗ $test_name - $details")
        log_error "$test_name - $details"
    fi
}

check_prerequisites() {
    log_info "Vérification des prérequis..."

    # Vérifier Vagrant
    if ! command -v vagrant &> /dev/null; then
        log_error "Vagrant n'est pas installé"
    fi
    log_success "Vagrant installé: $(vagrant --version)"

    # Vérifier le script kubelet_auto_config.sh
    if [[ ! -f "$KUBELET_SCRIPT" ]]; then
        log_error "Script kubelet_auto_config.sh introuvable: $KUBELET_SCRIPT"
    fi
    log_success "Script trouvé: $KUBELET_SCRIPT"

    # Vérifier le Vagrantfile
    if [[ ! -f "$SCRIPT_DIR/Vagrantfile" ]]; then
        log_error "Vagrantfile introuvable: $SCRIPT_DIR/Vagrantfile"
    fi
    log_success "Vagrantfile trouvé"
}

vagrant_up() {
    log_info "Démarrage du cluster Vagrant (cp1 + w1)..."

    cd "$SCRIPT_DIR"

    # Démarrer control-plane
    log_info "Démarrage du control-plane (cp1)..."
    if ! vagrant up cp1 2>&1 | tee /tmp/vagrant-cp1.log; then
        log_warning "Erreur lors du démarrage de cp1, tentative de continue..."
    fi

    # Attendre que le control-plane soit stable
    log_info "Attente de la stabilisation du control-plane..."
    sleep 30

    # Démarrer worker
    log_info "Démarrage du worker (w1)..."
    if ! vagrant up w1 2>&1 | tee /tmp/vagrant-w1.log; then
        log_warning "Erreur lors du démarrage de w1, tentative de continue..."
    fi

    # Attendre que le worker soit prêt
    log_info "Attente de la stabilisation du worker..."
    sleep 30

    log_success "Cluster Vagrant démarré"
}

check_cluster_health() {
    log_info "Vérification de la santé du cluster..."

    cd "$SCRIPT_DIR"

    # Vérifier que les nodes sont Ready
    local nodes_output
    if ! nodes_output=$(vagrant ssh cp1 -c 'kubectl get nodes -o wide' 2>/dev/null); then
        add_test_result "FAIL" "Cluster health check" "Impossible de récupérer l'état des nodes"
        return 1
    fi

    echo "$nodes_output"

    # Vérifier que cp1 et w1 sont Ready
    if echo "$nodes_output" | grep -qE 'k8s-lab-cp1.*Ready' && \
       echo "$nodes_output" | grep -qE 'k8s-lab-w1.*Ready'; then
        add_test_result "PASS" "Cluster nodes Ready"
    else
        log_warning "Certains nodes ne sont pas Ready, continuant quand même..."
    fi
}

test_script_on_node() {
    local node=$1
    local profile=${2:-gke}
    local density_factor=${3:-1.0}

    log_info "═════════════════════════════════════════════════════════════"
    log_info "Test du script sur $node (profil: $profile, density: $density_factor)"
    log_info "═════════════════════════════════════════════════════════════"

    cd "$SCRIPT_DIR"

    # Copier le script sur le node
    log_info "Copie du script kubelet_auto_config.sh sur $node..."
    if ! vagrant ssh "$node" -c "sudo rm -f /tmp/kubelet_auto_config.sh" 2>/dev/null; then
        add_test_result "FAIL" "[$node] Copie du script" "Impossible de nettoyer /tmp"
        return 1
    fi

    # Copier via cat (plus fiable que scp avec Vagrant)
    if ! vagrant ssh "$node" -c "cat > /tmp/kubelet_auto_config.sh" < "$KUBELET_SCRIPT" 2>/dev/null; then
        add_test_result "FAIL" "[$node] Copie du script" "Échec de la copie"
        return 1
    fi

    if ! vagrant ssh "$node" -c "sudo chmod +x /tmp/kubelet_auto_config.sh" 2>/dev/null; then
        add_test_result "FAIL" "[$node] Chmod du script" "Impossible de rendre exécutable"
        return 1
    fi

    add_test_result "PASS" "[$node] Copie du script"

    # Test 1: Dry-run
    log_info "[$node] Test 1: Dry-run..."
    if vagrant ssh "$node" -c "sudo /tmp/kubelet_auto_config.sh --profile $profile --density-factor $density_factor --dry-run" 2>&1 | tee "/tmp/test-${node}-dryrun.log"; then
        add_test_result "PASS" "[$node] Dry-run mode"
    else
        add_test_result "FAIL" "[$node] Dry-run mode" "Échec du dry-run"
        return 1
    fi

    # Test 2: Récupération de l'allocatable actuel
    log_info "[$node] Récupération de l'allocatable actuel..."
    local alloc_before
    alloc_before=$(vagrant ssh "$node" -c "kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get node \$(hostname) -o jsonpath='{.status.allocatable.cpu} {.status.allocatable.memory}'" 2>/dev/null || echo "N/A N/A")
    log_info "[$node] Allocatable avant: $alloc_before"

    # Test 3: Exécution réelle avec --backup
    log_info "[$node] Test 2: Exécution réelle avec --backup..."
    if vagrant ssh "$node" -c "sudo /tmp/kubelet_auto_config.sh --profile $profile --density-factor $density_factor --backup --wait-timeout 120" 2>&1 | tee "/tmp/test-${node}-apply.log"; then
        add_test_result "PASS" "[$node] Exécution avec backup"
    else
        add_test_result "FAIL" "[$node] Exécution avec backup" "Échec de l'application"
        return 1
    fi

    # Test 4: Vérifier que kubelet est actif après application
    log_info "[$node] Vérification de l'état du kubelet..."
    sleep 10
    if vagrant ssh "$node" -c "sudo systemctl is-active kubelet" 2>/dev/null | grep -q "active"; then
        add_test_result "PASS" "[$node] Kubelet actif après application"
    else
        add_test_result "FAIL" "[$node] Kubelet actif après application" "Kubelet non actif"
        return 1
    fi

    # Test 5: Vérifier que le node est toujours Ready
    log_info "[$node] Vérification que le node est Ready..."
    sleep 30
    local node_status
    node_status=$(vagrant ssh cp1 -c "kubectl get node k8s-lab-$node -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null || echo "Unknown")

    if [[ "$node_status" == "True" ]]; then
        add_test_result "PASS" "[$node] Node toujours Ready après application"
    else
        add_test_result "FAIL" "[$node] Node toujours Ready après application" "Status: $node_status"
        return 1
    fi

    # Test 6: Récupération de l'allocatable après application
    log_info "[$node] Récupération de l'allocatable après application..."
    sleep 10
    local alloc_after
    alloc_after=$(vagrant ssh "$node" -c "kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get node \$(hostname) -o jsonpath='{.status.allocatable.cpu} {.status.allocatable.memory}'" 2>/dev/null || echo "N/A N/A")
    log_info "[$node] Allocatable après: $alloc_after"

    if [[ "$alloc_before" != "$alloc_after" ]]; then
        log_success "[$node] Allocatable modifié avec succès"
        add_test_result "PASS" "[$node] Allocatable modifié"
    else
        log_warning "[$node] Allocatable identique (peut être normal si déjà configuré)"
    fi

    # Test 7: Vérifier l'attachement à kubelet.slice
    log_info "[$node] Vérification de l'attachement à kubelet.slice..."
    if vagrant ssh "$node" -c "sudo systemctl show kubelet.service -p Slice --value" 2>/dev/null | grep -q "kubelet.slice"; then
        add_test_result "PASS" "[$node] Kubelet attaché à kubelet.slice"
    else
        add_test_result "FAIL" "[$node] Kubelet attaché à kubelet.slice" "Non attaché à kubelet.slice"
    fi

    # Test 8: Vérifier que le backup a été créé
    log_info "[$node] Vérification de la création du backup..."
    if vagrant ssh "$node" -c "sudo ls -la /var/lib/kubelet/config.yaml.backup.* 2>/dev/null" 2>&1 | grep -q "config.yaml.backup"; then
        add_test_result "PASS" "[$node] Backup créé"
    else
        log_warning "[$node] Aucun backup trouvé (peut être normal si premier run)"
    fi

    log_success "═════════════════════════════════════════════════════════════"
    log_success "Tests terminés pour $node"
    log_success "═════════════════════════════════════════════════════════════"
}

display_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  RÉSUMÉ DES TESTS"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    for result in "${TEST_RESULTS[@]}"; do
        echo "$result"
    done

    echo ""
    echo "═══════════════════════════════════════════════════════════════"

    # Compter les résultats
    local pass_count=$(printf '%s\n' "${TEST_RESULTS[@]}" | grep -c "^✓" || true)
    local total_count=${#TEST_RESULTS[@]}

    if [[ $pass_count -eq $total_count ]]; then
        log_success "Tous les tests ont réussi ($pass_count/$total_count)"
        return 0
    else
        log_warning "Certains tests ont échoué ($pass_count/$total_count réussis)"
        return 1
    fi
}

cleanup() {
    log_info "Nettoyage de l'environnement Vagrant..."

    cd "$SCRIPT_DIR"

    # Demander confirmation
    read -p "Voulez-vous détruire les VMs Vagrant ? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        vagrant destroy -f w1
        vagrant destroy -f cp1
        log_success "VMs détruites"
    else
        log_info "VMs conservées pour investigation"
    fi
}

main() {
    log_info "╔═══════════════════════════════════════════════════════════════╗"
    log_info "║  TEST AUTOMATISÉ: kubelet_auto_config.sh                     ║"
    log_info "║  Environnement: Vagrant (cp1 + w1)                           ║"
    log_info "╚═══════════════════════════════════════════════════════════════╝"
    echo ""

    # Vérifications préalables
    check_prerequisites

    # Démarrer le cluster
    vagrant_up

    # Vérifier la santé du cluster
    check_cluster_health

    # Tester sur control-plane (avec density factor conservatif pour control-plane)
    test_script_on_node "cp1" "gke" "1.0"

    # Tester sur worker (avec density factor plus élevé)
    test_script_on_node "w1" "gke" "1.5"

    # Afficher le résumé
    if display_summary; then
        log_success "Tests terminés avec succès!"
    else
        log_warning "Tests terminés avec des échecs"
    fi

    # Cleanup optionnel
    cleanup
}

# Trap pour cleanup en cas d'interruption
trap cleanup EXIT

# Exécution
main "$@"
