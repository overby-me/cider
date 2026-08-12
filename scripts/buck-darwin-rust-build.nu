#!/usr/bin/env nu

# BUILD A DARWIN (MACH-O) RUST BINARY ON LINUX, USING CIDER OWN ld64. Task #96 route A.
#
# PROVEN 2026-08-12: this produces a Mach-O 64-bit x86_64 executable with
# NOUNDEFS|DYLDLINK|TWOLEVEL|PIE|HAS_TLV_DESCRIPTORS. Whether it RUNS under cider is a separate
# question; scripts/buck-darwin-rust-run.nu answers that one.
#
# THE FOUR THINGS THAT MAKE IT WORK, each of which was a dead end on its own:
#
# 1. USE THE OFFICIAL rustc, NOT THE NIXPKGS ONE. This is the whole reason route A looked
#    impossible. Both are release 1.95.0 at commit 59807616e, but nixpkgs appends a suffix to its
#    version string, and the crate-metadata check is a STRING COMPARE:
#
#      error[E0514]: found crate `std` compiled by an incompatible version of rustc
#        found: rustc 1.95.0 (59807616e 2026-04-14)
#        ours:  rustc 1.95.0 (59807616e 2026-04-14) (built from a source tarball)
#
#    Same compiler, same commit, rejected on the parenthetical. Take BOTH halves from upstream
#    and they match. Nothing about Darwin, LLVM or linking was ever the problem.
#
# 2. NIXPKGS CANNOT SUPPLY THIS, and the reason is narrower than "unsupported". Evaluating
#    pkgsCross.x86_64-darwin.rustc fails with
#
#      Refusing to evaluate package x86_64-apple-darwin-cctools-1010.6 ... hostPlatform.system
#      = "x86_64-linux"
#
#    It is CCTOOLS that nixpkgs will not provide on a Linux host, not rustc. cider builds its own
#    cctools and ld64 (#65), so the one package nixpkgs refuses is the one we already have.
#
# 3. -syslibroot IS MANDATORY. libSystem.dylib re-exports /usr/lib/system/*.dylib by ABSOLUTE
#    path, so without it ld64 looks on the Linux host and dies with
#
#      ld: file not found: /usr/lib/system/libsystem_sandbox.dylib
#
#    Point it at the cider prefix root and the whole re-export chain resolves.
#
# 4. -C linker-flavor=ld, because rustc otherwise drives a cc wrapper that does not exist here.
#
# THE xcrun WARNING IS HARMLESS. rustc shells out to xcrun to find an SDK and cannot; it only
# affects the SDK version stamped into the binary. Set SDKROOT to silence it if that matters.
#
# Usage:
#   scripts/buck-darwin-rust-build.nu <source.rs> <output> --rustc R --sysroot S --prefix P --ld L
#
# PORTED FROM PYTHON (#98). THE GATE IS THE ARGV, not the bytes, and that is a measurement rather
# than a convenience: two runs of the PYTHON over one source differ in 15 bytes, and the only
# load-command difference is LC_UUID, which ld64 derives per link. So a byte comparison would
# fail for both implementations equally and prove nothing. What this script actually decides is
# the command line, so the ported version was gated on producing a CHARACTER-IDENTICAL rustc
# invocation, and on its output differing from the python one only in that 16 byte uuid.

const TARGET = "x86_64-apple-darwin"

def say [msg: string] { print $msg }

def main [
    source: string           # the .rs to build
    output: string           # where to write the Mach-O
    --rustc: string          # OFFICIAL rustc, not the nixpkgs one; see 1 above
    --sysroot: string        # merged: official rustc libs + Darwin rust-std
    --prefix: string         # cider prefix root, the dir holding usr/lib
    --ld: string             # the buck2-built x86_64-apple-darwin20-ld
] {
    for pair in [[what, path]; ["rustc", $rustc] ["ld64", $ld]] {
        if ($pair.path | is-empty) or not ($pair.path | path exists) {
            say $"FAIL: no ($pair.what) at ($pair.path)"
            exit 2
        }
    }
    let libdir = ([$sysroot "lib" "rustlib" $TARGET "lib"] | path join)
    if ($libdir | path type) != "dir" {
        say $"FAIL: sysroot has no ($TARGET) libdir at ($libdir)"
        exit 2
    }

    # `path expand` is os.path.abspath here: rustc is run with the caller cwd, and a relative
    # sysroot or prefix would resolve against it rather than against the repo.
    let cmd = [
        $rustc "--target" $TARGET "--sysroot" ($sysroot | path expand)
        "-C" "linker-flavor=ld"
        "-C" $"linker=($ld)"
        "-C" "link-arg=-syslibroot" "-C" $"link-arg=($prefix | path expand)"
        "-C" "link-arg=-lSystem"
        "-o" $output $source
    ]
    say $"  ($cmd | str join ' ')"
    # STDERR IS NOT DISCARDED, and not captured either. The linker diagnostics are the whole
    # value when this fails, and `complete` would buffer them out of order with rustc stdout.
    let rc = (do -i { ^($cmd | first) ...($cmd | skip 1) } | complete | get exit_code)
    if $rc != 0 {
        say $"FAIL: rustc exited ($rc)"
        exit 1
    }

    # VERIFY THE ARTIFACT, not the exit code. A linker can exit 0 and leave the wrong format.
    let f = (do -i { ^file -b $output } | str trim)
    say $"  ($output): ($f)"
    if not ($f | str contains "Mach-O 64-bit x86_64 executable") {
        say "FAIL: output is not a Mach-O x86_64 executable"
        exit 1
    }
    say "PASS: built a Darwin Mach-O executable from Rust on Linux"
    exit 0
}
