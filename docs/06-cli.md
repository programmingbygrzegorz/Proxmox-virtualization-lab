# 06. Zarządzanie Proxmox VE z linii komend

Wszystko, co robisz w GUI, da się zrobić z CLI – GUI to tylko klient REST API. Narzędzia działają z dowolnego węzła klastra, jako `root` (lub przez `pvesh`/API z tokenem).

## Mapa narzędzi

| Narzędzie | Obszar |
|---|---|
| `qm` | maszyny wirtualne KVM |
| `pct` | kontenery LXC |
| `pvesm` | storage |
| `pvecm` | klaster |
| `pveceph` / `ceph` | Ceph |
| `pvesh` | dowolne wywołanie API (cały klaster) |
| `vzdump` / `qmrestore` / `pct restore` | backup i przywracanie |
| `pveam` | szablony kontenerów |
| `pveum` | użytkownicy, grupy, role, tokeny |
| `ha-manager` | wysoka dostępność |
| `pve-firewall` | firewall |
| `pvenode` | ustawienia węzła, certyfikaty ACME, zadania |
| `pvesubscription`, `pveversion`, `pvereport` | informacje o systemie |

## Informacje o systemie

```bash
pveversion -v               # wersje wszystkich pakietów Proxmox
pvereport > /root/raport.txt  # pełny raport diagnostyczny (dla forum/supportu)
pvesh get /cluster/resources --type node --output-format table
uptime; free -h; df -h; lsblk
journalctl -b -p warning --no-pager | tail -50
```

## Maszyny wirtualne – `qm`

```bash
qm list                                  # VM na tym węźle
qm status 130 --verbose
qm config 130                            # konfiguracja
qm start|shutdown|reboot|stop 130        # stop = "wyciągnięcie wtyczki"
qm suspend 130; qm resume 130
qm set 130 --memory 4096 --cores 2       # zmiana parametrów
qm set 130 --onboot 1 --startup order=2,up=30
qm guest cmd 130 network-get-interfaces  # przez qemu-guest-agent
qm guest exec 130 -- uptime
qm terminal 130                          # konsola szeregowa
qm monitor 130                           # monitor QEMU (info status, info block)
qm unlock 130                            # gdy VM zostaje "locked" po przerwanym zadaniu
qm destroy 130 --purge 1                 # usunięcie razem z wpisami w backup/HA
```

## Kontenery – `pct`

```bash
pct list
pct start|shutdown|stop|reboot 200
pct enter 200                            # powłoka wewnątrz kontenera
pct exec 200 -- apt update
pct config 200
pct set 200 --memory 1024 --cores 2
pct push 200 plik.txt /root/plik.txt
pct pull 200 /var/log/syslog ./syslog-ct200
pct resize 200 rootfs +4G
pct fsck 200
```

## Storage – `pvesm`

```bash
pvesm status                             # wszystkie storage i zajętość
pvesm list grzegorz-pool                 # zawartość (dyski VM)
pvesm list local --content iso
pvesm alloc local-lvm 130 vm-130-disk-1 10G
pvesm free grzegorz-pool:vm-130-disk-1
cat /etc/pve/storage.cfg

# dodanie storage NFS
pvesm add nfs nas-iso --server 192.168.1.50 --export /export/iso --content iso,vztmpl
pvesm set nas-iso --disable 1
pvesm remove nas-iso
```

LVM pod spodem:

```bash
pvs; vgs; lvs
lvs -o lv_name,data_percent,metadata_percent pve   # zajętość thin poola
```

## Klaster – `pvecm` i corosync

```bash
pvecm status; pvecm nodes
corosync-cfgtool -s
corosync-quorumtool -s
systemctl status corosync pve-cluster
```

Szczegóły: [03-klaster.md](03-klaster.md).

## `pvesh` – API z linii komend

`pvesh` odwzorowuje ścieżki REST API (`/api2/json/...`). Dokumentacja wszystkich ścieżek: <https://pve.proxmox.com/pve-docs/api-viewer/>.

```bash
pvesh ls /                                           # przeglądanie drzewa API
pvesh get /version
pvesh get /cluster/status
pvesh get /cluster/resources --type vm --output-format table
pvesh get /nodes/pve2/qemu --output-format json-pretty
pvesh create /nodes/pve2/qemu/130/status/start       # start VM na innym węźle bez SSH
pvesh get /nodes/pve/tasks --limit 10
pvesh get /nodes/pve/storage/grzegorz-pool/status
pvesh usage /nodes/{node}/qemu -v                    # opis parametrów
```

Przykład – lista wszystkich wyłączonych VM w klastrze:

```bash
pvesh get /cluster/resources --type vm --output-format json \
  | jq -r '.[] | select(.status=="stopped") | "\(.vmid)\t\(.name)\t\(.node)"'
```

## REST API z innego komputera (token)

```bash
# na PVE: użytkownik i token tylko do odczytu
pveum user add automation@pve
pveum aclmod / -user automation@pve -role PVEAuditor
pveum user token add automation@pve monitoring --privsep 0
#   -> zapisz pokazany sekret, nie da się go odczytać drugi raz
```

```bash
# z laptopa
export PVE_TOKEN='automation@pve!monitoring=<sekret>'
curl -sk -H "Authorization: PVEAPIToken=$PVE_TOKEN" \
  https://192.168.1.10:8006/api2/json/cluster/resources?type=vm | jq '.data[] | {vmid,name,status,node}'
```

W produkcji zamiast `-k` używaj zaufanego certyfikatu (ACME/Let's Encrypt: `pvenode acme`).

## Backup i przywracanie

```bash
vzdump 130 --storage pbs --mode snapshot --compress zstd --notes-template '{{guestname}}'
vzdump --all --storage pbs --mode snapshot --mailnotification failure
qmrestore pbs:backup/vm/130/2026-11-23T18:00:00Z 131 --storage grzegorz-pool
pct restore 201 local:backup/vzdump-lxc-200-*.tar.zst --storage grzegorz-pool
pvesh get /cluster/backup                 # zaplanowane zadania backupu
```

## Użytkownicy i uprawnienia – `pveum`

```bash
pveum user list
pveum user add jan@pve --password
pveum group add admins
pveum user modify jan@pve --groups admins
pveum aclmod /vms/130 -group admins -role PVEVMAdmin
pveum role list
pveum acl list
```

## HA

```bash
ha-manager status
ha-manager add vm:130 --state started --max_restart 2 --max_relocate 1
ha-manager crm-command migrate vm:130 pve
ha-manager remove vm:130
```

## Firewall

```bash
pve-firewall status
pve-firewall compile        # sprawdzenie reguł bez stosowania
cat /etc/pve/firewall/cluster.fw
cat /etc/pve/nodes/pve/host.fw
cat /etc/pve/firewall/130.fw
```

## Usługi Proxmoxa

| Usługa | Rola |
|---|---|
| `pveproxy` | GUI/API na porcie 8006 |
| `pvedaemon` | wykonuje zadania API jako root |
| `pvestatd` | zbiera statystyki VM/storage |
| `pve-cluster` | pmxcfs (`/etc/pve`) |
| `corosync` | komunikacja klastra |
| `pve-ha-lrm`, `pve-ha-crm` | HA |
| `pvescheduler` | zadania cykliczne (backup, replikacja) |

```bash
systemctl restart pveproxy pvedaemon      # gdy GUI nie odpowiada
journalctl -u pveproxy -e
```

## Diagnostyka – lista kontrolna

```bash
ping -c3 pve2 && pvecm status | grep -E 'Quorate|Total votes'
ceph -s | head -15
pvesm status
qm list; ssh pve2 qm list
journalctl -b -1 -e                # logi z poprzedniego uruchomienia (np. po niespodziewanym restarcie)
last -x | grep -E 'shutdown|reboot' | head
```

Gotowy raport w jednym poleceniu: [scripts/cluster-health.sh](../scripts/cluster-health.sh).
