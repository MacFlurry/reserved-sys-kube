# Changelog v2.0.12 - Réservations éphémères adaptatives & robustesse kubelet

> **Note :** Cette version supprime les réservations `ephemeral-storage` figées (10 Gi / 5 Gi) pour les adapter dynamiquement à la capacité réelle du nœud, évitant ainsi les redémarrages en boucle du kubelet sur les disques modestes.

## 📅 Date de release
**22 octobre 2025**

---

## 🎯 Problème résolu

### Contexte

Sur des environnements de test ou des contrôleurs ARM compacts, le disque associé à `/var/lib/kubelet` est souvent inférieur à 10 Gi. La version `v2.0.11` réservait néanmoins :

```yaml
systemReserved:
  ephemeral-storage: "10Gi"
kubeReserved:
  ephemeral-storage: "5Gi"
```

**Résultat :**

```
invalid Node Allocatable configuration. Resource "ephemeral-storage"
has a reservation of 16.0Gi but capacity of 9.7Gi. Expected capacity >= reservation.
```

Le kubelet basculait alors continuellement en `CrashLoopBackOff`, forçant un rollback automatique du script et bloquant toute mise à jour de configuration.

---

## ✨ Nouveautés v2.0.12

### 1. **Réservations éphémères dynamiques**

Le script mesure désormais la capacité réelle (`df -BM /var/lib/kubelet`) et applique des ratios conservateurs :

| Réservation        | Ratio max | Bornes min / max |
|--------------------|-----------|------------------|
| `system-reserved`  | 30 %      | `≥256 Mi` & `≤10 Gi` |
| `kube-reserved`    | 20 %      | `≥128 Mi` & `≤5 Gi`  |

En cas de capacité réduite, les valeurs sont abaissées tout en garantissant un total ≤ 80 % du disque. Les journaux détaillent la valeur retenue pour chaque nœud.

### 2. **Vérification kubelet plus robuste**

La boucle d’attente passe de 15 s à **60 s** avec un polling toutes les 5 s. Le kubelet a ainsi le temps de recharger sa configuration sur des hyperviseurs plus lents avant qu’un rollback ne soit déclenché.

### 3. **Logs propres dans les sous-shells**

Toutes les fonctions `log_*` écrivent maintenant sur `stderr`. Les appels du type `value=$(command)` ne polluent plus la sortie standard, éliminant les erreurs `sed: unknown command` observées en `--dry-run`.

### 4. **Rotation des backups compatible `set -e`**

L’incrémentation `((history_count++))` a été remplacée par `history_count=$((history_count + 1))` pour éviter les erreurs `set -e` lorsque `history_count` est indéfini.

---

## ✅ Résultat

- Kubelet redémarre correctement sur des disques < 10 Gi.
- Les réservations CPU/RAM continuent d’être calculées selon le profil sélectionné (`gke` par défaut).
- Les backups `config.yaml.last-success.{0..3}` sont conservés proprement après chaque exécution.

---

## 🧪 Validation

1. `./kubelet_auto_config.sh --dry-run` sur `cp1` et `w1`
2. `./kubelet_auto_config.sh` sur les deux nœuds
3. `kubectl describe node` pour vérifier `Allocatable` (`CPU`, `memory`, `ephemeral-storage`)
4. Inspection des backups dans `/var/lib/kubelet/`

---

## 🔁 Mise à niveau

```bash
scp kubelet_auto_config.sh root@<node>:/usr/local/bin/
ssh root@<node> "chmod +x /usr/local/bin/kubelet_auto_config.sh"
ssh root@<node> "sudo kubelet_auto_config.sh --dry-run"
ssh root@<node> "sudo kubelet_auto_config.sh"
```

---

## 📌 Version

**Tag Git :** `v2.0.12`  
**Fichier :** `kubelet_auto_config.sh`  
**Version interne :** `2.0.12`

