#!/usr/bin/env nu
# Guest Nix, running inside the BUCK2-BUILT Darling, builds GNU bash from source and runs it.
#
# This is the goal the port was aiming at, and it is a strictly bigger claim than
# scripts/buck-bash-check.nu: that one boots the container and runs the bash the port itself
# built, while this one runs a Darwin toolchain under the port well enough to COMPILE a package
# and execute the result.
#
# Everything below the container is buck2's: the daemon, the launcher, the guest loader and the
# whole prefix. Nix itself is not: it is the x86_64-darwin nix already in the host store,
# reached through the writable-/nix overlay, exactly as scripts/gnix-hello.sh describes. The
# port's job is to run it, not to build it.
#
# Converted from bash (task #40) and checked against it WITHOUT a container, by driving both in
# a scratch tree whose build-pkg-bypass.nu is a stub printing a canned transcript: the missing
# prefix (2), PASS, PARTIAL and FAIL. The verdict is the whole of this script, so the verdict is
# what was tested; the container belongs to the driver it calls.
#
# Usage:  scripts/buck-nix-bash-check.nu [<attr> [<binary>]]
# Default attr is bash. Any nixpkgs x86_64-darwin attr works, since the driver underneath
# (scripts/build-pkg-bypass.nu) is generic.

def say [msg: string] { print -e $msg }

def main [attr?: string, bin?: string] {
    cd ($env.FILE_PWD | path join ".." | path expand)
    let attr = ($attr | default "bash")
    let bin = ($bin | default "bash")

    # SHORT, because the daemon's control socket lives in the prefix and a Unix socket path is
    # capped at 108 bytes.
    let rt = ($env.BUCK2_RT? | default $"/tmp/darling-buck2-(^id -u | str trim)/rt")
    let prefix = ($env.DPREFIX? | default $"/tmp/darling-nixpkg-(^id -u | str trim)")

    if not ($"($rt)/bin/darling" | path exists) {
        say $"no materialized prefix at ($rt)"
        say "run scripts/buck-bash-check.nu first -- it builds //buck/prefix:darling_prefix and"
        say "copies it there, which is what this check then drives."
        exit 2
    }

    # The two paths the daemon reads from the environment. The cmake build bakes them in; a
    # relocatable prefix cannot, so they are passed here (same as scripts/buck-bash-check.nu).
    $env.DSERVER_LIBEXEC_PATH = $"($rt)/libexec/darling"
    $env.DSERVER_MLDR_PATH = $"($rt)/libexec/darling/usr/libexec/darling/mldr"

    say $"== guest nix builds ($attr) under the buck2-built Darling =="
    # out+err> into one file, NOT `complete`: complete hands back stdout and stderr separately,
    # so concatenating them reorders the driver's transcript, and this check reads that
    # transcript for build_rc and run_rc IN ORDER. Trailing newlines stripped as $(...) does in
    # bash, so print adds exactly one back rather than a blank line per run.
    let log = (mktemp --tmpdir buck-nix-bash-check.XXXXXX)
    do -i { ^./scripts/build-pkg-bypass.nu $attr $bin --mono $rt --prefix $prefix out+err> $log }
    let out = (open --raw $log | str trim --right --char "\n")
    rm -f $log
    print $out

    # build_rc=0 alone is not enough: the driver retries, and a stale valid output in the store
    # would let a build "succeed" without having run. The version line proves the binary the
    # guest produced actually executed. The (?s) matters: these are two lines of a transcript,
    # and the order between them is the difference between PASS and PARTIAL.
    if $out =~ '(?s)build_rc=0.*run_rc=0' {
        say $"PASS: guest nix built and ran ($attr) inside the buck2-built Darling"
        exit 0
    } else if $out =~ 'build_rc=0' {
        say $"PARTIAL: ($attr) built but did not run"
        exit 1
    } else {
        say $"FAIL: guest nix did not build ($attr)"
        exit 1
    }
}
