# 07. Tailscale – wspólna sieć dla PVE, PBS i PDM

## Po co

Proxmox Backup Server i Proxmox Datacenter Manager stoją na moim komputerze lokalnym, który nie zawsze jest w tym samym LAN co klaster. Tailscale (WireGuard + koordynacja) daje każdemu urządzeniu stały adres `100.x.y.z` i nazwę MagicDNS, bez otwierania portów na routerze.

```
            tailnet
  pve   100.a.a.a  ─┐
  pve2  100.b.b.b  ─┼──  PDM  100.d.d.d  → zarządza pve/pve2 (8006) i PBS (8007)
  pbs   100.c.c.c  ─┘    pve/pve2 → PBS (8007) – backupy
```

Ruch, który idzie przez Tailscale:

| Z → Do | Port | Po co |
|---|---|---|
| pve, pve2 → pbs | TCP 8007 | backup i przywracanie |
| pdm → pve, pve2 | TCP 8006 | zarządzanie klastrem |
| pdm → pbs | TCP 8007 | zarządzanie PBS |
| ty → wszystko | TCP 8006/8007/8443, 22 | GUI i SSH z dowolnego miejsca |
| pve, pve2 → qnetd (opcjonalnie) | TCP 5403 | QDevice |

**Czego NIE puszczać przez Tailscale:** głównego linku corosync i sieci Ceph. Corosync potrzebuje stabilnych opóźnień < 5 ms, a Ceph przepustowości – oba zostają w LAN.

## 1. Konto i tailnet

1. Załóż konto na <https://login.tailscale.com> (plan Personal jest darmowy).
2. *DNS* → włącz **MagicDNS** – urządzenia będą osiągalne jako `pve`, `pbs` itd.

## 2. Instalacja na węzłach PVE

Na `pve` i `pve2`:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --hostname=pve            # na pve2: --hostname=pve2
# otwórz wyświetlony link i zaloguj urządzenie
tailscale ip -4
tailscale status
```

Opcjonalnie: wyłącz wygasanie klucza dla serwerów (*Machines → … → Disable key expiry*), inaczej po 180 dniach węzeł wypadnie z tailnetu.

### Dostęp do całego LAN przez jeden węzeł (subnet router)

Zamiast instalować Tailscale na każdej VM, jeden węzeł może udostępnić całą sieć 192.168.1.0/24:

```bash
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf
tailscale up --hostname=pve --advertise-routes=192.168.1.0/24
```

W panelu: *Machines → pve → Edit route settings* → zatwierdź trasę. Na komputerach w LAN, które też są w tailnecie, nie akceptuj tych tras (`--accept-routes=false`), żeby ruch lokalny nie szedł naokoło.

## 3. Instalacja na PBS i PDM

PBS i PDM to Debian, więc identycznie:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --hostname=pbs     # albo --hostname=pdm
```

## 4. Sprawdzenie łączności

```bash
# z pve
tailscale ping pbs
curl -sk https://pbs:8007 -o /dev/null -w '%{http_code}\n'    # 200 = GUI PBS osiągalne

# z pdm
curl -sk https://pve:8006 -o /dev/null -w '%{http_code}\n'
```

`tailscale ping` pokazuje, czy połączenie jest bezpośrednie (`via 192.168.1.x`) czy przez przekaźnik DERP (wolniej – sprawdź firewall/NAT).

## 5. Reguły dostępu (ACL)

W panelu *Access controls* ogranicz, kto do czego ma dostęp. Przykład z tagami:

```json
{
  "tagOwners": {
    "tag:pve": ["autogroup:admin"],
    "tag:pbs": ["autogroup:admin"],
    "tag:pdm": ["autogroup:admin"]
  },
  "acls": [
    {"action": "accept", "src": ["autogroup:admin"], "dst": ["*:*"]},
    {"action": "accept", "src": ["tag:pve"], "dst": ["tag:pbs:8007"]},
    {"action": "accept", "src": ["tag:pdm"], "dst": ["tag:pve:8006", "tag:pbs:8007"]}
  ]
}
```

Tag nadajesz przy logowaniu: `tailscale up --advertise-tags=tag:pve` (albo w panelu).

## 6. Certyfikaty i fingerprinty

PBS i PVE mają certyfikaty self-signed. Przy dodawaniu PBS do PVE i węzłów do PDM podajesz **fingerprint** certyfikatu:

```bash
# na PBS
proxmox-backup-manager cert info | grep Fingerprint
# na PVE
openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -fingerprint -sha256
```

Alternatywa: `tailscale cert pbs.<tailnet>.ts.net` wystawia prawdziwy certyfikat Let's Encrypt dla nazwy w tailnecie (wymaga włączenia HTTPS w panelu DNS).

## Problemy

| Objaw | Co sprawdzić |
|---|---|
| `tailscale status` pokazuje `offline` | `systemctl status tailscaled`, wygasły klucz urządzenia |
| połączenie tylko przez DERP | UDP 41641 blokowane, podwójny NAT; `tailscale netcheck` |
| PVE nie widzi PBS po nazwie | MagicDNS włączone? `cat /etc/resolv.conf` (powinien być `100.100.100.100`); jeśli nie chcesz, by Tailscale zmieniał DNS hosta (`--accept-dns=false`), użyj adresu 100.x |
| po restarcie brak Tailscale | `systemctl enable tailscaled` |
