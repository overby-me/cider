#!/usr/bin/env nu

# DOES A RUST BINARY BUILT FOR DARWIN ACTUALLY RUN INSIDE CIDER? (task #96, route A runtime half)
#
# scripts/buck-darwin-rust-build.nu proves a Rust source becomes a Mach-O executable. That is
# NOT the same claim as this one, and #16 is why the difference is worth a separate check: guest
# nix BUILT fine and then died with SIGILL on startup. Building and running are different
# questions and this answers the second.
#
#   scripts/buck-darwin-rust-run.nu --binary <mach-o> [--art <prefix artifact>]
#
# WHAT IS ASSERTED is that the binary printed its own marker, not that it exited 0. A guest
# process that dies in dyld before main can still leave a 0 somewhere, and a check that reads
# the exit code would call that a pass.
#
# THE OPERATIONAL TRAPS ARE INHERITED FROM buck-bash-check.nu, which paid for all of them:
#   the scratch root must be SHALLOW, because the daemon socket lives at <prefix>/.ciderd.sock
#     and a Unix socket path is capped at 108 bytes;
#   kill leftovers BY /proc/N/exe, not by name, so it cannot match another check or this script;
#   cp -a and never cp -aL, because the prefix installs Volumes/DarlingEmulatedDrive -> / and
#     dereferencing walks the whole machine (82 GB once);
#   GNU rm, not nushell rm, because the daemon leaves a workdir at mode 000 and remove_dir_all
#     just returns EACCES;
#   out+err into ONE file rather than `complete`, so guest and daemon lines keep their order,
#     which is most of the evidence when this fails.

def say [msg: string] { print -e $"  ($msg)" }

def main [
    --binary: string                      # the Mach-O executable to run
    --art: string = ""                    # a prebuilt prefix artifact dir; built if empty
    --scratch: string = ""
    --marker: string = "CIDER_RUST_OK"    # what the binary is expected to print
    --lib: string = ""                    # a dylib to stage beside it, for the @rpath check
    --libdest: string = "lib"             # where in the GUEST root that dylib lands
    --setenv: string = ""                 # one NAME=VALUE handed to the guest process
    --expect-fail: string = ""            # invert: require the run to FAIL naming this
] {
    if ($binary | is-empty) or not ($binary | path exists) {
        say $"no such binary: ($binary)"
        exit 2
    }
    let ftype = (do -i { ^file -b $binary } | str trim)
    if not ($ftype | str contains "Mach-O 64-bit x86_64 executable") {
        say $"not a Darwin executable, this check would prove nothing: ($ftype)"
        exit 2
    }
    say $"binary: ($ftype)"
    if ($lib | is-not-empty) {
        if not ($lib | path exists) {
            say $"no such dylib: ($lib)"
            exit 2
        }
        let ltype = (do -i { ^file -b $lib } | str trim)
        if not ($ltype | str contains "Mach-O 64-bit x86_64 dynamically linked shared library") {
            say $"--lib is not a Darwin dylib, this check would prove nothing: ($ltype)"
            exit 2
        }
        say $"dylib: ($ltype)"
    }

    mut art = $art
    # `| default` DOES NOT FILL AN EMPTY STRING, only a null, and getting this wrong here is
    # catastrophic rather than merely wrong. The other runtime checks declare `scratch?: string`,
    # an optional POSITIONAL, which is null when absent, so `$scratch | default X` gives X. This
    # script first declared `--scratch: string = ""`, a FLAG with an empty default, so $scratch
    # was "" and `default` passed it straight through: root became "", the kill loop below
    # compared every process against `str starts-with "/"`, which is true for all of them, and
    # the loop would SIGKILL every process the user owns. Verified in nushell:
    #     "" | default "/tmp/x"                 => ""      (NOT the fallback)
    #     "/usr/bin/pipewire" | str starts-with "/"  => true
    let root = (if ($scratch | is-empty) {
        $"/tmp/cider-rustrun-(^id -u | str trim)"
    } else { $scratch })
    # AND THEN ASSERT IT ANYWAY. The guard above is the fix; this is the seatbelt, because the
    # cost of a wrong root here is the user's whole login session and the cost of the check is
    # nothing. Never remove it to make a caller more flexible.
    if ($root | is-empty) or (not ($root | str starts-with "/tmp/")) {
        say $"refusing to run: scratch root must be a non-empty path under /tmp, got [($root)]"
        exit 2
    }
    let rt = $"($root)/rt"
    let prefix_dir = $"($root)/prefix"

    if ($art | is-empty) {
        say "no --art given and building the prefix here is an hour; pass one"
        exit 2
    }
    if ($art | path type) != "dir" {
        say $"--art is not a directory: ($art)"
        exit 2
    }

    for p in (ls /proc | get name | where {|n| ($n | path basename) =~ '^[0-9]+$' }) {
        let exe = (do -i { ^readlink $"($p)/exe" | str trim } | default "")
        if ($exe | str starts-with $"($root)/") { do -i { ^kill -9 ($p | path basename) } }
    }

    say $"materializing into ($rt)"
    do -i { ^chmod -R u+w $rt }
    ^rm -rf $rt $prefix_dir $"($prefix_dir).workdir"
    mkdir $rt $prefix_dir
    ^cp -a $"($art)/." $"($rt)/"
    ^chmod -R u+w $rt

    # libexec/cider is the GUEST ROOT: its bin/bash is the guest /bin/bash.
    let guestbin = $"($rt)/libexec/cider/bin/cider-rust-probe"
    ^cp $binary $guestbin
    ^chmod +x $guestbin

    # THE DYLIB GOES IN BY GUEST-RELATIVE PATH, because that is the whole question an @rpath
    # probe asks: @loader_path/../lib resolves against the executable's directory IN THE GUEST
    # NAMESPACE, so libdest is named relative to the guest root and never to the host.
    if ($lib | is-not-empty) {
        let dest = $"($rt)/libexec/cider/($libdest)"
        mkdir $dest
        ^cp $lib $"($dest)/($lib | path basename)"
        say $"staged ($lib | path basename) at guest /($libdest)"
    }

    say "booting the container and running it"
    let log = (mktemp --tmpdir buck-darwin-rust-run.XXXXXX)
    # ONE EXTRA VARIABLE, BY NAME AND VALUE, and it is not a convenience: setting
    # DYLD_LIBRARY_PATH is what ISOLATED the @rpath gap in the first place, because it makes a
    # binary load whose LC_RPATH was silently dropped. A control that can turn the failure back
    # into a success proves the run is testing rpath expansion and not the dylib.
    let base = {
        DPREFIX: $prefix_dir
        CIDER_NO_LAUNCHD: "1"
        DSERVER_LIBEXEC_PATH: $"($rt)/libexec/cider"
        DSERVER_MLDR_PATH: $"($rt)/libexec/cider/usr/libexec/cider/mldr"
    }
    # NOT `let env`: env is a RESERVED WORD in nushell and the parse error says only
    # "`env` used as variable name", which does not name the line.
    let guest_env = (if ($setenv | is-empty) { $base } else {
        let ix = ($setenv | str index-of "=")
        if $ix < 1 {
            say $"--setenv wants NAME=VALUE, got [($setenv)]"
            exit 2
        }
        let name = ($setenv | str substring 0..<$ix)
        let from = ($ix + 1)
        say $"guest env: ($name)=($setenv | str substring $from..)"
        $base | insert $name ($setenv | str substring $from..)
    })
    with-env $guest_env {
        do -i { ^timeout 180 $"($rt)/bin/cider" shell /bin/cider-rust-probe out+err> $log }
    }
    let out = (open --raw $log | str trim --right --char "\n")
    rm -f $log
    print $out

    # INVERTED MODE, for a control run. A check that cannot fail is worth nothing, and the way
    # to show this one can is to remove what it depends on and require the SPECIFIC failure
    # back: the loader naming the dylib it could not resolve.
    if ($expect_fail | is-not-empty) {
        if ($out | str contains $marker) {
            say $"FAIL: the control RAN and printed ($marker), so the thing it removed did not"
            say "      matter and the check above proves nothing."
            exit 1
        }
        if ($out | str contains $expect_fail) {
            say $"PASS: the control failed exactly as required, naming [($expect_fail)]"
            exit 0
        }
        say $"FAIL: the control did not print the marker, but it did not name [($expect_fail)]"
        say "      either, so it failed for some OTHER reason and controls nothing."
        exit 1
    }

    if ($out | str contains $marker) {
        say $"PASS: a Rust binary built for Darwin RAN inside cider and printed ($marker)"
        exit 0
    }
    say $"FAIL: the marker ($marker) never appeared, so the binary did not run to that point."
    say "      The transcript above is ordered, so the last daemon line before it stops is the"
    say "      place to look. See #16 for the SIGILL-on-startup precedent."
    exit 1
}
