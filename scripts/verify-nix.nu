#!/usr/bin/env nu
# verify-nix.nu: standalone health-check for a Nix installation inside Darling
#
# This script runs a comprehensive set of checks to verify that Nix is correctly installed and
# functional inside a Darling prefix. It can be used after running install-nix-in-darling.nu, or
# at any later time to diagnose regressions.
#
# Converted from bash (task #40) and verified against it with `darling` stubbed on PATH, no
# container and no network: a healthy prefix (everything passing), a prefix with no nix binary,
# a guest that reports an unimplemented syscall, a guest whose currentSystem is wrong, a guest
# killed by a signal, --online, --json, --verbose, an unknown option and --help. Output, the
# per-check statuses and the exit code all match, with two documented exceptions.
#
# The unimplemented-syscall detail is printed as TWO LINES here. The bash version built it as
# "detected:\n$lines" and printed it with plain echo, so the \n arrived as two literal
# characters and the detail came out on one line with a visible backslash-n. Statuses, counts
# and exit code are unaffected; only the rendering changes.
#
# An unknown option exits 1 with nushell's own parser message, where bash printed
# "Unknown option: --x (try --help)" and exited 2. nushell parses arguments against the
# signature before the script runs, which is the same divergence every converted script has.
#
# Usage:
#   ./scripts/verify-nix.nu [OPTIONS]
#
# Options:
#   --prefix <path>       Darling prefix path (default: ~/.darling or $DPREFIX)
#   --online              Include checks that require network access (curl, cache)
#   --verbose             Show command output even on success
#   --json                Output results as JSON (for CI consumption)
#
# Exit code: 0 all passed, 1 something failed, 2 nothing passed at all.

def say [c: record, msg: string] { print $"($c.green)[verify-nix]($c.reset) ($msg)" }
def warn [c: record, msg: string] { print -e $"($c.yellow)[verify-nix] WARNING:($c.reset) ($msg)" }
def err_ [c: record, msg: string] { print -e $"($c.red)[verify-nix] ERROR:($c.reset) ($msg)" }

# Colours, disabled when not a terminal and when emitting JSON.
def colours [json: bool] {
    if (not $json) and (is-terminal --stdout) {
        {red: (ansi red), green: (ansi green), yellow: (ansi yellow), blue: (ansi blue)
         bold: (ansi attr_bold), dim: (ansi attr_dimmed), reset: (ansi reset)}
    } else {
        {red: "", green: "", yellow: "", blue: "", bold: "", dim: "", reset: ""}
    }
}

# Run a command inside the Darling prefix. A LIST, not rest arguments: nushell parses a def's
# rest arguments against its signature too, so `dsh sw_vers -productVersion` was rejected as an
# unknown flag on dsh itself.
def dsh [argv: list<string>] {
    ^darling shell ...$argv | complete
}

# Run a command inside Darling with Nix on PATH via a login shell. The sourcing preamble is the
# guest's, so it stays sh and is passed through verbatim.
def dsh_nix [cmd: string] {
    let script = ("
        # Source Nix profile
        if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
            . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
        elif [ -e \"$HOME/.nix-profile/etc/profile.d/nix.sh\" ]; then
            . \"$HOME/.nix-profile/etc/profile.d/nix.sh\"
        elif [ -e '/etc/profile.d/nix-darling.sh' ]; then
            . '/etc/profile.d/nix-darling.sh'
        fi
        " + $cmd + "
    ")
    let r = (^darling shell bash -lc $script | complete)
    {out: $"($r.stdout)($r.stderr)", exit_code: $r.exit_code}
}

# Print one result and return it, so the caller can accumulate. Printing and recording are the
# same step in the bash version and stay so here.
def record [c: record, json: bool, verbose: bool, name: string, status: string, detail: string] {
    if not $json {
        let label = ($name | fill --alignment left --width 55)
        match $status {
            "pass" => {
                print $"  ($c.green)\u{2713}($c.reset) ($label) ($c.green)PASS($c.reset)"
                if $verbose and ($detail | is-not-empty) {
                    $detail | lines | each {|l| print $"      ($l)" }
                }
            }
            "fail" => {
                print $"  ($c.red)\u{2717}($c.reset) ($label) ($c.red)FAIL($c.reset)"
                if ($detail | is-not-empty) {
                    $detail | lines | first 20 | each {|l| print $"      ($l)" }
                }
            }
            _ => {
                print $"  ($c.yellow)\u{2298}($c.reset) ($label) ($c.yellow)SKIP($c.reset)"
                if ($detail | is-not-empty) { print $"      ($detail)" }
            }
        }
    }
    {name: $name, status: $status, detail: $detail}
}

def section [c: record, json: bool, title: string] {
    if not $json {
        print ""
        print $"($c.blue)\u{2501}\u{2501}\u{2501} ($title) \u{2501}\u{2501}\u{2501}($c.reset)"
        print ""
    }
}

# The JSON detail field, escaped the way the bash version escaped it: first five lines, newlines
# and tabs to spaces, double quotes backslashed.
def json_detail [detail: string] {
    # The trailing space is not an accident: bash piped the detail through `tr` and the final
    # newline became a space, so an empty detail came out as a single space and a one-line one
    # as "text ". Matching that keeps the JSON byte-identical.
    (($detail | lines | first 5 | str join " ") + " ")
    | str replace --all '"' '\"'
    | str replace --all "\t" " "
}

def main [
    --prefix: string = ""   # Darling prefix (default: ~/.darling or $DPREFIX)
    --online                # include network-dependent checks
    --verbose (-v)          # show command output even on success
    --json                  # output results as JSON
] {
    let c = (colours $json)
    let darling_prefix = if ($prefix | is-not-empty) {
        $prefix
    } else {
        ($env | get -o DPREFIX | default ($env.HOME | path join ".darling"))
    }
    let conf = $"($darling_prefix)/etc/nix/nix.conf"
    # A literal, like the bash version: an escaped quote cannot appear inside a nushell
    # interpolation, and this nushell has no str repeat.
    let bar = "═══════════════════════════════════════════════════════════"
    mut r = []

    if not $json {
        print ""
        say $c $"($c.bold)($bar)($c.reset)"
        say $c $"($c.bold)  Nix-in-Darling Verification($c.reset)"
        say $c $"($c.bold)($bar)($c.reset)"
    }

    # -- Infrastructure ------------------------------------------------------
    section $c $json "Infrastructure"

    let dpath = (which darling | get path.0? | default "")
    $r = ($r | append (record $c $json $verbose "darling binary in PATH" (if ($dpath | is-empty) { "fail" } else { "pass" }) $dpath))

    $r = ($r | append (record $c $json $verbose "Darling prefix exists" (if ($darling_prefix | path type) == "dir" { "pass" } else { "fail" }) ""))

    let ok = (dsh ["echo" "ok"])
    $r = ($r | append (record $c $json $verbose "darling shell functional" (if $ok.exit_code == 0 { "pass" } else { "fail" }) $"($ok.stdout)($ok.stderr)"))

    for probe in [
        ["/nix exists in prefix", $"($darling_prefix)/nix"]
        ["/nix/store exists", $"($darling_prefix)/nix/store"]
        ["/nix/var/nix/db exists", $"($darling_prefix)/nix/var/nix/db"]
    ] {
        $r = ($r | append (record $c $json $verbose ($probe | first) (if (($probe | last) | path type) == "dir" { "pass" } else { "fail" }) ""))
    }
    $r = ($r | append (record $c $json $verbose "/etc/nix/nix.conf exists" (if ($conf | path type) == "file" { "pass" } else { "fail" }) ""))

    if ($conf | path type) == "file" {
        let has = (open --raw $conf | str contains "build-users-group =")
        $r = ($r | append (record $c $json $verbose "nix.conf: build-users-group is empty" (if $has { "pass" } else { "fail" }) ""))
    } else {
        $r = ($r | append (record $c $json $verbose "nix.conf: build-users-group is empty" "skip" "nix.conf not found"))
    }

    let sb = ((($"($darling_prefix)/usr/bin/sandbox-exec" | path type) == "file")
        or (($"($darling_prefix)/libexec/darling/usr/bin/sandbox-exec" | path type) == "file"))
    $r = ($r | append (record $c $json $verbose "sandbox-exec stub installed" (if $sb { "pass" } else { "fail" }) ""))

    let nixbin = (glob $"($darling_prefix)/nix/store/*/bin/nix" --no-dir)
    $r = ($r | append (record $c $json $verbose "Nix binary found in /nix/store" (if ($nixbin | is-empty) { "fail" } else { "pass" }) (if ($nixbin | is-empty) { "No /nix/store/*/bin/nix found" } else { "" })))

    # -- Core ----------------------------------------------------------------
    section $c $json "Core"
    for cmd in ["nix --version" "nix-env --version" "nix-store --version"
                "nix-instantiate --version" "nix-build --version"] {
        $r = ($r | append (check_nix $c $json $verbose $cmd $cmd))
    }

    # -- Evaluator -----------------------------------------------------------
    section $c $json "Evaluator"
    $r = ($r | append (check_nix $c $json $verbose "nix-instantiate --eval -E '1 + 1'" "nix-instantiate --eval -E '1 + 1'"))
    $r = ($r | append (check_nix $c $json $verbose "nix eval --expr '1 + 1'" "nix eval --expr '1 + 1'"))
    $r = ($r | append (check_nix $c $json $verbose "nix eval --expr '\"hello\"'" "nix eval --expr '\"hello\"'"))

    let sys = (dsh_nix "nix eval --expr 'builtins.currentSystem' --raw")
    let sysname = "builtins.currentSystem == x86_64-darwin"
    $r = ($r | append (
        if $sys.exit_code == 0 and $sys.out == "x86_64-darwin" {
            record $c $json $verbose $sysname "pass" $sys.out
        } else if $sys.exit_code == 0 {
            record $c $json $verbose $sysname "fail" $"Expected 'x86_64-darwin', got '($sys.out)'"
        } else {
            record $c $json $verbose $sysname "fail" $sys.out
        }))

    $r = ($r | append (check_nix $c $json $verbose "nix eval: list operations" "nix eval --expr 'builtins.length [1 2 3]'"))
    $r = ($r | append (check_nix $c $json $verbose "nix eval: let binding" "nix eval --expr 'let x = 21; in x * 2'"))
    $r = ($r | append (check_nix $c $json $verbose "nix eval: string interpolation" "nix eval --expr 'let name = \"darling\"; in \"hello ${name}\"'"))
    $r = ($r | append (check_nix $c $json $verbose "nix eval: import <nixpkgs> (if channel set up)" "nix-instantiate --eval -E 'builtins.typeOf (import <nixpkgs> {})' 2>/dev/null || echo skip"))

    # -- Store ---------------------------------------------------------------
    section $c $json "Store"
    $r = ($r | append (check_nix $c $json $verbose "nix-store --verify (basic)" "nix-store --verify 2>&1 || true"))
    $r = ($r | append (check_nix $c $json $verbose "nix-store --dump-db (database readable)" "nix-store --dump-db | head -1 >/dev/null 2>&1 && echo ok"))

    let sc = (dsh_nix "ls /nix/store/ 2>/dev/null | wc -l")
    $r = ($r | append (
        if $sc.exit_code == 0 {
            record $c $json $verbose $"Store paths exist \(count: ($sc.out | str trim))" "pass" ""
        } else {
            record $c $json $verbose "Store paths exist" "fail" $sc.out
        }))

    $r = ($r | append (check_nix $c $json $verbose "SQLite database integrity" "sqlite3 /nix/var/nix/db/db.sqlite 'PRAGMA integrity_check;' 2>/dev/null || echo 'sqlite3 not available'"))

    # -- Syscall health ------------------------------------------------------
    section $c $json "Syscall Health"
    let sh = (dsh_nix "nix --version 2>&1; nix-instantiate --eval -E '1 + 1' 2>&1")
    let unimpl = ($sh.out | lines | where {|l| ($l | str downcase) =~ 'unimplemented syscall' })
    $r = ($r | append (
        if ($unimpl | is-empty) {
            record $c $json $verbose "No 'Unimplemented syscall' warnings" "pass" ""
        } else {
            record $c $json $verbose "No 'Unimplemented syscall' warnings" "fail" ($unimpl | str join "\n")
        }))
    let stubs = ($sh.out | lines | where {|l| ($l | str downcase) =~ 'stub' })
    $r = ($r | append (
        if ($stubs | is-empty) {
            record $c $json $verbose "No STUB warnings during basic operations" "pass" ""
        } else {
            record $c $json $verbose "No STUB warnings during basic operations" "fail" ($stubs | first 10 | str join "\n")
        }))
    let sg = (dsh_nix "nix eval --expr '1 + 1' 2>&1")
    $r = ($r | append (
        if $sg.exit_code > 128 {
            record $c $json $verbose "No crashes (signals) during evaluation" "fail" $"Killed by signal ($sg.exit_code - 128) \(exit code ($sg.exit_code))"
        } else {
            record $c $json $verbose "No crashes (signals) during evaluation" "pass" ""
        }))

    # -- Network -------------------------------------------------------------
    section $c $json "Network"
    if $online {
        $r = ($r | append (check_nix $c $json $verbose "curl to cache.nixos.org" "curl -sfI https://cache.nixos.org/nix-cache-info >/dev/null 2>&1 && echo ok"))
        $r = ($r | append (check_nix $c $json $verbose "HTTPS/TLS handshake" "curl -sf https://cache.nixos.org/nix-cache-info | head -3"))
        $r = ($r | append (check_nix $c $json $verbose "Binary cache: nix path-info (bash)" "nix path-info --store https://cache.nixos.org /nix/store/$(nix eval --raw nixpkgs#bash.outPath 2>/dev/null | sed 's|/nix/store/||') 2>&1 || echo 'path-info not available (channels may not be set up)'"))
        $r = ($r | append (check_nix $c $json $verbose "DNS resolution" "nslookup cache.nixos.org >/dev/null 2>&1 || host cache.nixos.org >/dev/null 2>&1 || echo 'DNS tools not available, but curl worked'"))
    } else {
        $r = ($r | append (record $c $json $verbose "curl to cache.nixos.org" "skip" "Use --online to enable network checks"))
        $r = ($r | append (record $c $json $verbose "HTTPS/TLS handshake" "skip" "Use --online to enable network checks"))
    }

    # -- Environment ---------------------------------------------------------
    section $c $json "Environment"
    let ver = (dsh ["sw_vers" "-productVersion"])
    let verout = $"($ver.stdout)($ver.stderr)"
    $r = ($r | append (
        if $ver.exit_code == 0 {
            let major = (try { $verout | str trim | split row "." | first | into int } catch { 0 })
            if $major >= 11 {
                record $c $json $verbose $"macOS version >= 11 \(Big Sur): ($verout | str trim)" "pass" ""
            } else {
                record $c $json $verbose $"macOS version >= 11 \(Big Sur): ($verout | str trim)" "fail" $"Nix Darwin binaries target macOS 11+; current version is ($verout | str trim)"
            }
        } else {
            record $c $json $verbose "macOS version >= 11 (Big Sur)" "fail" $verout
        }))

    $r = ($r | append (
        if ($conf | path type) == "file" {
            if (open --raw $conf | str contains "sandbox = false") {
                record $c $json $verbose "nix.conf: sandbox = false" "pass" ""
            } else {
                record $c $json $verbose "nix.conf: sandbox = false" "fail" "Sandbox should be disabled in Darling; add 'sandbox = false' to /etc/nix/nix.conf"
            }
        } else {
            record $c $json $verbose "nix.conf: sandbox = false" "skip" "nix.conf not found"
        }))

    $r = ($r | append (
        if ($conf | path type) == "file" {
            if (open --raw $conf | lines | any {|l| $l =~ 'experimental-features.*nix-command' }) {
                record $c $json $verbose "nix.conf: nix-command flakes enabled" "pass" ""
            } else {
                record $c $json $verbose "nix.conf: nix-command flakes enabled" "skip" "experimental-features not set (optional but recommended)"
            }
        } else {
            record $c $json $verbose "nix.conf: nix-command flakes enabled" "skip" "nix.conf not found"
        }))

    # -- Totals --------------------------------------------------------------
    let total = ($r | length)
    let passed = ($r | where status == "pass" | length)
    let failed = ($r | where status == "fail" | length)
    let skipped = ($r | where status == "skip" | length)

    if $json {
        let stamp = (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")
        print "{"
        print $"  \"timestamp\": \"($stamp)\","
        print $"  \"prefix\": \"($darling_prefix)\","
        print $"  \"online\": (if $online { 1 } else { 0 }),"
        print $"  \"total\": ($total),"
        print $"  \"passed\": ($passed),"
        print $"  \"failed\": ($failed),"
        print $"  \"skipped\": ($skipped),"
        print "  \"results\": ["
        print (
            $r
            | each {|x| $"    {\"name\":\"($x.name)\",\"status\":\"($x.status)\",\"detail\":\"(json_detail $x.detail)\"}" }
            | str join ",\n"
        )
        print "  ]"
        print "}"
        exit (if $failed > 0 { 1 } else { 0 })
    }

    print ""
    say $c $"($c.bold)($bar)($c.reset)"
    say $c $"($c.bold)  Verification Summary($c.reset)"
    say $c $"($c.bold)($bar)($c.reset)"
    print ""
    print $"  Total:   ($total) checks"
    print $"  Passed:  ($c.green)($passed)($c.reset)"
    print $"  Failed:  ($c.red)($failed)($c.reset)"
    print $"  Skipped: ($c.yellow)($skipped)($c.reset)"
    print ""

    if $failed > 0 {
        err_ $c "Some checks failed."
        print -e ""
        print -e "Troubleshooting:"
        print -e "  \u{2022} If Nix binaries aren't found, run: ./scripts/install-nix-in-darling.nu"
        print -e "  \u{2022} If syscall warnings appear, check: PLAN.md"
        print -e "  \u{2022} If evaluator fails, try: darling shell bash -lc 'nix eval --expr 1+1' 2>&1"
        print -e "  \u{2022} For detailed tracing: DARLING_XTRACE=1 darling shell bash -lc 'nix --version'"
        print -e "  \u{2022} For host-side tracing: strace -f -p $(pidof darlingserver) 2>&1 | head -500"
        print -e "  \u{2022} Re-run with --verbose for more detail"
        print -e "  \u{2022} Re-run with --online for network checks"
        print -e ""
        exit 1
    } else if $passed == 0 {
        warn $c "No checks passed \u{2014} Nix may not be installed."
        print -e "  Run: ./scripts/install-nix-in-darling.nu"
        exit 2
    } else {
        say $c $"($c.green)All checks passed!($c.reset) Nix is healthy inside Darling."
        if not $online {
            say $c $"($c.dim)\(Run with --online to also verify network/cache access)($c.reset)"
        }
        exit 0
    }
}

# Run a check inside Darling with Nix on PATH. An unimplemented-syscall line in the output is a
# failure even when the command exited 0, which is the whole reason this wrapper exists.
def check_nix [c: record, json: bool, verbose: bool, name: string, cmd: string] {
    let res = (dsh_nix $cmd)
    let unimpl = ($res.out | lines | where {|l| ($l | str downcase) =~ 'unimplemented syscall' })
    if ($unimpl | is-not-empty) {
        record $c $json $verbose $name "fail" $"Unimplemented syscall\(s) detected:\n($unimpl | first 5 | str join "\n")"
    } else if $res.exit_code == 0 {
        record $c $json $verbose $name "pass" $res.out
    } else {
        record $c $json $verbose $name "fail" $res.out
    }
}
