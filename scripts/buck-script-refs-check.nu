#!/usr/bin/env nu
# Does every scripts/<name> the docs and configs NAME still exist?
#
# This is rot that keeps coming back, because a script is renamed in one commit and its name
# lives in prose written months earlier. It has now happened four times: gen-submodule-manifest
# was cited by a script that outlived it, buck-src.sh by 51 files, buck-bash-check.sh by 8, and
# buck-launchd-check.sh by PLAN itself. Each time the reference points at nothing and the reader
# has to guess whether the tool moved or was deleted on purpose.
#
# Cheap enough to run any time: it greps a fixed set of places for scripts/<something> and asks
# the filesystem. It deliberately does NOT scan the scripts themselves for each other, because a
# script citing a deleted sibling is the same bug and is caught by the same sweep below.
#
# Verified both ways: it exits 1 on a file that names a script which does not exist, and 0 on
# the tree as it stands. The negative case is what --scan is for.
#
# Usage:
#   scripts/buck-script-refs-check.nu              # the docs, configs and scripts
#   scripts/buck-script-refs-check.nu --scan a,b   # just these files (for testing)

def say [msg: string] { print -e $msg }

# Where a script name is likely to be written down. buck-src/ is excluded on purpose: its 49
# per-pin BUCK files are generated from one template, so a stale name there is one fix, and
# including them makes every run walk 49 files to say the same thing four dozen times.
const DEFAULT_GLOBS = [
    "docs/changelog.md"
    "flake.nix"
    ".gitignore"
    "plan/**/*.md"
    "docs/**/*.md"
    # Prose is not the only place a script name is written down: the three that
    # survived the first version of this check were named by a .bzl, a BUCK file, a
    # gitignore beside a materialized tree and a Rust doc comment. Widened after
    # buck-appkit-check, buck-rust-vendor and buck-setup were renamed to .nu and
    # seven such references kept pointing at the .sh.
    "buck/**/*"
    "buck-rust/BUCK"
    "buck-rust/.gitignore"
    "tests/**/*"
    "src/**/BUCK"
    "src/**/*.py"
    "linux/**/*.rs"
    "darwin/**/*.rs"
    "scripts/*"
]
# NOT nix/** yet: nix/lib/ciderBuck2Graph.nix carries one reference that is
# package-relative on purpose, and editing that file rebuilds the graph derivation
# even for a comment, so it waits for a moment when nothing is building.

def main [--scan: string = ""] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    let files = if ($scan | is-not-empty) {
        $scan | split row "," | where {|f| $f | path exists }
    } else {
        $DEFAULT_GLOBS | each {|g| glob $g --no-dir } | flatten | uniq
    }
    say $"scanning ($files | length) file\(s)"

    let bad = (
        $files
        | each {|f|
            let text = (try { open --raw $f | decode utf-8 } catch { "" })
            # The boundary matters: buck-src/openssl_certificates/scripts/generate-ca-bundle.py
            # is a path inside a PIN, not a reference to this repo's scripts/, and matching the
            # tail of it reported a missing script that was never supposed to be here. So the
            # match has to start at a line start or after something that cannot be a path
            # component, and the separator is then dropped.
            $text
            | parse --regex '(?m)(?P<pre>^|[^A-Za-z0-9_/.-])(?P<ref>scripts/[A-Za-z0-9_-]+\.(?:sh|nu|py|bxl))'
            | get ref
            | uniq
            # A BUCK file names its script RELATIVE TO ITS PACKAGE: ciderd's
            # BUCK points at pins/ciderd/scripts/generate-rpc-wrappers.py
            # by its package-relative name, which is correct and resolves to a real
            # file. Resolve both ways before calling it missing. (Spelled here as a
            # full path on purpose: a bare one would make this comment its own hit.)
            | where {|r| (not ($r | path exists)) and (not (($f | path dirname | path join $r) | path exists)) }
            | each {|r| {file: $f, missing: $r} }
        }
        | flatten
    )

    # And the runtime driver's own list, which names checks WITHOUT an extension because it
    # resolves .nu before .sh. A check renamed out from under it fails only when the driver is
    # run, which costs a container each time; here it costs nothing.
    let driver = "scripts/buck-runtime-check.nu"
    let named = if ($scan | is-not-empty) or (not ($driver | path exists)) {
        []
    } else {
        open --raw $driver
        | parse --regex '(?s)const (?:CHECKS|SLOW) = \[(?P<body>[^\]]*)\]'
        | get body
        | each {|b| $b | lines | each {|l| $l | str replace --regex '#.*' '' | str trim } }
        | flatten
        | where {|n| ($n | is-not-empty) and ($n =~ '^[a-z0-9-]+$') }
    }
    let missing_checks = (
        $named | where {|n| not (($"scripts/($n).nu" | path exists) or ($"scripts/($n).sh" | path exists)) }
    )
    if ($named | is-not-empty) {
        say $"   plus ($named | length) check\(s) named by ($driver)"
    }

    # AND IT HAS TO BE RUNNABLE, not merely present. buck-test.nu invokes several checks as
    # ./scripts/<name>.nu, and a file without the executable bit fails there with
    # "Command not found ... refers to a file that is not executable", which reads like a
    # missing script rather than a missing mode. EIGHTEEN of them were in that state after the
    # python ports, and the suite died on the first one it reached.
    let not_exec = (^find scripts -name "*.nu" ! -perm -u+x | complete | get stdout | lines
        | where {|l| $l != "" } | sort)

    if ($bad | is-empty) and ($missing_checks | is-empty) and ($not_exec | is-empty) {
        say "PASS: every scripts/<name> written down still exists and is executable"
        exit 0
    }
    if ($not_exec | is-not-empty) {
        say $"FAIL: ($not_exec | length) nushell script\(s) are not executable, so a caller that"
        say "      runs them by path gets a confusing not-found error:"
        for f in $not_exec { say $"  ($f)" }
    }
    for m in $missing_checks {
        say $"FAIL: ($driver) runs ($m), and neither scripts/($m).nu nor .sh is there"
    }
    if ($bad | is-not-empty) {
        say $"FAIL: ($bad | length) reference\(s) name a script that is not there"
        for b in $bad { say $"  ($b.file): ($b.missing)" }
    }
    say ""
    say "Rename the reference, or delete it if the tool was retired on purpose."
    exit 1
}
