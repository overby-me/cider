#!/usr/bin/env nu

# Build the framework dylibs the guest nix needs and overlay them into the cider runtime prefix.
#
# The M4 milestone (guest nix builds bash inside the buck2-built Darling) needs the
# CoreFoundation / CoreServices / SystemConfiguration / Foundation family present in the runtime
# prefix at their /System/Library/Frameworks/... paths. buck2 builds each framework dylib, and
# buck/prefix/BUCK already names the destination path for it; this joins the two, so the overlay
# is a committed step rather than a hand-run scratch script.
#
# --keep-going: build every framework we can. Ones that fail (a framework whose .defs are not yet
# ported for arm64, say) are simply not produced and are skipped in the overlay. The guest nix
# only loads its own closure, so a partial set is still useful.
#
# RUN UNDER THE devShell, like the checks and buck-src.nu: it calls bare `buck2`, which comes from
# `nix develop`. RT defaults to the same path the checks use ($BUCK2_RT, else
# /tmp/cider-buck2-<uid>/rt) and can be overridden.
#
#   nix develop --command nu scripts/build/build-frameworks-overlay.nu
#   nix develop --command nu scripts/build/build-frameworks-overlay.nu --dry-run   # list targets only
#
#   scripts/build/build-frameworks-overlay.nu

def framework_targets [repo: string] {
    # ALL framework Mach-O binaries, public AND private: the main dylib
    # (.../Versions/<V>/<Name>) and framework-internal libraries (.../Libraries/*.dylib).
    # Exclude resources and the pyobjc .so shims, which are Python-linked and not part of the
    # base framework set the guest nix needs.
    open --raw ($repo | path join "buck/prefix/BUCK")
    | parse --regex '"(?<path>libexec/cider/System/Library/(?:Private)?Frameworks/[^"]+)": "(?<tgt>//[^"]+)"'
    | where {|r| ($r.path =~ '/Versions/[A-Z]/[A-Za-z0-9_]+$') or ($r.path | str ends-with '.dylib') }
    | where {|r| (not ($r.path =~ 'Python|pyobjc')) and (not ($r.path | str ends-with '.so')) }
}

def main [--dry-run] {
    let repo = ($env.FILE_PWD | path join ".." ".." | path expand)
    cd $repo
    let rt = ($env.BUCK2_RT? | default $"/tmp/cider-buck2-(^id -u | str trim)/rt")

    let map = (framework_targets $repo)
    let targets = ($map | get tgt | uniq)
    print $"== ($targets | length) framework dylib targets from buck/prefix/BUCK =="
    if $dry_run {
        for t in ($targets | sort) { print $t }
        return
    }

    let tmp = (mktemp -d)
    let out = ($tmp | path join "fw.out")
    let err = ($tmp | path join "fw.err")
    print $"== building ($targets | length) framework dylibs for arm64 (--keep-going); log ($err) =="
    # -i: --keep-going still exits non-zero when any target fails, and a partial set is the point.
    do -i { ^buck2 build ...$targets --keep-going --show-output out> $out err> $err }

    # --show-output prints `root//<target> <relative-output-path>`, one per built target.
    let built = (open $out | lines | where {|l| $l | str starts-with 'root//' }
        | each {|l|
            let parts = ($l | str trim | split row -r '\s+')
            { tgt: ($"//" + ($parts.0 | str replace 'root//' '')), out: ($parts | get 1? | default "") }
        }
        | where {|r| $r.out | is-not-empty })
    let failed = (open $err | lines | where {|l| $l =~ 'Action failed' } | length)
    print $"built ($built | length) of ($targets | length) targets \(($failed) actions failed)"

    # Overlay each built dylib at the /System/Library/... path buck/prefix/BUCK maps it to.
    let bykey = ($map | reduce --fold {} {|r, acc| $acc | upsert $r.tgt $r.path })
    mut n = 0
    for b in $built {
        let rel = ($bykey | get -o $b.tgt)
        if ($rel | is-empty) { continue }
        let dest = ($rt | path join $rel)
        mkdir ($dest | path dirname)
        ^cp -f ($repo | path join $b.out) $dest
        $n += 1
    }
    print $"overlaid ($n) framework dylibs onto ($rt)"
}
