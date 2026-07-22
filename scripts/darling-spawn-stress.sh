#!/usr/bin/env bash
# Reliable spawn/IPC stress + correctness harness for darlingserver perf work.
#
# The container cold-start is intermittently flaky (transient -111 RPC failures,
# load-dependent), which makes a single run an unreliable gate. This harness
# RETRIES the boot until it gets a clean run, then runs N rapid process spawns
# inside one container and checks that every spawn succeeded. It distinguishes:
#   * container flaked  (boot/-111 before the loop got going) -> retry
#   * spawns failed     (loop ran but some spawns returned nonzero) -> REAL bug
#   * clean pass        (loop completed, 0 failed spawns)
#
# Use it as the correctness gate for darlingserver IPC-core changes (P1, P2, ...):
#   DARLING=./result-p1/bin/darling DPREFIX=$HOME/.dbash N=200 TRIES=5 \
#     scripts/darling-spawn-stress.sh
# Exit 0 = a clean pass was obtained; exit 1 = spawns failed or no clean run.
set -u
DARLING="${DARLING:-./result/bin/darling}"
export DPREFIX="${DPREFIX:-$HOME/.dbash}"     # must be warm/populated + a short path
N="${N:-200}"
TRIES="${TRIES:-5}"
export DARLING_SHELL_STARTUP_TIMEOUT="${DARLING_SHELL_STARTUP_TIMEOUT:-60}"

kill_ds() { pkill -x darlingserver 2>/dev/null; pkill -x mldr 2>/dev/null; }

for attempt in $(seq 1 "$TRIES"); do
	kill_ds; sleep 2; rm -f "$DPREFIX/.init.pid"
	out=$(timeout 180 env DPREFIX="$DPREFIX" \
		"$DARLING" shell sh -c \
		"echo GO; ok=0; bad=0; i=0; while [ \$i -lt $N ]; do if uname >/dev/null 2>&1; then ok=\$((ok+1)); else bad=\$((bad+1)); fi; i=\$((i+1)); done; echo RESULT ok=\$ok bad=\$bad total=\$i" 2>&1 \
		| grep -viE 'rlimit')
	res=$(printf '%s\n' "$out" | grep -oE 'RESULT ok=[0-9]+ bad=[0-9]+ total=[0-9]+' | head -1)
	if [ -n "$res" ]; then
		ok=$(printf '%s' "$res"  | sed -E 's/.*ok=([0-9]+).*/\1/')
		bad=$(printf '%s' "$res" | sed -E 's/.*bad=([0-9]+).*/\1/')
		if [ "$bad" -eq 0 ] && [ "$ok" -eq "$N" ]; then
			echo "PASS (attempt $attempt): $ok/$N spawns ok, 0 failed"
			kill_ds; exit 0
		else
			echo "SPAWN FAILURES (attempt $attempt): ok=$ok bad=$bad of $N -> REAL bug"
			kill_ds; exit 1
		fi
	fi
	# no RESULT marker -> container flaked before/at boot; retry
	echo "attempt $attempt: container flaked (no completion), retrying"
done
echo "NO CLEAN RUN in $TRIES attempts (container too flaky right now, not necessarily a code bug)"
kill_ds; exit 1
