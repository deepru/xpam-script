# XPAM Script

**XPAM Script** — Bash-автоматизация для подготовки чистого VPS на **Ubuntu 24.04 LTS** или **Debian 12** под HTTPS/TLS-схему с VLESS, 3x-ui/Xray, MTProto, nginx, HAProxy, Certbot, UFW, fail2ban, health-check и регулярным обслуживанием.

Актуальный публичный релиз: **v1.1.0**.

Проект не является форком 3x-ui, Xray-core или MTProto proxy. XPAM Script устанавливает, связывает, настраивает, проверяет и обслуживает эти upstream-компоненты.

> **Важно:** XPAM Script не обещает анонимность, неуязвимость или “невидимость”. Пользователь отвечает за законность использования, безопасность своих ключей и корректную DNS-настройку.

---

## Что делает XPAM Script

- включает SSH-вход только по ключу;
- нормализует hostname и `/etc/hosts`, чтобы `sudo` не ругался на hostname провайдера;
- настраивает UFW и fail2ban;
- создаёт nginx-сайты и HTTPS-поверхность;
- получает сертификаты Let's Encrypt через Certbot;
- устанавливает 3x-ui и Xray/VLESS;
- опционально настраивает MTProto через HAProxy SNI routing;
- опционально настраивает Telegram-уведомления и HTTPS Relay;
- опционально проверяет WARP outbound внутри 3x-ui/Xray;
- создаёт health-check, weekly maintenance, repair и netdiag команды;
- очищает установочные хвосты и держит сервер компактным.

---

## Поддерживаемые профили

| Профиль | Назначение |
|---|---|
| `vless_direct` | VLESS/Xray и панель 3x-ui без MTProto и HAProxy |
| `subdomains_mtproto` | VLESS и MTProto на отдельных поддоменах через HAProxy |
| `root_mtproto` | основной сайт, `www` redirect, VLESS-домен и MTProto-домен |

---

## Порты

Публично ожидаются только:

```text
22/tcp   SSH
80/tcp   HTTP / ACME
443/tcp  HTTPS/TLS surface
```

Внутренние сервисы слушают `127.0.0.1`: панель 3x-ui, Xray/VLESS, nginx fallback, nginx sync backend, MTProto proxy и служебные backend-порты.

XPAM Script работает по IPv4-first схеме. Для доменов проекта создавайте только `A`-записи на IPv4 VPS. `AAAA`-записи для этих доменов перед установкой нужно удалить.

---

## Установка

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh -o xpam-bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

После запуска сначала выберите пункт `0` для SSH-безопасности и создания prefix-команды, затем пункт `1` для установки.

---

## Основное меню

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

После шага 0 пользователь работает через свои prefix-команды. Если prefix = `srv`, команды будут `sudo srv-install`, `sudo srv-health`, `sudo srv-links` и так далее.

---

## Команды после установки

```text
sudo <prefix>-install       главное меню
sudo <prefix>-health        быстрая проверка сервера
sudo <prefix>-health --deep подробная диагностика
sudo <prefix>-links         безопасная сводка без секретов
sudo <prefix>-vless         информация по VLESS без вывода ссылки
sudo <prefix>-telega        информация по MTProto без вывода секретов
sudo <prefix>-netdiag       диагностика сети/DNS, ничего не чинит автоматически
sudo <prefix>-repair        восстановление XPAM-обвязки
```

Секреты не печатаются по умолчанию. Для осознанного вывода используются `--show` или `--show-secrets`.

---

## Документация

- [`docs/USER_GUIDE_RU.pdf`](docs/USER_GUIDE_RU.pdf) — полное руководство пользователя на русском.
- [`docs/USER_GUIDE_RU.docx`](docs/USER_GUIDE_RU.docx) — редактируемая версия руководства.
- [`docs/`](docs/) — технические документы проекта.

---

## Лицензия и сторонние компоненты

XPAM Script распространяется под MIT License.

3x-ui, Xray-core, alexbers/mtprotoproxy, nginx, HAProxy, Certbot, UFW, fail2ban, systemd и другие компоненты сохраняют собственные лицензии. Подробнее: [`THIRD_PARTY.md`](THIRD_PARTY.md).
