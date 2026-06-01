# XPAM Script - current testing matrix

This file records the current verified status of the release archive. Detailed per-release notes are published in GitHub Releases.

## Tested platforms and profiles

```text
Ubuntu 24.04 LTS / Profile 1 / VLESS only, direct TLS              PASS
Debian 12 / Profile 2 / VLESS + MTProto, separate subdomains       PASS
Ubuntu 24.04 LTS / Profile 3 / root website + VLESS + MTProto      PASS
```

## Verified scenarios

The current release line was checked through:

- clean install;
- reboot continuation when required;
- quick health;
- deep health;
- weekly maintenance;
- repair followed by health;
- `systemctl --failed = 0`;
- IPv4 listener policy;
- absence of public IPv6 listener on XPAM-managed public TCP ports `22/80/443`;
- direct VLESS public IPv4 bind;
- HAProxy + Xray local backend profile;
- MTProto command and user management through `<prefix>-tg`, with no legacy MTProto launcher left behind;
- VLESS link output and manual VLESS connection;
- MTProto link output and manual MTProto connection;
- 3x-ui SQLite backend guard;
- PostgreSQL backend detection in health and repair;
- 3x-ui External Proxy consistency;
- custom VLESS inbound/client name tolerance;
- custom valid uTLS fingerprint tolerance;
- `tcp_syncookies` drift detection and repair;
- Debian provider quirks: no-op `rc-local.service` and UFW oneshot behavior;
- WARP through 3x-ui/Xray as an Xray outbound;
- WARP reserved-bytes warning when Cloudflare WARP profile lacks 3 reserved bytes;
- WARP restart UX when SSH is connected through the same VLESS/Xray tunnel;
- final production cleanup and root-side log cleanup.

## Public IPv4-only policy

XPAM-managed public services use IPv4 for public TCP ports `22/80/443`. IPv6 may remain enabled in the operating system for local or internal use, but XPAM-managed public services must not listen publicly on `22/80/443` over IPv6.

## Notes

- `CHANGELOG.md` is the accumulated changelog.
- `SECURITY.md` describes the current support and reporting policy.
- `docs/USER_GUIDE_RU.pdf` and `docs/USER_GUIDE_RU.docx` are the user guide.
- GitHub Releases are the source for detailed release notes for specific published versions.
