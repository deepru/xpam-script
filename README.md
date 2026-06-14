# XPAM Script

**XPAM Script** — это Bash-автоматизация для быстрого развёртывания приватной HTTPS/TLS-инфраструктуры на чистом VPS: **VLESS**, **Telegram proxy / MTG**, 3x-ui/Xray, nginx, HAProxy, Certbot, firewall, fail2ban, health-checks, maintenance-сценарии, WARP через Xray, **DoubleHop Mode** и безопасное обновление через XPAM.

Цель проекта простая: взять чистый сервер и привести его к готовому, управляемому состоянию без ручной сборки nginx, HAProxy, TLS, 3x-ui, firewall, диагностики и служебных скриптов.

> XPAM Script меняет SSH-настройки, firewall, nginx, HAProxy, 3x-ui/Xray, Certbot, fail2ban, systemd-юниты, health/maintenance-скрипты, DNS-проверки, `/etc/hosts` и сетевые параметры VPS. Используйте его на чистом VPS, а не на сервере, где уже работают важные сервисы.

## Что нового в v1.3.5

Версия **v1.3.5** — крупное обновление архитектуры, UX и обслуживания:

- новый основной интерфейс управления: `sudo <prefix>-xpam`;
- обновлённый fresh-install UX без старой схемы профилей;
- VLESS через 3x-ui/Xray;
- Telegram proxy / MTG через 3x-ui;
- единый просмотр данных подключения через `sudo <prefix>-links`;
- DoubleHop Mode для маршрутизации выбранного трафика через Exit-сервер;
- режимы DoubleHop: VLESS only, Telegram only, VLESS + Telegram;
- WARP через 3x-ui/Xray как optional outbound;
- backend-aware health/deep-health, repair и weekly maintenance;
- оптимизации для небольших VPS;
- безопасное self-update через GitHub Releases с SHA256-проверкой, staging preflight, backup и rollback.

## Поддерживаемые ОС

XPAM Script v1.3.5 предназначен для чистых VPS на:

- **Ubuntu 24.04 LTS**;
- **Debian 12**.

Проверено на Ubuntu 24.04 LTS и Debian 12: установка, управление сервером, VLESS, Telegram proxy / MTG, DoubleHop Mode, диагностика, восстановление и безопасное обновление.

## Как это устроено

XPAM Script не заменяет 3x-ui и не пытается быть вторым web-panel. Он устанавливает и настраивает 3x-ui/Xray, nginx, HAProxy и системную обвязку, а затем даёт простой CLI-интерфейс для типовых операций.

Обычно публичный вход остаётся на HTTPS/TLS `443/tcp`. HAProxy принимает внешний трафик, направляет его в нужный backend, nginx отвечает за masking/fallback, а 3x-ui/Xray обслуживает VLESS, Telegram proxy / MTG и маршрутизацию.

## Быстрый старт

1. Подготовьте чистый VPS на Ubuntu 24.04 LTS или Debian 12.
2. Настройте DNS A-записи для доменов, которые будете использовать с XPAM.
3. Убедитесь, что у сервера есть IPv4-адрес и доступ по SSH.
4. Скачайте актуальный релиз XPAM Script из GitHub Releases.
5. Запустите установку по инструкции из релиза.
6. После создания prefix-команды используйте основное меню:

```bash
sudo <prefix>-xpam
```

В первый запуск обычно используются пункты:

```text
0) SSH-безопасность / создать prefix-команду
1) Установить / продолжить настройку сервера
```

После установки это же меню остаётся основным интерфейсом управления сервером.

## Основные команды

```bash
sudo <prefix>-xpam                 # основное меню управления XPAM
sudo <prefix>-links                # безопасная сводка без вывода секретов
sudo <prefix>-links --show-secrets # все данные подключения
sudo <prefix>-health               # быстрая проверка состояния
sudo <prefix>-health --deep        # расширенная проверка
sudo <prefix>-vless                # VLESS-информация и операции
sudo <prefix>-repair               # восстановление XPAM-обвязки
sudo <prefix>-netdiag              # диагностика сети
```

`<prefix>` выбирается при настройке сервера. Например, если выбран prefix `my`, основной командой будет `sudo my-xpam`.

## VLESS

XPAM настраивает VLESS через 3x-ui/Xray и хранит подключение как часть единой конфигурации сервера.

Полные данные подключения доступны через:

```bash
sudo <prefix>-links --show-secrets
```

VLESS links формируются из текущей конфигурации 3x-ui. Если вы добавили, удалили или изменили VLESS-клиента в 3x-ui, повторно запустите эту команду и используйте актуальную ссылку из вывода.

Обычная команда без `--show-secrets` не печатает секреты и подходит для безопасной диагностики:

```bash
sudo <prefix>-links
```

## Telegram proxy / MTG

XPAM v1.3.5 использует Telegram proxy / MTG через 3x-ui. Пользователю не нужна отдельная команда для Telegram: Telegram link показывается вместе с остальными данными подключения.

```bash
sudo <prefix>-links --show-secrets
```

Telegram link формируется из текущей конфигурации 3x-ui. Если вы вручную изменили Telegram proxy / MTG secret в 3x-ui, старая Telegram link перестанет работать, а актуальную ссылку нужно взять из нового вывода `sudo <prefix>-links --show-secrets`.

В пользовательской документации v1.3.5 используются термины **Telegram proxy / MTG** и **Telegram link**.

## DoubleHop Mode

**DoubleHop Mode** позволяет настроить Entry-сервер так, чтобы выбранный трафик выходил через другой сервер.

Доступные режимы:

- VLESS only;
- Telegram only;
- VLESS + Telegram.

Важные свойства:

- XPAM настраивает только Entry-сервер;
- Exit-сервер пользователь подготавливает отдельно;
- для включения DoubleHop пользователь вставляет VLESS-ссылку Exit-сервера;
- текущие VLESS и Telegram links на Entry-сервере не меняются при включении, изменении режима или выключении DoubleHop.

DoubleHop Mode доступен в основном меню:

```bash
sudo <prefix>-xpam
```

## WARP через 3x-ui/Xray

XPAM поддерживает WARP как optional Xray outbound. Это не системный VPN для всего сервера, а управляемый outbound внутри 3x-ui/Xray. Управление доступно из XPAM-меню.

## Health, repair и maintenance

Быстрая проверка:

```bash
sudo <prefix>-health
```

Расширенная проверка:

```bash
sudo <prefix>-health --deep
```

Восстановление XPAM-обвязки:

```bash
sudo <prefix>-repair
```

Weekly maintenance настраивается автоматически. Он поддерживает служебную обвязку, не должен менять пользовательские links и не должен ломать активные режимы работы.

## Безопасное обновление

В v1.3.5 добавлено безопасное обновление через XPAM:

- проверка информации о релизе;
- скачивание архива и `.sha256`;
- SHA256-проверка до распаковки;
- staging preflight;
- backup перед изменениями;
- post-update health/deep-health;
- rollback при ошибке.

Обновление запускается вручную:

```bash
sudo <prefix>-xpam
```

Раздел: `Дополнительно` → `Проверить обновления XPAM`.

## Секреты

Не публикуйте:

- VLESS links;
- Telegram links;
- Exit VLESS link для DoubleHop;
- UUID, tokens, private keys;
- содержимое `/etc/xpam-script/config.env`;
- вывод `sudo <prefix>-links --show-secrets`.

Для issue и bug reports используйте только отредактированные логи с заменёнными доменами, IP-адресами, UUID и ссылками.

## Документация

- [`docs/INSTALLATION.md`](docs/INSTALLATION.md) — установка;
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — архитектура;
- [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) — конфигурация;
- [`docs/PROFILES.md`](docs/PROFILES.md) — режимы работы;
- [`docs/HEALTHCHECKS.md`](docs/HEALTHCHECKS.md) — проверки состояния;
- [`docs/MAINTENANCE.md`](docs/MAINTENANCE.md) — обслуживание;
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — диагностика проблем;
- [`docs/SECURITY_MODEL.md`](docs/SECURITY_MODEL.md) — модель безопасности;
- [`SECURITY.md`](SECURITY.md) — правила безопасности проекта;
- [`THIRD_PARTY.md`](THIRD_PARTY.md) — сторонние компоненты.

## Лицензия

XPAM Script распространяется под MIT License. Сторонние компоненты сохраняют собственные лицензии. Подробнее: [`THIRD_PARTY.md`](THIRD_PARTY.md).
