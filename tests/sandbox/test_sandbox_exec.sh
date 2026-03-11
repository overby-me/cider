#!/bin/sh
# test_sandbox_exec.sh — Regression tests for the sandbox-exec stub binary
#
# Run inside darling shell:
#   sh /path/to/test_sandbox_exec.sh
#
# Expected: all tests pass (exit 0).
#
# See: plan/04-phase2-sandbox.md (Task 2.1)

set -u

PASS=0
FAIL=0
TOTAL=0

pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    printf "  TEST %2d: %-55s \033[32mPASS\033[0m\n" "$TOTAL" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    printf "  TEST %2d: %-55s \033[31mFAIL\033[0m — %s\n" "$TOTAL" "$1" "$2"
}

# ── Locate sandbox-exec ─────────────────────────────────────────────────────

SANDBOX_EXEC="/usr/bin/sandbox-exec"

if [ ! -x "$SANDBOX_EXEC" ]; then
    echo "FATAL: $SANDBOX_EXEC not found or not executable" >&2
    echo "       Install the sandbox-exec stub first (Phase 2, Task 2.1)" >&2
    exit 2
fi

# ── Tests ────────────────────────────────────────────────────────────────────

printf "\n"
printf "═══════════════════════════════════════════════════════════════\n"
printf "  sandbox-exec stub regression tests (Phase 2)\n"
printf "═══════════════════════════════════════════════════════════════\n"
printf "\n"

# --- Test: sandbox-exec exists and is executable ---
if [ -x "$SANDBOX_EXEC" ]; then
    pass "sandbox-exec exists and is executable"
else
    fail "sandbox-exec exists and is executable" "not found at $SANDBOX_EXEC"
fi

# --- Test: basic command execution ---
OUTPUT=$($SANDBOX_EXEC /bin/echo hello 2>&1)
if [ "$OUTPUT" = "hello" ]; then
    pass "basic command: sandbox-exec /bin/echo hello"
else
    fail "basic command: sandbox-exec /bin/echo hello" "got: '$OUTPUT'"
fi

# --- Test: exit code is forwarded ---
$SANDBOX_EXEC /bin/sh -c "exit 0" 2>/dev/null
RET=$?
if [ "$RET" -eq 0 ]; then
    pass "exit code 0 forwarded"
else
    fail "exit code 0 forwarded" "got exit code $RET"
fi

$SANDBOX_EXEC /bin/sh -c "exit 42" 2>/dev/null
RET=$?
if [ "$RET" -eq 42 ]; then
    pass "exit code 42 forwarded"
else
    fail "exit code 42 forwarded" "got exit code $RET"
fi

# --- Test: -f <profile> flag is ignored ---
OUTPUT=$($SANDBOX_EXEC -f /nonexistent/profile.sb /bin/echo ok 2>&1)
if [ "$OUTPUT" = "ok" ]; then
    pass "-f <profile> ignored, command runs"
else
    fail "-f <profile> ignored, command runs" "got: '$OUTPUT'"
fi

# --- Test: -f /dev/null (like Nix uses) ---
OUTPUT=$($SANDBOX_EXEC -f /dev/null /bin/echo "from-dev-null" 2>&1)
if [ "$OUTPUT" = "from-dev-null" ]; then
    pass "-f /dev/null works (Nix-style invocation)"
else
    fail "-f /dev/null works (Nix-style invocation)" "got: '$OUTPUT'"
fi

# --- Test: -p <profile-string> flag is ignored ---
OUTPUT=$($SANDBOX_EXEC -p '(version 1)(allow default)' /bin/echo inline-ok 2>&1)
if [ "$OUTPUT" = "inline-ok" ]; then
    pass "-p <profile-string> ignored, command runs"
else
    fail "-p <profile-string> ignored, command runs" "got: '$OUTPUT'"
fi

# --- Test: -n <name> flag is ignored ---
OUTPUT=$($SANDBOX_EXEC -n no_network /bin/echo named-ok 2>&1)
if [ "$OUTPUT" = "named-ok" ]; then
    pass "-n <name> ignored, command runs"
else
    fail "-n <name> ignored, command runs" "got: '$OUTPUT'"
fi

# --- Test: -D key=value (with space) ---
OUTPUT=$($SANDBOX_EXEC -D _GLOBAL_TMP_DIR=/tmp /bin/echo def-ok 2>&1)
if [ "$OUTPUT" = "def-ok" ]; then
    pass "-D key=value (with space) ignored, command runs"
else
    fail "-D key=value (with space) ignored, command runs" "got: '$OUTPUT'"
fi

# --- Test: -Dkey=value (no space) ---
OUTPUT=$($SANDBOX_EXEC -D_GLOBAL_TMP_DIR=/tmp /bin/echo def-nospace-ok 2>&1)
if [ "$OUTPUT" = "def-nospace-ok" ]; then
    pass "-Dkey=value (no space) ignored, command runs"
else
    fail "-Dkey=value (no space) ignored, command runs" "got: '$OUTPUT'"
fi

# --- Test: multiple flags combined (Nix-style full invocation) ---
OUTPUT=$($SANDBOX_EXEC \
    -f /dev/null \
    -D _GLOBAL_TMP_DIR=/tmp \
    -D TMPDIR=/tmp \
    /bin/echo "nix-style-ok" 2>&1)
if [ "$OUTPUT" = "nix-style-ok" ]; then
    pass "multiple flags combined (Nix-style full invocation)"
else
    fail "multiple flags combined (Nix-style full invocation)" "got: '$OUTPUT'"
fi

# --- Test: all flag types combined ---
OUTPUT=$($SANDBOX_EXEC \
    -f /dev/null \
    -p '(version 1)' \
    -n no_network \
    -D FOO=bar \
    -DBAZ=quux \
    /bin/echo "all-flags-ok" 2>&1)
if [ "$OUTPUT" = "all-flags-ok" ]; then
    pass "all flag types combined"
else
    fail "all flag types combined" "got: '$OUTPUT'"
fi

# --- Test: arguments are passed through to the command ---
OUTPUT=$($SANDBOX_EXEC -f /dev/null /bin/echo arg1 arg2 arg3 2>&1)
if [ "$OUTPUT" = "arg1 arg2 arg3" ]; then
    pass "arguments passed through to command"
else
    fail "arguments passed through to command" "got: '$OUTPUT'"
fi

# --- Test: command with flags that look like sandbox-exec flags ---
OUTPUT=$($SANDBOX_EXEC -f /dev/null /bin/echo -f -D -n -p 2>&1)
if [ "$OUTPUT" = "-f -D -n -p" ]; then
    pass "command args that look like sandbox flags are preserved"
else
    fail "command args that look like sandbox flags are preserved" "got: '$OUTPUT'"
fi

# --- Test: no command specified → error + non-zero exit ---
$SANDBOX_EXEC 2>/dev/null
RET=$?
if [ "$RET" -ne 0 ]; then
    pass "no command → non-zero exit"
else
    fail "no command → non-zero exit" "got exit code $RET"
fi

# --- Test: only flags, no command → error + non-zero exit ---
$SANDBOX_EXEC -f /dev/null -D FOO=bar 2>/dev/null
RET=$?
if [ "$RET" -ne 0 ]; then
    pass "only flags, no command → non-zero exit"
else
    fail "only flags, no command → non-zero exit" "got exit code $RET"
fi

# --- Test: error message on no command ---
STDERR=$($SANDBOX_EXEC 2>&1 >/dev/null || true)
if echo "$STDERR" | grep -qi "no command\|usage\|sandbox-exec"; then
    pass "helpful error message when no command given"
else
    fail "helpful error message when no command given" "stderr: '$STDERR'"
fi

# --- Test: nonexistent command → exit 127 ---
$SANDBOX_EXEC /nonexistent/binary 2>/dev/null
RET=$?
if [ "$RET" -eq 127 ]; then
    pass "nonexistent command → exit 127"
else
    fail "nonexistent command → exit 127" "got exit code $RET"
fi

# --- Test: environment variables are inherited ---
OUTPUT=$(FOO_TEST_VAR=hello123 $SANDBOX_EXEC /bin/sh -c 'echo $FOO_TEST_VAR' 2>&1)
if [ "$OUTPUT" = "hello123" ]; then
    pass "environment variables inherited through sandbox-exec"
else
    fail "environment variables inherited through sandbox-exec" "got: '$OUTPUT'"
fi

# --- Test: stdin is passed through ---
OUTPUT=$(echo "stdin-data" | $SANDBOX_EXEC /bin/cat 2>&1)
if [ "$OUTPUT" = "stdin-data" ]; then
    pass "stdin passed through to command"
else
    fail "stdin passed through to command" "got: '$OUTPUT'"
fi

# --- Test: working directory is preserved ---
EXPECTED_DIR=$(pwd)
OUTPUT=$($SANDBOX_EXEC /bin/pwd 2>&1)
if [ "$OUTPUT" = "$EXPECTED_DIR" ]; then
    pass "working directory preserved"
else
    fail "working directory preserved" "expected '$EXPECTED_DIR', got '$OUTPUT'"
fi

# --- Test: sandbox-exec with /bin/bash -e (Nix builder pattern) ---
TMPFILE=$(mktemp /tmp/sandbox-test.XXXXXX)
$SANDBOX_EXEC -f /dev/null -D _GLOBAL_TMP_DIR=/tmp \
    /bin/bash -e -c "echo builder-ok > $TMPFILE" 2>&1
if [ -f "$TMPFILE" ] && [ "$(cat "$TMPFILE")" = "builder-ok" ]; then
    pass "Nix builder pattern: sandbox-exec -f ... /bin/bash -e -c ..."
else
    fail "Nix builder pattern: sandbox-exec -f ... /bin/bash -e -c ..." \
         "file content: '$(cat "$TMPFILE" 2>/dev/null || echo MISSING)'"
fi
rm -f "$TMPFILE"

# ── Summary ──────────────────────────────────────────────────────────────────

printf "\n"
printf "───────────────────────────────────────────────────────────────\n"
if [ "$FAIL" -eq 0 ]; then
    printf "  Results: %d run, \033[32m%d passed\033[0m, \033[32m0 failed\033[0m\n" \
        "$TOTAL" "$PASS"
else
    printf "  Results: %d run, \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" \
        "$TOTAL" "$PASS" "$FAIL"
fi
printf "───────────────────────────────────────────────────────────────\n"
printf "\n"

exit "$FAIL"
