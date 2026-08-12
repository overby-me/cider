#!/usr/bin/env nu

# Every buck2 label we write must name a package directory that exists.
#
# Companion to buck-pin-paths-check.nu. That one resolves the PATHS we record
# into upstream pins; this one resolves the LABELS we write between packages.
# Both are the same failure mode from opposite ends: a plain string naming
# something that is not there, which nothing checks until buck2 is asked to build
# it, an hour into a run.
#
# WHAT IT CATCHES, and the reason it exists. buck-src/BUCK and buck-src/<pin>/BUCK
# are OURS, generated from the reference build, even though they sit next to
# upstream code. The Cider rename skipped the whole buck-src tree, correctly for
# the pin paths inside it and WRONGLY for its 170 references back to first-party
# packages. They kept naming //pins/darlingserver after that package
# became //pins/ciderd. buck2 reported the first one only, as an analysis
# error four minutes into the endpoint:
#
#     Unknown target `darling_config` from package `root//darwin/include`
#     Available targets: root//darwin/include:cider_config
#
# One failure per run, and the next one only after another four minutes. This
# reports all of them at once.
#
# TWO RULES, because a general target-existence check is not available cheaply:
#
#   1  the PACKAGE directory must exist. Unambiguous, and it caught the 205.
#   2  a label into a FIRST-PARTY package must not name a target containing
#      darling. First-party code is Cider now; only pins keep the old name. This
#      is narrow on purpose and has no false positives.
#
# Rule 2 exists because rule 1 does not catch a package that still exists under a
# target that was renamed inside it, which is how this failed twice:
#
#     Unknown target `darling_config` from package `root//darwin/include`
#     Unknown target `libsimple_darling` from package `root//darwin/libsimple`
#
# Full target existence was measured and rejected: after expanding the two macro
# shapes that can be resolved statically (the fw_* header roots from
# FRAMEWORKS.items() and the per-pin export_file loops from EXPORTS.items()), 105
# distinct targets remain unresolvable, all real. They come from elf_wrapper,
# which synthesises <name>_wrap and <name>_dylib from a list local to the BUCK
# file. Reporting those 105 as failures would make the check useless, so it does
# not claim to check what it cannot see.
#
# Verified both ways. Against the tree as the rename left it: 205 occurrences of
# //pins/darlingserver, 10 of //darwin/include:darling_config and 5 of
# //darwin/libsimple:libsimple_darling. Clean now, except two labels ignored by name
# below.
#
# Exit 0 if every label resolves, 1 otherwise.
#
# PORTED FROM PYTHON, byte identical on the real tree and under three planted faults. TWO THINGS
# THE PORT HAD TO GET RIGHT RATHER THAN TRANSLATE:
#
#   PARSE THE WHOLE FILE, NOT LINE BY LINE. A load() spans lines, so the python uses re.S and the
#   nushell needs the (?s) inline flag. It is also much faster: one parse over the 63k-line
#   buck-src/BUCK finds all 5,725 labels in 8ms, where per-line regex over a corpus that size
#   does not finish. The earlier finding that nushell regex is slow was about the number of
#   INVOCATIONS, not about regex.
#
#   COUNTER.MOST_COMMON IS COUNT-DESCENDING WITH TIES IN INSERTION ORDER, because python sorts
#   stably. `sort-by n --reverse` reverses the ties too and reports the same failures in a
#   different order, which a byte comparison catches and a human reading the output would not.
#   Sorting ascending on (-count, first-seen index) is the faithful equivalent.

const IGNORE_PREFIXES = ["buck-src/libcxx/utils/google-benchmark/"]
const SKIP_DIRS = [".jj" ".git" "buck-out"]

const LABEL = '"//(?<pkg>[A-Za-z0-9_./+-]*):(?<name>[A-Za-z0-9_.+-]+)"'

# read_root_config(SECTION, key, default) reads .buckconfig.local, which both
# nix/lib/ciderBuck2Graph.nix and scripts/buck-setup.nu write under [cider].
# A section that does not match returns the DEFAULT, silently: the one
# read_root_config("darling", "elf_lib_dirs", "") left in buck-src/BUCK gave
# wrapgen an empty search path and it failed with
#   Cannot load libfuse.so: cannot open shared object file
# four minutes into the endpoint. No label and no path is involved, so nothing
# else here would have seen it.
const CONFIG = 'read_root_config\(\s*"(?<section>[a-z_]+)"'
const CONFIG_SECTION = "cider"

# load("//pkg:file.bzl", "SYM", ALIAS = "SYM") -- the FILE has to exist and each
# symbol has to be defined in it. Renaming the load and not the file is how the
# duct-tape sweep broke the endpoint:
#   File not found: root//buck/generated/xnu_sys_flags.bzl
# and renaming the file but not the symbol fails the same way one line later.
const LOAD = '(?s)load\(\s*"//(?<pkg>[A-Za-z0-9_./+-]*):(?<file>[A-Za-z0-9_.+-]+\.bzl)"(?<rest>[^)]*)\)'
const LOAD_SYMS = '"(?<sym>[A-Za-z_][A-Za-z0-9_]*)"'
const DEFINES = '(?m)^(?<sym>[A-Za-z_][A-Za-z0-9_]*)\s*='

def buck-files [repo: string] {
  let ex = ($SKIP_DIRS | each {|d| $"**/($d)/**" })
  [ $"($repo)/**/BUCK" $"($repo)/**/*.bzl" ]
    | each {|g| glob $g --no-dir --exclude $ex } | flatten | uniq | sort
    | each {|p| $p | str replace $"($repo)/" "" }
    | where {|rel| not ($IGNORE_PREFIXES | any {|p| $rel | str starts-with $p }) }
}

def main [] {
  let repo = ($env.FILE_PWD | path dirname)

  mut hits = []
  mut checked = 0
  for rel in (buck-files $repo) {
    let text = (open --raw ($repo | path join $rel) | decode utf-8)

    for m in ($text | parse --regex $LABEL) {
      $checked = $checked + 1
      let pkg_dir = ($repo | path join $m.pkg)
      let is_dir = (($m.pkg | is-not-empty) and ($pkg_dir | path exists) and (($pkg_dir | path type) == "dir"))
      if not $is_dir {
        $hits = ($hits | append { key: $"no such package  //($m.pkg):($m.name)", file: $rel })
      } else if (not ($m.pkg | str starts-with "buck-src")) and ($m.name | str contains "darling") {
        $hits = ($hits | append { key: $"first-party target still named darling  //($m.pkg):($m.name)", file: $rel })
      }
    }

    for m in ($text | parse --regex $CONFIG) {
      $checked = $checked + 1
      if $m.section != $CONFIG_SECTION {
        # $'...' does NOT take backslash escapes, so a literal paren needs the $"..." form.
        $hits = ($hits | append { key: $"config section is not [($CONFIG_SECTION)]  read_root_config\(\"($m.section)\"\)", file: $rel })
      }
    }

    for m in ($text | parse --regex $LOAD) {
      $checked = $checked + 1
      let target = ($repo | path join $m.pkg $m.file)
      if not ($target | path exists) {
        $hits = ($hits | append { key: $"load\(\) file missing  //($m.pkg):($m.file)", file: $rel })
        continue
      }
      let defined = (open --raw $target | decode utf-8 | parse --regex $DEFINES | get sym)
      for s in ($m.rest | parse --regex $LOAD_SYMS | get sym) {
        if not ($s in $defined) {
          $hits = ($hits | append { key: $"load\(\) symbol missing  //($m.pkg):($m.file) has no ($s)", file: $rel })
        }
      }
    }
  }

  print $"labels and config reads checked: ($checked)"
  if ($hits | is-empty) {
    print "PASS: every label names a package that exists, every load\(\) file and symbol resolves,\n      no first-party target is still named darling, and every config read is [cider]"
    exit 0
  }

  # Counter.most_common: count descending, ties in FIRST-SEEN order. `sort-by n --reverse` would
  # invert the ties, so sort ascending on (-n, first index) instead.
  let summary = ($hits | group-by key | transpose key rows | enumerate
    | each {|g| {
        key: $g.item.key
        n: ($g.item.rows | length)
        neg: (0 - ($g.item.rows | length))
        idx: $g.index
        files: ($g.item.rows | get file | uniq | sort)
      } }
    | sort-by neg idx)

  print $"\n($hits | length) labels do not resolve:"
  for s in $summary {
    print $"  ($s.n | fill -a right -w 5)  ($s.key)   in ($s.files | length) file\(s\): ($s.files | first 3 | str join ', ')"
  }
  print "\nFAIL: a label names something that is not there."
  print "If a first-party package or target was renamed, buck-src/BUCK and"
  print "buck-src/<pin>/BUCK reference it too; those are generated files of ours,"
  print "not upstream code, and the Cider sweep skipped the whole buck-src tree."
  exit 1
}
