#!/usr/bin/env bash
# Proxmox VE – konfiguracja po instalacji:
#   - wyłącza repozytoria enterprise (PVE i Ceph)
#   - włącza no-subscription
#   - aktualizuje system i instaluje podstawowe narzędzia
# Obsługuje PVE 8 (bookworm, pliki .list) i PVE 9 (trixie, pliki .sources).
# Użycie: bash post-install.sh [--no-upgrade]
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Uruchom jako root"; exit 1; }
command -v pveversion >/dev/null || { echo "To nie jest Proxmox VE"; exit 1; }

. /etc/os-release
CODENAME="${VERSION_CODENAME}"
SRC=/etc/apt/sources.list.d
echo ">> Proxmox VE na Debianie ${CODENAME}: $(pveversion)"

disable_sources() {   # format deb822
  local f="$1"
  [[ -f "$f" ]] || return 0
  if grep -q '^Enabled:' "$f"; then sed -i 's/^Enabled:.*/Enabled: false/' "$f"
  else echo 'Enabled: false' >> "$f"; fi
  echo "   wyłączono: $f"
}

if [[ "$CODENAME" == "bookworm" ]]; then
  # PVE 8
  [[ -f $SRC/pve-enterprise.list ]] && sed -i 's/^deb/# deb/' $SRC/pve-enterprise.list
  echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > $SRC/pve-no-subscription.list
  if [[ -f $SRC/ceph.list ]] && grep -q enterprise $SRC/ceph.list; then
    CEPH=$(grep -oE 'ceph-[a-z]+' $SRC/ceph.list | head -1)
    echo "deb http://download.proxmox.com/debian/${CEPH} bookworm no-subscription" > $SRC/ceph.list
  fi
else
  # PVE 9+
  disable_sources $SRC/pve-enterprise.sources
  cat > $SRC/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  if [[ -f $SRC/ceph.sources ]] && grep -q enterprise $SRC/ceph.sources; then
    CEPH=$(grep -oE 'ceph-[a-z]+' $SRC/ceph.sources | head -1)
    cat > $SRC/ceph.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/${CEPH}
Suites: ${CODENAME}
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  fi
fi

echo ">> apt update"
apt-get update

if [[ "${1:-}" != "--no-upgrade" ]]; then
  echo ">> full-upgrade"
  DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
fi

apt-get install -y vim htop iotop iftop tmux curl wget jq lsof ethtool smartmontools

echo ">> Gotowe. Jeśli zainstalowano nowe jądro – zrób reboot."
[[ -f /var/run/reboot-required ]] && echo "   (wymagany restart)"
