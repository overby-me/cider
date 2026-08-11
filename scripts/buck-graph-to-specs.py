#!/usr/bin/env python3
"""Group a dumped buck2 action graph into per-GROUP specs, the way the lowering does.

THE ADAPTER HALF OF #66 (nix/lib/dyn-actions.nix is the reusable half). The lowering did this
grouping and rendering in the EVALUATOR; this does it once, inside the graph derivation.

WHAT IT IS ACTUALLY WORTH, corrected 2026-08-11 after measuring, because the earlier claim
here was too generous and the wrong thing was credited. The endpoint evaluates in 15.1 s.
Removing the script rendering from the evaluator entirely, measured by rendering nothing at
all, leaves 12.95 s. So the rendering is 2.2 s, NOT the ~12 s this file used to claim: that
12 s is the cost of computing 1,474 DERIVATIONS, of which the action script is a small part.
Reading the result back costs about 1.5 s, so the net is 15.1 -> 14.5 s.

That is a small win, and it is kept for what it enables rather than for the 0.6 s: the
remaining ~12.95 s is per-derivation computation, which is what emitting the derivations
themselves would remove.

WHAT IS NOT DONE, stated plainly because the record claimed otherwise. The <name>.json this
writes is NOT in the format nix/lib/dyn-actions.nix accepts in specDir mode. Tested
2026-08-11: `nix derivation add` rejects one with "Expected JSON object to contain key
'name'". specDir wants a DERIVATION; this writes the action data a derivation would be built
from. The conversion needs the consumer's store paths -- the builder, the staged tree, the
toolchain -- which are not knowable here, so it belongs in a derivation that has them.

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


# buck2 renders an action identity as `LABEL (CONFIGURATION) (ACTION)`. Anchored, because
# this is the ONE place the adapter reimplements a buck2 concept rather than moving data
# buck2 already extracted, and a wrong answer here is silent: a mis-split label produces a
# group that looks perfectly plausible and quietly merges or splits derivations.
#
# The lowering says `lib.head (lib.splitString " (" identity)`, which takes the prefix before
# the FIRST " (" and cannot fail. That is fine while every identity has this shape, and all
# 8,704 in the current graph do, measured. It stops being fine the moment one does not.
# Parsing buck2's Display output at all is the weakness; #92 is the proper fix, which is to
# take the label from buck2's own types instead of re-deriving it from a rendered string.
_IDENTITY = re.compile(r"^(?P<label>[^ ]+) \((?P<cfg>[^)]*)\) \((?P<action>.+)\)$")


def target_of(identity: str) -> str:
    """The buck2 label. Same answer as targetOf in the lowering, but it refuses to guess."""
    m = _IDENTITY.match(identity)
    if not m:
        raise SystemExit(
            f"FAIL: cannot parse a buck2 action identity: {identity!r}\n"
            f"Expected `LABEL (CONFIGURATION) (ACTION)`. Splitting on the first ' (' would "
            f"return a label that LOOKS right and silently group this action wrongly, so "
            f"this stops instead. See #92: the real fix is to read the label from buck2's "
            f"own types rather than from its rendered output.")
    return m.group("label")


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


def group_deps(graph: dict, groups: dict) -> dict:
    """{group: [other groups it reads outputs of]}, in the shape dyn-actions.nix reads back.

    THIS IS THE EDGE SET THE BRIDGE CANNOT INFER. In specDir mode the spec files are copied
    without being parsed, so a dependency that is not in deps.json does not exist as far as the
    emitted derivation is concerned -- and the failure is silent, because every action still
    builds and simply sees an empty dependency.

    TWO SOURCES, and the second is not optional. This matches needsOf in the lowering.

    1. ARTIFACTS. An action's `inputs` are paths, and whichever group WROTE a path is a
       dependency. A path nobody writes is a SOURCE, not a missing edge: most inputs are
       project files.

    2. DECLARED TARGETS, from `input_targets`. AN ACTION THAT READS ITS INPUTS FROM A FILE
       NAMES NONE OF THEM IN ITS ARGV, so the artifact rule cannot see them. This was left out
       of the first version of this function and the omission was large: 715 groups short of
       1,292 edges, with the prefix alone missing 527 of them, because it passes one manifest
       argument standing for thousands of inputs. The lowering's own comment records that this
       is how the first coarse build died, an hour in, with a cp that could not stat a .o.

    THROUGH THE SAME GROUPING, which is also not optional: input_targets arrives as raw target
    labels while everything else here is keyed by GROUP, so under coarse pins an unmapped label
    matches nothing and the edge disappears in silence.

    A DECLARED TARGET WITH NO ACTIONS IS DROPPED, deliberately. A header root or a staged
    include tree is a real declared input with no derivation to depend on; what it owns travels
    as staged data instead.
    """
    producer = {}
    for g, actions in groups.items():
        for a in actions:
            for o in a["outputs"]:
                producer[o] = g

    coarse_pin_of = graph.get("coarsePinOf", {})
    deps = {}
    for g, actions in groups.items():
        seen = set()
        for a in actions:
            for i in a["inputs"]:
                p = producer.get(i)
                if p is not None and p != g:
                    seen.add(p)
            for t in a.get("input_targets", []):
                grp = group_of(t, coarse_pin_of, True)
                if grp != g and grp in groups:
                    seen.add(grp)
        deps[g] = sorted(seen)
    return deps


def acyclic(deps: dict) -> list:
    """The first cycle found, or []. A cycle is fatal rather than suboptimal.

    nix/lib/dyn-actions.nix resolves a dependency to the OUTPUT of another action, so a cycle
    is an infinite recursion in the evaluator that names neither party. The dump already runs
    Tarjan when choosing which pins may be merged, for exactly this reason (contracting a DAG
    can create cycles, and this graph has them at pin level), so this is a check that the
    contraction actually held rather than a new worry.
    """
    WHITE, GREY, BLACK = 0, 1, 2
    colour = {g: WHITE for g in deps}
    stack = []

    def walk(n):
        colour[n] = GREY
        stack.append(n)
        for m in deps.get(n, []):
            if colour.get(m, WHITE) == GREY:
                return stack[stack.index(m):] + [m]
            if colour.get(m, WHITE) == WHITE:
                got = walk(m)
                if got:
                    return got
        colour[n] = BLACK
        stack.pop()
        return []

    for g in deps:
        if colour[g] == WHITE:
            got = walk(g)
            if got:
                return got
    return []


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

# WHICH placeholders the consumer actually exports. This list has to be checked rather than
# trusted, and the failure it prevents is the silent kind: the lowering's `fill` was a
# replaceStrings over these three names, so an argv containing some OTHER @TOKEN@ came out
# unchanged, as a literal. Turning it into ${CIDER_PH_TOKEN} instead makes the shell expand
# an unset variable to the EMPTY STRING, and an argument silently losing a path fragment is
# about the worst way for this to go wrong.
#
# Measured on the current graph: @RESOURCE_DIR@ 8,302 times and @CLANG@ 7,637, and nothing
# else matches. @LD64@ is declared because ciderBuck2Lower.nix supplies it whenever ld64 is
# non-null, so it is legitimate even though this graph happens not to use it.
KNOWN_PLACEHOLDERS = {"CLANG", "RESOURCE_DIR", "LD64"}


def ph_var(name: str) -> str:
    return "CIDER_PH_" + name


def check_placeholders(graph: dict) -> None:
    """Refuse to emit a script referencing a placeholder nobody exports."""
    seen: dict = {}
    for a in graph["actions"]:
        for x in a["argv"]:
            for m in _PLACEHOLDER.finditer(x):
                seen.setdefault(m.group(1), (a["identity"], x))
    unknown = sorted(k for k in seen if k not in KNOWN_PLACEHOLDERS)
    if unknown:
        lines = [f"FAIL: {len(unknown)} placeholder(s) no consumer exports:"]
        for k in unknown:
            ident, arg = seen[k]
            lines.append(f"    @{k}@  first in {ident}\n        {arg}")
        lines.append(
            "The emitted script would expand ${" + ph_var(unknown[0]) + "} to the empty "
            "string. Either add it to KNOWN_PLACEHOLDERS here AND to `placeholders` in "
            "nix/lib/ciderBuck2Lower.nix, or stop buck2-graph-dump.py from emitting it.")
        raise SystemExit("\n".join(lines))


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

    check_placeholders(graph)

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
    scripts = {}
    for g, acts in groups.items():
        n = safe_name(g)
        names.append(n)
        json.dump({"group": g, "actions": acts}, open(os.path.join(outdir, n + ".json"), "w"))
        # AND THE RENDERED SCRIPT, which is what the lowering actually needs. The .json is
        # the data; the .sh is the thing a builder sources instead of Nix concatenating it
        # per action at eval time. Emitting both means the consumer never re-renders and the
        # data stays available for anything that wants to inspect or re-render it.
        #
        # It references ${CIDER_PH_*} for each placeholder, so whoever sources it must export
        # those first. That is the whole portability trade: the script names no store path,
        # and the consumer supplies them from its OWN inputs, which is what lets one graph
        # serve any machine.
        scripts[n] = action_script(acts)
    open(os.path.join(outdir, "names"), "w").write("\n".join(names) + "\n")

    # THE DEPENDENCY EDGES, keyed and valued by SAFE NAME because that is the action name
    # nix/lib/dyn-actions.nix knows. It reads this file in specDir mode and can infer nothing
    # without it: the spec files are copied unparsed, so an edge that is not here does not
    # exist, and the resulting build succeeds with every action seeing an empty dependency.
    #
    # A CYCLE IS FATAL, not suboptimal: the bridge resolves a dependency to another action's
    # OUTPUT, so a cycle is an infinite recursion in the evaluator naming neither party.
    # Checked here rather than left to be discovered there. Measured on the current graph:
    # 1,474 groups, 925 with dependencies, 22,473 edges, no cycle.
    deps = group_deps(graph, groups)
    cycle = acyclic(deps)
    if cycle:
        raise SystemExit("FAIL: the group dependency graph has a cycle, which "
                         "nix/lib/dyn-actions.nix cannot express:\n    "
                         + "\n -> ".join(cycle))
    json.dump({safe_name(g): [safe_name(d) for d in ds] for g, ds in deps.items()},
              open(os.path.join(outdir, "deps.json"), "w"))

    # ONE FILE HOLDING EVERY GROUP'S SCRIPT, rather than one .sh per group, and the reason is
    # measured. Per-group files were written first and the lowering read them individually:
    # that cost 19.6 s of a 32.6 s evaluation, about 13 ms per file, against 0.10 s to read
    # all 1,474 from a plain store path.
    #
    # The context is what differs. These live in a derivation OUTPUT, and that output is
    # DEFERRED because this derivation reads a content addressed graph, so its real path is
    # not known until it is realised and every readFile against it resolves that again.
    # Hoisting the path into a let does not help: what gets hoisted is the placeholder.
    # Making this derivation input addressed does not help either, because the deferral comes
    # from its INPUT. Both were tried, and both measured 33 s.
    #
    # One readFile plus one fromJSON pays that resolution once, for about 1.5 s.
    with open(os.path.join(outdir, "scripts.json"), "w") as f:
        json.dump(scripts, f)
    print(f"wrote {len(names)} group spec(s) and script(s), {total_actions} action(s), "
          f"to {outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
