#!/usr/bin/env nu

# WIRE EACH xtrace MIG STUB TO THE mig_gen TARGET WHOSE OUTPUT DIRECTORY HOLDS ITS SOURCE.
#
# Every MIG protocol in the reference also produces a <stem>XtraceMig.c, compiled into its own
# little dylib that xtrace dlopens to decode that protocol messages. The source is generated, so
# the stub cannot be generated from sources alone: this maps each `*_xtrace_mig` object library
# to the mig_gen target whose output directory holds that file, sets that target xtrace_srcs,
# and records the gen: entry so the object library depends on the generated source.
#
# Usage:
#   scripts/gen-xtrace-mig.nu --dry-run     # report only, changes nothing
#   scripts/gen-xtrace-mig.nu               # WRITES: see the warning below
#
# IT WRITES BY DEFAULT, and that is inherited from the python rather than chosen. Running it
# with no arguments rewrites buck/generated/extra-deps.json and the mig_gen blocks in three BUCK
# files. That cost a restore during this port: the census said the file was "guarded" because it
# contains the string --dry-run, which says nothing about which way the default falls.
#
# PORTED FROM PYTHON (#98). THE GATE IS --dry-run, BYTE IDENTICAL: 31 wired stubs and 11
# unmatched, in the same order, naming the same targets. The WRITE path is transcribed and NOT
# gated, for a reason worth stating rather than hiding: running it does not reproduce the
# committed files. The python itself rewrites 84 lines and removes 69 across buck-src/BUCK,
# darwin/launchd/BUCK, pins/ciderd/xnu-sys/BUCK and extra-deps.json, so the committed generated
# blocks have drifted from what this produces, and comparing two implementations of the write
# would compare them against a moving target. That drift is recorded in docs/monorepo-port.md
# and is a decision for whoever regenerates those files.
#
# TWO REDUCTIONS, and they are what make this seconds rather than minutes: the reference
# build.ninja is 131 MB and 362,663 lines, of which 254 mention an xtrace mig object at all, and
# only THREE BUCK files in the tree contain a mig_gen call. Both are found with grep before
# nushell reads anything.

const GRAPH = "result-graph-ref/build.ninja"
const EXTRA_DEPS = "buck/generated/extra-deps.json"
const SKIP_DIRS = ["buck-out" ".git" ".jj" ".direnv" "build"]

# gen-buck-from-ninja.orig_repo_rel: the path as it is relative to the repo root, whatever tree
# it lives in. BOTH SPELLINGS of the store name, because the reference is a frozen cmake-era
# artifact that the #84 rename could not reach.
const SRC_STORE_RE = '/nix/store/[a-z0-9]{32}-(cider|darling)-cmake-src'
const BIN_DIR = "/build/build"

def say [msg: string] { print $msg }

def orig-repo-rel [p: string] {
  ($p | str replace --regex $SRC_STORE_RE "" | str replace $BIN_DIR ""
    | str trim --left --char "/" | path expand --no-symlink
    | str replace ($env.PWD + "/") "")
}

# {lib: [source]} for every *_xtrace_mig object library in the reference, from the build edges.
def xtrace_stubs [] {
  let lines = (^grep -F "_xtrace_mig.dir/" $GRAPH | complete | get stdout | lines
    | where {|l| $l | str starts-with "build " })
  mut out = []
  for l in $lines {
    let body = ($l | str substring 6..)
    let ix = ($body | str index-of ": ")
    if $ix < 0 { continue }
    let head = ($body | str substring 0..<$ix)
    let after = ($ix + 2)
    let rest = ($body | str substring $after..)
    let sp = ($rest | str index-of " ")
    let inputs = (if $sp < 0 { [] } else {
      $rest | str substring ($sp + 1).. | split row " "
        | where {|i| $i != "" and $i != "|" and $i != "||" }
    })
    for o in ($head | split row " | " | first | split row " " | where {|x| $x != "" }) {
      if not ($o | str ends-with ".o") { continue }
      let m = ($o | parse --regex 'CMakeFiles/(?<lib>[A-Za-z0-9_.-]+_xtrace_mig)\.dir/')
      if ($m | is-empty) { continue }
      let lib = ($m | get lib.0)
      for i in $inputs {
        if ($i | str ends-with "XtraceMig.c") {
          $out = ($out | append { lib: $lib, src: (orig-repo-rel $i) })
        }
      }
    }
  }
  $out | uniq
}

# [{label, path, span, defs, out_base, arch, multiarch}] for every mig_gen in the tree.
def mig-targets [] {
  let prune = ($SKIP_DIRS | each {|d| ["-name" $d "-o"] } | flatten | drop 1)
  let bucks = (^find . ...( $prune | prepend "(" | append ")" ) -prune -o -name BUCK -print
    | complete | get stdout | lines | where {|l| $l != "" }
    | each {|p| $p | str substring 2.. })
  let listf = (mktemp -t --suffix .txt)
  $bucks | str join "\n" | save -f $listf
  # THE PATTERN CANNOT GO INSIDE $"...", and this one is the reason to keep saying so: the
  # string it needs is mig_gen( with an UNBALANCED parenthesis, and inside an interpolation that
  # paren opens an expression which never closes. The parse error is "Unexpected end of code"
  # and it names the whole file, not the line.
  # xargs -a WITH -d newline, so there is no tr and no NUL: a nushell double quoted string
  # cannot carry a literal backslash-zero, and writing it as an escape is "Invalid literal".
  let cmd = ("xargs -d '\n' -a " + $listf + " grep -lF " + ("'" + "mig_gen(" + "'")
    + " 2>/dev/null || true")
  let withmig = (^bash -c $cmd | complete | get stdout | lines | where {|l| $l != "" })
  rm -f $listf

  mut found = []
  for path in $withmig {
    let pkg = ($path | path dirname)
    let text = (open --raw $path | decode utf-8)
    # The python regex is mig_gen\(\n(?:.*?\n)*?\)\n, a NON GREEDY run of whole lines up to the
    # first line that is exactly a closing paren. (?s) with a lazy .*? says the same thing.
    mut pos = 0
    loop {
      let rest = ($text | str substring $pos..)
      let ix = ($rest | str index-of "mig_gen(\n")
      if $ix < 0 { break }
      let from = ($ix + 9)
      let tail = ($rest | str substring $from..)
      let endix = ($tail | str index-of "\n)\n")
      if $endix < 0 { break }
      let blk = ("mig_gen(\n" + ($tail | str substring 0..<($endix + 3)))
      let start = ($pos + $ix)
      let stop = ($start + ($blk | str length))
      $pos = $stop
      let name = ($blk | parse --regex 'name = "(?<v>[^"]+)"')
      let defs = ($blk | parse --regex 'defs = "(?<v>[^"]+)"')
      if ($name | is-empty) or ($defs | is-empty) { continue }
      let base = ($blk | parse --regex 'out_base = "(?<v>[^"]*)"')
      let arch = ($blk | parse --regex 'arch = "(?<v>[^"]+)"')
      $found = ($found | append {
        label: $"//($pkg):($name | get v.0)"
        path: $path
        span_start: $start
        span_end: $stop
        defs: ($defs | get v.0)
        out_base: (if ($base | is-empty) { "" } else { $base | get v.0 })
        arch: (if ($blk | str contains 'arch = "') and ($arch | is-not-empty) { $arch | get v.0 } else { "" })
        multiarch: (($blk | str contains "-x86_64-") or ($blk | str contains "-i386-"))
      })
    }
  }
  $found
}

def main [--dry-run] {
  cd ($env.CURRENT_FILE | path dirname | path join "..")
  let stubs = (xtrace_stubs)
  let migs = (mig-targets)

  # {lib: sorted sources}, in sorted lib order, which is python's sorted(stubs.items()).
  let by_lib = ($stubs | group-by lib | transpose lib rows | sort-by lib
    | each {|r| { lib: $r.lib, srcs: ($r.rows | get src | uniq | sort) } })

  mut wired = []
  mut unmatched = []
  mut extra_pairs = []
  for e in $by_lib {
    # The generated file, e.g. .../src/launchd/liblaunch/jobXtraceMig.c
    let src = ($e.srcs | first)
    let stem = ($src | path basename)
    # `src` is the full generated path; the instance is the mig target whose out_base plus the
    # relative stem lands exactly there.
    let rel = ($src | str replace --regex '^pins/' "")
    let want_stem = ($stem | str replace --regex 'XtraceMig\.c$' "")
    # ONE LINE PER CONDITION, JOINED BY A HELPER, because `and` may not START a continuation
    # line: nushell reads it as a command name and says "Command `and` not found".
    mut cands = ($migs | where {|t| (stem-single $t $want_stem) and (out-rel-matches $t $rel) })
    if ($cands | is-empty) {
      $cands = ($migs | where {|t| (stem-single $t $want_stem) and (dir-tail-matches $t $rel) })
    }
    if ($cands | is-empty) {
      $unmatched = ($unmatched | append { lib: $e.lib, src: $src })
      continue
    }
    let t = ($cands | first)
    # The name must be relative to the mig OUTPUT DIR, not a bare basename: the runner writes
    # $outdir/<stem><suffix>, and the stem keeps the protocol's own subdirectory. out_base is
    # PACKAGE-relative, so the generated path has to be made package-relative first.
    let pkg = ($t.path | path dirname)
    let pkg_rel = (if $pkg == "buck-src" {
      $src | str replace --regex '^pins/' ""
    } else {
      $src | str replace --regex $"^($pkg)/" ""
    })
    let base = ($t.out_base | str trim --right --char "/")
    let out_name = (if ($base != "") and ($pkg_rel | str starts-with $"($base)/") {
      $pkg_rel | str substring (($base | str length) + 1)..
    } else { $stem })
    $extra_pairs = ($extra_pairs | append { lib: $e.lib, label: $t.label, out_name: $out_name, path: $t.path, start: $t.span_start, end: $t.span_end })
    $wired = ($wired | append { lib: $e.lib, label: $t.label })
  }

  if $dry_run {
    for w in $wired {
      say $"  ($w.lib | fill --alignment l --width 34) <- ($w.label)"
    }
    say $"($wired | length) wired, ($unmatched | length) unmatched"
    for u in $unmatched { say $"  UNMATCHED ($u.lib): ($u.src)" }
    exit 0
  }

  # FROM HERE DOWN IS TRANSCRIBED AND NOT GATED. See the header: the python write path does not
  # reproduce the committed files either, so there is no fixed point to compare against.
  for path in ($extra_pairs | get path | uniq) {
    mut text = (open --raw $path | decode utf-8)
    # Back to front so the spans stay valid.
    for it in ($extra_pairs | where path == $path | sort-by --custom {|a, b| $a.start > $b.start }) {
      mut blk = ($text | str substring $it.start..<$it.end)
      if ($blk | str contains "xtrace_srcs") {
        $blk = ($blk | str replace --regex '    xtrace_srcs = \[[^\]]*\],\n' "")
      }
      $blk = ($blk | str replace "    mig_sh =" $"    xtrace_srcs = [\"($it.out_name)\"],\n    mig_sh =")
      $text = ($text | str substring 0..<$it.start) + $blk + ($text | str substring $it.end..)
    }
    $text | save -f $path
  }
  mut extra = (open $EXTRA_DEPS)
  for it in $extra_pairs {
    $extra = ($extra | upsert $it.lib [$"gen:($it.label)[xtrace]" "//darwin/xtrace:xtrace_headers"])
  }
  (($extra | to json --indent 2) + "\n") | save -f $EXTRA_DEPS
  say $"wired ($wired | length) xtrace stubs; ($unmatched | length) unmatched"
  for u in $unmatched { say $"  UNMATCHED ($u.lib): ($u.src)" }
  say ("now run: scripts/gen-buck-from-ninja.py --write " + ($wired | get lib | str join " "))
  exit 0
}

# The two conditions every candidate shares: the defs stem matches and the target is not a
# multiarch one.
def stem-single [t: record, want_stem: string] {
  let stem_ok = (($t.defs | path basename | str replace --regex '\.defs$' "") == $want_stem)
  ($stem_ok and (not $t.multiarch))
}

# The fallback rule: the generated path's directory ends with the defs directory's last
# component.
def dir-tail-matches [t: record, rel: string] {
  let tail = (($t.defs | path dirname) | split row "/" | last)
  (($rel | path dirname) | str ends-with $tail)
}

# The first candidate rule: out_base plus the defs path, with .defs swapped for XtraceMig.c,
# has to land on the same file the object library compiles.
def out-rel-matches [t: record, rel: string] {
  let base = ($t.out_base | str trim --right --char "/")
  let defs_rel = $t.defs
  let out_rel = (if ($base != "") and ($defs_rel | str starts-with $"($base)/") {
    [$base ($defs_rel | str substring (($base | str length) + 1)..)] | path join
  } else { $defs_rel })
  let final = ($out_rel | str replace --regex '\.defs$' "") + "XtraceMig.c"
  ($final == $rel) or ($final | str ends-with $"/($rel)") or ($rel | str ends-with $"/($final)")
}
