#!/usr/bin/env bash
set -u

HOST="${1:?host required}"
PORT="${2:?port required}"
TIMEOUT_SECONDS="${3:-30}"
LABEL="${4:-${HOST}:${PORT}}"

for i in $(seq 1 "$TIMEOUT_SECONDS"); do
    if timeout 1 bash -c "</dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
        exit 0
    fi
    sleep 1
done

echo "ERROR: ${LABEL} (${HOST}:${PORT}) is not reachable after ${TIMEOUT_SECONDS}s" >&2
exit 1
