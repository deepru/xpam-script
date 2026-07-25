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
  # Masking depends on these at install/repair time; without them the decoy cannot be rendered.
  sites/_mask/generate.py
  sites/_mask/presets.json
  sites/_mask/themes/_layout.css
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

  # The "3-list gotcha": every config var must appear in THREE separate lists in xpam-core.sh — the
  # import loop, save_config and export_vars. They sit on different lines with different indentation,
  # so a careless edit updates only some of them and the var ends up loaded/exported but never
  # persisted — silently lost on the next repair. Compare the three lists as sets.
  local core="$root/scripts/xpam-core.sh" cl1 cl2 cl3
  if [[ -f "$core" ]]; then
    cl1="$(grep -oE 'for v in PROFILE [A-Z0-9_ ]+' "$core" | sed -n '1p' | sed 's/^for v in //' | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
    cl2="$(grep -oE 'for v in PROFILE [A-Z0-9_ ]+' "$core" | sed -n '2p' | sed 's/^for v in //' | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
    cl3="$(grep -oE 'export PROFILE [A-Z0-9_ ]+'   "$core" | sed -n '1p' | sed 's/^export //'   | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
    [[ -n "$cl1" && -n "$cl2" && -n "$cl3" ]] \
      || die "3-list gate: could not locate the config-var lists in scripts/xpam-core.sh"
    [[ "$cl1" == "$cl2" ]] || die "3-list gotcha: import-loop and save_config config-var lists differ"
    [[ "$cl1" == "$cl3" ]] || die "3-list gotcha: import-loop and export_vars config-var lists differ"
  fi

  # Every archetype the decoy generator can pick MUST have its theme file. generate.py deliberately
  # falls back to clean.css when one is missing, so a deleted/renamed theme would NOT crash — it
  # would silently render the wrong design on some domains. Fail loudly here instead.
  local gen="$root/sites/_mask/generate.py" arch
  if [[ -f "$gen" ]]; then
    for arch in $(sed -n '/^ARCHES = \[/,/\]/p' "$gen" | grep -oE '"[a-z0-9_-]+"' | tr -d '"'); do
      [[ -f "$root/sites/_mask/themes/${arch}.css" ]] \
        || die "decoy archetype '${arch}' is listed in generate.py but sites/_mask/themes/${arch}.css is missing"
    done
  fi

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

# ---- release vs dev build -------------------------------------------------------------------
# A branch build used to be named exactly like the published asset (VERSION only bumps at release
# time), so `dist/xpam-script-v1.3.9.tar.gz` could be either the real release or a work-in-progress
# build of the next version. That ambiguity once put an unreleased kit on a production box.
# Now only a build that provably matches a release tag gets the release name; everything else is
# marked as a dev build, in its own directory, and carries the commit in its filename.
head_sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
dirty=no
if ! git diff --quiet || ! git diff --cached --quiet; then dirty=yes; fi
head_tag="$(git describe --exact-match --tags HEAD 2>/dev/null || true)"

build_kind=dev
if [[ "$dirty" == "no" && "$head_tag" == "v${VERSION}" ]]; then
  build_kind=release
elif [[ "${XPAM_FORCE_RELEASE_BUILD:-}" == "1" ]]; then
  # Escape hatch for the documented flow, which builds the artifact BEFORE tagging.
  build_kind=release
  info "XPAM_FORCE_RELEASE_BUILD=1 — release naming forced (HEAD is not tagged v${VERSION})"
fi

if [[ "$build_kind" == "release" ]]; then
  prefix="xpam-script-v${VERSION}"
  default_out=dist
else
  # e.g. xpam-script-v1.3.9+dev.7175e18ab12c.dirty
  prefix="xpam-script-v${VERSION}+dev.${head_sha}"
  [[ "$dirty" == "yes" ]] && prefix="${prefix}.dirty"
  default_out=build
fi

out_dir="${2:-$default_out}"
mkdir -p "$out_dir"
tarball="${out_dir}/${prefix}.tar.gz"

if [[ "$dirty" == "yes" ]]; then
  info "note: working tree has uncommitted changes — they WILL be included (working-tree build)"
fi
if [[ "$build_kind" == "dev" ]]; then
  info "DEV build (HEAD=${head_sha}, dirty=${dirty}) — NOT a release; never deploy this to a live box"
else
  info "RELEASE build (tag ${head_tag:-forced}, HEAD=${head_sha})"
fi

# BUILD_INFO travels inside the kit, so `cat /opt/xpam-script/BUILD_INFO` on any box answers
# "what exactly is installed here". It carries no timestamp on purpose, so that a RELEASE build
# (clean tree) stays byte-reproducible: rebuilding the same tag must yield the same sha256, which
# is what makes the published asset verifiable. (A dirty dev build cannot be reproducible either
# way — `git stash create` mints a fresh commit each time and git archive takes file mtimes from
# the commit date; the tree, and therefore the content, is still identical.)
# The temp file must literally be named BUILD_INFO: `git archive --add-file` names the archive
# entry after the source file's basename. Renaming it afterwards would mean unpacking and
# re-taring the archive, and `tar -czf` stamps the current time into the gzip header — which
# would make two builds of the same commit differ.
build_info_dir="$(mktemp -d)"
build_info="${build_info_dir}/BUILD_INFO"
{
  echo "XPAM_VERSION=${VERSION}"
  echo "XPAM_BUILD_KIND=${build_kind}"
  echo "XPAM_GIT_COMMIT=${head_sha}"
  echo "XPAM_GIT_TAG=${head_tag:-none}"
  echo "XPAM_WORKTREE_DIRTY=${dirty}"
} > "$build_info"

# Archive the WORKING TREE (tracked files, current on-disk content) under the
# wrapper prefix. git stash create yields a tree object for the working tree
# without touching the stash list; falls back to HEAD when the tree is clean.
tree="$(git stash create 2>/dev/null || true)"
[[ -n "$tree" ]] || tree="HEAD"
git archive --format=tar.gz --prefix="${prefix}/" --add-file="$build_info" -o "$tarball" "$tree"
rm -rf "$build_info_dir"
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
