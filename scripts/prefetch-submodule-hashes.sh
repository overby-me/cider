#!/usr/bin/env bash
# prefetch-submodule-hashes.sh - fill the `hash` field in nix/submodules.json.
#
# The second half of the off-git-submodules move (with gen-submodule-manifest.sh
# and nix/lib/darling-src.nix): compute the fetchFromGitHub SRI hash for each
# pinned (owner, repo, rev) by prefetching the GitHub archive, and write it back
# into the manifest so darling-src.nix can fetch it purely.
#
# Incremental: by default only fills entries whose hash is still "". Pass paths
# (submodule paths, or basename substrings) to restrict to a subset, or --all to
# recompute every entry. Safe to interrupt and re-run; each success is persisted
# immediately.
#
# Usage:
#   scripts/prefetch-submodule-hashes.sh                 # all missing hashes
#   scripts/prefetch-submodule-hashes.sh xnu bootstrap   # only matching subset
#   scripts/prefetch-submodule-hashes.sh --limit 5       # first 5 missing
#   scripts/prefetch-submodule-hashes.sh --all           # recompute everything
set -euo pipefail
cd "$(dirname "$0")/.."
manifest=nix/submodules.json

want_all=0
limit=0
filters=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all) want_all=1; shift;;
    --limit) limit="$2"; shift 2;;
    *) filters+=("$1"); shift;;
  esac
done

# Emit the work list as tab-separated: idx <TAB> owner <TAB> repo <TAB> rev
mapfile -t work < <(
  WANT_ALL="$want_all" LIMIT="$limit" FILTERS="${filters[*]-}" python3 - "$manifest" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
want_all = os.environ["WANT_ALL"] == "1"
limit = int(os.environ["LIMIT"])
filters = os.environ.get("FILTERS", "").split()
n = 0
for i, e in enumerate(d):
    if not want_all and e.get("hash", ""):
        continue
    if filters and not any(f in e["path"] or f in e["repo"] for f in filters):
        continue
    print(f'{i}\t{e["owner"]}\t{e["repo"]}\t{e["rev"]}')
    n += 1
    if limit and n >= limit:
        break
PY
)

echo "prefetching ${#work[@]} submodule hash(es)..."
ok=0; fail=0
for line in "${work[@]}"; do
  IFS=$'\t' read -r idx owner repo rev <<<"$line"
  url="https://github.com/${owner}/${repo}/archive/${rev}.tar.gz"
  printf '  [%s] %s/%s @ %s ... ' "$idx" "$owner" "$repo" "${rev:0:10}"
  if h=$(nix-prefetch-url --unpack --type sha256 "$url" 2>/dev/null) && [ -n "$h" ]; then
    sri=$(nix hash convert --hash-algo sha256 --to sri "$h" 2>/dev/null \
          || nix hash to-sri --type sha256 "$h" 2>/dev/null)
    IDX="$idx" SRI="$sri" python3 - "$manifest" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d[int(os.environ["IDX"])]["hash"] = os.environ["SRI"]
json.dump(d, open(p, "w"), indent=None)
# re-pretty to keep the one-object-per-line shape gen-submodule-manifest.sh emits
with open(p, "w") as f:
    f.write("[\n")
    f.write(",\n".join("  " + json.dumps(e, separators=(", ", ": ")) for e in d))
    f.write("\n]\n")
PY
    echo "$sri"
    ok=$((ok+1))
  else
    echo "FAILED"
    fail=$((fail+1))
  fi
done
echo "done: $ok ok, $fail failed"
