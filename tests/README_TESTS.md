# Tests pour kubelet_auto_config.sh

Ce dossier contient les tests pour valider le fonctionnement du script `kubelet_auto_config.sh` après les modifications de production.

## Structure des tests

```
tests/
├── README_TESTS.md                    # Ce fichier
├── quick_tests.sh                     # Tests rapides (< 1 minute)
└── vagrant/
    ├── test_kubelet_auto_config.sh   # Tests d'intégration complets (15-30 min)
    ├── Vagrantfile                    # Configuration du cluster de test
    └── README.md                      # Documentation Vagrant
```

## Tests disponibles

### 1. Tests rapides (recommandé)

**Durée**: < 1 minute
**Environnement**: Aucun prérequis

Valide la syntaxe, la présence des fonctions critiques et les améliorations de sécurité :

```bash
cd tests
./quick_tests.sh
```

**Tests effectués** (15 tests) :
- ✓ Syntaxe bash valide
- ✓ Mode strict activé (set -euo pipefail)
- ✓ Trap cleanup présent
- ✓ Vérification SHA256 pour yq implémentée
- ✓ Validation anti-injection /etc/os-release
- ✓ Timeouts réseau configurés (apt + wget)
- ✓ Lock atomique avec flock implémenté
- ✓ Fallback kubeconfig implémenté
- ✓ Paramètre --wait-timeout présent
- ✓ Mode REQUIRE_DEPENDENCIES implémenté
- ✓ Fail-fast dans fonctions normalize
- ✓ Parsing robuste cgroup v1/v2 avec fallback
- ✓ Protection root présente
- ✓ Mode dry-run disponible
- ✓ Rollback automatique implémenté

**Résultat attendu** : `15/15 tests réussis`

---

### 2. Tests d'intégration Vagrant (optionnel)

**Durée**: 15-30 minutes
**Environnement**: VMware Fusion + Vagrant + Box Ubuntu 24.04 ARM64

Tests d'intégration complets dans un cluster Kubernetes réel (1 control-plane + 1 worker).

#### Prérequis

- macOS avec VMware Fusion
- Plugin `vagrant-vmware-desktop` installé
- Box locale `local/ubuntu-24.04-arm64`
- Vagrant 2.4+
- Accès Internet pour les VMs

#### Exécution

```bash
cd tests/vagrant
./test_kubelet_auto_config.sh
```

**Tests effectués** :
1. **Démarrage du cluster** (cp1 + w1)
2. **Validation de la santé du cluster** (nodes Ready)
3. **Tests sur le control-plane (cp1)** :
   - Copie du script
   - Dry-run mode
   - Exécution avec --backup
   - Vérification kubelet actif
   - Vérification node Ready
   - Vérification allocatable modifié
   - Vérification attachement kubelet.slice
   - Vérification backup créé
4. **Tests sur le worker (w1)** :
   - Mêmes tests que cp1

**Résultat attendu** : Tous les tests passent avec le cluster opérationnel

---

## Modifications de production validées

Les tests confirment que toutes les améliorations critiques ont été implémentées :

### Sécurité (Critical) ✅
- Vérification SHA256 pour téléchargement yq (protection supply chain)
- Validation anti-injection pour /etc/os-release
- Timeouts réseau (apt + wget) pour éviter les blocages

### Robustesse (Major) ✅
- Lock atomique avec flock (élimine race conditions)
- Fail-fast dans fonctions de normalisation
- Parsing robuste du cgroup avec fallback v1/v2
- Fallback kubeconfig intelligent

### Production-ready (Minor) ✅
- Mode strict dépendances (REQUIRE_DEPENDENCIES=true par défaut)
- Paramètre --wait-timeout configurable
- Rollback automatique en cas d'échec

---

## Workflow recommandé

### Développement / CI
```bash
# Validation rapide après modification
./tests/quick_tests.sh
```

### Validation complète avant release
```bash
# Tests rapides
./tests/quick_tests.sh

# Tests d'intégration (si disponible)
cd tests/vagrant
./test_kubelet_auto_config.sh
```

---

## Interprétation des résultats

### Tests rapides

**Succès** :
```
✓ Tous les tests rapides ont réussi! (15/15)
```

**Échec** :
```
✗ Certains tests ont échoué (12/15)
```
→ Vérifier les tests en échec et corriger le script

### Tests d'intégration

**Succès** :
- Cluster démarre correctement
- Script s'exécute sans erreur sur cp1 et w1
- Kubelet redémarre et reste actif
- Nodes restent Ready
- Allocatable est modifié

**Échec** :
- Vérifier les logs dans `/tmp/test-{cp1|w1}-*.log`
- Investiguer avec `vagrant ssh {cp1|w1}`
- Consulter `sudo journalctl -u kubelet -n 100`

---

## Troubleshooting

### Tests rapides échouent

```bash
# Vérifier la syntaxe bash
bash -n ../kubelet_auto_config.sh

# Vérifier les modifications
git diff ../kubelet_auto_config.sh
```

### Tests Vagrant échouent

```bash
# Vérifier l'état des VMs
cd tests/vagrant
vagrant status

# Logs détaillés
vagrant up cp1 --debug
vagrant ssh cp1 -c 'sudo journalctl -u kubelet -f'

# Nettoyer et recommencer
vagrant destroy -f w1 cp1
vagrant up cp1
vagrant up w1
```

---

## Maintenance

### Ajouter un nouveau test rapide

Éditer `tests/quick_tests.sh` :

```bash
test_ma_fonctionnalite() {
    log_info "Test XX: Description..."
    if grep -q "pattern" "$KUBELET_SCRIPT"; then
        log_success "Fonctionnalité présente"
    else
        log_fail "Fonctionnalité manquante"
    fi
}

# Ajouter dans main()
test_ma_fonctionnalite
```

### Mettre à jour les tests d'intégration

Éditer `tests/vagrant/test_kubelet_auto_config.sh` pour ajouter de nouveaux scénarios de test.

---

## Historique

- **2025-01**: Création des tests après refactoring de production
  - Tests rapides (15 tests)
  - Tests d'intégration Vagrant
  - Validation des améliorations critiques (sécurité + robustesse)
