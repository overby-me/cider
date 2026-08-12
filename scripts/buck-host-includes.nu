#!/usr/bin/env nu

# DOES EVERY TARGET THAT NEEDS A HOST HEADER ACTUALLY ASK FOR ONE?
#
# The port compiles against libraries that live outside the build graph: X11, freetype,
# fontconfig, cairo, ffmpeg, pulseaudio and the rest. The reference build.ninja names those
# include directories explicitly, with an absolute -I per compile. The port did not, for the
# whole of the campaign, and nothing noticed -- because buck/toolchains/BUCK defaults
# darwin_cc to the bare name "clang", which inside the dev shell is the WRAPPED clang and
# injects the same directories through NIX_CFLAGS_COMPILE.
#
# So AppKit, Onyx2D, CoreGraphics, CoreText, iokitd, hdiutil, the X11 backends and the
# CoreAudio cone were compiling against headers nothing in the build graph asked for. It only
# surfaced in the Nix graph derivation, which pins clang-unwrapped and unsets NIX_CFLAGS on
# purpose, where iokitd stopped at "X11/Xlib.h file not found".
#
# That is the class of bug this checks for, statically and in a second, rather than waiting an
# hour for a Nix build to fail. For every reference compile carrying an absolute host -I, the
# port's target must depend on //linux/native:host_headers, which exports -I for each entry of
# cider.host_include_dirs.
#
# Usage:
#   scripts/buck-host-includes.nu           # report, exit 1 if any target is missing it
#   scripts/buck-host-includes.nu --list    # also list the reference's host include dirs
#
# PORTED FROM PYTHON (#98), byte identical in both modes. IT READS THE FROZEN REFERENCE AND IS
# STILL A LIVE CHECK, which is the distinction #97 turns on: the input cannot change, but the
# thing it judges -- what the port declares -- changes with every edit.
#
# TWO EXTERNAL REDUCTIONS, both for the same reason as buck-codegen-coverage.nu: the reference
# build.ninja is 131 MB and 362,663 lines, which nushell must not walk line by line.
#   * ONE grep for the two line kinds that matter, in file order, so the association between a
#     build line and the FLAGS/INCLUDES lines under it survives without line numbers.
#   * THE STORE -I FILTER IS A SUPERSET, deliberately: grep keeps every FLAGS/INCLUDES line
#     carrying any -I/nix/store, and the exact rule below then decides. A line with a host -I
#     always carries one, so nothing can be lost by the reduction, and the rule that actually
#     classifies stays in one place. 52,942 such lines become 26,198, and 652 survive the rule.
#
# NO REGEX IN THE HOT LOOP. Splitting on the literal "-I" and testing the next characters for
# /nix/store/ is EXACTLY the python regex -I(/nix/store/[^\s]+): the match is anchored at the
# -I and runs to whitespace. `parse --regex` per line recompiles per call, which cost
# buck-codegen-coverage 6.5 seconds before it was measured.

const HOST_HEADERS = "//linux/native:host_headers"
const GRAPH = "result-graph-ref/build.ninja"
const EXTRA_DEPS = "buck/generated/extra-deps.json"

# The reference stages its own sources in the store too, so "absolute" is not enough to mean
# "host library": the project's own tree is a store path as well.
#
# BOTH NAMES, and the darling one is the one that actually matches. The reference is a FROZEN
# cmake-era artifact (#82), so the #84 rename could not touch it: it says darling-cmake-src
# 455,547 times and cider-cmake-src zero times. While this read the cider name alone it
# matched nothing, so the project's own -I flags all counted as HOST headers and the check
# reported 1,275 of 1,298 ported targets "missing" a dep they did not need -- 98.7 percent of
# the population was noise and the check was permanently red. Corrected it is 26 targets, of
# which 21 are ported and all 21 declare it. Same class as SRC_STORE_RE in
# gen-buck-from-ninja (deleted): a rename cannot reach a frozen artifact, so the READER takes both.
const PROJECT_MARKERS = ["-cider-cmake-src" "-darling-cmake-src"]

# The toolchain's own resource root, which the port supplies as clang_resource_dir rather
# than through host_include_dirs.
const TOOLCHAIN_MARKERS = ["clang-wrapper" "resource-root"]

# Both sets, since both are substring tests over the same directory string.
const MARKERS = ["-cider-cmake-src" "-darling-cmake-src" "clang-wrapper" "resource-root"]

# ORDER MATTERS, and it is the alternation order of the python regex: an anchored
# (?:OBJCXX|OBJC|CXX|C)_COMPILER__ tries the longest spellings first, so OBJCXX is stripped
# whole rather than leaving a stray CXX_ behind.
const RULE_PREFIXES = ["OBJCXX_COMPILER__" "OBJC_COMPILER__" "CXX_COMPILER__" "C_COMPILER__"]
const RULE_SUFFIX = "_unscanned_"

def cmake-target [rule: string] {
  mut r = $rule
  for p in $RULE_PREFIXES {
    if ($r | str starts-with $p) {
      let n = ($p | str length)
      $r = ($r | str substring $n..)
      break
    }
  }
  if ($r | str ends-with $RULE_SUFFIX) {
    let keep = (($r | str length) - ($RULE_SUFFIX | str length))
    $r = ($r | str substring 0..<$keep)
  }
  $r
}

# The host include dirs on one FLAGS/INCLUDES line, by the exact rule: a -I immediately
# followed by a store path, minus the project tree and minus the toolchain resource root.
def host-includes [text: string] {
  $text | split row "-I" | skip 1 | each {|t|
    let d = ($t | split row " " | first)
    if ($d | str starts-with "/nix/store/") { $d } else { null }
  } | compact | where {|d|
    # ONE LIST, not two tests joined by `and`: python searches a regex for the project marker
    # and does a substring test for the toolchain ones, but both are plain substrings here, so
    # the union is the same rule. It also sidesteps the nushell trap that an `and` STARTING a
    # continuation line parses as a command name (help: did you mean `all`).
    not ($MARKERS | any {|m| $d | str contains $m })
  }
}

def main [--list] {
  cd ($env.CURRENT_FILE | path dirname | path join "..")
  if not ($GRAPH | path exists) {
    # NONZERO ON PURPOSE, and it used to be 0. Returning 0 here meant that the day a store GC
    # collected the reference, this check would print one line and PASS, verifying nothing,
    # for ever. That is not hypothetical: result-graph-stock, the sibling symlink beside this
    # one, is ALREADY dangling because its store path was collected. A check whose input has
    # vanished has not passed, it has stopped existing, and it has to say so.
    # buck-endpoint-stale.nu already errors out in the same situation, so this adds no failure
    # mode the suite does not already have.
    print -e $"FAIL: no reference graph at ($GRAPH | path expand --no-symlink)"
    print -e "The frozen reference was garbage collected. NOTHING WAS VERIFIED here."
    print -e "Re-pin it, or delete this check rather than leaving it green and blind."
    exit 2
  }

  # THREE GREPS, ONE STREAM, and the third one is where the speed comes from. Selecting the
  # two line kinds is not enough: 26,198 FLAGS lines survive that, and running the token rule
  # over them inside nushell is 30 SECONDS against 1.0 for the python. So the token split
  # happens in grep too -- -o emits one match per line, which for a build line is its rule and
  # for a FLAGS line is each -I in turn, still in file order -- and the marker filter drops the
  # project and toolchain ones. What reaches nushell is 40,014 rule lines and 652 host
  # includes, each needing one string test.
  #
  # THE MARKER PATTERN IS BUILT FROM $MARKERS so the list stays the single source of truth, and
  # it is anchored to ^-I so it can only ever drop an include, never a build line whose output
  # path happens to contain one of the words.
  #
  # EVERY PATTERN IN A VARIABLE AND NEVER IN AN INTERPOLATION. Inside $"..." a backslash-paren
  # opens an interpolation and a backslash-bracket is an unrecognised escape, so a regex with
  # either in it cannot be written that way at all. Single quoted nushell strings are raw, and
  # the three externals pipe into each other directly, which also keeps bash out of it.
  let mpat = ("^-I.*(" + ($MARKERS | str join "|") + ")")
  let pat_lines = '^build [^:]+: |^[[:space:]]*(FLAGS|INCLUDES) =.*-I/nix/store/'
  let pat_token = '^build [^:]+: [^ ]+|-I/nix/store/[^ ]*'
  let raw = (do -i { ^grep -E $pat_lines $GRAPH | ^grep -oE $pat_token | ^grep -vE $mpat }
    | complete | get stdout | lines)
  mut needs = {}
  mut dirs = []
  mut cur = ""
  for l in $raw {
    if ($l | str starts-with "build ") {
      # `^build [^:]+: (\S+)`: the outs may not contain a colon, and the grep above carries the
      # same rule, so a line whose first colon is not the separator never arrives here and the
      # current target stays what it was -- which is what python does with it too.
      $cur = ($l | split row ": " | last | str trim)
      continue
    }
    if ($cur | is-empty) { continue }
    let d = ($l | str substring 2..)
    let t = (cmake-target $cur)
    $needs = ($needs | upsert $t (($needs | get -o $t | default 0) + 1))
    $dirs = ($dirs | append $d)
  }
  let dirs = ($dirs | uniq)

  let extra = (open $EXTRA_DEPS)
  let targets = ($needs | columns)

  # Only targets the port actually BUILDS. A reference target with no cc_objects block here is
  # out of scope, and demanding a dep for it would make this check unpassable.
  #
  # THE FILE LIST COMES FROM find, WITH -type l, because vendor/src is a MIRROR of real
  # directories and per-file SYMLINKS: a bare -type f drops 56 of the 125 BUCK files.
  let bucks = (^find . "(" -path ./buck-out -o -path ./.jj -o -path ./.git -o -path ./.direnv ")"
    -prune -o -name BUCK "(" -type f -o -type l ")" -print | lines)
  let texts = ($bucks | each {|p| open --raw $p | decode utf-8 })
  let ported = ($targets | where {|t| $texts | any {|x| $x | str contains $'name = "($t)_obj"' } })

  let missing = ($targets | where {|t|
    ($t in $ported) and (not ($HOST_HEADERS in ($extra | get -o $t | default []))) } | sort)
  let unported = ($targets | where {|t| not ($t in $ported) } | sort)

  let total = ($needs | values | math sum)
  print $"reference compiles with a host -I: ($total) across ($targets | length) targets"
  print $"distinct host include dirs:        ($dirs | length)"
  print $"ported targets among them:         ($ported | length)"
  if ($unported | is-not-empty) {
    print $"not built by the port \(skipped\):   ($unported | length)  ($unported | first 8 | str join ' ')"
  }
  if $list {
    for d in ($dirs | sort) { print $"    ($d)" }
  }

  if ($missing | is-not-empty) {
    print $"\nFAIL: ($missing | length) target\(s\) compile against host headers without asking:"
    for t in $missing { print $"    ($t)  \(($needs | get $t) host -I in the reference\)" }
    print $"\nAdd ($HOST_HEADERS) to each in buck/generated/extra-deps.json and"
    print "regenerate the block, so a --write cannot drop it again."
    exit 1
  }
  print $"\nok: every ported target with a host -I declares ($HOST_HEADERS)"
  exit 0
}
