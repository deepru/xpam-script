#!/usr/bin/env bash
# XPAM Script module. This file is sourced by scripts/xpam-core.sh.
# Safe, manual, SHA-verified self-update from GitHub Releases.
# Keep functions side-effect free at source time.

xpam_update_ts(){ date +%Y%m%d-%H%M%S; }

xpam_update_strip_v(){
  local v="${1:-}"
  v="${v#v}"
  printf '%s' "$v"
}

xpam_update_current_version(){
  local rel="${RUNTIME_KIT_DIR:-/opt/xpam-script}/RELEASE" v=""
  if [[ -f "$rel" ]]; then
    v="$(awk -F= '$1=="XPAM_VERSION"{gsub(/^"|"$/, "", $2); print $2; exit}' "$rel" 2>/dev/null || true)"
  fi
  if [[ -z "$v" && -f "${RUNTIME_KIT_DIR:-/opt/xpam-script}/VERSION" ]]; then
    v="$(head -n1 "${RUNTIME_KIT_DIR:-/opt/xpam-script}/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  [[ -n "$v" ]] || v="${KIT_VERSION:-unknown}"
  xpam_update_strip_v "$v"
}

xpam_update_current_build(){
  local rel="${RUNTIME_KIT_DIR:-/opt/xpam-script}/RELEASE" b=""
  if [[ -f "$rel" ]]; then
    b="$(awk -F= '$1=="XPAM_BUILD"{gsub(/^"|"$/, "", $2); print $2; exit}' "$rel" 2>/dev/null || true)"
  fi
  [[ -n "$b" ]] || b="unknown"
  printf '%s' "$b"
}

xpam_update_compare_versions(){
  # Return 0 when $1 > $2 for simple stable semver-like versions.
  python3 - "$1" "$2" <<'PY'
import re, sys

def norm(v):
    v = (v or '').strip().lstrip('v')
    m = re.match(r'^(\d+)\.(\d+)\.(\d+)$', v)
    if not m:
        return None
    return tuple(int(x) for x in m.groups())

a, b = norm(sys.argv[1]), norm(sys.argv[2])
if a is None or b is None:
    sys.exit(2)
sys.exit(0 if a > b else 1)
PY
}

xpam_update_log_init(){
  XPAM_UPDATE_WORKDIR="/root/manual-backups/xpam-update/$(xpam_update_ts)"
  XPAM_UPDATE_LOG="${XPAM_UPDATE_WORKDIR}/update.log"
  mkdir -p "$XPAM_UPDATE_WORKDIR" "$XPAM_UPDATE_WORKDIR/download" "$XPAM_UPDATE_WORKDIR/staging" "$XPAM_UPDATE_WORKDIR/backup" "$XPAM_UPDATE_WORKDIR/pre-state" "$XPAM_UPDATE_WORKDIR/post-state"
  chmod 700 "$XPAM_UPDATE_WORKDIR" 2>/dev/null || true
  # Keep only the newest N self-update work dirs (each holds a download + pre-update
  # backup, ~3 MB). Without this they accumulate on every update and clutter the disk.
  prune_keep_latest /root/manual-backups/xpam-update '*' "${XPAM_UPDATE_KEEP:-2}" 2>/dev/null || true
  : > "$XPAM_UPDATE_LOG"
  chmod 600 "$XPAM_UPDATE_LOG" 2>/dev/null || true
}

xpam_update_log(){
  local msg="$*"
  printf '%s %s\n' "$(date '+%F %T')" "$msg" >> "${XPAM_UPDATE_LOG:-/dev/null}" 2>/dev/null || true
}

xpam_update_release_api(){
  local api owner repo
  api="${XPAM_UPDATE_RELEASE_API:-}"
  owner="${XPAM_UPDATE_REPO_OWNER:-deepru}"
  repo="${XPAM_UPDATE_REPO_NAME:-xpam-script}"
  if [[ -z "$api" && -n "$owner" && -n "$repo" ]]; then
    api="https://api.github.com/repos/${owner}/${repo}/releases/latest"
  fi
  printf '%s' "$api"
}

xpam_update_release_source_label(){
  local owner repo api
  api="${XPAM_UPDATE_RELEASE_API:-}"
  owner="${XPAM_UPDATE_REPO_OWNER:-deepru}"
  repo="${XPAM_UPDATE_REPO_NAME:-xpam-script}"
  if [[ -n "$api" ]]; then
    printf '%s' "$api"
  elif [[ -n "$owner" && -n "$repo" ]]; then
    printf 'GitHub: %s/%s' "$owner" "$repo"
  else
    printf 'не настроен'
  fi
}

xpam_update_download_url(){
  local url="$1" out="$2" ip max_time
  max_time="${XPAM_UPDATE_DOWNLOAD_MAX_TIME:-180}"
  rm -f "$out"
  if curl --http1.1 -fsSL --connect-timeout 20 --max-time "$max_time" --retry 5 --retry-delay 2 --retry-all-errors \
    -H 'Accept: application/vnd.github+json' \
    -o "$out" "$url"; then
    return 0
  fi

  case "$url" in
    *github.com/*|*githubusercontent.com/*) ;;
    *) return 1 ;;
  esac

  xpam_update_log "normal GitHub download failed; trying CDN edge fallback for $url"
  for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
    rm -f "$out"
    xpam_update_log "trying GitHub CDN edge $ip for $url"
    if curl --http1.1 -fsSL --connect-timeout 15 --max-time "$max_time" --retry 1 --retry-delay 1 --retry-all-errors \
      --resolve "release-assets.githubusercontent.com:443:${ip}" \
      --resolve "raw.githubusercontent.com:443:${ip}" \
      --resolve "objects.githubusercontent.com:443:${ip}" \
      -H 'Accept: application/vnd.github+json' \
      -o "$out" "$url"; then
      return 0
    fi
  done
  rm -f "$out"
  return 1
}

xpam_update_fetch_release_metadata(){
  local api metadata
  api="$(xpam_update_release_api)"
  metadata="${XPAM_UPDATE_WORKDIR}/download/release.json"
  if [[ -z "$api" ]]; then
    echo
    echo "Источник обновлений XPAM не настроен."
    echo "Изменения не внесены."
    xpam_update_log "release source is not configured"
    return 2
  fi
  xpam_update_log "release source: $(xpam_update_release_source_label)"
  if ! xpam_update_download_url "$api" "$metadata" >>"$XPAM_UPDATE_LOG" 2>&1; then
    echo
    echo "Не удалось получить информацию об обновлении XPAM."
    echo "Изменения не внесены."
    xpam_update_log "failed to download release metadata"
    return 1
  fi
  XPAM_UPDATE_METADATA="$metadata"
  return 0
}

xpam_update_parse_release_metadata(){
  local current out
  current="$(xpam_update_current_version)"
  out="${XPAM_UPDATE_WORKDIR}/download/release.env"
  mkdir -p "$(dirname "$out")"
  python3 - "$XPAM_UPDATE_METADATA" "$current" "$out" <<'PY'
import json, os, re, sys
meta_path, current, out_path = sys.argv[1:4]
with open(meta_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)

def version_from_text(text):
    m = re.search(r'v?(\d+\.\d+\.\d+)(?:$|[^0-9])', text or '')
    return m.group(1) if m else ''

def norm(v):
    m = re.match(r'^(\d+)\.(\d+)\.(\d+)$', (v or '').strip().lstrip('v'))
    return tuple(map(int, m.groups())) if m else None

if data.get('draft'):
    fail('draft release is not allowed')
if data.get('prerelease'):
    fail('prerelease is not allowed on stable channel')

version = version_from_text(data.get('tag_name')) or version_from_text(data.get('name'))
if not version:
    fail('cannot detect release version')

cur_n, new_n = norm(current), norm(version)
if cur_n is None or new_n is None:
    fail('unsupported version format')

no_update = new_n <= cur_n
archive = None
sha = None
for asset in data.get('assets') or []:
    name = asset.get('name') or ''
    url = asset.get('browser_download_url') or asset.get('url') or ''
    if not url:
        continue
    if re.match(r'^xpam-script-.*\.tar\.gz$', name) and not name.endswith('.sha256'):
        archive = (name, url)
    elif re.match(r'^xpam-script-.*\.tar\.gz\.sha256$', name) or name.endswith('.sha256'):
        sha = (name, url)

with open(out_path, 'w', encoding='utf-8') as o:
    o.write(f'XPAM_UPDATE_LATEST_VERSION={version}\n')
    o.write(f'XPAM_UPDATE_NO_UPDATE={1 if no_update else 0}\n')
    if archive:
        o.write(f'XPAM_UPDATE_ARCHIVE_NAME={archive[0]}\n')
        o.write(f'XPAM_UPDATE_ARCHIVE_URL={archive[1]}\n')
    if sha:
        o.write(f'XPAM_UPDATE_SHA_NAME={sha[0]}\n')
        o.write(f'XPAM_UPDATE_SHA_URL={sha[1]}\n')

if no_update:
    sys.exit(0)
if not archive:
    fail('release archive asset is missing')
if not sha:
    fail('release sha256 asset is missing')
PY
  local parse_rc=$?
  if [[ "$parse_rc" -ne 0 ]]; then
    return "$parse_rc"
  fi
  # shellcheck source=/dev/null
  source "$out"
}

xpam_update_confirm(){
  local current latest ans
  current="$(xpam_update_current_version)"
  latest="${XPAM_UPDATE_LATEST_VERSION:-unknown}"
  echo
  echo "Проверка обновлений XPAM..."
  echo
  echo "Текущая версия: ${current}"
  echo "Доступная версия: ${latest}"
  echo
  echo "XPAM загрузит обновление с GitHub Release,"
  echo "проверит SHA256 и создаст резервную копию перед установкой."
  echo
  echo "Ваши ссылки подключения не должны измениться."
  echo
  read -r -p "Продолжить? [yes/no]: " ans
  [[ "$ans" == "yes" ]]
}

xpam_update_preflight_runtime(){
  local free_kb required_kb prefix
  load_config
  prefix="$SERVER_PREFIX"

  if ! dpkg --audit >/tmp/xpam-update-dpkg-audit.$$ 2>&1; then
    :
  fi
  if [[ -s /tmp/xpam-update-dpkg-audit.$$ ]]; then
    rm -f /tmp/xpam-update-dpkg-audit.$$
    echo
    echo "APT/DPKG находится в незавершённом состоянии."
    echo "Обновление не начато. Изменения не внесены."
    xpam_update_log "dirty dpkg state; abort before mutation"
    return 1
  fi
  rm -f /tmp/xpam-update-dpkg-audit.$$

  free_kb="$(df -Pk /root | awk 'NR==2{print $4}')"
  required_kb="${XPAM_UPDATE_MIN_FREE_KB:-524288}"
  if [[ "${free_kb:-0}" -lt "$required_kb" ]]; then
    echo
    echo "Недостаточно свободного места для безопасного обновления XPAM."
    echo "Свободно: $((free_kb/1024)) MB, требуется минимум: $((required_kb/1024)) MB."
    echo "Изменения не внесены."
    xpam_update_log "free disk too low: ${free_kb} KB"
    return 1
  fi

  # A failing health check does NOT block the update, and must not: the update is
  # frequently the thing that fixes it. 3x-ui 3.8 moved the mtproto share address,
  # which turned health red on every box that upgraded the panel first — and the
  # release carrying the fix could not be installed, because this very gate refused
  # to start. A gate that locks a server out of its own repair is worse than no gate.
  #
  # What replaces it: the failures are RECORDED here and the postcheck rolls back
  # only if the update ADDED failures. Both quick and deep are captured, because the
  # postcheck compares against both and a deep-only failure would otherwise read as
  # new. That costs one deep-health run before the download.
  if [[ -x "/usr/local/sbin/${prefix}-health" ]]; then
    local pre_dir failures
    pre_dir="${XPAM_UPDATE_WORKDIR}/pre-state"
    mkdir -p "$pre_dir"
    "/usr/local/sbin/${prefix}-health" > "$pre_dir/health.txt" 2>&1 || true
    "/usr/local/sbin/${prefix}-health" --deep > "$pre_dir/health-deep.txt" 2>&1 || true
    xpam_update_health_failures "$pre_dir/health.txt" "$pre_dir/health-deep.txt" \
      > "$pre_dir/health-failures.txt"
    failures="$(wc -l < "$pre_dir/health-failures.txt" | tr -d ' ')"
    if [[ "${failures:-0}" -gt 0 ]]; then
      echo
      echo "Внимание: сервер уже сообщает о проблемах (${failures})."
      echo "Обновление продолжится — оно часто и является их исправлением."
      echo "XPAM откатится только в том случае, если обновление добавит НОВЫЕ проблемы."
      echo
      xpam_update_log "pre-update health reports ${failures} failure(s); continuing, judged on new failures only"
    fi
  fi
  return 0
}

# The FAIL lines of one or more health transcripts: colour stripped, deduplicated,
# sorted. Used on both sides of the update so the two sets can be compared.
xpam_update_health_failures(){
  [[ "$#" -gt 0 ]] || return 0
  cat "$@" 2>/dev/null \
    | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' \
    | grep -E '^[[:space:]]*FAIL:' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | sort -u
}

xpam_update_download_assets(){
  local d archive sha
  d="${XPAM_UPDATE_WORKDIR}/download"
  archive="$d/${XPAM_UPDATE_ARCHIVE_NAME}"
  sha="$d/${XPAM_UPDATE_SHA_NAME}"
  say "Загрузка архива обновления XPAM"
  xpam_update_download_url "$XPAM_UPDATE_ARCHIVE_URL" "$archive" >>"$XPAM_UPDATE_LOG" 2>&1
  xpam_update_download_url "$XPAM_UPDATE_SHA_URL" "$sha" >>"$XPAM_UPDATE_LOG" 2>&1
  XPAM_UPDATE_ARCHIVE_PATH="$archive"
  XPAM_UPDATE_SHA_PATH="$sha"
}

xpam_update_verify_sha256(){
  local expected actual
  expected="$(awk '{print $1; exit}' "$XPAM_UPDATE_SHA_PATH" | tr -cd 'A-Fa-f0-9')"
  actual="$(sha256sum "$XPAM_UPDATE_ARCHIVE_PATH" | awk '{print $1}')"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo
    echo "Не удалось безопасно загрузить или проверить обновление XPAM."
    echo
    echo "SHA256 не совпадает или файл проверки недоступен."
    echo "Изменения не внесены."
    xpam_update_log "sha256 mismatch or empty expected hash"
    return 1
  fi
  xpam_update_log "sha256 verified for archive ${XPAM_UPDATE_ARCHIVE_NAME}"
  return 0
}

xpam_update_extract_staging(){
  local s root_count root_dir
  s="${XPAM_UPDATE_WORKDIR}/staging"
  mkdir -p "$s/extract"
  tar -xzf "$XPAM_UPDATE_ARCHIVE_PATH" -C "$s/extract"
  root_count="$(find "$s/extract" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  if [[ "$root_count" -ne 1 ]]; then
    xpam_update_log "invalid archive layout: root_count=$root_count"
    return 1
  fi
  root_dir="$(find "$s/extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -f "$root_dir/install.sh" && -f "$root_dir/scripts/xpam-core.sh" ]] || return 1
  XPAM_UPDATE_STAGING_ROOT="$root_dir"
}

xpam_update_static_preflight(){
  local root f required failed=0
  root="$XPAM_UPDATE_STAGING_ROOT"
  # Must stay identical (as a set) to REQUIRED_FILES in make-release.sh — a gate in its verify_tree
  # compares the two and fails the build on any drift. Rationale for the full list: xpam-core.sh
  # sources every scripts/lib/*.sh and the code renders every templates/*.tpl, so an archive missing
  # any of them installs "successfully" and then breaks at repair/render time instead of failing here.
  required=(
    "install.sh"
    "bootstrap.sh"
    "VERSION"
    "RELEASE"
    "scripts/xpam-core.sh"
    "scripts/lib/xpam-alt-transport.sh"
    "scripts/lib/xpam-doublehop.sh"
    "scripts/lib/xpam-launchers.sh"
    "scripts/lib/xpam-maintenance.sh"
    "scripts/lib/xpam-mtproto.sh"
    "scripts/lib/xpam-notify.sh"
    "scripts/lib/xpam-sites.sh"
    "scripts/lib/xpam-update.sh"
    "scripts/lib/xpam-xui.sh"
    "scripts/lib/xpam_xray_compat.py"
    "templates/backend-order.conf.tpl"
    "templates/check-dns-policy.sh.tpl"
    "templates/check-network-tuning-policy.sh.tpl"
    "templates/haproxy.cfg.tpl"
    "templates/health.sh.tpl"
    "templates/nginx-alt-acme.conf.tpl"
    "templates/nginx-alt-grpc.conf.tpl"
    "templates/nginx-alt-xhttp.conf.tpl"
    "templates/nginx-certonly.conf.tpl"
    "templates/nginx-direct.conf.tpl"
    "templates/nginx-mtproto.conf.tpl"
    "templates/post-reboot-maint.service.tpl"
    "templates/post-reboot-maint.sh.tpl"
    "templates/wait-for-local-port.sh.tpl"
    "templates/weekly.sh.tpl"
    "templates/xpam-maint-common.sh.tpl"
    "sites/_mask/generate.py"
    "sites/_mask/presets.json"
    "sites/_mask/themes/_layout.css"
  )
  for f in "${required[@]}"; do
    [[ -f "$root/$f" ]] || { xpam_update_log "required file missing in update archive: $f"; return 1; }
  done

  bash -n "$root/install.sh" || failed=1
  bash -n "$root/scripts/xpam-core.sh" || failed=1
  while IFS= read -r -d '' f; do
    bash -n "$f" || failed=1
  done < <(find "$root/scripts/lib" -type f -name '*.sh' -print0)
  while IFS= read -r -d '' f; do
    bash -n "$f" || failed=1
  done < <(find "$root/templates" -type f -name '*.sh.tpl' -print0)

  if [[ "$failed" != "0" ]]; then
    xpam_update_log "static preflight failed: bash syntax error in staged archive"
    return 1
  fi

  if ! (
    cd "$root"
    export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
    # shellcheck source=/dev/null
    source ./scripts/xpam-core.sh >/dev/null 2>&1
  ); then
    xpam_update_log "static preflight failed: staged xpam-core source check failed"
    return 1
  fi

  if ! grep -q 'xpam_update_menu' "$root/scripts/lib/xpam-update.sh"; then
    xpam_update_log "updater function missing in new archive"
    return 1
  fi
}

xpam_update_link_hashes_capture(){
  local out prefix dest v tg
  prefix="$1"
  dest="$2"
  mkdir -p "$dest"
  : > "$dest/link-hashes.env"
  if [[ ! -x "/usr/local/sbin/${prefix}-links" ]]; then
    return 1
  fi
  out="$(mktemp /tmp/xpam-update-links.XXXXXX)" || return 1
  chmod 600 "$out" || { rm -f "$out"; return 1; }
  if "/usr/local/sbin/${prefix}-links" > "$out" 2>/dev/null; then
    # Compare every connection, including spare transports and additional clients.
    # Ordering in the summary is presentation only; changing a connection is not.
    v="$(grep -Eo 'vless://[^[:space:]]+' "$out" | LC_ALL=C sort -u | sha256sum | awk '{print $1}' || true)"
    tg="$(grep -Eo 'tg://proxy\?[^[:space:]]+' "$out" | LC_ALL=C sort -u | sha256sum | awk '{print $1}' || true)"
    [[ -n "$v" ]] && printf 'XPAM_UPDATE_VLESS_HASH=%s\n' "$v" >> "$dest/link-hashes.env"
    [[ -n "$tg" ]] && printf 'XPAM_UPDATE_TG_HASH=%s\n' "$tg" >> "$dest/link-hashes.env"
  else
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
}

xpam_update_dh_mode_capture(){
  local dest="$1" mode="unknown"
  if declare -F dh_detect_mode >/dev/null 2>&1; then
    mode="$(dh_detect_mode 2>/dev/null || echo unknown)"
  fi
  printf '%s\n' "$mode" > "$dest/doublehop-mode.txt"
}

xpam_update_snapshot_create(){
  local b prefix p safe
  load_config
  prefix="$SERVER_PREFIX"
  b="${XPAM_UPDATE_WORKDIR}/backup"
  mkdir -p "$b/usr-local-sbin" "$b/usr-local-bin" "$b/opt" "$b/etc"

  xpam_update_link_hashes_capture "$prefix" "${XPAM_UPDATE_WORKDIR}/pre-state" || return 1
  xpam_update_dh_mode_capture "${XPAM_UPDATE_WORKDIR}/pre-state"

  if [[ -d "$RUNTIME_KIT_DIR" ]]; then
    cp -a "$RUNTIME_KIT_DIR" "$b/opt/xpam-script" || return 1
  fi
  if [[ -d "$CONFIG_DIR" ]]; then
    cp -a "$CONFIG_DIR" "$b/etc/xpam-script" || return 1
  fi

  for p in \
    "/usr/local/sbin/${prefix}-xpam" "/usr/local/bin/${prefix}-xpam" \
    "/usr/local/sbin/${prefix}-health" "/usr/local/sbin/${prefix}-links" \
    "/usr/local/sbin/${prefix}-repair" \
    "/usr/local/sbin/${prefix}-netdiag" "/usr/local/sbin/${prefix}-weekly-maintenance.sh" \
    "/usr/local/sbin/${prefix}-post-reboot-maint.sh" "/etc/systemd/system/${prefix}-post-reboot-maint.service" \
    "/usr/local/sbin/xpam-maint-common.sh" \
    "/usr/local/sbin/check-dns-policy.sh" "/usr/local/sbin/check-network-tuning-policy" \
    "/usr/local/sbin/telegram-https-relay.py" "/usr/bin/x-ui" \
    "/usr/local/bin/${prefix}-health" "/usr/local/bin/${prefix}-links" \
    "/usr/local/bin/${prefix}-repair" "/usr/local/bin/${prefix}-netdiag" \
    "/usr/local/bin/${prefix}-weekly-maintenance" \
    "/etc/hosts" "/etc/default/x-ui" \
    "/etc/systemd/journald.conf.d/90-xpam-script.conf" "/etc/logrotate.d/xpam-script" \
    "/etc/cron.d/${prefix}-weekly-maintenance" \
    "/usr/local/sbin/${prefix}-install" "/usr/local/bin/${prefix}-install"
  do
    safe="${p#/}"
    mkdir -p "$b/$(dirname "$safe")"
    if [[ -e "$p" || -L "$p" ]]; then
      cp -a "$p" "$b/$safe" || return 1
      printf 'present %s\n' "$p" >> "$b/manifest.txt"
    else
      printf 'absent %s\n' "$p" >> "$b/manifest.txt"
    fi
  done
  mkdir -p "$b/etc/x-ui" || return 1
  xui_db_safe_copy "$b/etc/x-ui/x-ui.db" || return 1
  systemctl is-active x-ui > "$b/x-ui-state" 2>/dev/null || true
  systemctl is-enabled "${prefix}-post-reboot-maint.service" > "$b/post-reboot-state" 2>/dev/null || true
  xpam_update_log "backup created at $b"
}

xpam_update_restore_path(){
  local p b safe
  p="$1"; b="$2"; safe="${p#/}"
  if grep -qx "present $p" "$b/manifest.txt" 2>/dev/null; then
    mkdir -p "$(dirname "$p")"
    rm -rf "$p"
    cp -a "$b/$safe" "$p"
  else
    rm -f "$p"
  fi
}

xpam_update_rollback(){
  local b prefix p
  b="${XPAM_UPDATE_WORKDIR}/backup"
  prefix="${SERVER_PREFIX:-}"
  echo
  warn "Обновление не удалось. Выполняется rollback..."
  xpam_update_log "rollback started"
  cd /

  if [[ -d "$b/opt/xpam-script" ]]; then
    rm -rf "$RUNTIME_KIT_DIR"
    cp -a "$b/opt/xpam-script" "$RUNTIME_KIT_DIR"
  fi
  if [[ -d "$b/etc/xpam-script" ]]; then
    rm -rf "$CONFIG_DIR"
    cp -a "$b/etc/xpam-script" "$CONFIG_DIR"
  fi

  if [[ -n "$prefix" ]]; then
    for p in \
      "/usr/local/sbin/${prefix}-xpam" "/usr/local/bin/${prefix}-xpam" \
      "/usr/local/sbin/${prefix}-health" "/usr/local/sbin/${prefix}-links" \
      "/usr/local/sbin/${prefix}-repair" \
      "/usr/local/sbin/${prefix}-netdiag" "/usr/local/sbin/${prefix}-weekly-maintenance.sh" \
      "/usr/local/sbin/${prefix}-post-reboot-maint.sh" "/etc/systemd/system/${prefix}-post-reboot-maint.service" \
      "/usr/local/sbin/xpam-maint-common.sh" \
    "/usr/local/sbin/check-dns-policy.sh" "/usr/local/sbin/check-network-tuning-policy" \
    "/usr/local/sbin/telegram-https-relay.py" "/usr/bin/x-ui" \
    "/usr/local/bin/${prefix}-health" "/usr/local/bin/${prefix}-links" \
    "/usr/local/bin/${prefix}-repair" "/usr/local/bin/${prefix}-netdiag" \
    "/usr/local/bin/${prefix}-weekly-maintenance" \
    "/etc/hosts" "/etc/default/x-ui" \
    "/etc/systemd/journald.conf.d/90-xpam-script.conf" "/etc/logrotate.d/xpam-script" \
    "/etc/cron.d/${prefix}-weekly-maintenance" \
      "/usr/local/sbin/${prefix}-install" "/usr/local/bin/${prefix}-install"
    do
      xpam_update_restore_path "$p" "$b"
    done
    # A rolled-back (pre-1.4.0) runtime has no post-reboot unit; make sure a
    # leftover armed unit from the new version cannot linger enabled.
    if grep -qx enabled "$b/post-reboot-state" 2>/dev/null; then
      systemctl enable "${prefix}-post-reboot-maint.service" >/dev/null 2>&1 || true
    else
      systemctl disable "${prefix}-post-reboot-maint.service" >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  # Try to regenerate launchers from restored runtime as an extra safety net.
  if [[ -f "$RUNTIME_KIT_DIR/scripts/xpam-core.sh" ]]; then
    (
      cd /
      export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
      # shellcheck source=/dev/null
      source "$RUNTIME_KIT_DIR/scripts/xpam-core.sh"
      load_config
      write_install_launcher || true
      write_health_weekly || true
      write_common_library || true
    ) >>"$XPAM_UPDATE_LOG" 2>&1 || true
  fi

  if [[ -s "$b/etc/x-ui/x-ui.db" ]]; then
    systemctl stop x-ui || return 1
    install -m 600 "$b/etc/x-ui/x-ui.db" /etc/x-ui/x-ui.db || return 1
    rm -f /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm
    if grep -qx active "$b/x-ui-state"; then
      systemctl start x-ui || return 1
      /usr/local/sbin/wait-for-local-port.sh 127.0.0.1 "$XUI_PANEL_PORT" 30 xui-panel || return 1
      wait_for_xray_vless 30 || return 1
    fi
  fi
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  xpam_update_log "rollback finished"
}

xpam_update_apply(){
  local root
  root="$XPAM_UPDATE_STAGING_ROOT"
  say "Применение обновления XPAM"
  cd /
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude '.git' --exclude '*.log' "$root"/ "$RUNTIME_KIT_DIR"/ || return 1
  else
    find "$RUNTIME_KIT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    (cd "$root" && tar --exclude='.git' --exclude='*.log' -cf - .) | (cd "$RUNTIME_KIT_DIR" && tar -xf -) || return 1
  fi
  chmod 755 "$RUNTIME_KIT_DIR" "$RUNTIME_KIT_DIR/install.sh" 2>/dev/null || true

  (
    cd /
    export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
    # shellcheck source=/dev/null
    source "$RUNTIME_KIT_DIR/scripts/xpam-core.sh" || exit 1
    load_config || exit 1
    fix_managed_hosts || true
    install_runtime_kit || exit 1
    xpam_xui_apply_fail2ban_optout || true
    write_install_launcher || exit 1
    write_health_weekly || exit 1
    write_common_library || exit 1
    # 3x-ui's own one-shot 3.8 migration rewrites the MTG share address into a `hosts` row
    # WITHOUT a port, and a portless row inherits the inbound's INTERNAL port. A panel upgrade
    # never runs XPAM, so nothing reconciled it and the next health run went red on a box the
    # operator had done nothing wrong to. Heal it here as well as in repair.
    # Narrow on purpose: NOT mtproto_backend_repair_after_update, which may decide to reinstall
    # the MTG runtime and re-mint the managed client's id/subId — an update must not do that.
    if uses_mtproto; then
      mtproto_3xui_mtg_ensure_share_host "$(mtproto_3xui_mtg_resolve_managed_id 2>/dev/null || true)" || true
    fi
    if [[ -f /usr/local/sbin/xpam-maint-common.sh ]]; then
      # shellcheck source=/dev/null
      . /usr/local/sbin/xpam-maint-common.sh
      xpam_apply_small_vm_policies || true
    fi
  ) >>"$XPAM_UPDATE_LOG" 2>&1
}

xpam_update_compare_link_hashes(){
  local prefix before after b_v b_t a_v a_t
  prefix="$1"
  before="${XPAM_UPDATE_WORKDIR}/pre-state/link-hashes.env"
  after="${XPAM_UPDATE_WORKDIR}/post-state"
  xpam_update_link_hashes_capture "$prefix" "$after" || return 1
  b_v="$(awk -F= '$1=="XPAM_UPDATE_VLESS_HASH"{print $2}' "$before" 2>/dev/null || true)"
  b_t="$(awk -F= '$1=="XPAM_UPDATE_TG_HASH"{print $2}' "$before" 2>/dev/null || true)"
  a_v="$(awk -F= '$1=="XPAM_UPDATE_VLESS_HASH"{print $2}' "$after/link-hashes.env" 2>/dev/null || true)"
  a_t="$(awk -F= '$1=="XPAM_UPDATE_TG_HASH"{print $2}' "$after/link-hashes.env" 2>/dev/null || true)"
  [[ -z "$b_v" || "$b_v" == "$a_v" ]] || return 1
  [[ -z "$b_t" || "$b_t" == "$a_t" ]] || return 1
  return 0
}

xpam_update_postcheck(){
  local prefix before_mode after_mode
  cd /
  load_config
  prefix="$SERVER_PREFIX"

  [[ -x "/usr/local/sbin/${prefix}-xpam" ]] || { xpam_update_log "postcheck: xpam launcher missing"; return 1; }
  if command -v "${prefix}-install" >/dev/null 2>&1; then
    xpam_update_log "postcheck: old install launcher exists"
    return 1
  fi
  # Only the commands the kit guarantees to write. `netdiag` used to be in this list and was not
  # taken out when the launcher was dropped, so the updater demanded a file the same release had just
  # deleted — every update failed its own postcheck and rolled back. Whatever is listed here MUST be
  # written by write_health_weekly; make-release.sh enforces that as a gate.
  for c in health links repair; do
    [[ -x "/usr/local/sbin/${prefix}-${c}" ]] || { xpam_update_log "postcheck: ${prefix}-${c} missing"; return 1; }
    bash -n "/usr/local/sbin/${prefix}-${c}" || return 1
  done
  [[ -x /usr/local/sbin/xpam-maint-common.sh ]] || { xpam_update_log "postcheck: xpam-maint-common missing"; return 1; }
  bash -n /usr/local/sbin/xpam-maint-common.sh || return 1

  # Health is judged as a DELTA, never as an absolute. Requiring green here would
  # undo the preflight's whole point: a box red for a reason the update does not
  # touch (an expiring certificate, a disk threshold, an upstream panel change)
  # would download, apply, see the same old red and roll the update straight back.
  # Only failures the update INTRODUCED are grounds for rollback. The structural
  # checks above stay absolute — those really do mean the update broke something.
  local post_dir pre_failures post_failures new_failures
  post_dir="${XPAM_UPDATE_WORKDIR}/post-state"
  mkdir -p "$post_dir"
  local quick_rc=0 deep_rc=0
  "/usr/local/sbin/${prefix}-health" > "$post_dir/health.txt" 2>&1 || quick_rc=$?
  "/usr/local/sbin/${prefix}-health" --deep > "$post_dir/health-deep.txt" 2>&1 || deep_rc=$?
  # An interrupted/failed checker is not an empty set of failures. The result
  # section is emitted only after every deep-health check has finished.
  if ! grep -qx '===== RESULT =====' "$post_dir/health-deep.txt" || \
      [[ "$quick_rc" -gt 1 || "$deep_rc" -gt 1 ]]; then
    xpam_update_log "postcheck: health did not finish normally"
    return 1
  fi
  xpam_update_health_failures "$post_dir/health.txt" "$post_dir/health-deep.txt" \
    > "$post_dir/health-failures.txt"
  if [[ "$quick_rc" -ne 0 || "$deep_rc" -ne 0 ]] && [[ ! -s "$post_dir/health-failures.txt" ]]; then
    xpam_update_log "postcheck: health failed without an actionable failure summary"
    return 1
  fi
  pre_failures="${XPAM_UPDATE_WORKDIR}/pre-state/health-failures.txt"
  [[ -f "$pre_failures" ]] || pre_failures=/dev/null
  post_failures="$post_dir/health-failures.txt"
  new_failures="$(comm -13 "$pre_failures" "$post_failures" 2>/dev/null || true)"
  if [[ -n "$new_failures" ]]; then
    xpam_update_log "postcheck: update introduced new health failures:"
    printf '%s\n' "$new_failures" | while IFS= read -r line; do
      xpam_update_log "postcheck:   ${line}"
    done
    return 1
  fi
  if [[ -s "$post_failures" ]]; then
    xpam_update_log "postcheck: $(wc -l < "$post_failures" | tr -d ' ') pre-existing failure(s) remain; none introduced by this update"
  fi

  xpam_update_compare_link_hashes "$prefix" || { xpam_update_log "postcheck: link hash changed"; return 1; }

  before_mode="$(cat "${XPAM_UPDATE_WORKDIR}/pre-state/doublehop-mode.txt" 2>/dev/null || echo unknown)"
  after_mode="unknown"
  if declare -F dh_detect_mode >/dev/null 2>&1; then
    after_mode="$(dh_detect_mode 2>/dev/null || echo unknown)"
  fi
  printf '%s\n' "$after_mode" > "${XPAM_UPDATE_WORKDIR}/post-state/doublehop-mode.txt"
  if [[ "$before_mode" != "unknown" && "$after_mode" != "$before_mode" ]]; then
    xpam_update_log "postcheck: DoubleHop mode changed: before=$before_mode after=$after_mode"
    return 1
  fi
  return 0
}

xpam_update_success_message(){
  local version remaining=0 post_failures
  version="$(xpam_update_current_version)"
  post_failures="${XPAM_UPDATE_WORKDIR}/post-state/health-failures.txt"
  [[ -s "$post_failures" ]] && remaining="$(wc -l < "$post_failures" | tr -d ' ')"
  echo
  echo "XPAM успешно обновлён."
  echo
  echo "Версия: ${version}"
  # "OK" would be a lie on a box that was already reporting problems: the update
  # is judged on not making things worse, not on curing what it never touched.
  if [[ "${remaining:-0}" -gt 0 ]]; then
    echo "Состояние сервера: обновление ничего не сломало, но ${remaining} проблем(ы) остаются."
    echo "Подробности: sudo ${SERVER_PREFIX:-<prefix>}-health --deep"
  else
    echo "Состояние сервера: OK"
  fi
  echo "Ваши ссылки подключения не изменились."
}

xpam_update_failure_message(){
  local rollback_ok="$1"
  echo
  echo "Обновление не удалось."
  echo
  if [[ "$rollback_ok" == "yes" ]]; then
    echo "XPAM восстановил предыдущую рабочую версию."
    echo "Ваши ссылки подключения не изменились."
  else
    echo "XPAM попытался восстановить предыдущую версию, но проверка сервера не прошла."
    echo "Ваши секреты не были напечатаны в лог."
  fi
  echo
  echo "Лог:"
  echo "  ${XPAM_UPDATE_LOG}"
}

xpam_update_run(){
  need_root
  xpam_update_log_init
  xpam_update_log "update started; current=$(xpam_update_current_version) build=$(xpam_update_current_build)"

  if ! xpam_update_fetch_release_metadata; then
    return 1
  fi
  if ! xpam_update_parse_release_metadata >>"$XPAM_UPDATE_LOG" 2>&1; then
    echo
    echo "Информация об обновлении XPAM неполная или некорректная."
    echo "Изменения не внесены."
    echo
    echo "Лог:"
    echo "  ${XPAM_UPDATE_LOG}"
    return 1
  fi

  if [[ "${XPAM_UPDATE_NO_UPDATE:-0}" == "1" ]]; then
    echo
    echo "Проверка обновлений XPAM..."
    echo
    echo "Текущая версия: $(xpam_update_current_version)"
    echo "Последняя версия в GitHub Release: ${XPAM_UPDATE_LATEST_VERSION:-unknown}"
    echo
    echo "Доступных обновлений не найдено."
    echo
    echo "Изменения не внесены."
    return 0
  fi

  if ! xpam_update_confirm; then
    echo "Обновление отменено. Изменения не внесены."
    return 0
  fi

  if ! xpam_update_preflight_runtime; then
    return 1
  fi

  if ! xpam_update_download_assets; then
    echo
    echo "Не удалось безопасно загрузить обновление XPAM."
    echo "Изменения не внесены."
    echo
    echo "Лог:"
    echo "  ${XPAM_UPDATE_LOG}"
    return 1
  fi
  xpam_update_verify_sha256 || return 1

  if ! xpam_update_extract_staging >>"$XPAM_UPDATE_LOG" 2>&1 || ! xpam_update_static_preflight >>"$XPAM_UPDATE_LOG" 2>&1; then
    echo
    echo "Архив обновления не прошёл предварительную проверку."
    echo
    echo "Обновление остановлено до применения изменений."
    echo "Изменения не внесены."
    echo
    echo "Лог:"
    echo "  ${XPAM_UPDATE_LOG}"
    return 1
  fi

  if ! xpam_update_snapshot_create >>"$XPAM_UPDATE_LOG" 2>&1; then
    warn "Не удалось создать полную резервную копию; обновление не применено"
    return 1
  fi

  if xpam_update_apply && xpam_update_postcheck >>"$XPAM_UPDATE_LOG" 2>&1; then
    xpam_update_log "update successful"
    xpam_update_success_message
    return 0
  fi

  xpam_update_log "update failed after mutation; rollback required"
  if xpam_update_rollback && xpam_update_postcheck >>"$XPAM_UPDATE_LOG" 2>&1; then
    xpam_update_failure_message yes
    return 1
  fi
  xpam_update_failure_message no
  return 1
}

xpam_update_menu(){
  xpam_update_run
}
