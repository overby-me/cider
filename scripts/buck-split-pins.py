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
SKIP_DIRS = ("buck-out", ".git", ".jj", ".direnv", "build")


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


def rule_blocks(text: str):
    """[(start, end, body)] for every top-level rule call, comments included."""
    out = []
    for m in re.finditer(r"^([a-z_][a-z_0-9]*)\(\n(?:.*?\n)*?\)\n", text, re.M):
        start = m.start()
        # Take the comment lines directly above with it.
        while start > 0:
            prev = text.rfind("\n", 0, start - 1) + 1
            if text[prev:start].lstrip().startswith("#") and "BEGIN generated" not in text[prev:start]:
                start = prev
            else:
                break
        out.append((start, m.end(), text[start:m.end()]))
    return out


def move_handwritten(pin: str) -> None:
    """Move hand-written blocks naming this pin's files, and repoint every reference.

    A generated block is regenerated into the new package; a hand-written one (the mig
    targets, say) has to be carried over verbatim, with its source paths made
    package-relative -- and then everything that referred to it by `:name` or
    `//buck-src:name` has to say `//buck-src/<pin>:name` instead.
    """
    text = open(BUCK_SRC).read()
    spans = blocks(text)  # generated regions, which are handled elsewhere
    keep, moved_text, moved_names = [], [], []
    last = 0
    for start, end, body in rule_blocks(text):
        if any(a <= start < b for _m, a, b in spans):
            continue
        if not re.search(r'"' + re.escape(pin) + r'/', body):
            continue
        m = re.search(r'name = "([^"]+)"', body)
        if not m:
            continue
        moved_names.append(m.group(1))
        moved_text.append(re.sub(r'"' + re.escape(pin) + r'/', '"', body))
        keep.append(text[last:start])
        last = end
    if not moved_names:
        return
    keep.append(text[last:])
    open(BUCK_SRC, "w").write("".join(keep))

    dest = os.path.join(REPO, "buck-src", pin, "BUCK")
    existing = open(dest).read() if os.path.exists(dest) else ""
    open(dest, "w").write(existing.rstrip("\n") + "\n\n" + "\n".join(moved_text))

    # Repoint every reference to the moved targets.
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn != "BUCK" and fn != "extra-deps.json":
                continue
            f = os.path.join(dirpath, fn)
            t = open(f).read()
            orig = t
            for name in moved_names:
                t = t.replace(f'"//buck-src:{name}"', f'"//buck-src/{pin}:{name}"')
                if f == BUCK_SRC:
                    t = t.replace(f'":{name}"', f'"//buck-src/{pin}:{name}"')
                t = t.replace(f'"gen://buck-src:{name}', f'"gen://buck-src/{pin}:{name}')
                t = t.replace(f'"gen::{name}', f'"gen://buck-src/{pin}:{name}')
            if t != orig:
                open(f, "w").write(t)
    print(f"moved {len(moved_names)} hand-written block(s): {' '.join(moved_names)}")


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

    # A pin moves as ONE unit, or the tree is broken in between:
    #   1. its own SDK header root, inside the new package;
    #   2. its targets, regenerated so they land there;
    #   3. its share removed from the monolithic maps (a map in buck-src/BUCK cannot
    #      name a file that now belongs to a subpackage);
    #   4. //darwin:sdk_env pointed at the new root.
    sdk_gen = os.path.join(REPO, "scripts", "gen-sdk-header-roots.py")
    NS = [".", "mach", "i386", "machine", "libkern", "sys"]
    subprocess.run([sdk_gen, "--pin-roots", "--apply", "--only", pin] + NS,
                   cwd=REPO, check=False)

    marker = os.path.join(REPO, "buck", "generated", "split-pins.txt")
    have = set()
    if os.path.exists(marker):
        have = {l.strip() for l in open(marker) if l.strip() and not l.startswith("#")}
    if pin not in have:
        with open(marker, "a") as fh:
            if not have:
                fh.write("# Pins migrated to their own package (scripts/buck-split-pins.py).\n")
            fh.write(pin + "\n")

    # Regenerate the monolithic maps without this pin.
    out = subprocess.run([sdk_gen] + NS, cwd=REPO, capture_output=True, text=True)
    if out.returncode == 0:
        open(os.path.join(REPO, "buck", "generated", "sdk_headers.bzl"), "w").write(out.stdout)

    # Point sdk_env at the new root, in the place the monolithic one occupies.
    name = "sdk_pin_" + re.sub(r"[^A-Za-z0-9_]+", "_", pin).strip("_") + "_headers"
    label = f'        "//buck-src/{pin}:{name}",\n'
    darwin = os.path.join(REPO, "darwin", "BUCK")
    dtext = open(darwin).read()
    anchor = '        "//buck-src:sdk_include",\n'
    if label not in dtext and anchor in dtext:
        open(darwin, "w").write(dtext.replace(anchor, anchor + label, 1))

    gen = os.path.join(REPO, "scripts", "gen-buck-from-ninja.py")
    if targets:
        subprocess.run([gen, "--write"] + targets, cwd=REPO, check=False)
    if pairs:
        subprocess.run([gen, "--dylibs", "--write"] + pairs, cwd=REPO, check=False)

    move_handwritten(pin)

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
