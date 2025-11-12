# Déploiement Ansible - Configuration Kubelet

> ✅ **Validé sur lab Vagrant** : Cette méthode a été testée avec succès sur un cluster de test (control-plane + worker)

## Vue d'ensemble

Ce dossier contient les playbooks Ansible pour déployer automatiquement la configuration des réservations kubelet sur tous les nœuds d'un cluster Kubernetes.

## Prérequis

### 1. Installation d'Ansible

```bash
# Sur Ubuntu/Debian
sudo apt update && sudo apt install -y ansible

# Vérifier l'installation
ansible --version
```

### 2. Configuration SSH

**Option A : Exécution depuis votre poste de travail**
- Accès SSH configuré vers tous les nœuds
- Clés SSH déjà déployées

**Option B : Exécution depuis un nœud du cluster**
- Ansible installé sur un nœud (typiquement le control-plane)
- Clés SSH configurées entre les nœuds

Exemple de configuration SSH entre nœuds :
```bash
# Sur le nœud depuis lequel vous exécutez Ansible (ex: cp1)
ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ''

# Copier la clé publique sur chaque nœud worker
ssh-copy-id vagrant@worker1
ssh-copy-id vagrant@worker2
```

## Fichiers fournis

- `deploy-kubelet-config.yml` - Playbook principal
- `inventory.ini` - Exemple d'inventory (exécution depuis poste de travail)
- `inventory-from-cp1.ini` - Exemple d'inventory (exécution depuis control-plane)

## Configuration de l'inventory

### Variante 1 : Exécution depuis votre poste

**Fichier** : `inventory.ini`

```ini
[k8s_workers]
cp1 ansible_host=127.0.0.1 ansible_port=2222
w1 ansible_host=172.16.173.136 ansible_port=22

[k8s_workers:vars]
ansible_user=vagrant
ansible_ssh_private_key_file=~/.vagrant.d/insecure_private_keys/vagrant.key.ed25519
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
```

### Variante 2 : Exécution depuis un nœud du cluster

**Fichier** : `inventory-from-cp1.ini`

```ini
[k8s_workers]
cp1 ansible_connection=local
w1 ansible_host=172.16.173.136

[k8s_workers:vars]
ansible_user=vagrant
ansible_become=yes
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
```

## Utilisation

### Étape 1 : Test de connectivité

```bash
cd ansible
ansible -i inventory.ini all -m ping
```

Sortie attendue :
```
cp1 | SUCCESS => {"changed": false, "ping": "pong"}
w1 | SUCCESS => {"changed": false, "ping": "pong"}
```

### Étape 2 : Dry-run (vérification syntaxe)

```bash
ansible-playbook -i inventory.ini deploy-kubelet-config.yml --check
```

### Étape 3 : Exécution réelle

```bash
ansible-playbook -i inventory.ini deploy-kubelet-config.yml
```

Le playbook va :
1. Vérifier les dépendances (bc, jq)
2. Installer yq si nécessaire
3. Copier le script `kubelet_auto_config.sh`
4. Exécuter un dry-run et afficher les réservations calculées
5. Demander validation (pause)
6. Appliquer la configuration
7. Vérifier le status kubelet et l'état des nœuds

### Personnalisation des variables

Modifier le profil ou le nombre de pods cible :

```bash
ansible-playbook -i inventory.ini deploy-kubelet-config.yml \
  -e "profile=gke" \
  -e "target_pods=80"
```

Profils disponibles : `gke`, `eks`, `conservative`, `minimal`

### Déploiement progressif

```bash
# Appliquer sur un nœud spécifique
ansible-playbook -i inventory.ini deploy-kubelet-config.yml --limit cp1

# Appliquer sur un sous-ensemble de nœuds
ansible-playbook -i inventory.ini deploy-kubelet-config.yml --limit "node[1:10]"
```

## Résultats attendus

### Exemple : Lab Vagrant (gke profile)

**Configuration** :
- cp1: 3 vCPU / 3.8 GiB RAM (control-plane)
- w1: 2 vCPU / 1.9 GiB RAM (worker)
- Profil: `gke`
- Density-factor: 1.50

**Sortie Ansible** :
```
PLAY RECAP *********************************************************************
cp1                        : ok=14   changed=4    unreachable=0    failed=0
w1                         : ok=13   changed=4    unreachable=0    failed=0
localhost                  : ok=1    changed=0    unreachable=0    failed=0
```

**Allocatable après configuration** :
- k8s-lab-cp1 : CPU 2670m/3000m (89%), RAM 2.96 GiB/3.80 GiB (78%)
- k8s-lab-w1  : CPU 1700m/2000m (85%), RAM 1.08 GiB/1.90 GiB (57%)

## Vérification post-déploiement

```bash
# Vérifier l'état des nœuds
kubectl get nodes

# Vérifier l'allocatable
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
CPU-CAP:.status.capacity.cpu,\
CPU-ALLOC:.status.allocatable.cpu,\
MEM-CAP:.status.capacity.memory,\
MEM-ALLOC:.status.allocatable.memory

# Vérifier la configuration sur un nœud
ssh node1 "cat /var/lib/kubelet/config.yaml | grep -A 3 Reserved"
```

## Garde-fous et limitations

⚠️ Le script intégré dans le playbook applique des **garde-fous** automatiques :

1. **Density-factor plafonné sur control-plane** : Sur les nœuds control-plane, le density-factor est automatiquement plafonné à 1.0 (même si vous spécifiez une valeur plus élevée)

2. **Allocatable minimum** : Le script refuse la configuration si l'allocatable projeté est inférieur à :
   - Worker : 25% CPU et 20% RAM
   - Control-plane : 30% CPU et 25% RAM

Sur des nœuds de faible capacité (≤ 2 vCPU / ≤ 2 GiB), des configurations agressives (`target-pods 110`, `profile conservative`) seront **refusées**.

**Solution** : Utiliser le profil `gke` ou `minimal`, ou augmenter la capacité des nœuds.

## Troubleshooting

### Erreur : "Host key verification failed"

```bash
# Ajouter dans ansible.cfg ou via variable d'environnement
export ANSIBLE_HOST_KEY_CHECKING=False
```

### Erreur : "Permission denied (publickey)"

Vérifier la configuration SSH :
```bash
# Test manuel
ssh -i /path/to/key vagrant@node1 hostname

# Vérifier l'inventory
ansible -i inventory.ini all -m ping -vvv
```

### Dry-run échoue avec "ERROR: Allocatable < seuil"

C'est normal sur des petits nœuds. Solutions :
1. Utiliser `profile=gke` ou `profile=minimal`
2. Réduire `target_pods`
3. Augmenter la capacité des nœuds

### Playbook bloque à "Pause pour validation"

En mode non-interactif, la pause est automatiquement ignorée (warning). Pour forcer le mode non-interactif :
```bash
ansible-playbook -i inventory.ini deploy-kubelet-config.yml < /dev/null
```

## Exemple d'exécution complète

```bash
# 1. Se connecter au control-plane (si exécution depuis le cluster)
vagrant ssh cp1

# 2. Installer Ansible
sudo apt update && sudo apt install -y ansible

# 3. Créer le répertoire de travail
mkdir -p ~/ansible && cd ~/ansible

# 4. Copier les fichiers (inventory + playbook + script)
# (voir les fichiers fournis)

# 5. Tester la connectivité
ansible -i inventory-from-cp1.ini all -m ping

# 6. Exécuter en check mode
ansible-playbook -i inventory-from-cp1.ini deploy-kubelet-config.yml --check

# 7. Exécution réelle
ansible-playbook -i inventory-from-cp1.ini deploy-kubelet-config.yml

# 8. Vérifier les résultats
kubectl get nodes
kubectl describe node cp1 | grep -A 10 Allocatable
kubectl describe node w1 | grep -A 10 Allocatable
```

## Support

Pour toute question ou problème, consultez :
- README principal du projet
- Section Troubleshooting
- Issues GitHub : https://github.com/MacFlurry/reserved-sys-kube/issues
