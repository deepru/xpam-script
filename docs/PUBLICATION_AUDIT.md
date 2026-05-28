# XPAM Script v1.1.0 publication audit

Дата публикации: 2026-05-28

Релиз: `v1.1.0`

GitHub repository: `deepru/xpam-script`

Release assets:

- `xpam-script-v1.1.0-ubuntu24-debian12.tar.gz`
- `xpam-script-v1.1.0-ubuntu24-debian12.tar.gz.sha256`

## Результат

XPAM Script v1.1.0 опубликован как GitHub Release и проверен через GitHub bootstrap.

Проверено:

- tag `v1.1.0` опубликован;
- branch `main` обновлён;
- release assets загружаются с GitHub;
- SHA256-проверка архива проходит успешно;
- bootstrap скачивает именно `v1.1.0`;
- installer запускается как `XPAM Script v1.1.0`;
- рабочий сервер после bootstrap-проверки остаётся healthy.

## Проверенные системы

- Ubuntu 24.04 LTS
- Debian 12

## Проверенные области

- SSH hardening;
- prefix-команды;
- установка и продолжение установки после reboot;
- DNS safe mode;
- Debian 12 provider/minimal VPS behavior;
- `/etc/hosts` и hostname normalization;
- fail2ban systemd backend;
- UFW policy;
- nginx;
- HAProxy;
- Certbot / Let's Encrypt;
- 3x-ui / Xray;
- VLESS;
- MTProto;
- Telegram notifications;
- Telegram HTTPS Relay;
- WARP через Xray outbound;
- quick health;
- deep health;
- production cleanup;
- safe output для команд подключения.

## Public sanitation

Перед публикацией проверено отсутствие:

- личных доменов;
- личных IP-адресов;
- приватных email;
- токенов;
- паролей;
- VLESS/MTProto ссылок;
- WARP private keys;
- Telegram bot tokens;
- dev/test-хвостов;
- тестовых hostname/prefix;
- hardcoded пользовательских prefix-команд.

В публичных документах команды указываются через универсальный формат:

```text
sudo <prefix>-install
sudo <prefix>-health
sudo <prefix>-links
sudo <prefix>-vless
sudo <prefix>-telega
sudo <prefix>-netdiag
sudo <prefix>-repair
```

Допускаются только обезличенные учебные примеры prefix, например `srv`.

## Документация

К релизу приложена обновлённая русская инструкция:

- `docs/USER_GUIDE_RU.pdf`
- `docs/USER_GUIDE_RU.docx`

README и release notes обновлены так, чтобы пользователь понимал:

- что делает XPAM Script;
- какие компоненты он устанавливает;
- какие части VPS меняет;
- почему перед запуском нужно прочитать инструкцию;
- какие команды доступны после установки;
- что можно и нельзя делать на сервере.

## Итог

Релиз `v1.1.0` готов к публичному использованию.

Статус:

```text
Ubuntu 24.04 LTS: PASS
Debian 12: PASS
GitHub Release: PASS
GitHub bootstrap: PASS
Documentation: PASS
```
