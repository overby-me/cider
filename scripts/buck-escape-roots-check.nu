#!/usr/bin/env nu

# Every escape root must resolve to a real tree, because a missing one is dropped IN SILENCE.
#
# WHY THIS EXISTS, and it is one specific day of lost work. #83 de-vendored
# pins/ciderd/xnu-sys/xnu: the tree left the repo and became a pin. escapeSrc in
# nix/lib/ciderBuck2Lower.nix read every escape root out of srcRaw behind a pathExists guard,
# so the guard simply went false and the carry stopped happening. No warning, no eval error,
# nothing in any diff. The security pin ships
#
#     darling/submodules/xnu -> ../../../darlingserver/duct-tape/xnu
#
# a link that keeps its upstream name on purpose, and with the carry gone it dangled, so
# security_codesigning_obj died on "security/mac.h file not found" AN HOUR into the gate.
#
# d51dfbc7 fixed that case by falling back to the PIN STORE. It did not close the class: a root
# that is in neither the repo nor the manifest still evaluates to null and is still skipped
# without a word. This check is what makes that loud, and it costs no build and no nix.
#
# WHAT MAKES THE CLASS CHECKABLE STATICALLY. escapeRoots is
#
#     ["darwin/Developer/Platforms"] ++ map (r: escapeNarrow.${r} or r) nonPinExternal
#
# and nonPinExternal is a readDir of pins minus the pin names, so every element of it
# exists by construction. The only entries that can point somewhere else are the literal SDK
# root and the VALUES of escapeNarrow, which is exactly how xnu-sys/xnu got out of the repo
# while its key stayed in. So the whole class is a handful of paths and needs no evaluation.
#
# THE HONEST TEST FOR "IS IT IN THE REPO" IS jj file list, NOT a path existence test.
# scripts/buck-src.nu materializes pins at their manifest paths, so the de-vendored tree is
# sitting on disk at pins/ciderd/xnu-sys/xnu right now with 2,077 files in it. `path exists`
# says yes and means nothing: srcRaw under a flake build is a store copy of TRACKED files, which
# is why the guard went false in the first place. Ask jj, which reports 0 tracked files there.
#
# WHAT THIS COVERS AND WHAT IT DOES NOT, because the scope is the part that gets over-trusted.
# There are eight pathExists guards in the lowering and two in cider-src.nix, and they are not
# equally dangerous:
#
#   ciderBuck2Lower :353  escapeSrc               CHECKED here, both resolvability and fallback
#   ciderBuck2Lower :1000 sdkGroup                covered TRANSITIVELY: sdkGroup is
#                                                 darwin/Developer/Platforms, the same literal
#                                                 root checked below, so it cannot go false
#                                                 while this passes
#   ciderBuck2Lower :1004 per-label group filter  elements come from the same readDir, so they
#                                                 exist by construction. The one exception is
#                                                 deliberate: groupSplit.shared still names
#                                                 pins/ciderd/xnu-sys/xnu, which is a pin
#                                                 now, so this guard drops it and the PIN route
#                                                 supplies it instead. That dead table entry is a
#                                                 known deferred cleanup, not a defect.
#   ciderBuck2Lower :973  pins readDir            NOT checked. If that directory vanished the
#                                                 root list would quietly shrink to the SDK and
#                                                 this would still pass. The counts printed below
#                                                 are the tell, and the scenario needs the whole
#                                                 pin tree to disappear, which is not quiet.
#   ciderBuck2Lower :1111 :1130  buck-rust, buck-src   not checked, and they do not need it:
#                                                 those stage every pin, so losing them fails
#                                                 immediately and everywhere rather than silently.
#   cider-src :184 :211   patch application       covered by buck-pin-patches-check.nu.
#
# Exit 0 if every escape root resolves, 1 otherwise.
#
# PORTED FROM PYTHON, byte identical on the real tree and under three planted faults. ONE
# DELIBERATE BEHAVIOUR CHANGE, measured rather than assumed: the python did
# `jj file list` output `.split()`, which splits on ANY whitespace, and SIX tracked paths here
# contain spaces. Four of them sit under darwin/Developer/Platforms, so python was testing
# fragments like `.../Specifications/Core` against the roots. It happened to give the right
# answer because a fragment still starts with the root, which is luck rather than design. This
# splits on lines. Verified to produce the same output on the real tree; it is strictly more
# correct, and a path with a space under a PIN would have made the python wrong.

const PIN_ROOT = "pins"

def tracked-files [repo: string] {
  let out = (do -i { ^jj -R $repo file list } | complete)
  if $out.exit_code != 0 {
    print $"FAIL: jj file list exited ($out.exit_code): ($out.stderr | str trim)"
    exit 2
  }
  $out.stdout | lines | where {|l| ($l | str trim | is-not-empty) }
}

# Parse the escapeNarrow table. It is a flat attrset of string to string.
def escape-narrow [lowering: string] {
  let text = (open --raw $lowering | decode utf-8)
  let m = ($text | parse --regex '(?ms)^  escapeNarrow = \{(?<body>.*?)^  \};')
  if ($m | is-empty) {
    print $"FAIL: no escapeNarrow table found in ($lowering). If it was renamed or reshaped, this check is reading the wrong thing and would PASS blindly."
    exit 2
  }
  ($m | first | get body) | parse --regex '"(?<k>[^"]+)"\s*=\s*"(?<v>[^"]+)"\s*;'
}

# The hardcoded head of escapeRoots, currently just the SDK. Parsed rather than hardcoded here
# so that adding one to the lowering does not silently escape this check.
def literal-roots [lowering: string] {
  let text = (open --raw $lowering | decode utf-8)
  let m = ($text | parse --regex '(?ms)^  escapeRoots =\s*\n?\s*\[(?<body>.*?)\]')
  if ($m | is-empty) {
    print $"FAIL: no escapeRoots binding found in ($lowering)"
    exit 2
  }
  ($m | first | get body) | parse --regex '"(?<v>[^"]+)"' | get v
}

# ASSERT THE FIX IS STILL THERE, because the resolvability check above would NOT have caught the
# bug that prompted all this.
#
# Worth being exact about, since a check credited with catching something it cannot is worse than
# no check. At the moment the build broke, pins/ciderd/xnu-sys/xnu was already a manifest entry
# WITH a hash, so the loop would have printed PIN STORE and exited 0. The defect was not an
# unresolvable root; it was that escapeSrc never consulted the pin, reading only srcRaw behind a
# pathExists guard.
#
# So the thing to assert is the shape of the code: escapeSrc must still have a route from a root
# to its pin store. Revert d51dfbc7, refactor it away, or rename pinPaths without following
# through here, and this fires.
def fallback-present [lowering: string] {
  let text = (open --raw $lowering | decode utf-8)
  let m = ($text | parse --regex '(?ms)^  escapeSrc = (?<body>.*?)^  pinsTree =')
  if ($m | is-empty) {
    print "FAIL: no escapeSrc binding found; this check is reading the wrong thing"
    exit 2
  }
  if (($m | first | get body) | str contains "pinPaths") { return true }
  print "FAIL: escapeSrc no longer reads pinPaths, so an escape root that lives in a PIN rather than the repo contributes NOTHING and is skipped in silence. That is the exact regression d51dfbc7 fixed: the security pin link to duct-tape/xnu dangles and security_codesigning_obj dies on a missing security/mac.h an hour into the build. Restore the fallback from ciderSrc.pinPaths."
  false
}

def main [
  --lowering: string = ""   # lowering to read the tables from; point it at a mutated COPY to
                            # negative-control this check without touching the working copy
] {
  let repo = ($env.FILE_PWD | path dirname)
  let low = (if ($lowering | is-empty) { $repo | path join "nix" "lib" "ciderBuck2Lower.nix" } else { $lowering })

  let manifest = (open --raw ($repo | path join "nix" "submodules.json") | from json)
  # pinPaths is keyed by manifest path and only entries with a hash get a store, which is what
  # the `or null` fallback in escapeSrc actually looks up.
  let pin_stores = ($manifest | where {|e| ($e | get -o hash) != null } | get path)
  let pin_names = ($manifest | where {|e| $e.path | str starts-with "pins/" } | get path | each {|p| $p | path basename })

  # THE INDEX IS DERIVED, because it is a path DEPTH and #87 stage 2 changed it. This read
  # component 2, the position of <name> under the old src/external/<name>. A textual sweep can
  # rewrite the string src/external to pins and CANNOT rewrite an array index, so the check went
  # on slicing at component 2 and reported the CHILDREN of the vendored trees as ten escape roots
  # resolving to nothing. It was right to fail: the population was wrong, not the tree.
  let depth = ($PIN_ROOT | split row "/" | length)
  let tracked = (tracked-files $repo)
  let dirs = ($tracked
    | where {|f| ($f | str starts-with $"($PIN_ROOT)/") and (($f | split row "/" | length) - 1) > $depth }
    | each {|f| $f | split row "/" | get $depth } | uniq)
  let non_pin_external = ($dirs | where {|d| not ($d in $pin_names) } | each {|d| $"($PIN_ROOT)/($d)" } | sort)

  let narrow = (escape-narrow $low)
  let narrow_vals = ($narrow | get v)
  let roots = ((literal-roots $low) | append (
    $non_pin_external | each {|r|
      let hit = ($narrow | where k == $r)
      if ($hit | is-empty) { $r } else { $hit | first | get v }
    }))

  print $"escapeNarrow entries: ($narrow | length); nonPinExternal: ($non_pin_external | length); escape roots: ($roots | length)"

  mut bad = []
  for r in $roots {
    let in_repo = ($tracked | any {|f| ($f == $r) or ($f | str starts-with $"($r)/") })
    let in_pin = ($r in $pin_stores)
    let how = (if $in_repo { "repo" } else if $in_pin { "PIN STORE" } else { "NEITHER" })
    if $how == "NEITHER" { $bad = ($bad | append $r) }
    let narrowed = (if ($r in $narrow_vals) { " \(narrowed\)" } else { "" })
    print $"  ($r)($narrowed): ($how)"
  }

  let ok_fallback = (fallback-present $low)

  if ($bad | is-empty) and $ok_fallback {
    print "PASS: every escape root resolves and the pin fallback is intact, so nothing is being dropped in silence"
    exit 0
  }
  if ($bad | is-empty) { exit 1 }

  print $"\n($bad | length) escape roots resolve to NOTHING and escapeSrc will skip them without a word:"
  for r in $bad { print $"  ($r)" }
  print "\nFAIL: an escape destination that carries nothing leaves the pin symlinks that point into it DANGLING, and the build only says so an hour later as a missing header. Either track the tree, or give it a manifest entry with a hash."
  exit 1
}
