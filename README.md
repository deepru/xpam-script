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

Bootstrap скачивает опубликованный архив из GitHub Releases, сверяет его SHA256 с файлом `.sha256` из того же релиза и запускает установку. Дальше — два пункта меню: **1)** SSH-безопасность, **2)** установка сервера. Пункт 2 выполняется дважды, с перезагрузкой между заходами. После установки оба пункта исчезают, и остаётся рабочее меню.

## Что это не решает

- Это инструмент для **своего** сервера и своего круга: одна установка — один оператор. Здесь нет
  биллинга, тарифов, панели для перепродажи доступа и учёта чужих пользователей.
- XPAM не обещает невидимости. Он делает сервер похожим на обычный веб-сайт и даёт запасной путь на
  случай блокировки, но домен, DNS, ключи и аккуратность в эксплуатации остаются на вас.
- Exit-сервер для DoubleHop готовите вы сами — XPAM настраивает только входную сторону.

> [!TIP]
> Перед установкой откройте **[Руководство пользователя](docs/USER_GUIDE_RU.md)** — там весь путь от подготовки VPS до эксплуатации, с примерами и разбором частых проблем.

## Документация

Основной документ — **[Руководство пользователя](docs/USER_GUIDE_RU.md)**. В нём весь путь от
подготовки VPS до эксплуатации; всё остальное — дополнение к нему.

| | |
|---|---|
| [Что подготовить](docs/USER_GUIDE_RU.md#ch2) · [SSH-ключ](docs/USER_GUIDE_RU.md#ch3) · [DNS](docs/USER_GUIDE_RU.md#ch4) | Перед установкой |
| [Установка](docs/USER_GUIDE_RU.md#ch5) · [Шаг 1](docs/USER_GUIDE_RU.md#ch6) · [Шаг 2](docs/USER_GUIDE_RU.md#ch7) | Как поставить |
| [Команды](docs/USER_GUIDE_RU.md#ch9) · [Меню](docs/USER_GUIDE_RU.md#ch10) · [Ссылки и секреты](docs/USER_GUIDE_RU.md#ch11) | После установки |
| [DoubleHop](docs/USER_GUIDE_RU.md#ch14) · [WARP](docs/USER_GUIDE_RU.md#ch15) · [Запасной транспорт](docs/USER_GUIDE_RU.md#ch16) · [Сайты-маскировки](docs/USER_GUIDE_RU.md#ch17) | Возможности |
| [Проверка и обслуживание](docs/USER_GUIDE_RU.md#ch19) · [Обновление](docs/USER_GUIDE_RU.md#ch20) · [Частые проблемы](docs/USER_GUIDE_RU.md#ch22) | Эксплуатация |

Ещё: [что считается секретом](SECURITY.md) · [проверка сервера](TESTING.md) ·
[изменения по версиям](CHANGELOG.md) · [релизы](https://github.com/deepru/xpam-script/releases)

Краткий справочник на английском — в [`docs/`](docs/README.md).

## Лицензия

MIT License. 3x-ui, Xray-core, mtg, nginx, HAProxy, Certbot, UFW, fail2ban, systemd и другие компоненты сохраняют свои лицензии — см. [THIRD_PARTY.md](THIRD_PARTY.md).
