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
# Every file whose absence produces a BROKEN install rather than a loud failure. This list used to
# name only 3 of the 9 lib modules and 3 of the 16 templates, so a kit missing e.g.
# xpam-alt-transport.sh or nginx-alt-grpc.conf.tpl passed every gate and then died at runtime —
# exactly the "partial deploy → repair dies on a missing template" incident (2026-07-26), reachable
# a second way. Rule: xpam-core.sh sources ALL of scripts/lib/*.sh, and every templates/*.tpl on
# disk is referenced by the code, so all of them are required. Keep in sync with the updater's
# static preflight — the drift gate in verify_tree enforces that mechanically.
REQUIRED_FILES=(
  install.sh
  bootstrap.sh
  VERSION
  RELEASE
  scripts/xpam-core.sh
  # Every module sourced by xpam-core.sh.
  scripts/lib/xpam-alt-transport.sh
  scripts/lib/xpam-doublehop.sh
  scripts/lib/xpam-launchers.sh
  scripts/lib/xpam-maintenance.sh
  scripts/lib/xpam-mtproto.sh
  scripts/lib/xpam-notify.sh
  scripts/lib/xpam-sites.sh
  scripts/lib/xpam-update.sh
  scripts/lib/xpam-xui.sh
  # Every template the code renders. The nginx/haproxy ones are load-bearing for masking and for
  # the front layer; repair re-renders them, so a kit without them cannot self-heal.
  templates/backend-order.conf.tpl
  templates/check-dns-policy.sh.tpl
  templates/check-network-tuning-policy.sh.tpl
  templates/haproxy.cfg.tpl
  templates/health.sh.tpl
  templates/nginx-alt-acme.conf.tpl
  templates/nginx-alt-grpc.conf.tpl
  templates/nginx-alt-xhttp.conf.tpl
  templates/nginx-certonly.conf.tpl
  templates/nginx-direct.conf.tpl
  templates/nginx-mtproto.conf.tpl
  templates/post-reboot-maint.service.tpl
  templates/post-reboot-maint.sh.tpl
  templates/wait-for-local-port.sh.tpl
  templates/weekly.sh.tpl
  templates/xpam-maint-common.sh.tpl
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

  # Required-file drift gate. The self-updater keeps its OWN copy of this list (its static
  # preflight runs on a box, where make-release.sh is not involved), and the two had already
  # drifted apart while a comment claimed they mirrored each other. Compare them as sets so a file
  # added to one is never forgotten in the other: otherwise a kit missing that file either fails to
  # build but self-updates fine, or the reverse.
  local upd="$root/scripts/lib/xpam-update.sh" want have
  if [[ -f "$upd" ]]; then
    want="$(printf '%s\n' "${REQUIRED_FILES[@]}" | sort -u | tr '\n' ' ')"
    have="$(sed -n '/^  required=(/,/^  )/p' "$upd" | grep -oE '"[^"]+"' | tr -d '"' | sort -u | tr '\n' ' ')"
    [[ -n "$have" ]] \
      || die "required-file drift gate: could not locate the required=() list in scripts/lib/xpam-update.sh"
    if [[ "$want" != "$have" ]]; then
      echo "  only in make-release.sh: $(comm -23 <(printf '%s\n' "${REQUIRED_FILES[@]}" | sort -u) <(sed -n '/^  required=(/,/^  )/p' "$upd" | grep -oE '"[^"]+"' | tr -d '"' | sort -u) | tr '\n' ' ')" >&2
      echo "  only in xpam-update.sh: $(comm -13 <(printf '%s\n' "${REQUIRED_FILES[@]}" | sort -u) <(sed -n '/^  required=(/,/^  )/p' "$upd" | grep -oE '"[^"]+"' | tr -d '"' | sort -u) | tr '\n' ' ')" >&2
      die "required-file lists differ between make-release.sh and the updater's static preflight"
    fi
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

  # --- config-template gates -------------------------------------------------------------------
  # *.conf.tpl / *.cfg.tpl were checked by NOTHING until now: render-smoke only covers *.sh.tpl, and
  # nginx/HAProxy validity was provable solely by `nginx -t` at apply time, i.e. on a live box. These
  # are the templates the masking and the whole front layer depend on. A real `nginx -t` stays a
  # box-time check on purpose (it needs the http context and the actual certificate files, so running
  # it here would only manufacture false failures) — what IS checkable offline is checked below.
  local tok tf known
  # (a) Every {{TOKEN}} a template uses must actually be provided by the kit. An unset token renders
  #     as an EMPTY string, which silently yields things like "listen ;" or "proxy_pass http://:;" —
  #     a broken front that no syntax check of ours would notice. "Provided" is deliberately broad:
  #     the kit sets these in three shapes — a bare list (`export A B C` in export_vars), an inline
  #     assignment (`export A="..."`, including several per line), and module-local exports such as
  #     ALT_CERT in xpam-alt-transport.sh. Collect assignment targets plus bare-export names once.
  # `|| true` on each grep: this runs under `set -e`+`pipefail`, so an empty match would abort.
  known="$( { grep -rhoE '[A-Za-z_][A-Za-z0-9_]*=' "$root/scripts" 2>/dev/null | tr -d '=' || true
              grep -rhoE '\bexport[[:space:]]+[A-Za-z_][A-Za-z0-9_ ]*' "$root/scripts" 2>/dev/null | sed -E 's/^export[[:space:]]+//' | tr ' ' '\n' || true
            } | sort -u )"
  [[ -n "$known" ]] || die "config-template gate: could not collect any variable names from scripts/"
  while IFS= read -r -d '' tf; do
    while read -r tok; do
      [[ -n "$tok" ]] || continue
      printf '%s\n' "$known" | grep -qx -- "$tok" \
        || { echo "  template token FAIL: {{${tok}}} used in ${tf#$root/} but nothing in scripts/ ever sets it (renders empty)"; fail=1; }
    done < <(grep -ohE '\{\{[A-Za-z0-9_]+\}\}' "$tf" | tr -d '{}' | sort -u)
  done < <(find "$root/templates" -type f \( -name '*.conf.tpl' -o -name '*.cfg.tpl' \) -print0)

  # (b) nginx templates only: braces must balance and every directive must terminate. Tokens are
  #     substituted with NOTHING (not a placeholder) because several expand to whole multi-line
  #     blocks; an empty expansion keeps "listen {{PORT}};" -> "listen ;", still a valid shape for
  #     this check. Non-nginx templates are excluded: backend-order.conf.tpl is a systemd unit and
  #     haproxy.cfg.tpl is HAProxy syntax — neither uses semicolons or braces.
  while IFS= read -r -d '' tf; do
    local rendered opens closes badline
    rendered="$(sed -E 's/\{\{[A-Za-z0-9_]+\}\}//g' "$tf")"
    if printf '%s\n' "$rendered" | grep -q '{{'; then
      echo "  template FAIL: ${tf#$root/} still contains an unsubstituted '{{' after token removal (malformed token?)"; fail=1
    fi
    opens="$(printf '%s\n' "$rendered" | tr -cd '{' | wc -c)"
    closes="$(printf '%s\n' "$rendered" | tr -cd '}' | wc -c)"
    [[ "$opens" -eq "$closes" ]] \
      || { echo "  template FAIL: ${tf#$root/} unbalanced braces ({=$opens, }=$closes)"; fail=1; }
    # `|| true`: a clean template makes the second grep match nothing, and under `set -e`+`pipefail`
    # that non-zero would abort the build on SUCCESS. Same reason as the `known=` assignment above.
    badline="$(printf '%s\n' "$rendered" | grep -vE '^[[:space:]]*(#|$)' | grep -vE '[;{}][[:space:]]*$' | head -1 || true)"
    [[ -z "$badline" ]] \
      || { echo "  template FAIL: ${tf#$root/} directive does not end in ';', '{' or '}': ${badline}"; fail=1; }
  done < <(find "$root/templates" -type f -name 'nginx-*.conf.tpl' -print0)
  [[ "$fail" -eq 0 ]] || die "config-template gate failed (see above)"

  # --- public-docs gate: no removed commands presented as current ---------------------------------
  # v1.4.0 removed four launchers and the --show-secrets flag. The GitHub issue template kept asking
  # people to redact the output of `<prefix>-links --show-secrets` — a flag that no longer exists —
  # and nothing caught it, because documentation is the one thing no gate ever read. A user meeting
  # the project through a stale instruction is a real defect, not a typo.
  #
  # Some files MUST mention the old names: the guide's migration table, the release notes and the
  # changelog's historical entries. Rather than weaken the check for them, those files declare it
  # once, near the top:  <!-- xpam-lint: legacy-commands-documented -->
  # Everything else must not mention the removed names at all. Add a name here the moment a command
  # is removed, in the same commit — and only if the kit truly stops writing it. `netdiag` is NOT in
  # this list on purpose: it still exists, because the pre-1.4.0 updater's postcheck requires it (see
  # the updater-postcheck gate below).
  local legacy_re='(<prefix>|\$\{?SERVER_PREFIX\}?)-(status|tg|vless)\b|--show-secrets'
  local df hits
  while IFS= read -r -d '' df; do
    # `|| true` on both greps: no match is the SUCCESS case here, and a non-zero would abort the
    # build under `set -e`+`pipefail` (same reason as the gates above).
    grep -q 'xpam-lint: legacy-commands-documented' "$df" 2>/dev/null && continue
    hits="$(grep -nE "$legacy_re" "$df" 2>/dev/null | head -5 || true)"
    if [[ -n "$hits" ]]; then
      echo "  public-docs FAIL: ${df#$root/} refers to a command removed in this release:"
      printf '    %s\n' "$hits"
      echo "    -> update the text, or add '<!-- xpam-lint: legacy-commands-documented -->' if the file"
      echo "       documents the migration on purpose."
      fail=1
    fi
  # Internal, git-ignored files are not public documentation and are exempt: handoff/ is the private
  # context set, and CLAUDE.md is the agent briefing — both legitimately name removed commands while
  # explaining the migration, and neither ships to anyone.
  done < <(find "$root" -path "$root/handoff" -prune -o \
                        -name 'CLAUDE.md' -prune -o \
                        -name 'CLAUDE.local.md' -prune -o \
                        -type f \( -name '*.md' -o -name '*.yml' -o -name '*.yaml' \) \
                        -not -path "*/sites/*" -print0)
  [[ "$fail" -eq 0 ]] || die "public-docs gate failed (see above)"

  # --- updater postcheck vs. the launchers the kit actually writes --------------------------------
  # The v1.4.0 release shipped an updater whose postcheck required `<prefix>-netdiag` while the same
  # release deleted that launcher: every self-update failed its own postcheck and rolled back. Nothing
  # caught it, because each half was internally consistent — only the pair was wrong. So compare them.
  #
  # Left side:  the command list in xpam_update_postcheck (`for c in ... ; do`).
  # Right side: the launchers write_health_weekly actually creates.
  # Every name the updater demands must be one the kit writes. (The reverse is fine: the kit may write
  # more than the updater checks.)
  local pc_list writes miss
  pc_list="$(sed -n '/^xpam_update_postcheck()/,/^}/p' "$root/scripts/lib/xpam-update.sh" \
             | sed -nE 's/^[[:space:]]*for c in ([a-z0-9 _-]+); do.*/\1/p' | head -1 | tr ' ' '\n' | sed '/^$/d')"
  [[ -n "$pc_list" ]] || die "updater-postcheck gate: could not read the command list from xpam_update_postcheck"
  # Match DEFINITIONS only (`write_x_launcher(){` at the start of a line), never a mention in prose —
  # the first cut of this gate grepped the whole file and was satisfied by its own explanatory
  # comment, so it passed while the defect was present. Verified by breaking it.
  # `|| true`: a name that is never written yields no match, and that is the case we want to REPORT,
  # not abort on, under `set -e`+`pipefail`.
  writes="$(grep -ohE '^[[:space:]]*write_[a-z0-9_]+_launcher[[:space:]]*\(\)' "$root/scripts/lib/xpam-launchers.sh" \
            | tr -d ' ()' | sort -u || true)"
  miss=""
  while read -r c; do
    [[ -n "$c" ]] || continue
    printf '%s\n' "$writes" | grep -qx "write_${c}_launcher" || miss="${miss} ${c}"
  done <<< "$pc_list"
  if [[ -n "$miss" ]]; then
    echo "  updater-postcheck FAIL: xpam_update_postcheck requires <prefix>-{${miss# }} but"
    echo "    scripts/lib/xpam-launchers.sh has no write_*_launcher that creates it."
    echo "    An update would delete/never write the command and then fail its own postcheck."
    die "updater-postcheck gate failed"
  fi

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
