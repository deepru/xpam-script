#!/usr/bin/env bash
set +e
XPAM_PREFIX="{{SERVER_PREFIX}}"
XPAM_CONFIG="/etc/xpam-script/config.env"
LOGDIR="/var/log/xpam-script"
mkdir -p "$LOGDIR"
chmod 700 "$LOGDIR" 2>/dev/null || true
LOG="$LOGDIR/{{SERVER_PREFIX}}-weekly-$(date +%F-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

. /usr/local/sbin/xpam-maint-common.sh
# shellcheck disable=SC1090
. "$XPAM_CONFIG"

FAIL=0
WARN=0
warn_fail(){ echo "FAIL: $*"; FAIL=1; }
warn_only(){ echo "WARN: $*"; WARN=1; }

echo "===== {{SERVER_PREFIX_UP}} WEEKLY MAINTENANCE START ====="
date
hostname -f 2>/dev/null || hostname
uptime

if ! xpam_release_upgrade_guard; then
  warn_fail "release-upgrade guard failed"
fi

echo
echo "===== CONFIG SNAPSHOT ====="
if ! xpam_config_snapshot "$XPAM_PREFIX" "${XPAM_BACKUP_KEEP:-2}"; then
  warn_fail "config snapshot failed"
fi

echo
echo "===== APT MAINTENANCE ====="
case "${XPAM_MAINT_APT_MODE:-security}" in
  off)
    echo "OK: apt maintenance disabled by config"
    ;;
  full)
    xpam_guarded_full_upgrade "$XPAM_PREFIX" || warn_fail "guarded full-upgrade failed"
    ;;
  upgrade|security|*)
    xpam_guarded_security_upgrade "$XPAM_PREFIX" || warn_fail "guarded apt upgrade failed"
    ;;
esac

echo
echo "===== CERTBOT RENEW ====="
if certbot renew --quiet; then
  echo "OK: certbot renew completed"
else
  warn_fail "certbot renew failed"
fi
if systemctl is-enabled --quiet certbot.timer && systemctl is-active --quiet certbot.timer; then
  echo "OK: certbot.timer enabled and active"
else
  warn_fail "certbot.timer is not enabled/active"
fi

xpam_service_hygiene_check "$XPAM_CONFIG" || warn_only "service hygiene check reported warnings; run sudo ${XPAM_PREFIX}-repair when repair mode is available"

echo
echo "===== QUICK HEALTH ====="
if /usr/local/sbin/{{SERVER_PREFIX}}-health; then
  echo "OK: quick health completed"
else
  warn_fail "quick health failed"
fi

echo
echo "===== CLEANUP RETENTION ====="
xpam_weekly_safe_cleanup "$XPAM_PREFIX"
xpam_prune_keep_latest "$LOGDIR" "${XPAM_PREFIX}-weekly-*.log" "${XPAM_WEEKLY_LOG_KEEP:-4}" || true
xpam_prune_keep_latest "$LOGDIR" "${XPAM_PREFIX}-health-*.log" "${XPAM_HEALTH_LOG_KEEP:-4}" || true

if ! xpam_kernel_reboot_check; then
  warn_only "reboot recommended"
fi

status="OK"
if [ "$FAIL" -ne 0 ]; then
  status="FAIL"
elif [ "$WARN" -ne 0 ]; then
  status="OK WITH WARNINGS"
fi

echo
echo "===== {{SERVER_PREFIX_UP}} WEEKLY MAINTENANCE END ====="
date
echo "Status: $status"
echo "Log: $LOG"

summary="XPAM weekly: $status
Server: $(xpam_server_label "$XPAM_PREFIX")
Host: $(hostname -f 2>/dev/null || hostname)
Log: $LOG"
case "$status" in
  FAIL) xpam_notify_once "${XPAM_PREFIX}-weekly-maintenance-fail" "$summary" 60 ;;
  "OK WITH WARNINGS") xpam_notify_once "${XPAM_PREFIX}-weekly-maintenance-warn" "$summary" 43200 ;;
esac

[ "$FAIL" -eq 0 ] || exit 1
exit 0
