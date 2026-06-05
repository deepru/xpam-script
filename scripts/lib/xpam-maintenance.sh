#!/usr/bin/env bash
# XPAM Script module. This file is sourced by scripts/xpam-core.sh.
# Keep functions side-effect free at source time.

prune_keep_latest(){
  local dir="$1" pattern="$2" keep="${3:-4}" old_path
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk -v keep="$keep" 'NR>keep {sub(/^[^ ]+ /,""); print}' \
    | while IFS= read -r old_path; do
        [[ -n "$old_path" ]] && rm -rf -- "$old_path" 2>/dev/null || true
      done
}


run_health_quiet(){
  local label="${1:-health-check}" ts log_dir log rc
  [[ -n "${SERVER_PREFIX:-}" ]] || fail "SERVER_PREFIX is not loaded; cannot run health"
  if [[ ! -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]]; then
    fail "Health command not found: /usr/local/sbin/${SERVER_PREFIX}-health"
  fi

  ts="$(date +%Y%m%d-%H%M%S)"
  label="$(printf '%s' "$label" | tr -cd 'A-Za-z0-9_.-')"
  [[ -n "$label" ]] || label="health-check"
  log_dir="/var/log/xpam-script"
  mkdir -p "$log_dir"
  chmod 700 "$log_dir" 2>/dev/null || true
  log="${log_dir}/${SERVER_PREFIX}-${label}-${ts}.log"

  if "/usr/local/sbin/${SERVER_PREFIX}-health" >"$log" 2>&1; then
    prune_keep_latest "$log_dir" "${SERVER_PREFIX}-*.log" 4
    ok "Краткая health-проверка пройдена. Подробный лог: $log"
    return 0
  fi

  rc=$?
  prune_keep_latest "$log_dir" "${SERVER_PREFIX}-*.log" 4
  warn "Health-check завершился ошибкой. Подробный лог: $log"
  echo "Последние строки health-лога:"
  tail -n 80 "$log" 2>/dev/null || true
  return "$rc"
}

apply_service_hygiene(){
  say "Applying post-install service hygiene and cleanup policy"
  write_common_library
  bash -c '. /usr/local/sbin/xpam-maint-common.sh; xpam_apply_service_hygiene "'"$CONFIG_FILE"'"'
}


post_install_cleanup(){
  say "Running post-install safe cleanup"
  write_common_library
  bash -c '. /usr/local/sbin/xpam-maint-common.sh; xpam_post_install_cleanup "'"$SERVER_PREFIX"'"'
}


cleanup_root_test_leftovers(){
  # Keep /root clean after successful stage transitions. This helper removes
  # only upload/test/debug leftovers and empty tool caches; it never touches
  # user secrets, SSH keys, config snapshots or rollback backups.
  local mode="${1:-safe}"
  shopt -s nullglob

  rm -f /root/*-health-*.txt /root/*-health-debian-*.txt 2>/dev/null || true
  rm -f /root/xpam-script-v*-*.log /root/xpam-script-*.log 2>/dev/null || true
  rm -f /root/.Xauthority /root/.lesshst 2>/dev/null || true
  rm -rf /root/xpam-install /root/xpam-release-build /root/xpam-script-test-* 2>/dev/null || true
  rm -rf /tmp/xpam-* /tmp/xpam-script-* /var/tmp/xpam-* /var/tmp/xpam-script-* 2>/dev/null || true
  rm -f /tmp/service-audit-*.txt /tmp/tls-cert.* /tmp/tls-info.* 2>/dev/null || true

  if [[ "$mode" == "stage1" || "$mode" == "final" ]]; then
    rm -f /root/xpam-script-v*.tar.gz /root/xpam-script-v*.tgz /root/xpam-script-v*.zip 2>/dev/null || true
    rm -f /root/xpam-script-v*.tar.gz.sha256 /root/xpam-script-v*.tgz.sha256 /root/xpam-script-v*.sha256 2>/dev/null || true
  fi

  # Remove empty helper/cache directory trees only when they contain no files.
  for xpam_empty_cache_dir in /root/.ansible /root/.local; do
    if [[ -d "$xpam_empty_cache_dir" ]]; then
      find "$xpam_empty_cache_dir" -depth -type d -empty -delete 2>/dev/null || true
      rmdir "$xpam_empty_cache_dir" 2>/dev/null || true
    fi
  done
  shopt -u nullglob
}


final_production_cleanup(){
  need_root
  ensure_sudo_hostname_resolution
  load_config
  validate_inputs
  say "Final production cleanup / polish"

  local original_workdir item target deferred_cleanup_script
  local -a deferred_workdirs
  original_workdir="$(pwd -P 2>/dev/null || true)"
  deferred_workdirs=()

  install_runtime_kit || true
  write_install_launcher || true
  write_health_launcher || true
  write_weekly_launcher || true
  write_links_launcher || true
  write_vless_launcher || true
  write_tg_launcher || true
  write_repair_launcher || true
  write_netdiag_launcher || true
  write_health_weekly || true

  post_install_cleanup || true

  # Final cleanup may remove the extracted XPAM Script directory.  A child shell
  # cannot move the user's parent SSH shell out of that directory.  Therefore we
  # move this script process to /root for safe health checks, and if any running
  # process still has cwd inside /root/xpam-script-v*, we schedule that
  # extracted directory for delayed removal after the user leaves it.
  cd /root 2>/dev/null || cd / 2>/dev/null || true

  has_process_cwd_inside_target(){
    local check_target="$1" cwd cur
    for cwd in /proc/[0-9]*/cwd; do
      cur="$(readlink -f "$cwd" 2>/dev/null || true)"
      [[ -n "$cur" ]] || continue
      if [[ "$cur" == "$check_target" || "$cur" == "$check_target"/* ]]; then
        return 0
      fi
    done
    return 1
  }

  say "Removing XPAM Script upload/test leftovers"
  shopt -s nullglob
  for item in \
    /root/xpam-bootstrap.sh \
    /root/xpam-install \
    /root/xpam-release-build \
    /root/xpam-script-*.tar.gz \
    /root/xpam-script-*.tgz \
    /root/xpam-script-*.zip \
    /root/xpam-script-*.sha256 \
    /root/xpam-script*.sha256 \
    /root/xpam-script*.tar.gz.sha256 \
    /root/xpam-script*.tgz.sha256 \
    /root/xpam-script-v*-*.log \
    /root/xpam-script-*.log \
    /root/xpam-script-test-* \
    /root/xpam-script-v*; do
    [[ -e "$item" ]] || continue
    target="$(readlink -f "$item" 2>/dev/null || true)"
    if [[ -d "$target" && ( "$target" == /root/xpam-script-v* || "$target" == /root/xpam-install || "$target" == /root/xpam-release-build ) ]]; then
      # Do not remove extracted XPAM Script/bootstrap/build directories synchronously.
      # The user's parent SSH shell may still be standing inside one of them,
      # and a child script cannot move that parent shell. Always schedule
      # delayed removal: if nobody is inside, it disappears within a few seconds;
      # if somebody is inside, it disappears after they leave.
      deferred_workdirs+=("$target")
      continue
    fi
    rm -rf -- "$item" 2>/dev/null || true
  done
  shopt -u nullglob
  rm -f /root/.lesshst 2>/dev/null || true

  say "Removing temporary installation/debug files"
  find /tmp -maxdepth 1 \( \
    -name 'xpam-script-*' -o \
    -name '3x-ui-install.*.sh' -o \
    -name '*.out' -o \
    -name '*.err' \
  \) -exec rm -rf {} + 2>/dev/null || true


  say "Removing unused default nginx webroot"
  rm -rf /var/www/html 2>/dev/null || true

  for target in "${deferred_workdirs[@]:-}"; do
    [[ -n "$target" && -d "$target" ]] || continue
    deferred_cleanup_script="/tmp/xpam-script-deferred-cleanup-${SERVER_PREFIX}-$$-$(basename "$target").sh"
    cat >"$deferred_cleanup_script" <<'EOS'
#!/usr/bin/env bash
set -u
target="${1:-}"
[[ -n "$target" ]] || exit 0
case "$target" in
  /root/xpam-script-v*|/root/xpam-install|/root/xpam-release-build) ;;
  *) exit 0 ;;
esac
[[ -d "$target" ]] || exit 0

has_process_cwd_inside_target(){
  local cwd cur
  for cwd in /proc/[0-9]*/cwd; do
    cur="$(readlink -f "$cwd" 2>/dev/null || true)"
    [[ -n "$cur" ]] || continue
    if [[ "$cur" == "$target" || "$cur" == "$target"/* ]]; then
      return 0
    fi
  done
  return 1
}
for _ in $(seq 1 1800); do
  if ! has_process_cwd_inside_target; then
    rm -rf -- "$target" 2>/dev/null || true
    rm -f -- "$0" 2>/dev/null || true
    exit 0
  fi
  sleep 1
done
exit 0
EOS
    chmod 700 "$deferred_cleanup_script" 2>/dev/null || true
    nohup bash "$deferred_cleanup_script" "$target" >/dev/null 2>&1 &
  done

  say "Cleaning old logs and backups by retention policy"
  mkdir -p /var/log/xpam-script /var/log/xpam-script/netdiag
  chmod 700 /var/log/xpam-script /var/log/xpam-script/netdiag 2>/dev/null || true
  prune_keep_latest /var/log/xpam-script "${SERVER_PREFIX}-health-*.log" "${XPAM_HEALTH_LOG_KEEP:-4}" || true
  prune_keep_latest /var/log/xpam-script/netdiag "${SERVER_PREFIX}-*.txt" 2 || true
  rm -rf /root/manual-backups/health-logs /root/manual-backups/networking-diagnostics 2>/dev/null || true
  prune_keep_latest /root/manual-backups/xui-warp-normalize 'x-ui.db.*' "${XPAM_BACKUP_KEEP:-2}" || true
  prune_keep_latest /root/manual-backups/xui-subscription-disable 'x-ui.db.*' "${XPAM_BACKUP_KEEP:-2}" || true
  prune_keep_latest /root/manual-backups 'mtproto-config.py.*' "${XPAM_BACKUP_KEEP:-2}" || true
  find /root/manual-backups -type d -empty -delete 2>/dev/null || true
  find /root/manual-backups -mindepth 1 -maxdepth 2 -type f \( -name '*.bak-*' -o -name '*.tmp' -o -name '*.out' -o -name '*.err' \) -delete 2>/dev/null || true
  find /usr/local/sbin /etc/nginx /etc/haproxy /etc/systemd/system -xdev -type f \
    \( -name '*.bak-*' -o -name '*.bak-before-*' -o -name '*.bak-xpam-script-*' \) \
    -delete 2>/dev/null || true

  say "Cleaning apt caches and trimming journals"
  apt-get clean || true
  rm -rf /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/* 2>/dev/null || true
  journalctl --vacuum-size=24M >/dev/null 2>&1 || true

  cleanup_root_test_leftovers final || true

  say "Final cleanup footprint"
  du -sh /root /tmp /var/cache/apt /var/log /opt /usr/local/sbin 2>/dev/null || true

  cd /root 2>/dev/null || cd / 2>/dev/null || true
  if [[ -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]]; then
    "/usr/local/sbin/${SERVER_PREFIX}-health" || fail "Health failed after final cleanup"
  fi
  if ((${#deferred_workdirs[@]} > 0)); then
    echo
    ok "Финальная очистка завершена. Сервер здоров."
    echo
    echo "Выполните сейчас:"
    echo "  cd /root"
    echo
    echo "Временная папка установки будет удалена автоматически через несколько секунд после выхода из неё."
    echo "Перезагрузка не требуется."
  else
    ok "Final production cleanup complete. Server is clean and manageable."
  fi

  # Production cleanup should leave /root free of install logs as well.
  # If this script is currently being logged through tee, removing the path is
  # safe: the open descriptor can finish, but the root filesystem stays clean.
  rm -f /root/xpam-script-v*-*.log /root/xpam-script-*.log 2>/dev/null || true
}
