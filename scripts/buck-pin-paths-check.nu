#!/usr/bin/env nu

# Every path we record INTO an upstream pin must exist on disk.
#
# vendor/src/<pin> is an upstream darlinghq repo, and 43 of those pins carry their
# own darling/ subdirectory (plus cfnetwork/darling-framework and the darling-dmg
# pin itself). We name paths inside them from four places, all of them generated
# or hand-maintained tables of plain strings:
#
#     buck/generated/exports_<pin>.bzl    {export target: pin-relative path}
#     buck/generated/sdk_headers.bzl      {SDK header: vendor/src-relative path}
#     buck/generated/sdk_framework*.bzl   same, per framework
#     nix/submodules.json                 the pin fetch manifest
#
# Strings are not checked by anything until something stages them, so a bad one
# survives evaluation, survives every compile, and fails only when a pin is
# actually fetched or a header actually staged. The Cider rename wrote 1,700 of
# them at once: it rewrote our references to the pins' darling/ directories while
# leaving the pins themselves untouched, and the first thing that noticed was the
# overnight endpoint failing to patch xnu.
#
# NEGATIVE CONTROL, measured rather than assumed: run against the tree as the
# rename left it, this reported 1,477 missing exports srcs, 35 missing framework
# paths and 1 unresolvable submodule path. It is not a check that cannot fail.
#
# Exit 0 if every path resolves, 1 otherwise, listing what does not.
#
# PORTED FROM PYTHON, byte identical on the real tree and under four planted faults, one per
# source. THE EXISTENCE TEST IS THE THING TO GET RIGHT: python uses os.path.lexists, so the
# nushell is `path exists --no-symlink`. Using the plain form would follow the 2,002 dangling
# links in darwin/Developer, which are dangling BY DESIGN here and resolve in the build, and
# report a couple of thousand false failures.

const PIN_ROOT = "vendor/src"

# {"key": "value"} on one line is what every one of these tables emits.
const PAIR = '":\s*"(?<v>[^"]+)"'
const KEYVAL = '"(?<k>[^"]+)":\s*"(?<v>[^"]+)"'

# Each sdk map is rooted somewhere different; the file name is the only thing
# that says where, so the root belongs beside the name rather than guessed.
const SDK_MAPS = [
  ["sdk_headers.bzl" "vendor/src"]
  ["sdk_framework_buck_src.bzl" "vendor/src"]
  ["sdk_framework_private_buck_src.bzl" "vendor/src"]
  ["sdk_framework_darwin_Developer.bzl" "darwin/Developer"]
]

const SDK_NAMESPACES = ["cider" "darling"]

# exports_<pin>.bzl values are relative to the pin, exports_buck_src.bzl
# to vendor/src itself: that file is the //vendor/src root package, not a pin.
def exports-srcs [gen: string] {
  ls -a $gen | where type == file | get name | each {|p| $p | path basename } | sort
    | each {|name|
        let m = ($name | parse --regex '^exports_(?<pin>.+)\.bzl$')
        if ($m | is-empty) { return [] }
        let pin = ($m | first | get pin)
        let base = (if $pin == "buck_src" { $PIN_ROOT } else { $PIN_ROOT + "/" + $pin })
        (open --raw ($gen | path join $name) | decode utf-8) | parse --regex $PAIR
          | each {|r| { origin: $"buck/generated/($name)", path: $"($base)/($r.v)" } }
      } | flatten
}

# The sdk maps hold paths and //buck2 labels side by side; only the paths
# are ours to resolve, and each file is rooted at its own tree.
def sdk-paths [gen: string] {
  $SDK_MAPS | each {|pair|
    let name = ($pair | first)
    let root = ($pair | last)
    let p = ($gen | path join $name)
    if not ($p | path exists) { return [] }
    (open --raw $p | decode utf-8) | parse --regex $PAIR
      | where {|r| not (($r.v | str starts-with "//") or ($r.v | str starts-with ":")) }
      | each {|r| { origin: $"buck/generated/($name)", path: $"($root)/($r.v)" } }
  } | flatten
}

# The sdk maps have TWO sides, and only one of them was ever checked here.
#
# An entry is {staged include path: source}. The VALUE is a path or label into a pin, which the
# other sources above resolve. The KEY is the path the header is staged AT, and UPSTREAM code
# names that too: the xnu pin's own os/tsd.h does
#
#     #include <darling/emulation/linux_premigration/linux-syscalls/linux.h>
#
# The Cider sweep rewrote 302 of those keys to cider/emulation, so the headers were staged where
# nothing looks for them, and 39 compiles failed an HOUR into the endpoint with the include not
# found. Restoring the values, which this file already did, left the keys wrong.
#
# CHECKED BY CONSISTENCY, not by a hardcoded name, because cider/ IS a legitimate SDK namespace
# elsewhere: usr/include/darling/mldr/elfcalls/dthreads.h is ours and resolves. The rule is that
# the key and the value must agree about whose namespace it is. If the key begins cider/ while
# the value names a darling_ target inside a pin, one of them is wrong, and it is the key.
def sdk-key-namespace [gen: string] {
  $SDK_MAPS | each {|pair|
    let name = ($pair | first)
    let p = ($gen | path join $name)
    if not ($p | path exists) { return [] }
    (open --raw $p | decode utf-8) | parse --regex $KEYVAL
      | where {|r| ($r.k | str starts-with "cider/") and ($r.v | str contains "darling") }
      | each {|r| { origin: $"buck/generated/($name)", path: $"KEY ($r.k) but VALUE ($r.v)" } }
  } | flatten
}

# And the THIRD side: what our own code asks for must be what gets staged.
#
# sdk_headers.bzl stages a header AT a key, and code includes it BY that key. The Cider sweep
# rewrote both, so restoring only the keys left our own sources asking for the other name and
# run 9 died at 2,829 builders on
#
#     FSEventsImpl.m:26 fatal error:
#       'cider/emulation/linux_premigration/ext/sys/inotify.h' file not found
#
# darling/ is the right namespace and that is measured, not preferred: the pins include it 1,839
# times and we include it 16.
#
# Only the two namespaces staged through this map are checked, so an include that resolves
# through some other -I root is not dragged in. Negative control: with the sweep as it stood, all
# 16 were missing; a correct tree has none.
def first-party-includes [repo: string, gen: string] {
  let out = (do -i { ^jj -R $repo file list } | complete)
  let files = ($out.stdout | lines | where {|l| $l | is-not-empty })
  let keys = ((open --raw ($gen | path join "sdk_headers.bzl") | decode utf-8)
    | parse --regex '(?m)^\s*"(?<k>[^"]+)":' | get k)
  let inc = ('#\s*include\s*<(?<p>(?:' + ($SDK_NAMESPACES | str join "|") + ')/[^>]+)>')
  $files
    | where {|rel| ($rel | str ends-with ".c") or ($rel | str ends-with ".h") or ($rel | str ends-with ".m") or ($rel | str ends-with ".mm") or ($rel | str ends-with ".cpp") }
    | where {|rel| not (($rel | str starts-with "vendor/src/") or ($rel | str starts-with "patches/")) }
    | each {|rel|
        let p = ($repo | path join $rel)
        let text = (try { open --raw $p | decode utf-8 } catch { null })
        if $text == null { return [] }
        # PREFILTER, and it is 25,061 files here. The regex only ever matches text that already
        # contains one of the namespaces followed by a slash, so testing that first is a strict
        # superset and cannot change the answer. Without it this runs `parse --regex` 25,061
        # times, and the per-invocation cost, not the regex, is what makes that slow: reading
        # every one of those files takes 733ms, and the parses take another twelve seconds.
        if not ($SDK_NAMESPACES | any {|ns| $text | str contains $"($ns)/" }) { return [] }
        $text | parse --regex $inc | where {|m| not ($m.p in $keys) }
          | each {|m| { origin: $rel, path: $"includes <($m.p)>, which sdk_headers.bzl does not stage" } }
      } | flatten
}

# The manifest keys a pin by its pins path; the last component is
# the vendor/src directory the pin is checked out as.
def submodule-paths [repo: string] {
  (open --raw ($repo | path join "nix" "submodules.json") | from json)
    | each {|e| { origin: "nix/submodules.json", path: $"($PIN_ROOT)/($e.path | split row '/' | last)" } }
}

def main [] {
  let repo = ($env.FILE_PWD | path dirname)
  let gen = ($repo | path join "buck" "generated")

  mut missing = []
  # This one yields FINDINGS rather than candidate paths: the key and the value
  # disagree about whose namespace the header lives in, and there is nothing to stat.
  let ns = (sdk-key-namespace $gen)
  print $"(('sdk_key_namespace' | fill -a left -w 18)) (($ns | length) | into string | fill -a right -w 5) disagreements"
  $missing = ($missing | append $ns)
  let fp = (first-party-includes $repo $gen)
  print $"(('first_party_incl' | fill -a left -w 18)) (($fp | length) | into string | fill -a right -w 5) unstaged includes"
  $missing = ($missing | append $fp)

  mut checked = 0
  for src in [
    { name: "exports_srcs", rows: (exports-srcs $gen) }
    { name: "sdk_paths", rows: (sdk-paths $gen) }
    { name: "submodule_paths", rows: (submodule-paths $repo) }
  ] {
    # lexists, not exists: darwin/Developer is a tree of symlinks written for the STAGED layout,
    # so 2,002 of its 2,636 links dangle in a checkout and resolve in the build.
    let bad = ($src.rows | where {|r| not (($repo | path join $r.path) | path exists --no-symlink) })
    print $"(($src.name | fill -a left -w 18)) (($src.rows | length) | into string | fill -a right -w 5) paths, ($bad | length) missing"
    $checked = $checked + ($src.rows | length)
    $missing = ($missing | append $bad)
  }

  if not ($missing | is-empty) {
    print $"\n($missing | length) of ($checked) pin paths do not exist:"
    for m in ($missing | first 40) { print $"  ($m.origin): ($m.path)" }
    if ($missing | length) > 40 { print $"  ... and (($missing | length) - 40) more" }
    print "\nFAIL: a reference names a directory inside a pin that is not there."
    print "Pins are upstream and keep their darling/ subdirectories; only our own"
    print "code is Cider. Check any recent rename against vendor/src/<pin>/."
    exit 1
  }

  print $"\nPASS: all ($checked) pin paths resolve, and every sdk key agrees with its value"
  exit 0
}
