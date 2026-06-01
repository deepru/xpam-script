# XPAM Script

**XPAM Script** is a Bash automation toolkit for preparing a clean Ubuntu 24.04 LTS or Debian 12 VPS with an IPv4-first HTTPS/TLS surface, VLESS, MTProto, masking sites, 3x-ui/Xray, HAProxy, nginx, Certbot, firewall policy, fail2ban, health checks, Telegram notifications, optional HTTPS Relay, optional WARP through Xray and final production cleanup.

Release archives are available in [GitHub Releases](https://github.com/deepru/xpam-script/releases).

> Before using XPAM Script, read the [full Russian user guide in PDF](docs/USER_GUIDE_RU.pdf).
>
> XPAM Script changes SSH, firewall, nginx, HAProxy, 3x-ui/Xray, MTProto, Certbot, fail2ban, systemd units, health/maintenance scripts, DNS checks, `/etc/hosts` and VPS networking-related policy. Use it on a clean VPS, not on a production server with existing important services.

## Quick install

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

First run step `0` to harden SSH and create the command prefix, then step `1` to install/configure the server.

Commands use the user-defined prefix:

```text
sudo <prefix>-install
sudo <prefix>-health
sudo <prefix>-links
sudo <prefix>-vless
sudo <prefix>-tg
sudo <prefix>-netdiag
sudo <prefix>-repair
```

## What XPAM Script configures

- SSH key-only access policy;
- UFW firewall policy;
- fail2ban with systemd backend;
- nginx;
- HAProxy TCP/SNI routing;
- Certbot / Let's Encrypt;
- 3x-ui / Xray with SQLite backend;
- VLESS over HTTPS/TLS;
- MTProto proxy;
- masking/fallback websites;
- Telegram notifications and optional HTTPS Relay;
- optional WARP as an Xray WireGuard outbound;
- quick and deep health checks;
- network diagnostics;
- repair helper;
- secure notes, backups and production cleanup.

Public exposure remains limited to IPv4 TCP 22/80/443. Backend services stay on loopback.

## Important compatibility notes

- XPAM Script supports 3x-ui only with SQLite backend at `/etc/x-ui/x-ui.db`.
- PostgreSQL backend is not supported by XPAM Script.
- MTProto user command is `sudo <prefix>-tg`.
- VLESS inbound created by XPAM Script is named `<prefix>-vless`.
- User-managed inbound/client names and valid uTLS fingerprints are tolerated by health, repair and VLESS link output.
- WARP is optional and remains an Xray outbound; XPAM Script does not install a system-wide VPN.

## Documentation

- [Full Russian user guide, PDF](docs/USER_GUIDE_RU.pdf)
- [Full Russian user guide, DOCX](docs/USER_GUIDE_RU.docx)
- [CHANGELOG.md](CHANGELOG.md)
- [TESTING.md](TESTING.md)
- [SECURITY.md](SECURITY.md)
- [THIRD_PARTY.md](THIRD_PARTY.md)
- [GitHub Releases](https://github.com/deepru/xpam-script/releases)

See [`LICENSE`](LICENSE) and [`THIRD_PARTY.md`](THIRD_PARTY.md).
