# Configuration Automatique des Réservations Kubelet

> Script bash pour configurer dynamiquement `system-reserved` et `kube-reserved` sur des nœuds Kubernetes v1.32+

[![Kubernetes](https://img.shields.io/badge/kubernetes-v1.32-blue.svg)](https://kubernetes.io/)
[![Bash](https://img.shields.io/badge/bash-5.0+-green.svg)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## 📋 Table des matières

- [Vue d'ensemble](#-vue-densemble)
- [Prérequis](#-prérequis)
- [Installation](#-installation)
- [Utilisation](#-utilisation)
- [Profils disponibles](#-profils-disponibles)
- [Density-factor](#%EF%B8%8F-density-factor--adapter-selon-la-densité-de-pods)
- [Exemples d'utilisation](#-exemples-dutilisation)
- [Déploiement sur un cluster](#-déploiement-sur-un-cluster)
- [Validation post-déploiement](#-validation-post-déploiement)
- [Rollback](#-rollback)
- [FAQ](#-faq)
- [Troubleshooting](#-troubleshooting)
- [Monitoring et métriques](#-monitoring-et-métriques)
- [Sécurité et bonnes pratiques](#-sécurité-et-bonnes-pratiques)
- [Ressources supplémentaires](#-ressources-supplémentaires)
- [Contribution](#-contribution)
- [Changelog](#-changelog-et-notes-de-version)
- [Licence](#-licence)
- [Support](#-support)
- [Crédits](#-crédits)

---

## 🎯 Vue d'ensemble

Ce script automatise la configuration des réservations de ressources kubelet (`system-reserved` et `kube-reserved`) en :

- ✅ **Détectant automatiquement** les ressources du nœud (vCPU, RAM)
- ✅ **Calculant les réservations optimales** selon plusieurs profils (GKE, EKS, Conservative, Minimal)
- ✅ **Adaptant dynamiquement** selon la densité de pods cible (via `density-factor`)
- ✅ **Générant la configuration kubelet** complète
- ✅ **Appliquant et validant** la configuration

### Pourquoi ce script ?

Les réservations `system-reserved` et `kube-reserved` sont **critiques** pour la stabilité des nœuds Kubernetes :
- **Sous-dimensionnées** → OOM kills, évictions, node NotReady
- **Sur-dimensionnées** → Gaspillage de capacité allocatable

Ce script applique les **formules officielles** documentées par Google (GKE), Amazon (EKS) et Red Hat (OpenShift).

---

## 🔧 Prérequis

### Système d'exploitation
- Ubuntu 20.04+ avec systemd
- Noyau Linux 5.x+ (pour cgroups v2, recommandé)

### Kubernetes
- Version **v1.26+** (testé sur v1.32)
- Container runtime : **containerd** (recommandé) ou CRI-O
- Kubelet configuré avec `cgroupDriver: systemd`

### Dépendances

Le script nécessite les outils suivants :

```bash
sudo apt update
sudo apt install -y bc jq systemd yq
```

### Permissions

Le script doit être exécuté en tant que **root** ou avec **sudo** :
```bash
sudo ./kubelet_auto_config.sh
```

---

## 📦 Installation

### Méthode 1 : Téléchargement direct

```bash
# Télécharger le script
curl -O https://gitlab.com/omega8280051/reserved-sys-kube/-/raw/main/kubelet_auto_config.sh

# Rendre exécutable
chmod +x kubelet_auto_config.sh

# Vérifier les dépendances
./kubelet_auto_config.sh --help
```

### Méthode 2 : Via Git

```bash
git clone https://gitlab.com/omega8280051/reserved-sys-kube.git
cd reserved-sys-kube
chmod +x kubelet_auto_config.sh
```

### Méthode 3 : Déploiement sur tous les nœuds

```bash
# Copier le script sur tous les nœuds via SSH
NODES="node1 node2 node3"  # Remplacer par vos nœuds
for node in $NODES; do
    scp kubelet_auto_config.sh root@$node:/usr/local/bin/
    ssh root@$node "chmod +x /usr/local/bin/kubelet_auto_config.sh"
done
```

---

## 🚀 Utilisation

### Syntaxe générale

```bash
sudo ./kubelet_auto_config.sh [OPTIONS]
```

### Options disponibles

| Option | Description | Valeur par défaut |
|--------|-------------|-------------------|
| `--profile <profil>` | Profil de calcul : `gke`, `eks`, `conservative`, `minimal` | `gke` |
| `--density-factor <float>` | Multiplicateur pour haute densité (0.1 à 5.0, recommandé 0.5-3.0) | `1.0` |
| `--target-pods <int>` | Nombre de pods cible (calcul auto du density-factor) | - |
| `--node-type <type>` | Type de nœud : `control-plane`, `worker`, `auto` (détection auto) | `auto` |
| `--dry-run` | Affiche la configuration sans l'appliquer | `false` |
| `--backup` | Crée un backup permanent timestampé (en plus des 4 backups rotatifs automatiques) | `false` |
| `--help` | Affiche l'aide | - |

### Workflow recommandé

```
1. Test en dry-run        → Vérifier les valeurs calculées
2. Backup                 → Sauvegarder la config existante
3. Application            → Appliquer la nouvelle config
4. Validation             → Vérifier allocatable et stabilité
```

---

## 📚 Profils disponibles

### 1. **GKE** (Google Kubernetes Engine) - Recommandé

**Cas d'usage** : Clusters production généralistes

**Caractéristiques** :
- Formules officielles Google Cloud
- Équilibre stabilité / capacité
- Testé à grande échelle (>100k nœuds)

**Exemple** :
```bash
sudo ./kubelet_auto_config.sh --profile gke
```

**Résultat typique (16 vCPU / 64 GiB)** :
- system-reserved : `300m CPU, 1123Mi RAM`
- kube-reserved : `220m CPU, 959Mi RAM`
- Allocatable : `15480m CPU, 62.08 GiB RAM`

---

### 2. **EKS** (Amazon Elastic Kubernetes Service)

**Cas d'usage** : Clusters AWS, compatibilité EKS

**Caractéristiques** :
- Formules officielles Amazon EKS
- Réservations par paliers (< 8 vCPU, 8-32 vCPU, > 32 vCPU)

**Exemple** :
```bash
sudo ./kubelet_auto_config.sh --profile eks
```

---

### 3. **Conservative** (OpenShift-like)

**Cas d'usage** : Environnements critiques, workloads sensibles

**Caractéristiques** :
- Inspiré de Red Hat OpenShift
- Réservations majorées (+30-50% vs GKE)
- Privilégie la stabilité sur la capacité

**Exemple** :
```bash
sudo ./kubelet_auto_config.sh --profile conservative
```

**Résultat typique (16 vCPU / 64 GiB)** :
- system-reserved : `660m CPU, 2355Mi RAM`
- kube-reserved : `740m CPU, 4301Mi RAM`
- Allocatable : `14600m CPU, 57.52 GiB RAM`

---

### 4. **Minimal**

**Cas d'usage** : Environnements dev/test, maximiser allocatable

**Caractéristiques** :
- Réservations minimales
- ⚠️ **Attention** : Monitoring requis, risque instabilité

**Exemple** :
```bash
sudo ./kubelet_auto_config.sh --profile minimal --dry-run
```

---

## 🖥️ Détection automatique Control-Plane vs Worker

### Pourquoi cette distinction ?

Le script détecte automatiquement le type de nœud et adapte la configuration `enforceNodeAllocatable` :

| Type | enforceNodeAllocatable | Raison |
|------|------------------------|--------|
| **Control-plane** | `["pods", "system-reserved"]` | Les static pods critiques (kube-apiserver, etcd, etc.) doivent démarrer **avant** le kubelet. Si `kube-reserved` est enforced, ces pods ne peuvent pas démarrer → cluster cassé. |
| **Worker** | `["pods", "system-reserved", "kube-reserved"]` | Enforcement complet recommandé pour maximiser la stabilité. |

### Détection automatique (par défaut)

Le script détecte automatiquement le type en vérifiant la présence de static pods dans `/etc/kubernetes/manifests/` :

```bash
# Exécution normale (détection auto)
sudo ./kubelet_auto_config.sh

# Sortie sur un control-plane :
# [INFO] Détection du type de nœud...
# [SUCCESS] Nœud détecté: CONTROL-PLANE (static pods détectés dans /etc/kubernetes/manifests)
# [WARNING] Mode control-plane: kube-reserved ne sera PAS enforced (pour préserver les static pods critiques)

# Sortie sur un worker :
# [INFO] Détection du type de nœud...
# [SUCCESS] Nœud détecté: WORKER (aucun static pod control-plane trouvé)
# [INFO] Mode worker: kube-reserved sera enforced normalement
```

### Override manuel (si nécessaire)

Dans de rares cas, vous pouvez forcer le type manuellement :

```bash
# Forcer mode control-plane
sudo ./kubelet_auto_config.sh --node-type control-plane

# Forcer mode worker
sudo ./kubelet_auto_config.sh --node-type worker

# Mode auto (par défaut, peut être omis)
sudo ./kubelet_auto_config.sh --node-type auto
```

### Important : Control-planes avec taints

Si vos control-planes ont des **taints** et n'exécutent jamais de workloads utilisateur, vous pouvez réduire les réservations :

```bash
# Control-plane dédié (pas de workloads)
sudo ./kubelet_auto_config.sh --profile minimal --node-type control-plane

# Control-plane mixte (avec workloads)
sudo ./kubelet_auto_config.sh --profile gke --node-type control-plane
```

---

## 🎛️ Density-factor : Adapter selon la densité de pods

### Concept

Le **density-factor** est un multiplicateur appliqué aux réservations pour compenser la charge kubelet selon le nombre de pods par nœud.

### Tableau de recommandations

| Pods/nœud | Density-factor | Commande |
|-----------|----------------|----------|
| **0-30** (faible) | `1.0` (baseline) | Par défaut |
| **31-50** (standard) | `1.1` (+10%) | `--density-factor 1.1` |
| **51-80** (élevée) | `1.2` (+20%) | `--density-factor 1.2` |
| **81-110** (très élevée) | `1.5` (+50%) | `--density-factor 1.5` ou `--target-pods 110` |
| **>110** (extrême) | `2.0` (+100%) | `--density-factor 2.0` + augmenter `maxPods` |

### Calcul automatique

Le script peut **calculer automatiquement** le density-factor :

```bash
# Cluster avec 110 pods/nœud maximum
sudo ./kubelet_auto_config.sh --profile conservative --target-pods 110

# Le script calcule automatiquement : density-factor = 1.5
```

### Exemples concrets

#### Cluster avec 20 pods/nœud (faible densité)
```bash
# Pas de facteur nécessaire
sudo ./kubelet_auto_config.sh --profile gke
```

#### Cluster avec 80 pods/nœud (haute densité)
```bash
# Facteur 1.2 recommandé
sudo ./kubelet_auto_config.sh --profile conservative --density-factor 1.2
```

#### Cluster avec 110 pods/nœud (limite maximale)
```bash
# Calcul automatique du facteur
sudo ./kubelet_auto_config.sh --profile conservative --target-pods 110 --backup

# Ou manuellement
sudo ./kubelet_auto_config.sh --profile conservative --density-factor 1.5 --backup
```

---

## 📖 Exemples d'utilisation

### Exemple 1 : Premier test (dry-run)

```bash
# Voir la configuration qui serait appliquée, sans toucher au système
sudo ./kubelet_auto_config.sh --dry-run

# Sortie :
# ═══════════════════════════════════════════════════════════════════════════
#   CONFIGURATION KUBELET - RÉSERVATIONS CALCULÉES
# ═══════════════════════════════════════════════════════════════════════════
# 
# Configuration nœud:
#   vCPU:              16
#   RAM:               64 GiB
#   Profil:            gke
#   Density-factor:    1.0
# [...]
```

### Exemple 2 : Configuration standard production

```bash
# Nœud généraliste, 30-50 pods maximum
sudo ./kubelet_auto_config.sh --profile gke --backup

# Vérifier les logs kubelet
sudo journalctl -u kubelet -f
```

### Exemple 3 : Cluster haute densité (110 pods/nœud)

```bash
# Étape 1 : Dry-run pour vérifier
sudo ./kubelet_auto_config.sh \
  --profile conservative \
  --target-pods 110 \
  --dry-run

# Étape 2 : Application avec backup
sudo ./kubelet_auto_config.sh \
  --profile conservative \
  --target-pods 110 \
  --backup

# Étape 3 : Validation
kubectl describe node $(hostname) | grep -A 10 Allocatable
```

### Exemple 4 : Configuration personnalisée

```bash
# Profil conservative avec facteur custom
sudo ./kubelet_auto_config.sh \
  --profile conservative \
  --density-factor 1.3 \
  --backup
```

### Exemple 5 : Environnement dev/test (minimal)

```bash
# Maximiser la capacité allocatable (avec précaution)
sudo ./kubelet_auto_config.sh \
  --profile minimal \
  --dry-run  # Toujours tester d'abord !
```

---

## 🌐 Déploiement sur un cluster

### Architecture cible

**Exemple** : Cluster de 220 nœuds avec 110 pods/nœud
- **Total** : 24,200 pods dans le cluster
- **Profil** : Conservative + density-factor 1.5

### Stratégie de déploiement progressive

```
Phase 1 : 1 nœud pilote     → Validation 24-48h
Phase 2 : 10% (22 nœuds)    → Validation 7 jours
Phase 3 : 50% (110 nœuds)   → Validation 7 jours
Phase 4 : 100% (220 nœuds)  → Rollout complet
```

---

### Méthode 1 : Déploiement manuel (petit cluster)

```bash
#!/bin/bash
# deploy-manual.sh

NODES="node1 node2 node3 node4 node5"  # Liste de vos nœuds
PROFILE="conservative"
TARGET_PODS="110"

for node in $NODES; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Configuration du nœud : $node"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Copier le script
    scp kubelet_auto_config.sh root@$node:/tmp/
    
    # Exécuter
    ssh root@$node "chmod +x /tmp/kubelet_auto_config.sh && \
                    /tmp/kubelet_auto_config.sh \
                    --profile $PROFILE \
                    --target-pods $TARGET_PODS \
                    --backup"
    
    # Vérifier le status
    ssh root@$node "systemctl is-active kubelet"
    
    echo ""
    echo "✓ Nœud $node configuré"
    echo ""
    sleep 5
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Déploiement terminé sur tous les nœuds"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

**Exécution** :
```bash
chmod +x deploy-manual.sh
./deploy-manual.sh
```

---

### Méthode 2 : Déploiement via Ansible (recommandé)

**Fichier** : `deploy-kubelet-config.yml`

```yaml
---
- name: Configuration des réservations kubelet sur tous les nœuds
  hosts: k8s_workers
  become: yes
  vars:
    profile: "conservative"
    target_pods: 110
    backup_enabled: true
  
  tasks:
    - name: Vérifier les dépendances
      package:
        name:
          - bc
          - jq
          - systemd
        state: present
    
    - name: Copier le script de configuration
      copy:
        src: kubelet_auto_config.sh
        dest: /usr/local/bin/kubelet_auto_config.sh
        mode: '0755'
        owner: root
        group: root
    
    - name: Exécuter la configuration (dry-run)
      command: >
        /usr/local/bin/kubelet_auto_config.sh
        --profile {{ profile }}
        --target-pods {{ target_pods }}
        --dry-run
      register: dryrun_output
      changed_when: false
    
    - name: Afficher le résultat du dry-run
      debug:
        var: dryrun_output.stdout_lines
    
    - name: Pause pour validation
      pause:
        prompt: "Vérifiez les résultats dry-run. Continuer ? (Ctrl+C pour annuler)"
      when: ansible_check_mode == false
    
    - name: Appliquer la configuration kubelet
      command: >
        /usr/local/bin/kubelet_auto_config.sh
        --profile {{ profile }}
        --target-pods {{ target_pods }}
        {% if backup_enabled %}--backup{% endif %}
      register: apply_output
    
    - name: Afficher le résultat de l'application
      debug:
        var: apply_output.stdout_lines
    
    - name: Vérifier le status kubelet
      systemd:
        name: kubelet
        state: started
        enabled: yes
      register: kubelet_status
    
    - name: Attendre la stabilisation
      wait_for:
        timeout: 30
      delegate_to: localhost
    
    - name: Vérifier que le nœud est Ready
      shell: kubectl get node {{ inventory_hostname }} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
      delegate_to: localhost
      register: node_ready
      until: node_ready.stdout == "True"
      retries: 6
      delay: 10
    
    - name: Afficher l'allocatable du nœud
      shell: kubectl describe node {{ inventory_hostname }} | grep -A 10 "Allocatable:"
      delegate_to: localhost
      register: allocatable
    
    - debug:
        var: allocatable.stdout_lines

- name: Rapport final
  hosts: localhost
  gather_facts: no
  tasks:
    - name: Récapitulatif des nœuds configurés
      debug:
        msg: "Configuration appliquée sur {{ groups['k8s_workers'] | length }} nœuds"
```

**Inventory Ansible** : `inventory.ini`

```ini
[k8s_workers]
node1.example.com
node2.example.com
node3.example.com
# ... (tous vos nœuds)

[k8s_workers:vars]
ansible_user=root
ansible_ssh_private_key_file=~/.ssh/id_rsa
```

**Exécution** :

```bash
# Dry-run sur tous les nœuds
ansible-playbook -i inventory.ini deploy-kubelet-config.yml --check

# Application réelle
ansible-playbook -i inventory.ini deploy-kubelet-config.yml

# Application sur un groupe spécifique (phase progressive)
ansible-playbook -i inventory.ini deploy-kubelet-config.yml --limit "node[1:22]"
```

---

### Méthode 3 : Déploiement via DaemonSet (avancé)

⚠️ **Attention** : Cette méthode nécessite des privilèges élevés (hostPath, privileged)

**Fichier** : `kubelet-config-daemonset.yaml`

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kubelet-config-updater
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: kubelet-config-updater
  template:
    metadata:
      labels:
        app: kubelet-config-updater
    spec:
      hostNetwork: true
      hostPID: true
      priorityClassName: system-node-critical
      tolerations:
      - effect: NoSchedule
        operator: Exists
      containers:
      - name: updater
        image: ubuntu:22.04
        command:
        - /bin/bash
        - -c
        - |
          # Installation des dépendances
          apt update && apt install -y bc jq systemd
          
          # Copier le script depuis ConfigMap
          cp /scripts/kubelet_auto_config.sh /tmp/
          chmod +x /tmp/kubelet_auto_config.sh
          
          # Exécuter la configuration
          chroot /host /tmp/kubelet_auto_config.sh \
            --profile conservative \
            --target-pods 110 \
            --backup
          
          # Marquer comme terminé
          echo "Configuration terminée sur $(hostname)"
          sleep infinity
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-root
          mountPath: /host
        - name: scripts
          mountPath: /scripts
      volumes:
      - name: host-root
        hostPath:
          path: /
      - name: scripts
        configMap:
          name: kubelet-config-script
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubelet-config-script
  namespace: kube-system
data:
  kubelet_auto_config.sh: |
    # Coller ici le contenu du script bash
```

**Déploiement** :
```bash
kubectl apply -f kubelet-config-daemonset.yaml

# Suivre les logs
kubectl logs -n kube-system -l app=kubelet-config-updater -f

# Supprimer après déploiement
kubectl delete daemonset -n kube-system kubelet-config-updater
```

---

## ✅ Validation post-déploiement

### 1. Vérifier l'allocatable sur tous les nœuds

```bash
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
CPU-CAP:.status.capacity.cpu,\
CPU-ALLOC:.status.allocatable.cpu,\
MEM-CAP:.status.capacity.memory,\
MEM-ALLOC:.status.allocatable.memory
```

**Sortie attendue** :
```
NAME      CPU-CAP   CPU-ALLOC   MEM-CAP      MEM-ALLOC
node1     16        15480m      67108864Ki   63572992Ki
node2     16        15480m      67108864Ki   63572992Ki
node3     16        15480m      67108864Ki   63572992Ki
```

### 2. Vérifier qu'aucun nœud n'est NotReady

```bash
kubectl get nodes

# Tous les nœuds doivent être Ready
# Si un nœud est NotReady, vérifier les logs :
kubectl describe node <node-name>
```

### 3. Vérifier les cgroups sur un nœud

```bash
# Se connecter à un nœud
ssh node1

# Vérifier la hiérarchie cgroups
systemd-cgls | grep -E "(system.slice|kubepods.slice|kubelet.slice)"

# Sortie attendue :
# ├─system.slice
# │ ├─containerd.service
# │ └─...
# ├─kubelet.slice
# │ └─kubelet.service
# └─kubepods.slice
#   ├─kubepods-burstable.slice
#   └─kubepods-besteffort.slice
```

### 4. Vérifier les métriques kubelet

```bash
# Sur un nœud
curl -s http://localhost:10255/metrics | grep -E "(kubelet_runtime_operations|kubelet_pleg)"

# Métriques clés :
# - kubelet_pleg_relist_duration_seconds : doit être < 5s
# - kubelet_runtime_operations_duration_seconds : doit être < 2s
```

### 5. Vérifier les évictions

```bash
# Aucune éviction due à pression mémoire ne devrait apparaître
kubectl get events --all-namespaces --field-selector reason=Evicted

# Si des évictions apparaissent, augmenter les réservations
```

### 6. Test de charge (optionnel)

```bash
# Déployer un workload de test
kubectl create deployment stress-test --image=polinux/stress \
  --replicas=10 -- stress --cpu 1 --vm 1 --vm-bytes 512M --timeout 300s

# Observer la stabilité des nœuds
watch -n 2 "kubectl top nodes"

# Nettoyer
kubectl delete deployment stress-test
```

---

## 🔄 Rollback

### En cas de problème

Le script v2.0.3+ conserve automatiquement **plusieurs niveaux de backups** pour faciliter les rollbacks.

#### 1. Restaurer depuis les backups rotatifs (automatiques)

```bash
# Le script conserve automatiquement les 4 dernières configurations réussies
# Format : /var/lib/kubelet/config.yaml.last-success.{0,1,2,3}
# .0 = plus récent, .3 = plus ancien

# Lister les backups rotatifs disponibles
ls -lht /var/lib/kubelet/config.yaml.last-success.*

# Revenir à la dernière configuration (1 changement en arrière)
sudo cp /var/lib/kubelet/config.yaml.last-success.0 /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet

# Revenir 2 changements en arrière
sudo cp /var/lib/kubelet/config.yaml.last-success.1 /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet

# Revenir 3 changements en arrière
sudo cp /var/lib/kubelet/config.yaml.last-success.2 /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet

# Revenir 4 changements en arrière (le plus ancien)
sudo cp /var/lib/kubelet/config.yaml.last-success.3 /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet
```

#### 2. Restaurer depuis les backups permanents (--backup)

```bash
# Si vous avez utilisé --backup, des backups permanents timestampés sont conservés
# Format : /var/lib/kubelet/config.yaml.backup.YYYYMMDD_HHMMSS

# Lister les backups permanents
ls -lh /var/lib/kubelet/config.yaml.backup.*

# Restaurer un backup permanent spécifique
sudo cp /var/lib/kubelet/config.yaml.backup.20251021_101234 /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet

# Ou restaurer le dernier backup permanent
LATEST_BACKUP=$(ls -t /var/lib/kubelet/config.yaml.backup.* 2>/dev/null | head -1)
sudo cp "$LATEST_BACKUP" /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet
```

#### 3. Script de rollback automatique

```bash
#!/bin/bash
# rollback-kubelet-config.sh

echo "=== Rollback Configuration Kubelet ==="
echo ""

# Essayer d'abord les backups rotatifs
ROTATIF=$(ls -t /var/lib/kubelet/config.yaml.last-success.* 2>/dev/null | head -1)
if [[ -n "$ROTATIF" ]]; then
    echo "Backup rotatif trouvé : $ROTATIF"
    sudo cp "$ROTATIF" /var/lib/kubelet/config.yaml
    sudo systemctl restart kubelet
    echo "✓ Rollback terminé depuis backup rotatif"
    sudo systemctl status kubelet
    exit 0
fi

# Sinon essayer les backups permanents
PERMANENT=$(ls -t /var/lib/kubelet/config.yaml.backup.* 2>/dev/null | head -1)
if [[ -n "$PERMANENT" ]]; then
    echo "Backup permanent trouvé : $PERMANENT"
    sudo cp "$PERMANENT" /var/lib/kubelet/config.yaml
    sudo systemctl restart kubelet
    echo "✓ Rollback terminé depuis backup permanent"
    sudo systemctl status kubelet
    exit 0
fi

echo "✗ Aucun backup trouvé"
exit 1
```

#### 4. Configuration manuelle d'urgence

Si le kubelet ne démarre plus :

```bash
# Éditer manuellement la config
sudo vi /var/lib/kubelet/config.yaml

# Supprimer ou ajuster les sections systemReserved et kubeReserved
# Exemple minimal qui fonctionne toujours :
# systemReserved:
#   cpu: "100m"
#   memory: "512Mi"
# kubeReserved:
#   cpu: "100m"
#   memory: "512Mi"

# Redémarrer
sudo systemctl restart kubelet
sudo journalctl -u kubelet -f
```

---

## ❓ FAQ

### Q1 : Le script modifie-t-il d'autres paramètres kubelet ?

**R** : Non, le script préserve **intelligemment** vos configurations existantes (depuis v2.0.5).

**Comportement :**
- ✅ **Si `/var/lib/kubelet/config.yaml` existe** : Le script **fusionne** avec la configuration existante
  - Modifie uniquement : `systemReserved`, `kubeReserved`, `enforceNodeAllocatable`, cgroups, seuils d'éviction
  - **Préserve tous les autres paramètres** : `maxPods`, `imageGCHighThresholdPercent`, `rotateCertificates`, etc.
  - Vos tweaks personnalisés sont **conservés** !

- ✅ **Si aucune configuration n'existe** : Le script génère une configuration complète avec les valeurs par défaut Kubernetes

**Exemple :**
```yaml
# Configuration existante avec tweaks
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
maxPods: 150                          # ← Tweak personnalisé
imageGCHighThresholdPercent: 90       # ← Tweak personnalisé
systemReserved:
  cpu: "100m"                         # ← Sera mis à jour par le script
  memory: "512Mi"                     # ← Sera mis à jour par le script

# Après exécution du script
# maxPods et imageGCHighThresholdPercent restent inchangés
# Seuls systemReserved et kubeReserved sont mis à jour
```

### Q2 : Puis-je exécuter le script plusieurs fois ?

**R** : Oui, le script est **idempotent**. Vous pouvez le relancer sans risque.

**Gestion automatique des backups** (depuis v2.0.3) :
- ✅ **4 backups rotatifs automatiques** : Le script conserve automatiquement les 4 dernières configurations réussies (`.last-success.{0,1,2,3}`)
- ✅ **Sans `--backup`** : Rotation automatique, `.0` = plus récent, `.3` = plus ancien
- ✅ **Avec `--backup`** : Crée un backup permanent timestampé (conservé 90 jours) + rotation automatique

**Exemple** :
```bash
# Première exécution
sudo ./kubelet_auto_config.sh --profile gke
# Crée : config.yaml.last-success.0

# Deuxième exécution
sudo ./kubelet_auto_config.sh --profile conservative
# Rotation : .0 → .1
# Crée : config.yaml.last-success.0 (nouveau)

# Rollback vers la config précédente
sudo cp /var/lib/kubelet/config.yaml.last-success.1 /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet
```

### Q3 : Que se passe-t-il si mes pods dépassent l'allocatable après modification ?

**R** : Kubernetes **n'évincera PAS** les pods déjà running. Seuls les nouveaux pods seront soumis aux nouvelles limites. Pour forcer un réajustement :

```bash
# Drainer le nœud (optionnel)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Appliquer la config
sudo ./kubelet_auto_config.sh --profile conservative --target-pods 110 --backup

# Rendre le nœud schedulable
kubectl uncordon <node-name>
```

### Q4 : Comment choisir entre GKE et Conservative ?

| Critère | GKE | Conservative |
|---------|-----|--------------|
| **Environnement** | Prod généraliste | Critique (finance, santé) |
| **Densité** | < 80 pods/nœud | > 80 pods/nœud ou haute criticité |
| **Allocatable** | Maximisé | Réduit de ~15% |
| **Stabilité** | Excellente | Maximale |
| **Recommandation** | ✅ Défaut | Workloads sensibles |

### Q5 : Le script fonctionne-t-il avec cgroups v1 ?

**R** : Oui, le script est compatible cgroups v1 et v2. Il détecte automatiquement la version via `systemd`.

### Q6 : Puis-je personnaliser les valeurs calculées ?

**R** : Le script applique des formules éprouvées. Pour des ajustements fins :

1. Utiliser `--dry-run` pour voir les valeurs
2. Modifier manuellement `/var/lib/kubelet/config.yaml` après exécution
3. Ou éditer le script (section `calculate_XXX()`)

### Q7 : Comment surveiller l'impact des réservations ?

**R** : Métriques Prometheus à surveiller :

```promql
# CPU throttling kubelet (doit être < 5%)
rate(container_cpu_cfs_throttled_seconds_total{container="kubelet"}[5m])

# Mémoire disponible nœud (doit être > 1GiB)
node_memory_MemAvailable_bytes / 1024 / 1024 / 1024

# PLEG latency (doit être < 5s)
kubelet_pleg_relist_duration_seconds{quantile="0.99"}
```

---

## 🐛 Troubleshooting

### Problème 0 : Le script affiche `!/bin/bash` au lieu du message d'aide

**Symptômes** :
```bash
./kubelet_auto_config.sh --help
# !/bin/bash
# ################################################################################
# Script de configuration automatique...
# (Le shebang #! est affiché sans le #)
```

**Cause** : BOM UTF-8 (Byte Order Mark) invisible au début du fichier

**Détection** :
```bash
# Vérifier les 3 premiers octets
hexdump -C kubelet_auto_config.sh | head -1
# Si vous voyez "ef bb bf" → BOM détecté

# Ou avec file
file kubelet_auto_config.sh
# Si vous voyez "UTF-8 Unicode (with BOM)" → BOM détecté
```

**Solution automatique** :
```bash
# Utiliser le script de diagnostic fourni
bash debug_bom.sh

# Ou manuellement :
# 1. Backup
cp kubelet_auto_config.sh kubelet_auto_config.sh.backup

# 2. Supprimer les 3 premiers octets (BOM)
tail -c +4 kubelet_auto_config.sh > kubelet_auto_config.sh.tmp
mv kubelet_auto_config.sh.tmp kubelet_auto_config.sh
chmod +x kubelet_auto_config.sh

# 3. Vérifier
./kubelet_auto_config.sh --help  # Doit afficher l'aide correctement
```

**Prévention** :
- Le hook pre-commit Git détecte automatiquement les BOM
- Éviter d'éditer le script avec des éditeurs Windows (Notepad)
- Utiliser `vim`, `nano`, ou VSCode avec encoding UTF-8 sans BOM

---

### Problème 1 : Kubelet ne démarre pas après application

**Symptômes** :
```bash
sudo systemctl status kubelet
# ● kubelet.service - kubelet: The Kubernetes Node Agent
#    Active: failed (Result: exit-code)
```

**Solution** :
```bash
# Vérifier les logs
sudo journalctl -u kubelet -n 100 --no-pager

# Erreurs fréquentes :
# 1. "failed to parse kubelet config file"
#    → Syntaxe YAML invalide dans /var/lib/kubelet/config.yaml
#    → Restaurer le backup

# 2. "failed to create cgroup"
#    → Vérifier que systemd est bien le cgroup driver
#    → Vérifier : cat /var/lib/kubelet/config.yaml | grep cgroupDriver

# 3. "reservations exceed node capacity"
#    → Les réservations sont trop élevées
#    → Utiliser --profile minimal ou réduire --density-factor
```

### Problème 2 : Allocatable trop faible, pas assez de place pour les pods

**Symptômes** :
```bash
kubectl describe node <node>
# Allocatable:
#   cpu: 100m  # Presque rien !
#   memory: 1Gi
```

**Cause** : Réservations trop élevées (profil conservative + density-factor trop grand)

**Solution** :
```bash
# 1. Vérifier les réservations actuelles
sudo cat /var/lib/kubelet/config.yaml | grep -A 3 "Reserved:"

# 2. Reconfigurer avec un profil moins conservateur
sudo ./kubelet_auto_config.sh --profile gke --backup

# 3. Ou réduire le density-factor
sudo ./kubelet_auto_config.sh --profile conservative --density-factor 1.2 --backup
```

### Problème 3 : Nœud devient NotReady après configuration

**Symptômes** :
```bash
kubectl get nodes
# NAME    STATUS     ROLES    AGE   VERSION
# node1   NotReady   <none>   10d   v1.32.0
```

**Diagnostic** :
```bash
# 1. Vérifier le kubelet
ssh node1 "sudo systemctl status kubelet"

# 2. Vérifier les conditions du nœud
kubectl describe node node1 | grep -A 20 "Conditions:"

# Causes fréquentes :
# - MemoryPressure: True    → system-reserved mémoire trop faible
# - DiskPressure: True      → ephemeral-storage mal configuré
# - NetworkUnavailable      → Problème CNI (non lié au script)
```

**Solution** :
```bash
# Augmenter les réservations
ssh node1 "sudo /usr/local/bin/kubelet_auto_config.sh \
  --profile conservative \
  --density-factor 1.5 \
  --backup"
```

### Problème 4 : Évictions fréquentes après déploiement

**Symptômes** :
```bash
kubectl get events --field-selector reason=Evicted
# REASON    MESSAGE
# Evicted   The node was low on resource: memory
```

**Diagnostic** :
```bash
# Vérifier la pression mémoire sur les nœuds affectés
ssh node1 "cat /sys/fs/cgroup/kubepods.slice/memory.pressure"

# Vérifier la mémoire disponible
ssh node1 "free -h"
```

**Solution** :
```bash
# Augmenter system-reserved et kube-reserved
sudo ./kubelet_auto_config.sh \
  --profile conservative \
  --density-factor 1.5 \
  --backup

# OU ajuster manuellement les seuils d'éviction
sudo vi /var/lib/kubelet/config.yaml
# Modifier :
# evictionHard:
#   memory.available: "1Gi"  # Au lieu de 500Mi
```

### Problème 5 : Script échoue avec "command not found"

**Symptômes** :
```bash
./kubelet_auto_config.sh
# line 42: bc: command not found
```

**Solution** :
```bash
# Installer les dépendances manquantes
sudo apt update && sudo apt install -y bc jq systemd

# Vérifier
which bc jq systemctl
```

### Problème 6 : Permission denied lors de l'exécution

**Symptômes** :
```bash
./kubelet_auto_config.sh
# bash: ./kubelet_auto_config.sh: Permission denied
```

**Solution** :
```bash
# Rendre le script exécutable
chmod +x kubelet_auto_config.sh

# Exécuter avec sudo
sudo ./kubelet_auto_config.sh
```

### Problème 7 : Les cgroups ne sont pas créés

**Symptômes** :
```bash
systemd-cgls | grep kubelet.slice
# (aucun résultat)
```

**Diagnostic** :
```bash
# Vérifier la configuration kubelet
sudo cat /var/lib/kubelet/config.yaml | grep -E "(enforceNodeAllocatable|Cgroup)"

# Vérifier les logs
sudo journalctl -u kubelet | grep -i cgroup
```

**Solution** :
```bash
# S'assurer que enforceNodeAllocatable contient bien :
# - "pods"
# - "system-reserved"
# - "kube-reserved"

# Réappliquer la configuration
sudo ./kubelet_auto_config.sh --profile conservative --backup
```

### Problème 8 : Valeurs différentes entre nœuds du même type

**Symptômes** :
```bash
# node1 : Allocatable 15480m CPU
# node2 : Allocatable 15200m CPU (même config matérielle)
```

**Cause** : Le script a été exécuté avec des paramètres différents

**Solution** :
```bash
# Standardiser sur tous les nœuds
ansible all -i inventory.ini -m shell -a \
  "/usr/local/bin/kubelet_auto_config.sh \
  --profile conservative \
  --target-pods 110 \
  --backup"
```

---

## 📊 Monitoring et métriques

### Dashboards Grafana recommandés

#### Dashboard 1 : Vue d'ensemble des réservations

**Métriques Prometheus** :
```promql
# Allocatable CPU par nœud
kube_node_status_allocatable{resource="cpu",unit="core"}

# Allocatable Memory par nœud
kube_node_status_allocatable{resource="memory",unit="byte"} / 1024 / 1024 / 1024

# Capacity vs Allocatable (ratio de réservation)
(kube_node_status_capacity{resource="cpu"} - kube_node_status_allocatable{resource="cpu"}) 
/ kube_node_status_capacity{resource="cpu"} * 100
```

#### Dashboard 2 : Santé kubelet

```promql
# PLEG latency (doit être < 5s)
histogram_quantile(0.99, 
  rate(kubelet_pleg_relist_duration_seconds_bucket[5m]))

# Throttling CPU kubelet
rate(container_cpu_cfs_throttled_seconds_total{
  container="kubelet"
}[5m]) * 100

# Mémoire RSS kubelet
process_resident_memory_bytes{job="kubelet"} / 1024 / 1024
```

#### Dashboard 3 : Évictions

```promql
# Nombre d'évictions par raison
sum by (reason) (kube_pod_status_reason{reason=~"Evicted|OutOf.*"})

# Taux d'évictions
rate(kube_pod_status_reason{reason="Evicted"}[5m]) * 60
```

### Alertes recommandées

**Fichier** : `kubelet-reservations-alerts.yaml`

```yaml
groups:
- name: kubelet-reservations
  interval: 30s
  rules:
  
  # Alerte : Kubelet CPU throttling élevé
  - alert: KubeletHighCPUThrottling
    expr: |
      rate(container_cpu_cfs_throttled_seconds_total{container="kubelet"}[5m]) > 0.1
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Kubelet throttling CPU élevé sur {{ $labels.node }}"
      description: "Le kubelet sur {{ $labels.node }} subit un throttling CPU de {{ $value | humanizePercentage }}. Augmentez kube-reserved CPU."
  
  # Alerte : PLEG latency trop élevée
  - alert: KubeletPLEGHighLatency
    expr: |
      histogram_quantile(0.99, 
        rate(kubelet_pleg_relist_duration_seconds_bucket[5m])) > 5
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "PLEG latency élevée sur {{ $labels.node }}"
      description: "P99 PLEG latency = {{ $value }}s (seuil: 5s). Considérez augmenter kube-reserved ou réduire la densité de pods."
  
  # Alerte : Mémoire kubelet élevée
  - alert: KubeletHighMemoryUsage
    expr: |
      process_resident_memory_bytes{job="kubelet"} / 1024 / 1024 / 1024 > 4
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Consommation mémoire kubelet élevée sur {{ $labels.instance }}"
      description: "Kubelet utilise {{ $value | humanize }}GiB de RAM. Augmentez kube-reserved memory."
  
  # Alerte : Évictions fréquentes
  - alert: FrequentPodEvictions
    expr: |
      rate(kube_pod_status_reason{reason="Evicted"}[15m]) * 60 > 5
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Évictions fréquentes détectées"
      description: "{{ $value | humanize }} évictions/min. Vérifiez les réservations system-reserved et kube-reserved."
  
  # Alerte : Allocatable très faible
  - alert: NodeLowAllocatable
    expr: |
      (kube_node_status_allocatable{resource="cpu"} / 
       kube_node_status_capacity{resource="cpu"}) < 0.8
    for: 30m
    labels:
      severity: warning
    annotations:
      summary: "Allocatable CPU faible sur {{ $labels.node }}"
      description: "Seulement {{ $value | humanizePercentage }} de CPU allocatable. Réservations potentiellement trop élevées."
```

---

## 🔐 Sécurité et bonnes pratiques

### 1. Permissions du script

```bash
# Le script doit appartenir à root et ne pas être modifiable par d'autres
sudo chown root:root kubelet_auto_config.sh
sudo chmod 750 kubelet_auto_config.sh

# Vérifier
ls -l kubelet_auto_config.sh
# -rwxr-x--- 1 root root 28472 Jan 20 10:30 kubelet_auto_config.sh
```

### 2. Audit trail

```bash
# Toutes les modifications sont logguées dans syslog
sudo grep "configure-kubelet-reservations" /var/log/syslog

# Ou journalctl
sudo journalctl -t configure-kubelet-reservations
```

### 3. Validation avant production

**Checklist** :
- [ ] Testé en dry-run sur 1 nœud de dev
- [ ] Testé en réel sur 1 nœud de dev pendant 24h
- [ ] Vérifié allocatable, pas d'évictions
- [ ] Testé workload réel (charge progressive)
- [ ] Validé par l'équipe infra/ops
- [ ] Documentation mise à jour
- [ ] Procédure de rollback testée

### 4. Versioning du script

```bash
# Ajouter un numéro de version dans le script
VERSION="1.0.0"

# Commit dans Git
git add kubelet_auto_config.sh
git commit -m "feat: script configuration kubelet v1.0.0"
git tag v1.0.0
git push origin v1.0.0
```

---

## 📚 Ressources supplémentaires

### Documentation officielle Kubernetes

- [Reserve Compute Resources](https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/)
- [Node Allocatable Resources](https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/#node-allocatable)
- [Kubelet Configuration Reference](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)

### Documentation cloud providers

- [GKE Node Allocatable](https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-architecture#node_allocatable_resources)
- [EKS Allocatable Capacity](https://docs.aws.amazon.com/eks/latest/userguide/allocatable-capacity.html)
- [AKS Resource Reservations](https://learn.microsoft.com/en-us/azure/aks/concepts-clusters-workloads#resource-reservations)

### Benchmarks et études

- [Kubernetes SIG Scalability Thresholds](https://github.com/kubernetes/community/blob/master/sig-scalability/configs-and-limits/thresholds.md)
- [CNCF Cloud Native Landscape](https://landscape.cncf.io/)

---

## 🤝 Contribution

### Signaler un bug

Ouvrez une issue sur GitHub avec :
- Version du script (voir `--help`)
- Version Kubernetes (`kubectl version`)
- OS et version (`cat /etc/os-release`)
- Logs complets (`journalctl -u kubelet`)

### Proposer une amélioration

1. Fork le repository
2. Créez une branche (`git checkout -b feature/nouvelle-fonctionnalite`)
3. Committez (`git commit -am 'feat: ajout fonctionnalité X'`)
4. Push (`git push origin feature/nouvelle-fonctionnalite`)
5. Ouvrez une Pull Request

---


## 📝 Changelog et Notes de Version

Pour l'historique complet des versions, consultez les fichiers de changelog dédiés :

- **[CHANGELOG_v2.0.11.md](CHANGELOG_v2.0.11.md)** - Version actuelle (détection auto control-plane/worker)
- **[CHANGELOG_v2.0.10.md](CHANGELOG_v2.0.10.md)** - Correctifs tests critiques
- **[CHANGELOG_v2.0.9.md](CHANGELOG_v2.0.9.md)** - Amélioration UX suite de tests
- **[CHANGELOG_v2.0.8.md](CHANGELOG_v2.0.8.md)** - Correctifs critiques ARM64
- Versions précédentes : voir le dossier `changelogs/` (si créé)

### Version Actuelle : v2.0.11

**Nouveautés :**
- ✅ Détection automatique du type de nœud (control-plane vs worker)
- ✅ Adaptation intelligente de `enforceNodeAllocatable` selon le type
- ✅ Option `--node-type` pour override manuel
- ✅ Prévention des crashes de kube-apiserver sur control-planes
- ✅ Rétrocompatible : comportement par défaut optimal pour tous les nœuds

**Hérité de v2.0.10 :**
- ✅ Support ARM64 (arithmétique décimale)
- ✅ Lock file robuste
- ✅ Formatage YAML propre
- ✅ Suite de tests unitaires (25 tests)
- ✅ Tests compatibles `set -euo pipefail`

Voir [CHANGELOG_v2.0.11.md](CHANGELOG_v2.0.11.md) pour les détails complets.

---
## 📄 Licence

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## 🆘 Support

### Communauté

- **GitHub Issues** : [https://gitlab.com/omega8280051/reserved-sys-kube/-/issues](https://gitlab.com)

---

## ✨ Crédits

**Développé par** : un stagiaire nommé Claude. Mais avec un Senior derrière lui quand même. 

**Basé sur** :
- Formules officielles Google (GKE)
- Formules officielles Amazon (EKS)
- Recommandations Red Hat (OpenShift)
- Benchmarks Kubernetes SIG Scalability

**Remerciements** :
- Communauté Kubernetes
- CNCF (Cloud Native Computing Foundation)
- Contributeurs open source

---

**Note** : Ce script a été testé sur les distributions suivantes :
- ✅ Ubuntu 20.04, 22.04, 24.04

**Versions Kubernetes testées** :
- ✅ v1.26.x
- ✅ v1.27.x
- ✅ v1.28.x
- ✅ v1.29.x
- ✅ v1.30.x
- ✅ v1.31.x
- ✅ v1.32.x

---

**Dernière mise à jour** : 21 oct 2025
**Version du script** : 2.0.11
**Mainteneur** : Platform Engineering Team
