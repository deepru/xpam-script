#!/usr/bin/env bash
set -Eeuo pipefail

KIT_VERSION="v1.3.5"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="/etc/xpam-script"
CONFIG_FILE="${CONFIG_DIR}/config.env"
PREFIX_BOOTSTRAP_FILE="${CONFIG_DIR}/prefix.env"
LOG="/var/log/xpam-script/xpam-script-${KIT_VERSION}-$(date +%F-%H%M%S).log"
RUNTIME_KIT_DIR="/opt/xpam-script"
PREPARE_DONE_FILE="${CONFIG_DIR}/stage-prepare.done"
XPAM_STATE_DIR="/var/lib/xpam-script"
REBOOT_SENSITIVE_MARKER="${XPAM_STATE_DIR}/reboot-sensitive-upgrades"


RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
say(){ echo -e "${BLUE}==>${NC} $*"; }
ok(){ echo -e "${GREEN}OK:${NC} $*"; }
warn(){ echo -e "${YELLOW}WARN:${NC} $*"; }
fail(){ echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите от root: sudo ./install.sh"; }

run_with_heartbeat(){
  local label="$1" interval="${XPAM_HEARTBEAT_INTERVAL:-30}" elapsed=0 pid rc
  shift
  warn "$label может занять несколько минут. Не закрывайте SSH-сессию."
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed % interval == 0 )) && kill -0 "$pid" 2>/dev/null; then
      ok "$label всё ещё выполняется... ${elapsed}s"
    fi
  done
  wait "$pid"
  rc=$?
  return "$rc"
}

apt_dpkg_recovery(){
  local context="${1:-apt}" attempt audit_file apt_log
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

  say "APT/DPKG recovery check: $context"

  for attempt in 1 2 3; do
    audit_file="$(mktemp /tmp/xpam-script-dpkg-audit.XXXXXX)"
    dpkg --audit >"$audit_file" 2>&1 || true
    if [[ ! -s "$audit_file" ]]; then
      rm -f "$audit_file"
      ok "dpkg audit clean"
      return 0
    fi

    warn "Ubuntu package manager has unfinished package configuration. Attempt ${attempt}/3."
    sed -n '1,80p' "$audit_file" | sed 's/^/  /' || true
    rm -f "$audit_file"

    say "Running safe automatic recovery: dpkg --configure -a"
    if ! run_with_heartbeat "dpkg --configure -a" env DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
      warn "dpkg --configure -a returned non-zero; will try apt-get -f install and re-check"
    fi

    say "Running safe automatic recovery: apt-get -f install"
    apt_log="$(mktemp /tmp/xpam-script-apt-fix.XXXXXX)"
    if ! run_with_heartbeat "apt-get -f install" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=180 -f install -y > >(tee "$apt_log") 2>&1; then
      if grep -Eiq 'Could not get lock|Unable to acquire the dpkg frontend lock|dpkg frontend lock is locked|apt.systemd.daily|dpkg was interrupted' "$apt_log" 2>/dev/null; then
        warn "APT/DPKG lock or interrupted state is still present; waiting 15 seconds before retry"
        sleep 15
      else
        warn "apt-get -f install returned non-zero; retrying if audit is still dirty"
      fi
    fi
    rm -f "$apt_log"
  done

  audit_file="$(mktemp /tmp/xpam-script-dpkg-audit.XXXXXX)"
  dpkg --audit >"$audit_file" 2>&1 || true
  if [[ -s "$audit_file" ]]; then
    echo
    fail "Ubuntu package manager is still not healthy. Run: sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a && sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y && sudo dpkg --audit, then start XPAM Script again."
  fi
  rm -f "$audit_file"
  ok "APT/DPKG recovery finished"
}

apt_get_safe(){
  local context="$1"; shift
  local log
  apt_dpkg_recovery "$context"
  log="$(mktemp /tmp/xpam-script-apt.XXXXXX)"
  if run_with_heartbeat "APT operation: $context" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 "$@" > >(tee "$log") 2>&1; then
    rm -f "$log"
    return 0
  fi
  if grep -Eiq 'dpkg was interrupted|Could not get lock|Unable to acquire the dpkg frontend lock|dpkg frontend lock is locked' "$log" 2>/dev/null; then
    warn "APT reported interrupted dpkg or lock during $context; trying recovery and one retry"
    rm -f "$log"
    apt_dpkg_recovery "$context retry"
    run_with_heartbeat "APT retry: $context" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 "$@"
    return $?
  fi
  rm -f "$log"
  return 1
}

xui_installed_ok(){
  [[ -x /usr/local/x-ui/x-ui && -s /etc/x-ui/x-ui.db ]] || return 1
  systemctl cat x-ui.service >/dev/null 2>&1 || return 1
  return 0
}

xui_env_file(){
  echo "/etc/default/x-ui"
}

xui_env_value(){
  local key="$1" file
  file="$(xui_env_file)"
  [[ -f "$file" ]] || return 0
  awk -F= -v k="$key" '
    $1 == k {
      v=$0; sub(/^[^=]*=/, "", v);
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);
      gsub(/^"|"$/, "", v);
      gsub(/^'"'"'|'"'"'$/, "", v);
      print v
    }
  ' "$file" 2>/dev/null | tail -n 1
}

xui_backend_type(){
  local db_type norm
  db_type="${XUI_DB_TYPE:-}"
  [[ -n "$db_type" ]] || db_type="$(xui_env_value XUI_DB_TYPE || true)"
  norm="$(printf '%s' "$db_type" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$norm" in
    ""|sqlite|sqlite3) echo "sqlite" ;;
    postgres|postgresql|pg) echo "postgres" ;;
    *) echo "unsupported:$db_type" ;;
  esac
}

xui_prepare_sqlite_backend_for_install(){
  local backend env_file tmp
  backend="$(xui_backend_type)"
  env_file="$(xui_env_file)"
  case "$backend" in
    sqlite) ;;
    postgres|unsupported:*)
      if systemctl cat x-ui.service >/dev/null 2>&1 || [[ -x /usr/local/x-ui/x-ui || -s /etc/x-ui/x-ui.db ]]; then
        fail "3x-ui backend is not supported by XPAM Script: ${backend}. XPAM supports only 3x-ui SQLite backend at /etc/x-ui/x-ui.db."
      fi
      warn "Removing pre-existing 3x-ui PostgreSQL backend env before fresh SQLite install: $env_file"
      ;;
  esac
  if [[ -f "$env_file" ]]; then
    tmp="$(mktemp /tmp/xpam-xui-env.XXXXXX)"
    grep -Ev '^(XUI_DB_TYPE|XUI_DB_DSN)=' "$env_file" > "$tmp" || true
    cat "$tmp" > "$env_file"
    rm -f "$tmp"
    chmod 600 "$env_file" 2>/dev/null || true
  fi
  unset XUI_DB_TYPE XUI_DB_DSN
}

xui_assert_sqlite_backend(){
  local backend
  backend="$(xui_backend_type)"
  case "$backend" in
    sqlite) return 0 ;;
    postgres) fail "3x-ui PostgreSQL backend detected. XPAM Script supports only 3x-ui SQLite backend at /etc/x-ui/x-ui.db. No 3x-ui data changes were made." ;;
    unsupported:*) fail "Unsupported 3x-ui backend detected (${backend#unsupported:}). XPAM Script supports only 3x-ui SQLite backend at /etc/x-ui/x-ui.db." ;;
  esac
}

xui_validate_sqlite_contract(){
  local db="/etc/x-ui/x-ui.db"
  xui_assert_sqlite_backend
  [[ -s "$db" ]] || fail "3x-ui SQLite DB missing: $db"
  python3 - <<'PY_XUI_SQLITE_CONTRACT'
import sqlite3, sys

db='/etc/x-ui/x-ui.db'
try:
    conn=sqlite3.connect(db)
    cur=conn.cursor()
    cur.execute('PRAGMA integrity_check')
    cols=[r[1] for r in cur.execute('PRAGMA table_info(inbounds)').fetchall()]
except Exception as exc:
    sys.exit(f'3x-ui SQLite DB is not readable: {exc}')
if not cols:
    sys.exit('3x-ui SQLite schema is not compatible: inbounds table missing or empty schema')
stream_col=next((c for c in ('stream_settings','streamSettings','stream') if c in cols), None)
if not stream_col:
    sys.exit('3x-ui SQLite schema is not compatible: stream settings column not found')
print(f'OK: 3x-ui backend SQLite OK: {db}')
print(f'OK: 3x-ui backend SQLite schema OK: stream settings column = {stream_col}')
PY_XUI_SQLITE_CONTRACT
}

ensure_xui_ready_for_finalize(){
  if xui_installed_ok; then
    return 0
  fi
  if [[ "${XUI_AUTO_SETUP:-yes}" == "yes" ]]; then
    warn "3x-ui is not installed/configured yet; running automatic 3x-ui setup before finalization."
    warn "This can happen after an interrupted apt/dpkg operation on a fresh VPS image."
    if [[ -z "${XUI_ADMIN_PASS:-}" ]]; then
      ask_xui_admin_credentials
    fi
    install_configure_3xui_auto
    return 0
  fi
  fail "3x-ui is missing and automatic setup is disabled. Re-enable auto setup or install 3x-ui manually before finalization."
}

PROFILE=""; SERVER_PREFIX=""; ROOT_DOMAIN=""; WWW_DOMAIN=""; PRIMARY_DOMAIN=""; SYNC_DOMAIN=""; WEB_CERT_NAME=""; CERT_EMAIL=""
PANEL_PATH="api/internal/storage"; XUI_PANEL_PORT="57827"; XUI_AUTO_SETUP="yes"; XUI_ADMIN_USER="vlessuser"; XUI_ADMIN_PASS="${XUI_ADMIN_PASS:-}"; XUI_INSTALLED_TAG=""; XRAY_PUBLIC_PORT="443"; XRAY_LOCAL_PORT="1443"; SSH_PUBLIC_PORT="22"; HTTP_PUBLIC_PORT="80"; SITE_BACKEND_PORT="8080"; SYNC_BACKEND_PORT="9443"; MTPROTO_PORT="47827"; MTPROTO_BACKEND="${MTPROTO_BACKEND:-alexbers}"; ALLOW_IPV6_443="no"; BASIC_USER="admin"
MTPROTO_REPO_URL="https://github.com/alexbers/mtprotoproxy.git"; MTPROTO_REPO_BRANCH="stable"
TELEGRAM_RELAY_PATH="api/internal/notify-relay"; TELEGRAM_RELAY_SOCKET="/run/xpam-script-telegram-relay.sock"

# XPAM Auto internal policy defaults. These are intentionally hidden from the normal user menu.
XPAM_DNS_POLICY_MODE="${XPAM_DNS_POLICY_MODE:-safe}"        # safe|strict
XPAM_OUTPUT_MODE="${XPAM_OUTPUT_MODE:-compact}"            # compact|verbose
XPAM_MAINT_APT_MODE="${XPAM_MAINT_APT_MODE:-security}"     # security|upgrade|full|off
XPAM_SERVICE_HYGIENE_MODE="${XPAM_SERVICE_HYGIENE_MODE:-safe}"
XPAM_BACKUP_KEEP="${XPAM_BACKUP_KEEP:-2}"
XPAM_HEALTH_LOG_KEEP="${XPAM_HEALTH_LOG_KEEP:-4}"
XPAM_WEEKLY_LOG_KEEP="${XPAM_WEEKLY_LOG_KEEP:-4}"
XPAM_PROVIDER_NETWORKING_WARN_ONLY="${XPAM_PROVIDER_NETWORKING_WARN_ONLY:-auto}"

ask(){
  local var="$1" prompt="$2" def="${3:-}" ans c_def="" c_off=""
  if [[ -t 1 ]]; then c_def="$YELLOW"; c_off="$NC"; fi
  if [[ -n "$def" ]]; then
    printf '%s [%b%s%b]: ' "$prompt" "$c_def" "$def" "$c_off"
    read -r ans || true
    ans="${ans:-$def}"
  else
    printf '%s: ' "$prompt"
    read -r ans || true
  fi
  printf -v "$var" '%s' "$ans"
}
ask_default_label(){
  local var="$1" prompt="$2" def="${3:-}" ans c_def="" c_off=""
  if [[ -t 1 ]]; then c_def="$YELLOW"; c_off="$NC"; fi
  printf '%s [по умолчанию: %s]: ' "$prompt" "$def"
  read -r ans || true
  ans="${ans:-$def}"
  printf -v "$var" '%s' "$ans"
}
confirm(){
  local prompt="$1" def="${2:-yes}" ans
  case "$def" in
    y|Y|yes|YES|Yes) def="yes" ;;
    n|N|no|NO|No) def="no" ;;
    *) def="yes" ;;
  esac
  read -r -p "$prompt Введите yes или no [$def]: " ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]
}
ask_xui_admin_credentials(){
  ask XUI_ADMIN_USER "3x-ui admin username" "${XUI_ADMIN_USER:-vlessuser}"
  local p1 p2
  while true; do
    read -r -s -p "3x-ui admin password: " p1 || true
    echo
    if [[ -z "$p1" ]]; then
      warn "Пароль 3x-ui не может быть пустым"
      continue
    fi
    if (( ${#p1} < 10 )); then
      warn "Пароль 3x-ui выглядит коротким. Рекомендуется минимум 10 символов."
      if ! confirm "Продолжить с этим коротким паролем?" no; then
        continue
      fi
    fi
    read -r -s -p "Повторите 3x-ui admin password: " p2 || true
    echo
    if [[ "$p1" != "$p2" ]]; then
      warn "Пароли 3x-ui не совпали"
      continue
    fi
    XUI_ADMIN_PASS="$p1"
    break
  done
}
normalize_path(){
  local p="$1"
  p="${p//$'\r'/}"
  p="${p//$'\n'/}"
  p="${p//$'\t'/ }"
  p="${p//\\//}"
  p="$(printf '%s' "$p" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s#/{2,}#/#g; s#^/+##; s#/+$##')"
  printf '%s\n' "$p"
}
normalize_https_relay_url(){
  local u="$1"
  u="${u//$'\r'/}"
  u="${u//$'\n'/}"
  u="$(printf '%s' "$u" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -n "$u" ]] || fail "Relay URL не может быть пустым"
  [[ "$u" == https://* ]] || fail "Relay URL должен начинаться с https://"
  [[ "$u" != *" "* && "$u" != *$'\t'* ]] || fail "Relay URL не должен содержать пробелы"
  u="${u%/}/"
  printf '%s' "$u"
}
unique_domains(){ printf '%s\n' "$@" | awk 'NF && !seen[$0]++' | xargs; }
uses_mtproto(){ [[ "$PROFILE" == "subdomains_mtproto" || "$PROFILE" == "root_mtproto" ]]; }
uses_haproxy(){ uses_mtproto; }
# Backend selector/abstraction. Stage 4 supports alexbers legacy/rollback and
# the controlled 3xui-mtg runtime path. Teleproxy remains reserved/future.
mtproto_backend_allowed_values(){ printf 'alexbers 3xui-mtg teleproxy\n'; }
mtproto_backend_effective(){
  if ! uses_mtproto; then
    printf 'none\n'
    return 0
  fi
  local backend="${MTPROTO_BACKEND:-}"
  [[ -n "$backend" ]] || backend="alexbers"
  printf '%s\n' "$backend"
}
mtproto_backend_validate_value(){
  local backend="${1:-}"
  case "$backend" in
    ""|alexbers|3xui-mtg|teleproxy) return 0 ;;
    *) fail "MTPROTO_BACKEND must be one of: $(mtproto_backend_allowed_values); got: $backend" ;;
  esac
}
mtproto_backend_runtime_supported(){
  local backend
  backend="$(mtproto_backend_effective)"
  [[ "$backend" == "none" || "$backend" == "alexbers" || "$backend" == "3xui-mtg" ]]
}
mtproto_backend_is_alexbers(){ [[ "$(mtproto_backend_effective)" == "alexbers" ]]; }
mtproto_backend_is_3xui_mtg(){ [[ "$(mtproto_backend_effective)" == "3xui-mtg" ]]; }
mtproto_backend_is_teleproxy(){ [[ "$(mtproto_backend_effective)" == "teleproxy" ]]; }
mtproto_backend_reserved_message(){
  local backend="${1:-$(mtproto_backend_effective)}"
  printf 'MTPROTO_BACKEND=%s is recognized/reserved but not implemented in this runtime patch yet. Current runtime support is alexbers legacy/rollback and 3xui-mtg.' "$backend"
}
mtproto_backend_require_runtime_supported(){
  local backend
  backend="$(mtproto_backend_effective)"
  case "$backend" in
    none|alexbers|3xui-mtg) return 0 ;;
    teleproxy) fail "$(mtproto_backend_reserved_message "$backend")" ;;
    *) fail "Unsupported MTPROTO_BACKEND: $backend" ;;
  esac
}
# Backward-compatible name for the Stage 1 gate; keep it while later stages
# switch call sites to the generic backend runtime gate.
mtproto_backend_require_stage1_runtime_supported(){ mtproto_backend_require_runtime_supported; }
mtproto_backend_normalize_for_config(){
  if uses_mtproto; then
    MTPROTO_BACKEND="$(mtproto_backend_effective)"
  else
    MTPROTO_BACKEND="${MTPROTO_BACKEND:-alexbers}"
  fi
}
web_cert_name(){ [[ -n "$WEB_CERT_NAME" ]] && echo "$WEB_CERT_NAME" || echo "$PRIMARY_DOMAIN"; }
expected_xray_port(){ uses_haproxy && echo "$XRAY_LOCAL_PORT" || echo "$XRAY_PUBLIC_PORT"; }
expected_xray_listen_host(){
  if uses_haproxy; then
    echo "127.0.0.1"
  else
    server_public_ipv4
  fi
}
wait_for_xray_vless(){
  local timeout="${1:-30}" host port
  host="$(expected_xray_listen_host)"
  port="$(expected_xray_port)"
  [[ -n "$host" ]] || fail "Could not detect public IPv4 for Xray/VLESS listener check"
  /usr/local/sbin/wait-for-local-port.sh "$host" "$port" "$timeout" xray-vless
}
root_web_domains(){ [[ "$PROFILE" == "root_mtproto" ]] && unique_domains "$ROOT_DOMAIN" "$WWW_DOMAIN" || true; }
web_domains(){ case "$PROFILE" in vless_direct|subdomains_mtproto) unique_domains "$PRIMARY_DOMAIN" ;; root_mtproto) unique_domains "$ROOT_DOMAIN" "$WWW_DOMAIN" "$PRIMARY_DOMAIN" ;; *) echo "" ;; esac; }
root_site_dir(){ if [[ -n "${ROOT_DOMAIN:-}" ]]; then echo "/var/www/${ROOT_DOMAIN}"; else echo "/var/www/${SERVER_PREFIX}-main-site"; fi; }
service_site_dir(){ echo "/var/www/${PRIMARY_DOMAIN}"; }
backup_file(){ local f="$1"; [[ -e "$f" ]] && cp -a "$f" "$f.bak-xpam-script-$(date +%Y%m%d-%H%M%S)" || true; }

validate_domain(){ local name="$1" val="$2"; [[ -n "$val" && "$val" =~ ^[A-Za-z0-9.-]+$ && "$val" == *.* && "$val" != .* && "$val" != *..* ]] || fail "$name must be a domain, got: $val"; }
validate_cert_name(){ local name="$1" val="$2"; [[ -n "$val" && "$val" =~ ^[A-Za-z0-9_.-]+$ && "$val" != */* ]] || fail "$name must be a safe certbot certificate name, got: $val"; }
validate_port(){ local name="$1" val="$2"; [[ "$val" =~ ^[0-9]+$ && "$val" -ge 1 && "$val" -le 65535 ]] || fail "$name must be TCP port 1..65535, got: $val"; }
validate_panel_path(){
  local val="$1" first
  [[ -n "$val" ]] || fail "PANEL_PATH cannot be empty"
  [[ "$val" =~ ^[A-Za-z0-9._~/-]+$ ]] || fail "PANEL_PATH contains unsupported characters"
  [[ "$val" != *..* ]] || fail "PANEL_PATH must not contain .."
  [[ "$val" != "." ]] || fail "PANEL_PATH must not be ."
  first="${val%%/*}"
  case "$first" in
    .well-known)
      fail "PANEL_PATH uses reserved path segment: /$first"
      ;;
  esac
}

require_os(){ source /etc/os-release || true; case "${ID:-}" in ubuntu|debian) ok "OS supported: ${PRETTY_NAME:-$ID}" ;; *) fail "Unsupported OS: ${PRETTY_NAME:-unknown}. Use Ubuntu 24.04 or Debian 12." ;; esac; }
validate_inputs(){
  validate_domain PRIMARY_DOMAIN "$PRIMARY_DOMAIN"; WEB_CERT_NAME="$(web_cert_name)"; validate_cert_name WEB_CERT_NAME "$WEB_CERT_NAME"

  # External/public ports are fixed by design. Do not let profiles drift into unsafe layouts.
  SSH_PUBLIC_PORT="22"
  HTTP_PUBLIC_PORT="80"
  XRAY_PUBLIC_PORT="443"

  for pair in "XUI_PANEL_PORT:$XUI_PANEL_PORT" "XRAY_PUBLIC_PORT:$XRAY_PUBLIC_PORT" "XRAY_LOCAL_PORT:$XRAY_LOCAL_PORT" "SITE_BACKEND_PORT:$SITE_BACKEND_PORT" "SSH_PUBLIC_PORT:$SSH_PUBLIC_PORT" "HTTP_PUBLIC_PORT:$HTTP_PUBLIC_PORT"; do
    validate_port "${pair%%:*}" "${pair##*:}"
  done

  PANEL_PATH="$(normalize_path "$PANEL_PATH")"; validate_panel_path "$PANEL_PATH"
  TELEGRAM_RELAY_PATH="$(normalize_path "${TELEGRAM_RELAY_PATH:-api/internal/notify-relay}")"; [[ -n "$TELEGRAM_RELAY_PATH" ]] || fail "TELEGRAM_RELAY_PATH cannot be empty"
  [[ "$TELEGRAM_RELAY_PATH" =~ ^[A-Za-z0-9._~/-]+$ ]] || fail "TELEGRAM_RELAY_PATH contains unsupported characters"
  [[ "$TELEGRAM_RELAY_PATH" != *..* ]] || fail "TELEGRAM_RELAY_PATH must not contain .."

  if uses_mtproto; then
    mtproto_backend_validate_value "${MTPROTO_BACKEND:-}"
    mtproto_backend_require_runtime_supported
    validate_domain SYNC_DOMAIN "$SYNC_DOMAIN"
    validate_port MTPROTO_PORT "$MTPROTO_PORT"
    validate_port SYNC_BACKEND_PORT "$SYNC_BACKEND_PORT"
    [[ "$SYNC_DOMAIN" != "$PRIMARY_DOMAIN" ]] || fail "SYNC_DOMAIN must differ from PRIMARY_DOMAIN"
  fi

  if [[ "$PROFILE" == "root_mtproto" ]]; then
    validate_domain ROOT_DOMAIN "$ROOT_DOMAIN"
    [[ "$ROOT_DOMAIN" != www.* ]] || fail "ROOT_DOMAIN must be root/apex domain without www"
    WWW_DOMAIN="www.${ROOT_DOMAIN}"
    validate_domain WWW_DOMAIN "$WWW_DOMAIN"
    [[ "$PRIMARY_DOMAIN" != "$ROOT_DOMAIN" && "$PRIMARY_DOMAIN" != "$WWW_DOMAIN" ]] || fail "PRIMARY_DOMAIN must differ from main/root and auto-www domains"
    if uses_mtproto; then [[ "$SYNC_DOMAIN" != "$ROOT_DOMAIN" && "$SYNC_DOMAIN" != "$WWW_DOMAIN" ]] || fail "SYNC_DOMAIN must differ from main/root and auto-www domains"; fi
  fi

  local forbidden=" 22 80 443 " name port seen_ports=" "
  for pair in "XUI_PANEL_PORT:$XUI_PANEL_PORT" "SITE_BACKEND_PORT:$SITE_BACKEND_PORT"; do
    name="${pair%%:*}"; port="${pair##*:}"
    [[ "$forbidden" != *" $port "* ]] || fail "$name is an internal/local port and must not be 22, 80, or 443"
    [[ "$seen_ports" != *" $port "* ]] || fail "Internal/local port conflict detected: $port"
    seen_ports+="$port "
  done
  if uses_haproxy; then
    for pair in "XRAY_LOCAL_PORT:$XRAY_LOCAL_PORT"; do
      name="${pair%%:*}"; port="${pair##*:}"
      [[ "$forbidden" != *" $port "* ]] || fail "$name is an internal/local port and must not be 22, 80, or 443"
      [[ "$seen_ports" != *" $port "* ]] || fail "Internal/local port conflict detected: $port"
      seen_ports+="$port "
    done
  fi
  if uses_mtproto; then
    for pair in "SYNC_BACKEND_PORT:$SYNC_BACKEND_PORT" "MTPROTO_PORT:$MTPROTO_PORT"; do
      name="${pair%%:*}"; port="${pair##*:}"
      [[ "$forbidden" != *" $port "* ]] || fail "$name is an internal/local port and must not be 22, 80, or 443"
      [[ "$seen_ports" != *" $port "* ]] || fail "Internal/local port conflict detected: $port"
      seen_ports+="$port "
    done
  fi

  if uses_haproxy && [[ "$(expected_xray_port)" == "$XRAY_PUBLIC_PORT" ]]; then fail "HAProxy mode requires local Xray port different from public 443"; fi
}


install_runtime_kit(){
  need_root
  local src dst
  src="$(cd "$KIT_DIR" && pwd -P)"
  dst="$RUNTIME_KIT_DIR"

  if [[ "$src" == "$dst" ]]; then
    ok "XPAM Script runtime already installed: $dst"
    return 0
  fi

  say "Installing XPAM Script runtime to $dst"
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude '.git' \
      --exclude '*.log' \
      "$src"/ "$dst"/
  else
    find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    (cd "$src" && tar --exclude='.git' --exclude='*.log' -cf - .) | (cd "$dst" && tar -xf -)
  fi
  chmod 755 "$dst" "$dst/install.sh" 2>/dev/null || true
  migrate_legacy_system_file_names || true
  ok "XPAM Script runtime installed: $dst"
}

server_prefix_valid(){
  local value="${1:-}"
  [[ -n "$value" && "$value" =~ ^[A-Za-z0-9_-]+$ ]]
}

validate_server_prefix(){
  server_prefix_valid "${SERVER_PREFIX:-}" || fail "SERVER_PREFIX must contain only letters, digits, underscore or dash: ${SERVER_PREFIX:-<empty>}"
}

legacy_project_name(){
  printf 'server-%b-kit' '\x64\x65\x70\x6c\x6f\x79'
}

legacy_short_name(){
  printf '%b-kit' '\x64\x65\x70\x6c\x6f\x79'
}

legacy_title_name(){
  printf 'Server %s Kit' 'Deploy'
}

legacy_config_dir(){
  # One-time import path for older installations. Kept non-user-facing.
  printf '/etc/%s' "$(legacy_project_name)"
}

legacy_runtime_dir(){
  printf '/opt/%s' "$(legacy_project_name)"
}

legacy_rewrite_file_brand(){
  local f="$1" old_project old_short old_title
  [[ -f "$f" ]] || return 0
  old_project="$(legacy_project_name)"
  old_short="$(legacy_short_name)"
  old_title="$(legacy_title_name)"
  sed -i \
    -e "s/${old_title}/XPAM Script/g" \
    -e "s/${old_project}/xpam-script/g" \
    -e "s/${old_short}/xpam-script/g" \
    "$f" 2>/dev/null || true
}

migrate_legacy_system_file_names(){
  local old_project old_network old_swap new_network new_swap d old_dns new_dns legacy_dir legacy_runtime
  old_project="$(legacy_project_name)"

  old_network="/etc/sysctl.d/99-${old_project}-network-tuning.conf"
  new_network="/etc/sysctl.d/99-xpam-script-network-tuning.conf"
  if [[ -f "$old_network" ]]; then
    mkdir -p /etc/sysctl.d
    cp -a "$old_network" "$new_network" 2>/dev/null || true
    legacy_rewrite_file_brand "$new_network"
    rm -f "$old_network" 2>/dev/null || true
  fi

  old_swap="/etc/sysctl.d/98-${old_project}-swap-policy.conf"
  new_swap="/etc/sysctl.d/98-xpam-script-swap-policy.conf"
  if [[ -f "$old_swap" ]]; then
    mkdir -p /etc/sysctl.d
    cp -a "$old_swap" "$new_swap" 2>/dev/null || true
    legacy_rewrite_file_brand "$new_swap"
    rm -f "$old_swap" 2>/dev/null || true
  fi

  for d in /etc/systemd/network/*.network.d; do
    [[ -d "$d" ]] || continue
    old_dns="$d/90-${old_project}-no-provider-dns.conf"
    new_dns="$d/90-xpam-script-no-provider-dns.conf"
    if [[ -f "$old_dns" ]]; then
      cp -a "$old_dns" "$new_dns" 2>/dev/null || true
      legacy_rewrite_file_brand "$new_dns"
      rm -f "$old_dns" 2>/dev/null || true
    fi
  done

  legacy_dir="$(legacy_config_dir)"
  if [[ -d "$legacy_dir" && -f "$CONFIG_FILE" ]]; then
    rm -rf "$legacy_dir" 2>/dev/null || true
  fi

  legacy_runtime="$(legacy_runtime_dir)"
  if [[ -d "$legacy_runtime" && -d "$RUNTIME_KIT_DIR" ]]; then
    rm -rf "$legacy_runtime" 2>/dev/null || true
  fi
}

maybe_import_existing_config(){
  [[ -f "$CONFIG_FILE" || -f "$PREFIX_BOOTSTRAP_FILE" ]] && return 0

  local legacy_dir legacy_config legacy_prefix v
  legacy_dir="$(legacy_config_dir)"
  legacy_config="${legacy_dir}/config.env"
  legacy_prefix="${legacy_dir}/prefix.env"

  if [[ -f "$legacy_config" ]]; then
    # shellcheck disable=SC1090
    source "$legacy_config"
    TELEGRAM_RELAY_SOCKET="/run/xpam-script-telegram-relay.sock"
    validate_server_prefix
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    {
      echo "# Managed by xpam-script ${KIT_VERSION}"
      for v in PROFILE SERVER_PREFIX ROOT_DOMAIN WWW_DOMAIN PRIMARY_DOMAIN SYNC_DOMAIN WEB_CERT_NAME CERT_EMAIL PANEL_PATH XUI_PANEL_PORT XUI_AUTO_SETUP XUI_ADMIN_USER XUI_INSTALLED_TAG XRAY_PUBLIC_PORT XRAY_LOCAL_PORT SSH_PUBLIC_PORT HTTP_PUBLIC_PORT SITE_BACKEND_PORT SYNC_BACKEND_PORT MTPROTO_PORT MTPROTO_BACKEND ALLOW_IPV6_443 BASIC_USER MTPROTO_REPO_URL MTPROTO_REPO_BRANCH TELEGRAM_RELAY_PATH TELEGRAM_RELAY_SOCKET XPAM_DNS_POLICY_MODE XPAM_OUTPUT_MODE XPAM_MAINT_APT_MODE XPAM_SERVICE_HYGIENE_MODE XPAM_BACKUP_KEEP XPAM_HEALTH_LOG_KEEP XPAM_WEEKLY_LOG_KEEP XPAM_PROVIDER_NETWORKING_WARN_ONLY; do
        printf '%s=%q\n' "$v" "${!v:-}"
      done
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    {
      echo "# Managed by xpam-script ${KIT_VERSION}"
      printf 'SERVER_PREFIX=%q\n' "$SERVER_PREFIX"
    } > "$PREFIX_BOOTSTRAP_FILE"
    chmod 600 "$PREFIX_BOOTSTRAP_FILE"
    ok "Existing configuration imported into $CONFIG_DIR"
    return 0
  fi

  if [[ -f "$legacy_prefix" ]]; then
    # shellcheck disable=SC1090
    source "$legacy_prefix"
    validate_server_prefix
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    {
      echo "# Managed by xpam-script ${KIT_VERSION}"
      printf 'SERVER_PREFIX=%q\n' "$SERVER_PREFIX"
    } > "$PREFIX_BOOTSTRAP_FILE"
    chmod 600 "$PREFIX_BOOTSTRAP_FILE"
    ok "Existing command prefix imported into $CONFIG_DIR"
  fi
}

ask_server_prefix(){
  local def="${1:-server}"
  while true; do
    ask SERVER_PREFIX "Server prefix/name for commands, for example myserver" "$def"
    if server_prefix_valid "$SERVER_PREFIX"; then
      return 0
    fi
    warn "Use only letters, digits, underscore or dash. Example: server or myserver"
  done
}

load_prefix_bootstrap(){
  maybe_import_existing_config || true
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    validate_server_prefix
    return 0
  fi
  if [[ -f "$PREFIX_BOOTSTRAP_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PREFIX_BOOTSTRAP_FILE"
    validate_server_prefix
    return 0
  fi
  return 1
}

save_prefix_bootstrap(){
  validate_server_prefix
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  {
    echo "# Managed by xpam-script ${KIT_VERSION}"
    printf 'SERVER_PREFIX=%q\n' "$SERVER_PREFIX"
  } > "$PREFIX_BOOTSTRAP_FILE"
  chmod 600 "$PREFIX_BOOTSTRAP_FILE"
  ok "Saved command prefix: $PREFIX_BOOTSTRAP_FILE"
}

ensure_prefix_bootstrap(){
  if load_prefix_bootstrap; then
    ok "Server prefix/name for commands: ${SERVER_PREFIX}"
    return 0
  fi
  ask_server_prefix server
  save_prefix_bootstrap
}

save_config(){
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  mtproto_backend_normalize_for_config
  validate_server_prefix
  {
    echo "# Managed by xpam-script ${KIT_VERSION}"
    for v in PROFILE SERVER_PREFIX ROOT_DOMAIN WWW_DOMAIN PRIMARY_DOMAIN SYNC_DOMAIN WEB_CERT_NAME CERT_EMAIL PANEL_PATH XUI_PANEL_PORT XUI_AUTO_SETUP XUI_ADMIN_USER XUI_INSTALLED_TAG XRAY_PUBLIC_PORT XRAY_LOCAL_PORT SSH_PUBLIC_PORT HTTP_PUBLIC_PORT SITE_BACKEND_PORT SYNC_BACKEND_PORT MTPROTO_PORT MTPROTO_BACKEND ALLOW_IPV6_443 BASIC_USER MTPROTO_REPO_URL MTPROTO_REPO_BRANCH TELEGRAM_RELAY_PATH TELEGRAM_RELAY_SOCKET XPAM_DNS_POLICY_MODE XPAM_OUTPUT_MODE XPAM_MAINT_APT_MODE XPAM_SERVICE_HYGIENE_MODE XPAM_BACKUP_KEEP XPAM_HEALTH_LOG_KEEP XPAM_WEEKLY_LOG_KEEP XPAM_PROVIDER_NETWORKING_WARN_ONLY; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  ok "Saved config: $CONFIG_FILE"
  save_prefix_bootstrap || true
  install_runtime_kit || true
  write_install_launcher || true
  write_links_launcher || true
  write_vless_launcher || true
  write_tg_launcher || true
  write_repair_launcher || true
  write_netdiag_launcher || true
}

load_config(){ maybe_import_existing_config || true; [[ -f "$CONFIG_FILE" ]] || fail "Config not found: $CONFIG_FILE. Run menu item 1 first."; source "$CONFIG_FILE"; validate_server_prefix; migrate_legacy_system_file_names || true; [[ "${XPAM_SCRIPT_QUIET_LOAD_CONFIG:-0}" == "1" ]] || ok "Loaded config: $CONFIG_FILE"; }

show_config(){
  maybe_import_existing_config || true
  if [[ -f "$CONFIG_FILE" ]]; then
    sed -n '1,220p' "$CONFIG_FILE"
  elif [[ -f "$PREFIX_BOOTSTRAP_FILE" ]]; then
    warn "Full config not created yet: $CONFIG_FILE"
    echo "Bootstrap command prefix:"
    sed -n '1,40p' "$PREFIX_BOOTSTRAP_FILE"
  else
    warn "No config: $CONFIG_FILE"
  fi
}

render_template(){
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import os, sys
src,dst=sys.argv[1],sys.argv[2]
s=open(src).read()
for k,v in os.environ.items():
    s=s.replace('{{'+k+'}}', v)
open(dst,'w').write(s)
PY
}
export_vars(){
  export PROFILE SERVER_PREFIX ROOT_DOMAIN WWW_DOMAIN PRIMARY_DOMAIN SYNC_DOMAIN WEB_CERT_NAME CERT_EMAIL PANEL_PATH XUI_PANEL_PORT XUI_AUTO_SETUP XUI_ADMIN_USER XUI_INSTALLED_TAG XRAY_PUBLIC_PORT XRAY_LOCAL_PORT SSH_PUBLIC_PORT HTTP_PUBLIC_PORT SITE_BACKEND_PORT SYNC_BACKEND_PORT MTPROTO_PORT MTPROTO_BACKEND ALLOW_IPV6_443 BASIC_USER MTPROTO_REPO_URL MTPROTO_REPO_BRANCH TELEGRAM_RELAY_PATH TELEGRAM_RELAY_SOCKET XPAM_DNS_POLICY_MODE XPAM_OUTPUT_MODE XPAM_MAINT_APT_MODE XPAM_SERVICE_HYGIENE_MODE XPAM_BACKUP_KEEP XPAM_HEALTH_LOG_KEEP XPAM_WEEKLY_LOG_KEEP XPAM_PROVIDER_NETWORKING_WARN_ONLY
  export WEB_SERVER_NAMES="$(web_domains)" CERTONLY_SERVER_NAMES="$(web_domains)${SYNC_DOMAIN:+ $SYNC_DOMAIN}" SERVICE_SITE_DIR="$(service_site_dir)" ROOT_SITE_DIR="$(root_site_dir)" SERVER_PREFIX_UP="$(printf '%s' "$SERVER_PREFIX" | tr '[:lower:]' '[:upper:]')"
  if uses_mtproto && mtproto_backend_is_3xui_mtg; then
    export HAPROXY_BACKEND_ORDER_UNITS="network-online.target nginx.service x-ui.service"
  else
    export HAPROXY_BACKEND_ORDER_UNITS="network-online.target nginx.service x-ui.service mtprotoproxy.service"
  fi
  if [[ "$PROFILE" == "root_mtproto" ]]; then
    ROOT_SITE_BLOCK="$(cat <<EOF_ROOT_SITE_BLOCK
server {
    listen 127.0.0.1:${SITE_BACKEND_PORT};
    server_name ${WWW_DOMAIN};
    return 301 https://${ROOT_DOMAIN}\$request_uri;
}
server {
    listen 127.0.0.1:${SITE_BACKEND_PORT};
    server_name ${ROOT_DOMAIN};
    root $(root_site_dir);
    index index.html;
    server_tokens off;
    charset utf-8;
    autoindex off;
    gzip on;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_vary on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer-when-downgrade always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    add_header X-Permitted-Cross-Domain-Policies none always;
    access_log /var/log/nginx/${ROOT_DOMAIN}.access.log;
    error_log /var/log/nginx/${ROOT_DOMAIN}.error.log;
    etag on;
    if_modified_since exact;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|webp|woff2?)\$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800" always;
        access_log off;
    }
    location @same_domain_root { return 302 https://\$host/; }
    location = /login { try_files /login.html @same_domain_root; add_header Cache-Control "no-store" always; }
    location = /docs { try_files /docs.html @same_domain_root; add_header Cache-Control "no-store" always; }
    location = /favicon.ico { try_files /favicon.ico =204; log_not_found off; access_log off; }
    location / { add_header Cache-Control "no-cache" always; try_files \$uri \$uri/ =404; }
    error_page 404 /404.html;
}
EOF_ROOT_SITE_BLOCK
)"
    export ROOT_SITE_BLOCK
  else
    export ROOT_SITE_BLOCK=""
  fi
  if [[ "$ALLOW_IPV6_443" == "yes" ]]; then export HAPROXY_IPV6_BIND="    bind [::]:${XRAY_PUBLIC_PORT} v6only"; else export HAPROXY_IPV6_BIND=""; fi
  if uses_mtproto; then
    if mtproto_backend_is_3xui_mtg; then
      export MTPROTO_HEALTH_BLOCK=$'check_active haproxy
haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 && echo "OK: haproxy config" || warn_fail "haproxy config failed"
check_http "'"$SYNC_DOMAIN"$'/health" 200 "https://'"$SYNC_DOMAIN"$'/health"
check_http "'"$SYNC_DOMAIN"$'/v1" 401 "https://'"$SYNC_DOMAIN"$'/v1"'
      export MTPROTO_WEEKLY_BLOCK=$'haproxy -c -f /etc/haproxy/haproxy.cfg || warn_fail "haproxy config check failed"
/usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$SYNC_BACKEND_PORT" 45 nginx-sync-backend || warn_fail "nginx sync backend port not reachable before HAProxy restart"
/usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XRAY_LOCAL_PORT" 45 xray-vless || warn_fail "xray local VLESS port not reachable before HAProxy restart"
/usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$MTPROTO_PORT" 60 3xui-mtg-backend || warn_fail "3xui-mtg backend port not reachable before HAProxy restart"
systemctl restart haproxy || warn_fail "haproxy restart failed"
if systemctl is-active --quiet haproxy; then
  sleep 5
  if [ -n "${SYNC_DOMAIN:-}" ]; then
    code="$(curl -4sk --connect-timeout 5 --max-time 15 -o /dev/null -w "%{http_code}" "https://${SYNC_DOMAIN}/health" 2>/dev/null || true)"
    [ "$code" = "200" ] || warn_fail "${SYNC_DOMAIN}/health expected 200 after HAProxy restart got ${code:-000}"
    code="$(curl -4sk --connect-timeout 5 --max-time 15 -o /dev/null -w "%{http_code}" "https://${SYNC_DOMAIN}/v1" 2>/dev/null || true)"
    [ "$code" = "401" ] || warn_fail "${SYNC_DOMAIN}/v1 expected 401 after HAProxy restart got ${code:-000}"
  fi
fi'
    else
      export MTPROTO_HEALTH_BLOCK=$'check_active haproxy
check_active mtprotoproxy
haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 && echo "OK: haproxy config" || warn_fail "haproxy config failed"
check_http "'"$SYNC_DOMAIN"$'/health" 200 "https://'"$SYNC_DOMAIN"$'/health"
check_http "'"$SYNC_DOMAIN"$'/v1" 401 "https://'"$SYNC_DOMAIN"$'/v1"'
      export MTPROTO_WEEKLY_BLOCK=$'haproxy -c -f /etc/haproxy/haproxy.cfg || warn_fail "haproxy config check failed"
/usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$SYNC_BACKEND_PORT" 45 nginx-sync-backend || warn_fail "nginx sync backend port not reachable before HAProxy restart"
/usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XRAY_LOCAL_PORT" 45 xray-vless || warn_fail "xray local VLESS port not reachable before HAProxy restart"
if ! systemctl restart mtprotoproxy; then
  warn_fail "mtprotoproxy restart failed"
else
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$MTPROTO_PORT" 60 mtproto-backend || warn_fail "mtprotoproxy backend port not reachable before HAProxy restart"
fi
systemctl restart haproxy || warn_fail "haproxy restart failed"
if systemctl is-active --quiet haproxy; then
  sleep 5
  if [ -n "${SYNC_DOMAIN:-}" ]; then
    code="$(curl -4sk --connect-timeout 5 --max-time 15 -o /dev/null -w "%{http_code}" "https://${SYNC_DOMAIN}/health" 2>/dev/null || true)"
    [ "$code" = "200" ] || warn_fail "${SYNC_DOMAIN}/health expected 200 after HAProxy restart got ${code:-000}"
    code="$(curl -4sk --connect-timeout 5 --max-time 15 -o /dev/null -w "%{http_code}" "https://${SYNC_DOMAIN}/v1" 2>/dev/null || true)"
    [ "$code" = "401" ] || warn_fail "${SYNC_DOMAIN}/v1 expected 401 after HAProxy restart got ${code:-000}"
  fi
fi'
    fi
  else
    export MTPROTO_HEALTH_BLOCK=""
    export MTPROTO_WEEKLY_BLOCK=""
  fi
  if [[ "$PROFILE" == "root_mtproto" ]]; then
    export ROOT_HEALTH_BLOCK=$'check_http "'"$ROOT_DOMAIN"$'/" 200 "https://'"$ROOT_DOMAIN"$'/"
check_redirect "'"$WWW_DOMAIN"$' -> '"$ROOT_DOMAIN"$'" "https://'"$WWW_DOMAIN"$'/" "https://'"$ROOT_DOMAIN"$'/"'
  else
    export ROOT_HEALTH_BLOCK=""
  fi
}

ssh_effective_config(){
  sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true
}

show_ssh_effective_summary(){
  local eff="$1"
  echo "$eff" | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin|permitemptypasswords|gssapiauthentication|maxauthtries|usedns|x11forwarding|allowtcpforwarding) ' || true
}

verify_authorized_keys_present(){
  [[ -d /root/.ssh ]] || fail "/root/.ssh is missing. Add the public SSH key first."
  [[ -s /root/.ssh/authorized_keys ]] || fail "/root/.ssh/authorized_keys is missing/empty. Add the public SSH key first."
  chmod 700 /root/.ssh 2>/dev/null || true
  chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
  if ! grep -Eq '^[[:space:]]*(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)[[:space:]]+' /root/.ssh/authorized_keys; then
    fail "/root/.ssh/authorized_keys does not contain a valid OpenSSH public key line"
  fi
}

verify_ssh_preflight(){
  say "Verifying SSH key-only effective policy"
  verify_authorized_keys_present
  sshd -t || fail "sshd config test failed"

  local eff prl
  eff="$(ssh_effective_config)"
  show_ssh_effective_summary "$eff"

  # Debian and Ubuntu/OpenSSH may format `sshd -T` output slightly differently.
  # Compare parsed fields instead of relying on a strict full-line grep.
  ssh_eff_value(){
    local key="$1"
    printf '%s\n' "$eff" | awk -v k="$key" 'tolower($1)==tolower(k) {print tolower($2); exit}'
  }

  ssh_eff_expect(){
    local key="$1" expected="$2" message="$3" actual
    actual="$(ssh_eff_value "$key")"
    [[ "$actual" == "$expected" ]] || fail "$message (actual: ${actual:-missing})"
  }

  ssh_eff_expect passwordauthentication no "PasswordAuthentication is not disabled. Run menu item 0: SSH hardening, after testing key login in a separate session."
  ssh_eff_expect kbdinteractiveauthentication no "KbdInteractiveAuthentication is not disabled. Run menu item 0 first."
  ssh_eff_expect pubkeyauthentication yes "PubkeyAuthentication is not enabled. Fix SSH key auth first."
  ssh_eff_expect permitemptypasswords no "PermitEmptyPasswords must be no"
  ssh_eff_expect gssapiauthentication no "GSSAPIAuthentication must be no"
  ssh_eff_expect x11forwarding no "X11Forwarding must be no. Run menu item 0: SSH hardening."
  ssh_eff_expect allowtcpforwarding yes "AllowTcpForwarding must remain yes for SSH local tunnels to 3x-ui."

  prl="$(ssh_eff_value permitrootlogin)"
  case "$prl" in
    yes|prohibit-password|without-password) : ;;
    *) fail "PermitRootLogin effective value is unsafe or blocks root key login: ${prl:-missing}" ;;
  esac

  ok "SSH effective policy is key-only"
}

apply_ssh_ipv4_only_public_listener(){
  # XPAM Script is IPv4-first on the public network, but it must not disable
  # the system IPv6 stack because Xray/WARP/local software may still rely on it.
  # This function only binds OpenSSH public listeners to IPv4.
  mkdir -p /etc/ssh/sshd_config.d

  local ssh_key_only_conf="/etc/ssh/sshd_config.d/00-key-only.conf"
  if [[ -f "$ssh_key_only_conf" ]] && ! grep -q '^AddressFamily inet$' "$ssh_key_only_conf"; then
    cat >> "$ssh_key_only_conf" <<'SSH_IPV4_ONLY'

# XPAM IPv4-first public SSH policy.
# Do not disable IPv6 globally; only bind sshd public listener to IPv4.
AddressFamily inet
SSH_IPV4_ONLY
  fi

  if systemctl list-unit-files ssh.socket >/dev/null 2>&1 || [[ -f /usr/lib/systemd/system/ssh.socket || -f /lib/systemd/system/ssh.socket ]]; then
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat > /etc/systemd/system/ssh.socket.d/10-xpam-ipv4-only.conf <<'SSH_SOCKET_IPV4'
[Socket]
ListenStream=
ListenStream=0.0.0.0:22
SSH_SOCKET_IPV4
    systemctl daemon-reload || true
  fi
}

stage_ssh_hardening(){
  need_root
  require_os
  ensure_sudo_hostname_resolution
  say "SSH hardening: key-only login, no X11 forwarding, TCP tunnels allowed"
  echo
  verify_authorized_keys_present
  echo "Current authorized_keys:"
  sed -n '1,10p' /root/.ssh/authorized_keys | sed -E 's/(ssh-[^ ]+ [A-Za-z0-9+\/]{20}).*/\1... [truncated]/'
  echo
  warn "Перед продолжением откройте НОВУЮ отдельную SSH-сессию по private key / ppk."
  echo "Новая сессия должна войти под root без пароля. Текущую сессию пока не закрывайте."
  echo
  if ! confirm "Вы проверили вход по SSH-ключу в новой отдельной сессии?" no; then
    fail "SSH-безопасность отменена. Сначала проверьте вход по ключу в отдельной сессии."
  fi

  mkdir -p /etc/ssh/sshd_config.d
  # Use an early drop-in name intentionally. On Ubuntu cloud images,
  # /etc/ssh/sshd_config.d/50-cloud-init.conf may set PasswordAuthentication yes.
  # OpenSSH keeps the first obtained value for many global options, so a late
  # 99-key-only.conf can fail to override cloud-init. 00-key-only.conf wins.
  local ssh_key_only_conf="/etc/ssh/sshd_config.d/00-key-only.conf"
  backup_file "$ssh_key_only_conf"
  cat > "$ssh_key_only_conf" <<'SSHCONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
PermitEmptyPasswords no
GSSAPIAuthentication no
MaxAuthTries 3
UseDNS no
X11Forwarding no
AllowTcpForwarding yes
AddressFamily inet
SSHCONF
  chmod 644 "$ssh_key_only_conf"
  apply_ssh_ipv4_only_public_listener

  say "Testing sshd configuration"
  sshd -t || fail "sshd -t failed after writing $ssh_key_only_conf; backup is kept next to the file"

  say "Reloading SSH service"
  systemctl daemon-reload || true
  if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    systemctl restart ssh.socket || fail "could not restart ssh.socket"
  fi
  systemctl reload ssh || systemctl restart ssh || fail "could not reload/restart ssh service"

  say "Verifying effective SSH policy"
  verify_ssh_preflight
  ok "SSH password login is disabled; key-only root login remains allowed"

  echo
  echo "============================================================"
  echo "SSH hardening complete."
  echo

  ensure_prefix_bootstrap
  install_runtime_kit || true
  write_install_launcher || true

  echo "Команда меню создана: sudo ${SERVER_PREFIX}-xpam"
  echo
  echo "Не закрывайте рабочую SSH-сессию до завершения установки."
  echo
  if confirm "Продолжить установку XPAM сейчас?" yes; then
    stage_install_continue
  else
    echo "Позже выполните: sudo ${SERVER_PREFIX}-xpam"
  fi
}
sensitive_package_patterns(){
  cat <<'EOF'
linux-image*
linux-modules*
linux-headers*
linux-generic*
linux-virtual*
libc6
systemd
systemd-sysv
systemd-resolved
udev
libudev1
dbus
openssh-server
openssh-client
openssl
libssl*
initramfs-tools
grub*
shim-signed
cloud-init
EOF
}

sensitive_package_snapshot(){
  local out="$1" patterns=()
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] && patterns+=("$pattern")
  done < <(sensitive_package_patterns)
  dpkg-query -W -f='${binary:Package}\t${Version}\n' "${patterns[@]}" 2>/dev/null | sort -u > "$out" || true
}

current_boot_id(){
  cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

reboot_sensitive_marker_current(){
  [[ -s "$REBOOT_SENSITIVE_MARKER" ]] || return 1
  local marker_boot current_boot
  marker_boot="$(awk -F= '$1=="boot_id"{print $2; exit}' "$REBOOT_SENSITIVE_MARKER" 2>/dev/null || true)"
  current_boot="$(current_boot_id)"
  [[ -z "$marker_boot" || -z "$current_boot" || "$marker_boot" == "$current_boot" ]]
}

clear_stale_reboot_sensitive_marker(){
  [[ -s "$REBOOT_SENSITIVE_MARKER" ]] || return 0
  local marker_boot current_boot
  marker_boot="$(awk -F= '$1=="boot_id"{print $2; exit}' "$REBOOT_SENSITIVE_MARKER" 2>/dev/null || true)"
  current_boot="$(current_boot_id)"
  if [[ -n "$marker_boot" && -n "$current_boot" && "$marker_boot" != "$current_boot" ]]; then
    rm -f "$REBOOT_SENSITIVE_MARKER" 2>/dev/null || true
    ok "Previous sensitive package upgrade marker cleared after reboot"
  fi
}

record_sensitive_package_changes(){
  local context="$1" before="$2" after="$3" changes boot_id ts
  changes="$(awk 'NR==FNR { old[$1]=$2; next } ($1 in old) && old[$1] != $2 { print $1 "	" old[$1] " -> " $2 }' "$before" "$after" 2>/dev/null || true)"
  [[ -n "$changes" ]] || return 0
  mkdir -p "$XPAM_STATE_DIR"
  chmod 700 "$XPAM_STATE_DIR" 2>/dev/null || true
  boot_id="$(current_boot_id)"
  ts="$(date -Is)"
  {
    echo "boot_id=${boot_id}"
    echo "timestamp=${ts}"
    echo "context=${context}"
    echo "packages:"
    printf '%s\n' "$changes"
  } > "$REBOOT_SENSITIVE_MARKER"
  chmod 600 "$REBOOT_SENSITIVE_MARKER" 2>/dev/null || true
  warn "Sensitive packages changed during ${context}; reboot will be required before final setup."
  printf '%s\n' "$changes" | sed 's/^/  /'
}

track_sensitive_package_changes(){
  local context="$1" before after rc
  shift
  before="$(mktemp /tmp/xpam-sensitive-before.XXXXXX)"
  after="$(mktemp /tmp/xpam-sensitive-after.XXXXXX)"
  sensitive_package_snapshot "$before"
  set +e
  "$@"
  rc=$?
  set -e
  sensitive_package_snapshot "$after"
  record_sensitive_package_changes "$context" "$before" "$after" || true
  rm -f "$before" "$after"
  return "$rc"
}

preinstall_marker_file(){ echo "/var/lib/xpam-script/preinstall-apt-ok"; }

preinstall_marker_valid(){
  local marker boot_id now marker_ts marker_boot_id marker_os_id marker_os_version current_os_id current_os_version
  marker="$(preinstall_marker_file)"
  [[ -s "$marker" ]] || return 1
  boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  [[ -n "$boot_id" ]] || return 1
  # Do not trust a cached apt marker if dpkg currently reports unfinished work.
  if dpkg --audit 2>/dev/null | grep -q .; then return 1; fi
  now="$(date +%s)"
  marker_ts="$(awk -F= '$1=="XPAM_PREINSTALL_APT_TS" {print $2}' "$marker" 2>/dev/null | tail -n1)"
  marker_boot_id="$(awk -F= '$1=="XPAM_PREINSTALL_APT_BOOT_ID" {print $2}' "$marker" 2>/dev/null | tail -n1)"
  marker_os_id="$(awk -F= '$1=="XPAM_PREINSTALL_APT_OS_ID" {print $2}' "$marker" 2>/dev/null | tail -n1)"
  marker_os_version="$(awk -F= '$1=="XPAM_PREINSTALL_APT_OS_VERSION_ID" {print $2}' "$marker" 2>/dev/null | tail -n1)"
  # shellcheck disable=SC1091
  . /etc/os-release
  current_os_id="${ID:-}"
  current_os_version="${VERSION_ID:-}"
  [[ "$marker_boot_id" == "$boot_id" ]] || return 1
  [[ "$marker_os_id" == "$current_os_id" ]] || return 1
  [[ "$marker_os_version" == "$current_os_version" ]] || return 1
  [[ "$marker_ts" =~ ^[0-9]+$ ]] || return 1
  (( now - marker_ts <= 21600 )) || return 1
  return 0
}

preinstall_marker_write(){
  local marker dir boot_id os_id os_version
  marker="$(preinstall_marker_file)"
  dir="$(dirname "$marker")"
  boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_version="${VERSION_ID:-}"
  mkdir -p "$dir"
  cat > "$marker" <<EOF_APT_MARKER
XPAM_PREINSTALL_APT_TS=$(date +%s)
XPAM_PREINSTALL_APT_BOOT_ID=$boot_id
XPAM_PREINSTALL_APT_OS_ID=$os_id
XPAM_PREINSTALL_APT_OS_VERSION_ID=$os_version
EOF_APT_MARKER
  chmod 600 "$marker" 2>/dev/null || true
}

preinstall_system_update(){
  say "Updating repositories and upgrading existing packages before installation"
  apt_dpkg_recovery "preinstall"
  if preinstall_marker_valid; then
    ok "Pre-install apt full-upgrade already passed in this boot; skipping repeated full-upgrade"
    return 0
  fi
  write_common_library
  # shellcheck source=/usr/local/sbin/xpam-maint-common.sh
  . /usr/local/sbin/xpam-maint-common.sh
  xpam_release_upgrade_guard || warn "release-upgrade guard returned non-zero"
  track_sensitive_package_changes "preinstall full-upgrade" xpam_guarded_full_upgrade "preinstall" || fail "Pre-install apt full-upgrade failed"
  preinstall_marker_write || true
}
install_base_packages_inner(){
  apt_get_safe "apt update before base packages" update &&
  apt_get_safe "base package install" install -y --no-install-recommends ca-certificates curl wget gnupg lsb-release unzip tar gzip cron ufw fail2ban python3-systemd nginx certbot openssl python3 python3-venv xxd systemd-sysv rsync sqlite3 jq dnsutils openssh-client iproute2
}
install_base_packages(){
  say "Installing base packages"
  apt_dpkg_recovery "base packages"
  track_sensitive_package_changes "base package install" install_base_packages_inner || fail "Base package install failed"
  systemctl enable --now certbot.timer 2>/dev/null || true
}

install_mtproto_haproxy_packages(){
  if uses_mtproto; then
    say "Installing HAProxy/MTProto dependencies"
    apt_dpkg_recovery "HAProxy/MTProto package install"
    apt_get_safe "apt update before HAProxy/MTProto packages" update
    if mtproto_backend_is_alexbers; then
      apt_get_safe "HAProxy/alexbers MTProto package install" install -y haproxy git python3-cryptography
    else
      apt_get_safe "HAProxy package install for 3xui-mtg" install -y haproxy
    fi
  fi
}

server_public_ipv4(){
  local ip
  # Prefer local routing information. This works even when DNS/HTTP is broken.
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  ip="$(ip -4 addr show scope global 2>/dev/null | awk '/ inet /{sub(/\/.*/,"",$2); print $2; exit}' || true)"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 5 ifconfig.me 2>/dev/null || true
}

normalize_hosts_public_ipv4_line(){
  local ip4 domains hn short
  ip4="${1:-}"
  shift || true
  domains="$*"
  [[ -n "$ip4" ]] || return 0

  hn="$(hostname 2>/dev/null | tr -d '[:space:]' || true)"
  short="${hn%%.*}"

  SERVER_IPV4="$ip4" XPAM_HOSTNAME="$hn" XPAM_SHORT_HOSTNAME="$short" XPAM_HOSTS_DOMAINS="$domains" python3 - <<'PYHOSTNORM'
from pathlib import Path
import os, shutil, datetime, re

hosts_path = Path('/etc/hosts')
ip = os.environ.get('SERVER_IPV4', '').strip()
hn = os.environ.get('XPAM_HOSTNAME', '').strip()
short = os.environ.get('XPAM_SHORT_HOSTNAME', '').strip()
domains = [d.strip() for d in os.environ.get('XPAM_HOSTS_DOMAINS', '').split() if d.strip()]

if not ip:
    raise SystemExit(0)

local_names = {'localhost', 'localhost.localdomain', 'ip6-localhost', 'ip6-loopback', 'ip6-localnet', 'ip6-mcastprefix', 'ip6-allnodes', 'ip6-allrouters', 'ip6-allhosts'}

wanted = []
def add(name):
    name = (name or '').strip()
    if not name or name in local_names:
        return
    if name not in wanted:
        wanted.append(name)

original_text = hosts_path.read_text() if hosts_path.exists() else ''
lines = original_text.splitlines()
out = []
public_names = []
placeholder = '__XPAM_PUBLIC_IPV4_LINE__'
inserted_placeholder = False

def add_public_name(name):
    name = (name or '').strip()
    if not name or name in local_names:
        return
    if name not in public_names:
        public_names.append(name)

for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        out.append(line)
        continue

    parts = stripped.split()
    addr, names = parts[0], parts[1:]

    if addr == ip:
        if not inserted_placeholder:
            out.append(placeholder)
            inserted_placeholder = True
        for name in names:
            add_public_name(name)
        continue

    out.append(line)

for name in public_names:
    add(name)
for name in domains:
    add(name)
if hn and hn not in ('localhost', 'localhost.localdomain'):
    add(hn)
if short and short != hn and short not in ('localhost', 'localhost.localdomain'):
    add(short)

cleaned = []
remove_from_local = set(wanted)
for line in out:
    if line == placeholder:
        continue
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        cleaned.append(line)
        continue
    parts = stripped.split()
    addr, names = parts[0], parts[1:]
    if addr.startswith('127.') or addr == '::1':
        kept = [n for n in names if n not in remove_from_local]
        # Keep loopback lines only if they still have names after removing public names.
        if kept:
            cleaned.append(addr + '\t' + ' '.join(kept))
        continue
    cleaned.append(line)

public_line = ip + '\t' + ' '.join(wanted) if wanted else ''
if public_line:
    if inserted_placeholder:
        final = []
        placed = False
        for line in out:
            if line == placeholder:
                if not placed:
                    final.append(public_line)
                    placed = True
                continue
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                final.append(line)
                continue
            parts = stripped.split()
            addr, names = parts[0], parts[1:]
            if addr.startswith('127.') or addr == '::1':
                kept = [n for n in names if n not in remove_from_local]
                if kept:
                    final.append(addr + '\t' + ' '.join(kept))
                continue
            final.append(line)
        cleaned = final
    else:
        cleaned.append(public_line)

new_text = '\n'.join(cleaned).rstrip() + '\n'
if new_text != original_text:
    backup_dir = Path('/root/manual-backups/hosts')
    backup_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    backup_path = backup_dir / f'hosts.before-xpam-normalize.{ts}'
    if hosts_path.exists():
        shutil.copy2(hosts_path, backup_path)
    hosts_path.write_text(new_text)
    print(f'OK: /etc/hosts normalized for {ip}: {" ".join(wanted)}')
PYHOSTNORM
}

ensure_sudo_hostname_resolution(){
  local hn short ip4
  hn="$(hostname 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$hn" ]] || return 0
  case "$hn" in
    localhost|localhost.localdomain) return 0 ;;
  esac

  ip4="$(server_public_ipv4)"
  short="${hn%%.*}"

  if [[ -n "$ip4" ]]; then
    normalize_hosts_public_ipv4_line "$ip4" "$hn" "$short"
    if getent hosts "$hn" >/dev/null 2>&1; then
      return 0
    fi
    warn "Hostname ${hn} still does not resolve locally after /etc/hosts normalization"
    return 0
  fi

  if getent hosts "$hn" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$hn" != *.* ]]; then
    if ! awk -v hn="$hn" '$1=="127.0.1.1" {for(i=2;i<=NF;i++) if($i==hn) found=1} END{exit found?0:1}' /etc/hosts 2>/dev/null; then
      cp -a /etc/hosts "/root/manual-backups/hosts/hosts.before-1270011-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
      printf '127.0.1.1\t%s\n' "$hn" >> /etc/hosts
      ok "Hostname for sudo resolved locally: ${hn} -> 127.0.1.1"
    fi
  else
    warn "Hostname ${hn} does not resolve locally and server IPv4 was not detected; sudo may warn about hostname resolution"
  fi
}


managed_domains(){ unique_domains $(web_domains) ${SYNC_DOMAIN:-}; }

fix_managed_hosts(){
  say "Ensuring managed domains do not resolve to localhost in /etc/hosts"
  local ip4 domains hn short
  ip4="$(server_public_ipv4)"
  domains="$(managed_domains)"
  hn="$(hostname 2>/dev/null | tr -d '[:space:]' || true)"
  short="${hn%%.*}"
  echo "Server IPv4 detected: ${ip4:-unknown}"
  [[ -n "$ip4" ]] || { warn "Could not detect public IPv4; /etc/hosts managed-domain fix skipped"; return 0; }
  [[ -n "$domains" ]] || return 0

  normalize_hosts_public_ipv4_line "$ip4" $domains "$hn" "$short"
  ok "Managed domains mapped in /etc/hosts to ${ip4}: ${domains}"
}


check_dns_preflight(){
  say "DNS preflight"
  local ip4 d answers aaaa localv4
  ip4="$(server_public_ipv4)"
  echo "Server IPv4 detected: ${ip4:-unknown}"
  for d in $(managed_domains); do
    [[ -n "$d" ]] || continue
    localv4="$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    if [[ -n "$localv4" ]]; then
      echo "Local resolver $d -> $localv4"
    else
      warn "Локальный DNS пока не вернул IPv4 для $d. Проверьте A-запись домена, если выпуск сертификата не пройдёт."
    fi

    answers="$(timeout 5s dig +short A "$d" @1.1.1.1 2>/dev/null | tr '\n' ' ' || true)"
    if [[ -n "$answers" ]]; then
      echo "Public DNS A $d -> $answers"
      [[ -n "$ip4" && "$answers" != *"$ip4"* ]] && warn "A record for $d does not appear to point to this server IPv4"
    else
      warn "Прямая проверка public DNS для $d не дала A-ответа; продолжаю, основная проверка идёт через системный resolver"
    fi

    aaaa="$(timeout 5s dig +short AAAA "$d" @1.1.1.1 2>/dev/null | tr '\n' ' ' || true)"
    echo "Public DNS AAAA $d -> ${aaaa:-none}"
    [[ -n "$aaaa" && "$ALLOW_IPV6_443" != "yes" ]] && warn "$d has AAAA records. XPAM Script is IPv4-first and does not support public IPv6 installation. Remove AAAA records for XPAM domains before running the installer."
  done
  return 0
}
setup_ufw(){ say "Configuring UFW"; ufw --force reset; ufw default deny incoming; ufw default allow outgoing; ufw allow from 0.0.0.0/0 to any port "$SSH_PUBLIC_PORT" proto tcp; ufw allow from 0.0.0.0/0 to any port "$HTTP_PUBLIC_PORT" proto tcp; ufw allow from 0.0.0.0/0 to any port "$XRAY_PUBLIC_PORT" proto tcp; [[ "$ALLOW_IPV6_443" == "yes" ]] && ufw allow from ::/0 to any port "$XRAY_PUBLIC_PORT" proto tcp || true; ufw --force enable; ufw status verbose; }
setup_fail2ban_ssh(){
  say "Configuring fail2ban"
  mkdir -p /etc/fail2ban/jail.d

  cat > /etc/fail2ban/fail2ban.local <<'F2B_DEF'
[Definition]
allowipv6 = no
F2B_DEF

  cat > /etc/fail2ban/jail.d/00-xpam-defaults.local <<'F2B_DEFAULTS'
[DEFAULT]
backend = systemd
F2B_DEFAULTS

  cat > /etc/fail2ban/jail.d/sshd.local <<'JAIL'
[sshd]
enabled = true
backend = systemd
maxretry = 3
findtime = 10m
bantime = 1h
JAIL

  fail2ban-client -t || fail "fail2ban configuration test failed"
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban || fail "fail2ban service restart failed"

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if fail2ban-client ping >/dev/null 2>&1; then
      ok "fail2ban is running"
      return 0
    fi
    sleep 1
  done
  systemctl status fail2ban --no-pager -l || true
  fail "fail2ban did not become ready after restart"
}

render_tree(){ local dir="$1" site_domain="$2" root_domain="$3" sync_domain="$4"; find "$dir" -type f \( -name '*.html' -o -name '*.css' -o -name '*.js' -o -name '*.txt' \) -print0 2>/dev/null | while IFS= read -r -d '' f; do sed -i -e "s#__SITE_DOMAIN__#${site_domain}#g" -e "s#__ROOT_DOMAIN__#${root_domain}#g" -e "s#__SYNC_DOMAIN__#${sync_domain}#g" "$f"; done; }
copy_site(){ local src="$1" dst="$2" domain="$3" rootd="$4" syncd="$5"; mkdir -p "$dst"; rsync -a --delete "$src"/ "$dst"/ 2>/dev/null || { rm -rf "$dst"; mkdir -p "$dst"; cp -a "$src"/. "$dst"/; }; render_tree "$dst" "$domain" "$rootd" "$syncd"; chown -R www-data:www-data "$dst" || true; }
setup_sites(){
  say "Preparing domain-named web roots"

  mkdir -p /var/www/letsencrypt
  chmod 755 /var/www /var/www/letsencrypt
  rm -rf /var/www/html 2>/dev/null || true

  install_site_template(){
    local src="$1"
    local dst="$2"
    local label="$3"

    mkdir -p "$dst"

    if [ ! -e "$dst/index.html" ] && [ -d "$src" ]; then
      rsync -a --ignore-existing "$src"/ "$dst"/
      ok "Default masked site installed for ${label}: ${dst}"
    else
      ok "Keeping existing/custom site for ${label}: ${dst}"
    fi

    chown -R www-data:www-data "$dst" 2>/dev/null || true
    find "$dst" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$dst" -type f -exec chmod 644 {} \; 2>/dev/null || true
  }

  if [[ "$PROFILE" == "vless_direct" ]]; then
    install_site_template "$KIT_DIR/sites/panel-vless-mask-site" "/var/www/${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN"
  else
    install_site_template "$KIT_DIR/sites/panel-vless-mask-site" "/var/www/${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN"
  fi

  if uses_mtproto; then
    if [[ "$PROFILE" == "root_mtproto" ]]; then
    install_site_template "$KIT_DIR/sites/mtproto-relay-mask-site" "/var/www/${SYNC_DOMAIN}" "$SYNC_DOMAIN"
  else
    install_site_template "$KIT_DIR/sites/mtproto-mask-site" "/var/www/${SYNC_DOMAIN}" "$SYNC_DOMAIN"
  fi
  fi

  if [[ "$PROFILE" == "root_mtproto" ]]; then
    install_site_template "$KIT_DIR/sites/root-mask-site" "/var/www/${ROOT_DOMAIN}" "$ROOT_DOMAIN"
  fi
}

ensure_htpasswd(){
  mkdir -p /root/secure-notes
  chmod 700 /root/secure-notes

  if [[ ! -f /etc/nginx/.htpasswd ]]; then
    local pass hash note
    ask BASIC_USER "Basic Auth username for protected panel path" "admin"
    read -r -s -p "Basic Auth password for protected panel path: " pass || true
    echo
    if [[ -z "$pass" ]]; then
      pass="change-me-now"
      warn "Basic Auth password is empty; using default temporary password. Change it after installation."
    fi
    hash="$(openssl passwd -apr1 "$pass")"
    printf '%s:%s\n' "$BASIC_USER" "$hash" > /etc/nginx/.htpasswd

    note="/root/secure-notes/${SERVER_PREFIX}-basic-auth.txt"
    cat > "$note" <<EOF_BASIC_AUTH
Basic Auth for protected 3x-ui panel path
=========================================
URL: https://${PRIMARY_DOMAIN}/${PANEL_PATH}/
Username: ${BASIC_USER}
Password: ${pass}
EOF_BASIC_AUTH
    chmod 600 "$note"
    ok "Basic Auth credentials stored in $note"
  fi

  chown root:www-data /etc/nginx/.htpasswd
  chmod 640 /etc/nginx/.htpasswd
}

write_wait_for_port(){ render_template "$KIT_DIR/templates/wait-for-local-port.sh.tpl" /usr/local/sbin/wait-for-local-port.sh; chmod +x /usr/local/sbin/wait-for-local-port.sh; }
write_common_library(){ render_template "$KIT_DIR/templates/xpam-maint-common.sh.tpl" /usr/local/sbin/xpam-maint-common.sh; chmod +x /usr/local/sbin/xpam-maint-common.sh; bash -n /usr/local/sbin/xpam-maint-common.sh; }
write_dns_policy_script(){ render_template "$KIT_DIR/templates/check-dns-policy.sh.tpl" /usr/local/sbin/check-dns-policy.sh; chmod +x /usr/local/sbin/check-dns-policy.sh; bash -n /usr/local/sbin/check-dns-policy.sh; }
write_network_tuning_policy_script(){ render_template "$KIT_DIR/templates/check-network-tuning-policy.sh.tpl" /usr/local/sbin/check-network-tuning-policy; chmod +x /usr/local/sbin/check-network-tuning-policy; bash -n /usr/local/sbin/check-network-tuning-policy; }
small_vm_resource_preflight(){
  local mem_kb mem_mb free_mb cpu_count active_swap_mb planned_swap_mb
  say "Проверка ресурсов маленькой VM"
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  mem_mb=$(( (mem_kb + 1023) / 1024 ))
  free_mb="$(df -Pm / | awk 'NR==2 {print $4+0}')"
  cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  active_swap_mb="$(swapon --show --bytes --noheadings 2>/dev/null | awk '{sum += $3} END {printf "%.0f", sum/1024/1024}' || echo 0)"

  if (( mem_mb <= 1024 || cpu_count <= 1 )); then
    warn "Обнаружена маленькая VM: RAM=${mem_mb} MB, CPU=${cpu_count}. XPAM включит щадящие проверки и retention-политику."
  else
    ok "Ресурсы VM: RAM=${mem_mb} MB, CPU=${cpu_count}"
  fi

  if (( active_swap_mb == 0 && mem_mb <= 1024 )); then
    planned_swap_mb=1024
    warn "Активный swap не найден. XPAM попробует создать /swapfile ${planned_swap_mb}M для безопасной установки."
  elif (( active_swap_mb > 0 )); then
    ok "Активный swap найден: ${active_swap_mb} MB"
  fi

  if (( free_mb < 1024 )); then
    warn "Очень мало свободного места на /: ${free_mb} MB. Установка может быть нестабильной; рекомендуется освободить место или увеличить диск."
  elif (( free_mb < 2048 )); then
    warn "Свободного места на / меньше 2 GB (${free_mb} MB). XPAM продолжит, но backup/apt операции могут требовать больше места."
  else
    ok "Свободное место на /: ${free_mb} MB"
  fi
}

ensure_swap_policy(){
  say "Checking swap policy"

  local mem_kb mem_mb size_mb free_mb swap_active=0
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  mem_mb=$(( (mem_kb + 1023) / 1024 ))

  # Always keep a conservative VM policy; it is harmless with or without active swap.
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/98-xpam-script-swap-policy.conf <<'EOF_SWAP_SYSCTL'
# XPAM Script swap policy
# Small emergency swap for apt/certbot/3x-ui operations; avoid aggressive swapping.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF_SWAP_SYSCTL
  sysctl -p /etc/sysctl.d/98-xpam-script-swap-policy.conf >/dev/null 2>&1 || warn "could not apply swap sysctl immediately"

  if swapon --show --noheadings 2>/dev/null | awk 'NF {found=1} END {exit found ? 0 : 1}'; then
    ok "swap is already active; no new swapfile needed"
    if [[ -e /swapfile ]] && [[ "$(blkid -p -o value -s TYPE /swapfile 2>/dev/null || true)" == "swap" ]]; then
      chmod 600 /swapfile || true
      cp -a /etc/fstab "/etc/fstab.bak-before-swap-normalize-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
      sed -i '/^[[:space:]]*\/swapfile[[:space:]]/d' /etc/fstab
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
      ok "swapfile fstab entry normalized"
    fi
    return 0
  fi

  free_mb="$(df -Pm / | awk 'NR==2 {print $4+0}')"
  if (( mem_mb <= 1024 )); then
    size_mb=1024
  elif (( mem_mb <= 4096 )); then
    size_mb=2048
  else
    warn "No active swap found, but RAM is ${mem_mb} MB (>4096 MB); not creating swap automatically"
    return 0
  fi

  if (( free_mb < size_mb + 512 )); then
    warn "No active swap found, but not enough free disk space to create ${size_mb}M /swapfile (free: ${free_mb}M)"
    return 0
  fi

  if [[ -e /swapfile ]]; then
    if [[ "$(blkid -p -o value -s TYPE /swapfile 2>/dev/null || true)" == "swap" ]]; then
      chmod 600 /swapfile || true
      swapon /swapfile || warn "existing /swapfile could not be enabled"
    else
      fail "/swapfile exists but is not a swap file; refusing to overwrite it"
    fi
  else
    say "Creating /swapfile (${size_mb}M)"
    if ! fallocate -l "${size_mb}M" /swapfile 2>/dev/null; then
      dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none || fail "failed to create /swapfile"
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null || fail "mkswap /swapfile failed"
    swapon /swapfile || fail "swapon /swapfile failed"
  fi

  cp -a /etc/fstab "/etc/fstab.bak-before-swap-normalize-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  sed -i '/^[[:space:]]*\/swapfile[[:space:]]/d' /etc/fstab
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "swapfile fstab entry normalized"

  swapon --show | grep -q '/swapfile' && ok "swapfile active: /swapfile (${size_mb}M)" || fail "swapfile was created but is not active"
}

apply_network_tuning_policy(){
  say "Applying network tuning policy: BBR + fq + balanced TCP/backlog profile"
  modprobe tcp_bbr || warn "tcp_bbr module could not be loaded now; policy will still be written and checked"
  mkdir -p /etc/modules-load.d /etc/sysctl.d
  cat > /etc/modules-load.d/tcp_bbr.conf <<'EOF_TUNING_MODULE'
tcp_bbr
EOF_TUNING_MODULE
  cat > /etc/sysctl.d/99-xpam-script-network-tuning.conf <<'EOF_TUNING_SYSCTL'
# XPAM Script network tuning
# Balanced profile: fast TCP proxying, low resource waste, stable WARP/HAProxy/Xray behavior.

# TCP congestion control + fq pacing
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP buffer ceilings: maximums, not permanent RAM allocation
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# Backlog for nginx / HAProxy / Xray under connection bursts
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 8192

# Better behavior on tunnels / imperfect paths
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0

# Basic SYN flood protection
net.ipv4.tcp_syncookies = 1

# Faster cleanup of dead TCP sockets
net.ipv4.tcp_fin_timeout = 15

# Keep modern Ubuntu/Debian default behavior
net.ipv4.tcp_tw_reuse = 2

# Wider outgoing ephemeral port range
net.ipv4.ip_local_port_range = 1024 65535
EOF_TUNING_SYSCTL
  sysctl --system
  sysctl -w net.ipv4.tcp_syncookies=1 >/dev/null 2>&1 || warn "could not apply runtime net.ipv4.tcp_syncookies=1; provider/kernel may override this setting"
  local dev
  dev="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
  if [[ -n "${dev:-}" ]] && ! tc qdisc show dev "$dev" 2>/dev/null | grep -q 'fq'; then
    tc qdisc replace dev "$dev" root fq || warn "could not apply fq qdisc immediately to $dev; reboot will apply default_qdisc=fq"
  fi
  write_network_tuning_policy_script
}
apply_service_nofile_limits(){
  say "Applying service LimitNOFILE=524288 where services are installed"
  local svc
  local -a svcs=(nginx x-ui haproxy)
  if uses_mtproto && mtproto_backend_is_alexbers; then
    svcs+=(mtprotoproxy)
  fi
  for svc in "${svcs[@]}"; do
    if systemctl cat "$svc.service" >/dev/null 2>&1; then
      mkdir -p "/etc/systemd/system/$svc.service.d"
      cat > "/etc/systemd/system/$svc.service.d/limits.conf" <<'EOF_NOFILE'
[Service]
LimitNOFILE=524288
EOF_NOFILE
      ok "LimitNOFILE configured for $svc"
    fi
  done
  systemctl daemon-reload
}
default_route_interface(){
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

suppress_provider_link_dns(){
  local dev network_file base dropin_dir changed=0 conn dns_after domains_after
  dev="$(default_route_interface || true)"
  [[ -n "$dev" ]] || { warn "Default-route interface not detected; provider link DNS suppression skipped"; return 0; }

  say "Suppressing provider/link DNS on default-route interface where safe: $dev"

  # systemd-networkd is the common backend for cloud-init/netplan VPS images.
  # Provider DNS may come from DHCP/RA OR from static netplan nameservers rendered
  # into /run/systemd/network/*.network as DNS=.  Use a drop-in for the active
  # .network file so we do not touch IP address, gateway, routes, SSH, or cloud-init.
  if systemctl is-active --quiet systemd-networkd; then
    network_file="$(networkctl status "$dev" --no-pager 2>/dev/null | awk '/Network File:/ {print $3; exit}' || true)"
    if [[ -n "$network_file" && -f "$network_file" ]]; then
      base="$(basename "$network_file")"
      dropin_dir="/etc/systemd/network/${base}.d"
      mkdir -p "$dropin_dir"
      cat > "$dropin_dir/90-xpam-script-no-provider-dns.conf" <<'EOF_DNS_DROPIN'
[Network]
DNS=
DNS=1.1.1.1
DNS=1.0.0.1
Domains=
Domains=~.

[DHCPv4]
UseDNS=false

[DHCP]
UseDNS=false

[IPv6AcceptRA]
UseDNS=false
EOF_DNS_DROPIN
      ok "provider/link DNS overridden via systemd-networkd drop-in: $dropin_dir/90-xpam-script-no-provider-dns.conf"
      changed=1
    else
      for network_file in /run/systemd/network/*.network /etc/systemd/network/*.network; do
        [[ -f "$network_file" ]] || continue
        if grep -Eq "^[[:space:]]*Name=([^[:space:]]+,)*${dev}([,[:space:]]|$)" "$network_file" || [[ "$(basename "$network_file")" == *"$dev"* ]]; then
          base="$(basename "$network_file")"
          dropin_dir="/etc/systemd/network/${base}.d"
          mkdir -p "$dropin_dir"
          cat > "$dropin_dir/90-xpam-script-no-provider-dns.conf" <<'EOF_DNS_DROPIN'
[Network]
DNS=
DNS=1.1.1.1
DNS=1.0.0.1
Domains=
Domains=~.

[DHCPv4]
UseDNS=false

[DHCP]
UseDNS=false

[IPv6AcceptRA]
UseDNS=false
EOF_DNS_DROPIN
          ok "provider/link DNS overridden via systemd-networkd drop-in: $dropin_dir/90-xpam-script-no-provider-dns.conf"
          changed=1
        fi
      done
    fi

    if (( changed == 1 )); then
      networkctl reload >/dev/null 2>&1 || true
      networkctl reconfigure "$dev" >/dev/null 2>&1 || warn "networkctl reconfigure $dev failed; DNS policy will still be enforced globally"
      systemctl restart systemd-resolved >/dev/null 2>&1 || true
      sleep 2
      dns_after="$(resolvectl dns "$dev" 2>/dev/null || true)"
      domains_after="$(resolvectl domain "$dev" 2>/dev/null || true)"
      if printf '%s\n' "$dns_after" | grep -Eq '1\.1\.1\.1.*1\.0\.0\.1' && printf '%s\n' "$domains_after" | grep -Fq '~.'; then
        ok "default-route link DNS now follows XPAM Script policy on $dev"
      else
        warn "default-route link DNS did not fully converge yet on $dev; health will report the effective DNS state"
      fi
      return 0
    fi
  fi

  # NetworkManager images are less common for minimal VPS servers, but handle them
  # where nmcli exposes a known connection.  This only changes DNS settings on the
  # default-route device connection and leaves IP/gateway untouched.
  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
    conn="$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1 || true)"
    if [[ -n "$conn" && "$conn" != "--" ]]; then
      nmcli connection modify "$conn" ipv4.ignore-auto-dns yes ipv4.dns "1.1.1.1 1.0.0.1" ipv6.ignore-auto-dns yes >/dev/null 2>&1 || warn "NetworkManager DNS override failed for $dev"
      nmcli connection up "$conn" >/dev/null 2>&1 || true
      systemctl restart systemd-resolved >/dev/null 2>&1 || true
      ok "provider/link DNS override attempted via NetworkManager connection: $conn"
      return 0
    fi
  fi

  if command -v netplan >/dev/null 2>&1 && find /etc/netplan -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | grep -q .; then
    warn "Netplan is present, but no safe backend-specific DNS override was identified for $dev. Leaving IP/gateway untouched; health will report effective DNS."
    return 0
  fi

  warn "Provider link DNS suppression skipped; unknown network manager. Global resolved DNS policy remains authoritative; health will report effective DNS."
  return 0
}

wait_for_resolved_global_dns_policy(){
  local i status dns_line domain_line

  for i in 1 2 3 4 5 6 7 8 9 10; do
    status="$(resolvectl status 2>/dev/null || true)"
    dns_line="$(printf '%s\n' "$status" | awk '/^[[:space:]]*DNS Servers[[:space:]]/ {print; exit}')"
    domain_line="$(printf '%s\n' "$status" | awk '/^[[:space:]]*DNS Domain[[:space:]]/ {print; exit}')"

    if printf '%s\n' "$dns_line" | grep -Eq '1\.1\.1\.1[[:space:]]+1\.0\.0\.1|1\.0\.0\.1[[:space:]]+1\.1\.1\.1' \
       && printf '%s\n' "$domain_line" | grep -Fq '~.'; then
      ok "systemd-resolved global DNS policy applied"
      return 0
    fi

    sleep 1
  done

  warn "systemd-resolved global DNS policy did not converge immediately; continuing to formal DNS check"
  return 0
}


dns_getent_ok(){
  local d
  for d in github.com letsencrypt.org api.telegram.org cloudflare.com; do
    getent ahostsv4 "$d" >/dev/null 2>&1 || return 1
  done
  return 0
}

raw_ipv4_network_ok(){
  # A valid route is enough for DNS rescue. Some VPS providers block ICMP,
  # so do not require ping to succeed before writing /etc/resolv.conf.
  ip route get 1.1.1.1 >/dev/null 2>&1 || return 1
  return 0
}

backup_resolv_conf_once(){
  mkdir -p /root/manual-backups/dns
  if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then
    cp -a /etc/resolv.conf "/root/manual-backups/dns/resolv.conf.before-xpam-dns-rescue.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  fi
}

write_static_dns_rescue(){
  backup_resolv_conf_once
  rm -f /etc/resolv.conf
  cat > /etc/resolv.conf <<'EOF_DNS_RESCUE'
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
options timeout:2 attempts:2 rotate
EOF_DNS_RESCUE
  chmod 644 /etc/resolv.conf 2>/dev/null || true
}

ensure_dns_safe_rescue_if_needed(){
  if dns_getent_ok; then
    ok "DNS работает; DNS провайдера не изменяем"
    return 0
  fi

  warn "DNS сейчас не работает через текущий системный resolver"
  if ! raw_ipv4_network_ok; then
    fail "DNS не работает, и прямой IPv4-доступ к интернету тоже не подтверждён. Проверьте сеть/VPS-провайдера."
  fi

  warn "IPv4-сеть работает, но DNS провайдера/resolver сломан. Включаю безопасный fallback DNS для установки."
  warn "IP, gateway, routes и /etc/network/interfaces не изменяются."

  # If systemd-resolved recently converted /etc/resolv.conf to a broken stub,
  # do not depend on resolvectl/DBus.  Static resolv.conf is the safest rescue.
  write_static_dns_rescue

  if dns_getent_ok; then
    ok "DNS восстановлен через безопасный fallback /etc/resolv.conf"
    return 0
  fi

  fail "DNS не работает даже после безопасного fallback /etc/resolv.conf"
}

setup_dns_policy(){
  local mode="${XPAM_DNS_POLICY_MODE:-safe}"
  # XPAM no longer replaces working provider DNS in the default installer path.
  # DNS management was deliberately reduced to: check -> rescue if broken.
  # No /etc/network/interfaces, route, gateway, NetworkManager or link-DNS changes are made here.
  say "Проверка DNS сервера (XPAM Auto: DNS не меняем, только проверяем)"
  write_dns_policy_script

  if [[ "$mode" != "safe" ]]; then
    warn "DNS replacement/strict mode отключён в XPAM Auto. Используется безопасная проверка DNS без замены провайдерских настроек."
    mode="safe"
  fi

  ensure_dns_safe_rescue_if_needed
  /usr/local/sbin/check-dns-policy.sh || fail "DNS-проверка не пройдена"
}
cleanup_legacy_nginx_files(){
  local f target ts backup_dir changed legacy_slug legacy_full_slug legacy_files
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_dir="/root/manual-backups/nginx-legacy-configs-disabled-${ts}"
  changed=0

  legacy_slug="$(printf '\144\145\160\154\157\171-\153\151\164')"
  legacy_full_slug="$(printf '\163\145\162\166\145\162-%s' "$legacy_slug")"

  legacy_files=(
    "/etc/nginx/sites-enabled/${legacy_slug}-final.conf"
    "/etc/nginx/sites-enabled/${legacy_slug}-certonly.conf"
    "/etc/nginx/conf.d/${legacy_slug}-final.conf"
    "/etc/nginx/conf.d/${legacy_slug}-certonly.conf"
    "/etc/nginx/sites-available/${legacy_slug}-final.conf"
    "/etc/nginx/sites-available/${legacy_slug}-certonly.conf"
    "/etc/nginx/snippets/${legacy_full_slug}-telegram-relay.conf"
  )

  for f in "${legacy_files[@]}"; do
    if [[ -e "$f" || -L "$f" ]]; then
      mkdir -p "$backup_dir"

      if [[ -L "$f" ]]; then
        target="$(readlink -f "$f" 2>/dev/null || true)"
        printf '%s -> %s
' "$f" "$target" >> "$backup_dir/legacy-links.txt"
        rm -f "$f"
      elif [[ -f "$f" ]]; then
        mv -f "$f" "$backup_dir/$(basename "$f").disabled"
      else
        rm -rf "$f"
      fi

      ok "Legacy nginx file disabled: $f"
      changed=1
    fi
  done

  if [[ "$changed" == "1" ]]; then
    ok "Legacy nginx files moved/recorded in: $backup_dir"
  fi
}


write_nginx_certonly(){ say "Writing certbot nginx config"; export_vars; cleanup_legacy_nginx_files; rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/xpam-script-final.conf /etc/nginx/sites-enabled/xpam-script-certonly.conf; render_template "$KIT_DIR/templates/nginx-certonly.conf.tpl" /etc/nginx/sites-available/xpam-script-certonly.conf; ln -sf /etc/nginx/sites-available/xpam-script-certonly.conf /etc/nginx/sites-enabled/xpam-script-certonly.conf; nginx -t; systemctl enable nginx; systemctl reload nginx || systemctl restart nginx; }
certbot_args(){ [[ -n "$CERT_EMAIL" ]] && echo "--email $CERT_EMAIL" || echo "--register-unsafely-without-email"; }
run_certbot_checked(){
  local label="$1" log rc retry_line
  shift
  log="$(mktemp /tmp/xpam-script-certbot.XXXXXX)"
  if run_with_heartbeat "Certbot: $label" certbot "$@" > >(tee "$log") 2>&1; then
    rm -f "$log"
    return 0
  fi
  rc=$?
  if grep -Eiq 'too many certificates|rate limit|retry after' "$log" 2>/dev/null; then
    retry_line="$(grep -Eio 'retry after [0-9TZ: -]+' "$log" | head -1 || true)"
    echo
    warn "Let's Encrypt temporarily refused a new certificate for this domain set. The server is not broken."
    [[ -n "$retry_line" ]] && warn "Retry time reported by Let's Encrypt: $retry_line"
    warn "Wait until the retry time, then run: sudo ${SERVER_PREFIX}-xpam and choose menu item 1."
    warn "For repeated tests, use fresh DNS names that point to this server."
  fi
  rm -f "$log"
  return "$rc"
}
issue_certs(){
  local domains_args="" d
  for d in $(web_domains); do domains_args="$domains_args -d $d"; done
  say "Issuing Web/VLESS cert-name '$(web_cert_name)' for: $(web_domains)"
  # shellcheck disable=SC2086
  run_certbot_checked "Web/VLESS $(web_cert_name)" certonly --webroot -w /var/www/letsencrypt $domains_args --cert-name "$(web_cert_name)" --keep-until-expiring --non-interactive --agree-tos $(certbot_args) || fail "Certbot failed for Web/VLESS certificate. See messages above."
  if uses_mtproto; then
    say "Issuing MTProto cert: $SYNC_DOMAIN"
    run_certbot_checked "MTProto $SYNC_DOMAIN" certonly --webroot -w /var/www/letsencrypt -d "$SYNC_DOMAIN" --cert-name "$SYNC_DOMAIN" --keep-until-expiring --non-interactive --agree-tos $(certbot_args) || fail "Certbot failed for MTProto certificate. See messages above."
  fi
}

web_cert_present(){
  local cert key
  cert="/etc/letsencrypt/live/$(web_cert_name)/fullchain.pem"
  key="/etc/letsencrypt/live/$(web_cert_name)/privkey.pem"
  [[ -s "$cert" && -s "$key" ]]
}

ensure_web_cert_for_xui(){
  local cert key
  cert="/etc/letsencrypt/live/$(web_cert_name)/fullchain.pem"
  key="/etc/letsencrypt/live/$(web_cert_name)/privkey.pem"

  if web_cert_present; then
    ok "Web/VLESS certificate is present for 3x-ui: $(web_cert_name)"
    return 0
  fi

  warn "Web/VLESS certificate is missing; issuing certificates before automatic 3x-ui setup."

  command -v nginx >/dev/null 2>&1 || install_base_packages
  command -v certbot >/dev/null 2>&1 || install_base_packages

  setup_sites
  write_nginx_certonly
  issue_certs
  write_certbot_hook

  web_cert_present || fail "Web/VLESS cert/key still missing after certbot: $cert / $key"
}

write_certbot_hook(){ say "Writing certbot renewal hook"; mkdir -p /etc/letsencrypt/renewal-hooks/deploy; cat > /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh <<EOF
#!/usr/bin/env bash
set -u
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LINEAGE="\${RENEWED_LINEAGE:-}"
reload_nginx(){ nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true; }
restart_xui(){ systemctl list-unit-files | grep -q '^x-ui.service' && systemctl restart x-ui >/dev/null 2>&1 || true; }
case "\$LINEAGE" in *"/$(web_cert_name)"*) restart_xui; reload_nginx ;; esac
EOF
if uses_mtproto; then cat >> /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh <<EOF
case "\$LINEAGE" in *"/${SYNC_DOMAIN}"*) reload_nginx ;; esac
EOF
fi; echo 'exit 0' >> /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh; chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh; }
write_manual_3xui_note(){
  mkdir -p /root/secure-notes
  chmod 700 /root/secure-notes
  local note="/root/secure-notes/${SERVER_PREFIX}-manual-3xui-setup.txt" xray_port xray_listen sniffing external_proxy_block proxy_protocol_note warp_block server_prefix_up
  server_prefix_up="$(printf '%s' "$SERVER_PREFIX" | tr '[:lower:]' '[:upper:]')"
  xray_port="$(expected_xray_port)"
  external_proxy_block="External Proxy: ENABLED\n  Force TLS: same / Тот же\n  Dest/Host: ${PRIMARY_DOMAIN}\n  Port: ${XRAY_PUBLIC_PORT}\n  Remark: ${server_prefix_up}-public-${XRAY_PUBLIC_PORT}\n  Purpose: generated VLESS links must always use ${PRIMARY_DOMAIN}:${XRAY_PUBLIC_PORT}, regardless of whether Xray listens directly on the public IPv4 address or behind HAProxy."
  if uses_haproxy; then
    xray_listen="127.0.0.1"
    sniffing="OFF by default. If you later enable WARP/domain routing inside 3x-ui/Xray, XPAM Script can switch sniffing to Route only for that routing use-case."
  else
    xray_listen="server public IPv4 address, for example 203.0.113.10"
    sniffing="ON: HTTP, TLS, QUIC; Route only ON. This is required only if you use Xray routing/WARP rules like selected-domain WARP routing."
  fi
  proxy_protocol_note="Proxy Protocol: OFF. Do not enable it unless HAProxy backend is also changed to send-proxy and health checks/nginx are adjusted.\nFallback PROXY/xVer: OFF / 0. Do not enable unless nginx fallback listens with proxy_protocol.\nFallback SNI/name: empty. Empty means catch-all fallback to the masked website; do not narrow it to one domain unless you intentionally maintain several fallback destinations.\nAuthentication: None / empty. Do not enable X25519/ML-KEM auth for this VLESS+TLS+fallback layout."
  warp_block="Direct profile optional WARP notes:\n  WARP is configured manually inside 3x-ui/Xray, not by XPAM Script.\n  Recommended outbound values: tag=warp, protocol=wireguard, MTU=1420, domainStrategy=ForceIPv4, workers=2, noKernelTun=false.\n  Use reserved from your WARP profile and peer keepAlive=25.\n  Peer allowedIPs should be IPv4-only: 0.0.0.0/0. Do not add ::/0.\n  Address should be IPv4-only, for example 172.16.0.2/32. Do not add Cloudflare IPv6 address 2606:.../128 on this IPv4-only public layout.\n  Endpoint is usually engage.cloudflareclient.com:2408, but follow your actual WARP profile if it differs.\n  Use routing rules for selected domains only; keep system DNS independent from wg0/WARP.\n  wg0 may be lazy/absent immediately after reboot; health treats that as acceptable when WireGuard outbound exists.\n  Never paste WARP private keys into XPAM Script files, notes, screenshots or support messages."
  cat > "$note" <<EOF
Manual 3x-ui setup for XPAM Script
=========================================================
VLESS/masking domain: ${PRIMARY_DOMAIN}
Panel URL after final setup: https://${PRIMARY_DOMAIN}/${PANEL_PATH}/
Web/VLESS cert: /etc/letsencrypt/live/$(web_cert_name)/fullchain.pem
Web/VLESS key:  /etc/letsencrypt/live/$(web_cert_name)/privkey.pem

Install 3x-ui manually:
  bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

During installer:
  panel port: ${XUI_PANEL_PORT}
  SSL setup: 4 = Skip SSL
  Do not issue certificates through 3x-ui/acme.sh; XPAM Script/certbot already manages them.

Initial panel access immediately after install:
  Use the random username, password and WebBasePath printed by the 3x-ui installer.
  Example: http://127.0.0.1:${XUI_PANEL_PORT}/RANDOM_PATH through your SSH local tunnel.
  /${PANEL_PATH}/ is NOT available yet. It becomes available only after you set webBasePath inside the panel.

Panel settings after install, before finalization:
  IMPORTANT: set webCertFile and webKeyFile immediately. Final nginx proxies the panel with HTTPS, so panel TLS is required even though it listens only on 127.0.0.1.
  webListen/IP: 127.0.0.1
  webPort: ${XUI_PANEL_PORT}
  webBasePath: /${PANEL_PATH}/
  webCertFile: /etc/letsencrypt/live/$(web_cert_name)/fullchain.pem
  webKeyFile: /etc/letsencrypt/live/$(web_cert_name)/privkey.pem
  subscription certificate/key: same cert/key if subscription TLS is enabled by your 3x-ui version.

VLESS inbound:
  listen/address: ${xray_listen}
  port: ${xray_port}
  protocol: VLESS
  transport/transmission: TCP/RAW
  security: TLS
  TLS min/max: 1.2 / 1.3
  uTLS/fingerprint: firefox
  ALPN: http/1.1
  cert/key: same as above
  decryption/encryption: none
  client flow: xtls-rprx-vision
  fallback destination: 127.0.0.1:${SITE_BACKEND_PORT}
  fallback ALPN: http/1.1
  sniffing: ${sniffing}

External Proxy / generated client links:
$(printf '%b' "$external_proxy_block")

Proxy protocol, fallback and authentication safety:
$(printf '%b' "$proxy_protocol_note")

$(printf '%b' "$warp_block")

Generated VLESS link sanity check:
  HAProxy mode must generate: vless://UUID@${PRIMARY_DOMAIN}:${XRAY_PUBLIC_PORT}?...
  direct mode must generate:     vless://UUID@${PRIMARY_DOMAIN}:${XRAY_PUBLIC_PORT}?...
  It must never generate 127.0.0.1:${XRAY_LOCAL_PORT} for HAProxy-mode clients after External Proxy is configured.

Then run the XPAM Script menu again and choose Install / continue server setup.
EOF
  chmod 600 "$note"
  ok "Manual 3x-ui checklist written: $note"
}


reboot_status_notice(){
  say "Reboot status"
  clear_stale_reboot_sensitive_marker
  local running newest
  running="$(uname -r 2>/dev/null || true)"
  newest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's#^/boot/vmlinuz-##' | sort -V | tail -1 || true)"
  if [[ -f /var/run/reboot-required ]]; then
    warn "Reboot is required by installed packages: /var/run/reboot-required exists"
    if [[ -s /var/run/reboot-required.pkgs ]]; then
      warn "Packages requesting reboot:"
      sed 's/^/  /' /var/run/reboot-required.pkgs || true
    fi
  else
    ok "No /var/run/reboot-required marker detected"
  fi
  if [[ -n "$newest" && -n "$running" && "$newest" != "$running" ]]; then
    warn "A newer installed kernel appears to be available: running=$running, newest=$newest. Reboot is required before final setup."
  elif [[ -n "$newest" && -n "$running" ]]; then
    ok "Running kernel matches newest installed kernel"
  fi
  if reboot_sensitive_marker_current; then
    warn "Sensitive package upgrade marker is present for this boot; reboot is required before final setup."
    awk 'BEGIN{show=0} /^packages:/{show=1; next} show{print "  " $0}' "$REBOOT_SENSITIVE_MARKER" 2>/dev/null || true
  else
    ok "No sensitive package upgrade marker for this boot"
  fi
  return 0
}

reboot_recommended_before_finalize(){
  clear_stale_reboot_sensitive_marker
  local running newest
  if [[ -f /var/run/reboot-required ]]; then
    return 0
  fi
  running="$(uname -r 2>/dev/null || true)"
  newest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's#^/boot/vmlinuz-##' | sort -V | tail -1 || true)"
  if [[ -n "$newest" && -n "$running" && "$newest" != "$running" ]]; then
    return 0
  fi
  reboot_sensitive_marker_current
}

reboot_gate_before_finalize(){
  if reboot_recommended_before_finalize; then
    reboot_status_notice || true
    echo
    warn "Финальную настройку нельзя продолжать до перезагрузки."
    echo "Выполните сейчас:"
    echo "  sudo reboot"
    echo
    echo "После перезагрузки войдите по SSH-ключу и выполните:"
    echo "  sudo ${SERVER_PREFIX}-xpam"
    return 1
  fi
  return 0
}

xui_latest_release_tag_any(){
  local tag json
  json="$(curl -4fsSL --connect-timeout 8 --max-time 20 https://api.github.com/repos/MHSanaei/3x-ui/releases 2>/dev/null || true)"
  tag="$(printf '%s' "$json" | jq -r '.[0].tag_name // empty' 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then
    warn "Could not query /releases; falling back to GitHub /releases/latest"
    json="$(curl -4fsSL --connect-timeout 8 --max-time 20 https://api.github.com/repos/MHSanaei/3x-ui/releases/latest 2>/dev/null || true)"
    tag="$(printf '%s' "$json" | jq -r '.tag_name // empty' 2>/dev/null || true)"
  fi
  [[ -n "$tag" ]] || fail "Could not detect latest 3x-ui tag from GitHub"
  printf '%s\n' "$tag"
}


xui_build_inbound_payload(){
  local payload="$1" uuid subid xray_port xray_listen cert key sniff_enabled sniff_route external_proxy_json client_name inbound_remark external_proxy_remark
  uuid="$(python3 - <<'PYUUID'
import uuid
print(uuid.uuid4())
PYUUID
)"
  subid="$(openssl rand -hex 8)"
  xray_port="$(expected_xray_port)"
  client_name="${SERVER_PREFIX}-vless-client"
  external_proxy_remark="${SERVER_PREFIX}-public-${XRAY_PUBLIC_PORT}"
  external_proxy_json='[{"forceTls":"same","dest":"'"${PRIMARY_DOMAIN}"'","port":'"${XRAY_PUBLIC_PORT}"',"remark":"'"${external_proxy_remark}"'"}]'

  if uses_haproxy; then
    xray_listen="127.0.0.1"
    sniff_enabled="false"
    sniff_route="false"
    inbound_remark="${SERVER_PREFIX}-vless"
  else
    xray_listen="$(server_public_ipv4)"
    [[ "$xray_listen" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "Could not detect public IPv4 for direct VLESS bind"
    sniff_enabled="true"
    sniff_route="true"
    inbound_remark="${SERVER_PREFIX}-vless"
  fi

  cert="/etc/letsencrypt/live/$(web_cert_name)/fullchain.pem"
  key="/etc/letsencrypt/live/$(web_cert_name)/privkey.pem"

  export XPAM_PAYLOAD_UUID="$uuid" XPAM_PAYLOAD_SUBID="$subid" XPAM_XRAY_PORT="$xray_port" XPAM_XRAY_LISTEN="$xray_listen" XPAM_CERT="$cert" XPAM_KEY="$key" XPAM_SNI="$PRIMARY_DOMAIN" XPAM_SITE_BACKEND_PORT="$SITE_BACKEND_PORT" XPAM_SNIFF_ENABLED="$sniff_enabled" XPAM_SNIFF_ROUTE="$sniff_route" XPAM_EXTERNAL_PROXY_JSON="$external_proxy_json" XPAM_SERVER_PREFIX="$SERVER_PREFIX" XPAM_CLIENT_NAME="$client_name" XPAM_INBOUND_REMARK="$inbound_remark"

  python3 - "$payload" <<'PYXUIPAYLOAD'
import json, os, sys

external_proxy=json.loads(os.environ["XPAM_EXTERNAL_PROXY_JSON"])
sniff_enabled = os.environ["XPAM_SNIFF_ENABLED"].lower() == "true"

settings={
  "clients":[{
    "id":os.environ["XPAM_PAYLOAD_UUID"],
    "flow":"xtls-rprx-vision",
    "email":os.environ["XPAM_CLIENT_NAME"],
    "limitIp":0,
    "totalGB":0,
    "expiryTime":0,
    "enable":True,
    "tgId":"",
    "subId":os.environ["XPAM_PAYLOAD_SUBID"],
    "reset":0
  }],
  "decryption":"none",
  "fallbacks":[{"name":"","alpn":"http/1.1","path":"","dest":f"127.0.0.1:{os.environ['XPAM_SITE_BACKEND_PORT']}","xver":0}]
}

stream={
  "network":"tcp",
  "security":"tls",
  "externalProxy":external_proxy,
  "tlsSettings":{
    "serverName":os.environ["XPAM_SNI"],
    "minVersion":"1.2",
    "maxVersion":"1.3",
    "cipherSuites":"",
    "certificates":[{"certificateFile":os.environ["XPAM_CERT"],"keyFile":os.environ["XPAM_KEY"],"ocspStapling":3600}],
    "alpn":["http/1.1"],
    "settings":{"allowInsecure":False,"fingerprint":"firefox"}
  },
  "tcpSettings":{"acceptProxyProtocol":False,"header":{"type":"none"}}
}

sniff={
  "enabled": sniff_enabled,
  "destOverride": ["http","tls","quic"] if sniff_enabled else [],
  "metadataOnly": False,
  "routeOnly": os.environ["XPAM_SNIFF_ROUTE"].lower() == "true"
}

payload={
  "up":0,
  "down":0,
  "total":0,
  "remark":os.environ["XPAM_INBOUND_REMARK"],
  "enable":True,
  "expiryTime":0,
  "listen":os.environ["XPAM_XRAY_LISTEN"],
  "port":int(os.environ["XPAM_XRAY_PORT"]),
  "protocol":"vless",
  "settings":json.dumps(settings,separators=(",",":")),
  "streamSettings":json.dumps(stream,separators=(",",":")),
  "tag":f"inbound-{os.environ['XPAM_XRAY_PORT']}",
  "sniffing":json.dumps(sniff,separators=(",",":")),
  "allocate":"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":3}"
}

with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)

print(os.environ["XPAM_PAYLOAD_UUID"])
print(os.environ["XPAM_PAYLOAD_SUBID"])
print(os.environ["XPAM_CLIENT_NAME"])
print(os.environ["XPAM_INBOUND_REMARK"])
PYXUIPAYLOAD
}

xui_api_token(){
  fail "3x-ui API token compatibility layer is not loaded. Expected: ${KIT_DIR}/scripts/lib/xpam-xui.sh"
}

xui_disable_subscription(){
  local db="/etc/x-ui/x-ui.db" backup_dir backup
  say "Disabling 3x-ui subscription server"
  xui_assert_sqlite_backend
  [[ -s "$db" ]] || fail "3x-ui DB missing: $db"

  backup_dir="/root/manual-backups/xui-subscription-disable"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  backup="${backup_dir}/x-ui.db.$(date +%Y%m%d-%H%M%S)"
  cp -a "$db" "$backup" 2>/dev/null || true
  chmod 600 "$backup" 2>/dev/null || true

  systemctl stop x-ui || true

  sqlite3 "$db" <<'SQL'
BEGIN;

UPDATE settings SET value='false'
WHERE key IN (
  'subEnable',
  'subJsonEnable',
  'subClashEnable',
  'subEncrypt',
  'subEnableRouting'
);

INSERT INTO settings (key, value)
SELECT 'subEnable', 'false'
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='subEnable');

INSERT INTO settings (key, value)
SELECT 'subJsonEnable', 'false'
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='subJsonEnable');

INSERT INTO settings (key, value)
SELECT 'subClashEnable', 'false'
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='subClashEnable');

DELETE FROM settings
WHERE key IN (
  'subCertFile',
  'subKeyFile',
  'subListen',
  'subPort',
  'subPath',
  'subDomain',
  'subURI',
  'subJsonPath',
  'subJsonURI',
  'subClashPath',
  'subClashURI',
  'subProfileUrl',
  'subSupportUrl',
  'subTitle',
  'subAnnounce',
  'subJsonFragment',
  'subJsonMux',
  'subJsonNoises',
  'subJsonRules',
  'subRoutingRules',
  'subUpdates'
);

COMMIT;
SQL

  systemctl start x-ui || fail "x-ui start failed after disabling subscription"
  sleep 4

  if ss -H -lntup 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]+[[:space:]]+.*:2096\b'; then
    journalctl -u x-ui --no-pager -n 80 | grep -Ei 'sub|subscription|2096|running|listen|error|fail' || true
    fail "3x-ui subscription listener :2096 is still present after disabling subscription"
  fi

  ok "3x-ui subscription listener is disabled"
}

xui_enforce_vless_inbound_policy(){
  local db="/etc/x-ui/x-ui.db" ip4 expected_port expected_listen expected_remark mode backup_dir backup
  expected_port="$(expected_xray_port)"
  if uses_haproxy; then
    mode="local"
    expected_listen="127.0.0.1"
    expected_remark="${SERVER_PREFIX}-vless"
  else
    mode="direct"
    ip4="$(server_public_ipv4)"
    [[ "$ip4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "Could not detect public IPv4 for direct VLESS bind"
    expected_listen="$ip4"
    expected_remark="${SERVER_PREFIX}-vless"
  fi
  [[ -s "$db" ]] || fail "3x-ui DB missing: $db"

  backup_dir="/root/manual-backups/xui-vless-policy"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  backup="${backup_dir}/x-ui.db.$(date +%Y%m%d-%H%M%S)"
  cp -a "$db" "$backup" || fail "Could not create 3x-ui DB backup before VLESS policy enforcement"
  chmod 600 "$backup" 2>/dev/null || true
  prune_keep_latest "$backup_dir" "x-ui.db.*" 4

  XPAM_XUI_DB="$db" \
  XPAM_SERVER_PREFIX="$SERVER_PREFIX" \
  XPAM_EXPECTED_PORT="$expected_port" \
  XPAM_EXPECTED_LISTEN="$expected_listen" \
  XPAM_EXPECTED_REMARK="$expected_remark" \
  XPAM_PRIMARY_DOMAIN="$PRIMARY_DOMAIN" \
  XPAM_PUBLIC_PORT="$XRAY_PUBLIC_PORT" \
  XPAM_MODE="$mode" \
  python3 <<'PY_XUI_VLESS_POLICY'
import json, os, sqlite3, sys

db=os.environ['XPAM_XUI_DB']
prefix=os.environ['XPAM_SERVER_PREFIX']
port=int(os.environ['XPAM_EXPECTED_PORT'])
expected_listen=os.environ['XPAM_EXPECTED_LISTEN']
expected_remark=os.environ['XPAM_EXPECTED_REMARK']
primary=os.environ['XPAM_PRIMARY_DOMAIN']
public_port=int(os.environ['XPAM_PUBLIC_PORT'])
mode=os.environ['XPAM_MODE']
expected_proxy={
    'forceTls': 'same',
    'dest': primary,
    'port': public_port,
    'remark': f'{prefix}-public-{public_port}',
}

def fail(msg):
    print('ERROR:', msg, file=sys.stderr)
    sys.exit(1)

def ok(msg):
    print('OK:', msg)

def load_json(raw, default):
    if raw is None or raw == '':
        return default
    try:
        data=json.loads(raw)
        return data if isinstance(data, type(default)) else default
    except Exception:
        return default

conn=sqlite3.connect(db)
conn.row_factory=sqlite3.Row
cur=conn.cursor()
cols=[r[1] for r in cur.execute('PRAGMA table_info(inbounds)').fetchall()]
base_required={'id','listen','port','protocol'}
if not base_required <= set(cols):
    fail(f'3x-ui inbounds schema is not compatible; missing {sorted(base_required-set(cols))}')
stream_col=next((c for c in ('stream_settings','streamSettings','stream') if c in cols), None)
if not stream_col:
    fail('3x-ui inbounds schema is not compatible; stream settings column not found')
select_cols=[c for c in ('id','remark','listen','port','protocol',stream_col) if c in cols]
select_sql='SELECT '+','.join('"'+c.replace('"','""')+'"' for c in select_cols)+" FROM inbounds WHERE lower(protocol)='vless' AND port=?"
rows=[dict(r) for r in cur.execute(select_sql, (port,)).fetchall()]
if not rows:
    fail(f'XPAM VLESS inbound on port {port} was not found')
legacy_remarks={f'{prefix}-vless-local-{port}', f'{prefix}-vless-public-{port}'}
canonical=[r for r in rows if str(r.get('remark') or '') == expected_remark]
legacy=[r for r in rows if str(r.get('remark') or '') in legacy_remarks]
if len(canonical)==1:
    managed=canonical
elif len(legacy)==1:
    managed=legacy
elif len(rows)==1:
    managed=rows
else:
    managed=[]
if len(managed)!=1:
    fail(f'Could not uniquely identify XPAM-managed VLESS inbound on port {port}; candidates={[(r.get("id"), r.get("remark"), r.get("listen")) for r in rows]}')
row=managed[0]
changed=False
old_remark=str(row.get('remark') or '')
if 'remark' in cols and old_remark in legacy_remarks and old_remark != expected_remark:
    cur.execute('UPDATE inbounds SET remark=? WHERE id=?', (expected_remark, row['id']))
    changed=True
    ok(f'VLESS inbound legacy name normalized from {old_remark} to {expected_remark}')
elif old_remark and old_remark != expected_remark:
    ok(f'VLESS inbound custom name preserved: {old_remark}')
old_listen=str(row.get('listen') or '')
if old_listen == expected_listen:
    if mode == 'direct':
        ok(f'direct VLESS inbound already binds public IPv4 {expected_listen}:{port}')
    else:
        ok(f'HAProxy-mode VLESS inbound already binds local listener {expected_listen}:{port}')
else:
    cur.execute('UPDATE inbounds SET listen=? WHERE id=?', (expected_listen, row['id']))
    changed=True
    if mode == 'direct':
        ok(f'direct VLESS inbound listen updated from {old_listen or "<empty>"} to {expected_listen}:{port}')
    else:
        ok(f'HAProxy-mode VLESS inbound listen updated from {old_listen or "<empty>"} to {expected_listen}:{port}')

stream=load_json(row.get(stream_col), {})
if not isinstance(stream, dict):
    stream={}
current=stream.get('externalProxy')
if current == [expected_proxy]:
    ok(f'External Proxy already points generated links to {primary}:{public_port}')
else:
    stream['externalProxy']=[expected_proxy]
    cur.execute('UPDATE inbounds SET "'+stream_col.replace('\"','\"\"')+'"=? WHERE id=?', (json.dumps(stream, separators=(',',':')), row['id']))
    changed=True
    ok(f'External Proxy normalized to {primary}:{public_port} for generated VLESS links')
if changed:
    conn.commit()
conn.close()
PY_XUI_VLESS_POLICY
}

xui_enforce_direct_ipv4_bind(){
  xui_enforce_vless_inbound_policy
}
xui_add_vless_inbound_auto(){
  local base payload ids uuid subid client_name inbound_remark rc note vless_link panel_path_clean expected_listen
  panel_path_clean="${PANEL_PATH#/}"
  panel_path_clean="${panel_path_clean%/}"
  base="https://127.0.0.1:${XUI_PANEL_PORT}/${panel_path_clean}"
  payload="$(mktemp /tmp/xpam-script-xui-inbound.XXXXXX.json)"
  if uses_haproxy; then
    expected_listen="127.0.0.1"
  else
    expected_listen="$(server_public_ipv4)"
  fi

  say "Checking local 3x-ui API token in XPAM root-only storage"
  xui_ensure_api_token || fail "Could not obtain usable 3x-ui API token"

  say "Проверка существующего XPAM-managed VLESS inbound"
  existing="$(SERVER_PREFIX="$SERVER_PREFIX" PRIMARY_DOMAIN="$PRIMARY_DOMAIN" XRAY_PUBLIC_PORT="$XRAY_PUBLIC_PORT" EXPECTED_PORT="$(expected_xray_port)" EXPECTED_LISTEN="$expected_listen" python3 - <<'PY_EXISTING_VLESS' 2>/dev/null || true
import json, os, sqlite3, sys
from urllib.parse import quote, urlencode
DB='/etc/x-ui/x-ui.db'
prefix=os.environ['SERVER_PREFIX']
primary=os.environ['PRIMARY_DOMAIN']
public_port=os.environ['XRAY_PUBLIC_PORT']
expected_port=str(os.environ['EXPECTED_PORT'])
expected_listen=os.environ.get('EXPECTED_LISTEN','')

def enabled(value):
    if value is None:
        return True
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return str(value).strip().lower() not in {'0','false','no','off','disabled'}

def load_json(raw, default):
    try:
        data=json.loads(raw or '{}')
        return data if isinstance(data, type(default)) else default
    except Exception:
        return default

def first_external_proxy(stream):
    proxies=stream.get('externalProxy') or stream.get('external_proxy') or []
    if isinstance(proxies, dict):
        proxies=[proxies]
    if not isinstance(proxies, list):
        return None
    for proxy in proxies:
        if isinstance(proxy, dict) and proxy.get('dest') and proxy.get('port'):
            return proxy
    return None

def alpn_value(tls):
    alpn=tls.get('alpn')
    if isinstance(alpn, list):
        return ','.join(str(x) for x in alpn if x) or 'http/1.1'
    if alpn is None:
        return 'http/1.1'
    return str(alpn)

def client_name(client, idx):
    for key in ('email','remark','name'):
        value=client.get(key)
        if value:
            return str(value)
    return f'client-{idx}'

def build_link(uuid, name, client, stream):
    ext=first_external_proxy(stream)
    host=str(ext.get('dest') if ext else primary).strip() or primary
    port=str(ext.get('port') if ext else public_port).strip() or str(public_port)
    network=str(stream.get('network') or 'tcp')
    security=str(stream.get('security') or 'tls')
    tls=stream.get('tlsSettings') or stream.get('tls_settings') or {}
    if not isinstance(tls, dict):
        tls={}
    tls_settings=tls.get('settings') if isinstance(tls.get('settings'), dict) else {}
    params={'type':network,'security':security}
    flow=str(client.get('flow') or '').strip()
    if flow:
        params['flow']=flow
    sni=str(tls.get('serverName') or tls.get('server_name') or host).strip()
    if security in {'tls','reality'} and sni:
        params['sni']=sni
    fp=str(tls_settings.get('fingerprint') or tls.get('fingerprint') or 'firefox').strip()
    if security in {'tls','reality'} and fp:
        params['fp']=fp
    alpn=alpn_value(tls)
    if security == 'tls' and alpn:
        params['alpn']=alpn
    return f'vless://{uuid}@{host}:{port}?{urlencode(params, safe=",")}#{quote(name)}'

conn=sqlite3.connect(DB)
conn.row_factory=sqlite3.Row
cur=conn.cursor()
rows=[]
for row in cur.execute('SELECT * FROM inbounds ORDER BY id ASC'):
    r=dict(row)
    if str(r.get('protocol','')).lower()!='vless':
        continue
    if str(r.get('port','')) != expected_port:
        continue
    if expected_listen and str(r.get('listen') or '') != expected_listen:
        continue
    rows.append(r)
if len(rows) != 1:
    sys.exit(0)
r=rows[0]
remark=str(r.get('remark','')) or f'{prefix}-vless'
settings=load_json(r.get('settings'), {})
stream=load_json(r.get('stream_settings') or r.get('streamSettings') or r.get('stream'), {})
clients=settings.get('clients') or []
if isinstance(clients, dict):
    clients=[clients]
if not isinstance(clients, list):
    clients=[]
for idx, c in enumerate(clients, 1):
    if not isinstance(c, dict) or not enabled(c.get('enable', c.get('enabled', True))):
        continue
    uuid=c.get('id') or c.get('uuid')
    if not uuid:
        continue
    name=client_name(c, idx)
    link=build_link(str(uuid), name, c, stream)
    print('	'.join([str(uuid), name, remark, link]))
    sys.exit(0)
PY_EXISTING_VLESS
)"
  if [[ -n "$existing" ]]; then
    IFS=$'\t' read -r uuid client_name inbound_remark vless_link <<< "$existing"
    note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"
    mkdir -p /root/secure-notes
    chmod 700 /root/secure-notes
    cat > "$note" <<EOF_XUINOTE_EXISTING
3x-ui / VLESS setup for XPAM Script
=======================================================
Installed 3x-ui tag: ${XUI_INSTALLED_TAG}

Panel public URL: https://${PRIMARY_DOMAIN}/${PANEL_PATH}/
3x-ui username: ${XUI_ADMIN_USER}
3x-ui password: ${XUI_ADMIN_PASS}

Inbound name: ${inbound_remark}
Client name: ${client_name}
VLESS link: ${vless_link}
EOF_XUINOTE_EXISTING
    chmod 600 "$note"
    rm -f "$payload"
    ok "Существующий VLESS inbound найден и переиспользован: ${inbound_remark}"
    return 0
  fi

  say "Building VLESS TLS fallback inbound payload"
  ids="$(xui_build_inbound_payload "$payload")"
  uuid="$(printf '%s\n' "$ids" | sed -n '1p')"
  subid="$(printf '%s\n' "$ids" | sed -n '2p')"
  client_name="$(printf '%s\n' "$ids" | sed -n '3p')"
  inbound_remark="$(printf '%s\n' "$ids" | sed -n '4p')"

  say "Adding VLESS inbound through 3x-ui Bearer API"
  rc=0
  xpam_xui_api_post_json \
    "$base/panel/api/inbounds/add" \
    "$payload" \
    /tmp/xpam-script-xui-add-inbound.out \
    /tmp/xpam-script-xui-add-inbound.err || rc=$?

  if [[ $rc -ne 0 ]] || ! grep -Eiq '"success"[[:space:]]*:[[:space:]]*true' /tmp/xpam-script-xui-add-inbound.out 2>/dev/null; then
    warn "3x-ui Bearer API add-inbound did not return clear success. Response follows:"
    sed -n '1,120p' /tmp/xpam-script-xui-add-inbound.out 2>/dev/null || true
    sed -n '1,80p' /tmp/xpam-script-xui-add-inbound.err 2>/dev/null || true
    rm -f "$payload"
    fail "Automatic inbound creation failed"
  fi

  mkdir -p /root/secure-notes
  chmod 700 /root/secure-notes

  vless_link="vless://${uuid}@${PRIMARY_DOMAIN}:${XRAY_PUBLIC_PORT}?type=tcp&security=tls&flow=xtls-rprx-vision&sni=${PRIMARY_DOMAIN}&fp=firefox&alpn=http%2F1.1#${client_name}"
  note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"

  cat > "$note" <<EOF_XUINOTE
3x-ui / VLESS setup for XPAM Script
=======================================================
Installed 3x-ui tag: ${XUI_INSTALLED_TAG}

Panel public URL: https://${PRIMARY_DOMAIN}/${PANEL_PATH}/
3x-ui username: ${XUI_ADMIN_USER}
3x-ui password: ${XUI_ADMIN_PASS}

Inbound name: ${inbound_remark}
Client name: ${client_name}
VLESS link: ${vless_link}
EOF_XUINOTE

  chmod 600 "$note"
  rm -f "$payload"
  ok "VLESS inbound created and credentials stored in $note"
}

install_configure_3xui_auto(){
  say "Automatic 3x-ui install/configure mode"
  ensure_web_cert_for_xui
  [[ -n "${XUI_ADMIN_USER:-}" ]] || ask XUI_ADMIN_USER "3x-ui admin username" "vlessuser"
  [[ -n "${XUI_ADMIN_PASS:-}" ]] || ask_xui_admin_credentials
  local cert key tag installer
  cert="/etc/letsencrypt/live/$(web_cert_name)/fullchain.pem"
  key="/etc/letsencrypt/live/$(web_cert_name)/privkey.pem"
  [[ -s "$cert" && -s "$key" ]] || fail "Cert/key missing for 3x-ui panel: $cert / $key"

  tag="$(xui_latest_release_tag_any)"
  XUI_INSTALLED_TAG="$tag"
  save_config
  say "Installing 3x-ui tag ${tag} (latest GitHub release including pre-release)"
  xui_prepare_sqlite_backend_for_install
  installer="$(mktemp /tmp/3x-ui-install.XXXXXX.sh)"
  curl -4fsSL --connect-timeout 8 --max-time 30 -o "$installer" https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh || fail "Could not download 3x-ui installer"
  chmod +x "$installer"
  if ! xpam_xui_run_installer_sanitized "$installer" "$tag" "$XUI_PANEL_PORT"; then
    rm -f "$installer"
    fail "3x-ui installer failed"
  fi
  rm -f "$installer"
  xui_validate_sqlite_contract

  say "Forcing XPAM Script panel settings"
  /usr/local/x-ui/x-ui setting -username "$XUI_ADMIN_USER" -password "$XUI_ADMIN_PASS" -port "$XUI_PANEL_PORT" -webBasePath "/${PANEL_PATH}/" -listenIP "127.0.0.1" || fail "x-ui setting failed"
  /usr/local/x-ui/x-ui cert -webCert "$cert" -webCertKey "$key" || fail "x-ui cert failed"
  xui_disable_subscription
  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl restart x-ui || fail "x-ui restart failed"
  write_wait_for_port
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 30 xui-panel
  xui_ensure_api_token || fail "Could not obtain usable 3x-ui API token"
  xui_add_vless_inbound_auto
  xui_enforce_direct_ipv4_bind
  systemctl restart x-ui || true
  sleep 2
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 30 xui-panel
  wait_for_xray_vless 30
  ok "Automatic 3x-ui install/configure complete"
  echo "Panel URL after setup: https://${PRIMARY_DOMAIN}/${PANEL_PATH}/"
  echo "3x-ui username: ${XUI_ADMIN_USER}"
  echo "3x-ui password сохранён в /root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"
}

stage_xui_auto_only(){
  need_root
  require_os
  load_config
  validate_inputs
  ask_xui_admin_credentials
  install_configure_3xui_auto
  reboot_status_notice
}

verify_xui_manual_setup(){
  say "Verifying 3x-ui setup"
  xui_installed_ok || fail "3x-ui is not installed/configured"
  xui_validate_sqlite_contract
  write_wait_for_port
  systemctl restart x-ui || fail "x-ui restart failed"
  sleep 2
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 20 xui-panel
  xui_enforce_direct_ipv4_bind
  systemctl restart x-ui || fail "x-ui restart failed after direct IPv4 bind enforcement"
  sleep 2
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 20 xui-panel
  wait_for_xray_vless 20
  ok "3x-ui/VLESS ports reachable. Deep validation will run in health."
}
write_nginx_final(){ export_vars; cleanup_legacy_nginx_files; if uses_mtproto; then ensure_telegram_relay_nginx_snippet; render_template "$KIT_DIR/templates/nginx-mtproto.conf.tpl" /etc/nginx/sites-available/xpam-script-final.conf; else render_template "$KIT_DIR/templates/nginx-direct.conf.tpl" /etc/nginx/sites-available/xpam-script-final.conf; fi; rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/xpam-script-certonly.conf; ln -sf /etc/nginx/sites-available/xpam-script-final.conf /etc/nginx/sites-enabled/xpam-script-final.conf; ensure_htpasswd; nginx -t; systemctl reload nginx || systemctl restart nginx; }

write_haproxy(){ uses_mtproto || return 0; export_vars; render_template "$KIT_DIR/templates/haproxy.cfg.tpl" /etc/haproxy/haproxy.cfg; haproxy -c -f /etc/haproxy/haproxy.cfg; mkdir -p /etc/systemd/system/haproxy.service.d; render_template "$KIT_DIR/templates/backend-order.conf.tpl" /etc/systemd/system/haproxy.service.d/backend-order.conf; systemctl daemon-reload; systemctl enable haproxy; systemctl restart haproxy; }
write_health_weekly(){ say "Writing health and weekly scripts"; write_common_library; bash -c '. /usr/local/sbin/xpam-maint-common.sh; xpam_apply_small_vm_policies' || true; write_dns_policy_script; write_network_tuning_policy_script; write_telegram_https_relay_worker; migrate_legacy_system_file_names || true; export_vars; render_template "$KIT_DIR/templates/health.sh.tpl" "/usr/local/sbin/${SERVER_PREFIX}-health"; chmod +x "/usr/local/sbin/${SERVER_PREFIX}-health"; bash -n "/usr/local/sbin/${SERVER_PREFIX}-health"; write_health_launcher || true; write_links_launcher || true; write_vless_launcher || true; write_tg_launcher || true; write_repair_launcher || true; write_netdiag_launcher || true; render_template "$KIT_DIR/templates/weekly.sh.tpl" "/usr/local/sbin/${SERVER_PREFIX}-weekly-maintenance.sh"; chmod +x "/usr/local/sbin/${SERVER_PREFIX}-weekly-maintenance.sh"; bash -n "/usr/local/sbin/${SERVER_PREFIX}-weekly-maintenance.sh"; write_weekly_launcher || true; local cron_min=35; [[ "$SERVER_PREFIX" == "se" ]] && cron_min=30; [[ "$SERVER_PREFIX" == "lt" ]] && cron_min=40; cat > "/etc/cron.d/${SERVER_PREFIX}-weekly-maintenance" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${cron_min} 4 * * 0 root /usr/bin/nice -n 19 /usr/bin/ionice -c3 /usr/local/sbin/${SERVER_PREFIX}-weekly-maintenance.sh >/dev/null 2>&1
EOF
}

ask_layout(){
  echo
  echo "Choose server profile:"
  echo "1) Subdomains-only: VLESS domain + Telegram domain"
  echo "2) Full-domain: root/www + VLESS domain + Telegram domain"
  local choice
  read -r -p "Profile [1-2]: " choice
  case "$choice" in
    1) PROFILE=subdomains_mtproto ;;
    2) PROFILE=root_mtproto ;;
    *) fail "Unknown profile" ;;
  esac

  ensure_prefix_bootstrap
  ask PRIMARY_DOMAIN "VLESS/3x-ui masking domain" ""
  if [[ "$PROFILE" == "root_mtproto" ]]; then
    ask ROOT_DOMAIN "Main/root domain without www" ""
    ROOT_DOMAIN="${ROOT_DOMAIN#www.}"
    WWW_DOMAIN="www.${ROOT_DOMAIN}"
    echo "Auto www alias: ${WWW_DOMAIN}"
    ask WEB_CERT_NAME "Certbot cert-name for unified main/root+www+VLESS cert" "$(echo "$ROOT_DOMAIN" | tr . -)-${SERVER_PREFIX}-unified"
  else
    ROOT_DOMAIN=""
    WWW_DOMAIN=""
    ask WEB_CERT_NAME "Certbot cert-name for Web/VLESS cert" "$PRIMARY_DOMAIN"
  fi
  if uses_mtproto; then
    MTPROTO_BACKEND="3xui-mtg"
    ask SYNC_DOMAIN "Telegram domain" ""
  fi
  ask CERT_EMAIL "Email for Let's Encrypt; empty = no email" ""
  ask_default_label PANEL_PATH "3x-ui panel path" "$PANEL_PATH"
  ask XUI_PANEL_PORT "3x-ui local panel port" "$XUI_PANEL_PORT"
  uses_haproxy && ask XRAY_LOCAL_PORT "Local Xray/VLESS port behind HAProxy" "$XRAY_LOCAL_PORT"
  ask SITE_BACKEND_PORT "Local nginx fallback site port" "$SITE_BACKEND_PORT"
  uses_mtproto && ask SYNC_BACKEND_PORT "Local nginx Telegram TLS fallback port" "$SYNC_BACKEND_PORT" && ask MTPROTO_PORT "Local Telegram backend port" "$MTPROTO_PORT"
  echo "External ports are fixed by XPAM Script: SSH 22, HTTP 80, TLS 443. They are not asked interactively."
  if confirm "Установить и настроить 3x-ui автоматически?" "${XUI_AUTO_SETUP:-yes}"; then
    XUI_AUTO_SETUP="yes"
    ask_xui_admin_credentials
  else
    XUI_AUTO_SETUP="no"
  fi

  validate_inputs
  echo
  echo "Planned layout:"
  echo "  Profile: $PROFILE"
  echo "  Web/VLESS domains: $(web_domains)"
  [[ "$PROFILE" == "root_mtproto" ]] && echo "  Main/root domain: $ROOT_DOMAIN" && echo "  Auto www alias: $WWW_DOMAIN"
  uses_mtproto && echo "  Telegram domain: $SYNC_DOMAIN"
  uses_mtproto && echo "  Telegram backend: $MTPROTO_BACKEND"
  echo "  Cert name: $(web_cert_name)"
  echo "  Public ports: SSH ${SSH_PUBLIC_PORT}, HTTP ${HTTP_PUBLIC_PORT}, TLS ${XRAY_PUBLIC_PORT}"
  echo "  3x-ui panel: 127.0.0.1:${XUI_PANEL_PORT}, public path https://${PRIMARY_DOMAIN}/${PANEL_PATH}/"
  echo "  VLESS/Xray inbound: $(uses_haproxy && echo 127.0.0.1 || server_public_ipv4):$(expected_xray_port)"
  echo "  3x-ui automation: ${XUI_AUTO_SETUP}"
  confirm "Продолжить?" yes || fail "Cancelled"
}

stage_prepare(){
  need_root
  require_os
  ensure_sudo_hostname_resolution
  verify_ssh_preflight
  if [[ "${XPAM_REUSE_CONFIG:-no}" == "yes" && -s "$CONFIG_FILE" ]]; then
    say "Продолжаю установку с сохранённой конфигурацией"
    load_config
    validate_inputs
  else
    ask_layout
    save_config
  fi
  small_vm_resource_preflight
  ensure_swap_policy
  preinstall_system_update
  install_base_packages
  # Provider images sometimes map the server hostname/root domain to 127.0.0.1 in /etc/hosts.
  # Fix managed domains before the DNS policy self-check, otherwise a valid public DNS setup can fail locally.
  fix_managed_hosts
  setup_dns_policy
  check_dns_preflight
  apply_network_tuning_policy
  apply_service_nofile_limits
  /usr/local/sbin/check-network-tuning-policy || fail "network tuning policy check failed"
  setup_ufw
  setup_fail2ban_ssh
  setup_sites
  write_nginx_certonly
  issue_certs
  write_certbot_hook
  write_wait_for_port
  write_common_library
  write_manual_3xui_note
  if [[ "${XUI_AUTO_SETUP:-yes}" == "yes" ]]; then
    install_configure_3xui_auto
  else
    warn "3x-ui automation disabled; use the manual checklist before continuing setup."
  fi
  post_install_cleanup
  cleanup_root_test_leftovers stage1 || true
  mkdir -p "$CONFIG_DIR"
  date -Is > "$PREPARE_DONE_FILE"
  reboot_status_notice
  echo
  echo "============================================================"
  if reboot_recommended_before_finalize; then
    warn "Первый этап завершён. Перед финальной настройкой требуется перезагрузка."
    echo "Выполните сейчас:"
    echo "  sudo reboot"
    echo
    echo "После перезагрузки войдите по SSH-ключу и выполните:"
    echo "  sudo ${SERVER_PREFIX}-xpam"
    echo "============================================================"
    echo
    exit 0
  elif [[ "${XUI_AUTO_SETUP:-yes}" == "yes" ]]; then
    ok "Перезагрузка не требуется. Продолжаю финальную настройку автоматически."
    echo "============================================================"
    echo
    stage_finalize
    exit 0
  else
    ok "Первый этап завершён. Настройте 3x-ui вручную, затем выполните: sudo ${SERVER_PREFIX}-xpam"
    echo "============================================================"
    echo
    exit 0
  fi
}
note_value(){
  local file="$1" key="$2"
  [[ -s "$file" ]] || return 0
  awk -v k="$key" 'index($0,k": ")==1 {sub(k": ",""); print; exit}' "$file" 2>/dev/null || true
}

print_vless_links_from_xui(){
  local auto_note="$1" db="/etc/x-ui/x-ui.db" tmp rc

  echo "ГОТОВЫЕ VLESS ССЫЛКИ ИЗ 3x-ui:"

  if [[ -s "$db" ]]; then
    tmp="$(mktemp /tmp/xpam-script-vless-links.XXXXXX)"
    rc=0
    XPAM_XUI_DB="$db" XPAM_PRIMARY_DOMAIN="${PRIMARY_DOMAIN}" XPAM_XRAY_PUBLIC_PORT="${XRAY_PUBLIC_PORT}" \
      python3 - <<'PY_VLESS_LINKS' >"$tmp" || rc=$?
import json
import os
import sqlite3
import sys
from urllib.parse import quote, urlencode

DB = os.environ.get("XPAM_XUI_DB", "/etc/x-ui/x-ui.db")
DEFAULT_HOST = os.environ.get("XPAM_PRIMARY_DOMAIN", "")
DEFAULT_PORT = os.environ.get("XPAM_XRAY_PUBLIC_PORT", "443") or "443"


def parse_json(value, default):
    if value is None or value == "":
        return default
    if isinstance(value, (dict, list)):
        return value
    try:
        parsed = json.loads(str(value))
        if isinstance(parsed, str):
            try:
                return json.loads(parsed)
            except Exception:
                return default
        return parsed
    except Exception:
        return default


def enabled(value):
    if value is None:
        return True
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return str(value).strip().lower() not in {"0", "false", "no", "off", "disabled"}


def pick(row, *names, default=None):
    for name in names:
        if name in row:
            return row[name]
    return default


def first_external_proxy(stream):
    proxies = stream.get("externalProxy") or stream.get("external_proxy") or []
    if isinstance(proxies, dict):
        proxies = [proxies]
    if not isinstance(proxies, list):
        return None
    for proxy in proxies:
        if isinstance(proxy, dict) and proxy.get("dest") and proxy.get("port"):
            return proxy
    return None


def alpn_value(tls):
    alpn = tls.get("alpn")
    if isinstance(alpn, list):
        alpn = ",".join(str(x) for x in alpn if x)
    elif alpn is None:
        alpn = "http/1.1"
    else:
        alpn = str(alpn)
    return alpn


def client_name(client, idx):
    for key in ("email", "remark", "name"):
        value = client.get(key)
        if value:
            return str(value)
    return f"client-{idx}"


def build_link(uuid, name, client, stream, inbound_port):
    ext = first_external_proxy(stream)
    host = str(ext.get("dest") if ext else DEFAULT_HOST).strip() if (ext or DEFAULT_HOST) else ""
    port = str(ext.get("port") if ext else DEFAULT_PORT).strip() if (ext or DEFAULT_PORT) else "443"
    if not host:
        host = DEFAULT_HOST or "<domain>"

    network = str(stream.get("network") or "tcp")
    security = str(stream.get("security") or "tls")
    tls = stream.get("tlsSettings") or stream.get("tls_settings") or stream.get("realitySettings") or {}
    if not isinstance(tls, dict):
        tls = {}
    tls_settings = tls.get("settings") if isinstance(tls.get("settings"), dict) else {}

    params = {
        "type": network,
        "security": security,
    }

    flow = str(client.get("flow") or "").strip()
    if flow:
        params["flow"] = flow

    sni = str(tls.get("serverName") or tls.get("server_name") or host).strip()
    if security in {"tls", "reality"} and sni:
        params["sni"] = sni

    fp = str(tls_settings.get("fingerprint") or tls.get("fingerprint") or "firefox").strip()
    if security in {"tls", "reality"} and fp:
        params["fp"] = fp

    alpn = alpn_value(tls)
    if security == "tls" and alpn:
        params["alpn"] = alpn

    if network == "ws":
        ws = stream.get("wsSettings") or stream.get("ws_settings") or {}
        if isinstance(ws, dict):
            if ws.get("path"):
                params["path"] = str(ws.get("path"))
            headers = ws.get("headers") if isinstance(ws.get("headers"), dict) else {}
            if headers.get("Host"):
                params["host"] = str(headers.get("Host"))
    elif network == "grpc":
        grpc = stream.get("grpcSettings") or stream.get("grpc_settings") or {}
        if isinstance(grpc, dict) and grpc.get("serviceName"):
            params["serviceName"] = str(grpc.get("serviceName"))

    query = urlencode(params, safe=",")
    return f"vless://{uuid}@{host}:{port}?{query}#{quote(name)}"

try:
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    columns = [r[1] for r in cur.execute("PRAGMA table_info(inbounds)").fetchall()]
    if not columns:
        raise RuntimeError("3x-ui inbounds table schema not found")
    rows = [dict(r) for r in cur.execute("SELECT * FROM inbounds ORDER BY id ASC").fetchall()]
except Exception as exc:
    print(f"WARN: не удалось прочитать 3x-ui SQLite: {exc}", file=sys.stderr)
    sys.exit(2)

found = 0
for row in rows:
    protocol = str(pick(row, "protocol", default="")).lower()
    if protocol != "vless":
        continue
    if not enabled(pick(row, "enable", "enabled", default=1)):
        continue

    settings = parse_json(pick(row, "settings", default="{}"), {})
    stream = parse_json(pick(row, "stream_settings", "streamSettings", "stream", default="{}"), {})
    if not isinstance(settings, dict):
        settings = {}
    if not isinstance(stream, dict):
        stream = {}

    clients = settings.get("clients") or []
    if isinstance(clients, dict):
        clients = [clients]
    if not isinstance(clients, list):
        clients = []

    enabled_clients = []
    for idx, client in enumerate(clients, 1):
        if not isinstance(client, dict):
            continue
        uuid = str(client.get("id") or client.get("uuid") or "").strip()
        if not uuid:
            continue
        if not enabled(client.get("enable", client.get("enabled", True))):
            continue
        enabled_clients.append((idx, client, uuid))

    if not enabled_clients:
        continue

    remark = str(pick(row, "remark", "tag", default="VLESS inbound") or "VLESS inbound")
    inbound_id = pick(row, "id", default="?")
    inbound_port = pick(row, "port", default="?")
    for idx, client, uuid in enabled_clients:
        name = client_name(client, idx)
        link = build_link(uuid, name, client, stream, inbound_port)
        print(f"  Inbound Name: {remark}")
        print(f"  Client Name: {name}")
        print(f"  VLESS Link: {link}")
        print()
    found += len(enabled_clients)

if found == 0:
    sys.exit(3)
PY_VLESS_LINKS
    rc=$?

    if [[ $rc -eq 0 && -s "$tmp" ]]; then
      cat "$tmp"
      rm -f "$tmp"
      return 0
    fi

    if [[ $rc -ne 3 ]]; then
      sed -n '1,20p' "$tmp" 2>/dev/null || true
    fi
    rm -f "$tmp"
  fi

  echo "  VLESS клиенты не найдены в 3x-ui DB. Добавьте клиента в 3x-ui или проверьте /etc/x-ui/x-ui.db."
  return 1
}

current_telegram_link_from_xui(){
  local db="/etc/x-ui/x-ui.db" tmp rc

  [[ -s "$db" ]] || return 1

  tmp="$(mktemp /tmp/xpam-telegram-link.XXXXXX)" || return 1
  rc=0
  XPAM_XUI_DB="$db" \
  XPAM_SYNC_DOMAIN="${SYNC_DOMAIN}" \
  XPAM_MTPROTO_PORT="${MTPROTO_PORT}" \
  python3 - <<'PY_TELEGRAM_LINK' >"$tmp" || rc=$?
import json
import os
import sqlite3
import sys

DB = os.environ.get("XPAM_XUI_DB", "/etc/x-ui/x-ui.db")
SYNC_DOMAIN = os.environ.get("XPAM_SYNC_DOMAIN", "")
MTPROTO_PORT = str(os.environ.get("XPAM_MTPROTO_PORT", "") or "")
PUBLIC_PORT = "443"


def parse_json(value, default):
    if value is None or value == "":
        return default
    if isinstance(value, (dict, list)):
        return value
    try:
        parsed = json.loads(str(value))
        if isinstance(parsed, str):
            try:
                return json.loads(parsed)
            except Exception:
                return default
        return parsed
    except Exception:
        return default


def enabled(value):
    if value is None:
        return True
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return str(value).strip().lower() not in {"0", "false", "no", "off", "disabled"}


def pick(row, *names, default=None):
    for name in names:
        if name in row:
            return row[name]
    return default

try:
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    rows = [dict(r) for r in conn.execute("SELECT * FROM inbounds ORDER BY id ASC").fetchall()]
except Exception as exc:
    print(f"WARN: cannot read 3x-ui SQLite: {exc}", file=sys.stderr)
    sys.exit(2)

candidates = []
for row in rows:
    if str(pick(row, "protocol", default="")).lower() != "mtproto":
        continue
    if not enabled(pick(row, "enable", "enabled", default=1)):
        continue

    settings = parse_json(pick(row, "settings", default="{}"), {})
    if not isinstance(settings, dict):
        settings = {}

    secret = str(settings.get("secret") or "").strip()
    server = str(settings.get("shareAddr") or settings.get("fakeTlsDomain") or SYNC_DOMAIN or "").strip()
    fake_tls = str(settings.get("fakeTlsDomain") or "").strip()
    share_addr = str(settings.get("shareAddr") or "").strip()
    row_port = str(pick(row, "port", default="") or "")

    if not secret or not server:
        continue

    score = 0
    if SYNC_DOMAIN and (server == SYNC_DOMAIN or share_addr == SYNC_DOMAIN or fake_tls == SYNC_DOMAIN):
        score += 100
    if MTPROTO_PORT and row_port == MTPROTO_PORT:
        score += 30
    if str(pick(row, "listen", default="") or "").startswith("127."):
        score += 10

    candidates.append((score, int(pick(row, "id", default=0) or 0), server, secret))

if not candidates:
    sys.exit(3)

candidates.sort(key=lambda item: (-item[0], item[1]))
_, _, server, secret = candidates[0]
print(f"tg://proxy?server={server}&port={PUBLIC_PORT}&secret={secret}")
PY_TELEGRAM_LINK

  if [[ $rc -eq 0 && -s "$tmp" ]]; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi

  rm -f "$tmp"
  return 1
}


vless_links_file(){
  # Kept for compatibility with older operator habits. Since the current
  # runtime, VLESS links are generated from 3x-ui SQLite on demand and are
  # not stored as source-of-truth secure-note files.
  echo "/root/secure-notes/${SERVER_PREFIX}-vless-links.txt"
}

sync_vless_links_file(){
  # Compatibility no-op: remove stale legacy link cache if present.
  # 3x-ui DB is the source of truth for VLESS links.
  local file
  file="$(vless_links_file)"
  [[ -e "$file" ]] && rm -f "$file" 2>/dev/null || true
  return 0
}

print_connection_summary(){
  local basic_note auto_note mt_users_note
  basic_note="/root/secure-notes/${SERVER_PREFIX}-basic-auth.txt"
  auto_note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"
  mt_users_note="/root/secure-notes/${SERVER_PREFIX}-mtproto-users.txt"
  sync_vless_links_file >/dev/null 2>&1 || true

  echo
  echo "============================================================"
  echo "XPAM Script: данные подключения"
  echo "============================================================"
  echo
  echo "Этот вывод безопасный: пароли, VLESS-ссылки и Telegram секреты здесь не печатаются."
  echo "Полные секреты лежат только в защищённых файлах с правами 600."
  echo
  echo "Сайты и панели:"
  [[ -n "${ROOT_DOMAIN:-}" ]] && echo "  Основной сайт:        https://${ROOT_DOMAIN}/"
  [[ -n "${WWW_DOMAIN:-}" && -n "${ROOT_DOMAIN:-}" ]] && echo "  www redirect:         https://${WWW_DOMAIN}/ -> https://${ROOT_DOMAIN}/"
  echo "  3x-ui / VLESS:        https://${PRIMARY_DOMAIN}/${PANEL_PATH}/"
  if uses_mtproto; then
    echo "  Telegram proxy:       https://${SYNC_DOMAIN}/health"
  fi
  echo
  echo "Файлы с секретами на сервере:"
  [[ -f "$basic_note" ]] && echo "  Basic Auth:           $basic_note"
  [[ -f "$auto_note" ]] && echo "  3x-ui данные:         $auto_note"
  echo "  VLESS/Telegram links: формируются из актуальной базы 3x-ui"
  if uses_mtproto && mtproto_backend_is_alexbers; then
    [[ -f "$mt_users_note" ]] && echo "  MTProto users:        $mt_users_note"
  fi
  echo
  echo "Показать секреты:"
  echo "  Все данные подключения: sudo ${SERVER_PREFIX}-links --show-secrets"
  echo
  echo "Проверка сервера:"
  echo "  Быстрая:              sudo ${SERVER_PREFIX}-health"
  echo "  Подробная:            sudo ${SERVER_PREFIX}-health --deep"
  echo "============================================================"
}

print_connection_secrets_summary(){
  local basic_note auto_note mt_users_note basic_user basic_pass xui_user xui_pass mtproto_link
  basic_note="/root/secure-notes/${SERVER_PREFIX}-basic-auth.txt"
  auto_note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"
  mt_users_note="/root/secure-notes/${SERVER_PREFIX}-mtproto-users.txt"

  basic_user="$(note_value "$basic_note" "Username")"
  basic_pass="$(note_value "$basic_note" "Password")"
  xui_user="$(note_value "$auto_note" "3x-ui username")"
  xui_pass="$(note_value "$auto_note" "3x-ui password")"
  mtproto_link="$(current_telegram_link_from_xui 2>/dev/null || true)"

  echo
  echo "============================================================"
  echo "Данные для подключения"
  echo
  echo "Сохраните эти данные в безопасном месте."
  echo "Не отправляйте пароли, VLESS/Telegram ссылки и token в чаты или публичные логи."
  echo "============================================================"
  echo
  echo "АДРЕС ПАНЕЛИ 3x-ui:"
  echo "  https://${PRIMARY_DOMAIN}/${PANEL_PATH}/"
  echo
  if [[ -n "$basic_user" || -n "$basic_pass" ]]; then
    echo "BASIC AUTH ДЛЯ СТРАНИЦЫ ПАНЕЛИ:"
    echo "  Username: ${basic_user:-see $basic_note}"
    echo "  Password: ${basic_pass:-see $basic_note}"
    echo
  fi
  echo "ЛОГИН В 3x-ui:"
  echo "  Username: ${xui_user:-see $auto_note}"
  echo "  Password: ${xui_pass:-see $auto_note}"
  echo
  print_vless_links_from_xui "$auto_note"
  echo
  if uses_mtproto; then
    echo "ГОТОВАЯ TELEGRAM LINK ИЗ 3x-ui:"
    if [[ -n "$mtproto_link" ]]; then
      echo "  $mtproto_link"
    else
      echo "  Telegram link не найдена в 3x-ui DB. Проверьте Telegram proxy / MTG inbound."
    fi
    echo
  fi
  echo "ФАЙЛЫ С ДАННЫМИ НА СЕРВЕРЕ:"
  [[ -f "$basic_note" ]] && echo "  $basic_note"
  [[ -f "$auto_note" ]] && echo "  $auto_note"
  if uses_mtproto && mtproto_backend_is_alexbers; then
    [[ -f "$mt_users_note" ]] && echo "  $mt_users_note"
  fi
  echo
  echo "ПОЛЕЗНЫЕ КОМАНДЫ:"
  echo "  Открыть меню XPAM Script:          sudo ${SERVER_PREFIX}-xpam"
  echo "  Показать безопасную сводку:     sudo ${SERVER_PREFIX}-links"
  echo "  Показать VLESS-ссылки:           sudo ${SERVER_PREFIX}-vless"
  if uses_mtproto && mtproto_backend_is_alexbers; then
    echo "  Управление MTProto пользователями: sudo ${SERVER_PREFIX}-tg"
  fi
  echo "  Проверить состояние сервера:     sudo ${SERVER_PREFIX}-health"
  echo
  echo "============================================================"
}



print_install_done_summary(){
  echo
  echo "============================================================"
  echo "XPAM Script: сервер готов"
  echo
  echo "Секреты, пароли, VLESS и Telegram ссылки не печатаются в install-log."
  echo "Чтобы посмотреть данные подключения вручную, выполните:"
  echo "  sudo ${SERVER_PREFIX}-links"
  echo
  echo "Проверить состояние сервера:"
  echo "  sudo ${SERVER_PREFIX}-health"
  echo
  echo "Полная диагностика при проблемах:"
  echo "  sudo ${SERVER_PREFIX}-health --deep"
  echo
  echo "Защищённые заметки с секретами находятся в /root/secure-notes"
  echo "============================================================"
}

stage_finalize(){
  need_root
  require_os
  ensure_sudo_hostname_resolution
  load_config
  validate_inputs
  verify_ssh_preflight
  small_vm_resource_preflight
  ensure_swap_policy
  preinstall_system_update
  install_base_packages
  reboot_gate_before_finalize || exit 0
  fix_managed_hosts
  setup_dns_policy
  check_dns_preflight
  apply_network_tuning_policy
  install_mtproto_haproxy_packages
  setup_sites
  write_wait_for_port
  ensure_xui_ready_for_finalize
  verify_xui_manual_setup
  write_nginx_final
  mtproto_backend_install
  write_haproxy
  apply_service_nofile_limits
  /usr/local/sbin/check-network-tuning-policy || fail "network tuning policy check failed"
  write_certbot_hook
  write_health_weekly
  systemctl try-restart x-ui || true
  systemctl reload nginx || systemctl restart nginx
  uses_mtproto && { mtproto_backend_restart_runtime; systemctl restart haproxy; }
  . /usr/local/sbin/xpam-maint-common.sh
  xpam_config_snapshot "$SERVER_PREFIX" 4 || true
  apply_service_hygiene
  post_install_cleanup
  if confirm "Настроить Telegram уведомления сейчас?" no; then
    setup_notify_env || true
  fi
  echo
  warn "Финальная очистка удалит временные файлы установки, архивы, .sha256 и распакованную папку XPAM Script."
  warn "После очистки временная папка установки будет удалена автоматически. Если вы сейчас внутри неё, выполните: cd /root"
  local did_final_cleanup="no"
  if confirm "Выполнить финальную очистку перед production сейчас?" yes; then
    did_final_cleanup="yes"
    final_production_cleanup
  fi
  "/usr/local/sbin/${SERVER_PREFIX}-health" || fail "Final health check failed after optional steps"
  print_install_done_summary
  reboot_status_notice
  ok "Готово. Сервер выглядит рабочим."
  if [[ "$did_final_cleanup" == "yes" ]]; then
    rm -f /root/xpam-script-v*-*.log /root/xpam-script-*.log 2>/dev/null || true
  fi
  exit 0
}
stage_check_only(){ need_root; load_config; validate_inputs; verify_ssh_preflight; [[ -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]] && "/usr/local/sbin/${SERVER_PREFIX}-health" || verify_xui_manual_setup; }

warp_print_3xui_manual_steps(){
  echo "============================================================"
  echo "WARP через 3x-ui / Xray"
  echo "============================================================"
  echo
  echo "Что важно:"
  echo "  - XPAM НЕ ставит системный VPN на весь сервер."
  echo "  - WARP будет работать только как outbound внутри Xray."
  echo "  - SSH, DNS, apt, certbot, nginx, HAProxy и MTProto не пойдут через WARP."
  echo "  - Default route сервера не меняется."
  echo "  - WARP private key, reserved и license key нельзя отправлять в чат или логи."
  echo
  echo "------------------------------------------------------------"
  echo "Шаг 1. Создайте WARP outbound в панели 3x-ui"
  echo "------------------------------------------------------------"
  echo
  echo "Откройте панель:"
  echo "  https://${PRIMARY_DOMAIN}/${PANEL_PATH}/"
  echo
  echo "В панели 3x-ui:"
  echo "  1. Откройте: Настройки Xray -> Исходящие подключения."
  echo "  2. Нажмите кнопку: WARP."
  echo "  3. Обязательно нажмите: Add outbound."
  echo "  4. Нажмите: Сохранить."
  echo
  echo "Важно:"
  echo "  Если не нажать Add outbound, WARP outbound не будет создан."
  echo "  Ручной перезапуск Xray не нужен — XPAM сделает это сам."
  echo
  echo "------------------------------------------------------------"
  echo "Шаг 2. Что сделает XPAM после проверки"
  echo "------------------------------------------------------------"
  echo
  echo "XPAM проверит WARP outbound и приведёт его к безопасной схеме:"
  echo
  echo "  tag=warp"
  echo "  protocol=wireguard"
  echo "  mtu=1420"
  echo "  domainStrategy=ForceIPv4"
  echo "  workers=2"
  echo "  noKernelTun=false"
  echo "  address=IPv4-only"
  echo "  peer allowedIPs=0.0.0.0/0"
  echo "  peer keepAlive=25"
  echo
  echo "Также XPAM:"
  echo "  - создаст backup базы 3x-ui;"
  echo "  - восстановит стандартное правило YouTube -> warp, если оно отсутствует;"
  echo "  - не удалит пользовательские маршруты;"
  echo "  - не изменит default route сервера;"
  echo "  - не изменит DNS сервера."
  echo
  echo "------------------------------------------------------------"
  echo "Выберите действие"
  echo "------------------------------------------------------------"
  echo
}

xui_warp_youtube_fix(){
  local db backup_dir backup expected_port
  db="/etc/x-ui/x-ui.db"
  xui_assert_sqlite_backend
  [[ -s "$db" ]] || fail "3x-ui DB не найден: $db"
  expected_port="$(expected_xray_port)"
  backup_dir="/root/manual-backups/xui-warp-normalize"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  backup="${backup_dir}/x-ui.db.$(date +%Y%m%d-%H%M%S)"
  cp -a "$db" "$backup" || fail "Не удалось создать backup 3x-ui DB"
  chmod 600 "$backup" 2>/dev/null || true
  ok "Backup 3x-ui DB создан: $backup"
  prune_keep_latest "$backup_dir" "x-ui.db.*" 4

  export XPAM_XUI_DB="$db" XPAM_EXPECTED_XRAY_PORT="$expected_port"
  python3 <<'PY_XUI_WARP_FIX'
import json, os, sqlite3, sys
from pathlib import Path

db=Path(os.environ['XPAM_XUI_DB'])
expected_port=int(os.environ['XPAM_EXPECTED_XRAY_PORT'])

youtube_domains=[
  'domain:youtube.com',
  'domain:youtu.be',
  'domain:yt.be',
  'domain:youtube-nocookie.com',
  'domain:youtubekids.com',
  'domain:youtubeeducation.com',
  'domain:googlevideo.com',
  'domain:ytimg.com',
  'domain:ggpht.com',
  'domain:youtubei.googleapis.com',
  'domain:youtube.googleapis.com',
  'domain:youtubeembeddedplayer.googleapis.com',
  'domain:jnn-pa.googleapis.com',
  'domain:youtube-ui.l.google.com',
  'domain:wide-youtube.l.google.com',
  'domain:ytimg.l.google.com',
  'domain:ytstatic.l.google.com',
  'full:yt3.googleusercontent.com',
]

def fail(msg):
    print('ERROR:', msg, file=sys.stderr)
    sys.exit(1)

def ok(msg):
    print('OK:', msg)

conn=sqlite3.connect(str(db))
cur=conn.cursor()
row=cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
if not row or not row[0]:
    fail("setting xrayTemplateConfig не найден в 3x-ui DB. Сначала создайте WARP outbound в 3x-ui.")
try:
    cfg=json.loads(row[0])
except Exception as e:
    fail(f"xrayTemplateConfig не является валидным JSON: {e}")

outbounds=cfg.setdefault('outbounds', [])
wg=[ob for ob in outbounds if isinstance(ob, dict) and ob.get('protocol')=='wireguard']
if not wg:
    fail("WireGuard/WARP outbound не найден. Сначала создайте WARP outbound в панели 3x-ui.")

warp=[ob for ob in wg if ob.get('tag')=='warp']
if not warp:
    if len(wg)==1:
        wg[0]['tag']='warp'
        warp=[wg[0]]
        ok("единственный WireGuard outbound переименован в tag=warp")
    else:
        fail("найдено несколько WireGuard outbound, но ни один не имеет tag=warp. Назовите нужный outbound 'warp' в 3x-ui и запустите проверку снова.")

ob=warp[0]
settings=ob.setdefault('settings', {})
settings['mtu']=1420
settings['workers']=2
settings['domainStrategy']='ForceIPv4'
settings['noKernelTun']=False

addrs=settings.get('address') or []
if not isinstance(addrs, list):
    addrs=[str(addrs)]
ipv4=[a for a in addrs if isinstance(a, str) and ':' not in a and '/' in a]
if not ipv4:
    fail("у WARP outbound нет IPv4 address вида 172.16.x.x/32. Создайте WARP outbound в 3x-ui корректно и повторите.")
settings['address']=ipv4

peers=settings.get('peers') or []
if not isinstance(peers, list) or not peers or not isinstance(peers[0], dict):
    fail("у WARP outbound нет peer. Создайте WARP outbound в 3x-ui корректно и повторите.")
peers[0]['allowedIPs']=['0.0.0.0/0']
peers[0]['keepAlive']=25
settings['peers']=peers
def valid_reserved(v):
    return isinstance(v, list) and len(v)==3 and all(isinstance(x, int) and 0 <= x <= 255 for x in v)
if valid_reserved(settings.get('reserved')) or valid_reserved(peers[0].get('reserved')):
    ok("WARP reserved bytes сохранены")
elif 'cloudflareclient.com' in str(peers[0].get('endpoint') or '').lower():
    print("WARNING: WARP reserved bytes отсутствуют. XPAM их не генерирует и не выдумывает; если текущий 3x-ui создал WARP без reserved, health покажет WARN.")
ok("WARP outbound приведён к настройкам XPAM Script")

routing=cfg.setdefault('routing', {})
rules=routing.setdefault('rules', [])
if not isinstance(rules, list):
    rules=[]
    routing['rules']=rules

# Routing rules are user-managed for health/weekly purposes. However this menu
# action is an explicit user request to normalize WARP and restore XPAM Script's
# default YouTube -> warp routing preset if it is missing. Custom user routes
# must be preserved.
default_domains=list(youtube_domains)
default_set=set(default_domains)

default_rule=None
for r in rules:
    if not isinstance(r, dict):
        continue
    if r.get('outboundTag')!='warp':
        continue
    domains=r.get('domain')
    if not isinstance(domains, list):
        continue
    if any(str(d) in default_set for d in domains):
        default_rule=r
        break

if default_rule is None:
    rules.append({'type':'field','domain':default_domains,'outboundTag':'warp'})
    ok("default YouTube routing rule -> outboundTag=warp добавлено; пользовательские маршруты не изменены")
else:
    domains=list(default_rule.get('domain') or [])
    added=0
    for d in default_domains:
        if d not in domains:
            domains.append(d)
            added += 1
    default_rule['domain']=domains
    if added:
        ok(f"default YouTube routing rule -> outboundTag=warp обновлено; добавлено {added} domain(s); пользовательские маршруты не изменены")
    else:
        ok("default YouTube routing rule -> outboundTag=warp уже есть; пользовательские маршруты не изменены")

warp_route_count=sum(1 for r in rules if isinstance(r, dict) and r.get('outboundTag')=='warp')
ok(f"3x-ui routing is user-managed; after default restore found {warp_route_count} rule(s) to outboundTag=warp; health does not validate route contents")

# Enable sniffing routeOnly for the VLESS inbound that XPAM Script uses.
try:
    cols=[r[1] for r in cur.execute('PRAGMA table_info(inbounds)').fetchall()]
    if {'id','port','protocol','sniffing'} <= set(cols):
        rows=cur.execute("SELECT id, sniffing FROM inbounds WHERE protocol='vless' AND port=?", (expected_port,)).fetchall()
        sniff={"enabled": True, "destOverride": ["http","tls","quic"], "metadataOnly": False, "routeOnly": True}
        for inbound_id, _old in rows:
            cur.execute("UPDATE inbounds SET sniffing=? WHERE id=?", (json.dumps(sniff, separators=(',',':')), inbound_id))
        if rows:
            ok(f"sniffing Route only включён для VLESS inbound port {expected_port}")
        else:
            print(f"WARNING: VLESS inbound port {expected_port} не найден в 3x-ui DB")
except Exception as e:
    print(f"WARNING: не удалось обновить sniffing в inbounds: {e}")

cur.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(cfg, ensure_ascii=False, separators=(',',':')),))
conn.commit()
conn.close()
ok("3x-ui xrayTemplateConfig сохранён")
PY_XUI_WARP_FIX

  warn "Сейчас будет перезапущен 3x-ui/Xray. Если ваша SSH-сессия идёт через этот же VLESS/прокси, соединение может оборваться. Это не означает поломку сервера: после переподключения выполните sudo ${SERVER_PREFIX}-health."
  say "Перезапускаем 3x-ui, чтобы Xray перечитал конфигурацию"
  systemctl restart x-ui || fail "x-ui restart failed after WARP update"
  sleep 5
  write_wait_for_port
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 30 xui-panel
  wait_for_xray_vless 30
  if [[ -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]]; then
    run_health_quiet "warp-3xui-update" || fail "Health check failed after WARP 3x-ui update"
  fi
  ok "WARP в 3x-ui настроен успешно"
}

stage_warp_3xui_youtube(){
  need_root
  load_config
  validate_inputs
  warp_print_3xui_manual_steps
  echo "1) Я создал WARP outbound в 3x-ui — проверить и настроить"
  echo "2) Выйти без изменений"
  local choice
  read -r -p "Выберите пункт [1-2]: " choice || true
  case "$choice" in
    1) xui_warp_youtube_fix ;;
    2) return 0 ;;
    *) fail "Неизвестный пункт меню" ;;
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
  echo "2) Выйти"
  local choice
  read -r -p "Выберите пункт [1-2]: " choice || true
  case "$choice" in
    1) stage_warp_3xui_youtube ;;
    2) return 0 ;;
    *) fail "Неизвестный пункт меню" ;;
  esac
}

print_vless_summary(){
  local auto_note
  auto_note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"

  echo
  echo "============================================================"
  echo "VLESS-подключение"
  echo "============================================================"
  echo
  echo "Эта команда по умолчанию НЕ печатает VLESS-ссылку, чтобы случайно не раскрыть доступ."
  echo "Добавлять, удалять и менять VLESS-пользователей нужно в панели 3x-ui."
  echo
  echo "Панель 3x-ui:"
  echo "  https://${PRIMARY_DOMAIN}/${PANEL_PATH}/"
  echo
  echo "VLESS-ссылки формируются из актуальной базы 3x-ui при каждом выводе."
  echo
  echo "Показать VLESS-ссылки на экран:"
  echo "  sudo ${SERVER_PREFIX}-vless --show"
  echo
  echo "Все данные подключения:"
  echo "  sudo ${SERVER_PREFIX}-links"
  echo "============================================================"
}

stage_vless_direct(){
  need_root
  load_config
  validate_inputs
  case "${1:-}" in
    --show)
      warn "Ниже будут показаны приватные VLESS-ссылки из 3x-ui. Не отправляйте их в публичные чаты, тикеты, скриншоты и логи."
      if ! print_vless_links_from_xui "/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"; then
        fail "VLESS-ссылки не найдены. Проверьте 3x-ui или выполните: sudo ${SERVER_PREFIX}-health --deep"
      fi
      ;;
    --file)
      warn "VLESS-ссылки больше не хранятся как source-of-truth файл. Используйте: sudo ${SERVER_PREFIX}-vless --show"
      ;;
    ""|--help|-h)
      print_vless_summary
      ;;
    *)
      fail "Неизвестный параметр. Используйте: sudo ${SERVER_PREFIX}-vless или sudo ${SERVER_PREFIX}-vless --show"
      ;;
  esac
}

stage_links_direct(){
  need_root
  load_config
  validate_inputs
  case "${1:-}" in
    --show-secrets)
      warn "Сейчас будут показаны пароли, VLESS/Telegram ссылки и другие секреты."
      warn "Не отправляйте этот вывод в чаты, тикеты, скриншоты или публичные логи."
      if confirm "Показать секреты на экран?" no; then
        print_connection_secrets_summary
      else
        echo "Отменено. Безопасная сводка:"
        print_connection_summary
      fi
      ;;
    ""|--safe|--help|-h)
      print_connection_summary
      ;;
    *)
      fail "Неизвестный параметр. Используйте: sudo ${SERVER_PREFIX}-links или sudo ${SERVER_PREFIX}-links --show-secrets"
      ;;
  esac
}

stage_show_details(){
  need_root
  load_config
  validate_inputs
  echo
  echo "Данные для подключения"
  echo "1) Показать безопасную сводку без секретов"
  echo "2) Показать секреты на экран"
  if uses_mtproto && mtproto_backend_is_alexbers; then
    echo "3) MTProto-пользователи"
    echo "4) Выйти"
    local choice
    read -r -p "Выберите пункт [1-4]: " choice || true
    case "$choice" in
      1) print_connection_summary ;;
      2) stage_links_direct --show-secrets ;;
      3) stage_mtproto_users_menu ;;
      4) return 0 ;;
      *) fail "Неизвестный пункт меню" ;;
    esac
  else
    echo "3) Выйти"
    local choice
    read -r -p "Выберите пункт [1-3]: " choice || true
    case "$choice" in
      1) print_connection_summary ;;
      2) stage_links_direct --show-secrets ;;
      3) return 0 ;;
      *) fail "Неизвестный пункт меню" ;;
    esac
  fi
}


stage_install_continue(){
  need_root
  maybe_import_existing_config || true
  if [[ ! -f "$CONFIG_FILE" ]]; then
    load_prefix_bootstrap || true
    stage_prepare
    exit 0
  fi
  load_config
  validate_inputs

  if [[ -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]]; then
    say "Сервер уже установлен"
    "/usr/local/sbin/${SERVER_PREFIX}-health" || fail "Health check failed"
    echo "Данные подключения не печатаются в install-log. Для просмотра выполните: sudo ${SERVER_PREFIX}-links"
    exit 0
  fi

  if [[ ! -s "$PREPARE_DONE_FILE" ]]; then
    warn "Предыдущая установка не завершила первый этап. Повторяю подготовку сервера с сохранённой конфигурацией."
    XPAM_REUSE_CONFIG=yes stage_prepare
    exit 0
  fi

  stage_finalize
  exit 0
}



stage_repair(){
  need_root
  ensure_sudo_hostname_resolution
  load_config
  validate_inputs
  echo "============================================================"
  echo "Repair: восстановление XPAM-обвязки"
  echo "============================================================"
  echo
  echo "Что делает repair: восстанавливает команды XPAM, health/weekly, service limits,"
  echo "startup order, fail2ban policy, certbot hook и service hygiene."
  echo
  echo "Что repair НЕ делает: не меняет домены, VLESS UUID, Telegram secret,"
  echo "не удаляет пользователей и не переписывает /etc/network/interfaces."
  echo
  say "Repair XPAM service policy"
  install_runtime_kit || true
  write_install_launcher || true
  verify_ssh_preflight || true
  setup_dns_policy || true
  apply_network_tuning_policy || true
  apply_service_nofile_limits || true
  write_wait_for_port || true
  write_certbot_hook || true
  write_health_weekly || true
  xui_assert_sqlite_backend
  xui_ensure_api_token || true
  xui_enforce_direct_ipv4_bind || true
  apply_service_hygiene || true
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || systemctl restart nginx || true
  systemctl try-restart x-ui || true
  if uses_mtproto; then
    mtproto_backend_repair_after_update || true
    write_haproxy || systemctl try-reload-or-restart haproxy || true
  fi
  run_health_quiet "repair" || fail "Repair завершён, но health-check всё ещё показывает проблемы"
  ok "Repair завершён"
}

stage_netdiag(){
  need_root
  load_config || true
  echo "============================================================"
  echo "Диагностика сети Debian/провайдера"
  echo "============================================================"
  echo
  echo "Эта команда ничего не чинит автоматически. Она собирает диагностику DNS,"
  echo "маршрутов, networking.service и сетевых конфигов в отдельный лог-файл."
  echo "Файл может содержать IP-адреса, gateway, DNS и домены."
  echo
  local ts dir log
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="/var/log/xpam-script/netdiag/${SERVER_PREFIX:-server}-${ts}"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  log="$dir/netdiag.txt"
  {
    echo "XPAM Script network diagnostics"
    date
    hostname -f 2>/dev/null || hostname
    echo
    echo "===== OS ====="; cat /etc/os-release 2>/dev/null || true
    echo
    echo "===== FAILED SYSTEMD UNITS ====="; systemctl --failed --no-pager || true
    echo
    echo "===== networking.service ====="; systemctl --no-pager --full status networking 2>&1 || true
    echo
    echo "===== networking.service journal ====="; journalctl -u networking -b --no-pager -n 200 2>&1 || true
    echo
    echo "===== ip link ====="; ip -br link 2>&1 || true
    echo
    echo "===== ip addr ====="; ip -4 addr 2>&1 || true
    echo
    echo "===== ip route ====="; ip -4 route 2>&1 || true
    echo
    echo "===== ip route get 1.1.1.1 ====="; ip route get 1.1.1.1 2>&1 || true
    echo
    echo "===== /etc/network/interfaces ====="; sed -n '1,220p' /etc/network/interfaces 2>&1 || true
    echo
    echo "===== /etc/network/interfaces.d ====="; find /etc/network/interfaces.d -maxdepth 1 -type f -print -exec sed -n '1,220p' {} \; 2>&1 || true
    echo
    echo "===== resolvectl status ====="; timeout 5s resolvectl status 2>&1 || true
    echo
    echo "===== DNS check ====="; /usr/local/sbin/check-dns-policy.sh 2>&1 || true
  } > "$log"
  chmod 600 "$log" 2>/dev/null || true
  ok "Диагностика сети сохранена: $log"
  echo "Файл может содержать IP-адреса и имена доменов. Не публикуйте его без проверки."
}

stage_advanced_menu(){
  echo
  echo "Дополнительно"
  echo "0) SSH-безопасность / создать prefix-команду"
  echo "1) Подробная health-диагностика"
  echo "2) Диагностика сети Debian/провайдера"
  echo "3) Repair: восстановить XPAM service policy"
  echo "4) Финальная production-очистка"
  echo "5) Показать текущую конфигурацию"
  echo "6) Проверить обновления XPAM"
  echo "7) Выйти"
  local choice
  read -r -p "Выберите пункт [0-7]: " choice
  case "$choice" in
    0) stage_ssh_hardening ;;
    1) need_root; load_config; "/usr/local/sbin/${SERVER_PREFIX}-health" --deep ;;
    2) stage_netdiag ;;
    3) stage_repair ;;
    4) final_production_cleanup ;;
    5) show_config ;;
    6) xpam_update_menu ;;
    7) return 0 ;;
    *) fail "Неизвестный пункт меню" ;;
  esac
}

main_menu(){
  need_root
  printf '\033[0m'
  echo "XPAM Script ${KIT_VERSION}"
  echo "0) SSH-безопасность / создать prefix-команду"
  echo "1) Установить / продолжить настройку сервера"
  echo "2) Показать данные для подключения"
  echo "3) Проверить состояние сервера"
  echo "4) Telegram-уведомления"
  echo "5) WARP через 3x-ui/Xray"
  echo "6) DoubleHop Mode"
  echo "7) Управление сайтами"
  echo "8) Дополнительно"
  echo "9) Выход"
  echo
  if [[ ! -s /etc/xpam-script/prefix.env ]]; then
    echo "Первый запуск? Сначала выберите пункт 0."
  fi
  local choice
  read -r -p "Выберите пункт [0-9]: " choice
  case "$choice" in
    0) stage_ssh_hardening ;;
    1) stage_install_continue ;;
    2) stage_show_details ;;
    3) stage_check_only ;;
    4) stage_notify ;;
    5) stage_warp_menu ;;
    6) stage_doublehop_menu ;;
    7) stage_site_menu ;;
    8) stage_advanced_menu ;;
    9) exit 0 ;;
    a|A) stage_prepare ;;
    b|B) stage_finalize ;;
    *) fail "Неизвестный пункт меню" ;;
  esac
  exit 0
}

# Source feature modules after defining base core helpers. Modules must only define
# functions at source time; install/menu execution starts from install.sh after this file
# has been fully sourced. xpam-xui.sh is intentionally sourced last because it acts as
# the 3x-ui compatibility layer and may override volatile upstream integration points.
for _xpam_lib in \
  "$KIT_DIR/scripts/lib/xpam-launchers.sh" \
  "$KIT_DIR/scripts/lib/xpam-maintenance.sh" \
  "$KIT_DIR/scripts/lib/xpam-notify.sh" \
  "$KIT_DIR/scripts/lib/xpam-update.sh" \
  "$KIT_DIR/scripts/lib/xpam-mtproto.sh" \
  "$KIT_DIR/scripts/lib/xpam-doublehop.sh" \
  "$KIT_DIR/scripts/lib/xpam-sites.sh" \
  "$KIT_DIR/scripts/lib/xpam-xui.sh"
do
  if [[ -f "$_xpam_lib" ]]; then
    # shellcheck source=/dev/null
    source "$_xpam_lib"
  fi
done
unset _xpam_lib
