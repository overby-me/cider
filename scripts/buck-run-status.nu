#!/usr/bin/env nu

# WHAT IS A RUNNING OR FINISHED BUILD ACTUALLY DOING? Point it at the stderr log.
#
#   scripts/buck-run-status.nu <log>
#
# WHY THIS EXISTS: the same reason buck-lowering-invariance-check.nu does. The counting below
# was hand assembled about fifteen times in one session, and a snippet retyped that often
# drifts. It also encodes two things that are easy to get wrong from memory.
#
# WHAT THE SUFFIXES MEAN, which is not guessable:
#
#   <hash>-<name>.drv.drv   a PRODUCER. The .drv-named derivation that emits an action.
#   <hash>-root__<name>.drv an EMITTED action, the thing the producer emitted.
#   <hash>-buck2-<name>.drv a LOWERED derivation, the evaluator-computed route.
#
# Seeing all three at once is correct when both routes are being built, and is exactly what a
# run after a source change looks like.
#
# COUNT WHAT RAN, NEVER THE WILL-BE-BUILT LIST. nix prints "these N derivations will be built"
# and then may build none of them, because a content addressed placeholder always moves even
# when the output does not. Only `building '...'` lines mean a builder started.
#
# ERRORS ARE MATCHED ON THE LINE START. A plain search for "error" on these logs returns
# hundreds of Objective-C selectors like error:(NSError **)error and reads as catastrophe.

def main [log: string] {
  if not ($log | path exists) {
    print $"no such log: ($log)"
    exit 2
  }

  let lines = (open --raw $log | lines)
  let built = ($lines | where {|l| $l starts-with "building '" })
  let paths = ($built | each {|l| $l | str replace "building '" "" | str replace "'..." "" })

  let producers = ($paths | where {|p| $p | str ends-with ".drv.drv" } | length)
  let lowered = ($paths | where {|p| ($p | str contains "-buck2-") and not ($p | str ends-with ".drv.drv") } | length)
  let emitted = ($paths | where {|p| ($p | str contains "-root__") and not ($p | str ends-with ".drv.drv") } | length)
  let other = (($paths | length) - $producers - $lowered - $emitted)

  # ^error: is a nix-level failure. Anything else with the word in it is source text.
  let errs = ($lines | where {|l| ($l starts-with "error:") or ($l starts-with "error: ") } | length)

  print $"builders that RAN     ($paths | length)"
  print $"  producers .drv.drv  ($producers)"
  print $"  emitted   root__    ($emitted)"
  print $"  lowered   buck2-    ($lowered)"
  print $"  other               ($other)"
  print $"nix-level errors      ($errs)"

  # THE VERDICT, if this log belongs to a full-graph diff. Printed verbatim rather than
  # reinterpreted: the check already says identical N, differ M, and names every differing
  # group, so summarising it again here would only be a second place to get it wrong.
  let verdict = ($lines | where {|l| ($l | str contains "identical ") and ($l | str contains "differ ") })
  if ($verdict | is-not-empty) {
    print ""
    print "verdict:"
    for v in $verdict { print $"  ($v | str trim)" }
    let differs = ($lines | where {|l| $l starts-with "DIFFERS: " } | length)
    if $differs > 0 { print $"  groups named as differing: ($differs)" }
  }

  if $errs > 0 {
    print ""
    print "first nix-level errors:"
    for e in ($lines | where {|l| $l starts-with "error:" } | first 5) { print $"  ($e)" }
  }
}
