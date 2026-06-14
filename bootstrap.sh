#!/usr/bin/env bash
set -euo pipefail

XPAM_VERSION="${XPAM_VERSION:-v1.3.0}"
XPAM_ASSET="${XPAM_ASSET:-xpam-script-${XPAM_VERSION}-ubuntu24-debian12.tar.gz}"
XPAM_INSTALL_DIR="${XPAM_INSTALL_DIR:-/root/xpam-install}"

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "ERROR: this installer must run as root" >&2
    exit 1
fi

if [ -z "${XPAM_REPO:-}" ] && [ -z "${XPAM_RELEASE_BASE_URL:-}" ]; then
    cat >&2 <<'EOF'
ERROR: XPAM_REPO is not set.

Use:
  sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh

Or set:
  XPAM_RELEASE_BASE_URL="https://github.com/deepru/xpam-script/releases/download/v1.2.0"
EOF
    exit 1
fi

if [ -n "${XPAM_RELEASE_BASE_URL:-}" ]; then
    BASE_URL="${XPAM_RELEASE_BASE_URL%/}"
else
    BASE_URL="https://github.com/${XPAM_REPO}/releases/download/${XPAM_VERSION}"
fi

ARCHIVE_URL="${XPAM_ARCHIVE_URL:-${BASE_URL}/${XPAM_ASSET}}"
SHA256_URL="${XPAM_SHA256_URL:-${BASE_URL}/${XPAM_ASSET}.sha256}"

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

if need_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl tar gzip findutils coreutils
fi

for cmd in curl tar gzip find sha256sum; do
    if ! need_cmd "$cmd"; then
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    fi
done

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ARCHIVE_FILE="$TMP_DIR/$XPAM_ASSET"
SHA256_FILE="$TMP_DIR/$XPAM_ASSET.sha256"

echo "==> Downloading XPAM Script ${XPAM_VERSION}"
curl -fL --retry 3 --connect-timeout 15 -o "$ARCHIVE_FILE" "$ARCHIVE_URL"

echo "==> Downloading SHA256"
curl -fL --retry 3 --connect-timeout 15 -o "$SHA256_FILE" "$SHA256_URL"

DIGEST="$(awk '{print $1; exit}' "$SHA256_FILE")"
if ! printf '%s' "$DIGEST" | grep -Eq '^[0-9a-fA-F]{64}$'; then
    echo "ERROR: invalid SHA256 file format" >&2
    exit 1
fi

echo "==> Verifying archive"
printf '%s  %s\n' "$DIGEST" "$ARCHIVE_FILE" | sha256sum -c -

echo "==> Extracting to $XPAM_INSTALL_DIR"
rm -rf "$XPAM_INSTALL_DIR"
mkdir -p "$XPAM_INSTALL_DIR"
tar -xzf "$ARCHIVE_FILE" -C "$XPAM_INSTALL_DIR"

KIT_DIR="$(find "$XPAM_INSTALL_DIR" -maxdepth 3 -type f -name install.sh -printf '%h\n' | head -n1)"
if [ -z "$KIT_DIR" ] || [ ! -f "$KIT_DIR/install.sh" ]; then
    echo "ERROR: install.sh not found in extracted archive" >&2
    exit 1
fi

echo "==> Starting XPAM Script installer"
cd "$KIT_DIR"
exec bash ./install.sh "$@"
