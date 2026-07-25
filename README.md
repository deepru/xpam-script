# XPAM Script

[![License: MIT](https://img.shields.io/github/license/deepru/xpam-script?color=blue)](LICENSE)
[![Release](https://img.shields.io/github/v/release/deepru/xpam-script?sort=semver)](https://github.com/deepru/xpam-script/releases/latest)
[![CI](https://github.com/deepru/xpam-script/actions/workflows/ci.yml/badge.svg)](https://github.com/deepru/xpam-script/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/Ubuntu%20%C2%B7%20Debian-informational)](docs/INSTALLATION.md)

**Русский** · [English](README_EN.md)

> Превращает чистый VPS в приватную HTTPS-инфраструктуру: **VLESS** и **Telegram proxy (MTG)** за одним портом `443`, с настоящим TLS-сертификатом и сайтами-маскировками.

Всё, что обычно делается вручную, скрипт берёт на себя: 3x-ui/Xray, nginx, HAProxy, Certbot, UFW, fail2ban, защита SSH, проверки состояния, еженедельное обслуживание и безопасное обновление самого себя. Управление после установки — одна команда `sudo <prefix>-xpam`.

> [!WARNING]
> Скрипт меняет SSH, firewall, nginx, HAProxy, 3x-ui/Xray, Certbot, fail2ban, systemd-юниты, `/etc/hosts` и сетевые параметры. Запускайте его **на чистом VPS**, а не там, где уже работают ваши сервисы.

## Возможности

| | |
|---|---|
| 🔐 **VLESS + Telegram proxy** | Оба за единым HTTPS-фронтом `443/tcp` — отдельных «подозрительных» портов нет |
| 🎭 **Умная маскировка** | На каждый домен — свой правдоподобный сайт, уникальный для каждой установки. Можно поставить и свой настоящий |
| 🔁 **Запасной транспорт** | Второй способ подключения (xhttp/grpc) на отдельном домене — на случай, если основной начали блокировать |
| 🔀 **DoubleHop** | Выпуск VLESS и/или Telegram через второй сервер |
| ⚙️ **WARP** | Автоматическая регистрация и точечная маршрутизация — без системного VPN |
| 🛡️ **Хардненинг** | SSH только по ключу, UFW, fail2ban, панель под скрытым путём и Basic Auth |
| ❤️ **Проверка и ремонт** | Быстрая и глубокая диагностика, восстановление обвязки и базы 3x-ui с авто-откатом |
| ⬆️ **Обновление** | Проверка контрольной суммы, резервная копия, проверка после установки, откат при сбое |

## Как это устроено

Снаружи открыт один рабочий порт — обычный HTTPS. Запросы разбираются по имени домена:

```text
Интернет :443 (HTTPS)
      │
      ├─ VLESS-домен      →  Xray / VLESS
      ├─ Telegram-домен   →  Telegram proxy (MTG)
      ├─ запасной домен   →  запасной транспорт (если включён)
      └─ всё остальное    →  обычный сайт (маскировка)
```

Поэтому со стороны сервер выглядит как обычный веб-сайт: если открыть домен в браузере, откроется нормальная страница, а не пустой технический ответ.

## Быстрый старт

Понадобится: чистый VPS на **Ubuntu** или **Debian** с root-доступом, домены для VLESS, Telegram proxy и панели с **A-записями** на IPv4 сервера, открытые порты `22`, `80`, `443` и **SSH-ключ** — вход по паролю отключается на первом же шаге.

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

Bootstrap скачивает опубликованный архив из GitHub Releases, проверяет SHA256 и запускает установку. Дальше — два пункта меню: сначала SSH-безопасность, затем установка сервера. После установки они исчезают, и остаётся рабочее меню.

> [!TIP]
> Перед установкой откройте **[Руководство пользователя](docs/USER_GUIDE_RU.md)** — там весь путь от подготовки VPS до эксплуатации, с примерами и разбором частых проблем.

## Документация

- **[Руководство пользователя](docs/USER_GUIDE_RU.md)** — основной документ, от установки до диагностики
- [Архитектура](docs/ARCHITECTURE.md) · [Установка](docs/INSTALLATION.md) · [Настройки и команды](docs/CONFIGURATION.md)
- [Проверки состояния](docs/HEALTHCHECKS.md) · [Обслуживание](docs/MAINTENANCE.md) · [Частые проблемы](docs/TROUBLESHOOTING.md)
- [Сайты-маскировки](docs/SITES.md) · [WARP](docs/WARP.md) · [Telegram-уведомления](docs/TELEGRAM_NOTIFICATIONS.md)
- [Модель безопасности](docs/SECURITY_MODEL.md) · [Changelog](CHANGELOG.md) · [Releases](https://github.com/deepru/xpam-script/releases)

## Лицензия

MIT License. 3x-ui, Xray-core, mtg, nginx, HAProxy, Certbot, UFW, fail2ban, systemd и другие компоненты сохраняют свои лицензии — см. [THIRD_PARTY.md](THIRD_PARTY.md).
