#!/usr/bin/env python3
"""Can cider libSystem satisfy what official Darwin Rust std references? (task #96 step 0)

THE QUESTION. Official rust-std for x86_64-apple-darwin is built expecting APPLE libSystem.
cider links guest binaries against its OWN reimplementation. So before anyone wires a
toolchain, measure the gap: undefined symbols the std rlibs cannot satisfy among themselves,
minus what cider exports.

FOUR WAYS TO GET THIS WRONG, ALL OF WHICH I DID BEFORE THE NUMBER BELOW WAS TRUSTWORTHY:

  1. llvm-nm and GNU nm ERROR on the big rlibs and succeed on the small ones, so a total that
     looks plausible can be missing std entirely. First run said 1,246 undefined. Garbage.
  2. ar x with a RELATIVE path and cwd set extracts nothing, and capture_output hides it. That
     produced 0 defined, 0 undefined, 0 unreadable, which reads as a clean pass.
  3. llvm-objdump --syms lists LOCAL symbols too, which a linker cannot bind to. Counting those
     gave 18,218 cider exports against a true 7,508.
  4. THE MACH-O SYMBOL TABLE IS NOT THE EXPORT LIST. Exports live in the EXPORT TRIE. For the
     cider side use: llvm-objdump --macho --exports-trie

USE llvm-objdump, NOT nm. Both llvm-nm and GNU nm REFUSE these objects:

    Unknown attribute kind (105) (Producer: LLVM22.1.2-rust-1.95.0-stable, Reader: LLVM 21.1.8)

They prefer the EMBEDDED BITCODE section over the Mach-O symbol table, and official 1.95.0 was
built with a newer LLVM than the local one. That error is about the bitcode, NOT about the code:
`file` reports each rlib member as a native "Mach-O 64-bit x86_64 object", and llvm-objdump reads
its symbol table fine. This distinction is the whole feasibility question for route A, because
native objects link without LLVM agreement while bitcode would not.

A FIRST ATTEMPT WITH llvm-nm SILENTLY REPORTED 1,246 UNDEFINED, which was garbage: nm failed on
exactly the big rlibs and returned success for the small ones, so the total looked plausible.
Any count here must come from a reader that did not error.

Usage: darwin-rust-symcheck.py <rlib-dir> <cider-exports.txt>
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile

# llvm-objdump --syms Mach-O line: an undefined symbol carries *UND*
_UND = re.compile(r"^\S+\s+.*\*UND\*\s+(\S+)\s*$")
_DEF = re.compile(r"^\S+\s+\S*\s*[gl]\s+.*?\s(\S+)\s*$")


def syms(path: str):
    """(defined, undefined) from one Mach-O object. Raises if the reader errored."""
    r = subprocess.run(["llvm-objdump", "--syms", path], capture_output=True, text=True)
    if r.returncode != 0 or "error:" in r.stderr:
        raise RuntimeError(f"llvm-objdump failed on {path}: {r.stderr.strip()[:200]}")
    d, u = set(), set()
    for line in r.stdout.splitlines():
        m = _UND.match(line)
        if m:
            u.add(m.group(1))
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[-1].startswith("_"):
            # a defined symbol line ends with the name and is not *UND*
            if "*UND*" not in line:
                d.add(parts[-1])
    return d, u


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    libdir, exports_path = argv

    rlibs = sorted(f for f in os.listdir(libdir) if f.endswith(".rlib"))
    print(f"rlibs: {len(rlibs)}")

    defined, undefined = set(), set()
    failures = []
    with tempfile.TemporaryDirectory() as td:
        for r in rlibs:
            # ABSOLUTE. ar runs with cwd=sub, so a relative rlib path silently extracts
            # nothing, and capture_output hides the error: the first run of this script
            # reported 0 undefined, 0 defined and 0 unreadable members, which looks like a
            # clean pass and is actually a measurement that never happened.
            full = os.path.abspath(os.path.join(libdir, r))
            sub = os.path.join(td, r)
            os.makedirs(sub, exist_ok=True)
            ar = subprocess.run(["ar", "x", full], cwd=sub, capture_output=True, text=True)
            if ar.returncode != 0:
                failures.append(f"ar x failed on {r}: {ar.stderr.strip()[:120]}")
                continue
            members = sorted(os.listdir(sub))
            if not members:
                failures.append(f"ar x produced no members for {r}")
                continue
            for m in members:
                mp = os.path.join(sub, m)
                try:
                    d, u = syms(mp)
                except RuntimeError as e:
                    failures.append(str(e)[:120])
                    continue
                defined |= d
                undefined |= u

    print(f"members that could not be read: {len(failures)}")
    for f in failures[:5]:
        print(f"    {f}")
    print(f"defined by the rlibs   : {len(defined)}")
    print(f"undefined referenced   : {len(undefined)}")

    external = {s for s in undefined if s not in defined}
    print(f"EXTERNAL needs (undefined and not self-satisfied): {len(external)}")

    cider = {l.strip() for l in open(exports_path) if l.strip()}
    print(f"cider libSystem exports: {len(cider)}")

    missing = sorted(s for s in external if s not in cider)
    print()
    print(f"=== MISSING FROM CIDER: {len(missing)} of {len(external)} ===")
    for s in missing:
        print(f"    {s}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
