#!/usr/bin/env nu
# build-hello-under-darling.nu: build GNU hello 2.12.3 from source *inside*
# rootless Darling with the x86_64-darwin bootstrap toolchain, and run it.
# This is campaign milestone M1: `pkgs.hello` builds from source and runs under
# Darling (the "builds" half; M0 is the "runs" half). It needs the dup2->EBADF
# fix (patches/xnu/0006) to get GNU hello's ./configure past its dup2 check.
#
# It runs the whole ./configure && make && ./hello in ONE `darling shell`
# session (rootless cannot re-join a container; see PLAN.md), staging
# the bootstrap-tools, the apple-sdk and the hello tarball through Darling's
# host-root mount (/Volumes/SystemRoot), building in the writable container
# $HOME with a writable TMPDIR, and forcing CONFIG_SHELL to the bootstrap bash
# (the host shell path leaks in and does not exist inside the container).
#
# Env overrides: DARLING (darling binary), DPREFIX (short prefix path),
# BOOTSTRAP_TOOLS, APPLE_SDK, HELLO_SRC (store paths), NIXPKGS_REV.
#
# Converted from bash (task #40). The GUEST script stays sh and is embedded verbatim, with the
# host-side substitutions the unquoted heredoc used to do now written as explicit
# interpolations. Verified against the bash version with nix, nix copy and the darling binary
# stubbed, no container and no network: a successful build, a run whose hello_rc is not 0, a
# container that never reaches the UNTAR marker (the retry path), and the noise filter.

def say [msg: string] { print -e $msg }

def main [] {
    let repo = ($env.FILE_PWD | path join ".." | path expand)
    let darling = ($env.DARLING? | default "darling")
    let prefix = ($env.DPREFIX? | default "/tmp/dhb")
    # Boot is reliable under the Rust daemon (#44); set RETRIES>1 to re-enable the old
    # busy-spin retry.
    let retries = (($env.RETRIES? | default "1") | into int)
    let nixpkgs_rev = ($env.NIXPKGS_REV? | default "fd1462031fdee08f65fd0b4c6b64e22239a77870")
    let cache = "https://cache.nixos.org"

    let bt = ($env.BOOTSTRAP_TOOLS?
        | default "/nix/store/v6wk45fap70cgcw88x4ilzkiwzhwq6r0-bootstrap-tools")
    let sdk_root = ($env.APPLE_SDK?
        | default "/nix/store/dfd1kijwi4r02dk8ridqwmx1vzfg7dik-apple-sdk-14.4")
    let hello_src = if (($env.HELLO_SRC? | default "") | is-not-empty) {
        $env.HELLO_SRC
    } else {
        ^nix eval --raw $"github:NixOS/nixpkgs/($nixpkgs_rev)#legacyPackages.x86_64-darwin.hello.src"
        | str trim
    }

    # Substitute prerequisites from the binary cache if missing (host-side).
    for p in [$bt $sdk_root $hello_src] {
        if not ($p | path exists) { do -i { ^nix copy --from $cache $p --no-check-sigs } }
    }

    let sdk = $"($sdk_root)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX14.4.sdk"

    # The build script that runs inside the container.
    let work = (mktemp --directory --tmpdir-path /tmp dhb.XXXXXX)
    let build_sh = $"($work)/build.sh"
    let guest_template = '#!/bin/sh
BT=@BTPATH@
SDK=@SDKPATH@
HSRC=@HSRCPATH@
export PATH="$BT/bin:/usr/bin:/bin"
export SDKROOT="$SDK" CC=clang
export CFLAGS="-isysroot $SDK -Wno-implicit-function-declaration"
export LDFLAGS="-isysroot $SDK"
export CONFIG_SHELL="$BT/bin/bash" SHELL="$BT/bin/bash"
unset CONFIG_SITE
cd "$HOME" || exit 9
rm -rf hbuild; mkdir -p hbuild tmp; export TMPDIR="$HOME/tmp"
cd hbuild || exit 9
echo "=UNTAR="; tar xzf "$HSRC" && echo untar_ok || { echo TAR_FAIL; exit 1; }
cd hello-2.12.3 || { echo NO_SRCDIR; exit 1; }
echo "=CONFIGURE="; "$CONFIG_SHELL" ./configure >conf.log 2>&1; echo "configure_rc=$?"; tail -3 conf.log
echo "=MAKE="; make >make.log 2>&1; echo "make_rc=$?"; tail -4 make.log
echo "=RUN="; ./hello; echo "hello_rc=$?"'
    let guest = ($guest_template
        | str replace --all "@BTPATH@" $"/Volumes/SystemRoot($bt)"
        | str replace --all "@SDKPATH@" $"/Volumes/SystemRoot($sdk)"
        | str replace --all "@HSRCPATH@" $"/Volumes/SystemRoot($hello_src)")
    $"($guest)\n" | save -f $build_sh
    let gbuild = $"/Volumes/SystemRoot($build_sh)"

    mut ok = false
    mut reached = false
    for i in 1..$retries {
        for n in [darlingserver mldr] { do -i { ^pkill -9 -x $n } }
        sleep 1sec
        let log = (mktemp --tmpdir-path /tmp dhb-out.XXXXXX)
        with-env {DPREFIX: $prefix} {
            do -i { ^timeout 1500 $darling shell sh $gbuild out+err> $log }
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
            $ok = ($out | str contains "hello_rc=0")
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
