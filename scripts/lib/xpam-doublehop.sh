#!/usr/bin/env bash
# XPAM Script module: Entry-side DoubleHop Mode.
# Server B / Exit is external in v1.3.5: XPAM only accepts a pasted VLESS link.
# Keep normal UX simple; technical fields are shown only in Advanced diagnostics.

DH_EXIT_TAG="xpam-dh-exit"

# ---------- paths / state ----------

dh_state_file(){ echo "${CONFIG_DIR:-/etc/xpam-script}/doublehop.env"; }
dh_exit_link_file(){ echo "/root/secure-notes/${SERVER_PREFIX}-doublehop-exit-vless.link"; }
dh_backup_root(){ echo "/root/manual-backups/xpam-doublehop"; }

dh_mode_label_ru(){
  case "${1:-off}" in
    off|OFF) echo "выключен" ;;
    vless-only) echo "только VLESS" ;;
    telegram-only) echo "только Telegram" ;;
    all) echo "VLESS + Telegram" ;;
    inconsistent) echo "неполная / требуется восстановление" ;;
    *) echo "${1:-unknown}" ;;
  esac
}

dh_mode_label_user(){
  case "${1:-off}" in
    off|OFF) echo "выключен" ;;
    vless-only) echo "VLESS" ;;
    telegram-only) echo "Telegram" ;;
    all) echo "VLESS + Telegram" ;;
    *) echo "${1:-unknown}" ;;
  esac
}

dh_load_config_for_menu(){
  need_root
  [[ -f "$CONFIG_FILE" ]] || fail "Сначала выполните установку сервера через пункт 1."
  load_config
  validate_inputs
}

dh_require_sqlite(){
  xui_assert_sqlite_backend
  [[ -s /etc/x-ui/x-ui.db ]] || fail "Сервер ещё не готов для DoubleHop. Завершите установку XPAM и проверьте health."
}

dh_preflight(){
  dh_require_sqlite
  [[ -s /usr/local/x-ui/bin/config.json || -s /etc/x-ui/x-ui.db ]] || fail "Сервер ещё не готов для DoubleHop. Завершите установку XPAM и проверьте health."
  systemctl is-active --quiet x-ui || fail "Прокси-сервис не активен. Сначала выполните health/repair."
  if uses_mtproto; then
    if ! mtproto_backend_is_3xui_mtg; then
      fail "DoubleHop для Telegram недоступен в текущей конфигурации этого сервера."
    fi
  fi
}

# ---------- current links / snapshots ----------

dh_write_current_links(){
  local out="$1" auto_note vless_link mtg_link
  auto_note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"
  mkdir -p "$(dirname "$out")"
  vless_link="$(print_vless_links_from_xui "$auto_note" 2>/dev/null | awk -F'VLESS Link: ' '/VLESS Link: / {print $2; exit}' || true)"
  mtg_link="$(current_telegram_link_from_xui 2>/dev/null || true)"
  : > "$out"
  [[ -n "$vless_link" ]] && printf 'VLESS=%s\n' "$vless_link" >> "$out"
  if uses_mtproto; then
    [[ -n "$mtg_link" ]] && printf 'Telegram=%s\n' "$mtg_link" >> "$out"
  fi
  grep -q '^VLESS=' "$out" || return 1
  if uses_mtproto; then grep -q '^Telegram=' "$out" || return 1; fi
}

dh_snapshot_create(){
  local backup_dir db backup_db
  backup_dir="$(dh_backup_root)/$(date +%Y%m%d-%H%M%S)"
  db="/etc/x-ui/x-ui.db"
  backup_db="$backup_dir/x-ui.db.backup"
  mkdir -p "$backup_dir/mtg-toml-before" "$backup_dir/generated"
  chmod 700 "$(dh_backup_root)" "$backup_dir" 2>/dev/null || true

  dh_write_current_links "$backup_dir/links.before" || return 1
  sha256sum "$backup_dir/links.before" > "$backup_dir/links.before.sha256" || return 1

  # Checkpoint + SQLite backup API. This avoids the Stage 9A WAL/SHM trap.
  sqlite3 "$db" "PRAGMA wal_checkpoint(FULL);" >/dev/null 2>&1 || true
  sqlite3 "$db" ".timeout 5000" ".backup '$backup_db'" || return 1
  sqlite3 "$backup_db" "PRAGMA integrity_check;" > "$backup_dir/x-ui.integrity.txt" || return 1
  chmod 600 "$backup_db" 2>/dev/null || true
  find "$backup_dir" -maxdepth 1 -type f -exec chmod 600 {} \; 2>/dev/null || true

  sqlite3 "$db" "select value from settings where key='xrayTemplateConfig';" > "$backup_dir/xrayTemplateConfig.before.json" 2>/dev/null || true
  sqlite3 "$db" "select settings from inbounds where protocol='mtproto' limit 1;" > "$backup_dir/mtg-settings.before.json" 2>/dev/null || true
  [[ -s /usr/local/x-ui/bin/config.json ]] && cp -a /usr/local/x-ui/bin/config.json "$backup_dir/generated/config.json.before" || true
  cp -a /usr/local/x-ui/bin/mtproto/mtg-*.toml "$backup_dir/mtg-toml-before/" 2>/dev/null || true
  [[ -f "$(dh_state_file)" ]] && cp -a "$(dh_state_file)" "$backup_dir/doublehop.env.before" || true

  printf '%s\n' "$backup_dir"
}

dh_prune_backups(){
  local root keep old_path
  root="$(dh_backup_root)"
  keep="${XPAM_DH_BACKUP_KEEP:-4}"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=4
  (( keep >= 1 )) || keep=1
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk -v keep="$keep" 'NR>keep {sub(/^[^ ]+ /,""); print}' \
    | while IFS= read -r old_path; do
        [[ -n "$old_path" && "$old_path" == "$root"/* ]] && rm -rf -- "$old_path" 2>/dev/null || true
      done
}

dh_restore_snapshot(){
  local backup_dir="$1" db="/etc/x-ui/x-ui.db"
  [[ -n "$backup_dir" && -s "$backup_dir/x-ui.db.backup" ]] || return 1
  systemctl stop x-ui 2>/dev/null || true
  install -m 600 "$backup_dir/x-ui.db.backup" "$db" || return 1
  rm -f /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm 2>/dev/null || true
  if [[ -f "$backup_dir/doublehop.env.before" ]]; then
    install -m 600 "$backup_dir/doublehop.env.before" "$(dh_state_file)" 2>/dev/null || true
  fi
  systemctl start x-ui || return 1
  sleep 6
  systemctl restart haproxy 2>/dev/null || true
  return 0
}

dh_verify_links_unchanged(){
  local backup_dir="$1" current
  current="$(mktemp /tmp/xpam-dh-links-current.XXXXXX)"
  dh_write_current_links "$current" || { rm -f "$current"; return 1; }
  if cmp -s "$backup_dir/links.before" "$current"; then
    rm -f "$current"
    return 0
  fi
  rm -f "$current"
  return 1
}

# ---------- state detection ----------

dh_state_shell(){
  local exit_file current_ip
  exit_file="$(dh_exit_link_file)"
  current_ip="$(server_public_ipv4 2>/dev/null || true)"
  XPAM_DH_EXIT_TAG="$DH_EXIT_TAG" \
  XPAM_DH_EXIT_LINK_FILE="$exit_file" \
  XPAM_CURRENT_PUBLIC_IP="$current_ip" \
  python3 - <<'PY_DH_STATE'
import json, os, re, shlex, sqlite3, subprocess, sys
from pathlib import Path

tag=os.environ.get('XPAM_DH_EXIT_TAG','xpam-dh-exit')
exit_file=Path(os.environ.get('XPAM_DH_EXIT_LINK_FILE',''))
state={
  'DH_MODE':'off',
  'DH_INCONSISTENT':'0',
  'DH_EXIT_CONFIGURED':'1' if exit_file.exists() and exit_file.stat().st_size>0 else '0',
  'DH_EXIT_OUTBOUND':'0',
  'DH_VLESS_ROUTE':'0',
  'DH_DH_RULE_COUNT':'0',
  'DH_BAD_ROUTE':'0',
  'DH_MTG_ACTIVE':'0',
  'DH_MTG_OUTBOUND_TAG':'',
  'DH_ROUTE_XRAY_PORT':'',
  'DH_ROUTE_XRAY_LISTENER':'0',
  'DH_MTG_TOML_PROXY':'0',
  'DH_MTG_TOML_PROXY_EXPECTED':'0',
  'DH_VLESS_INBOUND_TAG':'',
  'DH_EXIT_HOST':'',
}

def emit():
    for k,v in state.items():
        print(f'{k}={shlex.quote(str(v))}')

def jloads(x, default):
    try:
        if x is None or x == '': return default
        return json.loads(x)
    except Exception:
        return default

try:
    conn=sqlite3.connect('/etc/x-ui/x-ui.db')
    cur=conn.cursor()
    row=cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    cfg=jloads(row[0] if row else '{}', {})
except Exception:
    cfg={}

# generated config may have the current inbound tag after x-ui renders it
try:
    generated=json.loads(Path('/usr/local/x-ui/bin/config.json').read_text())
except Exception:
    generated={}

for source in (generated,):
    for inbound in source.get('inbounds') or []:
        if isinstance(inbound, dict) and inbound.get('protocol') == 'vless' and inbound.get('tag'):
            state['DH_VLESS_INBOUND_TAG']=str(inbound.get('tag'))
            break
    if state['DH_VLESS_INBOUND_TAG']:
        break
if not state['DH_VLESS_INBOUND_TAG']:
    try:
        row=cur.execute("SELECT tag FROM inbounds WHERE protocol='vless' AND enable=1 ORDER BY id ASC LIMIT 1").fetchone()
        if row and row[0]: state['DH_VLESS_INBOUND_TAG']=str(row[0])
    except Exception:
        pass

outbounds=cfg.get('outbounds') if isinstance(cfg,dict) else []
if not isinstance(outbounds, list): outbounds=[]
routing=cfg.get('routing') if isinstance(cfg,dict) else {}
rules=routing.get('rules') if isinstance(routing,dict) else []
if not isinstance(rules, list): rules=[]

for ob in outbounds:
    if isinstance(ob,dict) and ob.get('tag') == tag:
        state['DH_EXIT_OUTBOUND']='1'
        try:
            settings=(ob.get('settings') or {})
            # 3x-ui outbound editor/import model stores address/port flat in settings.
            # Older XPAM candidates used Xray-native settings.vnext; read both so
            # status/diagnostics can detect either shape.
            if settings.get('address'):
                state['DH_EXIT_HOST']=str(settings.get('address') or '')
            else:
                vnext=(settings.get('vnext') or [{}])[0]
                state['DH_EXIT_HOST']=str(vnext.get('address') or '')
        except Exception:
            pass
        break

vtag=state['DH_VLESS_INBOUND_TAG']
dh_rules=[]
expected_vless_rules=0
bad_dh_rules=0
for r in rules:
    if not isinstance(r,dict):
        continue
    if r.get('outboundTag') == tag:
        dh_rules.append(r)
        if r.get('inboundTag') == [vtag] and str(r.get('network') or '') == 'tcp,udp':
            expected_vless_rules += 1
        else:
            bad_dh_rules += 1
state['DH_DH_RULE_COUNT']=str(len(dh_rules))
state['DH_BAD_ROUTE']='1' if bad_dh_rules else '0'
if expected_vless_rules == 1 and len(dh_rules) == 1:
    state['DH_VLESS_ROUTE']='1'
elif len(dh_rules) > 0:
    state['DH_VLESS_ROUTE']='0'
    state['DH_BAD_ROUTE']='1'

try:
    row=cur.execute("SELECT settings FROM inbounds WHERE protocol='mtproto' ORDER BY id ASC LIMIT 1").fetchone()
    mtg=jloads(row[0] if row else '{}', {})
except Exception:
    mtg={}
if isinstance(mtg, dict):
    state['DH_MTG_OUTBOUND_TAG']=str(mtg.get('outboundTag') or '')
    if mtg.get('routeThroughXray') is True:
        state['DH_MTG_ACTIVE']='1'
    if mtg.get('routeXrayPort'):
        state['DH_ROUTE_XRAY_PORT']=str(mtg.get('routeXrayPort'))

if state['DH_ROUTE_XRAY_PORT']:
    try:
        out=subprocess.check_output(['ss','-H','-ltnp'], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        out=''
    if f"127.0.0.1:{state['DH_ROUTE_XRAY_PORT']}" in out:
        state['DH_ROUTE_XRAY_LISTENER']='1'

for path in Path('/usr/local/x-ui/bin/mtproto').glob('mtg-*.toml'):
    try:
        txt=path.read_text(errors='ignore')
    except Exception:
        continue
    if re.search(r'proxies\s*=\s*\[\s*"socks5://127\.0\.0\.1:\d+"\s*\]', txt):
        state['DH_MTG_TOML_PROXY']='1'
    if state['DH_ROUTE_XRAY_PORT'] and f"socks5://127.0.0.1:{state['DH_ROUTE_XRAY_PORT']}" in txt:
        state['DH_MTG_TOML_PROXY_EXPECTED']='1'

inconsistent=False
if int(state.get('DH_DH_RULE_COUNT','0') or '0') > 0 and state['DH_EXIT_OUTBOUND']!='1':
    inconsistent=True
if state.get('DH_BAD_ROUTE') == '1':
    inconsistent=True
if state['DH_VLESS_ROUTE']=='1' and state['DH_EXIT_OUTBOUND']!='1':
    inconsistent=True
if state['DH_MTG_ACTIVE']=='1':
    if state['DH_MTG_OUTBOUND_TAG'] != tag or state['DH_EXIT_OUTBOUND']!='1':
        inconsistent=True
    if not state['DH_ROUTE_XRAY_PORT'] or state['DH_ROUTE_XRAY_LISTENER']!='1' or state['DH_MTG_TOML_PROXY_EXPECTED']!='1':
        inconsistent=True
else:
    # Clean off/vless-only must not carry stale MTG DH fields or generated TOML proxy.
    if state['DH_MTG_OUTBOUND_TAG'] or state['DH_ROUTE_XRAY_PORT'] or state['DH_ROUTE_XRAY_LISTENER']=='1' or state['DH_MTG_TOML_PROXY']=='1':
        inconsistent=True
if state['DH_EXIT_OUTBOUND']=='1' and state['DH_EXIT_CONFIGURED']!='1':
    inconsistent=True

if inconsistent:
    state['DH_MODE']='inconsistent'
    state['DH_INCONSISTENT']='1'
elif state['DH_VLESS_ROUTE']=='1' and state['DH_MTG_ACTIVE']=='1':
    state['DH_MODE']='all'
elif state['DH_VLESS_ROUTE']=='1':
    state['DH_MODE']='vless-only'
elif state['DH_MTG_ACTIVE']=='1':
    state['DH_MODE']='telegram-only'
else:
    state['DH_MODE']='off'
emit()
PY_DH_STATE
}

dh_detect_mode(){ local DH_MODE; eval "$(dh_state_shell)"; printf '%s\n' "${DH_MODE:-off}"; }
dh_state_load(){ eval "$(dh_state_shell)"; }

# ---------- VLESS link parsing / validation ----------

dh_validate_exit_vless_link(){
  local link_file="$1" current_ip
  current_ip="$(server_public_ipv4 2>/dev/null || true)"
  XPAM_DH_LINK_FILE="$link_file" \
  XPAM_PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-}" \
  XPAM_SYNC_DOMAIN="${SYNC_DOMAIN:-}" \
  XPAM_ROOT_DOMAIN="${ROOT_DOMAIN:-}" \
  XPAM_WWW_DOMAIN="${WWW_DOMAIN:-}" \
  XPAM_CURRENT_PUBLIC_IP="$current_ip" \
  python3 - <<'PY_DH_VALIDATE'
import ipaddress, os, socket, sys, uuid
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

path=Path(os.environ['XPAM_DH_LINK_FILE'])
link=path.read_text().strip().splitlines()[0] if path.exists() else ''
if not link.startswith('vless://'):
    sys.exit('INVALID')
u=urlparse(link)
if u.scheme != 'vless' or not u.username or not u.hostname or not u.port:
    sys.exit('INVALID')
try:
    uuid.UUID(unquote(u.username))
except Exception:
    sys.exit('INVALID')
q=parse_qs(u.query)
network=(q.get('type') or q.get('network') or ['tcp'])[0]
security=(q.get('security') or ['tls'])[0]
if network not in {'tcp','ws','grpc'}:
    sys.exit('INVALID')
if security not in {'tls','reality','none'}:
    sys.exit('INVALID')

host=u.hostname.strip().lower().rstrip('.')
managed={x.lower().rstrip('.') for x in (os.environ.get('XPAM_PRIMARY_DOMAIN',''), os.environ.get('XPAM_SYNC_DOMAIN',''), os.environ.get('XPAM_ROOT_DOMAIN',''), os.environ.get('XPAM_WWW_DOMAIN','')) if x}
current_ip=os.environ.get('XPAM_CURRENT_PUBLIC_IP','').strip()
if host in managed:
    sys.exit('SELF')
try:
    ip=ipaddress.ip_address(host)
    if current_ip and str(ip) == current_ip:
        sys.exit('SELF')
except Exception:
    pass
try:
    infos=socket.getaddrinfo(host, u.port, type=socket.SOCK_STREAM)
except Exception:
    sys.exit('UNREACHABLE')
ips=[]
for item in infos:
    try:
        ips.append(item[4][0])
    except Exception:
        pass
if current_ip and current_ip in ips:
    sys.exit('SELF')
# TCP connect is a reachability hint; if it fails, reject before mutation.
ok=False
for ip in ips[:4]:
    try:
        with socket.create_connection((ip, int(u.port)), timeout=5):
            ok=True
            break
    except Exception:
        continue
if not ok:
    sys.exit('UNREACHABLE')
print(f'OK host={host} port={u.port} network={network} security={security}')
PY_DH_VALIDATE
}

dh_prompt_and_save_exit_link(){
  local tmp out rc
  echo
  echo "Настройка Exit-сервера для DoubleHop"
  echo
  echo "Создайте или выберите VLESS-клиента на Exit-сервере."
  echo "Скопируйте его VLESS-ссылку и вставьте её здесь."
  echo
  echo "XPAM использует эту ссылку только для настройки маршрутизации на этом Entry-сервере."
  echo "XPAM не изменяет Exit-сервер."
  echo
  tmp="$(mktemp /tmp/xpam-dh-exit-link.XXXXXX)"
  read -r -p "Вставьте VLESS-ссылку с Exit-сервера: " out || true
  printf '%s\n' "$out" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  set +e
  dh_validate_exit_vless_link "$tmp" >/tmp/xpam-dh-validate.out 2>/tmp/xpam-dh-validate.err
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if grep -q '^SELF' /tmp/xpam-dh-validate.err 2>/dev/null; then
      echo
      echo "Эта VLESS-ссылка похожа на ссылку текущего Entry-сервера."
      echo
      echo "Для DoubleHop нужна VLESS-ссылка с другого Exit-сервера."
      echo "Изменения не внесены."
    else
      echo
      echo "VLESS-ссылка Exit-сервера некорректна или недоступна."
      echo "Изменения не внесены."
    fi
    rm -f "$tmp" /tmp/xpam-dh-validate.out /tmp/xpam-dh-validate.err
    return 1
  fi
  mkdir -p /root/secure-notes
  chmod 700 /root/secure-notes 2>/dev/null || true
  install -m 600 "$tmp" "$(dh_exit_link_file)"
  rm -f "$tmp" /tmp/xpam-dh-validate.out /tmp/xpam-dh-validate.err
  ok "VLESS-ссылка Exit-сервера сохранена на этом Entry-сервере."
}

# ---------- DB mutation ----------

dh_materialize_xray_template_if_missing(){
  # Some current/clean 3x-ui installs can run Xray normally while the
  # persistent settings.xrayTemplateConfig row is still absent. DoubleHop
  # mutates that persistent template, so materialize a safe template from the
  # generated config before DH mutation.  Keep only the API/tunnel inbound in
  # the template; proxy inbounds remain managed by the 3x-ui inbounds table and
  # will be re-rendered by 3x-ui. Preserve outbounds/routing/policy/log/stats.
  XPAM_DH_EXIT_TAG="$DH_EXIT_TAG" python3 - <<'PY_DH_MATERIALIZE'
import json, os, sqlite3, sys
from pathlib import Path

tag=os.environ.get('XPAM_DH_EXIT_TAG','xpam-dh-exit')
db_path='/etc/x-ui/x-ui.db'
gen_path=Path('/usr/local/x-ui/bin/config.json')

def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)

def load_json_text(txt, label):
    try:
        if txt is None or txt == '':
            return None
        return json.loads(txt)
    except Exception as e:
        fail(f'{label} invalid JSON: {type(e).__name__}: {e}')

conn=sqlite3.connect(db_path)
try:
    cur=conn.cursor()
    row=cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if row and (row[0] or '').strip():
        current=load_json_text(row[0], 'xrayTemplateConfig')
        if not isinstance(current, dict):
            fail('xrayTemplateConfig is not a JSON object')
        print('OK: xrayTemplateConfig already present')
        sys.exit(0)

    if not gen_path.exists() or gen_path.stat().st_size <= 0:
        fail('generated Xray config missing: /usr/local/x-ui/bin/config.json')
    cfg=load_json_text(gen_path.read_text(), 'generated Xray config')
    if not isinstance(cfg, dict):
        fail('generated Xray config is not a JSON object')

    # Do not materialize from an already-mutated DoubleHop runtime config.
    if tag in json.dumps(cfg, ensure_ascii=False):
        fail('generated config already contains DoubleHop state; refusing automatic materialize')

    generated_inbounds=cfg.get('inbounds')
    if not isinstance(generated_inbounds, list):
        fail('generated Xray config has no inbounds list')

    api_inbounds=[]
    non_api_inbounds=[]
    for ib in generated_inbounds:
        if not isinstance(ib, dict):
            continue
        if ib.get('protocol') == 'tunnel' and ib.get('tag') == 'api':
            api_inbounds.append(ib)
        else:
            non_api_inbounds.append(ib)

    if len(api_inbounds) != 1:
        fail(f'expected exactly one api/tunnel inbound in generated config, got {len(api_inbounds)}')

    # Safety: every non-api generated inbound must correspond to a 3x-ui DB inbound.
    # If a user manually injected a raw inbound only into generated config, automatic
    # materialization is unsafe because 3x-ui itself would not preserve that state.
    rows=cur.execute("SELECT tag, protocol, listen, port FROM inbounds WHERE enable=1").fetchall()
    db_tags={str(r[0]) for r in rows if r and r[0] is not None and str(r[0])}
    db_tuples={(str(r[1] or ''), str(r[2] or ''), str(r[3] or '')) for r in rows}

    for ib in non_api_inbounds:
        ib_tag=str(ib.get('tag') or '')
        ib_tuple=(str(ib.get('protocol') or ''), str(ib.get('listen') or ''), str(ib.get('port') or ''))
        if ib_tag and ib_tag in db_tags:
            continue
        if ib_tuple in db_tuples:
            continue
        fail('generated config contains a non-DB inbound; refusing automatic materialize')

    cfg['inbounds']=api_inbounds
    value=json.dumps(cfg, ensure_ascii=False, separators=(',',':'))

    if row:
        cur.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (value,))
    else:
        cur.execute("INSERT INTO settings(key, value) VALUES(?, ?)", ('xrayTemplateConfig', value))
    conn.commit()
    print('OK: xrayTemplateConfig materialized')
    print('xrayTemplateConfig_len:', len(value))
finally:
    conn.close()
PY_DH_MATERIALIZE
}

dh_mutate_mode(){
  local mode="$1" remove_outbound="${2:-0}" link_file
  link_file="$(dh_exit_link_file)"
  XPAM_DH_MODE="$mode" \
  XPAM_DH_REMOVE_OUTBOUND="$remove_outbound" \
  XPAM_DH_EXIT_TAG="$DH_EXIT_TAG" \
  XPAM_DH_EXIT_LINK_FILE="$link_file" \
  python3 - <<'PY_DH_MUTATE'
import json, os, random, socket, sqlite3, sys, uuid
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

mode=os.environ['XPAM_DH_MODE']
tag=os.environ.get('XPAM_DH_EXIT_TAG','xpam-dh-exit')
remove_outbound=os.environ.get('XPAM_DH_REMOVE_OUTBOUND','0') == '1'
link_file=Path(os.environ.get('XPAM_DH_EXIT_LINK_FILE',''))

def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)

def jloads(x, default):
    try:
        if x is None or x == '': return default
        return json.loads(x)
    except Exception:
        return default

def parse_vless_link(link):
    u=urlparse(link.strip())
    if u.scheme!='vless' or not u.username or not u.hostname or not u.port:
        fail('bad vless link')
    uid=unquote(u.username)
    try: uuid.UUID(uid)
    except Exception: fail('bad uuid')
    q=parse_qs(u.query)
    network=(q.get('type') or q.get('network') or ['tcp'])[0]
    security=(q.get('security') or ['tls'])[0]
    flow=(q.get('flow') or [''])[0]
    # IMPORTANT: xrayTemplateConfig is consumed by 3x-ui, not only by raw Xray.
    # 3x-ui imported outbound links use a flat outbound settings model
    # (address/port/id/flow/encryption/testseed). If XPAM writes Xray-native
    # settings.vnext here, Xray may still render a usable config, but the 3x-ui
    # UI/tester shows an empty address and marks the outbound failed. Match the
    # 3x-ui import shape exactly and keep the stable XPAM tag.
    settings={
        'address': u.hostname,
        'port': int(u.port),
        'id': uid,
        'flow': flow,
        'encryption': 'none',
        'testseed': [900, 500, 900, 256],
    }
    ob={
        'protocol': 'vless',
        'settings': settings,
        'tag': tag,
        'streamSettings': {'network': network, 'security': security},
    }
    ss=ob['streamSettings']
    if security == 'tls':
        tls={'serverName': (q.get('sni') or [u.hostname])[0]}
        alpn=(q.get('alpn') or [''])[0]
        if alpn: tls['alpn']=[x for x in alpn.split(',') if x]
        fp=(q.get('fp') or [''])[0]
        if fp: tls['fingerprint']=fp
        tls.setdefault('echConfigList', '')
        tls.setdefault('verifyPeerCertByName', '')
        tls.setdefault('pinnedPeerCertSha256', '')
        ss['tlsSettings']=tls
    elif security == 'reality':
        reality={'serverName': (q.get('sni') or [u.hostname])[0]}
        fp=(q.get('fp') or [''])[0]
        if fp: reality['fingerprint']=fp
        for key in ('pbk','sid','spx'):
            val=(q.get(key) or [''])[0]
            if val:
                reality[{'pbk':'publicKey','sid':'shortId','spx':'spiderX'}[key]]=val
        ss['realitySettings']=reality
    if network == 'tcp':
        ss['tcpSettings']={'header': {'type':'none'}}
    elif network == 'ws':
        ws={}
        path=(q.get('path') or [''])[0]
        host=(q.get('host') or [''])[0]
        if path: ws['path']=path
        if host: ws['headers']={'Host':host}
        ss['wsSettings']=ws
    elif network == 'grpc':
        svc=(q.get('serviceName') or [''])[0]
        ss['grpcSettings']={'serviceName':svc} if svc else {}
    return ob

def free_loopback_port():
    for _ in range(80):
        port=random.randint(12000, 62000)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(('127.0.0.1', port))
                return port
            except OSError:
                continue
    fail('could not allocate routeXrayPort')

conn=sqlite3.connect('/etc/x-ui/x-ui.db')
cur=conn.cursor()
try:
    row=cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row:
        fail('xrayTemplateConfig missing')
    cfg=jloads(row[0], {})
    if not isinstance(cfg,dict):
        fail('xrayTemplateConfig invalid')
    outbounds=cfg.setdefault('outbounds', [])
    if not isinstance(outbounds,list):
        outbounds=[]; cfg['outbounds']=outbounds
    routing=cfg.setdefault('routing', {})
    if not isinstance(routing,dict):
        routing={}; cfg['routing']=routing
    rules=routing.setdefault('rules', [])
    if not isinstance(rules,list):
        rules=[]; routing['rules']=rules

    # Detect XPAM-managed VLESS inbound tag from generated config first, then DB.
    vless_tag=''
    try:
        generated=json.loads(Path('/usr/local/x-ui/bin/config.json').read_text())
        for inbound in generated.get('inbounds') or []:
            if isinstance(inbound,dict) and inbound.get('protocol')=='vless' and inbound.get('tag'):
                vless_tag=str(inbound.get('tag')); break
    except Exception:
        pass
    if not vless_tag:
        row=cur.execute("SELECT tag FROM inbounds WHERE protocol='vless' AND enable=1 ORDER BY id ASC LIMIT 1").fetchone()
        if row and row[0]: vless_tag=str(row[0])
    if not vless_tag:
        fail('VLESS inbound tag not detected')

    # Ensure/remove local exit outbound.
    outbounds=[ob for ob in outbounds if not (isinstance(ob,dict) and ob.get('tag')==tag)]
    # Keep the local Exit outbound while a saved Exit link exists, even when
    # DoubleHop is disabled. Advanced/remove configuration is the only normal
    # flow that removes both the local outbound and the saved Exit link.
    need_exit = (not remove_outbound) and link_file.exists() and bool(link_file.read_text().strip())
    if need_exit:
        exit_ob=parse_vless_link(link_file.read_text().strip().splitlines()[0])
        outbounds.append(exit_ob)
    elif mode in ('vless-only','telegram-only','all'):
        fail('exit link missing')
    cfg['outbounds']=outbounds

    # Remove ALL XPAM-owned DH routing rules first. Any route to the
    # internal DH tag is treated as XPAM-owned local DH state, including
    # stale/wrong/global/malformed routes from older attempts.
    rules=[r for r in rules if not (isinstance(r,dict) and r.get('outboundTag')==tag)]

    if mode in ('vless-only','all'):
        protected_last=-1
        for i,r in enumerate(rules):
            if not isinstance(r,dict):
                continue
            if r.get('outboundTag')=='api' and r.get('inboundTag')==['api']:
                protected_last=max(protected_last,i)
            if r.get('outboundTag')=='blocked' and r.get('ip')==['geoip:private']:
                protected_last=max(protected_last,i)
            if r.get('outboundTag')=='blocked' and r.get('protocol')==['bittorrent']:
                protected_last=max(protected_last,i)
        dh_rule={'type':'field','inboundTag':[vless_tag],'network':'tcp,udp','outboundTag':tag}
        rules.insert(protected_last+1, dh_rule)
    routing['rules']=rules

    # MTG routeThroughXray is controlled only for mtproto inbounds.
    rows=cur.execute("SELECT id, settings FROM inbounds WHERE protocol='mtproto' ORDER BY id ASC").fetchall()
    if mode in ('telegram-only','all') and not rows:
        fail('MTG inbound missing')
    for inbound_id, settings_raw in rows:
        s=jloads(settings_raw, {})
        if not isinstance(s,dict): s={}
        if mode in ('telegram-only','all'):
            s['routeThroughXray']=True
            s['outboundTag']=tag
            # Preserve an existing port when valid; otherwise allocate one.
            try:
                port=int(s.get('routeXrayPort') or 0)
            except Exception:
                port=0
            if port <= 0:
                s['routeXrayPort']=free_loopback_port()
        else:
            s['routeThroughXray']=False
            s.pop('outboundTag', None)
            s.pop('routeXrayPort', None)
        cur.execute("UPDATE inbounds SET settings=? WHERE id=?", (json.dumps(s, ensure_ascii=False, separators=(',',':')), inbound_id))

    cur.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(cfg, ensure_ascii=False, separators=(',',':')),))
    conn.commit()
finally:
    conn.close()
PY_DH_MUTATE
}

dh_restart_runtime(){
  systemctl restart x-ui || return 1
  sleep 8
  write_wait_for_port >/dev/null 2>&1 || true
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 30 xui-panel || return 1
  wait_for_xray_vless 30 || return 1
  if uses_mtproto; then
    /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$MTPROTO_PORT" 45 mtg-backend || return 1
    systemctl restart haproxy 2>/dev/null || true
    sleep 3
  fi
}

dh_verify_clean_state(){
  local expected="$1"
  XPAM_DH_EXPECTED="$expected" XPAM_DH_EXIT_TAG="$DH_EXIT_TAG" python3 - <<'PY_DH_VERIFY'
import json, os, re, sqlite3, subprocess, sys
from pathlib import Path
expected=os.environ['XPAM_DH_EXPECTED']
tag=os.environ.get('XPAM_DH_EXIT_TAG','xpam-dh-exit')

def fail(msg):
    print(msg, file=sys.stderr); sys.exit(1)

def jloads(x, default):
    try:
        if x is None or x == '': return default
        return json.loads(x)
    except Exception:
        return default

conn=sqlite3.connect('/etc/x-ui/x-ui.db')
cur=conn.cursor()
row=cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
cfg=jloads(row[0] if row else '{}', {})
outbounds=cfg.get('outbounds') or []
rules=(cfg.get('routing') or {}).get('rules') or []
exit_exists=any(isinstance(o,dict) and o.get('tag')==tag for o in outbounds)
try:
    gen=json.loads(Path('/usr/local/x-ui/bin/config.json').read_text())
except Exception:
    gen={}
vless_tag=''
for inbound in gen.get('inbounds') or []:
    if isinstance(inbound,dict) and inbound.get('protocol')=='vless' and inbound.get('tag'):
        vless_tag=str(inbound.get('tag')); break
if not vless_tag:
    row=cur.execute("SELECT tag FROM inbounds WHERE protocol='vless' AND enable=1 ORDER BY id ASC LIMIT 1").fetchone()
    if row and row[0]: vless_tag=str(row[0])
if not vless_tag:
    fail('VLESS inbound tag not detected')

def is_api_rule(r):
    return isinstance(r,dict) and r.get('outboundTag')=='api' and r.get('inboundTag')==['api']
def is_private_rule(r):
    return isinstance(r,dict) and r.get('outboundTag')=='blocked' and r.get('ip')==['geoip:private']
def is_bittorrent_rule(r):
    return isinstance(r,dict) and r.get('outboundTag')=='blocked' and r.get('protocol')==['bittorrent']

dh_rules=[]
for i,r in enumerate(rules):
    if isinstance(r,dict) and r.get('outboundTag')==tag:
        dh_rules.append((i,r))

vless_route=False
if dh_rules:
    if len(dh_rules) != 1:
        fail('more than one DH routing rule present')
    i,r=dh_rules[0]
    if r.get('inboundTag') != [vless_tag]:
        fail('DH routing rule is not scoped to current VLESS inbound')
    if str(r.get('network') or '') != 'tcp,udp':
        fail('DH routing rule network must be tcp,udp')
    vless_route=True
    if not r.get('inboundTag'):
        fail('VLESS DH route is global')
    for j,pr in enumerate(rules):
        if (is_api_rule(pr) or is_private_rule(pr) or is_bittorrent_rule(pr)) and j > i:
            fail('protection rule is below VLESS DH route')
mtg_active=False; mtg_tag=''; rxp=''
row=cur.execute("SELECT settings FROM inbounds WHERE protocol='mtproto' ORDER BY id ASC LIMIT 1").fetchone()
if row:
    s=jloads(row[0], {})
    if isinstance(s,dict):
        mtg_active = s.get('routeThroughXray') is True
        mtg_tag = str(s.get('outboundTag') or '')
        rxp = str(s.get('routeXrayPort') or '')
listener=False
if rxp:
    try:
        out=subprocess.check_output(['ss','-H','-ltnp'], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        out=''
    listener=f'127.0.0.1:{rxp}' in out

toml_proxy_any=False
toml_proxy_expected=False
for path in Path('/usr/local/x-ui/bin/mtproto').glob('mtg-*.toml'):
    try:
        txt=path.read_text(errors='ignore')
    except Exception:
        continue
    if re.search(r'proxies\s*=\s*\[\s*"socks5://127\.0\.0\.1:\d+"\s*\]', txt):
        toml_proxy_any=True
    if rxp and f'socks5://127.0.0.1:{rxp}' in txt:
        toml_proxy_expected=True

if expected == 'off' or expected == 'removed':
    if dh_rules: fail('DH routing rule still active')
    if expected == 'removed' and exit_exists: fail('exit outbound still present after remove config')
    if mtg_active: fail('MTG DH still active')
    if mtg_tag: fail('MTG outboundTag still present')
    if rxp: fail('routeXrayPort still present')
    if listener: fail('routeXrayPort listener still present')
    if toml_proxy_any: fail('MTG TOML still has socks proxy')
elif expected == 'vless-only':
    if not exit_exists: fail('exit outbound missing')
    if not vless_route: fail('VLESS route missing')
    if mtg_active: fail('MTG DH unexpectedly active')
    if mtg_tag: fail('MTG outboundTag unexpectedly present')
    if rxp or listener: fail('routeXrayPort unexpectedly present')
    if toml_proxy_any: fail('MTG TOML proxy unexpectedly present')
elif expected == 'telegram-only':
    if not exit_exists: fail('exit outbound missing')
    if dh_rules: fail('DH routing rule unexpectedly active')
    if not mtg_active or mtg_tag != tag: fail('MTG DH inactive or wrong outbound')
    if not rxp or not listener: fail('routeXrayPort listener missing')
    if not toml_proxy_expected: fail('MTG TOML socks proxy missing')
elif expected == 'all':
    if not exit_exists: fail('exit outbound missing')
    if not vless_route: fail('VLESS route missing')
    if not mtg_active or mtg_tag != tag: fail('MTG DH inactive or wrong outbound')
    if not rxp or not listener: fail('routeXrayPort listener missing')
    if not toml_proxy_expected: fail('MTG TOML socks proxy missing')
else:
    fail('unknown expected state')
print('OK')
PY_DH_VERIFY
}

dh_write_state_file(){
  local mode="$1" DH_ROUTE_XRAY_PORT="" DH_VLESS_INBOUND_TAG=""
  eval "$(dh_state_shell)"
  mkdir -p "$(dirname "$(dh_state_file)")"
  cat > "$(dh_state_file)" <<EOF_STATE
DH_EXIT_TAG=${DH_EXIT_TAG}
DH_MODE=${mode}
DH_VLESS_INBOUND_TAG=${DH_VLESS_INBOUND_TAG:-}
DH_LAST_ROUTE_XRAY_PORT=${DH_ROUTE_XRAY_PORT:-}
DH_EXIT_LINK_FILE=$(dh_exit_link_file)
EOF_STATE
  chmod 600 "$(dh_state_file)" 2>/dev/null || true
}

dh_run_health_validation(){
  local cmd ts log_dir deep_log
  cmd="/usr/local/sbin/${SERVER_PREFIX}-health"
  [[ -x "$cmd" ]] || fail "Health command not found: $cmd"
  ts="$(date +%Y%m%d-%H%M%S)"
  log_dir="/var/log/xpam-script"
  mkdir -p "$log_dir"
  chmod 700 "$log_dir" 2>/dev/null || true
  deep_log="${log_dir}/${SERVER_PREFIX}-doublehop-deep-health-${ts}.log"
  # Stage 9C small-VM optimization: one deep-health is enough here.
  # The normal health command already derives its short summary from deep-health,
  # so running both would duplicate the heaviest checks during each DH mutation.
  "$cmd" --deep >"$deep_log" 2>&1 || return 1
  return 0
}

dh_apply_mode_with_rollback(){
  local mode="$1" user_label="$2" backup_dir rc=0
  backup_dir="$(dh_snapshot_create)" || fail "Не удалось создать backup перед изменением DoubleHop. Изменения не внесены."
  if ! dh_materialize_xray_template_if_missing >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_mutate_mode "$mode" 0 >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_restart_runtime >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_verify_clean_state "$mode" >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_verify_links_unchanged "$backup_dir" >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_run_health_validation >>"$backup_dir/operation.log" 2>&1; then rc=1; fi

  if [[ $rc -ne 0 ]]; then
    warn "Операция DoubleHop не завершилась безопасно. Выполняю rollback."
    if dh_restore_snapshot "$backup_dir" && dh_verify_links_unchanged "$backup_dir"; then
      echo
      fail "DoubleHop не был изменён. Предыдущее рабочее состояние восстановлено. Ваши ссылки не изменились. Backup: $backup_dir"
    fi
    fail "Rollback DoubleHop не удалось завершить автоматически. Backup: $backup_dir"
  fi
  dh_write_state_file "$mode"
  dh_prune_backups || true
  echo
  echo "DoubleHop включён: ${user_label}"
  echo
  case "$mode" in
    vless-only)
      echo "VLESS-трафик теперь выходит через настроенный Exit-сервер."
      echo "Telegram остаётся в direct-режиме."
      ;;
    telegram-only)
      echo "Telegram-трафик теперь выходит через настроенный Exit-сервер."
      echo "VLESS остаётся в direct-режиме."
      ;;
    all)
      echo "VLESS- и Telegram-трафик теперь выходят через настроенный Exit-сервер."
      ;;
  esac
  echo
  echo "Ваши ссылки не изменились."
}

dh_disable_with_rollback(){
  local backup_dir rc=0 mode
  mode="$(dh_detect_mode)"
  if [[ "$mode" == "off" ]]; then
    echo "DoubleHop уже выключен."
    return 0
  fi
  backup_dir="$(dh_snapshot_create)" || fail "Не удалось создать backup перед выключением DoubleHop."
  if ! dh_materialize_xray_template_if_missing >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_mutate_mode "off" 0 >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_restart_runtime >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_verify_clean_state "off" >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_verify_links_unchanged "$backup_dir" >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_run_health_validation >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -ne 0 ]]; then
    warn "Не удалось безопасно выключить DoubleHop. Выполняю rollback."
    dh_restore_snapshot "$backup_dir" >/dev/null 2>&1 || true
    fail "DoubleHop не изменён. Подробности в backup: $backup_dir"
  fi
  dh_write_state_file "off"
  dh_prune_backups || true
  echo
  echo "DoubleHop выключен."
  echo
  echo "VLESS-трафик: direct"
  echo "Telegram-трафик: direct"
  echo "Ваши ссылки не изменились."
}

dh_remove_config_with_rollback(){
  local backup_dir rc=0
  backup_dir="$(dh_snapshot_create)" || fail "Не удалось создать backup перед удалением настройки DoubleHop."
  # Always disable first, then remove local outbound/link.
  if ! dh_materialize_xray_template_if_missing >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_mutate_mode "off" 1 >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_restart_runtime >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_verify_clean_state "removed" >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_verify_links_unchanged "$backup_dir" >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -eq 0 ]] && ! dh_run_health_validation >>"$backup_dir/operation.log" 2>&1; then rc=1; fi
  if [[ $rc -ne 0 ]]; then
    warn "Не удалось безопасно удалить настройку DoubleHop. Выполняю rollback."
    dh_restore_snapshot "$backup_dir" >/dev/null 2>&1 || true
    fail "Настройка DoubleHop не удалена. Подробности в backup: $backup_dir"
  fi
  rm -f "$(dh_exit_link_file)" "$(dh_state_file)" 2>/dev/null || true
  dh_prune_backups || true
  echo
  echo "Настройка DoubleHop удалена с этого Entry-сервера."
  echo
  echo "Если вы создавали отдельного VLESS-клиента на Exit-сервере только для DoubleHop,"
  echo "удалите его вручную на Exit-сервере, когда он больше не нужен."
}

# ---------- menus ----------

dh_menu_status(){
  local DH_MODE DH_INCONSISTENT DH_EXIT_CONFIGURED
  eval "$(dh_state_shell)"
  if [[ "${DH_INCONSISTENT:-0}" == "1" ]]; then
    echo
    echo "Статус DoubleHop"
    echo
    printf 'Этот сервер:      Entry\n'
    printf 'Режим:            неполная / требуется восстановление\n'
    printf 'Exit-сервер:      %s\n' "$([[ "${DH_EXIT_CONFIGURED:-0}" == "1" ]] && echo настроен || echo не настроен)"
    printf 'VLESS link:       без изменений\n'
    printf 'Telegram link:    без изменений\n'
    echo
    echo "Конфигурация DoubleHop неполная."
    echo
    echo "XPAM может безопасно восстановить её или выключить DoubleHop и вернуть direct-режим."
    echo
    echo "1) Восстановить DoubleHop"
    echo "2) Выключить DoubleHop"
    echo "0) Отмена"
    local c
    read -r -p "Выберите пункт [0-2]: " c || true
    case "$c" in
      1) dh_menu_enable_change ;;
      2) dh_menu_disable ;;
      *) echo "Отменено." ;;
    esac
    return 0
  fi
  echo
  echo "Статус DoubleHop"
  echo
  printf 'Этот сервер:      Entry\n'
  printf 'Режим:            %s\n' "$(dh_mode_label_ru "${DH_MODE:-off}")"
  printf 'Exit-сервер:      %s\n' "$([[ "${DH_EXIT_CONFIGURED:-0}" == "1" ]] && echo настроен || echo не настроен)"
  printf 'VLESS link:       без изменений\n'
  printf 'Telegram link:    без изменений\n'
  if dh_run_health_validation >/dev/null 2>&1; then
    printf 'Health:           OK\n'
  else
    printf 'Health:           требуется проверка\n'
  fi
}

dh_menu_enable_change(){
  local DH_EXIT_CONFIGURED choice mode label answer exit_saved_now=0
  eval "$(dh_state_shell)"
  echo
  echo "Настройка DoubleHop"
  echo
  echo "Вы настраиваете этот сервер как Entry-сервер."
  echo
  echo "Трафик будет входить на этот сервер через ваши текущие VLESS/Telegram-ссылки,"
  echo "а выбранный трафик будет выходить через другой сервер."
  echo
  echo "На Exit-сервере:"
  echo "  1. Создайте или выберите VLESS-клиента."
  echo "  2. Скопируйте его VLESS-ссылку."
  echo
  echo "На этом Entry-сервере:"
  echo "  3. Вставьте VLESS-ссылку Exit-сервера здесь."
  echo
  echo "XPAM не изменяет Exit-сервер."
  echo "XPAM настраивает только маршрутизацию на этом Entry-сервере."
  echo
  if [[ "${DH_EXIT_CONFIGURED:-0}" != "1" ]]; then
    dh_prompt_and_save_exit_link || return 0
    exit_saved_now=1
  else
    if confirm "Использовать уже сохранённую VLESS-ссылку Exit-сервера?" yes; then
      :
    else
      dh_prompt_and_save_exit_link || return 0
      exit_saved_now=1
    fi
  fi
  echo
  echo "Выберите режим DoubleHop:"
  echo
  echo "1) Только VLESS"
  echo "2) Только Telegram"
  echo "3) VLESS + Telegram"
  echo "0) Отмена"
  read -r -p "Выберите пункт [0-3]: " choice || true
  case "$choice" in
    1) mode="vless-only"; label="VLESS" ;;
    2) mode="telegram-only"; label="Telegram" ;;
    3) mode="all"; label="VLESS + Telegram" ;;
    *)
      if [[ "$exit_saved_now" == "1" ]]; then
        echo "DoubleHop не включён. VLESS-ссылка Exit-сервера сохранена для будущей настройки."
      else
        echo "Отменено. Изменений не внесено."
      fi
      return 0
      ;;
  esac
  echo
  echo "DoubleHop будет включён для: ${label}"
  echo
  echo "Ваши текущие ссылки НЕ изменятся:"
  echo "  VLESS: без изменений"
  echo "  Telegram: без изменений"
  echo
  read -r -p "Продолжить? [yes/no]: " answer || true
  case "$answer" in
    yes|YES|y|Y|д|Д) dh_apply_mode_with_rollback "$mode" "$label" ;;
    *)
      if [[ "$exit_saved_now" == "1" ]]; then
        echo "DoubleHop не включён. VLESS-ссылка Exit-сервера сохранена для будущей настройки."
      else
        echo "Отменено. Изменений не внесено."
      fi
      ;;
  esac
}

dh_menu_disable(){
  local answer
  echo
  read -r -p "Выключить DoubleHop и вернуть трафик в direct-режим? [yes/no]: " answer || true
  case "$answer" in
    yes|YES|y|Y|д|Д) dh_disable_with_rollback ;;
    *) echo "Отменено. Изменений не внесено." ;;
  esac
}

dh_status_technical(){
  local DH_MODE DH_INCONSISTENT DH_EXIT_CONFIGURED DH_EXIT_OUTBOUND DH_VLESS_ROUTE DH_MTG_ACTIVE DH_MTG_OUTBOUND_TAG DH_ROUTE_XRAY_PORT DH_ROUTE_XRAY_LISTENER DH_VLESS_INBOUND_TAG DH_EXIT_HOST
  eval "$(dh_state_shell)"
  echo
  echo "Technical DoubleHop state"
  echo "Mode: ${DH_MODE:-unknown}"
  echo "Inconsistent: ${DH_INCONSISTENT:-0}"
  echo "Exit link configured: ${DH_EXIT_CONFIGURED:-0}"
  echo "Exit outbound tag: ${DH_EXIT_TAG}"
  echo "Exit outbound exists: ${DH_EXIT_OUTBOUND:-0}"
  echo "Exit host: ${DH_EXIT_HOST:-}"
  echo "VLESS inbound tag: ${DH_VLESS_INBOUND_TAG:-}"
  echo "VLESS DH route: ${DH_VLESS_ROUTE:-0}"
  echo "DH routing rule count: ${DH_DH_RULE_COUNT:-0}"
  echo "Bad/stale DH route: ${DH_BAD_ROUTE:-0}"
  echo "MTG routeThroughXray: ${DH_MTG_ACTIVE:-0}"
  echo "MTG outboundTag: ${DH_MTG_OUTBOUND_TAG:-}"
  echo "routeXrayPort: ${DH_ROUTE_XRAY_PORT:-none}"
  echo "routeXrayPort listener: ${DH_ROUTE_XRAY_LISTENER:-0}"
  echo "MTG TOML proxy: ${DH_MTG_TOML_PROXY:-0}"
  echo "MTG TOML expected proxy: ${DH_MTG_TOML_PROXY_EXPECTED:-0}"
}

dh_diagnostics(){
  dh_status_technical
  echo
  echo "Generated routing rules to ${DH_EXIT_TAG}:"
  python3 - <<'PY_DH_DIAG' || true
import json
try:
    c=json.load(open('/usr/local/x-ui/bin/config.json'))
except Exception as e:
    print('cannot read generated config:', e)
    raise SystemExit
for i,r in enumerate((c.get('routing') or {}).get('rules') or []):
    if isinstance(r,dict) and r.get('outboundTag') == 'xpam-dh-exit':
        print(i, r)
PY_DH_DIAG
}

dh_menu_advanced(){
  local c answer
  echo
  echo "Дополнительно / удалить настройку"
  echo
  echo "1) Показать техническое состояние DoubleHop"
  echo "2) Удалить сохранённую настройку Exit-сервера"
  echo "3) Запустить диагностику DoubleHop"
  echo "0) Назад"
  read -r -p "Выберите пункт [0-3]: " c || true
  case "$c" in
    1) dh_status_technical ;;
    2)
      echo
      echo "Сначала DoubleHop будет выключен, затем будет удалена локальная настройка Exit-сервера."
      read -r -p "Продолжить? [yes/no]: " answer || true
      case "$answer" in yes|YES|y|Y|д|Д) dh_remove_config_with_rollback ;; *) echo "Отменено." ;; esac
      ;;
    3) dh_diagnostics ;;
    *) return 0 ;;
  esac
}

stage_doublehop_menu(){
  dh_load_config_for_menu
  dh_preflight
  local DH_MODE DH_EXIT_CONFIGURED choice
  eval "$(dh_state_shell)"
  echo
  echo "Режим DoubleHop"
  echo
  echo "Текущий режим: $(dh_mode_label_ru "${DH_MODE:-off}")"
  echo "Этот сервер: Entry"
  echo "Exit-сервер: $([[ "${DH_EXIT_CONFIGURED:-0}" == "1" ]] && echo настроен || echo не настроен)"
  echo
  echo "1) Включить / изменить DoubleHop"
  echo "2) Выключить DoubleHop"
  echo "3) Показать статус"
  echo "4) Дополнительно / удалить настройку"
  echo "0) Назад"
  read -r -p "Выберите пункт [0-4]: " choice || true
  case "$choice" in
    1) dh_menu_enable_change ;;
    2) dh_menu_disable ;;
    3) dh_menu_status ;;
    4) dh_menu_advanced ;;
    0) return 0 ;;
    *) fail "Неизвестный пункт меню" ;;
  esac
}
