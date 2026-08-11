#!/usr/bin/env nu

# DOES THE PYTHON PORT OF needsOf AGREE WITH THE LOWERING? Run this after touching either one.
#
# #66 is moving the builder script out of the evaluator into scripts/buck-graph-to-specs.py.
# That script is assembled from `needs`: the groups a group copies from, and the staged data it
# restores. So needsOf gets ported, and the port is worth exactly what the evidence says.
#
# TWO SIDES, NEITHER OF THEM ASKING THE OTHER. The lowering is evaluated for real and dumps its
# own answer for every label; the python re-derives it from graph.json. Comparing the generator
# against itself would pass no matter what either one believed.
#
#   scripts/buck-needs-check.nu                    # 1,474 labels, plus the controls
#   scripts/buck-needs-check.nu --no-controls      # just the comparison
#
# BUILDS NOTHING beyond the graph, which is usually already built. About a minute.
#
# THE CONTROLS ARE THE POINT. Four of the five must fail, and each breaks ONE rule inside the
# port rather than mangling its output afterwards, so a silent one says the rule is not
# exercised by this graph. The fifth is informational and its measurement is in the python.

def main [
  --endpoint: string = ".#cider-buck2-prefix-min"
  --graph-endpoint: string = ".#cider-buck2-graph-min"
  --no-controls
] {
  print "== needsOf: the python port against the lowering =="

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

  # BOTH HALVES OF needsOf, per label. fromTargets alone would leave the farms untested, and
  # they are the half that fails late: a missing farm is a header not found in some other
  # target an hour later, not an error here.
  let expr = "l: builtins.mapAttrs (n: d: { t = d.passthru.deps; s = d.passthru.stagedNeeds; }) l.drvs"
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
  let args = ([$graphJson $tmp] | append (if $no_controls { [] } else { ["--controls"] }))
  let r = (do -i { ^python3 ./scripts/buck-needs-check.py ...$args } | complete)
  print $r.stdout
  if $r.exit_code != 0 {
    print -e ($r.stderr | lines | last 20 | str join "\n")
    rm -f $tmp
    print "FAIL: the port and the lowering do not agree"
    exit 1
  }
  rm -f $tmp
  print "PASS: the python port of needsOf matches the lowering on every label"
}
