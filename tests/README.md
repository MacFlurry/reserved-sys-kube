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
| Script manuel (Méthode 1) via `scp/ssh vagrant` | ⚠️ | cp1 plafonne le facteur à 1.0 ; w1 refuse (mémoire insuffisante) |
| `ssh node "sudo kubelet_auto_config.sh --profile gke --dry-run"` (Méthode 3) | ✅ | Exécution distante OK, dry-run sans effets |
| Re-run `sudo ./kubelet_auto_config.sh` (cp1) | ✅ | Δ réel : CPU +855 m, RAM +1860 Mi |

Tous les tests manuels se terminent avec `kubectl get nodes` → `cp1` & `w1` en `Ready`, et les backups `config.yaml.last-success.*` présents.

> Les échecs ci-dessus sont attendus : ils valident les garde-fous introduits en v2.0.13.

### Validation Méthode 2 : Déploiement Ansible

**Date** : 22 octobre 2025
**Contexte** : Validation complète du playbook Ansible sur lab Vagrant

**Configuration** :
- Ansible installé sur `cp1` (control-plane)
- Authentification SSH par clé configurée entre `cp1` et `w1`
- Profil : `gke`
- Density-factor : 1.50 (appliqué automatiquement via calcul)

**Playbook exécuté** :
```bash
cd /home/vagrant/ansible
ansible-playbook -i inventory-from-cp1.ini deploy-kubelet-config.yml
```

**Résultats** :

| Phase | Status | Détails |
|-------|--------|---------|
| Test connectivité | ✅ | `ansible -i inventory-from-cp1.ini all -m ping` → pong sur cp1 et w1 |
| Installation yq | ✅ | Détecté comme déjà installé, tâche skippée |
| Copie du script | ✅ | `kubelet_auto_config.sh` déployé dans `/usr/local/bin/` |
| Dry-run | ✅ | Réservations calculées et affichées pour cp1 et w1 |
| Pause validation | ⚠️ | Ignorée en mode non-interactif (warning) |
| Application réelle | ✅ | Configuration appliquée sur les 2 nœuds |
| Vérification kubelet | ✅ | Service actif sur cp1 et w1 |
| Vérification nœuds Ready | ✅ | cp1 et w1 en Ready (après 40-50s stabilisation) |

**Play Recap** :
```
cp1        : ok=14   changed=4    unreachable=0    failed=0
w1         : ok=13   changed=4    unreachable=0    failed=0
localhost  : ok=1    changed=0    unreachable=0    failed=0
```

**Allocatable après application** :
- `k8s-lab-cp1` : CPU `2670m/3000m` (89%), RAM `2.96 GiB/3.80 GiB` (78%)
- `k8s-lab-w1` : CPU `1700m/2000m` (85%), RAM `1.08 GiB/1.90 GiB` (57%)

**Observations** :
1. Le playbook gère correctement l'installation automatique de yq si nécessaire
2. Les tasks de vérification post-application fonctionnent avec des retry (6 tentatives, délai 10s)
3. Le mode non-interactif (stdin non disponible) est géré gracieusement avec un warning
4. Les backups timestampés sont créés automatiquement : `/var/lib/kubelet/config.yaml.backup.20251022_124349`

**Fichiers créés** :
- `ansible/README.md` - Documentation complète de la méthode Ansible
- `ansible/deploy-kubelet-config.yml` - Playbook validé
- `ansible/inventory-from-cp1.ini` - Inventory pour exécution depuis un nœud du cluster
- `ansible/inventory.ini` - Inventory pour exécution depuis un poste de travail

**Conclusion** : ✅ La Méthode 2 (Ansible) est **entièrement fonctionnelle** et recommandée pour les déploiements sur clusters multi-nœuds.

---

### Validation Méthode 3 : Déploiement via DaemonSet

**Date** : 22 octobre 2025
**Contexte** : Validation du déploiement via DaemonSet Kubernetes

**Configuration** :
- DaemonSet déployé dans namespace `kube-system`
- ConfigMap créé automatiquement depuis `kubelet_auto_config.sh`
- Image de base : `ubuntu:24.04`
- Privilèges : `privileged: true` + `hostPath` mount
- Profil : `gke`
- Target pods : 80 (density-factor auto-calculé : 1.20)

**Déploiement** :
```bash
cd /home/vagrant/daemonset
./generate-daemonset.sh
```

**Pods créés** :
```
NAME                           READY   STATUS    RESTARTS   AGE   NODE
kubelet-config-updater-8dzj9   1/1     Running   0          2m    k8s-lab-cp1
kubelet-config-updater-cphg2   1/1     Running   0          2m    k8s-lab-w1
```

**Résultats par nœud** :

| Nœud | Type | CPU avant | CPU après | Δ CPU | RAM avant | RAM après | Δ RAM | Status |
|------|------|-----------|-----------|-------|-----------|-----------|-------|--------|
| k8s-lab-cp1 | control-plane | 2670m | 2736m | +66m | 2961 MiB | 3098 MiB | +137 MiB | ✅ |
| k8s-lab-w1 | worker | 1700m | 1760m | +60m | 1109 MiB | 1228 MiB | +119 MiB | ✅ |

**Allocatable final** :
- `k8s-lab-cp1` : CPU `2736m/3000m` (91%), RAM `3098 MiB/3899 MiB` (79%)
- `k8s-lab-w1` : CPU `1760m/2000m` (88%), RAM `1228 MiB/1953 MiB` (63%)

**Observations** :

1. **Installation automatique** :
   - Dépendances (bc, jq, wget) installées dans le conteneur
   - yq v4.44.3 (ARM64) téléchargé et copié sur l'hôte
   - Script copié depuis ConfigMap vers `/tmp/` de l'hôte

2. **Exécution via chroot** :
   - Le script s'exécute dans le contexte de l'hôte via `chroot /host`
   - Détection automatique du type de nœud (control-plane vs worker)
   - Calcul adapté du density-factor pour 80 pods

3. **Logs récupérés** :
   - Sur cp1 : `kubectl logs` fonctionne normalement
   - Sur w1 : `kubectl logs` échoue (pas d'InternalIP)
     - Solution : `sudo crictl logs <container-id>` sur le nœud w1

4. **Backups créés** :
   - Backup permanent : `/var/lib/kubelet/config.yaml.backup.20251022_125910`
   - Backups rotatifs : `.last-success.{0..2}` sur cp1, `.last-success.{0..1}` sur w1

5. **Nettoyage** :
   - DaemonSet et ConfigMap supprimés sans impact sur la configuration kubelet
   - Configurations restent en place après nettoyage

**Fichiers créés** :
- `daemonset/README.md` - Documentation complète de la méthode DaemonSet
- `daemonset/generate-daemonset.sh` - Script de déploiement automatique
- `daemonset/kubelet-config-daemonset-only.yaml` - Définition du DaemonSet

**Avantages constatés** :
- ✅ Déploiement ultra-rapide (tous les nœuds en parallèle)
- ✅ Pas de dépendance SSH/Ansible
- ✅ Installation automatique de toutes les dépendances
- ✅ Logs conservés dans les pods pour audit
- ✅ Adapté pour automatisation CI/CD

**Inconvénients constatés** :
- ⚠️ Nécessite privilèges élevés (`privileged: true`)
- ⚠️ Monte le système de fichiers hôte complet (risque sécurité)
- ⚠️ `kubectl logs` peut échouer sur certains nœuds (nécessite crictl)
- ⚠️ Pods restent actifs (sleep infinity) après exécution

**Conclusion** : ✅ La Méthode 3 (DaemonSet) est **fonctionnelle** et **efficace** pour une automatisation avancée, mais nécessite une validation sécurité approfondie avant usage en production.
