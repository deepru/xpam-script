# XPAM Script

**XPAM Script** — это Bash-автоматизация для подготовки чистого VPS под аккуратную IPv4-first HTTPS/TLS-инфраструктуру с VLESS, MTProto, сайтами-маскировками, 3x-ui/Xray, HAProxy, nginx, Certbot, firewall, fail2ban, health-check, Telegram-уведомлениями, HTTPS Relay, WARP через Xray и финальной production-очисткой.

Актуальный публичный релиз: **v1.1.0**.

> **Перед использованием обязательно прочитайте полную инструкцию: [`docs/USER_GUIDE_RU.pdf`](docs/USER_GUIDE_RU.pdf).**
>
> Скрипт меняет SSH, firewall, nginx, HAProxy, 3x-ui/Xray, MTProto, Certbot, fail2ban, systemd-юниты, health/maintenance-скрипты, DNS-проверки, `/etc/hosts` и сетевые параметры VPS. Это не “маленькая утилита”, а полноценная автоматизация сервера. Не запускайте XPAM Script на VPS, где уже работают важные сервисы.

---

## Для чего нужен XPAM Script

XPAM Script создан для ситуации, когда пользователь покупает чистый VPS и хочет получить готовую, воспроизводимую и проверяемую серверную схему без ручной сборки десятков компонентов.

После установки пользователь получает:

- защищённый SSH-доступ по ключу;
- IPv4-first публичную поверхность с портами **22/80/443**;
- HTTPS/TLS через nginx, HAProxy и Certbot;
- 3x-ui/Xray с loopback backend;
- VLESS через отдельный домен;
- MTProto proxy через отдельный домен;
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

Идея простая: сначала убедиться, что пользователь не потеряет доступ к серверу, и только потом продолжать установку.

### 2. Firewall и публичная поверхность

XPAM Script настраивает UFW так, чтобы снаружи были доступны только необходимые публичные IPv4 TCP-порты:

```text
22/tcp   SSH
80/tcp   HTTP для Certbot/redirect
443/tcp  HTTPS/TLS поверхность
```

Backend-сервисы остаются на loopback, а не открываются наружу напрямую.

XPAM Script не создаёт публичные IPv6 TCP-правила для 22/80/443.

### 3. DNS safe mode

В v1.1.0 XPAM Script использует safe DNS behavior:

- если DNS провайдера работает, скрипт его не переписывает;
- Debian без `systemd-resolved` не считается ошибкой сам по себе;
- DNS проверяется через доступные системные механизмы;
- если DNS сломан, health/netdiag покажут проблему.

Это сделано специально для реальных VPS-образов разных провайдеров, где DNS и resolver stack могут отличаться.

### 4. `/etc/hosts` и hostname

Некоторые VPS-провайдеры задают hostname сервера, но не добавляют его в `/etc/hosts`. Из-за этого `sudo` может писать:

```text
sudo: unable to resolve host ...
```

XPAM Script v1.1.0 нормализует `/etc/hosts` так, чтобы hostname резолвился корректно, а XPAM-managed домены не были привязаны к `127.0.0.1` или `127.0.1.1`.

### 5. nginx, HAProxy и TLS

XPAM Script настраивает HTTPS/TLS-поверхность:

- nginx для сайтов, fallback и HTTP/HTTPS-логики;
- HAProxy для TCP/SNI routing;
- Certbot / Let's Encrypt для сертификатов;
- TLS-согласованность между доменами и сервисами;
- redirect и fallback-поведение.

Снаружи сервер выглядит как обычный HTTPS-сервер, а внутренняя маршрутизация остаётся управляемой и проверяемой.

### 6. 3x-ui, Xray и VLESS

XPAM Script использует 3x-ui и Xray как upstream-компоненты, но автоматизирует их установку и интеграцию в общую схему.

В результате:

- 3x-ui работает на loopback;
- доступ к панели идёт через HTTPS path и Basic Auth;
- VLESS получает отдельный домен;
- VLESS-ссылка сохраняется в `/root/secure-notes`;
- команда `sudo <prefix>-vless` не печатает ссылку по умолчанию;
- для осознанного вывода используется `sudo <prefix>-vless --show`.

### 7. MTProto

XPAM Script может настроить MTProto proxy:

- отдельный домен под MTProto;
- маршрутизация через HAProxy по SNI;
- управление пользователями;
- ссылки сохраняются в `/root/secure-notes`;
- команда `sudo <prefix>-telega` безопасна по умолчанию;
- для вывода ссылок используется `sudo <prefix>-telega --show`;
- для управления пользователями используется `sudo <prefix>-telega --manage`.

### 8. Telegram-уведомления и HTTPS Relay

XPAM Script поддерживает Telegram-уведомления:

- direct mode — сервер сам отправляет уведомления в Telegram;
- relay server — сервер принимает HTTPS-запросы от других XPAM-серверов и пересылает их в Telegram;
- relay client — сервер отправляет уведомления через relay, если прямой доступ к Telegram API невозможен.

HTTPS Relay использует существующую HTTPS/443 поверхность и не требует отдельного публичного порта.

### 9. WARP через 3x-ui/Xray

WARP в XPAM Script — это опциональный WireGuard outbound внутри Xray.

Важно:

- XPAM Script не устанавливает системный `warp-cli`;
- не переводит весь сервер через WARP;
- не меняет default route сервера через WARP;
- пользователь сам решает, какие routing rules отправлять через WARP;
- health-check проверяет техническую форму WARP outbound.

### 10. Health-check и диагностика

После установки доступны:

```text
sudo <prefix>-health
sudo <prefix>-health --deep
sudo <prefix>-netdiag
sudo <prefix>-repair
```

`health` проверяет сервер как единый продукт: сервисы, firewall, TLS, DNS, hygiene, snapshot freshness, swap, kernel/reboot status и другие важные элементы.

`netdiag` собирает диагностику сети/DNS и ничего не чинит автоматически.

`repair` восстанавливает XPAM-обвязку: команды, health/weekly scripts, limits, hooks, fail2ban policy и service hygiene.

### 11. Backups, secure-notes и cleanup

XPAM Script сохраняет чувствительные данные и резервные копии в предсказуемых местах:

```text
/root/secure-notes
/root/config-backups
/root/manual-backups
/var/log/xpam-script
```

Финальная production-очистка удаляет установочные архивы, `.sha256`, распакованные install-папки, временные debug/test-файлы и пустые служебные директории, но не удаляет секреты, SSH-ключи и резервные копии.

---

## Основные команды после установки

```text
sudo <prefix>-install        главное меню XPAM Script
sudo <prefix>-health         быстрая проверка сервера
sudo <prefix>-health --deep  подробная диагностика
sudo <prefix>-links          безопасная сводка без секретов
sudo <prefix>-vless          информация по VLESS без вывода ссылки
sudo <prefix>-telega         информация по MTProto без вывода секретов
sudo <prefix>-netdiag        диагностика сети/DNS
sudo <prefix>-repair         восстановление XPAM-обвязки
```

Секреты не печатаются по умолчанию.

Для осознанного вывода:

```text
sudo <prefix>-links --show-secrets
sudo <prefix>-vless --show
sudo <prefix>-telega --show
sudo <prefix>-telega --manage
```

Не публикуйте вывод этих команд в чатах, issues, screenshots или публичных логах.

---

## Главное меню

```text
0) SSH-безопасность / создать prefix-команду
1) Установить / продолжить настройку сервера
2) Показать данные для подключения
3) Проверить состояние сервера
4) Telegram-уведомления
5) WARP через 3x-ui/Xray
6) Управление сайтами
7) Дополнительно
8) Выход
```

Раздел `Дополнительно` содержит deep health, сетевую диагностику, repair, финальную production-очистку и просмотр текущей конфигурации.

---

## Что нельзя делать без понимания последствий

Не рекомендуется:

- запускать XPAM Script на сервере с важными рабочими сервисами;
- вручную открывать наружу loopback backend-порты;
- менять firewall в обход XPAM policy;
- удалять `/root/secure-notes`;
- публиковать VLESS/MTProto ссылки, Telegram tokens, WARP keys;
- привязывать XPAM-managed домены к `127.0.0.1`;
- вручную переводить весь сервер через системный WARP/warp-cli;
- удалять или менять файлы в `/opt/xpam-script`, если вы не понимаете, что делаете.

---

## Документация

Обязательная инструкция:

- [`docs/USER_GUIDE_RU.pdf`](docs/USER_GUIDE_RU.pdf)
- [`docs/USER_GUIDE_RU.docx`](docs/USER_GUIDE_RU.docx)

Дополнительно:

- [`CHANGELOG-v1.1.0.md`](CHANGELOG-v1.1.0.md)
- [`RELEASE_NOTES-v1.1.0.md`](RELEASE_NOTES-v1.1.0.md)
- [`TESTING-v1.1.0.md`](TESTING-v1.1.0.md)
- [`THIRD_PARTY.md`](THIRD_PARTY.md)
- [`SECURITY.md`](SECURITY.md)

---

## Third-party components

XPAM Script — это automation/hardening/configuration wrapper. Он использует и настраивает сторонние компоненты:

- 3x-ui;
- Xray-core;
- alexbers/mtprotoproxy;
- nginx;
- HAProxy;
- Certbot / Let's Encrypt;
- UFW;
- fail2ban;
- systemd;
- cron.

Сторонние компоненты принадлежат их авторам и распространяются на условиях их лицензий.

---

## Проверенный статус v1.1.0

Проверено на чистых VPS:

```text
Ubuntu 24.04 LTS: PASS
Debian 12: PASS
GitHub Release assets: PASS
SHA256 verification: PASS
GitHub bootstrap path: PASS
```

Проверены установка, SSH hardening, DNS safe mode, fail2ban, UFW, nginx, HAProxy, 3x-ui/Xray, VLESS, MTProto, Certbot, Telegram Relay, WARP, health, deep health, cleanup и безопасный вывод команд.

---

## Лицензия

См. [`LICENSE`](LICENSE).

---

## Security

Не публикуйте реальные домены, IP-адреса, токены, приватные ключи, VLESS/MTProto ссылки и содержимое `/root/secure-notes`.

См. [`SECURITY.md`](SECURITY.md).
