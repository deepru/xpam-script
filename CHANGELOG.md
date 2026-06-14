# Changelog

## v1.3.5

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

Проверено на Ubuntu 24.04 LTS и Debian 12: установка, управление сервером, VLESS, Telegram proxy / MTG, DoubleHop Mode, диагностика, восстановление и безопасное обновление.

## v1.3.0

- Добавлена стабильная IPv4-first установка для Ubuntu 24.04 и Debian 12.
- Улучшена интеграция 3x-ui/Xray, nginx, HAProxy, Certbot, firewall, fail2ban и health-checks.
- Добавлены production cleanup и базовые maintenance-сценарии.

## v1.2.0

- Добавлены installer, runtime scripts, templates, документация и site assets.
- Добавлены SSH hardening, UFW, fail2ban, nginx, Certbot, HAProxy, 3x-ui, Xray/VLESS и Telegram-related automation.
