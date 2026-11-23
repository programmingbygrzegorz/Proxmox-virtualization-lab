# 12. Aktualizacja Proxmox VE 8 → 9

Mój klaster działa na PVE 8.3 z Ceph Quincy. Wsparcie PVE 8.x skończyło się w sierpniu 2026, a PDM wymaga co najmniej 8.4 – czas na aktualizację. Oficjalny przewodnik: <https://pve.proxmox.com/wiki/Upgrade_from_8_to_9>.

## Kolejność w moim labie

```
1. Backup wszystkich VM na PBS + test odtworzenia jednej
2. PVE 8.3 → najnowsze 8.4 (oba węzły)
3. Ceph Quincy → Reef → Squid (PVE 9 wspiera tylko Squid)
4. pve8to9 --full – usunąć wszystkie FAIL i WARN
5. Węzeł po węźle: repozytoria trixie → apt full-upgrade → reboot
6. Sprawdzenie klastra, Ceph, HA
```

## 1. Przygotowanie

```bash
# na obu węzłach
apt update && apt full-upgrade -y        # do najnowszej 8.4
pveversion                               # pve-manager/8.4.x
pvecm status | grep Quorate
ceph -s                                  # HEALTH_OK
```

Kopia konfiguracji (poza `/etc/pve`):

```bash
tar czf /root/etc-backup-$(hostname)-$(date +%F).tgz /etc /var/lib/pve-cluster/config.db
```

## 2. Ceph Quincy → Reef → Squid

Każdy skok to osobna procedura z wiki Proxmoxa (*Ceph Quincy to Reef*, *Ceph Reef to Squid*). W skrócie dla jednego skoku:

```bash
ceph osd set noout
# na każdym węźle: zmiana repozytorium ceph-quincy → ceph-reef w /etc/apt/sources.list.d/ceph.list
apt update && apt full-upgrade -y
systemctl restart ceph-mon.target      # węzeł po węźle, czekaj na quorum
systemctl restart ceph-mgr.target
systemctl restart ceph-osd.target      # węzeł po węźle, czekaj na HEALTH_OK / active+clean
ceph versions                          # wszystkie demony w nowej wersji
ceph osd require-osd-release reef
ceph osd unset noout
```

Potem to samo z `ceph-reef` → `ceph-squid` i `require-osd-release squid`.

## 3. Sprawdzenie gotowości

```bash
pve8to9 --full
```

Typowe uwagi: brak `amd64-microcode`/`intel-microcode`, stare jądro, systemd-boot, zbyt mało miejsca na `/`, VM uruchomione na starej wersji maszyny QEMU.

## 4. Aktualizacja węzła

Najpierw przenieś VM na drugi węzeł (albo je wyłącz), potem na tym węźle:

```bash
sed -i 's/bookworm/trixie/g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list
sed -i 's/ceph-squid bookworm/ceph-squid trixie/' /etc/apt/sources.list.d/ceph.list
apt update
apt full-upgrade                  # odpowiadaj na pytania o pliki konfiguracyjne wg przewodnika
reboot
pveversion                        # pve-manager/9.x
apt modernize-sources             # opcjonalnie: przejście na format .sources (deb822)
```

Powtórz na drugim węźle. Klaster działa w trybie mieszanym 8/9 tylko na czas aktualizacji.

## 5. Po aktualizacji

```bash
pvecm status
ceph -s
ha-manager status
pvesm status
```

- Zaktualizuj fingerprinty w PBS/PDM, jeśli certyfikaty się zmieniły.
- Grupy HA zostały zamienione na reguły HA – sprawdź *Datacenter → HA → Rules*.
- Dodaj klaster do [PDM](09-pdm.md).
