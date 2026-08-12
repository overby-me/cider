#!/usr/bin/env nu

# DOES THE PYTHON PORT OF needsOf AGREE WITH THE LOWERING? Run this after touching either one.
#
# #66 moved the builder script out of the evaluator into the generator, which since #99 is
# linux/buildtools/graph-specs (Rust).
# That script is assembled from `needs`: the groups a group copies from, and the staged data it
# restores. So needsOf gets ported, and the port is worth exactly what the evidence says.
#
# TWO SIDES, NEITHER OF THEM ASKING THE OTHER. The lowering is evaluated for real and dumps its
# own answer for every label through definitionNeeds; the other side is the needs.json the graph
# derivation WROTE. Comparing the generator against itself would pass no matter what it
# believed, which is why the nix side must not be `deps` (that is read from needs.json).
#
#   scripts/buck-needs-check.nu                    # 1,474 labels, plus the controls
#   scripts/buck-needs-check.nu --no-controls      # just the comparison
#
# BUILDS NOTHING beyond the graph and its specs, both usually already built. About a minute.
#
# THE CONTROLS ARE THE POINT, AND TWO OF THEM ARE GONE. Both remaining ones must fire; they
# break the DATA and prove the comparison can fail. The two that are gone broke a RULE inside
# needsOf, which needed a second implementation to break, and since #99 the only implementation
# is the Rust generator. Restoring them means a debug mode on cider-graph-specs that writes a
# deliberately weakened needs.json. The python check says the same thing in its docstring.

def main [
  --endpoint: string = ".#cider-buck2-prefix-min"
  --graph-endpoint: string = ".#cider-buck2-graph-min"
  --no-controls
] {
  print "== needsOf: the generator's needs.json against the lowering =="

  let g = (do -i { ^nix build $graph_endpoint --no-link --print-out-paths } | complete)
  if $g.exit_code != 0 {
    print "FAIL: could not build the graph"
    print -e ($g.stderr | lines | last 12 | str join "\n")
    exit 1
  }
  # A multi-output derivation prints every output, and only one of them holds graph.json.
  let outs = ($g.stdout | lines | where {|l| $l != "" })
  let graph = ($outs | where {|p| ($p | path join "graph.json" | path exists) })
  if ($graph | is-empty) {
    print $"FAIL: none of the graph outputs holds graph.json: ($outs)"
    exit 1
  }
  let graphJson = ($graph | first | path join "graph.json")

  # THE SPECS, because what is compared now is the needs.json the generator WROTE. Since #99
  # the generator is Rust and there is no python port to re-derive with, and the artifact is
  # the better question anyway: it is what the lowering reads.
  let s = (do -i { ^nix build $"($graph_endpoint).specs" --no-link --print-out-paths } | complete)
  if $s.exit_code != 0 {
    print "FAIL: could not build the specs"
    print -e ($s.stderr | lines | last 12 | str join "\n")
    exit 1
  }
  let specs = ($s.stdout | lines | last)

  # BOTH HALVES OF needsOf, per label. fromTargets alone would leave the farms untested, and
  # they are the half that fails late: a missing farm is a header not found in some other
  # target an hour later, not an error here.
  # definitionNeeds, NOT deps: `deps` is read from needs.json, which the python generator
  # wrote, so comparing against it would compare the python against itself and pass whatever
  # either side believed. definitionNeeds calls needsOf, which is the definition being ported.
  let expr = "l: builtins.mapAttrs (n: d: { t = d.passthru.definitionNeeds.fromTargets; s = d.passthru.definitionNeeds.fromStaged; }) l.drvs"
  let tmp = (mktemp -t --suffix .json)
  let e = (do -i { ^nix eval --json $endpoint --apply $expr } | complete)
  if $e.exit_code != 0 {
    print "FAIL: could not evaluate the lowering"
    print -e ($e.stderr | lines | last 12 | str join "\n")
    exit 1
  }
  $e.stdout | save -f $tmp

  # Bound with let, not mut: a closure cannot capture a mutable variable in nushell, and
  # `do -i { ... }` is a closure.
  let args = ([$specs $tmp] | append (if $no_controls { [] } else { ["--controls"] }))
  let r = (do -i { ^python3 ./scripts/buck-needs-check.py ...$args } | complete)
  print $r.stdout
  if $r.exit_code != 0 {
    print -e ($r.stderr | lines | last 20 | str join "\n")
    rm -f $tmp
    print "FAIL: the port and the lowering do not agree"
    exit 1
  }
  rm -f $tmp
  print "PASS: the generator's needs.json matches the lowering on every label"
}
