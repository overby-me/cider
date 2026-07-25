#!/usr/bin/env bash
# build-pkg-bypass.sh -- build ANY nixpkgs x86_64-darwin package FROM SOURCE with
# guest Nix under Darling, rootless and launchd-FREE, then run it.
#
# Generalises scripts/build-hello-bypass.sh (the M1 reference) to an arbitrary
# attr via the generic guest driver scripts/gnix-build.sh. The launchd bypass is
# DARLING_NO_LAUNCHD=1 (shellspawn as guest PID1; no launchd, no LKM). See
# plan/guest-nix-m1.md.
#
# Usage:
#   scripts/build-pkg-bypass.sh <attr> [binname] [--mono <darling-store-path>] [--prefix <dir>]
# e.g.  scripts/build-pkg-bypass.sh hello hello
#       scripts/build-pkg-bypass.sh pv pv
# <binname> (optional) is a binary in the output's bin/ to run with --version.
# If --mono is omitted, `nix build '.?submodules=1#default'` provides darling.
#
# Inputs are substituted from cache.nixos.org (the deps are prebuilt darwin
# binaries); only <attr> itself is built from source, in-guest.
set -u

REV=fd1462031fdee08f65fd0b4c6b64e22239a77870   # nixpkgs 26.05 pin (flake.lock)
ATTR="${1:?usage: build-pkg-bypass.sh <attr> [binname] [--mono P] [--prefix D]}"; shift
BIN=""
case "${1:-}" in --*|"") ;; *) BIN="$1"; shift ;; esac
MONO=""; PREFIX="${DPREFIX:-/tmp/darling-pkg}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
while [ $# -gt 0 ]; do
	case "$1" in
		--mono) MONO="$2"; shift 2 ;;
		--prefix) PREFIX="$2"; shift 2 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

KA() { for n in darling darlingserver mldr shellspawn; do pkill -9 -x "$n" 2>/dev/null; done; }
filt() { grep -avE 'Cannot chown|failed to increase FD rlimit'; }

# 1. darling
if [ -z "$MONO" ]; then
	echo "== building darling =="
	MONO=$(cd "$REPO" && nix build '.?submodules=1#default' --no-link --print-out-paths) \
		|| { echo "darling build failed" >&2; exit 1; }
fi
[ -x "$MONO/bin/darling" ] || { echo "no darling at $MONO" >&2; exit 1; }

# 2. eval the target drv from the pin
echo "== eval $ATTR.drvPath =="
DRV=$(nix eval --raw "github:NixOS/nixpkgs/${REV}#legacyPackages.x86_64-darwin.${ATTR}.drvPath") \
	|| { echo "eval failed for $ATTR" >&2; exit 1; }
echo "DRV=$DRV"
OUTHASH=$(basename "$(nix eval --raw "github:NixOS/nixpkgs/${REV}#legacyPackages.x86_64-darwin.${ATTR}.outPath" 2>/dev/null)")

# 3. substitute the build-input closure (everything but the target's own output)
echo "== substituting build inputs from cache =="
idrvs=$(nix-store -qR "$DRV" 2>/dev/null | grep '\.drv$')
iouts=$(nix-store -q --outputs $idrvs 2>/dev/null | grep -v "$OUTHASH" | sort -u)
nix-store -r $iouts >/dev/null 2>&1 || true   # a few SDK build-tools are not cached; harmless
DUMP="$(mktemp /tmp/pkg-db.XXXXXX.dump)"
nix-store --dump-db $(nix-store -qR --include-outputs "$DRV" 2>/dev/null) > "$DUMP" 2>/dev/null

# 4. warm-up boot -> skeleton; then build+run in one bypass session
export DARLING_NO_LAUNCHD=1 DARLING_SHELL_STARTUP_TIMEOUT=90
export GDRV="$DRV" GDB="$DUMP" GBIN="$BIN"
KA; sleep 2
if [ ! -d "$PREFIX/var/run" ]; then
	echo "== warm-up boot (skeleton) =="
	DPREFIX="$PREFIX" timeout --signal=KILL 300 "$MONO/bin/darling" shell true >/tmp/pkg-warmup.out 2>&1
	[ -d "$PREFIX/var/run" ] || { echo "skeleton not created" >&2; rm -f "$DUMP"; exit 1; }
	KA; sleep 3
fi
touch "$PREFIX/.enable-writable-nix"
echo "== guest nix builds $ATTR from source (launchd bypassed) =="
OUT="$(mktemp /tmp/pkg-build.XXXXXX.out)"
DPREFIX="$PREFIX" timeout --signal=KILL 1800 "$MONO/bin/darling" \
	shell sh "/Volumes/SystemRoot$REPO/scripts/gnix-build.sh" >"$OUT" 2>&1
KA
filt < "$OUT"
rc=1; grep -qaE 'build_rc=0' "$OUT" && rc=0
rm -f "$DUMP" "$OUT"
echo "== done (build_rc match: $([ $rc = 0 ] && echo yes || echo NO)) =="
exit "$rc"
