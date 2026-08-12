#!/usr/bin/env nu

# DOES THE DUMPED SOURCE UNION COVER EVERY QUOTED INCLUDE A COMPILED FILE MAKES?
#
# The narrowed per-target source set is built from what buck2 DECLARES, and a quoted include
# resolves against the including file's own directory, which buck2 never declares. Miss one and
# the narrowed build dies late with "file not found", 90 minutes in. cider-graph-dump closes that
# by taking the closure of quoted includes; this checks the closure actually holds, in seconds,
# against a built graph.
#
# TWO PATHS SINCE #56: the graph holds the actions, and the source closure is its own derivation
# over the real tree, because parsing a quoted include is the one thing here that reads file
# CONTENTS and the graph is now dumped from a skeleton.
#
#   scripts/buck-include-closure-check.nu <graph-store-path> <sources-store-path>
#
# Exit 0 when every compiled file's quoted includes are covered, 1 when any is not, 2 on
# infrastructure trouble.
#
# VERIFIED BOTH WAYS, which is the only reason to trust it: run against a graph dumped BEFORE
# the closure landed it reports five files (cctools/as/hppa-opcode.h, i860-opcode.h and
# sparc-opcode.h for the three otool disassemblers, man/man/catopen/catopen.c for gripes.c, which
# is a .c and not a header, and the OpenDirectory generated-stubs.h); after, it reports none.
#
# PORTED FROM PYTHON (#98), byte identical on the same inputs. TWO EXTERNAL TOOLS ARE KEPT ON
# PURPOSE, and they are the reason this is seconds rather than minutes: grep -o over the 147 MB
# graph.json, which nushell would have to parse whole to answer the same question, and ONE grep
# over the candidate files instead of 33,317 separate opens. Nushell per-invocation overhead is
# the cost that matters at this scale, so the loop that would pay it 33,317 times is the loop
# that does not exist.

const C_FAMILY = [".c" ".cc" ".cpp" ".cxx" ".m" ".mm" ".h" ".hpp" ".hh" ".inc"]

# Basenames that own a compile action, so a file nobody builds cannot fail the check.
#
# Count the identity FIELD, not a loose string match: the identity appears in more than one place
# per action and grepping loosely over-counts threefold.
def compiled-basenames [graph: string] {
  let out = (^grep -o '_compile [^"]*' ($graph | path join "graph.json") | complete)
  $out.stdout | lines | each {|l|
    let tok = (if ($l | str contains " ") { $l | split row " " | skip 1 | str join " " } else { "" })
    $tok | str trim --right --char ")" | path basename
  } | where {|b| $b != "" } | uniq
}

def main [graph?: string, sources?: string] {
  if ($graph | is-empty) or ($sources | is-empty) {
    print -e "usage: buck-include-closure-check.nu <graph-store-path> <sources-store-path>"
    exit 2
  }
  cd ($env.CURRENT_FILE | path dirname | path join "..")

  let sources_json = ($sources | path join "sources.json")
  if not ($sources_json | path exists) {
    print -e $"no sources.json in ($sources); pass the cider-buck2-sources output, not the graph"
    exit 2
  }
  let srcs = (open --raw $sources_json | from json | get projectSources)
  let compiled = (compiled-basenames $graph)
  print $"($srcs | length) declared source\(s\), ($compiled | length) compiled basename\(s\)"

  # MEMBERSHIP GOES THROUGH grep -Fx, NOT THROUGH A RECORD, and that is the difference between
  # seconds and minutes. Building one 58,506 key record with `reduce ... upsert` copies the
  # accumulator on every insert: MEASURED at 126.99 s of a 163 s run, against 1.58 s for the
  # whole python. Nushell has no hash set, so the set operations are done in one external pass
  # over a file instead of 58,506 interpreter operations.
  let dir_of = {|p| $p | path dirname }
  let declared_f = (mktemp -t --suffix .txt)
  let dirs_f = (mktemp -t --suffix .txt)
  $srcs | str join "\n" | save -f $declared_f
  $srcs | each {|s| $s | path dirname } | uniq | str join "\n" | save -f $dirs_f

  let compiled_f = (mktemp -t --suffix .txt)
  $compiled | str join "\n" | save -f $compiled_f
  # The candidates: C family, and a basename that owns a compile action. The basename test is
  # the same set membership, so it takes the same route.
  let bases_f = (mktemp -t --suffix .txt)
  let cfam = ($srcs | where {|rel| $C_FAMILY | any {|e| $rel | str ends-with $e } })
  $cfam | each {|s| $s | path basename } | str join "\n" | save -f $bases_f
  let wanted = (^bash -c $"grep -Fxn -f ($compiled_f) ($bases_f) | cut -d: -f1" | complete)
  rm -f $compiled_f $bases_f
  let candidates = ($wanted.stdout | lines | each {|i| $cfam | get (($i | into int) - 1) })

  # ONE grep OVER ALL OF THEM. The python opens each file; at this scale that loop would be the
  # whole runtime in nushell. The pattern is the python's, anchored per line, and grep prints
  # path:match so the owner of every include is known.
  let listfile = (mktemp -t --suffix .txt)
  $candidates | str join "\n" | save -f $listfile
  let hits = (^bash -c $"tr '\\n' '\\0' < ($listfile) | xargs -0 grep -H -o -E '^[ \\t]*#[ \\t]*include[ \\t]*\"[^\"]+\"' || true" | complete)
  rm -f $listfile

  let pairs = ($hits.stdout | lines | each {|line|
    let cut = ($line | split row ":" | first)
    # A RANGE WITH A COMPUTED START needs the start in a variable: an inline parenthesised
    # expression before `..` parses as an incomplete math expression.
    let from = (($cut | str length) + 1)
    let rest = ($line | str substring $from..)
    let target = ($rest | parse --regex '"(?<t>[^"]+)"' | get t? | get 0? | default "")
    if ($target | is-empty) {
      null
    } else {
      let res = ([($cut | path dirname) $target] | path join | path expand --no-symlink
        | str replace $"($env.PWD)/" "")
      { file: $cut, res: $res }
    }
  } | compact | where {|r|
    # A path that leaves the project is a system header by another name.
    let out = ($r.res | str starts-with "/") or ($r.res | str starts-with "..")
    not $out
  })

  # NOT DECLARED, then NOT COVERED BY A DECLARED DIRECTORY, both in one external pass each.
  let res_f = (mktemp -t --suffix .txt)
  $pairs | get res | uniq | str join "\n" | save -f $res_f
  let undeclared = (^bash -c $"grep -Fxv -f ($declared_f) ($res_f) || true" | complete)
  rm -f $res_f
  let u = ($undeclared.stdout | lines)
  let ud_f = (mktemp -t --suffix .txt)
  $u | each {|p| $p | path dirname } | uniq | str join "\n" | save -f $ud_f
  let nodir = (^bash -c $"grep -Fxv -f ($dirs_f) ($ud_f) || true" | complete)
  rm -f $ud_f $declared_f $dirs_f
  let bad_dirs = ($nodir.stdout | lines)

  mut gaps = []
  for r in ($pairs | where {|r| $r.res in $u }) {
    if not (($r.res | path dirname) in $bad_dirs) { continue }
    if not ($r.res | path exists) { continue }   # guarded out by the preprocessor
    $gaps = ($gaps | append { file: $r.file, needs: $r.res })
  }
  let gaps = ($gaps | uniq)

  if ($gaps | is-empty) {
    print "PASS: every compiled file's quoted includes are in the union"
    exit 0
  }
  print $"FAIL: ($gaps | length) quoted include\(s\) a COMPILED file makes are not in the union"
  for g in ($gaps | sort-by file needs) {
    print $"  ($g.file)\n      needs ($g.needs)"
  }
  print ""
  print "The dump should close these; see coarse target_sources and _quoted_includes in"
  print "cider-graph-dump, and task #44."
  exit 1
}
