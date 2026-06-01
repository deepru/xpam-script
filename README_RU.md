# XPAM Script

**XPAM Script** — это Bash-автоматизация для подготовки чистого VPS под аккуратную IPv4-first HTTPS/TLS-инфраструктуру с VLESS, MTProto, сайтами-маскировками, 3x-ui/Xray, HAProxy, nginx, Certbot, firewall, fail2ban, health-check, Telegram-уведомлениями, HTTPS Relay, WARP через Xray и финальной production-очисткой.

Релизы и установочные архивы доступны в [GitHub Releases](https://github.com/deepru/xpam-script/releases).

> Перед использованием обязательно прочитайте [полную инструкцию пользователя в PDF](docs/USER_GUIDE_RU.pdf).
>
> Скрипт меняет SSH, firewall, nginx, HAProxy, 3x-ui/Xray, MTProto, Certbot, fail2ban, systemd-юниты, health/maintenance-скрипты, DNS-проверки, `/etc/hosts` и сетевые параметры VPS. Это не “маленькая утилита”, а полноценная автоматизация сервера. Не запускайте XPAM Script на VPS, где уже работают важные сервисы.

---

## Для чего нужен XPAM Script

XPAM Script создан для ситуации, когда пользователь покупает чистый VPS и хочет получить готовую, воспроизводимую и проверяемую серверную схему без ручной сборки десятков компонентов.

После установки пользователь получает:

- защищённый SSH-доступ по ключу;
- IPv4-first публичную поверхность с портами **22/80/443**;
- HTTPS/TLS через nginx, HAProxy и Certbot;
- 3x-ui/Xray с SQLite backend;
- VLESS через отдельный домен;
- MTProto proxy через отдельный домен в MTProto-профилях;
- сайты-маскировки и fallback-сайт;
- Telegram-уведомления о состоянии сервера;
- опциональный HTTPS Relay для Telegram-уведомлений;
- опциональный WARP outbound внутри Xray;
- health-check и deep diagnostics;
- сервисную диагностику сети/DNS;
- repair-команду для восстановления XPAM-обвязки;
- production cleanup после завершения настройки;
- безопасные команды, которые не печатают секреты по умолчанию.

---

## Поддерживаемые системы

Официально проверено:

- **Ubuntu 24.04 LTS**
- **Debian 12**

XPAM Script рассчитан на **чистый VPS** с root-доступом. Использование на сервере с уже настроенными сайтами, панелями, VPN, reverse proxy или нестандартным firewall не рекомендуется.

---

## Что нужно подготовить до запуска

Перед установкой должны быть готовы:

1. VPS с Ubuntu 24.04 LTS или Debian 12.
2. Root-доступ по SSH.
3. SSH-ключ, добавленный в `/root/.ssh/authorized_keys`.
4. Доменная зона.
5. IPv4 A-записи для доменов, которые будет использовать XPAM Script.
6. Отсутствие AAAA-записей для XPAM-managed доменов, если вы не понимаете последствия IPv6.
7. Понимание будущего prefix-команд, например `<prefix>-install`, `<prefix>-health`, `<prefix>-links`.

Рекомендуемая схема DNS:

```text
example.com          A    SERVER_IP
www.example.com      A    SERVER_IP
vless.example.com    A    SERVER_IP
tg.example.com       A    SERVER_IP
```

`SERVER_IP` — публичный IPv4 вашего VPS.

---

## Быстрая установка

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

Bootstrap скачивает опубликованный GitHub Release, проверяет SHA256, распаковывает архив и запускает установщик.

После запуска сначала выберите пункт `0` для SSH-безопасности и создания prefix-команды, затем пункт `1` для установки.

```text
0) SSH-безопасность / создать prefix-команду
1) Установить / продолжить настройку сервера
```

После шага 0 пользователь работает через свои prefix-команды. Если prefix = `srv`, команды будут `sudo srv-install`, `sudo srv-health`, `sudo srv-links` и так далее.

В документации используется универсальная запись:

```text
sudo <prefix>-install
sudo <prefix>-health
sudo <prefix>-links
```

---

## Что именно делает XPAM Script

### 1. SSH и базовая безопасность

XPAM Script:

- проверяет вход по SSH-ключу;
- отключает password login;
- оставляет root login по ключу;
- отключает пустые пароли;
- отключает X11 forwarding;
- ограничивает SSH policy;
- создаёт удобные prefix-команды;
- не даёт продолжать установку, если key-only SSH policy не подтверждена.

### 2. Firewall и публичная поверхность

XPAM Script настраивает UFW так, чтобы снаружи были доступны только необходимые публичные IPv4 TCP-порты:

```text
22/tcp   SSH
80/tcp   HTTP для Certbot/redirect
443/tcp  HTTPS/TLS поверхность
```

Backend-сервисы остаются на loopback, а не открываются наружу напрямую. XPAM Script не создаёт публичные IPv6 TCP-правила для 22/80/443.

### 3. DNS safe mode и provider-specific quirks

XPAM Script использует safe DNS behavior: если DNS провайдера работает, скрипт его не переписывает. Debian без `systemd-resolved` не считается ошибкой сам по себе. Health/repair также учитывают типовые особенности VPS-образов, например no-op `rc-local.service` и Debian `ufw.service inactive (dead)` при фактически активном firewall.

### 4. 3x-ui, SQLite, Xray и VLESS

XPAM Script использует 3x-ui и Xray как upstream-компоненты, но автоматизирует их установку и интеграцию в общую схему.

Важный контракт:

- XPAM Script поддерживает 3x-ui только с SQLite backend;
- штатная база 3x-ui должна быть `/etc/x-ui/x-ui.db`;
- PostgreSQL backend не поддерживается;
- health/repair остановятся с понятной ошибкой, если обнаружат PostgreSQL backend.

VLESS inbound, созданный XPAM Script, получает имя `<prefix>-vless`. Пользовательские имена inbound/client и валидный пользовательский uTLS fingerprint не должны ломать health, repair и вывод VLESS-ссылок.

### 5. MTProto

XPAM Script может настроить MTProto proxy:

- отдельный домен под MTProto;
- маршрутизацию через HAProxy по SNI;
- управление пользователями;
- безопасное хранение ссылок в `/root/secure-notes`.

Команда MTProto:

```text
sudo <prefix>-tg
sudo <prefix>-tg --show
sudo <prefix>-tg --manage
```

### 6. WARP через 3x-ui/Xray

WARP в XPAM Script — это опциональный WireGuard outbound внутри Xray. XPAM Script не устанавливает системный `warp-cli`, не переводит весь сервер через WARP, не меняет default route и не меняет DNS сервера.

Если 3x-ui создаёт Cloudflare WARP outbound без 3 reserved bytes, deep health покажет предупреждение. XPAM Script не генерирует reserved bytes сам, не копирует их с других серверов и не перетирает пользовательские WARP-настройки.

### 7. Health-check, repair и обслуживание

После установки доступны:

```text
sudo <prefix>-health
sudo <prefix>-health --deep
sudo <prefix>-netdiag
sudo <prefix>-repair
sudo <prefix>-weekly-maintenance.sh
```

`health` проверяет сервер как единый продукт: сервисы, firewall, TLS, DNS, 3x-ui backend, External Proxy, WARP, service hygiene, snapshot freshness, swap, kernel/reboot status и сетевую tuning policy. `repair` восстанавливает XPAM-обвязку, не меняя домены, VLESS UUID, MTProto secret и пользовательские данные.

---

## Основные команды после установки

```text
sudo <prefix>-install        главное меню XPAM Script
sudo <prefix>-health         быстрая проверка сервера
sudo <prefix>-health --deep  подробная диагностика
sudo <prefix>-links          безопасная сводка без секретов
sudo <prefix>-vless          информация по VLESS без вывода ссылки
sudo <prefix>-tg             информация по MTProto без вывода секретов
sudo <prefix>-netdiag        диагностика сети/DNS
sudo <prefix>-repair         восстановление XPAM-обвязки
```

Для осознанного вывода секретов:

```text
sudo <prefix>-links --show-secrets
sudo <prefix>-vless --show
sudo <prefix>-tg --show
sudo <prefix>-tg --manage
```

Не публикуйте вывод этих команд в чатах, issues, screenshots или публичных логах.

---

## Документация

- [Полная инструкция пользователя, PDF](docs/USER_GUIDE_RU.pdf)
- [Полная инструкция пользователя, DOCX](docs/USER_GUIDE_RU.docx)
- [CHANGELOG.md](CHANGELOG.md)
- [TESTING.md](TESTING.md)
- [SECURITY.md](SECURITY.md)
- [THIRD_PARTY.md](THIRD_PARTY.md)
- [GitHub Releases](https://github.com/deepru/xpam-script/releases)

---

## Лицензия и сторонние компоненты

XPAM Script распространяется под MIT License. 3x-ui, Xray-core, MTProto proxy, nginx, HAProxy, Certbot, UFW, fail2ban, systemd и другие компоненты сохраняют свои собственные лицензии. Подробно: [`THIRD_PARTY.md`](THIRD_PARTY.md).
