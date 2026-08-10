#!/usr/bin/env nu
# Would the targets that need HOST headers still compile under the Nix graph derivation?
#
# This exists because the same bug was found four times in a row, each time an hour into a
# Nix build, and each time it was reproducible on the host in seconds once the condition was
# named. The condition is a divergence between two lists:
#
#   the HOST gets its host include dirs from scripts/buck-setup.nu, which asks pkg-config
#   for 23 packages and then SWEEPS the dev shell's own -isystem directories to catch
#   giflib, which ships no .pc file. That sweep is generous: 51 directories, including ones
#   nobody named, and linux-headers rode in on it unnoticed for the whole campaign.
#
#   NIX gets them from nix/lib/ciderBuck2Graph.nix, which names its packages EXPLICITLY,
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
# It is deliberately NOT in buck-test.nu: it shells out to nix to read the derivation and
# builds under a non-default buck2 config, which re-analyses. Run it when touching host
# includes, wrappedLibs, or the graph derivation's config.
#
# Converted from bash (task #40) and checked by running both and diffing, on the PASSING and
# the FAILING path. The failing one mattered: the bash version piped the whole buck2 output
# through printf '%s\n' "$out", which blows ARG_MAX once enough targets fail, so it printed
#
#   head: Argument list too long
#   grep: Argument list too long
#
# instead of the errors, exactly when the errors are the point. Its own negative test missed
# that because only ONE target failed then. This streams instead, so the divergence between
# the two is a bug fixed rather than behaviour changed.
#
# Usage:  scripts/buck-nix-includes-check.nu

def say [msg: string] { print -e $msg }

# Every target the reference gives an absolute host -I and that the port builds. Kept in
# step with scripts/buck-host-includes.py, which is what proves the list is complete.
const TARGETS = [
    "//buck-src:iokitd_obj"
    "//buck-src:Onyx2D_obj"
    "//buck-src:CoreText_obj"
    "//buck-src:hdiutil_obj"
    "//buck-src:X11_backend_obj"
    "//buck-src:X11_cgbackend_obj"
    "//darwin/frameworks:OpenGL_obj"
    "//darwin/frameworks:fseventsd_obj"
    "//darwin/CoreAudio:CoreAudio_obj"
    "//darwin/CoreAudio:AudioToolbox_obj"
    "//darwin/CoreAudio:AFAVFormatComponent_obj"
]

def main [] {
    cd ($env.FILE_PWD | path join ".." | path expand)

    if (which buck2 | is-empty) {
        say "missing buck2 -- run inside `nix develop`"
        exit 2
    }

    say "== reading the include dirs the Nix graph derivation declares =="
    # From the derivation rather than from a copy of the list: a copy is one more thing that
    # drifts, and drift is the entire bug this checks for.
    let shown = (^nix derivation show ".#cider-buck2-graph" | complete)
    let hit = (
        $shown.stdout
        | parse --regex 'host_include_dirs = (?<dirs>[^\\\\]*)'
        | get dirs
        | default []
    )
    if ($hit | is-empty) {
        say "could not read host_include_dirs out of the graph derivation"
        exit 2
    }
    let nix_dirs = ($hit | first)
    let n = ($nix_dirs | split row ":" | where {|d| $d != "" } | length)
    say $"   ($n) directories"

    say "== the compiler Nix uses, which is NOT the dev shell's wrapped clang =="
    let cu = (
        ^nix build "nixpkgs#llvmPackages.clang-unwrapped" --no-link --print-out-paths
        | complete | get stdout | lines | last | default ""
    )
    if not ($"($cu)/bin/clang" | path exists) {
        say "could not build clang-unwrapped"
        exit 2
    }
    say $"   ($cu)"

    say $"== building ($TARGETS | length) host-header targets under those conditions =="
    let built = (
        ^buck2 build
            --config $"cider.darwin_cc=($cu)/bin/clang"
            --config $"cider.darwin_cxx=($cu)/bin/clang++"
            --config $"cider.host_include_dirs=($nix_dirs)"
            ...$TARGETS
        | complete
    )

    if $built.exit_code == 0 {
        say ""
        say "PASS: every host-header target compiles with only what the Nix derivation declares"
        exit 0
    }

    say ""
    say "FAIL: a target needs a header the Nix graph derivation does not declare."
    say "The missing include dir has to be added to hostIncludeLibs (or the versioned-subdir"
    say "list beside it) in nix/lib/ciderBuck2Graph.nix. The error names the header:"
    say ""
    $"($built.stdout)($built.stderr)"
    | lines
    | where {|l| ($l =~ "fatal error") or ($l =~ "file not found") or ($l =~ "Failed to build") }
    | first 12
    | each {|l| say $l }
    exit 1
}
