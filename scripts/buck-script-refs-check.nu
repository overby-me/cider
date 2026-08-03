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
    "PLAN.md"
    "flake.nix"
    ".gitignore"
    "plan/**/*.md"
    "docs/**/*.md"
    "buck/**/*.md"
    "tests/**/*.nix"
    "scripts/*"
]

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
            | where {|r| not ($r | path exists) }
            | each {|r| {file: $f, missing: $r} }
        }
        | flatten
    )

    if ($bad | is-empty) {
        say "PASS: every scripts/<name> written down still exists"
        exit 0
    }
    say $"FAIL: ($bad | length) reference\(s) name a script that is not there"
    for b in $bad { say $"  ($b.file): ($b.missing)" }
    say ""
    say "Rename the reference, or delete it if the tool was retired on purpose."
    exit 1
}
