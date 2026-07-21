#!/usr/bin/env bash
# Resume an in-progress bash build in the Darling prefix (do NOT reconfigure or
# wipe). make is resumable — it skips up-to-date objects — so if Darling's
# intermittent under-load process-wait deadlock hangs make partway, we kill the
# container and re-run make, which continues from where it left off. Repeat until
# bash links and runs. This works around the flaky hang without needing every
# compile to succeed in one session.
#
#   DARLING=./result-perf/bin/darling DPREFIX=$HOME/.dbash scripts/resume-bash-build.sh
set -uo pipefail
DARLING="${DARLING:-$PWD/result-perf/bin/darling}"
PREFIX="${DPREFIX:-$HOME/.dbash}"
RETRIES="${RETRIES:-10}"
BT="${BOOTSTRAP_TOOLS:-/nix/store/v6wk45fap70cgcw88x4ilzkiwzhwq6r0-bootstrap-tools}"
SDK_ROOT="${APPLE_SDK:-/nix/store/dfd1kijwi4r02dk8ridqwmx1vzfg7dik-apple-sdk-14.4}"
SDK="$SDK_ROOT/Platforms/MacOSX.platform/Developer/SDKs/MacOSX14.4.sdk"
g() { printf '/Volumes/SystemRoot%s' "$1"; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cat > "$work/resume.sh" <<INNER
#!/bin/sh
BT=$(g "$BT"); SDK=$(g "$SDK")
export PATH="\$BT/bin:/usr/bin:/bin" SDKROOT="\$SDK" CC=clang
export CFLAGS="-isysroot \$SDK -Wno-implicit-function-declaration -Wno-error -fcommon"
export LDFLAGS="-isysroot \$SDK"
mkdir -p "\$HOME/tmp"; export TMPDIR="\$HOME/tmp"
cd "\$HOME/bbuild/bash-5.3" || { echo NO_TREE; exit 9; }
echo "=RESUME= o_before=\$(ls *.o 2>/dev/null | wc -l) linked=\$([ -x ./bash ] && echo y || echo n)"
make >>make.log 2>&1; echo "make_rc=\$?"
echo "o_after=\$(ls *.o 2>/dev/null | wc -l)"
if [ -x ./bash ]; then
  echo "=VER="; ./bash --version 2>&1 | head -1; echo "ver_rc=\$?"
  echo "=RUN="; ./bash -c 'echo BASH_RUNS_OK; x=2; echo sum=\$((x+3))'; echo "run_rc=\$?"
else
  echo "BASH_NOT_LINKED_YET"
fi
INNER
gR="$(g "$work/resume.sh")"
for i in $(seq 1 "$RETRIES"); do
  pkill -9 -x darlingserver 2>/dev/null || true
  pkill -9 -x mldr 2>/dev/null || true
  sleep 1
  echo "=== resume attempt $i/$RETRIES (load $(cut -d' ' -f1 /proc/loadavg)) ==="
  out=$(DPREFIX="$PREFIX" timeout -k 10 -s KILL 360 "$DARLING" shell sh "$gR" 2>&1) || true
  printf '%s\n' "$out" | grep -avE 'Cannot chown|failed to increase FD rlimit|semaphore_timedwait failed|dserver_rpc|mach_msg_overwrite'
  pkill -9 -x darlingserver 2>/dev/null || true
  pkill -9 -x mldr 2>/dev/null || true
  if printf '%s\n' "$out" | grep -q 'run_rc=0'; then
    echo ">>> BASH_BUILD_AND_RUN_OK (attempt $i)"; exit 0
  fi
  echo "--- attempt $i did not finish; resuming ---"
done
echo "resume exhausted after $RETRIES attempts"; exit 1
