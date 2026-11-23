# 02. Sieć w Proxmox VE

## Pojęcia

| Pojęcie | Co to jest |
|---|---|
| Interfejs fizyczny | `enp1s0`, `enx…` – karta sieciowa hosta |
| Linux bridge (`vmbrN`) | wirtualny przełącznik; VM podłączają się do niego swoimi kartami |
| VLAN-aware bridge | most, który przenosi wiele VLAN-ów; tag ustawiasz na karcie VM |
| Bond | połączenie kilku kart w jedną (LACP, active-backup) |
| SDN | warstwa nad mostami: strefy (Simple, VLAN, VXLAN, EVPN) i VNety definiowane dla całego klastra |

Konfiguracja leży w `/etc/network/interfaces`, a stosuje ją `ifupdown2`:

```bash
ifreload -a          # zastosuj zmiany bez restartu
ifquery -a -c        # porównaj plik z aktualnym stanem
ip -br link; ip -br a
bridge link          # które porty są w którym moście
```

> Zmiany zrobione w GUI (*węzeł → System → Network*) czekają w `/etc/network/interfaces.new` do kliknięcia **Apply Configuration**.

## Konfiguracja w moim labie

```
auto lo
iface lo inet loopback

iface enp1s0 inet manual
iface enx00e04c68021f inet manual     # karta USB

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

source /etc/network/interfaces.d/*
```

`vmbr1` nie ma IP – host nie jest w tej sieci, służy tylko maszynom (np. pfSense).

### Karty USB-Ethernet (Realtek)

Na `pve2` karta USB (`enx00e04c3c8308`) czasem nie podnosiła się po restarcie. Diagnostyka, której użyłem:

```bash
dmesg | grep -iE 'r8152|r8169|enx'
ip link set enx00e04c3c8308 up
ifup enx00e04c3c8308
```

Rozwiązanie: dodać `auto enx…` nad definicją interfejsu i sprawdzić, czy jest firmware (`apt install firmware-realtek` z komponentem `non-free-firmware`). Nazwa `enx…` pochodzi z adresu MAC, więc po wymianie przejściówki zmieni się nazwa interfejsu.

## pfSense jako router dla sieci laboratoryjnej

```
Internet ── router domowy 192.168.1.1 ── vmbr0 ── [WAN] pfSense (VM 110) [LAN] ── vmbr1 ── VM testowe 10.10.10.0/24
```

1. VM 110: `net0` → `vmbr0` (WAN, DHCP lub 192.168.1.x), `net1` → `vmbr1` (LAN, np. 10.10.10.1/24).
2. Model karty: **VirtIO** (pfSense ma sterownik `vtnet`). Wyłącz *Firewall* na kartach w Proxmoxie, żeby nie dublować reguł.
3. W pfSense: *System → Advanced → Networking* → zaznacz **Disable hardware checksum offload** (inaczej problemy z ruchem przez VirtIO).
4. Maszyny testowe podłączasz do `vmbr1` – dostają adresy z DHCP pfSense i wychodzą do Internetu przez jego NAT.

```bash
qm set 110 --net0 virtio,bridge=vmbr0,firewall=0
qm set 110 --net1 virtio,bridge=vmbr1,firewall=0
```

## VLAN (gdy przełącznik obsługuje 802.1Q)

```
auto vmbr0
iface vmbr0 inet static
        address 192.168.1.10/24
        gateway 192.168.1.1
        bridge-ports enp1s0
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
        bridge-vids 2-4094
```

```bash
qm set 130 --net0 virtio,bridge=vmbr0,tag=20     # VM w VLAN 20
```

## SDN (Datacenter → SDN)

SDN pozwala raz zdefiniować sieć dla całego klastra zamiast ręcznie dodawać mosty na każdym węźle.

Ćwiczenie – izolowana sieć z DHCP:

1. *Datacenter → SDN → Zones → Add → Simple*: ID `labzone`, zaznacz **automatic DHCP** (wymaga `apt install dnsmasq` i `systemctl disable --now dnsmasq` na węzłach).
2. *VNets → Create*: `labnet`, strefa `labzone`.
3. *Subnets → Create*: `10.20.0.0/24`, gateway `10.20.0.1`, **SNAT** zaznaczone, zakres DHCP `10.20.0.100–10.20.0.200`.
4. *SDN → Apply*.
5. Podłącz VM do mostu `labnet`.

CLI:

```bash
pvesh get /cluster/sdn/zones
pvesh get /cluster/sdn/vnets
pvesh set /cluster/sdn          # odpowiednik "Apply"
```

## Dobre praktyki

- Corosync na osobnym, mało obciążonym łączu; najlepiej dwa linki (`link0`, `link1`).
- Ceph na osobnej sieci (minimum 10 Gb w produkcji).
- Przed `ifreload -a` na zdalnym węźle miej dostęp awaryjny (konsola IPMI/monitor) – błąd w `vmbr0` odcina zarządzanie.
- Kopia przed edycją: `cp /etc/network/interfaces /root/interfaces.$(date +%F)`.
