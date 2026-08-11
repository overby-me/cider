#!/usr/bin/env python3
"""Check the rendered per-group action scripts against the graph they came from.

WHY THIS EXISTS. #66 moved the lowering's action rendering out of the evaluator and into
scripts/buck-graph-to-specs.py. That leaves the SAME rule written in two places -- how an
action identity becomes a group, how an argv element is escaped, when an action must _drain
first -- and a disagreement between them is silent in the worst way. The endpoint would build
a perfectly valid script that runs the wrong commands, or groups two targets into one
derivation, and nothing would say so.

SO THIS RE-DERIVES THE ANSWER INDEPENDENTLY. It does not import the generator and call its
functions, because a check that asks the thing under test what the answer is cannot fail. It
reads graph.json, works out what each group's script MUST contain, and compares that against
scripts.json, which is what the generator actually wrote and what the lowering actually reads.

COMPARISON IS ON WORDS, NOT TEXT. The two renderings quote differently on purpose: the old
evaluator path used nixpkgs escapeShellArg, which leaves a string bare when it matches
[[:alnum:],._+:@%/-]+, while a string holding a placeholder must be double quoted so the
variable expands. `"/nix/store/x"` and `/nix/store/x` are different text and the same word.
Comparing text reports 1,215 of 1,474 scripts as differing when none of them do.

AND IT PROVES IT CAN FAIL. --controls mutates a real script four ways and reports whether each
was caught, by the sub-check meant to catch it. Two earlier versions of these controls did not
fire: one mutation did not apply to the group it was tried on, and one deleted a _drain, which
the sequence comparison cannot see by construction. Both were harness bugs rather than good
news, which is the whole reason the controls are part of the check and not a one-off.

Usage:
  scripts/buck-specs-check.py <graph.json> <specsdir>              # check
  scripts/buck-specs-check.py <graph.json> <specsdir> --controls   # and prove it can fail
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sys

# The lowering's own copy of these rules, so the two files can be compared rather than trusted
# to match. Kept as a path relative to this script: the check must keep working when the repo
# moves, and an absolute path is a rename away from silently skipping the comparison.
LOWERING = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "nix", "lib", "ciderBuck2Lower.nix")

# INDEPENDENT re-derivations. Deliberately written out rather than imported.
IDENTITY = re.compile(r"^(?P<label>[^ ]+) \((?P<cfg>[^)]*)\) \((?P<action>.+)\)$")
NIX_SAFE = re.compile(r"^[A-Za-z0-9,._+:@%/-]+$")
PLACEHOLDER = re.compile(r"@([A-Z_0-9]+)@")
NAME_UNSAFE = re.compile(r"[^A-Za-z0-9_.-]")

MKDIR = re.compile(r'^mkdir -p "\$\(dirname (.*)\)"$', re.S)

# Placeholders resolve to these only for the comparison. The VALUES do not matter and must
# not: what is being checked is that the same word comes out, not which store path it names.
# Using obviously fake paths keeps a real one from accidentally matching something.
PH_VALUES = {
    "CLANG": "/PH/clang",
    "RESOURCE_DIR": "/PH/resource-root",
    "LD64": "/PH/ld64",
}


def group_of(identity: str, coarse_pin_of: dict) -> str:
    m = IDENTITY.match(identity)
    if not m:
        raise SystemExit(f"FAIL: unparseable action identity: {identity!r}")
    label = m.group("label")
    pin = coarse_pin_of.get(label)
    return label if pin is None else "root//buck-src:pin-" + pin


def safe_name(group: str) -> str:
    return NAME_UNSAFE.sub("_", group)


def fill(s: str) -> str:
    return PLACEHOLDER.sub(lambda m: PH_VALUES.get(m.group(1), m.group(0)), s)


def expand(text: str) -> str:
    for k, v in PH_VALUES.items():
        text = text.replace("${CIDER_PH_" + k + "}", v)
    return text


def logical_lines(text: str) -> list:
    """Split on UNQUOTED newlines only.

    One argv in the real graph holds a literal newline (a mig argument listing two file
    pairs). Splitting on every newline tears that line in half and the tokeniser then fails
    with "No closing quotation", which is the harness breaking rather than the script.
    """
    out, cur, quote, i = [], [], None, 0
    while i < len(text):
        c = text[i]
        if quote is None:
            if c == "\n":
                out.append("".join(cur))
                cur = []
                i += 1
                continue
            if c in "'\"":
                quote = c
            elif c == "\\" and i + 1 < len(text):
                cur.append(c)
                i += 1
                c = text[i]
        elif c == quote:
            quote = None
        elif quote == '"' and c == "\\" and i + 1 < len(text):
            cur.append(c)
            i += 1
            c = text[i]
        cur.append(c)
        i += 1
    if cur:
        out.append("".join(cur))
    return [x for x in out if x]


def canon(line: str) -> tuple:
    """One rendered line as the WORDS a shell would see. Quoting style disappears."""
    m = MKDIR.match(line)
    if m:
        return ("mkdir", tuple(shlex.split(m.group(1))))
    if line.startswith("echo "):
        return ("echo", tuple(shlex.split(line)))
    if line == "_drain":
        return ("drain",)
    if line.startswith("_spawn "):
        return ("run", tuple(shlex.split(line[7:])))
    return ("run", tuple(shlex.split(line)))


def canon_script(text: str) -> list:
    return [canon(l) for l in logical_lines(expand(text))]


def expected_sequence(actions: list) -> list:
    """What the script MUST contain, derived from the graph rather than from a re-rendering."""
    seq = []
    for a in actions:
        for o in a["outputs"]:
            seq.append(("mkdir", (fill(o),)))
        seq.append(("echo", ("echo", "  " + a["identity"])))
        seq.append(("run", tuple(fill(x) for x in a["argv"])))
    return seq


def expected_drains(actions: list) -> list:
    """Which actions must be preceded by a _drain: those reading a sibling's output."""
    own = set()
    for a in actions:
        own.update(a["outputs"])
    return [bool(any(i in own for i in a["inputs"])) for a in actions]


def actual_drains(seq: list) -> list:
    out, pending = [], False
    for e in seq:
        if e[0] == "drain":
            pending = True
        elif e[0] == "run":
            out.append(pending)
            pending = False
        else:
            pending = False
    return out


def strip_drains(seq: list) -> list:
    return [e for e in seq if e[0] != "drain"]


_SCRIPTS_CACHE: dict = {}


def all_scripts(specdir: str) -> dict:
    """scripts.json, read once. It is one file rather than one .sh per group because the
    evaluator reads it, and 1,474 separate reads out of a deferred derivation output cost
    19.6 s against 1.5 s for this. See buck-graph-to-specs.py."""
    if specdir not in _SCRIPTS_CACHE:
        with open(os.path.join(specdir, "scripts.json")) as f:
            _SCRIPTS_CACHE[specdir] = json.load(f)
    return _SCRIPTS_CACHE[specdir]


def read_script(specdir: str, group: str) -> str:
    scripts = all_scripts(specdir)
    n = safe_name(group)
    if n not in scripts:
        raise KeyError(f"scripts.json has no entry for {n}")
    return scripts[n]


def check_name_mapping() -> list:
    """The lowering has to sanitise a group name the same way this does.

    Compares the CHARACTER SET the two spell out rather than a sample of names: a sample can
    agree on every real label and still differ on the one that shows up next.
    """
    problems = []
    try:
        with open(LOWERING) as f:
            text = f.read()
    except OSError as e:
        return [f"cannot read {LOWERING}: {e}"]
    m = re.search(r'specSafeChars\s*=\s*(?:\n\s*)?lib\.stringToCharacters\s*\n?\s*"([^"]*)"',
                  text)
    if not m:
        return ["ciderBuck2Lower.nix has no specSafeChars: the lowering no longer states "
                "the mapping this checks, so the two cannot be compared"]
    nix_chars = set(m.group(1))
    py_chars = {chr(c) for c in range(32, 127) if not NAME_UNSAFE.match(chr(c))}
    if nix_chars != py_chars:
        problems.append(
            f"safe-character sets differ: only in nix {sorted(nix_chars - py_chars)!r}, "
            f"only in python {sorted(py_chars - nix_chars)!r}")
    if "CIDER_PH_" not in text:
        problems.append("ciderBuck2Lower.nix never mentions CIDER_PH_, so nothing exports "
                        "the placeholders the emitted scripts reference")
    return problems


def check(graph_path: str, specdir: str) -> tuple:
    with open(graph_path) as f:
        graph = json.load(f)
    coarse = graph.get("coarsePinOf", {})

    groups: dict = {}
    for a in graph["actions"]:
        groups.setdefault(group_of(a["identity"], coarse), []).append(a)

    problems = []

    names_path = os.path.join(specdir, "names")
    try:
        with open(names_path) as f:
            listed = {l for l in f.read().split("\n") if l}
    except OSError as e:
        return [f"cannot read {names_path}: {e}"], 0, 0
    ours = {safe_name(g) for g in groups}
    if listed != ours:
        problems.append(f"the names index disagrees: {len(listed - ours)} listed with no "
                        f"group, {len(ours - listed)} groups not listed")

    entries = 0
    for g, actions in groups.items():
        try:
            seq = canon_script(read_script(specdir, g))
        except OSError as e:
            problems.append(f"{g}: {e}")
            continue
        except ValueError as e:
            problems.append(f"{g}: cannot tokenise the script: {e}")
            continue
        except KeyError as e:
            problems.append(f"{g}: {e}")
            continue
        want = expected_sequence(actions)
        entries += len(want)
        if strip_drains(seq) != want:
            got = strip_drains(seq)
            where = next((i for i, (x, y) in enumerate(zip(got, want)) if x != y), None)
            if where is None:
                problems.append(f"{g}: {len(got)} entries, expected {len(want)}")
            else:
                problems.append(f"{g}: entry {where}\n      got  {str(got[where])[:180]}\n"
                                f"      want {str(want[where])[:180]}")
        if actual_drains(seq) != expected_drains(actions):
            problems.append(f"{g}: _drain placement differs from the sibling-read rule")

    problems.extend(check_name_mapping())
    return problems, len(groups), entries


def controls(graph_path: str, specdir: str) -> list:
    """Mutate a real script and confirm each mutation is caught. A control that does not
    apply is reported as such: a no-op mutation passing looks exactly like a caught one."""
    with open(graph_path) as f:
        graph = json.load(f)
    coarse = graph.get("coarsePinOf", {})
    groups: dict = {}
    for a in graph["actions"]:
        groups.setdefault(group_of(a["identity"], coarse), []).append(a)

    # A group that exercises BOTH sub-checks: more than a couple of actions, and at least one
    # that has to drain. Picking the first group alphabetically gave one with neither.
    victim = next((g for g in sorted(groups)
                   if any(expected_drains(groups[g])) and len(groups[g]) > 3), None)
    if victim is None:
        return ["no group exercises both sub-checks, so the controls cannot be run"]

    path = os.path.join(specdir, "scripts.json")
    with open(path) as f:
        blob = json.load(f)
    key = safe_name(victim)
    original = blob[key]

    muts = [
        ("drop an argument", " -c ", " "),
        ("corrupt a path", "buck-out", "buck-0ut"),
        ("blank an echo", 'echo "  ', 'echo "  X'),
        ("delete a _drain", "_drain\n", ""),
    ]
    out = []
    try:
        for label, find, repl in muts:
            applied = find in original
            blob[key] = original.replace(find, repl, 1)
            with open(path, "w") as f:
                json.dump(blob, f)
            _SCRIPTS_CACHE.pop(specdir, None)
            seq = canon_script(read_script(specdir, victim))
            by_seq = strip_drains(seq) != expected_sequence(groups[victim])
            by_drain = actual_drains(seq) != expected_drains(groups[victim])
            ok = applied and (by_seq or by_drain)
            out.append(f"  [{'ok ' if ok else 'BAD'}] {label}: applied={applied} "
                       f"caught_by_sequence={by_seq} caught_by_drain={by_drain}")
    finally:
        blob[key] = original
        with open(path, "w") as f:
            json.dump(blob, f)
        _SCRIPTS_CACHE.pop(specdir, None)
    return out


def main(argv: list) -> int:
    if len(argv) < 2:
        sys.exit(__doc__)
    graph_path, specdir = argv[0], argv[1]

    if "--controls" in argv[2:]:
        # WRITES TO THE SPEC DIR, so it refuses to touch a store path. The specs normally live
        # in /nix/store, which is read-only; failing there with a permission error would be
        # confusing, and succeeding would be worse.
        if os.path.realpath(specdir).startswith("/nix/store/"):
            print("controls need a WRITABLE spec dir; copy it out of the store first")
            return 2
        print("negative controls:")
        bad = 0
        for line in controls(graph_path, specdir):
            print(line)
            if "[BAD]" in line or line.startswith("no group"):
                bad += 1
        if bad:
            print(f"FAIL: {bad} control(s) did not fire, so this check proves nothing")
            return 1

    problems, ngroups, entries = check(graph_path, specdir)
    print(f"groups: {ngroups}   entries checked: {entries}   problems: {len(problems)}")
    for p in problems[:20]:
        print(f"    {p}")
    if len(problems) > 20:
        print(f"    ... and {len(problems) - 20} more")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
