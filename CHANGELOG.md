# Changelog

## v1.0.10 - IPv4-first installer and user guide polish

- Removed the interactive IPv6 public TLS question from the installer.
- New installations now follow the already tested IPv4-first path that previously matched the default `no` answer.
- XPAM Script does not create public IPv6 inbound rules in the supported installation path.
- AAAA-record guidance is now explicit: XPAM Script domains should use A records only; AAAA records for those domains should be removed before installation.
- Russian user guide was updated with a clearer MobaXterm SSH-key workflow.
- Russian user guide layout was polished so major sections start on a new page and tables, code blocks and warning blocks are not split awkwardly.
- Runtime deployment logic, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui and MTProto behavior are unchanged except for removing the untested IPv6 prompt.

## v1.0.9 - Documentation / publication polish

- README.md became the Russian-first main GitHub project page.
- Previous English technical README content was preserved as README_EN.md.
- User-facing documentation references were updated for the public release line.
- USER_GUIDE_RU.docx and USER_GUIDE_RU.pdf were regenerated with the current release version.
- Runtime deployment logic, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy and network tuning logic were not changed.
- v1.0.8 final cleanup behavior was retained.

## v1.0.8 - Final cleanup polish

- Final production cleanup now removes GitHub bootstrap and extracted installer leftovers from /root.
- Delayed cleanup protection now also covers /root/xpam-install and /root/xpam-release-build if any shell is still standing inside those directories.
- Bootstrap default version was updated to v1.0.8.
- The cleanup change is limited to final production cleanup and does not alter health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy or network tuning logic.

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