#!/usr/bin/env bash
# XPAM post-reboot maintenance. Runs ONCE after an auto-upgrade reboot that weekly
# maintenance armed: a second apt pass (installs anything that only became available
# after the first batch), full cleanup, then a health verdict. Silent on success;
# Telegram only on FAIL. The unit self-disarms so it never runs on later boots.
set +e
XPAM_PREFIX="{{SERVER_PREFIX}}"
XPAM_CONFIG="/etc/xpam-script/config.env"
LOGDIR="/var/log/xpam-script"
mkdir -p "$LOGDIR"
chmod 700 "$LOGDIR" 2>/dev/null || true
LOG="$LOGDIR/{{SERVER_PREFIX}}-post-reboot-$(date +%F-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

. /usr/local/sbin/xpam-maint-common.sh
# shellcheck disable=SC1090
. "$XPAM_CONFIG"

# Disarm ourselves first thing. Even if this run dies partway, the unit must not
# turn into a run-on-every-boot service; weekly re-arms it before the next reboot
# only when another auto-upgrade needs one.
xpam_disarm_post_reboot_maint "$XPAM_PREFIX"

FAIL=0

echo "===== {{SERVER_PREFIX_UP}} POST-REBOOT MAINTENANCE START ====="
date
hostname -f 2>/dev/null || hostname
uptime

# Right after boot, x-ui/nginx/haproxy may still be coming up. Judging health now
# would false-FAIL (the same class of race as the sshd /run/sshd window). Wait up
# to ~120s for the core services to be active before we verify anything.
echo
echo "===== WAIT FOR SERVICES TO SETTLE ====="
settle_deadline=$(( $(date +%s) + 120 ))
while :; do
  a_haproxy="$(systemctl is-active haproxy.service 2>/dev/null || true)"
  a_xui="$(systemctl is-active x-ui.service 2>/dev/null || true)"
  a_nginx="$(systemctl is-active nginx.service 2>/dev/null || true)"
  if [ "$a_haproxy" = "active" ] && [ "$a_xui" = "active" ] && [ "$a_nginx" = "active" ]; then
    echo "OK: core services active (haproxy/x-ui/nginx)"
    break
  fi
  if [ "$(date +%s)" -ge "$settle_deadline" ]; then
    echo "WARN: core services not all active after settle wait (haproxy=$a_haproxy x-ui=$a_xui nginx=$a_nginx)"
    break
  fi
  sleep 5
done

echo
echo "===== SECOND APT PASS (--with-new-pkgs) ====="
if xpam_guarded_auto_upgrade "$XPAM_PREFIX"; then
  echo "OK: second apt pass finished"
else
  echo "FAIL: second apt pass failed"
  FAIL=1
fi

echo
echo "===== CLEANUP ====="
xpam_weekly_safe_cleanup "$XPAM_PREFIX" || true

echo
echo "===== HEALTH VERDICT ====="
if /usr/local/sbin/{{SERVER_PREFIX}}-health; then
  echo "OK: health check passed"
else
  echo "FAIL: health check failed"
  FAIL=1
fi

# If a reboot is STILL needed here it means the second pass pulled yet another
# reboot-requiring update (rare — e.g. a second kernel appeared minutes later). We
# deliberately do NOT reboot again (no loop): flag it so the operator is told, and
# the next weekly run finishes the job.
if xpam_reboot_is_needed; then
  echo "FAIL: reboot still required after post-reboot pass; the next weekly run will apply it"
  FAIL=1
fi

status="OK"
[ "$FAIL" -eq 0 ] || status="FAIL"

echo
echo "===== {{SERVER_PREFIX_UP}} POST-REBOOT MAINTENANCE END ====="
date
echo "Status: $status"
echo "Log: $LOG"

# FAIL-only notification (operator policy: silence on success).
if [ "$FAIL" -ne 0 ]; then
  xpam_notify_once "${XPAM_PREFIX}-post-reboot-maintenance-fail" "XPAM post-reboot maintenance: FAIL
Server: $(xpam_server_label "$XPAM_PREFIX")
Host: $(hostname -f 2>/dev/null || hostname)
Log: $LOG" 60
fi

# Always exit 0: the systemd oneshot must record success so it does not show up as
# a failed unit in health. Real problems are reported via Telegram above, not via
# the unit's exit status.
exit 0
