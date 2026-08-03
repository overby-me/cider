#!/bin/sh
# gnix-hello.sh -- runs INSIDE one darling shell session (rootless one-shot).
# Guest `nix build` compiles GNU hello FROM SOURCE via the darwin stdenv and runs
# it: the *official* campaign M1 (vs the toolchain M1 in build-hello-under-darling.nu).
# See PLAN.md. Everything below is solved; the build currently reaches
# hello's configure and trips the darlingserver fork/exec concurrency bug at the
# first clang call (PLAN.md).
#
# Requires (set up on the HOST before `darling shell sh <this>`):
#   - <prefix>/.enable-writable-nix   (darlingserver overlays a writable native /nix)
#   - hello's COMPLETE build closure realised in the host store:
#       nix-store -r $(nix-store -q --references $HELLO_DRV | grep '\.drv$')
#   - a db dump of that closure (minus hello's own output) at $HELLO_DB_DUMP:
#       nix-store --dump-db <closure> > hello-db.dump
# Env (with defaults; override for other nixpkgs pins):
#   NIXBIN         x86_64-darwin nix bin dir (store path, seen via the /nix overlay)
#   HELLO_DRV      the hello derivation to build
#   HELLO_DB_DUMP  host path to the closure db dump (reached via /Volumes/SystemRoot)
#
# STAYS BASH. This runs inside the GUEST, under a darling shell session, where the
# shell is Darwin bash 3.2.57 and there is no nushell in the prefix. The bash-to-
# nushell conversion (task #40) covers HOST tooling only; converting this would break
# the guest, and putting a nushell in the prefix is a different project.
NIXBIN="${NIXBIN:-/nix/store/fw9y98mcqkksxyah45mmbsrvaxxv7r6x-nix-2.34.8/bin}"
HELLO_DRV="${HELLO_DRV:-/nix/store/yc10hxdna1mi7a8b96azgyg3prfi72ns-hello-2.12.3.drv}"
HELLO_DB_DUMP="${HELLO_DB_DUMP:?set HELLO_DB_DUMP to the host closure-dump path}"

echo "=NIXFIND="
[ -x "$NIXBIN/nix" ] || { echo "NO_NIX_BIN"; ls -d /nix/store/*nix-2.34* 2>/dev/null; exit 1; }
export PATH="$NIXBIN:/usr/bin:/bin"
export HOME=/Users/root
export NIX_CONFIG="experimental-features = nix-command flakes
sandbox = false
build-users-group =
require-sigs = false
substituters = "
export NIX_REMOTE=local

echo "=DBSEED="
# The inherited /nix/var/nix/db is owned by the unmapped host root (rootless userns
# maps host-user->guest-root, so host-root files read as "nobody") => unwritable, and
# it carries a daemon socket that makes nix auto-pick daemon mode. Point nix at a
# fresh guest-owned state dir (no socket -> local store) and seed it with hello's
# closure so the build inputs (present via the /nix/store overlay lower) are valid.
# /tmp is read-only in the container, so keep everything under /Users/root.
export NIX_STATE_DIR=/Users/root/nixstate
export NIX_LOG_DIR=/Users/root/nixlog
export TMPDIR=/Users/root/nixtmp
mkdir -p /Users/root/nixstate /Users/root/nixlog /Users/root/nixtmp
nix-store --init 2>&1 | tail -1
if nix-store --load-db < "/Volumes/SystemRoot${HELLO_DB_DUMP}" 2>&1 | tail -2; then echo "db_seeded_ok"; else echo "db_seed_FAIL"; fi

echo "=NIXVER="; nix --version 2>&1 | head -1 || { echo "NIX_RUN_FAIL"; exit 1; }
echo "=WRITABLE="
touch /nix/store/.wtest 2>/dev/null && { echo "nix_store_WRITABLE"; rm -f /nix/store/.wtest; } || echo "nix_store_READONLY"

echo "=BUILD="
[ -e "$HELLO_DRV" ] || { echo "NO_HELLO_DRV"; exit 1; }
# Retry: guest build/test binaries occasionally take a transient signal (e.g.
# SIGFPE in an autoconf mbrtowc/locale probe) -- a darling execution-fidelity
# flake, not a real build error (PLAN.md, task #44). nix builds are
# atomic, so a fresh attempt re-runs configure and usually passes.
brc=1
for attempt in 1 2 3 4; do
	nix build --offline --no-link -L "${HELLO_DRV}^out" 2>&1
	brc=$?
	[ "$brc" -eq 0 ] && break
	echo "build attempt $attempt failed (rc=$brc); retrying (transient-crash mitigation)..."
done
echo "build_rc=$brc"

echo "=RUN="
BIN=$(nix-store -q --outputs "$HELLO_DRV" 2>/dev/null | head -1)
[ -n "$BIN" ] && [ -x "$BIN/bin/hello" ] && { "$BIN/bin/hello"; echo "hello_rc=$?"; } || echo "no_hello_binary (out=$BIN)"
