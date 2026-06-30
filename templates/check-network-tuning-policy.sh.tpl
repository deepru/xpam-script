#!/usr/bin/env bash
set -u

FAIL=0
NET_LOCKED=0   # set to 1 on container/locked-sysctl hosts where net.* is provider-controlled

ok() { echo "OK: $*"; }
warn() { echo "WARNING: $*"; }
bad() { echo "FAIL: $*"; FAIL=1; }
note() { echo "INFO: $*"; }
# On a locked/container kernel a net.* RUNTIME mismatch is environmental: not breakage and not
# fixable from inside the box, so it must not FAIL a healthy server -> report INFO. The XPAM
# persistent policy FILE (which we DO control) is still held to FAIL separately.
runtime_miss() { if [ "$NET_LOCKED" -eq 1 ]; then note "$*"; else bad "$*"; fi; }

expect_sysctl() {
  local key="$1" expected="$2" actual
  actual="$(sysctl -n "$key" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')" || {
    runtime_miss "missing sysctl: $key"
    return
  }

  if [ "$actual" = "$expected" ]; then
    ok "$key = $actual"
  else
    runtime_miss "$key expected '$expected', got '$actual'"
  fi
}

is_tunnel_dev() {
  case "${1:-}" in
    wg*|tun*|tap*|warp*|CloudflareWARP*|tailscale*) return 0 ;;
    *) return 1 ;;
  esac
}

pick_physical_dev() {
  ip -o link show up 2>/dev/null \
    | awk -F': ' '{print $2}' \
    | sed 's/@.*//' \
    | grep -Ev '^(lo|wg[0-9]*|tun[0-9]*|tap[0-9]*|warp.*|CloudflareWARP.*|tailscale.*|docker.*|br-.*|veth.*)$' \
    | head -n 1
}

check_qdisc_dev() {
  local dev="$1"
  [ -n "$dev" ] || return 1
  echo "Checking qdisc on dev: $dev"
  if tc qdisc show dev "$dev" 2>/dev/null | grep -q 'fq'; then
    ok "fq qdisc is present on $dev"
  else
    runtime_miss "fq qdisc not found on $dev"
    tc qdisc show dev "$dev" 2>/dev/null || true
  fi
}

diagnose_tcp_syncookies() {
  local actual xpam_file conflict_found line value
  xpam_file="/etc/sysctl.d/99-xpam-script-network-tuning.conf"
  actual="$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null | tr -d '[:space:]' || true)"

  echo
  echo "===== TCP SYNCOOKIES DIAGNOSTICS ====="

  if [ ! -f "$xpam_file" ]; then
    bad "tcp_syncookies persistent policy is missing: $xpam_file"
  elif ! grep -Eq '^[[:space:]]*net\.ipv4\.tcp_syncookies[[:space:]]*=[[:space:]]*1([[:space:]]*(#.*)?)?$' "$xpam_file"; then
    bad "tcp_syncookies XPAM policy is missing or broken in $xpam_file"
  else
    ok "tcp_syncookies XPAM policy file contains net.ipv4.tcp_syncookies = 1"
  fi

  conflict_found=0
  while IFS= read -r line; do
    value="$(printf '%s' "$line" | sed -E 's/^[^:]+:[0-9]+:[[:space:]]*net\.ipv4\.tcp_syncookies[[:space:]]*=[[:space:]]*([^#[:space:]]+).*/\1/')"
    if [ "$value" != "1" ]; then
      warn "conflicting persistent tcp_syncookies assignment: $line"
      conflict_found=1
    fi
  done < <(grep -RnsE '^[[:space:]]*net\.ipv4\.tcp_syncookies[[:space:]]*=' /etc/sysctl.conf /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d 2>/dev/null || true)

  if [ "$conflict_found" -eq 0 ]; then
    ok "no conflicting persistent tcp_syncookies assignment found"
  elif [ "$actual" = "1" ]; then
    warn "tcp_syncookies runtime is currently 1, but a conflicting persistent assignment may override it after sysctl --system or reboot"
  fi

  if [ "$actual" != "1" ]; then
    runtime_miss "tcp_syncookies runtime drift/override detected: expected 1, got ${actual:-missing}. Run sudo <prefix>-repair to restore XPAM runtime policy; if it returns to 0, provider/kernel or a later sysctl file is overriding it."
  fi
}

detect_net_locked() {
  local virt cur
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "$virt" in
    openvz|lxc|lxc-libvirt|docker|podman|rkt|systemd-nspawn|container-other) NET_LOCKED=1 ;;
  esac
  # Probe: writing a net.* key back its own current value is a harmless no-op on a writable
  # kernel, but is denied on container/locked-sysctl hosts -> treat the box as net-locked.
  cur="$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || true)"
  if [ -n "$cur" ] && ! sysctl -w "net.ipv4.tcp_syncookies=$cur" >/dev/null 2>&1; then
    NET_LOCKED=1
  fi
  if [ "$NET_LOCKED" -eq 1 ]; then
    note "container/locked-sysctl environment (systemd-detect-virt='${virt:-unknown}'); net.* tunables are provider-controlled, so runtime sysctl mismatches below are informational, not failures"
  fi
}
detect_net_locked

echo "===== NETWORK TUNING POLICY CHECK ====="

expect_sysctl net.ipv4.tcp_congestion_control "bbr"
expect_sysctl net.core.default_qdisc "fq"
expect_sysctl net.core.rmem_max "33554432"
expect_sysctl net.core.wmem_max "33554432"
expect_sysctl net.ipv4.tcp_rmem "4096 131072 33554432"
expect_sysctl net.ipv4.tcp_wmem "4096 65536 33554432"
expect_sysctl net.core.somaxconn "4096"
expect_sysctl net.ipv4.tcp_max_syn_backlog "8192"
expect_sysctl net.core.netdev_max_backlog "8192"
expect_sysctl net.ipv4.tcp_mtu_probing "1"
expect_sysctl net.ipv4.tcp_slow_start_after_idle "0"
expect_sysctl net.ipv4.tcp_syncookies "1"
expect_sysctl net.ipv4.tcp_fin_timeout "15"
expect_sysctl net.ipv4.tcp_tw_reuse "2"
expect_sysctl net.ipv4.ip_local_port_range "1024 65535"

echo
echo "===== PERSISTENT CONFIG CHECK ====="

if [ -f /etc/sysctl.d/99-xpam-script-network-tuning.conf ]; then
  ok "persistent sysctl file exists: /etc/sysctl.d/99-xpam-script-network-tuning.conf"
else
  bad "missing /etc/sysctl.d/99-xpam-script-network-tuning.conf"
fi

if [ -f /etc/modules-load.d/tcp_bbr.conf ]; then
  if grep -qx 'tcp_bbr' /etc/modules-load.d/tcp_bbr.conf; then
    ok "tcp_bbr module-load config is correct"
  else
    bad "/etc/modules-load.d/tcp_bbr.conf exists but content is not exactly tcp_bbr"
  fi
else
  bad "missing /etc/modules-load.d/tcp_bbr.conf"
fi

diagnose_tcp_syncookies

echo
echo "===== QDISC CHECK ====="

DEV="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"

if [ -n "${DEV:-}" ]; then
  echo "Route-to-1.1.1.1 dev: $DEV"
  if is_tunnel_dev "$DEV"; then
    warn "default route probe uses tunnel/WARP dev $DEV; this is external to XPAM Script 3x-ui WARP"
    PHY_DEV="$(pick_physical_dev || true)"
    if [ -n "${PHY_DEV:-}" ]; then
      check_qdisc_dev "$PHY_DEV"
    else
      warn "could not detect a non-tunnel active interface; skipping qdisc device check"
    fi
  else
    check_qdisc_dev "$DEV"
  fi
else
  bad "could not detect default network interface"
fi

echo
echo "===== SERVICE NOFILE LIMIT CHECK ====="

SERVICES_TO_CHECK="nginx x-ui haproxy"

for svc in $SERVICES_TO_CHECK; do
  if systemctl cat "$svc.service" >/dev/null 2>&1; then
    state="$(systemctl is-active "$svc" 2>/dev/null || true)"
    limit="$(systemctl show "$svc" -p LimitNOFILE --value 2>/dev/null || echo 0)"

    if [ "$state" = "active" ]; then
      ok "$svc is active"
    else
      bad "$svc is installed but not active: $state"
      continue
    fi

    case "$limit" in
      ''|*[!0-9]*)
        if [ "$limit" = "infinity" ]; then
          ok "$svc LimitNOFILE = infinity"
        else
          bad "$svc LimitNOFILE is unexpected: $limit"
        fi
        ;;
      *)
        if [ "$limit" -ge 524288 ]; then
          ok "$svc LimitNOFILE = $limit"
        else
          bad "$svc LimitNOFILE too low: $limit"
        fi
        ;;
    esac
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "OK: network tuning policy looks correct"
else
  echo "FAIL: network tuning policy has problems"
fi

exit "$FAIL"
