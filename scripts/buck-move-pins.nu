#!/usr/bin/env nu

# #87 STAGE 2: MOVE src/external TO pins/, REWRITING ONLY WHAT IS GENUINELY A REFERENCE.
#
# DRY RUN IS THE DEFAULT AND --apply IS PARSED EXPLICITLY. An earlier script in this repo
# treated an unrecognised --dry-run as consent and wrote 98 files, so unknown arguments are a
# hard error here rather than something to guess at.
#
# THE RULE IS LABEL-FIRST, NOT PATH-FIRST, and that is the whole point of this file.
#
# A blanket rewrite of the string src/external corrupts far more than it fixes. Measured on
# this tree: buck-src/ alone carries 1,854 mentions and only 172 of them are ours. Rewriting
# the frozen lines would break nothing at build time and would silently stop coverage finding
# its reference paths, which is the expensive kind of failure. So this rewrites four specific
# things and reports everything it declines to touch:
#
#   1. LABELS          //src/external/<x>  ->  //pins/<x>          (also root//src/external/...)
#   2. MANIFEST        the "path" field of nix/submodules.json, handled as JSON, not as text
#   3. LIVE PATHS      a quoted or bare src/external/<x> in .nix, .py, .nu, .sh, .rs, .json
#                      and .gitignore, EXCLUDING the frozen and historical lines below
#   4. nothing else
#
# NEVER TOUCHED:
#   untracked files          materialized pins (.gitignore:115) and linux/server/target
#                            (linux/server/.gitignore:1). Asking the repo what it tracks
#                            excludes these by construction. A filesystem walk reported 945
#                            references where the repo holds 545, because one generated file,
#                            xnu/gen/bsdsyscalls/stubs.list, holds 430 of them by itself.
#   "# cmake target:" and "buck-registry:"    the FROZEN REFERENCE path space
#   "previously the submodule"                VENDORED.md sentences about the PAST
#   "/build/build/"                           the cmake BINARY DIR path space
#   docs/changelog.md                                   34 hits mixing current layout with past failures;
#                                             only a reader can tell which is which
#
# PORTED FROM PYTHON (#98), byte identical in dry run over the whole tracked tree.
#
# THE TWO REGEXES COULD NOT BE PORTED AS REGEXES. python spells the boundaries with lookaround,
# `(?<![\w/.-])src/external(?=[/"'\s:,)\]}]|$)`, and the Rust regex crate nushell uses has no
# lookaround at all. They are therefore done by hand, scanning for the string and testing the
# characters either side, which is what the lookarounds mean. That is exact rather than
# approximate, and it avoids the trap of consuming a boundary character that the NEXT match on
# the same line needs.
#
# THE FILE LIST IS REDUCED BY grep BEFORE nushell reads anything. The repo tracks 27,350 files
# and about 1,200 lines mention the string at all; opening every tracked file to discover that
# is the whole runtime, and python pays it too but at a hundredth of the per-file cost.

const OLD = "src/external"
const NEW = "pins"
const MANIFEST = "nix/submodules.json"

# THIS FILE EXCLUDES ITSELF, and that is not a convenience. Its header has to quote the old
# spelling in order to explain which lines are frozen and why, so a sweep that rewrote it would
# destroy the explanation of what the sweep does.
const SELF = "scripts/buck-move-pins.nu"
const SKIP_FILES = ["docs/changelog.md" "nix/submodules.json" "scripts/buck-move-pins.nu"]
const SKIP_REL_PREFIX = ["linux/server/target/"]

# Lines that mention the string but must keep the old spelling.
#
# (NO-PIN-REWRITE) is an explicit opt-out for PROSE THAT DESCRIBES THE PAST. Comments in this
# repo routinely quote the exact path a failure happened at, and rewriting those turns a true
# sentence into a false one while looking like a tidy-up.
const FROZEN_LINE = '#\s*cmake target:|buck-registry:|/build/build/|previously the submodule|NO-PIN-REWRITE'

const REWRITE_EXT = [".nix" ".py" ".nu" ".sh" ".rs" ".json" ".md" ".toml" ".bzl" ""]

# The character classes the python lookarounds name, as sets rather than as regex.
const PATH_BEFORE_BAD = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_/.-"
const PATH_AFTER_OK = "/\"' \t:,)]}"

def say [msg: string] { print $msg }

def tracked-files [] {
  let r = (do -i { ^jj file list } | complete)
  if $r.exit_code != 0 {
    print -e $"FAIL: could not list tracked files: ($r.stderr | str trim | str substring 0..<200)"
    exit 1
  }
  let rels = ($r.stdout | lines | each {|l| $l | str trim } | where {|l| $l != "" })
  if ($rels | is-empty) {
    print -e "FAIL: the tracked file list is EMPTY, refusing to report a vacuous zero"
    exit 1
  }
  $rels
}

# (new_line, labels_rewritten, paths_rewritten), the python rewrite_line.
def rewrite-line [line: string, is_build: bool] {
  if ($line =~ $FROZEN_LINE) { return { line: $line, lab: 0, path: 0 } }
  # LABELS: //src/external followed by / or :, with an optional root prefix. The lookahead is
  # a single character class, so it is a captured group here and put back verbatim.
  # THE PATTERNS ARE BUILT BY CONCATENATION, NEVER INSIDE $'...'. A single quoted interpolated
  # string is RAW, so a backslash does not escape anything in it and the parenthesis of the
  # regex opens an interpolation that never closes. The parse error says only
  # "Unclosed delimiter" and names the whole file.
  let lab_re = '(root)?//' + $OLD + '([/:])'
  let after_lab = ($line | str replace --all --regex $lab_re '${1}//pins${2}')
  let nlab = ($line | parse --regex $lab_re | length)
  if $is_build {
    # A bare path inside a BUCK or bzl file is PACKAGE relative, so only labels move there.
    return { line: $after_lab, lab: $nlab, path: 0 }
  }
  # LIVE PATHS, by hand: find every occurrence and test the characters either side, which is
  # what the python lookarounds say. Scanning left to right and rebuilding avoids consuming a
  # boundary character that the next occurrence needs.
  mut out = ""
  mut rest = $after_lab
  mut npath = 0
  loop {
    let ix = ($rest | str index-of $OLD)
    if $ix < 0 { break }
    let before = (if $ix == 0 { "" } else { $rest | str substring ($ix - 1)..<$ix })
    let after_ix = ($ix + ($OLD | str length))
    let after = (if $after_ix >= ($rest | str length) { "" } else {
      $rest | str substring $after_ix..<($after_ix + 1) })
    let ok_before = ($before == "" or (not ($PATH_BEFORE_BAD | str contains $before)))
    let ok_after = ($after == "" or ($PATH_AFTER_OK | str contains $after))
    $out = $out + ($rest | str substring 0..<$ix) + (if ($ok_before and $ok_after) {
      $npath = $npath + 1
      $NEW
    } else { $OLD })
    $rest = ($rest | str substring $after_ix..)
  }
  { line: ($out + $rest), lab: $nlab, path: $npath }
}

def main [--apply, --dry-run (-n)] {
  cd ($env.CURRENT_FILE | path dirname | path join "..")

  # ONE grep over the tracked list, so nushell only opens the handful of files that mention the
  # string. python reads all 27,350 and discards most; same answer, a hundredth of the opens.
  let listf = (mktemp -t --suffix .txt)
  tracked-files | str join "\n" | save -f $listf
  let hits = (^bash -c $"tr '\\n' '\\0' < ($listf) | xargs -0 grep -l -F -e ($OLD) 2>/dev/null || true"
    | complete)
  rm -f $listf
  let candidates = ($hits.stdout | lines | where {|l| $l != "" })

  mut labels = 0
  mut paths = 0
  mut left_frozen = 0
  mut touched = []
  for rel in $candidates {
    if ($rel in $SKIP_FILES) { continue }
    if ($SKIP_REL_PREFIX | any {|pref| $rel | str starts-with $pref }) { continue }
    # islink and isfile, in that order: a symlink is skipped even when it resolves.
    if ($rel | path type) != "file" { continue }
    # os.path.splitext, which IGNORES LEADING DOTS: ".gitignore" has NO extension in python
    # and so falls in the "" bucket that REWRITE_EXT allows. `path parse` calls it an extension
    # of "gitignore", which dropped .gitignore from the report entirely.
    let base_core = ($rel | path basename | str trim --left --char ".")
    let ext = (if ($base_core | str contains ".") { "." + ($base_core | split row "." | last) } else { "" })
    let is_build = (($rel | path basename) == "BUCK" or $ext == ".bzl")
    if not ($is_build or ($ext in $REWRITE_EXT)) { continue }
    # ONLY THE MATCHING LINES ARE REWRITTEN, and that is what makes this finish. Walking every
    # line of every candidate means walking buck-src/BUCK, 175,450 lines of which 1,854 mention
    # the string; python pays that too, at a hundredth of the per-line cost, and nushell simply
    # does not come back. grep -n gives the line numbers, the rewrite runs on those, and the
    # file is only rebuilt when --apply has something to write.
    let text = (open --raw $rel | decode utf-8)
    let all = ($text | split row "\n")
    let hitlines = (do -i { ^grep -n -F -e $OLD $rel } | complete | get stdout | lines
      | each {|l| ($l | split row ":" | first | into int) - 1 })
    mut flab = 0
    mut fpath = 0
    mut newlines = {}
    for i in $hitlines {
      let line = ($all | get $i)
      if ($line =~ $FROZEN_LINE) { $left_frozen = $left_frozen + 1 }
      let r = (rewrite-line $line $is_build)
      $flab = $flab + $r.lab
      $fpath = $fpath + $r.path
      if $r.line != $line { $newlines = ($newlines | upsert ($i | into string) $r.line) }
    }
    if $flab > 0 or $fpath > 0 {
      $touched = ($touched | append { rel: $rel, lab: $flab, path: $fpath })
      $labels = $labels + $flab
      $paths = $paths + $fpath
      if $apply {
        # A CLOSURE MAY NOT CAPTURE A `mut`, and the error says only "Capture of mutable
        # variable" without naming the line. Bind it to a `let` and the same closure is fine.
        let edited = $newlines
        ($all | enumerate | each {|r|
          let k = ($r.index | into string)
          ($edited | get -o $k | default $r.item)
        } | str join "\n") | save -f $rel
      }
    }
  }

  # The manifest, as JSON so that only a real path field moves.
  mut mcount = 0
  if ($MANIFEST | path exists) {
    let data = (open --raw $MANIFEST | from json)
    let hitrows = ($data | where {|e| ($e | get -o path | default "") | str starts-with $"($OLD)/" })
    $mcount = ($hitrows | length)
    if $apply and $mcount > 0 {
      let moved = ($data | each {|e|
        let p = ($e | get -o path | default "")
        if ($p | str starts-with $"($OLD)/") {
          $e | upsert path ($NEW + ($p | str substring ($OLD | str length)..))
        } else { $e }
      })
      ($moved | to json --indent 2) + "\n" | save -f $MANIFEST
    }
  }

  let verb = (if $apply { "REWROTE" } else { "would rewrite" })
  say $"($verb): ($labels) label\(s), ($paths) live path\(s), ($mcount) manifest entry\(ies)"
  say $"LEFT ALONE: ($left_frozen) frozen / historical / binary-dir line\(s)"
  say $"files affected: ($touched | length)"
  for t in ($touched | sort-by {|x| 0 - ($x.lab + $x.path) } | first 20) {
    say $"    labels=($t.lab | into string | fill --alignment r --width 4) paths=($t.path | into string | fill --alignment r --width 4)  ($t.rel)"
  }
  if not $apply {
    say ""
    say "DRY RUN. Nothing was written. docs/changelog.md and the manifest text are excluded; pass --apply to write."
  }
  exit 0
}
