#!/usr/bin/env nu
# Boot the buck2-built Darling and run bash inside it.
#
# This is the milestone the whole port aims at: not "the targets build" but "the thing runs".
# Everything it uses comes from buck2 -- the 5,500-entry prefix, the Rust daemon, the launcher
# and the guest Mach-O loader -- so a pass means the port produced a working Darling and not
# just a pile of correct-looking artifacts.
#
# The prefix is COPIED into a scratch root first, rather than mounted out of buck-out directly:
# the container writes nothing to it, but a build tree is not a thing to hand a daemon as a root
# filesystem.
#
# Converted from bash (task #40) and checked by running BOTH versions against a real container,
# comparing the verdict, the exit code and the guest transcript, and by driving the argument
# paths that do not need one: --prefix on a directory that is not one (2), and --prefix on a
# tree with no loader in it.
#
# Usage:  scripts/buck-bash-check.nu [<scratch dir>]
#         scripts/buck-bash-check.nu --prefix <tree> [<scratch dir>]

def say [msg: string] { print -e $msg }

def main [
    # An already-built prefix to test instead of building one. This is how the same check
    # covers BOTH endpoints: with no argument it builds through the buck2 daemon, and with one
    # it takes a tree the Nix endpoint produced
    # (nix build .#cider-buck2-prefix, then result/cider_prefix__prefix).
    --prefix: string = ""
    scratch?: string
] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    mut art = $prefix
    if ($art | is-not-empty) and (($art | path type) != "dir") {
        say $"not a directory: ($art)"
        exit 2
    }

    # SHORT by default, and that is not cosmetic: the daemon's control socket lives at
    # <prefix>/.ciderd.sock and a Unix socket path is capped at 108 bytes, so a scratch
    # directory a few levels deep makes the daemon panic with "socket path too long" after it
    # has already brought all of xnu-sys up.
    let root = ($scratch | default $"/tmp/cider-buck2-(^id -u | str trim)")

    # SEATBELT, added 2026-08-12. A wrong root here SIGKILLs the user's ENTIRE login session,
    # because the cleanup loop below matches processes with `str starts-with $"($root)/"` and an
    # empty root makes that `starts-with "/"`, which is true for every process on the machine.
    # This is safe today ONLY because `scratch` is an optional POSITIONAL, so it is null when
    # absent and `| default` fills it. It becomes lethal the moment someone declares it as a flag
    # with an empty default, because `"" | default X` returns "" in nushell, not X. That is not
    # hypothetical: it is exactly what buck-darwin-rust-run.nu did when it was first written.
    # The check costs nothing and the failure costs the desktop, so it stays.
    if ($root | is-empty) or (not ($root | str starts-with "/tmp/")) {
        print -e $"  refusing to run: scratch root must be a path under /tmp, got [($root)]"
        exit 2
    }

    let rt = $"($root)/rt"
    let prefix_dir = $"($root)/prefix"

    if ($art | is-empty) {
        if (which buck2 | is-empty) {
            say "missing buck2 -- run inside `nix develop`"
            exit 2
        }
        say "== building the prefix =="
        # STDERR TO A FILE. `| complete` buffers it, this builds the WHOLE prefix, and on a
        # cold one buck2 emits gigabytes of progress: that is the 17.3 GB the suite was
        # killed at. Nothing here ever read the stderr, so it was paid for and thrown away,
        # and a failure printed no reason. Now it is on disk and the message names it.
        let errf = (($env.TMPDIR? | default "/tmp") + "/cider-prefix-build.err")
        let b = (^buck2 build //buck/prefix:cider_prefix --show-output err> $errf | complete)
        $art = ($b.stdout | lines | last | default "" | split row " " | get 1? | default "")
        if ($art | path type) != "dir" {
            say $"the prefix did not build, see ($errf)"
            exit 1
        }
    }

    # Anything still running from a previous run holds the old prefix mounted, and removing the
    # tree underneath a live daemon leaves it wedged -- so this comes FIRST. By exe symlink
    # rather than by name: it kills exactly the processes running out of THIS scratch root, and
    # cannot match another check's daemon or this script.
    for p in (ls /proc | get name | where {|n| ($n | path basename) =~ '^[0-9]+$' }) {
        # readlink, not path expand: this asks what /proc/N/exe POINTS AT, and a process that
        # has exited between the listing and here just yields nothing.
        let exe = (do -i { ^readlink $"($p)/exe" | str trim } | default "")
        if ($exe | str starts-with $"($root)/") {
            do -i { ^kill -9 ($p | path basename) }
        }
    }

    say $"== materializing into ($rt) =="
    # Only ever removes what this script created.
    do -i { ^chmod -R u+w $rt }
    # GNU rm, not nushell's: the overlay workdir the daemon leaves behind contains a `work`
    # directory at mode 000, and rm chmods a directory it owns to get into it while nushell's
    # rm is remove_dir_all, which just returns EACCES. This is the one place that difference
    # shows, and it stops the check dead before it boots anything.
    ^rm -rf $rt $prefix_dir $"($prefix_dir).workdir"
    mkdir $rt $prefix_dir
    # `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /, so
    # dereferencing indiscriminately walks the whole machine (it copied 82 GB once). -a is
    # correct here because prefix_tree already resolved every installed artifact into a real
    # file; the only symlinks left are the 72 the layout itself declares, and those have to
    # survive as links.
    ^cp -a $"($art)/." $"($rt)/"
    ^chmod -R u+w $rt

    say "== booting the container and running bash =="
    # DARLING_NO_LAUNCHD: run the command directly instead of bringing launchd up, which is the
    # lighter of the two paths and the one that answers "does bash run".
    # In a variable, because a newline inside an external command ends it: with the script on
    # its own line, bash was invoked as `-c` with no argument and said so.
    let guest_cmd = 'echo BUCK2_BASH_OK $BASH_VERSION $MACHTYPE'
    # out+err> into one file, NOT `complete`: complete hands back stdout and stderr separately,
    # so concatenating them puts every guest line before every daemon line and the transcript
    # stops showing which came first. bash got this for free from 2>&1, and when a check fails
    # the interleaving is most of the evidence.
    let log = (mktemp --tmpdir buck-bash-check.XXXXXX)
    with-env {
        DPREFIX: $prefix_dir
        CIDER_NO_LAUNCHD: "1"
        DSERVER_LIBEXEC_PATH: $"($rt)/libexec/cider"
        DSERVER_MLDR_PATH: $"($rt)/libexec/cider/usr/libexec/cider/mldr"
    } {
        do -i { ^timeout 180 $"($rt)/bin/cider" shell /bin/bash -c $guest_cmd out+err> $log }
    }
    let out = (open --raw $log | str trim --right --char "\n")
    rm -f $log
    print $out

    # What is asserted is BASH ITSELF, not a coreutil: uname lives in the cli component, which
    # this milestone deliberately does not build (task #3 -- bash links libSystem and nothing
    # else), and the Nix-built reference cannot run it here either.
    if $out =~ '(?s)BUCK2_BASH_OK.*darwin' {
        say "PASS: the buck2-built Darling boots and runs bash"
        exit 0
    } else if $out =~ 'BUCK2_BASH_OK' {
        say "PARTIAL: bash ran but did not report a Darwin build"
        exit 1
    } else {
        say "FAIL: bash did not run inside the container"
        exit 1
    }
}
