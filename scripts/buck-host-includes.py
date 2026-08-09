#!/usr/bin/env python3
# FROZEN GENERATOR (#82). cmake is gone, so nothing can regenerate the reference
# build.ninja this reads. It still runs against the stale result-graph-ref symlink
# until a store GC collects it, and then it cannot run at all. The BUCK files it
# produced are committed; this is kept for provenance, not for re-running.
"""Does every target that needs a HOST header actually ask for one?

The port compiles against libraries that live outside the build graph: X11, freetype,
fontconfig, cairo, ffmpeg, pulseaudio and the rest. The reference build.ninja names those
include directories explicitly, with an absolute -I per compile. The port did not, for the
whole of the campaign, and nothing noticed -- because buck/toolchains/BUCK defaults
darwin_cc to the bare name "clang", which inside the dev shell is the WRAPPED clang and
injects the same directories through NIX_CFLAGS_COMPILE.

So AppKit, Onyx2D, CoreGraphics, CoreText, iokitd, hdiutil, the X11 backends and the
CoreAudio cone were compiling against headers nothing in the build graph asked for. It only
surfaced in the Nix graph derivation, which pins clang-unwrapped and unsets NIX_CFLAGS on
purpose, where iokitd stopped at "X11/Xlib.h file not found".

That is the class of bug this checks for, statically and in a second, rather than waiting an
hour for a Nix build to fail. For every reference compile carrying an absolute host -I, the
port's target must depend on //src/native:host_headers, which exports -I for each entry of
cider.host_include_dirs.

Usage:
  scripts/buck-host-includes.py           # report, exit 1 if any target is missing it
  scripts/buck-host-includes.py --list    # also list the reference's host include dirs
"""
from __future__ import annotations

import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GRAPH = os.path.join(REPO, "result-graph-ref", "build.ninja")
EXTRA_DEPS = os.path.join(REPO, "buck", "generated", "extra-deps.json")
HOST_HEADERS = "//src/native:host_headers"

# The reference stages its own sources in the store too, so "absolute" is not enough to mean
# "host library": the project's own tree is a store path as well.
PROJECT_MARKER = "cider-cmake-src"

# The toolchain's own resource root, which the port supplies as clang_resource_dir rather
# than through host_include_dirs.
TOOLCHAIN_MARKERS = ("clang-wrapper", "resource-root")

BUILD_RE = re.compile(r"^build [^:]+: (\S+)")
INC_RE = re.compile(r"-I(/nix/store/[^\s]+)")
RULE_STRIP = re.compile(r"^(?:OBJCXX|OBJC|CXX|C)_COMPILER__|_unscanned_$")


def cmake_target(rule: str) -> str:
    return RULE_STRIP.sub("", RULE_STRIP.sub("", rule))


def main(argv: list[str]) -> int:
    if not os.path.exists(GRAPH):
        print(f"no reference graph at {GRAPH}; nothing to check")
        return 0

    needs: dict[str, int] = {}
    dirs: set[str] = set()
    cur = None
    with open(GRAPH) as f:
        for line in f:
            m = BUILD_RE.match(line)
            if m:
                cur = m.group(1)
                continue
            s = line.strip()
            if not (s.startswith("FLAGS =") or s.startswith("INCLUDES =")):
                continue
            hits = [
                d for d in INC_RE.findall(s)
                if PROJECT_MARKER not in d and not any(t in d for t in TOOLCHAIN_MARKERS)
            ]
            if hits and cur:
                needs[cmake_target(cur)] = needs.get(cmake_target(cur), 0) + len(hits)
                dirs.update(hits)

    extra = json.load(open(EXTRA_DEPS))

    # Only targets the port actually BUILDS. A reference target with no cc_objects block
    # here is out of scope, and demanding a dep for it would make this check unpassable.
    ported: set[str] = set()
    for dirpath, dirnames, filenames in os.walk(REPO):
        if "buck-out" in dirpath or "/.jj" in dirpath or "/.git" in dirpath:
            dirnames[:] = []
            continue
        if "BUCK" not in filenames:
            continue
        text = open(os.path.join(dirpath, "BUCK"), errors="ignore").read()
        for t in needs:
            if f'name = "{t}_obj"' in text:
                ported.add(t)

    missing = sorted(
        t for t in needs
        if t in ported and HOST_HEADERS not in extra.get(t, [])
    )
    unported = sorted(t for t in needs if t not in ported)

    print(f"reference compiles with a host -I: {sum(needs.values())} across {len(needs)} targets")
    print(f"distinct host include dirs:        {len(dirs)}")
    print(f"ported targets among them:         {len(ported)}")
    if unported:
        print(f"not built by the port (skipped):   {len(unported)}  {' '.join(unported[:8])}")
    if "--list" in argv:
        for d in sorted(dirs):
            print(f"    {d}")

    if missing:
        print(f"\nFAIL: {len(missing)} target(s) compile against host headers without asking:")
        for t in missing:
            print(f"    {t}  ({needs[t]} host -I in the reference)")
        print(f"\nAdd {HOST_HEADERS} to each in buck/generated/extra-deps.json and")
        print("regenerate the block, so a --write cannot drop it again.")
        return 1

    print(f"\nok: every ported target with a host -I declares {HOST_HEADERS}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
