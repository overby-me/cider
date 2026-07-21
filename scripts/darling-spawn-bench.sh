#!/usr/bin/env bash
# Wall-clock per-process-spawn cost under Darling — the metric that maps to build
# time (configure/make fork thousands of short-lived processes). Companion to
# scripts/darling-rpc-attach-probe.sh (which counts syscalls). A syscall-count win
# only matters if it moves this number.
#
# Method: time one warm container running N1 external spawns and one running N2,
# and take (T2-T1)/(N2-N1). The subtraction cancels the fixed container-boot cost,
# leaving the marginal per-spawn wall-clock. Run a couple of times; the container
# is a bit noisy.
#
#   DARLING=./result-both/bin/darling DPREFIX=$HOME/.dbash scripts/darling-spawn-bench.sh
set -u
DARLING="${DARLING:-darling}"
export DPREFIX="${DPREFIX:-$HOME/.dbench}"
N1="${N1:-20}"; N2="${N2:-220}"
WORKLOAD="${WORKLOAD:-uname >/dev/null 2>&1}"

run() { # $1 = iterations -> prints wall seconds (or empty on failure)
	pkill -9 -x darlingserver 2>/dev/null; pkill -9 -x mldr 2>/dev/null; sleep 1
	local n="$1" t0 t1 out
	t0=$(date +%s.%N)
	out=$(timeout -k3 -s KILL 300 "$DARLING" shell sh -c \
		"i=0; while [ \$i -lt $n ]; do $WORKLOAD; i=\$((i+1)); done; echo DONE_$n" 2>&1)
	t1=$(date +%s.%N)
	printf '%s' "$out" | grep -q "DONE_$n" && awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}'
}

echo "## spawn bench (DARLING=$DARLING)  workload='$WORKLOAD'"
best=""
for rep in 1 2 3; do
	t1=$(run "$N1"); t2=$(run "$N2")
	if [ -n "$t1" ] && [ -n "$t2" ]; then
		per=$(awk -v a="$t1" -v b="$t2" -v n1="$N1" -v n2="$N2" 'BEGIN{printf "%.1f", (b-a)*1000/(n2-n1)}')
		echo "  rep$rep: T($N1)=${t1}s T($N2)=${t2}s  => per-spawn ~${per}ms"
		best="$per"
	else
		echo "  rep$rep: container flaked (boot hang); retrying"
	fi
done
pkill -9 -x darlingserver 2>/dev/null; pkill -9 -x mldr 2>/dev/null
[ -n "$best" ] && echo "  marginal per-spawn wall-clock ~= ${best}ms (native fork+exec of uname is <1ms)"
