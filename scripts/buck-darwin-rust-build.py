#!/usr/bin/env python3
"""Build a Darwin (Mach-O) Rust binary on Linux, using cider's own ld64. Task #96 route A.

PROVEN 2026-08-12: this produces a Mach-O 64-bit x86_64 executable with
NOUNDEFS|DYLDLINK|TWOLEVEL|PIE|HAS_TLV_DESCRIPTORS. Whether it RUNS under cider is a separate
question; see the runtime note at the bottom.

THE FOUR THINGS THAT MAKE IT WORK, each of which was a dead end on its own:

1. USE THE OFFICIAL rustc, NOT THE NIXPKGS ONE. This is the whole reason route A looked
   impossible. Both are release 1.95.0 at commit 59807616e, but nixpkgs appends a suffix to its
   version string, and rustc's crate-metadata check is a STRING COMPARE:

     error[E0514]: found crate `std` compiled by an incompatible version of rustc
       found: rustc 1.95.0 (59807616e 2026-04-14)
       ours:  rustc 1.95.0 (59807616e 2026-04-14) (built from a source tarball)

   Same compiler, same commit, rejected on the parenthetical. Take BOTH halves from upstream and
   they match. Nothing about Darwin, LLVM or linking was ever the problem.

2. NIXPKGS CANNOT SUPPLY THIS, and the reason is narrower than "unsupported". Evaluating
   pkgsCross.x86_64-darwin.rustc fails with

     Refusing to evaluate package 'x86_64-apple-darwin-cctools-1010.6' ... hostPlatform.system
     = "x86_64-linux"

   It is CCTOOLS that nixpkgs will not provide on a Linux host, not rustc. cider builds its own
   cctools and ld64 (#65), so the one package nixpkgs refuses is the one we already have.

3. -syslibroot IS MANDATORY. libSystem.dylib re-exports /usr/lib/system/*.dylib by ABSOLUTE
   path, so without it ld64 looks on the Linux host and dies with

     ld: file not found: /usr/lib/system/libsystem_sandbox.dylib

   Point it at the cider prefix root and the whole re-export chain resolves.

4. -C linker-flavor=ld, because rustc otherwise drives a cc wrapper that does not exist here.

THE xcrun WARNING IS HARMLESS. rustc shells out to xcrun to find an SDK and cannot; it only
affects the SDK version stamped into the binary. Set SDKROOT to silence it if that matters.

Usage:
  buck-darwin-rust-build.py <source.rs> <output> [--sysroot DIR] [--prefix DIR] [--ld PATH]
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

TARGET = "x86_64-apple-darwin"


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("output")
    ap.add_argument("--rustc", required=True, help="OFFICIAL rustc, not the nixpkgs one; see 1 above")
    ap.add_argument("--sysroot", required=True, help="merged: official rustc libs + Darwin rust-std")
    ap.add_argument("--prefix", required=True, help="cider prefix root, the dir holding usr/lib")
    ap.add_argument("--ld", required=True, help="the buck2-built x86_64-apple-darwin20-ld")
    a = ap.parse_args(argv)

    for p, what in ((a.rustc, "rustc"), (a.ld, "ld64")):
        if not os.path.exists(p):
            print(f"FAIL: no {what} at {p}")
            return 2
    libdir = os.path.join(a.sysroot, "lib", "rustlib", TARGET, "lib")
    if not os.path.isdir(libdir):
        print(f"FAIL: sysroot has no {TARGET} libdir at {libdir}")
        return 2

    cmd = [
        a.rustc, "--target", TARGET, "--sysroot", os.path.abspath(a.sysroot),
        "-C", "linker-flavor=ld",
        "-C", f"linker={a.ld}",
        "-C", "link-arg=-syslibroot", "-C", f"link-arg={os.path.abspath(a.prefix)}",
        "-C", "link-arg=-lSystem",
        "-o", a.output, a.source,
    ]
    print("  " + " ".join(cmd))
    # STDERR IS NOT DISCARDED. The linker diagnostics are the whole value when this fails.
    r = subprocess.run(cmd)
    if r.returncode != 0:
        print(f"FAIL: rustc exited {r.returncode}")
        return 1

    # VERIFY THE ARTIFACT, not the exit code. A linker can exit 0 and leave the wrong format.
    f = subprocess.run(["file", "-b", a.output], capture_output=True, text=True).stdout.strip()
    print(f"  {a.output}: {f}")
    if "Mach-O 64-bit x86_64 executable" not in f:
        print("FAIL: output is not a Mach-O x86_64 executable")
        return 1
    print("PASS: built a Darwin Mach-O executable from Rust on Linux")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
