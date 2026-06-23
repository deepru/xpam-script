# XPAM Script v1.3.6

**XPAM Script v1.3.6** — maintenance/hardening release поверх v1.3.5. Релиз не меняет пользовательскую архитектуру XPAM, но усиливает установку, обновление, совместимость с текущими версиями 3x-ui и диагностику.

Релиз ориентирован на чистые VPS с Ubuntu 24.04 LTS и Debian 12, а также на безопасное обновление уже установленных серверов v1.3.5 через XPAM updater.

## Главное в v1.3.6

- Добавлен более устойчивый GitHub download flow для bootstrap, updater и загрузки 3x-ui installer: HTTP/1.1, retries и временный CDN-edge fallback без постоянного `/etc/hosts`/DNS pin.
- SHA256-проверка архива остаётся обязательной перед установкой или обновлением.
- Установщик 3x-ui дополнительно защищён от upstream-изменений вокруг fail2ban/IP Limit: XPAM явно задаёт `XUI_ENABLE_FAIL2BAN=false`.
- Health/deep-health проверяют, что upstream `3x-ipl` fail2ban files/jail не появились и не перехватили XPAM-owned fail2ban policy.
- 3x-ui installer выбирает stable release и не должен использовать prerelease как обычный путь установки.
- Deep-health получил дополнительные compatibility checks: Xray version, generated config JSON/readability, SQLite journal mode, subscription/Managed Hosts sanity.
- Telegram proxy / MTG, XPAM Telegram notifications и upstream 3x-ui Telegram notifications остаются разделёнными сущностями и не смешиваются в UX/health.
- XPAM предпочитает `systemd-timesyncd` для локальной синхронизации времени и не должен оставлять публичный `ntp/ntpsec` UDP `:123` как часть XPAM-managed runtime.
- Убрана устаревшая рекомендация WireGuard `workers=2` для текущих Xray/3x-ui builds.

## Что не менялось

- Основной интерфейс управления остаётся `sudo <prefix>-xpam`.
- Команды ссылок остаются `sudo <prefix>-links` и `sudo <prefix>-links --show-secrets`.
- VLESS и Telegram links не должны меняться при обновлении с v1.3.5 на v1.3.6.
- DoubleHop Mode остаётся Entry-side функцией: XPAM принимает VLESS-ссылку Exit-сервера и не изменяет Exit-сервер.
- Exit-сервер по-прежнему подготавливается пользователем отдельно.
- XPAM не включает upstream 3x-ui Notification Event Bus, Managed Hosts, subscription listener или 3x-ui IP Limit как свои runtime-функции.

## Обновление с v1.3.5

Для уже установленных серверов v1.3.5 обновление должно выполняться через XPAM меню:

```bash
sudo <prefix>-xpam
```

Далее:

```text
8) Дополнительно
6) Проверить обновления XPAM
```

Updater должен:

1. обнаружить stable release v1.3.6;
2. скачать архив и `.sha256`;
3. проверить SHA256 до распаковки;
4. выполнить staging extract и static preflight;
5. создать backup текущей установки и служебных команд;
6. применить обновление;
7. выполнить health/deep-health postcheck;
8. выполнить rollback при ошибке.

Updater не должен печатать секреты в лог и не должен менять VLESS/Telegram links.

## Проверка релиза

Проверены ключевые сценарии XPAM v1.3.5/v1.3.6 hardening path:

- fresh install на Debian 12;
- `health` и `deep-health`;
- 3x-ui / Xray runtime;
- Telegram proxy / MTG через 3x-ui;
- 3x-ui fail2ban/IP Limit opt-out;
- GitHub/CDN download availability paths;
- DoubleHop Mode: VLESS only, Telegram only, VLESS + Telegram, disable/rollback;
- неизменность VLESS/Telegram links при DoubleHop operations.

## Секреты

Не публикуйте:

- VLESS links;
- Telegram links;
- Exit VLESS link для DoubleHop;
- UUID, tokens, private keys;
- вывод `sudo <prefix>-links --show-secrets`;
- содержимое `/etc/xpam-script/config.env`.
