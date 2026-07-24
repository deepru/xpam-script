#!/usr/bin/env bash
# XPAM Script module. This file is sourced by scripts/xpam-core.sh.
# Keep functions side-effect free at source time.

mask_render_preset_site(){
  # Render the deterministic, per-install-UNIQUE "product landing" decoy for <domain> into <dest>.
  # Everything about the look (accent palette, CSS class names, hero SVG, product name) is derived
  # from the FQDN, so every install is visually unique yet reproducible (see sites/_mask/generate.py
  # + MASKING_IDEAS.md section 6). Honors the optional MASK_PRESET override. Echoes an informational
  # "<preset-id>\t<palette-id>\t<product-name>" line (not parsed by callers).
  local domain="$1" role="${2:-primary}" dest="$3"
  local gen="${KIT_DIR}/sites/_mask/generate.py"
  [[ -n "$domain" && -n "$dest" ]] || fail "mask_render_preset_site: требуется domain и dest"
  [[ -f "$gen" ]] || fail "Генератор сайтов не найден: $gen"
  # All decoy domains on this box, canonical order (primary, sync, root) — lets the generator hand
  # each domain a different product so subdomains of one box are not the same preset.
  local peers="${PRIMARY_DOMAIN:-$domain}"
  if uses_mtproto && [[ -n "${SYNC_DOMAIN:-}" ]]; then peers="${peers},${SYNC_DOMAIN}"; fi
  if [[ "${PROFILE:-}" == "root_mtproto" && -n "${ROOT_DOMAIN:-}" ]]; then peers="${peers},${ROOT_DOMAIN}"; fi
  # The alt-transport domain is a decoy too and MUST be in the peer set, otherwise the generator
  # dedupes it against a different peer list and can hand it an archetype/product already used on
  # this box. Appended LAST on purpose: the greedy assignment processes peers in order, so adding
  # (or removing) the alt domain never moves the primary/sync/root assignments.
  if [[ -n "${VLESS_ALT_DOMAIN:-}" ]]; then peers="${peers},${VLESS_ALT_DOMAIN}"; fi
  MASK_DOMAIN="$domain" MASK_DEST="$dest" MASK_ROLE="$role" MASK_PEERS="$peers" \
    MASK_PRESET="${MASK_PRESET:-}" MASK_DIR="${KIT_DIR}/sites/_mask" \
    python3 "$gen"
}

mask_reset_preset_site(){
  # Force-restore the stock preset site for <domain> (clears the web root first). Used by the
  # "restore stock sites" menu action; deterministic, so it re-renders the same site every time.
  local domain="$1" role="${2:-primary}" dst="/var/www/$1"
  mkdir -p "$dst"
  find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  mask_render_preset_site "$domain" "$role" "$dst" >/dev/null || fail "Не удалось восстановить сайт для ${domain}"
  ok "Стандартный сайт восстановлен для ${domain}: ${dst}"
}

site_webroot_lines(){
  # Prints: ROLE<TAB>DOMAIN<TAB>PATH<TAB>DESCRIPTION
  [[ -n "${PRIMARY_DOMAIN:-}" ]] && printf 'PANEL_VLESS\t%s\t/var/www/%s\t%s\n' "$PRIMARY_DOMAIN" "$PRIMARY_DOMAIN" "Сайт-декорация для VLESS / 3x-ui домена"
  if [[ "${PROFILE:-}" == "root_mtproto" && -n "${ROOT_DOMAIN:-}" ]]; then
    printf 'ROOT\t%s\t/var/www/%s\t%s\n' "$ROOT_DOMAIN" "$ROOT_DOMAIN" "Основной сайт"
  fi
  if uses_mtproto && [[ -n "${SYNC_DOMAIN:-}" ]]; then
    printf 'MTPROTO_RELAY\t%s\t/var/www/%s\t%s\n' "$SYNC_DOMAIN" "$SYNC_DOMAIN" "Сайт-декорация для MTProto / Relay домена"
  fi
}


site_print_webroots(){
  local role domain path desc
  echo
  echo "Папки сайтов, которые можно менять:"
  while IFS=$'\t' read -r role domain path desc; do
    [[ -n "$domain" ]] || continue
    echo "  - ${desc}:"
    echo "      ${path}/"
  done < <(site_webroot_lines)
  if [[ "${PROFILE:-}" == "root_mtproto" && -n "${WWW_DOMAIN:-}" && -n "${ROOT_DOMAIN:-}" ]]; then
    echo
    echo "Важно: ${WWW_DOMAIN} — это redirect на ${ROOT_DOMAIN}. Отдельный сайт для ${WWW_DOMAIN} загружать не нужно."
  fi
}


stage_site_instructions(){
  need_root
  load_config
  validate_inputs
  echo "============================================================"
  echo "Управление сайтами"
  echo "============================================================"
  site_print_webroots
  cat <<EOF_SITE_HELP

Коротко: можно менять внешний вид сайтов, но нельзя занимать служебные адреса XPAM Script.

Что можно менять в папках сайта:
  - index.html, docs.html, license.html, 404.html;
  - favicon.svg, robots.txt, sitemap.xml;
  - папки assets/, css/, js/, img/, fonts/ и обычные статичные файлы.

Важно:
  - удаляйте содержимое /var/www/<domain>/, а не саму папку /var/www/<domain>/;
  - не публикуйте VLESS/MTProto ссылки, пароли, токены, WARP keys или private keys;
  - не меняйте nginx, HAProxy, systemd, 3x-ui, Xray, сертификаты и secure-notes ради замены сайта.

Служебные адреса, которые нельзя ломать:
  - /.well-known/acme-challenge/ — выпуск и продление SSL-сертификатов;
  - /${PANEL_PATH}/ — путь панели 3x-ui на panel/VLESS домене;
EOF_SITE_HELP
  if uses_mtproto; then
    cat <<EOF_SITE_MTPROTO
  - /health — проверка доступности sync/MTProto backend;
  - /status — технический статус sync backend;
  - /v1 и /v1/ — API-like служебные адреса, должны отвечать 401 без token;
EOF_SITE_MTPROTO
    if [[ -n "${TELEGRAM_RELAY_PATH:-}" ]]; then
      echo "  - /${TELEGRAM_RELAY_PATH}/ — путь HTTPS Telegram Relay, если Relay включён;"
    fi
  fi
  cat <<'EOF_SITE_HELP_2'

/docs, /license, favicon и стили можно заменять своим дизайном, если они остаются обычными статичными страницами и не конфликтуют со служебными route.

Роли стандартных сайтов:
  - все домены получают нейтральный лендинг небольшого технического продукта (product landing),
    сгенерированный автоматически из имени домена — на каждом домене свой продукт и цвет;
  - никакой личной информации, никаких серверных данных или метрик на странице;
  - страницы: / (лендинг), /docs, /license, 404, плюс robots.txt и sitemap.xml.

После загрузки файлов вернитесь сюда и выберите:
  2) Я загрузил новый сайт — проверить и применить

XPAM Script выставит права, проверит nginx, служебные маршруты и состояние сервера.
EOF_SITE_HELP_2
}

site_backup_webroots(){
  local label="${1:-site-replace}" ts backup_dir role domain path desc
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_dir="/root/manual-backups/${label}-${ts}"
  mkdir -p "$backup_dir/var-www"
  chmod 700 "$backup_dir"
  while IFS=$'\t' read -r role domain path desc; do
    [[ -n "$domain" && -d "$path" ]] || continue
    cp -a "$path" "$backup_dir/var-www/$domain"
  done < <(site_webroot_lines)
  prune_keep_latest /root/manual-backups "${label}-*" 4
  echo "$backup_dir"
}


site_fix_permissions(){
  local role domain path desc
  while IFS=$'\t' read -r role domain path desc; do
    [[ -n "$domain" ]] || continue
    [[ -d "$path" ]] || fail "Папка сайта не найдена: $path"
    chown -R www-data:www-data "$path" 2>/dev/null || true
    find "$path" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$path" -type f -exec chmod 644 {} \; 2>/dev/null || true
  done < <(site_webroot_lines)
}


site_verify_index_files(){
  local role domain path desc missing=0
  while IFS=$'\t' read -r role domain path desc; do
    [[ -n "$domain" ]] || continue
    if [[ ! -f "$path/index.html" ]]; then
      warn "В папке $path нет index.html"
      missing=1
    fi
  done < <(site_webroot_lines)
  [[ "$missing" -eq 0 ]] || fail "Добавьте index.html в каждую показанную папку сайта и повторите проверку"
}


site_http_code(){
  local url="$1"
  # -k is intentional: this is an HTTP status/reachability probe, not a security check.
  # Certificate validity is asserted separately by the TLS cert checks, so the probe
  # must not fail on transient cert state (e.g. mid-renewal) and mask a real status code.
  curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 25 "$url" 2>/dev/null || true
}


site_expect_code(){
  local label="$1" url="$2" expected="$3" code
  code="$(site_http_code "$url")"
  if [[ "$code" == "$expected" ]]; then
    ok "$label HTTP $code"
  else
    fail "$label: expected HTTP $expected, got ${code:-none} for $url"
  fi
}


site_verify_routes(){
  local role domain path desc panel_clean relay_clean
  while IFS=$'\t' read -r role domain path desc; do
    [[ -n "$domain" ]] || continue
    site_expect_code "$domain/" "https://${domain}/" 200
  done < <(site_webroot_lines)

  if [[ "${PROFILE:-}" == "root_mtproto" && -n "${WWW_DOMAIN:-}" && -n "${ROOT_DOMAIN:-}" ]]; then
    local code
    code="$(site_http_code "https://${WWW_DOMAIN}/")"
    [[ "$code" == "301" || "$code" == "302" || "$code" == "308" ]] || fail "${WWW_DOMAIN} redirect: expected 301/302/308, got ${code:-none}"
    ok "${WWW_DOMAIN} redirects to ${ROOT_DOMAIN} HTTP $code"
  fi

  panel_clean="${PANEL_PATH#/}"
  panel_clean="${panel_clean%/}"
  site_expect_code "3x-ui panel path is protected" "https://${PRIMARY_DOMAIN}/${panel_clean}/" 401

  if uses_mtproto && [[ -n "${SYNC_DOMAIN:-}" ]]; then
    site_expect_code "MTProto/Relay /health service route" "https://${SYNC_DOMAIN}/health" 200
    site_expect_code "MTProto/Relay /v1 service route" "https://${SYNC_DOMAIN}/v1" 401
    if [[ -f /root/secure-notes/notify-relay.env && -n "${TELEGRAM_RELAY_PATH:-}" ]]; then
      relay_clean="${TELEGRAM_RELAY_PATH#/}"
      relay_clean="${relay_clean%/}"
      site_expect_code "HTTPS Telegram Relay path without token" "https://${SYNC_DOMAIN}/${relay_clean}/" 401
    fi
  fi
}


stage_site_check_uploaded(){
  need_root
  load_config
  validate_inputs
  echo "============================================================"
  echo "Проверка загруженных сайтов"
  echo "============================================================"
  local backup_dir
  backup_dir="$(site_backup_webroots site-replace-check)"
  ok "Backup текущих сайтов создан: $backup_dir"
  site_verify_index_files
  site_fix_permissions
  nginx -t
  systemctl reload nginx || systemctl restart nginx
  site_verify_routes
  if [[ -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]]; then
    run_health_quiet "site-check-uploaded"
  fi
  ok "Сайт загружен и проверен. nginx работает, служебные маршруты XPAM Script не повреждены, сервер здоров."
}


stage_site_reset_stock(){
  need_root
  load_config
  validate_inputs
  echo "============================================================"
  echo "Возврат стандартных сайтов XPAM Script"
  echo "============================================================"
  warn "Этот пункт заменит содержимое папок сайтов стандартными страницами XPAM Script."
  local ans backup_dir
  read -r -p "Введите RESET-SITES для продолжения: " ans || true
  [[ "$ans" == "RESET-SITES" ]] || fail "Возврат стандартных сайтов отменён"
  backup_dir="$(site_backup_webroots site-reset)"
  ok "Backup текущих сайтов создан: $backup_dir"

  mask_reset_preset_site "${PRIMARY_DOMAIN}" primary
  if uses_mtproto; then
    mask_reset_preset_site "${SYNC_DOMAIN}" sync
  fi
  if [[ "$PROFILE" == "root_mtproto" ]]; then
    mask_reset_preset_site "${ROOT_DOMAIN}" root
  fi

  site_fix_permissions
  write_nginx_final
  nginx -t
  systemctl reload nginx || systemctl restart nginx
  site_verify_routes
  if [[ -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]]; then
    run_health_quiet "site-reset-stock"
  fi
  ok "Стандартные сайты XPAM Script восстановлены. Backup предыдущих файлов: $backup_dir"
}


stage_site_menu(){
  need_root
  [[ -f "$CONFIG_FILE" ]] || fail "Сначала выполните установку сервера через пункт 1."
  load_config
  validate_inputs
  echo "Управление сайтами (опционально)"
  echo "1) Замена предустановленных сайтов: инструкция и папки"
  echo "2) Я загрузил новый сайт — проверить и применить"
  echo "3) Вернуть стандартные сайты XPAM Script"
  echo "4) Назад"
  local choice
  read -r -p "Выберите пункт [1-4]: " choice || true
  case "$choice" in
    1) stage_site_instructions ;;
    2) stage_site_check_uploaded ;;
    3) stage_site_reset_stock ;;
    4) return 0 ;;
    *) fail "Неизвестный пункт меню" ;;
  esac
}


