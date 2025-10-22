# Méthode 3 : Déploiement via DaemonSet

> ✅ **Validé sur lab Vagrant** : Cette méthode a été testée avec succès sur un cluster de test (control-plane + worker)

## Vue d'ensemble

Cette méthode avancée utilise un DaemonSet Kubernetes pour déployer automatiquement la configuration kubelet sur tous les nœuds du cluster. Le DaemonSet :

1. Monte le système de fichiers hôte (`hostPath: /`)
2. Installe les dépendances nécessaires (bc, jq, yq)
3. Exécute le script `kubelet_auto_config.sh` via `chroot`
4. Configure kubelet avec les réservations calculées
5. Reste actif pour inspection des logs

## ⚠️ Avertissements

### Sécurité
- Nécessite des privilèges élevés (`privileged: true`)
- Monte le système de fichiers hôte complet
- **À utiliser uniquement** dans des environnements contrôlés
- **Non recommandé** en production sans validation approfondie

### Limitations
- Si la configuration calculée laisse < 25% CPU ou < 20% RAM disponibles, le script échouera
- Sur des nœuds très contraints (≤ 2 vCPU / ≤ 2 GiB), certains profils seront refusés
- Le pod peut crashloop si les garde-fous se déclenchent

## Fichiers fournis

- `generate-daemonset.sh` - Script de déploiement automatique
- `kubelet-config-daemonset-only.yaml` - Définition du DaemonSet
- `kubelet-config-daemonset-old.yaml` - Ancien template (archive)

## Prérequis

- Cluster Kubernetes fonctionnel
- Accès kubectl avec droits admin (namespace kube-system)
- Architecture ARM64 (le script utilise yq_linux_arm64)
- Ubuntu 24.04 comme base image (configurable)

## Utilisation

### Déploiement automatique (recommandé)

```bash
# Depuis le répertoire daemonset/
cd daemonset
./generate-daemonset.sh
```

Le script va :
1. Créer le ConfigMap avec le script `kubelet_auto_config.sh`
2. Déployer le DaemonSet sur tous les nœuds
3. Afficher les instructions de surveillance

### Déploiement manuel

```bash
# 1. Créer le ConfigMap avec le script
kubectl create configmap kubelet-config-script \
  --from-file=kubelet_auto_config.sh=../kubelet_auto_config.sh \
  --namespace=kube-system

# 2. Déployer le DaemonSet
kubectl apply -f kubelet-config-daemonset-only.yaml

# 3. Vérifier les pods
kubectl get pods -n kube-system -l app=kubelet-config-updater -o wide
```

## Surveillance et vérification

### Vérifier le statut des pods

```bash
kubectl get pods -n kube-system -l app=kubelet-config-updater -o wide
```

Sortie attendue :
```
NAME                           READY   STATUS    RESTARTS   AGE
kubelet-config-updater-xxxxx   1/1     Running   0          30s
kubelet-config-updater-yyyyy   1/1     Running   0          30s
```

### Voir les logs (approche kubectl)

```bash
# Logs de tous les pods
kubectl logs -n kube-system -l app=kubelet-config-updater -f

# Logs d'un pod spécifique
kubectl logs -n kube-system kubelet-config-updater-xxxxx
```

**Note** : Sur les nœuds sans InternalIP configuré, `kubectl logs` peut échouer. Utilisez alors `crictl` directement sur le nœud.

### Voir les logs (approche crictl - alternative)

Si `kubectl logs` ne fonctionne pas :

```bash
# Se connecter au nœud concerné
ssh node1

# Lister les pods
sudo crictl pods --name kubelet-config-updater

# Lister les conteneurs du pod
sudo crictl ps --pod <POD_ID>

# Voir les logs
sudo crictl logs <CONTAINER_ID>
```

### Vérifier l'allocatable après application

```bash
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
CPU-CAP:.status.capacity.cpu,\
CPU-ALLOC:.status.allocatable.cpu,\
MEM-CAP:.status.capacity.memory,\
MEM-ALLOC:.status.allocatable.memory
```

## Nettoyage

Une fois la configuration appliquée avec succès, supprimez le DaemonSet :

```bash
kubectl delete daemonset -n kube-system kubelet-config-updater
kubectl delete configmap -n kube-system kubelet-config-script
```

> 💡 Les configurations kubelet restent en place après suppression du DaemonSet

## Personnalisation

### Modifier le profil ou target-pods

Éditez `kubelet-config-daemonset-only.yaml`, section `command` :

```yaml
chroot /host /tmp/kubelet_auto_config.sh \
  --profile conservative \      # Changez le profil
  --target-pods 110 \            # Changez le nombre de pods cible
  --backup
```

Profils disponibles : `gke`, `eks`, `conservative`, `minimal`

### Adapter pour architecture x86_64

Remplacez dans le YAML :

```yaml
# Avant (ARM64)
wget -qO /tmp/yq https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_arm64

# Après (x86_64)
wget -qO /tmp/yq https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64
```

### Utiliser une autre image de base

Remplacez dans le YAML :

```yaml
containers:
- name: updater
  image: ubuntu:22.04  # ou ubuntu:20.04, debian:12, etc.
```

## Résultats attendus (lab Vagrant)

### Configuration
- **Cluster** : cp1 (3 vCPU / 3.8 GiB) + w1 (2 vCPU / 1.9 GiB)
- **Profil** : gke
- **Target pods** : 80 (density-factor auto-calculé : 1.20)

### Pods DaemonSet

```
NAME                           READY   STATUS    RESTARTS   AGE   NODE
kubelet-config-updater-8dzj9   1/1     Running   0          2m    k8s-lab-cp1
kubelet-config-updater-cphg2   1/1     Running   0          2m    k8s-lab-w1
```

### Allocatable après configuration

| Nœud | CPU Allocatable | Variation | RAM Allocatable | Variation |
|------|----------------|-----------|-----------------|-----------|
| k8s-lab-cp1 | 2736m / 3000m (91%) | +66m | 3098 MiB / 3899 MiB (79%) | +137 MiB |
| k8s-lab-w1 | 1760m / 2000m (88%) | +60m | 1228 MiB / 1953 MiB (63%) | +119 MiB |

### Logs de succès (exemple cp1)

```
✓ Configuration terminée avec succès sur k8s-lab-cp1

Δ allocatable réel -> CPU: 2736m (+66m) | Mémoire: 3098Mi (+137Mi)

Backup permanent conservé : /var/lib/kubelet/config.yaml.backup.20251022_125910
Backup rotatif créé : /var/lib/kubelet/config.yaml.last-success.0
```

## Troubleshooting

### Les pods sont en CrashLoopBackOff

**Cause** : Le script a probablement échoué (garde-fous activés, ressources insuffisantes)

**Solution** :
```bash
# Voir les logs pour identifier l'erreur
kubectl logs -n kube-system <pod-name>

# Si garde-fous : ajuster le profil ou target-pods
# Éditer le DaemonSet et le redéployer
kubectl edit daemonset -n kube-system kubelet-config-updater
```

### kubectl logs ne fonctionne pas

**Cause** : Nœud sans InternalIP configuré (problème réseau Kubernetes)

**Solution** : Utiliser `crictl` directement sur le nœud (voir section Surveillance)

### Le pod ne démarre pas (ImagePullBackOff)

**Cause** : Image Ubuntu non disponible ou problème de pull

**Solution** :
```bash
# Vérifier l'image sur le nœud
ssh node1 "sudo crictl images | grep ubuntu"

# Pré-charger l'image si nécessaire
ssh node1 "sudo crictl pull ubuntu:24.04"
```

### La configuration n'est pas appliquée

**Cause** : Le script a réussi mais kubelet n'a pas redémarré correctement

**Solution** :
```bash
# Se connecter au nœud et vérifier
ssh node1
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 50

# Redémarrer manuellement si nécessaire
sudo systemctl restart kubelet
```

## Comparaison avec les autres méthodes

| Critère | Méthode 1 (Manuel) | Méthode 2 (Ansible) | Méthode 3 (DaemonSet) |
|---------|-------------------|---------------------|---------------------|
| **Complexité** | Faible | Moyenne | Élevée |
| **Automatisation** | Manuelle | Élevée | Maximale |
| **Privilèges requis** | SSH + sudo | SSH + sudo | Cluster admin |
| **Scalabilité** | Faible (<10 nœuds) | Élevée | Maximale |
| **Sécurité** | ✅ Bonne | ✅ Bonne | ⚠️ Privilèges élevés |
| **Recommandation** | Tests, petits clusters | Production | Automatisation avancée |

## Support

Pour toute question ou problème :
- README principal du projet
- Section Troubleshooting du README.md
- Issues GitLab : https://gitlab.com/omega8280051/reserved-sys-kube/-/issues
