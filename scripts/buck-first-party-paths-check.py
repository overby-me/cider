#!/usr/bin/env python3
"""A first-party path quoted in a build file must resolve to something that exists.

WHY THIS EXISTS. #87 moved 52 directories out of src/ into darwin/ and linux/, and 44 literal
"src/xtrace/include" strings did not move with them, in buck-src/BUCK (23), buck-src/xnu/BUCK
(19), buck-src/syslog/BUCK (1) and buck-src/OpenDirectory/BUCK (1). Nothing complained. buck2
takes a missing include dir as an empty one, so the targets loaded, the graph built, the
lowering staged, and gate11 died an hour later with 118 errors that named base.h, memory.h and
string.h rather than the path that was wrong. 44 stale strings, 44 failing MIG stubs.

THE RULE IS DELIBERATELY NARROW, because a path in a build file lives in one of FOUR spaces and
they are spelled identically:

  1. repo-relative and CURRENT -- an include dir, a root =, a src. This is the only class that
     must resolve, and the only class this checks.
  2. pin-relative -- openssl/src/tools/c_hash. Recorded in buck/generated/exports_<pin>.bzl
     against the PIN root, so it does not resolve from the repo root and must not be expected
     to. buck-pin-paths-check.py owns this class and resolves it against the right root.
  3. FROZEN REFERENCE -- a buck-registry: KEY, a "# cmake target: X ->" line. Still spells the
     pre-move layout on purpose, because the reference build.ninja is frozen. Comments only,
     so quoting is what keeps them out of here.
  4. cmake BINARY-DIR -- everything under "# TODO these include dirs are GENERATED (codegen
     output):". Also comments only.

So: quoted literals only, which excludes 3 and 4; and the two exclusions below, which exclude
2 and the outputs.

THE EXCLUSIONS, both measured rather than assumed:

  buck/generated/exports_*.bzl   93 hits, every one pin-root-relative (libcxx's src/any.cpp and
                                 friends). Class 2, owned by buck-pin-paths-check.py.
  pins/**                a pin that has not been materialized is absent from disk, so
                                 its own BUCK file cannot resolve its own sources.
  out_base = "..."               a mig_gen OUTPUT base, not an input. buck-src/BUCK declares
                                 out_base = "src/firehose" for libdispatch's firehose
                                 protocols; nothing of that name exists or should.

A package-relative spelling is accepted too (resolved against the build file's own directory),
because both forms appear and both are correct.
"""
import os
import re
import sys

# --root exists for the negative control, which has to run against a tree where the path is
# genuinely absent. Pointing it at the real repo cannot demonstrate the failing direction
# without editing a BUCK file, and a control that edits projectSrc cannot run beside a build.
#
# The bounds test is not pedantry: a check that raises is a check that FAILS, and a suite
# reading only the exit code cannot tell a crash from a real finding. Say what is wrong and
# exit 2, which is the convention the other checks use for cannot-run as against found-a-problem.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if "--root" in sys.argv:
    _i = sys.argv.index("--root") + 1
    if _i >= len(sys.argv):
        print("FAIL: --root needs a directory argument", file=sys.stderr)
        sys.exit(2)
    ROOT = os.path.abspath(sys.argv[_i])
    if not os.path.isdir(ROOT):
        print(f"FAIL: --root {ROOT} is not a directory", file=sys.stderr)
        sys.exit(2)
LITERAL = re.compile(r'"((?:src|darwin|linux)/[\w./+-]+)"')
OUTPUT_ATTR = re.compile(r'\bout_base\s*=\s*"[^"]*"')
SKIP_DIRS = {".jj", ".git", "buck-out", "target", "outputs", "build", "__pycache__",
             "buck-rust"}


def in_scope(rel: str) -> bool:
    """False for the two path spaces this rule cannot judge. See the module docstring."""
    if rel.startswith("pins/"):
        return False
    return re.match(r"buck/generated/exports_.*\.bzl$", rel) is None


def main() -> int:
    bad, seen, files = [], 0, 0
    for dp, dn, fn in os.walk(ROOT):
        dn[:] = [d for d in dn if d not in SKIP_DIRS]
        for f in fn:
            if f != "BUCK" and not f.endswith((".bzl", ".bxl")):
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, ROOT)
            if os.path.islink(p) or not in_scope(rel):
                continue
            try:
                text = open(p, encoding="utf-8").read()
            except (OSError, UnicodeDecodeError):
                continue
            files += 1
            # Blank the output attributes rather than skipping the line, so a real path
            # sharing a line with an out_base is still checked.
            text = OUTPUT_ATTR.sub(lambda m: " " * len(m.group(0)), text)
            for m in LITERAL.finditer(text):
                q = m.group(1)
                seen += 1
                if os.path.lexists(os.path.join(ROOT, q)):
                    continue
                if os.path.lexists(os.path.join(os.path.dirname(p), q)):
                    continue
                line = text.count("\n", 0, m.start()) + 1
                bad.append(f"{rel}:{line}: {q}")

    print(f"first-party paths  {seen} quoted in {files} build file(s), {len(bad)} unresolved")
    if bad:
        for b in bad:
            print(f"    - {b}")
        print(f"\nFAIL: {len(bad)} quoted first-party path(s) resolve to nothing. buck2 reads a "
              f"missing include dir as an EMPTY one, so this does not fail the build where it "
              f"is written; it fails a compile somewhere else, much later.")
        return 1
    print("PASS: every quoted first-party path resolves")
    return 0


if __name__ == "__main__":
    sys.exit(main())
