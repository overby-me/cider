#!/usr/bin/env nu
# run-tests.nu: compile and run all regression tests inside a Darling prefix
#
# This script copies the test source files into the Darling prefix, compiles them using
# Darling's macOS toolchain (cc), and executes them. It collects results from all test suites
# and produces a summary.
#
# Converted from bash (task #40) and verified against it with `darling` stubbed on PATH, no
# container: every suite passing, a suite whose binary exits non-zero, a compilation failure,
# ALL compilations failing (which is its own fatal), an unknown --suite name, a missing prefix,
# a darling shell that does not work, --keep, --verbose and --suite. Output and exit code match
# on all of them, apart from the tips block naming this script instead of the .sh.
#
# Behaviour PRESERVED rather than fixed, because it is a judgement call about what this harness
# promises: when every C suite fails to COMPILE but the shell suites pass, both versions print
# "All tests passed!" and exit 0, with the compiled suites listed as SKIP. The fatal only fires
# when EVERY suite failed to compile.
#
# Usage:
#   ./scripts/run-tests.nu [OPTIONS]
#
# Options:
#   --prefix <path>       Darling prefix path (default: ~/.darling or $DPREFIX)
#   --suite <name>        Run only the named suite (repeatable)
#   --keep                Keep compiled test binaries in the prefix after running
#   --verbose             Show full test output even on success
#
# Prerequisites:
#   - Darling must be installed and `darling shell echo ok` must work
#   - The Darling prefix must be initialized
#
# Exit code:
#   0 all tests passed
#   1 one or more tests failed
#   2 infrastructure error (Darling not working, compilation failure, etc.)

# Each suite: type ("c" or "sh"), source path from the repo root, description, extra cflags.
const SUITES = [
    [name type source desc cflags];
    [renameatx_np c "tests/syscall/test_renameatx_np.c" "renameatx_np (syscall 488) — plain rename, SWAP, EXCL, invalid flags" ""]
    [setattrlist_flags c "tests/syscall/test_setattrlist_flags.c" "setattrlist/getattrlist ATTR_CMN_FLAGS — lchflags, chflags, combined attrs" ""]
    [utimensat c "tests/syscall/test_utimensat.c" "utimensat/setattrlistat — timestamps, MODTIME, ACCTIME, CRTIME, symlinks" ""]
    [sandbox_api c "tests/sandbox/test_sandbox_api.c" "sandbox C API — sandbox_init, sandbox_free_error" ""]
    [sandbox_exec sh "tests/sandbox/test_sandbox_exec.sh" "sandbox-exec stub — flag parsing, exec, exit codes, Nix patterns" ""]
    [dirserv sh "tests/dirserv/test_dirserv.sh" "Directory Services stubs — dseditgroup, sysadminctl, dscl (Phase 5.1)" ""]
    [identity c "tests/identity/test_identity.c" "macOS 14 identity — uname, kern.osrelease/osproductversion/osversion (Phase A)" ""]
    [sw_vers sh "tests/identity/test_sw_vers.sh" "sw_vers identity — productVersion/buildVersion report macOS 14 (Phase A)" ""]
]

# Test directory inside the Darling prefix
const DARLING_TEST_DIR = "/tmp/darling-nix-tests"

# Colours only on a terminal, the same condition the bash version used.
def colours [] {
    if (is-terminal --stdout) {
        {red: (ansi red), green: (ansi green), yellow: (ansi yellow), blue: (ansi blue)
         bold: (ansi attr_bold), dim: (ansi attr_dimmed), reset: (ansi reset)}
    } else {
        {red: "", green: "", yellow: "", blue: "", bold: "", dim: "", reset: ""}
    }
}

def main [
    --prefix: string = ""    # Darling prefix (default: ~/.darling or $DPREFIX)
    # COMMA-SEPARATED, because nushell has no repeatable flag: the bash version took
    # --suite a --suite b, this takes --suite a,b. Everything else about it is the same.
    --suite: string = ""
    --keep                   # keep compiled binaries in the prefix after running
    --verbose (-v)           # show full test output even on success
] {
    let c = (colours)
    let repo_dir = ($env.FILE_PWD | path join ".." | path expand)
    let darling_prefix = if ($prefix | is-not-empty) {
        $prefix
    } else {
        ($env | get -o DPREFIX | default ($env.HOME | path join ".darling"))
    }
    let selected = ($suite | split row "," | each {|x| $x | str trim } | where {|x| $x != "" })

    def log [c: record, msg: string] { print $"($c.green)[run-tests]($c.reset) ($msg)" }
    def warn [c: record, msg: string] { print -e $"($c.yellow)[run-tests] WARNING:($c.reset) ($msg)" }
    def err [c: record, msg: string] { print -e $"($c.red)[run-tests] ERROR:($c.reset) ($msg)" }

    let run_suites = if ($selected | is-empty) {
        $SUITES
    } else {
        let unknown = ($selected | where {|s| ($SUITES | where name == $s | is-empty) })
        if ($unknown | is-not-empty) {
            err $c $"Unknown suite: ($unknown | first) \(available: ($SUITES.name | str join ' '))"
            exit 2
        }
        $selected | each {|s| $SUITES | where name == $s | first }
    }

    # -- Preflight ----------------------------------------------------------
    log $c $"($c.bold)Preflight checks...($c.reset)"
    if (which darling | is-empty) {
        err $c "darling is not installed or not in PATH"
        exit 2
    }
    if ($darling_prefix | path type) != "dir" {
        err $c $"Darling prefix not found at ($darling_prefix)\n   Initialize with: darling shell true"
        exit 2
    }
    if (dsh_ok) == false {
        err $c "darling shell is not functional\n   Try: darling shell echo ok"
        exit 2
    }
    log $c $"  Prefix: ($darling_prefix)"
    log $c $"  Suites: ($run_suites.name | str join ' ')"

    for s in $run_suites {
        if not ($"($repo_dir)/($s.source)" | path exists) {
            err $c $"Source file not found: ($s.source)\n   Expected at: ($repo_dir)/($s.source)"
            exit 2
        }
    }

    # -- Copy test sources into the prefix ----------------------------------
    log $c $"($c.bold)Copying test sources into Darling prefix...($c.reset)"
    let prefix_test_dir = $"($darling_prefix)/private/tmp/darling-nix-tests"
    mkdir $prefix_test_dir
    for s in $run_suites {
        ^cp $"($repo_dir)/($s.source)" $"($prefix_test_dir)/"
        log $c $"  Copied ($s.source)"
    }

    # -- Compile C test suites ----------------------------------------------
    log $c $"($c.bold)Compiling C test suites inside Darling...($c.reset)"
    mut compile_failures = 0
    for s in ($run_suites | where type == "c") {
        let base = ($s.source | path basename)
        let bin = ($base | str replace --regex '\.c$' '')
        log $c $"  Compiling ($base) ..."
        let cmd = $"cd ($DARLING_TEST_DIR) && cc -Wall -Wextra -o '($bin)' '($base)' ($s.cflags) 2>&1"
        let r = (^darling shell bash -c $cmd | complete)
        if $r.exit_code != 0 {
            err $c $"  Compilation of ($base) FAILED:"
            $"($r.stdout)($r.stderr)" | lines | each {|l| print -e $"    ($l)" }
            $compile_failures = $compile_failures + 1
            continue
        }
        if $verbose and (($r.stdout | str trim) | is-not-empty) {
            $r.stdout | lines | each {|l| print $"    ($l)" }
        }
        log $c $"  ($c.green)\u{2713}($c.reset) ($bin) compiled"
    }
    if $compile_failures > 0 {
        err $c $"($compile_failures) suite\(s) failed to compile"
        if $compile_failures == ($run_suites | length) {
            err $c "All suites failed to compile \u{2014} is the Darling toolchain working?"
            exit 2
        }
    }

    # -- Run test suites -----------------------------------------------------
    print ""
    log $c $"($c.bold)═══════════════════════════════════════════════════════════($c.reset)"
    log $c $"($c.bold)  Running Darling regression tests($c.reset)"
    log $c $"($c.bold)═══════════════════════════════════════════════════════════($c.reset)"
    print ""

    mut results = []
    for s in $run_suites {
        let base = ($s.source | path basename)
        print $"($c.blue)\u{2501}\u{2501}\u{2501} Suite: ($s.name) \u{2501}\u{2501}\u{2501}($c.reset)"
        print $"($c.dim)($s.desc)($c.reset)"
        print ""

        mut verdict = "skip"
        mut out = ""
        mut code = 0
        if $s.type == "c" {
            let bin = ($base | str replace --regex '\.c$' '')
            let chk = (^darling shell test -x $"($DARLING_TEST_DIR)/($bin)" | complete)
            if $chk.exit_code != 0 {
                print $"  ($c.yellow)SKIPPED($c.reset) \u{2014} compilation failed"
                print ""
                $results = ($results | append {name: $s.name, verdict: "skip"})
                continue
            }
            let r = (^darling shell bash -c $"cd ($DARLING_TEST_DIR) && ./($bin) 2>&1" | complete)
            $out = $"($r.stdout)($r.stderr)"
            $code = $r.exit_code
        } else {
            let r = (^darling shell bash -c $"cd ($DARLING_TEST_DIR) && sh '($base)' 2>&1" | complete)
            $out = $"($r.stdout)($r.stderr)"
            $code = $r.exit_code
        }

        if $code == 0 {
            $verdict = "pass"
            if $verbose {
                print ($out | str trim --right --char "\n")
                print ""
            }
            print $"  ($c.green)\u{2713} PASSED($c.reset)"
        } else {
            $verdict = "fail"
            # Always show output on failure.
            print ($out | str trim --right --char "\n")
            print ""
            print $"  ($c.red)\u{2717} FAILED($c.reset) \(exit code: ($code))"
        }
        $results = ($results | append {name: $s.name, verdict: $verdict})
        print ""
    }

    # -- Cleanup -------------------------------------------------------------
    if not $keep {
        log $c "Cleaning up test files from prefix..."
        ^rm -rf $prefix_test_dir
    } else {
        log $c $"Test binaries preserved at: ($DARLING_TEST_DIR) \(inside prefix)"
        log $c $"  Host path: ($prefix_test_dir)"
    }

    # -- Summary -------------------------------------------------------------
    let passed = ($results | where verdict == "pass" | length)
    let failed = ($results | where verdict == "fail" | length)
    let skipped = ($results | where verdict == "skip" | length)
    let total = ($results | length)

    print ""
    log $c $"($c.bold)═══════════════════════════════════════════════════════════($c.reset)"
    log $c $"($c.bold)  Test Summary($c.reset)"
    log $c $"($c.bold)═══════════════════════════════════════════════════════════($c.reset)"
    print ""
    print $"  ('Suite' | fill --alignment left --width 25) Result"
    print $"  ('─────────────────────────' | fill --alignment left --width 25) ──────"
    for r in $results {
        let label = ($r.name | fill --alignment left --width 25)
        match $r.verdict {
            "pass" => { print $"  ($label) ($c.green)\u{2713} PASS($c.reset)" }
            "fail" => { print $"  ($label) ($c.red)\u{2717} FAIL($c.reset)" }
            _ => { print $"  ($label) ($c.yellow)\u{2298} SKIP($c.reset)" }
        }
    }
    print ""
    print $"  Total:   ($total) suites"
    print $"  Passed:  ($c.green)($passed)($c.reset)"
    print $"  Failed:  ($c.red)($failed)($c.reset)"
    print $"  Skipped: ($c.yellow)($skipped)($c.reset)"
    print ""

    if $failed > 0 {
        err $c "Some test suites failed."
        print -e ""
        print -e "Debugging tips:"
        print -e "  \u{2022} Re-run with --verbose to see full output for passing tests"
        print -e "  \u{2022} Run a single suite: scripts/run-tests.nu --suite <name>"
        print -e "  \u{2022} Run with --keep to preserve binaries, then inspect inside:"
        print -e $"      darling shell ($DARLING_TEST_DIR)/<test_binary>"
        print -e "  \u{2022} Trace syscalls: strace -f -p $(pidof darlingserver) 2>&1 | head"
        print -e $"  \u{2022} Darling xtrace: DARLING_XTRACE=1 darling shell ($DARLING_TEST_DIR)/<test_binary>"
        print -e ""
        exit 1
    } else if $skipped > 0 and $passed == 0 {
        warn $c "All suites were skipped \u{2014} check compilation errors above."
        exit 2
    } else {
        log $c $"($c.green)All tests passed!($c.reset)"
        exit 0
    }
}

# `darling shell echo ok`, as a predicate.
def dsh_ok [] {
    (^darling shell echo ok | complete | get exit_code) == 0
}
