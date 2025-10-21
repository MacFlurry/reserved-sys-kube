# Tests Unitaires - kubelet_auto_config.sh

## Vue d'ensemble

Ce répertoire contient les tests unitaires pour le script `kubelet_auto_config.sh`. Les tests valident les calculs de réservations système et Kubernetes pour différentes configurations de nœuds.

## Structure

```
tests/
├── README.md                 # Ce fichier
└── test_calculations.sh      # Tests unitaires des fonctions calculate_*
```

## Exécution des tests

### Test complet

```bash
cd tests
./test_calculations.sh
```

### Intégration CI/CD

Exemple pour GitLab CI :

```yaml
# .gitlab-ci.yml
test:
  stage: test
  image: ubuntu:22.04
  before_script:
    - apt-get update && apt-get install -y bc
  script:
    - bash -n kubelet_auto_config.sh  # Vérification syntaxe
    - cd tests && ./test_calculations.sh
```

## Scénarios de test couverts

### 1. Profil GKE (Google Kubernetes Engine)
- **Petit nœud** : 2 vCPU, 4 GiB RAM
- **Nœud moyen** : 8 vCPU, 32 GiB RAM
- **Gros nœud** : 48 vCPU, 192 GiB RAM

### 2. Profil EKS (Amazon Elastic Kubernetes Service)
- **Nœud moyen** : 8 vCPU, 32 GiB RAM

### 3. Profil Conservative (Red Hat OpenShift-like)
- **Nœud moyen** : 8 vCPU, 32 GiB RAM

### 4. Profil Minimal
- **Nœud moyen** : 8 vCPU, 32 GiB RAM

### 5. Test de robustesse
- **Gestion des décimales** : Validation avec RAM=3.80 GiB (cas réel ARM64)

## Métriques validées

Pour chaque profil, les tests valident :
- `system-reserved.cpu` (en millicores)
- `system-reserved.memory` (en MiB)
- `kube-reserved.cpu` (en millicores)
- `kube-reserved.memory` (en MiB)

## Critères de passage

✅ **Tous les tests doivent passer** (25/25)
- Valeurs exactes pour les CPU (entiers)
- Plages acceptables pour la mémoire (± 5 MiB)
- Aucune valeur décimale dans les résultats
- Pas de plantage avec RAM décimale

## Ajout de nouveaux tests

Pour ajouter un test :

```bash
test_custom_scenario() {
    echo "Test: Mon scénario personnalisé"

    local vcpu=16
    local ram_gib=64
    local ram_mib=62464

    read -r sys_cpu sys_mem kube_cpu kube_mem <<< $(calculate_gke "$vcpu" "$ram_gib" "$ram_mib")

    assert_equals "Test CPU" "expected_value" "$sys_cpu"
    assert_in_range "Test Memory" "$sys_mem" min max
}
```

Puis appeler `test_custom_scenario` dans la fonction `main()`.

## Debugging

Si un test échoue :

1. **Vérifier la formule** dans `kubelet_auto_config.sh`
2. **Exécuter manuellement** la fonction :
   ```bash
   source ../kubelet_auto_config.sh
   calculate_gke 8 32 31232
   ```
3. **Valider les calculs bc** :
   ```bash
   echo "scale=0; (1024 + (31232 * 0.02)) / 1" | bc
   ```

## Maintenance

- **Mise à jour des tests** : Si les formules de calcul changent, adapter les valeurs attendues
- **Nouveaux profils** : Ajouter des tests pour chaque nouveau profil de calcul
- **Régression** : Conserver les tests historiques pour détecter les régressions
