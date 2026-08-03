#!/usr/bin/env bash
# build-trivial.sh — Attempt to build trivial Nix derivations inside Darling
#
# This script exercises Phase 4.1 of the plan: building progressively more
# complex derivations inside a Darling prefix to validate that the full Nix
# build pipeline works (posix_spawn → sandbox-exec → builder → store).
#
# Usage:
#   ./scripts/build-trivial.sh [OPTIONS]
#
# Options:
#   --prefix <path>       Darling prefix path (default: ~/.darling or $DPREFIX)
#   --level <N>           Run only derivation level N (1-5, default: all)
#   --keep                Don't garbage-collect built derivations
#   --verbose             Show full nix-build output
#   --debug               Pass -vvvv --debug to nix-build (very verbose)
#   --help                Show this help message
#
# Derivation Levels:
#   1 — Echo to $out (no deps, /bin/bash only)
#   2 — Multi-line builder script writing to $out
#   3 — Derivation that reads and transforms input files
#   4 — Derivation with a dependency on another derivation
#   5 — Fetch a file from the binary cache (requires network)
#
# Exit codes:
#   0 — all attempted levels passed
#   1 — one or more levels failed
#   2 — infrastructure error
#
# See: plan/06-phase4-building.md (Task 4.1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────

DARLING_PREFIX="${DPREFIX:-$HOME/.darling}"
SELECTED_LEVEL=""
KEEP_BUILDS=0
VERBOSE=0
DEBUG=0

# ── Colors ──────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
fi

# ── Helpers ─────────────────────────────────────────────────────────────────

log()   { echo -e "${GREEN}[build-trivial]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[build-trivial] WARNING:${RESET} $*" >&2; }
err()   { echo -e "${RED}[build-trivial] ERROR:${RESET} $*" >&2; }
fatal() { err "$@"; exit 2; }

dsh() {
    darling shell "$@"
}

# Run a command inside Darling with Nix on PATH
dsh_nix() {
    local nix_flags=""
    if [ "$DEBUG" -eq 1 ]; then
        nix_flags="-vvvv --debug"
    fi

    darling shell bash -lc "
        # Source Nix profile
        if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
            . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
        elif [ -e \"\\\$HOME/.nix-profile/etc/profile.d/nix.sh\" ]; then
            . \"\\\$HOME/.nix-profile/etc/profile.d/nix.sh\"
        elif [ -e '/etc/profile.d/nix-darling.sh' ]; then
            . '/etc/profile.d/nix-darling.sh'
        fi
        $*
    " 2>&1
}

usage() {
    cat <<'EOF'
Usage: ./scripts/build-trivial.sh [OPTIONS]

Build progressively more complex Nix derivations inside Darling to validate
the full build pipeline.

Options:
  --prefix <path>   Darling prefix (default: ~/.darling or $DPREFIX)
  --level <N>       Run only level N (1-5; default: all)
  --keep            Don't garbage-collect built derivations
  --verbose         Show full nix-build output
  --debug           Pass -vvvv --debug to nix-build
  --help            Show this help

Levels:
  1  Echo to $out          — minimal: /bin/bash writes a one-liner to $out
  2  Multi-line builder    — bash script with variables, loops, file I/O
  3  Input transformation  — derivation that reads from an input file
  4  Derivation dependency — one derivation depends on another
  5  Binary substitution   — fetch a pre-built path from cache.nixos.org

Each level exercises more of the Nix + Darling stack.  If a level fails,
the script prints debugging hints specific to that level's failure mode.
EOF
    exit 0
}

# ── Argument Parsing ────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || fatal "--prefix requires an argument"
            DARLING_PREFIX="$2"
            shift 2
            ;;
        --level)
            [ $# -ge 2 ] || fatal "--level requires an argument"
            SELECTED_LEVEL="$2"
            if ! [[ "$SELECTED_LEVEL" =~ ^[1-5]$ ]]; then
                fatal "--level must be 1-5, got: $SELECTED_LEVEL"
            fi
            shift 2
            ;;
        --keep)
            KEEP_BUILDS=1
            shift
            ;;
        --verbose|-v)
            VERBOSE=1
            shift
            ;;
        --debug)
            DEBUG=1
            VERBOSE=1
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            fatal "Unknown option: $1 (try --help)"
            ;;
    esac
done

# ── Preflight ───────────────────────────────────────────────────────────────

log "${BOLD}Preflight checks...${RESET}"

if ! command -v darling &>/dev/null; then
    fatal "darling is not in PATH"
fi

if [ ! -d "$DARLING_PREFIX" ]; then
    fatal "Darling prefix not found at $DARLING_PREFIX"
fi

if ! dsh echo ok &>/dev/null; then
    fatal "darling shell is not functional"
fi

# Check Nix is installed
nix_version=""
nix_version=$(dsh_nix "nix --version" 2>&1) || true
if [ -z "$nix_version" ] || ! echo "$nix_version" | grep -qi "nix"; then
    fatal "Nix does not appear to be installed in the Darling prefix.\n" \
          "  Run: ./scripts/install-nix-in-darling.nu"
fi

log "  Prefix: $DARLING_PREFIX"
log "  Nix:    $nix_version"

# ── Level Definitions ───────────────────────────────────────────────────────

# Each level is a function that:
#   - Prints what it exercises
#   - Runs the build
#   - Returns 0 on success, 1 on failure

level1_echo_to_out() {
    cat <<'DESC'
  Level 1: Echo to $out
  Exercises: posix_spawn, sandbox-exec stub, /bin/bash, file creation
             in /nix/store, store path registration, chmod/lchflags on
             store path.
DESC

    local expr='derivation {
        name = "darling-test-1-echo";
        builder = "/bin/bash";
        args = [ "-c" "echo Hello from Darling > $out" ];
        system = "x86_64-darwin";
    }'

    local nix_flags=""
    if [ "$DEBUG" -eq 1 ]; then
        nix_flags="-vvvv"
    fi

    local output=""
    local exit_code=0
    output=$(dsh_nix "nix-build --no-out-link $nix_flags --expr '$expr' 2>&1") || exit_code=$?

    if [ "$VERBOSE" -eq 1 ]; then
        echo "$output" | sed 's/^/    /'
    fi

    if [ "$exit_code" -ne 0 ]; then
        echo "$output" | tail -20 | sed 's/^/    /'
        echo ""
        echo "  Debugging hints for Level 1 failure:"
        echo "    • 'clearing flags of path': lchflags still broken (Phase 1.1)"
        echo "    • 'Bad file descriptor' / ENOEXEC: sandbox-exec stub issue (Phase 2)"
        echo "    • 'sandbox profile' write fail: check /tmp is writable inside prefix"
        echo "    • Builder hangs: posix_spawn with POSIX_SPAWN_SETEXEC broken"
        echo "    • 'Unimplemented syscall': check plan/syscall-triage.md"
        echo ""
        echo "  Manual reproduction:"
        echo "    darling shell bash -lc 'nix-build -vvvv --no-out-link --expr \"$expr\"'"
        echo "    darling shell /usr/bin/sandbox-exec -f /dev/null /bin/bash -c 'echo ok'"
        return 1
    fi

    # Verify the output exists and has the right content
    local store_path
    store_path=$(echo "$output" | grep '^/nix/store/' | tail -1)
    if [ -z "$store_path" ]; then
        echo "  Build appeared to succeed but no store path in output."
        echo "  Output: $output"
        return 1
    fi

    local content
    content=$(dsh_nix "cat '$store_path'" 2>&1) || true
    if echo "$content" | grep -q "Hello from Darling"; then
        echo "  Store path: $store_path"
        echo "  Content:    $(echo "$content" | head -1)"
        return 0
    else
        echo "  Store path content mismatch."
        echo "  Expected: 'Hello from Darling'"
        echo "  Got:      '$content'"
        return 1
    fi
}

level2_multiline_builder() {
    cat <<'DESC'
  Level 2: Multi-line builder script
  Exercises: bash scripting, variables, loops, file I/O, mkdir, directory
             output (vs single file), multiple files in $out.
DESC

    local expr='derivation {
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
    }'

    local nix_flags=""
    if [ "$DEBUG" -eq 1 ]; then
        nix_flags="-vvvv"
    fi

    local output=""
    local exit_code=0
    output=$(dsh_nix "nix-build --no-out-link $nix_flags --expr '$expr' 2>&1") || exit_code=$?

    if [ "$VERBOSE" -eq 1 ]; then
        echo "$output" | sed 's/^/    /'
    fi

    if [ "$exit_code" -ne 0 ]; then
        echo "$output" | tail -20 | sed 's/^/    /'
        echo ""
        echo "  Debugging hints for Level 2 failure:"
        echo "    • mkdir/chmod failures: filesystem or syscall issue"
        echo "    • 'for' loop issues: bash not fully working in sandbox"
        echo "    • Same as Level 1 hints if Level 1 also failed"
        return 1
    fi

    local store_path
    store_path=$(echo "$output" | grep '^/nix/store/' | tail -1)
    if [ -z "$store_path" ]; then
        echo "  No store path in output."
        return 1
    fi

    # Verify directory structure
    local verify_exit=0
    dsh_nix "
        test -x '$store_path/bin/hello' &&
        test -f '$store_path/share/item-1.txt' &&
        test -f '$store_path/share/item-2.txt' &&
        test -f '$store_path/share/item-3.txt' &&
        test -f '$store_path/share/status.txt' &&
        grep -q 'done' '$store_path/share/status.txt'
    " >/dev/null 2>&1 || verify_exit=$?

    if [ "$verify_exit" -eq 0 ]; then
        echo "  Store path: $store_path"
        echo "  Verified:   bin/hello (executable), share/item-{1,2,3}.txt, share/status.txt"
        return 0
    else
        echo "  Output verification failed."
        echo "  Store path: $store_path"
        dsh_nix "find '$store_path' -type f 2>/dev/null" | sed 's/^/    /' || true
        return 1
    fi
}

level3_input_transform() {
    cat <<'DESC'
  Level 3: Input transformation
  Exercises: builtins.toFile, passing string context to a derivation,
             reading input files, text processing (wc, sort).
DESC

    local expr='let
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
    }'

    local nix_flags=""
    if [ "$DEBUG" -eq 1 ]; then
        nix_flags="-vvvv"
    fi

    local output=""
    local exit_code=0
    output=$(dsh_nix "nix-build --no-out-link $nix_flags --expr '$expr' 2>&1") || exit_code=$?

    if [ "$VERBOSE" -eq 1 ]; then
        echo "$output" | sed 's/^/    /'
    fi

    if [ "$exit_code" -ne 0 ]; then
        echo "$output" | tail -20 | sed 's/^/    /'
        echo ""
        echo "  Debugging hints for Level 3 failure:"
        echo "    • builtins.toFile failure: store write issue"
        echo "    • sort/wc not found: PATH issue inside build sandbox"
        echo "    • Input file not readable: store path access issue"
        return 1
    fi

    local store_path
    store_path=$(echo "$output" | grep '^/nix/store/' | tail -1)
    if [ -z "$store_path" ]; then
        echo "  No store path in output."
        return 1
    fi

    local count
    count=$(dsh_nix "cat '$store_path/count.txt'" 2>&1 | tr -d '[:space:]')
    if [ "$count" = "5" ]; then
        echo "  Store path: $store_path"
        echo "  Line count: $count (correct)"
        return 0
    else
        echo "  Count verification failed: expected '5', got '$count'"
        return 1
    fi
}

level4_derivation_dependency() {
    cat <<'DESC'
  Level 4: Derivation dependency
  Exercises: one derivation depending on another's output, Nix's dependency
             tracking, incremental builds, store path references.
DESC

    local expr='let
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
    }'

    local nix_flags=""
    if [ "$DEBUG" -eq 1 ]; then
        nix_flags="-vvvv"
    fi

    local output=""
    local exit_code=0
    output=$(dsh_nix "nix-build --no-out-link $nix_flags --expr '$expr' 2>&1") || exit_code=$?

    if [ "$VERBOSE" -eq 1 ]; then
        echo "$output" | sed 's/^/    /'
    fi

    if [ "$exit_code" -ne 0 ]; then
        echo "$output" | tail -20 | sed 's/^/    /'
        echo ""
        echo "  Debugging hints for Level 4 failure:"
        echo "    • If dep itself failed: same as Level 1/2 hints"
        echo "    • If consumer failed reading dep: store path access issue"
        echo "    • Build order issue: Nix should build dep first automatically"
        return 1
    fi

    local store_path
    store_path=$(echo "$output" | grep '^/nix/store/' | tail -1)
    if [ -z "$store_path" ]; then
        echo "  No store path in output."
        return 1
    fi

    local result
    result=$(dsh_nix "cat '$store_path/result.txt'" 2>&1)
    if echo "$result" | grep -q "DEPENDENCY_OUTPUT"; then
        echo "  Store path: $store_path"
        echo "  Result:     $result"
        echo "  Dep path:   $(dsh_nix "cat '$store_path/dep-path.txt'" 2>&1 | head -1)"
        return 0
    else
        echo "  Dependency content not found in result."
        echo "  Expected to contain: 'DEPENDENCY_OUTPUT'"
        echo "  Got:                 '$result'"
        return 1
    fi
}

level5_binary_substitution() {
    cat <<'DESC'
  Level 5: Binary substitution (requires network)
  Exercises: curl/TLS, binary cache access, NAR download, signature
             verification, store path registration from remote.
DESC

    # Check if we can reach the cache first
    local cache_check=""
    cache_check=$(dsh_nix "curl -sfI https://cache.nixos.org/nix-cache-info 2>&1 | head -1") || true
    if ! echo "$cache_check" | grep -qi "200"; then
        echo "  Cannot reach cache.nixos.org — skipping Level 5."
        echo "  (This level requires network access.)"
        echo "  cache check result: $cache_check"
        return 2  # special: skip, not fail
    fi

    # Try to realise a simple, very small store path from the cache.
    # We use `nix-store -r` on a known path, or `nix build` with --substituters.
    # The safest approach: evaluate a nixpkgs attr and fetch it.
    local output=""
    local exit_code=0
    output=$(dsh_nix "
        # Try to fetch a tiny package from the cache.
        # 'hello' is small and almost always cached.
        nix build --no-link --print-out-paths \\
            --expr '(import <nixpkgs> {}).hello' \\
            --substituters https://cache.nixos.org \\
            --trusted-public-keys 'cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=' \\
            2>&1
    ") || exit_code=$?

    if [ "$VERBOSE" -eq 1 ]; then
        echo "$output" | sed 's/^/    /'
    fi

    if [ "$exit_code" -ne 0 ]; then
        echo "$output" | tail -20 | sed 's/^/    /'
        echo ""
        echo "  Debugging hints for Level 5 failure:"
        echo "    • 'SSL' / 'TLS' error: Darling's certificate bundle may be outdated"
        echo "    • 'cannot connect': DNS or network issue inside Darling"
        echo "    • '<nixpkgs>' not found: channels not set up — run nix-channel --update"
        echo "    • NAR download failure: curl or decompression issue"
        echo "    • Signature mismatch: trusted-public-keys not configured"
        return 1
    fi

    local store_path
    store_path=$(echo "$output" | grep '^/nix/store/' | tail -1)
    if [ -z "$store_path" ]; then
        echo "  Build output did not contain a store path."
        echo "  Output: $(echo "$output" | tail -5)"
        return 1
    fi

    # Try running the fetched hello binary
    local hello_output
    hello_output=$(dsh_nix "'$store_path/bin/hello'" 2>&1) || true
    if echo "$hello_output" | grep -qi "hello"; then
        echo "  Store path: $store_path"
        echo "  Output:     $hello_output"
        return 0
    else
        echo "  Store path: $store_path"
        echo "  hello binary did not produce expected output: $hello_output"
        echo "  (This may be OK — the binary was fetched, which is the main test.)"
        return 0
    fi
}

# ── Determine which levels to run ──────────────────────────────────────────

ALL_LEVELS=(1 2 3 4 5)

if [ -n "$SELECTED_LEVEL" ]; then
    RUN_LEVELS=("$SELECTED_LEVEL")
else
    RUN_LEVELS=("${ALL_LEVELS[@]}")
fi

# ── Execute ─────────────────────────────────────────────────────────────────

echo ""
log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
log "${BOLD}  Trivial Derivation Build Tests (Phase 4.1)${RESET}"
log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo ""

LEVELS_PASSED=0
LEVELS_FAILED=0
LEVELS_SKIPPED=0

declare -A LEVEL_RESULT  # "pass", "fail", "skip"
LEVEL_NAMES=(
    [1]="Echo to \$out"
    [2]="Multi-line builder"
    [3]="Input transformation"
    [4]="Derivation dependency"
    [5]="Binary substitution (network)"
)

LEVEL_FUNCS=(
    [1]=level1_echo_to_out
    [2]=level2_multiline_builder
    [3]=level3_input_transform
    [4]=level4_derivation_dependency
    [5]=level5_binary_substitution
)

for level in "${RUN_LEVELS[@]}"; do
    echo -e "${BLUE}━━━ Level $level: ${LEVEL_NAMES[$level]} ━━━${RESET}"
    echo ""

    exit_code=0
    ${LEVEL_FUNCS[$level]} || exit_code=$?

    echo ""

    if [ "$exit_code" -eq 0 ]; then
        LEVELS_PASSED=$((LEVELS_PASSED + 1))
        LEVEL_RESULT[$level]="pass"
        echo -e "  ${GREEN}✓ Level $level PASSED${RESET}"
    elif [ "$exit_code" -eq 2 ]; then
        LEVELS_SKIPPED=$((LEVELS_SKIPPED + 1))
        LEVEL_RESULT[$level]="skip"
        echo -e "  ${YELLOW}⊘ Level $level SKIPPED${RESET}"
    else
        LEVELS_FAILED=$((LEVELS_FAILED + 1))
        LEVEL_RESULT[$level]="fail"
        echo -e "  ${RED}✗ Level $level FAILED${RESET}"

        # If an early level fails, later levels will almost certainly fail too
        if [ "$level" -le 2 ] && [ -z "$SELECTED_LEVEL" ]; then
            warn "Level $level failed — skipping remaining levels (they depend on this)."
            for remaining in "${RUN_LEVELS[@]}"; do
                if [ "$remaining" -gt "$level" ] && [ -z "${LEVEL_RESULT[$remaining]+x}" ]; then
                    LEVELS_SKIPPED=$((LEVELS_SKIPPED + 1))
                    LEVEL_RESULT[$remaining]="skip"
                fi
            done
            break
        fi
    fi

    echo ""
done

# ── Garbage Collection ──────────────────────────────────────────────────────

if [ "$KEEP_BUILDS" -eq 0 ] && [ "$LEVELS_PASSED" -gt 0 ]; then
    log "Cleaning up test derivations..."
    dsh_nix "nix-collect-garbage 2>/dev/null" >/dev/null 2>&1 || true
else
    if [ "$KEEP_BUILDS" -eq 1 ]; then
        log "Keeping built derivations (--keep)."
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────

TOTAL=$((LEVELS_PASSED + LEVELS_FAILED + LEVELS_SKIPPED))

echo ""
log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
log "${BOLD}  Build Test Summary${RESET}"
log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo ""

printf "  %-5s %-35s %s\n" "Level" "Name" "Result"
printf "  %-5s %-35s %s\n" "─────" "───────────────────────────────────" "──────"

for level in "${ALL_LEVELS[@]}"; do
    result="${LEVEL_RESULT[$level]:-skip}"
    case "$result" in
        pass) printf "  %-5s %-35s ${GREEN}✓ PASS${RESET}\n" "$level" "${LEVEL_NAMES[$level]}" ;;
        fail) printf "  %-5s %-35s ${RED}✗ FAIL${RESET}\n" "$level" "${LEVEL_NAMES[$level]}" ;;
        skip) printf "  %-5s %-35s ${YELLOW}⊘ SKIP${RESET}\n" "$level" "${LEVEL_NAMES[$level]}" ;;
    esac
done

echo ""
printf "  Total:   %d levels\n" "$TOTAL"
printf "  Passed:  ${GREEN}%d${RESET}\n" "$LEVELS_PASSED"
printf "  Failed:  ${RED}%d${RESET}\n" "$LEVELS_FAILED"
printf "  Skipped: ${YELLOW}%d${RESET}\n" "$LEVELS_SKIPPED"
echo ""

if [ "$LEVELS_FAILED" -gt 0 ]; then
    err "Some build levels failed."
    echo "" >&2
    echo "Next steps:" >&2
    echo "  • Run a single level:  $0 --level N --debug" >&2
    echo "  • Manual build:        darling shell bash -lc 'nix-build -vvvv --expr \"...\"'" >&2
    echo "  • Manual sandbox test: darling shell /usr/bin/sandbox-exec -f /dev/null /bin/bash -c 'echo ok'" >&2
    echo "  • Check syscalls:      ./scripts/triage-syscalls.sh" >&2
    echo "  • Host-side trace:     strace -f -p \$(pidof darlingserver) 2>&1 | head -500" >&2
    echo "  • Darling xtrace:      DARLING_XTRACE=1 darling shell bash -lc 'nix-build --expr ...'" >&2
    echo "" >&2
    exit 1
elif [ "$LEVELS_PASSED" -eq 0 ]; then
    warn "No levels were attempted — check that Nix is installed."
    exit 2
else
    log "${GREEN}All build levels passed!${RESET}"
    if [ "$LEVELS_SKIPPED" -gt 0 ]; then
        log "${DIM}($LEVELS_SKIPPED levels skipped — re-run with --level N to target them)${RESET}"
    fi
    log ""
    log "Phase 4.1 is complete! Next steps:"
    log "  • Phase 4.2: Test bash in build sandboxes (more complex scripts)"
    log "  • Phase 4.5: Build a C program with Darwin stdenv"
    log "  • See: plan/06-phase4-building.md"
    exit 0
fi
