#!/usr/bin/env nu
# Is a per-pin store byte for byte what the assembled tree holds at that path?
#
# The lowering used to plant every pin from cider-src, which is ONE store path holding the
# whole project, so editing any tracked file moved it and with it all 295 pin symlinks in
# every target's staging script. Measured on libsimple_ciderd: 588 of the 601 lines
# changed after editing one unrelated ObjC file, and every changed line was a cider-src
# path, while the two source groups it actually reads did not move. That is why source groups
# bought nothing on their own.
#
# Per-pin stores fix it, but only if they hold the SAME BYTES the assembled tree does. The
# assembled tree does three things to a pin: fetch, apply patches/<name>/*.patch, then repoint
# stale SDK symlinks. nix/lib/cider-src.nix repeats those three, deliberately as a copy
# rather than a shared fragment (factoring them changed the assembled builder text by
# whitespace and cost an hour of rebuild). This is what keeps the copies honest.
#
# It is a check that CAN fail: drop the patch loop or the repoint from pinStore and pins that
# need them come out different, which is exactly the drift a shared string could not prevent.
#
# WHAT IT CANNOT CATCH, and this bit hard. A NAR hash records a symlink TARGET as a STRING, so
# two identical strings that resolve to different places because the ROOT moved are identical
# to it. It passed the change that staged pins from their own store paths, and that change
# broke 1,194 targets: 21 links reach out of their pin, and one of them is a directory link, so
# the effect was 143 dangling links. For that question use scripts/buck-escape-check.py:
#   buck-escape-check.py pins --root <assembled cider-src>   # are they self contained
#   buck-escape-check.py resolve <staged tree>                 # does it work AS STAGED
# THAT "DISPROVEN" IS NO LONGER TRUE, and the correction matters: a subtree of this project
# indeed has no self contained existence, but ALL THE PINS TOGETHER do. pinsTree (#74) mirrors
# every pin into one tree -- real directories, one link per file, each source symlink re-created
# by its own target string -- so a link to a SIBLING pin lands inside it, and its escape
# destinations are carried too. It is what made source groups work, and sourceGroups is ON by
# default now. scripts/buck-pins-tree-check.nu is the check for that property, since this one
# still cannot see it. This check remains useful only for the narrower question it actually asks, which
# is whether pinStore reproduces the assembled tree's BYTES.
#
# Usage:
#   scripts/buck-pin-store-check.nu                          # build both sides, compare all
#   scripts/buck-pin-store-check.nu --src <cider-src path> # compare against a given tree
#   scripts/buck-pin-store-check.nu --pins <farm path>
#   scripts/buck-pin-store-check.nu --only libdispatch       # one pin, for a quick loop

def say [msg: string] { print -e $msg }

def main [--src: string = "", --pins: string = "", --only: string = ""] {
    let farm = if ($pins | is-not-empty) { $pins } else {
        let r = (^nix build ".#cider-pin-stores" --no-link --print-out-paths | complete)
        if $r.exit_code != 0 {
            say "could not build .#cider-pin-stores"
            say $r.stderr
            exit 2
        }
        $r.stdout | lines | last | default ""
    }
    if not ($farm | path exists) {
        say $"no such pin farm: ($farm)"
        exit 2
    }

    # The assembled tree is not a flake output of its own, so it is taken from a staging
    # script, which names it once per pin. Any target's script will do.
    let tree = if ($src | is-not-empty) { $src } else {
        let found = (ls /nix/store
            | where name =~ 'cider-src$'
            | where type == dir
            | sort-by modified
            | last
            | get name)
        $found
    }
    if not ($tree | path exists) {
        say $"no such assembled tree: ($tree)"
        exit 2
    }

    say $"pin farm:  ($farm)"
    say $"assembled: ($tree)"

    # The farm names entries by sanitised path, so pins/libdispatch is
    # src-external-libdispatch. Turning that back into a path is what the compare needs.
    let entries = (ls $farm
        | get name
        | path basename
        | where {|n| ($only | is-empty) or ($n =~ $only) })

    if ($entries | is-empty) {
        say "no pin entries matched, nothing was compared, which is not a pass"
        exit 2
    }

    mut bad = []
    mut checked = 0
    for e in $entries {
        # src-external-X -> pins/X. Only the first two segments are directories in
        # every entry the manifest carries, so rebuilding the path is unambiguous.
        let rel = ($e | str replace 'src-external-' 'pins/')
        let theirs = ($tree | path join $rel)
        # RESOLVED, because a linkFarm entry is a symlink into the store and `nix hash path`
        # hashes the symlink itself, not what it points at. Without this every pin came back
        # different, which looked like the reconstruction being wrong and was the check being
        # wrong: a failure that says everything failed usually means the check is measuring
        # the wrong object.
        let ours = ($farm | path join $e | path expand)
        if not ($theirs | path exists) {
            $bad = ($bad | append $"($rel): missing from the assembled tree")
            continue
        }
        # NAR hashes, not diff. Two reasons. A recursive diff here compares a linkFarm
        # SYMLINK against a directory and reports every pin as different, which is a check
        # that fails for the wrong reason; and `diff` on this machine resolves to something
        # that does not take -r, so the comparison silently exited 0 with no output. A NAR
        # hash is what the store itself considers identity: contents, layout, symlink targets
        # and the execute bit, with mtimes and the rest normalised away.
        let a = (^nix hash path --type sha256 --sri $ours | complete)
        let b = (^nix hash path --type sha256 --sri $theirs | complete)
        $checked = $checked + 1
        if $a.exit_code != 0 or $b.exit_code != 0 {
            $bad = ($bad | append $"($rel): could not hash one side")
        } else if ($a.stdout | str trim) != ($b.stdout | str trim) {
            $bad = ($bad | append $"($rel): ($a.stdout | str trim) against ($b.stdout | str trim)")
        }
    }

    say $"compared ($checked) pins"
    if ($bad | is-empty) {
        say "PASS: every per-pin store matches the assembled tree"
        exit 0
    }
    say $"FAIL: ($bad | length) pins differ"
    for b in $bad { say $"  ($b)" }
    exit 1
}
