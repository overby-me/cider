#!/usr/bin/env nu

# DOES dyld STILL EXPAND @rpath INSIDE THE GUEST? (task #96, the regression check the fix lacked)
#
# THE BUG THIS GUARDS, and it cost most of a night. mldr put the HOST path in apple[0]
# executable_path=. dyld keeps that as sExecPath and calls realpath() on it in the GUEST
# namespace before expanding @loader_path, so realpath failed, getRPaths pushed nothing, and
# EVERY LC_RPATH was dropped IN SILENCE. Nothing logged it: DYLD_PRINT_RPATHS only prints inside
# the substitution loop, which never runs on an empty list. What it looked like from outside was
#
#     dyld: Library not loaded: @rpath/librustc_driver-....dylib
#
# with the dylib sitting exactly where the LC_RPATH said it would be. The fix, in
# darwin/loader/src/main.rs, strips the root prefix so the path resolves in the guest.
#
# It had NO test, which is the gap this closes: the same class as #77 (psynch) and #80 (kqchan),
# where a ported piece nothing exercises is a piece nobody will notice breaking.
#
#   scripts/buck-rpath-check.nu [--binary <probe>] [--lib <dylib>] [--art <prefix artifact>]
#
# With no arguments it builds the prefix the way the other runtime checks do and looks for the
# probes under $CIDER_RPATH_PROBE_DIR, or /tmp/cider-rpath-probes-<uid>. Without them it exits
# 3, a KNOWN partial state, and says so; it never passes without running anything.
#
# THREE RUNS, and the second and third are what make the first worth anything:
#
#   1  CLAIM     dylib at guest /lib, which is where @loader_path/../lib points from /bin.
#                It must print CIDER_RPATH_OK, which can only happen if the rpath expanded.
#   2  CONTROL   the same dylib staged at guest /rpath-control instead. The run must FAIL and
#                the failure must NAME @rpath/libciderrpath.dylib. A run that fails for any
#                other reason controls nothing, so the needle is required, not the exit code.
#   3  CONTROL   run 2 again with DYLD_LIBRARY_PATH=/rpath-control. It must SUCCEED. That is
#                the exact instrument that isolated the original gap: it makes a binary load
#                whose LC_RPATH was dropped, so a pass here proves runs 1 and 2 differ in rpath
#                EXPANSION and not in whether the dylib is loadable at all.
#
# THE PROBES ARE PREBUILT, on purpose. Building them needs the OFFICIAL rustc (a 442 MB
# out-of-tree asset, see scripts/buck-darwin-rust-build.nu for why the nixpkgs one cannot work)
# and the buck2-built ld64. The two sources are four lines each and the commands are recorded
# here so anyone can rebuild them:
#
#   lib.rs    #[no_mangle] pub extern "C" fn cider_rpath_value() -> i32 { 424242 }
#   main.rs   extern "C" { fn cider_rpath_value() -> i32; }
#             fn main() { println!("CIDER_RPATH_OK {}", unsafe { cider_rpath_value() }); }
#
#   rustc --target x86_64-apple-darwin --sysroot <sr> --crate-type cdylib \
#     -C linker-flavor=ld -C linker=<ld64> \
#     -C link-arg=-syslibroot -C link-arg=<prefix>/libexec/cider -C link-arg=-lSystem \
#     -C link-arg=-install_name -C link-arg=@rpath/libciderrpath.dylib \
#     -o lib/libciderrpath.dylib lib.rs
#
#   rustc --target x86_64-apple-darwin --sysroot <sr> \
#     -C linker-flavor=ld -C linker=<ld64> \
#     -C link-arg=-syslibroot -C link-arg=<prefix>/libexec/cider -C link-arg=-lSystem \
#     -C link-arg=-rpath -C link-arg=@loader_path/../lib \
#     -L native=lib -l dylib=ciderrpath -o bin/cider-rpath-probe main.rs
#
# THE INSTALL NAME IS THE POINT. libciderrpath.dylib is recorded in the executable as
# @rpath/libciderrpath.dylib and nothing else, so there is no absolute path and no fallback: if
# the rpath does not expand, the loader has no way to find it. Verified in the load commands
# rather than assumed, and this check verifies it again before it runs anything.
#
# IT DRIVES scripts/buck-darwin-rust-run.nu rather than materialising its own tree. That script
# owns the traps that cost real damage to learn (a shallow scratch root for the 108 byte socket
# limit, killing leftovers by /proc/N/exe, cp -a and never cp -aL, GNU rm for the mode 000
# workdir), and a second copy of them here would be a second place to get them wrong.

# Where the two probes live when nothing names them. NOT in the repo: they are Mach-O
# artifacts of an out-of-tree toolchain, and committing binaries whose provenance is a 442 MB
# download is exactly what #76 spent a night undoing. Absent, this check SKIPS VISIBLY with
# exit 3, which scripts/buck-runtime-check.nu treats as a known partial state rather than a
# pass: a check that quietly returns 0 with no probe is the blind pass this project keeps
# finding in other people's harnesses.
const PROBE_ENV = "CIDER_RPATH_PROBE_DIR"

const LIB_INSTALL_NAME = "@rpath/libciderrpath.dylib"
const RPATH = "@loader_path/../lib"
const MARKER = "CIDER_RPATH_OK 424242"
const CONTROL_DIR = "rpath-control"

def say [msg: string] { print -e $"  ($msg)" }

# The load commands have to say what this check assumes. An executable that names the dylib by
# an absolute path would pass run 1 with the rpath code entirely broken.
def check-load-commands [binary: string] {
    let p = (do -i { ^llvm-objdump -p $binary } | complete)
    if $p.exit_code != 0 {
        say "llvm-objdump is not on PATH, so the probe cannot be verified before use"
        return false
    }
    let text = $p.stdout
    if not ($text | str contains $LIB_INSTALL_NAME) {
        say $"the probe does not load ($LIB_INSTALL_NAME), so it would prove nothing"
        return false
    }
    if not ($text | str contains $RPATH) {
        say $"the probe carries no LC_RPATH ($RPATH), so there is nothing to expand"
        return false
    }
    say $"probe loads ($LIB_INSTALL_NAME) and carries LC_RPATH ($RPATH)"
    true
}

def run-phase [runner: string, args: list<string>] {
    let r = (do -i { ^nu $runner ...$args } | complete)
    print ($r.stdout | str trim --right --char "\n")
    print -e ($r.stderr | str trim --right --char "\n")
    $r.exit_code
}

def main [
    --binary: string = ""     # the Mach-O probe that loads the dylib only through @rpath
    --lib: string = ""        # libciderrpath.dylib, install name @rpath/libciderrpath.dylib
    --art: string = ""        # a prebuilt prefix artifact directory; built here if empty
    --scratch: string = ""
] {
    cd ($env.CURRENT_FILE | path dirname | path join "..")

    let probedir = ($env | get -o $PROBE_ENV | default $"/tmp/cider-rpath-probes-(^id -u | str trim)")
    let binary = (if ($binary | is-empty) { $"($probedir)/bin/cider-rpath-probe" } else { $binary })
    let lib = (if ($lib | is-empty) { $"($probedir)/lib/libciderrpath.dylib" } else { $lib })
    for pair in [[what, path]; ["the probe", $binary] ["the dylib", $lib]] {
        if not ($pair.path | path exists) {
            say $"SKIP: ($pair.what) is not at ($pair.path)"
            say $"      Build both with the two rustc commands in the header of this file, put"
            say $"      them there, or point ($PROBE_ENV) at the directory holding bin/ and lib/."
            say "      Exiting 3, a KNOWN partial state, so nothing reports this as verified."
            exit 3
        }
    }
    if not (check-load-commands $binary) { exit 2 }

    # THE PREFIX, the same way every other runtime check gets it. STDERR TO A FILE: on a cold
    # prefix buck2 emits gigabytes of progress, and `| complete` buffering that is the 17.3 GB
    # the suite was once killed at.
    mut art = $art
    if ($art | is-empty) {
        if (which buck2 | is-empty) {
            say "missing buck2 -- run inside `nix develop`, or pass --art"
            exit 2
        }
        say "== building the prefix =="
        let errf = (($env.TMPDIR? | default "/tmp") + "/cider-prefix-build.err")
        let b = (^buck2 build //buck/prefix:cider_prefix --show-output err> $errf | complete)
        $art = ($b.stdout | lines | last | default "" | split row " " | get 1? | default "")
        if ($art | path type) != "dir" {
            say $"the prefix did not build, see ($errf)"
            exit 1
        }
    }
    if ($art | path type) != "dir" {
        say $"--art is not a directory: ($art)"
        exit 2
    }

    let runner = ($env.CURRENT_FILE | path dirname | path join "buck-darwin-rust-run.nu")
    let common = [--binary $binary --art $art --marker $MARKER]
    let common = (if ($scratch | is-empty) { $common } else { $common ++ [--scratch $scratch] })

    say ""
    say "== 1 of 3: the claim, dylib at guest /lib where the rpath points =="
    let rc1 = (run-phase $runner ($common ++ [--lib $lib --libdest "lib"]))
    if $rc1 != 0 {
        say "FAIL: the probe did not run, so @rpath expansion is broken in the guest."
        say "      See darwin/loader/src/main.rs and the executable_path= note at the top."
        exit 1
    }

    say ""
    say $"== 2 of 3: control, the same dylib staged at guest /($CONTROL_DIR) instead =="
    let rc2 = (run-phase $runner
        ($common ++ [--lib $lib --libdest $CONTROL_DIR --expect-fail $LIB_INSTALL_NAME]))
    if $rc2 != 0 {
        say "FAIL: moving the dylib off the rpath did NOT reproduce the loader failure, so run"
        say "      1 was not testing what it claims. Do not trust the pass above."
        exit 1
    }

    say ""
    say $"== 3 of 3: control, run 2 again with DYLD_LIBRARY_PATH=/($CONTROL_DIR) =="
    let rc3 = (run-phase $runner
        ($common ++ [--lib $lib --libdest $CONTROL_DIR --setenv $"DYLD_LIBRARY_PATH=/($CONTROL_DIR)"]))
    if $rc3 != 0 {
        say "FAIL: with DYLD_LIBRARY_PATH set the probe STILL did not run, so runs 1 and 2 do"
        say "      not differ in rpath expansion and this check is measuring something else."
        exit 1
    }

    say ""
    say "PASS: @rpath expands in the guest, and both controls hold:"
    say "  the probe runs only when the dylib is on its rpath;"
    say "  moving it off reproduces the exact loader failure the fix was for;"
    say "  DYLD_LIBRARY_PATH turns that failure back into a pass, so the difference is the"
    say "  EXPANSION and not the dylib."
    exit 0
}
