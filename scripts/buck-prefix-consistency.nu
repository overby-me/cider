#!/usr/bin/env nu

# Is a prefix internally consistent: does everything it points at, it also install?
#
# Removing an install entry is not a local edit. Other entries REFER to it, and those references
# do not fail loudly, they produce a prefix that is quietly wrong:
#
#   SYMLINKS. A multi-call binary ships once and is symlinked under its other names. Dropping
#   `installer` orphaned lsbom, pkgutil and uninstaller; dropping `less` orphaned `more`;
#   dropping `unzip` orphaned `zipinfo`. Five links to nothing. This is #41 again, where eight
#   krb5 dylib symlinks dangled.
#
#   LAUNCHD PLISTS. A plist names a Program. Dropping the security daemons, sshd and cupsd left
#   seven plists whose Program does not exist, so launchd would try to spawn each at boot and
#   fail. **The smoke test cannot catch this**: it runs with CIDER_NO_LAUNCHD=1, so the job
#   graph is never exercised at all.
#
# The symlink half is also enforced in gen-prefix-min.nu, which drops orphaned links as it
# writes. This exists because that only protects the generated minimal prefix, and because a
# check that can be pointed at any prefix is what turns "I removed something" into a question
# with an answer.
#
# Usage:
#   scripts/buck-prefix-consistency.nu                          # the minimal prefix
#   scripts/buck-prefix-consistency.nu --prefix buck/prefix/BUCK
#
# PORTED FROM PYTHON, byte identical on BOTH prefixes (prefix-min and the full one) and under
# two planted faults. The performance warning in the original survives the port and gets
# sharper: a repo-wide `**` glob took the python from under a second to over ten MINUTES because
# it walked buck-out, and in nushell the equivalent mistake is worse, because `glob` applies its
# filter to RESULTS. The five source roots are named explicitly for that reason, and --exclude
# is passed as well, since it PRUNES the walk rather than filtering it.

const SOURCE_ROOTS = ["src" "vendor/src" "src/darwin" "src/linux" "buck"]
const GLOB_EXCLUDE = ["**/buck-out/**" "**/.jj/**" "**/.git/**"]

# `^\s+NAME = \{(.*?)^\s+\},` with re.M | re.S. Nushell needs both inline flags, (?ms), and the
# non-greedy `.*?` is what stops the first section from swallowing every later one.
def section [text: string, name: string] {
  let m = ($text | parse --regex $"\(?ms\)^\\s+($name) = \\{\(?<body>.*?\)^\\s+\\},")
  if ($m | is-empty) { "" } else { $m | first | get body }
}

def installed-destinations [text: string] {
  ["entries" "files" "trees"]
    | each {|s| (section $text $s) | parse --regex '(?m)^\s*"(?<d>[^"]+)"\s*:' | get d }
    | flatten | uniq
}

# Where a plist label's source file actually lives.
#
# DERIVED FROM THE LABEL, not globbed, because globbing one directory silently skipped the
# most important plist in the prefix: shellspawn is `//src/darwin/shellspawn:...`, so a glob rooted
# at vendor/src/ never found it, and shellspawn is what `cider shell` uses to spawn the guest
# shell. A check that quietly cannot see its most important case is worse than no check.
#
# Three forms, in order:
#   //src/darwin/shellspawn:me.overby.cider.shellspawn.plist -> src/darwin/shellspawn/org.cider....plist
#   //vendor/src:security_OSX_sec_ipc_com.apple.secd.plist -> the name's underscores are path
#       separators: vendor/src/security/OSX/sec/ipc/com.apple.secd.plist
#   anything else -> a glob over the SOURCE ROOTS only, as a last resort
def plist-source [repo: string, label: string] {
  let stripped = ($label | str trim --left --char "/")
  let pkg = ($stripped | split row ":" | first)
  let name = ($stripped | split row ":" | skip 1 | str join ":")

  let direct = ($repo | path join $pkg $name)
  if ($direct | path exists) { return $direct }

  # underscore-encoded path, peeled from the left so a dotted file name survives
  let parts = ($name | split row "_")
  for i in (seq (($parts | length) - 1) 1) {
    let cand = ($repo | path join $pkg ...($parts | first $i) ($parts | skip $i | str join "_"))
    if ($cand | path exists) { return $cand }
  }

  # Last resort, over the SOURCE roots only. A repo-wide `**` glob is not an option: it walks
  # buck-out, which is hundreds of thousands of build artifacts, and the first version of this
  # took the check from under a second to over ten MINUTES. Filtering buck-out out of the
  # results afterwards does not help, because the walk has already happened. That is exactly
  # what nushell's `glob` post-filter would do, so --exclude is used, which prunes.
  # The label NAME is the underscore-encoded path, so the file on disk is only its last
  # component: `remote_cmds_talkd.tproj_ntalk.plist` is `.../talkd.tproj/ntalk.plist`.
  # Globbing the whole name finds nothing, which is how ntalk and tftp stayed "not checked"
  # even though both were sitting in the tree.
  let leaf = ($name | split row "_" | last)
  for root in $SOURCE_ROOTS {
    let dir = ($repo | path join $root)
    if not ($dir | path exists) { continue }
    let hits = (glob $"($dir)/**/($leaf)" --exclude $GLOB_EXCLUDE)
    if not ($hits | is-empty) { return ($hits | first) }
  }
  null
}

# The Program a launchd plist names, read from its source in the repo.
#
# A plist whose source cannot be found is REPORTED, not silently passed: an unreadable input
# is not evidence of correctness.
def plist-program [repo: string, label: string] {
  let src = (plist-source $repo $label)
  if $src == null { return { prog: null, why: "source not found" } }
  let text = (open --raw $src | decode utf-8)
  let m = ($text | parse --regex '(?s)<key>Program(?:Arguments)?</key>\s*(?:<array>\s*)?<string>(?<prog>[^<]+)</string>')
  if ($m | is-empty) { return { prog: null, why: "no Program key" } }
  { prog: ($m | first | get prog), why: null }
}

def main [--prefix: string = "buck/prefix-min/BUCK"] {
  let repo = ($env.FILE_PWD | path dirname)
  let path = ($repo | path join $prefix)
  if not ($path | path exists) {
    print -e $"($path) does not exist"
    exit 1
  }
  let text = (open --raw $path | decode utf-8)
  let dests = (installed-destinations $text)
  if ($dests | is-empty) {
    print -e $"($prefix): no install destinations found; wrong file?"
    exit 1
  }

  mut failures = 0

  let links = ((section $text "symlinks") | parse --regex '(?m)^\s*"(?<a>[^"]+)"\s*:\s*"(?<b>[^"]+)"')
  let dangling = ($links | where {|l| not ($l.b in $dests) })
  print $"symlinks: ($links | length), dangling: ($dangling | length)"
  for l in $dangling { print $"  FAIL ($l.a)\n         -> ($l.b)  \(not installed\)" }
  $failures = $failures + ($dangling | length)

  let plists = ($text | parse --regex '(?m)^\s*"(?<dest>[^"]*Launch(?:Daemons|Agents)/[^"]+)"\s*:\s*"(?<label>[^"]+)"')
  mut bad = []
  mut unknown = []
  for p in $plists {
    let r = (plist-program $repo $p.label)
    if $r.prog == null {
      $unknown = ($unknown | append { dest: $p.dest, why: $r.why })
      continue
    }
    let prog = $r.prog
    let leaf = ($prog | split row "/" | last)
    let abs = ("/" + ($prog | str trim --left --char "/"))
    let found = ($dests | any {|d| ($d | str ends-with $abs) or ($d | str ends-with $"/($leaf)") })
    if not $found { $bad = ($bad | append { dest: $p.dest, prog: $prog }) }
  }
  print $"launchd plists: ($plists | length), Program missing: ($bad | length)"
  for b in $bad { print $"  FAIL ($b.dest | split row '/' | last)\n         Program ($b.prog) is not installed" }
  $failures = $failures + ($bad | length)
  for u in $unknown { print $"  note ($u.dest | split row '/' | last): ($u.why), not checked" }

  if $failures > 0 {
    print $"\nFAIL: ($failures) reference\(s\) point at something the prefix does not install"
    exit 1
  }
  print "\nPASS: every symlink target and every plist Program is installed"
  exit 0
}
