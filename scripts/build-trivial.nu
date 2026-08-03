#!/usr/bin/env nu
# build-trivial.nu: attempt to build trivial Nix derivations inside Darling
#
# This script exercises Phase 4.1 of the plan: building progressively more
# complex derivations inside a Darling prefix to validate that the full Nix
# build pipeline works (posix_spawn, sandbox-exec, builder, store).
#
# Usage:
#   ./scripts/build-trivial.nu [OPTIONS]
#
# Options:
#   --prefix <path>       Darling prefix path (default: ~/.darling or $DPREFIX)
#   --level <N>           Run only derivation level N (1-5, default: all)
#   --keep                Do not garbage-collect built derivations
#   --verbose             Show full nix-build output
#   --debug               Pass -vvvv --debug to nix-build (very verbose)
#
# Derivation Levels:
#   1  Echo to $out (no deps, /bin/bash only)
#   2  Multi-line builder script writing to $out
#   3  Derivation that reads and transforms input files
#   4  Derivation with a dependency on another derivation
#   5  Fetch a file from the binary cache (requires network)
#
# Exit codes:
#   0  all attempted levels passed
#   1  one or more levels failed
#   2  infrastructure error
#
# Converted from bash (task #40) and verified against it with darling stubbed on
# PATH, no container: every level passing, level 1 failing (which skips the rest),
# level 3 returning the wrong count, a build with no store path in its output, an
# unreachable cache (level 5 skips), a prefix that does not exist, a dead darling
# shell, and no Nix in the prefix; each of those with no flags, --level N, --keep,
# --verbose and --debug. Output, exit code AND the exact argv handed to darling
# (the guest script text, which is what actually gets executed) all match.
#
# Two deviations, both in argument handling: --help prints nushell's own signature
# help rather than the hand-written usage block, and an unknown option or a missing
# flag argument is rejected by the nushell parser with exit 1 where bash printed its
# own message and exited 2.
#
# See: PLAN.md (Task 4.1)

def colours [] {
    if (is-terminal --stdout) {
        {red: (ansi red), green: (ansi green), yellow: (ansi yellow), blue: (ansi blue)
         bold: (ansi attr_bold), dim: (ansi attr_dimmed), reset: (ansi reset)}
    } else {
        {red: "", green: "", yellow: "", blue: "", bold: "", dim: "", reset: ""}
    }
}

# printf "%-5s"/"%-35s" pads by BYTES; fill pads by characters. Every value that
# reaches these is ASCII, and the two box-drawing rows are already wider than the
# field in both counts, so the two agree.
def pad5 [s: string] { $s | fill --alignment l --width 5 }
def pad35 [s: string] { $s | fill --alignment l --width 35 }

# bash printed $0, which is the path as invoked rather than the resolved one.
def self_name [] { $env | get -o PROCESS_PATH | default "./scripts/build-trivial.nu" }

def log_ [c: record, msg: string] { print $"($c.green)[build-trivial]($c.reset) ($msg)" }
def warn [c: record, msg: string] { print -e $"($c.yellow)[build-trivial] WARNING:($c.reset) ($msg)" }
def err_ [c: record, msg: string] { print -e $"($c.red)[build-trivial] ERROR:($c.reset) ($msg)" }

# bash captured every one of these with $(...) and 2>&1, so stdout and stderr are
# one stream and the trailing newlines are gone. complete keeps the two streams
# apart, so the merge goes through a file instead.
def run_merged [argv: list<string>] {
    let f = (mktemp --tmpdir --suffix .build-trivial)
    let rc = (try {
        ^darling shell ...$argv out+err> $f
        0
    } catch {
        $env.LAST_EXIT_CODE
    })
    let text = (if ($f | path exists) { open --raw $f } else { "" })
    rm -f $f
    {out: ($text | str replace -r '\n+$' ''), rc: $rc}
}

# The guest-side profile prelude, verbatim from the bash version: the leading
# newline, the eight-space indent and the escaped $HOME are all part of the script
# that darling actually runs, so they are reproduced rather than tidied.
def nix_prelude [] {
    "
        # Source Nix profile
        if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
            . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
        elif [ -e \"\\$HOME/.nix-profile/etc/profile.d/nix.sh\" ]; then
            . \"\\$HOME/.nix-profile/etc/profile.d/nix.sh\"
        elif [ -e '/etc/profile.d/nix-darling.sh' ]; then
            . '/etc/profile.d/nix-darling.sh'
        fi
        "
}

# Run a command inside Darling with Nix on PATH.
def dsh_nix [cmd: string] {
    run_merged ["bash" "-lc" ((nix_prelude) + $cmd + "\n    ")]
}

# echo "$text" | sed 's/^/    /': an empty string is still one (indented) line,
# which is why this splits rather than using lines.
def indent4 [text: string] {
    $text | split row "\n" | each {|l| $"    ($l)" } | str join "\n"
}

def tail_n [text: string, n: int] {
    let rows = ($text | split row "\n")
    $rows | last ([($rows | length) $n] | math min) | str join "\n"
}

def store_path_of [text: string] {
    let hits = ($text | split row "\n" | where {|l| $l | str starts-with "/nix/store/" })
    if ($hits | is-empty) { "" } else { $hits | last }
}

# ── Level definitions ───────────────────────────────────────────────────────
#
# Each level prints what it exercises, runs the build, and returns 0 on success,
# 1 on failure, 2 on skip.

def level1_echo_to_out [ctx: record] {
    print r#'  Level 1: Echo to $out
  Exercises: posix_spawn, sandbox-exec stub, /bin/bash, file creation
             in /nix/store, store path registration, chmod/lchflags on
             store path.'#

    let expr = r#'derivation {
        name = "darling-test-1-echo";
        builder = "/bin/bash";
        args = [ "-c" "echo Hello from Darling > $out" ];
        system = "x86_64-darwin";
    }'#

    let nix_flags = if $ctx.debug { "-vvvv" } else { "" }
    let r = (dsh_nix $"nix-build --no-out-link ($nix_flags) --expr '($expr)' 2>&1")

    if $ctx.verbose { print (indent4 $r.out) }

    if $r.rc != 0 {
        print (indent4 (tail_n $r.out 20))
        print ""
        print "  Debugging hints for Level 1 failure:"
        print "    \u{2022} 'clearing flags of path': lchflags still broken (Phase 1.1)"
        print "    \u{2022} 'Bad file descriptor' / ENOEXEC: sandbox-exec stub issue (Phase 2)"
        print "    \u{2022} 'sandbox profile' write fail: check /tmp is writable inside prefix"
        print "    \u{2022} Builder hangs: posix_spawn with POSIX_SPAWN_SETEXEC broken"
        print "    \u{2022} 'Unimplemented syscall': check PLAN.md"
        print ""
        print "  Manual reproduction:"
        print $"    darling shell bash -lc 'nix-build -vvvv --no-out-link --expr \"($expr)\"'"
        print "    darling shell /usr/bin/sandbox-exec -f /dev/null /bin/bash -c 'echo ok'"
        return 1
    }

    let store_path = (store_path_of $r.out)
    if ($store_path | is-empty) {
        print "  Build appeared to succeed but no store path in output."
        print $"  Output: ($r.out)"
        return 1
    }

    let content = (dsh_nix $"cat '($store_path)'").out
    if ($content | str contains "Hello from Darling") {
        print $"  Store path: ($store_path)"
        print $"  Content:    ($content | split row "\n" | first)"
        return 0
    } else {
        print "  Store path content mismatch."
        print "  Expected: 'Hello from Darling'"
        print $"  Got:      '($content)'"
        return 1
    }
}

def level2_multiline_builder [ctx: record] {
    print r#'  Level 2: Multi-line builder script
  Exercises: bash scripting, variables, loops, file I/O, mkdir, directory
             output (vs single file), multiple files in $out.'#

    let expr = r##'derivation {
        name = "darling-test-2-multiline";
        builder = "/bin/bash";
        args = [ "-c" "
            set -e
            mkdir -p $out/bin $out/share
            echo \"#!/bin/bash\" > $out/bin/hello
            echo \"echo Hello from Darling build\" >> $out/bin/hello
            chmod +x $out/bin/hello
            for i in 1 2 3; do
                echo \"Item $i\" > $out/share/item-$i.txt
            done
            echo done > $out/share/status.txt
        " ];
        system = "x86_64-darwin";
    }'##

    let nix_flags = if $ctx.debug { "-vvvv" } else { "" }
    let r = (dsh_nix $"nix-build --no-out-link ($nix_flags) --expr '($expr)' 2>&1")

    if $ctx.verbose { print (indent4 $r.out) }

    if $r.rc != 0 {
        print (indent4 (tail_n $r.out 20))
        print ""
        print "  Debugging hints for Level 2 failure:"
        print "    \u{2022} mkdir/chmod failures: filesystem or syscall issue"
        print "    \u{2022} 'for' loop issues: bash not fully working in sandbox"
        print "    \u{2022} Same as Level 1 hints if Level 1 also failed"
        return 1
    }

    let store_path = (store_path_of $r.out)
    if ($store_path | is-empty) {
        print "  No store path in output."
        return 1
    }

    let verify = (dsh_nix $"
        test -x '($store_path)/bin/hello' &&
        test -f '($store_path)/share/item-1.txt' &&
        test -f '($store_path)/share/item-2.txt' &&
        test -f '($store_path)/share/item-3.txt' &&
        test -f '($store_path)/share/status.txt' &&
        grep -q 'done' '($store_path)/share/status.txt'
    ")

    if $verify.rc == 0 {
        print $"  Store path: ($store_path)"
        print "  Verified:   bin/hello (executable), share/item-{1,2,3}.txt, share/status.txt"
        return 0
    } else {
        print "  Output verification failed."
        print $"  Store path: ($store_path)"
        print (indent4 (dsh_nix $"find '($store_path)' -type f 2>/dev/null").out)
        return 1
    }
}

def level3_input_transform [ctx: record] {
    print r#'  Level 3: Input transformation
  Exercises: builtins.toFile, passing string context to a derivation,
             reading input files, text processing (wc, sort).'#

    let expr = r#'let
        input = builtins.toFile "input.txt" "apple\nbanana\ncherry\ndate\nelderberry\n";
    in derivation {
        name = "darling-test-3-transform";
        builder = "/bin/bash";
        args = [ "-c" "
            set -e
            mkdir -p $out
            cp ${input} $out/original.txt
            sort ${input} > $out/sorted.txt
            wc -l < ${input} | tr -d \" \" > $out/count.txt
        " ];
        system = "x86_64-darwin";
        inherit input;
    }'#

    let nix_flags = if $ctx.debug { "-vvvv" } else { "" }
    let r = (dsh_nix $"nix-build --no-out-link ($nix_flags) --expr '($expr)' 2>&1")

    if $ctx.verbose { print (indent4 $r.out) }

    if $r.rc != 0 {
        print (indent4 (tail_n $r.out 20))
        print ""
        print "  Debugging hints for Level 3 failure:"
        print "    \u{2022} builtins.toFile failure: store write issue"
        print "    \u{2022} sort/wc not found: PATH issue inside build sandbox"
        print "    \u{2022} Input file not readable: store path access issue"
        return 1
    }

    let store_path = (store_path_of $r.out)
    if ($store_path | is-empty) {
        print "  No store path in output."
        return 1
    }

    let count = ((dsh_nix $"cat '($store_path)/count.txt'").out | str replace -a -r '\s' '')
    if $count == "5" {
        print $"  Store path: ($store_path)"
        print $"  Line count: ($count) \(correct\)"
        return 0
    } else {
        print $"  Count verification failed: expected '5', got '($count)'"
        return 1
    }
}

def level4_derivation_dependency [ctx: record] {
    print r#'  Level 4: Derivation dependency
  Exercises: one derivation depending on another's output, Nix's dependency
             tracking, incremental builds, store path references.'#

    let expr = r#'let
        dep = derivation {
            name = "darling-test-4-dep";
            builder = "/bin/bash";
            args = [ "-c" "echo DEPENDENCY_OUTPUT > $out" ];
            system = "x86_64-darwin";
        };
    in derivation {
        name = "darling-test-4-consumer";
        builder = "/bin/bash";
        args = [ "-c" "
            set -e
            mkdir -p $out
            content=\$(cat ${dep})
            echo \"Read from dep: \$content\" > $out/result.txt
            echo ${dep} > $out/dep-path.txt
        " ];
        system = "x86_64-darwin";
        inherit dep;
    }'#

    let nix_flags = if $ctx.debug { "-vvvv" } else { "" }
    let r = (dsh_nix $"nix-build --no-out-link ($nix_flags) --expr '($expr)' 2>&1")

    if $ctx.verbose { print (indent4 $r.out) }

    if $r.rc != 0 {
        print (indent4 (tail_n $r.out 20))
        print ""
        print "  Debugging hints for Level 4 failure:"
        print "    \u{2022} If dep itself failed: same as Level 1/2 hints"
        print "    \u{2022} If consumer failed reading dep: store path access issue"
        print "    \u{2022} Build order issue: Nix should build dep first automatically"
        return 1
    }

    let store_path = (store_path_of $r.out)
    if ($store_path | is-empty) {
        print "  No store path in output."
        return 1
    }

    let result = (dsh_nix $"cat '($store_path)/result.txt'").out
    if ($result | str contains "DEPENDENCY_OUTPUT") {
        print $"  Store path: ($store_path)"
        print $"  Result:     ($result)"
        let dep_path = (dsh_nix $"cat '($store_path)/dep-path.txt'").out
        print $"  Dep path:   ($dep_path | split row "\n" | first)"
        return 0
    } else {
        print "  Dependency content not found in result."
        print "  Expected to contain: 'DEPENDENCY_OUTPUT'"
        print $"  Got:                 '($result)'"
        return 1
    }
}

def level5_binary_substitution [ctx: record] {
    print r#'  Level 5: Binary substitution (requires network)
  Exercises: curl/TLS, binary cache access, NAR download, signature
             verification, store path registration from remote.'#

    # Check if we can reach the cache first
    let cache_check = (dsh_nix "curl -sfI https://cache.nixos.org/nix-cache-info 2>&1 | head -1").out
    if not ($cache_check | str downcase | str contains "200") {
        print "  Cannot reach cache.nixos.org \u{2014} skipping Level 5."
        print "  (This level requires network access.)"
        print $"  cache check result: ($cache_check)"
        return 2  # special: skip, not fail
    }

    # Try to realise a simple, very small store path from the cache. hello is
    # small and almost always cached.
    let r = (dsh_nix r##'
        # Try to fetch a tiny package from the cache.
        # 'hello' is small and almost always cached.
        nix build --no-link --print-out-paths \
            --expr '(import <nixpkgs> {}).hello' \
            --substituters https://cache.nixos.org \
            --trusted-public-keys 'cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=' \
            2>&1
    '##)

    if $ctx.verbose { print (indent4 $r.out) }

    if $r.rc != 0 {
        print (indent4 (tail_n $r.out 20))
        print ""
        print "  Debugging hints for Level 5 failure:"
        print "    \u{2022} 'SSL' / 'TLS' error: Darling's certificate bundle may be outdated"
        print "    \u{2022} 'cannot connect': DNS or network issue inside Darling"
        print "    \u{2022} '<nixpkgs>' not found: channels not set up \u{2014} run nix-channel --update"
        print "    \u{2022} NAR download failure: curl or decompression issue"
        print "    \u{2022} Signature mismatch: trusted-public-keys not configured"
        return 1
    }

    let store_path = (store_path_of $r.out)
    if ($store_path | is-empty) {
        print "  Build output did not contain a store path."
        print $"  Output: (tail_n $r.out 5)"
        return 1
    }

    let hello_output = (dsh_nix $"'($store_path)/bin/hello'").out
    if ($hello_output | str downcase | str contains "hello") {
        print $"  Store path: ($store_path)"
        print $"  Output:     ($hello_output)"
        return 0
    } else {
        print $"  Store path: ($store_path)"
        print $"  hello binary did not produce expected output: ($hello_output)"
        print "  (This may be OK \u{2014} the binary was fetched, which is the main test.)"
        return 0
    }
}

def run_level [n: int, ctx: record] {
    match $n {
        1 => (level1_echo_to_out $ctx)
        2 => (level2_multiline_builder $ctx)
        3 => (level3_input_transform $ctx)
        4 => (level4_derivation_dependency $ctx)
        5 => (level5_binary_substitution $ctx)
    }
}

def main [
    --prefix: string = ""   # Darling prefix (default: ~/.darling or $DPREFIX)
    --level: string = ""    # run only level N (1-5; default: all)
    --keep                  # do not garbage-collect built derivations
    --verbose (-v)          # show full nix-build output
    --debug                 # pass -vvvv --debug to nix-build
] {
    let c = (colours)
    let darling_prefix = if ($prefix | is-not-empty) {
        $prefix
    } else {
        ($env | get -o DPREFIX | default ($env.HOME | path join ".darling"))
    }
    if ($level | is-not-empty) and not ($level =~ '^[1-5]$') {
        err_ $c $"--level must be 1-5, got: ($level)"
        exit 2
    }
    # --debug implies --verbose, as in the bash version
    let ctx = {debug: $debug, verbose: ($verbose or $debug)}

    # ── Preflight ───────────────────────────────────────────────────────────
    log_ $c $"($c.bold)Preflight checks...($c.reset)"

    if (which darling | is-empty) {
        err_ $c "darling is not in PATH"
        exit 2
    }
    if ($darling_prefix | path type) != "dir" {
        err_ $c $"Darling prefix not found at ($darling_prefix)"
        exit 2
    }
    if (run_merged ["echo" "ok"]).rc != 0 {
        err_ $c "darling shell is not functional"
        exit 2
    }

    let nix_version = (dsh_nix "nix --version").out
    if ($nix_version | is-empty) or not ($nix_version | str downcase | str contains "nix") {
        err_ $c "Nix does not appear to be installed in the Darling prefix.\n   Run: ./scripts/install-nix-in-darling.nu"
        exit 2
    }

    log_ $c $"  Prefix: ($darling_prefix)"
    log_ $c $"  Nix:    ($nix_version)"

    # ── Execute ─────────────────────────────────────────────────────────────
    let all_levels = [1 2 3 4 5]
    let run_levels = if ($level | is-not-empty) { [($level | into int)] } else { $all_levels }
    let level_names = {
        "1": "Echo to $out"
        "2": "Multi-line builder"
        "3": "Input transformation"
        "4": "Derivation dependency"
        "5": "Binary substitution (network)"
    }
    let bar = "═══════════════════════════════════════════════════════════"

    print ""
    log_ $c $"($c.bold)($bar)($c.reset)"
    log_ $c $"($c.bold)  Trivial Derivation Build Tests \(Phase 4.1\)($c.reset)"
    log_ $c $"($c.bold)($bar)($c.reset)"
    print ""

    mut passed = 0
    mut failed = 0
    mut skipped = 0
    mut results = {}

    for lv in $run_levels {
        let name = ($level_names | get ($lv | into string))
        print $"($c.blue)\u{2501}\u{2501}\u{2501} Level ($lv): ($name) \u{2501}\u{2501}\u{2501}($c.reset)"
        print ""

        let rc = (run_level $lv $ctx)

        print ""

        if $rc == 0 {
            $passed = $passed + 1
            $results = ($results | upsert ($lv | into string) "pass")
            print $"  ($c.green)\u{2713} Level ($lv) PASSED($c.reset)"
        } else if $rc == 2 {
            $skipped = $skipped + 1
            $results = ($results | upsert ($lv | into string) "skip")
            print $"  ($c.yellow)\u{2298} Level ($lv) SKIPPED($c.reset)"
        } else {
            $failed = $failed + 1
            $results = ($results | upsert ($lv | into string) "fail")
            print $"  ($c.red)\u{2717} Level ($lv) FAILED($c.reset)"

            # If an early level fails, later levels will almost certainly fail too
            if $lv <= 2 and ($level | is-empty) {
                warn $c $"Level ($lv) failed \u{2014} skipping remaining levels \(they depend on this\)."
                for remaining in $run_levels {
                    if $remaining > $lv and (($results | get -o ($remaining | into string)) == null) {
                        $skipped = $skipped + 1
                        $results = ($results | upsert ($remaining | into string) "skip")
                    }
                }
                break
            }
        }

        print ""
    }

    # ── Garbage collection ──────────────────────────────────────────────────
    if (not $keep) and $passed > 0 {
        log_ $c "Cleaning up test derivations..."
        dsh_nix "nix-collect-garbage 2>/dev/null" | ignore
    } else if $keep {
        log_ $c "Keeping built derivations (--keep)."
    }

    # ── Summary ─────────────────────────────────────────────────────────────
    let total = $passed + $failed + $skipped

    print ""
    log_ $c $"($c.bold)($bar)($c.reset)"
    log_ $c $"($c.bold)  Build Test Summary($c.reset)"
    log_ $c $"($c.bold)($bar)($c.reset)"
    print ""

    print $"  (pad5 'Level') (pad35 'Name') Result"
    # bash printf pads by BYTES, and these box characters are three bytes each, so
    # both separator fields are already over their field width and get no padding.
    print "  ───── ─────────────────────────────────── ──────"

    for lv in $all_levels {
        let key = ($lv | into string)
        let result = ($results | get -o $key | default "skip")
        let name = ($level_names | get $key)
        let cell = match $result {
            "pass" => $"($c.green)\u{2713} PASS($c.reset)"
            "fail" => $"($c.red)\u{2717} FAIL($c.reset)"
            _ => $"($c.yellow)\u{2298} SKIP($c.reset)"
        }
        print $"  (pad5 $key) (pad35 $name) ($cell)"
    }

    print ""
    print $"  Total:   ($total) levels"
    print $"  Passed:  ($c.green)($passed)($c.reset)"
    print $"  Failed:  ($c.red)($failed)($c.reset)"
    print $"  Skipped: ($c.yellow)($skipped)($c.reset)"
    print ""

    if $failed > 0 {
        err_ $c "Some build levels failed."
        print -e ""
        print -e "Next steps:"
        print -e $"  \u{2022} Run a single level:  (self_name) --level N --debug"
        print -e "  \u{2022} Manual build:        darling shell bash -lc 'nix-build -vvvv --expr \"...\"'"
        print -e "  \u{2022} Manual sandbox test: darling shell /usr/bin/sandbox-exec -f /dev/null /bin/bash -c 'echo ok'"
        print -e "  \u{2022} Check syscalls:      ./scripts/triage-syscalls.nu"
        print -e "  \u{2022} Host-side trace:     strace -f -p $(pidof darlingserver) 2>&1 | head -500"
        print -e "  \u{2022} Darling xtrace:      DARLING_XTRACE=1 darling shell bash -lc 'nix-build --expr ...'"
        print -e ""
        exit 1
    } else if $passed == 0 {
        warn $c "No levels were attempted \u{2014} check that Nix is installed."
        exit 2
    } else {
        log_ $c $"($c.green)All build levels passed!($c.reset)"
        if $skipped > 0 {
            log_ $c $"($c.dim)\(($skipped) levels skipped \u{2014} re-run with --level N to target them\)($c.reset)"
        }
        log_ $c ""
        log_ $c "Phase 4.1 is complete! Next steps:"
        log_ $c "  \u{2022} Phase 4.2: Test bash in build sandboxes (more complex scripts)"
        log_ $c "  \u{2022} Phase 4.5: Build a C program with Darwin stdenv"
        log_ $c "  \u{2022} See: PLAN.md"
        exit 0
    }
}
