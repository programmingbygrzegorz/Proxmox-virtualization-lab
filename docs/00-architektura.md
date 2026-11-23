# 00. Architektura labu

## Sprzęt i węzły

| Węzeł | IP (vmbr0) | CPU | RAM | Dysk systemowy | Dysk pod Ceph |
|---|---|---|---|---|---|
| `pve` | 192.168.1.10/24 | 4 rdzenie | ~8 GB | `sda` 119 GB SSD | `sdb` 931 GB, podzielony na 2 partycje → 2 OSD |
| `pve2` | 192.168.1.11/24 | 4 rdzenie | ~8 GB | `sda` 119 GB SSD | `sdb` 466 GB → 1 OSD |

Brama: `192.168.1.1`. Oba węzły mają kartę wbudowaną (`enp1s0`) i dodatkową kartę USB‑Ethernet (`enx…`, sterownik `r8152`/`r8169`).

## Sieć

```
enp1s0 ──► vmbr0  192.168.1.x/24   zarządzanie, corosync, Ceph, VM w LAN
enx…   ──► vmbr1  (bez IP)         druga sieć – np. LAN za pfSense albo WAN pfSense
```

Fragment `/etc/network/interfaces` z `pve`:

```
auto vmbr0
iface vmbr0 inet static
        address 192.168.1.10/24
        gateway 192.168.1.1
        bridge-ports enp1s0
        bridge-stp off
        bridge-fd 0

auto vmbr1
iface vmbr1 inet manual
        bridge-ports enx00e04c68021f
        bridge-stp off
        bridge-fd 0
```

> **Uwaga projektowa:** corosync, Ceph public i Ceph cluster network idą tym samym łączem 1 Gb co ruch VM. W labie to działa, ale w produkcji corosync powinien mieć osobny link (najlepiej dwa – `link0` i `link1`), a Ceph osobną, szybką sieć (10 Gb+). Ruch Ceph potrafi zapchać łącze i spowodować utratę quorum.

## Storage

| ID | Typ | Zawartość | Współdzielony | Uwagi |
|---|---|---|---|---|
| `local` | dir (`/var/lib/vz`) | ISO, szablony CT, backupy | nie | na partycji root (25 GB) |
| `local-lvm` | LVM-thin (`pve/data`) | dyski VM i CT | nie | ~85 GB, zajęte w >80% przez VM 110 i 111 |
| `grzegorz-pool` | RBD (Ceph) | dyski VM i CT | **tak** | potrzebny do live-migracji i HA |

Pula Ceph `grzegorz-pool`: `size 2`, `min_size 2`. Pula `.mgr`: `size 3`, `min_size 2`.

> **Do poprawy:** VM 110 i 111 leżą na `local-lvm`, więc nie da się ich szybko zmigrować ani objąć HA. Przeniesienie dysków na Ceph: `qm disk move 110 scsi0 grzegorz-pool --delete 1` (szczegóły w [05-vm-lxc.md](05-vm-lxc.md)).

## Klaster

- Nazwa: `Itechnology`, transport `knet`, `secure auth: on`
- 2 węzły × 1 głos, `expected votes: 2`, quorum = 2

Konsekwencja: **gdy jeden węzeł padnie, drugi traci quorum** – `/etc/pve` przechodzi w tryb tylko do odczytu, nie da się uruchomić ani zmienić VM. Rozwiązanie: trzeci głos z QDevice (np. na Raspberry Pi albo na maszynie z PBS) – patrz [03-klaster.md](03-klaster.md#qdevice--trzeci-głos-dla-klastra-2-węzłowego).

## Ceph

- Monitory: 2 (`pve`, `pve2`), manager aktywny na `pve`
- OSD: `osd.3`, `osd.4` na `pve` (dwie partycje jednego dysku), `osd.0` na `pve2`
- Domena awarii: `host`, więc kopie rozkładane są między węzłami

Ograniczenia labu (świadome):
- Parzysta liczba monitorów (2) – przy awarii jednego węzła Ceph też traci quorum. Docelowo 3 monitory.
- Dwa OSD na jednym fizycznym dysku nie zwiększają niezawodności, tylko udają większą liczbę OSD.
- `size 2 / min_size 2` – awaria jednego hosta zatrzymuje zapisy. `size 2 / min_size 1` pozwala pracować dalej, ale grozi utratą danych – w produkcji standard to `size 3 / min_size 2` i minimum 3 węzły.
- Pula `.mgr` ma `size 3` przy dwóch hostach, więc jeden PG zostaje `remapped` – to nie błąd, tylko brak trzeciego hosta.

## Maszyny wirtualne

| VMID | Nazwa | Węzeł | RAM | Dysk | Rola |
|---|---|---|---|---|---|
| 110 | PfSense | pve | 1,5 GB | 32 GB (local-lvm) | firewall/router między `vmbr0` a `vmbr1` |
| 111 | Wazuh | pve | 4 GB | 50 GB (local-lvm) | SIEM/XDR – zbiera logi z VM i hostów |
| 130 | VM 130 | pve2 | 6 GB | 83 GB | maszyna testowa, konsola szeregowa |

## Elementy zewnętrzne (komputer lokalny)

| Element | Rola | Połączenie |
|---|---|---|
| Proxmox Backup Server | cel backupów VM/CT, deduplikacja, weryfikacja | Tailscale |
| Proxmox Datacenter Manager | jedno okno na klaster, PBS, aktualizacje, migracje | Tailscale |

Szczegóły: [07-tailscale.md](07-tailscale.md), [08-pbs.md](08-pbs.md), [09-pdm.md](09-pdm.md).
