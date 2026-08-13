#!/usr/bin/env nu
# Did a change to the lowering move any derivation it was not supposed to move?
#
# THE CHECK THAT A GREEN LADDER CANNOT REPLACE, and this exists because it was hand assembled
# four times in one session and caught two real problems that the ladder passed clean:
#
#   - Hoisting the label-independent tail out of the staging text moved ALL 1,474 staging
#     scripts. A nested indented string gets its own common-indent stripping, so the text
#     differed by whitespace alone: same 94 distinct scripts, every path different, every
#     target would have rebuilt. rung 1 and rung 2 were both green.
#   - Two cone fixtures produced a BYTE IDENTICAL check derivation, so running one silently
#     reused the other's result. Same shape: the thing that was supposed to be tested was not.
#
# WHY THE LADDER MISSES THEM. rung 2 builds ONE target and reports builders that ran. A change
# that moves every OTHER derivation, or that moves nothing but produces the wrong sharing, is
# invisible to it. This compares a fingerprint of every target instead.
#
# WHAT IT FINGERPRINTS, per label:
#   builderScript   the exact text the lowered derivation runs. Covers the staging reference,
#                   the dependency copies, the staged-tree restores, the action script and the
#                   output collection, so almost any lowering change shows up here.
#   stageScript     the staging derivation's store path. Separate because two groups wrongly
#                   SHARING a staging script is a specific failure that does not change any
#                   single builderScript, and it does not fail at eval: it surfaces much later
#                   as a missing file in some other target's compile.
#
# IT IS AN EVALUATION, NOT A BUILD, so it costs about the endpoint's eval and builds nothing.
#
#   scripts/checks/buck-lowering-invariance-check.nu --save before.json    # before your change
#   scripts/checks/buck-lowering-invariance-check.nu --against before.json # after it
#   scripts/checks/buck-lowering-invariance-check.nu --against before.json --expect-changes
#
# --expect-changes INVERTS THE VERDICT, for when a change is MEANT to move things: it then
# fails if nothing moved. That is the negative control, and it is the reason to trust a zero
# from the normal direction.

def fingerprint [endpoint: string] {
  # BOTH FIELDS IN ONE EVALUATION. Two passes would double the ~12 s cost and, worse, could
  # straddle an edit and compare two different trees.
  let expr = "l: builtins.mapAttrs (n: d: { s = builtins.hashString \"sha256\" d.passthru.builderScript; g = builtins.unsafeDiscardStringContext \"${d.passthru.stageScript}\"; }) l.drvs"
  let r = (do -i { ^nix eval --json $endpoint --apply $expr } | complete)
  if $r.exit_code != 0 {
    print "FAIL: could not evaluate the lowering"
    print -e ($r.stderr | lines | last 12 | str join "\n")
    exit 1
  }
  $r.stdout | from json
}

def main [
  --endpoint: string = ".#cider-buck2-prefix-min"
  --save: string
  --against: string
  --expect-changes
] {
  if ($save | is-empty) and ($against | is-empty) {
    print "give --save <file> before the change, or --against <file> after it"
    exit 2
  }

  let now = (fingerprint $endpoint)
  let labels = ($now | columns)

  if ($save | is-not-empty) {
    $now | to json | save -f $save
    let distinct = ($labels | each {|l| $now | get $l | get g } | uniq | length)
    print $"saved ($labels | length) labels to ($save)"
    print $"  distinct staging scripts: ($distinct)"
    exit 0
  }

  let before = (open --raw $against | from json)
  let beforeLabels = ($before | columns)

  # THE LABEL SET ITSELF IS PART OF THE FINGERPRINT. A change that adds or drops a target is
  # not an invariance failure in the same way, but reporting only the intersection would hide
  # it entirely.
  let added = ($labels | where {|l| $l not-in $beforeLabels })
  let dropped = ($beforeLabels | where {|l| $l not-in $labels })

  let common = ($labels | where {|l| $l in $beforeLabels })
  let movedScript = ($common | where {|l| ($now | get $l | get s) != ($before | get $l | get s) })
  let movedStage = ($common | where {|l| ($now | get $l | get g) != ($before | get $l | get g) })

  print $"labels: ($beforeLabels | length) -> ($labels | length)"
  print $"  added ($added | length)   dropped ($dropped | length)"
  print $"  builderScript changed: ($movedScript | length)"
  print $"  stageScript changed:   ($movedStage | length)"
  for l in ($movedScript | first 5) { print $"     script  ($l)" }
  for l in ($movedStage | first 5) { print $"     staging ($l)" }

  let total = (($movedScript | length) + ($movedStage | length) + ($added | length) + ($dropped | length))

  if $expect_changes {
    if $total == 0 {
      print "FAIL: nothing moved, so this run proves nothing about the check"
      exit 1
    }
    print $"PASS as a control: ($total) difference\(s), so the comparison can fire"
    exit 0
  }

  if $total != 0 {
    print $"FAIL: ($total) derivation fingerprint\(s) moved"
    exit 1
  }
  print "PASS: every label has the same builder script and the same staging script"
  exit 0
}
