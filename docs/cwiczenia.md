# Ćwiczenia

Każde ćwiczenie ma kryterium zaliczenia. Odhaczaj `[x]` i dopisuj datę oraz uwagi.

## Podstawy

- [ ] **1. Inwentaryzacja.** Bez GUI wypisz: wersję PVE, węzły, storage z zajętością, listę VM z węzłem i stanem. *Zaliczone, gdy:* wszystko z jednego węzła przez `pvesh`.
- [ ] **2. Repozytoria.** Przełącz węzeł na no-subscription i zaktualizuj. *Zaliczone:* `apt update` bez błędu 401.
- [ ] **3. VM z ISO.** Zainstaluj Ubuntu Server na `grzegorz-pool`, z qemu-guest-agent. *Zaliczone:* IP VM widoczne w *Summary*.
- [ ] **4. Szablon cloud-init.** Uruchom [scripts/cloudinit-template.sh](../scripts/cloudinit-template.sh), sklonuj 2 VM ze statycznym IP. *Zaliczone:* logowanie kluczem SSH bez hasła.
- [ ] **5. Kontener LXC.** Unprivileged Debian z nginx. *Zaliczone:* strona z CT otwiera się w przeglądarce.

## Sieć

- [ ] **6. pfSense.** VM 110: WAN na `vmbr0`, LAN na `vmbr1`, DHCP w LAN. *Zaliczone:* VM w `vmbr1` ma Internet przez pfSense.
- [ ] **7. SDN.** Strefa Simple z DHCP i SNAT. *Zaliczone:* VM w VNecie dostaje IP i pinguje 1.1.1.1.

## Klaster i storage

- [ ] **8. Przeniesienie dysków na Ceph.** VM 110 i 111 z `local-lvm` na `grzegorz-pool`. *Zaliczone:* `local-lvm` < 30%.
- [ ] **9. Live-migracja.** VM 130 `pve2 → pve` podczas `ping -t`. *Zaliczone:* utracone ≤ 1–2 pakiety.
- [ ] **10. QDevice.** qnetd na trzeciej maszynie (PBS lub Raspberry Pi). *Zaliczone:* `Expected votes: 3`.
- [ ] **11. Awaria węzła.** Wyłącz `pve2`. *Zaliczone:* `pve` zachowuje quorum, VM na `pve` działają.
- [ ] **12. Ceph – usunięcie i dodanie OSD.** `ceph osd out` → czekanie na `HEALTH_OK` → `pveceph osd destroy` → ponowne utworzenie. *Zaliczone:* 3 OSD `up/in`, `HEALTH_OK`.
- [ ] **13. Bezpieczna zmiana corosync.conf.** Dodaj `link1`. *Zaliczone:* `corosync-cfgtool -s` pokazuje 2 linki, klaster nie stracił quorum.

## Backup

- [ ] **14. PBS.** Instalacja na komputerze lokalnym, Tailscale, datastore. *Zaliczone:* storage `pbs` aktywny w PVE.
- [ ] **15. Zadanie backupu.** Codziennie 02:00, wszystkie VM, retencja na PBS. *Zaliczone:* 3 kolejne udane backupy.
- [ ] **16. Test odtworzenia.** VM 130 → 9130 z `--unique 1`. *Zaliczone:* VM wstaje, dane aktualne. Czas odtworzenia: ____
- [ ] **17. Odtworzenie pliku.** Pobierz `/etc/hostname` z backupu przez *File Restore*.

## Zarządzanie i bezpieczeństwo

- [ ] **18. PDM.** Klaster i PBS dodane jako zdalne. *Zaliczone:* dashboard pokazuje oba węzły i datastore.
- [ ] **19. HA.** VM 130 w HA, odłączenie kabla `pve2`. *Zaliczone:* VM startuje na `pve`. Czas przełączenia: ____
- [ ] **20. Użytkownicy i role.** `operator@pve` może tylko start/stop VM w puli `lab`. *Zaliczone:* nie widzi innych VM, nie może usunąć VM.
- [ ] **21. 2FA.** TOTP dla `root@pam` + kody odzyskiwania.
- [ ] **22. Firewall.** Firewall na poziomie Datacenter z dostępem tylko z LAN i Tailscale. *Zaliczone:* GUI działa z LAN i tailnetu, port 8006 zamknięty dla innych.
- [ ] **23. Token API + monitoring.** Token `PVEAuditor`, podłączenie do Zabbixa (szablon *Proxmox VE by HTTP*). *Zaliczone:* metryki węzłów w Zabbixie.
- [ ] **24. Aktualizacja 8 → 9.** Według [12-aktualizacja-8-do-9.md](12-aktualizacja-8-do-9.md). *Zaliczone:* oba węzły na 9.x, `HEALTH_OK`, quorum.
