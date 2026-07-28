#!/usr/bin/env bash
# XPAM Script module. This file is sourced by scripts/xpam-core.sh.
# Keep functions side-effect free at source time.

mtproto_3xui_mtg_managed_remark(){
  printf '%s-mtproto' "$SERVER_PREFIX"
}

mtproto_3xui_mtg_secret_domain_hex(){
  [[ -n "${SYNC_DOMAIN:-}" ]] || fail "SYNC_DOMAIN is required to build 3x-ui MTG secret suffix"
  XPAM_MTG_SYNC_DOMAIN="$SYNC_DOMAIN" python3 - <<'PY_XPAM_3XUI_MTG_DOMAIN_HEX'
import os
print(os.environ['XPAM_MTG_SYNC_DOMAIN'].encode('utf-8').hex())
PY_XPAM_3XUI_MTG_DOMAIN_HEX
}

mtproto_3xui_mtg_generate_raw_secret_hex(){
  python3 - <<'PY_XPAM_3XUI_MTG_RAW_SECRET'
import secrets
print(secrets.token_hex(16))
PY_XPAM_3XUI_MTG_RAW_SECRET
}

mtproto_3xui_mtg_validate_raw_secret_hex(){
  local raw="${1:-}"
  [[ "$raw" =~ ^[0-9a-fA-F]{32}$ ]] || fail "RAW_SECRET_HEX must be exactly 32 hex characters"
}

mtproto_3xui_mtg_full_secret_hex(){
  local raw="${1:-}" domain_hex
  [[ -n "$raw" ]] || raw="$(mtproto_3xui_mtg_generate_raw_secret_hex)"
  mtproto_3xui_mtg_validate_raw_secret_hex "$raw"
  domain_hex="$(mtproto_3xui_mtg_secret_domain_hex)"
  printf 'ee%s%s' "${raw,,}" "${domain_hex,,}"
}

mtproto_3xui_mtg_validate_full_secret_hex(){
  local secret="${1:-}" domain_hex
  domain_hex="$(mtproto_3xui_mtg_secret_domain_hex)"
  [[ "$secret" =~ ^ee[0-9a-fA-F]+$ ]] || fail "FULL_EE_SECRET_HEX must be an ee-prefixed hex string"
  [[ "${secret,,}" == ee*"${domain_hex,,}" ]] || fail "FULL_EE_SECRET_HEX suffix must be hex(SYNC_DOMAIN)"
}

mtproto_3xui_mtg_api_base(){
  printf '%s/panel/api/inbounds' "$(xpam_xui_panel_base_url)"
}

mtproto_3xui_mtg_payload(){
  uses_mtproto || fail "3x-ui MTG payload requires an MTProto-capable profile"
  local payload="${1:-}" full_secret="${2:-}" port="${3:-$MTPROTO_PORT}" remark="${4:-}" tag
  [[ -n "$payload" ]] || fail "mtproto_3xui_mtg_payload requires output payload path"
  [[ -n "$remark" ]] || remark="$(mtproto_3xui_mtg_managed_remark)"
  [[ -n "$full_secret" ]] || full_secret="$(mtproto_3xui_mtg_full_secret_hex)"
  mtproto_3xui_mtg_validate_full_secret_hex "$full_secret"
  validate_port MTPROTO_PORT "$port"
  validate_port SYNC_BACKEND_PORT "$SYNC_BACKEND_PORT"
  validate_domain SYNC_DOMAIN "$SYNC_DOMAIN"
  tag="in-${port}-tcp"
  XPAM_MTG_PAYLOAD_PATH="$payload" \
  XPAM_MTG_REMARK="$remark" \
  XPAM_MTG_LISTEN="127.0.0.1" \
  XPAM_MTG_PORT="$port" \
  XPAM_MTG_SECRET="$full_secret" \
  XPAM_MTG_SYNC_DOMAIN="$SYNC_DOMAIN" \
  XPAM_MTG_SYNC_BACKEND_PORT="$SYNC_BACKEND_PORT" \
  XPAM_MTG_TAG="$tag" \
  XPAM_MTG_PREFIX="${SERVER_PREFIX:-}" \
  python3 <<'PY_XPAM_3XUI_MTG_PAYLOAD'
import json, os, uuid, secrets
payload_path=os.environ['XPAM_MTG_PAYLOAD_PATH']
secret=os.environ['XPAM_MTG_SECRET']
# MTProto became multi-client in 3x-ui 3.5.0: mtg reads the secret from
# settings.clients[], and the add API strips any inbound-level settings.secret.
# 3x-ui <= 3.4.2 is the opposite — mtg reads the inbound-level settings.secret,
# and its add API has no mtproto client case, so it rejects a client whose id is
# empty ("empty client ID"). Emit BOTH shapes so one payload creates a working
# MTG inbound on either version:
#   * top-level secret  -> drives mtg on <=3.4.2; harmlessly stripped by 3.5.0.
#   * clients[0]        -> drives mtg on >=3.5.0; carries an id so 3.4.2's guard
#                          passes and the same secret so 3.5.0's guard passes.
# The client secret is already a valid FakeTLS value, so 3.5.0's secret healing
# rebuilds it byte-identically (no-op).
#
# subId: gives the client a subscription id like the VLESS client has, so 3.5.0's
# Clients page can render its link/QR (the panel builds those from subId via its
# own API — no public subscription listener needed, which XPAM keeps disabled).
# comment: the panel's mtproto copy-link/QR hardcodes the inbound's INTERNAL port
# (genMtprotoLink uses inbound.Port; 3x-ui has no externalProxy for mtproto), so
# it is display-only and does not connect. Point whoever reads it in the panel at
# the authoritative :443 link from the XPAM links launcher.
prefix=os.environ.get('XPAM_MTG_PREFIX','').strip()
comment=('Рабочая MTG-ссылка (:443): sudo %s-links --show-secrets. '
         'Панельная copy-ссылка/QR имеют внутренний порт и не подключаются.' % prefix) if prefix \
        else 'Рабочая MTG-ссылка (:443) — в выводе XPAM links --show-secrets; панельный QR имеет внутренний порт.'
settings={
    'fakeTlsDomain': os.environ['XPAM_MTG_SYNC_DOMAIN'],
    'secret': secret,
    'clients': [
        {
            'id': str(uuid.uuid4()),
            'secret': secret,
            'email': os.environ['XPAM_MTG_REMARK'],
            'subId': secrets.token_hex(8),
            'comment': comment,
            'enable': True,
        }
    ],
    'preferIp': 'prefer-ipv4',
    'domainFronting': {
        'ip': '127.0.0.1',
        'port': int(os.environ['XPAM_MTG_SYNC_BACKEND_PORT']),
    },
}
payload={
    'up': 0,
    'down': 0,
    'total': 0,
    'remark': os.environ['XPAM_MTG_REMARK'],
    'enable': True,
    'expiryTime': 0,
    'listen': os.environ['XPAM_MTG_LISTEN'],
    'port': int(os.environ['XPAM_MTG_PORT']),
    'protocol': 'mtproto',
    'settings': json.dumps(settings, separators=(',', ':')),
    'streamSettings': '',
    'tag': os.environ['XPAM_MTG_TAG'],
    'sniffing': '',
    # No 'allocate' key: not a field of 3x-ui v3.x model.Inbound (silently dropped); "always" is Xray's
    # default for this fixed-port inbound anyway.
    'shareAddrStrategy': 'custom',
    'shareAddr': os.environ['XPAM_MTG_SYNC_DOMAIN'],
}
with open(payload_path, 'w', encoding='utf-8') as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
PY_XPAM_3XUI_MTG_PAYLOAD
}

mtproto_3xui_mtg_api_list(){
  local out_file="${1:-}" err_file="${2:-}"
  [[ -n "$out_file" && -n "$err_file" ]] || fail "mtproto_3xui_mtg_api_list requires out and err paths"
  xpam_xui_api_get_json "$(mtproto_3xui_mtg_api_base)/list" "$out_file" "$err_file"
}

mtproto_3xui_mtg_api_get(){
  local inbound_id="${1:-}" out_file="${2:-}" err_file="${3:-}"
  [[ "$inbound_id" =~ ^[0-9]+$ ]] || fail "3x-ui MTG inbound id must be numeric"
  [[ -n "$out_file" && -n "$err_file" ]] || fail "mtproto_3xui_mtg_api_get requires id, out and err paths"
  xpam_xui_api_get_json "$(mtproto_3xui_mtg_api_base)/get/${inbound_id}" "$out_file" "$err_file"
}

mtproto_3xui_mtg_api_add(){
  local payload="${1:-}" out_file="${2:-}" err_file="${3:-}"
  [[ -s "$payload" ]] || fail "3x-ui MTG add payload missing or empty: $payload"
  [[ -n "$out_file" && -n "$err_file" ]] || fail "mtproto_3xui_mtg_api_add requires payload, out and err paths"
  xpam_xui_api_post_json "$(mtproto_3xui_mtg_api_base)/add" "$payload" "$out_file" "$err_file"
}

mtproto_3xui_mtg_api_update(){
  local inbound_id="${1:-}" payload="${2:-}" out_file="${3:-}" err_file="${4:-}"
  [[ "$inbound_id" =~ ^[0-9]+$ ]] || fail "3x-ui MTG inbound id must be numeric"
  [[ -s "$payload" ]] || fail "3x-ui MTG update payload missing or empty: $payload"
  [[ -n "$out_file" && -n "$err_file" ]] || fail "mtproto_3xui_mtg_api_update requires id, payload, out and err paths"
  xpam_xui_api_post_json "$(mtproto_3xui_mtg_api_base)/update/${inbound_id}" "$payload" "$out_file" "$err_file"
}

mtproto_3xui_mtg_api_delete(){
  local inbound_id="${1:-}" out_file="${2:-}" err_file="${3:-}" payload rc
  [[ "$inbound_id" =~ ^[0-9]+$ ]] || fail "3x-ui MTG inbound id must be numeric"
  [[ -n "$out_file" && -n "$err_file" ]] || fail "mtproto_3xui_mtg_api_delete requires id, out and err paths"
  payload="$(mktemp /tmp/xpam-3xui-mtg-delete.XXXXXX.json)"
  printf '{}\n' > "$payload"
  if xpam_xui_api_post_json "$(mtproto_3xui_mtg_api_base)/del/${inbound_id}" "$payload" "$out_file" "$err_file"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$payload"
  return "$rc"
}

mtproto_3xui_mtg_extract_managed_id(){
  local list_json="${1:-}" remark="${2:-}"
  [[ -s "$list_json" ]] || fail "3x-ui API list JSON missing or empty: $list_json"
  [[ -n "$remark" ]] || remark="$(mtproto_3xui_mtg_managed_remark)"
  XPAM_MTG_LIST_JSON="$list_json" XPAM_MTG_REMARK="$remark" python3 <<'PY_XPAM_3XUI_MTG_EXTRACT_ID'
import json, os, sys
path=os.environ['XPAM_MTG_LIST_JSON']
remark=os.environ['XPAM_MTG_REMARK']
try:
    data=json.load(open(path, encoding='utf-8'))
except Exception:
    sys.exit(1)
items=data.get('obj') or []
if isinstance(items, dict):
    items=items.get('inbounds') or items.get('items') or []
matches=[]
for item in items:
    if not isinstance(item, dict):
        continue
    if str(item.get('protocol') or '').lower() != 'mtproto':
        continue
    if str(item.get('remark') or '') != remark:
        continue
    inbound_id=item.get('id')
    if isinstance(inbound_id, int):
        matches.append(inbound_id)
if len(matches) == 1:
    print(matches[0])
    sys.exit(0)
sys.exit(1)
PY_XPAM_3XUI_MTG_EXTRACT_ID
}


mtproto_3xui_mtg_extract_managed_ids(){
  local list_json="${1:-}" remark="${2:-}"
  [[ -s "$list_json" ]] || fail "3x-ui API list JSON missing or empty: $list_json"
  [[ -n "$remark" ]] || remark="$(mtproto_3xui_mtg_managed_remark)"
  XPAM_MTG_LIST_JSON="$list_json" XPAM_MTG_REMARK="$remark" python3 <<'PY_XPAM_3XUI_MTG_EXTRACT_IDS'
import json, os, sys
path=os.environ['XPAM_MTG_LIST_JSON']
remark=os.environ['XPAM_MTG_REMARK']
try:
    data=json.load(open(path, encoding='utf-8'))
except Exception:
    sys.exit(1)
items=data.get('obj') or []
if isinstance(items, dict):
    items=items.get('inbounds') or items.get('items') or []
for item in items if isinstance(items, list) else []:
    if not isinstance(item, dict):
        continue
    if str(item.get('protocol') or '').lower() != 'mtproto':
        continue
    if str(item.get('remark') or '') != remark:
        continue
    inbound_id=item.get('id')
    if isinstance(inbound_id, int):
        print(inbound_id)
PY_XPAM_3XUI_MTG_EXTRACT_IDS
}

mtproto_3xui_mtg_assert_api_success(){
  local json_file="${1:-}" label="${2:-3x-ui MTG API call}" msg
  [[ -s "$json_file" ]] || fail "$label returned empty response"
  msg="$(XPAM_MTG_API_RESPONSE="$json_file" python3 <<'PY_XPAM_3XUI_MTG_API_SUCCESS'
import json, os, sys
path=os.environ['XPAM_MTG_API_RESPONSE']
try:
    data=json.load(open(path, encoding='utf-8'))
except Exception as exc:
    print(f'non-JSON response: {exc}')
    sys.exit(2)
if data.get('success') is True:
    sys.exit(0)
print(str(data.get('msg') or data.get('message') or data)[:500])
sys.exit(1)
PY_XPAM_3XUI_MTG_API_SUCCESS
  )" || fail "$label failed: ${msg:-unknown API error}"
}

mtproto_3xui_mtg_extract_secret_from_json(){
  local json_file="${1:-}" remark="${2:-}"
  [[ -s "$json_file" ]] || return 1
  [[ -n "$remark" ]] || remark="$(mtproto_3xui_mtg_managed_remark)"
  XPAM_MTG_JSON="$json_file" XPAM_MTG_REMARK="$remark" python3 <<'PY_XPAM_3XUI_MTG_SECRET_FROM_JSON'
import json, os, sys
path=os.environ['XPAM_MTG_JSON']
remark=os.environ['XPAM_MTG_REMARK']
try:
    data=json.load(open(path, encoding='utf-8'))
except Exception:
    sys.exit(1)

def unwrap(obj):
    if isinstance(obj, dict) and 'obj' in obj:
        return obj.get('obj')
    return obj

def items(obj):
    obj=unwrap(obj)
    if isinstance(obj, dict):
        if str(obj.get('protocol') or '').lower() == 'mtproto' and str(obj.get('remark') or '') == remark:
            return [obj]
        for key in ('inbounds','items'):
            val=obj.get(key)
            if isinstance(val, list):
                return val
        return []
    if isinstance(obj, list):
        return obj
    return []

def settings_from(item):
    raw=item.get('settings')
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw.strip():
        try:
            return json.loads(raw)
        except Exception:
            return {}
    return {}
def mtg_secret_from(settings):
    # 3x-ui > 3.4.2: per-client secrets in settings.clients; <= 3.4.2: settings.secret.
    clients=settings.get('clients')
    if isinstance(clients, list):
        for c in clients:
            if not isinstance(c, dict):
                continue
            if str(c.get('enable', True)).lower() in ('false', '0', 'no', 'off'):
                continue
            s=str(c.get('secret') or '').strip()
            if s:
                return s
    return str(settings.get('secret') or '').strip()
for item in items(data):
    if not isinstance(item, dict):
        continue
    if str(item.get('protocol') or '').lower() != 'mtproto':
        continue
    if str(item.get('remark') or '') != remark:
        continue
    secret=mtg_secret_from(settings_from(item))
    if secret:
        print(secret)
        sys.exit(0)
sys.exit(1)
PY_XPAM_3XUI_MTG_SECRET_FROM_JSON
}

mtproto_3xui_mtg_note_path(){
  printf '/root/secure-notes/%s-mtproto.txt' "$SERVER_PREFIX"
}

mtproto_3xui_mtg_write_notes(){
  # Compatibility wrapper kept for older call-sites. For 3xui-mtg,
  # Telegram link source-of-truth is the 3x-ui SQLite DB, not a secure-note.
  local note legacy_dir ts base
  note="$(mtproto_3xui_mtg_note_path)"
  if [[ -f "$note" ]]; then
    legacy_dir="/root/secure-notes/legacy"
    mkdir -p "$legacy_dir"
    chmod 700 /root/secure-notes "$legacy_dir" 2>/dev/null || true
    ts="$(date +%Y%m%d-%H%M%S)"
    base="$(basename "$note")"
    mv -f "$note" "$legacy_dir/${base}.${ts}.bak" 2>/dev/null || rm -f "$note" 2>/dev/null || true
    chmod 600 "$legacy_dir/${base}.${ts}.bak" 2>/dev/null || true
  fi
  return 0
}

mtproto_3xui_mtg_stop_disable_alexbers(){
  systemctl stop mtprotoproxy.service >/dev/null 2>&1 || true
  systemctl disable mtprotoproxy.service >/dev/null 2>&1 || true
  systemctl reset-failed mtprotoproxy.service >/dev/null 2>&1 || true
}

mtproto_3xui_mtg_wait_runtime(){
  write_wait_for_port
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$MTPROTO_PORT" 60 3xui-mtg-backend
}

mtproto_3xui_mtg_assert_runtime_port_owner(){
  local all rows
  all="$(ss -H -ltnp 2>/dev/null | awk -v p=":${MTPROTO_PORT}" '$4 ~ p"$" {print}' || true)"
  rows="$(printf '%s\n' "$all" | awk -v p="127.0.0.1:${MTPROTO_PORT}" '$4 == p {print}' || true)"
  [[ -n "$rows" ]] || fail "No 127.0.0.1:${MTPROTO_PORT} listener found for 3xui-mtg"
  if printf '%s\n' "$all" | awk -v p="127.0.0.1:${MTPROTO_PORT}" 'NF && $4 != p {bad=1} END{exit bad?0:1}'; then
    fail "MTPROTO_PORT=${MTPROTO_PORT} has a non-loopback listener under 3xui-mtg"
  fi
  if printf '%s\n' "$all" | grep -Fq 'mtprotoproxy'; then
    fail "mtprotoproxy still owns or shares MTPROTO_PORT=${MTPROTO_PORT}"
  fi
  if printf '%s\n' "$rows" | grep -Eq 'mtg-linux|mtg-linux-amd64'; then
    ok "3xui-mtg owns 127.0.0.1:${MTPROTO_PORT}"
  else
    warn "127.0.0.1:${MTPROTO_PORT} is listening, but process name was not clearly mtg-linux-amd64"
  fi
}

mtproto_3xui_mtg_runtime_invariants_ok(){
  uses_mtproto || return 0
  [[ "$(mtproto_backend_effective)" == "3xui-mtg" ]] || return 1
  [[ -n "${SERVER_PREFIX:-}" && -n "${SYNC_DOMAIN:-}" && -n "${MTPROTO_PORT:-}" ]] || return 1

  systemctl is-active --quiet x-ui || return 1
  if systemctl is-active --quiet mtprotoproxy.service; then
    return 1
  fi
  if systemctl cat haproxy.service 2>/dev/null | grep -Fq 'mtprotoproxy.service'; then
    return 1
  fi

  local all rows mtg_rows tmp list err id_count
  all="$(ss -H -ltnp 2>/dev/null | awk -v p=":${MTPROTO_PORT}" '$4 ~ p"$" {print}' || true)"
  rows="$(printf '%s\n' "$all" | awk -v p="127.0.0.1:${MTPROTO_PORT}" '$4 == p {print}' || true)"
  [[ -n "$rows" ]] || return 1
  if printf '%s\n' "$all" | awk -v p="127.0.0.1:${MTPROTO_PORT}" 'NF && $4 != p {bad=1} END{exit bad?0:1}'; then
    return 1
  fi
  printf '%s\n' "$rows" | grep -Eq 'mtg-linux|mtg-linux-amd64' || return 1
  printf '%s\n' "$all" | grep -Fq 'mtprotoproxy' && return 1

  mtg_rows="$(ss -H -ltnp 2>/dev/null | grep -E 'mtg-linux|mtg-linux-amd64' || true)"
  [[ -n "$mtg_rows" ]] || return 1
  if printf '%s\n' "$mtg_rows" | awk 'NF && $4 !~ /^127\.0\.0\.1:/ {bad=1} END{exit bad?0:1}'; then
    return 1
  fi

  # Telegram link is generated from the current 3x-ui DB on demand.
  # A legacy /root/secure-notes/*-mtproto.txt file is not required.

  tmp="$(mktemp -d /tmp/xpam-3xui-mtg-invariant.XXXXXX)" || return 1
  list="$tmp/list.json"; err="$tmp/err.txt"
  if ! mtproto_3xui_mtg_api_list "$list" "$err" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  if ! mtproto_3xui_mtg_assert_api_success "$list" "3x-ui MTG API list" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  id_count="$(mtproto_3xui_mtg_extract_managed_ids "$list" 2>/dev/null | awk 'NF {c++} END{print c+0}')"
  rm -rf "$tmp"
  [[ "$id_count" == "1" ]] || return 1

  return 0
}

mtproto_3xui_mtg_repair_if_needed(){
  uses_mtproto || return 0
  # Wait for the mtg sidecar to rebind before judging it. `repair` calls this immediately after
  # `systemctl try-restart x-ui` (xpam-core.sh), and 3x-ui needs a moment to respawn mtg. Without
  # the wait the invariant sees ZERO mtg listeners, declares failure, and triggers a full MTG
  # reinstall on EVERY repair and weekly run. That reinstall preserves the secret — so the user's
  # Telegram link keeps working — but it re-mints the managed client's `id` and `subId`, which
  # changes the panel's per-client link/QR (the whole point of D-3) and rewrites the row each time.
  # Measured on a live box 2026-07-29: invariant exit=1 with 0 listeners at t+0s, exit=0 with 2
  # listeners by t+1s. The helper already exists and bounds the wait at 60s, after which a genuinely
  # dead runtime still fails the invariant and gets repaired exactly as before.
  mtproto_3xui_mtg_wait_runtime >/dev/null 2>&1 || true
  if mtproto_3xui_mtg_runtime_invariants_ok; then
    ok "3x-ui MTG runtime invariants already OK; repair skipped"
    return 0
  fi
  warn "3x-ui MTG runtime invariant check failed; repairing MTG runtime"
  mtproto_3xui_mtg_install
}

mtproto_3xui_mtg_restart_runtime(){
  mtproto_3xui_mtg_stop_disable_alexbers
  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl restart x-ui || fail "x-ui restart failed for 3xui-mtg runtime"
  sleep 2
  mtproto_3xui_mtg_wait_runtime
  mtproto_3xui_mtg_assert_runtime_port_owner
}

# Purge the XPAM-managed mtproto client(s) left orphaned by an inbound delete. 3x-ui 3.x makes a client
# a first-class many-to-many entity, so DelInbound removes the inbound + client_inbounds junction but
# LEAVES the `clients` row + client_traffics behind (no ON DELETE CASCADE) — mirroring the xhttp/alt
# teardown. $1 = newline-separated emails captured from the inbound's client_inbounds BEFORE deletion
# (rename-safe: found by their link to the inbound, not a hardcoded name the operator may have changed);
# the deterministic managed email <prefix>-mtproto is always added as a fallback for when the junction
# was already gone. An mtproto client the operator added by hand under a different inbound keeps its
# data. PRIMARY = 3x-ui's own client API (schema-agnostic); DEFENSIVE FALLBACK = direct SQL by email.
mtproto_3xui_mtg_purge_managed_client(){
  local db=/etc/x-ui/x-ui.db base body email captured="${1:-}" emails
  emails="$(printf '%s\n%s\n' "$captured" "$(mtproto_3xui_mtg_managed_remark)" | awk 'NF && !seen[$0]++')"
  base="$(xpam_xui_panel_base_url 2>/dev/null || true)"
  { [[ -n "$base" ]] && xui_ensure_api_token >/dev/null 2>&1; } || base=""
  while IFS= read -r email; do
    [[ -n "$email" ]] || continue
    if [[ -n "$base" ]]; then
      body="$(mktemp /tmp/xpam-mtg-cdel.XXXXXX.json)"; printf '{}' > "$body"
      xpam_xui_api_post_json "$base/panel/api/clients/del/${email}" "$body" \
        /tmp/xpam-mtg-cdel.out /tmp/xpam-mtg-cdel.err >/dev/null 2>&1 || true
      rm -f "$body"
    fi
    if command -v sqlite3 >/dev/null 2>&1; then
      sqlite3 "$db" "DELETE FROM client_traffics WHERE email='${email}';" 2>/dev/null || true
      sqlite3 "$db" "DELETE FROM clients WHERE email='${email}';" 2>/dev/null || true
      sqlite3 "$db" "DELETE FROM client_global_traffics WHERE email='${email}';" 2>/dev/null || true
      sqlite3 "$db" "DELETE FROM node_client_traffics WHERE email='${email}';" 2>/dev/null || true
      sqlite3 "$db" "DELETE FROM inbound_client_ips WHERE client_email='${email}';" 2>/dev/null || true
    fi
  done <<< "$emails"
}

mtproto_3xui_mtg_delete_managed_if_present(){
  uses_mtproto || return 0
  systemctl is-active --quiet x-ui || return 0
  local tmp list out err id ids emails="" db=/etc/x-ui/x-ui.db
  tmp="$(mktemp -d /tmp/xpam-3xui-mtg-cleanup.XXXXXX)" || return 0
  list="$tmp/list.json"; out="$tmp/out.json"; err="$tmp/err.txt"
  if mtproto_3xui_mtg_api_list "$list" "$err" >/dev/null 2>&1; then
    ids="$(mtproto_3xui_mtg_extract_managed_ids "$list" 2>/dev/null || true)"
    # Capture the client email(s) bound to each managed inbound BEFORE deletion (the client_inbounds
    # junction is dropped once the inbound is gone), so cleanup is rename-safe.
    for id in $ids; do
      emails+="$(sqlite3 "$db" "SELECT c.email FROM clients c JOIN client_inbounds ci ON ci.client_id=c.id WHERE ci.inbound_id=${id};" 2>/dev/null || true)"$'\n'
    done
    for id in $ids; do
      mtproto_3xui_mtg_api_delete "$id" "$out" "$err" >/dev/null 2>&1 || true
    done
    # Clean the now-orphaned XPAM-managed mtproto client(s) (see helper above). Before the restart so
    # x-ui re-reads the cleaned tables.
    mtproto_3xui_mtg_purge_managed_client "$emails" || true
    if [[ -s "$out" ]]; then
      systemctl restart x-ui >/dev/null 2>&1 || true
      sleep 2
    fi
  fi
  rm -rf "$tmp"
}

mtproto_3xui_mtg_install(){
  uses_mtproto || return 0
  say "Preparing 3x-ui MTG runtime"
  write_wait_for_port
  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl start x-ui || fail "x-ui start failed for 3xui-mtg runtime"
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 30 xui-panel
  xui_ensure_api_token || fail "Could not obtain usable 3x-ui API token for MTG runtime"

  local tmp list get out err payload id ids id_count full_secret extracted
  tmp="$(mktemp -d /tmp/xpam-3xui-mtg-install.XXXXXX)"
  list="$tmp/list.json"; get="$tmp/get.json"; out="$tmp/out.json"; err="$tmp/err.txt"; payload="$tmp/payload.json"

  mtproto_3xui_mtg_api_list "$list" "$err" || { cat "$err" >&2 2>/dev/null || true; rm -rf "$tmp"; fail "3x-ui MTG API list failed"; }
  mtproto_3xui_mtg_assert_api_success "$list" "3x-ui MTG API list"
  ids="$(mtproto_3xui_mtg_extract_managed_ids "$list" 2>/dev/null || true)"
  id="$(awk 'NF {print; exit}' <<<"$ids")"
  id_count="$(awk 'NF {c++} END{print c+0}' <<<"$ids")"
  if [[ "$id_count" -gt 1 ]]; then
    rm -rf "$tmp"
    fail "Multiple XPAM-managed 3x-ui MTG inbounds found; refusing to choose one automatically"
  fi

  if [[ -n "$id" ]]; then
    mtproto_3xui_mtg_api_get "$id" "$get" "$err" || { cat "$err" >&2 2>/dev/null || true; rm -rf "$tmp"; fail "3x-ui MTG API get failed for inbound id $id"; }
    mtproto_3xui_mtg_assert_api_success "$get" "3x-ui MTG API get"
    extracted="$(mtproto_3xui_mtg_extract_secret_from_json "$get" 2>/dev/null || true)"
    if [[ -n "$extracted" && "$extracted" =~ ^ee[0-9a-fA-F]+$ && "${extracted,,}" == ee*"$(mtproto_3xui_mtg_secret_domain_hex)" ]]; then
      full_secret="${extracted,,}"
    else
      full_secret="$(mtproto_3xui_mtg_full_secret_hex)"
    fi
  else
    full_secret="$(mtproto_3xui_mtg_full_secret_hex)"
  fi

  mtproto_3xui_mtg_payload "$payload" "$full_secret" "$MTPROTO_PORT"
  mtproto_3xui_mtg_stop_disable_alexbers

  if [[ -n "$id" ]]; then
    mtproto_3xui_mtg_api_update "$id" "$payload" "$out" "$err" || { cat "$err" >&2 2>/dev/null || true; rm -rf "$tmp"; fail "3x-ui MTG API update failed"; }
    mtproto_3xui_mtg_assert_api_success "$out" "3x-ui MTG API update"
  else
    mtproto_3xui_mtg_api_add "$payload" "$out" "$err" || { cat "$err" >&2 2>/dev/null || true; rm -rf "$tmp"; fail "3x-ui MTG API add failed"; }
    mtproto_3xui_mtg_assert_api_success "$out" "3x-ui MTG API add"
  fi

  mtproto_3xui_mtg_write_notes "$full_secret"
  if ! mtproto_3xui_mtg_wait_runtime; then
    systemctl restart x-ui || true
    sleep 2
    mtproto_3xui_mtg_wait_runtime
  fi
  mtproto_3xui_mtg_assert_runtime_port_owner
  rm -rf "$tmp"
  ok "3x-ui MTG runtime prepared"
}

mtproto_backend_install(){
  uses_mtproto || return 0
  mtproto_3xui_mtg_install "$@"
}

mtproto_backend_restart_runtime(){
  uses_mtproto || return 0
  mtproto_3xui_mtg_restart_runtime
}

mtproto_backend_repair_after_update(){
  uses_mtproto || return 0
  mtproto_3xui_mtg_repair_if_needed
}
