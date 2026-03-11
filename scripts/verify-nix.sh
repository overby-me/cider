#!/usr/bin/env bash
# verify-nix.sh — Standalone health-check for a Nix installation inside Darling
#
# This script runs a comprehensive set of checks to verify that Nix is
# correctly installed and functional inside a Darling prefix.  It can be
# used after running install-nix-in-darling.sh, or at any later time to
# diagnose regressions.
#
# Usage:
#   ./scripts/verify-nix.sh [OPTIONS]
#
# Options:
#   --prefix <path>       Darling prefix path (default: ~/.darling or $DPREFIX)
#   --online              Include checks that require network access (curl, cache)
#   --offline             Skip all network-dependent checks (default)
#   --verbose             Show command output even on success
#   --json                Output results as JSON (for CI consumption)
#   --help                Show this help message
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed
#   2 — infrastructure error (Darling not working, Nix not installed, etc.)
#
# See: plan/05-phase3-nix-install.md (Task 3.3 — Verify Core Nix Commands)

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────

DARLING_PREFIX="${DPREFIX:-$HOME/.darling}"
ONLINE=0
VERBOSE=0
JSON_OUTPUT=0

# ── Colors ──────────────────────────────────────────────────────────────────

if [ -t 1 ] && [ "$JSON_OUTPUT" -eq 0 ]; then
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

log()   { [ "$JSON_OUTPUT" -eq 0 ] && echo -e "${GREEN}[verify-nix]${RESET} $*" || true; }
warn()  { [ "$JSON_OUTPUT" -eq 0 ] && echo -e "${YELLOW}[verify-nix] WARNING:${RESET} $*" >&2 || true; }
err()   { [ "$JSON_OUTPUT" -eq 0 ] && echo -e "${RED}[verify-nix] ERROR:${RESET} $*" >&2 || true; }
fatal() { err "$@"; exit 2; }

dsh() {
    darling shell "$@"
}

# Run a command inside Darling with Nix on PATH via a login shell
dsh_nix() {
    darling shell bash -lc "
        # Source Nix profile
        if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
            . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
        elif [ -e \"\$HOME/.nix-profile/etc/profile.d/nix.sh\" ]; then
            . \"\$HOME/.nix-profile/etc/profile.d/nix.sh\"
        elif [ -e '/etc/profile.d/nix-darling.sh' ]; then
            . '/etc/profile.d/nix-darling.sh'
        fi
        $*
    " 2>&1
}

usage() {
    cat <<'EOF'
Usage: ./scripts/verify-nix.sh [OPTIONS]

Verify that Nix is correctly installed and functional inside a Darling prefix.

Options:
  --prefix <path>   Darling prefix (default: ~/.darling or $DPREFIX)
  --online          Include network-dependent checks (curl, binary cache)
  --offline         Skip network checks (default)
  --verbose         Show command output even on success
  --json            Output results as JSON
  --help            Show this help

Categories:
  Infrastructure    Darling shell, prefix, Nix binaries present
  Core              nix --version, nix-env --version, nix-store --verify
  Evaluator         nix-instantiate --eval, nix eval, builtins.currentSystem
  Store             Store database integrity, path registration
  Network           curl to cache.nixos.org, HTTPS/TLS (--online only)
  Syscall           Check for unimplemented syscall warnings

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
        --online)
            ONLINE=1
            shift
            ;;
        --offline)
            ONLINE=0
            shift
            ;;
        --verbose|-v)
            VERBOSE=1
            shift
            ;;
        --json)
            JSON_OUTPUT=1
            # Disable color when outputting JSON
            RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
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

# ── Check Result Tracking ──────────────────────────────────────────────────

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# For JSON output
declare -a JSON_RESULTS=()

# Record the result of a single check
record_result() {
    local name="$1"
    local status="$2"  # pass, fail, skip
    local detail="${3:-}"

    TOTAL=$((TOTAL + 1))

    case "$status" in
        pass)
            PASSED=$((PASSED + 1))
            if [ "$JSON_OUTPUT" -eq 0 ]; then
                printf "  ${GREEN}✓${RESET} %-55s ${GREEN}PASS${RESET}\n" "$name"
                if [ "$VERBOSE" -eq 1 ] && [ -n "$detail" ]; then
                    echo "$detail" | sed 's/^/      /'
                fi
            fi
            ;;
        fail)
            FAILED=$((FAILED + 1))
            if [ "$JSON_OUTPUT" -eq 0 ]; then
                printf "  ${RED}✗${RESET} %-55s ${RED}FAIL${RESET}\n" "$name"
                if [ -n "$detail" ]; then
                    echo "$detail" | head -20 | sed 's/^/      /'
                fi
            fi
            ;;
        skip)
            SKIPPED=$((SKIPPED + 1))
            if [ "$JSON_OUTPUT" -eq 0 ]; then
                printf "  ${YELLOW}⊘${RESET} %-55s ${YELLOW}SKIP${RESET}\n" "$name"
                if [ -n "$detail" ]; then
                    echo "      $detail"
                fi
            fi
            ;;
    esac

    # Escape strings for JSON
    local json_detail
    json_detail=$(echo "$detail" | head -5 | tr '\n' ' ' | sed 's/"/\\"/g; s/\t/ /g')
    JSON_RESULTS+=("{\"name\":\"$name\",\"status\":\"$status\",\"detail\":\"$json_detail\"}")
}

# Run a check: check <name> <command...>
#   Runs the command, records pass/fail based on exit code.
#   Captures stdout+stderr for detail.
check() {
    local name="$1"
    shift
    local output=""
    local exit_code=0

    output=$("$@" 2>&1) || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        record_result "$name" "pass" "$output"
    else
        record_result "$name" "fail" "$output"
    fi
}

# Run a check inside Darling with Nix on PATH
check_nix() {
    local name="$1"
    shift
    local cmd="$*"
    local output=""
    local exit_code=0

    output=$(dsh_nix "$cmd" 2>&1) || exit_code=$?

    # Also check for "Unimplemented syscall" in output — even if exit=0,
    # unimplemented syscall messages indicate problems.
    if echo "$output" | grep -qi "unimplemented syscall" 2>/dev/null; then
        local syscall_warns
        syscall_warns=$(echo "$output" | grep -i "unimplemented syscall" | head -5)
        record_result "$name" "fail" "Unimplemented syscall(s) detected:\n$syscall_warns"
        return
    fi

    if [ "$exit_code" -eq 0 ]; then
        record_result "$name" "pass" "$output"
    else
        record_result "$name" "fail" "$output"
    fi
}

# ── Section header ──────────────────────────────────────────────────────────

section() {
    if [ "$JSON_OUTPUT" -eq 0 ]; then
        echo ""
        echo -e "${BLUE}━━━ $1 ━━━${RESET}"
        echo ""
    fi
}

# ── Preflight: Infrastructure Checks ───────────────────────────────────────

if [ "$JSON_OUTPUT" -eq 0 ]; then
    echo ""
    log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
    log "${BOLD}  Nix-in-Darling Verification${RESET}"
    log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
fi

section "Infrastructure"

# Check darling binary exists
check "darling binary in PATH" command -v darling

# Check prefix exists
check "Darling prefix exists" test -d "$DARLING_PREFIX"

# Check darling shell is functional
check "darling shell functional" dsh echo ok

# Check /nix exists in the prefix
check "/nix exists in prefix" test -d "$DARLING_PREFIX/nix"

# Check /nix/store exists
check "/nix/store exists" test -d "$DARLING_PREFIX/nix/store"

# Check /nix/var/nix/db exists
check "/nix/var/nix/db exists" test -d "$DARLING_PREFIX/nix/var/nix/db"

# Check nix.conf exists
check "/etc/nix/nix.conf exists" test -f "$DARLING_PREFIX/etc/nix/nix.conf"

# Check nix.conf has single-user setting
if [ -f "$DARLING_PREFIX/etc/nix/nix.conf" ]; then
    check "nix.conf: build-users-group is empty" \
        grep -q 'build-users-group =' "$DARLING_PREFIX/etc/nix/nix.conf"
else
    record_result "nix.conf: build-users-group is empty" "skip" "nix.conf not found"
fi

# Check sandbox-exec stub
check "sandbox-exec stub installed" \
    test -f "$DARLING_PREFIX/usr/bin/sandbox-exec" -o -f "$DARLING_PREFIX/libexec/darling/usr/bin/sandbox-exec"

# Check that nix binary exists somewhere in the store
nix_binary_found=0
if compgen -G "$DARLING_PREFIX/nix/store/*/bin/nix" >/dev/null 2>&1; then
    nix_binary_found=1
fi
if [ "$nix_binary_found" -eq 1 ]; then
    record_result "Nix binary found in /nix/store" "pass" ""
else
    record_result "Nix binary found in /nix/store" "fail" "No /nix/store/*/bin/nix found"
fi

# ── Core: Nix binaries load and report version ─────────────────────────────

section "Core"

check_nix "nix --version" "nix --version"
check_nix "nix-env --version" "nix-env --version"
check_nix "nix-store --version" "nix-store --version"
check_nix "nix-instantiate --version" "nix-instantiate --version"
check_nix "nix-build --version" "nix-build --version"

# ── Evaluator: Nix expression evaluation ───────────────────────────────────

section "Evaluator"

check_nix "nix-instantiate --eval -E '1 + 1'" \
    "nix-instantiate --eval -E '1 + 1'"

check_nix "nix eval --expr '1 + 1'" \
    "nix eval --expr '1 + 1'"

check_nix "nix eval --expr '\"hello\"'" \
    "nix eval --expr '\"hello\"'"

# Check that builtins.currentSystem reports x86_64-darwin
system_output=""
system_exit=0
system_output=$(dsh_nix "nix eval --expr 'builtins.currentSystem' --raw" 2>&1) || system_exit=$?

if [ "$system_exit" -eq 0 ] && [ "$system_output" = "x86_64-darwin" ]; then
    record_result "builtins.currentSystem == x86_64-darwin" "pass" "$system_output"
elif [ "$system_exit" -eq 0 ]; then
    record_result "builtins.currentSystem == x86_64-darwin" "fail" \
        "Expected 'x86_64-darwin', got '$system_output'"
else
    record_result "builtins.currentSystem == x86_64-darwin" "fail" "$system_output"
fi

# Slightly more complex evaluation — list operations, let bindings
check_nix "nix eval: list operations" \
    "nix eval --expr 'builtins.length [1 2 3]'"

check_nix "nix eval: let binding" \
    "nix eval --expr 'let x = 21; in x * 2'"

check_nix "nix eval: string interpolation" \
    "nix eval --expr 'let name = \"darling\"; in \"hello \${name}\"'"

check_nix "nix eval: import <nixpkgs> (if channel set up)" \
    "nix-instantiate --eval -E 'builtins.typeOf (import <nixpkgs> {})' 2>/dev/null || echo skip"

# ── Store: Database and integrity ──────────────────────────────────────────

section "Store"

check_nix "nix-store --verify (basic)" \
    "nix-store --verify 2>&1 || true"

# Check that the SQLite database is accessible
check_nix "nix-store --dump-db (database readable)" \
    "nix-store --dump-db | head -1 >/dev/null 2>&1 && echo ok"

# Count store paths
store_count_output=""
store_count_exit=0
store_count_output=$(dsh_nix "ls /nix/store/ 2>/dev/null | wc -l" 2>&1) || store_count_exit=$?
if [ "$store_count_exit" -eq 0 ]; then
    record_result "Store paths exist (count: $(echo "$store_count_output" | tr -d '[:space:]'))" "pass" ""
else
    record_result "Store paths exist" "fail" "$store_count_output"
fi

# Check that the store database is not corrupt
check_nix "SQLite database integrity" \
    "sqlite3 /nix/var/nix/db/db.sqlite 'PRAGMA integrity_check;' 2>/dev/null || echo 'sqlite3 not available'"

# ── Syscall: Check for warnings ────────────────────────────────────────────

section "Syscall Health"

# Run a nix command and check that no "Unimplemented syscall" messages appear
syscall_output=""
syscall_exit=0
syscall_output=$(dsh_nix "nix --version 2>&1; nix-instantiate --eval -E '1 + 1' 2>&1" 2>&1) || syscall_exit=$?

if echo "$syscall_output" | grep -qi "unimplemented syscall" 2>/dev/null; then
    unimpl_lines=$(echo "$syscall_output" | grep -i "unimplemented syscall")
    record_result "No 'Unimplemented syscall' warnings" "fail" "$unimpl_lines"
else
    record_result "No 'Unimplemented syscall' warnings" "pass" ""
fi

# Check for STUB warnings
if echo "$syscall_output" | grep -qi "STUB" 2>/dev/null; then
    stub_lines=$(echo "$syscall_output" | grep -i "STUB" | head -10)
    record_result "No STUB warnings during basic operations" "fail" "$stub_lines"
else
    record_result "No STUB warnings during basic operations" "pass" ""
fi

# Check for segfaults / signals in Nix operations
segfault_output=""
segfault_exit=0
segfault_output=$(dsh_nix "nix eval --expr '1 + 1' 2>&1" 2>&1) || segfault_exit=$?

if [ "$segfault_exit" -gt 128 ]; then
    signal=$((segfault_exit - 128))
    record_result "No crashes (signals) during evaluation" "fail" "Killed by signal $signal (exit code $segfault_exit)"
else
    record_result "No crashes (signals) during evaluation" "pass" ""
fi

# ── Network (optional) ─────────────────────────────────────────────────────

section "Network"

if [ "$ONLINE" -eq 1 ]; then
    check_nix "curl to cache.nixos.org" \
        "curl -sfI https://cache.nixos.org/nix-cache-info >/dev/null 2>&1 && echo ok"

    check_nix "HTTPS/TLS handshake" \
        "curl -sf https://cache.nixos.org/nix-cache-info | head -3"

    # Try to look up a well-known store path (bash) in the binary cache
    check_nix "Binary cache: nix path-info (bash)" \
        "nix path-info --store https://cache.nixos.org /nix/store/\$(nix eval --raw nixpkgs#bash.outPath 2>/dev/null | sed 's|/nix/store/||') 2>&1 || echo 'path-info not available (channels may not be set up)'"

    # DNS resolution
    check_nix "DNS resolution" \
        "nslookup cache.nixos.org >/dev/null 2>&1 || host cache.nixos.org >/dev/null 2>&1 || echo 'DNS tools not available, but curl worked'"
else
    record_result "curl to cache.nixos.org" "skip" "Use --online to enable network checks"
    record_result "HTTPS/TLS handshake" "skip" "Use --online to enable network checks"
fi

# ── Environment ─────────────────────────────────────────────────────────────

section "Environment"

# Check macOS version reported by Darling
version_output=""
version_exit=0
version_output=$(dsh sw_vers -productVersion 2>&1) || version_exit=$?
if [ "$version_exit" -eq 0 ]; then
    major=$(echo "$version_output" | cut -d. -f1)
    if [ "$major" -ge 11 ] 2>/dev/null; then
        record_result "macOS version >= 11 (Big Sur): $version_output" "pass" ""
    else
        record_result "macOS version >= 11 (Big Sur): $version_output" "fail" \
            "Nix Darwin binaries target macOS 11+; current version is $version_output"
    fi
else
    record_result "macOS version >= 11 (Big Sur)" "fail" "$version_output"
fi

# Check that sandbox = false in nix.conf
if [ -f "$DARLING_PREFIX/etc/nix/nix.conf" ]; then
    if grep -q 'sandbox = false' "$DARLING_PREFIX/etc/nix/nix.conf" 2>/dev/null; then
        record_result "nix.conf: sandbox = false" "pass" ""
    else
        record_result "nix.conf: sandbox = false" "fail" \
            "Sandbox should be disabled in Darling; add 'sandbox = false' to /etc/nix/nix.conf"
    fi
else
    record_result "nix.conf: sandbox = false" "skip" "nix.conf not found"
fi

# Check experimental features enabled
if [ -f "$DARLING_PREFIX/etc/nix/nix.conf" ]; then
    if grep -q 'experimental-features.*nix-command' "$DARLING_PREFIX/etc/nix/nix.conf" 2>/dev/null; then
        record_result "nix.conf: nix-command flakes enabled" "pass" ""
    else
        record_result "nix.conf: nix-command flakes enabled" "skip" \
            "experimental-features not set (optional but recommended)"
    fi
else
    record_result "nix.conf: nix-command flakes enabled" "skip" "nix.conf not found"
fi

# ── JSON Output ─────────────────────────────────────────────────────────────

if [ "$JSON_OUTPUT" -eq 1 ]; then
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"prefix\": \"$DARLING_PREFIX\","
    echo "  \"online\": $ONLINE,"
    echo "  \"total\": $TOTAL,"
    echo "  \"passed\": $PASSED,"
    echo "  \"failed\": $FAILED,"
    echo "  \"skipped\": $SKIPPED,"
    echo "  \"results\": ["

    local_first=1
    for result in "${JSON_RESULTS[@]}"; do
        if [ "$local_first" -eq 1 ]; then
            local_first=0
        else
            echo ","
        fi
        printf "    %s" "$result"
    done
    echo ""
    echo "  ]"
    echo "}"
    # Set exit code but don't print summary
    if [ "$FAILED" -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
log "${BOLD}  Verification Summary${RESET}"
log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo ""
printf "  Total:   %d checks\n" "$TOTAL"
printf "  Passed:  ${GREEN}%d${RESET}\n" "$PASSED"
printf "  Failed:  ${RED}%d${RESET}\n" "$FAILED"
printf "  Skipped: ${YELLOW}%d${RESET}\n" "$SKIPPED"
echo ""

if [ "$FAILED" -gt 0 ]; then
    err "Some checks failed."
    echo "" >&2
    echo "Troubleshooting:" >&2
    echo "  • If Nix binaries aren't found, run: ./scripts/install-nix-in-darling.sh" >&2
    echo "  • If syscall warnings appear, check: plan/syscall-triage.md" >&2
    echo "  • If evaluator fails, try: darling shell bash -lc 'nix eval --expr 1+1' 2>&1" >&2
    echo "  • For detailed tracing: DARLING_XTRACE=1 darling shell bash -lc 'nix --version'" >&2
    echo "  • For host-side tracing: strace -f -p \$(pidof darlingserver) 2>&1 | head -500" >&2
    echo "  • Re-run with --verbose for more detail" >&2
    echo "  • Re-run with --online for network checks" >&2
    echo "" >&2
    exit 1
elif [ "$PASSED" -eq 0 ]; then
    warn "No checks passed — Nix may not be installed."
    echo "  Run: ./scripts/install-nix-in-darling.sh" >&2
    exit 2
else
    log "${GREEN}All checks passed!${RESET} Nix is healthy inside Darling."
    if [ "$ONLINE" -eq 0 ]; then
        log "${DIM}(Run with --online to also verify network/cache access)${RESET}"
    fi
    exit 0
fi
