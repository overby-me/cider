#!/usr/bin/env nu

# DOES THE GENERATOR'S needs.json AGREE WITH THE LOWERING? Run this after touching either one.
#
# #66 moved the builder script out of the evaluator into the generator, which since #99 is
# linux/buildtools/graph-specs (Rust).
# That script is assembled from `needs`: the groups a group copies from, and the staged data it
# restores, so the two sides have to agree on every label or a group copies the wrong thing.
#
# ALL NUSHELL SINCE #98. It was a .nu wrapper over a .py core; the core is here now and the
# python is deleted. The port was landed only after both implementations produced BYTE
# IDENTICAL output on the same inputs, controls included.
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

# specName in the lowering, safe_name in the generator: the key needs.json is written under.
# EVERY OTHER CHARACTER becomes an underscore, one per character.
def safe-name [group: string] {
  $group | str replace --all --regex '[^A-Za-z0-9_.-]' "_"
}

# Per label, three outcomes rather than one pass or fail: identical, same members in a different
# ORDER, and genuinely different members. They have different causes, and the ORDER one is real
# here rather than tidiness: the dep copies are `cp -a <dep>/. .` in list order, so two groups
# sharing a path let the LAST one win.
def compare [mine: record, theirs: record] {
  mut same = 0
  mut order = []
  mut diff = []
  mut missing = []
  for label in ($theirs | columns) {
    let a = ($mine | get -o $label)
    if $a == null {
      $missing = ($missing | append $label)
      continue
    }
    let b = ($theirs | get $label)
    if $a.t == $b.t and $a.s == $b.s {
      $same += 1
    } else if ($a.t | sort) == ($b.t | sort) and ($a.s | sort) == ($b.s | sort) {
      $order = ($order | append $label)
    } else {
      $diff = ($diff | append $label)
    }
  }
  let extra = ($mine | columns | where {|l| ($theirs | get -o $l) == null })
  { same: $same, order: $order, diff: $diff, missing: $missing, extra: $extra }
}

def report [res: record, mine: record, theirs: record, total: int] {
  print $"  identical          ($res.same) / ($total)"
  print $"  same set, reordered ($res.order | length)"
  print $"  different          ($res.diff | length)"
  print $"  absent from the generator ($res.missing | length)"
  print $"  absent from nix    ($res.extra | length)"
  for label in ($res.diff | first 5) {
    let a = ($mine | get $label)
    let b = ($theirs | get $label)
    print $"\n  ($label)"
    for pair in [[k, what]; ["t" "fromTargets"] ["s" "fromStaged"]] {
      let av = ($a | get $pair.k)
      let bv = ($b | get $pair.k)
      let only_gen = ($av | where {|x| not ($x in $bv) })
      let only_nix = ($bv | where {|x| not ($x in $av) })
      if ($only_gen | is-not-empty) or ($only_nix | is-not-empty) {
        print $"    ($pair.what): the generator has ($av | length), nix has ($bv | length)"
        if ($only_gen | is-not-empty) { print $"      generator only: ($only_gen | first 4)" }
        if ($only_nix | is-not-empty) { print $"      nix only:    ($only_nix | first 4)" }
      }
    }
  }
  let bad = ($res.diff | length) + ($res.order | length) + ($res.missing | length) + ($res.extra | length)
  if $bad == 0 { 0 } else { 1 }
}

def control [name: string, broken: record, theirs: record] {
  let r = (compare $broken $theirs)
  let bad = ($r.diff | length) + ($r.order | length) + ($r.missing | length) + ($r.extra | length)
  let tag = (if $bad > 0 { "FIRES " } else { "SILENT" })
  print $"  ($tag) ($name): ($bad) label\(s\) differ"
  if $bad > 0 { 0 } else { 1 }
}

def main [
  --endpoint: string = ".#cider-buck2-prefix-min"
  --graph-endpoint: string = ".#cider-buck2-graph-min"
  --no-controls
  # THE TWO INPUTS, SUPPLIED DIRECTLY, which turns a two minute run into a fraction of a second.
  # The nix side of this check is an EVALUATION of the whole lowering, and iterating on the
  # comparison itself while paying for that every time is how a port gets verified once and then
  # never again. Both must be given together: half of the pair is not a mode.
  --specs: string = ""       # a built cider-buck2-graph-specs directory
  --nix-json: string = ""    # the definitionNeeds dump the eval below produces
] {
  print "== needsOf: the generator's needs.json against the lowering =="

  if ($specs | is-not-empty) != ($nix_json | is-not-empty) {
    print "FAIL: --specs and --nix-json go together"
    exit 1
  }
  if ($specs | is-not-empty) {
    let theirs = (open --raw $nix_json | from json)
    exit (run-comparison $specs $theirs (not $no_controls))
  }

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
  let theirs = (open --raw $tmp | from json)
  rm -f $tmp
  exit (run-comparison $specs $theirs (not $no_controls))
}

# The comparison itself, reached either from the nix steps above or straight from --specs and
# --nix-json. Returns the exit code rather than calling exit, so main owns that.
def run-comparison [specs: string, theirs: record, controls: bool] {

  # THE FILE THE GENERATOR WROTE. Its extra `trees` key is ignored rather than dropped: this
  # check is about fromTargets and fromStaged, and a key it does not read cannot make it pass
  # or fail.
  #
  # KEYED BY SAFE NAME, WHILE THE NIX SIDE IS KEYED BY LABEL, and joining them the wrong way
  # round is not a subtle failure: the first version compared the two dicts directly and
  # reported 1,474 labels absent from each side, which is what a total key mismatch looks like.
  # The join goes label -> safe_name, because safe_name is not invertible.
  let raw = (open --raw ($specs | path join "needs.json") | from json)
  let labels = ($theirs | columns)
  let mine = ($labels | reduce --fold {} {|l, acc|
    let v = ($raw | get -o (safe-name $l))
    if $v == null { $acc } else {
      $acc | upsert $l { t: ($v.t? | default []), s: ($v.s? | default []) }
    }
  })

  print $"== needs: the generator's needs.json against the lowering, ($labels | length) labels from nix =="
  mut rc = (report (compare $mine $theirs) $mine $theirs ($labels | length))

  # CONTROLS, because a comparison of two things that agree proves nothing about whether the
  # comparison could ever have DISAGREED.
  #
  # THE TWO RULE-LEVEL CONTROLS ARE GONE, and the reason is worth keeping: breaking a rule
  # INSIDE needsOf needs a second implementation, and since #99 there is only the Rust one.
  # They covered the one-level-out indirection through a staged farm's own links, and the
  # DECLARED input_targets edges that no argv mentions, which is the omission that cost an
  # hour-deep coarse build. Restoring them means a debug mode on cider-graph-specs that writes
  # a deliberately weakened needs.json.
  #
  # A THIRD WAS ALREADY INFORMATIONAL and stays here as a measurement rather than as code:
  # reducing ownerOf to exact matching did NOT fire on this graph. The prefix walk does run,
  # 120 of 12,135 distinct input paths resolve to a strict prefix, all of them a .c inside a
  # mig codegen directory, but it changes no ANSWER because the group owning that directory is
  # already reached by another input of the same group.
  if $controls {
    print "\n== controls: each must FAIL =="
    # Order, since the comparison above claims to be order sensitive.
    let reversed = ($mine | items {|l, v| { l: $l, v: { t: ($v.t | reverse), s: $v.s } } }
      | reduce --fold {} {|it, acc| $acc | upsert $it.l $it.v })
    # The staged half on its own: without this, fromTargets agreeing would carry the verdict.
    let emptied = ($mine | items {|l, v| { l: $l, v: { t: $v.t, s: [] } } }
      | reduce --fold {} {|it, acc| $acc | upsert $it.l $it.v })
    mut fails = 0
    $fails += (control "fromTargets reversed" $reversed $theirs)
    $fails += (control "fromStaged emptied" $emptied $theirs)
    if $fails > 0 {
      print $"  ($fails) of the 2 binding control\(s\) did not fire, so the agreement above is not proven"
      $rc = 1
    }
  }

  if $rc != 0 {
    print "FAIL: the generator and the lowering do not agree"
    return 1
  }
  print "PASS: the generator's needs.json matches the lowering on every label"
  0
}
