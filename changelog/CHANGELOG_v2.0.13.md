# Changelog v2.0.13 - Garde-fous allocatable & télémétrie post-exécution

> **Note :** cette version renforce la sécurité des réservations en empêchant les profils trop agressifs de saturer un nœud, tout en fournissant une visibilité claire sur l'impact réel (avant/après) de la configuration appliquée.

## 📅 Date de release
**22 octobre 2025**

---

## 🎯 Problèmes résolus

1. **Control-plane sursaturé** : un `density-factor` élevé sur un nœud critique pouvait laisser <500 Mi de RAM allocatable, provoquant des évictions et des timeouts kubelet/kube-apiserver.
2. **Workers sans garde-fou** : la combinaison `profil conservative + density 1.5` dépassait la capacité mémoire mais le script ne s'arrêtait qu'après génération de la configuration.
3. **Visibilité limitée** : il était difficile de connaître l'impact exact des réservations (différences allocatable avant/après).

---

## ✨ Nouveautés v2.0.13

### 1. Garde-fous dynamiques
- Density-factor plafonné à `1.0` sur les control-planes (`--density-factor` est automatiquement recadré avec un warning).
- Arrêt immédiat si l'allocatable projeté descend sous :
  - **25 % CPU** / **20 % RAM** sur les workers
  - **30 % CPU** / **25 % RAM** sur les control-planes
- Les profils trop agressifs sont donc refusés avant tout redémarrage du kubelet.

### 2. Pré-visualisation enrichie
- Estimation de l'allocatable final (`CPU` + `Mémoire`) et delta vs l'état actuel, même en `--dry-run`.
- Après une exécution réelle, le script relit la valeur sur l'API (`kubectl`) et affiche la variation effective.

### 3. Journalisation améliorée
- Messages clairs invitant à réduire le `density-factor` ou à changer de profil en cas de dépassement.
- Conservation des backups et validations existantes (yq v4, diff YAML, rotation des snapshots).

---

## 🧪 Validation

1. `./kubelet_auto_config.sh --dry-run` sur control-plane et worker
2. `./kubelet_auto_config.sh --profile conservative --density-factor 1.5`
   - ✅ Contrôle : le control-plane affiche le delta estimé mais refuse la configuration (<25 % RAM)
   - ✅ Worker : le script stoppe avec une erreur claire avant toute modification
3. Retest avec le profil par défaut pour confirmer la remise en état
4. `kubectl describe node` pour vérifier l'allocatable réel

---

## 📌 Version

**Tag Git :** `v2.0.13`

**Fichier :** `kubelet_auto_config.sh`

**Version interne :** `2.0.13`

