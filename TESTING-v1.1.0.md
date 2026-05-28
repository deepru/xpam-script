# XPAM Script v1.1.0 — проверка релизной сборки

Этот файл фиксирует проверочный статус релиза v1.1.0 перед публикацией на GitHub.

## Проверенные системы

- Ubuntu 24.04 LTS
- Debian 12

Обе системы проверялись на чистой VPS-установке с нуля.

## Проверенные сценарии

- Шаг 0: SSH-безопасность, вход по ключу и создание prefix-команды.
- Шаг 1: полная установка и финальная настройка сервера.
- Быстрая проверка: `sudo <prefix>-health`.
- Подробная проверка: `sudo <prefix>-health --deep`.
- Состояние systemd: 0 failed units.
- SSH policy: password login disabled, key-only root login allowed.
- UFW policy: публично открыты только IPv4 TCP 22/80/443.
- DNS safe mode: рабочий DNS провайдера принимается и не переписывается.
- Нормализация `/etc/hosts`: hostname сервера резолвится, управляемые домены не привязаны к localhost.
- fail2ban: systemd backend, jail `sshd`.
- Certbot: сертификаты выпущены, `certbot.timer` активен.
- nginx, HAProxy, 3x-ui/Xray, VLESS, MTProto.
- Telegram-уведомления: direct mode и HTTPS Relay.
- WARP через 3x-ui/Xray: WireGuard outbound внутри Xray без системного `warp-cli`.
- Production cleanup: временные файлы удалены, секреты и резервные копии сохранены.
- Команды подключения безопасны по умолчанию и не печатают секреты без явного `--show` или `--show-secrets`.

## Проверенные пользовательские команды

- `sudo <prefix>-install`
- `sudo <prefix>-health`
- `sudo <prefix>-health --deep`
- `sudo <prefix>-links`
- `sudo <prefix>-vless`
- `sudo <prefix>-telega`
- `sudo <prefix>-netdiag`
- `sudo <prefix>-repair`

## Итог

Ubuntu 24.04 LTS: PASS.

Debian 12: PASS.

Релиз v1.1.0 готов к публикации при условии, что финальный архив и GitHub Release используют те же файлы, которые прошли проверку.
