#!/usr/bin/env bash
set -Eeuo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/xpam-core.sh
source "$KIT_DIR/scripts/xpam-core.sh"

# Keep live terminal output and an install log. All output is routed through tee,
# including early exits from sourced functions. The EXIT trap restores stdout
# and waits for tee before the interactive shell prompt returns; otherwise the
# user can see leftover separator lines after the prompt on slow terminals.
mkdir -p "$(dirname "$LOG")"
chmod 700 "$(dirname "$LOG")" 2>/dev/null || true
exec 3>&1 4>&2
LOG_PIPE="$(mktemp -u /tmp/xpam-script-log.XXXXXX)"
mkfifo "$LOG_PIPE"
tee -a "$LOG" < "$LOG_PIPE" &
TEE_PID=$!
exec > "$LOG_PIPE" 2>&1
rm -f "$LOG_PIPE"

xpam_install_cleanup(){
  local rc=$?
  trap - EXIT
  set +e
  exec 1>&3 2>&4
  exec 3>&- 4>&-
  wait "$TEE_PID" 2>/dev/null || true
  exit "$rc"
}
trap xpam_install_cleanup EXIT

main_menu "$@"
exit $?
