#!/usr/bin/env python3
"""Give every file another package names by label an export_file in its owner.

A file attribute has to be a source of the package that DECLARES it, so once a pin is
its own package, everything outside it -- a header map in buck-src/BUCK, a force-included
header in another pin's compile -- has to reach its files through a label backed by an
export_file. This is the one place that keeps those in sync: it scans every BUCK file and
every generated .bzl for `//buck-src/<pin>:<name>` labels, resolves each name back to the
file it flattens from, and writes the pin's export list.

The list is a DICT in buck/generated/exports_<pin>.bzl, one line per file, with the pin's
BUCK declaring them in a comprehension. One export_file block per file would be five lines
each -- 30k lines across the tree, and the biggest pins would land back over the Nix
evaluator's budget that splitting buck-src was meant to get under (plan/buck2-port.md
phase 3).

Usage:
  scripts/buck-exports.py            # write the lists
  scripts/buck-exports.py --check    # fail if anything is missing or stale
"""
from __future__ import annotations

import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = ("buck-out", ".git", ".jj", ".direnv", "build")

# What can be a FILE label rather than a rule target. A rule target is named after a
# cmake target and never carries a source extension, so the extension is what tells them
# apart -- and the name is only accepted once it resolves to a file that really exists.
FILE_EXTS = (".h", ".hpp", ".hh", ".hxx", ".inc", ".defs", ".c", ".cc", ".cpp", ".cxx",
             ".m", ".mm", ".S", ".s", ".y", ".l", ".tcc", ".mdh", ".mdhi", ".mdhs",
             ".pro", ".epro", ".sh", ".plist", ".txt", ".in", ".sym", ".exp", ".def",
             # Prefix DATA, added with the install rules: configs, an asl policy, iconv's
             # charset table and the man pages, which are sections 1 through 9.
             ".conf", ".asl", ".alias",
             ".1", ".2", ".3", ".4", ".5", ".6", ".7", ".8", ".9")

# The same, for files that carry no extension at all. The rule above cannot see these --
# vim's vimrc and libedit's inputrc are installed by name -- and without them the label goes
# unresolved and the package it names is never even created.
FILE_NAMES = ("vimrc", "inputrc")

BEGIN = "# BEGIN generated: pin exports\n"
END = "# END generated: pin exports\n"


def export_target_name(rel_in_pkg: str) -> str:
    """Same flattening as gen-buck-from-ninja.py: separators become underscores."""
    return re.sub(r"[^A-Za-z0-9_.+-]+", "_", rel_in_pkg)


def migrated_pins() -> set:
    f = os.path.join(REPO, "buck", "generated", "split-pins.txt")
    if not os.path.exists(f):
        return set()
    return {l.strip() for l in open(f) if l.strip() and not l.startswith("#")}


def read_hints() -> dict:
    """{package: {label name: path in package}} recorded by whoever created the label.

    buck-src itself cannot be indexed by walking it -- it holds every materialized pin,
    hundreds of thousands of files -- so the tool that mints a label into it records the
    path here instead. scripts/buck-split-pins.py writes this.
    """
    f = os.path.join(REPO, "buck", "generated", "export-hints.json")
    return json.load(open(f)) if os.path.exists(f) else {}


def scan_labels() -> dict[str, set]:
    """{package: {label name}} over every file that can name one."""
    wanted: dict[str, set] = {}
    pat = re.compile(r'//(buck-src(?:/[A-Za-z0-9_.+-]+)?):([A-Za-z0-9_.+-]+)')
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn != "BUCK" and not fn.endswith((".bzl", ".json")):
                continue
            path = os.path.join(dirpath, fn)
            try:
                text = open(path).read()
            except (UnicodeDecodeError, OSError):
                continue
            for pkg, name in pat.findall(text):
                if name.endswith(FILE_EXTS) or name.endswith(FILE_NAMES):
                    wanted.setdefault(pkg, set()).add(name)
    return wanted


def pin_index(pin: str) -> dict[str, str]:
    """{flattened name: pin-relative path} for every file in the pin.

    Following symlinks matters: a pin reaches part of its own tree through symlinked
    DIRECTORIES (libunwind's darling/include/mach-o is one), and os.walk skips those by
    default -- so the file a label names looks absent and the export goes unwritten.
    """
    root = os.path.join(REPO, "buck-src", pin)
    index: dict[str, str] = {}
    clash: set = set()

    def walk(d: str, chain: tuple):
        """DFS that follows symlinked dirs but not loops.

        The guard is BRANCH-local, not global: a pin reaches parts of its own tree under
        two names (libsyscall/mach/mach and darling/include/mach are the same files), and
        both spellings have to be indexed -- a label minted from either one has to resolve.
        Skipping a directory just because another name for it was already seen dropped
        every entry under the second spelling.
        """
        try:
            entries = sorted(os.scandir(d), key=lambda e: e.name)
        except OSError:
            return
        for e in entries:
            if e.is_dir():
                if e.name in SKIP_DIRS:
                    continue
                real = os.path.realpath(e.path)
                if real in chain or len(chain) > 24:  # a loop, or absurdly deep
                    continue
                walk(e.path, chain + (real,))
            else:
                yield_file(e.path)

    def yield_file(path: str):
        rel = os.path.relpath(path, root)
        key = export_target_name(rel)
        if key in index and index[key] != rel:
            clash.add(key)
            # Prefer the shallowest path, deterministically, so a regeneration does not
            # flip between two files that flatten to the same name.
            if (rel.count("/"), rel) < (index[key].count("/"), index[key]):
                index[key] = rel
            return
        index[key] = rel

    walk(root, (os.path.realpath(root),))
    if clash:
        print(f"  NOTE: {pin}: {len(clash)} name(s) are shared by several files; "
              "using the shallowest of each", file=sys.stderr)
    return index


def target_names(buck_path: str) -> set:
    if not os.path.exists(buck_path):
        return set()
    text = open(buck_path).read()
    if BEGIN in text:
        pre, rest = text.split(BEGIN, 1)
        text = pre + rest.split(END, 1)[1]
    return set(re.findall(r'name = "([^"]+)"', text))


def bzl_name(pkg: str) -> str:
    """buck-src/xnu -> exports_xnu.bzl; buck-src itself -> exports_buck_src.bzl."""
    tail = pkg[len("buck-src/"):] if pkg.startswith("buck-src/") else "buck_src"
    return "exports_" + tail


def render(pkg: str, exports: dict[str, str]) -> str:
    out = ["# GENERATED by scripts/buck-exports.py.",
           "#",
           f"# Files in {pkg} that other packages name by label:",
           "# {export target name: package-relative path}. The package's BUCK turns each",
           "# into an export_file, because a file attribute has to be a source of the",
           "# package that declares it.",
           "EXPORTS = {"]
    for name, rel in sorted(exports.items()):
        out.append(f'    "{name}": "{rel}",')
    out += ["}", ""]
    return "\n".join(out)


def block(pkg: str) -> str:
    return (BEGIN
            + f'load("//buck/generated:{bzl_name(pkg)}.bzl", "EXPORTS")\n'
            + "\n"
            + "# One export_file per file another package names by label, from the list\n"
            + "# scripts/buck-exports.py keeps.\n"
            + "[\n"
            + "    export_file(name = _n, src = _s, visibility = [\"PUBLIC\"])\n"
            + "    for _n, _s in EXPORTS.items()\n"
            + "]\n"
            + END)


def main(argv: list[str]) -> int:
    check = "--check" in argv
    pins = migrated_pins()
    wanted = scan_labels()
    stale, missing, wrote = [], [], 0

    hints = read_hints()
    packages = sorted(set(wanted) | {f"buck-src/{p}" for p in pins})
    for pkg in packages:
        pin = pkg[len("buck-src/"):] if pkg.startswith("buck-src/") else None
        names = wanted.get(pkg, set())
        buck = os.path.join(REPO, pkg, "BUCK")
        if pin and pin not in pins and not os.path.exists(buck):
            if names:
                missing.append(f"{pkg}: {len(names)} label(s) into a pin that is not a package")
            continue
        # buck-src holds every materialized pin, so walking it to resolve a name is not
        # an option: for that package the hints ARE the index.
        index = dict(hints.get(pkg, {}))
        if pin and names:
            index = {**pin_index(pin), **index}
        already = target_names(buck)
        exports, unresolved = {}, []
        for name in sorted(names):
            if name in already:
                continue  # a real target of that name already provides it
            rel = index.get(name)
            if rel is None:
                unresolved.append(name)
                continue
            exports[name] = rel
        for name in unresolved:
            missing.append(f"{pkg}:{name} does not resolve to a file in the package")

        out = os.path.join(REPO, "buck", "generated", bzl_name(pkg) + ".bzl")
        text = render(pkg, exports)
        have = open(out).read() if os.path.exists(out) else ""
        if not exports:
            # Nothing to export: drop the list and the block rather than leaving an
            # empty comprehension behind.
            if os.path.exists(out) and not check:
                os.remove(out)
            if os.path.exists(buck):
                btext = open(buck).read()
                if BEGIN in btext and not check:
                    pre, rest = btext.split(BEGIN, 1)
                    open(buck, "w").write(pre + rest.split(END, 1)[1])
            continue
        if have != text:
            if check:
                stale.append(os.path.relpath(out, REPO))
            else:
                open(out, "w").write(text)
                wrote += 1
        btext = open(buck).read() if os.path.exists(buck) else ""
        if BEGIN in btext:
            pre, rest = btext.split(BEGIN, 1)
            new = pre + block(pkg) + rest.split(END, 1)[1]
        else:
            new = (btext.rstrip("\n") + "\n\n" if btext.strip() else "") + block(pkg)
        # The comprehension calls export_file, which a pin that exported nothing before has
        # no reason to have loaded (crontabs, once the install rules started naming its man
        # pages). Adding the block without the load leaves the package unparseable.
        load = 'load("//buck/rules:files.bzl", "export_file")'
        if load not in new:
            new = load + "\n" + new
        if new != btext:
            if check:
                stale.append(f"{pkg}/BUCK")
            else:
                open(buck, "w").write(new)
        if not check:
            print(f"{pkg}: {len(exports)} export(s)")

    for m in missing:
        print(f"  MISSING {m}", file=sys.stderr)
    if check and (stale or missing):
        for s in stale:
            print(f"  STALE {s}", file=sys.stderr)
        return 1
    if not check:
        print(f"wrote {wrote} export list(s)")
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
