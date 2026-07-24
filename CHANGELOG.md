# Changelog

## [Unreleased] — v1.4.0 (в разработке)

> Черновик release notes; версия ещё не поднята. Копим изменения до крупного релиза 1.4.0.

### Dev / CI
- **`make-release` теперь требует генератор сайтов-обманок** (`sites/_mask/generate.py`, `presets.json`,
  `themes/_layout.css`) — раньше их отсутствие проходило и через гейты, и через preflight обновлятора,
  хотя маскировка на них завязана.
- **Новый гейт: каждому архетипу из списка в генераторе обязан соответствовать файл темы.** Генератор
  намеренно откатывается на `clean.css`, если темы нет, то есть удалённая/переименованная тема НЕ
  падала — она молча рисовала другой дизайн. Теперь это ошибка сборки (проверено: гейт срабатывает).
- Удалены неиспользуемые файлы `sites/_mask/palettes.json` и `sites/_mask/templates/style.css`
  (генератор их больше не читает).
- Замена имени продукта в пресете теперь идёт **по границам слова**: наивная подстрока испортила бы
  текст, если бы id пресета оказался внутри другого слова (`ember` → «September», `slate` →
  «translate»). На текущих данных вывод побайтно не изменился.

### Fixes
- **Заголовки безопасности реально доходят до браузера.** Во всех nginx-конфигах (основной домен,
  корневой, sync и оба alt-фронта) заголовки `X-Content-Type-Options`, `X-Frame-Options`,
  `Referrer-Policy`, `Permissions-Policy`, `X-Permitted-Cross-Domain-Policies` были заданы на уровне
  сервера, но **не отправлялись**: в nginx любой `add_header` внутри `location` отменяет наследование
  всех `add_header` уровня выше, а такие `add_header Cache-Control` стояли в `/`, `/docs`, `/license`
  и в блоке статики. Управление кэшем переведено на директиву `expires`, которая не ломает
  наследование. Проверено вживую: было 0 заголовков, стало 5 (на sync-домене — свои 3, там набор
  намеренно строже, как у API-поддомена).
- **Смена альт-транспорта больше не переспрашивает домен.** При переключении xhttp ↔ grpc на уже
  настроенном домене скрипт спрашивал домен заново и печатал требования к нему (A-запись, порт 80),
  хотя домен и сертификат уже есть. Теперь домен переиспользуется молча, лишние проверки DNS и порта
  не повторяются. Смена самого домена — отдельное явное действие (выключить, включить на новом).
- **Домен альт-транспорта участвует в раздаче архетипов.** Он тоже показывает сайт-обманку, но не
  попадал в список доменов сервера, из-за чего мог получить оформление, уже занятое другим доменом
  этой же машины (примерно 1 случай из 3). Теперь учитывается — и добавляется последним, поэтому
  оформление остальных доменов от этого не меняется.

### Masking
- **Сайты-обманки теперь уникальны на каждой установке.** Раньше все серверы отдавали визуально
  одинаковый сайт: один и тот же CSS, одни и те же имена классов, одна и та же вёрстка и один из
  10 фиксированных «продуктов». Это общий отпечаток: просканировав один сервер, можно было узнать
  и заблокировать остальные по совпадению. Теперь всё, что видно снаружи, выводится из имени
  домена: **имена CSS-классов** (у каждого сервера свои), **акцентный цвет** (непрерывный подбор
  оттенка), **hero-иллюстрация и favicon** (генерируются процедурно), **название продукта**
  (генерируется, а не выбирается из списка). Два сервера больше не совпадают побайтно.
- **10 архетипов оформления — у каждого своя вёрстка, а не только цвет.** `clean`, `terminal`,
  `editorial`, `financial`, `atlas`, `soft`, `midnight`, `console`, `slate`, `aurora`. Отличаются
  раскладкой первого экрана, типом иллюстрации (схема / окно терминала / карточка API / без неё),
  подачей блока возможностей (сетка / список / таблица), навигацией и порядком секций; светлые и
  тёмные архетипы фиксируют свою тему и не зависят от системной темы браузера. Палитра зависит и от
  домена, и от архетипа, поэтому два архетипа не совпадают по цвету даже на одном домене.
- **Домены одного сервера гарантированно получают разные архетипы и разные продукты** (актуально,
  когда на одной машине 5–6 доменов). Выбор детерминированный: тот же домен → тот же сайт, поэтому
  `repair` и «восстановить стандартный сайт» воспроизводят его в точности.
- Адреса страниц не изменились (`/docs`, `/license`, `/health`, `/v1`, путь панели), маскировочные
  проверки и `deep-health` работают как прежде. Сайты остаются полностью автономными: только
  системные шрифты, никаких внешних файлов и обращений в сеть.

### Transports
- **Второй транспорт VLESS — xhttp ИЛИ grpc на отдельном домене (по требованию, из меню).** Работает
  ОДНОВРЕМЕННО с нетронутым основным tcp-транспортом (primary остаётся байт-в-байт). Схема Path B: nginx
  терминирует TLS для alt-домена, проксирует секретный путь / serviceName в plain (security=none)
  xhttp/grpc-инбаунд и отдаёт сайт-обманку на `/`; HAProxy добавляет alt-SNI маршрут; grpc = +1 nginx
  `grpc_pass` location. Один переиспользуемый порт `XRAY_ALT_PORT` (миграция со старого `XRAY_XHTTP_PORT`);
  генераторы секретного пути (xhttp) / serviceName (grpc); ничего не захардкожено. Меню «Транспорты VLESS»:
  включить/сменить xhttp, включить/сменить grpc, выключить — смена транспорта автоматическая. Валидация
  домена → cert → декой → инбаунд → nginx-фронт → HAProxy → ссылка. DoubleHop хопит ВСЕ VLESS-инбаунды.
- **Сертификат alt-домена НИКОГДА не удаляется автоматически** (ни при выключении, ни при смене
  транспорта) — повторное включение/смена переиспользуют его (`--keep-until-expiring`), без риска лимитов
  Let's Encrypt; продление идёт через primary `:80` catch-all. (Раньше выключение удаляло сертификат.)
- **Откат при сбое включения/смены транспорта.** Если любой шаг падает (cert, инбаунд, nginx, HAProxy),
  скрипт откатывает частично применённое состояние в чистое primary-only (убирает инбаунд/фронт, чистит
  конфиг, перегенерит HAProxy/health без alt-блока) и сообщает причину — маскировка основного домена не
  ломается.

### Maintenance
- **Еженедельное авто-обновление системы с ребутом (режим `auto`, теперь по умолчанию).**
  `apt upgrade --with-new-pkgs` ставит все обновления (включая ядра), ребут только при необходимости;
  один ребут запускает пост-ребутный oneshot (второй проход + очистка + health), затем самоотключается.
  Telegram-оповещение только при сбое. Полная очистка `.dpkg-*`/`.ucf-*` и охранный autoremove.
  Существующие серверы мигрируют `security`→`auto` автоматически при обновлении.

### UX
- **Меню зависит от стадии жизни сервера.** До завершения установки показывается меню установки
  (SSH-безопасность + установка/продолжение); после полной установки — рабочее меню, из которого
  install-only пункты (SSH и «Установить») убраны, чтобы не путать. Признак «установлено» — наличие
  команды `<prefix>-health` (появляется только по завершении финальной стадии, переживает reboot между
  этапами), поэтому пункты установки не пропадают раньше времени.
- **Меню: команда → вывод → шелл (как в 1.3.9).** Меню больше не зацикливается и не перерисовывается
  поверх вывода: выбрал пункт → выполнилось → вернулся в шелл, вывод команды остаётся последним на
  экране. Касается и рабочего меню, и подменю «Дополнительно» / «Транспорты VLESS». Неверный ввод —
  переспросить. Из «Дополнительно» убран дублирующий пункт SSH-настройки.
- Чистые имена ссылок (панель/подписка используют email клиента), единый вывод `<prefix>-links` (без
  `--show-secrets`), подменю «Транспорты VLESS»; standalone-команды `-status`/`-netdiag` свёрнуты в меню.

### Fixes
- **DoubleHop:** извлечение VLESS-ссылки по токену `vless://`, а не по устаревшей метке — иначе после
  UX-рефактора вывода ссылок падали все операции DoubleHop (enable/disable/remove).
- **grpc-ссылка в `<prefix>-links`:** не добавляется `alpn=http/1.1` (grpc требует HTTP/2 — с
  `alpn=http/1.1` реальный клиент не подключается); клиент сам согласует h2.
- **deep-health:** порты alt-транспорта (Xray-инбаунд + nginx-фронт) при включённом alt добавляются в
  allowlist loopback-портов — больше не флагаются как «unexpected loopback listener».

### Dev / CI
- Offline smoke-тесты (`tests/payload-smoke.sh`) проверяют VLESS/MTG/xhttp/grpc payload-строители против
  Go-типов 3x-ui `model.Client`/`model.Inbound`; подключены в CI.

## v1.3.9

### Masking

- New decoy mask-site system. Instead of static placeholder pages, XPAM generates a plausible
  product-landing site (home, docs, license, 404, `robots.txt`, `sitemap.xml`) for each domain,
  chosen deterministically from the domain name — so every domain, and every server, looks
  different. Per-server anti-collision keeps two subdomains of one box from getting the same site.
  Fully self-contained; nothing to configure.
- Bring-your-own-site preserved: a custom site placed in a domain's web root is never overwritten
  on install or repair. "Restore stock sites" regenerates the default pages on demand.

### Documentation

- The full Russian user guide was reformatted from DOCX/PDF into GitHub-native Markdown
  (`docs/USER_GUIDE_RU.md`) — table of contents, tables, code highlighting, alerts; it opens
  directly on GitHub. The old `.docx`/`.pdf` were removed.
- `THIRD_PARTY.md` / `NOTICE.md` updated: dropped the stale standalone `mtg` reference (Telegram
  proxy / MTG is bundled and maintained by 3x-ui). `docs/SITES.md` documents the new site system.

### Compatibility

- No user-facing changes — same commands and menu. Validated on Ubuntu and Debian with
  3x-ui 3.5.0 / Xray 26.7.11 (last-validated baseline unchanged).

## v1.3.8

### Compatibility

- Verified full compatibility with **3x-ui v3.5.0** (multi-client MTProto/MTG, Xray 26.7.11). MTProto secrets moved from the inbound level to per-client entries; XPAM reads and writes both shapes, so a single build works on 3x-ui 3.4.2 and 3.5.0. Last-validated baseline updated to **3x-ui 3.5.0 / Xray 26.7.11**.

### Fixes

- MTProto (MTG) is now created with a client entry that carries the secret, so the Telegram proxy works on a fresh install under 3x-ui 3.5.0 (which strips inbound-level secrets). Remains backward-compatible with 3.4.2.
- VLESS inbound creation no longer fails on 3x-ui 3.5.0's stricter client parsing — the client `tgId` is sent as a number instead of a string.

### Improvements

- `<prefix>-links --show-secrets` lists the link of every enabled VLESS and Telegram client (multi-client aware).
- MTProto clients now carry a subscription id, so the 3x-ui panel shows their link/QR, with a comment pointing to `<prefix>-links --show-secrets` for the authoritative (:443) Telegram link.

## v1.3.7

### Compatibility

- Verified full compatibility with **Debian 13** and **Ubuntu 26.04** — fresh install, repair, `repair --full`, weekly maintenance and health checks all pass. OS checks no longer flag newer Ubuntu/Debian releases.

### Architecture cleanup

- Removed the legacy `vless_direct` profile; the server always runs VLESS behind HAProxy.
- Removed the legacy `alexbers` MTProto backend; MTProto runs only via 3x-ui MTG. The `<prefix>-tg` command was removed — the Telegram link is shown by `<prefix>-links --show-secrets`.
- Config imports from removed profiles/backends now fail fast with a clear message.

### New features

- `<prefix>-repair --full` restores the 3x-ui database (clients/inbounds/secrets) from the latest golden snapshot, with integrity check, explicit confirmation, pre-restore backup and health-gated auto-rollback.
- `<prefix>-repair` now also regenerates the nginx configuration (previously only HAProxy).
- New health check for memory pressure (available RAM / swap usage).

### Security

- Hardened the Telegram relay socket fallback (no world-writable fallback).

### Maintainer / infrastructure

- Added `make-release.sh` and CI to build/verify the release archive with the mandatory wrapper layout, guarding the packaging-regression class.
- Self-update now prunes old update work directories (keeps the newest 2) to avoid disk clutter over time.

## v1.3.6

### Compatibility and release hardening

- Hardened GitHub download paths in bootstrap and self-update with HTTP/1.1 retries/timeouts while keeping SHA256 verification mandatory.
- Hardened 3x-ui installer handling for current upstream behavior, including stable-release selection and `XUI_ENABLE_FAIL2BAN=false` guard.
- Added health/deep-health checks for unexpected upstream 3x-ui `3x-ipl` fail2ban files/jail.
- Added additional 3x-ui/Xray compatibility diagnostics: version visibility, generated config JSON/readability, SQLite journal mode, subscription/Managed Hosts sanity, and Telegram feature separation.
- Preferred `systemd-timesyncd` and avoided unnecessary public `ntp/ntpsec` UDP `:123` exposure in XPAM-managed runtime.
- Removed legacy WireGuard `workers=2` recommendation for current Xray/3x-ui builds.
- Kept VLESS/Telegram links unchanged across tested DoubleHop enable/disable scenarios.

## v1.3.5

### Compatibility hardening after 3x-ui v3.4.0

- Added XPAM-owned guard against upstream 3x-ui fail2ban/IP-limit auto-setup: `XUI_ENABLE_FAIL2BAN=false`.
- Added health/deep-health checks for unexpected upstream `3x-ipl` fail2ban files/jail.
- Hardened GitHub download paths with HTTP/1.1 retries/timeouts while keeping SHA256 verification mandatory.
- 3x-ui auto-install now selects the latest stable GitHub release and skips prereleases by default.
- Hardened bootstrap documentation for VPS networks with broken GitHub CDN edge routing.
- Added 3x-ui/Xray compatibility information to deep-health: version, generated config readability, SQLite journal mode, subscription/Managed Hosts sanity.
- Kept XPAM Telegram proxy / MTG, XPAM Telegram notifications, and upstream 3x-ui Telegram notifications clearly separated.
- Preferred `systemd-timesyncd` for local time sync and removed unnecessary public `ntp/ntpsec` server exposure during XPAM-managed installs.
- Removed legacy WireGuard `workers=2` recommendation for current Xray/3x-ui builds.

### Главное

- Добавлен новый основной интерфейс управления: `sudo <prefix>-xpam`.
- Обновлён fresh-install UX и убрана старая пользовательская схема профилей.
- VLESS настраивается через 3x-ui/Xray.
- Telegram proxy / MTG настраивается через 3x-ui.
- Данные подключения объединены в `sudo <prefix>-links` и `sudo <prefix>-links --show-secrets`.
- VLESS и Telegram links в полной выдаче берутся из текущей конфигурации 3x-ui.
- Добавлен DoubleHop Mode для Entry-сервера.
- Добавлены режимы DoubleHop: VLESS only, Telegram only, VLESS + Telegram.
- Добавлены small-VM оптимизации для слабых VPS.
- Добавлен safe self-update через GitHub Releases.
- Добавлены SHA256 verification, staging preflight, backup и rollback для обновлений.

### Health, repair и maintenance

- Health/deep-health учитывают актуальную Telegram proxy / MTG архитектуру.
- Repair и weekly maintenance не должны менять VLESS/Telegram links.
- Ручная смена Telegram proxy / MTG secret в 3x-ui не должна ломать health/deep-health/weekly; актуальная Telegram link должна отображаться через `sudo <prefix>-links --show-secrets`.
- Maintenance-сценарии проверены в direct/off и DoubleHop-сценариях.
- Сохранены journald/logrotate политики и backup retention для небольших VPS.

### DoubleHop Mode

- XPAM управляет DoubleHop только на Entry-сервере.
- Exit-сервер пользователь подготавливает отдельно.
- Для Exit используется VLESS-ссылка, которую пользователь вставляет в XPAM.
- Включение, изменение режима и выключение DoubleHop не меняют текущие Entry-side VLESS и Telegram links.

### Safe self-update

- Обновление запускается вручную из XPAM-меню.
- Архив обновления проверяется по SHA256 до применения.
- Static preflight выполняется до mutation.
- Перед применением создаётся backup runtime и служебных команд.
- При ошибке post-update проверки выполняется rollback.
- Секреты не должны печататься в update logs.

### Проверка

Проверено на Ubuntu и Debian: установка, управление сервером, VLESS, Telegram proxy / MTG, DoubleHop Mode, диагностика, восстановление и безопасное обновление.

## v1.3.0

- Добавлена стабильная IPv4-first установка для Ubuntu и Debian.
- Улучшена интеграция 3x-ui/Xray, nginx, HAProxy, Certbot, firewall, fail2ban и health-checks.
- Добавлены production cleanup и базовые maintenance-сценарии.

## v1.2.0

- Добавлены installer, runtime scripts, templates, документация и site assets.
- Добавлены SSH hardening, UFW, fail2ban, nginx, Certbot, HAProxy, 3x-ui, Xray/VLESS и Telegram-related automation.
