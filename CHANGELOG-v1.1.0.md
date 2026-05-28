# XPAM Script v1.1.0

XPAM Script v1.1.0 — стабильный релиз совместимости, безопасности, UX и документации для Ubuntu 24.04 LTS и Debian 12.

Релиз сохраняет рабочую архитектуру v1.0.10 и улучшает поведение на реальных VPS-образах разных провайдеров.

## Главное

- Стабильная IPv4-first установка для Ubuntu 24.04 LTS и Debian 12.
- Safe DNS mode: рабочий DNS провайдера принимается и не переписывается.
- Улучшена совместимость с Debian 12 minimal/provider images.
- Улучшена нормализация `/etc/hosts`: hostname сервера резолвится, а управляемые домены не попадают на localhost.
- fail2ban использует systemd backend.
- Публичная поверхность остаётся ограниченной IPv4 TCP 22/80/443.
- Команды подключения безопасны по умолчанию и не печатают секреты без явного запроса.
- Добавлены диагностика сети и repair-команда.
- Улучшена проверка WARP через 3x-ui/Xray.
- Усилена финальная production-очистка.
- Обновлена русская пользовательская инструкция для v1.1.0.

## Добавлено

- `sudo <prefix>-netdiag` — диагностика DNS, маршрутов, сетевых конфигов и provider-specific особенностей без автоматического ремонта.
- `sudo <prefix>-repair` — восстановление XPAM service policy, helper-команд, limits, health/weekly scripts, hooks и service hygiene.
- `sudo <prefix>-links --show-secrets` — осознанный вывод всех секретов после подтверждения.
- `sudo <prefix>-vless --show` — осознанный вывод VLESS-ссылок.
- `sudo <prefix>-telega --show` и `sudo <prefix>-telega --manage` — вывод MTProto-ссылок и управление MTProto-пользователями.
- `.gitattributes` — фиксация LF line endings для shell-скриптов и шаблонов в Git.
- Release notes и testing summary для v1.1.0.

## Изменено

- DNS policy по умолчанию переведён в safe mode.
- `sudo <prefix>-health` теперь показывает компактный summary.
- Подробная диагностика доступна через `sudo <prefix>-health --deep`.
- Health/weekly логи хранятся в `/var/log/xpam-script`.
- `sudo <prefix>-links`, `sudo <prefix>-vless`, `sudo <prefix>-telega` больше не печатают секреты по умолчанию.
- WARP-меню упрощено: убраны дублирующие варианты выхода.
- Health-check проверяет техническую форму WireGuard outbound, но не переписывает пользовательские routing rules.
- Финальная очистка удаляет временные установочные файлы и мусор, сохраняя secure-notes, backups и SSH-ключи.
- README и пользовательская инструкция обновлены под текущую структуру меню и safe-output поведение.

## Исправлено

- Проблемы Debian 12 minimal/provider VPS, где DNS и сетевое окружение отличаются от Ubuntu.
- fail2ban startup/backend проблемы на Debian.
- `sudo: unable to resolve host`, когда провайдерский hostname отсутствует в `/etc/hosts`.
- Случаи, когда managed domains могли оказаться привязанными к localhost.
- Лишние установочные/test-хвосты в `/root` после production cleanup.
- Слишком лёгкое случайное раскрытие VLESS/MTProto данных на экран.
- Шум health-check вокруг пользовательских WARP routing rules.

## Безопасность

- SSH password login отключается после шага 0.
- Root login остаётся доступным по SSH-ключу.
- XPAM Script не создаёт публичные IPv6 TCP-правила для 22/80/443.
- 3x-ui слушает loopback и открывается только через настроенный HTTPS path и Basic Auth.
- VLESS/MTProto ссылки, Telegram токены и другие секреты хранятся в `/root/secure-notes` и не печатаются по умолчанию.
- Публичная поверхность сервера остаётся ограниченной IPv4 TCP 22, 80 и 443.

## Совместимость

Проверено на чистых VPS-установках:

- Ubuntu 24.04 LTS
- Debian 12

Проверены SSH hardening, DNS safe mode, fail2ban, UFW policy, nginx, HAProxy, 3x-ui/Xray, VLESS, MTProto, Certbot, weekly maintenance, deep health, WARP и Telegram notification/relay modes.

## Пользователю

- Устанавливайте через GitHub bootstrap из README.
- До установки подготовьте DNS A-записи.
- Для XPAM-managed доменов используйте IPv4 A records и уберите AAAA records.
- Не публикуйте вывод `--show`, `--show-secrets`, VLESS-ссылки, MTProto-ссылки, WARP keys и Telegram tokens.
- Для обычной проверки используйте `sudo <prefix>-health`.
- Для подробной диагностики используйте `sudo <prefix>-health --deep`.
