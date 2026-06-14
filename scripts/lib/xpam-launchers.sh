#!/usr/bin/env bash
# XPAM Script module. This file is sourced by scripts/xpam-core.sh.
# Keep functions side-effect free at source time.

write_install_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0

  local safe_prefix launcher bin_link old_sbin old_bin kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"

  [[ -n "$safe_prefix" ]] || fail "SERVER_PREFIX is empty; cannot create XPAM launcher"
  [[ "$safe_prefix" == "$SERVER_PREFIX" ]] || fail "SERVER_PREFIX contains unsupported chars for launcher command: $SERVER_PREFIX"

  launcher="/usr/local/sbin/${safe_prefix}-xpam"
  bin_link="/usr/local/bin/${safe_prefix}-xpam"
  old_sbin="/usr/local/sbin/${safe_prefix}-install"
  old_bin="/usr/local/bin/${safe_prefix}-install"
  kit_dir_real="$RUNTIME_KIT_DIR"

  cat > "$launcher" <<EOF_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

LAUNCHER="/usr/local/sbin/${safe_prefix}-xpam"
KIT_DIR="${kit_dir_real}"

if [ "\$(id -u)" -ne 0 ]; then
  exec sudo "\$LAUNCHER" "\$@"
fi

if [ ! -f "\$KIT_DIR/install.sh" ]; then
  echo "ERROR: XPAM Script runtime is missing: \$KIT_DIR/install.sh" >&2
  echo "Re-upload the XPAM Script archive or restore /opt/xpam-script." >&2
  exit 1
fi

cd "\$KIT_DIR"
exec bash ./install.sh "\$@"
EOF_LAUNCHER

  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true

  # v1.3.5 has no legacy compatibility alias/wrapper for -install.
  rm -f "$old_sbin" "$old_bin" 2>/dev/null || true

  ok "Команда управления создана: sudo ${safe_prefix}-xpam"
}



write_health_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0
  local safe_prefix health bin_link
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"
  [[ -n "$safe_prefix" && "$safe_prefix" == "$SERVER_PREFIX" ]] || return 0
  health="/usr/local/sbin/${safe_prefix}-health"
  bin_link="/usr/local/bin/${safe_prefix}-health"
  if [[ -x "$health" ]]; then
    ln -sf "$health" "$bin_link" 2>/dev/null || true
    ok "Health command available: sudo ${safe_prefix}-health"
  fi
}




write_repair_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0
  local safe_prefix launcher bin_link kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"
  launcher="/usr/local/sbin/${safe_prefix}-repair"
  bin_link="/usr/local/bin/${safe_prefix}-repair"
  kit_dir_real="$RUNTIME_KIT_DIR"
  cat > "$launcher" <<EOF_REPAIR_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
LAUNCHER="/usr/local/sbin/${safe_prefix}-repair"
KIT_DIR="${kit_dir_real}"
if [ "\$(id -u)" -ne 0 ]; then exec sudo "\$LAUNCHER" "\$@"; fi
if [ ! -f "\$KIT_DIR/scripts/xpam-core.sh" ]; then
  echo "ERROR: XPAM Script runtime missing: \$KIT_DIR/scripts/xpam-core.sh" >&2
  exit 1
fi
export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
# shellcheck source=/dev/null
source "\$KIT_DIR/scripts/xpam-core.sh"
stage_repair
EOF_REPAIR_LAUNCHER
  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true
  ok "Repair-команда доступна: sudo ${safe_prefix}-repair"
}


write_netdiag_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0
  local safe_prefix launcher bin_link kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"
  launcher="/usr/local/sbin/${safe_prefix}-netdiag"
  bin_link="/usr/local/bin/${safe_prefix}-netdiag"
  kit_dir_real="$RUNTIME_KIT_DIR"
  cat > "$launcher" <<EOF_NETDIAG_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
LAUNCHER="/usr/local/sbin/${safe_prefix}-netdiag"
KIT_DIR="${kit_dir_real}"
if [ "\$(id -u)" -ne 0 ]; then exec sudo "\$LAUNCHER" "\$@"; fi
if [ ! -f "\$KIT_DIR/scripts/xpam-core.sh" ]; then
  echo "ERROR: XPAM Script runtime missing: \$KIT_DIR/scripts/xpam-core.sh" >&2
  exit 1
fi
export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
# shellcheck source=/dev/null
source "\$KIT_DIR/scripts/xpam-core.sh"
stage_netdiag
EOF_NETDIAG_LAUNCHER
  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true
  ok "Диагностика сети доступна: sudo ${safe_prefix}-netdiag"
}


write_weekly_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0
  local safe_prefix weekly bin_link
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"
  [[ -n "$safe_prefix" && "$safe_prefix" == "$SERVER_PREFIX" ]] || return 0
  weekly="/usr/local/sbin/${safe_prefix}-weekly-maintenance.sh"
  bin_link="/usr/local/bin/${safe_prefix}-weekly-maintenance"
  if [[ -x "$weekly" ]]; then
    ln -sf "$weekly" "$bin_link" 2>/dev/null || true
    ok "Weekly maintenance is configured for automatic weekly run"
  fi
}


write_links_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0

  local safe_prefix launcher bin_link kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"

  [[ -n "$safe_prefix" ]] || fail "SERVER_PREFIX is empty; cannot create links launcher"
  [[ "$safe_prefix" == "$SERVER_PREFIX" ]] || fail "SERVER_PREFIX contains unsupported chars for launcher command: $SERVER_PREFIX"

  launcher="/usr/local/sbin/${safe_prefix}-links"
  bin_link="/usr/local/bin/${safe_prefix}-links"
  kit_dir_real="$RUNTIME_KIT_DIR"

  cat > "$launcher" <<EOF_LINKS_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

LAUNCHER="/usr/local/sbin/${safe_prefix}-links"
KIT_DIR="${kit_dir_real}"

if [ "\$(id -u)" -ne 0 ]; then
  exec sudo "\$LAUNCHER" "\$@"
fi

if [ ! -f "\$KIT_DIR/scripts/xpam-core.sh" ]; then
  echo "ERROR: XPAM Script runtime is missing: \$KIT_DIR/scripts/xpam-core.sh" >&2
  echo "Re-upload the XPAM Script archive or restore /opt/xpam-script." >&2
  exit 1
fi

export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
# shellcheck source=/dev/null
source "\$KIT_DIR/scripts/xpam-core.sh"
stage_links_direct "\$@"
EOF_LINKS_LAUNCHER

  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true

  ok "Connection data command available: sudo ${safe_prefix}-links"
}


write_tg_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0

  local safe_prefix launcher bin_link kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"

  [[ -n "$safe_prefix" ]] || fail "SERVER_PREFIX is empty; cannot create tg launcher"
  [[ "$safe_prefix" == "$SERVER_PREFIX" ]] || fail "SERVER_PREFIX contains unsupported chars for launcher command: $SERVER_PREFIX"

  launcher="/usr/local/sbin/${safe_prefix}-tg"
  bin_link="/usr/local/bin/${safe_prefix}-tg"

  if ! uses_mtproto || ! mtproto_backend_is_alexbers; then
    rm -f "$launcher" "$bin_link" 2>/dev/null || true
    ok "Telegram uses ${safe_prefix}-links; old ${safe_prefix}-tg launcher removed for backend: $(mtproto_backend_effective)"
    return 0
  fi

  kit_dir_real="$RUNTIME_KIT_DIR"

  cat > "$launcher" <<EOF_TG_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

LAUNCHER="/usr/local/sbin/${safe_prefix}-tg"
KIT_DIR="${kit_dir_real}"

if [ "\$(id -u)" -ne 0 ]; then
  exec sudo "\$LAUNCHER" "\$@"
fi

if [ ! -f "\$KIT_DIR/scripts/xpam-core.sh" ]; then
  echo "ERROR: XPAM Script runtime is missing: \$KIT_DIR/scripts/xpam-core.sh" >&2
  echo "Re-upload the XPAM Script archive or restore /opt/xpam-script." >&2
  exit 1
fi

export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
# shellcheck source=/dev/null
source "\$KIT_DIR/scripts/xpam-core.sh"
stage_tg_direct "\$@"
EOF_TG_LAUNCHER

  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true

  [[ -x "$launcher" ]] || fail "MTProto launcher was not created: $launcher"
  [[ -x "$bin_link" ]] || fail "MTProto launcher symlink was not created or is not executable: $bin_link"

  ok "Legacy alexbers MTProto users command available: sudo ${safe_prefix}-tg"
}


write_vless_launcher(){
  [[ -n "${SERVER_PREFIX:-}" ]] || return 0

  local safe_prefix launcher bin_link kit_dir_real
  safe_prefix="$(printf '%s' "$SERVER_PREFIX" | tr -cd 'A-Za-z0-9_-')"

  [[ -n "$safe_prefix" ]] || fail "SERVER_PREFIX is empty; cannot create vless launcher"
  [[ "$safe_prefix" == "$SERVER_PREFIX" ]] || fail "SERVER_PREFIX contains unsupported chars for launcher command: $SERVER_PREFIX"

  launcher="/usr/local/sbin/${safe_prefix}-vless"
  bin_link="/usr/local/bin/${safe_prefix}-vless"
  kit_dir_real="$RUNTIME_KIT_DIR"

  cat > "$launcher" <<EOF_VLESS_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

LAUNCHER="/usr/local/sbin/${safe_prefix}-vless"
KIT_DIR="${kit_dir_real}"

if [ "\$(id -u)" -ne 0 ]; then
  exec sudo "\$LAUNCHER" "\$@"
fi

if [ ! -f "\$KIT_DIR/scripts/xpam-core.sh" ]; then
  echo "ERROR: XPAM Script runtime is missing: \$KIT_DIR/scripts/xpam-core.sh" >&2
  echo "Re-upload the XPAM Script archive or restore /opt/xpam-script." >&2
  exit 1
fi

export XPAM_SCRIPT_QUIET_LOAD_CONFIG=1
# shellcheck source=/dev/null
source "\$KIT_DIR/scripts/xpam-core.sh"
stage_vless_direct "\$@"
EOF_VLESS_LAUNCHER

  chmod 755 "$launcher"
  ln -sf "$launcher" "$bin_link" 2>/dev/null || true

  ok "VLESS links command available: sudo ${safe_prefix}-vless"
}


