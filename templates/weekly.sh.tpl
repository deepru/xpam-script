#!/usr/bin/env bash
set +e
XPAM_PREFIX="{{SERVER_PREFIX}}"
XPAM_CONFIG="/etc/xpam-script/config.env"
LOGDIR="/var/log/{{SERVER_PREFIX}}-maintenance"
mkdir -p "$LOGDIR"
chmod 700 "$LOGDIR" 2>/dev/null || true
LOG="$LOGDIR/weekly-$(date +%F-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

. /usr/local/sbin/xpam-maint-common.sh
# shellcheck disable=SC1090
. "$XPAM_CONFIG"

FAIL=0
warn_fail(){ echo "WARNING: $*"; FAIL=1; }

echo "===== {{SERVER_PREFIX_UP}} WEEKLY MAINTENANCE START ====="
date
hostname -f 2>/dev/null || hostname
uptime

echo
echo "===== PRE-SNAPSHOT SAFE CLEANUP ====="
xpam_weekly_safe_cleanup "$XPAM_PREFIX"

if ! xpam_release_upgrade_guard; then
    warn_fail "release-upgrade guard failed"
    xpam_notify_once "${XPAM_PREFIX}-release-upgrade-guard" "[$(xpam_server_label "$XPAM_PREFIX")] release-upgrade guard FAILED on $(hostname -f 2>/dev/null || hostname). Check /etc/update-manager/release-upgrades."
fi

echo
echo "===== CONFIG SNAPSHOT ====="
if ! xpam_config_snapshot "$XPAM_PREFIX" 4; then
    warn_fail "config snapshot failed"
    xpam_notify_once "${XPAM_PREFIX}-config-snapshot-fail" "[$(xpam_server_label "$XPAM_PREFIX")] config snapshot FAILED on $(hostname -f 2>/dev/null || hostname)."
fi

if ! xpam_guarded_full_upgrade "$XPAM_PREFIX"; then
    warn_fail "guarded full-upgrade failed"
    xpam_notify_once "${XPAM_PREFIX}-apt-full-upgrade-fail" "[$(xpam_server_label "$XPAM_PREFIX")] guarded full-upgrade FAILED on $(hostname -f 2>/dev/null || hostname). Check $LOG."
fi

if ! xpam_guarded_autoremove "$XPAM_PREFIX"; then
    warn_fail "guarded autoremove failed"
    xpam_notify_once "${XPAM_PREFIX}-apt-autoremove-fail" "[$(xpam_server_label "$XPAM_PREFIX")] guarded autoremove FAILED on $(hostname -f 2>/dev/null || hostname). Check $LOG."
fi

echo
echo "===== CERTBOT RENEW ====="
certbot renew --quiet || warn_fail "certbot renew failed"

echo
echo "===== SERVICE CONFIG RELOAD ====="
nginx -t && systemctl reload nginx || { systemctl restart nginx || warn_fail "nginx reload/restart failed"; }
{{MTPROTO_WEEKLY_BLOCK}}

echo
/usr/local/sbin/check-dns-policy.sh || warn_fail "DNS policy check failed"

xpam_apply_service_hygiene "$XPAM_CONFIG" || warn_fail "service hygiene apply failed"

xpam_service_hygiene_check "$XPAM_CONFIG" || warn_fail "service hygiene check failed"

echo
echo "===== HEALTH CHECK ====="
/usr/local/sbin/{{SERVER_PREFIX}}-health || warn_fail "health check failed"

if ! xpam_kernel_reboot_check; then
    warn_fail "reboot recommended"
    xpam_notify_once "${XPAM_PREFIX}-reboot-required" "[$(xpam_server_label "$XPAM_PREFIX")] reboot recommended on $(hostname -f 2>/dev/null || hostname): kernel update or reboot-required detected."
fi

xpam_weekly_safe_cleanup "$XPAM_PREFIX"

echo
echo "===== NETWORK TUNING POLICY ====="
if [ -x /usr/local/sbin/check-network-tuning-policy ]; then
    if ! /usr/local/sbin/check-network-tuning-policy; then
        warn_fail "network tuning policy failed"
        xpam_notify_once "${XPAM_PREFIX}-network-tuning-policy-fail" "[$(xpam_server_label "$XPAM_PREFIX")] network tuning policy FAILED on $(hostname -f 2>/dev/null || hostname). Check $LOG."
    fi
else
    warn_fail "missing /usr/local/sbin/check-network-tuning-policy"
    xpam_notify_once "${XPAM_PREFIX}-network-tuning-policy-missing" "[$(xpam_server_label "$XPAM_PREFIX")] check-network-tuning-policy is missing on $(hostname -f 2>/dev/null || hostname). Check $LOG."
fi

echo
echo
echo "===== FINAL FAILED SYSTEMD UNITS ====="
_FAILED_SYSTEMD_UNITS="$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk 'NF{print}')"
if [ -n "$_FAILED_SYSTEMD_UNITS" ]; then
    systemctl --failed --no-pager || true
    warn_fail "failed systemd units present"
else
    echo "OK: no failed systemd units"
fi

echo "===== {{SERVER_PREFIX_UP}} WEEKLY MAINTENANCE END ====="
date
echo "Exit status: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    xpam_notify_once "${XPAM_PREFIX}-weekly-maintenance-fail" "[$(xpam_server_label "$XPAM_PREFIX")] weekly-maintenance FAILED on $(hostname -f 2>/dev/null || hostname). Check $LOG."
fi
exit "$FAIL"
