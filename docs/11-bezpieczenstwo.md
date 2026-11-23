# 11. Bezpieczeństwo

## Realmy (źródła użytkowników)

| Realm | Opis |
|---|---|
| `pam` | konta systemowe Linuksa (`root@pam`) – istnieją na każdym węźle osobno |
| `pve` | wbudowana baza Proxmoxa – jedna dla całego klastra |
| LDAP / AD / OpenID Connect | integracja z katalogiem firmowym (np. Entra ID przez OIDC) |

Zasada: `root@pam` tylko awaryjnie, na co dzień imienne konta w realmie `pve` lub AD/OIDC.

## Użytkownicy, grupy, role

```bash
pveum group add admins --comment "Administratorzy labu"
pveum user add grzegorz@pve --groups admins --email ja@example.com
pveum passwd grzegorz@pve
pveum aclmod / -group admins -role Administrator

# operator, który może tylko obsługiwać VM w puli "lab"
pveum pool add lab
pveum pool modify lab --vms 130,140
pveum user add operator@pve
pveum aclmod /pool/lab -user operator@pve -role PVEVMUser
```

Najważniejsze role wbudowane: `Administrator`, `PVEAdmin`, `PVEVMAdmin`, `PVEVMUser`, `PVEAuditor` (tylko odczyt), `PVEDatastoreUser`. Własna rola:

```bash
pveum role add VMRestart --privs "VM.PowerMgmt VM.Audit"
```

## Tokeny API

```bash
pveum user token add grzegorz@pve ansible --privsep 1
pveum aclmod /vms -token 'grzegorz@pve!ansible' -role PVEVMAdmin
pveum user token list grzegorz@pve
pveum user token remove grzegorz@pve ansible
```

`--privsep 1` = token ma **osobne** uprawnienia (najwyżej takie jak użytkownik) – bezpieczniej niż dziedziczenie wszystkiego.

## 2FA

*Datacenter → Permissions → Two Factor → Add → TOTP* (aplikacja typu Aegis, Google Authenticator) lub *WebAuthn* (klucz sprzętowy, wymaga HTTPS z poprawną nazwą). Dodaj też **Recovery Keys** i wydrukuj je.

Ćwiczenie: włącz TOTP dla `root@pam` i `grzegorz@pve`, wyloguj się, zaloguj ponownie.

> Wymuszenie 2FA dla realmu: *Permissions → Realms → pve → Edit → Require TFA: TOTP*.

## Firewall Proxmoxa

Trzy poziomy: **Datacenter** (`/etc/pve/firewall/cluster.fw`), **węzeł** (`host.fw`), **VM/CT** (`<vmid>.fw`). Domyślnie wyłączony na poziomie Datacenter.

> Przed włączeniem na poziomie Datacenter dodaj regułę dopuszczającą 8006 i 22 z sieci zarządzania – inaczej odetniesz się od GUI. Ruch klastra (corosync) Proxmox dopuszcza automatycznie.

Przykład `cluster.fw`:

```
[OPTIONS]
enable: 1

[IPSET management]
192.168.1.0/24
100.64.0.0/10     # Tailscale

[RULES]
IN ACCEPT -source +management -p tcp -dport 8006 -log nolog
IN ACCEPT -source +management -p tcp -dport 22 -log nolog
IN ACCEPT -source +management -p icmp
```

```bash
pve-firewall compile     # sprawdź przed zastosowaniem
pve-firewall status
```

## SSH

```bash
# klucz zamiast hasła (z laptopa)
ssh-copy-id root@192.168.1.10

# /etc/ssh/sshd_config.d/hardening.conf
PermitRootLogin prohibit-password
PasswordAuthentication no
```

Uwaga: węzły klastra łączą się ze sobą po SSH kluczami z `/etc/pve/priv/authorized_keys` – nie wyłączaj logowania roota kluczem.

## Higiena sekretów

- Nie wpisuj haseł, kluczy Ceph (`AQ...==`) ani tokenów jako argumentów poleceń – trafiają do `~/.bash_history`. Sprawdzenie i czyszczenie:
  ```bash
  grep -nE 'AQ[A-Za-z0-9+/]{30,}|password|token' ~/.bash_history
  history -d <numer>; history -w
  ```
- Spacja przed poleceniem nie zapisuje go w historii, jeśli `HISTCONTROL=ignorespace` (domyślnie w Debianie `ignoreboth`).
- Do repozytorium nie trafiają: `/etc/pve/priv/*`, `/etc/corosync/authkey`, `/etc/ceph/*.keyring`, klucze szyfrowania PBS.

## Monitoring bezpieczeństwa

- **Wazuh (VM 111)** – zainstaluj agenta na `pve` i `pve2`, monitoruj `/var/log/auth.log`, `/var/log/pveproxy/access.log`, zmiany w `/etc/pve`.
- **Zabbix** – szablon *Proxmox VE by HTTP* korzysta z tokenu API z rolą `PVEAuditor`.
- Powiadomienia: *Datacenter → Notifications* – SMTP/Gotify/webhook dla błędów backupu, fencingu, aktualizacji.
