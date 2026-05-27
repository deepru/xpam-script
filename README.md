# XPAM Script

**XPAM Script** — автоматизированный Bash-инструмент для подготовки VPS на **Ubuntu 24.04 LTS** и **Debian 12**.

Скрипт настраивает серверную схему для **VLESS** и **MTProto** с HTTPS/TLS-поверхностью, сайтами-маскировками, TLS-сертификатами, firewall, health-checks и еженедельным обслуживанием.

Актуальный публичный релиз: **v1.0.10**.
> **IPv4-first:** XPAM Script поддерживает установку только по IPv4. Для доменов проекта создавайте только `A`-записи на IPv4-адрес VPS. `AAAA`-записи для этих доменов нужно удалить до запуска установки: публичный IPv6-режим скриптом не поддерживается.

---

## Быстрая установка

На чистом VPS выполните:

    curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
    sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh

После запуска следуйте меню установщика.

---

## Что делает XPAM Script

XPAM Script автоматизирует полный цикл подготовки VPS:

- настраивает SSH-безопасность и вход только по SSH-ключу;
- отключает вход по SSH-паролю;
- настраивает UFW firewall;
- устанавливает и настраивает nginx;
- устанавливает и настраивает HAProxy для TCP/SNI-маршрутизации;
- устанавливает Certbot и получает TLS-сертификаты Let's Encrypt;
- устанавливает и настраивает 3x-ui / Xray;
- создаёт VLESS inbound на loopback-адресе;
- настраивает внешний VLESS-домен через HTTPS/TLS;
- устанавливает и настраивает MTProto proxy;
- маскирует VLESS и MTProto под обычную HTTPS/TLS-поверхность;
- создаёт рабочие сайты-маскировки;
- настраивает systemd-зависимости и порядок запуска сервисов;
- настраивает DNS policy через systemd-resolved;
- применяет сетевые параметры ядра: BBR, fq, TCP buffers, backlog и другие;
- отключает ненужные фоновые сервисы и демоны;
- создаёт health-checks;
- создаёт еженедельное обслуживание;
- поддерживает Telegram-уведомления об ошибках weekly maintenance;
- поддерживает опциональную WARP-маршрутизацию через 3x-ui / Xray;
- создаёт резервные снимки конфигурации;
- сохраняет данные подключения в защищённых файлах на сервере.

---

## Для чего нужен скрипт

XPAM Script нужен, когда требуется не собирать VPS вручную из десятков команд, а получить повторяемую и проверяемую схему:

- один публичный HTTPS/TLS-порт `443`;
- backend-сервисы только на `127.0.0.1`;
- рабочие сайты на публичных доменах;
- защищённый путь панели 3x-ui;
- VLESS через Xray;
- MTProto через отдельный домен;
- сертификаты Let's Encrypt;
- firewall и fail2ban;
- автоматические проверки здоровья сервера;
- безопасная еженедельная maintenance-процедура.

---

## Требования

Перед запуском нужен:

- чистый VPS на Ubuntu 24.04 LTS или Debian 12;
- root-доступ;
- SSH-ключ, заранее добавленный на сервер;
- свой домен;
- возможность создавать поддомены;
- возможность редактировать DNS-записи;
- DNS A-записи доменов должны указывать на IPv4 VPS.

Без рабочего SSH-входа по ключу использовать скрипт нельзя: пункт `0` отключает SSH-вход по паролю.

---

## Поддерживаемые схемы

XPAM Script поддерживает несколько профилей:

- VLESS direct TLS;
- VLESS + MTProto на отдельных поддоменах;
- основной сайт + www redirect + VLESS-домен + MTProto-домен.

В схемах с MTProto внешний порт `443` обслуживается HAProxy.

HAProxy маршрутизирует соединения по SNI:

- VLESS-домен → Xray/VLESS backend;
- MTProto-домен → MTProto backend;
- обычные сайты → nginx fallback/web surface.

---

## Основные команды после установки

Префикс пользователь задаёт на шаге `0`. Ниже `<prefix>` означает выбранный пользователем префикс.

    sudo <prefix>-install
    sudo <prefix>-health
    sudo <prefix>-links
    sudo <prefix>-vless
    sudo <prefix>-telega

Пример: если префикс `de`, команды будут `sudo de-install`, `sudo de-health`, `sudo de-links`.

---

## Документация

- [Полное руководство пользователя на русском языке, PDF](docs/USER_GUIDE_RU.pdf)
- [README_RU.md](README_RU.md)
- [English technical README](README_EN.md)
- [Установка](docs/INSTALLATION.md)
- [Архитектура](docs/ARCHITECTURE.md)
- [Модель безопасности](docs/SECURITY_MODEL.md)
- [Telegram-уведомления](docs/TELEGRAM_NOTIFICATIONS.md)
- [WARP](docs/WARP.md)
- [Управление сайтами](docs/SITES.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

---

## Проверенный статус

Проверено:

- GitHub bootstrap скачивает актуальный релиз;
- SHA256-проверка архива проходит успешно;
- установщик запускается из GitHub Release;
- Ubuntu 24.04 LTS протестирован end-to-end;
- Debian 12 ранее протестирован end-to-end;
- VLESS работает;
- MTProto работает;
- сайты-маскировки открываются;
- TLS-сертификаты корректны;
- weekly maintenance завершается с `Exit status: 0`;
- финальная production-очистка удаляет временные bootstrap/install/build-файлы;
- после очистки сервер остаётся здоровым.

---

## Release assets

В каждом релизе публикуются:

- `xpam-script-vX.Y.Z-ubuntu24-debian12.tar.gz`
- `xpam-script-vX.Y.Z-ubuntu24-debian12.tar.gz.sha256`

Проверка архива:

    sha256sum -c xpam-script-vX.Y.Z-ubuntu24-debian12.tar.gz.sha256

---

## Third-party components

XPAM Script не является форком 3x-ui, Xray-core или MTProto proxy.

Проект является automation / hardening / configuration wrapper и использует сторонние компоненты:

- 3x-ui;
- Xray-core;
- alexbers/mtprotoproxy;
- nginx;
- HAProxy;
- Certbot / Let's Encrypt;
- UFW;
- fail2ban;
- systemd.

Подробности указаны в [THIRD_PARTY.md](THIRD_PARTY.md).

---

## Важно

XPAM Script изменяет системную конфигурацию VPS:

- SSH;
- firewall;
- DNS policy;
- systemd-сервисы;
- nginx;
- HAProxy;
- Xray;
- 3x-ui;
- MTProto;
- сетевые параметры ядра;
- service hygiene.

Используйте скрипт на чистом VPS. Не запускайте его на сервере с важными рабочими сервисами без понимания последствий.
