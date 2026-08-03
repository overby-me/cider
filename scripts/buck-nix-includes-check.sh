#!/usr/bin/env bash
# Would the targets that need HOST headers still compile under the Nix graph derivation?
#
# This exists because the same bug was found four times in a row, each time an hour into a
# Nix build, and each time it was reproducible on the host in seconds once the condition was
# named. The condition is a divergence between two lists:
#
#   the HOST gets its host include dirs from scripts/buck-setup.sh, which asks pkg-config
#   for 23 packages and then SWEEPS the dev shell's own -isystem directories to catch
#   giflib, which ships no .pc file. That sweep is generous: 51 directories, including ones
#   nobody named, and linux-headers rode in on it unnoticed for the whole campaign.
#
#   NIX gets them from nix/lib/darlingBuck2Graph.nix, which names its packages EXPLICITLY,
#   because a reproducible derivation cannot sweep a shell it does not have. 27 directories.
#
# So the host compiles against a superset and cannot fail the way Nix does. A package
# missing from the Nix list is invisible here until the graph derivation dies on it, which
# is what happened with X11 (task 36) and then linux/types.h (task 38).
#
# This closes that gap by compiling the affected targets the way NIX will: clang-unwrapped
# rather than the dev shell's wrapped clang, whose NIX_CFLAGS_COMPILE is the other half of
# the same crutch, and ONLY the include dirs the Nix derivation declares.
#
# It is deliberately NOT in buck-test.sh: it shells out to nix to read the derivation and
# builds under a non-default buck2 config, which re-analyses. Run it when touching host
# includes, wrappedLibs, or the graph derivation's config.
#
# Usage:  scripts/buck-nix-includes-check.sh
set -uo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

# Every target the reference gives an absolute host -I and that the port builds. Kept in
# step with scripts/buck-host-includes.py, which is what proves the list is complete.
TARGETS=(
	//buck-src:iokitd_obj
	//buck-src:Onyx2D_obj
	//buck-src:CoreText_obj
	//buck-src:hdiutil_obj
	//buck-src:X11_backend_obj
	//buck-src:X11_cgbackend_obj
	//darwin/frameworks:OpenGL_obj
	//darwin/frameworks:fseventsd_obj
	//src/CoreAudio:CoreAudio_obj
	//src/CoreAudio:AudioToolbox_obj
	//src/CoreAudio:AFAVFormatComponent_obj
)

command -v buck2 >/dev/null || {
	say "missing buck2 -- run inside \`nix develop\`"
	exit 2
}

say "== reading the include dirs the Nix graph derivation declares =="
# From the derivation rather than from a copy of the list: a copy is one more thing that
# drifts, and drift is the entire bug this checks for.
nix_dirs=$(nix derivation show '.#darling-buck2-graph' 2>/dev/null |
	grep -oE 'host_include_dirs = [^\\]*' | head -1 | sed 's/^host_include_dirs = //')
[ -n "$nix_dirs" ] || {
	say "could not read host_include_dirs out of the graph derivation"
	exit 2
}
n=$(printf '%s' "$nix_dirs" | tr ':' '\n' | grep -c .)
say "   $n directories"

say "== the compiler Nix uses, which is NOT the dev shell's wrapped clang =="
cu=$(nix build 'nixpkgs#llvmPackages.clang-unwrapped' --no-link --print-out-paths 2>/dev/null | tail -1)
[ -x "$cu/bin/clang" ] || {
	say "could not build clang-unwrapped"
	exit 2
}
say "   $cu"

say "== building ${#TARGETS[@]} host-header targets under those conditions =="
out=$(buck2 build \
	--config "darling.darwin_cc=$cu/bin/clang" \
	--config "darling.darwin_cxx=$cu/bin/clang++" \
	--config "darling.host_include_dirs=$nix_dirs" \
	"${TARGETS[@]}" 2>&1)
rc=$?

if [ "$rc" = 0 ]; then
	say ""
	say "PASS: every host-header target compiles with only what the Nix derivation declares"
	exit 0
fi

say ""
say "FAIL: a target needs a header the Nix graph derivation does not declare."
say "The missing include dir has to be added to hostIncludeLibs (or the versioned-subdir"
say "list beside it) in nix/lib/darlingBuck2Graph.nix. The error names the header:"
say ""
printf '%s\n' "$out" | grep -E "fatal error|file not found|Failed to build" | head -12 >&2
exit 1
