#!/usr/bin/env python3
"""The lowering, in python: what a group NEEDS, and the script that builds it.

#66 is moving both out of the Nix evaluator and into the graph derivation, where they are
computed once by scripts/buck-graph-to-specs.py rather than on every `nix build`. This module is
the shared half, so the generator and the checks that verify it cannot drift into two answers.

VERIFIED AGAINST THE LOWERING RATHER THAN BELIEVED. scripts/buck-needs-check.nu dumps
ciderBuck2Lower.nix's own needsOf for all 1,474 labels and requires this to match every one,
order included, with controls that break one rule at a time.
"""
from __future__ import annotations

import json
import re
import sys


def target_of(identity: str) -> str:
    """The label out of a buck2 action identity. Mirrors targetOf in the lowering."""
    i = identity.find(" (")
    return identity[:i] if i > 0 else identity


def group_of_label(label: str, coarse_pin_of: dict) -> str:
    pin = coarse_pin_of.get(label)
    return label if pin is None else "root//buck-src:pin-" + pin


def uniq(xs):
    """Order preserving, which is what lib.unique is. Never sorted: see the header."""
    seen, out = set(), []
    for x in xs:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


class Needs:
    """The lowering's needsOf, in python. Field for field, so it can be diffed by eye."""

    def __init__(self, graph: dict, coarse_pins: bool = True):
        self.coarse_pin_of = graph.get("coarsePinOf", {}) if coarse_pins else {}
        self.staged = graph.get("staged", {})
        self.staged_trees = graph.get("stagedTrees", {})
        self.staged_tree_deps = graph.get("stagedTreeDeps", {})

        # targets = lib.groupBy groupOf g.actions
        self.targets: dict = {}
        for a in graph["actions"]:
            self.targets.setdefault(
                group_of_label(target_of(a["identity"]), self.coarse_pin_of), []).append(a)

        # producerTarget: which GROUP writes which artifact.
        self.producer: dict = {}
        for a in graph["actions"]:
            g = group_of_label(target_of(a["identity"]), self.coarse_pin_of)
            for o in a["outputs"]:
                self.producer[o] = g

        # known = producerTarget // staged // stagedTrees, membership only.
        self.known = set(self.producer) | set(self.staged) | set(self.staged_trees)

        # ATTRIBUTE NAMES COME OUT OF NIX SORTED, so the two halves are sorted separately and
        # then concatenated, exactly as `attrNames a ++ attrNames b` does. Feeding python dict
        # order here would produce the right SET with the wrong order, which is the failure
        # this file goes out of its way to be able to see.
        self.staged_names = sorted(self.staged) + sorted(self.staged_trees)
        self.staged_by_target: dict = {}
        for o in self.staged_names:
            self.staged_by_target.setdefault(self.producer.get(o, ""), []).append(o)

        self._owner_cache: dict = {}

    def outs_of(self, label: str) -> list:
        """`outs` in the lowering: every artifact this group's actions write, deduped in order.
        These become the cp -aT lines that put the results under $out."""
        return uniq(o for a in self.targets.get(label, []) for o in a["outputs"])

    @staticmethod
    def safe_name(group: str) -> str:
        """Mirrors safe_name in buck-graph-to-specs.py and specName in the lowering. It has to
        be all three or a dependency resolves to a name nothing set."""
        return re.sub(r"[^A-Za-z0-9_.-]", "_", group)

    def owner_of(self, path: str, exact: bool = False):
        """The LONGEST known prefix of a path, or None. An input can be a file INSIDE a
        directory output, so exact matching is not enough: that is the difference between this
        and the cheaper producer lookup group_deps does."""
        if exact:
            return path if path in self.known else None
        hit = self._owner_cache.get(path)
        if hit is not None or path in self._owner_cache:
            return hit
        segs = path.split("/")
        got = None
        for n in range(len(segs), 0, -1):
            p = "/".join(segs[:n])
            if p in self.known:
                got = p
                break
        self._owner_cache[path] = got
        return got

    def of(self, label: str, break_rule: str = "") -> dict:
        """`break_rule` disables exactly ONE rule, for the controls. Breaking a rule here rather
        than mangling the result afterwards is the difference between a control that proves the
        rule is exercised by this graph and one that only proves the comparison can subtract."""
        acts = self.targets.get(label, [])
        ins = uniq(i for a in acts for i in a["inputs"])
        ex = break_rule == "exact"
        direct = uniq(o for o in (self.owner_of(i, ex) for i in ins) if o is not None)
        via = ([] if break_rule == "vialinks" else
               uniq(self.owner_of(t, ex)
                    for o in direct for t in self.staged_tree_deps.get(o, [])))
        owners = uniq(direct + [x for x in via if x is not None])

        declared = ([] if break_rule == "declared" else
                    uniq(group_of_label(t, self.coarse_pin_of)
                         for a in acts for t in a.get("input_targets", [])))
        declared_with_actions = [t for t in declared if t in self.targets]
        declared_staged = [o for t in declared for o in self.staged_by_target.get(t, [])]

        from_targets = uniq(
            t for t in ([self.producer.get(o) for o in owners] + declared_with_actions)
            if t is not None and t != label)
        from_staged = uniq(
            [o for o in owners if o in self.staged or o in self.staged_trees]
            + declared_staged)
        return {"t": from_targets, "s": from_staged}




# THE STATIC MIDDLE OF THE SCRIPT, lifted verbatim from a real passthru.builderScript
# rather than retyped. It is about sixty lines of shell and comment, and a typo in any of
# them is a byte the comparison would report without saying which side is right. Only the
# label varies.
_HARNESS = 'for _v in $(env | sed -n \'s/^\\(NIX_\\(CFLAGS\\|LDFLAGS\\)[A-Za-z0-9_]*\\)=.*/\\1/p\'); do\n  unset "$_v"\ndone\nexport TMPDIR="$NIX_BUILD_TOP/tmp" BUCK_SCRATCH_PATH="$NIX_BUILD_TOP/scratch"\nmkdir -p "$TMPDIR" "$BUCK_SCRATCH_PATH"\n\n# This target\'s own actions, in the order buck2 ran them, which is a topological one:\n# buck2 only runs an action once its inputs exist. Independent ones run CONCURRENTLY,\n# bounded by NIX_BUILD_CORES the way any other builder is -- so balance this with\n# `--cores` alongside `--max-jobs`, since 6 jobs each allowed 22 cores is 132 compiles.\n_max=${NIX_BUILD_CORES:-1}\nif [ "$_max" -lt 1 ]; then _max=1; fi\n_running=0\n# Checked EXPLICITLY, not left to set -e: a background job\'s failure does not abort the\n# shell, and an unnoticed one here means a target quietly missing an object and a link\n# error somewhere else entirely.\n_reap() {\n  if ! wait -n; then\n    echo "buck2 lower: an action of %(label)s failed" >&2\n    exit 1\n  fi\n  _running=$((_running - 1))\n}\n_spawn() {\n  "$@" &\n  _running=$((_running + 1))\n  while [ "$_running" -ge "$_max" ]; do _reap; done\n}\n_drain() { while [ "$_running" -gt 0 ]; do _reap; done; }\n\n# #66: THE ACTION SCRIPT IS READ, NOT COMPUTED HERE. It used to be a concatMapStrings\n# over every action, escaping every argv element and running replaceStrings over each\n# for the placeholders: per-argv work across 208,515 entries, in the EVALUATOR, on\n# every invocation. scripts/buck-graph-to-specs.py now renders it inside the graph\n# derivation, which already runs, and this reads the result.\n#\n# WHY IT IS EMBEDDED RATHER THAN SOURCED, which is the whole design question here and\n# was got wrong first. Sourcing ${graph.specs}/<name>.sh looks better -- the drv stays\n# tiny -- but graph.specs is ONE store path covering ALL 1,474 scripts, so changing a\n# single action moves it and every target\'s build command with it. That is a universal\n# rebuild on any BUCK edit, which is #37 again and undoes what #50, #53 and #55 bought.\n# Embedding the text keeps the granularity exactly where it was: a target\'s drv changes\n# only when ITS OWN script changes. The drv is no bigger than before either, because\n# this is the same text the old concatMapStrings produced.\n#\n# THE CONTEXT COMES OFF for the same reason it does on graph.json above: keeping it\n# would make every target depend on graph.specs and reintroduce the cascade the\n# embedding exists to avoid. Nothing is lost, since the text is self-contained.\n#\n# THE PLACEHOLDERS STAY AS SHELL VARIABLES rather than being substituted. The script\n# says ${CIDER_PH_CLANG} where the argv said @CLANG@, so the graph stays portable, the\n# text names no store path, and this consumer fills them from its OWN inputs with the\n# same values `fill` used. A clang bump therefore does not rewrite 8,704 command lines.\n# (Escaped above because a # does NOT start a comment inside a Nix indented string: the\n# whole block is one string, so a bare dollar-brace here is Nix antiquotation.)\n'


# ---- the builder script, which is the last thing #66 computes in the evaluator ----------

# CONSUMER VALUES THE GENERATOR CANNOT KNOW travel as shell variables, and arrive through
# nix/lib/dyn-actions.nix's extraEnv. This runs inside the graph derivation, long before any
# consumer exists: the staging script, the staged tree scripts and the data tree are store paths
# belonging to whoever is lowering this graph, so the text names them and never contains them.
#
# DEPENDENCIES USE THE BRIDGE'S OWN NAMING, DYN_DEP_<sanitised name>, because the bridge already
# sets those and inventing a second convention would mean two places to keep in step. Mirrored
# from depVar in dyn-actions.nix and dep_var in dyn-actions-spec-fixup.py.
_UNSAFE_SH = re.compile(r"[^A-Za-z0-9]")


def dep_var(name: str) -> str:
    return "DYN_DEP_" + _UNSAFE_SH.sub("_", name)


# lib.escapeShellArg DOES NOT ALWAYS QUOTE, and assuming it did put quotes around every output
# path here on the first attempt, against a lowering that had none. It leaves a string alone
# when every character is in this class, which includes the slash, so ordinary buck-out paths
# come through bare. Same class as _SAFE in buck-graph-to-specs.py, and it has to stay that way.
_ESC_SAFE = re.compile(r"^[A-Za-z0-9,._+:@%/-]+$")


def sh_quote(s: str) -> str:
    """lib.escapeShellArg, including its no-quotes-needed case."""
    if s == "":
        return "''"
    if _ESC_SAFE.match(s):
        return s
    return "'" + s.replace("'", "'\\''") + "'"


# WHERE THE CONSUMER'S PLACEHOLDER EXPORTS GO. A marker rather than a gap, so the substituted
# text is BYTE IDENTICAL to what the lowering assembles today: the export block sits in the
# middle of the script, and a consumer that prepended it at the top instead would produce a
# script that works and hashes differently, which throws away both the proof and CA early
# cutoff for every target.
EXPORTS_MARKER = "@@CIDER_PLACEHOLDER_EXPORTS@@\n"


def builder_parts(n, label: str, group_script: str) -> list:
    """The whole of builderScriptWith, as an ALTERNATING TEMPLATE: literal, variable, literal,
    variable, ..., literal. Always odd length, so index parity alone says which is which.

    WHY A TEMPLATE AND NOT A FINISHED STRING WITH "$VAR" IN IT, which is what this returned
    first and it was MEASURED rather than argued. A consumer has to put its own paths in, and
    with a finished string that means builtins.replaceStrings, which scans every byte of every
    script against every pattern. On this graph, 77 MB of text against up to 130 patterns:

        the lowering assembling the script itself      11.5 s
        reading full.json and substituting             28.0 s
        reading full.json, no substitution              5.2 s

    So the reads are a WIN and the scan is a 23 s loss. A template turns the same job into
    concatenation, which is linear in the output and has no pattern matching in it at all.

    THE SHAPE IS THE NIX TEMPLATE'S, line for line, including the blank lines: the check
    compares the joined result against passthru.builderScript byte for byte across all 1,474
    labels, and a match on 5,662 bytes of shell is worth far more than a match on an idea of
    what the script should do.

    VARIABLE NAMES ARE THE BRIDGE'S. DYN_DEP_<name> is what nix/lib/dyn-actions.nix sets, so
    the same text serves a lowered consumer and an emitted one. EXPORTS is the placeholder
    block, which only a consumer knows.
    """
    needs = n.of(label)
    parts = [""]

    def lit(s):
        parts[-1] += s

    def var(v):
        parts.append(v)
        parts.append("")

    lit("mkdir -p work && cd work\n")
    var("CIDER_STAGE")
    lit("\n")
    lit("\n")
    lit("# What other targets built, at the paths this target's argv expects. Modes are\n")
    lit("# PRESERVED: a dependency can be a TOOL -- migcom is, and the port's every codegen\n")
    lit('# edge runs it -- and dropping the executable bit turns into "Permission denied"\n')
    lit("# inside mig.sh, a long way from here. Writability is restored afterwards instead,\n")
    lit("# because the store copy is read-only and later actions write next to it.\n")
    for dep in needs["t"]:
        lit("cp -a ")
        var(dep_var(n.safe_name(dep)))
        lit("/. .\n")
        lit("# After EACH one, not at the end: the copy reproduces the store's read-only\n")
        lit("# directories, and two dependencies share parent directories under buck-out, so\n")
        lit("# the second copy cannot write into what the first one just created.\n")
        lit("find . -type d ! -perm -u+w -exec chmod u+w {} +\n")
    lit("\n")
    lit("\n")
    lit("# And the artifacts buck2 made in-process rather than by running a command. A staged\n")
    lit("# include root is rebuilt from its link map; anything buck2 GENERATED rather than\n")
    lit("# linked was copied out and is restored from there.\n")
    # NUMBERED BY SCRIPTS EMITTED, not by position in fromStaged. An entry with no links emits
    # no script, so indexing on the loop variable silently shifts every later number past the
    # first such entry: 730 of 1,474 labels matched anyway, because a group whose entries all
    # have links has the two numberings agree. The 744 that did not are what found this.
    tree = 0
    for o in needs["s"]:
        links = n.staged_trees.get(o)
        has_links = links is not None and links.get("n", 0) > 0
        data = n.staged.get(o)
        if has_links:
            var("CIDER_TREE_%d" % tree)
            lit("\n")
            tree += 1
        if data is not None:
            if has_links:
                lit("# MERGED, not replaced: a tree can hold both links into the project and files\n")
                lit("# buck2 generated (rtsig.h is one), and copying over the farm with -T destroys\n")
                lit("# the links that were just made.\n")
                lit("cp -a ")
                var("CIDER_DATA")
                lit("/%s/. %s/\n" % (data, sh_quote(o)))
                lit("chmod -R u+w %s\n" % sh_quote(o))
            else:
                lit('mkdir -p "$(dirname %s)"\n' % sh_quote(o))
                lit("cp -aT ")
                var("CIDER_DATA")
                lit("/%s %s\n" % (data, sh_quote(o)))
                lit("chmod -R u+w %s\n" % sh_quote(o))
    lit("\n")
    lit("\n")
    lit(_HARNESS % {"label": label})
    var("EXPORTS")
    # THE TEMPLATE'S OWN NEWLINE, after the interpolation. Both this one and the final one
    # below were missing at first and cost exactly two bytes across 5,662, which is precisely
    # the kind of thing a comparison against the real script catches and a reading of the code
    # does not.
    lit(group_script + "\n")
    lit("_drain\n")
    lit("\n")
    lit("# Everything this target produced, at the SAME relative paths, so a consumer can\n")
    lit("# stage it exactly where its own argv expects it.\n")
    for o in n.outs_of(label):
        lit('mkdir -p "$out/$(dirname %s)"\n' % sh_quote(o))
        lit("cp -aT %s \"$out/%s\"\n" % (sh_quote(o), o))
    lit("\n")
    return parts


def join_parts(parts: list, resolve) -> str:
    """Even index literal, odd index variable name. The one place that rule is written down."""
    return "".join(p if i % 2 == 0 else resolve(p) for i, p in enumerate(parts))


def builder_script(n, label: str, group_script: str, exports: str = EXPORTS_MARKER) -> str:
    """The template joined with the variables left as shell references, which is what the check
    compares. EXPORTS is the one variable a consumer must substitute rather than export."""
    return join_parts(builder_parts(n, label, group_script),
                      lambda v: exports if v == "EXPORTS" else '"$' + v + '"')
