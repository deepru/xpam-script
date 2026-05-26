#!/usr/bin/env bash
set +e
XPAM_PREFIX="{{SERVER_PREFIX}}"
XPAM_CONFIG="/etc/xpam-script/config.env"
FAIL=0
. /usr/local/sbin/xpam-maint-common.sh
# shellcheck disable=SC1090
. "$XPAM_CONFIG"
warn_fail(){ echo "FAIL: $*"; FAIL=1; }
check_active(){ systemctl is-active --quiet "$1" && echo "OK: service $1 active" || warn_fail "service $1 not active"; }
check_http(){ local name="$1" exp="$2" url="$3" code; code="$(curl -4ksS -o /dev/null -w '%{http_code}' --max-time 12 "$url" 2>/dev/null)"; [[ "$code" == "$exp" ]] && echo "OK: $name HTTP $code" || warn_fail "$name expected $exp got $code"; }
check_redirect(){
  local name="$1" url="$2" expected_prefix="$3" out code redir
  out="$(curl -4ksS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 12 "$url" 2>/dev/null)"
  code="${out%% *}"
  redir="${out#* }"
  if [[ "$code" =~ ^30(1|2|7|8)$ && "$redir" == "$expected_prefix"* ]]; then
    echo "OK: $name redirect $code -> $redir"
  else
    warn_fail "$name expected redirect to ${expected_prefix}, got HTTP ${code}, Location ${redir:-<empty>}"
  fi
}

echo "===== {{SERVER_PREFIX_UP}} QUICK HEALTH CHECK ====="
date

echo
echo "===== FAILED SYSTEMD UNITS ====="
_FAILED_SYSTEMD_UNITS="$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk 'NF{print}')"
if [ -n "$_FAILED_SYSTEMD_UNITS" ]; then
    systemctl --failed --no-pager || true
    warn_fail "failed systemd units present"
else
    systemctl --failed --no-pager || true
    echo "OK: no failed systemd units"
fi

uptime
for svc in nginx x-ui fail2ban certbot.timer ufw cron; do check_active "$svc"; done
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
if ! xpam_xui_xray_config_check "$XPAM_CONFIG"; then FAIL=1; xpam_notify_once "${XPAM_PREFIX}-xui-xray-config-fail" "[$(xpam_server_label $XPAM_PREFIX)] 3x-ui/Xray config check FAILED on $(hostname -f 2>/dev/null || hostname)."; fi
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

    relay_code_no_token="$(curl -4ksS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$relay_url" 2>/dev/null || true)"
    if [[ "$relay_code_no_token" == "401" ]]; then
      echo "OK: Relay endpoint without token returns HTTP 401"
    else
      warn_fail "Relay endpoint without token returned HTTP ${relay_code_no_token:-none}; expected 401"
    fi

    relay_code_get_with_token="$(curl -4ksS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 -H "Authorization: Bearer ${TELEGRAM_HTTPS_RELAY_TOKEN}" "$relay_url" 2>/dev/null || true)"
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
