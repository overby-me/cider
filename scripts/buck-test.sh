#!/usr/bin/env bash
# Regression test for the Buck2 port (plan/buck2-port.md).
#
# Asserts that every ported target still builds and that its artifact has the
# properties we verified when it landed -- member counts, symbol presence, and
# that the archives are the ones the Rust daemon can consume. Runs against a
# direct `buck2` daemon, so it is the check to run while iterating; the Nix
# endpoint (phase 3) is not wired yet.
#
# Usage: scripts/buck-test.sh [-v]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

verbose=""
[ "${1:-}" = "-v" ] && verbose=1

fail=0
pass=0

say() { printf '%s\n' "$*"; }
ok() { pass=$((pass + 1)); say "  ok   $*"; }
bad() {
	fail=$((fail + 1))
	say "  FAIL $*"
}

need() {
	command -v "$1" >/dev/null 2>&1 || {
		say "missing $1 -- run inside \`nix develop\` (it provides buck2 + watchman)"
		exit 2
	}
}
need buck2
need watchman

# The pinned upstream trees the port compiles (migcom, the SDK header roots).
if [ ! -d buck-src/bootstrap_cmds ] || [ ! -d buck-src/xnu ]; then
	say "materializing pinned sources (scripts/buck-src.sh) ..."
	./scripts/buck-src.sh >/dev/null
fi

out_of() { # target -> artifact path
	buck2 build "$1" --show-output 2>/dev/null | tail -1 | awk '{print $2}'
}

say "== building ported targets =="
targets=(
	//src/libsimple:libsimple_darlingserver
	//buck-src:migcom
	//src/startup:rtsig_header
	//src/external/darlingserver:dserver_rpc
	//src/external/darlingserver/duct-tape:darlingserver_duct_tape
	//linux/server:duct_tape_lib
)
if [ -n "$verbose" ]; then
	buck2 build "${targets[@]}"
else
	buck2 build "${targets[@]}" >/dev/null 2>&1 || {
		say "buck2 build FAILED; re-run with -v"
		exit 1
	}
fi
say "  ok   all targets build"
pass=$((pass + 1))

say "== libsimple =="
lib=$(out_of //src/libsimple:libsimple_darlingserver)
[ -f "$lib" ] && ok "archive exists" || bad "archive missing"
syms=$(nm --defined-only "$lib" | awk '{print $3}' | grep -c '^libsimple_' || true)
[ "$syms" -ge 13 ] && ok "exports $syms libsimple_* symbols" || bad "expected >= 13 libsimple_* symbols, got $syms"

say "== migcom (the MIG toolchain) =="
migcom=$(out_of //buck-src:migcom)
[ -x "$migcom" ] && ok "migcom is executable" || bad "migcom missing"
ver=$("$migcom" -version 2>&1 | head -1)
[ "$ver" = "1.0" ] && ok "migcom -version = $ver" || bad "migcom -version = '$ver', expected 1.0"

say "== codegen =="
rtsig=$(out_of //src/startup:rtsig_header)
grep -q LINUX_SIGRTMIN "$rtsig" && ok "rtsig.h defines LINUX_SIGRTMIN" || bad "rtsig.h missing LINUX_SIGRTMIN"
# dserver_rpc has three default outputs, and --show-output prints no path for
# multi-output targets, so look for the generated files themselves.
rpc_h=$(find buck-out -path "*__dserver_rpc__*" -name "rpc.h" 2>/dev/null | head -1)
rpc_c=$(find buck-out -path "*__dserver_rpc__*" -name "rpc.c" 2>/dev/null | head -1)
[ -n "$rpc_h" ] && [ -n "$rpc_c" ] && ok "RPC wrappers generated (rpc.h + rpc.c)" ||
	bad "RPC wrappers missing"
if [ -n "$rpc_h" ]; then
	grep -q dserver_rpc "$rpc_h" && ok "rpc.h declares the RPC surface" ||
		bad "rpc.h has no dserver_rpc declarations"
fi

say "== duct-tape =="
dt=$(out_of //src/external/darlingserver/duct-tape:darlingserver_duct_tape)
[ -f "$dt" ] && ok "archive exists" || bad "archive missing"
members=$(ar t "$dt" | wc -l)
# 66 hand-written + 26 MIG-generated + pthread/kern_synch.c
[ "$members" -eq 93 ] && ok "93 members" || bad "expected 93 members, got $members"
# Collect the symbol list ONCE. Note: `nm ... | grep -q` under `set -o pipefail`
# fails even on a match, because grep -q exits early and nm dies on SIGPIPE.
dt_syms=$(nm --defined-only "$dt" | awk '{print $3}' | grep -v '^$' | sort -u)
sym_count=$(printf '%s\n' "$dt_syms" | wc -l)
[ "$sym_count" -ge 2700 ] && ok "defines $sym_count symbols" ||
	bad "expected >= 2700 symbols, got $sym_count"
has_sym() { printf '%s\n' "$dt_syms" | grep -qx "$1"; }
for sym in dtape_init dtape_init_in_thread ipc_kmsg_send mig_init thread_call_initialize; do
	if has_sym "$sym"; then ok "defines $sym"; else bad "missing $sym"; fi
done
# The MIG-generated server stubs must be in there, not just the hand-written code.
if has_sym mach_port_server; then
	ok "contains MIG-generated mach_port_server"
else
	bad "missing MIG-generated mach_port_server"
fi

say "== DUCT_TAPE_LIB staging =="
dir=$(out_of //linux/server:duct_tape_lib)
for a in libdarlingserver_duct_tape.a liblibsimple_darlingserver.a; do
	[ -f "$dir/$a" ] && ok "staged $a" || bad "missing $a in DUCT_TAPE_LIB dir"
done

say ""
say "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
