# XPAM Script v1.1.0

XPAM Script v1.1.0 — крупный стабильный релиз для Ubuntu 24.04 LTS и Debian 12.

Главная цель релиза: сделать установку и эксплуатацию XPAM Script предсказуемой на реальных VPS от разных провайдеров, без ручных костылей после установки.

Релиз сохраняет проверенную архитектуру XPAM Script: VLESS / 3x-ui / Xray, MTProto, HAProxy SNI routing, nginx fallback, Certbot, SSH hardening, health-check, weekly maintenance, Telegram-уведомления и WARP через Xray outbound.

## Быстрая установка

Установка выполняется через GitHub bootstrap:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

После первого этапа скрипт создаёт prefix-команду вида:

```bash
sudo <prefix>-install
```

`<prefix>` — это имя, которое пользователь сам задаёт на шаге 0.

## Что изменено в v1.1.0

### DNS и Debian 12

- XPAM Script теперь работает в safe DNS mode.
- Если DNS провайдера работает, скрипт его не переписывает.
- Debian 12 minimal/provider images поддерживаются стабильнее.
- Отсутствие `systemd-resolved` на Debian не считается ошибкой само по себе.
- DNS проверяется через доступные системные механизмы и health-check.

### SSH, IPv4 и /etc/hosts

- Сохраняется IPv4-first схема: публично используются TCP-порты 22, 80 и 443.
- XPAM Script не создаёт публичные IPv6 TCP-правила для 22/80/443.
- Исправлена ситуация, когда провайдер задаёт hostname сервера, но не добавляет его в `/etc/hosts`, из-за чего `sudo` пишет `unable to resolve host`.
- Управляемые домены XPAM не привязываются к `127.0.0.1` или `127.0.1.1`.

### fail2ban

- fail2ban переведён на systemd backend.
- На Debian устанавливается необходимый пакет `python3-systemd`.
- Проверка fail2ban стала стабильнее на Debian 12 и Ubuntu 24.04.

### Безопасный вывод секретов

Команды подключения теперь безопасны по умолчанию:

- `sudo <prefix>-links`
- `sudo <prefix>-vless`
- `sudo <prefix>-telega`

Они не печатают VLESS-ссылки, MTProto-ссылки, пароли, токены и приватные данные без явного запроса.

Для осознанного вывода используются отдельные команды:

- `sudo <prefix>-links --show-secrets`
- `sudo <prefix>-vless --show`
- `sudo <prefix>-telega --show`
- `sudo <prefix>-telega --manage`

### Диагностика и восстановление

Добавлены команды:

- `sudo <prefix>-netdiag` — диагностика сети, DNS, маршрутов и provider-specific особенностей без автоматического ремонта.
- `sudo <prefix>-repair` — восстановление XPAM service policy, helper-команд, health/weekly scripts, limits, hooks и service hygiene.

### WARP через 3x-ui/Xray

- WARP остаётся опциональным outbound внутри Xray.
- XPAM Script не ставит системный `warp-cli` и не переводит весь сервер через WARP.
- Health-check проверяет техническую форму WireGuard outbound: `tag=warp`, `mtu=1420`, IPv4-only address, `ForceIPv4`, `workers=2`, `keepAlive=25`, `noKernelTun=false`.
- Пользовательские routing rules остаются пользовательскими и не переписываются.

### Telegram-уведомления и HTTPS Relay

- Поддерживаются Direct Telegram alerts, Relay server и Relay client.
- Relay использует существующую HTTPS/443 поверхность и не требует отдельного публичного порта.
- Уведомления предназначены для weekly/health проблем и ситуации, когда серверу нужна ручная перезагрузка.

### Production cleanup

- Финальная очистка удаляет установочные архивы, `.sha256`, распакованные временные папки, debug/test-файлы и пустые служебные root-папки.
- Скрипт сохраняет `/root/secure-notes`, `/root/config-backups`, `/root/manual-backups`, `/root/.ssh` и рабочий runtime.

## Что не менялось

- Публичная схема портов остаётся 22/80/443.
- VLESS продолжает работать через Xray и 3x-ui.
- MTProto в MTProto-профилях маршрутизируется через HAProxy по SNI.
- Сертификаты выпускает Certbot / Let's Encrypt.
- 3x-ui остаётся upstream-компонентом, XPAM Script только настраивает его в рамках общей серверной схемы.
- WARP не становится системным VPN сервера.

## Что делает XPAM Script

XPAM Script готовит чистый VPS под аккуратную HTTPS-поверхность:

- SSH hardening;
- UFW policy;
- fail2ban;
- nginx;
- HAProxy;
- Certbot;
- 3x-ui / Xray / VLESS;
- MTProto proxy;
- Telegram notifications / HTTPS Relay;
- WARP через Xray outbound;
- health-check;
- weekly maintenance;
- production cleanup;
- пользовательские prefix-команды управления.

Снаружи сервер выглядит как обычный HTTPS-сервер с публичными портами 22, 80 и 443, а служебные backend-порты остаются на loopback.

## Документация

В релиз добавлена обновлённая русская инструкция:

- `docs/USER_GUIDE_RU.pdf`
- `docs/USER_GUIDE_RU.docx`

Инструкция ведёт пользователя от покупки VPS, подготовки DNS и SSH-ключа до установки, проверки, настройки VLESS, MTProto, Telegram, WARP, сайтов и финальной production-очистки.

## Release assets

- `xpam-script-v1.1.0-ubuntu24-debian12.tar.gz`
- `xpam-script-v1.1.0-ubuntu24-debian12.tar.gz.sha256`

## Проверенный статус

Релиз проверен на чистых установках:

- Ubuntu 24.04 LTS
- Debian 12

Проверены установка, SSH hardening, DNS safe mode, fail2ban, UFW, nginx, HAProxy, 3x-ui/Xray, VLESS, MTProto, Certbot, Telegram Relay, WARP, health, deep health, weekly maintenance, cleanup и безопасный вывод пользовательских команд.
