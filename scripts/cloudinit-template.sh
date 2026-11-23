#!/usr/bin/env bash
# Tworzy szablon VM z obrazu chmurowego (cloud-init).
# Użycie:
#   bash cloudinit-template.sh [VMID] [STORAGE] [OBRAZ]
#   OBRAZ: ubuntu-2404 (domyślnie) | debian-13
# Przykład:
#   bash cloudinit-template.sh 9000 grzegorz-pool ubuntu-2404
# Zmienne opcjonalne: CI_USER (domyślnie grzegorz), SSH_KEY (domyślnie ~/.ssh/id_ed25519.pub),
#                     BRIDGE (vmbr0), DISK_SIZE (20G)
set -euo pipefail

VMID="${1:-9000}"
STORAGE="${2:-grzegorz-pool}"
IMAGE="${3:-ubuntu-2404}"
CI_USER="${CI_USER:-grzegorz}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_SIZE="${DISK_SIZE:-20G}"
DIR=/var/lib/vz/template/iso

case "$IMAGE" in
  ubuntu-2404) URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" ;;
  debian-13)   URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2" ;;
  *) echo "Nieznany obraz: $IMAGE"; exit 1 ;;
esac

qm status "$VMID" &>/dev/null && { echo "VMID $VMID już istnieje"; exit 1; }
[[ -f "$SSH_KEY" ]] || { echo "Brak klucza SSH: $SSH_KEY (ustaw SSH_KEY=...)"; exit 1; }

FILE="$DIR/$(basename "$URL")"
if [[ ! -f "$FILE" ]]; then
  echo ">> Pobieram $URL"
  wget -q --show-progress -O "$FILE" "$URL"
fi

echo ">> Tworzę VM $VMID"
qm create "$VMID" --name "${IMAGE}-tpl" --memory 2048 --cores 2 --cpu x86-64-v2-AES \
  --net0 "virtio,bridge=${BRIDGE}" --scsihw virtio-scsi-single \
  --agent enabled=1 --ostype l26 --serial0 socket --vga serial0
qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${FILE},discard=on,iothread=1"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit" --boot order=scsi0
qm set "$VMID" --ciuser "$CI_USER" --sshkeys "$SSH_KEY" --ipconfig0 ip=dhcp
qm disk resize "$VMID" scsi0 "$DISK_SIZE"
qm template "$VMID"

cat <<EOF
>> Szablon $VMID gotowy.
   Klon:   qm clone $VMID 141 --name web01 --full 1
   IP:     qm set 141 --ipconfig0 ip=192.168.1.141/24,gw=192.168.1.1
   Start:  qm start 141 && ssh ${CI_USER}@192.168.1.141
EOF
