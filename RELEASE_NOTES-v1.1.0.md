# XPAM Script v1.1.0

XPAM Script v1.1.0 — крупный стабильный релиз для Ubuntu 24.04 LTS и Debian 12.

Это не косметический апдейт. Релиз закрывает реальные проблемы и улучшает поведение на VPS-образах разных провайдеров: DNS, Debian 12, fail2ban, hostname/`/etc/hosts`, безопасный вывод секретов, WARP validation, Telegram Relay, health-check и production cleanup.

---

## Быстрая установка

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

После запуска сначала выберите:

```text
0) SSH-безопасность / создать prefix-команду
```

Затем:

```text
1) Установить / продолжить настройку сервера
```

Перед установкой обязательно прочитайте инструкцию:

- [Полная инструкция пользователя, PDF](https://github.com/deepru/xpam-script/blob/main/docs/USER_GUIDE_RU.pdf)
- [Редактируемая версия инструкции, DOCX](https://github.com/deepru/xpam-script/blob/main/docs/USER_GUIDE_RU.docx)

---

## Что делает XPAM Script

XPAM Script — это Bash-автоматизация для подготовки чистого VPS под управляемую HTTPS/TLS-схему.

Скрипт настраивает:

- SSH hardening;
- UFW firewall policy;
- fail2ban;
- nginx;
- HAProxy TCP/SNI routing;
- Certbot / Let's Encrypt;
- 3x-ui / Xray;
- VLESS;
- MTProto proxy;
- сайты-маскировки и fallback;
- Telegram-уведомления;
- HTTPS Relay для Telegram-уведомлений;
- WARP через Xray WireGuard outbound;
- health-check и deep diagnostics;
- network diagnostics;
- repair-команду;
- backups и secure-notes;
- production cleanup.

После установки сервер имеет IPv4-first публичную поверхность с портами 22/80/443, а backend-сервисы остаются на loopback.

---

## Что пользователь получает после установки

- Готовую серверную схему для VLESS через HTTPS/TLS.
- MTProto proxy через отдельный домен.
- 3x-ui panel через защищённый HTTPS path и Basic Auth.
- Основной сайт-маскировку и www redirect.
- Certbot/Let's Encrypt сертификаты.
- UFW firewall с минимальной публичной поверхностью.
- fail2ban для SSH.
- Быструю команду проверки состояния сервера.
- Подробную диагностику через deep health.
- Telegram-уведомления.
- Опциональный Telegram HTTPS Relay.
- Опциональный WARP routing через Xray.
- Безопасные команды, которые не печатают секреты по умолчанию.

---

## Что изменено в v1.1.0

### DNS safe mode

XPAM Script больше не пытается “насильно” переделывать рабочий DNS.

Теперь логика такая:

- если DNS провайдера работает, скрипт его принимает;
- Debian без `systemd-resolved` не считается ошибкой сам по себе;
- DNS проверяется через доступные системные механизмы;
- если DNS реально сломан, health/netdiag покажут проблему.

Это улучшает совместимость с минимальными VPS-образами и провайдерскими сетевыми шаблонами.

### Debian 12

Улучшена работа на Debian 12:

- fail2ban использует systemd backend;
- устанавливается `python3-systemd`;
- DNS/networking особенности Debian/provider images не превращаются в ложный FAIL, если сервер реально работает;
- health-check стал аккуратнее различать критичные ошибки и provider-specific особенности.

### SSH, IPv4 и `/etc/hosts`

- Сохраняется IPv4-first публичная схема.
- Публично используются TCP-порты 22/80/443.
- XPAM Script не создаёт публичные IPv6 TCP-правила для 22/80/443.
- Исправлена ситуация `sudo: unable to resolve host`, когда провайдер задаёт hostname, но не добавляет его в `/etc/hosts`.
- Managed domains XPAM не привязываются к localhost.

### Безопасный вывод секретов

Команды подключения больше не печатают секреты по умолчанию:

```text
sudo <prefix>-links
sudo <prefix>-vless
sudo <prefix>-telega
```

Для осознанного вывода используются:

```text
sudo <prefix>-links --show-secrets
sudo <prefix>-vless --show
sudo <prefix>-telega --show
sudo <prefix>-telega --manage
```

Это снижает риск случайно отправить VLESS/MTProto ссылки, пароли или токены в чат, скриншот или issue.

### Диагностика и repair

Добавлены:

```text
sudo <prefix>-netdiag
sudo <prefix>-repair
```

`netdiag` собирает диагностику сети, DNS, routes и resolver stack без автоматического ремонта.

`repair` восстанавливает XPAM-обвязку: helper-команды, service policy, limits, hooks, health scripts, maintenance scripts и service hygiene.

### WARP через 3x-ui/Xray

WARP остаётся опциональной функцией внутри Xray:

- системный `warp-cli` не устанавливается;
- default route сервера через WARP не меняется;
- пользователь сам управляет routing rules;
- health-check проверяет техническую форму WireGuard outbound.

### Telegram Relay

Telegram HTTPS Relay позволяет отправлять уведомления через HTTPS/443 без отдельного публичного порта.

Поддерживаются:

- direct mode;
- relay server;
- relay client.

---

## Что не менялось

- Порты публичной поверхности: 22/80/443.
- HAProxy TCP/SNI routing.
- nginx fallback-схема.
- Certbot / Let's Encrypt.
- 3x-ui и Xray как upstream-компоненты.
- MTProto через отдельный домен.
- WARP как optional Xray outbound, а не системный VPN.
- Хранение секретов в `/root/secure-notes`.

---

## Важное перед использованием

XPAM Script меняет системную конфигурацию VPS.

Перед запуском:

- используйте чистый VPS;
- подготовьте SSH-ключ;
- подготовьте DNS A records;
- уберите AAAA records для XPAM-managed доменов;
- прочитайте `docs/USER_GUIDE_RU.pdf`;
- не запускайте скрипт на сервере с важными рабочими сервисами.

---

## Release assets

- `xpam-script-v1.1.0-ubuntu24-debian12.tar.gz`
- `xpam-script-v1.1.0-ubuntu24-debian12.tar.gz.sha256`

---

## Проверенный статус

Проверено на чистых VPS:

```text
Ubuntu 24.04 LTS: PASS
Debian 12: PASS
GitHub Release assets: PASS
SHA256 verification: PASS
GitHub bootstrap path: PASS
```

Проверены:

- SSH hardening;
- DNS safe mode;
- fail2ban;
- UFW policy;
- nginx;
- HAProxy;
- 3x-ui/Xray;
- VLESS;
- MTProto;
- Certbot;
- Telegram direct alerts;
- Telegram HTTPS Relay;
- WARP через Xray;
- quick health;
- deep health;
- production cleanup;
- safe command output.
