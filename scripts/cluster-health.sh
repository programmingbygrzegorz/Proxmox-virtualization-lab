#!/usr/bin/env bash
# Szybki raport stanu klastra Proxmox VE (tylko odczyt).
# Użycie: bash cluster-health.sh
# Wymaga: jq (apt install jq)
set -uo pipefail
command -v jq >/dev/null || { echo "Zainstaluj jq: apt install jq"; exit 1; }

h() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

h "Wersja"
pveversion

h "Klaster / quorum"
if pvecm status &>/dev/null; then
  pvecm status | grep -E 'Name:|Nodes:|Quorate:|Expected votes|Total votes'
  pvecm nodes | tail -n +4
else
  echo "Węzeł nie jest w klastrze"
fi

h "Ceph"
if command -v ceph &>/dev/null && [[ -f /etc/pve/ceph.conf ]]; then
  timeout 10 ceph -s 2>&1 | grep -E 'health|mon:|osd:|usage|pgs:' || echo "ceph -s nie odpowiada"
else
  echo "Ceph nie jest skonfigurowany"
fi

h "Storage"
pvesm status 2>/dev/null

h "Maszyny i kontenery w klastrze"
pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
  | jq -r '["VMID","TYP","NAZWA","WĘZEŁ","STAN"], (.[] | [.vmid, .type, .name, .node, .status]) | @tsv' \
  | column -t

h "HA"
ha-manager status 2>/dev/null || echo "brak"

h "Ostatnie nieudane zadania (24 h)"
since=$(( $(date +%s) - 86400 ))
pvesh get /cluster/tasks --output-format json 2>/dev/null \
  | jq -r --argjson s "$since" '.[] | select(.starttime > $s and .status != "OK" and .status != null)
         | "\(.starttime|todate)  \(.node)  \(.type)  \(.id // "")  \(.status)"' | head -20

h "Ostrzeżenia z journala (bieżące uruchomienie)"
journalctl -b -p err --no-pager -q | tail -10
