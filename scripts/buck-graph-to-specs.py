#!/usr/bin/env python3
"""Group a dumped buck2 action graph into per-GROUP specs, the way the lowering does.

THE ADAPTER HALF OF #66 (nix/lib/dyn-actions.nix is the reusable half). The lowering
currently does this grouping in the EVALUATOR, and doing it here is the point: cider's
endpoint eval is 14.36 s, of which 0.21 s is reading a 139 MB graph.json, about 2.1 s is
parsing it, and about 12 s is computing derivations from the result. This moves the
computing to a script that already runs inside the graph derivation.

THE GROUPING IS COPIED FROM ciderBuck2Lower.nix AND MUST STAY IDENTICAL. If the two ever
disagree, the adapter emits specs for groups the lowering does not have, or misses ones it
does, and the endpoint builds a different set of derivations than it did before. So the rule
is stated once here and checked against reality by --verify:

    target  = identity up to the first " ("        e.g. root//buck-src:apr_obj
    group   = coarsePinOf[target] -> root//buck-src:pin-<pin>, when coarse pins are on
              otherwise the target itself

ORDER WITHIN A GROUP IS NOT COSMETIC. g.actions is globally topological, which the lowering
verified by walking it and finding 0 inputs read before they were written across 27,591
actions, against 112,213 on the reversed list. Nix's lib.groupBy keeps element order, so the
groups stay topological; this iterates the action list in order for the same reason. Sorting
the actions here would silently break every target whose second action reads the first
output.

WHY NOT RUST, since the question comes up: measured 2026-08-11, this parses 139 MB and writes
every spec in 2.17 s, of which 1.18 s is json.load. It runs INSIDE the graph derivation, which
takes about 18 minutes, so the whole script is 0.2 percent of a build that already happens.
Rust would save under two seconds of an eighteen minute build. Python's json is C underneath,
which is why 139 MB parses in about a second.

Usage:
  scripts/buck-graph-to-specs.py <graph.json> <outdir>          # write the specs
  scripts/buck-graph-to-specs.py <graph.json> --verify <log>    # check the grouping against
                                                                # derivations a real gate built
"""
from __future__ import annotations

import json
import os
import re
import sys


def target_of(identity: str) -> str:
    """The buck2 label, identity up to the first " (". Same as targetOf in the lowering."""
    return identity.split(" (")[0]


def group_of(label: str, coarse_pin_of: dict, coarse_pins: bool) -> str:
    """Same as groupOfLabel. A coarse pin folds its members into one synthetic label.

    WHICH pins may be folded is decided in the DUMP, not here: contracting a DAG can create
    cycles and this graph has them, 43 of 157 pins in one strongly connected component over
    the system cone. coarse_pin_map in buck2-graph-dump.py runs Tarjan and offers only the
    pins that are in no cycle. Re-deriving that here would be re-deriving the bug.
    """
    if not coarse_pins:
        return label
    pin = coarse_pin_of.get(label)
    return label if pin is None else "root//buck-src:pin-" + pin


def safe_name(group: str) -> str:
    """A store-safe file name for a group label, injectively.

    INJECTIVE MATTERS: the name keys the consumer lookup, so two groups colliding here would
    silently merge two derivations. Checked rather than assumed, in group_specs below.
    """
    return re.sub(r"[^A-Za-z0-9_.-]", "_", group)


def group_specs(graph: dict, coarse_pins: bool = True) -> dict:
    """{group_label: [action, ...]} in buck2 order, plus the safe-name mapping."""
    coarse_pin_of = graph.get("coarsePinOf", {})
    groups: dict = {}
    for a in graph["actions"]:
        g = group_of(target_of(a["identity"]), coarse_pin_of, coarse_pins)
        groups.setdefault(g, []).append(a)

    seen: dict = {}
    for g in groups:
        s = safe_name(g)
        if s in seen:
            raise SystemExit(
                f"FAIL: safe_name is not injective: {g!r} and {seen[s]!r} both give {s!r}. "
                f"Two groups would silently share one derivation.")
        seen[s] = g
    return groups


_SAFE = re.compile(r"^[A-Za-z0-9,._+:@%/-]+$")

# @CLANG@ and friends. The graph is deliberately PORTABLE: buck2-graph-dump.py names the
# store paths an argv needs instead of baking them in, so one graph can serve any machine,
# and filling them back in is the consumer's job. The lowering does that with a
# replaceStrings over every argv at EVAL time, which is per-argv work over 208,515 entries
# and part of what #66 is removing.
#
# So the emitted script keeps the placeholder, as a SHELL VARIABLE the builder expands.
# Portability is preserved exactly -- the script still names no store path -- and the
# substitution moves from the evaluator to the shell, where it costs nothing.
_PLACEHOLDER = re.compile(r"@([A-Z_0-9]+)@")


def ph_var(name: str) -> str:
    return "CIDER_PH_" + name


def esc_with_placeholders(s: str) -> str:
    """Escape one argv element, turning @X@ into an expandable ${CIDER_PH_X}.

    Double quotes, not single, because a single-quoted string does not expand. Everything
    that is special inside double quotes is escaped, so only the placeholder expands and an
    argv containing a literal dollar or backtick cannot become a command substitution.
    """
    out = []
    last = 0
    for m in _PLACEHOLDER.finditer(s):
        lit = s[last:m.start()]
        out.append(lit.replace("\\", "\\\\").replace('"', '\\"')
                   .replace("$", "\\$").replace("`", "\\`"))
        out.append("${" + ph_var(m.group(1)) + "}")
        last = m.end()
    lit = s[last:]
    out.append(lit.replace("\\", "\\\\").replace('"', '\\"')
               .replace("$", "\\$").replace("`", "\\`"))
    return '"' + "".join(out) + '"'


def esc(s: str) -> str:
    """Shell-escape one argv element, byte for byte as nixpkgs lib.escapeShellArg does.

    IT DOES NOT ALWAYS QUOTE, which is the whole reason this is a function and not a format
    string. Modern nixpkgs leaves a string bare when it matches [[:alnum:],._+:@%/-]+ and
    only single-quotes otherwise. Assuming it always quoted produced a script that differed
    from the lowering's on EVERY line while being perfectly valid shell, which is the kind of
    difference that survives testing and then shows up as every derivation moving.
    """
    if _PLACEHOLDER.search(s):
        return esc_with_placeholders(s)
    if _SAFE.match(s):
        return s
    return "'" + s.replace("'", r"'\''") + "'"


def action_script(actions: list) -> str:
    """The per-group action sequence, byte-identical to what the lowering renders.

    THE _drain BRANCH IS THE WHOLE SUBTLETY. Independent actions run concurrently through
    _spawn; one that reads an output THIS group produces must wait for everything in flight,
    hence _drain before it. The lowering computes that as `any input is in the group's own
    output set`, which is sound only because the action list is topological, so an input
    produced by this group necessarily came from an earlier action.
    """
    own = set()
    for a in actions:
        own.update(a["outputs"])

    out = []
    for a in actions:
        for o in a["outputs"]:
            out.append(f'mkdir -p "$(dirname {esc(o)})"\n')
        out.append(f'echo "  {a["identity"]}"\n')
        cmd = " ".join(esc(x) for x in a["argv"])
        if any(i in own for i in a["inputs"]):
            out.append(f"_drain\n{cmd}\n")
        else:
            out.append(f"_spawn {cmd}\n")
    return "".join(out)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.exit(__doc__)
    graph_path = argv[0]
    graph = json.load(open(graph_path))

    groups = group_specs(graph)
    total_actions = sum(len(v) for v in groups.values())
    if total_actions != len(graph["actions"]):
        sys.exit(f"FAIL: {total_actions} actions across groups but {len(graph['actions'])} "
                 f"in the graph; the grouping dropped some")

    if argv[1] == "--verify":
        # THE CHECK IS AGAINST A REAL GATE LOG, not against this script's own idea of the
        # answer. Every buck2-<name> derivation a gate actually built must correspond to a
        # group here. The converse does not hold and is not claimed: CA early cutoff means a
        # green gate builds only a subset.
        log = argv[2]
        built = set()
        for line in open(log, errors="ignore"):
            m = re.search(r"building '/nix/store/[a-z0-9]{32}-buck2-([A-Za-z0-9_.-]+)\.drv'", line)
            if m:
                built.add(m.group(1))
        names = {safe_name(g) for g in groups}
        # The lowering names a derivation after the group with root//... stripped; compare on
        # the tail so the two namings can be related without guessing the whole scheme.
        tails = {n.split("_")[-1] for n in names}
        # NOT TARGETS, so their absence from the grouping is correct rather than a miss. Named
        # explicitly instead of pattern-matched: a known-benign exception that swallows an
        # unknown one turns this check into a check that cannot fail. Measured against
        # gate15, `stage-project-grouped` was the only one.
        NOT_A_TARGET = {"stage-project-grouped", "stage-tree", "skeleton"}
        unmatched = sorted(b for b in built
                           if b not in names and b.split("_")[-1] not in tails
                           and not b.endswith("-out")
                           and b not in NOT_A_TARGET)
        print(f"groups: {len(groups)}   actions: {total_actions}")
        print(f"derivations the gate built: {len(built)}")
        print(f"built names with no group: {len(unmatched)}")
        for u in unmatched[:15]:
            print(f"    {u}")
        return 1 if unmatched else 0

    outdir = argv[1]
    os.makedirs(outdir, exist_ok=True)
    names = []
    for g, acts in groups.items():
        n = safe_name(g)
        names.append(n)
        json.dump({"group": g, "actions": acts}, open(os.path.join(outdir, n + ".json"), "w"))
    open(os.path.join(outdir, "names"), "w").write("\n".join(names) + "\n")
    print(f"wrote {len(names)} group spec(s), {total_actions} action(s), to {outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
