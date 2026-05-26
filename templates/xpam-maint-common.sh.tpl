#!/usr/bin/env bash

xpam_server_label(){ local p="${1:-server}"; printf '%s' "$p" | tr '[:lower:]' '[:upper:]'; }
xpam_run_with_heartbeat(){
    local label="$1" interval="${XPAM_HEARTBEAT_INTERVAL:-30}" elapsed=0 pid rc
    shift
    echo "WARNING: $label may take several minutes. Do not close the SSH session."
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ $((elapsed % interval)) -eq 0 ] && kill -0 "$pid" 2>/dev/null; then
            echo "OK: $label still working... ${elapsed}s"
        fi
    done
    wait "$pid"
    rc=$?
    return "$rc"
}
xpam_notify_send(){
    local msg="$1"
    local env_file="/root/secure-notes/notify.env"
    local relay_url=""
    local relay_token=""
    local mode=""

    [ -f "$env_file" ] || return 0
    # shellcheck disable=SC1090
    . "$env_file"

    mode="${TELEGRAM_MODE:-}"
    relay_url="${TELEGRAM_RELAY_URL:-}"
    relay_token="${TELEGRAM_RELAY_TOKEN:-}"

    if [ -n "$relay_url" ] && [ -n "$relay_token" ]; then
        curl -4fsS --connect-timeout 3 --max-time 8 \
          -X POST "$relay_url" \
          -H "Authorization: Bearer ${relay_token}" \
          --data-binary "$msg" \
          >/dev/null 2>&1 || true
        return 0
    fi

    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || return 0
    [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0

    curl -4fsS --connect-timeout 3 --max-time 8 \
      -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${msg}" \
      >/dev/null 2>&1 || true

    return 0
}
xpam_notify_once(){
    local key="$1"
    local msg="$2"
    local cooldown="${3:-43200}"
    local state_dir="/var/lib/xpam-notify"
    local safe_key
    safe_key="$(printf '%s' "$key" | tr -cd 'A-Za-z0-9_.:-')"
    [ -n "$safe_key" ] || safe_key="generic"

    mkdir -p "$state_dir"
    chmod 700 "$state_dir"

    local stamp="$state_dir/$safe_key"
    local now
    local last=0
    now="$(date +%s)"

    if [ -f "$stamp" ]; then
        last="$(cat "$stamp" 2>/dev/null || echo 0)"
    fi

    if [ $((now - last)) -lt "$cooldown" ]; then
        return 0
    fi

    echo "$now" > "$stamp"
    chmod 600 "$stamp" 2>/dev/null || true
    xpam_notify_send "$msg"
}

xpam_prune_keep_latest(){
    local dir="$1" pattern="$2" keep="${3:-4}" old_path
    [ -d "$dir" ] || return 0
    find "$dir" -mindepth 1 -maxdepth 1 -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | awk -v keep="$keep" 'NR>keep {sub(/^[^ ]+ /,""); print}' \
      | while IFS= read -r old_path; do
            [ -n "$old_path" ] && rm -rf -- "$old_path" 2>/dev/null || true
        done
}

xpam_config_snapshot(){
    local prefix="$1"
    local keep="${2:-4}"
    local backup_dir="/root/config-backups"
    local ts
    local snapshot
    local list_file

    ts="$(date +%Y%m%d-%H%M%S)"
    snapshot="$backup_dir/${prefix}-config-${ts}.tar.gz"
    list_file="$(mktemp /tmp/${prefix}-snapshot-list.XXXXXX)"

    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"

    for p in \
      /etc/xpam-script \
      /etc/nginx \
      /etc/haproxy \
      /etc/letsencrypt/renewal \
      /etc/letsencrypt/renewal-hooks \
      /etc/systemd/system \
      /etc/systemd/resolved.conf \
      /etc/systemd/resolved.conf.d \
      /etc/sysctl.d \
      /etc/modules-load.d \
      /etc/resolv.conf \
      /etc/netplan \
      /etc/ssh/sshd_config \
      /etc/ssh/sshd_config.d \
      /etc/fail2ban \
      /etc/ufw \
      /usr/local/sbin \
      /opt/mtprotoproxy/config.py \
      /etc/x-ui/x-ui.db \
      /usr/local/x-ui/bin/config.json
    do
        [ -e "$p" ] && printf '%s
' "$p" >> "$list_file"
    done

    if [ ! -s "$list_file" ]; then
        echo "WARNING: nothing to snapshot"
        rm -f "$list_file"
        return 1
    fi

    tar --ignore-failed-read -czf "$snapshot" -T "$list_file" 2>/dev/null || true
    rm -f "$list_file"

    if [ ! -s "$snapshot" ]; then
        echo "FAIL: snapshot was not created or is empty: $snapshot"
        return 1
    fi

    chmod 600 "$snapshot"

    echo "OK: config snapshot created: $snapshot"
    ls -lh "$snapshot"
    find "$backup_dir" -maxdepth 1 -type f -name "${prefix}-config-*.tar.gz" -printf '%T@ %p
' 2>/dev/null | sort -nr | awk -v keep="$keep" 'NR>keep {print $2}' | xargs -r rm -f
    echo "OK: keeping latest $keep snapshots for prefix $prefix"
}

xpam_apt_dpkg_recovery(){
    local context="${1:-apt}" attempt audit_file apt_log
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    echo
    echo "===== APT / DPKG RECOVERY CHECK: $context ====="
    for attempt in 1 2 3; do
        audit_file="$(mktemp /tmp/${context//[^A-Za-z0-9_-]/_}-dpkg-audit.XXXXXX)"
        dpkg --audit > "$audit_file" 2>&1 || true
        if [ ! -s "$audit_file" ]; then
            rm -f "$audit_file"
            echo "OK: dpkg audit clean"
            return 0
        fi
        echo "WARNING: unfinished package configuration detected; recovery attempt ${attempt}/3"
        sed -n '1,80p' "$audit_file" | sed 's/^/  /' || true
        rm -f "$audit_file"
        echo "--- dpkg --configure -a"
        xpam_run_with_heartbeat "dpkg --configure -a" env DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
        echo "--- apt-get -f install"
        apt_log="$(mktemp /tmp/${context//[^A-Za-z0-9_-]/_}-apt-fix.XXXXXX)"
        xpam_run_with_heartbeat "apt-get -f install" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=180 -f install -y > >(tee "$apt_log") 2>&1 || true
        if grep -Eiq 'Could not get lock|Unable to acquire the dpkg frontend lock|dpkg was interrupted' "$apt_log" 2>/dev/null; then
            echo "WARNING: apt/dpkg lock or interrupted state still visible; waiting before retry"
            sleep 15
        fi
        rm -f "$apt_log"
    done
    audit_file="$(mktemp /tmp/${context//[^A-Za-z0-9_-]/_}-dpkg-audit.XXXXXX)"
    dpkg --audit > "$audit_file" 2>&1 || true
    if [ -s "$audit_file" ]; then
        echo "FAIL: Ubuntu package manager is still not healthy."
        cat "$audit_file"
        rm -f "$audit_file"
        echo "Run manually: sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a"
        echo "Then:         sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y"
        echo "Then rerun XPAM Script."
        return 1
    fi
    rm -f "$audit_file"
    echo "OK: APT/DPKG recovery finished"
}

xpam_apt_get_safe(){
    local context="$1"; shift
    local log
    xpam_apt_dpkg_recovery "$context" || return 1
    log="$(mktemp /tmp/${context//[^A-Za-z0-9_-]/_}-apt.XXXXXX)"
    if xpam_run_with_heartbeat "APT operation: $context" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=180 "$@" > >(tee "$log") 2>&1; then
        rm -f "$log"
        return 0
    fi
    if grep -Eiq 'dpkg was interrupted|Could not get lock|Unable to acquire the dpkg frontend lock|dpkg frontend lock is locked' "$log" 2>/dev/null; then
        echo "WARNING: apt reported interrupted dpkg or lock during $context; trying recovery and one retry"
        rm -f "$log"
        xpam_apt_dpkg_recovery "$context retry" || return 1
        xpam_run_with_heartbeat "APT retry: $context" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=180 "$@"
        return $?
    fi
    rm -f "$log"
    return 1
}

xpam_release_upgrade_guard(){
    echo
    echo "===== RELEASE-UPGRADE GUARD ====="
    if [ -f /etc/update-manager/release-upgrades ]; then
        sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades || return 1
        grep -nE '^Prompt=' /etc/update-manager/release-upgrades || true
    else
        echo "INFO: /etc/update-manager/release-upgrades not present; skipping"
    fi
}

xpam_guarded_full_upgrade(){
    local prefix="${1:-server}"
    xpam_apt_dpkg_recovery "$prefix full-upgrade" || return 1

    echo
    echo "===== APT UPDATE ====="
    xpam_apt_get_safe "$prefix apt update" update || return 1

    echo
    echo "===== APT FULL-UPGRADE SIMULATION ====="
    apt-get -s full-upgrade | tail -120 || return 1

    echo
    echo "===== GUARDED APT FULL-UPGRADE ====="
    xpam_apt_get_safe "$prefix full-upgrade" -o Dpkg::Options::=--force-confold full-upgrade -y || return 1

    echo "OK: guarded full-upgrade finished for $prefix"
}

xpam_guarded_autoremove(){
    local prefix="${1:-server}"
    local sim_log protected_re protected_hits

    sim_log="$(mktemp /tmp/${prefix}-autoremove-sim.XXXXXX)"

    # These packages are part of the XPAM Script runtime, remote access, TLS, firewall,
    # or optional 3x-ui/Xray WireGuard outbounds. Weekly maintenance must not remove them.
    protected_re='^(openssh-server|openssh-client|ssh|systemd|systemd-resolved|systemd-sysv|nginx|haproxy|x-ui|xray|xray-linux-amd64|certbot|cron|ufw|fail2ban|ca-certificates|curl|wget|gnupg|lsb-release|python3|python3-minimal|python3-venv|sqlite3|jq|dnsutils|iproute2|wireguard|wireguard-tools|ubuntu-minimal|ubuntu-server-minimal|ubuntu-standard|ubuntu-server)$'

    echo
    echo "===== AUTOREMOVE SIMULATION ====="
    xpam_apt_dpkg_recovery "$prefix autoremove" || return 1
    if ! apt-get -s autoremove --purge > "$sim_log" 2>&1; then
        cat "$sim_log" || true
        rm -f "$sim_log"
        return 1
    fi

    tail -120 "$sim_log"

    protected_hits="$(awk '/^(Remv|Purg)[[:space:]]+/ {print $2}' "$sim_log" | grep -E "$protected_re" || true)"
    if [ -n "$protected_hits" ]; then
        echo
        echo "FAIL: autoremove would remove protected package(s); refusing automatic autoremove"
        echo "$protected_hits" | sed 's/^/  - /'
        rm -f "$sim_log"
        return 1
    fi

    rm -f "$sim_log"

    echo
    echo "===== GUARDED AUTOREMOVE --PURGE ====="
    xpam_apt_get_safe "$prefix autoremove --purge" autoremove --purge -y || return 1
    apt-get clean || true
    apt-get autoclean -y || true

    echo "OK: guarded autoremove finished for $prefix"
}

xpam_snapshot_freshness_check(){
    local prefix="$1" max_age_days="${2:-8}" dir="/root/config-backups" count newest_line newest_epoch newest_path now age_days total_kb
    echo; echo "===== CONFIG SNAPSHOT FRESHNESS ====="
    [ -d "$dir" ] || { echo "FAIL: config backup directory missing: $dir"; return 1; }
    count="$(find "$dir" -maxdepth 1 -type f -name "${prefix}-config-*.tar.gz" 2>/dev/null | wc -l | awk '{print $1}')"
    echo "Snapshot count for ${prefix}: ${count}"
    [ "$count" -ge 1 ] || { echo "FAIL: no config snapshots found"; return 1; }
    newest_line="$(find "$dir" -maxdepth 1 -type f -name "${prefix}-config-*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 || true)"
    newest_epoch="${newest_line%% *}"; newest_path="${newest_line#* }"; newest_epoch="${newest_epoch%.*}"; now="$(date +%s)"
    age_days=$(((now - newest_epoch) / 86400))
    echo "Newest snapshot: $newest_path"; echo "Newest snapshot age: ${age_days} day(s)"
    total_kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')"; echo "Config backup total size: ${total_kb:-0} KB"
    [ "$age_days" -le "$max_age_days" ] || { echo "FAIL: newest config snapshot older than ${max_age_days} days"; return 1; }
    echo "OK: config snapshot freshness looks good"
}
xpam_disk_inode_check(){
    local warn_pct="${1:-75}" fail_pct="${2:-85}" disk_pct inode_pct fail=0
    echo; echo "===== DISK / INODE CHECK ====="
    disk_pct="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    inode_pct="$(df -Pi / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    echo "Root disk usage: ${disk_pct}%"; echo "Root inode usage: ${inode_pct}%"
    if [ "$disk_pct" -ge "$fail_pct" ]; then echo "FAIL: root filesystem usage is >= ${fail_pct}%"; fail=1; elif [ "$disk_pct" -ge "$warn_pct" ]; then echo "WARNING: root filesystem usage is >= ${warn_pct}%"; else echo "OK: root filesystem usage is below ${warn_pct}%"; fi
    if [ "$inode_pct" -ge "$fail_pct" ]; then echo "FAIL: root inode usage is >= ${fail_pct}%"; fail=1; elif [ "$inode_pct" -ge "$warn_pct" ]; then echo "WARNING: root inode usage is >= ${warn_pct}%"; else echo "OK: root inode usage is below ${warn_pct}%"; fi
    journalctl --disk-usage 2>/dev/null || true
    return "$fail"
}
xpam_kernel_reboot_check(){
    echo; echo "===== KERNEL / REBOOT CHECK ====="
    local running newest
    running="$(uname -r)"
    newest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's#^/boot/vmlinuz-##' | sort -V | tail -1 || true)"
    echo "Running kernel: $running"; echo "Newest installed kernel: ${newest:-unknown}"
    if [ -f /var/run/reboot-required ]; then echo "WARNING: /var/run/reboot-required exists"; cat /var/run/reboot-required.pkgs 2>/dev/null || true; return 1; fi
    if [ -n "${newest:-}" ] && [ "$running" != "$newest" ]; then echo "WARNING: reboot recommended to load newest installed kernel"; return 1; fi
    echo "OK: running kernel matches newest installed kernel"
}
xpam_tls_endpoint_check(){
    local label="$1" host="$2" port="$3" sni="$4" expected_dns="$5" cert_file info_file fail=0
    echo; echo "--- $label: ${host}:${port} SNI ${sni}, expect DNS:${expected_dns}"
    cert_file="$(mktemp /tmp/tls-cert.XXXXXX)"; info_file="$(mktemp /tmp/tls-info.XXXXXX)"
    timeout 12 bash -c "echo | openssl s_client -connect '${host}:${port}' -servername '${sni}' -showcerts 2>/dev/null" | awk '/-----BEGIN CERTIFICATE-----/ {p=1} p {print} /-----END CERTIFICATE-----/ {exit}' > "$cert_file" || true
    [ -s "$cert_file" ] || { echo "FAIL: no certificate received"; rm -f "$cert_file" "$info_file"; return 1; }
    openssl x509 -in "$cert_file" -noout -subject -issuer -dates -ext subjectAltName > "$info_file" 2>&1 || { echo "FAIL: cannot parse certificate"; cat "$info_file"; rm -f "$cert_file" "$info_file"; return 1; }
    cat "$info_file"
    grep -Fq "DNS:${expected_dns}" "$info_file" && echo "OK: expected DNS name found: ${expected_dns}" || { echo "FAIL: expected DNS name not found: ${expected_dns}"; fail=1; }
    openssl x509 -in "$cert_file" -checkend 1209600 -noout >/dev/null 2>&1 && echo "OK: certificate is valid for more than 14 days" || { echo "FAIL: certificate expires within 14 days"; fail=1; }
    openssl x509 -in "$cert_file" -checkend 2592000 -noout >/dev/null 2>&1 || echo "WARNING: certificate expires within 30 days"
    rm -f "$cert_file" "$info_file"; return "$fail"
}
xpam_tls_cert_check(){
    local cfg="$1" fail=0
    # shellcheck disable=SC1090
    . "$cfg"
    echo; echo "===== TLS / CERTIFICATE CONSISTENCY CHECK ====="
    xpam_tls_endpoint_check "x-ui panel" "127.0.0.1" "$XUI_PANEL_PORT" "$PRIMARY_DOMAIN" "$PRIMARY_DOMAIN" || fail=1
    if [ "$PROFILE" = "vless_direct" ]; then
        xpam_tls_endpoint_check "xray vless" "127.0.0.1" "$XRAY_PUBLIC_PORT" "$PRIMARY_DOMAIN" "$PRIMARY_DOMAIN" || fail=1
    else
        xpam_tls_endpoint_check "xray vless" "127.0.0.1" "$XRAY_LOCAL_PORT" "$PRIMARY_DOMAIN" "$PRIMARY_DOMAIN" || fail=1
        if [ "$PROFILE" = "root_mtproto" ]; then
            xpam_tls_endpoint_check "xray root site" "127.0.0.1" "$XRAY_LOCAL_PORT" "$ROOT_DOMAIN" "$ROOT_DOMAIN" || fail=1
            xpam_tls_endpoint_check "xray www alias" "127.0.0.1" "$XRAY_LOCAL_PORT" "$WWW_DOMAIN" "$WWW_DOMAIN" || fail=1
        fi
        xpam_tls_endpoint_check "nginx sync backend" "127.0.0.1" "$SYNC_BACKEND_PORT" "$SYNC_DOMAIN" "$SYNC_DOMAIN" || fail=1
    fi
    [ "$fail" -eq 0 ] && echo "OK: TLS certificate consistency looks correct"
    return "$fail"
}
xpam_port_exposure_check(){
    local cfg="$1"
    echo; echo "===== PORT EXPOSURE CHECK ====="
    ss -H -lntup 2>/dev/null || true
    python3 - "$cfg" <<'PY_PORT'
import re, subprocess, sys
from pathlib import Path
cfg={}
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line or line.startswith('#') or '=' not in line: continue
    k,v=line.split('=',1); cfg[k]=v.strip().strip("'").strip('"')
profile=cfg['PROFILE']
required_public_tcp={int(cfg['SSH_PUBLIC_PORT']), int(cfg['HTTP_PUBLIC_PORT']), int(cfg['XRAY_PUBLIC_PORT'])}
required_local_tcp={int(cfg['XUI_PANEL_PORT']), int(cfg['SITE_BACKEND_PORT'])}
allowed_local_tcp=set(required_local_tcp) | {11111, 62789}
if profile!='vless_direct':
    required_local_tcp |= {int(cfg['XRAY_LOCAL_PORT']), int(cfg['MTPROTO_PORT']), int(cfg['SYNC_BACKEND_PORT'])}
    allowed_local_tcp |= required_local_tcp
else:
    allowed_local_tcp |= {int(cfg.get('XRAY_LOCAL_PORT','1443')), int(cfg.get('MTPROTO_PORT','47827')), int(cfg.get('SYNC_BACKEND_PORT','9443'))}

def loop(h):
    h=h.strip('[]')
    return h in ('localhost','::1') or h.startswith('127.') or h.startswith('::ffff:127.')

def parse_ss(args):
    try:
        out=subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return []
    rows=[]
    for line in out.splitlines():
        parts=line.split()
        if len(parts)<4: continue
        local=parts[3]
        m=re.search(r':(\d+)$', local)
        if not m: continue
        port=int(m.group(1)); host=local[:-(len(m.group(1))+1)].strip('[]')
        rows.append((port,host,local))
    return rows

tcp_rows=parse_ss(['ss','-H','-lnt'])
udp_rows=parse_ss(['ss','-H','-lnu'])
fail=False

def nonlocal_tcp(p): return [l for port,h,l in tcp_rows if port==p and not loop(h)]
def local_tcp(p): return [l for port,h,l in tcp_rows if port==p and loop(h)]

for p in sorted(required_public_tcp):
    e=nonlocal_tcp(p)
    if e: print(f'OK: required public TCP port {p}: {", ".join(e)}')
    else: print(f'FAIL: required public TCP port {p} has no non-loopback listener'); fail=True
for p in sorted(required_local_tcp):
    e=local_tcp(p)
    if e: print(f'OK: required loopback TCP port {p}: {", ".join(e)}')
    else: print(f'FAIL: required loopback TCP port {p} has no listener'); fail=True

for port,host,local in sorted(tcp_rows):
    if loop(host):
        if port in allowed_local_tcp or port in required_public_tcp:
            continue
        if local in ('127.0.0.53%lo:53', '127.0.0.54:53'):
            print(f'OK: expected systemd-resolved loopback DNS listener {local}')
            continue
        if local.startswith('127.0.0.1:601') or local.startswith('[::1]:601'):
            print(f'OK: transient SSH X11 forwarding loopback listener {local}')
            continue
        print(f'WARNING: unexpected loopback TCP listener {local}')
        continue
    if port in required_public_tcp:
        continue
    print(f'FAIL: unexpected public TCP listener {local}; allowed public TCP ports are {sorted(required_public_tcp)}')
    fail=True

for port,host,local in sorted(udp_rows):
    if loop(host) or port==53:
        continue
    print(f'WARNING: public UDP listener {local}; verify it is intentional and firewalled as expected')

if fail: sys.exit(1)
print('OK: port exposure policy looks correct')
PY_PORT
}

xpam_ufw_expected_policy_check(){
    local cfg="$1"
    echo; echo "===== UFW EXPECTED POLICY ====="
    python3 - "$cfg" <<'EOF_PY_UFW'
import subprocess, sys
from pathlib import Path
cfg={}
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line or line.startswith('#') or '=' not in line: continue
    k,v=line.split('=',1); cfg[k]=v.strip().strip("'").strip('"')
ssh=cfg.get('SSH_PUBLIC_PORT','22'); http=cfg.get('HTTP_PUBLIC_PORT','80'); tls=cfg.get('XRAY_PUBLIC_PORT','443')
allow_v6=cfg.get('ALLOW_IPV6_443','no').lower()=='yes'
try:
    status=subprocess.check_output(['ufw','status'], text=True, stderr=subprocess.STDOUT)
except Exception as e:
    print(f'FAIL: cannot read ufw status: {e}')
    sys.exit(1)
print('Expected:')
print(f'  IPv4: {ssh}/tcp, {http}/tcp, {tls}/tcp allowed')
if allow_v6:
    print(f'  IPv6: {tls}/tcp allowed; {ssh}/tcp and {http}/tcp should be absent unless intentionally opened')
else:
    print('  IPv6: no public TCP rules expected from XPAM Script')
print('\nCurrent relevant UFW rules:')
for ln in status.splitlines():
    if any(tok in ln for tok in (f'{ssh}/tcp', f'{http}/tcp', f'{tls}/tcp')):
        print(ln)
lines=status.splitlines()
def has_rule(port, v6=None):
    needle=f'{port}/tcp'
    for ln in lines:
        if needle not in ln or 'ALLOW' not in ln: continue
        is_v6='(v6)' in ln
        if v6 is None or is_v6==v6:
            return True
    return False
fail=False
for port,label in ((ssh,'SSH'),(http,'HTTP'),(tls,'HTTPS/HAProxy-or-Xray')):
    if has_rule(port, False): print(f'OK: IPv4 {label} {port}/tcp allowed')
    else: print(f'FAIL: IPv4 {label} {port}/tcp not allowed'); fail=True
if allow_v6:
    if has_rule(tls, True): print(f'OK: IPv6 HTTPS/TLS {tls}/tcp allowed')
    else: print(f'FAIL: IPv6 HTTPS/TLS {tls}/tcp not allowed though ALLOW_IPV6_443=yes'); fail=True
    for port,label in ((ssh,'SSH'),(http,'HTTP')):
        if has_rule(port, True): print(f'WARNING: IPv6 {label} {port}/tcp is allowed; XPAM Script normally leaves it absent')
        else: print(f'OK: IPv6 {label} {port}/tcp absent')
else:
    for port,label in ((ssh,'SSH'),(http,'HTTP'),(tls,'HTTPS/TLS')):
        if has_rule(port, True): print(f'WARNING: IPv6 {label} {port}/tcp is allowed; XPAM Script did not request it')
        else: print(f'OK: IPv6 {label} {port}/tcp absent')
if fail: sys.exit(1)
print('OK: UFW expected policy looks correct')
EOF_PY_UFW
}

xpam_startup_order_check(){
    local cfg="$1" fail=0
    # shellcheck disable=SC1090
    . "$cfg"
    [ "$PROFILE" = "vless_direct" ] && return 0
    echo; echo "===== SYSTEMD STARTUP ORDER ====="
    if [ -x /usr/local/sbin/wait-for-local-port.sh ]; then echo "OK: executable exists: /usr/local/sbin/wait-for-local-port.sh"; else echo "FAIL: missing/executable wait-for-local-port.sh"; fail=1; fi
    bash -n /usr/local/sbin/wait-for-local-port.sh >/dev/null 2>&1 && echo "OK: wait-for-local-port.sh syntax" || { echo "FAIL: wait-for-local-port.sh syntax"; fail=1; }
    if [ -e /etc/systemd/system/mtprotoproxy.service.d/haproxy-order.conf ]; then echo "FAIL: obsolete mtprotoproxy haproxy-order drop-in exists"; fail=1; else echo "OK: absent as expected: /etc/systemd/system/mtprotoproxy.service.d/haproxy-order.conf"; fi
    if systemctl cat mtprotoproxy 2>/dev/null | grep -Fq "wait-for-local-port.sh 127.0.0.1 ${SYNC_BACKEND_PORT}"; then echo "OK: mtprotoproxy waits for nginx sync backend 127.0.0.1:${SYNC_BACKEND_PORT}"; else echo "FAIL: mtprotoproxy does not wait for nginx sync backend 127.0.0.1:${SYNC_BACKEND_PORT}"; fail=1; fi
    if systemctl cat haproxy 2>/dev/null | grep -Eq 'After=.*nginx.*x-ui.*mtprotoproxy|After=.*nginx.*mtprotoproxy.*x-ui|After=.*x-ui.*nginx.*mtprotoproxy|After=.*x-ui.*mtprotoproxy.*nginx|After=.*mtprotoproxy.*nginx.*x-ui|After=.*mtprotoproxy.*x-ui.*nginx'; then echo "OK: haproxy starts after nginx, x-ui, mtprotoproxy"; else echo "FAIL: haproxy ordering does not include nginx, x-ui and mtprotoproxy"; fail=1; fi
    if systemctl cat haproxy 2>/dev/null | grep -Fq "wait-for-local-port.sh 127.0.0.1 ${XRAY_LOCAL_PORT}"; then echo "OK: haproxy waits for xray local 127.0.0.1:${XRAY_LOCAL_PORT}"; else echo "FAIL: haproxy does not wait for xray local 127.0.0.1:${XRAY_LOCAL_PORT}"; fail=1; fi
    if systemctl cat haproxy 2>/dev/null | grep -Fq "wait-for-local-port.sh 127.0.0.1 ${MTPROTO_PORT}"; then echo "OK: haproxy waits for mtproto local 127.0.0.1:${MTPROTO_PORT}"; else echo "FAIL: haproxy does not wait for mtproto local 127.0.0.1:${MTPROTO_PORT}"; fail=1; fi
    /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$SYNC_BACKEND_PORT" 3 sync-backend >/dev/null 2>&1 && echo "OK: local ${SYNC_BACKEND_PORT} reachable" || { echo "FAIL: local ${SYNC_BACKEND_PORT} not reachable"; fail=1; }
    /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XRAY_LOCAL_PORT" 3 xray-local >/dev/null 2>&1 && echo "OK: local ${XRAY_LOCAL_PORT} reachable" || { echo "FAIL: local ${XRAY_LOCAL_PORT} not reachable"; fail=1; }
    /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$MTPROTO_PORT" 3 mtproto-local >/dev/null 2>&1 && echo "OK: local ${MTPROTO_PORT} reachable" || { echo "FAIL: local ${MTPROTO_PORT} not reachable"; fail=1; }
    _haproxy_since="$(systemctl show -p ActiveEnterTimestamp --value haproxy.service 2>/dev/null || true)"
    if [ -z "$_haproxy_since" ]; then _haproxy_since="now"; fi
    if journalctl -u haproxy -u mtprotoproxy --since "$_haproxy_since" --no-pager 2>/dev/null \
        | grep -Eiv "Current worker .*exited with code 143|Exiting Master process|All workers exited|Deactivated successfully|Stopping haproxy.service|Stopped haproxy.service|Started haproxy.service|Starting haproxy.service|Loading success|New worker|haproxy version is|path to executable is" \
        | grep -Eiq "no server available|backend be_mtproto has no server|backend be_xray has no server|Layer4 connection problem|Connection refused|Bad secret|Changing it to [0-9a-fA-F]{32}|failed|error"; then echo "FAIL: HAProxy/MTProto startup errors found in current HAProxy activation journal"; fail=1; else echo "OK: no HAProxy/MTProto startup errors in current HAProxy activation journal"; fi
    [ "$fail" -eq 0 ] && echo "OK: startup order looks correct"
    return "$fail"
}

xpam_xui_xray_config_check(){
    local cfg="$1"
    echo; echo "===== 3X-UI / XRAY CONFIG CHECK ====="
    python3 - "$cfg" <<'EOF_PY_XUI'
import json, sqlite3, subprocess, sys
from pathlib import Path
cfg={}
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line or line.startswith('#') or '=' not in line: continue
    k,v=line.split('=',1); cfg[k]=v.strip().strip("'").strip('"')
profile=cfg['PROFILE']; primary=cfg['PRIMARY_DOMAIN']
cert_name=cfg.get('WEB_CERT_NAME') or primary
cert=f'/etc/letsencrypt/live/{cert_name}/fullchain.pem'; key=f'/etc/letsencrypt/live/{cert_name}/privkey.pem'
expected_port=int(cfg['XRAY_LOCAL_PORT'] if profile!='vless_direct' else cfg['XRAY_PUBLIC_PORT'])
mode='local' if profile!='vless_direct' else 'public'
fallback=f"127.0.0.1:{cfg['SITE_BACKEND_PORT']}"
public_port=int(cfg['XRAY_PUBLIC_PORT'])
errs=[]
def ok(m): print('OK: '+m)
def warn(m): print('WARNING: '+m)
def bad(m): print('FAIL: '+m); errs.append(m)
def as_bool(v):
    if isinstance(v,bool): return v
    if isinstance(v,(int,float)): return bool(v)
    return str(v).lower() in ('1','true','yes','on')
def jloads(v, default):
    if v in (None,''): return default
    if isinstance(v,(dict,list)): return v
    try: return json.loads(v)
    except Exception:
        return default
print(f"Profile: {cfg.get('SERVER_PREFIX', profile)}")
print(f"Expected panel domain: {primary}")
print(f"Expected panel cert: {cert}")
print(f"Expected VLESS port: {expected_port}")
conn=sqlite3.connect('/etc/x-ui/x-ui.db'); cur=conn.cursor()
settings={str(k):'' if v is None else str(v) for k,v in cur.execute('select key,value from settings')}
print('\n--- 3x-ui database settings ---')
for k in ('webListen','webPort','webBasePath','webCertFile','webKeyFile','subCertFile','subKeyFile'):
    if k in settings: print(f'{k} = {settings.get(k,"")}')
expected_settings={'webListen':'127.0.0.1','webPort':cfg['XUI_PANEL_PORT'],'webBasePath':'/'+cfg['PANEL_PATH'].strip('/')+'/','webCertFile':cert,'webKeyFile':key}
for k,exp in expected_settings.items():
    if settings.get(k,'')==exp: ok(f'x-ui setting {k} = {exp}')
    else: bad(f'x-ui setting {k} expected {exp!r}, got {settings.get(k,"")!r}')
print('\n--- 3x-ui inbound database validation ---')
cols=[r[1] for r in cur.execute('PRAGMA table_info(inbounds)').fetchall()]
rows=[]
if cols:
    q='select '+','.join('"'+c+'"' for c in cols)+' from inbounds'
    for tup in cur.execute(q): rows.append(dict(zip(cols,tup)))
db_inb=None
for r in rows:
    if str(r.get('protocol','')).lower()=='vless' and int(r.get('port') or 0)==expected_port:
        db_inb=r; break
if not db_inb:
    bad(f'No database VLESS inbound on expected port {expected_port}')
else:
    print(f"id={db_inb.get('id')}, remark={db_inb.get('remark')}, enable={db_inb.get('enable')}, listen={db_inb.get('listen') or '<empty>'}, port={db_inb.get('port')}, protocol={db_inb.get('protocol')}")
    if as_bool(db_inb.get('enable', False)): ok('VLESS inbound is enabled in database')
    else: bad('VLESS inbound is disabled in database')
    listen=str(db_inb.get('listen') or '')
    if mode=='local':
        if listen=='127.0.0.1': ok('database VLESS inbound listen is local-only: 127.0.0.1')
        else: bad(f'database VLESS listen expected 127.0.0.1 got {listen!r}')
    else:
        if listen in ('','0.0.0.0','::','*'): ok(f'database VLESS inbound listen is public as expected: {listen or "<empty/omitted>"}')
        else: bad(f'database VLESS listen expected public/empty got {listen!r}')
    st=jloads(db_inb.get('stream_settings') or db_inb.get('streamSettings'), {})
    sett=jloads(db_inb.get('settings'), {})
    sniff=jloads(db_inb.get('sniffing'), {})
    if st.get('network')=='tcp': ok('database VLESS network is tcp')
    else: bad('database VLESS network must be tcp')
    if st.get('security')=='tls': ok('database VLESS security is tls')
    else: bad('database VLESS security must be tls')
    tcp=st.get('tcpSettings') or {}
    if tcp.get('acceptProxyProtocol') in (False, None, 0): ok('database Proxy Protocol is OFF')
    else: bad('database Proxy Protocol is enabled; HAProxy send-proxy is not part of this kit')
    if (tcp.get('header') or {}).get('type','none')=='none': ok('database TCP header/masking is none')
    else: bad('database TCP header/masking must be none')
    tls=st.get('tlsSettings') or {}
    cert_ok=any(c.get('certificateFile')==cert and c.get('keyFile')==key for c in tls.get('certificates') or [])
    if cert_ok: ok('database VLESS certificateFile/keyFile matches expected primary cert')
    else: bad('database VLESS certificateFile/keyFile mismatch')
    if 'http/1.1' in (tls.get('alpn') or []): ok('database VLESS ALPN includes http/1.1')
    else: bad('database VLESS ALPN must include http/1.1')
    fp=(tls.get('settings') or {}).get('fingerprint') or st.get('fingerprint')
    if fp in ('chrome', None, ''): ok('database uTLS/fingerprint is chrome or empty-compatible')
    else: warn(f'database uTLS/fingerprint is {fp!r}; reference servers use chrome')
    fbs=sett.get('fallbacks') or []
    good_fb=[]
    for fb in fbs:
        dest=str(fb.get('dest',''))
        if dest in (fallback, cfg['SITE_BACKEND_PORT']): good_fb.append(fb)
    if good_fb:
        ok(f'database VLESS fallback points to port {cfg["SITE_BACKEND_PORT"]}: {[fb.get("dest") for fb in good_fb]}')
        for fb in good_fb:
            if fb.get('alpn') not in ('http/1.1', '', None): bad(f'fallback ALPN should be http/1.1 or empty, got {fb.get("alpn")!r}')
            elif fb.get('alpn')=='http/1.1': ok('database fallback ALPN is http/1.1')
            if str(fb.get('name') or fb.get('sni') or ''): bad('fallback SNI/name is not empty; reference kit uses catch-all fallback')
            else: ok('database fallback SNI/name is empty catch-all')
            if str(fb.get('path') or ''): bad('fallback path is not empty; reference kit uses catch-all path')
            else: ok('database fallback path is empty')
            if int(fb.get('xver') or 0)!=0: bad('fallback PROXY/xVer is enabled; nginx fallback is not configured for proxy_protocol')
            else: ok('database fallback PROXY/xVer is OFF/0')
    else:
        bad(f'database VLESS fallback to {fallback} not found')
    ep=st.get('externalProxy') or []
    if mode=='local':
        match=[x for x in ep if isinstance(x,dict) and str(x.get('dest','')).lower()==primary.lower() and int(x.get('port') or 0)==public_port and str(x.get('forceTls','')).lower()=='same']
        if match: ok(f'database External Proxy points generated links to {primary}:{public_port} with forceTls=same')
        else:
            bad(f'database External Proxy must contain forceTls=same, dest={primary}, port={public_port}; current={ep!r}')
            if any(isinstance(x,dict) and int(x.get('port') or 0)==expected_port for x in ep): bad(f'External Proxy incorrectly uses internal port {expected_port}; it must use public port {public_port}')
    else:
        if ep: bad(f'direct VLESS mode should have External Proxy empty; current={ep!r}')
        else: ok('database External Proxy is empty for direct VLESS mode')
    if mode=='local':
        if sniff.get('enabled') in (False, None, 0):
            ok('database sniffing is OFF for HAProxy mode')
        elif sniff.get('enabled') is True and sniff.get('routeOnly') is True:
            ok('database sniffing is ON with Route only; acceptable for optional WARP/domain routing')
        else:
            warn('database sniffing is enabled without Route only; review if WARP/domain routing is intended')
    else:
        if sniff.get('enabled') is True and sniff.get('routeOnly') is True:
            ok('database sniffing is ON with Route only for direct VLESS/domain routing')
        else:
            warn('direct VLESS sniffing is not ON with Route only; acceptable only if no WARP/domain routing is needed')
config_path=Path('/usr/local/x-ui/bin/config.json')
print('\n--- Xray generated config validation ---')
try:
    config=json.loads(config_path.read_text())
    ok(f'loaded Xray config: {config_path}')
except Exception as e:
    bad(f'cannot load generated Xray config {config_path}: {e}')
    config={}
found=False
for ib in config.get('inbounds') or []:
    if ib.get('protocol')=='vless' and int(ib.get('port') or 0)==expected_port:
        listen=str(ib.get('listen') or '')
        print(f"protocol=vless, listen={listen or '<empty>'}, port={ib.get('port')}")
        if mode=='local' and listen=='127.0.0.1': ok('generated Xray VLESS inbound listen is local-only: 127.0.0.1')
        elif mode=='local': bad(f'generated Xray VLESS listen expected 127.0.0.1 got {listen!r}')
        elif mode=='public' and listen in ('','0.0.0.0','::','*'): ok(f'generated Xray VLESS inbound listen is public as expected: {listen or "<empty>"}')
        else: bad(f'generated Xray VLESS listen expected public/empty got {listen!r}')
        st=ib.get('streamSettings') or {}; tls=st.get('tlsSettings') or {}
        if st.get('network')=='tcp': ok('generated Xray VLESS network is tcp')
        else: bad('generated Xray VLESS network must be tcp')
        if st.get('security')=='tls': ok('generated Xray VLESS security is tls')
        else: bad('generated Xray VLESS security must be tls')
        if (st.get('tcpSettings') or {}).get('acceptProxyProtocol') in (False, None, 0): ok('generated Xray Proxy Protocol is OFF')
        else: bad('generated Xray Proxy Protocol is enabled unexpectedly')
        cert_ok=any(c.get('certificateFile')==cert and c.get('keyFile')==key for c in tls.get('certificates') or [])
        if cert_ok: ok('generated Xray certificateFile/keyFile matches expected primary cert')
        else: bad('generated Xray certificateFile/keyFile mismatch')
        fb_ok=any(str(fb.get('dest')) in (fallback, cfg['SITE_BACKEND_PORT']) for fb in (ib.get('settings') or {}).get('fallbacks') or [])
        if fb_ok: ok(f'generated Xray fallback points to port {cfg["SITE_BACKEND_PORT"]}')
        else: bad(f'generated Xray fallback to {fallback} not found')
        found=True
if not found: bad(f'No generated Xray VLESS inbound on port {expected_port}')
print('\n--- OPTIONAL WARP / WireGuard validation ---')
outbounds=config.get('outbounds') or []
rules=(config.get('routing') or {}).get('rules') or []
wg=[ob for ob in outbounds if isinstance(ob,dict) and ob.get('protocol')=='wireguard']

def first_peer(settings):
    peers=settings.get('peers') or []
    return peers[0] if peers and isinstance(peers[0], dict) else {}

def is_ipv4_cidr(v):
    return isinstance(v,str) and ':' not in v and '/' in v

def warn_setting(name, got, expected):
    warn(f'WARP setting {name} is {got!r}; recommended value is {expected!r}')

if not wg:
    ok('no WireGuard/WARP outbound in Xray config; WARP is optional')
else:
    ok(f'generated Xray config contains {len(wg)} WireGuard outbound(s)')
    warp_obs=[ob for ob in wg if ob.get('tag')=='warp']
    custom_wg=[ob for ob in wg if ob.get('tag')!='warp']

    if warp_obs:
        ok('WireGuard outbound tag warp exists')
    else:
        ok('no XPAM Script WARP outbound tag=warp found; custom WireGuard outbounds are user-managed')

    if custom_wg:
        ok(f'{len(custom_wg)} additional WireGuard outbound(s) ignored as user-managed')

    warp_route_count=sum(1 for r in rules if isinstance(r,dict) and r.get('outboundTag')=='warp')
    ok(f'WARP/3x-ui routing domains/IPs are user-managed; {warp_route_count} rule(s) to outboundTag=warp found; route contents are not validated')

    for ob in warp_obs:
        tag=str(ob.get('tag') or '<empty>')
        settings=ob.get('settings') or {}
        peer=first_peer(settings)
        if settings.get('mtu')==1420: ok(f'WARP {tag}: mtu=1420')
        else: warn_setting(f'{tag}.mtu', settings.get('mtu'), 1420)
        addrs=settings.get('address') or []
        if any(is_ipv4_cidr(a) for a in addrs) and not any(isinstance(a,str) and ':' in a for a in addrs):
            ok(f'WARP {tag}: address is IPv4-only')
        else:
            warn(f'WARP {tag}: address should be IPv4-only, got {addrs!r}')
        if settings.get('domainStrategy')=='ForceIPv4': ok(f'WARP {tag}: domainStrategy=ForceIPv4')
        else: warn_setting(f'{tag}.domainStrategy', settings.get('domainStrategy'), 'ForceIPv4')
        if settings.get('workers')==2: ok(f'WARP {tag}: workers=2')
        else: warn_setting(f'{tag}.workers', settings.get('workers'), 2)
        allowed=peer.get('allowedIPs') or []
        if '0.0.0.0/0' in allowed and '::/0' not in allowed:
            ok(f'WARP {tag}: peer allowedIPs are IPv4-only')
        else:
            warn(f'WARP {tag}: peer allowedIPs should include 0.0.0.0/0 and not ::/0, got {allowed!r}')
        if peer.get('keepAlive')==25: ok(f'WARP {tag}: peer keepAlive=25')
        else: warn_setting(f'{tag}.peer.keepAlive', peer.get('keepAlive'), 25)
        if settings.get('noKernelTun') is False: ok(f'WARP {tag}: noKernelTun=false')
        else: warn_setting(f'{tag}.noKernelTun', settings.get('noKernelTun'), False)

try:
    subprocess.check_call(['ip','link','show','wg0'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ok('wg0 currently exists; acceptable when WARP/WireGuard is active or lazy-created by Xray')
except Exception:
    ok('wg0 absent; acceptable when WARP is unused or lazy-created only after routed traffic')

try:
    default_routes=subprocess.check_output(['ip','route','show','default'], text=True, stderr=subprocess.DEVNULL)
    if any((' dev wg0' in line or ' dev warp' in line.lower() or ' dev tun' in line.lower()) for line in default_routes.splitlines()):
        warn('system default route appears to use WARP/tunnel; XPAM Script WARP is intended to run only inside 3x-ui/Xray')
    else:
        ok('system default route is not obviously through wg0/WARP')
except Exception as e:
    warn(f'could not inspect system default route: {e}')

try:
    status=subprocess.check_output(['resolvectl','status'], text=True, stderr=subprocess.DEVNULL)
    lines=status.splitlines()
    block=[]; capture=False
    for line in lines:
        if line.startswith('Link ') and 'wg0' in line:
            capture=True; block=[line]; continue
        if line.startswith('Link ') and capture:
            capture=False
        if capture: block.append(line)
    block_text='\n'.join(block)
    if block_text and 'Current Scopes: DNS' in block_text:
        warn('wg0 has system DNS scope; XPAM Script WARP is intended to run only inside 3x-ui/Xray')
    elif block_text:
        ok('wg0 exists but is not used for system DNS')
    else:
        ok('wg0 has no resolvectl DNS block')
except Exception as e:
    warn(f'could not inspect resolvectl wg0 state: {e}')
if errs: sys.exit(1)
print('\nOK: 3x-ui / Xray config looks correct')
EOF_PY_XUI
}


xpam_unit_exists(){
    local unit="$1"
    systemctl list-unit-files "$unit" --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit" && return 0
    systemctl status "$unit" >/dev/null 2>&1
}

xpam_stop_disable_mask_unit(){
    local unit="$1" state enabled
    xpam_unit_exists "$unit" || return 0
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    if [ "$state" != "active" ] && [ "$enabled" = "masked" ]; then
        echo "OK: $unit already masked"
        return 0
    fi
    echo "FIXED: disable/mask $unit"
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
    systemctl mask "$unit" >/dev/null 2>&1 || true
}

xpam_guarded_purge_package(){
    local pkg="$1" sim protected
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || return 0
    echo "--- guarded purge candidate: $pkg"
    sim="$(DEBIAN_FRONTEND=noninteractive apt-get -s purge "$pkg" 2>&1 || true)"
    printf '%s\n' "$sim" | tail -80
    protected='Remv (openssh-server|openssh-client|ssh|systemd|systemd-resolved|nginx|haproxy|fail2ban|ufw|certbot|cron|ca-certificates|curl|wget|python3|python3-minimal|python3\.12|ubuntu-minimal|ubuntu-server-minimal|ubuntu-standard|ubuntu-server)\b'
    if printf '%s\n' "$sim" | grep -Eq "$protected"; then
        echo "WARNING: purge of $pkg would remove protected/base packages; leaving package installed but disabled"
        return 0
    fi
    xpam_run_with_heartbeat "apt purge $pkg" env NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get purge -y "$pkg" || true
}


xpam_ssh_runtime_check(){
    local fail=0
    if command -v sshd >/dev/null 2>&1 && sshd -t >/dev/null 2>&1; then
        echo "OK: sshd config syntax"
    else
        echo "FAIL: sshd config syntax check failed"
        fail=1
    fi

    if systemctl is-active --quiet ssh.service 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
        echo "OK: service ssh active"
    elif systemctl is-active --quiet ssh.socket 2>/dev/null; then
        if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(:|\])22$'; then
            echo "OK: SSH socket active and port 22 listening"
        else
            echo "FAIL: ssh.socket active but TCP port 22 is not listening"
            fail=1
        fi
    else
        echo "FAIL: neither ssh.service nor ssh.socket is active"
        fail=1
    fi
    return "$fail"
}

xpam_apply_service_hygiene(){
    local cfg="$1"
    # shellcheck disable=SC1090
    . "$cfg"
    echo; echo "===== SERVICE HYGIENE APPLY ====="
    echo "Profile: ${PROFILE:-unknown}"
    for unit in \
      snapd.service snapd.socket snapd.seeded.service snapd.snap-repair.timer snapd.refresh.timer \
      packagekit.service packagekit-offline-update.service \
      fwupd.service fwupd-refresh.service fwupd-refresh.timer \
      apport.service apport-autoreport.service apport-forward@.service \
      unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service \
      motd-news.timer update-notifier-download.timer update-notifier-motd.timer \
      thermald.service open-iscsi.service iscsid.service multipathd.service lvm2-monitor.service
    do
        xpam_stop_disable_mask_unit "$unit"
    done
    if [ "${PROFILE:-}" = "vless_direct" ]; then
        xpam_stop_disable_mask_unit haproxy.service
        xpam_stop_disable_mask_unit mtprotoproxy.service
    fi
    for unit in ssh.socket ssh.service nginx.service x-ui.service fail2ban.service ufw.service cron.service systemd-resolved.service systemd-timesyncd.service; do
        xpam_unit_exists "$unit" && systemctl enable "$unit" >/dev/null 2>&1 || true
    done
    if [ "${PROFILE:-}" != "vless_direct" ]; then
        xpam_unit_exists haproxy.service && systemctl enable haproxy.service >/dev/null 2>&1 || true
        xpam_unit_exists mtprotoproxy.service && systemctl enable mtprotoproxy.service >/dev/null 2>&1 || true
    fi
    for pkg in snapd packagekit packagekit-tools fwupd apport apport-core-dump-handler unattended-upgrades thermald open-iscsi multipath-tools; do
        xpam_guarded_purge_package "$pkg"
    done
    systemctl daemon-reload || true
    apt-get clean || true
    apt-get autoclean -y || true
    echo "OK: service hygiene apply finished"
}

xpam_service_hygiene_check(){
    local cfg="$1" fail=0 unit state enabled
    # shellcheck disable=SC1090
    . "$cfg"
    echo; echo "===== SERVICE HYGIENE CHECK ====="
    echo "Profile: ${PROFILE:-unknown}"
    for unit in \
      snapd.service snapd.socket snapd.seeded.service \
      packagekit.service packagekit-offline-update.service \
      fwupd.service fwupd-refresh.service \
      apport.service apport-autoreport.service \
      unattended-upgrades.service apt-daily.service apt-daily-upgrade.service \
      thermald.service open-iscsi.service iscsid.service multipathd.service lvm2-monitor.service
    do
        state="$(systemctl is-active "$unit" 2>/dev/null || true)"
        enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
        if [ "$state" = "active" ]; then
            echo "FAIL: extra service/socket is active: $unit"
            fail=1
        elif [ -n "$state" ] && [ "$state" != "unknown" ]; then
            echo "OK: $unit active=$state enabled=${enabled:-unknown}"
        fi
    done
    for unit in snapd.snap-repair.timer snapd.refresh.timer fwupd-refresh.timer apt-daily.timer apt-daily-upgrade.timer motd-news.timer update-notifier-download.timer update-notifier-motd.timer; do
        enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
        state="$(systemctl is-active "$unit" 2>/dev/null || true)"
        if [ "$state" = "active" ] || [ "$enabled" = "enabled" ]; then
            echo "FAIL: extra timer enabled/active: $unit active=${state:-unknown} enabled=${enabled:-unknown}"
            fail=1
        else
            [ -n "$state" ] && [ "$state" != "unknown" ] && echo "OK: $unit active=$state enabled=${enabled:-unknown}"
        fi
    done
    if [ "${PROFILE:-}" = "vless_direct" ]; then
        for unit in haproxy.service mtprotoproxy.service; do
            state="$(systemctl is-active "$unit" 2>/dev/null || true)"
            if [ "$state" = "active" ]; then echo "FAIL: $unit must not be active in direct VLESS profile"; fail=1; else echo "OK: $unit not active (${state:-unknown})"; fi
        done
    else
        for unit in haproxy.service mtprotoproxy.service; do
            systemctl is-active --quiet "$unit" && echo "OK: required service active: $unit" || { echo "FAIL: required service not active: $unit"; fail=1; }
        done
    fi
    for unit in qemu-guest-agent.service open-vm-tools.service rsyslog.service serial-getty@ttyS0.service; do
        state="$(systemctl is-active "$unit" 2>/dev/null || true)"
        [ "$state" = "active" ] && echo "OK: provider/system service allowed: $unit active"
    done
    if [ "$fail" -eq 0 ]; then echo "OK: service hygiene looks correct"; fi
    return "$fail"
}

xpam_post_install_cleanup(){
    local prefix="${1:-server}"
    echo; echo "===== POST-INSTALL SAFE CLEANUP ====="
    xpam_guarded_autoremove "$prefix" || true
    apt-get clean || true
    apt-get autoclean -y || true
    rm -f /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin 2>/dev/null || true
    rm -rf /var/cache/apt/archives/partial/* 2>/dev/null || true
    rm -f /tmp/service-audit-*.txt /tmp/tls-cert.* /tmp/tls-info.* 2>/dev/null || true
    rm -f /root/recipe_*.log /root/recipe_-*.log /root/exec_recipe.log 2>/dev/null || true
    rm -f /root/site-nginx-snapshot-*.tar.gz /root/*-nginx-snapshot-*.tar.gz 2>/dev/null || true
    find /root -maxdepth 1 -type d \( -name 'site-nginx-snapshot-*' -o -name '*-nginx-snapshot-*' \) -print -exec rm -rf {} + 2>/dev/null || true
    find /root/.ssh -maxdepth 1 -type f -name 'authorized_keys.bak-before-*' -print -delete 2>/dev/null || true
    find /root -maxdepth 1 -type f -name 'xpam-script-v*.log' -mtime +1 -print -delete 2>/dev/null || true
    find /root -maxdepth 1 -type f \( -name 'xpam-script*.tar.gz' -o -name 'xpam-script*.tgz' -o -name 'xpam-script*.sha256' -o -name 'xpam-script*.tar.gz.sha256' -o -name 'xpam-script*.tgz.sha256' \) -mtime +1 -print -delete 2>/dev/null || true
    rm -f /root/.lesshst 2>/dev/null || true
    rm -rf /var/www/html 2>/dev/null || true
    find /root -maxdepth 1 -type d -name 'xpam-script-v*' -mtime +1 -print -exec rm -rf {} + 2>/dev/null || true
    rm -rf /var/log/unattended-upgrades 2>/dev/null || true
    find /tmp /var/tmp -xdev -mindepth 1 -maxdepth 1 -type f -print -delete 2>/dev/null || true
    find /tmp /var/tmp -xdev -mindepth 1 -maxdepth 1 -type d -empty -print -delete 2>/dev/null || true
    journalctl --vacuum-size=32M 2>/dev/null || true
    echo; echo "--- cleanup footprint"
    du -sh /root /root/config-backups /root/secure-notes /var/cache /var/cache/apt /var/log /tmp /usr/local/sbin /opt 2>/dev/null || true
    echo "OK: post-install cleanup finished for $prefix"
}

xpam_weekly_safe_cleanup(){
    local prefix="${1:-server}"
    echo; echo "===== WEEKLY SAFE CLEANUP ====="

    echo "--- targeted temporary/audit files"
    find /root /tmp /usr/local/sbin -maxdepth 1 -type f \
      \( -name 'dns-full-check.sh' \
         -o -name 'dns-audit.sh' \
         -o -name 'dot-test.py' \
         -o -name 'telegram-dns-connect-test.py' \
         -o -name 'final-maint-audit.sh' \
         -o -name 'tg-getme.json' \
         -o -name 'dns-full-check-*.log' \
         -o -name 'final-maint-audit-*.log' \
         -o -name '50-cloud-init.yaml.bak-dns-*' \
         -o -name 'resolv.conf.bak-dns-*' \
         -o -name '*.bak-dns-policy-*' \
         -o -name '*.bak-dns-snapshot-*' \
         -o -name '*.bak-telegram-https-relay-*' \
         -o -name 'check-network-tuning.sh' \
         -o -name 'apply-network-tuning.sh' \
         -o -name 'apply-safe-network-tuning.sh' \
         -o -name 'temp-revert-network-tuning-for-test.sh' \
         -o -name 'network-tuning-before-*' \
         -o -name 'network-tuning-after-*' \
         -o -name 'network-tuning-final-state.txt' \
         -o -name 'final-short-report.txt' \
         -o -name 'short-report.txt' \
         -o -name '.bash_history-*.tmp' \
         -o -name '.lesshst' \
         -o -name 'recipe_*.log' \
         -o -name 'recipe_-*.log' \
         -o -name 'exec_recipe.log' \
         -o -name 'site-nginx-snapshot-*.tar.gz' \
         -o -name '*-nginx-snapshot-*.tar.gz' \) \
      -print -delete 2>/dev/null || true

    echo; echo "--- XPAM Script log and backup retention"
    xpam_prune_keep_latest "/var/log/${prefix}-maintenance" 'weekly-*.log' 4
    xpam_prune_keep_latest /root/config-backups "${prefix}-config-*.tar.gz" 4
    xpam_prune_keep_latest /root/manual-backups/health-logs "${prefix}-*.log" 4
    xpam_prune_keep_latest /root/manual-backups 'site-replace-check-*' 4
    xpam_prune_keep_latest /root/manual-backups 'site-reset-*' 4
    xpam_prune_keep_latest /root/manual-backups 'mtproto-users-*' 4
    xpam_prune_keep_latest /root/manual-backups/xui-warp-normalize 'x-ui.db.*' 4

    echo; echo "--- older generic backup files"
    find /usr/local/sbin /etc/nginx /etc/haproxy /etc/systemd/system /etc/letsencrypt/renewal-hooks/deploy /etc/ssh /etc/fail2ban /etc/ufw \
      -maxdepth 3 -type f \
      \( -name '*.bak' -o -name '*.bak-*' -o -name '*.backup*' -o -name '*.old' -o -name '*.save' -o -name '*.tmp' \) \
      -mtime +14 -print -delete 2>/dev/null || true

    echo; echo "--- final apt cache clean"
    apt-get clean || true
    apt-get autoclean -y || true
    rm -f /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin
    rm -rf /var/cache/apt/archives/partial/* 2>/dev/null || true

    echo; echo "--- journal vacuum"
    journalctl --vacuum-size=64M 2>/dev/null || true
    journalctl --disk-usage 2>/dev/null || true

    echo; echo "--- cleanup summary"
    du -sh /root /var/cache /var/cache/apt /var/log /usr/local/sbin 2>/dev/null || true
    echo "OK: weekly safe cleanup finished for $prefix"
}
