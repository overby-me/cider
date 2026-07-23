#!/usr/bin/env bash
# gen-submodule-manifest.sh - emit nix/submodules.json from .gitmodules + gitlinks.
#
# This is the first half of the "off git submodules" move (task #23): instead of
# `git submodule update` (or a dirty `?submodules=1` flake build) to materialise
# Darling's 147 vendored trees, we pin each as a fetchFromGitHub in nix and let
# nix/lib/darling-src.nix assemble them into a source tree. This script produces
# the manifest that both sides read.
#
# Each entry is { path, owner, repo, rev, hash }:
#   path  - submodule path in the superproject (from .gitmodules)
#   owner - always "darlinghq" (this fork's relative URLs resolve there; see
#           scripts/init-submodules.sh, the authoritative mapping this mirrors)
#   repo  - basename of the .gitmodules URL without .git
#   rev   - the gitlink commit the superproject records (via `git ls-tree`, so it
#           works with submodules uninitialised)
#   hash  - left "" here; fill with scripts/prefetch-submodule-hashes.sh (needs
#           network). An empty hash means "not yet pinned" to darling-src.nix.
#
# Rev note: xnu carries Campaign-1 syscall fixes as patches/xnu/, not in its
# gitlink, so its rev is the upstream base; darling-src.nix applies the patches.
#
# Usage: scripts/gen-submodule-manifest.sh
set -euo pipefail
cd "$(dirname "$0")/.."

out=nix/submodules.json
tmp=$(mktemp)

# Gitlink overrides: some recorded gitlinks are unpublished fork revs. Use the
# upstream base rev instead and rely on patches/<name>/. Keep in sync with
# scripts/init-submodules.sh's GITLINK_OVERRIDE (the local-checkout counterpart).
declare -A GITLINK_OVERRIDE=(
  # Campaign-1 xnu fixes were never published; base rev + patches/xnu/ instead.
  ["src/external/xnu"]="5f26a4c2365d9774b5a1e66ae7da20b61ab6d2db"
)

first=1
count=0
while read -r key url; do
  name=${key#submodule.}
  name=${name%.url}
  path=$(git config -f .gitmodules "submodule.${name}.path")
  repo=${url##*/}
  repo=${repo%.git}
  rev=${GITLINK_OVERRIDE[$path]:-$(git ls-tree HEAD "$path" 2>/dev/null | awk '{print $3}')}
  if [ -z "$rev" ]; then
    echo "warn: no gitlink rev for $path (skipped)" >&2
    continue
  fi
  # Preserve any hash already pinned in the existing manifest (so re-running to
  # pick up a rev bump does not throw away hashes we have already prefetched).
  old_hash=""
  if [ -f "$out" ]; then
    old_hash=$(REV="$rev" PATH_="$path" python3 - "$out" <<'PY' 2>/dev/null || true
import json,os,sys
try:
    for e in json.load(open(sys.argv[1])):
        if e.get("path")==os.environ["PATH_"] and e.get("rev")==os.environ["REV"]:
            print(e.get("hash","")); break
except Exception:
    pass
PY
)
  fi
  [ $first -eq 1 ] && first=0 || printf ',\n' >> "$tmp"
  printf '  {"path": "%s", "owner": "darlinghq", "repo": "%s", "rev": "%s", "hash": "%s"}' \
    "$path" "$repo" "$rev" "$old_hash" >> "$tmp"
  count=$((count + 1))
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.url$')

{ echo "["; cat "$tmp"; echo ""; echo "]"; } > "$out"
rm -f "$tmp"
echo "wrote $out ($count entries, $(grep -c '"hash": ""' "$out" || true) without hashes)"
