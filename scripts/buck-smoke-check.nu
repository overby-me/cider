#!/usr/bin/env nu
# tests/cider-smoke.nix's assertions, against the BUCK2-built Darling, without a VM.
#
# The smoke test itself runs in a NixOS test VM, and Darling hangs in one (a pre-existing
# problem, not the port's -- task #12). Its assertions do not need a VM: they need a prefix
# and a container, which scripts/buck-bash-check.nu already produces. So this drives the
# same checks here, and what remains blocked on the VM is the harness rather than the claim.
#
# Stages, numbered as they are in tests/cider-smoke.nix:
#   2  shell, environment, exit codes
#   3  macOS identity (uname, sw_vers)
#   4  filesystem basics (files, directories, symlinks)
#   5  sandbox-exec, including the -D form Nix uses
#   6  diskutil info / list
#   7  Directory Services: dseditgroup, sysadminctl, dscl
#
# Stage 1 is prefix creation, which is what getting this far already proves, and stage 8 is
# a warning scan that fails nothing.
#
# Usage:  scripts/buck-smoke-check.nu
# Run scripts/buck-bash-check.nu first -- this drives the root it materializes.
#
# Converted from bash (task #40). The GUEST script below stays bash and is embedded verbatim,
# because it runs inside Darling where there is no nushell: only the host-side wrapper is
# nushell. Verified by running BOTH versions against a real container and diffing the whole
# output, which for this check is 30 assertions plus the tally.

def say [msg: string] { print -e $msg }

def main [] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    let rt = ($env.BUCK2_RT? | default $"/tmp/cider-buck2-(^id -u | str trim)/rt")
    # SHORT, because the daemon's control socket lives in the prefix and a Unix socket path is
    # capped at 108 bytes.
    let prefix_dir = ($env.DPREFIX? | default $"/tmp/cider-smoke-(^id -u | str trim)")

    if not ($"($rt)/bin/cider" | path exists) {
        say $"no materialized prefix at ($rt)"
        say "run scripts/buck-bash-check.nu first -- it builds //buck/prefix:cider_prefix and"
        say "copies it there, which is what this check then drives."
        exit 2
    }

    # pkill -x, never -f: an -f pattern matches the command line of the shell running it. One
    # name per call, because a multi-pattern pkill matches nothing and exits 2.
    for n in [cider ciderd mldr shellspawn] { do -i { ^pkill -9 -x $n } }
    # GNU rm: the overlay workdir holds a `work` directory at mode 000.
    ^rm -rf $prefix_dir $"($prefix_dir).workdir"

    # One container invocation for the whole run: booting costs more than every check in here
    # put together, and the stages are not independent anyway (stage 7 builds up a user and a
    # group and then takes them away again).
    let guest = '
set +e
say() { printf "%s\n" "$*"; }
ok() { say "SMOKE ok   $1"; }
no() { say "SMOKE FAIL $1: $2"; }
is() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "$2" ;; esac; }

# -- stage 2: shell ------------------------------------------------------------
is "echo passes through"        "$(echo hello-from-cider)"      hello-from-cider
[ -n "$HOME" ] && ok "HOME is set" || no "HOME is set" empty
( exit 0 ); [ $? -eq 0 ] && ok "exit 0 propagates" || no "exit 0 propagates" "$?"
( exit 1 ); [ $? -eq 1 ] && ok "exit 1 propagates" || no "exit 1 propagates" "$?"

# -- stage 3: macOS identity ---------------------------------------------------
is "uname -s is Darwin"         "$(uname -s)"                     Darwin
is "uname -m is x86_64"         "$(uname -m)"                     x86_64
[ -n "$(sw_vers -productName)" ] && ok "sw_vers -productName" || no "sw_vers -productName" empty
case "$(sw_vers -productVersion)" in
[0-9]*.[0-9]*) ok "sw_vers -productVersion looks like a version" ;;
*) no "sw_vers -productVersion looks like a version" "$(sw_vers -productVersion)" ;;
esac

# -- stage 4: filesystem -------------------------------------------------------
echo test-content > /tmp/smoke-test.txt
is "a file reads back"          "$(cat /tmp/smoke-test.txt)"      test-content
mkdir -p /tmp/smoke-dir/sub && [ -d /tmp/smoke-dir/sub ] &&
	ok "mkdir -p" || no "mkdir -p" "not a directory"
ln -sf /tmp/smoke-test.txt /tmp/smoke-link
is "a symlink reads back"       "$(cat /tmp/smoke-link)"          test-content
rm -f /tmp/smoke-test.txt /tmp/smoke-link
rm -rf /tmp/smoke-dir
[ ! -e /tmp/smoke-test.txt ] && ok "rm removes" || no "rm removes" "still there"

# -- stage 5: sandbox-exec -----------------------------------------------------
[ -x /usr/bin/sandbox-exec ] && ok "sandbox-exec is executable" ||
	no "sandbox-exec is executable" "not executable"
is "sandbox-exec -f passes through" \
	"$(/usr/bin/sandbox-exec -f /dev/null /bin/echo sandbox-ok 2>&1)" sandbox-ok
is "sandbox-exec -p takes an inline profile" \
	"$(/usr/bin/sandbox-exec -p "(version 1)(allow default)" /bin/echo inline-ok 2>&1)" inline-ok
# The shape Nix itself invokes it with.
is "sandbox-exec -D takes parameters" \
	"$(/usr/bin/sandbox-exec -f /dev/null -D _GLOBAL_TMP_DIR=/tmp -D IMPORT_DIR=/tmp \
		/bin/echo nix-pattern-ok 2>&1)" nix-pattern-ok
/usr/bin/sandbox-exec -f /dev/null /bin/bash -c "exit 42" 2>/dev/null
[ $? -eq 42 ] && ok "sandbox-exec forwards the exit code" ||
	no "sandbox-exec forwards the exit code" "$?"

# -- stage 6: diskutil ---------------------------------------------------------
[ -x /usr/sbin/diskutil ] && ok "diskutil is executable" || no "diskutil is executable" "no"
is "diskutil info / reports apfs"      "$(/usr/sbin/diskutil info / 2>&1)"        APFS
is "diskutil info -plist / has a type" "$(/usr/sbin/diskutil info -plist / 2>&1)" FilesystemType
is "diskutil list has disk0"           "$(/usr/sbin/diskutil list 2>&1)"          disk0

# -- stage 7: Directory Services -----------------------------------------------
for t in dscl dseditgroup sysadminctl; do
	[ -x "/usr/sbin/$t" ] && ok "$t is executable" || no "$t is executable" "not executable"
done
/usr/sbin/dseditgroup -o create -q -i 39999 smoketest >/dev/null 2>&1
is "dseditgroup creates a group"  "$(grep smoketest /etc/group)"    39999
/usr/sbin/sysadminctl -addUser _smoketest -UID 399 -GID 39999 \
	-home /var/empty -shell /usr/bin/false >/dev/null 2>&1
is "sysadminctl creates a user"   "$(grep _smoketest /etc/passwd)"  399
/usr/sbin/dseditgroup -o edit -a _smoketest -t user smoketest >/dev/null 2>&1
is "dscl reads the membership" \
	"$(/usr/sbin/dscl . -read /Groups/smoketest GroupMembership 2>&1)" _smoketest
is "dscl reads the uid" \
	"$(/usr/sbin/dscl . -read /Users/_smoketest UniqueID 2>&1)"        399
/usr/sbin/dseditgroup -o checkmember -m _smoketest smoketest >/dev/null 2>&1 &&
	ok "dseditgroup checkmember" || no "dseditgroup checkmember" "not a member"
/usr/sbin/sysadminctl -deleteUser _smoketest >/dev/null 2>&1 &&
	ok "sysadminctl deletes the user" || no "sysadminctl deletes the user" "failed"
/usr/sbin/dseditgroup -o delete smoketest >/dev/null 2>&1 &&
	ok "dseditgroup deletes the group" || no "dseditgroup deletes the group" "failed"
say "SMOKE DONE"'
    # out+err> into one file rather than `complete`, which would hand back stdout and stderr
    # separately and put every SMOKE line before every daemon line.
    let log = (mktemp --tmpdir buck-smoke-check.XXXXXX)
    with-env {
        DPREFIX: $prefix_dir
        DARLING_NO_LAUNCHD: "1"
        DSERVER_LIBEXEC_PATH: $"($rt)/libexec/cider"
        DSERVER_MLDR_PATH: $"($rt)/libexec/cider/usr/libexec/cider/mldr"
    } {
        do -i { ^timeout 300 $"($rt)/bin/cider" shell /bin/bash -c $guest out+err> $log }
    }
    let out = (open --raw $log | str trim --right --char "\n")
    rm -f $log

    # Only the harness's own lines, so the prefix-creation chatter on a first boot does not read
    # as output of a check.
    let lines = ($out | lines)
    $lines | where {|l| $l starts-with "SMOKE " } | each {|l| print $l }

    let passed = ($lines | where {|l| $l starts-with "SMOKE ok " } | length)
    let failed = ($lines | where {|l| $l starts-with "SMOKE FAIL" } | length)
    if not ($out | str contains "SMOKE DONE") {
        say ""
        say "FAIL: the container did not finish the run"
        exit 1
    }

    say ""
    say $"($passed) passed, ($failed) failed"
    if $failed != 0 { exit 1 }
    say "PASS: the buck2-built Darling meets tests/cider-smoke.nix stages 2-7"
}
