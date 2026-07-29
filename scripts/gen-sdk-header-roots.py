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
build` are materialized under buck-src/<pin>/ (scripts/buck-src.sh), so targets
are rewritten to that prefix.

Usage:
  scripts/gen-sdk-header-roots.py <namespace> [<namespace> ...]  > buck-src/sdk_headers.bzl
  scripts/gen-sdk-header-roots.py --list-pins <namespace> ...     # which pins are needed
"""
from __future__ import annotations

import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SDK_INCLUDE = os.path.join(
    REPO,
    "darwin/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include",
)
# Where scripts/buck-src.sh materializes pinned trees, relative to the repo root.
BUCK_SRC = "buck-src"


HEADER_EXTS = (".h", ".hpp", ".modulemap", ".defs")

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
                continue
            src_dir = os.path.join(REPO, BUCK_SRC, buck_rel)
            if not os.path.isdir(src_dir):
                continue
            for sub_dir, _, sub_files in os.walk(src_dir):
                for f in sorted(sub_files):
                    if not f.endswith(HEADER_EXTS):
                        continue
                    sub_rel = os.path.relpath(os.path.join(sub_dir, f), src_dir)
                    yield (
                        os.path.normpath(os.path.join(include_base, sub_rel)),
                        os.path.normpath(os.path.join(repo_rel, sub_rel)),
                    )


def to_buck_src(repo_rel: str) -> str | None:
    """`src/external/xnu/osfmk/mach/boolean.h` -> `xnu/osfmk/mach/boolean.h`.

    The returned path is relative to the buck-src package, where the materialized
    pins live. None means "not ours to map": either the file is committed repo
    content outside src/external, or it is one of the three trees under
    src/external that are COMMITTED rather than pinned (darlingserver, libtrace,
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


def main(argv: list[str]) -> int:
    list_pins = "--list-pins" in argv
    namespaces = [a for a in argv[1:] if not a.startswith("--")]
    if not namespaces:
        sys.exit(__doc__)

    pins: dict[str, int] = {}
    roots: dict[str, list[tuple[str, str]]] = {}
    skipped: dict[str, int] = {}

    for ns in namespaces:
        entries = []
        for include_path, repo_rel in walk_namespace(ns):
            pin = repo_rel.split("/")[2] if repo_rel.startswith("src/external/") else "(repo)"
            pins[pin] = pins.get(pin, 0) + 1
            buck_rel = to_buck_src(repo_rel)
            if buck_rel is None:
                key = "/".join(repo_rel.split("/")[:3 if repo_rel.startswith("src/external/") else 2])
                skipped[key] = skipped.get(key, 0) + 1
                continue
            entries.append((include_path, buck_rel))
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
                        value = os.path.relpath(os.path.join(dirpath, f), os.path.join(REPO, pkg))
                        by_pkg.setdefault(pkg, []).append((include_path, value))
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
        for pkg, entries in sorted(by_pkg.items()):
            name = "sdk_" + pkg.replace("/", "_").replace("-", "_") + "_headers"
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
