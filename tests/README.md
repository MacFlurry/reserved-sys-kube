# Tests Unitaires - kubelet_auto_config.sh

## Vue d'ensemble

Ce répertoire contient les tests unitaires pour le script `kubelet_auto_config.sh`. Les tests valident les calculs de réservations système et Kubernetes pour différentes configurations de nœuds.

## Structure

```
tests/
├── README.md                 # Ce fichier
└── test_calculations.sh      # Tests unitaires des fonctions calculate_* et helpers
```

## Exécution des tests

### Test complet

```bash
cd tests
./test_calculations.sh
```

Sortie attendue : `38/38 tests` réussis (11 suites).

### Intégration CI/CD

Exemple pour GitLab CI :

```yaml
# .gitlab-ci.yml
test:
  stage: test
  image: ubuntu:22.04
  before_script:
    - apt-get update && apt-get install -y bc
  script:
    - bash -n kubelet_auto_config.sh  # Vérification syntaxe
    - cd tests && ./test_calculations.sh
```

## Scénarios de test couverts

### 1. Profil GKE (Google Kubernetes Engine)
- **Petit nœud** : 2 vCPU, 4 GiB RAM
- **Nœud moyen** : 8 vCPU, 32 GiB RAM
- **Gros nœud** : 48 vCPU, 192 GiB RAM

### 2. Profil EKS (Amazon Elastic Kubernetes Service)
- **Nœud moyen** : 8 vCPU, 32 GiB RAM

### 3. Profil Conservative (Red Hat OpenShift-like)
- **Nœud moyen** : 8 vCPU, 32 GiB RAM

### 4. Profil Minimal
- **Nœud moyen** : 8 vCPU, 32 GiB RAM

### 5. Test de robustesse
- **Gestion des décimales** : Validation avec RAM=3.80 GiB (cas réel ARM64)

### 6. Utilitaires & garde-fous
- `format_diff`
- `normalize_cpu_to_milli`
- `normalize_memory_to_mib`
- Vérification des constantes `MIN_ALLOC_CPU_PERCENT`, `MIN_ALLOC_MEM_PERCENT`, `CONTROL_PLANE_MAX_DENSITY`

## Métriques validées

Pour chaque profil, les tests valident :
- `system-reserved.cpu` (en millicores)
- `system-reserved.memory` (en MiB)
- `kube-reserved.cpu` (en millicores)
- `kube-reserved.memory` (en MiB)

Les suites suplémentaires valident :
- `format_diff` (mise en forme des deltas)
- `normalize_*` (normalisation CPU/mémoire)
- Les constantes de garde (`MIN_ALLOC_*`, `CONTROL_PLANE_MAX_DENSITY`)

## Critères de passage

✅ **Tous les tests doivent passer** (38/38)
- Valeurs exactes pour les CPU (entiers)
- Plages acceptables pour la mémoire (± 5 MiB)
- Aucune valeur décimale dans les résultats
- Pas de plantage avec RAM décimale

## Ajout de nouveaux tests

1. Ajouter une fonction `test_mon_scenario()` :
   - Utilisez les helpers `assert_equals`, `assert_in_range` ou créez vos propres vérifications.
   - Si vous testez une nouvelle fonction utilitaire, pensez à l'ajouter dans `source_functions()`.
2. Enregistrer la suite via `run_test_suite "Description" test_mon_scenario` dans `main()`.
3. Mettre à jour cette documentation et, si besoin, le changelog.

## Debugging

Si un test échoue :

1. **Vérifier la formule** dans `kubelet_auto_config.sh`
2. **Exécuter manuellement** la fonction :
   ```bash
   source ../kubelet_auto_config.sh
   calculate_gke 8 32 31232
   ```
3. **Valider les calculs bc** :
   ```bash
   echo "scale=0; (1024 + (31232 * 0.02)) / 1" | bc
   ```

## Maintenance

- **Mise à jour des tests** : Si les formules de calcul changent, adapter les valeurs attendues
- **Nouveaux profils** : Ajouter des tests pour chaque nouveau profil de calcul
- **Régression** : Conserver les tests historiques pour détecter les régressions

## Tests manuels (lab Vagrant ARM64)

- **Hôte** : macOS (Apple Silicon) + Vagrant VMware Desktop
- **VMs** :
  - `cp1` (control-plane) — 3 vCPU / 3.8 GiB RAM
  - `w1` (worker) — 2 vCPU / 1.9 GiB RAM
- **Préparation** :
  ```bash
  vagrant destroy -f cp1 w1
  vagrant up cp1
  vagrant up w1
  vagrant ssh cp1 -c 'sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_arm64 && sudo chmod +x /usr/local/bin/yq'
  vagrant ssh w1  -c 'sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_arm64 && sudo chmod +x /usr/local/bin/yq'
  ```

### Campagnes exécutées

| Commande | Résultat | Observations |
|----------|----------|--------------|
| `sudo ./kubelet_auto_config.sh` (cp1) | ✅ | Δ réel : CPU −220 m, RAM −609 Mi |
| `sudo ./kubelet_auto_config.sh` (w1)  | ✅ | Δ réel : CPU −200 m, RAM −546 Mi |
| `sudo ./kubelet_auto_config.sh --profile conservative --density-factor 1.5` (cp1) | ⚠️ | Density-factor plafonné à 1.0 sur control-plane (garde-fou) |
| `sudo ./kubelet_auto_config.sh --profile conservative --density-factor 1.5` (w1) | ❌ | Refus : `Réservations mémoire totales (3276 Mi) >= Capacité mémoire (1945 Mi)` |
| `sudo ./kubelet_auto_config.sh --profile gke --density-factor 4 --dry-run` (w1) | ❌ | Refus : `Allocatable mémoire tomberait à 18.00% (< 20%)` |
| Re-run `sudo ./kubelet_auto_config.sh` (cp1) | ✅ | Δ réel : CPU +855 m, RAM +1860 Mi |

Tous les tests manuels se terminent avec `kubectl get nodes` → `cp1` & `w1` en `Ready`, et les backups `config.yaml.last-success.*` présents.

> Les échecs ci-dessus sont attendus : ils valident les garde-fous introduits en v2.0.13.
