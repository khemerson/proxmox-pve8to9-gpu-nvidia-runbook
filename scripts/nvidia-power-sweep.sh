#!/usr/bin/env bash
#
# nvidia-power-sweep.sh — Balayage perf/watt d'un GPU NVIDIA servant un llama-server
# en conteneur LXC Proxmox. Mesure débit (tok/s) et puissance à chaque palier de
# power limit, pour identifier le point le plus efficient (genou perf/watt).
#
# RÉVERSIBLE : restaure le service de power limits à la fin (systemd).
# Lecture/bench uniquement — ne modifie aucune config d'inférence.
#
# Référence : runbook "Migrer Proxmox VE 8.4 vers 9.2 sur un nœud GPU NVIDIA sans IPMI",
# Phase 7. Licence CC BY-SA 4.0.
#
# Usage :
#   NODE_IP=192.0.2.10 ./nvidia-power-sweep.sh <gpu_index> <vmid> <port> "<liste_PL>"
# Exemple (RTX 3090, conteneur 203, port 8080, paliers 220 à 280 W) :
#   NODE_IP=192.0.2.10 ./nvidia-power-sweep.sh 3 203 8080 "220 250 265 280"
#
set -euo pipefail

GPU=${1:?index GPU manquant}
VMID=${2:?VMID conteneur manquant}
PORT=${3:?port llama-server manquant}
shift 3
PLS="$*"
: "${NODE_IP:?définir NODE_IP (IP de gestion SSH du nœud)}"
PROMPT=${PROMPT:-"Redige une analyse detaillee du fonctionnement dun moteur thermique."}
NPREDICT=${NPREDICT:-256}
REVERT_CMD=${REVERT_CMD:-"systemctl restart nvidia-power-limits.service"}

N() { ssh -o BatchMode=yes "root@${NODE_IP}" "$@"; }

# Débit médian de décodage sur 3 runs (oracle = timings de l'API llama.cpp, jamais torch.cuda)
bench() {
  N "pct exec $VMID -- bash -c 'for i in 1 2 3; do curl -s http://127.0.0.1:$PORT/completion \
    -d \"{\\\"prompt\\\":\\\"$PROMPT\\\",\\\"n_predict\\\":$NPREDICT,\\\"temperature\\\":0,\\\"cache_prompt\\\":false}\" \
    | python3 -c \"import sys,json;print(json.load(sys.stdin)[\\\"timings\\\"][\\\"predicted_per_second\\\"])\"; done'" \
    | sort -n | sed -n 2p
}

cleanup() { echo "# revert power limits ($REVERT_CMD)"; N "$REVERT_CMD" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "PL_W,tok_s_median,W_load_peak,SMclk_peak_MHz"
for PL in $PLS; do
  N "nvidia-smi -i $GPU -pl $PL" >/dev/null
  # échantillonnage robuste (boucle bash, plus fiable que 'nvidia-smi -l -f' via SSH)
  N "rm -f /tmp/sw_${PL}.csv; nohup bash -c 'for i in \$(seq 1 30); do \
     nvidia-smi -i $GPU --query-gpu=power.draw,clocks.sm --format=csv,noheader >> /tmp/sw_${PL}.csv; sleep 1; done' \
     >/dev/null 2>&1 &"
  sleep 1
  TOKS=$(bench)
  N "pkill -f 'sw_${PL}.csv' 2>/dev/null || true"
  WLOAD=$(N "awk -F, '{gsub(/ W/,\"\",\$1); if(\$1+0>v)v=\$1} END{printf \"%.0f\",v}' /tmp/sw_${PL}.csv")
  SMCLK=$(N "awk -F, '{gsub(/ MHz/,\"\",\$2); if(\$2+0>v)v=\$2} END{printf \"%.0f\",v}' /tmp/sw_${PL}.csv")
  echo "${PL},${TOKS},${WLOAD},${SMCLK}"
done
# revert exécuté par le trap EXIT
