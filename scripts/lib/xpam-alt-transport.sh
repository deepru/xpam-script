#!/usr/bin/env bash
# XPAM Script module: optional secondary VLESS transport (xhttp; grpc later) on a SEPARATE
# on-demand domain, coexisting with the untouched tcp primary (Design 2, see
# handoff/FEATURE_TRANSPORT_SELECTOR.md §5.5).
#
# Topology when enabled:
#   :443 HAProxy (mode tcp, SNI) ─ SNI=primary → be_xray (tcp+tls+vision)     ← UNTOUCHED
#                                 ─ SNI=alt     → be_vless_front → nginx (TLS) → xhttp inbound (security=none)
#                                                                              → decoy on /
# The primary tcp path stays byte-identical; this module only ADDS the alt front.
#
# Build phases (offline-first): A = config vars + validation + menu skeleton (this scaffold);
# B = cert + ACME vhost + decoy; C = xhttp inbound + nginx front + HAProxy ACL + link; D = DoubleHop
# multi-inbound + deep-health + repair-safety. Live test (E) is deferred to an ephemeral box.

# ---------- helpers ----------

# Resolve a domain's IPv4 A records, one per line. Prefers dig (dnsutils), falls back to getent.
alt_dns_a(){
  local d="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$d" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' || true
  else
    getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u || true
  fi
}

# Normalize a hostname: lowercase, strip a single trailing dot.
alt_domain_normalize(){ printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//'; }

# Validate an alt-transport domain: format, not one of the managed domains, and public DNS A points
# to this server (required for cert issuance). Returns 0 and echoes nothing on success; warns + non-0
# on failure. The :80 ACME reachability is proven implicitly at cert-issue time (phase B).
alt_domain_validate(){
  local d ip resolved m found=0 r
  d="$(alt_domain_normalize "$1")"
  [[ -n "$d" ]] || { warn "Домен не задан."; return 1; }
  if ! [[ "$d" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
    warn "Некорректный формат домена: $d"
    return 1
  fi
  for m in "${PRIMARY_DOMAIN:-}" "${SYNC_DOMAIN:-}" "${ROOT_DOMAIN:-}" "${WWW_DOMAIN:-}"; do
    [[ -n "$m" ]] || continue
    if [[ "$d" == "$(alt_domain_normalize "$m")" ]]; then
      warn "Домен $d уже используется этим сервером (primary/sync/root/www). Нужен ОТДЕЛЬНЫЙ домен."
      return 1
    fi
  done
  ip="$(server_public_ipv4 2>/dev/null || true)"
  resolved="$(alt_dns_a "$d")"
  if [[ -z "$resolved" ]]; then
    warn "DNS: у домена $d нет A-записи (или он не резолвится)."
    [[ -n "$ip" ]] && warn "Заведите A-запись домена $d на IP этого сервера: $ip"
    return 1
  fi
  if [[ -n "$ip" ]]; then
    while IFS= read -r r; do [[ "$r" == "$ip" ]] && found=1; done <<< "$resolved"
    if [[ "$found" != "1" ]]; then
      warn "DNS: A-запись $d указывает на [$(printf '%s ' $resolved)], а IP этого сервера — $ip."
      warn "Исправьте A-запись, иначе не выпустится сертификат Let's Encrypt."
      return 1
    fi
  fi
  ok "Домен $d валиден и указывает на этот сервер (${ip:-?})."
  return 0
}

alt_transport_is_enabled(){ [[ -n "${VLESS_ALT_DOMAIN:-}" && -n "${VLESS_ALT_TRANSPORT:-}" ]]; }

# ---------- status ----------

alt_transport_status(){
  echo
  echo "Дополнительный транспорт VLESS"
  echo
  if ! alt_transport_is_enabled; then
    echo "Статус:    выключен"
    echo "Основной:  tcp на ${PRIMARY_DOMAIN:-<не задан>} (работает как обычно)"
    return 0
  fi
  echo "Статус:    включён"
  echo "Транспорт: ${VLESS_ALT_TRANSPORT}"
  echo "Домен:     ${VLESS_ALT_DOMAIN}"
  echo "Основной:  tcp на ${PRIMARY_DOMAIN:-<не задан>} (работает одновременно)"
  # NOTE: connection link is printed by alt_build_link (phase C/D).
}

# ---------- pipeline helpers (phases B/C) ----------

# Build the plain (security=none) xhttp inbound payload into $1. Echoes "<uuid>\t<subid>".
# Reuses the tcp inbound's shape but STRIPS TLS (nginx terminates it) and clears the Vision flow.
alt_build_xhttp_payload(){
  local payload="$1" uuid subid ep_remark external_proxy_json
  uuid="$(python3 -c 'import uuid;print(uuid.uuid4())')"
  subid="$(openssl rand -hex 8)"
  ep_remark="${SERVER_PREFIX}-xhttp-public-${XRAY_PUBLIC_PORT}"
  # forceTls=tls (NOT "same"): the xhttp inbound is security=none (nginx terminates TLS on :443),
  # so the panel/host share-link must advertise security=tls. sni + fingerprint live ON THIS entry:
  # 3x-ui's genVlessLink derives the link's sni (externalProxy.sni||dest) and fp from here, and
  # externalProxyEntryToHost copies them into the hosts row — while it IGNORES the inbound's own
  # tlsSettings whenever the inbound is security!=tls. So the inbound carries NO tlsSettings (below).
  # (ru-links stays authoritative per D-4; it already emits fp=firefox itself.)
  external_proxy_json='[{"forceTls":"tls","dest":"'"${VLESS_ALT_DOMAIN}"'","port":'"${XRAY_PUBLIC_PORT}"',"sni":"'"${VLESS_ALT_DOMAIN}"'","fingerprint":"firefox","remark":"'"${ep_remark}"'"}]'
  XPAM_A_UUID="$uuid" XPAM_A_SUBID="$subid" XPAM_A_PORT="$XRAY_ALT_PORT" XPAM_A_PATH="$VLESS_ALT_PATH" \
  XPAM_A_HOST="$VLESS_ALT_DOMAIN" XPAM_A_EP="$external_proxy_json" XPAM_A_CLIENT="${SERVER_PREFIX}-client-xhttp" \
  XPAM_A_REMARK="${SERVER_PREFIX}-vless-xhttp" python3 - "$payload" <<'PY_ALT_PAYLOAD'
import json, os, sys
ep=json.loads(os.environ["XPAM_A_EP"])
settings={
  "clients":[{"id":os.environ["XPAM_A_UUID"],"flow":"","email":os.environ["XPAM_A_CLIENT"],
    "limitIp":0,"totalGB":0,"expiryTime":0,"enable":True,"tgId":0,
    "subId":os.environ["XPAM_A_SUBID"],"reset":0}],
  "decryption":"none",
  "fallbacks":[]
}
stream={
  "network":"xhttp","security":"none","externalProxy":ep,
  # No tlsSettings on the inbound: it stays pure security=none. The panel/host share-link gets its
  # security=tls + sni + fingerprint from the externalProxy entry (forceTls=tls, sni, fingerprint);
  # 3x-ui's genVlessLink ignores an inbound tlsSettings when security!=tls, so it would be dead weight.
  "xhttpSettings":{"path":os.environ["XPAM_A_PATH"],"host":os.environ["XPAM_A_HOST"],"mode":"auto"}
}
sniff={"enabled":False,"destOverride":[],"metadataOnly":False,"routeOnly":False}
payload={
  "up":0,"down":0,"total":0,"remark":os.environ["XPAM_A_REMARK"],"enable":True,"expiryTime":0,
  "listen":"127.0.0.1","port":int(os.environ["XPAM_A_PORT"]),"protocol":"vless",
  "settings":json.dumps(settings,separators=(",",":")),
  "streamSettings":json.dumps(stream,separators=(",",":")),
  "tag":f"inbound-{os.environ['XPAM_A_PORT']}",
  # No "allocate" key: not a field of 3x-ui v3.x model.Inbound (silently dropped); "always" is Xray's
  # default for this fixed-port inbound anyway.
  "sniffing":json.dumps(sniff,separators=(",",":"))
}
with open(sys.argv[1],"w",encoding="utf-8") as f:
    json.dump(payload,f,ensure_ascii=False,indent=2)
print(os.environ["XPAM_A_UUID"]+"\t"+os.environ["XPAM_A_SUBID"])
PY_ALT_PAYLOAD
}

# Build the plain (security=none) grpc inbound payload into $1. Echoes "<uuid>\t<subid>".
# Same shape/discipline as alt_build_xhttp_payload — only the stream differs: network=grpc with
# grpcSettings.serviceName (reuses VLESS_ALT_PATH, the generic secret selector) instead of xhttpSettings.
# nginx terminates TLS, so the inbound stays security=none; the share-link's tls/sni/fp come from the
# externalProxy entry (forceTls=tls) — genVlessLink ignores an inbound tlsSettings when security!=tls,
# so the inbound carries none (same R1 rule as xhttp).
alt_build_grpc_payload(){
  local payload="$1" uuid subid ep_remark external_proxy_json
  uuid="$(python3 -c 'import uuid;print(uuid.uuid4())')"
  subid="$(openssl rand -hex 8)"
  ep_remark="${SERVER_PREFIX}-grpc-public-${XRAY_PUBLIC_PORT}"
  external_proxy_json='[{"forceTls":"tls","dest":"'"${VLESS_ALT_DOMAIN}"'","port":'"${XRAY_PUBLIC_PORT}"',"sni":"'"${VLESS_ALT_DOMAIN}"'","fingerprint":"firefox","remark":"'"${ep_remark}"'"}]'
  XPAM_A_UUID="$uuid" XPAM_A_SUBID="$subid" XPAM_A_PORT="$XRAY_ALT_PORT" XPAM_A_SVC="$VLESS_ALT_PATH" \
  XPAM_A_EP="$external_proxy_json" XPAM_A_CLIENT="${SERVER_PREFIX}-client-grpc" \
  XPAM_A_REMARK="${SERVER_PREFIX}-vless-grpc" python3 - "$payload" <<'PY_ALT_GRPC_PAYLOAD'
import json, os, sys
ep=json.loads(os.environ["XPAM_A_EP"])
settings={
  "clients":[{"id":os.environ["XPAM_A_UUID"],"flow":"","email":os.environ["XPAM_A_CLIENT"],
    "limitIp":0,"totalGB":0,"expiryTime":0,"enable":True,"tgId":0,
    "subId":os.environ["XPAM_A_SUBID"],"reset":0}],
  "decryption":"none",
  "fallbacks":[]
}
stream={
  "network":"grpc","security":"none","externalProxy":ep,
  # No tlsSettings on the inbound: it stays pure security=none. The share-link gets its security=tls +
  # sni + fingerprint from the externalProxy entry; genVlessLink ignores an inbound tlsSettings when
  # security!=tls. serviceName = the generated secret (nginx matches location ^~ /<serviceName>).
  "grpcSettings":{"serviceName":os.environ["XPAM_A_SVC"],"authority":"","multiMode":False}
}
sniff={"enabled":False,"destOverride":[],"metadataOnly":False,"routeOnly":False}
payload={
  "up":0,"down":0,"total":0,"remark":os.environ["XPAM_A_REMARK"],"enable":True,"expiryTime":0,
  "listen":"127.0.0.1","port":int(os.environ["XPAM_A_PORT"]),"protocol":"vless",
  "settings":json.dumps(settings,separators=(",",":")),
  "streamSettings":json.dumps(stream,separators=(",",":")),
  "tag":f"inbound-{os.environ['XPAM_A_PORT']}",
  # No "allocate" key: not a field of 3x-ui v3.x model.Inbound (silently dropped).
  "sniffing":json.dumps(sniff,separators=(",",":"))
}
with open(sys.argv[1],"w",encoding="utf-8") as f:
    json.dump(payload,f,ensure_ascii=False,indent=2)
print(os.environ["XPAM_A_UUID"]+"\t"+os.environ["XPAM_A_SUBID"])
PY_ALT_GRPC_PAYLOAD
}

alt_panel_base_url(){
  local p="${PANEL_PATH#/}"; p="${p%/}"
  printf 'https://127.0.0.1:%s/%s' "$XUI_PANEL_PORT" "$p"
}

# Create the active alt inbound (xhttp OR grpc, per VLESS_ALT_TRANSPORT) via the 3x-ui Bearer API.
# On success sets ALT_NEW_UUID and returns 0.
ALT_NEW_UUID=""
alt_create_inbound(){
  local base payload ids rc=0
  base="$(alt_panel_base_url)"
  xui_ensure_api_token || { warn "Не удалось получить API-токен 3x-ui."; return 1; }
  payload="$(mktemp /tmp/xpam-alt-inbound.XXXXXX.json)"
  case "${VLESS_ALT_TRANSPORT:-xhttp}" in
    grpc) ids="$(alt_build_grpc_payload "$payload")" || { rm -f "$payload"; return 1; } ;;
    *)    ids="$(alt_build_xhttp_payload "$payload")" || { rm -f "$payload"; return 1; } ;;
  esac
  ALT_NEW_UUID="${ids%%$'\t'*}"
  xpam_xui_api_post_json "$base/panel/api/inbounds/add" "$payload" \
    /tmp/xpam-alt-add.out /tmp/xpam-alt-add.err || rc=$?
  if [[ $rc -ne 0 ]] || ! grep -Eiq '"success"[[:space:]]*:[[:space:]]*true' /tmp/xpam-alt-add.out 2>/dev/null; then
    warn "3x-ui add-inbound (${VLESS_ALT_TRANSPORT:-alt}) не вернул success. Ответ:"
    sed -n '1,80p' /tmp/xpam-alt-add.out 2>/dev/null || true
    rm -f "$payload"; return 1
  fi
  rm -f "$payload"; return 0
}

# Delete the active alt inbound (found by its loopback port XRAY_ALT_PORT — transport-agnostic, so it
# removes whichever of xhttp/grpc is live) + its orphaned managed client. Used by disable and by the
# enable switch path.
alt_delete_inbound(){
  local base id body rc=0 db=/etc/x-ui/x-ui.db emails email cbody
  id="$(sqlite3 "$db" "SELECT id FROM inbounds WHERE protocol='vless' AND listen='127.0.0.1' AND port=${XRAY_ALT_PORT} ORDER BY id ASC LIMIT 1;" 2>/dev/null || true)"
  [[ -n "$id" ]] || { warn "Альт-инбаунд не найден в БД (уже удалён?)."; return 0; }
  base="$(alt_panel_base_url)"
  xui_ensure_api_token || { warn "Нет API-токена для удаления инбаунда."; return 1; }
  # 3x-ui 3.x makes a client a first-class many-to-many entity: DelInbound removes the inbound + the
  # client_inbounds junction but LEAVES the `clients` row + client_traffics (no ON DELETE CASCADE) — by
  # design, since a client may span inbounds — so our dedicated xhttp client would linger on the panel
  # Clients page. Capture the client(s) bound to THIS inbound NOW (the junction is dropped once the
  # inbound is deleted), so cleanup finds them by their link to the inbound — rename-safe: it does not
  # rely on a hardcoded email the operator may have changed in the panel.
  emails="$(sqlite3 "$db" "SELECT c.email FROM clients c JOIN client_inbounds ci ON ci.client_id=c.id WHERE ci.inbound_id=${id};" 2>/dev/null || true)"
  # PRIMARY cleanup: remove each captured client through 3x-ui's OWN client API (drops the client + all
  # its traffic/IP rows via the ORM, schema-agnostically) BEFORE the inbound, so no orphan is left.
  while IFS= read -r email; do
    [[ -n "$email" ]] || continue
    cbody="$(mktemp /tmp/xpam-alt-cdel.XXXXXX.json)"; printf '{}' > "$cbody"
    xpam_xui_api_post_json "$base/panel/api/clients/del/${email}" "$cbody" \
      /tmp/xpam-alt-cdel.out /tmp/xpam-alt-cdel.err >/dev/null 2>&1 \
      || warn "client-API удаление клиента '${email}' не подтверждено — будет SQL-фолбэк."
    rm -f "$cbody"
  done <<< "$emails"
  # Now delete the inbound itself.
  body="$(mktemp /tmp/xpam-alt-del.XXXXXX.json)"; printf '{}' > "$body"
  xpam_xui_api_post_json "$base/panel/api/inbounds/del/${id}" "$body" \
    /tmp/xpam-alt-del.out /tmp/xpam-alt-del.err || rc=$?
  rm -f "$body"
  if [[ $rc -ne 0 ]] || ! grep -Eiq '"success"[[:space:]]*:[[:space:]]*true' /tmp/xpam-alt-del.out 2>/dev/null; then
    warn "Удаление альт-инбаунда не подтверждено (id=$id)."; return 1
  fi
  # DEFENSIVE FALLBACK (older panels without the client API, or a failed call): purge each captured
  # client directly. Guarded — a no-op once the API path already cleaned it. Plus sweep any traffic rows
  # still bound to the now-deleted inbound id, regardless of email.
  while IFS= read -r email; do
    [[ -n "$email" ]] || continue
    sqlite3 "$db" "DELETE FROM client_traffics WHERE email='${email}';" 2>/dev/null || true
    sqlite3 "$db" "DELETE FROM clients WHERE email='${email}';" 2>/dev/null || true
    sqlite3 "$db" "DELETE FROM client_global_traffics WHERE email='${email}';" 2>/dev/null || true
    sqlite3 "$db" "DELETE FROM node_client_traffics WHERE email='${email}';" 2>/dev/null || true
    sqlite3 "$db" "DELETE FROM inbound_client_ips WHERE client_email='${email}';" 2>/dev/null || true
  done <<< "$emails"
  sqlite3 "$db" "DELETE FROM client_traffics WHERE inbound_id=${id};" 2>/dev/null || true
  return 0
}

alt_issue_cert(){
  local d="$1"
  # shellcheck disable=SC2046
  run_certbot_checked "Alt $d" certonly --webroot -w /var/www/letsencrypt -d "$d" \
    --cert-name "$d" --keep-until-expiring --non-interactive --agree-tos $(certbot_args) || return 1
  [[ -s "/etc/letsencrypt/live/$d/fullchain.pem" && -s "/etc/letsencrypt/live/$d/privkey.pem" ]]
}

alt_nginx_target(){ printf '/etc/nginx/sites-available/xpam-alt-xhttp.conf'; }

alt_nginx_write_acme(){
  export_vars
  render_template "$KIT_DIR/templates/nginx-alt-acme.conf.tpl" "$(alt_nginx_target)"
  ln -sf "$(alt_nginx_target)" /etc/nginx/sites-enabled/xpam-alt-xhttp.conf
  nginx -t || return 1
  systemctl reload nginx || systemctl restart nginx || return 1
}

alt_nginx_write_front(){
  export_vars
  export ALT_CERT="/etc/letsencrypt/live/${VLESS_ALT_DOMAIN}/fullchain.pem"
  export ALT_KEY="/etc/letsencrypt/live/${VLESS_ALT_DOMAIN}/privkey.pem"
  # Pick the front template by the active transport (only one alt transport runs at a time). Same server
  # block + decoy either way — differs only in the secret location (xhttp proxy_pass vs grpc grpc_pass).
  local tpl="$KIT_DIR/templates/nginx-alt-xhttp.conf.tpl"
  [[ "${VLESS_ALT_TRANSPORT:-}" == "grpc" ]] && tpl="$KIT_DIR/templates/nginx-alt-grpc.conf.tpl"
  render_template "$tpl" "$(alt_nginx_target)"
  ln -sf "$(alt_nginx_target)" /etc/nginx/sites-enabled/xpam-alt-xhttp.conf
  nginx -t || return 1
  systemctl reload nginx || systemctl restart nginx || return 1
}

alt_nginx_remove(){
  rm -f /etc/nginx/sites-enabled/xpam-alt-xhttp.conf "$(alt_nginx_target)"
  if nginx -t >/dev/null 2>&1; then systemctl reload nginx || systemctl restart nginx || true; fi
}

# Re-render the deep-health script so it picks up (or drops) the alt decoy check. export_vars builds
# ALT_HEALTH_BLOCK from the current VLESS_ALT_* vars; check_http is defined inside health.sh.tpl.
alt_rerender_health(){
  export_vars
  render_template "$KIT_DIR/templates/health.sh.tpl" "/usr/local/sbin/${SERVER_PREFIX}-health"
  chmod +x "/usr/local/sbin/${SERVER_PREFIX}-health"
  bash -n "/usr/local/sbin/${SERVER_PREFIX}-health"
}

# Repair-safety: re-assert the alt xhttp front when configured. HAProxy (alt ACL) and deep-health are
# re-rendered by the surrounding repair steps (write_haproxy / write_health_weekly read the config);
# this restores the parts repair does not otherwise touch: the separate nginx TLS front + its hook.
# The xhttp inbound lives in the 3x-ui DB, so a normal repair keeps it (no re-create → no link churn).
alt_transport_reconcile(){
  alt_transport_is_enabled || return 0
  local cert="/etc/letsencrypt/live/${VLESS_ALT_DOMAIN}/fullchain.pem"
  if [[ -s "$cert" ]]; then
    say "Repair: восстанавливаю nginx-фронт (${VLESS_ALT_TRANSPORT:-alt}) для ${VLESS_ALT_DOMAIN}"
    alt_nginx_write_front || warn "Repair: не удалось перегенерировать nginx-фронт для ${VLESS_ALT_DOMAIN}."
    alt_write_certbot_hook "${VLESS_ALT_DOMAIN}"
  else
    warn "Repair: сертификат для ${VLESS_ALT_DOMAIN} отсутствует — nginx-фронт пропущен (перевыпустите через меню)."
  fi
}

alt_write_certbot_hook(){
  local d="$1" hook=/etc/letsencrypt/renewal-hooks/deploy/xpam-alt-reload.sh
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > "$hook" <<EOF
#!/usr/bin/env bash
set -u
case "\${RENEWED_LINEAGE:-}" in
  *"/$d") nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true ;;
esac
EOF
  chmod +x "$hook" 2>/dev/null || true
}
alt_remove_certbot_hook(){ rm -f /etc/letsencrypt/renewal-hooks/deploy/xpam-alt-reload.sh 2>/dev/null || true; }

# Generate a plausible, universal secret xhttp path: a realistic API/CDN-style prefix (coherent with
# ANY decoy site, domain-independent) + a high-entropy secret segment (the effective auth). NOT a
# bare random-hex path (which reads as a token and is a mild fingerprint).
alt_gen_xhttp_path(){
  local prefixes=( "/v1/streams" "/v1/events" "/api/media" "/api/blobs" "/assets/hls" \
                   "/cdn/segments" "/live/edge" "/media/chunks" "/static/assets" "/stream/live" )
  local pick secret
  pick="${prefixes[$((RANDOM % ${#prefixes[@]}))]}"
  secret="$(openssl rand -hex 12)"
  printf '%s/%s' "$pick" "$secret"
}

# Generate a plausible, high-entropy gRPC serviceName. Same philosophy as alt_gen_xhttp_path (realistic
# CDN/API-style prefix + openssl secret, NOT a bare hex token) but in gRPC serviceName format: NO leading
# slash (the serviceName is stored slash-less; nginx matches `location ^~ /<serviceName>` and the link
# carries `serviceName=<value>`). Prefixes avoid grpc/rpc words so they don't hint at the transport.
alt_gen_grpc_service(){
  local prefixes=( "v1/streams" "v1/events" "api/media" "api/blobs" "assets/hls" \
                   "cdn/segments" "live/edge" "media/chunks" "static/assets" "stream/live" )
  local pick secret
  pick="${prefixes[$((RANDOM % ${#prefixes[@]}))]}"
  secret="$(openssl rand -hex 12)"
  printf '%s/%s' "$pick" "$secret"
}

alt_build_link(){
  local uuid="$1" name="${2:-${SERVER_PREFIX}-client-xhttp}" pe
  pe="$(python3 - "$VLESS_ALT_PATH" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe='/'))
PY
)"
  printf 'vless://%s@%s:%s?type=xhttp&security=tls&encryption=none&path=%s&host=%s&mode=auto&sni=%s&fp=firefox#%s\n' \
    "$uuid" "$VLESS_ALT_DOMAIN" "$XRAY_PUBLIC_PORT" "$pe" "$VLESS_ALT_DOMAIN" "$VLESS_ALT_DOMAIN" "$name"
}

alt_build_grpc_link(){
  local uuid="$1" name="${2:-${SERVER_PREFIX}-client-grpc}" sn
  # serviceName is a query param → URL-encode fully (slashes become %2F), matching how the 3x-ui panel
  # (URLSearchParams) emits it. mode=gun (single); multiMode/mode=multi deferred.
  sn="$(python3 - "$VLESS_ALT_PATH" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
)"
  printf 'vless://%s@%s:%s?type=grpc&security=tls&encryption=none&serviceName=%s&mode=gun&sni=%s&fp=firefox#%s\n' \
    "$uuid" "$VLESS_ALT_DOMAIN" "$XRAY_PUBLIC_PORT" "$sn" "$VLESS_ALT_DOMAIN" "$name"
}

# If DoubleHop is configured (intended mode is vless-only/telegram-only/all), re-apply that mode so the
# single DH routing rule is rewritten to the CURRENT set of managed VLESS inbound tags — dh_mutate_mode
# scopes to every enabled vless inbound, so this makes DH hop the alt inbound (xhttp or grpc) too. Without
# it, enabling (or disabling) the alt transport leaves the DH rule covering only the primary → DH status reads
# "неполная / требуется восстановление" (deep-health stays green) until a manual menu restore.
#
# We read the INTENDED mode from the DoubleHop state file, NOT dh_detect_mode: while the rule lags the
# inbound set (exactly the window this runs in) the live-detected mode is "inconsistent", which is not a
# valid mutate target. dh_apply_mode_with_rollback is snapshot-protected and rolls back its own step on
# any failure; we call it in a subshell so its internal `fail` (on a failed rollback) cannot abort the
# alt enable/disable, whose xhttp change is already persisted. No-op when DoubleHop is off/unconfigured.
alt_dh_reapply_if_active(){
  command -v sqlite3 >/dev/null 2>&1 || return 0
  declare -f dh_apply_mode_with_rollback >/dev/null 2>&1 || return 0
  local state_file want_mode
  state_file="$(dh_state_file 2>/dev/null || echo "${CONFIG_DIR:-/etc/xpam-script}/doublehop.env")"
  [[ -f "$state_file" ]] || return 0
  want_mode="$(grep -E '^DH_MODE=' "$state_file" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr -d '[:space:]')"
  case "$want_mode" in
    vless-only|telegram-only|all) ;;
    *) return 0 ;;   # off / unset / unknown → nothing to reapply
  esac
  say "DoubleHop настроен (режим: $(dh_mode_label_ru "$want_mode")) — переприменяю правило на текущий набор VLESS-инбаундов"
  if ( dh_apply_mode_with_rollback "$want_mode" "$(dh_mode_label_user "$want_mode")" ); then
    ok "DoubleHop переприменён — правило охватывает все активные VLESS-инбаунды."
  else
    warn "Автоприменение DoubleHop не удалось (см. лог). Откройте меню DoubleHop → «Восстановить» вручную."
  fi
}

# ---------- enable / disable ----------

# Roll back a partially-applied enable/switch to a clean primary-only state (idempotent teardown), so a
# failure mid-enable never leaves masking broken. Removes any alt inbound on XRAY_ALT_PORT + its managed
# client, removes the nginx alt front, clears the alt config, re-renders HAProxy + deep-health WITHOUT the
# alt block, and re-applies DoubleHop to the remaining inbounds. The certificate is KEPT (re-enable reuses
# it). The primary tcp path is NEVER touched. Safe after any step (idempotent).
alt_enable_abort(){
  warn "Откат: снимаю частично применённый альт-транспорт, возвращаю сервер в чистое состояние (основной tcp не затронут)."
  if systemctl is-active --quiet x-ui; then
    alt_delete_inbound >/dev/null 2>&1 || true
    systemctl restart x-ui >/dev/null 2>&1 || true
  fi
  alt_nginx_remove
  VLESS_ALT_TRANSPORT=""; VLESS_ALT_DOMAIN=""; VLESS_ALT_PATH=""
  save_config
  write_haproxy >/dev/null 2>&1 || warn "Откат: перегенерация HAProxy не удалась — выполните sudo ${SERVER_PREFIX}-repair."
  alt_rerender_health >/dev/null 2>&1 || true
  alt_dh_reapply_if_active >/dev/null 2>&1 || true
  ok "Откат завершён: альт-транспорт выключен, основной tcp работает. Исправьте причину (выше) и попробуйте снова."
}

alt_transport_enable(){
  local transport="${1:-xhttp}" tlabel d uuid code was_enabled=0
  local old_domain="${VLESS_ALT_DOMAIN:-}" old_transport="${VLESS_ALT_TRANSPORT:-}"
  [[ "$transport" == "grpc" ]] && tlabel="grpc" || tlabel="xhttp"
  echo
  echo "Включение дополнительного транспорта ${tlabel} на ОТДЕЛЬНОМ домене."
  echo
  echo "Основной домен ${PRIMARY_DOMAIN:-<не задан>} (tcp) НЕ затрагивается — оба транспорта будут"
  echo "работать одновременно. Домен для ${tlabel} должен быть отдельным."
  echo
  if alt_transport_is_enabled; then
    was_enabled=1
    echo "Сейчас активен транспорт «${old_transport}» на ${old_domain}."
    echo "Он будет ЗАМЕНЁН на «${tlabel}» (одновременно активен только один альт-транспорт)."
    echo
  fi
  if (( was_enabled )) && [[ -n "$old_domain" ]]; then
    # Switching transport only: the domain is already configured and its certificate already issued,
    # so don't re-ask for it and don't re-validate DNS/:80 — that would just repeat proven checks.
    # Changing the alt domain is a separate, explicit action (disable, then enable on a new domain).
    d="$old_domain"
    echo "Домен остаётся прежним: ${d} (сертификат переиспользуется)."
    echo
  else
    echo "Требования к домену:"
    echo "  • A-запись указывает на IP этого сервера;"
    echo "  • порт 80 доступен извне (для выпуска TLS-сертификата)."
    echo
    ask d "Введите домен для ${tlabel} (например cdn.example.com)" "${old_domain}"
    d="$(alt_domain_normalize "$d")"
    alt_domain_validate "$d" || { echo "Изменения не внесены."; return 1; }
  fi

  uses_mtproto || { warn "Дополнительный транспорт требует HAProxy (профиль с MTProto)."; return 1; }
  systemctl is-active --quiet x-ui || { warn "Сервис x-ui не активен. Сначала выполните health/repair."; return 1; }
  command -v sqlite3 >/dev/null 2>&1 || { warn "sqlite3 не установлен."; return 1; }

  # Switch / re-enable: remove the currently-active alt inbound FIRST (its tag inbound-<port> is unique, so
  # a new inbound on the same reused port would collide). The certificate is ALWAYS KEPT (never
  # auto-deleted): same domain → reused below via --keep-until-expiring; different domain → the old cert is
  # left as a harmless orphan (it still renews via the primary :80 default_server catch-all while its DNS
  # points here). This avoids Let's Encrypt rate limits on repeated enable/switch. The renewal hook is
  # re-pointed at the new domain below by alt_write_certbot_hook.
  if [[ "$was_enabled" == "1" ]]; then
    say "Снимаю текущий транспорт «${old_transport}» перед переключением на «${tlabel}»"
    alt_delete_inbound || warn "Старый инбаунд не удалён автоматически — проверьте панель."
    systemctl restart x-ui || true
  fi

  # New transport state. Always generate a FRESH secret in the target transport's format (an xhttp path is
  # not a valid grpc serviceName and vice-versa). These vars drive export_vars (nginx/HAProxy render) and
  # the payload/link builders.
  VLESS_ALT_DOMAIN="$d"
  VLESS_ALT_TRANSPORT="$transport"
  case "$transport" in
    grpc) VLESS_ALT_PATH="$(alt_gen_grpc_service)" ;;
    *)    VLESS_ALT_PATH="$(alt_gen_xhttp_path)" ;;
  esac

  # 1) Decoy site (BYO-respecting: render only when the operator has not placed their own site).
  mkdir -p "/var/www/$d"
  if [[ ! -s "/var/www/$d/index.html" ]]; then
    say "Генерация сайта-декоя для $d"
    mask_render_preset_site "$d" primary "/var/www/$d" >/dev/null || { warn "Не удалось сгенерировать сайт-декой для $d."; alt_enable_abort; return 1; }
  else
    say "Свой сайт в /var/www/$d обнаружен — не трогаю (BYO)."
  fi

  # 2) ACME vhost + certificate.
  say "Поднимаю ACME-vhost nginx для $d и выпускаю сертификат"
  alt_nginx_write_acme || { warn "Не удалось поднять ACME-vhost nginx для $d."; alt_enable_abort; return 1; }
  alt_issue_cert "$d" || { warn "Не удалось выпустить сертификат для $d (проверьте A-запись и доступность :80)."; alt_enable_abort; return 1; }
  alt_write_certbot_hook "$d"

  # 3) Plain security=none alt inbound (xhttp or grpc, per VLESS_ALT_TRANSPORT).
  say "Создаю ${tlabel}-инбаунд (security=none) на 127.0.0.1:${XRAY_ALT_PORT}"
  alt_create_inbound || { warn "Не удалось создать ${tlabel}-инбаунд."; alt_enable_abort; return 1; }
  uuid="$ALT_NEW_UUID"
  systemctl restart x-ui || true
  write_wait_for_port >/dev/null 2>&1 || true
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XRAY_ALT_PORT" 30 xray-alt || warn "Порт альт-инбаунда пока не слушается — проверьте health/live-тест."

  # 4) nginx TLS front (cert now exists).
  say "Рендер nginx TLS-фронта для $d"
  alt_nginx_write_front || { warn "Не удалось поднять nginx TLS-фронт для $d."; alt_enable_abort; return 1; }

  # 5) HAProxy alt SNI route (primary/default routing untouched).
  say "Перегенерация HAProxy с маршрутом alt-SNI"
  write_haproxy || { warn "Не удалось перегенерировать HAProxy."; alt_enable_abort; return 1; }

  # 6) Re-render deep-health so it now also checks the alt decoy (GET https://<alt>/ = 200).
  alt_rerender_health || warn "Не удалось перегенерировать health-скрипт (проверка alt-декоя добавится при repair)."

  # 7) Persist.
  save_config

  # 7b) If DoubleHop is active, re-apply its rule to the new inbound set (primary + this alt transport) so
  #     the alt inbound is hopped too — otherwise DH reads "неполная" until a manual restore. The rule
  #     scopes to all VLESS inbounds by protocol, so it works identically for xhttp and grpc. Best-effort.
  alt_dh_reapply_if_active

  # 8) Soft acceptance check (offline, loopback): decoy on / must be 200.
  code="$(curl -sk -o /dev/null -w '%{http_code}' --resolve "${d}:${NGINX_ALT_TLS_PORT}:127.0.0.1" "https://${d}:${NGINX_ALT_TLS_PORT}/" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then ok "Декой на https://$d/ отвечает 200 (маскировка ок)."; else warn "Проверка декоя вернула HTTP '$code' (ожидалось 200) — перепроверьте на живом тесте."; fi

  echo
  ok "Дополнительный транспорт ${tlabel} включён на $d (одновременно с tcp на ${PRIMARY_DOMAIN})."
  echo
  echo "Ссылка для подключения (${tlabel}):"
  case "$transport" in
    grpc) alt_build_grpc_link "$uuid" ;;
    *)    alt_build_link "$uuid" ;;
  esac
  echo
  echo "Основной tcp-транспорт на ${PRIMARY_DOMAIN} не изменился."
}

alt_transport_disable(){
  if ! alt_transport_is_enabled; then
    echo "Дополнительный транспорт не настроен."
    return 0
  fi
  local d="$VLESS_ALT_DOMAIN" tlabel="${VLESS_ALT_TRANSPORT:-alt}"
  echo
  echo "Выключение дополнительного транспорта ${tlabel} на $d."
  echo
  confirm "Удалить ${tlabel}-инбаунд, nginx-фронт и HAProxy-маршрут для $d?" yes || { echo "Отменено. Изменений не внесено."; return 0; }

  if systemctl is-active --quiet x-ui; then
    alt_delete_inbound || warn "Инбаунд не удалён автоматически — проверьте панель."
    systemctl restart x-ui || true
  else
    warn "x-ui не активен — пропускаю удаление инбаунда."
  fi

  alt_nginx_remove
  alt_remove_certbot_hook

  # KEEP the certificate (do NOT delete it). Re-enabling or switching to another transport later reuses it
  # via alt_issue_cert --keep-until-expiring → no re-issue → no Let's Encrypt rate-limit risk. Weekly
  # `certbot renew` still succeeds while disabled: the primary nginx :80 default_server (server_name _)
  # serves /.well-known/acme-challenge/ from /var/www/letsencrypt for ANY host, this domain included.

  # Clear state and re-render HAProxy without the alt block. The decoy site /var/www/$d is left in place.
  VLESS_ALT_TRANSPORT=""; VLESS_ALT_DOMAIN=""; VLESS_ALT_PATH=""
  save_config
  write_haproxy || warn "Перегенерация HAProxy не удалась — проверьте вручную."
  alt_rerender_health || true

  # If DoubleHop is active, re-scope its rule to the remaining inbound set (primary only) now that the alt
  # inbound is gone — keeps DH consistent without a manual restore. The rule scopes to all VLESS inbounds
  # by protocol, so this auto-reapply is identical for xhttp and grpc. Safe/best-effort.
  alt_dh_reapply_if_active

  echo
  ok "Дополнительный транспорт ${tlabel} выключен."
  echo "Сертификат $d СОХРАНЁН (повторное включение или смена транспорта — без повторного выпуска). Сайт /var/www/$d оставлен."
}

# ---------- menu ----------
# Wired into stage_advanced_menu (item 7) as of phase C — the enable/disable pipeline is functional.
stage_alt_transport_menu(){
  need_root
  load_config
  # One-shot sub-area (like the rest of the menus): draw → pick a valid item → run → return to the shell.
  # xhttp and grpc are both selectable; enabling one while another is active switches to it automatically
  # (alt_transport_enable tears the current one down first). Only invalid input re-prompts; "0)" returns.
  local choice
  while true; do
    alt_transport_status
    echo
    echo "Транспорты VLESS (дополнительный транспорт на отдельном домене)"
    echo "1) Включить / сменить на xhttp"
    echo "2) Включить / сменить на grpc"
    echo "3) Выключить"
    echo "0) Назад"
    read -r -p "Выберите пункт [0-3]: " choice || return 0
    case "$choice" in
      1) alt_transport_enable xhttp || true ;;
      2) alt_transport_enable grpc || true ;;
      3) alt_transport_disable || true ;;
      0) return 0 ;;
      *) warn "Неизвестный пункт меню — выберите из списка."; continue ;;
    esac
    return 0
  done
}
