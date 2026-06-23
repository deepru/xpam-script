#!/usr/bin/env bash
# XPAM Script 3x-ui compatibility layer.
# Keep upstream 3x-ui assumptions here, not scattered across xpam-core.sh.

xpam_xui_api_token_file(){
  echo "${CONFIG_DIR:-/etc/xpam-script}/x-ui-api-token"
}

xpam_xui_panel_base_url(){
  local panel_path_clean
  panel_path_clean="${PANEL_PATH#/}"
  panel_path_clean="${panel_path_clean%/}"
  printf 'https://127.0.0.1:%s/%s' "${XUI_PANEL_PORT}" "${panel_path_clean}"
}


xpam_xui_download_url(){
  local url="$1" out="$2" label="${3:-3x-ui file}" ip
  rm -f "$out"
  if curl --http1.1 -fsSL --connect-timeout 20 --max-time 120 --retry 5 --retry-delay 2 --retry-all-errors -o "$out" "$url"; then
    return 0
  fi
  case "$url" in
    *github.com/*|*githubusercontent.com/*) ;;
    *) return 1 ;;
  esac
  warn "Не удалось скачать ${label} обычным способом; пробую GitHub CDN fallback"
  for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
    rm -f "$out"
    if curl --http1.1 -fsSL --connect-timeout 15 --max-time 120 --retry 1 --retry-delay 1 --retry-all-errors \
      --resolve "release-assets.githubusercontent.com:443:${ip}" \
      --resolve "raw.githubusercontent.com:443:${ip}" \
      --resolve "objects.githubusercontent.com:443:${ip}" \
      -o "$out" "$url"; then
      ok "GitHub CDN fallback сработал для ${label}: ${ip}"
      return 0
    fi
  done
  rm -f "$out"
  return 1
}

xpam_xui_apply_fail2ban_optout(){
  local env_file="/etc/default/x-ui" tmp cli="/usr/bin/x-ui"
  mkdir -p /etc/default
  touch "$env_file"
  chmod 644 "$env_file" 2>/dev/null || true
  if grep -q '^XUI_ENABLE_FAIL2BAN=' "$env_file" 2>/dev/null; then
    sed -i 's/^XUI_ENABLE_FAIL2BAN=.*/XUI_ENABLE_FAIL2BAN=false/' "$env_file"
  else
    printf '\n# Managed by XPAM Script: XPAM owns fail2ban; 3x-ui IP-limit fail2ban setup is disabled.\nXUI_ENABLE_FAIL2BAN=false\n' >> "$env_file"
  fi

  if [[ -f "$cli" ]] && head -n1 "$cli" 2>/dev/null | grep -Eq '^#!.*(sh|bash)'; then
    if ! grep -q 'XPAM BEGIN XUI FAIL2BAN OPTOUT' "$cli" 2>/dev/null; then
      tmp="$(mktemp /tmp/xpam-xui-cli.XXXXXX)" || return 0
      awk 'NR==1 {print; print "# XPAM BEGIN XUI FAIL2BAN OPTOUT"; print "export XUI_ENABLE_FAIL2BAN=\"${XUI_ENABLE_FAIL2BAN:-false}\""; print "# XPAM END XUI FAIL2BAN OPTOUT"; next} {print}' "$cli" > "$tmp" && cat "$tmp" > "$cli"
      rm -f "$tmp"
      chmod +x "$cli" 2>/dev/null || true
    fi
  fi
}

xpam_xui_redact_output(){
  sed -E \
    -e 's/([Aa][Pp][Ii][ _-]?[Tt]oken[^:]*:[[:space:]]*)[^[:space:]]+/\1[redacted]/g' \
    -e 's/([Tt]oken[^:]*:[[:space:]]*)[^[:space:]]+/\1[redacted]/g' \
    -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._~+\/=:-]{16,}/\1[redacted]/g'
}

xpam_xui_store_api_token(){
  local token="${1:-}" file tmp dir
  [[ -n "$token" ]] || return 1
  file="$(xpam_xui_api_token_file)"
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$(mktemp "${dir}/.x-ui-api-token.XXXXXX")" || return 1
  umask 077
  printf '%s\n' "$token" > "$tmp"
  chown root:root "$tmp" 2>/dev/null || true
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
  chown root:root "$file" 2>/dev/null || true
  chmod 600 "$file" 2>/dev/null || true
}

xpam_xui_read_stored_api_token(){
  local file token
  file="$(xpam_xui_api_token_file)"
  [[ -f "$file" ]] || return 1
  token="$(head -n 1 "$file" 2>/dev/null | tr -d '\r\n' || true)"
  [[ -n "$token" ]] || return 1
  printf '%s\n' "$token"
}

xpam_xui_extract_api_token_from_output(){
  python3 - <<'PY_XPAM_XUI_EXTRACT_TOKEN'
import re, sys
text=sys.stdin.read()
# Prefer labelled token lines. The 3x-ui CLI/installer wording has changed across releases,
# so keep this parser deliberately conservative and verify the candidate with Bearer API later.
labelled=[]
for line in text.splitlines():
    if re.search(r'api[ _-]*token|bearer token|token', line, re.I):
        labelled.extend(re.findall(r'[A-Za-z0-9._~+/=-]{16,}', line))
if labelled:
    print(labelled[-1])
    sys.exit(0)
all_candidates=re.findall(r'[A-Za-z0-9._~+/=-]{32,}', text)
if all_candidates:
    print(all_candidates[-1])
PY_XPAM_XUI_EXTRACT_TOKEN
}

xpam_xui_api_token_usable(){
  local token="${1:-}" base
  [[ -n "$token" ]] || return 1
  base="$(xpam_xui_panel_base_url)"
  XPAM_XUI_API_TOKEN="$token" XPAM_XUI_API_URL="${base}/panel/api/inbounds/list" python3 - <<'PY_XPAM_XUI_TOKEN_USABLE' >/dev/null 2>&1
import json, os, ssl, sys, urllib.error, urllib.request
url=os.environ['XPAM_XUI_API_URL']
token=os.environ['XPAM_XUI_API_TOKEN']
ctx=ssl._create_unverified_context()
req=urllib.request.Request(url, headers={
    'Authorization': 'Bearer '+token,
    'Accept': 'application/json',
    'User-Agent': 'XPAM-Script/3x-ui-compat'
})
try:
    with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
        body=resp.read(1024*1024).decode('utf-8', 'replace')
except Exception:
    sys.exit(1)
try:
    data=json.loads(body)
except Exception:
    sys.exit(1)
if data.get('success') is True:
    sys.exit(0)
sys.exit(1)
PY_XPAM_XUI_TOKEN_USABLE
}

xpam_xui_get_cli_api_token(){
  [[ -x /usr/local/x-ui/x-ui ]] || return 1
  local out token
  out="$(/usr/local/x-ui/x-ui setting -getApiToken true 2>&1 || true)"
  token="$(printf '%s' "$out" | xpam_xui_extract_api_token_from_output || true)"
  [[ -n "$token" ]] || return 1
  printf '%s\n' "$token"
}

xpam_xui_create_api_token_via_session(){
  local base
  [[ -n "${XUI_ADMIN_USER:-}" && -n "${XUI_ADMIN_PASS:-}" ]] || return 1
  base="$(xpam_xui_panel_base_url)"
  XPAM_XUI_BASE_URL="$base" XPAM_XUI_ADMIN_USER="$XUI_ADMIN_USER" XPAM_XUI_ADMIN_PASS="$XUI_ADMIN_PASS" python3 - <<'PY_XPAM_XUI_SESSION_TOKEN'
import json, os, re, ssl, sys, time, urllib.parse, urllib.request
from http.cookiejar import CookieJar
from urllib.request import HTTPCookieProcessor, build_opener

base=os.environ['XPAM_XUI_BASE_URL'].rstrip('/')
username=os.environ['XPAM_XUI_ADMIN_USER']
password=os.environ['XPAM_XUI_ADMIN_PASS']
ctx=ssl._create_unverified_context()
cj=CookieJar()
opener=build_opener(HTTPCookieProcessor(cj), urllib.request.HTTPSHandler(context=ctx))

def req(method, url, data=None, headers=None, opener_obj=None):
    headers=headers or {}
    r=urllib.request.Request(url, data=data, method=method, headers=headers)
    active_opener=opener_obj or opener
    with active_opener.open(r, timeout=20) as resp:
        return resp.read(2*1024*1024).decode('utf-8', 'replace')

def load(body):
    try:
        return json.loads(body)
    except Exception:
        return {}

def token_candidates(obj):
    found=[]
    def walk(x):
        if isinstance(x, dict):
            for k, v in x.items():
                lk=str(k).lower()
                if isinstance(v, str) and ('token' in lk or 'api' in lk):
                    found.append(v.strip())
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
        elif isinstance(x, str):
            found.extend(re.findall(r'[A-Za-z0-9._~+/=-]{24,}', x))
    walk(obj)
    clean=[]
    seen=set()
    for item in found:
        if item and item not in seen:
            seen.add(item)
            clean.append(item)
    return clean

def api_check(token):
    # Validate behaviour, not token shape/version. This rejects hashed-at-rest DB values,
    # empty CLI output, and any response candidate that is not a usable Bearer token.
    try:
        r=urllib.request.Request(base + '/panel/api/inbounds/list', headers={
            'Authorization': 'Bearer '+token,
            'Accept': 'application/json',
            'User-Agent': 'XPAM-Script/3x-ui-compat',
        })
        with urllib.request.urlopen(r, timeout=15, context=ctx) as resp:
            data=json.loads(resp.read(2*1024*1024).decode('utf-8', 'replace'))
        return data.get('success') is True
    except Exception:
        return False

try:
    body=req('GET', base + '/csrf-token', headers={'Accept':'application/json','User-Agent':'XPAM-Script/3x-ui-compat'})
    csrf=load(body).get('obj') or ''
    if not csrf:
        sys.exit(1)

    login_data=urllib.parse.urlencode({'username':username,'password':password,'twoFactorCode':''}).encode()
    body=req('POST', base + '/login', data=login_data, headers={
        'Content-Type':'application/x-www-form-urlencoded',
        'Accept':'application/json',
        'X-CSRF-Token': csrf,
        'User-Agent':'XPAM-Script/3x-ui-compat',
    })
    if load(body).get('success') is not True:
        sys.exit(1)

    endpoints=(
        # 3x-ui v3.3.0+: /panel/setting and /panel/xray moved under /panel/api.
        '/panel/api/setting/apiTokens/create',
        # Older 3x-ui releases.
        '/panel/setting/apiTokens/create',
    )

    for endpoint in endpoints:
        payload=json.dumps({'name':'xpam-script-%d' % int(time.time())}).encode()
        try:
            body=req('POST', base + endpoint, data=payload, headers={
                'Content-Type':'application/json',
                'Accept':'application/json',
                'X-CSRF-Token': csrf,
                'User-Agent':'XPAM-Script/3x-ui-compat',
            })
        except Exception:
            continue
        data=load(body)
        if data.get('success') is not True:
            continue
        for token in token_candidates(data):
            if api_check(token):
                print(token)
                sys.exit(0)

    sys.exit(1)
except Exception:
    sys.exit(1)
PY_XPAM_XUI_SESSION_TOKEN
}

xpam_xui_get_legacy_db_plaintext_token(){
  # Compatibility fallback only for older 3x-ui releases that stored plaintext tokens.
  # The candidate must pass a Bearer API smoke-check before XPAM stores or uses it.
  xui_assert_sqlite_backend
  python3 - <<'PY_XPAM_XUI_LEGACY_DB_TOKEN'
import sqlite3, sys
try:
    conn=sqlite3.connect('/etc/x-ui/x-ui.db')
    cur=conn.cursor()
    cols=[r[1] for r in cur.execute('PRAGMA table_info(api_tokens)').fetchall()]
    if not cols:
        sys.exit(1)
    token_col='token' if 'token' in cols else next((c for c in cols if 'token' in c.lower()), None)
    if not token_col:
        sys.exit(1)
    where='WHERE enable=1' if 'enable' in cols else ''
    order='ORDER BY id DESC' if 'id' in cols else ''
    row=cur.execute(f'SELECT {token_col} FROM api_tokens {where} {order} LIMIT 1').fetchone()
    if row and row[0]:
        print(str(row[0]))
except Exception:
    sys.exit(1)
PY_XPAM_XUI_LEGACY_DB_TOKEN
}

xui_ensure_api_token(){
  local token file
  file="$(xpam_xui_api_token_file)"

  token="$(xpam_xui_read_stored_api_token 2>/dev/null || true)"
  if [[ -n "$token" ]] && xpam_xui_api_token_usable "$token"; then
    chown root:root "$file" 2>/dev/null || true
    chmod 600 "$file" 2>/dev/null || true
    ok "3x-ui API token storage OK: $file"
    return 0
  fi

  say "Ensuring XPAM-owned 3x-ui API token storage"

  token="$(xpam_xui_get_cli_api_token 2>/dev/null || true)"
  if [[ -n "$token" ]] && xpam_xui_api_token_usable "$token"; then
    if ! xpam_xui_store_api_token "$token"; then warn "Could not store 3x-ui API token in $file"; return 1; fi
    ok "3x-ui API token saved to root-only XPAM storage: $file"
    return 0
  fi

  token="$(xpam_xui_create_api_token_via_session 2>/dev/null || true)"
  if [[ -n "$token" ]] && xpam_xui_api_token_usable "$token"; then
    if ! xpam_xui_store_api_token "$token"; then warn "Could not store created 3x-ui API token in $file"; return 1; fi
    ok "3x-ui API token created via authenticated panel API and saved to root-only XPAM storage: $file"
    return 0
  fi

  token="$(xpam_xui_get_legacy_db_plaintext_token 2>/dev/null || true)"
  if [[ -n "$token" ]] && xpam_xui_api_token_usable "$token"; then
    if ! xpam_xui_store_api_token "$token"; then warn "Could not store legacy 3x-ui API token in $file"; return 1; fi
    ok "Legacy usable 3x-ui API token migrated to root-only XPAM storage: $file"
    return 0
  fi

  warn "Could not obtain a usable 3x-ui API token. XPAM will not read hashed tokens from SQLite. Use 3x-ui supported token creation/get flow, then run repair."
  return 1
}

xui_api_token(){
  local token
  xui_assert_sqlite_backend
  token="$(xpam_xui_read_stored_api_token 2>/dev/null || true)"
  if [[ -n "$token" ]] && xpam_xui_api_token_usable "$token"; then
    printf '%s\n' "$token"
    return 0
  fi
  xui_ensure_api_token >/dev/null || return 1
  token="$(xpam_xui_read_stored_api_token 2>/dev/null || true)"
  [[ -n "$token" ]] || return 1
  printf '%s\n' "$token"
}

xpam_xui_api_post_json(){
  local url="$1" payload="$2" out_file="$3" err_file="$4" token
  token="$(xui_api_token)" || return 1
  XPAM_XUI_API_TOKEN="$token" XPAM_XUI_API_URL="$url" XPAM_XUI_API_PAYLOAD="$payload" XPAM_XUI_API_OUT="$out_file" XPAM_XUI_API_ERR="$err_file" python3 - <<'PY_XPAM_XUI_API_POST'
import os, ssl, sys, urllib.error, urllib.request
url=os.environ['XPAM_XUI_API_URL']
payload=os.environ['XPAM_XUI_API_PAYLOAD']
out_path=os.environ['XPAM_XUI_API_OUT']
err_path=os.environ['XPAM_XUI_API_ERR']
token=os.environ['XPAM_XUI_API_TOKEN']
ctx=ssl._create_unverified_context()
try:
    data=open(payload, 'rb').read()
    req=urllib.request.Request(url, data=data, method='POST', headers={
        'Authorization': 'Bearer '+token,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': 'XPAM-Script/3x-ui-compat'
    })
    with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
        body=resp.read(10*1024*1024)
    open(out_path, 'wb').write(body)
    open(err_path, 'wb').write(b'')
except urllib.error.HTTPError as exc:
    body=exc.read(1024*1024)
    open(out_path, 'wb').write(body)
    open(err_path, 'w', encoding='utf-8').write(f'HTTP error {exc.code}\n')
    sys.exit(1)
except Exception as exc:
    open(out_path, 'wb').write(b'')
    open(err_path, 'w', encoding='utf-8').write(str(exc)+'\n')
    sys.exit(1)
PY_XPAM_XUI_API_POST
}


xpam_xui_api_get_json(){
  local url="$1" out_file="$2" err_file="$3" token
  token="$(xui_api_token)" || return 1
  XPAM_XUI_API_TOKEN="$token" XPAM_XUI_API_URL="$url" XPAM_XUI_API_OUT="$out_file" XPAM_XUI_API_ERR="$err_file" python3 - <<'PY_XPAM_XUI_API_GET'
import os, ssl, sys, urllib.error, urllib.request
url=os.environ['XPAM_XUI_API_URL']
out_path=os.environ['XPAM_XUI_API_OUT']
err_path=os.environ['XPAM_XUI_API_ERR']
token=os.environ['XPAM_XUI_API_TOKEN']
ctx=ssl._create_unverified_context()
try:
    req=urllib.request.Request(url, method='GET', headers={
        'Authorization': 'Bearer '+token,
        'Accept': 'application/json',
        'User-Agent': 'XPAM-Script/3x-ui-compat'
    })
    with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
        body=resp.read(10*1024*1024)
    open(out_path, 'wb').write(body)
    open(err_path, 'wb').write(b'')
except urllib.error.HTTPError as exc:
    body=exc.read(1024*1024)
    open(out_path, 'wb').write(body)
    open(err_path, 'w', encoding='utf-8').write(f'HTTP error {exc.code}\n')
    sys.exit(1)
except Exception as exc:
    open(out_path, 'wb').write(b'')
    open(err_path, 'w', encoding='utf-8').write(str(exc)+'\n')
    sys.exit(1)
PY_XPAM_XUI_API_GET
}

xpam_xui_prepare_installer_sanitized(){
  local installer="$1" tag="${2:-}"
  [[ -s "$installer" ]] || fail "3x-ui installer file is missing or empty: $installer"
  cp -a "$installer" "${installer}.orig" || fail "Could not backup temporary 3x-ui installer"
  XPAM_XUI_INSTALLER="$installer" XPAM_XUI_INSTALLER_TAG="$tag" python3 <<'PY_XPAM_XUI_INSTALLER_SANITIZE'
import os, re, sys
from pathlib import Path

path = Path(os.environ['XPAM_XUI_INSTALLER'])
tag = os.environ.get('XPAM_XUI_INSTALLER_TAG', '').strip()
try:
    text = path.read_text(encoding='utf-8')
except UnicodeDecodeError:
    text = path.read_text(encoding='utf-8', errors='replace')

original = text

# Some upstream 3x-ui install.sh versions still hard-pin downloads to IPv4.
# That breaks on VPS providers where GitHub/raw works only in curl auto mode
# or over IPv6. Remove only curl's forced IP-version option from lines that
# actually invoke curl in the temporary upstream installer; do not touch system
# curl and do not alter MTG preferIp or other IPv4 runtime settings.
forced_ipv4_pattern = re.compile(r'(?<!\S)(?:-4|--ipv4)(?=\s|$)|(?<!\S)-4(?=[A-Za-z])')

def strip_forced_ipv4_from_curl_line(line: str) -> str:
    if 'curl' not in line:
        return line
    # curl -4fLR ... -> curl -fLR ...
    line = re.sub(r'(?<!\S)-4(?=[A-Za-z])', '-', line)
    # curl -4 ... / curl --ipv4 ... -> curl ...
    line = re.sub(r'(?<!\S)(?:-4|--ipv4)(?=\s|$)[ \t]*', '', line)
    return line

text = ''.join(strip_forced_ipv4_from_curl_line(line) for line in text.splitlines(keepends=True))

remaining_forced_ipv4 = [
    line for line in text.splitlines()
    if 'curl' in line and forced_ipv4_pattern.search(line)
]
if remaining_forced_ipv4:
    print('ERROR: forced IPv4 curl option remains in temporary 3x-ui installer after sanitization', file=sys.stderr)
    for line in remaining_forced_ipv4[:5]:
        print(line, file=sys.stderr)
    sys.exit(1)

# Keep helper scripts/service files aligned with the selected 3x-ui release tag.
# Upstream installers historically download x-ui.sh/service files from main even
# when a concrete binary release tag is requested. XPAM needs reproducible fresh
# installs, so pin raw helper URLs to the same tag when the tag is safe.
if tag and re.fullmatch(r'[A-Za-z0-9._/-]+', tag):
    raw_tag = f'https://raw.githubusercontent.com/MHSanaei/3x-ui/{tag}/'
    text = text.replace('https://raw.githubusercontent.com/MHSanaei/3x-ui/main/', raw_tag)
    text = text.replace('https://raw.githubusercontent.com/MHSanaei/3x-ui/master/', raw_tag)
    text = text.replace('https://raw.githubusercontent.com/mhsanaei/3x-ui/main/', raw_tag)
    text = text.replace('https://raw.githubusercontent.com/mhsanaei/3x-ui/master/', raw_tag)

path.write_text(text, encoding='utf-8')
print('OK: temporary 3x-ui installer sanitized')
before_count = len([line for line in original.splitlines() if 'curl' in line and forced_ipv4_pattern.search(line)])
after_count = len([line for line in text.splitlines() if 'curl' in line and forced_ipv4_pattern.search(line)])
print(f'OK: forced IPv4 curl occurrences before={before_count} after={after_count}')
if tag:
    print(f'OK: temporary 3x-ui helper URLs pinned to tag/ref: {tag}')
PY_XPAM_XUI_INSTALLER_SANITIZE
  chmod +x "$installer"
}

xpam_xui_run_installer_sanitized(){
  local installer="$1" tag="$2" port="$3" raw_out redacted_out rc token file timeout_sec
  timeout_sec="${XPAM_XUI_INSTALL_TIMEOUT:-900}"
  raw_out="$(mktemp /tmp/xpam-script-3x-ui-install.XXXXXX.log)"
  redacted_out="${raw_out%.log}.redacted.log"
  chmod 600 "$raw_out" 2>/dev/null || true

  # New 3x-ui installers support unattended mode; older ones still use stdin prompts.
  # Use both: explicit env for current/future installers, and the legacy answer stream
  # for tagged installers that have not learned those variables yet.
  printf '1\ny\n%s\n4\ny\n' "$port" | \
    timeout --foreground "$timeout_sec" env \
      XUI_NONINTERACTIVE=1 \
      XUI_ENABLE_FAIL2BAN=false \
      XUI_DB_TYPE=sqlite \
      XUI_DB_DSN= \
      XUI_DB_FOLDER=/etc/x-ui \
      XUI_PANEL_PORT="$port" \
      XUI_SSL_MODE=none \
      bash "$installer" "$tag" >"$raw_out" 2>&1
  rc=$?

  xpam_xui_redact_output < "$raw_out" > "$redacted_out" 2>/dev/null || cp -f "$raw_out" "$redacted_out"
  chmod 600 "$redacted_out" 2>/dev/null || true

  if [[ $rc -eq 0 ]]; then
    token="$(xpam_xui_extract_api_token_from_output < "$raw_out" 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      file="$(xpam_xui_api_token_file)"
      if xpam_xui_store_api_token "$token"; then
        ok "3x-ui API token captured from installer and saved to root-only XPAM storage: $file"
      else
        warn "Could not save 3x-ui API token captured from installer; will try authenticated token creation after panel restart"
      fi
    else
      warn "3x-ui installer output did not expose an API token; will try authenticated token creation after panel restart"
    fi
  elif [[ $rc -eq 124 ]]; then
    warn "3x-ui installer timed out after ${timeout_sec}s"
  fi

  sed -n '1,220p' "$redacted_out"
  rm -f "$raw_out"
  if [[ $rc -eq 0 ]]; then
    rm -f "$redacted_out"
  else
    warn "Sanitized 3x-ui installer log kept for diagnostics: $redacted_out"
  fi
  return "$rc"
}

xpam_xui_warp_disable_reset(){
  local db backup_dir backup expected_port restore_mode
  db="/etc/x-ui/x-ui.db"
  xui_assert_sqlite_backend
  [[ -s "$db" ]] || fail "3x-ui DB не найден: $db"
  expected_port="$(expected_xray_port)"
  restore_mode="haproxy"
  uses_haproxy || restore_mode="direct"

  backup_dir="/root/manual-backups/xui-warp-disable"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  backup="${backup_dir}/x-ui.db.$(date +%Y%m%d-%H%M%S)"
  cp -a "$db" "$backup" || fail "Не удалось создать backup 3x-ui DB"
  chmod 600 "$backup" 2>/dev/null || true
  ok "Backup 3x-ui DB создан: $backup"
  prune_keep_latest "$backup_dir" "x-ui.db.*" 4

  export XPAM_XUI_DB="$db" XPAM_EXPECTED_XRAY_PORT="$expected_port" XPAM_WARP_RESTORE_MODE="$restore_mode"
  python3 <<'PY_XPAM_XUI_WARP_DISABLE'
import json, os, sqlite3, sys
from pathlib import Path

db=Path(os.environ['XPAM_XUI_DB'])
expected_port=int(os.environ['XPAM_EXPECTED_XRAY_PORT'])
restore_mode=os.environ.get('XPAM_WARP_RESTORE_MODE','haproxy')

def ok(msg):
    print('OK:', msg)

def warn(msg):
    print('WARNING:', msg)

def fail(msg):
    print('ERROR:', msg, file=sys.stderr)
    sys.exit(1)

def jloads(value, default):
    try:
        if value is None or value == '':
            return default
        return json.loads(value)
    except Exception:
        return default

conn=sqlite3.connect(str(db))
cur=conn.cursor()
row=cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
if not row or not row[0]:
    fail("setting xrayTemplateConfig не найден в 3x-ui DB")
try:
    cfg=json.loads(row[0])
except Exception as e:
    fail(f"xrayTemplateConfig не является валидным JSON: {e}")

changed=False
outbounds=cfg.setdefault('outbounds', [])
if not isinstance(outbounds, list):
    outbounds=[]
    cfg['outbounds']=outbounds
    changed=True

new_out=[]
removed_warp=0
custom_wg=0
for ob in outbounds:
    if isinstance(ob, dict) and ob.get('protocol') == 'wireguard' and ob.get('tag') == 'warp':
        removed_warp += 1
        changed=True
        continue
    if isinstance(ob, dict) and ob.get('protocol') == 'wireguard':
        custom_wg += 1
    new_out.append(ob)
cfg['outbounds']=new_out
if removed_warp:
    ok(f"XPAM-managed WARP outbound tag=warp удалён: {removed_warp}")
else:
    ok("XPAM-managed WARP outbound tag=warp отсутствует; удалять нечего")
if custom_wg:
    warn(f"найдено пользовательских WireGuard outbound: {custom_wg}; XPAM их не трогает")

routing=cfg.setdefault('routing', {})
if not isinstance(routing, dict):
    routing={}
    cfg['routing']=routing
    changed=True
rules=routing.setdefault('rules', [])
if not isinstance(rules, list):
    rules=[]
    routing['rules']=rules
    changed=True
new_rules=[]
removed_rules=0
for r in rules:
    if isinstance(r, dict) and r.get('outboundTag') == 'warp':
        removed_rules += 1
        changed=True
        continue
    new_rules.append(r)
routing['rules']=new_rules
if removed_rules:
    ok(f"routing rules to outboundTag=warp удалены: {removed_rules}")
else:
    ok("routing rules to outboundTag=warp отсутствуют; удалять нечего")

# Restore sniffing to the pre-WARP XPAM state for the XPAM-managed VLESS inbound.
try:
    cols=[r[1] for r in cur.execute('PRAGMA table_info(inbounds)').fetchall()]
    if {'id','port','protocol','sniffing'} <= set(cols):
        rows=cur.execute("SELECT id, remark, sniffing FROM inbounds WHERE protocol='vless' AND port=?", (expected_port,)).fetchall()
        if restore_mode == 'haproxy':
            sniff={"enabled": False, "destOverride": [], "metadataOnly": False, "routeOnly": False}
            sniff_msg="sniffing выключен"
        else:
            sniff={"enabled": True, "destOverride": ["http","tls","quic"], "metadataOnly": False, "routeOnly": True}
            sniff_msg="sniffing восстановлен в direct-profile состояние Route only"
        for inbound_id, remark, old in rows:
            cur.execute("UPDATE inbounds SET sniffing=? WHERE id=?", (json.dumps(sniff, separators=(',',':')), inbound_id))
            changed=True
        if rows:
            ok(f"{sniff_msg} для VLESS inbound port {expected_port}: {len(rows)}")
        else:
            warn(f"VLESS inbound port {expected_port} не найден в 3x-ui DB; sniffing не изменён")
    else:
        warn("таблица inbounds не содержит ожидаемые columns для обновления sniffing")
except Exception as e:
    warn(f"не удалось обновить sniffing в inbounds: {e}")

cur.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(cfg, ensure_ascii=False, separators=(',',':')),))
conn.commit()
conn.close()
if changed:
    ok("3x-ui WARP-managed state отключён и сохранён")
else:
    ok("3x-ui WARP-managed state уже был отключён")
PY_XPAM_XUI_WARP_DISABLE

  warn "Сейчас будет перезапущен 3x-ui/Xray. Если ваша SSH-сессия идёт через этот же VLESS/прокси, соединение может оборваться. Это не означает поломку сервера: после переподключения выполните sudo ${SERVER_PREFIX}-health."
  say "Перезапускаем 3x-ui, чтобы Xray перечитал конфигурацию"
  systemctl restart x-ui || fail "x-ui restart failed after WARP disable/reset"
  sleep 5
  write_wait_for_port
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 30 xui-panel
  wait_for_xray_vless 30
  if [[ -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]]; then
    run_health_quiet "warp-3xui-disable" || fail "Health check failed after WARP disable/reset"
  fi
  ok "WARP в 3x-ui отключён; XPAM-managed VLESS state восстановлен"
}

stage_warp_3xui_disable(){
  need_root
  load_config
  validate_inputs
  echo "============================================================"
  echo "Отключить WARP через 3x-ui / Xray"
  echo "============================================================"
  echo
  echo "Будет отключён только XPAM-managed WARP state:"
  echo "  - outbound tag=warp protocol=wireguard;"
  echo "  - routing rules с outboundTag=warp;"
  if uses_haproxy; then
    echo "  - sniffing у XPAM-managed VLESS inbound будет выключен."
  else
    echo "  - sniffing у XPAM-managed VLESS inbound будет возвращён в direct-profile режим Route only."
  fi
  echo
  echo "Пользовательские WireGuard/WARP outbound с другими tag не удаляются."
  echo "Перед изменением будет создан backup /etc/x-ui/x-ui.db."
  echo
  local confirm
  read -r -p "Продолжить отключение WARP? [y/N]: " confirm || true
  case "$confirm" in
    y|Y|yes|YES|д|Д) xpam_xui_warp_disable_reset ;;
    *) echo "Отменено. Изменений не внесено."; return 0 ;;
  esac
}

stage_warp_menu(){
  need_root
  if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "Сначала выполните установку сервера через пункт 1. WARP настраивается после установки 3x-ui."
  fi
  load_config
  validate_inputs
  echo "WARP через 3x-ui / Xray"
  echo "1) Настроить или проверить WARP outbound"
  echo "2) Отключить WARP и вернуть VLESS в обычный режим"
  echo "3) Выйти"
  local choice
  read -r -p "Выберите пункт [1-3]: " choice || true
  case "$choice" in
    1) stage_warp_3xui_youtube ;;
    2) stage_warp_3xui_disable ;;
    3) return 0 ;;
    *) fail "Неизвестный пункт меню" ;;
  esac
}
