#!/usr/bin/env bash
# POKE THE TRUST SERVICE N TIMES IN ONE CONTAINER, WITH LAUNCHD ON, AND PRINT A RATE.
#
# WHAT THIS ACTUALLY DETECTS, measured 2026-09-08 rather than assumed. A client that needs a trust
# evaluation looks up the MachService com.apple.trustd; launchd demand-starts the job; trustd
# answers and, because its plist sets EnableTransactions and EnablePressuredExit, exits again. Any
# break in that chain shows up here as the SAME symptom, a poke that never returns, because nothing
# on the client side has a timeout. So the rate alone does not name the defect and this script also
# prints trustd's LastExitStatus, which does.
#
# READ LastExitStatus, NOT JUST THE RATE. Values seen so far:
#   0     the job has never been started, or started and exited cleanly
#   768   0x300, so exit(3) -- ESRCH from launchd's own forked child, which is what it returns when
#         getpwnam of the job's UserName fails. com.apple.trustd runs as _trustd, and a prefix whose
#         /etc/master.passwd lists only root and nobody cannot resolve it. The child exits BEFORE
#         exec, so StandardErrorPath is never even created and there is nothing to read anywhere.
#
# THE STALE ARTIFACT TRAP, which cost a whole iteration on 2026-09-08. Everything below is picked
# out of buck-out by mtime, so this happily measures a prefix built before the fix under test and
# reports it as a live product defect. Build //buck/prefix:cider_prefix FIRST. The check at the
# bottom compares the built master.passwd against the source and refuses to run on a stale one.
#
# WHY THIS SCRIPT EXISTS AT ALL. The original harness lived in a session scratchpad under /tmp and
# systemd-tmpfiles swept it, so the numbers in #143 could not be re-taken and the task sat on
# measurements nobody could reproduce. scripts/app-drive.sh carries the same lesson in its header.
#
# THE POKE IS A TESTSUITE CASE, not a bespoke tool: test_SecTrustEvaluateWithError already exists,
# is already wired, and already passes in the batch. Running it N times in ONE container is exactly
# the poke-1-poke-2-poke-3 shape, and reusing it means the client side is known good.
#
# timeout NEEDS -k HERE. A cider that ignores SIGTERM leaves plain timeout waiting forever, and one
# run of this sat for 22 minutes on a 7 minute limit before that was noticed.
#
#   scripts/repro-143.sh            5 pokes
#   N=10 scripts/repro-143.sh       ten
#   LAUNCHD=1 scripts/repro-143.sh  launchd OFF, the control: with no launchd there is no demand
#                                   start at all, so this says what the case does on its own
set -u
cd "$(dirname "$0")/.."
REPO=$(pwd -P)
N=${N:-5}
OUT=${OUT:-/tmp/repro-143}
CASE=dts_System_Library_Frameworks_Security_framework_test_test_SecTrustEvaluateWithError

mkdir -p "$OUT"

ART=$(ls -td "$REPO"/buck-out/v2/art/root/*/vendor/src 2>/dev/null | head -1)
[ -n "$ART" ] || { echo "no buck-out artifacts; build the testsuite case first" >&2; exit 2; }
BIN="$ART/__${CASE}__/$CASE"
if [ ! -x "$BIN" ]; then
	echo "building the poke: //vendor/src:$CASE" >&2
	buck2 build "//vendor/src:$CASE" > "$OUT/build.log" 2>&1 || {
		echo "the poke did not build, see $OUT/build.log" >&2; exit 2; }
fi
[ -x "$BIN" ] || { echo "still no $BIN" >&2; exit 2; }

CIDER=$(ls -t "$REPO"/buck-out/v2/art/root/*/src/linux/launcher/__cider__/cider 2>/dev/null | head -1)
CIDERD=$(ls -t "$REPO"/buck-out/v2/art/root/*/src/linux/server/__ciderd__/ciderd 2>/dev/null | head -1)
MLDR=$(ls -t "$REPO"/buck-out/v2/art/root/*/src/darwin/loader/__mldr__/mldr 2>/dev/null | head -1)
RT=$(ls -td "$REPO"/buck-out/v2/art/root/*/buck/prefix/__cider_prefix__/cider_prefix__prefix 2>/dev/null | head -1)
for t in CIDER CIDERD MLDR RT; do
	[ -e "${!t}" ] || { echo "missing $t" >&2; exit 3; }
done
GUEST="$RT/libexec/cider"

# THE ARTIFACT MUST MATCH THE SOURCE. See the stale artifact note in the header.
if ! diff -q "$REPO/src/darwin/etc/master.passwd" "$GUEST/private/etc/master.passwd" >/dev/null 2>&1; then
	echo "STALE PREFIX: $GUEST/private/etc/master.passwd differs from src/darwin/etc/master.passwd." >&2
	echo "Run: buck2 build //buck/prefix:cider_prefix" >&2
	exit 5
fi

ELF_LIBS=$(grep '^elf_lib_dirs' "$REPO/.buckconfig.local" 2>/dev/null | sed 's/^elf_lib_dirs *= *//')
RES=$(realpath vendor/src/darling-testsuite)

# THE RESOURCE PATH IS THE PARENT of the testsuite directory: the cases ask for paths that already
# begin with "testsuite/", and pointing at the directory itself doubles the component (see #131).
# Omitting it entirely does NOT fail cleanly, it SIGSEGVs the case, which reads as a product defect.
{
	echo '#!/bin/sh'
	echo "export DARLING_TESTSUITE_RESOURCE_PATH=/Volumes/SystemRoot$RES"
	echo 'mkdir -p /tmp/repro143'
	echo 'cd /tmp/repro143'
	# The PHYSICAL path: /tmp is a symlink to private/tmp in the prefix exactly as on macOS.
	echo 'D=$(pwd -P); cd "$D"'
	# COPIED INTO THE PREFIX and run from there. A binary reached through /Volumes/SystemRoot gets
	# the HOST spelling of its own path, CFBundleGetMainBundle answers NULL, and this case in
	# particular traps on that (#205).
	echo "cp \"/Volumes/SystemRoot$(realpath "$BIN")\" \"\$D/poke\" && chmod +x \"\$D/poke\""
	echo 'echo BOOTED'
	echo "for i in \$(seq 1 $N); do"
	echo '  "$D/poke" >/dev/null 2>&1; echo "POKE $i EXIT $?"'
	echo '  launchctl list com.apple.trustd 2>/dev/null | sed -n "s/.*LastExitStatus\" = \(.*\);/TRUSTD_STATUS \1/p"'
	echo 'done'
} > "$OUT/poke.sh"
chmod +x "$OUT/poke.sh"

pkill -9 -x 'mldr|cider|ciderd|shellspawn' 2>/dev/null
sleep 1
chmod -R u+w /tmp/cider-143-1000/prefix 2>/dev/null
rm -rf /tmp/cider-143-1000
mkdir -p /tmp/cider-143-1000

# CIDER_NO_LAUNCHD IS INVERTED: 0 means launchd is ON, which is the whole point here.
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
	CIDERPREFIX=/tmp/cider-143-1000/prefix "CIDER_NO_LAUNCHD=${LAUNCHD:-0}" \
	LD_LIBRARY_PATH="$ELF_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	DYLD_INSERT_LIBRARIES=/usr/lib/swift/libswiftCompat.dylib \
	CIDER_COMPAT_LIBRARY=/usr/lib/swift/libswiftCompat.dylib \
	DSERVER_PATH="$(realpath "$CIDERD")" DSERVER_MLDR_PATH="$(realpath "$MLDR")" \
	DSERVER_LIBEXEC_PATH="$(realpath "$RT")/libexec/cider" \
	timeout -k 10 "${LIMIT:-300}" "$CIDER" shell /bin/sh "/Volumes/SystemRoot$OUT/poke.sh" \
	> "$OUT/run.log" 2>&1

# ciderd.log is CONTAINER WIDE and appends across runs, so take a copy of THIS run's before the
# next one starts.
cp /tmp/cider-143-1000/prefix/ciderd.log "$OUT/ciderd.log" 2>/dev/null
cp /tmp/cider-143-1000/prefix/var/log/system.log "$OUT/system.log" 2>/dev/null
pkill -9 -x 'mldr|cider|ciderd|shellspawn' 2>/dev/null

# A CONTAINER THAT NEVER BOOTED IS NOT A FAILED POKE, and reading it as one is how #143 got its
# numbers wrong before. The container does not always come up with launchd on (#141).
if ! grep -q '^BOOTED' "$OUT/run.log"; then
	echo "NORUN: the guest shell never reached its first line, so this run measured nothing."
	echo "  run log     $OUT/run.log"
	echo "  ciderd log  $OUT/ciderd.log"
	exit 4
fi

grep '^POKE \|^TRUSTD_STATUS ' "$OUT/run.log"
ok=$(grep -c '^POKE [0-9]* EXIT 0$' "$OUT/run.log")
ran=$(grep -c '^POKE ' "$OUT/run.log")
echo
echo "RATE: $ok of $ran pokes replied (launchd $([ "${LAUNCHD:-0}" = 0 ] && echo ON || echo OFF))"
echo "  run log     $OUT/run.log"
echo "  ciderd log  $OUT/ciderd.log"
if [ "$ran" -lt "$N" ]; then
	echo "  NOTE: only $ran of $N pokes ran at all, so the container died or the limit was hit."
fi
if grep -q '^TRUSTD_STATUS 768$' "$OUT/run.log"; then
	echo "  TRUSTD EXITED 3 (ESRCH): launchd could not resolve the job's UserName. See the header."
fi
# grep for trustd in ciderd.log does NOT work: the process kqueue trace names a launchd child by the
# comm it has BEFORE exec, which is always sbin/launchd. launchctl list is the instrument.
