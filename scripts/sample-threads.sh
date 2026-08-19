#!/usr/bin/env bash
# WHAT IS EVERY THREAD OF THE GUEST APPLICATION DOING? The main thread keeps animating a spinner, so
# the application looks merely slow; the work that never finishes is on a background thread and no
# guest-side trace has spoken. The host can answer without one: each guest thread is a host thread,
# and /proc/<pid>/task/<tid>/{syscall,wchan,stat} says which syscall it is parked in.
#
# A thread parked in recvmsg on the dserver socket is inside a BLOCKING call to another guest
# process, which is the shape of a Mach send-and-receive with no reply. It found MoneyMoney's, at
# zero ticks, while the main thread burned 14 percent of a core animating a spinner.
#
#   scripts/sample-threads.sh [command-line-substring]      SAMPLES=4 EVERY=25 to change the cadence
set -u
# Which application to watch, as a substring of its command line.
APP=${1:-MoneyMoney}
for i in $(seq 1 ${SAMPLES:-6}); do
  sleep ${EVERY:-25}
  echo "=== t=$((i*${EVERY:-25}))s $(date +%T)"
  for p in /proc/[0-9]*; do
    # TWO SIGNALS. The exe says what the process IS -- only a guest process is mldr, and no shell
    # can be -- and the cmdline says WHICH application. Matching the cmdline alone matches this
    # script's own shell, whose command line quotes the script, and then it samples itself.
    exe=$(readlink "$p/exe" 2>/dev/null) || continue
    case "$exe" in */mldr) ;; *) continue ;; esac
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$cmd" in
      *"$APP"*) ;;
      *) continue ;;
    esac
    pid=$(basename "$p")
    echo "  PID $pid  ${cmd:0:70}"
    for t in "$p"/task/*; do
      tid=$(basename "$t")
      sc=$(cat "$t/syscall" 2>/dev/null | awk '{print $1}')
      wc=$(cat "$t/wchan" 2>/dev/null)
      read -r _ _ st rest < "$t/stat" 2>/dev/null
      utime=$(awk '{print $14+$15}' "$t/stat" 2>/dev/null)
      echo "    tid=$tid state=$st syscall=$sc wchan=${wc:-?} ticks=$utime"
    done
  done
done
