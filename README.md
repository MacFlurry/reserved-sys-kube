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

**✨ Installation automatique** : Le script installe automatiquement les dépendances manquantes (bc, jq, yq v4) au premier lancement. Aucune action préalable requise !

Le script nécessite les outils suivants :
- `bc` : Calculs arithmétiques
- `jq` : Traitement JSON
- `yq` v4+ (mikefarah) : Traitement YAML

**Installation automatique** :
```bash
# Les dépendances sont installées automatiquement lors de l'exécution
sudo ./kubelet_auto_config.sh --dry-run
# Le script détecte et installe bc, jq, et yq v4 si nécessaire
```

**Installation manuelle** (optionnelle) :
```bash
sudo apt update
sudo apt install -y bc jq

# Installer yq (>= v4) - le paquet Ubuntu (v3) n'est pas compatible
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)   YQ_BIN=yq_linux_amd64 ;;
  arm64|aarch64)  YQ_BIN=yq_linux_arm64 ;;
  *) echo "Architecture non supportée: $ARCH" >&2; exit 1 ;;
esac

sudo wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v4.44.3/${YQ_BIN}"
sudo chmod +x /usr/local/bin/yq

# Vérifier la version
yq --version
```

> ℹ️ **Important** : le script installe automatiquement `yq` **v4+** (binaire mikefarah).
> Si `yq` Python v3 est déjà installé, le script le remplace automatiquement par la bonne version.
> Le paquet `apt install yq` installe la version Python 3.x qui provoque des erreurs `yq: -i/--in-place can only be used with -y/-Y`.
> Consultez les binaires officiels : https://github.com/mikefarah/yq/releases

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

Le **density-factor** est un multiplicateur appliqué aux réservations pour **adapter les ressources kubelet selon la charge**.

**Pourquoi ?** Plus il y a de pods sur un nœud, plus kubelet consomme de ressources :

- **Réconciliation** : Kubelet vérifie l'état de chaque pod toutes les 10 secondes (PLEG - Pod Lifecycle Event Generator)
- **Health checks** : Exécution des liveness/readiness probes de tous les pods
- **API calls** : Communication avec l'API server et le container runtime (containerd/CRI-O)
- **Logging & metrics** : Collecte de logs et métriques de tous les containers
- **Watch operations** : Surveillance des changements d'état des pods, secrets, configmaps

**Règle simple** :
- **30 pods** → density-factor **1.0** (baseline, réservations de base)
- **80 pods** → density-factor **1.2** (+20% de ressources pour kubelet)
- **110 pods** → density-factor **1.5** (+50% de ressources pour kubelet)

💡 **Le script calcule automatiquement** le bon facteur avec `--target-pods` !

### Tableau de recommandations

| Pods/nœud | Density-factor | Commande |
|-----------|----------------|----------|
| **0-30** (faible) | `1.0` (baseline) | Par défaut |
| **31-50** (standard) | `1.1` (+10%) | `--density-factor 1.1` |
| **51-80** (élevée) | `1.2` (+20%) | `--density-factor 1.2` |
| **81-110** (très élevée) | `1.5` (+50%) | `--density-factor 1.5` ou `--target-pods 110`* |
| **>110** (extrême) | `2.0` (+100%) | `--density-factor 2.0` + augmenter `maxPods` |

> ⚠️ *Sur des nœuds modestes (≤ 2 vCPU / ≤ 2 GiB), le script refusera ces facteurs élevés :
> il arrête l’exécution si l’allocatable projeté descend sous 25 % CPU ou 20 % RAM (30 %/25 %
> pour un control-plane). Prévoyez des machines plus capacitaires avant de pousser la densité.*

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
# Sur un control-plane, le facteur est plafonné à 1.0 : un warning signalera l'ajustement.
# Sur un worker avec peu de mémoire, le script peut refuser cette configuration.
```

#### Cluster avec 110 pods/nœud (limite maximale)
```bash
# Calcul automatique du facteur
sudo ./kubelet_auto_config.sh --profile conservative --target-pods 110 --backup
# Si les ressources sont insuffisantes, le script refusera (allocatable < seuil minimal).

# Ou manuellement
sudo ./kubelet_auto_config.sh --profile conservative --density-factor 1.5 --backup
# Sur control-plane, le facteur sera ramené automatiquement à 1.0.
# Sur petit worker, la commande peut être bloquée car les réservations dépassent la capacité.
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

> 💡 **Pré-requis** : accès SSH sans mot de passe (clé) et paquets `bc`, `jq`, `yq >= 4` déjà installés
> sur chaque nœud. Adaptez `SSH_USER`/`SSH_OPTS` à votre contexte (`root`, `vagrant`, `ec2-user`, etc.).

```bash
#!/bin/bash
# deploy-manual.sh

SSH_USER="root"
SSH_OPTS=""  # Exemple : "-F ~/.ssh/config" ou "-o StrictHostKeyChecking=no"
NODES="node1 node2"  # Liste de vos nœuds
PROFILE="conservative"
TARGET_PODS="110"

for node in $NODES; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Configuration du nœud : $node"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Copier le script
    scp $SSH_OPTS kubelet_auto_config.sh ${SSH_USER}@$node:/tmp/
    
    # Exécuter
    ssh $SSH_OPTS ${SSH_USER}@$node "chmod +x /tmp/kubelet_auto_config.sh && \
                    /tmp/kubelet_auto_config.sh \
                    --profile $PROFILE \
                    --target-pods $TARGET_PODS \
                    --backup"
    
    # Vérifier le status
    ssh $SSH_OPTS ${SSH_USER}@$node "systemctl is-active kubelet"
    
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

> ℹ️ Sur des nœuds de faible capacité (≤ 2 vCPU / ≤ 2 GiB RAM), `--target-pods 110` peut être refusé
> car l’allocatable tomberait sous les seuils de sécurité. Commencez par le profil `gke` ou réduisez
> le `density-factor`.
```

---

### Méthode 2 : Déploiement via Ansible (recommandé)

> ✅ **Validé sur lab Vagrant** : Cette méthode a été testée et validée (voir [ansible/README.md](ansible/README.md))

**Fichier** : `ansible/deploy-kubelet-config.yml` (version simplifiée)

```yaml
---
- name: Configuration des réservations kubelet
  hosts: k8s_workers
  become: yes
  vars:
    profile: "gke"
    target_pods: 110
    backup_enabled: true

  tasks:
    - name: Vérifier dépendances (bc, jq)
      package:
        name: [bc, jq]
        state: present

    - name: Installer yq si nécessaire
      # Installation automatique de yq v4
      # (voir playbook complet pour les détails)

    - name: Copier le script
      copy:
        src: kubelet_auto_config.sh
        dest: /usr/local/bin/kubelet_auto_config.sh
        mode: '0755'

    - name: Dry-run
      command: >
        /usr/local/bin/kubelet_auto_config.sh
        --profile {{ profile }}
        --target-pods {{ target_pods }}
        --dry-run
      failed_when: false

    - name: Appliquer configuration
      command: >
        /usr/local/bin/kubelet_auto_config.sh
        --profile {{ profile }}
        --target-pods {{ target_pods }}
        --backup

    - name: Vérifier kubelet
      systemd:
        name: kubelet
        state: started
```

**Inventory** : `ansible/inventory.ini`

```ini
[k8s_workers]
node1.example.com
node2.example.com

[k8s_workers:vars]
ansible_user=root
ansible_ssh_private_key_file=~/.ssh/id_rsa
```

**Exécution** :

```bash
# Installer Ansible
sudo apt update && sudo apt install -y ansible

# Test de connectivité
cd ansible
ansible -i inventory.ini all -m ping

# Déploiement
ansible-playbook -i inventory.ini deploy-kubelet-config.yml

# Personnalisation
ansible-playbook -i inventory.ini deploy-kubelet-config.yml \
  -e "profile=conservative" \
  -e "target_pods=80"
```

**Résultats validés** (lab Vagrant, profil `gke`) :

```
PLAY RECAP:
  cp1  : ok=14   changed=4    failed=0
  w1   : ok=13   changed=4    failed=0

Allocatable:
  - cp1: 2670m CPU, 2.96 GiB RAM
  - w1:  1700m CPU, 1.08 GiB RAM
```

> ⚠️ **Garde-fous** : Sur des nœuds contraints (≤ 2 vCPU / ≤ 2 GiB), les configurations agressives seront refusées (allocatable < 25% CPU / 20% RAM).

📖 **Documentation complète** : Voir **[ansible/README.md](ansible/README.md)** pour :
- Playbook complet avec installation automatique de yq
- Configuration inventory (depuis poste ou nœud cluster)
- Guide troubleshooting détaillé
- Exemples d'exécution complets

---

### Méthode 3 : Déploiement via DaemonSet (avancé)

> ✅ **Validé sur lab Vagrant** : Cette méthode a été testée avec succès (voir [daemonset/README.md](daemonset/README.md))

⚠️ **Attention** : Cette méthode nécessite des privilèges élevés (`privileged: true`, `hostPath`)
- À utiliser uniquement dans des environnements contrôlés
- Validation sécurité requise avant usage en production
- Non adaptée aux nœuds très contraints (< 25% CPU / < 20% RAM après config)

**Script de déploiement** : `daemonset/generate-daemonset.sh`

```bash
#!/bin/bash
# Déploiement automatique du DaemonSet

cd daemonset

# 1. Créer le ConfigMap avec le script
kubectl create configmap kubelet-config-script \
  --from-file=kubelet_auto_config.sh=../kubelet_auto_config.sh \
  --namespace=kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Déployer le DaemonSet
kubectl apply -f kubelet-config-daemonset-only.yaml

# 3. Vérifier les pods
kubectl get pods -n kube-system -l app=kubelet-config-updater -o wide
```

**Surveillance** :

```bash
# Suivre les logs de tous les pods
kubectl logs -n kube-system -l app=kubelet-config-updater -f

# Logs d'un pod spécifique
kubectl logs -n kube-system kubelet-config-updater-xxxxx

# Si kubectl logs ne fonctionne pas, utiliser crictl sur le nœud
ssh node1 "sudo crictl logs <container-id>"
```

**Vérification** :

```bash
# Vérifier l'allocatable après application
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
CPU-ALLOC:.status.allocatable.cpu,\
MEM-ALLOC:.status.allocatable.memory
```

**Nettoyage** :

```bash
# Supprimer le DaemonSet après application
kubectl delete daemonset -n kube-system kubelet-config-updater
kubectl delete configmap -n kube-system kubelet-config-script
```

**Personnalisation** : Éditez `daemonset/kubelet-config-daemonset-only.yaml` pour modifier le profil ou target-pods :

```yaml
chroot /host /tmp/kubelet_auto_config.sh \
  --profile gke \            # ou eks, conservative, minimal
  --target-pods 80 \         # ajuster selon votre densité
  --backup
```

📖 **Documentation complète** : Voir **[daemonset/README.md](daemonset/README.md)** pour :
- Guide de déploiement détaillé (automatique et manuel)
- Surveillance avec kubectl et crictl
- Troubleshooting complet
- Comparaison avec les Méthodes 1 & 2
- Résultats de validation sur lab réel
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
# .0 = configuration actuelle, .1 = précédente, etc.

# Lister les backups rotatifs disponibles
ls -lht /var/lib/kubelet/config.yaml.last-success.*

# Revenir à la dernière configuration stable (1 changement en arrière)
sudo cp /var/lib/kubelet/config.yaml.last-success.1 /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet

# Revenir 2 changements en arrière
sudo cp /var/lib/kubelet/config.yaml.last-success.2 /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet

# Revenir 3 changements en arrière (si disponible)
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
# Script fourni dans le dépôt : rollback-kubelet-config.sh

# Restaurer automatiquement la configuration précédente
sudo ./rollback-kubelet-config.sh

# Voir le backup sélectionné sans appliquer
sudo ./rollback-kubelet-config.sh --dry-run

# Restaurer un backup précis (.last-success.2)
sudo ./rollback-kubelet-config.sh --index 2

# Restaurer sans redémarrer kubelet (à faire manuellement ensuite)
sudo ./rollback-kubelet-config.sh --no-restart
```

Le script :
- ignore `.last-success.0` (configuration actuelle) et restaure par défaut `.1` ;
- bascule automatiquement vers les backups permanents (`--backup`) si besoin ;
- expose des options `--index`, `--dry-run`, `--no-restart`.

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

**⚠️ Note** : Depuis la **v2.0.16**, le script installe **automatiquement** les dépendances manquantes (`bc`, `jq`, `yq v4`). Ce problème ne devrait plus se produire.

**Si le problème persiste** :

1. **Vérifier les permissions** : Le script a besoin de `sudo` pour installer les dépendances
   ```bash
   sudo ./kubelet_auto_config.sh
   ```

2. **Vérifier la connectivité Internet** : Le script télécharge `yq` depuis GitHub
   ```bash
   ping -c 3 github.com
   ```

3. **Installation manuelle** (si nécessaire) :
   ```bash
   sudo apt update && sudo apt install -y bc jq systemd

   # Pour yq v4
   ARCH=$(uname -m)
   case "$ARCH" in
     x86_64|amd64)   YQ_BIN=yq_linux_amd64 ;;
     arm64|aarch64)  YQ_BIN=yq_linux_arm64 ;;
   esac
   sudo wget -qO /usr/local/bin/yq \
     "https://github.com/mikefarah/yq/releases/download/v4.44.3/${YQ_BIN}"
   sudo chmod +x /usr/local/bin/yq

   # Vérifier
   which bc jq yq systemctl
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

### Lab de monitoring complet

Un environnement de monitoring complet (Prometheus + Grafana + Alerting) est disponible dans **`tests/kubelet-alerting-lab/`**.

**Contenu du lab** :
- 🎯 Dashboard Grafana prêt à l'emploi (JSON)
- 📈 Recording rules Prometheus (métriques custom)
- 🚨 Alerting rules (5 alertes recommandées)
- 📖 Guide de déploiement complet avec kube-prometheus-stack

**Déploiement rapide** :
```bash
cd tests/kubelet-alerting-lab
# Suivre le README.md pour déployer sur votre cluster
```

**Ce qui est déployé** :
- Helm chart `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager)
- Metrics Server (métriques CPU/Memory des nœuds)
- PrometheusRules (recording + alerting)
- Dashboard Grafana avec visualisation temps réel

---

### Recording rules Prometheus

**Fichier** : `tests/kubelet-alerting-lab/kubelet-reservations-recordings.yaml`

⚠️ **Prérequis** : Nécessite **kube-prometheus-stack** ou **Prometheus Operator** (PrometheusRule CRD)

Ces recording rules créent des **métriques custom** basées sur vos réservations kubelet :

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kubelet-reservations-recordings
  namespace: monitoring
spec:
  groups:
    - name: kubelet-reservations
      rules:
        # Métriques CPU réservées (en cores)
        - record: kubelet_system_reserved_cpu_cores
        - record: kubelet_kube_reserved_cpu_cores

        # Métriques mémoire réservées (en bytes)
        - record: kubelet_system_reserved_memory_bytes
        - record: kubelet_kube_reserved_memory_bytes
        - record: kubelet_memory_eviction_bytes

        # Métriques en pourcentage de la capacité
        - record: kubelet_system_reserved_cpu_percent
        - record: kubelet_kube_reserved_cpu_percent
        - record: kubelet_system_reserved_memory_percent
        - record: kubelet_kube_reserved_memory_percent
        - record: kubelet_memory_eviction_percent
```

📝 **Important** : Les valeurs dans le fichier YAML sont des exemples. Adaptez-les selon votre configuration réelle (voir le README du lab pour générer automatiquement les bonnes valeurs).

**Déploiement** :
```bash
kubectl apply -f tests/kubelet-alerting-lab/kubelet-reservations-recordings.yaml
```

---

### Dashboard Grafana

**Fichier** : `tests/kubelet-alerting-lab/grafana-dashboard-kubelet-reservations.json`

Le dashboard affiche en temps réel les métriques de réservations kubelet :

**Panneaux inclus** :
- CPU system-reserved et kube-reserved (en cores)
- Mémoire system-reserved, kube-reserved et éviction (en Mi)
- Allocatable CPU et mémoire (capacité disponible pour les pods)
- Pourcentages de réservations par rapport à la capacité
- Graphiques empilés pour visualiser la répartition

**Import du dashboard** :
1. Accéder à Grafana → **Dashboards** → **Import**
2. Copier-coller le contenu du fichier JSON
3. Sélectionner la datasource **Prometheus**
4. Cliquer sur **Import**

Le dashboard utilise les métriques créées par les recording rules ci-dessus.

---

### Alertes recommandées

**Fichier** : `tests/kubelet-alerting-lab/kubelet-reservations-alerts.yaml`

⚠️ **Prérequis** : Nécessite **kube-prometheus-stack** ou **Prometheus Operator** (PrometheusRule CRD)

**Déploiement** :
```bash
kubectl apply -f tests/kubelet-alerting-lab/kubelet-reservations-alerts.yaml
```

**5 alertes implémentées** :

| Alerte | Condition | Durée | Sévérité | Action recommandée |
|--------|-----------|-------|----------|-------------------|
| **KubeletHighCPUThrottling** | Throttling CPU > 10% | 10 min | Warning | Augmenter kube-reserved CPU |
| **KubeletPLEGHighLatency** | PLEG P99 > 5s | 5 min | Warning | Augmenter kube-reserved ou réduire densité pods |
| **KubeletHighMemoryUsage** | RSS kubelet > 4 GiB | 10 min | Warning | Augmenter kube-reserved memory |
| **FrequentPodEvictions** | > 5 évictions/min | 5 min | Critical | Vérifier system-reserved et kube-reserved |
| **NodeLowAllocatable** | Allocatable < 80% capacity | 30 min | Warning | Réservations potentiellement trop élevées |

**Détails des alertes** :

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kubelet-reservations
  namespace: monitoring
spec:
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
            histogram_quantile(0.99, rate(kubelet_pleg_relist_duration_seconds_bucket[5m])) > 5
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
            (kube_node_status_allocatable{resource="cpu"} / kube_node_status_capacity{resource="cpu"}) < 0.8
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Allocatable CPU faible sur {{ $labels.node }}"
            description: "Seulement {{ $value | humanizePercentage }} de CPU allocatable. Réservations potentiellement trop élevées."
```

**Vérification des alertes** :
```bash
# Vérifier que les PrometheusRules sont chargées
kubectl get prometheusrule -n monitoring

# Vérifier les alertes actives dans Prometheus
# Accéder à Prometheus UI → Alerts
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

- **[CHANGELOG_v2.0.16.md](CHANGELOG_v2.0.16.md)** - Version actuelle (installation automatique des dépendances)
- **[CHANGELOG_v2.0.15.md](CHANGELOG_v2.0.15.md)** - Lab monitoring kubelet (Prometheus/Grafana)
- **[CHANGELOG_v2.0.14.md](CHANGELOG_v2.0.14.md)** - Validation complète des 3 méthodes de déploiement
- **[CHANGELOG_v2.0.13.md](CHANGELOG_v2.0.13.md)** - Garde-fous allocatable & diff automatiques
- **[CHANGELOG_v2.0.12.md](CHANGELOG_v2.0.12.md)** - Réservations éphémères adaptatives & robustesse kubelet
- **[CHANGELOG_v2.0.11.md](CHANGELOG_v2.0.11.md)** - Détection automatique control-plane/worker
- **[CHANGELOG_v2.0.10.md](CHANGELOG_v2.0.10.md)** - Correctifs tests critiques
- **[CHANGELOG_v2.0.9.md](CHANGELOG_v2.0.9.md)** - Amélioration UX suite de tests
- **[CHANGELOG_v2.0.8.md](CHANGELOG_v2.0.8.md)** - Correctifs critiques ARM64
- Versions précédentes : voir le dossier `changelogs/` (si créé)

### Version Actuelle : v2.0.16

**Nouveautés v2.0.16 (Installation automatique des dépendances) :**
- ✅ **Installation automatique** : Le script installe automatiquement `bc`, `jq`, et `yq v4` si manquants
- ✅ **Détection d'architecture** : Support ARM64 et AMD64 automatique pour yq
- ✅ **Remplacement automatique** : Remplace yq Python v3 par yq v4 (mikefarah) si détecté
- ✅ **Zero-config** : Une seule commande suffit, aucune préparation manuelle
- ✅ **Gain de temps** : 5-10 minutes économisées par installation
- ✅ **Cohérence** : Même logique que le playbook Ansible

**Versions précédentes notables :**
- v2.0.15 : Lab monitoring kubelet (Prometheus/Grafana, alertes, dashboard)
- v2.0.14 : Validation des 3 méthodes de déploiement (Manuel, Ansible, DaemonSet)
- v2.0.13 : Garde-fous allocatable, diff automatiques, réservations éphémères

**Script version v2.0.13 (inclus) :**
- ✅ Garde-fous : density-factor plafonné sur control-planes, arrêt si allocatable < 25% CPU / 20% RAM
- ✅ Affichage de la variation estimée et réelle d'allocatable
- ✅ Réservations `ephemeral-storage` dynamiques selon capacité nœud
- ✅ Détection automatique control-plane vs worker avec enforcement adapté
- ✅ Support ARM64 complet & suite de tests unitaires (38/38)
- ✅ Compatible `set -euo pipefail`

Voir [CHANGELOG_v2.0.16.md](CHANGELOG_v2.0.16.md) pour les détails complets de la version actuelle.

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

- **GitLab Issues** : https://gitlab.com/omega8280051/reserved-sys-kube/-/issues

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

**Dernière mise à jour** : 22 oct 2025
**Version du projet** : 2.0.16 (script v2.0.13)
**Mainteneur** : Platform Engineering Team
