#!/usr/bin/env nu

# DOES aquery's RENDERED COMMAND STILL ROUND-TRIP BACK INTO THE ARGV BUCK2 RAN?
#
# aquery hands back a command as one STRING, made by joining the real argv with ", ", and the
# graph dump splits that back apart. That is only sound while no single argument contains the
# separator, and it has been wrong exactly once: perl's versions.h passed VERSIONS as the C
# initializer ` "5.18", "5.28",`, so one argument came back as two and the Nix lowering died
# while the host, which never round-trips through the rendering, built it fine.
#
# TWO HALVES, and both are needed.
#
#   --static   every BUCK literal that carries the separator, and whether any of them is in a
#              rule that puts values into an argv. configure_file is the one that writes its
#              values to a FILE, so it is safe by construction and is the only allowance.
#   default    the real thing: build the configure_file targets, read what buck2 ACTUALLY RAN
#              out of what-ran, recover the same argvs from aquery the way the dump does, and
#              compare. That tests the assumption across the whole graph rather than a corner.
#
# TWO THINGS MAKE IT WORK, worth knowing before editing:
#   * its OWN isolation dir, because what-ran lists only actions that EXECUTED. Against the
#     normal daemon everything is cached, nothing runs, and the check reports zero comparable
#     actions while looking like it passed.
#   * with no arguments it asks uquery for every configure_file target rather than listing
#     them, so a new one is covered the day it is added.
#
# PORTED FROM PYTHON (#98). BYTE IDENTICAL in both modes on the same tree, and the unjoin rule
# is a four line COPY of the one in src/linux/buildtools/graph-specs/src/dump.rs on purpose: this
# check compares against what buck2 really ran, so it is checking the rule against reality
# rather than against another implementation of the split.
#
# THE STATIC HALF GOES THROUGH grep, not through a per-line loop: 125 BUCK files hold 175,450
# lines of which 107,825 carry a quote, and a nushell loop over those is a minute. grep reduces
# it to the handful of lines that actually carry a comma-space, and the exact python rule is
# then applied to those.

const ISO = ["--isolation-dir" "argvcheck"]
# The one rule whose values never reach an argv, because it writes them to a file.
const SAFE_RULE = "configure_file"

def buck2-run [...args: string] {
  let r = (do -i { ^buck2 ...$ISO ...$args } | complete)
  if $r.exit_code != 0 {
    print -e ($r.stderr | str substring (($r.stderr | str length) - 2000)..)
    print -e $"buck2 ($args | first 2 | str join ' ') failed"
    exit 1
  }
  $r.stdout
}

# aquery's `cmd` back into an argv. A COPY of the rule, four lines of it, and deliberately so:
# what it is checked against is what buck2 ACTUALLY RAN.
def unjoin [cmd: string] {
  let inner = ($cmd | str trim)
  # END EXCLUSIVE. `str substring a..b` INCLUDES b, so 1..(len - 1) keeps the closing bracket
  # and every recovered argv ends with one extra "]". The check caught it on the first real
  # run: 6 of 6 actions differed, and the diff was that single character.
  let body = (if ($inner | str starts-with "[") and ($inner | str ends-with "]") {
    $inner | str substring 1..<(($inner | str length) - 1)
  } else { $inner })
  if ($body | is-empty) { [] } else { $body | split row ", " }
}

def static-scan [] {
  # ONE grep for the lines that could possibly matter, then the python rule on those only.
  # THE PATTERN IN A VARIABLE, NEVER INSIDE AN INTERPOLATION: `\(` inside $"..." opens an
  # interpolation, so a regex with an escaped paren in it cannot be written that way, and the
  # parse error says "Unexpected end of code, expected closing '".
  let pat = '"[^"]*, [^"]*"'
  let hits = (do -i { ^grep -rHnE $pat --include=BUCK . } | complete)
  mut total = 0
  mut bad = []
  for line in ($hits.stdout | lines | where {|l|
      not (($l | str starts-with "./buck-out/") or ($l | str starts-with "./.jj/")
        or ($l | str starts-with "./.git/") or ($l | str starts-with "./.direnv/")) }) {
    let parts = ($line | split row ":")
    let path = ($parts | first)
    let lineno = ($parts | get 1 | into int)
    let from = (($path | str length) + ($parts | get 1 | str length) + 2)
    let text = ($line | str substring $from..)
    # python skips a comment line by its LEFT-STRIPPED first character.
    if ($text | str trim | str starts-with "#") { continue }
    # Every literal on the line, the same regex python uses, so a line with two counts twice.
    for m in ($text | parse --regex '"(?<v>(?:[^"\\]|\\.)*)"') {
      if not ($m.v | str contains ", ") { continue }
      $total += 1
      let rule = (enclosing-rule $path $lineno)
      if $rule != $SAFE_RULE {
        $bad = ($bad | append { path: $path, line: $lineno, rule: $rule, v: ($m.v | str substring 0..<70) })
      }
    }
  }
  print $"BUCK literals carrying the argv separator: ($total)"
  print $"  in ($SAFE_RULE) \(safe, passed in a file\):  ($total - ($bad | length))"
  print $"  in a rule that puts them in an argv:      ($bad | length)"
  if ($bad | is-not-empty) {
    print "\nFAIL: an argument would carry the ', ' aquery joins on, so the Nix"
    print "lowering would replay a DIFFERENT command than buck2 ran. Pass the value"
    print "through a file, the way configure_file does.\n"
    for b in ($bad | first 8) { print $"  ($b.path):($b.line)  in ($b.rule)\(\): ($b.v)" }
    return 1
  }
  print "\nok: no argv-bound literal carries the separator"
  0
}

# The rule a line sits in: the LAST line at or above it that opens one. python carries this as
# state through a per-line walk; here it is one grep over the same file, which is the same
# answer for a fraction of the work.
def enclosing-rule [path: string, lineno: int] {
  let rule_pat = '^[a-z_][a-z0-9_]*\('
  let starts = (do -i { ^grep -nE $rule_pat $path } | complete)
  let before = ($starts.stdout | lines | each {|l|
      let n = ($l | split row ":" | first | into int)
      { n: $n, rule: ($l | parse --regex '^[0-9]+:(?<r>[a-z_][a-z0-9_]*)\(' | get r? | get 0? | default "") }
    } | where {|r| $r.n <= $lineno })
  if ($before | is-empty) { "" } else { $before | last | get rule }
}

def main [--static, ...targets: string] {
  cd ($env.CURRENT_FILE | path dirname | path join "..")
  if $static {
    exit (static-scan)
  }

  let tg = (if ($targets | is-empty) {
    # configure_file is the rule that puts free-form VALUES into an argv, so it is where a
    # comma-space can occur. Asked for rather than listed, so a new one is covered.
    let found = (buck2-run "uquery" "kind('configure_file', //...)" | split row --regex '\s+'
      | where {|t| $t != "" })
    print -e $"== ($found | length) configure_file target\(s\) =="
    $found
  } else { $targets })
  if ($tg | is-empty) {
    print -e "no targets to check"
    exit 0
  }

  # The build has to happen in the SAME invocation whose what-ran is then read: the log is
  # per-invocation, so reading it after some other command reports that command instead.
  print -e $"== building ($tg | str join ' ') so what-ran has the real argvs =="
  do -i { ^buck2 ...$ISO build ...$tg } | complete | ignore

  print -e "== reading what buck2 actually ran =="
  mut truth = {}
  for line in (buck2-run "log" "what-ran" "--format" "json" | lines) {
    let l = ($line | str trim)
    if ($l | is-empty) { continue }
    let ev = ($l | from json)
    let cmd = ($ev.reproducer?.details?.command?)
    if $cmd != null {
      $truth = ($truth | upsert $ev.identity $cmd)
    }
  }
  if ($truth | columns | is-empty) {
    print -e "what-ran is empty; nothing to verify"
    exit 0
  }

  print -e "== recovering the same argvs the way the dump does =="
  let query = $"deps\(($tg | str join ' + ')\)"
  let aq = (buck2-run "aquery" "--output-all-attributes" "--json" $query | from json)
  mut recovered = {}
  for node in ($aq | columns) {
    let at = ($aq | get $node)
    let cmd = ($at.cmd? | default "")
    if ($cmd | is-empty) { continue }
    let target = (if ($node | str contains "target: `") {
      $node | split row "target: `" | last | split row "`" | first
    } else { $node | split row "`" | first })
    let identity = ($"($target) \(($at.category? | default "") ($at.identifier? | default ""))"
      | str replace --all " )" ")")
    $recovered = ($recovered | upsert $identity (unjoin $cmd))
  }

  let common = ($truth | columns | where {|i| ($recovered | get -o $i) != null } | sort)
  let bad = ($common | where {|i| ($truth | get $i) != ($recovered | get $i) })

  print $"\nactions that ran:      ($truth | columns | length)"
  print $"actions aquery renders: ($recovered | columns | length)"
  print $"comparable:            ($common | length)"
  print $"matching:              (($common | length) - ($bad | length))"

  if ($bad | is-not-empty) {
    print $"\nFAIL: ($bad | length) action\(s\) do NOT round-trip through the ', ' join."
    print "An argument contains the separator, so the Nix lowering would replay a"
    print "DIFFERENT command than buck2 ran. Fix the RULE so the argument cannot carry"
    print "a comma-space (see configure_file in buck/rules/codegen.bzl), rather than"
    print "teaching unjoin to guess where the boundaries were.\n"
    for ident in ($bad | first 5) {
      print $"  ($ident)"
      print $"    ran:       ($truth | get $ident)"
      print $"    recovered: ($recovered | get $ident)"
    }
    exit 1
  }
  if ($common | is-empty) {
    print "\nnothing comparable: the build was fully cached and reported no actions"
    exit 0
  }
  print $"\nok: all ($common | length) comparable actions round-trip exactly"
  exit 0
}
