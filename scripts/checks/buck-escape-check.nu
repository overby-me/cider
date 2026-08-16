#!/usr/bin/env nu

# Which relative symlinks reach OUT of the tree they would be staged in?
#
# This exists because the same mistake was made twice in one night, in two different places,
# and neither the build nor the checks caught it until an hour of compiling had gone by.
#
#   #54 staged each source GROUP as its own store path, and a link from one group into another
#   dangles the moment the groups are staged apart.
#
#   #74 staged each PIN as its own store path, and a link from one pin into a SIBLING pin does
#   the same. The per-pin boundary was the one nothing had ever measured, because the check
#   that existed walked a boundary that held no symlinks at all.
#
# COUNT THE EFFECT, NOT JUST THE CAUSE. `pins` finds 21 escaping links across 12 pins, which
# sounds negligible. `resolve` on the same pin stores finds **143 dangling links of 3,861 across
# 15 pins**, because one escaping DIRECTORY link carries every file link under it: IOKitUser has
# 3 escapes and 117 dangling links, since darling/include/IOKit/*.h all point through
# darling/submodules/xnu. Seven times the blast radius of the escape count. Quote the resolve
# number when describing the damage.
#
# Usage:
#   buck-escape-check.nu pins --root /nix/store/...-cider-src   # per-pin store boundary
#   buck-escape-check.nu groups                                   # the #54 source-group boundary
#   buck-escape-check.nu resolve <dir> ...                        # does a tree AS STAGED work
#   buck-escape-check.nu path <dir> ...                           # arbitrary boundaries
#
# Find the assembled tree with:
#   ls -d /nix/store/*-cider-src | tail -1
#
# Exit 0 when every boundary is self contained, 1 when any is not, and 2 when it REFUSES
# because it walked no symlink at all. A usage error (no mode, an unknown mode, path with no
# directory) is 1, not 2: the python header claimed 2 and its code used sys.exit(<string>),
# which is 1. Measured against the code rather than copied from the sentence above it.
#
# VERIFIED on the tree it was written against, three ways:
#   `groups`                     -> 2,306 escapes across 15 groups, matching an independent walk
#   `pins --root <assembled>`    -> 21 across 12 pins, matching the same independent walk
#   `pins` with no --root        -> REFUSED with exit 2 rather than reporting a clean 0
#                                   (it no longer refuses, because the pins are materialized
#                                   in place now and it walks 685 links over 148 pins)
# The third is the one that matters, because reporting 0 there is the exact bug this file is
# about. `path src/darwin/basic-headers` was tried as a zero case and is NOT one: it reports 2, both
# into pins (AvailabilityVersions.h and architecture). Left recorded rather than swapped for a
# tidier example, because it is a real answer.
#
# =====================================================================================
# PORTED FROM PYTHON, AND IT IS THE FIRST CHECK IN THIS SWEEP THAT IS NOT BYTE COMPARABLE.
# That is a property of the python, not of the port, and it is stated here rather than left for
# someone to discover: the "first few" sample is printed in os.walk order, which is os.listdir
# order, which is READDIR order. Nushell `ls` and `glob` sort. Readdir order is stable for an
# unchanged directory but it is not a contract and it carries no meaning, so this emits the
# sample in SORTED order instead, which is reproducible.
#
# WHAT WAS VERIFIED INSTEAD, and it compares more than a byte diff of six lines would:
#   the counts line, identical
#   the per-boundary table, identical INCLUDING TIE ORDER (measured: this tree has ties at 1, 2
#     and 3, and python's insertion order happens to be alphabetical for all of them, which is
#     what sorting ties by name reproduces)
#   the SET of ALL findings, 2,270 of them for `groups`, identical
#   the exit codes, identical in every mode
#
# HOW TO WALK FOR SYMLINKS, measured against python 131ms rather than guessed:
#   stack walk, one `ls -la` per directory        18.8s over 1,841 directories
#   `ls -la` over globbed paths                   28.7s AND WRONG, it expands directory
#                                                 symlinks and returns 7,265 rows for darwin
#   glob, `path type` filter, bulk `ls -laD`      0.48s, correct
# `glob` DOES NOT DESCEND THROUGH SYMLINKED DIRECTORIES, which is exactly
# os.walk(followlinks=False): both find the same 2,930 links under darwin and linux. And
# `ls -laD` bulk stats a LIST of paths without expanding directory symlinks, which is what turns
# 2,930 target reads into one call. `resolve` cannot use any of this, because it MUST descend
# through symlinked directories, so it keeps the hand walk and the realpath cycle guard.

# EXACTLY the rule in src/linux/buildtools/graph-specs/src/srcset.rs, copied rather than approximated. An
# earlier version of this file guessed at it (frameworks three deep, everything else two) and
# reported 2,490 escapes across 8 groups where the real rule gives 2,306 across 15. Same
# conclusion, wrong numbers, and the numbers were quoted in a commit message.
const UNGROUPED = ["vendor/src/" "vendor/pins/" "vendor/rust/"]
const SKIP_NAMES = [".git" ".jj"]

def group-of [rel: string] {
  if ($UNGROUPED | any {|p| $rel | str starts-with $p }) { return null }
  let segs = ($rel | split row "/")
  if ($segs | length) >= 4 { $segs | first 3 | str join "/" } else { null }
}

# Relative to `tree`, the way os.path.relpath is. Everything this walks lives under the tree, so
# the prefix strip is the whole answer; the `..` form is kept for a destination that climbs OUT,
# which is precisely the case this check exists to find.
def rel-to [tree: string, p: string] {
  if $p == $tree { return "." }
  if ($p | str starts-with $"($tree)/") { return ($p | str substring (($tree | str length) + 1)..) }
  let a = ($tree | split row "/" | where {|x| $x != "" })
  let b = ($p | split row "/" | where {|x| $x != "" })
  mut i = 0
  while $i < ($a | length) and $i < ($b | length) and (($a | get $i) == ($b | get $i)) { $i = $i + 1 }
  let up = (0..<(($a | length) - $i) | each {|_| ".." })
  ($up | append ($b | skip $i) | str join "/")
}

# [{rel, target, dest, boundary}] for links leaving their boundary, plus the number walked, so
# the caller can refuse to pass on a boundary it never saw.
def escapes [tree: string, roots: list<string>, kind: string, arg: any] {
  let ex = ($SKIP_NAMES | each {|d| $"**/($d)/**" })
  let candidates = ($roots | each {|r|
      let base = ($tree | path join $r)
      if not (($base | path exists) and (($base | path type) == "dir")) { return [] }
      glob $"($base)/**/*" --exclude $ex
    } | flatten)
  let links = ($candidates | where {|p| ($p | path type) == "symlink" })
  if ($links | is-empty) { return { found: [], walked: 0 } }
  let rows = (ls -laD ...$links | select name target)
  let found = ($rows
    | where {|r| not ($r.target | str starts-with "/") }   # absolute, already root independent
    | each {|r|
        let rel = (rel-to $tree $r.name)
        # normpath STRIPS A TRAILING SLASH and `path expand --no-symlink` DOES NOT. Exactly one
        # of the 2,270 group findings has a target written with one, src/darwin/softlinking/
        # submodules/WTF -> ../../../vendor/pins/WTF/, and without this trim it lands as vendor/pins/WTF/
        # rather than vendor/pins/WTF. It changed no verdict here because both spellings fall outside
        # every group, but it would change a BOUNDARY the moment the trailing component mattered,
        # and it is the kind of difference a six-line sample would never have shown.
        let raw = (($r.name | path dirname) | path join $r.target | path expand --no-symlink)
        let norm = (if $raw == "/" { $raw } else { $raw | str trim --right --char "/" })
        let dest = (rel-to $tree $norm)
        { rel: $rel, target: $r.target, dest: $dest
          b: (boundary-of $kind $arg $rel), bd: (boundary-of $kind $arg $dest) }
      }
    | where {|f| $f.b != $f.bd }
    | select rel target dest b
    | sort-by rel)
  { found: $found, walked: ($links | length) }
}

def boundary-of [kind: string, arg: any, rel: string] {
  if $kind == "pins" {
    let cand = ($rel | split row "/" | first 3 | str join "/")
    if ($cand in $arg) { $cand } else { "<outside any pin>" }
  } else if $kind == "groups" {
    (group-of $rel) | default "<no group>"
  } else {
    let hit = ($arg | where {|r| ($rel == $r) or ($rel | str starts-with $"($r)/") })
    if ($hit | is-empty) { "<outside>" } else { $hit | first }
  }
}

def report [title: string, found: list<any>, walked: int, hint: string] {
  print $"($title): ($found | length) escaping symlink\(s\) of ($walked) walked($hint)"
  if $walked == 0 {
    print "  REFUSING: no symlink was walked at all, so this proved nothing."
    print "  The pins pin directories are empty mount points in the repo;"
    print "  point --root at an assembled cider-src instead."
    return 2
  }
  if ($found | is-empty) {
    print "  self contained, safe to stage standalone"
    return 0
  }
  # Counter.most_common: count descending, ties in insertion order. Measured on this tree, that
  # order is alphabetical for every tie, which is what sorting on (-n, name) reproduces.
  let table = ($found | group-by b | transpose b rows
    | each {|g| { b: $g.b, n: ($g.rows | length), neg: (0 - ($g.rows | length)) } }
    | sort-by neg b)
  for t in $table { print $"  (($t.n | into string) | fill -a right -w 6)  ($t.b)" }
  print "  first few:"
  for f in ($found | first 6) { print $"    ($f.rel)\n      -> ($f.target)   \(lands ($f.dest)\)" }
  print "  NOT self contained: staging any of these on its own dangles those links."
  1
}

def dump-if [want: bool, found: list<any>] {
  if $want {
    for f in $found { print $"($f.b)\t($f.rel)\t($f.target)\t($f.dest)" }
    exit (if ($found | is-empty) { 0 } else { 1 })
  }
}

def main [
  mode?: string
  ...rest: string
  --root: string = ""
  --dump                # print EVERY finding, one per line, rather than a six-line sample.
                        # Added by the nushell port and kept deliberately: the sample is printed
                        # in sorted order here and in readdir order in the python it replaces,
                        # so the only way to compare the two implementations is over the whole
                        # set. That comparison should stay possible after a future refactor too.
] {
  let repo = ($env.FILE_PWD | path dirname | path dirname)
  if ($mode | is-empty) {
    # EXIT 1, NOT 2, because python reaches these three through sys.exit(<string>), which prints
    # to stderr and exits ONE. The header says "2 on trouble" and the code disagrees with it; the
    # code is what callers see, so the code is what this matches. Measured, not read off the
    # docstring. The only deliberate difference is the TEXT: python prints its whole module
    # docstring here and nushell has no docstring object, so this prints a usage line.
    print -e "usage: buck-escape-check.nu {pins|groups|resolve|path} [--root DIR] [dirs...]"
    exit 1
  }
  let tree = (if ($root | is-empty) { $repo } else { $root })

  if $mode == "pins" {
    let manifest = (open --raw ($repo | path join "nix" "submodules.json") | from json)
    let pins = ($manifest | get path | where {|p| $p | str starts-with "vendor/pins/" })
    let r = (escapes $tree $pins "pins" $pins)
    let found = ($r.found | where {|f| $f.b != "<outside any pin>" })
    dump-if $dump $found
    exit (report "pins" $found $r.walked $" over ($pins | length) pins")
  }

  if $mode == "groups" {
    # A link whose OWN path is in no group travels individually as a shallow file, so it has no
    # boundary to escape from and is not a finding.
    let r = (escapes $tree ["src/darwin" "src" "src/linux"] "groups" null)
    let found = ($r.found | where {|f| $f.b != "<no group>" })
    dump-if $dump $found
    exit (report "groups" $found $r.walked "")
  }

  if $mode == "resolve" {
    # The OTHER half of the question. `groups` and `pins` ask whether a subtree could be staged
    # on its own; this asks whether a tree AS STAGED actually works, by following every symlink
    # in it. That is what a compiler does, and it is the check to run on a pin farm or a staged
    # group once the escapes have been rewritten.
    let roots = (if ($rest | is-empty) { ["."] } else { $rest })
    mut dangling = []
    mut walked = 0
    for r in $roots {
      let base = (if ($r | str starts-with "/") { $r } else { $tree | path join $r })
      # A HAND WALK THAT DESCENDS THROUGH SYMLINKED DIRECTORIES, keeping the LOGICAL path. glob
      # and os.walk both stop at a symlinked directory, and on a linkFarm every entry IS one, so
      # a walk that stops there looked at 147 links and reported a clean 0 for a farm holding
      # thousands. That is the third false pass of the night from the same mistake: a check has
      # to be pointed at the thing it claims to measure.
      #
      # Following blindly would loop on a cyclic symlink, and this tree has had one (#20,
      # JavaScriptCore), so the realpath set is the cycle guard.
      mut seen = []
      mut stack = [$base]
      while not ($stack | is-empty) {
        let d = ($stack | last)
        $stack = ($stack | drop 1)
        let real = (try { $d | path expand } catch { $d })
        if ($real in $seen) { continue }
        $seen = ($seen | append $real)
        let entries = (try { ls -la $d } catch { [] })
        for e in $entries {
          let n = ($e.name | path basename)
          if ($n in $SKIP_NAMES) { continue }
          let p = $e.name
          mut is_dir = ($e.type == "dir")
          if $e.type == "symlink" {
            $walked = $walked + 1
            if not ($p | path exists) {          # path exists FOLLOWS, --no-symlink would not
              $dangling = ($dangling | append { rel: (rel-to $base $p), target: $e.target })
              continue
            }
            # python asks os.path.isdir, which FOLLOWS, so a link to a directory is descended.
            $is_dir = ((try { $p | path expand | path type } catch { "" }) == "dir")
          }
          if $is_dir { $stack = ($stack | append $p) }
        }
      }
    }
    let dang = ($dangling | sort-by rel)
    print $"resolve ($roots | str join ' '): ($dang | length) dangling of ($walked) symlinks"
    if $walked == 0 {
      print "  REFUSING: no symlink was walked, so this proved nothing"
      exit 2
    }
    if ($dang | is-empty) {
      print "  every symlink resolves where it is"
      exit 0
    }
    for d in ($dang | first 10) { print $"    ($d.rel)  ->  ($d.target)" }
    if ($dang | length) > 10 { print $"    ... and (($dang | length) - 10) more" }
    exit 1
  }

  if $mode == "path" {
    if ($rest | is-empty) {
      print -e "path mode needs at least one directory"
      exit 1
    }
    let roots = ($rest | each {|r| $r | str trim --right --char "/" })
    let r = (escapes $tree $roots "path" $roots)
    let found = ($r.found | where {|f| $f.b != "<outside>" })
    dump-if $dump $found
    exit (report ($roots | str join " ") $found $r.walked "")
  }

  print -e $"unknown mode '($mode)'"
  exit 1
}
