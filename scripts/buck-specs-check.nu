#!/usr/bin/env nu
# Do the generator's rendered action scripts still say what the lowering means (#66)?
#
# Companion to buck-lowering-stage-check.nu, and it exists for the same reason: the only
# other thing that exercises this is an hour-long build. The lowering no longer renders a
# target's command sequence; cider-graph-specs does, inside the graph
# derivation, and the lowering reads the result. That leaves the SAME rule written twice --
# how an action identity becomes a group, how an argv element is escaped, when an action must
# _drain before it runs -- and a disagreement is silent: the endpoint would build a perfectly
# valid script that runs the wrong commands.
#
# This finds the two store paths and hands them to scripts/buck-specs-check.py, which
# re-derives the answer from graph.json rather than asking the generator what it thinks.
#
# IT BUILDS THE GRAPH IF IT IS NOT BUILT, which is why it is a separate check rather than
# part of scripts/buck-test.nu: that suite is about the buck2 side and never touches the Nix
# graph. With the graph already built this is a few seconds.
#
#   scripts/buck-specs-check.nu                       # against .#cider-buck2-graph-min
#   scripts/buck-specs-check.nu --endpoint .#other    # against another graph
#   scripts/buck-specs-check.nu --controls            # and prove the check can fail

def main [
  --endpoint: string = ".#cider-buck2-graph-min"
  --controls
] {
  # --print-out-paths on a multi-output derivation prints EVERY output, so the graph.json one
  # has to be picked out by name rather than by position. `data` sorts before the bare name,
  # and relying on the order is the kind of thing that works until an output is added.
  let g = (^nix build $endpoint --no-link --print-out-paths | complete)
  if $g.exit_code != 0 {
    print "FAIL: could not build the graph"
    print $g.stderr
    exit 1
  }
  let outs = ($g.stdout | split row "\n" | where {|l| $l != "" })
  let graph = ($outs | where {|p| ($p | path join "graph.json" | path exists) } | first)
  if ($graph | is-empty) {
    print $"FAIL: none of the graph outputs holds graph.json: ($outs)"
    exit 1
  }

  let s = (^nix build $"($endpoint).specs" --no-link --print-out-paths | complete)
  if $s.exit_code != 0 {
    print "FAIL: could not build the action specs"
    print $s.stderr
    exit 1
  }
  let specs = ($s.stdout | split row "\n" | where {|l| $l != "" } | first)

  print $"graph: ($graph)"
  print $"specs: ($specs)"

  # THE CONTROLS WRITE to the spec directory, and a store path is read only, so they run
  # against a copy. Skipping them instead would leave a check nobody has shown can fail.
  if $controls {
    let tmp = (mktemp -d)
    ^cp -r $"($specs)/." $tmp
    ^chmod -R u+w $tmp
    let r = (^python3 ./scripts/buck-specs-check.py $"($graph)/graph.json" $tmp --controls | complete)
    print $r.stdout
    if ($r.stderr | is-not-empty) { print -e $r.stderr }
    ^rm -rf $tmp
    exit $r.exit_code
  }

  let r = (^python3 ./scripts/buck-specs-check.py $"($graph)/graph.json" $specs | complete)
  print $r.stdout
  if ($r.stderr | is-not-empty) { print -e $r.stderr }
  exit $r.exit_code
}
