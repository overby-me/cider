#!/usr/bin/env bash
# init-submodules.sh - materialize Darling submodules from upstream darlinghq.
#
# Why this exists: this fork's .gitmodules uses URLs relative to the origin
# remote (e.g. ../darling-xnu.git). Those resolve to repos that do not exist
# on the fork's host, so a plain `git submodule update --init` cannot fetch.
# This script points every submodule at the canonical upstream
# (https://github.com/darlinghq/<name>.git) via local .git/config overrides
# (without touching .gitmodules), fetches everything, applies any local
# patches from patches/<submodule-basename>/, and reports leftovers.
#
# Known-orphaned gitlinks: commits recorded in the super-repo that were never
# published anywhere are overridden to a reachable upstream rev below; the
# corresponding local changes live in patches/ instead.
#
# Usage: scripts/init-submodules.sh [--jobs N] [--skip-patches]
# Idempotent: safe to re-run; already-applied patches are detected.

set -uo pipefail

JOBS=8
APPLY_PATCHES=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs) JOBS="$2"; shift 2 ;;
    --skip-patches) APPLY_PATCHES=0; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

# Gitlink overrides: path -> upstream rev to check out instead of the
# (unpublished) rev recorded in the super-repo tree.
declare -A GITLINK_OVERRIDE=(
  # Campaign-1 xnu fixes were never published; base rev + patches/xnu/ instead.
  ["src/external/xnu"]="5f26a4c2365d9774b5a1e66ae7da20b61ab6d2db"
)

echo "==> Initializing submodule configuration"
git submodule init >/dev/null

echo "==> Overriding submodule URLs to upstream darlinghq"
while read -r key url; do
  name=${key#submodule.}
  name=${name%.url}
  base=${url##*/}
  git config "submodule.${name}.url" "https://github.com/darlinghq/${base}"
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.url$')

echo "==> Fetching submodules (jobs: ${JOBS}); this downloads several GB"
# The overridden gitlinks fail here (their recorded revs are unreachable);
# everything else completes. Failures are handled explicitly next.
git submodule update --init --recursive --jobs "$JOBS"
update_rc=$?
[[ $update_rc -ne 0 ]] && echo "    (update exited ${update_rc}; resolving known overrides)"

for path in "${!GITLINK_OVERRIDE[@]}"; do
  rev=${GITLINK_OVERRIDE[$path]}
  name=$(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
    | awk -v p="$path" '$2 == p {sub(/^submodule\./, "", $1); sub(/\.path$/, "", $1); print $1}')
  url=$(git config "submodule.${name}.url")
  echo "==> Override: ${path} -> ${rev}"
  if [[ ! -e "${path}/.git" ]]; then
    git clone "$url" "$path" || { echo "    clone failed for ${path}" >&2; continue; }
  fi
  git -C "$path" fetch origin "$rev" 2>/dev/null || git -C "$path" fetch origin
  git -C "$path" checkout --quiet "$rev" || { echo "    checkout ${rev} failed in ${path}" >&2; continue; }
  git -C "$path" submodule update --init --recursive --jobs "$JOBS" || true
done

# Repair pass: the parallel update aborts on the first hard failure (the xnu
# override above), which can leave later submodules registered but with no
# checked-out content (only a .git file). Re-fetch any that are empty.
echo "==> Repairing content-empty submodules"
repaired=0
while read -r _ path; do
  [[ -z "$path" ]] && continue
  n=$(ls -A "$path" 2>/dev/null | grep -v '^\.git$' | wc -l)
  if [[ "$n" -eq 0 ]]; then
    echo "    re-fetching $path"
    git submodule update --init --force "$path" >/dev/null 2>&1 || {
      # Maybe it's another orphaned gitlink; try latest upstream default branch.
      url=$(git config "submodule.$path.url" 2>/dev/null)
      [[ -n "$url" ]] && { rm -rf "$path"/* 2>/dev/null; git clone --depth 1 "$url" "$path" 2>/dev/null; }
    }
    repaired=$((repaired+1))
  fi
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
echo "    repaired ${repaired} empty submodule(s)"

if [[ $APPLY_PATCHES -eq 1 && -d patches ]]; then
  echo "==> Applying local patches"
  for dir in patches/*/; do
    [[ -d "$dir" ]] || continue
    base=$(basename "$dir")
    # Find the submodule path whose directory basename matches patches/<base>/
    target=""
    while read -r _ p; do
      if [[ $(basename "$p") == "$base" ]]; then target="$p"; break; fi
    done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
    if [[ -z "$target" || ! -e "$target/.git" ]]; then
      echo "    skip ${base}: no checked-out submodule matches" >&2
      continue
    fi
    for patch in "$dir"*.patch; do
      [[ -e "$patch" ]] || continue
      abs_patch="${repo_root}/${patch}"
      if git -C "$target" apply --reverse --check "$abs_patch" 2>/dev/null; then
        echo "    ${patch}: already applied"
      elif git -C "$target" apply --check "$abs_patch" 2>/dev/null; then
        git -C "$target" apply "$abs_patch"
        echo "    ${patch}: applied"
      else
        echo "    ${patch}: DOES NOT APPLY to ${target}" >&2
      fi
    done
  done
fi

echo "==> Remaining uninitialized submodules:"
remaining=$(git submodule status --recursive 2>/dev/null | grep -c '^-' || true)
git submodule status 2>/dev/null | awk '/^-/ {print "    " $2}'
echo "==> Done. ${remaining} uninitialized."
