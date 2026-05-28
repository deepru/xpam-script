# Changelog

## v1.1.0

XPAM Script v1.1.0 — стабильный релиз для Ubuntu 24.04 LTS и Debian 12.

Основной фокус релиза: совместимость с реальными VPS-образами, safe DNS behavior, Debian 12, fail2ban, `/etc/hosts`, безопасный вывод секретов, production cleanup и обновлённая русская пользовательская инструкция.

### Главное

- Safe DNS mode: рабочий DNS провайдера принимается и не переписывается.
- Улучшена совместимость с Debian 12 minimal/provider VPS.
- Добавлена нормализация hostname и `/etc/hosts`, чтобы устранить `sudo: unable to resolve host` без привязки managed domains к localhost.
- fail2ban использует systemd backend.
- Публичные TCP-порты остаются ограничены IPv4 22/80/443.
- Команды `sudo <prefix>-links`, `sudo <prefix>-vless`, `sudo <prefix>-telega` не печатают секреты по умолчанию.
- Добавлены `sudo <prefix>-netdiag` и `sudo <prefix>-repair`.
- Улучшена проверка WARP через 3x-ui/Xray.
- Усилена финальная production cleanup.
- Обновлена русская инструкция `docs/USER_GUIDE_RU.pdf`.

Подробности: `CHANGELOG-v1.1.0.md` и `RELEASE_NOTES-v1.1.0.md`.

## v1.0.10

Предыдущий стабильный релиз. Основная рабочая архитектура сохранена в v1.1.0.
