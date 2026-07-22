#!/usr/bin/env bash
# Regression test for the P1 signal-mask-free ucontext primitives
# (src/external/darlingserver/src/fast_context.c). Proves, without building
# darlingserver, that the fast get/set/makecontext behave byte-identically to
# glibc across darlingserver's usage patterns (setjmp-style resume, makecontext
# new-stack + uc_link return, cooperative suspend/resume) AND make zero
# rt_sigprocmask syscalls where glibc makes many.
#
#   nix shell nixpkgs#gcc nixpkgs#strace --command scripts/test-fast-context.sh
# (or run in any env with a C compiler + strace on the PATH)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
test_c="$here/tests/darlingserver/test_fast_context.c"
fast_c="$here/src/external/darlingserver/src/fast_context.c"
CC="${CC:-cc}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$CC" -O2 "$test_c"                    -o "$tmp/ref"  # glibc ucontext (reference)
"$CC" -O2 -DUSE_FAST "$test_c" "$fast_c" -o "$tmp/fast" # sigmask-free versions

timeout 15 "$tmp/ref"  > "$tmp/out_ref"  2>&1
timeout 15 "$tmp/fast" > "$tmp/out_fast" 2>&1

fail=0
if diff -u "$tmp/out_ref" "$tmp/out_fast"; then
	echo "PASS: fast ucontext behaviour is identical to glibc"
else
	echo "FAIL: behaviour differs from glibc"; fail=1
fi

if command -v strace >/dev/null 2>&1; then
	ref_n=$(strace -f -e trace=rt_sigprocmask -c "$tmp/ref"  2>&1 | awk '/rt_sigprocmask/{print $4}'); ref_n=${ref_n:-0}
	fast_n=$(strace -f -e trace=rt_sigprocmask -c "$tmp/fast" 2>&1 | awk '/rt_sigprocmask/{print $4}'); fast_n=${fast_n:-0}
	echo "rt_sigprocmask: glibc=$ref_n  fast=$fast_n"
	if [ "$fast_n" -ne 0 ]; then echo "FAIL: fast version still calls rt_sigprocmask"; fail=1; fi
	if [ "$ref_n" -eq 0 ]; then echo "WARN: reference made 0 rt_sigprocmask (strace unavailable?)"; fi
else
	echo "SKIP: strace not on PATH; behaviour check only"
fi

[ "$fail" -eq 0 ] && echo "ALL GOOD" || { echo "FAILURES"; exit 1; }
