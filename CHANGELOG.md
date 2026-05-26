# Changelog

## v1.0.6 — public GitHub-ready baseline

### Added

- GitHub-ready documentation set.
- Bootstrap installer template for GitHub Releases.
- Failed systemd units validation in health checks.
- Final failed systemd units validation in weekly maintenance.
- Clear third-party component notice.
- Security reporting and redaction guidance.
- Technical architecture documentation.

### Changed

- Default 3x-ui username is `vlessuser`.
- User-facing output no longer promotes the weekly maintenance command as a normal user command.
- Health output is cleaner and explicitly reports failed systemd units.
- README rewritten for technical GitHub audience.

### Verified

- Ubuntu 24.04 LTS baseline installation.
- Debian 12 baseline installation.
- VLESS connectivity.
- MTProto connectivity.
- Static website surface.
- Health check.
- Weekly maintenance.
- SHA256 release archive verification.

### Notes

- 3x-ui remains downloaded from upstream.
- alexbers/mtprotoproxy remains cloned from upstream.
- XPAM Script is an automation/configuration/hardening wrapper, not a fork of those projects.
