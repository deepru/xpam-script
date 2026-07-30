# Testing

XPAM Script прошёл полное тестирование на:

- Ubuntu;
- Debian.

Проверено на Ubuntu и Debian: установка, управление сервером, VLESS, Telegram proxy / MTG, DoubleHop Mode, диагностика, восстановление и безопасное обновление.

## Проверенные пользовательские сценарии

- установка на чистый VPS;
- создание и использование основной команды `sudo <prefix>-xpam`;
- получение данных подключения через `sudo <prefix>-links` и краткой сводки через `sudo <prefix>-links --safe`;
- VLESS-подключение;
- отображение VLESS links из текущей конфигурации 3x-ui;
- Telegram proxy / MTG-подключение;
- отображение Telegram link из текущей конфигурации 3x-ui;
- ручная смена Telegram proxy / MTG secret в 3x-ui и повторное получение актуальной Telegram link;
- DoubleHop Mode: включение, изменение режима и выключение;
- сохранение VLESS и Telegram links при изменении DoubleHop Mode;
- WARP через 3x-ui/Xray: автоматическая регистрация, смена выходного адреса, отключение;
- запасной транспорт VLESS (xhttp/grpc): включение, переключение, выключение, сохранение основного подключения;
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
sudo <prefix>-links --safe
```

`sudo <prefix>-links` показывает актуальные VLESS/Telegram links из текущей конфигурации 3x-ui и содержит приватные данные. `sudo <prefix>-links --safe` печатает краткую сводку без секретов.

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
