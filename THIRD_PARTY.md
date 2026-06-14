# Third-party components

XPAM Script is a Bash automation and configuration wrapper. It installs, configures and verifies several third-party components, but it does not claim ownership of them.

Each third-party component keeps its own license, authorship and upstream support model.

## Components

| Component | Role |
|---|---|
| 3x-ui | Web panel and management layer for Xray-based proxy configuration |
| Xray-core | VLESS and routing engine |
| nginx | Local web server and masking/fallback sites |
| HAProxy | Public HTTPS/TLS routing layer |
| Certbot / Let's Encrypt | TLS certificate issuance and renewal |
| UFW | Firewall policy |
| fail2ban | Basic SSH protection |
| systemd | Service management |
| Cloudflare WARP / WireGuard tooling | Optional WARP outbound through Xray |
| mtg by 9seconds | Indirect upstream component that may be used by 3x-ui for Telegram proxy / MTG support |

## 3x-ui and Xray-core

XPAM installs and configures 3x-ui/Xray as part of the server setup. XPAM does not vendor the 3x-ui or Xray-core source code into this repository.

3x-ui and Xray-core are maintained by their respective upstream projects.

## mtg by 9seconds

XPAM Script does not bundle, ship, or install `mtg` directly.

XPAM uses Telegram proxy / MTG functionality through 3x-ui. Depending on the 3x-ui version, this functionality may rely on the upstream `mtg` project by 9seconds.

- Project: `9seconds/mtg`
- License: MIT
- Role in XPAM: indirect upstream component used through 3x-ui's Telegram proxy / MTG integration
- XPAM responsibility: installation flow, configuration, health checks, maintenance checks, and user-facing integration around 3x-ui
- 3x-ui responsibility: bundled/runtime integration of Telegram proxy / MTG support

## System packages

XPAM uses packages from the target operating system repositories, including nginx, HAProxy, Certbot, UFW, fail2ban and supporting utilities.

Supported target systems for v1.3.5 are Ubuntu 24.04 LTS and Debian 12.

## Licenses

XPAM Script itself is distributed under the MIT License. Third-party projects may use different licenses. Review the upstream projects for their exact license terms.
