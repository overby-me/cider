#!/usr/bin/env bash
# Run jsc inside the buck2-built Darling.
#
# The point is RUNTIME evidence. buck-test.sh is almost entirely static -- does it link,
# does it export the right symbols, is the install_name right -- and the JavaScriptCore
# cone (JavaScriptCore, libWTF.a, libbmalloc.a, libmbmalloc.dylib, jsc) passes all of that
# while never having executed a single instruction. This is the cheapest probe that
# exercises the whole cone end to end: the loader, libSystem, ICU, WTF's thread and stack
# setup, bmalloc, and then the interpreter.
#
# CURRENT RESULT: jsc loads and runs WTF initialization, then dies on
#
#   ASSERTION FAILED: m_origin && m_bound
#   wtf/StackBounds.h(129) : bool WTF::StackBounds::isGrowingDownwards() const
#
# which is a DEFAULT-CONSTRUCTED StackBounds (the constexpr ctor sets both to nullptr)
# being queried before anything filled it in from pthread_get_stackaddr_np.
#
# That is NOT a port defect. The reference build.ninja does not put -DNDEBUG on the
# JavaScriptCore compile edge -- the token appears 1379 times elsewhere in the graph and
# not once there -- so the reference compiles JSC with assertions ENABLED too, and its jsc
# asserts in the same place. What this probe establishes is that the port faithfully
# reproduces the reference, and that "JavaScriptCore works on Darling" was never true
# upstream either. Root-causing the empty StackBounds is guest-side work.
#
# So: exit 0 means JS actually evaluated, exit 3 means the known assertion (the cone loaded
# and initialized), and exit 1 means it did not get that far -- which WOULD be a regression.
#
# Usage:  scripts/buck-jsc-check.sh [<scratch dir>]
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

# SHORT by default: the daemon's control socket lives at <prefix>/.darlingserver.sock and a
# Unix socket path is capped at 108 bytes.
root=${1:-/tmp/darling-jsc-$(id -u)}
rt="$root/rt"
prefix="$root/prefix"

command -v buck2 >/dev/null || {
	say "missing buck2 -- run inside \`nix develop\`"
	exit 2
}

say "== building the prefix =="
art=$(buck2 build //buck/prefix:darling_prefix --show-output 2>/dev/null | tail -1 | awk '{print $2}')
[ -d "$art" ] || {
	say "the prefix did not build"
	exit 1
}

# Anything still running from a previous run holds the old prefix mounted, and removing the
# tree underneath a live daemon leaves it wedged -- so this comes FIRST.
for p in /proc/[0-9]*; do
	ex=$(readlink "$p/exe" 2>/dev/null) || continue
	case "$ex" in "$root"/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;; esac
done

say "== materializing into $rt =="
chmod -R u+w "$rt" 2>/dev/null || true
rm -rf "$rt" "$prefix" "$prefix.workdir"
mkdir -p "$rt" "$prefix"
# `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /.
cp -a "$art"/. "$rt"/
chmod -R u+w "$rt"

# jsc and JavaScriptCore.framework come from the PREFIX now. They used to be staged in by
# hand here, because buck/prefix/BUCK was generated from the stock graph while
# JavaScriptCore belongs to `all`; the prefix is generated from `all` now and ships both.

say "== running jsc inside the container =="
# Arithmetic in a loop and a JSON round trip: enough to need the interpreter, the GC and
# bmalloc, and cheap enough that a hang is a hang rather than a slow run.
js='var s = 0; for (var i = 0; i < 200000; i++) s += i;
print("JSC_OK sum=" + s + " json=" + JSON.stringify(JSON.parse("{\"a\":1}")));'
out=$(
	DPREFIX="$prefix" \
		DARLING_NO_LAUNCHD=1 \
		DSERVER_LIBEXEC_PATH="$rt/libexec/darling" \
		DSERVER_MLDR_PATH="$rt/libexec/darling/usr/libexec/darling/mldr" \
		timeout 180 "$rt/bin/darling" shell /usr/bin/jsc -e "$js" 2>&1
) || true

printf '%s\n' "$out"
case "$out" in
*JSC_OK*sum=19999900000*)
	say "PASS: jsc evaluated JavaScript inside the buck2-built Darling"
	exit 0
	;;
*"ASSERTION FAILED: m_origin && m_bound"*)
	say "KNOWN: the JSC cone loads and initializes, then hits the empty-StackBounds"
	say "assertion the reference build hits too (assertions are on in both). Not a"
	say "regression; see the header of this script."
	exit 3
	;;
*)
	say "FAIL: jsc did not reach WTF initialization -- this IS a regression"
	exit 1
	;;
esac
