#!/usr/bin/env python3
"""Move generated blocks out of the one giant buck-src package into one package PER PIN.

buck2 does not care how big a BUCK file is, but the Nix-lowered path (plan/buck2-port.md
phase 3) parses a whole file into Nix values to reach any target in it: buck-src/BUCK at
32k lines costs more memory than the machine has, while a 4.3k-line file is comfortable.
Pins are also the unit a reader thinks in.

Each generated block carries a marker naming the cmake target that produced it, so the
move is: regenerate that target (gen-buck-from-ninja.py now places pin sources in
buck-src/<pin>), then drop the block left behind in buck-src/BUCK.

Usage:
  scripts/buck-split-pins.py --list                 # what lives in buck-src/BUCK
  scripts/buck-split-pins.py --pin libnotify        # move one pin's targets
  scripts/buck-split-pins.py --pin libnotify --dry-run
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUCK_SRC = os.path.join(REPO, "buck-src", "BUCK")


def blocks(text: str):
    """[(marker, start, end)] for every generated block, outermost first."""
    out = []
    for m in re.finditer(r"^# BEGIN generated: (.+)\n", text, re.M):
        end_marker = f"# END generated: {m.group(1)}\n"
        end = text.find(end_marker, m.end())
        if end != -1:
            out.append((m.group(1), m.start(), end + len(end_marker)))
    return out


def pin_of_block(body: str) -> str | None:
    """Which pin a block's sources live in, from the first pin-relative path."""
    for m in re.finditer(r'"([A-Za-z0-9_.+-]+)/[^"]*\.(?:c|cc|cpp|m|mm|S|s|h|defs|y|l)"', body):
        return m.group(1)
    return None


def main(argv: list[str]) -> int:
    text = open(BUCK_SRC).read()
    found = blocks(text)

    if "--list" in argv:
        by_pin: dict[str, list] = {}
        for marker, a, b in found:
            pin = pin_of_block(text[a:b]) or "(none)"
            by_pin.setdefault(pin, []).append((marker, b - a))
        for pin, items in sorted(by_pin.items(), key=lambda kv: -sum(i[1] for i in kv[1])):
            print(f"{sum(i[1] for i in items):8d} bytes  {pin:24} {len(items)} block(s)")
        return 0

    if "--pin" not in argv:
        sys.exit(__doc__)
    pin = argv[argv.index("--pin") + 1]
    dry = "--dry-run" in argv

    targets = [marker for marker, a, b in found
               if pin_of_block(text[a:b]) == pin and " " not in marker]
    pairs = [marker.split(" ")[0] for marker, a, b in found
             if pin_of_block(text[a:b]) == pin and marker.endswith(" dylibs")]
    print(f"{pin}: {len(targets)} object block(s), {len(pairs)} dylib block(s)")
    if dry:
        for t in targets + pairs:
            print(f"  {t}")
        return 0

    gen = os.path.join(REPO, "scripts", "gen-buck-from-ninja.py")
    if targets:
        subprocess.run([gen, "--write"] + targets, cwd=REPO, check=False)
    if pairs:
        subprocess.run([gen, "--dylibs", "--write"] + pairs, cwd=REPO, check=False)

    # Drop whatever is still in buck-src/BUCK for those markers: the regeneration wrote
    # the block into the pin package, it did not remove the old copy.
    text = open(BUCK_SRC).read()
    moved = set(targets) | {f"{p} dylibs" for p in pairs}
    keep = []
    last = 0
    for marker, a, b in blocks(text):
        if marker in moved:
            keep.append(text[last:a])
            last = b
    keep.append(text[last:])
    open(BUCK_SRC, "w").write("".join(keep))
    print(f"removed {len(moved)} block(s) from buck-src/BUCK")
    subprocess.run([os.path.join(REPO, "scripts", "buck-fix-loads.py")], cwd=REPO)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
