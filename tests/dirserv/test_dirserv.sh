#!/bin/sh
# test_dirserv.sh — Regression tests for Directory Services stubs
#
# Tests dseditgroup, sysadminctl, and dscl stubs that translate
# macOS Directory Services commands to /etc/passwd and /etc/group
# file operations within a Darling prefix.
#
# Usage:
#   sh test_dirserv.sh
#
# Exit code:
#   0 — all tests passed
#   1 — one or more tests failed
#
# See: plan/07-phase5-daemon.md (Task 5.1)

set -eu

# ── Test framework ──────────────────────────────────────────────────────────

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS: $CURRENT_TEST"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $CURRENT_TEST — $1"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    CURRENT_TEST="$1"
}

# ── Setup ───────────────────────────────────────────────────────────────────

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/test_dirserv.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

# We need stub /etc/passwd and /etc/group for the tools to operate on.
# The tools reference /etc/passwd and /etc/group directly, so we use
# wrapper scripts that override those paths.

PASSWD_FILE="$WORKDIR/passwd"
GROUP_FILE="$WORKDIR/group"

# Seed with minimal entries (root user/group)
cat > "$PASSWD_FILE" <<'EOF'
root:x:0:0:System Administrator:/var/root:/bin/sh
nobody:x:-2:-2:Unprivileged User:/var/empty:/usr/bin/false
daemon:x:1:1:System Services:/var/root:/usr/bin/false
EOF

cat > "$GROUP_FILE" <<'EOF'
wheel:x:0:root
daemon:x:1:root
nobody:x:-2:
staff:x:20:root
EOF

# Find the scripts — they could be in a few locations
SCRIPT_DIR=""
for candidate in \
    "$(dirname "$0")/../../src/dirserv" \
    "/usr/sbin" \
    "$(dirname "$0")/../src/dirserv"; do
    if [ -f "$candidate/dseditgroup" ]; then
        SCRIPT_DIR="$candidate"
        break
    fi
done

if [ -z "$SCRIPT_DIR" ]; then
    echo "ERROR: Cannot find Directory Services stubs (dseditgroup, sysadminctl, dscl)"
    echo "  Looked in: ../../src/dirserv, /usr/sbin, ../src/dirserv"
    exit 2
fi

# Create wrapper scripts that redirect /etc/passwd and /etc/group
# to our test files by modifying the variables the stubs use.
# Since the stubs use hardcoded /etc/passwd and /etc/group, we create
# thin wrappers that set up a temporary overlay.
#
# Actually, the stubs reference /etc/passwd and /etc/group directly.
# We'll use a chroot-like approach: create a fake root and run from there.
# But that requires root. Instead, let's create modified copies of the
# stubs that use our test paths.

mkdir -p "$WORKDIR/bin"

for tool in dseditgroup sysadminctl dscl; do
    sed \
        -e "s|/etc/passwd|${PASSWD_FILE}|g" \
        -e "s|/etc/group|${GROUP_FILE}|g" \
        "$SCRIPT_DIR/$tool" > "$WORKDIR/bin/$tool"
    chmod +x "$WORKDIR/bin/$tool"
done

DSEDITGROUP="$WORKDIR/bin/dseditgroup"
SYSADMINCTL="$WORKDIR/bin/sysadminctl"
DSCL="$WORKDIR/bin/dscl"

echo "═══════════════════════════════════════════════════════════"
echo "  Directory Services Stubs — Regression Tests"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  Tools:       $SCRIPT_DIR"
echo "  Passwd file: $PASSWD_FILE"
echo "  Group file:  $GROUP_FILE"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# dseditgroup tests
# ═══════════════════════════════════════════════════════════════════════════

echo "── dseditgroup ──────────────────────────────────────────────"

# --- create ---

run_test "dseditgroup: create group with explicit GID"
if $DSEDITGROUP -o create -q -i 30000 nixbld 2>/dev/null; then
    if grep -q "^nixbld:x:30000:" "$GROUP_FILE"; then
        pass
    else
        fail "group entry not found or GID mismatch"
    fi
else
    fail "command returned non-zero"
fi

run_test "dseditgroup: create is idempotent (no error on duplicate)"
if $DSEDITGROUP -o create -q -i 30000 nixbld 2>/dev/null; then
    # Count how many nixbld lines exist — should be exactly 1
    count=$(grep -c "^nixbld:" "$GROUP_FILE")
    if [ "$count" -eq 1 ]; then
        pass
    else
        fail "expected 1 entry, got $count"
    fi
else
    fail "command returned non-zero on duplicate"
fi

run_test "dseditgroup: create group with auto-assigned GID"
if $DSEDITGROUP -o create -q testgroup 2>/dev/null; then
    if grep -q "^testgroup:" "$GROUP_FILE"; then
        pass
    else
        fail "group entry not found"
    fi
else
    fail "command returned non-zero"
fi

run_test "dseditgroup: create rejects duplicate GID"
if $DSEDITGROUP -o create -q -i 30000 othergroup 2>"$WORKDIR/stderr.tmp"; then
    fail "should have failed with duplicate GID"
else
    pass
fi

run_test "dseditgroup: create rejects invalid group name"
if $DSEDITGROUP -o create -q 'bad name!' 2>/dev/null; then
    fail "should have rejected invalid name"
else
    pass
fi

# --- edit (add member) ---

run_test "dseditgroup: add user to group"
if $DSEDITGROUP -o edit -a _nixbld1 -t user nixbld 2>/dev/null; then
    members=$(awk -F: '$1 == "nixbld" { print $4 }' "$GROUP_FILE")
    case ",$members," in
        *,_nixbld1,*) pass ;;
        *) fail "user not in member list (got: '$members')" ;;
    esac
else
    fail "command returned non-zero"
fi

run_test "dseditgroup: add second user to group"
if $DSEDITGROUP -o edit -a _nixbld2 -t user nixbld 2>/dev/null; then
    members=$(awk -F: '$1 == "nixbld" { print $4 }' "$GROUP_FILE")
    has1=0; has2=0
    case ",$members," in *,_nixbld1,*) has1=1 ;; esac
    case ",$members," in *,_nixbld2,*) has2=1 ;; esac
    if [ "$has1" -eq 1 ] && [ "$has2" -eq 1 ]; then
        pass
    else
        fail "expected both users in list (got: '$members')"
    fi
else
    fail "command returned non-zero"
fi

run_test "dseditgroup: add user is idempotent"
if $DSEDITGROUP -o edit -a _nixbld1 -t user nixbld 2>/dev/null; then
    count=$(awk -F: '$1 == "nixbld" { print $4 }' "$GROUP_FILE" | tr ',' '\n' | grep -c "^_nixbld1$")
    if [ "$count" -eq 1 ]; then
        pass
    else
        fail "user appears $count times"
    fi
else
    fail "command returned non-zero"
fi

run_test "dseditgroup: add user to nonexistent group fails"
if $DSEDITGROUP -o edit -a foo -t user nosuchgroup 2>/dev/null; then
    fail "should have failed for nonexistent group"
else
    pass
fi

# --- edit (remove member) ---

run_test "dseditgroup: remove user from group"
if $DSEDITGROUP -o edit -d _nixbld2 -t user nixbld 2>/dev/null; then
    members=$(awk -F: '$1 == "nixbld" { print $4 }' "$GROUP_FILE")
    case ",$members," in
        *,_nixbld2,*) fail "_nixbld2 still in member list (got: '$members')" ;;
        *) pass ;;
    esac
else
    fail "command returned non-zero"
fi

# --- checkmember ---

run_test "dseditgroup: checkmember returns 0 for member"
if $DSEDITGROUP -o checkmember -m _nixbld1 nixbld >/dev/null 2>&1; then
    pass
else
    fail "expected exit 0 for existing member"
fi

run_test "dseditgroup: checkmember returns non-zero for non-member"
if $DSEDITGROUP -o checkmember -m _nixbld99 nixbld >/dev/null 2>&1; then
    fail "expected non-zero for non-member"
else
    pass
fi

run_test "dseditgroup: checkmember on nonexistent group fails"
if $DSEDITGROUP -o checkmember -m root nosuchgroup 2>/dev/null; then
    fail "should have failed for nonexistent group"
else
    pass
fi

# --- read ---

run_test "dseditgroup: read group prints PrimaryGroupID"
output=$($DSEDITGROUP -o read nixbld 2>/dev/null)
if echo "$output" | grep -q "PrimaryGroupID: 30000"; then
    pass
else
    fail "expected PrimaryGroupID: 30000 in output"
fi

run_test "dseditgroup: read group prints GroupMembership"
output=$($DSEDITGROUP -o read nixbld 2>/dev/null)
if echo "$output" | grep -q "GroupMembership:.*_nixbld1"; then
    pass
else
    fail "expected GroupMembership containing _nixbld1"
fi

# --- delete ---

run_test "dseditgroup: delete group"
# First create a throwaway group
$DSEDITGROUP -o create -q -i 99999 throwaway 2>/dev/null || true
if $DSEDITGROUP -o delete throwaway 2>/dev/null; then
    if grep -q "^throwaway:" "$GROUP_FILE"; then
        fail "group still exists after delete"
    else
        pass
    fi
else
    fail "command returned non-zero"
fi

run_test "dseditgroup: delete nonexistent group is idempotent"
if $DSEDITGROUP -o delete throwaway 2>/dev/null; then
    pass
else
    fail "should succeed silently for nonexistent group"
fi

# --- usage / error handling ---

run_test "dseditgroup: no arguments prints usage"
if $DSEDITGROUP 2>/dev/null; then
    fail "should have returned non-zero"
else
    pass
fi

run_test "dseditgroup: unknown operation fails"
if $DSEDITGROUP -o frobnicate testgroup 2>/dev/null; then
    fail "should have failed for unknown operation"
else
    pass
fi


# ═══════════════════════════════════════════════════════════════════════════
# sysadminctl tests
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "── sysadminctl ──────────────────────────────────────────────"

run_test "sysadminctl: create user with all options"
if $SYSADMINCTL -addUser _nixbld1 -UID 300 -GID 30000 \
    -home /var/empty -shell /usr/bin/false 2>/dev/null; then
    if grep -q "^_nixbld1:x:300:30000:" "$PASSWD_FILE"; then
        pass
    else
        fail "user entry not found or fields mismatch"
    fi
else
    fail "command returned non-zero"
fi

run_test "sysadminctl: create user is idempotent"
if $SYSADMINCTL -addUser _nixbld1 -UID 300 -GID 30000 2>/dev/null; then
    count=$(grep -c "^_nixbld1:" "$PASSWD_FILE")
    if [ "$count" -eq 1 ]; then
        pass
    else
        fail "expected 1 entry, got $count"
    fi
else
    fail "command returned non-zero on duplicate"
fi

run_test "sysadminctl: create user with defaults"
if $SYSADMINCTL -addUser _nixbld2 -UID 301 -GID 30000 2>/dev/null; then
    line=$(grep "^_nixbld2:" "$PASSWD_FILE")
    if echo "$line" | grep -q "/var/empty"; then
        pass
    else
        fail "default home not set (got: '$line')"
    fi
else
    fail "command returned non-zero"
fi

run_test "sysadminctl: create user with fullName"
if $SYSADMINCTL -addUser _nixbld3 -UID 302 -GID 30000 \
    -fullName "Nix Build User 3" -home /var/empty -shell /usr/bin/false 2>/dev/null; then
    gecos=$(awk -F: '$1 == "_nixbld3" { print $5 }' "$PASSWD_FILE")
    if [ "$gecos" = "Nix Build User 3" ]; then
        pass
    else
        fail "GECOS mismatch (got: '$gecos')"
    fi
else
    fail "command returned non-zero"
fi

run_test "sysadminctl: create rejects duplicate UID"
if $SYSADMINCTL -addUser _dupeuid -UID 300 -GID 30000 2>"$WORKDIR/stderr.tmp"; then
    fail "should have failed with duplicate UID"
else
    pass
fi

run_test "sysadminctl: create rejects non-numeric UID"
if $SYSADMINCTL -addUser _baduid -UID abc -GID 30000 2>/dev/null; then
    fail "should have rejected non-numeric UID"
else
    pass
fi

run_test "sysadminctl: create rejects invalid username"
if $SYSADMINCTL -addUser "bad user!" 2>/dev/null; then
    fail "should have rejected invalid username"
else
    pass
fi

run_test "sysadminctl: ignores -password option"
if $SYSADMINCTL -addUser _nixbld4 -UID 303 -GID 30000 \
    -home /var/empty -shell /usr/bin/false -password "secret" 2>/dev/null; then
    if grep -q "^_nixbld4:x:" "$PASSWD_FILE"; then
        pass
    else
        fail "user not created or password field not 'x'"
    fi
else
    fail "command returned non-zero"
fi

run_test "sysadminctl: ignores -adminUser and -adminPassword"
if $SYSADMINCTL -addUser _nixbld5 -UID 304 -GID 30000 \
    -home /var/empty -shell /usr/bin/false \
    -adminUser admin -adminPassword pw 2>/dev/null; then
    if grep -q "^_nixbld5:" "$PASSWD_FILE"; then
        pass
    else
        fail "user not created"
    fi
else
    fail "command returned non-zero"
fi

run_test "sysadminctl: handles -roleAccount flag"
if $SYSADMINCTL -addUser _nixbld6 -UID 305 -GID 30000 \
    -home /var/empty -shell /usr/bin/false -roleAccount 2>/dev/null; then
    if grep -q "^_nixbld6:" "$PASSWD_FILE"; then
        pass
    else
        fail "user not created"
    fi
else
    fail "command returned non-zero"
fi

# --- deleteUser ---

run_test "sysadminctl: delete user"
# First verify the user exists
if ! grep -q "^_nixbld4:" "$PASSWD_FILE"; then
    fail "prerequisite: _nixbld4 doesn't exist"
else
    if $SYSADMINCTL -deleteUser _nixbld4 2>/dev/null; then
        if grep -q "^_nixbld4:" "$PASSWD_FILE"; then
            fail "user still exists after delete"
        else
            pass
        fi
    else
        fail "command returned non-zero"
    fi
fi

run_test "sysadminctl: delete nonexistent user is idempotent"
if $SYSADMINCTL -deleteUser _nosuchuser 2>/dev/null; then
    pass
else
    fail "should succeed silently for nonexistent user"
fi

# --- usage / error handling ---

run_test "sysadminctl: no arguments prints usage"
if $SYSADMINCTL 2>/dev/null; then
    fail "should have returned non-zero"
else
    pass
fi

run_test "sysadminctl: unknown option fails"
if $SYSADMINCTL -frobnicate 2>/dev/null; then
    fail "should have failed for unknown option"
else
    pass
fi


# ═══════════════════════════════════════════════════════════════════════════
# dscl tests
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "── dscl ─────────────────────────────────────────────────────"

# --- -read /Users ---

run_test "dscl: read user UniqueID"
output=$($DSCL . -read /Users/root UniqueID 2>/dev/null)
if echo "$output" | grep -q "UniqueID: 0"; then
    pass
else
    fail "expected 'UniqueID: 0' (got: '$output')"
fi

run_test "dscl: read user PrimaryGroupID"
output=$($DSCL . -read /Users/_nixbld1 PrimaryGroupID 2>/dev/null)
if echo "$output" | grep -q "PrimaryGroupID: 30000"; then
    pass
else
    fail "expected 'PrimaryGroupID: 30000' (got: '$output')"
fi

run_test "dscl: read user NFSHomeDirectory"
output=$($DSCL . -read /Users/_nixbld1 NFSHomeDirectory 2>/dev/null)
if echo "$output" | grep -q "NFSHomeDirectory: /var/empty"; then
    pass
else
    fail "expected home '/var/empty' (got: '$output')"
fi

run_test "dscl: read user UserShell"
output=$($DSCL . -read /Users/_nixbld1 UserShell 2>/dev/null)
if echo "$output" | grep -q "UserShell: /usr/bin/false"; then
    pass
else
    fail "expected shell '/usr/bin/false' (got: '$output')"
fi

run_test "dscl: read all user keys (no specific key)"
output=$($DSCL . -read /Users/root 2>/dev/null)
if echo "$output" | grep -q "RecordName: root" && \
   echo "$output" | grep -q "UniqueID: 0"; then
    pass
else
    fail "expected full record output"
fi

run_test "dscl: read nonexistent user fails"
if $DSCL . -read /Users/nosuchuser 2>/dev/null; then
    fail "should have failed for nonexistent user"
else
    pass
fi

# --- -read /Groups ---

run_test "dscl: read group PrimaryGroupID"
output=$($DSCL . -read /Groups/nixbld PrimaryGroupID 2>/dev/null)
if echo "$output" | grep -q "PrimaryGroupID: 30000"; then
    pass
else
    fail "expected 'PrimaryGroupID: 30000' (got: '$output')"
fi

run_test "dscl: read group GroupMembership"
output=$($DSCL . -read /Groups/nixbld GroupMembership 2>/dev/null)
if echo "$output" | grep -q "_nixbld1"; then
    pass
else
    fail "expected _nixbld1 in GroupMembership (got: '$output')"
fi

run_test "dscl: read nonexistent group fails"
if $DSCL . -read /Groups/nosuchgroup 2>/dev/null; then
    fail "should have failed for nonexistent group"
else
    pass
fi

# --- -list ---

run_test "dscl: list /Users (names only)"
output=$($DSCL . -list /Users 2>/dev/null)
if echo "$output" | grep -q "^root$" && echo "$output" | grep -q "^_nixbld1$"; then
    pass
else
    fail "expected root and _nixbld1 in user list"
fi

run_test "dscl: list /Users UniqueID"
output=$($DSCL . -list /Users UniqueID 2>/dev/null)
if echo "$output" | grep -q "root.*0"; then
    pass
else
    fail "expected root with UID 0"
fi

run_test "dscl: list /Groups (names only)"
output=$($DSCL . -list /Groups 2>/dev/null)
if echo "$output" | grep -q "^nixbld$" && echo "$output" | grep -q "^wheel$"; then
    pass
else
    fail "expected nixbld and wheel in group list"
fi

run_test "dscl: list /Groups PrimaryGroupID"
output=$($DSCL . -list /Groups PrimaryGroupID 2>/dev/null)
if echo "$output" | grep -q "nixbld.*30000"; then
    pass
else
    fail "expected nixbld with GID 30000"
fi

# --- -create ---

run_test "dscl: create user record"
if $DSCL . -create /Users/_testuser 2>/dev/null; then
    if grep -q "^_testuser:" "$PASSWD_FILE"; then
        pass
    else
        fail "user not created"
    fi
else
    fail "command returned non-zero"
fi

run_test "dscl: create user and set UniqueID"
if $DSCL . -create /Users/_testuser UniqueID 500 2>/dev/null; then
    uid=$(awk -F: '$1 == "_testuser" { print $3 }' "$PASSWD_FILE")
    if [ "$uid" = "500" ]; then
        pass
    else
        fail "UID mismatch (got: '$uid')"
    fi
else
    fail "command returned non-zero"
fi

run_test "dscl: create user and set NFSHomeDirectory"
if $DSCL . -create /Users/_testuser NFSHomeDirectory /Users/_testuser 2>/dev/null; then
    home=$(awk -F: '$1 == "_testuser" { print $6 }' "$PASSWD_FILE")
    if [ "$home" = "/Users/_testuser" ]; then
        pass
    else
        fail "home mismatch (got: '$home')"
    fi
else
    fail "command returned non-zero"
fi

run_test "dscl: create user and set UserShell"
if $DSCL . -create /Users/_testuser UserShell /bin/bash 2>/dev/null; then
    shell=$(awk -F: '$1 == "_testuser" { print $7 }' "$PASSWD_FILE")
    if [ "$shell" = "/bin/bash" ]; then
        pass
    else
        fail "shell mismatch (got: '$shell')"
    fi
else
    fail "command returned non-zero"
fi

run_test "dscl: create user and set RealName"
if $DSCL . -create /Users/_testuser RealName "Test User" 2>/dev/null; then
    gecos=$(awk -F: '$1 == "_testuser" { print $5 }' "$PASSWD_FILE")
    if [ "$gecos" = "Test User" ]; then
        pass
    else
        fail "GECOS mismatch (got: '$gecos')"
    fi
else
    fail "command returned non-zero"
fi

run_test "dscl: create group record"
if $DSCL . -create /Groups/testgrp 2>/dev/null; then
    if grep -q "^testgrp:" "$GROUP_FILE"; then
        pass
    else
        fail "group not created"
    fi
else
    fail "command returned non-zero"
fi

run_test "dscl: create group and set PrimaryGroupID"
if $DSCL . -create /Groups/testgrp PrimaryGroupID 50000 2>/dev/null; then
    gid=$(awk -F: '$1 == "testgrp" { print $3 }' "$GROUP_FILE")
    if [ "$gid" = "50000" ]; then
        pass
    else
        fail "GID mismatch (got: '$gid')"
    fi
else
    fail "command returned non-zero"
fi

run_test "dscl: create ignores IsHidden key"
if $DSCL . -create /Users/_testuser IsHidden 1 2>/dev/null; then
    pass
else
    fail "should silently ignore IsHidden"
fi

# --- -delete ---

run_test "dscl: delete user record"
if $DSCL . -delete /Users/_testuser 2>/dev/null; then
    if grep -q "^_testuser:" "$PASSWD_FILE"; then
        fail "user still exists after delete"
    else
        pass
    fi
else
    fail "command returned non-zero"
fi

run_test "dscl: delete nonexistent user is idempotent"
if $DSCL . -delete /Users/_testuser 2>/dev/null; then
    pass
else
    fail "should succeed silently for nonexistent user"
fi

run_test "dscl: delete group record"
if $DSCL . -delete /Groups/testgrp 2>/dev/null; then
    if grep -q "^testgrp:" "$GROUP_FILE"; then
        fail "group still exists after delete"
    else
        pass
    fi
else
    fail "command returned non-zero"
fi

# --- -append ---

run_test "dscl: append GroupMembership"
if $DSCL . -append /Groups/nixbld GroupMembership _nixbld10 2>/dev/null; then
    members=$(awk -F: '$1 == "nixbld" { print $4 }' "$GROUP_FILE")
    case ",$members," in
        *,_nixbld10,*) pass ;;
        *) fail "_nixbld10 not in member list (got: '$members')" ;;
    esac
else
    fail "command returned non-zero"
fi

run_test "dscl: append GroupMembership is idempotent"
if $DSCL . -append /Groups/nixbld GroupMembership _nixbld10 2>/dev/null; then
    count=$(awk -F: '$1 == "nixbld" { print $4 }' "$GROUP_FILE" | tr ',' '\n' | grep -c "^_nixbld10$")
    if [ "$count" -eq 1 ]; then
        pass
    else
        fail "_nixbld10 appears $count times"
    fi
else
    fail "command returned non-zero"
fi

run_test "dscl: append to nonexistent group fails"
if $DSCL . -append /Groups/nosuchgroup GroupMembership user1 2>/dev/null; then
    fail "should have failed for nonexistent group"
else
    pass
fi

# --- -search ---

run_test "dscl: search /Users by UniqueID"
output=$($DSCL . -search /Users UniqueID 300 2>/dev/null)
if echo "$output" | grep -q "_nixbld1"; then
    pass
else
    fail "expected _nixbld1 in search results (got: '$output')"
fi

run_test "dscl: search /Users by UniqueID (no match)"
output=$($DSCL . -search /Users UniqueID 99999 2>/dev/null)
if [ -z "$output" ]; then
    pass
else
    fail "expected empty results (got: '$output')"
fi

run_test "dscl: search /Groups by PrimaryGroupID"
output=$($DSCL . -search /Groups PrimaryGroupID 30000 2>/dev/null)
if echo "$output" | grep -q "nixbld"; then
    pass
else
    fail "expected nixbld in search results (got: '$output')"
fi

run_test "dscl: search /Users by RecordName"
output=$($DSCL . -search /Users RecordName root 2>/dev/null)
if echo "$output" | grep -q "root"; then
    pass
else
    fail "expected root in search results (got: '$output')"
fi

# --- datasource handling ---

run_test "dscl: accepts /Local/Default as datasource"
output=$($DSCL /Local/Default -list /Users 2>/dev/null)
if echo "$output" | grep -q "^root$"; then
    pass
else
    fail "expected user list with /Local/Default datasource"
fi

run_test "dscl: rejects unsupported datasource"
if $DSCL /LDAPv3/ldap.example.com -list /Users 2>/dev/null; then
    fail "should have rejected unsupported datasource"
else
    pass
fi

# --- error handling ---

run_test "dscl: no arguments prints usage"
if $DSCL 2>/dev/null; then
    fail "should have returned non-zero"
else
    pass
fi

run_test "dscl: unknown command fails"
if $DSCL . -frobnicate /Users 2>/dev/null; then
    fail "should have failed for unknown command"
else
    pass
fi


# ═══════════════════════════════════════════════════════════════════════════
# Integration: Nix installer simulation
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "── Integration: Nix installer simulation ────────────────────"

# Reset the files for a clean integration test
cat > "$PASSWD_FILE" <<'EOF'
root:x:0:0:System Administrator:/var/root:/bin/sh
nobody:x:-2:-2:Unprivileged User:/var/empty:/usr/bin/false
EOF

cat > "$GROUP_FILE" <<'EOF'
wheel:x:0:root
nobody:x:-2:
staff:x:20:root
EOF

run_test "integration: create nixbld group (dseditgroup)"
$DSEDITGROUP -o create -q -i 30000 nixbld 2>/dev/null
if grep -q "^nixbld:x:30000:" "$GROUP_FILE"; then
    pass
else
    fail "nixbld group not created"
fi

run_test "integration: create 5 build users (sysadminctl)"
ALL_OK=1
for i in 1 2 3 4 5; do
    uid=$((299 + i))
    if ! $SYSADMINCTL -addUser "_nixbld${i}" -UID "$uid" -GID 30000 \
        -home /var/empty -shell /usr/bin/false \
        -fullName "Nix Build User ${i}" 2>/dev/null; then
        ALL_OK=0
        break
    fi
done
if [ "$ALL_OK" -eq 1 ]; then
    count=$(grep -c "^_nixbld" "$PASSWD_FILE")
    if [ "$count" -eq 5 ]; then
        pass
    else
        fail "expected 5 build users, got $count"
    fi
else
    fail "sysadminctl failed during user creation"
fi

run_test "integration: add all build users to nixbld group (dseditgroup)"
ALL_OK=1
for i in 1 2 3 4 5; do
    if ! $DSEDITGROUP -o edit -a "_nixbld${i}" -t user nixbld 2>/dev/null; then
        ALL_OK=0
        break
    fi
done
if [ "$ALL_OK" -eq 1 ]; then
    members=$(awk -F: '$1 == "nixbld" { print $4 }' "$GROUP_FILE")
    # Verify all 5 are present
    member_count=$(echo "$members" | tr ',' '\n' | grep -c "^_nixbld")
    if [ "$member_count" -eq 5 ]; then
        pass
    else
        fail "expected 5 members, got $member_count (members: '$members')"
    fi
else
    fail "dseditgroup edit failed"
fi

run_test "integration: verify via dscl -read"
output=$($DSCL . -read /Groups/nixbld GroupMembership 2>/dev/null)
if echo "$output" | grep -q "_nixbld1" && \
   echo "$output" | grep -q "_nixbld5"; then
    pass
else
    fail "dscl read didn't show expected members"
fi

run_test "integration: verify UIDs via dscl -search"
output=$($DSCL . -search /Users UniqueID 300 2>/dev/null)
if echo "$output" | grep -q "_nixbld1"; then
    pass
else
    fail "dscl search didn't find _nixbld1 with UID 300"
fi

run_test "integration: verify via dscl -list"
output=$($DSCL . -list /Users UniqueID 2>/dev/null)
if echo "$output" | grep -q "_nixbld1.*300" && \
   echo "$output" | grep -q "_nixbld5.*304"; then
    pass
else
    fail "dscl list didn't show expected users with UIDs"
fi

run_test "integration: checkmember for all build users"
ALL_OK=1
for i in 1 2 3 4 5; do
    if ! $DSEDITGROUP -o checkmember -m "_nixbld${i}" nixbld >/dev/null 2>&1; then
        ALL_OK=0
        break
    fi
done
if [ "$ALL_OK" -eq 1 ]; then
    pass
else
    fail "checkmember failed for _nixbld${i}"
fi

run_test "integration: re-running create is idempotent (full sequence)"
$DSEDITGROUP -o create -q -i 30000 nixbld 2>/dev/null
for i in 1 2 3 4 5; do
    uid=$((299 + i))
    $SYSADMINCTL -addUser "_nixbld${i}" -UID "$uid" -GID 30000 \
        -home /var/empty -shell /usr/bin/false 2>/dev/null
    $DSEDITGROUP -o edit -a "_nixbld${i}" -t user nixbld 2>/dev/null
done
# Verify no duplicates
group_count=$(grep -c "^nixbld:" "$GROUP_FILE")
user_count=$(grep -c "^_nixbld1:" "$PASSWD_FILE")
member_count=$(awk -F: '$1 == "nixbld" { print $4 }' "$GROUP_FILE" | tr ',' '\n' | grep -c "^_nixbld1$")
if [ "$group_count" -eq 1 ] && [ "$user_count" -eq 1 ] && [ "$member_count" -eq 1 ]; then
    pass
else
    fail "duplicates found: groups=$group_count, users=$user_count, memberships=$member_count"
fi

run_test "integration: cleanup — delete all build users"
ALL_OK=1
for i in 1 2 3 4 5; do
    if ! $SYSADMINCTL -deleteUser "_nixbld${i}" 2>/dev/null; then
        ALL_OK=0
        break
    fi
done
if [ "$ALL_OK" -eq 1 ]; then
    remaining=$(grep -c "^_nixbld" "$PASSWD_FILE" || true)
    if [ "$remaining" -eq 0 ]; then
        pass
    else
        fail "$remaining build users remain"
    fi
else
    fail "deleteUser failed"
fi

run_test "integration: cleanup — delete nixbld group"
if $DSEDITGROUP -o delete nixbld 2>/dev/null; then
    if grep -q "^nixbld:" "$GROUP_FILE"; then
        fail "group still exists"
    else
        pass
    fi
else
    fail "delete failed"
fi


# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "FAILED"
    exit 1
else
    echo "ALL TESTS PASSED"
    exit 0
fi
