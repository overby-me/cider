#!/usr/bin/env python3
"""Generate the Darling PREFIX layout from the reference build's install manifests.

build.ninja cannot answer what a prefix contains: `install` is one opaque edge that shells
out to `cmake -P cmake_install.cmake`. The real statement is the per-directory
cmake_install.cmake files cmake writes at configure time, which nix/lib/darling-graph.nix
now ships under install-manifests/. This reads them and emits a prefix_tree
(buck/rules/install.bzl) so the layout is GENERATED from the reference, like every other
part of this port, instead of transcribed from 89 install() calls by hand.

The four entry kinds and what each becomes:

  SHARED_LIBRARY  a built dylib      -> a target, via the port's final/archive registries
  EXECUTABLE      a built binary     -> a target, by output basename
  FILE            a source file      -> a `files` entry, repo-relative
  DIRECTORY       a source directory -> expanded to its files, since a prefix_tree maps
                                        destinations to artifacts, not trees

Anything that cannot be mapped is REPORTED, never dropped silently: a prefix missing one
dylib fails at runtime, a long way from here.

Usage:
  scripts/gen-install-from-manifests.py [--manifests <dir>] [--write] [--limit N]
"""
from __future__ import annotations

import importlib.util
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTRY = re.compile(
    r'file\(INSTALL DESTINATION "([^"]+)"\s+TYPE (\w+)(?:\s+\w+)*\s+FILES? (.*?)\)\n',
    re.S)
STRING = re.compile(r'"([^"]*)"')


def load_gen():
    spec = importlib.util.spec_from_file_location(
        "gen", os.path.join(REPO, "scripts", "gen-buck-from-ninja.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def manifest_dir(argv: list[str]) -> str:
    if "--manifests" in argv:
        return argv[argv.index("--manifests") + 1]
    # The reference graph the port already reads from.
    ref = os.path.join(REPO, "result-graph-ref")
    return os.path.join(os.path.realpath(ref), "install-manifests")


def read_entries(root: str):
    """[(destination, type, [source paths])] over every manifest."""
    out = []
    for dirpath, _dirs, files in os.walk(root):
        if "cmake_install.cmake" not in files:
            continue
        text = open(os.path.join(dirpath, "cmake_install.cmake")).read()
        for dest, kind, files_blob in ENTRY.findall(text):
            dest = dest.replace("${CMAKE_INSTALL_PREFIX}/", "").rstrip("/")
            out.append((dest, kind, STRING.findall(files_blob)))
    return out


def binary_index() -> dict:
    """{output name: label} for every executable and framework binary the port builds.

    The registries cover dylibs and archives only, but half the prefix is executables
    (dyld, notifyd, syslogd) and framework binaries (CoreFoundation), whose artifact name
    is the TARGET name. Scanning the BUCK files for those rules is how buck-coverage.py
    already identifies them.
    """
    index = {}
    for dirpath, dirnames, files in os.walk(REPO):
        dirnames[:] = [d for d in dirnames
                       if d not in ("buck-out", ".git", ".jj", ".direnv", "build")]
        if "BUCK" not in files:
            continue
        pkg = os.path.relpath(dirpath, REPO)
        text = open(os.path.join(dirpath, "BUCK")).read()
        for m in re.finditer(
                r'(darwin_binary|cc_binary|darwin_dylib)\(\n(?:.*?\n)*?\)\n', text):
            block = m.group(0)
            name = re.search(r'name = "([^"]+)"', block)
            if not name:
                continue
            label = f"//{pkg}:{name.group(1)}"
            index.setdefault(name.group(1), label)
            # A dylib rule names its own output, which for a framework is not <name>.dylib.
            out = re.search(r'dylib_name = "([^"]+)"', block)
            if out:
                index.setdefault(out.group(1), label)
                index.setdefault(out.group(1).removesuffix(".dylib"), label)
    return index


def target_for(path: str, gen, binaries: dict) -> str | None:
    """The buck2 target that builds this artifact, by output basename.

    The reference paths are build-dir absolute (/build/build/src/libm/libsystem_m.dylib);
    what identifies the artifact across both builds is its NAME, which is also the key the
    port's registries use.
    """
    base = os.path.basename(path)
    finals = gen.final_registry()
    if base in finals:
        return finals[base]
    archives = gen.archive_registry()
    if base in archives:
        return archives[base]
    return binaries.get(base)


def source_rel(path: str) -> str | None:
    """A source file's path relative to the repo, or None if it is not from the source."""
    # The manifests name the cmake source as a store path; everything after the store
    # entry's name is repo-relative.
    m = re.match(r"/nix/store/[a-z0-9]{32}-[^/]+/(.*)", path)
    if m:
        return m.group(1)
    if path.startswith(REPO + "/"):
        return path[len(REPO) + 1:]
    return None


def main(argv: list[str]) -> int:
    gen = load_gen()
    root = manifest_dir(argv)
    if not os.path.isdir(root):
        sys.exit(f"no install manifests at {root} -- build .#darling-graph first")

    binaries = binary_index()
    entries = read_entries(root)
    built, sources, unmapped, dirs = {}, {}, [], []
    for dest, kind, files in entries:
        for src in files:
            if not src:
                continue
            name = os.path.basename(src)
            full = f"{dest}/{name}" if dest else name
            if kind in ("SHARED_LIBRARY", "EXECUTABLE", "STATIC_LIBRARY"):
                t = target_for(src, gen, binaries)
                if t:
                    built[full] = t
                else:
                    unmapped.append((full, src))
            elif kind == "FILE":
                rel = source_rel(src)
                if rel:
                    sources[full] = rel
                else:
                    unmapped.append((full, src))
            elif kind == "DIRECTORY":
                dirs.append((dest, src))
            else:
                unmapped.append((full, src))

    print(f"install entries: {len(entries)}")
    print(f"  built artifacts mapped to targets: {len(built)}")
    print(f"  source files:                      {len(sources)}")
    print(f"  directory installs (not expanded): {len(dirs)}")
    print(f"  UNMAPPED:                          {len(unmapped)}")
    for full, src in unmapped[:10]:
        print(f"      {full}  <-  {src[-70:]}")

    if "--write" not in argv:
        return 0

    lines = ['load("//buck/rules:install.bzl", "prefix_tree")', "",
             "# GENERATED by scripts/gen-install-from-manifests.py from the reference build's",
             "# cmake_install.cmake manifests -- review before committing.",
             "prefix_tree(",
             '    name = "darling_prefix",',
             "    entries = {"]
    for dest in sorted(built):
        lines.append(f'        "{dest}": "{built[dest]}",')
    lines += ["    },", "    files = {"]
    for dest in sorted(sources):
        lines.append(f'        "{dest}": "{sources[dest]}",')
    lines += ["    },", '    visibility = ["PUBLIC"],', ")", ""]

    out = os.path.join(REPO, "buck", "prefix", "BUCK")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w").write("\n".join(lines))
    print(f"wrote {os.path.relpath(out, REPO)}: {len(built)} target(s), {len(sources)} file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
