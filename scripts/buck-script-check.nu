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

# EXPORTED, so scripts/buck-names-check.nu can IMPORT these two rather than keep a third copy.
# That check exists to prove every copy of the two mappings agrees, and the cheapest way to make
# a copy agree is not to have one.
#
# THE THREE PURE RULES, copied rather than imported: the renderer is Rust since #99
# (linux/buildtools/graph-specs/src/main.rs) and a check cannot import a binary. Each is
# exercised by the comparison below, so a wrong one does not sit unnoticed: get safe-name wrong
# and every label misses, get dep-var wrong and every dependency substitution misses.
export def safe-name [group: string] {
  $group | str replace --all --regex '[^A-Za-z0-9_.-]' "_"
}

export def dep-var [name: string] {
  $"DYN_DEP_($name | str replace --all --regex '[^A-Za-z0-9]' '_')"
}

# Even index literal, odd index variable name. The one place that rule is written down.
def join-parts [parts: list, exports: string] {
  $parts | enumerate | each {|it|
    if ($it.index mod 2) == 0 {
      $it.item
    } else if $it.item == "EXPORTS" {
      $exports
    } else {
      $'"$($it.item)"'
    }
  } | str join ""
}

# Put the consumer's values where the variables are. Same order the bridge resolves them in: the
# staging script and the data tree are one value each, the tree scripts are positional in
# fromStaged order, and the dependencies are keyed by the bridge's own variable name.
def render [text: string, info: record, data: string] {
  mut t = ($text | str replace --all '"$CIDER_STAGE"' $info.g | str replace --all '"$CIDER_DATA"' $data)
  for it in ($info.r | enumerate) {
    $t = ($t | str replace --all $'"$CIDER_TREE_($it.index)"' $it.item)
  }
  for it in ($info.d | enumerate) {
    let var = (dep-var (safe-name $it.item))
    $t = ($t | str replace --all $'"$($var)"' ($info.p | get $it.index))
  }
  $t
}

def main [
  --endpoint: string = ".#cider-buck2-prefix-min"
  --graph-endpoint: string = ".#cider-buck2-graph-min"
  --no-controls
  # THE TWO INPUTS, SUPPLIED DIRECTLY. The nix side is an evaluation of the whole lowering, so
  # without these a change to the comparison costs two minutes to see. Both go together.
  --specs: string = ""        # a built cider-buck2-graph-specs directory
  --dump-json: string = ""    # the lowering dump the eval below produces
] {
  print "== builderScript: the generator's full.json against the lowering =="

  if ($specs | is-not-empty) != ($dump_json | is-not-empty) {
    print "FAIL: --specs and --dump-json go together"
    exit 1
  }
  if ($specs | is-not-empty) {
    exit (run-comparison $specs (open --raw $dump_json | from json) (not $no_controls))
  }

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

  let dump = (open --raw $tmp | from json)
  rm -f $tmp
  exit (run-comparison $specs $dump (not $no_controls))
}

# The comparison itself, reached either from the nix steps above or straight from --specs and
# --dump-json. Returns the exit code rather than calling exit, so main owns that.
def run-comparison [specs: string, dump: record, controls: bool] {
  # THE ARTIFACT, ALWAYS. full.json is what the generator WROTE, and since #99 there is no
  # second implementation to re-render with: the renderer is Rust. A missing full.json is a
  # FAILURE rather than a reason to run a weaker check.
  let full_path = ($specs | path join "full.json")
  if not ($full_path | path exists) {
    print "FAIL: the specs hold no full.json, which is the file the lowering reads"
    return 1
  }
  print "  reading the generator's full.json (the artifact)"
  let full = (open --raw $full_path | from json)

  # The placeholder export block, lifted out of a real script by its own boundaries: it sits
  # between the static harness and this group's action script, both of which are known here.
  let sample = ($dump.sample? | default "")
  if ($sample | is-empty) {
    print "FAIL: the dump has no sample script text to take the placeholder block from"
    return 1
  }
  let b = ($sample | str index-of "export CIDER_PH_")
  let last = ($sample | str index-of --end "export CIDER_PH_")
  # END EXCLUSIVE, and this is the nushell trap the earlier ports hit: `str substring a..b` is
  # END INCLUSIVE, so the same arithmetic python does off by one here. `..<` is the exclusive
  # form, and the +1 keeps the newline that ends the block, as python's does.
  let c = ($sample | str index-of --range $last.. "\n") + 1
  let exports = ($sample | str substring $b..<$c)

  let labels = ($dump.drvs | columns)
  let total = ($labels | length)
  let res = (run-labels $full $dump $exports $labels null)
  print $"== builderScript: the generator's full.json against the lowering, ($total) labels =="
  print $"  byte identical   ($res.ok)"
  print $"  differ           ($res.bad | length)"
  for label in ($res.bad | first 8) { print $"    ($label)" }
  mut rc = (if ($res.bad | is-empty) { 0 } else { 1 })

  # DO THE GENERATOR'S TWO OUTPUTS AGREE? full.json is what the lowering joins; dyn/*.json is
  # what the bridge emits. They come from the same renderer, but they are written separately and
  # read by different consumers, so a divergence would mean the two routes build DIFFERENT
  # THINGS while both look healthy. Nothing else checks this.
  #
  # The dyn spec differs in exactly two known ways, and both are asserted rather than skipped
  # over: the EXPORTS slot is empty, because an emitted action gets the placeholders as env, and
  # there is a three line preamble a runCommand would have supplied.
  let dyn_dir = ($specs | path join "dyn")
  if ($dyn_dir | path type) == "dir" {
    mut agree = 0
    mut disagree = []
    mut missing = 0
    for label in $labels {
      let name = (safe-name $label)
      let path = ($dyn_dir | path join $"($name).json")
      if not ($path | path exists) {
        $missing += 1
        continue
      }
      let spec = (open --raw $path | from json)
      let want = (join-parts ($full | get $name) "")
      let got = ($spec.args | get 1)
      let i = ($got | str index-of "mkdir -p work && cd work")
      if $i < 0 or ($got | str substring $i..) != $want {
        $disagree = ($disagree | append $label)
      } else {
        $agree += 1
      }
    }
    print $"\n== the generator's two outputs, full.json against dyn/ =="
    print $"  agree            ($agree)"
    print $"  differ           ($disagree | length)"
    print $"  no dyn spec      ($missing)"
    for label in ($disagree | first 5) { print $"    ($label)" }
    if ($disagree | is-not-empty) or $missing > 0 { $rc = 1 }
  }

  if $controls {
    # EACH BREAKS ONE THING and must be caught. A comparison of two things that agree says
    # nothing about whether it could have disagreed, and this one compares hashes, where a bug
    # that renders the same wrong text on both sides is not even possible to see.
    print "\n== controls: each must FAIL =="
    mut fails = 0
    # One byte into the action script, which is the part the generator already emits.
    $fails += (control "one byte changed in the group script" $full $dump $exports $labels "script")
    # A dependency path pointing somewhere else: proves the dep copies are really compared and
    # not lost in the substitution.
    $fails += (control "one dependency path swapped" $full $dump $exports $labels "dep")
    # The staging script, which is the per-group value extraEnv exists to carry.
    $fails += (control "the staging script path swapped" $full $dump $exports $labels "stage")
    if $fails > 0 {
      print $"  ($fails) control\(s\) did not fire, so the agreement above is not proven"
      $rc = 1
    }
  }

  if $rc != 0 {
    print "FAIL: the renderer and the lowering do not agree"
    return 1
  }
  print "PASS: every label's builder script renders byte identically"
  0
}

# One pass over every label. `mutate` is null for the real comparison and names ONE break for a
# control, so the control runs the same code path the check does rather than a copy of it.
def run-labels [full: record, dump: record, exports: string, labels: list<string>, mutate: any] {
  mut ok = 0
  mut bad = []
  for label in $labels {
    let info0 = ($dump.drvs | get $label)
    let name = (safe-name $label)
    let gs0 = (join-parts ($full | get $name) $exports)
    let gs = (if $mutate == "script" { $gs0 | str replace "mkdir" "mkdir " } else { $gs0 })
    let info = (if $mutate == "dep" {
        $info0 | upsert p (if ($info0.p | is-empty) { $info0.p } else { ["/nix/store/wrong"] | append ($info0.p | skip 1) })
      } else if $mutate == "stage" {
        $info0 | upsert g "/nix/store/wrong-stage"
      } else { $info0 })
    let t = (render $gs $info $dump.data)
    if ($t | hash sha256) == $info.h {
      $ok += 1
    } else {
      $bad = ($bad | append $label)
    }
  }
  { ok: $ok, bad: $bad }
}

def control [name: string, full: record, dump: record, exports: string, labels: list<string>, mutate: string] {
  let r = (run-labels $full $dump $exports $labels $mutate)
  let n = ($r.bad | length)
  let tag = (if $n > 0 { "FIRES " } else { "SILENT" })
  print $"  ($tag) ($name): ($n) label\(s\) differ"
  if $n > 0 { 0 } else { 1 }
}
