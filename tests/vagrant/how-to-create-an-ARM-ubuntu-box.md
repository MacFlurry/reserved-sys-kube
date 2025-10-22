# Guide Complet : Créer une Box Vagrant Ubuntu 24.04 ARM64 pour VMware Fusion

Ce guide détaille les étapes pour créer une box Vagrant personnalisée Ubuntu 24.04 ARM64 compatible avec VMware Fusion sur Apple Silicon (M1/M2/M3/M4).

---

## 📋 Table des Matières

- [Prérequis](#prérequis)
- [Étape 1 : Télécharger l'ISO Ubuntu 24.04 ARM64](#étape-1--télécharger-liso-ubuntu-2404-arm64)
- [Étape 2 : Créer la VM dans VMware Fusion](#étape-2--créer-la-vm-dans-vmware-fusion)
- [Étape 3 : Installer Ubuntu 24.04](#étape-3--installer-ubuntu-2404)
- [Étape 4 : Configuration de la VM pour Vagrant](#étape-4--configuration-de-la-vm-pour-vagrant)
- [Étape 5 : Créer un Clone Complet](#étape-5--créer-un-clone-complet)
- [Étape 6 : Optimiser le Disque](#étape-6--optimiser-le-disque)
- [Étape 7 : Nettoyer les Fichiers Inutiles](#étape-7--nettoyer-les-fichiers-inutiles)
- [Étape 8 : Créer le metadata.json](#étape-8--créer-le-metadatajson)
- [Étape 9 : Packager la Box](#étape-9--packager-la-box)
- [Étape 10 : Ajouter la Box à Vagrant](#étape-10--ajouter-la-box-à-vagrant)
- [Étape 11 : Tester la Box](#étape-11--tester-la-box)
- [Récapitulatif des Fichiers Requis](#-récapitulatif-des-fichiers-requis-dans-la-box)
- [Troubleshooting](#-troubleshooting)
- [Sources Officielles](#-sources-officielles)

---

## Prérequis

- **macOS** avec Apple Silicon (M1/M2/M3/M4)
- **VMware Fusion** (gratuit avec licence personnelle depuis acquisition Broadcom)
- **Vagrant** installé
- **Vagrant VMware Utility** installé
- **Espace disque** : ~50 GB minimum (ISO + VM + box finale)

---

## Étape 1 : Télécharger l'ISO Ubuntu 24.04 ARM64

**Site officiel** : https://ubuntu.com/download/server/arm

**Fichier** : `ubuntu-24.04.3-live-server-arm64.iso` (environ 3 GB)

```bash
# Option 1 : Téléchargement via navigateur depuis le site officiel
# Option 2 : Téléchargement via wget/curl
wget https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-arm64.iso
```

---

## Étape 2 : Créer la VM dans VMware Fusion

### 2.1 Nouvelle VM

1. **VMware Fusion** → "Create a custom virtual machine"
2. **Operating System** : Ubuntu 64-bit ARM
3. **Firmware** : UEFI
4. **Disk** :
   - Taille : 30-40 GB (selon vos besoins)
   - ⚠️ **IMPORTANT** : Décocher "Split into multiple files"
5. **RAM** : 2-4 GB (selon vos besoins)
6. **CPU** : 2 cores
7. **Network** : NAT

### 2.2 Configuration VMX AVANT installation

**⚠️ CRITIQUE** : Éditer le fichier `.vmx` et ajouter cette ligne :

```ruby
ethernet0.virtualdev = "vmxnet3"
```

**Localisation du fichier** : `~/Virtual Machines.localized/<nom-vm>.vmwarevm/<nom-vm>.vmx`

**Raison** : Sans cette ligne, la box échouera au boot car le NIC e1000 legacy ne fonctionne plus sur ARM64.

**Comment éditer** :
```bash
# Arrêter la VM si elle tourne
# Éditer le fichier .vmx
vim ~/Virtual\ Machines.localized/<nom-vm>.vmwarevm/<nom-vm>.vmx

# Ajouter la ligne
ethernet0.virtualdev = "vmxnet3"
```

---

## Étape 3 : Installer Ubuntu 24.04

### 3.1 Installation de base

1. **Boot** sur l'ISO
2. **Language** : English
3. **Keyboard** : Selon préférence
4. **Installation type** : Ubuntu Server (minimal)
5. **Network** : Accepter la config DHCP par défaut
6. **Storage** : Use entire disk (pas de LVM si vous préférez)
7. **Profile setup** :
   ```
   Your name: vagrant
   Your server's name: ubuntu (ou au choix)
   Username: vagrant
   Password: vagrant
   ```
8. **SSH Setup** : ✅ Installer OpenSSH server
9. **Featured Server Snaps** : Rien (skip)

### 3.2 Post-installation

Une fois l'installation terminée :
```bash
# Redémarrer la VM
sudo reboot

# Se connecter avec vagrant/vagrant
```

---

## Étape 4 : Configuration de la VM pour Vagrant

### 4.1 Configurer sudo sans mot de passe

```bash
sudo visudo
```

Ajouter à la fin du fichier :
```
vagrant ALL=(ALL) NOPASSWD:ALL
```

Sauvegarder et quitter (`:wq` dans vim).

### 4.2 Installer la clé SSH publique Vagrant

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Télécharger la clé publique officielle Vagrant
curl -fsSL https://raw.githubusercontent.com/hashicorp/vagrant/master/keys/vagrant.pub \
  -o ~/.ssh/authorized_keys

chmod 600 ~/.ssh/authorized_keys
```

### 4.3 Installer VMware Tools

```bash
sudo apt update
sudo apt install -y open-vm-tools
```

### 4.4 Nettoyer le système

```bash
# Nettoyer les paquets
sudo apt clean
sudo apt autoremove -y

# Supprimer l'historique bash
history -c
cat /dev/null > ~/.bash_history

# Supprimer les logs
sudo find /var/log -type f -exec truncate -s 0 {} \;

# Zeroize le disque (optionnel, pour réduire la taille finale)
# ⚠️ Cette commande peut prendre 10-30 minutes selon la taille du disque
sudo dd if=/dev/zero of=/EMPTY bs=1M || true
sudo rm -f /EMPTY
```

### 4.5 Arrêter la VM

```bash
sudo shutdown -h now
```

---

## Étape 5 : Créer un Clone Complet

Dans **VMware Fusion** :

1. Clic droit sur la VM → **Snapshot** → **Take Snapshot** (optionnel, pour backup)
2. Clic droit sur la VM → **Create Full Clone**
3. Nom : `ubuntu-24.04-arm64-clone`

**Pourquoi un clone ?** Pour garder votre VM originale intacte et travailler sur le clone.

---

## Étape 6 : Optimiser le Disque

```bash
# Naviguer vers le dossier de la VM clonée
cd ~/Virtual\ Machines.localized/ubuntu-24.04-arm64-clone.vmwarevm

# Identifier le fichier disque principal
ls -lh *.vmdk

# Défragmenter le disque virtuel
/Applications/VMware\ Fusion.app/Contents/Library/vmware-vdiskmanager \
  -d "Virtual Disk.vmdk"

# Shrink le disque (compresser et réduire la taille)
/Applications/VMware\ Fusion.app/Contents/Library/vmware-vdiskmanager \
  -k "Virtual Disk.vmdk"
```

**Note** :
- Ces opérations peuvent prendre 10-30 minutes selon la taille du disque
- Le nom du fichier peut varier (`Virtual Disk.vmdk`, `disk.vmdk`, etc.)

---

## Étape 7 : Nettoyer les Fichiers Inutiles

```bash
# Toujours dans le dossier .vmwarevm
# Supprimer les fichiers temporaires et logs

rm -f *.log
rm -f *.lck
rm -rf *.vmem
rm -rf vmware*.log
rm -rf vmware.log.*
```

**Fichiers à CONSERVER** :
- `*.nvram` (NVRAM VMware)
- `*.vmsd` (VM Snapshot Data)
- `*.vmx` (VM Configuration - fichier principal)
- `*.vmxf` (Supplemental VM Configuration)
- `*.vmdk` (Virtual Disk - tous les fichiers disque)

---

## Étape 8 : Créer le metadata.json

```bash
# Toujours dans le dossier .vmwarevm
cat > metadata.json << 'EOF'
{
  "provider": "vmware_desktop"
}
EOF
```

**Vérification** :
```bash
cat metadata.json
# Doit afficher : {"provider": "vmware_desktop"}
```

---

## Étape 9 : Packager la Box

```bash
# Créer le fichier .box (archive tar gzippée)
# Depuis le dossier .vmwarevm
tar cvzf ~/ubuntu-24.04-arm64.box ./*
```

**Résultat** : Fichier `ubuntu-24.04-arm64.box` dans votre répertoire home

**Taille attendue** : 2-5 GB selon l'optimisation du disque

**Vérification** :
```bash
ls -lh ~/ubuntu-24.04-arm64.box
file ~/ubuntu-24.04-arm64.box
# Doit afficher : gzip compressed data
```

---

## Étape 10 : Ajouter la Box à Vagrant

```bash
# Ajouter la box localement avec un nom personnalisé
vagrant box add local/ubuntu-24-04-arm64 ~/ubuntu-24.04-arm64.box

# Vérifier que la box est bien ajoutée
vagrant box list
# Doit afficher : local/ubuntu-24-04-arm64 (vmware_desktop, 0)
```

---

## Étape 11 : Tester la Box

```bash
# Créer un répertoire de test
mkdir -p ~/vagrant-box-test
cd ~/vagrant-box-test

# Initialiser avec votre box
vagrant init local/ubuntu-24-04-arm64

# Configurer le Vagrantfile pour VMware
cat > Vagrantfile << 'EOF'
Vagrant.configure("2") do |config|
  config.vm.box = "local/ubuntu-24-04-arm64"

  config.vm.provider "vmware_desktop" do |v|
    v.vmx["memsize"] = "2048"
    v.vmx["numvcpus"] = "2"
    v.vmx["ethernet0.virtualdev"] = "vmxnet3"  # Important !
    v.linked_clone = false  # Utiliser full clone
  end

  config.vm.hostname = "ubuntu-test"
end
EOF

# Démarrer la VM
vagrant up --provider=vmware_desktop

# Se connecter via SSH
vagrant ssh

# Vérifications dans la VM
uname -a      # Doit afficher : aarch64
lsb_release -a  # Doit afficher : Ubuntu 24.04
ip a          # Vérifier la connectivité réseau
```

**Tests de validation** :
```bash
# Test sudo sans mot de passe
sudo whoami   # Doit afficher : root (sans demander de mot de passe)

# Test connectivité internet
ping -c 3 8.8.8.8

# Sortir et détruire la VM de test
exit
vagrant destroy -f
```

---

## 📝 Récapitulatif des Fichiers Requis dans la Box

Selon la [documentation officielle HashiCorp](https://developer.hashicorp.com/vagrant/docs/providers/vmware/boxes), les fichiers obligatoires sont :

```
ubuntu-24.04-arm64-clone.vmwarevm/
├── metadata.json           # Métadonnées Vagrant {"provider": "vmware_desktop"}
├── *.nvram                 # NVRAM VMware (UEFI variables)
├── *.vmsd                  # VM Snapshot Data
├── *.vmx                   # VM Configuration (DOIT contenir ethernet0.virtualdev = "vmxnet3")
├── *.vmxf                  # Supplemental VM Configuration
└── *.vmdk                  # Virtual Disk (peut avoir plusieurs fichiers -s001.vmdk, -s002.vmdk, etc.)
```

**Fichiers critiques** :
- **metadata.json** : Obligatoire pour Vagrant
- **\*.vmx** : Doit contenir `ethernet0.virtualdev = "vmxnet3"`
- **\*.vmdk** : Tous les fichiers disque (ne pas en omettre)

---

## 🔧 Troubleshooting

### Problème : Linked clone errors

**Erreur** :
```
The VMware provider does not support linked clones for this box.
```

**Solution** : Ajouter dans votre Vagrantfile :
```ruby
config.vm.provider "vmware_desktop" do |v|
  v.linked_clone = false
end
```

---

### Problème : VM ne boot pas / network error

**Erreur** :
```
Failed to connect to the hypervisor
No usable network adapters found
```

**Solution** :
1. Vérifier que `ethernet0.virtualdev = "vmxnet3"` est bien dans le fichier `.vmx` de la box
2. Recréer la box en s'assurant que cette ligne est présente

**Vérification** :
```bash
# Extraire la box pour vérifier
mkdir /tmp/box-check
cd /tmp/box-check
tar xzf ~/ubuntu-24.04-arm64.box
grep "ethernet0.virtualdev" *.vmx
# Doit afficher : ethernet0.virtualdev = "vmxnet3"
```

---

### Problème : Box trop volumineuse (>10 GB)

**Cause** : Disque virtuel non optimisé

**Solution** :
1. Réexécuter le zeroize dans la VM **avant** de l'arrêter :
   ```bash
   sudo dd if=/dev/zero of=/EMPTY bs=1M || true
   sudo rm -f /EMPTY
   sudo shutdown -h now
   ```
2. Réexécuter `vmware-vdiskmanager -k` sur le clone
3. Vérifier que vous avez supprimé tous les logs/snapshots
4. Utiliser `gzip` avec compression maximale :
   ```bash
   tar cv ./* | gzip -9 > ~/ubuntu-24.04-arm64.box
   ```

---

### Problème : SSH timeout lors du vagrant up

**Erreur** :
```
Timed out while waiting for the machine to boot.
```

**Causes possibles** :
1. Clé SSH Vagrant non installée
2. Firewall bloquant le port SSH (22)
3. OpenSSH server non installé

**Solution** :
```bash
# Vérifier dans la VM (via console VMware) :
sudo systemctl status ssh
sudo ufw status  # Vérifier firewall

# Réinstaller la clé Vagrant
curl -fsSL https://raw.githubusercontent.com/hashicorp/vagrant/master/keys/vagrant.pub \
  -o ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

---

### Problème : vagrant ssh demande un mot de passe

**Cause** : Clé SSH Vagrant mal configurée

**Solution** :
```bash
# Dans la VM (via console VMware) :
# Vérifier les permissions
ls -la ~/.ssh/
# Doit afficher : drwx------ .ssh/ et -rw------- authorized_keys

# Réinstaller la clé
curl -fsSL https://raw.githubusercontent.com/hashicorp/vagrant/master/keys/vagrant.pub \
  > ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

---

## 📚 Sources Officielles

- **HashiCorp Vagrant VMware Box Format** : https://developer.hashicorp.com/vagrant/docs/providers/vmware/boxes
- **Ubuntu ARM Server Download** : https://ubuntu.com/download/server/arm
- **GitHub Guide (wildfluss)** : https://github.com/wildfluss/vagrant-vmware-box
- **Vagrant Official Documentation** : https://developer.hashicorp.com/vagrant/docs

---

## 📌 Notes Supplémentaires

### Différences ARM64 vs AMD64

- **NIC** : Sur ARM64, `vmxnet3` est obligatoire (e1000 ne fonctionne plus)
- **ISO** : Utiliser impérativement la version ARM64 (`aarch64`)
- **VMware Tools** : `open-vm-tools` fonctionne correctement sur ARM64

### Bonnes Pratiques

1. **Toujours créer un clone complet** avant de packager
2. **Tester la box** avant de la distribuer
3. **Documenter les modifications** spécifiques apportées à la VM
4. **Versionner les box** si vous les mettez à jour régulièrement
5. **Sauvegarder la VM originale** pour futures mises à jour

### Commandes Utiles

```bash
# Lister les box installées
vagrant box list

# Supprimer une box
vagrant box remove local/ubuntu-24-04-arm64

# Mettre à jour une box (remplacer)
vagrant box add local/ubuntu-24-04-arm64 ~/ubuntu-24.04-arm64-v2.box --force

# Vérifier l'intégrité d'une box
tar tzf ~/ubuntu-24.04-arm64.box | head -20
```

---

## 🎉 Conclusion

Vous disposez maintenant d'une box Vagrant Ubuntu 24.04 ARM64 fonctionnelle pour VMware Fusion sur Apple Silicon !

**Cas d'usage** :
- Développement local sur macOS M1/M2/M3/M4
- Tests d'applications ARM64
- Labs Kubernetes (comme dans ce projet)
- Environnements CI/CD locaux

**Prochaines étapes** :
- Créer des variantes avec des configurations différentes (Docker préinstallé, Kubernetes, etc.)
- Partager la box avec votre équipe (Vagrant Cloud ou stockage privé)
- Automatiser la création avec Packer (voir https://www.packer.io/)

---

**Mainteneur** : Platform Engineering Team
**Date de création** : 22 octobre 2025
**Dernière mise à jour** : 22 octobre 2025
