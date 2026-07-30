#!/usr/bin/env python3
"""Move generated blocks out of the one giant buck-src package into one package PER PIN.

buck2 does not care how big a BUCK file is, but the Nix-lowered path (plan/buck2-port.md
phase 3) parses a whole file into Nix values to reach any target in it: buck-src/BUCK at
33k lines costs more memory than the machine has, while a 13.5k-line file is comfortable.
Pins are also the unit a reader thinks in.

This MOVES blocks, it does not regenerate them. Regenerating would be the obvious way to
place a block in its pin's package -- gen-buck-from-ninja.py already knows how -- but the
committed tree is not a fixpoint of the generator: 216 of its 367 blocks were written by
older versions of it, and re-deriving them all at once mixes the split with dozens of
unrelated changes (libc's include roots, for one, come back merged in a way that does not
compile). So each block travels verbatim, with only the mechanical rewrites a package
change forces:

  * its own pin's paths become package-relative;
  * `:name` becomes `//buck-src:name`, unless that target moves too;
  * every reference to a moved target, anywhere in the tree, is repointed.

A block that names ANOTHER pin's files (libcxxabi globbing libcxx's include dir) stays
where it is: a glob cannot cross a package boundary, so moving it would need a header root
in buck-src to replace the glob. Those are reported, not guessed at.

The SDK header maps stay whole and stay in buck-src/BUCK. A subpackage owns its files, so
a map cannot name them by PATH any more -- but a `header_map` value is an attrs.source(),
and a source coerces from a LABEL too. So only the spelling changes, the staged SDK tree
and its include order are exactly what they were, and scripts/buck-exports.py backs each
label with an export_file in the owning pin.

Usage:
  scripts/buck-split-pins.py --list                   # what lives in buck-src/BUCK
  scripts/buck-split-pins.py --all --dry-run          # what would move, and what sticks
  scripts/buck-split-pins.py --only libnotify,syslog  # migrate these pins
  scripts/buck-split-pins.py --all                    # migrate every pin
"""
from __future__ import annotations

import collections
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUCK_SRC_DIR = os.path.join(REPO, "buck-src")
BUCK_SRC = os.path.join(BUCK_SRC_DIR, "BUCK")
SPLIT_PINS = os.path.join(REPO, "buck", "generated", "split-pins.txt")
EXTRA_DEPS = os.path.join(REPO, "buck", "generated", "extra-deps.json")
SKIP_DIRS = ("buck-out", ".git", ".jj", ".direnv", "build")
# Namespaces the SDK maps cover, in the order gen-sdk-header-roots.py expects them.
NS = [".", "mach", "i386", "machine", "libkern", "sys"]
# Prefixes that are never a source path: a label, a compiler flag, or one of the typed
# extra-dep instructions.
NOT_A_PATH = ("//", ":", "-", "gen:", "dylib:", "dep:", "objs:", "ldflag:", "toolchains//")
# Every string literal, ESCAPES INCLUDED. A plain `"([^"]+)"` desynchronises on the first
# `\"` -- and the flag lists are full of them (-DMIG_VERSION=\"1.0\") -- after which its
# "strings" are the text BETWEEN strings, so nearly every path goes unseen.
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')


def blocks(text: str):
    """[(marker, start, end)] for every generated block, outermost first."""
    out = []
    for m in re.finditer(r"^# BEGIN generated: (.+)\n", text, re.M):
        end_marker = f"# END generated: {m.group(1)}\n"
        end = text.find(end_marker, m.end())
        if end != -1:
            out.append((m.group(1), m.start(), end + len(end_marker)))
    return out


def pin_paths(body: str):
    """(files, glob dirs) a block really names, by checking the disk.

    Shape is not enough to tell a path from anything else: an install_name reads as an
    absolute path, a header_map KEY reads as a relative one, and a glob pattern is not a
    file at all. So a string counts as a path only if it resolves under buck-src -- as a
    FILE, or, for a glob, as the directory its pattern starts in.

    A directory that is not a glob prefix is deliberately not a file reference: `root` and
    `out_base` name one, and they are a prefix to strip and an output dir, not sources.
    Labelling those turned libcxx's include root into `root = "//buck-src/libcxx:include"`,
    which stages nothing and takes the C++ standard library off the search path.
    """
    files, globs = set(), set()
    for s in STRING.findall(body):
        if s.startswith(NOT_A_PATH) or " " in s or "/" not in s:
            continue
        if "*" in s:
            head = s.split("*")[0].rstrip("/")
            if head and os.path.isdir(os.path.join(BUCK_SRC_DIR, head)):
                globs.add(head)
        elif os.path.isfile(os.path.join(BUCK_SRC_DIR, s)):
            files.add(s)
    return files, globs


def owner_of(path: str) -> str:
    return path.split("/")[0]


def pin_of(body: str) -> str | None:
    """Which pin a block belongs to: the one holding its SOURCES.

    Sources first, then the DOMINANT pin among everything else it names -- a generated
    block (an xtrace stub, say) compiles nothing from the tree, and its eight include
    roots all point into the same pin, which is the pin it belongs to. Taking the first
    path instead put those blocks in whichever pin sorted first, and left them naming
    another package's files.
    """
    srcs = re.findall(r'^\s+"([A-Za-z0-9_.+-]+)/[^"]*\.(?:c|cc|cpp|m|mm|S|s)",$', body, re.M)
    if srcs:
        return collections.Counter(srcs).most_common(1)[0][0]
    files, globs = pin_paths(body)
    owners = collections.Counter(owner_of(p) for p in files | globs)
    return owners.most_common(1)[0][0] if owners else None


def target_names(body: str) -> list:
    return re.findall(r'^\s*name = "([A-Za-z0-9_.+-]+)",$', body, re.M)


def movable(text: str, pins: set):
    """({pin: [(marker, start, end)]}, [(marker, pin, blocking globs)]).

    A block moves once every GLOB it runs is inside the pin it is moving to: a glob cannot
    cross a package boundary, so one reaching into a sibling pin would stage nothing.
    Individual FILE references are not blocking -- those become labels.
    """
    move: dict[str, list] = {}
    stuck = []
    for marker, a, b in blocks(text):
        body = text[a:b]
        pin = pin_of(body)
        if not pin or pin not in pins:
            continue
        foreign = sorted(g for g in pin_paths(body)[1] if owner_of(g) != pin)
        if foreign:
            stuck.append((marker, pin, foreign))
            continue
        move.setdefault(pin, []).append((marker, a, b))
    return move, stuck


def rule_calls(text: str):
    """[(start, end, body)] for every top-level rule call, comments above included."""
    out = []
    for m in re.finditer(r"^([a-z_][a-z_0-9]*)\(\n(?:.*?\n)*?\)\n", text, re.M):
        start = m.start()
        while start > 0:
            prev = text.rfind("\n", 0, start - 1) + 1
            if text[prev:start].lstrip().startswith("#") and "generated:" not in text[prev:start]:
                start = prev
            else:
                break
        out.append((start, m.end(), text[start:m.end()]))
    return out


def orphan_roots(text: str, pins: set):
    """Calls left in buck-src/BUCK that GLOB into exactly one migrated pin.

    A glob cannot cross a package boundary, so these have to travel too, one TARGET at a
    time rather than one block at a time. Two shapes need it: a hand-written root the
    block mover never sees (libcxx_include), and a root inside a block that stayed behind
    because it reaches into a sibling pin (info-util's roots over libc's locale trees).
    The rest of that block stays where it is and reaches the root by label.
    """
    found = []
    for start, end, body in rule_calls(text):
        owners = {owner_of(g) for g in pin_paths(body)[1]}
        migrated = owners & pins
        if len(migrated) != 1 or len(owners) != 1:
            continue
        names = target_names(body)
        if names:
            found.append((start, end, next(iter(migrated)), names))
    return found


def export_target_name(rel_in_pkg: str) -> str:
    """Same flattening as gen-buck-from-ninja.py and buck-exports.py."""
    return re.sub(r"[^A-Za-z0-9_.+-]+", "_", rel_in_pkg)


HINTS = os.path.join(REPO, "buck", "generated", "export-hints.json")


def add_hint(hints: dict, pkg: str, path_in_pkg: str) -> str:
    """Record that `pkg` must export this file, and return the label for it."""
    name = export_target_name(path_in_pkg)
    hints.setdefault(pkg, {})[name] = path_in_pkg
    return f"//{pkg}:{name}"


def label_for_file(path: str, pkg: str, pins: set, hints: dict) -> str:
    """How `pkg` refers to a buck-src-relative file it does not own."""
    pin = owner_of(path)
    if pin in pins:
        owner, rel = f"buck-src/{pin}", path[len(pin) + 1:]
    else:
        owner, rel = "buck-src", path
    if owner == pkg:
        return rel
    return add_hint(hints, owner, rel)


def fix_mig_out_base(text: str) -> int:
    """Keep `out_base` in step with a `defs` that became a label.

    mig names its outputs from `defs.short_path` minus `out_base`, and a source's
    short_path is relative to the package that DECLARES it. Once defs arrives as a label
    into buck-src/<pin>, the short_path loses the `<pin>/` prefix -- so an out_base that
    still carries it stops matching, and every output keeps a directory it should not have
    (asl_ipcUser.c became libsystem_asl.tproj/asl_ipcUser.c, which no consumer names).
    """
    out, last, n = [], 0, 0
    for start, end, call in rule_calls(text):
        m = re.search(r'^\s*defs = "//buck-src/([A-Za-z0-9_.+-]+):', call, re.M)
        if not m:
            continue
        pin = m.group(1)
        fixed = re.sub(r'^(\s*out_base = )"' + re.escape(pin) + r'/', r'\1"', call, flags=re.M)
        fixed = re.sub(r'^(\s*out_base = )"' + re.escape(pin) + r'"', r'\1""', fixed, flags=re.M)
        if fixed == call:
            continue
        out.append(text[last:start])
        out.append(fixed)
        last = end
        n += 1
    if n:
        out.append(text[last:])
        open(BUCK_SRC, "w").write("".join(out))
    return n


def labelize(body: str, pkg: str, pins: set, hints: dict) -> str:
    """Turn every file reference the package does not own into a label.

    A path is only spellable by a package that owns the file; anything else has to come
    through an export_file in the owner. Globs are left alone -- movable() has already
    guaranteed they are local, and a glob has no label form.
    """
    files, _globs = pin_paths(body)
    own = pkg[len("buck-src/"):] if pkg.startswith("buck-src/") else None
    for path in sorted(files, key=len, reverse=True):
        if own and (path == own or path.startswith(own + "/")):
            continue  # its own pin: already package-relative
        if not own and owner_of(path) not in pins:
            continue  # buck-src still owns it
        body = body.replace(f'"{path}"', f'"{label_for_file(path, pkg, pins, hints)}"')
    return body


def ensure_visibility(body: str) -> str:
    """Give every moved target `visibility = ["PUBLIC"]`.

    Inside one package a target needs no visibility at all, so the generator only declares
    it where it mattered. The moment the target lives in its own package, every consumer is
    a stranger: buck2 rejects the reference with "is not visible to".
    """
    out, last = [], 0
    for start, end, call in rule_calls(body):
        if "visibility = " not in call:
            call = call[:call.rindex(")\n")] + '    visibility = ["PUBLIC"],\n)\n'
        out.append(body[last:start])
        out.append(call)
        last = end
    out.append(body[last:])
    return "".join(out)


def rewrite_for_pin(body: str, pin: str, names: dict[str, str], pins: set, hints: dict) -> str:
    """A block's text as the pin's own package must spell it.

    `names` is {moved target: its new pin}; anything else stays in buck-src.
    """
    # Files in OTHER packages first, while the paths are still whole.
    body = labelize(body, f"buck-src/{pin}", pins, hints)
    # The pin DIRECTORY itself: an include root or a mig out_base can be exactly the pin,
    # and package-relative that is the package itself. This runs BEFORE the prefix strip,
    # or a pin holding a directory of its own name loses it: libunwind's root is
    # libunwind/libunwind, and stripping first left `root = "libunwind"` to be cleared.
    body = re.sub(r'^(\s*(?:root|out_base) = )"' + re.escape(pin) + '"', r'\1""', body, flags=re.M)
    # Its own pin's paths are package-relative there.
    body = body.replace('"' + pin + "/", '"')

    # A bare `:name` meant "this package", which is no longer buck-src. It keeps that
    # form only for a target landing in the SAME pin; a target that stayed behind is in
    # buck-src, and one that moved elsewhere is in that pin's package.
    def abs_label(m):
        prefix, name = m.group(1) or "", m.group(2)
        dest = names.get(name)
        if dest == pin:
            return m.group(0)
        pkg = f"//buck-src/{dest}" if dest else "//buck-src"
        return f'"{prefix}{pkg}:{name}"'
    body = re.sub(r'"(gen:)?:([A-Za-z0-9_.+-]+)"', abs_label, body)
    return ensure_visibility(body)


def publicise_referenced() -> int:
    """Give a buck-src target PUBLIC visibility once another package names it.

    Visibility cuts both ways: a moved target needs it to be reachable from buck-src, and
    a target that STAYED needs it the moment a pin package refers to it. Only the ones
    actually named from outside are opened up, so the rest keep saying who may use them.
    """
    wanted = set()
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if "BUCK" not in filenames or dirpath == BUCK_SRC_DIR:
            continue
        for m in re.finditer(r'"(?:[a-z]+:)?//buck-src:([A-Za-z0-9_.+-]+)"',
                             open(os.path.join(dirpath, "BUCK")).read()):
            wanted.add(m.group(1))
    text = open(BUCK_SRC).read()
    out, last, n = [], 0, 0
    for start, end, call in rule_calls(text):
        if "visibility = " in call or not (set(target_names(call)) & wanted):
            continue
        out.append(text[last:start])
        out.append(call[:call.rindex(")\n")] + '    visibility = ["PUBLIC"],\n)\n')
        last = end
        n += 1
    if n:
        out.append(text[last:])
        open(BUCK_SRC, "w").write("".join(out))
    return n


def repoint(names: dict[str, str]) -> int:
    """Point every reference at a moved target's new package. Returns files touched.

    One regex over all the moved names, not a replace per name: it is 900 names across two
    dozen files, and it has to catch the UNQUOTED form too -- the suite lists its targets
    bare, and a label left stale there reads as a regression rather than as a rename.
    """
    if not names:
        return 0
    alt = "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True))
    tail = r"(?![A-Za-z0-9_.+-])"
    absolute = re.compile(r"//buck-src:(" + alt + ")" + tail)
    # `:name` meant "this package" only inside buck-src/BUCK itself.
    local = re.compile(r'"(gen:)?:(' + alt + r')"')
    touched = 0
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn not in ("BUCK", "extra-deps.json", "buck-test.sh"):
                continue
            f = os.path.join(dirpath, fn)
            t = orig = open(f).read()
            t = absolute.sub(lambda m: f"//buck-src/{names[m.group(1)]}:{m.group(1)}", t)
            if f == BUCK_SRC:
                t = local.sub(
                    lambda m: f'"{m.group(1) or ""}//buck-src/{names[m.group(2)]}:{m.group(2)}"', t)
            if t != orig:
                open(f, "w").write(t)
                touched += 1
    return touched


def read_split_pins() -> set:
    if not os.path.exists(SPLIT_PINS):
        return set()
    return {l.strip() for l in open(SPLIT_PINS) if l.strip() and not l.startswith("#")}


def write_split_pins(pins: set) -> None:
    with open(SPLIT_PINS, "w") as fh:
        fh.write("# Pins that have their own package, buck-src/<pin>/BUCK.\n")
        fh.write("# THIS FILE IS THE SWITCH: the SDK maps name a listed pin's headers by\n")
        fh.write("# label instead of by path, and gen-buck-from-ninja.py writes a listed\n")
        fh.write("# pin's blocks into its own package. scripts/buck-split-pins.py keeps it.\n")
        for pin in sorted(pins):
            fh.write(pin + "\n")


def run(*cmd: str) -> int:
    return subprocess.run([str(c) for c in cmd], cwd=REPO, check=False).returncode


def migrate(pins: list[str], dry: bool = False) -> int:
    text = open(BUCK_SRC).read()
    move, stuck = movable(text, set(pins))
    n = sum(len(v) for v in move.values())
    print(f"{n} block(s) move into {len(move)} package(s); {len(stuck)} stay behind")
    for marker, pin, foreign in stuck:
        print(f"    STAYS {marker:32} ({pin}) names {' '.join(sorted({p.split('/')[0] for p in foreign}))}")
    if dry:
        for pin, items in sorted(move.items()):
            print(f"    {pin:22} {len(items):3d} block(s), "
                  f"{sum(b - a for _m, a, b in items) // 1024}k")
        return 0
    if not move:
        return 0

    # Which target names move, and where to. Everything else keeps living in buck-src.
    names: dict[str, str] = {}
    for pin, items in move.items():
        for _marker, a, b in items:
            for name in target_names(text[a:b]):
                names[name] = pin
    all_pins = read_split_pins() | set(move)
    hints = json.load(open(HINTS)) if os.path.exists(HINTS) else {}

    # 1. Cut each block out and write it into its pin's package.
    spans = sorted((a, b, pin) for pin, items in move.items() for _m, a, b in items)
    per_pin: dict[str, list] = {}
    keep, last = [], 0
    for a, b, pin in spans:
        per_pin.setdefault(pin, []).append(
            rewrite_for_pin(text[a:b], pin, names, all_pins, hints))
        keep.append(text[last:a])
        last = b
    keep.append(text[last:])
    # 1b. What stays behind still names files that just changed owner: those become
    #     labels too, or buck2 refuses to coerce a source it no longer owns.
    open(BUCK_SRC, "w").write(labelize("".join(keep), "buck-src", all_pins, hints))
    with open(HINTS, "w") as fh:
        json.dump(hints, fh, indent=2, sort_keys=True)
        fh.write("\n")
    for pin, bodies in sorted(per_pin.items()):
        d = os.path.join(BUCK_SRC_DIR, pin)
        os.makedirs(d, exist_ok=True)
        f = os.path.join(d, "BUCK")
        head = "" if os.path.exists(f) else (
            f"# Targets over the {pin} pin, materialized by scripts/buck-src.sh. The tree\n"
            "# itself is gitignored (content is pinned in nix/submodules.json); this file is\n"
            "# committed. One package per pin keeps what the Nix-lowered path has to parse\n"
            "# small enough to evaluate (plan/buck2-port.md phase 3).\n\n")
        existing = open(f).read() if os.path.exists(f) else ""
        open(f, "w").write(head + existing.rstrip("\n") + ("\n\n" if existing.strip() else "")
                           + "\n".join(bodies))
        print(f"  buck-src/{pin}: {len(bodies)} block(s)")

    # 1c. Hand-written calls that glob a migrated pin travel as single TARGETS: they are
    #     not in a generated block, so step 1 never sees them, and a glob left behind
    #     would stage nothing.
    text = open(BUCK_SRC).read()
    orphans = orphan_roots(text, all_pins)
    if orphans:
        keep, last = [], 0
        by_pin: dict[str, list] = {}
        for start, end, pin, tnames in sorted(orphans):
            for n in tnames:
                names[n] = pin
        for start, end, pin, tnames in sorted(orphans):
            by_pin.setdefault(pin, []).append(
                rewrite_for_pin(text[start:end], pin, names, all_pins, hints))
            keep.append(text[last:start])
            last = end
        keep.append(text[last:])
        open(BUCK_SRC, "w").write("".join(keep))
        for pin, bodies in sorted(by_pin.items()):
            f = os.path.join(BUCK_SRC_DIR, pin, "BUCK")
            os.makedirs(os.path.dirname(f), exist_ok=True)
            existing = open(f).read() if os.path.exists(f) else ""
            open(f, "w").write(existing.rstrip("\n") + ("\n\n" if existing.strip() else "")
                               + "\n".join(bodies))
        print(f"  {len(orphans)} hand-written target(s) moved into "
              f"{len(by_pin)} package(s): {' '.join(sorted(by_pin))}")
        with open(HINTS, "w") as fh:
            json.dump(hints, fh, indent=2, sort_keys=True)
            fh.write("\n")

    # 2. The switch, then everything that referred to a moved target.
    write_split_pins(read_split_pins() | set(move))
    print(f"  repointed references in {repoint(names)} file(s)")
    print(f"  opened up {publicise_referenced()} buck-src target(s) now named from outside")
    print(f"  fixed out_base on {fix_mig_out_base(open(BUCK_SRC).read())} mig target(s)")

    # 3. The SDK maps, naming the migrated pins' headers by label.
    sdk_gen = os.path.join(REPO, "scripts", "gen-sdk-header-roots.py")
    out = subprocess.run([sdk_gen] + NS, cwd=REPO, capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr, file=sys.stderr)
        return 1
    open(os.path.join(REPO, "buck", "generated", "sdk_headers.bzl"), "w").write(out.stdout)
    run(sdk_gen, "--framework-roots", *NS)

    # 4. An export_file for every label that now points into a pin package.
    run(os.path.join(REPO, "scripts", "buck-exports.py"))
    run(os.path.join(REPO, "scripts", "buck-fix-loads.py"))
    print("migration written; build and iterate")
    return 0


def main(argv: list[str]) -> int:
    text = open(BUCK_SRC).read()
    dry = "--dry-run" in argv

    if "--list" in argv:
        by_pin: dict[str, list] = {}
        for marker, a, b in blocks(text):
            pin = pin_of(text[a:b]) or "(none)"
            by_pin.setdefault(pin, []).append((marker, b - a))
        for pin, items in sorted(by_pin.items(), key=lambda kv: -sum(i[1] for i in kv[1])):
            print(f"{sum(i[1] for i in items):8d} bytes  {pin:24} {len(items)} block(s)")
        return 0

    candidates = sorted({p for marker, a, b in blocks(text)
                         if (p := pin_of(text[a:b])) and "/" not in p and p != ".."})
    if "--all" in argv:
        return migrate(candidates, dry)
    if "--only" in argv:
        want = set(argv[argv.index("--only") + 1].split(","))
        unknown = want - set(candidates)
        if unknown:
            print(f"no movable blocks for: {' '.join(sorted(unknown))}", file=sys.stderr)
            return 1
        return migrate(sorted(want), dry)
    sys.exit(__doc__)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
