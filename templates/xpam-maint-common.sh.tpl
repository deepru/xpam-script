#!/usr/bin/env bash

xpam_server_label(){ local p="${1:-server}"; printf '%s' "$p" | tr '[:lower:]' '[:upper:]'; }
xpam_run_with_heartbeat(){
    local label="$1" interval="${XPAM_HEARTBEAT_INTERVAL:-30}" elapsed=0 pid rc
    shift
    echo "WARN: $label может занять несколько минут. Не закрывайте SSH-сессию."
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ $((elapsed % interval)) -eq 0 ] && kill -0 "$pid" 2>/dev/null; then
            echo "OK: $label всё ещё выполняется... ${elapsed}s"
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
        curl -fsS --connect-timeout 3 --max-time 8 \
          -X POST "$relay_url" \
          -H "Authorization: Bearer ${relay_token}" \
          --data-binary "$msg" \
          >/dev/null 2>&1 || true
        return 0
    fi

    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || return 0
    [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0

    curl -fsS --connect-timeout 3 --max-time 8 \
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
    if xpam_run_with_heartbeat "APT operation: $context" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 "$@" > >(tee "$log") 2>&1; then
        rm -f "$log"
        return 0
    fi
    if grep -Eiq 'dpkg was interrupted|Could not get lock|Unable to acquire the dpkg frontend lock|dpkg frontend lock is locked' "$log" 2>/dev/null; then
        echo "WARNING: apt reported interrupted dpkg or lock during $context; trying recovery and one retry"
        rm -f "$log"
        xpam_apt_dpkg_recovery "$context retry" || return 1
        xpam_run_with_heartbeat "APT retry: $context" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 "$@"
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


xpam_guarded_security_upgrade(){
    local prefix="${1:-server}"
    xpam_apt_dpkg_recovery "$prefix security-upgrade" || return 1
    echo
    echo "===== APT UPDATE ====="
    xpam_apt_get_safe "$prefix apt update" update || return 1
    echo
    echo "===== GUARDED APT UPGRADE ====="
    # Minimal autonomous maintenance for small VPS. This intentionally avoids
    # distribution release upgrades. It is safer than unattended apt-daily timers
    # because XPAM controls schedule, logs and Telegram summaries.
    xpam_apt_get_safe "$prefix apt upgrade" -o Dpkg::Options::=--force-confold upgrade -y || return 1
    echo "OK: guarded apt upgrade finished for $prefix"
}

xpam_guarded_autoremove(){
    local prefix="${1:-server}"
    local sim_log protected_re protected_hits

    sim_log="$(mktemp /tmp/${prefix}-autoremove-sim.XXXXXX)"

    # These packages are part of the XPAM Script runtime, remote access, TLS, firewall,
    # or optional 3x-ui/Xray WireGuard outbounds. Weekly maintenance must not remove them.
    protected_re='^(openssh-server|openssh-client|ssh|systemd|systemd-resolved|systemd-sysv|nginx|haproxy|x-ui|xray|xray-linux-amd64|certbot|cron|ufw|fail2ban|ca-certificates|curl|wget|gnupg|lsb-release|python3|python3-minimal|python3-venv|python3-systemd|sqlite3|jq|dnsutils|iproute2|wireguard|wireguard-tools|ubuntu-minimal|ubuntu-server-minimal|ubuntu-standard|ubuntu-server)$'

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
    local running newest marker marker_boot current_boot
    running="$(uname -r)"
    newest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's#^/boot/vmlinuz-##' | sort -V | tail -1 || true)"
    echo "Running kernel: $running"; echo "Newest installed kernel: ${newest:-unknown}"
    if [ -f /var/run/reboot-required ]; then
        echo "WARNING: /var/run/reboot-required exists"
        cat /var/run/reboot-required.pkgs 2>/dev/null || true
        return 1
    fi
    if [ -n "${newest:-}" ] && [ "$running" != "$newest" ]; then
        echo "WARNING: reboot recommended to load newest installed kernel"
        return 1
    fi
    marker="/var/lib/xpam-script/reboot-sensitive-upgrades"
    if [ -s "$marker" ]; then
        marker_boot="$(awk -F= '$1=="boot_id"{print $2; exit}' "$marker" 2>/dev/null || true)"
        current_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
        if [ -n "$marker_boot" ] && [ -n "$current_boot" ] && [ "$marker_boot" != "$current_boot" ]; then
            rm -f "$marker" 2>/dev/null || true
            echo "OK: stale sensitive package upgrade marker cleared after reboot"
        else
            echo "WARNING: sensitive packages changed during this boot; reboot recommended"
            awk 'BEGIN{show=0} /^packages:/{show=1; next} show{print "  " $0}' "$marker" 2>/dev/null || true
            return 1
        fi
    fi
    echo "OK: running kernel matches newest installed kernel"
}

xpam_debian_networking_provider_warning_ok(){
    local j fail=0
    [ -r /etc/os-release ] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "debian" ] && [ "${VERSION_ID:-}" = "12" ] || return 1
    systemctl is-failed --quiet networking.service || return 1

    ip -4 route show default 2>/dev/null | grep -q . || fail=1
    ip route get 1.1.1.1 >/dev/null 2>&1 || fail=1
    getent ahostsv4 github.com >/dev/null 2>&1 || fail=1
    [ "$fail" -eq 0 ] || return 1

    j="$(journalctl -u networking -b --no-pager -n 240 2>/dev/null || true)"
    if printf '%s\n' "$j" | grep -Eiq 'RTNETLINK answers: File exists|File exists|already exists|Failed to bring up|resolvconf|dns-nameservers|dns \{'; then
        echo "WARN: Debian 12 provider networking.service issue detected; active network works"
        echo "INFO: XPAM не переписывает /etc/network/interfaces автоматически. Для деталей: sudo ${XPAM_PREFIX:-<prefix>}-netdiag"
        return 0
    fi
    return 1
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
    xpam_tls_endpoint_check "xray vless" "127.0.0.1" "$XRAY_LOCAL_PORT" "$PRIMARY_DOMAIN" "$PRIMARY_DOMAIN" || fail=1
    if [ "$PROFILE" = "root_mtproto" ]; then
        xpam_tls_endpoint_check "xray root site" "127.0.0.1" "$XRAY_LOCAL_PORT" "$ROOT_DOMAIN" "$ROOT_DOMAIN" || fail=1
        xpam_tls_endpoint_check "xray www alias" "127.0.0.1" "$XRAY_LOCAL_PORT" "$WWW_DOMAIN" "$WWW_DOMAIN" || fail=1
    fi
    xpam_tls_endpoint_check "nginx sync backend" "127.0.0.1" "$SYNC_BACKEND_PORT" "$SYNC_DOMAIN" "$SYNC_DOMAIN" || fail=1
    [ "$fail" -eq 0 ] && echo "OK: TLS certificate consistency looks correct"
    return "$fail"
}
xpam_port_exposure_check(){
    local cfg="$1"
    echo; echo "===== PORT EXPOSURE CHECK ====="
    echo "--- IPv4 TCP listeners ---"
    ss -H -4 -lntp 2>/dev/null || true
    echo "--- IPv6 TCP listeners ---"
    ss -H -6 -lntp 2>/dev/null || true
    echo "--- UDP listeners ---"
    ss -H -lnup 2>/dev/null || true
    python3 - "$cfg" <<'PY_PORT'
import re, subprocess, sys
from pathlib import Path
cfg={}
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line or line.startswith('#') or '=' not in line:
        continue
    k,v=line.split('=',1)
    cfg[k]=v.strip().strip("'").strip('"')

required_public_tcp={int(cfg['SSH_PUBLIC_PORT']), int(cfg['HTTP_PUBLIC_PORT']), int(cfg['XRAY_PUBLIC_PORT'])}
required_local_tcp={int(cfg['XUI_PANEL_PORT']), int(cfg['SITE_BACKEND_PORT'])}
allowed_local_tcp=set(required_local_tcp) | {11111, 62789}
required_local_tcp |= {int(cfg['XRAY_LOCAL_PORT']), int(cfg['MTPROTO_PORT']), int(cfg['SYNC_BACKEND_PORT'])}
allowed_local_tcp |= required_local_tcp

if (cfg.get('MTPROTO_BACKEND') or '3xui-mtg') == '3xui-mtg':
    try:
        proc_out=subprocess.check_output(['ss','-H','-lntp'], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        proc_out=''
    mtg_port=int(cfg.get('MTPROTO_PORT','0') or 0)
    for line in proc_out.splitlines():
        if 'mtg-linux' not in line and 'mtg-linux-amd64' not in line:
            continue
        parts=line.split()
        if len(parts) < 4:
            continue
        local=parts[3]
        if not (local.startswith('127.') or local.startswith('[::1]') or local.startswith('::1')):
            continue
        m=re.search(r':(\d+)$', local)
        if not m:
            continue
        port=int(m.group(1))
        if port != mtg_port:
            allowed_local_tcp.add(port)

    # DoubleHop / 3x-ui MTG routeThroughXray creates an expected local Xray SOCKS
    # listener on routeXrayPort. It is loopback-only and must not make health fail.
    try:
        import json, sqlite3
        conn=sqlite3.connect('/etc/x-ui/x-ui.db')
        row=conn.execute("SELECT settings FROM inbounds WHERE protocol='mtproto' ORDER BY id ASC LIMIT 1").fetchone()
        if row and row[0]:
            mtg_settings=json.loads(row[0])
            if isinstance(mtg_settings, dict) and mtg_settings.get('routeThroughXray') is True:
                rxp=int(mtg_settings.get('routeXrayPort') or 0)
                if rxp > 0:
                    allowed_local_tcp.add(rxp)
                    print(f'OK: DoubleHop MTG routeXrayPort loopback listener expected: 127.0.0.1:{rxp}')
    except Exception:
        pass

def normalize_host(h):
    h=(h or '').strip()
    if h.startswith('[') and ']' in h:
        h=h[1:h.index(']')]
    else:
        h=h.strip('[]')
    return h

def loop(h):
    h=normalize_host(h)
    return h in ('localhost','::1') or h.startswith('127.') or h.startswith('::ffff:127.')

def parse_ss(args, family, proto):
    try:
        out=subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return []
    rows=[]
    for line in out.splitlines():
        parts=line.split()
        if len(parts)<4:
            continue
        local=None
        for candidate in parts[3:7]:
            if re.search(r':\d+$', candidate):
                local=candidate
                break
        if not local:
            continue
        if local.startswith('['):
            m=re.match(r'^\[([^\]]+)\]:(\d+)$', local)
            if not m:
                continue
            host=m.group(1); port=int(m.group(2))
        else:
            m=re.search(r':(\d+)$', local)
            if not m:
                continue
            port=int(m.group(1)); host=local[:-(len(m.group(1))+1)]
        rows.append({'family':family, 'proto':proto, 'port':port, 'host':normalize_host(host), 'local':local, 'raw':line})
    return rows

tcp4_rows=parse_ss(['ss','-H','-4','-lnt'], 'ipv4', 'tcp')
tcp6_rows=parse_ss(['ss','-H','-6','-lnt'], 'ipv6', 'tcp')
udp_rows=parse_ss(['ss','-H','-lnup'], 'any', 'udp')
tcp_rows=tcp4_rows+tcp6_rows
fail=False

def public_ipv4_host(h):
    h=normalize_host(h)
    return h in ('0.0.0.0','*') or re.match(r'^(?:\d{1,3}\.){3}\d{1,3}$', h)

def public_ipv6_host(h):
    h=normalize_host(h)
    if loop(h):
        return False
    return h in ('*','::') or ':' in h

def public_ipv4_tcp(p):
    return [r['local'] for r in tcp4_rows if r['port']==p and public_ipv4_host(r['host'])]

def public_ipv6_tcp(p):
    return [r['local'] for r in tcp6_rows if r['port']==p and public_ipv6_host(r['host'])]

def local_tcp(p):
    return [r['local'] for r in tcp_rows if r['port']==p and loop(r['host'])]

for p in sorted(required_public_tcp):
    e=public_ipv4_tcp(p)
    if e:
        print(f'OK: required public IPv4 TCP port {p}: {", ".join(e)}')
    else:
        print(f'FAIL: required public IPv4 TCP port {p} has no IPv4 listener')
        fail=True
    v6=public_ipv6_tcp(p)
    if v6:
        print(f'FAIL: unexpected public IPv6 TCP listener on port {p}: {", ".join(v6)}; XPAM public surface is IPv4-only')
        fail=True

for p in sorted(required_local_tcp):
    e=local_tcp(p)
    if e:
        print(f'OK: required loopback TCP port {p}: {", ".join(e)}')
    else:
        print(f'FAIL: required loopback TCP port {p} has no listener')
        fail=True

for r in sorted(tcp_rows, key=lambda x:(x['port'], x['family'], x['local'])):
    port, host, local = r['port'], r['host'], r['local']
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

def ufw_udp_allowed(port):
    try:
        status=subprocess.check_output(['ufw','status'], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return False
    for line in status.splitlines():
        low=line.lower()
        if f'{port}/udp' in low and 'allow' in low:
            return True
    return False

for r in sorted(udp_rows, key=lambda x:(x['port'], x['local'])):
    port, host, local = r['port'], r['host'], r['local']
    raw = r.get('raw','')
    if loop(host) or port==53:
        continue
    if 'xray' in raw.lower():
        if ufw_udp_allowed(port):
            print(f'WARNING: Xray/WARP UDP socket {local} is also allowed by UFW; verify this is intentional')
        else:
            print(f'OK: Xray/WARP UDP socket detected at {local}; no public UFW UDP allow rule found')
        continue
    print(f'WARNING: public UDP listener {local}; verify it is intentional and firewalled as expected')

if fail:
    sys.exit(1)
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

xpam_haproxy_mtproto_journal_check(){
    local cfg="$1" fail=0 since log tmp_log
    [ -f "$cfg" ] || { echo "FAIL: XPAM config missing for HAProxy journal check: $cfg"; return 1; }
    # shellcheck disable=SC1090
    . "$cfg"

    since="$(systemctl show -p ActiveEnterTimestamp --value haproxy.service 2>/dev/null || true)"
    [ -n "$since" ] || since="now"

    tmp_log="$(mktemp)" || { echo "FAIL: cannot create temporary journal file"; return 1; }
    journalctl -u haproxy -u mtprotoproxy --since "$since" --no-pager 2>/dev/null \
        | grep -Eiv "Current worker .*exited with code 143|Exiting Master process|All workers exited|Deactivated successfully|Stopping haproxy.service|Stopped haproxy.service|Started haproxy.service|Starting haproxy.service|Loading success|New worker|haproxy version is|path to executable is|Reloading haproxy.service|Reloaded haproxy.service" \
        >"$tmp_log" || true

    if grep -Eiq "Bad secret|Changing it to [0-9a-fA-F]{32}|\\bFATAL\\b|cannot bind|configuration file is invalid|Traceback|Unhandled|panic" "$tmp_log"; then
        echo "FAIL: fatal HAProxy/MTProto journal events found in current HAProxy activation journal"
        grep -Ei "Bad secret|Changing it to [0-9a-fA-F]{32}|\\bFATAL\\b|cannot bind|configuration file is invalid|Traceback|Unhandled|panic" "$tmp_log" | tail -20
        rm -f "$tmp_log"
        return 1
    fi

    python3 - "$tmp_log" "${XRAY_LOCAL_PORT:-}" "${MTPROTO_PORT:-}" <<'PY_HAPROXY_RECOVERY'
import re, socket, sys
from pathlib import Path
path = Path(sys.argv[1])
xray_port = sys.argv[2]
mtproto_port = sys.argv[3]
lines = path.read_text(errors='ignore').splitlines() if path.exists() else []

def reachable(port_s):
    try:
        port = int(port_s)
    except Exception:
        return False
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=2):
            return True
    except OSError:
        return False

backend = {
    'be_xray': {'name': 'be_xray/xray', 'port': xray_port, 'down': [], 'up': []},
    'be_mtproto': {'name': 'be_mtproto/mtproto', 'port': mtproto_port, 'down': [], 'up': []},
}

def is_down_event(key, line):
    ll = line.lower()
    if key not in line:
        return False
    return (
        ' is down' in ll or
        'no server available' in ll or
        '<nosrv>' in ll or
        'layer4 connection problem' in ll or
        'connection refused' in ll or
        'has no server' in ll
    )

def is_up_event(key, line):
    ll = line.lower()
    return key in line and ' is up' in ll

for idx, line in enumerate(lines):
    for key in backend:
        if is_down_event(key, line):
            backend[key]['down'].append((idx, line))
        if is_up_event(key, line):
            backend[key]['up'].append((idx, line))

fail = False
any_event = False
for key, data in backend.items():
    if not data['down']:
        continue
    any_event = True
    last_down_idx, last_down_line = data['down'][-1]
    recovered_by_journal = any(idx > last_down_idx for idx, _ in data['up'])
    current_ok = reachable(data['port'])
    if recovered_by_journal and current_ok:
        print(f"INFO: HAProxy {data['name']} had transient DOWN/no-server events after current HAProxy activation")
        print(f"OK: HAProxy {data['name']} recovered in journal and local port 127.0.0.1:{data['port']} is reachable")
    elif current_ok:
        print(f"INFO: HAProxy {data['name']} had historical DOWN/no-server events after current HAProxy activation")
        print(f"OK: HAProxy {data['name']} local port 127.0.0.1:{data['port']} is currently reachable")
    else:
        print(f"FAIL: HAProxy {data['name']} has unrecovered backend failure and local port 127.0.0.1:{data['port']} is not reachable")
        print("Recent matching HAProxy event:")
        print(last_down_line)
        fail = True
if not any_event:
    print("OK: no HAProxy/MTProto backend failure events in current HAProxy activation journal")
else:
    print("OK: HAProxy/MTProto backend journal classification completed")
sys.exit(1 if fail else 0)
PY_HAPROXY_RECOVERY
    fail=$?
    rm -f "$tmp_log"
    return "$fail"
}

xpam_startup_order_check(){
    local cfg="$1" fail=0
    # shellcheck disable=SC1090
    . "$cfg"
    echo; echo "===== SYSTEMD STARTUP ORDER ====="
    if [ -x /usr/local/sbin/wait-for-local-port.sh ]; then echo "OK: executable exists: /usr/local/sbin/wait-for-local-port.sh"; else echo "FAIL: missing/executable wait-for-local-port.sh"; fail=1; fi
    bash -n /usr/local/sbin/wait-for-local-port.sh >/dev/null 2>&1 && echo "OK: wait-for-local-port.sh syntax" || { echo "FAIL: wait-for-local-port.sh syntax"; fail=1; }
    if [ -e /etc/systemd/system/mtprotoproxy.service.d/haproxy-order.conf ]; then echo "FAIL: obsolete mtprotoproxy haproxy-order drop-in exists"; fail=1; else echo "OK: absent as expected: /etc/systemd/system/mtprotoproxy.service.d/haproxy-order.conf"; fi
    case "${MTPROTO_BACKEND:-3xui-mtg}" in
      3xui-mtg)
        if systemctl cat haproxy 2>/dev/null | grep -Fq "mtprotoproxy.service"; then echo "FAIL: haproxy ordering references mtprotoproxy.service under 3xui-mtg"; fail=1; else echo "OK: haproxy ordering has no mtprotoproxy.service dependency under 3xui-mtg"; fi
        if systemctl cat haproxy 2>/dev/null | grep -Eq 'After=.*nginx.*x-ui|After=.*x-ui.*nginx'; then echo "OK: haproxy starts after nginx and x-ui for 3xui-mtg"; else echo "FAIL: haproxy ordering does not include nginx and x-ui for 3xui-mtg"; fail=1; fi
        if systemctl is-active --quiet mtprotoproxy.service; then echo "FAIL: mtprotoproxy must be inactive under 3xui-mtg"; fail=1; else echo "OK: mtprotoproxy inactive under 3xui-mtg"; fi
        ;;
      *)
        if systemctl cat mtprotoproxy 2>/dev/null | grep -Fq "wait-for-local-port.sh 127.0.0.1 ${SYNC_BACKEND_PORT}"; then echo "OK: mtprotoproxy waits for nginx sync backend 127.0.0.1:${SYNC_BACKEND_PORT}"; else echo "FAIL: mtprotoproxy does not wait for nginx sync backend 127.0.0.1:${SYNC_BACKEND_PORT}"; fail=1; fi
        if systemctl cat haproxy 2>/dev/null | grep -Eq 'After=.*nginx.*x-ui.*mtprotoproxy|After=.*nginx.*mtprotoproxy.*x-ui|After=.*x-ui.*nginx.*mtprotoproxy|After=.*x-ui.*mtprotoproxy.*nginx|After=.*mtprotoproxy.*nginx.*x-ui|After=.*mtprotoproxy.*x-ui.*nginx'; then echo "OK: haproxy starts after nginx, x-ui, mtprotoproxy"; else echo "FAIL: haproxy ordering does not include nginx, x-ui and mtprotoproxy"; fail=1; fi
        ;;
    esac
    if systemctl cat haproxy 2>/dev/null | grep -Fq "wait-for-local-port.sh 127.0.0.1 ${XRAY_LOCAL_PORT}"; then echo "OK: haproxy waits for xray local 127.0.0.1:${XRAY_LOCAL_PORT}"; else echo "FAIL: haproxy does not wait for xray local 127.0.0.1:${XRAY_LOCAL_PORT}"; fail=1; fi
    if systemctl cat haproxy 2>/dev/null | grep -Fq "wait-for-local-port.sh 127.0.0.1 ${MTPROTO_PORT}"; then echo "OK: haproxy waits for mtproto local 127.0.0.1:${MTPROTO_PORT}"; else echo "FAIL: haproxy does not wait for mtproto local 127.0.0.1:${MTPROTO_PORT}"; fail=1; fi
    /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$SYNC_BACKEND_PORT" 3 sync-backend >/dev/null 2>&1 && echo "OK: local ${SYNC_BACKEND_PORT} reachable" || { echo "FAIL: local ${SYNC_BACKEND_PORT} not reachable"; fail=1; }
    /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XRAY_LOCAL_PORT" 3 xray-local >/dev/null 2>&1 && echo "OK: local ${XRAY_LOCAL_PORT} reachable" || { echo "FAIL: local ${XRAY_LOCAL_PORT} not reachable"; fail=1; }
    /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$MTPROTO_PORT" 3 mtproto-local >/dev/null 2>&1 && echo "OK: local ${MTPROTO_PORT} reachable" || { echo "FAIL: local ${MTPROTO_PORT} not reachable"; fail=1; }
    if ! xpam_haproxy_mtproto_journal_check "$cfg"; then fail=1; fi
    [ "$fail" -eq 0 ] && echo "OK: startup order looks correct"
    return "$fail"
}



xpam_3xui_mtg_runtime_invariant_check(){
    local cfg="$1" fail=0
    [ -f "$cfg" ] || { echo "FAIL: XPAM config missing: $cfg"; return 1; }
    # shellcheck disable=SC1090
    . "$cfg"

    if systemctl is-active --quiet x-ui.service; then
        echo "OK: x-ui active for 3xui-mtg"
    else
        echo "FAIL: x-ui must be active for 3xui-mtg"
        fail=1
    fi

    if systemctl is-active --quiet mtprotoproxy.service; then
        echo "FAIL: mtprotoproxy must be inactive under 3xui-mtg"
        fail=1
    else
        echo "OK: mtprotoproxy inactive under 3xui-mtg"
    fi

    if systemctl cat haproxy.service 2>/dev/null | grep -Fq 'mtprotoproxy.service'; then
        echo "FAIL: HAProxy drop-in/order references mtprotoproxy.service under 3xui-mtg"
        fail=1
    else
        echo "OK: HAProxy drop-in has no mtprotoproxy.service dependency under 3xui-mtg"
    fi

    python3 - "$cfg" <<'PY_3XUI_MTG_RUNTIME'
import json, re, ssl, subprocess, sys, urllib.request
from pathlib import Path
cfg_path=Path(sys.argv[1])
cfg={}
for line in cfg_path.read_text(errors='ignore').splitlines():
    if not line or line.startswith('#') or '=' not in line:
        continue
    k,v=line.split('=',1)
    cfg[k]=v.strip().strip('"').strip("'")
errs=[]
def ok(msg): print('OK: '+msg)
def bad(msg): print('FAIL: '+msg); errs.append(msg)

backend=cfg.get('MTPROTO_BACKEND') or '3xui-mtg'
if backend == '3xui-mtg':
    ok('backend selected = 3xui-mtg')
else:
    bad(f'backend expected 3xui-mtg, got {backend!r}')

prefix=cfg.get('SERVER_PREFIX','')
remark=f'{prefix}-mtproto'
sync_domain=cfg.get('SYNC_DOMAIN','')
mtproto_port=int(cfg.get('MTPROTO_PORT','0') or 0)
sync_backend_port=int(cfg.get('SYNC_BACKEND_PORT','0') or 0)
panel_port=cfg.get('XUI_PANEL_PORT','57827')
panel_path=(cfg.get('PANEL_PATH','') or '').strip('/')
token_path=Path('/etc/xpam-script/x-ui-api-token')

def api_list():
    if not token_path.exists():
        bad('3x-ui API token storage missing for MTG invariant check')
        return []
    try:
        token=token_path.read_text(errors='ignore').splitlines()[0].strip()
    except Exception as exc:
        bad(f'3x-ui API token unreadable for MTG invariant check: {exc}')
        return []
    if not token:
        bad('3x-ui API token empty for MTG invariant check')
        return []
    url=f'https://127.0.0.1:{panel_port}/{panel_path}/panel/api/inbounds/list'
    req=urllib.request.Request(url, headers={
        'Authorization':'Bearer '+token,
        'Accept':'application/json',
        'User-Agent':'XPAM-Script/health-mtg',
    })
    try:
        # Loopback-only (127.0.0.1 panel, cert for the public domain): verification
        # intentionally skipped; the request never leaves localhost.
        with urllib.request.urlopen(req, timeout=10, context=ssl._create_unverified_context()) as resp:
            data=json.loads(resp.read(1024*1024).decode('utf-8','replace'))
    except Exception as exc:
        bad(f'3x-ui API list failed for MTG invariant check: {exc}')
        return []
    if data.get('success') is not True:
        bad('3x-ui API list did not return success=true for MTG invariant check')
        return []
    items=data.get('obj') or []
    if isinstance(items, dict):
        items=items.get('inbounds') or items.get('items') or []
    if not isinstance(items, list):
        bad('3x-ui API list obj is not a list for MTG invariant check')
        return []
    return items

def boolish(v):
    if isinstance(v, bool): return v
    if isinstance(v, (int, float)): return bool(v)
    return str(v).strip().lower() in ('1','true','yes','on')

def settings_from(item):
    raw=item.get('settings')
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw.strip():
        try:
            return json.loads(raw)
        except Exception:
            return {}
    return {}

items=api_list()
matches=[]
for item in items:
    if not isinstance(item, dict):
        continue
    if str(item.get('protocol') or '').lower() != 'mtproto':
        continue
    if str(item.get('remark') or '') == remark:
        matches.append(item)

if len(matches) == 1:
    ok('XPAM-managed MTG inbound exists')
    item=matches[0]
    if boolish(item.get('enable')):
        ok('XPAM-managed MTG inbound enabled')
    else:
        bad('XPAM-managed MTG inbound is disabled')
    checks=[
        ('MTG inbound protocol', str(item.get('protocol') or '').lower(), 'mtproto'),
        ('MTG inbound listen', str(item.get('listen') or ''), '127.0.0.1'),
        ('MTG inbound shareAddrStrategy', str(item.get('shareAddrStrategy') or ''), 'custom'),
        ('MTG inbound shareAddr', str(item.get('shareAddr') or ''), sync_domain),
        ('MTG inbound tag', str(item.get('tag') or ''), f'in-{mtproto_port}-tcp'),
    ]
    for label, got, exp in checks:
        if got == exp:
            ok(f'{label} = {exp}')
        else:
            bad(f'{label} expected {exp!r}, got {got!r}')
    try:
        got_port=int(item.get('port'))
    except Exception:
        got_port=-1
    if got_port == mtproto_port:
        ok(f'MTG inbound port = {mtproto_port}')
    else:
        bad(f'MTG inbound port expected {mtproto_port}, got {item.get("port")!r}')
    settings=settings_from(item)
    if settings:
        ok('MTG inbound settings JSON parsed')
    else:
        bad('MTG inbound settings JSON missing or invalid')
    if settings.get('fakeTlsDomain') == sync_domain:
        ok(f'MTG settings.fakeTlsDomain = {sync_domain}')
    else:
        bad(f'MTG settings.fakeTlsDomain expected {sync_domain!r}, got {settings.get("fakeTlsDomain")!r}')
    secret=str(settings.get('secret') or '')
    expected_suffix=sync_domain.encode('utf-8').hex()
    if secret.startswith('ee') and secret.lower().endswith(expected_suffix.lower()):
        ok('MTG settings.secret is canonical FULL_EE_SECRET_HEX for SYNC_DOMAIN')
    else:
        bad('MTG settings.secret is not canonical FULL_EE_SECRET_HEX for SYNC_DOMAIN')
    if settings.get('preferIp') == 'prefer-ipv4':
        ok('MTG settings.preferIp = prefer-ipv4')
    else:
        bad(f'MTG settings.preferIp expected prefer-ipv4, got {settings.get("preferIp")!r}')
    df=settings.get('domainFronting') if isinstance(settings.get('domainFronting'), dict) else {}
    if df.get('ip') == '127.0.0.1':
        ok('MTG domainFronting.ip = 127.0.0.1')
    else:
        bad(f'MTG domainFronting.ip expected 127.0.0.1, got {df.get("ip")!r}')
    try:
        df_port=int(df.get('port'))
    except Exception:
        df_port=-1
    if df_port == sync_backend_port:
        ok(f'MTG domainFronting.port = {sync_backend_port}')
    else:
        bad(f'MTG domainFronting.port expected {sync_backend_port}, got {df.get("port")!r}')
elif len(matches) == 0:
    bad(f'XPAM-managed MTG inbound missing: remark={remark}')
else:
    bad(f'expected exactly one XPAM-managed MTG inbound, found {len(matches)}')

# Listener/process checks.
try:
    ss_out=subprocess.check_output(['ss','-H','-ltnp'], text=True, stderr=subprocess.DEVNULL)
except Exception as exc:
    bad(f'cannot inspect TCP listeners with ss: {exc}')
    ss_out=''
mtg_rows=[]
port_rows=[]
non_loopback_mtg=[]
for line in ss_out.splitlines():
    if 'mtg-linux' in line or 'mtg-linux-amd64' in line:
        mtg_rows.append(line)
    parts=line.split()
    local=parts[3] if len(parts) >= 4 else ''
    if local == f'127.0.0.1:{mtproto_port}':
        port_rows.append(line)

def local_addr(line):
    parts=line.split()
    return parts[3] if len(parts) >= 4 else ''

if port_rows and any(('mtg-linux' in r or 'mtg-linux-amd64' in r) for r in port_rows):
    ok(f'mtg-linux-amd64 owns 127.0.0.1:{mtproto_port}')
else:
    bad(f'mtg-linux-amd64 does not own 127.0.0.1:{mtproto_port}')
if any('mtprotoproxy' in r for r in port_rows):
    bad(f'mtprotoproxy shares 127.0.0.1:{mtproto_port}')
else:
    ok(f'mtprotoproxy does not share 127.0.0.1:{mtproto_port}')

for row in mtg_rows:
    addr=local_addr(row)
    if not addr.startswith('127.'):
        non_loopback_mtg.append(addr)
if mtg_rows and not non_loopback_mtg:
    ok('MTG listeners are loopback-only')
elif non_loopback_mtg:
    bad('MTG has non-loopback listener(s): '+', '.join(non_loopback_mtg))
else:
    bad('no mtg-linux listener found')

metrics=[]
for row in mtg_rows:
    addr=local_addr(row)
    if not addr.startswith('127.'):
        continue
    m=re.search(r':(\d+)$', addr)
    if not m:
        continue
    port=int(m.group(1))
    if port != mtproto_port:
        metrics.append(port)
if metrics:
    ok('MTG metrics listener loopback-only: '+', '.join(str(p) for p in sorted(set(metrics))))
    ok('public MTG metrics not exposed by listener binding')
else:
    bad('MTG metrics listener not found')

# Telegram link source-of-truth check.
# For 3xui-mtg, the current Telegram link is generated from the 3x-ui DB.
# A legacy /root/secure-notes/*-mtproto.txt file is intentionally not required.
if matches:
    ok('MTG Telegram link source-of-truth is current 3x-ui DB settings')

if errs:
    sys.exit(1)
print('OK: 3xui-mtg MTProto runtime invariants look correct')
PY_3XUI_MTG_RUNTIME
    py_rc=$?
    if [ "$py_rc" -ne 0 ]; then fail=1; fi
    return "$fail"
}

xpam_mtproto_config_invariant_check(){
    local cfg="$1" fail=0
    echo; echo "===== MTPROTO CONFIG INVARIANT CHECK ====="
    [ -f "$cfg" ] || { echo "FAIL: XPAM config missing: $cfg"; return 1; }
    # shellcheck disable=SC1090
    . "$cfg"
    [ "${MTPROTO_BACKEND:-3xui-mtg}" = "3xui-mtg" ] && { xpam_3xui_mtg_runtime_invariant_check "$cfg"; return $?; }
    python3 - "$cfg" <<'PY_MTPROTO_INVARIANTS'
import importlib.util, pathlib, re, sys
from pathlib import Path
cfg={}
for line in Path(sys.argv[1]).read_text(errors='ignore').splitlines():
    if not line or line.startswith('#') or '=' not in line:
        continue
    k,v=line.split('=',1)
    cfg[k]=v.strip().strip("'").strip('"')
path=pathlib.Path('/opt/mtprotoproxy/config.py')
errs=[]
def ok(msg): print('OK: '+msg)
def bad(msg): print('FAIL: '+msg); errs.append(msg)
if not path.exists():
    bad('MTProto config missing: /opt/mtprotoproxy/config.py')
    raise SystemExit(1)
try:
    spec=importlib.util.spec_from_file_location('mtproto_config_health', str(path))
    mod=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
except Exception as exc:
    bad(f'cannot import MTProto config.py: {exc}')
    raise SystemExit(1)

def check(name, got, exp):
    if got == exp:
        ok(f'MTProto {name} = {exp!r}')
    else:
        bad(f'MTProto {name} expected {exp!r}, got {got!r}')
try:
    check('PORT', int(getattr(mod,'PORT',None)), int(cfg['MTPROTO_PORT']))
except Exception:
    bad('MTProto PORT is missing or not integer')
check('TLS_DOMAIN', getattr(mod,'TLS_DOMAIN',None), cfg.get('SYNC_DOMAIN',''))
modes=getattr(mod,'MODES',{})
if isinstance(modes, dict) and modes.get('classic') is False and modes.get('secure') is False and modes.get('tls') is True:
    ok('MTProto MODES classic=False secure=False tls=True')
else:
    bad(f'MTProto MODES expected classic=False secure=False tls=True, got {modes!r}')
check('LISTEN_ADDR_IPV4', getattr(mod,'LISTEN_ADDR_IPV4',None), '127.0.0.1')
if getattr(mod,'LISTEN_ADDR_IPV6',None) in (None, ''):
    ok('MTProto LISTEN_ADDR_IPV6 is None/empty')
else:
    bad(f'MTProto LISTEN_ADDR_IPV6 expected None/empty, got {getattr(mod,"LISTEN_ADDR_IPV6",None)!r}')
if getattr(mod,'MASK',None) is True:
    ok('MTProto MASK=True')
else:
    bad(f'MTProto MASK expected True, got {getattr(mod,"MASK",None)!r}')
check('MASK_HOST', getattr(mod,'MASK_HOST',None), '127.0.0.1')
try:
    check('MASK_PORT', int(getattr(mod,'MASK_PORT',None)), int(cfg['SYNC_BACKEND_PORT']))
except Exception:
    bad('MTProto MASK_PORT is missing or not integer')
if getattr(mod,'PREFER_IPV6',None) is False:
    ok('MTProto PREFER_IPV6=False')
else:
    bad(f'MTProto PREFER_IPV6 expected False, got {getattr(mod,"PREFER_IPV6",None)!r}')
users=getattr(mod,'USERS',{})
if isinstance(users, dict) and users:
    bad_users=[]
    for name, sec in users.items():
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,32}', name):
            bad_users.append(name)
        if not isinstance(sec, str) or not re.fullmatch(r'[0-9a-fA-F]{32}', sec):
            bad_users.append(name)
    if bad_users:
        bad('MTProto USERS contains invalid user name or secret format')
    else:
        ok(f'MTProto USERS count = {len(users)}')
else:
    bad('MTProto USERS is empty or not a dict')
if errs:
    raise SystemExit(1)
print('OK: MTProto config invariants look correct')
PY_MTPROTO_INVARIANTS
    fail=$?
    return "$fail"
}

xpam_mtproto_public_fallback_check(){
    local cfg="$1" server_ipv4 code fail=0
    echo; echo "===== MTPROTO PUBLIC FALLBACK CHECK ====="
    [ -f "$cfg" ] || { echo "FAIL: XPAM config missing: $cfg"; return 1; }
    # shellcheck disable=SC1090
    . "$cfg"
    server_ipv4="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
    if [ -z "$server_ipv4" ]; then
        echo "FAIL: could not detect server IPv4 for public fallback check"
        return 1
    fi
    code="$(curl -4ksS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' --resolve "${SYNC_DOMAIN}:443:${server_ipv4}" "https://${SYNC_DOMAIN}/health" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then
        echo "OK: MTProto public fallback --resolve ${SYNC_DOMAIN}:443:${server_ipv4} /health HTTP 200"
    else
        echo "FAIL: MTProto public fallback --resolve expected HTTP 200, got ${code:-000}"
        fail=1
    fi
    return "$fail"
}

xpam_mtproto_local_tls_backend_check(){
    local cfg="$1" out cert san fail=0
    echo; echo "===== MTPROTO LOCAL TLS BACKEND CHECK ====="
    [ -f "$cfg" ] || { echo "FAIL: XPAM config missing: $cfg"; return 1; }
    # shellcheck disable=SC1090
    . "$cfg"
    out="$(mktemp /tmp/xpam-mtproto-local-tls.XXXXXX)"
    if timeout 12s openssl s_client -tls1_3 -connect "127.0.0.1:${SYNC_BACKEND_PORT}" -servername "$SYNC_DOMAIN" -showcerts </dev/null >"$out" 2>&1; then
        echo "OK: MTProto local TLS backend handshake succeeded: 127.0.0.1:${SYNC_BACKEND_PORT} SNI ${SYNC_DOMAIN}"
    else
        echo "FAIL: MTProto local TLS backend TLS 1.3 handshake failed"
        sed -n '1,40p' "$out" | sed 's/^/  /' || true
        rm -f "$out"
        return 1
    fi
    if grep -Eq 'TLSv1\.3|Protocol[ :]+TLSv1\.3' "$out"; then
        echo "OK: MTProto local TLS backend uses TLSv1.3"
    else
        echo "FAIL: MTProto local TLS backend did not report TLSv1.3"
        fail=1
    fi
    cert="$(awk '/BEGIN CERTIFICATE/{flag=1} flag{print} /END CERTIFICATE/{exit}' "$out")"
    if [ -n "$cert" ]; then
        san="$(printf '%s\n' "$cert" | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)"
        if printf '%s\n' "$san" | grep -Fq "DNS:${SYNC_DOMAIN}"; then
            echo "OK: MTProto local TLS backend certificate SAN includes ${SYNC_DOMAIN}"
        else
            echo "FAIL: MTProto local TLS backend certificate SAN does not include ${SYNC_DOMAIN}"
            fail=1
        fi
    else
        echo "FAIL: MTProto local TLS backend certificate was not captured"
        fail=1
    fi
    rm -f "$out"
    return "$fail"
}

xpam_xui_api_token_check(){
    local cfg="$1" fail=0 file mode owner
    echo; echo "===== 3X-UI API TOKEN CHECK ====="
    [ -f "$cfg" ] || { echo "FAIL: XPAM config missing: $cfg"; return 1; }
    # shellcheck disable=SC1090
    . "$cfg"
    file="/etc/xpam-script/x-ui-api-token"
    if [ ! -f "$file" ]; then
        echo "FAIL: 3x-ui API token storage missing: $file"
        return 1
    fi
    mode="$(stat -c '%a' "$file" 2>/dev/null || echo unknown)"
    owner="$(stat -c '%U:%G' "$file" 2>/dev/null || echo unknown)"
    if [ "$owner" = "root:root" ]; then echo "OK: 3x-ui API token owner root:root"; else echo "FAIL: 3x-ui API token owner expected root:root, got $owner"; fail=1; fi
    if [ "$mode" = "600" ]; then echo "OK: 3x-ui API token permissions 600"; else echo "FAIL: 3x-ui API token permissions expected 600, got $mode"; fail=1; fi
    python3 - "$cfg" "$file" <<'PY_XPAM_XUI_HEALTH_TOKEN'
import json, ssl, sys, urllib.request
from pathlib import Path
cfg_path=Path(sys.argv[1])
token_path=Path(sys.argv[2])
cfg={}
for line in cfg_path.read_text(errors='ignore').splitlines():
    if not line or line.startswith('#') or '=' not in line:
        continue
    k,v=line.split('=',1)
    cfg[k]=v.strip().strip('"').strip("'")
try:
    token=token_path.read_text(errors='ignore').splitlines()[0].strip()
except Exception:
    print('FAIL: 3x-ui API token storage is not readable')
    sys.exit(1)
if not token:
    print('FAIL: 3x-ui API token storage is empty')
    sys.exit(1)
port=cfg.get('XUI_PANEL_PORT','57827')
path=cfg.get('PANEL_PATH','').strip('/')
url=f'https://127.0.0.1:{port}/{path}/panel/api/inbounds/list'
# Loopback-only: panel cert is for the public domain but we connect via 127.0.0.1,
# so hostname/cert verification is intentionally skipped (request never leaves localhost).
ctx=ssl._create_unverified_context()
req=urllib.request.Request(url, headers={
    'Authorization':'Bearer '+token,
    'Accept':'application/json',
    'User-Agent':'XPAM-Script/health'
})
try:
    with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
        body=resp.read(1024*1024).decode('utf-8','replace')
except Exception as exc:
    print('FAIL: 3x-ui API token Bearer check failed')
    sys.exit(1)
try:
    data=json.loads(body)
except Exception:
    print('FAIL: 3x-ui API token Bearer check returned non-JSON response')
    sys.exit(1)
if data.get('success') is True:
    print('OK: 3x-ui API token Bearer check passed')
    sys.exit(0)
print('FAIL: 3x-ui API token Bearer check did not return success=true')
sys.exit(1)
PY_XPAM_XUI_HEALTH_TOKEN
    if [ $? -ne 0 ]; then fail=1; fi
    [ "$fail" -eq 0 ] && echo "OK: 3x-ui API token storage usable"
    return "$fail"
}
xpam_xui_xray_config_check(){
    local cfg="$1"
    echo; echo "===== 3X-UI / XRAY CONFIG CHECK ====="
    python3 - "$cfg" <<'EOF_PY_XUI'
import json, re, sqlite3, subprocess, sys
from pathlib import Path

def xui_env_value(key):
    path=Path('/etc/default/x-ui')
    if not path.exists():
        return ''
    value=''
    for line in path.read_text(errors='ignore').splitlines():
        if line.startswith(key+'='):
            value=line.split('=',1)[1].strip().strip('\"').strip("'")
    return value

def xui_backend_type():
    raw=xui_env_value('XUI_DB_TYPE')
    norm=''.join(str(raw).lower().split())
    if norm in ('', 'sqlite', 'sqlite3'):
        return 'sqlite'
    if norm in ('postgres', 'postgresql', 'pg'):
        return 'postgres'
    return 'unsupported:'+str(raw)
cfg={}
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line or line.startswith('#') or '=' not in line: continue
    k,v=line.split('=',1); cfg[k]=v.strip().strip("'").strip('"')
profile=cfg['PROFILE']; primary=cfg['PRIMARY_DOMAIN']
cert_name=cfg.get('WEB_CERT_NAME') or primary
cert=f'/etc/letsencrypt/live/{cert_name}/fullchain.pem'; key=f'/etc/letsencrypt/live/{cert_name}/privkey.pem'
expected_port=int(cfg['XRAY_LOCAL_PORT'])
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
backend=xui_backend_type()
if backend != 'sqlite':
    bad(f'3x-ui PostgreSQL/unsupported backend detected: {backend}. XPAM Script supports only 3x-ui SQLite backend at /etc/x-ui/x-ui.db.')
    sys.exit(1)
db_path=Path('/etc/x-ui/x-ui.db')
if not db_path.exists() or db_path.stat().st_size == 0:
    bad('3x-ui SQLite DB missing: /etc/x-ui/x-ui.db')
    sys.exit(1)
ok('3x-ui backend SQLite OK: /etc/x-ui/x-ui.db')
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
stream_col=next((c for c in ('stream_settings','streamSettings','stream') if c in cols), None)
if not cols:
    bad('3x-ui SQLite schema is not compatible: inbounds table missing or empty schema')
    sys.exit(1)
if not stream_col:
    bad('3x-ui SQLite schema is not compatible: stream settings column not found')
    sys.exit(1)
ok(f'3x-ui backend SQLite schema OK: stream settings column = {stream_col}')
rows=[]
if cols:
    q='select '+','.join('"'+c+'"' for c in cols)+' from inbounds'
    for tup in cur.execute(q): rows.append(dict(zip(cols,tup)))
db_candidates=[r for r in rows if str(r.get('protocol','')).lower()=='vless' and int(r.get('port') or 0)==expected_port]
if not db_candidates:
    db_inb=None
    bad(f'No database VLESS inbound on expected port {expected_port}')
elif len(db_candidates) > 1:
    db_inb=None
    bad(f'Multiple database VLESS inbounds on expected port {expected_port}; candidates={[(r.get("id"), r.get("remark"), r.get("listen")) for r in db_candidates]}')
else:
    db_inb=db_candidates[0]
if db_inb:
    print(f"id={db_inb.get('id')}, remark={db_inb.get('remark')}, enable={db_inb.get('enable')}, listen={db_inb.get('listen') or '<empty>'}, port={db_inb.get('port')}, protocol={db_inb.get('protocol')}")
    if as_bool(db_inb.get('enable', False)): ok('VLESS inbound is enabled in database')
    else: bad('VLESS inbound is disabled in database')
    listen=str(db_inb.get('listen') or '')
    if listen=='127.0.0.1': ok('database VLESS inbound listen is local-only: 127.0.0.1')
    else: bad(f'database VLESS listen expected 127.0.0.1 got {listen!r}')
    st=jloads(db_inb.get('stream_settings') or db_inb.get('streamSettings') or db_inb.get('stream'), {})
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
    if fp in (None, ''):
        ok('database uTLS/fingerprint is empty-compatible')
    else:
        ok(f'database uTLS/fingerprint is compatible: {fp!r}')
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
    ep_match=[x for x in ep if isinstance(x,dict) and str(x.get('dest','')).lower()==primary.lower() and int(x.get('port') or 0)==public_port and str(x.get('forceTls','')).lower()=='same']
    # 3x-ui 3.4.x mirrors externalProxy into the `hosts` table (the future "Managed Hosts" model).
    # Read that mirror so XPAM keeps working (and health stays honest) if a later 3x-ui ever stops
    # maintaining streamSettings.externalProxy. forceTls 'same' maps to hosts.security 'same'.
    host_mirror=None
    try:
        for addr,prt,sec in cur.execute('select address,port,security from hosts where inbound_id=?', (db_inb.get('id'),)):
            if str(addr or '').lower()==primary.lower() and int(prt or 0)==public_port and str(sec or '').lower()=='same':
                host_mirror=(str(addr),int(prt or 0),str(sec)); break
    except Exception:
        host_mirror=None  # older 3x-ui without a hosts table -> externalProxy is the only source
    if ep_match:
        ok(f'database External Proxy points generated links to {primary}:{public_port} with forceTls=same')
        # migration radar (INFO, not an alarm): the mirror should agree, but today links use
        # externalProxy so a drifted/absent mirror does not affect the running service.
        if host_mirror:
            ok(f'hosts mirror row consistent with External Proxy ({primary}:{public_port}/same)')
        else:
            print(f'INFO: hosts mirror row for {primary}:{public_port} not present/does not match; links use externalProxy so service is unaffected (3x-ui->hosts migration radar)')
    elif host_mirror:
        # forward-compat fallback: externalProxy absent/changed but the hosts mirror still carries
        # the correct public endpoint, so generated links remain correct -> not a failure.
        ok(f'External Proxy not set in streamSettings; public endpoint resolved from hosts mirror {primary}:{public_port}/same (forward-compat)')
    else:
        bad(f'database External Proxy must contain forceTls=same, dest={primary}, port={public_port}; current={ep!r} and no matching hosts mirror row')
        if expected_port != public_port and any(isinstance(x,dict) and int(x.get('port') or 0)==expected_port for x in ep):
            bad(f'External Proxy incorrectly uses internal port {expected_port}; it must use public port {public_port}')
    if sniff.get('enabled') in (False, None, 0):
        ok('database sniffing is OFF for HAProxy mode')
    elif sniff.get('enabled') is True and sniff.get('routeOnly') is True:
        ok('database sniffing is ON with Route only; acceptable for optional WARP/domain routing')
    else:
        warn('database sniffing is enabled without Route only; review if WARP/domain routing is intended')
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
        if listen=='127.0.0.1': ok('generated Xray VLESS inbound listen is local-only: 127.0.0.1')
        else: bad(f'generated Xray VLESS listen expected 127.0.0.1 got {listen!r}')
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
        legacy_worker_keys=[k for k in ('workers','num_workers','NumWorkers') if k in settings]
        if legacy_worker_keys:
            warn(f'WARP {tag}: legacy WireGuard worker field(s) present: {legacy_worker_keys!r}; run XPAM WARP check/normalize to clean them')
        else:
            ok(f'WARP {tag}: no legacy workers field')
        def valid_reserved(v):
            return isinstance(v, list) and len(v)==3 and all(isinstance(x, int) and 0 <= x <= 255 for x in v)
        reserved=settings.get('reserved')
        peer_reserved=peer.get('reserved')
        endpoint=str(peer.get('endpoint') or '')
        if valid_reserved(reserved):
            ok(f'WARP {tag}: reserved bytes present')
        elif valid_reserved(peer_reserved):
            ok(f'WARP {tag}: peer reserved bytes present')
        elif tag == 'warp' and 'cloudflareclient.com' in endpoint.lower():
            warn(f'WARP {tag}: reserved bytes are missing. Cloudflare WARP normally uses 3 reserved bytes/clientid; WARP may still work, but a WARP profile with reserved bytes is recommended.')
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
    
    import shutil
    if not shutil.which('resolvectl'):
        ok('resolvectl is not installed; systemd-resolved DNS scope check is not applicable')
        status=''
    else:
        status=subprocess.run(['resolvectl','status'], text=True, stderr=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=3).stdout
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
    ok(f'resolvectl wg0 state check skipped: {e}')
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
        if systemctl is-failed --quiet "$unit" 2>/dev/null; then
            systemctl reset-failed "$unit" >/dev/null 2>&1 || true
            echo "FIXED: reset stale failed state for masked hygiene unit $unit"
        fi
        echo "OK: $unit already masked"
        return 0
    fi
    echo "FIXED: disable/mask $unit"
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
    systemctl mask "$unit" >/dev/null 2>&1 || true
    if systemctl is-failed --quiet "$unit" 2>/dev/null; then
        systemctl reset-failed "$unit" >/dev/null 2>&1 || true
        echo "FIXED: reset stale failed state for hygiene unit $unit"
    fi
}


xpam_rc_local_is_safe_noop(){
    [ -f /etc/rc.local ] || return 1
    python3 - <<'PY_RC_LOCAL'
from pathlib import Path
p = Path('/etc/rc.local')
try:
    lines = p.read_text(errors='ignore').splitlines()
except Exception:
    raise SystemExit(1)
body = []
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        continue
    body.append(stripped)
if body in (['exit 0'], ['exit 0;']):
    raise SystemExit(0)
raise SystemExit(1)
PY_RC_LOCAL
}

xpam_normalize_rc_local_noop(){
    # Some provider Debian images ship an enabled rc-local.service with a
    # no-op /etc/rc.local that is not executable. That creates a failed unit
    # even though there is no user payload. Fix only this safe no-op case.
    xpam_unit_exists rc-local.service || return 0
    [ -e /etc/rc.local ] || return 0
    xpam_rc_local_is_safe_noop || return 0

    local changed="no"
    if [ ! -x /etc/rc.local ]; then
        chmod 755 /etc/rc.local 2>/dev/null && changed="yes"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl is-failed --quiet rc-local.service 2>/dev/null; then
        systemctl reset-failed rc-local.service >/dev/null 2>&1 || true
        changed="yes"
    fi
    # Starting a no-op rc.local is safe and clears the current boot state.
    if ! systemctl is-active --quiet rc-local.service 2>/dev/null; then
        systemctl start rc-local.service >/dev/null 2>&1 || true
    fi
    if [ "$changed" = "yes" ]; then
        echo "FIXED: normalized provider no-op rc-local.service (/etc/rc.local executable, failed state reset)"
    else
        echo "OK: provider no-op rc-local.service looks clean"
    fi
}

xpam_failed_units_check(){
    local failed names unit names_csv fail=0
    echo
    echo "===== FAILED SYSTEMD UNITS ====="
    failed="$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk 'NF{print}')"
    if [ -z "$failed" ]; then
        echo "OK: no failed systemd units"
        return 0
    fi

    systemctl --failed --no-pager || true
    names="$(printf '%s\n' "$failed" | awk '{print $1}' | xargs 2>/dev/null || true)"
    names_csv="$(printf '%s\n' $names | paste -sd ', ' - 2>/dev/null || printf '%s' "$names")"

    if [ "$names" = "networking.service" ] && xpam_debian_networking_provider_warning_ok; then
        echo "WARN: networking.service failed, but active networking works; treating it as a provider Debian image warning"
        return 0
    fi

    for unit in $names; do
        if [ "$unit" = "rc-local.service" ] && xpam_rc_local_is_safe_noop && [ ! -x /etc/rc.local ]; then
            echo "FAIL: rc-local.service failed because provider no-op /etc/rc.local is not executable; run repair to normalize it safely"
        else
            echo "FAIL: failed systemd unit: $unit"
        fi
        fail=1
    done
    [ -n "$names_csv" ] && echo "FAIL: failed systemd units present: $names_csv"
    return "$fail"
}

xpam_normalize_provider_quirks(){
    xpam_normalize_rc_local_noop || true
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



xpam_ufw_runtime_check(){
    local status_line status
    if command -v ufw >/dev/null 2>&1; then
        status_line="$(ufw status 2>/dev/null | awk -F': *' '/^Status:/ {print $2; exit}')"
        status="$(printf '%s' "$status_line" | tr '[:upper:]' '[:lower:]')"
        if [ "$status" = "active" ]; then
            echo "OK: UFW status active"
            return 0
        fi
        if systemctl is-active --quiet ufw.service 2>/dev/null; then
            echo "WARN: ufw.service active but ufw status is ${status_line:-unknown}"
        fi
        echo "FAIL: UFW status is ${status_line:-unknown}"
        return 1
    fi
    if systemctl is-active --quiet ufw.service 2>/dev/null; then
        echo "OK: service ufw active"
        return 0
    fi
    echo "FAIL: ufw command not found and ufw.service is not active"
    return 1
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


xpam_xui_apply_fail2ban_optout_common(){
    local env_file="/etc/default/x-ui" tmp cli="/usr/bin/x-ui"
    [ -e /etc/x-ui/x-ui.db ] || [ -x /usr/local/x-ui/x-ui ] || [ -f "$cli" ] || return 0
    mkdir -p /etc/default
    touch "$env_file" 2>/dev/null || return 0
    chmod 644 "$env_file" 2>/dev/null || true
    if grep -q '^XUI_ENABLE_FAIL2BAN=' "$env_file" 2>/dev/null; then
        sed -i 's/^XUI_ENABLE_FAIL2BAN=.*/XUI_ENABLE_FAIL2BAN=false/' "$env_file" 2>/dev/null || true
    else
        printf '\n# Managed by XPAM Script: XPAM owns fail2ban; 3x-ui IP-limit fail2ban setup is disabled.\nXUI_ENABLE_FAIL2BAN=false\n' >> "$env_file" 2>/dev/null || true
    fi
    if [ -f "$cli" ] && head -n1 "$cli" 2>/dev/null | grep -Eq '^#!.*(sh|bash)'; then
        if ! grep -q 'XPAM BEGIN XUI FAIL2BAN OPTOUT' "$cli" 2>/dev/null; then
            tmp="$(mktemp /tmp/xpam-xui-cli.XXXXXX)" || return 0
            awk 'NR==1 {print; print "# XPAM BEGIN XUI FAIL2BAN OPTOUT"; print "export XUI_ENABLE_FAIL2BAN=\"${XUI_ENABLE_FAIL2BAN:-false}\""; print "# XPAM END XUI FAIL2BAN OPTOUT"; next} {print}' "$cli" > "$tmp" && cat "$tmp" > "$cli"
            rm -f "$tmp"
            chmod +x "$cli" 2>/dev/null || true
        fi
    fi
}

xpam_xui_fail2ban_ownership_check(){
    local fail=0 f status env_file="/etc/default/x-ui"
    echo; echo "===== 3X-UI FAIL2BAN OWNERSHIP CHECK ====="
    if [ -f "$env_file" ] && grep -Eq '^XUI_ENABLE_FAIL2BAN=false$' "$env_file"; then
        echo "OK: XUI_ENABLE_FAIL2BAN=false persisted in /etc/default/x-ui"
    else
        echo "WARNING: XUI_ENABLE_FAIL2BAN=false is not persisted in /etc/default/x-ui"
    fi
    for f in /etc/fail2ban/jail.d/3x-ipl.conf /etc/fail2ban/filter.d/3x-ipl.conf /etc/fail2ban/action.d/3x-ipl.conf; do
        if [ -e "$f" ]; then
            echo "WARNING: unexpected upstream 3x-ui IP-limit fail2ban file exists: $f"
        else
            echo "OK: absent upstream 3x-ui IP-limit fail2ban file: $f"
        fi
    done
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
        status="$(fail2ban-client status 2>/dev/null || true)"
        if printf '%s\n' "$status" | grep -Eq '(^|[ ,])3x-ipl([ ,]|$)'; then
            echo "WARNING: upstream 3x-ui IP-limit fail2ban jail is active: 3x-ipl"
        else
            echo "OK: no active upstream 3x-ui IP-limit fail2ban jail"
        fi
    else
        echo "WARNING: fail2ban-client is not available/running for ownership check"
    fi
    return "$fail"
}

xpam_xui_version_compat_check(){
    local db="/etc/x-ui/x-ui.db" cfg="/usr/local/x-ui/bin/config.json" xui_ver xray_ver mode journal_mode
    echo; echo "===== 3X-UI VERSION / COMPATIBILITY CHECK ====="
    if [ -x /usr/local/x-ui/x-ui ]; then
        xui_ver=""
        for xpam_xui_ver_arg in version --version -v; do
            xpam_xui_ver_out="$(/usr/local/x-ui/x-ui "$xpam_xui_ver_arg" 2>/dev/null | head -n1 || true)"
            case "$xpam_xui_ver_out" in
                ""|*"Invalid subcommands"*|*"invalid subcommands"*|*"Usage:"*|*"usage:"*|*"unknown"*|*"Unknown"*)
                    ;;
                *)
                    xui_ver="$xpam_xui_ver_out"
                    break
                    ;;
            esac
        done
        [ -n "$xui_ver" ] && echo "INFO: 3x-ui version: $xui_ver" || echo "INFO: 3x-ui version: unavailable via CLI"
    else
        echo "WARNING: /usr/local/x-ui/x-ui is missing or not executable"
    fi
    if [ -x /usr/local/x-ui/bin/xray-linux-amd64 ]; then
        xray_ver="$(/usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -n1 || true)"
        [ -n "$xray_ver" ] && echo "INFO: Xray core: $xray_ver" || echo "INFO: Xray version command returned no output"
    else
        echo "WARNING: /usr/local/x-ui/bin/xray-linux-amd64 missing or not executable"
    fi
    # XPAM last-validated baseline. INFO only -- NO warn/fail/notify: a newer 3x-ui/Xray that
    # still passes the functional checks above is fine, so the version number alone never alarms
    # the user. This line is diagnostic (maintainer + auto-test). BUMP both values after a
    # fresh-install + deep-health test passes on a newer 3x-ui.
    local LV_XUI="3.4.2" LV_XRAY="26.6.27" xui_sem xray_sem
    xui_sem="$(printf '%s' "${xui_ver:-}"  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    xray_sem="$(printf '%s' "${xray_ver:-}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    echo "INFO: XPAM last-validated baseline: 3x-ui ${LV_XUI} / Xray ${LV_XRAY} (functional checks above are authoritative)"
    if [ -n "$xui_sem" ]; then
        if [ "$xui_sem" = "$LV_XUI" ]; then
            echo "INFO: installed 3x-ui ${xui_sem} matches XPAM last-validated baseline"
        else
            echo "INFO: installed 3x-ui ${xui_sem} differs from baseline ${LV_XUI}"
        fi
    fi
    if [ -n "$xray_sem" ]; then
        if [ "$xray_sem" = "$LV_XRAY" ]; then
            echo "INFO: installed Xray ${xray_sem} matches XPAM last-validated baseline"
        else
            echo "INFO: installed Xray ${xray_sem} differs from baseline ${LV_XRAY}"
        fi
    fi
    if [ -f "$cfg" ]; then
        mode="$(stat -c '%a' "$cfg" 2>/dev/null || echo unknown)"
        case "$mode" in
            600|640|644) echo "OK: generated Xray config permissions acceptable for root health: $mode" ;;
            *) echo "WARNING: generated Xray config permissions unusual: $mode" ;;
        esac
        python3 - "$cfg" <<'PY_XPAM_CONFIG_JSON_CHECK'
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data=json.load(f)
    print('OK: generated Xray config JSON parsed')
except Exception as exc:
    print(f'WARNING: generated Xray config JSON parse failed: {exc}')
PY_XPAM_CONFIG_JSON_CHECK
    else
        echo "WARNING: generated Xray config missing: $cfg"
    fi
    if [ -s "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
        journal_mode="$(sqlite3 "$db" 'PRAGMA journal_mode;' 2>/dev/null | head -n1 || true)"
        [ -n "$journal_mode" ] && echo "INFO: 3x-ui SQLite journal_mode: $journal_mode" || echo "WARNING: could not read SQLite journal_mode"
        sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='settings' AND sql LIKE '%key%' LIMIT 1;" 2>/dev/null | grep -q . \
          && echo "OK: settings.key index present or compatible" \
          || echo "INFO: settings.key index not detected; acceptable on older 3x-ui"
    fi
}

xpam_xui_subscription_sanity_check(){
    local db="/etc/x-ui/x-ui.db" fail=0
    echo; echo "===== 3X-UI SUBSCRIPTION / MANAGED HOSTS SANITY CHECK ====="
    [ -s "$db" ] || { echo "WARNING: 3x-ui DB missing; subscription check skipped"; return 0; }
    python3 - "$db" <<'PY_XPAM_SUB_CHECK'
import sqlite3, sys
db=sys.argv[1]
conn=sqlite3.connect(db)
cur=conn.cursor()
fail=False
def val(k):
    row=cur.execute('SELECT value FROM settings WHERE key=?', (k,)).fetchone()
    return None if row is None else str(row[0]).strip().lower()
for key in ('subEnable','subJsonEnable','subClashEnable','subEnableRouting'):
    v=val(key)
    if v in (None, '', 'false', '0', 'off', 'no'):
        print(f'OK: {key} disabled/absent')
    else:
        print(f'FAIL: {key} should be disabled under XPAM, got {v!r}')
        fail=True
# Managed Hosts are a 3x-ui subscription feature. XPAM does not use them; presence alone is informational.
for table in ('hosts','host','sub_hosts','subscription_hosts'):
    try:
        row=cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone()
        if row:
            count=cur.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]
            print(f'INFO: 3x-ui managed-hosts related table {table} rows={count}; XPAM does not use this feature')
    except Exception:
        pass
sys.exit(1 if fail else 0)
PY_XPAM_SUB_CHECK
    [ $? -eq 0 ] || fail=1
    if ss -H -lntup 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]+[[:space:]]+.*:2096\b'; then
        echo "FAIL: 3x-ui subscription listener :2096 is present"
        fail=1
    else
        echo "OK: no 3x-ui subscription listener on :2096"
    fi
    [ "$fail" -eq 0 ] && echo "OK: 3x-ui subscription/Managed Hosts do not affect XPAM public surface"
    return "$fail"
}

xpam_telegram_feature_separation_check(){
    echo; echo "===== TELEGRAM FEATURE SEPARATION CHECK ====="
    echo "OK: XPAM Telegram proxy / MTG is separate from 3x-ui Telegram notification event bus"
    echo "OK: XPAM Telegram notifications, when configured, remain XPAM-owned and separate from 3x-ui panel notifications"
}

xpam_write_journald_policy(){
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/90-xpam-script.conf <<'EOF_XPAM_JOURNALD'
# XPAM Script small-VM journal policy
[Journal]
SystemMaxUse=64M
RuntimeMaxUse=32M
MaxRetentionSec=14day
EOF_XPAM_JOURNALD
    chmod 644 /etc/systemd/journald.conf.d/90-xpam-script.conf 2>/dev/null || true
    systemctl restart systemd-journald 2>/dev/null || true
}

xpam_write_logrotate_policy(){
    if ! command -v logrotate >/dev/null 2>&1 && [ ! -d /etc/logrotate.d ]; then
        echo "INFO: logrotate not present; XPAM internal log retention remains active"
        return 0
    fi
    mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/xpam-script <<'EOF_XPAM_LOGROTATE'
/var/log/xpam-script/*.log /var/log/xpam-script/netdiag/*.txt {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0600 root root
}
EOF_XPAM_LOGROTATE
    chmod 644 /etc/logrotate.d/xpam-script 2>/dev/null || true
}

xpam_apply_small_vm_policies(){
    xpam_xui_apply_fail2ban_optout_common || true
    xpam_write_journald_policy || true
    xpam_write_logrotate_policy || true
}

xpam_apply_service_hygiene(){
    local cfg="$1"
    # shellcheck disable=SC1090
    . "$cfg"
    echo; echo "===== SERVICE HYGIENE APPLY ====="
    xpam_apply_small_vm_policies || true
    echo "Profile: ${PROFILE:-unknown}"
    xpam_normalize_provider_quirks
    for unit in \
      snapd.service snapd.socket snapd.seeded.service snapd.snap-repair.timer snapd.refresh.timer \
      packagekit.service packagekit-offline-update.service \
      fwupd.service fwupd-refresh.service fwupd-refresh.timer \
      apport.service apport-autoreport.service apport-forward@.service \
      unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service \
      motd-news.timer update-notifier-download.timer update-notifier-motd.timer \
      thermald.service sysstat.service sysstat-collect.timer sysstat-summary.timer
    do
        xpam_stop_disable_mask_unit "$unit"
    done
    if [ "${MTPROTO_BACKEND:-3xui-mtg}" = "3xui-mtg" ]; then
        systemctl stop mtprotoproxy.service >/dev/null 2>&1 || true
        systemctl disable mtprotoproxy.service >/dev/null 2>&1 || true
        systemctl reset-failed mtprotoproxy.service >/dev/null 2>&1 || true
    fi
    for unit in ssh.socket ssh.service nginx.service x-ui.service fail2ban.service ufw.service cron.service systemd-resolved.service systemd-timesyncd.service; do
        xpam_unit_exists "$unit" && systemctl enable "$unit" >/dev/null 2>&1 || true
    done
    xpam_unit_exists haproxy.service && systemctl enable haproxy.service >/dev/null 2>&1 || true
    if [ "${MTPROTO_BACKEND:-3xui-mtg}" = "3xui-mtg" ]; then
        systemctl disable mtprotoproxy.service >/dev/null 2>&1 || true
    else
        xpam_unit_exists mtprotoproxy.service && systemctl enable mtprotoproxy.service >/dev/null 2>&1 || true
    fi
    for pkg in snapd packagekit packagekit-tools fwupd apport apport-core-dump-handler unattended-upgrades thermald sysstat; do
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
      thermald.service sysstat.service
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
    for unit in snapd.snap-repair.timer snapd.refresh.timer fwupd-refresh.timer apt-daily.timer apt-daily-upgrade.timer motd-news.timer update-notifier-download.timer update-notifier-motd.timer sysstat-collect.timer sysstat-summary.timer; do
        enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
        state="$(systemctl is-active "$unit" 2>/dev/null || true)"
        if [ "$state" = "active" ] || [ "$enabled" = "enabled" ]; then
            echo "FAIL: extra timer enabled/active: $unit active=${state:-unknown} enabled=${enabled:-unknown}"
            fail=1
        else
            [ -n "$state" ] && [ "$state" != "unknown" ] && echo "OK: $unit active=$state enabled=${enabled:-unknown}"
        fi
    done
    systemctl is-active --quiet haproxy.service && echo "OK: required service active: haproxy.service" || { echo "FAIL: required service not active: haproxy.service"; fail=1; }
    if [ "${MTPROTO_BACKEND:-3xui-mtg}" = "3xui-mtg" ]; then
        state="$(systemctl is-active mtprotoproxy.service 2>/dev/null || true)"
        if [ "$state" = "active" ]; then echo "FAIL: mtprotoproxy.service must be inactive under 3xui-mtg"; fail=1; else echo "OK: mtprotoproxy.service inactive under 3xui-mtg (${state:-unknown})"; fi
    else
        systemctl is-active --quiet mtprotoproxy.service && echo "OK: required service active: mtprotoproxy.service" || { echo "FAIL: required service not active: mtprotoproxy.service"; fail=1; }
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
    xpam_apply_small_vm_policies || true
    xpam_guarded_autoremove "$prefix" || true
    apt-get clean || true
    apt-get autoclean -y || true
    rm -f /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin 2>/dev/null || true
    rm -rf /var/cache/apt/archives/partial/* 2>/dev/null || true
    rm -f /tmp/service-audit-*.txt /tmp/tls-cert.* /tmp/tls-info.* 2>/dev/null || true
    rm -f /root/recipe_*.log /root/recipe_-*.log /root/exec_recipe.log 2>/dev/null || true
    rm -f /root/*-health-*.txt /root/*-health-debian-*.txt 2>/dev/null || true
    rm -f /root/xpam-script-v*-*.log /root/xpam-script-*.log 2>/dev/null || true
    rm -f /root/.Xauthority /root/.lesshst 2>/dev/null || true
    for xpam_empty_cache_dir in /root/.ansible /root/.local; do
        if [ -d "$xpam_empty_cache_dir" ]; then
            find "$xpam_empty_cache_dir" -depth -type d -empty -delete 2>/dev/null || true
            rmdir "$xpam_empty_cache_dir" 2>/dev/null || true
        fi
    done
    rm -f /root/site-nginx-snapshot-*.tar.gz /root/*-nginx-snapshot-*.tar.gz 2>/dev/null || true
    find /root -maxdepth 1 -type d \( -name 'site-nginx-snapshot-*' -o -name '*-nginx-snapshot-*' \) -print -exec rm -rf {} + 2>/dev/null || true
    find /root/.ssh -maxdepth 1 -type f -name 'authorized_keys.bak-before-*' -print -delete 2>/dev/null || true
    find /root -maxdepth 1 -type f -name 'xpam-script-v*.log' -mtime +1 -print -delete 2>/dev/null || true
    find /root -maxdepth 1 -type f \( -name 'xpam-script*.tar.gz' -o -name 'xpam-script*.tgz' -o -name 'xpam-script*.sha256' -o -name 'xpam-script*.tar.gz.sha256' -o -name 'xpam-script*.tgz.sha256' \) -mtime +1 -print -delete 2>/dev/null || true
    rm -f /root/.lesshst 2>/dev/null || true
    rm -rf /var/www/html 2>/dev/null || true
    # Do not delete extracted XPAM Script directories during post-install cleanup.
    # The current install process may still need templates from that directory.
    # Final production cleanup handles extracted kit directories after the install is complete.
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
    xpam_apply_small_vm_policies || true

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
         -o -name '*-health-*.txt' \
         -o -name '*-health-debian-*.txt' \
         -o -name 'xpam-script-v*-*.log' \
         -o -name 'xpam-script-*.log' \
         -o -name '.Xauthority' \
         -o -name 'site-nginx-snapshot-*.tar.gz' \
         -o -name '*-nginx-snapshot-*.tar.gz' \) \
      -print -delete 2>/dev/null || true

    echo; echo "--- XPAM Script log and backup retention"
    xpam_prune_keep_latest "/var/log/xpam-script" "${prefix}-weekly-*.log" "${XPAM_WEEKLY_LOG_KEEP:-4}"
    xpam_prune_keep_latest "/var/log/xpam-script" "${prefix}-health-*.log" "${XPAM_HEALTH_LOG_KEEP:-4}"
    xpam_prune_keep_latest /root/config-backups "${prefix}-config-*.tar.gz" "${XPAM_BACKUP_KEEP:-2}"
    xpam_prune_keep_latest /root/manual-backups 'site-replace-check-*' "${XPAM_BACKUP_KEEP:-2}"
    xpam_prune_keep_latest /root/manual-backups 'site-reset-*' "${XPAM_BACKUP_KEEP:-2}"
    xpam_prune_keep_latest /root/manual-backups 'mtproto-users-*' "${XPAM_BACKUP_KEEP:-2}"
    xpam_prune_keep_latest /root/manual-backups/xui-warp-normalize 'x-ui.db.*' "${XPAM_BACKUP_KEEP:-2}"
    xpam_prune_keep_latest /root/manual-backups/xui-subscription-disable 'x-ui.db.*' "${XPAM_BACKUP_KEEP:-2}"
    xpam_prune_keep_latest /root/manual-backups 'mtproto-config.py.*' "${XPAM_BACKUP_KEEP:-2}"
    xpam_prune_keep_latest /root/manual-backups/xpam-doublehop '*' "${XPAM_DH_BACKUP_KEEP:-4}"
    find /root/manual-backups -type d -empty -delete 2>/dev/null || true

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
    journalctl --vacuum-size=24M 2>/dev/null || true
    journalctl --disk-usage 2>/dev/null || true

    for xpam_empty_cache_dir in /root/.ansible /root/.local; do
        if [ -d "$xpam_empty_cache_dir" ]; then
            find "$xpam_empty_cache_dir" -depth -type d -empty -delete 2>/dev/null || true
            rmdir "$xpam_empty_cache_dir" 2>/dev/null || true
        fi
    done

    echo; echo "--- cleanup summary"
    du -sh /root /var/cache /var/cache/apt /var/log /tmp /opt /usr/local/sbin 2>/dev/null || true
    echo "OK: weekly safe cleanup finished for $prefix"
}
