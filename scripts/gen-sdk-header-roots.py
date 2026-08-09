#!/usr/bin/env python3
"""Derive Buck2 header roots from the repo's committed SDK symlink farm.

Darling exposes Darwin's headers through
darwin/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include,
a tree of ~1900 committed relative symlinks into the pinned upstream sources.
Those symlinks ARE the authority on how the SDK's namespaces are assembled: the
SDK's `i386/` merges xnu/bsd/i386 with xnu/osfmk/i386, `libkern/` merges xnu with
libplatform and libc, and so on. No single prefix rule reproduces that.

Rather than hand-deriving it (hundreds of namespaces, and it would drift), this
reads the farm and emits `cc_header_root(header_map = {...})` declarations that
map each include path to the real source file. Result: a compile sees exactly the
SDK's headers under exactly the SDK's names, with no source tree on the include
path -- which is the whole point of the port (see plan/buck2-port.md wall #1).

The symlinks resolve to `src/external/<pin>/...`, which for a direct `buck2
build` are materialized under buck-src/<pin>/ (scripts/buck-src.nu), so targets
are rewritten to that prefix.

Usage:
  scripts/gen-sdk-header-roots.py <namespace> [<namespace> ...]  > buck-src/sdk_headers.bzl
  scripts/gen-sdk-header-roots.py --list-pins <namespace> ...     # which pins are needed
"""
from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SDK_INCLUDE = os.path.join(
    REPO,
    "darwin/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include",
)
# Where scripts/buck-src.nu materializes pinned trees, relative to the repo root.
BUCK_SRC = "buck-src"


# .c is included deliberately: Darling's SDK exposes implementation .c files under
# its cider/emulation namespace, and the emulation layer #includes them by path
# (<cider/emulation/.../setattrlist_generic.c>). Skipping them leaves those
# includes unresolved.
HEADER_EXTS = (".h", ".hpp", ".modulemap", ".defs", ".c")

# Headers that are real files inside the SDK tree, collected while walking. They
# are declared by a header root in the SDK directory's own package, where their
# paths are already package-relative (and are exactly the include paths).
REPO_SIDE: list[str] = []


def link_target_repo_rel(link_path: str) -> str | None:
    """Repo-relative path a farm symlink ultimately points at.

    The farm has three kinds of link, and one of them defeated hand-rolled chain
    following:
      * straight into a pinned tree (mach/boolean.h -> src/external/xnu/...),
      * INTRA-SDK (pthread.h -> pthread/pthread.h, itself a link into libpthread),
      * and links whose PARENT DIRECTORY is a link into a pinned tree
        (architecture/i386/desc.h under darwin/basic-headers/architecture ->
        src/external/architecture). Testing islink() on such a path returns False,
        because the parent cannot be traversed in a working copy where the pins
        are absent.

    realpath handles all three: it resolves every component textually and does NOT
    require the result to exist, which is what makes it usable here -- the pinned
    trees are not at src/external in the working copy at all.
    """
    real = os.path.realpath(link_path)
    repo_rel = os.path.relpath(real, REPO)
    return None if repo_rel.startswith("..") else repo_rel


def walk_namespace(ns: str):
    """Yield (include_path, repo_relative_source) for every header under `ns`.

    `include_path` is what a #include says, e.g. `mach/i386/vm_types.h`.
    Directory symlinks in the farm are expanded against the materialized tree,
    so a whole SDK subdirectory that is one symlink still yields its files.
    """
    root = os.path.join(SDK_INCLUDE, ns) if ns != "." else SDK_INCLUDE
    if not os.path.exists(root) and not os.path.islink(root):
        sys.exit(f"no such SDK namespace: {ns}")

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, SDK_INCLUDE)

        for name in sorted(filenames + dirnames):
            path = os.path.join(dirpath, name)
            if not os.path.islink(path):
                # A REAL file committed in the SDK tree (not a link into a pinned
                # tree): sys/_symbol_aliasing.h, sys/_posix_availability.h and
                # friends. It belongs to the SDK directory's own buck2 package, so
                # it is reported separately rather than mapped into buck-src.
                if os.path.isfile(path) and name.endswith(HEADER_EXTS):
                    REPO_SIDE.append(os.path.normpath(os.path.join(rel_dir, name)))
                continue
            repo_rel = link_target_repo_rel(path)
            if repo_rel is None:
                continue
            include_base = os.path.normpath(os.path.join(rel_dir, name))

            if name.endswith(HEADER_EXTS):
                yield include_base, repo_rel
                continue

            # A directory symlink (SDK/sys/_types -> .../libc/include/sys/_types):
            # expand it from the materialized tree so its headers get mapped too.
            buck_rel = to_buck_src(repo_rel)
            if buck_rel is None:
                # Not a pin but a COMMITTED repo tree, so expand it from the repo:
                # SDK/opendirectory -> src/opendirectory_internal/include/opendirectory
                # holds odipc.h, which Libinfo includes. Skipping these dropped the
                # whole namespace from both the pinned and the repo-side maps.
                src_dir = os.path.join(REPO, repo_rel)
            else:
                src_dir = os.path.join(REPO, BUCK_SRC, buck_rel)
            if not os.path.isdir(src_dir):
                continue
            for sub_dir, _, sub_files in os.walk(src_dir):
                for f in sorted(sub_files):
                    if not f.endswith(HEADER_EXTS):
                        continue
                    sub_path = os.path.join(sub_dir, f)
                    sub_rel = os.path.relpath(sub_path, src_dir)
                    # Inside a committed tree the entries are often themselves links
                    # into the pins (opendirectory/rb.h -> DirectoryService/...);
                    # follow them, or the map would name a source that is not
                    # checked out here.
                    target = os.path.normpath(os.path.join(repo_rel, sub_rel))
                    if buck_rel is None and os.path.islink(sub_path):
                        resolved = link_target_repo_rel(sub_path)
                        if resolved is not None:
                            target = resolved
                    yield (
                        os.path.normpath(os.path.join(include_base, sub_rel)),
                        target,
                    )


def to_buck_src(repo_rel: str) -> str | None:
    """`src/external/xnu/osfmk/mach/boolean.h` -> `xnu/osfmk/mach/boolean.h`.

    The returned path is relative to the buck-src package, where the materialized
    pins live. None means "not ours to map": either the file is committed repo
    content outside src/external, or it is one of the three trees under
    src/external that are COMMITTED rather than pinned (ciderd, libtrace,
    libpthread_workqueue), which therefore never appear in buck-src. Both cases
    belong to another buck2 package and need a header root there.
    """
    prefix = "src/external/"
    if not repo_rel.startswith(prefix):
        return None
    buck_rel = repo_rel[len(prefix):]
    if not os.path.exists(os.path.join(REPO, BUCK_SRC, buck_rel)):
        return None
    return buck_rel


# Upstream's SDK exposes a handful of headers under BOTH /usr/include/<x>.h and
# /usr/include/System/<x>.h. Darling's symlink farm carries only one spelling, so
# the other one is added here: objc4 includes <System/pthread_machdep.h>, and the
# reference build has no rule that would create it either.
# Pins already migrated to their own package (buck-src/<pin>/BUCK). Once that package
# exists, a header_map in buck-src/BUCK cannot name a file under it by PATH -- a
# subpackage owns its files. It can still name it by LABEL, which is what these maps do:
# a `header_map` value is an attrs.source(), and a source coerces from a label just as
# well as from a path. So the SDK stays ONE staged tree with one include order, and only
# the spelling of the value changes. scripts/buck-split-pins.py maintains this list, and
# scripts/buck-exports.py gives every label an export_file in the owning pin.
SPLIT_PINS_FILE = os.path.join(REPO, "buck", "generated", "split-pins.txt")


def split_pins() -> set:
    if not os.path.exists(SPLIT_PINS_FILE):
        return set()
    return {l.strip() for l in open(SPLIT_PINS_FILE) if l.strip() and not l.startswith("#")}


def pin_value(buck_rel: str, moved: set) -> str:
    """How a map refers to a pinned header: a path, or a label once the pin has split."""
    pin = buck_rel.split("/")[0]
    if pin not in moved:
        return buck_rel
    rel = buck_rel[len(pin) + 1:]
    return f"//{BUCK_SRC}/{pin}:" + re.sub(r"[^A-Za-z0-9_.+-]+", "_", rel)


ALIASES = {
    "System/pthread_machdep.h": "pthread_machdep.h",
    # Upstream also exposes the kernel headers under /usr/include/Kernel/; copyfile
    # includes <Kernel/sys/decmpfs.h> whenever VOL_CAP_FMT_DECMPFS_COMPRESSION is
    # defined, which sys/attr.h does.
    "Kernel/sys/decmpfs.h": "sys/decmpfs.h",
    # The SDK spells the same thing a second way for IOKit:
    #   Kernel.framework/Versions/A/Headers/IOKit -> IOKit.framework/Headers
    # so <Kernel/IOKit/X.h> and <IOKit/X.h> are one header. zprint and ioclasscount
    # both open the kernel's zone and IOKit debug interfaces through the Kernel/
    # spelling, and neither builds without it.
    "Kernel/IOKit/IOKitDebug.h": "IOKit/IOKitDebug.h",
}


def main(argv: list[str]) -> int:
    list_pins = "--list-pins" in argv
    argv_vals = set()
    for flag in ("--only",):
        if flag in argv:
            argv_vals.add(argv[argv.index(flag) + 1])
    namespaces = [a for a in argv[1:] if not a.startswith("--") and a not in argv_vals]
    if not namespaces:
        sys.exit(__doc__)

    pins: dict[str, int] = {}
    roots: dict[str, list[tuple[str, str]]] = {}
    skipped: dict[str, int] = {}

    for ns in namespaces:
        entries = []
        moved = split_pins()
        for include_path, repo_rel in walk_namespace(ns):
            pin = repo_rel.split("/")[2] if repo_rel.startswith("src/external/") else "(repo)"
            pins[pin] = pins.get(pin, 0) + 1
            buck_rel = to_buck_src(repo_rel)
            if buck_rel is None:
                key = "/".join(repo_rel.split("/")[:3 if repo_rel.startswith("src/external/") else 2])
                skipped[key] = skipped.get(key, 0) + 1
                continue
            entries.append((include_path, pin_value(buck_rel, moved)))
        by_path = dict(entries)
        for alias, real in ALIASES.items():
            if real in by_path and alias not in by_path:
                entries.append((alias, by_path[real]))
        roots[ns] = sorted(set(entries))

    if "--framework-roots" in argv:
        # The framework header surface. `#include <Foundation/NSString.h>` resolves
        # through -I darwin/framework-include, whose entries are symlinks named
        # after the framework:
        #   framework-include/Foundation -> ...Foundation.framework/Headers
        #     -> Versions/C/Headers -> src/external/foundation/include/Foundation
        # so the include path is <Framework>/<rel> and the source is whatever the
        # chain ends at.
        for tree, label in (
            ("darwin/framework-include", "framework"),
            ("darwin/framework-private-include", "framework_private"),
        ):
            root = os.path.join(REPO, tree)
            if not os.path.isdir(root):
                continue
            by_pkg: dict[str, list[tuple[str, str]]] = {}
            for name in sorted(os.listdir(root)):
                entry = os.path.join(root, name)
                real = os.path.realpath(entry)
                rel = os.path.relpath(real, REPO)
                if rel.startswith(".."):
                    continue
                buck_rel = to_buck_src(rel)
                src_dir = os.path.join(REPO, BUCK_SRC, buck_rel) if buck_rel else os.path.join(REPO, rel)
                if not os.path.isdir(src_dir):
                    continue
                pkg = BUCK_SRC if buck_rel else "/".join(rel.split("/")[:2])
                for dirpath, _, files in os.walk(src_dir):
                    for f in sorted(files):
                        if not f.endswith(HEADER_EXTS):
                            continue
                        sub = os.path.relpath(os.path.join(dirpath, f), src_dir)
                        include_path = os.path.normpath(os.path.join(name, sub))
                        fpath = os.path.join(dirpath, f)
                        # A committed framework tree can be a farm of its OWN: every
                        # SystemConfiguration header is a link into src/external/configd,
                        # which is a pin and therefore lives in buck-src, not at that path
                        # at all. Following it decides the owning package, and skipping
                        # that step produced a map naming 52 files that do not exist --
                        # which buck2 only reports when something first depends on them.
                        owner, rel_in_owner = pkg, os.path.relpath(fpath, os.path.join(REPO, pkg))
                        if os.path.islink(fpath) and not os.path.exists(fpath):
                            resolved = link_target_repo_rel(fpath)
                            in_pin = to_buck_src(resolved) if resolved else None
                            if in_pin:
                                owner, rel_in_owner = BUCK_SRC, in_pin
                        value = pin_value(rel_in_owner, split_pins()) if owner == BUCK_SRC else rel_in_owner
                        by_pkg.setdefault(owner, []).append((include_path, value))
            # One dict per FRAMEWORK, not one giant map: a target then declares the
            # frameworks it actually includes, instead of getting all 17k headers on
            # its search path the way the reference build does. Written per owning
            # package so a package only parses what it declares.
            for pkg, entries in sorted(by_pkg.items()):
                per_fw: dict[str, list[tuple[str, str]]] = {}
                for include_path, value in sorted(set(entries)):
                    per_fw.setdefault(include_path.split("/")[0], []).append((include_path, value))
                out = os.path.join(
                    REPO, "buck", "generated",
                    "sdk_" + label + "_" + pkg.replace("/", "_").replace("-", "_") + ".bzl",
                )
                with open(out, "w") as fh:
                    fh.write("# GENERATED by scripts/gen-sdk-header-roots.py --framework-roots.\n")
                    fh.write("#\n")
                    fh.write(f"# The {tree} headers owned by {pkg}, one entry per framework:\n")
                    fh.write("# {framework: {include path: source file}}. A target declares the\n")
                    fh.write("# frameworks it includes rather than getting the whole surface.\n")
                    fh.write("FRAMEWORKS = {\n")
                    for fw, items in sorted(per_fw.items()):
                        fh.write(f'    "{fw}": {{\n')
                        for include_path, value in items:
                            fh.write(f'        "{include_path}": "{value}",\n')
                        fh.write("    },\n")
                    fh.write("}\n")
                print(f"wrote {os.path.relpath(out, REPO)}: {len(per_fw)} frameworks, "
                      f"{len(set(entries))} headers ({pkg})", file=sys.stderr)
        return 0

    if "--pin-roots" in argv:
        # The same idea as --repo-roots, but for the PINS: one header root per pin,
        # declared inside buck-src/<pin>. That is the prerequisite for splitting
        # buck-src into a package per pin (plan/buck2-port.md phase 3): a subpackage
        # takes ownership of its files, so the monolithic maps in buck-src/BUCK stop
        # being able to name them the moment buck-src/<pin>/BUCK exists.
        by_pin: dict[str, list[tuple[str, str]]] = {}
        for ns in namespaces:
            for include_path, repo_rel in walk_namespace(ns):
                buck_rel = to_buck_src(repo_rel)
                if buck_rel is None:
                    continue
                pin = buck_rel.split("/")[0]
                by_pin.setdefault(pin, []).append((include_path, buck_rel[len(pin) + 1:]))
        apply = "--apply" in argv
        only = argv[argv.index("--only") + 1].split(",") if "--only" in argv else None
        labels = []
        for pin, entries in sorted(by_pin.items()):
            if only and pin not in only:
                continue
            name = "sdk_pin_" + re.sub(r"[^A-Za-z0-9_]+", "_", pin).strip("_") + "_headers"
            labels.append(f"//{BUCK_SRC}/{pin}:{name}")
            block = ["# BEGIN generated: sdk pin headers",
                     "# This pin's share of the Darwin SDK header surface. One root per pin, so",
                     "# buck-src can be split into a package per pin: a subpackage owns its files,",
                     "# and a map in the parent package cannot name them.",
                     "# GENERATED by scripts/gen-sdk-header-roots.py --pin-roots.",
                     "cc_header_root(",
                     f'    name = "{name}",',
                     "    header_map = {"]
            for include_path, rel in sorted(set(entries)):
                block.append(f'        "{include_path}": "{rel}",')
            block += ["    },", '    visibility = ["PUBLIC"],', ")",
                      "# END generated: sdk pin headers"]
            text = "\n".join(block) + "\n"
            if not apply:
                print(f"### {BUCK_SRC}/{pin}/BUCK  ({len(set(entries))} headers)")
                continue
            d = os.path.join(REPO, BUCK_SRC, pin)
            os.makedirs(d, exist_ok=True)
            f = os.path.join(d, "BUCK")
            existing = open(f).read() if os.path.exists(f) else ""
            begin, end = "# BEGIN generated: sdk pin headers\n", "# END generated: sdk pin headers\n"
            if begin in existing:
                pre, rest = existing.split(begin, 1)
                _, post = rest.split(end, 1)
                new = pre + text + post
            else:
                head = 'load("//buck/rules:cc.bzl", "cc_header_root")\n\n' if not existing else ""
                new = (existing.rstrip() + "\n\n" if existing.strip() else head) + text
            with open(f, "w") as fh:
                fh.write(new)
            print(f"wrote {BUCK_SRC}/{pin}/BUCK: {name} ({len(set(entries))} headers)",
                  file=sys.stderr)
        if apply:
            print("# sdk_env deps for darwin/BUCK:")
            for lb in labels:
                print(f'        "{lb}",')
        else:
            print(f"# {len(by_pin)} pins carry SDK headers")
        return 0

    if "--repo-roots" in argv:
        # The SDK headers that live in COMMITTED repo trees rather than pinned
        # ones. Each owning package needs its own header root, because a
        # header_map's values must be sources in the declaring package.
        by_pkg: dict[str, list[tuple[str, str]]] = {}
        for ns in namespaces:
            for include_path, repo_rel in walk_namespace(ns):
                if to_buck_src(repo_rel) is not None:
                    continue
                parts = repo_rel.split("/")
                pkg = "/".join(parts[:3]) if repo_rel.startswith("src/external/") else "/".join(parts[:2])
                if not os.path.isdir(os.path.join(REPO, pkg)):
                    continue
                rel_in_pkg = os.path.relpath(repo_rel, pkg)
                by_pkg.setdefault(pkg, []).append((include_path, rel_in_pkg))
        apply = "--apply" in argv
        labels = []
        for pkg, entries in sorted(by_pkg.items()):
            name = "sdk_" + pkg.replace("/", "_").replace("-", "_") + "_headers"
            labels.append(f"//{pkg}:{name}")
            if apply:
                block = ["# BEGIN generated: sdk headers"]
                block.append("# SDK headers this package owns: the Darwin SDK tree reaches them by")
                block.append("# symlink, and a header_map's values must be sources in the declaring")
                block.append("# package. GENERATED by scripts/gen-sdk-header-roots.py --repo-roots.")
                block.append("cc_header_root(")
                block.append(f'    name = "{name}",')
                block.append("    header_map = {")
                for include_path, rel in sorted(set(entries)):
                    block.append(f'        "{include_path}": "{rel}",')
                block.append("    },")
                block.append('    visibility = ["PUBLIC"],')
                block.append(")")
                block.append("# END generated: sdk headers")
                text = "\n".join(block) + "\n"
                f = os.path.join(REPO, pkg, "BUCK")
                existing = open(f).read() if os.path.exists(f) else ""
                begin, end = "# BEGIN generated: sdk headers\n", "# END generated: sdk headers\n"
                if begin in existing:
                    pre, rest = existing.split(begin, 1)
                    _, post = rest.split(end, 1)
                    new_text = pre + text + post
                elif f'name = "{name}"' in existing:
                    # An older hand-placed copy of the same root: replace that block
                    # rather than adding a second definition of the same target.
                    i = existing.rindex("cc_header_root(", 0, existing.index(f'name = "{name}"'))
                    j = existing.index("\n)\n", i) + len("\n)\n")
                    new_text = existing[:i] + text + existing[j:]
                else:
                    head = 'load("//buck/rules:cc.bzl", "cc_header_root")\n\n' if not existing else ""
                    new_text = (existing.rstrip() + "\n\n" if existing.strip() else head) + text
                with open(f, "w") as fh:
                    fh.write(new_text)
                print(f"wrote {pkg}/BUCK: {name} ({len(set(entries))} headers)", file=sys.stderr)
                continue
            print(f"### {pkg}/BUCK")
            print('load("//buck/rules:cc.bzl", "cc_header_root")')
            print()
            print("# SDK headers this package owns: the Darwin SDK tree reaches them by")
            print("# symlink, and a header_map's values must be sources in the declaring")
            print("# package. GENERATED by scripts/gen-sdk-header-roots.py --repo-roots.")
            print("cc_header_root(")
            print(f'    name = "{name}",')
            print("    header_map = {")
            for include_path, rel in sorted(set(entries)):
                print(f'        "{include_path}": "{rel}",')
            print("    },")
            print('    visibility = ["PUBLIC"],')
            print(")")
            print()
        if apply:
            print("# sdk_env deps for darwin/BUCK:")
            for label in labels:
                print(f'        "{label}",')
        return 0

    if list_pins:
        for pin, count in sorted(pins.items(), key=lambda kv: -kv[1]):
            print(f"{count:5d}  src/external/{pin}" if pin != "(repo)" else f"{count:5d}  (repo)")
        return 0

    print("# GENERATED by scripts/gen-sdk-header-roots.py -- do not edit.")
    print("#")
    print("# Derived from the repo's committed SDK symlink farm")
    print("# (darwin/Developer/.../MacOSX.sdk/usr/include), which is the authority on how")
    print("# Darwin's header namespaces are assembled from the pinned upstream trees.")
    print("# Regenerate after materializing more pins:")
    print("#   scripts/gen-sdk-header-roots.py " + " ".join(namespaces) + " > buck-src/sdk_headers.bzl")
    print()
    for ns, entries in roots.items():
        var = "SDK_" + ns.replace("/", "_").replace(".", "ROOT").upper()
        print(f"# {ns}/: {len(entries)} headers")
        print(f"{var} = {{")
        for include_path, buck_rel in entries:
            print(f'    "{include_path}": "{buck_rel}",')
        print("}")
        print()
    if REPO_SIDE:
        print("# Real files committed inside the SDK tree (not links into a pinned tree).")
        print("# Declared by the header root in the SDK directory's own package, where these")
        print("# paths are both the file paths and the include paths.")
        print("SDK_REPO_HEADERS = [")
        for h in sorted(set(REPO_SIDE)):
            print(f'    "{h}",')
        print("]")
        print()

    if skipped:
        print("# Headers skipped: they live in another buck2 package (committed repo")
        print("# content, or one of the committed trees under src/external), so they need a")
        print("# header root declared in the package that owns them:")
        for top, count in sorted(skipped.items()):
            print(f"#   {count:4d} under {top}/")
        print("# skipped:", file=sys.stderr)
        for top, count in sorted(skipped.items()):
            print(f"#   {count:4d} under {top}/", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
