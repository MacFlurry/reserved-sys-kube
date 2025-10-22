# Lab d'alerting kubelet — Prometheus / Grafana / Alertmanager

Ce dossier documente l’installation complète du stack monitoring utilisé pour valider le script `kubelet_auto_config.sh` dans l’environnement Vagrant (`cp1` + `w1`) basé sur Ubuntu 24.04 ARM64 + VMware Fusion. Il fournit également les manifestes associés :

- `kubelet-reservations-alerts.yaml` : alertes Prometheus prêtes à l’emploi.
- `kubelet-reservations-recordings.yaml` : règles d’enregistrement pour exposer les réserves système/kube configurées.
- `grafana-dashboard-kubelet-reservations.json` : tableau de bord Grafana pour visualiser réservations et allocatable.

---

## 1. Pré-requis du lab

1. **Cluster Vagrant opérationnel** via le Vagrantfile du projet (`cp1` control-plane, `w1` worker) avec le provisioning actuel (containerd en mode `SystemdCgroup`, kubelet `--node-ip`, etc.).
2. **Metrics Server** déployé et patché avec `--kubelet-insecure-tls` (voir § 2.3) pour accepter les certificats kubelet auto-signés.
3. **Accès Internet sortant** depuis les VMs vers Docker Hub, ghcr.io, quay.io…
4. **DNS fonctionnel** sur les nœuds. Si `systemd-resolved` échoue (observé sur `w1`), le désactiver et fournir un `resolv.conf` statique :
   ```bash
   sudo systemctl disable --now systemd-resolved
   sudo unlink /etc/resolv.conf
   echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf >/dev/null
   sudo mkdir -p /run/systemd/resolve
   echo "nameserver 1.1.1.1" | sudo tee /run/systemd/resolve/resolv.conf >/dev/null
   ```

---

## 2. Installation du stack monitoring

Toutes les commandes ci-dessous sont exécutées depuis l’hôte dans le dossier `vagrant-kube`, via `vagrant ssh cp1 -c '…'`.

### 2.1 Installer Helm 3

```bash
vagrant ssh cp1 -c 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'
vagrant ssh cp1 -c 'helm version'
```

### 2.2 Déployer kube-prometheus-stack

```bash
vagrant ssh cp1 -c 'helm repo add prometheus-community https://prometheus-community.github.io/helm-charts'
vagrant ssh cp1 -c 'helm repo update'
vagrant ssh cp1 -c "helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.service.type=NodePort --set grafana.service.nodePort=32000"
```

Résultat : Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter, etc. Grafana est exposé via NodePort `32000`.

### 2.3 Installer / patcher Metrics Server

```bash
# 1. Déploiement
vagrant ssh cp1 -c 'kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml'

# 2. Patch TLS (certificats kubelet auto-signés)
vagrant ssh cp1 -c \
  "kubectl -n kube-system patch deploy metrics-server --type='json' \
   -p='[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--kubelet-insecure-tls\"}]'"

# 3. Validation
a) kubectl get pods -n kube-system | grep metrics-server
b) kubectl top nodes
```

### 2.4 Vérifications de base

```bash
vagrant ssh cp1 -c 'kubectl get pods -n monitoring'
vagrant ssh cp1 -c 'kubectl get svc -n monitoring'
```

Tous les pods doivent être `Running` (Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter…).

---

## 3. Règles Prometheus (alerting + recordings)

1. Copier les manifestes dans l’environnement Vagrant (ou les appliquer depuis ce dossier via `kubectl apply -f`).
2. Appliquer les alertes et recordings :
   ```bash
   vagrant ssh cp1 -c 'kubectl apply -f /vagrant/kubelet-reservations-alerts.yaml'
   vagrant ssh cp1 -c 'kubectl apply -f /vagrant/kubelet-reservations-recordings.yaml'
   ```
3. Vérifier :
   ```bash
   vagrant ssh cp1 -c 'kubectl get prometheusrules -n monitoring | grep kubelet'
   ```

### 3.1 Règles d’enregistrement

`kubelet-reservations-recordings.yaml` publie quatre séries :

- `kubelet_system_reserved_cpu_cores`
- `kubelet_kube_reserved_cpu_cores`
- `kubelet_system_reserved_memory_bytes`
- `kubelet_kube_reserved_memory_bytes`

Les valeurs sont fixes (issues du script `kubelet_auto_config.sh` exécuté avec `--profile gke` et density 1.2). Adaptés aux nœuds actuels :

| Nœud        | system-reserved CPU | kube-reserved CPU | system-reserved mémoire | kube-reserved mémoire | marge d'éviction mémoire |
|-------------|--------------------|-------------------|-------------------------|------------------------|---------------------------|
| k8s-lab-cp1 | 0.12 cores         | 0.10 cores        | 171 Mi                  | 288 Mi                 | 250 Mi *(threshold kubelet)* |
| k8s-lab-w1  | 0.12 cores         | 0.12 cores        | 156 Mi                  | 319 Mi                 | 250 Mi                     |

**Important** : si vous changez les paramètres du script (nouvelle densité, profil, etc.), ajustez les constantes dans `kubelet-reservations-recordings.yaml`.

### 3.2 Alertes

`kubelet-reservations-alerts.yaml` reprend les recommandations du README principal :

- `KubeletHighCPUThrottling`
- `KubeletPLEGHighLatency`
- `KubeletHighMemoryUsage`
- `FrequentPodEvictions`
- `NodeLowAllocatable`

Vérifiez leur présence dans Prometheus (`/alerts`) ou via Alertmanager.

---

## 4. Tableau de bord Grafana

1. Récupérer le mot de passe admin :
   ```bash
   vagrant ssh cp1 -c \
     "kubectl -n monitoring get secret kube-prometheus-grafana \
      -o jsonpath='{.data.admin-password}' | base64 -d; echo"
   ```
2. Ouvrir Grafana : `http://192.168.56.10:32000` (user `admin`).
3. Dans **Connections → Data sources**, vérifier la datasource Prometheus (`http://kube-prometheus-kube-prome-prometheus.monitoring.svc:9090`).
4. Importer **grafana-dashboard-kubelet-reservations.json** (Dashboards → Import). Il expose :
   - `CPU system-reserved / kube-reserved / allocatable`
   - `RAM system-reserved / kube-reserved / éviction / allocatable`
   - Panneaux détaillés en **%** et en **MiB** empilés pour visualiser la contribution de chaque composante (system, kube, éviction)
   - Allocatable (CPU / mémoire) disponible pour les pods

*Datasource* : sélectionner la datasource Prometheus installée par kube-prometheus-stack.

---

## 5. Vérifications rapides

```bash
# Cibles kubelet actives
vagrant ssh cp1 -c "kubectl -n monitoring exec prometheus-kube-prometheus-kube-prome-prometheus-0 -c prometheus -- \
  wget -qO- http://localhost:9090/api/v1/targets?state=active | grep kubelet"

# Allocatable vs capacity (Kubernetes natif)
vagrant ssh cp1 -c 'kubectl describe node k8s-lab-cp1'
```

Dans Grafana, surveillez :
- `kubelet_system_reserved_*` et `kubelet_kube_reserved_*` pour les réserves configurées.
- `kube_node_status_allocatable` pour l’espace disponible pods.

---

## 6. Dépannage courant

| Problème | Diagnostic | Correctif |
|----------|------------|-----------|
| Pods monitoring en `ImagePullBackOff` | `kubectl describe pod` → erreurs DNS | Réparer DNS (`systemd-resolved` ou `resolv.conf` statique) |
| Metrics Server n’atteint pas le kubelet | Logs `kubectl -n kube-system logs deploy/metrics-server` | Ajouter `--kubelet-insecure-tls` |
| Prometheus sans cible kubelet | Targets dans l’UI Prometheus | Vérifier ServiceMonitor / accès port 10250 |
| Alertes absentes | `kubectl get prometheusrules -n monitoring` | S’assurer que le CRD `PrometheusRule` existe et que le YAML est appliqué |

---

## 7. Nettoyage

```bash
vagrant ssh cp1 -c 'helm uninstall kube-prometheus -n monitoring'
vagrant ssh cp1 -c 'kubectl delete namespace monitoring'
vagrant ssh cp1 -c 'kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml'
```

---

## 8. Références

- Chart Helm : <https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack>
- Metrics Server : <https://github.com/kubernetes-sigs/metrics-server>
- Config kubelet : Vagrantfile `vagrant-kube/Vagrantfile`
- Script `kubelet_auto_config.sh` : `reserved-sys-kube/kubelet_auto_config.sh`

Votre lab dispose maintenant d’une observabilité complète pour analyser les réservations kubelet et tester les profils du script `kubelet_auto_config.sh`.
