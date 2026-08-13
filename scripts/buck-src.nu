#!/usr/bin/env nu
# Materialize nix-pinned upstream sources into vendor/src/ for the Buck2 port.
#
# Most of Darling's source is already in this repo, but a few trees are nix pins
# (nix/submodules.json) with no working copy: `nix build` assembles them into the store, which
# a direct `buck2 build` cannot see (buck2 needs its sources inside the project root, and a
# symlink into the store would make it crawl the closure).
#
# So this fetches the SAME pinned revision + hash nix uses, and copies it into vendor/src/<name>/
# (gitignored). The BUCK file that builds these trees is vendor/src/BUCK, which is committed: a
# buck2 package owns its subdirectories, so one checked-in BUCK file can define targets over all
# materialized trees without putting a BUCK file inside any of them.
#
# --all copies out of the nix-ASSEMBLED tree (`nix build .#cider-src`) rather than fetching
# 147 pins one at a time: one derivation, and its patches and symlink fixups are already
# applied. It is what the guest tier needs, because a Darwin compile's include path is the SDK
# tree (src/darwin/Developer/.../MacOSX.sdk/usr/include), ~1900 committed symlinks into these trees
# -- with them absent, 1909 of those links dangle.
#
# Converted from bash (task #40). Tested against the bash version in an isolated tree -- a
# scratch root holding only scripts/, nix/submodules.json and the flake, so vendor/src/ there is
# empty and the copying paths run for real without touching this repo's 3.8 GB of pins. Both
# versions were driven over: a cold fetch of a small pin, the same pin again (the rev-stamp
# skip), FORCE=1 over it, a path with no manifest entry, a scratch patches/<name>/*.patch to
# exercise the patch loop, and --all's skip path against materialized stamps. Resulting trees
# were compared file by file, not just the output.
#
# Usage:  scripts/buck-src.nu [<submodule-path> ...]
#         scripts/buck-src.nu                      # the port's current needs
#         scripts/buck-src.nu --all                # every pinned tree (~3.8 GB)
#         FORCE=1 scripts/buck-src.nu <path>       # re-fetch even if present

# What the port needs so far:
#  - bootstrap_cmds: migcom + mig.sh, which every MIG codegen edge runs.
#  - xnu: the Darwin headers migcom's own sources compile against (mach/*.h). The repo's SDK
#    tree reaches these through ~1900 relative symlinks that only resolve in the nix-assembled
#    tree, so the Buck2 port declares the header roots it needs directly from the source trees
#    instead.
const DEFAULT_PATHS = ["vendor/pins/bootstrap_cmds" "vendor/pins/xnu"]

# THE PIN ROOT, in one place, because the rule below is DIRECTLY UNDER THE PIN ROOT and not
# a fixed depth. It read `== 3` while the root was src/external (NO-PIN-REWRITE); writing `== 2` for vendor/pins/
# would reseat the same landmine for whoever renames it next. Both copies of the test below
# derive from this, so they cannot drift apart the way the rename tables once did.
const PIN_ROOT_DEPTH = 2   # "vendor/pins" is two components

def say [msg: string] { print -e $msg }

def main [--all, ...paths: string] {
    let repo_root = ($env.FILE_PWD | path join ".." | path expand)
    let manifest = ($repo_root | path join "nix/submodules.json")
    let dest_root = ($repo_root | path join "vendor/src")
    let force = ($env.FORCE? | default "" | is-not-empty)
    let entries = (open --raw $manifest | from json)

    mkdir $dest_root

    if $all {
        print "vendor/src: realizing the assembled tree (nix build .#cider-src) ..."
        let assembled = (^nix build $"($repo_root)#cider-src" --no-link --print-out-paths
            | str trim | lines | last)
        print $"vendor/src: assembled at ($assembled)"

        let all_entries = ($entries | where {|e| ($e.hash? | default "") | is-not-empty })
        print $"vendor/src: copying ($all_entries | length) pinned trees ..."
        for e in $all_entries {
            let sub = $e.path
            let name = ($sub | path basename)
            # A NESTED PIN GOES TO ITS OWN PATH, never vendor/src/<basename>. Basenames are NOT
            # unique: vendor/pins/ciderd/xnu-sys/xnu ends in xnu just like vendor/pins/xnu,
            # so both would land in vendor/src/xnu and copy over each other. The same collision
            # broke the Nix endpoint through ciderBuck2Graph.nix materializePins, and the fix
            # here matches: only a pin directly under pins takes the vendor/src route.
            let dest = (if (($sub | split row "/" | length) == ($PIN_ROOT_DEPTH + 1)) {
                $dest_root | path join $name
            } else {
                $repo_root | path join $sub
            })
            let src = ($assembled | path join $sub)
            if ($src | path type) != "dir" {
                print $"vendor/src: WARNING ($sub) missing from the assembled tree"
                continue
            }
            let stamp = ($dest | path join ".buck-src-assembled")
            let stamped = (($stamp | path exists) and ((open --raw $stamp | str trim) == $assembled))
            if (not $force) and $stamped {
                continue
            }
            if ($dest | path exists) { do -i { ^chmod -R u+w $dest } }
            rm -rf $dest
            # Plain copy, NOT hardlinks: hardlinked store files share the store's inode, so any
            # later chmod/write would mutate the nix store itself. Left read-only; nothing here
            # is edited, only compiled.
            ^cp -a --no-preserve=ownership $src $dest
            # The copy inherits the store's read-only mode, so the stamp needs the directory
            # itself made writable first (only the directory, not the tree: nothing in here is
            # edited).
            ^chmod u+w $dest
            # With the trailing newline echo wrote, so a tree stamped by either version
            # is byte-identical. The readers strip it, but the file should not differ.
            $"($assembled)\n" | save -f $stamp
            # AND THE REV, because the per-path branch below has to be able to tell whether
            # this tree is at the revision the manifest now asks for. Writing only the
            # assembled-tree path here is what let a bumped pin keep a stale tree: the marker
            # existed, so the per-path branch skipped, and the tree stayed on the old rev.
            $"($e.rev)\n" | save -f ($dest | path join ".buck-src-rev")
        }
        let size = (^du -sh $dest_root | split row "\t" | first)
        print $"vendor/src: done \(($size))"
        exit 0
    }

    let wanted = if ($paths | is-empty) { $DEFAULT_PATHS } else { $paths }

    for sub in $wanted {
        let name = ($sub | path basename)
        # Same nested-pin rule as the --all branch above.
        let dest = (if (($sub | split row "/" | length) == ($PIN_ROOT_DEPTH + 1)) {
            $dest_root | path join $name
        } else {
            $repo_root | path join $sub
        })

        let hits = ($entries | where path == $sub)
        if ($hits | is-empty) {
            say $"no submodule entry for ($sub)"
            exit 1
        }
        let e = ($hits | first)
        if (($e.hash? | default "") | is-empty) {
            say $"submodule ($e.path) has no pinned hash yet"
            exit 1
        }

        let stamp = ($dest | path join ".buck-src-rev")
        let stamped = (($stamp | path exists) and ((open --raw $stamp | str trim) == $e.rev))
        if (not $force) and $stamped {
            print $"vendor/src: ($name) already at ($e.rev)"
            continue
        }
        # THERE USED TO BE A SECOND SKIP HERE AND IT REPORTED SUCCESS ABOUT A STALE TREE.
        #
        # It honoured .buck-src-assembled on PRESENCE ALONE, with no comparison, on the
        # reasoning that --all had put the tree there "at the same pinned rev". That holds
        # exactly until a rev changes, and then the marker is a permanent skip: the tree stays
        # on the OLD revision while this prints that it is already materialized.
        #
        # It cost a real verification. After bumping configd, the bisect build
        # //src/darwin/frameworks:SystemConfiguration_dylib would have compiled the PREVIOUS
        # revision and passed, which is a green build proving nothing. Caught only by probing
        # for a file the new rev adds, darling/include/SystemConfiguration/CaptiveNetwork.h.
        #
        # The rev stamp above is now the only skip, and --all writes it too, so a tree
        # materialized either way is checked against the revision the manifest asks for. A tree
        # left by an older --all has no rev stamp and is simply re-fetched once, which is the
        # safe direction: correctness over one avoidable fetch.

        print $"vendor/src: fetching ($e.owner)/($e.repo) @ ($e.rev)"
        # getFlake for the pinned nixpkgs, and --impure because that reads a path outside the
        # store. The same fetchFromGitHub arguments nix/lib/cider-src.nix uses, so the fetch
        # is a store hit whenever the nix side has already been built.
        let flake = $"\(builtins.getFlake \"path:($repo_root)\"\)"
        # A list joined rather than a concatenation: in nushell a newline before an operator
        # ends the expression, so a `+` at the start of a continuation line is parsed as a
        # command name and fails with "Command `+` not found".
        let expr = ([
            $"let pkgs = ($flake).inputs.nixpkgs.legacyPackages.${builtins.currentSystem};"
            $"in pkgs.fetchFromGitHub { owner = \"($e.owner)\"; repo = \"($e.repo)\";"
            $"rev = \"($e.rev)\"; hash = \"($e.hash)\"; }"
        ] | str join " ")
        let store_path = (^nix build --impure --no-link --print-out-paths --expr $expr
            | str trim | lines | last)

        # The port's OWN files inside a pin directory, which the upstream tree knows nothing
        # about and which this function would otherwise destroy: vendor/src/<pin>/BUCK is
        # committed and generated by the port, while the pin contents are not tracked at all.
        # Losing it costs a build cycle and reports as `package root//vendor/src/<pin>: does not
        # exist, missing BUCK file`, which reads like a buck2 problem rather than this one.
        let keep = (if ($dest | path exists) {
            glob $"($dest)/**/{BUCK,BUCK.v2,extra-deps.json}" --no-dir
            | each {|f| {rel: ($f | path relative-to $dest), body: (open --raw $f)} }
        } else { [] })

        if ($dest | path exists) { do -i { ^chmod -R u+w $dest } }
        rm -rf $dest
        ^cp -a --no-preserve=ownership $store_path $dest
        ^chmod -R u+w $dest

        for k in $keep {
            let target = ($dest | path join $k.rel)
            mkdir ($target | path dirname)
            $k.body | save -f -r $target
        }
        if ($keep | is-not-empty) {
            print $"vendor/src:   kept ($keep | length) port-owned file\(s) \(BUCK, extra-deps.json)"
        }

        # Same patch application as nix/lib/cider-src.nix: patches/<name>/*.patch with
        # `patch -p1` inside the tree. xnu in particular carries the macOS identity patches, so
        # an unpatched tree is not the tree we build.
        #
        # AND THE SAME patches OVERRIDE cider-src.nix takes, for the same reason: the directory
        # is keyed by basename and basenames are not unique, so a second xnu would otherwise be
        # handed patches/xnu, which is the GUEST SYSCALL set belonging to the other one. This
        # has to agree with cider-src.nix or the local tree and the Nix tree get different
        # patches applied to the same submodule.
        let patch_dir = ($repo_root | path join "vendor" "patches" ($e.patches? | default $name))
        if ($patch_dir | path type) == "dir" {
            for p in (glob $"($patch_dir)/*.patch" | sort) {
                print $"vendor/src:   patch ($name): ($p | path basename)"
                # stdout dropped, stderr left alone: a rejected hunk has to be visible.
                open --raw $p | ^patch -p1 -d $dest --force | ignore
            }
        }

        # buck2 refuses symlinks with a "." component or a target that leaves the cell, and the
        # upstream trees contain both; re-point them at the same file inside vendor/src. See
        # src/linux/buildtools/src-normalise for the two cases.
        #
        # ON PATH, NOT A PATH IN THE TREE, since #99 made this a nix-built binary: it comes
        # from the devShell, which declares it for exactly this call. --repo is explicit
        # because the binary lives in the store and cannot find the project above itself.
        ^cider-src-normalise --repo $repo_root $dest

        $"($e.rev)\n" | save -f $stamp
        print $"vendor/src: ($name) -> ($dest)"
    }
}
