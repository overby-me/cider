#!/usr/bin/env python3
"""Assemble the port's action graph from what buck2 can be asked, for the Nix endpoint.

Run INSIDE nix/lib/darlingBuck2Graph.nix, right after a build, with the project root as the
working directory. Three buck2 interfaces are needed because no single one answers
everything (plan/buck2-port.md phase 3, and buck/bxl/probe.bxl for what was tried):

  * `aquery --output-all-attributes` -- the command line, at ANALYSIS time, without
    executing anything. Its `cmd` is rendered by joining the real argv with ", " (comma
    plus space), which is lossy in general: an argument containing that sequence cannot be
    told from two arguments. It is NOT lossy for this port, and that was measured rather
    than assumed -- over the 2,066 actions of the whole-port graph, reversing the join
    reproduces what-ran's argv EXACTLY for 2,066 of 2,066, and no argument anywhere
    contains the separator. The flags that do carry commas (-Wl,-alias_list,<file>) never
    carry comma-space. `--check-against-what-ran` re-verifies that, and the dump refuses to
    trust the join if it ever stops holding.
  * `log what-ran --format json` -- the same commands, but only for actions that actually
    RAN. Kept as the checker, not as the source: using it as the source is what forced the
    graph derivation to compile everything before it could learn anything.
  * `audit output <path>` -- which action produced a buck-out path. That is what separates
    an action's OWN outputs from the artifacts it consumes, which no argv makes explicit.
  * `aquery` -- every action's kind, including the in-process ones (symlinked_dir, write,
    copy) that never appear in what-ran.

The in-process artifacts are then copied out DEREFERENCED: a staged include root is a farm
of relative symlinks into the project, which mean nothing once the tree is a store path.

The graph comes out MACHINE-INDEPENDENT. An argv names its tools by absolute path, and
under Nix those are store paths, which would tie the dump to the machine that made it and
make it worthless as a committed artifact. Measured on the guest-tier graph, exactly three
store entries appear anywhere in 1,669 actions -- clang, the wrapper's resource root and
Darling's ld64 -- so each is replaced by a named placeholder that the consumer substitutes
from its own inputs. Anything left pointing into the store afterwards is reported, because
a silent one would be a machine dependency nobody notices until the cache misses.

Usage:
  buck2-graph-dump.py <isolation-dir> <out-dir> [--placeholder NAME=PATH ...] <target> ...
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys

BUCK_OUT = re.compile(r"buck-out/[A-Za-z0-9_.-]+/[^\s\"']*")


def buck2(isolation: str, *args: str) -> str:
    out = subprocess.run(["buck2", "--isolation-dir", isolation, *args],
                         capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr[-2000:], file=sys.stderr)
        raise SystemExit(f"buck2 {' '.join(args[:2])} failed")
    return out.stdout


def action_id(identity: str) -> str:
    """`root//pkg:name (<cfg>) (c_compile src/lock.c)` -> a stable, filesystem-safe id."""
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", identity).strip("_")


def parse_placeholders(argv: list[str]) -> tuple[dict, list[str]]:
    """--placeholder NAME=PATH ... -> ({PATH: "@NAME@"}, remaining argv).

    Flags are stripped here so the rest of argv is targets and nothing else: a stray flag
    reaches buck2 as a target pattern and the error names the flag, not the mistake.
    """
    subs, rest, i = {}, [], 0
    while i < len(argv):
        if argv[i] == "--check-against-what-ran":
            i += 1
            continue
        if argv[i] == "--placeholder" and i + 1 < len(argv):
            name, _, path = argv[i + 1].partition("=")
            if path:
                subs[path] = f"@{name}@"
            i += 2
            continue
        rest.append(argv[i])
        i += 1
    return subs, rest


def unjoin(cmd: str) -> list[str]:
    """aquery's `cmd` back into an argv.

    It is rendered as "[a, b, c]" -- the real argv joined with comma-space. Reversing that
    is only sound while no argument contains the separator, which is checked below and was
    measured over the whole-port graph: 2,066 of 2,066 actions reproduce what-ran exactly.
    """
    inner = cmd.strip()
    if inner.startswith("[") and inner.endswith("]"):
        inner = inner[1:-1]
    return inner.split(", ") if inner else []


def check_against_what_ran(isolation: str, ran: list, subs: dict) -> int:
    """Re-verify the join on whatever the last invocation actually executed."""
    truth = {}
    for line in buck2(isolation, "log", "what-ran", "--format", "json").splitlines():
        line = line.strip()
        if not line:
            continue
        ev = json.loads(line)
        cmd = ev.get("reproducer", {}).get("details", {}).get("command")
        if cmd:
            truth[ev["identity"]] = [portable(c, subs) for c in cmd]
    if not truth:
        print("  NOTE: nothing ran in the last invocation, so the join went unverified",
              file=sys.stderr)
        return 0
    by_identity = {a["identity"]: a["argv"] for a in ran}
    common = set(truth) & set(by_identity)
    bad = [i for i in common if truth[i] != by_identity[i]]
    print(f"  verified {len(common) - len(bad)}/{len(common)} commands against what-ran",
          file=sys.stderr)
    for ident in bad[:3]:
        print(f"  MISMATCH {ident}", file=sys.stderr)
    return len(bad)


def portable(value: str, subs: dict) -> str:
    """Longest first, so a resource root inside a compiler prefix is not half-replaced."""
    for path in sorted(subs, key=len, reverse=True):
        value = value.replace(path, subs[path])
    return value


def main(argv: list[str]) -> int:
    subs, argv = parse_placeholders(argv)
    if len(argv) < 4:
        sys.exit(__doc__)
    isolation, outdir, targets = argv[1], argv[2], argv[3:]

    # 1. Every action, from ANALYSIS. No build has to have happened for this.
    aq = json.loads(buck2(isolation, "aquery", "--output-all-attributes", "--json",
                          f"deps({' + '.join(targets)})"))

    ran = []
    for node, attrs in aq.items():
        cmd = attrs.get("cmd")
        if not cmd:
            continue  # analysis nodes, and the actions buck2 performs in-process
        target = node.split("target: `", 1)[-1].split("`", 1)[0]
        identity = f"{target} ({attrs.get('category', '')} {attrs.get('identifier', '')})"
        identity = identity.replace(" )", ")")
        ran.append({
            "id": action_id(identity),
            "identity": identity,
            "argv": [portable(c, subs) for c in unjoin(cmd)],
            # The only env buck2 sets is TMPDIR and BUCK_SCRATCH_PATH, and the consumer
            # makes its own in its own sandbox, so nothing is lost by aquery not carrying
            # env at all.
            "env": {},
        })

    # 2. Every buck-out path any command names, and which action produced it.
    referenced = sorted({m for a in ran for arg in a["argv"] for m in BUCK_OUT.findall(arg)})
    producer = {}
    for path in referenced:
        # `audit output` prints the producing action, or nothing for a path no action
        # claims (a scratch dir, say).
        line = buck2(isolation, "audit", "output", path).strip().splitlines()
        producer[path] = line[-1].strip() if line else None

    # 3. Every action's KIND, so the in-process ones can be told apart. Same query as
    #    step 1: aquery keys its json by the "(target: ..., id: N)" string audit output
    #    prints, which is what joins the two vocabularies.
    kinds = {}
    node_of = {}
    for node, attrs in aq.items():
        kind = attrs.get("kind")
        if kind:
            kinds[node] = kind
        # The two vocabularies meet here. `audit output` names an action as
        # "(target: `T`, id: N)"; what-ran names the same one as "T (category identifier)".
        # aquery is the only place that carries both, so it is what joins them.
        m = re.match(r"\(target: `(.+)`, id: `?(\d+)`?\)", node)
        if m and attrs.get("category"):
            key = (m.group(1), attrs["category"], attrs.get("identifier", ""))
            node_of[key] = node
    node_by_identity = {}
    for (target, category, identifier), node in node_of.items():
        node_by_identity[f"{target} ({category} {identifier})".rstrip()] = node
        node_by_identity[f"{target} ({category})"] = node

    def owns(action, path):
        """Whether this action is the one that PRODUCED that path.

        By action, not by target: a target's compile and its archive both name the object
        file, and only one of them writes it.
        """
        return producer.get(path) == node_by_identity.get(action["identity"])

    unjoined = [a["identity"] for a in ran if a["identity"] not in node_by_identity]
    if unjoined:
        print(f"  WARNING: {len(unjoined)} action(s) did not join to an aquery node, so "
              "their outputs cannot be told from their inputs:", file=sys.stderr)
        for ident in unjoined[:5]:
            print(f"    {ident}", file=sys.stderr)

    # 3b. An action's DECLARED inputs, which argv does not always name.
    #
    # Scraping buck-out paths out of the command line works for a compile or a link, where
    # every input is an argument. It fails completely for an action that reads its inputs
    # from a FILE: the prefix passes a manifest and nothing else, so its 5,537 inputs are
    # invisible to argv, and lowering it would run the builder against a staging tree that
    # holds none of them. aquery does declare them, together with the action that produces
    # each, which is what makes the dependency recoverable at all.
    INPUT = re.compile(r"action: \(target: `([^`]+)`, id: `?\d+`?\)")
    input_targets = {}
    for node, attrs in aq.items():
        decl = attrs.get("buck.all_ineligible_for_dedup_inputs")
        if not decl:
            continue
        seen = []
        for target in INPUT.findall(decl):
            # Same spelling the rest of the dump uses: aquery writes the configuration
            # after the label, and everything downstream groups actions by the bare label.
            target = target.split(" (")[0]
            if target not in seen:
                seen.append(target)
        if seen:
            input_targets[node] = seen

    staged = {}
    for a in ran:
        paths = sorted({m for arg in a["argv"] for m in BUCK_OUT.findall(arg)})
        a["outputs"] = [p for p in paths if owns(a, p)]
        a["inputs"] = [p for p in paths if not owns(a, p)]
        node = node_by_identity.get(a["identity"])
        own = a["identity"].split(" (")[0]
        a["input_targets"] = [t for t in input_targets.get(node, []) if t != own]
        for p in a["inputs"]:
            prod = producer.get(p) or ""
            if kinds.get(prod, "").lower() not in ("run",):
                staged[p] = prod  # an in-process artifact: it has to travel as DATA

    # 4a. Which artifact is which TARGET's output, from analysis: `targets
    #     --show-full-output` answers it without building, where the build report would
    #     have required exactly the build this dump exists to avoid.
    target_outputs = {}
    root = os.getcwd()
    for line in buck2(isolation, "targets", "--show-full-output", *targets).splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        label, path = parts[0], parts[1].strip()
        # Project-relative, like every other path in the graph.
        if path.startswith(root + "/"):
            path = path[len(root) + 1:]
        target_outputs.setdefault(label, []).append(path)

    # 4b. A target's own DEFAULT output can also be in-process (a staged lib directory that
    #     no command writes and no command consumes, so nothing above has seen it).
    written = {p for a in ran for p in a["outputs"]}
    for outs in target_outputs.values():
        for p in outs:
            if p not in written and p not in staged:
                staged[p] = producer.get(p) or ""

    # 4c. MATERIALIZE what has to travel as data. Only the targets that own an in-process
    #     artifact are built, never the whole graph: measured over the whole-port graph,
    #     549 of those 632 targets have no command actions at all (they are header roots,
    #     so building them compiles nothing) and the other 83 carry 85 commands between
    #     them -- 4% of the 2,066 the old what-ran dump had to run before it could learn
    #     anything.
    # By PROVIDER, through BXL, not by building targets. `buck2 build <target>` produces a
    # target's DEFAULT output and nothing else, and these artifacts hang off other
    # providers: darling-config.h is action id 2 of //src/include:darling_config, reachable
    # through no subtarget, and it simply went missing when a consumer came to include it.
    # buck/bxl/materialize.bxl asks for them by provider instead, which works because the
    # port's rules are its own.
    print("materializing in-process artifacts through BXL", file=sys.stderr)
    bxl = subprocess.run(
        ["buck2", "--isolation-dir", isolation, "bxl", "//buck/bxl/materialize.bxl:main",
         "--"] + [a for t in targets for a in ("--targets", t)],
        capture_output=True, text=True)
    if bxl.returncode != 0:
        print(bxl.stderr[-1500:], file=sys.stderr)
        raise SystemExit("materialization failed")
    print("  " + bxl.stdout.strip(), file=sys.stderr)

    # 4. Copy the in-process artifacts out, dereferenced.
    os.makedirs(os.path.join(outdir, "staged"), exist_ok=True)
    copied = {}
    trees = {}
    for path in sorted(staged):
        if not os.path.exists(path) and not os.path.islink(path):
            print(f"  MISSING artifact {path}", file=sys.stderr)
            continue
        if os.path.isdir(path):
            # A staged include root is a farm of SYMLINKS into the project -- 3,591 of them
            # and not one real file, in the SDK root. Recording where each one points, rather
            # than copying what it points AT, keeps the graph to names: it drops ~200 MB of
            # duplicated headers, and it means a source edit does not change the graph at
            # all, which is what lets the graph be reused across edits.
            links, real = {}, []
            for dirpath, _dirs, files in os.walk(path):
                for name in files:
                    full = os.path.join(dirpath, name)
                    rel = os.path.relpath(full, path)
                    if os.path.islink(full):
                        # Verbatim, so the recreated link resolves exactly as buck2's did:
                        # the staged directory sits at the same depth in the consumer's tree.
                        links[rel] = os.readlink(full)
                    else:
                        real.append(rel)
            if real:
                # Content buck2 generated rather than linked (a mig runner script, a written
                # header). It has to travel as data, but it comes from the RULES, not from
                # the sources, so it does not make the graph source-dependent.
                dest = os.path.join(outdir, "staged", re.sub(r"[^A-Za-z0-9_.-]+", "_", path))
                for rel in real:
                    d = os.path.join(dest, rel)
                    os.makedirs(os.path.dirname(d), exist_ok=True)
                    shutil.copy(os.path.join(path, rel), d, follow_symlinks=True)
                copied[path] = os.path.relpath(dest, outdir)
            trees[path] = links
        else:
            dest = os.path.join(outdir, "staged", re.sub(r"[^A-Za-z0-9_.-]+", "_", path))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if os.path.islink(path) and not os.path.exists(path):
                trees[path] = {"": os.readlink(path)}
                continue
            shutil.copy(path, dest, follow_symlinks=True)
            copied[path] = os.path.relpath(dest, outdir)

    graph = {
        "targets": targets,
        "actions": ran,
        "staged": copied,
        "stagedTrees": trees,
        "producers": producer,
        "kinds": kinds,
        "targetOutputs": target_outputs,
        "placeholders": sorted(subs.values()),
    }
    # Anything still pointing into the store is a machine dependency: name it rather than
    # letting it travel silently.
    leftover = sorted({m for a in ran
                       for s in a["argv"] + list(a["env"].values())
                       for m in re.findall(r"/nix/store/[a-z0-9]{32}-[^/\s\"',]+", s)})
    for m in leftover:
        print(f"  NOTE: store path left in the graph: {m}", file=sys.stderr)

    with open(os.path.join(outdir, "graph.json"), "w") as fh:
        json.dump(graph, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"graph: {len(ran)} command action(s), {len(copied)} staged artifact(s), "
          f"{len(referenced)} referenced path(s)")

    # The join is only sound while no argument contains the separator. Check it against
    # whatever the last invocation ran rather than assuming it stays true.
    if "--check-against-what-ran" in sys.argv:
        if check_against_what_ran(isolation, ran, subs):
            print("  aquery's rendering no longer round-trips; the dump is not trustworthy",
                  file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
