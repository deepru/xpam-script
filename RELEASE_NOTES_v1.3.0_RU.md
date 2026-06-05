# XPAM Script v1.3.0

XPAM Script v1.3.0 — крупный технический релиз, в котором усилены совместимость с актуальными версиями 3x-ui, диагностика, восстановление конфигурации, WARP-управление, MTProto-профили и финальная проверка установленных серверов.

## Главное

- Переработана внутренняя структура XPAM Script: часть логики вынесена из монолитного ядра в отдельные helper-слои.
- Добавлена основа compatibility layer для 3x-ui.
- Исправлена работа с API token в новых версиях 3x-ui, где токен доступен в открытом виде только один раз при создании.
- Улучшены repair/runtime refresh-механизмы.
- Усилены health и deep-health проверки.
- Добавлены WARP normalize и WARP disable/reset.
- Усилен MTProto-режим для HAProxy-профилей.
- Улучшены Telegram notifications и HTTPS Telegram Relay.
- Проведена финальная release QA-проверка на Ubuntu 24.04 и Debian 12.

## Внутренняя структура и сопровождение

В v1.3.0 внутренняя логика XPAM Script была разнесена по более понятным слоям. Это касается core runtime, 3x-ui integration, health/deep-health, repair, WARP, Telegram notifications и profile-specific behavior.

Такая структура упрощает дальнейшее сопровождение проекта и снижает риск регрессий при будущих изменениях.

## 3x-ui compatibility layer

Добавлена основа отдельного compatibility layer для 3x-ui. XPAM Script не пытается заменить 3x-ui и не запрещает пользователю обновлять его через панель. Вместо этого XPAM усиливает проверку собственной серверной схемы вокруг 3x-ui/Xray.

Что улучшено:

- обработка API token для новых версий 3x-ui;
- сохранение usable token в root-only файл с правами `0600`;
- Bearer-проверка токена в health/deep-health;
- проверка SQLite backend;
- проверка схемы базы 3x-ui;
- проверка inbound, stream settings, TLS, fallback, external proxy и generated Xray config;
- более аккуратное восстановление runtime и helper-команд через repair.

## Repair и runtime refresh

Repair теперь обновляет установленный runtime и helper-команды более последовательно. Это важно для случаев, когда сам архив уже обновлён, но на сервере могли остаться старые menu/runtime-файлы.

Проверяются и обновляются:

- `/opt/xpam-script`;
- profile-prefixed install launcher;
- health/deep-health;
- repair;
- network diagnostics;
- connection-data commands;
- VLESS/MTProto helper commands;
- weekly maintenance.

## Reboot gate

Усилена проверка необходимости перезагрузки после обновления пакетов. Перед финализацией установки XPAM дополнительно проверяет:

- стандартный reboot marker;
- список пакетов, требующих reboot;
- совпадение running kernel и newest installed kernel;
- sensitive package upgrade markers.

## Health и deep-health

Обычный health стал компактнее для ежедневной проверки состояния сервера.

Полная диагностика остаётся в:

```bash
sudo <prefix>-health --deep
```

Deep-health проверяет больше деталей:

- systemd services;
- firewall/UFW policy;
- public port exposure;
- 3x-ui/Xray database and generated config;
- API token;
- TLS certificates;
- HAProxy/MTProto startup order;
- MTProto invariants;
- optional WARP state;
- DNS/provider behavior;
- service hygiene;
- config snapshot freshness;
- swap policy;
- kernel/reboot status;
- network tuning;
- file descriptor limits.

## HAProxy and MTProto profiles

Для HAProxy/MTProto-профилей усилены startup order и backend validation.

HAProxy ждёт локальные Xray и MTProto backends, а MTProto ждёт локальный nginx sync backend. Это делает старт сервисов более последовательным после установки, repair и перезагрузки.

MTProto-профили также получили более строгие invariants:

- MTProto backend работает локально;
- публичный вход идёт через HAProxy на 443;
- используется TLS-only mode;
- mask backend проверяется отдельно;
- IPv4-first behavior задан явно;
- deep-health проверяет MTProto без вывода секретов.

## WARP через 3x-ui/Xray

WARP остаётся optional-функцией внутри Xray и настраивается через 3x-ui.

В v1.3.0 улучшены два сценария:

- **WARP normalize** — XPAM проверяет созданный в 3x-ui WARP outbound и приводит XPAM-managed WARP state к совместимому состоянию для выбранного профиля.
- **WARP disable/reset** — XPAM может отключить XPAM-managed WARP state и вернуть VLESS/sniffing/routing поведение к штатному baseline текущего профиля.

Для direct VLESS профиля штатное состояние — Route-only sniffing.
Для HAProxy/MTProto профилей после WARP reset sniffing возвращается в OFF.

Перед изменениями XPAM создаёт backup базы 3x-ui.

## Telegram notifications and HTTPS Relay

Улучшены Telegram notifications:

- direct notifications;
- relay-client mode;
- HTTPS Telegram Relay server mode;
- проверка уже сохранённых настроек;
- защита от вывода секретов.

Relay-server mode отображается только в профилях, где сервер может безопасно принять relay-запрос через существующую HTTPS/443 поверхность. Для direct VLESS профиля этот пункт больше не показывается, чтобы не путать пользователя.

Для HTTPS Relay добавлены health checks:

- service active;
- Unix socket exists;
- request without token returns HTTP 401;
- GET with token returns HTTP 405;
- отдельный публичный порт для Relay не открывается.

## Maintenance and cleanup

Улучшены weekly maintenance и final production cleanup:

- guarded apt operations;
- dpkg audit checks;
- certbot renew check;
- config snapshots;
- snapshot retention;
- cleanup retention;
- apt cache cleanup;
- journal cleanup;
- post-maintenance quick health;
- final production cleanup from the menu.

Финальная production-очистка доступна в меню:

```text
7) Дополнительно
4) Финальная production-очистка
```

## Public exposure policy

XPAM Script v1.3.0 сохраняет существующую IPv4-first модель:

- публичные TCP-порты XPAM-managed схемы: `22/80/443`;
- backend-сервисы остаются на loopback;
- отдельные публичные порты для 3x-ui, Xray backend, MTProto backend или Telegram Relay не открываются;
- публичные IPv6 listeners на XPAM-managed public ports не входят в поддерживаемый контракт этого релиза.

## Tested release matrix

Финальная релизная линия была проверена на следующих сценариях:

- Ubuntu 24.04 / Profile 1 — PASS;
- Debian 12 / Profile 3 — PASS;
- Debian 12 / Profile 2 — PASS на той же кодовой базе перед финальной сборкой.

Финальный архив с SHA256 `7efeb82fcc856c2ffb6155cbd94265d668944eb2e1c1ce87d98f06ad41e0987f` дополнительно прошёл post-build validation на Profile 1 и Profile 3. Эта матрица закрывает direct VLESS-профиль, separate-subdomain HAProxy/MTProto-профиль и полную HAProxy/MTProto/root-site схему.

Проверялись:

- установка на чистую ОС;
- health;
- deep-health;
- weekly maintenance;
- final production cleanup;
- VLESS;
- MTProto;
- Telegram notifications;
- HTTPS Telegram Relay;
- WARP enable/normalize;
- WARP disable/reset;
- profile-specific sniffing behavior;
- service hygiene;
- DNS/provider compatibility;
- reboot/kernel checks.

## Archive

Final archive:

```text
xpam-script-v1.3.0-ubuntu24-debian12.tar.gz
```

SHA256:

```text
7efeb82fcc856c2ffb6155cbd94265d668944eb2e1c1ce87d98f06ad41e0987f
```
