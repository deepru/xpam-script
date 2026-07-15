# Third-party components

XPAM Script is a Bash automation and configuration wrapper. It **installs,
configures and verifies** several third-party components, but it does **not**
vendor their source code into this repository and does **not** claim ownership
of them. Each component keeps its own license, authorship and upstream support.

## Components used

| Component | Upstream project | License | Role in XPAM |
|---|---|---|---|
| **3x-ui** | [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) | [GPL-3.0](https://github.com/MHSanaei/3x-ui/blob/main/LICENSE) | Web panel and management layer for Xray |
| **Xray-core** | [XTLS/Xray-core](https://github.com/XTLS/Xray-core) | [MPL-2.0](https://github.com/XTLS/Xray-core/blob/main/LICENSE) | VLESS and routing engine |
| **nginx** | [nginx.org](https://nginx.org/) | [BSD-2-Clause](https://nginx.org/LICENSE) | Local web server, masking and fallback sites |
| **HAProxy** | [haproxy.org](https://www.haproxy.org/) | [GPL-2.0](https://github.com/haproxy/haproxy/blob/master/LICENSE) | Public HTTPS/TLS routing on `:443` |
| **Certbot** | [certbot/certbot](https://github.com/certbot/certbot) | [Apache-2.0](https://github.com/certbot/certbot/blob/main/LICENSE.txt) | TLS certificate issuance and renewal |
| **Let's Encrypt** | [letsencrypt.org](https://letsencrypt.org/) | — (certificate authority) | Free TLS certificates |
| **fail2ban** | [fail2ban/fail2ban](https://github.com/fail2ban/fail2ban) | [GPL-2.0](https://github.com/fail2ban/fail2ban/blob/master/COPYING) | SSH brute-force protection |
| **UFW** | [Uncomplicated Firewall](https://launchpad.net/ufw) | GPL-3.0 | Firewall policy |
| **systemd** | [systemd/systemd](https://github.com/systemd/systemd) | [LGPL-2.1+](https://github.com/systemd/systemd/blob/main/LICENSE.LGPL2.1) | Service management |
| **WireGuard / Cloudflare WARP** | [wireguard.com](https://www.wireguard.com/) · [Cloudflare WARP](https://developers.cloudflare.com/warp-client/) | GPL-2.0 / proprietary | Optional WARP outbound through Xray |

## 3x-ui and Xray-core

XPAM installs and configures [3x-ui](https://github.com/MHSanaei/3x-ui) and
[Xray-core](https://github.com/XTLS/Xray-core) as part of the server setup. XPAM
does **not** vendor their source code; both are maintained by their upstream
projects and are downloaded from their official release channels during install.

## Components bundled by 3x-ui

XPAM installs **3x-ui**, which downloads and manages its own runtime components — notably
**Xray-core** and a **Telegram proxy / MTG sidecar**. XPAM does **not** vendor, pin or ship these
directly: their exact set, versions and licenses are chosen and maintained by 3x-ui upstream and
vary by 3x-ui release. XPAM's responsibility is the installation flow, configuration and
health/maintenance around 3x-ui; the bundled runtime components are 3x-ui's responsibility. Review
the upstream [3x-ui](https://github.com/MHSanaei/3x-ui) project for their exact composition and
licensing in a given release.

## System packages

XPAM uses packages from the target operating system repositories, including
nginx, HAProxy, Certbot, UFW, fail2ban and supporting utilities. Supported
target systems are **Ubuntu** and **Debian**.

## Licenses

XPAM Script itself is distributed under the [MIT License](LICENSE). The
third-party projects listed above use their own licenses — always review the
upstream project for the exact, current license terms.
