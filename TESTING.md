# XPAM Script - current testing matrix

This file records the current verified status of the release archive. Detailed per-release notes are published in GitHub Releases.

## Current release

```text
XPAM Script v1.3.0
Archive: xpam-script-v1.3.0-ubuntu24-debian12.tar.gz
SHA256: 7efeb82fcc856c2ffb6155cbd94265d668944eb2e1c1ce87d98f06ad41e0987f
```


## Tested platforms and profiles

```text
Ubuntu 24.04 LTS / Profile 1 / VLESS only, direct TLS              PASS
Debian 12 / Profile 3 / root website + VLESS + MTProto             PASS
Debian 12 / Profile 2 / VLESS + MTProto, separate subdomains       PASS on the same code line before final packaging
```

Profile 1 covers the direct VLESS architecture. Profile 2 covers the separate-subdomain HAProxy/MTProto path. Profile 3 covers the full HAProxy/MTProto/root-site architecture and is the superset path for the HAProxy/MTProto profile family. Final post-build validation for archive SHA256 `7efeb82fcc856c2ffb6155cbd94265d668944eb2e1c1ce87d98f06ad41e0987f` was performed on Profile 1 and Profile 3.

## Verified scenarios

The current release line was checked through:

- clean install;
- reboot continuation when required;
- quick health;
- deep health;
- weekly maintenance;
- final production cleanup;
- `systemctl --failed = 0` / no failed systemd units;
- IPv4 listener policy;
- absence of public IPv6 listener on XPAM-managed public TCP ports `22/80/443`;
- direct VLESS public IPv4 bind;
- HAProxy + Xray local backend profile;
- HAProxy + MTProto startup ordering;
- MTProto TLS-only configuration and local mask backend checks;
- MTProto command and user management through `<prefix>-tg`, with no legacy MTProto launcher left behind;
- VLESS link output and manual VLESS connection;
- MTProto link output and manual MTProto connection on desktop and mobile clients;
- Telegram direct notifications;
- Telegram HTTPS Relay server mode;
- Relay endpoint behavior without token and with unsupported HTTP method;
- 3x-ui SQLite backend guard;
- 3x-ui API token storage and Bearer validation;
- 3x-ui External Proxy consistency;
- compact quick health output and full deep-health diagnostics;
- Debian provider quirks: missing `systemd-resolved`, no-op `rc-local.service` and UFW oneshot behavior;
- WARP through 3x-ui/Xray as an Xray outbound;
- WARP normalize flow for XPAM-managed WARP state;
- WARP disable/reset for XPAM-managed WARP state;
- profile-specific sniffing baseline after WARP reset;
- WARP restart UX when SSH is connected through the same VLESS/Xray tunnel;
- runtime refresh through repair;
- final production cleanup and root-side log cleanup.

## Final validation summary

```text
Ubuntu 24.04 / Profile 1:
  PASS - clean install, 4-item Telegram menu without Relay-server mode, direct Telegram notifications, health, deep health, weekly maintenance, VLESS, panel/site access, WARP normalize/reset and direct-profile Route-only sniffing baseline.

Debian 12 / Profile 3:
  PASS - clean install, root/www site, VLESS, MTProto, HAProxy startup order, HTTPS Telegram Relay, TLS consistency, health, deep health, weekly maintenance, manual VLESS/MTProto checks and full HAProxy/MTProto baseline with sniffing OFF.

Debian 12 / Profile 2:
  PASS - validated on the same release code line before final packaging; this covered the separate-subdomain HAProxy/MTProto profile without the root/www site layer.
```

## Public IPv4-only policy

XPAM-managed public services use IPv4 for public TCP ports `22/80/443`. IPv6 may remain enabled in the operating system for local or internal use, but XPAM-managed public services must not listen publicly on `22/80/443` over IPv6.

## Notes

- `CHANGELOG.md` is the accumulated changelog.
- `SECURITY.md` describes the current support and reporting policy.
- `docs/USER_GUIDE_RU.pdf` and `docs/USER_GUIDE_RU.docx` are the user guide.
- GitHub Releases are the source for detailed release notes for specific published versions.
