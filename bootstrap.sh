#!/usr/bin/env bash
set -euo pipefail

XPAM_VERSION="${XPAM_VERSION:-v1.3.7}"
XPAM_ASSET="${XPAM_ASSET:-xpam-script-${XPAM_VERSION}.tar.gz}"
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
  XPAM_RELEASE_BASE_URL="https://github.com/deepru/xpam-script/releases/download/v1.3.7"
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


XPAM_GITHUB_CDN_IPS=(185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133)

xpam_download_with_github_cdn_fallback() {
    local url="$1" out="$2" label="${3:-file}" max_time="${4:-300}" ip
    rm -f "$out"
    if curl --http1.1 -fL --retry 5 --retry-delay 2 --retry-all-errors \
        --connect-timeout 20 --max-time "$max_time" -o "$out" "$url"; then
        return 0
    fi

    case "$url" in
        *github.com/*|*githubusercontent.com/*) ;;
        *) return 1 ;;
    esac

    echo "WARN: normal GitHub download failed for ${label}; trying temporary CDN edge fallback" >&2
    for ip in "${XPAM_GITHUB_CDN_IPS[@]}"; do
        rm -f "$out"
        echo "==> Trying GitHub CDN edge ${ip} for ${label}" >&2
        if curl --http1.1 -fL --retry 1 --retry-delay 1 --retry-all-errors \
            --connect-timeout 15 --max-time "$max_time" \
            --resolve "release-assets.githubusercontent.com:443:${ip}" \
            --resolve "raw.githubusercontent.com:443:${ip}" \
            --resolve "objects.githubusercontent.com:443:${ip}" \
            -o "$out" "$url"; then
            return 0
        fi
    done
    rm -f "$out"
    return 1
}

xpam_bootstrap_apt_auto_guard() {
    # Fresh cloud images often start apt-daily / unattended-upgrades during
    # first boot.  Do not race them and do not let them start again while XPAM
    # is installing.  If dpkg is already configuring packages, wait for it to
    # finish instead of killing it.
    local locks holder_seen waited max_wait units_after_wait
    locks="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock"
    max_wait="${XPAM_APT_LOCK_MAX_WAIT:-1800}"

    if command -v systemctl >/dev/null 2>&1; then
        for unit in apt-daily.timer apt-daily-upgrade.timer; do
            systemctl disable --now "$unit" >/dev/null 2>&1 || true
            systemctl mask "$unit" >/dev/null 2>&1 || true
        done
        # Mask services now so they cannot be triggered again; if one is
        # currently running with dpkg locks, wait below before stopping it.
        for unit in apt-daily.service apt-daily-upgrade.service unattended-upgrades.service; do
            systemctl disable "$unit" >/dev/null 2>&1 || true
            systemctl mask "$unit" >/dev/null 2>&1 || true
        done
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if command -v fuser >/dev/null 2>&1; then
        waited=0
        while fuser $locks >/dev/null 2>&1; do
            if [ "$waited" -eq 0 ]; then
                echo "==> Waiting for existing apt/dpkg operation to finish"
                fuser -v $locks 2>/dev/null || true
            fi
            if [ "$waited" -ge "$max_wait" ]; then
                echo "ERROR: apt/dpkg locks are still held after ${max_wait}s" >&2
                fuser -v $locks 2>/dev/null || true
                exit 1
            fi
            sleep 5
            waited=$((waited + 5))
            if [ $((waited % 30)) -eq 0 ]; then
                echo "==> Still waiting for apt/dpkg locks... ${waited}s"
                fuser -v $locks 2>/dev/null || true
            fi
        done
    fi

    if command -v systemctl >/dev/null 2>&1; then
        for unit in apt-daily.service apt-daily-upgrade.service unattended-upgrades.service; do
            systemctl stop "$unit" >/dev/null 2>&1 || true
            systemctl disable "$unit" >/dev/null 2>&1 || true
            systemctl mask "$unit" >/dev/null 2>&1 || true
        done
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if command -v dpkg >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
    fi
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=180 -f install -y || true
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

if need_cmd apt-get; then
    xpam_bootstrap_apt_auto_guard
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
xpam_download_with_github_cdn_fallback "$ARCHIVE_URL" "$ARCHIVE_FILE" "XPAM archive" 300

echo "==> Downloading SHA256"
xpam_download_with_github_cdn_fallback "$SHA256_URL" "$SHA256_FILE" "XPAM SHA256" 120

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
