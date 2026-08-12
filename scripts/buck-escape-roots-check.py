#!/usr/bin/env python3
"""Every escape root must resolve to a real tree, because a missing one is dropped IN SILENCE.

WHY THIS EXISTS, and it is one specific day of lost work. #83 de-vendored
pins/ciderd/xnu-sys/xnu: the tree left the repo and became a pin. escapeSrc in
nix/lib/ciderBuck2Lower.nix read every escape root out of srcRaw behind a pathExists guard,
so the guard simply went false and the carry stopped happening. No warning, no eval error,
nothing in any diff. The security pin ships

    darling/submodules/xnu -> ../../../darlingserver/duct-tape/xnu

a link that keeps its upstream name on purpose, and with the carry gone it dangled, so
security_codesigning_obj died on "security/mac.h file not found" AN HOUR into the gate.

d51dfbc7 fixed that case by falling back to the PIN STORE. It did not close the class: a root
that is in neither the repo nor the manifest still evaluates to null and is still skipped
without a word. This check is what makes that loud, and it costs no build and no nix.

WHAT MAKES THE CLASS CHECKABLE STATICALLY. escapeRoots is

    ["darwin/Developer/Platforms"] ++ map (r: escapeNarrow.${r} or r) nonPinExternal

and nonPinExternal is a readDir of pins minus the pin names, so every element of it
exists by construction. The only entries that can point somewhere else are the literal SDK
root and the VALUES of escapeNarrow, which is exactly how xnu-sys/xnu got out of the repo
while its key stayed in. So the whole class is a handful of paths and needs no evaluation.

THE HONEST TEST FOR "IS IT IN THE REPO" IS jj file list, NOT os.path.exists. scripts/buck-src.nu
materializes pins at their manifest paths, so the de-vendored tree is sitting on disk at
pins/ciderd/xnu-sys/xnu right now with 2,077 files in it. os.path.exists says yes and
means nothing: srcRaw under a flake build is a store copy of TRACKED files, which is why the
guard went false in the first place. Ask jj, which reports 0 tracked files there.

WHAT THIS COVERS AND WHAT IT DOES NOT, because the scope is the part that gets over-trusted.
There are eight pathExists guards in the lowering and two in cider-src.nix, and they are not
equally dangerous:

  ciderBuck2Lower :353  escapeSrc               CHECKED here, both resolvability and fallback
  ciderBuck2Lower :1000 sdkGroup                covered TRANSITIVELY: sdkGroup is
                                                darwin/Developer/Platforms, the same literal
                                                root checked below, so it cannot go false
                                                while this passes
  ciderBuck2Lower :1004 per-label group filter  elements come from the same readDir, so they
                                                exist by construction. The one exception is
                                                deliberate: groupSplit.shared still names
                                                pins/ciderd/xnu-sys/xnu, which is a pin
                                                now, so this guard drops it and the PIN route
                                                supplies it instead. That dead table entry is a
                                                known deferred cleanup, not a defect.
  ciderBuck2Lower :973  pins readDir    NOT checked. If that directory vanished the
                                                root list would quietly shrink to the SDK and
                                                this would still pass. The counts printed below
                                                are the tell, and the scenario needs the whole
                                                pin tree to disappear, which is not quiet.
  ciderBuck2Lower :1111 :1130  buck-rust, buck-src   not checked, and they do not need it:
                                                those stage every pin, so losing them fails
                                                immediately and everywhere rather than silently.
  cider-src :184 :211   patch application       covered by buck-pin-patches-check.nu.

Exit 0 if every escape root resolves, 1 otherwise.
"""
import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def tracked_files():
    """The flake's view of the source: tracked files only. See the docstring on why this is
    not os.walk."""
    out = subprocess.run(["jj", "file", "list"], cwd=ROOT,
                         capture_output=True, text=True)
    if out.returncode != 0:
        print(f"FAIL: jj file list exited {out.returncode}: {out.stderr.strip()}")
        sys.exit(2)
    return out.stdout.split()


def escape_narrow(lowering):
    """Parse the escapeNarrow table. It is a flat attrset of string to string."""
    text = open(lowering, encoding="utf-8").read()
    m = re.search(r"^  escapeNarrow = \{(.*?)^  \};", text, re.S | re.M)
    if not m:
        print(f"FAIL: no escapeNarrow table found in {lowering}. If it was renamed or "
              f"reshaped, this check is reading the wrong thing and would PASS blindly.")
        sys.exit(2)
    return dict(re.findall(r'"([^"]+)"\s*=\s*"([^"]+)"\s*;', m.group(1)))


def literal_roots(lowering):
    """The hardcoded head of escapeRoots, currently just the SDK. Parsed rather than
    hardcoded here so that adding one to the lowering does not silently escape this check."""
    text = open(lowering, encoding="utf-8").read()
    m = re.search(r"^  escapeRoots =\s*\n?\s*\[(.*?)\]", text, re.S | re.M)
    if not m:
        print(f"FAIL: no escapeRoots binding found in {lowering}")
        sys.exit(2)
    return re.findall(r'"([^"]+)"', m.group(1))


def fallback_present(lowering):
    """ASSERT THE FIX IS STILL THERE, because the resolvability check above would NOT have
    caught the bug that prompted all this.

    Worth being exact about, since a check credited with catching something it cannot is
    worse than no check. At the moment the build broke, pins/ciderd/xnu-sys/xnu was
    already a manifest entry WITH a hash, so the loop above would have printed PIN STORE and
    exited 0. The defect was not an unresolvable root; it was that escapeSrc never consulted
    the pin, reading only srcRaw behind a pathExists guard.

    So the thing to assert is the shape of the code: escapeSrc must still have a route from a
    root to its pin store. Revert d51dfbc7, refactor it away, or rename pinPaths without
    following through here, and this fires."""
    text = open(lowering, encoding="utf-8").read()
    m = re.search(r"^  escapeSrc = (.*?)^  pinsTree =", text, re.S | re.M)
    if not m:
        print("FAIL: no escapeSrc binding found; this check is reading the wrong thing")
        sys.exit(2)
    body = m.group(1)
    if "pinPaths" in body:
        return True
    print("FAIL: escapeSrc no longer reads pinPaths, so an escape root that lives in a PIN "
          "rather than the repo contributes NOTHING and is skipped in silence. That is the "
          "exact regression d51dfbc7 fixed: the security pin link to duct-tape/xnu dangles "
          "and security_codesigning_obj dies on a missing security/mac.h an hour into the "
          "build. Restore the fallback from ciderSrc.pinPaths.")
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lowering", default=os.path.join(ROOT, "nix", "lib",
                                                       "ciderBuck2Lower.nix"),
                    help="lowering to read the tables from; point it at a mutated COPY to "
                         "negative-control this check without touching the working copy")
    a = ap.parse_args()

    manifest = json.load(open(os.path.join(ROOT, "nix", "submodules.json"),
                              encoding="utf-8"))
    # pinPaths is keyed by manifest path and only entries with a hash get a store, which is
    # what the `or null` fallback in escapeSrc actually looks up.
    pin_stores = {e["path"] for e in manifest if e.get("hash")}
    pin_names = {os.path.basename(e["path"]) for e in manifest
                 if e["path"].startswith("pins/")}

    # THE INDEX IS DERIVED, because it is a path DEPTH and #87 stage 2 changed it. This read
    # f.split("/")[2] with f.count("/") > 2, which is the position of <name> under the old
    # src/external/<name>. A textual sweep can rewrite the string src/external to pins and
    # CANNOT rewrite an array index, so the check went on slicing at component 2 and reported
    # the CHILDREN of the vendored trees (libtrace's include, libsbuf, xcodescripts, ciderd's
    # xnu-sys and scripts) as ten escape roots resolving to nothing. It was right to fail:
    # the population was wrong, not the tree.
    PIN_ROOT = "pins"
    depth = len(PIN_ROOT.split("/"))
    tracked = tracked_files()
    dirs = {f.split("/")[depth] for f in tracked
            if f.startswith(PIN_ROOT + "/") and f.count("/") > depth}
    non_pin_external = sorted(PIN_ROOT + "/" + d for d in dirs if d not in pin_names)

    narrow = escape_narrow(a.lowering)
    roots = literal_roots(a.lowering) + [narrow.get(r, r) for r in non_pin_external]

    print(f"escapeNarrow entries: {len(narrow)}; nonPinExternal: {len(non_pin_external)}; "
          f"escape roots: {len(roots)}")

    bad = []
    for r in roots:
        in_repo = any(f == r or f.startswith(r + "/") for f in tracked)
        in_pin = r in pin_stores
        if in_repo:
            how = "repo"
        elif in_pin:
            how = "PIN STORE"
        else:
            how = "NEITHER"
            bad.append(r)
        narrowed = " (narrowed)" if r in narrow.values() else ""
        print(f"  {r}{narrowed}: {how}")

    ok_fallback = fallback_present(a.lowering)

    if not bad and ok_fallback:
        print("PASS: every escape root resolves and the pin fallback is intact, so nothing "
              "is being dropped in silence")
        return 0
    if not bad:
        return 1

    print(f"\n{len(bad)} escape roots resolve to NOTHING and escapeSrc will skip them "
          f"without a word:")
    for r in bad:
        print(f"  {r}")
    print("\nFAIL: an escape destination that carries nothing leaves the pin symlinks that "
          "point into it DANGLING, and the build only says so an hour later as a missing "
          "header. Either track the tree, or give it a manifest entry with a hash.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
