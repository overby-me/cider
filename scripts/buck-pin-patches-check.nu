#!/usr/bin/env nu

# Every patch set must reach exactly the pin it was written for, and nothing else.
#
# THE WHOLE MECHANISM IS A pathExists AND A BASENAME, which is two silent failure modes in
# three lines. From nix/lib/cider-src.nix:
#
#     patchSub   = patchesDir + ("/" + (e.patches or base));   # base is baseNameOf e.path
#     hasPatches = builtins.pathExists patchSub;
#
# So a patch directory is applied when it happens to exist and is skipped when it does not.
# Nothing anywhere says which pins are SUPPOSED to be patched, and that gap has three shapes:
#
#   1  A `patches` field naming a directory that is not there. Rename patches/xnu-sys-xnu, or
#      typo the field, and hasPatches goes false and the pin is silently the RAW upstream fetch.
#      For that entry specifically that means the 51-file vendored delta vanishes and the
#      duct-tape build compiles against unmodified XNU.
#
#   2  An ORPHAN patch directory that no manifest entry maps to. It looks like maintained,
#      applied local delta and is dead weight that has never been applied to anything.
#
#   3  A BASENAME COLLISION, which is the one that has already bitten. Patches key on
#      baseNameOf, and two different pins here really are both called `xnu`:
#
#          vendor/pins/xnu                       darlinghq/darling-xnu, the GUEST syscall tree
#          vendor/pins/ciderd/xnu-sys/xnu        the same repo, the duct-tape KERNEL subset
#
#      patches/xnu holds NINE guest syscall patches that touch
#      darling/src/libsystem_kernel/emulation only. Without an explicit override the de-vendored
#      kernel subset would receive all nine, because it is spelled `xnu` too. cider-src.nix
#      documents this and the manifest does carry `patches: xnu-sys-xnu`. This asserts it rather
#      than trusting the comment, and it fires for any FUTURE collision as well: the moment a
#      second pin shares a basename with a patch directory and has no override, it is wrong.
#
# NONE OF THE THREE IS A BUILD ERROR. An unpatched or wrongly patched pin compiles, and says so
# much later as a mismatched signature or a missing member, an hour into an endpoint. This costs
# about ten milliseconds.
#
# DELIBERATELY NOT CHECKED: whether the patches still apply. That needs the fetched store paths
# and belongs to buck-pin-store-check.nu, which already diffs a per-pin store against the
# assembled tree. This is purely about the WIRING, which is the part with no owner.
#
# Exit 0 if every patch set reaches exactly its intended pin, 1 otherwise.
#
# PORTED FROM PYTHON, and the output is byte identical to the .py it replaces, checked by diff
# on both the real manifest and a mutated copy. Two nushell traps were paid for here and are
# worth knowing before porting the next one:
#
#   `get X` on a record without X is an ERROR, not null, so an optional manifest field has to be
#   read with `get -o` (or `get X?`). The python is `e.get("patches")`, which is null-by-default,
#   and a plain `get` turns every unpatched entry into a hard failure instead.
#
#   `ls <dir>` gives records and `ls <dir> | length` counts entries, but nushell's `ls` HIDES
#   DOTFILES, where python's os.listdir does not. Every count that has to agree with a python
#   original needs `ls -a`.

def main [
  --manifest: string = ""   # point at a mutated COPY to negative-control this without touching
                            # the working copy, which matters while a gate is running
  --patches: string = ""
] {
  let root = ($env.FILE_PWD | path dirname)
  let manifest = (if ($manifest | is-empty) { $root | path join "nix" "submodules.json" } else { $manifest })
  let patches = (if ($patches | is-empty) { $root | path join "patches" } else { $patches })

  let entries = (open --raw $manifest | from json)
  let dirs = (ls -a $patches | where type == dir | get name | each {|p| $p | path basename } | sort)

  # Mirror the nix exactly: explicit field first, basename otherwise.
  let rows = ($entries | each {|e|
    let base = ($e.path | path basename)
    { path: $e.path, base: $base, want: ($e | get -o patches), key: (($e | get -o patches) | default $base) }
  })
  let mapped = ($rows | group-by key)

  mut problems = []

  for r in $rows {
    if ($r.want != null) and (not ($r.want in $dirs)) {
      $problems = ($problems | append $"($r.path) asks for patches/($r.want), which does not exist, so it is silently the RAW upstream fetch with no local delta at all")
    }
  }

  for d in ($dirs | where {|d| not ($d in ($mapped | columns)) }) {
    let n = (ls -a ($patches | path join $d) | length)
    $problems = ($problems | append $"patches/($d) \(($n) patches\) is an ORPHAN: no manifest entry names it and no pin basename matches it, so it has never been applied to anything")
  }

  for g in ($rows | group-by base | transpose base rows | sort-by base) {
    let paths = ($g.rows | get path)
    if ($paths | length) < 2 or (not ($g.base in $dirs)) { continue }
    # A collision only matters where the shared basename also names a patch directory:
    # then every colliding entry without an override silently inherits those patches.
    let victims = ($g.rows | where {|r| $r.want == null } | get path)
    if ($victims | length) > 1 {
      $problems = ($problems | append $"basename ($g.base) is shared by ($paths | length) pins and patches/($g.base) exists, so these would all receive the SAME patch set with no override: ($victims | str join ', ')")
    }
  }

  print $"manifest entries ($entries | length), patch directories ($dirs | length)"
  for d in $dirs {
    let who = (if ($d in ($mapped | columns)) { $mapped | get $d | get path } else { [] })
    let n = (ls -a ($patches | path join $d) | length)
    let to = (if ($who | is-empty) { "NOTHING" } else { $who | str join ', ' })
    print $"  patches/($d): ($n) patches -> ($to)"
  }

  if ($problems | is-empty) {
    print "PASS: every patch set reaches exactly the pin it was written for"
    exit 0
  }

  print $"\n($problems | length) problems with the patch wiring:"
  for p in $problems { print $"  ($p)" }
  print "\nFAIL: patches key on a basename behind a pathExists, so all of these are SILENT. An unpatched or wrongly patched pin builds, and reports as a mismatched signature an hour into an endpoint."
  exit 1
}
