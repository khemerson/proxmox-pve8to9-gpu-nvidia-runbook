# Runbook : migrer Proxmox VE 8.4 vers 9.2 sur un nœud GPU NVIDIA sans IPMI

[![License: CC BY-SA 4.0](https://img.shields.io/badge/License-CC%20BY--SA%204.0-lightgrey.svg)](https://creativecommons.org/licenses/by-sa/4.0/) ![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-9.2.3-E57000) ![Kernel](https://img.shields.io/badge/kernel-7.0.12--pve-blue) ![NVIDIA](https://img.shields.io/badge/NVIDIA-595.71.05%20open-76B900) ![Debian](https://img.shields.io/badge/Debian-13%20trixie-A81D33)

> 🇫🇷 Runbook en français. 🇬🇧 A reproducible runbook for migrating a production GPU Proxmox node — PVE 8.4→9.2, kernel 6.8→7.0, NVIDIA 570→595 (open modules), LXC passthrough — with **no out-of-band access (no IPMI)**. Includes a real post-migration throughput-drop diagnosis that turned out *not* to be a regression.

Guide reproductible et retour d'expérience pour migrer un hyperviseur Proxmox de production servant plusieurs agents LLM en inférence locale, avec passthrough GPU vers des conteneurs LXC. Couvre le passage de PVE 8.4 à 9.2, du kernel 6.8 au kernel 7.0, et la mise à niveau forcée du driver NVIDIA 570 vers 595. Inclut le diagnostic d'une baisse de débit apparue après migration, qui n'était pas une régression de la nouvelle pile.

Le document est conçu pour être suivi commande par commande. Les valeurs spécifiques sont sorties dans un bloc de variables en tête. Adaptez ces variables, lisez la matrice de décision, puis déroulez les phases.

| | |
|---|---|
| Version du runbook | 1.1 (30 juin 2026) |
| Testé sur | PVE 8.4.16 vers 9.2.3, kernel 6.8.12-18-pve vers 7.0.12-1-pve, Debian 12 vers 13 |
| Driver NVIDIA | 570.153.02 vers 595.71.05 (modules open) |
| Matériel de référence | AMD EPYC 7742 (Zen 2), 512 Go DDR4, 2x RTX 4090 + 2x RTX 3090, double alimentation |
| Contrainte | Aucun accès hors bande (pas d'IPMI ni iKVM), console physique uniquement |
| Licence | CC BY-SA 4.0 |

## Changelog

- 1.1 (2026-06-30) : corrections de reproductibilité (composant `non-free-firmware` requis pour le microcode, ordre des phases) ; ajouts issus du run réel (vérification Secure Boot/MOK, libération des modules NVIDIA avant purge, build DKMS explicite pour le kernel cible, dérive du major `nvidia-uvm`, distinction passthrough as-run vs recommandé).
- 1.0 (2026-06-30) : version initiale, migration réelle d'un nœud GPU 4 cartes.

## Avertissement

Ce runbook reflète une migration réelle sur une configuration précise. Le kernel 7.0 et le driver 595 sont récents et évoluent vite. Ne collez pas les commandes sans les lire. Selon votre bootloader (GRUB ou systemd-boot), votre stockage (LVM ou ZFS), votre flavour de driver (open ou proprietary) et votre matériel, plusieurs étapes changent. La matrice de décision ci-dessous indique quelles bifurcations vous concernent. Chaque phase fournit son point de retour arrière. Validez chaque vérification avant de passer à la suivante.

## Sommaire

1. [À qui s'adresse ce guide](#1-à-qui-sadresse-ce-guide)
2. [Variables à adapter](#2-variables-à-adapter)
3. [Matrice de décision](#3-matrice-de-décision)
4. [Principe directeur sans IPMI](#4-principe-directeur-sans-ipmi)
5. [Phase 0 : sauvegardes et captures de référence](#5-phase-0--sauvegardes-et-captures-de-référence)
6. [Phase 1 : pré-checks](#6-phase-1--pré-checks)
7. [Phase 2 : durcissements avant reboot](#7-phase-2--durcissements-avant-reboot)
8. [Phase 3 : bascule des dépôts et dist-upgrade](#8-phase-3--bascule-des-dépôts-et-dist-upgrade)
9. [Phase 4 : driver NVIDIA, l'étape critique](#9-phase-4--driver-nvidia-létape-critique)
10. [Phase 5 : reboot et validation](#10-phase-5--reboot-et-validation)
11. [Phase 6 : diagnostiquer une baisse de performance](#11-phase-6--diagnostiquer-une-baisse-de-performance)
12. [Phase 7 : optimiser les power limits](#12-phase-7--optimiser-les-power-limits)
13. [Procédure de rollback complète](#13-procédure-de-rollback-complète)
14. [Checklist condensée](#14-checklist-condensée)
15. [Pièges à retenir](#15-pièges-à-retenir)
16. [Sources](#16-sources)

## 1. À qui s'adresse ce guide

Vous administrez un hôte Proxmox VE 8.4 standalone qui passe un ou plusieurs GPU NVIDIA à des conteneurs LXC (pas des VM) et vous voulez migrer vers 9.2. Le guide est particulièrement pertinent si vous n'avez pas d'accès hors bande, car la stratégie est construite autour de cette contrainte. Si vous faites du passthrough vers des VM, l'essentiel sur le driver et le kernel reste valable mais la partie LXC ne s'applique pas.

Prérequis de départ :

- Un accès SSH root au nœud, idéalement depuis un hôte tiers qui le joint par son IP de gestion directe (pas via un DNS hébergé sur le nœud lui-même).
- Une fenêtre de maintenance et, pour le reboot, une présence physique devant la machine avec écran et clavier.
- De l'espace disque libre pour les sauvegardes et le téléchargement des paquets.

## 2. Variables à adapter

Définissez ces variables au début de votre session. Elles sont réutilisées dans toutes les commandes du guide.

```bash
# Identité du nœud
NODE_IP="192.0.2.10"                 # IP de gestion SSH du nœud
NODE_NAME="<node>"                      # hostname (pour nommer les rapports)
# Conteneurs
GPU_LXC="201 202 203"                   # VMID des conteneurs avec passthrough GPU
ALL_GUESTS="201 202 203 204 205 206 207 208"  # tous les invités à arrêter avant reboot
# GPU et driver
GPU_COUNT=4                             # nombre de GPU physiques sur le nœud
NVIDIA_TARGET="595.71.05"               # version driver cible (Production Branch compatible kernel 7.0)
RENDER_GID=44                           # gid du groupe propriétaire des device nodes (À VÉRIFIER, voir Phase 4)
# Espace de travail (sur l'hôte d'orchestration)
WORK="$HOME/migration/pve8to9/${NODE_NAME}"
mkdir -p "$WORK"/{backups,reports,configs}
# Helper SSH
N() { ssh -o BatchMode=yes "root@${NODE_IP}" "$@"; }
```

La variable `TARGET_KERNEL` n'est pas fixée d'avance car le numéro exact dépend de ce que le dist-upgrade installe. Vous la relèverez en Phase 3 :

```bash
# À exécuter après le dist-upgrade (Phase 3)
TARGET_KERNEL=$(N "dpkg -l 'proxmox-kernel-7*' | awk '/^ii/{print \$2}' | grep -oE '7\.[0-9.]+-[0-9]+-pve' | sort -V | tail -1")
echo "Kernel cible : $TARGET_KERNEL"
```

## 3. Matrice de décision

Repérez votre configuration dans chaque ligne. La colonne de droite indique la section à appliquer ou à ignorer.

| Si votre nœud | Alors |
|---|---|
| démarre via `proxmox-boot-tool` (présence de `/etc/kernel/proxmox-boot-uuids`) | Phase 2, traitez le meta-package `systemd-boot` (FAIL bloquant typique) |
| démarre via GRUB classique | Phase 2, vérifiez plutôt `grub-efi-amd64` et le timeout GRUB |
| utilise ZFS (`zpool list` renvoie un pool) | Ne lancez jamais `zpool upgrade` pendant la migration (irréversible) |
| utilise LVM ou LVM-thin | Pas de contrainte ZFS, voir l'avis autoactivation en Phase 1 |
| Secure Boot actif (`mokutil --sb-state`) | Phase 1, enrôlez la clé MOK DKMS ou désactivez Secure Boot (sinon modules non chargés au boot) |
| driver NVIDIA en modules open (`modinfo nvidia` mentionne une licence duale ou MIT/GPL) | Conservez les modules open en 595 |
| driver NVIDIA proprietary | Conservez le proprietary en 595, même logique d'install |
| GPU Pascal ou Kepler | La branche 595 ne les supporte plus, ce guide ne couvre pas ce cas |
| GPU Ada, Ampere, Hopper, Blackwell | Compatibles 595, vous êtes dans le périmètre |
| CPU AMD Zen 5 | Vérifiez le microcode pour le bug RDSEED (CVE-2025-62626) |
| CPU AMD Zen 2/3/4 ou Intel | Non concerné par RDSEED, microcode recommandé pour les correctifs génériques |

## 4. Principe directeur sans IPMI

L'idée centrale : valider que le nouveau driver compile pour le kernel 7.0 pendant que la machine tourne encore sur le kernel 6.8, avant le reboot.

Sans accès hors bande, un reboot raté est coûteux. Le pire scénario est de redémarrer sur le kernel 7.0, de découvrir que le driver ne charge pas, et de se retrouver avec tous les GPU morts sans moyen d'intervention distante. On élimine ce scénario en installant le driver cible avec DKMS après le dist-upgrade mais avant le reboot. À ce moment, les en-têtes des deux kernels sont présents. DKMS compile le module pour le 6.8 actif (testable tout de suite avec `nvidia-smi`) et pour le 7.0 cible (build vérifiable avec `dkms status`). Si le build 7.0 échoue, on le voit sans avoir rebooté, la machine reste fonctionnelle sur le 6.8, et on revient au driver précédent pour diagnostiquer à froid.

Trois règles encadrent l'opération : des points d'arrêt humains avant chaque action irréversible (dist-upgrade, changement de driver, reboot), une présence physique au reboot avec un menu de boot visible 30 secondes et un kernel de secours listé, et un chemin de retour arrière préservé de bout en bout.

## 5. Phase 0 : sauvegardes et captures de référence

Objectif : pouvoir tout restaurer et disposer d'un état GPU de référence pour comparer après reboot.

Prérequis : accès SSH root au nœud, espace disque pour les `vzdump`.

### Sauvegarde des fichiers de configuration

```bash
N "tar czf /tmp/${NODE_NAME}_etc_$(date +%Y%m%d_%H%M%S).tgz \
  /etc/pve/lxc /etc/network/interfaces /etc/apt /etc/modprobe.d /etc/default/grub 2>/dev/null"
scp "root@${NODE_IP}:/tmp/${NODE_NAME}_etc_*.tgz" "$WORK/backups/"
```

### Captures GPU de référence

Ces captures sont votre point de comparaison après reboot (versions, bus PCI, device nodes, flavour). La capture du power limit en charge est aussi précieuse pour la Phase 6 : elle prouve a posteriori qu'un éventuel cap n'est pas une régression de la migration.

```bash
N "nvidia-smi --query-gpu=index,name,pci.bus_id,driver_version --format=csv" | tee "$WORK/configs/gpu_AVANT.txt"
N "nvidia-smi"                              | tee "$WORK/configs/nvidia_smi_AVANT.txt"  # capture aussi la colonne Pwr/Cap
N "lspci -nnk | grep -A3 -i nvidia"        | tee "$WORK/configs/pci_nvidia_AVANT.txt"
N "modinfo nvidia | grep -E 'version|license'" | tee "$WORK/configs/driver_flavour.txt"
N "ls -l /dev/nvidia*"                      | tee "$WORK/configs/dev_nodes_AVANT.txt"
for VMID in $GPU_LXC; do N "pct config $VMID" > "$WORK/configs/lxc_${VMID}.conf"; done
```

### Sauvegarde des conteneurs

Excluez les volumes de poids de modèles, volumineux et rechargeables. Sauvegardez la configuration et l'état applicatif. Si un conteneur n'est pas snapshotable (bind-mount actif), utilisez le mode stop.

```bash
# Conteneurs snapshotables
for VMID in 205 206 207 208; do
  N "vzdump $VMID --mode snapshot --compress zstd --dumpdir /var/lib/vz/dump 2>&1 | tail -5"
done
# Conteneur non snapshotable (exemple : service avec bind-mount)
N "vzdump 204 --mode stop --compress zstd --dumpdir /var/lib/vz/dump 2>&1 | tail -5"
```

Vérification (sortie attendue : des fichiers `.tar.zst` non vides) :

```bash
N "ls -lah /var/lib/vz/dump/*.tar.zst | tail"
```

Note : si l'espace de la cible de dump est limité, traitez les conteneurs un par un et rapatriez chaque archive (`scp`) avant de passer au suivant. Sur le nœud de référence, les rootfs des conteneurs GPU vivaient sur un stockage séparé et les poids de modèles sur un montage à part (exclu des vzdump) ; le filet de secours réel reposait surtout sur le kernel 6.x conservé et le driver précédent (voir section 13), les vzdump couvrant les services à état applicatif.

Rollback de cette phase : aucune modification système n'a été faite, rien à annuler.

## 6. Phase 1 : pré-checks

Objectif : appliquer les derniers correctifs 8.4, vérifier Secure Boot, puis faire tourner le checker officiel et traiter ses retours.

Prérequis : Phase 0 terminée.

### Appliquer les point releases 8.4 sans changer de version majeure

Le checker `pve8to9` n'existe que dans une 8.4 récente. Appliquez d'abord les mises à jour 8.4 sans reboot.

```bash
N "apt-get update -qq && apt-get -s dist-upgrade | grep -E 'upgraded|installed' | tail -3"
# Si des paquets 8.4 sont en attente, les appliquer (toujours en 8.4) :
N "DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y"
```

### Vérifier Secure Boot (critique sans IPMI)

Vos modules NVIDIA construits par DKMS sont signés avec la clé MOK de DKMS. Si Secure Boot est actif et que cette clé n'est pas enrôlée, les modules **ne se chargeront pas au boot du kernel 7.0**, et l'enrôlement MOK exige une saisie au prochain démarrage **en console physique**. Tranchez ce point avant le reste.

```bash
N "mokutil --sb-state"
# 'SecureBoot disabled' (ou 'Setup Mode') => rien à faire.
# 'SecureBoot enabled' => deux options :
#   a) enrôler la clé DKMS :  mokutil --import /var/lib/dkms/mok.pub
#      (définit un mot de passe, validation au reboot via MokManager, en console physique)
#   b) désactiver Secure Boot dans le firmware (intervention physique elle aussi).
```

Sur le nœud de référence, `SecureBoot disabled, Setup Mode` : les modules signés se chargent sans enrôlement.

### Lancer le checker

```bash
N "pve8to9 --full" 2>&1 | tee "$WORK/reports/pve8to9.txt"
```

Lecture des retours et traitement. Voici les cas rencontrés sur le nœud de référence et leur résolution.

| Retour | Gravité | Traitement |
|---|---|---|
| meta-package `systemd-boot` installé | FAIL bloquant | À retirer en Phase 2 |
| modules DKMS présents | WARN | Attendu (driver NVIDIA), traité en Phase 4 |
| `amd64-microcode` absent | WARN | Installer **après bascule trixie** (fin de Phase 3) |
| N invités en cours | WARN | Arrêt propre avant reboot (Phase 5) |
| dépôts tiers avec suites inhabituelles | NOTICE | Corriger en Phase 3 |
| autoactivation LVM sur volumes invités | NOTICE | Sans danger sur stockage local, peut être désactivé |

Vérification (sortie attendue) : zéro FAIL non traité avant de continuer. Tant qu'un FAIL bloquant subsiste, ne passez pas à la Phase 3.

Rollback de cette phase : les mises à jour 8.4 sont des correctifs mineurs sans bascule de version, pas de retour arrière nécessaire.

## 7. Phase 2 : durcissements avant reboot

Objectif : retirer le blocage bootloader, figer les noms d'interfaces, et rendre le menu de boot exploitable sans IPMI.

Prérequis : Phase 1 terminée, FAIL bootloader identifié.

### Bootloader (cas systemd-boot)

Sur un système `proxmox-boot-tool`, retirez le meta-package `systemd-boot` en conservant `systemd-boot-efi`.

```bash
N "test -d /etc/kernel/proxmox-boot-uuids && echo 'proxmox-boot-tool detecté' || echo 'GRUB classique'"
# Si proxmox-boot-tool et que pve8to9 a remonté le FAIL systemd-boot :
N "apt-get remove -y systemd-boot"          # conserve systemd-boot-efi
N "proxmox-boot-tool refresh"
```

Sur le nœud de référence (GRUB classique en UEFI via shim), le meta-package `systemd-boot` était installé mais spurieux : `apt-get remove -y systemd-boot` ne retire que lui (vérifiez en simulation `apt-get -s remove systemd-boot`), `systemd-boot-efi` reste.

### Bootloader (cas GRUB classique)

```bash
# Si UEFI mais grub-pc installé au lieu de grub-efi-amd64 :
N "echo 'grub-efi-amd64 grub2/force_efi_extra_removable boolean true' | debconf-set-selections"
N "apt-get install -y grub-efi-amd64"
```

### Épingler les interfaces réseau par MAC

Évite le renommage des interfaces au passage du kernel 7.0, qui pourrait couper le réseau de gestion. Épinglez au nom actuel, c'est moins disruptif qu'une renumérotation. Les noms `eno*` (issus du firmware/SMBIOS) sont assez stables ; le risque est plus élevé pour les noms `enpXsY` (dérivés du chemin PCI).

```bash
N "ip -br link" | tee "$WORK/reports/iface_AVANT.txt"
# Pour chaque interface de gestion (exemple eno1), créer un fichier .link :
N "MAC=\$(cat /sys/class/net/eno1/address); cat > /etc/systemd/network/10-pin-eno1.link <<EOF
[Match]
MACAddress=\$MAC
[Link]
Name=eno1
EOF"
# Valider AVANT de faire confiance : la sortie doit résoudre vers le bon nom
N "udevadm test-builtin net_setup_link /sys/class/net/eno1 2>&1 | grep -E 'is applied|Name='"
```

Les fichiers `.link` seront intégrés à l'initramfs lors du `update-initramfs` de la Phase 4.

### Rendre le menu de boot visible

Sur systemd-boot, réglez le timeout via `proxmox-boot-tool`. Sur GRUB, via `/etc/default/grub`. L'objectif est d'avoir 30 secondes pour sélectionner un kernel de secours en console physique. Vous reviendrez à 5 secondes après plusieurs reboots concluants.

```bash
# GRUB classique :
N "cp /etc/default/grub /etc/default/grub.bak-pve8"
N "sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=30/' /etc/default/grub"
N "grep -q GRUB_TIMEOUT_STYLE /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub"
N "update-grub"
N "grep -m1 'set timeout' /boot/grub/grub.cfg"   # vérifier : set timeout=30
```

Vérification : `pve8to9 --full` relancé ne montre plus de FAIL bootloader, l'interface de gestion conserve son nom, le menu de boot est configuré pour 30 secondes.

Rollback de cette phase : restaurez `/etc/default/grub.bak-pve8`, retirez le fichier `.link` créé. Aucune de ces actions ne touche au système de boot de façon irréversible.

## 8. Phase 3 : bascule des dépôts et dist-upgrade

Objectif : passer les dépôts en trixie, corriger les dépôts cassants, exécuter le dist-upgrade sans reboot, puis installer le microcode.

Prérequis : Phases 0 à 2 terminées, zéro FAIL.

### Corriger les dépôts qui cassent apt

```bash
# Le dépôt enterprise créé par PVE 9 renvoie 401 sans abonnement : le désactiver
N "test -f /etc/apt/sources.list.d/pve-enterprise.sources && \
   (grep -q '^Enabled:' /etc/apt/sources.list.d/pve-enterprise.sources && \
    sed -i 's/^Enabled:.*/Enabled: false/' /etc/apt/sources.list.d/pve-enterprise.sources || \
    echo 'Enabled: false' >> /etc/apt/sources.list.d/pve-enterprise.sources) || true"
# Un ancien dépôt tiers signé en SHA1 (ex. CUDA debian12) sera rejeté par la politique crypto de trixie : le commenter
N "for f in /etc/apt/sources.list.d/*.list; do grep -q debian12 \"\$f\" 2>/dev/null && \
   { cp \"\$f\" \"\$f.bak\"; sed -i 's/^deb /# deb /' \"\$f\"; }; done"
```

### Basculer Debian et Proxmox vers trixie

N'utilisez pas un simple `sed s/bookworm/trixie/g` : il ne crée pas le composant `non-free-firmware` (indispensable pour `amd64-microcode`) et peut laisser une URL security non canonique. Écrivez les sources explicitement.

```bash
N "cp -a /etc/apt/sources.list /etc/apt/sources.list.bak-pve8"
N "cp -a /etc/apt/sources.list.d /etc/apt/sources.list.d.bak-pve8 2>/dev/null || true"
# Repérer ce qui référence encore bookworm (pour ne rien oublier dans les .list tiers)
N "grep -rl bookworm /etc/apt/ 2>/dev/null"
# Réécrire le sources.list principal en trixie, avec non-free-firmware
N "cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF"
# Pour les dépôts tiers légitimes encore en bookworm (ex. docker), bumpez la suite si elle existe en trixie
N "for f in /etc/apt/sources.list.d/*.list; do grep -q bookworm \"\$f\" 2>/dev/null && sed -i 's/bookworm/trixie/g' \"\$f\"; done"
```

Vérification (sortie attendue : aucune erreur, aucune clé GPG manquante, `non-free-firmware` listé) :

```bash
N "apt-get update" 2>&1 | tee "$WORK/reports/apt_update_9.txt"
```

### Simuler puis lancer le dist-upgrade

```bash
N "apt-get -s dist-upgrade" 2>&1 | tee "$WORK/reports/distupgrade_dryrun.txt"
```

Examinez la simulation. Les paquets retirés doivent être uniquement d'anciennes bibliothèques partagées (transition ABI `t64`/time_t, modules Python obsolètes). Aucun paquet PVE ni de service ne doit être retiré, et surtout aucun kernel 6.x. Si un kernel 6.x apparaît dans les suppressions, arrêtez et corrigez avant de continuer, c'est votre filet de secours.

Lancez le dist-upgrade détaché. `openssh-server` est mis à jour pendant l'opération, une coupure SSH ne doit pas tuer le processus.

```bash
N "setsid bash -c 'DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
  -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" \
  > /var/log/pve8to9_distupgrade.log 2>&1 ; echo \$? > /var/log/pve8to9_distupgrade.done'"
# Suivre l'avancement
while true; do
  RC=$(N "cat /var/log/pve8to9_distupgrade.done 2>/dev/null")
  [ -n "$RC" ] && { echo "dist-upgrade terminé RC=$RC"; break; }
  sleep 15; echo "  en cours..."
done
scp "root@${NODE_IP}:/var/log/pve8to9_distupgrade.log" "$WORK/reports/"
```

Note : `rsyslog` peut se bloquer pendant le dist-upgrade à cause d'un conflit de socket sous trixie. Ce blocage se résout au reboot, sans impact. De même, des avertissements AppArmor `Failed to load policy-features` peuvent apparaître pendant la phase de configuration des paquets : transitoires, résolus au reboot. L'audit `dpkg` (ci-dessous) reste l'indicateur faisant foi.

Vérification après dist-upgrade, avant reboot (sorties attendues entre parenthèses) :

```bash
N "dpkg --audit"                                    # (vide)
N "apt-get -s -f install"                           # (rien à corriger)
N "pveversion"                                      # (pve-manager 9.2.x)
N "dpkg -l 'proxmox-kernel-*' | grep '^ii'"         # (un kernel 7.0.x ET des kernels 6.x présents)
# Confirmer que le menu GRUB liste bien le 7.0 par défaut et les 6.x en secours
N "grep -E \"menuentry '\" /boot/grub/grub.cfg | head"
# Fixer la variable du kernel cible
TARGET_KERNEL=$(N "dpkg -l 'proxmox-kernel-7*' | awk '/^ii/{print \$2}' | grep -oE '7\.[0-9.]+-[0-9]+-pve' | sort -V | tail -1")
echo "Kernel cible : $TARGET_KERNEL"
```

### Microcode CPU (après bascule trixie)

`amd64-microcode` (et `intel-microcode`) vit dans le composant `non-free-firmware`, activé seulement à l'étape précédente : c'est pourquoi cette installation arrive ici et non plus tôt. Le microcode est chargé en early-boot ; il deviendra actif au reboot de la Phase 5.

```bash
N "apt-get install -y amd64-microcode && update-initramfs -u"   # ou intel-microcode
N "lsinitramfs /boot/initrd.img-${TARGET_KERNEL} | grep -i microcode | head"   # confirmer l'inclusion
```

Rollback de cette phase : tant que vous n'avez pas rebooté, la machine tourne toujours sur le kernel 6.8. Restaurez les sources depuis les `.bak-pve8` si vous renoncez. Après reboot, le rollback passe par la sélection d'un kernel 6.x (section 13).

## 9. Phase 4 : driver NVIDIA, l'étape critique

Objectif : installer le driver cible et valider qu'il compile pour le kernel 7.0, le tout pendant qu'on tourne encore sur le 6.8.

Prérequis : dist-upgrade réussi, `TARGET_KERNEL` défini, conteneurs GPU encore en marche, fichier `.run` du driver cible déjà déposé sur le nœud (par exemple `/root/NVIDIA-Linux-x86_64-${NVIDIA_TARGET}.run`, vérifié via `sh fichier.run --check`).

### En-têtes des deux kernels

DKMS doit pouvoir compiler pour le kernel actif (6.8) et pour le cible (7.0). Les en-têtes du kernel actif sont normalement déjà présents ; installez ceux du cible.

```bash
N "apt-get install -y proxmox-default-headers"
N "apt-get install -y proxmox-headers-${TARGET_KERNEL}"
N "for k in \$(uname -r) ${TARGET_KERNEL}; do test -d /usr/src/linux-headers-\$k && echo \"OK \$k\" || echo \"MANQUE \$k\"; done"
```

Note : tous les anciens kernels 6.x n'ont pas forcément leurs en-têtes publiés dans le dépôt PVE 9. Privilégiez comme kernel de secours **celui qui tourne actuellement** (en-têtes présents, driver buildé pour lui ci-dessous) plutôt que le 6.x le plus récent.

### Blacklister nouveau, nova et nova_core

Le kernel 7.0 introduit `nova` et `nova_core`, un pilote GPU open source en Rust qui prend la main au démarrage et entre en conflit avec NVRM. À blacklister en plus de `nouveau`.

```bash
N "cat > /etc/modprobe.d/blacklist-nvidia-nova.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
blacklist nova
blacklist nova_core
options nova modeset=0
EOF
update-initramfs -u -k all"
```

### Arrêter les conteneurs GPU et libérer les modules

```bash
for VMID in $GPU_LXC; do N "pct shutdown $VMID --timeout 90"; done
N "pct list | grep -E '$(echo $GPU_LXC | tr ' ' '|')'"
```

Avant de purger le driver, identifiez et arrêtez **tous les consommateurs GPU côté hôte** : sinon les modules `nvidia*` restent chargés (refcount non nul) et le nouveau module ne pourra pas se charger sur le 6.8, ce qui ruine la validation pré-reboot. Sur le nœud de référence, c'était un conteneur Docker `dcgm-exporter` (export de métriques GPU) qui tenait le module.

```bash
# Qui tient les modules ?
N "fuser -v /dev/nvidia* 2>&1; lsmod | grep -i nvidia; nvidia-smi --query-compute-apps=pid,process_name --format=csv"
# Arrêter les consommateurs hôte (adapter à votre stack de monitoring)
N "docker stop \$(docker ps -q --filter ancestor=nvidia/dcgm-exporter) 2>/dev/null || true"
N "systemctl stop nvidia-persistenced 2>/dev/null || true"
```

### Purger l'ancien driver et installer le cible

Purgez le driver actuel selon son mode d'installation : fichier `.run` via `nvidia-uninstall`, ou `apt purge` des paquets. Sur le nœud de référence (install par `.run` avec DKMS), c'était `nvidia-uninstall`.

```bash
N "nvidia-uninstall --silent"
# Après la purge, 'modprobe -r' échoue souvent (fichiers de module retirés) : utiliser rmmod par nom
N "rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null; lsmod | grep -i nvidia || echo 'modules déchargés'"
```

Installez ensuite le driver cible dans le **même flavour** que l'existant (open ou proprietary, voir `driver_flavour.txt` de la Phase 0), avec DKMS. Point clé souvent oublié : **`--dkms` ne compile que pour le kernel actif** ; il faut forcer explicitement le build du kernel cible, sans quoi il n'existe pas et la validation ci-dessous serait vide.

```bash
# Exemple en modules open (retirer --kernel-module-type=open pour le proprietary)
N "/root/NVIDIA-Linux-x86_64-${NVIDIA_TARGET}.run --silent --accept-license \
   --dkms --kernel-module-type=open --no-x-check --no-nouveau-check"
# Forcer le build pour le kernel cible
N "dkms install nvidia/${NVIDIA_TARGET} -k ${TARGET_KERNEL}"
```

Si vous aviez `nvidia-persistenced`, vérifiez sa compatibilité de version avant de le réinstaller/relancer.

### Validation conditionnant le reboot

C'est le point de décision le plus important. Deux vérifications pendant qu'on est encore sur le 6.8 :

```bash
N "modprobe nvidia nvidia_uvm"                                      # recharger le nouveau module sur le 6.8
N "nvidia-smi --query-gpu=index,name,driver_version --format=csv"   # attendu : GPU_COUNT cartes, version NVIDIA_TARGET
N "dkms status | grep nvidia"                                       # attendu : 'installed' pour 6.8 ET ${TARGET_KERNEL}
N "cat /proc/driver/nvidia/version"                                 # confirmer le flavour (Open Kernel Module / proprietary)
```

Critère de décision : si `nvidia-smi` voit toutes les cartes sur le 6.8 et que `dkms status` montre un build réussi pour le kernel 7.0, vous pouvez rebooter en confiance. Si le build 7.0 a échoué, ne rebootez pas. Revenez au driver précédent (section 13), la machine reste fonctionnelle sur le 6.8, et diagnostiquez à froid.

### Réaligner l'espace utilisateur NVIDIA dans les conteneurs

`llama-server` utilise la `libcuda` installée dans chaque conteneur. Si l'hôte passe en 595 mais qu'un conteneur garde un espace utilisateur 570, CUDA échoue dans ce conteneur (`Driver/library version mismatch`). Ce réalignement se fait une fois les conteneurs redémarrés (Phase 5) : mettez à jour l'espace utilisateur de chaque conteneur GPU vers la version cible, **avec `--no-kernel-module`** (le module noyau est celui de l'hôte). Le même `.run` peut être poussé dans le conteneur (`pct push`) puis exécuté via `pct exec`, ou déployé par votre outil de configuration.

```bash
# Forme générique (dans chaque conteneur GPU, après son démarrage en Phase 5)
N "pct push <VMID> /root/NVIDIA-Linux-x86_64-${NVIDIA_TARGET}.run /tmp/nv.run --perms 0755"
N "pct exec <VMID> -- /tmp/nv.run --silent --accept-license --no-kernel-module --no-nouveau-check --no-x-check"
```

### Rappel sur le set de device nodes

Le passthrough LXC repose sur l'exposition des device nodes. `libcuda` énumère les GPU de manière contiguë à partir de `/dev/nvidia0`. Exposez l'ensemble des nodes, même pour un conteneur mono GPU, sinon l'énumération s'interrompt.

> As-run vs recommandé : le nœud de référence utilisait la forme historique `lxc.mount.entry: /dev/nvidiaN ...` combinée à `lxc.cgroup2.devices.allow: a` (apparmor unconfined). La forme native `dev[n]:` ci-dessous est la **modernisation recommandée** (elle n'a pas été la config réellement déployée sur ce nœud). Avant de l'adopter, **vérifiez le gid réel** du groupe propriétaire des nodes dans votre conteneur — `RENDER_GID` n'est pas universellement 44 :

```bash
N "stat -c '%g %G' /dev/nvidia0"   # relever le gid réel à mettre dans RENDER_GID
```

Forme paramétrée à mettre dans la configuration de chaque conteneur GPU :

```bash
# Génère les lignes de passthrough pour un conteneur (à insérer dans /etc/pve/lxc/<VMID>.conf)
gen_passthrough() {
  local i n=0
  for i in $(seq 0 $((GPU_COUNT-1))); do
    echo "dev${n}: /dev/nvidia$i,gid=${RENDER_GID}"; n=$((n+1))
  done
  for node in nvidiactl nvidia-uvm nvidia-uvm-tools; do
    echo "dev${n}: /dev/$node,gid=${RENDER_GID}"; n=$((n+1))
  done
}
gen_passthrough
```

La forme native `dev[n]:` (disponible depuis PVE 8.1) est préférable aux `lxc.mount.entry` bruts : elle gère automatiquement les règles cgroup, re-résout le couple major:minor au démarrage du conteneur (robuste à la dérive de major, voir Phase 5) et fonctionne en conteneur non privilégié sans `lxc.cgroup2.devices.allow`. À noter : PVE 9.2 n'apporte pas de support CDI natif dans `pct`, le passage par device node reste la méthode.

Rollback de cette phase : tant qu'aucun reboot n'a eu lieu, réinstallez le driver précédent (conservé en Phase 0) et la machine reste opérationnelle sur le 6.8.

## 10. Phase 5 : reboot et validation

Objectif : redémarrer sur le kernel 7.0 et valider du plus général au plus spécifique.

Prérequis : validation driver de la Phase 4 réussie, présence physique confirmée.

### Arrêt propre et reboot

```bash
for VMID in $ALL_GUESTS; do N "pct shutdown $VMID --timeout 90"; done
N "pct list"   # tous arrêtés
```

Point d'arrêt humain. Avant de lancer le reboot, confirmez les trois conditions : vous êtes physiquement devant la machine avec écran et clavier, le menu de boot affichera 30 secondes, un kernel 6.x de secours est listé et vous savez le sélectionner (typiquement via « Advanced options for Proxmox VE » puis le kernel 6.x dont le driver a été buildé en Phase 4).

```bash
N "systemctl reboot" || true
# Attente du retour SSH (10 min max)
for i in $(seq 1 60); do
  sleep 10
  if ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE_IP}" true 2>/dev/null; then
    echo "Nœud revenu après $((i*10))s"; break
  fi
  [ $i -eq 60 ] && echo "ALERTE : pas de réponse après 10 min, basculer sur la console physique"
done
```

Si la machine ne répond pas, n'insistez pas en boucle SSH. Passez à la console physique et sélectionnez le kernel 6.x de secours.

### Validation par niveaux

```bash
# Hôte
N "pveversion && uname -r"                          # attendu : 9.2.x et 7.0.x
N "lsmod | grep -E 'nova|nouveau' || echo 'nova/nouveau absents (blacklist OK)'"
N "ip -br addr" | tee "$WORK/reports/iface_APRES.txt"
diff "$WORK/reports/iface_AVANT.txt" "$WORK/reports/iface_APRES.txt" && echo "interfaces inchangées"
# GPU au niveau hôte (le module nvidia doit s'être chargé automatiquement au boot)
N "nvidia-smi --query-gpu=index,name,pci.bus_id,driver_version --format=csv" | tee "$WORK/reports/gpu_APRES.txt"
diff <(cut -d, -f3 "$WORK/configs/gpu_AVANT.txt") <(cut -d, -f3 "$WORK/reports/gpu_APRES.txt") \
  && echo "bus PCI inchangés (ordre d'énumération préservé)"
N "ls -l /dev/nvidia*"                               # comparer à dev_nodes_AVANT.txt
# Conteneurs un par un (puis réaligner leur espace utilisateur, cf Phase 4)
for VMID in $GPU_LXC; do
  N "pct start $VMID && sleep 8"
  N "pct exec $VMID -- nvidia-smi --query-gpu=index,name,driver_version --format=csv | head"
done
```

> Dérive du major `nvidia-uvm` : après reboot, le numéro de major de `/dev/nvidia-uvm` (et `nvidia-uvm-tools`) peut changer — sur le nœud de référence, **235 → 234**, alloué dynamiquement par le kernel. C'est **sans impact** car le passthrough est par chemin (`/dev/nvidia-uvm`) et la règle cgroup est soit permissive (`allow: a`), soit re-résolue au démarrage par la forme `dev[n]:`. Une règle cgroup codée en dur sur `c 235:* rwm` casserait en revanche à ce moment précis.

Pour valider l'inférence, l'oracle est `llama-server` (option `--list-devices` et `timings` de l'API), pas un test `torch.cuda`. Vérifiez que chaque serveur répond (`/health`), que la VRAM est bien allouée côté hôte (`nvidia-smi`), et que les contraintes spécifiques (cache KV, tensor-split) sont préservées. Si `nvidia-smi` dans un conteneur renvoie `Driver/library version mismatch`, réalignez son espace utilisateur (Phase 4) puis redémarrez son `llama-server`.

Sortie attendue : version 9.2.x sur kernel 7.0.x, interfaces inchangées, bus PCI identiques, chaque conteneur voit ses GPU avec la version cible du driver.

Rollback : voir section 13.

## 11. Phase 6 : diagnostiquer une baisse de performance

Cette section est un retour d'expérience autant qu'une méthode. Après migration, un serveur d'inférence sur RTX 3090 affichait environ 24 tokens par seconde contre 37 auparavant. Le réflexe à éviter est d'incriminer la nouvelle pile sans preuve. La bonne démarche élimine les hypothèses une par une.

### Benchmark reproductible

```bash
PORT=8080   # port du llama-server dans le conteneur
bench() {   # 3 runs, prompt fixe, débit de décodage
  N "pct exec $1 -- bash -c 'for i in 1 2 3; do curl -s http://127.0.0.1:$PORT/completion \
    -d \"{\\\"prompt\\\":\\\"Explique le fonctionnement dun moteur thermique.\\\",\\\"n_predict\\\":256,\\\"temperature\\\":0,\\\"cache_prompt\\\":false}\" \
    | python3 -c \"import sys,json;print(json.load(sys.stdin)[\\\"timings\\\"][\\\"predicted_per_second\\\"])\"; done'"
}
bench 203
```

### Échantillonner les raisons de throttling sous charge

```bash
GPU_INDEX=3
N "nvidia-smi -i $GPU_INDEX --query-gpu=power.draw,clocks.sm,temperature.gpu,clocks_event_reasons.active \
  --format=csv -l 1 -f /tmp/throttle.csv & echo \$! > /tmp/s.pid"
# Lancer une génération longue pendant l'échantillonnage, puis :
N "kill \$(cat /tmp/s.pid)"
scp "root@${NODE_IP}:/tmp/throttle.csv" "$WORK/reports/"
```

Astuce : l'option `nvidia-smi -l -f` lancée en arrière-plan via SSH s'avère parfois capricieuse (fichier vide). Une boucle `bash` qui appende des relevés instantanés est plus robuste :

```bash
N "nohup bash -c 'for i in \$(seq 1 45); do nvidia-smi -i $GPU_INDEX \
   --query-gpu=power.draw,clocks.sm,temperature.gpu,clocks_event_reasons.active \
   --format=csv,noheader >> /tmp/throttle.csv; sleep 1; done' >/dev/null 2>&1 &"
```

Si `clocks_event_reasons.active` vaut `0x4`, c'est SW Power Cap : le GPU est limité par son budget de puissance. La fréquence du cœur s'effondre (570 à 645 MHz dans notre cas), la mémoire reste à son plafond, la température est basse (donc pas de throttling thermique).

### Arbre d'élimination

| Piste | Comment l'écarter | Notre verdict |
|---|---|---|
| PCIe | `lspci -vv -s <bus> \| grep LnkSta` **sous charge**, pas à l'idle (Gen1 idle = ASPM normal) | Gen4 x16 sous charge, écarté |
| Thermique | température et reasons HW Thermal (0x40/0x80) | 63 degrés, écarté |
| Persistence | `nvidia-smi -q \| grep Persistence` | activé, écarté |
| Espace utilisateur CUDA | version `libcuda` dans le conteneur | aligné, écarté |
| Build llama.cpp | passe par l'API driver (pas de rebuild requis sur bump mineur) | pas en cause |
| Power cap | reason 0x4 et test A/B ci-dessous | cause confirmée |

### Preuve par test A/B réversible

```bash
GPU_INDEX=3
N "nvidia-smi -i $GPU_INDEX -q -d POWER | grep -E 'Power Limit|Default Power Limit|Max Power Limit'"
# Relever temporairement, mesurer, revenir
N "nvidia-smi -i $GPU_INDEX -pl 300"
bench 203
N "systemctl restart nvidia-power-limits.service"   # restaure la valeur permanente
```

Résultat : 24 tokens par seconde à 220 W, 44 à 300 W. Le facteur limitant était le budget de puissance, pas la pile. Sur ce nœud, le cap 220 W était délibéré (posé par un service de power limits) et déjà présent sous le driver 570 (capture `nvidia_smi_AVANT.txt` de la Phase 0), donc ce n'était pas une régression de la migration.

Nuance d'honnêteté : ce test prouve que le power cap domine, mais ne départage pas formellement une éventuelle différence d'efficience à puissance constante entre les deux drivers, faute d'une mesure de référence capturée dans les mêmes conditions. Le départager exigerait de rebooter sur l'ancien couple kernel et driver, ce qui n'est pas rentable sur un nœud de production.

## 12. Phase 7 : optimiser les power limits

Objectif : trouver le power limit le plus efficient par type de GPU, par balayage perf par watt, sans reboot.

Prérequis : diagnostic de la Phase 6 fait, charge concurrente testable.

La bonne méthode n'est pas une valeur fixe choisie d'avance mais un balayage qui mesure débit et puissance à chaque palier, calcule le gain marginal et retient le point juste avant que chaque watt supplémentaire ne rapporte presque plus rien.

### Script de balayage

```bash
#!/usr/bin/env bash
# Balayage perf/watt d'un GPU. Réversible (restaure le service à la fin).
# Usage : sweep.sh <gpu_index> <vmid> <port> "<liste_PL>"
set -u
GPU=$1 ; VMID=$2 ; PORT=$3 ; shift 3 ; PLS="$@"
NODE_IP="${NODE_IP:?définir NODE_IP}"
N() { ssh -o BatchMode=yes "root@${NODE_IP}" "$@"; }
bench() {
  N "pct exec $VMID -- bash -c 'for i in 1 2 3; do curl -s http://127.0.0.1:$PORT/completion \
    -d \"{\\\"prompt\\\":\\\"Redige une analyse detaillee.\\\",\\\"n_predict\\\":256,\\\"temperature\\\":0,\\\"cache_prompt\\\":false}\" \
    | python3 -c \"import sys,json;print(json.load(sys.stdin)[\\\"timings\\\"][\\\"predicted_per_second\\\"])\"; done'"
}
echo "PL,tok_s_median,W_load,SMclk"
for PL in $PLS; do
  N "nvidia-smi -i $GPU -pl $PL" >/dev/null
  N "nohup bash -c 'for i in \$(seq 1 30); do nvidia-smi -i $GPU --query-gpu=power.draw,clocks.sm --format=csv,noheader >> /tmp/sw_${PL}.csv; sleep 1; done' >/dev/null 2>&1 &"
  TOKS=$(bench | sort -n | sed -n 2p)   # médiane sur 3
  WLOAD=$(N "awk -F, '{gsub(/ W/,\"\",\$1); print \$1}' /tmp/sw_${PL}.csv | sort -n | tail -1")
  SMCLK=$(N "awk -F, '{gsub(/ MHz/,\"\",\$2); print \$2}' /tmp/sw_${PL}.csv | sort -n | tail -1")
  echo "$PL,$TOKS,$WLOAD,$SMCLK"
done
N "systemctl restart nvidia-power-limits.service"   # revert garanti
```

Exemple d'usage et résultats obtenus sur le nœud de référence.

RTX 3090 (balayage 220 à 280 W) :

| Power limit | Débit | Puissance sous charge | Fréquence cœur |
|---|---|---|---|
| 220 W | 24,5 tok/s | 214 W | 692 MHz |
| 250 W | 31,5 tok/s | 240 W | 848 MHz |
| 265 W | 35,3 tok/s | | |
| 280 W | 38,8 tok/s | 245 W | 1188 MHz |

Gain marginal plat sur toute la plage (0,23 à 0,25 token par seconde par watt), rendement par watt croissant, pas de point de décroissance. À 280 W en flux unique, le GPU ne sature plus son plafond. Cible retenue : 280 W, soit 58 pour cent de gain.

RTX 4090 (balayage 280 à 320 W, tensor-split sur deux cartes) :

| Power limit par GPU | Débit |
|---|---|
| 280 W | 29,9 tok/s |
| 300 W | 29,9 tok/s |
| 310 W | 29,9 tok/s |
| 320 W | 29,9 tok/s |

Parfaitement plat. Ces GPU ne sont pas limités par la puissance dans cette charge, le goulot est le tensor-split et la bande passante. Relever leur plafond ne sert à rien. Cible inchangée à 280 W. Enseignement : vérifiez toujours que le GPU est réellement limité par la puissance avant d'augmenter son plafond. À l'inverse, un GPU plat peut souvent être **abaissé** sans perte, pour économiser énergie et thermique.

### Test de charge concurrente

Le seul moment réellement à risque, surtout sur plusieurs alimentations. Lancez les serveurs simultanément et surveillez le pic par rail.

```bash
# Appliquer les cibles à chaud (pas encore permanent)
for i in 1 3; do N "nvidia-smi -i $i -pl 280"; done   # exemple : 3090 à 280
# Surveillance des GPU (boucle bash robuste)
N "nohup bash -c 'for i in \$(seq 1 60); do nvidia-smi --query-gpu=index,power.draw,temperature.gpu,clocks_event_reasons.active --format=csv,noheader >> /tmp/concurrent.csv; sleep 1; done' >/dev/null 2>&1 &"
# Générations simultanées sur les conteneurs (adapter ports)
N "pct exec 201 -- curl -s http://127.0.0.1:8080/completion -d '{\"prompt\":\"Essai.\",\"n_predict\":512}' >/dev/null & \
   pct exec 202 -- curl -s http://127.0.0.1:8080/completion -d '{\"prompt\":\"Essai.\",\"n_predict\":512}' >/dev/null & \
   pct exec 203 -- curl -s http://127.0.0.1:8080/completion -d '{\"prompt\":\"Essai.\",\"n_predict\":512}' >/dev/null & wait"
scp "root@${NODE_IP}:/tmp/concurrent.csv" "$WORK/reports/"
```

Sur le nœud de référence, charge concurrente des trois serveurs avec les RTX 3090 à 280 W : pic total de 952 W sur quatre GPU, températures de 51 à 66 degrés, aucun throttling thermique, aucun reset. Sur une configuration à deux alimentations (1200 W et 1000 W, chacune portant une RTX 3090 et une RTX 4090, la plus grosse portant aussi carte mère et CPU), le pire cas par rail était d'environ 502 W de GPU, avec des marges confortables sur chaque rail. Le risque se raisonne par rail, jamais sur le total ; connaître la répartition physique GPU↔alimentation est donc un prérequis de ce test.

### Persistance

Appliquez les valeurs retenues via votre service de power limits au démarrage, après sauvegarde de son script. Important : éditez le script **avant** de relancer le service, sinon le `restart` réappliquerait les anciennes valeurs.

```bash
N "cp -a /usr/local/bin/set-nvidia-power-limits.sh /usr/local/bin/set-nvidia-power-limits.sh.bak-$(date +%s)"
# Éditer les valeurs dans le script (ex. 3090 -> 280), vérifier le diff, puis appliquer
N "systemctl restart nvidia-power-limits.service"
N "nvidia-smi --query-gpu=index,name,power.limit --format=csv"   # vérifier les cibles à chaud
```

N'oubliez pas de **redémarrer les consommateurs GPU hôte** arrêtés en Phase 4 (par exemple `dcgm-exporter`) et de vérifier que le mode persistance est actif (`nvidia-smi -q | grep Persistence`). Le service de power limits étant déclenché au boot (timer ou unit), les cibles seront réappliquées automatiquement ; confirmez-le au prochain reboot naturel, sans en provoquer un pour cela.

Gain net sur le nœud de référence : le serveur de l'éditeur passe de 24,5 à 38,8 tokens par seconde, et la baisse apparue après migration est résorbée.

## 13. Procédure de rollback complète

Le rollback est l'artefact que vous espérez ne jamais utiliser. Décidez à l'avance ce qui le déclenche.

Critères de déclenchement (définis avant l'opération) :

- Build DKMS du driver pour le kernel 7.0 en échec en Phase 4 : on ne reboote pas, rollback driver seul.
- Nœud injoignable après reboot et console montrant une panique ou un réseau mort : rollback kernel.
- Conteneurs GPU sans device après reboot malgré driver chargé : revérifier le set de device nodes, sinon rollback kernel.

Rollback du driver seul (avant reboot, sur kernel 6.8) :

```bash
# Réinstaller le driver précédent conservé en Phase 0, puis valider
N "nvidia-smi --query-gpu=driver_version --format=csv"   # doit afficher l'ancienne version
```

Rollback du kernel (après un reboot raté, depuis la console physique) : au menu de boot, sélectionnez un kernel 6.x (celui dont le driver a été buildé en Phase 4 de préférence). La machine redémarre en configuration antérieure. Le driver précédent, recompilé pour le 6.8, redonne l'inférence.

Rollback des conteneurs : restaurez depuis les `vzdump` de la Phase 0.

```bash
N "pct restore <VMID> /var/lib/vz/dump/vzdump-lxc-<VMID>-<timestamp>.tar.zst --storage local-lvm"
```

Condition qui préserve tout cela : ne jamais avoir exécuté `zpool upgrade`, qui rendrait le retour à un kernel ou un ZFS antérieur impossible.

## 14. Checklist condensée

```
PRÉPARATION
[ ] Sauvegarder confs hors nœud + vzdump conteneurs (hors poids modèles)
[ ] Capturer état GPU (versions, bus PCI, device nodes, flavour, Pwr/Cap)
[ ] Appliquer point releases 8.4 sans reboot
[ ] Vérifier Secure Boot (mokutil --sb-state) : enrôler MOK ou désactiver si actif
[ ] pve8to9 --full, traiter tous les FAIL
[ ] Retirer meta-package systemd-boot si proxmox-boot-tool
[ ] Épingler interfaces par MAC, menu boot 30s
MIGRATION (sans reboot)
[ ] Désactiver pve-enterprise.sources, corriger dépôts SHA1
[ ] Réécrire sources trixie AVEC non-free-firmware, apt update propre
[ ] Simuler dist-upgrade, vérifier aucun kernel 6.x retiré
[ ] dist-upgrade détaché, vérifier kernel 7.0 installé + 6.x conservés
[ ] Installer microcode (après trixie), update-initramfs
DRIVER (sur 6.8, avant reboot)
[ ] En-têtes des deux kernels (actif + cible)
[ ] Blacklister nouveau, nova, nova_core + update-initramfs -u -k all
[ ] Arrêter conteneurs GPU + consommateurs hôte (dcgm-exporter, persistenced)
[ ] Purger ancien driver, décharger modules (rmmod), installer cible DKMS
[ ] dkms install -k <kernel_cible> (forcer le build 7.0 explicitement)
[ ] VALIDER nvidia-smi sur 6.8 ET build DKMS pour 7.0 avant reboot
REBOOT (présence physique)
[ ] Arrêter tous les invités
[ ] Confirmer console + kernel de secours, puis reboot
[ ] Valider hôte, GPU, bus PCI inchangés, nova/nouveau absents
[ ] Démarrer conteneurs, réaligner espace utilisateur NVIDIA, valider inférence
APRÈS
[ ] Benchmarker, diagnostiquer par élimination avant d'incriminer la pile
[ ] Balayage perf/watt, appliquer les power limits efficients (éditer le script AVANT restart)
[ ] Redémarrer les consommateurs GPU hôte (dcgm-exporter)
[ ] Ramener le menu boot à 5s après plusieurs reboots concluants
[ ] Ne jamais lancer zpool upgrade tant que le rollback doit rester possible
```

## 15. Pièges à retenir

Le driver NVIDIA 570 ou 580 ne compile pas sur le kernel 7.0 (retrait de `VMA_LOCK_OFFSET`). Prévoyez la branche 595 et validez le build avant de rebooter, surtout sans accès hors bande.

`--dkms` ne compile le module que pour le kernel actif. Forcez explicitement le build du kernel cible (`dkms install nvidia/<version> -k <kernel_cible>`), sinon il n'existe pas et la pré-validation sur l'ancien kernel n'a rien à valider.

Avant de purger le driver, libérez les modules : tout consommateur GPU côté hôte (exporter de métriques type `dcgm-exporter`, `nvidia-persistenced`) maintient `nvidia` chargé et empêche le nouveau module de prendre le relais sur l'ancien kernel.

Le pilote `nova` et `nova_core` du kernel 7.0 doit être blacklisté en plus de `nouveau`, sinon le module NVIDIA (open ou proprietary) ne s'attache pas aux GPU.

Avec Secure Boot actif, les modules DKMS signés par la clé MOK ne se chargent qu'après enrôlement de cette clé, lequel se fait en console physique. À trancher avant le reboot sur un nœud sans IPMI.

Sans IPMI, la pré-validation du driver sur l'ancien kernel transforme un pari aveugle en opération contrôlée. C'est la décision la plus importante de la migration.

`amd64-microcode` vit dans `non-free-firmware` : ce composant doit être présent dans les sources trixie, sinon le paquet est introuvable. D'où l'install du microcode après la bascule des dépôts.

L'espace utilisateur NVIDIA dans les conteneurs doit suivre la version du driver hôte. Un décalage casse CUDA dans le conteneur (`Driver/library version mismatch`) sans rien casser au niveau hôte.

Le passthrough LXC exige le set complet de device nodes à cause de l'énumération contiguë de `libcuda`, même pour un conteneur mono GPU. Préférez la forme `dev[n]:` aux majors codés en dur : le major de `nvidia-uvm` peut changer au reboot.

Une baisse de performance après migration n'est pas forcément une régression. Mesurez, échantillonnez les raisons de throttling, prouvez par un test réversible. Ici un power cap préexistant expliquait tout.

Avant de relever un power limit, vérifiez que le GPU est réellement limité par la puissance. Les RTX 4090 de ce nœud ne l'étaient pas.

Sur plusieurs alimentations, le risque se raisonne par rail, pas sur le total. Connaître la répartition physique des GPU est indispensable avant un test à pleine charge.

## 16. Sources

Sources consultées en juin 2026. Les couples kernel et driver évoluant vite, vérifiez les versions et l'état des fils au moment de votre migration. Un comportement validé sur un patchlevel donné peut différer sur un autre.

### Proxmox

- Wiki officiel, [Upgrade from 8 to 9](https://pve.proxmox.com/wiki/Upgrade_from_8_to_9), dont la section [sd-boot-warning](https://pve.proxmox.com/wiki/Upgrade_from_8_to_9#sd-boot-warning) sur le retrait du meta-package systemd-boot.
- Forum, [Opt-in Linux 7.0 Kernel for Proxmox VE 9](https://forum.proxmox.com/threads/opt-in-linux-7-0-kernel-for-proxmox-ve-9-available-on-test-and-no-subscription.182328/), retours terrain sur le kernel 7.0.
- Forum, [LXC device passthrough Proxmox 8.1](https://forum.proxmox.com/threads/lxc-device-passthrough-proxmox-8-1.137773/), introduction de la syntaxe `dev[n]:`.

### Driver NVIDIA et kernel 7.0

- GitHub NVIDIA, [Issue #1113 : VMA_LOCK_OFFSET undeclared sur kernel 7.0](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1113), la cause racine de l'incompatibilité des drivers antérieurs au 595.
- Forum Proxmox, [NVIDIA 580.x et kernel 7.0, incompatibilité sur Trixie](https://forum.proxmox.com/threads/nvidia-580-x-kernel-7-0-incompatibility-on-trixie.183421/).
- Forum Proxmox, [Fix NVIDIA drivers failing after upgrade to PVE 9.2.2, conflit NovaCore](https://forum.proxmox.com/threads/fix-nvidia-drivers-failing-after-upgrade-to-proxmox-9-2-2-kernel-7-0-2-6-pve-novacore-conflict.183800/) : blacklist nova/nova_core et validation du 595.71.05 sur kernel 7.0.2-6-pve.
- [NVIDIA 595, dernière branche Production](https://9to5linux.com/nvidia-595-linux-graphics-driver-released-as-latest-production-branch-version) et [release notes data center 595.71.05](https://docs.nvidia.com/datacenter/tesla/tesla-release-notes-595-71-05/index.html).
- GitHub NVIDIA, [Issue #1134 : kernel 7.0.3 + nvidia-open 595.71.05 sur RTX 3090](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1134), à surveiller si vos GPU sont des RTX 3090 en modules open. Le déclencheur documenté est une charge GPU desktop (Chromium/Wayland), profil différent d'une inférence headless, mais à connaître.

### Passthrough GPU vers LXC

- [How to Enable GPU Passthrough to LXC Containers in Proxmox](https://www.virtualizationhowto.com/2025/05/how-to-enable-gpu-passthrough-to-lxc-containers-in-proxmox/).
- [Running a vLLM LXC on Proxmox 9 with NVIDIA GPU passthrough](https://medium.com/@jakeasmith/running-a-vllm-lxc-on-proxmox-9-f7fbb8a7db2f).

### Matériel AMD

- Bulletin officiel AMD, [AMD-SB-7055 : RDSEED Failure on Zen 5 Processors](https://www.amd.com/en/resources/product-security/bulletin/amd-sb-7055.html) (CVE-2025-62626). Le bug est limité à Zen 5 et n'affecte pas les Zen 2, 3 et 4.
- Couverture Phoronix, [AMD Acknowledges RDSEED Failure on Zen 5](https://www.phoronix.com/news/AMD-SB-7055-RDSEED-Zen-5).

## À propos

Retour d'expérience et runbook rédigés par Hemerson Koffi, HKCONSEILS. Infrastructure souveraine, inférence LLM locale, exploitation de plateformes IA on premise.

Publié sous licence Creative Commons Attribution ShareAlike 4.0 International (CC BY-SA 4.0). Partage et adaptation autorisés en citant la source et en conservant la même licence.
