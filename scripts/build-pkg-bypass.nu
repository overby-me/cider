#!/usr/bin/env nu
# build-pkg-bypass.nu -- build ANY nixpkgs x86_64-darwin package FROM SOURCE with guest Nix
# under Darling, rootless and launchd-FREE, then run it.
#
# Generalises scripts/build-hello-bypass.nu (the M1 reference) to an arbitrary attr via the
# generic guest driver scripts/gnix-build.sh. The launchd bypass is DARLING_NO_LAUNCHD=1
# (shellspawn as guest PID1; no launchd, no LKM).
#
# Inputs are substituted from cache.nixos.org (the deps are prebuilt darwin binaries); only
# <attr> itself is built from source, in-guest.
#
# Converted from bash (task #40). This script is ORCHESTRATION -- argument handling, four
# external stages, a transcript filter and one exit code -- so it was verified the way
# orchestration can be: with nix, nix-store and the cider binary itself stubbed on PATH, no
# container involved. Both versions were driven over a successful build, a build whose
# transcript carries no build_rc=0, a cider that is not executable, an eval that fails, a
# missing skeleton after the warm-up boot, and an unknown argument, and they agree on output
# and exit code every time. What is NOT covered that way is the container itself, which is
# scripts/buck-nix-bash-check.nu's job and which drives this.
#
# One deliberate divergence: an unknown argument. bash printed unknown arg: --x and exited 2;
# nushell parses arguments against this signature and rejects it itself, with its own message
# and exit 1. Same behaviour, different diagnostic, and not worth faking a parser to match.
#
# Usage:
#   scripts/build-pkg-bypass.nu <attr> [binname] [--mono <cider-store-path>] [--prefix <dir>]
# e.g.  scripts/build-pkg-bypass.nu hello hello
#       scripts/build-pkg-bypass.nu pv pv
# <binname> (optional) is a binary in the output's bin/ to run with --version.
# If --mono is omitted, `nix build '.?submodules=1#default'` provides cider.

# nixpkgs 26.05 pin (flake.lock)
const REV = "fd1462031fdee08f65fd0b4c6b64e22239a77870"

def say [msg: string] { print -e $msg }

# One name per pkill call: a multi-pattern pkill matches nothing and exits 2. -x, never -f,
# so the pattern cannot match the command line of the shell running it.
def kill_all [] {
    for n in [cider ciderd mldr shellspawn] { do -i { ^pkill -9 -x $n } }
}

def main [
    attr: string             # the nixpkgs attribute to build in the guest
    binname?: string         # a binary in the output bin/ to run with --version
    --mono: string = ""      # a cider store path to use instead of building one
    --prefix: string = ""    # the guest prefix directory
] {
    let repo = ($env.FILE_PWD | path join ".." | path expand)
    let bin = ($binname | default "")
    let prefix = if ($prefix | is-not-empty) {
        $prefix
    } else {
        $env.DPREFIX? | default "/tmp/cider-pkg"
    }

    # 1. cider
    mut monopath = $mono
    if ($monopath | is-empty) {
        print "== building cider =="
        let r = (do -i { cd $repo; ^nix build '.?submodules=1#default' --no-link
            --print-out-paths } | complete)
        $monopath = ($r.stdout | lines | last | default "")
        if $r.exit_code != 0 or ($monopath | is-empty) {
            say "cider build failed"
            exit 1
        }
    }
    if not ($"($monopath)/bin/cider" | path exists) {
        say $"no cider at ($monopath)"
        exit 1
    }
    # Immutable from here on: nushell refuses to capture a mut inside a closure, and every
    # container invocation below is one.
    let cider = $"($monopath)/bin/cider"

    # 2. eval the target drv from the pin
    print $"== eval ($attr).drvPath =="
    let e = (^nix eval --raw $"github:NixOS/nixpkgs/($REV)#legacyPackages.x86_64-darwin.($attr).drvPath"
        | complete)
    let drv = ($e.stdout | str trim)
    if $e.exit_code != 0 or ($drv | is-empty) {
        say $"eval failed for ($attr)"
        exit 1
    }
    print $"DRV=($drv)"
    let o = (^nix eval --raw $"github:NixOS/nixpkgs/($REV)#legacyPackages.x86_64-darwin.($attr).outPath"
        | complete)
    let outhash = ($o.stdout | str trim | path basename)

    # 3. substitute the build-input closure (everything but the target's own output)
    print "== substituting build inputs from cache =="
    let idrvs = (^nix-store -qR $drv | complete | get stdout | lines
        | where {|l| $l | str ends-with ".drv" })
    let iouts = (
        (do -i { ^nix-store -q --outputs ...$idrvs } | complete | get stdout | lines
            | where {|l| not ($l | str contains $outhash) } | uniq | sort)
    )
    # A few SDK build-tools are not cached; harmless.
    do -i { ^nix-store -r ...$iouts } | ignore
    # -p, because nushell mktemp rejects a template that contains a directory separator.
    let dump = (mktemp --tmpdir-path /tmp pkg-db.XXXXXX.dump)
    let closure = (do -i { ^nix-store -qR --include-outputs $drv } | complete | get stdout | lines)
    do -i { ^nix-store --dump-db ...$closure out> $dump }

    # 4. warm-up boot -> skeleton; then build+run in one bypass session
    kill_all
    sleep 2sec
    let genv = {
        DARLING_NO_LAUNCHD: "1"
        DARLING_SHELL_STARTUP_TIMEOUT: "90"
        GDRV: $drv
        GDB: $dump
        GBIN: $bin
        DPREFIX: $prefix
    }
    # != rather than `not ... == ...`: nushell binds not tighter than ==, so the latter tries
    # to negate a string and fails with "Can't convert to boolean".
    if ($"($prefix)/var/run" | path type) != "dir" {
        print "== warm-up boot (skeleton) =="
        # The redirection stays on the command line: on a continuation line nushell reports
        # "redirecting nothing".
        with-env $genv {
            do -i { ^timeout --signal=KILL 300 $cider shell true out+err> /tmp/pkg-warmup.out }
        }
        if ($"($prefix)/var/run" | path type) != "dir" {
            say "skeleton not created"
            rm -f $dump
            exit 1
        }
        kill_all
        sleep 3sec
    }
    touch $"($prefix)/.enable-writable-nix"
    print $"== guest nix builds ($attr) from source \(launchd bypassed) =="
    let out = (mktemp --tmpdir-path /tmp pkg-build.XXXXXX.out)
    let guest_driver = $"/Volumes/SystemRoot($repo)/scripts/gnix-build.sh"
    with-env $genv {
        do -i { ^timeout --signal=KILL 1800 $cider shell sh $guest_driver out+err> $out }
    }
    kill_all
    # Through the external grep, and -a, because the transcript can carry bytes that are not
    # UTF-8 and reading it as a nushell string would either lose or reject them.
    do -i { ^grep -avE 'Cannot chown|failed to increase FD rlimit' $out }
    let ok = (do -i { ^grep -qaE 'build_rc=0' $out } | complete | get exit_code) == 0
    rm -f $dump $out
    print $"== done \(build_rc match: (if $ok { 'yes' } else { 'NO' })) =="
    exit (if $ok { 0 } else { 1 })
}
