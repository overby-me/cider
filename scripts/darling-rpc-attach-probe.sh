#!/usr/bin/env bash
# Measure darlingserver overhead by attaching strace to the DAEMON itself (which
# lives outside the emulated process's user namespace, so its RPC-handling
# syscalls are actually visible -- strace-ing `darling shell` only sees the
# launcher). Spawns N short-lived macho processes and reports the daemon's own
# syscall histogram, which is where per-process emulation overhead shows up.
#
# This is the before/after tool for perf work (see plan/perf-overhead.md). It
# found getpid+getuid+getgid = 83% of darlingserver syscalls (ucred filled per
# message), fixed in patches/darlingserver/0002-cache-darlingserver-own-credentials.
#
#   DARLING=./result/bin/darling STRACE=$(command -v strace) DPREFIX=$HOME/.dbash \
#     N=200 scripts/darling-rpc-attach-probe.sh
set -u
DARLING="${DARLING:-darling}"
STRACE="${STRACE:-strace}"
export DPREFIX="${DPREFIX:-$HOME/.dperf}"
N="${N:-200}"
WORKLOAD="${WORKLOAD:-uname >/dev/null 2>&1}"
OUT="${OUT:-/tmp/darling-rpc-probe}"; mkdir -p "$OUT"

pkill -9 -x darlingserver 2>/dev/null; pkill -9 -x mldr 2>/dev/null; sleep 2

# Launch the workload container in the background: N iterations of $WORKLOAD,
# each a full macho process spawn (task/thread registration + startup RPCs).
nohup "$DARLING" shell sh -c \
  "echo LOOP_START; i=0; while [ \$i -lt $N ]; do $WORKLOAD; i=\$((i+1)); done; echo LOOP_DONE" \
  >"$OUT/loop.out" 2>&1 &

# Bounded busy-wait for the daemon to appear, then attach and count. SIGINT (not
# KILL) so strace flushes its -c summary on detach.
DS=""; c=0
while [ -z "$DS" ] && [ $c -lt 2000000 ]; do DS=$(pgrep -x darlingserver | head -1); c=$((c+1)); done
echo "darlingserver pid=$DS"
timeout -s INT -k5 35 "$STRACE" -f -c -p "$DS" -o "$OUT/ds.strace" 2>/dev/null

echo "=== workload markers ==="; grep -aE 'LOOP_START|LOOP_DONE' "$OUT/loop.out"
echo "=== darlingserver syscall histogram over $N spawns ==="
cat "$OUT/ds.strace"
id3=$(awk 'NR>3 && $NF ~ /^(getpid|getuid|getgid)$/ {s+=$(NF-2)} END{print s+0}' "$OUT/ds.strace")
tot=$(awk '$NF=="total" {print $(NF-2)}' "$OUT/ds.strace")
echo "=== identity syscalls (getpid+getuid+getgid)=$id3  total=$tot ==="
pkill -9 -x darlingserver 2>/dev/null; pkill -9 -x mldr 2>/dev/null
