# Third-party components

XPAM Script is a Bash automation, hardening, and configuration wrapper. It installs, configures, and verifies several third-party components, but it does not claim ownership of them.

This document describes the major third-party components used by XPAM Script.

> This file is informational and is not legal advice. Always verify upstream license terms before redistribution, modification, or commercial use.

---

## Runtime components

| Component | Upstream | Role | License / notice |
|---|---|---|---|
| 3x-ui | <https://github.com/MHSanaei/3x-ui> | Xray management panel | GPL-3.0 upstream |
| Xray-core | <https://github.com/XTLS/Xray-core> | VLESS runtime | MPL-2.0 upstream |
| alexbers/mtprotoproxy | <https://github.com/alexbers/mtprotoproxy> | MTProto proxy | MIT upstream |
| nginx | <https://nginx.org/> | HTTP/HTTPS sites, fallback, ACME, relay surface | nginx upstream license |
| HAProxy | <https://www.haproxy.org/> | TCP/SNI frontend | HAProxy upstream license |
| Certbot | <https://certbot.eff.org/> | Let’s Encrypt certificate automation | Certbot upstream license |
| Let’s Encrypt | <https://letsencrypt.org/> | Public CA service | Let’s Encrypt terms apply |
| UFW | <https://launchpad.net/ufw> | Firewall policy | Ubuntu/Canonical upstream package license |
| fail2ban | <https://github.com/fail2ban/fail2ban> | SSH brute-force baseline protection | fail2ban upstream license |
| systemd / systemd-resolved | <https://systemd.io/> | service management and DNS resolver policy | systemd upstream license |

---

## Install-time behavior

### 3x-ui

XPAM Script downloads 3x-ui from upstream during installation. It does not vendor the 3x-ui source code or release archives into this repository.

The script configures 3x-ui to:

- bind the web panel to loopback;
- use a configured web base path;
- use Let’s Encrypt certificates;
- create or validate a local Xray/VLESS inbound;
- disable the subscription listener;
- set External Proxy values when HAProxy is used.

### Xray-core

Xray-core is used through 3x-ui. XPAM Script configures the resulting Xray inbound and validates the generated runtime config.

### alexbers/mtprotoproxy

XPAM Script clones alexbers/mtprotoproxy from upstream during installation when an MTProto profile is selected. It writes a local `config.py`, systemd unit, user secrets, and operational checks.

### System packages

The project installs and configures system packages from the target OS repositories. Supported target systems are Ubuntu 24.04 LTS and Debian 12.

---

## Ownership statement

XPAM Script owns only its own automation code, templates, documentation, and integration logic.

The names of third-party projects belong to their respective owners.
