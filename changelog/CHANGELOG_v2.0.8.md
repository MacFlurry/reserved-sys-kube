# Changelog v2.0.8 - Correctifs critiques et fiabilisation

> **Note importante:** La v2.0.7 contenait les bugs critiques identifiés lors du test sur VM ARM64.
> Cette v2.0.8 corrige tous les problèmes bloquants.

## 📅 Date de release
**21 octobre 2025**

---

## 🔴 Correctifs critiques (Breaking bugs)

### 1. **Arithmétique décimale avec `(( ))` - CRITIQUE**
**Problème :** Le script plantait systématiquement sur VM ARM64 avec des valeurs de RAM décimales (ex: 3.80 GiB).

**Impact :**
```bash
# AVANT (plantage)
local sys_mem_kernel=$((ram_gib * 11))  # Si ram_gib=3.80 → ERROR: invalid arithmetic operator

# Erreurs observées :
# - line 311: 3.80 * 11: syntax error: invalid arithmetic operator
# - line 329: 3.80 * 11: syntax error
```

**Solution :**
- Normalisation systématique de `ram_gib` en entier via `printf "%.0f"`
- Utilisation de `bc` avec forçage entier (`/ 1`) pour tous les calculs décimaux
- Ajout de validations post-calcul (`validate_calculated_value()`)

**Fichiers modifiés :**
- `calculate_gke()` : kubelet_auto_config.sh:286-337
- `calculate_eks()` : kubelet_auto_config.sh:340-381
- `calculate_conservative()` : kubelet_auto_config.sh:384-406
- `calculate_minimal()` : kubelet_auto_config.sh:409-436
- `apply_density_factor()` : kubelet_auto_config.sh:442-456

**Test de régression :**
```bash
# Valider avec RAM décimale
cd tests && ./test_calculations.sh
# → Test "Gestion des décimales (3.80 GiB)" doit passer
```

---

### 2. **Gestion du lock file et trap - CRITIQUE**
**Problème :** Variable `lock_file` locale dans `acquire_lock()`, trap échouait si erreur avant acquisition.

**Impact :**
```bash
# AVANT
acquire_lock() {
    local lock_file="/var/lock/..."  # Variable locale !
    trap 'rm -rf "$lock_file"' EXIT  # Échoue si erreur avant acquire_lock
}

# Erreur observée :
# line 146: lock_file: unbound variable
```

**Solution :**
- Variable globale `LOCK_FILE` déclarée en début de script (ligne 86)
- Fonction `cleanup()` robuste avec gestion des erreurs (ligne 89-93)
- Trap enregistré dès le début du script (ligne 96)
- Détection et nettoyage des locks orphelins (ligne 147-156)

**Code ajouté :**
```bash
# Ligne 86-96
LOCK_FILE="/var/lock/kubelet-auto-config.lock"

cleanup() {
    if [[ -n "${LOCK_FILE:-}" ]] && [[ -d "$LOCK_FILE" ]]; then
        rm -rf "$LOCK_FILE" 2>/dev/null || true
    fi
}

trap cleanup EXIT
```

---

### 3. **Formatage YAML avec décimales - HAUTE PRIORITÉ**
**Problème :** Génération de valeurs `172.00Mi` au lieu de `172Mi` dans le YAML kubelet.

**Impact :**
```yaml
# AVANT
systemReserved:
  cpu: "172.00m"      # ✗ Décimales inutiles
  memory: "460.00Mi"  # ✗ Non standard

# APRÈS
systemReserved:
  cpu: "172m"         # ✓ Entier propre
  memory: "460Mi"     # ✓ Format standard
```

**Solution :**
- Utilisation de `printf "%.0f"` au lieu de `cut -d. -f1` dans `apply_density_factor()`
- Garantit un arrondi correct et pas de décimales résiduelles

**Ligne modifiée :** kubelet_auto_config.sh:450-453

---

## 🟢 Améliorations (Robustesse)

### 4. **Validation post-calcul**
**Ajout :** Fonction `validate_calculated_value()` pour détecter les erreurs de calcul.

**Fonctionnalités :**
- Vérification que les valeurs calculées ne sont pas vides
- Validation du format entier (regex `^[0-9]+$`)
- Vérification des minimums requis (ex: CPU >= 50m, Memory >= 100Mi)

**Usage :**
```bash
validate_calculated_value "$SYS_CPU" "system-reserved CPU" 50
validate_calculated_value "$SYS_MEM" "system-reserved Memory" 100
```

**Ligne ajoutée :** kubelet_auto_config.sh:217-236

---

### 5. **Hook pre-commit pour détection BOM UTF-8**
**Ajout :** Hook Git automatique pour détecter et nettoyer les BOM UTF-8.

**Fonctionnalités :**
- Scan de tous les fichiers `.sh` et `.bash` stagés
- Détection automatique du BOM (octets `EF BB BF`)
- Nettoyage et re-staging automatique
- Création de backups (`.bom-backup`)

**Installation :**
```bash
# Le hook est déjà installé dans .git/hooks/pre-commit
# Test manuel :
git add kubelet_auto_config.sh
git commit -m "test"
# → Le hook s'exécute automatiquement
```

**Fichier créé :** `.git/hooks/pre-commit` (exécutable)

---

### 6. **Suite de tests unitaires**
**Ajout :** Framework de tests complet pour valider les calculs.

**Couverture :**
- 25 tests sur 4 profils (GKE, EKS, Conservative, Minimal)
- 3 tailles de nœuds (2 vCPU / 4GB, 8 vCPU / 32GB, 48 vCPU / 192GB)
- Test spécifique de gestion des décimales

**Exécution :**
```bash
cd tests
./test_calculations.sh

# Résultat attendu :
# Total:    25 tests
# Réussis:  25
# Échoués:  0
```

**Fichiers créés :**
- `tests/test_calculations.sh` (exécutable)
- `tests/README.md` (documentation)

---

## 📊 Tests de validation

### Avant v2.0.7 (VM ARM64 Ubuntu)
```bash
$ sudo ./kubelet_auto_config.sh --dry-run
line 311: 3.80 * 11: syntax error: invalid arithmetic operator (expression: "3.80 * 11")
line 146: lock_file: unbound variable
```

### Après v2.0.7 (VM ARM64 Ubuntu)
```bash
$ sudo ./kubelet_auto_config.sh --dry-run
[INFO] Détection des ressources système...
[SUCCESS] Détecté: 2 vCPU, 3.80 GiB RAM (3891 MiB)
[INFO] Calcul des réservations avec profil 'gke'...
[SUCCESS] Configuration générée avec succès

Configuration nœud:
  vCPU:              2
  RAM:               3.80 GiB

systemReserved:
  cpu: "100m"        # ✓ Pas de décimales
  memory: "182Mi"    # ✓ Entier propre

kubeReserved:
  cpu: "100m"
  memory: "299Mi"
```

---

## 🔧 Modifications techniques

### Fichiers modifiés
| Fichier | Lignes modifiées | Type de changement |
|---------|------------------|-------------------|
| `kubelet_auto_config.sh` | 86-96, 142-169, 217-236, 286-456, 1045-1061 | Fix critique + validations |

### Fichiers créés
| Fichier | Rôle |
|---------|------|
| `.git/hooks/pre-commit` | Détection BOM UTF-8 |
| `tests/test_calculations.sh` | Tests unitaires |
| `tests/README.md` | Documentation tests |
| `CHANGELOG_v2.0.7.md` | Ce fichier |

---

## 🎯 Plan de déploiement

### Étape 1 : Validation locale
```bash
# Vérification syntaxe
bash -n kubelet_auto_config.sh

# Tests unitaires
cd tests && ./test_calculations.sh

# Test dry-run sur VM
sudo ./kubelet_auto_config.sh --dry-run
```

### Étape 2 : Test sur nœud de staging
```bash
# Application avec backup
sudo ./kubelet_auto_config.sh --profile gke --backup

# Vérification kubelet
systemctl status kubelet
kubectl describe node $(hostname) | grep -A5 Allocatable
```

### Étape 3 : Déploiement production
```bash
# Rollout progressif
# - 1 nœud test → attendre 24h
# - 10% des nœuds → attendre 48h
# - 100% des nœuds
```

---

## 🚨 Breaking Changes

**Aucun breaking change** - Rétrocompatibilité complète avec v2.0.6.

---

## 📝 Notes pour les développeurs

### Bonnes pratiques ajoutées
1. **Toujours normaliser les décimales** avant usage dans `(( ))`
2. **Utiliser `bc` avec `/1`** pour forcer la conversion en entier
3. **Valider les résultats** après chaque calcul critique
4. **Tester avec des valeurs décimales** (cas ARM64)

### Exemple de pattern correct
```bash
# Normaliser d'abord
local ram_gib_int
ram_gib_int=$(printf "%.0f" "$ram_gib")

# Ensuite utiliser dans (( ))
local sys_mem_kernel=$((ram_gib_int * 11))

# OU utiliser bc directement
local sys_mem
sys_mem=$(echo "scale=0; (1024 + ($ram_mib * 0.02)) / 1" | bc)

# Puis valider
validate_calculated_value "$sys_mem" "system-reserved Memory" 100
```

---

## 🔗 Références
- Issue #1 : Crash arithmétique décimale sur ARM64
- Issue #2 : Lock file persistence après crash
- Issue #3 : Valeurs YAML avec décimales

---

**Auteur :** Plateform team
**Reviewers :** @omegabk
**Status :** ✅ Ready for production
