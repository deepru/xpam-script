#!/usr/bin/env bash
set -Eeuo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/xpam-core.sh
source "$KIT_DIR/scripts/xpam-core.sh"

# Keep live terminal output and a root log, but wait for tee before returning to
# the interactive shell. This avoids confusing prompt/output interleaving on
# slow terminals after long install stages.
exec 3>&1 4>&2
LOG_PIPE="$(mktemp -u /tmp/xpam-script-log.XXXXXX)"
mkfifo "$LOG_PIPE"
tee -a "$LOG" < "$LOG_PIPE" &
TEE_PID=$!
exec > "$LOG_PIPE" 2>&1
rm -f "$LOG_PIPE"

set +e
main_menu "$@"
RC=$?
set -e

exec 1>&3 2>&4
exec 3>&- 4>&-
wait "$TEE_PID" 2>/dev/null || true
exit "$RC"
