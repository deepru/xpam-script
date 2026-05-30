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
sudo <prefix>-telega
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
- 3x-ui / Xray;
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

## Highlights

- Safe DNS behavior: working provider DNS is accepted and not rewritten.
- Improved Debian 12 minimal/provider VPS compatibility.
- Hostname and `/etc/hosts` normalization to avoid `sudo: unable to resolve host`.
- Safer connection commands: secrets are not printed by default.
- Added `<prefix>-netdiag` and `<prefix>-repair`.
- Improved WARP validation through 3x-ui/Xray.
- Stronger production cleanup.
- Updated Russian user guide.

## Documentation

- [Full Russian user guide, PDF](docs/USER_GUIDE_RU.pdf)
- [CHANGELOG.md](CHANGELOG.md)
- [TESTING.md](TESTING.md)
- [SECURITY.md](SECURITY.md)
- [GitHub Releases](https://github.com/deepru/xpam-script/releases)
- [`THIRD_PARTY.md`](THIRD_PARTY.md)
- [`SECURITY.md`](SECURITY.md)

## Tested status

```text
Ubuntu 24.04 LTS: PASS
Debian 12: PASS
GitHub Release assets: PASS
SHA256 verification: PASS
GitHub bootstrap path: PASS
```

See [`LICENSE`](LICENSE) and [`THIRD_PARTY.md`](THIRD_PARTY.md).
