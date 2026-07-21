#!/usr/bin/env bash
# Quantify Darling overhead: count darlingserver socket round-trips
# (sendmsg/recvmsg/sendto/recvfrom) and futex calls for a workload, and time
# per-process startup. Run this to find which hot path dominates before writing
# any optimization. Needs a Darling launcher (DARLING) + a prefix (DPREFIX).
#
#   DARLING=/nix/store/..-darling/bin/darling DPREFIX=$HOME/.dperf \
#     scripts/darling-perf-probe.sh
set -u
DARLING="${DARLING:-darling}"
export DPREFIX="${DPREFIX:-$HOME/.dperf}"
OUT="${OUT:-/tmp/darling-perf}"; mkdir -p "$OUT"
STRACE="${STRACE:-strace}"

boot() { pkill -9 -x darlingserver 2>/dev/null; pkill -9 -x mldr 2>/dev/null; sleep 1; }

# strace -f -c a workload and print the round-trip / futex / total histogram.
probe() {
	local name="$1"; shift
	boot
	"$STRACE" -f -c -o "$OUT/$name.strace" "$DARLING" shell "$@" >"$OUT/$name.out" 2>>"$OUT/$name.out" || true
	echo "=== $name : $* ==="
	# summary columns: % time / seconds / usecs/call / calls / errors / syscall
	awk 'NR>2 && $NF ~ /^(sendmsg|recvmsg|sendto|recvfrom|futex|read|write|openat|mmap|clone|clone3|rt_sigprocmask|rt_sigaction)$/ {
		printf "  %-14s calls=%-8s time%%=%s\n", $NF, $(NF-2), $1 }' "$OUT/$name.strace" 2>/dev/null
	local rt fut tot
	rt=$(awk 'NR>2 && $NF ~ /^(sendmsg|recvmsg|sendto|recvfrom)$/ {s+=$(NF-2)} END{print s+0}' "$OUT/$name.strace" 2>/dev/null)
	fut=$(awk 'NR>2 && $NF=="futex" {print $(NF-2)+0}' "$OUT/$name.strace" 2>/dev/null)
	tot=$(awk 'NR>2 && $NF!="total" {s+=$(NF-2)} END{print s+0}' "$OUT/$name.strace" 2>/dev/null)
	echo "  --> socket round-trips=${rt:-?}  futex=${fut:-?}  total-syscalls=${tot:-?}"
	echo ""
}

# per-process startup latency: N sequential `true`s in one shell vs one boot.
latency() {
	boot
	local n="${1:-30}" t0 t1
	t0=$(date +%s.%N 2>/dev/null || echo 0)
	"$DARLING" shell sh -c "i=0; while [ \$i -lt $n ]; do /usr/bin/true; i=\$((i+1)); done; echo LOOP_DONE" >"$OUT/lat.out" 2>&1 || true
	t1=$(date +%s.%N 2>/dev/null || echo 0)
	if grep -q LOOP_DONE "$OUT/lat.out"; then
		echo "=== per-process startup: $n x /usr/bin/true in one container ==="
		awk -v a="$t0" -v b="$t1" -v n="$n" 'BEGIN{ if(a&&b) printf "  wall=%.2fs  per-exec=%.1fms\n", b-a, (b-a)*1000/n }'
	else
		echo "=== latency probe: container did not complete (shellspawn race?); retry ==="
	fi
	echo ""
}

echo "## Darling perf probe (DARLING=$DARLING PREFIX=$DPREFIX)"
probe bare       sh -c 'true'
probe getpwuid   sh -c 'i=0; while [ $i -lt 20 ]; do id -u >/dev/null; i=$((i+1)); done; echo IDS_DONE'
probe fork       sh -c 'i=0; while [ $i -lt 20 ]; do /usr/bin/true; i=$((i+1)); done; echo FORK_DONE'
latency 30
echo "raw strace summaries in $OUT/*.strace"
