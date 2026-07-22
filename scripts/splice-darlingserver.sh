#!/usr/bin/env bash
# Fast darlingserver perf-iteration loop, avoiding the ~40-min monolith rebuild.
# Builds ONLY the daemon (nix/darlingserver.nix, ~5-9 min) and splices it into a
# copy of the full `result` runtime.
#
# One-time setup (copies the runtime + builds daemon & launcher baked to $RT):
#   scripts/splice-darlingserver.sh setup
#
# Per iteration (after editing src/external/darlingserver):
#   scripts/splice-darlingserver.sh swap        # rebuild daemon + re-splice
#   DPREFIX=~/.dbash result-launcher-spliced/src/startup/darling shell <cmd>
#
# The daemon AND launcher must both be baked with CMAKE_INSTALL_PREFIX=$RT so the
# daemon's compiled-in LIBEXEC_PATH (overlay lowerdir + mldr path) and the
# launcher's exec target resolve inside the spliced runtime; DARLING_SPLICE_PREFIX
# drives that (see flake.nix). Env: RT (runtime dir).
set -euo pipefail
cd "$(dirname "$0")/.."
RT="${RT:-$HOME/darling-rt}"
DS=result-ds/bin/darlingserver
LAUNCHER_LINK="result-launcher-spliced"

build_daemon() { # baked to $RT so LIBEXEC_PATH points into the spliced runtime
  echo "building daemon baked to $RT (~5-9 min) ..."
  DARLING_SPLICE_PREFIX="$RT" nix build --impure '.?submodules=1#darlingserver' --out-link result-ds
  [ -x "$DS" ] || { echo "daemon build failed"; exit 1; }
}

case "${1:-setup}" in
  setup)
    [ -e result ] || { echo "need a full ./result runtime to splice into"; exit 1; }
    build_daemon
    # Real copy with cp -a (NOT cp -rL): -a preserves symlinks (--no-dereference),
    # so the runtime's libexec/darling/Volumes/DarlingEmulatedDrive -> / is copied
    # as a symlink, never followed (cp -rL would traverse the whole host fs -- a
    # disaster). A real dir tree is needed: the daemon mounts a container overlay
    # whose lowerdir (LIBEXEC_PATH=$RT/libexec/darling) must be a real directory.
    store="$(readlink -f result)"
    chmod -R u+w "$RT" 2>/dev/null || true; rm -rf "$RT"
    echo "copying runtime (cp -a; ~hundreds of MB) ..."
    cp -a "$store" "$RT"; chmod -R u+w "$RT"
    cp "$DS" "$RT/bin/darlingserver"
    echo "building launcher baked to $RT ..."
    DARLING_SPLICE_PREFIX="$RT" nix build --impure '.?submodules=1#darling-launcher-spliced' \
      --out-link "$LAUNCHER_LINK"
    echo "READY. run:  DPREFIX=~/.dbash $LAUNCHER_LINK/src/startup/darling shell <cmd>"
    ;;
  swap)
    [ -d "$RT" ] || { echo "run '$0 setup' first"; exit 1; }
    build_daemon
    cp "$DS" "$RT/bin/darlingserver"
    echo "swapped in $(sha256sum "$DS" | cut -c1-12); launcher unchanged. rerun your test."
    ;;
  *)
    echo "usage: $0 [setup|swap]"; exit 1;;
esac
