#!/usr/bin/env bash
# One-time (per machine) setup for a direct `buck2 build` of Darling.
#
# Two things buck2 cannot work out for itself:
#
#  1. The pinned upstream sources (scripts/buck-src.sh). The working copy is not a
#     complete source tree: 147 trees are nix pins with no checkout.
#  2. The absolute path of Darling's Mach-O linker. clang's `-fuse-ld=` only
#     accepts a linker NAME or an ABSOLUTE path, and a Starlark rule cannot
#     compute the project root, so the path is written into .buckconfig.local
#     (gitignored, machine-local) from the nix store path.
#
# Usage: scripts/buck-setup.sh [--all]     # --all materializes every pinned tree
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo_root="$PWD"

want_all=""
[ "${1:-}" = "--all" ] && want_all=1

echo "== pinned sources =="
if [ -n "$want_all" ]; then
	./scripts/buck-src.sh --all
else
	./scripts/buck-src.sh
fi

echo "== Mach-O toolchain =="
ld64="$(nix build "$repo_root#darling-ld64" --no-link --print-out-paths)"
echo "darling-ld64: $ld64"
triplet=x86_64-apple-darwin20
[ -x "$ld64/bin/$triplet-ld" ] || {
	echo "no $triplet-ld in $ld64/bin" >&2
	exit 1
}

# Guest compiles use -nostdinc (the reference build does), which drops clang's
# OWN builtin headers (stddef.h, stdarg.h, ...) along with the host's. The
# reference adds them back with -isystem <resource-dir>/include, so record where
# they are.
clang_resource_dir="$(clang -print-resource-dir)"
echo "clang resource dir: $clang_resource_dir"

# Darling reaches HOST libraries through libelfloader, and wrapgen builds the Mach-O stub
# for each one by dlopen()ing the real .so at BUILD time to read its dynamic symbol table.
# dlopen goes through the loader's search path, so every such library's directory has to be
# on it: `dlopen("libfuse.so")` fails without this even though the dev shell contains fuse.
#
# One entry per wrap_elf() in the tree: fuse for hdiutil (darling-dmg), the sixteen
# src/native ones the gui component wraps, and the five src/CoreAudio ones (ffmpeg's four
# plus pulseaudio) that AudioToolbox decodes and plays through. Looked up by SONAME against the dev shell's own
# -L directories (NIX_LDFLAGS), because that is the authoritative list of what this shell
# declares. pkg-config is not enough on its own: giflib ships no .pc file at all, and
# globbing /nix/store is worse than either, since several of these libraries have more than
# one version there and a stub generated against the wrong one exports the wrong symbols.
elf_sonames="libfuse.so libfreetype.so libjpeg.so libpng.so libtiff.so libgif.so libEGL.so
libfontconfig.so libX11.so libXext.so libXrandr.so libXcursor.so libxkbfile.so libcairo.so
libdbus-1.so libGL.so libGLU.so libswresample.so libavcodec.so libavformat.so libavutil.so
libpulse.so"
_ldirs="$(printf '%s\n' $NIX_LDFLAGS | sed -n 's/^-L//p' | sort -u)"
elf_lib_dirs=""
elf_missing=""
for _so in $elf_sonames; do
	_hit=""
	for _d in $_ldirs; do
		[ -e "$_d/$_so" ] && { _hit="$_d"; break; }
	done
	[ -n "$_hit" ] || _hit="$(pkg-config --variable=libdir "${_so#lib}" 2>/dev/null || true)"
	if [ -n "$_hit" ]; then
		case ":$elf_lib_dirs:" in *":$_hit:"*) ;; *) elf_lib_dirs="${elf_lib_dirs:+$elf_lib_dirs:}$_hit" ;; esac
	else
		elf_missing="$elf_missing $_so"
	fi
done
echo "host ELF lib dirs: $(printf '%s' "$elf_lib_dirs" | tr ':' '\n' | wc -l) entries"
[ -n "$elf_missing" ] && echo "WARNING: cannot locate:$elf_missing -- those wrap_elf stubs will not generate" >&2

# HOST include dirs, for the targets that compile against a host library's real headers
# rather than a wrapgen stub. DBusKit is the only one: it includes <dbus/dbus.h>, and the
# dev shell's own -isystem does not reach it, because dbus puts its headers in a VERSIONED
# subdirectory (include/dbus-1.0) and splits dbus-arch-deps.h into a different output
# entirely. Only pkg-config knows both dirs, which is exactly why the reference cmake asks
# it too. Same shape as elf_lib_dirs: absolute store paths, stable because the store is.
# EVERY host library the reference gives a compile an absolute -I for, not just dbus. The
# reference build.ninja names 25 such include dirs across 23 packages, and the port dropped
# all of them: on the host that went unnoticed because darwin_cc defaults to the bare name
# "clang" (buck/toolchains/BUCK), which inside the dev shell is the WRAPPED clang and injects
# the same directories through NIX_CFLAGS_COMPILE. So the port has been compiling AppKit,
# Onyx2D, CoreGraphics, the CoreAudio cone and the X11 backends against headers nothing in
# the build graph asked for, and it only showed up where that wrapper is deliberately not
# used: the Nix graph derivation pins clang-unwrapped and unsets NIX_CFLAGS, where iokitd
# stops at "X11/Xlib.h file not found".
#
# pkg-config rather than the -isystem list, because several of these are VERSIONED
# subdirectories that only pkg-config knows: freetype2 is include/freetype2, cairo is
# include/cairo, dbus splits over two outputs. The ones with no .pc file at all (giflib) are
# picked up from the dev shell's own -isystem directories below.
host_pkgs="dbus-1 x11 xext xrandr xcursor xkbfile xrender xdmcp xproto freetype2
fontconfig cairo gl glu libavcodec libavformat libavutil libswresample libpulse zlib
libpng libtiff-4 fuse"
host_include_dirs=""
host_include_missing=""
for _p in $host_pkgs; do
	_inc="$(pkg-config --cflags-only-I "$_p" 2>/dev/null | tr ' ' '\n' | sed -n 's/^-I//p')"
	if [ -z "$_inc" ]; then
		host_include_missing="$host_include_missing $_p"
		continue
	fi
	for _d in $_inc; do
		case ":$host_include_dirs:" in *":$_d:"*) ;; *) host_include_dirs="${host_include_dirs:+$host_include_dirs:}$_d" ;; esac
	done
done
# The stragglers. giflib ships no .pc file at all, so pkg-config cannot find it and the
# only authoritative statement of where its header is, is the dev shell's own -isystem
# list -- the same list the wrapped clang has been quietly injecting all along. Added
# AFTER the pkg-config dirs so a versioned subdirectory still wins the include order.
for _d in $(printf '%s\n' ${NIX_CFLAGS_COMPILE:-} | awk '$0=="-isystem"{getline; print}' | sort -u); do
	[ -d "$_d" ] || continue
	case ":$host_include_dirs:" in *":$_d:"*) ;; *) host_include_dirs="${host_include_dirs:+$host_include_dirs:}$_d" ;; esac
done
echo "host include dirs: $(printf '%s' "$host_include_dirs" | tr ':' '\n' | grep -c .) entries"
[ -n "$host_include_missing" ] && echo "WARNING: pkg-config knows nothing about:$host_include_missing" >&2

# The store path is immutable, so an absolute reference to it is stable; rerun
# this script after bumping the sources that ld64 is built from.
cat >.buckconfig.local <<EOF
# GENERATED by scripts/buck-setup.sh -- machine-local, gitignored.
#
# Absolute paths to prebuilt tools and toolchain dirs the Buck2 build drives.
# The nix ones are store paths (immutable), so this file only needs regenerating
# when the derivation that produces them changes.
[darling]
ld = $ld64/bin/$triplet-ld
ld64_dir = $ld64/bin
clang_resource_dir = $clang_resource_dir
elf_lib_dirs = $elf_lib_dirs
host_include_dirs = $host_include_dirs
EOF

echo "wrote .buckconfig.local:"
sed 's/^/  /' .buckconfig.local

echo
echo "ready: buck2 build //src/external/darlingserver/duct-tape:darlingserver_duct_tape"
