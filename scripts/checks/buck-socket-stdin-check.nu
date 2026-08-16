#!/usr/bin/env nu
# Does the guest still survive a SOCKET on stdin?
#
# bash calls getpeername from isnetconn (lib/sh/netconn.c) for every shell whose stdin is a
# socket, handing it a 16 byte struct sockaddr on its own stack. sockaddr_fixup_from_linux
# converted the reply IN THAT BUFFER while knowing only how many bytes the kernel had
# written, never how large the buffer was, and on the PF_LOCAL branch wrote a full 104 byte
# sun_path plus a terminator into it. bash died in __stack_chk_fail, silently, with SIGABRT.
# Fixed by patches/xnu/0009-sockaddr-fixup-respect-caller-buffer.patch.
#
# Nothing else in the suite would notice that coming back. Every other runtime check either
# inherits a terminal or redirects stdin, and the failure is invisible from the build side:
# it links, it loads, it runs everywhere except under a caller whose stdin is a socket. That
# is exactly what a CI harness, an ssh session and the NixOS test driver all are, and under
# the driver it read as Darling hanging for months (task #12).
#
# AF_UNIX specifically. An AF_INET socket takes a different branch and survived even unfixed,
# so a check built on /dev/tcp would pass against the bug.
#
# Usage:
#   scripts/checks/buck-socket-stdin-check.nu [--prefix <dir>] [--scratch <dir>]
#
# Exit 0 pass, 1 fail, 2 infrastructure.
#
# Verified both ways against real artifacts rather than a fixture: it passes against a prefix
# built with the patch and fails against one built without it.

def say [msg: string] { print $msg }

def main [
    --prefix: string = ""    # a built prefix tree; default: buck2 build //buck/prefix:cider_prefix
    --scratch: string = ""   # scratch root; default /tmp/cider-socket-stdin-<uid>
] {
    cd ($env.FILE_PWD | path join ".." ".." | path expand)

    mut art = $prefix
    if ($art | is-not-empty) and (($art | path type) != "dir") {
        say $"not a directory: ($art)"
        exit 2
    }

    # SHORT, like the other runtime checks: the daemon's control socket lives inside the
    # prefix and a Unix socket path is capped at 108 bytes.
    # `| default` substitutes for NULL, not for an empty string, and a flag declared
    # `--scratch: string = ""` is the empty string when omitted. Writing it that way made root
    # EMPTY, so the cleanup loop below matched every process whose exe starts with a slash and
    # killed an unrelated build of mine. The sibling checks take scratch as an optional
    # POSITIONAL, which really is null when omitted, which is why they never showed this.
    let root = (if ($scratch | is-empty) { $"/tmp/cider-sockstdin-(^id -u | str trim)" } else { $scratch })
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

    # Anything still running out of THIS scratch root holds the old tree mounted. By exe
    # symlink rather than by name, so it cannot match another check's daemon or this script.
    #
    # try/catch rather than do -i around the kill: a PID that exits between the listing and
    # the kill is the normal case when a daemon and its guests are going down together, and
    # with do -i the run ended right there, silently, having printed only the kill error.
    #
    # And a guard on the prefix itself, because the cost of getting it wrong is killing
    # processes that have nothing to do with this check. A root has to be an absolute path
    # under /tmp with a name after it; anything else means the caller or a default went wrong
    # and the right move is to stop, not to sweep.
    if not ($root =~ '^/tmp/[A-Za-z0-9._-]+') {
        say $"refusing to sweep processes for a suspicious scratch root: ($root)"
        exit 2
    }
    for p in (ls /proc | get name | where {|n| ($n | path basename) =~ '^[0-9]+$' }) {
        let exe = (try { ^readlink $"($p)/exe" | str trim } catch { "" })
        if ($exe | str starts-with $"($root)/") {
            try { ^kill -9 ($p | path basename) } catch { }
        }
    }

    say $"== materializing into ($rt) =="
    if ($rt | path exists) { try { ^chmod -R u+w $rt } catch { } }
    # GNU rm, not nushell's: the overlay workdir the daemon leaves behind holds a `work`
    # directory at mode 000, which remove_dir_all just fails on.
    ^rm -rf $rt $prefix_dir $"($prefix_dir).workdir"
    mkdir $rt $prefix_dir
    # -a and never -aL: the prefix installs Volumes/DarlingEmulatedDrive -> /.
    ^cp -a $"($art)/." $"($rt)/"
    ^chmod -R u+w $rt

    # python3 only to get the fd: nushell cannot hand a child an AF_UNIX socketpair as stdin,
    # and that fd IS the test. Everything else stays here.
    let helper = (mktemp --tmpdir buck-socket-stdin.XXXXXX.py)
    let py = "
import os, socket, subprocess, sys
rt, dprefix, tag = sys.argv[1], sys.argv[2], sys.argv[3]
env = dict(os.environ)
env.update({'CIDERPREFIX': dprefix, 'DARLING_NO_LAUNCHD': '1',
            'DSERVER_LIBEXEC_PATH': rt + '/libexec/cider',
            'DSERVER_MLDR_PATH': rt + '/libexec/cider/usr/libexec/cider/mldr'})
if tag == 'sock':
    a, _b = socket.socketpair()          # AF_UNIX: the branch that used to smash the stack
    fd = a.fileno()
else:
    fd = os.open('/dev/null', os.O_RDONLY)
p = subprocess.run([rt + '/bin/cider', 'shell', '/bin/bash', '-c',
                    'echo SOCKSTDIN_' + tag.upper() + '_OK $BASH_VERSION'],
                   stdin=fd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                   env=env, timeout=180)
sys.stdout.write(p.stdout.decode('utf-8', 'replace'))
sys.exit(p.returncode)
"
    $py | save -f -r $helper

    mut failed = 0
    for arm in [[tag, want]; ["null", "SOCKSTDIN_NULL_OK"] ["sock", "SOCKSTDIN_SOCK_OK"]] {
        let dp = $"($prefix_dir)-($arm.tag)"
        ^rm -rf $dp $"($dp).workdir"
        let r = (do -i { ^timeout 240 python3 $helper $rt $dp $arm.tag } | complete)
        let out = (($r.stdout + $r.stderr) | str trim)
        if ($out | str contains $arm.want) and $r.exit_code == 0 {
            say $"  ok   stdin=($arm.tag): ($arm.want)"
        } else {
            $failed = $failed + 1
            say $"  FAIL stdin=($arm.tag): rc=($r.exit_code)"
            for l in ($out | split row "\n" | last 6) { say $"       ($l)" }
        }
    }
    rm -f $helper

    if $failed == 0 {
        say "PASS: a socket on stdin is survivable, and so is /dev/null"
        exit 0
    }
    say ""
    say "A socket on stdin is what a CI harness, an ssh session and the NixOS test driver all"
    say "hand the guest. If only the sock arm failed, suspect the sockaddr conversion again."
    exit 1
}
