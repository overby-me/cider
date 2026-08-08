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
    # zsh's 35 loadable modules. Removing the zsh BINARY by label left these installed at
    # usr/lib/zsh/5.7.1/zsh/*.so, orphaned: nothing can load them. This is also the omission
    # PLAN.md recorded from the start, that the prose claimed the scripting languages were
    # excluded while the list omitted //buck-src/zsh. Closed at the package level.
    "//buck-src/zsh",
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
    "//buck-src:cal",
    "//buck-src:ncal",
    "//buck-src:latency",
    "//buck-src:sc_usage",

    # The GUI cone, reached through three small tools. pbcopy, pbpaste and open are the ONLY
    # prefix entries that reach AppKit or CoreImage (checked by walking every entry's cone),
    # and between them they pull 752 actions of framework into a prefix defined as having no
    # GUI frameworks. Same shape as jsc: a small tool carrying a large cone.
    "//src/pboard:pbcopy",
    "//src/pboard:pbpaste",
    "//src/tools:open",

    # The SUPERSEDED libcrypto/libssl/libtls versions. Darling ships five libcrypto builds for
    # binary compatibility with guest software linking a specific versioned dylib. Only
    # crypto44 has real consumers -- curl_dylib, curlexe, openssl, scp, sftp -- and the other
    # four are self-contained islands, each linked solely by its own ssl/tls sibling:
    #   crypto098 505 + ssl098 44                = 549
    #   crypto35  543 + ssl35  43 + tls6      6  = 592
    #   crypto41  544 + ssl43  38 + tls15    10  = 592
    #   crypto42  539 + ssl44  38 + tls16    10  = 587
    # 2,320 actions for versions nothing in this prefix links. nix carries its own openssl in
    # its store closure, so it needs none of them; the system curl needs crypto44/ssl46/tls18,
    # which stay.
    "//buck-src:crypto098_dylib",
    "//buck-src:ssl098_dylib",
    "//buck-src:crypto35_dylib",
    "//buck-src:ssl35_dylib",
    "//buck-src:tls6_dylib",
    "//buck-src:crypto41_dylib",
    "//buck-src:ssl43_dylib",
    "//buck-src:tls15_dylib",
    "//buck-src:crypto42_dylib",
    "//buck-src:ssl44_dylib",
    "//buck-src:tls16_dylib",

    # The security DAEMONS and the security CLI. Together about 1,390 actions: secd alone is
    # 738 exclusive and additionally pulls CloudKit 257 and AppleAccount 235, and with
    # securitytool it pulls SecurityFoundation 161.
    #
    # The question is not what nix NEEDS, it is what nix needs TO START; once installed it
    # pulls anything else from nixpkgs. Read tests/nix-in-darling.nix for what the guest
    # actually does: the HOST downloads and extracts the installer tarball and copies it in,
    # then the guest runs `bash -x install --no-daemon` followed by nix --version,
    # nix-instantiate --eval, nix eval, nix-store --verify and a trivial derivation. NONE of
    # that does network I/O, so there is no TLS, no trust evaluation and no keychain on the
    # bootstrap path.
    #
    # This cannot regress anything currently verified, and that is checkable rather than
    # hopeful: nix-in-darling runs against the cmake-built FULL `darling`, not this prefix, so
    # no existing test exercises nix here. And Security.framework itself is ALREADY absent from
    # this prefix (0 entries reach Security_dylib; it lives under System/Library/Frameworks,
    # which EXCLUDE_DEST drops), so if nix needed it the minimal prefix was already unable to
    # run nix, independently of these four.
    #
    # If nix-in-guest is ever pointed at this prefix and turns out to need Security, the fix is
    # the Security DYLIB, which is a different and much smaller thing than these daemons.
    "//buck-src:secd",
    "//buck-src:securityd_exe",
    "//buck-src:trustd",
    "//buck-src:securitytool_macos",

    # The OpenSSH suite, and with it openbsd_compat (82 actions, reached by nothing else).
    "//buck-src:ssh",
    "//buck-src:scp",
    "//buck-src:sftp",
    "//buck-src:sftp-server",
    "//buck-src:ssh-add",
    "//buck-src:ssh-agent",
    "//buck-src:ssh-keygen",
    "//buck-src:ssh-keyscan",
    "//buck-src:ssh-keysign",
    "//buck-src:ssh-pkcs11-helper",
    "//buck-src:sshd-keygen-wrapper",

    # curl, openssl and the LAST libcrypto. Keeping crypto44 was justified earlier by "curl
    # needs it", which was the wrong question: the bootstrap does no network I/O, so CURL is
    # not needed either, and the whole chain goes. crypto44_obj alone is 543 actions, the
    # single largest item left in the prefix, plus curl_obj 135.
    "//buck-src:curlexe",
    "//buck-src:curl_dylib",
    "//buck-src:openssl",
    "//buck-src:crypto44_dylib",
    "//buck-src:ssl46_dylib",
    "//buck-src:tls18_dylib",

    # The Berkeley DB command line tools: 225 actions of berkeley_db_obj reached by these
    # twelve and nothing else.
    "//buck-src:db_archive",
    "//buck-src:db_checkpoint",
    "//buck-src:db_codegen",
    "//buck-src:db_deadlock",
    "//buck-src:db_dump",
    "//buck-src:db_hotbackup",
    "//buck-src:db_load",
    "//buck-src:db_printlog",
    "//buck-src:db_recover",
    "//buck-src:db_stat",
    "//buck-src:db_upgrade",
    "//buck-src:db_verify",

    # The BIND DNS diagnostic tools: bind9_dns_obj 84 and bind9_isc_obj 82 are reached by
    # these six and nothing else. Resolution itself is libnetwork/libc, not these.
    "//buck-src:dig",
    "//buck-src:host",
    "//buck-src:nslookup",
    "//buck-src:nsupdate",
    "//buck-src:delv",
    "//buck-src:ddns-confgen",

    # libarchive's tools (archive_obj 115) and the Apache Portable Runtime (apr_obj 82).
    # I flagged these as a residual risk on the grounds that the nix installer might shell out
    # to tar. It does not, and the evidence was already in tests/nix-in-darling.nix when I
    # wrote that: EVERY extraction step is on the HOST. The host curls the tarball, the host
    # runs `tar -xf`, the host `cp -a`s the extracted directory into the prefix, and the guest
    # then runs `install --no-daemon` over plain files. That installer copies $self/store into
    # /nix/store with `cp -RPp` and loads the DB from .reginfo; there is no archive left to
    # unpack guest-side. No tar is needed in the guest.
    "//buck-src:bsdtar",
    "//buck-src:cpio",
    # and libarchive itself, which after those two is installed for its own sake
    # with nothing left consuming it.
    "//buck-src:archive_dylib",
    "//buck-src:apr_dylib",
    "//buck-src:aprutil_dylib",

    # launchd plists whose Program no longer exists, orphaned by the removals above. launchd
    # would try to spawn each of these at boot and fail. THE SMOKE TEST CANNOT CATCH THIS: it
    # runs with DARLING_NO_LAUNCHD=1, so the job graph is never exercised. Found by reading
    # each plist Program/ProgramArguments and checking it against the install destinations.
    "//buck-src:security_OSX_sec_ipc_com.apple.secd.plist",
    "//buck-src:security_securityd_etc_com.apple.securityd.plist",
    "//buck-src:security_trust_trustd_macOS_com.apple.trustd.plist",
    "//buck-src:security_trust_trustd_macOS_com.apple.trustd.agent.plist",
    "//buck-src:openssh_com.openssh.ssh-agent.plist",
    "//buck-src:openssh_com.openssh.sshd.plist",
    "//buck-src:cups_cups_scheduler_org.cups.cupsd.plist",
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

    # SECOND PASS: drop symlinks whose target is no longer installed.
    #
    # Removing a binary silently orphans its aliases, because a multi-call binary is shipped
    # once and symlinked under its other names. Dropping `installer` left lsbom, pkgutil and
    # uninstaller pointing at nothing; dropping `less` left `more`; dropping `unzip` left
    # `zipinfo`. Five dangling links, and the prefix would have installed every one of them.
    #
    # That is #41 all over again (eight krb5 .dylib symlinks that dangled), so it is fixed
    # here rather than by naming the five: any future exclusion gets the same treatment for
    # free, which is the whole reason the exclusion lists are worth having.
    body = "".join(kept)
    installed = set()
    for sec in ("entries", "files", "trees"):
        m = re.search(r"^\s+%s = \{(.*?)^\s+\}," % sec, body, re.M | re.S)
        if m:
            installed |= set(re.findall(r'^\s*"([^"]+)"\s*:', m.group(1), re.M))

    sec = re.search(r"^\s+symlinks = \{(.*?)^\s+\},", body, re.M | re.S)
    if sec:
        orphans = []
        for line in sec.group(1).splitlines(True):
            m = re.match(r'^\s*"([^"]+)"\s*:\s*"([^"]+)"', line)
            if m and m.group(2) not in installed:
                orphans.append(line)
        if orphans:
            for line in orphans:
                body = body.replace(line, "", 1)
            dropped += len(orphans)
            names = ", ".join(
                re.match(r'^\s*"([^"]+)"', o).group(1).rsplit("/", 1)[-1] for o in orphans)
            print(f"prefix-min: dropped {len(orphans)} symlink(s) orphaned by an "
                  f"excluded target: {names}", file=sys.stderr)
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
