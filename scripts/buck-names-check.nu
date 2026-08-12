#!/usr/bin/env nu

# DO ALL THE COPIES OF THE TWO NAME MAPPINGS AGREE? Run this after touching any of them.
#
# There are two mappings and several implementations of each, across two languages:
#   safe_name / specName   a group label to a store-safe file name, the key spec files are
#                          named by and the key a consumer looks a group up with
#   dep_var / depVar       that name to a shell variable, how the bridge hands a dependency
#                          path to an emitted action
#
# A MISMATCH IS SILENT IN THE WORST WAY. A wrong spec name either finds nothing, which at least
# errors, or finds ANOTHER GROUP's spec, which does not. A wrong variable name is worse: it is
# simply never set, expands to empty, and the action copies from nothing and produces a
# plausible, wrong result. That is how the first version of the bridge shipped a clean build
# that produced nothing.
#
#   scripts/buck-names-check.nu                # 1,474 real labels, plus the controls
#
# BUILDS NOTHING beyond the graph. Seconds.

def main [
  --endpoint: string = ".#cider-buck2-prefix-min"
  --graph-endpoint: string = ".#cider-buck2-graph-min"
  --no-controls
] {
  print "== the name mappings, across every implementation =="

  let g = (do -i { ^nix build $graph_endpoint --no-link --print-out-paths } | complete)
  if $g.exit_code != 0 {
    print "FAIL: could not build the graph"
    print -e ($g.stderr | lines | last 12 | str join "\n")
    exit 1
  }
  let graph = ($g.stdout | lines | where {|p| ($p | path join "graph.json" | path exists) })
  if ($graph | is-empty) {
    print "FAIL: none of the graph outputs holds graph.json"
    exit 1
  }

  # THE SPECS, because the generator's copy of the mapping is now judged through the NAMES IT
  # WROTE rather than by importing it: since #99 it is Rust, and a check cannot import a binary.
  let s = (do -i { ^nix build $"($graph_endpoint).specs" --no-link --print-out-paths } | complete)
  if $s.exit_code != 0 {
    print "FAIL: could not build the specs"
    print -e ($s.stderr | lines | last 12 | str join "\n")
    exit 1
  }
  let specs = ($s.stdout | lines | last)

  # The NIX side, which is the one the other implementations are checked against: it is what
  # the lowering actually uses to index full.json and to name the dependency variables.
  let expr = "l: builtins.mapAttrs (n: _: { s = l.specName n; d = l.depVar n; }) l.drvs"
  let tmp = (mktemp -t --suffix .json)
  let e = (do -i { ^nix eval --json $endpoint --apply $expr } | complete)
  if $e.exit_code != 0 {
    print "FAIL: could not evaluate the lowering"
    print -e ($e.stderr | lines | last 12 | str join "\n")
    exit 1
  }
  $e.stdout | save -f $tmp

  # let, not mut: a closure cannot capture a mutable in nushell.
  let args = ([$specs $tmp]
    | append (if $no_controls { [] } else { ["--controls"] }))
  let r = (do -i { ^python3 ./scripts/buck-names-check.py ...$args } | complete)
  print $r.stdout
  if $r.exit_code != 0 {
    print -e ($r.stderr | lines | last 20 | str join "\n")
    rm -f $tmp
    print "FAIL: the name mappings do not agree"
    exit 1
  }
  rm -f $tmp
  print "PASS: every implementation of both mappings agrees on every label"
}
