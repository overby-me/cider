#!/usr/bin/env nu
# Does pinsTree RESOLVE, and does it resolve as well as the assembled tree does?
#
# pinsTree is what made source groups work (#54, #74). It holds all 147 pins MIRRORED -- real
# directories, one symlink per file, each source symlink re-created with its own target string
# -- so that a pin's link to a SIBLING pin resolves inside the tree. A per-pin store cannot do
# that: vendor/pins/IOKitUser/darling/submodules/xnu is a link to ../../../xnu/, and planted as
# a directory symlink the kernel resolves that against the STORE. Staging pins that way broke
# the DEFAULT endpoint, and scripts/buck-pin-store-check.nu passed anyway, because it compares
# by NAR HASH and a NAR hash records a symlink TARGET as a STRING.
#
# So this asks the question that one cannot: does every link LAND somewhere.
#
# THE BAR IS PARITY, NOT ZERO. The assembled tree itself carries dangling links that dangle
# upstream: two dtrace links the pin does not ship, a homebrew absolute path under libxslt,
# libcxx/test/std/pstl, libkqueue's test configure. Chasing pinsTree to zero would mean
# diverging from the tree it has to match. Measured when this was written: 6 and 6.
#
# It CAN fail, which is the point:
#   drop the symlink re-creation pass from stageGroupsFor and the sibling links point into a
#   store instead, which shows up here as a jump from 6 to hundreds;
#   drop the escape-destination pass and it goes 6 to 17, all of them links leaving
#   pins into the SDK or into a non-pin external.
#
# Usage:
#   scripts/buck-pins-tree-check.nu                    # build pinsTree, compare against cider-src
#   scripts/buck-pins-tree-check.nu --tree <path>      # check a tree already built

def say [msg: string] { print -e $msg }

# PARSE THE NUMBER, not the number of LINES mentioning it. The first version of this counted
# lines matching "dangling", which is one summary line either way, so it reported 1 against 1
# and would have passed for any tree at all. A check that cannot fail is worth nothing, and this
# one nearly shipped as one.
#
# The line is: `resolve <path>: 6 dangling of 263806 symlinks`
def dangling [dir: string] {
    let out = (do -i { ^nu scripts/buck-escape-check.nu resolve $dir } | complete)
    let line = ($out.stdout | lines | where {|l| $l =~ 'dangling of' } | first)
    if ($line | is-empty) {
        say $"  no resolve summary for ($dir); output was:"
        say $out.stdout
        exit 1
    }
    let m = ($line | parse --regex ': (?<bad>\d+) dangling of (?<walked>\d+)' | first)
    {bad: ($m.bad | into int), walked: ($m.walked | into int)}
}

def main [--tree: string = ""] {
    let tree = if ($tree | is-empty) {
        say "building .#cider-buck2-prefix-min.pinsTree ..."
        (^nix build '.#cider-buck2-prefix-min.pinsTree' --no-link --print-out-paths
            | complete | get stdout | lines | first)
    } else { $tree }
    say $"pinsTree: ($tree)"

    let src = (^nix build '.#cider-src' --no-link --print-out-paths
        | complete | get stdout | lines | first)
    say $"cider-src: ($src)"

    let mine = (dangling $tree)
    let theirs = (dangling $"($src)/vendor/pins")
    say $"  pinsTree:   ($mine.bad) dangling of ($mine.walked) symlinks"
    say $"  assembled:  ($theirs.bad) dangling of ($theirs.walked) symlinks"

    # It must have WALKED something, or it proved nothing. buck-escape-check refuses on zero for
    # its own modes; resolve is informational, so the floor is asserted here.
    if $mine.walked == 0 or $theirs.walked == 0 {
        say "FAIL: walked no symlinks, so this proved nothing"
        exit 1
    }
    if $mine.bad > $theirs.bad {
        say $"FAIL: pinsTree dangles (($mine.bad) - ($theirs.bad)) more than the tree it replaces"
        exit 1
    }
    say "PASS: pinsTree resolves at least as well as the assembled tree"
}
