#!/usr/bin/env nu
# Regression test for the Buck2 port (plan/buck2-port.md).
#
# Asserts that every ported target still builds and that its artifact has the
# properties we verified when it landed -- member counts, symbol presence, and
# that the archives are the ones the Rust daemon can consume. Runs against a
# direct buck2 daemon, so it is the check to run while iterating; the Nix
# endpoint (phase 3) is not wired yet.
#
# Usage: scripts/buck-test.nu [-v]
#
# Converted from bash (task #40). The tally lives in a file rather than in two
# counters: a nushell def cannot mutate its caller's variables, and env changes
# made inside one do not propagate back out either.
#
# The external tools stay external. Nearly every assertion here is a property of
# a pipeline over llvm-nm, llvm-objdump, ar, file, find or sed output, and
# rewriting those pipelines in nushell would be reimplementing the checks rather
# than converting the script.

# The [ -f ] family, run as the real test(1): a buck2 --show-output path is often a
# SYMLINK into buck-out, and nushell path type answers "symlink" where test -f
# follows the link and answers yes.
def test_f [p: string] { (do { ^test -f $p } | complete | get exit_code) == 0 }
def test_e [p: string] { (do { ^test -e $p } | complete | get exit_code) == 0 }
def test_s [p: string] { (do { ^test -s $p } | complete | get exit_code) == 0 }
def test_l [p: string] { (do { ^test -L $p } | complete | get exit_code) == 0 }
def test_d [p: string] { (do { ^test -d $p } | complete | get exit_code) == 0 }
def is_exec [p: string] { (do { ^test -x $p } | complete | get exit_code) == 0 }
def grep_q [f: string, pat: string] { (do { ^grep -q $pat $f } | complete | get exit_code) == 0 }

def say [msg: string] { print $msg }
def ok [msg: string] { print $"  ok   ($msg)"; "ok\n" | save -a $env.BT_TALLY }
def bad [msg: string] { print $"  FAIL ($msg)"; "bad\n" | save -a $env.BT_TALLY }

# stdout only, never failing: the bash version wrote 2>/dev/null and || true on
# essentially all of these, because an objdump over a missing path must not take
# the whole suite down mid-section.
def cap [argv: list<string>] {
    let r = (do { ^($argv | first) ...($argv | skip 1) } | complete)
    $r.stdout | str replace -r '\n+$' ''
}

# stdout and stderr, for the tools whose usage goes to stderr.
def cap2 [argv: list<string>] {
    let r = (do { ^($argv | first) ...($argv | skip 1) } | complete)
    ($r.stdout + $r.stderr) | str replace -r '\n+$' ''
}

def cap_rc [argv: list<string>] {
    let r = (do { ^($argv | first) ...($argv | skip 1) } | complete)
    {out: (($r.stdout + $r.stderr) | str replace -r '\n+$' ''), rc: $r.exit_code}
}

# wc -l over $(...) output: printf '%s\n' "" is still one line.
def wc_l [text: string] {
    if ($text | is-empty) { 1 } else { $text | split row "\n" | length }
}

def lines_of [text: string] {
    if ($text | is-empty) { [] } else { $text | split row "\n" }
}

# awk '{print $N}', which prints an empty field rather than skipping the line.
def field [text: string, n: int] {
    lines_of $text | each {|l| $l | str trim | split row --regex '\s+' | get -o ($n - 1) | default "" }
}

def has [syms: list<string>, sym: string] { $sym in $syms }

# buck2 build <target> --show-output | tail -1 | awk '{print $2}'
# awk '/pat/ {print $n}'
def awk_field [text: string, pat: string, n: int] {
    lines_of $text | where {|l| $l =~ $pat }
    | each {|l| $l | str trim | split row --regex '\s+' | get -o ($n - 1) | default "" }
    | str join "\n"
}

# ${x:-N} followed by a numeric test
def num_or [s: string, d: int] {
    if ($s | is-empty) { $d } else { (try { $s | into int } catch { $d }) }
}
def num_or_s [s: string, d: string] { if ($s | is-empty) { $d } else { $s } }

# <cmd> | wc -l, which is 0 for no output (unlike printf '%s\n' "$var" | wc -l)
def count_lines_cmd [argv: list<string>] {
    let out = (cap $argv)
    if ($out | is-empty) { 0 } else { $out | split row "\n" | length }
}

def count_files_or_links [d: string] { count_lines_cmd [find $d "(" -type f -o -type l ")"] }
def count_files [d: string] { count_lines_cmd [find $d -type f] }

# printf '%s' "$out" | tail -1 | sed 's/^ok: //'
def last_line_no_ok [text: string] {
    let ls = (lines_of $text)
    (if ($ls | is-empty) { "" } else { $ls | last }) | str replace -r '^ok: ' ''
}

def indent7 [text: string] { $text | split row "\n" | each {|l| $"       ($l)" } | str join "\n" }
def indent4 [text: string] { $text | split row "\n" | each {|l| $"    ($l)" } | str join "\n" }

def out_of [t: string] {
    let r = (do { ^buck2 build $t --show-output } | complete)
    let ls = (lines_of ($r.stdout | str replace -r '\n+$' ''))
    if ($ls | is-empty) { "" } else { ($ls | last | str trim | split row --regex '\s+' | get 1? | default "") }
}

def macho_id [f: string] {
    let out = (cap [llvm-objdump --macho --dylib-id $f])
    let ls = (lines_of $out)
    if ($ls | is-empty) { "" } else { $ls | last }
}

def macho_hdr [f: string] {
    let out = (cap [llvm-objdump --macho --private-headers $f])
    let hit = (lines_of $out | where {|l| $l | str contains "MH_MAGIC" })
    if ($hit | is-empty) { "" } else { $hit | first }
}

def load_dylibs [f: string] {
    # grep -A2 LC_LOAD_DYLIB | grep "name ", kept external for the -A2
    let r = (do {
        ^llvm-objdump --macho --private-headers $f | ^grep -A2 LC_LOAD_DYLIB | ^grep "name "
    } | complete)
    $r.stdout | str replace -r '\n+$' ''
}

def defined_syms [f: string] { field (cap [llvm-nm --defined-only $f]) 3 }
def extern_syms [f: string] { field (cap [llvm-nm --defined-only --extern-only $f]) 3 }

# <file> <table name> <sed expr extracting the target from a table row>
def check_wrap_table [f: string, name: string, sedexpr: string] {
    let tbl = (lines_of (cap [sed -n $sedexpr $f]) | sort)
    let reg = (lines_of (cap [sed -n 's/^# buck-registry: lib\(.*\)\.dylib = .*$/\1/p' $f]) | sort)
    if $tbl == $reg {
        ok $"($f) buck-registry pragmas match ($name) \((wc_l ($tbl | str join "\n")) entries\)"
    } else {
        bad $"($f) buck-registry pragmas have drifted from ($name)"
        # diff of two process substitutions, through files
        let a = (mktemp --tmpdir --suffix .bt-tbl)
        let b = (mktemp --tmpdir --suffix .bt-reg)
        (($tbl | str join "\n") + "\n") | save -f -r $a
        (($reg | str join "\n") + "\n") | save -f -r $b
        print (indent4 (cap [diff $a $b]))
        rm -f $a $b
    }
}

# Task #40 converted the port's scripting to nushell. Six shell scripts remain and
# every one of them is deliberate, so a SEVENTH is a regression: four of these need
# a bash the guest or the watchdog can exec, and two run inside the container where
# there is no nu at all. Listed by name rather than counted, so replacing one with a
# different bash script does not pass.
def check_shell_scripts [] {
    let allowed = [
        cc-under-darling.sh      # a fresh container per compile, exec'd by the build hook
        darling-host.sh          # the host side of the same
        run-darwin-under-darling.sh
        with-watchdog.sh         # wraps a command in a stall watchdog, exec'd from bash
        gnix-hello.sh            # runs INSIDE the guest
        gnix-build.sh            # runs INSIDE the guest
    ] | sort
    let found = (ls scripts/*.sh | get name | each {|n| $n | path basename } | sort)
    if $found == $allowed {
        ok $"scripts/ holds only the ($found | length) shell scripts that have to stay bash"
    } else {
        bad "scripts/*.sh has drifted from the six that have to stay bash"
        let extra = ($found | where {|f| not ($f in $allowed) })
        let gone = ($allowed | where {|f| not ($f in $found) })
        if ($extra | is-not-empty) { print $"    unexpected: ($extra | str join ', ')" }
        if ($gone | is-not-empty) { print $"    missing: ($gone | str join ', ')" }
    }
}

def main [flag?: string] {
    let verbose = ($flag == "-v")
    cd ($env.CURRENT_FILE | path dirname | path join "..")

    $env.BT_TALLY = (mktemp --tmpdir --suffix .buck-test-tally)
    "" | save -f $env.BT_TALLY

    for tool in [buck2 watchman] {
        if (which $tool | is-empty) {
            say $"missing ($tool) -- run inside `nix develop` (it provides buck2 + watchman)"
            exit 2
        }
    }

    # The pinned upstream trees the port compiles (migcom, the SDK header roots).
    if (not (test_d "buck-src/bootstrap_cmds")) or (not (test_d "buck-src/xnu")) {
        say "materializing pinned sources (scripts/buck-src.nu) ..."
        do { ^./scripts/buck-src.nu } | ignore
    }

    say "== building ported targets =="
    let targets = [
        //src/libsimple:libsimple_darlingserver
        //src/libsimple:libsimple_darling
        //buck-src:migcom
        //src/startup:rtsig_header
        //src/external/darlingserver:dserver_rpc
        //src/external/darlingserver/duct-tape:darlingserver_duct_tape
        //src/external/darlingserver/tools:dserverdbg
        //linux/server:duct_tape_lib
        //src/libsimple:libsimple_darling_dylib
        //tests/buck2/firstpass:a
        //tests/buck2/firstpass:b
        //tests/buck2/firstpass:umbrella
        //buck-src:system_blocks_firstpass
        //buck-src:keymgr_firstpass
        //buck-src:system_malloc_firstpass
        //buck-src:system_pthread_firstpass
        //buck-src/libc:system_c_firstpass
        //buck-src/xnu:system_kernel_firstpass
        //buck-src:system_blocks_final
        //buck-src/xnu:system_kernel_final
        //buck-src/libplatform:platform_firstpass
        //buck-src:compiler_rt_firstpass
        //buck-src:system_dyld_firstpass
        //buck-src:system_asl_firstpass
        //buck-src:system_coretls_firstpass
        //buck-src:asl_ipc_mig
        //src/duct:system_duct_firstpass
        //src/external/libtrace:system_trace_firstpass
        //src/libsystem_coreservices:system_coreservices_firstpass
    ]
    if $verbose {
        ^buck2 build ...$targets
    } else {
        let r = (do { ^buck2 build ...$targets } | complete)
        if $r.exit_code != 0 {
            say "buck2 build FAILED; re-run with -v"
            exit 1
        }
    }
    say "  ok   all targets build"
    "ok\n" | save -a $env.BT_TALLY

    say "== libsimple =="
    let lib = (out_of //src/libsimple:libsimple_darlingserver)
    if (test_f $lib) { ok "archive exists" } else { bad "archive missing" }
    let syms = (field (cap [nm --defined-only $lib]) 3 | where {|s| $s | str starts-with "libsimple_" } | length)
    if $syms >= 13 { ok $"exports ($syms) libsimple_* symbols" } else { bad $"expected >= 13 libsimple_* symbols, got ($syms)" }

    say "== libsimple, GUEST build (Darwin/Mach-O cross toolchain) =="
    let dlib = (out_of //src/libsimple:libsimple_darling)
    if (test_f $dlib) { ok "archive exists" } else { bad "archive missing" }
    let obj_kind = (do {
        cd ($dlib | path dirname)
        ^ar p ($dlib | path basename) lock.c.o | ^file -
    } | complete | get stdout | str replace -r '\n+$' '' | split row ":" | get 1? | default "")
    if ($obj_kind | str contains "Mach-O 64-bit x86_64") {
        ok $"member is($obj_kind)"
    } else {
        bad $"expected a Mach-O 64-bit x86_64 object, got:(if ($obj_kind | is-empty) { 'nothing' } else { $obj_kind })"
    }
    # Darwin mangles C symbols with a leading underscore; seeing it proves the
    # cross toolchain really targeted Darwin rather than the host.
    if (has (defined_syms $dlib) "_libsimple_lock_lock") {
        ok "exports _libsimple_lock_lock (Darwin mangling)"
    } else {
        bad "missing the Darwin-mangled _libsimple_lock_lock"
    }

    say "== migcom (the MIG toolchain) =="
    let migcom = (out_of //buck-src:migcom)
    if (is_exec $migcom) { ok "migcom is executable" } else { bad "migcom missing" }
    let ver = (lines_of (cap2 [$migcom -version]) | get 0? | default "")
    if $ver == "1.0" { ok $"migcom -version = ($ver)" } else { bad $"migcom -version = '($ver)', expected 1.0" }

    say "== codegen =="
    let rtsig = (out_of //src/startup:rtsig_header)
    if (grep_q $rtsig "LINUX_SIGRTMIN") { ok "rtsig.h defines LINUX_SIGRTMIN" } else { bad "rtsig.h missing LINUX_SIGRTMIN" }
    # dserver_rpc has three default outputs, and --show-output prints no path for
    # multi-output targets, so look for the generated files themselves.
    let rpc_h = (lines_of (cap [find buck-out -path "*__dserver_rpc__*" -name "rpc.h"]) | get 0? | default "")
    let rpc_c = (lines_of (cap [find buck-out -path "*__dserver_rpc__*" -name "rpc.c"]) | get 0? | default "")
    if ($rpc_h | is-not-empty) and ($rpc_c | is-not-empty) {
        ok "RPC wrappers generated (rpc.h + rpc.c)"
    } else {
        bad "RPC wrappers missing"
    }
    if ($rpc_h | is-not-empty) {
        if (grep_q $rpc_h "dserver_rpc") { ok "rpc.h declares the RPC surface" } else { bad "rpc.h has no dserver_rpc declarations" }
    }

    say "== duct-tape =="
    let dt = (out_of //src/external/darlingserver/duct-tape:darlingserver_duct_tape)
    if (test_f $dt) { ok "archive exists" } else { bad "archive missing" }
    let members = (count_lines_cmd [ar t $dt])
    # WAS 93 (66 hand-written + 26 MIG-generated + pthread/kern_synch.c) BEFORE #71. That port
    # moved 16 glue .c to Rust under linux/server/src/xnu, so the C archive is smaller now and
    # the 16 files were later deleted. This number is the post-#71 archive.
    if $members == 81 { ok "81 members" } else { bad $"expected 81 members, got ($members)" }
    # Collect the symbol list ONCE. Note: `nm ... | grep -q` under `set -o pipefail`
    # fails even on a match, because grep -q exits early and nm dies on SIGPIPE.
    let dt_syms = (field (cap [nm --defined-only $dt]) 3 | where {|s| $s != "" } | uniq | sort)
    let sym_count = (wc_l ($dt_syms | str join "\n"))
    # Floor lowered from 2700 with #71 for the same reason as the member count.
    if $sym_count >= 2100 { ok $"defines ($sym_count) symbols" } else { bad $"expected >= 2100 symbols, got ($sym_count)" }
    # dtape_init and dtape_init_in_thread are NOT here any more: #71 made them Rust, they live
    # at linux/server/src/xnu/init.rs. Asserting them against the C archive asserted something
    # false. What covers them now is the darlingserverd LINK plus the demos, both in
    # scripts/duct-tape-runtime-check.nu, which is a 40 second gate.
    for sym in [ipc_kmsg_send mig_init thread_call_initialize] {
        if (has $dt_syms $sym) { ok $"defines ($sym)" } else { bad $"missing ($sym)" }
    }
    # The MIG-generated server stubs must be in there, not just the hand-written code.
    if (has $dt_syms "mach_port_server") {
        ok "contains MIG-generated mach_port_server"
    } else {
        bad "missing MIG-generated mach_port_server"
    }

    say "== dserverdbg (generated RPC source + a forced -include) =="
    let dbg = (out_of //src/external/darlingserver/tools:dserverdbg)
    if (is_exec $dbg) { ok "dserverdbg is executable" } else { bad "dserverdbg missing" }
    # It refuses to run without setuid, which is exactly the message we expect: the
    # binary links and its RPC surface initialized enough to reach that check.
    let msg = (lines_of (cap2 [$dbg]) | get 0? | default "")
    if ($msg | str contains "not setuid root") {
        ok "dserverdbg runs (reports the expected setuid requirement)"
    } else {
        bad $"dserverdbg said: ($msg)"
    }

    say "== Mach-O dylib: install_name (phase 1.2) =="
    let dyl = (out_of //src/libsimple:libsimple_darling_dylib)
    let kind = (cap [file -b $dyl])
    if ($kind | str contains "Mach-O 64-bit x86_64 dynamically linked shared library") {
        ok "is a Mach-O dylib"
    } else {
        bad $"expected a Mach-O dylib, got: ($kind)"
    }
    let id = (macho_id $dyl)
    if $id == "/usr/lib/system/libsimple_darling.dylib" { ok $"install_name is ($id)" } else { bad $"install_name is '($id)'" }

    say "== the firstpass cycle + umbrella reexport (phase 1.3) =="
    let a = (out_of //tests/buck2/firstpass:a)
    let umb = (out_of //tests/buck2/firstpass:umbrella)
    let loads = (load_dylibs $a)
    # The point of the firstpass mechanism: liba linked against libb_FIRSTPASS.dylib,
    # but records the sibling INSTALL_NAME, so at runtime it loads the real libb.
    if ($loads | str contains "/usr/lib/system/libb.dylib") {
        ok "liba records the sibling install_name, not the firstpass path"
    } else {
        bad $"liba's LC_LOAD_DYLIB entries: ($loads)"
    }
    # No awk here, unlike the defined-symbol checks: llvm-nm prints an undefined
    # symbol as the bare name, and the bash version grepped the raw lines.
    if (has (lines_of (cap [llvm-nm --undefined-only $a])) "_b_value") {
        ok "liba imports _b_value from its sibling"
    } else {
        bad "liba does not import _b_value"
    }
    let reexports = (do {
        ^llvm-objdump --macho --private-headers $umb | ^grep -A2 LC_REEXPORT_DYLIB | ^grep -c "name "
    } | complete | get stdout | str trim | into int)
    if $reexports == 2 { ok "umbrella reexports both members" } else { bad $"expected 2 LC_REEXPORT_DYLIB entries, got ($reexports)" }
    if ((cap [file -b $umb]) | str contains "NOUNDEFS") {
        ok "umbrella has no undefined symbols"
    } else {
        bad "umbrella still has undefined symbols"
    }

    say "== libsystem_blocks: the first real libSystem sublibrary =="
    let blocks = (out_of //buck-src:system_blocks_firstpass)
    let bid = (macho_id $blocks)
    if $bid == "/usr/lib/system/libsystem_blocks.dylib" { ok $"install_name is ($bid)" } else { bad $"install_name is '($bid)'" }
    let blocks_syms = (extern_syms $blocks)
    for sym in [__Block_copy __Block_release __Block_object_assign __Block_object_dispose] {
        if (has $blocks_syms $sym) { ok $"exports ($sym)" } else { bad $"missing ($sym)" }
    }
    # A firstpass resolves nothing, so its siblings' symbols must still be undefined.
    if (has (lines_of (cap [llvm-nm --undefined-only $blocks])) "_free") {
        ok "leaves sibling symbols undefined (as a firstpass must)"
    } else {
        bad "expected _free to be undefined in a firstpass dylib"
    }

    say "== libSystem members, as firstpass dylibs =="
    # target:install_name, from the reference build's -dylib_file map. Every one is
    # checked for being a Mach-O dylib carrying the right install_name.
    let pairs = [
        "//buck-src:system_blocks_firstpass:/usr/lib/system/libsystem_blocks.dylib"
        "//buck-src:keymgr_firstpass:/usr/lib/system/libkeymgr.dylib"
        "//buck-src:system_malloc_firstpass:/usr/lib/system/libsystem_malloc.dylib"
        "//buck-src:system_pthread_firstpass:/usr/lib/system/libsystem_pthread.dylib"
        "//buck-src:system_asl_firstpass:/usr/lib/system/libsystem_asl.dylib"
        "//buck-src/libc:system_c_firstpass:/usr/lib/system/libsystem_c.dylib"
        "//buck-src/xnu:system_kernel_firstpass:/usr/lib/system/libsystem_kernel.dylib"
        "//buck-src:system_coretls_firstpass:/usr/lib/system/libsystem_coretls.dylib"
        "//src/duct:system_duct_firstpass:/usr/lib/system/libsystem_duct.dylib"
        "//src/external/libtrace:system_trace_firstpass:/usr/lib/system/libsystem_trace.dylib"
        "//src/libsystem_coreservices:system_coreservices_firstpass:/usr/lib/system/libsystem_coreservices.dylib"
    ]
    for pair in $pairs {
        let f = ($pair | split row ":")
        let t = ($f | drop 1 | str join ":")
        let want = ($f | last)
        let art = (out_of $t)
        if not ((cap [file -b $art]) | str contains "Mach-O 64-bit x86_64 dynamically linked shared library") {
            bad $"($t) is not a Mach-O dylib"
            continue
        }
        let got = (macho_id $art)
        if $got == $want {
            ok $"($t | split row ':' | last) -> ($got)"
        } else {
            bad $"($t) install_name is '($got)', want '($want)'"
        }
    }

    # libsystem_pthread is split across SEVEN flag groups and has hand-written
    # assembly. _pthread_create comes from one group and __pthread_list_lock from
    # another, so this also guards against a dylib that names only some groups (which
    # links, but leaves symbols undefined).
    let pth = (out_of //buck-src:system_pthread_firstpass)
    let pth_syms = (defined_syms $pth)
    for sym in [_pthread_create __pthread_list_lock] {
        if (has $pth_syms $sym) { ok $"libsystem_pthread defines ($sym)" } else { bad $"libsystem_pthread is missing ($sym)" }
    }

    # libsystem_c is the big one: 641 objects from 43 cmake object libraries, each of
    # which can be several flag groups. Spot-check that the C library is really in
    # there rather than an empty shell that happened to link.
    let libc_dylib = (out_of //buck-src/libc:system_c_firstpass)
    let libc_syms = (extern_syms $libc_dylib)
    let libc_count = (wc_l ($libc_syms | str join "\n"))
    if $libc_count >= 1300 { ok $"libsystem_c exports ($libc_count) symbols" } else { bad $"libsystem_c exports only ($libc_count) symbols" }
    for sym in [_printf _fopen _strtod _qsort _getenv _regcomp _uuid_generate _strftime] {
        if (has $libc_syms $sym) { ok $"libsystem_c exports ($sym)" } else { bad $"libsystem_c is missing ($sym)" }
    }

    # asl's sources include <asl_ipc.h>, which MIG generates -- the same include that
    # stalls nix-ninja's full-graph build.
    let aslmig = (out_of //buck-src:asl_ipc_mig)
    if (test_f $"($aslmig)/asl_ipc.h") { ok "guest MIG generated asl_ipc.h" } else { bad "asl_ipc.h was not generated" }

    say "== libsystem_kernel: the syscall boundary =="
    let krn = (out_of //buck-src/xnu:system_kernel_firstpass)
    let krn_syms = (extern_syms $krn)
    let kn = (wc_l ($krn_syms | str join "\n"))
    if $kn >= 1300 { ok $"libsystem_kernel exports ($kn) symbols" } else { bad $"libsystem_kernel exports only ($kn) symbols" }
    for sym in [_mach_msg _mach_task_self_ ___syscall _mmap _kevent] {
        if (has $krn_syms $sym) { ok $"libsystem_kernel exports ($sym)" } else { bad $"libsystem_kernel is missing ($sym)" }
    }
    # The mach_zone family, which is really a check on the MIG FLAGS. mig runs the C
    # preprocessor over the .defs, so the -D flags the reference passes decide which routines
    # exist: without -DPRIVATE=1 on the ksmig_* targets, every `#ifdef PRIVATE` routine is
    # silently absent and nothing fails until some program tries to link one. zlog was the
    # program that did. The first two here are unguarded and were always exported; the last
    # four are the guarded ones, and they are what proves the flags are still being passed.
    for sym in [_mach_zone_info _mach_zone_info_for_zone _mach_zone_force_gc _mach_zone_info_for_largest_zone _mach_zone_get_zlog_zones _mach_zone_get_btlog_records] {
        if (has $krn_syms $sym) {
            ok $"libsystem_kernel exports ($sym)"
        } else {
            bad $"libsystem_kernel is missing ($sym) \(is -DPRIVATE=1 still on the ksmig targets?\)"
        }
    }

    say "== THE FINAL PASS (phase 2's objective) =="
    # libsystem_blocks linked against its four siblings' FIRSTPASS dylibs, the way
    # cmake's add_circular does. What proves the mechanism is not that it links, but
    # WHAT it recorded: the siblings' install_names, and nothing left undefined.
    let fin = (out_of //buck-src:system_blocks_final)
    let fid = (macho_id $fin)
    if $fid == "/usr/lib/system/libsystem_blocks.dylib" { ok $"final pass install_name is ($fid)" } else { bad $"final pass install_name is '($fid)'" }
    let floads = (load_dylibs $fin)
    for want in [libsystem_kernel libsystem_malloc libsystem_pthread libsystem_c] {
        if ($floads | str contains $"/usr/lib/system/($want).dylib") {
            ok $"final pass records ($want) by install_name"
        } else {
            bad $"final pass does not load ($want)"
        }
    }
    # What it exports is the point of the pass: the firstpass/final split exists so
    # the mutually dependent libraries can define their own symbols.
    if (has (extern_syms $fin) "__Block_copy") {
        ok "final pass defines _Block_copy"
    } else {
        bad "final pass does not define _Block_copy"
    }
    # libclosure's final pass is linked -flat_namespace -undefined,suppress in the
    # reference, so its imports are deliberately left unbound and the image is NOT
    # two-level. Asserting "no undefined symbols" here would assert the opposite of
    # what the reference does.
    if ((cap [llvm-objdump --macho --private-headers $fin]) | str contains "TWOLEVEL") {
        bad "final pass is two-level, but the reference links it flat"
    } else {
        ok "final pass is flat-namespace, as the reference links it"
    }
    # The kernel's final pass IS two-level, and there nothing may be left unbound.
    let kfin = (out_of //buck-src/xnu:system_kernel_final)
    if ((cap [llvm-objdump --macho --private-headers $kfin]) | str contains "TWOLEVEL") {
        ok "the kernel's final pass is two-level"
    } else {
        bad "the kernel's final pass is not two-level"
    }
    let unbound = (lines_of (cap [llvm-nm -m $kfin]) | where {|l| $l =~ '\(undefined\) external [^(]*$' } | length)
    if $unbound == 0 { ok "the kernel's final pass leaves nothing unbound" } else { bad $"the kernel's final pass leaves ($unbound) symbols unbound" }

    say "== the kernel's FINAL pass (the syscall boundary) =="
    let kf = (out_of //buck-src/xnu:system_kernel_final)
    let kfid = (macho_id $kf)
    if $kfid == "/usr/lib/system/libsystem_kernel.dylib" { ok $"install_name is ($kfid)" } else { bad $"install_name is '($kfid)'" }
    let kloads = (load_dylibs $kf)
    for want in [libsystem_c libcompiler_rt libdyld] {
        if ($kloads | str contains $"/usr/lib/system/($want).dylib") {
            ok $"kernel final records ($want) by install_name"
        } else {
            bad $"kernel final does not load ($want)"
        }
    }
    # The dserver_rpc_* symbols come from the GENERATED rpc.c, which needs its own
    # flag group (dserver-rpc-defs.h force-included). Missing it links a firstpass
    # fine but breaks the final pass, so assert one of them is really defined.
    if (has (defined_syms $kf) "_dserver_rpc_checkin") {
        ok "kernel final defines _dserver_rpc_checkin (generated rpc.c is linked in)"
    } else {
        bad "kernel final is missing _dserver_rpc_checkin"
    }

    say "== every ported dylib links =="
    # Discovered rather than listed: the members come from the reference graph, and a
    # hand-kept list here would quietly stop covering new ones. Every target must
    # produce a Mach-O dylib whose install_name is the one its consumers look it up by.
    # Nothing is expected to fail any more: the layer outside the circular cluster
    # (libc++, libc++abi, libsystem_dnssd, libsystem_configuration, libquarantine,
    # libremovefile, libcopyfile, libsystem_networkextension) is ported too.
    let dylib_pkgs = "//buck-src/... + //src/duct: + //src/libm: + //src/libcache: + //src/sandbox: + //src/launchd: + //src/external/libtrace: + //src/libsystem_coreservices: + //src/lib: + //src/quarantine: + //src/networkextension:"
    # By RULE KIND, not by name: check_dylib is an EXECUTABLE whose name ends in _dylib,
    # and a name match swept it in here.
    let all_dylibs = (cap [buck2 uquery $"kind\('darwin_dylib', ($dylib_pkgs)\)"] | split row --regex '\s+' | where {|t| $t != "" })
    mut n_first = 0
    mut n_linked = 0
    for t in $all_dylibs {
        let name = ($t | split row ":" | last)
        let f = (out_of $t)
        # Both substitutions have to tolerate failure: with `set -euo pipefail`, an
        # objdump on an empty path takes the whole suite down mid-section, which looks
        # like the run stopping for no reason.
        let id = (macho_id $f)
        if ($id | str starts-with "/usr/lib/") or ($id | str starts-with "/System/Library/") {
            # A framework binary's id lives under /System/Library, not /usr/lib.
            $n_linked = $n_linked + 1
            if ($name | str ends-with "_firstpass") { $n_first = $n_first + 1 }
        } else if ($id | str starts-with "/") {
            # No install_name. An install_name is always an ABSOLUTE path, so anything that
            # is not one means the Mach-O carries no LC_ID_DYLIB -- llvm-objdump then echoes
            # the file's own header line ("<path>:") or nothing at all. That is not a defect
            # here: xtrace's per-protocol stubs and every LOADABLE MODULE (zsh's 35, sasl's 8)
            # are dlopened by path, and the reference links them with no -dylib_install_name.
            # For those the assertion is the Mach-O type instead.
            bad $"($name) has an unexpected install_name \(got '($id)'\)"
        } else {
            let ft = (macho_hdr $f)
            # BUNDLE as well as DYLIB, because that is what the reference builds these as:
            # zsh's and sasl's module links carry -Wl,-bundle -Wl,-flat_namespace
            # -Wl,-undefined,suppress, which is a MH_BUNDLE by definition. A module is
            # dlopened, never linked against, so it needs no LC_ID_DYLIB and gets none.
            if ($ft | str contains "DYLIB") or ($ft | str contains "BUNDLE") {
                $n_linked = $n_linked + 1
            } else {
                bad $"($name) is neither a Mach-O dylib nor a bundle \(($ft)\)"
            }
        }
    }
    if $n_first >= 30 { ok $"($n_first) firstpass dylibs link" } else { bad $"expected >= 30 firstpass dylibs, got ($n_first)" }
    if $n_linked >= 129 { ok $"($n_linked) dylibs link in total" } else { bad $"expected >= 129 dylibs, got ($n_linked)" }

    say "== libSystem's umbrella records its members =="
    # The umbrella reexports each member, so its LC_REEXPORT_DYLIB entries are the
    # check that the cluster is wired together rather than merely built.
    let su = (out_of //buck-src:system_final)
    let reex = (lines_of (cap [llvm-objdump --macho --private-headers $su]) | where {|l| $l | str contains "LC_REEXPORT_DYLIB" } | length)
    if $reex >= 33 { ok $"libSystem reexports ($reex) dylibs" } else { bad $"libSystem reexports only ($reex) dylibs" }
    # The Objective-C runtime is the deepest consumer of that umbrella: it links only
    # against libSystem.B.dylib plus libc++/libc++abi, so its message dispatch entry
    # point being defined means the reexport chain actually resolves.
    let oc = (out_of //buck-src/objc4:objc_final)
    if (has (extern_syms $oc) "_objc_msgSend") {
        ok "libobjc defines _objc_msgSend"
    } else {
        bad "libobjc does not define _objc_msgSend"
    }

    say "== guest EXECUTABLES =="
    # The dylib layer is not the whole guest: an executable also needs csu's start.S.o
    # named directly on the link line and -nostdlib, or clang's driver reaches for an
    # -lSystem that no -L holds. NOUNDEFS is the real assertion -- it says the loader
    # will not have to resolve anything that is missing.
    #
    # Discovered from the graph, like the dylibs: every executable target that exists.
    let exe_pkgs = "//buck-src/... + //src/shellspawn: + //src/vchroot: + //src/launchd:"
    # dyld is a DYLINKER, not an EXECUTE image, and has its own checks below.
    let exe_skip = ["dyld"]
    let all_exes = (cap [buck2 uquery $"kind\('darwin_binary', ($exe_pkgs)\)"] | split row --regex '\s+' | where {|t| $t != "" })
    mut n_exe = 0
    for t in $all_exes {
        let name = ($t | split row ":" | last)
        if $name in $exe_skip { continue }
        let hdr = (macho_hdr (out_of $t))
        if ($hdr | str contains "EXECUTE") and ($hdr | str contains "NOUNDEFS") {
            $n_exe = $n_exe + 1
        } else if ($hdr | str contains "EXECUTE") {
            bad $"($name) links but leaves symbols undefined"
        } else {
            bad $"($name) is not a Mach-O executable \(($hdr)\)"
        }
    }
    if $n_exe >= 50 { ok $"($n_exe) guest executables link with nothing undefined" } else { bad $"expected >= 50 executables, got ($n_exe)" }
    # launchd is PID 1 in the container and notifyd is the notification daemon: both are
    # MIG servers, and which generated stub each protocol contributes is not guessable --
    # launchd compiles jobServer.c but job_forwardUser.c, from two protocols that both
    # declare job_t.
    for t in [//src/launchd:launchd //buck-src:notifyd] {
        let hdr = (macho_hdr (out_of $t))
        if ($hdr | str contains "EXECUTE") and ($hdr | str contains "NOUNDEFS") {
            ok $"($t | split row ':' | last) links with nothing undefined"
        } else {
            bad $"($t | split row ':' | last): ($hdr)"
        }
    }

    say "== FRAMEWORK binaries =="
    # A framework binary is a Mach-O dylib with no extension at all, so both the edge
    # matcher and the sibling resolver have to identify it by its install_name rather than
    # by a file suffix. CoreFoundation is the one that matters: it is what every
    # higher-level framework builds on, and its constant strings only work because the
    # reference aliases _OBJC_CLASS_$___NSCFConstantString to
    # ___CFConstantStringClassReference on the link line.
    let specs = [
        "//buck-src/corefoundation:CoreFoundation_dylib=/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"
        "//darwin/frameworks:DirectoryService_dylib=/System/Library/Frameworks/DirectoryService.framework/Versions/A/DirectoryService"
        "//buck-src:icucore_dylib=/usr/lib/libicucore.A.dylib"
    ]
    for spec in $specs {
        let t = ($spec | split row "=" | first)
        let want = ($spec | split row "=" | skip 1 | str join "=")
        let id = (macho_id (out_of $t))
        if $id == $want {
            ok $"($t | split row ':' | last) id is ($id)"
        } else {
            bad $"($t | split row ':' | last) id is '($id)', want ($want)"
        }
    }
    let cf_syms = (defined_syms (out_of //buck-src/corefoundation:CoreFoundation_dylib) | uniq | sort)
    if (has $cf_syms "___CFConstantStringClassReference") {
        ok "CoreFoundation defines ___CFConstantStringClassReference (the -Wl,-alias took)"
    } else {
        bad "CoreFoundation is missing ___CFConstantStringClassReference"
    }
    # cctools' tools are the ones that prove the static archive path: they link
    # liblibstuff.a, and strings without libstuff would silently be a stub.
    let st_syms = (defined_syms (out_of //buck-src:strip) | uniq | sort)
    if (has $st_syms "_main") { ok "strip defines _main" } else { bad "strip has no _main" }

    say "== the STATIC tier, and dyld =="
    # dyld is not linked against dylibs at all: it links 17 static archives, because the
    # loader has to run before any dylib is mapped. Each archive is checked for holding
    # objects (an empty one links fine and silently drops symbols).
    mut n_ar = 0
    let static_targets = [
        //buck-src:compiler_rt_static64 //buck-src:corecrypto_static
        //buck-src:cxx_static //buck-src:cxxabi_static //buck-src:keymgr_static
        //buck-src:libc_static //buck-src:libc_static64 //buck-src:macho_static
        //buck-src:platform_static64 //buck-src:pthread_static
        //buck-src:system_blocks_static //src/duct:system_duct_static
        //buck-src:system_kernel_static64 //src/libm:system_m_static
        //src/external/libtrace:system_trace_static //buck-src:unwind_static
    ]
    for t in $static_targets {
        let f = (out_of $t)
        let n = (count_lines_cmd [ar t $f])
        if $n > 0 {
            $n_ar = $n_ar + 1
        } else {
            bad $"($t | split row ':' | last) is empty or missing"
        }
    }
    if $n_ar == 16 { ok $"($n_ar) static archives hold objects" } else { bad $"only ($n_ar) of 16 static archives hold objects" }
    # The kernel archive needs the generated rpc.c in a flag group of its own, exactly as
    # the dylib tier does; without it dyld comes out undefined against dserver_rpc_*.
    let ka = (out_of //buck-src:system_kernel_static64)
    let ka_syms = (defined_syms $ka | uniq | sort)
    if (has $ka_syms "_dserver_rpc_tid_for_thread") {
        ok "the static kernel defines _dserver_rpc_tid_for_thread"
    } else {
        bad "the static kernel is missing the generated rpc.c"
    }

    let dy = (out_of //buck-src/dyld:dyld)
    let dhdr = (macho_hdr $dy)
    if ($dhdr | str contains "DYLINKER") and ($dhdr | str contains "NOUNDEFS") {
        ok "dyld is a Mach-O DYLINKER with nothing undefined"
    } else if ($dhdr | str contains "DYLINKER") {
        bad "dyld links but leaves symbols undefined"
    } else {
        bad $"dyld is not a Mach-O dylinker \(($dhdr)\)"
    }
    let dy_syms = (defined_syms $dy | uniq | sort)
    if (has $dy_syms "__dyld_start") { ok "dyld defines __dyld_start" } else { bad "dyld has no __dyld_start" }

    say "== coverage against the reference graph =="
    # Measured, not estimated: scripts/buck-coverage.py counts every LINK EDGE in the
    # reference build.ninja and reports which have a buck2 target. Asserting a floor here
    # means a regression that drops targets cannot pass unnoticed.
    let cov = (awk_field (cap [./scripts/buck-coverage.py]) '^total' 2)
    let tot = (awk_field (cap [./scripts/buck-coverage.py]) '^total' 4)
    # The floor tracks the real number. It sat at 208 long after coverage passed 800, which
    # made it decorative: anything short of losing three quarters of the port passed it.
    #
    # result-graph-ref now points at the ALL graph, the largest the reference defines, so these
    # are all-component numbers: 1452 of 1452, where stock read 1434 and the cli graph 868 of
    # 871. The floor is the WHOLE graph: every in-scope link edge is ported, so any drop at all
    # is a regression, not a gap. `buck2 build //...` over all ~12k targets is green too, with
    # libstdc++ the last one to fall.
    #
    # The reference moved stock -> all once `all` reached 100 percent and the prefix followed
    # it, which is what let scripts/buck-jsc-check.nu stop hand-staging JavaScriptCore.
    #
    # The denominator jumped from 1359 when the metric started keying edges by reference PATH
    # rather than by artifact basename. A name does not identify a library -- perl builds two
    # module sets, cctools sits beside its xcselect shims, and the nine dev-stub frameworks
    # build an AppKit called exactly AppKit -- and collapsing a pair onto one entry answered
    # "ported" as soon as either half was.
    if (num_or $cov 0) >= 1452 {
        ok $"($cov) of the reference's (num_or_s $tot '1452') in-scope link edges are ported"
    } else {
        bad $"coverage dropped to (num_or_s $cov '0') of (num_or_s $tot '1452'), floor is 1452"
    }

    # ZERO edges matched on the artifact name alone. Every reference link edge now resolves to
    # a specific target by its PATH, so a pair that shares a name can no longer read ported
    # because its other half is. Getting here was not bookkeeping: it turned up 14 xcselect
    # shims, python's datetime.so and xcselect's xcrun that were never ported at all, and 54
    # perl 5.18 install destinations wired to the 5.28 BINARY.
    # GENERATED files, which the link-edge metric never sees. The worry was that a generated
    # file nothing compiles could be silently absent. Measured, it cannot: of 4035 generated
    # outputs, 3375 are cmake's own bookkeeping targets rather than files, 254 are headers
    # (a missing one fails the compile that includes it, and `buck2 build //...` is green),
    # 177 are consumed by a build edge and 2 are installed. The 227 that remain are MIG SIDE
    # OUTPUTS -- one mig run emits user, server, header and xtrace, and a target compiles one
    # or two -- which the REFERENCE does not read either. Asserted so the number cannot grow.
    let unc = (awk_field (cap [./scripts/buck-codegen-coverage.py]) '^  unconsumed' 2)
    if (num_or $unc 999) <= 227 {
        ok $"codegen: ($unc) generated outputs unconsumed \(ceiling 227, all mig side outputs\)"
    } else {
        bad $"codegen unconsumed rose to (num_or_s $unc 'unknown'), ceiling is 227"
    }

    let soft = (awk_field (cap [./scripts/buck-coverage.py]) '^by-name' 2)
    if (num_or $soft 0) <= 0 {
        ok $"coverage matches (num_or_s $soft '0') edges by name alone \(ceiling 0\)"
    } else {
        bad $"by-name coverage matches rose to (num_or_s $soft 'unknown'), ceiling is 0"
    }

    # The same question for the INSTALL side: link coverage says what builds, this says what
    # the port can actually lay out. UNMAPPED is every install entry that neither a target nor
    # a source file can supply, and it is a number that only ever goes down -- a ceiling here
    # catches a target quietly dropping out of the prefix, which no other check would notice
    # until something failed at runtime inside the container.
    #
    # Cheap enough to belong in the suite only since the registries stopped being rebuilt per
    # entry; it used to take eight minutes and now takes under two seconds.
    #
    # ZERO. Every install entry the reference has resolves to something the port builds. The
    # last three were not build outputs at all: python-config and the easyinstall shim are
    # written by cmake at CONFIGURE time (configure_file), so no ninja edge ever produced them,
    # and python.o is $<TARGET_OBJECTS:python27exe_obj>, a single object out of a group rather
    # than a library or an executable. All three read as "build output with no target" because
    # the resolver only knew how to look for build outputs.
    let unmapped = (lines_of (cap [python3 scripts/gen-install-from-manifests.py])
        | each {|l| $l | parse --regex '^ *UNMAPPED: *(?P<v>.*)$' | get v? | get 0? }
        | where {|v| $v != null } | get 0? | default "")
    if (num_or $unmapped 999) <= 0 {
        ok $"install UNMAPPED is ($unmapped) \(ceiling 0\)"
    } else {
        bad $"install UNMAPPED rose to (num_or_s $unmapped 'unknown'), ceiling is 0"
    }

    say "== DUCT_TAPE_LIB staging =="
    let dir = (out_of //linux/server:duct_tape_lib)
    for a in [libdarlingserver_duct_tape.a liblibsimple_darlingserver.a] {
        if (test_f $"($dir)/($a)") { ok $"staged ($a)" } else { bad $"missing ($a) in DUCT_TAPE_LIB dir" }
    }

    say "== the dtrace cone =="
    # Three static libraries (ctf, elf, dwarf), one dylib and four binaries: the largest
    # single block of install entries left, landed together because they only ever build
    # together. libdtrace also carries the committed lex/yacc output (gen/libdtrace), so a
    # build here proves those staged as sources rather than being regenerated.
    for t in [//buck-src:ctf //buck-src:elf //buck-src:dwarf] {
        let a = (out_of $t)
        if (test_s $a) { ok $"built ($t | split row ':' | last) archive" } else { bad $"($t) did not build" }
    }
    let dtl = (out_of //buck-src:libdtrace_dylib)
    if ((cap [file -bL $dtl]) | str contains "Mach-O 64-bit x86_64 dynamically linked shared library") {
        ok "libdtrace.dylib is a Mach-O x86_64 dylib"
    } else {
        bad "libdtrace.dylib is not a Mach-O x86_64 dylib"
    }
    for t in [//buck-src:dtrace //buck-src:lockstat //buck-src:plockstat //buck-src:usdtheadergen] {
        let b = (out_of $t)
        if ((cap [file -bL $b]) | str contains "Mach-O 64-bit x86_64 executable") {
            ok $"built ($t | split row ':' | last)"
        } else {
            bad $"($t) is not a Mach-O x86_64 executable"
        }
    }

    say "== the src/native ELF wrappers (stage 2, gui) =="
    # Sixteen Mach-O stubs that forward to HOST libraries through libelfloader, one per
    # wrap_elf() in src/native. They belong to the gui component, so they are NOT in the cli
    # graph this suite otherwise measures; they are checked here because they build today and a
    # break would otherwise go unnoticed until the stock switch.
    #
    # The export count is the real assertion. An elf_wrapper whose dlopen failed would still
    # produce a valid, EMPTY dylib, so a stub with no exports is the failure mode to catch.
    for n in [X11 cairo GL FreeType gif] {
        let w = (out_of $"//src/native:($n)_dylib")
        if not ((cap [file -bL $w]) | str contains "Mach-O 64-bit x86_64 dynamically linked shared library") {
            bad $"lib($n).dylib is not a Mach-O dylib"
            continue
        }
        let nex = (count_lines_cmd [llvm-nm --defined-only --extern-only $w])
        if $nex >= 50 {
            ok $"lib($n).dylib forwards ($nex) host symbols"
        } else {
            bad $"lib($n).dylib exports only ($nex) symbols \(did wrapgen's dlopen fail?\)"
        }
    }

    say "== the src/CoreAudio ELF wrappers (stage 2, ffmpeg + pulseaudio) =="
    # The same shape as src/native's, five of them, which AudioToolbox links to decode and
    # play. Same assertion for the same reason: a failed dlopen yields a valid EMPTY dylib.
    for n in [avcodec avutil pulse] {
        let w = (out_of $"//src/CoreAudio:($n)_dylib")
        if not ((cap [file -bL $w]) | str contains "Mach-O 64-bit x86_64 dynamically linked shared library") {
            bad $"lib($n).dylib is not a Mach-O dylib"
            continue
        }
        let nex = (count_lines_cmd [llvm-nm --defined-only --extern-only $w])
        if $nex >= 100 {
            ok $"lib($n).dylib forwards ($nex) host symbols"
        } else {
            bad $"lib($n).dylib exports only ($nex) symbols \(did wrapgen's dlopen fail?\)"
        }
    }

    # The buck-registry: pragmas in those files are what makes buck-coverage.py see the
    # wrappers at all -- they are built from Starlark tables, and the registry is a text scan
    # for a literal name/dylib_name pair. Duplicated data drifts, so assert each pragma list
    # and its table still agree. Without this they silently return to reading as unported the
    # moment someone adds one more.
    check_wrap_table src/native/BUCK _NATIVE 's/^    ("\([A-Za-z0-9]*\)", "lib[^"]*", "[^"]*"),$/\1/p'
    check_wrap_table src/CoreAudio/BUCK _AUDIO 's/^    ("\([A-Za-z0-9]*\)", "lib[^"]*"),$/\1/p'

    say "== wrapgen (the host-ELF bridge generator) =="
    # The second host tool (task #8), and the one hdiutil is blocked on: cmake's
    # wrap_elf(<name> lib<name>.so) runs it over a HOST library's dynamic symbol table and emits
    # a Mach-O stub whose every export forwards through libelfloader. Running it is the
    # assertion -- it prints its three-argument usage and exits 0 with no arguments.
    let wg = (out_of //src/libelfloader:wrapgen)
    if ((cap [file -bL $wg]) | str contains "ELF 64-bit") { ok "wrapgen is a host ELF binary" } else { bad "wrapgen is not a host ELF binary" }
    let wgusage = (cap2 [$wg])
    if ($wgusage | str starts-with "Usage:") and ($wgusage | str contains "<library-name> <output-file> <var-access-header>") {
        ok "wrapgen runs and prints usage"
    } else {
        bad "wrapgen did not print its usage"
    }

    say "== darling-coredump (a HOST tool that reads Mach-O) =="
    # The first of the five host tools to land (task #8). It is worth its own check because
    # what it proves is the header slice, not the program: a Linux binary that includes
    # <mach-o/loader.h> without pulling in the SDK headers that would collide with glibc's.
    # Running it is the assertion that the slice produced a real program -- it prints usage and
    # exits 0 with no arguments.
    let cdump = (out_of //src/hosttools:darling-coredump)
    if ((cap [file -bL $cdump]) | str contains "ELF 64-bit") { ok "darling-coredump is a host ELF binary" } else { bad "darling-coredump is not a host ELF binary" }
    let usage = (cap2 [$cdump])
    if ($usage | str starts-with "Usage:") { ok "darling-coredump runs and prints usage" } else { bad "darling-coredump did not print usage" }

    say "== the Rust components (no cargo in the graph) =="
    # All three of Darling's Rust crates, built by rustc under buck2: the launcher, the guest
    # loader and the daemon. The daemon is the one that proves the seam -- it links the
    # buck2-built duct-tape and libsimple archives and the bindgen-generated hooks vtable.
    for t in [//linux/launcher:darling //darwin/loader:mldr //linux/server:darlingserverd] {
        let b = (out_of $t)
        if (is_exec $b) { ok $"built ($t | split row ':' | last)" } else { bad $"($t) did not build" }
    }
    # It refuses to run outside a container, which is exactly the message we want: reaching it
    # means the binary linked and got as far as its own startup check.
    let dmsg = (cap2 [(out_of //linux/server:darlingserverd)])
    if ($dmsg | str contains "not meant to be started manually") {
        ok "darlingserverd links and reaches its startup check"
    } else {
        bad "darlingserverd did not reach its startup check"
    }
    let lver = (cap2 [(out_of //linux/launcher:darling) --version])
    if ($lver | str contains "Rust launcher") { ok "darling --version runs" } else { bad "darling --version failed" }

    say "== buck-src normalisation (what the Nix endpoint materialises) =="
    # The host builds from buck-src as it stands; the Nix endpoint re-runs
    # buck-src-normalise.py over its own copy first. So a bug in that script is invisible on
    # the host and fatal in Nix, which is exactly what happened: expand_dir_links() followed
    # JavaScriptCore's DerivedSources/JavaScriptCore/JavaScriptCore -> ../.. into the tree it
    # was creating, made 1147 directories 266 levels deep out of 13, swallowed the resulting
    # ENAMETOOLONG in `except OSError` and reported expanding nothing. buck2 then crawled the
    # wreckage and aquery died with "File name too long".
    #
    # Tested on a COPY: buck-src holds materialized pins and this must never write to them.
    let norm_t = (mktemp -d)
    do { ^cp -a buck-src/JavaScriptCore/DerivedSources $"($norm_t)/" } | ignore
    ^chmod -R u+w $norm_t
    let before = (wc_l (cap [find $norm_t -type d]))
    do { ^python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("n", "scripts/buck-src-normalise.py")
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.expand_dir_links(sys.argv[1])' $norm_t } | ignore
    let after = (wc_l (cap [find $norm_t -type d]))
    let deep = (lines_of (cap [find $norm_t -type d -printf '%d\n']) | each {|d| $d | into int } | sort | last)
    if $before == $after {
        ok $"expand_dir_links leaves the cyclic JSC link alone \(($after) dirs, depth ($deep)\)"
    } else {
        bad $"expand_dir_links expanded a cycle: ($before) -> ($after) dirs, depth ($deep)"
    }
    if (test_l $"($norm_t)/DerivedSources/JavaScriptCore/JavaScriptCore") {
        ok "the cyclic link survives as a symlink"
    } else {
        bad "the cyclic link was replaced by a real directory"
    }
    do { ^chmod -R u+w $norm_t } | ignore
    ^rm -rf $norm_t

    say "== host headers (the ones that live outside the build graph) =="
    # The port compiles against X11, freetype, fontconfig, cairo, ffmpeg and pulseaudio, and for
    # the whole campaign it never asked for their headers: darwin_cc defaults to the bare name
    # "clang" (buck/toolchains/BUCK), which in the dev shell is the WRAPPED clang and injects
    # them through NIX_CFLAGS_COMPILE. Nothing here noticed until the Nix graph derivation,
    # which pins clang-unwrapped and unsets NIX_CFLAGS on purpose, stopped at
    # "X11/Xlib.h file not found". This asserts the port keeps naming them itself.
    let hi = (cap_rc [./scripts/buck-host-includes.py])
    if $hi.rc == 0 {
        ok (last_line_no_ok $hi.out)
    } else {
        bad "a target compiles against host headers without declaring them"
        print -e (indent7 $hi.out)
    }

    say "== the argv separator (what the Nix lowering replays) =="
    # aquery renders an action's command by joining the argv with ", " and the graph dump splits
    # it back, so an argument containing that separator comes back as two and the lowering
    # replays a DIFFERENT command than buck2 ran. It happened once: perl's VERSIONS is the C
    # initializer for versions.h, and the Nix build died on a ValueError from the configure
    # script while the host, which never round-trips through the rendering, was fine.
    # configure_file passes its values in a file now; this catches the next one for free.
    let ar = (cap_rc [./scripts/buck-argv-roundtrip-check.py --static])
    if $ar.rc == 0 {
        ok (last_line_no_ok $ar.out)
    } else {
        bad "a BUCK literal would put the argv separator into a command"
        print -e (indent7 $ar.out)
    }

    say "== the shell scripts that stay bash =="
    check_shell_scripts

    # Written-down script names rot every time one is renamed, and the reader cannot
    # tell whether the tool moved or was retired. Static and about a second over 518
    # files, so it belongs in the suite rather than in someone's memory.
    let sr = (cap_rc [./scripts/buck-script-refs-check.nu])
    if $sr.rc == 0 {
        ok (last_line_no_ok $sr.out)
    } else {
        bad "a file names a scripts/<name> that is not there"
        print -e (indent7 $sr.out)
    }

    say "== the prefix (what a Darling install actually is) =="
    # The port's product is not the link outputs, it is a laid-out prefix. This builds the
    # whole of it, which is also the broadest single check in this file: 151 targets, and a
    # failure anywhere in the port surfaces here.
    let prefix = (out_of //buck/prefix:darling_prefix)
    let n_entries = (count_files_or_links $"($prefix)/")
    if $n_entries >= 5000 { ok $"prefix has ($n_entries) entries" } else { bad $"prefix has only ($n_entries) entries" }
    for f in [bin/bash bin/sh usr/lib/dyld usr/lib/libSystem.B.dylib usr/lib/system/libsystem_kernel.dylib usr/share/icu/icudt66l.dat] {
        if (test_e $"($prefix)/libexec/darling/($f)") { ok $"prefix has ($f)" } else { bad $"prefix is missing ($f)" }
    }
    # bin/sh is bash under a second name, which is how bash knows to start in POSIX mode.
    let sh_link = (cap [readlink $"($prefix)/libexec/darling/bin/sh"])
    let bash_link = (cap [readlink $"($prefix)/libexec/darling/bin/bash"])
    if $sh_link == $bash_link { ok "bin/sh is the same artifact as bin/bash" } else { bad "bin/sh does not point at bash" }
    if ((cap [file -bL $"($prefix)/libexec/darling/bin/bash"]) | str contains "Mach-O 64-bit x86_64 executable") {
        ok "prefix bash is a Mach-O x86_64 executable"
    } else {
        bad "prefix bash is not Mach-O x86_64"
    }
    # The one install(DIRECTORY) whose source is a build output rather than a repo path, so the
    # only one that needs a prefix_gen_dir. Both halves matter: the DER tables are what Security
    # actually parses, and EVRoots.plist is derived from evroot.config rather than copied, so an
    # empty one would mean the generator ran but found no certificates.
    let bundle = $"($prefix)/libexec/darling/System/Library/Security/Certificates.bundle"
    let n_bundle = (count_files $"($bundle)/")
    if $n_bundle == 10 { ok "Certificates.bundle has its 10 files" } else { bad $"Certificates.bundle has ($n_bundle) files, expected 10" }
    if (test_s $"($bundle)/Contents/Resources/certsTable.data") {
        ok "Certificates.bundle certsTable.data is non-empty"
    } else {
        bad "Certificates.bundle certsTable.data is missing or empty"
    }
    if (grep_q $"($bundle)/Contents/Resources/EVRoots.plist" "<data>") {
        ok "Certificates.bundle EVRoots.plist names EV roots"
    } else {
        bad "Certificates.bundle EVRoots.plist has no roots"
    }

    # Is every .dylib actually a library? scripts/buck-loadall-check.nu found 44 that would not
    # dlopen, and they are 131-byte git LFS pointers: the Swift runtime binaries live in LFS and
    # the checkout never fetched them, so the port installs the pointer under the library's name.
    # Nothing links against them, so no build-time check could see it. Free here because the
    # prefix is already built above.
    let ds = (cap_rc [./scripts/buck-dylib-shape.nu $"($prefix)/libexec/darling"])
    if $ds.rc == 0 {
        ok (last_line_no_ok $ds.out)
    } else {
        bad "a file installed as .dylib is not a library"
        print -e (indent7 $ds.out)
    }

    say ""
    let tally = (open --raw $env.BT_TALLY | split row "\n" | where {|l| $l != "" })
    let pass = ($tally | where {|l| $l == "ok" } | length)
    let fail = ($tally | where {|l| $l == "bad" } | length)
    rm -f $env.BT_TALLY
    say $"($pass) passed, ($fail) failed"
    if $fail != 0 { exit 1 }
}
