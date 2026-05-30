# XPAM Script — текущая проверочная матрица

Этот файл фиксирует текущий проверенный статус основной ветки проекта после публичного релиза v1.1.1.

Подробные описания конкретных релизов находятся в [GitHub Releases](https://github.com/deepru/xpam-script/releases).

## Проверенная матрица

```text
Ubuntu 24.04 LTS / Profile 1 / VLESS only direct TLS        PASS
Debian 12        / Profile 3 / root + VLESS + MTProto       PASS
Ubuntu 24.04 LTS / Profile 2 / VLESS + MTProto              PASS
```

## Проверенные сценарии

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

## Публичная IPv4-only policy

XPAM-managed публичные сервисы должны использовать IPv4 для публичных портов `22/80/443`.

IPv6 может оставаться включённым в системе для локального или внутреннего использования, но XPAM-managed публичные сервисы не должны слушать `22/80/443` по IPv6.

## Примечания

- `CHANGELOG.md` является основным накопительным changelog.
- `SECURITY.md` описывает актуальную политику поддержки.
- `docs/USER_GUIDE_RU.pdf` и `docs/USER_GUIDE_RU.docx` являются пользовательской инструкцией.
- GitHub Releases являются источником подробных release notes для конкретных версий.
