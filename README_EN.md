# XPAM Script

**XPAM Script** is a Bash automation project for preparing a clean VPS as a managed HTTPS/TLS proxy stack with **VLESS**, **Telegram proxy / MTG**, 3x-ui/Xray, nginx, HAProxy, Certbot, firewall, fail2ban, health checks, maintenance scripts, optional WARP outbound, **DoubleHop Mode**, and safe self-update.

The project is designed for the “clean VPS to ready-to-use managed server” workflow. It configures the system components around 3x-ui/Xray and provides a simple prefix-based CLI.

> XPAM Script changes SSH settings, firewall rules, nginx, HAProxy, 3x-ui/Xray, Certbot, fail2ban, systemd units, health/maintenance scripts and network-related settings. Use it on a clean VPS, not on a server that already hosts important services.

## v1.3.5 highlights

- main management command: `sudo <prefix>-xpam`;
- VLESS through 3x-ui/Xray;
- Telegram proxy / MTG through 3x-ui;
- connection data through `sudo <prefix>-links`;
- DoubleHop Mode: VLESS only, Telegram only, or VLESS + Telegram;
- optional WARP outbound through Xray;
- backend-aware health, repair and weekly maintenance;
- small-VPS optimizations;
- safe self-update with SHA256 verification, staging preflight, backup and rollback.

## Supported systems

XPAM Script v1.3.5 is intended for clean VPS installations on:

- Ubuntu 24.04 LTS;
- Debian 12.

Tested on Ubuntu 24.04 LTS and Debian 12: installation, server management, VLESS, Telegram proxy / MTG, DoubleHop Mode, diagnostics, repair and safe update.

## Main commands

```bash
sudo <prefix>-xpam                 # main XPAM menu
sudo <prefix>-links                # safe summary without secrets
sudo <prefix>-links --show-secrets # full connection data
sudo <prefix>-health               # quick health check
sudo <prefix>-health --deep        # extended health check
sudo <prefix>-vless                # VLESS information and actions
sudo <prefix>-repair               # repair XPAM runtime glue
sudo <prefix>-netdiag              # network diagnostics
```

`<prefix>` is selected during setup. For example, if the prefix is `my`, the main command is `sudo my-xpam`.

`sudo <prefix>-links --show-secrets` builds the current VLESS and Telegram links from the active 3x-ui configuration. If you add/remove VLESS clients or rotate the Telegram proxy / MTG secret in 3x-ui, run the command again and use the updated links from its output.

## DoubleHop Mode

DoubleHop Mode is configured on the Entry server only. The Exit server is prepared separately by the user, and XPAM uses a user-provided Exit VLESS link. Existing Entry-side VLESS and Telegram links remain unchanged when DoubleHop is enabled, changed or disabled.

## Secrets

Do not publish VLESS links, Telegram links, Exit VLESS links, UUIDs, tokens, private keys, `/etc/xpam-script/config.env`, or output from `sudo <prefix>-links --show-secrets`.

## Documentation

The primary documentation is in Russian:

- [`README_RU.md`](README_RU.md)
- [`docs/`](docs/)
- [`RELEASE_NOTES_v1.3.5_RU.md`](RELEASE_NOTES_v1.3.5_RU.md)
