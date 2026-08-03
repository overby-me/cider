#!/usr/bin/env python3
"""Does the recorded argv match what buck2 actually ran?

The Nix endpoint replays argvs recovered from aquery, which renders an action's command by
joining it with ", ". scripts/buck2-graph-dump.py splits that back apart, and that is sound
only while no argument contains the separator. It is an assumption, and it has been wrong:
perl's versions.h passed the C initializer ` "5.18", "5.28",` as one argument, it came back
as two, and the lowering died on a ValueError from the configure script -- while the host,
which never round-trips through the rendering, built it correctly all along.

The dumper can already verify itself with --check-against-what-ran, but only for actions
that RAN in the last invocation. Inside the Nix graph derivation that is about 4% of the
graph, the ones owning artifacts buck2 makes in-process, and perl's configure_file is not
among them. So the verification exists and could not have caught the one bug it is for.

Here it can. The host builds everything, so `buck2 log what-ran` carries the real argv, as a
LIST, for every action of the last invocation. Comparing that against what unjoin() recovers
tests the assumption across the whole graph instead of a corner of it, in minutes, on the
machine where the failure is cheap.

This imports unjoin and portable from the dumper rather than reimplementing them, so it
tests the real code path.

Two things make it work that are worth knowing before editing it:

  * it runs buck2 under its OWN isolation dir, because what-ran only lists actions that
    actually executed. Against the normal daemon everything is cached, nothing runs, and the
    check reports zero comparable actions while looking like it passed.
  * with no arguments it checks every configure_file target, found by uquery rather than
    listed here. That is the rule that passes free-form VALUES into an argv, so it is where
    a comma-space can appear; pass targets explicitly to widen it.

Usage:
  scripts/buck-argv-roundtrip-check.py [<target>...]   # default: every configure_file target
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_dumper():
    path = os.path.join(REPO, "scripts", "buck2-graph-dump.py")
    spec = importlib.util.spec_from_file_location("dump", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Its OWN daemon: what-ran lists only actions that EXECUTED, and against the normal
# isolation dir everything is already cached, so nothing runs and there is nothing to
# compare. A separate dir also keeps this from disturbing the working daemon's state.
ISO = ["--isolation-dir", "argvcheck"]


def buck2(*args: str) -> str:
    p = subprocess.run(["buck2", *ISO, *args], cwd=REPO, capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr[-2000:])
        sys.exit(f"buck2 {' '.join(args[:2])} failed")
    return p.stdout


def main(argv: list[str]) -> int:
    dump = load_dumper()
    targets = [a for a in argv if not a.startswith("--")]
    if not targets:
        # configure_file is the rule that puts free-form VALUES into an argv, so it is where
        # a comma-space can occur. Asked for rather than listed, so a new one is covered.
        targets = buck2("uquery", "kind('configure_file', //...)").split()
        print(f"== {len(targets)} configure_file target(s) ==", file=sys.stderr)
    if not targets:
        print("no targets to check", file=sys.stderr)
        return 0

    # The build has to happen in the SAME invocation whose what-ran we then read: the log is
    # per-invocation, so reading it after some other command reports that command instead.
    print(f"== building {' '.join(targets)} so what-ran has the real argvs ==", file=sys.stderr)
    subprocess.run(["buck2", *ISO, "build", *targets], cwd=REPO,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print("== reading what buck2 actually ran ==", file=sys.stderr)
    truth: dict = {}
    for line in buck2("log", "what-ran", "--format", "json").splitlines():
        line = line.strip()
        if not line:
            continue
        ev = json.loads(line)
        cmd = ev.get("reproducer", {}).get("details", {}).get("command")
        if cmd:
            truth[ev["identity"]] = cmd
    if not truth:
        print("what-ran is empty; nothing to verify", file=sys.stderr)
        return 0

    print("== recovering the same argvs the way the dump does ==", file=sys.stderr)
    aq = json.loads(buck2("aquery", "--output-all-attributes", "--json",
                          f"deps({' + '.join(targets)})"))
    recovered: dict = {}
    for node, at in aq.items():
        cmd = at.get("cmd")
        if not cmd:
            continue
        target = node.split("target: `", 1)[-1].split("`", 1)[0]
        identity = f"{target} ({at.get('category', '')} {at.get('identifier', '')})"
        recovered[identity.replace(" )", ")")] = dump.unjoin(cmd)

    common = sorted(set(truth) & set(recovered))
    bad = [i for i in common if truth[i] != recovered[i]]

    print(f"\nactions that ran:      {len(truth)}")
    print(f"actions aquery renders: {len(recovered)}")
    print(f"comparable:            {len(common)}")
    print(f"matching:              {len(common) - len(bad)}")

    if bad:
        print(f"\nFAIL: {len(bad)} action(s) do NOT round-trip through the ', ' join.")
        print("An argument contains the separator, so the Nix lowering would replay a")
        print("DIFFERENT command than buck2 ran. Fix the RULE so the argument cannot carry")
        print("a comma-space (see configure_file in buck/rules/codegen.bzl), rather than")
        print("teaching unjoin to guess where the boundaries were.\n")
        for ident in bad[:5]:
            print(f"  {ident}")
            print(f"    ran:       {truth[ident]}")
            print(f"    recovered: {recovered[ident]}")
        return 1

    if not common:
        print("\nnothing comparable: the build was fully cached and reported no actions")
        return 0
    print(f"\nok: all {len(common)} comparable actions round-trip exactly")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
