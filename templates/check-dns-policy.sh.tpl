#!/usr/bin/env bash
set -u

FAIL=0
SYSTEM_TUNNEL_ACTIVE=0

ok(){ echo "OK: $*"; }
warn(){ echo "WARNING: $*"; }
bad(){ echo "FAIL: $*"; FAIL=1; }
soft_bad(){
  if [ "$SYSTEM_TUNNEL_ACTIVE" -eq 1 ]; then
    warn "$* (external system tunnel appears active; continuing as compatibility warning)"
  else
    bad "$*"
  fi
}

echo
echo "===== DNS POLICY CHECK ====="

POLICY_FILE="/etc/systemd/resolved.conf.d/10-dns-policy.conf"
RESOLV_CONF_TARGET="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
STATUS="$(resolvectl status 2>&1 || true)"

WG0_BLOCK=""
if ip link show wg0 >/dev/null 2>&1; then
  WG0_BLOCK="$(printf '%s\n' "$STATUS" | awk '
    /^Link .*wg0/ {p=1}
    /^Link / && $0 !~ /wg0/ {p=0}
    p {print}
  ')"
fi

if printf '%s\n' "$WG0_BLOCK" | grep -q "Current Scopes: DNS"; then SYSTEM_TUNNEL_ACTIVE=1; fi
if printf '%s\n' "$WG0_BLOCK" | grep -q "+DefaultRoute"; then SYSTEM_TUNNEL_ACTIVE=1; fi
if ip route show default 2>/dev/null | grep -Eq ' dev (wg0|warp|tun|CloudflareWARP)'; then SYSTEM_TUNNEL_ACTIVE=1; fi

if [ "$SYSTEM_TUNNEL_ACTIVE" -eq 1 ]; then
  warn "external system tunnel DNS or default route appears active; strict XPAM Script DNS policy checks become compatibility warnings"
fi

if systemctl is-active --quiet systemd-resolved; then ok "systemd-resolved is active"; else bad "systemd-resolved is not active"; fi
if systemctl is-enabled --quiet systemd-resolved; then ok "systemd-resolved is enabled"; else bad "systemd-resolved is not enabled"; fi

if [ "$RESOLV_CONF_TARGET" = "/run/systemd/resolve/stub-resolv.conf" ]; then
  ok "/etc/resolv.conf points to systemd-resolved stub"
else
  soft_bad "/etc/resolv.conf target is unexpected: ${RESOLV_CONF_TARGET:-<empty>}"
fi

if grep -Eq '^nameserver[[:space:]]+127\.0\.0\.53$' /etc/resolv.conf 2>/dev/null; then
  ok "/etc/resolv.conf uses local resolved stub nameserver 127.0.0.53"
else
  soft_bad "/etc/resolv.conf does not expose the local resolved stub nameserver"
fi

if [ -f "$POLICY_FILE" ]; then
  ok "DNS policy file exists: $POLICY_FILE"
else
  soft_bad "DNS policy file missing: $POLICY_FILE"
fi

if [ -f "$POLICY_FILE" ]; then
  grep -Fxq "DNS=1.1.1.1 1.0.0.1" "$POLICY_FILE" && ok "DNS policy uses Cloudflare IPv4 DNS" || soft_bad "DNS policy DNS= mismatch"
  grep -Fxq "FallbackDNS=" "$POLICY_FILE" && ok "FallbackDNS is intentionally empty" || soft_bad "FallbackDNS is not empty or missing"
  grep -Fxq "DNSOverTLS=no" "$POLICY_FILE" && ok "DNSOverTLS is disabled" || soft_bad "DNSOverTLS is not disabled"
  grep -Fxq "DNSSEC=no" "$POLICY_FILE" && ok "DNSSEC is disabled" || soft_bad "DNSSEC is not disabled"
  grep -Fxq "Cache=yes" "$POLICY_FILE" && ok "resolved cache is enabled" || soft_bad "Cache=yes missing"
  grep -Fxq "LLMNR=no" "$POLICY_FILE" && ok "LLMNR is disabled" || soft_bad "LLMNR=no missing"
  grep -Fxq "MulticastDNS=no" "$POLICY_FILE" && ok "MulticastDNS is disabled" || soft_bad "MulticastDNS=no missing"
  grep -Fxq "Domains=~." "$POLICY_FILE" && ok "global DNS routing domain is set to ~." || soft_bad "Domains=~. missing"
fi

global_dns_line="$(resolvectl dns 2>/dev/null | awk '/^Global:/ {sub(/^Global:[[:space:]]*/, ""); print; exit}' || true)"
global_domain_line="$(resolvectl domain 2>/dev/null | awk '/^Global:/ {sub(/^Global:[[:space:]]*/, ""); print; exit}' || true)"

if printf '%s\n' "$global_dns_line" | grep -Eq '(^|[[:space:]])1\.1\.1\.1([[:space:]]|$)' \
   && printf '%s\n' "$global_dns_line" | grep -Eq '(^|[[:space:]])1\.0\.0\.1([[:space:]]|$)'; then
  ok "resolvectl reports expected DNS servers"
else
  soft_bad "resolvectl does not report expected DNS servers: ${global_dns_line:-<empty>}"
fi

if printf '%s\n' "$global_domain_line" | grep -Fq '~.'; then
  ok "resolvectl reports DNS Domain ~."
else
  soft_bad "resolvectl does not report DNS Domain ~.: ${global_domain_line:-<empty>}"
fi
printf '%s\n' "$STATUS" | grep -q -- "-DNSOverTLS" && ok "resolvectl reports DNSOverTLS disabled" || soft_bad "resolvectl does not clearly report DNSOverTLS disabled"

default_dev="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
if [ -n "$default_dev" ]; then
  link_dns_line="$(resolvectl dns "$default_dev" 2>/dev/null | head -n1 || true)"
  link_domain_line="$(resolvectl domain "$default_dev" 2>/dev/null | head -n1 || true)"
  link_dns="$(printf '%s\n' "$link_dns_line" | sed 's/^Link [0-9][0-9]* ([^)]*):[[:space:]]*//' || true)"
  link_domains="$(printf '%s\n' "$link_domain_line" | sed 's/^Link [0-9][0-9]* ([^)]*):[[:space:]]*//' || true)"

  if [ -z "$link_dns" ] || [ "$link_dns" = "$link_dns_line" ]; then
    ok "no effective link DNS reported on default-route interface $default_dev"
  elif printf '%s\n' "$link_dns" | grep -Eq '(^|[[:space:]])1\.1\.1\.1([[:space:]]|$)' \
       && printf '%s\n' "$link_dns" | grep -Eq '(^|[[:space:]])1\.0\.0\.1([[:space:]]|$)' \
       && ! printf '%s\n' "$link_dns" | grep -Eq '8\.8\.8\.8|8\.8\.4\.4'; then
    if printf '%s\n' "$link_domains" | grep -Fq '~.'; then
      ok "default-route link DNS follows XPAM Script policy on $default_dev: $link_dns"
    else
      warn "default-route link DNS uses Cloudflare on $default_dev, but link routing domain is not ~.: ${link_domains:-<empty>}"
    fi
  else
    if [ "$SYSTEM_TUNNEL_ACTIVE" -eq 1 ]; then
      warn "non-XPAM Script link DNS is present on $default_dev, but an external system tunnel appears active: $link_dns"
    elif printf '%s\n' "$STATUS" | grep -Eq "DNS Domain:?[[:space:]]+~\." && printf '%s\n' "$STATUS" | grep -Eq "DNS Servers:?[[:space:]]+1\.1\.1\.1[[:space:]]+1\.0\.0\.1"; then
      warn "non-XPAM Script provider/link DNS is still visible on $default_dev despite global ~. Cloudflare policy: $link_dns"
    else
      soft_bad "provider/link DNS is visible on $default_dev and global DNS policy is not clearly authoritative: $link_dns"
    fi
  fi
else
  warn "default-route interface not detected; link DNS visibility check skipped"
fi

for d in cloudflare.com github.com ubuntu.com letsencrypt.org api.telegram.org; do
  if resolvectl query "$d" >/dev/null 2>&1; then
    ok "DNS query works: $d"
  else
    bad "DNS query failed: $d"
  fi
done


# Managed XPAM Script domains must not be shadowed to localhost by provider /etc/hosts.
# Some VPS images put the hostname/FQDN on 127.0.0.1, which can break local health checks
# even when public DNS is correct.
echo
if [ -f /etc/xpam-script/config.env ]; then
  echo "===== MANAGED DOMAIN /ETC/HOSTS CHECK ====="
  set +u
  # shellcheck disable=SC1091
  . /etc/xpam-script/config.env 2>/dev/null || true
  set -u

  managed_domains=""
  for d in "${ROOT_DOMAIN:-}" "${PRIMARY_DOMAIN:-}" "${SYNC_DOMAIN:-}"; do
    [ -n "$d" ] || continue
    case " $managed_domains " in
      *" $d "*) ;;
      *) managed_domains="$managed_domains $d" ;;
    esac
  done

  if [ -z "${managed_domains## }" ]; then
    warn "no managed domains found in config.env; skipping /etc/hosts domain shadowing check"
  else
    for d in $managed_domains; do
      if awk -v dom="$d" '
        /^[[:space:]]*#/ {next}
        $1 ~ /^127\./ {
          for (i=2; i<=NF; i++) if ($i == dom) found=1
        }
        END {exit found ? 0 : 1}
      ' /etc/hosts 2>/dev/null; then
        bad "managed domain $d is mapped to localhost in /etc/hosts; remove it from 127.* lines or map it to the server public IPv4"
      else
        ok "managed domain $d is not mapped to localhost in /etc/hosts"
      fi

      first_v4="$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}' || true)"
      if [[ "$first_v4" =~ ^127\. ]]; then
        bad "managed domain $d resolves locally to $first_v4; /etc/hosts is probably shadowing public DNS"
      elif [ -n "$first_v4" ]; then
        ok "managed domain $d local IPv4 resolution = $first_v4"
      else
        warn "managed domain $d has no local IPv4 resolution yet"
      fi
    done
  fi
else
  echo "OK: /etc/xpam-script/config.env not found; managed-domain /etc/hosts check skipped before XPAM Script configuration"
fi

if ss -tnp 2>/dev/null | grep -q ':853'; then
  soft_bad "active TCP :853 connection found; DoT should not be active in XPAM Script DNS policy"
else
  ok "no active DoT :853 connections"
fi

if ss -unp 2>/dev/null | grep -q ':853'; then
  soft_bad "active UDP :853 connection found; encrypted/alternative DNS transport should not be active in XPAM Script DNS policy"
else
  ok "no active UDP :853 connections"
fi

if ip link show wg0 >/dev/null 2>&1; then
  if printf '%s\n' "$WG0_BLOCK" | grep -q "Current Scopes: DNS"; then
    warn "wg0 has DNS scope; this is not managed by XPAM Script 3x-ui WARP"
  else
    ok "wg0 exists but is not used for system DNS"
  fi
else
  ok "wg0 absent; acceptable when WARP is unused or lazy-created by Xray"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "OK: DNS policy looks correct"
else
  echo "FAIL: DNS policy check failed"
fi

exit "$FAIL"
