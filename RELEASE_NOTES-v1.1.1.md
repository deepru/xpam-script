# XPAM Script v1.1.1

XPAM Script v1.1.1 — точечный production hotfix для корректной публичной IPv4-only схемы, direct VLESS profile, health-check и 3x-ui External Proxy.

Это не крупная переделка архитектуры. Релиз закрывает конкретную проблему, найденную на реальных VPS-образах: в профиле VLESS only Xray мог фактически слушать публичный `443` через wildcard/dual-stack поведение, из-за чего сервер работал для IPv4-клиентов, но health/deep-health справедливо видел риск публичного IPv6 listener. Теперь direct VLESS привязывается к реальному публичному IPv4-адресу сервера.

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

Перед установкой обязательно прочитайте инструкцию пользователя из release assets.

---

## Что исправлено

### Direct VLESS / Profile 1

В профиле `VLESS only, direct TLS` Xray/VLESS inbound теперь слушает не пустой wildcard listen, а конкретный публичный IPv4-адрес текущего VPS.

Итоговая модель:

```text
public IPv4 SERVER_IP:443 -> Xray/VLESS
public IPv6 22/80/443     -> не используется XPAM-managed сервисами
```

Это устраняет provider/OS-dependent ситуацию, когда `ss` мог показывать wildcard/dual-stack listener на `*:443`.

### Repair для уже установленных direct VLESS серверов

Repair умеет аккуратно нормализовать XPAM-managed direct VLESS inbound:

- не меняет UUID;
- не меняет клиентов;
- не меняет TLS-сертификаты;
- не меняет fallback;
- не меняет WARP;
- не меняет Telegram Relay;
- не меняет nginx, HAProxy и MTProto;
- исправляет только XPAM-managed listener/external proxy contract там, где это нужно.

### Health/deep-health

Health-check стал точнее разделять IPv4 и IPv6 listener checks.

Теперь:

- публичные IPv4 listeners проверяются отдельно;
- публичные IPv6 listeners проверяются отдельно;
- XPAM-managed публичные порты `22/80/443` не должны слушать IPv6;
- публичный IPv6 listener на XPAM-managed `22/80/443` считается FAIL;
- TLS-проверка direct VLESS выполняется через найденный публичный IPv4 endpoint.

### Weekly / service hygiene

Добавлена точечная очистка stale failed-state только для XPAM-managed hygiene units после stop/disable/mask действий.

Это закрывает ложный FAIL вида:

```text
fwupd-refresh.service masked failed failed
```

Важно: глобальный `systemctl reset-failed` не используется. Реальные failed units не маскируются.

### 3x-ui External Proxy

External Proxy теперь нормализуется для XPAM-managed VLESS inbound во всех профилях.

Это нужно, чтобы 3x-ui генерировал клиентские ссылки через публичный домен и порт:

```text
vless-domain:443
```

а не через локальный backend, IP/listen или внутренний порт.

Модель по профилям:

```text
Profile 1:
  Xray слушает SERVER_PUBLIC_IPV4:443
  External Proxy указывает на VLESS_DOMAIN:443

Profile 2/3:
  HAProxy слушает public IPv4 443
  Xray слушает 127.0.0.1:1443
  External Proxy указывает на VLESS_DOMAIN:443
```

---

## Что не менялось

В релизе специально не менялись:

- стратегия установки 3x-ui;
- HAProxy TCP/SNI routing;
- MTProto routing;
- nginx fallback layout;
- WARP через 3x-ui/Xray;
- Telegram Relay;
- DNS safe mode;
- weekly maintenance architecture;
- production cleanup architecture;
- модель хранения секретов в `/root/secure-notes`.

IPv6 глобально не отключается. Он может оставаться включённым в системе для локальных/внутренних задач, но XPAM-managed публичные порты `22/80/443` должны оставаться IPv4-only.

---

## Проверенный статус

Релиз проверен на чистых VPS:

```text
Ubuntu 24.04 LTS / Profile 1 / VLESS only direct TLS        PASS
Debian 12        / Profile 3 / root + VLESS + MTProto       PASS
Ubuntu 24.04 LTS / Profile 2 / VLESS + MTProto              PASS
```

Проверены:

- clean install;
- quick health;
- deep health;
- weekly maintenance;
- health after weekly;
- `systemctl --failed = 0`;
- IPv4 listener policy;
- отсутствие public IPv6 listener на XPAM-managed `22/80/443`;
- VLESS подключение;
- MTProto подключение;
- 3x-ui External Proxy;
- TLS/SNI/certificate checks;
- HAProxy + Xray local backend;
- nginx fallback;
- Telegram HTTPS Relay endpoints;
- service hygiene.

---

## Release assets

Загрузите из раздела Assets:

```text
xpam-script-v1.1.1-ubuntu24-debian12.tar.gz
xpam-script-v1.1.1-ubuntu24-debian12.tar.gz.sha256
XPAM_Script_USER_GUIDE_RU_final.pdf
XPAM_Script_USER_GUIDE_RU_final.docx
```

Пользовательская установка через bootstrap остаётся основным способом установки.

---

## Важное перед использованием

XPAM Script рассчитан на чистый VPS.

Перед запуском:

- подготовьте SSH-ключ;
- проверьте вход по SSH-ключу до шага 0;
- подготовьте DNS A-записи на IPv4 VPS;
- не используйте AAAA-записи для XPAM-managed доменов;
- убедитесь, что публичные TCP-порты `22/80/443` доступны;
- не запускайте установку на сервере с важными чужими production-конфигурациями nginx/HAProxy/Xray.

---

## Для уже установленных серверов

Если сервер был установлен предыдущей версией и используется profile 1 / direct VLESS, после обновления комплекта рекомендуется выполнить repair через меню:

```text
7) Дополнительно
3) Repair: восстановить XPAM service policy
```

или командой:

```bash
sudo <prefix>-repair
```

Repair не должен менять пользовательские VLESS-клиенты, UUID, MTProto secrets, WARP routing, Telegram Relay и сайты.

