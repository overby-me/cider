#!/usr/bin/env nu

# DOES migcom STILL HONOUR SOURCE_DATE_EPOCH? This guards #95, and it exists because the only
# thing that caught the original defect was an hour-class full-graph diff.
#
# THE DEFECT. migcom wrote the WALL CLOCK into every stub it generates, so two builds of the
# same inputs at different times produced different bytes. Under a content addressed store that
# defeats early cutoff for everything downstream of a mig group: the group re-runs for any
# reason, emits new bytes although nothing meaningful changed, and the cascade continues instead
# of stopping there. 110 of 1,474 groups were affected.
#
# WHY A DEDICATED CHECK RATHER THAN THE FULL DIFF. .#cider-buck2-dyn-gen-all does catch it, by
# reporting 110 differing groups, but it costs an hour and builds the entire graph twice over.
# This builds ONE mig group and reads one line.
#
#   scripts/buck-mig-epoch-check.nu
#
# WHAT THE FAILING STATE LOOKED LIKE, so this is anchored to an artifact rather than to a
# description. Before patches/bootstrap_cmds/0001-migcom-honour-source-date-epoch.patch, the
# same stubs read
#
#     * stub generated Tue Aug 11 18:57:26 2026    and    * stub generated Tue Aug 11 13:19:33 2026
#
# in two builds of the SAME inputs, those being the times each build ran. After it they read
# * stub generated Tue Jan  1 00:00:00 1980, which is SOURCE_DATE_EPOCH 315532800. So this
# check demonstrably distinguishes the two states; it is not a zero nobody has seen fail.
#
# THE CONTROL IS BUILT IN, and it is the half that matters: the check first asserts the
# "stub generated" line EXISTS. Without that, a migcom that stopped emitting the line at all,
# or a renamed output, would make the date assertion vacuously true and the guard would report
# success while guarding nothing.

def main [
  --endpoint: string = ".#cider-buck2-prefix-min"
  --label: string = "root//vendor/src:asl_ipc_mig"
] {
  print "== does migcom honour SOURCE_DATE_EPOCH? (#95) =="

  # THROUGH THE ATTRIBUTE PATH. nix build has no --apply, so the group is named directly; the
  # label needs quoting because it carries slashes and a colon.
  let b = (do -i { ^nix build $"($endpoint).drvs.\"($label)\"" --no-link --print-out-paths } | complete)
  if $b.exit_code != 0 {
    print "FAIL: could not build the mig group"
    print -e ($b.stderr | lines | last 12 | str join "\n")
    exit 1
  }
  check_out ($b.stdout | lines | last)
}

def check_out [out: string] {
  # Every generated stub, found by walking rather than by globbing a guessed path: the layout
  # under buck-out is long and changes with the target hash.
  let files = (do -i { ^find $out -name "*.c" -o -name "*.h" } | complete)
  let paths = ($files.stdout | lines | where {|l| $l != "" })
  if ($paths | is-empty) {
    print $"FAIL: no generated sources under ($out)"
    exit 1
  }

  # THE CONTROL FIRST. If nothing carries the line, the date assertion below is vacuous.
  let withLine = ($paths | where {|p| (open --raw $p | str contains "stub generated") })
  print $"  generated files: ($paths | length), carrying the stub line: ($withLine | length)"
  if ($withLine | is-empty) {
    print "FAIL: no file carries a `stub generated` line, so this check proves nothing."
    print "      Either migcom stopped emitting it or the output moved. Fix the check first."
    exit 1
  }

  # SOURCE_DATE_EPOCH is 315532800, which is 1980-01-01 UTC, so the stubs must say 1980.
  # Matching the YEAR rather than the whole string: ctime formats with the local timezone and
  # the day-of-week, and pinning those would make this fail for the wrong reason.
  let lines = ($withLine | each {|p|
    open --raw $p | lines | where {|l| $l =~ "stub generated" } | first
  })
  let bad = ($lines | where {|l| not ($l =~ "1980") })
  for l in ($lines | first 2) { print $"  ($l | str trim)" }
  if ($bad | is-not-empty) {
    print $"FAIL: ($bad | length) stub line\(s\) do not read 1980, so migcom is stamping the"
    print "      wall clock again and every mig group has become non-reproducible."
    for l in ($bad | first 3) { print $"    ($l | str trim)" }
    exit 1
  }
  print $"PASS: all ($lines | length) stub line\(s\) carry the SOURCE_DATE_EPOCH date"
}
