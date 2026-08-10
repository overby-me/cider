#!/usr/bin/env python3
"""Do the Rust host tools behave EXACTLY like the C ones they replace? (#76)

getuuid and elfdep were ported to Rust. Parity here means BYTE parity, not "looks the same":
stdout compared as HEX, stderr verbatim, exit code compared. A trailing newline appearing or
disappearing would be a real regression, and getuuid deliberately emits none.

NOTHING IN THE BUCK2 BUILD CONSUMES EITHER TOOL TODAY. The one consumer is cmake/dsym.cmake,
which belongs to the reference CMake build this port replaces, and it calls getuuid and reads
its stdout. So the strictness is for that caller and for anyone who wires these up later, not
for a dependency that exists right now. Said plainly because the opposite claim, that the
output is consumed in-tree, is easy to assume and was written here first.

WHY BYTES AND NOT EYES. Writing the ports from a reading of the C produced one defect that
survived review and died here: std::io::Error renders ENOENT as
"No such file or directory (os error 2)" while the C strerror prints only "No such file or
directory". Only a byte comparison against the actual C binary catches that.

WHAT THE CASES DO AND DO NOT PROVE, which matters when reading a green run:

  the Mach-O cases (a dylib, an ELF object) DISCRIMINATE. They exercise the magic dispatch,
  the load command walk and the output format, and they are what would catch a real porting
  error.

  the error cases (no args, missing file, non Mach-O) verify FORMATTING against the C, and
  that is worth having, but they do NOT discriminate between the two tools: getuuid and elfdep
  produce byte identical error output by design. Verified by running the harness across tools,
  where the missing-file case reports SAME and only the dylib case reports DIFF. A run that
  exercised only error paths would prove much less than it appears to.

Exit 0 when every pair matches, 1 on any difference, 2 when a binary is missing.

Usage:
  scripts/buck-hosttools-parity.py                  # build outputs under buck-out
  scripts/buck-hosttools-parity.py --buck-out DIR
"""
from __future__ import annotations
import subprocess, sys, pathlib, argparse

DEFAULT_OUT = "buck-out/v2/art/root/1ef78538d8598cb2"


def run(binary: str, args: list[str]) -> tuple[str, str, int]:
    p = subprocess.run([binary, *args], capture_output=True)
    return p.stdout.hex(), p.stderr.decode(errors="replace"), p.returncode


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--buck-out", default=DEFAULT_OUT)
    ns = ap.parse_args(argv[1:])
    b = pathlib.Path(ns.buck_out)

    notmacho = pathlib.Path("/tmp/buck-hosttools-parity-notmacho.bin")
    notmacho.write_bytes(b"not a mach-o at all\n")

    dylib = b / "darwin/libsimple/__libsimple_cider_dylib__/libsimple_cider.dylib"
    elfobj = b / "linux/startup/__rtsig__/__objs/rtsig.c.o"

    pairs = [
        ("getuuid", b / "linux/buildtools/__getuuid_c__/getuuid_c",
         b / "linux/buildtools/__getuuid__/getuuid"),
        ("elfdep", b / "linux/buildtools/__elfdep_c__/elfdep_c",
         b / "linux/buildtools/__elfdep__/elfdep"),
    ]
    cases = [
        ("no args", []),
        ("missing file", ["/nonexistent/path"]),
        ("not mach-o", [str(notmacho)]),
        ("dylib", [str(dylib)]),
        ("elf object", [str(elfobj)]),
    ]

    missing = [str(p) for _, c, r in pairs for p in (c, r) if not p.exists()]
    if missing:
        print("MISSING, build //linux/buildtools:{getuuid,elfdep,getuuid_c,elfdep_c} first:")
        for m in missing:
            print("  ", m)
        return 2

    bad = 0
    walked = 0
    for name, c, r in pairs:
        print(f"=== {name}: C against Rust ===")
        for label, args in cases:
            co, ce, crc = run(str(c), args)
            ro, re_, rrc = run(str(r), args)
            walked += 1
            if (co, ce, crc) == (ro, re_, rrc):
                print(f"  ok    {label:<14} exit={crc} stdout={len(co)//2}B")
            else:
                bad += 1
                print(f"  DIFF  {label}")
                if crc != rrc:
                    print(f"    exit   C={crc} R={rrc}")
                if co != ro:
                    print(f"    stdout C={co}\n           R={ro}")
                if ce != re_:
                    print(f"    stderr C={ce!r}\n           R={re_!r}")

    # A harness that compared nothing would print a clean sheet, so say what it walked.
    if walked == 0:
        print("FAIL: compared nothing, so this proved nothing")
        return 1
    print()
    if bad:
        print(f"FAIL: {bad} of {walked} comparisons differ")
        return 1
    print(f"PASS: {walked} comparisons byte identical (stdout hex, stderr, exit code)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
