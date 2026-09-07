#!/usr/bin/env bash
# Run the WHOLE darling-testsuite batch and print a per-case verdict and a rate.
#
#   scripts/run-dts-batch.sh                 build everything, run everything
#   scripts/run-dts-batch.sh --no-build      reuse whatever is already built
#
# ONE CONTAINER FOR ALL CASES, which matters twice over. It is far faster than a container per
# case, and it is the only way to read a case's REAL exit code: `cider shell` does not propagate a
# guest that dies on a signal, so from outside, an aborted case and a passing one both look like 0
# (see scripts/run-dts-case.sh). Inside a single guest shell, $? after each case is the true code.
#
# DARLING_TESTSUITE_RESOURCE_PATH MUST BE THE PARENT of the testsuite directory, not the testsuite
# directory itself: the cases ask for paths that already begin with "testsuite/", so pointing at
# .../darling-testsuite/testsuite silently doubles the component and every resource-using case
# fails with ENOENT. Getting that wrong made four cases look like product defects.
#
# EXIT CODES: 0 pass, 134 an assertion fired, 139 a segfault, 1 the case could not load or is one
# of the WILL_FAIL cases where a non-zero exit IS the pass.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"
OUT=${OUT:-/tmp/dts-batch}
mkdir -p "$OUT"

# Every case target in the generated BUCK, minus the per-case object libraries.
grep '^    name = "dts_' vendor/src/BUCK | sed 's/.*name = "//; s/",//' | grep -v '_obj$' | sort > "$OUT/targets.txt"

if [ "${1:-}" != "--no-build" ]; then
	sed 's|^|//vendor/src:|' "$OUT/targets.txt" > "$OUT/labels.txt"
	# --keep-going: several cases do not compile yet and that must not stop the rest.
	xargs -a "$OUT/labels.txt" buck2 build --keep-going > "$OUT/build.log" 2>&1 || true
fi

ART=$(ls -td "$REPO"/buck-out/v2/art/root/*/vendor/src 2>/dev/null | head -1)
[ -n "$ART" ] || { echo "no buck-out artifacts; build first" >&2; exit 2; }

: > "$OUT/built.txt"; : > "$OUT/nobuild.txt"
while read -r t; do
	if [ -x "$ART/__${t}__/$t" ]; then echo "$t" >> "$OUT/built.txt"; else echo "$t" >> "$OUT/nobuild.txt"; fi
done < "$OUT/targets.txt"

RES=$(realpath vendor/src/darling-testsuite)
# EACH CASE IS COPIED INTO THE PREFIX AND RUN FROM THERE, not run in place from buck-out. A binary
# executed through /Volumes/SystemRoot gets the HOST spelling of its own path, and CFBundleCreate
# needs an existing directory, so CFBundleGetMainBundle answers NULL and anything that asks for the
# main bundle fails. That is what made the Security case trap (task #205). Upstream installs its
# cases before running them, so this is also closer to how the suite is meant to run.
# A FEW CASES CARE WHAT THEY ARE CALLED. The posix_spawn pair builds
# "$(getcwd)/<DARLING_IDENTIFIER>.<case>" and compares it against argv[0], and the parent spawns the
# child by that RELATIVE name, so both have to be present and invoked under the name CMake would
# have used. Our target names put an underscore where CMake puts a dot.
python3 scripts/gen-testsuite-buck.py --cmake-names 2>/dev/null > "$OUT/cmake-names.txt" || : > "$OUT/cmake-names.txt"
runname() {
	awk -v t="$1" '$1 == t {print $2; found=1} END {if (!found) print t}' "$OUT/cmake-names.txt"
}

# STAGE EVERYTHING FIRST, then run, so a case that spawns a sibling does not depend on the order
# the two happen to appear in.
{
	echo '#!/bin/sh'
	echo "export DARLING_TESTSUITE_RESOURCE_PATH=/Volumes/SystemRoot$RES"
	echo 'mkdir -p /tmp/dts'
	echo 'cd /tmp/dts'
	# THE PHYSICAL PATH, not the literal /tmp and not the shell's logical pwd. In the prefix /tmp is
	# a symlink to private/tmp exactly as on macOS, so getcwd(3) answers /private/tmp/dts while the
	# pwd BUILTIN answers /tmp/dts. The posix_spawn child compares argv[0] against getcwd plus its
	# own name, and fails on that difference alone. Measured: via the logical path it aborts, via
	# the physical path it exits 0.
	echo 'D=$(pwd -P); cd "$D"'
	while read -r t; do
		src="/Volumes/SystemRoot$(realpath "$ART")/__${t}__/$t"
		echo "cp \"$src\" \"\$D/$(runname "$t")\" && chmod +x \"\$D/$(runname "$t")\""
	done < "$OUT/built.txt"
	while read -r t; do
		echo "\"\$D/$(runname "$t")\" >/dev/null 2>&1; echo \"CASE $t EXIT \$?\""
	done < "$OUT/built.txt"
} > "$OUT/batch.sh"
chmod +x "$OUT/batch.sh"

CIDER=$(ls -t "$REPO"/buck-out/v2/art/root/*/src/linux/launcher/__cider__/cider 2>/dev/null | head -1)
CIDERD=$(ls -t "$REPO"/buck-out/v2/art/root/*/src/linux/server/__ciderd__/ciderd 2>/dev/null | head -1)
MLDR=$(ls -t "$REPO"/buck-out/v2/art/root/*/src/darwin/loader/__mldr__/mldr 2>/dev/null | head -1)
RT=$(ls -td "$REPO"/buck-out/v2/art/root/*/buck/prefix/__cider_prefix__/cider_prefix__prefix 2>/dev/null | head -1)
ELF_LIBS=$(grep '^elf_lib_dirs' "$REPO/.buckconfig.local" 2>/dev/null | sed 's/^elf_lib_dirs *= *//')

pkill -9 -x 'mldr|cider|ciderd|shellspawn' 2>/dev/null
sleep 1
mkdir -p /tmp/cider-dts-1000
# cider refuses a prefix that already exists. chmod first: a previous run's clonefile cases leave
# behind copies that inherited a read-only mode from their source, and plain rm -rf cannot remove
# those from a read-only directory.
chmod -R u+w /tmp/cider-dts-1000/prefix 2>/dev/null
rm -rf /tmp/cider-dts-1000/prefix

env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
	CIDERPREFIX=/tmp/cider-dts-1000/prefix CIDER_NO_LAUNCHD=1 \
	LD_LIBRARY_PATH="$ELF_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	DYLD_INSERT_LIBRARIES=/usr/lib/swift/libswiftCompat.dylib \
	CIDER_COMPAT_LIBRARY=/usr/lib/swift/libswiftCompat.dylib \
	DSERVER_PATH="$(realpath "$CIDERD")" DSERVER_MLDR_PATH="$(realpath "$MLDR")" \
	DSERVER_LIBEXEC_PATH="$(realpath "$RT")/libexec/cider" \
	timeout "${LIMIT:-1800}" "$CIDER" shell /bin/sh "/Volumes/SystemRoot$OUT/batch.sh" \
	> "$OUT/run.log" 2>&1
pkill -9 -x 'mldr|cider|ciderd|shellspawn' 2>/dev/null

# CTest marks these WILL_FAIL: a non-zero exit is the pass.
WILLFAIL=$(python3 scripts/gen-testsuite-buck.py --willfail 2>/dev/null | tr '\n' ' ')
# Cases upstream has not written. They exit(1) with every line commented out, so they fail on real
# macOS too; counting them as failures here reads as a defect in this port and is not one.
PLACEHOLDER=$(python3 scripts/gen-testsuite-buck.py --placeholders 2>/dev/null | tr '\n' ' ')

pass=0; fail=0; unwritten=0
: > "$OUT/failed.txt"; : > "$OUT/placeholder.txt"
while read -r _ t _ rc; do
	short=${t#dts_}
	skip=0
	for p in $PLACEHOLDER; do case "$short" in *"$p") skip=1 ;; esac; done
	if [ "$skip" = 1 ]; then
		unwritten=$((unwritten + 1)); echo "$rc $short" >> "$OUT/placeholder.txt"; continue
	fi
	expect_fail=0
	for w in $WILLFAIL; do case "$short" in *"$w") expect_fail=1 ;; esac; done
	if { [ "$rc" = 0 ] && [ "$expect_fail" = 0 ]; } || { [ "$rc" != 0 ] && [ "$expect_fail" = 1 ]; }; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1)); echo "$rc $short" >> "$OUT/failed.txt"
	fi
done < <(grep '^CASE ' "$OUT/run.log")

wired=$(wc -l < "$OUT/targets.txt"); built=$(wc -l < "$OUT/built.txt")
ran=$(grep -c '^CASE ' "$OUT/run.log")
echo "wired $wired, built $built, ran $ran, passed $pass, failed $fail, unwritten upstream $unwritten"
echo
echo "failures (exit code, case):"
sort -n "$OUT/failed.txt"
if [ "$unwritten" -gt 0 ]; then
	echo
	echo "not counted, upstream never wrote a body:"
	sort -n "$OUT/placeholder.txt"
fi
echo
echo "did not build: $(wc -l < "$OUT/nobuild.txt"), see $OUT/nobuild.txt and $OUT/build.log"
[ "$fail" -eq 0 ]
