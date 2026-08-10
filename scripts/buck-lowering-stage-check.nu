#!/usr/bin/env nu
# Does the lowering still stage a project tree the pins can be planted into?
#
# This exists because of one word. The lowered derivations build in a directory that
# stageProject fills: most of the project arrives as symlinks into the store, but src/ and
# src/external/ have to be REAL directories, because the pinned upstream trees are planted at
# src/external/<pin> and planting anything inside a store path is a permission error. When
# `name != "src"` fell out of the top-level exclusion list (rewritten to `name != "projectSrc"`,
# a Nix binding name that matches no directory), src became a symlink into the store and all
# 1798 lowered targets died with
#
#   ln: failed to create symbolic link 'src/external/xnu': Permission denied
#
# Nothing caught it, because the only thing that exercises the lowering is a 90 minute build.
# This reads the staging script instead, in seconds, and it is a fair check precisely because
# the script is generated: it says what the lowering will actually do, not what it should.
#
# Verified BOTH WAYS, which is possible here because the broken script is still in the store:
# it fails on the one the regression generated and passes on the one from before it.
#
# Usage:
#   scripts/buck-lowering-stage-check.nu                 # build the current one and check it
#   scripts/buck-lowering-stage-check.nu --script <path> # check a specific staging script

def say [msg: string] { print -e $msg }

def main [--script: string = ""] {
    let path = if ($script | is-not-empty) {
        $script
    } else {
        # Attached to the prefix package with `//`, so this builds the little staging script
        # and NOT the prefix. It does need graph.json, which is an IFD: with the graph
        # derivation already in the store this is seconds, without it, it is the graph build.
        let r = (^nix build ".#cider-buck2-prefix.stageProject"
            --no-link --print-out-paths | complete)
        if $r.exit_code != 0 {
            say "could not build .#cider-buck2-prefix.stageProject"
            say $r.stderr
            exit 2
        }
        $r.stdout | lines | last | default ""
    }

    if not ($path | path exists) {
        say $"no such staging script: ($path)"
        exit 2
    }
    say $"staging script: ($path)"
    let lines = (open --raw $path | lines)

    # 1. src must NOT be a symlink into the store. This is the regression itself.
    let src_link = ($lines | where {|l| $l =~ '^ln -s [^ ]+/src src$' })
    # 2. ... because src/external has to be a real directory to plant pins into.
    let mk_external = ($lines | where {|l| $l =~ '^mkdir -p src/external$' })
    # 3. src/ is then populated entry by entry, which is what makes it usable at all.
    let src_entries = ($lines | where {|l| $l =~ '^ln -s [^ ]+/src/[^ ]+ src/' })
    # 4. And the pins land under it. Without these the SDK symlink farm does not resolve.
    let pins = ($lines | where {|l| $l =~ '^ln -sfn [^ ]+ src/external/' })
    # 5. EVERY buck-src ALIAS MUST BE UNIQUE. A pin is aliased as buck-src/<basename> and
    #    basenames are NOT unique: src/external/ciderd/xnu-sys/xnu ends in xnu exactly like
    #    src/external/xnu, so both claimed buck-src/xnu and the second silently overwrote the
    #    first. Everything resolving through buck-src/xnu then got the wrong tree, which
    #    surfaced 90 minutes later as "redeclaration of __dso_handle with a different type"
    #    in the Security cone, naming SDK headers that have nothing to do with xnu.
    let aliases = ($lines | where {|l| $l =~ '^ln -sfn [^ ]+ buck-src/' }
        | each {|l| $l | split row " " | last })
    let dupe_aliases = ($aliases | uniq -d)
    # 6. AND NO rm -f AGAINST A PIN PATH. rm -f cannot remove a DIRECTORY, so where the path
    #    is already a real directory the removal failed and the ln that followed created the
    #    link INSIDE it. It has to be rm -rf. The four checks above all passed while this was
    #    broken, which is why it is here: they assert the shape of src, not the pin lines.
    let bad_rm = ($lines | where {|l| $l =~ '^rm -f (?!-)' })

    mut failed = false
    if ($src_link | is-not-empty) {
        say $"FAIL: src is symlinked into the store, so nothing can be planted under it:"
        $src_link | each {|l| say $"  ($l)" }
        $failed = true
    }
    if ($mk_external | is-empty) {
        say "FAIL: no `mkdir -p src/external`, so src/external is not a real directory"
        $failed = true
    }
    if ($src_entries | length) < 10 {
        say $"FAIL: only ($src_entries | length) src/<entry> links, expected the whole of src/"
        $failed = true
    }
    if ($pins | is-empty) {
        say "FAIL: no pin is planted at src/external/<pin>"
        $failed = true
    }
    if ($dupe_aliases | is-not-empty) {
        say $"FAIL: ($dupe_aliases | length) buck-src alias\(es) claimed by more than one pin,"
        say "      so the later one silently overwrites the earlier and its consumers get the"
        say "      wrong tree. A nested pin must not take a buck-src alias at all:"
        $dupe_aliases | each {|a| say $"  ($a)" }
        $failed = true
    }
    if ($bad_rm | is-not-empty) {
        say $"FAIL: ($bad_rm | length) rm -f line\(s), which cannot remove a directory, so the"
        say "      ln that follows lands INSIDE the path instead of replacing it. Use rm -rf:"
        $bad_rm | first 5 | each {|l| say $"  ($l)" }
        $failed = true
    }

    if $failed {
        say ""
        say "The staging script cannot build. See the top-level exclusion list in"
        say "nix/lib/ciderBuck2Lower.nix: src, buck-src, buck-out and buck-rust all have to"
        say "stay out of the symlink-everything loop, because each is rebuilt below it."
        exit 1
    }
    say $"PASS: src is a real directory, ($src_entries | length) entries linked into it, ($pins | length) pin\(s) planted under src/external"
    exit 0
}
