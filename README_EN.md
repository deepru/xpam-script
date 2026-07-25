# XPAM Script

[![License: MIT](https://img.shields.io/github/license/deepru/xpam-script?color=blue)](LICENSE)
[![Release](https://img.shields.io/github/v/release/deepru/xpam-script?sort=semver)](https://github.com/deepru/xpam-script/releases/latest)
[![CI](https://github.com/deepru/xpam-script/actions/workflows/ci.yml/badge.svg)](https://github.com/deepru/xpam-script/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/Ubuntu%20%C2%B7%20Debian-informational)](docs/INSTALLATION.md)

[Русский](README.md) · **English**

> Turns a clean VPS into a private HTTPS setup: **VLESS** and **Telegram proxy (MTG)** behind a single `443` port, with a real TLS certificate and decoy websites.

Everything normally done by hand is handled for you: 3x-ui/Xray, nginx, HAProxy, Certbot, UFW, fail2ban, SSH hardening, health checks, weekly maintenance and safe self-update. After installation everything is managed by one command, `sudo <prefix>-xpam`.

> [!WARNING]
> The script changes SSH, the firewall, nginx, HAProxy, 3x-ui/Xray, Certbot, fail2ban, systemd units, `/etc/hosts` and network parameters. Run it **on a clean VPS**, not on a server that already hosts your services.

## Features

| | |
|---|---|
| 🔐 **VLESS + Telegram proxy** | Both behind one HTTPS front on `443/tcp` — no separate "suspicious" ports |
| 🎭 **Smart masking** | Every domain gets its own believable website, unique to each installation. You can serve your own real site instead |
| 🔁 **Spare transport** | A second way in (xhttp/grpc) on its own domain, for when the primary one gets blocked |
| 🔀 **DoubleHop** | Route VLESS and/or Telegram traffic through a second server |
| ⚙️ **WARP** | Automatic registration and selective routing — not a system-wide VPN |
| 🛡️ **Hardening** | SSH keys only, UFW, fail2ban, panel behind a secret path and Basic Auth |
| ❤️ **Checks and repair** | Quick and deep diagnostics, runtime and 3x-ui database restore with automatic rollback |
| ⬆️ **Updates** | Checksum verification, backup, post-update health check, rollback on failure |

## How it works

Only one working port is exposed — ordinary HTTPS. Requests are routed by domain name:

```text
Internet :443 (HTTPS)
      │
      ├─ VLESS domain     →  Xray / VLESS
      ├─ Telegram domain  →  Telegram proxy (MTG)
      ├─ spare domain     →  spare transport (when enabled)
      └─ anything else    →  an ordinary website (masking)
```

That is why the server looks like a normal web server from the outside: opening a domain in a browser shows a real page, not a blank technical response.

## Quick start

You will need: a clean VPS running **Ubuntu** or **Debian** with root access, domains for VLESS, Telegram proxy and the panel with **A records** pointing at the server's IPv4, open ports `22`, `80`, `443`, and an **SSH key** — password login is disabled at the very first step.

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

Bootstrap downloads the published archive from GitHub Releases, verifies its SHA256 and starts the installer. Two menu entries follow: SSH security first, then the server setup. Once the server is installed they disappear and the operational menu takes their place.

> [!TIP]
> The full step-by-step guide is in Russian: **[Руководство пользователя](docs/USER_GUIDE_RU.md)**. The English docs under [`docs/`](docs/README.md) cover the same operational model in shorter form.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) · [Installation](docs/INSTALLATION.md) · [Configuration and commands](docs/CONFIGURATION.md)
- [Health checks](docs/HEALTHCHECKS.md) · [Maintenance](docs/MAINTENANCE.md) · [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Masking sites](docs/SITES.md) · [WARP](docs/WARP.md) · [Telegram notifications](docs/TELEGRAM_NOTIFICATIONS.md)
- [Security model](docs/SECURITY_MODEL.md) · [Changelog](CHANGELOG.md) · [Releases](https://github.com/deepru/xpam-script/releases)

## License

MIT License. 3x-ui, Xray-core, mtg, nginx, HAProxy, Certbot, UFW, fail2ban, systemd and other components keep their own licenses — see [THIRD_PARTY.md](THIRD_PARTY.md).
