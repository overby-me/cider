#!/usr/bin/env python3
"""Generate the Darling PREFIX layout from the reference build's install manifests.

build.ninja cannot answer what a prefix contains: `install` is one opaque edge that shells
out to `cmake -P cmake_install.cmake`. The real statement is the per-directory
cmake_install.cmake files cmake writes at configure time, which nix/lib/darling-graph.nix
ships under install-manifests/. This reads them and emits prefix_tree / prefix_dir rules
(buck/rules/install.bzl) so the layout is GENERATED from the reference, like every other part
of this port, instead of transcribed from 89 install() calls by hand.

The entry kinds and what each becomes:

  SHARED_LIBRARY  a built dylib      -> a prefix_tree `entries` label, via the registries
  EXECUTABLE      a built binary     -> a prefix_tree `entries` label, by output basename
  FILE            a source file      -> a prefix_tree `files` entry, repo-relative
  FILE            a build symlink    -> a prefix_tree `symlinks` entry (see below)
  DIRECTORY       a source directory -> a prefix_dir target in the PIN's package, mapped in

Two things the manifests do not say on their own:

  * A symlink installed through cmake/InstallSymlink.cmake arrives as an ordinary FILE whose
    source happens to be a symlink in the build tree. Its TARGET exists only in the link
    itself, so darling-graph.nix records every build-tree link in install-symlinks.tsv and
    this reads that back. bin/sh -> bash is the one that matters for bash.
  * A dylib that goes through cmake's POST_BUILD lipo is installed under the lipo output's
    name while the port builds the linker's output (CoreFoundation vs
    CoreFoundation_x86_64). Resolved by falling back to the _<arch> name.

Anything that cannot be mapped is REPORTED, never dropped silently: a prefix missing one
dylib fails at runtime, a long way from here.

Usage:
  scripts/gen-install-from-manifests.py [--manifests <graph dir>] [--write]
"""
from __future__ import annotations

import importlib.util
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARCH = "x86_64"
ENTRY = re.compile(
    r'file\(INSTALL DESTINATION "([^"]+)"\s+TYPE (\w+)(?:\s+\w+)*\s+FILES? (.*?)\)\n',
    re.S)
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
# `REGEX "..." EXCLUDE`, which follows the file list.
EXCLUDE = re.compile(r'REGEX "((?:[^"\\]|\\.)*)" EXCLUDE')

# Artifacts the reference GENERATES with a custom command rather than linking, so no registry
# knows them. Ported by hand and listed here, so the mapping is visible rather than buried in
# a fallback that would just as happily match the wrong thing.
GENERATED = {
    "icudt66l.dat": "//buck-src/icu:icudt66l_dat",
}

# Destinations deliberately left out of the prefix, with the reason. Counted apart from
# UNMAPPED so "what is missing" stays a number that can reach zero.
OUT_OF_SCOPE = {
    "libexec/darling/usr/lib/libstdc++.6.dylib":
        "libstdc++ is not ported (scripts/buck-coverage.py OUT_OF_SCOPE: GCC 4.2.1's "
        "vendored headers do not compile against this SDK), and nothing links it",
}


def load_gen():
    spec = importlib.util.spec_from_file_location(
        "gen", os.path.join(REPO, "scripts", "gen-buck-from-ninja.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def graph_dir(argv: list[str]) -> str:
    if "--manifests" in argv:
        return argv[argv.index("--manifests") + 1]
    return os.path.realpath(os.path.join(REPO, "result-graph-ref"))


def read_entries(root: str):
    """[(destination, type, [sources], [exclude regexes])] over every manifest."""
    out = []
    seen = 0
    for dirpath, _dirs, files in os.walk(root):
        if "cmake_install.cmake" not in files:
            continue
        seen += 1
        text = open(os.path.join(dirpath, "cmake_install.cmake")).read()
        for dest, kind, blob in ENTRY.findall(text):
            dest = dest.replace("${CMAKE_INSTALL_PREFIX}/", "").rstrip("/")
            # The excludes are quoted strings too, so the file list is what comes BEFORE the
            # first REGEX. Splitting there keeps `/Makefile$` from being read as a file.
            head = blob.split(" REGEX ", 1)[0]
            out.append((dest, kind, STRING.findall(head), EXCLUDE.findall(blob)))
    # Loudly, because an empty walk is indistinguishable from a prefix with nothing in it,
    # and a manifest directory that has been garbage-collected or moved is the likely cause.
    if not seen:
        sys.exit(f"no cmake_install.cmake under {root} -- is the graph output still present?")
    return out


def read_symlinks(graph: str) -> dict:
    """{build-relative path: link value} for every symlink configure left in the build tree."""
    path = os.path.join(graph, "install-symlinks.tsv")
    if not os.path.isfile(path):
        return {}
    links = {}
    for line in open(path):
        line = line.rstrip("\n")
        if not line:
            continue
        p, _, target = line.partition("\t")
        links[p.removeprefix("./")] = target
    return links


def binary_index() -> dict:
    """{output name: label} for every executable and framework binary the port builds.

    The registries cover dylibs and archives only, but half the prefix is executables (dyld,
    notifyd, syslogd) and framework binaries (CoreFoundation), whose artifact name is the
    TARGET name. Scanning the BUCK files for those rules is how buck-coverage.py already
    identifies them.
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
    for table in (gen.final_registry(), gen.archive_registry(), binaries, GENERATED):
        if base in table:
            return table[base]
    # cmake's POST_BUILD lipo renames the linker's output, and the port builds the linker's:
    # CoreFoundation is what gets installed, CoreFoundation_x86_64 is what exists. A
    # single-arch lipo -create is a rename here, so the thin file is the same artifact under
    # the name the install destination gives it.
    return binaries.get(f"{base}_{ARCH}")


def source_rel(path: str) -> str | None:
    """A source path relative to the repo, or None if it is not from the source tree."""
    # The manifests name the cmake source as a store path; everything after the store
    # entry's name is repo-relative.
    m = re.match(r"/nix/store/[a-z0-9]{32}-[^/]+/(.*)", path)
    if m:
        return m.group(1)
    if path.startswith(REPO + "/"):
        return path[len(REPO) + 1:]
    return None


def build_rel(path: str) -> str | None:
    """A build-tree path relative to the build directory, or None."""
    m = re.match(r"/build/build/(.*)", path)
    return m.group(1) if m else None


def pin_of(rel: str):
    """(pin, path within the pin) for a src/external/<pin>/... source path."""
    m = re.match(r"src/external/([^/]+)/(.*)", rel)
    return (m.group(1), m.group(2)) if m else (None, None)


def regex_to_glob(rx: str) -> str:
    """cmake's REGEX ... EXCLUDE as a buck2 glob exclusion.

    Only the shapes Darling actually uses, and a hard failure otherwise: a silently dropped
    exclusion puts Makefiles and .py files into the prefix, which is exactly the sort of
    difference nobody notices until something reads one.
    """
    if not rx.startswith("/") or not rx.endswith("$"):
        sys.exit(f"exclude regex is not anchored the way this understands: {rx}")
    # The manifest holds a cmake STRING containing a regex, so its backslashes are doubled:
    # `/\\.gitignore$` on disk is the regex `/\.gitignore$`. Undo one level first.
    body = rx[1:-1].replace("\\\\", "\\").replace("[^/]*", "*").replace("\\.", ".")
    if re.search(r"[\[\]()|+?^$\\]", body):
        sys.exit(f"exclude regex too rich to convert to a glob: {rx}")
    return f"**/{body}"


def dir_target(rel: str, excludes: list[str]):
    """The prefix_dir target for an install(DIRECTORY) source: (label, package, block)."""
    pin, within = pin_of(rel)
    if pin is None:
        return None
    pkg = f"buck-src/{pin}"
    if not os.path.isdir(os.path.join(REPO, pkg)):
        return None
    # cmake reaches out of a source directory with .. (libc installs its sibling's assets).
    within = os.path.normpath(within)
    if within.startswith(".."):
        return None
    name = "prefix_" + re.sub(r"[^A-Za-z0-9_]", "_", within)
    ex = "".join(f'\n            "{regex_to_glob(r)}",' for r in excludes)
    block = (f'prefix_dir(\n'
             f'    name = "{name}",\n'
             f'    srcs = glob(\n'
             f'        ["{within}/**"],\n'
             f'        exclude = [{ex}{chr(10) + "        " if ex else ""}],\n'
             f'    ),\n'
             f'    strip = "{within}",\n'
             f'    visibility = ["PUBLIC"],\n'
             f')\n')
    return (f"//{pkg}:{name}", pkg, block)


def write_block(pkg: str, blocks: list[str]) -> None:
    """Replace the generated prefix-dirs block in a pin's BUCK file, creating it if absent."""
    path = os.path.join(REPO, pkg, "BUCK")
    begin = "# BEGIN generated: prefix dirs"
    end = "# END generated: prefix dirs"
    body = (f"{begin}\n"
            "# GENERATED from the reference build's install(DIRECTORY) entries by\n"
            "# scripts/gen-install-from-manifests.py -- review before committing.\n\n"
            + "\n".join(blocks) + f"{end}\n")
    text = open(path).read() if os.path.isfile(path) else ""
    if begin in text:
        text = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n", body, text,
                      flags=re.S)
    else:
        text = text.rstrip("\n") + ("\n\n" if text.strip() else "") + body
    if 'load("//buck/rules:install.bzl", "prefix_dir")' not in text:
        text = 'load("//buck/rules:install.bzl", "prefix_dir")\n' + text
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)


def main(argv: list[str]) -> int:
    gen = load_gen()
    graph = graph_dir(argv)
    root = os.path.join(graph, "install-manifests")
    if not os.path.isdir(root):
        sys.exit(f"no install manifests at {root} -- build .#darling-graph first")

    binaries = binary_index()
    links = read_symlinks(graph)
    entries = read_entries(root)

    # Where each installed source ends up, so a symlink can be expressed against the
    # DESTINATION of the thing it points at rather than against a build path.
    dest_of = {}
    for dest, _kind, files, _ex in entries:
        for src in files:
            if src:
                base = os.path.basename(src)
                dest_of[src] = f"{dest}/{base}" if dest else base

    built, sources, symlinks, dirs, unmapped, skipped = {}, {}, {}, {}, [], []
    blocks: dict[str, list[str]] = {}
    for dest, kind, files, excludes in entries:
        for src in files:
            if not src:
                continue
            full = dest_of[src]
            if full in OUT_OF_SCOPE:
                skipped.append(full)
                continue
            if kind in ("SHARED_LIBRARY", "EXECUTABLE", "STATIC_LIBRARY"):
                t = target_for(src, gen, binaries)
                if t:
                    built[full] = t
                else:
                    unmapped.append((full, "no target builds it"))
            elif kind == "FILE":
                brel = build_rel(src)
                if brel is not None and brel in links:
                    # A symlink InstallSymlink left in the build tree. Its value is relative
                    # to the link itself, so resolve it there and ask where THAT lands.
                    target = os.path.normpath(os.path.join(os.path.dirname(src), links[brel]))
                    if target in dest_of:
                        symlinks[full] = dest_of[target]
                    else:
                        unmapped.append((full, f"links to {links[brel]}, which is not installed"))
                    continue
                rel = source_rel(src)
                if rel:
                    sources[full] = rel
                    continue
                t = target_for(src, gen, binaries)
                if t:
                    built[full] = t
                else:
                    unmapped.append((full, "build output with no target"))
            elif kind == "DIRECTORY":
                rel = source_rel(src)
                info = dir_target(rel, excludes) if rel else None
                if info is None:
                    unmapped.append((dest, f"install(DIRECTORY) of {src[-50:]}, not a pin path"))
                    continue
                label, pkg, block = info
                # A trailing slash means the CONTENTS go to the destination; without one the
                # directory itself does, under its own name.
                where = dest if src.endswith("/") else f"{dest}/{os.path.basename(rel)}"
                dirs[where] = label
                blocks.setdefault(pkg, [])
                if block not in blocks[pkg]:
                    blocks[pkg].append(block)
            else:
                unmapped.append((full, f"unhandled install type {kind}"))

    print(f"install entries: {len(entries)}")
    print(f"  built artifacts mapped to targets: {len(built)}")
    print(f"  source files:                      {len(sources)}")
    print(f"  symlinks:                          {len(symlinks)}")
    print(f"  directories:                       {len(dirs)}")
    print(f"  out of scope:                      {len(skipped)}")
    print(f"  UNMAPPED:                          {len(unmapped)}")
    for full, why in unmapped:
        print(f"      {full}  ({why})")

    if "--write" not in argv:
        return 0

    for pkg, bs in sorted(blocks.items()):
        write_block(pkg, bs)
        print(f"wrote {pkg}/BUCK: {len(bs)} prefix_dir target(s)")

    lines = ['load("//buck/rules:install.bzl", "prefix_tree")', "",
             "# GENERATED from the reference build's cmake_install.cmake manifests by",
             "# scripts/gen-install-from-manifests.py -- review before committing.",
             "prefix_tree(",
             '    name = "darling_prefix",',
             "    entries = {"]
    for dest in sorted(built):
        lines.append(f'        "{dest}": "{built[dest]}",')
    for dest in sorted(dirs):
        lines.append(f'        "{dest}": "{dirs[dest]}",')
    lines += ["    },", "    files = {"]
    for dest in sorted(sources):
        lines.append(f'        "{dest}": "{sources[dest]}",')
    lines += ["    },", "    symlinks = {"]
    for dest in sorted(symlinks):
        lines.append(f'        "{dest}": "{symlinks[dest]}",')
    lines += ["    },", '    visibility = ["PUBLIC"],', ")", ""]

    out = os.path.join(REPO, "buck", "prefix", "BUCK")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w").write("\n".join(lines))
    print(f"wrote buck/prefix/BUCK: {len(built) + len(dirs)} target(s), "
          f"{len(sources)} file(s), {len(symlinks)} symlink(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
