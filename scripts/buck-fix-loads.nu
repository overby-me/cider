#!/usr/bin/env nu
# Make every BUCK file load exactly the rules it uses.
#
# Generated targets get appended to whatever BUCK file owns their sources, and that file load
# statements rarely already name the rules the new block needs. Rather than teaching every
# generator to merge load lines, this fixes them all after the fact.
#
#   scripts/buck-fix-loads.nu            # rewrite
#   scripts/buck-fix-loads.nu --check    # exit 1 and name what WOULD change
#
# THE RULE MAP IS READ FROM THE RULE FILES, never listed here. This script STRIPS every
# //buck/rules: load and re-adds only the rules it knows about, so a rule missing from the map
# has its load silently deleted from any file the script touches. A hand-kept list guarantees
# that happens every time a rule is added: it took out buck/prefix/BUCK prefix_tree load, and
# then darwin/tools stdout_gen. Deriving the map from `<name> = rule(` in buck/rules/*.bzl
# cannot drift.
#
# PORTED FROM PYTHON (#98) and gated byte for byte against it: both implementations were run
# over a MIRROR of the tree holding buck/rules and all 125 BUCK files, pristine and mutated, in
# --check and in write mode, and the resulting trees compared file by file.

const SKIP_DIRS = ["buck-out", ".git", ".jj", ".direnv", "build"]

# `<name> = rule(` at the start of a line. The python uses \s*, which matches a newline, so a
# definition split across lines would count there and not here; the gate compares the two maps
# on the real buck/rules and they agree on all 25.
const RULE_DEF = '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*rule\('

# Only the loads this script manages. A BUCK file may load other things, buck-src/BUCK loads the
# generated SDK header maps, and dropping those breaks it.
const STRIP_LOAD = '(?m)^load\("//buck/rules:[^)]*\)\n'

# NUSHELL =~ WITH A \b IN THE PATTERN IS UNSOUND ON A BIG HAYSTACK, and this script is where it
# was caught. On buck-src/BUCK, 2,068,911 bytes after the loads are stripped:
#     $body =~ 'cc_library'            false   (correct, the name is not in the file)
#     $body =~ '\bcc_library\s*\('     TRUE    (wrong, and it is the same haystack)
# The literal is fine and the bounded pattern is not, so it FAILS OPEN: the first version of
# this port added loads for nine rules the file never uses, and every one of them would have
# been a load of a rule that is not called. At 400 KB the same test is still correct, which
# lines up with the half-a-megabyte note already in the repo about lookaround.
# So the membership test goes to grep, which is also where the measured rule wanted it.

def rules-map [repo: string] {
  let d = ($repo | path join "buck" "rules")
  let files = (ls $d | get name | where {|f| ($f | str ends-with ".bzl") } | sort)
  let out = ($files | each {|f|
    # The hot loop is grep, per the measured rule: one process per rule file, not one regex per
    # line inside nushell.
    let hits = (^grep -oE $RULE_DEF $f | complete)
    let names = ($hits.stdout | lines | each {|l|
      $l | split row "=" | get 0 | str trim
    } | uniq | sort)
    if ($names | is-empty) { [] } else { [{ bzl: ("//buck/rules:" + ($f | path basename)), rules: $names }] }
  } | flatten)
  if ($out | is-empty) {
    print -e "no rules found under buck/rules -- refusing to strip every load"
    exit 1
  }
  $out
}

def buck-files [repo: string] {
  # Directory names pruned at ANY depth, which is what the python dirnames filter does. find does
  # not follow symlinked directories, and neither does os.walk.
  # Built by hand rather than by a fold: find wants -o BETWEEN the -name terms, and leaving it
  # out is a prune expression that silently matches nothing.
  mut expr = ["("]
  mut first = true
  for d in $SKIP_DIRS {
    if not $first { $expr = ($expr | append "-o") }
    $expr = ($expr | append ["-name" $d])
    $first = false
  }
  $expr = ($expr | append [")" "-prune" "-o" "-name" "BUCK" "-type" "f" "-print"])
  let r = (^find $repo ...$expr | complete)
  $r.stdout | lines | where {|l| $l != "" } | sort
}

# One BUCK file. Returns true when its loads are not what the rules it uses require.
def fix-one [path: string, rules: list, alt: string, check: bool] {
  let text = (open --raw $path | decode utf-8)
  let body = ($text | str replace --regex --all $STRIP_LOAD "")

  # ONE grep over the body for all 25 rule names at once, rather than 25 =~ tests: see the note
  # on STRIP_LOAD above for why =~ is not an option here at all.
  let hits = ($body | ^grep -oE $alt | complete)
  let used_names = ($hits.stdout | lines | each {|l| $l | split row "(" | get 0 | str trim } | uniq)

  let wanted = ($rules | each {|r|
    let used = ($r.rules | where {|name| $name in $used_names } | sort)
    if ($used | is-empty) { [] } else { [{ bzl: $r.bzl, rules: $used }] }
  } | flatten | sort-by bzl)

  let loads = ($wanted | each {|w|
    'load("' + $w.bzl + '", ' + ($w.rules | each {|x| '"' + $x + '"' } | str join ", ") + ")\n"
  } | str join "")

  let new = $loads + (if ($loads | is-empty) { "" } else { "\n" }) + ($body | str replace --regex '^\n+' "")
  if $new == $text {
    false
  } else {
    if not $check { $new | save -f $path }
    true
  }
}

def main [--check] {
  let repo = ($env.FILE_PWD | path dirname)
  let rules = (rules-map $repo)
  # The name alternation, built once. \b is GNU grep own word boundary and is sound there; the
  # trailing [[:space:]]*\( is the python \s*\( minus its ability to cross a newline, which the
  # gate showed makes no difference on any of the 125 files.
  let alt = ('\b(' + ($rules | get rules | flatten | uniq | str join "|") + ')[[:space:]]*\(')
  let changed = (buck-files $repo | where {|p| (fix-one $p $rules $alt $check) })
  for p in $changed {
    print ((if $check { "would fix " } else { "fixed " }) + ($p | str replace ($repo + "/") ""))
  }
  if ($check and ($changed | is-not-empty)) { exit 1 }
  exit 0
}
