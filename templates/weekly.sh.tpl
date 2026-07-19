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
APT_MODE="${XPAM_MAINT_APT_MODE:-auto}"
APT_OK=1
case "$APT_MODE" in
  off)
    echo "OK: apt maintenance disabled by config"
    ;;
  auto)
    # Install ALL updates including kernels (--with-new-pkgs); the reboot decision
    # below arms the post-reboot pass and reboots when a reboot is actually needed.
    if ! xpam_guarded_auto_upgrade "$XPAM_PREFIX"; then
      warn_fail "guarded auto-upgrade failed"
      APT_OK=0
    fi
    ;;
  full)
    xpam_guarded_full_upgrade "$XPAM_PREFIX" || { warn_fail "guarded full-upgrade failed"; APT_OK=0; }
    ;;
  upgrade|security|*)
    xpam_guarded_security_upgrade "$XPAM_PREFIX" || { warn_fail "guarded apt upgrade failed"; APT_OK=0; }
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
echo "===== CLEANUP RETENTION ====="
xpam_weekly_safe_cleanup "$XPAM_PREFIX"
xpam_prune_keep_latest "$LOGDIR" "${XPAM_PREFIX}-weekly-*.log" "${XPAM_WEEKLY_LOG_KEEP:-4}" || true
xpam_prune_keep_latest "$LOGDIR" "${XPAM_PREFIX}-health-*.log" "${XPAM_HEALTH_LOG_KEEP:-4}" || true

# --- Reboot / health decision ---
# In auto mode, when updates need a reboot we reboot and defer the health verdict
# to the one-shot post-reboot maintenance unit: judging health with a freshly
# installed-but-not-yet-running kernel would false-FAIL the kernel check. In every
# other case (no reboot needed, or a non-auto apt mode) we run health inline now.
REBOOT_PENDING=0
if xpam_reboot_is_needed; then REBOOT_PENDING=1; fi

if [ "$APT_MODE" = "auto" ] && [ "$APT_OK" = "1" ] && [ "$REBOOT_PENDING" = "1" ]; then
  echo
  echo "===== AUTO-UPGRADE REBOOT ====="
  echo "Updates require a reboot. Arming post-reboot maintenance and rebooting now."
  echo "The post-reboot pass runs a second apt pass + health and notifies only on FAIL."

  # If this pre-reboot run already failed something, tell the operator now so the
  # reboot cannot swallow it. The post-reboot pass verifies independently afterwards.
  if [ "$FAIL" -ne 0 ]; then
    xpam_notify_once "${XPAM_PREFIX}-weekly-maintenance-fail" "XPAM weekly: FAIL (before auto-reboot)
Server: $(xpam_server_label "$XPAM_PREFIX")
Host: $(hostname -f 2>/dev/null || hostname)
Log: $LOG" 60
  fi

  echo
  echo "===== {{SERVER_PREFIX_UP}} WEEKLY MAINTENANCE END (rebooting) ====="
  date
  echo "Log: $LOG"
  xpam_arm_post_reboot_maint "$XPAM_PREFIX"
  sync 2>/dev/null || true
  systemctl reboot
  exit 0
fi

echo
echo "===== HEALTH ====="
if /usr/local/sbin/{{SERVER_PREFIX}}-health; then
  echo "OK: health completed"
else
  warn_fail "health failed"
fi

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

# FAIL-only notification (operator policy: silence on success and on warnings;
# warnings stay visible in this log and in <prefix>-health on demand).
if [ "$FAIL" -ne 0 ]; then
  xpam_notify_once "${XPAM_PREFIX}-weekly-maintenance-fail" "XPAM weekly: $status
Server: $(xpam_server_label "$XPAM_PREFIX")
Host: $(hostname -f 2>/dev/null || hostname)
Log: $LOG" 60
fi

[ "$FAIL" -eq 0 ] || exit 1
exit 0
