# XPAM Script v1.0.7 GitHub publication audit

Дата подготовки: 2026-05-26  
Базовый архив: `xpam-script-final-20260526-v1.0.7-ubuntu24-debian12.tar.gz`  
SHA256 базового архива: `8cae6b4f3f99b1e8f83e49ee7c109252d452dce0b5337147d787edcdbe49afb4`

## Результат

Подготовлен отдельный GitHub-ready пакет на базе v1.0.7.

Архив был статически разобран: проверена структура, синтаксис shell-файлов, шаблоны, документация и потенциальные утечки.

## Что проверено

- `install.sh`
- `scripts/xpam-core.sh`
- `templates/*.sh.tpl`
- nginx templates
- HAProxy template
- MTProto templates
- health/weekly templates
- stock websites under `sites/`
- README and generated docs

## Синтаксис

Проверки прошли успешно:

```bash
bash -n install.sh
bash -n scripts/xpam-core.sh
for f in templates/*.sh.tpl; do bash -n "$f"; done
bash -n bootstrap.sh
```

## Что было исправлено

В исходной v1.0.7-сборке оставались косметические legacy-строки с прежним внутренним путём/версией в старых предупреждениях и MTProto notes. Они заменены на актуальное нейтральное описание XPAM Script v1.0.7.

## Персональные данные и секреты

В GitHub-ready дереве не найдено:

- реальных пользовательских доменов;
- реальных IP тестовых VPS;
- личных имён, email или аккаунтов;
- Telegram bot token;
- Relay token;
- private keys;
- реальные VLESS ссылки;
- реальные MTProto ссылки;
- `/root/secure-notes`;
- `/etc/xpam-script/config.env`;
- серверные логи;
- config backups.

## Допустимые совпадения

В коде остались строки генерации ссылок вида:

```text
tg://proxy?server=${SYNC_DOMAIN}...
vless://...
```

Это не реальные секреты, а шаблоны/генераторы, необходимые для работы скрипта.

В коде также есть Cloudflare DNS `1.1.1.1` и `1.0.0.1`; это ожидаемая DNS policy, а не старая версия проекта.

## Добавлено для GitHub

- `README.md` — техническое описание на английском.
- `README_RU.md` — краткое техническое описание на русском.
- `LICENSE` — MIT для собственного кода XPAM Script.
- `THIRD_PARTY.md` — upstream-компоненты и лицензии.
- `SECURITY.md` — политика безопасности и редактирования секретов.
- `CHANGELOG.md` — changelog v1.0.7.
- `NOTICE.md` — независимость проекта.
- `.gitignore`
- `bootstrap.sh`
- `.github/ISSUE_TEMPLATE/*`
- `.github/pull_request_template.md`
- `docs/*.md`
- `docs/USER_GUIDE_RU.pdf`
- `docs/PRESS_RELEASE_RU.md`

## Перед публикацией

Нужно заменить placeholder-значения:

```text
deepru
stas.khramov.github@gmail.com
```

Минимум:

```bash
grep -RIn 'deepru\|stas.khramov.github@gmail.com' .
```

После выбора GitHub owner/repo можно заменить `deepru` на реальный GitHub username или organization.

## Рекомендация

Публиковать не старый tar.gz как репозиторий, а именно GitHub-ready пакет.  
Release asset можно прикреплять отдельно как `xpam-script-v1.0.7-ubuntu24-debian12.tar.gz` вместе с `.sha256`.
