# Testing

XPAM Script v1.3.6 прошёл полное тестирование на:

- Ubuntu 24.04 LTS;
- Debian 12.

Проверено на Ubuntu 24.04 LTS и Debian 12: установка, управление сервером, VLESS, Telegram proxy / MTG, DoubleHop Mode, диагностика, восстановление и безопасное обновление.

## Проверенные пользовательские сценарии

- установка на чистый VPS;
- создание и использование основной команды `sudo <prefix>-xpam`;
- получение безопасной сводки через `sudo <prefix>-links`;
- получение полных данных подключения через `sudo <prefix>-links --show-secrets`;
- VLESS-подключение;
- отображение VLESS links из текущей конфигурации 3x-ui;
- Telegram proxy / MTG-подключение;
- отображение Telegram link из текущей конфигурации 3x-ui;
- ручная смена Telegram proxy / MTG secret в 3x-ui и повторное получение актуальной Telegram link;
- DoubleHop Mode: включение, изменение режима и выключение;
- сохранение VLESS и Telegram links при изменении DoubleHop Mode;
- WARP через 3x-ui/Xray;
- health и deep-health проверки;
- repair-сценарии;
- weekly maintenance;
- network diagnostics;
- safe self-update через XPAM;
- rollback при ошибке обновления;
- small-VM политики: journald/logrotate, backup retention и preflight-проверки.

## Что пользователь может проверить после установки

```bash
sudo <prefix>-health
sudo <prefix>-health --deep
sudo <prefix>-links
sudo <prefix>-links --show-secrets
sudo <prefix>-netdiag
```

Обычная команда `sudo <prefix>-links` не должна печатать секреты. Полная команда с `--show-secrets` содержит приватные данные подключения и должна показывать актуальные VLESS/Telegram links из текущей конфигурации 3x-ui.

## Отчёты об ошибках

Перед публикацией issue удалите или замените:

- реальные домены;
- реальные IP-адреса;
- VLESS links;
- Telegram links;
- Exit VLESS links;
- UUIDs;
- tokens;
- private keys;
- содержимое `/etc/xpam-script/config.env`.
