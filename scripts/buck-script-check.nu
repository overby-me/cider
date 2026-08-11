#!/usr/bin/env nu

# DOES THE PYTHON RENDERER PRODUCE THE LOWERING'S BUILDER SCRIPT, BYTE FOR BYTE? Run this after
# touching either side.
#
# #66 moves the builder script out of the evaluator and into the graph derivation. The script is
# what actually runs, so a port that merely looks equivalent is worth nothing. This compares the
# sha256 of the whole rendered text against passthru.builderScript for every label.
#
# THE RENDERER CANNOT NAME THE CONSUMER'S PATHS, which is the point rather than a limitation: it
# runs inside the graph derivation, before any consumer exists. The staging script, the staged
# tree scripts, the data tree and the dependency outputs are shell variables that
# nix/lib/dyn-actions.nix fills in through extraEnv and DYN_DEP_*, and this check substitutes
# the real values back exactly as the bridge does at build time.
#
#   scripts/buck-script-check.nu                  # 1,474 labels, plus the controls
#   scripts/buck-script-check.nu --no-controls
#
# BUILDS NOTHING beyond the graph and its specs. A couple of minutes.

def main [
  --endpoint: string = ".#cider-buck2-prefix-min"
  --graph-endpoint: string = ".#cider-buck2-graph-min"
  --no-controls
] {
  print "== builderScript: the python renderer against the lowering =="

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

  let s = (do -i { ^nix build $"($graph_endpoint).specs" --no-link --print-out-paths } | complete)
  if $s.exit_code != 0 {
    print "FAIL: could not build the specs"
    print -e ($s.stderr | lines | last 12 | str join "\n")
    exit 1
  }
  let specs = ($s.stdout | lines | last)

  # EVERYTHING THE COMPARISON NEEDS, IN ONE EVALUATION. The script HASH rather than its text:
  # 1,474 scripts are tens of megabytes and nothing here needs to read them, only to know
  # whether they match. `sample` is one whole script, and it is what the placeholder export
  # block is taken from, since that block is the consumer's clang paths.
  let expr = ('l: { data = builtins.unsafeDiscardStringContext "${l.graphData}"; '
    + 'sample = builtins.unsafeDiscardStringContext (builtins.head (builtins.attrValues '
    + '(builtins.mapAttrs (n: d: d.passthru.builderScript) l.drvs))); '
    + 'drvs = builtins.mapAttrs (n: d: { '
    + 'h = builtins.hashString "sha256" d.passthru.builderScript; '
    + 'g = builtins.unsafeDiscardStringContext "${d.passthru.stageScript}"; '
    + 'r = map (x: builtins.unsafeDiscardStringContext "${x}") d.passthru.treeScripts; '
    + 'd = d.passthru.deps; '
    + 'p = map (x: builtins.unsafeDiscardStringContext "${l.drvs.${x}}") d.passthru.deps; '
    + '}) l.drvs; }')
  let tmp = (mktemp -t --suffix .json)
  let e = (do -i { ^nix eval --json $endpoint --apply $expr } | complete)
  if $e.exit_code != 0 {
    print "FAIL: could not evaluate the lowering"
    print -e ($e.stderr | lines | last 12 | str join "\n")
    exit 1
  }
  $e.stdout | save -f $tmp

  # let, not mut: `do -i { ... }` is a closure and nushell will not capture a mutable.
  let args = ([($graph | first | path join "graph.json") $specs $tmp]
    | append (if $no_controls { [] } else { ["--controls"] }))
  let r = (do -i { ^python3 ./scripts/buck-script-check.py ...$args } | complete)
  print $r.stdout
  if $r.exit_code != 0 {
    print -e ($r.stderr | lines | last 20 | str join "\n")
    rm -f $tmp
    print "FAIL: the renderer and the lowering do not agree"
    exit 1
  }
  rm -f $tmp
  print "PASS: every label's builder script renders byte identically"
}
