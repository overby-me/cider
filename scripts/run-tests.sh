#!/usr/bin/env bash
# run-tests.sh — Compile and run all regression tests inside a Darling prefix
#
# This script copies the test source files into the Darling prefix, compiles
# them using Darling's macOS toolchain (cc), and executes them.  It collects
# results from all test suites and produces a summary.
#
# Usage:
#   ./scripts/run-tests.sh [OPTIONS]
#
# Options:
#   --prefix <path>       Darling prefix path (default: ~/.darling or $DPREFIX)
#   --suite <name>        Run only the named suite (can be repeated)
#                         Available: renameatx_np, setattrlist_flags, utimensat,
#                                    sandbox_api, sandbox_exec, dirserv,
#                                    identity, sw_vers
#   --keep                Keep compiled test binaries in the prefix after running
#   --verbose             Show full test output even on success
#   --help                Show this help message
#
# Prerequisites:
#   - Darling must be installed and `darling shell echo ok` must work
#   - The Darling prefix must be initialized
#
# Exit code:
#   0 — all tests passed
#   1 — one or more tests failed
#   2 — infrastructure error (Darling not working, compilation failure, etc.)
#
# See: plan/PLAN.md "What's Next" item 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────

DARLING_PREFIX="${DPREFIX:-$HOME/.darling}"
KEEP_BINARIES=0
VERBOSE=0
SELECTED_SUITES=()

# Test directory inside the Darling prefix
DARLING_TEST_DIR="/tmp/darling-nix-tests"

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

log()   { echo -e "${GREEN}[run-tests]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[run-tests] WARNING:${RESET} $*" >&2; }
err()   { echo -e "${RED}[run-tests] ERROR:${RESET} $*" >&2; }
fatal() { err "$@"; exit 2; }

dsh() {
    darling shell "$@"
}

usage() {
    cat <<'EOF'
Usage: ./scripts/run-tests.sh [OPTIONS]

Compile and run all Darling regression tests.

Options:
  --prefix <path>   Darling prefix (default: ~/.darling or $DPREFIX)
  --suite <name>    Run only the named suite (repeatable)
                    Available: renameatx_np, setattrlist_flags, utimensat,
                               sandbox_api, sandbox_exec, dirserv,
                               identity, sw_vers
  --keep            Keep compiled binaries in the prefix after running
  --verbose         Show full test output even on success
  --help            Show this help

Suites:
  renameatx_np       — renameatx_np syscall 488 (5 tests)
  setattrlist_flags  — setattrlist/getattrlist ATTR_CMN_FLAGS (10 tests)
  utimensat          — utimensat/setattrlistat timestamps (16 tests)
  sandbox_api        — sandbox C API stubs
  sandbox_exec       — sandbox-exec integration (shell tests)
  dirserv            — Directory Services stubs (dseditgroup, sysadminctl, dscl)
  identity           — macOS 14 identity via uname / kern.* sysctls (Phase A)
  sw_vers            — sw_vers productVersion / buildVersion (Phase A)
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
        --suite)
            [ $# -ge 2 ] || fatal "--suite requires an argument"
            SELECTED_SUITES+=("$2")
            shift 2
            ;;
        --keep)
            KEEP_BINARIES=1
            shift
            ;;
        --verbose|-v)
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

# ── Suite Definitions ───────────────────────────────────────────────────────

# Each suite is defined as:
#   SUITE_<name>_TYPE     = "c" | "sh"
#   SUITE_<name>_SOURCE   = relative path from repo root
#   SUITE_<name>_DESC     = human description
#   SUITE_<name>_CFLAGS   = extra compiler flags (C suites only)

declare -A SUITE_TYPE SUITE_SOURCE SUITE_DESC SUITE_CFLAGS

SUITE_TYPE[renameatx_np]="c"
SUITE_SOURCE[renameatx_np]="tests/syscall/test_renameatx_np.c"
SUITE_DESC[renameatx_np]="renameatx_np (syscall 488) — plain rename, SWAP, EXCL, invalid flags"
SUITE_CFLAGS[renameatx_np]=""

SUITE_TYPE[setattrlist_flags]="c"
SUITE_SOURCE[setattrlist_flags]="tests/syscall/test_setattrlist_flags.c"
SUITE_DESC[setattrlist_flags]="setattrlist/getattrlist ATTR_CMN_FLAGS — lchflags, chflags, combined attrs"
SUITE_CFLAGS[setattrlist_flags]=""

SUITE_TYPE[utimensat]="c"
SUITE_SOURCE[utimensat]="tests/syscall/test_utimensat.c"
SUITE_DESC[utimensat]="utimensat/setattrlistat — timestamps, MODTIME, ACCTIME, CRTIME, symlinks"
SUITE_CFLAGS[utimensat]=""

SUITE_TYPE[sandbox_api]="c"
SUITE_SOURCE[sandbox_api]="tests/sandbox/test_sandbox_api.c"
SUITE_DESC[sandbox_api]="sandbox C API — sandbox_init, sandbox_free_error"
SUITE_CFLAGS[sandbox_api]=""

SUITE_TYPE[sandbox_exec]="sh"
SUITE_SOURCE[sandbox_exec]="tests/sandbox/test_sandbox_exec.sh"
SUITE_DESC[sandbox_exec]="sandbox-exec stub — flag parsing, exec, exit codes, Nix patterns"
SUITE_CFLAGS[sandbox_exec]=""

SUITE_TYPE[dirserv]="sh"
SUITE_SOURCE[dirserv]="tests/dirserv/test_dirserv.sh"
SUITE_DESC[dirserv]="Directory Services stubs — dseditgroup, sysadminctl, dscl (Phase 5.1)"
SUITE_CFLAGS[dirserv]=""

SUITE_TYPE[identity]="c"
SUITE_SOURCE[identity]="tests/identity/test_identity.c"
SUITE_DESC[identity]="macOS 14 identity — uname, kern.osrelease/osproductversion/osversion (Phase A)"
SUITE_CFLAGS[identity]=""

SUITE_TYPE[sw_vers]="sh"
SUITE_SOURCE[sw_vers]="tests/identity/test_sw_vers.sh"
SUITE_DESC[sw_vers]="sw_vers identity — productVersion/buildVersion report macOS 14 (Phase A)"
SUITE_CFLAGS[sw_vers]=""

ALL_SUITES=(renameatx_np setattrlist_flags utimensat sandbox_api sandbox_exec dirserv identity sw_vers)

# ── Determine which suites to run ──────────────────────────────────────────

if [ ${#SELECTED_SUITES[@]} -eq 0 ]; then
    RUN_SUITES=("${ALL_SUITES[@]}")
else
    RUN_SUITES=()
    for s in "${SELECTED_SUITES[@]}"; do
        if [ -z "${SUITE_TYPE[$s]+x}" ]; then
            fatal "Unknown suite: $s (available: ${ALL_SUITES[*]})"
        fi
        RUN_SUITES+=("$s")
    done
fi

# ── Preflight ───────────────────────────────────────────────────────────────

log "${BOLD}Preflight checks...${RESET}"

if ! command -v darling &>/dev/null; then
    fatal "darling is not installed or not in PATH"
fi

if [ ! -d "$DARLING_PREFIX" ]; then
    fatal "Darling prefix not found at $DARLING_PREFIX\n" \
          "  Initialize with: darling shell true"
fi

if ! dsh echo ok &>/dev/null; then
    fatal "darling shell is not functional\n" \
          "  Try: darling shell echo ok"
fi

log "  Prefix: $DARLING_PREFIX"
log "  Suites: ${RUN_SUITES[*]}"

# Verify source files exist
for suite in "${RUN_SUITES[@]}"; do
    src="$REPO_DIR/${SUITE_SOURCE[$suite]}"
    if [ ! -f "$src" ]; then
        fatal "Source file not found: ${SUITE_SOURCE[$suite]}\n" \
              "  Expected at: $src"
    fi
done

# ── Copy test sources into the prefix ───────────────────────────────────────

log "${BOLD}Copying test sources into Darling prefix...${RESET}"

PREFIX_TEST_DIR="$DARLING_PREFIX/private/tmp/darling-nix-tests"
mkdir -p "$PREFIX_TEST_DIR"

for suite in "${RUN_SUITES[@]}"; do
    src="$REPO_DIR/${SUITE_SOURCE[$suite]}"
    cp "$src" "$PREFIX_TEST_DIR/"
    log "  Copied ${SUITE_SOURCE[$suite]}"
done

# ── Compile C test suites ──────────────────────────────────────────────────

log "${BOLD}Compiling C test suites inside Darling...${RESET}"

COMPILE_FAILURES=0

for suite in "${RUN_SUITES[@]}"; do
    if [ "${SUITE_TYPE[$suite]}" != "c" ]; then
        continue
    fi

    src_basename="$(basename "${SUITE_SOURCE[$suite]}")"
    bin_name="${src_basename%.c}"

    log "  Compiling $src_basename ..."

    compile_output=$(dsh bash -c \
        "cd $DARLING_TEST_DIR && cc -Wall -Wextra -o '$bin_name' '$src_basename' ${SUITE_CFLAGS[$suite]} 2>&1" \
        2>&1) || {
        err "  Compilation of $src_basename FAILED:"
        echo "$compile_output" | sed 's/^/    /' >&2
        COMPILE_FAILURES=$((COMPILE_FAILURES + 1))
        continue
    }

    if [ "$VERBOSE" -eq 1 ] && [ -n "$compile_output" ]; then
        echo "$compile_output" | sed 's/^/    /'
    fi

    log "  ${GREEN}✓${RESET} $bin_name compiled"
done

if [ "$COMPILE_FAILURES" -gt 0 ]; then
    err "$COMPILE_FAILURES suite(s) failed to compile"
    if [ "$COMPILE_FAILURES" -eq "${#RUN_SUITES[@]}" ]; then
        fatal "All suites failed to compile — is the Darling toolchain working?"
    fi
fi

# ── Run test suites ─────────────────────────────────────────────────────────

echo ""
log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
log "${BOLD}  Running Darling regression tests${RESET}"
log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo ""

SUITES_PASSED=0
SUITES_FAILED=0
SUITES_SKIPPED=0

declare -A SUITE_RESULTS  # "pass", "fail", "skip"
declare -A SUITE_OUTPUT

for suite in "${RUN_SUITES[@]}"; do
    src_basename="$(basename "${SUITE_SOURCE[$suite]}")"
    echo -e "${BLUE}━━━ Suite: $suite ━━━${RESET}"
    echo -e "${DIM}${SUITE_DESC[$suite]}${RESET}"
    echo ""

    if [ "${SUITE_TYPE[$suite]}" = "c" ]; then
        bin_name="${src_basename%.c}"

        # Check the binary was compiled
        compile_check=$(dsh test -x "$DARLING_TEST_DIR/$bin_name" 2>&1 && echo "yes" || echo "no")
        if [ "$compile_check" != "yes" ]; then
            echo -e "  ${YELLOW}SKIPPED${RESET} — compilation failed"
            echo ""
            SUITES_SKIPPED=$((SUITES_SKIPPED + 1))
            SUITE_RESULTS[$suite]="skip"
            continue
        fi

        # Run the test binary
        output=""
        exit_code=0
        output=$(dsh bash -c "cd $DARLING_TEST_DIR && ./$bin_name 2>&1" 2>&1) || exit_code=$?

    elif [ "${SUITE_TYPE[$suite]}" = "sh" ]; then
        # Shell tests run directly
        output=""
        exit_code=0
        output=$(dsh bash -c "cd $DARLING_TEST_DIR && sh '$src_basename' 2>&1" 2>&1) || exit_code=$?
    fi

    SUITE_OUTPUT[$suite]="$output"

    if [ "$exit_code" -eq 0 ]; then
        SUITES_PASSED=$((SUITES_PASSED + 1))
        SUITE_RESULTS[$suite]="pass"
        if [ "$VERBOSE" -eq 1 ]; then
            echo "$output"
            echo ""
        fi
        echo -e "  ${GREEN}✓ PASSED${RESET}"
    else
        SUITES_FAILED=$((SUITES_FAILED + 1))
        SUITE_RESULTS[$suite]="fail"
        # Always show output on failure
        echo "$output"
        echo ""
        echo -e "  ${RED}✗ FAILED${RESET} (exit code: $exit_code)"
    fi

    echo ""
done

# ── Cleanup ─────────────────────────────────────────────────────────────────

if [ "$KEEP_BINARIES" -eq 0 ]; then
    log "Cleaning up test files from prefix..."
    rm -rf "$PREFIX_TEST_DIR"
else
    log "Test binaries preserved at: $DARLING_TEST_DIR (inside prefix)"
    log "  Host path: $PREFIX_TEST_DIR"
fi

# ── Summary ─────────────────────────────────────────────────────────────────

TOTAL=$((SUITES_PASSED + SUITES_FAILED + SUITES_SKIPPED))

echo ""
log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
log "${BOLD}  Test Summary${RESET}"
log "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo ""

# Per-suite results table
printf "  %-25s %s\n" "Suite" "Result"
printf "  %-25s %s\n" "─────────────────────────" "──────"
for suite in "${RUN_SUITES[@]}"; do
    result="${SUITE_RESULTS[$suite]:-skip}"
    case "$result" in
        pass) printf "  %-25s ${GREEN}✓ PASS${RESET}\n" "$suite" ;;
        fail) printf "  %-25s ${RED}✗ FAIL${RESET}\n" "$suite" ;;
        skip) printf "  %-25s ${YELLOW}⊘ SKIP${RESET}\n" "$suite" ;;
    esac
done

echo ""
printf "  Total:   %d suites\n" "$TOTAL"
printf "  Passed:  ${GREEN}%d${RESET}\n" "$SUITES_PASSED"
printf "  Failed:  ${RED}%d${RESET}\n" "$SUITES_FAILED"
printf "  Skipped: ${YELLOW}%d${RESET}\n" "$SUITES_SKIPPED"
echo ""

if [ "$SUITES_FAILED" -gt 0 ]; then
    err "Some test suites failed."
    echo ""
    echo "Debugging tips:" >&2
    echo "  • Re-run with --verbose to see full output for passing tests" >&2
    echo "  • Run a single suite: $0 --suite <name>" >&2
    echo "  • Run with --keep to preserve binaries, then inspect inside:" >&2
    echo "      darling shell $DARLING_TEST_DIR/<test_binary>" >&2
    echo "  • Trace syscalls: strace -f -p \$(pidof darlingserver) 2>&1 | head" >&2
    echo "  • Darling xtrace: DARLING_XTRACE=1 darling shell $DARLING_TEST_DIR/<test_binary>" >&2
    echo ""
    exit 1
elif [ "$SUITES_SKIPPED" -gt 0 ] && [ "$SUITES_PASSED" -eq 0 ]; then
    warn "All suites were skipped — check compilation errors above."
    exit 2
else
    log "${GREEN}All tests passed!${RESET}"
    exit 0
fi
