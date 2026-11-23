# 01. Instalacja Proxmox VE

Rozdział prowadzi od pustego komputera do działającego węzła. Mój lab działa na PVE 8.3 (Debian 12), ale nowa instalacja powinna być już na **Proxmox VE 9.x** (Debian 13 „trixie”). Różnice między wersjami zaznaczam w tekście.

## 1. Wymagania

| Element | Minimum do labu | Zalecane |
|---|---|---|
| CPU | 64-bit z VT-x/AMD-V | 4+ rdzenie |
| RAM | 4 GB | 8–16 GB (Ceph zjada ~1 GB na OSD + po 1 GB na monitor/manager) |
| Dysk systemowy | 32 GB | SSD 120 GB+ |
| Dysk na dane / Ceph | — | osobny dysk (nie partycja dysku systemowego) |
| Sieć | 1 karta | 2 karty (zarządzanie + VM/Ceph) |

W BIOS/UEFI włącz: **Intel VT-x / AMD-V**, opcjonalnie **VT-d / AMD-Vi (IOMMU)** – potrzebne do przekazywania urządzeń PCI do VM.

## 2. Przygotowanie pendrive’a

1. Pobierz ISO: <https://www.proxmox.com/en/downloads> → *Proxmox Virtual Environment* → *ISO Installer*.
2. Sprawdź sumę kontrolną:
   ```bash
   sha256sum proxmox-ve_9.*.iso
   ```
3. Nagraj ISO:
   - Windows: **Rufus** w trybie **DD** (nie ISO) albo **balenaEtcher**,
   - Linux:
     ```bash
     lsblk                       # znajdź pendrive, np. /dev/sdX
     sudo dd if=proxmox-ve_9.*.iso of=/dev/sdX bs=4M status=progress conv=fsync
     ```

## 3. Instalator – krok po kroku

1. Bootuj z pendrive’a → **Install Proxmox VE (Graphical)**.
2. **EULA** → *I agree*.
3. **Target Harddisk** – wybierz dysk systemowy (`sda`). Przycisk *Options*:
   - `ext4` lub `xfs` + LVM – tak jak w moim labie (`pve-root`, `pve-swap`, `pve-data` jako LVM-thin),
   - `zfs (RAID1)` – jeśli masz dwa dyski i chcesz mirror systemu.
   - Przy dysku 120 GB możesz zmniejszyć `swapsize` (np. 4–6 GB) i ustawić `maxroot` 25–30 GB.
   - **Nie wybieraj** tu dysku przeznaczonego na Ceph – zostaw go pusty.
4. **Location and Time Zone** – Poland, Europe/Warsaw, klawiatura Polish.
5. **Administration Password and Email** – silne hasło roota i prawdziwy e-mail (powiadomienia o błędach backupu, SMART).
6. **Management Network Configuration**:
   | Pole | `pve` | `pve2` |
   |---|---|---|
   | Management Interface | `enp1s0` | `enp1s0` |
   | Hostname (FQDN) | `pve.lab.local` | `pve2.lab.local` |
   | IP Address (CIDR) | `192.168.1.10/24` | `192.168.1.11/24` |
   | Gateway | `192.168.1.1` | `192.168.1.1` |
   | DNS | `192.168.1.1` | `192.168.1.1` |

   > Hostname i IP trudno zmienić po dołączeniu węzła do klastra. Ustal je raz, porządnie.
7. **Summary** → *Install*. Po restarcie wyjmij pendrive.
8. Zaloguj się w przeglądarce: `https://192.168.1.10:8006`, użytkownik `root`, realm **Linux PAM**.

## 4. Pierwsze kroki po instalacji (CLI)

Konsola: *Datacenter → węzeł → Shell* albo `ssh root@192.168.1.10`.

### 4.1. Repozytoria bez subskrypcji

Bez subskrypcji repozytorium `enterprise` zwraca błąd 401 przy `apt update`. Wyłączamy je i włączamy `no-subscription`.

**PVE 9 (format deb822, pliki `.sources`):**

```bash
# wyłącz enterprise (PVE i Ceph) – dopisuje/ustawia "Enabled: false"
disable_src() {
  [ -f "$1" ] || return 0
  if grep -q '^Enabled:' "$1"; then sed -i 's/^Enabled:.*/Enabled: false/' "$1"
  else echo 'Enabled: false' >> "$1"; fi
}
disable_src /etc/apt/sources.list.d/pve-enterprise.sources
disable_src /etc/apt/sources.list.d/ceph.sources   # jeśli wskazuje na enterprise

cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
```

**PVE 8 (tak było w moim labie, stary format `.list`):**

```bash
rm -f /etc/apt/sources.list.d/pve-enterprise.list
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list
echo "deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription" \
  > /etc/apt/sources.list.d/ceph.list
```

Najwygodniej zrobić to w GUI: *węzeł → Updates → Repositories* → *Disable* przy enterprise, *Add* → *No-Subscription*.

Gotowy skrypt: [scripts/post-install.sh](../scripts/post-install.sh).

### 4.2. Aktualizacja systemu

```bash
apt update
apt full-upgrade -y      # na Proxmoxie zawsze full-upgrade / dist-upgrade, nigdy samo "apt upgrade"
reboot                   # jeśli przyszło nowe jądro
pveversion -v | head
```

### 4.3. Plik /etc/hosts

Każdy węzeł musi rozwiązywać swoją nazwę na adres w sieci zarządzania (nie `127.0.1.1`), inaczej `pve-cluster` i certyfikaty będą sprawiać problemy:

```
127.0.0.1       localhost
192.168.1.10    pve.lab.local   pve
192.168.1.11    pve2.lab.local  pve2
```

Sprawdzenie:

```bash
hostname          # pve
hostname -f       # pve.lab.local
hostname -I       # 192.168.1.10 ...
getent hosts pve2
```

### 4.4. Przydatne pakiety

```bash
apt install -y vim htop iotop iftop tmux curl wget lsof ethtool smartmontools
```

### 4.5. Odciski kluczy SSH (do porównania przy pierwszym połączeniu)

```bash
for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key"; done
```

### 4.6. Wyłączenie komunikatu o braku subskrypcji (opcjonalnie)

To tylko kosmetyka i nadpisuje się przy aktualizacji `proxmox-widget-toolkit`. W labie można go zignorować – kliknąć *OK*.

## 5. Sprawdzenie, że węzeł działa

```bash
systemctl status pveproxy pvedaemon pve-cluster pvestatd --no-pager
pvesm status          # lista storage
ip -br a              # interfejsy i adresy
cat /etc/network/interfaces
```

W GUI: *Datacenter → Summary* – węzeł zielony, brak błędów w *Tasks*.

## 6. Instalacja na gotowym Debianie (alternatywa)

Gdy instalator ISO nie wykrywa karty sieciowej albo potrzebujesz nietypowego układu dysków, można zainstalować Debiana 13, a potem dodać repozytorium Proxmox i pakiet `proxmox-ve`. Instrukcja: <https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie>.

## 7. Następny krok

Drugi węzeł instalujesz identycznie (inny hostname i IP), a potem przechodzisz do [sieci](02-siec.md) i [klastra](03-klaster.md).
