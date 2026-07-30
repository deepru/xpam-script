# Installation

XPAM Script is intended for clean VPS installations on Ubuntu and Debian.

## Requirements

- Clean VPS;
- root access;
- IPv4 address;
- DNS A records prepared for your XPAM domains;
- SSH key access is required — password login is disabled at the first step.

## Install from GitHub Releases

Bootstrap downloads the current release archive from GitHub Releases, verifies its SHA256, extracts it
and starts the installer:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

If the download fails because of a provider or GitHub network issue, retry later, or fetch
`bootstrap.sh` on another machine and upload it to the VPS by hand. The release archive itself is
still downloaded from GitHub Releases and checksum-verified before anything is installed.

Do not pin GitHub CDN addresses in `/etc/hosts` to work around this. XPAM falls back to a direct
address only for a failing download, and verifies the release checksum either way.

## First run

Installation runs as two menu items, in order:

```text
1) SSH-безопасность и создание команды сервера
2) Установить / продолжить настройку сервера
```

Item 2 runs twice, with a reboot in between: the first pass prepares the system and asks you to
reboot, the second pass finishes the setup. Once the server is fully installed, both entries
disappear and the same command shows the operational menu instead.

After the first item creates the prefix command, the menu is reached with:

```bash
sudo <prefix>-xpam
```

That stays the main management interface: connection data, health, notifications, WARP, DoubleHop,
sites and maintenance.

## Connection data

Summary without secrets:

```bash
sudo <prefix>-links --safe
```

Full connection data:

```bash
sudo <prefix>-links
```

The full output contains sensitive data — see [`SECURITY.md`](../SECURITY.md) before sharing it. VLESS
and Telegram links in this output are generated from the current 3x-ui configuration.

## Post-install validation

Run:

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
```

The server should pass both checks before you rely on it.

## Updating

Use XPAM safe self-update from the menu:

```bash
sudo <prefix>-xpam
```

Then open `Дополнительно` → `Проверить обновления XPAM`.

The updater verifies SHA256, performs preflight checks, creates a backup and rolls back if the updated server does not pass post-update checks.
