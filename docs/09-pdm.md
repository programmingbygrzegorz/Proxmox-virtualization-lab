# 09. Proxmox Datacenter Manager

PDM to jedno okno do wielu niezależnych klastrów PVE i serwerów PBS: wspólny dashboard, wyszukiwarka zasobów, centralny panel aktualizacji i migracja VM **między klastrami**. Wersja stabilna 1.0 wyszła w grudniu 2025, bazuje na Debianie 13.

W labie PDM działa jako VM na komputerze lokalnym i łączy się z `pve`, `pve2` i PBS przez [Tailscale](07-tailscale.md).

## Wymagania

- Proxmox VE **minimum 8.4** – mój klaster jest na 8.3, więc przed dodaniem do PDM trzeba go zaktualizować (najlepiej od razu do 9.x – [12-aktualizacja-8-do-9.md](12-aktualizacja-8-do-9.md)).
- Proxmox Backup Server minimum 3.4.
- VM: 2 vCPU, 2–4 GB RAM, dysk 20–40 GB.
- PDM łączy się do zdalnych węzłów (8006 dla PVE, 8007 dla PBS); węzły nie muszą łączyć się do PDM.
- Odwrotne proxy między PDM a PVE nie są wspierane – stąd tunel (Tailscale/WireGuard).

## 1. Instalacja

1. ISO: <https://www.proxmox.com/en/downloads> → *Proxmox Datacenter Manager*.
2. VM na komputerze lokalnym (jak przy [PBS](08-pbs.md#1-gdzie-i-jak-zainstalować) – bridged, Secure Boot wyłączony w Hyper-V).
3. Instalator: hostname `pdm.lab.local`, IP np. `192.168.1.21/24`.
4. GUI: `https://192.168.1.21:8443`, login `root`, realm *Linux PAM*.

Repozytorium no-subscription:

```bash
cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pdm
Suites: trixie
Components: pdm-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
# w pliku pdm-enterprise.sources dopisz: Enabled: false
apt update && apt full-upgrade -y
proxmox-datacenter-manager-admin versions
```

Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up --hostname=pdm`.

## 2. Dodanie klastra PVE

*Remotes → Add → Proxmox VE*:

1. **Server**: `pve` (MagicDNS) lub `100.x.y.z`, port 8006 → *Connect* – PDM pokaże fingerprint certyfikatu, porównaj z:
   ```bash
   openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -fingerprint -sha256
   ```
2. PDM wykryje pozostałe węzły klastra (`pve2`) – dodaj je jako dodatkowe punkty połączenia, żeby PDM działał, gdy `pve` jest wyłączony. Upewnij się, że adresy to adresy Tailscale, a nie 192.168.1.x, jeśli PDM nie jest w tym LAN.
3. **Uwierzytelnienie**: podaj `root@pam` i hasło – PDM utworzy na PVE własny token API i nie przechowuje hasła. Alternatywnie przygotuj token sam:
   ```bash
   pveum user add pdm@pve
   pveum aclmod / -user pdm@pve -role Administrator
   pveum user token add pdm@pve pdm --privsep 0
   ```
4. Nazwa zdalnego: `Itechnology`.

## 3. Dodanie PBS

*Remotes → Add → Proxmox Backup Server* → `pbs:8007`, fingerprint z `proxmox-backup-manager cert info`, konto `root@pam` (PDM utworzy token).

## 4. Co ćwiczyć w PDM

| Funkcja | Ćwiczenie |
|---|---|
| Dashboard | sprawdź zużycie CPU/RAM/storage obu węzłów i stan PBS |
| Wyszukiwarka | znajdź VM po nazwie (`wazuh`), po statusie (`status:stopped`) |
| Aktualizacje | zobacz listę dostępnych pakietów dla wszystkich węzłów w jednym miejscu |
| Zarządzanie VM | start/stop VM 130 z PDM, podgląd konsoli |
| Migracja zdalna | gdy masz drugi klaster/samodzielny węzeł (np. trzeci PVE w VM), przenieś VM między klastrami |
| Uprawnienia | utwórz użytkownika PDM z rolą tylko do odczytu |

## 5. Bezpieczeństwo

PDM ma uprawnienia administratora do wszystkich podłączonych systemów – przejęcie PDM oznacza przejęcie całej infrastruktury. Dlatego:

- dostęp do GUI PDM tylko z tailnetu (ACL w Tailscale), nie wystawiaj portu 8443 do Internetu,
- włącz 2FA dla `root@pam` w PDM,
- regularnie aktualizuj PDM,
- rozważ token z ograniczoną rolą (np. `PVEAuditor` + `PVEVMAdmin`) zamiast pełnego `Administrator`, jeśli nie potrzebujesz wszystkich funkcji.

## Problemy

| Objaw | Przyczyna / rozwiązanie |
|---|---|
| „unsupported version” przy dodawaniu PVE | PVE < 8.4 – zaktualizuj |
| zdalny raz działa, raz nie | PDM łączy się na adres LAN, którego nie widzi – zmień punkty połączenia na adresy Tailscale |
| błąd certyfikatu po aktualizacji PVE | certyfikat węzła się zmienił – zaktualizuj fingerprint w ustawieniach zdalnego |
