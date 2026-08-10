#!/usr/bin/env nu
# build-hello-bypass.nu -- Campaign M1, rootless and launchd-FREE.
#
# Guest Nix, running under Darling with launchd BYPASSED, builds GNU hello FROM SOURCE (the
# official `nix build ...#hello`) and runs it. No LKM, no launchd boot -- shellspawn runs
# directly as the guest PID1 via ciderd's DSERVER_INIT hook, so we never hit launchd's
# (still-open) portset/kqueue bootstrap deadlock (task #47).
#
# Why a bypass: `cider shell` normally waits for shellspawn, which launchd brings up during
# `launchctl bootstrap -S System` -- and that bootstrap deadlocks in ciderd mode.
# shellspawn itself is a standalone unix-socket daemon with no launchd/mach-bootstrap
# dependency, so we run it as PID1 directly.
#
# The guest-side driver is scripts/gnix-hello.sh; this script is the HOST-side orchestration
# (build cider, seed the store db, two-boot the bypass container).
#
# Converted from bash (task #40) and verified the same way its generic sibling was: with nix,
# nix-store and the cider binary stubbed on PATH, no container and no network. Both versions
# were driven over a successful M1 transcript, one missing the Hello line, one missing
# build_rc=0, the two noisy lines the filter drops, a cider that is not there, a dump-db that
# fails, and a warm-up boot that leaves no skeleton. Same output and same exit code on all of
# them EXCEPT the two that are a deliberate fix, described next.
#
# THE BASH VERSION COULD NOT FAIL when the container exited 0. Its last line was
#
#   grep -qa Hello && grep -qa build_rc=0 && rc=0 || rc=${rc:-1}
#
# and rc was already set from the guest invocation, so ${rc:-1} kept THAT, not 1. A transcript
# with no Hello line, or none saying build_rc=0, still exited 0 as long as cider itself
# returned 0 -- which it does whenever the guest driver runs to completion and merely reports a
# failed build. Reproduced both ways with a stub; this version exits 1, which is what the two
# assertions were for.
#
# An unknown argument also diverges: nushell rejects it with its own message and exit 1 where
# bash printed unknown arg and exited 2.
#
# Usage:
#   scripts/build-hello-bypass.nu [--mono <cider-store-path>] [--prefix <dir>]

def say [msg: string] { print -e $msg }

# One name per pkill call: a multi-pattern pkill matches nothing and exits 2. -x, never -f.
def kill_all [] {
    for n in [cider ciderd mldr shellspawn] { do -i { ^pkill -9 -x $n } }
}

def main [
    --mono: string = ""      # a cider store path to use instead of building one
    --prefix: string = ""    # the guest prefix directory
] {
    let repo = ($env.FILE_PWD | path join ".." | path expand)
    let prefix = if ($prefix | is-not-empty) {
        $prefix
    } else {
        $env.DPREFIX? | default "/tmp/cider-hello-m1"
    }
    # nixpkgs 26.05 x86_64-darwin pins (match scripts/gnix-hello.sh defaults).
    let hello_drv = ($env.HELLO_DRV?
        | default "/nix/store/yc10hxdna1mi7a8b96azgyg3prfi72ns-hello-2.12.3.drv")
    let nixbin = ($env.NIXBIN? | default "/nix/store/fw9y98mcqkksxyah45mmbsrvaxxv7r6x-nix-2.34.8/bin")

    # 1. Darling build (monolith; ?submodules=1 picks up the committed submodules plus the
    #    campaign working-tree fixes).
    mut monopath = $mono
    if ($monopath | is-empty) {
        print "== building cider (nix build '.?submodules=1#default') =="
        let r = (do -i { cd $repo; ^nix build '.?submodules=1#default' --no-link
            --print-out-paths } | complete)
        $monopath = ($r.stdout | lines | last | default "")
        if $r.exit_code != 0 or ($monopath | is-empty) {
            say "cider build failed"
            exit 1
        }
    }
    if not ($"($monopath)/bin/cider" | path exists) {
        say $"no cider at ($monopath)/bin/cider"
        exit 1
    }
    # Immutable from here: a closure cannot capture a mut, and every container call is one.
    let cider = $"($monopath)/bin/cider"
    print $"MONO=($monopath)"

    # 2. Seed data: dump the host valid-paths DB for hello.drv's FULL closure WITH outputs (so
    #    guest nix trusts the substituted build inputs -- present via the writable-/nix overlay
    #    lower -- and knows how to build hello.drv itself).
    # -p, because nushell mktemp rejects a template containing a directory separator.
    let dump = (mktemp --tmpdir-path /tmp hello-db.XXXXXX.dump)
    print $"== dumping hello.drv closure db -> ($dump) =="
    let closure = (do -i { ^nix-store -qR --include-outputs $hello_drv } | complete
        | get stdout | lines | uniq | sort)
    # try/catch, NOT `do -i`, and not `| complete`: complete rejects a block whose command
    # redirects ("Complete only works with external commands"), and do -i swallows the failure
    # so LAST_EXIT_CODE reads 0 even when the command exited 3. Measured both ways.
    let dumped = (try { ^nix-store --dump-db ...$closure out> $dump; true } catch { false })
    if not $dumped {
        say "dump-db failed"
        exit 1
    }

    let genv = {
        HELLO_DB_DUMP: $dump
        HELLO_DRV: $hello_drv
        NIXBIN: $nixbin
        # The launchd bypass (first-class env; runs shellspawn as guest PID1 instead of launchd)
        DARLING_NO_LAUNCHD: "1"
        # DELIBERATELY still the DARLING_ name: this is what keeps the compat fallback in
        # linux/launcher/src/main.rs EXERCISED. If every setter moved to CIDER_, a broken
        # fallback would never be caught. Move this only when the fallbacks are dropped.
        DARLING_SHELL_STARTUP_TIMEOUT: "90"
        DPREFIX: $prefix
    }

    # 3. Warm-up boot: create the prefix skeleton (writable host-visible /var/run via
    #    setupPrefix -- must be a real overlay-upper dir, NOT a tmpfs). Let cider create the
    #    prefix (a pre-created dir makes checkPrefixDir skip the skeleton).
    kill_all
    sleep 2sec
    if ($"($prefix)/var/run" | path type) != "dir" {
        print "== warm-up boot (skeleton + one-time chown) =="
        with-env $genv {
            do -i { ^timeout --signal=KILL 300 $cider shell true out+err> /tmp/hello-warmup.out }
        }
        if ($"($prefix)/var/run" | path type) != "dir" {
            say "skeleton not created; see /tmp/hello-warmup.out"
            exit 1
        }
        kill_all
        sleep 3sec
    }

    # 4. Enable the writable native /nix overlay, then build+run hello in ONE guest shell
    #    session (rootless runs one command per fresh container -- no re-join).
    touch $"($prefix)/.enable-writable-nix"
    print "== M1 build: guest nix builds+runs hello (launchd bypassed) =="
    # Write to a FILE, never a pipe: a leaked container holds the pipe write-end open so a
    # reader would block on EOF forever. Read the file after teardown.
    let out = (mktemp --tmpdir-path /tmp hello-build.XXXXXX.out)
    let guest_driver = $"/Volumes/SystemRoot($repo)/scripts/gnix-hello.sh"
    # Same reason: do -i would report 0 for a guest that died, and bash kept the real status.
    let guest_rc = (with-env $genv {
        # catch stays on the same line as try's closing brace, for the same reason a
        # redirection cannot start a continuation line: the newline ends the expression.
        try { ^timeout --signal=KILL 1200 $cider shell sh $guest_driver out+err> $out; 0 } catch { $env.LAST_EXIT_CODE }
    })
    kill_all
    # The external grep, and -a: the transcript can carry bytes that are not UTF-8.
    do -i { ^grep -avE 'Cannot chown|failed to increase FD rlimit' $out }
    let said_hello = (do -i { ^grep -qaE '^Hello, world!$' $out } | complete | get exit_code) == 0
    let built = (do -i { ^grep -qaE 'build_rc=0' $out } | complete | get exit_code) == 0
    let rc = if $said_hello and $built { 0 } else if $guest_rc != 0 { $guest_rc } else { 1 }
    rm -f $dump $out
    print $"== done \(exit ($rc)). Expect: build_rc=0 and 'Hello, world!' above. =="
    exit $rc
}
