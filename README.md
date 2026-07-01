# XPAM Script

**XPAM Script** — Bash-автоматизация для быстрого развёртывания приватной HTTPS/TLS-инфраструктуры на чистом VPS.

XPAM настраивает **VLESS**, **Telegram proxy / MTG**, 3x-ui/Xray, nginx, HAProxy, Certbot, firewall, fail2ban, health-checks, maintenance-сценарии, WARP через Xray, **DoubleHop Mode** и безопасное обновление через XPAM.

> XPAM Script меняет SSH, firewall, nginx, HAProxy, 3x-ui/Xray, Certbot, fail2ban, systemd-юниты, health/maintenance-скрипты, DNS-проверки, `/etc/hosts` и сетевые параметры VPS. Используйте его на чистом VPS, а не на сервере, где уже работают важные сервисы.

## Быстрый старт

Перед запуском подготовьте:

- чистый VPS на **Ubuntu** или **Debian**;
- root-доступ по SSH;
- домены для VLESS, Telegram proxy / MTG и панели;
- DNS A-записи на IPv4 вашего сервера.

### Установка через GitHub bootstrap

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

Bootstrap скачивает опубликованный архив из **GitHub Releases**, проверяет SHA256, распаковывает XPAM Script и запускает установку.

Если загрузка bootstrap временно не проходит из-за сетевой ошибки провайдера или GitHub, повторите команду позже либо скачайте `bootstrap.sh` локально и загрузите его на VPS вручную. XPAM всё равно скачивает опубликованный архив из GitHub Releases и проверяет SHA256 перед установкой.

После запуска сначала выполните пункт `0` для SSH-безопасности и создания prefix-команды, затем пункт `1` для установки сервера.

```text
0) SSH-безопасность / создать prefix-команду
1) Установить / продолжить настройку сервера
```

После шага 0 основная команда управления будет:

```bash
sudo <prefix>-xpam
```

Например, если prefix = `srv`:

```bash
sudo srv-xpam
```

## Инструкция и документация

Перед установкой рекомендуется открыть полную инструкцию пользователя.

**Основной вариант инструкции:** [USER_GUIDE_RU.docx](docs/USER_GUIDE_RU.docx)

**PDF-версия для скачивания:** [USER_GUIDE_RU.pdf](https://github.com/deepru/xpam-script/raw/main/docs/USER_GUIDE_RU.pdf)

> Если встроенный PDF-preview в браузере искажает кириллицу, используйте DOCX-версию или скачайте PDF и откройте его в Chrome, Adobe Reader, SumatraPDF или другом локальном PDF viewer.

Дополнительные материалы:

- [Release notes / changelog](CHANGELOG.md)
- [GitHub Releases](https://github.com/deepru/xpam-script/releases)
- [CHANGELOG.md](CHANGELOG.md)
- [TESTING.md](TESTING.md)
- [SECURITY.md](SECURITY.md)
- [THIRD_PARTY.md](THIRD_PARTY.md)

## Что делает XPAM Script

После установки пользователь получает:

- защищённый SSH-доступ по ключу;
- HTTPS/TLS-поверхность на `443/tcp`;
- nginx + HAProxy + Certbot;
- 3x-ui/Xray с SQLite backend;
- VLESS через отдельный домен;
- Telegram proxy / MTG через отдельный домен;
- сайты-маскировки и fallback;
- health-check и deep-health диагностику;
- repair-команду для восстановления XPAM runtime/обвязки;
- weekly maintenance;
- WARP через 3x-ui/Xray как optional outbound;
- DoubleHop Mode для маршрутизации VLESS и/или Telegram через второй XPAM-сервер;
- безопасное user-initiated обновление XPAM через меню.

## Поддерживаемые системы

Официально протестировано:

- Ubuntu
- Debian

Рекомендуется чистый VPS с root-доступом и IPv4. Использование на сервере с уже настроенными сайтами, панелями, VPN, reverse proxy или нестандартным firewall не рекомендуется.

## Основные команды

После настройки prefix-команд используйте:

```bash
sudo <prefix>-xpam
sudo <prefix>-health
sudo <prefix>-health --deep
sudo <prefix>-links
sudo <prefix>-links --show-secrets
sudo <prefix>-repair
sudo <prefix>-netdiag
```

Главная команда управления:

```bash
sudo <prefix>-xpam
```

Она открывает меню XPAM Script: установка, состояние сервера, данные подключения, WARP, DoubleHop Mode, сайты, обновление и дополнительные операции.

## VLESS и Telegram links

Актуальные данные подключения показываются командой:

```bash
sudo <prefix>-links --show-secrets
```

VLESS links и Telegram link формируются из текущей конфигурации **3x-ui**. Если пользователь добавил/изменил VLESS-клиента или вручную сменил Telegram proxy / MTG secret в 3x-ui, нужно повторно запустить команду и взять новую актуальную ссылку из вывода.

Не публикуйте вывод `--show-secrets` в чатах, issues, screenshots или публичных логах.

## DoubleHop Mode

DoubleHop Mode позволяет использовать два XPAM-сервера: основной сервер принимает текущие VLESS/Telegram links, а выбранный трафик выпускает через второй XPAM-сервер.

Поддерживаемые режимы:

```text
VLESS only
Telegram only
VLESS + Telegram
```

Как это работает:

- установите XPAM на обоих серверах обычным способом;
- на втором сервере откройте `sudo <prefix>-links --show-secrets` и возьмите VLESS-ссылку;
- на основном сервере откройте `sudo <prefix>-xpam` → `DoubleHop Mode` и вставьте VLESS-ссылку второго сервера;
- текущие VLESS и Telegram links основного сервера не меняются при включении, изменении режима или выключении DoubleHop.

## Безопасное обновление

XPAM поддерживает user-initiated обновление через меню. Обновление проверяет release metadata, SHA256, делает backup/snapshot, выполняет preflight, применяет новую версию, запускает post-update health/deep-health и откатывается при ошибке.

## Лицензия и сторонние компоненты

XPAM Script распространяется под MIT License.

3x-ui, Xray-core, nginx, HAProxy, Certbot, UFW, fail2ban, systemd и другие компоненты сохраняют свои собственные лицензии. Подробнее: [THIRD_PARTY.md](THIRD_PARTY.md).
