#!/usr/bin/env nu

# WATCH A DETACHED NIX BUILD FOR THE ZOMBIE-REAP STALL, AND SAY SO OUT LOUD.
#
# WHY THIS EXISTS. The endpoint build reproducibly wedges: the daemon worker ends up holding
# exactly --max-jobs unreaped `bash <defunct>` children with ZERO live ones, the client sits in
# unix_stream_read_gen, and nothing moves again. Eight hypotheses for the cause are dead by
# measurement and the mechanism is still unknown, so this does not try to fix it. It tries to
# stop it costing an unattended hour. Observed 2026-08-10: a gate wedged at 45 minutes and 3,122
# builders and would have sat there indefinitely.
#
# IT REPORTS BY DEFAULT AND KILLS NOTHING. Pass --restart to have it terminate the CLIENT when
# it is certain, which is what a human would do: the daemon is root and restarting it is a user
# action, while the client can go and the build resumes from the store, losing no work.
#
# THREE CONDITIONS, ALL THREE REQUIRED, because each alone is ordinary:
#   1. no new `building ` line in the log for --idle-secs;
#   2. the worker burned under 20 jiffies in a 5 second sample. NOT a lifetime average: a
#      worker that did 45 real minutes before wedging still reads 42 percent while doing 0.35;
#   3. the worker holds >= --max-jobs zombie children and ZERO live ones. Zombies alone are
#      ordinary reaping lag; 3 of 6 with the daemon busy is not a stall.
#
# WHAT IT CANNOT SEE. The daemon runs as root, so /proc/<worker>/wchan reads 0 and
# /proc/<worker>/fd lists nothing, which naive code reports as "0 open files". Those are
# permission artefacts and this deliberately does not use them: a fabricated zero is worse than
# no measurement.
#
# PORTED FROM PYTHON (#98). Verified against the python on the same logs in the paths reachable
# without wedging a real build: the startup banner in report mode and in relaunch mode, both
# byte identical, and the builder count including its edge case. The stall branch itself needs a
# wedged daemon to reach honestly, and faking one would be a check that proves nothing.
#
# TWO DELIBERATE DIFFERENCES, both from argparse having no equivalent here:
#   the usage text with no log, and the wording of the --restart refusal. The RULE is the same
#   and is enforced the same way; only argparse formatting is gone.
#   A relaunch command that is a single bare word which nushell reads as a literal, `true` or a
#   number, arrives as that type rather than as a string. Real relaunch commands have spaces
#   (`nix build .#cider-buck2-one`) and are unaffected.
#
# THE BUILDER COUNT MATCHES python's EDGE CASE, which is easy to miss: python counts occurrences
# of "\nbuilding ", so a log whose FIRST line is a builder does not count it. Checked with a log
# built for it: both say 2 where the file holds three builder lines and one of them is first.
#
# THE SCOPING RULE IN client-pid IS THE MOST IMPORTANT LINE IN THIS FILE, and it earned a second
# author on 2026-08-12: I ran `pkill -x nu` elsewhere in this repo and killed the user login
# shell, the loop and my own detached suite, because -x matches by NAME across the whole machine.
# A watcher that kills the FIRST nix it finds is the same mistake with a longer fuse. So a kill
# requires --client-match, an argv substring naming the build to act on, and report-only mode
# stays unscoped because reporting on the wrong pid costs nothing.

def say [msg: string] { print $msg }

# Count of builders that RAN. Never the will-be-built list, which overstates the real work by
# nearly five times.
def builders [log: string] {
  # PARENTHESISED, because a bare `return -1` parses the value as a FLAG and the error says
  # "The `return` command doesn't have flag `-1`".
  if not ($log | path exists) { return (-1) }
  # python counts occurrences of "\nbuilding ", which requires a PRECEDING NEWLINE, so a log
  # whose very first line is a builder does not count it. grep counts that line, so the first
  # line is subtracted back out. An edge case, and cheap to be exact about.
  let n = (^grep -c '^building ' $log | complete | get stdout | str trim | into int)
  let first = (^head -c 9 $log | complete | get stdout)
  if $first == "building " { $n - 1 } else { $n }
}

# utime+stime. Sample twice and subtract; a single reading means nothing.
def jiffies [pid: int] {
  let p = $"/proc/($pid)/stat"
  if not ($p | path exists) { return null }
  let text = (open --raw $p | decode utf-8)
  # The comm field can contain spaces and parentheses, so the split is on the LAST ") ".
  let ix = ($text | str index-of --end ") ")
  if $ix < 0 { return null }
  let from = ($ix + 2)
  let f = ($text | str substring $from.. | split row " " | where {|x| $x != "" })
  if ($f | length) < 13 { return null }
  (($f | get 11 | into int) + ($f | get 12 | into int))
}

# (zombies, live) direct children, by reading ps once.
def children [pid: int] {
  let out = (^ps -eo 'ppid=,stat=' | complete | get stdout)
  mut z = 0
  mut live = 0
  for line in ($out | lines) {
    let parts = ($line | split row " " | where {|x| $x != "" })
    if ($parts | length) >= 2 and ($parts | first) == ($pid | into string) {
      if (($parts | get 1) | str starts-with "Z") { $z = $z + 1 } else { $live = $live + 1 }
    }
  }
  { z: $z, live: $live }
}

# The nix client to act on, or null. SCOPED, AND THAT MATTERS BECAUSE THIS FEEDS A KILL: see the
# header. Matching on the argv substring ties the kill to the build being watched.
def client-pid [match: string] {
  let out = (^ps -eo 'pid=,args=' | complete | get stdout)
  for line in ($out | lines) {
    let t = ($line | str trim)
    let sp = ($t | str index-of " ")
    if $sp < 1 { continue }
    let pid = ($t | str substring 0..<$sp)
    let from = ($sp + 1)
    let argv = ($t | str substring $from.. | str trim)
    let cmd = ($argv | split row " " | first | path basename)
    if $cmd != "nix" { continue }
    if ($match != "") and (not ($argv | str contains $match)) { continue }
    return ($pid | into int)
  }
  null
}

# The nix-daemon worker serving this client. The daemon forks one per connection and the
# WORKER argv carries the CLIENT pid (it runs as `nix-daemon <client-pid>`), so match on the
# worker whose argv names our client. Verified against a live pair on 2026-08-11: 2591760 was
# `nix-daemon 2591741` while 2591741 was the `nix build` doing the work.
def worker-of [client: int] {
  let out = (^ps -eo 'pid=,args=' | complete | get stdout)
  for line in ($out | lines) {
    let t = ($line | str trim)
    let sp = ($t | str index-of " ")
    if $sp < 1 { continue }
    let from = ($sp + 1)
    let argv = ($t | str substring $from..)
    if ($argv | str starts-with "nix-daemon") and ($argv | str contains ($client | into string)) {
      return ($t | str substring 0..<$sp | into int)
    }
  }
  null
}

def main [
  log?: string
  --max-jobs: int = 6
  --idle-secs: int = 480
  --poll: int = 60
  --restart                      # terminate the CLIENT when certain; off by default
  --relaunch-cmd: string = ""    # shell command to restart the build after a kill; implies --restart
  --max-restarts: int = 5        # give up and report after this many
  --client-match: string = ""    # argv substring identifying WHICH nix client to act on
] {
  if ($log | is-empty) {
    print -e "usage: buck-stall-watch.nu <log> [--max-jobs N] [--idle-secs N] [--poll N]"
    print -e "       [--restart --client-match SUBSTRING] [--relaunch-cmd CMD] [--max-restarts N]"
    exit 2
  }
  let restart = ($restart or ($relaunch_cmd != ""))
  if $restart and ($client_match == "") {
    print -e "--restart needs --client-match: killing the first nix found is how a watcher ends"
    print -e "somebody else build. Report-only mode needs no match."
    exit 2
  }

  mut last_n = (builders $log)
  mut last_change = (date now)
  mut restarts = 0
  say $"[watch] ($log): ($last_n) builders, idle threshold ($idle_secs)s, restart=(if $restart { 'on' } else { 'OFF (report only)' })(if $relaunch_cmd != '' { $', relaunch up to ($max_restarts)x' } else { '' })"

  loop {
    sleep ($poll * 1sec)
    let n = (builders $log)
    if $n != $last_n {
      $last_n = $n
      $last_change = (date now)
      continue
    }
    let idle_for = (((date now) - $last_change) / 1sec)
    if $idle_for < $idle_secs { continue }

    let cp = (client-pid $client_match)
    if $cp == null {
      say $"[watch] no nix client left, build is over at ($n) builders"
      exit 0
    }
    let wp = (worker-of $cp)
    if $wp == null {
      say $"[watch] ($idle_for | math floor)s idle at ($n) builders, worker not identified"
      continue
    }

    let j1 = (jiffies $wp)
    sleep 5sec
    let j2 = (jiffies $wp)
    let dj = (if $j1 != null and $j2 != null { $j2 - $j1 } else { null })
    let c = (children $wp)

    let stalled = ($dj != null and $dj < 20 and $c.z >= $max_jobs and $c.live == 0)
    say $"[watch] ($idle_for | math floor)s with no new builder at ($n): worker ($wp) jiffies+($dj) over 5s, ($c.z) zombie / ($c.live) live children -> (if $stalled { 'STALLED' } else { 'still working' })"
    if not $stalled { continue }

    say "[watch] THIS IS THE ZOMBIE-REAP STALL. It does not clear on its own."
    if not $restart {
      say $"[watch] reporting only. To clear it by hand: kill -TERM ($cp), then relaunch; the store keeps every finished derivation."
      exit 2
    }
    say $"[watch] terminating CLIENT ($cp), never the daemon"
    # BY PID, and by a pid that was chosen with --client-match. Never by name.
    ^kill -15 $cp
    if $relaunch_cmd == "" { exit 3 }

    # THE CAP IS THE POINT. Each cycle makes real forward progress, because every finished
    # derivation is already in the store, so relaunching is not thrash in the usual sense. But
    # if the daemon itself has gone bad the stall recurs within a few builders, and then this
    # would kill and relaunch for ever while achieving nothing. Observed spread on 2026-08-10:
    # one wedge after 3,122 builders and 45 minutes, another after 14 builders and 4 minutes.
    # So give up after a few and SAY SO: a nix-daemon restart is a user action.
    $restarts = $restarts + 1
    if $restarts > $max_restarts {
      say $"[watch] ($restarts - 1) relaunches already and it stalled again at ($n) builders. This is a degraded daemon, not bad luck. A nix-daemon restart is a USER action. Stopping rather than looping."
      exit 4
    }
    sleep 10sec
    say $"[watch] relaunch ($restarts) of ($max_restarts): ($relaunch_cmd)"
    ^setsid bash -c $relaunch_cmd out+err> /dev/null
    # The log keeps growing across relaunches, so the baseline moves with it rather than being
    # reset; a fresh run appending its first builder line is what clears the idle.
    $last_n = (builders $log)
    $last_change = (date now)
  }
}
