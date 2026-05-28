# XPAM Script

**XPAM Script** is a Bash automation, hardening and operations toolkit for preparing a clean **Ubuntu 24.04 LTS** or **Debian 12** VPS for an HTTPS/TLS service layout with VLESS, 3x-ui/Xray, optional MTProto, nginx, HAProxy, Certbot, UFW, fail2ban, health checks and regular maintenance.

Current public release: **v1.1.0**.

XPAM Script is not a fork of 3x-ui, Xray-core or MTProto proxy. It installs, configures, verifies and maintains upstream components.

> **Scope note**  
> XPAM Script does not promise anonymity, invulnerability or invisibility. Operators remain responsible for legal use, provider rules, DNS correctness and secret handling.

---

## What XPAM Script does

- enables SSH key-only access;
- normalizes hostname resolution in `/etc/hosts` when provider images break `sudo` hostname lookup;
- configures UFW and fail2ban;
- creates nginx websites and HTTPS service surface;
- obtains Let's Encrypt certificates through Certbot;
- installs 3x-ui and Xray/VLESS;
- optionally configures MTProto through HAProxy SNI routing;
- optionally configures Telegram notifications and HTTPS Relay;
- optionally validates WARP outbound inside 3x-ui/Xray;
- creates health, netdiag, repair and safe connection-data commands;
- removes installer leftovers through production cleanup.

---

## Supported profiles

| Profile | Purpose |
|---|---|
| `vless_direct` | VLESS/Xray and 3x-ui panel without MTProto and HAProxy |
| `subdomains_mtproto` | VLESS and MTProto on separate subdomains through HAProxy |
| `root_mtproto` | root website, `www` redirect, VLESS domain and MTProto domain |

---

## Ports

Public TCP ports:

```text
22/tcp   SSH
80/tcp   HTTP / ACME
443/tcp  HTTPS/TLS surface
```

Backend services listen on `127.0.0.1`: 3x-ui panel, Xray/VLESS, nginx fallback, nginx sync backend, MTProto proxy and internal service ports.

XPAM Script uses an IPv4-first deployment model. Create only `A` records for XPAM domains and remove `AAAA` records for those domains before installation.

---

## Installation

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

After the menu starts, first run step `0` for SSH security and command prefix creation, then run step `1` for installation.

---

## Main menu

```text
0) SSH security / create prefix command
1) Install / continue server setup
2) Show connection data
3) Check server health
4) Telegram notifications
5) WARP through 3x-ui/Xray
6) Website management
7) Advanced
8) Exit
```

---

## User commands

```text
sudo <prefix>-install       main menu
sudo <prefix>-health        quick server check
sudo <prefix>-health --deep deep diagnostics
sudo <prefix>-links         safe connection summary without secrets
sudo <prefix>-vless         VLESS information without printing the link
sudo <prefix>-telega        MTProto information without printing secrets
sudo <prefix>-netdiag       network/DNS diagnostics; does not repair automatically
sudo <prefix>-repair        restore XPAM service policy
```

Secrets are not printed by default. Explicit `--show` or `--show-secrets` options are used when the operator intentionally wants to display them.

---

## Documentation

- [`docs/USER_GUIDE_RU.pdf`](docs/USER_GUIDE_RU.pdf) — full Russian user guide.
- [`docs/USER_GUIDE_RU.docx`](docs/USER_GUIDE_RU.docx) — editable Russian user guide.
- [`docs/`](docs/) — technical documentation.

---

## License and third-party components

XPAM Script is distributed under the MIT License.

3x-ui, Xray-core, alexbers/mtprotoproxy, nginx, HAProxy, Certbot, UFW, fail2ban, systemd and other components keep their own licenses. See [`THIRD_PARTY.md`](THIRD_PARTY.md).
