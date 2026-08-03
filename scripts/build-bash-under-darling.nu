#!/usr/bin/env nu
# Build GNU bash from source inside a Darling container using the 26.05
# bootstrap-tools clang + apple-sdk-14.4, then run it. Mirrors
# build-hello-under-darling.nu; bash is a much larger configure/make and
# exercises far more of libSystem (signals, job control, termios, locale).
#
# Converted from bash (task #40). The GUEST script stays sh and is embedded VERBATIM in a raw
# r-string, because it carries both quote kinds; the four host-side substitutions the unquoted
# heredoc used to do are explicit placeholders now. Verified against the bash version with nix
# and darling stubbed, no container and no network: a successful build, a run whose run_rc is
# not 0, a transcript that never reaches UNTAR so the retries run out, the noise filter, and a
# byte-for-byte diff of the STAGED guest script, which is what actually does the work.

def say [msg: string] { print -e $msg }

def main [] {
    let darling = ($env.DARLING? | default "darling")
    let prefix = ($env.DPREFIX? | default ($env.HOME | path join ".dbash"))
    # Boot is reliable under the Rust daemon (#44); set RETRIES>1 to re-enable the old
    # busy-spin retry.
    let retries = (($env.RETRIES? | default "1") | into int)
    let nixpkgs_rev = ($env.NIXPKGS_REV? | default "fd1462031fdee08f65fd0b4c6b64e22239a77870")
    let cache = "https://cache.nixos.org"

    let bt = ($env.BOOTSTRAP_TOOLS?
        | default "/nix/store/v6wk45fap70cgcw88x4ilzkiwzhwq6r0-bootstrap-tools")
    let sdk_root = ($env.APPLE_SDK?
        | default "/nix/store/dfd1kijwi4r02dk8ridqwmx1vzfg7dik-apple-sdk-14.4")
    let bash_src = if (($env.BASH_SRC? | default "") | is-not-empty) {
        $env.BASH_SRC
    } else {
        ^nix eval --raw $"github:NixOS/nixpkgs/($nixpkgs_rev)#legacyPackages.x86_64-darwin.bash.src"
        | str trim
    }
    let ncurses = if (($env.NCURSES? | default "") | is-not-empty) {
        $env.NCURSES
    } else {
        ^nix eval --raw $"github:NixOS/nixpkgs/($nixpkgs_rev)#legacyPackages.x86_64-darwin.ncurses.outPath"
        | str trim
    }

    for p in [$bt $sdk_root $bash_src $ncurses] {
        if not ($p | path exists) { do -i { ^nix copy --from $cache $p --no-check-sigs } }
    }
    let sdk = $"($sdk_root)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX14.4.sdk"

    let work = (mktemp --directory --tmpdir-path /tmp dbash.XXXXXX)
    let build_sh = $"($work)/build.sh"
    let guest_template = r##'#!/bin/sh
BT=@BTPATH@
SDK=@SDKPATH@
BSRC=@BSRCPATH@
NC=@NCPATH@
export PATH="$BT/bin:/usr/bin:/bin"
export SDKROOT="$SDK" CC=clang
# -fcommon: some readline globals are tentative defs; modern clang defaults to -fno-common,
# which turns them into hard duplicate symbols at link. -fcommon keeps them mergeable.
# -I/-L point at the system curses (ncurses) so bash's configure finds tgetent there and uses
# ncurses/libtinfo for termcap (which exports BC/UP/PC/ospeed), instead of its bundled fallback.
export CFLAGS="-isysroot $SDK -Wno-implicit-function-declaration -Wno-error -fcommon -I$NC/include"
export LDFLAGS="-isysroot $SDK -L$NC/lib"
export CONFIG_SHELL="$BT/bin/bash" SHELL="$BT/bin/bash"
unset CONFIG_SITE
cd "$HOME" || exit 9
rm -rf bbuild; mkdir -p bbuild tmp; export TMPDIR="$HOME/tmp"
cd bbuild || exit 9
echo "=UNTAR="; tar xzf "$BSRC" && echo untar_ok || { echo TAR_FAIL; exit 1; }
cd bash-5.3 || { echo NO_SRCDIR; exit 1; }
echo "=CONFIGURE="; "$CONFIG_SHELL" ./configure --without-bash-malloc >conf.log 2>&1; echo "configure_rc=$?"; tail -3 conf.log
echo "=MAKE="; make >make.log 2>&1; echo "make_rc=$?"; tail -4 make.log
echo "=VER="; ./bash --version 2>&1 | head -1; echo "ver_rc=$?"
echo "=RUN="; ./bash -c 'echo BASH_RUNS_OK; x=2; echo sum=$((x+3)); for i in a b c; do printf "%s" "$i"; done; echo'; echo "run_rc=$?"'##
    let guest = ($guest_template
        | str replace --all "@BTPATH@" $"/Volumes/SystemRoot($bt)"
        | str replace --all "@SDKPATH@" $"/Volumes/SystemRoot($sdk)"
        | str replace --all "@BSRCPATH@" $"/Volumes/SystemRoot($bash_src)"
        | str replace --all "@NCPATH@" $"/Volumes/SystemRoot($ncurses)")
    $"($guest)\n" | save -f $build_sh
    let gbuild = $"/Volumes/SystemRoot($build_sh)"

    mut ok = false
    mut reached = false
    for i in 1..$retries {
        for n in [darlingserver mldr] { do -i { ^pkill -9 -x $n } }
        sleep 1sec
        let log = (mktemp --tmpdir-path /tmp dbash-out.XXXXXX)
        with-env {DPREFIX: $prefix} {
            do -i { ^timeout 2400 $darling shell sh $gbuild out+err> $log }
        }
        let out = (open --raw $log)
        rm -f $log
        if ($out | str contains "=UNTAR=") {
            $reached = true
            $out
            | lines
            | where {|l| not ($l =~ 'Cannot chown|failed to increase FD rlimit|semaphore_timedwait failed|dserver_rpc|mach_msg_overwrite') }
            | each {|l| print $l }
            do -i { ^pkill -9 -x darlingserver }
            $ok = ($out | str contains "run_rc=0")
            break
        }
    }
    rm -rf $work
    if $reached {
        exit (if $ok { 0 } else { 1 })
    }
    say $"failed to get a working Darling shell after ($retries) tries"
    do -i { ^pkill -9 -x darlingserver }
    exit 1
}
