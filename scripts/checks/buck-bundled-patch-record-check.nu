#!/usr/bin/env nu

# A BUNDLED PIN'S PATCH SERIES MUST STILL REPRODUCE THE TREE IT DESCRIBES.
#
# vendor/pins/cocotron is checked into git and scripts/buck-src.nu COPIES it into
# vendor/src/cocotron. vendor/src is not tracked, and buck-pin-patches-check.nu already reports
# that vendor/patches/cocotron is an ORPHAN: nothing applies it. So every cocotron change lives in
# exactly one place, an untracked directory, and the patch directory is the only record of it.
#
# A RECORD NOBODY REPLAYS ROTS SILENTLY, and it had. Measured when this check was written: three of
# the twenty nine patches were already in the pin, three applied only in part, and five files still
# differed afterwards. One of those five mattered: O2Image.m has two near identical functions and
# the byte order guard from #212 applied CLEANLY TO THE WRONG ONE, because patch matched the
# context in the neighbour. Replaying the series would have put a fix where it does nothing, and
# the build would have succeeded.
#
# So this replays the series into a temporary directory and compares. --forward is deliberate: a
# patch already present in the pin is a fact about the pin, not a defect, and it must be skipped
# rather than prompted for.
#
# NOT A SUBSTITUTE FOR WIRING. This says the record is exact; it does not make it the mechanism.
#
# Exit 0 if every bundled pin's series reproduces its materialised tree, 1 otherwise.

def check_one [name: string, root: string]: nothing -> record {
  let pin = ($root | path join "vendor" "pins" $name)
  let src = ($root | path join "vendor" "src" $name)
  let patches = ($root | path join "vendor" "patches" $name)

  if not ($pin | path exists) { return { name: $name, skip: $"no pin at vendor/pins/($name)" } }
  if not ($src | path exists) { return { name: $name, skip: $"vendor/src/($name) is not materialised" } }
  if not ($patches | path exists) { return { name: $name, skip: $"no patch directory" } }

  let work = (mktemp -d)
  let tree = ($work | path join $name)
  ^cp -r $pin $tree
  ^chmod -R u+w $tree

  # `ls <dir>/*.patch` is a GLOB nushell expands before ls sees it, and it ERRORS when the join
  # produced a literal path rather than a pattern. List the directory and filter instead.
  let series = (ls -a $patches | where type == file | get name | where {|n| $n | str ends-with ".patch" } | sort)
  for p in $series {
    do -i { ^bash -c $"cd '($tree)' && patch -p1 --forward -s < '($p)'" } | ignore
  }
  do -i { ^bash -c $"cd '($tree)' && find . -name '*.rej' -delete && find . -name '*.orig' -delete" } | ignore

  # .buck-src-assembled is a materialisation marker the pin cannot have.
  let out = (do -i { ^bash -c $"diff -rq '($tree)' '($src)' 2>/dev/null | grep -v buck-src-assembled" } | complete)
  let differing = ($out.stdout | lines | where {|l| ($l | str trim) != "" })
  ^rm -rf $work

  { name: $name, patches: ($series | length), differing: $differing }
}

def main [] {
  let root = ($env.FILE_PWD | path dirname | path dirname)
  mut problems = []

  for name in ["cocotron"] {
    let r = (check_one $name $root)
    if ($r | get -o skip) != null {
      print $"  ($name): SKIPPED, ($r.skip)"
      continue
    }
    print $"  ($name): ($r.patches) patches, ($r.differing | length) files differ after replaying them"
    for d in $r.differing { print $"    ($d)" }
    if ($r.differing | length) > 0 {
      $problems = ($problems | append $"vendor/patches/($name) no longer reproduces vendor/src/($name): ($r.differing | length) files differ")
    }
  }

  if ($problems | is-empty) {
    print "PASS: every bundled pin's patch series reproduces its materialised tree"
    exit 0
  }

  print $"\n($problems | length) problems:"
  for p in $problems { print $"  ($p)" }
  print "\nFAIL: the patch directory is the ONLY record of these changes, because vendor/src is not tracked and nothing applies the series. Capture the delta as the next numbered patch and re-run this."
  exit 1
}
