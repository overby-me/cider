#!/usr/bin/env nu

# DOES THE vendor/src NORMALISER STILL DO ALL SIX THINGS? (#99)
#
# It is the tool that makes the materialized pins crawlable by buck2, and every one of its rules
# exists because a rule that was missing broke a build in a way nothing else could see:
#
#   a "." component            buck2 refuses the link outright
#   a target leaving the cell  buck2 refuses that too, and it is how the SDK farm links look
#   dangling inside vendor/src   recovered through FIRST_PARTY_RENAMES, which is where the
#                              security pin's 2,077 links naming the pre-Cider layout go
#   src/external re-rooting    #87 moved the pin root to vendor/pins/
#   a symlinked DIRECTORY      buck2's globs do not descend into one, so a header behind it is
#                              invisible, and expanding it is what makes it visible
#   a CYCLIC directory link    JavaScriptCore has exactly one, and expanding it made 1147
#                              directories 266 levels deep before ENAMETOOLONG stopped it
#
# WHY THIS EXISTS AS ITS OWN SCRIPT. buck-test.nu used to reach into the python and call
# expand_dir_links and rename_first_party directly. Since #99 the normaliser is a Rust binary
# (linux/buildtools/src-normalise) and there is nothing to import, so the rules are checked
# through BEHAVIOUR instead, on a repo built here for the purpose. That is strictly better
# evidence: a function returning the right string is not the same as a tree coming out right.
#
# SELF CONTAINED. It builds its own vendor/pins/ and darwin/ so it does not depend on which pins happen
# to be materialized on this machine, which is what made the earlier by-hand version fragile.
#
#   scripts/buck-src-normalise-check.nu

def say [msg: string] { print -e $msg }
def ok [msg: string] { print -e $"  ok   ($msg)" }
def bad [msg: string] { print -e $"  FAIL ($msg)" }

# name -> the target it must have AFTER the run, or "" for "must not exist any more"
const EXPECT = [
    # the "." component, rewritten without touching the filesystem
    ["p1/dot.h" "include/real.h"]
    # absolute: left alone
    ["p1/abs.h" "/etc/hostname"]
    # already resolving inside vendor/src: left alone
    ["p1/ok.h" "real2.h"]
    # dangling inside vendor/src, recovered through the rename table
    ["p1/rename.h" "../../pins/ciderd/xnu-sys/xnu/osfmk/mach/host.h"]
    # written for the pre-#87 root: src/external/<pin> is vendor/pins/<pin> now
    ["p1/oldroot.h" "../../pins/somepin/include/real.h"]
    # escapes the repo, recovered through the SDK farm, landed in the pin COPY
    ["p1/escape.h" "../somepin/include/real.h"]
    # escapes to a path that exists only under darwin/, then through the farm link there
    ["p1/farm.defs" "../somepin/include/real.h"]
    # the cyclic dir link is left exactly as it was
    ["p1/cycle" ".."]
    # the expanded directory: per-file links, subdirectory kept
    ["p1/dirlink/a.h" "../../shared/a.h"]
    ["p1/dirlink/sub/b.h" "../../../shared/sub/b.h"]
    # a BUCK file is NEVER mirrored: buck2 would read it as a second package definition
    ["p1/dirlink/BUCK" ""]
]

# The link target, or "" for anything that is not a symlink or is not there. NOT ^readlink: an
# external command that exits 1 on a missing path aborts the pipeline even inside `do -i`, and
# the check has to be able to ASK about a path that should not exist.
def link_target [p: string] {
    try { (ls -laD $p | first | get target? | default "") } catch { "" }
}

def write_file [path: string] {
    mkdir ($path | path dirname)
    "x\n" | save -f $path
}

def build_repo [repo: string] {
    # First-party trees, in the shape #87 stage 2 left them.
    write_file $"($repo)/vendor/pins/ciderd/xnu-sys/xnu/osfmk/mach/host.h"
    write_file $"($repo)/vendor/pins/somepin/include/real.h"
    # The SDK farm: a link under darwin/ pointing into vendor/pins/, which is what makes an escaping
    # link recoverable at all.
    mkdir $"($repo)/darwin/sdk-farm"
    ^ln -s "../../vendor/pins/somepin/include/real.h" $"($repo)/darwin/sdk-farm/link.h"
    mkdir $"($repo)/darwin/Developer/SDK/usr/include"
    ^ln -s "../../../../../vendor/pins/somepin/include/real.h" $"($repo)/darwin/Developer/SDK/usr/include/notify.defs"

    # The pin copies buck2 actually crawls.
    write_file $"($repo)/vendor/src/somepin/include/real.h"
    write_file $"($repo)/vendor/src/p1/include/real.h"
    write_file $"($repo)/vendor/src/p1/real2.h"
    write_file $"($repo)/vendor/src/shared/a.h"
    "# a package definition, which must NOT be mirrored\n" | save -f $"($repo)/vendor/src/shared/BUCK"
    write_file $"($repo)/vendor/src/shared/sub/b.h"

    ^ln -s "include/./real.h" $"($repo)/vendor/src/p1/dot.h"
    ^ln -s "/etc/hostname" $"($repo)/vendor/src/p1/abs.h"
    ^ln -s "real2.h" $"($repo)/vendor/src/p1/ok.h"
    ^ln -s "../darlingserver/duct-tape/xnu/osfmk/mach/host.h" $"($repo)/vendor/src/p1/rename.h"
    ^ln -s "../../../src/external/somepin/include/real.h" $"($repo)/vendor/src/p1/oldroot.h"
    ^ln -s "../../../../darwin/sdk-farm/link.h" $"($repo)/vendor/src/p1/escape.h"
    ^ln -s "../../../../Developer/SDK/usr/include/notify.defs" $"($repo)/vendor/src/p1/farm.defs"
    ^ln -s "../shared" $"($repo)/vendor/src/p1/dirlink"
    ^ln -s ".." $"($repo)/vendor/src/p1/cycle"
}

def main [] {
    cd ($env.CURRENT_FILE | path dirname | path join "..")
    say "== vendor/src normalisation: every rule, through the binary =="

    let found = (which cider-src-normalise)
    if ($found | is-empty) {
        bad "cider-src-normalise is not on PATH; it comes from the devShell (nix develop)"
        exit 1
    }
    let tool = ($found | first | get path)

    let repo = (mktemp -d)
    build_repo $repo

    # CONTROL FIRST, because a set of expectations that passes on an unnormalised tree is worth
    # nothing. Every rewriting rule must be UNSATISFIED before the tool runs.
    let before = ($EXPECT | each {|e|
        let p = $"($repo)/vendor/src/($e.0)"
        let got = (link_target $p)
        { name: $e.0, want: $e.1, got: $got }
    })
    # SEVEN of the eleven, and the number is exact rather than a floor: four expectations are
    # "leave this alone" or "this must not exist", which are met by construction before the tool
    # runs. Every REWRITING expectation must be unmet, or the run afterwards proves nothing.
    let unsatisfied = ($before | where {|r| $r.got != $r.want } | length)
    if $unsatisfied != 7 {
        bad $"($unsatisfied) of ($EXPECT | length) expectations are unmet before the run, expected 7"
        for r in ($before | where {|r| $r.got == $r.want }) { bad $"  already met: ($r.name)" }
        ^rm -rf $repo
        exit 1
    }
    ok $"control: the 7 rewriting expectations are all unmet before the run"

    let roots = (ls $"($repo)/vendor/src" | get name)
    let r = (do -i { ^$tool --repo $repo ...$roots } | complete)
    if $r.exit_code != 0 {
        bad $"the normaliser exited ($r.exit_code)"
        print -e $r.stderr
        ^rm -rf $repo
        exit 1
    }
    print -e ($r.stdout | str trim | lines | each {|l| $"       ($l)" } | str join "\n")

    mut fails = 0
    for e in $EXPECT {
        let p = $"($repo)/vendor/src/($e.0)"
        let exists = (($p | path type) != null)
        if $e.1 == "" {
            if $exists {
                bad $"($e.0) exists and must not"
                $fails += 1
            }
            continue
        }
        if not $exists {
            bad $"($e.0) is missing"
            $fails += 1
            continue
        }
        let got = (link_target $p)
        if $got != $e.1 {
            bad $"($e.0) -> ($got), wanted ($e.1)"
            $fails += 1
        }
    }
    # The expanded link must be a REAL directory now, not a link.
    if ($"($repo)/vendor/src/p1/dirlink" | path type) != "dir" {
        bad "p1/dirlink is not a real directory"
        $fails += 1
    }

    ^rm -rf $repo
    if $fails > 0 {
        print $"FAIL: ($fails) of ($EXPECT | length) expectation\(s\) not met"
        exit 1
    }
    print $"PASS: all ($EXPECT | length) expectations, every rule the normaliser has"
}
