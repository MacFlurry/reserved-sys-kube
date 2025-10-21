#!/bin/bash
################################################################################
# Tests unitaires pour kubelet_auto_config.sh
# Valide les calculs de réservations pour différentes configurations de nœuds
################################################################################

set -euo pipefail

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Compteurs
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Charger les fonctions du script principal (sans l'exécuter)
# On source uniquement les fonctions nécessaires
source_functions() {
    # Extraire uniquement les fonctions calculate_* du script
    local script_path="../kubelet_auto_config.sh"

    # Sourcer les fonctions de calcul
    eval "$(sed -n '/^calculate_gke()/,/^}/p' "$script_path")"
    eval "$(sed -n '/^calculate_eks()/,/^}/p' "$script_path")"
    eval "$(sed -n '/^calculate_conservative()/,/^}/p' "$script_path")"
    eval "$(sed -n '/^calculate_minimal()/,/^}/p' "$script_path")"
}

assert_equals() {
    local test_name=$1
    local expected=$2
    local actual=$3

    ((TESTS_TOTAL++))

    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        ((TESTS_FAILED++))
        return 1
    fi
}

assert_in_range() {
    local test_name=$1
    local value=$2
    local min=$3
    local max=$4

    ((TESTS_TOTAL++))

    # Normaliser les valeurs en entiers pour éviter les problèmes avec (( ))
    local value_int=$(printf "%.0f" "$value" 2>/dev/null || echo "$value")
    local min_int=$(printf "%.0f" "$min" 2>/dev/null || echo "$min")
    local max_int=$(printf "%.0f" "$max" 2>/dev/null || echo "$max")

    if (( value_int >= min_int && value_int <= max_int )); then
        echo -e "${GREEN}✓${NC} $test_name (value=$value_int, range=[$min_int-$max_int])"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Value: $value_int"
        echo "  Expected range: [$min_int-$max_int]"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_gke_small_node() {
    local vcpu=2
    local ram_gib=4
    local ram_mib=3891

    read -r sys_cpu sys_mem kube_cpu kube_mem <<< $(calculate_gke "$vcpu" "$ram_gib" "$ram_mib")

    # Valeurs attendues basées sur la formule GKE
    # sys_cpu: vcpu <= 2 → 100
    assert_equals "GKE 2vCPU: system-reserved CPU" "100" "$sys_cpu"

    # sys_mem: 100 + (ram_mib * 0.01) + (ram_gib * 11)
    # = 100 + 38 + 44 = 182
    assert_in_range "GKE 4GB: system-reserved Memory" "$sys_mem" 180 185

    # kube_cpu: 60 + max(vcpu*10, 40) = 60 + 40 = 100
    # Mais vcpu=2 → 2*10=20 < 40, donc 40. Total 60+40=100
    # Correction: kube_cpu_dynamic = max(vcpu * 10, 40) si < 40
    # vcpu=2 → 20, si < 40 alors = 40. Total = 60 + 40 = 100
    # Mais en réalité: kube_cpu_dynamic=$((vcpu * 10)) puis si < 40 alors = 40
    # Donc kube_cpu_base=60 + kube_cpu_dynamic
    assert_equals "GKE 2vCPU: kube-reserved CPU" "100" "$kube_cpu"

    # kube_mem: 255 + (ram_gib <= 64 ? ram_gib*11 : ...)
    # = 255 + 44 = 299
    assert_in_range "GKE 4GB: kube-reserved Memory" "$kube_mem" 295 305
}

test_gke_medium_node() {
    local vcpu=8
    local ram_gib=32
    local ram_mib=31232

    read -r sys_cpu sys_mem kube_cpu kube_mem <<< $(calculate_gke "$vcpu" "$ram_gib" "$ram_mib")

    # sys_cpu: vcpu=8 → 100 + (8-2)*20 = 100 + 120 = 220
    assert_equals "GKE 8vCPU: system-reserved CPU" "220" "$sys_cpu"

    # sys_mem: 100 + 312 + 352 = 764
    assert_in_range "GKE 32GB: system-reserved Memory" "$sys_mem" 760 770

    # kube_cpu: 60 + 80 = 140
    assert_equals "GKE 8vCPU: kube-reserved CPU" "140" "$kube_cpu"

    # kube_mem: 255 + 352 = 607
    assert_in_range "GKE 32GB: kube-reserved Memory" "$kube_mem" 600 615
}

test_gke_large_node() {
    local vcpu=48
    local ram_gib=192
    local ram_mib=187392

    read -r sys_cpu sys_mem kube_cpu kube_mem <<< $(calculate_gke "$vcpu" "$ram_gib" "$ram_mib")

    # sys_cpu: vcpu=48 > 32 → 460 + (48-32)*5 = 460 + 80 = 540
    assert_equals "GKE 48vCPU: system-reserved CPU" "540" "$sys_cpu"

    # sys_mem: ram_gib >= 64 → 100 + (ram_mib * 0.005) + (ram_gib * 11)
    # = 100 + 936 + 2112 = 3148
    assert_in_range "GKE 192GB: system-reserved Memory" "$sys_mem" 3140 3160

    # kube_cpu: 60 + 480 = 540
    assert_equals "GKE 48vCPU: kube-reserved CPU" "540" "$kube_cpu"

    # kube_mem: ram_gib > 64 → 255 + (64*11 + (192-64)*8)
    # = 255 + 704 + 1024 = 1983
    assert_in_range "GKE 192GB: kube-reserved Memory" "$kube_mem" 1975 1990
}

test_eks_calculations() {
    local vcpu=8
    local ram_gib=32
    local ram_mib=31232

    read -r sys_cpu sys_mem kube_cpu kube_mem <<< $(calculate_eks "$vcpu" "$ram_gib" "$ram_mib")

    # sys_cpu: vcpu=8 → palier 8-32 → 200
    assert_equals "EKS 8vCPU: system-reserved CPU" "200" "$sys_cpu"

    # sys_mem: 100 + (31232 * 0.015) = 100 + 468 = 568
    assert_in_range "EKS 32GB: system-reserved Memory" "$sys_mem" 565 575

    # kube_cpu: vcpu=8 → 100 + 8*10 = 180
    assert_equals "EKS 8vCPU: kube-reserved CPU" "180" "$kube_cpu"

    # kube_mem: 255 + 32*11 = 255 + 352 = 607
    assert_in_range "EKS 32GB: kube-reserved Memory" "$kube_mem" 600 615
}

test_conservative_calculations() {
    local vcpu=8
    local ram_gib=32
    local ram_mib=31232

    read -r sys_cpu sys_mem kube_cpu kube_mem <<< $(calculate_conservative "$vcpu" "$ram_gib" "$ram_mib")

    # sys_cpu: 500 + (8 * 1000 * 0.01) = 500 + 80 = 580
    assert_equals "Conservative 8vCPU: system-reserved CPU" "580" "$sys_cpu"

    # sys_mem: 1024 + (31232 * 0.02) = 1024 + 624 = 1648
    assert_in_range "Conservative 32GB: system-reserved Memory" "$sys_mem" 1645 1655

    # kube_cpu: 500 + (8 * 1000 * 0.015) = 500 + 120 = 620
    assert_equals "Conservative 8vCPU: kube-reserved CPU" "620" "$kube_cpu"

    # kube_mem: 1024 + (31232 * 0.05) = 1024 + 1561 = 2585
    assert_in_range "Conservative 32GB: kube-reserved Memory" "$kube_mem" 2580 2595
}

test_minimal_calculations() {
    local vcpu=8
    local ram_gib=32
    local ram_mib=31232

    read -r sys_cpu sys_mem kube_cpu kube_mem <<< $(calculate_minimal "$vcpu" "$ram_gib" "$ram_mib")

    # sys_cpu: vcpu >= 8 → 150
    assert_equals "Minimal 8vCPU: system-reserved CPU" "150" "$sys_cpu"

    # sys_mem: 256 + 32*8 = 256 + 256 = 512
    assert_equals "Minimal 32GB: system-reserved Memory" "512" "$sys_mem"

    # kube_cpu: 60 + 8*5 = 60 + 40 = 100
    assert_equals "Minimal 8vCPU: kube-reserved CPU" "100" "$kube_cpu"

    # kube_mem: 256 + 32*8 = 512
    assert_equals "Minimal 32GB: kube-reserved Memory" "512" "$kube_mem"
}

test_decimal_handling() {
    local vcpu=2
    local ram_gib=3.80
    local ram_mib=3891

    # Ce test vérifie que les fonctions ne plantent pas avec des décimales
    local result
    result=$(calculate_gke "$vcpu" "$ram_gib" "$ram_mib" 2>&1) || {
        echo -e "${RED}✗${NC} calculate_gke plante avec ram_gib décimal"
        ((TESTS_FAILED++))
        ((TESTS_TOTAL++))
        return 1
    }

    read -r sys_cpu sys_mem kube_cpu kube_mem <<< "$result"

    # Vérifier que les valeurs sont des entiers valides
    if [[ "$sys_cpu" =~ ^[0-9]+$ ]] && [[ "$sys_mem" =~ ^[0-9]+$ ]] && \
       [[ "$kube_cpu" =~ ^[0-9]+$ ]] && [[ "$kube_mem" =~ ^[0-9]+$ ]]; then
        echo -e "${GREEN}✓${NC} Gestion décimales: toutes les valeurs sont des entiers valides"
        ((TESTS_PASSED++))
        ((TESTS_TOTAL++))
    else
        echo -e "${RED}✗${NC} Gestion décimales: certaines valeurs ne sont pas des entiers"
        echo "  sys_cpu=$sys_cpu, sys_mem=$sys_mem, kube_cpu=$kube_cpu, kube_mem=$kube_mem"
        ((TESTS_FAILED++))
        ((TESTS_TOTAL++))
    fi
}

run_test_suite() {
    local suite_name=$1
    local test_function=$2

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 $suite_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local tests_before=$TESTS_TOTAL
    local failed_before=$TESTS_FAILED

    $test_function

    local tests_run=$((TESTS_TOTAL - tests_before))
    local tests_suite_failed=$((TESTS_FAILED - failed_before))
    local tests_suite_passed=$((tests_run - tests_suite_failed))

    if (( tests_suite_failed == 0 )); then
        echo -e "${GREEN}✓${NC} Suite complète : $tests_suite_passed/$tests_run tests réussis"
    else
        echo -e "${RED}✗${NC} Suite échouée : $tests_suite_passed/$tests_run tests réussis, $tests_suite_failed échoués"
    fi
}

main() {
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║       Tests unitaires - kubelet_auto_config.sh               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Suites de tests à exécuter :"
    echo "  [1] GKE - Petit nœud (2 vCPU, 4 GiB)"
    echo "  [2] GKE - Nœud moyen (8 vCPU, 32 GiB)"
    echo "  [3] GKE - Gros nœud (48 vCPU, 192 GiB)"
    echo "  [4] EKS - Nœud moyen (8 vCPU, 32 GiB)"
    echo "  [5] Conservative - Nœud moyen (8 vCPU, 32 GiB)"
    echo "  [6] Minimal - Nœud moyen (8 vCPU, 32 GiB)"
    echo "  [7] Gestion des décimales (3.80 GiB - ARM64)"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"

    # Charger les fonctions
    source_functions

    # Exécuter les tests
    run_test_suite "GKE - Petit nœud (2 vCPU, 4 GiB)" test_gke_small_node
    run_test_suite "GKE - Nœud moyen (8 vCPU, 32 GiB)" test_gke_medium_node
    run_test_suite "GKE - Gros nœud (48 vCPU, 192 GiB)" test_gke_large_node
    run_test_suite "EKS - Nœud moyen (8 vCPU, 32 GiB)" test_eks_calculations
    run_test_suite "Conservative - Nœud moyen (8 vCPU, 32 GiB)" test_conservative_calculations
    run_test_suite "Minimal - Nœud moyen (8 vCPU, 32 GiB)" test_minimal_calculations
    run_test_suite "Gestion des décimales (3.80 GiB - ARM64)" test_decimal_handling

    # Résumé
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "               RÉSUMÉ GLOBAL DES TESTS"
    echo "═══════════════════════════════════════════════════════════════"
    echo "Total:    $TESTS_TOTAL tests"
    echo -e "${GREEN}Réussis:  $TESTS_PASSED${NC}"
    echo -e "${RED}Échoués:  $TESTS_FAILED${NC}"
    echo "═══════════════════════════════════════════════════════════════"

    if (( TESTS_FAILED > 0 )); then
        echo -e "\n${RED}✗ Certains tests ont échoué${NC}\n"
        exit 1
    else
        echo -e "\n${GREEN}✓ Tous les tests sont passés !${NC}\n"
        exit 0
    fi
}

main "$@"
