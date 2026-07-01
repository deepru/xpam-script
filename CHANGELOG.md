# Changelog

## v1.3.7

### Compatibility

- Verified full compatibility with **Debian 13** and **Ubuntu 26.04** — fresh install, repair, `repair --full`, weekly maintenance and health checks all pass. OS checks no longer flag newer Ubuntu/Debian releases.

### Architecture cleanup

- Removed the legacy `vless_direct` profile; the server always runs VLESS behind HAProxy.
- Removed the legacy `alexbers` MTProto backend; MTProto runs only via 3x-ui MTG. The `<prefix>-tg` command was removed — the Telegram link is shown by `<prefix>-links --show-secrets`.
- Config imports from removed profiles/backends now fail fast with a clear message.

### New features

- `<prefix>-repair --full` restores the 3x-ui database (clients/inbounds/secrets) from the latest golden snapshot, with integrity check, explicit confirmation, pre-restore backup and health-gated auto-rollback.
- `<prefix>-repair` now also regenerates the nginx configuration (previously only HAProxy).
- New health check for memory pressure (available RAM / swap usage).

### Security

- Hardened the Telegram relay socket fallback (no world-writable fallback).

### Maintainer / infrastructure

- Added `make-release.sh` and CI to build/verify the release archive with the mandatory wrapper layout, guarding the packaging-regression class.
- Self-update now prunes old update work directories (keeps the newest 2) to avoid disk clutter over time.

## v1.3.6

### Compatibility and release hardening

- Hardened GitHub download paths in bootstrap and self-update with HTTP/1.1 retries/timeouts while keeping SHA256 verification mandatory.
- Hardened 3x-ui installer handling for current upstream behavior, including stable-release selection and `XUI_ENABLE_FAIL2BAN=false` guard.
- Added health/deep-health checks for unexpected upstream 3x-ui `3x-ipl` fail2ban files/jail.
- Added additional 3x-ui/Xray compatibility diagnostics: version visibility, generated config JSON/readability, SQLite journal mode, subscription/Managed Hosts sanity, and Telegram feature separation.
- Preferred `systemd-timesyncd` and avoided unnecessary public `ntp/ntpsec` UDP `:123` exposure in XPAM-managed runtime.
- Removed legacy WireGuard `workers=2` recommendation for current Xray/3x-ui builds.
- Kept VLESS/Telegram links unchanged across tested DoubleHop enable/disable scenarios.

## v1.3.5

### Compatibility hardening after 3x-ui v3.4.0

- Added XPAM-owned guard against upstream 3x-ui fail2ban/IP-limit auto-setup: `XUI_ENABLE_FAIL2BAN=false`.
- Added health/deep-health checks for unexpected upstream `3x-ipl` fail2ban files/jail.
- Hardened GitHub download paths with HTTP/1.1 retries/timeouts while keeping SHA256 verification mandatory.
- 3x-ui auto-install now selects the latest stable GitHub release and skips prereleases by default.
- Hardened bootstrap documentation for VPS networks with broken GitHub CDN edge routing.
- Added 3x-ui/Xray compatibility information to deep-health: version, generated config readability, SQLite journal mode, subscription/Managed Hosts sanity.
- Kept XPAM Telegram proxy / MTG, XPAM Telegram notifications, and upstream 3x-ui Telegram notifications clearly separated.
- Preferred `systemd-timesyncd` for local time sync and removed unnecessary public `ntp/ntpsec` server exposure during XPAM-managed installs.
- Removed legacy WireGuard `workers=2` recommendation for current Xray/3x-ui builds.

### Главное

- Добавлен новый основной интерфейс управления: `sudo <prefix>-xpam`.
- Обновлён fresh-install UX и убрана старая пользовательская схема профилей.
- VLESS настраивается через 3x-ui/Xray.
- Telegram proxy / MTG настраивается через 3x-ui.
- Данные подключения объединены в `sudo <prefix>-links` и `sudo <prefix>-links --show-secrets`.
- VLESS и Telegram links в полной выдаче берутся из текущей конфигурации 3x-ui.
- Добавлен DoubleHop Mode для Entry-сервера.
- Добавлены режимы DoubleHop: VLESS only, Telegram only, VLESS + Telegram.
- Добавлены small-VM оптимизации для слабых VPS.
- Добавлен safe self-update через GitHub Releases.
- Добавлены SHA256 verification, staging preflight, backup и rollback для обновлений.

### Health, repair и maintenance

- Health/deep-health учитывают актуальную Telegram proxy / MTG архитектуру.
- Repair и weekly maintenance не должны менять VLESS/Telegram links.
- Ручная смена Telegram proxy / MTG secret в 3x-ui не должна ломать health/deep-health/weekly; актуальная Telegram link должна отображаться через `sudo <prefix>-links --show-secrets`.
- Maintenance-сценарии проверены в direct/off и DoubleHop-сценариях.
- Сохранены journald/logrotate политики и backup retention для небольших VPS.

### DoubleHop Mode

- XPAM управляет DoubleHop только на Entry-сервере.
- Exit-сервер пользователь подготавливает отдельно.
- Для Exit используется VLESS-ссылка, которую пользователь вставляет в XPAM.
- Включение, изменение режима и выключение DoubleHop не меняют текущие Entry-side VLESS и Telegram links.

### Safe self-update

- Обновление запускается вручную из XPAM-меню.
- Архив обновления проверяется по SHA256 до применения.
- Static preflight выполняется до mutation.
- Перед применением создаётся backup runtime и служебных команд.
- При ошибке post-update проверки выполняется rollback.
- Секреты не должны печататься в update logs.

### Проверка

Проверено на Ubuntu и Debian: установка, управление сервером, VLESS, Telegram proxy / MTG, DoubleHop Mode, диагностика, восстановление и безопасное обновление.

## v1.3.0

- Добавлена стабильная IPv4-first установка для Ubuntu и Debian.
- Улучшена интеграция 3x-ui/Xray, nginx, HAProxy, Certbot, firewall, fail2ban и health-checks.
- Добавлены production cleanup и базовые maintenance-сценарии.

## v1.2.0

- Добавлены installer, runtime scripts, templates, документация и site assets.
- Добавлены SSH hardening, UFW, fail2ban, nginx, Certbot, HAProxy, 3x-ui, Xray/VLESS и Telegram-related automation.
