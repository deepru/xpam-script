# Changelog

## v1.0.9 - Documentation / publication polish

- README.md is now Russian-first for the main GitHub project page.
- Previous English README content is preserved as README_EN.md.
- User-facing documentation references were updated for the final public release line.
- USER_GUIDE_RU.docx and USER_GUIDE_RU.pdf were regenerated with the current release version.
- No changes to the runtime deployment scheme, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy, or network tuning logic.
- v1.0.8 final cleanup behavior is retained.


## v1.0.8 — final cleanup polish

## v1.0.9 - Documentation / publication polish

- README.md is now Russian-first for the main GitHub project page.
- Previous English README content is preserved as README_EN.md.
- User-facing documentation references were updated for the final public release line.
- USER_GUIDE_RU.docx and USER_GUIDE_RU.pdf were regenerated with the current release version.
- No changes to the runtime deployment scheme, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy, or network tuning logic.
- v1.0.8 final cleanup behavior is retained.


### Changed

## v1.0.9 - Documentation / publication polish

- README.md is now Russian-first for the main GitHub project page.
- Previous English README content is preserved as README_EN.md.
- User-facing documentation references were updated for the final public release line.
- USER_GUIDE_RU.docx and USER_GUIDE_RU.pdf were regenerated with the current release version.
- No changes to the runtime deployment scheme, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy, or network tuning logic.
- v1.0.8 final cleanup behavior is retained.


- Final production cleanup now removes GitHub bootstrap and extracted installer leftovers from `/root`.
- Delayed cleanup protection now also covers `/root/xpam-install` and `/root/xpam-release-build` if any shell is still standing inside those directories.
- Bootstrap default version now points to `v1.0.8`.

### Verified

## v1.0.9 - Documentation / publication polish

- README.md is now Russian-first for the main GitHub project page.
- Previous English README content is preserved as README_EN.md.
- User-facing documentation references were updated for the final public release line.
- USER_GUIDE_RU.docx and USER_GUIDE_RU.pdf were regenerated with the current release version.
- No changes to the runtime deployment scheme, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy, or network tuning logic.
- v1.0.8 final cleanup behavior is retained.


- The cleanup change is limited to final production cleanup and does not alter health-check, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS or network-tuning logic.

## v1.0.7 — public GitHub-ready baseline

## v1.0.9 - Documentation / publication polish

- README.md is now Russian-first for the main GitHub project page.
- Previous English README content is preserved as README_EN.md.
- User-facing documentation references were updated for the final public release line.
- USER_GUIDE_RU.docx and USER_GUIDE_RU.pdf were regenerated with the current release version.
- No changes to the runtime deployment scheme, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy, or network tuning logic.
- v1.0.8 final cleanup behavior is retained.


### Added

## v1.0.9 - Documentation / publication polish

- README.md is now Russian-first for the main GitHub project page.
- Previous English README content is preserved as README_EN.md.
- User-facing documentation references were updated for the final public release line.
- USER_GUIDE_RU.docx and USER_GUIDE_RU.pdf were regenerated with the current release version.
- No changes to the runtime deployment scheme, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy, or network tuning logic.
- v1.0.8 final cleanup behavior is retained.


- GitHub-ready documentation set.
- Bootstrap installer template for GitHub Releases.
- Failed systemd units validation in health checks.
- Final failed systemd units validation in weekly maintenance.
- Clear third-party component notice.
- Security reporting and redaction guidance.
- Technical architecture documentation.

### Changed

## v1.0.9 - Documentation / publication polish

- README.md is now Russian-first for the main GitHub project page.
- Previous English README content is preserved as README_EN.md.
- User-facing documentation references were updated for the final public release line.
- USER_GUIDE_RU.docx and USER_GUIDE_RU.pdf were regenerated with the current release version.
- No changes to the runtime deployment scheme, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy, or network tuning logic.
- v1.0.8 final cleanup behavior is retained.


- Default 3x-ui username is `vlessuser`.
- User-facing output no longer promotes the weekly maintenance command as a normal user command.
- Health output is cleaner and explicitly reports failed systemd units.
- README rewritten for technical GitHub audience.

### Verified

## v1.0.9 - Documentation / publication polish

- README.md is now Russian-first for the main GitHub project page.
- Previous English README content is preserved as README_EN.md.
- User-facing documentation references were updated for the final public release line.
- USER_GUIDE_RU.docx and USER_GUIDE_RU.pdf were regenerated with the current release version.
- No changes to the runtime deployment scheme, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy, or network tuning logic.
- v1.0.8 final cleanup behavior is retained.


- Ubuntu 24.04 LTS baseline installation.
- Debian 12 baseline installation.
- VLESS connectivity.
- MTProto connectivity.
- Static website surface.
- Health check.
- Weekly maintenance.
- SHA256 release archive verification.

### Notes

## v1.0.9 - Documentation / publication polish

- README.md is now Russian-first for the main GitHub project page.
- Previous English README content is preserved as README_EN.md.
- User-facing documentation references were updated for the final public release line.
- USER_GUIDE_RU.docx and USER_GUIDE_RU.pdf were regenerated with the current release version.
- No changes to the runtime deployment scheme, health checks, weekly maintenance, nginx, HAProxy, Xray, 3x-ui, MTProto, DNS policy, or network tuning logic.
- v1.0.8 final cleanup behavior is retained.


- 3x-ui remains downloaded from upstream.
- alexbers/mtprotoproxy remains cloned from upstream.
- XPAM Script is an automation/configuration/hardening wrapper, not a fork of those projects.
