# 03. Klaster Proxmox VE

## Jak to działa

| Komponent | Rola |
|---|---|
| **corosync** | komunikacja między węzłami, członkostwo i quorum (głosowanie) |
| **pmxcfs** (`pve-cluster`) | rozproszony system plików zamontowany w `/etc/pve` – konfiguracja VM, storage, użytkownicy, certyfikaty; replikowany na wszystkie węzły |
| **quorum** | większość głosów (> 50%). Bez quorum `/etc/pve` jest tylko do odczytu |

Ważne pliki:

```
/etc/pve/corosync.conf          # konfiguracja klastra (wersja „główna”, replikowana)
/etc/corosync/corosync.conf     # lokalna kopia używana przez demona corosync
/etc/corosync/authkey           # klucz klastra – nie publikować
/etc/pve/nodes/<węzeł>/qemu-server/<vmid>.conf   # konfiguracje VM
/var/lib/pve-cluster/config.db  # baza SQLite, z której powstaje /etc/pve
```

## Wymagania przed utworzeniem klastra

- Wszystkie węzły w tej samej wersji PVE (`pveversion`).
- Statyczne IP, poprawny `/etc/hosts` na każdym węźle (patrz [01-instalacja-pve.md](01-instalacja-pve.md#43-plik-etchosts)).
- Zsynchronizowany czas (`timedatectl`, chrony jest domyślnie).
- Węzeł dołączany **nie może mieć maszyn** – jego `/etc/pve` zostanie nadpisane.
- Port UDP 5405–5412 (corosync) i TCP 22, 8006 otwarte między węzłami.

## Tworzenie klastra

### GUI

1. Na `pve`: *Datacenter → Cluster → Create Cluster* → nazwa `Itechnology`, link0 = `192.168.1.10`.
2. *Join Information* → *Copy Information*.
3. Na `pve2`: *Datacenter → Cluster → Join Cluster* → wklej, podaj hasło roota `pve`, link0 = `192.168.1.11`.

### CLI

```bash
# na pve
pvecm create Itechnology --link0 192.168.1.10

# na pve2
pvecm add 192.168.1.10 --link0 192.168.1.11
#   - zapyta o hasło roota pve i pokaże fingerprint do potwierdzenia
```

Sprawdzenie:

```bash
pvecm status
pvecm nodes
corosync-cfgtool -s        # stan linków knet
journalctl -u corosync -u pve-cluster -b --no-pager | tail -50
```

### Błąd z fingerprintem (z mojego labu)

Próbowałem podać fingerprint ręcznie i dostałem:

```
fingerprint: value does not match the regex pattern
```

Parametr `--fingerprint` oczekuje odcisku **certyfikatu HTTPS** węzła w formacie `AA:BB:CC:...` (SHA-256 z dwukropkami), a nie odcisku klucza SSH (`SHA256:base64...`). Odcisk certyfikatu:

```bash
# na pve
openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -fingerprint -sha256
```

Najprościej pominąć `--fingerprint` – `pvecm add` sam pokaże odcisk do zatwierdzenia.

### Problemy z certyfikatami

Jeśli GUI nie działa po dołączeniu albo `pveproxy` nie startuje z błędem certyfikatu:

```bash
pvecm updatecerts --force
systemctl restart pveproxy pvedaemon
```

Ręczne generowanie własnego CA i certyfikatów `openssl` (co robiłem na `pve2`) jest zbędne – `pvecm updatecerts` robi to poprawnie, z właściwymi nazwami i podpisem CA klastra.

## Quorum w klastrze 2-węzłowym

```
Expected votes: 2     Total votes: 2     Quorum: 2
```

Gdy jeden węzeł zniknie: `Total votes: 1 < Quorum: 2` → brak quorum → nie wystartujesz VM, nie zmienisz konfiguracji.

Awaryjnie, **tylko gdy masz pewność, że drugi węzeł jest wyłączony**:

```bash
pvecm expected 1
```

### QDevice – trzeci głos dla klastra 2-węzłowego

QDevice to lekki demon (`corosync-qnetd`) na dowolnej trzeciej maszynie z Debianem – np. Raspberry Pi, VM na komputerze z PBS albo sam PBS. Działa też przez Tailscale (wymaga tylko TCP 5403).

```bash
# na maszynie zewnętrznej (np. 100.x.y.z w Tailscale)
apt install corosync-qnetd

# na OBU węzłach PVE
apt install corosync-qdevice

# na jednym węźle PVE
pvecm qdevice setup 100.x.y.z     # IP maszyny z qnetd
pvecm status                      # Expected votes: 3, Flags: Quorate Qdevice
```

Teraz klaster przetrwa awarię jednego węzła – to warunek sensownego [HA](10-ha.md).

## Bezpieczna edycja corosync.conf

**Nigdy nie edytuj `/etc/pve/corosync.conf` bezpośrednio edytorem** – każdy zapis od razu się replikuje, a plik w połowie edycji może rozłożyć klaster. Do tego zawsze trzeba podbić `config_version`.

```bash
cd /etc/pve
cp corosync.conf corosync.conf.new
cp corosync.conf /root/corosync.conf.bak.$(date +%F)   # kopia poza /etc/pve
nano corosync.conf.new        # zmiany + config_version o 1 w górę
mv corosync.conf.new corosync.conf
pvecm status
```

Przykład – dodanie drugiego linku (np. przez drugą kartę albo Tailscale jako zapas):

```
node {
  name: pve
  nodeid: 1
  quorum_votes: 1
  ring0_addr: 192.168.1.10
  ring1_addr: 10.99.0.10
}
...
totem {
  cluster_name: Itechnology
  config_version: 3          # było 2
  interface { linknumber: 0 }
  interface { linknumber: 1 }
  ...
}
```

## Naprawa: klaster rozsypał się po edycji corosync.conf

Tak wyglądała moja sytuacja: po ręcznej edycji `corosync.conf` węzły przestały się widzieć, `/etc/pve` było tylko do odczytu, a kopia (`corosync_kopia.conf`) nie dała się skopiować z powrotem. Procedura, która zadziałała:

```bash
# na węźle z problemem
systemctl stop pve-cluster corosync
killall pmxcfs 2>/dev/null

pmxcfs -l                     # tryb lokalny – /etc/pve zapisywalne bez quorum

cp /root/corosync.conf.bak.YYYY-MM-DD /etc/pve/corosync.conf    # albo popraw ręcznie
cp /etc/pve/corosync.conf /etc/corosync/corosync.conf          # lokalna kopia musi być identyczna

killall pmxcfs
systemctl start corosync pve-cluster
pvecm status
journalctl -xeu pve-cluster --no-pager | tail -30
```

To samo na drugim węźle, jeśli jego kopia też jest zła. `config_version` musi być identyczny i wyższy niż przed awarią.

## Usunięcie węzła z klastra

```bash
# węzeł do usunięcia: wyłączony na stałe, bez VM
pvecm nodes
pvecm delnode pve2
rm -rf /etc/pve/nodes/pve2     # po upewnieniu się, że nie ma tam potrzebnych konfiguracji
```

Węzeł usunięty z klastra **nie może wrócić w tej samej postaci** – przed ponownym dołączeniem trzeba go przeinstalować albo wyczyścić konfigurację klastra.

## Ściąga

| Polecenie | Co robi |
|---|---|
| `pvecm status` | stan klastra i quorum |
| `pvecm nodes` | lista węzłów |
| `pvecm expected N` | awaryjnie zmienia liczbę oczekiwanych głosów |
| `pvecm updatecerts --force` | odtwarza certyfikaty węzła |
| `pvecm qdevice setup <ip>` | dodaje QDevice |
| `corosync-cfgtool -s` | stan linków |
| `corosync-quorumtool -s` | szczegóły quorum |
| `pmxcfs -l` | tryb lokalny /etc/pve (ratunkowy) |
