#!/usr/bin/env python3
# component-dag.py (#26): read Darling's ninja graph JSON and emit components.json,
# the driver for the per-component nix codegen (nix/lib/cider-components.nix).
#
# Steps:
#  1. Group edges into per-subproject components by CMakeFiles/<target>.dir/.
#  2. Build the component dependency graph (X deps Y if X consumes Y's output).
#  3. Drop deps satisfied by cider-base = everything reachable from the
#     libSystem umbrella (what base builds) plus the toolchain (ld/ar/migcom).
#     Those are provided by base, so components need not depend on them.
#  4. Condense strongly-connected components (Darling's add_circular two-pass
#     libs form real cycles) into single super-components so the DAG is acyclic
#     and the nix fixpoint resolves.
#  5. Emit {baseComponents, components:[{name, components, targets, deps}]}.
#
# Usage: component-dag.py <graph.json> <out.json>
import json, re, sys, collections

graph_path, out_path = sys.argv[1], sys.argv[2]
BASE_ROOT = "pins/libsystem/libSystem.B.dylib"

d = json.load(open(graph_path))
edges = d["edges"]
dir_re = re.compile(r'(?:^|/)(?:(.*?)/)?CMakeFiles/([^/]+)\.dir/')

def comp_of(p):
    m = dir_re.search(p)
    if m:
        dd = (m.group(1) or "").strip("/")
        return f"{dd}::{m.group(2)}" if dd else m.group(2)
    return None

out2comp = {}
for e in edges:
    for o in e["outputs"] + e["implicit_outputs"]:
        c = comp_of(o)
        if c:
            out2comp[o] = c
for e in edges:
    outs = e["outputs"] + e["implicit_outputs"]
    if any(comp_of(o) for o in outs):
        continue
    ic = {comp_of(i) or out2comp.get(i) for i in e["inputs"] + e["implicit_inputs"]}
    ic.discard(None)
    if len(ic) == 1:
        c = next(iter(ic))
        for o in outs:
            out2comp.setdefault(o, c)

# component -> its final buildable ninja target output (prefer a real artifact)
finalout = {}
for e in edges:
    for o in e["outputs"]:
        c = out2comp.get(o)
        if c and "CMakeFiles" not in o and "/" in o:
            # prefer dylib/exe/.a over intermediate _obj markers
            cur = finalout.get(c)
            if cur is None or (not cur.endswith((".dylib", ".a", ".tbd")) and o.endswith((".dylib", ".a", ".tbd"))):
                finalout[c] = o

dep = collections.defaultdict(set)
for e in edges:
    ocs = {out2comp.get(o) for o in e["outputs"] + e["implicit_outputs"]}
    ocs.discard(None)
    for i in e["inputs"] + e["implicit_inputs"]:
        dc = out2comp.get(i) or comp_of(i)
        for c in ocs:
            if dc and dc != c:
                dep[c].add(dc)

all_comps = set(out2comp.values())

# base_set = what cider-base builds = transitive closure of the libSystem link
# edge's inputs (its reexported sublibs). The umbrella itself has no sources / no
# CMakeFiles component, so seed from the LINK EDGE inputs, not the output.
base_set = set()
base_edge = next((e for e in edges if BASE_ROOT in (e["outputs"] + e["implicit_outputs"])), None)
if base_edge:
    stack = []
    for i in base_edge["inputs"] + base_edge["implicit_inputs"] + base_edge["order_only_inputs"]:
        c = out2comp.get(i) or comp_of(i)
        if c:
            stack.append(c)
    while stack:
        c = stack.pop()
        if c in base_set:
            continue
        base_set.add(c)
        stack.extend(dep.get(c, ()))
for c in list(all_comps):
    if "migcom" in c or "::x86_64-apple-darwin20-" in c:
        base_set.add(c)

gen = [c for c in all_comps if c not in base_set]
real_dep = {c: {y for y in dep.get(c, ()) if y not in base_set and y in set(gen)} for c in gen}

# Tarjan SCC (iterative, to avoid recursion limits)
index = {}; low = {}; onstack = {}; stack = []; sccs = []; ctr = [0]
for start in gen:
    if start in index:
        continue
    work = [(start, iter(sorted(real_dep.get(start, ()))))]
    index[start] = low[start] = ctr[0]; ctr[0] += 1
    stack.append(start); onstack[start] = True
    while work:
        v, it = work[-1]
        advanced = False
        for w in it:
            if w not in index:
                index[w] = low[w] = ctr[0]; ctr[0] += 1
                stack.append(w); onstack[w] = True
                work.append((w, iter(sorted(real_dep.get(w, ())))))
                advanced = True
                break
            elif onstack.get(w):
                low[v] = min(low[v], index[w])
        if advanced:
            continue
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop(); onstack[w] = False; comp.append(w)
                if w == v:
                    break
            sccs.append(comp)
        work.pop()
        if work:
            low[work[-1][0]] = min(low[work[-1][0]], low[v])

comp2scc = {}
for i, s in enumerate(sccs):
    for c in s:
        comp2scc[c] = i
scc_deps = collections.defaultdict(set)
for c in gen:
    for y in real_dep[c]:
        if comp2scc[c] != comp2scc[y]:
            scc_deps[comp2scc[c]].add(comp2scc[y])

def scc_name(i):
    s = sorted(sccs[i])
    n = re.sub(r'[^a-zA-Z0-9]+', '-', s[0]).strip('-')
    return n + (f"--scc{len(s)}" if len(s) > 1 else "")

components = []
for i, s in enumerate(sccs):
    targets = sorted({finalout[c] for c in s if c in finalout})
    if not targets:
        continue  # nothing buildable (e.g. header-only phony); skip
    components.append({
        "name": scc_name(i),
        "components": sorted(s),
        "targets": targets,
        "deps": sorted(scc_name(j) for j in scc_deps.get(i, ())),
    })

json.dump({"baseComponents": sorted(base_set), "components": components},
          open(out_path, "w"), indent=1)
ncyc = sum(1 for c in components if len(c["components"]) > 1)
print(f"total components: {len(all_comps)}; base-covered: {len(base_set)}; "
      f"generated super-components: {len(components)} ({ncyc} are cycles/SCCs)")
