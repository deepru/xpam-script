# Installation

XPAM Script is intended for clean VPS installations on Ubuntu and Debian.

## Requirements

- Clean VPS;
- root access;
- IPv4 address;
- DNS A records prepared for your XPAM domains;
- SSH key access strongly recommended.

Use placeholders in examples:

```text
<server-ip>
vless.example.com
tg.example.com
panel.example.com
```

## Install from GitHub Releases

Use the current release archive and SHA256 file from GitHub Releases. The install flow should download the release archive, verify SHA256, extract it and start installation.

Follow the exact command block published in the GitHub release page for the current version. Current bootstrap download should use HTTP/1.1 and retries:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

If bootstrap download temporarily fails because of a provider or GitHub network issue, retry later or download `bootstrap.sh` locally and upload it to the VPS manually. XPAM still downloads the published archive from GitHub Releases and verifies SHA256 before installation.


Do not pin GitHub CDN IPs in `/etc/hosts`. XPAM uses temporary fallback only for the failing download and still verifies release SHA256.

## First run

After the initial bootstrap creates the prefix command, use:

```bash
sudo <prefix>-xpam
```

Typical first-run order:

```text
1) SSH-безопасность и создание команды сервера
2) Установить / продолжить настройку сервера
```

Once the server is fully installed those two entries disappear and the same command shows the
operational menu instead (connection data, health, notifications, WARP, DoubleHop, sites, advanced).
It stays the main management interface.

## Connection data

Summary without secrets:

```bash
sudo <prefix>-links --safe
```

Full connection data:

```bash
sudo <prefix>-links
```

The full output contains sensitive data. VLESS and Telegram links in this output are generated from the current 3x-ui configuration.

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
