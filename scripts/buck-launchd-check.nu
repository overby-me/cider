#!/usr/bin/env nu
# Boot the buck2-built Darling through LAUNCHD and run a command inside it.
#
# The sibling check (buck-bash-check.nu) sets DARLING_NO_LAUNCHD=1, which runs the command
# directly and skips init entirely. This one takes the real path: launchd comes up as guest pid
# 1, `launchctl bootstrap -S System` loads the system jobs, those jobs start, and only then does
# the requested command run via shellspawn. It exercises the whole Mach IPC core -- portsets,
# blocking mach_msg receives across processes, OOL descriptor copyout, and the S2C calls that
# back them -- which the no-launchd path never touches.
#
# It stayed broken for a long time (task #47) and the failure was silent: the container just
# never finished. So it gets its own check, because "bash runs" does not imply "init works".
#
# Converted from bash (task #40) and verified by running BOTH versions against a real container
# and comparing the verdict, the exit code and the guest transcript, plus the --prefix argument
# error, which needs no container.
#
# Usage:  scripts/buck-launchd-check.nu [--prefix <dir>] [<scratch dir>]

def say [msg: string] { print -e $msg }

def main [--prefix: string = "", scratch?: string] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    mut art = $prefix
    if ($art | is-not-empty) and (($art | path type) != "dir") {
        say $"not a directory: ($art)"
        exit 2
    }

    # Short by default: <prefix>/.ciderd.sock has to fit in a 108-byte sun_path.
    let root = ($scratch | default $"/tmp/cider-buck2-(^id -u | str trim)")
    let rt = $"($root)/rt"
    let prefix_dir = $"($root)/prefix-launchd"

    if ($art | is-empty) {
        if (which buck2 | is-empty) {
            say "missing buck2 -- run inside `nix develop`"
            exit 2
        }
        say "== building the prefix =="
        let b = (^buck2 build //buck/prefix:cider_prefix --show-output | complete)
        $art = ($b.stdout | lines | last | default "" | split row " " | get 1? | default "")
        if ($art | path type) != "dir" {
            say "the prefix did not build"
            exit 1
        }
    }

    # Anything still running from a previous run holds the old prefix mounted.
    for p in (ls /proc | get name | where {|n| ($n | path basename) =~ '^[0-9]+$' }) {
        let exe = (do -i { ^readlink $"($p)/exe" | str trim } | default "")
        if ($exe | str starts-with $"($root)/") {
            do -i { ^kill -9 ($p | path basename) }
        }
    }

    say $"== materializing into ($rt) =="
    do -i { ^chmod -R u+w $rt }
    # GNU rm: the overlay workdir left behind holds a `work` directory at mode 000, which
    # nushell's remove_dir_all cannot enter and GNU rm chmods its way into.
    ^rm -rf $rt $prefix_dir $"($prefix_dir).workdir"
    # Only $rt. The prefix directory must NOT be pre-created: cider treats an existing DPREFIX
    # as one it has already set up, so creating it empty skips first-time setup entirely and
    # launchd then boots into an unpopulated filesystem and stalls (deterministically, at ~509
    # lines of daemon log). The no-launchd check gets away with it because running one command
    # directly needs almost none of what that setup lays down.
    mkdir $rt
    # `cp -a`, never `cp -aL`: see buck-bash-check.nu.
    ^cp -a $"($art)/." $"($rt)/"
    ^chmod -R u+w $rt

    say "== booting the container through launchd =="
    # No DARLING_NO_LAUNCHD here -- that is the entire point of this check. The guest script
    # lives in a variable because a newline inside an external command ends it.
    let guest_cmd = 'echo BUCK2_LAUNCHD_OK $BASH_VERSION $MACHTYPE'
    # out+err> into one file, NOT `complete`: complete hands back stdout and stderr separately,
    # so concatenating them puts every guest line before every daemon line. bash got the real
    # order for free from 2>&1, and for a launchd boot that order IS the diagnosis.
    let log = (mktemp --tmpdir buck-launchd-check.XXXXXX)
    with-env {
        DPREFIX: $prefix_dir
        DSERVER_LIBEXEC_PATH: $"($rt)/libexec/cider"
        DSERVER_MLDR_PATH: $"($rt)/libexec/cider/usr/libexec/cider/mldr"
    } {
        do -i { ^timeout 180 $"($rt)/bin/cider" shell /bin/bash -c $guest_cmd out+err> $log }
    }
    let out = (open --raw $log | str trim --right --char "\n")
    rm -f $log
    print $out

    # The home-directory template copy ("cp: /Users/root: No such file or directory") is
    # expected noise: /Users/root is not part of the prefix. It does not stop the boot, so it is
    # not asserted on either way.
    if $out =~ '(?s)BUCK2_LAUNCHD_OK.*darwin' {
        say "PASS: the buck2-built Darling boots through launchd and runs a command"
        exit 0
    } else if $out =~ 'BUCK2_LAUNCHD_OK' {
        say "PARTIAL: the command ran but did not report a Darwin build"
        exit 1
    } else {
        say "FAIL: the container did not finish with launchd as init"
        exit 1
    }
}
