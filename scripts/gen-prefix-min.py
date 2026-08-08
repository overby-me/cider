#!/usr/bin/env python3
"""Derive a MINIMAL prefix from the generated full one.

The goal this serves is narrow and worth stating: a Darling prefix that boots, runs bash,
and can run nix to build things. It is not parity. Everything the full prefix installs for
GUI, ObjC frameworks and scripting languages is dead weight for that, and it is most of the
build:

  darwin/frameworks          8,142 actions   29.5% of the graph
  darwin/private-frameworks  2,250 actions    8.2%
  perl python pyobjc ruby    1,197 actions    4.3%

buck/prefix/BUCK is GENERATED from the reference build's cmake manifests by
scripts/gen-install-from-manifests.py, so it is not edited by hand and neither is its
minimal sibling. This reads it, drops the entries whose target lives in an excluded package,
and writes buck/prefix-min/BUCK. Re-run it after regenerating the full prefix.

WHAT IT DOES NOT DO. It does not chase dependencies. Dropping an install ENTRY only stops a
file being placed in the prefix; buck2 still builds whatever the remaining targets depend
on. So the saving is real but bounded by what the survivors pull in, and the honest way to
find out is to build it and read the action count, which is why this prints one.

Usage:
  gen-prefix-min.py [--exclude PKG ...]        (writes buck/prefix-min/BUCK)
"""
from __future__ import annotations

import os
import re
import sys

# Packages whose installed output the goal does not need. Each is matched against the
# `//package:name` label on the right hand side of an entry.
EXCLUDE_PKGS = (
    "//darwin/frameworks",
    "//darwin/private-frameworks",
    "//buck-src/python",
    "//buck-src/python_modules",
    "//buck-src/pyobjc",
    "//buck-src/perl",
    "//buck-src/ruby",
)

# Individual labels to drop, for packages that are otherwise kept. Matched EXACTLY, because
# the package prefix cannot discriminate: jsc lives in //buck-src alongside most of the
# minimal prefix.
#
# //buck-src:jsc is the JavaScriptCore command-line shell, and it is the ONLY thing in this
# prefix that pulls JavaScriptCore. Measured with buck2 cquery:
#   somepath(//buck/prefix-min:darling_prefix_min, //buck-src:JavaScriptCore_obj)
#     -> darling_prefix_min -> jsc -> JavaScriptCore_dylib -> JavaScriptCore_obj
#   rdeps(deps(darling_prefix_min), //buck-src:JavaScriptCore_dylib, 1)
#     -> jsc, and nothing else
# One install entry, libexec/darling/usr/bin/jsc, therefore drags in 1,082 compiles. That is
# the single biggest item in this prefix and it is dead weight for the stated goal: boot, run
# bash, run nix. The FULL prefix keeps it, so parity is unaffected.
EXCLUDE_LABELS = (
    "//buck-src:jsc",

    # Userland tools nix can FETCH once it runs. The prefix exists to get nix up; anything
    # nix could install afterwards is being paid for twice, once here and once in the store.
    # None of these participates in booting the container or in running bash.
    #
    # Editors, pagers, shells other than bash, terminal multiplexers.
    "//buck-src:vim",
    "//buck-src:nano",
    "//buck-src:less",
    "//buck-src:tcsh",
    "//buck-src:zsh",
    "//buck-src:ash",
    "//buck-src/screen:screen",
    # Archivers and compressors.
    "//buck-src:gnutar",
    "//buck-src:zip",
    "//buck-src:unzip",
    "//buck-src:unzipsfx",
    "//buck-src:xz",
    "//buck-src:pax",
    # Network clients and daemons.
    "//buck-src:sshd",
    "//buck-src:rsync",
    "//buck-src:netstat",
    "//buck-src:cupsd",
    # Misc userland.
    "//buck-src:top",
    "//buck-src:mail",
    "//buck-src:patch",
    "//buck-src/file:file",
    "//buck-src:otool",
    "//buck-src:hdiutil",
    "//buck-src:installer",
    "//buck-src/groff:eqn",
)

# DELIBERATELY NOT EXCLUDED, so the reasoning is not lost:
#   grep         shell scripts in the prefix may call it, and it is cheap
#   curl, openssl  nix brings its own, but the SYSTEM ones may back the Security stack
#   iokitd       a guest daemon, not obviously inert
#   secd, securityd, trustd  the security daemons are 738/68/18 exclusive actions and the
#     biggest remaining prize, but nix does HTTPS and TLS trust on Darwin goes through
#     Security. That cannot be settled statically, and nix-in-guest cannot currently be run
#     to settle it empirically, so they stay until it can.

# Source-file entries (the `files` and `trees` sections name repo paths, not labels).
EXCLUDE_SRC = (
    "darwin/frameworks/",
    "darwin/private-frameworks/",
    "buck-src/python",
    "buck-src/pyobjc/",
    "buck-src/perl/",
    "buck-src/ruby/",
)

# Destination prefixes to drop outright, for files that arrive from a package that is kept
# but land somewhere only the excluded world reads.
EXCLUDE_DEST = (
    "libexec/darling/System/Library/Frameworks/",
    "libexec/darling/System/Library/PrivateFrameworks/",
    "libexec/darling/usr/lib/python",
    "libexec/darling/System/Library/Perl/",
)

_LABEL = re.compile(r'"\s*:\s*"(//[^"]+)"')
_DEST = re.compile(r'^\s*"([^"]+)"\s*:')


def excluded(line: str) -> bool:
    m = _LABEL.search(line)
    if m and m.group(1).startswith(EXCLUDE_PKGS):
        return True
    if m and m.group(1) in EXCLUDE_LABELS:
        return True
    d = _DEST.match(line)
    if d and d.group(1).startswith(EXCLUDE_DEST):
        return True
    # `files` and `trees` map a destination to a repo-relative SOURCE, not a label.
    if m is None:
        v = re.search(r':\s*"([^"]+)"', line)
        if v and v.group(1).startswith(EXCLUDE_SRC):
            return True
    return False


def main(argv: list[str]) -> int:
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    src = os.path.join(root, "buck", "prefix", "BUCK")
    if not os.path.exists(src):
        sys.exit(f"no generated prefix at {src}")

    out_dir = os.path.join(root, "buck", "prefix-min")
    os.makedirs(out_dir, exist_ok=True)

    kept, dropped = [], 0
    with open(src) as fh:
        for line in fh:
            if line.lstrip().startswith('"') and excluded(line):
                dropped += 1
                continue
            kept.append(line)

    body = "".join(kept)
    body = body.replace('name = "darling_prefix"', 'name = "darling_prefix_min"', 1)
    header = (
        "# GENERATED by scripts/gen-prefix-min.py from buck/prefix/BUCK -- do not edit.\n"
        "#\n"
        "# The full prefix minus the GUI frameworks, the private frameworks and the\n"
        "# scripting languages. It exists for one purpose: a prefix that boots, runs bash\n"
        "# and can run nix. Parity lives in //buck/prefix:darling_prefix, which is unchanged.\n"
        f"# Entries dropped from the full prefix: {dropped}.\n"
    )
    body = body.replace(
        "# GENERATED from the reference build's cmake_install.cmake manifests by\n"
        "# scripts/gen-install-from-manifests.py -- review before committing.\n",
        header, 1)

    dst = os.path.join(out_dir, "BUCK")
    with open(dst, "w") as fh:
        fh.write(body)

    total = sum(1 for l in open(src) if l.lstrip().startswith('"'))
    print(f"prefix-min: dropped {dropped} of {total} entries "
          f"({100 * dropped // max(total, 1)} percent), wrote {dst}")
    if dropped == 0:
        raise SystemExit("prefix-min: nothing was dropped, the exclusion list is wrong")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
