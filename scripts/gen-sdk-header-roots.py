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
    """Repo-relative path a farm symlink points at, resolved TEXTUALLY.

    Textually, not with realpath: the targets are `src/external/<pin>/...`, which
    does not exist in the working copy at all (the pins live in buck-src/ for the
    Buck2 build, and only in the nix store otherwise). So resolving on disk would
    just report everything as dangling.
    """
    target = os.readlink(link_path)
    if os.path.isabs(target):
        return None
    joined = os.path.normpath(os.path.join(os.path.dirname(link_path), target))
    repo_rel = os.path.relpath(joined, REPO)
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
