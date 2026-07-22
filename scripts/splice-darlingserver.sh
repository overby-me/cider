#!/usr/bin/env bash
# Fast darlingserver perf-iteration loop, avoiding the ~40-min monolith rebuild.
#
# One-time setup (builds a writable runtime copy + a launcher pointing at it):
#   nix build '.?submodules=1#darlingserver' --out-link result-ds   # ~5-15 min
#   scripts/splice-darlingserver.sh setup
#
# Per iteration (after editing src/external/darlingserver and rebuilding it):
#   nix build '.?submodules=1#darlingserver' --out-link result-ds
#   scripts/splice-darlingserver.sh swap        # just drops in the new daemon
#   DPREFIX=~/.dbash "$RT-launcher"/src/startup/darling shell <cmd>
#
# The launcher is baked once to exec $RT/bin/darlingserver, so only the daemon
# binary changes between iterations. Env: RT (runtime dir), DS (built daemon).
set -euo pipefail
cd "$(dirname "$0")/.."
RT="${RT:-$HOME/darling-rt}"
DS="${DS:-result-ds/bin/darlingserver}"
LAUNCHER_LINK="result-launcher-spliced"

need_ds() { [ -x "$DS" ] || { echo "build the daemon first: nix build '.?submodules=1#darlingserver' --out-link result-ds"; exit 1; }; }

case "${1:-setup}" in
  setup)
    need_ds
    [ -e result ] || { echo "need a full ./result runtime to splice into"; exit 1; }
    echo "staging writable runtime copy at $RT (this dereferences result, ~hundreds of MB)"
    rm -rf "$RT"; cp -rL result "$RT"; chmod -R u+w "$RT"
    cp "$DS" "$RT/bin/darlingserver"
    echo "building launcher baked to $RT ..."
    DARLING_SPLICE_PREFIX="$RT" nix build --impure '.?submodules=1#darling-launcher-spliced' \
      --out-link "$LAUNCHER_LINK"
    echo "READY. run:  DPREFIX=~/.dbash $LAUNCHER_LINK/src/startup/darling shell <cmd>"
    ;;
  swap)
    need_ds
    [ -d "$RT" ] || { echo "run '$0 setup' first"; exit 1; }
    cp "$DS" "$RT/bin/darlingserver"
    echo "swapped in $(sha256sum "$DS" | cut -c1-12); launcher unchanged. rerun your test."
    ;;
  *)
    echo "usage: $0 [setup|swap]"; exit 1;;
esac
