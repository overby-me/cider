#!/usr/bin/env nu

# DOES OUR RENAME STILL LEAVE UPSTREAM ABLE TO REFER TO US? (#84)
#
# A pin names something Darling-flavoured, we renamed our side to Cider, and nothing connects
# them any more:
#
#     #include <darlingserver/rpc.h>          we shipped ciderd/rpc.h
#     #include <darling/emulation/...>        we staged cider/emulation/...
#     #include <darling-config.h>             we generated cider-config.h
#     __darling_thread_create(...)            we defined __cider_thread_create
#
# None of these is a compile error in OUR tree. They fail only where an upstream file is
# compiled against our headers, which on the nix endpoint is an hour in, one at a time, each
# costing a full rebuild. Three of them were found by this check in minutes.
#
# THE TEST: for every token a pin references that contains darling, compute the Cider form. If
# our tree contains that Cider form AT ALL, upstream has been orphaned and the name must go
# back. "At all" rather than "unless a Darling spelling also survives", because a negative
# control FAILED TO FAIL under the weaker rule: re-breaking __darling_thread_create in one of
# its two files left the other spelling intact and it reported PASS while the build was broken.
#
# THE MATCHING RULES ARE SCARS, EVERY ONE OF THEM. Do not simplify them:
#   the token class holds . and - , or darling-config.h hides among 184,642 bare hits
#   DARLING all-caps is a THIRD spelling, and the pattern that missed it held 54 tokens with
#     not one uppercase among them
#   an ASSEMBLY symbol carries an extra leading underscore that the C spelling does not, so
#     __cider_x is also tried as _cider_x
#   the TRAILING boundary stops _cider_bsd_syscall_entry matching our own
#     _cider_bsd_syscall_entry_trampoline, six false alarms in one run
#   the LEADING boundary allows -D, because -DLIBSIMPLE_DARLING=1 was invisible without it and
#     cost an hour-long endpoint run on 2026-08-10
#   the SUBSTRING TEST RUNS FIRST, and that is where all the time went: the regex opens on an
#     alternation of lookbehinds, so the engine tests one at every position of a 39 MB string.
#     Only six of 120 tokens have their cider form present at all. 235.3 s against 11.9 s, with
#     identical results.
#
# THE CACHE IS BOUND TO THE MANIFEST THAT PRODUCED IT and a mismatch REFUSES rather than warns,
# exit 2 rather than 1, so "the audit failed" and "the audit could not be trusted" are never
# confused. Refreshing reads about 100k pin files and takes four minutes.
#
#   scripts/buck-upstream-names-check.nu
#   scripts/buck-upstream-names-check.nu --refresh
#   scripts/buck-upstream-names-check.nu --ours-root <dir>   # audit a tree that is not ours
#
# PORTED FROM PYTHON (#98). BYTE IDENTICAL on the real tree and on a planted control. --ours-root
# is what makes the control possible without editing linux/ or darwin/: point it at a directory
# holding one file that spells a name the Cider way and the check must name it.

const OURS = ["src" "linux" "darwin"]
const SRC_EXT = [".c" ".h" ".cpp" ".m" ".mm" ".S" ".rs"]
# . and - are IN the class on purpose, and DARLING is a separate branch: see the header.
const TOKEN_PAT = '[A-Za-z0-9_.-]*(?:DARLING|[Dd]arling)[A-Za-z0-9_.-]*'
# Bare project references and upstream's own org and product names: prose or upstream identity,
# not something we renamed a counterpart of.
const IGNORE = ["darling" "Darling" "DARLING" "darlinghq" "darling." "Darling." "DARLING."
                "darlingC"]

# Every manifest entry whose directory exists on disk, wherever it sits. A PIN MATERIALIZED
# INSIDE OURS IS STILL UPSTREAM: pins/ciderd/xnu-sys/xnu lands inside the tree this file treats
# as ours, and counting it as ours put two Apple names on a rename list.
def materialized-pins [] {
  let manifest = "nix/submodules.json"
  if not ($manifest | path exists) { return [] }
  let entries = (open --raw $manifest | from json)
  $entries | each {|e| $e.path? | default "" } | where {|p| $p != "" }
    | where {|p| ($p | path type) == "dir" }
    | each {|p| $p | path expand --no-symlink }
}

# Everything the cached token set depends on, hashed together: the manifest CONTENT, the token
# pattern and the ignore list. The pattern is in here because widening it without refreshing
# would leave the check reporting PASS over the very class the widening was meant to catch.
def manifest-fingerprint [] {
  let m = (if ("nix/submodules.json" | path exists) {
    open --raw nix/submodules.json | into binary
  } else { "no-manifest" | into binary })
  # BYTE FOR BYTE what the python hashed: manifest content, a NUL and the pattern, a NUL and
  # the ignore list joined by NULs. A different separator is a different fingerprint and every
  # cache in existence would read as stale.
  mut ib = ("" | into binary)
  for it in (($IGNORE | sort) | enumerate) {
    if $it.index > 0 { $ib = ($ib ++ 0x[00]) }
    $ib = ($ib ++ ($it.item | into binary))
  }
  let blob = ($m ++ 0x[00] ++ ($TOKEN_PAT | into binary) ++ 0x[00] ++ $ib)
  $blob | hash sha256
}

# THE FILE LIST THROUGH find, NOT bash -c, and not through an interpolated string: `\(` inside
# $"..." opens an interpolation, so a find expression with escaped parens cannot be written that
# way. Three -prune clauses chained with -o say the same thing as one parenthesised group.
def file-list [roots: list<string>] {
  let args = ($roots | where {|r| ($r | path type) == "dir" })
  if ($args | is-empty) { return [] }
  # ONE LINE: an external command does not continue across a line break, and the parse error
  # for that is the unhelpful "Parse mismatch during operation".
  let found = (do -i { ^find ...$args -type d -name .git -prune -o -type d -name .jj -prune -o -type d -name buck-out -prune -o -type f -print } | complete)
  $found.stdout | lines | where {|p| $SRC_EXT | any {|e| $p | str ends-with $e } }
}

def main [--refresh, --ours-root: string = ""] {
  cd ($env.CURRENT_FILE | path dirname | path join "..")
  let pins = (materialized-pins)

  let cache = "buck-out/upstream-name-tokens.json"
  let want = (manifest-fingerprint)
  mut tokens = {}
  mut cached = false
  if (not $refresh) and ($cache | path exists) {
    let blob = (open --raw $cache | from json)
    let got = ($blob.manifest? | default null)
    let toks = ($blob.tokens? | default null)
    if $toks != null and $got == $want {
      $tokens = $toks
      $cached = true
    } else {
      let why = (if $toks == null {
        "was written by an older version that recorded no fingerprint"
      } else {
        $"was built from a DIFFERENT manifest or token pattern \(($got | str substring 0..<12)... not ($want | str substring 0..<12)...\)"
      })
      print $"STALE CACHE: buck-out/upstream-name-tokens.json ($why)."
      print "Either the pins have moved or the pattern has widened since it was built, so auditing against it would compare our tree to the PREVIOUS upstream revision, or through the PREVIOUS pattern, and report PASS about names it never read. Re-run with --refresh (about four minutes)."
      exit 2
    }
  }
  if not $cached {
    # THE PIN SCAN. One find and one grep -o over about 100k files: a per-file open in nushell
    # is the whole runtime at this scale, which is the lesson every other port here paid for.
    let pin_files = (file-list ["buck-src"])
    let listfile = (mktemp -t --suffix .txt)
    ($pin_files | append (file-list $pins)) | str join "\n" | save -f $listfile
    let hits = (^bash -c $"tr '\\n' '\\0' < ($listfile) | xargs -0 grep -h -o -E '($TOKEN_PAT)' || true" | complete)
    rm -f $listfile
    mut counts = {}
    for tok in ($hits.stdout | lines) {
      if $tok in $IGNORE { continue }
      $counts = ($counts | upsert $tok (($counts | get -o $tok | default 0) + 1))
    }
    $tokens = $counts
    mkdir buck-out
    { manifest: $want, tokens: $tokens } | to json | save -f $cache
  }
  if $cached {
    print "pin tokens read from cache, fingerprint verified against the manifest and the token pattern"
  }
  print $"pin trees materialized inside our tree: ($pins | length)"

  # OUR SIDE. The file LIST, not one concatenated string, and the reason is a measurement that
  # invalidates the obvious implementation: see the boundary test below.
  let ours_roots = (if ($ours_root | is-empty) { $OURS } else { [$ours_root] })
  let all = (file-list $ours_roots)
  let kept = ($all | where {|p|
    let full = ($p | path expand --no-symlink)
    not ($pins | any {|t| $full | str starts-with $"($t)/" })
  })
  let skipped = (($all | length) - ($kept | length))
  let listfile = (mktemp -t --suffix .txt)
  $kept | str join "\n" | save -f $listfile
  print $"files under ($ours_roots | str join '/') skipped as materialized pin content: ($skipped)"

  # EVERY CANDIDATE FORM, then two passes over the files: the same two stages the python has,
  # for the same reason, and with the boundary test done by grep.
  #
  # NUSHELL LOOKAROUND IS UNSOUND ABOVE ABOUT HALF A MEGABYTE, MEASURED. `$big =~
  # 'zzq_no_such_token_here(?![A-Za-z0-9_])'` returns TRUE on a 1 MB string where the same
  # pattern without the lookahead returns false, and false at 400,000 characters. The first
  # version of this port used the python's lookbehind-alternation regex against the 37 MB
  # concatenation and reported SIX orphans that do not exist, all of them our own
  # _cider_bsd_syscall_entry_trampoline, which is precisely the false-alarm class the trailing
  # boundary exists to prevent. grep has no such limit and needs no lookaround: (^|[^w]|-D) as
  # a leading alternative says the same thing as the lookbehind pair.
  mut forms_of = {}
  for row in ($tokens | transpose tok uses) {
    let cider = ($row.tok | str replace --all "darling" "cider" | str replace --all "Darling" "Cider"
      | str replace --all "DARLING" "CIDER")
    if $cider == $row.tok { continue }
    # An ASSEMBLY symbol carries one extra leading underscore that the C spelling does not.
    let forms = (if ($cider | str starts-with "__") { [$cider ($cider | str substring 1..)] } else { [$cider] })
    $forms_of = ($forms_of | upsert $row.tok $forms)
  }
  let all_forms = ($forms_of | values | flatten | uniq)
  let formfile = (mktemp -t --suffix .txt)
  $all_forms | str join "\n" | save -f $formfile
  # STAGE ONE, the substring test: one fixed-string pass over every file. grep -F -o prints the
  # literal it matched, so the result IS the set of forms present anywhere.
  let present = (^bash -c $"tr '\\n' '\\0' < ($listfile) | xargs -0 grep -F -o -h -f ($formfile) 2>/dev/null | sort -u || true" | complete)
  let present_set = ($present.stdout | lines | where {|l| $l != "" })
  rm -f $formfile

  # STAGE TWO, the boundary test, only for the handful that survive stage one.
  mut orphaned = []
  for row in ($tokens | transpose tok uses | sort-by uses --reverse) {
    let forms = ($forms_of | get -o $row.tok)
    if $forms == null { continue }
    let hit = ($forms | where {|f|
      if not ($f in $present_set) { false } else {
        let esc = ($f | str replace --all "." "\\.")
        let pat = "(^|[^A-Za-z0-9_]|-D)" + $esc + "([^A-Za-z0-9_]|$)"
        let r = (^bash -c $"tr '\\n' '\\0' < ($listfile) | xargs -0 grep -l -E ($pat | to json) 2>/dev/null | head -1" | complete)
        ($r.stdout | str trim | is-not-empty)
      }
    } | get 0? | default null)
    if $hit != null {
      $orphaned = ($orphaned | append { tok: $row.tok, cider: $hit, uses: $row.uses })
    }
  }
  rm -f $listfile


  print $"pin tokens containing darling: ($tokens | columns | length)"
  if ($orphaned | is-empty) {
    print "PASS: no upstream name has been orphaned by the rename"
    exit 0
  }
  print $"\n($orphaned | length) upstream names have no counterpart in our tree:"
  for o in $orphaned {
    print $"  pins use ($o.tok) \(($o.uses) times\); our tree still spells it ($o.cider)"
  }
  print "\nFAIL: upstream keeps its own names, so ours must match where it references us."
  print "Rename our side back, or provide the name upstream asks for."
  exit 1
}
