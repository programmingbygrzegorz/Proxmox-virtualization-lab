# 08. Proxmox Backup Server

PBS przechowuje backupy VM i kontenerów z **deduplikacją** (kolejne backupy wysyłają tylko zmienione bloki), szyfrowaniem po stronie klienta, weryfikacją i przywracaniem pojedynczych plików.

W labie PBS stoi na moim komputerze lokalnym jako maszyna wirtualna i łączy się z klastrem przez [Tailscale](07-tailscale.md). PBS 4.x (Debian 13) obsługuje backupy z PVE 8 i PVE 9.

## 1. Gdzie i jak zainstalować

| Wariant | Kiedy |
|---|---|
| **VM na komputerze lokalnym** (Hyper-V / VirtualBox / VMware Workstation) – mój wariant | lab, brak dodatkowego sprzętu |
| Osobny komputer / mini-PC z ISO | najlepszy – backup na innym sprzęcie niż klaster |
| VM/LXC na samym klastrze PVE | tylko do nauki – awaria klastra = utrata backupów |

Zasoby VM: 2 vCPU, 4 GB RAM, **dwa dyski**: 32 GB na system + osobny dysk na datastore (tyle, ile możesz – np. 200–500 GB). Karta sieciowa w trybie **bridged** (Hyper-V: *External switch*), żeby PBS dostał adres z LAN.

> Hyper-V: przy tworzeniu VM wybierz *Generation 2* i **wyłącz Secure Boot** albo ustaw szablon *Microsoft UEFI Certificate Authority*, inaczej ISO się nie uruchomi.

## 2. Instalacja z ISO

1. Pobierz ISO *Proxmox Backup Server* z <https://www.proxmox.com/en/downloads>.
2. Instalator wygląda jak w PVE: dysk systemowy (32 GB), strefa czasowa, hasło roota, sieć:
   - Hostname: `pbs.lab.local`
   - IP: np. `192.168.1.20/24`, brama `192.168.1.1`
3. GUI: `https://192.168.1.20:8007`, login `root`, realm *Linux PAM*.

Po instalacji – repozytorium no-subscription i aktualizacja:

```bash
cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
# wyłącz enterprise: dopisz "Enabled: false" w /etc/apt/sources.list.d/pbs-enterprise.sources
apt update && apt full-upgrade -y
```

Potem [Tailscale](07-tailscale.md#3-instalacja-na-pbs-i-pdm): `tailscale up --hostname=pbs`.

## 3. Datastore

### GUI

*Administration → Storage / Disks* → wybierz drugi dysk (`sdb`) → *Directory* (ext4/xfs) lub *ZFS* → zaznacz **Add as Datastore**, nazwa `store1`.

### CLI

```bash
lsblk
proxmox-backup-manager disk list
proxmox-backup-manager disk fs create store1 --disk sdb --filesystem ext4 --add-datastore true
proxmox-backup-manager datastore list
```

## 4. Użytkownik dla PVE (nie używaj roota)

```bash
proxmox-backup-manager user create backup@pbs --password 'SilneHaslo'
proxmox-backup-manager acl update /datastore/store1 DatastoreBackup --auth-id backup@pbs
proxmox-backup-manager cert info | grep -i fingerprint
```

`DatastoreBackup` pozwala tworzyć backupy i odczytywać własne, ale nie usuwać cudzych – to chroni przed sytuacją, w której przejęty PVE kasuje całą historię kopii.

## 5. Dodanie PBS w Proxmox VE

GUI: *Datacenter → Storage → Add → Proxmox Backup Server*

| Pole | Wartość |
|---|---|
| ID | `pbs` |
| Server | `pbs` (MagicDNS) lub `100.x.y.z` |
| Username | `backup@pbs` |
| Datastore | `store1` |
| Fingerprint | z `cert info` |
| Encryption | *Auto-generate a client encryption key* (opcjonalnie) |

CLI (na dowolnym węźle klastra):

```bash
pvesm add pbs pbs --server pbs --datastore store1 \
  --username backup@pbs --password \
  --fingerprint 'AA:BB:...:FF'
pvesm status | grep pbs
```

> Jeśli włączysz szyfrowanie, **zrób kopię klucza** (*Storage → pbs → Encryption → Download/Print*). Bez klucza backupów nie da się odtworzyć.

## 6. Zadanie backupu

*Datacenter → Backup → Add*:

- Storage: `pbs`, Schedule: `daily 02:00` (składnia jak systemd calendar, np. `mon..fri 21:00`)
- Selection: *All* albo wybrane VM (110, 111, 130)
- Mode: **Snapshot** (bez zatrzymywania VM; z qemu-guest-agent system plików jest zamrażany)
- Retention: na PBS (punkt 7), w zadaniu zostaw puste

CLI – jednorazowo:

```bash
vzdump 130 --storage pbs --mode snapshot
vzdump 110 111 130 --storage pbs --mode snapshot --notes-template '{{guestname}} {{node}}'
```

## 7. Utrzymanie na PBS: prune, GC, weryfikacja

| Zadanie | Co robi | Przykład harmonogramu |
|---|---|---|
| **Prune** | usuwa stare snapshoty wg reguł retencji | codziennie |
| **Garbage Collection** | fizycznie zwalnia nieużywane bloki (chunks) | codziennie po prune |
| **Verify** | sprawdza sumy kontrolne backupów | co tydzień |
| **Sync** | kopiuje backupy na drugi PBS (offsite) | opcjonalnie |

GUI: *Datastore → store1 → Prune & GC*, *Verify Jobs*.

Retencja w labie: `keep-last 3, keep-daily 7, keep-weekly 4, keep-monthly 3`.

```bash
proxmox-backup-manager prune-job create codzienny --store store1 --schedule daily \
  --keep-last 3 --keep-daily 7 --keep-weekly 4 --keep-monthly 3
proxmox-backup-manager datastore update store1 --gc-schedule 'daily 04:00'
proxmox-backup-manager verify-job create tygodniowy --store store1 --schedule 'sun 05:00' \
  --ignore-verified true --outdated-after 30
proxmox-backup-manager garbage-collection start store1
proxmox-backup-manager task list
```

## 8. Przywracanie

### Cała VM

GUI: *Storage pbs → Backups* → wybierz → *Restore* (nowy VMID, storage `grzegorz-pool`).

```bash
pvesm list pbs | grep vm/130
qmrestore pbs:backup/vm/130/2026-11-23T01:00:00Z 131 --storage grzegorz-pool --unique 1
```

`--unique 1` generuje nowe adresy MAC – ważne, gdy oryginał nadal działa.

### Pojedyncze pliki

GUI: *Backups → File Restore* – przeglądasz system plików z backupu i pobierasz plik/katalog.

### Live-restore

Zaznacz *Live restore* – VM startuje od razu, a dane dociągają się w tle. Przydaje się przy dużych dyskach.

## 9. Test odtworzenia (obowiązkowy)

Backup, którego nigdy nie odtworzono, nie jest backupem. Raz w miesiącu:

1. Odtwórz VM 130 jako 9130 na `grzegorz-pool` z `--unique 1`, z kartą odłączoną od sieci (`qm set 9130 --net0 virtio,bridge=vmbr0,link_down=1`).
2. Uruchom, sprawdź, czy system wstaje i dane są aktualne.
3. Usuń: `qm destroy 9130 --purge 1`.
4. Zapisz wynik w [ćwiczeniach](cwiczenia.md).

## 10. Klient CLI (backup zwykłego hosta Linux)

```bash
apt install proxmox-backup-client
export PBS_REPOSITORY='backup@pbs@pbs:store1'
proxmox-backup-client backup etc.pxar:/etc root.pxar:/ --exclude /proc --exclude /sys
proxmox-backup-client snapshot list
```

Tak można np. robić kopie `/etc` z samych węzłów PVE (konfiguracja sieci, `/etc/pve` jako kopia `config.db`).
