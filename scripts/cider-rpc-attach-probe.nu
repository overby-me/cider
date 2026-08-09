#!/usr/bin/env nu
# Measure ciderd overhead by attaching strace to the DAEMON itself (which lives outside
# the emulated process's user namespace, so its RPC-handling syscalls are actually visible --
# strace-ing `cider shell` only sees the launcher). Spawns N short-lived macho processes and
# reports the daemon's own syscall histogram, which is where per-process emulation overhead
# shows up.
#
# This is the before/after tool for perf work. It found getpid+getuid+getgid = 83% of
# ciderd syscalls (ucred filled per message), fixed in
# patches/ciderd/0002-cache-ciderd-own-credentials.
#
# Converted from bash (task #40) and verified against it with cider, strace, pgrep and pkill
# stubbed, no container: the two workload markers, the histogram passthrough, and the identity
# arithmetic over a canned strace -c table, including the case where the table has no identity
# rows at all. Output identical.
#
#   DARLING=./result/bin/cider STRACE=$(command -v strace) DPREFIX=$HOME/.dbash \
#     N=200 scripts/cider-rpc-attach-probe.nu

def main [
    # A FLAG, not the OUT environment variable the bash version took, and that is forced.
    # nushell resolves $env case-insensitively, and a nix shell exports a lowercase `out`
    # (the derivation output path). Setting OUT= and reading it back from nushell gives the
    # NIX value, whichever spelling is used and whether the lookup is $env.OUT, `get -o OUT`
    # or an exact transpose. Measured all three. So every artifact silently went to
    # <repo>/outputs/out instead of where the caller asked, and a flag is the only honest fix.
    --out: string = "/tmp/cider-rpc-probe"
] {
    let cider = ($env | get -o DARLING | default "cider")
    let strace = ($env | get -o STRACE | default "strace")
    let prefix = ($env | get -o DPREFIX | default ($env.HOME | path join ".dperf"))
    let n = (($env | get -o N | default "200") | into int)
    let workload = ($env | get -o WORKLOAD | default "uname >/dev/null 2>&1")
    mkdir $out

    for p in [ciderd mldr] { do -i { ^pkill -9 -x $p } }
    sleep 2sec

    # Launch the workload container in the background: N iterations of the workload, each a
    # full macho process spawn (task/thread registration plus startup RPCs). job spawn, because
    # nushell has no background ampersand.
    let loop_sh = $"echo LOOP_START; i=0; while [ $i -lt ($n) ]; do ($workload); i=$\(\($i+1)); done; echo LOOP_DONE"
    let loop_out = $"($out)/loop.out"
    let job = (job spawn { with-env {DPREFIX: $prefix} { do -i { ^$cider shell sh -c $loop_sh out+err> $loop_out } } })

    # Bounded busy-wait for the daemon to appear, then attach and count. SIGINT (not KILL) so
    # strace flushes its -c summary on detach.
    mut ds = ""
    mut c = 0
    while ($ds | is-empty) and $c < 2000000 {
        $ds = (do -i { ^pgrep -x ciderd | lines | first } | default "")
        $c = $c + 1
    }
    print $"ciderd pid=($ds)"
    # Immutable copy: a closure cannot capture a mut.
    let ds_pid = $ds
    let trace = $"($out)/ds.strace"
    do -i { ^timeout -s INT -k5 35 $strace -f -c -p $ds_pid -o $trace e> /dev/null }

    print "=== workload markers ==="
    # Captured and printed, NOT left as the value of an if block: an external whose output is
    # the value of a block gets that value discarded, so the markers silently vanished. At the
    # top level of a script the same call prints, which is what made this easy to miss.
    if ($loop_out | path exists) {
        print -n (do -i { ^grep -aE 'LOOP_START|LOOP_DONE' $loop_out } | complete | get stdout)
    }
    print $"=== ciderd syscall histogram over ($n) spawns ==="
    if ($trace | path exists) { print (open --raw $trace | str trim --right --char "\n") }

    # strace -c puts the syscall name last and the call count two columns before it. Skip the
    # three header lines, exactly as the awk did.
    let rows = (if ($trace | path exists) { open --raw $trace | lines | skip 3 } else { [] })
    let id3 = (
        $rows
        | each {|l| $l | split row --regex '\s+' | where {|w| $w != "" } }
        | where {|w| ($w | length) >= 3 }
        | where {|w| ($w | last) in [getpid getuid getgid] }
        | each {|w| ($w | get (($w | length) - 3)) | into int }
        # 0 prepended: math sum errors on an empty list, and a trace with no identity rows is
        # exactly what a fixed daemon looks like.
        | prepend 0
        | math sum
    )
    let totrow = (
        (if ($trace | path exists) { open --raw $trace | lines } else { [] })
        | each {|l| $l | split row --regex '\s+' | where {|w| $w != "" } }
        | where {|w| ($w | length) >= 3 and ($w | last) == "total" }
    )
    let tot = (if ($totrow | is-empty) { "" } else { ($totrow | first | get (($totrow | first | length) - 3)) })
    print $"=== identity syscalls \(getpid+getuid+getgid)=($id3)  total=($tot) ==="
    do -i { job kill $job }
    for p in [ciderd mldr] { do -i { ^pkill -9 -x $p } }
}
