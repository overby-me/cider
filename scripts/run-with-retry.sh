#!/usr/bin/env bash
# RUN AN APPLICATION DRIVER UNTIL THE CONTAINER ACTUALLY BOOTS.
#
# MEASURED 2026-08-20: `cider shell /bin/echo` succeeds 6 of 8 times with launchd and 8 of 8
# without, and a failed boot produces NO OUTPUT AT ALL and times out. From outside that is
# indistinguishable from the application failing to start, and it has been read that way more than
# once: three MoneyMoney runs in a row were called application stalls when the guest never ran.
#
# So: run the driver, and if its log never shows the marker the backend prints once it is alive,
# kill everything and run it again. The gate is OUTSIDE the container on purpose -- a gate loop
# INSIDE one invocation, before the exec, is what previously gave runs where the app never mapped a
# window (see the plan's note on `sh -c 'exec <app>'`).
#
#   run-with-retry.sh <driver.sh> <logfile> [marker] [tries]
set -u
# Where the sweep and the drivers live; override for a different checkout.
SP=${CIDER_SCRATCH:?set CIDER_SCRATCH to the directory holding kill-stale-prefix.sh}
DRIVER=${1:?usage: run-with-retry.sh driver.sh logfile [marker] [tries]}
LOG=${2:?}
MARKER=${3:-cider-wayland-appkit register=ok}
TRIES=${4:-3}
PREFIX=${APPPREFIX:-/tmp/cider-mm-1000/prefix}
GATE=${GATE:-45}

for try in $(seq 1 "$TRIES"); do
  bash "$SP/kill-stale-prefix.sh" "$PREFIX" > /dev/null
  bash "$SP/kill-stale-prefix.sh" /tmp/cider-appkit-1000 > /dev/null
  # The nested compositor is per run; one left over sends grim to the wrong output and every
  # capture comes out black, which is NOT the application drawing nothing.
  NS=$(pgrep -a sway 2>/dev/null | grep sway-nested | awk '{print $1}')
  [ -n "$NS" ] && kill $NS 2>/dev/null
  sleep 2

  : > "$LOG"
  setsid timeout -s KILL "${HARD:-280}" bash "$DRIVER" >> "$LOG" 2>&1 < /dev/null &
  RUN=$!
  # Watch for the marker rather than sleeping blind, so a good boot is not charged the gate.
  ALIVE=no
  for _ in $(seq 1 "$GATE"); do
    sleep 1
    if grep -aq "$MARKER" "$LOG" 2>/dev/null; then ALIVE=yes; break; fi
    kill -0 $RUN 2>/dev/null || break
  done
  if [ "$ALIVE" = yes ]; then
    echo "RETRY-GATE try $try: container is up, letting the run finish"
    wait $RUN 2>/dev/null
    exit 0
  fi
  echo "RETRY-GATE try $try: no marker in ${GATE}s, the container did not boot; retrying"
  kill -9 $RUN 2>/dev/null
  sleep 2
done
echo "RETRY-GATE gave up after $TRIES tries"
exit 1
