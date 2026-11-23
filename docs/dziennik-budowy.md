# Dziennik budowy labu i wnioski

Ten rozdział powstał na podstawie historii poleceń (`~/.bash_history`) z obu węzłów: około 500 wpisów na `pve` i 300 na `pve2`. Pokazuje, jak lab był faktycznie budowany – razem z błędami, bo z nich nauczyłem się najwięcej. Klucze, hasła i odciski certyfikatów zostały usunięte.

Dla każdego etapu: **co robiłem → co poszło nie tak → jak to zrobić dobrze**.

---

## Etap 1. Sieć i nazwa hosta

```bash
ifconfig
nano /etc/network/interfaces
ifreload -a
hostname
nano /etc/hosts
nano /etc/hostname
```

- Kilka iteracji edycji `interfaces`, zanim most `vmbr0` z adresem statycznym zadziałał.
- Na `pve2` zmieniałem `hostname` i `/etc/hosts` już po instalacji, co później odbiło się na certyfikatach (etap 3).

**Wniosek:** ustal hostname, FQDN i IP w instalatorze i nie zmieniaj ich. `ifreload -a` stosuje zmiany sieci bez restartu, ale po błędzie w `vmbr0` tracisz dostęp zdalny – trzeba mieć monitor/klawiaturę. Patrz [02-siec.md](02-siec.md).

## Etap 2. Repozytoria

```bash
nano /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/pve-enterprise.list
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > ...
nano /etc/apt/sources.list.d/ceph.list
apt-get update
```

**Wniosek:** to samo robi się kilkoma kliknięciami w *Updates → Repositories*, albo skryptem [scripts/post-install.sh](../scripts/post-install.sh). W PVE 9 pliki mają format `.sources`.

## Etap 3. Certyfikaty na pve2

Po zmianie nazwy hosta GUI na `pve2` nie działało. Usuwałem pliki `pve-ssl.*`, `pveproxy-ssl.*`, `pve-root-ca.pem`, generowałem własne CA i certyfikaty przez `openssl genrsa` / `openssl req` / `openssl x509`, restartowałem `pveproxy`.

**Wniosek:** jedno polecenie odtwarza wszystko poprawnie:

```bash
pvecm updatecerts --force
systemctl restart pveproxy pvedaemon
```

Ręcznie wygenerowane certyfikaty łatwo mają złe nazwy (SAN) lub nie są podpisane przez CA klastra.

## Etap 4. Klaster

```bash
pvecm create ...                 # na pve
pvecm add 192.168.1.10 --fingerprint SHA256:...    # na pve2 – błąd
pvecm add 192.168.1.10 -f ...                       # błąd
pvecm add 192.168.1.10                              # zadziałało
```

Błąd: `fingerprint: value does not match the regex pattern` – podawałem odcisk klucza SSH zamiast odcisku certyfikatu HTTPS.

**Wniosek:** `pvecm add <ip>` bez `--fingerprint` sam pokazuje odcisk do potwierdzenia. Patrz [03-klaster.md](03-klaster.md#błąd-z-fingerprintem-z-mojego-labu).

## Etap 5. Ceph – pierwsza próba

```bash
ceph -s                          # HEALTH_WARN: OSD count 0 < osd_pool_default_size 3
scp /etc/ceph/ceph.conf root@192.168.1.11:/etc/ceph/
ceph auth get-or-create-key client.bootstrap-osd ...
ceph auth del client.bootstrap-osd
ceph auth add client.bootstrap-osd ...
ceph-authtool --create-keyring ...
scp ...bootstrap-osd.keyring root@192.168.1.11:/etc/ceph/
ceph-volume lvm create --data /dev/sdb1   # błąd: brak klucza bootstrap-osd
pvcreate / vgcreate ceph-vg / lvcreate ceph-lv   # próba ręcznego LVM pod OSD
```

Kilka godzin walki o klucz `client.bootstrap-osd` i ręczne kopiowanie plików między węzłami. Przy okazji wkleiłem klucz Ceph do polecenia `echo`/`cat <<EOF`, więc został w historii powłoki.

**Wnioski:**
- `/etc/ceph/ceph.conf` w Proxmoxie to dowiązanie do `/etc/pve/ceph.conf` – już jest na wszystkich węzłach, `scp` niepotrzebny.
- Klucz dla `ceph-volume` wystarczy wyeksportować: `ceph auth get client.bootstrap-osd > /var/lib/ceph/bootstrap-osd/ceph.keyring`. Usuwanie i tworzenie go od nowa psuje pozostałe węzły.
- `ceph-volume` sam tworzy LVM – ręczne `pvcreate/vgcreate` tylko przeszkadza.
- Klucze (`AQ...==`) nie mogą trafiać do historii. Patrz [11-bezpieczenstwo.md](11-bezpieczenstwo.md#higiena-sekretów).

## Etap 6. Ceph – druga próba (działająca)

```bash
ceph-volume lvm zap /dev/sdb --destroy
sgdisk --zap-all /dev/sdb
sgdisk -n 1:0:+465G -n 2:0:0 /dev/sdb
wipefs -a /dev/sdb1 /dev/sdb2
ceph-volume lvm create --data /dev/sdb1
ceph-volume lvm create --data /dev/sdb2
ceph osd pool set grzegorz-pool size 2
ceph pg repair 2.0
ceph osd df tree
```

Efekt: 3 OSD (2 na `pve`, 1 na `pve2`), pula `grzegorz-pool` jako storage RBD. Po drodze usunięta testowa pula `rbd_pool` i ręcznie wyczyszczone stare OSD (`ceph osd out/crush remove/auth del/rm`, `lvremove`, `vgremove`).

**Wnioski:** `pveceph osd create` dla całych dysków i `pveceph osd destroy --cleanup` do usuwania oszczędzają większość ręcznej pracy. Rozmiar puli (`size`) dobieraj do liczby hostów. Patrz [04-ceph.md](04-ceph.md).

## Etap 7. Awaria klastra po edycji corosync.conf

```bash
cp /etc/pve/corosync.conf /etc/pve/corosync_kopia.conf
nano /etc/pve/corosync.conf          # edycja na żywo
# klaster się rozpada, /etc/pve tylko do odczytu
cp /etc/pve/corosync_kopia.conf /etc/pve/corosync.conf   # Permission denied
systemctl stop pve-cluster; killall pmxcfs
fusermount -u /etc/pve
pmxcfs -l                            # tryb lokalny
nano /etc/corosync/corosync.conf
systemctl restart corosync
systemctl start pve-cluster
```

Kopia leżała w `/etc/pve`, czyli w tym samym systemie plików, który przestał być zapisywalny.

**Wnioski:**
- Edytuj kopię `corosync.conf.new`, podbij `config_version`, potem `mv` – nigdy bezpośrednio.
- Kopię zapasową trzymaj poza `/etc/pve` (np. `/root`).
- `pmxcfs -l` + skopiowanie poprawnego pliku do `/etc/pve/corosync.conf` **i** `/etc/corosync/corosync.conf` to procedura ratunkowa. Patrz [03-klaster.md](03-klaster.md#naprawa-klaster-rozsypał-się-po-edycji-corosyncconf).

## Etap 8. Karta USB na pve2 i restart OSD

```bash
dmesg | grep r8169
ifup enx00e04c3c8308
ip link set enx00e04c3c8308 up
systemctl restart ceph-osd@0 ceph-osd@1 ceph-osd@2
journalctl -xeu ceph-osd@1.service
```

Karta USB nie podnosiła się po restarcie, przez co część usług (w tym OSD) startowała bez sieci.

**Wniosek:** `auto enx…` w `/etc/network/interfaces`, firmware Realtek, a dla Ceph – sieć na stabilnej karcie wbudowanej.

## Etap 9. Diagnostyka niespodziewanego wyłączenia

```bash
last -x | grep shutdown
journalctl -b -1 -e
journalctl --since "2025-05-30" --until "2025-06-02 23:59"
cat /etc/crontab
```

Szukałem przyczyny wyłączenia serwera: kto i kiedy wydał `poweroff`/`reboot`, czy nie było zadania w cronie.

**Wniosek:** `last -x`, `journalctl -b -1` (poprzednie uruchomienie) i `journalctl --list-boots` to podstawowy zestaw do takiego śledztwa. Trwałe logi wymagają katalogu `/var/log/journal` (w Proxmoxie jest domyślnie).

## Etap 10. GUI nie działa (ExtJS / pveproxy)

```bash
ls -lh /usr/share/javascript/extjs/ext-all.js
curl -k https://127.0.0.1:8006     # curl: (7) Failed to connect
systemctl status pveproxy
```

GUI się nie ładowało – `pveproxy` nie nasłuchiwał. Sprawdzenie pliku ExtJS wykluczyło uszkodzony pakiet.

**Wniosek:** gdy GUI nie działa: `systemctl status pveproxy`, `journalctl -u pveproxy -e`, `ss -tlnp | grep 8006`, `systemctl restart pveproxy`. Jeśli brakuje plików – `apt install --reinstall pve-manager libjs-extjs proxmox-widget-toolkit`.

## Etap 11. Codzienna obsługa

```bash
qm list; pvecm nodes
ssh root@pve2 qm list
ssh root@pve2 qm start 130
qm set 130 -serial0 socket
qm terminal 130
```

**Wniosek:** `pvesh` obsługuje cały klaster z jednego węzła bez SSH – patrz [06-cli.md](06-cli.md#pvesh--api-z-linii-komend).

---

## Podsumowanie lekcji

1. Najpierw narzędzia Proxmoxa (`pvecm`, `pveceph`, `pvesm`), dopiero potem niskopoziomowe (`ceph-volume`, `openssl`, ręczna edycja plików).
2. Konfiguracja klastra to system rozproszony – każda zmiana w `/etc/pve` od razu trafia na wszystkie węzły.
3. Kopie zapasowe konfiguracji poza `/etc/pve`.
4. Sekrety nigdy w linii poleceń.
5. Klaster 2-węzłowy potrzebuje trzeciego głosu (QDevice) i rozsądnych ustawień Ceph.
