#!/usr/bin/env nu

# Every materialized pin tree must be at the revision the manifest asks for.
#
# WHY THIS EXISTS. buck-src.nu is supposed to guarantee this, and on 2026-08-10 it did not: it
# printed "configd already materialized from the assembled tree" while the tree on disk was the
# PREVIOUS revision. Its second skip honoured a marker file on presence alone, with no
# comparison, so once a tree had been materialized by --all that marker skipped it for ever.
#
# The consequence is the expensive kind. The bump was verified by building
# //src/darwin/frameworks:SystemConfiguration_dylib, which compiles configd. With a stale tree that
# build compiles the OLD code and passes, so the bisect target reports success about a revision
# it never saw. A green build proving nothing.
#
# That specific bug is fixed. This exists because the FIX lives in the same script that had the
# bug, and a bump is exactly when nobody looks. This checks the RESULT on disk instead of
# trusting the process that produced it.
#
# THE CHECK: for every manifest entry with a hash, work out where it materializes, and if that
# directory exists require a .buck-src-rev stamp equal to the manifest rev. A tree that is not
# materialized at all is fine and is reported separately, because most of the 148 pins are only
# materialized on demand.
#
# THE DESTINATION RULE IS COPIED FROM buck-src.nu AND IS NOT A DETAIL. A pin directly under
# pins goes to vendor/src/<basename>; anything deeper materializes IN PLACE at its own
# path. Basenames are not unique, vendor/pins/xnu and vendor/pins/ciderd/xnu-sys/xnu both end
# in xnu, and collapsing them into vendor/src/xnu is a collision that has already broken this
# project once through materializePins.
#
# A MISSING STAMP IS REPORTED, NOT FAILED, AND THAT DISTINCTION WAS LEARNED IMMEDIATELY. The
# first version of this treated an unstamped tree as a defect. Run against the real repo it
# reported 143 of 148 materialized pins as problems, because every one of them was placed by an
# older --all that wrote only .buck-src-assembled. That is not 143 defects, it is the ordinary
# state of this tree, and a check that fails on the ordinary state gets ignored or silenced.
#
# Worse, it made the negative control worthless: a planted stale rev DID make it exit 1, but so
# did the 143 unstamped trees, so the exit code proved nothing about stale detection. The control
# only became real once stale was the ONLY thing that fails.
#
# So: a mismatched stamp is a FAILURE, because it is a definite statement that the tree is the
# wrong revision. An absent stamp is COUNTED and named, because it means provenance is unknown
# rather than known-bad, and the honest remedy is one --all that will stamp them all.
#
# Exit 0 if no materialized pin contradicts the manifest, 1 if any does.
#
# PORTED FROM PYTHON, byte identical on the real tree and under both negative controls (a planted
# stale stamp, and a destination collision). TWO NUSHELL TRAPS WERE PAID FOR HERE:
#
#   `path exists` answers for FILES AND DIRECTORIES ALIKE where the python asks os.path.isdir, so
#   a pin whose destination happened to be a regular file would count as materialized. The type
#   has to be tested explicitly.
#
#   `str substring 0..12` is END-INCLUSIVE and yields THIRTEEN characters, where python's [:12]
#   yields twelve. Use `0..<12`. This is exactly the kind of difference that survives the happy
#   path untouched and only appears in the failure text, which is the text nobody diffs: the
#   real run was byte identical and only the planted stale-rev control exposed it.

const PIN_ROOT = "vendor/pins"

# The test is DIRECTLY UNDER THE PIN ROOT, which is not the same thing as a fixed depth. It read
# `== 3` while the root was src/external, and writing `== 2` for vendor/pins/ would just reseat the same
# landmine one rename later. Expressed against the root, it survives the next move without anyone
# having to remember this comment.
def directly-under-pin-root [path: string] {
  ($path | split row "/" | length) == (($PIN_ROOT | split row "/" | length) + 1)
}

# Where buck-src.nu materializes this entry. Same rule, deliberately duplicated: if the two ever
# disagree, this check is measuring a directory nothing writes.
def dest-for [root: string, path: string] {
  if (directly-under-pin-root $path) {
    $root | path join "vendor/src" ($path | path basename)
  } else {
    $root | path join $path
  }
}

def main [
  --manifest: string = ""   # point at a copy to negative-control this without touching the repo
] {
  let root = ($env.FILE_PWD | path dirname | path dirname)
  let manifest = (if ($manifest | is-empty) { $root | path join "nix" "submodules.json" } else { $manifest })

  let entries = (open --raw $manifest | from json | where {|e| ($e | get -o hash) != null })

  # NO TWO PINS MAY MATERIALIZE TO THE SAME PLACE. This is the invariant the whole
  # directly-under-the-pin-root rule exists to protect, and until #87 stage 2 nothing
  # asserted it: the collision was found once by an endpoint build dying at BXL
  # materialisation, an hour in, with "File not found: root//.../vendor/src/xnu".
  # vendor/pins/xnu and vendor/pins/ciderd/xnu-sys/xnu share the basename xnu, so getting the depth
  # test wrong collapses them onto vendor/src/xnu and one silently overwrites the other.
  # It costs a table to say so here instead.
  let placed = ($entries | each {|e| { path: $e.path, dest: (dest-for $root $e.path) } })
  mut owners = {}
  mut collisions = []
  for p in $placed {
    if ($p.dest in ($owners | columns)) {
      $collisions = ($collisions | append $"($p.path) and ($owners | get $p.dest) both materialize to (($p.dest | str replace $"($root)/" '')), so one overwrites the other")
    } else {
      $owners = ($owners | insert $p.dest $p.path)
    }
  }
  if not ($collisions | is-empty) {
    print $"\n($collisions | length) pin destination collision\(s\):"
    for c in $collisions { print $"  ($c)" }
    print "\nFAIL: two pins cannot share a materialization directory. This is what the depth rule in dest_for prevents, and a wrong depth reintroduces it."
    exit 1
  }

  mut materialized = 0
  mut stale = 0
  mut unstamped = 0
  mut problems = []
  for e in $entries {
    let dest = (dest-for $root $e.path)
    # `path exists` is true for a FILE too; the python asks isdir, so test the type.
    if (($dest | path exists) == false) or (($dest | path type) != "dir") { continue }
    $materialized = $materialized + 1
    let stamp = ($dest | path join ".buck-src-rev")
    if (not ($stamp | path exists)) {
      $unstamped = $unstamped + 1
      continue
    }
    let got = (open --raw $stamp | str trim)
    if $got != $e.rev {
      $stale = $stale + 1
      $problems = ($problems | append $"($e.path) is at ($got | str substring 0..<12) but the manifest asks for ($e.rev | str substring 0..<12). The tree is STALE and anything compiled from it tests the wrong revision.")
    }
  }

  print $"manifest entries with a hash: ($entries | length); materialized on disk: ($materialized); stale: ($stale); unstamped: ($unstamped)"
  if $unstamped > 0 {
    print $"note: ($unstamped) materialized trees carry no .buck-src-rev, so their revision cannot be established from disk. They were placed by an --all that predates the stamp. Not a failure, and one scripts/buck-src.nu --all stamps them all. Only a stamp that CONTRADICTS the manifest fails below."
  }

  if ($problems | is-empty) {
    print "PASS: no materialized pin contradicts the manifest"
    exit 0
  }

  print $"\n($problems | length) materialized pins contradict the manifest:"
  for p in $problems { print $"  ($p)" }
  print "\nFAIL: a build against a stale pin compiles the PREVIOUS upstream revision and passes, which is why this is checked on disk rather than trusted from the script that materializes it."
  exit 1
}
