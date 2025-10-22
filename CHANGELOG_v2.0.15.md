# Changelog v2.0.15 - Lab monitoring kubelet (Prometheus / Grafana)

**Date** : 22 octobre 2025  
**Type** : Documentation & Observabilité  
**Impact** : Patch (nouvelle doc + configuration optionnelle)

---

## 🎯 Vue d'ensemble

Cette version apporte un **lab complet d'observabilité kubelet** prêt à l'emploi :

- Documentation pas-à-pas (Helm, kube-prometheus-stack, Metrics Server, PrometheusRule, Grafana)
- Fichiers sources versionnés (rules, dashboard JSON, Vagrantfile du lab ARM64)
- Nouvelle instrumentation : réserves system/kube + marge d'éviction exposées en métriques Prometheus

Objectif : permettre aux équipes d’**inspecter précisément l’impact de `kubelet_auto_config.sh`** sur les ressources allocatables (CPU/RAM) et de reproduire le lab Vagrant officiel.

---

## ✨ Nouveautés principales

### 📊 Lab monitoring kubelet (`tests/kubelet-alerting-lab/`)

- `README.md` (500+ lignes) : guide complet pour installer Helm, kube-prometheus-stack, Metrics Server, alertes et dashboards.
- `kubelet-reservations-alerts.yaml` : PrometheusRule avec alertes recommandées (throttling, PLEG, mémoire, évictions, allocatable).
- `kubelet-reservations-recordings.yaml` : nouvelles métriques enregistrées :
  - `kubelet_system_reserved_*` (CPU/RAM + %)
  - `kubelet_kube_reserved_*` (CPU/RAM + %)
  - `kubelet_memory_eviction_*` (marge d’éviction kubelet en Mi/%)  
  - Calcul basé sur les constantes profil `gke` density 1.2 (cp1 + w1 du lab Vagrant).
- `grafana-dashboard-kubelet-reservations.json` :
  - Panneaux CPU/RAM allocatable + détail system/kube/éviction
  - Visualisation en pourcentage (stack) + MiB
  - Panneaux spécifiques aux réserves (Mi) et allocatable (GiB)

### 🧪 Lab Vagrant (`tests/vagrant/`)

- `Vagrantfile` ARM64 (cp1 control-plane 3 vCPU/4 GiB, w1 worker 2 vCPU/2 GiB) identique au lab principal.
- `README.md` : mode d’emploi rapide (vagrant up/destroy, vérifications, lien vers doc monitoring).
- Prépare le terrain pour rejouer `kubelet_auto_config.sh` + instrumentation sans dépendre du dépôt principal.

---

## 🔍 Résultats de validation

Sur lab Vagrant ARM64 (Ubuntu 24.04, Kubernetes v1.32.9) :

| Nœud        | Allocatable CPU | Allocatable RAM | System-reserved RAM | Kube-reserved RAM | Marge d'éviction |
|-------------|-----------------|-----------------|---------------------|-------------------|------------------|
| k8s-lab-cp1 | 2780m / 3000m   | 3.12 GiB / 3.81 GiB | 171 Mi            | 288 Mi            | 250 Mi           |
| k8s-lab-w1  | 1760m / 2000m   | 1.20 GiB / 1.90 GiB | 156 Mi            | 319 Mi            | 250 Mi           |

Les nouvelles métriques confirment que le panneau “Mémoire réservée (%)” agrège bien system + kube + marge d’éviction (d’où ~37 % sur cp1).

---

## 📌 Actions recommandées

1. **Importer le dashboard Grafana** (`grafana-dashboard-kubelet-reservations.json`) après avoir appliqué `kubelet-reservations-recordings.yaml`.
2. **Mettre à jour les constantes** dans `kubelet-reservations-recordings.yaml` si vous exécutez `kubelet_auto_config.sh` avec un autre profil/density.
3. **Utiliser le dossier `tests/vagrant/`** pour lancer un lab isolé et rejouer les procédures step-by-step (doc + alertes).

---

## 📚 Fichiers modifiés / ajoutés

- `tests/kubelet-alerting-lab/README.md`
- `tests/kubelet-alerting-lab/kubelet-reservations-alerts.yaml`
- `tests/kubelet-alerting-lab/kubelet-reservations-recordings.yaml`
- `tests/kubelet-alerting-lab/grafana-dashboard-kubelet-reservations.json`
- `tests/vagrant/Vagrantfile`
- `tests/vagrant/README.md`
