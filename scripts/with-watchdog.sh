#!/usr/bin/env bash
# with-watchdog.sh - run a command under a timeout, and on expiry capture
# stack traces of the guest process tree and ciderd before killing it.
#
# Stalls (not crashes) are the signature failure mode of a subtly-wrong kernel
# shim under Darling - typically kqueue/kevent, poll/select edge semantics, or
# a Mach IPC wait that never wakes. When a build or test hangs, a plain timeout
# tells us nothing; this wrapper attaches gdb to every relevant process on
# timeout and dumps backtraces so the stall can be triaged
# (see PLAN.md).
#
# Usage:
#   scripts/with-watchdog.sh [--timeout SECONDS] [--label NAME]
#                            [--log FILE] -- <command> [args...]
#
# Defaults: --timeout 900, label "job", log written under $TMPDIR.
# Exit code: the command's own, or 124 if it timed out.
#
# Example:
#   scripts/with-watchdog.sh --timeout 1800 --label hello-build -- \
#     ./scripts/cider-nix nix build nixpkgs#hello
#
# STAYS BASH (task #40). This forwards ARBITRARY argv to another program, and a nushell
# script cannot receive that: nu parses a script's arguments against main's signature, so the
# first argument starting with a dash becomes an unknown flag and the script exits 1 before
# running. `--` does not help, in either `script.nu -- -la` or `nu script.nu -- -la` form; both
# are parsed as a flag with an empty name. Measured, not assumed.
#
# It also needs a process GROUP: setsid, then SIGTERM and SIGKILL to -PID after the stacks are
# captured. nushell has no primitive for either half.

set -uo pipefail

TIMEOUT=900
LABEL="job"
LOG=""
declare -a CMD=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    --) shift; CMD=("$@"); break ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1 (did you forget -- before the command?)" >&2; exit 2 ;;
  esac
done

if [[ ${#CMD[@]} -eq 0 ]]; then
  echo "usage: $0 [--timeout S] [--label N] [--log F] -- <command...>" >&2
  exit 2
fi

ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
LOG=${LOG:-"${TMPDIR:-/tmp}/watchdog-${LABEL}-${ts}.log"}
GDB=$(command -v gdb || true)

capture_stacks() {
  {
    echo "=================================================================="
    echo "WATCHDOG: '$LABEL' exceeded ${TIMEOUT}s - capturing stacks"
    echo "time: $(date 2>/dev/null || true)"
    echo "=================================================================="

    # Everything that looks like a Darling guest or the server.
    local pids
    pids=$(pgrep -a -f 'ciderd|mldr|/usr/libexec/cider|cider ' 2>/dev/null \
      | awk '{print $1}' | sort -un)

    if [[ -z "$pids" ]]; then
      echo "(no ciderd/mldr/guest processes found via pgrep)"
      pids=$(pgrep -f cider 2>/dev/null | sort -un)
    fi

    for pid in $pids; do
      echo ""
      echo "----- pid $pid : $(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null) -----"
      echo "wchan: $(cat /proc/$pid/wchan 2>/dev/null)"
      echo "state: $(awk '/^State:/{print $2,$3}' /proc/$pid/status 2>/dev/null)"
      if [[ -n "$GDB" ]]; then
        timeout 30 "$GDB" -p "$pid" -batch \
          -ex 'set pagination off' \
          -ex 'thread apply all bt' 2>/dev/null \
          || echo "(gdb attach failed for $pid)"
      else
        echo "(gdb not available; kernel stack below)"
        cat /proc/$pid/stack 2>/dev/null || echo "(no /proc/$pid/stack)"
      fi
    done
    echo "=================================================================="
    echo "WATCHDOG: stack capture complete -> $LOG"
  } >>"$LOG" 2>&1
}

echo "[watchdog] '$LABEL' timeout=${TIMEOUT}s log=$LOG" >&2

# Run the command in its own process group so we can kill the whole tree.
setsid "${CMD[@]}" &
child=$!

(
  # Watchdog subshell.
  for _ in $(seq 1 "$TIMEOUT"); do
    kill -0 "$child" 2>/dev/null || exit 0
    sleep 1
  done
  kill -0 "$child" 2>/dev/null || exit 0
  echo "[watchdog] '$LABEL' TIMED OUT after ${TIMEOUT}s; capturing stacks -> $LOG" >&2
  capture_stacks
  # SIGTERM the group, then SIGKILL.
  kill -TERM -"$child" 2>/dev/null
  sleep 5
  kill -KILL -"$child" 2>/dev/null
) &
watcher=$!

wait "$child"
rc=$?

# Stop the watcher if the command finished on its own.
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null

if ! kill -0 "$child" 2>/dev/null && [[ $rc -eq 143 || $rc -eq 137 ]]; then
  echo "[watchdog] '$LABEL' was killed after timeout (see $LOG)" >&2
  exit 124
fi
exit $rc
