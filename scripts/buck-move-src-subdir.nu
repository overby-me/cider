#!/usr/bin/env nu

# MOVE A GROUP OF src/ SUBDIRECTORIES TO darwin/ OR linux/, AND REPOINT EVERY REFERENCE TO THEM.
# Task #87 stage 1.
#
# SAFE BY DEFAULT. This prints what it would do and changes nothing unless --apply is passed.
# That is not politeness: a script in this repo with no argv parsing once treated --dry-run as
# consent and wrote 98 files, so the default here has to be the harmless one.
#
# WHY A SCRIPT RATHER THAN A SED SWEEP. The reference surface for the full move is 1,208
# occurrences across 130 files, and the wrong ones are not obvious:
#
#   patches/ is EXCLUDED and that was established by reading, not assumed. One xnu patch has a
#   line reading a hash-include then the OLD startup path then a comment, with a LEADING SPACE,
#   which makes it a CONTEXT line of a unified diff. Rewriting a context line stops the patch
#   applying.
#
#   pins/ and buck-src/ are excluded for their CONTENT, because those are the 148 vendored
#   upstreams and a pin tree is where a careless rewrite does the most damage. But a BUCK or
#   .bzl file is OURS wherever it sits, and excluding those trees wholesale was wrong: the first
#   run left 56 labels dangling in four tracked build files of ours that name first-party
#   targets. buck-labels-check.nu caught every one, which is the whole reason it exists. So
#   build files are rewritten everywhere and only upstream SOURCE is left alone.
#
#   Longest name first. Several directories share a prefix, so the alternation is sorted by
#   length descending and anchored with a trailing word boundary. Without that the shorter name
#   eats the front of the longer one.
#
#   AND THE PYTHON REWROTE ITS OWN DOCSTRING THE FIRST TIME IT RAN. This file lives in scripts/,
#   which is in scope, so prose QUOTING an old path was repointed along with real references and
#   became a false statement about a file deliberately left alone. That is why the paragraphs
#   above describe those paths instead of spelling them. A rewriting tool inside its own blast
#   radius cannot quote what it is rewriting.
#
# Usage:
#   scripts/buck-move-src-subdir.nu --group linux                  # dry run, the default
#   scripts/buck-move-src-subdir.nu --group linux --apply
#   scripts/buck-move-src-subdir.nu --group linux --rewrite-only   # tree already moved
#
# PORTED FROM PYTHON (#98), and what can be gated is gated: BOTH groups in BOTH reachable modes,
# byte identical. The default mode refuses (src/ no longer exists, since this tool is what
# emptied it) and --rewrite-only produces the real reference report over the whole tree.
#
# WHAT CANNOT BE GATED, said plainly rather than left implied: --apply. The move it performs
# ALREADY HAPPENED, so there is no tree left on which to compare two implementations of it. The
# moving, symlink repointing and self check below are a faithful transcription and nothing more,
# and the file says so where each of them starts.
#
# THE THREE REGEXES ARE HAND ROLLED BOUNDARY TESTS, because python spells them with lookbehind
# and the Rust regex crate nushell uses has none. Each is documented where it is used, and the
# rules they encode were each paid for by a broken build.

const TO_LINUX = ["bsdln" "buildtools" "hosttools" "libelfloader" "startup" "native"]

const TO_DARWIN = [
  "CoreAudio" "MobileKeyBag" "OpenDirectoryOld" "OpenScripting" "PlistBuddy"
  "VideoDecodeAcceleration" "clt" "crash" "dirserv" "diskutil" "ditto" "duct"
  "include" "launchd" "lib" "libDiagnosticMessagesClient" "libMobileGestalt"
  "libaccessibility" "libacm" "libaks" "libcache" "libcompression" "libcrashhandler"
  "libgcc" "libgmalloc" "libm" "libpmenergy" "libquit" "libsandbox" "libsimple"
  "libsysmon" "libsystem_coreservices" "networkextension" "opendirectory_internal"
  "pboard" "quarantine" "sandbox" "sandbox-exec" "shellspawn" "simd" "softlinking"
  "tools" "unxip" "vchroot" "xcselect" "xtrace"
]

const SKIP_DIRS = [".jj" ".git" "buck-out" "buck-src" "buck-rust" "target" "outputs"
  "build" "__pycache__" "result" "result-ld64" "result-graph-ref"
  "result-ducttape-ref" "node_modules" ".direnv"]

# Excluded from REWRITING, for the reasons in the header. Not excluded from moving.
const SKIP_REL_PREFIX = ["patches/" "pins/"]

const MAX_BYTES = 4000000

def say [msg: string] { print $msg }

# Ours wherever it lives, including inside a pin. See the header.
def is-build-file [name: string] {
  ($name == "BUCK") or ($name | str ends-with ".bzl")
}

# Every file the rewrite considers: the tree minus the excluded directories, PLUS the build
# files inside those excluded directories, minus symlinks and anything over 4 MB.
#
# ONE find RATHER THAN A WALK IN NUSHELL. The python opens every candidate to decide; at this
# tree size that is the whole runtime, and the reduction below means only files that actually
# mention a moving name are ever read.
def candidate-files [] {
  # THE -o BETWEEN THE PATHS IS LOAD BEARING. Without it find reads the parenthesised group as
  # an AND of every -path, which is never true, so NOTHING is pruned: the first run of this port
  # reported 103 references in 77 files, and the top of the list was buck-out logs, .jj operation
  # objects and a __pycache__ .pyc. The python walk excludes those by construction.
  # BY NAME, NOT BY PATH, and at ANY DEPTH. python filters the walk's directory list by NAME,
  # so a __pycache__ five levels down is excluded too; -path ./__pycache__ only ever matches one
  # at the top and left four .pyc files in the report.
  let prune = ($SKIP_DIRS | each {|d| ["-name" $d "-o"] } | flatten | drop 1)
  let listed = (^find . ...( $prune | prepend "(" | append ")" ) -prune -o -type f -print
    | complete | get stdout | lines | where {|l| $l != "" } | each {|p| $p | str substring 2.. })
  # The build files inside the pruned trees, which are ours wherever they sit.
  let inside = (^find . -name BUCK -o -name "*.bzl" | complete | get stdout | lines
    | where {|l| $l != "" } | each {|p| $p | str substring 2.. })
  # IN os.walk ORDER, which is what the report's tie breaking depends on. find interleaves: it
  # descends into a subdirectory the moment it meets one, so scripts/x came out before the root
  # PLAN.md. os.walk is top-down by DIRECTORY: every file of a directory, then its children. So
  # the directories are listed once, in the same depth-first order, and the files are bucketed
  # into them. Two files with one reference each swapped places without this, which is the only
  # way the report can differ once the counts agree.
  let files = (($listed ++ $inside) | uniq)
  let dirorder = (^find . ...( $prune | prepend "(" | append ")" ) -prune -o -type d -print
    | complete | get stdout | lines | where {|l| $l != "" }
    | each {|p| if $p == "." { "" } else { $p | str substring 2.. } })
  let ranked = ($dirorder | enumerate | reduce --fold {} {|r, acc| $acc | insert $r.item $r.index })
  $files | enumerate | sort-by --custom {|a, b|
    let da = ($ranked | get -o ($a.item | path dirname) | default 999999)
    let db = ($ranked | get -o ($b.item | path dirname) | default 999999)
    if $da != $db { $da < $db } else { $a.index < $b.index }
  } | get item
}

def main [
  --group: string = ""      # linux or darwin
  --apply                   # actually move and rewrite; without it nothing is changed
  --rewrite-only            # skip the move, repoint references only, for a tree already moved
] {
  cd ($env.CURRENT_FILE | path dirname | path join "..")
  if not ($group in ["darwin" "linux"]) {
    print -e "usage: buck-move-src-subdir.nu --group {darwin,linux} [--apply] [--rewrite-only]"
    print -e "buck-move-src-subdir.nu: error: the following arguments are required: --group"
    exit 2
  }
  let names = (if $group == "linux" { $TO_LINUX } else { $TO_DARWIN })
  let dest = $group

  let missing = ($names | where {|n| (["src" $n] | path join | path type) != "dir" })
  if ($missing | is-not-empty) and (not $rewrite_only) {
    # THE LIST IS PRINTED AS PYTHON PRINTS A LIST, because this line is the only output the
    # default mode has left and it is what the port is gated on.
    let shown = ("[" + ($missing | each {|n| $"'($n)'" } | str join ", ") + "]")
    say $"FAIL: not in src/: ($shown). Refusing to run on a tree that does not match the mapping this was written against."
    exit 1
  }

  # THE ALTERNATION IS LONGEST FIRST, and a nushell `sort-by` on the length descending is the
  # same order python builds with sorted(key=len, reverse=True). Ties keep the input order in
  # both, which is what makes the two patterns identical rather than merely equivalent.
  let alts = ($names | sort-by --custom {|a, b| ($a | str length) > ($b | str length) })

  # ONE grep TO FIND THE CANDIDATES. Only a file that mentions src/<name> can contribute, and
  # reading the other 27,000 is what makes the python take 109 seconds.
  let pat_any = ("src/(" + ($alts | str join "|") + ")")
  let listf = (mktemp -t --suffix .txt)
  candidate-files | str join "\n" | save -f $listf
  # -I SKIPS BINARY FILES, which is python's errors="strict" open raising UnicodeDecodeError and
  # the loop continuing. Without it a .pyc that happens to hold the byte sequence counts as a
  # reference, and four of them did.
  let hits = (^bash -c $"tr '\\n' '\\0' < ($listf) | xargs -0 grep -lIE '($pat_any)' 2>/dev/null || true"
    | complete | get stdout | lines | where {|l| $l != "" })
  rm -f $listf

  mut edits = []
  # NOT SORTED. The report breaks ties by the order files were SEEN, because python's sorted()
  # is stable over a dict in insertion order, and that insertion order is os.walk's, which is
  # readdir order. find gives the same readdir order, so leaving the list alone reproduces the
  # tie order; sorting it alphabetically swapped two files that both have one reference.
  for rel in $hits {
    if ($rel | path type) != "file" { continue }
    let sz = (ls -l $rel | get size.0 | into int)
    if $sz > $MAX_BYTES { continue }
    let base = ($rel | path basename)
    let skipped_tree = ($SKIP_REL_PREFIX | any {|p| $rel | str starts-with $p })
    if $skipped_tree and (not (is-build-file $base)) { continue }
    let text = (open --raw $rel | decode utf-8)

    # A LABEL is ours anywhere: //src/<name>. The python lookbehind is (?<=//), a fixed two
    # characters, so here the match is found on the literal "//src/" and the boundary after the
    # name is tested by hand.
    let lab = (count-and-rewrite $text "//src/" $"//($dest)/" $alts)
    mut n = $lab.n
    mut new = $lab.text
    # A BARE path is ours only where the path space is the repo, and never inside a pin tree or
    # buck-src, where it is relative to the pin instead. Build files are the exception: a label
    # in one is ours wherever it sits, and it was handled above.
    if not ($skipped_tree or ($rel | str starts-with "buck-src/") or (is-build-file $base)) {
      let bare = (count-and-rewrite-bare $new $alts $dest)
      $n = $n + $bare.n
      $new = $bare.text
    }
    if $n > 0 { $edits = ($edits | append { rel: $rel, n: $n, text: $new }) }
  }

  let total = ($edits | get n | math sum | default 0)
  say $"group ($group): ($names | length) directories -> ($dest)/"
  say $"references to repoint: ($total) in ($edits | length) files"
  for e in ($edits | sort-by --custom {|a, b| $a.n > $b.n } | first 12) {
    say $"   ($e.n | into string | fill --alignment r --width 5)  ($e.rel)"
  }
  if ($edits | length) > 12 {
    say $"   ... and (($edits | length) - 12) more files"
  }

  if not $apply {
    say ""
    say "DRY RUN. Nothing was changed. Pass --apply to perform the move."
    exit 0
  }

  # FROM HERE DOWN IS A TRANSCRIPTION THAT CANNOT BE GATED. The move already happened, so there
  # is no tree on which to compare this against the python. It is written to match line for
  # line and it has not been executed.
  if not $rewrite_only {
    for n in $names {
      let src = (["src" $n] | path join)
      let dst = ([$dest $n] | path join)
      if ($dst | path exists) {
        say $"FAIL: ($dest)/($n) already exists, refusing to overwrite"
        exit 1
      }
      ^mv $src $dst
      say $"  moved src/($n) -> ($dest)/($n)"
    }
  }

  # SYMLINK TARGETS ARE REFERENCES TOO, and missing them is what broke rung 1 the first time.
  # The rewrite pass skips symlinks so it never follows one out of the tree, but that also meant
  # their TARGETS were never repointed: three SDK links still pointed at the old startup path.
  # A SYMLINK TARGET IS RESOLVED, NOT PATTERN MATCHED: targets are relative and full of ../, so
  # src/ in one is ALWAYS preceded by a slash, the same slash the bare pattern must refuse in
  # order to leave pin-relative paths alone. Matching text found 0 of the 65 links that needed
  # moving while claiming success.
  let root_real = ($env.PWD | path expand)
  mut relinked = 0
  for p in (^find . -type l | complete | get stdout | lines | where {|l| $l != "" }) {
    let t = (^readlink $p | complete | get stdout | str trim)
    if ($t | is-empty) { continue }
    let landing = (if ($t | str starts-with "/") { $t } else {
      [($p | path dirname) $t] | path join
    } | path expand --no-symlink)
    if not ($landing | str starts-with ($root_real + "/")) { continue }
    let from = (($root_real | str length) + 1)
    let parts = ($landing | str substring $from.. | split row "/")
    if ($parts | length) < 2 { continue }
    if ($parts | get 0) != "src" { continue }
    if not (($parts | get 1) in $names) { continue }
    # Only the first component changes, so the ../ depth stays correct.
    let nt = ($t | str replace $"src/($parts | get 1)" $"($dest)/($parts | get 1)")
    if $nt != $t {
      rm $p
      ^ln -s $nt $p
      $relinked = $relinked + 1
    }
  }
  say $"  repointed ($relinked) symlink target\(s)"

  for e in $edits {
    # A moved file is now under its new path; rewrite there instead.
    mut target = $e.rel
    for n in $names {
      if ($e.rel | str starts-with $"src/($n)/") {
        $target = $"($dest)/" + ($e.rel | str substring 4..)
        break
      }
    }
    $e.text | save -f $target
  }
  say ""
  say $"rewrote ($edits | length) files, ($total) references"
  say "self check is not transcribed: see the header, the apply path cannot be gated"
  exit 0
}

# //src/<name> anywhere, with the boundary after the name tested by hand because the Rust regex
# crate has no lookahead. Returns the rewritten text and how many it changed.
def count-and-rewrite [text: string, prefix: string, replacement: string, alts: list<string>] {
  mut out = ""
  mut rest = $text
  mut n = 0
  loop {
    let ix = ($rest | str index-of $prefix)
    if $ix < 0 { break }
    let after = ($ix + ($prefix | str length))
    let tail = ($rest | str substring $after..)
    # `first?` IS NOT A COMMAND in nushell, and the error names only the pipe. An empty list
    # has to be tested for.
    let cands = ($alts | where {|a| ($tail | str starts-with $a) and (boundary-ok $tail $a) })
    let hit = (if ($cands | is-empty) { null } else { $cands | first })
    $out = $out + ($rest | str substring 0..<$ix)
    if $hit == null {
      $out = $out + $prefix
    } else {
      $out = $out + $replacement + $hit
      $n = $n + 1
    }
    $rest = (if $hit == null { $tail } else { $tail | str substring ($hit | str length).. })
  }
  { text: ($out + $rest), n: $n }
}

# A BARE src/<name>, which is ours only outside a pin. python spells the left boundary
# (?<![\w.\-/]), so the character before src/ may not be a word character, dot, dash or slash;
# the slash is the important one, since buck-src/ ends in src/ and rewriting that would produce
# buck-darwin/<name> for any pin sharing a name with a moving directory.
def count-and-rewrite-bare [text: string, alts: list<string>, dest: string] {
  mut out = ""
  mut rest = $text
  mut n = 0
  mut consumed = 0
  loop {
    let ix = ($rest | str index-of "src/")
    if $ix < 0 { break }
    let abs = ($consumed + $ix)
    let before = (if $abs == 0 { "" } else { $text | str substring ($abs - 1)..<$abs })
    let after = ($ix + 4)
    let tail = ($rest | str substring $after..)
    # `first?` IS NOT A COMMAND in nushell, and the error names only the pipe. An empty list
    # has to be tested for.
    let cands = ($alts | where {|a| ($tail | str starts-with $a) and (boundary-ok $tail $a) })
    let hit = (if ($cands | is-empty) { null } else { $cands | first })
    let left_ok = ($before == "" or (not ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-/" | str contains $before)))
    $out = $out + ($rest | str substring 0..<$ix)
    if ($hit == null) or (not $left_ok) {
      $out = $out + "src/"
      $rest = $tail
      $consumed = $abs + 4
    } else {
      $out = $out + $"($dest)/($hit)"
      $n = $n + 1
      $rest = ($tail | str substring ($hit | str length)..)
      $consumed = $abs + 4 + ($hit | str length)
    }
  }
  { text: ($out + $rest), n: $n }
}

# python's (?![\w.\-]) after the name: the next character may not be a word character, dot or
# dash. End of string counts as a boundary.
def boundary-ok [tail: string, name: string] {
  let ix = ($name | str length)
  if ($tail | str length) <= $ix { return true }
  let c = ($tail | str substring $ix..<($ix + 1))
  not ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-" | str contains $c)
}
