# Configuration Automatique des Réservations Kubelet

> Script bash pour configurer dynamiquement `system-reserved` et `kube-reserved` sur des nœuds Kubernetes v1.32+

[![Kubernetes](https://img.shields.io/badge/kubernetes-v1.32-blue.svg)](https://kubernetes.io/)
[![Bash](https://img.shields.io/badge/bash-5.0+-green.svg)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## 📋 Table des matières

- [Vue d'ensemble](#vue-densemble)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Utilisation](#utilisation)
- [Profils disponibles](#profils-disponibles)
- [Exemples d'utilisation](#exemples-dutilisation)
- [Déploiement sur un cluster](#déploiement-sur-un-cluster)
- [Validation post-déploiement](#validation-post-déploiement)
- [Rollback](#rollback)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)

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
- Linux avec systemd (Ubuntu 20.04+, Debian 11+, RHEL 8+, Rocky Linux 8+)
- Noyau Linux 5.x+ (pour cgroups v2, recommandé)

### Kubernetes
- Version **v1.26+** (testé sur v1.32)
- Container runtime : **containerd** (recommandé) ou CRI-O
- Kubelet configuré avec `cgroupDriver: systemd`

### Dépendances

Le script nécessite les outils suivants :

```bash
# Sur Debian/Ubuntu
sudo apt update
sudo apt install -y bc jq systemd yq

# Sur RHEL/Rocky/CentOS
sudo dnf install -y bc jq systemd yq

# Installer yq (si non disponible dans les repos)
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq
sudo chmod +x /usr/bin/yq
```

### Permissions

Le script doit être exécuté en tant que **root** ou avec **sudo** :
```bash
sudo ./configure-kubelet-reservations.sh
```

---

## 📦 Installation

### Méthode 1 : Téléchargement direct

```bash
# Télécharger le script
curl -O https://gitlab.com/omega8280051/reserved-sys-kube/-/raw/main/kubelet_auto_config.sh

# Rendre exécutable
chmod +x configure-kubelet-reservations.sh

# Vérifier les dépendances
./configure-kubelet-reservations.sh --help
```

### Méthode 2 : Via Git

```bash
git clone https://gitlab.com/omega8280051/reserved-sys-kube.git
cd reserved-sys-kube
chmod +x configure-kubelet-reservations.sh
```

### Méthode 3 : Déploiement sur tous les nœuds

```bash
# Copier le script sur tous les nœuds via SSH
NODES="node1 node2 node3"  # Remplacer par vos nœuds
for node in $NODES; do
    scp configure-kubelet-reservations.sh root@$node:/usr/local/bin/
    ssh root@$node "chmod +x /usr/local/bin/configure-kubelet-reservations.sh"
done
```

---

## 🚀 Utilisation

### Syntaxe générale

```bash
sudo ./configure-kubelet-reservations.sh [OPTIONS]
```

### Options disponibles

| Option | Description | Valeur par défaut |
|--------|-------------|-------------------|
| `--profile <profil>` | Profil de calcul : `gke`, `eks`, `conservative`, `minimal` | `gke` |
| `--density-factor <float>` | Multiplicateur pour haute densité (1.0 à 3.0) | `1.0` |
| `--target-pods <int>` | Nombre de pods cible (calcul auto du density-factor) | - |
| `--dry-run` | Affiche la configuration sans l'appliquer | `false` |
| `--backup` | Sauvegarde la configuration existante | `false` |
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
sudo ./configure-kubelet-reservations.sh --profile gke
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
sudo ./configure-kubelet-reservations.sh --profile eks
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
sudo ./configure-kubelet-reservations.sh --profile conservative
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
sudo ./configure-kubelet-reservations.sh --profile minimal --dry-run
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
sudo ./configure-kubelet-reservations.sh --profile conservative --target-pods 110

# Le script calcule automatiquement : density-factor = 1.5
```

### Exemples concrets

#### Cluster avec 20 pods/nœud (faible densité)
```bash
# Pas de facteur nécessaire
sudo ./configure-kubelet-reservations.sh --profile gke
```

#### Cluster avec 80 pods/nœud (haute densité)
```bash
# Facteur 1.2 recommandé
sudo ./configure-kubelet-reservations.sh --profile conservative --density-factor 1.2
```

#### Cluster avec 110 pods/nœud (limite maximale)
```bash
# Calcul automatique du facteur
sudo ./configure-kubelet-reservations.sh --profile conservative --target-pods 110 --backup

# Ou manuellement
sudo ./configure-kubelet-reservations.sh --profile conservative --density-factor 1.5 --backup
```

---

## 📖 Exemples d'utilisation

### Exemple 1 : Premier test (dry-run)

```bash
# Voir la configuration qui serait appliquée, sans toucher au système
sudo ./configure-kubelet-reservations.sh --dry-run

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
sudo ./configure-kubelet-reservations.sh --profile gke --backup

# Vérifier les logs kubelet
sudo journalctl -u kubelet -f
```

### Exemple 3 : Cluster haute densité (110 pods/nœud)

```bash
# Étape 1 : Dry-run pour vérifier
sudo ./configure-kubelet-reservations.sh \
  --profile conservative \
  --target-pods 110 \
  --dry-run

# Étape 2 : Application avec backup
sudo ./configure-kubelet-reservations.sh \
  --profile conservative \
  --target-pods 110 \
  --backup

# Étape 3 : Validation
kubectl describe node $(hostname) | grep -A 10 Allocatable
```

### Exemple 4 : Configuration personnalisée

```bash
# Profil conservative avec facteur custom
sudo ./configure-kubelet-reservations.sh \
  --profile conservative \
  --density-factor 1.3 \
  --backup
```

### Exemple 5 : Environnement dev/test (minimal)

```bash
# Maximiser la capacité allocatable (avec précaution)
sudo ./configure-kubelet-reservations.sh \
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
    scp configure-kubelet-reservations.sh root@$node:/tmp/
    
    # Exécuter
    ssh root@$node "chmod +x /tmp/configure-kubelet-reservations.sh && \
                    /tmp/configure-kubelet-reservations.sh \
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
        src: configure-kubelet-reservations.sh
        dest: /usr/local/bin/configure-kubelet-reservations.sh
        mode: '0755'
        owner: root
        group: root
    
    - name: Exécuter la configuration (dry-run)
      command: >
        /usr/local/bin/configure-kubelet-reservations.sh
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
        /usr/local/bin/configure-kubelet-reservations.sh
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
          cp /scripts/configure-kubelet-reservations.sh /tmp/
          chmod +x /tmp/configure-kubelet-reservations.sh
          
          # Exécuter la configuration
          chroot /host /tmp/configure-kubelet-reservations.sh \
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
  configure-kubelet-reservations.sh: |
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

#### 1. Restaurer depuis le backup

```bash
# Le script crée automatiquement un backup si --backup est utilisé
# Format : /var/lib/kubelet/config.yaml.backup.YYYYMMDD_HHMMSS

# Lister les backups
ls -lh /var/lib/kubelet/config.yaml.backup.*

# Restaurer le dernier backup
LATEST_BACKUP=$(ls -t /var/lib/kubelet/config.yaml.backup.* | head -1)
sudo cp "$LATEST_BACKUP" /var/lib/kubelet/config.yaml

# Redémarrer kubelet
sudo systemctl restart kubelet
```

#### 2. Rollback automatique via script

```bash
#!/bin/bash
# rollback-kubelet-config.sh

LATEST_BACKUP=$(ls -t /var/lib/kubelet/config.yaml.backup.* 2>/dev/null | head -1)

if [[ -z "$LATEST_BACKUP" ]]; then
    echo "Aucun backup trouvé"
    exit 1
fi

echo "Restauration depuis : $LATEST_BACKUP"
sudo cp "$LATEST_BACKUP" /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet

echo "Rollback terminé. Vérifiez le status :"
sudo systemctl status kubelet
```

#### 3. Configuration manuelle d'urgence

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

**R** : Non, le script génère une configuration **complète** mais ne modifie que :
- `systemReserved`
- `kubeReserved`
- `enforceNodeAllocatable`
- Les cgroups associés
- Les seuils d'éviction (valeurs standard)

Tous les autres paramètres conservent leurs valeurs par défaut Kubernetes.

### Q2 : Puis-je exécuter le script plusieurs fois ?

**R** : Oui, le script est **idempotent**. Vous pouvez le relancer sans risque. Utilisez `--backup` pour conserver un historique.

### Q3 : Que se passe-t-il si mes pods dépassent l'allocatable après modification ?

**R** : Kubernetes **n'évincera PAS** les pods déjà running. Seuls les nouveaux pods seront soumis aux nouvelles limites. Pour forcer un réajustement :

```bash
# Drainer le nœud (optionnel)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Appliquer la config
sudo ./configure-kubelet-reservations.sh --profile conservative --target-pods 110 --backup

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
sudo ./configure-kubelet-reservations.sh --profile gke --backup

# 3. Ou réduire le density-factor
sudo ./configure-kubelet-reservations.sh --profile conservative --density-factor 1.2 --backup
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
ssh node1 "sudo /usr/local/bin/configure-kubelet-reservations.sh \
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
sudo ./configure-kubelet-reservations.sh \
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
./configure-kubelet-reservations.sh
# line 42: bc: command not found
```

**Solution** :
```bash
# Installer les dépendances manquantes
# Ubuntu/Debian
sudo apt update && sudo apt install -y bc jq systemd

# RHEL/Rocky/CentOS
sudo dnf install -y bc jq systemd

# Vérifier
which bc jq systemctl
```

### Problème 6 : Permission denied lors de l'exécution

**Symptômes** :
```bash
./configure-kubelet-reservations.sh
# bash: ./configure-kubelet-reservations.sh: Permission denied
```

**Solution** :
```bash
# Rendre le script exécutable
chmod +x configure-kubelet-reservations.sh

# Exécuter avec sudo
sudo ./configure-kubelet-reservations.sh
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
sudo ./configure-kubelet-reservations.sh --profile conservative --backup
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
  "/usr/local/bin/configure-kubelet-reservations.sh \
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
sudo chown root:root configure-kubelet-reservations.sh
sudo chmod 750 configure-kubelet-reservations.sh

# Vérifier
ls -l configure-kubelet-reservations.sh
# -rwxr-x--- 1 root root 28472 Jan 20 10:30 configure-kubelet-reservations.sh
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
git add configure-kubelet-reservations.sh
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

## 📝 Changelog

### v2.0.0-production (2025-10-21)

**🎯 Production-Ready Enhancements** :
- ✨ **Input Validation**: Comprehensive validation for all command-line arguments
  - Profile validation with clear error messages
  - Density-factor bounds checking (0.1-5.0, recommended 0.5-3.0)
  - Target-pods positive integer validation
- ✨ **Improved RAM Detection**: Fixed RAM detection using MiB for accuracy (fixes rounding issues)
- ✨ **Dynamic Eviction Thresholds**: Eviction thresholds now scale with node size
  - Small nodes (<8 GiB): 250Mi hard / 500Mi soft
  - Medium nodes (8-32 GiB): 500Mi hard / 1Gi soft
  - Large nodes (32-64 GiB): 1Gi hard / 2Gi soft
  - XL nodes (>64 GiB): 2Gi hard / 4Gi soft
- ✨ **Cgroup Verification & Creation**: Automatic detection and creation of required cgroups
  - Detects cgroup v1 vs v2
  - Creates kubelet.slice if missing
  - Validates system.slice existence
- ✨ **Automatic Rollback**: Built-in rollback mechanism on failure
  - Automatic backup before changes
  - Rollback on kubelet restart failure
  - Rollback on stability check failure (15s wait)
  - Cleanup of temporary backups on success
- ✨ **YAML Validation**: Pre-flight validation before applying config
  - Validates YAML syntax with yq
  - Checks apiVersion and kind fields
  - Prevents invalid configs from breaking kubelet
- ✨ **Better Error Handling**: Fixed arithmetic expressions and improved reliability
  - Fixed bc comparison in density-factor check
  - Added zero-division protections
  - Better error messages throughout

**🔧 Code Quality** :
- 🐛 Fixed arithmetic expression for density factor comparison (line 717)
- 🐛 Fixed RAM detection precision issues
- 🔒 Enhanced security with automatic backups
- 📝 Added VERSION constant (2.0.0-production)
- 📝 Updated documentation headers

**📚 Documentation** :
- 📚 Updated README with v2.0.0 changes
- 📚 Added yq dependency requirement
- 📚 Improved usage examples

### v1.0.0 (2025-01-20)

**Ajouts** :
- ✨ Détection automatique des ressources (vCPU, RAM)
- ✨ 4 profils de calcul (GKE, EKS, Conservative, Minimal)
- ✨ Calcul automatique du density-factor via `--target-pods`
- ✨ Mode `--dry-run` pour tester sans appliquer
- ✨ Option `--backup` pour sauvegarder la config existante
- ✨ Validation post-configuration (kubelet status)
- ✨ Affichage détaillé des réservations et allocatable
- ✨ Support cgroups v1 et v2
- ✨ Compatible systemd

**Documentation** :
- 📚 README complet avec exemples
- 📚 Guide de déploiement (manuel, Ansible, DaemonSet)
- 📚 Section troubleshooting détaillée
- 📚 FAQ et bonnes pratiques

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

**Développé par** : Platform Engineering Team 

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
- ✅ Debian 11, 12
- ✅ RHEL 8, 9
- ✅ Rocky Linux 8, 9
- ✅ Amazon Linux 2023

**Versions Kubernetes testées** :
- ✅ v1.26.x
- ✅ v1.27.x
- ✅ v1.28.x
- ✅ v1.29.x
- ✅ v1.30.x
- ✅ v1.31.x
- ✅ v1.32.x

---

**Dernière mise à jour** : 20 oct 2025  
**Version du README** : 1.0.0  
**Mainteneur** : Platform Engineering Team
