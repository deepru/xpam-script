# XPAM Script

**XPAM Script** — это набор автоматизации, защиты и эксплуатационной подготовки VPS для **Ubuntu 24.04 LTS** и **Debian 12**.

Проект подготавливает сервер с контролируемой HTTPS/TLS-поверхностью и настраивает:

- вход по SSH-ключу;
- UFW и fail2ban;
- nginx-сайты;
- Let’s Encrypt сертификаты через Certbot;
- 3x-ui и Xray/VLESS;
- опциональный MTProto;
- опциональный HAProxy TCP/SNI routing;
- опциональную маршрутизацию WARP через 3x-ui/Xray;
- Telegram-уведомления;
- health-check и еженедельное обслуживание.

XPAM Script не является форком 3x-ui, Xray-core или MTProto proxy. Это Bash-обвязка для установки, настройки, проверки, обслуживания и интеграции upstream-компонентов.

> **Важное ограничение**  
> Проект не обещает анонимность, неуязвимость или “невидимость”. Пользователь сам отвечает за соблюдение законов, правил провайдера и корректное использование сервера.

---

## Основная идея

XPAM Script нужен, чтобы не собирать VPS “руками по памяти”, а каждый раз получать повторяемую и проверяемую схему:

- минимум публичных портов;
- сервисы на loopback;
- HTTPS/TLS-поверхность;
- нормальные сайты-заглушки;
- сертификаты;
- health-check;
- регулярное обслуживание;
- понятные команды с выбранным prefix.

---

## Поддерживаемые профили

| Профиль | Что делает |
|---|---|
| `vless_direct` | VLESS/Xray напрямую на публичном TLS-порту, без MTProto и HAProxy |
| `subdomains_mtproto` | VLESS и MTProto на отдельных поддоменах через HAProxy |
| `root_mtproto` | основной сайт, `www` redirect, VLESS-домен и MTProto-домен |

Домены должны быть заранее направлены на IPv4-адрес VPS.

---

## Публичные и внутренние порты

Публично ожидаются только:

```text
22/tcp   SSH
80/tcp   HTTP / ACME
443/tcp  HTTPS/TLS surface
```

Внутренние сервисы слушают `127.0.0.1`:

```text
3x-ui panel
Xray/VLESS
nginx fallback site
nginx sync TLS backend
MTProto proxy
```

В профилях с MTProto HAProxy принимает внешний `443` и маршрутизирует TCP-поток по SNI.

---

## Основная установка

Рекомендуемый GitHub Releases вариант:

```bash
curl -fsSL -o xpam-bootstrap.sh https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

Ручной вариант:

```bash
cd /root
sha256sum -c xpam-script-v1.0.10-ubuntu24-debian12.tar.gz.sha256

> **IPv4-first:** XPAM Script поддерживает установку только по IPv4. Для доменов проекта создавайте только `A`-записи на IPv4-адрес VPS. `AAAA`-записи для этих доменов нужно удалить до запуска установки: публичный IPv6-режим скриптом не поддерживается.

mkdir -p /root/xpam-install
tar -xzf xpam-script-v1.0.10-ubuntu24-debian12.tar.gz -C /root/xpam-install

KIT_DIR="$(find /root/xpam-install -maxdepth 3 -type f -name install.sh -printf '%h\n' | head -n1)"
cd "$KIT_DIR"
bash ./install.sh
```

---

## Меню

```text
0) Настроить SSH-безопасность
1) Установить / продолжить настройку сервера
2) Настроить / проверить Telegram уведомления
3) Настройка WARP
4) Управление сайтами
5) Показать данные для подключения
6) Проверить состояние сервера
7) Финальная / production-очистка
8) Показать текущую конфигурацию
9) Выход
```

Prefix задаётся на шаге `0`. После этого пользователь работает через:

```text
sudo <prefix>-install
sudo <prefix>-health
sudo <prefix>-links
sudo <prefix>-vless
sudo <prefix>-telega
```

`<prefix>` — это placeholder. Реальное значение выбирает пользователь.

---

## Документация

Технические документы находятся в [`docs/`](docs/).

Пользовательская инструкция на русском:

- [`docs/USER_GUIDE_RU.pdf`](docs/USER_GUIDE_RU.pdf)

---

## Лицензия и сторонние компоненты

XPAM Script распространяется под MIT License.

3x-ui, Xray-core, alexbers/mtprotoproxy, nginx, HAProxy, Certbot, UFW, fail2ban, systemd и другие компоненты сохраняют свои собственные лицензии. Подробно: [`THIRD_PARTY.md`](THIRD_PARTY.md).
