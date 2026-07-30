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
	//src/libsimple:libsimple_darling
	//buck-src:migcom
	//src/startup:rtsig_header
	//src/external/darlingserver:dserver_rpc
	//src/external/darlingserver/duct-tape:darlingserver_duct_tape
	//src/external/darlingserver/tools:dserverdbg
	//linux/server:duct_tape_lib
	//src/libsimple:libsimple_darling_dylib
	//tests/buck2/firstpass:a
	//tests/buck2/firstpass:b
	//tests/buck2/firstpass:umbrella
	//buck-src:system_blocks_firstpass
	//buck-src:keymgr_firstpass
	//buck-src:system_malloc_firstpass
	//buck-src:system_pthread_firstpass
	//buck-src:system_c_firstpass
	//buck-src:system_kernel_firstpass
	//buck-src:system_blocks_final
	//buck-src:system_kernel_final
	//buck-src:platform_firstpass
	//buck-src:compiler_rt_firstpass
	//buck-src:system_dyld_firstpass
	//buck-src:system_asl_firstpass
	//buck-src:system_coretls_firstpass
	//buck-src:asl_ipc_mig
	//src/duct:system_duct_firstpass
	//src/external/libtrace:system_trace_firstpass
	//src/libsystem_coreservices:system_coreservices_firstpass
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

say "== libsimple, GUEST build (Darwin/Mach-O cross toolchain) =="
dlib=$(out_of //src/libsimple:libsimple_darling)
[ -f "$dlib" ] && ok "archive exists" || bad "archive missing"
obj_kind=$(cd "$(dirname "$dlib")" && ar p "$(basename "$dlib")" lock.c.o 2>/dev/null | file - | cut -d: -f2)
case "$obj_kind" in
*"Mach-O 64-bit x86_64"*) ok "member is${obj_kind}" ;;
*) bad "expected a Mach-O 64-bit x86_64 object, got:${obj_kind:-nothing}" ;;
esac
# Darwin mangles C symbols with a leading underscore; seeing it proves the
# cross toolchain really targeted Darwin rather than the host.
if llvm-nm --defined-only "$dlib" 2>/dev/null | awk '{print $3}' | grep -qx "_libsimple_lock_lock"; then
	ok "exports _libsimple_lock_lock (Darwin mangling)"
else
	bad "missing the Darwin-mangled _libsimple_lock_lock"
fi

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

say "== dserverdbg (generated RPC source + a forced -include) =="
dbg=$(out_of //src/external/darlingserver/tools:dserverdbg)
[ -x "$dbg" ] && ok "dserverdbg is executable" || bad "dserverdbg missing"
# It refuses to run without setuid, which is exactly the message we expect: the
# binary links and its RPC surface initialized enough to reach that check.
msg=$("$dbg" 2>&1 | head -1 || true)
case "$msg" in
*"not setuid root"*) ok "dserverdbg runs (reports the expected setuid requirement)" ;;
*) bad "dserverdbg said: $msg" ;;
esac

say "== Mach-O dylib: install_name (phase 1.2) =="
dyl=$(out_of //src/libsimple:libsimple_darling_dylib)
kind=$(file -b "$dyl")
case "$kind" in
*"Mach-O 64-bit x86_64 dynamically linked shared library"*) ok "is a Mach-O dylib" ;;
*) bad "expected a Mach-O dylib, got: $kind" ;;
esac
id=$(llvm-objdump --macho --dylib-id "$dyl" 2>/dev/null | tail -1)
[ "$id" = "/usr/lib/system/libsimple_darling.dylib" ] &&
	ok "install_name is $id" || bad "install_name is '$id'"

say "== the firstpass cycle + umbrella reexport (phase 1.3) =="
a=$(out_of //tests/buck2/firstpass:a)
umb=$(out_of //tests/buck2/firstpass:umbrella)
loads=$(llvm-objdump --macho --private-headers "$a" 2>/dev/null | grep -A2 LC_LOAD_DYLIB | grep "name " || true)
# The point of the firstpass mechanism: liba linked against libb_FIRSTPASS.dylib,
# but records the sibling INSTALL_NAME, so at runtime it loads the real libb.
case "$loads" in
*"/usr/lib/system/libb.dylib"*) ok "liba records the sibling install_name, not the firstpass path" ;;
*) bad "liba's LC_LOAD_DYLIB entries: $loads" ;;
esac
if llvm-nm --undefined-only "$a" 2>/dev/null | grep -qx "_b_value"; then
	ok "liba imports _b_value from its sibling"
else
	bad "liba does not import _b_value"
fi
reexports=$(llvm-objdump --macho --private-headers "$umb" 2>/dev/null | grep -A2 LC_REEXPORT_DYLIB | grep -c "name " || true)
[ "$reexports" -eq 2 ] && ok "umbrella reexports both members" ||
	bad "expected 2 LC_REEXPORT_DYLIB entries, got $reexports"
case "$(file -b "$umb")" in
*NOUNDEFS*) ok "umbrella has no undefined symbols" ;;
*) bad "umbrella still has undefined symbols" ;;
esac

say "== libsystem_blocks: the first real libSystem sublibrary =="
blocks=$(out_of //buck-src:system_blocks_firstpass)
bid=$(llvm-objdump --macho --dylib-id "$blocks" 2>/dev/null | tail -1)
[ "$bid" = "/usr/lib/system/libsystem_blocks.dylib" ] &&
	ok "install_name is $bid" || bad "install_name is '$bid'"
blocks_syms=$(llvm-nm --defined-only --extern-only "$blocks" 2>/dev/null | awk '{print $3}')
for sym in __Block_copy __Block_release __Block_object_assign __Block_object_dispose; do
	if printf '%s\n' "$blocks_syms" | grep -qx "$sym"; then
		ok "exports $sym"
	else
		bad "missing $sym"
	fi
done
# A firstpass resolves nothing, so its siblings' symbols must still be undefined.
if llvm-nm --undefined-only "$blocks" 2>/dev/null | grep -qx "_free"; then
	ok "leaves sibling symbols undefined (as a firstpass must)"
else
	bad "expected _free to be undefined in a firstpass dylib"
fi

say "== libSystem members, as firstpass dylibs =="
# target:install_name, from the reference build's -dylib_file map. Every one is
# checked for being a Mach-O dylib carrying the right install_name.
for pair in \
	"//buck-src:system_blocks_firstpass:/usr/lib/system/libsystem_blocks.dylib" \
	"//buck-src:keymgr_firstpass:/usr/lib/system/libkeymgr.dylib" \
	"//buck-src:system_malloc_firstpass:/usr/lib/system/libsystem_malloc.dylib" \
	"//buck-src:system_pthread_firstpass:/usr/lib/system/libsystem_pthread.dylib" \
	"//buck-src:system_asl_firstpass:/usr/lib/system/libsystem_asl.dylib" \
	"//buck-src:system_c_firstpass:/usr/lib/system/libsystem_c.dylib" \
	"//buck-src:system_kernel_firstpass:/usr/lib/system/libsystem_kernel.dylib" \
	"//buck-src:system_coretls_firstpass:/usr/lib/system/libsystem_coretls.dylib" \
	"//src/duct:system_duct_firstpass:/usr/lib/system/libsystem_duct.dylib" \
	"//src/external/libtrace:system_trace_firstpass:/usr/lib/system/libsystem_trace.dylib" \
	"//src/libsystem_coreservices:system_coreservices_firstpass:/usr/lib/system/libsystem_coreservices.dylib"; do
	t=${pair%:*}
	want=${pair##*:}
	art=$(out_of "$t")
	case "$(file -b "$art")" in
	*"Mach-O 64-bit x86_64 dynamically linked shared library"*) ;;
	*) bad "$t is not a Mach-O dylib"; continue ;;
	esac
	got=$(llvm-objdump --macho --dylib-id "$art" 2>/dev/null | tail -1)
	[ "$got" = "$want" ] && ok "${t##*:} -> $got" || bad "$t install_name is '$got', want '$want'"
done

# libsystem_pthread is split across SEVEN flag groups and has hand-written
# assembly. _pthread_create comes from one group and __pthread_list_lock from
# another, so this also guards against a dylib that names only some groups (which
# links, but leaves symbols undefined).
pth=$(out_of //buck-src:system_pthread_firstpass)
# Collect first: piping straight into `grep -q` fails under pipefail, because grep
# exits on the first match and llvm-nm dies on SIGPIPE.
pth_syms=$(llvm-nm --defined-only "$pth" 2>/dev/null | awk '{print $3}')
for sym in _pthread_create __pthread_list_lock; do
	printf '%s\n' "$pth_syms" | grep -qx "$sym" &&
		ok "libsystem_pthread defines $sym" || bad "libsystem_pthread is missing $sym"
done

# libsystem_c is the big one: 641 objects from 43 cmake object libraries, each of
# which can be several flag groups. Spot-check that the C library is really in
# there rather than an empty shell that happened to link.
libc_dylib=$(out_of //buck-src:system_c_firstpass)
libc_syms=$(llvm-nm --defined-only --extern-only "$libc_dylib" 2>/dev/null | awk '{print $3}')
libc_count=$(printf '%s\n' "$libc_syms" | wc -l)
[ "$libc_count" -ge 1300 ] && ok "libsystem_c exports $libc_count symbols" ||
	bad "libsystem_c exports only $libc_count symbols"
for sym in _printf _fopen _strtod _qsort _getenv _regcomp _uuid_generate _strftime; do
	printf '%s\n' "$libc_syms" | grep -qx "$sym" && ok "libsystem_c exports $sym" ||
		bad "libsystem_c is missing $sym"
done

# asl's sources include <asl_ipc.h>, which MIG generates -- the same include that
# stalls nix-ninja's full-graph build.
aslmig=$(out_of //buck-src:asl_ipc_mig)
[ -f "$aslmig/asl_ipc.h" ] && ok "guest MIG generated asl_ipc.h" ||
	bad "asl_ipc.h was not generated"

say "== libsystem_kernel: the syscall boundary =="
krn=$(out_of //buck-src:system_kernel_firstpass)
krn_syms=$(llvm-nm --defined-only --extern-only "$krn" 2>/dev/null | awk '{print $3}')
kn=$(printf '%s\n' "$krn_syms" | wc -l)
[ "$kn" -ge 1300 ] && ok "libsystem_kernel exports $kn symbols" ||
	bad "libsystem_kernel exports only $kn symbols"
for sym in _mach_msg _mach_task_self_ ___syscall _mmap _kevent; do
	printf '%s\n' "$krn_syms" | grep -qx "$sym" && ok "libsystem_kernel exports $sym" ||
		bad "libsystem_kernel is missing $sym"
done

say "== THE FINAL PASS (phase 2's objective) =="
# libsystem_blocks linked against its four siblings' FIRSTPASS dylibs, the way
# cmake's add_circular does. What proves the mechanism is not that it links, but
# WHAT it recorded: the siblings' install_names, and nothing left undefined.
fin=$(out_of //buck-src:system_blocks_final)
fid=$(llvm-objdump --macho --dylib-id "$fin" 2>/dev/null | tail -1)
[ "$fid" = "/usr/lib/system/libsystem_blocks.dylib" ] && ok "final pass install_name is $fid" ||
	bad "final pass install_name is '$fid'"
loads=$(llvm-objdump --macho --private-headers "$fin" 2>/dev/null | grep -A2 LC_LOAD_DYLIB | grep "name " || true)
for want in libsystem_kernel libsystem_malloc libsystem_pthread libsystem_c; do
	case "$loads" in
	*"/usr/lib/system/$want.dylib"*) ok "final pass records $want by install_name" ;;
	*) bad "final pass does not load $want" ;;
	esac
done
undef=$(llvm-nm --undefined-only "$fin" 2>/dev/null | wc -l)
[ "$undef" -eq 0 ] && ok "final pass has NO undefined symbols" ||
	bad "final pass still has $undef undefined symbols"

say "== the kernel's FINAL pass (the syscall boundary) =="
kf=$(out_of //buck-src:system_kernel_final)
kfid=$(llvm-objdump --macho --dylib-id "$kf" 2>/dev/null | tail -1)
[ "$kfid" = "/usr/lib/system/libsystem_kernel.dylib" ] && ok "install_name is $kfid" ||
	bad "install_name is '$kfid'"
kloads=$(llvm-objdump --macho --private-headers "$kf" 2>/dev/null | grep -A2 LC_LOAD_DYLIB | grep "name " || true)
for want in libsystem_c libcompiler_rt libdyld; do
	case "$kloads" in
	*"/usr/lib/system/$want.dylib"*) ok "kernel final records $want by install_name" ;;
	*) bad "kernel final does not load $want" ;;
	esac
done
# The dserver_rpc_* symbols come from the GENERATED rpc.c, which needs its own
# flag group (dserver-rpc-defs.h force-included). Missing it links a firstpass
# fine but breaks the final pass, so assert one of them is really defined.
kf_syms=$(llvm-nm --defined-only "$kf" 2>/dev/null | awk '{print $3}')
printf '%s\n' "$kf_syms" | grep -qx "_dserver_rpc_checkin" &&
	ok "kernel final defines _dserver_rpc_checkin (generated rpc.c is linked in)" ||
	bad "kernel final is missing _dserver_rpc_checkin"

say "== DUCT_TAPE_LIB staging =="
dir=$(out_of //linux/server:duct_tape_lib)
for a in libdarlingserver_duct_tape.a liblibsimple_darlingserver.a; do
	[ -f "$dir/$a" ] && ok "staged $a" || bad "missing $a in DUCT_TAPE_LIB dir"
done

say ""
say "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
