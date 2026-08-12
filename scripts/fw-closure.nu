#!/usr/bin/env nu

# RESOLVE THE TRANSITIVE FRAMEWORK CLOSURE FOR A SET OF SEED FRAMEWORKS
#
# Umbrella frameworks include each other: ApplicationServices.h pulls in
# CoreServices/CoreServices.h, which pulls in CarbonCore, and so on. A target that includes one
# umbrella therefore needs a whole set of framework header roots, and adding them one compile
# error at a time is slow and stops at the first miss.
#
# This reads the generated FRAMEWORKS maps (which say, per framework, what header paths it
# exposes and which repo file backs each), scans those headers for
# `#include <Framework/Header.h>` / `#import <...>`, and walks the graph.
#
# Usage:
#   scripts/fw-closure.nu Foundation ApplicationServices        # labels to add
#   scripts/fw-closure.nu --json Foundation                     # for extra-deps
#
# PORTED FROM PYTHON (#98), byte identical in both modes.
#
# THE .bzl MAPS ARE PARSED LINE BY LINE, where the python handed the whole dict literal to
# ast.literal_eval. That is not a shortcut taken on faith: these six files are GENERATED, their
# shape is two levels of quoted keys, and the parse is checked by the counts it produces
# (17,845 lines, and the same closure and the same skipped list as the python on the same
# seeds). A general Starlark parser here would be more code and no more correct.
#
# THE MAPS STAY TABLES, never records. There are about 17,600 header entries; building one
# record that size with `upsert` copies the accumulator on every insert, which is the O(n^2)
# that cost buck-include-closure-check 127 s of a 163 s run.
#
# ONE grep PER FRAMEWORK, not one open per header. The python opens every backing file of every
# framework it walks; at this scale nushell would spend the whole runtime in per-file overhead,
# so the include scan is a single grep over the file list with the same anchored pattern.

const GEN = "buck/generated"

# Which .bzl belongs to which package, and whether it is the private surface (those targets are
# named fwp_* rather than fw_*).
const SOURCES = [["file" "pkg" "prefix"];
  ["sdk_framework_buck_src.bzl" "vendor/src" "fw_"]
  ["sdk_framework_private_buck_src.bzl" "vendor/src" "fwp_"]
  ["sdk_framework_darwin_frameworks.bzl" "darwin/frameworks" "fw_"]
  ["sdk_framework_private_darwin_private_frameworks.bzl" "darwin/private-frameworks" "fwp_"]
  ["sdk_framework_darwin_Developer.bzl" "darwin/Developer" "fw_"]
  ["sdk_framework_src_CoreAudio.bzl" "darwin/CoreAudio" "fw_"]]

def say-err [msg: string] { print -e $msg }

# os.path.isfile, which FOLLOWS SYMLINKS. `path type` does not: it answers "symlink" for a
# symlink, and these framework headers are symlinks into the submodules, so a bare
# `path type == "file"` marked CFNetwork, CoreServices, IOKit and Security as not backed and
# dropped seven labels from the closure. `path exists` follows and is false for a dangling
# link, which is the case this predicate exists to catch.
def is-file [p: string] {
  if ($p | path exists) { ($p | path expand | path type) == "file" } else { false }
}

# [{fw, label, pkg, headers: [{h, f}]}] in declaration order, which is what decides the winner
# when a framework is declared in more than one package.
def load-maps [] {
  mut out = []
  for src in $SOURCES {
    let path = ([$GEN $src.file] | path join)
    if not ($path | path exists) { continue }
    mut fw = ""
    mut headers = []
    for line in (open --raw $path | decode utf-8 | lines) {
      let top = ($line | parse --regex '^    "(?<name>[^"]+)": \{$')
      if ($top | is-not-empty) {
        if $fw != "" {
          $out = ($out | append { fw: $fw, label: $"//($src.pkg):($src.prefix)($fw)", pkg: $src.pkg, headers: $headers })
        }
        $fw = ($top | get name.0)
        $headers = []
        continue
      }
      let ent = ($line | parse --regex '^        "(?<h>[^"]+)": "(?<f>[^"]+)",$')
      if ($ent | is-not-empty) {
        $headers = ($headers | append { h: ($ent | get h.0), f: ($ent | get f.0) })
      }
    }
    if $fw != "" {
      $out = ($out | append { fw: $fw, label: $"//($src.pkg):($src.prefix)($fw)", pkg: $src.pkg, headers: $headers })
    }
  }
  $out
}

# Whether a framework's headers actually resolve in this working copy.
#
# The repo SDK and Developer trees are symlinks into the submodules, which are not checked out
# (the pins under vendor/src are what the port compiles against). A header_map full of dangling
# links does not even coerce, so such an entry is not a usable dep: naming it fails analysis
# for every consumer.
#
# THE SAMPLE IS python's SLICE, items[::max(1, len//20)][:20], reproduced step for step. A
# different sample would answer a different question on a partially checked out tree.
def backed [entry: record] {
  let items = $entry.headers
  let n = ($items | length)
  if $n == 0 { return false }
  let step = ([1 ($n // 20)] | math max)
  let sample = ($items | enumerate | where {|r| ($r.index mod $step) == 0 }
    | get item | first 20)
  let have = ($sample | where {|it| is-file ([$entry.pkg $it.f] | path join) } | length)
  $have == ($sample | length)
}

# Frameworks the headers of one framework include. The python tries pkg/file first and then
# file, taking the FIRST that exists and scanning only that one; the file list is built the
# same way here and then scanned in one pass.
def framework-edges [entry: record, known: list<string>] {
  let files = ($entry.headers | each {|it|
    let a = ([$entry.pkg $it.f] | path join)
    if (is-file $a) { $a } else if (is-file $it.f) { $it.f } else { null }
  } | compact)
  if ($files | is-empty) { return [] }
  let lf = (mktemp -t --suffix .txt)
  $files | str join "\n" | save -f $lf
  let pat = '^[ \t]*#[ \t]*(include|import)[ \t]*<[A-Za-z0-9_]+/'
  let hits = (^bash -c $"tr '\\n' '\\0' < ($lf) | xargs -0 grep -hoE '($pat)' || true" | complete)
  rm -f $lf
  $hits.stdout | lines | each {|l|
    let m = ($l | parse --regex '<(?<fw>[A-Za-z0-9_]+)/')
    if ($m | is-empty) { null } else { $m | get fw.0 }
  } | compact | uniq | where {|f| $f in $known }
}

def main [--json, ...seeds: string] {
  cd ($env.CURRENT_FILE | path dirname | path join "..")
  if ($seeds | is-empty) {
    say-err "Usage: scripts/fw-closure.nu [--json] <framework>..."
    exit 2
  }
  let maps = (load-maps)
  let known = ($maps | get fw | uniq)
  let unknown = ($seeds | where {|s| not ($s in $known) })
  if ($unknown | is-not-empty) {
    say-err $"# unknown frameworks: ($unknown | str join ' ')"
  }

  mut closure = []
  mut queue = ($seeds | where {|s| $s in $known })
  while ($queue | is-not-empty) {
    let fw = ($queue | last)
    $queue = ($queue | drop 1)
    if $fw in $closure { continue }
    $closure = ($closure | append $fw)
    for entry in ($maps | where fw == $fw) {
      for dep in (framework-edges $entry $known) {
        if not ($dep in $closure) { $queue = ($queue | append $dep) }
      }
    }
  }

  # Prefer the pins when a framework is declared in more than one package: the pinned copy is
  # what the reference build compiles against. Entries whose headers are not present are
  # skipped, and said so rather than emitted.
  mut labels = []
  mut unavailable = []
  for fw in ($closure | sort) {
    let entries = ($maps | where fw == $fw | where {|e| backed $e })
    if ($entries | is-empty) {
      $unavailable = ($unavailable | append $fw)
      continue
    }
    let pinned = ($entries | where {|e| $e.pkg == "vendor/src" and (not ($e.label | str ends-with $"fwp_($fw)")) })
    let pick = (if ($pinned | is-not-empty) { $pinned | first } else { $entries | first })
    $labels = ($labels | append $pick.label)
  }
  if ($unavailable | is-not-empty) {
    say-err $"# not backed in this working copy, skipped: ($unavailable | str join ' ')"
  }

  if $json {
    print ($labels | to json --indent 2)
  } else {
    print $"# ($labels | length) frameworks in the closure of ($seeds | str join ' ')"
    for label in $labels { print $'    "($label)",' }
  }
  exit 0
}
