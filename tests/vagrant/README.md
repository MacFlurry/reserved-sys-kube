# Vagrant Lab — kubelet reservations

Ce dossier contient le `Vagrantfile` utilisé pour monter le lab ARM64 sous VMware Fusion (cp1 + w1) avec kubeadm, Calico et le provisioning détaillé dans la documentation monitoring.

## Prérequis

- macOS avec VMware Fusion + plugin `vagrant-vmware-desktop`.
- Box locale `local/ubuntu-24.04-arm64` (la même que celle utilisée dans le projet principal).
- Vagrant 2.4+.
- Accès Internet pour les VMs (dépôts Ubuntu, pkgs.k8s.io, Docker Hub / ghcr).

## Démarrage du cluster

```bash
cd tests/vagrant
vagrant up cp1
vagrant up w1
```

Le provisioning réalise :
- configuration noyau (modules, sysctl), containerd avec `SystemdCgroup=true`, installation kubeadm/kubelet/kubectl (repo pkgs.k8s.io `v1.32`).
- initialisation `cp1` en control-plane (`kubeadm init` + Calico + génération `join.sh`).
- attente API control-plane, exécution `join.sh` sur w1.
- configuration `kubelet` avec `--node-ip=192.168.56.x`.

## Vérifications rapides

Une fois `w1` `Ready` :

```bash
vagrant ssh cp1 -c 'kubectl get nodes'
vagrant ssh cp1 -c 'kubectl get pods -A'
```

## Provisioning monitoring

Après `vagrant up`, suivre la doc `tests/kubelet-alerting-lab/README.md` pour installer :
- Helm + kube-prometheus-stack (Grafana NodePort 32000).
- Metrics Server patché `--kubelet-insecure-tls`.
- Règles Prometheus et dashboard Grafana (`kubelet-reservations-*`).

## Nettoyage

```bash
vagrant destroy -f w1
vagrant destroy -f cp1
```

## Notes

- Les réservations kubelet (system/kube) sont fixées par le script `kubelet_auto_config.sh` (`--profile gke --density 1.2`).
- Si `systemd-resolved` tombe, appliquez la procédure DNS décrite dans le README monitoring avant de relancer les pods monitoring.
