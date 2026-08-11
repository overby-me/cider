#!/usr/bin/env python3
"""Watch a detached nix build for the zombie-reap stall, and say so out loud.

WHY THIS EXISTS. The endpoint build reproducibly wedges: the daemon worker ends up holding
exactly --max-jobs unreaped `bash <defunct>` children with ZERO live ones, the client sits in
unix_stream_read_gen, and nothing moves again. Eight hypotheses for the cause are dead by
measurement and the mechanism is still unknown, so this does not try to fix it. It tries to
stop it costing an unattended hour. Observed 2026-08-10: a gate wedged at 45 minutes and 3,122
builders and would have sat there indefinitely.

IT REPORTS BY DEFAULT AND KILLS NOTHING. Pass --restart to have it terminate the CLIENT when
it is certain, which is what a human would do: the daemon is root and restarting it is a user
action, while the client can go and the build resumes from the store, losing no work. That
was measured, not assumed: killing the client reaped all six zombies immediately and the
relaunch picked up from what was already built.

THE DISCRIMINATOR IS THREE THINGS AT ONCE, because any one of them alone is normal:
  1. no new `building ` line in the log for --idle-secs;
  2. the worker is IDLE, measured as a jiffie DELTA and never as ps %CPU. That column is a
     LIFETIME average, and a worker that did 45 real minutes before wedging still reads 42
     percent while doing 0.35;
  3. the worker holds >= --max-jobs zombie children and ZERO live ones. Zombies alone are
     ordinary reaping lag; 3 of 6 with the daemon busy is not a stall.

WHAT IT CANNOT SEE. The daemon runs as root, so /proc/<worker>/wchan reads 0 and
/proc/<worker>/fd lists nothing, which naive code reports as "0 open files". Those are
permission artefacts and this deliberately does not use them: a fabricated zero is worse than
no measurement. Anything needing the worker internals needs root.
"""
import argparse
import os
import re
import subprocess
import sys
import time


def builders(log):
    """Count of builders that RAN. Never the will-be-built list."""
    try:
        with open(log, "rb") as fh:
            return fh.read().decode("utf-8", "replace").count("\nbuilding ")
    except OSError:
        return -1


def jiffies(pid):
    """utime+stime. Sample twice and subtract; a single reading means nothing."""
    try:
        with open(f"/proc/{pid}/stat") as fh:
            f = fh.read().rsplit(") ", 1)[1].split()
        return int(f[11]) + int(f[12])
    except (OSError, IndexError, ValueError):
        return None


def children(pid):
    """(zombies, live) direct children, by reading ps once."""
    out = subprocess.run(["ps", "-eo", "ppid=,stat="], capture_output=True, text=True).stdout
    z = live = 0
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == str(pid):
            if parts[1].startswith("Z"):
                z += 1
            else:
                live += 1
    return z, live


def client_pid(match=None):
    """The nix client to act on, or None.

    SCOPED, AND THAT MATTERS BECAUSE THIS FEEDS A KILL. The first version took the FIRST result
    of `pgrep -x nix` with no tie to the log being watched. On a shared box that is a loaded gun:
    when the watched build ends, or merely goes quiet for the idle window, the first nix running
    may belong to somebody else -- the user, or a second agent session -- and --restart would
    terminate THAT one. The standing ops note warns about --relaunch-cmd aiming at whatever nix
    runs next; the same hazard is already present in choosing the client.

    So a kill now requires --client-match, an argv substring naming the build to act on, and
    main() refuses --restart without it. Report-only stays unscoped, because reporting on the
    wrong pid costs nothing.
    """
    out = subprocess.run(["ps", "-eo", "pid=,args="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        argv = parts[1]
        cmd = argv.split(None, 1)[0].rsplit("/", 1)[-1]
        if cmd != "nix":
            continue
        if match is not None and match not in argv:
            continue
        return int(parts[0])
    return None


def worker_of(client):
    """The nix-daemon worker serving this client. The daemon forks one per connection, and the
    WORKER's command line carries the CLIENT pid (it runs as `nix-daemon <client-pid>`), so match
    on the worker whose argv names our client. Verified against a live pair on 2026-08-11:
    2591760 was `nix-daemon 2591741` while 2591741 was the `nix build` doing the work."""
    out = subprocess.run(["ps", "-eo", "pid=,args="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].startswith("nix-daemon") and str(client) in parts[1]:
            return int(parts[0])
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--max-jobs", type=int, default=6)
    ap.add_argument("--idle-secs", type=int, default=480)
    ap.add_argument("--poll", type=int, default=60)
    ap.add_argument("--restart", action="store_true",
                    help="terminate the CLIENT when certain; off by default")
    ap.add_argument("--relaunch-cmd", default=None,
                    help="shell command to restart the build after a kill; implies --restart")
    ap.add_argument("--max-restarts", type=int, default=5,
                    help="give up and report after this many, so a degraded daemon does not "
                         "become an endless kill and relaunch loop")
    ap.add_argument("--client-match", default=None,
                    help="argv substring identifying WHICH nix client to act on, e.g. the "
                         "flake attribute. REQUIRED with --restart: without it the watcher "
                         "would kill the first nix on the box, which on a shared machine can "
                         "belong to the user or to another session")
    a = ap.parse_args()
    if a.relaunch_cmd:
        a.restart = True
    if a.restart and not a.client_match:
        ap.error("--restart needs --client-match: killing the first nix found is how a watcher "
                 "ends somebody else's build. Report-only mode needs no match.")

    last_n, last_change = builders(a.log), time.time()
    restarts = 0
    print(f"[watch] {a.log}: {last_n} builders, idle threshold {a.idle_secs}s, "
          f"restart={'on' if a.restart else 'OFF (report only)'}"
          + (f", relaunch up to {a.max_restarts}x" if a.relaunch_cmd else ""), flush=True)

    while True:
        time.sleep(a.poll)
        n = builders(a.log)
        if n != last_n:
            last_n, last_change = n, time.time()
            continue
        idle_for = time.time() - last_change
        if idle_for < a.idle_secs:
            continue

        cp = client_pid(a.client_match)
        if cp is None:
            print(f"[watch] no nix client left, build is over at {n} builders", flush=True)
            return 0
        wp = worker_of(cp)
        if wp is None:
            print(f"[watch] {int(idle_for)}s idle at {n} builders, worker not identified",
                  flush=True)
            continue

        j1 = jiffies(wp)
        time.sleep(5)
        j2 = jiffies(wp)
        dj = (j2 - j1) if (j1 is not None and j2 is not None) else None
        z, live = children(wp)

        stalled = (dj is not None and dj < 20) and z >= a.max_jobs and live == 0
        print(f"[watch] {int(idle_for)}s with no new builder at {n}: worker {wp} "
              f"jiffies+{dj} over 5s, {z} zombie / {live} live children -> "
              f"{'STALLED' if stalled else 'still working'}", flush=True)
        if not stalled:
            continue

        print("[watch] THIS IS THE ZOMBIE-REAP STALL. It does not clear on its own.",
              flush=True)
        if not a.restart:
            print(f"[watch] reporting only. To clear it by hand: kill -TERM {cp}, then "
                  f"relaunch; the store keeps every finished derivation.", flush=True)
            return 2
        print(f"[watch] terminating CLIENT {cp}, never the daemon", flush=True)
        os.kill(cp, 15)
        if not a.relaunch_cmd:
            return 3

        # THE CAP IS THE POINT. Each cycle makes real forward progress, because every
        # finished derivation is already in the store, so relaunching is not thrash in the
        # usual sense. But if the daemon itself has gone bad the stall recurs within a few
        # builders, and then this would kill and relaunch for ever while achieving nothing.
        # Observed spread on 2026-08-10: one wedge after 3,122 builders and 45 minutes,
        # another after 14 builders and 4 minutes. So give up after a few and SAY SO: a
        # nix-daemon restart is a user action and no amount of relaunching substitutes.
        restarts += 1
        if restarts > a.max_restarts:
            print(f"[watch] {restarts - 1} relaunches already and it stalled again at {n} "
                  f"builders. This is a degraded daemon, not bad luck. A nix-daemon restart "
                  f"is a USER action. Stopping rather than looping.", flush=True)
            return 4
        time.sleep(10)
        print(f"[watch] relaunch {restarts} of {a.max_restarts}: {a.relaunch_cmd}", flush=True)
        subprocess.Popen(["setsid", "bash", "-c", a.relaunch_cmd],
                         stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # The log keeps growing across relaunches, so the baseline moves with it rather than
        # being reset; a fresh run appending its first builder line is what clears the idle.
        last_n, last_change = builders(a.log), time.time()


if __name__ == "__main__":
    sys.exit(main())
