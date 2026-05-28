#!/usr/bin/env bash
set -u

FAIL=0
MODE="${XPAM_DNS_POLICY_MODE:-safe}"
if [ -f /etc/xpam-script/config.env ]; then
  set +u
  # shellcheck disable=SC1091
  . /etc/xpam-script/config.env 2>/dev/null || true
  set -u
  MODE="${XPAM_DNS_POLICY_MODE:-${MODE:-safe}}"
fi
[ -n "$MODE" ] || MODE="safe"

ok(){ echo "OK: $*"; }
warn(){ echo "WARN: $*"; }
bad(){ echo "FAIL: $*"; FAIL=1; }

query_ok(){
  local d="$1"
  if getent ahostsv4 "$d" >/dev/null 2>&1; then
    ok "DNS работает: $d"
  else
    bad "DNS не смог разрешить: $d"
  fi
}

echo "===== XPAM DNS CHECK ====="
echo "Mode: ${MODE}"

if command -v resolvectl >/dev/null 2>&1; then
  if systemctl is-active --quiet systemd-resolved; then
    ok "systemd-resolved активен"
  else
    warn "systemd-resolved не активен; проверяем DNS через системный resolver"
  fi
else
  ok "resolvectl не установлен; это нормально в safe mode, проверяем DNS через getent"
fi

for d in github.com letsencrypt.org api.telegram.org cloudflare.com; do
  query_ok "$d"
done

# Managed XPAM domains must not be shadowed to localhost by provider /etc/hosts.
if [ -f /etc/xpam-script/config.env ]; then
  echo
  echo "===== MANAGED DOMAIN /ETC/HOSTS CHECK ====="
  set +u
  # shellcheck disable=SC1091
  . /etc/xpam-script/config.env 2>/dev/null || true
  set -u
  managed_domains=""
  for d in "${ROOT_DOMAIN:-}" "${WWW_DOMAIN:-}" "${PRIMARY_DOMAIN:-}" "${SYNC_DOMAIN:-}"; do
    [ -n "$d" ] || continue
    case " $managed_domains " in *" $d "*) ;; *) managed_domains="$managed_domains $d" ;; esac
  done
  if [ -n "${managed_domains## }" ]; then
    for d in $managed_domains; do
      if awk -v dom="$d" '
        /^[[:space:]]*#/ {next}
        $1 ~ /^127\./ { for (i=2; i<=NF; i++) if ($i == dom) found=1 }
        END {exit found ? 0 : 1}
      ' /etc/hosts 2>/dev/null; then
        bad "домен $d привязан к localhost в /etc/hosts; это ломает локальные проверки"
      else
        ok "домен $d не привязан к localhost в /etc/hosts"
      fi
      first_v4="$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}' || true)"
      if [[ "$first_v4" =~ ^127\. ]]; then
        bad "домен $d локально резолвится в $first_v4; вероятно, мешает /etc/hosts"
      elif [ -n "$first_v4" ]; then
        ok "локальный IPv4 DNS для $d = $first_v4"
      else
        warn "домен $d пока не имеет локального IPv4 DNS-ответа"
      fi
    done
  else
    warn "управляемые домены не найдены в config.env"
  fi
else
  ok "config.env ещё не создан; проверка доменов XPAM пропущена"
fi

# XPAM Auto does not replace provider DNS. Link DNS is diagnostic only in safe mode.
default_dev="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
if [ -n "$default_dev" ] && command -v resolvectl >/dev/null 2>&1; then
  link_dns="$(timeout 3s resolvectl dns "$default_dev" 2>/dev/null || true)"
  if [ -n "$link_dns" ]; then
    case "$MODE" in
      strict)
        if printf '%s\n' "$link_dns" | grep -Eq '1\.1\.1\.1.*1\.0\.0\.1|1\.0\.0\.1.*1\.1\.1\.1'; then
          warn "strict DNS mode отключён в v1.1.0; provider/link DNS показан только для диагностики: $link_dns"
        else
          warn "strict DNS mode отключён в v1.1.0; provider/link DNS показан только для диагностики: $link_dns"
        fi
        ;;
      *)
        ok "provider/link DNS виден на $default_dev и принят в safe mode: $link_dns"
        ;;
    esac
  else
    ok "link DNS на $default_dev не найден; это допустимо, если системный DNS работает"
  fi
fi

if ip link show wg0 >/dev/null 2>&1; then
  wg_block="$(timeout 3s resolvectl status wg0 2>/dev/null || true)"
  if printf '%s\n' "$wg_block" | grep -q "Current Scopes: DNS"; then
    warn "wg0 имеет DNS scope; XPAM WARP должен быть только outbound внутри Xray, не system DNS"
  else
    ok "wg0 существует, но не используется как system DNS"
  fi
else
  ok "wg0 отсутствует; это нормально, если WARP не используется или создан лениво Xray"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "OK: DNS-проверка пройдена"
else
  echo "FAIL: DNS-проверка не пройдена"
fi
exit "$FAIL"
