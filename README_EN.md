# XPAM Script

**XPAM Script** is a Bash automation tool for deploying a private HTTPS/TLS VPS setup on a clean server.

It configures **VLESS**, **Telegram proxy / MTG**, 3x-ui/Xray, nginx, HAProxy, Certbot, firewall, fail2ban, health checks, maintenance scripts, WARP via Xray, **DoubleHop Mode**, and safe XPAM self-update.

> XPAM Script changes SSH, firewall, nginx, HAProxy, 3x-ui/Xray, Certbot, fail2ban, systemd units, health/maintenance scripts, DNS checks, `/etc/hosts`, and VPS network settings. Use it on a clean VPS, not on a server that already hosts important services.

## Quick start

Prepare:

- a clean **Ubuntu 24.04 LTS** or **Debian 12** VPS;
- root SSH access;
- domains for VLESS, Telegram proxy / MTG, and the panel;
- DNS A records pointing to your server IPv4.

### Install through GitHub bootstrap

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

The bootstrap downloads the published archive from **GitHub Releases**, verifies SHA256, extracts XPAM Script, and starts the installer.

Run menu item `0` first to configure SSH safety and create the prefix command, then run item `1` to install the server.

```text
0) SSH security / create prefix command
1) Install / continue server setup
```

After step 0, the main management command is:

```bash
sudo <prefix>-xpam
```

For example, if prefix = `srv`:

```bash
sudo srv-xpam
```

## Documentation

Before installation, read the full user guide.

**Primary guide format:** [USER_GUIDE_RU.docx](docs/USER_GUIDE_RU.docx)

**Downloadable PDF:** [USER_GUIDE_RU.pdf](https://github.com/deepru/xpam-script/raw/main/docs/USER_GUIDE_RU.pdf)

> If a browser PDF preview distorts Cyrillic text, use the DOCX guide or download the PDF and open it in Chrome, Adobe Reader, SumatraPDF, or another local PDF viewer.

Additional documents:

- [Release notes v1.3.5](RELEASE_NOTES_v1.3.5_RU.md)
- [GitHub Releases](https://github.com/deepru/xpam-script/releases)
- [CHANGELOG.md](CHANGELOG.md)
- [TESTING.md](TESTING.md)
- [SECURITY.md](SECURITY.md)
- [THIRD_PARTY.md](THIRD_PARTY.md)

## What XPAM Script provides

After installation, you get:

- SSH key based access;
- HTTPS/TLS entry surface on `443/tcp`;
- nginx + HAProxy + Certbot;
- 3x-ui/Xray with SQLite backend;
- VLESS on a dedicated domain;
- Telegram proxy / MTG on a dedicated domain;
- masking/fallback sites;
- health and deep-health diagnostics;
- repair command;
- weekly maintenance;
- WARP via 3x-ui/Xray as an optional outbound;
- DoubleHop Mode for VLESS and/or Telegram routing through the second XPAM server;
- safe user-initiated XPAM updates through the menu.

## Supported systems

Officially tested:

- Ubuntu 24.04 LTS
- Debian 12

A clean VPS with root access and IPv4 is recommended.

## Main commands

```bash
sudo <prefix>-xpam
sudo <prefix>-health
sudo <prefix>-health --deep
sudo <prefix>-links
sudo <prefix>-links --show-secrets
sudo <prefix>-vless
sudo <prefix>-repair
sudo <prefix>-netdiag
```

`sudo <prefix>-xpam` opens the main XPAM management menu.

## VLESS and Telegram links

Current connection data is shown with:

```bash
sudo <prefix>-links --show-secrets
```

VLESS links and the Telegram link are generated from the current **3x-ui** configuration. If you add/change a VLESS client or manually rotate the Telegram proxy / MTG secret in 3x-ui, run the links command again and use the updated output.

Do not publish `--show-secrets` output in chats, issues, screenshots, or public logs.

## DoubleHop Mode

DoubleHop Mode lets you use two XPAM servers: the main server keeps accepting the existing VLESS/Telegram links, while selected traffic exits through the second XPAM server.

Supported modes:

```text
VLESS only
Telegram only
VLESS + Telegram
```

How it works:

- install XPAM on both servers normally;
- on the second server, run `sudo <prefix>-links --show-secrets` and copy its VLESS link;
- on the main server, open `sudo <prefix>-xpam` → `DoubleHop Mode` and paste the second server VLESS link;
- the current VLESS and Telegram links of the main server do not change when DoubleHop is enabled, changed, or disabled.

## Safe update

XPAM supports user-initiated updates through the menu. The updater checks release metadata and SHA256, creates backup/snapshot, runs preflight, applies the new version, runs post-update health/deep-health, and rolls back on failure.

## License and third-party components

XPAM Script is distributed under the MIT License.

3x-ui, Xray-core, nginx, HAProxy, Certbot, UFW, fail2ban, systemd, and other components keep their own licenses. See [THIRD_PARTY.md](THIRD_PARTY.md).
