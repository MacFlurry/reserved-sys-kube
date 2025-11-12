#!/bin/bash
################################################################################
# Tests rapides pour kubelet_auto_config.sh
# Valide la syntaxe, les fonctions critiques et la logique de base
################################################################################

set -uo pipefail

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBELET_SCRIPT="$PROJECT_ROOT/kubelet_auto_config.sh"

TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
    ((PASS_COUNT++))
    ((TEST_COUNT++))
}

log_fail() {
    echo -e "${RED}[✗]${NC} $*"
    ((FAIL_COUNT++))
    ((TEST_COUNT++))
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

# Test 1: Syntaxe Bash
test_bash_syntax() {
    log_info "Test 1: Validation syntaxe bash..."
    if bash -n "$KUBELET_SCRIPT" 2>/dev/null; then
        log_success "Syntaxe bash valide"
    else
        log_fail "Erreur de syntaxe bash"
    fi
}

# Test 2: Présence de set -euo pipefail
test_strict_mode() {
    log_info "Test 2: Vérification du mode strict..."
    if grep -q "^set -euo pipefail" "$KUBELET_SCRIPT"; then
        log_success "Mode strict activé (set -euo pipefail)"
    else
        log_fail "Mode strict non activé"
    fi
}

# Test 3: Présence du trap cleanup
test_trap_cleanup() {
    log_info "Test 3: Vérification du trap cleanup..."
    if grep -q "trap cleanup EXIT" "$KUBELET_SCRIPT"; then
        log_success "Trap cleanup présent"
    else
        log_fail "Trap cleanup manquant"
    fi
}

# Test 4: Vérification SHA256 pour yq
test_sha256_check() {
    log_info "Test 4: Vérification SHA256 pour yq..."
    if grep -q "sha256sum -c" "$KUBELET_SCRIPT" && grep -q "yq_sha256" "$KUBELET_SCRIPT"; then
        log_success "Vérification SHA256 pour yq implémentée"
    else
        log_fail "Vérification SHA256 pour yq manquante"
    fi
}

# Test 5: Vérification validation /etc/os-release
test_os_release_validation() {
    log_info "Test 5: Validation anti-injection /etc/os-release..."
    if grep -q 'grep.*os-release' "$KUBELET_SCRIPT" && grep -q 'caractères suspects' "$KUBELET_SCRIPT"; then
        log_success "Validation anti-injection /etc/os-release présente"
    else
        log_fail "Validation anti-injection /etc/os-release manquante"
    fi
}

# Test 6: Timeouts pour apt et wget
test_timeouts() {
    log_info "Test 6: Vérification des timeouts réseau..."
    local has_apt_timeout=$(grep -c "Acquire::http::Timeout" "$KUBELET_SCRIPT" || echo 0)
    local has_wget_timeout=$(grep -c "wget --timeout" "$KUBELET_SCRIPT" || echo 0)

    if [[ $has_apt_timeout -gt 0 ]] && [[ $has_wget_timeout -gt 0 ]]; then
        log_success "Timeouts réseau configurés (apt + wget)"
    else
        log_fail "Timeouts réseau manquants"
    fi
}

# Test 7: Utilisation de flock
test_flock_usage() {
    log_info "Test 7: Vérification de l'utilisation de flock..."
    if grep -q "flock" "$KUBELET_SCRIPT"; then
        log_success "Lock atomique avec flock implémenté"
    else
        log_fail "Lock atomique flock manquant"
    fi
}

# Test 8: Fallback kubeconfig
test_kubeconfig_fallback() {
    log_info "Test 8: Vérification du fallback kubeconfig..."
    if grep -q "KUBECONFIG" "$KUBELET_SCRIPT" && grep -q "kubelet.conf" "$KUBELET_SCRIPT"; then
        log_success "Fallback kubeconfig implémenté"
    else
        log_fail "Fallback kubeconfig manquant"
    fi
}

# Test 9: Paramètre --wait-timeout
test_wait_timeout_param() {
    log_info "Test 9: Vérification du paramètre --wait-timeout..."
    if grep -q "\\-\\-wait-timeout" "$KUBELET_SCRIPT" && grep -q "KUBELET_WAIT_TIMEOUT" "$KUBELET_SCRIPT"; then
        log_success "Paramètre --wait-timeout présent"
    else
        log_fail "Paramètre --wait-timeout manquant"
    fi
}

# Test 10: Mode REQUIRE_DEPENDENCIES
test_require_dependencies() {
    log_info "Test 10: Vérification du mode REQUIRE_DEPENDENCIES..."
    if grep -q "REQUIRE_DEPENDENCIES" "$KUBELET_SCRIPT"; then
        log_success "Mode REQUIRE_DEPENDENCIES implémenté"
    else
        log_fail "Mode REQUIRE_DEPENDENCIES manquant"
    fi
}

# Test 11: Fonctions normalize avec fail-fast
test_normalize_fail_fast() {
    log_info "Test 11: Vérification du fail-fast dans normalize_*..."
    local normalize_errors=$(grep -A 5 "normalize_cpu_to_milli\|normalize_memory_to_mib" "$KUBELET_SCRIPT" | grep -c "log_error" || echo 0)

    if [[ $normalize_errors -gt 4 ]]; then
        log_success "Fail-fast implémenté dans fonctions normalize"
    else
        log_fail "Fail-fast manquant dans fonctions normalize"
    fi
}

# Test 12: Parsing robuste cgroup avec fallback
test_cgroup_parsing() {
    log_info "Test 12: Vérification du parsing robuste du cgroup..."
    if grep -q "cgroup v2" "$KUBELET_SCRIPT" && grep -q "Fallback cgroup v1" "$KUBELET_SCRIPT"; then
        log_success "Parsing robuste cgroup v1/v2 avec fallback"
    else
        log_fail "Parsing robuste cgroup manquant"
    fi
}

# Test 13: Vérifier que le script nécessite root
test_root_check() {
    log_info "Test 13: Vérification de la protection root..."
    if grep -q "check_root" "$KUBELET_SCRIPT" && grep -q "EUID" "$KUBELET_SCRIPT"; then
        log_success "Protection root présente"
    else
        log_fail "Protection root manquante"
    fi
}

# Test 14: Dry-run disponible
test_dry_run() {
    log_info "Test 14: Vérification du mode dry-run..."
    if grep -q "\\-\\-dry-run" "$KUBELET_SCRIPT" && grep -q "DRY_RUN" "$KUBELET_SCRIPT"; then
        log_success "Mode dry-run disponible"
    else
        log_fail "Mode dry-run manquant"
    fi
}

# Test 15: Rollback automatique
test_rollback() {
    log_info "Test 15: Vérification du rollback automatique..."
    if grep -q "rollback" "$KUBELET_SCRIPT" && grep -q "BACKUP_FILE" "$KUBELET_SCRIPT"; then
        log_success "Rollback automatique implémenté"
    else
        log_fail "Rollback automatique manquant"
    fi
}

display_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  RÉSUMÉ DES TESTS RAPIDES"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Total:  $TEST_COUNT tests"
    echo "  Réussi: $PASS_COUNT"
    echo "  Échoué: $FAIL_COUNT"
    echo ""

    if [[ $FAIL_COUNT -eq 0 ]]; then
        log_success "Tous les tests rapides ont réussi!"
        echo ""
        log_info "Pour les tests d'intégration complets:"
        log_info "  cd tests/vagrant && ./test_kubelet_auto_config.sh"
        echo ""
        return 0
    else
        log_fail "Certains tests ont échoué"
        return 1
    fi
}

main() {
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  TESTS RAPIDES: kubelet_auto_config.sh                       ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""

    # Vérifier que le script existe
    if [[ ! -f "$KUBELET_SCRIPT" ]]; then
        log_fail "Script introuvable: $KUBELET_SCRIPT"
        exit 1
    fi

    log_info "Script: $KUBELET_SCRIPT"
    echo ""

    # Exécuter les tests
    test_bash_syntax
    test_strict_mode
    test_trap_cleanup
    test_sha256_check
    test_os_release_validation
    test_timeouts
    test_flock_usage
    test_kubeconfig_fallback
    test_wait_timeout_param
    test_require_dependencies
    test_normalize_fail_fast
    test_cgroup_parsing
    test_root_check
    test_dry_run
    test_rollback

    # Afficher le résumé
    display_summary
}

main "$@"
