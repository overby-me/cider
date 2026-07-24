#!/usr/bin/env bash
# build-hello-bypass.sh -- Campaign M1, rootless and launchd-FREE.
#
# Guest Nix, running under Darling with launchd BYPASSED, builds GNU hello
# FROM SOURCE (the official `nix build ...#hello`) and runs it. No LKM, no
# launchd boot -- shellspawn runs directly as the guest PID1 via darlingserver's
# DSERVER_INIT hook, so we never hit launchd's (still-open) portset/kqueue
# bootstrap deadlock (plan/guest-nix-m1.md, task #47).
#
# Why a bypass: `darling shell` normally waits for shellspawn, which launchd
# brings up during `launchctl bootstrap -S System` -- and that bootstrap
# deadlocks in darlingserver mode. shellspawn itself is a standalone unix-socket
# daemon with no launchd/mach-bootstrap dependency, so we run it as PID1 directly.
#
# Usage:
#   scripts/build-hello-bypass.sh [--mono <darling-store-path>] [--prefix <dir>]
# If --mono is omitted, `nix build '.?submodules=1#default'` provides it.
#
# The guest-side driver is scripts/gnix-hello.sh; this script is the HOST-side
# orchestration (build darling, seed the store db, two-boot the bypass container).
set -u

MONO=""
PREFIX="${DPREFIX:-/tmp/darling-hello-m1}"
# nixpkgs 26.05 x86_64-darwin pins (match scripts/gnix-hello.sh defaults).
HELLO_DRV="${HELLO_DRV:-/nix/store/yc10hxdna1mi7a8b96azgyg3prfi72ns-hello-2.12.3.drv}"
NIXBIN="${NIXBIN:-/nix/store/fw9y98mcqkksxyah45mmbsrvaxxv7r6x-nix-2.34.8/bin}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

while [ $# -gt 0 ]; do
	case "$1" in
		--mono)   MONO="$2"; shift 2 ;;
		--prefix) PREFIX="$2"; shift 2 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

KA() { for n in darling darlingserver mldr shellspawn; do pkill -9 -x "$n" 2>/dev/null; done; }
filt() { grep -avE 'Cannot chown|failed to increase FD rlimit'; }

# 1. Darling build (monolith; ?submodules=1 picks up the committed submodules +
#    the campaign working-tree fixes).
if [ -z "$MONO" ]; then
	echo "== building darling (nix build '.?submodules=1#default') =="
	MONO=$(cd "$REPO" && nix build '.?submodules=1#default' --no-link --print-out-paths) || {
		echo "darling build failed" >&2; exit 1; }
fi
[ -x "$MONO/bin/darling" ] || { echo "no darling at $MONO/bin/darling" >&2; exit 1; }
echo "MONO=$MONO"

# 2. Seed data: dump the host valid-paths DB for hello.drv's FULL closure WITH
#    outputs (so guest nix trusts the substituted build inputs -- present via the
#    writable-/nix overlay lower -- and knows how to build hello.drv itself).
DUMP="$(mktemp /tmp/hello-db.XXXXXX.dump)"
echo "== dumping hello.drv closure db -> $DUMP =="
closure=$(nix-store -qR --include-outputs "$HELLO_DRV" 2>/dev/null | sort -u)
nix-store --dump-db $closure > "$DUMP" || { echo "dump-db failed" >&2; exit 1; }
export HELLO_DB_DUMP="$DUMP" HELLO_DRV NIXBIN
export DSERVER_INIT=/usr/libexec/shellspawn   # <-- the launchd bypass
export DARLING_SHELL_STARTUP_TIMEOUT=90

# 3. Warm-up boot: create the prefix skeleton (writable host-visible /var/run via
#    setupPrefix -- must be a real overlay-upper dir, NOT a tmpfs). Let darling
#    create the prefix (a pre-created dir makes checkPrefixDir skip the skeleton).
KA; sleep 2
if [ ! -d "$PREFIX/var/run" ]; then
	echo "== warm-up boot (skeleton + one-time chown) =="
	DPREFIX="$PREFIX" timeout --signal=KILL 300 "$MONO/bin/darling" shell true >/tmp/hello-warmup.out 2>&1
	[ -d "$PREFIX/var/run" ] || { echo "skeleton not created; see /tmp/hello-warmup.out" >&2; exit 1; }
	KA; sleep 3
fi

# 4. Enable the writable native /nix overlay, then build+run hello in ONE guest
#    shell session (rootless runs one command per fresh container -- no re-join).
touch "$PREFIX/.enable-writable-nix"
echo "== M1 build: guest nix builds+runs hello (launchd bypassed) =="
# Write to a FILE, never a pipe: a leaked container holds the pipe write-end open
# so a reader (grep/tail) would block on EOF forever. Read the file after teardown.
OUT="$(mktemp /tmp/hello-build.XXXXXX.out)"
DPREFIX="$PREFIX" timeout --signal=KILL 1200 "$MONO/bin/darling" \
	shell sh "/Volumes/SystemRoot$REPO/scripts/gnix-hello.sh" >"$OUT" 2>&1
rc=$?
KA
filt < "$OUT"
grep -qaE '^Hello, world!$' "$OUT" && grep -qaE 'build_rc=0' "$OUT" && rc=0 || rc=${rc:-1}
rm -f "$DUMP" "$OUT"
echo "== done (exit $rc). Expect: build_rc=0 and 'Hello, world!' above. =="
exit "$rc"
