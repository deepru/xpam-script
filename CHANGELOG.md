# Changelog

## v1.2.0 - 3x-ui compatibility, SQLite contract and diagnostics release

- Added an explicit 3x-ui SQLite-only compatibility contract. XPAM Script supports 3x-ui through `/etc/x-ui/x-ui.db`; PostgreSQL backend is detected and rejected safely in install, health and repair flows.
- Added 3x-ui backend/schema guards so health and repair report unsupported backend state clearly instead of producing misleading SQLite/inbound errors.
- Improved 3x-ui External Proxy consistency for XPAM-managed VLESS inbounds so generated VLESS links point to the public domain and port.
- The MTProto user command is now `<prefix>-tg`; no backward-compatible legacy launcher is created.
- Changed the default XPAM-managed VLESS inbound remark to `<prefix>-vless`; legacy XPAM remarks are still recognized.
- Made VLESS health, repair and link output tolerant of user-managed inbound names, client names and valid custom uTLS fingerprints.
- Changed the default uTLS fingerprint for XPAM-created VLESS inbounds to `firefox`.
- Added clearer network tuning diagnostics and repair handling for `net.ipv4.tcp_syncookies` runtime drift, missing policy, broken policy, later sysctl override and unsupported provider/kernel behavior.
- Improved provider-image compatibility for no-op `rc-local.service`, Debian UFW oneshot behavior and reboot decisions when the running kernel differs from the newest installed kernel.
- Improved WARP diagnostics: XPAM preserves WARP reserved bytes when present, warns when Cloudflare WARP reserved bytes are missing, does not generate them automatically, and keeps WARP as an Xray outbound rather than a system VPN.
- Improved WARP UX: fixed panel URL rendering, added a warning before restarting 3x-ui/Xray, softened Xray/WARP UDP listener reporting when UFW does not allow public UDP, and moved install logs out of `/root`.
- Cleaned documentation structure: accumulated changes are in `CHANGELOG.md`, current verification is in `TESTING.md`, security policy is in `SECURITY.md`, and detailed per-release notes belong in GitHub Releases.

## v1.1.1 - Direct VLESS IPv4 bind hotfix

- Fixed direct VLESS profile behavior on provider images where Xray could expose public 443 through an IPv6 wildcard / dual-stack socket instead of a real IPv4 listener.
- Direct VLESS now binds the public inbound to the detected public IPv4 address.
- Repair can normalize an existing XPAM-managed direct VLESS inbound without changing UUIDs, clients, TLS certificates, fallback, WARP, Telegram Relay, nginx, HAProxy or MTProto settings.
- Health/deep-health now treats public IPv6 listeners on XPAM-managed public ports 22/80/443 as FAIL and checks direct VLESS TLS against the detected public IPv4 address.
- HAProxy/MTProto routing remains unchanged: HAProxy owns public IPv4 443 and Xray/MTProto/nginx backends remain loopback-only.
- External Proxy is normalized for XPAM-managed VLESS inbounds in all profiles so 3x-ui generated links consistently use the public domain and port.

## v1.1.0 - Stability, Debian compatibility, safe UX and cleanup release

- Added stable IPv4-first installation flow for Ubuntu 24.04 and Debian 12.
- Removed the old interactive public IPv6/TLS prompt from the supported installation path.
- DNS handling now uses safe mode: working provider DNS is accepted and not rewritten.
- Debian 12 compatibility was improved for provider images without systemd-resolved.
- fail2ban now uses the systemd backend with python3-systemd on Debian and Ubuntu.
- SSH hardening now normalizes hostname resolution in `/etc/hosts` to avoid sudo hostname warnings without mapping managed domains to localhost.
- Ubuntu ssh.socket public listener is normalized to IPv4-only while IPv6 is not globally disabled.
- Public firewall policy remains 22/80/443 over IPv4; internal service ports remain on `127.0.0.1`.
- Connection commands are safer by default: `<prefix>-links`, `<prefix>-vless` and the MTProto command no longer print secrets unless explicitly requested.
- Added `<prefix>-netdiag` for network/DNS diagnostics and `<prefix>-repair` for restoring XPAM service policy.
- WARP through 3x-ui/Xray was polished and health now validates the safe technical form of the WARP outbound.
- Production cleanup removes installer archives, sha256 files, extracted folders, test logs and empty root-side cache folders while preserving secure-notes, config backups, manual backups and SSH keys.
- Russian user guide was fully updated.

## v1.0.9 - Documentation / publication polish

- README.md became the Russian-first main GitHub project page.
- Previous English technical README content was preserved as README_EN.md.
- User-facing documentation references were updated for the public release line.
- USER_GUIDE_RU.docx and USER_GUIDE_RU.pdf were regenerated with the current release version.
- Runtime deployment logic, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy and network tuning logic were not changed.
- v1.0.8 final cleanup behavior was retained.

## v1.0.8 - Final cleanup polish

- Final production cleanup removes GitHub bootstrap and extracted installer leftovers from `/root`.
- Delayed cleanup protection covers install/build directories if a shell is still standing inside them.
- Bootstrap default version was updated.
- The cleanup change was limited to final production cleanup and did not alter health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy or network tuning logic.

## v1.0.7 - Public GitHub-ready baseline

- Added GitHub-ready documentation set.
- Added bootstrap installer template for GitHub Releases.
- Added release process documentation.
- Added publication audit notes.
- Added GitHub issue template and pull request template.
- Updated release archive naming and references for GitHub distribution.
- Verified public bootstrap flow through GitHub Releases.

## v1.0.6 - Initial public release line

- Prepared the initial public project structure.
- Added installer, runtime scripts, templates, documentation and site assets.
- Added support for Ubuntu 24.04 LTS and Debian 12.
- Added SSH hardening, UFW, fail2ban, nginx, Certbot, HAProxy, 3x-ui, Xray/VLESS and MTProto automation.
- Added health checks, weekly maintenance, DNS policy and network tuning logic.
- Added Russian user guide and public project documentation.
