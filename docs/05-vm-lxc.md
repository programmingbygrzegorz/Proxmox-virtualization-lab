# 05. Maszyny wirtualne i kontenery LXC

| | VM (KVM/QEMU) | Kontener (LXC) |
|---|---|---|
| Narzędzie CLI | `qm` | `pct` |
| System gościa | dowolny (Linux, Windows, BSD – np. pfSense) | tylko Linux, współdzieli jądro hosta |
| Izolacja | pełna | słabsza (unprivileged CT jest bezpieczniejszy) |
| Narzut | większy | bardzo mały |
| Live-migracja | tak | nie (tylko restart-migracja) |
| Konfiguracja | `/etc/pve/qemu-server/<vmid>.conf` | `/etc/pve/lxc/<vmid>.conf` |

## Tworzenie VM z ISO

GUI: *Create VM* → wybierz ISO z `local` → dysk na `grzegorz-pool` (współdzielony) → CPU typu `host` (lub `x86-64-v2-AES` przy mieszanym sprzęcie w klastrze) → karta VirtIO.

CLI:

```bash
# ISO do /var/lib/vz/template/iso/
cd /var/lib/vz/template/iso && wget https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso

qm create 140 --name ubuntu-test --memory 2048 --cores 2 --cpu x86-64-v2-AES \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single --scsi0 grzegorz-pool:32,discard=on,iothread=1 \
  --ide2 local:iso/ubuntu-24.04.3-live-server-amd64.iso,media=cdrom \
  --boot order='scsi0;ide2' --ostype l26 --agent enabled=1
qm start 140
```

Po instalacji systemu w VM: `apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent` – Proxmox zobaczy IP maszyny i będzie mógł ją poprawnie wyłączać i zamrażać system plików przy backupie.

## Szablon z cloud-init (najszybsza droga do nowych VM)

```bash
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

qm create 9000 --name ubuntu-2404-tpl --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single --agent enabled=1 --ostype l26 \
  --serial0 socket --vga serial0
qm set 9000 --scsi0 grzegorz-pool:0,import-from=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img,discard=on
qm set 9000 --ide2 grzegorz-pool:cloudinit --boot order=scsi0
qm set 9000 --ciuser grzegorz --sshkeys ~/.ssh/id_ed25519.pub --ipconfig0 ip=dhcp
qm disk resize 9000 scsi0 20G
qm template 9000

# klon w kilka sekund
qm clone 9000 141 --name web01 --full 1
qm set 141 --ipconfig0 ip=192.168.1.141/24,gw=192.168.1.1
qm start 141
```

Gotowy skrypt: [scripts/cloudinit-template.sh](../scripts/cloudinit-template.sh).

## Konsola szeregowa (tak podłączyłem się do VM 130)

Przydaje się, gdy noVNC nie działa albo pracujesz tylko przez SSH:

```bash
qm set 130 --serial0 socket
# w VM: włącz konsolę na ttyS0
#   /etc/default/grub: GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200"
#   update-grub && systemctl enable --now serial-getty@ttyS0.service
qm terminal 130          # wyjście: Ctrl+O
```

## Kontenery LXC

```bash
pveam update
pveam available --section system | grep debian
pveam download local debian-13-standard_13.1-2_amd64.tar.zst   # nazwę skopiuj z listy powyżej

pct create 200 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname ct-test --cores 1 --memory 512 --swap 512 \
  --rootfs grzegorz-pool:8 --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 --features nesting=1 --password
pct start 200
pct enter 200
```

## Operacje na dyskach

```bash
qm disk move 110 scsi0 grzegorz-pool --delete 1    # przeniesienie dysku na Ceph (można na żywo)
qm disk resize 130 scsi0 +10G                      # powiększenie (potem rozszerz partycję w gościu)
qm disk import 140 obraz.qcow2 grzegorz-pool       # import dysku z pliku
qm rescan                                          # wykrycie osieroconych dysków
pct move-volume 200 rootfs grzegorz-pool --delete 1
```

## Migracja

```bash
qm migrate 130 pve --online          # live – wymaga dysków na storage współdzielonym
qm migrate 110 pve2 --online --with-local-disks   # z kopiowaniem dysków lokalnych (wolniej)
pct migrate 200 pve2 --restart
```

## Migawki (snapshoty)

```bash
qm snapshot 130 przed-aktualizacja --description "przed apt upgrade" --vmstate 1
qm listsnapshot 130
qm rollback 130 przed-aktualizacja
qm delsnapshot 130 przed-aktualizacja
```

> Snapshot to nie backup – leży na tym samym storage co VM.

## Uruchamianie maszyn na innym węźle przez SSH

Z historii poleceń – zamiast logować się na `pve2`:

```bash
ssh root@pve2 qm list
ssh root@pve2 qm start 130
```

Lepiej: `pvesh` widzi cały klaster z dowolnego węzła (patrz [06-cli.md](06-cli.md#pvesh--api-z-linii-komend)).
