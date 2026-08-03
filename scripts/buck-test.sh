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
	//buck-src/libc:system_c_firstpass
	//buck-src/xnu:system_kernel_firstpass
	//buck-src:system_blocks_final
	//buck-src/xnu:system_kernel_final
	//buck-src/libplatform:platform_firstpass
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
has_sym() { grep -qxF "$1" <<<"$dt_syms"; }
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
	if grep -qxF "$sym" <<<"$blocks_syms"; then
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
	"//buck-src/libc:system_c_firstpass:/usr/lib/system/libsystem_c.dylib" \
	"//buck-src/xnu:system_kernel_firstpass:/usr/lib/system/libsystem_kernel.dylib" \
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
	grep -qxF "$sym" <<<"$pth_syms" &&
		ok "libsystem_pthread defines $sym" || bad "libsystem_pthread is missing $sym"
done

# libsystem_c is the big one: 641 objects from 43 cmake object libraries, each of
# which can be several flag groups. Spot-check that the C library is really in
# there rather than an empty shell that happened to link.
libc_dylib=$(out_of //buck-src/libc:system_c_firstpass)
libc_syms=$(llvm-nm --defined-only --extern-only "$libc_dylib" 2>/dev/null | awk '{print $3}')
libc_count=$(printf '%s\n' "$libc_syms" | wc -l)
[ "$libc_count" -ge 1300 ] && ok "libsystem_c exports $libc_count symbols" ||
	bad "libsystem_c exports only $libc_count symbols"
for sym in _printf _fopen _strtod _qsort _getenv _regcomp _uuid_generate _strftime; do
	grep -qxF "$sym" <<<"$libc_syms" && ok "libsystem_c exports $sym" ||
		bad "libsystem_c is missing $sym"
done

# asl's sources include <asl_ipc.h>, which MIG generates -- the same include that
# stalls nix-ninja's full-graph build.
aslmig=$(out_of //buck-src:asl_ipc_mig)
[ -f "$aslmig/asl_ipc.h" ] && ok "guest MIG generated asl_ipc.h" ||
	bad "asl_ipc.h was not generated"

say "== libsystem_kernel: the syscall boundary =="
krn=$(out_of //buck-src/xnu:system_kernel_firstpass)
krn_syms=$(llvm-nm --defined-only --extern-only "$krn" 2>/dev/null | awk '{print $3}')
kn=$(printf '%s\n' "$krn_syms" | wc -l)
[ "$kn" -ge 1300 ] && ok "libsystem_kernel exports $kn symbols" ||
	bad "libsystem_kernel exports only $kn symbols"
for sym in _mach_msg _mach_task_self_ ___syscall _mmap _kevent; do
	grep -qxF "$sym" <<<"$krn_syms" && ok "libsystem_kernel exports $sym" ||
		bad "libsystem_kernel is missing $sym"
done
# The mach_zone family, which is really a check on the MIG FLAGS. mig runs the C
# preprocessor over the .defs, so the -D flags the reference passes decide which routines
# exist: without -DPRIVATE=1 on the ksmig_* targets, every `#ifdef PRIVATE` routine is
# silently absent and nothing fails until some program tries to link one. zlog was the
# program that did. The first two here are unguarded and were always exported; the last
# four are the guarded ones, and they are what proves the flags are still being passed.
for sym in _mach_zone_info _mach_zone_info_for_zone _mach_zone_force_gc \
	_mach_zone_info_for_largest_zone _mach_zone_get_zlog_zones _mach_zone_get_btlog_records; do
	grep -qxF "$sym" <<<"$krn_syms" && ok "libsystem_kernel exports $sym" ||
		bad "libsystem_kernel is missing $sym (is -DPRIVATE=1 still on the ksmig targets?)"
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
# What it exports is the point of the pass: the firstpass/final split exists so
# the mutually dependent libraries can define their own symbols.
printf '%s\n' "$(llvm-nm --defined-only --extern-only "$fin" 2>/dev/null | awk '{print $3}')" |
	grep -qx "__Block_copy" && ok "final pass defines _Block_copy" ||
	bad "final pass does not define _Block_copy"
# libclosure's final pass is linked -flat_namespace -undefined,suppress in the
# reference, so its imports are deliberately left unbound and the image is NOT
# two-level. Asserting "no undefined symbols" here would assert the opposite of
# what the reference does.
if llvm-objdump --macho --private-headers "$fin" 2>/dev/null | grep -q TWOLEVEL; then
	bad "final pass is two-level, but the reference links it flat"
else
	ok "final pass is flat-namespace, as the reference links it"
fi
# The kernel's final pass IS two-level, and there nothing may be left unbound.
kfin=$(out_of //buck-src/xnu:system_kernel_final)
if llvm-objdump --macho --private-headers "$kfin" 2>/dev/null | grep -q TWOLEVEL; then
	ok "the kernel's final pass is two-level"
else
	bad "the kernel's final pass is not two-level"
fi
unbound=$(llvm-nm -m "$kfin" 2>/dev/null | grep -c "(undefined) external [^(]*$" || true)
[ "$unbound" -eq 0 ] && ok "the kernel's final pass leaves nothing unbound" ||
	bad "the kernel's final pass leaves $unbound symbols unbound"

say "== the kernel's FINAL pass (the syscall boundary) =="
kf=$(out_of //buck-src/xnu:system_kernel_final)
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
grep -qxF "_dserver_rpc_checkin" <<<"$kf_syms" &&
	ok "kernel final defines _dserver_rpc_checkin (generated rpc.c is linked in)" ||
	bad "kernel final is missing _dserver_rpc_checkin"

say "== every ported dylib links =="
# Discovered rather than listed: the members come from the reference graph, and a
# hand-kept list here would quietly stop covering new ones. Every target must
# produce a Mach-O dylib whose install_name is the one its consumers look it up by.
# Nothing is expected to fail any more: the layer outside the circular cluster
# (libc++, libc++abi, libsystem_dnssd, libsystem_configuration, libquarantine,
# libremovefile, libcopyfile, libsystem_networkextension) is ported too.
dylib_pkgs="//buck-src/... + //src/duct: + //src/libm: + //src/libcache: + //src/sandbox: + //src/launchd: + //src/external/libtrace: + //src/libsystem_coreservices: + //src/lib: + //src/quarantine: + //src/networkextension:"
# By RULE KIND, not by name: check_dylib is an EXECUTABLE whose name ends in _dylib,
# and a name match swept it in here.
all_dylibs=$(buck2 uquery "kind('darwin_dylib', $dylib_pkgs)" 2>/dev/null || true)
n_first=0
n_linked=0
for t in $all_dylibs; do
	name=${t##*:}
	f=$(out_of "$t" || true)
	# Both substitutions have to tolerate failure: with `set -euo pipefail`, an
	# objdump on an empty path takes the whole suite down mid-section, which looks
	# like the run stopping for no reason.
	id=$(llvm-objdump --macho --dylib-id "$f" 2>/dev/null | tail -1 || true)
	case "$id" in
	# A framework binary's id lives under /System/Library, not /usr/lib.
	/usr/lib/* | /System/Library/*)
		n_linked=$((n_linked + 1))
		case "$name" in
		*_firstpass) n_first=$((n_first + 1)) ;;
		esac
		;;
	# No install_name. An install_name is always an ABSOLUTE path, so anything that
	# is not one means the Mach-O carries no LC_ID_DYLIB -- llvm-objdump then echoes
	# the file's own header line ("<path>:") or nothing at all. That is not a defect
	# here: xtrace's per-protocol stubs and every LOADABLE MODULE (zsh's 35, sasl's 8)
	# are dlopened by path, and the reference links them with no -dylib_install_name.
	# For those the assertion is the Mach-O type instead.
	/*) bad "$name has an unexpected install_name (got '$id')" ;;
	*)
		ft=$(llvm-objdump --macho --private-headers "$f" 2>/dev/null | grep -m1 MH_MAGIC || true)
		case "$ft" in
		# BUNDLE as well as DYLIB, because that is what the reference builds these as:
		# zsh's and sasl's module links carry -Wl,-bundle -Wl,-flat_namespace
		# -Wl,-undefined,suppress, which is a MH_BUNDLE by definition. A module is
		# dlopened, never linked against, so it needs no LC_ID_DYLIB and gets none.
		*DYLIB* | *BUNDLE*) n_linked=$((n_linked + 1)) ;;
		*) bad "$name is neither a Mach-O dylib nor a bundle ($ft)" ;;
		esac
		;;
	esac
done
[ "$n_first" -ge 30 ] && ok "$n_first firstpass dylibs link" ||
	bad "expected >= 30 firstpass dylibs, got $n_first"
[ "$n_linked" -ge 129 ] && ok "$n_linked dylibs link in total" ||
	bad "expected >= 129 dylibs, got $n_linked"

say "== libSystem's umbrella records its members =="
# The umbrella reexports each member, so its LC_REEXPORT_DYLIB entries are the
# check that the cluster is wired together rather than merely built.
su=$(out_of //buck-src:system_final)
reex=$(llvm-objdump --macho --private-headers "$su" 2>/dev/null |
	grep -c LC_REEXPORT_DYLIB || true)
[ "$reex" -ge 33 ] && ok "libSystem reexports $reex dylibs" ||
	bad "libSystem reexports only $reex dylibs"
# The Objective-C runtime is the deepest consumer of that umbrella: it links only
# against libSystem.B.dylib plus libc++/libc++abi, so its message dispatch entry
# point being defined means the reexport chain actually resolves.
oc=$(out_of //buck-src/objc4:objc_final)
printf '%s\n' "$(llvm-nm --defined-only --extern-only "$oc" 2>/dev/null | awk '{print $3}')" |
	grep -qx "_objc_msgSend" && ok "libobjc defines _objc_msgSend" ||
	bad "libobjc does not define _objc_msgSend"

say "== guest EXECUTABLES =="
# The dylib layer is not the whole guest: an executable also needs csu's start.S.o
# named directly on the link line and -nostdlib, or clang's driver reaches for an
# -lSystem that no -L holds. NOUNDEFS is the real assertion -- it says the loader
# will not have to resolve anything that is missing.
#
# Discovered from the graph, like the dylibs: every executable target that exists.
exe_pkgs="//buck-src/... + //src/shellspawn: + //src/vchroot: + //src/launchd:"
# dyld is a DYLINKER, not an EXECUTE image, and has its own checks below.
exe_skip="dyld"
exe_blocked=""
all_exes=$(buck2 uquery "kind('darwin_binary', $exe_pkgs)" 2>/dev/null || true)
n_exe=0
for t in $all_exes; do
	name=${t##*:}
	case " $exe_skip " in
	*" $name "*) continue ;;
	esac
	f=$(out_of "$t" || true)
	hdr=$(llvm-objdump --macho --private-headers "$f" 2>/dev/null | grep -m1 MH_MAGIC || true)
	case "$hdr" in
	*EXECUTE*NOUNDEFS*) n_exe=$((n_exe + 1)) ;;
	*EXECUTE*) bad "${t##*:} links but leaves symbols undefined" ;;
	*) bad "${t##*:} is not a Mach-O executable ($hdr)" ;;
	esac
done
[ "$n_exe" -ge 50 ] && ok "$n_exe guest executables link with nothing undefined" ||
	bad "expected >= 50 executables, got $n_exe"
# launchd is PID 1 in the container and notifyd is the notification daemon: both are
# MIG servers, and which generated stub each protocol contributes is not guessable --
# launchd compiles jobServer.c but job_forwardUser.c, from two protocols that both
# declare job_t.
for t in //src/launchd:launchd //buck-src:notifyd; do
	hdr=$(llvm-objdump --macho --private-headers "$(out_of "$t")" 2>/dev/null |
		grep -m1 MH_MAGIC || true)
	case "$hdr" in
	*EXECUTE*NOUNDEFS*) ok "${t##*:} links with nothing undefined" ;;
	*) bad "${t##*:}: $hdr" ;;
	esac
done
for name in $exe_blocked; do
	if buck2 build "//src/launchd:$name" >/dev/null 2>&1; then
		bad "$name builds now -- drop it from the blocked list"
	else
		ok "$name still blocked (expected)"
	fi
done

say "== FRAMEWORK binaries =="
# A framework binary is a Mach-O dylib with no extension at all, so both the edge
# matcher and the sibling resolver have to identify it by its install_name rather than
# by a file suffix. CoreFoundation is the one that matters: it is what every
# higher-level framework builds on, and its constant strings only work because the
# reference aliases _OBJC_CLASS_$___NSCFConstantString to
# ___CFConstantStringClassReference on the link line.
for spec in \
	"//buck-src/corefoundation:CoreFoundation_dylib=/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation" \
	"//darwin/frameworks:DirectoryService_dylib=/System/Library/Frameworks/DirectoryService.framework/Versions/A/DirectoryService" \
	"//buck-src:icucore_dylib=/usr/lib/libicucore.A.dylib"; do
	t=${spec%%=*}
	want=${spec#*=}
	id=$(llvm-objdump --macho --dylib-id "$(out_of "$t")" 2>/dev/null | tail -1 || true)
	[ "$id" = "$want" ] && ok "${t##*:} id is $id" || bad "${t##*:} id is '$id', want $want"
done
cf_syms=$(llvm-nm --defined-only "$(out_of //buck-src/corefoundation:CoreFoundation_dylib)" 2>/dev/null |
	awk '{print $3}' | sort -u)
grep -qxF "___CFConstantStringClassReference" <<<"$cf_syms" &&
	ok "CoreFoundation defines ___CFConstantStringClassReference (the -Wl,-alias took)" ||
	bad "CoreFoundation is missing ___CFConstantStringClassReference"
# cctools' tools are the ones that prove the static archive path: they link
# liblibstuff.a, and strings without libstuff would silently be a stub.
st_syms=$(llvm-nm --defined-only "$(out_of //buck-src:strip)" 2>/dev/null | awk '{print $3}' | sort -u)
grep -qxF "_main" <<<"$st_syms" && ok "strip defines _main" || bad "strip has no _main"

say "== the STATIC tier, and dyld =="
# dyld is not linked against dylibs at all: it links 17 static archives, because the
# loader has to run before any dylib is mapped. Each archive is checked for holding
# objects (an empty one links fine and silently drops symbols).
n_ar=0
for t in //buck-src:compiler_rt_static64 //buck-src:corecrypto_static \
	//buck-src:cxx_static //buck-src:cxxabi_static //buck-src:keymgr_static \
	//buck-src:libc_static //buck-src:libc_static64 //buck-src:macho_static \
	//buck-src:platform_static64 //buck-src:pthread_static \
	//buck-src:system_blocks_static //src/duct:system_duct_static \
	//buck-src:system_kernel_static64 //src/libm:system_m_static \
	//src/external/libtrace:system_trace_static //buck-src:unwind_static; do
	f=$(out_of "$t" || true)
	n=$(ar t "$f" 2>/dev/null | wc -l)
	if [ "$n" -gt 0 ]; then
		n_ar=$((n_ar + 1))
	else
		bad "${t##*:} is empty or missing"
	fi
done
[ "$n_ar" -eq 16 ] && ok "$n_ar static archives hold objects" ||
	bad "only $n_ar of 16 static archives hold objects"
# The kernel archive needs the generated rpc.c in a flag group of its own, exactly as
# the dylib tier does; without it dyld comes out undefined against dserver_rpc_*.
ka=$(out_of //buck-src:system_kernel_static64)
# Collect the symbols FIRST: under `set -o pipefail`, `nm | grep -q` fails even on a
# match, because grep exits early and nm dies on SIGPIPE.
ka_syms=$(llvm-nm --defined-only "$ka" 2>/dev/null | awk '{print $3}' | sort -u)
grep -qxF "_dserver_rpc_tid_for_thread" <<<"$ka_syms" &&
	ok "the static kernel defines _dserver_rpc_tid_for_thread" ||
	bad "the static kernel is missing the generated rpc.c"

dy=$(out_of //buck-src/dyld:dyld)
dhdr=$(llvm-objdump --macho --private-headers "$dy" 2>/dev/null | grep -m1 MH_MAGIC || true)
case "$dhdr" in
*DYLINKER*NOUNDEFS*) ok "dyld is a Mach-O DYLINKER with nothing undefined" ;;
*DYLINKER*) bad "dyld links but leaves symbols undefined" ;;
*) bad "dyld is not a Mach-O dylinker ($dhdr)" ;;
esac
dy_syms=$(llvm-nm --defined-only "$dy" 2>/dev/null | awk '{print $3}' | sort -u)
grep -qxF "__dyld_start" <<<"$dy_syms" &&
	ok "dyld defines __dyld_start" || bad "dyld has no __dyld_start"

say "== coverage against the reference graph =="
# Measured, not estimated: scripts/buck-coverage.py counts every LINK EDGE in the
# reference build.ninja and reports which have a buck2 target. Asserting a floor here
# means a regression that drops targets cannot pass unnoticed.
cov=$(./scripts/buck-coverage.py 2>/dev/null | awk '/^total/ {print $2}')
tot=$(./scripts/buck-coverage.py 2>/dev/null | awk '/^total/ {print $4}')
# The floor tracks the real number. It sat at 208 long after coverage passed 800, which
# made it decorative: anything short of losing three quarters of the port passed it.
#
# result-graph-ref now points at the ALL graph, the largest the reference defines, so these
# are all-component numbers: 1452 of 1452, where stock read 1434 and the cli graph 868 of
# 871. The floor is the WHOLE graph: every in-scope link edge is ported, so any drop at all
# is a regression, not a gap. `buck2 build //...` over all ~12k targets is green too, with
# libstdc++ the last one to fall.
#
# The reference moved stock -> all once `all` reached 100 percent and the prefix followed
# it, which is what let scripts/buck-jsc-check.sh stop hand-staging JavaScriptCore.
#
# The denominator jumped from 1359 when the metric started keying edges by reference PATH
# rather than by artifact basename. A name does not identify a library -- perl builds two
# module sets, cctools sits beside its xcselect shims, and the nine dev-stub frameworks
# build an AppKit called exactly AppKit -- and collapsing a pair onto one entry answered
# "ported" as soon as either half was.
[ "${cov:-0}" -ge 1452 ] && ok "$cov of the reference's ${tot:-1452} in-scope link edges are ported" ||
	bad "coverage dropped to ${cov:-0} of ${tot:-1452}, floor is 1452"

# ZERO edges matched on the artifact name alone. Every reference link edge now resolves to
# a specific target by its PATH, so a pair that shares a name can no longer read ported
# because its other half is. Getting here was not bookkeeping: it turned up 14 xcselect
# shims, python's datetime.so and xcselect's xcrun that were never ported at all, and 54
# perl 5.18 install destinations wired to the 5.28 BINARY.
# GENERATED files, which the link-edge metric never sees. The worry was that a generated
# file nothing compiles could be silently absent. Measured, it cannot: of 4035 generated
# outputs, 3375 are cmake's own bookkeeping targets rather than files, 254 are headers
# (a missing one fails the compile that includes it, and `buck2 build //...` is green),
# 177 are consumed by a build edge and 2 are installed. The 227 that remain are MIG SIDE
# OUTPUTS -- one mig run emits user, server, header and xtrace, and a target compiles one
# or two -- which the REFERENCE does not read either. Asserted so the number cannot grow.
unc=$(./scripts/buck-codegen-coverage.py 2>/dev/null | awk '/^  unconsumed/ {print $2}')
[ "${unc:-999}" -le 227 ] && ok "codegen: $unc generated outputs unconsumed (ceiling 227, all mig side outputs)" ||
	bad "codegen unconsumed rose to ${unc:-unknown}, ceiling is 227"

soft=$(./scripts/buck-coverage.py 2>/dev/null | awk '/^by-name/ {print $2}')
[ "${soft:-0}" -le 0 ] && ok "coverage matches ${soft:-0} edges by name alone (ceiling 0)" ||
	bad "by-name coverage matches rose to ${soft:-unknown}, ceiling is 0"

# The same question for the INSTALL side: link coverage says what builds, this says what
# the port can actually lay out. UNMAPPED is every install entry that neither a target nor
# a source file can supply, and it is a number that only ever goes down -- a ceiling here
# catches a target quietly dropping out of the prefix, which no other check would notice
# until something failed at runtime inside the container.
#
# Cheap enough to belong in the suite only since the registries stopped being rebuilt per
# entry; it used to take eight minutes and now takes under two seconds.
unmapped=$(python3 scripts/gen-install-from-manifests.py 2>/dev/null |
	sed -n 's/^ *UNMAPPED: *//p')
#
# The ceiling is 2 on the stock graph, not 0 as it was on cli: stock INSTALLS iokitd and
# DBusKit, and those are two of the five edges whose blocks are removed for not linking.
# It goes back to 0 when they do.
# ZERO. Every install entry the reference has resolves to something the port builds. The
# last three were not build outputs at all: python-config and the easyinstall shim are
# written by cmake at CONFIGURE time (configure_file), so no ninja edge ever produced them,
# and python.o is $<TARGET_OBJECTS:python27exe_obj>, a single object out of a group rather
# than a library or an executable. All three read as "build output with no target" because
# the resolver only knew how to look for build outputs.
[ "${unmapped:-999}" -le 0 ] && ok "install UNMAPPED is $unmapped (ceiling 0)" ||
	bad "install UNMAPPED rose to ${unmapped:-unknown}, ceiling is 0"

say "== DUCT_TAPE_LIB staging =="
dir=$(out_of //linux/server:duct_tape_lib)
for a in libdarlingserver_duct_tape.a liblibsimple_darlingserver.a; do
	[ -f "$dir/$a" ] && ok "staged $a" || bad "missing $a in DUCT_TAPE_LIB dir"
done

say "== the dtrace cone =="
# Three static libraries (ctf, elf, dwarf), one dylib and four binaries: the largest
# single block of install entries left, landed together because they only ever build
# together. libdtrace also carries the committed lex/yacc output (gen/libdtrace), so a
# build here proves those staged as sources rather than being regenerated.
for t in //buck-src:ctf //buck-src:elf //buck-src:dwarf; do
	a=$(out_of "$t")
	[ -s "$a" ] && ok "built ${t##*:} archive" || bad "$t did not build"
done
dtl=$(out_of //buck-src:libdtrace_dylib)
case "$(file -bL "$dtl")" in
*"Mach-O 64-bit x86_64 dynamically linked shared library"*)
	ok "libdtrace.dylib is a Mach-O x86_64 dylib" ;;
*) bad "libdtrace.dylib is not a Mach-O x86_64 dylib" ;;
esac
for t in //buck-src:dtrace //buck-src:lockstat //buck-src:plockstat //buck-src:usdtheadergen; do
	b=$(out_of "$t")
	case "$(file -bL "$b")" in
	*"Mach-O 64-bit x86_64 executable"*) ok "built ${t##*:}" ;;
	*) bad "$t is not a Mach-O x86_64 executable" ;;
	esac
done

say "== the src/native ELF wrappers (stage 2, gui) =="
# Sixteen Mach-O stubs that forward to HOST libraries through libelfloader, one per
# wrap_elf() in src/native. They belong to the gui component, so they are NOT in the cli
# graph this suite otherwise measures; they are checked here because they build today and a
# break would otherwise go unnoticed until the stock switch.
#
# The export count is the real assertion. An elf_wrapper whose dlopen failed would still
# produce a valid, EMPTY dylib, so a stub with no exports is the failure mode to catch.
for n in X11 cairo GL FreeType gif; do
	w=$(out_of "//src/native:${n}_dylib")
	case "$(file -bL "$w")" in
	*"Mach-O 64-bit x86_64 dynamically linked shared library"*) ;;
	*) bad "lib$n.dylib is not a Mach-O dylib"; continue ;;
	esac
	nex=$(llvm-nm --defined-only --extern-only "$w" 2>/dev/null | wc -l)
	[ "${nex:-0}" -ge 50 ] && ok "lib$n.dylib forwards $nex host symbols" ||
		bad "lib$n.dylib exports only ${nex:-0} symbols (did wrapgen's dlopen fail?)"
done

say "== the src/CoreAudio ELF wrappers (stage 2, ffmpeg + pulseaudio) =="
# The same shape as src/native's, five of them, which AudioToolbox links to decode and
# play. Same assertion for the same reason: a failed dlopen yields a valid EMPTY dylib.
for n in avcodec avutil pulse; do
	w=$(out_of "//src/CoreAudio:${n}_dylib")
	case "$(file -bL "$w")" in
	*"Mach-O 64-bit x86_64 dynamically linked shared library"*) ;;
	*) bad "lib$n.dylib is not a Mach-O dylib"; continue ;;
	esac
	nex=$(llvm-nm --defined-only --extern-only "$w" 2>/dev/null | wc -l)
	[ "${nex:-0}" -ge 100 ] && ok "lib$n.dylib forwards $nex host symbols" ||
		bad "lib$n.dylib exports only ${nex:-0} symbols (did wrapgen's dlopen fail?)"
done

# The buck-registry: pragmas in those files are what makes buck-coverage.py see the
# wrappers at all -- they are built from Starlark tables, and the registry is a text scan
# for a literal name/dylib_name pair. Duplicated data drifts, so assert each pragma list
# and its table still agree. Without this they silently return to reading as unported the
# moment someone adds one more.
check_wrap_table() { # <file> <table name> <sed expr extracting the target from a table row>
	_tbl=$(sed -n "$3" "$1" | sort)
	_reg=$(sed -n 's/^# buck-registry: lib\(.*\)\.dylib = .*$/\1/p' "$1" | sort)
	if [ "$_tbl" = "$_reg" ]; then
		ok "$1 buck-registry pragmas match $2 ($(printf '%s\n' "$_tbl" | wc -l) entries)"
	else
		bad "$1 buck-registry pragmas have drifted from $2"
		diff <(printf '%s\n' "$_tbl") <(printf '%s\n' "$_reg") | sed 's/^/    /' || true
	fi
}
check_wrap_table src/native/BUCK _NATIVE \
	's/^    ("\([A-Za-z0-9]*\)", "lib[^"]*", "[^"]*"),$/\1/p'
check_wrap_table src/CoreAudio/BUCK _AUDIO \
	's/^    ("\([A-Za-z0-9]*\)", "lib[^"]*"),$/\1/p'

say "== wrapgen (the host-ELF bridge generator) =="
# The second host tool (task #8), and the one hdiutil is blocked on: cmake's
# wrap_elf(<name> lib<name>.so) runs it over a HOST library's dynamic symbol table and emits
# a Mach-O stub whose every export forwards through libelfloader. Running it is the
# assertion -- it prints its three-argument usage and exits 0 with no arguments.
wg=$(out_of //src/libelfloader:wrapgen)
case "$(file -bL "$wg")" in
*"ELF 64-bit"*) ok "wrapgen is a host ELF binary" ;;
*) bad "wrapgen is not a host ELF binary" ;;
esac
wgusage=$("$wg" 2>&1 || true)
case "$wgusage" in
"Usage:"*"<library-name> <output-file> <var-access-header>"*)
	ok "wrapgen runs and prints usage" ;;
*) bad "wrapgen did not print its usage" ;;
esac

say "== darling-coredump (a HOST tool that reads Mach-O) =="
# The first of the five host tools to land (task #8). It is worth its own check because
# what it proves is the header slice, not the program: a Linux binary that includes
# <mach-o/loader.h> without pulling in the SDK headers that would collide with glibc's.
# Running it is the assertion that the slice produced a real program -- it prints usage and
# exits 0 with no arguments.
cdump=$(out_of //src/hosttools:darling-coredump)
case "$(file -bL "$cdump")" in
*"ELF 64-bit"*) ok "darling-coredump is a host ELF binary" ;;
*) bad "darling-coredump is not a host ELF binary" ;;
esac
# Captured, not piped into `grep -q`: see the darlingserverd check below for why that
# combination reports failure on a MATCH under `set -o pipefail`.
usage=$("$cdump" 2>&1 || true)
case "$usage" in
"Usage:"*) ok "darling-coredump runs and prints usage" ;;
*) bad "darling-coredump did not print usage" ;;
esac

say "== the Rust components (no cargo in the graph) =="
# All three of Darling's Rust crates, built by rustc under buck2: the launcher, the guest
# loader and the daemon. The daemon is the one that proves the seam -- it links the
# buck2-built duct-tape and libsimple archives and the bindgen-generated hooks vtable.
for t in //linux/launcher:darling //darwin/loader:mldr //linux/server:darlingserverd; do
	b=$(out_of "$t")
	[ -x "$b" ] && ok "built ${t##*:}" || bad "$t did not build"
done
# It refuses to run outside a container, which is exactly the message we want: reaching it
# means the binary linked and got as far as its own startup check.
# Captured, not piped: `grep -q` exits on the first match, the writer takes SIGPIPE, and
# under `set -o pipefail` the whole pipeline then reports failure even though it matched.
msg=$("$(out_of //linux/server:darlingserverd)" 2>&1 || true)
case "$msg" in
*"not meant to be started manually"*)
	ok "darlingserverd links and reaches its startup check" ;;
*) bad "darlingserverd did not reach its startup check" ;;
esac
ver=$("$(out_of //linux/launcher:darling)" --version 2>&1 || true)
case "$ver" in
*"Rust launcher"*) ok "darling --version runs" ;;
*) bad "darling --version failed" ;;
esac

say "== buck-src normalisation (what the Nix endpoint materialises) =="
# The host builds from buck-src as it stands; the Nix endpoint re-runs
# buck-src-normalise.py over its own copy first. So a bug in that script is invisible on
# the host and fatal in Nix, which is exactly what happened: expand_dir_links() followed
# JavaScriptCore's DerivedSources/JavaScriptCore/JavaScriptCore -> ../.. into the tree it
# was creating, made 1147 directories 266 levels deep out of 13, swallowed the resulting
# ENAMETOOLONG in `except OSError` and reported expanding nothing. buck2 then crawled the
# wreckage and aquery died with "File name too long".
#
# Tested on a COPY: buck-src holds materialized pins and this must never write to them.
norm_t=$(mktemp -d)
cp -a buck-src/JavaScriptCore/DerivedSources "$norm_t/" 2>/dev/null
chmod -R u+w "$norm_t"
before=$(find "$norm_t" -type d | wc -l)
python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("n", "scripts/buck-src-normalise.py")
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.expand_dir_links(sys.argv[1])' "$norm_t" >/dev/null 2>&1
after=$(find "$norm_t" -type d | wc -l)
deep=$(find "$norm_t" -type d -printf '%d\n' | sort -n | tail -1)
[ "$before" = "$after" ] &&
	ok "expand_dir_links leaves the cyclic JSC link alone ($after dirs, depth $deep)" ||
	bad "expand_dir_links expanded a cycle: $before -> $after dirs, depth $deep"
[ -L "$norm_t/DerivedSources/JavaScriptCore/JavaScriptCore" ] &&
	ok "the cyclic link survives as a symlink" ||
	bad "the cyclic link was replaced by a real directory"
chmod -R u+w "$norm_t" 2>/dev/null; rm -rf "$norm_t"

say "== host headers (the ones that live outside the build graph) =="
# The port compiles against X11, freetype, fontconfig, cairo, ffmpeg and pulseaudio, and for
# the whole campaign it never asked for their headers: darwin_cc defaults to the bare name
# "clang" (buck/toolchains/BUCK), which in the dev shell is the WRAPPED clang and injects
# them through NIX_CFLAGS_COMPILE. Nothing here noticed until the Nix graph derivation,
# which pins clang-unwrapped and unsets NIX_CFLAGS on purpose, stopped at
# "X11/Xlib.h file not found". This asserts the port keeps naming them itself.
if out=$(./scripts/buck-host-includes.py 2>&1); then
	ok "$(printf '%s' "$out" | tail -1 | sed 's/^ok: //')"
else
	bad "a target compiles against host headers without declaring them"
	printf '%s\n' "$out" | sed 's/^/       /' >&2
fi

say "== the argv separator (what the Nix lowering replays) =="
# aquery renders an action's command by joining the argv with ", " and the graph dump splits
# it back, so an argument containing that separator comes back as two and the lowering
# replays a DIFFERENT command than buck2 ran. It happened once: perl's VERSIONS is the C
# initializer for versions.h, and the Nix build died on a ValueError from the configure
# script while the host, which never round-trips through the rendering, was fine.
# configure_file passes its values in a file now; this catches the next one for free.
if out=$(./scripts/buck-argv-roundtrip-check.py --static 2>&1); then
	ok "$(printf '%s' "$out" | tail -1 | sed 's/^ok: //')"
else
	bad "a BUCK literal would put the argv separator into a command"
	printf '%s\n' "$out" | sed 's/^/       /' >&2
fi

say "== the prefix (what a Darling install actually is) =="
# The port's product is not the link outputs, it is a laid-out prefix. This builds the
# whole of it, which is also the broadest single check in this file: 151 targets, and a
# failure anywhere in the port surfaces here.
prefix=$(out_of //buck/prefix:darling_prefix)
n=$(find "$prefix/" \( -type f -o -type l \) 2>/dev/null | wc -l)
[ "${n:-0}" -ge 5000 ] && ok "prefix has $n entries" || bad "prefix has only ${n:-0} entries"
for f in bin/bash bin/sh usr/lib/dyld usr/lib/libSystem.B.dylib \
	usr/lib/system/libsystem_kernel.dylib usr/share/icu/icudt66l.dat; do
	[ -e "$prefix/libexec/darling/$f" ] && ok "prefix has $f" || bad "prefix is missing $f"
done
# bin/sh is bash under a second name, which is how bash knows to start in POSIX mode.
[ "$(readlink "$prefix/libexec/darling/bin/sh")" = \
  "$(readlink "$prefix/libexec/darling/bin/bash")" ] &&
	ok "bin/sh is the same artifact as bin/bash" || bad "bin/sh does not point at bash"
file -bL "$prefix/libexec/darling/bin/bash" | grep -q "Mach-O 64-bit x86_64 executable" &&
	ok "prefix bash is a Mach-O x86_64 executable" || bad "prefix bash is not Mach-O x86_64"
# The one install(DIRECTORY) whose source is a build output rather than a repo path, so the
# only one that needs a prefix_gen_dir. Both halves matter: the DER tables are what Security
# actually parses, and EVRoots.plist is derived from evroot.config rather than copied, so an
# empty one would mean the generator ran but found no certificates.
bundle="$prefix/libexec/darling/System/Library/Security/Certificates.bundle"
n=$(find "$bundle/" -type f 2>/dev/null | wc -l)
[ "${n:-0}" -eq 10 ] && ok "Certificates.bundle has its 10 files" ||
	bad "Certificates.bundle has ${n:-0} files, expected 10"
[ -s "$bundle/Contents/Resources/certsTable.data" ] &&
	ok "Certificates.bundle certsTable.data is non-empty" ||
	bad "Certificates.bundle certsTable.data is missing or empty"
grep -q "<data>" "$bundle/Contents/Resources/EVRoots.plist" 2>/dev/null &&
	ok "Certificates.bundle EVRoots.plist names EV roots" ||
	bad "Certificates.bundle EVRoots.plist has no roots"

# Is every .dylib actually a library? scripts/buck-loadall-check.sh found 44 that would not
# dlopen, and they are 131-byte git LFS pointers: the Swift runtime binaries live in LFS and
# the checkout never fetched them, so the port installs the pointer under the library's name.
# Nothing links against them, so no build-time check could see it. Free here because the
# prefix is already built above.
if out=$(./scripts/buck-dylib-shape.nu "$prefix/libexec/darling" 2>&1); then
	ok "$(printf '%s' "$out" | tail -1 | sed 's/^ok: //')"
else
	bad "a file installed as .dylib is not a library"
	printf '%s\n' "$out" | sed 's/^/       /' >&2
fi

say ""
say "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
