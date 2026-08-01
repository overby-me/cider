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
# The prefix the reference configures with. cmake writes it into DESTINATION paths two
# ways -- as ${CMAKE_INSTALL_PREFIX} and, for a few targets, literally -- and both
# spellings have to come off before a path can be used as a prefix-relative one.
INSTALL_PREFIX = "/usr/local"
# \s+ after FILES, not a literal space: cmake puts a SINGLE file on the same line
# ("... FILES \"/nix/store/.../diskutil\"") and a LIST on the lines below it. Requiring a
# space matched only the first spelling, so every multi-file install entry in the build was
# read as no entry at all -- silently, since a manifest that parses to nothing looks exactly
# like a manifest with nothing in it. dirserv's three Directory Services stubs went missing
# that way, and they are what tests/darling-smoke.nix stage 7 drives.
ENTRY = re.compile(
    r'file\(INSTALL DESTINATION "([^"]+)"\s+TYPE (\w+)((?:\s+\w+)*)\s+FILES?\s+(.*?)\)\n',
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

# What the reference does NOT install, but a runnable Darling needs.
#
# The Rust rewrite replaced the C darlingserver, launcher and mldr, and none of the three
# appears in any install manifest: nix/package.nix places them by hand after cmake has run.
# The prefix is what a Darling install IS, so it carries them here instead, at the paths the
# launcher looks for -- it execs INSTALL_PREFIX/bin/darlingserver and the plain name is what
# keeps /proc/<pid>/comm reading "darlingserver".
EXTRA = {
    "bin/darling": "//linux/launcher:darling",
    "bin/darlingserver": "//linux/server:darlingserverd",
    "libexec/darling/usr/libexec/darling/mldr": "//darwin/loader:mldr",
}

# install(DIRECTORY) entries whose source is a BUILD output, with the hand-written target
# that produces the same tree. dir_target() can only reach a pin's own files -- it globs, and
# a glob cannot see something no action has written yet -- so a GENERATED directory has to be
# named here. Keyed by the prefix-relative destination the directory lands at.
EXTRA_DIRS = {
    # Security's trust store, built from the 159 .crt files and evroot.config by
    # buck-src/openssl_certificates/scripts/generate-ca-bundle.py.
    "libexec/darling/System/Library/Security/Certificates.bundle":
        "//buck-src:certificates_bundle",
}

# Destinations deliberately left out of the prefix, with the reason. Counted apart from
# UNMAPPED so "what is missing" stays a number that can reach zero.
OUT_OF_SCOPE = {
    "libexec/darling/usr/lib/libstdc++.6.dylib":
        "libstdc++ is not ported (scripts/buck-coverage.py OUT_OF_SCOPE: GCC 4.2.1's "
        "vendored headers do not compile against this SDK), and nothing links it",
    # Two links the REFERENCE build leaves dangling, so the port has nothing to point them
    # at. buck-src/file_cmds/CMakeLists.txt:96 says
    # InstallSymlink(zdiff libexec/darling/usr/bin/zcmp), but zdiff installs to
    # libexec/darling/BIN (line 76), and a link value with no ../.. resolves next to the
    # link -- in usr/bin, where no zdiff exists. Line 97 is worse: InstallSymlink(zless ...)
    # names a file no install() in the tree mentions at all. Two lines above them,
    # InstallSymlink(../sbin/chown libexec/darling/usr/bin/chgrp) shows the spelling that
    # does cross directories, so this is a slip rather than a convention. Reproducing a
    # broken link is not worth failing the prefix rule's consistency check over, and fixing
    # it belongs upstream, not in a port whose whole discipline is matching the reference.
    "libexec/darling/usr/bin/zcmp":
        "the reference links it to zdiff, which installs to libexec/darling/bin rather "
        "than the usr/bin the link resolves in (file_cmds/CMakeLists.txt:96)",
    "libexec/darling/usr/bin/zmore":
        "the reference links it to zless, which no install() in the tree provides "
        "(file_cmds/CMakeLists.txt:97)",
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


# Sources whose install entry grants an EXECUTE permission. Kept beside the entries rather
# than in them because only the FILE branch cares, and every other reader of an entry would
# have to carry a field it ignores.
EXEC_SOURCES: set = set()


def read_entries(root: str):
    """[(destination, type, [sources], [exclude regexes])] over every manifest."""
    out = []
    seen = 0
    for dirpath, _dirs, files in os.walk(root):
        if "cmake_install.cmake" not in files:
            continue
        seen += 1
        text = open(os.path.join(dirpath, "cmake_install.cmake")).read()
        for dest, kind, perms, blob in ENTRY.findall(text):
            dest = dest.replace("${CMAKE_INSTALL_PREFIX}/", "").rstrip("/")
            # Not every DESTINATION keeps the variable: unzip installs to a literal
            # /usr/local/libexec/... (cmake even warns about the absolute path). Left as
            # is, the entry lands in the prefix under a top-level usr/local, and its
            # symlinks point outside the tree.
            dest = dest.removeprefix(INSTALL_PREFIX + "/").rstrip("/")
            # The excludes are quoted strings too, so the file list is what comes BEFORE the
            # first REGEX. Splitting there keeps `/Makefile$` from being read as a file.
            head = blob.split(" REGEX ", 1)[0]
            srcs = STRING.findall(head)
            # install(FILES ... PERMISSIONS ... OWNER_EXECUTE) means the file lands
            # EXECUTABLE whatever mode it has in the source tree. The Directory Services
            # stubs are the case that matters: dscl, dseditgroup and sysadminctl are 644
            # in the repo and 755 once installed, and copying the source mode leaves three
            # shell scripts the guest cannot run.
            if "EXECUTE" in perms:
                EXEC_SOURCES.update(srcs)
            # cmake's `file(INSTALL ... TYPE PROGRAM ...)` is a FILE that lands executable --
            # it is how the shell wrappers ship (zipgrep, unxip, clt_install.py). Treating it
            # as its own kind left them unmapped, and because zdiff and zless arrive this way
            # too, the zcmp and zmore links pointing at them could not resolve either.
            if kind == "PROGRAM":
                EXEC_SOURCES.update(srcs)
            out.append((dest, kind, srcs, EXCLUDE.findall(blob)))
    # Loudly, because an empty walk is indistinguishable from a prefix with nothing in it,
    # and a manifest directory that has been garbage-collected or moved is the likely cause.
    if not seen:
        sys.exit(f"no cmake_install.cmake under {root} -- is the graph output still present?")
    return out


# `install(DIRECTORY DESTINATION x)` with no source: cmake writes it as an INSTALL with an
# empty file list, and it means "create this directory". libexec/darling/proc is one.
EMPTY_DIR = re.compile(r'file\(INSTALL DESTINATION "([^"]+)" TYPE DIRECTORY FILES ""\)')
# cmake/InstallSymlink.cmake's other branch: an install(CODE) block that runs
# `cmake -E create_symlink <target> <destination>`. Nothing in the file()-based manifest
# names these, so a parser that only reads file(INSTALL ...) misses all 74 of them.
CODE_SYMLINK = re.compile(r"create_symlink\s+(\S+)\s+(\S+)\)")


def read_layout(root: str, prefix: str):
    """([empty directories], {destination: link value}) over every manifest.

    Both forms are invisible to the file(INSTALL ...) parser, and both matter: without the
    empty directories the container has no /proc to mount procfs on, and without the links
    it has no etc, no var and no mtab.
    """
    dirs, links = [], {}
    for dirpath, _d, files in os.walk(root):
        if "cmake_install.cmake" not in files:
            continue
        text = open(os.path.join(dirpath, "cmake_install.cmake")).read()
        for dest in EMPTY_DIR.findall(text):
            d = dest.replace("${CMAKE_INSTALL_PREFIX}/", "").rstrip("/")
            if d and d not in dirs:
                dirs.append(d)
        for target, dest in CODE_SYMLINK.findall(text):
            # Each block has two branches, one of them under $ENV{DESTDIR}; they say the
            # same thing, so the plain one is enough.
            if "DESTDIR" in dest:
                continue
            rel = dest.removeprefix(prefix).lstrip("/")
            if rel:
                links[rel] = target
    return dirs, links


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
    """{kind: {output name: label}} for every executable and framework binary the port builds.

    The registries cover dylibs and archives only, but half the prefix is executables (dyld,
    notifyd, syslogd) and framework binaries (CoreFoundation), whose artifact name is the
    TARGET name. Scanning the BUCK files for those rules is how buck-coverage.py already
    identifies them.

    Split by KIND rather than merged into one namespace, because the two collide and the
    collision is silent. `login` is both an executable (system_cmds' login program, which
    installs to usr/bin/login) and a private FRAMEWORK whose dylib_name is also "login". In
    one dict, whichever os.walk() reached first won -- so porting the framework silently
    repointed usr/bin/login at a dylib, and the prefix shipped a shared library where a
    program belonged. Every runtime check failed and nothing said why. An install entry
    knows whether it wants an EXECUTABLE or a SHARED_LIBRARY, so target_for asks for the
    matching kind first.
    """
    index = {"exe": {}, "lib": {}}
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
            kind = "lib" if m.group(1) == "darwin_dylib" else "exe"
            into = index[kind]
            label = f"//{pkg}:{name.group(1)}"
            into.setdefault(name.group(1), label)
            # A dylib rule names its own output, which for a framework is not <name>.dylib.
            out = re.search(r'dylib_name = "([^"]+)"', block)
            if out:
                into.setdefault(out.group(1), label)
                into.setdefault(out.group(1).removesuffix(".dylib"), label)
            # And a binary rule does the same through exe_name, for the 92 targets whose
            # cmake name is not the file name -- clang_shim installs as clang, curlexe as
            # curl. Indexing only the rule name leaves every one of them UNMAPPED, with
            # the block built and sitting right there.
            exe = re.search(r'exe_name = "([^"]+)"', block)
            if exe:
                into.setdefault(exe.group(1), label)
    return index


# The tables target_for searches, built once per run.
#
# gen.final_registry() and gen.archive_registry() each WALK THE WHOLE REPO and re-read every
# BUCK file, and target_for called both for EVERY install entry -- so a run did that walk
# twice over for each of ~2,000 entries. Eight minutes, all of it recomputing an answer that
# cannot change while the script runs. Long enough that the script read as hung rather than
# slow, and long enough to discourage regenerating, which is how a generated file drifts
# from the reference it is supposed to be derived from.
_REGISTRIES: list = []


def registries(gen, binaries: dict) -> list:
    if not _REGISTRIES:
        _REGISTRIES.extend(
            [gen.final_registry(), gen.archive_registry(), binaries["lib"],
             binaries["exe"], GENERATED])
    return _REGISTRIES


def target_for(path: str, gen, binaries: dict, kind: str = "") -> str | None:
    """The buck2 target that builds this artifact, by output basename.

    The reference paths are build-dir absolute (/build/build/src/libm/libsystem_m.dylib);
    what identifies the artifact across both builds is its NAME, which is also the key the
    port's registries use.

    `kind` is the install entry's cmake TYPE. It matters when one name means two artifacts:
    `login` is both system_cmds' program and a private framework, and without the kind the
    executable entry usr/bin/login can resolve to the framework's dylib.
    """
    base = os.path.basename(path)
    tables = registries(gen, binaries)
    if kind == "EXECUTABLE":
        tables = [binaries["exe"]] + tables
    for table in tables:
        if base in table:
            return table[base]
    # cmake's POST_BUILD lipo renames the linker's output, and the port builds the linker's:
    # CoreFoundation is what gets installed, CoreFoundation_x86_64 is what exists. A
    # single-arch lipo -create is a rename here, so the thin file is the same artifact under
    # the name the install destination gives it.
    for table in (binaries["lib"], binaries["exe"]):
        if f"{base}_{ARCH}" in table:
            return table[f"{base}_{ARCH}"]
    return None


def source_rel(path: str) -> str | None:
    """A source path relative to the repo, or None if it is not from the source tree.

    NORMALISED here, once, so nothing downstream has to. cmake installs several files by
    a path with a `..` in the middle (securityd's plist is named
    security/keychain/securityd/../../OSX/sec/ipc/com.apple.secd.plist), and buck2 refuses
    such a source -- both as a label's target name and as an export_file's src.
    """
    # The manifests name the cmake source as a store path; everything after the store
    # entry's name is repo-relative.
    m = re.match(r"/nix/store/[a-z0-9]{32}-[^/]+/(.*)", path)
    if m:
        return os.path.normpath(m.group(1))
    if path.startswith(REPO + "/"):
        return os.path.normpath(path[len(REPO) + 1:])
    return None


def build_rel(path: str) -> str | None:
    """A build-tree path relative to the build directory, or None."""
    m = re.match(r"/build/build/(.*)", path)
    return m.group(1) if m else None


def flatten(rel: str) -> str:
    """The same flattening scripts/buck-exports.py and gen-buck-from-ninja.py use."""
    return re.sub(r"[^A-Za-z0-9_.+-]+", "_", rel)


def owning_package(rel: str) -> str | None:
    """The nearest ancestor package that can declare this file, or None."""
    d = os.path.dirname(rel)
    while d:
        if os.path.isfile(os.path.join(REPO, d, "BUCK")):
            return d
        d = os.path.dirname(d)
    return None


def file_label(rel: str):
    """(label, package needing an export_file or None) for a source file the prefix installs.

    A source attribute has to name a file of the package that DECLARES it, and buck/prefix
    owns none of these -- so every one of them travels as a LABEL backed by an export_file in
    its owner. For a pin that is the machinery scripts/buck-exports.py already runs; for the
    few files outside the pins (launchd's man pages, shellspawn's plist, etc/resolv.conf) the
    export goes in a generated block, since nothing else was minting labels into them.
    """
    pin, within = pin_of(rel)
    if pin is not None and os.path.isdir(os.path.join(REPO, "buck-src", pin)):
        if os.path.isfile(os.path.join(REPO, "buck-src", pin, "BUCK")):
            return (f"//buck-src/{pin}:{flatten(within)}", None)
        # A pin that has not been split out yet still lives in the buck-src mega-package, so
        # the label goes there -- and since buck-src cannot be walked to resolve a name (it
        # holds every materialized pin), the path is recorded as a HINT, which is the same
        # arrangement scripts/buck-split-pins.py uses.
        return (f"//buck-src:{flatten(f'{pin}/{within}')}", "buck-src")
    pkg = owning_package(rel)
    if pkg is None:
        return (None, None)
    return (f"//{pkg}:{flatten(os.path.relpath(rel, pkg))}", pkg)


def pin_of(rel: str):
    """(pin, path within the pin) for a src/external/<pin>/... source path.

    NORMALISED: cmake happily installs a path with a `..` in the middle of it (file's man
    page is named .../file/file/../gen/file.1), and buck2 rejects such a source outright.
    The path on disk is the same file either way.
    """
    m = re.match(r"src/external/([^/]+)/(.*)", os.path.normpath(rel))
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
    if not os.path.isdir(os.path.join(REPO, "buck-src", pin)):
        return None
    # cmake reaches out of a source directory with .. (libc installs its sibling's assets).
    within = os.path.normpath(within)
    if within.startswith(".."):
        return None
    # An UNSPLIT pin's directories go in the buck-src mega-package, with the pin in the
    # path. Writing a BUCK into the pin instead would make it a package, and every
    # already-generated block that names one of its files as a source -- vim's xxd is a
    # source of //buck-src -- stops being able to see it. Splitting a pin is a deliberate
    # act with its own tool (scripts/buck-split-pins.py); it must not happen as a side
    # effect of the pin having an install(DIRECTORY) entry.
    if os.path.isfile(os.path.join(REPO, "buck-src", pin, "BUCK")):
        pkg, within = f"buck-src/{pin}", within
    else:
        pkg, within = "buck-src", f"{pin}/{within}"
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


def write_block(pkg: str, blocks: list[str], kind: str = "prefix dirs",
                load: str = 'load("//buck/rules:install.bzl", "prefix_dir")') -> None:
    """Replace a generated block in a package's BUCK file, creating the file if absent."""
    path = os.path.join(REPO, pkg, "BUCK")
    begin = f"# BEGIN generated: {kind}"
    end = f"# END generated: {kind}"
    body = (f"{begin}\n"
            "# GENERATED from the reference build's install entries by\n"
            "# scripts/gen-install-from-manifests.py -- review before committing.\n\n"
            + "\n".join(blocks) + f"{end}\n")
    text = open(path).read() if os.path.isfile(path) else ""
    if begin in text:
        text = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n", body, text,
                      flags=re.S)
    else:
        text = text.rstrip("\n") + ("\n\n" if text.strip() else "") + body
    text = ensure_load(text, load)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)


def ensure_load(text: str, load: str) -> str:
    """Make sure `load` is satisfied, without duplicating an existing load of that module.

    A plain `if load not in text` compares the WHOLE line, so a BUCK file that already loads
    the module and hand-adds a symbol to it -- buck-src/BUCK loads prefix_gen_dir next to
    prefix_dir -- no longer matches, and a second load of the same module gets prepended.
    Buck2 rejects that outright (`prefix_dir` would be defined twice), and it would happen
    the next time anyone regenerated, not now, which is the worst time to find out.
    """
    module, symbols = re.match(r'load\("([^"]+)"(.*)\)', load).groups()
    have = re.search(r'^load\("' + re.escape(module) + r'"([^)]*)\)$', text, re.M)
    if not have:
        return load + "\n" + text
    missing = [s for s in re.findall(r'"([^"]+)"', symbols)
               if f'"{s}"' not in have.group(1)]
    if not missing:
        return text
    add = "".join(f', "{s}"' for s in missing)
    return text[:have.end() - 1] + add + text[have.end() - 1:]


def main(argv: list[str]) -> int:
    gen = load_gen()
    graph = graph_dir(argv)
    root = os.path.join(graph, "install-manifests")
    if not os.path.isdir(root):
        sys.exit(f"no install manifests at {root} -- build .#darling-graph first")

    binaries = binary_index()
    links = read_symlinks(graph)
    entries = read_entries(root)
    # The reference configures with CMAKE_INSTALL_PREFIX=/usr/local, which the install(CODE)
    # blocks bake into absolute paths while file(INSTALL ...) keeps the variable.
    empty_dirs, abs_links = read_layout(root, INSTALL_PREFIX)

    # Where each installed source ends up, so a symlink can be expressed against the
    # DESTINATION of the thing it points at rather than against a build path.
    dest_of = {}
    for dest, _kind, files, _ex in entries:
        for src in files:
            if src:
                base = os.path.basename(src)
                dest_of[src] = f"{dest}/{base}" if dest else base

    # Every destination anything installs to, so a relative link value can be resolved
    # against the destination directory it lands in.
    all_dests = set(dest_of.values())

    built, sources, symlinks, dirs, unmapped, skipped = {}, {}, {}, {}, [], []
    exec_files: dict[str, str] = {}
    blocks: dict[str, list[str]] = {}
    exports: dict[str, dict] = {}
    hints: dict[str, dict] = {}
    for dest, kind, files, excludes in entries:
        for src in files:
            if not src:
                continue
            full = dest_of[src]
            if full in OUT_OF_SCOPE:
                skipped.append(full)
                continue
            if kind in ("SHARED_LIBRARY", "EXECUTABLE", "STATIC_LIBRARY"):
                t = target_for(src, gen, binaries, kind)
                if t:
                    built[full] = t
                else:
                    unmapped.append((full, "no target builds it"))
            elif kind in ("FILE", "PROGRAM"):
                brel = build_rel(src)
                if brel is not None and brel in links:
                    # A symlink InstallSymlink left in the build tree. Its value is relative
                    # to the link itself, so resolve it there and ask where THAT lands.
                    target = os.path.normpath(os.path.join(os.path.dirname(src), links[brel]))
                    if target in dest_of:
                        symlinks[full] = dest_of[target]
                    else:
                        # The link value is relative to the LINK, and cmake installs a link
                        # and the thing it points at into the SAME destination -- but the
                        # target may be installed from the SOURCE tree while the link
                        # resolves inside the BUILD tree, so the build-dir path it resolves
                        # to appears in no manifest. Resolving the value against the
                        # DESTINATION instead is what a relative symlink actually means.
                        # This is openssl_certificates' 159 hash links (3c9a4d3b.0 ->
                        # ACCVRAIZ1.crt): configure-time execute_process(create_symlink)
                        # makes them, so no ninja edge builds them and nothing else can
                        # map them.
                        cand = os.path.normpath(f"{dest}/{links[brel]}") if dest else links[brel]
                        if cand in all_dests:
                            symlinks[full] = cand
                        else:
                            unmapped.append((full, f"links to {links[brel]}, which is not installed"))
                    continue
                rel = source_rel(src)
                if rel:
                    label, needs_export = file_label(rel)
                    if label is None:
                        unmapped.append((full, f"{rel} is in no package"))
                        continue
                    (exec_files if src in EXEC_SOURCES else sources)[full] = label
                    if needs_export == "buck-src":
                        hints.setdefault("buck-src", {})[label.split(":", 1)[1]] = \
                            rel.removeprefix("src/external/")
                    elif needs_export:
                        exports.setdefault(needs_export, {})[
                            label.split(":", 1)[1]] = os.path.relpath(rel, needs_export)
                    continue
                t = target_for(src, gen, binaries)
                if t:
                    built[full] = t
                else:
                    unmapped.append((full, "build output with no target"))
            elif kind == "DIRECTORY":
                # A trailing slash means the CONTENTS go to the destination; without one the
                # directory itself does, under its own name.
                where = dest if src.endswith("/") else f"{dest}/{os.path.basename(src)}"
                if where in EXTRA_DIRS:
                    dirs[where] = EXTRA_DIRS[where]
                    continue
                rel = source_rel(src)
                info = dir_target(rel, excludes) if rel else None
                if info is None:
                    unmapped.append((dest, f"install(DIRECTORY) of {src[-50:]}, not a pin path"))
                    continue
                label, pkg, block = info
                dirs[where] = label
                blocks.setdefault(pkg, [])
                if block not in blocks[pkg]:
                    blocks[pkg].append(block)
            else:
                unmapped.append((full, f"unhandled install type {kind}"))

    built.update(EXTRA)

    # A symlink whose destination did not SURVIVE. The check inside the loop asks whether
    # the target is an install entry at all, which it can be while still being dropped a
    # few lines later for having no target that builds it: lsbom links to installer, and
    # installer is not ported. Left in, the prefix rule fails on a link into nothing.
    present = set(built) | set(sources) | set(exec_files) | set(dirs) | set(empty_dirs)
    while True:
        dangling = {d: t for d, t in symlinks.items()
                    if t not in present and t not in symlinks}
        if not dangling:
            break
        for d, t in sorted(dangling.items()):
            unmapped.append((d, f"links to {t}, which is not in the prefix"))
            del symlinks[d]

    print(f"install entries: {len(entries)}")
    print(f"  built artifacts mapped to targets: {len(built)}")
    print(f"  source files:                      {len(sources)}")
    print(f"  source files (executable):         {len(exec_files)}")
    print(f"  symlinks:                          {len(symlinks)}")
    print(f"  directories:                       {len(dirs)}")
    print(f"  empty directories:                 {len(empty_dirs)}")
    print(f"  symlinks outside the tree:         {len(abs_links)}")
    print(f"  out of scope:                      {len(skipped)}")
    print(f"  UNMAPPED:                          {len(unmapped)}")
    for full, why in unmapped:
        print(f"      {full}  ({why})")

    if "--write" not in argv:
        return 0

    for pkg, bs in sorted(blocks.items()):
        write_block(pkg, bs)
        print(f"wrote {pkg}/BUCK: {len(bs)} prefix_dir target(s)")

    if hints:
        import json
        f = os.path.join(REPO, "buck", "generated", "export-hints.json")
        have = json.load(open(f)) if os.path.isfile(f) else {}
        for pkg, entries in hints.items():
            have.setdefault(pkg, {}).update(entries)
        open(f, "w").write(json.dumps(have, indent=2, sort_keys=True) + "\n")
        print(f"wrote buck/generated/export-hints.json: "
              f"{sum(len(v) for v in hints.values())} hint(s)")

    for pkg, files in sorted(exports.items()):
        block = "".join(
            f'export_file(\n    name = "{n}",\n    src = "{sp}",\n'
            f'    visibility = ["PUBLIC"],\n)\n\n'
            for n, sp in sorted(files.items()))
        write_block(pkg, [block], kind="prefix exports",
                    load='load("//buck/rules:files.bzl", "export_file")')
        print(f"wrote {pkg}/BUCK: {len(files)} export_file target(s)")

    lines = ['load("//buck/rules:install.bzl", "prefix_tree")', "",
             "# GENERATED from the reference build's cmake_install.cmake manifests by",
             "# scripts/gen-install-from-manifests.py -- review before committing.",
             "prefix_tree(",
             '    name = "darling_prefix",',
             "    entries = {"]
    for dest in sorted(built):
        lines.append(f'        "{dest}": "{built[dest]}",')
    lines += ["    },", "    trees = {"]
    for dest in sorted(dirs):
        lines.append(f'        "{dest}": "{dirs[dest]}",')
    lines += ["    },", "    files = {"]
    for dest in sorted(sources):
        lines.append(f'        "{dest}": "{sources[dest]}",')
    lines += ["    },", "    exec_files = {"]
    for dest in sorted(exec_files):
        lines.append(f'        "{dest}": "{exec_files[dest]}",')
    lines += ["    },", "    symlinks = {"]
    for dest in sorted(symlinks):
        lines.append(f'        "{dest}": "{symlinks[dest]}",')
    lines += ["    },", "    links = {"]
    for dest in sorted(abs_links):
        lines.append(f'        "{dest}": "{abs_links[dest]}",')
    lines += ["    },", "    dirs = ["]
    for d in sorted(empty_dirs):
        lines.append(f'        "{d}",')
    lines += ["    ],", '    visibility = ["PUBLIC"],', ")", ""]

    out = os.path.join(REPO, "buck", "prefix", "BUCK")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w").write("\n".join(lines))
    print(f"wrote buck/prefix/BUCK: {len(built) + len(dirs)} target(s), "
          f"{len(sources)} file(s), {len(symlinks)} symlink(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
