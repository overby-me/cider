#!/usr/bin/env python3
"""What project files does each lowered target actually read?

nix/lib/darlingBuck2Lower.nix gives every lowered target the WHOLE filtered project as its
source, so editing any file it does not exclude relowers all of them. The precise fix is to
give each target only the sources it names -- and this measures whether that set can be
computed at all, and what it would buy, BEFORE the lowering is rewritten around it.

The plan recorded against the task said headers "come from cc_header_root staging actions
whose argvs name each header". That is not what the data says. A staging action arrives from
aquery as kind `symlinkeddir` with exactly four attributes -- kind, category, identifier and
executor config -- and no cmd and no inputs at all. It has no argv for a header to be named
in. Nothing computed from argvs alone would have staged a single header, and the failure
mode would have been a missing header at compile time, a long way from the cause.

Where the headers really are is the link MAP the dump records per staged tree (stagedTrees,
which the dumper gets from BXL rather than aquery). So a target's project sources are:

  * the project-relative tokens in its own actions' argvs -- the .c and .defs files, the
    scripts a codegen edge runs, the .exp symbol lists a link reads;
  * plus every link TARGET of each staged tree it consumes, which is where the header cones
    live: 53,603 links into buck-src, 3,528 into src and 142 into darwin in the graph this
    was measured on.

Tree ownership is resolved exactly the way the lowering's ownerOf does it -- longest known
prefix of an input path, because an action's output is often a directory and consumers name
files inside it.

Usage:
  scripts/buck-lower-srcdeps.py [<graph.json>] [--target LABEL] [--list] [--top N]
"""
from __future__ import annotations

import json
import os
import posixpath
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The lowering's own exclusion list, so "coarse" here is the CURRENT baseline rather than
# the unfiltered repo. Keep in step with nix/lib/darlingBuck2Lower.nix.
COARSE_EXCLUDE = {
    "plan", "docs", "nix", "scripts", "PLAN.md", "README.md", "CONTRIBUTORS.md",
    "LICENSE", ".vscode", ".claude", ".tangled", ".gdbinit", ".dfx-boot.log",
    ".git", ".jj", ".direnv", "buck-out", "result-graph-ref", "flake.nix", "flake.lock",
}

# Flags that carry a path in the SAME token.
GLUED = ("-I", "-F", "-L", "-iquote")


def target_of(identity: str) -> str:
    return identity.split(" (")[0]


def candidate_paths(tok: str):
    """Every project-relative path a single argv token might be.

    A token starting with @ is a PLACEHOLDER the dump substituted for an absolute store
    path (@CLANG@, @RESOURCE_DIR@, @LD64@). Treating those as project-relative is what made
    the first run of this report claim 5,449 project include roots when the real number is
    two.
    """
    if not tok or tok.startswith(("/", "@", "buck-out/")):
        return
    yield tok
    for g in GLUED:
        if tok.startswith(g) and len(tok) > len(g):
            rest = tok[len(g):]
            if not rest.startswith(("/", "@", "buck-out/")):
                yield rest


def include_roots(argv: list[str]):
    """Every directory an action puts on the include path, as written."""
    for i, t in enumerate(argv):
        if t in ("-I", "-isystem", "-F", "-iquote") and i + 1 < len(argv):
            yield argv[i + 1]
        elif t.startswith(("-I", "-F")) and len(t) > 2:
            yield t[2:]
        elif t.startswith("-iquote") and len(t) > len("-iquote"):
            yield t[len("-iquote"):]


def load(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    want = None
    for i, a in enumerate(argv):
        if a == "--target" and i + 1 < len(argv):
            want = argv[i + 1]
            args = [x for x in args if x != want]
    top_n = 10
    for i, a in enumerate(argv):
        if a == "--top" and i + 1 < len(argv):
            top_n = int(argv[i + 1])
            args = [x for x in args if x != argv[i + 1]]
    if not args:
        print("usage: buck-lower-srcdeps.py <graph.json> [--target LABEL] [--list]")
        return 2
    g = load(args[0])

    actions = g["actions"]
    staged = g.get("staged") or {}
    staged_trees = g.get("stagedTrees") or {}

    by_target: dict[str, list] = {}
    for a in actions:
        by_target.setdefault(target_of(a["identity"]), []).append(a)

    producer: dict[str, str] = {}
    for a in actions:
        for o in a.get("outputs", []):
            producer[o] = target_of(a["identity"])

    known = set(producer) | set(staged) | set(staged_trees)

    def owner_of(path: str):
        """Longest known prefix, so a file named inside a generated directory resolves."""
        segs = path.split("/")
        for n in range(len(segs), 0, -1):
            p = "/".join(segs[:n])
            if p in known:
                return p
        return None

    # A staged tree's links, resolved to the paths they actually point at.
    def tree_sources(tree_path: str) -> set:
        out = set()
        for rel, tgt in (staged_trees.get(tree_path) or {}).items():
            link = posixpath.join(tree_path, rel)
            dest = posixpath.normpath(posixpath.join(posixpath.dirname(link), tgt))
            if not dest.startswith("buck-out/") and not dest.startswith("/"):
                out.add(dest)
        return out

    # THE COMPLETENESS QUESTION. Naming individual files is only safe if every directory on
    # an include path is a staged tree, whose exact contents the link map records. An -I
    # pointing straight at a project directory lets the compile read anything under it, and
    # no per-file set computed from argvs could know what. So classify every include root,
    # and take the project ones WHOLESALE.
    root_class = {"staged": 0, "absolute": 0, "project": 0}
    project_roots: dict[str, int] = {}
    for a in actions:
        for p in include_roots(a.get("argv", [])):
            if p.startswith("buck-out/"):
                root_class["staged"] += 1
            elif p.startswith(("/", "@")):
                root_class["absolute"] += 1
            else:
                root_class["project"] += 1
                project_roots[p] = project_roots.get(p, 0) + 1

    def under(d: str) -> set:
        out = set()
        for dp, _dn, fs in os.walk(os.path.join(REPO, d)):
            rel = os.path.relpath(dp, REPO)
            out.update(posixpath.join(rel, f) for f in fs)
        return out

    whole_dirs = {d: under(d) for d in project_roots if os.path.isdir(os.path.join(REPO, d))}

    precise: dict[str, set] = {}
    missing_tokens: set = set()
    for label, acts in by_target.items():
        srcs: set = set()
        # 1. What this target's own commands name.
        for a in acts:
            for tok in a.get("argv", []):
                for cand in candidate_paths(tok):
                    if os.path.lexists(os.path.join(REPO, cand)):
                        srcs.add(cand)
                        break
                    if cand.split("/")[0] in ("buck-src", "src", "darwin", "buck-rust"):
                        # Names a project tree but is not on disk: worth seeing.
                        missing_tokens.add(cand)
            # 1b. And any project directory it puts on the include path, in full.
            for p in include_roots(a.get("argv", [])):
                if p in whole_dirs:
                    srcs |= whole_dirs[p]
        # 2. The staged trees it consumes, which is where headers live.
        ins = {i for a in acts for i in a.get("inputs", [])}
        owners = {o for o in (owner_of(i) for i in ins) if o}
        # input_targets covers actions that read their inputs from a manifest file rather
        # than naming them, which is how the prefix target works.
        for t in {t for a in acts for t in (a.get("input_targets") or [])}:
            for o, prod in producer.items():
                if prod == t and o in staged_trees:
                    owners.add(o)
        for o in list(owners):
            if o in staged_trees:
                srcs |= tree_sources(o)
                # One level out: a farm can link at another farm's output.
                for dest in tree_sources(o):
                    sub = owner_of(dest)
                    if sub and sub in staged_trees:
                        srcs |= tree_sources(sub)
        precise[label] = srcs

    # The coarse baseline: what every target depends on today.
    coarse = 0
    for dirpath, dirnames, filenames in os.walk(REPO):
        rel = os.path.relpath(dirpath, REPO)
        top = rel.split("/")[0] if rel != "." else ""
        if top in COARSE_EXCLUDE:
            dirnames[:] = []
            continue
        if rel == ".":
            dirnames[:] = [d for d in dirnames if d not in COARSE_EXCLUDE]
            filenames = [f for f in filenames if f not in COARSE_EXCLUDE]
        coarse += len(filenames)

    union = set().union(*precise.values()) if precise else set()
    counts = sorted(((len(v), k) for k, v in precise.items()), reverse=True)

    print(f"graph:            {args[0]}")
    print(f"targets:          {len(precise)}")
    print(f"coarse baseline:  {coarse} project files, for EVERY target")
    print(f"union of precise: {len(union)} files across all targets")
    if counts:
        mid = counts[len(counts) // 2][0]
        print(f"per target:       max {counts[0][0]}, median {mid}, min {counts[-1][0]}")
        print(f"median target reads {mid / coarse:.2%} of the coarse source")
    if missing_tokens:
        print(f"\nargv tokens naming a project tree but absent on disk: {len(missing_tokens)}")
        for m in sorted(missing_tokens)[:5]:
            print(f"    ? {m}")

    # The audit that decides whether any of the above can be trusted.
    print("\ninclude roots, by where they point:")
    for k in ("staged", "absolute", "project"):
        print(f"  {root_class[k]:8d}  {k}")
    if project_roots:
        print("  the project ones, taken WHOLESALE above:")
        for d, n in sorted(project_roots.items(), key=lambda kv: -kv[1]):
            size = len(whole_dirs.get(d, ()))
            print(f"    {n:6d}x  {d}  ({size} files)"
                  + ("" if d in whole_dirs else "  [not a directory here]"))

    print(f"\nlargest {top_n} targets by project-file count:")
    for n, label in counts[:top_n]:
        print(f"  {n:7d}  {label}")

    if want:
        got = precise.get(want)
        if got is None:
            near = [k for k in precise if want in k]
            print(f"\nno such target: {want}" + (f"; did you mean {near[:3]}" if near else ""))
            return 1
        hdr = sum(1 for p in got if p.endswith((".h", ".hpp", ".hh", ".defs", ".inc")))
        print(f"\n{want}")
        print(f"  project files: {len(got)}  ({hdr} headers)")
        print(f"  vs coarse:     {len(got) / coarse:.2%} of {coarse}")
        if "--list" in argv:
            for p in sorted(got):
                print(f"    {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
