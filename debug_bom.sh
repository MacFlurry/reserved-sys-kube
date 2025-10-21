#!/bin/bash
################################################################################
# Script de diagnostic BOM UTF-8
# À exécuter dans la VM Vagrant pour détecter le problème
################################################################################

echo "=== Diagnostic BOM UTF-8 ==="
echo ""

# 1. Vérifier le fichier actuel
echo "1. Premiers octets du fichier kubelet_auto_config.sh :"
if command -v hexdump &>/dev/null; then
    hexdump -C kubelet_auto_config.sh | head -1
elif command -v od &>/dev/null; then
    od -An -tx1 -N 16 kubelet_auto_config.sh
else
    echo "  ⚠ hexdump et od non disponibles"
fi
echo ""

# 2. Vérifier avec file
echo "2. Type de fichier détecté :"
file kubelet_auto_config.sh
echo ""

# 3. Vérifier le shebang
echo "3. Première ligne (shebang) :"
head -1 kubelet_auto_config.sh | cat -v
echo ""

# 4. Test d'exécution
echo "4. Test bash -n (vérification syntaxe) :"
if bash -n kubelet_auto_config.sh 2>&1; then
    echo "  ✓ Syntaxe OK"
else
    echo "  ✗ Erreur de syntaxe"
fi
echo ""

# 5. Nettoyage préventif si BOM détecté
echo "5. Vérification présence BOM UTF-8 :"
if head -c 3 kubelet_auto_config.sh | od -An -tx1 | grep -q "ef bb bf"; then
    echo "  ✗ BOM UTF-8 DÉTECTÉ !"
    echo ""
    echo "Nettoyage automatique :"

    # Backup
    cp kubelet_auto_config.sh kubelet_auto_config.sh.bom-backup
    echo "  → Backup créé : kubelet_auto_config.sh.bom-backup"

    # Nettoyage (supprimer les 3 premiers octets)
    tail -c +4 kubelet_auto_config.sh > kubelet_auto_config.sh.tmp
    mv kubelet_auto_config.sh.tmp kubelet_auto_config.sh
    chmod +x kubelet_auto_config.sh

    echo "  → BOM supprimé"
    echo "  → Vérification post-nettoyage :"
    head -1 kubelet_auto_config.sh
else
    echo "  ✓ Pas de BOM détecté"
fi
echo ""

# 6. Test final
echo "6. Test --help après nettoyage :"
./kubelet_auto_config.sh --help 2>&1 | head -5
echo ""
echo "=== Fin du diagnostic ==="
