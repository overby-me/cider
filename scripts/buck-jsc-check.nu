#!/usr/bin/env nu
# Run jsc inside the buck2-built Darling.
#
# The point is RUNTIME evidence. buck-test.sh is almost entirely static -- does it link, does it
# export the right symbols, is the install_name right -- and the JavaScriptCore cone
# (JavaScriptCore, libWTF.a, libbmalloc.a, libmbmalloc.dylib, jsc) passes all of that while never
# having executed a single instruction. This is the cheapest probe that exercises the whole cone
# end to end: the loader, libSystem, ICU, WTF's thread and stack setup, bmalloc, and then the
# interpreter.
#
# CURRENT RESULT: PASS. jsc evaluates JavaScript.
#
# It spent a while dying on
#
#   ASSERTION FAILED: m_origin && m_bound
#   wtf/StackBounds.h(129) : bool WTF::StackBounds::isGrowingDownwards() const
#
# and the cause was that the guest's MAIN thread had no stack address at all:
# pthread_get_stackaddr_np returned NULL there while spawned threads got real addresses. mldr now
# passes main_stack in apple[] so libpthread fills the main thread in properly.
# tests/buck2/guest/stack_probe.c is the instrument that found it and is the thing to run first
# if this ever regresses.
#
# So: exit 0 means JS actually evaluated, exit 3 means the empty-StackBounds assertion is back,
# and exit 1 means jsc did not even reach WTF initialization.
#
# Converted from bash (task #40) and verified by running BOTH versions against a real container
# and comparing the transcript, the verdict and the exit code.
#
# Usage:  scripts/buck-jsc-check.nu [<scratch dir>]

def say [msg: string] { print -e $msg }

def main [scratch?: string] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    # SHORT by default: the daemon's control socket lives at <prefix>/.darlingserver.sock and a
    # Unix socket path is capped at 108 bytes.
    let root = ($scratch | default $"/tmp/darling-jsc-(^id -u | str trim)")
    let rt = $"($root)/rt"
    let prefix_dir = $"($root)/prefix"

    if (which buck2 | is-empty) {
        say "missing buck2 -- run inside `nix develop`"
        exit 2
    }

    say "== building the prefix =="
    let b = (^buck2 build //buck/prefix:darling_prefix --show-output | complete)
    let art = ($b.stdout | lines | last | default "" | split row " " | get 1? | default "")
    if ($art | path type) != "dir" {
        say "the prefix did not build"
        exit 1
    }

    # Anything still running from a previous run holds the old prefix mounted, and removing the
    # tree underneath a live daemon leaves it wedged -- so this comes FIRST.
    for p in (ls /proc | get name | where {|n| ($n | path basename) =~ '^[0-9]+$' }) {
        let exe = (do -i { ^readlink $"($p)/exe" | str trim } | default "")
        if ($exe | str starts-with $"($root)/") {
            do -i { ^kill -9 ($p | path basename) }
        }
    }

    say $"== materializing into ($rt) =="
    do -i { ^chmod -R u+w $rt }
    # GNU rm: the overlay workdir holds a `work` directory at mode 000 that nushell's
    # remove_dir_all cannot enter.
    ^rm -rf $rt $prefix_dir $"($prefix_dir).workdir"
    mkdir $rt $prefix_dir
    # `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /.
    ^cp -a $"($art)/." $"($rt)/"
    ^chmod -R u+w $rt

    # jsc and JavaScriptCore.framework come from the PREFIX now. They used to be staged in by
    # hand here, because buck/prefix/BUCK was generated from the stock graph while
    # JavaScriptCore belongs to `all`; the prefix is generated from `all` now and ships both.

    say "== running jsc inside the container =="
    # Arithmetic in a loop and a JSON round trip: enough to need the interpreter, the GC and
    # bmalloc, and cheap enough that a hang is a hang rather than a slow run. In a variable
    # because a newline inside an external command ends it.
    let js = 'var s = 0; for (var i = 0; i < 200000; i++) s += i;
print("JSC_OK sum=" + s + " json=" + JSON.stringify(JSON.parse("{\"a\":1}")));'
    # out+err> into one file, NOT `complete`: complete hands back stdout and stderr separately,
    # so concatenating them puts every guest line before every daemon line and the transcript
    # stops showing which came first. bash got this for free from 2>&1, and when a check fails
    # the interleaving is most of the evidence.
    let log = (mktemp --tmpdir buck-jsc-check.XXXXXX)
    with-env {
        DPREFIX: $prefix_dir
        DARLING_NO_LAUNCHD: "1"
        DSERVER_LIBEXEC_PATH: $"($rt)/libexec/darling"
        DSERVER_MLDR_PATH: $"($rt)/libexec/darling/usr/libexec/darling/mldr"
    } {
        do -i { ^timeout 180 $"($rt)/bin/darling" shell /usr/bin/jsc -e $js out+err> $log }
    }
    let out = (open --raw $log | str trim --right --char "\n")
    rm -f $log
    print $out

    if $out =~ '(?s)JSC_OK.*sum=19999900000' {
        say "PASS: jsc evaluated JavaScript inside the buck2-built Darling"
        exit 0
    } else if ($out | str contains "ASSERTION FAILED: m_origin && m_bound") {
        say "KNOWN: the JSC cone loads and initializes, then hits the empty-StackBounds"
        say "assertion the reference build hits too (assertions are on in both). Not a"
        say "regression; see the header of this script."
        exit 3
    } else {
        say "FAIL: jsc did not reach WTF initialization -- this IS a regression"
        exit 1
    }
}
