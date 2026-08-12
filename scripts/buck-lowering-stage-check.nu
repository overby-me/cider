#!/usr/bin/env nu
# Does the lowering still stage a project tree the pins can be planted into?
#
# This exists because of one word. The lowered derivations build in a directory that
# the staging script fills, and when `name != "src"` fell out of the top-level exclusion
# list (rewritten to `name != "projectSrc"`, a Nix binding name that matches no directory),
# src became a symlink into the store and all 1798 lowered targets died with
#
#   ln: failed to create symbolic link 'pins/xnu': Permission denied
#
# Nothing caught it, because the only thing that exercises the lowering is a 90 minute build.
# This reads the staging script instead, in seconds, and it is a fair check precisely because
# the script is generated: it says what the lowering will actually do, not what it should.
#
# AND A BUILD IS NOT MERELY SLOW AT CATCHING THIS, IT CANNOT CATCH IT. The staging script
# carries no `set -e`, and both pin faults SUCCEED at the shell level: `ln -sfn X dir/`
# happily creates dir/X, and a failed `rm -f` is never looked at. So the script exits 0 with
# the tree wrong, and the damage surfaces much later as somebody else's compile error --
# "redeclaration of __dso_handle with a different type" in the Security cone, naming SDK
# headers with nothing to do with xnu. MEASURED 2026-08-10, against the derivations in the
# store: 3 of libsimple's own 8 staging scripts plant the nested xnu-sys pin and 2 carry the
# duplicate alias, so even the cheapest target STAGES the fault. It just cannot fail on it,
# because it compiles nothing that reads the tree that went wrong. Reading the script is
# therefore not a cheaper substitute for building. It is the only thing that works.
#
# THERE ARE TWO STAGING SCRIPTS AND THIS CHECKED THE WRONG ONE. ciderBuck2Lower.nix picks
# between them on `sourceGroups`, and every endpoint that gets gated has it ON, so the
# WHOLE-PROJECT script this used to inspect is not the one the gate runs. Measured
# 2026-08-10: the green .#cider-buck2-prefix-min run built 65 buck2-stage-project-grouped
# derivations and zero buck2-stage-project ones. Worse, reaching the whole-project script
# meant naming .#cider-buck2-prefix, the FULL endpoint, whose graph is not the one the gate
# builds, so the "seconds" check kicked off a full graph rebuild instead: buck2 and the
# generator were still running at 96 seconds. It now asks the gated endpoint for the script
# it actually runs, via the stageProjectUsed attribute.
#
# The two shapes assert different things, so the checks are split. Both plant the pins the
# same way, from wantedPins verbatim, which is why the pin assertions are shared.
#
# Verified BOTH WAYS, which is possible here because the broken scripts are still in the
# store: it fails on the ones the regressions generated and passes on the current one.
#
# Usage:
#   scripts/buck-lowering-stage-check.nu                 # build the current one and check it
#   scripts/buck-lowering-stage-check.nu --script <path> # check a specific staging script
#   scripts/buck-lowering-stage-check.nu --endpoint .#cider-buck2-prefix.stageProject

def say [msg: string] { print -e $msg }

def main [
    --script: string = ""
    # THE GATED ENDPOINT, not the full one. Naming the wrong endpoint here does not fail,
    # it silently costs a graph build, which is the whole thing this check exists to avoid.
    --endpoint: string = ".#cider-buck2-prefix-min.stageProjectUsed"
] {
    let path = if ($script | is-not-empty) {
        $script
    } else {
        # Attached to the endpoint with `.`, so this builds the little staging script and
        # NOT the endpoint. It does need graph.json, which is an IFD: with that endpoint's
        # graph derivation already in the store this is seconds, without it, it is a graph
        # build.
        let r = (^nix build $endpoint --no-link --print-out-paths | complete)
        if $r.exit_code != 0 {
            say $"could not build ($endpoint)"
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

    # WHICH SHAPE IS THIS. The grouped one mirrors each source group it reads into place and
    # references no shared project path at all, which is the point of #54; the whole-project
    # one links the project in entry by entry.
    let groups = ($lines | where {|l| $l =~ '^_g=' })
    let grouped = ($groups | is-not-empty)
    say (if $grouped { $"shape: GROUPED, ($groups | length) source group\(s) mirrored" } else { "shape: WHOLE PROJECT" })

    # ---- shared: the pins, which both shapes stage identically ----------------------
    #
    # 1. The pins land under src/external. Without these the SDK symlink farm does not
    #    resolve.
    let pins = ($lines | where {|l| $l =~ '^ln -sfn [^ ]+ pins/' })
    # 2. EVERY buck-src ALIAS MUST BE UNIQUE. A pin is aliased as buck-src/<basename> and
    #    basenames are NOT unique: pins/ciderd/xnu-sys/xnu ends in xnu exactly like
    #    pins/xnu, so both claimed buck-src/xnu and the second silently overwrote the
    #    first. Everything resolving through buck-src/xnu then got the wrong tree, which
    #    surfaced 90 minutes later as "redeclaration of __dso_handle with a different type"
    #    in the Security cone, naming SDK headers that have nothing to do with xnu.
    let aliases = ($lines | where {|l| $l =~ '^ln -sfn [^ ]+ buck-src/' }
        | each {|l| $l | split row " " | last })
    let dupe_aliases = ($aliases | uniq -d)
    # 3. AND NO rm -f AGAINST A PIN PATH. rm -f cannot remove a DIRECTORY, so where the path
    #    is already a real directory the removal failed and the ln that followed created the
    #    link INSIDE it. It has to be rm -rf. Every other check here passed while this was
    #    broken, which is why it is here: they assert the shape of the tree, not the pin lines.
    # PER LINE, AND THAT MATTERS FOR THE LOOKAHEAD. Measured 2026-08-12: nushell stops
    # honouring a lookaround somewhere between 400,000 and 1,000,000 characters, and a pattern
    # that cannot match then returns TRUE. These are single lines of a staging script, so this
    # is far below the threshold; do not lift it onto the whole script text.
    let bad_rm = ($lines | where {|l| $l =~ '^rm -f (?!-)' })
    # 4. pins has to be a REAL directory, in both shapes, because planting a pin
    #    inside a store path is a permission error.
    let mk_external = ($lines | where {|l| $l =~ '^mkdir -p ([^ ]+ )*pins( |$)' })

    mut failed = false
    if ($pins | is-empty) {
        say "FAIL: no pin is planted at pins/<pin>"
        $failed = true
    }
    if ($mk_external | is-empty) {
        say "FAIL: no `mkdir -p pins`, so pins is not a real directory"
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

    mut src_entries = []
    if $grouped {
        # ---- the grouped shape ------------------------------------------------------
        #
        # 5. A GROUP IS MIRRORED, NOT LINKED. Handed over as one symlink to a directory, a
        #    relative parent inside it is resolved against the REAL parent in the store and
        #    leaves our tree; 2,306 of the 2,970 symlinks under darwin, src and linux are
        #    relative and cross a group boundary. So every group gets a real directory.
        let mk_group = ($lines | where {|l| $l == 'mkdir -p "$_d"' })
        # 6. --no-preserve=all IS LOAD BEARING. With any preserve at all, cp applies the
        #    source mode to the symlink it just created and chmod FOLLOWS a symlink, so it
        #    walks back through the link and changes THE SOURCE. It was caught because a
        #    scratch run left three tracked files at 755; against a group store the same
        #    call would try to chmod inside /nix/store.
        let cp_all = ($lines | where {|l| $l =~ '^cp -Rsf ' })
        let cp_safe = ($lines | where {|l| $l =~ '^cp -Rsf --no-preserve=all ' })
        # 7. AND THE PER-FILE RELINK LOOP, which is not optional: cp -as points our link AT
        #    the store's symlink, which then resolves inside the STORE, so a target in
        #    another group store dangles.
        let relink = ($lines | where {|l| $l =~ 'readlink "\$_g/\$_l"' })

        if ($mk_group | length) != ($groups | length) {
            say $"FAIL: ($groups | length) group\(s) but ($mk_group | length) `mkdir -p \"$_d\"`, so a group is"
            say "      not being given a real directory to be mirrored into"
            $failed = true
        }
        if ($cp_all | length) != ($cp_safe | length) {
            say $"FAIL: ($cp_all | length) bulk cp but only ($cp_safe | length) with --no-preserve=all. Without it"
            say "      cp chmods THROUGH the symlink it just made and modifies the source, in the"
            say "      store or in the working tree:"
            $cp_all | where {|l| not ($l =~ '--no-preserve=all') } | first 3 | each {|l| say $"  ($l)" }
            $failed = true
        }
        if ($relink | length) != ($groups | length) {
            say $"FAIL: ($groups | length) group\(s) but ($relink | length) per-file relink loop\(s). cp -as alone points"
            say "      our link at the store symlink, so a cross-group target dangles"
            $failed = true
        }
    } else {
        # ---- the whole-project shape ------------------------------------------------
        #
        # 8. src must NOT be a symlink into the store. This is the original regression.
        let src_link = ($lines | where {|l| $l =~ '^ln -s [^ ]+/src src$' })
        # 9. ... and src/ is populated entry by entry, which is what makes it usable at all.
        $src_entries = ($lines | where {|l| $l =~ '^ln -s [^ ]+/src/[^ ]+ src/' })

        if ($src_link | is-not-empty) {
            say $"FAIL: src is symlinked into the store, so nothing can be planted under it:"
            $src_link | each {|l| say $"  ($l)" }
            $failed = true
        }
        if ($src_entries | length) < 10 {
            say $"FAIL: only ($src_entries | length) src/<entry> links, expected the whole of src/"
            $failed = true
        }
    }

    if $failed {
        say ""
        say "The staging script cannot build. See the top-level exclusion list in"
        say "nix/lib/ciderBuck2Lower.nix: src, buck-src, buck-out and buck-rust all have to"
        say "stay out of the symlink-everything loop, because each is rebuilt below it."
        exit 1
    }
    if $grouped {
        say $"PASS: ($groups | length) group\(s) mirrored into real directories, ($pins | length) pin\(s) planted under pins"
    } else {
        say $"PASS: src is a real directory, ($src_entries | length) entries linked into it, ($pins | length) pin\(s) planted under pins"
    }
    exit 0
}
