#!/usr/bin/env bash
# Reproduce and rate the intermittent clang crash under Darling that aborts
# ./configure (configure runs hundreds of compile probes; a low per-invocation
# crash rate reliably kills it). Compiles + runs a trivial program N times and
# reports how many crashed and with what signal (rc 139=SIGSEGV, 134=SIGABRT).
# Isolates the fidelity bug from bash specifics.
#
#   DARLING=./result-both/bin/darling scripts/darling-crash-repro.sh
set -u
DARLING="${DARLING:-darling}"
PREFIX="${DPREFIX:-$HOME/.dbash}"
N="${N:-60}"
BT="${BOOTSTRAP_TOOLS:-/nix/store/v6wk45fap70cgcw88x4ilzkiwzhwq6r0-bootstrap-tools}"
SDK_ROOT="${APPLE_SDK:-/nix/store/dfd1kijwi4r02dk8ridqwmx1vzfg7dik-apple-sdk-14.4}"
CACHE="https://cache.nixos.org"
for p in "$BT" "$SDK_ROOT"; do [ -e "$p" ] || nix copy --from "$CACHE" "$p" --no-check-sigs; done
SDK="$SDK_ROOT/Platforms/MacOSX.platform/Developer/SDKs/MacOSX14.4.sdk"
g() { printf '/Volumes/SystemRoot%s' "$1"; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cat > "$work/repro.sh" <<INNER
#!/bin/sh
BT=$(g "$BT"); SDK=$(g "$SDK")
export PATH="\$BT/bin:/usr/bin:/bin" SDKROOT="\$SDK"
cd "\$HOME" || exit 9
rm -rf ctmp; mkdir -p ctmp; export TMPDIR="\$HOME/ctmp"
echo "ulimit_n=\$(ulimit -n) TMPDIR=\$TMPDIR"
printf 'int main(){return 0;}\n' > t.c
cf=0; rf=0
i=0
while [ \$i -lt $N ]; do
  i=\$((i+1))
  clang -isysroot "\$SDK" t.c -o "t.\$i" 2>"e.\$i"; rc=\$?
  if [ \$rc -ne 0 ]; then cf=\$((cf+1)); echo "COMPILE_FAIL i=\$i rc=\$rc \$(head -1 e.\$i)"; continue; fi
  "./t.\$i"; rrc=\$?
  [ \$rrc -ne 0 ] && { rf=\$((rf+1)); echo "RUN_FAIL i=\$i rc=\$rrc"; }
  rm -f "t.\$i" "e.\$i"
done
echo "RESULT compile_fails=\$cf run_fails=\$rf of $N"
INNER
gR="$(g "$work/repro.sh")"
pkill -9 -x darlingserver 2>/dev/null; pkill -9 -x mldr 2>/dev/null; sleep 1
DPREFIX="$PREFIX" timeout 1200 "$DARLING" shell sh "$gR" 2>&1 | grep -avE 'Cannot chown|rlimit|semaphore_timedwait'
pkill -9 -x darlingserver 2>/dev/null
