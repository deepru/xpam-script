# XPAM Script v1.3.5

**XPAM Script v1.3.5** — крупный релиз, который переводит проект на новую пользовательскую архитектуру: единое XPAM-меню, Telegram proxy / MTG через 3x-ui, DoubleHop Mode, оптимизации для небольших VPS и безопасное обновление через XPAM.

Релиз ориентирован на чистые VPS с Ubuntu 24.04 LTS и Debian 12.

## Главное

- Новый основной интерфейс управления: `sudo <prefix>-xpam`.
- Актуальная fresh-install схема без старой пользовательской модели профилей.
- VLESS через 3x-ui/Xray.
- Telegram proxy / MTG через 3x-ui.
- Единая команда для данных подключения: `sudo <prefix>-links`.
- DoubleHop Mode.
- Safe self-update через GitHub Releases.
- Small-VM оптимизации для слабых VPS.
- Backend-aware health/deep-health, repair и weekly maintenance.

## Новый интерфейс управления

Основная команда теперь:

```bash
sudo <prefix>-xpam
```

Через неё доступны установка, проверка состояния, WARP, DoubleHop Mode, управление сайтами и дополнительные операции.

Команда для данных подключения:

```bash
sudo <prefix>-links
sudo <prefix>-links --show-secrets
```

Обычная команда показывает безопасную сводку без секретов. Полная команда печатает VLESS и Telegram links и должна использоваться аккуратно.

VLESS и Telegram links в полной выдаче строятся из текущей конфигурации 3x-ui. Если пользователь меняет VLESS-клиента или Telegram proxy / MTG secret в 3x-ui, актуальные ссылки нужно заново взять через `sudo <prefix>-links --show-secrets`.

## Telegram proxy / MTG через 3x-ui

В v1.3.5 Telegram proxy / MTG работает через 3x-ui. Пользователю больше не нужна отдельная команда для Telegram: Telegram link находится в общей выдаче `sudo <prefix>-links --show-secrets`.

Telegram link берётся из текущей конфигурации 3x-ui. После ручной смены Telegram proxy / MTG secret в 3x-ui старая Telegram link перестаёт работать, а новая ссылка отображается в `sudo <prefix>-links --show-secrets`.

Health, deep-health, repair и weekly maintenance учитывают текущий Telegram proxy / MTG backend и не должны менять пользовательские links.

## DoubleHop Mode

DoubleHop Mode позволяет использовать два XPAM-сервера: основной сервер принимает текущие VLESS/Telegram links, а выбранный трафик выпускает через второй XPAM-сервер.

Доступные режимы:

- VLESS only;
- Telegram only;
- VLESS + Telegram.

Как это работает:

- установите XPAM на обоих серверах обычным способом;
- на втором сервере откройте `sudo <prefix>-links --show-secrets` и возьмите VLESS-ссылку;
- на основном сервере откройте `sudo <prefix>-xpam` → `DoubleHop Mode` и вставьте VLESS-ссылку второго сервера;
- текущие VLESS и Telegram links основного сервера не меняются при включении, изменении режима или выключении DoubleHop.

## Small-VM оптимизации

v1.3.5 содержит настройки и проверки, которые делают эксплуатацию безопаснее на небольших VPS:

- более аккуратная политика journald;
- logrotate policy для XPAM-логов;
- preflight-проверки ресурсов;
- защита от проблем с package-manager состоянием;
- ограничение накопления служебных backup-файлов.

## Safe self-update

Обновление XPAM теперь выполняется через безопасный manual flow:

1. проверка доступного релиза;
2. скачивание архива и `.sha256`;
3. SHA256-проверка до распаковки;
4. staging extract;
5. static preflight;
6. backup текущей установки и служебных команд;
7. apply;
8. health/deep-health postcheck;
9. rollback при ошибке.

Updater не должен печатать секреты в лог и не должен менять VLESS/Telegram links.

## Проверка релиза

Проверено на Ubuntu 24.04 LTS и Debian 12: установка, управление сервером, VLESS, Telegram proxy / MTG, DoubleHop Mode, диагностика, восстановление и безопасное обновление.

## Совместимость и поддержка

Для новых установок используйте актуальный релиз v1.3.5 или новее. Документация и поддерживаемый install path ориентированы на текущую архитектуру XPAM.

## Секреты

Не публикуйте:

- VLESS links;
- Telegram links;
- Exit VLESS link для DoubleHop;
- UUID, tokens, private keys;
- вывод `sudo <prefix>-links --show-secrets`;
- содержимое `/etc/xpam-script/config.env`.
