#!/usr/bin/env bash
set -Eeuo pipefail

KIT_VERSION="v1.1.0"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="/etc/xpam-script"
CONFIG_FILE="${CONFIG_DIR}/config.env"
PREFIX_BOOTSTRAP_FILE="${CONFIG_DIR}/prefix.env"
LOG="/root/xpam-script-${KIT_VERSION}-$(date +%F-%H%M%S).log"
RUNTIME_KIT_DIR="/opt/xpam-script"
PREPARE_DONE_FILE="${CONFIG_DIR}/stage-prepare.done"


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
  if run_with_heartbeat "APT operation: $context" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=180 "$@" > >(tee "$log") 2>&1; then
    rm -f "$log"
    return 0
  fi
  if grep -Eiq 'dpkg was interrupted|Could not get lock|Unable to acquire the dpkg frontend lock|dpkg frontend lock is locked' "$log" 2>/dev/null; then
    warn "APT reported interrupted dpkg or lock during $context; trying recovery and one retry"
    rm -f "$log"
    apt_dpkg_recovery "$context retry"
    run_with_heartbeat "APT retry: $context" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=180 "$@"
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
PANEL_PATH="api/internal/storage"; XUI_PANEL_PORT="57827"; XUI_AUTO_SETUP="yes"; XUI_ADMIN_USER="vlessuser"; XUI_ADMIN_PASS="${XUI_ADMIN_PASS:-}"; XUI_INSTALLED_TAG=""; XRAY_PUBLIC_PORT="443"; XRAY_LOCAL_PORT="1443"; SSH_PUBLIC_PORT="22"; HTTP_PUBLIC_PORT="80"; SITE_BACKEND_PORT="8080"; SYNC_BACKEND_PORT="9443"; MTPROTO_PORT="47827"; ALLOW_IPV6_443="no"; BASIC_USER="admin"
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
web_cert_name(){ [[ -n "$WEB_CERT_NAME" ]] && echo "$WEB_CERT_NAME" || echo "$PRIMARY_DOMAIN"; }
expected_xray_port(){ uses_haproxy && echo "$XRAY_LOCAL_PORT" || echo "$XRAY_PUBLIC_PORT"; }
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

write_install_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0

  local safe_prefix launcher bin_link kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"

  [[ -n "$safe_prefix" ]] || fail "SERVER_PREFIX is empty; cannot create install launcher"
  [[ "$safe_prefix" == "$SERVER_PREFIX" ]] || fail "SERVER_PREFIX contains unsupported chars for launcher command: $SERVER_PREFIX"

  launcher="/usr/local/sbin/${safe_prefix}-install"
  bin_link="/usr/local/bin/${safe_prefix}-install"
  kit_dir_real="$RUNTIME_KIT_DIR"

  cat > "$launcher" <<EOF_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

LAUNCHER="/usr/local/sbin/${safe_prefix}-install"
KIT_DIR="${kit_dir_real}"

if [ "\$(id -u)" -ne 0 ]; then
  exec sudo "\$LAUNCHER" "\$@"
fi

if [ ! -f "\$KIT_DIR/install.sh" ]; then
  echo "ERROR: XPAM Script runtime is missing: \$KIT_DIR/install.sh" >&2
  echo "Re-upload the XPAM Script archive or restore /opt/xpam-script." >&2
  exit 1
fi

cd "\$KIT_DIR"
exec bash ./install.sh "\$@"
EOF_LAUNCHER

  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true

  ok "Install launcher created: sudo ${safe_prefix}-install"
}

write_health_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0
  local safe_prefix health bin_link
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"
  [[ -n "$safe_prefix" && "$safe_prefix" == "$SERVER_PREFIX" ]] || return 0
  health="/usr/local/sbin/${safe_prefix}-health"
  bin_link="/usr/local/bin/${safe_prefix}-health"
  if [[ -x "$health" ]]; then
    ln -sf "$health" "$bin_link" 2>/dev/null || true
    ok "Health command available: sudo ${safe_prefix}-health"
  fi
}



write_repair_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0
  local safe_prefix launcher bin_link kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"
  launcher="/usr/local/sbin/${safe_prefix}-repair"
  bin_link="/usr/local/bin/${safe_prefix}-repair"
  kit_dir_real="$RUNTIME_KIT_DIR"
  cat > "$launcher" <<EOF_REPAIR_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
LAUNCHER="/usr/local/sbin/${safe_prefix}-repair"
KIT_DIR="${kit_dir_real}"
if [ "\$(id -u)" -ne 0 ]; then exec sudo "\$LAUNCHER" "\$@"; fi
if [ ! -f "\$KIT_DIR/scripts/xpam-core.sh" ]; then
  echo "ERROR: XPAM Script runtime missing: \$KIT_DIR/scripts/xpam-core.sh" >&2
  exit 1
fi
export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
# shellcheck source=/dev/null
source "\$KIT_DIR/scripts/xpam-core.sh"
stage_repair
EOF_REPAIR_LAUNCHER
  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true
  ok "Repair-команда доступна: sudo ${safe_prefix}-repair"
}

write_netdiag_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0
  local safe_prefix launcher bin_link kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"
  launcher="/usr/local/sbin/${safe_prefix}-netdiag"
  bin_link="/usr/local/bin/${safe_prefix}-netdiag"
  kit_dir_real="$RUNTIME_KIT_DIR"
  cat > "$launcher" <<EOF_NETDIAG_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
LAUNCHER="/usr/local/sbin/${safe_prefix}-netdiag"
KIT_DIR="${kit_dir_real}"
if [ "\$(id -u)" -ne 0 ]; then exec sudo "\$LAUNCHER" "\$@"; fi
if [ ! -f "\$KIT_DIR/scripts/xpam-core.sh" ]; then
  echo "ERROR: XPAM Script runtime missing: \$KIT_DIR/scripts/xpam-core.sh" >&2
  exit 1
fi
export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
# shellcheck source=/dev/null
source "\$KIT_DIR/scripts/xpam-core.sh"
stage_netdiag
EOF_NETDIAG_LAUNCHER
  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true
  ok "Диагностика сети доступна: sudo ${safe_prefix}-netdiag"
}

write_weekly_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0
  local safe_prefix weekly bin_link
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"
  [[ -n "$safe_prefix" && "$safe_prefix" == "$SERVER_PREFIX" ]] || return 0
  weekly="/usr/local/sbin/${safe_prefix}-weekly-maintenance.sh"
  bin_link="/usr/local/bin/${safe_prefix}-weekly-maintenance"
  if [[ -x "$weekly" ]]; then
    ln -sf "$weekly" "$bin_link" 2>/dev/null || true
    ok "Weekly maintenance is configured for automatic weekly run"
  fi
}

write_links_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0

  local safe_prefix launcher bin_link kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"

  [[ -n "$safe_prefix" ]] || fail "SERVER_PREFIX is empty; cannot create links launcher"
  [[ "$safe_prefix" == "$SERVER_PREFIX" ]] || fail "SERVER_PREFIX contains unsupported chars for launcher command: $SERVER_PREFIX"

  launcher="/usr/local/sbin/${safe_prefix}-links"
  bin_link="/usr/local/bin/${safe_prefix}-links"
  kit_dir_real="$RUNTIME_KIT_DIR"

  cat > "$launcher" <<EOF_LINKS_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

LAUNCHER="/usr/local/sbin/${safe_prefix}-links"
KIT_DIR="${kit_dir_real}"

if [ "\$(id -u)" -ne 0 ]; then
  exec sudo "\$LAUNCHER" "\$@"
fi

if [ ! -f "\$KIT_DIR/scripts/xpam-core.sh" ]; then
  echo "ERROR: XPAM Script runtime is missing: \$KIT_DIR/scripts/xpam-core.sh" >&2
  echo "Re-upload the XPAM Script archive or restore /opt/xpam-script." >&2
  exit 1
fi

export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
# shellcheck source=/dev/null
source "\$KIT_DIR/scripts/xpam-core.sh"
stage_links_direct "\$@"
EOF_LINKS_LAUNCHER

  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true

  ok "Connection data command available: sudo ${safe_prefix}-links"
}

write_telega_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0

  local safe_prefix launcher bin_link kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"

  [[ -n "$safe_prefix" ]] || fail "SERVER_PREFIX is empty; cannot create telega launcher"
  [[ "$safe_prefix" == "$SERVER_PREFIX" ]] || fail "SERVER_PREFIX contains unsupported chars for launcher command: $SERVER_PREFIX"

  launcher="/usr/local/sbin/${safe_prefix}-telega"
  bin_link="/usr/local/bin/${safe_prefix}-telega"
  kit_dir_real="$RUNTIME_KIT_DIR"

  cat > "$launcher" <<EOF_TELEGA_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

LAUNCHER="/usr/local/sbin/${safe_prefix}-telega"
KIT_DIR="${kit_dir_real}"

if [ "\$(id -u)" -ne 0 ]; then
  exec sudo "\$LAUNCHER" "\$@"
fi

if [ ! -f "\$KIT_DIR/scripts/xpam-core.sh" ]; then
  echo "ERROR: XPAM Script runtime is missing: \$KIT_DIR/scripts/xpam-core.sh" >&2
  echo "Re-upload the XPAM Script archive or restore /opt/xpam-script." >&2
  exit 1
fi

export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
# shellcheck source=/dev/null
source "\$KIT_DIR/scripts/xpam-core.sh"
stage_telega_direct "\$@"
EOF_TELEGA_LAUNCHER

  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true

  ok "MTProto users command available: sudo ${safe_prefix}-telega"
}

write_vless_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0

  local safe_prefix launcher bin_link kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"

  [[ -n "$safe_prefix" ]] || fail "SERVER_PREFIX is empty; cannot create vless launcher"
  [[ "$safe_prefix" == "$SERVER_PREFIX" ]] || fail "SERVER_PREFIX contains unsupported chars for launcher command: $SERVER_PREFIX"

  launcher="/usr/local/sbin/${safe_prefix}-vless"
  bin_link="/usr/local/bin/${safe_prefix}-vless"
  kit_dir_real="$RUNTIME_KIT_DIR"

  cat > "$launcher" <<EOF_VLESS_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

LAUNCHER="/usr/local/sbin/${safe_prefix}-vless"
KIT_DIR="${kit_dir_real}"

if [ "\$(id -u)" -ne 0 ]; then
  exec sudo "\$LAUNCHER" "\$@"
fi

if [ ! -f "\$KIT_DIR/scripts/xpam-core.sh" ]; then
  echo "ERROR: XPAM Script runtime is missing: \$KIT_DIR/scripts/xpam-core.sh" >&2
  echo "Re-upload the XPAM Script archive or restore /opt/xpam-script." >&2
  exit 1
fi

export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
# shellcheck source=/dev/null
source "\$KIT_DIR/scripts/xpam-core.sh"
stage_vless_direct "\$@"
EOF_VLESS_LAUNCHER

  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true

  ok "VLESS links command available: sudo ${safe_prefix}-vless"
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
      for v in PROFILE SERVER_PREFIX ROOT_DOMAIN WWW_DOMAIN PRIMARY_DOMAIN SYNC_DOMAIN WEB_CERT_NAME CERT_EMAIL PANEL_PATH XUI_PANEL_PORT XUI_AUTO_SETUP XUI_ADMIN_USER XUI_INSTALLED_TAG XRAY_PUBLIC_PORT XRAY_LOCAL_PORT SSH_PUBLIC_PORT HTTP_PUBLIC_PORT SITE_BACKEND_PORT SYNC_BACKEND_PORT MTPROTO_PORT ALLOW_IPV6_443 BASIC_USER MTPROTO_REPO_URL MTPROTO_REPO_BRANCH TELEGRAM_RELAY_PATH TELEGRAM_RELAY_SOCKET XPAM_DNS_POLICY_MODE XPAM_OUTPUT_MODE XPAM_MAINT_APT_MODE XPAM_SERVICE_HYGIENE_MODE XPAM_BACKUP_KEEP XPAM_HEALTH_LOG_KEEP XPAM_WEEKLY_LOG_KEEP XPAM_PROVIDER_NETWORKING_WARN_ONLY; do
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
  validate_server_prefix
  {
    echo "# Managed by xpam-script ${KIT_VERSION}"
    for v in PROFILE SERVER_PREFIX ROOT_DOMAIN WWW_DOMAIN PRIMARY_DOMAIN SYNC_DOMAIN WEB_CERT_NAME CERT_EMAIL PANEL_PATH XUI_PANEL_PORT XUI_AUTO_SETUP XUI_ADMIN_USER XUI_INSTALLED_TAG XRAY_PUBLIC_PORT XRAY_LOCAL_PORT SSH_PUBLIC_PORT HTTP_PUBLIC_PORT SITE_BACKEND_PORT SYNC_BACKEND_PORT MTPROTO_PORT ALLOW_IPV6_443 BASIC_USER MTPROTO_REPO_URL MTPROTO_REPO_BRANCH TELEGRAM_RELAY_PATH TELEGRAM_RELAY_SOCKET XPAM_DNS_POLICY_MODE XPAM_OUTPUT_MODE XPAM_MAINT_APT_MODE XPAM_SERVICE_HYGIENE_MODE XPAM_BACKUP_KEEP XPAM_HEALTH_LOG_KEEP XPAM_WEEKLY_LOG_KEEP XPAM_PROVIDER_NETWORKING_WARN_ONLY; do
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
  write_telega_launcher || true
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
  export PROFILE SERVER_PREFIX ROOT_DOMAIN WWW_DOMAIN PRIMARY_DOMAIN SYNC_DOMAIN WEB_CERT_NAME CERT_EMAIL PANEL_PATH XUI_PANEL_PORT XUI_AUTO_SETUP XUI_ADMIN_USER XUI_INSTALLED_TAG XRAY_PUBLIC_PORT XRAY_LOCAL_PORT SSH_PUBLIC_PORT HTTP_PUBLIC_PORT SITE_BACKEND_PORT SYNC_BACKEND_PORT MTPROTO_PORT ALLOW_IPV6_443 BASIC_USER MTPROTO_REPO_URL MTPROTO_REPO_BRANCH TELEGRAM_RELAY_PATH TELEGRAM_RELAY_SOCKET XPAM_DNS_POLICY_MODE XPAM_OUTPUT_MODE XPAM_MAINT_APT_MODE XPAM_SERVICE_HYGIENE_MODE XPAM_BACKUP_KEEP XPAM_HEALTH_LOG_KEEP XPAM_WEEKLY_LOG_KEEP XPAM_PROVIDER_NETWORKING_WARN_ONLY
  export WEB_SERVER_NAMES="$(web_domains)" CERTONLY_SERVER_NAMES="$(web_domains)${SYNC_DOMAIN:+ $SYNC_DOMAIN}" SERVICE_SITE_DIR="$(service_site_dir)" ROOT_SITE_DIR="$(root_site_dir)" SERVER_PREFIX_UP="$(printf '%s' "$SERVER_PREFIX" | tr '[:lower:]' '[:upper:]')"
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
    export MTPROTO_HEALTH_BLOCK=$'check_active haproxy
check_active mtprotoproxy
haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 && echo "OK: haproxy config" || warn_fail "haproxy config failed"
check_http "'"$SYNC_DOMAIN"$'/health" 200 "https://'"$SYNC_DOMAIN"$'/health"
check_http "'"$SYNC_DOMAIN"$'/v1" 401 "https://'"$SYNC_DOMAIN"$'/v1"
_haproxy_since="$(systemctl show -p ActiveEnterTimestamp --value haproxy.service 2>/dev/null || true)"
if [ -z "$_haproxy_since" ]; then _haproxy_since="now"; fi
if journalctl -u haproxy -u mtprotoproxy --since "$_haproxy_since" --no-pager 2>/dev/null \
  | grep -Eiv "Current worker .*exited with code 143|Exiting Master process|All workers exited|Deactivated successfully|Stopping haproxy.service|Stopped haproxy.service|Started haproxy.service|Starting haproxy.service|Loading success|New worker|haproxy version is|path to executable is" \
  | grep -Eiq "no server available|backend be_mtproto has no server|backend be_xray has no server|Layer4 connection problem|Connection refused|Bad secret|Changing it to [0-9a-fA-F]{32}|failed|error"; then warn_fail "HAProxy/MTProto startup errors found"; else echo "OK: no HAProxy/MTProto startup errors in current HAProxy activation journal"; fi'
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

  echo "Команда меню создана: sudo ${SERVER_PREFIX}-install"
  echo
  echo "Не закрывайте рабочую SSH-сессию до завершения установки."
  echo
  if confirm "Продолжить установку XPAM сейчас?" yes; then
    stage_install_continue
  else
    echo "Позже выполните: sudo ${SERVER_PREFIX}-install"
  fi
}
preinstall_system_update(){
  say "Updating repositories and upgrading existing packages before installation"
  apt_dpkg_recovery "preinstall"
  write_common_library
  # shellcheck source=/usr/local/sbin/xpam-maint-common.sh
  . /usr/local/sbin/xpam-maint-common.sh
  xpam_release_upgrade_guard || warn "release-upgrade guard returned non-zero"
  xpam_guarded_full_upgrade "preinstall" || fail "Pre-install apt full-upgrade failed"
}
install_base_packages(){
  say "Installing base packages"
  apt_dpkg_recovery "base packages"
  apt_get_safe "apt update before base packages" update
  apt_get_safe "base package install" install -y --no-install-recommends ca-certificates curl wget gnupg lsb-release unzip tar gzip cron ufw fail2ban python3-systemd nginx certbot openssl python3 python3-venv xxd systemd-sysv rsync sqlite3 jq dnsutils openssh-client iproute2
  systemctl enable --now certbot.timer 2>/dev/null || true
}

install_mtproto_haproxy_packages(){
  if uses_mtproto; then
    say "Installing HAProxy/MTProto dependencies"
    apt_dpkg_recovery "HAProxy/MTProto package install"
    apt_get_safe "apt update before HAProxy/MTProto packages" update
    apt_get_safe "HAProxy/MTProto package install" install -y haproxy git python3-cryptography
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

  if ! grep -Eq '^[^#][[:space:]]*/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]]+' /etc/fstab 2>/dev/null; then
    cp -a /etc/fstab "/etc/fstab.bak-before-swap-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

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
  for svc in nginx x-ui haproxy mtprotoproxy; do
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
write_telegram_https_relay_worker(){
  cat > /usr/local/sbin/telegram-https-relay.py <<'PYRELAY'
#!/usr/bin/env python3
import json
import os
import socket
import socketserver
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler

SOCKET_PATH = os.environ.get("TELEGRAM_RELAY_SOCKET", "/run/xpam-script-telegram-relay.sock")
NOTIFY_ENV = "/root/secure-notes/notify.env"
RELAY_ENV = "/root/secure-notes/notify-relay.env"
MAX_BODY = 4096


def read_env(path):
    data = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                    value = value[1:-1]
                data[key] = value
    except FileNotFoundError:
        pass
    return data


def send_telegram(text):
    notify = read_env(NOTIFY_ENV)
    token = notify.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = notify.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        return False, "direct Telegram token/chat_id are not configured on relay server"
    payload = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=payload,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if 200 <= resp.status < 300:
                return True, "OK"
            return False, f"Telegram HTTP {resp.status}"
    except Exception as exc:
        return False, str(exc)


class Handler(BaseHTTPRequestHandler):
    server_version = "ServerInstallKitTelegramRelay/1.0"

    def log_message(self, fmt, *args):
        return

    def send_text(self, code, text):
        body = (text + "\n").encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        if code == 401:
            self.send_header("WWW-Authenticate", 'Bearer realm="telegram-relay"')
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        relay = read_env(RELAY_ENV)
        token = relay.get("TELEGRAM_HTTPS_RELAY_TOKEN", "")
        auth = self.headers.get("Authorization", "")
        return bool(token) and auth == f"Bearer {token}"

    def do_GET(self):
        if not self.authorized():
            return self.send_text(401, "unauthorized")
        return self.send_text(405, "method not allowed")

    def do_PUT(self):
        if not self.authorized():
            return self.send_text(401, "unauthorized")
        return self.send_text(405, "method not allowed")

    def do_DELETE(self):
        if not self.authorized():
            return self.send_text(401, "unauthorized")
        return self.send_text(405, "method not allowed")

    def do_POST(self):
        if not self.authorized():
            return self.send_text(401, "unauthorized")
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            length = 0
        if length <= 0:
            return self.send_text(400, "empty message")
        if length > MAX_BODY:
            return self.send_text(413, "message too large")
        raw = self.rfile.read(length)
        text = raw.decode("utf-8", "replace").strip()
        ctype = (self.headers.get("Content-Type") or "").lower()
        if "application/json" in ctype:
            try:
                obj = json.loads(text)
                text = str(obj.get("text") or obj.get("message") or "").strip()
            except Exception:
                return self.send_text(400, "invalid json")
        if not text:
            return self.send_text(400, "empty message")
        if len(text.encode("utf-8")) > MAX_BODY:
            text = text[:3500]
        ok, err = send_telegram(text)
        if ok:
            return self.send_text(200, "OK")
        return self.send_text(502, "telegram delivery failed")


class UnixHTTPServer(socketserver.UnixStreamServer):
    allow_reuse_address = True


def main():
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
    server = UnixHTTPServer(SOCKET_PATH, Handler)
    try:
        import grp
        gid = grp.getgrnam("www-data").gr_gid
        os.chown(SOCKET_PATH, 0, gid)
        os.chmod(SOCKET_PATH, 0o660)
    except Exception:
        os.chmod(SOCKET_PATH, 0o666)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
PYRELAY
  chmod 700 /usr/local/sbin/telegram-https-relay.py
  python3 -m py_compile /usr/local/sbin/telegram-https-relay.py
}

ensure_telegram_relay_nginx_snippet(){
  mkdir -p /etc/nginx/snippets
  if [[ ! -f /etc/nginx/snippets/xpam-script-telegram-relay.conf ]]; then
    : > /etc/nginx/snippets/xpam-script-telegram-relay.conf
  fi
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
    warn "Wait until the retry time, then run: sudo ${SERVER_PREFIX}-install and choose menu item 1."
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
  if uses_haproxy; then
    xray_listen="127.0.0.1"
    sniffing="OFF by default. If you later enable WARP/domain routing inside 3x-ui/Xray, XPAM Script can switch sniffing to Route only for that routing use-case."
    external_proxy_block="External Proxy: ENABLED\n  Force TLS: same / Тот же\n  Dest/Host: ${PRIMARY_DOMAIN}\n  Port: ${XRAY_PUBLIC_PORT}\n  Remark: ${server_prefix_up}-public-${XRAY_PUBLIC_PORT}\n  Purpose: generated VLESS links must use ${PRIMARY_DOMAIN}:${XRAY_PUBLIC_PORT}, not 127.0.0.1:${XRAY_LOCAL_PORT}."
  else
    xray_listen="empty / 0.0.0.0"
    sniffing="ON: HTTP, TLS, QUIC; Route only ON. This is required only if you use Xray routing/WARP rules like selected-domain WARP routing."
    external_proxy_block="External Proxy: DISABLED / empty. Direct mode exposes Xray itself on public ${XRAY_PUBLIC_PORT}; no HAProxy rewrite is needed."
  fi
  proxy_protocol_note="Proxy Protocol: OFF. Do not enable it unless HAProxy backend is also changed to send-proxy and health checks/nginx are adjusted.\nFallback PROXY/xVer: OFF / 0. Do not enable unless nginx fallback listens with proxy_protocol.\nFallback SNI/name: empty. Empty means catch-all fallback to the masked website; do not narrow it to one domain unless you intentionally maintain several fallback destinations.\nAuthentication: None / empty. Do not enable X25519/ML-KEM auth for this VLESS+TLS+fallback layout."
  warp_block="Direct profile optional WARP notes:\n  WARP is configured manually inside 3x-ui/Xray, not by XPAM Script.\n  Recommended outbound values: tag=warp, protocol=wireguard, MTU=1420, domainStrategy=ForceIPv4, workers=2, noKernelTun=false.\n  Use reserved from your WARP profile and peer keepAlive=25.\n  Peer allowedIPs should be IPv4-only: 0.0.0.0/0. Do not add ::/0.\n  Address should be IPv4-only, for example 172.16.0.2/32. Do not add Cloudflare IPv6 address 2606:.../128 on this IPv4-only public layout.\n  Endpoint is usually engage.cloudflareclient.com:2408, but follow your actual WARP profile if it differs.\n  Use routing rules for selected domains only; keep system DNS independent from wg0/WARP.\n  wg0 may be lazy/absent immediately after reboot; health treats that as acceptable when WireGuard outbound exists.\n  Never paste WARP private keys into XPAM Script files, notes, screenshots or support messages."
  cat > "$note" <<EOF
Manual 3x-ui setup for xpam-script ${KIT_VERSION}
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
  uTLS/fingerprint: chrome
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
  local running newest
  running="$(uname -r 2>/dev/null || true)"
  newest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's#^/boot/vmlinuz-##' | sort -V | tail -1 || true)"
  if [[ -f /var/run/reboot-required ]]; then
    warn "Reboot is required by installed packages: /var/run/reboot-required exists"
  elif [[ -n "$newest" && -n "$running" && "$newest" != "$running" ]]; then
    warn "A newer installed kernel appears to be available: running=$running, newest=$newest. Reboot after finishing the current stage."
  else
    ok "No reboot marker detected"
  fi
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

  if uses_haproxy; then
    xray_listen="127.0.0.1"
    sniff_enabled="false"
    sniff_route="false"
    inbound_remark="${SERVER_PREFIX}-vless-local-${xray_port}"
    external_proxy_remark="${SERVER_PREFIX}-public-${XRAY_PUBLIC_PORT}"
    external_proxy_json='[{"forceTls":"same","dest":"'"${PRIMARY_DOMAIN}"'","port":'"${XRAY_PUBLIC_PORT}"',"remark":"'"${external_proxy_remark}"'"}]'
  else
    xray_listen=""
    sniff_enabled="true"
    sniff_route="true"
    inbound_remark="${SERVER_PREFIX}-vless-public-${xray_port}"
    external_proxy_json='[]'
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
    "settings":{"allowInsecure":False,"fingerprint":"chrome"}
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
  python3 - <<'PYXUITOKEN'
import sqlite3, sys
db = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(db)
cur = conn.cursor()
cols = [r[1] for r in cur.execute("PRAGMA table_info(api_tokens)").fetchall()]
if not cols:
    sys.exit("api_tokens table is missing or empty schema")
token_col = "token" if "token" in cols else None
if token_col is None:
    for c in cols:
        if "token" in c.lower():
            token_col = c
            break
if token_col is None:
    sys.exit("api token column was not found in api_tokens table")
where = "WHERE enable=1" if "enable" in cols else ""
order = "ORDER BY id DESC" if "id" in cols else ""
row = cur.execute(f"SELECT {token_col} FROM api_tokens {where} {order} LIMIT 1").fetchone()
if not row or not row[0]:
    sys.exit("enabled 3x-ui API token was not found")
print(row[0])
PYXUITOKEN
}

xui_disable_subscription(){
  local db="/etc/x-ui/x-ui.db" backup_dir backup
  say "Disabling 3x-ui subscription server"
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
xui_add_vless_inbound_auto(){
  local base payload ids uuid subid client_name inbound_remark rc token note vless_link panel_path_clean
  panel_path_clean="${PANEL_PATH#/}"
  panel_path_clean="${panel_path_clean%/}"
  base="https://127.0.0.1:${XUI_PANEL_PORT}/${panel_path_clean}"
  payload="$(mktemp /tmp/xpam-script-xui-inbound.XXXXXX.json)"

  say "Reading local 3x-ui v3 API token from SQLite"
  token="$(xui_api_token)" || fail "Could not read enabled 3x-ui API token from /etc/x-ui/x-ui.db"

  say "Проверка существующего XPAM-managed VLESS inbound"
  existing="$(SERVER_PREFIX="$SERVER_PREFIX" PRIMARY_DOMAIN="$PRIMARY_DOMAIN" XRAY_PUBLIC_PORT="$XRAY_PUBLIC_PORT" EXPECTED_PORT="$(expected_xray_port)" python3 - <<'PY_EXISTING_VLESS' 2>/dev/null || true
import json, os, sqlite3, sys
DB='/etc/x-ui/x-ui.db'
prefix=os.environ['SERVER_PREFIX']
primary=os.environ['PRIMARY_DOMAIN']
public_port=os.environ['XRAY_PUBLIC_PORT']
expected_port=str(os.environ['EXPECTED_PORT'])
client_email=f'{prefix}-vless-client'
conn=sqlite3.connect(DB)
conn.row_factory=sqlite3.Row
cur=conn.cursor()
for row in cur.execute('SELECT * FROM inbounds ORDER BY id ASC'):
    r=dict(row)
    if str(r.get('protocol','')).lower()!='vless':
        continue
    if str(r.get('port','')) != expected_port:
        continue
    remark=str(r.get('remark',''))
    settings=json.loads(r.get('settings') or '{}')
    clients=settings.get('clients') or []
    if isinstance(clients, dict): clients=[clients]
    for c in clients:
        if not isinstance(c, dict):
            continue
        if c.get('email') != client_email:
            continue
        uuid=c.get('id') or c.get('uuid')
        if not uuid:
            continue
        link=f'vless://{uuid}@{primary}:{public_port}?type=tcp&security=tls&flow=xtls-rprx-vision&sni={primary}&fp=chrome&alpn=http%2F1.1#{client_email}'
        print('\t'.join([str(uuid), client_email, remark or f'{prefix}-vless', link]))
        sys.exit(0)
PY_EXISTING_VLESS
)"
  if [[ -n "$existing" ]]; then
    IFS=$'\t' read -r uuid client_name inbound_remark vless_link <<< "$existing"
    note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"
    mkdir -p /root/secure-notes
    chmod 700 /root/secure-notes
    cat > "$note" <<EOF_XUINOTE_EXISTING
3x-ui / VLESS setup for xpam-script ${KIT_VERSION}
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
  curl -ksS --connect-timeout 5 --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -d "@$payload" \
    "$base/panel/api/inbounds/add" \
    >/tmp/xpam-script-xui-add-inbound.out \
    2>/tmp/xpam-script-xui-add-inbound.err || rc=$?

  if [[ $rc -ne 0 ]] || ! grep -Eiq '"success"[[:space:]]*:[[:space:]]*true' /tmp/xpam-script-xui-add-inbound.out 2>/dev/null; then
    warn "3x-ui Bearer API add-inbound did not return clear success. Response follows:"
    sed -n '1,120p' /tmp/xpam-script-xui-add-inbound.out 2>/dev/null || true
    sed -n '1,80p' /tmp/xpam-script-xui-add-inbound.err 2>/dev/null || true
    rm -f "$payload"
    fail "Automatic inbound creation failed"
  fi

  mkdir -p /root/secure-notes
  chmod 700 /root/secure-notes

  vless_link="vless://${uuid}@${PRIMARY_DOMAIN}:${XRAY_PUBLIC_PORT}?type=tcp&security=tls&flow=xtls-rprx-vision&sni=${PRIMARY_DOMAIN}&fp=chrome&alpn=http%2F1.1#${client_name}"
  note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"

  cat > "$note" <<EOF_XUINOTE
3x-ui / VLESS setup for xpam-script ${KIT_VERSION}
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
  installer="$(mktemp /tmp/3x-ui-install.XXXXXX.sh)"
  curl -4fsSL --connect-timeout 8 --max-time 30 -o "$installer" https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh || fail "Could not download 3x-ui installer"
  chmod +x "$installer"
  # Current 3x-ui installer flow for first install:
  # customize panel port -> port -> SSL option 4 skip -> bind panel to 127.0.0.1.
  if ! printf 'y\n%s\n4\ny\n' "$XUI_PANEL_PORT" | bash "$installer" "$tag"; then
    rm -f "$installer"
    fail "3x-ui installer failed"
  fi
  rm -f "$installer"

  say "Forcing XPAM Script panel settings"
  /usr/local/x-ui/x-ui setting -username "$XUI_ADMIN_USER" -password "$XUI_ADMIN_PASS" -port "$XUI_PANEL_PORT" -webBasePath "/${PANEL_PATH}/" -listenIP "127.0.0.1" || fail "x-ui setting failed"
  /usr/local/x-ui/x-ui cert -webCert "$cert" -webCertKey "$key" || fail "x-ui cert failed"
  xui_disable_subscription
  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl restart x-ui || fail "x-ui restart failed"
  write_wait_for_port
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 30 xui-panel
  xui_add_vless_inbound_auto
  systemctl restart x-ui || true
  sleep 2
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 30 xui-panel
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$(expected_xray_port)" 30 xray-vless
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
  write_wait_for_port
  systemctl restart x-ui || fail "x-ui restart failed"
  sleep 2
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 20 xui-panel
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$(expected_xray_port)" 20 xray-vless
  ok "3x-ui/VLESS ports reachable. Deep validation will run in health."
}
write_nginx_final(){ export_vars; cleanup_legacy_nginx_files; if uses_mtproto; then ensure_telegram_relay_nginx_snippet; render_template "$KIT_DIR/templates/nginx-mtproto.conf.tpl" /etc/nginx/sites-available/xpam-script-final.conf; else render_template "$KIT_DIR/templates/nginx-direct.conf.tpl" /etc/nginx/sites-available/xpam-script-final.conf; fi; rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/xpam-script-certonly.conf; ln -sf /etc/nginx/sites-available/xpam-script-final.conf /etc/nginx/sites-enabled/xpam-script-final.conf; ensure_htpasswd; nginx -t; systemctl reload nginx || systemctl restart nginx; }
install_mtproto(){
  uses_mtproto || return 0

  say "Подготовка MTProto proxy"
  mkdir -p /root/secure-notes
  chmod 700 /root/secure-notes

  local existing_ok="no" secret tag note backup_dir
  if [[ -f /opt/mtprotoproxy/config.py ]]; then
    if python3 - <<'PY_MTPROTO_VALIDATE' >/dev/null 2>&1
import importlib.util
p='/opt/mtprotoproxy/config.py'
spec=importlib.util.spec_from_file_location('mtproto_config', p)
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
users=getattr(mod,'USERS',{})
assert isinstance(users, dict) and users
for k,v in users.items():
    assert isinstance(k,str) and k
    assert isinstance(v,str) and len(v)==32 and all(c in '0123456789abcdefABCDEF' for c in v)
PY_MTPROTO_VALIDATE
    then
      existing_ok="yes"
      ok "Найден существующий валидный MTProto config.py; USERS/secrets будут сохранены"
    else
      warn "Существующий /opt/mtprotoproxy/config.py не прошёл проверку; перед изменением будет создан backup"
    fi
  fi

  if [[ ! -x /opt/mtprotoproxy/mtprotoproxy.py ]]; then
    say "Установка Python mtprotoproxy из upstream repo"
    backup_dir="/root/manual-backups/mtprotoproxy-code-$(date +%Y%m%d-%H%M%S)"
    if [[ -d /opt/mtprotoproxy ]]; then
      mkdir -p "$backup_dir"
      cp -a /opt/mtprotoproxy "$backup_dir/" 2>/dev/null || true
      rm -rf /opt/mtprotoproxy
    fi
    git clone --depth 1 --branch "$MTPROTO_REPO_BRANCH" "$MTPROTO_REPO_URL" /opt/mtprotoproxy
    chmod 755 /opt/mtprotoproxy /opt/mtprotoproxy/mtprotoproxy.py
    rm -rf /opt/mtprotoproxy/.git /opt/mtprotoproxy/Dockerfile /opt/mtprotoproxy/docker-compose.yml || true
  else
    ok "MTProto upstream code already present: /opt/mtprotoproxy"
  fi

  if [[ "$existing_ok" != "yes" ]]; then
    [[ -f /opt/mtprotoproxy/config.py ]] && cp -a /opt/mtprotoproxy/config.py "/root/manual-backups/mtproto-config.py.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    secret="$(xxd -p -l 16 /dev/urandom)"
    tag="$(echo -n "$SYNC_DOMAIN" | xxd -p -c 256)"
    export MTPROTO_SECRET="$secret"
    export_vars
    render_template "$KIT_DIR/templates/mtprotoproxy-config.py.tpl" /opt/mtprotoproxy/config.py
    chmod 600 /opt/mtprotoproxy/config.py
    note="/root/secure-notes/${SERVER_PREFIX}-mtproto.txt"
    cat > "$note" <<EOF_MTPROTO_NOTE
MTProto proxy for xpam-script ${KIT_VERSION}
==================================================
Link: tg://proxy?server=${SYNC_DOMAIN}&port=443&secret=ee${secret}${tag}
EOF_MTPROTO_NOTE
    chmod 600 "$note"
  fi

  render_template "$KIT_DIR/templates/mtprotoproxy.service.tpl" /etc/systemd/system/mtprotoproxy.service
  mkdir -p /etc/systemd/system/mtprotoproxy.service.d

  cat > /etc/systemd/system/mtprotoproxy.service.d/logging.conf <<'EOF_MTPROTO_LOGGING'
[Service]
StandardOutput=null
StandardError=journal
EOF_MTPROTO_LOGGING

  cat > /etc/systemd/system/mtprotoproxy.service.d/override.conf <<EOF_MTPROTO_OVERRIDE
[Unit]
Wants=network-online.target nginx.service
After=network-online.target nginx.service

[Service]
ExecStartPre=
ExecStartPre=/usr/local/sbin/wait-for-local-port.sh 127.0.0.1 ${SYNC_BACKEND_PORT} 30 nginx-sync-backend
ExecStartPre=/bin/sleep 3
EOF_MTPROTO_OVERRIDE

  cat > /etc/systemd/system/mtprotoproxy.service.d/restart.conf <<'EOF_MTPROTO_RESTART'
[Service]
Restart=on-failure
RestartSec=5s
EOF_MTPROTO_RESTART

  mtproto_python_update rewrite-notes >/dev/null 2>&1 || true
  systemctl daemon-reload
  systemctl enable mtprotoproxy
  systemctl restart mtprotoproxy
}

write_haproxy(){ uses_mtproto || return 0; export_vars; render_template "$KIT_DIR/templates/haproxy.cfg.tpl" /etc/haproxy/haproxy.cfg; haproxy -c -f /etc/haproxy/haproxy.cfg; mkdir -p /etc/systemd/system/haproxy.service.d; render_template "$KIT_DIR/templates/backend-order.conf.tpl" /etc/systemd/system/haproxy.service.d/backend-order.conf; systemctl daemon-reload; systemctl enable haproxy; systemctl restart haproxy; }
write_health_weekly(){ say "Writing health and weekly scripts"; write_common_library; write_dns_policy_script; write_network_tuning_policy_script; write_telegram_https_relay_worker; migrate_legacy_system_file_names || true; export_vars; render_template "$KIT_DIR/templates/health.sh.tpl" "/usr/local/sbin/${SERVER_PREFIX}-health"; chmod +x "/usr/local/sbin/${SERVER_PREFIX}-health"; bash -n "/usr/local/sbin/${SERVER_PREFIX}-health"; write_health_launcher || true; write_links_launcher || true; write_vless_launcher || true; write_telega_launcher || true; write_repair_launcher || true; write_netdiag_launcher || true; render_template "$KIT_DIR/templates/weekly.sh.tpl" "/usr/local/sbin/${SERVER_PREFIX}-weekly-maintenance.sh"; chmod +x "/usr/local/sbin/${SERVER_PREFIX}-weekly-maintenance.sh"; bash -n "/usr/local/sbin/${SERVER_PREFIX}-weekly-maintenance.sh"; write_weekly_launcher || true; local cron_min=35; [[ "$SERVER_PREFIX" == "se" ]] && cron_min=30; [[ "$SERVER_PREFIX" == "lt" ]] && cron_min=40; cat > "/etc/cron.d/${SERVER_PREFIX}-weekly-maintenance" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${cron_min} 4 * * 0 root /usr/bin/nice -n 19 /usr/bin/ionice -c3 /usr/local/sbin/${SERVER_PREFIX}-weekly-maintenance.sh >/dev/null 2>&1
EOF
}

prune_keep_latest(){
  local dir="$1" pattern="$2" keep="${3:-4}" old_path
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk -v keep="$keep" 'NR>keep {sub(/^[^ ]+ /,""); print}' \
    | while IFS= read -r old_path; do
        [[ -n "$old_path" ]] && rm -rf -- "$old_path" 2>/dev/null || true
      done
}

run_health_quiet(){
  local label="${1:-health-check}" ts log_dir log rc
  [[ -n "${SERVER_PREFIX:-}" ]] || fail "SERVER_PREFIX is not loaded; cannot run health"
  if [[ ! -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]]; then
    fail "Health command not found: /usr/local/sbin/${SERVER_PREFIX}-health"
  fi

  ts="$(date +%Y%m%d-%H%M%S)"
  label="$(printf '%s' "$label" | tr -cd 'A-Za-z0-9_.-')"
  [[ -n "$label" ]] || label="health-check"
  log_dir="/var/log/xpam-script"
  mkdir -p "$log_dir"
  chmod 700 "$log_dir" 2>/dev/null || true
  log="${log_dir}/${SERVER_PREFIX}-${label}-${ts}.log"

  if "/usr/local/sbin/${SERVER_PREFIX}-health" >"$log" 2>&1; then
    prune_keep_latest "$log_dir" "${SERVER_PREFIX}-*.log" 4
    ok "Краткая health-проверка пройдена. Подробный лог: $log"
    return 0
  fi

  rc=$?
  prune_keep_latest "$log_dir" "${SERVER_PREFIX}-*.log" 4
  warn "Health-check завершился ошибкой. Подробный лог: $log"
  echo "Последние строки health-лога:"
  tail -n 80 "$log" 2>/dev/null || true
  return "$rc"
}
telegram_mask_token(){
  local t="${1:-}"
  local n=${#t}
  if (( n <= 10 )); then
    printf '%s' '[masked]'
  else
    printf '%s...%s' "${t:0:6}" "${t: -4}"
  fi
}
telegram_api_base(){ printf 'https://api.telegram.org/bot%s' "$1"; }
telegram_validate_token(){
  local token="$1" json ok username
  json="$(curl -4fsS --connect-timeout 5 --max-time 10 "$(telegram_api_base "$token")/getMe" 2>/dev/null || true)"
  [[ -n "$json" ]] || return 1
  ok="$(printf '%s' "$json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("true" if d.get("ok") is True else "false")' 2>/dev/null || echo false)"
  [[ "$ok" == "true" ]] || return 1
  username="$(printf '%s' "$json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("result",{}).get("username", ""))' 2>/dev/null || true)"
  [[ -n "$username" ]] && ok "Telegram bot token действителен: @${username}" || ok "Telegram bot token is valid"
  return 0
}
telegram_send_test(){
  local token="$1" chat="$2" text="$3"
  curl -4fsS --connect-timeout 5 --max-time 10 \
    -X POST "$(telegram_api_base "$token")/sendMessage" \
    -d "chat_id=${chat}" \
    --data-urlencode "text=${text}" \
    >/dev/null 2>&1
}
telegram_private_chat_id(){
  local token="$1"
  curl -4fsS --connect-timeout 5 --max-time 10 "$(telegram_api_base "$token")/getUpdates" 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); chats=[]
for u in d.get("result",[]):
    m=u.get("message") or u.get("edited_message") or {}
    c=m.get("chat") or {}
    if c.get("type")=="private" and c.get("id") is not None:
        chats.append(str(c.get("id")))
print(chats[-1] if chats else "")' 2>/dev/null || true
}

telegram_botfather_help(){
  cat <<'EOF_TG_BOT_HELP'
Подготовка Telegram-бота:

XPAM Script использует только личный чат один-на-один с вашим Telegram-ботом.
Группы, каналы и темы форумов в простой установке не используются.

Если у вас уже есть bot token:
  1. Используйте существующий token.
  2. Откройте чат с вашим созданным ботом.
  3. Отправьте боту /start, если ещё не делали этого раньше.
  4. Повторно отправить /start безопасно.

Если бота ещё нет:
  1. Откройте Telegram.
  2. Найдите @BotFather.
  3. Отправьте ему /newbot.
  4. Создайте имя и username бота.
  5. Скопируйте token, который выдаст BotFather.
  6. Откройте чат с вашим новым ботом, НЕ с @BotFather.
  7. Отправьте вашему новому боту /start.
  8. Вернитесь сюда и вставьте token в терминал.
EOF_TG_BOT_HELP
}


setup_direct_telegram_env(){
  local token chat direct_ok
  if [[ -f /etc/xpam-script/config.env ]]; then
    set +u
    . /etc/xpam-script/config.env
    set -u
  fi
  echo
  echo "Режим прямой отправки Telegram уведомлений."
  echo "Этот VPS сам отправляет сообщения в Telegram через вашего бота."
  echo "Relay-сервер в этом режиме не используется."
  echo
  telegram_botfather_help
  echo

  while true; do
    read -r -s -p "Введите Telegram bot token от @BotFather; пусто = отмена. Token сюда, в чат ChatGPT, не отправляйте: " token || true
    echo
    [[ -n "$token" ]] || { warn "Настройка Telegram отменена"; return 1; }
    say "Проверяем Telegram bot token: $(telegram_mask_token "$token")"
    telegram_validate_token "$token" && break
    warn "Telegram bot token не прошёл проверку. Проверьте token, который выдал @BotFather."
  done

  echo
  echo "Теперь откройте в Telegram чат с вашим созданным ботом, НЕ с @BotFather, и отправьте:"
  echo "  /start"
  echo
  echo "Если чат с ботом уже был запущен раньше, повторно отправить /start безопасно."
  echo
  read -r -p "Нажмите Enter после отправки /start вашему боту: " _tg_enter || true

  chat="$(telegram_private_chat_id "$token")"
  if [[ -z "$chat" ]]; then
    warn "Не удалось автоматически определить private chat_id. Убедитесь, что вы открыли созданного бота и отправили ему /start."
    read -r -p "Нажмите Enter, чтобы попробовать getUpdates ещё раз, или Ctrl+C для отмены: " _tg_retry || true
    chat="$(telegram_private_chat_id "$token")"
  fi
  [[ -n "$chat" ]] || fail "Private Telegram chat_id не найден. Отправьте /start вашему боту и запустите настройку Telegram снова."

  cat > /root/secure-notes/notify.env <<EOF_NOTIFY
TELEGRAM_MODE='direct'
TELEGRAM_BOT_TOKEN='${token}'
TELEGRAM_CHAT_ID='${chat}'
EOF_NOTIFY
  chmod 600 /root/secure-notes/notify.env

  say "Отправляем тестовое Telegram сообщение"
  direct_ok=no
  if telegram_send_test "$token" "$chat" "[${SERVER_PREFIX:-$(hostname -s)}] Проверка Telegram уведомлений: OK"; then
    ok "Telegram уведомления в личный чат работают напрямую"
    direct_ok=yes
  else
    warn "Прямая отправка Telegram с этого сервера не сработала. Используйте HTTPS Relay, если этот VPS не может достучаться до api.telegram.org."
  fi
  say "Telegram настройки сохранены в /root/secure-notes/notify.env с правами 600"
  [[ "$direct_ok" == "yes" ]]
}

setup_https_relay_client(){
  local relay_url relay_token
  if [[ -f /etc/xpam-script/config.env ]]; then
    set +u
    . /etc/xpam-script/config.env
    set -u
  fi
  echo
  echo "Режим отправки уведомлений через другой XPAM Script сервер."
  echo
  echo "Этот VPS будет клиентом Telegram Relay."
  echo "Он НЕ использует Telegram bot token и НЕ пишет в Telegram напрямую."
  echo "Он отправляет уведомления на основной XPAM Script сервер, где уже включён Telegram Relay."
  echo
  echo "Когда выбирать этот пункт:"
  echo "  - этот сервер дополнительный;"
  echo "  - основной сервер уже настроен как Telegram Relay через пункт 3;"
  echo "  - вы хотите, чтобы этот сервер отправлял уведомления через основной сервер."
  echo
  echo "Что нужно взять с основного Relay-сервера:"
  echo "  1. Relay URL"
  echo "  2. Relay token"
  echo
  echo "Где взять Relay URL:"
  echo "  На основном сервере выберите пункт 3:"
  echo "  Сделать этот сервер Telegram Relay для других серверов."
  echo "  После включения скрипт покажет Relay URL."
  echo
  echo "Где взять Relay token:"
  echo "  На основном Relay-сервере он хранится в:"
  echo "  /root/secure-notes/notify-relay.env"
  echo
  echo "Relay token — секрет. Не отправляйте его в чат, письма или публичные логи."
  echo "Relay URL лучше копировать с завершающим /. Если / забыли, XPAM Script добавит его сам."
  echo "Автоматического подставления Relay URL/token нет: пользователь вводит их вручную."
  echo
  ask relay_url "Введите Relay URL с основного Relay-сервера" ""
  read -r -s -p "Введите Relay token с основного Relay-сервера; пусто = отмена: " relay_token || true
  echo
  relay_url="$(normalize_https_relay_url "$relay_url")"
  [[ -n "$relay_token" ]] || { warn "Настройка HTTPS Relay отменена"; return 1; }
  echo "Relay URL будет сохранён как: ${relay_url}"

  say "Отправляем тестовое сообщение через HTTPS Relay"
  if curl -4fsS --connect-timeout 5 --max-time 12 \
      -X POST "$relay_url" \
      -H "Authorization: Bearer ${relay_token}" \
      --data-binary "[${SERVER_PREFIX:-$(hostname -s)}] Проверка отправки через HTTPS Relay: OK" \
      >/dev/null 2>&1; then
    ok "HTTPS Relay работает"
  else
    fail "Тест HTTPS Relay не прошёл. Проверьте Relay URL/token и то, что relay-сервер умеет отправлять Telegram уведомления."
  fi

  cat > /root/secure-notes/notify.env <<EOF_NOTIFY_RELAY
TELEGRAM_MODE='https_relay'
TELEGRAM_RELAY_URL='${relay_url}'
TELEGRAM_RELAY_TOKEN='${relay_token}'
EOF_NOTIFY_RELAY
  chmod 600 /root/secure-notes/notify.env
  ok "Настройки HTTPS Relay сохранены в /root/secure-notes/notify.env"
}

telegram_relay_wait_http_code(){
  local url="$1" expect="$2" token="${3:-}" code=""
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -n "$token" ]]; then
      code="$(curl -4ksS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 -H "Authorization: Bearer ${token}" "$url" 2>/dev/null || true)"
    else
      code="$(curl -4ksS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)"
    fi
    [[ "$code" == "$expect" ]] && { echo "$code"; return 0; }
    sleep 1
  done
  echo "${code:-none}"
  return 1
}

telegram_relay_post_with_retry(){
  local url="$1" token="$2" message="$3"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -4fsS --connect-timeout 5 --max-time 12 \
        -X POST "$url" \
        -H "Authorization: Bearer ${token}" \
        --data-binary "$message" \
        >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

setup_https_relay_server(){
  local relay_path relay_token relay_url code
  if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "Server config not found. Finish server setup first, then enable HTTPS Telegram relay."
  fi
  load_config
  validate_inputs
  uses_mtproto || fail "HTTPS relay server mode requires a profile with MTProto domain behind HAProxy. This keeps public ports limited to 22/80/443."
  echo
  echo "Режим Telegram Relay-сервера."
  echo "Этот VPS будет принимать уведомления от других XPAM Script серверов и пересылать их в Telegram."
  echo "Новый внешний порт НЕ открывается. Используется существующий HTTPS 443 через HAProxy/nginx."
  echo "Так как именно этот сервер отправляет сообщения в Telegram, ему нужен Telegram bot token."
  echo "Если бота ещё нет, следующий шаг объяснит, как создать его через @BotFather."
  echo

  if [[ ! -s /root/secure-notes/notify.env ]]; then
    warn "Direct Telegram settings are required on the relay server. Configure them now."
    setup_direct_telegram_env || fail "Direct Telegram setup is required before enabling this server as relay."
  else
    # Relay server must have real Telegram bot token/chat_id locally. A relay-client-only notify.env is not enough.
    if ! bash -c '. /root/secure-notes/notify.env; [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]'; then
      warn "This server does not have direct Telegram bot token/chat_id. Configure direct Telegram now."
      setup_direct_telegram_env || fail "Direct Telegram setup is required before enabling this server as relay."
    else
      echo
      echo "Перед включением Telegram Relay нужно проверить, что этот сервер сам может отправлять сообщения в Telegram."
      echo "Сейчас будет отправлено тестовое сообщение в ваш Telegram."
      echo
      if ! bash -c '. /etc/xpam-script/config.env; . /usr/local/sbin/xpam-maint-common.sh; xpam_notify_send "[${SERVER_PREFIX:-$(hostname -s)}] Проверка перед включением Relay: прямая отправка в Telegram работает."'; then
        fail "Сохранённые прямые Telegram настройки не сработали. Сначала обновите Direct Telegram token через пункт 1."
      fi
    fi
  fi

  relay_path="$(normalize_path "${TELEGRAM_RELAY_PATH:-api/internal/notify-relay}")"
  read -r -p "Путь HTTPS Relay на ${SYNC_DOMAIN} [${relay_path}]: " _relay_path_ans || true
  relay_path="$(normalize_path "${_relay_path_ans:-$relay_path}")"
  [[ -n "$relay_path" ]] || fail "Relay path cannot be empty"
  [[ "$relay_path" =~ ^[A-Za-z0-9._~/-]+$ ]] || fail "Relay path contains unsupported characters"
  [[ "$relay_path" != *..* ]] || fail "Relay path must not contain .."
  relay_token="$(openssl rand -hex 32)"

  mkdir -p /root/secure-notes /etc/nginx/snippets
  chmod 700 /root/secure-notes
  cat > /root/secure-notes/notify-relay.env <<EOF_RELAY_ENV
TELEGRAM_HTTPS_RELAY_TOKEN='${relay_token}'
TELEGRAM_HTTPS_RELAY_PATH='${relay_path}'
TELEGRAM_HTTPS_RELAY_SOCKET='${TELEGRAM_RELAY_SOCKET}'
EOF_RELAY_ENV
  chmod 600 /root/secure-notes/notify-relay.env

  write_telegram_https_relay_worker
  cat > /etc/systemd/system/telegram-https-relay.service <<EOF_RELAY_SERVICE
[Unit]
Description=XPAM Script HTTPS Telegram relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=TELEGRAM_RELAY_SOCKET=${TELEGRAM_RELAY_SOCKET}
ExecStart=/usr/local/sbin/telegram-https-relay.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=false

[Install]
WantedBy=multi-user.target
EOF_RELAY_SERVICE

  cat > /etc/nginx/snippets/xpam-script-telegram-relay.conf <<EOF_RELAY_NGINX
location = /${relay_path} { return 308 /${relay_path}/; }
location ^~ /${relay_path}/ {
    client_max_body_size 8k;
    access_log off;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header Authorization \$http_authorization;
    proxy_set_header Content-Type \$content_type;
    proxy_pass http://unix:${TELEGRAM_RELAY_SOCKET}:/;
}
EOF_RELAY_NGINX

  systemctl daemon-reload
  systemctl enable --now telegram-https-relay.service
  nginx -t
  systemctl reload nginx || systemctl restart nginx

  relay_url="https://${SYNC_DOMAIN}/${relay_path}/"

  say "Проверяем HTTPS Relay endpoint без token; ожидается HTTP 401"
  code="$(telegram_relay_wait_http_code "$relay_url" "401" "" || true)"
  [[ "$code" == "401" ]] && ok "Relay endpoint без token возвращает HTTP 401" || fail "Relay endpoint без token вернул HTTP ${code:-none}; ожидался 401"

  say "Отправляем тестовое сообщение через HTTPS Relay"
  telegram_relay_post_with_retry "$relay_url" "$relay_token" "[${SERVER_PREFIX:-$(hostname -s)}] Проверка HTTPS Telegram Relay-сервера: OK" \
    || fail "HTTPS Relay self-test не прошёл"

  ok "HTTPS Telegram Relay-сервер включён"
  echo
  echo "ДАННЫЕ HTTPS RELAY — СОХРАНИТЕ ДЛЯ ДРУГИХ СЕРВЕРОВ"
  echo
  echo "Этот сервер теперь является основным Telegram Relay-сервером."
  echo "Другие XPAM Script серверы могут отправлять Telegram уведомления через него."
  echo
  echo "На дополнительных серверах выберите:"
  echo "  4) Настроить / проверить Telegram уведомления"
  echo "  2) Отправлять уведомления через другой XPAM Script сервер"
  echo
  echo "Relay URL:"
  echo "  ${relay_url}"
  echo
  echo "Relay token:"
  echo "  сохранён безопасно в /root/secure-notes/notify-relay.env"
  echo "  откройте этот файл на основном Relay-сервере и вручную скопируйте token"
  echo "  token нужен только при настройке дополнительных серверов через пункт 2"
  echo
  echo "Relay token не печатается в терминал и обычные install logs."
  echo "Relay token нельзя отправлять в чат, письма или публичные логи."
}
setup_notify_env(){
  write_common_library
  write_telegram_https_relay_worker
  mkdir -p /root/secure-notes
  chmod 700 /root/secure-notes

  local choice
  echo
  printf '\033[0m'
  echo "============================================================"
  echo "Telegram-уведомления"
  echo "============================================================"
  echo
  echo "XPAM использует личный чат один-на-один с вашим Telegram-ботом."
  echo "Группы, каналы и темы форумов в простой установке не используются."
  echo
  echo "Что НЕ отправляется:"
  echo "  - пароли;"
  echo "  - VLESS/MTProto ссылки;"
  echo "  - Telegram token;"
  echo "  - WARP keys."
  echo
  echo "------------------------------------------------------------"
  echo "Выберите режим Telegram"
  echo "------------------------------------------------------------"
  echo "1) Отправлять уведомления напрямую с этого сервера в Telegram"
  echo "   Этот VPS сам пишет вам в Telegram. Нужен bot token от @BotFather."
  echo
  echo "2) Отправлять уведомления через другой XPAM Script сервер"
  echo "   Этот VPS НЕ использует bot token. Нужны только Relay URL и Relay token с другого сервера."
  echo
  echo "3) Сделать этот сервер Telegram Relay для других серверов"
  echo "   Этот VPS будет принимать уведомления от других серверов и пересылать их в Telegram."
  echo "   Нужен bot token от @BotFather. Новый внешний порт не открывается, используется HTTPS 443."
  echo
  echo "4) Проверить уже сохранённые Telegram настройки"
  echo "   Использует /root/secure-notes/notify.env. Ничего заново не настраивает."
  echo
  echo "5) Пропустить Telegram уведомления"
  read -r -p "Выберите пункт [1-5]: " choice || true
  choice="${choice:-5}"

  case "$choice" in
    1) setup_direct_telegram_env || true ;;
    2) setup_https_relay_client ;;
    3) setup_https_relay_server ;;
    4)
      if [[ -s /root/secure-notes/notify.env ]]; then
        chmod 600 /root/secure-notes/notify.env
        ok "Используем сохранённые Telegram настройки: /root/secure-notes/notify.env"
        bash -c '. /etc/xpam-script/config.env; . /usr/local/sbin/xpam-maint-common.sh; xpam_notify_send "[${SERVER_PREFIX:-$(hostname -s)}] Проверка сохранённых Telegram настроек из xpam-script: OK"' || warn "Не удалось отправить Telegram test с сохранёнными настройками"
      else
        warn "No existing /root/secure-notes/notify.env found"
      fi
      ;;
    5|*) warn "Telegram skipped" ;;
  esac
}


ask_layout(){
  echo
  echo "Choose server profile:"
  echo "1) VLESS only, direct TLS"
  echo "2) VLESS + MTProto, separate subdomains"
  echo "3) Main/root website + VLESS + MTProto"
  local choice
  read -r -p "Profile [1-3]: " choice
  case "$choice" in
    1) PROFILE=vless_direct ;;
    2) PROFILE=subdomains_mtproto ;;
    3) PROFILE=root_mtproto ;;
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
    ask SYNC_DOMAIN "MTProto domain" ""
  fi
  ask CERT_EMAIL "Email for Let's Encrypt; empty = no email" ""
  ask_default_label PANEL_PATH "3x-ui panel path" "$PANEL_PATH"
  ask XUI_PANEL_PORT "3x-ui local panel port" "$XUI_PANEL_PORT"
  uses_haproxy && ask XRAY_LOCAL_PORT "Local Xray/VLESS port behind HAProxy" "$XRAY_LOCAL_PORT"
  ask SITE_BACKEND_PORT "Local nginx fallback site port" "$SITE_BACKEND_PORT"
  uses_mtproto && ask SYNC_BACKEND_PORT "Local nginx MTProto TLS backend port" "$SYNC_BACKEND_PORT" && ask MTPROTO_PORT "Local MTProto backend port" "$MTPROTO_PORT"
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
  uses_mtproto && echo "  MTProto domain: $SYNC_DOMAIN"
  echo "  Cert name: $(web_cert_name)"
  echo "  Public ports: SSH ${SSH_PUBLIC_PORT}, HTTP ${HTTP_PUBLIC_PORT}, TLS ${XRAY_PUBLIC_PORT}"
  echo "  3x-ui panel: 127.0.0.1:${XUI_PANEL_PORT}, public path https://${PRIMARY_DOMAIN}/${PANEL_PATH}/"
  echo "  VLESS/Xray inbound: $(uses_haproxy && echo 127.0.0.1 || echo 0.0.0.0):$(expected_xray_port)"
  echo "  3x-ui automation: ${XUI_AUTO_SETUP}"
  confirm "Продолжить?" yes || fail "Cancelled"
}

apply_service_hygiene(){
  say "Applying post-install service hygiene and cleanup policy"
  write_common_library
  bash -c '. /usr/local/sbin/xpam-maint-common.sh; xpam_apply_service_hygiene "'"$CONFIG_FILE"'"'
}

post_install_cleanup(){
  say "Running post-install safe cleanup"
  write_common_library
  bash -c '. /usr/local/sbin/xpam-maint-common.sh; xpam_post_install_cleanup "'"$SERVER_PREFIX"'"'
}

cleanup_root_test_leftovers(){
  # Keep /root clean after successful stage transitions. This helper removes
  # only upload/test/debug leftovers and empty tool caches; it never touches
  # user secrets, SSH keys, config snapshots or rollback backups.
  local mode="${1:-safe}"
  shopt -s nullglob

  rm -f /root/de-health-*.txt /root/de-health-debian-*.txt 2>/dev/null || true
  rm -f /root/xpam-script-v*-*.log /root/xpam-script-*.log 2>/dev/null || true
  rm -f /root/.Xauthority /root/.lesshst 2>/dev/null || true
  rm -rf /root/xpam-install /root/xpam-release-build /root/xpam-script-test-* 2>/dev/null || true
  rm -rf /tmp/xpam-* /tmp/xpam-script-* /var/tmp/xpam-* /var/tmp/xpam-script-* 2>/dev/null || true
  rm -f /tmp/service-audit-*.txt /tmp/tls-cert.* /tmp/tls-info.* 2>/dev/null || true

  if [[ "$mode" == "stage1" || "$mode" == "final" ]]; then
    rm -f /root/xpam-script-v*.tar.gz /root/xpam-script-v*.tgz /root/xpam-script-v*.zip 2>/dev/null || true
    rm -f /root/xpam-script-v*.tar.gz.sha256 /root/xpam-script-v*.tgz.sha256 /root/xpam-script-v*.sha256 2>/dev/null || true
  fi

  # Remove empty helper/cache directory trees only when they contain no files.
  for xpam_empty_cache_dir in /root/.ansible /root/.local; do
    if [[ -d "$xpam_empty_cache_dir" ]]; then
      find "$xpam_empty_cache_dir" -depth -type d -empty -delete 2>/dev/null || true
      rmdir "$xpam_empty_cache_dir" 2>/dev/null || true
    fi
  done
  shopt -u nullglob
}

final_production_cleanup(){
  need_root
  ensure_sudo_hostname_resolution
  load_config
  validate_inputs
  say "Final production cleanup / polish"

  local original_workdir item target deferred_cleanup_script
  local -a deferred_workdirs
  original_workdir="$(pwd -P 2>/dev/null || true)"
  deferred_workdirs=()

  install_runtime_kit || true
  write_install_launcher || true
  write_health_launcher || true
  write_weekly_launcher || true
  write_links_launcher || true
  write_vless_launcher || true
  write_telega_launcher || true
  write_repair_launcher || true
  write_netdiag_launcher || true
  write_health_weekly || true

  post_install_cleanup || true

  # Final cleanup may remove the extracted XPAM Script directory.  A child shell
  # cannot move the user's parent SSH shell out of that directory.  Therefore we
  # move this script process to /root for safe health checks, and if any running
  # process still has cwd inside /root/xpam-script-v*, we schedule that
  # extracted directory for delayed removal after the user leaves it.
  cd /root 2>/dev/null || cd / 2>/dev/null || true

  has_process_cwd_inside_target(){
    local check_target="$1" cwd cur
    for cwd in /proc/[0-9]*/cwd; do
      cur="$(readlink -f "$cwd" 2>/dev/null || true)"
      [[ -n "$cur" ]] || continue
      if [[ "$cur" == "$check_target" || "$cur" == "$check_target"/* ]]; then
        return 0
      fi
    done
    return 1
  }

  say "Removing XPAM Script upload/test leftovers"
  shopt -s nullglob
  for item in \
    /root/xpam-bootstrap.sh \
    /root/xpam-install \
    /root/xpam-release-build \
    /root/xpam-script-*.tar.gz \
    /root/xpam-script-*.tgz \
    /root/xpam-script-*.zip \
    /root/xpam-script-*.sha256 \
    /root/xpam-script*.sha256 \
    /root/xpam-script*.tar.gz.sha256 \
    /root/xpam-script*.tgz.sha256 \
    /root/xpam-script-v*-*.log \
    /root/xpam-script-*.log \
    /root/xpam-script-test-* \
    /root/xpam-script-v*; do
    [[ -e "$item" ]] || continue
    target="$(readlink -f "$item" 2>/dev/null || true)"
    if [[ -d "$target" && ( "$target" == /root/xpam-script-v* || "$target" == /root/xpam-install || "$target" == /root/xpam-release-build ) ]]; then
      # Do not remove extracted XPAM Script/bootstrap/build directories synchronously.
      # The user's parent SSH shell may still be standing inside one of them,
      # and a child script cannot move that parent shell. Always schedule
      # delayed removal: if nobody is inside, it disappears within a few seconds;
      # if somebody is inside, it disappears after they leave.
      deferred_workdirs+=("$target")
      continue
    fi
    rm -rf -- "$item" 2>/dev/null || true
  done
  shopt -u nullglob
  rm -f /root/.lesshst 2>/dev/null || true

  say "Removing temporary installation/debug files"
  find /tmp -maxdepth 1 \( \
    -name 'xpam-script-*' -o \
    -name '3x-ui-install.*.sh' -o \
    -name '*.out' -o \
    -name '*.err' \
  \) -exec rm -rf {} + 2>/dev/null || true


  say "Removing unused default nginx webroot"
  rm -rf /var/www/html 2>/dev/null || true

  for target in "${deferred_workdirs[@]:-}"; do
    [[ -n "$target" && -d "$target" ]] || continue
    deferred_cleanup_script="/tmp/xpam-script-deferred-cleanup-${SERVER_PREFIX}-$$-$(basename "$target").sh"
    cat >"$deferred_cleanup_script" <<'EOS'
#!/usr/bin/env bash
set -u
target="${1:-}"
[[ -n "$target" ]] || exit 0
case "$target" in
  /root/xpam-script-v*|/root/xpam-install|/root/xpam-release-build) ;;
  *) exit 0 ;;
esac
[[ -d "$target" ]] || exit 0
has_process_cwd_inside_target(){
  local cwd cur
  for cwd in /proc/[0-9]*/cwd; do
    cur="$(readlink -f "$cwd" 2>/dev/null || true)"
    [[ -n "$cur" ]] || continue
    if [[ "$cur" == "$target" || "$cur" == "$target"/* ]]; then
      return 0
    fi
  done
  return 1
}
for _ in $(seq 1 1800); do
  if ! has_process_cwd_inside_target; then
    rm -rf -- "$target" 2>/dev/null || true
    rm -f -- "$0" 2>/dev/null || true
    exit 0
  fi
  sleep 1
done
exit 0
EOS
    chmod 700 "$deferred_cleanup_script" 2>/dev/null || true
    nohup bash "$deferred_cleanup_script" "$target" >/dev/null 2>&1 &
  done

  say "Cleaning old logs and backups by retention policy"
  mkdir -p /var/log/xpam-script /var/log/xpam-script/netdiag
  chmod 700 /var/log/xpam-script /var/log/xpam-script/netdiag 2>/dev/null || true
  prune_keep_latest /var/log/xpam-script "${SERVER_PREFIX}-health-*.log" "${XPAM_HEALTH_LOG_KEEP:-4}" || true
  prune_keep_latest /var/log/xpam-script/netdiag "${SERVER_PREFIX}-*.txt" 2 || true
  rm -rf /root/manual-backups/health-logs /root/manual-backups/networking-diagnostics 2>/dev/null || true
  prune_keep_latest /root/manual-backups/xui-warp-normalize 'x-ui.db.*' "${XPAM_BACKUP_KEEP:-2}" || true
  prune_keep_latest /root/manual-backups/xui-subscription-disable 'x-ui.db.*' "${XPAM_BACKUP_KEEP:-2}" || true
  prune_keep_latest /root/manual-backups 'mtproto-config.py.*' "${XPAM_BACKUP_KEEP:-2}" || true
  find /root/manual-backups -type d -empty -delete 2>/dev/null || true
  find /root/manual-backups -mindepth 1 -maxdepth 2 -type f \( -name '*.bak-*' -o -name '*.tmp' -o -name '*.out' -o -name '*.err' \) -delete 2>/dev/null || true
  find /usr/local/sbin /etc/nginx /etc/haproxy /etc/systemd/system -xdev -type f \
    \( -name '*.bak-*' -o -name '*.bak-before-*' -o -name '*.bak-xpam-script-*' \) \
    -delete 2>/dev/null || true

  say "Cleaning apt caches and trimming journals"
  apt-get clean || true
  rm -rf /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/* 2>/dev/null || true
  journalctl --vacuum-size=24M >/dev/null 2>&1 || true

  cleanup_root_test_leftovers final || true

  say "Final cleanup footprint"
  du -sh /root /tmp /var/cache/apt /var/log /opt /usr/local/sbin 2>/dev/null || true

  cd /root 2>/dev/null || cd / 2>/dev/null || true
  if [[ -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]]; then
    "/usr/local/sbin/${SERVER_PREFIX}-health" || fail "Health failed after final cleanup"
  fi
  if ((${#deferred_workdirs[@]} > 0)); then
    echo
    ok "Финальная очистка завершена. Сервер здоров."
    echo
    echo "Выполните сейчас:"
    echo "  cd /root"
    echo
    echo "Временная папка установки будет удалена автоматически через несколько секунд после выхода из неё."
    echo "Перезагрузка не требуется."
  else
    ok "Final production cleanup complete. Server is clean and manageable."
  fi

  # Production cleanup should leave /root free of install logs as well.
  # If this script is currently being logged through tee, removing the path is
  # safe: the open descriptor can finish, but the root filesystem stays clean.
  rm -f /root/xpam-script-v*-*.log /root/xpam-script-*.log 2>/dev/null || true
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
  if [[ -f /var/run/reboot-required ]]; then
    warn "Первый этап завершён. Перед финальной настройкой требуется перезагрузка."
    echo "Выполните сейчас:"
    echo "  sudo reboot"
    echo
    echo "После перезагрузки войдите по SSH-ключу и выполните:"
    echo "  sudo ${SERVER_PREFIX}-install"
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
    ok "Первый этап завершён. Настройте 3x-ui вручную, затем выполните: sudo ${SERVER_PREFIX}-install"
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
  local auto_note="$1" db="/etc/x-ui/x-ui.db" tmp rc fallback_link fallback_inbound fallback_client

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

    fp = str(tls_settings.get("fingerprint") or tls.get("fingerprint") or "chrome").strip()
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

  fallback_link="$(note_value "$auto_note" "VLESS link")"
  fallback_inbound="$(note_value "$auto_note" "Inbound name")"
  fallback_client="$(note_value "$auto_note" "Client name")"
  if [[ -n "$fallback_link" ]]; then
    echo "  Inbound Name: ${fallback_inbound:-see 3x-ui panel}"
    echo "  Client Name: ${fallback_client:-see 3x-ui panel}"
    echo "  VLESS Link: ${fallback_link}"
  else
    echo "  VLESS клиенты не найдены. Добавьте клиента в 3x-ui или проверьте /etc/x-ui/x-ui.db."
  fi
}


vless_links_file(){
  echo "/root/secure-notes/${SERVER_PREFIX}-vless-links.txt"
}

sync_vless_links_file(){
  local auto_note file tmp
  auto_note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"
  file="$(vless_links_file)"
  mkdir -p /root/secure-notes
  chmod 700 /root/secure-notes 2>/dev/null || true
  tmp="$(mktemp /tmp/xpam-vless-links.XXXXXX)"
  # print_vless_links_from_xui intentionally prints a human view; extract only link lines into the secure file.
  print_vless_links_from_xui "$auto_note" 2>/dev/null \
    | awk -F'VLESS Link: ' '/VLESS Link: / {print $2}' \
    | sed '/^[[:space:]]*$/d' > "$tmp" || true
  if [[ -s "$tmp" ]]; then
    install -m 600 "$tmp" "$file"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

print_connection_summary(){
  local basic_note auto_note mt_note mt_users_note vless_file
  basic_note="/root/secure-notes/${SERVER_PREFIX}-basic-auth.txt"
  auto_note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"
  mt_note="/root/secure-notes/${SERVER_PREFIX}-mtproto.txt"
  mt_users_note="/root/secure-notes/${SERVER_PREFIX}-mtproto-users.txt"
  vless_file="$(vless_links_file)"
  sync_vless_links_file >/dev/null 2>&1 || true

  echo
  echo "============================================================"
  echo "XPAM Script: данные подключения"
  echo "============================================================"
  echo
  echo "Этот вывод безопасный: пароли, VLESS-ссылки и MTProto-секреты здесь не печатаются."
  echo "Полные секреты лежат только в защищённых файлах с правами 600."
  echo
  echo "Сайты и панели:"
  [[ -n "${ROOT_DOMAIN:-}" ]] && echo "  Основной сайт:        https://${ROOT_DOMAIN}/"
  [[ -n "${WWW_DOMAIN:-}" && -n "${ROOT_DOMAIN:-}" ]] && echo "  www redirect:         https://${WWW_DOMAIN}/ -> https://${ROOT_DOMAIN}/"
  echo "  3x-ui / VLESS:        https://${PRIMARY_DOMAIN}/${PANEL_PATH}/"
  if uses_mtproto; then
    echo "  MTProto health:       https://${SYNC_DOMAIN}/health"
  fi
  echo
  echo "Файлы с секретами на сервере:"
  [[ -f "$basic_note" ]] && echo "  Basic Auth:           $basic_note"
  [[ -f "$auto_note" ]] && echo "  3x-ui данные:         $auto_note"
  [[ -f "$vless_file" ]] && echo "  VLESS-ссылки:         $vless_file"
  [[ -f "$mt_note" ]] && echo "  MTProto link:         $mt_note"
  [[ -f "$mt_users_note" ]] && echo "  MTProto users:        $mt_users_note"
  echo
  echo "Показать секреты на экран только осознанно:"
  echo "  VLESS-ссылки:         sudo ${SERVER_PREFIX}-vless --show"
  if uses_mtproto; then
    echo "  MTProto-ссылки:       sudo ${SERVER_PREFIX}-telega --show"
    echo "  MTProto управление:   sudo ${SERVER_PREFIX}-telega --manage"
  fi
  echo "  Всё сразу:            sudo ${SERVER_PREFIX}-links --show-secrets"
  echo
  echo "Проверка сервера:"
  echo "  Быстрая:              sudo ${SERVER_PREFIX}-health"
  echo "  Подробная:            sudo ${SERVER_PREFIX}-health --deep"
  echo "============================================================"
}

print_connection_secrets_summary(){
  local basic_note auto_note mt_note mt_users_note basic_user basic_pass xui_user xui_pass mtproto_link
  basic_note="/root/secure-notes/${SERVER_PREFIX}-basic-auth.txt"
  auto_note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"
  mt_note="/root/secure-notes/${SERVER_PREFIX}-mtproto.txt"
  mt_users_note="/root/secure-notes/${SERVER_PREFIX}-mtproto-users.txt"

  basic_user="$(note_value "$basic_note" "Username")"
  basic_pass="$(note_value "$basic_note" "Password")"
  xui_user="$(note_value "$auto_note" "3x-ui username")"
  xui_pass="$(note_value "$auto_note" "3x-ui password")"
  mtproto_link="$(note_value "$mt_note" "Link")"

  echo
  echo "============================================================"
  echo "Данные для подключения"
  echo
  echo "Сохраните эти данные в безопасном месте."
  echo "Не отправляйте пароли, VLESS/MTProto ссылки и token в чаты или публичные логи."
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
    echo "ГОТОВАЯ TELEGRAM / MTPROTO ССЫЛКА:"
    echo "  ${mtproto_link:-see $mt_note}"
    echo
  fi
  echo "ФАЙЛЫ С ДАННЫМИ НА СЕРВЕРЕ:"
  [[ -f "$basic_note" ]] && echo "  $basic_note"
  [[ -f "$auto_note" ]] && echo "  $auto_note"
  [[ -f "$mt_note" ]] && echo "  $mt_note"
  [[ -f "$mt_users_note" ]] && echo "  $mt_users_note"
  echo
  echo "ПОЛЕЗНЫЕ КОМАНДЫ:"
  echo "  Открыть меню XPAM Script:          sudo ${SERVER_PREFIX}-install"
  echo "  Показать безопасную сводку:     sudo ${SERVER_PREFIX}-links"
  echo "  Показать VLESS-ссылки:           sudo ${SERVER_PREFIX}-vless"
  if uses_mtproto; then
    echo "  Управление MTProto пользователями: sudo ${SERVER_PREFIX}-telega"
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
  echo "Секреты, пароли, VLESS и MTProto ссылки не печатаются в install-log."
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
  ensure_swap_policy
  preinstall_system_update
  install_base_packages
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
  install_mtproto
  write_haproxy
  apply_service_nofile_limits
  /usr/local/sbin/check-network-tuning-policy || fail "network tuning policy check failed"
  write_certbot_hook
  write_health_weekly
  systemctl try-restart x-ui || true
  systemctl reload nginx || systemctl restart nginx
  uses_mtproto && { systemctl restart mtprotoproxy; systemctl restart haproxy; }
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

stage_notify(){ need_root; setup_notify_env; }

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
  echo "  https://${PRIMARY_DOMAIN}${PANEL_PATH}/"
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

  say "Перезапускаем 3x-ui, чтобы Xray перечитал конфигурацию"
  systemctl restart x-ui || fail "x-ui restart failed after WARP update"
  sleep 5
  write_wait_for_port
  /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 30 xui-panel
  if uses_haproxy; then
    /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$(expected_xray_port)" 30 xray-vless
  else
    ss -H -lntp 2>/dev/null | grep -Eq "(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]|:::|):$(expected_xray_port)\b|:$(expected_xray_port)\b" || warn "Не увидел Xray listener на $(expected_xray_port) через ss; health проверит глубже"
  fi
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
  local auto_note file
  auto_note="/root/secure-notes/${SERVER_PREFIX}-3x-ui-auto.txt"
  file="$(vless_links_file)"
  sync_vless_links_file >/dev/null 2>&1 || true

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
  if [[ -f "$file" ]]; then
    echo "VLESS-ссылка сохранена одной строкой в файле:"
    echo "  $file"
  else
    echo "VLESS-ссылка пока не найдена в 3x-ui. Проверьте панель или выполните health --deep."
  fi
  echo
  echo "Показать VLESS-ссылку на экран:"
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
      if sync_vless_links_file; then
        warn "Ниже будет показана приватная VLESS-ссылка. Не отправляйте её в публичные чаты, тикеты, скриншоты и логи."
        cat "$(vless_links_file)"
      else
        fail "VLESS-ссылка не найдена. Проверьте 3x-ui или выполните: sudo ${SERVER_PREFIX}-health --deep"
      fi
      ;;
    --file)
      sync_vless_links_file >/dev/null 2>&1 || true
      echo "$(vless_links_file)"
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
      warn "Сейчас будут показаны пароли, VLESS/MTProto ссылки и другие секреты."
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
  - index.html, login.html, docs.html, 404.html;
  - favicon.svg, favicon.ico, robots.txt;
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

/login, /docs и favicon можно заменять своим дизайном, если они остаются обычными статичными страницами и не конфликтуют со служебными route.

Роли стандартных сайтов:
  - panel/VLESS домен: нейтральная маскировка под private storage interface;
  - MTProto/sync домен: нейтральная маскировка под sync/API endpoint;
  - root/main домен: универсальная минималистичная заглушка без личной информации.

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

site_copy_stock_template(){
  local src="$1" dst="$2" label="$3"
  [[ -d "$src" ]] || fail "Стандартный шаблон сайта не найден: $src"
  mkdir -p "$dst"
  find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$src"/ "$dst"/
  else
    cp -a "$src"/. "$dst"/
  fi
  ok "Стандартный сайт восстановлен для ${label}: ${dst}"
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

  site_copy_stock_template "$KIT_DIR/sites/panel-vless-mask-site" "/var/www/${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN"
  if uses_mtproto; then
    if [[ "$PROFILE" == "root_mtproto" ]]; then
      site_copy_stock_template "$KIT_DIR/sites/mtproto-relay-mask-site" "/var/www/${SYNC_DOMAIN}" "$SYNC_DOMAIN"
    else
      site_copy_stock_template "$KIT_DIR/sites/mtproto-mask-site" "/var/www/${SYNC_DOMAIN}" "$SYNC_DOMAIN"
    fi
  fi
  if [[ "$PROFILE" == "root_mtproto" ]]; then
    site_copy_stock_template "$KIT_DIR/sites/root-mask-site" "/var/www/${ROOT_DOMAIN}" "$ROOT_DOMAIN"
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

mtproto_require(){
  uses_mtproto || fail "MTProto не включён в текущем профиле сервера."
  [[ -f /opt/mtprotoproxy/config.py ]] || fail "MTProto config не найден: /opt/mtprotoproxy/config.py"
}

mtproto_valid_user_name(){
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]{1,32}$ ]]
}

mtproto_backup(){
  local ts backup_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_dir="/root/manual-backups/mtproto-users-${ts}"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  cp -a /opt/mtprotoproxy/config.py "$backup_dir/config.py"
  cp -a /root/secure-notes/*mtproto* "$backup_dir/" 2>/dev/null || true
  prune_keep_latest /root/manual-backups 'mtproto-users-*' 4
  echo "$backup_dir"
}

mtproto_python_update(){
  local action="$1" user="${2:-}"
  XPAM_MTPROTO_ACTION="$action" XPAM_MTPROTO_USER="$user" XPAM_SYNC_DOMAIN="$SYNC_DOMAIN" XPAM_SERVER_PREFIX="$SERVER_PREFIX" python3 <<'PY_MTPROTO_USERS'
import importlib.util, os, pathlib, re, secrets, sys
from collections import OrderedDict

path=pathlib.Path('/opt/mtprotoproxy/config.py')
action=os.environ['XPAM_MTPROTO_ACTION']
user=os.environ.get('XPAM_MTPROTO_USER','')
domain=os.environ['XPAM_SYNC_DOMAIN']
prefix=os.environ['XPAM_SERVER_PREFIX']
notes=pathlib.Path('/root/secure-notes')
users_note=notes / f'{prefix}-mtproto-users.txt'
legacy_note=notes / f'{prefix}-mtproto.txt'

spec=importlib.util.spec_from_file_location('mtproto_config', str(path))
cfg=importlib.util.module_from_spec(spec)
spec.loader.exec_module(cfg)
users=OrderedDict((str(k), str(v)) for k,v in getattr(cfg,'USERS',{}).items())
limits=dict(getattr(cfg,'USER_MAX_TCP_CONNS',{}))
exp=dict(getattr(cfg,'USER_EXPIRATIONS',{}))
quota=dict(getattr(cfg,'USER_DATA_QUOTA',{}))

def fail(msg):
    print('ERROR:', msg, file=sys.stderr)
    sys.exit(1)

def validate_users():
    if not users:
        fail('USERS is empty; at least one MTProto user is required')
    for name, sec in users.items():
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,32}', name):
            fail(f'bad MTProto user name: {name}')
        if not re.fullmatch(r'[0-9a-fA-F]{32}', sec):
            fail(f'bad MTProto secret format for user {name}')

def py_dict(d):
    items=[]
    for k,v in d.items():
        items.append(f'{k!r}: {v!r}')
    return '{ ' + ', '.join(items) + ' }'

def replace_or_append(text, name, value):
    line=f'{name} = {value}'
    pattern=re.compile(rf'^{name}\s*=.*$', re.M)
    if pattern.search(text):
        return pattern.sub(line, text)
    return text.rstrip()+f'\n{line}\n'

def link_for(sec):
    return f'tg://proxy?server={domain}&port=443&secret=ee{sec}{domain.encode().hex()}'

def write_notes():
    notes.mkdir(mode=0o700, parents=True, exist_ok=True)
    body=['MTProto users for XPAM Script v1.1.0','==================================================','']
    for name, sec in users.items():
        body.append(f'User: {name}')
        body.append(f'Link: {link_for(sec)}')
        body.append('')
    users_note.write_text('\n'.join(body), encoding='utf-8')
    users_note.chmod(0o600)
    first_name = prefix if prefix in users else next(iter(users))
    legacy_note.write_text('MTProto proxy for XPAM Script v1.1.0\n==================================================\nLink: '+link_for(users[first_name])+'\n', encoding='utf-8')
    legacy_note.chmod(0o600)

if action == 'list':
    validate_users()
    for name, sec in users.items():
        print(f'{name}\t{sec[:4]}...[REDACTED]...{sec[-4:]}')
    sys.exit(0)

if action == 'show-link':
    validate_users()
    if user not in users:
        fail(f'MTProto user not found: {user}')
    print(link_for(users[user]))
    sys.exit(0)

if action == 'add':
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,32}', user):
        fail('bad user name; use letters, digits, underscore or dash, max 32 chars')
    if user in users:
        fail(f'MTProto user already exists: {user}')
    users[user]=secrets.token_hex(16)
elif action == 'delete':
    validate_users()
    if user not in users:
        fail(f'MTProto user not found: {user}')
    if len(users) <= 1:
        fail('cannot delete the last MTProto user')
    users.pop(user, None)
    limits.pop(user, None); exp.pop(user, None); quota.pop(user, None)
elif action == 'regen':
    validate_users()
    if user not in users:
        fail(f'MTProto user not found: {user}')
    users[user]=secrets.token_hex(16)
elif action == 'rewrite-notes':
    validate_users()
else:
    fail(f"unknown action: {action}")

validate_users()
text=path.read_text(encoding='utf-8')
text=replace_or_append(text, 'USERS', py_dict(users))
text=replace_or_append(text, 'USER_MAX_TCP_CONNS', py_dict(limits))
text=replace_or_append(text, 'USER_EXPIRATIONS', py_dict(exp))
text=replace_or_append(text, 'USER_DATA_QUOTA', py_dict(quota))
path.write_text(text, encoding='utf-8')
path.chmod(0o600)
# Import again after write to validate syntax/runtime.
spec=importlib.util.spec_from_file_location('mtproto_config_new', str(path))
new_cfg=importlib.util.module_from_spec(spec)
spec.loader.exec_module(new_cfg)
write_notes()
if action in {'add','regen'}:
    print(link_for(users[user]))
else:
    print('OK')
PY_MTPROTO_USERS
}

mtproto_restart_check(){
  systemctl restart mtprotoproxy
  systemctl is-active --quiet mtprotoproxy || fail "mtprotoproxy is not active after restart"
  ok "mtprotoproxy active"
  if [[ -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]]; then
    run_health_quiet "mtproto-users"
  fi
}

mtproto_list_users(){
  need_root; load_config; validate_inputs; mtproto_require
  echo "MTProto пользователи:"
  echo
  local printed=0
  mtproto_python_update list | while IFS=$'\t' read -r name masked; do
    [[ -n "$name" ]] || continue
    if [[ "$printed" == "1" ]]; then
      echo
    fi
    printed=1
    echo "username: $name"
    echo "key: $masked"
  done
}

mtproto_add_user(){
  need_root; load_config; validate_inputs; mtproto_require
  local user backup_dir link
  read -r -p "Введите имя нового MTProto пользователя [a-z A-Z 0-9 _ -]: " user || true
  mtproto_valid_user_name "$user" || fail "Имя пользователя должно содержать только буквы, цифры, _ или -, максимум 32 символа"
  backup_dir="$(mtproto_backup)"
  ok "Backup MTProto config создан: $backup_dir"
  link="$(mtproto_python_update add "$user")"
  mtproto_restart_check
  echo
  warn "Это приватная ссылка подключения. Не отправляйте её в публичные чаты, тикеты, скриншоты и логи."
  echo "username: $user"
  echo "link: $link"
}

mtproto_show_user_link(){
  need_root; load_config; validate_inputs; mtproto_require
  mtproto_list_users
  local user link
  read -r -p "Введите имя MTProto пользователя: " user || true
  mtproto_valid_user_name "$user" || fail "Некорректное имя пользователя"
  link="$(mtproto_python_update show-link "$user")"
  echo
  warn "Это приватная ссылка подключения. Не отправляйте её в публичные чаты, тикеты, скриншоты и логи."
  echo "username: $user"
  echo "link: $link"
}

mtproto_delete_user(){
  need_root; load_config; validate_inputs; mtproto_require
  mtproto_list_users
  local user confirm backup_dir
  read -r -p "Введите имя MTProto пользователя для удаления: " user || true
  mtproto_valid_user_name "$user" || fail "Некорректное имя пользователя"
  read -r -p "Для подтверждения введите delete-${user}: " confirm || true
  [[ "$confirm" == "delete-${user}" ]] || fail "Удаление отменено"
  backup_dir="$(mtproto_backup)"
  ok "Backup MTProto config создан: $backup_dir"
  mtproto_python_update delete "$user" >/dev/null
  mtproto_restart_check
  ok "MTProto пользователь удалён: $user"
}

mtproto_regenerate_user_key(){
  need_root; load_config; validate_inputs; mtproto_require
  mtproto_list_users
  local user confirm backup_dir link
  read -r -p "Введите имя MTProto пользователя для замены ключа: " user || true
  mtproto_valid_user_name "$user" || fail "Некорректное имя пользователя"
  warn "Старый MTProto link этого пользователя перестанет работать."
  read -r -p "Для подтверждения введите regen-${user}: " confirm || true
  [[ "$confirm" == "regen-${user}" ]] || fail "Замена ключа отменена"
  backup_dir="$(mtproto_backup)"
  ok "Backup MTProto config создан: $backup_dir"
  link="$(mtproto_python_update regen "$user")"
  mtproto_restart_check
  echo
  warn "Это приватная ссылка подключения. Не отправляйте её в публичные чаты, тикеты, скриншоты и логи."
  echo "username: $user"
  echo "new link: $link"
}

print_telega_summary(){
  local mt_note mt_users_note
  mt_note="/root/secure-notes/${SERVER_PREFIX}-mtproto.txt"
  mt_users_note="/root/secure-notes/${SERVER_PREFIX}-mtproto-users.txt"
  echo
  echo "============================================================"
  echo "MTProto-подключение"
  echo "============================================================"
  echo
  echo "Эта команда по умолчанию НЕ печатает MTProto-ссылки, чтобы случайно не раскрыть доступ."
  echo
  echo "Файлы с MTProto-данными:"
  [[ -f "$mt_note" ]] && echo "  Основная ссылка:       $mt_note"
  [[ -f "$mt_users_note" ]] && echo "  Пользователи:          $mt_users_note"
  echo
  echo "Показать MTProto-ссылки на экран:"
  echo "  sudo ${SERVER_PREFIX}-telega --show"
  echo
  echo "Управлять MTProto-пользователями:"
  echo "  sudo ${SERVER_PREFIX}-telega --manage"
  echo
  echo "Проверить сервер:"
  echo "  sudo ${SERVER_PREFIX}-health"
  echo "============================================================"
}

mtproto_show_all_links(){
  need_root; load_config; validate_inputs; mtproto_require
  local mt_users_note mt_note
  mt_users_note="/root/secure-notes/${SERVER_PREFIX}-mtproto-users.txt"
  mt_note="/root/secure-notes/${SERVER_PREFIX}-mtproto.txt"
  warn "Ниже будут показаны приватные MTProto-ссылки. Не отправляйте их в публичные чаты, тикеты, скриншоты и логи."
  if [[ -s "$mt_users_note" ]]; then
    cat "$mt_users_note"
  elif [[ -s "$mt_note" ]]; then
    cat "$mt_note"
  else
    fail "MTProto note file не найден. Выполните health или repair."
  fi
}

stage_telega_direct(){
  need_root
  load_config
  validate_inputs
  mtproto_require
  case "${1:-}" in
    --show)
      mtproto_show_all_links
      ;;
    --manage)
      stage_mtproto_users_menu
      ;;
    --list)
      mtproto_list_users
      ;;
    ""|--help|-h)
      print_telega_summary
      ;;
    *)
      fail "Неизвестный параметр. Используйте: sudo ${SERVER_PREFIX}-telega, sudo ${SERVER_PREFIX}-telega --show или sudo ${SERVER_PREFIX}-telega --manage"
      ;;
  esac
}

stage_mtproto_users_menu(){
  need_root
  load_config
  validate_inputs
  mtproto_require
  echo "MTProto пользователи"
  echo "1) Показать список пользователей"
  echo "2) Добавить пользователя"
  echo "3) Показать ссылку пользователя"
  echo "4) Удалить пользователя"
  echo "5) Перегенерировать ключ пользователя"
  echo "6) Выйти"
  local choice
  read -r -p "Выберите пункт [1-6]: " choice || true
  case "$choice" in
    1) mtproto_list_users ;;
    2) mtproto_add_user ;;
    3) mtproto_show_user_link ;;
    4) mtproto_delete_user ;;
    5) mtproto_regenerate_user_key ;;
    6) return 0 ;;
    *) fail "Неизвестный пункт меню" ;;
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
  if uses_mtproto; then
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
  echo "Что repair НЕ делает: не меняет домены, VLESS UUID, MTProto secret,"
  echo "не удаляет пользователей и не переписывает /etc/network/interfaces."
  echo
  say "Repair XPAM service policy"
  verify_ssh_preflight || true
  setup_dns_policy || true
  apply_network_tuning_policy || true
  apply_service_nofile_limits || true
  write_wait_for_port || true
  write_certbot_hook || true
  write_health_weekly || true
  apply_service_hygiene || true
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || systemctl restart nginx || true
  systemctl try-restart x-ui || true
  if uses_mtproto; then
    systemctl try-restart mtprotoproxy || true
    systemctl try-reload-or-restart haproxy || true
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
  echo "6) Выйти"
  local choice
  read -r -p "Выберите пункт [0-6]: " choice
  case "$choice" in
    0) stage_ssh_hardening ;;
    1) need_root; load_config; "/usr/local/sbin/${SERVER_PREFIX}-health" --deep ;;
    2) stage_netdiag ;;
    3) stage_repair ;;
    4) final_production_cleanup ;;
    5) show_config ;;
    6) return 0 ;;
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
  echo "6) Управление сайтами"
  echo "7) Дополнительно"
  echo "8) Выход"
  echo
  if [[ ! -s /etc/xpam-script/prefix.env ]]; then
    echo "Первый запуск? Сначала выберите пункт 0."
  fi
  local choice
  read -r -p "Выберите пункт [0-8]: " choice
  case "$choice" in
    0) stage_ssh_hardening ;;
    1) stage_install_continue ;;
    2) stage_show_details ;;
    3) stage_check_only ;;
    4) stage_notify ;;
    5) stage_warp_menu ;;
    6) stage_site_menu ;;
    7) stage_advanced_menu ;;
    8) exit 0 ;;
    a|A) stage_prepare ;;
    b|B) stage_finalize ;;
    *) fail "Неизвестный пункт меню" ;;
  esac
  exit 0
}
