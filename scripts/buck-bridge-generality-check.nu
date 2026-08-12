#!/usr/bin/env nu

# Could the bridge be lifted into another project as it stands?
#
# GENERALITY IS THE REQUIREMENT for #66, not a nicety: the bridge is worth having for other
# projects whatever it saves here, and cider is the first CONSUMER rather than the target. Every
# file in the reusable half says so in a comment. A comment is not a check.
#
# THE PROPERTY THAT IS ACTUALLY CHECKABLE is not the wording, it is the REFERENCES. A file can
# say "nothing cider-shaped in here" and still import the lowering; comments cannot be tested and
# paths can. So this reads every path a reusable file names and requires it to land inside the
# reusable set. That is exactly the condition for copying the set into another repo and having it
# work.
#
# WHAT IS DELIBERATELY NOT CHECKED: the prose. Naming cider in a comment, to say what the rule is
# or to record a measurement taken on it, is what the comments are FOR.
#
# Usage: buck-bridge-generality-check.nu [--controls]
#
# PORTED FROM PYTHON, byte identical with and without --controls. ONE THING WORTH KNOWING FOR THE
# NEXT PORT: the path regex uses a LOOKBEHIND, `(?<![\w/.])`, and nushell accepts it. The plain
# Rust regex crate has no lookaround at all, so this was measured rather than assumed before the
# port was written: `parse --regex` matched ./a/b.nix and correctly refused x./c/d.

const LIB_SUB = ["nix" "lib"]

# THE REUSABLE SET, by rule rather than by list, so a new toy joins it automatically and a new
# cider-specific file does not. dyn-* is the bridge and its fixtures; cider-* is the adapter.
const REUSABLE_PREFIX = "dyn-"

# A nix path expression: ./x, ../x, or ../../x. Bare <nixpkgs> is a lookup, not a repo path.
const NIX_PATH = '(?<![\w/.])(?<ref>\.{1,2}/[\w./-]+)'

# NOT A FIXTURE, and named rather than pattern-matched. A benign exception recognised by a
# pattern is how an unknown one gets swallowed with it.
const NOT_A_FIXTURE = [
  # What the fixtures test, rather than a fixture.
  "dyn-actions.nix"
  # A MEASUREMENT, not an assertion: it prices one emitted action and takes --argstr n.
  # There is no pass or fail to run in a suite, and the number is in its header.
  "dyn-actions-scale-toy.nix"
]

def reusable-files [lib: string] {
  ls -a $lib | where type == file | get name | each {|p| $p | path basename }
    | where {|f| ($f | str starts-with $REUSABLE_PREFIX) and (($f | str ends-with ".nix") or ($f | str ends-with ".py")) }
    | sort
}

# Comments blanked, keeping line numbers. The check is about references in CODE: a header
# that shows how to run the file, `nix build -f ./nix/lib/dyn-drv-probe.nix`, names a repo
# path and depends on nothing.
#
# NAIVE ON PURPOSE, and the direction it errs matters. A hash inside a string is treated as a
# comment, so this can only ever blank MORE than it should, which makes the check more
# permissive rather than less. A missed violation is possible; a false alarm is not.
def strip-comments [text: string] {
  $text | lines | each {|l|
    let i = ($l | str index-of "#")
    if $i < 0 { $l } else { $l | str substring 0..<$i }
  }
}

# Every path a reusable file names must resolve inside the reusable set. Returns
# [{file, line, ref}]. Line numbers come from enumerating the STRIPPED lines, which is the same
# count python gets from counting newlines before the match offset.
def check-refs [lib: string, files: list<string>, allowed: list<string>] {
  mut problems = []
  for f in $files {
    let stripped = (strip-comments (open --raw ($lib | path join $f) | decode utf-8))
    for row in ($stripped | enumerate) {
      for m in ($row.item | parse --regex $NIX_PATH) {
        # Resolve relative to nix/lib, then ask whether it is one of ours.
        let target = ($lib | path join $m.ref | path expand --no-symlink)
        let base = ($target | path basename)
        let inside = (($target | path dirname) == $lib) and ($base in $allowed)
        if not $inside {
          $problems = ($problems | append { file: $f, line: ($row.index + 1), ref: $m.ref })
        }
      }
    }
  }
  $problems
}

def main [--controls] {
  let root = ($env.FILE_PWD | path dirname)
  let lib = ($root | path join ...$LIB_SUB)
  let files = (reusable-files $lib)

  print $"== can the bridge be lifted out? ($files | length) reusable file\(s\) in nix/lib =="
  for f in $files { print $"    ($f)" }
  let problems = (check-refs $lib $files $files)
  print $"  references leaving the set: ($problems | length)"
  for p in ($problems | first 10) { print $"    ($p.file):($p.line) names ($p.ref)" }
  mut rc = (if ($problems | is-empty) { 0 } else { 1 })

  # AND IS EVERY FIXTURE ACTUALLY RUN? A correct check nobody calls is worth nothing, which
  # is the lesson that put the staging check into the suite in the first place. The fixtures
  # here have already caught properties that were FALSE and had no fixture, so one that
  # exists and is never invoked is the same failure a step earlier.
  #
  # THE BRIDGE ITSELF IS NOT A FIXTURE, nor is the fixup: they are what the fixtures test.
  # REACHABILITY, NOT DIRECT NAMING. A fixture the runner does not name is still exercised
  # if a fixture it DOES name imports it: dyn-actions-toy.nix is used that way by
  # dyn-actions-specdir-toy.nix. Checking direct naming alone reports it as dead.
  let runner = ($root | path join "scripts" "buck-dyndrv-check.nu")
  let fixtures = ($files | where {|f| ($f | str ends-with ".nix") and (not ($f in $NOT_A_FIXTURE)) })
  let runner_text = (open --raw $runner | decode utf-8)
  let reached = (reach $lib $fixtures ($fixtures | where {|f| $runner_text | str contains $f }))
  let unrun = ($fixtures | where {|f| not ($f in $reached) })
  print $"  fixtures in the set: ($fixtures | length), unreachable from buck-dyndrv-check.nu: ($unrun | length)"
  for f in $unrun { print $"    ($f)" }
  if not ($unrun | is-empty) { $rc = 1 }

  if $controls {
    # A CHECK THAT CANNOT FAIL IS WORTH NOTHING. The set is discovered by prefix, so the
    # way to prove the walk works is to shrink the allowed set and watch the internal
    # references become violations: the toys DO reference dyn-actions.nix, and if they did
    # not this check would be inspecting files that name no paths at all.
    print "\n== controls: each must FAIL =="
    mut fails = 0
    let shrunk = ($files | where {|f| $f != "dyn-actions.nix" })
    let without_bridge = (check-refs $lib $shrunk $shrunk)
    let n = ($without_bridge | where {|p| $p.ref | str ends-with "dyn-actions.nix" } | length)
    print $"  (if $n > 0 { 'FIRES ' } else { 'SILENT' }) dyn-actions.nix removed from the set: ($n) reference\(s\) become violations"
    if $n == 0 { $fails = $fails + 1 }

    # And the walk must actually be finding paths at all.
    let total = ($files | each {|f|
        (strip-comments (open --raw ($lib | path join $f) | decode utf-8))
          | each {|l| $l | parse --regex $NIX_PATH | length } | math sum
      } | math sum)
    print $"  (if $total > 0 { 'FIRES ' } else { 'SILENT' }) path references found across the set: ($total)"
    if $total == 0 { $fails = $fails + 1 }

    # The reachability walk needs its own control: with an empty runner nothing may be
    # reachable, or the walk is reporting everything reached no matter what it reads.
    let empty_reached = (reach $lib $fixtures [])
    let m = (($fixtures | length) - ($empty_reached | length))
    print $"  (if $m == ($fixtures | length) { 'FIRES ' } else { 'SILENT' }) runner naming nothing: ($m) of ($fixtures | length) fixture\(s\) unreachable"
    if $m != ($fixtures | length) { $fails = $fails + 1 }

    if $fails > 0 {
      print $"  ($fails) control\(s\) did not fire, so the zero above is not proven"
      $rc = 1
    }
  }
  exit $rc
}

# Transitive closure: a fixture named by an already-reached fixture is reached too.
def reach [lib: string, fixtures: list<string>, seed: list<string>] {
  mut reached = $seed
  mut changed = true
  while $changed {
    $changed = false
    for f in $fixtures {
      if $f in $reached { continue }
      let hit = ($reached | any {|r| (open --raw ($lib | path join $r) | decode utf-8) | str contains $f })
      if $hit {
        $reached = ($reached | append $f)
        $changed = true
      }
    }
  }
  $reached
}
