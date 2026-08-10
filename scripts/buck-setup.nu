#!/usr/bin/env nu
# One-time (per machine) setup for a direct `buck2 build` of Darling.
#
# Two things buck2 cannot work out for itself:
#
#  1. The pinned upstream sources (scripts/buck-src.nu). The working copy is not a
#     complete source tree: 147 trees are nix pins with no checkout.
#  2. The absolute path of Darling's Mach-O linker. clang's `-fuse-ld=` only
#     accepts a linker NAME or an ABSOLUTE path, and a Starlark rule cannot
#     compute the project root, so the path is written into .buckconfig.local
#     (gitignored, machine-local) from the nix store path.
#
# Converted from bash (task #40) and checked by running both and diffing the .buckconfig.local
# they produce as well as their output, not by reading it.
#
# Usage: scripts/buck-setup.nu [--all]     # --all materializes every pinned tree

def main [--all] {
    cd ($env.FILE_PWD | path join ".." | path expand)
    let repo_root = $env.PWD

    print "== pinned sources =="
    if $all {
        ^./scripts/buck-src.nu --all
    } else {
        ^./scripts/buck-src.nu
    }

    print "== Mach-O toolchain =="
    let ld64 = (^nix build $"($repo_root)#cider-ld64" --no-link --print-out-paths
        | str trim)
    print $"cider-ld64: ($ld64)"
    let triplet = "x86_64-apple-darwin20"
    if not ($"($ld64)/bin/($triplet)-ld" | path exists) {
        print -e $"no ($triplet)-ld in ($ld64)/bin"
        exit 1
    }

    # Guest compiles use -nostdinc (the reference build does), which drops clang's
    # OWN builtin headers (stddef.h, stdarg.h, ...) along with the host's. The
    # reference adds them back with -isystem <resource-dir>/include, so record where
    # they are.
    let clang_resource_dir = (^clang -print-resource-dir | str trim)
    print $"clang resource dir: ($clang_resource_dir)"

    # THE GUEST TOOLCHAIN MUST NOT BE THE WRAPPED CLANG, and ciderBuck2Graph.nix has always
    # known it: the Nix graph derivation pins darwin_cc to clang-unwrapped and unsets
    # NIX_CFLAGS/NIX_LDFLAGS. This file set neither, so darwin_cc fell back to the bare name
    # clang from buck/toolchains/BUCK, which in the dev shell is the WRAPPED one, and it
    # breaks a guest build two separate ways:
    #   1. add-hardening.sh appends -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 AFTER the argv, so
    #      the -D_FORTIFY_SOURCE=0 the port passes loses. libc secure/_stdio.h then turns
    #      snprintf into a macro over __builtin___snprintf_chk, which rewrites libc OWN
    #      DEFINITION of snprintf, and //buck-src/libc:libc-stdio_obj does not parse.
    #   2. bin/clang re-sources the binutils add-flags whenever the bintools sentinel is
    #      unset, which is true here and false inside a derivation, so every link gets
    #      -Wl,-dynamic-linker=<glibc ld.so> and ld64 dies with "unknown option".
    # Measured 2026-08-10: those two are the whole of a clean buck-test reporting
    # "built, 432 of 659 reported an output" with 227 FAIL lines, while the Nix endpoint was
    # green. A green endpoint is not evidence about the dev shell.
    #
    # cc and cxx stay WRAPPED deliberately. Host ELF tools DO need the nixpkgs dynamic linker
    # and the -L paths, and the unwrapped clang cannot even find stdio.h without them.
    let nix_cc = ($env.NIX_CC? | default "")
    if ($nix_cc | is-empty) or not ($"($nix_cc)/nix-support/orig-cc" | path exists) {
        print -e "ERROR: NIX_CC is unset or has no nix-support/orig-cc, so the unwrapped clang"
        print -e "cannot be located. Run this from inside the dev shell."
        exit 1
    }
    let clang_unwrapped = (open $"($nix_cc)/nix-support/orig-cc" | str trim)
    print $"unwrapped clang (guest toolchain): ($clang_unwrapped)"

    # Darling reaches HOST libraries through libelfloader, and wrapgen builds the Mach-O stub
    # for each one by dlopen()ing the real .so at BUILD time to read its dynamic symbol table.
    # dlopen goes through the loader's search path, so every such library's directory has to
    # be on it: dlopen("libfuse.so") fails without this even though the dev shell contains
    # fuse.
    #
    # One entry per wrap_elf() in the tree: fuse for hdiutil (darling-dmg), the sixteen
    # src/native ones the gui component wraps, and the five src/CoreAudio ones (ffmpeg's four
    # plus pulseaudio) that AudioToolbox decodes and plays through. Looked up by SONAME
    # against the dev shell's own -L directories (NIX_LDFLAGS), because that is the
    # authoritative list of what this shell declares. pkg-config is not enough on its own:
    # giflib ships no .pc file at all, and globbing /nix/store is worse than either, since
    # several of these libraries have more than one version there and a stub generated
    # against the wrong one exports the wrong symbols.
    let elf_sonames = [
        libfuse.so libfreetype.so libjpeg.so libpng.so libtiff.so libgif.so libEGL.so
        libfontconfig.so libX11.so libXext.so libXrandr.so libXcursor.so libxkbfile.so
        libcairo.so libdbus-1.so libGL.so libGLU.so libswresample.so libavcodec.so
        libavformat.so libavutil.so libpulse.so
    ]
    let ldirs = (
        ($env.NIX_LDFLAGS? | default "") | split row " " | where {|f| $f | str starts-with "-L" }
        | each {|f| $f | str substring 2.. } | uniq | sort
    )
    mut elf_lib_dirs = []
    mut elf_missing = []
    for so in $elf_sonames {
        mut hit = ($ldirs | where {|d| $"($d)/($so)" | path exists } | first | default "")
        if ($hit | is-empty) {
            $hit = (do -i { ^pkg-config --variable=libdir ($so | str replace "lib" "" )
                | str trim } | default "")
        }
        if ($hit | is-empty) {
            $elf_missing = ($elf_missing | append $so)
        } else if not ($hit in $elf_lib_dirs) {
            $elf_lib_dirs = ($elf_lib_dirs | append $hit)
        }
    }
    print $"host ELF lib dirs: ($elf_lib_dirs | length) entries"
    if ($elf_missing | is-not-empty) {
        print -e $"WARNING: cannot locate: ($elf_missing | str join ' ') -- those wrap_elf stubs will not generate"
    }

    # EVERY host library the reference gives a compile an absolute -I for, not just dbus. The
    # reference build.ninja names 25 such include dirs across 23 packages, and the port
    # dropped all of them: on the host that went unnoticed because darwin_cc defaults to the
    # bare name "clang" (buck/toolchains/BUCK), which inside the dev shell is the WRAPPED
    # clang and injects the same directories through NIX_CFLAGS_COMPILE. It only showed up
    # where that wrapper is deliberately not used: the Nix graph derivation pins
    # clang-unwrapped and unsets NIX_CFLAGS, where iokitd stops at "X11/Xlib.h not found".
    #
    # pkg-config rather than the -isystem list, because several of these are VERSIONED
    # subdirectories that only pkg-config knows: freetype2 is include/freetype2, cairo is
    # include/cairo, dbus splits over two outputs. The ones with no .pc file at all (giflib)
    # are picked up from the dev shell's own -isystem directories below.
    let host_pkgs = [
        dbus-1 x11 xext xrandr xcursor xkbfile xrender xdmcp xproto freetype2
        fontconfig cairo gl glu libavcodec libavformat libavutil libswresample libpulse zlib
        libpng libtiff-4 fuse
    ]
    mut host_include_dirs = []
    mut host_include_missing = []
    for p in $host_pkgs {
        let inc = (
            do -i { ^pkg-config --cflags-only-I $p | str trim } | default ""
            | split row " " | where {|f| $f | str starts-with "-I" }
            | each {|f| $f | str substring 2.. }
        )
        if ($inc | is-empty) {
            $host_include_missing = ($host_include_missing | append $p)
            continue
        }
        for d in $inc {
            if not ($d in $host_include_dirs) {
                $host_include_dirs = ($host_include_dirs | append $d)
            }
        }
    }
    # The stragglers. giflib ships no .pc file at all, so pkg-config cannot find it and the
    # only authoritative statement of where its header is, is the dev shell's own -isystem
    # list -- the same list the wrapped clang has been quietly injecting all along. Added
    # AFTER the pkg-config dirs so a versioned subdirectory still wins the include order.
    let isystem = (
        ($env.NIX_CFLAGS_COMPILE? | default "") | split row " " | enumerate
        | where {|it| $it.index > 0 }
        | where {|it| (($env.NIX_CFLAGS_COMPILE? | default "") | split row " " | get ($it.index - 1)) == "-isystem" }
        | each {|it| $it.item } | uniq | sort
    )
    for d in $isystem {
        if ($d | path exists) and (not ($d in $host_include_dirs)) {
            $host_include_dirs = ($host_include_dirs | append $d)
        }
    }
    print $"host include dirs: ($host_include_dirs | length) entries"
    if ($host_include_missing | is-not-empty) {
        print -e $"WARNING: pkg-config knows nothing about: ($host_include_missing | str join ' ')"
    }

    # The store path is immutable, so an absolute reference to it is stable; rerun
    # this script after bumping the sources that ld64 is built from.
    let conf = $"# GENERATED by scripts/buck-setup.nu -- machine-local, gitignored.
#
# Absolute paths to prebuilt tools and toolchain dirs the Buck2 build drives.
# The nix ones are store paths \(immutable\), so this file only needs regenerating
# when the derivation that produces them changes.
[cider]
ld = ($ld64)/bin/($triplet)-ld
ld64_dir = ($ld64)/bin
clang_resource_dir = ($clang_resource_dir)
darwin_cc = ($clang_unwrapped)/bin/clang
darwin_cxx = ($clang_unwrapped)/bin/clang++
elf_lib_dirs = ($elf_lib_dirs | str join ':')
host_include_dirs = ($host_include_dirs | str join ':')
"
    $conf | save -f .buckconfig.local

    print "wrote .buckconfig.local:"
    open .buckconfig.local | lines | each {|l| print $"  ($l)" }

    print ""
    print "ready: buck2 build //src/external/ciderd/xnu-sys:ciderd_xnu_sys"
}
