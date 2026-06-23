#!/usr/bin/env bash
set +e

if [[ "${1:-}" != "--deep" ]]; then
  XPAM_PREFIX="{{SERVER_PREFIX}}"
  LOG_DIR="/var/log/xpam-script"
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR" 2>/dev/null || true
  LOG="$LOG_DIR/${XPAM_PREFIX}-health-$(date +%Y%m%d-%H%M%S).log"
  bash "$0" --deep >"$LOG" 2>&1
  rc=$?
  chmod 600 "$LOG" 2>/dev/null || true

  echo "===== XPAM HEALTH: {{SERVER_PREFIX_UP}} ====="
  date
  echo

  warn_tmp="$(mktemp 2>/dev/null || true)"
  if [[ -n "$warn_tmp" ]]; then
    grep -E '^WARN: ' "$LOG" 2>/dev/null       | grep -Ev 'HAProxy .*historical DOWN/no-server|HAProxy .*transient DOWN/no-server|provider networking.service issue'       >"$warn_tmp" || true
  fi

  if [[ $rc -eq 0 ]]; then
    if [[ -n "$warn_tmp" && -s "$warn_tmp" ]]; then
      echo "Статус: OK WITH WARNINGS"
    else
      echo "Статус: OK"
    fi
  else
    echo "Статус: FAIL"
  fi
  echo

  qok(){
    local label="$1" pattern="$2"
    if grep -Eq "$pattern" "$LOG" 2>/dev/null; then
      echo "OK: $label"
    fi
  }

  if [[ $rc -eq 0 ]]; then
    qok "services" '^OK: services summary$'
    qok "firewall" '^OK: UFW expected policy looks correct$'
    qok "3x-ui / Xray" '^OK: 3x-ui / Xray config looks correct$'
    if grep -Eq '^OK: MTProto config invariants look correct$|^OK: 3xui-mtg MTProto runtime invariants look correct$|^OK: MTProto is not enabled in this profile; invariant check skipped$' "$LOG" 2>/dev/null; then
      echo "OK: MTProto"
    fi
    qok "TLS certificates" '^OK: TLS certificate consistency looks correct$'
    qok "public ports" '^OK: port exposure policy looks correct$'
    qok "DNS" '^OK: DNS-проверка пройдена$'
    qok "kernel/reboot" '^OK: running kernel matches newest installed kernel$'
    if grep -Eq '^OK: service hygiene looks correct$' "$LOG" 2>/dev/null && grep -Eq '^OK: config snapshot freshness looks good$' "$LOG" 2>/dev/null; then
      echo "OK: maintenance policy"
    fi
    qok "network tuning" '^OK: network tuning policy looks correct$'

    if [[ -n "$warn_tmp" && -s "$warn_tmp" ]]; then
      echo
      echo "Предупреждения:"
      head -n 8 "$warn_tmp"
    fi
  else
    echo "Причины FAIL:"
    grep -E '^(FAIL|ERROR): ' "$LOG" 2>/dev/null | head -n 12 || true
    echo
    echo "Последние строки подробного лога:"
    tail -n 50 "$LOG" 2>/dev/null || true
  fi

  [[ -n "$warn_tmp" ]] && rm -f "$warn_tmp" 2>/dev/null || true
  echo
  echo "Подробный лог: $LOG"
  echo "Для полной диагностики выполните: sudo {{SERVER_PREFIX}}-health --deep"
  exit "$rc"
fi
shift || true

XPAM_PREFIX="{{SERVER_PREFIX}}"
XPAM_CONFIG="/etc/xpam-script/config.env"
FAIL=0
. /usr/local/sbin/xpam-maint-common.sh
# shellcheck disable=SC1090
. "$XPAM_CONFIG"
warn_fail(){ echo "FAIL: $*"; FAIL=1; }
check_active(){ systemctl is-active --quiet "$1" && echo "OK: service $1 active" || warn_fail "service $1 not active"; }
check_http(){ local name="$1" exp="$2" url="$3" code; code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 12 "$url" 2>/dev/null)"; [[ "$code" == "$exp" ]] && echo "OK: $name HTTP $code" || warn_fail "$name expected $exp got $code"; }
check_redirect(){
  local name="$1" url="$2" expected_prefix="$3" out code redir
  out="$(curl -ksS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 12 "$url" 2>/dev/null)"
  code="${out%% *}"
  redir="${out#* }"
  if [[ "$code" =~ ^30(1|2|7|8)$ && "$redir" == "$expected_prefix"* ]]; then
    echo "OK: $name redirect $code -> $redir"
  else
    warn_fail "$name expected redirect to ${expected_prefix}, got HTTP ${code}, Location ${redir:-<empty>}"
  fi
}

echo "===== {{SERVER_PREFIX_UP}} DEEP HEALTH CHECK ====="
date

if ! xpam_failed_units_check; then
    FAIL=1
fi

uptime
svc_fail_before="$FAIL"
for svc in nginx x-ui fail2ban certbot.timer cron; do check_active "$svc"; done
if ! xpam_ufw_runtime_check; then FAIL=1; fi
if [ "$FAIL" = "$svc_fail_before" ]; then echo "OK: services summary"; else echo "FAIL: services summary"; fi
if ! xpam_ssh_runtime_check; then FAIL=1; fi
if ! xpam_ufw_expected_policy_check "$XPAM_CONFIG"; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-ufw-policy-fail" "[$(xpam_server_label $XPAM_PREFIX)] UFW expected policy check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
nginx -t >/dev/null 2>&1 && echo "OK: nginx config" || warn_fail "nginx config failed"
{{MTPROTO_HEALTH_BLOCK}}
{{ROOT_HEALTH_BLOCK}}
check_http "{{PRIMARY_DOMAIN}}/" 200 "https://{{PRIMARY_DOMAIN}}/"
check_redirect "{{PRIMARY_DOMAIN}} panel path no-slash" "https://{{PRIMARY_DOMAIN}}/{{PANEL_PATH}}" "https://{{PRIMARY_DOMAIN}}/{{PANEL_PATH}}/"
check_http "{{PRIMARY_DOMAIN}} panel path" 401 "https://{{PRIMARY_DOMAIN}}/{{PANEL_PATH}}/"
sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | grep -q '^passwordauthentication no$' && echo "OK: SSH password auth disabled" || warn_fail "SSH password auth not disabled"
if journalctl -u mtprotoproxy.service --no-pager -n 100 2>/dev/null | grep -Eiq 'tg://proxy|secret='; then warn_fail "possible MTProto secret in recent journal"; else echo "OK: no MTProto secret in recent journal"; fi
if ! xpam_startup_order_check "$XPAM_CONFIG"; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-startup-order-fail" "[$(xpam_server_label $XPAM_PREFIX)] HAProxy/MTProto startup order check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
if [[ "${PROFILE:-}" != "vless_direct" ]]; then
  if ! xpam_mtproto_config_invariant_check "$XPAM_CONFIG"; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-mtproto-invariants-fail" "[$(xpam_server_label $XPAM_PREFIX)] MTProto config invariant check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
  if ! xpam_mtproto_public_fallback_check "$XPAM_CONFIG"; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-mtproto-public-fallback-fail" "[$(xpam_server_label $XPAM_PREFIX)] MTProto public fallback check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
  if ! xpam_mtproto_local_tls_backend_check "$XPAM_CONFIG"; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-mtproto-local-tls-fail" "[$(xpam_server_label $XPAM_PREFIX)] MTProto local TLS backend check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
fi
if ! xpam_xui_xray_config_check "$XPAM_CONFIG"; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-xui-xray-config-fail" "[$(xpam_server_label $XPAM_PREFIX)] 3x-ui/Xray config check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
if ! xpam_xui_api_token_check "$XPAM_CONFIG"; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-xui-api-token-fail" "[$(xpam_server_label $XPAM_PREFIX)] 3x-ui API token check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
xpam_xui_version_compat_check || true
xpam_xui_fail2ban_ownership_check || true
if ! xpam_xui_subscription_sanity_check; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-xui-subscription-sanity-fail" "[$(xpam_server_label $XPAM_PREFIX)] 3x-ui subscription/Managed Hosts sanity check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
xpam_telegram_feature_separation_check || true
if ! xpam_tls_cert_check "$XPAM_CONFIG"; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-tls-cert-fail" "[$(xpam_server_label $XPAM_PREFIX)] TLS certificate check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
if ! xpam_port_exposure_check "$XPAM_CONFIG"; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-port-exposure-fail" "[$(xpam_server_label $XPAM_PREFIX)] port exposure check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
if ! xpam_service_hygiene_check "$XPAM_CONFIG"; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-service-hygiene-fail" "[$(xpam_server_label $XPAM_PREFIX)] service hygiene check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
if ! xpam_snapshot_freshness_check "$XPAM_PREFIX" 8; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-snapshot-stale" "[$(xpam_server_label $XPAM_PREFIX)] config snapshot freshness check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
if ! xpam_disk_inode_check 75 85; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-disk-inode-fail" "[$(xpam_server_label $XPAM_PREFIX)] disk/inode check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi

echo "===== SWAP POLICY CHECK ====="
mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_mb=$(( (mem_kb + 1023) / 1024 ))
swap_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
swap_mb=$(( (swap_kb + 1023) / 1024 ))
if [ "$swap_kb" -gt 0 ]; then
    echo "OK: swap is available (${swap_mb} MB)"
    if [ -e /swapfile ]; then
        mode="$(stat -c '%a' /swapfile 2>/dev/null || echo missing)"
        [ "$mode" = "600" ] && echo "OK: /swapfile permissions = 600" || warn_fail "/swapfile permissions should be 600, got $mode"
        swapon --show --noheadings 2>/dev/null | awk '$1=="/swapfile" {found=1} END {exit found ? 0 : 1}' && echo "OK: /swapfile is active" || warn_fail "/swapfile exists but is not active"
        grep -Eq '^[^#]*[[:space:]]*/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]]+sw[[:space:]]+0[[:space:]]+0([[:space:]]*)$' /etc/fstab 2>/dev/null && echo "OK: /swapfile fstab entry is correct" || warn_fail "/swapfile fstab entry should be: /swapfile none swap sw 0 0"
    fi
else
    if [ "$mem_mb" -le 4096 ]; then
        warn_fail "swap is missing on small VPS (${mem_mb} MB RAM)"
    else
        echo "OK: no swap configured; RAM is ${mem_mb} MB (>4096 MB)"
    fi
fi
swappiness="$(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
cache_pressure="$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo unknown)"
[ "$swappiness" = "10" ] && echo "OK: vm.swappiness = 10" || warn_fail "vm.swappiness expected 10, got $swappiness"
[ "$cache_pressure" = "50" ] && echo "OK: vm.vfs_cache_pressure = 50" || warn_fail "vm.vfs_cache_pressure expected 50, got $cache_pressure"

if ! xpam_kernel_reboot_check; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-reboot-required" "[$(xpam_server_label $XPAM_PREFIX)] reboot recommended on $(hostname -f 2>/dev/null || hostname)."; fi

if ! /usr/local/sbin/check-dns-policy.sh; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-dns-policy-fail" "[$(xpam_server_label $XPAM_PREFIX)] DNS policy check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi

if [ -x /usr/local/sbin/check-network-tuning-policy ]; then
    if ! /usr/local/sbin/check-network-tuning-policy; then
        FAIL=1
        xpam_notify_once "${XPAM_PREFIX}-network-tuning-policy-fail" "[$(xpam_server_label $XPAM_PREFIX)] network tuning policy check FAILED on $(hostname -f 2>/dev/null || hostname)."
    fi
else
    warn_fail "missing /usr/local/sbin/check-network-tuning-policy"
    xpam_notify_once "${XPAM_PREFIX}-network-tuning-policy-missing" "[$(xpam_server_label $XPAM_PREFIX)] check-network-tuning-policy is missing on $(hostname -f 2>/dev/null || hostname)."
fi


echo
echo "===== HTTPS TELEGRAM RELAY CHECK ====="
relay_env="/root/secure-notes/notify-relay.env"
relay_socket="/run/xpam-script-telegram-relay.sock"

if [[ -f "$relay_env" ]]; then
  if systemctl is-active --quiet telegram-https-relay.service; then
    echo "OK: telegram-https-relay.service active"
  else
    warn_fail "telegram-https-relay.service is not active"
  fi

  if [[ -S "$relay_socket" ]]; then
    echo "OK: HTTPS Relay Unix socket exists"
  else
    warn_fail "HTTPS Relay Unix socket missing: $relay_socket"
  fi

  set +u
  . /etc/xpam-script/config.env 2>/dev/null || true
  . "$relay_env" 2>/dev/null || true
  set -u

  if [[ -n "${SYNC_DOMAIN:-}" && -n "${TELEGRAM_HTTPS_RELAY_PATH:-}" && -n "${TELEGRAM_HTTPS_RELAY_TOKEN:-}" ]]; then
    relay_url="https://${SYNC_DOMAIN}/${TELEGRAM_HTTPS_RELAY_PATH}/"

    relay_code_no_token="$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$relay_url" 2>/dev/null || true)"
    if [[ "$relay_code_no_token" == "401" ]]; then
      echo "OK: Relay endpoint without token returns HTTP 401"
    else
      warn_fail "Relay endpoint without token returned HTTP ${relay_code_no_token:-none}; expected 401"
    fi

    relay_code_get_with_token="$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 -H "Authorization: Bearer ${TELEGRAM_HTTPS_RELAY_TOKEN}" "$relay_url" 2>/dev/null || true)"
    if [[ "$relay_code_get_with_token" == "405" ]]; then
      echo "OK: Relay endpoint GET with token returns HTTP 405"
    else
      warn_fail "Relay endpoint GET with token returned HTTP ${relay_code_get_with_token:-none}; expected 405"
    fi

    echo "OK: HTTPS Telegram Relay uses existing HTTPS/443 path; no separate public Relay port is expected"
  else
    warn_fail "HTTPS Relay env exists but required values are missing"
  fi
else
  echo "OK: HTTPS Telegram Relay не настроен; проверка пропущена"
fi

echo "===== RESULT ====="
if [[ "$FAIL" -eq 0 ]]; then echo "OK: {{SERVER_PREFIX_UP}} server looks healthy"; exit 0; else echo "WARNING: {{SERVER_PREFIX_UP}} server has issues"; xpam_notify_once "${XPAM_PREFIX}-health-fail" "[$(xpam_server_label $XPAM_PREFIX)] health-check FAILED on $(hostname -f 2>/dev/null || hostname)."; exit 1; fi
