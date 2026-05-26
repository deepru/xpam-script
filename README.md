# XPAM Script

**XPAM Script** is a VPS automation, hardening, and service-integration toolkit for **Ubuntu 24.04 LTS** and **Debian 12**.

It prepares a clean VPS for a controlled HTTPS/TLS service surface built around:

- SSH key-only access;
- UFW and fail2ban baseline protection;
- nginx fallback websites;
- Let’s Encrypt certificates through Certbot;
- 3x-ui and Xray/VLESS;
- optional MTProto over a TLS/SNI-aware frontend;
- optional HAProxy TCP/SNI routing;
- optional WARP routing through 3x-ui/Xray;
- Telegram notification modes;
- health checks and weekly maintenance.

XPAM Script is not a fork of 3x-ui, Xray-core, or MTProto proxy. It is a Bash-based automation and configuration wrapper that installs, configures, verifies, and maintains a VPS built from upstream components.

> **Scope note**  
> This project describes the server-side automation and operational hardening. It does not promise anonymity, censorship resistance, or invisibility. Operators are responsible for complying with local law, provider terms, and acceptable-use policies.

---

## Current baseline

| Field | Value |
|---|---|
| Version | `1.0.6` |
| Supported OS | Ubuntu 24.04 LTS, Debian 12 |
| Shell | Bash |
| Privilege model | root-required installer |
| Public TCP ports | `22`, `80`, `443` |
| Main runtime path | `/opt/xpam-script` |
| Main config path | `/etc/xpam-script/config.env` |
| Sensitive notes | `/root/secure-notes` |
| Config backups | `/root/config-backups` |

---

## Design goals

XPAM Script is designed for operators who want a repeatable VPS baseline instead of a hand-built snowflake server.

The project focuses on:

1. **Deterministic setup**  
   One menu-driven flow creates the same service layout every time.

2. **Minimal public exposure**  
   Public access is limited to SSH, HTTP, and HTTPS/TLS. Backend services bind to loopback.

3. **HTTPS/TLS-compatible service surface**  
   Public domains serve normal websites, redirects, authentication-protected panel paths, and TLS/SNI-routed services.

4. **Operational safety**  
   Health checks validate real runtime state: services, ports, TLS certificates, DNS policy, firewall rules, startup ordering, network tuning, and maintenance results.

5. **Maintainability**  
   Weekly maintenance performs safe cleanup, guarded package upgrades, certificate renewal, health checks, and optional Telegram failure notification.

---

## Supported deployment profiles

XPAM Script supports three profiles.

| Profile | Public role | Internal role | HAProxy | MTProto |
|---|---|---|---|---|
| `vless_direct` | VLESS/Xray listens on public TLS port | nginx fallback website | No | No |
| `subdomains_mtproto` | HAProxy listens on `443` and routes by SNI | Xray/VLESS and MTProto bind to loopback | Yes | Yes |
| `root_mtproto` | root website + `www` redirect + VLESS domain + MTProto domain | Xray/VLESS, nginx fallback, MTProto bind to loopback | Yes | Yes |

Typical domain roles:

| Role | Example | Purpose |
|---|---|---|
| Root website | `example.com` | Normal public website surface |
| WWW alias | `www.example.com` | Redirect to root domain |
| VLESS / panel domain | `vless.example.com` | Xray/VLESS TLS endpoint and protected 3x-ui path |
| MTProto / sync domain | `tg.example.com` | MTProto SNI role and relay-compatible HTTPS surface |

All required domains must point to the VPS IPv4 address before certificate issuance.

---

## Network model

The public surface is intentionally small.

| Port | Scope | Purpose |
|---|---|---|
| `22/tcp` | Public | SSH |
| `80/tcp` | Public | HTTP redirect and ACME HTTP-01 |
| `443/tcp` | Public | HTTPS/TLS surface, Xray/VLESS, optional SNI routing |

In HAProxy profiles, backend ports are loopback-only:

| Service | Bind address | Purpose |
|---|---|---|
| 3x-ui panel | `127.0.0.1:<XUI_PANEL_PORT>` | local panel backend |
| Xray/VLESS | `127.0.0.1:<XRAY_LOCAL_PORT>` | local VLESS backend |
| nginx website | `127.0.0.1:<SITE_BACKEND_PORT>` | fallback/static website |
| nginx sync TLS backend | `127.0.0.1:<SYNC_BACKEND_PORT>` | MTProto/relay domain HTTPS surface |
| MTProto proxy | `127.0.0.1:<MTPROTO_PORT>` | local MTProto backend |

HAProxy performs TCP-level SNI routing. In MTProto profiles:

```text
SNI == MTProto domain  -> 127.0.0.1:<MTPROTO_PORT>
default                -> 127.0.0.1:<XRAY_LOCAL_PORT>
```

---

## Installation

### Recommended public installation model

For GitHub Releases, publish a release archive and a matching SHA256 file.

Expected release assets:

```text
xpam-script-v1.0.6-ubuntu24-debian12.tar.gz
xpam-script-v1.0.6-ubuntu24-debian12.tar.gz.sha256
```

Bootstrap usage:

```bash
curl -fsSL -o xpam-bootstrap.sh https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

The bootstrap installer:

1. installs minimal download/extract tools if needed;
2. downloads the release archive;
3. downloads the `.sha256` file;
4. verifies SHA256;
5. extracts the archive to `/root/xpam-install`;
6. finds `install.sh`;
7. starts the XPAM Script menu.

### Manual archive installation

```bash
cd /root

sha256sum -c xpam-script-v1.0.6-ubuntu24-debian12.tar.gz.sha256

rm -rf /root/xpam-install
mkdir -p /root/xpam-install

tar -xzf xpam-script-v1.0.6-ubuntu24-debian12.tar.gz -C /root/xpam-install

KIT_DIR="$(find /root/xpam-install -maxdepth 3 -type f -name install.sh -printf '%h\n' | head -n1)"
cd "$KIT_DIR"

bash ./install.sh
```

---

## Menu model

The installer is menu-driven.

```text
0) Configure SSH security
1) Install / continue server setup
2) Configure / verify Telegram notifications
3) WARP setup
4) Website management
5) Show connection data
6) Check server health
7) Final / production cleanup
8) Show current configuration
9) Exit
```

Important behavior:

- The command prefix is created during step `0`.
- After step `0`, the operator continues through `sudo <prefix>-install`.
- `<prefix>` is a placeholder. The operator chooses the actual prefix.
- The weekly maintenance command is internal and is not intended as a normal user command.

---

## User-facing commands

After installation, the operator normally uses only these commands:

| Command | Purpose |
|---|---|
| `sudo <prefix>-install` | open XPAM Script menu |
| `sudo <prefix>-health` | run full health check |
| `sudo <prefix>-links` | show connection data and generated links |
| `sudo <prefix>-vless` | show VLESS/panel data |
| `sudo <prefix>-telega` | manage MTProto users, when MTProto is enabled |

Sensitive data is stored under `/root/secure-notes`. Do not publish that directory.

---

## Main components

XPAM Script integrates upstream components:

| Component | Role |
|---|---|
| 3x-ui | Xray management panel |
| Xray-core | VLESS runtime |
| alexbers/mtprotoproxy | MTProto proxy implementation |
| nginx | static websites, HTTP/ACME, fallback, relay surface |
| HAProxy | TCP/SNI frontend in MTProto profiles |
| Certbot / Let’s Encrypt | TLS certificates |
| UFW | firewall policy |
| fail2ban | SSH brute-force baseline protection |
| systemd/systemd-resolved | service management and DNS policy |
| cron | weekly maintenance scheduling |

See [`THIRD_PARTY.md`](THIRD_PARTY.md) for license and upstream details.

---

## Documentation

Technical documentation is available in [`docs/`](docs/):

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/INSTALLATION.md`](docs/INSTALLATION.md)
- [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md)
- [`docs/PROFILES.md`](docs/PROFILES.md)
- [`docs/SECURITY_MODEL.md`](docs/SECURITY_MODEL.md)
- [`docs/HEALTHCHECKS.md`](docs/HEALTHCHECKS.md)
- [`docs/MAINTENANCE.md`](docs/MAINTENANCE.md)
- [`docs/TELEGRAM_NOTIFICATIONS.md`](docs/TELEGRAM_NOTIFICATIONS.md)
- [`docs/WARP.md`](docs/WARP.md)
- [`docs/SITES.md`](docs/SITES.md)
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)
- [`docs/RELEASE_PROCESS.md`](docs/RELEASE_PROCESS.md)

Russian user guide:

- [`docs/USER_GUIDE_RU.pdf`](docs/USER_GUIDE_RU.pdf)

---

## Security posture

XPAM Script intentionally changes the server baseline:

- SSH password login is disabled after key access is confirmed.
- X11 forwarding is disabled.
- SSH TCP forwarding remains allowed for operational use.
- UFW is reset and rebuilt.
- Only the expected public TCP ports are allowed.
- Backend ports are expected to be loopback-only.
- systemd service ordering is hardened for HAProxy/MTProto startup.
- MTProto secrets are kept out of recent journal output checks.
- Telegram, VLESS, MTProto and Relay credentials are treated as secrets.

Before opening an issue, redact:

```text
VLESS links
MTProto links
Telegram bot tokens
Relay tokens
WARP private keys
certificate private keys
/root/secure-notes/*
/etc/xpam-script/config.env
public IPs, if you do not want them public
real domains, if you do not want them public
```

See [`SECURITY.md`](SECURITY.md).

---

## License

XPAM Script is released under the MIT License. See [`LICENSE`](LICENSE).

Third-party components retain their own licenses. See [`THIRD_PARTY.md`](THIRD_PARTY.md).
