# 04. Ceph w Proxmox VE

Ceph daje storage współdzielony między węzłami: dysk VM jest dostępny z każdego węzła, więc działa live-migracja i HA bez kopiowania danych.

## Pojęcia

| Element | Rola | Ile w labie |
|---|---|---|
| **MON** (monitor) | mapa klastra Ceph, quorum Ceph | 2 (docelowo 3 – liczba nieparzysta) |
| **MGR** (manager) | metryki, dashboard, moduły | 1 aktywny |
| **OSD** | jeden dysk/partycja przechowująca dane | 3 |
| **Pool** | logiczna pula z ustawieniem replikacji | `grzegorz-pool`, `.mgr` |
| **PG** (placement group) | jednostka rozkładania danych między OSD | 33 |
| `size` / `min_size` | liczba kopii / minimum kopii, przy którym pula przyjmuje zapisy | 2 / 2 |

## Instalacja (zalecana droga – `pveceph`)

Na **każdym** węźle:

```bash
pveceph install --repository no-subscription     # PVE 9 instaluje Ceph Squid
```

Na pierwszym węźle:

```bash
pveceph init --network 192.168.1.0/24            # public_network (+ opcjonalnie --cluster-network)
pveceph mon create
pveceph mgr create
```

Na pozostałych węzłach:

```bash
pveceph mon create
pveceph mgr create        # zapasowy manager
```

OSD na całym, pustym dysku:

```bash
lsblk
ceph-volume lvm zap /dev/sdb --destroy     # UWAGA: kasuje dysk
pveceph osd create /dev/sdb
```

Pula i storage w Proxmoxie jednym poleceniem:

```bash
pveceph pool create grzegorz-pool --size 2 --min_size 2 --add_storages
```

GUI: *węzeł → Ceph → Install*, potem *Monitor*, *OSD → Create*, *Pools → Create*.

## Mój przypadek: dwa OSD z jednego dysku

`pveceph osd create` przyjmuje tylko cały dysk. Na `pve` podzieliłem 931 GB na dwie partycje i utworzyłem OSD ręcznie:

```bash
ceph-volume lvm zap /dev/sdb --destroy
sgdisk -n 1:0:+465G -n 2:0:0 /dev/sdb
partprobe /dev/sdb
wipefs -a /dev/sdb1 /dev/sdb2

ceph auth get client.bootstrap-osd > /var/lib/ceph/bootstrap-osd/ceph.keyring
ceph-volume lvm create --data /dev/sdb1
ceph-volume lvm create --data /dev/sdb2
ceph osd tree
```

> W produkcji tak się nie robi – dwa OSD na jednym dysku dzielą jego wydajność i awarię. W labie pozwala ćwiczyć z większą liczbą OSD.

### Lekcja: brakujący klucz bootstrap-osd

Najwięcej czasu zajęło mi ręczne tworzenie klucza `client.bootstrap-osd` (`ceph auth add`, `ceph-authtool`, kopiowanie przez `scp`). Przyczyna: `ceph-volume` szuka klucza w `/var/lib/ceph/bootstrap-osd/ceph.keyring`, a Proxmox trzyma go gdzie indziej. Wystarczy jedno polecenie na danym węźle:

```bash
ceph auth get client.bootstrap-osd > /var/lib/ceph/bootstrap-osd/ceph.keyring
```

Nie twórz go na nowo (`ceph auth del` + `add`) – zmienisz klucz, którego używają inne węzły.

> **Bezpieczeństwo:** klucze Ceph (`AQ...==`) to hasła. Nie wklejaj ich do poleceń w terminalu (zostają w `~/.bash_history`), nie wrzucaj do repozytorium. Jeśli trafiły do historii: usuń wpis (`history -d N` albo edycja pliku) i rozważ wymianę klucza.

## Ustawienia puli

```bash
ceph osd pool ls detail
ceph osd pool get grzegorz-pool size
ceph osd pool set grzegorz-pool size 2
ceph osd pool set grzegorz-pool min_size 2
ceph osd pool autoscale-status
```

| Ustawienie | Zachowanie przy awarii 1 z 2 hostów |
|---|---|
| `size 2, min_size 2` | dane bezpieczne, **zapisy wstrzymane** do powrotu hosta (tak jest w labie) |
| `size 2, min_size 1` | VM działają dalej, ale przez ten czas istnieje tylko 1 kopia – ryzyko utraty danych |
| `size 3, min_size 2` | standard produkcyjny, wymaga min. 3 hostów |

`.mgr` ma `size 3` przy 2 hostach, więc 1 PG jest `active+clean+remapped`. Ostrzeżenie zniknie po dodaniu trzeciego hosta albo po `ceph osd pool set .mgr size 2`.

## Stan i diagnostyka

```bash
ceph -s                     # ogólny stan
ceph health detail          # co dokładnie jest nie tak
ceph osd tree               # OSD i hosty
ceph osd df tree            # zajętość OSD
ceph df                     # zajętość pul
ceph pg stat
ceph pg ls | head
ceph pg <pgid> query        # szczegóły jednego PG
ceph mon stat; ceph quorum_status -f json-pretty
journalctl -u ceph-osd@0 -e
```

Naprawa niespójnego PG:

```bash
ceph health detail | grep inconsistent
ceph pg repair <pgid>
```

## Usuwanie OSD (np. przed wymianą dysku)

```bash
ceph osd out osd.1                       # dane migrują na inne OSD – poczekaj na HEALTH_OK
ceph -s
systemctl stop ceph-osd@1
pveceph osd destroy 1 --cleanup          # usuwa z crush, auth i czyści dysk
```

Ręcznie (tak robiłem, zanim poznałem `pveceph osd destroy`):

```bash
ceph osd crush remove osd.1
ceph auth del osd.1
ceph osd rm osd.1
ceph-volume lvm zap /dev/sdb --destroy
```

## Usuwanie puli

```bash
ceph config set mon mon_allow_pool_delete true
ceph osd pool delete rbd_pool rbd_pool --yes-i-really-really-mean-it
ceph config set mon mon_allow_pool_delete false
```

Usuń też wpis z `/etc/pve/storage.cfg` (lub *Datacenter → Storage → Remove*), inaczej GUI będzie pokazywać storage ze znakiem zapytania.

## Dobre praktyki

- Minimum 3 węzły i 3 monitory w produkcji.
- Osobna sieć dla Ceph (10 Gb+), dyski SSD/NVMe z zabezpieczeniem przed utratą zasilania (PLP).
- Nie przekraczaj ~80% zajętości – przy `nearfull` (85%) Ceph ostrzega, przy `full` (95%) zatrzymuje zapisy.
- Ceph nie jest backupem – backupy robi [PBS](08-pbs.md).
