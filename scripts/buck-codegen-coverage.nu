#!/usr/bin/env nu

# IS EVERY FILE THE REFERENCE GENERATES ACCOUNTED FOR BY THE PORT?
#
# buck-coverage.nu counts LINK edges. The reference also has thousands of CUSTOM_COMMAND
# edges -- mig, bison, flex, configure_file, script generators -- and the worry recorded
# against them was that a generated file which nothing compiles could be silently absent,
# with no check anywhere that would notice.
#
# This tests that worry rather than restating it. Every generated output is classified:
#
#   compiled   an input to a compile or link edge. A missing one FAILS THE BUILD, and
#              `buck2 build //...` is green, so these are covered -- by implication, but
#              the implication is sound.
#   installed  named by an install entry. gen-install-from-manifests.py resolves every one
#              of those to a target and reports UNMAPPED otherwise, currently 0.
#   header     a .h/.hpp/.def/.defs/.modulemap. Reached by #include rather than by name, so
#              it has no edge pointing at it -- but a missing one fails the compile of
#              whatever includes it, and again the build is green.
#   neither    the actual risk set: generated, not built against, not installed. These are
#              the only ones where absence would be silent.
#
# Usage:  scripts/buck-codegen-coverage.nu [--list]
#
# PORTED FROM PYTHON (#98), byte identical in both modes. IT TOOK THE TWO PIECES OF GENERATOR
# IT IMPORTED WITH IT, the way buck-coverage.nu took its 180 lines of the reference library:
# the python loaded gen-buck-from-ninja for one PATH constant and gen-install-from-manifests
# for read_entries and build_rel, and both of those are frozen-reference generators that #97
# archives rather than ports. What is carried here is the ENTRY regex, the FILES/REGEX split
# and the /build/build/ prefix strip, which is all a check needs, and it is verified by the
# count: 1,456 installed build paths, the same number the python reaches through read_entries.
#
# THREE EXTERNAL PASSES ARE KEPT ON PURPOSE, and they are why this is seconds:
#   * grep '^build ' over the 131 MB build.ninja. 362,663 lines in, 40,014 out, and nushell
#     never sees the other 322,649.
#   * grep -Fx / -Fxv for set membership. Nushell has NO hash set, and the consumed set has
#     53,389 entries: building it with `reduce ... upsert` copies the accumulator on every
#     insert, which is the O(n^2) that cost buck-include-closure-check 127 s of a 163 s run.
#   * a plain sort for the unique-and-ordered generated list.
#
# THE TOKEN SPLIT IS A PLAIN SPACE, not `split row --regex '\s+'`, and that alone is 6.5 of
# the 10 seconds the parse used to take: the regex form recompiles per call, 40,014 times.
# python writes .split(), which splits on any whitespace -- checked rather than assumed to be
# the same thing here: ZERO of the 40,014 build lines contain a tab, and a run of spaces
# collapses either way because the empty fields are filtered out.

const HEADER_SUFFIXES = [".h" ".hpp" ".hh" ".inc" ".def" ".defs" ".modulemap" ".pch"]

# cmake's own targets, emitted as CUSTOM_COMMAND but not files any build produces:
# edit_cache, rebuild_cache, install, and CTest's Nightly/Continuous/Experimental set.
# 3345 of the 4035 "generated outputs" are these, and counting them as a coverage gap is
# what made the first version of this number meaningless.
const CMAKE_TARGETS = ["CMakeFiles/uninstall" "CMakeFiles/xcproj_symlinks"]

# The reference graph. gen-buck-from-ninja.py holds the same constant, and this check used to
# import that whole file to read it.
const GRAPH_LINK = "result-graph-ref"

# cmake writes the build tree under /build/build in the reference derivation; a CUSTOM_COMMAND
# names its output relative to that directory and every other edge names it absolutely.
const BUILD_ROOT = "/build/build/"

def is-cmake-bookkeeping [path: string] {
  if ($path | str ends-with ".util") or ($path in $CMAKE_TARGETS) { return true }
  let base = $"($path | path dirname | path basename)/($path | path basename)"
  ($base | str starts-with "CMakeFiles/") and (["Nightly" "Continuous" "Experimental"]
    | any {|p| ($path | path basename) | str starts-with $p })
}

# The two sets the ninja graph answers for: what a CUSTOM_COMMAND produces, and what any real
# edge reads.
#
# PARSED HERE rather than through the generator read_edges, which keeps ORDER-ONLY deps in its
# input list. That distinction is the whole measurement: cmake gives every target a
# `cmake_object_order_depends_target_X` phony that lists EVERY generated file the target might
# use, and those arrive after `||`. Counting them as consumption made all 4035 outputs look
# consumed and the metric say nothing at all.
#
# Ninja's grammar is `build outs | implicit_outs: rule ins | implicit_deps || order_only`.
# Explicit and implicit inputs are things the command actually reads. Order-only is sequencing,
# and a file that appears ONLY there is not evidence of use.
#
# NOT `append` INSIDE THE LOOP, and that is not a style preference: appending each line's token
# list to an accumulator over 40,014 lines copies the accumulator every time, and this check
# took 103 SECONDS that way against 0.18 s for the python. It is the same O(n^2) shape as the
# `reduce ... upsert` record that cost buck-include-closure-check 127 s of a 163 s run, in a
# different disguise. `each` builds one list of per-line results and `flatten` joins them in a
# single pass.
def read-graph [graph: string] {
  let cut = ($BUILD_ROOT | str length)
  let lines = (^grep "^build " $graph | lines)
  let rows = ($lines | each {|l|
    let body = ($l | str substring 6..)
    let ix = ($body | str index-of ": ")
    if $ix < 0 { null } else {
      let head = ($body | str substring 0..<$ix)
      # A RANGE WITH A COMPUTED START needs the start in a variable: an inline parenthesised
      # expression before `..` parses as an incomplete math expression.
      let after = ($ix + 2)
      let rest = ($body | str substring $after..)
      let sp = ($rest | str index-of " ")
      let rule = (if $sp < 0 { $rest } else { $rest | str substring 0..<$sp })
      let dstart = ($sp + 1)
      let deps = (if $sp < 0 { "" } else { $rest | str substring $dstart.. })
      {
        gen: (if $rule == "CUSTOM_COMMAND" {
          $head | split row " | " | first | split row " " | where {|w| $w != "" }
        } else { [] }),
        con: (if $rule != "phony" {
          $deps | split row " || " | first | split row " "
            | where {|w| $w != "" and $w != "|" }
            | each {|i| if ($i | str starts-with $BUILD_ROOT) {
                $i | str substring $cut..
              } else { $i } }
        } else { [] }),
      }
    }
  } | compact)
  { generated: ($rows | get gen | flatten | uniq | sort), consumed: ($rows | get con | flatten) }
}

# Every build-tree path an install entry names, relative to the build directory.
#
# THE ENTRY REGEX IS THE GENERATOR ONE, character for character, and the two details in it are
# both load bearing: \s+ after FILES because cmake puts a single file on the same line and a
# list on the lines below, and the RENAME group because an entry that carries one does not
# match without it. THE FILE LIST ENDS AT THE FIRST " REGEX ", which is where the EXCLUDE
# patterns start -- they are quoted strings too, so a naive scan reads /Makefile$ as a file.
#
# NOT A LOOSE SCAN FOR /build/build/ STRINGS, which was tried and is wrong: cmake_install.cmake
# also names its own manifest, its sibling cmake_install.cmake files and the per-target
# install-cxx-module-bmi-noconfig.cmake under that prefix, and the loose rule collected 4,238
# paths where the entries hold 1,456.
def read-installed [root: string] {
  let ENTRY = '(?s)file\(INSTALL DESTINATION "([^"]+)"\s+TYPE (\w+)((?:\s+\w+)*?)(?:\s+RENAME "([^"]+)")?\s+FILES?\s+(.*?)\)\n'
  let STR = '"((?:[^"\\]|\\.)*)"'
  let cut = ($BUILD_ROOT | str length)
  let manifests = (^find $root -name cmake_install.cmake | lines)
  if ($manifests | is-empty) {
    print -e $"no cmake_install.cmake under ($root) -- is the graph output still present?"
    exit 2
  }
  mut out = []
  for f in $manifests {
    for e in ((open --raw $f | decode utf-8) | parse --regex $ENTRY) {
      let head = ($e.capture4 | split row " REGEX " | first)
      for s in ($head | parse --regex $STR | get capture0) {
        if ($s | str starts-with $BUILD_ROOT) {
          $out = ($out | append ($s | str substring $cut..))
        }
      }
    }
  }
  $out | uniq
}

# `lines that ARE in set` and `lines that are NOT`, in the order the input has them. One
# external pass each, because the sets run to tens of thousands of entries.
def split-by-set [items: list<string>, set: list<string>] {
  if ($items | is-empty) { return { hit: [], miss: [] } }
  if ($set | is-empty) { return { hit: [], miss: $items } }
  let sf = (mktemp -t --suffix .txt)
  let itf = (mktemp -t --suffix .txt)
  $set | str join "\n" | save -f $sf
  $items | str join "\n" | save -f $itf
  let hit = (^bash -c $"grep -Fx -f ($sf) ($itf) || true" | complete)
  let miss = (^bash -c $"grep -Fxv -f ($sf) ($itf) || true" | complete)
  rm -f $sf $itf
  { hit: ($hit.stdout | lines), miss: ($miss.stdout | lines) }
}

def main [--list] {
  cd ($env.CURRENT_FILE | path dirname | path join "..")
  let root = ($GRAPH_LINK | path expand)
  let g = (read-graph ($root | path join "build.ninja"))
  let installed = (read-installed $root)

  let a = (split-by-set $g.generated $g.consumed)
  let b = (split-by-set $a.miss $installed)
  let headers = ($b.miss | where {|n| $HEADER_SUFFIXES | any {|s| $n | str ends-with $s } })
  let rest = ($b.miss | where {|n| not ($HEADER_SUFFIXES | any {|s| $n | str ends-with $s }) })
  let cmake = ($rest | where {|n| is-cmake-bookkeeping $n })
  let unconsumed = ($rest | where {|n| not (is-cmake-bookkeeping $n) })

  print $"generated outputs: ($g.generated | length)"
  for row in [["k" "v"]; ["consumed" ($a.hit | length)] ["installed" ($b.hit | length)]
              ["header" ($headers | length)] ["cmake" ($cmake | length)]
              ["unconsumed" ($unconsumed | length)]] {
    # THE SPACE BETWEEN THE TWO FIELDS IS PART OF THE FORMAT: python writes
    # f"  {k:12} {n:5d}", so the line is 2 + 12 + 1 + 5 wide. Dropping it made every count
    # line one column narrow, which the diff against the python output caught at once.
    print $"  ($row.k | fill --alignment l --width 12) ($row.v | into string | fill --alignment r --width 5)"
  }
  if $list {
    for n in $unconsumed { print $"    ? ($n)" }
  }
  exit 0
}
