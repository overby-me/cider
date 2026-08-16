#!/usr/bin/env nu

# THE COPIES ARE IMPORTED, NOT REWRITTEN. A check that reimplements what it checks tests the
# check, so the two mappings come from the file that really uses them.
use ./buck-script-check.nu [safe-name dep-var]

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
#   scripts/checks/buck-names-check.nu                # 1,474 real labels, plus the controls
#
# BUILDS NOTHING beyond the graph. Seconds.

def main [
  --endpoint: string = ".#cider-buck2-prefix-min"
  --graph-endpoint: string = ".#cider-buck2-graph-min"
  --no-controls
  # THE TWO INPUTS, SUPPLIED DIRECTLY, so iterating on the comparison does not pay for an
  # evaluation of the whole lowering each time. Both go together.
  --specs: string = ""       # a built cider-buck2-graph-specs directory
  --nix-json: string = ""    # the specName and depVar dump the eval below produces
] {
  print "== the name mappings, across every implementation =="

  if ($specs | is-not-empty) != ($nix_json | is-not-empty) {
    print "FAIL: --specs and --nix-json go together"
    exit 1
  }
  if ($specs | is-not-empty) {
    exit (run-comparison $specs (open --raw $nix_json | from json) (not $no_controls))
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
  let from_nix = (open --raw $tmp | from json)
  rm -f $tmp
  exit (run-comparison $specs $from_nix (not $no_controls))
}

# The comparison itself, reached either from the nix steps above or straight from --specs and
# --nix-json.
def run-comparison [specs: string, from_nix: record, controls: bool] {
  let labels = ($from_nix | columns | sort)
  print $"== name mappings across 4 spec-name and 2 variable-name implementations, on ($labels | length) real labels =="

  mut rc = 0

  # THE GENERATOR, THROUGH THE NAMES IT WROTE. Nothing is computed here: the question is whether
  # a file exists at the name the lowering will look for, which is the whole contract between
  # the two.
  let missing = ($labels | where {|l|
    not ($specs | path join $"(($from_nix | get $l).s).json" | path exists) })
  let tag_gen = (if ($missing | is-not-empty) { "DIFFERS" } else { "agrees " })
  print $"  ($tag_gen) the generator's spec file names: ($missing | length)"
  for label in ($missing | first 3) {
    print $"      ($label)\n        nix wants (($from_nix | get $label).s).json, which is not there"
  }
  if ($missing | is-not-empty) { $rc = 1 }

  # THE INDEPENDENT RE-DERIVATION, which is cider-specs-check. It spells the spec name out again
  # rather than importing the generator, so it is a copy that has to agree, and it is asked
  # DIRECTLY rather than quietly dropped from the comparison. It used to be python and was
  # reached by importing the module; a binary cannot be imported, so it grew --safe-names for
  # exactly this question.
  let t = (do -i { ^nix build ".#specs-tool" --no-link --print-out-paths } | complete)
  if $t.exit_code != 0 {
    print "  FAILED to build cider-specs-check"
    print -e ($t.stderr | lines | last 5 | str join "\n")
    $rc = 1
  }
  let labels_file = (mktemp -t --suffix .json)
  $labels | to json | save -f $labels_file
  let spc = (if $t.exit_code == 0 {
    let tool = ($t.stdout | lines | where {|l| $l != "" } | first)
    do -i { ^($tool | path join "bin" "cider-specs-check") --safe-names $labels_file } | complete
  } else { { exit_code: 1, stdout: "", stderr: "" } })
  rm -f $labels_file
  if $spc.exit_code != 0 {
    print "  FAILED to ask cider-specs-check for its copy"
    print -e ($spc.stderr | lines | last 5 | str join "\n")
    $rc = 1
  }
  let spc_names = (if $spc.exit_code == 0 { $spc.stdout | from json } else { [] })
  let spc_bad = ($labels | enumerate | where {|it|
    ($spc_names | get -o $it.index) != ($from_nix | get $it.item).s })
  let tag_spc = (if ($spc_bad | is-not-empty) { "DIFFERS" } else { "agrees " })
  print $"  ($tag_spc) cider-specs-check safe_name: ($spc_bad | length)"
  if ($spc_bad | is-not-empty) { $rc = 1 }

  mut bad = {}
  for label in $labels {
    let want = ($from_nix | get $label)
    let got_s = (safe-name $label)
    if $got_s != $want.s {
      $bad = ($bad | upsert "buck-script-check.nu safe-name" (($bad | get -o "buck-script-check.nu safe-name" | default []) | append { label: $label, want: $want.s, got: $got_s }))
    }
    # THE VARIABLE NAME IS A COMPOSITION, dep_var after safe_name, and checking it on the raw
    # label instead would silently be testing a different function.
    let got_d = (dep-var $want.s)
    if $got_d != $want.d {
      $bad = ($bad | upsert "buck-script-check.nu dep-var" (($bad | get -o "buck-script-check.nu dep-var" | default []) | append { label: $label, want: $want.d, got: $got_d }))
    }
  }
  for what in ["buck-script-check.nu safe-name" "buck-script-check.nu dep-var"] {
    let rows = ($bad | get -o $what | default [])
    let tag = (if ($rows | is-not-empty) { "DIFFERS" } else { "agrees " })
    print $"  ($tag) ($what): ($rows | length)"
    for r in ($rows | first 3) { print $"      ($r.label)\n        nix ($r.want)\n        nu  ($r.got)" }
    if ($rows | is-not-empty) { $rc = 1 }
  }

  # THE LABELS ARE NOT ALL ALIKE, and a run where every label happened to be alphanumeric would
  # agree trivially. Count what the mapping actually has to do.
  let changed = ($labels | where {|l| ($from_nix | get $l).s != $l } | length)
  let chars = ($labels | each {|l| $l | split chars } | flatten | uniq
    | where {|c| not ($c =~ '^[A-Za-z0-9_.-]$') } | sort | str join "")
  print $"  labels the mapping CHANGES: ($changed) of ($labels | length)"
  print $"  characters it has to map: '($chars)'"
  if $changed == 0 {
    print "  FAIL: no label needs mapping, so this proves nothing"
    $rc = 1
  }

  if $controls {
    print "\n== controls: each must FAIL =="
    mut fails = 0
    let n_colon = ($labels | where {|l| let w = ($from_nix | get $l).s; ($w | str replace "_" ":") != $w } | length)
    let tag1 = (if $n_colon > 0 { "FIRES " } else { "SILENT" })
    print $"  ($tag1) a spec name that keeps the colon: ($n_colon) label\(s\) would differ"
    if $n_colon == 0 { $fails += 1 }
    let n_pref = ($labels | where {|l| let w = ($from_nix | get $l).d; ($w | str replace "DYN_DEP_" "") != $w } | length)
    let tag2 = (if $n_pref > 0 { "FIRES " } else { "SILENT" })
    print $"  ($tag2) a variable name missing the prefix: ($n_pref) label\(s\) would differ"
    if $n_pref == 0 { $fails += 1 }
    if $fails > 0 {
      print $"  ($fails) control\(s\) did not fire"
      $rc = 1
    }
  }

  if $rc != 0 {
    print "FAIL: the name mappings do not agree"
    return 1
  }
  print "PASS: every implementation of both mappings agrees on every label"
  0
}
