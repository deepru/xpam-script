#!/usr/bin/env bash
#
# make-release.sh — build and verify the XPAM Script release tarball.
#
# Produces  dist/xpam-script-v<VERSION>.tar.gz  (with the MANDATORY top-level
# wrapper dir) plus its .sha256, then runs the exact gates the self-updater
# applies on existing installs. A build that passes here is guaranteed to pass
# self-update staging + static preflight — this is the guard against the
# packaging regression class (missing wrapper dir -> root_count != 1 -> the
# updater rejects the archive).
#
# Usage:
#   ./make-release.sh          build + verify -> dist/
#   ./make-release.sh build [out_dir]
#   ./make-release.sh check    run the verification gates on the repo tree only
#                              (no build) — used by CI on every push.
#
set -euo pipefail

die(){ echo "FAIL: $*" >&2; exit 1; }
info(){ echo ">> $*"; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

# Files the self-updater's static preflight requires to be present (kept in sync
# with xpam_update_static_preflight in scripts/lib/xpam-update.sh).
REQUIRED_FILES=(
  install.sh
  bootstrap.sh
  scripts/xpam-core.sh
  scripts/lib/xpam-launchers.sh
  scripts/lib/xpam-maintenance.sh
  scripts/lib/xpam-update.sh
  templates/health.sh.tpl
  templates/weekly.sh.tpl
  templates/xpam-maint-common.sh.tpl
  VERSION
  RELEASE
)

# verify_tree <root> — assert required files exist and every shell script /
# template is syntactically valid, both raw (as the updater checks) and rendered
# (placeholders substituted). Used on the repo tree (check) and on the extracted
# tarball (build), so the two can never drift.
verify_tree(){
  local root="$1" fail=0 f
  [[ -d "$root" ]] || die "verify_tree: not a directory: $root"

  for f in "${REQUIRED_FILES[@]}"; do
    [[ -f "$root/$f" ]] || die "required file missing: $f"
  done

  # Raw bash -n on install/bootstrap, every scripts/**/*.sh and every *.sh.tpl
  # (mirrors the updater's static preflight exactly).
  bash -n "$root/install.sh"   || fail=1
  bash -n "$root/bootstrap.sh" || fail=1
  while IFS= read -r -d '' f; do bash -n "$f" || { echo "  bash -n FAIL: $f"; fail=1; }; done \
    < <(find "$root/scripts" -type f -name '*.sh' -print0)
  while IFS= read -r -d '' f; do bash -n "$f" || { echo "  bash -n FAIL: $f"; fail=1; }; done \
    < <(find "$root/templates" -type f -name '*.sh.tpl' -print0)
  [[ "$fail" -eq 0 ]] || die "bash -n syntax errors (see above)"

  # Render-smoke: substitute {{TOKENS}} and re-check the templates, so a token
  # placed in a syntax-sensitive spot is caught before it ships.
  while IFS= read -r -d '' f; do
    bash -n <(sed -E 's/\{\{[A-Za-z0-9_]+\}\}/x/g' "$f") || { echo "  render-smoke FAIL: $f"; fail=1; }
  done < <(find "$root/templates" -type f -name '*.sh.tpl' -print0)
  [[ "$fail" -eq 0 ]] || die "render-smoke syntax errors (see above)"

  info "verify_tree OK: $root"
}

cmd="${1:-build}"

if [[ "$cmd" == "check" ]]; then
  verify_tree "$repo_root"
  echo "OK: check-only gates passed (required files + bash -n + render-smoke)"
  exit 0
fi
[[ "$cmd" == "build" ]] || die "unknown command: $cmd (use: build | check)"

# ---- build ----
VERSION="$(tr -d ' \t\r\n' < VERSION)"
[[ -n "$VERSION" ]] || die "VERSION file is empty"
rel_ver="$(awk -F= '$1=="XPAM_VERSION"{gsub(/[ \t\r]/,"",$2); print $2}' RELEASE)"
[[ "$rel_ver" == "$VERSION" ]] || die "VERSION ($VERSION) != RELEASE XPAM_VERSION ($rel_ver) — bump both before release"

prefix="xpam-script-v${VERSION}"
out_dir="${2:-dist}"
mkdir -p "$out_dir"
tarball="${out_dir}/${prefix}.tar.gz"

if ! git diff --quiet || ! git diff --cached --quiet; then
  info "note: working tree has uncommitted changes — they WILL be included (working-tree build)"
fi

# Archive the WORKING TREE (tracked files, current on-disk content) under the
# wrapper prefix. git stash create yields a tree object for the working tree
# without touching the stash list; falls back to HEAD when the tree is clean.
tree="$(git stash create 2>/dev/null || true)"
[[ -n "$tree" ]] || tree="HEAD"
git archive --format=tar.gz --prefix="${prefix}/" -o "$tarball" "$tree"
( cd "$out_dir" && sha256sum "${prefix}.tar.gz" > "${prefix}.tar.gz.sha256" )
info "built: $tarball"

# ---- verify the built artifact exactly as the self-updater will ----
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
tar -xzf "$tarball" -C "$work"

root_count="$(find "$work" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$root_count" -eq 1 ]] || die "root_count=$root_count — self-update staging requires exactly 1 top-level dir (the wrapper)"
[[ -d "$work/$prefix" ]] || die "wrapper dir '$prefix' not found inside the tarball"

verify_tree "$work/$prefix"
( cd "$out_dir" && sha256sum -c "${prefix}.tar.gz.sha256" >/dev/null ) || die "sha256 self-check failed"

echo
echo "OK: release verified — $tarball"
echo "    root_count=1, required files present, bash -n + render-smoke clean, sha256 OK"
echo "    sha256: $(awk '{print $1}' "${out_dir}/${prefix}.tar.gz.sha256")"
