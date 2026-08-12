#!/usr/bin/env nu

# An environment variable we tell people to set must be read by something.
#
# WHY THIS EXISTS. DARLING_XTRACE was named in nine places across five scripts: two of them
# actually ran `env DARLING_XTRACE=1 cider shell ...` behind a --xtrace flag, the rest printed it
# at the user as the way to get a syscall trace. Nothing read it. Not the loader, not the server,
# not the launcher, not xtrace itself, not upstream. A search of all 289,836 files in the tree
# found the name only in those scripts and in __PTK_DARLING_XTRACE_TLS, which is a pthread
# TLS key in xnu, a different namespace entirely.
#
# So the flag was inert. Someone triaging a failing syscall would pass --xtrace, get no trace,
# and conclude the tracer was broken or that the syscall was never reached. The failure is silent
# and it points the investigation the wrong way, which is the expensive kind.
#
# This is the mirror image of buck-upstream-names-check.py. That one catches a rename that
# ORPHANS a name upstream still uses. This one catches a name WE advertise that nothing
# implements. Both are about the same underlying mistake, a name whose two ends do not meet.
#
# THE CHECK. In our own namespace only -- CIDER_, CIDERD_, DARLING_, DARLINGSERVER_, XTRACE_ --
# every name a user-facing file ADVERTISES must be READ somewhere in first-party code.
#
# ADVERTISED is deliberately narrow: the name appears as an assignment (`NAME=`, with or without
# a leading `env`) or as `$env.NAME`, in a file under a directory we use to talk to people or to
# drive the build. A bare quoted string is NOT advertising, which is what keeps the upstream
# names listed as DATA inside buck-upstream-names-check.py from being flagged.
#
# READ is deliberately wide, because there are many ways to consume a variable and treating any
# of them as unread produces a false positive:
#
#     getenv("X")            C and Objective-C
#     env::var("X")          Rust, Result
#     env("X")               the bare helper in linux/server
#     env!("X")              Rust compile-time, fed by the BUCK env attribute, NOT by build.rs
#     os.environ / getenv    Python, both the .get and the subscript forms
#     $env.X                 nushell
#     $X, ${X}, ${X[@]}      POSIX expansion, including the ARRAY subscript form
#     envp_set(.., "X")      xtrace propagating its settings into a child
#     "X": in a BUCK file    the env attribute that feeds env!()
#     #define X              not an environment variable at all, but a C macro sharing the
#                            namespace: XTRACE_INLINE, XTRACE_HIDDEN, the include guards
#
# WHY THE WIDTH MATTERS, measured rather than assumed. A first pass recognising only the first
# four idioms reported 39 names, 38 of them false: C macros in darwin/xtrace, the CIDER_GIT_* pair
# the launcher reads through env!(), and script-local names consumed by POSIX expansion. Widening
# it left three, and TWO OF THOSE THREE WERE STILL FALSE, each for its own reason worth keeping:
#
#   CIDER_CMD is a bash ARRAY. It is assigned as CIDER_CMD=(cider) and read as
#   ${CIDER_CMD[@]}, so a ${NAME} pattern anchored on : or } misses it. The subscript is a read.
#
#   CIDER_EMIT_TARGET_SOURCES is read by os.environ.get, a Python idiom absent from the first
#   list entirely.
#
#   (Both carried the DARLING_ spelling when they were found. They are CIDER_ now, and the two
#   that are genuinely read from the ENVIRONMENT kept a DARLING_ fallback while the script-local
#   ones did not, because a fallback on a variable no one can set from outside is theatre.)
#
# Both looked exactly like the real defect until the file was opened. That is the whole lesson:
# an unrecognised idiom and an unimplemented variable are indistinguishable from the outside, so
# every name this reports has to be read in its file before it is believed, and every idiom the
# project actually uses has to be in the list above or the report is fiction of its own.
#
# A check reporting 39 problems of which 38 are noise is a check nobody runs, and this project has
# already been bitten by exactly that: buck-pin-rev-check.nu flagged 143 unrelated trees in its
# first form and its exit code proved nothing about the one defect planted in it.
#
# THIS FILE EXCLUDES ITSELF from the advertising side, and that is not a convenience. Its
# header has to name the fiction it hunts in order to explain it, which would make the check
# report itself for ever and turn a green result into an impossibility. A check that cannot pass
# is as worthless as one that cannot fail.
#
# THE NEGATIVE CONTROL IS THE TREE ITSELF. Before the DARLING_XTRACE fix this check reported
# exactly one name, the real one, and no others. That is a stronger control than a planted fault,
# because the thing it caught was found independently and was the ONLY thing that fired. Use
# --expect-fiction to assert that a named variable is still detected, which is what makes a
# regression of the check itself visible.
#
# Exit 0 if every advertised name is read, 1 otherwise.
#
# PORTED FROM PYTHON, byte identical on the real tree in all three modes (plain, --list-read and
# --expect-fiction both ways). TWO NOTES FOR THE NEXT PORT:
#
#   THE SELF-EXCLUSION MAKES A SIDE BY SIDE COMPARISON LIE. While both files exist, each excludes
#   itself and scans the OTHER, whose header advertises DARLING_XTRACE, so each reports a fiction
#   the other does not. The comparison has to be done with exactly one of them in the tree.
#
#   PREFILTER BY NAMESPACE. Both sides keep only names matching OURS, so a file that does not
#   contain CIDER, DARLING or XTRACE at all cannot contribute to either side. Testing that with
#   `str contains` before running thirteen regexes over the file is a strict superset and takes
#   this from tens of seconds to a couple, on the same measured principle as the other ports:
#   the per-invocation cost dominates.

const OURS = '^(?:CIDER|CIDERD|DARLING|DARLINGSERVER|XTRACE)_[A-Z0-9_]+$'
const NAMESPACES = ["CIDER" "DARLING" "XTRACE"]

# Where we talk to people or drive the build. darwin/ and linux/ are deliberately absent:
# a C macro is not an advertisement, and those trees are where the macros live.
const ADVERTISING_DIRS = ["scripts" "tests" "docs" "nix" "etc" "tools" "plan"]
const ADVERTISING_FILES = ["PLAN.md" "README.md" "flake.nix"]

# Everything first-party, for the read side. Pins are excluded: they are upstream, they cannot
# implement a name we invented, and walking them costs far more than the check is worth.
const READING_DIRS = ["src" "darwin" "linux" "scripts" "nix" "tests" "buck" "tools" "etc"]

const SKIP_DIRS = [".jj" ".git" "buck-out" "target" "__pycache__" "node_modules"
                   "result" "outputs" "build" "buck-rust" "buck-src"]

const ADVERTISE = [
  '\b(?<n>(?:CIDER|CIDERD|DARLING|DARLINGSERVER|XTRACE)_[A-Z0-9_]+)\s*='
  '\$env\.(?<n>(?:CIDER|CIDERD|DARLING|DARLINGSERVER|XTRACE)_[A-Z0-9_]+)'
]

const READS = [
  'getenv\s*\(\s*"(?<n>[A-Z0-9_]+)"'
  'env::var\s*\(\s*"(?<n>[A-Z0-9_]+)"'
  '\benv!\s*\(\s*"(?<n>[A-Z0-9_]+)"'
  '\benv\s*\(\s*"(?<n>[A-Z0-9_]+)"'
  'envp_set\s*\([^,]+,\s*"(?<n>[A-Z0-9_]+)"'
  'os\.environ(?:\.get)?\s*[\(\[]\s*"(?<n>[A-Z0-9_]+)"'
  '\$env\.(?<n>[A-Z0-9_]+)'
  '\$\{(?<n>[A-Z0-9_]+)[:\}\[]'
  '\$(?<n>[A-Z0-9_]+)\b'
  '"(?<n>[A-Z0-9_]+)"\s*:'
  '(?m)^\s*#\s*(?:define|ifdef|ifndef)\s+(?<n>[A-Z0-9_]+)'
]

const MAX_BYTES = 2000000

def walk-files [repo: string, bases: list<string>, extra: list<string>] {
  let ex = ($SKIP_DIRS | each {|d| $"**/($d)/**" })
  let from_dirs = ($bases | each {|b|
      let d = ($repo | path join $b)
      if not (($d | path exists) and (($d | path type) == "dir")) { return [] }
      glob $"($d)/**/*" --no-dir --no-symlink --exclude $ex
    } | flatten)
  let from_files = ($extra | each {|f|
      let p = ($repo | path join $f)
      if (($p | path exists) and (($p | path type) == "file")) { [$p] } else { [] }
    } | flatten)
  $from_dirs | append $from_files
}

def read-text [p: string] {
  let sz = (try { ls -a $p | first | get size | into int } catch { 0 })
  if $sz > $MAX_BYTES { return null }
  try { open --raw $p | decode utf-8 } catch { null }
}

def main [
  --expect-fiction: string = ""  # assert this name IS reported, to prove the check still fires
  --list-read                    # print every name found to be read, to inspect the read side
] {
  let repo = ($env.FILE_PWD | path dirname)
  let me = ($env.FILE_PWD | path join ($env.CURRENT_FILE | path basename) | str replace $"($repo)/" "")

  mut read = {}
  for p in (walk-files $repo $READING_DIRS []) {
    let text = (read-text $p)
    if $text == null { continue }
    # See the header: only names matching OURS survive, so a file naming none of the three
    # namespaces cannot contribute, and testing that first avoids thirteen regex invocations.
    if not ($NAMESPACES | any {|ns| $text | str contains $ns }) { continue }
    let rel = ($p | str replace $"($repo)/" "")
    for rx in $READS {
      for m in ($text | parse --regex $rx) {
        if ($m.n =~ $OURS) {
          let cur = ($read | get -o $m.n | default [])
          $read = ($read | upsert $m.n ($cur | append $rel | uniq))
        }
      }
    }
  }

  mut advertised = {}
  for p in (walk-files $repo $ADVERTISING_DIRS $ADVERTISING_FILES) {
    let rel = ($p | str replace $"($repo)/" "")
    if $rel == $me { continue }          # see the header: it must name the fiction
    let text = (read-text $p)
    if $text == null { continue }
    if not ($NAMESPACES | any {|ns| $text | str contains $ns }) { continue }
    for rx in $ADVERTISE {
      for m in ($text | parse --regex $rx) {
        if ($m.n =~ $OURS) {
          let cur = ($advertised | get -o $m.n | default [])
          $advertised = ($advertised | upsert $m.n ($cur | append $rel | uniq))
        }
      }
    }
  }

  if $list_read {
    for n in ($read | columns | sort) {
      print $"  read: ($n | fill -a left -w 34) ($read | get $n | sort | first)"
    }
  }

  let read_names = ($read | columns)
  let fiction = ($advertised | columns | where {|n| not ($n in $read_names) } | sort)

  print $"names advertised in our namespace: ($advertised | columns | length); read somewhere in first-party code: ($read | columns | length); advertised but read by nothing: ($fiction | length)"

  if ($expect_fiction | is-not-empty) {
    if ($expect_fiction in $fiction) {
      print $"PASS: ($expect_fiction) is still detected as advertised-but-unread, so the check can fire"
      exit 0
    }
    let why = (if ($expect_fiction in $read_names) { "it is read somewhere" } else { "it is not advertised" })
    print $"FAIL: expected ($expect_fiction) to be reported and it was not, because ($why). The check has stopped being able to detect this class."
    exit 1
  }

  if ($fiction | is-empty) {
    print "PASS: every advertised environment variable is read by something"
    exit 0
  }

  print $"\n($fiction | length) advertised names that nothing reads:"
  for n in $fiction {
    let where = ($advertised | get $n | sort | first 4 | str join ", ")
    print $"  ($n) -- set or documented in ($where)"
  }
  print "\nFAIL: setting one of these does nothing. A flag that silently has no effect sends an investigation the wrong way, which is how DARLING_XTRACE survived in nine places across five scripts without ever having been implemented."
  exit 1
}
